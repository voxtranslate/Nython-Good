// builtins/nyzlib.cpp - DEFLATE (RFC 1951) with the zlib (RFC 1950) and gzip
// (RFC 1952) wrappers, written here (round 79): no system zlib, so the
// Windows/MinGW and 32-bit builds link with what nython.cbp lists. Behind
// lib/zlib.ny (and through it gzip, zipfile, tarfile); both engines (the VM
// reaches these through the builtin bridge).
//
// Inflate: stored, fixed and dynamic Huffman blocks, every length/distance
// code, resumable at any input boundary (a decoder state machine that rolls
// back to the last whole symbol when input runs out), output limits
// (decompressobj's max_length / unconsumed_tail), preset dictionaries, the
// zlib, gzip and auto-detecting wrappers, and zlib's own error messages
// ("invalid block type", "invalid distance too far back", ...).
//
// Deflate: LZ77 over hash chains with zlib's level table (levels 1-3 greedy
// with limited insertion, 4-9 lazy matching; good/lazy/nice/chain as zlib
// trades them), the strategies (filtered, Huffman only, RLE, fixed), blocks
// chosen among stored, fixed and dynamic by their exact size, dynamic codes
// length-limited by package-merge (Larmore & Hirschberg, "A fast algorithm
// for optimal length-limited Huffman codes", JACM 1990), the code-length
// alphabet run-length coded as zlib does, flush modes (sync, full, partial,
// block, finish), copy(), zdict.
//
// Nython-only: _zlib_optimal - an optimal parse in the spirit of Zopfli
// (Alakuijala & Vandevenne, 2013): the LZ77 choices of each block are a
// shortest path whose edge costs come from the previous pass's statistics,
// iterated; blocks are split where that lowers the cost. Standard DEFLATE
// out (any inflater reads it), smaller than level 9.
//
//   _zlib_compress(data, level, wbits) -> bytes
//   _zlib_decompress(data, wbits, bufsize) -> bytes
//   _zlib_cnew(level, method, wbits, memLevel, strategy, zdict) -> handle
//   _zlib_ccompress(h, data) -> bytes      _zlib_cflush(h, mode) -> bytes
//   _zlib_dnew(wbits, zdict) -> handle
//   _zlib_ddecompress(h, data, max_length) -> [out, unconsumed_tail, unused_data, eof]
//   _zlib_dflush(h, data, length) -> [out, unconsumed_tail, unused_data, eof]
//   _zlib_copy(h) -> handle    _zlib_free(h)
//   _zlib_crc32(data, value)   _zlib_adler32(data, value)   _zlib_crc_hqx(data, value)
//   _zlib_optimal(data, iterations, wbits, splitting) -> bytes
//
// zlib.error is raised as ValueError("[zlib] <message>"), which lib/zlib.ny
// turns into its error class; argument errors raise as CPython raises them.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

