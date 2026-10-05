#pragma once
// NyStr.hpp - Python str semantics over UTF-8 std::string, shared by both
// engines so that every string method behaves identically on the
// interpreter and the VM.
//
// Indexes are in CHARACTERS (code points), as len() already counted them;
// plain-ASCII strings take a byte-indexed fast path. Errors are thrown as
// nypy::PyError{type, message}; each engine converts that into its own
// exception representation.
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>
#include "NyBigInt.hpp"
#include <cstdlib>
#include <cstdio>
#include <cmath>
#include <cstring>

namespace nypy {


// ── UTF-8 ───────────────────────────────────────────────────────────────
// True when the first n bytes (all of them by default) are ASCII: there a
// character index is a byte index. Eight bytes at a time, since indexing and
// slicing ask on every call.
inline bool ascii_prefix(const std::string& s, size_t n) {
    if (n > s.size()) n = s.size();
    const char* p = s.data();
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t w; std::memcpy(&w, p + i, 8);
        if (w & 0x8080808080808080ULL) return false;
    }
    for (; i < n; i++) if ((unsigned char)p[i] >= 0x80) return false;
    return true;
}
inline bool is_ascii(const std::string& s) { return ascii_prefix(s, s.size()); }
inline size_t u8_seq(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c >> 5) == 6) return 2;
    if ((c >> 4) == 14) return 3;
    if ((c >> 3) == 30) return 4;
    return 1; // stray continuation / invalid byte: one character
}
// Length of the character starting at byte i (clipped to the string).
inline size_t u8_at_len(const std::string& s, size_t i) {
    size_t n = u8_seq((unsigned char)s[i]);
    if (i + n > s.size()) n = s.size() - i;
    return n;
}
inline size_t u8_len(const std::string& s) {
    if (is_ascii(s)) return s.size();
    size_t n = 0;
    for (size_t i = 0; i < s.size(); i += u8_at_len(s, i)) n++;
    return n;
}
inline uint32_t u8_decode(const std::string& s, size_t& i) {
    unsigned char c = (unsigned char)s[i];
    size_t n = u8_at_len(s, i);
    uint32_t cp;
    if (n == 1) cp = c;
    else if (n == 2) cp = ((c & 0x1Fu) << 6) | (s[i+1] & 0x3F);
    else if (n == 3) cp = ((c & 0x0Fu) << 12) | ((s[i+1] & 0x3Fu) << 6) | (s[i+2] & 0x3F);
    else cp = ((c & 0x07u) << 18) | ((s[i+1] & 0x3Fu) << 12) | ((s[i+2] & 0x3Fu) << 6) | (s[i+3] & 0x3F);
    i += n;
    return cp;
}
inline void u8_encode(uint32_t cp, std::string& out) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}
inline std::vector<uint32_t> u8_codepoints(const std::string& s) {
    std::vector<uint32_t> r; r.reserve(s.size());
    for (size_t i = 0; i < s.size();) r.push_back(u8_decode(s, i));
    return r;
}
inline std::string u8_from_cps(const std::vector<uint32_t>& cps, size_t a = 0, size_t b = (size_t)-1) {
    std::string r; if (b > cps.size()) b = cps.size();
    for (size_t i = a; i < b; i++) u8_encode(cps[i], r);
    return r;
}
// Byte offset of every character, plus s.size() at the end.
inline std::vector<size_t> u8_offsets(const std::string& s) {
    std::vector<size_t> r; r.reserve(s.size() + 1);
    for (size_t i = 0; i < s.size(); i += u8_at_len(s, i)) r.push_back(i);
    r.push_back(s.size());
    return r;
}
// Splits into one string per character.
inline std::vector<std::string> u8_chars(const std::string& s) {
    std::vector<std::string> r; r.reserve(s.size());
    for (size_t i = 0; i < s.size();) { size_t n = u8_at_len(s, i); r.emplace_back(s, i, n); i += n; }
    return r;
}
// Byte offset -> character index.
inline int64_t u8_char_index(const std::string& s, size_t byte) {
    int64_t n = 0;
    for (size_t i = 0; i < byte && i < s.size(); i += u8_at_len(s, i)) n++;
    return n;
}

// ── slices ──────────────────────────────────────────────────────────────
// PySlice_AdjustIndices: clamps start/stop for a sequence of length len and
// returns the number of items selected.
inline int64_t slice_adjust(int64_t len, bool has_start, int64_t& start, bool has_stop, int64_t& stop, int64_t step) {
    if (step == 0) raise("ValueError", "slice step cannot be zero");
    if (!has_start) start = step < 0 ? len - 1 : 0;
    else if (start < 0) { start += len; if (start < 0) start = step < 0 ? -1 : 0; }
    else if (start >= len) start = step < 0 ? len - 1 : len;
    if (!has_stop) stop = step < 0 ? -1 : len;
    else if (stop < 0) { stop += len; if (stop < 0) stop = step < 0 ? -1 : 0; }
    else if (stop >= len) stop = step < 0 ? len - 1 : len;
    if (step < 0) return stop < start ? (start - stop - 1) / (-step) + 1 : 0;
    return start < stop ? (stop - start - 1) / step + 1 : 0;
}
// Normalises a sequence index; returns false when out of range.
inline bool seq_index(int64_t len, int64_t& i) {
    if (i < 0) i += len;
    return i >= 0 && i < len;
}

