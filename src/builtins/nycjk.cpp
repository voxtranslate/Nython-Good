// builtins/nycjk.cpp (round 84) - the CJK multibyte codecs: CPython 3.11's
// Modules/cjkcodecs (_codecs_cn.c, _codecs_hk.c, _codecs_iso2022.c,
// _codecs_jp.c, _codecs_kr.c, _codecs_tw.c by Hye-Shik Chang, and
// multibytecodec.c's encode/decode loops and error handling) ported to C++.
// The codec functions below are CPython's, written with the same macros
// (defined here over a growable output buffer and a code point vector), so
// that every decision - lookahead for JIS X 0213 pairs, the KS X 1001:1998
// Annex 3 make-up sequences, gb18030's four-byte ranges, the ISO-2022
// escape processing, the JIS X 0213:2000 emulation, the error lengths - is
// the one CPython makes.
//
// The mapping tables (gb2312, gbkext, gbcommon, ksx1001, cp949, big5,
// jisx0208, jisx0212, jisxcommon, jisx0213_*, cp932ext ...) are generated
// from python3's own codecs by tools/gen_cjk_codecs.py into
// nycjk_tables.inc, DEFLATE-compressed, with every encoding map stored as
// its differences from the inverse of its decoding maps; they are inflated
// and the encoding maps rebuilt on the first use of any CJK codec.
//
// The native: _ny_mbc(op, ...) - see dispatch_mbc at the end - for
// lib/_multibytecodec.ny; str.encode and bytes.decode use encode_all /
// decode_all (include/NyCJK.hpp) through include/NyCodecs.hpp.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyCJK.hpp"
#include "NyCodecs.hpp"
#include "builtins/os.hpp"
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

using namespace nython;
using namespace nython::kernel;

std::string nyz_inflate(const std::string& data);   // builtins/nyzlib.cpp (round 84)

namespace nycjk {
namespace {

typedef int64_t ssz;
typedef uint32_t Py_UCS4;
typedef uint16_t ucs2_t;
typedef uint16_t DBCHAR;

#define UNIINV 0xFFFE
#define NOCHAR 0xFFFF
#define MULTIC 0xFFFE
#define DBCINV 0xFFFD

#define MBERR_TOOSMALL (-1)
#define MBERR_TOOFEW (-2)
#define MBERR_INTERNAL (-3)
#define MBERR_EXCEPTION (-4)
#define MBENC_FLUSH 0x0001
#define MBENC_RESET 0x0002

struct MultibyteCodec_State { unsigned char c[8]; };

struct dbcs_index { const ucs2_t* map; unsigned char bottom, top; };
struct widedbcs_index { const Py_UCS4* map; unsigned char bottom, top; };
struct unim_index { const DBCHAR* map; unsigned char bottom, top; };
typedef dbcs_index decode_map;
typedef widedbcs_index widedecode_map;
typedef unim_index encode_map;

// the encoder's output: CPython writes at (*outbuf)[i] and then advances
struct OutBuf {
    std::string s;
    size_t pos = 0;
    void need(size_t n) { if (s.size() < pos + n) s.resize(pos + n + 64); }
    void put(size_t i, unsigned char c) { need(i + 1); s[pos + i] = (char)c; }
    std::string take() { return s.substr(0, pos); }
};
typedef std::vector<Py_UCS4> Writer;

#define CODEC_INIT(encoding) static int encoding##_codec_init(const void* config)
#define ENCODER_INIT(encoding) static int encoding##_encode_init(MultibyteCodec_State* state, const void* config)
#define ENCODER(encoding)                                                                                   \
    static ssz encoding##_encode(MultibyteCodec_State* state, const void* config, const Py_UCS4* data,     \
                                 ssz* inpos, ssz inlen, OutBuf& ob, int flags)
#define ENCODER_RESET(encoding) static ssz encoding##_encode_reset(MultibyteCodec_State* state, const void* config, OutBuf& ob)
#define DECODER_INIT(encoding) static int encoding##_decode_init(MultibyteCodec_State* state, const void* config)
#define DECODER(encoding)                                                                                   \
    static ssz encoding##_decode(MultibyteCodec_State* state, const void* config, const unsigned char** inbuf, \
                                 ssz inleft, Writer& writer)
#define DECODER_RESET(encoding) static ssz encoding##_decode_reset(MultibyteCodec_State* state, const void* config)

#define NEXT_IN(i) do { (*inbuf) += (i); (inleft) -= (i); } while (0)
#define NEXT_INCHAR(i) do { (*inpos) += (i); } while (0)
#define NEXT_OUT(o) do { ob.pos += (size_t)(o); } while (0)
#define NEXT(i, o) do { NEXT_INCHAR(i); NEXT_OUT(o); } while (0)
#define REQUIRE_INBUF(n) do { if (inleft < (n)) return MBERR_TOOFEW; } while (0)
#define REQUIRE_OUTBUF(n) do { ob.need((size_t)(n)); } while (0)
#define INBYTE1 ((*inbuf)[0])
#define INBYTE2 ((*inbuf)[1])
#define INBYTE3 ((*inbuf)[2])
#define INBYTE4 ((*inbuf)[3])
#define INCHAR1 (data[*inpos])
#define INCHAR2 (data[*inpos + 1])
#define OUTCHAR(c) do { writer.push_back((Py_UCS4)(c)); } while (0)
#define OUTCHAR2(c1, c2) do { writer.push_back((Py_UCS4)(c1)); writer.push_back((Py_UCS4)(c2)); } while (0)
#define OUTBYTEI(c, i) ob.put((i), (unsigned char)(c))
#define OUTBYTE1(c) OUTBYTEI(c, 0)
#define OUTBYTE2(c) OUTBYTEI(c, 1)
#define OUTBYTE3(c) OUTBYTEI(c, 2)
#define OUTBYTE4(c) OUTBYTEI(c, 3)
#define WRITEBYTE1(c1) do { REQUIRE_OUTBUF(1); OUTBYTE1(c1); } while (0)
#define WRITEBYTE2(c1, c2) do { REQUIRE_OUTBUF(2); OUTBYTE1(c1); OUTBYTE2(c2); } while (0)
#define WRITEBYTE3(c1, c2, c3) do { REQUIRE_OUTBUF(3); OUTBYTE1(c1); OUTBYTE2(c2); OUTBYTE3(c3); } while (0)
#define WRITEBYTE4(c1, c2, c3, c4) do { REQUIRE_OUTBUF(4); OUTBYTE1(c1); OUTBYTE2(c2); OUTBYTE3(c3); OUTBYTE4(c4); } while (0)

#define _TRYMAP_ENC(m, assi, val) \
    ((m)->map != NULL && (val) >= (m)->bottom && (val) <= (m)->top && ((assi) = (m)->map[(val) - (m)->bottom]) != NOCHAR)
#define TRYMAP_ENC(charset, assi, uni) _TRYMAP_ENC(&charset##_encmap[(uni) >> 8], assi, (uni) & 0xff)
#define _TRYMAP_DEC(m, assi, val) \
    ((m)->map != NULL && (val) >= (m)->bottom && (val) <= (m)->top && ((assi) = (m)->map[(val) - (m)->bottom]) != UNIINV)
#define TRYMAP_DEC(charset, assi, c1, c2) _TRYMAP_DEC(&charset##_decmap[c1], assi, c2)

// ── the tables (nycjk_tables.inc, built on first use) ───────────────────────
#include "nycjk_tables.inc"

const decode_map* gb2312_decmap; const decode_map* gbkext_decmap; const decode_map* gb18030ext_decmap;
const decode_map* ksx1001_decmap; const decode_map* cp949ext_decmap;
const decode_map* big5_decmap; const decode_map* cp950ext_decmap;
const widedecode_map* big5hkscs_decmap;
const decode_map* jisx0208_decmap; const decode_map* jisx0212_decmap;
const decode_map* jisx0213_1_bmp_decmap; const decode_map* jisx0213_2_bmp_decmap;
const decode_map* jisx0213_1_emp_decmap; const decode_map* jisx0213_2_emp_decmap;
const widedecode_map* jisx0213_pair_decmap;
const decode_map* cp932ext_decmap;
const encode_map* gbcommon_encmap; const encode_map* gb18030ext_encmap; const encode_map* cp949_encmap;
const encode_map* big5_encmap; const encode_map* cp950ext_encmap;
const encode_map* big5hkscs_bmp_encmap; const encode_map* big5hkscs_nonbmp_encmap;
const encode_map* jisxcommon_encmap; const encode_map* jisx0213_bmp_encmap; const encode_map* jisx0213_emp_encmap;
const encode_map* cp932ext_encmap;

struct Tables {
    std::vector<std::vector<ucs2_t>> u16;     // storage the maps point into
    std::vector<std::vector<Py_UCS4>> u32;
    std::vector<std::vector<decode_map>> dec;
    std::vector<std::vector<widedecode_map>> wdec;
    std::vector<std::vector<encode_map>> enc;
};

struct Reader {
    const std::string& s;
    size_t p = 0;
    explicit Reader(const std::string& s_) : s(s_) {}
    unsigned u8() { return (unsigned char)s[p++]; }
    unsigned u16() { unsigned v = (unsigned char)s[p] | ((unsigned)(unsigned char)s[p + 1] << 8); p += 2; return v; }
    uint32_t u32() {
        uint32_t v = 0;
        for (int k = 0; k < 4; k++) v |= (uint32_t)(unsigned char)s[p + (size_t)k] << (8 * k);
        p += 4;
        return v;
    }
};

// a decoding table's entries, (first byte, second byte, value), in order
struct Entry { unsigned a, b; uint32_t v; };

Tables* g_tables = nullptr;

void load_tables() {
    Tables* T = new Tables();
    std::string raw = nyz_inflate(std::string((const char*)kCjkBlob, sizeof kCjkBlob));
    Reader r(raw);
    std::vector<std::vector<Entry>> entries;   // each decoding table's, for the inverses
    auto read_dec = [&](bool wide_expected) {
        unsigned kind = r.u8();
        unsigned rows = r.u16();
        bool wide = kind == 1;
        (void)wide_expected;
        std::vector<decode_map> dm(256, decode_map{nullptr, 0, 0});
        std::vector<widedecode_map> wm(256, widedecode_map{nullptr, 0, 0});
        std::vector<Entry> es;
        for (unsigned k = 0; k < rows; k++) {
            unsigned a = r.u8(), lo = r.u8(), hi = r.u8();
            if (wide) {
                T->u32.emplace_back();
                auto& v = T->u32.back();
                for (unsigned b = lo; b <= hi; b++) { uint32_t x = r.u32(); v.push_back(x); if (x != UNIINV) es.push_back({a, b, x}); }
            } else {
                T->u16.emplace_back();
                auto& v = T->u16.back();
                unsigned prev = 0;
                for (unsigned b = lo; b <= hi; b++) {
                    unsigned x = (prev + r.u16()) & 0xFFFF;
                    prev = x;
                    v.push_back((ucs2_t)x);
                    if (x != UNIINV) es.push_back({a, b, x});
                }
            }
        }
        // (the row pointers once every row is stored: vectors of vectors
        // keep their elements' buffers when they grow)
        entries.push_back(es);
        return std::make_pair(dm, wm);
    };
    // decoding maps: rows are rebuilt from the entries so their storage is final
    const char* const dec_names[] = {"gb2312", "gbkext", "gb18030ext", "ksx1001", "cp949ext", "big5", "cp950ext",
                                     "big5hkscs", "jisx0208", "jisx0212", "jisx0213_1_bmp", "jisx0213_2_bmp",
                                     "jisx0213_1_emp", "jisx0213_2_emp", "jisx0213_pair", "cp932ext"};
    const bool dec_wide[] = {false, false, false, false, false, false, false, true,
                             false, false, false, false, false, false, true, false};
    const int ND = 16;
    for (int i = 0; i < ND; i++) read_dec(dec_wide[i]);
    (void)dec_names;
    T->u16.clear();
    T->u32.clear();
    T->dec.resize(ND);
    T->wdec.resize(ND);
    T->u16.reserve(4096);
    T->u32.reserve(512);
    for (int i = 0; i < ND; i++) {
        auto& es = entries[(size_t)i];
        if (dec_wide[i]) T->wdec[(size_t)i].assign(256, widedecode_map{nullptr, 0, 0});
        else T->dec[(size_t)i].assign(256, decode_map{nullptr, 0, 0});
        size_t j = 0;
        while (j < es.size()) {
            unsigned a = es[j].a;
            size_t e = j;
            while (e < es.size() && es[e].a == a) e++;
            unsigned lo = es[j].b, hi = es[e - 1].b;
            if (dec_wide[i]) {
                T->u32.emplace_back(hi - lo + 1, (Py_UCS4)UNIINV);
                auto& v = T->u32.back();
                for (size_t k = j; k < e; k++) v[es[k].b - lo] = es[k].v;
                T->wdec[(size_t)i][a] = widedecode_map{v.data(), (unsigned char)lo, (unsigned char)hi};
            } else {
                T->u16.emplace_back(hi - lo + 1, (ucs2_t)UNIINV);
                auto& v = T->u16.back();
                for (size_t k = j; k < e; k++) v[es[k].b - lo] = (ucs2_t)es[k].v;
                T->dec[(size_t)i][a] = decode_map{v.data(), (unsigned char)lo, (unsigned char)hi};
            }
            j = e;
        }
    }
    // encoding maps: the inverse of their decoding maps (first one wins, as
    // tools/gen_cjk_codecs.py's inverse()), then the stored differences
    struct Src { int table; uint32_t flag; int keep; };   // keep: 0 all, 1 BMP values, 2 plane-2 values
    auto build = [&](std::initializer_list<Src> srcs) {
        std::vector<uint32_t> m(65536, NOCHAR);
        for (const Src& s : srcs) {
            for (const Entry& e : entries[(size_t)s.table]) {
                if (s.keep == 1 && e.v >= 0x10000) continue;
                if (s.keep == 2 && e.v < 0x20000) continue;
                uint32_t u = e.v >= 0x10000 ? (e.v & 0xFFFF) : e.v;
                if (m[u] == NOCHAR) m[u] = s.flag | (e.a << 8) | e.b;
            }
        }
        unsigned kind = r.u8();
        (void)kind;
        uint32_t n = r.u32();
        uint32_t u = 0;
        for (uint32_t k = 0; k < n; k++) {
            u += r.u32();
            unsigned v = r.u16();
            if (u < 65536) m[u] = v;
        }
        std::vector<encode_map> em(256, encode_map{nullptr, 0, 0});
        for (unsigned hb = 0; hb < 256; hb++) {
            int lo = -1, hi = -1;
            for (unsigned lb = 0; lb < 256; lb++) if (m[(hb << 8) | lb] != NOCHAR) { if (lo < 0) lo = (int)lb; hi = (int)lb; }
            if (lo < 0) continue;
            T->u16.emplace_back();
            auto& v = T->u16.back();
            for (int lb = lo; lb <= hi; lb++) v.push_back((ucs2_t)m[(hb << 8) | (unsigned)lb]);
            em[hb] = encode_map{v.data(), (unsigned char)lo, (unsigned char)hi};
        }
        T->enc.push_back(em);
        return T->enc.size() - 1;
    };
    size_t e_gbcommon = build({{0, 0, 0}, {1, 0, 0}});
    size_t e_gb18030ext = build({{2, 0, 0}});
    size_t e_cp949 = build({{3, 0, 0}, {4, 0, 0}});
    size_t e_big5 = build({{5, 0, 0}});
    size_t e_cp950ext = build({});
    size_t e_hkbmp = build({{7, 0, 1}});
    size_t e_hknonbmp = build({{7, 0, 2}});
    size_t e_jisxcommon = build({{8, 0, 0}, {9, 0x8000, 0}});
    size_t e_j213bmp = build({{10, 0, 0}, {11, 0x8000, 0}});
    size_t e_j213emp = build({{12, 0, 0}, {13, 0x8000, 0}});
    size_t e_cp932ext = build({});
    gb2312_decmap = T->dec[0].data(); gbkext_decmap = T->dec[1].data(); gb18030ext_decmap = T->dec[2].data();
    ksx1001_decmap = T->dec[3].data(); cp949ext_decmap = T->dec[4].data();
    big5_decmap = T->dec[5].data(); cp950ext_decmap = T->dec[6].data();
    big5hkscs_decmap = T->wdec[7].data();
    jisx0208_decmap = T->dec[8].data(); jisx0212_decmap = T->dec[9].data();
    jisx0213_1_bmp_decmap = T->dec[10].data(); jisx0213_2_bmp_decmap = T->dec[11].data();
    jisx0213_1_emp_decmap = T->dec[12].data(); jisx0213_2_emp_decmap = T->dec[13].data();
    jisx0213_pair_decmap = T->wdec[14].data();
    cp932ext_decmap = T->dec[15].data();
    gbcommon_encmap = T->enc[e_gbcommon].data(); gb18030ext_encmap = T->enc[e_gb18030ext].data();
    cp949_encmap = T->enc[e_cp949].data(); big5_encmap = T->enc[e_big5].data(); cp950ext_encmap = T->enc[e_cp950ext].data();
    big5hkscs_bmp_encmap = T->enc[e_hkbmp].data(); big5hkscs_nonbmp_encmap = T->enc[e_hknonbmp].data();
    jisxcommon_encmap = T->enc[e_jisxcommon].data(); jisx0213_bmp_encmap = T->enc[e_j213bmp].data();
    jisx0213_emp_encmap = T->enc[e_j213emp].data(); cp932ext_encmap = T->enc[e_cp932ext].data();
    g_tables = T;
}