Value dispatch_zlib(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> zlib_builtin_names();

namespace nyz {

// ── checksums ───────────────────────────────────────────────────────────────
static uint32_t g_crc[8][256];
static uint16_t g_hqx[256];
static std::once_flag g_tables_once;
static void init_tables() {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320U ^ (c >> 1) : c >> 1;
        g_crc[0][i] = c;
    }
    for (uint32_t i = 0; i < 256; i++)
        for (int t = 1; t < 8; t++) g_crc[t][i] = (g_crc[t - 1][i] >> 8) ^ g_crc[0][g_crc[t - 1][i] & 0xff];
    for (uint32_t i = 0; i < 256; i++) {
        uint16_t c = (uint16_t)(i << 8);
        for (int k = 0; k < 8; k++) c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
        g_hqx[i] = c;
    }
}
static void tables() { std::call_once(g_tables_once, init_tables); }

uint32_t crc32(const uint8_t* p, size_t n, uint32_t crc) {
    tables();
    crc = ~crc;
    while (n >= 8) {   // slicing-by-8
        uint32_t a = crc ^ ((uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
        uint32_t b = (uint32_t)p[4] | (uint32_t)p[5] << 8 | (uint32_t)p[6] << 16 | (uint32_t)p[7] << 24;
        crc = g_crc[7][a & 0xff] ^ g_crc[6][(a >> 8) & 0xff] ^ g_crc[5][(a >> 16) & 0xff] ^ g_crc[4][a >> 24]
            ^ g_crc[3][b & 0xff] ^ g_crc[2][(b >> 8) & 0xff] ^ g_crc[1][(b >> 16) & 0xff] ^ g_crc[0][b >> 24];
        p += 8; n -= 8;
    }
    while (n--) crc = g_crc[0][(crc ^ *p++) & 0xff] ^ (crc >> 8);
    return ~crc;
}
uint32_t adler32(const uint8_t* p, size_t n, uint32_t adler) {
    uint32_t a = adler & 0xffff, b = adler >> 16;
    while (n) {
        size_t k = n < 5552 ? n : 5552;   // NMAX: no overflow before the modulo
        n -= k;
        while (k--) { a += *p++; b += a; }
        a %= 65521; b %= 65521;
    }
    return (b << 16) | a;
}
uint32_t crc_hqx(const uint8_t* p, size_t n, uint32_t crc) {
    tables();
    crc &= 0xffff;
    while (n--) crc = ((crc << 8) & 0xff00) ^ g_hqx[((crc >> 8) & 0xff) ^ *p++];
    return crc;
}

// ── shared tables ───────────────────────────────────────────────────────────
static const uint16_t LBASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                   35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint8_t LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t DBASE[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                   1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint8_t DEXT[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
static const uint8_t CLORDER[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

static uint8_t g_lcode[259];     // match length 3..258 -> length code 0..28
static uint8_t g_dcode_lo[513];  // distance 1..512 -> code
static uint8_t g_dcode_hi[257];  // (distance-1) >> 7 for distances above 512
static std::once_flag g_codes_once;
static void init_codes() {
    for (int c = 0; c < 29; c++) {
        int hi = c == 28 ? 258 : LBASE[c] + (1 << LEXT[c]) - 1;
        for (int l = LBASE[c]; l <= hi && l <= 258; l++) g_lcode[l] = (uint8_t)c;
    }
    g_lcode[258] = 28;
    for (int c = 0; c < 30; c++) {
        int lo = DBASE[c], hi = DBASE[c] + (1 << DEXT[c]) - 1;
        for (int d = lo; d <= hi; d++) {
            if (d <= 512) g_dcode_lo[d] = (uint8_t)c;
            else g_dcode_hi[(d - 1) >> 7] = (uint8_t)c;
        }
    }
}
static inline int lcode(int len) { return g_lcode[len]; }
static inline int dcode(int dist) { return dist <= 512 ? g_dcode_lo[dist] : g_dcode_hi[(dist - 1) >> 7]; }
static void codes() { std::call_once(g_codes_once, init_codes); }

static inline uint32_t reverse_bits(uint32_t code, int len) {
    uint32_t r = 0;
    for (int i = 0; i < len; i++) { r = (r << 1) | (code & 1); code >>= 1; }
    return r;
}

struct ZError { int code; std::string msg; };
[[noreturn]] static void zfail(int code, const std::string& msg) { throw ZError{code, msg}; }

// ════════════════════════════════════════════════════════════════════════════
// Inflate
// ════════════════════════════════════════════════════════════════════════════
constexpr int FASTBITS = 10;

struct Huff {
    uint16_t count[16] = {0};
    uint16_t sym[320] = {0};
    uint16_t fast[1 << FASTBITS] = {0};   // sym << 4 | len, 0 = use the slow path
};

// 0 complete, > 0 incomplete, < 0 over-subscribed; max length in *maxlen.
static int build_huff(Huff& h, const uint8_t* lens, int n, int* maxlen = nullptr) {
    std::memset(h.count, 0, sizeof h.count);
    std::memset(h.fast, 0, sizeof h.fast);
    for (int i = 0; i < n; i++) h.count[lens[i]]++;
    int mx = 0;
    for (int l = 1; l <= 15; l++) if (h.count[l]) mx = l;
    if (maxlen) *maxlen = mx;
    h.count[0] = 0;
    int left = 1;
    for (int l = 1; l <= 15; l++) { left <<= 1; left -= h.count[l]; if (left < 0) return left; }
    uint16_t offs[16];
    offs[1] = 0;
    for (int l = 1; l < 15; l++) offs[l + 1] = (uint16_t)(offs[l] + h.count[l]);
    for (int s = 0; s < n; s++) if (lens[s]) h.sym[offs[lens[s]]++] = (uint16_t)s;
    uint32_t next[16];
    uint32_t code = 0;
    for (int l = 1; l <= 15; l++) { code = (code + h.count[l - 1]) << 1; next[l] = code; }
    for (int s = 0; s < n; s++) {
        int l = lens[s];
        if (!l) continue;
        uint32_t c = next[l]++;
        if (l <= FASTBITS) {
            uint32_t r = reverse_bits(c, l);
            for (uint32_t j = r; j < (1u << FASTBITS); j += (1u << l)) h.fast[j] = (uint16_t)((s << 4) | l);
        }
    }
    return mx == 0 ? 0 : left;
}

struct NeedInput {};

struct Inflater {
    // configuration
    int wrap = 1;            // 0 raw, 1 zlib, 2 gzip, 3 zlib or gzip
    int wbits = 15;          // 0: the header's
    std::string dict;
    // input not consumed yet, and the bit buffer
    std::string in;
    size_t ip = 0;
    uint64_t bb = 0;
    int bc = 0;
    size_t cp_ip = 0; uint64_t cp_bb = 0; int cp_bc = 0;   // the last whole step
    // history
    std::vector<uint8_t> win = std::vector<uint8_t>(32768);
    uint32_t wpos = 0;
    uint64_t have = 0;       // bytes of history (dictionary + output)
    // state
    enum St { HEAD, BLOCK, STORED, CODES, CHECK, DONE } st = HEAD;
    bool last = false;
    bool is_gzip = false;
    bool dict_used = false;
    uint32_t stored_left = 0;
    Huff lit, dist;
    bool use_fixed = false;
    int copy_len = 0, copy_dist = 0;
    uint32_t check = 0, isize = 0;
    size_t ck_from = 0;      // out[ck_from:] not in `check` yet
    std::string* outp = nullptr;

    static const Huff& fixed_lit() {
        static Huff h = [] { Huff x; uint8_t l[288]; for (int i = 0; i < 288; i++) l[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8; build_huff(x, l, 288); return x; }();
        return h;
    }
    static const Huff& fixed_dist() {
        static Huff h = [] { Huff x; uint8_t l[30]; for (int i = 0; i < 30; i++) l[i] = 5; build_huff(x, l, 30); return x; }();
        return h;
    }

    void start() {
        if (wrap == 0 && !dict.empty()) preload_dict();
        st = wrap == 0 ? BLOCK : HEAD;
        check = wrap == 2 ? 0 : 1;
    }
    void preload_dict() {
        size_t n = dict.size(), from = n > 32768 ? n - 32768 : 0;
        for (size_t i = from; i < n; i++) { win[wpos & 32767] = (uint8_t)dict[i]; wpos++; }
        have += n;
        dict_used = true;
    }
    void mark() { cp_ip = ip; cp_bb = bb; cp_bc = bc; }
    void rollback() { ip = cp_ip; bb = cp_bb; bc = cp_bc; }
    inline void need(int n) {
        while (bc < n) {
            if (ip >= in.size()) throw NeedInput{};
            bb |= (uint64_t)(uint8_t)in[ip++] << bc;
            bc += 8;
        }
    }
    inline uint32_t bits(int n) {
        if (n == 0) return 0;
        need(n);
        uint32_t v = (uint32_t)(bb & ((1ull << n) - 1));
        bb >>= n; bc -= n;
        return v;
    }
    inline void refill() {
        while (bc <= 56 && ip < in.size()) { bb |= (uint64_t)(uint8_t)in[ip++] << bc; bc += 8; }
    }
    void align() { int k = bc & 7; bb >>= k; bc -= k; }
    // a byte at a byte boundary: whole bytes left in the bit buffer first
    int byte() {
        if (bc >= 8) { int v = (int)(bb & 0xff); bb >>= 8; bc -= 8; return v; }
        if (ip >= in.size()) throw NeedInput{};
        return (uint8_t)in[ip++];
    }
    size_t avail_bytes() const { return (size_t)(bc / 8) + (in.size() - ip); }
    inline int decode(const Huff& h) {
        if (bc < 15) refill();
        uint16_t e = h.fast[bb & ((1u << FASTBITS) - 1)];
        if (e) {
            int l = e & 15;
            if (l > bc) throw NeedInput{};
            bb >>= l; bc -= l;
            return e >> 4;
        }
        uint64_t b = bb;
        int code = 0, first = 0, index = 0;
        for (int l = 1; l <= 15; l++) {
            if (l > bc) throw NeedInput{};
            code |= (int)((b >> (l - 1)) & 1);
            int count = h.count[l];
            if (code - count < first) { bb >>= l; bc -= l; return h.sym[index + (code - first)]; }
            index += count; first += count; first <<= 1; code <<= 1;
        }
        return -1;
    }
    inline void put(uint8_t c) {
        outp->push_back((char)c);
        win[wpos & 32767] = c;
        wpos++;
        have++;
    }
    void update_check() {
        std::string& out = *outp;
        if (ck_from >= out.size()) return;
        const uint8_t* p = (const uint8_t*)out.data() + ck_from;
        size_t n = out.size() - ck_from;
        if (is_gzip) { check = crc32(p, n, check); isize += (uint32_t)n; }
        else if (wrap != 0) check = adler32(p, n, check);
        ck_from = out.size();
    }

    void header() {
        int b0 = byte(), b1 = byte();
        bool gz = false;
        if (wrap == 2 || wrap == 3) {
            if (b0 == 0x1f && b1 == 0x8b) gz = true;
            else if (wrap == 2) zfail(-3, "incorrect header check");
        }
        if (gz) {
            std::string hdr;
            hdr.push_back((char)b0); hdr.push_back((char)b1);
            int cm = byte(); hdr.push_back((char)cm);
            int flg = byte(); hdr.push_back((char)flg);
            if (cm != 8) zfail(-3, "unknown compression method");
            if (flg & 0xe0) zfail(-3, "unknown header flags set");
            for (int i = 0; i < 6; i++) hdr.push_back((char)byte());   // mtime, xfl, os
            if (flg & 4) {
                int x0 = byte(), x1 = byte();
                hdr.push_back((char)x0); hdr.push_back((char)x1);
                int xlen = x0 | x1 << 8;
                for (int i = 0; i < xlen; i++) hdr.push_back((char)byte());
            }
            if (flg & 8) { int c; do { c = byte(); hdr.push_back((char)c); } while (c != 0); }
            if (flg & 16) { int c; do { c = byte(); hdr.push_back((char)c); } while (c != 0); }
            if (flg & 2) {
                int h0 = byte(), h1 = byte();
                uint32_t want = crc32((const uint8_t*)hdr.data(), hdr.size(), 0) & 0xffff;
                if ((uint32_t)(h0 | h1 << 8) != want) zfail(-3, "header crc mismatch");
            }
            is_gzip = true;
            check = 0; isize = 0;
            st = BLOCK;
            return;
        }
        // zlib
        if (((b0 << 8) | b1) % 31) zfail(-3, "incorrect header check");
        if ((b0 & 15) != 8) zfail(-3, "unknown compression method");
        int len = (b0 >> 4) + 8;
        int wb = wbits;
        if (len > 15 || (wb != 0 && len > wb)) zfail(-3, "invalid window size");
        if (b1 & 0x20) {
            uint32_t id = 0;
            for (int i = 0; i < 4; i++) id = (id << 8) | (uint32_t)byte();
            if (dict.empty()) zfail(2, "");                       // Z_NEED_DICT
            if (adler32((const uint8_t*)dict.data(), dict.size(), 1) != id) zfail(-3, "\x01zdict");
            preload_dict();
        }
        check = 1;
        st = BLOCK;
    }
    void block_header() {
        int hdr = (int)bits(3);
        last = hdr & 1;
        int type = hdr >> 1;
        if (type == 0) {
            align();
            int a = byte(), b = byte(), c = byte(), d = byte();
            uint32_t len = (uint32_t)(a | b << 8), nlen = (uint32_t)(c | d << 8);
            if (len != (~nlen & 0xffff)) zfail(-3, "invalid stored block lengths");
            stored_left = len;
            st = STORED;
        } else if (type == 1) {
            use_fixed = true;
            st = CODES;
        } else if (type == 2) {
            dynamic_header();
            use_fixed = false;
            st = CODES;
        } else zfail(-3, "invalid block type");
    }
    void dynamic_header() {
        int nlen = (int)bits(5) + 257, ndist = (int)bits(5) + 1, ncode = (int)bits(4) + 4;
        if (nlen > 286 || ndist > 30) zfail(-3, "too many length or distance symbols");
        uint8_t cl[19] = {0};
        for (int i = 0; i < ncode; i++) cl[CLORDER[i]] = (uint8_t)bits(3);
        Huff clh;
        if (build_huff(clh, cl, 19) != 0) zfail(-3, "invalid code lengths set");
        uint8_t lens[320] = {0};
        int i = 0;
        while (i < nlen + ndist) {
            int s = decode(clh);
            if (s < 0) zfail(-3, "invalid code lengths set");
            if (s < 16) { lens[i++] = (uint8_t)s; continue; }
            int len = 0, rep;
            if (s == 16) {
                if (i == 0) zfail(-3, "invalid bit length repeat");
                len = lens[i - 1];
                rep = 3 + (int)bits(2);
            } else if (s == 17) rep = 3 + (int)bits(3);
            else rep = 11 + (int)bits(7);
            if (i + rep > nlen + ndist) zfail(-3, "invalid bit length repeat");
            while (rep--) lens[i++] = (uint8_t)len;
        }
        if (lens[256] == 0) zfail(-3, "invalid code -- missing end-of-block");
        int mx = 0;
        int r = build_huff(lit, lens, nlen, &mx);
        if (r < 0 || (r > 0 && mx != 1)) zfail(-3, "invalid literal/lengths set");
        r = build_huff(dist, lens + nlen, ndist, &mx);
        if (r < 0 || (r > 0 && mx != 1)) zfail(-3, "invalid distances set");
    }
    // the bytes of a match still to copy; false when the output is full
    bool do_copy(size_t limit) {
        while (copy_len > 0) {
            if (limit && outp->size() >= limit) return false;
            put(win[(wpos - (uint32_t)copy_dist) & 32767]);
            copy_len--;
        }
        return true;
    }
    void trailer() {
        update_check();
        align();   // the trailer starts at the next byte boundary
        if (is_gzip) {
            uint32_t crc = 0, sz = 0;
            for (int i = 0; i < 4; i++) crc |= (uint32_t)byte() << (8 * i);
            for (int i = 0; i < 4; i++) sz |= (uint32_t)byte() << (8 * i);
            if (crc != check) zfail(-3, "incorrect data check");
            if (sz != isize) zfail(-3, "incorrect length check");
        } else if (wrap != 0) {
            uint32_t a = 0;
            for (int i = 0; i < 4; i++) a = (a << 8) | (uint32_t)byte();
            if (a != check) zfail(-3, "incorrect data check");
        }
        st = DONE;
    }

    // Decode what the input allows into out (at most `limit` bytes in all
    // when limit > 0). Returns with st == DONE, the input used up, or the
    // output full.
    void run(std::string& out, size_t limit) {
        outp = &out;
        ck_from = out.size();
        try {
            for (;;) {
                mark();
                if (st == DONE) break;
                if (limit && out.size() >= limit && (copy_len > 0 || st == CODES || st == STORED)) break;
                switch (st) {
                case HEAD: header(); break;
                case BLOCK: block_header(); break;
                case STORED: {
                    align();
                    while (stored_left > 0) {
                        if (limit && out.size() >= limit) break;
                        if (avail_bytes() == 0) throw NeedInput{};
                        if (bc >= 8) { put((uint8_t)byte()); stored_left--; continue; }
                        size_t n = std::min<size_t>(stored_left, in.size() - ip);
                        if (limit) n = std::min(n, limit - out.size());
                        for (size_t k = 0; k < n; k++) put((uint8_t)in[ip + k]);
                        ip += n;
                        stored_left -= (uint32_t)n;
                        mark();
                    }
                    if (stored_left == 0) st = last ? CHECK : BLOCK;
                    break;
                }
                case CODES: {
                    const Huff& L = use_fixed ? fixed_lit() : lit;
                    const Huff& D = use_fixed ? fixed_dist() : dist;
                    if (!do_copy(limit)) break;
                    for (;;) {
                        mark();
                        if (limit && out.size() >= limit) break;
                        int s = decode(L);
                        if (s < 256) {
                            if (s < 0) zfail(-3, "invalid literal/length code");
                            put((uint8_t)s);
                            continue;
                        }
                        if (s == 256) { st = last ? CHECK : BLOCK; break; }
                        s -= 257;
                        if (s >= 29) zfail(-3, "invalid literal/length code");
                        int len = LBASE[s] + (int)bits(LEXT[s]);
                        int ds = decode(D);
                        if (ds < 0 || ds >= 30) zfail(-3, "invalid distance code");
                        int d = DBASE[ds] + (int)bits(DEXT[ds]);
                        if ((uint64_t)d > have || d > 32768) zfail(-3, "invalid distance too far back");
                        copy_len = len; copy_dist = d;
                        mark();
                        if (!do_copy(limit)) break;
                    }
                    break;
                }
                case CHECK: trailer(); break;
                case DONE: break;
                }
            }
        } catch (NeedInput&) {
            rollback();
        } catch (ZError&) {
            outp = nullptr;
            throw;
        }
        update_check();
        // drop what was consumed
        if (ip) { in.erase(0, ip); ip = 0; cp_ip = 0; }
        outp = nullptr;
    }
    // After the end of the stream: the bytes that followed it (the whole
    // bytes still in the bit buffer first).
    std::string take_unused() {
        std::string u;
        int k = bc & 7; bb >>= k; bc -= k;
        while (bc >= 8) { u.push_back((char)(bb & 0xff)); bb >>= 8; bc -= 8; }
        u += in.substr(ip);
        in.clear(); ip = 0;
        return u;
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Huffman code construction
// ════════════════════════════════════════════════════════════════════════════
// Package-merge (Larmore & Hirschberg 1990): optimal code lengths no longer
// than maxlen for the symbols with a non-zero frequency.
static void limited_lengths(const uint32_t* freq, int n, int maxlen, uint8_t* lens) {
    std::memset(lens, 0, (size_t)n);
    std::vector<int> used;
    for (int i = 0; i < n; i++) if (freq[i]) used.push_back(i);
    int m = (int)used.size();
    if (m == 0) return;
    if (m == 1) { lens[used[0]] = 1; return; }
    std::stable_sort(used.begin(), used.end(), [&](int a, int b) { return freq[a] < freq[b]; });
    struct Node { uint64_t w; int a, b, sym; };
    std::vector<Node> nodes;
    nodes.reserve((size_t)m * (size_t)(maxlen + 1) * 2);
    std::vector<int> leaves;
    for (int s : used) { leaves.push_back((int)nodes.size()); nodes.push_back({freq[s], -1, -1, s}); }
    std::vector<int> cur = leaves, pk, merged;
    for (int level = 1; level < maxlen; level++) {
        pk.clear();
        for (size_t i = 0; i + 1 < cur.size(); i += 2) {
            nodes.push_back({nodes[cur[i]].w + nodes[cur[i + 1]].w, cur[i], cur[i + 1], -1});
            pk.push_back((int)nodes.size() - 1);
        }
        merged.clear();
        size_t a = 0, b = 0;
        while (a < leaves.size() || b < pk.size()) {
            if (b >= pk.size() || (a < leaves.size() && nodes[leaves[a]].w <= nodes[pk[b]].w)) merged.push_back(leaves[a++]);
            else merged.push_back(pk[b++]);
        }
        cur.swap(merged);
    }
    std::vector<int> stack;
    for (int i = 0; i < 2 * m - 2 && i < (int)cur.size(); i++) {
        stack.push_back(cur[i]);
        while (!stack.empty()) {
            int x = stack.back(); stack.pop_back();
            if (nodes[x].sym >= 0) lens[nodes[x].sym]++;
            else { stack.push_back(nodes[x].a); stack.push_back(nodes[x].b); }
        }
    }
}
// Canonical codes (RFC 1951 3.2.2), bit-reversed for an LSB-first writer.
static void make_codes(const uint8_t* lens, int n, uint16_t* codes) {
    uint16_t count[16] = {0};
    for (int i = 0; i < n; i++) count[lens[i]]++;
    count[0] = 0;
    uint32_t next[16], code = 0;
    for (int l = 1; l <= 15; l++) { code = (code + count[l - 1]) << 1; next[l] = code; }
    for (int i = 0; i < n; i++) codes[i] = lens[i] ? (uint16_t)reverse_bits(next[lens[i]]++, lens[i]) : 0;
}

// ════════════════════════════════════════════════════════════════════════════
// Bit writer and block encoder (shared by the deflater and the optimal parse)
// ════════════════════════════════════════════════════════════════════════════
struct BitOut {
    std::string out;
    uint64_t bb = 0;
    int bc = 0;
    inline void put(uint32_t v, int n) {
        bb |= (uint64_t)v << bc;
        bc += n;
        while (bc >= 8) { out.push_back((char)(bb & 0xff)); bb >>= 8; bc -= 8; }
    }
    void align() { if (bc > 0) put(0, 8 - bc); }
};

// A symbol: literal (< 256) or a match: 1 << 31 | len << 16 | dist.
constexpr uint32_t MATCH = 0x80000000u;
static inline bool is_match(uint32_t s) { return (s & MATCH) != 0; }
static inline int s_len(uint32_t s) { return (int)((s >> 16) & 0x1ff); }
static inline int s_dist(uint32_t s) { return (int)(s & 0xffff); }
static inline uint32_t mk_match(int len, int dist) { return MATCH | (uint32_t)len << 16 | (uint32_t)dist; }

struct CLItem { uint8_t sym; uint8_t extra; uint8_t nbits; };
// zlib's scan_tree/send_tree run-length coding of one tree's lengths.
static void rle_lengths(const uint8_t* lens, int n, std::vector<CLItem>& outv) {
    int prevlen = -1, nextlen = lens[0], count = 0, max_count = 7, min_count = 4;
    if (nextlen == 0) { max_count = 138; min_count = 3; }
    for (int i = 0; i < n; i++) {
        int curlen = nextlen;
        nextlen = i + 1 < n ? lens[i + 1] : -1;
        if (++count < max_count && curlen == nextlen) continue;
        if (count < min_count) {
            while (count--) outv.push_back({(uint8_t)curlen, 0, 0});
        } else if (curlen != 0) {
            if (curlen != prevlen) { outv.push_back({(uint8_t)curlen, 0, 0}); count--; }
            outv.push_back({16, (uint8_t)(count - 3), 2});
        } else if (count <= 10) {
            outv.push_back({17, (uint8_t)(count - 3), 3});
        } else {
            outv.push_back({18, (uint8_t)(count - 11), 7});
        }
        count = 0;
        prevlen = curlen;
        if (nextlen == 0) { max_count = 138; min_count = 3; }
        else if (curlen == nextlen) { max_count = 6; min_count = 3; }
        else { max_count = 7; min_count = 4; }
    }
}

struct DynTrees {
    uint8_t ll[288], dl[32], cl[19];
    uint16_t lc[288], dc[32], cc[19];
    int hlit, hdist, hclen;
    std::vector<CLItem> items;
    uint64_t header_bits = 0;
};

static const uint8_t* fixed_ll() {
    static uint8_t l[288];
    static bool init = [] { for (int i = 0; i < 288; i++) l[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8; return true; }();
    (void)init;
    return l;
}
static const uint16_t* fixed_lc() {
    static uint16_t c[288];
    static bool init = [] { make_codes(fixed_ll(), 288, c); return true; }();
    (void)init;
    return c;
}
static const uint16_t* fixed_dc() {
    static uint16_t c[32];
    static bool init = [] { uint8_t l[32]; for (int i = 0; i < 32; i++) l[i] = 5; make_codes(l, 32, c); return true; }();
    (void)init;
    return c;
}

static void count_freqs(const uint32_t* syms, size_t n, uint32_t* lf, uint32_t* df) {
    std::memset(lf, 0, 288 * sizeof(uint32_t));
    std::memset(df, 0, 32 * sizeof(uint32_t));
    for (size_t i = 0; i < n; i++) {
        uint32_t s = syms[i];
        if (is_match(s)) { lf[257 + lcode(s_len(s))]++; df[dcode(s_dist(s))]++; }
        else lf[s]++;
    }
    lf[256] = 1;
}
static void build_dyn(const uint32_t* lf_in, const uint32_t* df_in, DynTrees& t) {
    uint32_t lf[288], df[32];
    std::memcpy(lf, lf_in, sizeof lf);
    std::memcpy(df, df_in, sizeof df);
    // at least two codes in each tree (zlib's rule: an inflater may refuse
    // an incomplete code otherwise)
    auto ensure2 = [](uint32_t* f, int n) {
        int used = 0;
        for (int i = 0; i < n; i++) if (f[i]) used++;
        for (int i = 0; used < 2 && i < n; i++) if (!f[i]) { f[i] = 1; used++; }
    };
    ensure2(lf, 286);
    ensure2(df, 30);
    limited_lengths(lf, 286, 15, t.ll);
    t.ll[286] = t.ll[287] = 0;
    limited_lengths(df, 30, 15, t.dl);
    t.dl[30] = t.dl[31] = 0;
    t.hlit = 286; while (t.hlit > 257 && t.ll[t.hlit - 1] == 0) t.hlit--;
    t.hdist = 30; while (t.hdist > 1 && t.dl[t.hdist - 1] == 0) t.hdist--;
    t.items.clear();
    rle_lengths(t.ll, t.hlit, t.items);
    rle_lengths(t.dl, t.hdist, t.items);
    uint32_t cf[19] = {0};
    for (auto& it : t.items) cf[it.sym]++;
    limited_lengths(cf, 19, 7, t.cl);
    t.hclen = 19; while (t.hclen > 4 && t.cl[CLORDER[t.hclen - 1]] == 0) t.hclen--;
    make_codes(t.ll, 288, t.lc);
    make_codes(t.dl, 32, t.dc);
    make_codes(t.cl, 19, t.cc);
    uint64_t hb = 5 + 5 + 4 + 3 * (uint64_t)t.hclen;
    for (auto& it : t.items) hb += t.cl[it.sym] + it.nbits;
    t.header_bits = hb;
}
static uint64_t data_bits(const uint32_t* lf, const uint32_t* df, const uint8_t* ll, const uint8_t* dl) {
    uint64_t b = 0;
    for (int i = 0; i < 286; i++) {
        if (!lf[i]) continue;
        b += (uint64_t)lf[i] * ll[i];
        if (i >= 257) b += (uint64_t)lf[i] * LEXT[i - 257];
    }
    for (int i = 0; i < 30; i++) if (df[i]) b += (uint64_t)df[i] * (dl[i] + DEXT[i]);
    return b;
}
static void write_syms(BitOut& w, const uint32_t* syms, size_t n, const uint8_t* ll, const uint16_t* lc,
                       const uint8_t* dl, const uint16_t* dc) {
    for (size_t i = 0; i < n; i++) {
        uint32_t s = syms[i];
        if (!is_match(s)) { w.put(lc[s], ll[s]); continue; }
        int len = s_len(s), d = s_dist(s);
        int c = lcode(len);
        w.put(lc[257 + c], ll[257 + c]);
        if (LEXT[c]) w.put((uint32_t)(len - LBASE[c]), LEXT[c]);
        int dcd = dcode(d);
        w.put(dc[dcd], dl[dcd]);
        if (DEXT[dcd]) w.put((uint32_t)(d - DBASE[dcd]), DEXT[dcd]);
    }
    w.put(lc[256], ll[256]);
}
static void write_stored(BitOut& w, const uint8_t* raw, size_t n, bool last) {
    size_t off = 0;
    do {
        size_t k = std::min<size_t>(n - off, 65535);
        bool fin = last && off + k == n;
        w.put(fin ? 1 : 0, 3);
        w.align();
        w.put((uint32_t)(k & 0xffff), 16);
        w.put((uint32_t)(~k & 0xffff), 16);
        w.out.append((const char*)raw + off, k);
        off += k;
    } while (off < n);
}
// The cheapest of stored, fixed and dynamic for these symbols (raw: the
// bytes they stand for, or null when stored is not possible).
// mode: 0 best, 1 fixed only (Z_FIXED).
static void emit_block(BitOut& w, const std::vector<uint32_t>& syms, const uint8_t* raw, size_t rawlen,
                       bool last, int mode) {
    codes();
    uint32_t lf[288], df[32];
    count_freqs(syms.data(), syms.size(), lf, df);
    uint64_t fixed_bits = 3 + data_bits(lf, df, fixed_ll(), [] { static uint8_t d[32]; static bool i = [] { for (auto& x : d) x = 5; return true; }(); (void)i; return d; }());
    DynTrees t;
    uint64_t dyn_bits = UINT64_MAX;
    if (mode == 0) {
        build_dyn(lf, df, t);
        dyn_bits = 3 + t.header_bits + data_bits(lf, df, t.ll, t.dl);
    }
    uint64_t opt_lenb = (dyn_bits == UINT64_MAX) ? UINT64_MAX : (dyn_bits + 7) >> 3;
    uint64_t static_lenb = (fixed_bits + 7) >> 3;
    bool use_fixed = static_lenb <= opt_lenb || mode == 1;
    if (use_fixed) opt_lenb = static_lenb;
    size_t nstored = rawlen == 0 ? 1 : (rawlen + 65534) / 65535;
    if (raw && rawlen + 4 * nstored <= opt_lenb) { write_stored(w, raw, rawlen, last); return; }
    if (use_fixed) {
        w.put((last ? 1 : 0) | (1 << 1), 3);
        static uint8_t fd[32];
        static bool fi = [] { for (auto& x : fd) x = 5; return true; }();
        (void)fi;
        write_syms(w, syms.data(), syms.size(), fixed_ll(), fixed_lc(), fd, fixed_dc());
        return;
    }
    w.put((last ? 1 : 0) | (2 << 1), 3);
    w.put((uint32_t)(t.hlit - 257), 5);
    w.put((uint32_t)(t.hdist - 1), 5);
    w.put((uint32_t)(t.hclen - 4), 4);
    for (int i = 0; i < t.hclen; i++) w.put(t.cl[CLORDER[i]], 3);
    for (auto& it : t.items) {
        w.put(t.cc[it.sym], t.cl[it.sym]);
        if (it.nbits) w.put(it.extra, it.nbits);
    }
    write_syms(w, syms.data(), syms.size(), t.ll, t.lc, t.dl, t.dc);
}

// ════════════════════════════════════════════════════════════════════════════
// Deflate
// ════════════════════════════════════════════════════════════════════════════
struct Config { int good, lazy, nice, chain; bool fast; };
static const Config CONFIG[10] = {
    {0, 0, 0, 0, false},       // 0: stored
    {4, 4, 8, 4, true},        // 1..3: greedy, lazy = max insert length
    {4, 5, 16, 8, true},
    {4, 6, 32, 32, true},
    {4, 4, 16, 16, false},     // 4..9: lazy matching
    {8, 16, 32, 32, false},
    {8, 16, 128, 128, false},
    {8, 32, 128, 256, false},
    {32, 128, 258, 1024, false},
    {32, 258, 258, 4096, false},
};
constexpr int MIN_MATCH = 3, MAX_MATCH = 258, MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1, TOO_FAR = 4096;
enum { Z_NO_FLUSH = 0, Z_PARTIAL_FLUSH = 1, Z_SYNC_FLUSH = 2, Z_FULL_FLUSH = 3, Z_FINISH = 4, Z_BLOCK = 5, Z_TREES = 6 };
enum { Z_FILTERED = 1, Z_HUFFMAN_ONLY = 2, Z_RLE = 3, Z_FIXED = 4 };

struct Deflater {
    int level = 6, wbits = 15, strategy = 0, mem_level = 8, wrap = 1;
    Config cfg{};
    int wsize = 32768, wmask = 32767, max_dist = 32768 - MIN_LOOKAHEAD;
    int hbits = 15, hmask = 0, hshift = 5;
    std::vector<uint8_t> buf;       // buf[0] is absolute position `base`
    int64_t base = 0, pos = 0;      // pos: next position to look at
    std::vector<int64_t> head, prev;
    // lazy matching state
    bool match_avail = false;
    int match_len = MIN_MATCH - 1, match_dist = 0;
    // the block being collected: syms stand for [block_start, tally_end)
    std::vector<uint32_t> syms;
    size_t lit_bufsize = 16384;
    int64_t block_start = 0, tally_end = 0;
    BitOut w;
    uint32_t check = 1, isize = 0;
    bool started = false, finished = false;
    std::string dict;

    bool init(int lvl, int wb, int mem, int strat) {
        if (lvl == -1) lvl = 6;
        int wr = 1;
        if (wb < 0) { wr = 0; if (wb < -15) return false; wb = -wb; }
        else if (wb > 15) { wr = 2; wb -= 16; }
        if (mem < 1 || mem > 9 || wb < 8 || wb > 15 || lvl < 0 || lvl > 9 || strat < 0 || strat > Z_FIXED || (wb == 8 && wr != 1))
            return false;
        if (wb == 8) wb = 9;
        level = lvl; wbits = wb; mem_level = mem; strategy = strat; wrap = wr;
        cfg = CONFIG[lvl];
        wsize = 1 << wb; wmask = wsize - 1; max_dist = wsize - MIN_LOOKAHEAD;
        hbits = mem + 7; hmask = (1 << hbits) - 1; hshift = (hbits + MIN_MATCH - 1) / MIN_MATCH;
        head.assign((size_t)1 << hbits, -1);
        prev.assign((size_t)wsize, -1);
        lit_bufsize = (size_t)1 << (mem + 6);
        check = wrap == 2 ? 0 : 1;
        codes();
        return true;
    }
    void set_dict(const std::string& d) {
        dict = d;
        buf.assign(d.begin(), d.end());
        base = 0;
        pos = block_start = tally_end = (int64_t)d.size();
        for (int64_t p = 0; p + MIN_MATCH <= (int64_t)d.size(); p++) insert(p);
    }
    inline uint32_t hash_at(int64_t p) const {
        const uint8_t* s = &buf[(size_t)(p - base)];
        return (((uint32_t)s[0] << (2 * hshift)) ^ ((uint32_t)s[1] << hshift) ^ s[2]) & (uint32_t)hmask;
    }
    inline int64_t insert(int64_t p) {
        uint32_t h = hash_at(p);
        int64_t c = head[h];
        prev[(size_t)(p & wmask)] = c;
        head[h] = p;
        return c;
    }
    int64_t end() const { return base + (int64_t)buf.size(); }
    int longest_match(int64_t cur, int64_t cand, int prev_length, int& dist_out) {
        int chain = cfg.chain;
        if (prev_length >= cfg.good) chain >>= 2;
        int64_t avail = end() - cur;
        int maxlen = (int)std::min<int64_t>(MAX_MATCH, avail);
        int nice = std::min(cfg.nice, maxlen);
        int best = prev_length;
        int found = 0;
        const uint8_t* s = &buf[(size_t)(cur - base)];
        int64_t limit = cur - max_dist;
        while (cand >= 0 && cand >= limit && cand < cur && chain-- > 0) {
            const uint8_t* m = &buf[(size_t)(cand - base)];
            if (best < maxlen && m[best] == s[best] && m[0] == s[0] && m[1] == s[1]) {
                int l = 2;
                while (l < maxlen && m[l] == s[l]) l++;
                if (l > best) { best = l; found = (int)(cur - cand); if (l >= nice) break; }
            }
            int64_t nx = prev[(size_t)(cand & wmask)];
            if (nx >= cand) break;
            cand = nx;
        }
        if (!found) return MIN_MATCH - 1;
        dist_out = found;
        return best;
    }
    void header() {
        if (started) return;
        started = true;
        if (wrap == 1) {
            int cmf = ((wbits - 8) << 4) | 8;
            int lf = (strategy >= Z_HUFFMAN_ONLY || level < 2) ? 0 : level < 6 ? 1 : level == 6 ? 2 : 3;
            int flg = lf << 6;
            if (!dict.empty()) flg |= 0x20;
            flg += 31 - ((cmf << 8) + flg) % 31;
            w.put((uint32_t)cmf, 8);
            w.put((uint32_t)flg, 8);
            if (!dict.empty()) {
                uint32_t id = adler32((const uint8_t*)dict.data(), dict.size(), 1);
                for (int i = 3; i >= 0; i--) w.put((id >> (8 * i)) & 0xff, 8);
            }
        } else if (wrap == 2) {
            int xfl = level == 9 ? 2 : (strategy >= Z_HUFFMAN_ONLY || level < 2) ? 4 : 0;
            const uint8_t h[10] = {0x1f, 0x8b, 8, 0, 0, 0, 0, 0, (uint8_t)xfl, 3};
            for (uint8_t c : h) w.put(c, 8);
        }
    }
    inline void tally_lit(uint8_t c) { syms.push_back(c); tally_end++; }
    inline void tally_match(int len, int dist) { syms.push_back(mk_match(len, dist)); tally_end += len; }
    void flush_block(bool last) {
        const uint8_t* raw = &buf[(size_t)(block_start - base)];
        size_t rawlen = (size_t)(tally_end - block_start);
        if (level == 0) write_stored(w, raw, rawlen, last);
        else emit_block(w, syms, raw, rawlen, last, strategy == Z_FIXED ? 1 : 0);
        syms.clear();
        block_start = tally_end;
        slide();
    }
    void slide() {
        // keep a window of history before the next position and the block
        int64_t keep = std::min(block_start, pos) - wsize;
        if (keep - base > (int64_t)std::max<size_t>(65536, buf.size() / 2)) {
            buf.erase(buf.begin(), buf.begin() + (size_t)(keep - base));
            base = keep;
        }
    }
    bool block_full() const { return syms.size() >= lit_bufsize - 1; }

    void run(bool all) {
        int64_t e = end();
        if (level == 0) {
            pos = e;
            while (tally_end + 65535 <= e) {   // whole stored blocks as they fill
                write_stored(w, &buf[(size_t)(block_start - base)], 65535, false);
                tally_end += 65535;
                block_start = tally_end;
            }
            if (all) tally_end = e;
            slide();
            return;
        }
        if (strategy == Z_HUFFMAN_ONLY) {
            while (pos < e) {
                tally_lit(buf[(size_t)(pos - base)]);
                pos++;
                if (block_full()) flush_block(false);
            }
            return;
        }
        if (strategy == Z_RLE) {
            while (pos < e) {
                if (!all && e - pos < MIN_LOOKAHEAD) break;
                int len = 0;
                if (pos > base && pos - 1 >= block_start - wsize && e - pos >= MIN_MATCH) {
                    const uint8_t* s = &buf[(size_t)(pos - base)];
                    uint8_t c = s[-1];
                    int mx = (int)std::min<int64_t>(MAX_MATCH, e - pos);
                    while (len < mx && s[len] == c) len++;
                }
                if (len >= MIN_MATCH && pos > 0) { tally_match(len, 1); pos += len; }
                else { tally_lit(buf[(size_t)(pos - base)]); pos++; }
                if (block_full()) flush_block(false);
            }
            return;
        }
        if (cfg.fast) {
            while (pos < e) {
                if (!all && e - pos < MIN_LOOKAHEAD) break;
                int64_t cand = -1;
                if (e - pos >= MIN_MATCH) cand = insert(pos);
                int mlen = 0, mdist = 0;
                if (cand >= 0 && pos - cand <= max_dist) mlen = longest_match(pos, cand, MIN_MATCH - 1, mdist);
                if (mlen >= MIN_MATCH) {
                    tally_match(mlen, mdist);
                    if (mlen <= cfg.lazy && e - pos >= MIN_MATCH) {
                        for (int64_t p = pos + 1; p < pos + mlen; p++) if (e - p >= MIN_MATCH) insert(p);
                    }
                    pos += mlen;
                } else {
                    tally_lit(buf[(size_t)(pos - base)]);
                    pos++;
                }
                if (block_full()) flush_block(false);
            }
            return;
        }
        // lazy evaluation (zlib's deflate_slow)
        while (pos < e) {
            if (!all && e - pos < MIN_LOOKAHEAD) break;
            int64_t cand = -1;
            if (e - pos >= MIN_MATCH) cand = insert(pos);
            int prev_len = match_len, prev_dist = match_dist;
            match_len = MIN_MATCH - 1;
            if (cand >= 0 && prev_len < cfg.lazy && pos - cand <= max_dist) {
                int d = 0;
                match_len = longest_match(pos, cand, prev_len, d);
                if (match_len > prev_len) match_dist = d;
                else match_len = MIN_MATCH - 1;
                if (match_len <= 5 && (strategy == Z_FILTERED || (match_len == MIN_MATCH && match_dist > TOO_FAR)))
                    match_len = MIN_MATCH - 1;
            }
            if (prev_len >= MIN_MATCH && match_len <= prev_len) {
                tally_match(prev_len, prev_dist);
                int64_t stop = pos - 1 + prev_len;
                for (int64_t p = pos + 1; p < stop; p++) if (e - p >= MIN_MATCH) insert(p);
                match_avail = false;
                match_len = MIN_MATCH - 1;
                pos = stop;
                if (block_full()) flush_block(false);
            } else if (match_avail) {
                tally_lit(buf[(size_t)(pos - 1 - base)]);
                pos++;
                if (block_full()) flush_block(false);
            } else {
                match_avail = true;
                pos++;
            }
        }
        if (all && match_avail) {
            tally_lit(buf[(size_t)(pos - 1 - base)]);
            match_avail = false;
            match_len = MIN_MATCH - 1;
        }
    }
    void feed(const std::string& data) {
        header();
        if (!data.empty()) {
            if (wrap == 2) { check = crc32((const uint8_t*)data.data(), data.size(), check); isize += (uint32_t)data.size(); }
            else if (wrap == 1) check = adler32((const uint8_t*)data.data(), data.size(), check);
            buf.insert(buf.end(), data.begin(), data.end());
        }
        run(false);
    }
    void flush(int mode) {
        header();
        if (mode == Z_NO_FLUSH) return;
        run(true);
        if (mode == Z_FINISH) {
            flush_block(true);
            w.align();
            if (wrap == 1) for (int i = 3; i >= 0; i--) w.put((check >> (8 * i)) & 0xff, 8);
            else if (wrap == 2) {
                for (int i = 0; i < 4; i++) w.put((check >> (8 * i)) & 0xff, 8);
                for (int i = 0; i < 4; i++) w.put((isize >> (8 * i)) & 0xff, 8);
            }
            finished = true;
            return;
        }
        if (tally_end > block_start || !syms.empty()) flush_block(false);
        if (mode == Z_PARTIAL_FLUSH) {
            w.put(1 << 1, 3);                 // an empty fixed block
            w.put(0, 7);
        } else if (mode == Z_SYNC_FLUSH || mode == Z_FULL_FLUSH) {
            w.put(0, 3);                      // an empty stored block: byte aligned
            w.align();
            w.put(0, 16);
            w.put(0xffff, 16);
            if (mode == Z_FULL_FLUSH) {
                std::fill(head.begin(), head.end(), -1);
                match_avail = false;
                match_len = MIN_MATCH - 1;
            }
        }
    }
    std::string take() { std::string o; o.swap(w.out); return o; }
};

// ════════════════════════════════════════════════════════════════════════════
// Optimal parsing (Nython-only), after Zopfli
// ════════════════════════════════════════════════════════════════════════════
struct Optimal {
    const uint8_t* d = nullptr;
    int64_t n = 0;
    int wsize = 32768;
    int max_chain = 8192;
    // for every position: the shortest distance of each match length, kept
    // as runs (lengths up to `len` at distance `dist`)
    std::vector<uint32_t> off;
    struct Run { uint16_t len; uint16_t dist; };
    std::vector<Run> runs;

    void find_matches() {
        const int hbits = 16;
        std::vector<int64_t> head((size_t)1 << hbits, -1), prev((size_t)wsize, -1);
        off.assign((size_t)n + 1, 0);
        runs.clear();
        auto hash = [&](int64_t p) {
            return ((uint32_t)d[p] << 10 ^ (uint32_t)d[p + 1] << 5 ^ (uint32_t)d[p + 2]) * 2654435761u >> (32 - hbits);
        };
        int64_t max_dist = wsize - MIN_LOOKAHEAD;
        for (int64_t p = 0; p < n; p++) {
            off[(size_t)p] = (uint32_t)runs.size();
            if (n - p < MIN_MATCH) continue;
            uint32_t h = hash(p);
            int64_t cand = head[h];
            prev[(size_t)(p & (wsize - 1))] = cand;
            head[h] = p;
            int maxlen = (int)std::min<int64_t>(MAX_MATCH, n - p);
            int best = 2, chain = max_chain;
            // a run of one byte: the distance-1 match first (cheap to find, common)
            while (cand >= 0 && p - cand <= max_dist && chain-- > 0) {
                const uint8_t* m = d + cand;
                const uint8_t* s = d + p;
                if (m[best] == s[best]) {
                    int l = 0;
                    while (l < maxlen && m[l] == s[l]) l++;
                    if (l > best) {
                        runs.push_back({(uint16_t)l, (uint16_t)(p - cand)});
                        best = l;
                        if (l >= maxlen) break;
                    }
                }
                int64_t nx = prev[(size_t)(cand & (wsize - 1))];
                if (nx >= cand) break;
                cand = nx;
            }
        }
        off[(size_t)n] = (uint32_t)runs.size();
    }
    // costs in bits from symbol statistics
    struct Cost { float lit[288]; float dist[32]; };
    static void stats_cost(const uint32_t* lf, const uint32_t* df, Cost& c) {
        auto fill = [](const uint32_t* f, int k, float* out) {
            double total = 0;
            for (int i = 0; i < k; i++) total += f[i];
            double lt = total > 0 ? std::log2(total) : 0;
            for (int i = 0; i < k; i++) out[i] = (float)(f[i] ? lt - std::log2((double)f[i]) : lt + 1.0);
        };
        fill(lf, 286, c.lit);
        fill(df, 30, c.dist);
    }
    static void fixed_cost(Cost& c) {
        for (int i = 0; i < 288; i++) c.lit[i] = i < 144 ? 8.f : i < 256 ? 9.f : i < 280 ? 7.f : 8.f;
        for (int i = 0; i < 32; i++) c.dist[i] = 5.f;
    }
    // the cheapest parse of [from, to) under cost c (matches may reach back
    // before `from`, never past `to`)
    void parse(int64_t from, int64_t to, const Cost& c, std::vector<uint32_t>& out) {
        size_t m = (size_t)(to - from);
        std::vector<float> cost(m + 1, 1e30f);
        std::vector<uint32_t> choice(m + 1, 0);
        float lc[259];
        for (int l = 3; l <= 258; l++) { int k = lcode(l); lc[l] = c.lit[257 + k] + LEXT[k]; }
        cost[0] = 0;
        for (size_t i = 0; i < m; i++) {
            float ci = cost[i];
            if (ci >= 1e29f) continue;
            int64_t p = from + (int64_t)i;
            float lit = ci + c.lit[d[p]];
            if (lit < cost[i + 1]) { cost[i + 1] = lit; choice[i + 1] = d[p]; }
            int prevlen = 2;
            size_t room = m - i;
            for (uint32_t r = off[(size_t)p]; r < off[(size_t)p + 1]; r++) {
                int len = runs[r].len, dist = runs[r].dist;
                int dc = dcode(dist);
                float dcost = c.dist[dc] + DEXT[dc];
                int hi = (int)std::min<size_t>((size_t)len, room);
                for (int l = prevlen + 1; l <= hi; l++) {
                    float v = ci + lc[l] + dcost;
                    if (v < cost[i + l]) { cost[i + l] = v; choice[i + l] = mk_match(l, dist); }
                }
                prevlen = len;
                if (prevlen >= (int)room) break;
            }
        }
        out.clear();
        size_t i = m;
        while (i > 0) {
            uint32_t s = choice[i];
            out.push_back(s);
            i -= is_match(s) ? (size_t)s_len(s) : 1;
        }
        std::reverse(out.begin(), out.end());
    }
    static uint64_t block_bits(const uint32_t* syms, size_t k) {
        uint32_t lf[288], df[32];
        count_freqs(syms, k, lf, df);
        DynTrees t;
        build_dyn(lf, df, t);
        uint64_t dyn = 3 + t.header_bits + data_bits(lf, df, t.ll, t.dl);
        uint8_t fdl[32];
        for (auto& x : fdl) x = 5;
        uint64_t fix = 3 + data_bits(lf, df, fixed_ll(), fdl);
        return std::min(dyn, fix);
    }
    // the parse of [from, to): iterated shortest paths, the best kept
    void optimal_range(int64_t from, int64_t to, int iterations, std::vector<uint32_t>& best,
                       const std::vector<uint32_t>& start) {
        Cost c;
        uint32_t lf[288], df[32];
        std::vector<uint32_t> cur;
        uint64_t best_bits = UINT64_MAX;
        if (!start.empty()) {
            best = start;
            best_bits = block_bits(best.data(), best.size());
            count_freqs(start.data(), start.size(), lf, df);
            stats_cost(lf, df, c);
        } else fixed_cost(c);
        uint32_t last_lf[288], last_df[32];
        std::memcpy(last_lf, lf, sizeof lf);
        std::memcpy(last_df, df, sizeof df);
        uint64_t last_bits = UINT64_MAX;
        for (int it = 0; it < iterations; it++) {
            parse(from, to, c, cur);
            uint64_t b = block_bits(cur.data(), cur.size());
            if (b < best_bits) { best_bits = b; best = cur; }
            count_freqs(cur.data(), cur.size(), lf, df);
            if (b >= last_bits) {
                // no progress: blend in the last statistics (Zopfli's
                // weighted stats) to leave the local minimum
                for (int i = 0; i < 288; i++) lf[i] = lf[i] + last_lf[i] / 2;
                for (int i = 0; i < 32; i++) df[i] = df[i] + last_df[i] / 2;
            }
            std::memcpy(last_lf, lf, sizeof lf);
            std::memcpy(last_df, df, sizeof df);
            last_bits = b;
            stats_cost(lf, df, c);
        }
    }
    // symbols -> byte lengths
    static std::vector<size_t> byte_offsets(const std::vector<uint32_t>& syms) {
        std::vector<size_t> o(syms.size() + 1, 0);
        for (size_t i = 0; i < syms.size(); i++) o[i + 1] = o[i] + (is_match(syms[i]) ? (size_t)s_len(syms[i]) : 1);
        return o;
    }
    // Zopfli's block splitting: the split point that lowers the cost most,
    // found by narrowing a grid, recursively, while it pays.
    void split(const std::vector<uint32_t>& syms, size_t lo, size_t hi, std::vector<size_t>& points, int depth) {
        if (depth > 6 || hi - lo < 512) return;
        uint64_t whole = block_bits(syms.data() + lo, hi - lo);
        size_t a = lo + 1, b = hi - 1, best_at = 0;
        uint64_t best = whole;
        for (int round = 0; round < 6 && b > a + 8; round++) {
            const int K = 9;
            size_t step = (b - a) / (K + 1);
            if (!step) break;
            size_t bp = 0; uint64_t bv = UINT64_MAX;
            for (int k = 1; k <= K; k++) {
                size_t s = a + step * (size_t)k;
                uint64_t v = block_bits(syms.data() + lo, s - lo) + block_bits(syms.data() + s, hi - s);
                if (v < bv) { bv = v; bp = s; }
            }
            if (bv < best) { best = bv; best_at = bp; }
            a = bp > step ? bp - step : a;
            b = std::min(bp + step, hi - 1);
        }
        if (!best_at || best + 64 >= whole) return;
        split(syms, lo, best_at, points, depth + 1);
        points.push_back(best_at);
        split(syms, best_at, hi, points, depth + 1);
    }
    std::string compress(int iterations, bool splitting) {
        BitOut w;
        find_matches();
        // a first parse with level 9's lazy matcher
        Deflater lz;
        lz.init(9, -15, 9, 0);
        lz.lit_bufsize = SIZE_MAX;
        lz.buf.assign(d, d + n);
        lz.run(true);
        std::vector<uint32_t> greedy = lz.syms;
        std::vector<size_t> points;
        if (splitting) split(greedy, 0, greedy.size(), points, 0);
        std::vector<size_t> goff = byte_offsets(greedy);
        std::vector<int64_t> cuts{0};
        for (size_t p : points) cuts.push_back((int64_t)goff[p]);
        cuts.push_back(n);
        size_t gi = 0;
        for (size_t bi = 0; bi + 1 < cuts.size(); bi++) {
            int64_t from = cuts[bi], to = cuts[bi + 1];
            std::vector<uint32_t> start;
            while (gi < greedy.size() && (int64_t)goff[gi] < to) start.push_back(greedy[gi++]);
            std::vector<uint32_t> best;
            optimal_range(from, to, iterations, best, start);
            emit_block(w, best, d + from, (size_t)(to - from), bi + 2 == cuts.size(), 0);
        }
        w.align();
        return w.out;
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Handles
// ════════════════════════════════════════════════════════════════════════════
struct Obj {
    bool is_deflate = true;
    Deflater c;
    Inflater dd;
    bool ended = false;
};
std::mutex& mu() { static std::mutex* m = new std::mutex(); return *m; }
std::unordered_map<int64_t, std::unique_ptr<Obj>>& table() {
    static auto* t = new std::unordered_map<int64_t, std::unique_ptr<Obj>>();
    return *t;
}
int64_t g_next = 1;

} // namespace nyz

// round 84: a zlib stream inflated, for other natives' compressed tables
// (builtins/nycjk.cpp's CJK mapping tables)
std::string nyz_inflate(const std::string& data) {
    nyz::Inflater f;
    f.wrap = 1;
    f.start();
    f.in = data;
    std::string out;
    f.run(out, 0);
    return out;
}

namespace {

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

// zlib.error, with CPython's text ("Error -3 while decompressing data: ...")
[[noreturn]] void zerr(const nyz::ZError& e, const char* doing) {
    std::string m = "[zlib] Error " + std::to_string(e.code) + " while " + doing;
    if (e.msg == "\x01zdict") m = "[zlib] Error -3 while setting zdict: invalid input data";
    else if (!e.msg.empty()) m += ": " + e.msg;
    fail("ValueError", m);
}

std::string bytes_arg(NythonExecutor& E, const Value& v) {
    if (auto* bo = E.bytesOf(v)) return bo->s;
    fail("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}

int64_t int_arg(const Value& v, const char* what) {
    if (v.type == ValueType::INTEGER || v.type == ValueType::BOOLEAN) return (int64_t)nyos::to_int(v, 0);
    fail("TypeError", std::string("'") + what + "' must be an integer");
}

nyz::Obj* get(int64_t h) {
    auto it = nyz::table().find(h);
    if (it == nyz::table().end()) fail("ValueError", "invalid zlib object");
    return it->second.get();
}
int64_t store(std::unique_ptr<nyz::Obj> o) {
    int64_t id = nyz::g_next++;
    nyz::table()[id] = std::move(o);
    return id;
}
// inflate's wrapper and window from wbits (zlib's inflateReset2); false when invalid
bool inflate_mode(int64_t wbits, int& wrap, int& wb) {
    if (wbits < 0) {
        if (wbits < -15) return false;
        wrap = 0; wb = (int)-wbits;
    } else {
        int w = (int)(wbits >> 4) + 5;
        wb = (int)wbits;
        if (wbits < 48) wb &= 15;
        wrap = (w & 1 ? 1 : 0) | (w & 2 ? 2 : 0);   // 5: zlib, 6: gzip, 7: both
        if (wbits >= 48) return false;
    }
    if (wb && (wb < 8 || wb > 15)) return false;
    return true;
}

Value result4(NythonExecutor& E, const std::string& out, const std::string& tail, const std::string& unused, bool eof) {
    std::vector<Value> v{E.makeBytesValue(out), E.makeBytesValue(tail), E.makeBytesValue(unused), Value(eof)};
    return E.makeListValue(v);
}

} // namespace

std::vector<std::string> zlib_builtin_names() {
    return {"_zlib_compress", "_zlib_decompress", "_zlib_cnew", "_zlib_ccompress", "_zlib_cflush", "_zlib_dnew",
            "_zlib_ddecompress", "_zlib_dflush", "_zlib_copy", "_zlib_free", "_zlib_crc32", "_zlib_adler32",
            "_zlib_crc_hqx", "_zlib_optimal"};
}

Value dispatch_zlib(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name.compare(0, 6, "_zlib_") != 0) return UNDEFINED_VALUE;
    auto arg = [&](size_t i) -> const Value& {
        if (i >= args.size()) fail("TypeError", name + "(): missing argument");
        return args[i];
    };
    if (name == "_zlib_crc32" || name == "_zlib_adler32" || name == "_zlib_crc_hqx") {
        std::string d = bytes_arg(E, arg(0));
        // (lib/zlib.ny masks the value to 32 bits first, as CPython's 'I')
        uint64_t v = args.size() > 1 ? (uint64_t)int_arg(args[1], "value") : name == "_zlib_adler32" ? 1 : 0;
        const uint8_t* p = (const uint8_t*)d.data();
        if (name == "_zlib_crc32") return Value((int64_t)nyz::crc32(p, d.size(), (uint32_t)v));
        if (name == "_zlib_adler32") return Value((int64_t)nyz::adler32(p, d.size(), (uint32_t)v));
        return Value((int64_t)nyz::crc_hqx(p, d.size(), (uint32_t)v));
    }
    if (name == "_zlib_compress") {
        std::string d = bytes_arg(E, arg(0));
        nyz::Deflater c;
        if (!c.init((int)int_arg(arg(1), "level"), (int)int_arg(arg(2), "wbits"), 8, 0))
            fail("ValueError", "[zlib] Bad compression level");
        c.feed(d);
        c.flush(nyz::Z_FINISH);
        return E.makeBytesValue(c.take());
    }
    if (name == "_zlib_optimal") {
        std::string d = bytes_arg(E, arg(0));
        int64_t iters = int_arg(arg(1), "iterations");
        int64_t wbits = int_arg(arg(2), "wbits");
        bool split = args.size() > 3 ? E.isTruthy(args[3]) : true;
        if (iters < 1) fail("ValueError", "iterations must be at least 1");
        nyz::Deflater hdr;
        if (!hdr.init(9, (int)wbits, 8, 0)) fail("ValueError", "[zlib] Bad compression level");
        nyz::Optimal o;
        o.d = (const uint8_t*)d.data();
        o.n = (int64_t)d.size();
        o.wsize = 1 << hdr.wbits;
        std::string raw = o.compress((int)std::min<int64_t>(iters, 1000), split);
        hdr.header();
        std::string out = hdr.take();
        out += raw;
        if (hdr.wrap == 1) {
            uint32_t a = nyz::adler32((const uint8_t*)d.data(), d.size(), 1);
            for (int i = 3; i >= 0; i--) out.push_back((char)((a >> (8 * i)) & 0xff));
        } else if (hdr.wrap == 2) {
            uint32_t c = nyz::crc32((const uint8_t*)d.data(), d.size(), 0), s = (uint32_t)d.size();
            for (int i = 0; i < 4; i++) out.push_back((char)((c >> (8 * i)) & 0xff));
            for (int i = 0; i < 4; i++) out.push_back((char)((s >> (8 * i)) & 0xff));
        }
        return E.makeBytesValue(out);
    }
    if (name == "_zlib_decompress") {
        std::string d = bytes_arg(E, arg(0));
        int64_t wbits = int_arg(arg(1), "wbits");
        if (args.size() > 2 && int_arg(args[2], "bufsize") < 0) fail("ValueError", "bufsize must be non-negative");
        nyz::Inflater f;
        if (!inflate_mode(wbits, f.wrap, f.wbits))
            fail("ValueError", "[zlib] Error -2 while preparing to decompress data: inconsistent stream state");
        f.start();
        f.in = std::move(d);
        std::string out;
        try { f.run(out, 0); } catch (nyz::ZError& e) { zerr(e, "decompressing data"); }
        if (f.st != nyz::Inflater::DONE)
            fail("ValueError", "[zlib] Error -5 while decompressing data: incomplete or truncated stream");
        return E.makeBytesValue(out);
    }
    if (name == "_zlib_cnew") {
        int level = (int)int_arg(arg(0), "level");
        int method = (int)int_arg(arg(1), "method");
        int wbits = (int)int_arg(arg(2), "wbits");
        int mem = (int)int_arg(arg(3), "memLevel");
        int strat = (int)int_arg(arg(4), "strategy");
        auto o = std::make_unique<nyz::Obj>();
        if (method != 8 || !o->c.init(level, wbits, mem, strat)) fail("ValueError", "Invalid initialization option");
        if (args.size() > 5 && args[5].type != ValueType::NONE) {
            if (!E.bytesOf(args[5])) fail("TypeError", "zdict argument must support the buffer protocol");
            o->c.set_dict(bytes_arg(E, args[5]));
        }
        std::lock_guard<std::mutex> l(nyz::mu());
        return Value(store(std::move(o)));
    }
    if (name == "_zlib_ccompress") {
        std::string d = bytes_arg(E, arg(1));
        std::lock_guard<std::mutex> l(nyz::mu());
        nyz::Obj* o = get(int_arg(arg(0), "h"));
        if (o->c.finished) fail("ValueError", "[zlib] Error -2 while compressing data: inconsistent stream state");
        o->c.feed(d);
        return E.makeBytesValue(o->c.take());
    }
    if (name == "_zlib_cflush") {
        int64_t mode = int_arg(arg(1), "mode");
        std::lock_guard<std::mutex> l(nyz::mu());
        nyz::Obj* o = get(int_arg(arg(0), "h"));
        if (mode == nyz::Z_NO_FLUSH) return E.makeBytesValue("");
        if (o->c.finished) fail("ValueError", "[zlib] Error -2 while flushing: inconsistent stream state");
        if (mode < 0 || mode > 6) fail("ValueError", "[zlib] Error -2 while flushing: inconsistent stream state");
        o->c.flush((int)mode);
        return E.makeBytesValue(o->c.take());
    }
    if (name == "_zlib_dnew") {
        int64_t wbits = int_arg(arg(0), "wbits");
        auto o = std::make_unique<nyz::Obj>();
        o->is_deflate = false;
        if (!inflate_mode(wbits, o->dd.wrap, o->dd.wbits)) fail("ValueError", "Invalid initialization option");
        if (args.size() > 1 && args[1].type != ValueType::NONE) {
            if (!E.bytesOf(args[1])) fail("TypeError", "zdict argument must support the buffer protocol");
            o->dd.dict = bytes_arg(E, args[1]);
        }
        o->dd.start();
        std::lock_guard<std::mutex> l(nyz::mu());
        return Value(store(std::move(o)));
    }
    if (name == "_zlib_ddecompress" || name == "_zlib_dflush") {
        bool flush = name == "_zlib_dflush";
        std::string d = bytes_arg(E, arg(1));
        int64_t lim = int_arg(arg(2), flush ? "length" : "max_length");
        if (flush && lim <= 0) fail("ValueError", "length must be greater than zero");
        if (!flush && lim < 0) fail("ValueError", "max_length must be non-negative");
        std::lock_guard<std::mutex> l(nyz::mu());
        nyz::Obj* o = get(int_arg(arg(0), "h"));
        nyz::Inflater& f = o->dd;
        std::string out, tail, unused;
        if (f.st == nyz::Inflater::DONE) {
            // after the end of the stream, data only adds to unused_data
            return result4(E, out, std::string(), d, true);
        }
        f.in += d;
        try { f.run(out, flush ? 0 : (size_t)lim); }
        catch (nyz::ZError& e) { f.in.clear(); f.ip = 0; zerr(e, "decompressing data"); }
        bool eof = f.st == nyz::Inflater::DONE;
        if (eof) unused = f.take_unused();
        else if (!flush && lim > 0 && out.size() >= (size_t)lim) { tail = f.in.substr(f.ip); f.in.clear(); f.ip = 0; }
        return result4(E, out, tail, unused, eof);
    }
    if (name == "_zlib_copy") {
        std::lock_guard<std::mutex> l(nyz::mu());
        nyz::Obj* o = get(int_arg(arg(0), "h"));
        if (o->is_deflate && o->c.finished) fail("ValueError", "Inconsistent stream state");
        auto c = std::make_unique<nyz::Obj>(*o);
        return Value(store(std::move(c)));
    }
    if (name == "_zlib_free") {
        std::lock_guard<std::mutex> l(nyz::mu());
        nyz::table().erase(int_arg(arg(0), "h"));
        return NONE_VALUE;
    }
    return UNDEFINED_VALUE;
}
