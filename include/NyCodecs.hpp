#pragma once
// NyCodecs.hpp - the text codecs of both engines (round 80): one table
// behind str.encode, bytes.decode, str(b, encoding, errors) and lib/codecs.ny
// (through the _ny_codec native, src/builtins/nycodecs.cpp).
//
// Codecs: utf-8, utf-8-sig, utf-16 / -le / -be, utf-32 / -le / -be, latin-1,
// ascii, cp437, cp850, cp1252, mac-roman, unicode_escape, raw_unicode_escape
// - with CPython's names and aliases (encodings.aliases), its error ranges,
// reasons and messages ("'charmap' codec can't encode characters in
// position 1-2: character maps to <undefined>"), and every builtin error
// handler on both directions: strict, ignore, replace, backslashreplace,
// xmlcharrefreplace and namereplace (encoding only, as CPython), surrogate-
// escape (PEP 383) and surrogatepass. A str is UTF-8 inside; a lone
// surrogate (U+D800..U+DFFF, which surrogateescape and surrogatepass make)
// is kept as its three-byte generalized UTF-8 form, which len, indexing and
// these encoders read as one character.
//
// The "stop" handler (errors "__ny_stop__") is lib/codecs.ny's: the codec
// stops at the first error and reports it (CxErr), so a handler registered
// with codecs.register_error runs in Nython and the codec resumes where it
// says. `final` false (incremental decoders) leaves an incomplete sequence
// at the end unconsumed.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include "NyStr.hpp"
#include "NyBigInt.hpp"
#include "NyUniNames.hpp"

namespace nypy {

enum class Cx : int { UTF8, UTF8SIG, UTF16, UTF16LE, UTF16BE, UTF32, UTF32LE, UTF32BE, LATIN1, ASCII,
                      CP437, CP850, CP1252, MACROMAN, UNIESC, RAWUNIESC };

// encodings.normalize_encoding + lower case: runs of characters other than
// letters, digits and '.' become one '_'
inline std::string codec_normalize(const std::string& e) {
    std::string n;
    bool pend = false;
    for (char ch : e) {
        unsigned char c = (unsigned char)ch;
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c >= 0x80) {
            if (pend && !n.empty()) n += '_';
            pend = false;
            n += (char)c;
        } else if (c >= 'A' && c <= 'Z') {
            if (pend && !n.empty()) n += '_';
            pend = false;
            n += (char)(c + 32);
        } else pend = true;
    }
    return n;
}

// The native codec an encoding name stands for; false when there is none.
inline bool codec_find(const std::string& encoding, Cx& out) {
    // the names every program uses, before normalizing
    if (encoding == "utf-8" || encoding == "utf8" || encoding == "UTF-8") { out = Cx::UTF8; return true; }
    std::string n = codec_normalize(encoding);
    struct A { const char* n; Cx c; };
    static const A t[] = {
        {"utf_8", Cx::UTF8}, {"u8", Cx::UTF8}, {"utf", Cx::UTF8}, {"utf8", Cx::UTF8}, {"utf8_ucs2", Cx::UTF8},
        {"utf8_ucs4", Cx::UTF8}, {"cp65001", Cx::UTF8},
        {"utf_8_sig", Cx::UTF8SIG},
        {"utf_16", Cx::UTF16}, {"u16", Cx::UTF16}, {"utf16", Cx::UTF16},
        {"utf_16_le", Cx::UTF16LE}, {"utf_16le", Cx::UTF16LE}, {"unicodelittleunmarked", Cx::UTF16LE},
        {"utf_16_be", Cx::UTF16BE}, {"utf_16be", Cx::UTF16BE}, {"unicodebigunmarked", Cx::UTF16BE},
        {"utf_32", Cx::UTF32}, {"u32", Cx::UTF32}, {"utf32", Cx::UTF32},
        {"utf_32_le", Cx::UTF32LE}, {"utf_32le", Cx::UTF32LE},
        {"utf_32_be", Cx::UTF32BE}, {"utf_32be", Cx::UTF32BE},
        {"latin_1", Cx::LATIN1}, {"8859", Cx::LATIN1}, {"cp819", Cx::LATIN1}, {"csisolatin1", Cx::LATIN1},
        {"ibm819", Cx::LATIN1}, {"iso8859", Cx::LATIN1}, {"iso8859_1", Cx::LATIN1}, {"iso_8859_1", Cx::LATIN1},
        {"iso_8859_1_1987", Cx::LATIN1}, {"iso_ir_100", Cx::LATIN1}, {"l1", Cx::LATIN1}, {"latin", Cx::LATIN1},
        {"latin1", Cx::LATIN1},
        {"ascii", Cx::ASCII}, {"646", Cx::ASCII}, {"ansi_x3.4_1968", Cx::ASCII}, {"ansi_x3.4_1986", Cx::ASCII},
        {"ansi_x3_4_1968", Cx::ASCII}, {"cp367", Cx::ASCII}, {"csascii", Cx::ASCII}, {"ibm367", Cx::ASCII},
        {"iso646_us", Cx::ASCII}, {"iso_646.irv_1991", Cx::ASCII}, {"iso_ir_6", Cx::ASCII}, {"us", Cx::ASCII},
        {"us_ascii", Cx::ASCII},
        {"cp437", Cx::CP437}, {"437", Cx::CP437}, {"cspc8codepage437", Cx::CP437}, {"ibm437", Cx::CP437},
        {"cp850", Cx::CP850}, {"850", Cx::CP850}, {"cspc850multilingual", Cx::CP850}, {"ibm850", Cx::CP850},
        {"cp1252", Cx::CP1252}, {"1252", Cx::CP1252}, {"windows_1252", Cx::CP1252},
        {"mac_roman", Cx::MACROMAN}, {"macintosh", Cx::MACROMAN}, {"macroman", Cx::MACROMAN},
        {"unicode_escape", Cx::UNIESC}, {"raw_unicode_escape", Cx::RAWUNIESC},
    };
    for (auto& a : t) if (n == a.n) { out = a.c; return true; }
    return false;
}