void ensure_tables() {
    static std::once_flag once;
    std::call_once(once, load_tables);
}

DBCHAR find_pairencmap(ucs2_t body, ucs2_t modifier) {
    uint32_t value = ((uint32_t)body << 16) | modifier;
    size_t n = sizeof kJisx0213PairEnc / sizeof kJisx0213PairEnc[0];
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (kJisx0213PairEnc[mid][0] < value) lo = mid + 1;
        else hi = mid;
    }
    if (lo < n && kJisx0213PairEnc[lo][0] == value) return (DBCHAR)kJisx0213PairEnc[lo][1];
    return DBCINV;
}

// ════════════════════════════════════════════════════════════════════════
// _codecs_cn.c
// ════════════════════════════════════════════════════════════════════════
#define GBK_DECODE(dc1, dc2, writer)                                \
    if ((dc1) == 0xa1 && (dc2) == 0xaa) {                           \
        OUTCHAR(0x2014);                                            \
    }                                                               \
    else if ((dc1) == 0xa8 && (dc2) == 0x44) {                      \
        OUTCHAR(0x2015);                                            \
    }                                                               \
    else if ((dc1) == 0xa1 && (dc2) == 0xa4) {                      \
        OUTCHAR(0x00b7);                                            \
    }                                                               \
    else if (TRYMAP_DEC(gb2312, decoded, dc1 ^ 0x80, dc2 ^ 0x80)) { \
        OUTCHAR(decoded);                                           \
    }                                                               \
    else if (TRYMAP_DEC(gbkext, decoded, dc1, dc2)) {               \
        OUTCHAR(decoded);                                           \
    }

#define GBK_ENCODE(code, assi)                                         \
    if ((code) == 0x2014) {                                            \
        (assi) = 0xa1aa;                                               \
    } else if ((code) == 0x2015) {                                     \
        (assi) = 0xa844;                                               \
    } else if ((code) == 0x00b7) {                                     \
        (assi) = 0xa1a4;                                               \
    } else if ((code) != 0x30fb && TRYMAP_ENC(gbcommon, assi, code)) { \
        ;                                                              \
    }

#define CN_STATE_OFFSET 0

ENCODER(gb2312)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (TRYMAP_ENC(gbcommon, code, c)) ;
        else return 1;
        if (code & 0x8000) return 1;   /* MSB set: GBK */
        OUTBYTE1((code >> 8) | 0x80);
        OUTBYTE2((code & 0xFF) | 0x80);
        NEXT(1, 2);
    }
    return 0;
}

DECODER(gb2312)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = **inbuf;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        if (TRYMAP_DEC(gb2312, decoded, c ^ 0x80, INBYTE2 ^ 0x80)) { OUTCHAR(decoded); NEXT_IN(2); }
        else return 1;
    }
    return 0;
}

ENCODER(gbk)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code = 0;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        GBK_ENCODE(c, code)
        else return 1;
        OUTBYTE1((code >> 8) | 0x80);
        if (code & 0x8000) OUTBYTE2((code & 0xFF));         /* MSB set: GBK */
        else OUTBYTE2((code & 0xFF) | 0x80);                /* MSB unset: GB2312 */
        NEXT(1, 2);
    }
    return 0;
}

DECODER(gbk)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        GBK_DECODE(c, INBYTE2, writer)
        else return 1;
        NEXT_IN(2);
    }
    return 0;
}

ENCODER(gb18030)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code = 0;
        if (c < 0x80) { WRITEBYTE1(c); NEXT(1, 1); continue; }
        if (c >= 0x10000) {
            Py_UCS4 tc = c - 0x10000;
            REQUIRE_OUTBUF(4);
            OUTBYTE4((unsigned char)(tc % 10) + 0x30);
            tc /= 10;
            OUTBYTE3((unsigned char)(tc % 126) + 0x81);
            tc /= 126;
            OUTBYTE2((unsigned char)(tc % 10) + 0x30);
            tc /= 10;
            OUTBYTE1((unsigned char)(tc + 0x90));
            NEXT(1, 4);
            continue;
        }
        REQUIRE_OUTBUF(2);
        GBK_ENCODE(c, code)
        else if (TRYMAP_ENC(gb18030ext, code, c)) ;
        else {
            const uint32_t (*utrrange)[3];
            REQUIRE_OUTBUF(4);
            for (utrrange = kGb18030Ranges; (*utrrange)[0] != 0; utrrange++)
                if ((*utrrange)[0] <= c && c <= (*utrrange)[1]) {
                    Py_UCS4 tc;
                    tc = c - (*utrrange)[0] + (*utrrange)[2];
                    OUTBYTE4((unsigned char)(tc % 10) + 0x30);
                    tc /= 10;
                    OUTBYTE3((unsigned char)(tc % 126) + 0x81);
                    tc /= 126;
                    OUTBYTE2((unsigned char)(tc % 10) + 0x30);
                    tc /= 10;
                    OUTBYTE1((unsigned char)tc + 0x81);
                    NEXT(1, 4);
                    break;
                }
            if ((*utrrange)[0] == 0) return 1;
            continue;
        }
        OUTBYTE1((code >> 8) | 0x80);
        if (code & 0x8000) OUTBYTE2((code & 0xFF));   /* MSB set: GBK or GB18030ext */
        else OUTBYTE2((code & 0xFF) | 0x80);          /* MSB unset: GB2312 */
        NEXT(1, 2);
    }
    return 0;
}

DECODER(gb18030)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1, c2;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        c2 = INBYTE2;
        if (c2 >= 0x30 && c2 <= 0x39) {   /* 4 bytes seq */
            const uint32_t (*utr)[3];
            unsigned char c3, c4;
            Py_UCS4 lseq;
            REQUIRE_INBUF(4);
            c3 = INBYTE3;
            c4 = INBYTE4;
            if (c < 0x81 || c > 0xFE || c3 < 0x81 || c3 > 0xFE || c4 < 0x30 || c4 > 0x39) return 1;
            c -= 0x81; c2 -= 0x30;
            c3 -= 0x81; c4 -= 0x30;
            if (c < 4) {   /* U+0080 - U+FFFF */
                lseq = ((Py_UCS4)c * 10 + c2) * 1260 + (Py_UCS4)c3 * 10 + c4;
                if (lseq < 39420) {
                    for (utr = kGb18030Ranges; lseq >= (*(utr + 1))[2]; utr++) ;
                    OUTCHAR((*utr)[0] - (*utr)[2] + lseq);
                    NEXT_IN(4);
                    continue;
                }
            }
            else if (c >= 15) {   /* U+10000 - U+10FFFF */
                lseq = 0x10000 + (((Py_UCS4)c - 15) * 10 + c2) * 1260 + (Py_UCS4)c3 * 10 + c4;
                if (lseq <= 0x10FFFF) { OUTCHAR(lseq); NEXT_IN(4); continue; }
            }
            return 1;
        }
        GBK_DECODE(c, c2, writer)
        else if (TRYMAP_DEC(gb18030ext, decoded, c, c2)) OUTCHAR(decoded);
        else return 1;
        NEXT_IN(2);
    }
    return 0;
}

ENCODER_INIT(hz) { (void)config; state->c[CN_STATE_OFFSET] = 0; return 0; }

ENCODER_RESET(hz)
{
    (void)config;
    if (state->c[CN_STATE_OFFSET] != 0) { WRITEBYTE2('~', '}'); state->c[CN_STATE_OFFSET] = 0; NEXT_OUT(2); }
    return 0;
}

ENCODER(hz)
{
    (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) {
            if (state->c[CN_STATE_OFFSET]) { WRITEBYTE2('~', '}'); NEXT_OUT(2); state->c[CN_STATE_OFFSET] = 0; }
            WRITEBYTE1((unsigned char)c);
            NEXT(1, 1);
            if (c == '~') { WRITEBYTE1('~'); NEXT_OUT(1); }
            continue;
        }
        if (c > 0xFFFF) return 1;
        if (TRYMAP_ENC(gbcommon, code, c)) ;
        else return 1;
        if (code & 0x8000) return 1;   /* MSB set: GBK */
        if (state->c[CN_STATE_OFFSET] == 0) {
            WRITEBYTE4('~', '{', code >> 8, code & 0xff);
            NEXT(1, 4);
            state->c[CN_STATE_OFFSET] = 1;
        } else {
            WRITEBYTE2(code >> 8, code & 0xff);
            NEXT(1, 2);
        }
    }
    return 0;
}

DECODER_INIT(hz) { (void)config; state->c[CN_STATE_OFFSET] = 0; return 0; }
DECODER_RESET(hz) { (void)config; state->c[CN_STATE_OFFSET] = 0; return 0; }

DECODER(hz)
{
    (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c == '~') {
            REQUIRE_INBUF(2);
            unsigned char c2 = INBYTE2;
            if (c2 == '~' && state->c[CN_STATE_OFFSET] == 0) OUTCHAR('~');
            else if (c2 == '{' && state->c[CN_STATE_OFFSET] == 0) state->c[CN_STATE_OFFSET] = 1;   /* set GB */
            else if (c2 == '\n' && state->c[CN_STATE_OFFSET] == 0) ;                              /* line-continuation */
            else if (c2 == '}' && state->c[CN_STATE_OFFSET] == 1) state->c[CN_STATE_OFFSET] = 0;   /* set ASCII */
            else return 1;
            NEXT_IN(2);
            continue;
        }
        if (c & 0x80) return 1;
        if (state->c[CN_STATE_OFFSET] == 0) { OUTCHAR(c); NEXT_IN(1); }   /* ASCII mode */
        else {                                                            /* GB mode */
            REQUIRE_INBUF(2);
            if (TRYMAP_DEC(gb2312, decoded, c, INBYTE2)) { OUTCHAR(decoded); NEXT_IN(2); }
            else return 1;
        }
    }
    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// _codecs_kr.c
// ════════════════════════════════════════════════════════════════════════
#define EUCKR_JAMO_FIRSTBYTE 0xA4
#define EUCKR_JAMO_FILLER 0xD4

const unsigned char u2cgk_choseong[19] = {0xa1, 0xa2, 0xa4, 0xa7, 0xa8, 0xa9, 0xb1, 0xb2, 0xb3, 0xb5,
                                          0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe};
const unsigned char u2cgk_jungseong[21] = {0xbf, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
                                           0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xd0, 0xd1, 0xd2, 0xd3};
const unsigned char u2cgk_jongseong[28] = {0xd4, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa9, 0xaa,
                                           0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb4, 0xb5,
                                           0xb6, 0xb7, 0xb8, 0xba, 0xbb, 0xbc, 0xbd, 0xbe};

