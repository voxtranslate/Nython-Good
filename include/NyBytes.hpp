#pragma once
// NyBytes.hpp - Python bytes / bytearray semantics and the text codecs,
// shared by both engines (round 77).
//
// A bytes value is a std::string of raw bytes: indexing gives an int,
// slicing gives bytes, len counts bytes - where a str counts characters.
// The engines convert a call's arguments to BArg, call bytes_method and turn
// the BRes back into their own values, so every method has exactly one
// implementation (as NyStr.hpp's str_method). A bytearray method mutates the
// engine's storage through the `data` reference it is given.
//
// Errors are nypy::PyError{type, message} with Python's messages.
#include <cstdint>
#include <string>
#include <vector>
#include <cstring>
#include <cmath>
#include "NyStr.hpp"
#include "NyBigInt.hpp"

namespace nypy {

// ── repr ────────────────────────────────────────────────────────────────
// b'...' as Python writes it: single quotes unless the bytes hold a single
// quote and no double quote; \t \n \r, \\ and the quote escaped; other
// bytes outside 0x20..0x7e as \xNN.
inline std::string bytes_repr(const std::string& s, bool bytearray = false) {
    bool sq = s.find('\'') != std::string::npos, dq = s.find('"') != std::string::npos;
    char q = (sq && !dq) ? '"' : '\'';
    std::string r;
    r.reserve(s.size() + 3);
    r += 'b'; r += q;
    static const char* hx = "0123456789abcdef";
    for (unsigned char c : s) {
        if (c == (unsigned char)q || c == '\\') { r += '\\'; r += (char)c; }
        else if (c == '\t') r += "\\t";
        else if (c == '\n') r += "\\n";
        else if (c == '\r') r += "\\r";
        else if (c < 0x20 || c >= 0x7f) { r += "\\x"; r += hx[c >> 4]; r += hx[c & 15]; }
        else r += (char)c;
    }
    r += q;
    return bytearray ? "bytearray(" + r + ")" : r;
}

// ── hex / fromhex ───────────────────────────────────────────────────────
// b.hex(sep="", bytes_per_sep=1): a positive group size counts from the
// right, a negative one from the left (Python's rule).
inline std::string bytes_hex(const std::string& s, const std::string& sep = "", int64_t per = 1) {
    static const char* hx = "0123456789abcdef";
    std::string r;
    if (s.empty()) return r;
    if (sep.empty() || per == 0) {
        r.reserve(s.size() * 2);
        for (unsigned char c : s) { r += hx[c >> 4]; r += hx[c & 15]; }
        return r;
    }
    if (sep.size() != 1) raise("ValueError", "sep must be length 1.");
    if ((unsigned char)sep[0] >= 0x80) raise("ValueError", "sep must be ASCII.");
    size_t g = (size_t)(per < 0 ? -per : per);
    size_t n = s.size();
    for (size_t i = 0; i < n; i++) {
        if (i) {
            // a separator before byte i when a group boundary falls there
            bool cut = per > 0 ? ((n - i) % g == 0) : (i % g == 0);
            if (cut) r += sep;
        }
        unsigned char c = (unsigned char)s[i];
        r += hx[c >> 4]; r += hx[c & 15];
    }
    return r;
}
inline int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
inline std::string bytes_fromhex(const std::string& s) {
    std::string r;
    size_t i = 0, n = s.size();
    while (i < n) {
        unsigned char c = (unsigned char)s[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f') { i++; continue; }
        int hi = hex_digit((char)c);
        if (hi < 0) raise("ValueError", "non-hexadecimal number found in fromhex() arg at position " + std::to_string(u8_char_index(s, i)));
        if (i + 1 >= n) raise("ValueError", "non-hexadecimal number found in fromhex() arg at position " + std::to_string(u8_char_index(s, i) + 1));
        int lo = hex_digit(s[i + 1]);
        if (lo < 0) raise("ValueError", "non-hexadecimal number found in fromhex() arg at position " + std::to_string(u8_char_index(s, i + 1)));
        r += (char)(hi * 16 + lo);
        i += 2;
    }
    return r;
}

// ── codecs ──────────────────────────────────────────────────────────────
enum class Codec { UTF8, ASCII, LATIN1, UTF16, UTF16LE, UTF16BE, UTF32, UTF32LE, UTF32BE };
inline Codec codec_of(const std::string& name) {
    std::string n;
    for (char c : name) {
        if (c == ' ') continue;
        n += (c == '_') ? '-' : (char)((c >= 'A' && c <= 'Z') ? c + 32 : c);
    }
    if (n == "utf-8" || n == "utf8" || n == "u8" || n == "utf" || n == "cp65001" || n == "utf-8-sig") return Codec::UTF8;
    if (n == "ascii" || n == "us-ascii" || n == "646" || n == "us") return Codec::ASCII;
    if (n == "latin-1" || n == "latin1" || n == "latin" || n == "l1" || n == "iso-8859-1" || n == "iso8859-1" ||
        n == "8859" || n == "cp819" || n == "iso-ir-100") return Codec::LATIN1;
    if (n == "utf-16" || n == "utf16" || n == "u16") return Codec::UTF16;
    if (n == "utf-16-le" || n == "utf-16le" || n == "utf16le") return Codec::UTF16LE;
    if (n == "utf-16-be" || n == "utf-16be" || n == "utf16be") return Codec::UTF16BE;
    if (n == "utf-32" || n == "utf32" || n == "u32") return Codec::UTF32;
    if (n == "utf-32-le" || n == "utf-32le" || n == "utf32le") return Codec::UTF32LE;
    if (n == "utf-32-be" || n == "utf-32be" || n == "utf32be") return Codec::UTF32BE;
    raise("LookupError", "unknown encoding: " + name);
}
inline const char* codec_name(Codec c) {
    switch (c) {
        case Codec::UTF8: return "utf-8";
        case Codec::ASCII: return "ascii";
        case Codec::LATIN1: return "latin-1";
        case Codec::UTF16: return "utf-16";
        case Codec::UTF16LE: return "utf-16-le";
        case Codec::UTF16BE: return "utf-16-be";
        case Codec::UTF32: return "utf-32";
        case Codec::UTF32LE: return "utf-32-le";
        default: return "utf-32-be";
    }
}
// (not STRICT/IGNORE/...: windows.h defines those as macros)
enum class ErrMode { Strict, Ignore, Replace, Backslash, XmlCharRef, NameReplace };
inline ErrMode errmode_of(const std::string& e) {
    if (e.empty() || e == "strict") return ErrMode::Strict;
    if (e == "ignore") return ErrMode::Ignore;
    if (e == "replace") return ErrMode::Replace;
    if (e == "backslashreplace") return ErrMode::Backslash;
    if (e == "xmlcharrefreplace") return ErrMode::XmlCharRef;
    if (e == "namereplace") return ErrMode::NameReplace;
    raise("LookupError", "unknown error handler name '" + e + "'");
}

// Length of the valid UTF-8 sequence at i, or the length of the maximal
// invalid subpart (negated) - the unit Python reports and replaces. `why`
// says what was wrong with an invalid one.
inline int utf8_unit(const std::string& s, size_t i, const char*& why) {
    size_t n = s.size();
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) return 1;
    int need; unsigned char lo = 0x80, hi = 0xBF;
    if (c >= 0xC2 && c <= 0xDF) need = 1;
    else if (c == 0xE0) { need = 2; lo = 0xA0; }
    else if (c >= 0xE1 && c <= 0xEC) need = 2;
    else if (c == 0xED) { need = 2; hi = 0x9F; }
    else if (c >= 0xEE && c <= 0xEF) need = 2;
    else if (c == 0xF0) { need = 3; lo = 0x90; }
    else if (c >= 0xF1 && c <= 0xF3) need = 3;
    else if (c == 0xF4) { need = 3; hi = 0x8F; }
    else { why = "invalid start byte"; return -1; }
    for (int k = 1; k <= need; k++) {
        if (i + k >= n) { why = "unexpected end of data"; return -k; }
        unsigned char d = (unsigned char)s[i + k];
        unsigned char l = (k == 1) ? lo : 0x80, h = (k == 1) ? hi : 0xBF;
        if (d < l || d > h) { why = "invalid continuation byte"; return -k; }
    }
    return need + 1;
}
inline std::string hex2(unsigned char c) {
    static const char* hx = "0123456789abcdef";
    std::string r = "0x"; r += hx[c >> 4]; r += hx[c & 15]; return r;
}
[[noreturn]] inline void decode_error(Codec c, const std::string& s, size_t a, size_t b, const char* why) {
    std::string m = std::string("'") + codec_name(c) + "' codec can't decode ";
    if (b - a == 1) m += "byte " + hex2((unsigned char)s[a]) + " in position " + std::to_string(a);
    else m += "bytes in position " + std::to_string(a) + "-" + std::to_string(b - 1);
    raise("UnicodeDecodeError", m + ": " + why);
}
inline void decode_bad(ErrMode e, Codec c, const std::string& s, size_t a, size_t b, const char* why, std::string& out) {
    static const char* hx = "0123456789abcdef";
    switch (e) {
        case ErrMode::Strict: decode_error(c, s, a, b, why);
        case ErrMode::Ignore: return;
        case ErrMode::Replace: out += "\xEF\xBF\xBD"; return;
        case ErrMode::Backslash:
            for (size_t k = a; k < b; k++) { unsigned char x = (unsigned char)s[k]; out += "\\x"; out += hx[x >> 4]; out += hx[x & 15]; }
            return;
        default: raise("TypeError", "don't know how to handle UnicodeDecodeError in error callback");
    }
}
inline std::string decode_utf16(const std::string& s, Codec c, ErrMode e) {
    std::string out;
    size_t i = 0, n = s.size();
    bool le = c != Codec::UTF16BE;
    if (c == Codec::UTF16 && n >= 2) {
        if ((unsigned char)s[0] == 0xFF && (unsigned char)s[1] == 0xFE) { le = true; i = 2; }
        else if ((unsigned char)s[0] == 0xFE && (unsigned char)s[1] == 0xFF) { le = false; i = 2; }
    }
    auto unit = [&](size_t k) -> uint32_t {
        unsigned char x = (unsigned char)s[k], y = (unsigned char)s[k + 1];
        return le ? (uint32_t)(x | (y << 8)) : (uint32_t)((x << 8) | y);
    };
    while (i < n) {
        if (i + 1 >= n) { decode_bad(e, c, s, i, n, "truncated data", out); break; }
        uint32_t u = unit(i);
        if (u >= 0xD800 && u <= 0xDBFF) {
            if (i + 3 >= n) { decode_bad(e, c, s, i, n, "unexpected end of data", out); break; }
            uint32_t v = unit(i + 2);
            if (v < 0xDC00 || v > 0xDFFF) { decode_bad(e, c, s, i, i + 2, "illegal UTF-16 surrogate", out); i += 2; continue; }
            u8_encode(0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00), out);
            i += 4; continue;
        }
        if (u >= 0xDC00 && u <= 0xDFFF) { decode_bad(e, c, s, i, i + 2, "illegal encoding", out); i += 2; continue; }
        u8_encode(u, out);
        i += 2;
    }
    return out;
}
inline std::string decode_utf32(const std::string& s, Codec c, ErrMode e) {
    std::string out;
    size_t i = 0, n = s.size();
    bool le = c != Codec::UTF32BE;
    if (c == Codec::UTF32 && n >= 4) {
        if (s.compare(0, 4, std::string("\xFF\xFE\0\0", 4)) == 0) { le = true; i = 4; }
        else if (s.compare(0, 4, std::string("\0\0\xFE\xFF", 4)) == 0) { le = false; i = 4; }
    }
    while (i < n) {
        if (i + 3 >= n) { decode_bad(e, c, s, i, n, "truncated data", out); break; }
        uint32_t u = 0;
        for (int k = 0; k < 4; k++) {
            uint32_t b = (unsigned char)s[i + (size_t)(le ? k : 3 - k)];
            u |= b << (8 * k);
        }
        if (u > 0x10FFFF || (u >= 0xD800 && u <= 0xDFFF)) { decode_bad(e, c, s, i, i + 4, "code point not in range(0x110000)", out); i += 4; continue; }
        u8_encode(u, out);
        i += 4;
    }
    return out;
}
inline std::string bytes_decode(const std::string& s, const std::string& encoding = "utf-8", const std::string& errors = "strict") {
    Codec c = codec_of(encoding);
    ErrMode e = errmode_of(errors);
    std::string out;
    switch (c) {
        case Codec::UTF8: {
            size_t i = 0, n = s.size();
            // utf-8-sig drops a leading BOM
            std::string en;
            for (char ch : encoding) en += (char)((ch >= 'A' && ch <= 'Z') ? ch + 32 : ch);
            if ((en == "utf-8-sig" || en == "utf_8_sig") && n >= 3 && s.compare(0, 3, "\xEF\xBB\xBF") == 0) i = 3;
            if (i == 0 && is_ascii(s)) return s;
            out.reserve(n);
            while (i < n) {
                const char* why = "";
                int u = utf8_unit(s, i, why);
                if (u > 0) { out.append(s, i, (size_t)u); i += (size_t)u; continue; }
                size_t b = i + (size_t)(-u);
                decode_bad(e, c, s, i, b, why, out);
                i = b;
            }
            return out;
        }
        case Codec::ASCII:
            for (size_t i = 0; i < s.size(); i++) {
                unsigned char x = (unsigned char)s[i];
                if (x < 0x80) out += (char)x;
                else decode_bad(e, c, s, i, i + 1, "ordinal not in range(128)", out);
            }
            return out;
        case Codec::LATIN1:
            for (unsigned char x : s) u8_encode(x, out);
            return out;
        case Codec::UTF16: case Codec::UTF16LE: case Codec::UTF16BE: return decode_utf16(s, c, e);
        default: return decode_utf32(s, c, e);
    }
}