// ── character classes (ASCII exact, common Unicode letters approximated) ─
inline bool cp_is_space(uint32_t c) {
    return c == ' ' || (c >= 9 && c <= 13) || (c >= 0x1C && c <= 0x1F) || c == 0x85 || c == 0xA0 ||
           c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F ||
           c == 0x205F || c == 0x3000;
}
inline bool cp_is_digit(uint32_t c) { return c >= '0' && c <= '9'; }
inline uint32_t cp_upper(uint32_t c) {
    if (c < 0x80) return (c >= 'a' && c <= 'z') ? c - 32 : c;
    if ((c >= 0xE0 && c <= 0xFE && c != 0xF7)) return c - 0x20;
    if (c == 0xFF) return 0x178;
    if (c == 0xB5) return 0x39C;
    if (c >= 0x100 && c <= 0x137) return (c & 1) ? c - 1 : c;
    if (c >= 0x139 && c <= 0x148) return (c & 1) ? c : c - 1;
    if (c >= 0x14A && c <= 0x177) return (c & 1) ? c - 1 : c;
    if (c >= 0x179 && c <= 0x17E) return (c & 1) ? c : c - 1;
    if (c == 0x17F) return 'S';
    if (c >= 0x3B1 && c <= 0x3C9 && c != 0x3C2) return c - 0x20;
    if (c == 0x3C2) return 0x3A3;
    if (c >= 0x3AC && c <= 0x3AF) { static const uint32_t m[] = {0x386, 0x388, 0x389, 0x38A}; return m[c - 0x3AC]; }
    if (c >= 0x430 && c <= 0x44F) return c - 0x20;
    if (c >= 0x450 && c <= 0x45F) return c - 0x50;
    if (c >= 0x460 && c <= 0x4FF) return (c & 1) ? c - 1 : c;
    return c;
}
inline uint32_t cp_lower(uint32_t c) {
    if (c < 0x80) return (c >= 'A' && c <= 'Z') ? c + 32 : c;
    if ((c >= 0xC0 && c <= 0xDE && c != 0xD7)) return c + 0x20;
    if (c == 0x178) return 0xFF;
    if (c >= 0x100 && c <= 0x137) return (c & 1) ? c : c + 1;
    if (c >= 0x139 && c <= 0x148) return (c & 1) ? c + 1 : c;
    if (c >= 0x14A && c <= 0x177) return (c & 1) ? c : c + 1;
    if (c >= 0x179 && c <= 0x17E) return (c & 1) ? c + 1 : c;
    if (c >= 0x391 && c <= 0x3A9 && c != 0x3A2) return c + 0x20;
    if (c == 0x386) return 0x3AC;
    if (c >= 0x388 && c <= 0x38A) return c + 0x25;
    if (c >= 0x410 && c <= 0x42F) return c + 0x20;
    if (c >= 0x400 && c <= 0x40F) return c + 0x50;
    if (c >= 0x460 && c <= 0x4FF) return (c & 1) ? c : c + 1;
    return c;
}
inline bool cp_is_upper(uint32_t c) { return cp_lower(c) != c; }
inline bool cp_is_lower(uint32_t c) { return cp_upper(c) != c || c == 0xDF || c == 0x138; }
inline bool cp_is_cased(uint32_t c) { return cp_is_upper(c) || cp_is_lower(c); }
inline bool cp_is_alpha(uint32_t c) {
    if (c < 0x80) return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (c == 0xAA || c == 0xB5 || c == 0xBA) return true;
    if (c >= 0xC0 && c <= 0x24F) return c != 0xD7 && c != 0xF7;
    if (c >= 0x250 && c <= 0x2C1) return true;
    if (c >= 0x370 && c <= 0x3FF) return c != 0x375 && c != 0x37E && c != 0x384 && c != 0x385 && c != 0x387;
    if (c >= 0x400 && c <= 0x481) return true;
    if (c >= 0x48A && c <= 0x52F) return true;
    if (c >= 0x531 && c <= 0x556) return true;
    if (c >= 0x561 && c <= 0x587) return true;
    if (c >= 0x5D0 && c <= 0x5EA) return true;
    if (c >= 0x620 && c <= 0x64A) return true;
    if (c >= 0x904 && c <= 0x939) return true;
    if (c >= 0xE01 && c <= 0xE30) return true;
    if (c >= 0x1E00 && c <= 0x1FBC) return true;
    if (c >= 0x3041 && c <= 0x3096) return true;
    if (c >= 0x30A1 && c <= 0x30FA) return true;
    if (c >= 0x3400 && c <= 0x4DBF) return true;
    if (c >= 0x4E00 && c <= 0x9FFF) return true;
    if (c >= 0xAC00 && c <= 0xD7A3) return true;
    if (c >= 0xF900 && c <= 0xFAFF) return true;
    return false;
}
inline bool cp_is_printable(uint32_t c) {
    if (c < 0x20 || c == 0x7F) return false;
    if (c >= 0x80 && c <= 0xA0) return false;
    if (c == 0xAD) return false;
    if (c == 0x2028 || c == 0x2029 || (c >= 0x2000 && c <= 0x200F) || (c >= 0x202A && c <= 0x202F) || c == 0x205F || c == 0x3000 || c == 0xFEFF) return false;
    if (c >= 0xD800 && c <= 0xDFFF) return false;
    return true;
}

// ── case mapping ────────────────────────────────────────────────────────
inline std::string str_upper(const std::string& s) {
    std::string r; r.reserve(s.size());
    if (is_ascii(s)) { for (char c : s) r += (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; return r; }
    for (size_t i = 0; i < s.size();) {
        uint32_t c = u8_decode(s, i);
        if (c == 0xDF) { r += "SS"; continue; }
        u8_encode(cp_upper(c), r);
    }
    return r;
}
inline std::string str_lower(const std::string& s) {
    std::string r; r.reserve(s.size());
    if (is_ascii(s)) { for (char c : s) r += (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; return r; }
    for (size_t i = 0; i < s.size();) u8_encode(cp_lower(u8_decode(s, i)), r);
    return r;
}
inline std::string str_casefold(const std::string& s) {
    std::string r;
    for (size_t i = 0; i < s.size();) { uint32_t c = u8_decode(s, i); if (c == 0xDF) r += "ss"; else u8_encode(cp_lower(c), r); }
    return r;
}
inline std::string str_swapcase(const std::string& s) {
    std::string r;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = u8_decode(s, i);
        if (c == 0xDF) { r += "SS"; continue; }
        if (cp_is_upper(c)) u8_encode(cp_lower(c), r);
        else if (cp_is_lower(c)) u8_encode(cp_upper(c), r);
        else u8_encode(c, r);
    }
    return r;
}
inline std::string str_capitalize(const std::string& s) {
    std::string r; bool first = true;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = u8_decode(s, i);
        if (first) { if (c == 0xDF) r += "Ss"; else u8_encode(cp_upper(c), r); first = false; }
        else u8_encode(cp_lower(c), r);
    }
    return r;
}
inline std::string str_title(const std::string& s) {
    std::string r; bool prev_cased = false;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = u8_decode(s, i);
        bool cased = cp_is_cased(c);
        if (cased) { if (prev_cased) u8_encode(cp_lower(c), r); else if (c == 0xDF) r += "Ss"; else u8_encode(cp_upper(c), r); }
        else u8_encode(c, r);
        prev_cased = cased;
    }
    return r;
}