ENCODER(euc_kr)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (TRYMAP_ENC(cp949, code, c)) ;
        else return 1;
        if ((code & 0x8000) == 0) {
            /* KS X 1001 coded character */
            OUTBYTE1((code >> 8) | 0x80);
            OUTBYTE2((code & 0xFF) | 0x80);
            NEXT(1, 2);
        } else {
            /* Mapping is found in CP949 extension, but we encode it in KS X
               1001:1998 Annex 3, make-up sequence for EUC-KR. */
            REQUIRE_OUTBUF(8);
            /* syllable composition precedence */
            OUTBYTE1(EUCKR_JAMO_FIRSTBYTE);
            OUTBYTE2(EUCKR_JAMO_FILLER);
            /* All code points in CP949 extension are in unicode Hangul Syllable area. */
            c -= 0xac00;
            OUTBYTE3(EUCKR_JAMO_FIRSTBYTE);
            OUTBYTE4(u2cgk_choseong[c / 588]);
            NEXT_OUT(4);
            OUTBYTE1(EUCKR_JAMO_FIRSTBYTE);
            OUTBYTE2(u2cgk_jungseong[(c / 28) % 21]);
            OUTBYTE3(EUCKR_JAMO_FIRSTBYTE);
            OUTBYTE4(u2cgk_jongseong[c % 28]);
            NEXT(1, 4);
        }
    }
    return 0;
}

#define NONE 127
const unsigned char cgk2u_choseong[] = {   /* [A1, BE] */
    0, 1, NONE, 2, NONE, NONE, 3, 4, 5, NONE, NONE, NONE, NONE, NONE, NONE, NONE,
    6, 7, 8, NONE, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18};
const unsigned char cgk2u_jongseong[] = {   /* [A1, BE] */
    1, 2, 3, 4, 5, 6, 7, NONE, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, NONE, 18, 19, 20, 21, 22,
    NONE, 23, 24, 25, 26, 27};

DECODER(euc_kr)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        if (c == EUCKR_JAMO_FIRSTBYTE && INBYTE2 == EUCKR_JAMO_FILLER) {
            /* KS X 1001:1998 Annex 3 make-up sequence */
            DBCHAR cho, jung, jong;
            REQUIRE_INBUF(8);
            if ((*inbuf)[2] != EUCKR_JAMO_FIRSTBYTE || (*inbuf)[4] != EUCKR_JAMO_FIRSTBYTE ||
                (*inbuf)[6] != EUCKR_JAMO_FIRSTBYTE)
                return 1;
            c = (*inbuf)[3];
            if (0xa1 <= c && c <= 0xbe) cho = cgk2u_choseong[c - 0xa1];
            else cho = NONE;
            c = (*inbuf)[5];
            jung = (0xbf <= c && c <= 0xd3) ? c - 0xbf : NONE;
            c = (*inbuf)[7];
            if (c == EUCKR_JAMO_FILLER) jong = 0;
            else if (0xa1 <= c && c <= 0xbe) jong = cgk2u_jongseong[c - 0xa1];
            else jong = NONE;
            if (cho == NONE || jung == NONE || jong == NONE) return 1;
            OUTCHAR(0xac00 + cho * 588 + jung * 28 + jong);
            NEXT_IN(8);
        }
        else if (TRYMAP_DEC(ksx1001, decoded, c ^ 0x80, INBYTE2 ^ 0x80)) { OUTCHAR(decoded); NEXT_IN(2); }
        else return 1;
    }
    return 0;
}
#undef NONE

ENCODER(cp949)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (TRYMAP_ENC(cp949, code, c)) ;
        else return 1;
        OUTBYTE1((code >> 8) | 0x80);
        if (code & 0x8000) OUTBYTE2(code & 0xFF);   /* MSB set: CP949 */
        else OUTBYTE2((code & 0xFF) | 0x80);        /* MSB unset: ks x 1001 */
        NEXT(1, 2);
    }
    return 0;
}

DECODER(cp949)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        if (TRYMAP_DEC(ksx1001, decoded, c ^ 0x80, INBYTE2 ^ 0x80)) OUTCHAR(decoded);
        else if (TRYMAP_DEC(cp949ext, decoded, c, INBYTE2)) OUTCHAR(decoded);
        else return 1;
        NEXT_IN(2);
    }
    return 0;
}

const unsigned char u2johabidx_choseong[32] = {0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
                                              0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14};
const unsigned char u2johabidx_jungseong[32] = {0x03, 0x04, 0x05, 0x06, 0x07, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
                                               0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x1a, 0x1b, 0x1c, 0x1d};
const unsigned char u2johabidx_jongseong[32] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
                                               0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x13, 0x14, 0x15,
                                               0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d};
const DBCHAR u2johabjamo[] = {
    0x8841, 0x8c41, 0x8444, 0x9041, 0x8446, 0x8447, 0x9441, 0x9841, 0x9c41, 0x844a, 0x844b, 0x844c, 0x844d,
    0x844e, 0x844f, 0x8450, 0xa041, 0xa441, 0xa841, 0x8454, 0xac41, 0xb041, 0xb441, 0xb841, 0xbc41, 0xc041,
    0xc441, 0xc841, 0xcc41, 0xd041, 0x8461, 0x8481, 0x84a1, 0x84c1, 0x84e1, 0x8541, 0x8561, 0x8581, 0x85a1,
    0x85c1, 0x85e1, 0x8641, 0x8661, 0x8681, 0x86a1, 0x86c1, 0x86e1, 0x8741, 0x8761, 0x8781, 0x87a1,
};

ENCODER(johab)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (c >= 0xac00 && c <= 0xd7a3) {
            c -= 0xac00;
            code = (DBCHAR)(0x8000 | (u2johabidx_choseong[c / 588] << 10) | (u2johabidx_jungseong[(c / 28) % 21] << 5) |
                            u2johabidx_jongseong[c % 28]);
        }
        else if (c >= 0x3131 && c <= 0x3163) code = u2johabjamo[c - 0x3131];
        else if (TRYMAP_ENC(cp949, code, c)) {
            unsigned char c1, c2, t2;
            unsigned short t1;
            c1 = code >> 8;
            c2 = code & 0xff;
            if (((c1 >= 0x21 && c1 <= 0x2c) || (c1 >= 0x4a && c1 <= 0x7d)) && (c2 >= 0x21 && c2 <= 0x7e)) {
                t1 = (unsigned short)(c1 < 0x4a ? (c1 - 0x21 + 0x1b2) : (c1 - 0x21 + 0x197));
                t2 = (unsigned char)(((t1 & 1) ? 0x5e : 0) + (c2 - 0x21));
                OUTBYTE1(t1 >> 1);
                OUTBYTE2(t2 < 0x4e ? t2 + 0x31 : t2 + 0x43);
                NEXT(1, 2);
                continue;
            }
            else return 1;
        }
        else return 1;
        OUTBYTE1(code >> 8);
        OUTBYTE2(code & 0xff);
        NEXT(1, 2);
    }
    return 0;
}

#define FILL 0xfd
#define NONE 0xff
const unsigned char johabidx_choseong[32] = {
    NONE, FILL, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
    0x0e, 0x0f, 0x10, 0x11, 0x12, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE};
const unsigned char johabidx_jungseong[32] = {
    NONE, NONE, FILL, 0x00, 0x01, 0x02, 0x03, 0x04, NONE, NONE, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
    NONE, NONE, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, NONE, NONE, 0x11, 0x12, 0x13, 0x14, NONE, NONE};
const unsigned char johabidx_jongseong[32] = {
    NONE, FILL, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
    0x0f, 0x10, NONE, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, NONE, NONE};
const unsigned char johabjamo_choseong[32] = {
    NONE, FILL, 0x31, 0x32, 0x34, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x4b, 0x4c, 0x4d, 0x4e, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE};
const unsigned char johabjamo_jungseong[32] = {
    NONE, NONE, FILL, 0x4f, 0x50, 0x51, 0x52, 0x53, NONE, NONE, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    NONE, NONE, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, NONE, NONE, 0x60, 0x61, 0x62, 0x63, NONE, NONE};
const unsigned char johabjamo_jongseong[32] = {
    NONE, FILL, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
    0x40, 0x41, NONE, 0x42, 0x44, 0x45, 0x46, 0x47, 0x48, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, NONE, NONE};

DECODER(johab)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1, c2;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        c2 = INBYTE2;
        if (c < 0xd8) {
            /* johab hangul */
            unsigned char c_cho, c_jung, c_jong;
            unsigned char i_cho, i_jung, i_jong;
            c_cho = (c >> 2) & 0x1f;
            c_jung = ((c << 3) | c2 >> 5) & 0x1f;
            c_jong = c2 & 0x1f;
            i_cho = johabidx_choseong[c_cho];
            i_jung = johabidx_jungseong[c_jung];
            i_jong = johabidx_jongseong[c_jong];
            if (i_cho == NONE || i_jung == NONE || i_jong == NONE) return 1;
            /* we don't use U+1100 hangul jamo yet. */
            if (i_cho == FILL) {
                if (i_jung == FILL) {
                    if (i_jong == FILL) OUTCHAR(0x3000);
                    else OUTCHAR(0x3100 | johabjamo_jongseong[c_jong]);
                } else {
                    if (i_jong == FILL) OUTCHAR(0x3100 | johabjamo_jungseong[c_jung]);
                    else return 1;
                }
            } else {
                if (i_jung == FILL) {
                    if (i_jong == FILL) OUTCHAR(0x3100 | johabjamo_choseong[c_cho]);
                    else return 1;
                }
                else OUTCHAR(0xac00 + i_cho * 588 + i_jung * 28 + (i_jong == FILL ? 0 : i_jong));
            }
            NEXT_IN(2);
        } else {
            /* KS X 1001 except hangul jamos and syllables */
            if (c == 0xdf || c > 0xf9 || c2 < 0x31 || (c2 >= 0x80 && c2 < 0x91) || (c2 & 0x7f) == 0x7f ||
                (c == 0xda && (c2 >= 0xa1 && c2 <= 0xd3)))
                return 1;
            else {
                unsigned char t1, t2;
                t1 = (unsigned char)(c < 0xe0 ? 2 * (c - 0xd9) : 2 * c - 0x197);
                t2 = (unsigned char)(c2 < 0x91 ? c2 - 0x31 : c2 - 0x43);
                t1 = (unsigned char)(t1 + (t2 < 0x5e ? 0 : 1) + 0x21);
                t2 = (unsigned char)((t2 < 0x5e ? t2 : t2 - 0x5e) + 0x21);
                if (TRYMAP_DEC(ksx1001, decoded, t1, t2)) { OUTCHAR(decoded); NEXT_IN(2); }
                else return 1;
            }
        }
    }
    return 0;
}
#undef NONE
#undef FILL

// ════════════════════════════════════════════════════════════════════════
// _codecs_tw.c
// ════════════════════════════════════════════════════════════════════════
ENCODER(big5)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { REQUIRE_OUTBUF(1); OUTBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (TRYMAP_ENC(big5, code, c)) ;
        else return 1;
        OUTBYTE1(code >> 8);
        OUTBYTE2(code & 0xFF);
        NEXT(1, 2);
    }
    return 0;
}

DECODER(big5)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        if (TRYMAP_DEC(big5, decoded, c, INBYTE2)) { OUTCHAR(decoded); NEXT_IN(2); }
        else return 1;
    }
    return 0;
}

ENCODER(cp950)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (TRYMAP_ENC(cp950ext, code, c)) ;
        else if (TRYMAP_ENC(big5, code, c)) ;
        else return 1;
        OUTBYTE1(code >> 8);
        OUTBYTE2(code & 0xFF);
        NEXT(1, 2);
    }
    return 0;
}

DECODER(cp950)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        if (TRYMAP_DEC(cp950ext, decoded, c, INBYTE2)) OUTCHAR(decoded);
        else if (TRYMAP_DEC(big5, decoded, c, INBYTE2)) OUTCHAR(decoded);
        else return 1;
        NEXT_IN(2);
    }
    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// _codecs_hk.c (the decoding map holds the plane bit itself: CPython's
// phint bitmaps are folded into its values)
// ════════════════════════════════════════════════════════════════════════
const DBCHAR big5hkscs_pairenc_table[4] = {0x8862, 0x8864, 0x88a3, 0x88a5};

ENCODER(big5hkscs)
{
    (void)state; (void)config;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        ssz insize;
        if (c < 0x80) { REQUIRE_OUTBUF(1); OUTBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        insize = 1;
        REQUIRE_OUTBUF(2);
        if (c < 0x10000) {
            if (TRYMAP_ENC(big5hkscs_bmp, code, c)) {
                if (code == MULTIC) {
                    Py_UCS4 c2;
                    if (inlen - *inpos >= 2) c2 = INCHAR2;
                    else c2 = 0;
                    if (inlen - *inpos >= 2 && ((c & 0xffdf) == 0x00ca) && ((c2 & 0xfff7) == 0x0304)) {
                        code = big5hkscs_pairenc_table[((c >> 4) | (c2 >> 3)) & 3];
                        insize = 2;
                    }
                    else if (inlen - *inpos < 2 && !(flags & MBENC_FLUSH)) return MBERR_TOOFEW;
                    else {
                        if (c == 0xca) code = 0x8866;
                        else code = 0x88a7;   /* c == 0xea */
                    }
                }
            }
            else if (TRYMAP_ENC(big5, code, c)) ;
            else return 1;
        }
        else if (c < 0x20000) return insize;
        else if (c < 0x30000) {
            if (TRYMAP_ENC(big5hkscs_nonbmp, code, c & 0xffff)) ;
            else return insize;
        }
        else return insize;
        OUTBYTE1(code >> 8);
        OUTBYTE2(code & 0xFF);
        NEXT(insize, 2);
    }
    return 0;
}

DECODER(big5hkscs)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        REQUIRE_INBUF(2);
        if (0xc6 > c || c > 0xc8 || (c < 0xc7 && INBYTE2 < 0xa1)) {
            if (TRYMAP_DEC(big5, decoded, c, INBYTE2)) { OUTCHAR(decoded); NEXT_IN(2); continue; }
        }
        if (TRYMAP_DEC(big5hkscs, decoded, c, INBYTE2)) { OUTCHAR(decoded); NEXT_IN(2); continue; }
        switch ((c << 8) | INBYTE2) {
            case 0x8862: OUTCHAR2(0x00ca, 0x0304); break;
            case 0x8864: OUTCHAR2(0x00ca, 0x030c); break;
            case 0x88a3: OUTCHAR2(0x00ea, 0x0304); break;
            case 0x88a5: OUTCHAR2(0x00ea, 0x030c); break;
            default: return 1;
        }
        NEXT_IN(2);   /* all decoded code points are pairs, above. */
    }
    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// _codecs_jp.c (with alg_jisx0201.h and emu_jisx0213_2000.h)