// str -> bytes. The str is UTF-8 already; its code points are re-encoded.
// A malformed byte in it (a str read from a binary file) is kept as is by
// utf-8 and counts as U+FFFD for the others.
inline void encode_bad(ErrMode e, Codec c, const std::string& s, uint32_t cp, int64_t pos, int64_t limit, std::string& out) {
    switch (e) {
        case ErrMode::Strict: {
            std::string m = std::string("'") + codec_name(c) + "' codec can't encode character '";
            char buf[16];
            if (cp <= 0xFF) std::snprintf(buf, sizeof buf, "\\x%02x", cp);
            else if (cp <= 0xFFFF) std::snprintf(buf, sizeof buf, "\\u%04x", cp);
            else std::snprintf(buf, sizeof buf, "\\U%08x", cp);
            raise("UnicodeEncodeError", m + buf + "' in position " + std::to_string(pos) + ": ordinal not in range(" + std::to_string(limit) + ")");
        }
        case ErrMode::Ignore: return;
        case ErrMode::Replace: out += '?'; return;
        case ErrMode::Backslash: case ErrMode::NameReplace: {
            char buf[16];
            if (cp <= 0xFF) std::snprintf(buf, sizeof buf, "\\x%02x", cp);
            else if (cp <= 0xFFFF) std::snprintf(buf, sizeof buf, "\\u%04x", cp);
            else std::snprintf(buf, sizeof buf, "\\U%08x", cp);
            out += buf; return;
        }
        case ErrMode::XmlCharRef: out += "&#" + std::to_string(cp) + ";"; return;
    }
    (void)s;
}
inline std::string str_encode(const std::string& s, const std::string& encoding = "utf-8", const std::string& errors = "strict") {
    Codec c = codec_of(encoding);
    ErrMode e = errmode_of(errors);
    if (c == Codec::UTF8) {
        std::string en;
        for (char ch : encoding) en += (char)((ch >= 'A' && ch <= 'Z') ? ch + 32 : ch);
        if (en == "utf-8-sig" || en == "utf_8_sig") return "\xEF\xBB\xBF" + s;
        return s;
    }
    if ((c == Codec::ASCII || c == Codec::LATIN1) && is_ascii(s)) return s;
    std::string out;
    out.reserve(s.size() * (c == Codec::UTF32 || c == Codec::UTF32LE || c == Codec::UTF32BE ? 4 : 2));
    bool le = !(c == Codec::UTF16BE || c == Codec::UTF32BE);
    if (c == Codec::UTF16) out += "\xFF\xFE";
    if (c == Codec::UTF32) out += std::string("\xFF\xFE\0\0", 4);
    auto put16 = [&](uint32_t u) {
        if (le) { out += (char)(u & 0xFF); out += (char)(u >> 8); }
        else { out += (char)(u >> 8); out += (char)(u & 0xFF); }
    };
    int64_t pos = 0;
    for (size_t i = 0; i < s.size(); pos++) {
        const char* why = "";
        int u = utf8_unit(s, i, why);
        uint32_t cp;
        if (u > 0) { size_t j = i; cp = u8_decode(s, j); i = j; }
        else { cp = 0xFFFD; i += (size_t)(-u); }
        switch (c) {
            case Codec::ASCII:
                if (cp < 0x80) out += (char)cp; else encode_bad(e, c, s, cp, pos, 128, out);
                break;
            case Codec::LATIN1:
                if (cp < 0x100) out += (char)cp; else encode_bad(e, c, s, cp, pos, 256, out);
                break;
            case Codec::UTF16: case Codec::UTF16LE: case Codec::UTF16BE:
                if (cp >= 0x10000) { uint32_t v = cp - 0x10000; put16(0xD800 + (v >> 10)); put16(0xDC00 + (v & 0x3FF)); }
                else put16(cp);
                break;
            default:
                for (int k = 0; k < 4; k++) out += (char)((cp >> (8 * (le ? k : 3 - k))) & 0xFF);
                break;
        }
    }
    return out;
}