// CodecInfo.name
inline const char* cx_name(Cx c) {
    switch (c) {
        case Cx::UTF8: return "utf-8";
        case Cx::UTF8SIG: return "utf-8-sig";
        case Cx::UTF16: return "utf-16";
        case Cx::UTF16LE: return "utf-16-le";
        case Cx::UTF16BE: return "utf-16-be";
        case Cx::UTF32: return "utf-32";
        case Cx::UTF32LE: return "utf-32-le";
        case Cx::UTF32BE: return "utf-32-be";
        case Cx::LATIN1: return "iso8859-1";
        case Cx::ASCII: return "ascii";
        case Cx::CP437: return "cp437";
        case Cx::CP850: return "cp850";
        case Cx::CP1252: return "cp1252";
        case Cx::MACROMAN: return "mac-roman";
        case Cx::UNIESC: return "unicode-escape";
        default: return "raw-unicode-escape";
    }
}

// The codec's name in an encoding error ("'charmap' codec can't encode ...")
inline const char* cx_encname(Cx c) {
    switch (c) {
        case Cx::UTF8: case Cx::UTF8SIG: return "utf-8";
        case Cx::LATIN1: return "latin-1";
        case Cx::CP437: case Cx::CP850: case Cx::CP1252: case Cx::MACROMAN: return "charmap";
        case Cx::UNIESC: return "unicodeescape";
        case Cx::RAWUNIESC: return "rawunicodeescape";
        default: return cx_name(c);
    }
}

// (not STRICT/IGNORE/...: windows.h defines those as macros)
enum class EH { Strict, Ignore, Replace, Backslash, XmlRef, NameRep, SurrEsc, SurrPass, Stop };
inline bool eh_find(const std::string& e, EH& out) {
    if (e.empty() || e == "strict") { out = EH::Strict; return true; }
    if (e == "ignore") { out = EH::Ignore; return true; }
    if (e == "replace") { out = EH::Replace; return true; }
    if (e == "backslashreplace") { out = EH::Backslash; return true; }
    if (e == "xmlcharrefreplace") { out = EH::XmlRef; return true; }
    if (e == "namereplace") { out = EH::NameRep; return true; }
    if (e == "surrogateescape") { out = EH::SurrEsc; return true; }
    if (e == "surrogatepass") { out = EH::SurrPass; return true; }
    if (e == "__ny_stop__") { out = EH::Stop; return true; }
    return false;
}
// Whether encoding/errors need lib/codecs.ny (a codec or an error handler
// registered there): the engines then call the prelude's _ny_codec_encode /
// _ny_codec_decode instead.
inline bool codec_needs_python(const std::string& encoding, const std::string& errors) {
    Cx c; EH e;
    return !codec_find(encoding, c) || !eh_find(errors, e);
}

// The first error the "stop" handler met.
struct CxErr {
    bool hit = false;
    int64_t start = 0, end = 0;
    std::string reason, codec;   // codec: the name the error reports
};

// The fields of the last UnicodeDecodeError / UnicodeEncodeError a codec
// raised on this thread (round 77): the engines make the exception object
// from the message, and take encoding, object, start, end and reason from
// here when the message is this one (e.object is the whole input).
struct UnicodeErrInfo {
    std::string msg, encoding, object, reason;
    bool is_str = false;            // object is a str (encode) rather than bytes
    int64_t start = 0, end = 0;
};
inline UnicodeErrInfo& last_unicode_error() { static thread_local UnicodeErrInfo e; return e; }