// ════════════════════════════════════════════════════════════════════════
#define EMPBASE 0x20000

#define JISX0201_R_ENCODE(c, assi)                      \
    if ((c) < 0x80 && (c) != 0x5c && (c) != 0x7e) {     \
        (assi) = (c);                                   \
    }                                                   \
    else if ((c) == 0x00a5) {                           \
        (assi) = 0x5c;                                  \
    }                                                   \
    else if ((c) == 0x203e) {                           \
        (assi) = 0x7e;                                  \
    }
#define JISX0201_K_ENCODE(c, assi)                      \
    if ((c) >= 0xff61 && (c) <= 0xff9f) {               \
        (assi) = (c) - 0xfec0;                          \
    }
#define JISX0201_ENCODE(c, assi)                        \
    JISX0201_R_ENCODE(c, assi)                          \
    else JISX0201_K_ENCODE(c, assi)
#define JISX0201_R_DECODE_CHAR(c, assi)                 \
    if ((c) < 0x5c) {                                   \
        (assi) = (c);                                   \
    }                                                   \
    else if ((c) == 0x5c) {                             \
        (assi) = 0x00a5;                                \
    }                                                   \
    else if ((c) < 0x7e) {                              \
        (assi) = (c);                                   \
    }                                                   \
    else if ((c) == 0x7e) {                             \
        (assi) = 0x203e;                                \
    }                                                   \
    else if ((c) == 0x7f) {                             \
        (assi) = 0x7f;                                  \
    }
#define JISX0201_R_DECODE(c, writer)                    \
    if ((c) < 0x5c) {                                   \
        OUTCHAR(c);                                     \
    }                                                   \
    else if ((c) == 0x5c) {                             \
        OUTCHAR(0x00a5);                                \
    }                                                   \
    else if ((c) < 0x7e) {                              \
        OUTCHAR(c);                                     \
    }                                                   \
    else if ((c) == 0x7e) {                             \
        OUTCHAR(0x203e);                                \
    }                                                   \
    else if ((c) == 0x7f) {                             \
        OUTCHAR(0x7f);                                  \
    }
#define JISX0201_K_DECODE(c, writer)                    \
    if ((c) >= 0xa1 && (c) <= 0xdf) {                   \
        OUTCHAR(0xfec0 + (c));                          \
    }
#define JISX0201_K_DECODE_CHAR(c, assi)                 \
    if ((c) >= 0xa1 && (c) <= 0xdf) {                   \
        (assi) = 0xfec0 + (c);                          \
    }
#define JISX0201_DECODE(c, writer)                      \
    JISX0201_R_DECODE(c, writer)                        \
    else JISX0201_K_DECODE(c, writer)

#define EMULATE_JISX0213_2000_ENCODE_BMP(assi, c, INVALID)               \
    if (config == (void *)2000 && (                                     \
                    (c) == 0x9B1C || (c) == 0x4FF1 ||                   \
                    (c) == 0x525D || (c) == 0x541E ||                   \
                    (c) == 0x5653 || (c) == 0x59F8 ||                   \
                    (c) == 0x5C5B || (c) == 0x5E77 ||                   \
                    (c) == 0x7626 || (c) == 0x7E6B)) {                  \
        return INVALID;                                                 \
    }                                                                   \
    else if (config == (void *)2000 && (c) == 0x9B1D) {                 \
        (assi) = 0x8000 | 0x7d3b;                                       \
    }
#define EMULATE_JISX0213_2000_ENCODE_EMP(assi, c, INVALID)               \
    if (config == (void *)2000 && (c) == 0x20B9F) {                     \
        return INVALID;                                                 \
    }
#define EMULATE_JISX0213_2000_DECODE_PLANE1(assi, c1, c2, INVALID)       \
    if (config == (void *)2000 &&                                       \
                    (((c1) == 0x2E && (c2) == 0x21) ||                  \
                     ((c1) == 0x2F && (c2) == 0x7E) ||                  \
                     ((c1) == 0x4F && (c2) == 0x54) ||                  \
                     ((c1) == 0x4F && (c2) == 0x7E) ||                  \
                     ((c1) == 0x74 && (c2) == 0x27) ||                  \
                     ((c1) == 0x7E && (c2) == 0x7A) ||                  \
                     ((c1) == 0x7E && (c2) == 0x7B) ||                  \
                     ((c1) == 0x7E && (c2) == 0x7C) ||                  \
                     ((c1) == 0x7E && (c2) == 0x7D) ||                  \
                     ((c1) == 0x7E && (c2) == 0x7E))) {                 \
        return INVALID;                                                 \
    }
#define EMULATE_JISX0213_2000_DECODE_PLANE2(writer, c1, c2)             \
    if (config == (void *)2000 && (c1) == 0x7D && (c2) == 0x3B) {       \
        OUTCHAR(0x9B1D);                                                \
    }
#define EMULATE_JISX0213_2000_DECODE_PLANE2_CHAR(assi, c1, c2)          \
    if (config == (void *)2000 && (c1) == 0x7D && (c2) == 0x3B) {       \
        (assi) = 0x9B1D;                                                \
    }

ENCODER(cp932)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        unsigned char c1, c2;
        if (c <= 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        else if (c >= 0xff61 && c <= 0xff9f) { WRITEBYTE1(c - 0xfec0); NEXT(1, 1); continue; }
        else if (c >= 0xf8f0 && c <= 0xf8f3) {
            /* Windows compatibility */
            REQUIRE_OUTBUF(1);
            if (c == 0xf8f0) OUTBYTE1(0xa0);
            else OUTBYTE1(c - 0xf8f1 + 0xfd);
            NEXT(1, 1);
            continue;
        }
        if (c > 0xFFFF) return 1;
        REQUIRE_OUTBUF(2);
        if (TRYMAP_ENC(cp932ext, code, c)) { OUTBYTE1(code >> 8); OUTBYTE2(code & 0xff); }
        else if (TRYMAP_ENC(jisxcommon, code, c)) {
            if (code & 0x8000) return 1;   /* MSB set: JIS X 0212 */
            /* JIS X 0208 */
            c1 = code >> 8;
            c2 = code & 0xff;
            c2 = (unsigned char)((((c1 - 0x21) & 1) ? 0x5e : 0) + (c2 - 0x21));
            c1 = (unsigned char)((c1 - 0x21) >> 1);
            OUTBYTE1(c1 < 0x1f ? c1 + 0x81 : c1 + 0xc1);
            OUTBYTE2(c2 < 0x3f ? c2 + 0x40 : c2 + 0x41);
        }
        else if (c >= 0xe000 && c < 0xe758) {
            /* User-defined area */
            c1 = (unsigned char)((Py_UCS4)(c - 0xe000) / 188);
            c2 = (unsigned char)((Py_UCS4)(c - 0xe000) % 188);
            OUTBYTE1(c1 + 0xf0);
            OUTBYTE2(c2 < 0x3f ? c2 + 0x40 : c2 + 0x41);
        }
        else return 1;
        NEXT(1, 2);
    }
    return 0;
}

DECODER(cp932)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1, c2;
        Py_UCS4 decoded;
        if (c <= 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        else if (c >= 0xa0 && c <= 0xdf) {
            if (c == 0xa0) OUTCHAR(0xf8f0);   /* half-width katakana */
            else OUTCHAR(0xfec0 + c);
            NEXT_IN(1);
            continue;
        }
        else if (c >= 0xfd) {
            /* Windows compatibility */
            OUTCHAR(0xf8f1 - 0xfd + c);
            NEXT_IN(1);
            continue;
        }
        REQUIRE_INBUF(2);
        c2 = INBYTE2;
        if (TRYMAP_DEC(cp932ext, decoded, c, c2)) OUTCHAR(decoded);
        else if ((c >= 0x81 && c <= 0x9f) || (c >= 0xe0 && c <= 0xea)) {
            if (c2 < 0x40 || (c2 > 0x7e && c2 < 0x80) || c2 > 0xfc) return 1;
            c = (unsigned char)(c < 0xe0 ? c - 0x81 : c - 0xc1);
            c2 = (unsigned char)(c2 < 0x80 ? c2 - 0x40 : c2 - 0x41);
            c = (unsigned char)(2 * c + (c2 < 0x5e ? 0 : 1) + 0x21);
            c2 = (unsigned char)((c2 < 0x5e ? c2 : c2 - 0x5e) + 0x21);
            if (TRYMAP_DEC(jisx0208, decoded, c, c2)) OUTCHAR(decoded);
            else return 1;
        }
        else if (c >= 0xf0 && c <= 0xf9) {
            if ((c2 >= 0x40 && c2 <= 0x7e) || (c2 >= 0x80 && c2 <= 0xfc))
                OUTCHAR(0xe000 + 188 * (c - 0xf0) + (c2 < 0x80 ? c2 - 0x40 : c2 - 0x41));
            else return 1;
        }
        else return 1;
        NEXT_IN(2);
    }
    return 0;
}

ENCODER(euc_jis_2004)
{
    (void)state;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code = 0;
        ssz insize;
        if (c < 0x80) { WRITEBYTE1(c); NEXT(1, 1); continue; }
        insize = 1;
        if (c <= 0xFFFF) {
            EMULATE_JISX0213_2000_ENCODE_BMP(code, c, 1)
            else if (TRYMAP_ENC(jisx0213_bmp, code, c)) {
                if (code == MULTIC) {
                    if (inlen - *inpos < 2) {
                        if (flags & MBENC_FLUSH) {
                            code = find_pairencmap((ucs2_t)c, 0);
                            if (code == DBCINV) return 1;
                        }
                        else return MBERR_TOOFEW;
                    } else {
                        Py_UCS4 c2 = INCHAR2;
                        code = find_pairencmap((ucs2_t)c, (ucs2_t)c2);
                        if (code == DBCINV) {
                            code = find_pairencmap((ucs2_t)c, 0);
                            if (code == DBCINV) return 1;
                        } else insize = 2;
                    }
                }
            }
            else if (TRYMAP_ENC(jisxcommon, code, c)) ;
            else if (c >= 0xff61 && c <= 0xff9f) {
                /* JIS X 0201 half-width katakana */
                WRITEBYTE2(0x8e, c - 0xfec0);
                NEXT(1, 2);
                continue;
            }
            else if (c == 0xff3c) code = 0x2140;   /* F/W REVERSE SOLIDUS (see NOTES) */
            else if (c == 0xff5e) code = 0x2232;   /* F/W TILDE (see NOTES) */
            else return 1;
        }
        else if (c >> 16 == EMPBASE >> 16) {
            EMULATE_JISX0213_2000_ENCODE_EMP(code, c, 1)
            else if (TRYMAP_ENC(jisx0213_emp, code, c & 0xffff)) ;
            else return insize;
        }
        else return insize;
        if (code & 0x8000) {
            /* Codeset 2 */
            WRITEBYTE3(0x8f, code >> 8, (code & 0xFF) | 0x80);
            NEXT(insize, 3);
        } else {
            /* Codeset 1 */
            WRITEBYTE2((code >> 8) | 0x80, (code & 0xFF) | 0x80);
            NEXT(insize, 2);
        }
    }
    return 0;
}

DECODER(euc_jis_2004)
{
    (void)state;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 code, decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        if (c == 0x8e) {
            /* JIS X 0201 half-width katakana */
            unsigned char c2;
            REQUIRE_INBUF(2);
            c2 = INBYTE2;
            if (c2 >= 0xa1 && c2 <= 0xdf) { OUTCHAR(0xfec0 + c2); NEXT_IN(2); }
            else return 1;
        }
        else if (c == 0x8f) {
            unsigned char c2, c3;
            REQUIRE_INBUF(3);
            c2 = INBYTE2 ^ 0x80;
            c3 = INBYTE3 ^ 0x80;
            /* JIS X 0213 Plane 2 or JIS X 0212 (see NOTES) */
            EMULATE_JISX0213_2000_DECODE_PLANE2(writer, c2, c3)
            else if (TRYMAP_DEC(jisx0213_2_bmp, decoded, c2, c3)) OUTCHAR(decoded);
            else if (TRYMAP_DEC(jisx0213_2_emp, code, c2, c3)) { OUTCHAR(EMPBASE | code); NEXT_IN(3); continue; }
            else if (TRYMAP_DEC(jisx0212, decoded, c2, c3)) OUTCHAR(decoded);
            else return 1;
            NEXT_IN(3);
        }
        else {
            unsigned char c2;
            REQUIRE_INBUF(2);
            c ^= 0x80;
            c2 = INBYTE2 ^ 0x80;
            /* JIS X 0213 Plane 1 */
            EMULATE_JISX0213_2000_DECODE_PLANE1(writer, c, c2, 2)
            else if (c == 0x21 && c2 == 0x40) OUTCHAR(0xff3c);
            else if (c == 0x22 && c2 == 0x32) OUTCHAR(0xff5e);
            else if (TRYMAP_DEC(jisx0208, decoded, c, c2)) OUTCHAR(decoded);
            else if (TRYMAP_DEC(jisx0213_1_bmp, decoded, c, c2)) OUTCHAR(decoded);
            else if (TRYMAP_DEC(jisx0213_1_emp, code, c, c2)) { OUTCHAR(EMPBASE | code); NEXT_IN(2); continue; }
            else if (TRYMAP_DEC(jisx0213_pair, code, c, c2)) { OUTCHAR2(code >> 16, code & 0xffff); NEXT_IN(2); continue; }
            else return 1;
            NEXT_IN(2);
        }
    }
    return 0;
}

ENCODER(euc_jp)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        if (c < 0x80) { WRITEBYTE1((unsigned char)c); NEXT(1, 1); continue; }
        if (c > 0xFFFF) return 1;
        if (TRYMAP_ENC(jisxcommon, code, c)) ;
        else if (c >= 0xff61 && c <= 0xff9f) {
            /* JIS X 0201 half-width katakana */
            WRITEBYTE2(0x8e, c - 0xfec0);
            NEXT(1, 2);
            continue;
        }
        else if (c == 0xff3c) code = 0x2140;   /* FULL-WIDTH REVERSE SOLIDUS */
        else if (c == 0xa5) { WRITEBYTE1(0x5c); NEXT(1, 1); continue; }    /* YEN SIGN */
        else if (c == 0x203e) { WRITEBYTE1(0x7e); NEXT(1, 1); continue; }  /* OVERLINE */
        else return 1;
        if (code & 0x8000) {
            /* JIS X 0212 */
            WRITEBYTE3(0x8f, code >> 8, (code & 0xFF) | 0x80);
            NEXT(1, 3);
        } else {
            /* JIS X 0208 */
            WRITEBYTE2((code >> 8) | 0x80, (code & 0xFF) | 0x80);
            NEXT(1, 2);
        }
    }
    return 0;
}