// ── int.from_bytes / int.to_bytes ───────────────────────────────────────
// 2**bits as a BigInt.
inline BigInt pow2_big(size_t bits) {
    BigInt m;
    m.mag.assign(bits / 32 + 1, 0);
    m.mag[bits / 32] = 1u << (bits % 32);
    return m;
}
inline BigInt int_from_bytes(const std::string& s, bool little, bool is_signed) {
    BigInt r;
    size_t n = s.size();
    r.mag.assign((n + 3) / 4, 0);
    for (size_t k = 0; k < n; k++) {
        uint32_t c = (unsigned char)s[little ? k : n - 1 - k];
        r.mag[k / 4] |= c << (8 * (k % 4));
    }
    r.trim();
    if (is_signed && n > 0 && ((unsigned char)s[little ? n - 1 : 0] & 0x80)) r = r - pow2_big(8 * n);
    return r;
}
inline std::string int_to_bytes(const BigInt& v, int64_t length, bool little, bool is_signed) {
    if (length < 0) raise("ValueError", "length argument must be non-negative");
    if (!is_signed && v.neg) raise("OverflowError", "can't convert negative int to unsigned");
    size_t bits = (size_t)length * 8;
    BigInt x = v;
    if (is_signed) {
        BigInt half = bits ? pow2_big(bits - 1) : BigInt(0);
        bool fits = bits ? (!(x < -half) && x < half) : x.is_zero();
        if (!fits) raise("OverflowError", "int too big to convert");
        if (x.neg) x = x + pow2_big(bits);
    } else if (!(x < pow2_big(bits))) {
        raise("OverflowError", "int too big to convert");
    }
    std::string out((size_t)length, '\0');
    for (size_t k = 0; k < (size_t)length; k++) {
        uint32_t w = k / 4 < x.mag.size() ? x.mag[k / 4] : 0;
        out[little ? k : (size_t)length - 1 - k] = (char)((w >> (8 * (k % 4))) & 0xFF);
    }
    return out;
}