inline std::string cx_hex2(unsigned char c) {
    static const char* hx = "0123456789abcdef";
    std::string r = "0x"; r += hx[c >> 4]; r += hx[c & 15]; return r;
}
inline std::string cx_charrepr(uint32_t cp) {
    char buf[16];
    if (cp <= 0xFF) std::snprintf(buf, sizeof buf, "\\x%02x", cp);
    else if (cp <= 0xFFFF) std::snprintf(buf, sizeof buf, "\\u%04x", cp);
    else std::snprintf(buf, sizeof buf, "\\U%08x", cp);
    return buf;
}
[[noreturn]] inline void cx_raise_decode(const char* name, const std::string& obj, int64_t a, int64_t b, const std::string& why) {
    std::string m = std::string("'") + name + "' codec can't decode ";
    if (b - a == 1) m += "byte " + cx_hex2((unsigned char)obj[(size_t)a]) + " in position " + std::to_string(a);
    else m += "bytes in position " + std::to_string(a) + "-" + std::to_string(b - 1);
    m += ": " + why;
    UnicodeErrInfo& info = last_unicode_error();
    info.msg = m; info.encoding = name; info.object = obj; info.reason = why;
    info.is_str = false; info.start = a; info.end = b;
    raise("UnicodeDecodeError", m);
}
// obj: the str; cps: its code points
[[noreturn]] inline void cx_raise_encode(const char* name, const std::string& obj, const std::vector<uint32_t>& cps,
                                         int64_t a, int64_t b, const std::string& why) {
    std::string m = std::string("'") + name + "' codec can't encode ";
    if (b - a == 1) m += "character '" + cx_charrepr(cps[(size_t)a]) + "' in position " + std::to_string(a);
    else m += "characters in position " + std::to_string(a) + "-" + std::to_string(b - 1);
    m += ": " + why;
    UnicodeErrInfo& info = last_unicode_error();
    info.msg = m; info.encoding = name; info.object = obj; info.reason = why;
    info.is_str = true; info.start = a; info.end = b;
    raise("UnicodeEncodeError", m);
}

// ── single-byte tables (CPython's encodings/cp437.py ...; 0xFFFE: undefined)
inline const uint16_t* cx_table(Cx c) {
#include "NyCodecTables.inc"
    switch (c) {
        case Cx::CP437: return k_CP437;
        case Cx::CP850: return k_CP850;
        case Cx::CP1252: return k_CP1252;
        default: return k_MACROMAN;
    }
}
inline int cx_charmap_encode(Cx c, uint32_t cp) {
    // the byte for cp, -1 when it has none (a reverse table built once)
    static thread_local std::vector<std::pair<uint32_t, unsigned char>> rev[4];
    int k = c == Cx::CP437 ? 0 : c == Cx::CP850 ? 1 : c == Cx::CP1252 ? 2 : 3;
    auto& r = rev[k];
    if (r.empty()) {
        const uint16_t* t = cx_table(c);
        for (int b = 0; b < 256; b++) if (t[b] != 0xFFFE) r.push_back({t[b], (unsigned char)b});
        std::sort(r.begin(), r.end());
    }
    auto it = std::lower_bound(r.begin(), r.end(), std::make_pair(cp, (unsigned char)0));
    if (it != r.end() && it->first == cp) return it->second;
    return -1;
}

inline bool cx_is_utf16(Cx c) { return c == Cx::UTF16 || c == Cx::UTF16LE || c == Cx::UTF16BE; }
inline bool cx_is_utf32(Cx c) { return c == Cx::UTF32 || c == Cx::UTF32LE || c == Cx::UTF32BE; }

// ── decoding ───────────────────────────────────────────────────────────────
struct CxDecoder {
    Cx c;
    EH eh;
    const std::string& s;
    bool final;
    CxErr& err;
    std::string out;
    const char* name;      // the name errors report
    bool le = true;        // UTF-16/32 byte order
    CxDecoder(Cx c_, EH eh_, const std::string& s_, bool final_, CxErr& err_)
        : c(c_), eh(eh_), s(s_), final(final_), err(err_), out(), name(cx_encname(c_)) {}