DECODER(euc_jp)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) { OUTCHAR(c); NEXT_IN(1); continue; }
        if (c == 0x8e) {
            /* JIS X 0201 half-width katakana */
            unsigned char c2;
            REQUIRE_INBUF(2);
            c2 = INBYTE2;
            if (c2 >= 0xa1 && c2 <= 0xdf) { OUTCHAR(0xfec0 + c2); NEXT_IN(2); }
            else return 1;
        }
        else if (c == 0x8f) {
            unsigned char c2, c3;
            REQUIRE_INBUF(3);
            c2 = INBYTE2;
            c3 = INBYTE3;
            /* JIS X 0212 */
            if (TRYMAP_DEC(jisx0212, decoded, c2 ^ 0x80, c3 ^ 0x80)) { OUTCHAR(decoded); NEXT_IN(3); }
            else return 1;
        }
        else {
            unsigned char c2;
            REQUIRE_INBUF(2);
            c2 = INBYTE2;
            /* JIS X 0208 */
            if (c == 0xa1 && c2 == 0xc0) OUTCHAR(0xff3c);   /* FULL-WIDTH REVERSE SOLIDUS */
            else if (TRYMAP_DEC(jisx0208, decoded, c ^ 0x80, c2 ^ 0x80)) OUTCHAR(decoded);
            else return 1;
            NEXT_IN(2);
        }
    }
    return 0;
}

ENCODER(shift_jis)
{
    (void)state; (void)config; (void)flags;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code;
        unsigned char c1, c2;
        if (c < 0x80) code = (DBCHAR)c;
        else if (c == 0x00a5) code = 0x5c;   /* YEN SIGN */
        else if (c == 0x203e) code = 0x7e;   /* OVERLINE */
        else JISX0201_K_ENCODE(c, code)
        else if (c > 0xFFFF) return 1;
        else code = NOCHAR;
        if (code < 0x80 || (code >= 0xa1 && code <= 0xdf)) {
            REQUIRE_OUTBUF(1);
            OUTBYTE1((unsigned char)code);
            NEXT(1, 1);
            continue;
        }
        REQUIRE_OUTBUF(2);
        if (code == NOCHAR) {
            if (TRYMAP_ENC(jisxcommon, code, c)) ;
            else if (c == 0xff3c) code = 0x2140;   /* FULL-WIDTH REVERSE SOLIDUS */
            else return 1;
            if (code & 0x8000) return 1;   /* MSB set: JIS X 0212 */
        }
        c1 = code >> 8;
        c2 = code & 0xff;
        c2 = (unsigned char)((((c1 - 0x21) & 1) ? 0x5e : 0) + (c2 - 0x21));
        c1 = (unsigned char)((c1 - 0x21) >> 1);
        OUTBYTE1(c1 < 0x1f ? c1 + 0x81 : c1 + 0xc1);
        OUTBYTE2(c2 < 0x3f ? c2 + 0x40 : c2 + 0x41);
        NEXT(1, 2);
    }
    return 0;
}

DECODER(shift_jis)
{
    (void)state; (void)config;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        Py_UCS4 decoded;
        if (c < 0x80) OUTCHAR(c);
        else JISX0201_K_DECODE(c, writer)
        else if ((c >= 0x81 && c <= 0x9f) || (c >= 0xe0 && c <= 0xea)) {
            unsigned char c1, c2;
            REQUIRE_INBUF(2);
            c2 = INBYTE2;
            if (c2 < 0x40 || (c2 > 0x7e && c2 < 0x80) || c2 > 0xfc) return 1;
            c1 = (unsigned char)(c < 0xe0 ? c - 0x81 : c - 0xc1);
            c2 = (unsigned char)(c2 < 0x80 ? c2 - 0x40 : c2 - 0x41);
            c1 = (unsigned char)(2 * c1 + (c2 < 0x5e ? 0 : 1) + 0x21);
            c2 = (unsigned char)((c2 < 0x5e ? c2 : c2 - 0x5e) + 0x21);
            if (c1 == 0x21 && c2 == 0x40) { OUTCHAR(0xff3c); NEXT_IN(2); continue; }   /* FULL-WIDTH REVERSE SOLIDUS */
            if (TRYMAP_DEC(jisx0208, decoded, c1, c2)) { OUTCHAR(decoded); NEXT_IN(2); continue; }
            else return 1;
        }
        else return 1;
        NEXT_IN(1);   /* JIS X 0201 */
    }
    return 0;
}

ENCODER(shift_jis_2004)
{
    (void)state;
    while (*inpos < inlen) {
        Py_UCS4 c = INCHAR1;
        DBCHAR code = NOCHAR;
        int c1, c2;
        ssz insize;
        JISX0201_ENCODE(c, code)
        if (code < 0x80 || (code >= 0xa1 && code <= 0xdf)) {
            WRITEBYTE1((unsigned char)code);
            NEXT(1, 1);
            continue;
        }
        REQUIRE_OUTBUF(2);
        insize = 1;
        if (code == NOCHAR) {
            if (c <= 0xffff) {
                EMULATE_JISX0213_2000_ENCODE_BMP(code, c, 1)
                else if (TRYMAP_ENC(jisx0213_bmp, code, c)) {
                    if (code == MULTIC) {
                        if (inlen - *inpos < 2) {
                            if (flags & MBENC_FLUSH) {
                                code = find_pairencmap((ucs2_t)c, 0);
                                if (code == DBCINV) return 1;
                            }
                            else return MBERR_TOOFEW;
                        } else {
                            Py_UCS4 ch2 = INCHAR2;
                            code = find_pairencmap((ucs2_t)c, (ucs2_t)ch2);
                            if (code == DBCINV) {
                                code = find_pairencmap((ucs2_t)c, 0);
                                if (code == DBCINV) return 1;
                            }
                            else insize = 2;
                        }
                    }
                }
                else if (TRYMAP_ENC(jisxcommon, code, c)) {
                    /* abandon JIS X 0212 codes */
                    if (code & 0x8000) return 1;
                }
                else return 1;
            }
            else if (c >> 16 == EMPBASE >> 16) {
                EMULATE_JISX0213_2000_ENCODE_EMP(code, c, 1)
                else if (TRYMAP_ENC(jisx0213_emp, code, c & 0xffff)) ;
                else return insize;
            }
            else return insize;
        }
        c1 = code >> 8;
        c2 = (code & 0xff) - 0x21;
        if (c1 & 0x80) {
            /* Plane 2 */
            if (c1 >= 0xee) c1 -= 0x87;
            else if (c1 >= 0xac || c1 == 0xa8) c1 -= 0x49;
            else c1 -= 0x43;
        } else {
            /* Plane 1 */
            c1 -= 0x21;
        }
        if (c1 & 1) c2 += 0x5e;
        c1 >>= 1;
        OUTBYTE1(c1 + (c1 < 0x1f ? 0x81 : 0xc1));
        OUTBYTE2(c2 + (c2 < 0x3f ? 0x40 : 0x41));
        NEXT(insize, 2);
    }
    return 0;
}

DECODER(shift_jis_2004)
{
    (void)state;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        JISX0201_DECODE(c, writer)
        else if ((c >= 0x81 && c <= 0x9f) || (c >= 0xe0 && c <= 0xfc)) {
            unsigned char c1, c2;
            Py_UCS4 code, decoded;
            REQUIRE_INBUF(2);
            c2 = INBYTE2;
            if (c2 < 0x40 || (c2 > 0x7e && c2 < 0x80) || c2 > 0xfc) return 1;
            c1 = (unsigned char)(c < 0xe0 ? c - 0x81 : c - 0xc1);
            c2 = (unsigned char)(c2 < 0x80 ? c2 - 0x40 : c2 - 0x41);
            c1 = (unsigned char)(2 * c1 + (c2 < 0x5e ? 0 : 1));
            c2 = (unsigned char)((c2 < 0x5e ? c2 : c2 - 0x5e) + 0x21);
            if (c1 < 0x5e) {   /* Plane 1 */
                c1 += 0x21;
                EMULATE_JISX0213_2000_DECODE_PLANE1(writer, c1, c2, 2)
                else if (TRYMAP_DEC(jisx0208, decoded, c1, c2)) OUTCHAR(decoded);
                else if (TRYMAP_DEC(jisx0213_1_bmp, decoded, c1, c2)) OUTCHAR(decoded);
                else if (TRYMAP_DEC(jisx0213_1_emp, code, c1, c2)) OUTCHAR(EMPBASE | code);
                else if (TRYMAP_DEC(jisx0213_pair, code, c1, c2)) OUTCHAR2(code >> 16, code & 0xffff);
                else return 1;
                NEXT_IN(2);
            } else {   /* Plane 2 */
                if (c1 >= 0x67) c1 += 0x07;
                else if (c1 >= 0x63 || c1 == 0x5f) c1 -= 0x37;
                else c1 -= 0x3d;
                EMULATE_JISX0213_2000_DECODE_PLANE2(writer, c1, c2)
                else if (TRYMAP_DEC(jisx0213_2_bmp, decoded, c1, c2)) OUTCHAR(decoded);
                else if (TRYMAP_DEC(jisx0213_2_emp, code, c1, c2)) { OUTCHAR(EMPBASE | code); NEXT_IN(2); continue; }
                else return 1;
                NEXT_IN(2);
            }
            continue;
        }
        else return 1;
        NEXT_IN(1);   /* JIS X 0201 */
    }
    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// _codecs_iso2022.c
// ════════════════════════════════════════════════════════════════════════
#define ESC 0x1B
#define SO 0x0E
#define SI 0x0F
#define LF 0x0A
#define MAX_ESCSEQLEN 16

#define CHARSET_ISO8859_1 'A'
#define CHARSET_ASCII 'B'
#define CHARSET_ISO8859_7 'F'
#define CHARSET_JISX0201_K 'I'
#define CHARSET_JISX0201_R 'J'
#define CHARSET_DBCS 0x80
#define CHARSET_GB2312 ('A' | CHARSET_DBCS)
#define CHARSET_JISX0208 ('B' | CHARSET_DBCS)
#define CHARSET_KSX1001 ('C' | CHARSET_DBCS)
#define CHARSET_JISX0212 ('D' | CHARSET_DBCS)
#define CHARSET_JISX0213_2000_1 ('O' | CHARSET_DBCS)
#define CHARSET_JISX0213_2 ('P' | CHARSET_DBCS)
#define CHARSET_JISX0213_2004_1 ('Q' | CHARSET_DBCS)
#define CHARSET_JISX0208_O ('@' | CHARSET_DBCS)
#define ESCMARK(mark) ((mark) & 0x7f)

#define IS_ESCEND(c) (((c) >= 'A' && (c) <= 'Z') || (c) == '@')
#define IS_ISO2022ESC(c2) ((c2) == '(' || (c2) == ')' || (c2) == '$' || (c2) == '.' || (c2) == '&')

#define MAP_UNMAPPABLE 0xFFFF
#define MAP_MULTIPLE_AVAIL 0xFFFE   /* for JIS X 0213 */

#define F_SHIFTED 0x01
#define F_ESCTHROUGHOUT 0x02

#define STATE_SETG(dn, v) do { ((state)->c[dn]) = (unsigned char)(v); } while (0)
#define STATE_GETG(dn) ((state)->c[dn])
#define STATE_G0 STATE_GETG(0)
#define STATE_G1 STATE_GETG(1)
#define STATE_G2 STATE_GETG(2)
#define STATE_G3 STATE_GETG(3)
#define STATE_SETG0(v) STATE_SETG(0, v)
#define STATE_SETG1(v) STATE_SETG(1, v)
#define STATE_SETG2(v) STATE_SETG(2, v)
#define STATE_SETG3(v) STATE_SETG(3, v)
#define STATE_SETFLAG(f) do { ((state)->c[4]) |= (f); } while (0)
#define STATE_GETFLAG(f) ((state)->c[4] & (f))
#define STATE_CLEARFLAG(f) do { ((state)->c[4]) &= ~(f); } while (0)
#define STATE_CLEARFLAGS() do { ((state)->c[4]) = 0; } while (0)

#define NO_SHIFT 0x01
#define USE_G2 0x02
#define USE_JISX0208_EXT 0x04

typedef Py_UCS4 (*iso2022_decode_func)(const unsigned char* data);
typedef DBCHAR (*iso2022_encode_func)(const Py_UCS4* data, ssz* length);
struct iso2022_designation {
    unsigned char mark, plane, width;
    iso2022_decode_func decoder;
    iso2022_encode_func encoder;
};
struct iso2022_config {
    int flags;
    const iso2022_designation* designations;
};
#define ISO2022_CONFIG ((const iso2022_config*)config)
#define CONFIG_ISSET(flag) (ISO2022_CONFIG->flags & (flag))
#define CONFIG_DESIGNATIONS (ISO2022_CONFIG->designations)

ENCODER_INIT(iso2022)
{
    (void)config;
    STATE_CLEARFLAGS();
    STATE_SETG0(CHARSET_ASCII);
    STATE_SETG1(CHARSET_ASCII);
    return 0;
}

ENCODER_RESET(iso2022)
{
    (void)config;
    if (STATE_GETFLAG(F_SHIFTED)) { WRITEBYTE1(SI); NEXT_OUT(1); STATE_CLEARFLAG(F_SHIFTED); }
    if (STATE_G0 != CHARSET_ASCII) { WRITEBYTE3(ESC, '(', 'B'); NEXT_OUT(3); STATE_SETG0(CHARSET_ASCII); }
    return 0;
}