// ── predicates ──────────────────────────────────────────────────────────
template<class F> inline bool all_cps(const std::string& s, F f) {
    if (s.empty()) return false;
    for (size_t i = 0; i < s.size();) if (!f(u8_decode(s, i))) return false;
    return true;
}
inline bool str_isdigit(const std::string& s) { return all_cps(s, cp_is_digit); }
inline bool str_isalpha(const std::string& s) { return all_cps(s, cp_is_alpha); }
inline bool str_isalnum(const std::string& s) { return all_cps(s, [](uint32_t c) { return cp_is_alpha(c) || cp_is_digit(c); }); }
inline bool str_isspace(const std::string& s) { return all_cps(s, cp_is_space); }
inline bool str_isascii(const std::string& s) { return is_ascii(s); }
inline bool str_isprintable(const std::string& s) {
    for (size_t i = 0; i < s.size();) if (!cp_is_printable(u8_decode(s, i))) return false;
    return true;
}
inline bool str_isupper(const std::string& s) {
    bool cased = false;
    for (size_t i = 0; i < s.size();) { uint32_t c = u8_decode(s, i); if (cp_is_lower(c)) return false; if (cp_is_upper(c)) cased = true; }
    return cased;
}
inline bool str_islower(const std::string& s) {
    bool cased = false;
    for (size_t i = 0; i < s.size();) { uint32_t c = u8_decode(s, i); if (cp_is_upper(c)) return false; if (cp_is_lower(c)) cased = true; }
    return cased;
}
inline bool str_istitle(const std::string& s) {
    bool cased = false, prev_cased = false;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = u8_decode(s, i);
        if (cp_is_upper(c)) { if (prev_cased) return false; prev_cased = true; cased = true; }
        else if (cp_is_lower(c)) { if (!prev_cased) return false; prev_cased = true; cased = true; }
        else prev_cased = false;
    }
    return cased;
}
inline bool str_isidentifier(const std::string& s) {
    if (s.empty()) return false;
    bool first = true;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = u8_decode(s, i);
        bool ok = c == '_' || cp_is_alpha(c) || (!first && cp_is_digit(c));
        if (!ok) return false;
        first = false;
    }
    return true;
}

// ── search ──────────────────────────────────────────────────────────────
// Resolves optional [start, end) character bounds the way str.find does
// (like a slice, but a start beyond the end is reported as > len).
struct Bounds { int64_t start, end; };
inline Bounds adjust_bounds(int64_t len, bool has_start, int64_t start, bool has_end, int64_t end) {
    if (!has_start) start = 0;
    if (!has_end) end = len;
    if (end > len) end = len;
    else if (end < 0) { end += len; if (end < 0) end = 0; }
    if (start < 0) { start += len; if (start < 0) start = 0; }
    return {start, end};
}
// Converts [start,end) character bounds to byte offsets (ASCII: identity).
struct ByteView { size_t b0, b1; bool ascii; std::vector<size_t> offs; };
inline ByteView byte_view(const std::string& s, int64_t start, int64_t end) {
    ByteView v; v.ascii = is_ascii(s);
    if (v.ascii) { v.b0 = (size_t)start; v.b1 = (size_t)std::max(start, end); return v; }
    v.offs = u8_offsets(s);
    int64_t n = (int64_t)v.offs.size() - 1;
    v.b0 = v.offs[(size_t)std::min(start, n)];
    v.b1 = v.offs[(size_t)std::max(std::min(end, n), std::min(start, n))];
    return v;
}
inline int64_t to_char_index(const ByteView& v, const std::string& s, size_t byte) {
    if (v.ascii) return (int64_t)byte;
    auto it = std::lower_bound(v.offs.begin(), v.offs.end(), byte);
    (void)s;
    return (int64_t)(it - v.offs.begin());
}
inline int64_t str_find(const std::string& s, const std::string& sub, bool hs = false, int64_t st = 0, bool he = false, int64_t en = 0) {
    int64_t len = is_ascii(s) ? (int64_t)s.size() : (int64_t)u8_len(s);
    Bounds b = adjust_bounds(len, hs, st, he, en);
    if (b.start > len) return -1;
    ByteView v = byte_view(s, b.start, b.end);
    if (b.end - b.start < 0) return -1;
    if (v.b1 - v.b0 < sub.size()) return sub.empty() && b.start <= b.end ? b.start : -1;
    size_t p = s.find(sub, v.b0);
    if (p == std::string::npos || p + sub.size() > v.b1) return -1;
    return to_char_index(v, s, p);
}
inline int64_t str_rfind(const std::string& s, const std::string& sub, bool hs = false, int64_t st = 0, bool he = false, int64_t en = 0) {
    int64_t len = is_ascii(s) ? (int64_t)s.size() : (int64_t)u8_len(s);
    Bounds b = adjust_bounds(len, hs, st, he, en);
    if (b.start > len || b.end < b.start) return -1;
    ByteView v = byte_view(s, b.start, b.end);
    if (v.b1 - v.b0 < sub.size()) return -1;
    if (sub.empty()) return b.end;
    size_t p = s.rfind(sub, v.b1 - sub.size());
    if (p == std::string::npos || p < v.b0) return -1;
    return to_char_index(v, s, p);
}
inline int64_t str_count(const std::string& s, const std::string& sub, bool hs = false, int64_t st = 0, bool he = false, int64_t en = 0) {
    int64_t len = is_ascii(s) ? (int64_t)s.size() : (int64_t)u8_len(s);
    Bounds b = adjust_bounds(len, hs, st, he, en);
    if (b.start > len || b.end < b.start) return 0;
    if (sub.empty()) return b.end - b.start + 1;
    ByteView v = byte_view(s, b.start, b.end);
    int64_t n = 0;
    for (size_t p = s.find(sub, v.b0); p != std::string::npos && p + sub.size() <= v.b1; p = s.find(sub, p + sub.size())) n++;
    return n;
}
inline bool str_startswith(const std::string& s, const std::vector<std::string>& prefixes, bool hs = false, int64_t st = 0, bool he = false, int64_t en = 0, bool ends = false) {
    int64_t len = is_ascii(s) ? (int64_t)s.size() : (int64_t)u8_len(s);
    Bounds b = adjust_bounds(len, hs, st, he, en);
    if (b.start > len || b.end < b.start) return false;
    ByteView v = byte_view(s, b.start, b.end);
    size_t n = v.b1 >= v.b0 ? v.b1 - v.b0 : 0;
    for (auto& p : prefixes) {
        if (p.size() > n) continue;
        if (!ends) { if (s.compare(v.b0, p.size(), p) == 0) return true; }
        else { if (s.compare(v.b1 - p.size(), p.size(), p) == 0) return true; }
    }
    return false;
}