    // An error over bytes [a, b): false when the codec must stop ("stop"
    // handler); else `next` is where decoding resumes.
    bool bad(size_t a, size_t b, const std::string& why, size_t& next) {
        static const char* hx = "0123456789abcdef";
        switch (eh) {
            case EH::Strict: cx_raise_decode(name, s, (int64_t)a, (int64_t)b, why);
            case EH::Stop:
                err.hit = true; err.start = (int64_t)a; err.end = (int64_t)b; err.reason = why; err.codec = name;
                return false;
            case EH::Ignore: next = b; return true;
            case EH::Replace: out += "\xEF\xBF\xBD"; next = b; return true;
            case EH::Backslash:
                for (size_t k = a; k < b; k++) { unsigned char x = (unsigned char)s[k]; out += "\\x"; out += hx[x >> 4]; out += hx[x & 15]; }
                next = b; return true;
            case EH::SurrEsc: {
                // CPython's PyCodec_SurrogateEscapeErrors: up to 4 bytes,
                // stopping at an ASCII one (none escaped: the error stands)
                size_t k = a;
                while (k < b && k - a < 4 && (unsigned char)s[k] >= 0x80) { u8_encode(0xDC00u + (unsigned char)s[k], out); k++; }
                if (k == a) cx_raise_decode(name, s, (int64_t)a, (int64_t)b, why);
                next = k; return true;
            }
            case EH::SurrPass: {
                // one encoded surrogate at a, in this codec's form
                uint32_t ch = 0;
                size_t w = 0;
                if (c == Cx::UTF8 || c == Cx::UTF8SIG) {
                    if (a + 3 <= s.size() && ((unsigned char)s[a] & 0xF0) == 0xE0 && ((unsigned char)s[a + 1] & 0xC0) == 0x80
                        && ((unsigned char)s[a + 2] & 0xC0) == 0x80) {
                        ch = (((unsigned char)s[a] & 0x0Fu) << 12) | (((unsigned char)s[a + 1] & 0x3Fu) << 6) | ((unsigned char)s[a + 2] & 0x3Fu);
                        w = 3;
                    }
                } else if (cx_is_utf16(c)) {
                    if (a + 2 <= s.size()) { ch = unit16(a); w = 2; }
                } else if (cx_is_utf32(c)) {
                    if (a + 4 <= s.size()) { ch = unit32(a); w = 4; }
                }
                if (w == 0 || ch < 0xD800 || ch > 0xDFFF) cx_raise_decode(name, s, (int64_t)a, (int64_t)b, why);
                u8_encode(ch, out);
                next = a + w;
                return true;
            }
            default:
                raise("TypeError", "don't know how to handle UnicodeDecodeError in error callback");
        }
    }
    uint32_t unit16(size_t k) const {
        unsigned char x = (unsigned char)s[k], y = (unsigned char)s[k + 1];
        return le ? (uint32_t)(x | (y << 8)) : (uint32_t)((x << 8) | y);
    }
    uint32_t unit32(size_t k) const {
        uint32_t u = 0;
        for (int j = 0; j < 4; j++) u |= (uint32_t)(unsigned char)s[k + (size_t)(le ? j : 3 - j)] << (8 * j);
        return u;
    }