ENCODER(iso2022)
{
    while (*inpos < inlen) {
        const iso2022_designation* dsg;
        DBCHAR encoded;
        Py_UCS4 c = INCHAR1;
        ssz insize;
        if (c < 0x80) {
            if (STATE_G0 != CHARSET_ASCII) { WRITEBYTE3(ESC, '(', 'B'); STATE_SETG0(CHARSET_ASCII); NEXT_OUT(3); }
            if (STATE_GETFLAG(F_SHIFTED)) { WRITEBYTE1(SI); STATE_CLEARFLAG(F_SHIFTED); NEXT_OUT(1); }
            WRITEBYTE1((unsigned char)c);
            NEXT(1, 1);
            continue;
        }
        insize = 1;
        encoded = MAP_UNMAPPABLE;
        for (dsg = CONFIG_DESIGNATIONS; dsg->mark; dsg++) {
            Py_UCS4 buf[2] = {c, 0};
            ssz length = 1;
            encoded = dsg->encoder(buf, &length);
            if (encoded == MAP_MULTIPLE_AVAIL) {
                /* this implementation won't work for pair of non-bmp characters. */
                if (inlen - *inpos < 2) {
                    if (!(flags & MBENC_FLUSH)) return MBERR_TOOFEW;
                    length = -1;
                } else {
                    buf[1] = INCHAR2;
                    length = 2;
                }
                encoded = dsg->encoder(buf, &length);
                if (encoded != MAP_UNMAPPABLE) { insize = length; break; }
            }
            else if (encoded != MAP_UNMAPPABLE) break;
        }
        if (!dsg->mark) return 1;
        switch (dsg->plane) {
            case 0: /* G0 */
                if (STATE_GETFLAG(F_SHIFTED)) { WRITEBYTE1(SI); STATE_CLEARFLAG(F_SHIFTED); NEXT_OUT(1); }
                if (STATE_G0 != dsg->mark) {
                    if (dsg->width == 1) { WRITEBYTE3(ESC, '(', ESCMARK(dsg->mark)); STATE_SETG0(dsg->mark); NEXT_OUT(3); }
                    else if (dsg->mark == CHARSET_JISX0208) { WRITEBYTE3(ESC, '$', ESCMARK(dsg->mark)); STATE_SETG0(dsg->mark); NEXT_OUT(3); }
                    else { WRITEBYTE4(ESC, '$', '(', ESCMARK(dsg->mark)); STATE_SETG0(dsg->mark); NEXT_OUT(4); }
                }
                break;
            case 1: /* G1 */
                if (STATE_G1 != dsg->mark) {
                    if (dsg->width == 1) { WRITEBYTE3(ESC, ')', ESCMARK(dsg->mark)); STATE_SETG1(dsg->mark); NEXT_OUT(3); }
                    else { WRITEBYTE4(ESC, '$', ')', ESCMARK(dsg->mark)); STATE_SETG1(dsg->mark); NEXT_OUT(4); }
                }
                if (!STATE_GETFLAG(F_SHIFTED)) { WRITEBYTE1(SO); STATE_SETFLAG(F_SHIFTED); NEXT_OUT(1); }
                break;
            default: /* G2 and G3 is not supported: no encoding in CJKCodecs are using them yet */
                return MBERR_INTERNAL;
        }
        if (dsg->width == 1) { WRITEBYTE1((unsigned char)encoded); NEXT_OUT(1); }
        else { WRITEBYTE2(encoded >> 8, encoded & 0xff); NEXT_OUT(2); }
        NEXT_INCHAR(insize);
    }
    return 0;
}

DECODER_INIT(iso2022)
{
    (void)config;
    STATE_CLEARFLAGS();
    STATE_SETG0(CHARSET_ASCII);
    STATE_SETG1(CHARSET_ASCII);
    STATE_SETG2(CHARSET_ASCII);
    return 0;
}

DECODER_RESET(iso2022)
{
    (void)config;
    STATE_SETG0(CHARSET_ASCII);
    STATE_CLEARFLAG(F_SHIFTED);
    return 0;
}

ssz iso2022processesc(const void* config, MultibyteCodec_State* state, const unsigned char** inbuf, ssz* inleft)
{
    unsigned char charset, designation;
    ssz i, esclen = 0;
    for (i = 1; i < MAX_ESCSEQLEN; i++) {
        if (i >= *inleft) return MBERR_TOOFEW;
        if (IS_ESCEND((*inbuf)[i])) { esclen = i + 1; break; }
        else if (CONFIG_ISSET(USE_JISX0208_EXT) && i + 1 < *inleft && (*inbuf)[i] == '&' && (*inbuf)[i + 1] == '@') {
            i += 2;
        }
    }
    switch (esclen) {
        case 0:
            return 1;   /* unterminated escape sequence */
        case 3:
            if (INBYTE2 == '$') { charset = INBYTE3 | CHARSET_DBCS; designation = 0; }
            else {
                charset = INBYTE3;
                if (INBYTE2 == '(') designation = 0;
                else if (INBYTE2 == ')') designation = 1;
                else if (CONFIG_ISSET(USE_G2) && INBYTE2 == '.') designation = 2;
                else return 3;
            }
            break;
        case 4:
            if (INBYTE2 != '$') return 4;
            charset = INBYTE4 | CHARSET_DBCS;
            if (INBYTE3 == '(') designation = 0;
            else if (INBYTE3 == ')') designation = 1;
            else return 4;
            break;
        case 6: /* designation with prefix */
            if (CONFIG_ISSET(USE_JISX0208_EXT) && (*inbuf)[3] == ESC && (*inbuf)[4] == '$' && (*inbuf)[5] == 'B') {
                charset = 'B' | CHARSET_DBCS;
                designation = 0;
            }
            else return 6;
            break;
        default:
            return esclen;
    }
    /* raise error when the charset is not designated for this encoding */
    if (charset != CHARSET_ASCII) {
        const iso2022_designation* dsg;
        for (dsg = CONFIG_DESIGNATIONS; dsg->mark; dsg++) if (dsg->mark == charset) break;
        if (!dsg->mark) return esclen;
    }
    STATE_SETG(designation, charset);
    *inleft -= esclen;
    (*inbuf) += esclen;
    return 0;
}

#define ISO8859_7_DECODE(c, writer)                                \
    if ((c) < 0xa0) {                                              \
        OUTCHAR(c);                                                \
    } else if ((c) < 0xc0 && (0x288f3bc9L & (1L << ((c)-0xa0)))) { \
        OUTCHAR(c);                                                \
    } else if ((c) >= 0xb4 && (c) <= 0xfe && ((c) >= 0xd4 ||       \
             (0xbffffd77L & (1L << ((c)-0xb4))))) {                \
        OUTCHAR(0x02d0 + (c));                                     \
    } else if ((c) == 0xa1) {                                      \
        OUTCHAR(0x2018);                                           \
    } else if ((c) == 0xa2) {                                      \
        OUTCHAR(0x2019);                                           \
    } else if ((c) == 0xaf) {                                      \
        OUTCHAR(0x2015);                                           \
    }

ssz iso2022processg2(const void* config, MultibyteCodec_State* state, const unsigned char** inbuf, ssz* inleft,
                     Writer& writer)
{
    (void)config;
    /* not written to use encoder, decoder functions because only few encodings use G2 designations in CJKCodecs */
    if (STATE_G2 == CHARSET_ISO8859_1) {
        if (INBYTE3 < 0x80) OUTCHAR(INBYTE3 + 0x80);
        else return 3;
    }
    else if (STATE_G2 == CHARSET_ISO8859_7) {
        ISO8859_7_DECODE(INBYTE3 ^ 0x80, writer)
        else return 3;
    }
    else if (STATE_G2 == CHARSET_ASCII) {
        if (INBYTE3 & 0x80) return 3;
        else OUTCHAR(INBYTE3);
    }
    else return MBERR_INTERNAL;
    (*inbuf) += 3;
    *inleft -= 3;
    return 0;
}

DECODER(iso2022)
{
    const iso2022_designation* dsgcache = NULL;
    while (inleft > 0) {
        unsigned char c = INBYTE1;
        ssz err;
        if (STATE_GETFLAG(F_ESCTHROUGHOUT)) {
            /* ESC throughout mode: for non-iso2022 escape sequences */
            OUTCHAR(c);   /* assume as ISO-8859-1 */
            NEXT_IN(1);
            if (IS_ESCEND(c)) STATE_CLEARFLAG(F_ESCTHROUGHOUT);
            continue;
        }
        switch (c) {
            case ESC:
                REQUIRE_INBUF(2);
                if (IS_ISO2022ESC(INBYTE2)) {
                    err = iso2022processesc(config, state, inbuf, &inleft);
                    if (err != 0) return err;
                }
                else if (CONFIG_ISSET(USE_G2) && INBYTE2 == 'N') {   /* SS2 */
                    REQUIRE_INBUF(3);
                    err = iso2022processg2(config, state, inbuf, &inleft, writer);
                    if (err != 0) return err;
                }
                else {
                    OUTCHAR(ESC);
                    STATE_SETFLAG(F_ESCTHROUGHOUT);
                    NEXT_IN(1);
                }
                break;
            case SI:
                if (CONFIG_ISSET(NO_SHIFT)) goto bypass;
                STATE_CLEARFLAG(F_SHIFTED);
                NEXT_IN(1);
                break;
            case SO:
                if (CONFIG_ISSET(NO_SHIFT)) goto bypass;
                STATE_SETFLAG(F_SHIFTED);
                NEXT_IN(1);
                break;
            case LF:
                STATE_CLEARFLAG(F_SHIFTED);
                OUTCHAR(LF);
                NEXT_IN(1);
                break;
            default:
                if (c < 0x20) goto bypass;   /* C0 */
                else if (c >= 0x80) return 1;
                else {
                    const iso2022_designation* dsg;
                    unsigned char charset;
                    Py_UCS4 decoded;
                    if (STATE_GETFLAG(F_SHIFTED)) charset = STATE_G1;
                    else charset = STATE_G0;
                    if (charset == CHARSET_ASCII) {
                    bypass:
                        OUTCHAR(c);
                        NEXT_IN(1);
                        break;
                    }
                    if (dsgcache != NULL && dsgcache->mark == charset) dsg = dsgcache;
                    else {
                        for (dsg = CONFIG_DESIGNATIONS; dsg->mark != charset && dsg->mark != '\0'; dsg++) ;
                        if (dsg->mark == '\0') return MBERR_INTERNAL;
                        dsgcache = dsg;
                    }
                    REQUIRE_INBUF(dsg->width);
                    decoded = dsg->decoder(*inbuf);
                    if (decoded == MAP_UNMAPPABLE) return dsg->width;
                    if (decoded < 0x10000) OUTCHAR(decoded);
                    else if (decoded < 0x30000) OUTCHAR(decoded);
                    else OUTCHAR2(decoded >> 16, decoded & 0xffff);   /* JIS X 0213 pairs */
                    NEXT_IN(dsg->width);
                }
                break;
        }
    }
    return 0;
}

// the charsets' decoders and encoders
Py_UCS4 ksx1001_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    if (TRYMAP_DEC(ksx1001, u, data[0], data[1])) return u;
    return MAP_UNMAPPABLE;
}
DBCHAR ksx1001_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    (void)length;
    if (*data < 0x10000) {
        if (TRYMAP_ENC(cp949, coded, *data)) {
            if (!(coded & 0x8000)) return coded;
        }
    }
    return MAP_UNMAPPABLE;
}
Py_UCS4 jisx0208_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    if (data[0] == 0x21 && data[1] == 0x40) return 0xff3c;   /* F/W REVERSE SOLIDUS */
    else if (TRYMAP_DEC(jisx0208, u, data[0], data[1])) return u;
    return MAP_UNMAPPABLE;
}
DBCHAR jisx0208_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    (void)length;
    if (*data < 0x10000) {
        if (*data == 0xff3c) return 0x2140;   /* F/W REVERSE SOLIDUS */
        else if (TRYMAP_ENC(jisxcommon, coded, *data)) {
            if (!(coded & 0x8000)) return coded;
        }
    }
    return MAP_UNMAPPABLE;
}
Py_UCS4 jisx0212_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    if (TRYMAP_DEC(jisx0212, u, data[0], data[1])) return u;
    return MAP_UNMAPPABLE;
}
DBCHAR jisx0212_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    (void)length;
    if (*data < 0x10000) {
        if (TRYMAP_ENC(jisxcommon, coded, *data)) {
            if (coded & 0x8000) return coded & 0x7fff;
        }
    }
    return MAP_UNMAPPABLE;
}

#define config ((void*)2000)
Py_UCS4 jisx0213_2000_1_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    EMULATE_JISX0213_2000_DECODE_PLANE1(u, data[0], data[1], MAP_UNMAPPABLE)
    else if (data[0] == 0x21 && data[1] == 0x40) return 0xff3c;   /* F/W REVERSE SOLIDUS */
    else if (TRYMAP_DEC(jisx0208, u, data[0], data[1])) ;
    else if (TRYMAP_DEC(jisx0213_1_bmp, u, data[0], data[1])) ;
    else if (TRYMAP_DEC(jisx0213_1_emp, u, data[0], data[1])) u |= 0x20000;
    else if (TRYMAP_DEC(jisx0213_pair, u, data[0], data[1])) ;
    else return MAP_UNMAPPABLE;
    return u;
}
Py_UCS4 jisx0213_2000_2_decoder(const unsigned char* data)
{
    Py_UCS4 u = 0;
    EMULATE_JISX0213_2000_DECODE_PLANE2_CHAR(u, data[0], data[1])
    if (TRYMAP_DEC(jisx0213_2_bmp, u, data[0], data[1])) ;
    else if (TRYMAP_DEC(jisx0213_2_emp, u, data[0], data[1])) u |= 0x20000;
    else return MAP_UNMAPPABLE;
    return u;
}
#undef config

Py_UCS4 jisx0213_2004_1_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    if (data[0] == 0x21 && data[1] == 0x40) return 0xff3c;   /* F/W REVERSE SOLIDUS */
    else if (TRYMAP_DEC(jisx0208, u, data[0], data[1])) ;
    else if (TRYMAP_DEC(jisx0213_1_bmp, u, data[0], data[1])) ;
    else if (TRYMAP_DEC(jisx0213_1_emp, u, data[0], data[1])) u |= 0x20000;
    else if (TRYMAP_DEC(jisx0213_pair, u, data[0], data[1])) ;
    else return MAP_UNMAPPABLE;
    return u;
}
Py_UCS4 jisx0213_2004_2_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    if (TRYMAP_DEC(jisx0213_2_bmp, u, data[0], data[1])) ;
    else if (TRYMAP_DEC(jisx0213_2_emp, u, data[0], data[1])) u |= 0x20000;
    else return MAP_UNMAPPABLE;
    return u;
}

