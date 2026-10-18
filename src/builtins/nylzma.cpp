// builtins/nylzma.cpp - LZMA for lib/lzma.ny (round 83).
//
// liblzma (XZ Utils) is loaded at run time - dlopen / LoadLibrary, nothing at
// build or link time, as builtins/tls.cpp loads OpenSSL (NY_LIBLZMA names a
// library to try first). With it every format, check and filter of
// CPython's _lzma module works, through the same calls CPython makes
// (lzma_easy_encoder / lzma_stream_encoder / lzma_alone_encoder /
// lzma_raw_encoder, lzma_auto_decoder / lzma_stream_decoder /
// lzma_alone_decoder / lzma_raw_decoder, lzma_properties_encode/decode).
//
// Without it (the innovation of this module): a native decoder, written
// here after the LZMA specification (Igor Pavlov's LZMA SDK, lzma-specification
// / LzmaSpec.cpp, and the .xz file format 1.1.0) - the range decoder, the
// LZMA1 literal/match/rep coder with its adaptive bit models, LZMA2's chunks
// (dictionary and state resets, uncompressed chunks), the .xz container
// (stream header and footer, block headers, the index - checked against the
// blocks - and the CRC32/CRC64/SHA-256 checks) and the delta filter - so
// .xz and .lzma data reads everywhere. It is resumable at any input
// boundary: a whole LZMA2 chunk is decoded once its bytes are in (chunks
// carry their packed size); LZMA1 (.lzma, raw) decodes symbol by symbol while
// 64 bytes of input are ahead and finishes the tail from a snapshot it rolls
// back to when the input runs out. Compression needs liblzma (an LZMAError
// names it).
//
//   _lzma_has_lib() -> bool             _lzma_lib_error() -> str
//   _lzma_check_supported(check) -> bool
//   _lzma_cnew(format, check, preset, filters) -> h       (filters: none or specs)
//   _lzma_compress(h, data) -> bytes   _lzma_flush(h) -> bytes
//   _lzma_dnew(format, memlimit, filters) -> h
//   _lzma_decompress(h, data, max_length) -> [out, eof, unused, needs_input, check]
//   _lzma_free(h)
//   _lzma_encode_props(spec) -> bytes  _lzma_decode_props(id, props) -> spec
// A filter spec is a list: [id, preset, dict_size, lc, lp, pb, mode, nice_len,
// mf, depth] for LZMA1/LZMA2 (-1: not given), [id, dist] for delta,
// [id, start_offset] for the BCJ filters. lib/lzma.ny turns Python's dicts
// into these. Errors are raised as ValueError("\x01lzma <message>"), which
// lib/lzma.ny turns into LZMAError; MemoryError and argument errors as CPython.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyHash.hpp"
#include "NyConc.hpp"
#include "builtins/os.hpp"
#include "builtins/sysmods.hpp"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>
#ifdef _WIN32
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

namespace {

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }
[[noreturn]] void lzerr(const std::string& msg) { nyos::raise("ValueError", "\x01lzma " + msg); }

// ── liblzma's ABI (lzma/base.h, lzma12.h, delta.h, bcj.h, filter.h) ─────────
struct lz_stream {
    const uint8_t* next_in = nullptr; size_t avail_in = 0; uint64_t total_in = 0;
    uint8_t* next_out = nullptr; size_t avail_out = 0; uint64_t total_out = 0;
    const void* allocator = nullptr; void* internal = nullptr;
    void* rp1 = nullptr; void* rp2 = nullptr; void* rp3 = nullptr; void* rp4 = nullptr;
    uint64_t seek_pos = 0; uint64_t ri2 = 0; size_t ri3 = 0; size_t ri4 = 0;
    int re1 = 0; int re2 = 0;
};
struct lz_options_lzma {
    uint32_t dict_size; const uint8_t* preset_dict; uint32_t preset_dict_size;
    uint32_t lc, lp, pb; int mode; uint32_t nice_len; int mf; uint32_t depth;
    uint32_t ext_flags, ext_size_low, ext_size_high;
    uint32_t ri4, ri5, ri6, ri7, ri8; int re1, re2, re3, re4; void* rp1; void* rp2;
};
struct lz_options_delta { int type; uint32_t dist; uint32_t r1, r2, r3, r4; void* p1; void* p2; };
struct lz_options_bcj { uint32_t start_offset; };
struct lz_filter { uint64_t id; void* options; };

const uint64_t F_LZMA1 = 0x4000000000000001ULL, F_LZMA2 = 0x21, F_DELTA = 0x03;
const uint64_t VLI_UNKNOWN = ~0ULL;
enum { LZ_OK = 0, LZ_STREAM_END = 1, LZ_NO_CHECK = 2, LZ_UNSUPPORTED_CHECK = 3, LZ_GET_CHECK = 4,
       LZ_MEM_ERROR = 5, LZ_MEMLIMIT_ERROR = 6, LZ_FORMAT_ERROR = 7, LZ_OPTIONS_ERROR = 8,
       LZ_DATA_ERROR = 9, LZ_BUF_ERROR = 10, LZ_PROG_ERROR = 11 };
enum { FORMAT_AUTO = 0, FORMAT_XZ = 1, FORMAT_ALONE = 2, FORMAT_RAW = 3 };
const int CHECK_NONE = 0, CHECK_CRC32 = 1, CHECK_CRC64 = 4, CHECK_SHA256 = 10, CHECK_UNKNOWN = 16;

struct Api {
    bool tried = false, ok = false;
    std::string why;
    void* lib = nullptr;
    const char* (*version_string)() = nullptr;
    int (*easy_encoder)(lz_stream*, uint32_t, int) = nullptr;
    int (*stream_encoder)(lz_stream*, const lz_filter*, int) = nullptr;
    int (*alone_encoder)(lz_stream*, const lz_options_lzma*) = nullptr;
    int (*raw_encoder)(lz_stream*, const lz_filter*) = nullptr;
    int (*auto_decoder)(lz_stream*, uint64_t, uint32_t) = nullptr;
    int (*stream_decoder)(lz_stream*, uint64_t, uint32_t) = nullptr;
    int (*alone_decoder)(lz_stream*, uint64_t) = nullptr;
    int (*raw_decoder)(lz_stream*, const lz_filter*) = nullptr;
    int (*code)(lz_stream*, int) = nullptr;
    void (*end)(lz_stream*) = nullptr;
    int (*get_check)(const lz_stream*) = nullptr;
    unsigned char (*check_is_supported)(int) = nullptr;
    unsigned char (*lzma_preset)(lz_options_lzma*, uint32_t) = nullptr;
    int (*properties_size)(uint32_t*, const lz_filter*) = nullptr;
    int (*properties_encode)(const lz_filter*, uint8_t*) = nullptr;
    int (*properties_decode)(lz_filter*, const void*, const uint8_t*, size_t) = nullptr;
};