    // Decodes from `pos`; returns where it stopped (s.size() when done).
    size_t run(size_t pos) {
        size_t n = s.size(), i = pos;
        switch (c) {
            case Cx::UTF8: case Cx::UTF8SIG: {
                if (c == Cx::UTF8SIG && i == 0 && n >= 3 && s.compare(0, 3, "\xEF\xBB\xBF") == 0) i = 3;
                out.reserve(n - i);
                while (i < n) {
                    unsigned char ch = (unsigned char)s[i];
                    if (ch < 0x80) { out += (char)ch; i++; continue; }
                    const char* why = "";
                    int u = utf8_unit(i, why);
                    if (u > 0) { out.append(s, i, (size_t)u); i += (size_t)u; continue; }
                    size_t b = i + (size_t)(-u);
                    if (!final && b == n && std::string(why) == "unexpected end of data") return i;
                    size_t next = b;
                    if (!bad(i, b, why, next)) return i;
                    i = next;
                }
                return n;
            }
            case Cx::ASCII:
                while (i < n) {
                    unsigned char x = (unsigned char)s[i];
                    if (x < 0x80) { out += (char)x; i++; continue; }
                    size_t next = i + 1;
                    if (!bad(i, i + 1, "ordinal not in range(128)", next)) return i;
                    i = next;
                }
                return n;
            case Cx::LATIN1:
                for (; i < n; i++) u8_encode((unsigned char)s[i], out);
                return n;
            case Cx::CP437: case Cx::CP850: case Cx::CP1252: case Cx::MACROMAN: {
                const uint16_t* t = cx_table(c);
                while (i < n) {
                    uint16_t u = t[(unsigned char)s[i]];
                    if (u != 0xFFFE) { u8_encode(u, out); i++; continue; }
                    size_t next = i + 1;
                    if (!bad(i, i + 1, "character maps to <undefined>", next)) return i;
                    i = next;
                }
                return n;
            }
            case Cx::UTF16: case Cx::UTF16LE: case Cx::UTF16BE: {
                le = c != Cx::UTF16BE;
                if (c == Cx::UTF16 && i == 0 && n >= 2) {
                    if ((unsigned char)s[0] == 0xFF && (unsigned char)s[1] == 0xFE) { le = true; i = 2; }
                    else if ((unsigned char)s[0] == 0xFE && (unsigned char)s[1] == 0xFF) { le = false; i = 2; }
                }
                if (c == Cx::UTF16) name = le ? "utf-16-le" : "utf-16-be";
                while (i < n) {
                    if (n - i < 2) {
                        if (!final) return i;
                        size_t next = n;
                        if (!bad(i, n, "truncated data", next)) return i;
                        i = next;
                        continue;
                    }
                    uint32_t u = unit16(i);
                    if (u < 0xD800 || u > 0xDFFF) { u8_encode(u, out); i += 2; continue; }
                    size_t next;
                    if (u >= 0xDC00) {
                        next = i + 2;
                        if (!bad(i, i + 2, "illegal encoding", next)) return i;
                        i = next;
                        continue;
                    }
                    if (n - i < 4) {
                        if (!final) return i;
                        next = n;
                        if (!bad(i, n, "unexpected end of data", next)) return i;
                        i = next;
                        continue;
                    }
                    uint32_t v = unit16(i + 2);
                    if (v < 0xDC00 || v > 0xDFFF) {
                        next = i + 2;
                        if (!bad(i, i + 2, "illegal UTF-16 surrogate", next)) return i;
                        i = next;
                        continue;
                    }
                    u8_encode(0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00), out);
                    i += 4;
                }
                return n;
            }
            case Cx::UTF32: case Cx::UTF32LE: case Cx::UTF32BE: {
                le = c != Cx::UTF32BE;
                if (c == Cx::UTF32 && i == 0 && n >= 4) {
                    if (s.compare(0, 4, std::string("\xFF\xFE\0\0", 4)) == 0) { le = true; i = 4; }
                    else if (s.compare(0, 4, std::string("\0\0\xFE\xFF", 4)) == 0) { le = false; i = 4; }
                }
                if (c == Cx::UTF32) name = le ? "utf-32-le" : "utf-32-be";
                while (i < n) {
                    size_t next;
                    if (n - i < 4) {
                        if (!final) return i;
                        next = n;
                        if (!bad(i, n, "truncated data", next)) return i;
                        i = next;
                        continue;
                    }
                    uint32_t u = unit32(i);
                    if (u > 0x10FFFF) {
                        next = i + 4;
                        if (!bad(i, i + 4, "code point not in range(0x110000)", next)) return i;
                        i = next;
                        continue;
                    }
                    if (u >= 0xD800 && u <= 0xDFFF) {
                        next = i + 4;
                        if (!bad(i, i + 4, "code point in surrogate code point range(0xd800, 0xe000)", next)) return i;
                        i = next;
                        continue;
                    }
                    u8_encode(u, out);
                    i += 4;
                }
                return n;
            }
            case Cx::UNIESC: return run_unicode_escape(i, false);
            default: return run_unicode_escape(i, true);
        }
    }

    // utf8_unit of NyBytes.hpp: the length of the valid sequence at i, or
    // minus the length of the maximal invalid subpart
    int utf8_unit(size_t i, const char*& why) const {
        size_t n = s.size();
        unsigned char ch = (unsigned char)s[i];
        int need; unsigned char lo = 0x80, hi = 0xBF;
        if (ch >= 0xC2 && ch <= 0xDF) need = 1;
        else if (ch == 0xE0) { need = 2; lo = 0xA0; }
        else if (ch >= 0xE1 && ch <= 0xEC) need = 2;
        else if (ch == 0xED) { need = 2; hi = 0x9F; }
        else if (ch >= 0xEE && ch <= 0xEF) need = 2;
        else if (ch == 0xF0) { need = 3; lo = 0x90; }
        else if (ch >= 0xF1 && ch <= 0xF3) need = 3;
        else if (ch == 0xF4) { need = 3; hi = 0x8F; }
        else { why = "invalid start byte"; return -1; }
        for (int k = 1; k <= need; k++) {
            if (i + (size_t)k >= n) { why = "unexpected end of data"; return -k; }
            unsigned char d = (unsigned char)s[i + (size_t)k];
            unsigned char l = (k == 1) ? lo : 0x80, h = (k == 1) ? hi : 0xBF;
            if (d < l || d > h) { why = "invalid continuation byte"; return -k; }
        }
        return need + 1;
    }

    static int hexval(unsigned char ch) {
        if (ch >= '0' && ch <= '9') return ch - '0';
        if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
        if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
        return -1;
    }
    // CPython's _PyUnicode_DecodeUnicodeEscapeInternal / the raw decoder
    size_t run_unicode_escape(size_t i, bool raw) {
        size_t n = s.size();
        while (i < n) {
            unsigned char ch = (unsigned char)s[i++];
            if (ch != '\\') { u8_encode(ch, out); continue; }
            size_t start = i - 1;
            const char* msg = "\\ at end of string";
            if (i >= n) {
                if (!final) return start;
                if (raw) { out += '\\'; continue; }
                size_t next = i;
                if (!bad(start, i, msg, next)) return start;
                i = next;
                continue;
            }
            ch = (unsigned char)s[i];
            if (raw && ch != 'u' && ch != 'U') { out += '\\'; continue; }
            i++;
            int count = 0;
            bool incomplete = false, error = false;
            uint32_t cp = 0;
            switch (ch) {
                case '\n': continue;
                case '\\': out += '\\'; continue;
                case '\'': out += '\''; continue;
                case '"': out += '"'; continue;
                case 'b': out += '\b'; continue;
                case 'f': out += '\f'; continue;
                case 't': out += '\t'; continue;
                case 'n': out += '\n'; continue;
                case 'r': out += '\r'; continue;
                case 'v': out += '\v'; continue;
                case 'a': out += '\a'; continue;
                case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7':
                    cp = ch - '0';
                    if (i < n && s[i] >= '0' && s[i] <= '7') {
                        cp = (cp << 3) + (uint32_t)(s[i++] - '0');
                        if (i < n && s[i] >= '0' && s[i] <= '7') cp = (cp << 3) + (uint32_t)(s[i++] - '0');
                    }
                    u8_encode(cp, out);
                    continue;
                case 'x': count = 2; msg = "truncated \\xXX escape"; break;
                case 'u': count = 4; msg = "truncated \\uXXXX escape"; break;
                case 'U': count = 8; msg = "truncated \\UXXXXXXXX escape"; break;
                case 'N': {
                    msg = "malformed \\N character escape";
                    if (i >= n) { incomplete = true; break; }
                    if (s[i] == '{') {
                        size_t nm = ++i;
                        while (i < n && s[i] != '}') i++;
                        if (i >= n) { incomplete = true; break; }
                        if (i > nm) {
                            std::string nmtext = s.substr(nm, i - nm);
                            i++;
                            uint32_t got;
                            if (nyuni::lookup(nmtext, got)) { u8_encode(got, out); continue; }
                            msg = "unknown Unicode character name";
                        }
                    }
                    error = true;
                    break;
                }
                default:
                    out += '\\';
                    u8_encode(ch, out);
                    continue;
            }
            if (count) {
                for (; count; ++i, --count) {
                    if (i >= n) { incomplete = true; break; }
                    int h = hexval((unsigned char)s[i]);
                    if (h < 0) { error = true; break; }
                    cp = (cp << 4) + (uint32_t)h;
                }
                if (!incomplete && !error) {
                    if (cp > 0x10FFFF) { msg = raw ? "\\Uxxxxxxxx out of range" : "illegal Unicode character"; error = true; }
                    else { u8_encode(cp, out); continue; }
                }
            }
            if (incomplete && !final) return start;
            size_t next = i;
            if (!bad(start, i, msg, next)) return start;
            i = next;
        }
        return n;
    }
};