// ── split / join / strip ────────────────────────────────────────────────
// Whitespace test on the character starting at byte i; sets n to its length.
inline bool ws_at(const std::string& s, size_t i, size_t& n) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { n = 1; return c == ' ' || (c >= 9 && c <= 13) || (c >= 0x1C && c <= 0x1F); }
    size_t j = i; uint32_t cp = u8_decode(s, j); n = j - i;
    return cp_is_space(cp);
}
inline std::vector<std::string> str_split(const std::string& s, bool has_sep, const std::string& sep, int64_t maxsplit = -1) {
    std::vector<std::string> out;
    if (!has_sep) {
        size_t i = 0, n = 0, L = s.size();
        while (true) {
            while (i < L && ws_at(s, i, n)) i += n;
            if (i >= L) break;
            if (maxsplit >= 0 && (int64_t)out.size() >= maxsplit) {
                // The rest, with trailing whitespace kept (CPython).
                out.push_back(s.substr(i));
                break;
            }
            size_t j = i;
            while (j < L && !ws_at(s, j, n)) j += n;
            out.push_back(s.substr(i, j - i));
            i = j;
        }
        return out;
    }
    if (sep.empty()) raise("ValueError", "empty separator");
    size_t pos = 0, f;
    while ((maxsplit < 0 || (int64_t)out.size() < maxsplit) && (f = s.find(sep, pos)) != std::string::npos) {
        out.push_back(s.substr(pos, f - pos));
        pos = f + sep.size();
    }
    out.push_back(s.substr(pos));
    return out;
}
inline std::vector<std::string> str_rsplit(const std::string& s, bool has_sep, const std::string& sep, int64_t maxsplit = -1) {
    if (maxsplit < 0) return str_split(s, has_sep, sep, -1);
    std::vector<std::string> out;
    if (!has_sep) {
        // Work on characters from the right.
        auto offs = u8_offsets(s);
        int64_t k = (int64_t)offs.size() - 1; // character count
        auto is_ws = [&](int64_t ci) { size_t n; return ws_at(s, offs[(size_t)ci], n); };
        int64_t j = k;
        while (true) {
            while (j > 0 && is_ws(j - 1)) j--;
            if (j <= 0) break;
            if ((int64_t)out.size() >= maxsplit) { out.push_back(s.substr(0, offs[(size_t)j])); break; }
            int64_t i = j;
            while (i > 0 && !is_ws(i - 1)) i--;
            out.push_back(s.substr(offs[(size_t)i], offs[(size_t)j] - offs[(size_t)i]));
            j = i;
        }
        std::reverse(out.begin(), out.end());
        return out;
    }
    if (sep.empty()) raise("ValueError", "empty separator");
    size_t end = s.size();
    while ((int64_t)out.size() < maxsplit) {
        if (end < sep.size()) break;
        size_t f = s.rfind(sep, end - sep.size());
        if (f == std::string::npos) break;
        out.push_back(s.substr(f + sep.size(), end - f - sep.size()));
        end = f;
    }
    out.push_back(s.substr(0, end));
    std::reverse(out.begin(), out.end());
    return out;
}
inline std::vector<std::string> str_splitlines(const std::string& s, bool keepends = false) {
    std::vector<std::string> out;
    size_t i = 0, start = 0, L = s.size();
    while (i < L) {
        unsigned char c = (unsigned char)s[i];
        size_t eol = 0;
        if (c == '\n' || c == 0x0B || c == 0x0C || (c >= 0x1C && c <= 0x1E)) eol = 1;
        else if (c == '\r') eol = (i + 1 < L && s[i+1] == '\n') ? 2 : 1;
        else if (c == 0xC2 && i + 1 < L && (unsigned char)s[i+1] == 0x85) eol = 2;
        else if (c == 0xE2 && i + 2 < L && (unsigned char)s[i+1] == 0x80 && ((unsigned char)s[i+2] == 0xA8 || (unsigned char)s[i+2] == 0xA9)) eol = 3;
        if (eol) {
            out.push_back(s.substr(start, (keepends ? i + eol : i) - start));
            i += eol; start = i;
        } else i++;
    }
    if (start < L) out.push_back(s.substr(start));
    return out;
}
// strip/lstrip/rstrip. chars == nullptr strips whitespace.
inline std::string str_strip(const std::string& s, const std::string* chars, int which /*0 both,1 left,2 right*/) {
    if (chars && is_ascii(*chars) && is_ascii(s)) {
        size_t a = 0, b = s.size();
        if (which != 2) while (a < b && chars->find(s[a]) != std::string::npos) a++;
        if (which != 1) while (b > a && chars->find(s[b-1]) != std::string::npos) b--;
        return s.substr(a, b - a);
    }
    auto cps = u8_codepoints(s);
    std::vector<uint32_t> set;
    if (chars) set = u8_codepoints(*chars);
    auto strip_it = [&](uint32_t c) {
        if (!chars) return cp_is_space(c);
        return std::find(set.begin(), set.end(), c) != set.end();
    };
    size_t a = 0, b = cps.size();
    if (which != 2) while (a < b && strip_it(cps[a])) a++;
    if (which != 1) while (b > a && strip_it(cps[b-1])) b--;
    return u8_from_cps(cps, a, b);
}