Api& api() {
    static Api a;
    static std::mutex m;
    std::lock_guard<std::mutex> l(m);
    if (a.tried) return a;
    a.tried = true;
    std::vector<std::string> names;
    if (const char* e = std::getenv("NY_LIBLZMA")) if (*e) names.push_back(e);
    if (const char* e = std::getenv("NY_NO_LIBLZMA")) if (*e && std::string(e) != "0") {
        a.why = "liblzma disabled by NY_NO_LIBLZMA";
        return a;
    }
#ifdef _WIN32
    for (const char* n : {"liblzma.dll", "liblzma-5.dll", "lzma.dll"}) names.push_back(n);
#elif defined(__APPLE__)
    for (const char* n : {"liblzma.5.dylib", "liblzma.dylib", "/opt/homebrew/lib/liblzma.5.dylib",
                          "/usr/local/lib/liblzma.5.dylib"}) names.push_back(n);
#else
    for (const char* n : {"liblzma.so.5", "liblzma.so"}) names.push_back(n);
#endif
    for (auto& n : names) {
#ifdef _WIN32
        a.lib = (void*)LoadLibraryA(n.c_str());
#else
        a.lib = dlopen(n.c_str(), RTLD_NOW | RTLD_LOCAL);
#endif
        if (a.lib) break;
    }
    if (!a.lib) {
        a.why = "liblzma (XZ Utils) is not installed";
        return a;
    }
    auto sym = [&](const char* n) -> void* {
#ifdef _WIN32
        return (void*)GetProcAddress((HMODULE)a.lib, n);
#else
        return dlsym(a.lib, n);
#endif
    };
    bool ok = true;
#define S(field, name) do { *(void**)&a.field = sym(name); if (!a.field) ok = false; } while (0)
    S(version_string, "lzma_version_string");
    S(easy_encoder, "lzma_easy_encoder");
    S(stream_encoder, "lzma_stream_encoder");
    S(alone_encoder, "lzma_alone_encoder");
    S(raw_encoder, "lzma_raw_encoder");
    S(auto_decoder, "lzma_auto_decoder");
    S(stream_decoder, "lzma_stream_decoder");
    S(alone_decoder, "lzma_alone_decoder");
    S(raw_decoder, "lzma_raw_decoder");
    S(code, "lzma_code");
    S(end, "lzma_end");
    S(get_check, "lzma_get_check");
    S(check_is_supported, "lzma_check_is_supported");
    S(lzma_preset, "lzma_lzma_preset");
    S(properties_size, "lzma_properties_size");
    S(properties_encode, "lzma_properties_encode");
    S(properties_decode, "lzma_properties_decode");
#undef S
    if (!ok) { a.why = "liblzma is too old (a function is missing)"; return a; }
    a.ok = true;
    return a;
}

[[noreturn]] void lib_error(int ret) {
    switch (ret) {
    case LZ_UNSUPPORTED_CHECK: lzerr("Unsupported integrity check");
    case LZ_MEM_ERROR: fail("MemoryError", "");
    case LZ_MEMLIMIT_ERROR: lzerr("Memory usage limit exceeded");
    case LZ_FORMAT_ERROR: lzerr("Input format not supported by decoder");
    case LZ_OPTIONS_ERROR: lzerr("Invalid or unsupported options");
    case LZ_DATA_ERROR: lzerr("Corrupt input data");
    case LZ_BUF_ERROR: lzerr("Insufficient buffer space");
    case LZ_PROG_ERROR: lzerr("Internal error");
    default: lzerr("Unrecognized error from liblzma: " + std::to_string(ret));
    }
}

// The filter chain a spec list describes, with its options kept alive.
struct Chain {
    std::vector<lz_filter> f;
    std::vector<std::unique_ptr<lz_options_lzma>> lz;
    std::vector<std::unique_ptr<lz_options_delta>> de;
    std::vector<std::unique_ptr<lz_options_bcj>> bc;
};
int64_t spec_int(NythonExecutor& E, const std::vector<Value>& s, size_t i) {
    (void)E;
    if (i >= s.size()) return -1;
    return (int64_t)nyos::to_int(s[i], -1);
}
void build_chain(NythonExecutor& E, const Value& filters, Chain& c) {
    Api& a = api();
    std::vector<Value> items = E.iterItems(filters, E.globalContext());
    if (items.size() > 4) fail("ValueError", "Too many filters - liblzma supports a maximum of 4");
    for (auto& it : items) {
        std::vector<Value> s = E.iterItems(it, E.globalContext());
        uint64_t id = (uint64_t)nyos::to_int(s[0], 0);
        lz_filter f;
        f.id = id;
        if (id == F_LZMA1 || id == F_LZMA2) {
            auto o = std::make_unique<lz_options_lzma>();
            std::memset(o.get(), 0, sizeof *o);
            int64_t preset = spec_int(E, s, 1);
            if (preset < 0) preset = 6;
            if (a.lzma_preset(o.get(), (uint32_t)preset)) lzerr("Invalid compression preset: " + std::to_string(preset));
            int64_t v;
            if ((v = spec_int(E, s, 2)) >= 0) o->dict_size = (uint32_t)v;
            if ((v = spec_int(E, s, 3)) >= 0) o->lc = (uint32_t)v;
            if ((v = spec_int(E, s, 4)) >= 0) o->lp = (uint32_t)v;
            if ((v = spec_int(E, s, 5)) >= 0) o->pb = (uint32_t)v;
            if ((v = spec_int(E, s, 6)) >= 0) o->mode = (int)v;
            if ((v = spec_int(E, s, 7)) >= 0) o->nice_len = (uint32_t)v;
            if ((v = spec_int(E, s, 8)) >= 0) o->mf = (int)v;
            if ((v = spec_int(E, s, 9)) >= 0) o->depth = (uint32_t)v;
            f.options = o.get();
            c.lz.push_back(std::move(o));
        } else if (id == F_DELTA) {
            auto o = std::make_unique<lz_options_delta>();
            std::memset(o.get(), 0, sizeof *o);
            int64_t d = spec_int(E, s, 1);
            o->dist = d < 0 ? 1 : (uint32_t)d;
            f.options = o.get();
            c.de.push_back(std::move(o));
        } else if (id >= 0x04 && id <= 0x0B) {
            auto o = std::make_unique<lz_options_bcj>();
            int64_t d = spec_int(E, s, 1);
            o->start_offset = d < 0 ? 0 : (uint32_t)d;
            f.options = o.get();
            c.bc.push_back(std::move(o));
        } else {
            fail("ValueError", "Invalid filter ID: " + std::to_string(id));
        }
        c.f.push_back(f);
    }
    c.f.push_back(lz_filter{VLI_UNKNOWN, nullptr});
}