// bytes -> str. consumed: where decoding stopped (for "stop" / final=false).
inline std::string codec_decode(Cx c, const std::string& s, EH eh, bool final, size_t start, size_t& consumed, CxErr& err,
                                bool* little = nullptr) {
    if (c == Cx::UTF8SIG && start == 0 && s.size() >= 3 && s.compare(0, 3, "\xEF\xBB\xBF") == 0) {
        // as CPython's utf_8_sig: the rest decoded as utf-8 (an error's
        // position and object are the rest's)
        std::string rest = s.substr(3);
        CxDecoder d(Cx::UTF8, eh, rest, final, err);
        consumed = d.run(0) + 3;
        if (err.hit) { err.start += 3; err.end += 3; }
        return std::move(d.out);
    }
    CxDecoder d(c, eh, s, final, err);
    consumed = d.run(start);
    if (little) *little = d.le;
    return std::move(d.out);
}

// ── encoding ──────────────────────────────────────────────────────────────
// The str's code points: a lone surrogate's generalized UTF-8 form is the
// surrogate; a byte that starts no character (a str read from a binary
// file) counts as U+FFFD.
inline std::vector<uint32_t> cx_codepoints(const std::string& s) {
    std::vector<uint32_t> r;
    r.reserve(s.size());
    for (size_t i = 0; i < s.size();) {
        unsigned char ch = (unsigned char)s[i];
        if (ch < 0x80) { r.push_back(ch); i++; continue; }
        size_t len = u8_seq(ch);
        bool ok = len > 1 && i + len <= s.size();
        for (size_t k = 1; ok && k < len; k++) if (((unsigned char)s[i + k] & 0xC0) != 0x80) ok = false;
        if (!ok) { r.push_back(0xFFFD); i++; continue; }
        size_t j = i;
        r.push_back(u8_decode(s, j));
        i = j;
    }
    return r;
}