// ── replace / partition / padding ───────────────────────────────────────
inline std::string str_replace(const std::string& s, const std::string& from, const std::string& to, int64_t count = -1) {
    std::string r;
    if (from.empty()) {
        // Insert `to` before every character and at the end.
        int64_t n = 0;
        size_t i = 0;
        while (i <= s.size()) {
            if (count >= 0 && n >= count) { r.append(s, i, std::string::npos); return r; }
            r += to; n++;
            if (i == s.size()) break;
            size_t k = u8_at_len(s, i);
            r.append(s, i, k); i += k;
        }
        return r;
    }
    size_t pos = 0, f; int64_t n = 0;
    while ((count < 0 || n < count) && (f = s.find(from, pos)) != std::string::npos) {
        r.append(s, pos, f - pos); r += to; pos = f + from.size(); n++;
    }
    r.append(s, pos, std::string::npos);
    return r;
}
inline std::vector<std::string> str_partition(const std::string& s, const std::string& sep, bool right) {
    if (sep.empty()) raise("ValueError", "empty separator");
    size_t p = right ? s.rfind(sep) : s.find(sep);
    if (p == std::string::npos) {
        if (right) return {"", "", s};
        return {s, "", ""};
    }
    return {s.substr(0, p), sep, s.substr(p + sep.size())};
}
inline size_t str_width(const std::string& s) { return is_ascii(s) ? s.size() : u8_len(s); }
inline std::string fill_of(const std::string* fill) {
    if (!fill) return " ";
    if (u8_len(*fill) != 1) raise("TypeError", "The fill character must be exactly one character long");
    return *fill;
}
inline std::string repeat_str(const std::string& f, int64_t n) {
    std::string r; if (n <= 0) return r;
    r.reserve(f.size() * (size_t)n);
    for (int64_t i = 0; i < n; i++) r += f;
    return r;
}
inline std::string str_ljust(const std::string& s, int64_t width, const std::string* fill) {
    std::string f = fill_of(fill);
    int64_t pad = width - (int64_t)str_width(s);
    return pad > 0 ? s + repeat_str(f, pad) : s;
}
inline std::string str_rjust(const std::string& s, int64_t width, const std::string* fill) {
    std::string f = fill_of(fill);
    int64_t pad = width - (int64_t)str_width(s);
    return pad > 0 ? repeat_str(f, pad) + s : s;
}
inline std::string str_center(const std::string& s, int64_t width, const std::string* fill) {
    std::string f = fill_of(fill);
    int64_t marg = width - (int64_t)str_width(s);
    if (marg <= 0) return s;
    int64_t left = marg / 2 + (marg & width & 1);
    return repeat_str(f, left) + s + repeat_str(f, marg - left);
}
inline std::string str_zfill(const std::string& s, int64_t width) {
    int64_t pad = width - (int64_t)str_width(s);
    if (pad <= 0) return s;
    if (!s.empty() && (s[0] == '+' || s[0] == '-')) return s.substr(0, 1) + std::string((size_t)pad, '0') + s.substr(1);
    return std::string((size_t)pad, '0') + s;
}
inline std::string str_expandtabs(const std::string& s, int64_t tabsize = 8) {
    std::string r; int64_t col = 0;
    for (size_t i = 0; i < s.size();) {
        char c = s[i];
        if (c == '\t') {
            if (tabsize > 0) { int64_t n = tabsize - (col % tabsize); r.append((size_t)n, ' '); col += n; }
            i++;
        } else if (c == '\n' || c == '\r') { r += c; col = 0; i++; }
        else { size_t k = u8_at_len(s, i); r.append(s, i, k); i += k; col++; }
    }
    return r;
}
inline std::string str_reverse(const std::string& s) {
    if (is_ascii(s)) return std::string(s.rbegin(), s.rend());
    auto ch = u8_chars(s);
    std::string r; r.reserve(s.size());
    for (size_t i = ch.size(); i-- > 0;) r += ch[i];
    return r;
}
inline std::string str_repeat(const std::string& s, int64_t n) { return repeat_str(s, n); }

// ── indexing and slicing in characters ──────────────────────────────────
inline std::string str_getitem(const std::string& s, int64_t i) {
    // s[i] with i >= 0 needs only the first i + 1 characters to be ASCII.
    if (i >= 0 && (uint64_t)i < s.size() && ascii_prefix(s, (size_t)i + 1)) return std::string(1, s[(size_t)i]);
    if (is_ascii(s)) {
        int64_t n = (int64_t)s.size();
        if (!seq_index(n, i)) raise("IndexError", "string index out of range");
        return std::string(1, s[(size_t)i]);
    }
    auto offs = u8_offsets(s);
    int64_t n = (int64_t)offs.size() - 1;
    if (!seq_index(n, i)) raise("IndexError", "string index out of range");
    return s.substr(offs[(size_t)i], offs[(size_t)i + 1] - offs[(size_t)i]);
}
inline std::string str_slice(const std::string& s, bool hs, int64_t start, bool he, int64_t stop, int64_t step = 1) {
    // s[a:b] with 0 <= a <= b: only the first b characters matter.
    if (step == 1 && hs && he && start >= 0 && stop >= start && ascii_prefix(s, (size_t)std::min<uint64_t>((uint64_t)stop, s.size())))
        return (uint64_t)start >= s.size() ? std::string() : s.substr((size_t)start, (size_t)(stop - start));
    bool ascii = is_ascii(s);
    std::vector<size_t> offs;
    int64_t len;
    if (ascii) len = (int64_t)s.size(); else { offs = u8_offsets(s); len = (int64_t)offs.size() - 1; }
    int64_t n = slice_adjust(len, hs, start, he, stop, step);
    std::string r;
    if (n <= 0) return r;
    if (step == 1) {
        if (ascii) return s.substr((size_t)start, (size_t)n);
        return s.substr(offs[(size_t)start], offs[(size_t)(start + n)] - offs[(size_t)start]);
    }
    for (int64_t k = 0, i = start; k < n; k++, i += step) {
        if (ascii) r += s[(size_t)i];
        else r.append(s, offs[(size_t)i], offs[(size_t)i + 1] - offs[(size_t)i]);
    }
    return r;
}

// ── ord / chr / repr ────────────────────────────────────────────────────
inline int64_t str_ord(const std::string& s) {
    size_t n = s.empty() ? 0 : u8_at_len(s, 0);
    if (s.empty() || n != s.size())
        raise("TypeError", "ord() expected a character, but string of length " + std::to_string(u8_len(s)) + " found");
    size_t i = 0;
    return (int64_t)u8_decode(s, i);
}
inline std::string str_chr(int64_t cp) {
    if (cp < 0 || cp > 0x10FFFF) raise("ValueError", "chr() arg not in range(0x110000)");
    std::string r; u8_encode((uint32_t)cp, r); return r;
}
inline std::string hex_esc(uint32_t c) {
    char buf[16];
    if (c <= 0xFF) snprintf(buf, sizeof buf, "\\x%02x", c);
    else if (c <= 0xFFFF) snprintf(buf, sizeof buf, "\\u%04x", c);
    else snprintf(buf, sizeof buf, "\\U%08x", c);
    return buf;
}
// Python repr() of a str; ascii_only gives ascii().
inline std::string str_repr(const std::string& s, bool ascii_only = false) {
    char q = '\'';
    if (s.find('\'') != std::string::npos && s.find('"') == std::string::npos) q = '"';
    std::string r; r.reserve(s.size() + 2);
    r += q;
    for (size_t i = 0; i < s.size();) {
        unsigned char b = (unsigned char)s[i];
        if (b < 0x80) {
            i++;
            if (b == (unsigned char)q || b == '\\') { r += '\\'; r += (char)b; }
            else if (b == '\n') r += "\\n";
            else if (b == '\t') r += "\\t";
            else if (b == '\r') r += "\\r";
            else if (b < 0x20 || b == 0x7F) r += hex_esc(b);
            else r += (char)b;
            continue;
        }
        size_t j = i;
        uint32_t c = u8_decode(s, j);
        if (ascii_only || !cp_is_printable(c)) r += hex_esc(c);
        else r.append(s, i, j - i);
        i = j;
    }
    r += q;
    return r;
}

} // namespace nypy