// ── checksums for the fallback decoder ──────────────────────────────────────
uint32_t g_crc32[256];
uint64_t g_crc64[256];
std::once_flag g_crc_once;
void crc_tables() {
    std::call_once(g_crc_once, [] {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
            g_crc32[i] = c;
            uint64_t d = i;
            for (int k = 0; k < 8; k++) d = (d & 1) ? (d >> 1) ^ 0xC96C5795D7870F42ULL : d >> 1;
            g_crc64[i] = d;
        }
    });
}
uint32_t crc32(const uint8_t* p, size_t n, uint32_t crc = 0) {
    crc = ~crc;
    for (size_t i = 0; i < n; i++) crc = g_crc32[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}
uint64_t crc64(const uint8_t* p, size_t n, uint64_t crc = 0) {
    crc = ~crc;
    for (size_t i = 0; i < n; i++) crc = g_crc64[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

struct Corrupt { std::string msg; };
struct Short {};
[[noreturn]] void corrupt() { throw Corrupt{"Corrupt input data"}; }

// ── the LZMA1 decoder (LzmaSpec.cpp's model) ────────────────────────────────
struct Window {
    std::string buf;          // the history (and what is not yet filtered out)
    uint64_t base = 0;        // total position of buf[0]
    uint64_t dict_start = 0;  // the last dictionary reset
    uint32_t dict_size = 1 << 23;
    uint64_t total() const { return base + buf.size(); }
    void trim(uint64_t keep_from) {
        // drop history no match can reach and the filter has taken
        uint64_t min_keep = total() > dict_size ? total() - dict_size : 0;
        uint64_t cut = std::min(keep_from, min_keep);
        if (cut > base && cut - base > (uint64_t)4 * 1024 * 1024) {
            buf.erase(0, (size_t)(cut - base));
            base = cut;
        }
    }
};

struct Lzma1 {
    uint32_t lc = 3, lp = 0, pb = 2;
    std::vector<uint16_t> lit;
    uint16_t isMatch[192], isRep[12], isRepG0[12], isRepG1[12], isRepG2[12], isRep0Long[192];
    uint16_t posSlot[4][64], posDec[115], align[16];
    struct Len { uint16_t choice, choice2, low[16][8], mid[16][8], high[256]; } lenDec, repLenDec;
    uint32_t state = 0, rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0;
    uint32_t range = 0, code = 0;
    const uint8_t* in = nullptr;
    size_t in_size = 0, pos = 0;
    Window* w = nullptr;
    bool eopm = false;     // the end marker was read

    static void init_probs(uint16_t* p, size_t n) { for (size_t i = 0; i < n; i++) p[i] = 1024; }
    void set_props(uint32_t lc_, uint32_t lp_, uint32_t pb_) { lc = lc_; lp = lp_; pb = pb_; }
    void reset_state() {
        lit.assign((size_t)0x300 << (lc + lp), 1024);
        init_probs(isMatch, 192); init_probs(isRep, 12); init_probs(isRepG0, 12); init_probs(isRepG1, 12);
        init_probs(isRepG2, 12); init_probs(isRep0Long, 192); init_probs(&posSlot[0][0], 256);
        init_probs(posDec, 115); init_probs(align, 16);
        init_probs((uint16_t*)&lenDec, sizeof(Len) / 2); init_probs((uint16_t*)&repLenDec, sizeof(Len) / 2);
        state = rep0 = rep1 = rep2 = rep3 = 0;
        eopm = false;
    }
    inline uint8_t byte() {
        if (pos >= in_size) throw Short();
        return in[pos++];
    }
    void rc_init() {
        if (byte() != 0) corrupt();
        code = 0;
        range = 0xFFFFFFFFu;
        for (int i = 0; i < 4; i++) code = (code << 8) | byte();
        if (code == range) corrupt();
    }
    inline void normalize() {
        if (range < (1u << 24)) { range <<= 8; code = (code << 8) | byte(); }
    }
    inline uint32_t bit(uint16_t& p) {
        uint32_t bound = (range >> 11) * p;
        uint32_t r;
        if (code < bound) { p = (uint16_t)(p + ((2048 - p) >> 5)); range = bound; r = 0; }
        else { p = (uint16_t)(p - (p >> 5)); code -= bound; range -= bound; r = 1; }
        normalize();
        return r;
    }
    uint32_t direct(int n) {
        uint32_t res = 0;
        do {
            range >>= 1;
            code -= range;
            uint32_t t = 0 - (code >> 31);
            code += range & t;
            if (code == range) corrupt();
            normalize();
            res = (res << 1) + (t + 1);
        } while (--n);
        return res;
    }
    uint32_t tree(uint16_t* p, int n) {
        uint32_t m = 1;
        for (int i = 0; i < n; i++) m = (m << 1) + bit(p[m]);
        return m - (1u << n);
    }
    uint32_t rtree(uint16_t* p, int n) {
        uint32_t m = 1, sym = 0;
        for (int i = 0; i < n; i++) { uint32_t b = bit(p[m]); m = (m << 1) + b; sym |= b << i; }
        return sym;
    }
    uint32_t len(Len& L, uint32_t ps) {
        if (!bit(L.choice)) return tree(L.low[ps], 3);
        if (!bit(L.choice2)) return 8 + tree(L.mid[ps], 3);
        return 16 + tree(L.high, 8);
    }
    inline uint8_t back(uint32_t dist) const {   // the byte dist+1 back
        return (uint8_t)w->buf[w->buf.size() - dist - 1];
    }
    // Decode until the window reaches `limit` (total position) or the end
    // marker; with `margin`, only while 64 input bytes are ahead (false:
    // stop where that is no longer so, before a symbol).
    bool run(uint64_t limit, bool margin) {
        while (w->total() < limit) {
            if (margin && in_size - pos < 64) return false;
            uint64_t tot = w->total();
            uint32_t ps = (uint32_t)(tot & ((1u << pb) - 1));
            if (!bit(isMatch[(state << 4) + ps])) {
                uint32_t prev = tot > w->dict_start ? back(0) : 0;
                uint32_t ls = (uint32_t)(((tot & ((1u << lp) - 1)) << lc) + (prev >> (8 - lc)));
                uint16_t* probs = &lit[(size_t)0x300 * ls];
                uint32_t sym = 1;
                if (state >= 7) {
                    if ((uint64_t)rep0 + 1 > tot - w->dict_start) corrupt();
                    uint32_t mb = back(rep0);
                    do {
                        uint32_t mbit = (mb >> 7) & 1;
                        mb <<= 1;
                        uint32_t b = bit(probs[((1 + mbit) << 8) + sym]);
                        sym = (sym << 1) | b;
                        if (mbit != b) break;
                    } while (sym < 0x100);
                }
                while (sym < 0x100) sym = (sym << 1) | bit(probs[sym]);
                w->buf.push_back((char)(sym - 0x100));
                state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6;
                continue;
            }
            uint32_t l;
            if (bit(isRep[state])) {
                if (tot == w->dict_start) corrupt();
                if (!bit(isRepG0[state])) {
                    if (!bit(isRep0Long[(state << 4) + ps])) {
                        state = state < 7 ? 9 : 11;
                        w->buf.push_back((char)back(rep0));
                        continue;
                    }
                } else {
                    uint32_t d;
                    if (!bit(isRepG1[state])) d = rep1;
                    else {
                        if (!bit(isRepG2[state])) d = rep2;
                        else { d = rep3; rep3 = rep2; }
                        rep2 = rep1;
                    }
                    rep1 = rep0;
                    rep0 = d;
                }
                l = len(repLenDec, ps);
                state = state < 7 ? 8 : 11;
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0;
                l = len(lenDec, ps);
                state = state < 7 ? 7 : 10;
                uint32_t lstate = l < 3 ? l : 3;
                uint32_t slot = tree(posSlot[lstate], 6);
                uint32_t dist;
                if (slot < 4) dist = slot;
                else {
                    int nd = (int)(slot >> 1) - 1;
                    dist = (2 | (slot & 1)) << nd;
                    if (slot < 14) dist += rtree(posDec + dist - slot, nd);
                    else { dist += direct(nd - 4) << 4; dist += rtree(align, 4); }
                }
                rep0 = dist;
                if (rep0 == 0xFFFFFFFFu) { eopm = true; return true; }
                if (rep0 >= w->dict_size) corrupt();
            }
            l += 2;
            if ((uint64_t)rep0 + 1 > tot - w->dict_start) corrupt();
            if (tot + l > limit) corrupt();
            for (uint32_t i = 0; i < l; i++) w->buf.push_back((char)back(rep0));
        }
        return true;
    }
};

// ── the .xz / .lzma / raw decoder without liblzma ───────────────────────────
struct Fallback {
    int format = FORMAT_AUTO;
    uint64_t memlimit = ~0ULL;
    std::string in;
    size_t ip = 0;
    std::string out;               // filtered output not yet returned
    bool eof = false;
    int check = CHECK_UNKNOWN;
    Window w;
    Lzma1 lz;
    // the filter chain after LZMA (delta only)
    uint32_t delta_dist = 0;
    uint8_t delta_hist[256];
    uint8_t delta_pos = 0;
    uint64_t filtered_to = 0;      // window position the filters have taken
    // .xz
    enum { S_HDR, S_BLOCK, S_DATA, S_PAD, S_CHECK, S_INDEX, S_FOOTER, S_DONE,
           A_HDR, A_DATA, R_LZMA1, R_LZMA2 } st = S_HDR;
    int stream_flags = 0;
    uint64_t block_start_in = 0;   // input offset of the block (for its size)
    uint64_t block_hdr_size = 0;
    uint64_t block_out_start = 0;
    uint64_t block_comp_known = VLI_UNKNOWN, block_unc_known = VLI_UNKNOWN;
    uint64_t consumed_total = 0;   // input consumed before `in`'s current start
    std::vector<std::pair<uint64_t, uint64_t>> records;   // (unpadded, uncompressed)
    uint64_t index_start = 0;
    // running check of the block
    uint32_t ck_crc32 = 0;
    uint64_t ck_crc64 = 0;
    std::unique_ptr<nyhash::Hash> ck_sha;
    // LZMA2
    bool l2_need_dict_reset = true, l2_need_props = true, l2_done = false;
    // alone / raw LZMA1
    uint64_t a_size = VLI_UNKNOWN;

    void start(int fmt, uint64_t mem) {
        crc_tables();
        format = fmt;
        memlimit = mem;
        if (fmt == FORMAT_ALONE) st = A_HDR;
    }
    uint64_t in_off() const { return consumed_total + ip; }
    void need(size_t n) { if (in.size() - ip < n) throw Short(); }
    static uint64_t le(const std::string& s, size_t at, int n) {
        uint64_t v = 0;
        for (int i = n - 1; i >= 0; i--) v = (v << 8) | (uint8_t)s[at + i];
        return v;
    }
    uint64_t vli(size_t& p, size_t end) {
        uint64_t v = 0;
        for (int i = 0; i < 9; i++) {
            if (p >= end) throw Short();
            uint8_t b = (uint8_t)in[p++];
            v |= (uint64_t)(b & 0x7F) << (7 * i);
            if (!(b & 0x80)) {
                if (b == 0 && i) corrupt();
                return v;
            }
        }
        corrupt();
    }
    static int check_size(int c) {
        if (c == 0) return 0;
        if (c <= 3) return 4;
        if (c <= 6) return 8;
        if (c <= 9) return 16;
        if (c <= 12) return 32;
        return 64;
    }
    static uint32_t lzma2_dict(uint8_t b) {
        uint32_t bits = b & 0x3F;
        if (bits > 40) corrupt();
        if (bits == 40) return 0xFFFFFFFFu;
        return (2u | (bits & 1u)) << (bits / 2 + 11);
    }
    void set_lzma_props(uint8_t d, bool lzma2) {
        if (d >= 9 * 5 * 5) throw Corrupt{"Invalid or unsupported options"};
        uint32_t lc = d % 9; d /= 9;
        uint32_t lp = d % 5, pb = d / 5;
        if (lzma2 && lc + lp > 4) throw Corrupt{"Invalid or unsupported options"};
        lz.set_props(lc, lp, pb);
    }
    void begin_check() {
        ck_crc32 = 0; ck_crc64 = 0;
        if (check == CHECK_SHA256) ck_sha = nyhash::make("sha256");
    }
    // the filters over new window bytes, into `out`
    void take_output() {
        uint64_t end = w.total();
        if (filtered_to >= end) return;
        size_t from = (size_t)(filtered_to - w.base);
        size_t n = (size_t)(end - filtered_to);
        size_t o0 = out.size();
        out.append(w.buf, from, n);
        if (delta_dist) {
            for (size_t i = o0; i < out.size(); i++) {
                uint8_t v = (uint8_t)(out[i] + delta_hist[(uint8_t)(delta_dist + delta_pos)]);
                out[i] = (char)v;
                delta_hist[delta_pos--] = v;
            }
        }
        if (st == S_DATA) {
            const uint8_t* p = (const uint8_t*)out.data() + o0;
            size_t m = out.size() - o0;
            if (check == CHECK_CRC32) ck_crc32 = crc32(p, m, ck_crc32);
            else if (check == CHECK_CRC64) ck_crc64 = crc64(p, m, ck_crc64);
            else if (check == CHECK_SHA256 && ck_sha) ck_sha->update(p, m);
        }
        filtered_to = end;
        w.trim(filtered_to);
    }
    void dict_reset() {
        w.dict_start = w.total();
    }
    // One LZMA2 chunk; false when its bytes are not all in yet.
    bool lzma2_chunk() {
        size_t p = ip;
        need(1);
        uint8_t ctl = (uint8_t)in[p];
        if (ctl == 0x00) { ip = p + 1; l2_done = true; return true; }
        if (ctl == 0x01 || ctl == 0x02) {
            need(3);
            size_t usize = (size_t)(((uint8_t)in[p + 1] << 8) | (uint8_t)in[p + 2]) + 1;
            if (ctl == 0x01) { dict_reset(); l2_need_dict_reset = false; }
            else if (l2_need_dict_reset) corrupt();
            need(3 + usize);
            w.buf.append(in, p + 3, usize);
            ip = p + 3 + usize;
            take_output();
            return true;
        }
        if (ctl < 0x80) corrupt();
        need(5);
        uint64_t usize = ((uint64_t)(ctl & 0x1F) << 16) + (((uint8_t)in[p + 1] << 8) | (uint8_t)in[p + 2]) + 1;
        size_t psize = (size_t)(((uint8_t)in[p + 3] << 8) | (uint8_t)in[p + 4]) + 1;
        int reset = (ctl >> 5) & 3;
        size_t hdr = 5 + (reset >= 2 ? 1 : 0);
        need(hdr + psize);
        if (reset == 3) { dict_reset(); l2_need_dict_reset = false; }
        else if (l2_need_dict_reset) corrupt();
        if (reset >= 2) { set_lzma_props((uint8_t)in[p + 5], true); l2_need_props = false; }
        else if (l2_need_props) corrupt();
        if (reset >= 1) lz.reset_state();
        lz.in = (const uint8_t*)in.data() + p + hdr;
        lz.in_size = psize;
        lz.pos = 0;
        lz.w = &w;
        try {
            lz.rc_init();
            lz.run(w.total() + usize, false);
        } catch (Short&) {
            corrupt();     // the chunk's own bytes ran out
        }
        if (lz.eopm || lz.pos != psize || lz.code != 0) corrupt();
        ip = p + hdr + psize;
        take_output();
        return true;
    }
    void parse_block_header() {
        need(1);
        size_t hsize = ((size_t)(uint8_t)in[ip] + 1) * 4;
        need(hsize);
        if (crc32((const uint8_t*)in.data() + ip, hsize - 4) != (uint32_t)le(in, ip + hsize - 4, 4)) corrupt();
        size_t p = ip + 1, end = ip + hsize - 4;
        uint8_t flags = (uint8_t)in[p++];
        if (flags & 0x3C) throw Corrupt{"Invalid or unsupported options"};
        int nf = (flags & 3) + 1;
        block_comp_known = (flags & 0x40) ? vli(p, end) : VLI_UNKNOWN;
        block_unc_known = (flags & 0x80) ? vli(p, end) : VLI_UNKNOWN;
        delta_dist = 0;
        bool have_lzma2 = false;
        for (int i = 0; i < nf; i++) {
            uint64_t id = vli(p, end);
            uint64_t psz = vli(p, end);
            if (p + psz > end) corrupt();
            if (id == F_LZMA2) {
                if (i != nf - 1 || psz != 1) throw Corrupt{"Invalid or unsupported options"};
                w.dict_size = lzma2_dict((uint8_t)in[p]);
                if ((uint64_t)w.dict_size > memlimit) throw Corrupt{"Memory usage limit exceeded"};
                have_lzma2 = true;
            } else if (id == F_DELTA) {
                if (psz != 1 || i == nf - 1) throw Corrupt{"Invalid or unsupported options"};
                delta_dist = (uint32_t)(uint8_t)in[p] + 1;
            } else {
                throw Corrupt{"Invalid or unsupported options (this filter needs liblzma, which is not installed)"};
            }
            p += psz;
        }
        if (!have_lzma2) throw Corrupt{"Invalid or unsupported options"};
        while (p < end) if (in[p++] != 0) throw Corrupt{"Invalid or unsupported options"};
        std::memset(delta_hist, 0, sizeof delta_hist);
        delta_pos = 0;
        block_start_in = in_off();
        block_hdr_size = hsize;
        ip += hsize;
        block_out_start = out_total();
        l2_need_dict_reset = true;
        l2_need_props = true;
        l2_done = false;
        begin_check();
    }
    uint64_t out_emitted = 0;      // bytes handed out of `out` so far
    uint64_t out_total() const { return out_emitted + out.size(); }

    // Decode what the buffered input allows.
    void run() {
        while (true) {
            size_t save = ip;
            try {
                if (!step()) return;
            } catch (Short&) {
                ip = save;
                return;
            }
            if (st == S_DONE) return;
        }
    }
    bool step() {
        switch (st) {
        case S_HDR: {
            need(12);
            static const unsigned char magic[6] = {0xFD, '7', 'z', 'X', 'Z', 0x00};
            if (std::memcmp(in.data() + ip, magic, 6) != 0) {
                if (format == FORMAT_AUTO) { st = A_HDR; return true; }
                throw Corrupt{"Input format not supported by decoder"};
            }
            if (crc32((const uint8_t*)in.data() + ip + 6, 2) != (uint32_t)le(in, ip + 8, 4)) corrupt();
            if (in[ip + 6] != 0 || ((uint8_t)in[ip + 7] & 0xF0)) throw Corrupt{"Invalid or unsupported options"};
            stream_flags = (uint8_t)in[ip + 7];
            check = stream_flags & 0x0F;
            ip += 12;
            st = S_BLOCK;
            return true;
        }
        case S_BLOCK: {
            need(1);
            if (in[ip] == 0) { index_start = in_off(); st = S_INDEX; return true; }
            parse_block_header();
            st = S_DATA;
            return true;
        }
        case S_DATA: {
            while (!l2_done) {
                size_t save = ip;
                try { lzma2_chunk(); }
                catch (Short&) { ip = save; return false; }
            }
            uint64_t unc = out_total() - block_out_start;
            uint64_t comp = in_off() - block_start_in - block_hdr_size;
            if (block_unc_known != VLI_UNKNOWN && block_unc_known != unc) corrupt();
            if (block_comp_known != VLI_UNKNOWN && block_comp_known != comp) corrupt();
            block_data_end = in_off();
            st = S_PAD;
            return true;
        }
        case S_PAD: {
            uint64_t sz = in_off() - block_start_in;
            size_t pad = (size_t)((4 - (sz & 3)) & 3);
            need(pad);
            for (size_t i = 0; i < pad; i++) if (in[ip + i] != 0) corrupt();
            ip += pad;
            st = S_CHECK;
            return true;
        }
        case S_CHECK: {
            int cs = check_size(check);
            need((size_t)cs);
            const uint8_t* p = (const uint8_t*)in.data() + ip;
            if (check == CHECK_CRC32 && (uint32_t)le(in, ip, 4) != ck_crc32) corrupt();
            if (check == CHECK_CRC64 && le(in, ip, 8) != ck_crc64) corrupt();
            if (check == CHECK_SHA256 && ck_sha && std::memcmp(ck_sha->final().data(), p, 32) != 0) corrupt();
            ip += (size_t)cs;
            // the unpadded size: header + compressed data + check
            uint64_t unpadded = block_data_end - block_start_in + (uint64_t)cs;
            records.push_back({unpadded, out_total() - block_out_start});
            st = S_BLOCK;
            return true;
        }
        case S_INDEX: {
            size_t p = ip + 1;
            size_t end = in.size();
            uint64_t n = vli(p, end);
            if (n != records.size()) corrupt();
            for (uint64_t i = 0; i < n; i++) {
                uint64_t up = vli(p, end), un = vli(p, end);
                if (up != records[i].first || un != records[i].second) corrupt();
            }
            uint64_t isz = p - ip;
            size_t pad = (size_t)((4 - (isz & 3)) & 3);
            if (in.size() < p + pad + 4) throw Short();
            for (size_t i = 0; i < pad; i++) if (in[p + i] != 0) corrupt();
            p += pad;
            if (crc32((const uint8_t*)in.data() + ip, p - ip) != (uint32_t)le(in, p, 4)) corrupt();
            p += 4;
            uint64_t index_size = p - ip;
            ip = p;
            index_bytes = index_size;
            st = S_FOOTER;
            return true;
        }
        case S_FOOTER: {
            need(12);
            if (in[ip + 10] != 'Y' || in[ip + 11] != 'Z') corrupt();
            if (crc32((const uint8_t*)in.data() + ip + 4, 6) != (uint32_t)le(in, ip, 4)) corrupt();
            uint64_t backward = (le(in, ip + 4, 4) + 1) * 4;
            if (backward != index_bytes) corrupt();
            if ((uint8_t)in[ip + 8] != 0 || (uint8_t)in[ip + 9] != stream_flags) corrupt();
            ip += 12;
            st = S_DONE;
            eof = true;
            return true;
        }
        case A_HDR: {
            need(13);
            uint32_t ds = (uint32_t)le(in, ip + 1, 4);
            a_size = le(in, ip + 5, 8);
            {
                // round 84: what liblzma's .lzma decoder refuses as no .lzma
                // header (LZMA_FORMAT_ERROR) - invalid properties and, read
                // through FORMAT_AUTO ("picky"), a dictionary size not 2^n or
                // 2^n + 2^(n-1) or an implausible size (garbage given to
                // lzma.decompress said "Corrupt input data")
                uint8_t pb = (uint8_t)in[ip];
                bool bad = pb > (4 * 5 + 4) * 9 + 8 || (pb % 9) + ((pb / 9) % 5) > 4;
                if (!bad && format == FORMAT_AUTO) {
                    if (ds != UINT32_MAX) {
                        uint32_t d = ds - 1;
                        d |= d >> 2; d |= d >> 3; d |= d >> 4; d |= d >> 8; d |= d >> 16; ++d;
                        bad = d != ds;
                    }
                    if (a_size != UINT64_MAX && a_size >= (1ULL << 38)) bad = true;
                }
                if (bad) throw Corrupt{"Input format not supported by decoder"};
            }
            set_lzma_props((uint8_t)in[ip], false);
            w.dict_size = std::max<uint32_t>(ds, 4096);
            if ((uint64_t)w.dict_size > memlimit) throw Corrupt{"Memory usage limit exceeded"};
            ip += 13;
            check = CHECK_NONE;
            lz.reset_state();
            lz.w = &w;
            st = R_LZMA1;
            lz1_started = false;
            return true;
        }
        case R_LZMA1: return lzma1_step();
        case R_LZMA2: {
            while (!l2_done) {
                size_t save = ip;
                try { lzma2_chunk(); }
                catch (Short&) { ip = save; return false; }
            }
            st = S_DONE;
            eof = true;
            return true;
        }
        default:
            return false;
        }
    }
    uint64_t index_bytes = 0;
    uint64_t block_data_end = 0;
    bool lz1_started = false;
    // .lzma / raw LZMA1: symbol by symbol with a margin; the tail from a snapshot
    bool lzma1_step() {
        if (!lz1_started) {
            lz.in = (const uint8_t*)in.data();
            lz.in_size = in.size();
            lz.pos = ip;
            lz.rc_init();          // Short: nothing changed but the position
            ip = lz.pos;
            lz1_started = true;
        }
        uint64_t limit = a_size == VLI_UNKNOWN ? ~0ULL : a_size;
        lz.in = (const uint8_t*)in.data();
        lz.in_size = in.size();
        lz.pos = ip;
        bool done = false;
        try {
            done = lz.run(limit, true);
        } catch (Short&) {
            corrupt();     // cannot happen with the margin
        }
        ip = lz.pos;
        take_output();
        if (!done) {
            // the tail: try from a snapshot, roll back if the input runs out
            Lzma1 snap = lz;
            std::string wsnap_tail;
            uint64_t wtotal = w.total(), wbase = w.base;
            std::string wbuf_copy;          // only the part after the snapshot is undone
            size_t out_len = out.size();
            uint64_t ft = filtered_to;
            uint8_t dh[256];
            std::memcpy(dh, delta_hist, 256);
            uint8_t dp = delta_pos;
            try {
                done = lz.run(limit, false);
                ip = lz.pos;
                take_output();
            } catch (Short&) {
                lz = snap;
                if (w.base == wbase) w.buf.resize((size_t)(wtotal - w.base));
                out.resize(out_len);
                filtered_to = ft;
                std::memcpy(delta_hist, dh, 256);
                delta_pos = dp;
                return false;
            }
            if (!done) return false;
        }
        // finished: the size reached, or the end marker
        if (lz.eopm && a_size != VLI_UNKNOWN && w.total() != a_size) corrupt();
        if (lz.code != 0) corrupt();
        st = S_DONE;
        eof = true;
        return true;
    }
};

// ── objects ─────────────────────────────────────────────────────────────────
struct Obj {
    bool compress = false;
    bool native = false;           // the fallback decoder
    bool flushed = false;
    bool eof = false;
    bool needs_input = true;
    int check = CHECK_UNKNOWN;
    lz_stream s;
    bool inited = false;
    std::string in;                // the decompressor's unconsumed input
    std::string unused;
    std::unique_ptr<Fallback> fb;
    ~Obj() { if (inited) api().end(&s); }
};
std::mutex& mu() { static std::mutex* m = new std::mutex(); return *m; }
std::unordered_map<int64_t, std::shared_ptr<Obj>>& table() {
    static auto* t = new std::unordered_map<int64_t, std::shared_ptr<Obj>>();
    return *t;
}
int64_t g_next = 1;
std::shared_ptr<Obj> get(int64_t h) {
    std::lock_guard<std::mutex> l(mu());
    auto it = table().find(h);
    if (it == table().end()) fail("ValueError", "invalid lzma object");
    return it->second;
}
int64_t store(std::shared_ptr<Obj> o) {
    std::lock_guard<std::mutex> l(mu());
    int64_t id = g_next++;
    table()[id] = std::move(o);
    return id;
}
std::string barg(NythonExecutor& E, const Value& v) {
    if (auto* b = E.bytesOf(v)) return b->s;
    fail("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}
int64_t iarg(std::vector<Value>& a, size_t i, int64_t d = 0) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return d;
    return (int64_t)nyos::to_int(a[i], d);
}

// Run lzma_code over `in` until the input is used up (or the stream ends,
// or `limit` bytes are out); returns the code of the last call.
int code_loop(Api& a, Obj& o, std::string& out, const std::string& input, size_t& used, int action, int64_t limit) {
    o.s.next_in = (const uint8_t*)input.data();
    o.s.avail_in = input.size();
    int ret = LZ_OK;
    std::string chunk;
    while (true) {
        size_t room = 64 * 1024;
        if (limit >= 0) {
            if ((int64_t)out.size() >= limit) break;
            room = std::min<size_t>(room, (size_t)(limit - (int64_t)out.size()));
        }
        chunk.resize(room);
        o.s.next_out = (uint8_t*)&chunk[0];
        o.s.avail_out = room;
        {
            nyconc::GilRelease un;
            ret = a.code(&o.s, action);
        }
        size_t got = room - o.s.avail_out;
        out.append(chunk.data(), got);
        if (ret == LZ_GET_CHECK || ret == LZ_NO_CHECK) { o.check = a.get_check(&o.s); ret = LZ_OK; }
        if (ret == LZ_BUF_ERROR && o.s.avail_in == 0 && o.s.avail_out > 0) ret = LZ_OK;
        if (ret == LZ_STREAM_END) break;
        if (ret != LZ_OK) { used = input.size() - o.s.avail_in; lib_error(ret); }
        if (action == 0 && o.s.avail_in == 0 && o.s.avail_out > 0) break;
        if (got == 0 && o.s.avail_in == 0 && action == 0) break;
    }
    used = input.size() - o.s.avail_in;
    return ret;
}

} // namespace

std::vector<std::string> lzma_builtin_names() {
    return {"_lzma_has_lib", "_lzma_lib_error", "_lzma_check_supported", "_lzma_cnew", "_lzma_compress",
            "_lzma_flush", "_lzma_dnew", "_lzma_decompress", "_lzma_free", "_lzma_encode_props", "_lzma_decode_props"};
}

Value dispatch_lzma(NythonExecutor& E, const std::string& name, std::vector<Value>& a, Context* ctx) {
    (void)ctx;
    if (name == "_lzma_has_lib") return Value(api().ok);
    if (name == "_lzma_lib_error") return E.makeStringValue(api().ok ? std::string() : api().why);
    if (name == "_lzma_check_supported") {
        int64_t c = iarg(a, 0);
        if (api().ok) return Value(api().check_is_supported((int)c) != 0);
        return Value(c == CHECK_NONE || c == CHECK_CRC32 || c == CHECK_CRC64 || c == CHECK_SHA256);
    }
    if (name == "_lzma_free") {
        std::lock_guard<std::mutex> l(mu());
        table().erase(iarg(a, 0));
        return NONE_VALUE;
    }
    if (name == "_lzma_cnew") {
        Api& A = api();
        if (!A.ok) lzerr("compression needs liblzma: " + A.why);
        int64_t format = iarg(a, 0, FORMAT_XZ), check = iarg(a, 1, -1), preset = iarg(a, 2, 6);
        bool has_filters = a.size() > 3 && a[3].type != ValueType::NONE;
        auto o = std::make_shared<Obj>();
        o->compress = true;
        int ret = LZ_OK;
        Chain c;
        if (has_filters) build_chain(E, a[3], c);
        if (format == FORMAT_XZ) {
            if (check == -1) check = CHECK_CRC64;
            if (!has_filters) ret = A.easy_encoder(&o->s, (uint32_t)preset, (int)check);
            else ret = A.stream_encoder(&o->s, c.f.data(), (int)check);
        } else if (format == FORMAT_ALONE) {
            if (!has_filters) {
                lz_options_lzma opt;
                std::memset(&opt, 0, sizeof opt);
                if (A.lzma_preset(&opt, (uint32_t)preset)) lzerr("Invalid compression preset: " + std::to_string(preset));
                ret = A.alone_encoder(&o->s, &opt);
            } else {
                if (c.f.size() != 2 || c.f[0].id != F_LZMA1) fail("ValueError", "Invalid filter chain for FORMAT_ALONE - must be a single LZMA1 filter");
                ret = A.alone_encoder(&o->s, (lz_options_lzma*)c.f[0].options);
            }
        } else if (format == FORMAT_RAW) {
            ret = A.raw_encoder(&o->s, c.f.data());
        } else {
            fail("ValueError", "Invalid container format: " + std::to_string(format));
        }
        if (ret != LZ_OK) lib_error(ret);
        o->inited = true;
        return Value((int64_t)store(o));
    }
    if (name == "_lzma_compress" || name == "_lzma_flush") {
        auto o = get(iarg(a, 0));
        if (o->flushed) fail("ValueError", name == "_lzma_flush" ? "Repeated call to flush()" : "Compressor has been flushed");
        std::string input = name == "_lzma_compress" ? barg(E, a[1]) : std::string();
        std::string out;
        size_t used = 0;
        if (name == "_lzma_flush") { o->flushed = true; code_loop(api(), *o, out, input, used, 3, -1); }
        else code_loop(api(), *o, out, input, used, 0, -1);
        return E.makeBytesValue(out);
    }
    if (name == "_lzma_dnew") {
        int64_t format = iarg(a, 0, FORMAT_AUTO);
        uint64_t memlimit = a.size() > 1 && a[1].type != ValueType::NONE ? (uint64_t)nyos::to_int(a[1], 0) : ~0ULL;
        bool has_filters = a.size() > 2 && a[2].type != ValueType::NONE;
        auto o = std::make_shared<Obj>();
        Api& A = api();
        if (!A.ok) {
            // the native decoder
            o->native = true;
            o->fb = std::make_unique<Fallback>();
            if (format == FORMAT_RAW) {
                if (!has_filters) fail("ValueError", "Must specify filters for FORMAT_RAW");
                std::vector<Value> items = E.iterItems(a[2], E.globalContext());
                if (items.empty()) lzerr("Invalid or unsupported options");
                o->fb->start(FORMAT_RAW, memlimit);
                o->fb->check = CHECK_NONE;
                for (size_t i = 0; i < items.size(); i++) {
                    std::vector<Value> s = E.iterItems(items[i], E.globalContext());
                    uint64_t id = (uint64_t)nyos::to_int(s[0], 0);
                    bool last = i + 1 == items.size();
                    if (id == F_DELTA && !last) {
                        int64_t d = s.size() > 1 ? (int64_t)nyos::to_int(s[1], -1) : -1;
                        o->fb->delta_dist = d < 0 ? 1 : (uint32_t)d;
                        std::memset(o->fb->delta_hist, 0, 256);
                    } else if ((id == F_LZMA1 || id == F_LZMA2) && last) {
                        int64_t dict = s.size() > 2 ? (int64_t)nyos::to_int(s[2], -1) : -1;
                        o->fb->w.dict_size = dict < 0 ? (1u << 23) : (uint32_t)dict;
                        int64_t lc = s.size() > 3 ? (int64_t)nyos::to_int(s[3], -1) : -1;
                        int64_t lp = s.size() > 4 ? (int64_t)nyos::to_int(s[4], -1) : -1;
                        int64_t pb = s.size() > 5 ? (int64_t)nyos::to_int(s[5], -1) : -1;
                        o->fb->lz.set_props(lc < 0 ? 3 : (uint32_t)lc, lp < 0 ? 0 : (uint32_t)lp, pb < 0 ? 2 : (uint32_t)pb);
                        if (id == F_LZMA1) { o->fb->lz.reset_state(); o->fb->lz.w = &o->fb->w; o->fb->st = Fallback::R_LZMA1; }
                        else { o->fb->st = Fallback::R_LZMA2; o->fb->l2_need_dict_reset = true; }
                    } else {
                        lzerr("Invalid or unsupported options (this filter needs liblzma, which is not installed)");
                    }
                }
            } else {
                if (has_filters) fail("ValueError", "Cannot specify filters except with FORMAT_RAW");
                o->fb->start((int)format, memlimit);
            }
            o->check = o->fb->check;
            return Value((int64_t)store(o));
        }
        uint32_t flags = 0x04 | 0x01;    // LZMA_TELL_ANY_CHECK | LZMA_TELL_NO_CHECK
        int ret;
        Chain c;
        if (format == FORMAT_RAW) {
            if (!has_filters) fail("ValueError", "Must specify filters for FORMAT_RAW");
            build_chain(E, a[2], c);
            ret = A.raw_decoder(&o->s, c.f.data());
            o->check = CHECK_NONE;
        } else {
            if (has_filters) fail("ValueError", "Cannot specify filters except with FORMAT_RAW");
            if (format == FORMAT_AUTO) ret = A.auto_decoder(&o->s, memlimit, flags);
            else if (format == FORMAT_XZ) ret = A.stream_decoder(&o->s, memlimit, flags);
            else if (format == FORMAT_ALONE) { ret = A.alone_decoder(&o->s, memlimit); o->check = CHECK_NONE; }
            else fail("ValueError", "Invalid container format: " + std::to_string(format));
        }
        if (ret != LZ_OK) lib_error(ret);
        o->inited = true;
        return Value((int64_t)store(o));
    }
    if (name == "_lzma_decompress") {
        auto o = get(iarg(a, 0));
        std::string data = barg(E, a[1]);
        int64_t maxlen = iarg(a, 2, -1);
        if (o->eof) fail("EOFError", "Already at end of stream");
        std::string out;
        if (o->native) {
            Fallback& f = *o->fb;
            if (!data.empty()) f.in.append(data);
            try { f.run(); }
            catch (Corrupt& c) { lzerr(c.msg); }
            catch (Short&) {}
            // drop consumed input now and then
            if (f.ip > 1024 * 1024) {
                f.consumed_total += f.ip;
                f.in.erase(0, f.ip);
                f.ip = 0;
            }
            if (maxlen < 0 || (size_t)maxlen >= f.out.size()) out.swap(f.out);
            else { out = f.out.substr(0, (size_t)maxlen); f.out.erase(0, (size_t)maxlen); }
            f.out_emitted += out.size();
            o->check = f.check;
            if (f.eof && f.out.empty()) {
                o->eof = true;
                o->needs_input = false;
                o->unused = f.in.substr(f.ip);
            } else {
                o->needs_input = f.out.empty() && !f.eof;
            }
        } else {
            Api& A = api();
            o->in.append(data);
            size_t used = 0;
            int ret = code_loop(A, *o, out, o->in, used, 0, maxlen);
            o->in.erase(0, used);
            if (ret == LZ_STREAM_END) {
                o->eof = true;
                o->needs_input = false;
                o->unused = o->in;
                o->in.clear();
            } else if (o->in.empty()) {
                o->needs_input = !(maxlen >= 0 && (int64_t)out.size() >= maxlen);
            } else {
                o->needs_input = false;
            }
        }
        std::vector<Value> v{E.makeBytesValue(out), Value(o->eof), E.makeBytesValue(o->unused), Value(o->needs_input),
                             Value((int64_t)o->check)};
        return E.makeListValue(v);
    }
    if (name == "_lzma_encode_props") {
        Api& A = api();
        if (!A.ok) lzerr("encoding filter properties needs liblzma: " + A.why);
        Chain c;
        std::vector<Value> one{a[0]};
        Value lst = E.makeListValue(one);
        build_chain(E, lst, c);
        uint32_t size = 0;
        int ret = A.properties_size(&size, &c.f[0]);
        if (ret != LZ_OK) lib_error(ret);
        std::string out(size, '\0');
        ret = A.properties_encode(&c.f[0], (uint8_t*)&out[0]);
        if (ret != LZ_OK) lib_error(ret);
        return E.makeBytesValue(out);
    }
    if (name == "_lzma_decode_props") {
        uint64_t id = (uint64_t)nyos::to_int(a[0], 0);
        std::string props = barg(E, a[1]);
        std::vector<Value> spec{Value((int64_t)id)};
        Api& A = api();
        if (A.ok) {
            lz_filter f{id, nullptr};
            int ret = A.properties_decode(&f, nullptr, (const uint8_t*)props.data(), props.size());
            if (ret != LZ_OK) lib_error(ret);
            if (id == F_LZMA1) {
                auto* o = (lz_options_lzma*)f.options;
                spec.push_back(Value((int64_t)o->lc)); spec.push_back(Value((int64_t)o->lp));
                spec.push_back(Value((int64_t)o->pb)); spec.push_back(Value((int64_t)o->dict_size));
            } else if (id == F_LZMA2) {
                spec.push_back(Value((int64_t)((lz_options_lzma*)f.options)->dict_size));
            } else if (id == F_DELTA) {
                spec.push_back(Value((int64_t)((lz_options_delta*)f.options)->dist));
            } else if (f.options) {
                spec.push_back(Value((int64_t)((lz_options_bcj*)f.options)->start_offset));
            }
            std::free(f.options);
            return E.makeListValue(spec);
        }
        // without liblzma: the properties of LZMA1, LZMA2 and delta are simple
        if (id == F_LZMA1) {
            if (props.size() != 5) lzerr("Invalid or unsupported options");
            uint8_t d = (uint8_t)props[0];
            if (d >= 225) lzerr("Invalid or unsupported options");
            uint32_t lc = d % 9; d /= 9;
            spec.push_back(Value((int64_t)lc)); spec.push_back(Value((int64_t)(d % 5)));
            spec.push_back(Value((int64_t)(d / 5)));
            uint32_t ds = (uint8_t)props[1] | ((uint8_t)props[2] << 8) | ((uint8_t)props[3] << 16) | ((uint32_t)(uint8_t)props[4] << 24);
            spec.push_back(Value((int64_t)ds));
        } else if (id == F_LZMA2) {
            if (props.size() != 1 || ((uint8_t)props[0] & 0x3F) > 40) lzerr("Invalid or unsupported options");
            uint32_t bits = (uint8_t)props[0] & 0x3F;
            uint32_t ds = bits == 40 ? 0xFFFFFFFFu : (2u | (bits & 1u)) << (bits / 2 + 11);
            spec.push_back(Value((int64_t)ds));
        } else if (id == F_DELTA) {
            if (props.size() != 1) lzerr("Invalid or unsupported options");
            spec.push_back(Value((int64_t)((uint8_t)props[0] + 1)));
        } else {
            lzerr("Invalid or unsupported options (this filter needs liblzma, which is not installed)");
        }
        return E.makeListValue(spec);
    }
    return UNDEFINED_VALUE;
}