struct CxEncoder {
    Cx c;
    EH eh;
    const std::string& s;          // the str (UTF-8)
    std::vector<uint32_t> cps;
    CxErr& err;
    std::string out;
    const char* name;
    bool le = true;
    CxEncoder(Cx c_, EH eh_, const std::string& s_, CxErr& err_)
        : c(c_), eh(eh_), s(s_), cps(cx_codepoints(s_)), err(err_), out(), name(cx_encname(c_)) {
        le = !(c == Cx::UTF16BE || c == Cx::UTF32BE);
    }
    // can cp be written as is?
    bool can(uint32_t cp) const {
        switch (c) {
            case Cx::ASCII: return cp < 0x80;
            case Cx::LATIN1: return cp < 0x100;
            case Cx::CP437: case Cx::CP850: case Cx::CP1252: case Cx::MACROMAN:
                return cx_charmap_encode(c, cp) >= 0;
            case Cx::UNIESC: case Cx::RAWUNIESC: return true;
            default: return cp < 0xD800 || cp > 0xDFFF;
        }
    }
    void put16(uint32_t u) {
        if (le) { out += (char)(u & 0xFF); out += (char)(u >> 8); }
        else { out += (char)(u >> 8); out += (char)(u & 0xFF); }
    }
    void put(uint32_t cp) {
        switch (c) {
            case Cx::ASCII: case Cx::LATIN1: out += (char)cp; return;
            case Cx::CP437: case Cx::CP850: case Cx::CP1252: case Cx::MACROMAN:
                out += (char)cx_charmap_encode(c, cp); return;
            case Cx::UTF8: case Cx::UTF8SIG: u8_encode(cp, out); return;
            case Cx::UTF16: case Cx::UTF16LE: case Cx::UTF16BE:
                if (cp >= 0x10000) { uint32_t v = cp - 0x10000; put16(0xD800 + (v >> 10)); put16(0xDC00 + (v & 0x3FF)); }
                else put16(cp);
                return;
            case Cx::UNIESC: {
                char buf[16];
                if (cp < 0x100) {
                    if (cp >= ' ' && cp < 127) { if (cp == '\\') out += "\\\\"; else out += (char)cp; }
                    else if (cp == '\t') out += "\\t";
                    else if (cp == '\n') out += "\\n";
                    else if (cp == '\r') out += "\\r";
                    else { std::snprintf(buf, sizeof buf, "\\x%02x", cp); out += buf; }
                } else if (cp < 0x10000) { std::snprintf(buf, sizeof buf, "\\u%04x", cp); out += buf; }
                else { std::snprintf(buf, sizeof buf, "\\U%08x", cp); out += buf; }
                return;
            }
            case Cx::RAWUNIESC: {
                char buf[16];
                if (cp < 0x100) out += (char)cp;
                else if (cp < 0x10000) { std::snprintf(buf, sizeof buf, "\\u%04x", cp); out += buf; }
                else { std::snprintf(buf, sizeof buf, "\\U%08x", cp); out += buf; }
                return;
            }
            default:
                for (int k = 0; k < 4; k++) out += (char)((cp >> (8 * (le ? k : 3 - k))) & 0xFF);
                return;
        }
    }
    void put_ascii(const std::string& t) { for (unsigned char ch : t) put(ch); }
    const char* reason() const {
        switch (c) {
            case Cx::ASCII: return "ordinal not in range(128)";
            case Cx::LATIN1: return "ordinal not in range(256)";
            case Cx::CP437: case Cx::CP850: case Cx::CP1252: case Cx::MACROMAN: return "character maps to <undefined>";
            default: return "surrogates not allowed";
        }
    }
    // characters [a, b) cannot be encoded: false to stop
    bool bad(size_t a, size_t b) {
        const char* why = reason();
        switch (eh) {
            case EH::Strict: cx_raise_encode(name, s, cps, (int64_t)a, (int64_t)b, why);
            case EH::Stop:
                err.hit = true; err.start = (int64_t)a; err.end = (int64_t)b; err.reason = why; err.codec = name;
                return false;
            case EH::Ignore: return true;
            case EH::Replace: for (size_t k = a; k < b; k++) put('?'); return true;
            case EH::Backslash: for (size_t k = a; k < b; k++) put_ascii(cx_charrepr(cps[k])); return true;
            case EH::XmlRef: for (size_t k = a; k < b; k++) put_ascii("&#" + std::to_string(cps[k]) + ";"); return true;
            case EH::NameRep:
                for (size_t k = a; k < b; k++) {
                    std::string nm = nyuni::name(cps[k]);
                    put_ascii(nm.empty() ? cx_charrepr(cps[k]) : "\\N{" + nm + "}");
                }
                return true;
            case EH::SurrEsc: {
                if (c == Cx::UTF8 || c == Cx::UTF8SIG || c == Cx::LATIN1 || c == Cx::ASCII) {
                    // these encoders escape what they can and report the rest
                    // (CPython's fast paths in unicode_encode_ucs1/utf8)
                    size_t k = a;
                    for (; k < b && cps[k] >= 0xDC80 && cps[k] <= 0xDCFF; k++) out += (char)(cps[k] - 0xDC00);
                    if (k < b) cx_raise_encode(name, s, cps, (int64_t)k, (int64_t)b, why);
                    return true;
                }
                for (size_t k = a; k < b; k++) if (cps[k] < 0xDC80 || cps[k] > 0xDCFF) cx_raise_encode(name, s, cps, (int64_t)a, (int64_t)b, why);
                // UTF-16/32 take a bytes replacement in whole code units only
                size_t unit = cx_is_utf16(c) ? 2 : cx_is_utf32(c) ? 4 : 1;
                if ((b - a) % unit != 0) cx_raise_encode(name, s, cps, (int64_t)a, (int64_t)b, why);
                for (size_t k = a; k < b; k++) out += (char)(cps[k] - 0xDC00);
                return true;
            }
            case EH::SurrPass: {
                bool utf = c == Cx::UTF8 || c == Cx::UTF8SIG || cx_is_utf16(c) || cx_is_utf32(c);
                for (size_t k = a; k < b; k++) if (!utf || cps[k] < 0xD800 || cps[k] > 0xDFFF) cx_raise_encode(name, s, cps, (int64_t)a, (int64_t)b, why);
                for (size_t k = a; k < b; k++) {
                    if (c == Cx::UTF8 || c == Cx::UTF8SIG) u8_encode(cps[k], out);
                    else if (cx_is_utf16(c)) put16(cps[k]);
                    else for (int j = 0; j < 4; j++) out += (char)((cps[k] >> (8 * (le ? j : 3 - j))) & 0xFF);
                }
                return true;
            }
        }
        return true;
    }
    // Encodes from character `pos`; returns where it stopped.
    size_t run(size_t pos) {
        if (pos == 0) {
            if (c == Cx::UTF8SIG) out += "\xEF\xBB\xBF";
            if (c == Cx::UTF16) out += "\xFF\xFE";
            if (c == Cx::UTF32) out += std::string("\xFF\xFE\0\0", 4);
        }
        size_t n = cps.size(), i = pos;
        // UTF-16/32 report each unencodable character on its own (CPython's
        // encoders); the others a run of them
        bool single = cx_is_utf16(c) || cx_is_utf32(c);
        while (i < n) {
            if (can(cps[i])) { put(cps[i]); i++; continue; }
            size_t b = i + 1;
            while (!single && b < n && !can(cps[b])) b++;
            if (!bad(i, b)) return i;
            i = b;
        }
        return n;
    }
};