// ── int / float methods ─────────────────────────────────────────────────
inline int64_t big_bit_length(const BigInt& v) {
    if (v.mag.empty()) return 0;
    uint32_t top = v.mag.back();
    int64_t bits = (int64_t)(v.mag.size() - 1) * 32;
    while (top) { bits++; top >>= 1; }
    return bits;
}
inline int64_t big_bit_count(const BigInt& v) {
    int64_t c = 0;
    for (uint32_t w : v.mag) { while (w) { c += w & 1; w >>= 1; } }
    return c;
}
// float.hex(): Python's form, 0x1.8000000000000p+1 (13 hex digits).
inline std::string float_hex(double d) {
    if (std::isnan(d)) return "nan";
    if (std::isinf(d)) return d < 0 ? "-inf" : "inf";
    std::string r = std::signbit(d) ? "-" : "";
    if (d == 0) return r + "0x0.0p+0";
    uint64_t bits; std::memcpy(&bits, &d, 8);
    int exp = (int)((bits >> 52) & 0x7FF);
    uint64_t mant = bits & ((1ULL << 52) - 1);
    int lead = 1;
    if (exp == 0) { lead = 0; exp = -1022; } else exp -= 1023;
    char buf[64];
    std::snprintf(buf, sizeof buf, "0x%d.%013llxp%+d", lead, (unsigned long long)mant, exp);
    return r + buf;
}
// float.as_integer_ratio(): the exact fraction, as (numerator, denominator).
inline void float_ratio(double d, BigInt& num, BigInt& den) {
    if (std::isinf(d)) raise("OverflowError", "cannot convert Infinity to integer ratio");
    if (std::isnan(d)) raise("ValueError", "cannot convert NaN to integer ratio");
    int e;
    double m = std::frexp(d, &e);         // d = m * 2**e, 0.5 <= |m| < 1
    for (int k = 0; k < 300 && m != std::floor(m); k++) { m *= 2; e--; }
    num = BigInt::from_double(m);
    den = BigInt(1);
    if (e > 0) num = num * pow2_big((size_t)e);
    else if (e < 0) den = pow2_big((size_t)-e);
}

// ── the engine-neutral method call ──────────────────────────────────────
// An argument as the engines hand it over. SEQ: an iterable's items, each
// converted the same way (bytes(list), join, extend).
struct BArg {
    enum K { NONE, INT, BOOL, BYTES, STR, SEQ, OTHER } k = NONE;
    int64_t i = 0;
    std::string s;
    std::vector<BArg> items;
    std::string tname;          // the value's type name, for messages
};
struct BRes {
    enum K { NONE, INT, BOOL, STR, BYTES, LIST, TUPLE } k = NONE;
    int64_t i = 0;
    bool b = false;
    bool ba = false;            // BYTES/LIST/TUPLE items are bytearrays
    std::string s;
    std::vector<std::string> v;
};
inline BRes bres_bytes(std::string s, bool ba) { BRes r; r.k = BRes::BYTES; r.s = std::move(s); r.ba = ba; return r; }
inline BRes bres_int(int64_t i) { BRes r; r.k = BRes::INT; r.i = i; return r; }
inline BRes bres_bool(bool b) { BRes r; r.k = BRes::BOOL; r.b = b; return r; }
inline BRes bres_str(std::string s) { BRes r; r.k = BRes::STR; r.s = std::move(s); return r; }
inline BRes bres_list(std::vector<std::string> v, bool ba, bool tuple = false) {
    BRes r; r.k = tuple ? BRes::TUPLE : BRes::LIST; r.v = std::move(v); r.ba = ba; return r;
}