// ── str methods, engine-neutral ─────────────────────────────────────────
// Both engines convert the call's arguments to SArg, call str_method and
// convert the SRes back, so every str method has exactly one
// implementation. str.format needs the engine's values and lives in each
// engine; everything else is here.
namespace nypy {
struct SArg {
    enum K { NONE, INT, STR, STRS, BOOL, OTHER } k = NONE;
    int64_t i = 0;
    std::string s;
    std::vector<std::string> v;   // STRS: a tuple/list of strings
    std::string tname;            // type name, for messages
};
struct SRes {
    enum K { NONE, INT, STR, BOOL, LIST, TUPLE } k = NONE;
    int64_t i = 0;
    bool b = false;
    std::string s;
    std::vector<std::string> v;
};
inline SRes sres_str(std::string s) { SRes r; r.k = SRes::STR; r.s = std::move(s); return r; }
inline SRes sres_int(int64_t i) { SRes r; r.k = SRes::INT; r.i = i; return r; }
inline SRes sres_bool(bool b) { SRes r; r.k = SRes::BOOL; r.b = b; return r; }
inline SRes sres_list(std::vector<std::string> v, bool tuple = false) { SRes r; r.k = tuple ? SRes::TUPLE : SRes::LIST; r.v = std::move(v); return r; }

inline bool str_method(const std::string& s, const std::string& m, const std::vector<SArg>& a, SRes& out) {
    const size_t n = a.size();
    // The method name against each literal: length first, no strlen.
    auto M = [&m](const auto& lit) { return m.size() == sizeof(lit) - 1 && std::memcmp(m.data(), lit, sizeof(lit) - 1) == 0; };
    auto bad_arg = [&](size_t i, const char* want) {
        raise("TypeError", m + "() argument " + std::to_string(i + 1) + " must be " + want + ", not " + (i < n ? a[i].tname : std::string("nothing")));
    };
    auto need = [&](size_t lo, size_t hi) {
        if (n < lo || n > hi) {
            if (lo == hi) raise("TypeError", m + "() takes exactly " + std::to_string(lo) + " argument" + (lo == 1 ? "" : "s") + " (" + std::to_string(n) + " given)");
            raise("TypeError", m + "() takes at most " + std::to_string(hi) + " arguments (" + std::to_string(n) + " given)");
        }
    };
    auto str_at = [&](size_t i) -> const std::string& { if (i >= n || a[i].k != SArg::STR) bad_arg(i, "str"); return a[i].s; };
    auto int_at = [&](size_t i) -> int64_t {
        if (i >= n || (a[i].k != SArg::INT && a[i].k != SArg::BOOL)) raise("TypeError", "'" + (i < n ? a[i].tname : std::string("NoneType")) + "' object cannot be interpreted as an integer");
        return a[i].i;
    };
    // Optional start/end bounds (None allowed).
    auto opt_int = [&](size_t i, bool& has, int64_t& v) {
        has = false;
        if (i < n && a[i].k != SArg::NONE) {
            if (a[i].k != SArg::INT && a[i].k != SArg::BOOL) raise("TypeError", "slice indices must be integers or None or have an __index__ method");
            has = true; v = a[i].i;
        }
    };
    auto opt_chars = [&](size_t i) -> const std::string* {
        if (i < n && a[i].k != SArg::NONE) { if (a[i].k != SArg::STR) bad_arg(i, "str or None"); return &a[i].s; }
        return nullptr;
    };
    // ── case / predicates
    if (M("upper")) { out = sres_str(str_upper(s)); return true; }
    if (M("lower")) { out = sres_str(str_lower(s)); return true; }
    if (M("casefold")) { out = sres_str(str_casefold(s)); return true; }
    if (M("swapcase")) { out = sres_str(str_swapcase(s)); return true; }
    if (M("capitalize")) { out = sres_str(str_capitalize(s)); return true; }
    if (M("title")) { out = sres_str(str_title(s)); return true; }
    if (M("isdigit") || M("isdecimal") || M("isnumeric")) { out = sres_bool(str_isdigit(s)); return true; }
    if (M("isalpha")) { out = sres_bool(str_isalpha(s)); return true; }
    if (M("isalnum")) { out = sres_bool(str_isalnum(s)); return true; }
    if (M("isspace")) { out = sres_bool(str_isspace(s)); return true; }
    if (M("isupper")) { out = sres_bool(str_isupper(s)); return true; }
    if (M("islower")) { out = sres_bool(str_islower(s)); return true; }
    if (M("istitle")) { out = sres_bool(str_istitle(s)); return true; }
    if (M("isidentifier")) { out = sres_bool(str_isidentifier(s)); return true; }
    if (M("isprintable")) { out = sres_bool(str_isprintable(s)); return true; }
    if (M("isascii")) { out = sres_bool(str_isascii(s)); return true; }
    // ── strip
    if (M("strip") || M("trim")) { need(0, 1); out = sres_str(str_strip(s, opt_chars(0), 0)); return true; }
    if (M("lstrip")) { need(0, 1); out = sres_str(str_strip(s, opt_chars(0), 1)); return true; }
    if (M("rstrip")) { need(0, 1); out = sres_str(str_strip(s, opt_chars(0), 2)); return true; }
    if (M("removeprefix")) { need(1, 1); const std::string& p = str_at(0); out = sres_str(s.compare(0, p.size(), p) == 0 && s.size() >= p.size() ? s.substr(p.size()) : s); return true; }
    if (M("removesuffix")) { need(1, 1); const std::string& p = str_at(0); out = sres_str(!p.empty() && s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0 ? s.substr(0, s.size() - p.size()) : s); return true; }
    // ── split / join
    if (M("split") || M("rsplit")) {
        need(0, 2);
        const std::string* sep = opt_chars(0);
        int64_t maxs = -1;
        if (n >= 2) maxs = int_at(1);
        out = sres_list(M("split") ? str_split(s, sep != nullptr, sep ? *sep : std::string(), maxs)
                                     : str_rsplit(s, sep != nullptr, sep ? *sep : std::string(), maxs));
        return true;
    }
    if (M("splitlines")) { need(0, 1); bool keep = n >= 1 && a[0].k != SArg::NONE && a[0].i != 0; out = sres_list(str_splitlines(s, keep)); return true; }
    if (M("join")) {
        need(1, 1);
        if (a[0].k == SArg::STR) {   // "".join("abc") joins its characters
            auto ch = u8_chars(a[0].s);
            std::string r; for (size_t i = 0; i < ch.size(); i++) { if (i) r += s; r += ch[i]; }
            out = sres_str(r); return true;
        }
        if (a[0].k != SArg::STRS) raise("TypeError", "can only join an iterable");
        std::string r;
        for (size_t i = 0; i < a[0].v.size(); i++) { if (i) r += s; r += a[0].v[i]; }
        out = sres_str(r); return true;
    }
    if (M("partition") || M("rpartition")) { need(1, 1); out = sres_list(str_partition(s, str_at(0), M("rpartition")), true); return true; }
    // ── search
    if (M("find") || M("rfind") || M("index") || M("rindex") || M("count")) {
        need(1, 3);
        const std::string& sub = str_at(0);
        bool hs, he; int64_t st = 0, en = 0;
        opt_int(1, hs, st); opt_int(2, he, en);
        int64_t r;
        if (M("count")) { out = sres_int(str_count(s, sub, hs, st, he, en)); return true; }
        bool rev = M("rfind") || M("rindex");
        r = rev ? str_rfind(s, sub, hs, st, he, en) : str_find(s, sub, hs, st, he, en);
        if (r < 0 && (M("index") || M("rindex"))) raise("ValueError", "substring not found");
        out = sres_int(r); return true;
    }
    if (M("startswith") || M("endswith") || M("starts_with") || M("ends_with")) {
        need(1, 3);
        std::vector<std::string> ps;
        if (a[0].k == SArg::STR) ps.push_back(a[0].s);
        else if (a[0].k == SArg::STRS) ps = a[0].v;
        else raise("TypeError", m + " first arg must be str or a tuple of str, not " + a[0].tname);
        bool hs, he; int64_t st = 0, en = 0;
        opt_int(1, hs, st); opt_int(2, he, en);
        out = sres_bool(str_startswith(s, ps, hs, st, he, en, m[0] == 'e'));
        return true;
    }
    if (M("contains") || M("__contains__") || M("includes")) { need(1, 1); out = sres_bool(s.find(str_at(0)) != std::string::npos); return true; }
    // ── replace / padding
    if (M("replace")) {
        need(2, 3);
        int64_t cnt = n >= 3 ? int_at(2) : -1;
        out = sres_str(str_replace(s, str_at(0), str_at(1), cnt)); return true;
    }
    if (M("center") || M("ljust") || M("rjust")) {
        need(1, 2);
        int64_t w = int_at(0);
        const std::string* f = n >= 2 ? &str_at(1) : nullptr;
        out = sres_str(M("center") ? str_center(s, w, f) : M("ljust") ? str_ljust(s, w, f) : str_rjust(s, w, f));
        return true;
    }
    if (M("zfill")) { need(1, 1); out = sres_str(str_zfill(s, int_at(0))); return true; }
    if (M("expandtabs")) { need(0, 1); out = sres_str(str_expandtabs(s, n ? int_at(0) : 8)); return true; }
    if (M("encode") || M("decode")) { out = sres_str(s); return true; }
    // ── Nython extras (kept on both engines)
    if (M("length") || M("size") || M("len")) { out = sres_int((int64_t)str_width(s)); return true; }
    if (M("reverse") || M("reversed")) { out = sres_str(str_reverse(s)); return true; }
    if (M("repeat")) { need(1, 1); out = sres_str(repeat_str(s, int_at(0))); return true; }
    if (M("charAt") || M("char_at")) {
        // Lenient, as it always was: out of range reads "".
        need(1, 1);
        int64_t i = int_at(0);
        int64_t len = (int64_t)str_width(s);
        out = sres_str(i >= 0 && i < len ? str_getitem(s, i) : std::string());
        return true;
    }
    if (M("substring") || M("substr")) {
        // (start, length), as on the interpreter since the start.
        need(0, 2);
        int64_t st = n >= 1 ? int_at(0) : 0;
        int64_t len = (int64_t)str_width(s);
        if (st < 0) st = std::max<int64_t>(0, st + len);
        if (st > len) st = len;
        int64_t cnt = n >= 2 ? int_at(1) : len - st;
        if (cnt < 0) cnt = 0;
        out = sres_str(str_slice(s, true, st, true, std::min(len, st + cnt), 1));
        return true;
    }
    if (M("slice")) {
        // s[a:b:c] - the parser emits s.slice(a, b, c) with none for a
        // missing bound.
        need(0, 3);
        bool ha, hb; int64_t st = 0, en = 0, step = 1;
        opt_int(0, ha, st); opt_int(1, hb, en);
        if (n >= 3 && a[2].k != SArg::NONE) step = int_at(2);
        out = sres_str(str_slice(s, ha, st, hb, en, step));
        return true;
    }
    if (M("to_float") || M("to_number")) {
        char* e = nullptr; double v = std::strtod(s.c_str(), &e);
        out.k = SRes::STR; out.s = (e && *e == 0 && !s.empty()) ? s : std::string("0");
        out.i = 1;   // STR with i == 1: the engine returns float(out.s)
        (void)v;
        return true;
    }
    if (M("to_int") || M("to_integer")) {
        char* e = nullptr; long long v = std::strtoll(s.c_str(), &e, 10);
        out = sres_int(e && *e == 0 && !s.empty() ? v : 0); return true;
    }
    return false;
}
} // namespace nypy

