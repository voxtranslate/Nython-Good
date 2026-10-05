// builtins/nyre.cpp - the regular expression engine (include/NyRe.hpp) and
// the _re_* builtins lib/re.ny is written over (round 77).
//
//   1. Unicode            \w \d \s, case-insensitive classes (NyReTables.hpp)
//   2. Parser             CPython's Lib/re/_parser.py, ported line by line:
//                         the same syntax, error messages and positions
//   3. Compiler           syntax tree -> instruction program; analysis for
//                         memoization, the literal prefix, the first-
//                         character set and anchoring
//   4. Machine            the backtracking matcher (explicit stack)
//   5. Templates          re.sub replacement strings (_parser.parse_template)
//   6. Builtins           Value <-> engine; the VM reaches them through the
//                         builtin bridge (registered names, NythonExecutor.hpp)
//
// Selective memoization (Davis, Servant, Lee, IEEE S&P 2021)
// ----------------------------------------------------------
// A backtracking matcher is exponential when the same state - an instruction
// at a subject position - is reached along many paths and explored again
// each time ((a|a)*b, (x+x+)+y). Here the states that can be reached more
// than once are remembered when they FAIL: every instruction with two or more
// predecessors (loop heads, the ends of alternations: the in-degree > 1
// vertices of the paper) and the run
// states of single-character loops (x*, x+, x*?: entered at i, a loop at
// position j >= i is the same state whichever i it was entered at); a
// bounded one (x?, x{2,5}) remembers the states after it, one per count it
// tried, so (?:a?){30}a{30} is linear too. A memo point visited at (pc, pos)
// pushes a marker (a SPLIT's alternative turns into one once it is taken)
// that, when popped - everything after it exhausted - records (pc, pos) as
// failed. A later visit fails at once. Choice points removed by
// an atomic group or a lookaround (a cut) record nothing: only exhausted
// searches are recorded, so a memo entry never claims more than was proved.
//
// The rule holds while the future of a state depends only on (pc, pos):
//   * captures do not change whether a match exists unless something reads
//     them, so instructions from which a backreference or a (?(group)...)
//     conditional is reachable are not memoized (everything else in such a
//     pattern still is);
//   * a loop whose body can match empty must stop after an empty iteration
//     (sre's rule), which needs the position the iteration started at. That
//     register only matters through "has this iteration consumed anything
//     yet", so for each enclosing such loop (at most 3) one bit joins the key;
//   * counted loops too large to unroll ({1000,5000} of a group) keep a
//     counter: their bodies are not memoized (they are unrolled up to 2000
//     instructions, and single characters, x{2,9000}, never need one);
//   * a lookaround body's states mean "can reach the end of the lookaround",
//     independent of where it started; the bodies are separate contexts.
// The table is a bitset of (memo slots x (subject + 1)) bits, or a hash set
// when that would pass 16 MB, and it is shared by the successive searches of
// findall/finditer/sub/split (a later search starts further on and is at
// least as restricted, so a recorded failure stays a failure).
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyRe.hpp"
#include "NyReTables.hpp"
#include "NyStr.hpp"
#include "NyConc.hpp"
#include "builtins/os.hpp"
#include <algorithm>
#include <cstring>
#include <list>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace nyre {
namespace {

// ═══════════════════════════════════════════════════════════════════════
// 1. Unicode
// ═══════════════════════════════════════════════════════════════════════
template <size_t N>
bool in_table(const uint32_t (&t)[N][2], uint32_t c) {
    size_t lo = 0, hi = N;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (t[mid][1] < c) lo = mid + 1; else hi = mid;
    }
    return lo < N && t[lo][0] <= c;
}
template <size_t N>
uint32_t map_get(const uint32_t (&t)[N][2], uint32_t c) {
    size_t lo = 0, hi = N;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (t[mid][0] < c) lo = mid + 1; else hi = mid;
    }
    return (lo < N && t[lo][0] == c) ? t[lo][1] : c;
}