// A byte value from an int argument (0..255).
inline unsigned char byte_of(const BArg& a) {
    if (a.k != BArg::INT && a.k != BArg::BOOL) raise("TypeError", "'" + a.tname + "' object cannot be interpreted as an integer");
    if (a.i < 0 || a.i > 255) raise("ValueError", "byte must be in range(0, 256)");
    return (unsigned char)a.i;
}
// The bytes a bytes-like argument holds.
inline const std::string& bytes_like(const BArg& a, const std::string& what) {
    if (a.k != BArg::BYTES) raise("TypeError", what + ", not '" + a.tname + "'");
    return a.s;
}

// bytes(x) / bytearray(x): from an int (that many zero bytes), a
// bytes-like, an iterable of ints, or a str with an encoding.
inline std::string bytes_construct(const std::vector<BArg>& a, const std::string& encoding, const std::string& errors,
                                   bool has_encoding, const char* type) {
    if (a.empty()) {
        if (has_encoding) raise("TypeError", "encoding without a string argument");
        return std::string();
    }
    const BArg& x = a[0];
    if (x.k == BArg::STR) {
        if (!has_encoding) raise("TypeError", "string argument without an encoding");
        return str_encode(x.s, encoding, errors);
    }
    if (has_encoding) raise("TypeError", "encoding without a string argument");
    if (x.k == BArg::INT || x.k == BArg::BOOL) {
        if (x.i < 0) raise("ValueError", "negative count");
        if (x.i > (int64_t)1 << 32) raise("MemoryError", "");
        return std::string((size_t)x.i, '\0');
    }
    if (x.k == BArg::BYTES) return x.s;
    if (x.k == BArg::SEQ) {
        std::string out;
        out.reserve(x.items.size());
        for (auto& it : x.items) {
            if (it.k != BArg::INT && it.k != BArg::BOOL) raise("TypeError", "'" + it.tname + "' object cannot be interpreted as an integer");
            out += (char)byte_of(it);
        }
        return out;
    }
    if (x.k == BArg::NONE) raise("TypeError", std::string("cannot convert 'NoneType' object to ") + type);
    raise("TypeError", std::string("cannot convert '") + x.tname + "' object to " + type);
}

inline bool byte_space(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }
inline bool byte_lower(unsigned char c) { return c >= 'a' && c <= 'z'; }
inline bool byte_upper(unsigned char c) { return c >= 'A' && c <= 'Z'; }
inline bool byte_alpha(unsigned char c) { return byte_lower(c) || byte_upper(c); }
inline bool byte_digit(unsigned char c) { return c >= '0' && c <= '9'; }

inline std::vector<std::string> bytes_split_ws(const std::string& s, int64_t maxsplit, bool right) {
    std::vector<std::string> out;
    if (!right) {
        size_t i = 0, n = s.size();
        while (true) {
            while (i < n && byte_space((unsigned char)s[i])) i++;
            if (i >= n) break;
            if (maxsplit >= 0 && (int64_t)out.size() == maxsplit) {
                size_t e = n;
                while (e > i && byte_space((unsigned char)s[e - 1])) e--;
                out.push_back(s.substr(i, e - i));
                break;
            }
            size_t j = i;
            while (j < n && !byte_space((unsigned char)s[j])) j++;
            out.push_back(s.substr(i, j - i));
            i = j;
        }
        return out;
    }
    int64_t i = (int64_t)s.size();
    while (true) {
        while (i > 0 && byte_space((unsigned char)s[(size_t)i - 1])) i--;
        if (i <= 0) break;
        if (maxsplit >= 0 && (int64_t)out.size() == maxsplit) {
            size_t b = 0;
            while ((int64_t)b < i && byte_space((unsigned char)s[b])) b++;
            out.push_back(s.substr(b, (size_t)i - b));
            break;
        }
        int64_t j = i;
        while (j > 0 && !byte_space((unsigned char)s[(size_t)j - 1])) j--;
        out.push_back(s.substr((size_t)j, (size_t)(i - j)));
        i = j;
    }
    std::reverse(out.begin(), out.end());
    return out;
}
inline std::vector<std::string> bytes_split_sep(const std::string& s, const std::string& sep, int64_t maxsplit, bool right) {
    if (sep.empty()) raise("ValueError", "empty separator");
    std::vector<std::string> out;
    if (!right) {
        size_t pos = 0;
        while (maxsplit < 0 || (int64_t)out.size() < maxsplit) {
            size_t f = s.find(sep, pos);
            if (f == std::string::npos) break;
            out.push_back(s.substr(pos, f - pos));
            pos = f + sep.size();
        }
        out.push_back(s.substr(pos));
        return out;
    }
    size_t end = s.size();
    int64_t made = 0;
    std::vector<std::string> rev;
    while (maxsplit < 0 || made < maxsplit) {
        if (end < sep.size()) break;
        size_t f = s.rfind(sep, end - sep.size());
        if (f == std::string::npos) break;
        rev.push_back(s.substr(f + sep.size(), end - f - sep.size()));
        end = f;
        made++;
    }
    rev.push_back(s.substr(0, end));
    std::reverse(rev.begin(), rev.end());
    return rev;
}