// ── dict keys ───────────────────────────────────────────────────────────
// Both engines store dicts in string-keyed maps (the interpreter's
// Containers also hold lists, instances and scopes, keyed by name). A key of
// any hashable type is stored as a canonical string:
//   str "abc"            -> "abc" (unchanged, so name lookups still work),
//                           or "\x01s" + text when it starts with "__" or
//                           "\x01" (internal markers such as "__len__"
//                           cannot be overwritten through d["__len__"])
//   int 1, True, 1.0     -> "\x01i1"   (hash-equal, as in Python; bool and
//                           integral float keys read back as ints)
//   float 1.5            -> "\x01f1.5"
//   none                 -> "\x01n"
//   tuple (1, "a")       -> "\x01t" + each element's key, length-prefixed
//   object (instance...) -> "\x01o" + an engine-specific identity
// so 1 and "1" are different keys and keys keep their type when iterated.
namespace nypy {
inline bool key_is_plain(const std::string& k) {
    return !(k.size() >= 1 && k[0] == '\x01') && !(k.size() >= 2 && k[0] == '_' && k[1] == '_');
}
inline std::string key_of_str(const std::string& s) { return key_is_plain(s) ? s : "\x01s" + s; }
inline std::string key_of_int(int64_t v) { return "\x01i" + std::to_string(v); }
inline std::string key_of_big(const BigInt& b) { int64_t v; if (b.to_i64(v)) return key_of_int(v); return "\x01i" + b.to_string(); }
inline std::string key_of_float(double d) {
    if (d == std::trunc(d) && std::fabs(d) < 9.2e18) return key_of_int((int64_t)d);
    if (d == std::trunc(d) && !std::isinf(d)) return key_of_big(BigInt::from_double(d));
    char buf[40]; snprintf(buf, sizeof buf, "%.17g", d);
    return std::string("\x01" "f") + buf;   // not "\x01f": that is one hex escape, 0x1F
}
inline std::string key_of_none() { return "\x01n"; }
inline std::string key_of_tuple(const std::vector<std::string>& parts) {
    std::string r = "\x01t";
    for (auto& p : parts) { r += std::to_string(p.size()); r += ':'; r += p; }
    return r;
}
inline std::string key_of_obj(const std::string& id) { return "\x01o" + id; }
// bytes b"abc" -> "\x01b" + the bytes (round 77): never equal to the str
// with the same characters, as in Python.
inline std::string key_of_bytes(const std::string& b) { return std::string("\x01" "b") + b; }
// Decoding: the kind of a stored key and its payload.
enum KeyKind { K_STR, K_INT, K_FLOAT, K_NONE, K_TUPLE, K_OBJ, K_BYTES };
inline KeyKind key_kind(const std::string& k) {
    if (k.size() < 2 || k[0] != '\x01') return K_STR;
    switch (k[1]) {
        case 'i': return K_INT; case 'f': return K_FLOAT; case 'n': return K_NONE;
        case 't': return K_TUPLE; case 'o': return K_OBJ; case 'b': return K_BYTES; default: return K_STR;
    }
}
inline std::string key_payload(const std::string& k) { return key_kind(k) == K_STR && key_is_plain(k) ? k : k.substr(2); }
inline std::vector<std::string> key_tuple_parts(const std::string& k) {
    std::vector<std::string> out;
    size_t i = 2;
    while (i < k.size()) {
        size_t c = k.find(':', i);
        if (c == std::string::npos) break;
        size_t n = (size_t)std::strtoull(k.c_str() + i, nullptr, 10);
        out.push_back(k.substr(c + 1, n));
        i = c + 1 + n;
    }
    return out;
}

// hash(x) from x's key: Python's own value for ints, floats (so hash(1) ==
// hash(1.0) == hash(True) == 1) and tuples of them; strings and objects get
// a stable FNV-1a (Python randomises those per process anyway).
inline int64_t hash_of_key(const std::string& k) {
    const uint64_t P = (1ULL << 61) - 1;
    auto fin = [](int64_t h) { return h == -1 ? (int64_t)-2 : h; };
    auto fnv = [&](const std::string& t) {
        uint64_t h = 1469598103934665603ULL;
        for (unsigned char c : t) { h ^= c; h *= 1099511628211ULL; }
        return fin((int64_t)(h & P));
    };
    switch (key_kind(k)) {
        case K_INT: {
            const std::string d = k.substr(2);
            bool neg = !d.empty() && d[0] == '-';
            // h*10 + digit mod P, P = 2**61 - 1 (a Mersenne prime), in 64-bit
            // arithmetic on every platform (unsigned __int128 does not exist
            // on 32-bit targets): x mod P = (x & P) + (x >> 61), and
            // h*10 = (h << 3) + (h << 1) with h < 2**61, so no term overflows.
            auto mod_p = [P](uint64_t x) { x = (x & P) + (x >> 61); return x >= P ? x - P : x; };
            uint64_t h = 0;
            for (size_t i = neg ? 1 : 0; i < d.size(); i++)
                h = mod_p(mod_p(h << 3) + mod_p(h << 1) + (uint64_t)(d[i] - '0'));
            int64_t r = (int64_t)h;
            return fin(neg ? -r : r);
        }
        case K_FLOAT: {
            double v = std::strtod(k.c_str() + 2, nullptr);
            if (std::isinf(v)) return v > 0 ? 314159 : -314159;
            if (std::isnan(v)) return 0;
            int e; double m = std::frexp(v, &e);
            int sign = 1;
            if (m < 0) { sign = -1; m = -m; }
            uint64_t x = 0;
            while (m != 0) {
                x = ((x << 28) & P) | x >> (61 - 28);
                m *= 268435456.0; e -= 28;
                uint64_t y = (uint64_t)m; m -= (double)y;
                x += y;
                if (x >= P) x -= P;
            }
            e = e >= 0 ? e % 61 : 61 - 1 - ((-1 - e) % 61);
            x = ((x << e) & P) | x >> (61 - e);
            return fin((int64_t)x * sign);
        }
        case K_NONE: return 0xFCA86420;
        case K_TUPLE: {
            // CPython's tuple hash (xxHash-derived).
            const uint64_t X1 = 11400714785074694791ULL, X2 = 14029467366897019727ULL, X5 = 2870177450012600261ULL;
            auto parts = key_tuple_parts(k);
            uint64_t acc = X5;
            for (auto& p : parts) {
                uint64_t lane = (uint64_t)hash_of_key(p);
                acc += lane * X2;
                acc = (acc << 31) | (acc >> 33);
                acc *= X1;
            }
            acc += (uint64_t)parts.size() ^ (X5 ^ 3527539ULL);
            if (acc == (uint64_t)-1) return 1546275796;
            return (int64_t)acc;
        }
        default: return fnv(k);
    }
}
} // namespace nypy