DBCHAR jisx0213_encoder(const Py_UCS4* data, ssz* length, const void* config)
{
    DBCHAR coded = 0;
    switch (*length) {
        case 1: /* first character */
            if (*data >= 0x10000) {
                if ((*data) >> 16 == 0x20000 >> 16) {
                    EMULATE_JISX0213_2000_ENCODE_EMP(coded, *data, MAP_UNMAPPABLE)
                    else if (TRYMAP_ENC(jisx0213_emp, coded, (*data) & 0xffff)) return coded;
                }
                return MAP_UNMAPPABLE;
            }
            EMULATE_JISX0213_2000_ENCODE_BMP(coded, *data, MAP_UNMAPPABLE)
            else if (TRYMAP_ENC(jisx0213_bmp, coded, *data)) {
                if (coded == MULTIC) return MAP_MULTIPLE_AVAIL;
            }
            else if (TRYMAP_ENC(jisxcommon, coded, *data)) {
                if (coded & 0x8000) return MAP_UNMAPPABLE;
            }
            else return MAP_UNMAPPABLE;
            return coded;
        case 2: /* second character of unicode pair */
            coded = find_pairencmap((ucs2_t)data[0], (ucs2_t)data[1]);
            if (coded != DBCINV) return coded;
            /* fall through */
        case -1: /* flush unterminated */
            *length = 1;
            coded = find_pairencmap((ucs2_t)data[0], 0);
            if (coded == DBCINV) return MAP_UNMAPPABLE;
            return coded;
        default:
            return MAP_UNMAPPABLE;
    }
}
DBCHAR jisx0213_2000_1_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded = jisx0213_encoder(data, length, (void*)2000);
    if (coded == MAP_UNMAPPABLE || coded == MAP_MULTIPLE_AVAIL) return coded;
    else if (coded & 0x8000) return MAP_UNMAPPABLE;
    return coded;
}
DBCHAR jisx0213_2000_1_encoder_paironly(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    ssz ilength = *length;
    coded = jisx0213_encoder(data, length, (void*)2000);
    switch (ilength) {
        case 1:
            if (coded == MAP_MULTIPLE_AVAIL) return MAP_MULTIPLE_AVAIL;
            return MAP_UNMAPPABLE;
        case 2:
            if (*length != 2) return MAP_UNMAPPABLE;
            return coded;
        default:
            return MAP_UNMAPPABLE;
    }
}
DBCHAR jisx0213_2000_2_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded = jisx0213_encoder(data, length, (void*)2000);
    if (coded == MAP_UNMAPPABLE || coded == MAP_MULTIPLE_AVAIL) return coded;
    else if (coded & 0x8000) return coded & 0x7fff;
    return MAP_UNMAPPABLE;
}
DBCHAR jisx0213_2004_1_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded = jisx0213_encoder(data, length, NULL);
    if (coded == MAP_UNMAPPABLE || coded == MAP_MULTIPLE_AVAIL) return coded;
    else if (coded & 0x8000) return MAP_UNMAPPABLE;
    return coded;
}
DBCHAR jisx0213_2004_1_encoder_paironly(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    ssz ilength = *length;
    coded = jisx0213_encoder(data, length, NULL);
    switch (ilength) {
        case 1:
            if (coded == MAP_MULTIPLE_AVAIL) return MAP_MULTIPLE_AVAIL;
            return MAP_UNMAPPABLE;
        case 2:
            if (*length != 2) return MAP_UNMAPPABLE;
            return coded;
        default:
            return MAP_UNMAPPABLE;
    }
}
DBCHAR jisx0213_2004_2_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded = jisx0213_encoder(data, length, NULL);
    if (coded == MAP_UNMAPPABLE || coded == MAP_MULTIPLE_AVAIL) return coded;
    else if (coded & 0x8000) return coded & 0x7fff;
    return MAP_UNMAPPABLE;
}
Py_UCS4 jisx0201_r_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    JISX0201_R_DECODE_CHAR(*data, u)
    else return MAP_UNMAPPABLE;
    return u;
}
DBCHAR jisx0201_r_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    (void)length;
    JISX0201_R_ENCODE(*data, coded)
    else return MAP_UNMAPPABLE;
    return coded;
}
Py_UCS4 jisx0201_k_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    JISX0201_K_DECODE_CHAR(*data ^ 0x80, u)
    else return MAP_UNMAPPABLE;
    return u;
}
DBCHAR jisx0201_k_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    (void)length;
    JISX0201_K_ENCODE(*data, coded)
    else return MAP_UNMAPPABLE;
    return coded - 0x80;
}
Py_UCS4 gb2312_decoder(const unsigned char* data)
{
    Py_UCS4 u;
    if (TRYMAP_DEC(gb2312, u, data[0], data[1])) return u;
    return MAP_UNMAPPABLE;
}
DBCHAR gb2312_encoder(const Py_UCS4* data, ssz* length)
{
    DBCHAR coded;
    (void)length;
    if (*data < 0x10000) {
        if (TRYMAP_ENC(gbcommon, coded, *data)) {
            if (!(coded & 0x8000)) return coded;
        }
    }
    return MAP_UNMAPPABLE;
}
Py_UCS4 dummy_decoder(const unsigned char*) { return MAP_UNMAPPABLE; }
DBCHAR dummy_encoder(const Py_UCS4*, ssz*) { return MAP_UNMAPPABLE; }

#define REGISTRY_KSX1001_G0 {CHARSET_KSX1001, 0, 2, ksx1001_decoder, ksx1001_encoder}
#define REGISTRY_KSX1001_G1 {CHARSET_KSX1001, 1, 2, ksx1001_decoder, ksx1001_encoder}
#define REGISTRY_JISX0201_R {CHARSET_JISX0201_R, 0, 1, jisx0201_r_decoder, jisx0201_r_encoder}
#define REGISTRY_JISX0201_K {CHARSET_JISX0201_K, 0, 1, jisx0201_k_decoder, jisx0201_k_encoder}
#define REGISTRY_JISX0208 {CHARSET_JISX0208, 0, 2, jisx0208_decoder, jisx0208_encoder}
#define REGISTRY_JISX0208_O {CHARSET_JISX0208_O, 0, 2, jisx0208_decoder, jisx0208_encoder}
#define REGISTRY_JISX0212 {CHARSET_JISX0212, 0, 2, jisx0212_decoder, jisx0212_encoder}
#define REGISTRY_JISX0213_2000_1 {CHARSET_JISX0213_2000_1, 0, 2, jisx0213_2000_1_decoder, jisx0213_2000_1_encoder}
#define REGISTRY_JISX0213_2000_1_PAIRONLY {CHARSET_JISX0213_2000_1, 0, 2, jisx0213_2000_1_decoder, jisx0213_2000_1_encoder_paironly}
#define REGISTRY_JISX0213_2000_2 {CHARSET_JISX0213_2, 0, 2, jisx0213_2000_2_decoder, jisx0213_2000_2_encoder}
#define REGISTRY_JISX0213_2004_1 {CHARSET_JISX0213_2004_1, 0, 2, jisx0213_2004_1_decoder, jisx0213_2004_1_encoder}
#define REGISTRY_JISX0213_2004_1_PAIRONLY {CHARSET_JISX0213_2004_1, 0, 2, jisx0213_2004_1_decoder, jisx0213_2004_1_encoder_paironly}
#define REGISTRY_JISX0213_2004_2 {CHARSET_JISX0213_2, 0, 2, jisx0213_2004_2_decoder, jisx0213_2004_2_encoder}
#define REGISTRY_GB2312 {CHARSET_GB2312, 0, 2, gb2312_decoder, gb2312_encoder}
#define REGISTRY_ISO8859_1 {CHARSET_ISO8859_1, 2, 1, dummy_decoder, dummy_encoder}
#define REGISTRY_ISO8859_7 {CHARSET_ISO8859_7, 2, 1, dummy_decoder, dummy_encoder}
#define REGISTRY_SENTINEL {0, 0, 0, nullptr, nullptr}

const iso2022_designation iso2022_kr_designations[] = {REGISTRY_KSX1001_G1, REGISTRY_SENTINEL};
const iso2022_config iso2022_kr_config = {0, iso2022_kr_designations};
const iso2022_designation iso2022_jp_designations[] = {REGISTRY_JISX0208, REGISTRY_JISX0201_R, REGISTRY_JISX0208_O,
                                                       REGISTRY_SENTINEL};
const iso2022_config iso2022_jp_config = {NO_SHIFT | USE_JISX0208_EXT, iso2022_jp_designations};
const iso2022_designation iso2022_jp_1_designations[] = {REGISTRY_JISX0208, REGISTRY_JISX0212, REGISTRY_JISX0201_R,
                                                         REGISTRY_JISX0208_O, REGISTRY_SENTINEL};
const iso2022_config iso2022_jp_1_config = {NO_SHIFT | USE_JISX0208_EXT, iso2022_jp_1_designations};
const iso2022_designation iso2022_jp_2_designations[] = {
    REGISTRY_JISX0208, REGISTRY_JISX0212, REGISTRY_KSX1001_G0, REGISTRY_GB2312, REGISTRY_JISX0201_R,
    REGISTRY_JISX0208_O, REGISTRY_ISO8859_1, REGISTRY_ISO8859_7, REGISTRY_SENTINEL};
const iso2022_config iso2022_jp_2_config = {NO_SHIFT | USE_G2 | USE_JISX0208_EXT, iso2022_jp_2_designations};
const iso2022_designation iso2022_jp_2004_designations[] = {
    REGISTRY_JISX0213_2004_1_PAIRONLY, REGISTRY_JISX0208, REGISTRY_JISX0213_2004_1, REGISTRY_JISX0213_2004_2,
    REGISTRY_SENTINEL};
const iso2022_config iso2022_jp_2004_config = {NO_SHIFT | USE_JISX0208_EXT, iso2022_jp_2004_designations};
const iso2022_designation iso2022_jp_3_designations[] = {
    REGISTRY_JISX0213_2000_1_PAIRONLY, REGISTRY_JISX0208, REGISTRY_JISX0213_2000_1, REGISTRY_JISX0213_2000_2,
    REGISTRY_SENTINEL};
const iso2022_config iso2022_jp_3_config = {NO_SHIFT | USE_JISX0208_EXT, iso2022_jp_3_designations};
const iso2022_designation iso2022_jp_ext_designations[] = {REGISTRY_JISX0208, REGISTRY_JISX0212, REGISTRY_JISX0201_R,
                                                           REGISTRY_JISX0201_K, REGISTRY_JISX0208_O, REGISTRY_SENTINEL};
const iso2022_config iso2022_jp_ext_config = {NO_SHIFT | USE_JISX0208_EXT, iso2022_jp_ext_designations};