// bytes / bytearray methods. `data` is the receiver's bytes; a bytearray
// (mut) method may change it. Returns false when `m` is not a method.
inline bool bytes_method(std::string& data, bool mut, const std::string& m, const std::vector<BArg>& a, BRes& out) {
    const size_t n = a.size();
    const std::string& s = data;
    const char* tn = mut ? "bytearray" : "bytes";
    auto M = [&m](const auto& lit) { return m.size() == sizeof(lit) - 1 && std::memcmp(m.data(), lit, sizeof(lit) - 1) == 0; };
    auto need = [&](size_t lo, size_t hi) {
        if (n < lo || n > hi) {
            if (lo == hi) raise("TypeError", m + "() takes exactly " + std::to_string(lo) + " argument" + (lo == 1 ? "" : "s") + " (" + std::to_string(n) + " given)");
            raise("TypeError", m + "() takes at most " + std::to_string(hi) + " arguments (" + std::to_string(n) + " given)");
        }
    };
    auto int_at = [&](size_t i) -> int64_t {
        if (i >= n || (a[i].k != BArg::INT && a[i].k != BArg::BOOL))
            raise("TypeError", "'" + (i < n ? a[i].tname : std::string("NoneType")) + "' object cannot be interpreted as an integer");
        return a[i].i;
    };
    auto bl_at = [&](size_t i) -> const std::string& {
        if (i >= n) raise("TypeError", m + "() missing required argument");
        return bytes_like(a[i], "a bytes-like object is required");
    };
    // a sub-sequence argument: bytes-like, or an int for one byte
    std::string one;
    auto sub_at = [&](size_t i) -> const std::string& {
        if (i < n && (a[i].k == BArg::INT || a[i].k == BArg::BOOL)) { one.assign(1, (char)byte_of(a[i])); return one; }
        if (i >= n) raise("TypeError", m + "() takes at least 1 argument (0 given)");
        return bytes_like(a[i], "argument should be integer or bytes-like object");
    };
    auto opt_int = [&](size_t i, bool& has, int64_t& v) {
        has = false;
        if (i < n && a[i].k != BArg::NONE) {
            if (a[i].k != BArg::INT && a[i].k != BArg::BOOL) raise("TypeError", "slice indices must be integers or None or have an __index__ method");
            has = true; v = a[i].i;
        }
    };
    auto res = [&](std::string x) { out = bres_bytes(std::move(x), mut); return true; };
    auto map_bytes = [&](auto f) { std::string r = s; for (auto& c : r) c = (char)f((unsigned char)c); return r; };
    auto all_of = [&](auto f) {
        if (s.empty()) return false;
        for (unsigned char c : s) if (!f(c)) return false;
        return true;
    };
    // the [start, end) byte range of the optional bound arguments at i, i+1
    auto bounds = [&](size_t i, size_t& b0, size_t& b1) {
        bool hs, he; int64_t st = 0, en = 0;
        opt_int(i, hs, st); opt_int(i + 1, he, en);
        Bounds bd = adjust_bounds((int64_t)s.size(), hs, st, he, en);
        b0 = (size_t)bd.start; b1 = (size_t)bd.end;
    };

    // ── conversions
    if (M("decode")) {
        need(0, 2);
        std::string enc = "utf-8", err = "strict";
        if (n >= 1 && a[0].k != BArg::NONE) { if (a[0].k != BArg::STR) raise("TypeError", "decode() argument 'encoding' must be str, not " + a[0].tname); enc = a[0].s; }
        if (n >= 2 && a[1].k != BArg::NONE) { if (a[1].k != BArg::STR) raise("TypeError", "decode() argument 'errors' must be str, not " + a[1].tname); err = a[1].s; }
        out = bres_str(bytes_decode(s, enc, err));
        return true;
    }
    if (M("hex")) {
        need(0, 2);
        std::string sep;
        if (n >= 1 && a[0].k != BArg::NONE) {
            if (a[0].k == BArg::STR || a[0].k == BArg::BYTES) sep = a[0].s;
            else raise("TypeError", "sep must be str or bytes.");
        }
        int64_t per = n >= 2 ? int_at(1) : 1;
        out = bres_str(bytes_hex(s, sep, per));
        return true;
    }
    if (M("copy") && mut) { need(0, 0); return res(s); }
    // ── case / predicates (ASCII only, as Python's bytes)
    if (M("upper")) { need(0, 0); return res(map_bytes([](unsigned char c) { return byte_lower(c) ? c - 32 : c; })); }
    if (M("lower")) { need(0, 0); return res(map_bytes([](unsigned char c) { return byte_upper(c) ? c + 32 : c; })); }
    if (M("swapcase")) { need(0, 0); return res(map_bytes([](unsigned char c) { return byte_lower(c) ? c - 32 : byte_upper(c) ? c + 32 : c; })); }
    if (M("capitalize")) {
        need(0, 0);
        std::string r = s;
        for (size_t i = 0; i < r.size(); i++) {
            unsigned char c = (unsigned char)r[i];
            if (i == 0) { if (byte_lower(c)) r[i] = (char)(c - 32); }
            else if (byte_upper(c)) r[i] = (char)(c + 32);
        }
        return res(r);
    }
    if (M("title")) {
        need(0, 0);
        std::string r = s;
        bool prev_cased = false;
        for (auto& ch : r) {
            unsigned char c = (unsigned char)ch;
            if (byte_alpha(c)) {
                if (prev_cased) { if (byte_upper(c)) ch = (char)(c + 32); }
                else if (byte_lower(c)) ch = (char)(c - 32);
                prev_cased = true;
            } else prev_cased = false;
        }
        return res(r);
    }
    if (M("isdigit")) { need(0, 0); out = bres_bool(all_of(byte_digit)); return true; }
    if (M("isalpha")) { need(0, 0); out = bres_bool(all_of(byte_alpha)); return true; }
    if (M("isalnum")) { need(0, 0); out = bres_bool(all_of([](unsigned char c) { return byte_alpha(c) || byte_digit(c); })); return true; }
    if (M("isspace")) { need(0, 0); out = bres_bool(all_of(byte_space)); return true; }
    if (M("isascii")) { need(0, 0); out = bres_bool(is_ascii(s)); return true; }
    if (M("isupper") || M("islower")) {
        need(0, 0);
        bool up = M("isupper"), cased = false, ok = true;
        for (unsigned char c : s) {
            if (byte_upper(c)) { cased = true; if (!up) ok = false; }
            else if (byte_lower(c)) { cased = true; if (up) ok = false; }
        }
        out = bres_bool(ok && cased);
        return true;
    }
    if (M("istitle")) {
        need(0, 0);
        bool prev = false, cased = false, ok = true;
        for (unsigned char c : s) {
            if (byte_upper(c)) { if (prev) ok = false; prev = true; cased = true; }
            else if (byte_lower(c)) { if (!prev) ok = false; prev = true; cased = true; }
            else prev = false;
        }
        out = bres_bool(ok && cased);
        return true;
    }
    // ── searching
    if (M("find") || M("rfind") || M("index") || M("rindex") || M("count")) {
        need(1, 3);
        const std::string& sub = sub_at(0);
        size_t b0, b1; bounds(1, b0, b1);
        if (M("count")) {
            int64_t c = 0;
            if (b0 <= b1) {
                if (sub.empty()) c = (int64_t)(b1 - b0) + 1;
                else for (size_t p = b0; p + sub.size() <= b1;) {
                    size_t f = s.find(sub, p);
                    if (f == std::string::npos || f + sub.size() > b1) break;
                    c++; p = f + sub.size();
                }
            }
            out = bres_int(c);
            return true;
        }
        bool rev = M("rfind") || M("rindex");
        int64_t r = -1;
        if (b0 <= b1 && sub.size() <= b1 - b0) {
            if (!rev) { size_t f = s.find(sub, b0); if (f != std::string::npos && f + sub.size() <= b1) r = (int64_t)f; }
            else { size_t f = s.rfind(sub, b1 - sub.size()); if (f != std::string::npos && f >= b0) r = (int64_t)f; }
        }
        if (r < 0 && (M("index") || M("rindex"))) raise("ValueError", "subsection not found");
        out = bres_int(r);
        return true;
    }
    if (M("startswith") || M("endswith")) {
        need(1, 3);
        std::vector<std::string> cands;
        if (a[0].k == BArg::SEQ) {
            for (auto& it : a[0].items) cands.push_back(bytes_like(it, "a bytes-like object is required"));
        } else if (a[0].k == BArg::BYTES) cands.push_back(a[0].s);
        else raise("TypeError", m + " first arg must be bytes or a tuple of bytes, not " + a[0].tname);
        size_t b0, b1; bounds(1, b0, b1);
        bool hit = false;
        for (auto& p : cands) {
            if (b0 > b1 || p.size() > b1 - b0) continue;
            if (M("startswith") ? s.compare(b0, p.size(), p) == 0 : s.compare(b1 - p.size(), p.size(), p) == 0) { hit = true; break; }
        }
        out = bres_bool(hit);
        return true;
    }
    // ── splitting and joining
    if (M("split") || M("rsplit")) {
        need(0, 2);
        int64_t maxs = -1;
        if (n >= 2) maxs = int_at(1);
        bool right = M("rsplit");
        if (n == 0 || a[0].k == BArg::NONE) { out = bres_list(bytes_split_ws(s, maxs, right), mut); return true; }
        out = bres_list(bytes_split_sep(s, bl_at(0), maxs, right), mut);
        return true;
    }
    if (M("splitlines")) {
        need(0, 1);
        bool keep = n >= 1 && a[0].k != BArg::NONE && a[0].i != 0;
        std::vector<std::string> r;
        size_t i = 0, st = 0, len = s.size();
        while (i < len) {
            char c = s[i];
            if (c == '\n' || c == '\r') {
                size_t e = i;
                i += (c == '\r' && i + 1 < len && s[i + 1] == '\n') ? 2 : 1;
                r.push_back(s.substr(st, (keep ? i : e) - st));
                st = i;
            } else i++;
        }
        if (st < len) r.push_back(s.substr(st));
        out = bres_list(r, mut);
        return true;
    }
    if (M("join")) {
        need(1, 1);
        if (a[0].k != BArg::SEQ && a[0].k != BArg::BYTES) raise("TypeError", "can only join an iterable");
        std::string r;
        std::vector<BArg> items;
        if (a[0].k == BArg::BYTES) { for (unsigned char c : a[0].s) { BArg b; b.k = BArg::INT; b.i = c; b.tname = "int"; items.push_back(b); } }
        const std::vector<BArg>& L = a[0].k == BArg::SEQ ? a[0].items : items;
        for (size_t k = 0; k < L.size(); k++) {
            if (L[k].k != BArg::BYTES)
                raise("TypeError", "sequence item " + std::to_string(k) + ": expected a bytes-like object, " + L[k].tname + " found");
            if (k) r += s;
            r += L[k].s;
        }
        return res(r);
    }
    if (M("partition") || M("rpartition")) {
        need(1, 1);
        const std::string& sep = bl_at(0);
        if (sep.empty()) raise("ValueError", "empty separator");
        size_t f = M("partition") ? s.find(sep) : s.rfind(sep);
        if (f == std::string::npos) {
            out = M("partition") ? bres_list({s, "", ""}, mut, true) : bres_list({"", "", s}, mut, true);
        } else {
            out = bres_list({s.substr(0, f), sep, s.substr(f + sep.size())}, mut, true);
        }
        return true;
    }
    // ── trimming and padding
    if (M("strip") || M("lstrip") || M("rstrip")) {
        need(0, 1);
        bool custom = n >= 1 && a[0].k != BArg::NONE;
        std::string chars = custom ? bl_at(0) : std::string(" \t\n\r\v\f");
        auto in_set = [&](unsigned char c) { return chars.find((char)c) != std::string::npos; };
        size_t b = 0, e = s.size();
        if (!M("rstrip")) while (b < e && in_set((unsigned char)s[b])) b++;
        if (!M("lstrip")) while (e > b && in_set((unsigned char)s[e - 1])) e--;
        return res(s.substr(b, e - b));
    }
    if (M("removeprefix")) { need(1, 1); const std::string& p = bl_at(0); return res(s.compare(0, p.size(), p) == 0 && s.size() >= p.size() ? s.substr(p.size()) : s); }
    if (M("removesuffix")) { need(1, 1); const std::string& p = bl_at(0); return res(!p.empty() && s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0 ? s.substr(0, s.size() - p.size()) : s); }
    if (M("center") || M("ljust") || M("rjust")) {
        need(1, 2);
        int64_t w = int_at(0);
        char f = ' ';
        if (n >= 2) {
            const std::string& fb = bl_at(1);
            if (fb.size() != 1) raise("TypeError", m + "() argument 2 must be a byte string of length 1, not " + a[1].tname);
            f = fb[0];
        }
        int64_t len = (int64_t)s.size();
        if (w <= len) return res(s);
        int64_t pad = w - len, left;
        if (M("ljust")) left = 0;
        else if (M("rjust")) left = pad;
        else left = pad / 2 + (pad & w & 1);
        return res(std::string((size_t)left, f) + s + std::string((size_t)(pad - left), f));
    }
    if (M("zfill")) {
        need(1, 1);
        int64_t w = int_at(0), len = (int64_t)s.size();
        if (w <= len) return res(s);
        std::string r = s;
        size_t at = (!r.empty() && (r[0] == '+' || r[0] == '-')) ? 1 : 0;
        r.insert(at, (size_t)(w - len), '0');
        return res(r);
    }
    if (M("expandtabs")) {
        need(0, 1);
        int64_t ts = n ? int_at(0) : 8;
        std::string r; int64_t col = 0;
        for (char c : s) {
            if (c == '\t') { if (ts > 0) { int64_t sp = ts - col % ts; r.append((size_t)sp, ' '); col += sp; } }
            else { r += c; col = (c == '\n' || c == '\r') ? 0 : col + 1; }
        }
        return res(r);
    }
    if (M("replace")) {
        need(2, 3);
        const std::string& from = bl_at(0);
        const std::string& to = bl_at(1);
        int64_t cnt = n >= 3 ? int_at(2) : -1;
        std::string r;
        if (from.empty()) {
            int64_t done = 0;
            for (size_t i = 0; i <= s.size(); i++) {
                if (cnt < 0 || done < cnt) { r += to; done++; }
                if (i < s.size()) r += s[i];
            }
            return res(r);
        }
        size_t pos = 0; int64_t done = 0;
        while (cnt < 0 || done < cnt) {
            size_t f = s.find(from, pos);
            if (f == std::string::npos) break;
            r.append(s, pos, f - pos); r += to; pos = f + from.size(); done++;
        }
        r.append(s, pos, std::string::npos);
        return res(r);
    }
    if (M("translate")) {
        need(1, 2);
        std::string del = n >= 2 ? bl_at(1) : std::string();
        bool has_table = a[0].k != BArg::NONE;
        std::string table;
        if (has_table) {
            table = bl_at(0);
            if (table.size() != 256) raise("ValueError", "translation table must be 256 characters long");
        }
        std::string r;
        for (unsigned char c : s) {
            if (del.find((char)c) != std::string::npos) continue;
            r += has_table ? table[c] : (char)c;
        }
        return res(r);
    }
    // ── bytearray mutation
    if (mut) {
        if (M("append")) { need(1, 1); data += (char)byte_of(a[0]); out = BRes(); return true; }
        if (M("extend")) {
            need(1, 1);
            if (a[0].k == BArg::BYTES) data += a[0].s;
            else if (a[0].k == BArg::SEQ) {
                std::string add;
                for (auto& it : a[0].items) add += (char)byte_of(it);
                data += add;
            } else if (a[0].k == BArg::STR) raise("TypeError", "expected iterable of integers; got: 'str'");
            else raise("TypeError", "can't extend bytearray with " + a[0].tname);
            out = BRes(); return true;
        }
        if (M("insert")) {
            need(2, 2);
            int64_t i = int_at(0), len = (int64_t)data.size();
            unsigned char c = byte_of(a[1]);
            if (i < 0) { i += len; if (i < 0) i = 0; }
            if (i > len) i = len;
            data.insert(data.begin() + i, (char)c);
            out = BRes(); return true;
        }
        if (M("pop")) {
            need(0, 1);
            if (data.empty()) raise("IndexError", "pop from empty bytearray");
            int64_t i = n ? int_at(0) : -1, len = (int64_t)data.size();
            if (i < 0) i += len;
            if (i < 0 || i >= len) raise("IndexError", "pop index out of range");
            unsigned char c = (unsigned char)data[(size_t)i];
            data.erase((size_t)i, 1);
            out = bres_int(c); return true;
        }
        if (M("remove")) {
            need(1, 1);
            unsigned char c = byte_of(a[0]);
            size_t f = data.find((char)c);
            if (f == std::string::npos) raise("ValueError", "value not found in bytearray");
            data.erase(f, 1);
            out = BRes(); return true;
        }
        if (M("clear")) { need(0, 0); data.clear(); out = BRes(); return true; }
        if (M("reverse")) { need(0, 0); std::reverse(data.begin(), data.end()); out = BRes(); return true; }
    }
    (void)tn;
    return false;
}

// The engines' operators, in one place: `x in b` (an int or a bytes-like).
inline bool bytes_contains(const std::string& s, const BArg& x) {
    if (x.k == BArg::INT || x.k == BArg::BOOL) return s.find((char)byte_of(x)) != std::string::npos;
    if (x.k == BArg::BYTES) return s.find(x.s) != std::string::npos;
    raise("TypeError", "a bytes-like object is required, not '" + x.tname + "'");
}

// Three-way comparison of two byte strings (lexicographic by unsigned byte).
inline int bytes_compare(const std::string& a, const std::string& b) {
    int c = a.compare(b);   // std::string compares char_traits<char>: memcmp, unsigned
    return c < 0 ? -1 : c > 0 ? 1 : 0;
}

// bytes % args is not supported; the engines raise this.
inline const char* bytes_methods_list() {
    return "capitalize center count decode endswith expandtabs find hex index isalnum isalpha isascii isdigit "
           "islower isspace istitle isupper join ljust lower lstrip partition removeprefix removesuffix replace "
           "rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title "
           "translate upper zfill";
}

} // namespace nypy
