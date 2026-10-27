#pragma once
// NyUniData.hpp - the Unicode character database of both engines (round 84):
// Unicode 14.0.0, the version CPython 3.11 uses, generated from python3's
// own database by tools/gen_unicodedata.py (include/NyUniDataTables.hpp,
// include/NyUniDataShape.hpp; the code in src/NyUniData.cpp).
//
// One record per code point holds what CPython's two records hold
// (unicodedata.c's database record and unicodectype.c's type record):
// category, combining class, bidirectional class, east asian width,
// mirrored, the normalization quick-check bits, the flags str's predicates
// read (CPython's masks, below), and the case mappings - deltas, or indexes
// into the extended array for SpecialCasing's multi-character mappings and
// for case folding where it differs from lower-casing. The records are
// found through one three-level trie (see tools/gen_unicodedata.py --stats:
// 76 KB with the decomposition index, where CPython's layout of the same
// data takes 222 KB).
//
// The lookups str's methods make on every character are inline here;
// everything else (names of categories, decompositions, normalization, the
// 3.2.0 delta, aliases and named sequences) is in src/NyUniData.cpp.
#include <cstdint>
#include <string>
#include <vector>
#include "NyUniDataShape.hpp"

namespace nyucd {

// Objects/unicodectype.c's masks
enum : uint16_t {
    ALPHA = 0x01, DECIMAL = 0x02, DIGIT = 0x04, LOWER = 0x08, LINEBREAK = 0x10, SPACE = 0x20, TITLE = 0x40,
    UPPER = 0x80, XID_START = 0x100, XID_CONTINUE = 0x200, PRINTABLE = 0x400, NUMERIC = 0x800,
    CASE_IGNORABLE = 0x1000, CASED = 0x2000, EXTENDED_CASE = 0x4000
};

inline const Rec& rec(uint32_t cp) {
    if (cp >= 0x110000) cp = 0xFFFF;   // (a noncharacter: an unassigned record)
    uint32_t i = data::kIdx1[cp >> (kIdxLo + kIdxMid)];
    i = data::kIdx2[(i << kIdxMid) + ((cp >> kIdxLo) & ((1u << kIdxMid) - 1))];
    return data::kRecs[data::kIdx3[(i << kIdxLo) + (cp & ((1u << kIdxLo) - 1))]];
}
inline uint16_t flags(uint32_t cp) { return rec(cp).flags; }
inline bool has(uint32_t cp, uint16_t f) { return (rec(cp).flags & f) != 0; }

// ── str's predicates (CPython's Py_UNICODE_IS*) ─────────────────────────────
inline bool is_space(uint32_t c) {
    if (c < 0x80) return c == ' ' || (c >= 9 && c <= 13) || (c >= 0x1C && c <= 0x1F);
    return has(c, SPACE);
}
inline bool is_linebreak(uint32_t c) {
    if (c < 0x80) return c == '\n' || c == '\r' || c == 0x0B || c == 0x0C || (c >= 0x1C && c <= 0x1E);
    return has(c, LINEBREAK);
}
inline bool is_alpha(uint32_t c) {
    if (c < 0x80) return (c | 0x20) >= 'a' && (c | 0x20) <= 'z';
    return has(c, ALPHA);
}
inline bool is_decimal(uint32_t c) { return c < 0x80 ? c >= '0' && c <= '9' : has(c, DECIMAL); }
inline bool is_digit(uint32_t c) { return c < 0x80 ? c >= '0' && c <= '9' : has(c, DIGIT); }
inline bool is_numeric(uint32_t c) { return c < 0x80 ? c >= '0' && c <= '9' : has(c, NUMERIC); }
inline bool is_alnum(uint32_t c) {
    if (c < 0x80) return ((c | 0x20) >= 'a' && (c | 0x20) <= 'z') || (c >= '0' && c <= '9');
    return has(c, ALPHA | DECIMAL | DIGIT | NUMERIC);
}
inline bool is_lower(uint32_t c) { return c < 0x80 ? c >= 'a' && c <= 'z' : has(c, LOWER); }
inline bool is_upper(uint32_t c) { return c < 0x80 ? c >= 'A' && c <= 'Z' : has(c, UPPER); }
inline bool is_title(uint32_t c) { return c >= 0x80 && has(c, TITLE); }
inline bool is_cased(uint32_t c) { return c < 0x80 ? (c | 0x20) >= 'a' && (c | 0x20) <= 'z' : has(c, CASED); }
inline bool is_case_ignorable(uint32_t c) { return has(c, CASE_IGNORABLE); }
inline bool is_printable(uint32_t c) { return c < 0x80 ? c >= 0x20 && c < 0x7F : has(c, PRINTABLE); }
inline bool is_xid_start(uint32_t c) { return has(c, XID_START); }
inline bool is_xid_continue(uint32_t c) { return has(c, XID_CONTINUE); }
// the value of a decimal / digit character, -1 when it has none
inline int to_decimal(uint32_t c) {
    if (c < 0x80) return c >= '0' && c <= '9' ? (int)(c - '0') : -1;
    const Rec& r = rec(c);
    return (r.flags & DECIMAL) ? (r.decdig & 15) : -1;
}
inline int to_digit(uint32_t c) {
    if (c < 0x80) return c >= '0' && c <= '9' ? (int)(c - '0') : -1;
    const Rec& r = rec(c);
    return (r.flags & DIGIT) ? (r.decdig >> 4) : -1;
}
double to_numeric(uint32_t c);   // -1.0 when it has none

// ── case mapping (CPython's _PyUnicode_To*Full): the mapping's code points
// in out (at most 3), their number returned
inline int ext_copy(int32_t v, uint32_t* out) {
    int n = (int)((uint32_t)v >> 24);
    for (int k = 0; k < n; k++) out[k] = data::kExtCase[(v & 0xFFFF) + k];
    return n;
}
inline int to_lower_full(uint32_t c, uint32_t* out) {
    const Rec& r = rec(c);
    if (r.flags & EXTENDED_CASE) return ext_copy(r.lower & 0x0F0FFFFF, out);
    out[0] = (uint32_t)((int32_t)c + r.lower);
    return 1;
}
inline int to_upper_full(uint32_t c, uint32_t* out) {
    const Rec& r = rec(c);
    if (r.flags & EXTENDED_CASE) return ext_copy(r.upper, out);
    out[0] = (uint32_t)((int32_t)c + r.upper);
    return 1;
}
inline int to_title_full(uint32_t c, uint32_t* out) {
    const Rec& r = rec(c);
    if (r.flags & EXTENDED_CASE) return ext_copy(r.title, out);
    out[0] = (uint32_t)((int32_t)c + r.title);
    return 1;
}
inline int to_folded_full(uint32_t c, uint32_t* out) {
    const Rec& r = rec(c);
    if ((r.flags & EXTENDED_CASE) && ((r.lower >> 20) & 7)) {
        int idx = (r.lower & 0xFFFF) + (r.lower >> 24);
        int n = (r.lower >> 20) & 7;
        for (int k = 0; k < n; k++) out[k] = data::kExtCase[idx + k];
        return n;
    }
    return to_lower_full(c, out);
}
// the simple mappings CPython's _PyUnicode_ToLowercase / ToUppercase give:
// the first code point of the full one
inline uint32_t to_lower(uint32_t c) {
    if (c < 0x80) return (c >= 'A' && c <= 'Z') ? c + 32 : c;
    uint32_t m[3];
    to_lower_full(c, m);
    return m[0];
}
inline uint32_t to_upper(uint32_t c) {
    if (c < 0x80) return (c >= 'a' && c <= 'z') ? c - 32 : c;
    uint32_t m[3];
    to_upper_full(c, m);
    return m[0];
}

// ── unicodedata's properties ────────────────────────────────────────────────
const char* category(uint32_t c);          // "Lu", "Cn", ...
const char* bidirectional(uint32_t c);     // "L", "" ...
const char* east_asian_width(uint32_t c);  // "F", "H", "W", "Na", "A", "N"
inline int combining(uint32_t c) { return rec(c).ccc; }
inline int mirrored(uint32_t c) { return rec(c).eawm & 1; }
std::string decomposition(uint32_t c);     // "<compat> 0020 0301", "" when none

// unicodedata.ucd_3_2_0 (the version IDNA's stringprep uses): CPython's
// change records over this database
struct Old { uint8_t bidir, category, decimal, mirrored, eaw; };
Old old_record(uint32_t c);
const char* category_3_2_0(uint32_t c);
const char* bidirectional_3_2_0(uint32_t c);
const char* east_asian_width_3_2_0(uint32_t c);
int combining_3_2_0(uint32_t c);
int mirrored_3_2_0(uint32_t c);
int decimal_3_2_0(uint32_t c);             // -1 when none
double numeric_3_2_0(uint32_t c);          // -1.0 when none
std::string decomposition_3_2_0(uint32_t c);
bool assigned_3_2_0(uint32_t c);

// ── normalization (UAX #15; CPython's nfd_nfkd / nfc_nfkc) ──────────────────
enum Form { NFC, NFKC, NFD, NFKD };
bool form_of(const std::string& name, Form& f);   // "NFC" ... false otherwise
std::vector<uint32_t> normalize(Form f, const std::vector<uint32_t>& s, bool ucd_3_2_0 = false);
bool is_normalized(Form f, const std::vector<uint32_t>& s, bool ucd_3_2_0 = false);
// the quick check of UAX #15 (CPython's is_normalized_quickcheck): 0 yes,
// 1 maybe, 2 no
int quickcheck(Form f, const std::vector<uint32_t>& s, bool yes_only);
// UTF-8 in and out (lone surrogates kept); NFKC of an identifier for the
// lexer (PEP 3131), the ASCII fast path first
std::string normalize_utf8(Form f, const std::string& s, bool ucd_3_2_0 = false);

// Nython's addition (UAX #15, section 13): the Stream-Safe Text Format -
// a COMBINING GRAPHEME JOINER (U+034F) inserted before the 31st of a run of
// non-starters, so that a normalizer can work in bounded buffers
std::vector<uint32_t> stream_safe(const std::vector<uint32_t>& s);

// ── names (with include/NyUniNames.hpp) ─────────────────────────────────────
// name aliases (NameAliases.txt): an upper-case name -> its code point
bool alias_lookup(const std::string& upper, uint32_t& cp);
// named sequences (NamedSequences.txt): unicodedata.lookup only, never \N{}
bool named_sequence_lookup(const std::string& upper, std::vector<uint32_t>& seq);

}  // namespace nyucd