inline bool a_word(uint32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}
inline bool a_digit(uint32_t c) { return c >= '0' && c <= '9'; }
inline bool a_space(uint32_t c) { return c == ' ' || (c >= 9 && c <= 13); }
inline uint32_t a_lower(uint32_t c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
inline bool a_cased(uint32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

inline bool u_word(uint32_t c) { return c < 128 ? a_word(c) : in_table(nyre_tables::kWord, c); }
inline bool u_digit(uint32_t c) { return c < 128 ? a_digit(c) : in_table(nyre_tables::kDigit, c); }
inline bool u_space(uint32_t c) {
    return c < 128 ? (a_space(c) || (c >= 0x1C && c <= 0x1F)) : in_table(nyre_tables::kSpace, c);
}
inline uint32_t u_lower(uint32_t c) { return c < 128 ? a_lower(c) : map_get(nyre_tables::kLower, c); }
inline uint32_t u_canon(uint32_t c) { return c < 128 ? a_lower(c) : map_get(nyre_tables::kCanon, c); }
inline bool u_cased(uint32_t c) { return c < 128 ? a_cased(c) : in_table(nyre_tables::kCased, c); }
// The members of the case-insensitive class whose canon is k ([first, last)
// of kClass); empty when the class is k alone.
std::pair<size_t, size_t> class_of(uint32_t k) {
    const auto& t = nyre_tables::kClass;
    size_t n = sizeof(t) / sizeof(t[0]);
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (t[mid][0] < k) lo = mid + 1; else hi = mid;
    }
    size_t e = lo;
    while (e < n && t[e][0] == k) e++;
    return {lo, e};
}
bool is_identifier(const std::u32string& s) {
    if (s.empty()) return false;
    for (size_t i = 0; i < s.size(); i++) {
        uint32_t c = s[i];
        bool ok = i == 0 ? (c < 128 ? ((c | 32) >= 'a' && (c | 32) <= 'z') || c == '_' : in_table(nyre_tables::kIdStart, c))
                         : (c < 128 ? a_word(c) : in_table(nyre_tables::kIdCont, c));
        if (!ok) return false;
    }
    return true;
}

std::string utf8(const std::u32string& s) {
    std::string r;
    for (uint32_t c : s) nypy::u8_encode(c, r);
    return r;
}

// ═══════════════════════════════════════════════════════════════════════
// 2. Parser (Lib/re/_parser.py)
// ═══════════════════════════════════════════════════════════════════════
const uint64_t MAXREPEAT = 4294967295ull;     // _sre.MAXREPEAT
const uint64_t MAXWIDTH = UINT64_MAX;         // stands for 1 << 64
const uint64_t MAXCODE = 4294967295ull;
const int MAXGROUPS = 1073741823;
const int MAXDEPTH = 300;                     // nesting; Python's own limit is near there

enum AtCode : uint8_t {
    AT_BEGINNING, AT_BEGINNING_LINE, AT_BEGINNING_STRING, AT_BOUNDARY, AT_NON_BOUNDARY,
    AT_END, AT_END_LINE, AT_END_STRING
};
enum Cat : uint8_t { CAT_DIGIT, CAT_NOT_DIGIT, CAT_SPACE, CAT_NOT_SPACE, CAT_WORD, CAT_NOT_WORD };

struct Node;
using Seq = std::vector<Node>;
enum NK : uint8_t { K_LIT, K_NLIT, K_ANY, K_IN, K_AT, K_BRANCH, K_SUB, K_ATOMIC, K_REP, K_REF, K_REFEX, K_ASSERT, K_ASSERTNOT };
enum RepKind : uint8_t { R_GREEDY, R_LAZY, R_POSS };
struct SetItem {
    uint8_t kind;      // 0 literal, 1 range, 2 category
    uint32_t lo, hi;
};
struct Node {
    NK k = K_LIT;
    uint32_t c = 0;               // literal, AT code, group of REF/REFEX
    int group = -1, addf = 0, delf = 0, dir = 1;
    uint8_t rk = R_GREEDY;
    uint64_t mn = 0, mx = 0;
    bool negate = false, has_no = false;
    std::vector<SetItem> set{};
    std::vector<Seq> subs{};      // SUB/ATOMIC/REP/ASSERT: [body]; BRANCH: alternatives; REFEX: [yes, no]
};

struct Width { uint64_t lo, hi; };
inline uint64_t sadd(uint64_t a, uint64_t b) { return a > MAXWIDTH - b ? MAXWIDTH : a + b; }
inline uint64_t smul(uint64_t a, uint64_t b) {
    if (a == 0 || b == 0) return 0;
    return a > MAXWIDTH / b ? MAXWIDTH : a * b;
}

Width seq_width(const Seq& p, const std::vector<Width>& gw);
Width node_width(const Node& n, const std::vector<Width>& gw) {
    switch (n.k) {
    case K_BRANCH: {
        uint64_t i = MAXWIDTH, j = 0;
        for (auto& a : n.subs) { Width w = seq_width(a, gw); i = std::min(i, w.lo); j = std::max(j, w.hi); }
        return {i, j};
    }
    case K_ATOMIC: case K_SUB: return seq_width(n.subs[0], gw);
    case K_REP: {
        Width w = seq_width(n.subs[0], gw);
        uint64_t hi = (n.mx == MAXREPEAT && w.hi) ? MAXWIDTH : smul(w.hi, n.mx);
        return {smul(w.lo, n.mn), hi};
    }
    case K_LIT: case K_NLIT: case K_ANY: case K_IN: return {1, 1};
    case K_REF: return n.c < gw.size() ? gw[n.c] : Width{0, 0};
    case K_REFEX: {
        Width w = seq_width(n.subs[0], gw);
        if (n.has_no) { Width v = seq_width(n.subs[1], gw); w.lo = std::min(w.lo, v.lo); w.hi = std::max(w.hi, v.hi); }
        else w.lo = 0;
        return w;
    }
    default: return {0, 0};
    }
}
Width seq_width(const Seq& p, const std::vector<Width>& gw) {
    uint64_t lo = 0, hi = 0;
    for (auto& n : p) { Width w = node_width(n, gw); lo = sadd(lo, w.lo); hi = sadd(hi, w.hi); }
    return {lo, hi};
}

// A token: one character, or a backslash and the character after it.
struct Tok {
    bool none = true;
    uint32_t a = 0, b = 0;
    int len = 0;
    bool is(uint32_t c) const { return !none && len == 1 && a == c; }
    bool in(const char* set) const { return !none && len == 1 && a < 128 && a && std::strchr(set, (int)a); }
    std::u32string str() const {
        std::u32string r;
        if (none) return r;
        r += a;
        if (len == 2) r += b;
        return r;
    }
};

const char* DIGITS = "0123456789";
const char* OCTDIGITS = "01234567";
const char* HEXDIGITS = "0123456789abcdefABCDEF";
const char* WHITESPACE = " \t\n\r\v\f";
const char* SPECIAL_CHARS = ".\\[{()*+?^$|";
const char* REPEAT_CHARS = "*+?{";
inline bool ascii_letter(uint32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
inline bool in_set(uint32_t c, const char* set) { return c && c < 128 && std::strchr(set, (int)c); }

int flag_of(uint32_t c) {
    switch (c) {
    case 'i': return F_IGNORECASE; case 'L': return F_LOCALE; case 'm': return F_MULTILINE;
    case 's': return F_DOTALL; case 'x': return F_VERBOSE; case 'a': return F_ASCII;
    case 't': return F_TEMPLATE; case 'u': return F_UNICODE;
    default: return 0;
    }
}
const int TYPE_FLAGS = F_ASCII | F_LOCALE | F_UNICODE;
const int GLOBAL_FLAGS = F_DEBUG | F_TEMPLATE;

std::string fmt_u(uint64_t v) { return std::to_string(v); }

class Parser {
public:
    const std::vector<uint32_t>& s;
    bool istext;
    size_t index = 0;
    Tok next{};
    // state
    int flags = 0;
    std::vector<std::pair<std::u32string, int>> groupdict{};   // in definition order
    std::vector<Width> groupwidths{Width{0, 0}};
    std::vector<bool> groupclosed{true};
    int lookbehindgroups = -1;
    std::vector<std::pair<int, int64_t>> grouprefpos{};
    int depth = 0;

    Parser(const std::vector<uint32_t>& p, bool text) : s(p), istext(text) { advance(); }

    // ── the tokenizer ──
    void advance() {
        if (index >= s.size()) { next = Tok(); return; }
        uint32_t ch = s[index];
        if (ch == '\\') {
            if (index + 1 >= s.size()) throw Error{"bad escape (end of pattern)", (int64_t)s.size() - 1};
            next.none = false; next.a = '\\'; next.b = s[index + 1]; next.len = 2;
            index += 2;
        } else {
            next.none = false; next.a = ch; next.b = 0; next.len = 1;
            index += 1;
        }
    }
    bool match(uint32_t c) { if (next.is(c)) { advance(); return true; } return false; }
    Tok get() { Tok t = next; advance(); return t; }
    int64_t tell() const { return (int64_t)index - (next.none ? 0 : next.len); }
    void seek(size_t i) { index = i; advance(); }
    Error error(const std::string& msg, int64_t offset = 0) const { return Error{msg, tell() - offset}; }
    std::u32string getwhile(int n, const char* set) {
        std::u32string r;
        for (int i = 0; i < n; i++) {
            if (!next.in(set)) break;
            r += next.a;
            advance();
        }
        return r;
    }
    std::u32string getuntil(uint32_t term, const char* name) {
        std::u32string r;
        for (;;) {
            Tok c = next;
            advance();
            if (c.none) {
                if (r.empty()) throw error(std::string("missing ") + name);
                throw error(std::string("missing ") + (char)term + ", unterminated name", (int64_t)r.size());
            }
            if (c.is(term)) {
                if (r.empty()) throw error(std::string("missing ") + name, 1);
                break;
            }
            std::u32string cs = c.str();
            r += cs;
        }
        return r;
    }
    void checkgroupname(const std::u32string& name, int64_t offset) {
        bool ascii = true;
        for (uint32_t c : name) if (c >= 128) ascii = false;
        if (!(istext || ascii))
            throw error("bad character in group name " + nypy::str_repr(utf8(name), true), (int64_t)name.size() + offset);
        if (!is_identifier(name))
            throw error("bad character in group name " + nypy::str_repr(utf8(name)), (int64_t)name.size() + offset);
    }

    // ── state ──
    int groups() const { return (int)groupwidths.size(); }
    int lookup_group(const std::u32string& name) const {
        for (auto& g : groupdict) if (g.first == name) return g.second;
        return -1;
    }
    bool checkgroup(int gid) const { return gid < groups() && groupclosed[gid]; }
    void checklookbehindgroup(int gid) {
        if (lookbehindgroups >= 0) {
            if (!checkgroup(gid)) throw error("cannot refer to an open group");
            if (gid >= lookbehindgroups) throw error("cannot refer to group defined in the same lookbehind subpattern");
        }
    }

    static bool all_ascii_digits(const std::u32string& n) {
        if (n.empty()) return false;
        for (uint32_t c : n) if (!(c >= '0' && c <= '9')) return false;
        return true;
    }
    static uint64_t to_int(const std::u32string& n) {     // saturating
        uint64_t v = 0;
        for (uint32_t c : n) { v = v * 10 + (c - '0'); if (v > (1ull << 40)) return 1ull << 40; }
        return v;
    }

    // ── escapes ──
    Node lit(uint32_t c) { Node n; n.k = K_LIT; n.c = c; return n; }
    Node cat_node(Cat c) { Node n; n.k = K_IN; n.set.push_back({2, (uint32_t)c, 0}); return n; }
    bool category(uint32_t c, Node& out) {
        switch (c) {
        case 'd': out = cat_node(CAT_DIGIT); return true;
        case 'D': out = cat_node(CAT_NOT_DIGIT); return true;
        case 's': out = cat_node(CAT_SPACE); return true;
        case 'S': out = cat_node(CAT_NOT_SPACE); return true;
        case 'w': out = cat_node(CAT_WORD); return true;
        case 'W': out = cat_node(CAT_NOT_WORD); return true;
        default: return false;
        }
    }
    static bool simple_escape(uint32_t c, uint32_t& v) {
        switch (c) {
        case 'a': v = 7; return true; case 'b': v = 8; return true; case 'f': v = 12; return true;
        case 'n': v = 10; return true; case 'r': v = 13; return true; case 't': v = 9; return true;
        case 'v': v = 11; return true; case '\\': v = '\\'; return true;
        default: return false;
        }
    }
    static uint32_t hexval(const std::u32string& h) {
        uint32_t v = 0;
        for (uint32_t c : h) v = v * 16 + (c <= '9' ? c - '0' : (c | 32) - 'a' + 10);
        return v;
    }
    // Shared by _escape and _class_escape: \x \u \U \N. Returns false when c is none of them.
    bool unicode_escape(std::u32string& escape, uint32_t c, uint32_t& v) {
        if (c == 'x') {
            escape += getwhile(2, HEXDIGITS);
            if (escape.size() != 4) throw error("incomplete escape " + utf8(escape), (int64_t)escape.size());
            v = hexval(escape.substr(2));
            return true;
        }
        if (c == 'u' && istext) {
            escape += getwhile(4, HEXDIGITS);
            if (escape.size() != 6) throw error("incomplete escape " + utf8(escape), (int64_t)escape.size());
            v = hexval(escape.substr(2));
            return true;
        }
        if (c == 'U' && istext) {
            escape += getwhile(8, HEXDIGITS);
            if (escape.size() != 10) throw error("incomplete escape " + utf8(escape), (int64_t)escape.size());
            uint64_t w = 0;
            for (uint32_t d : escape.substr(2)) w = w * 16 + (d <= '9' ? d - '0' : (d | 32) - 'a' + 10);
            if (w > 0x10FFFF) throw error("bad escape " + utf8(escape), (int64_t)escape.size());
            v = (uint32_t)w;
            return true;
        }
        if (c == 'N' && istext) {
            if (!match('{')) throw error("missing {");
            std::u32string name = getuntil('}', "character name");
            throw error("undefined character name " + nypy::str_repr(utf8(name)) +
                        " (named Unicode escapes are not supported)", (int64_t)name.size() + 4);
        }
        return false;
    }
    // _class_escape: a member of a [...] set: a literal or a category.
    SetItem class_escape(const Tok& t) {
        uint32_t c = t.b, v;
        if (simple_escape(c, v)) return {0, v, 0};
        Node cn;
        if (category(c, cn)) return cn.set[0];
        std::u32string escape = t.str();
        if (unicode_escape(escape, c, v)) return {0, v, 0};
        if (in_set(c, OCTDIGITS)) {
            escape += getwhile(2, OCTDIGITS);
            uint32_t o = 0;
            for (size_t i = 1; i < escape.size(); i++) o = o * 8 + (escape[i] - '0');
            if (o > 0377)
                throw error("octal escape value " + utf8(escape) + " outside of range 0-0o377", (int64_t)escape.size());
            return {0, o, 0};
        }
        if (in_set(c, DIGITS) || ascii_letter(c)) throw error("bad escape " + utf8(escape), (int64_t)escape.size());
        return {0, c, 0};
    }
    // _escape: an escape outside a set.
    Node escape_node(const Tok& t) {
        uint32_t c = t.b, v;
        Node n;
        switch (c) {
        case 'A': n.k = K_AT; n.c = AT_BEGINNING_STRING; return n;
        case 'b': n.k = K_AT; n.c = AT_BOUNDARY; return n;
        case 'B': n.k = K_AT; n.c = AT_NON_BOUNDARY; return n;
        case 'Z': n.k = K_AT; n.c = AT_END_STRING; return n;
        default: break;
        }
        if (category(c, n)) return n;
        if (simple_escape(c, v)) return lit(v);
        std::u32string escape = t.str();
        if (unicode_escape(escape, c, v)) return lit(v);
        if (c == '0') {
            escape += getwhile(2, OCTDIGITS);
            uint32_t o = 0;
            for (size_t i = 1; i < escape.size(); i++) o = o * 8 + (escape[i] - '0');
            return lit(o);
        }
        if (in_set(c, DIGITS)) {
            // octal escape *or* decimal group reference (sigh)
            if (next.in(DIGITS)) {
                escape += get().a;
                if (in_set(escape[1], OCTDIGITS) && in_set(escape[2], OCTDIGITS) && next.in(OCTDIGITS)) {
                    escape += get().a;
                    uint32_t o = (escape[1] - '0') * 64 + (escape[2] - '0') * 8 + (escape[3] - '0');
                    if (o > 0377)
                        throw error("octal escape value " + utf8(escape) + " outside of range 0-0o377", (int64_t)escape.size());
                    return lit(o);
                }
            }
            int group = 0;
            for (size_t i = 1; i < escape.size(); i++) group = group * 10 + (int)(escape[i] - '0');
            if (group < groups()) {
                if (!checkgroup(group)) throw error("cannot refer to an open group", (int64_t)escape.size());
                checklookbehindgroup(group);
                n.k = K_REF; n.c = (uint32_t)group;
                return n;
            }
            throw error("invalid group reference " + std::to_string(group), (int64_t)escape.size() - 1);
        }
        if (ascii_letter(c)) throw error("bad escape " + utf8(escape), (int64_t)escape.size());
        return lit(c);
    }

    // ── _parse_sub / _parse ──
    Seq parse_sub(bool verbose, int nested) {
        std::vector<Seq> items;
        for (;;) {
            items.push_back(parse(verbose, nested + 1, !nested && items.empty()));
            if (!match('|')) break;
        }
        if (items.size() == 1) return std::move(items[0]);
        Seq r;
        // As _parse_sub does: move a common prefix out of the branch (sre
        // compares the nodes as tuples, so only single-character and zero-
        // width ones are ever equal - for those the order of the search is
        // unchanged), and turn a branch of single characters into a set.
        for (;;) {
            bool same = true;
            for (auto& it : items)
                if (it.empty() || !simple_equal(it[0], items[0][0])) { same = false; break; }
            if (!same) break;
            r.push_back(items[0][0]);
            for (auto& it : items) it.erase(it.begin());
        }
        std::vector<SetItem> set;
        bool chars = true;
        for (auto& it : items) {
            if (it.size() != 1) { chars = false; break; }
            const Node& n = it[0];
            if (n.k == K_LIT) set.push_back({0, n.c, 0});
            else if (n.k == K_IN && !n.negate) set.insert(set.end(), n.set.begin(), n.set.end());
            else { chars = false; break; }
        }
        if (chars) {
            Node n;
            n.k = K_IN;
            for (auto& x : set) {
                bool dup = false;
                for (auto& y : n.set) if (x.kind == y.kind && x.lo == y.lo && x.hi == y.hi) { dup = true; break; }
                if (!dup) n.set.push_back(x);
            }
            r.push_back(std::move(n));
            return r;
        }
        Node b;
        b.k = K_BRANCH;
        b.subs = std::move(items);
        r.push_back(std::move(b));
        return r;
    }
    static bool simple_equal(const Node& a, const Node& b) {
        if (a.k != b.k) return false;
        switch (a.k) {
        case K_LIT: case K_NLIT: case K_AT: case K_REF: return a.c == b.c;
        case K_ANY: return true;
        case K_IN:
            if (a.negate != b.negate || a.set.size() != b.set.size()) return false;
            for (size_t i = 0; i < a.set.size(); i++)
                if (a.set[i].kind != b.set[i].kind || a.set[i].lo != b.set[i].lo || a.set[i].hi != b.set[i].hi) return false;
            return true;
        default: return false;
        }
    }

    void parse_flags(Tok chr, int& add_flags, int& del_flags, bool& global) {
        uint32_t ch = chr.len == 1 ? chr.a : 0;
        add_flags = del_flags = 0;
        global = false;
        if (!chr.is('-')) {
            for (;;) {
                int flag = flag_of(ch);
                if (istext) {
                    if (ch == 'L') throw error("bad inline flags: cannot use 'L' flag with a str pattern");
                } else {
                    if (ch == 'u') throw error("bad inline flags: cannot use 'u' flag with a bytes pattern");
                }
                add_flags |= flag;
                if ((flag & TYPE_FLAGS) && (add_flags & TYPE_FLAGS) != flag)
                    throw error("bad inline flags: flags 'a', 'u' and 'L' are incompatible");
                chr = get();
                if (chr.none) throw error("missing -, : or )");
                if (chr.is(')') || chr.is('-') || chr.is(':')) break;
                ch = chr.len == 1 ? chr.a : 0;
                if (!flag_of(ch) || chr.len != 1) {
                    bool alpha = chr.len == 1 && (ascii_letter(chr.a) || (chr.a >= 128 && in_table(nyre_tables::kIdStart, chr.a)));
                    throw error(alpha ? "unknown flag" : "missing -, : or )", chr.len);
                }
            }
        }
        if (chr.is(')')) {
            flags |= add_flags;
            global = true;
            return;
        }
        if (add_flags & GLOBAL_FLAGS) throw error("bad inline flags: cannot turn on global flag", 1);
        if (chr.is('-')) {
            chr = get();
            if (chr.none) throw error("missing flag");
            if (chr.len != 1 || !flag_of(chr.a)) {
                bool alpha = chr.len == 1 && (ascii_letter(chr.a) || (chr.a >= 128 && in_table(nyre_tables::kIdStart, chr.a)));
                throw error(alpha ? "unknown flag" : "missing flag", chr.len);
            }
            for (;;) {
                int flag = flag_of(chr.a);
                if (flag & TYPE_FLAGS) throw error("bad inline flags: cannot turn off flags 'a', 'u' and 'L'");
                del_flags |= flag;
                chr = get();
                if (chr.none) throw error("missing :");
                if (chr.is(':')) break;
                if (chr.len != 1 || !flag_of(chr.a)) {
                    bool alpha = chr.len == 1 && (ascii_letter(chr.a) || (chr.a >= 128 && in_table(nyre_tables::kIdStart, chr.a)));
                    throw error(alpha ? "unknown flag" : "missing :", chr.len);
                }
            }
        }
        if (del_flags & GLOBAL_FLAGS) throw error("bad inline flags: cannot turn off global flag", 1);
        if (add_flags & del_flags) throw error("bad inline flags: flag turned on and off", 1);
    }

    struct DepthGuard {
        int& d;
        explicit DepthGuard(int& x) : d(x) {
            if (++d > MAXDEPTH) { --d; throw PyErr{"RecursionError", "maximum recursion depth exceeded"}; }
        }
        ~DepthGuard() { --d; }
    };

    Seq parse(bool verbose, int nested, bool first) {
        DepthGuard guard(depth);
        Seq sub;
        for (;;) {
            Tok t = next;
            if (t.none) break;
            if (t.is('|') || t.is(')')) break;
            advance();
            if (verbose) {
                if (t.in(WHITESPACE)) continue;
                if (t.is('#')) {
                    for (;;) {
                        Tok c = get();
                        if (c.none || c.is('\n')) break;
                    }
                    continue;
                }
            }
            if (t.len == 2) {
                sub.push_back(escape_node(t));
            } else if (!in_set(t.a, SPECIAL_CHARS)) {
                sub.push_back(lit(t.a));
            } else if (t.a == '[') {
                int64_t here = tell() - 1;
                std::vector<SetItem> set;
                bool negate = match('^');
                for (;;) {
                    Tok th = get();
                    if (th.none) throw error("unterminated character set", tell() - here);
                    SetItem code1;
                    if (th.is(']') && !set.empty()) break;
                    else if (th.len == 2) code1 = class_escape(th);
                    else code1 = {0, th.a, 0};
                    if (match('-')) {
                        Tok that = get();
                        if (that.none) throw error("unterminated character set", tell() - here);
                        if (that.is(']')) {
                            set.push_back(code1);
                            set.push_back({0, '-', 0});
                            break;
                        }
                        SetItem code2;
                        if (that.len == 2) code2 = class_escape(that);
                        else code2 = {0, that.a, 0};
                        if (code1.kind != 0 || code2.kind != 0 || code2.lo < code1.lo) {
                            std::string msg = "bad character range " + utf8(th.str()) + "-" + utf8(that.str());
                            throw error(msg, (int64_t)th.len + 1 + that.len);
                        }
                        set.push_back({1, code1.lo, code2.lo});
                    } else {
                        set.push_back(code1);
                    }
                }
                // _uniq
                std::vector<SetItem> u;
                for (auto& it : set) {
                    bool dup = false;
                    for (auto& x : u) if (x.kind == it.kind && x.lo == it.lo && x.hi == it.hi) { dup = true; break; }
                    if (!dup) u.push_back(it);
                }
                Node n;
                if (u.size() == 1 && u[0].kind == 0) {
                    n.k = negate ? K_NLIT : K_LIT;
                    n.c = u[0].lo;
                } else {
                    n.k = K_IN;
                    n.negate = negate;
                    n.set = std::move(u);
                }
                sub.push_back(std::move(n));
            } else if (in_set(t.a, REPEAT_CHARS)) {
                int64_t here = tell();
                uint64_t mn = 0, mx = MAXREPEAT;
                if (t.a == '?') { mn = 0; mx = 1; }
                else if (t.a == '*') { mn = 0; mx = MAXREPEAT; }
                else if (t.a == '+') { mn = 1; mx = MAXREPEAT; }
                else {   // '{'
                    if (next.is('}')) { sub.push_back(lit('{')); continue; }
                    std::u32string lo, hi;
                    while (next.in(DIGITS)) lo += get().a;
                    if (match(',')) { while (next.in(DIGITS)) hi += get().a; }
                    else hi = lo;
                    if (!match('}')) {
                        sub.push_back(lit('{'));
                        seek((size_t)here);
                        continue;
                    }
                    if (!lo.empty()) {
                        mn = to_int(lo);
                        if (mn >= MAXREPEAT) throw PyErr{"OverflowError", "the repetition number is too large"};
                    }
                    if (!hi.empty()) {
                        mx = to_int(hi);
                        if (mx >= MAXREPEAT) throw PyErr{"OverflowError", "the repetition number is too large"};
                        if (mx < mn) throw error("min repeat greater than max repeat", tell() - here);
                    }
                }
                if (sub.empty() || sub.back().k == K_AT)
                    throw error("nothing to repeat", tell() - here + 1);
                if (sub.back().k == K_REP)
                    throw error("multiple repeat", tell() - here + 1);
                Node item = std::move(sub.back());
                sub.pop_back();
                Node r;
                r.k = K_REP;
                r.mn = mn;
                r.mx = mx;
                if (item.k == K_SUB && item.group < 0 && !item.addf && !item.delf)
                    r.subs.push_back(std::move(item.subs[0]));
                else {
                    Seq one;
                    one.push_back(std::move(item));
                    r.subs.push_back(std::move(one));
                }
                if (match('?')) r.rk = R_LAZY;
                else if (match('+')) r.rk = R_POSS;
                else r.rk = R_GREEDY;
                sub.push_back(std::move(r));
            } else if (t.a == '.') {
                Node n; n.k = K_ANY; sub.push_back(n);
            } else if (t.a == '(') {
                int64_t start = tell() - 1;
                bool capture = true, atomic = false;
                bool has_name = false;
                std::u32string name;
                int add_flags = 0, del_flags = 0;
                if (match('?')) {
                    Tok chr = get();
                    if (chr.none) throw error("unexpected end of pattern");
                    if (chr.is('P')) {
                        if (match('<')) {
                            name = getuntil('>', "group name");
                            checkgroupname(name, 1);
                            has_name = true;
                        } else if (match('=')) {
                            name = getuntil(')', "group name");
                            checkgroupname(name, 1);
                            int gid = lookup_group(name);
                            if (gid < 0)
                                throw error("unknown group name " + nypy::str_repr(utf8(name)), (int64_t)name.size() + 1);
                            if (!checkgroup(gid)) throw error("cannot refer to an open group", (int64_t)name.size() + 1);
                            checklookbehindgroup(gid);
                            Node n; n.k = K_REF; n.c = (uint32_t)gid;
                            sub.push_back(n);
                            continue;
                        } else {
                            Tok c2 = get();
                            if (c2.none) throw error("unexpected end of pattern");
                            throw error("unknown extension ?P" + utf8(c2.str()), (int64_t)c2.len + 2);
                        }
                    } else if (chr.is(':')) {
                        capture = false;
                    } else if (chr.is('#')) {
                        for (;;) {
                            if (next.none) throw error("missing ), unterminated comment", tell() - start);
                            if (get().is(')')) break;
                        }
                        continue;
                    } else if (chr.is('=') || chr.is('!') || chr.is('<')) {
                        int dir = 1;
                        int saved_lbg = -2;
                        if (chr.is('<')) {
                            chr = get();
                            if (chr.none) throw error("unexpected end of pattern");
                            if (!(chr.is('=') || chr.is('!')))
                                throw error("unknown extension ?<" + utf8(chr.str()), (int64_t)chr.len + 2);
                            dir = -1;
                            saved_lbg = lookbehindgroups;
                            if (lookbehindgroups < 0) lookbehindgroups = groups();
                        }
                        Seq p = parse_sub(verbose, nested + 1);
                        if (dir < 0 && saved_lbg < 0) lookbehindgroups = -1;
                        if (!match(')')) throw error("missing ), unterminated subpattern", tell() - start);
                        Node n;
                        n.k = chr.is('=') ? K_ASSERT : K_ASSERTNOT;
                        n.dir = dir;
                        n.subs.push_back(std::move(p));
                        sub.push_back(std::move(n));
                        continue;
                    } else if (chr.is('(')) {
                        std::u32string condname = getuntil(')', "group name");
                        int condgroup;
                        if (!all_ascii_digits(condname)) {
                            checkgroupname(condname, 1);
                            condgroup = lookup_group(condname);
                            if (condgroup < 0)
                                throw error("unknown group name " + nypy::str_repr(utf8(condname)), (int64_t)condname.size() + 1);
                        } else {
                            uint64_t g = to_int(condname);
                            if (!g) throw error("bad group number", (int64_t)condname.size() + 1);
                            if (g >= (uint64_t)MAXGROUPS)
                                throw error("invalid group reference " + fmt_u(g), (int64_t)condname.size() + 1);
                            condgroup = (int)g;
                            bool seen = false;
                            for (auto& gp : grouprefpos) if (gp.first == condgroup) seen = true;
                            if (!seen) grouprefpos.push_back({condgroup, tell() - (int64_t)condname.size() - 1});
                        }
                        checklookbehindgroup(condgroup);
                        Seq yes = parse(verbose, nested + 1, false);
                        Seq no;
                        bool has_no = false;
                        if (match('|')) {
                            no = parse(verbose, nested + 1, false);
                            has_no = true;
                            if (next.is('|')) throw error("conditional backref with more than two branches");
                        }
                        if (!match(')')) throw error("missing ), unterminated subpattern", tell() - start);
                        Node n;
                        n.k = K_REFEX;
                        n.c = (uint32_t)condgroup;
                        n.has_no = has_no;
                        n.subs.push_back(std::move(yes));
                        n.subs.push_back(std::move(no));
                        sub.push_back(std::move(n));
                        continue;
                    } else if (chr.is('>')) {
                        capture = false;
                        atomic = true;
                    } else if ((chr.len == 1 && flag_of(chr.a)) || chr.is('-')) {
                        bool global;
                        parse_flags(chr, add_flags, del_flags, global);
                        if (global) {
                            if (!first || !sub.empty())
                                throw error("global flags not at the start of the expression", tell() - start);
                            verbose = (flags & F_VERBOSE) != 0;
                            continue;
                        }
                        capture = false;
                    } else {
                        throw error("unknown extension ?" + utf8(chr.str()), (int64_t)chr.len + 1);
                    }
                }
                int group = -1;
                if (capture) {
                    group = groups();
                    groupwidths.push_back(Width{0, 0});
                    groupclosed.push_back(false);
                    if (groups() > MAXGROUPS) throw error("too many groups", has_name ? (int64_t)name.size() + 1 : 0);
                    if (has_name) {
                        int ogid = lookup_group(name);
                        if (ogid >= 0)
                            throw error("redefinition of group name " + nypy::str_repr(utf8(name)) + " as group " +
                                        std::to_string(group) + "; was group " + std::to_string(ogid),
                                        (int64_t)name.size() + 1);
                        groupdict.push_back({name, group});
                    }
                }
                bool sub_verbose = (verbose || (add_flags & F_VERBOSE)) && !(del_flags & F_VERBOSE);
                Seq p = parse_sub(sub_verbose, nested + 1);
                if (!match(')')) throw error("missing ), unterminated subpattern", tell() - start);
                if (group >= 0) {
                    groupwidths[group] = seq_width(p, groupwidths);
                    groupclosed[group] = true;
                }
                Node n;
                if (atomic) {
                    n.k = K_ATOMIC;
                } else {
                    n.k = K_SUB;
                    n.group = group;
                    n.addf = add_flags;
                    n.delf = del_flags;
                }
                n.subs.push_back(std::move(p));
                sub.push_back(std::move(n));
            } else if (t.a == '^') {
                Node n; n.k = K_AT; n.c = AT_BEGINNING; sub.push_back(n);
            } else if (t.a == '$') {
                Node n; n.k = K_AT; n.c = AT_END; sub.push_back(n);
            }
        }
        // unpack non-capturing groups
        Seq out;
        out.reserve(sub.size());
        for (auto& n : sub) {
            if (n.k == K_SUB && n.group < 0 && !n.addf && !n.delf) {
                for (auto& m : n.subs[0]) out.push_back(std::move(m));
            } else {
                out.push_back(std::move(n));
            }
        }
        return out;
    }

    Seq parse_all() {
        Seq p = parse_sub((flags & F_VERBOSE) != 0, 0);
        // fix_flags
        if (istext) {
            if (flags & F_LOCALE) throw PyErr{"ValueError", "cannot use LOCALE flag with a str pattern"};
            if (!(flags & F_ASCII)) flags |= F_UNICODE;
            else if (flags & F_UNICODE) throw PyErr{"ValueError", "ASCII and UNICODE flags are incompatible"};
        } else {
            if (flags & F_UNICODE) throw PyErr{"ValueError", "cannot use UNICODE flag with a bytes pattern"};
            if ((flags & F_LOCALE) && (flags & F_ASCII)) throw PyErr{"ValueError", "ASCII and LOCALE flags are incompatible"};
        }
        if (!next.none) throw error("unbalanced parenthesis");
        for (auto& g : grouprefpos)
            if (g.first >= groups()) throw Error{"invalid group reference " + std::to_string(g.first), g.second};
        return p;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// 3. Compiler
// ═══════════════════════════════════════════════════════════════════════
enum Op : uint8_t {
    O_ONE, O_AT, O_SAVE, O_SPLIT, O_JMP, O_REP1, O_PROG_SET, O_PROG_MARK, O_PROG_CHECK,
    O_CNT_INIT, O_CNT_HEAD, O_BACKREF, O_GROUPEX, O_LOOK, O_LOOK_END, O_ATOMIC, O_ATOMIC_END, O_MATCH
};
// single-character tests (O_ONE, O_REP1)
enum AtomKind : uint8_t { A_CHAR, A_CHAR_UI, A_CHAR_AI, A_NCHAR, A_NCHAR_UI, A_NCHAR_AI, A_ANY, A_ANYALL, A_SET };
const int64_t INF = -1;

struct CharSet {
    bool negate = false;
    uint8_t icase = 0;              // 0 exact, 1 ASCII, 2 Unicode
    bool ucat = false;              // categories: Unicode or ASCII
    std::vector<std::pair<uint32_t, uint32_t>> ranges{};  // sorted, merged
    uint32_t cats = 0;              // 1 << Cat
    uint64_t bm[4] = {0, 0, 0, 0};  // the whole answer below 256

    bool cat(uint32_t c) const {
        if (!cats) return false;
        for (int k = 0; k < 6; k++) {
            if (!(cats & (1u << k))) continue;
            bool r;
            switch (k) {
            case CAT_DIGIT: r = ucat ? u_digit(c) : a_digit(c); break;
            case CAT_NOT_DIGIT: r = !(ucat ? u_digit(c) : a_digit(c)); break;
            case CAT_SPACE: r = ucat ? u_space(c) : a_space(c); break;
            case CAT_NOT_SPACE: r = !(ucat ? u_space(c) : a_space(c)); break;
            case CAT_WORD: r = ucat ? u_word(c) : a_word(c); break;
            default: r = !(ucat ? u_word(c) : a_word(c)); break;
            }
            if (r) return true;
        }
        return false;
    }
    bool raw(uint32_t c) const {
        size_t lo = 0, hi = ranges.size();
        while (lo < hi) {
            size_t mid = (lo + hi) / 2;
            if (ranges[mid].second < c) lo = mid + 1; else hi = mid;
        }
        if (lo < ranges.size() && ranges[lo].first <= c) return true;
        return cat(c);
    }
    bool slow(uint32_t c) const {
        bool in = raw(c);
        if (!in && icase == 1) {
            if (a_cased(c)) in = raw(c ^ 32);
        } else if (!in && icase == 2) {
            auto r = class_of(u_canon(c));
            for (size_t i = r.first; i < r.second && !in; i++) {
                uint32_t y = nyre_tables::kClass[i][1];
                if (y != c && raw(y)) in = true;
            }
        }
        return in != negate;
    }
    bool test(uint32_t c) const {
        if (c < 256) return (bm[c >> 6] >> (c & 63)) & 1;
        return slow(c);
    }
    void finish() {
        std::sort(ranges.begin(), ranges.end());
        std::vector<std::pair<uint32_t, uint32_t>> m;
        for (auto& r : ranges) {
            if (!m.empty() && r.first <= m.back().second + 1) m.back().second = std::max(m.back().second, r.second);
            else m.push_back(r);
        }
        ranges = std::move(m);
        for (uint32_t c = 0; c < 256; c++)
            if (slow(c)) bm[c >> 6] |= 1ull << (c & 63);
    }
};

struct Inst {
    Op op = O_MATCH;
    uint8_t ak = 0;          // atom kind / AT code / look kind / backref case mode
    uint8_t rk = 0;          // REP1 and CNT_HEAD: R_GREEDY, R_LAZY, R_POSS
    uint8_t nregs = 0;       // progress registers in the memo key (SPLIT)
    int32_t a = 0, b = 0, c = 0;
    uint32_t ch = 0;         // atom character
    int32_t set = -1;        // atom set
    int64_t mn = 0, mx = 0;  // REP1 / CNT_HEAD bounds (INF: unbounded)
    int64_t memo = -1;       // memo slot base (SPLIT, REP1 run states)
    int32_t regs[3] = {0, 0, 0};
};

} // namespace

struct Program {
    std::vector<Inst> code{};
    std::vector<CharSet> sets{};
    int ncaps = 2;
    int nregs = 0;
    int64_t memo_slots = 0;
    bool anchored = false;
    std::vector<uint32_t> prefix{};
    bool has_first = false;
    uint64_t first_bm[4] = {0, 0, 0, 0};
    std::vector<int32_t> first_atoms{};  // O_ONE/O_REP1 instructions, for characters >= 256
};

namespace {

inline bool atom_test(const Program& P, const Inst& I, uint32_t c) {
    switch (I.ak) {
    case A_CHAR: return c == I.ch;
    case A_CHAR_UI: return u_canon(c) == I.ch;
    case A_CHAR_AI: return a_lower(c) == I.ch;
    case A_NCHAR: return c != I.ch;
    case A_NCHAR_UI: return u_canon(c) != I.ch;
    case A_NCHAR_AI: return a_lower(c) != I.ch;
    case A_ANY: return c != '\n';
    case A_ANYALL: return true;
    default: return P.sets[I.set].test(c);
    }
}

int combine_flags(int flags, int add, int del) {
    if (add & TYPE_FLAGS) flags &= ~TYPE_FLAGS;
    return (flags | add) & ~del;
}

const int64_t EXPAND_LIMIT = 2000;       // instructions one unrolled repeat may take

struct Compiler {
    Program& P;
    const std::vector<Width>& gw;
    std::vector<int32_t> progstack{};    // active progress registers, innermost last
    int nomemo = 0;                      // > 0 inside a counted loop
    std::vector<uint8_t> inst_nomemo{};
    int depth = 0;

    Compiler(Program& p, const std::vector<Width>& g) : P(p), gw(g) {}

    int emit(const Inst& i) {
        Inst x = i;
        {
            // the progress registers this instruction's future reads
            size_t k = progstack.size();
            if (k > 3) x.nregs = 4;      // too many: no memo
            else {
                x.nregs = (uint8_t)k;
                for (size_t j = 0; j < k; j++) x.regs[j] = progstack[k - 1 - j];
            }
        }
        P.code.push_back(x);
        inst_nomemo.push_back(nomemo > 0);
        return (int)P.code.size() - 1;
    }
    int here() const { return (int)P.code.size(); }
    int newreg() { return P.nregs++; }

    static bool unicode_mode(int flags) { return (flags & F_UNICODE) && !(flags & F_ASCII); }

    Inst atom_for(const Node& n, int flags) {
        Inst I;
        I.op = O_ONE;
        bool icase = (flags & F_IGNORECASE) && !(flags & F_LOCALE);
        bool uni = unicode_mode(flags);
        if (n.k == K_LIT || n.k == K_NLIT) {
            bool neg = n.k == K_NLIT;
            if (icase && uni && u_cased(n.c)) { I.ak = neg ? A_NCHAR_UI : A_CHAR_UI; I.ch = u_canon(n.c); }
            else if (icase && !uni && a_cased(n.c)) { I.ak = neg ? A_NCHAR_AI : A_CHAR_AI; I.ch = a_lower(n.c); }
            else if ((flags & F_IGNORECASE) && (flags & F_LOCALE) && a_cased(n.c)) { I.ak = neg ? A_NCHAR_AI : A_CHAR_AI; I.ch = a_lower(n.c); }
            else { I.ak = neg ? A_NCHAR : A_CHAR; I.ch = n.c; }
        } else if (n.k == K_ANY) {
            I.ak = (flags & F_DOTALL) ? A_ANYALL : A_ANY;
        } else {   // K_IN
            CharSet cs;
            cs.negate = n.negate;
            cs.icase = !(flags & F_IGNORECASE) ? 0 : (uni ? 2 : 1);
            cs.ucat = uni;
            for (auto& it : n.set) {
                if (it.kind == 0) cs.ranges.push_back({it.lo, it.lo});
                else if (it.kind == 1) cs.ranges.push_back({it.lo, it.hi});
                else cs.cats |= 1u << it.lo;
            }
            cs.finish();
            I.ak = A_SET;
            I.set = (int32_t)P.sets.size();
            P.sets.push_back(std::move(cs));
        }
        return I;
    }

    // sre's _simple: one single-character item, possibly inside non-capturing groups.
    static bool simple(const Seq& body, int flags, const Node*& atom, int& aflags) {
        if (body.size() != 1) return false;
        const Node& n = body[0];
        if (n.k == K_SUB) {
            if (n.group >= 0) return false;
            return simple(n.subs[0], combine_flags(flags, n.addf, n.delf), atom, aflags);
        }
        if (n.k == K_LIT || n.k == K_NLIT || n.k == K_ANY || n.k == K_IN) { atom = &n; aflags = flags; return true; }
        return false;
    }

    // Size estimate (instructions) of a sequence, saturating.
    static int64_t est(const Seq& s) {
        int64_t t = 0;
        for (auto& n : s) { t += est_node(n); if (t > (1 << 30)) return 1 << 30; }
        return t;
    }
    static int64_t est_node(const Node& n) {
        switch (n.k) {
        case K_BRANCH: { int64_t t = 0; for (auto& a : n.subs) t += est(a) + 2; return std::min<int64_t>(t, 1 << 30); }
        case K_SUB: return est(n.subs[0]) + 2;
        case K_ATOMIC: case K_ASSERT: case K_ASSERTNOT: return est(n.subs[0]) + 2;
        case K_REFEX: return est(n.subs[0]) + est(n.subs[1]) + 2;
        case K_REP: {
            const Node* a; int f;
            if (simple(n.subs[0], 0, a, f)) return 1;
            int64_t b = est(n.subs[0]) + 4;
            int64_t copies = n.mx == MAXREPEAT ? (int64_t)std::max<uint64_t>(n.mn, 1) : (int64_t)n.mx;
            if (b * copies > EXPAND_LIMIT) return b + 4;
            return std::min<int64_t>(b * copies + 4, 1 << 30);
        }
        default: return 1;
        }
    }

    void seq(const Seq& s, int flags) { for (auto& n : s) node(n, flags); }

    void body_once(const Seq& body, int flags, bool atomic_iter) {
        if (atomic_iter) {
            Inst a; a.op = O_ATOMIC; emit(a);
            seq(body, flags);
            Inst e; e.op = O_ATOMIC_END; emit(e);
        } else {
            seq(body, flags);
        }
    }
    void body_prog(const Seq& body, int flags, bool atomic_iter, int r) {
        progstack.push_back(r);
        body_once(body, flags, atomic_iter);
        progstack.pop_back();
    }
    // An empty-iteration check reads its own register: it joins the key.
    int prog_check(int r) {
        progstack.push_back(r);
        Inst ck; ck.op = O_PROG_CHECK; ck.a = r;
        int L = emit(ck);
        progstack.pop_back();
        return L;
    }
    int split(bool lazy, int body_pc, int exit_pc) {
        Inst s; s.op = O_SPLIT;
        if (lazy) { s.a = exit_pc; s.b = body_pc; } else { s.a = body_pc; s.b = exit_pc; }
        return emit(s);
    }
    void set_split_exit(int pc, int exit_pc, bool lazy) { if (lazy) P.code[pc].a = exit_pc; else P.code[pc].b = exit_pc; }
    void set_split_body(int pc, int body_pc, bool lazy) { if (lazy) P.code[pc].b = body_pc; else P.code[pc].a = body_pc; }

    void loop(const Seq& body, uint64_t mn, uint64_t mx, bool lazy, int flags, bool atomic_iter) {
        bool nullable = seq_width(body, gw).lo == 0;
        int64_t b = est(body) + (atomic_iter ? 2 : 0) + 4;
        bool inf = mx == MAXREPEAT;
        if (!inf && mx == 0) return;
        if (inf) {
            if (mn == 0) {
                if (!nullable) {
                    int L = split(lazy, 0, 0);
                    set_split_body(L, here(), lazy);
                    body_once(body, flags, atomic_iter);
                    Inst j; j.op = O_JMP; j.a = L; emit(j);
                    set_split_exit(L, here(), lazy);
                } else {
                    int r = newreg();
                    Inst ps; ps.op = O_PROG_SET; ps.a = r; emit(ps);
                    int L = prog_check(r);
                    int S = split(lazy, 0, 0);
                    Inst mk; mk.op = O_PROG_MARK; mk.a = r; int M = emit(mk);
                    set_split_body(S, M, lazy);
                    body_prog(body, flags, atomic_iter, r);
                    Inst j; j.op = O_JMP; j.a = L; emit(j);
                    P.code[L].b = here();
                    set_split_exit(S, here(), lazy);
                }
                return;
            }
            if ((int64_t)(mn - 1) * b > EXPAND_LIMIT) { counted(body, mn, mx, lazy, flags, atomic_iter); return; }
            for (uint64_t i = 0; i + 1 < mn; i++) body_once(body, flags, atomic_iter);
            if (!nullable) {
                int B = here();
                body_once(body, flags, atomic_iter);
                int S = split(lazy, B, 0);
                set_split_exit(S, here(), lazy);
            } else {
                int r = newreg();
                Inst ps; ps.op = O_PROG_SET; ps.a = r; emit(ps);
                Inst jb; jb.op = O_JMP; int J = emit(jb);
                int L = prog_check(r);
                int S = split(lazy, 0, 0);
                Inst mk; mk.op = O_PROG_MARK; mk.a = r; int M = emit(mk);
                set_split_body(S, M, lazy);
                P.code[J].a = here();
                body_prog(body, flags, atomic_iter, r);
                Inst j; j.op = O_JMP; j.a = L; emit(j);
                P.code[L].b = here();
                set_split_exit(S, here(), lazy);
            }
            return;
        }
        if ((int64_t)mx * b > EXPAND_LIMIT) { counted(body, mn, mx, lazy, flags, atomic_iter); return; }
        for (uint64_t i = 0; i < mn; i++) body_once(body, flags, atomic_iter);
        if (mx == mn) return;
        std::vector<int> exits_split, exits_check;
        int r = -1;
        if (nullable) { r = newreg(); Inst ps; ps.op = O_PROG_SET; ps.a = r; emit(ps); }
        for (uint64_t i = mn; i < mx; i++) {
            if (nullable) {
                exits_check.push_back(prog_check(r));
                int S = split(lazy, 0, 0);
                exits_split.push_back(S);
                Inst mk; mk.op = O_PROG_MARK; mk.a = r; int M = emit(mk);
                set_split_body(S, M, lazy);
                body_prog(body, flags, atomic_iter, r);
            } else {
                int S = split(lazy, 0, 0);
                exits_split.push_back(S);
                set_split_body(S, here(), lazy);
                body_once(body, flags, atomic_iter);
            }
        }
        int X = here();
        for (int pc : exits_split) set_split_exit(pc, X, lazy);
        for (int pc : exits_check) P.code[pc].b = X;
    }

    void counted(const Seq& body, uint64_t mn, uint64_t mx, bool lazy, int flags, bool atomic_iter) {
        int c = newreg(), r = newreg();
        Inst ci; ci.op = O_CNT_INIT; ci.a = c; ci.b = r; emit(ci);
        nomemo++;
        Inst h; h.op = O_CNT_HEAD; h.a = c; h.b = r; h.mn = (int64_t)mn; h.mx = mx == MAXREPEAT ? INF : (int64_t)mx;
        h.rk = lazy ? R_LAZY : R_GREEDY;
        int H = emit(h);
        body_once(body, flags, atomic_iter);
        Inst j; j.op = O_JMP; j.a = H; emit(j);
        nomemo--;
        P.code[H].c = here();
    }

    void node(const Node& n, int flags) {
        if (++depth > MAXDEPTH + 10) { depth--; throw PyErr{"RecursionError", "maximum recursion depth exceeded"}; }
        struct D { int& d; ~D() { d--; } } dg{depth};
        switch (n.k) {
        case K_LIT: case K_NLIT: case K_ANY: case K_IN:
            emit(atom_for(n, flags));
            break;
        case K_AT: {
            Inst I; I.op = O_AT;
            uint8_t code = (uint8_t)n.c;
            if (code == AT_BEGINNING && (flags & F_MULTILINE)) code = AT_BEGINNING_LINE;
            if (code == AT_END && (flags & F_MULTILINE)) code = AT_END_LINE;
            I.ak = code;
            I.b = unicode_mode(flags) ? 1 : 0;
            emit(I);
            break;
        }
        case K_BRANCH: {
            std::vector<int> jumps;
            for (size_t i = 0; i < n.subs.size(); i++) {
                if (i + 1 < n.subs.size()) {
                    Inst s; s.op = O_SPLIT; s.a = here() + 1;
                    int S = emit(s);
                    seq(n.subs[i], flags);
                    Inst j; j.op = O_JMP; jumps.push_back(emit(j));
                    P.code[S].b = here();
                } else {
                    seq(n.subs[i], flags);
                }
            }
            for (int pc : jumps) P.code[pc].a = here();
            break;
        }
        case K_SUB: {
            int f2 = combine_flags(flags, n.addf, n.delf);
            if (n.group >= 0) { Inst s; s.op = O_SAVE; s.a = 2 * n.group; emit(s); }
            seq(n.subs[0], f2);
            if (n.group >= 0) { Inst s; s.op = O_SAVE; s.a = 2 * n.group + 1; emit(s); }
            break;
        }
        case K_ATOMIC: {
            Inst a; a.op = O_ATOMIC; emit(a);
            seq(n.subs[0], flags);
            Inst e; e.op = O_ATOMIC_END; emit(e);
            break;
        }
        case K_REP: {
            const Node* atom = nullptr;
            int aflags = flags;
            if (simple(n.subs[0], flags, atom, aflags)) {
                Inst I = atom_for(*atom, aflags);
                I.op = O_REP1;
                I.mn = (int64_t)n.mn;
                I.mx = n.mx == MAXREPEAT ? INF : (int64_t)n.mx;
                I.rk = n.rk;
                emit(I);
                break;
            }
            if (n.rk == R_POSS) {
                Inst a; a.op = O_ATOMIC; emit(a);
                loop(n.subs[0], n.mn, n.mx, false, flags, true);
                Inst e; e.op = O_ATOMIC_END; emit(e);
            } else {
                loop(n.subs[0], n.mn, n.mx, n.rk == R_LAZY, flags, false);
            }
            break;
        }
        case K_REF: {
            Inst I; I.op = O_BACKREF; I.a = (int32_t)n.c;
            I.ak = !(flags & F_IGNORECASE) ? 0 : (unicode_mode(flags) ? 2 : 1);
            emit(I);
            break;
        }
        case K_REFEX: {
            Inst g; g.op = O_GROUPEX; g.a = (int32_t)n.c;
            int G = emit(g);
            seq(n.subs[0], flags);
            if (n.has_no) {
                Inst j; j.op = O_JMP; int J = emit(j);
                P.code[G].b = here();
                seq(n.subs[1], flags);
                P.code[J].a = here();
            } else {
                P.code[G].b = here();
            }
            break;
        }
        case K_ASSERT: case K_ASSERTNOT: {
            Inst L; L.op = O_LOOK;
            bool neg = n.k == K_ASSERTNOT;
            if (n.dir < 0) {
                Width w = seq_width(n.subs[0], gw);
                if (w.lo > MAXCODE) throw Error{"looks too much behind", -1};
                if (w.lo != w.hi) throw Error{"look-behind requires fixed-width pattern", -1};
                L.ak = neg ? 3 : 2;
                L.b = (int32_t)w.lo;
            } else {
                L.ak = neg ? 1 : 0;
            }
            int LI = emit(L);
            std::vector<int32_t> saved;
            saved.swap(progstack);
            seq(n.subs[0], flags);
            progstack.swap(saved);
            Inst e; e.op = O_LOOK_END; emit(e);
            P.code[LI].c = here();
            break;
        }
        }
    }

    // Memo slots, after code generation: see "Selective memoization".
    void assign_memo() {
        size_t N = P.code.size();
        std::vector<uint8_t> reads(N, 0);
        // reaches a capture reader (backreference / conditional)?
        std::vector<std::vector<int>> preds(N + 1);
        auto edge = [&](int from, int to) { if (to >= 0 && (size_t)to < N) preds[to].push_back(from); };
        for (size_t pc = 0; pc < N; pc++) {
            const Inst& I = P.code[pc];
            int p = (int)pc;
            switch (I.op) {
            case O_SPLIT: edge(p, I.a); edge(p, I.b); break;
            case O_JMP: edge(p, I.a); break;
            case O_PROG_CHECK: edge(p, I.b); edge(p, p + 1); break;
            case O_CNT_HEAD: edge(p, I.c); edge(p, p + 1); break;
            case O_GROUPEX: edge(p, I.b); edge(p, p + 1); break;
            case O_LOOK: edge(p, I.c); edge(p, p + 1); break;
            case O_LOOK_END: case O_MATCH: break;
            default: edge(p, p + 1); break;
            }
        }
        std::vector<int> work;
        for (size_t pc = 0; pc < N; pc++)
            if (P.code[pc].op == O_BACKREF || P.code[pc].op == O_GROUPEX) { reads[pc] = 1; work.push_back((int)pc); }
        while (!work.empty()) {
            int x = work.back();
            work.pop_back();
            for (int p : preds[x]) if (!reads[p]) { reads[p] = 1; work.push_back(p); }
        }
        // Only a state reachable along two paths can be explored twice: the
        // memo points are the instructions with two or more predecessors
        // (loop heads, the ends of alternations; the paper's in-degree > 1
        // vertices). An alternation of 1000 words has one, not 999.
        std::vector<int> indeg(N + 1, 0);
        for (size_t pc = 0; pc < N; pc++) indeg[pc] = (int)preds[pc].size();
        indeg[0]++;                      // the entry: each search start
        int64_t slots = 0;
        for (size_t pc = 0; pc < N; pc++) {
            Inst& I = P.code[pc];
            I.memo = -1;
            if (inst_nomemo[pc] || reads[pc] || I.nregs > 3) continue;
            if (I.op != O_REP1 && I.op != O_MATCH && I.op != O_LOOK_END && I.op != O_ATOMIC_END && indeg[pc] >= 2) {
                I.memo = slots;
                slots += 1 << I.nregs;
            } else if (I.op == O_REP1 && I.rk != R_POSS) {
                // x*, x+, x*?: run states; bounded ones (x?, x{2,5}): the
                // continuation states after the loop, one per count.
                I.memo = slots;
                slots += 1 << I.nregs;
                I.c = (I.mn <= 1 && I.mx == INF) ? 1 : 2;
            }
        }
        P.memo_slots = slots;
    }

    // An atom for the first-character set, unless an equal one is there.
    void add_atom(std::vector<int32_t>& atoms, int x) const {
        const Inst& I = P.code[(size_t)x];
        for (int32_t a : atoms) {
            const Inst& J = P.code[(size_t)a];
            if (J.ak == I.ak && J.ch == I.ch && (I.ak != A_SET || J.set == I.set)) return;
        }
        atoms.push_back(x);
    }
    // Literal prefix, first-character set, anchoring.
    void analyse() {
        const auto& C = P.code;
        if (!C.empty() && C[0].op == O_AT && (C[0].ak == AT_BEGINNING || C[0].ak == AT_BEGINNING_STRING))
            P.anchored = true;
        size_t pc = 0;
        while (pc < C.size()) {
            if (C[pc].op == O_SAVE) { pc++; continue; }
            if (C[pc].op == O_ONE && C[pc].ak == A_CHAR) { P.prefix.push_back(C[pc].ch); pc++; if (P.prefix.size() >= 64) break; continue; }
            break;
        }
        // first set: the atoms that can consume the first character
        std::vector<uint8_t> seen(C.size() + 1, 0);
        std::vector<int> work{0};
        std::vector<int32_t> atoms;
        bool ok = true;
        while (!work.empty() && ok) {
            int x = work.back();
            work.pop_back();
            if (x < 0 || (size_t)x >= C.size()) { ok = false; break; }
            if (seen[x]) continue;
            seen[x] = 1;
            const Inst& I = C[x];
            switch (I.op) {
            case O_ONE: add_atom(atoms, x); break;
            case O_REP1: add_atom(atoms, x); if (I.mn == 0) work.push_back(x + 1); break;
            case O_AT: case O_SAVE: case O_PROG_SET: case O_PROG_MARK: case O_CNT_INIT:
            case O_ATOMIC: case O_ATOMIC_END: work.push_back(x + 1); break;
            case O_SPLIT: work.push_back(I.a); work.push_back(I.b); break;
            case O_JMP: work.push_back(I.a); break;
            case O_PROG_CHECK: work.push_back(I.b); work.push_back(x + 1); break;
            case O_CNT_HEAD: work.push_back(I.c); work.push_back(x + 1); break;
            case O_GROUPEX: work.push_back(I.b); work.push_back(x + 1); break;
            case O_LOOK: work.push_back(I.c); break;
            default: ok = false; break;   // MATCH (can match empty), BACKREF, LOOK_END
            }
            if (atoms.size() > 256) ok = false;
        }
        if (!ok || atoms.empty()) return;
        P.has_first = true;
        P.first_atoms = atoms;
        for (uint32_t c = 0; c < 256; c++)
            for (int32_t a : atoms)
                if (atom_test(P, C[a], c)) { P.first_bm[c >> 6] |= 1ull << (c & 63); break; }
    }
};

// ═══════════════════════════════════════════════════════════════════════
// 4. Machine
// ═══════════════════════════════════════════════════════════════════════
struct Memo {
    uint64_t stride = 0, slots = 0;
    std::vector<uint64_t> bits{};
    bool hash = false;
    std::unordered_set<uint64_t> hs{};
    void init(uint64_t nslots, uint64_t n) {
        stride = n + 1;
        slots = nslots;
        hash = slots && (slots * stride > (1ull << 27) || slots > ((1ull << 40) / stride));
    }
    bool test(uint64_t i) const {
        if (hash) return hs.count(i) != 0;
        size_t w = (size_t)(i >> 6);
        return w < bits.size() && ((bits[w] >> (i & 63)) & 1);
    }
    void ensure() { if (bits.empty()) bits.assign((size_t)((slots * stride + 63) / 64), 0); }
    void set(uint64_t i) {
        if (hash) { hs.insert(i); return; }
        ensure();
        bits[i >> 6] |= 1ull << (i & 63);
    }
    void set_range(uint64_t a, uint64_t b) {     // inclusive
        if (a > b) return;
        if (hash) { for (uint64_t i = a; i <= b; i++) hs.insert(i); return; }
        ensure();
        for (uint64_t i = a; i <= b;) {
            if ((i & 63) == 0 && i + 63 <= b) { bits[i >> 6] = ~0ull; i += 64; }
            else { bits[i >> 6] |= 1ull << (i & 63); i++; }
        }
    }
};

enum EntryKind : uint32_t {
    E_ALT, E_MEMO, E_UNDO_CAP, E_UNDO_LAST, E_UNDO_REG, E_REP1G, E_REP1L, E_CNT_ITER, E_BARRIER
};
struct Entry {
    uint32_t kind;
    int32_t pc;
    int64_t a, b, c;
};
inline bool is_undo(uint32_t k) { return k == E_UNDO_CAP || k == E_UNDO_LAST || k == E_UNDO_REG; }

template <class C>
struct Machine {
    const Program& P;
    const C* s;
    int64_t n;
    std::vector<int64_t> caps{}, regs{};
    int64_t lastindex = -1;
    std::vector<Entry> stk{};
    Memo memo{};
    int64_t start = 0;
    bool must_adv = false;
    Mode mode = SEARCH;

    Machine(const Machine&) = delete;
    Machine& operator=(const Machine&) = delete;
    Machine(const Program& p, const C* subj, int64_t len) : P(p), s(subj), n(len) {
        caps.assign((size_t)P.ncaps, -1);
        regs.assign((size_t)std::max(P.nregs, 1), -1);
        memo.init((uint64_t)P.memo_slots, (uint64_t)n);
    }

    void push(uint32_t k, int32_t pc, int64_t a, int64_t b = 0, int64_t c = 0) { stk.push_back(Entry{k, pc, a, b, c}); }
    void set_cap(int slot, int64_t pos) {
        if (!stk.empty()) push(E_UNDO_CAP, slot, caps[(size_t)slot]);
        caps[(size_t)slot] = pos;
        if (slot & 1) {
            if (!stk.empty()) push(E_UNDO_LAST, 0, lastindex);
            lastindex = slot >> 1;
        }
    }
    void set_reg(int r, int64_t v) {
        if (!stk.empty()) push(E_UNDO_REG, r, regs[(size_t)r]);
        regs[(size_t)r] = v;
    }
    void apply_undo(const Entry& e) {
        if (e.kind == E_UNDO_CAP) caps[(size_t)e.pc] = e.a;
        else if (e.kind == E_UNDO_LAST) lastindex = e.a;
        else if (e.kind == E_UNDO_REG) regs[(size_t)e.pc] = e.a;
    }
    size_t top_barrier() const {
        for (size_t i = stk.size(); i-- > 0;) if (stk[i].kind == E_BARRIER) return i;
        return 0;   // not reached: every END has its barrier
    }
    // An atomic group or a positive lookaround succeeded: its choice points
    // go, the undo records stay (backtracking past it restores the captures).
    void cut(size_t bi) {
        size_t w = bi;
        for (size_t i = bi + 1; i < stk.size(); i++) if (is_undo(stk[i].kind)) stk[w++] = stk[i];
        stk.resize(w);
    }
    // A negative lookaround's body matched: everything it did is undone.
    void unwind(size_t bi) {
        for (size_t i = stk.size(); i-- > bi + 1;) apply_undo(stk[i]);
        stk.resize(bi);
    }
    bool word(uint32_t c, bool uni) const { return uni ? u_word(c) : a_word(c); }
    bool at(const Inst& I, int64_t pos) const {
        switch (I.ak) {
        case AT_BEGINNING: case AT_BEGINNING_STRING: return pos == 0;
        case AT_BEGINNING_LINE: return pos == 0 || s[pos - 1] == '\n';
        case AT_END: return pos == n || (pos + 1 == n && s[pos] == '\n');
        case AT_END_LINE: return pos == n || s[pos] == '\n';
        case AT_END_STRING: return pos == n;
        default: {
            if (n == 0) return false;
            bool that = pos > 0 && word(s[pos - 1], I.b != 0);
            bool thisp = pos < n && word(s[pos], I.b != 0);
            return I.ak == AT_BOUNDARY ? thisp != that : thisp == that;
        }
        }
    }
    uint64_t memo_bits(const Inst& I, int64_t pos) const {
        uint64_t k = 0;
        for (int j = 0; j < I.nregs; j++) if (regs[(size_t)I.regs[j]] == pos) k += 1u << j;
        return k;
    }
    uint64_t memo_idx(const Inst& I, int64_t pos) const {
        return ((uint64_t)I.memo + memo_bits(I, pos)) * memo.stride + (uint64_t)pos;
    }
    uint64_t cont_idx(const Inst& I, int64_t pos) const { return memo_idx(I, pos); }
    // A single-character loop's choice point is exhausted: the run states
    // [lo, top] failed (lo with the entry's key bits, the rest with none).
    void record_run(const Inst& R, uint32_t kind, int64_t lo, int64_t top) {
        if (R.memo < 0 || R.c != 1) return;
        uint64_t base = (uint64_t)R.memo * memo.stride;
        uint64_t bits = kind >> 8;
        if (bits) {
            memo.set(base + bits * memo.stride + (uint64_t)lo);
            lo++;
        }
        if (lo <= top) memo.set_range(base + (uint64_t)lo, base + (uint64_t)top);
    }

    bool run(int64_t st0) {
        int64_t pos = st0;
        int32_t pc = 0;
        stk.clear();
        std::fill(caps.begin(), caps.end(), -1);
        lastindex = -1;
        const Inst* code = P.code.data();
        for (;;) {
            {
                const Inst& I = code[pc];
                if (I.memo >= 0 && I.op != O_SPLIT && I.op != O_REP1) {
                    uint64_t x = memo_idx(I, pos);
                    if (memo.test(x)) goto fail;
                    push(E_MEMO, 0, 0, (int64_t)x);
                }
                switch (I.op) {
                case O_ONE:
                    if (pos < n && atom_test(P, I, s[pos])) { pos++; pc++; continue; }
                    goto fail;
                case O_AT:
                    if (at(I, pos)) { pc++; continue; }
                    goto fail;
                case O_SAVE:
                    set_cap(I.a, pos);
                    pc++;
                    continue;
                case O_SPLIT: {
                    int64_t mi = -1;
                    if (I.memo >= 0) {
                        uint64_t x = memo_idx(I, pos);
                        if (memo.test(x)) goto fail;
                        mi = (int64_t)x;
                    }
                    push(E_ALT, I.b, pos, mi);
                    pc = I.a;
                    continue;
                }
                case O_JMP:
                    pc = I.a;
                    continue;
                case O_REP1: {
                    int64_t avail = n - pos;
                    if (I.mn > avail) goto fail;
                    int64_t lim = (I.mx == INF || I.mx > avail) ? avail : I.mx;
                    int64_t q = pos, e = pos + I.mn;
                    for (; q < e; q++) if (!atom_test(P, I, s[q])) goto fail;
                    int64_t lo = q, end = pos + lim;
                    if (I.rk == R_POSS) {
                        while (q < end && atom_test(P, I, s[q])) q++;
                        pos = q;
                        pc++;
                        continue;
                    }
                    if (I.memo >= 0 && I.c == 2) {
                        // continuation memo: (pc + 1, i) for each count tried
                        if (I.rk == R_GREEDY) {
                            while (q < end && atom_test(P, I, s[q])) q++;
                            int64_t cur = q;
                            while (cur >= lo && memo.test(cont_idx(I, cur))) cur--;
                            if (cur < lo) goto fail;
                            push(E_REP1G, pc, lo, cur, q);
                            pos = cur;
                        } else {
                            int64_t cur = lo;
                            while (memo.test(cont_idx(I, cur))) {
                                if (cur < end && atom_test(P, I, s[cur])) cur++;
                                else goto fail;
                            }
                            push(E_REP1L, pc, lo, cur, end);
                            pos = cur;
                        }
                        pc++;
                        continue;
                    }
                    // Run states L(i): the loop at i, whatever it was entered
                    // at. Past the entry position every enclosing empty-loop
                    // check has seen progress, so their key bits are 0 there.
                    uint64_t base = 0, bits = 0;
                    if (I.memo >= 0) {
                        base = (uint64_t)I.memo * memo.stride;
                        if (I.mn == 0) bits = memo_bits(I, pos);
                        if (memo.test(base + bits * memo.stride + (uint64_t)lo)) goto fail;
                    }
                    uint32_t tag = (uint32_t)bits << 8;
                    if (I.rk == R_GREEDY) {
                        if (I.memo >= 0) { while (q < end && atom_test(P, I, s[q]) && !memo.test(base + (uint64_t)q + 1)) q++; }
                        else while (q < end && atom_test(P, I, s[q])) q++;
                        if (q > lo || I.memo >= 0) push(E_REP1G | tag, pc, lo, q, q);
                        pos = q;
                    } else {
                        if (end > lo || I.memo >= 0) push(E_REP1L | tag, pc, lo, lo, end);
                        pos = lo;
                    }
                    pc++;
                    continue;
                }
                case O_PROG_SET: set_reg(I.a, -1); pc++; continue;
                case O_PROG_MARK: set_reg(I.a, pos); pc++; continue;
                case O_PROG_CHECK: pc = regs[(size_t)I.a] == pos ? I.b : pc + 1; continue;
                case O_CNT_INIT: set_reg(I.a, 0); set_reg(I.b, -1); pc++; continue;
                case O_CNT_HEAD: {
                    int64_t k = regs[(size_t)I.a];
                    if (k < I.mn) { set_reg(I.a, k + 1); pc++; continue; }
                    bool can = (I.mx == INF || k < I.mx) && pos != regs[(size_t)I.b];
                    if (!can) { pc = I.c; continue; }
                    if (I.rk == R_GREEDY) {
                        push(E_ALT, I.c, pos, -1);
                        set_reg(I.a, k + 1);
                        set_reg(I.b, pos);
                        pc++;
                    } else {
                        push(E_CNT_ITER, pc, pos);
                        pc = I.c;
                    }
                    continue;
                }
                case O_BACKREF: {
                    int64_t a = caps[(size_t)(2 * I.a)], b = caps[(size_t)(2 * I.a + 1)];
                    if (a < 0 || b < 0 || b < a) goto fail;
                    int64_t len = b - a;
                    if (len > n - pos) goto fail;
                    for (int64_t i = 0; i < len; i++) {
                        uint32_t c1 = s[a + i], c2 = s[pos + i];
                        bool eq = I.ak == 0 ? c1 == c2 : I.ak == 1 ? a_lower(c1) == a_lower(c2) : u_lower(c1) == u_lower(c2);
                        if (!eq) goto fail;
                    }
                    pos += len;
                    pc++;
                    continue;
                }
                case O_GROUPEX:
                    pc = (caps[(size_t)(2 * I.a)] >= 0 && caps[(size_t)(2 * I.a + 1)] >= 0) ? pc + 1 : I.b;
                    continue;
                case O_LOOK: {
                    bool behind = I.ak >= 2, neg = I.ak & 1;
                    if (behind && pos < I.b) {
                        if (neg) { pc = I.c; continue; }
                        goto fail;
                    }
                    push(E_BARRIER, pc, pos);
                    if (behind) pos -= I.b;
                    pc++;
                    continue;
                }
                case O_LOOK_END: {
                    size_t bi = top_barrier();
                    Entry B = stk[bi];
                    const Inst& L = code[B.pc];
                    if (L.ak & 1) { unwind(bi); goto fail; }
                    cut(bi);
                    pos = B.a;
                    pc = L.c;
                    continue;
                }
                case O_ATOMIC:
                    push(E_BARRIER, pc, pos);
                    pc++;
                    continue;
                case O_ATOMIC_END:
                    cut(top_barrier());
                    pc++;
                    continue;
                case O_MATCH:
                    if (mode == FULLMATCH && pos != n) goto fail;
                    if (must_adv && pos == start) goto fail;
                    caps[0] = st0;
                    caps[1] = pos;
                    return true;
                }
            }
        fail:
            for (;;) {
                if (stk.empty()) return false;
                Entry& e = stk.back();
                switch (e.kind & 0xFF) {
                case E_ALT:
                    pc = e.pc;
                    pos = e.a;
                    if (e.b >= 0) e.kind = E_MEMO; else stk.pop_back();
                    goto resume;
                case E_MEMO:
                    memo.set((uint64_t)e.b);
                    stk.pop_back();
                    continue;
                case E_UNDO_CAP: case E_UNDO_LAST: case E_UNDO_REG:
                    apply_undo(e);
                    stk.pop_back();
                    continue;
                case E_REP1G: {
                    const Inst& R = code[e.pc];
                    if (R.memo >= 0 && R.c == 2) {
                        memo.set(cont_idx(R, e.b));
                        int64_t cur = e.b - 1;
                        while (cur >= e.a && memo.test(cont_idx(R, cur))) cur--;
                        if (cur < e.a) { stk.pop_back(); continue; }
                        e.b = cur;
                        pos = cur;
                        pc = e.pc + 1;
                        goto resume;
                    }
                    if (e.b > e.a) {
                        e.b--;
                        pos = e.b;
                        pc = e.pc + 1;
                        goto resume;
                    }
                    record_run(R, e.kind, e.a, e.c);
                    stk.pop_back();
                    continue;
                }
                case E_REP1L: {
                    const Inst& R = code[e.pc];
                    if (R.memo >= 0 && R.c == 2) {
                        memo.set(cont_idx(R, e.b));
                        bool again = false;
                        while (e.b < e.c && atom_test(P, R, s[e.b])) {
                            e.b++;
                            if (!memo.test(cont_idx(R, e.b))) { again = true; break; }
                        }
                        if (!again) { stk.pop_back(); continue; }
                        pos = e.b;
                        pc = e.pc + 1;
                        goto resume;
                    }
                    uint64_t base = R.memo >= 0 ? (uint64_t)R.memo * memo.stride : 0;
                    if (e.b < e.c && atom_test(P, R, s[e.b]) && !(R.memo >= 0 && memo.test(base + (uint64_t)e.b + 1))) {
                        e.b++;
                        pos = e.b;
                        pc = e.pc + 1;
                        goto resume;
                    }
                    record_run(R, e.kind, e.a, e.b);
                    stk.pop_back();
                    continue;
                }
                case E_CNT_ITER: {
                    int32_t hp = e.pc;
                    int64_t p0 = e.a;
                    stk.pop_back();
                    const Inst& H = code[hp];
                    int64_t k = regs[(size_t)H.a];
                    pos = p0;
                    set_reg(H.a, k + 1);
                    set_reg(H.b, pos);
                    pc = hp + 1;
                    goto resume;
                }
                case E_BARRIER: {
                    const Inst& L = code[e.pc];
                    if (L.op == O_LOOK && (L.ak & 1)) {
                        pos = e.a;
                        pc = L.c;
                        stk.pop_back();
                        goto resume;
                    }
                    stk.pop_back();
                    continue;
                }
                }
            }
        resume:;
        }
    }

    bool first_ok(uint32_t c) const {
        if (c < 256) return (P.first_bm[c >> 6] >> (c & 63)) & 1;
        for (int32_t a : P.first_atoms) if (atom_test(P, P.code[(size_t)a], c)) return true;
        return false;
    }
    // Next start position >= from where the literal prefix occurs, or -1.
    int64_t find_prefix(int64_t from) const {
        const auto& pf = P.prefix;
        int64_t k = (int64_t)pf.size();
        if (k > n) return -1;
        uint32_t c0 = pf[0];
        for (int64_t i = from; i + k <= n;) {
            if constexpr (sizeof(C) == 1) {
                if (c0 > 255) return -1;
                const void* hit = std::memchr(s + i, (int)c0, (size_t)(n - k + 1 - i));
                if (!hit) return -1;
                i = (const C*)hit - s;
            } else {
                while (i + k <= n && s[i] != c0) i++;
                if (i + k > n) return -1;
            }
            int64_t j = 1;
            while (j < k && s[i + j] == pf[(size_t)j]) j++;
            if (j == k) return i;
            i++;
        }
        return -1;
    }

    bool search(int64_t pos) {
        if (P.anchored) return run(pos);
        bool use_prefix = P.prefix.size() >= 2 || (P.prefix.size() == 1 && sizeof(C) == 1);
        for (int64_t s0 = pos; s0 <= n; s0++) {
            if (use_prefix) {
                s0 = find_prefix(s0);
                if (s0 < 0) return false;
            } else if (P.has_first) {
                while (s0 < n && !first_ok(s[s0])) s0++;
                if (s0 >= n) return false;
            }
            if (run(s0)) return true;
        }
        return false;
    }

    bool exec(int64_t pos, Mode md, bool must_advance, Match& out) {
        if (pos < 0 || pos > n) return false;
        mode = md;
        must_adv = must_advance;
        start = pos;
        bool ok = md == SEARCH ? search(pos) : run(pos);
        stk.clear();
        if (!ok) return false;
        out.lastindex = lastindex;
        out.spans = caps;
        return true;
    }
};

} // namespace

// ── Scanner ──────────────────────────────────────────────────────────────
struct Scanner::Impl {
    virtual ~Impl() {}
    virtual bool exec(int64_t pos, Mode mode, bool must_advance, Match& out) = 0;
};
namespace {
template <class C>
struct MachineImpl : Scanner::Impl {
    std::shared_ptr<const Program> keep;
    Machine<C> m;
    MachineImpl(std::shared_ptr<const Program> p, const C* s, int64_t n) : keep(p), m(*p, s, n) {}
    bool exec(int64_t pos, Mode mode, bool must_advance, Match& out) override { return m.exec(pos, mode, must_advance, out); }
};
} // namespace
Scanner::Scanner(const Compiled& c, const uint8_t* s, int64_t n) : impl_(new MachineImpl<uint8_t>(c.prog, s, n)) {}
Scanner::Scanner(const Compiled& c, const uint32_t* s, int64_t n) : impl_(new MachineImpl<uint32_t>(c.prog, s, n)) {}
Scanner::~Scanner() = default;
bool Scanner::exec(int64_t pos, Mode mode, bool must_advance, Match& out) { return impl_->exec(pos, mode, must_advance, out); }

// ── compile ──────────────────────────────────────────────────────────────
Compiled compile(const std::vector<uint32_t>& pattern, int flags, bool is_bytes) {
    Parser ps(pattern, !is_bytes);
    ps.flags = flags;
    Seq tree;
    try {
        tree = ps.parse_all();
    } catch (Error& e) {
        if (is_bytes) {   // msg.encode('ascii', 'backslashreplace')
            std::string m;
            for (size_t i = 0; i < e.msg.size();) {
                uint32_t c = nypy::u8_decode(e.msg, i);
                if (c < 128) m += (char)c;
                else { char b[8]; std::snprintf(b, sizeof b, "\\x%02x", c & 0xFF); m += b; }
            }
            e.msg = m;
        }
        throw;
    }
    auto prog = std::make_shared<Program>();
    prog->ncaps = 2 * ps.groups();
    Compiler cc(*prog, ps.groupwidths);
    cc.seq(tree, ps.flags);
    Inst m; m.op = O_MATCH;
    cc.emit(m);
    cc.assign_memo();
    cc.analyse();
    Compiled out;
    out.prog = prog;
    out.groups = ps.groups() - 1;
    out.flags = ps.flags;
    out.is_bytes = is_bytes;
    for (auto& g : ps.groupdict) out.groupindex.push_back({utf8(g.first), g.second});
    return out;
}

// ═══════════════════════════════════════════════════════════════════════
// 5. Templates (_parser.parse_template)
// ═══════════════════════════════════════════════════════════════════════
std::vector<TemplateItem> parse_template(const Compiled& cp, const std::vector<uint32_t>& repl, bool is_bytes) {
    Parser src(repl, !is_bytes);
    std::vector<TemplateItem> result;
    std::string literal;
    auto add_char = [&](uint32_t c) {
        if (is_bytes) literal += (char)(unsigned char)c;
        else nypy::u8_encode(c, literal);
    };
    auto addliteral = [&]() {
        if (!literal.empty()) result.push_back({-1, literal});
        literal.clear();
    };
    auto addgroup = [&](int64_t index, int64_t pos) {
        if (index > cp.groups) throw src.error("invalid group reference " + std::to_string(index), pos);
        addliteral();
        result.push_back({(int)index, std::string()});
    };
    for (;;) {
        Tok t = src.get();
        if (t.none) break;
        if (t.len == 2) {
            uint32_t c = t.b;
            if (c == 'g') {
                if (!src.match('<')) throw src.error("missing <");
                std::u32string name = src.getuntil('>', "group name");
                int64_t index;
                if (!Parser::all_ascii_digits(name)) {
                    src.checkgroupname(name, 1);
                    std::string nm = utf8(name);
                    index = -1;
                    for (auto& g : cp.groupindex) if (g.first == nm) index = g.second;
                    if (index < 0) throw PyErr{"IndexError", "unknown group name '" + nm + "'"};
                } else {
                    uint64_t v = Parser::to_int(name);
                    index = (int64_t)v;
                    if (v >= (uint64_t)MAXGROUPS)
                        throw src.error("invalid group reference " + std::to_string(v), (int64_t)name.size() + 1);
                }
                addgroup(index, (int64_t)name.size() + 1);
            } else if (c == '0') {
                uint32_t v = 0;
                if (src.next.in(OCTDIGITS)) {
                    v = src.get().a - '0';
                    if (src.next.in(OCTDIGITS)) v = v * 8 + (src.get().a - '0');
                }
                add_char(v & 0xFF);
            } else if (in_set(c, DIGITS)) {
                bool isoctal = false;
                std::u32string th = t.str();
                if (src.next.in(DIGITS)) {
                    th += src.get().a;
                    if (in_set(c, OCTDIGITS) && in_set(th[2], OCTDIGITS) && src.next.in(OCTDIGITS)) {
                        th += src.get().a;
                        isoctal = true;
                        uint32_t v = (th[1] - '0') * 64 + (th[2] - '0') * 8 + (th[3] - '0');
                        if (v > 0377)
                            throw src.error("octal escape value " + utf8(th) + " outside of range 0-0o377", (int64_t)th.size());
                        add_char(v);
                    }
                }
                if (!isoctal) {
                    int64_t g = 0;
                    for (size_t i = 1; i < th.size(); i++) g = g * 10 + (th[i] - '0');
                    addgroup(g, (int64_t)th.size() - 1);
                }
            } else {
                uint32_t v;
                if (Parser::simple_escape(c, v)) add_char(v);
                else if (ascii_letter(c)) throw src.error("bad escape " + utf8(t.str()), 2);
                else { add_char('\\'); add_char(c); }
            }
        } else {
            add_char(t.a);
        }
    }
    addliteral();
    return result;
}

std::vector<uint32_t> escape(const std::vector<uint32_t>& s) {
    static const char* special = "()[]{}?*+-|^$\\.&~# \t\n\r\v\f";
    std::vector<uint32_t> r;
    r.reserve(s.size() + 8);
    for (uint32_t c : s) {
        if (c && c < 128 && std::strchr(special, (int)c)) r.push_back('\\');
        r.push_back(c);
    }
    return r;
}

} // namespace nyre

// ═══════════════════════════════════════════════════════════════════════
// 6. Builtins
// ═══════════════════════════════════════════════════════════════════════
//   _re_compile(pattern, flags) -> [groups, flags, [name, index, ...]]
//                                  or [-1, message, pos] (re.error)
//   _re_exec(pattern, flags, string, pos, endpos, mode) -> match or none
//                                  mode 0 search, 1 match, 2 fullmatch
//   _re_scan(pattern, flags, string, pos, endpos, limit, must_advance)
//                                  -> [match, ...]  successive searches
//   _re_findall(pattern, flags, string, pos, endpos) -> list
//   _re_split(pattern, flags, string, maxsplit) -> list (Pattern.split)
//   _re_pieces(pattern, flags, string, count)
//                                  -> [gap0, match1, gap1, ..., matchN, gapN]
//   _re_sub(pattern, flags, repl, string, count) -> [result, n]
//                                  or [-1, message, pos] (error in repl)
//   _re_template(pattern, flags, repl) -> [literal, group, literal, ...]
//                                  or [-1, message, pos]
//   _re_escape(s)   _re_purge()
// A match is [lastindex, start0, end0, start1, end1, ..., text0, text1, ...]
// (lastindex none, -1 and none for a group that did not take part). Positions
// are character indexes. Compiled programs are cached here by (type, flags,
// pattern), least recently used out after 512, so lib/re.ny passes the
// pattern each time; a long subject is matched with the GIL released (the
// engine touches no interpreter state).
namespace {

using nyre::Compiled;

std::mutex& cache_mu() { static std::mutex* m = new std::mutex(); return *m; }
struct CacheSlot {
    std::shared_ptr<const Compiled> c{};
    std::list<std::string>::iterator it{};
};
std::unordered_map<std::string, CacheSlot>& cache() { static auto* c = new std::unordered_map<std::string, CacheSlot>(); return *c; }
std::list<std::string>& lru() { static auto* l = new std::list<std::string>(); return *l; }
const size_t CACHE_MAX = 512;

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

struct Text {
    bool is_bytes = false;
    const std::string* raw = nullptr;    // the str's UTF-8 or the bytes
    std::vector<uint32_t> wide{};        // code points, when the str is not ASCII
    bool narrow = true;
    int64_t len = 0;                     // characters
    const uint8_t* p8() const { return (const uint8_t*)raw->data(); }
    // Characters [a, b) as a str's UTF-8 or bytes.
    std::string slice(int64_t a, int64_t b) const {
        if (a < 0 || b < a) return std::string();
        if (narrow) return raw->substr((size_t)a, (size_t)(b - a));
        std::string r;
        for (int64_t i = a; i < b; i++) nypy::u8_encode(wide[(size_t)i], r);
        return r;
    }
};

bool load_text(NythonExecutor& E, const Value& v, Text& t) {
    if (auto* bo = E.bytesOf(v)) {
        t.is_bytes = true;
        t.raw = &bo->s;
        t.len = (int64_t)bo->s.size();
        return true;
    }
    if (v.type == ValueType::USERDATA && v.value.p && E.isStringValue(v)) {
        t.raw = static_cast<const std::string*>(v.value.p);
        if (nypy::is_ascii(*t.raw)) {
            t.len = (int64_t)t.raw->size();
        } else {
            t.narrow = false;
            t.wide = nypy::u8_codepoints(*t.raw);
            t.len = (int64_t)t.wide.size();
        }
        return true;
    }
    return false;
}

std::vector<uint32_t> code_points(const Text& t) {
    if (!t.narrow) return t.wide;
    std::vector<uint32_t> r(t.raw->size());
    for (size_t i = 0; i < r.size(); i++) r[i] = (unsigned char)(*t.raw)[i];
    return r;
}

std::shared_ptr<const Compiled> get_compiled(NythonExecutor& E, const Value& pat, int64_t flags, Text& pt) {
    if (!load_text(E, pat, pt)) fail("TypeError", "first argument must be string or compiled pattern");
    std::string key;
    key.reserve(pt.raw->size() + 16);
    key += pt.is_bytes ? 'b' : 's';
    key += std::to_string(flags);
    key += ':';
    key += *pt.raw;
    {
        std::lock_guard<std::mutex> lk(cache_mu());
        auto it = cache().find(key);
        if (it != cache().end()) {
            lru().splice(lru().end(), lru(), it->second.it);
            return it->second.c;
        }
    }
    auto c = std::make_shared<Compiled>(nyre::compile(code_points(pt), (int)flags, pt.is_bytes));
    std::lock_guard<std::mutex> lk(cache_mu());
    auto it = cache().find(key);
    if (it != cache().end()) return it->second.c;
    if (cache().size() >= CACHE_MAX) {
        cache().erase(lru().front());
        lru().pop_front();
    }
    lru().push_back(key);
    cache()[key] = CacheSlot{c, std::prev(lru().end())};
    return c;
}

Value error_list(NythonExecutor& E, const nyre::Error& e) {
    return E.makeListValue({nyos::make_int(-1), E.makeStringValue(e.msg),
                               e.pos < 0 ? NONE_VALUE : nyos::make_int(e.pos)});
}

void check_kind(NythonExecutor& E, const Compiled& c, const Value& v, Text& t) {
    if (!load_text(E, v, t))
        fail("TypeError", "expected string or bytes-like object, got '" + E.typeNameOf(v) + "'");
    if (c.is_bytes && !t.is_bytes) fail("TypeError", "cannot use a bytes pattern on a string-like object");
    if (!c.is_bytes && t.is_bytes) fail("TypeError", "cannot use a string pattern on a bytes-like object");
}

Value text_value(NythonExecutor& E, const Text& t, std::string s) {
    return t.is_bytes ? E.makeBytesValue(std::move(s)) : E.makeStringValue(s);
}

// One subject's scanner, with the GIL released while it runs on a long one.
struct Run {
    std::unique_ptr<nyre::Scanner> sc{};
    bool release = false;
    Run(const Compiled& c, const Text& t, int64_t endpos) {
        if (t.narrow) sc.reset(new nyre::Scanner(c, t.p8(), endpos));
        else sc.reset(new nyre::Scanner(c, t.wide.data(), endpos));
        release = endpos > 4096;
    }
    bool exec(int64_t pos, nyre::Mode m, bool adv, nyre::Match& out) {
        if (release) {
            nyconc::GilRelease unlocked;
            return sc->exec(pos, m, adv, out);
        }
        return sc->exec(pos, m, adv, out);
    }
};

Value match_value(NythonExecutor& E, const Compiled& c, const Text& t, const nyre::Match& m) {
    std::vector<Value> items;
    size_t ng = (size_t)c.groups + 1;
    items.reserve(1 + 3 * ng);
    items.push_back(m.lastindex < 0 ? NONE_VALUE : nyos::make_int(m.lastindex));
    for (size_t i = 0; i < 2 * ng; i++) items.push_back(nyos::make_int(m.spans[i]));
    for (size_t g = 0; g < ng; g++) {
        int64_t a = m.spans[2 * g], b = m.spans[2 * g + 1];
        items.push_back(a < 0 || b < 0 ? NONE_VALUE : text_value(E, t, t.slice(a, b)));
    }
    return E.makeListValue(items);
}

void clip(int64_t len, int64_t& pos, int64_t& endpos) {
    if (pos < 0) pos = 0; else if (pos > len) pos = len;
    if (endpos < 0) endpos = 0; else if (endpos > len) endpos = len;
}

int64_t int_arg(std::vector<Value>& args, size_t i, int64_t dflt) {
    if (i >= args.size() || args[i].type == ValueType::NONE) return dflt;
    return nyos::to_int(args[i], dflt);
}

Value re_tuple(NythonExecutor& E, const std::vector<Value>& items) { return E.makeListValue(items, true); }

} // namespace

std::vector<std::string> re_builtin_names() {
    return {"_re_compile", "_re_exec", "_re_scan", "_re_findall", "_re_split", "_re_pieces", "_re_sub",
            "_re_template", "_re_escape", "_re_purge"};
}

Value dispatch_re(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name == "_re_purge") {
        std::lock_guard<std::mutex> lk(cache_mu());
        cache().clear();
        lru().clear();
        return NONE_VALUE;
    }
    if (name == "_re_escape") {
        Text t;
        if (args.empty() || !load_text(E, args[0], t))
            fail("TypeError", "expected str or bytes");
        std::vector<uint32_t> r = nyre::escape(code_points(t));
        std::string out;
        for (uint32_t c : r) {
            if (t.is_bytes) out += (char)(unsigned char)c;
            else nypy::u8_encode(c, out);
        }
        return text_value(E, t, out);
    }
    if (args.size() < 2) fail("TypeError", name + "() needs a pattern and flags");
    int64_t flags = nyos::to_int(args[1], 0);
    Text pt;
    std::shared_ptr<const Compiled> cp;
    try {
        cp = get_compiled(E, args[0], flags, pt);
    } catch (nyre::Error& e) {
        if (name == "_re_compile") return error_list(E, e);
        fail("ValueError", e.msg);
    } catch (nyre::PyErr& e) {
        fail(e.type, e.msg);
    }
    const Compiled& c = *cp;

    if (name == "_re_compile") {
        std::vector<Value> gi;
        for (auto& g : c.groupindex) { gi.push_back(E.makeStringValue(g.first)); gi.push_back(nyos::make_int(g.second)); }
        return E.makeListValue({nyos::make_int(c.groups), nyos::make_int(c.flags), E.makeListValue(gi)});
    }
    if (name == "_re_template" || name == "_re_sub") {
        size_t ri = 2;
        if (args.size() <= ri) fail("TypeError", name + "() needs a replacement");
        Text rt;
        if (!load_text(E, args[ri], rt))
            fail("TypeError", "expected str or bytes-like object, got '" + E.typeNameOf(args[ri]) + "'");
        if (rt.is_bytes != c.is_bytes)
            fail("TypeError", c.is_bytes ? "expected a bytes-like object, str found" : "expected str instance, bytes found");
        std::vector<nyre::TemplateItem> tpl;
        try {
            tpl = nyre::parse_template(c, code_points(rt), rt.is_bytes);
        } catch (nyre::Error& e) {
            return error_list(E, e);
        } catch (nyre::PyErr& e) {
            fail(e.type, e.msg);
        }
        if (name == "_re_template") {
            std::vector<Value> items;
            for (auto& it : tpl) {
                if (it.group < 0) items.push_back(text_value(E, rt, it.text));
                else items.push_back(nyos::make_int(it.group));
            }
            return E.makeListValue(items);
        }
        Text t;
        if (args.size() < 4) fail("TypeError", "_re_sub() needs a string");
        check_kind(E, c, args[3], t);
        int64_t count = int_arg(args, 4, 0);
        std::string out;
        int64_t nsub = 0;
        {
            Run run(c, t, t.len);
            nyre::Match m;
            int64_t pos = 0, last = 0;
            bool adv = false;
            while ((count == 0 || nsub < count) && pos <= t.len) {
                if (!run.exec(pos, nyre::SEARCH, adv, m)) break;
                int64_t b = m.spans[0], e = m.spans[1];
                if (last < b) out += t.slice(last, b);
                for (auto& it : tpl) {
                    if (it.group < 0) out += it.text;
                    else {
                        int64_t ga = m.spans[2 * (size_t)it.group], gb = m.spans[2 * (size_t)it.group + 1];
                        if (ga >= 0 && gb >= 0) out += t.slice(ga, gb);
                    }
                }
                last = e;
                nsub++;
                adv = e == b;
                pos = e;
            }
            if (last < t.len) out += t.slice(last, t.len);
        }
        return E.makeListValue({text_value(E, t, std::move(out)), nyos::make_int(nsub)});
    }

    Text t;
    if (args.size() < 3) fail("TypeError", name + "() needs a string");
    check_kind(E, c, args[2], t);

    if (name == "_re_exec") {
        int64_t pos = int_arg(args, 3, 0), endpos = int_arg(args, 4, t.len);
        int64_t mode = int_arg(args, 5, 0);
        clip(t.len, pos, endpos);
        if (pos > endpos) return NONE_VALUE;
        Run run(c, t, endpos);
        nyre::Match m;
        if (!run.exec(pos, (nyre::Mode)mode, false, m)) return NONE_VALUE;
        return match_value(E, c, t, m);
    }
    if (name == "_re_scan") {
        int64_t pos = int_arg(args, 3, 0), endpos = int_arg(args, 4, t.len);
        int64_t limit = int_arg(args, 5, 0);
        bool adv = args.size() > 6 && args[6].isTrue();
        clip(t.len, pos, endpos);
        std::vector<nyre::Match> ms;
        if (pos <= endpos) {
            Run run(c, t, endpos);
            nyre::Match m;
            while ((limit <= 0 || (int64_t)ms.size() < limit) && pos <= endpos) {
                if (!run.exec(pos, nyre::SEARCH, adv, m)) break;
                adv = m.spans[1] == m.spans[0];
                pos = m.spans[1];
                ms.push_back(m);
            }
        }
        std::vector<Value> items;
        items.reserve(ms.size());
        for (auto& m : ms) items.push_back(match_value(E, c, t, m));
        return E.makeListValue(items);
    }
    if (name == "_re_findall") {
        int64_t pos = int_arg(args, 3, 0), endpos = int_arg(args, 4, t.len);
        clip(t.len, pos, endpos);
        std::vector<Value> items;
        if (pos <= endpos) {
            std::vector<nyre::Match> ms;
            {
                Run run(c, t, endpos);
                nyre::Match m;
                bool adv = false;
                while (pos <= endpos) {
                    if (!run.exec(pos, nyre::SEARCH, adv, m)) break;
                    adv = m.spans[1] == m.spans[0];
                    pos = m.spans[1];
                    ms.push_back(m);
                }
            }
            items.reserve(ms.size());
            for (auto& m : ms) {
                if (c.groups == 0) items.push_back(text_value(E, t, t.slice(m.spans[0], m.spans[1])));
                else if (c.groups == 1) items.push_back(text_value(E, t, t.slice(m.spans[2], m.spans[3])));
                else {
                    std::vector<Value> g;
                    for (int i = 1; i <= c.groups; i++)
                        g.push_back(text_value(E, t, t.slice(m.spans[2 * (size_t)i], m.spans[2 * (size_t)i + 1])));
                    items.push_back(re_tuple(E, g));
                }
            }
        }
        return E.makeListValue(items);
    }
    if (name == "_re_split") {
        int64_t maxsplit = int_arg(args, 3, 0);
        std::vector<nyre::Match> ms;
        {
            Run run(c, t, t.len);
            nyre::Match m;
            int64_t pos = 0;
            bool adv = false;
            while ((maxsplit == 0 || (int64_t)ms.size() < maxsplit) && pos <= t.len) {
                if (!run.exec(pos, nyre::SEARCH, adv, m)) break;
                adv = m.spans[1] == m.spans[0];
                pos = m.spans[1];
                ms.push_back(m);
            }
        }
        std::vector<Value> items;
        items.reserve(ms.size() * (size_t)(c.groups + 1) + 1);
        int64_t last = 0;
        for (auto& m : ms) {
            items.push_back(text_value(E, t, t.slice(last, m.spans[0])));
            for (int g = 1; g <= c.groups; g++) {
                int64_t ga = m.spans[2 * (size_t)g], gb = m.spans[2 * (size_t)g + 1];
                items.push_back(ga < 0 || gb < 0 ? NONE_VALUE : text_value(E, t, t.slice(ga, gb)));
            }
            last = m.spans[1];
        }
        items.push_back(text_value(E, t, t.slice(last, t.len)));
        return E.makeListValue(items);
    }
    if (name == "_re_pieces") {
        int64_t count = int_arg(args, 3, 0);
        std::vector<nyre::Match> ms;
        {
            Run run(c, t, t.len);
            nyre::Match m;
            int64_t pos = 0;
            bool adv = false;
            while ((count == 0 || (int64_t)ms.size() < count) && pos <= t.len) {
                if (!run.exec(pos, nyre::SEARCH, adv, m)) break;
                adv = m.spans[1] == m.spans[0];
                pos = m.spans[1];
                ms.push_back(m);
            }
        }
        std::vector<Value> items;
        items.reserve(2 * ms.size() + 1);
        int64_t last = 0;
        for (auto& m : ms) {
            items.push_back(text_value(E, t, t.slice(last, m.spans[0])));
            items.push_back(match_value(E, c, t, m));
            last = m.spans[1];
        }
        items.push_back(text_value(E, t, t.slice(last, t.len)));
        return E.makeListValue(items);
    }
    return NONE_VALUE;
}