// ════════════════════════════════════════════════════════════════════════
// the codec list (CPython's MultibyteCodec)
// ════════════════════════════════════════════════════════════════════════
struct Codec {
    const char* encoding;
    const void* config;
    ssz (*encode)(MultibyteCodec_State*, const void*, const Py_UCS4*, ssz*, ssz, OutBuf&, int);
    int (*encinit)(MultibyteCodec_State*, const void*);
    ssz (*encreset)(MultibyteCodec_State*, const void*, OutBuf&);
    ssz (*decode)(MultibyteCodec_State*, const void*, const unsigned char**, ssz, Writer&);
    int (*decinit)(MultibyteCodec_State*, const void*);
    ssz (*decreset)(MultibyteCodec_State*, const void*);
};
#define STATELESS(name, enc, cfg) {name, cfg, enc##_encode, nullptr, nullptr, enc##_decode, nullptr, nullptr}
#define STATEFUL(name, enc, cfg) \
    {name, cfg, enc##_encode, enc##_encode_init, enc##_encode_reset, enc##_decode, enc##_decode_init, enc##_decode_reset}

const Codec kCodecs[] = {
    STATELESS("gb2312", gb2312, nullptr),
    STATELESS("gbk", gbk, nullptr),
    STATELESS("gb18030", gb18030, nullptr),
    STATEFUL("hz", hz, nullptr),
    STATELESS("euc_kr", euc_kr, nullptr),
    STATELESS("cp949", cp949, nullptr),
    STATELESS("johab", johab, nullptr),
    STATELESS("big5", big5, nullptr),
    STATELESS("cp950", cp950, nullptr),
    STATELESS("big5hkscs", big5hkscs, nullptr),
    STATELESS("shift_jis", shift_jis, nullptr),
    STATELESS("cp932", cp932, nullptr),
    STATELESS("euc_jp", euc_jp, nullptr),
    STATELESS("shift_jis_2004", shift_jis_2004, nullptr),
    STATELESS("euc_jis_2004", euc_jis_2004, nullptr),
    STATELESS("euc_jisx0213", euc_jis_2004, (void*)2000),
    STATELESS("shift_jisx0213", shift_jis_2004, (void*)2000),
    STATEFUL("iso2022_kr", iso2022, &iso2022_kr_config),
    STATEFUL("iso2022_jp", iso2022, &iso2022_jp_config),
    STATEFUL("iso2022_jp_1", iso2022, &iso2022_jp_1_config),
    STATEFUL("iso2022_jp_2", iso2022, &iso2022_jp_2_config),
    STATEFUL("iso2022_jp_2004", iso2022, &iso2022_jp_2004_config),
    STATEFUL("iso2022_jp_3", iso2022, &iso2022_jp_3_config),
    STATEFUL("iso2022_jp_ext", iso2022, &iso2022_jp_ext_config),
};

const Codec* find_codec(const std::string& name) {
    for (const Codec& c : kCodecs) if (name == c.encoding) return &c;
    return nullptr;
}

// ════════════════════════════════════════════════════════════════════════
// multibytecodec.c: the encode and decode loops with the error handlers
// ════════════════════════════════════════════════════════════════════════
// The error handler: one of CPython's builtin ones, or Stop (a handler
// registered with codecs.register_error: the loop stops at the error and
// lib/_multibytecodec.ny calls it).
enum class H { Strict, Ignore, Replace, Backslash, XmlRef, NameRep, SurrEsc, SurrPass, Stop };
bool handler_of(const std::string& e, H& h) {
    if (e.empty() || e == "strict") h = H::Strict;
    else if (e == "ignore") h = H::Ignore;
    else if (e == "replace") h = H::Replace;
    else if (e == "backslashreplace") h = H::Backslash;
    else if (e == "xmlcharrefreplace") h = H::XmlRef;
    else if (e == "namereplace") h = H::NameRep;
    else if (e == "surrogateescape") h = H::SurrEsc;
    else if (e == "surrogatepass") h = H::SurrPass;
    else if (e == "__ny_stop__") h = H::Stop;
    else return false;
    return true;
}

struct Err {
    bool hit = false;
    ssz start = 0, end = 0;
    std::string reason;
};

std::string utf8_of(const std::vector<Py_UCS4>& v, size_t a = 0, size_t b = (size_t)-1) {
    std::string r;
    if (b > v.size()) b = v.size();
    for (size_t i = a; i < b; i++) nypy::u8_encode(v[i], r);
    return r;
}

std::string mb_encode(const Codec& c, MultibyteCodec_State& st, const std::vector<Py_UCS4>& in, ssz& inpos, H h, int flags, Err& err);

// multibytecodec_encerror; false: stop (the "stop" handler)
bool encerror(const Codec& c, MultibyteCodec_State& st, const std::vector<Py_UCS4>& in, ssz& inpos, OutBuf& ob, H h,
              ssz e, Err& err) {
    const char* reason;
    ssz esize;
    if (e > 0) { reason = "illegal multibyte sequence"; esize = e; }
    else if (e == MBERR_TOOFEW) { reason = "incomplete multibyte sequence"; esize = inpos; }
    else if (e == MBERR_INTERNAL) nypy::raise("RuntimeError", "internal codec error");
    else nypy::raise("RuntimeError", "unknown runtime error");
    ssz start = inpos, end = inpos + esize;
    if (end > (ssz)in.size()) end = (ssz)in.size();
    if (h == H::Replace) {
        Py_UCS4 q = '?';
        ssz qpos = 0;
        ssz r = c.encode(&st, c.config, &q, &qpos, 1, ob, 0);
        if (r != 0) { ob.put(0, '?'); ob.pos++; }
    }
    if (h == H::Ignore || h == H::Replace) { inpos += esize; return true; }
    auto raise_it = [&]() { nypy::cx_raise_encode(c.encoding, utf8_of(in), in, start, end, reason); };
    if (h == H::Strict || h == H::SurrPass) raise_it();
    if (h == H::Stop) { err.hit = true; err.start = start; err.end = end; err.reason = reason; return false; }
    // the builtin handlers' replacements (codecs.c), encoded by the codec
    std::vector<Py_UCS4> rep;
    auto put = [&](const std::string& s) { for (unsigned char ch : s) rep.push_back(ch); };
    if (h == H::SurrEsc) {
        std::string bytes;
        for (ssz k = start; k < end; k++) {
            if (in[(size_t)k] < 0xDC80 || in[(size_t)k] > 0xDCFF) raise_it();
            bytes += (char)(in[(size_t)k] - 0xDC00);
        }
        ob.need(bytes.size());
        for (size_t k = 0; k < bytes.size(); k++) ob.put(k, (unsigned char)bytes[k]);
        ob.pos += bytes.size();
        inpos = end;
        return true;
    }
    for (ssz k = start; k < end; k++) {
        Py_UCS4 ch = in[(size_t)k];
        if (h == H::XmlRef) put("&#" + std::to_string(ch) + ";");
        else if (h == H::NameRep) {
            std::string nm = nyuni::name(ch);
            if (!nm.empty()) put("\\N{" + nm + "}");
            else put(nypy::cx_charrepr(ch));
        }
        else put(nypy::cx_charrepr(ch));
    }
    Err sub;
    ssz rpos = 0;
    std::string bytes = mb_encode(c, st, rep, rpos, H::Strict, MBENC_FLUSH, sub);
    ob.need(bytes.size());
    for (size_t k = 0; k < bytes.size(); k++) ob.put(k, (unsigned char)bytes[k]);
    ob.pos += bytes.size();
    inpos = end;
    return true;
}

std::string mb_encode(const Codec& c, MultibyteCodec_State& st, const std::vector<Py_UCS4>& in, ssz& inpos, H h, int flags, Err& err) {
    OutBuf ob;
    ssz inlen = (ssz)in.size();
    if (inlen == 0 && !(flags & MBENC_RESET)) return std::string();
    ob.s.reserve(in.size() * 2 + 16);
    while (inpos < inlen) {
        ssz r = c.encode(&st, c.config, in.data(), &inpos, inlen, ob, flags);
        if (r == 0 || (r == MBERR_TOOFEW && !(flags & MBENC_FLUSH))) break;
        if (!encerror(c, st, in, inpos, ob, h, r, err)) return ob.take();
        if (r == MBERR_TOOFEW) break;
    }
    if (c.encreset && (flags & MBENC_RESET)) c.encreset(&st, c.config, ob);
    return ob.take();
}

// multibytecodec_decerror; false: stop
bool decerror(const Codec& c, const std::string& data, const unsigned char*& inbuf, const unsigned char* top,
              const unsigned char* end, Writer& w, H h, ssz e, Err& err) {
    const char* reason;
    ssz esize;
    if (e > 0) { reason = "illegal multibyte sequence"; esize = e; }
    else if (e == MBERR_TOOFEW) { reason = "incomplete multibyte sequence"; esize = (ssz)(end - inbuf); }
    else if (e == MBERR_INTERNAL) nypy::raise("RuntimeError", "internal codec error");
    else nypy::raise("RuntimeError", "unknown runtime error");
    if (h == H::Replace) w.push_back(0xFFFD);
    if (h == H::Ignore || h == H::Replace) { inbuf += esize; return true; }
    ssz start = (ssz)(inbuf - top), stop = start + esize;
    auto raise_it = [&]() { nypy::cx_raise_decode(c.encoding, data, start, stop, reason); };
    if (h == H::Strict || h == H::SurrPass) raise_it();
    if (h == H::Stop) { err.hit = true; err.start = start; err.end = stop; err.reason = reason; return false; }
    if (h == H::XmlRef || h == H::NameRep) nypy::raise("TypeError", "don't know how to handle UnicodeDecodeError in error callback");
    if (h == H::SurrEsc) {
        ssz k = 0;
        while (k < 4 && start + k < stop && (unsigned char)data[(size_t)(start + k)] >= 0x80) {
            w.push_back(0xDC00 + (unsigned char)data[(size_t)(start + k)]);
            k++;
        }
        if (k == 0) raise_it();
        inbuf = top + start + k;
        return true;
    }
    static const char* hx = "0123456789abcdef";
    for (ssz k = start; k < stop; k++) {
        unsigned char x = (unsigned char)data[(size_t)k];
        w.push_back('\\'); w.push_back('x'); w.push_back((unsigned char)hx[x >> 4]); w.push_back((unsigned char)hx[x & 15]);
    }
    inbuf = top + stop;
    return true;
}

// final: an incomplete sequence at the end is an error (MultibyteCodec.decode,
// IncrementalDecoder.decode(final=True)); else it is left unconsumed
std::string mb_decode(const Codec& c, MultibyteCodec_State& st, const std::string& data, ssz& pos, H h, bool final, Err& err) {
    Writer w;
    w.reserve(data.size());
    const unsigned char* top = (const unsigned char*)data.data();
    const unsigned char* end = top + data.size();
    const unsigned char* inbuf = top + pos;
    while (inbuf < end) {
        ssz inleft = (ssz)(end - inbuf);
        ssz r = c.decode(&st, c.config, &inbuf, inleft, w);
        if (r == 0) break;
        if (r == MBERR_TOOFEW && !final) break;
        if (!decerror(c, data, inbuf, top, end, w, h, r, err)) break;
    }
    pos = (ssz)(inbuf - top);
    return utf8_of(w);
}

std::vector<Py_UCS4> cps_of(const std::string& s) { return nypy::cx_codepoints(s); }

uint64_t pack(const MultibyteCodec_State& st) {
    uint64_t v = 0;
    for (int k = 0; k < 8; k++) v |= (uint64_t)st.c[k] << (8 * k);
    return v;
}
MultibyteCodec_State unpack(uint64_t v) {
    MultibyteCodec_State st;
    for (int k = 0; k < 8; k++) st.c[k] = (unsigned char)(v >> (8 * k));
    return st;
}

// CPython's encodings.aliases for these codecs (tools/gen_cjk_codecs.py)
struct Alias { const char* alias; const char* codec; };
#include "nycjk_aliases.inc"

}  // namespace

std::string codec_of(const std::string& encoding) {
    std::string n = nypy::codec_normalize(encoding);
    for (const Codec& c : kCodecs) if (n == c.encoding) return n;
    std::string n2 = n;
    for (auto& ch : n2) if (ch == '.') ch = '_';
    for (const Alias& a : kCjkAliases) if (n == a.alias || n2 == a.alias) return a.codec;
    return std::string();
}

std::string encode_all(const std::string& codec, const std::string& s, const std::string& errors) {
    const Codec* c = find_codec(codec);
    H h;
    if (!c || !handler_of(errors, h) || h == H::Stop) nypy::raise("LookupError", "unknown error handler name '" + errors + "'");
    ensure_tables();
    MultibyteCodec_State st{};
    if (c->encinit) c->encinit(&st, c->config);
    std::vector<Py_UCS4> in = cps_of(s);
    ssz pos = 0;
    Err err;
    return mb_encode(*c, st, in, pos, h, MBENC_FLUSH | MBENC_RESET, err);
}

std::string decode_all(const std::string& codec, const std::string& b, const std::string& errors) {
    const Codec* c = find_codec(codec);
    H h;
    if (!c || !handler_of(errors, h) || h == H::Stop) nypy::raise("LookupError", "unknown error handler name '" + errors + "'");
    ensure_tables();
    MultibyteCodec_State st{};
    if (c->decinit) c->decinit(&st, c->config);
    ssz pos = 0;
    Err err;
    if (b.empty()) return std::string();
    return mb_decode(*c, st, b, pos, h, true, err);
}

}  // namespace nycjk

// ── _ny_mbc: lib/_multibytecodec.ny's native ─────────────────────────────
//   ("codecs") -> the codec names
//   ("lookup", encoding) -> its codec's name, or None
//   ("encinit" | "decinit", codec) -> the initial state (an int: the eight
//       state bytes, little-endian, as CPython's getstate gives them)
//   ("encode", codec, str, errors, state, flags, pos) -> (bytes, pos, err, state)
//       flags: 1 flush, 2 reset (CPython's MBENC_*); err None or (start, end,
//       reason) when errors is "__ny_stop__"
//   ("decode", codec, bytes, errors, state, final, pos) -> (str, pos, err, state)
//   ("encreset", codec, state) -> (bytes, state);  ("decreset", codec, state) -> state
Value dispatch_mbc(NythonExecutor& E, std::vector<Value>& args) {
    using namespace nycjk;
    auto S = [&](size_t i) -> std::string { return i < args.size() ? E.getStringValue(args[i]) : std::string(); };
    auto tuple = [&](const std::vector<Value>& items) {
        Value t = nyos::make_list(E, items);
        if (auto* o = dynamic_cast<Object*>((Collectable*)t.value.p)) o->set("__tuple__", Value(1));
        return t;
    };
    std::string op = S(0);
    if (op == "codecs") {
        std::vector<Value> v;
        for (const Codec& c : kCodecs) v.push_back(E.makeStringValue(c.encoding));
        return nyos::make_list(E, v);
    }
    if (op == "lookup") {
        std::string n = codec_of(S(1));
        return n.empty() ? NONE_VALUE : E.makeStringValue(n);
    }
    const Codec* c = find_codec(S(1));
    if (!c) nyos::raise("LookupError", "no such codec is supported.");
    ensure_tables();
    auto state_at = [&](size_t i, bool enc) {
        MultibyteCodec_State st{};
        if (i < args.size() && args[i].type != ValueType::NONE) st = unpack((uint64_t)nyos::to_int(args[i], 0));
        else if (enc && c->encinit) c->encinit(&st, c->config);
        else if (!enc && c->decinit) c->decinit(&st, c->config);
        return st;
    };
    auto state_val = [&](const MultibyteCodec_State& st) { return nyos::make_int((long long)pack(st)); };
    if (op == "encinit") return state_val(state_at(99, true));
    if (op == "decinit") return state_val(state_at(99, false));
    if (op == "encreset") {
        MultibyteCodec_State st = state_at(2, true);
        OutBuf ob;
        if (c->encreset) c->encreset(&st, c->config, ob);
        return tuple({E.makeBytesValue(ob.take()), state_val(st)});
    }
    if (op == "decreset") {
        MultibyteCodec_State st = state_at(2, false);
        if (c->decreset) c->decreset(&st, c->config);
        return state_val(st);
    }
    std::string errors = args.size() > 3 && args[3].type != ValueType::NONE ? S(3) : std::string("strict");
    H h;
    if (!handler_of(errors, h)) nyos::raise("LookupError", "unknown error handler name '" + errors + "'");
    Err err;
    Value out, errv = NONE_VALUE;
    long long pos = args.size() > 6 ? nyos::to_int(args[6], 0) : 0;
    if (pos < 0) pos = 0;
    ssz p = pos;
    MultibyteCodec_State st;
    if (op == "encode") {
        st = state_at(4, true);
        int flags = (int)(args.size() > 5 ? nyos::to_int(args[5], 3) : 3);
        std::vector<Py_UCS4> in = cps_of(S(2));
        if (p > (ssz)in.size()) p = (ssz)in.size();
        std::string r = E.nyCall([&] { return mb_encode(*c, st, in, p, h, flags, err); });
        out = E.makeBytesValue(r);
    } else if (op == "decode") {
        st = state_at(4, false);
        bool final = args.size() <= 5 || E.isTruthy(args[5]);
        auto* bo = args.size() > 2 ? E.bytesOf(args[2]) : nullptr;
        if (!bo) nyos::raise("TypeError", "a bytes-like object is required, not '" + (args.size() > 2 ? E.typeNameOf(args[2]) : std::string("NoneType")) + "'");
        std::string data = bo->s;
        if (p > (ssz)data.size()) p = (ssz)data.size();
        std::string r = E.nyCall([&] { return mb_decode(*c, st, data, p, h, final, err); });
        out = E.makeStringValue(r);
    } else {
        nyos::raise("ValueError", "_ny_mbc: unknown operation '" + op + "'");
    }
    if (err.hit) errv = tuple({nyos::make_int(err.start), nyos::make_int(err.end), E.makeStringValue(err.reason)});
    return tuple({out, nyos::make_int(p), errv, state_val(st)});
}