// str -> bytes. consumed: characters encoded (for "stop").
inline std::string codec_encode(Cx c, const std::string& s, EH eh, size_t start, size_t& consumed, CxErr& err) {
    CxEncoder e(c, eh, s, err);
    consumed = e.run(start);
    return std::move(e.out);
}

// Has the str a lone surrogate (a three-byte ED A0..BF xx sequence)?
inline bool cx_has_surrogate(const std::string& s) {
    for (size_t i = 0; i + 1 < s.size(); i++)
        if ((unsigned char)s[i] == 0xED && (unsigned char)s[i + 1] >= 0xA0) return true;
    return false;
}

// The names str.encode / bytes.decode handle without the codec registry in
// CPython (PyUnicode_Decode's fast paths): an error a handler raises from
// any other codec is wrapped, "decoding with 'cp1252' codec failed
// (TypeError: ...)".
inline bool cx_fast_path(const std::string& encoding) {
    std::string n = codec_normalize(encoding);
    return n == "utf8" || n == "utf_8" || n == "utf16" || n == "utf_16" || n == "utf32" || n == "utf_32"
        || n == "ascii" || n == "us_ascii" || n == "latin1" || n == "latin_1" || n == "iso_8859_1" || n == "iso8859_1";
}
template <typename F>
std::string cx_wrapped(const std::string& encoding, bool decoding, F f) {
    try {
        return f();
    } catch (PyError& e) {
        if (cx_fast_path(encoding) || (e.type != "TypeError" && e.type != "LookupError" && e.type != "ValueError")) throw;
        throw PyError(e.type, std::string(decoding ? "decoding" : "encoding") + " with " + str_repr(encoding)
                      + " codec failed (" + e.type + ": " + e.msg + ")");
    }
}

// What str.encode / bytes.decode run (NyBytes.hpp's str_encode /
// bytes_decode): the whole input, a builtin handler.
inline std::string codec_decode_all(const std::string& s, const std::string& encoding, const std::string& errors) {
    Cx c;
    EH e;
    if (!codec_find(encoding, c)) raise("LookupError", "unknown encoding: " + encoding);
    if (!eh_find(errors, e) || e == EH::Stop) raise("LookupError", "unknown error handler name '" + errors + "'");
    if (c == Cx::UTF8 && is_ascii(s)) return s;
    return cx_wrapped(encoding, true, [&] {
        CxErr err;
        size_t used = 0;
        return codec_decode(c, s, e, true, 0, used, err);
    });
}
inline std::string codec_encode_all(const std::string& s, const std::string& encoding, const std::string& errors) {
    Cx c;
    EH e;
    if (!codec_find(encoding, c)) raise("LookupError", "unknown encoding: " + encoding);
    if (!eh_find(errors, e) || e == EH::Stop) raise("LookupError", "unknown error handler name '" + errors + "'");
    if (c == Cx::UTF8 && !cx_has_surrogate(s)) return s;
    if ((c == Cx::ASCII || c == Cx::LATIN1) && is_ascii(s)) return s;
    return cx_wrapped(encoding, false, [&] {
        CxErr err;
        size_t used = 0;
        return codec_encode(c, s, e, 0, used, err);
    });
}

}  // namespace nypy
