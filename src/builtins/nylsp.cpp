// builtins/nylsp.cpp - the native half of lib/nylsp, the Language Server
// (round 86). One entry point, nylsp::call (include/builtins/nylsp.hpp),
// which the builtin `_ny_lsp(op, args...)` reaches (src/builtins/text.cpp).
//
// What lives here, and why it is native: the server answers completion and
// hover on every keystroke, and the interpreter spends ~1 us a statement,
// so everything that walks a document - its text, its tokens, its tree,
// its bindings - is done here and kept between requests; the server asks
// small questions and gets small answers (JSON text).
//
//   documents      a piece table per document (two buffers, a list of
//                  pieces each knowing its line breaks - VS Code's piece
//                  tree without the tree): an edit is list surgery, a line
//                  is found by summing line-break counts; positions are
//                  taken and given in the client's encoding (UTF-16 code
//                  units by default, UTF-8 or UTF-32 when negotiated)
//   analysis       the real parser twice: the engines' own parse (its
//                  SyntaxError, NyScope's const / nonlocal errors and its
//                  Nython-vs-Python rule report) and the ast-mode parse
//                  (Python's tree shape with token spans, no desugaring),
//                  over which the binding analysis runs: scopes, symbols,
//                  every occurrence of a name tied to its symbol by
//                  Nython's rule (.ny: a plain assignment rebinds the
//                  nearest binding) or Python's (.py, `# nython: python`:
//                  a name a function binds is its local) - NyScope's
//                  rules, so a rename follows what the engines will bind
//   recovery       when the source does not parse, error recovery by the
//                  indentation structure (island parsing): the statement
//                  around the error is cut out and replaced, keeping the
//                  line count, by `pass` - or `if 1:` when an indented
//                  block follows, so that block stays an island of its own
//                  - and the parse is tried again (10 times at most); each
//                  cut is a diagnostic, everything around it is analysed
//   queries        symbols, semantic tokens (+ delta), the occurrence at a
//                  position, a symbol's references, names visible at a
//                  position, a class's members, call sites, the call
//                  around a position, the completion context, folding
//                  extras, a module's exports and imports
#include "platform_compat.hpp"
// The records below are plain structs with default member initializers;
// -Weffc++ would ask each implicit constructor for an initializer list.
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Weffc++"
#endif
#include <algorithm>
#include <chrono>
#include <cstring>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include "Parser.hpp"
#include "Lexer.hpp"
#include "SourceCode.hpp"
#include "Except.hpp"
#include "Script.hpp"
#include "ASTNodes.hpp"
#include "NyScope.hpp"
#include "NyJson.hpp"
#include "builtins/nylsp.hpp"

using namespace nython;
using namespace nython::lexer;
using namespace nython::parser;
using namespace nython::node;

namespace {

// ── text ─────────────────────────────────────────────────────────────────────
inline bool u8cont(unsigned char c) { return (c & 0xC0) == 0x80; }
inline int u8len(unsigned char c) { return c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1; }
inline bool id_start(unsigned char c) { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80; }
inline bool id_char(unsigned char c) { return id_start(c) || (c >= '0' && c <= '9'); }

bool is_word(const std::string& s) {
    if (s.empty() || !id_start((unsigned char)s[0])) return false;
    for (unsigned char c : s) if (!id_char(c)) return false;
    return true;
}

void split_lines(const std::string& s, std::vector<std::string>& out) {
    out.clear();
    size_t i = 0;
    while (true) {
        size_t j = s.find('\n', i);
        std::string ln = s.substr(i, j == std::string::npos ? std::string::npos : j - i);
        if (!ln.empty() && ln.back() == '\r') ln.pop_back();
        out.push_back(std::move(ln));
        if (j == std::string::npos) break;
        i = j + 1;
    }
}

long long to_ll(const std::string& s, long long d = 0) {
    if (s.empty()) return d;
    try { return std::stoll(s); } catch (...) { return d; }
}

// ── position encodings (LSP 3.17 PositionEncodingKind) ──────────────────────
enum class Enc { U8, U16, U32 };
Enc g_enc = Enc::U16;

// the code units character `cp_first_byte` takes in the encoding
inline int units(const unsigned char* p, Enc e) {
    int n = u8len(*p);
    if (e == Enc::U8) return n;
    if (e == Enc::U32) return 1;
    return n == 4 ? 2 : 1;
}
// byte offset in `ln` of column `col` (code units of `e`); the end of the
// line when past it, and the start of a character a column falls inside
size_t byte_of_col(const std::string& ln, long long col, Enc e) {
    if (col <= 0) return 0;
    size_t i = 0;
    long long c = 0;
    while (i < ln.size()) {
        int w = units((const unsigned char*)ln.data() + i, e);
        if (c + w > col) return i;
        c += w;
        i += (size_t)u8len((unsigned char)ln[i]);
        if (c >= col) return std::min(i, ln.size());
    }
    return ln.size();
}
long long col_of_byte(const std::string& ln, size_t b, Enc e) {
    if (e == Enc::U8) return (long long)std::min(b, ln.size());
    long long c = 0;
    size_t i = 0;
    while (i < ln.size() && i < b) {
        c += units((const unsigned char*)ln.data() + i, e);
        i += (size_t)u8len((unsigned char)ln[i]);
    }
    return c;
}
// code point index <-> byte offset
size_t byte_of_cp(const std::string& ln, long long cp) {
    size_t i = 0;
    long long c = 0;
    while (i < ln.size() && c < cp) { i += (size_t)u8len((unsigned char)ln[i]); c++; }
    return std::min(i, ln.size());
}
long long cp_of_byte(const std::string& ln, size_t b) {
    long long c = 0;
    for (size_t i = 0; i < ln.size() && i < b; i++) if (!u8cont((unsigned char)ln[i])) c++;
    return c;
}
inline bool ascii(const std::string& s) {
    for (unsigned char c : s) if (c >= 0x80) return false;
    return true;
}

// ── JSON output ──────────────────────────────────────────────────────────────
// j.obj().key("a").num(1).key("b").arr().num(1).end_arr().end_obj()
struct J {
    std::string s;
    std::vector<char> need;   // per open container: an item was written (a comma is due)
    bool after_key = false;
    void pre() {
        if (after_key) { after_key = false; return; }
        if (!need.empty()) { if (need.back()) s += ','; need.back() = 1; }
    }
    J& obj() { pre(); s += '{'; need.push_back(0); return *this; }
    J& end_obj() { s += '}'; need.pop_back(); return *this; }
    J& arr() { pre(); s += '['; need.push_back(0); return *this; }
    J& end_arr() { s += ']'; need.pop_back(); return *this; }
    J& key(const char* k) { pre(); nyjson::quote_to(s, k); s += ':'; after_key = true; return *this; }
    J& str(const std::string& v) { pre(); nyjson::quote_to(s, v); return *this; }
    J& num(long long v) { pre(); s += std::to_string(v); return *this; }
    J& boolean(bool v) { pre(); s += v ? "true" : "false"; return *this; }
    J& null() { pre(); s += "null"; return *this; }
    J& raw(const std::string& v) { pre(); s += v; return *this; }
};

// ── the piece table ──────────────────────────────────────────────────────────
struct PieceTable {
    std::string orig, add;
    struct Piece { bool in_add; size_t start, len, lf; };
    std::vector<Piece> ps;
    mutable std::string text_;
    mutable bool text_ok = false;
    size_t total = 0, lfs = 0;

    const char* data(const Piece& p) const { return (p.in_add ? add.data() : orig.data()) + p.start; }
    static size_t count_lf(const char* d, size_t n) { size_t k = 0; for (size_t i = 0; i < n; i++) if (d[i] == '\n') k++; return k; }

    void reset(const std::string& t) {
        orig = t;
        add.clear();
        ps.clear();
        if (!t.empty()) ps.push_back({false, 0, t.size(), count_lf(t.data(), t.size())});
        total = t.size();
        lfs = ps.empty() ? 0 : ps[0].lf;
        text_ = t;
        text_ok = true;
    }
    const std::string& text() const {
        if (!text_ok) {
            text_.clear();
            text_.reserve(total);
            for (auto& p : ps) text_.append(data(p), p.len);
            text_ok = true;
        }
        return text_;
    }
    size_t line_count() const { return lfs + 1; }
    // the byte offset where line `n` starts (the end when past the last)
    size_t line_start(size_t n) const {
        if (n == 0) return 0;
        size_t off = 0, seen = 0;
        for (auto& p : ps) {
            if (seen + p.lf >= n) {
                const char* d = data(p);
                for (size_t i = 0; i < p.len; i++)
                    if (d[i] == '\n' && ++seen == n) return off + i + 1;
            }
            seen += p.lf;
            off += p.len;
        }
        return total;
    }
    std::string line(size_t n) const {
        if (text_ok) {
            size_t b = line_start(n);
            size_t e = text_.find('\n', b);
            std::string s = text_.substr(b, e == std::string::npos ? std::string::npos : e - b);
            if (!s.empty() && s.back() == '\r') s.pop_back();
            return s;
        }
        size_t b = line_start(n);
        std::string out;
        size_t off = 0;
        for (auto& p : ps) {
            if (off + p.len <= b) { off += p.len; continue; }
            const char* d = data(p);
            size_t i = b > off ? b - off : 0;
            for (; i < p.len; i++) {
                if (d[i] == '\n') {
                    if (!out.empty() && out.back() == '\r') out.pop_back();
                    return out;
                }
                out += d[i];
            }
            off += p.len;
        }
        if (!out.empty() && out.back() == '\r') out.pop_back();
        return out;
    }
    // split the piece list so that a piece starts at `off`; its index
    size_t split(size_t off) {
        size_t pos = 0;
        for (size_t i = 0; i < ps.size(); i++) {
            if (off == pos) return i;
            if (off < pos + ps[i].len) {
                Piece a = ps[i];
                size_t k = off - pos;
                Piece b{a.in_add, a.start + k, a.len - k, 0};
                a.len = k;
                a.lf = count_lf(data(a), a.len);
                b.lf = ps[i].lf - a.lf;
                ps[i] = a;
                ps.insert(ps.begin() + (long)i + 1, b);
                return i + 1;
            }
            pos += ps[i].len;
        }
        return ps.size();
    }
    void replace(size_t off, size_t len, const std::string& s) {
        if (off > total) off = total;
        if (off + len > total) len = total - off;
        size_t i = split(off);
        size_t j = split(off + len);
        size_t gone = 0, gone_lf = 0;
        for (size_t k = i; k < j; k++) { gone += ps[k].len; gone_lf += ps[k].lf; }
        ps.erase(ps.begin() + (long)i, ps.begin() + (long)j);
        if (!s.empty()) {
            Piece p{true, add.size(), s.size(), count_lf(s.data(), s.size())};
            add += s;
            // typing: grow the piece just before when it ends where the add buffer did
            if (i > 0 && ps[i - 1].in_add && ps[i - 1].start + ps[i - 1].len == p.start) {
                ps[i - 1].len += p.len;
                ps[i - 1].lf += p.lf;
            } else ps.insert(ps.begin() + (long)i, p);
            lfs += p.lf;
        }
        total = total - gone + s.size();
        lfs -= gone_lf;
        text_ok = false;
        if (ps.size() > 2000) reset(text());   // compaction: one piece again
    }
};

// ── documents ────────────────────────────────────────────────────────────────
struct Analysis;

struct Doc {
    PieceTable pt;
    std::string path;          // the file (module resolution, the binding rule)
    bool python = false;       // Python-language source (NyScope's python_source)
    bool python_forced = false;
    long long edits = 0;       // edits since opened
    std::shared_ptr<Analysis> an;
    bool dirty = true;
    // edits since the last analysis that stayed inside one line each (none
    // added or removed a line): completion can use that analysis with the
    // edited lines' text (analysis_typing)
    bool same_lines = true;
    std::set<long long> typed_rows;
    long long generation = 0;   // full analyses so far (what a cache of answers keys on)
    // semantic tokens sent last (for /delta)
    std::vector<uint32_t> last_tokens;
    long long last_tokens_id = 0;
};

std::map<long long, std::unique_ptr<Doc>> g_docs;
long long g_next_doc = 1;
long long g_result_ids = 0;
// builtin names (the server's): name -> kind letter ('f' function, 'c' class, 'v' value)
std::unordered_map<std::string, char> g_builtins;

Doc& doc_of(const std::vector<std::string>& a, size_t i = 1) {
    long long h = i < a.size() ? to_ll(a[i], -1) : -1;
    auto it = g_docs.find(h);
    if (it == g_docs.end()) throw std::runtime_error("no such document: " + (i < a.size() ? a[i] : std::string()));
    return *it->second;
}

bool doc_python(const Doc& d) {
    if (d.python_forced) return d.python;
    return nython::scope::python_source(d.path.empty() ? std::string("<doc>.ny") : d.path, d.pt.text());
}

// ── the analysis ─────────────────────────────────────────────────────────────
// A token of the analysed text: 0-based rows and code-point columns, the
// end exclusive.
struct Tk {
    uint32_t row = 0, col = 0, erow = 0, ecol = 0;
    TokenType type = TokenType::Invalid;
    TokenClass cls = TokenClass::Default;
    std::string val;
    bool extra = false;   // not one of the lexer's (an f-string field's, a ${name})
};

// Symbol kinds:
//   v variable   k constant   p parameter   f function   M method   c class
//   m module (import x)   n imported name (from m import n)   F field (self.x)
//   A class attribute   e enum   E enum member   I interface   N namespace
//   u a member read on a class of this file that nothing here defines
struct Sym {
    std::string name;
    int scope = -1;        // the scope it belongs to (members: the class scope)
    char kind = 'v';
    int tok = -1;          // the defining occurrence's token (-1: not in the source)
    int s0 = -1, s1 = -1;  // the defining statement's token span
    int body = -1;         // def / class / lambda: the scope of its body
    std::string detail;    // def: "(a, b=1) -> int"; class: "(Base)"
    std::string doc;
    std::string imod, iname;   // m: imod = the module ("a.b"); n: from imod import iname
    int ilevel = 0;
    bool member = false, is_const = false, is_async = false, is_static = false, is_classm = false,
         is_property = false, generator = false, decl_var = false;
    std::vector<std::string> params;   // def: each parameter as written ("*args", "b=1", "x: int")
    std::vector<std::string> pnames;   // ... and its name ("args", "b", "x"); "*" / "/" markers kept
    std::string returns;               // def: the return annotation's text
    Node* value = nullptr;             // the value its definition binds (an assignment's right side)
    int value_scope = -1;
    Node* annotation = nullptr;        // a parameter's / annotated name's annotation
    int ann_scope = -1;
    std::vector<int> bases;            // class: base classes of this file (symbols)
    std::vector<Node*> base_nodes;
    std::vector<std::string> base_texts;
    int ty_state = 0;                  // type inference: 0 not yet, 1 in progress, 2 done
    struct TyV { char k = 0; int sym = -1; std::string text; } ty;
};

struct Scope {
    char kind = 'm';     // m module, f function, l lambda, c class, q comprehension
    int parent = -1;
    int owner = -1;      // the def / class symbol whose body it is
    bool py = false;     // Python's binding rule
    int t0 = -1, t1 = -1;   // the token span it covers
    uint32_t r0 = 0, r1 = 0, indent = 0;
    struct Decl { int tok; char kind; };
    std::map<std::string, Decl> declared;       // var/let/const, params, def, class, import, targets
    std::map<std::string, int> assigned;        // plain assignment targets (first token)
    std::map<std::string, int> globals, nonlocals;
    std::set<std::string> comp_walrus;
    std::map<std::string, int> syms;            // name -> symbol, after resolution
    std::map<std::string, int> members;         // a class: methods, class attributes, fields
    int self_sym = -1;                          // a method: its first parameter
    int cls = -1;                               // a method: the class scope it is in
    bool has_star_import = false;
};

struct Ev {          // a name read or written
    int scope;
    std::string name;
    int tok;
    char how;        // r read, a assign, l a local form (for/with/except target, walrus), x del, d declaration
    char kind;       // for declarations / writes: the symbol kind it makes
    Node* value = nullptr;   // the value written (assignments, var declarations)
    int loop = -1;           // the innermost loop around it
    int s0 = -1, s1 = -1;    // the statement's span
    bool aug = false;
};

struct AttrEv {      // obj.attr
    int scope;
    Node* obj;
    std::string attr;
    int tok;
    bool store;
    Node* value = nullptr;
};

struct CallSite {
    int scope;
    Node* callee;
    int lp = -1, rp = -1;                  // the parentheses' tokens
    struct Arg { int tok; std::string kw; int kwtok = -1; char star = 0; };
    std::vector<Arg> args;
};

struct Import {
    int sym = -1;          // the name it binds (-1: none - a star or quoted import)
    std::string module;    // as written, dots of a relative import included
    std::string name;      // from-import: the name ("*" for a star)
    std::string alias;
    int level = 0;
    bool from = false, quoted = false;
    int mod_t0 = -1, mod_t1 = -1;   // the module's tokens
    int name_tok = -1, alias_tok = -1;
    int stmt0 = -1, stmt1 = -1;
};

struct Diag { uint32_t r0, c0, r1, c1; int severity; std::string code, message; };

struct Analysis {
    std::string text;                 // the text analysed
    std::vector<std::string> lines;
    std::vector<char> line_ascii;
    std::vector<char> patched;        // per line: cut out by error recovery
    std::vector<Tk> toks;
    size_t nlex = 0;                  // the lexer's tokens (the rest are extras)
    std::vector<Scope> scopes;
    std::vector<Sym> syms;
    std::vector<int> occ;             // per token: its symbol (-1)
    std::vector<char> role;           // per token: d definition, w write, r read, x del
    std::vector<AttrEv> attrs;
    std::vector<int> attr_of_tok;     // per token: its attribute event (-1)
    std::vector<CallSite> calls;
    std::vector<Import> imports;
    std::vector<Ev> unresolved;       // reads bound nowhere (not builtins)
    std::vector<Diag> diags;
    // rk: 'M' an attribute of an imported module (recv: the import's symbol,
    // path: the attributes between, "a.b" for m.a.b.attr), 'X' of a name
    // imported from a module (a class, an instance of one), 'C' a member of
    // a class of this file that nothing here defines (recv: the class)
    struct Ext { int tok; int recv; std::string attr; bool store; std::string path; char rk; };
    std::vector<Ext> ext;             // attributes of imported modules / classes
    std::vector<std::pair<int, int>> loops;   // token spans of loops
    std::vector<int> decorator_toks;
    bool python = false;
    int recoveries = 0;
    // the resolution's tables, kept for the queries
    std::vector<std::set<std::string>> pyl;   // Python's rule: a function's locals
    std::map<int, int> self_cls;              // a method's self symbol -> its class scope
    std::map<int, int> cls_param;             // a classmethod's cls symbol -> its class scope
    double ms_parse = 0, ms_total = 0, ms_engine = 0, ms_walk = 0, ms_resolve = 0, ms_checks = 0;
    bool engine_done = false;
    std::string work_text, fname;   // the text that parsed (after recovery), its file name
    std::string module_doc;
    // the parse, kept: the tree's nodes are referred to (Sym::value ...)
    std::unique_ptr<SourceCode> src;
    std::unique_ptr<Reporter> rep;
    std::unique_ptr<Lexer> lex;
    std::unique_ptr<Parser> parser;
    node_ptr root;
};

// the symbol `name` has in scope s (made when it has none)
int new_sym(Analysis& A, int s, const std::string& name, char kind, int tok) {
    auto it = A.scopes[(size_t)s].syms.find(name);
    if (it != A.scopes[(size_t)s].syms.end()) return it->second;
    Sym y;
    y.name = name;
    y.scope = s;
    y.kind = kind;
    y.tok = tok;
    A.syms.push_back(y);
    int id = (int)A.syms.size() - 1;
    A.scopes[(size_t)s].syms[name] = id;
    return id;
}

// ── walking the ast-mode tree ────────────────────────────────────────────────
struct Walker {
    Analysis& A;
    Parser& P;
    std::vector<Ev> evs;
    int loop = -1;
    std::vector<int> loop_stack;

    Walker(Analysis& a, Parser& p) : A(a), P(p) {}

    // token helpers
    int span0(const Node* n) const {
        auto it = P.ast_spans_.find(n);
        return it == P.ast_spans_.end() ? -1 : tix(it->second.first);
    }
    int span1(const Node* n) const {
        auto it = P.ast_spans_.find(n);
        return it == P.ast_spans_.end() ? -1 : tix(it->second.second);
    }
    // a span's token index in A.toks (the parser's extras follow the lexer's)
    int tix(int i) const {
        if (i >= Parser::kAstExtra) {
            size_t k = (size_t)(i - Parser::kAstExtra);
            return k < P.ast_extra_toks_.size() ? (int)(A.nlex + k) : -1;
        }
        return i >= 0 && i < (int)A.nlex ? i : -1;
    }
    // the lexer token starting at a node's token's location
    int at_loc(const Token& t) const {
        if (t.line() <= 0) return -1;
        uint32_t r = (uint32_t)t.line() - 1, c = (uint32_t)std::max(1, t.column()) - 1;
        size_t lo = 0, hi = A.nlex;
        while (lo < hi) {
            size_t mid = (lo + hi) / 2;
            const Tk& m = A.toks[mid];
            if (m.row < r || (m.row == r && m.col < c)) lo = mid + 1; else hi = mid;
        }
        if (lo < A.nlex && A.toks[lo].row == r && A.toks[lo].col == c) return (int)lo;
        return -1;
    }
    bool name_tok_ok(int i, const std::string& name) const {
        return i >= 0 && i < (int)A.toks.size() && A.toks[(size_t)i].val == name && is_word(name);
    }
    // the token of `name` that node n stands for (-1: the parser made it)
    int name_tok(const Node* n, const std::string& name) const {
        if (!n || name.empty()) return -1;
        // the node's own token first: a span recorded around a lookahead
        // can start at an earlier token of the same name
        int e = at_loc(n->tok());
        if (name_tok_ok(e, name)) return e;
        int s0 = span0(n);
        if (name_tok_ok(s0, name)) return s0;
        if (s0 >= 0) {
            int s1 = span1(n);
            for (int i = s0; i <= s1 && i < s0 + 64; i++) if (name_tok_ok(i, name)) return i;
        }
        return -1;
    }
    // the first token of `name` in [from, to] (to < 0: 64 tokens on)
    int find_tok(int from, int to, const std::string& name) const {
        if (from < 0) return -1;
        if (to < 0) to = from + 64;
        for (int i = from; i <= to && i < (int)A.toks.size(); i++) if (name_tok_ok(i, name)) return i;
        return -1;
    }
    int last_tok(int from, int to, const std::string& name) const {
        if (from < 0) return -1;
        for (int i = to; i >= from; i--) if (name_tok_ok(i, name)) return i;
        return -1;
    }
    int node_t0(const Node* n) const {
        int s = span0(n);
        return s >= 0 ? s : at_loc(const_cast<Node*>(n)->tok());
    }

    // scopes
    int new_scope(char kind, int parent, int t0, int t1) {
        Scope s;
        s.kind = kind;
        s.parent = parent;
        s.py = parent >= 0 ? A.scopes[(size_t)parent].py : A.python;
        s.t0 = t0;
        s.t1 = t1;
        A.scopes.push_back(s);
        return (int)A.scopes.size() - 1;
    }
    Scope& S(int s) { return A.scopes[(size_t)s]; }

    void ev(int s, const std::string& name, int tok, char how, char kind = 'v', Node* value = nullptr,
            int s0 = -1, int s1 = -1, bool aug = false) {
        if (name.empty()) return;
        Ev e{s, name, tok, how, kind, value, loop, s0, s1, aug};
        evs.push_back(e);
        Scope& sc = S(s);
        if (how == 'd' || how == 'l') sc.declared.try_emplace(name, Scope::Decl{tok, how == 'l' ? 't' : kind});
        else if (how == 'a') sc.assigned.try_emplace(name, tok);
        else if (how == 'x') sc.assigned.try_emplace(name, tok);
    }

    static std::string bare(std::string n) { while (!n.empty() && n[0] == '*') n.erase(0, 1); return n; }

    // ── expressions ──
    void exprs(const std::vector<node_ptr>& v, int s) { for (auto& n : v) expr(n.get(), s); }

    // how deep the walk is: a tree deeper than this (`a + a + ... ` with
    // thousands of terms) is not followed further, the C++ stack is not
    // the tree's
    int depth = 0;
    struct Deeper {
        int& d;
        explicit Deeper(int& x) : d(x) { d++; }
        ~Deeper() { d--; }
        Deeper(const Deeper&) = delete;
        Deeper& operator=(const Deeper&) = delete;
    };
    static constexpr int kMaxDepth = 2500;

    void expr(Node* n, int s) {
        if (!n || depth > kMaxDepth) return;
        Deeper deeper(depth);
        switch (n->type()) {
        case NodeType::VARIABLE: {
            auto* v = static_cast<VariableNode*>(n);
            ev(s, v->name, name_tok(n, v->name), 'r');
            return;
        }
        case NodeType::SELF: {
            const std::string& t = n->tok().value;
            std::string nm = t == "this" ? "this" : "self";
            ev(s, nm, name_tok(n, nm), 'r');
            return;
        }
        case NodeType::SUPER: ev(s, "super", name_tok(n, "super"), 'r'); return;
        case NodeType::STRING: interpolations(n, s); return;
        case NodeType::ATTRIBUTE: {
            auto* a = static_cast<AttributeNode*>(n);
            expr(a->object.get(), s);
            int tk = at_loc(n->tok());
            if (!name_tok_ok(tk, a->attr)) { int t1 = span1(n); tk = name_tok_ok(t1, a->attr) ? t1 : -1; }
            if (tk < 0) {   // after the object's last token
                int o1 = span1(a->object.get());
                if (o1 < 0) o1 = node_t0(a->object.get());
                tk = find_tok(o1 >= 0 ? o1 + 1 : -1, -1, a->attr);
            }
            attr_ev(s, a->object.get(), a->attr, tk, false);
            return;
        }
        case NodeType::SUBSCRIPT: {
            auto* x = static_cast<SubscriptNode*>(n);
            expr(x->object.get(), s); expr(x->index.get(), s);
            return;
        }
        case NodeType::CALL: call(static_cast<CallNode*>(n), s); return;
        case NodeType::KEYWORD_ARG: expr(static_cast<KeywordArgNode*>(n)->val.get(), s); return;
        case NodeType::UNARY: expr(static_cast<UnaryNode*>(n)->operand.get(), s); return;
        case NodeType::BINARY: {
            auto* b = static_cast<BinaryNode*>(n);
            expr(b->left.get(), s); expr(b->right.get(), s);
            return;
        }
        case NodeType::IF: {
            auto* i = static_cast<IfNode*>(n);
            expr(i->condition.get(), s); expr(i->then_branch.get(), s); expr(i->else_branch.get(), s);
            for (auto& e : i->elseif_branches) expr(e.get(), s);
            return;
        }
        case NodeType::LAMBDA: {
            auto* l = static_cast<LambdaNode*>(n);
            exprs(l->defaults, s);
            int ls = new_scope('l', s, span0(n), span1(n));
            for (auto& p : l->params) {
                if (!p) continue;
                std::string pn = bare(p->value());
                if (pn.empty() || pn == "/") continue;
                ev(ls, pn, name_tok(p.get(), pn), 'd', 'p');
            }
            expr(l->body.get(), ls);
            return;
        }
        case NodeType::COMPREHENSION: {
            auto* c = static_cast<ComprehensionNode*>(n);
            int cs = new_scope('q', s, span0(n), span1(n));
            bool first = true;
            for (auto& cl : c->clauses) {
                expr(cl.iter.get(), first ? s : cs);   // the first iterable is evaluated outside (Python)
                first = false;
                target(cl.target.get(), cs, 'l');
                for (auto& k : cl.conds) expr(k.get(), cs);
            }
            expr(c->elt.get(), cs); expr(c->value.get(), cs);
            return;
        }
        case NodeType::WALRUS: {
            auto* w = static_cast<WalrusNode*>(n);
            expr(w->init.get(), s);
            walrus(s, w->name, name_tok(n, w->name), w->init.get());
            return;
        }
        case NodeType::YIELD: case NodeType::YIELD_FROM: {
            mark_generator(s);
            expr(n->type() == NodeType::YIELD ? static_cast<YieldNode*>(n)->expr.get() : static_cast<YieldFromNode*>(n)->expr.get(), s);
            return;
        }
        case NodeType::MAP_ENTRY: {
            auto* e = static_cast<MapEntryNode*>(n);
            expr(e->key.get(), s); expr(e->val.get(), s);
            return;
        }
        case NodeType::SLICE: {
            auto* x = static_cast<SliceNode*>(n);
            expr(x->start.get(), s); expr(x->end_node.get(), s); expr(x->step.get(), s);
            return;
        }
        case NodeType::RANGE: {
            auto* x = static_cast<RangeNode*>(n);
            expr(x->start.get(), s); expr(x->end_node.get(), s); expr(x->step.get(), s);
            return;
        }
        case NodeType::OPT_CHAIN: {
            auto* o = static_cast<OptChainNode*>(n);
            expr(o->recv.get(), s);
            if (!o->name.empty()) {
                int r1 = span1(o->recv.get());
                if (r1 < 0) r1 = node_t0(o->recv.get());
                int tk = find_tok(r1 >= 0 ? r1 + 1 : node_t0(n), -1, o->name);
                attr_ev(s, o->recv.get(), o->name, tk, false);
            }
            expr(o->index.get(), s);
            if (o->call && o->call->type() == NodeType::CALL) {
                auto* c = static_cast<CallNode*>(o->call.get());
                for (auto& a : c->args) arg(a.get(), s);
            } else expr(o->call.get(), s);
            expr(o->rest.get(), s);
            return;
        }
        case NodeType::DYN_BINOP: {
            auto* d = static_cast<DynBinopNode*>(n);
            expr(d->lhs.get(), s); expr(d->rhs.get(), s);
            return;
        }
        case NodeType::COMPLEX: exprs(static_cast<ComplexNode*>(n)->items, s); return;
        case NodeType::PY_AST: pyexpr(static_cast<PyAstNode*>(n), s); return;
        case NodeType::FUNCTION: case NodeType::CLASS: stmt(n, s); return;
        case NodeType::CHAIN_HOLE: case NodeType::MACRO_CALL: return;
        default:
            for (auto& k : n->statements()) expr(k.get(), s);
            return;
        }
    }

    void pyexpr(PyAstNode* a, int s) {
        const std::string& k = a->kind;
        if (k == "NamedExpr") {
            Node* t = a->kidOf("target").get();
            expr(a->kidOf("value").get(), s);
            if (t && t->type() == NodeType::VARIABLE) {
                auto* v = static_cast<VariableNode*>(t);
                walrus(s, v->name, name_tok(t, v->name), a->kidOf("value").get());
            } else expr(t, s);
            return;
        }
        if (k == "keyword") {
            expr(a->kidOf("value").get(), s);
            return;
        }
        if (k == "JoinedStr") {
            // a Nython string with ${name}: its fields are located in the
            // field's own text, so they are found in the string's token
            interpolations(a, s);
            if (auto* parts = a->listOf("values"))
                for (auto& p : *parts) {
                    if (!p || p->type() != NodeType::PY_AST) continue;
                    auto* fv = static_cast<PyAstNode*>(p.get());
                    expr(fv->kidOf("value").get(), s);
                    node_ptr spec = fv->kidOf("format_spec");
                    if (spec) expr(spec.get(), s);
                }
            return;
        }
        if (k == "Await") { expr(a->kidOf("value").get(), s); return; }
        for (auto& c : a->statements()) expr(c.get(), s);
    }

    // a walrus binds in the function around the comprehensions it is in (PEP 572)
    void walrus(int s, const std::string& name, int tok, Node* value) {
        int t = s;
        while (t >= 0 && S(t).kind == 'q') t = S(t).parent;
        if (t < 0) t = s;
        if (t != s) S(t).comp_walrus.insert(name);
        ev(t, name, tok, 'l', 'v', value);
    }

    void mark_generator(int s) {
        int t = s;
        while (t >= 0 && (S(t).kind == 'q')) t = S(t).parent;
        if (t >= 0 && S(t).owner >= 0) A.syms[(size_t)S(t).owner].generator = true;
    }

    void arg(Node* a, int s) {
        if (!a) return;
        if (a->type() == NodeType::KEYWORD_ARG) expr(static_cast<KeywordArgNode*>(a)->val.get(), s);
        else if (a->type() == NodeType::PY_AST && static_cast<PyAstNode*>(a)->kind == "keyword") expr(static_cast<PyAstNode*>(a)->kidOf("value").get(), s);
        else expr(a, s);
    }

    void call(CallNode* c, int s) {
        expr(c->callee.get(), s);
        CallSite cs;
        cs.scope = s;
        cs.callee = c->callee.get();
        int c1 = span1(c->callee.get());
        if (c1 < 0) c1 = node_t0(c->callee.get());
        int e1 = span1(c);
        if (c1 >= 0) {
            for (int i = c1 + 1; i < (int)A.nlex && i < c1 + 4; i++)
                if (A.toks[(size_t)i].type == TokenType::ParenOpen) { cs.lp = i; break; }
        }
        if (e1 >= 0 && e1 < (int)A.nlex && A.toks[(size_t)e1].type == TokenType::ParenClose) cs.rp = e1;
        for (auto& an : c->args) {
            Node* a = an.get();
            if (!a) continue;
            CallSite::Arg g;
            g.tok = node_t0(a);
            if (a->type() == NodeType::KEYWORD_ARG) {
                auto* k = static_cast<KeywordArgNode*>(a);
                g.kw = k->name;
                g.kwtok = name_tok_ok(g.tok, k->name) ? g.tok : find_tok(g.tok, -1, k->name);
                if (g.kwtok >= 0) g.tok = g.kwtok;
            } else if (a->type() == NodeType::UNARY) {
                auto* u = static_cast<UnaryNode*>(a);
                if (u->op == "*" || u->op == "**") {
                    g.star = u->op == "*" ? 1 : 2;
                    int ot = node_t0(u->operand.get());
                    if (g.tok < 0 || (ot >= 0 && ot > 0 && g.tok >= ot)) g.tok = ot > 0 ? ot - 1 : ot;
                }
            }
            cs.args.push_back(g);
            arg(a, s);
        }
        A.calls.push_back(cs);
    }

    void attr_ev(int s, Node* obj, const std::string& attr, int tok, bool store, Node* value = nullptr) {
        AttrEv e{s, obj, attr, tok, store, value};
        A.attrs.push_back(e);
    }

    // `${name}` / `${a.b}` in a Nython string: reads at their place
    void interpolations(Node* n, int s) {
        int t = at_loc(n->tok());
        if (t < 0 || t >= (int)A.nlex) return;
        const Tk& k = A.toks[(size_t)t];
        if (k.type != TokenType::String || k.cls != TokenClass::Literal) return;
        for (uint32_t r = k.row; r <= k.erow && r < A.lines.size(); r++) {
            const std::string& ln = A.lines[r];
            size_t b0 = r == k.row ? byte_of_cp(ln, k.col) : 0;
            size_t b1 = r == k.erow ? byte_of_cp(ln, k.ecol) : ln.size();
            size_t p = ln.find("${", b0);
            while (p != std::string::npos && p < b1) {
                size_t q = p + 2;
                while (q < b1 && (ln[q] == ' ')) q++;
                size_t w0 = q;
                while (q < b1 && id_char((unsigned char)ln[q])) q++;
                if (q > w0 && id_start((unsigned char)ln[w0])) {
                    std::string nm = ln.substr(w0, q - w0);
                    Tk x;
                    x.row = x.erow = r;
                    x.col = (uint32_t)cp_of_byte(ln, w0);
                    x.ecol = (uint32_t)cp_of_byte(ln, q);
                    x.type = TokenType::Identifier;
                    x.val = nm;
                    x.extra = true;
                    A.toks.push_back(x);
                    ev(s, nm, (int)A.toks.size() - 1, 'r');
                }
                p = ln.find("${", q);
            }
        }
    }

    // ── targets ──
    void target(Node* t, int s, char how, Node* value = nullptr, int s0 = -1, int s1 = -1, bool aug = false) {
        if (!t) return;
        switch (t->type()) {
        case NodeType::VARIABLE: {
            auto* v = static_cast<VariableNode*>(t);
            std::string nm = bare(v->name);
            ev(s, nm, name_tok(t, nm), how, 'v', value, s0, s1, aug);
            return;
        }
        case NodeType::TUPLE: case NodeType::LIST: case NodeType::ARRAY:
            for (auto& e : t->statements()) target(e.get(), s, how, nullptr, s0, s1);
            return;
        case NodeType::UNARY: target(static_cast<UnaryNode*>(t)->operand.get(), s, how, nullptr, s0, s1); return;
        case NodeType::ATTRIBUTE: {
            auto* a = static_cast<AttributeNode*>(t);
            expr(a->object.get(), s);
            int tk = at_loc(t->tok());
            if (!name_tok_ok(tk, a->attr)) { int t1 = span1(t); tk = name_tok_ok(t1, a->attr) ? t1 : -1; }
            if (tk < 0) {
                int o1 = span1(a->object.get());
                if (o1 < 0) o1 = node_t0(a->object.get());
                tk = find_tok(o1 >= 0 ? o1 + 1 : -1, -1, a->attr);
            }
            if (aug) attr_ev(s, a->object.get(), a->attr, tk, false);
            attr_ev(s, a->object.get(), a->attr, tk, true, value);
            return;
        }
        case NodeType::SELF: {   // `self = ...` in a plain function binds it
            std::string nm = t->tok().value == "this" ? "this" : "self";
            ev(s, nm, name_tok(t, nm), how, 'v', value, s0, s1, aug);
            return;
        }
        case NodeType::PY_AST: {
            auto* p = static_cast<PyAstNode*>(t);
            if (p->kind == "Starred") { for (auto& c : p->statements()) target(c.get(), s, how, nullptr, s0, s1); return; }
            expr(t, s);
            return;
        }
        default:
            expr(t, s);
            return;
        }
    }

    // ── statements ──
    void block(Node* n, int s) {
        if (!n) return;
        NodeType t = n->type();
        if (t == NodeType::BLOCK || t == NodeType::STATEMENTS || t == NodeType::SCRIPT || t == NodeType::STATEMENT) {
            for (auto& c : n->statements()) stmt(c.get(), s);
            return;
        }
        stmt(n, s);
    }

    void push_loop(Node* n) {
        A.loops.push_back({span0(n), span1(n)});
        loop_stack.push_back(loop);
        loop = (int)A.loops.size() - 1;
    }
    void pop_loop() { loop = loop_stack.back(); loop_stack.pop_back(); }

    // the text of tokens [a, b] as written (one line; spaces where the source has them)
    std::string text_of(int a, int b) const {
        std::string out;
        if (a < 0 || b < a) return out;
        for (int i = a; i <= b && i < (int)A.nlex; i++) {
            const Tk& k = A.toks[(size_t)i];
            if (k.type == TokenType::NewLine || k.type == TokenType::Indent || k.type == TokenType::Dedent) continue;
            if (i > a) {
                const Tk& p = A.toks[(size_t)i - 1];
                if (p.erow != k.row || p.ecol != k.col) out += ' ';
            }
            out += source_of(k);
        }
        return out;
    }
    std::string source_of(const Tk& k) const {
        if (k.row >= A.lines.size()) return k.val;
        if (k.erow != k.row) {   // a multi-line string: its first line and an ellipsis
            const std::string& ln = A.lines[k.row];
            return ln.substr(byte_of_cp(ln, k.col)) + "...";
        }
        const std::string& ln = A.lines[k.row];
        size_t b0 = byte_of_cp(ln, k.col), b1 = byte_of_cp(ln, k.ecol);
        return b1 > b0 ? ln.substr(b0, b1 - b0) : k.val;
    }

    // a def's signature from its tokens: the parameters as written
    void signature(Sym& f, int name_tok_i, int stop) {
        if (name_tok_i < 0) return;
        int lp = -1;
        for (int i = name_tok_i + 1; i < (int)A.nlex && i <= name_tok_i + 2; i++)
            if (A.toks[(size_t)i].type == TokenType::ParenOpen) { lp = i; break; }
        if (lp < 0) { f.detail = "()"; return; }
        int depth = 0, rp = -1;
        std::vector<std::pair<int, int>> parts;
        int st = lp + 1;
        for (int i = lp; i < (int)A.nlex && (stop < 0 || i <= stop); i++) {
            TokenType t = A.toks[(size_t)i].type;
            if (t == TokenType::ParenOpen || t == TokenType::BracketOpen || t == TokenType::BraceOpen) depth++;
            else if (t == TokenType::ParenClose || t == TokenType::BracketClose || t == TokenType::BraceClose) {
                depth--;
                if (depth == 0) { if (i > st) parts.push_back({st, i - 1}); rp = i; break; }
            } else if (t == TokenType::Comma && depth == 1) { if (i > st) parts.push_back({st, i - 1}); st = i + 1; }
        }
        std::string d = "(";
        for (size_t k = 0; k < parts.size(); k++) {
            int a = parts[k].first, b = parts[k].second;
            while (a <= b && (A.toks[(size_t)a].type == TokenType::NewLine || A.toks[(size_t)a].type == TokenType::Indent || A.toks[(size_t)a].type == TokenType::Dedent)) a++;
            if (a > b) continue;
            std::string txt = text_of(a, b);
            // tighten "b = 1" to "b=1" when unannotated, as Python's reprs do
            std::string nm;
            for (int i = a; i <= b; i++) if (is_word(A.toks[(size_t)i].val) && A.toks[(size_t)i].type != TokenType::String) { nm = A.toks[(size_t)i].val; break; }
            const std::string& t0 = A.toks[(size_t)a].val;
            if (t0 == "*" && a == b) nm = "*";
            if (t0 == "/" && a == b) nm = "/";
            if (k) d += ", ";
            d += txt;
            f.params.push_back(txt);
            f.pnames.push_back(nm);
        }
        d += ")";
        if (rp >= 0 && rp + 1 < (int)A.nlex && A.toks[(size_t)rp + 1].type == TokenType::RightArrow) {
            int e = rp + 2;
            int depth2 = 0;
            while (e < (int)A.nlex) {
                TokenType t = A.toks[(size_t)e].type;
                if (t == TokenType::ParenOpen || t == TokenType::BracketOpen) depth2++;
                else if (t == TokenType::ParenClose || t == TokenType::BracketClose) depth2--;
                else if (t == TokenType::Colon && depth2 == 0) break;
                e++;
            }
            f.returns = text_of(rp + 2, e - 1);
            d += " -> " + f.returns;
        }
        f.detail = d;
    }

    struct Deco { bool st = false, cm = false, prop = false, setter = false; int t0 = -1; };

    void funcdef(FunctionNode* f, Node* n, int s, const Deco& dc) {
        // defaults and annotations are evaluated where the def is
        exprs(f->defaults, s);
        if (f->annotations && f->annotations->type() == NodeType::MAP)
            for (auto& e : static_cast<MapNode*>(f->annotations.get())->entries)
                expr(static_cast<MapEntryNode*>(e.get())->val.get(), s);
        int t0 = at_loc(n->tok()), t1 = span1(n);
        if (t0 < 0) t0 = span0(n);
        int nt = find_tok(t0, -1, f->name);
        bool in_class = S(s).kind == 'c';
        bool is_setter = dc.setter && in_class && S(s).syms.count(f->name);
        char kind = in_class ? 'M' : 'f';
        int fs = new_scope('f', s, t0, t1);
        // `def f(...):  # nython: python` opts a Nython function in (round 85)
        if (!S(fs).py && nt >= 0 && opts_in(A.toks[(size_t)nt].row)) S(fs).py = true;
        // (@x.setter / @x.deleter: the property's other accessor, the same member)
        ev(s, f->name, nt, 'd', kind, nullptr, dc.t0 >= 0 ? dc.t0 : t0, t1);
        int sym = make_sym(s, f->name, kind, nt);
        if (!is_setter) {
            Sym& y = A.syms[(size_t)sym];
            y.s0 = dc.t0 >= 0 ? dc.t0 : t0;
            y.s1 = t1;
            y.body = fs;
            y.doc = f->has_doc ? f->doc : std::string();
            y.is_async = f->is_async;
            y.is_static = dc.st;
            y.is_classm = dc.cm;
            y.is_property = dc.prop;
            signature(y, nt, t1);
        }
        S(fs).owner = sym;
        if (in_class) S(fs).cls = s;
        // parameters
        bool first = true;
        Node* ann_map = f->annotations.get();
        for (auto& p : f->params) {
            if (!p) continue;
            std::string raw = p->value();
            std::string pn = bare(raw);
            if (pn.empty() || pn == "/" ) continue;
            int pt = name_tok(p.get(), pn);
            if (pt < 0) pt = find_tok(t0, t1 >= 0 ? std::min(t1, t0 + 512) : -1, pn);
            ev(fs, pn, pt, 'd', 'p');
            int ps = make_sym(fs, pn, 'p', pt);
            if (ann_map && ann_map->type() == NodeType::MAP)
                for (auto& e : static_cast<MapNode*>(ann_map)->entries) {
                    auto* me = static_cast<MapEntryNode*>(e.get());
                    if (me->key && me->key->tok().value == pn) { A.syms[(size_t)ps].annotation = me->val.get(); A.syms[(size_t)ps].ann_scope = s; }
                }
            if (first && in_class && !dc.st && raw[0] != '*') S(fs).self_sym = ps;
            first = false;
        }
        block(f->body.get(), fs);
    }

    bool opts_in(uint32_t row) const {
        if (row >= A.lines.size()) return false;
        const std::string& ln = A.lines[row];
        size_t h = ln.find('#');
        while (h != std::string::npos) {
            size_t p = ln.find_first_not_of(" \t", h + 1);
            if (p != std::string::npos && ln.compare(p, 7, "nython:") == 0) {
                size_t w = ln.find_first_not_of(" \t", p + 7);
                if (w != std::string::npos && ln.compare(w, 6, "python") == 0) return true;
            }
            h = ln.find('#', h + 1);
        }
        return false;
    }

    void classdef(ClassNode* c, Node* n, int s, const Deco& dc) {
        for (auto& b : c->bases) expr(b.get(), s);
        for (auto& kv : c->keywords) {
            if (kv.second && kv.second->type() == NodeType::PY_AST) pyexpr(static_cast<PyAstNode*>(kv.second.get()), s);
            else expr(kv.second.get(), s);
        }
        int t0 = at_loc(n->tok()), t1 = span1(n);
        if (t0 < 0) t0 = span0(n);
        int nt = find_tok(t0, -1, c->name);
        ev(s, c->name, nt, 'd', 'c', nullptr, dc.t0 >= 0 ? dc.t0 : t0, t1);
        int sym = make_sym(s, c->name, 'c', nt);
        int cs = new_scope('c', s, t0, t1);
        Sym& y = A.syms[(size_t)sym];
        y.s0 = dc.t0 >= 0 ? dc.t0 : t0;
        y.s1 = t1;
        y.body = cs;
        y.doc = c->has_doc ? c->doc : std::string();
        for (auto& b : c->bases) {
            if (!b) continue;
            y.base_nodes.push_back(b.get());
            int b0 = node_t0(b.get()), b1 = span1(b.get());
            y.base_texts.push_back(b1 >= b0 && b0 >= 0 ? text_of(b0, b1) : b->value());
        }
        std::string d = "(";
        for (size_t i = 0; i < y.base_texts.size(); i++) { if (i) d += ", "; d += y.base_texts[i]; }
        y.detail = y.base_texts.empty() ? std::string() : d + ")";
        S(cs).owner = sym;
        block(c->body.get(), cs);
    }

    // a name's own symbol in scope s, made now (declarations: the walk
    // knows their details before the resolution runs)
    int make_sym(int s, const std::string& name, char kind, int tok) { return new_sym(A, s, name, kind, tok); }

    void import_stmt(PyAstNode* a, Node* n, int s) {
        bool from = a->kind == "ImportFrom";
        int t0 = span0(n), t1 = span1(n);
        const std::string* modp = a->strOf("module");
        std::string mod = modp ? *modp : std::string();
        int level = (int)a->numOf("level", 0);
        // the module's tokens: `from` [dots] a . b `import`
        int m0 = -1, m1 = -1;
        if (from && t0 >= 0) {
            int i = t0 + 1;
            while (i <= t1 && i < (int)A.nlex && (A.toks[(size_t)i].type == TokenType::Dot || A.toks[(size_t)i].type == TokenType::Interval || A.toks[(size_t)i].type == TokenType::Ellipsis)) i++;
            if (!mod.empty()) {
                m0 = i;
                while (i <= t1 && i < (int)A.nlex && A.toks[(size_t)i].type != TokenType::Import) i++;
                m1 = i - 1;
            }
        }
        if (auto* names = a->listOf("names"))
            for (auto& al : *names) {
                auto* aa = static_cast<PyAstNode*>(al.get());
                const std::string* nmp = aa->strOf("name");
                const std::string* asp = aa->strOf("asname");
                std::string nm = nmp ? *nmp : std::string();
                std::string as = asp ? *asp : std::string();
                int a0 = span0(al.get()), a1 = span1(al.get());
                Import im;
                im.from = from;
                im.level = level;
                im.stmt0 = t0; im.stmt1 = t1;
                if (from) {
                    im.module = std::string((size_t)level, '.') + mod;
                    im.name = nm;
                    im.mod_t0 = m0; im.mod_t1 = m1;
                    if (nm == "*") {
                        S(s).has_star_import = true;
                        A.imports.push_back(im);
                        continue;
                    }
                    im.name_tok = find_tok(a0, a1, nm);
                    im.alias = as;
                    if (!as.empty()) im.alias_tok = last_tok(a0, a1, as);
                    std::string bound = as.empty() ? nm : as;
                    int bt = as.empty() ? im.name_tok : im.alias_tok;
                    ev(s, bound, bt, 'd', 'n', nullptr, t0, t1);
                    int sym = make_sym(s, bound, 'n', bt);
                    Sym& y = A.syms[(size_t)sym];
                    if (y.kind == 'n' && y.imod.empty()) { y.imod = im.module; y.iname = nm; y.ilevel = level; y.s0 = t0; y.s1 = t1; }
                    im.sym = sym;
                } else {
                    // `import a.b.c` binds a; `import a.b as m` binds m (the module a.b);
                    // `import "path"` (Nython) runs the file in this scope
                    im.module = nm;
                    im.alias = as;
                    im.mod_t0 = a0;
                    im.mod_t1 = a0;
                    if (a0 >= 0) {
                        int i = a0;
                        while (i + 2 <= a1 && A.toks[(size_t)i + 1].type == TokenType::Dot) i += 2;
                        im.mod_t1 = i;
                    }
                    bool quoted = nm.find('/') != std::string::npos || nm.find('\\') != std::string::npos
                                  || (nm.size() > 3 && (nm.compare(nm.size() - 3, 3, ".ny") == 0 || nm.compare(nm.size() - 3, 3, ".py") == 0));
                    if (a0 >= 0 && a0 < (int)A.nlex && A.toks[(size_t)a0].type == TokenType::String) quoted = true;
                    im.quoted = quoted;
                    if (quoted && as.empty()) {
                        S(s).has_star_import = true;
                        A.imports.push_back(im);
                        continue;
                    }
                    std::string bound = as.empty() ? nm.substr(0, nm.find('.')) : as;
                    int bt = as.empty() ? (a0 >= 0 && name_tok_ok(a0, bound) ? a0 : -1) : last_tok(a0, a1, as);
                    if (!as.empty()) im.alias_tok = bt;
                    else im.name_tok = bt;
                    ev(s, bound, bt, 'd', 'm', nullptr, t0, t1);
                    int sym = make_sym(s, bound, 'm', bt);
                    Sym& y = A.syms[(size_t)sym];
                    if (y.kind == 'm' && y.imod.empty()) { y.imod = as.empty() ? bound : nm; y.s0 = t0; y.s1 = t1; }
                    im.sym = sym;
                }
                A.imports.push_back(im);
            }
    }

    void pattern(Node* n, int s) {
        if (!n || n->type() != NodeType::PY_AST) { expr(n, s); return; }
        auto* a = static_cast<PyAstNode*>(n);
        const std::string& k = a->kind;
        int p0 = span0(n), p1 = span1(n);
        if (k == "MatchValue") { expr(a->kidOf("value").get(), s); return; }
        if (k == "MatchSingleton") return;
        if (k == "MatchSequence" || k == "MatchOr") { if (auto* ps = a->listOf("patterns")) for (auto& p : *ps) pattern(p.get(), s); return; }
        if (k == "MatchStar") { if (auto* nm = a->strOf("name")) ev(s, *nm, last_tok(p0, p1, *nm), 'l'); return; }
        if (k == "MatchMapping") {
            if (auto* ks = a->listOf("keys")) exprs(*ks, s);
            if (auto* ps = a->listOf("patterns")) for (auto& p : *ps) pattern(p.get(), s);
            if (auto* r = a->strOf("rest")) ev(s, *r, last_tok(p0, p1, *r), 'l');
            return;
        }
        if (k == "MatchClass") {
            expr(a->kidOf("cls").get(), s);
            if (auto* ps = a->listOf("patterns")) for (auto& p : *ps) pattern(p.get(), s);
            if (auto* ps = a->listOf("kwd_patterns")) for (auto& p : *ps) pattern(p.get(), s);
            return;
        }
        if (k == "MatchAs") {
            node_ptr inner = a->kidOf("pattern");
            if (inner) pattern(inner.get(), s);
            if (auto* nm = a->strOf("name")) ev(s, *nm, last_tok(p0, p1, *nm), 'l');
            return;
        }
        for (auto& c : a->statements()) pattern(c.get(), s);
    }

    void stmt(Node* n, int s, const Deco* dc_in = nullptr) {
        if (!n || depth > kMaxDepth) return;
        Deeper deeper(depth);
        Deco dc;
        if (dc_in) dc = *dc_in;
        int t0 = span0(n), t1 = span1(n);
        switch (n->type()) {
        case NodeType::BLOCK: case NodeType::STATEMENTS: case NodeType::SCRIPT: case NodeType::STATEMENT:
            for (auto& c : n->statements()) stmt(c.get(), s);
            return;
        case NodeType::FUNCTION: funcdef(static_cast<FunctionNode*>(n), n, s, dc); return;
        case NodeType::CLASS: classdef(static_cast<ClassNode*>(n), n, s, dc); return;
        case NodeType::INTERFACE: case NodeType::NAMESPACE: {
            std::string nm = n->type() == NodeType::INTERFACE ? static_cast<InterfaceNode*>(n)->name : static_cast<NameSpaceNode*>(n)->name;
            Node* body = n->type() == NodeType::INTERFACE ? static_cast<InterfaceNode*>(n)->body.get() : static_cast<NameSpaceNode*>(n)->body.get();
            if (t0 < 0) t0 = at_loc(n->tok());
            int nt = find_tok(t0, -1, nm);
            char kind = n->type() == NodeType::INTERFACE ? 'I' : 'N';
            ev(s, nm, nt, 'd', kind, nullptr, t0, t1);
            int sym = make_sym(s, nm, kind, nt);
            int cs = new_scope('c', s, t0, t1);
            A.syms[(size_t)sym].s0 = t0; A.syms[(size_t)sym].s1 = t1; A.syms[(size_t)sym].body = cs;
            S(cs).owner = sym;
            block(body, cs);
            return;
        }
        case NodeType::ENUM: {
            auto* e = static_cast<EnumNode*>(n);
            if (t0 < 0) t0 = at_loc(n->tok());
            int nt = find_tok(t0, -1, e->name);
            ev(s, e->name, nt, 'd', 'e', nullptr, t0, t1);
            int sym = make_sym(s, e->name, 'e', nt);
            int cs = new_scope('c', s, t0, t1);
            A.syms[(size_t)sym].s0 = t0; A.syms[(size_t)sym].s1 = t1; A.syms[(size_t)sym].body = cs;
            S(cs).owner = sym;
            int from = nt >= 0 ? nt + 1 : t0;
            for (auto& it : e->items) {
                if (!it || it->type() != NodeType::ENUM_ITEM) continue;
                auto* ei = static_cast<EnumItemNode*>(it.get());
                expr(ei->value_node.get(), s);
                int it_t = name_tok(it.get(), ei->name);
                if (it_t < 0) it_t = find_tok(from, t1, ei->name);
                if (it_t >= 0) from = it_t + 1;
                int m = make_sym(cs, ei->name, 'E', it_t);
                A.syms[(size_t)m].member = true;
                A.syms[(size_t)m].value = ei->value_node.get();
                A.syms[(size_t)m].value_scope = s;
                if (it_t >= 0) evs.push_back(Ev{cs, ei->name, it_t, 'd', 'E', nullptr, -1, t0, t1, false});
            }
            return;
        }
        case NodeType::VARIABLE_DECL: {
            auto* v = static_cast<VarDeclNode*>(n);
            expr(v->init.get(), s);
            if (t0 < 0) t0 = at_loc(n->tok());
            int nt = name_tok(n, v->name);
            if (nt < 0) nt = find_tok(t0, t1, v->name);
            char kind = v->is_const ? 'k' : 'v';
            ev(s, v->name, nt, 'd', kind, v->init.get(), t0, t1);
            int sym = make_sym(s, v->name, kind, nt);
            Sym& y = A.syms[(size_t)sym];
            if (y.tok == nt) {
                y.is_const = v->is_const;
                y.decl_var = true;
                y.value = v->init.get();
                y.value_scope = s;
                y.s0 = t0; y.s1 = t1;
            }
            return;
        }
        case NodeType::ASSIGNMENT: {
            // x = y = v
            std::vector<Node*> targets;
            Node* v = n;
            while (v && v->type() == NodeType::ASSIGNMENT && v->tok().value != ":=") {
                auto* av = static_cast<AssignmentNode*>(v);
                targets.push_back(av->target.get());
                v = av->value_node.get();
            }
            expr(v, s);
            for (auto* t : targets) target(t, s, 'a', v, t0, t1);
            return;
        }
        case NodeType::ASSIGNMENT_AUG: {
            auto* a = static_cast<AugAssignNode*>(n);
            expr(a->value_node.get(), s);
            if (a->target && a->target->type() == NodeType::VARIABLE) {
                auto* tv = static_cast<VariableNode*>(a->target.get());
                int tk = name_tok(a->target.get(), tv->name);
                ev(s, tv->name, tk, 'r');
                ev(s, tv->name, tk, 'a', 'v', nullptr, t0, t1, true);
            } else target(a->target.get(), s, 'a', nullptr, t0, t1, true);
            return;
        }
        case NodeType::FOR: {
            auto* f = static_cast<ForNode*>(n);
            expr(f->iterable.get(), s);
            push_loop(n);
            target(f->var.get(), s, 'l', nullptr, t0, t1);
            for (auto& u : f->unpack_vars) target(u.get(), s, 'l', nullptr, t0, t1);
            block(f->body.get(), s);
            pop_loop();
            block(f->else_branch.get(), s);
            return;
        }
        case NodeType::WHILE: {
            auto* w = static_cast<WhileNode*>(n);
            push_loop(n);
            expr(w->condition.get(), s);
            block(w->body.get(), s);
            pop_loop();
            block(w->else_branch.get(), s);
            return;
        }
        case NodeType::REPEAT: {
            auto* r = static_cast<RepeatNode*>(n);
            expr(r->count.get(), s);
            push_loop(n);
            block(r->body.get(), s);
            pop_loop();
            return;
        }
        case NodeType::IF: {
            auto* i = static_cast<IfNode*>(n);
            if (i->is_expr) { expr(n, s); return; }
            expr(i->condition.get(), s);
            block(i->then_branch.get(), s);
            for (auto& e : i->elseif_branches) {
                if (!e) continue;
                if (e->type() == NodeType::IF) {
                    auto* ei = static_cast<IfNode*>(e.get());
                    expr(ei->condition.get(), s);
                    block(ei->then_branch.get(), s);
                    block(ei->else_branch.get(), s);
                } else block(e.get(), s);
            }
            block(i->else_branch.get(), s);
            return;
        }
        case NodeType::SWITCH: {
            auto* w = static_cast<SwitchNode*>(n);
            expr(w->subject.get(), s);
            for (auto& c : w->cases) stmt(c.get(), s);
            stmt(w->default_case.get(), s);
            return;
        }
        case NodeType::CASE: {
            auto* c = static_cast<CaseNode*>(n);
            expr(c->value_node.get(), s);
            block(c->body.get(), s);
            return;
        }
        case NodeType::DEFAULT: block(static_cast<DefaultNode*>(n)->body.get(), s); return;
        case NodeType::TRY: {
            auto* t = static_cast<TryNode*>(n);
            block(t->body.get(), s);
            for (auto& h : t->except_clauses) {
                if (!h) continue;
                if (h->type() == NodeType::PY_AST) {
                    auto* ha = static_cast<PyAstNode*>(h.get());
                    expr(ha->kidOf("type").get(), s);
                    if (const std::string* nm = ha->strOf("name")) {
                        int h0 = span0(h.get());
                        int hb = h0;
                        // the name after `as`, before the clause's colon
                        int found = -1;
                        for (int i = h0; i >= 0 && i < (int)A.nlex && i < h0 + 128; i++) {
                            if (A.toks[(size_t)i].type == TokenType::As && name_tok_ok(i + 1, *nm)) { found = i + 1; break; }
                            if (A.toks[(size_t)i].type == TokenType::Colon && i > hb) break;
                        }
                        ev(s, *nm, found, 'l');
                    }
                    block(ha->kidOf("body").get(), s);
                } else if (h->type() == NodeType::EXCEPT) {
                    auto* e = static_cast<ExceptNode*>(h.get());
                    if (!e->var.empty()) ev(s, e->var, find_tok(span0(h.get()), -1, e->var), 'l');
                    block(e->body.get(), s);
                } else block(h.get(), s);
            }
            block(t->else_clause.get(), s);
            block(t->finally_clause.get(), s);
            return;
        }
        case NodeType::WITH: {
            auto* w = static_cast<WithNode*>(n);
            expr(w->expr.get(), s);
            if (!w->alias.empty()) ev(s, w->alias, find_tok(t0, -1, w->alias), 'l');
            block(w->body.get(), s);
            return;
        }
        case NodeType::RETURN: expr(static_cast<ReturnNode*>(n)->expr.get(), s); return;
        case NodeType::RAISE: {
            auto* r = static_cast<RaiseNode*>(n);
            expr(r->expr.get(), s); expr(r->cause.get(), s);
            return;
        }
        case NodeType::ASSERT: {
            auto* a = static_cast<AssertNode*>(n);
            expr(a->condition.get(), s); expr(a->message.get(), s);
            return;
        }
        case NodeType::DELETE: {
            Node* t = static_cast<DeleteNode*>(n)->target.get();
            del_target(t, s);
            return;
        }
        case NodeType::PRINT: {
            auto* p = static_cast<PrintNode*>(n);
            exprs(p->args, s); expr(p->sep.get(), s); expr(p->end.get(), s);
            return;
        }
        case NodeType::GLOBAL: {
            auto* g = static_cast<GlobalNode*>(n);
            int gt = find_tok(t0 >= 0 ? t0 : at_loc(n->tok()), -1, g->name);
            if (g->is_nonlocal) S(s).nonlocals.try_emplace(g->name, gt);
            else S(s).globals.try_emplace(g->name, gt);
            evs.push_back(Ev{s, g->name, gt, g->is_nonlocal ? 'N' : 'G', 'v', nullptr, loop, t0, t1, false});
            return;
        }
        case NodeType::PASS: case NodeType::BREAK: case NodeType::CONTINUE: case NodeType::MACRO_CALL:
            return;
        case NodeType::PY_AST: {
            auto* a = static_cast<PyAstNode*>(n);
            const std::string& k = a->kind;
            if (k == "Decorated") {
                Deco d2;
                d2.t0 = t0;
                if (auto* ds = a->listOf("decorators"))
                    for (auto& d : *ds) {
                        if (!d) continue;
                        expr(d.get(), s);
                        int d0 = node_t0(d.get());
                        if (d0 > 0 && A.toks[(size_t)d0 - 1].type == TokenType::At) A.decorator_toks.push_back(d0 - 1);
                        if (d0 >= 0) A.decorator_toks.push_back(d0);
                        std::string dn = d->type() == NodeType::VARIABLE ? static_cast<VariableNode*>(d.get())->name : std::string();
                        if (dn == "staticmethod") d2.st = true;
                        else if (dn == "classmethod") d2.cm = true;
                        else if (dn == "property" || dn == "cached_property") d2.prop = true;
                        if (d->type() == NodeType::ATTRIBUTE) {
                            const std::string& at = static_cast<AttributeNode*>(d.get())->attr;
                            if (at == "setter" || at == "deleter" || at == "getter") d2.setter = true;
                            if (at == "cached_property") d2.prop = true;
                        }
                    }
                stmt(a->kidOf("target").get(), s, &d2);
                return;
            }
            if (k == "Assign") {
                Node* v = a->kidOf("value").get();
                expr(v, s);
                if (auto* ts = a->listOf("targets")) for (auto& t : *ts) target(t.get(), s, 'a', ts->size() == 1 ? v : nullptr, t0, t1);
                return;
            }
            if (k == "AnnAssign") {
                Node* v = a->kidOf("value").get();
                Node* ann = a->kidOf("annotation").get();
                expr(ann, s);
                expr(v, s);
                Node* t = a->kidOf("target").get();
                if (t && t->type() == NodeType::VARIABLE) {
                    auto* tv = static_cast<VariableNode*>(t);
                    int tk = name_tok(t, tv->name);
                    ev(s, tv->name, tk, 'a', 'v', v, t0, t1);
                    pending_ann.push_back({s, tv->name, ann});
                } else target(t, s, 'a', v, t0, t1);
                return;
            }
            if (k == "Global" || k == "Nonlocal") {
                bool nl = k == "Nonlocal";
                int from = t0 >= 0 ? t0 + 1 : -1;
                if (auto* ns = a->strlOf("names"))
                    for (auto& nm : *ns) {
                        int gt = find_tok(from, t1, nm);
                        if (gt >= 0) from = gt + 1;
                        if (nl) S(s).nonlocals.try_emplace(nm, gt); else S(s).globals.try_emplace(nm, gt);
                        evs.push_back(Ev{s, nm, gt, nl ? 'N' : 'G', 'v', nullptr, loop, t0, t1, false});
                    }
                return;
            }
            if (k == "Import" || k == "ImportFrom") { import_stmt(a, n, s); return; }
            if (k == "Delete") { if (auto* ts = a->listOf("targets")) for (auto& t : *ts) del_target(t.get(), s); return; }
            if (k == "With" || k == "AsyncWith") {
                if (auto* items = a->listOf("items"))
                    for (auto& it : *items) {
                        auto* wi = static_cast<PyAstNode*>(it.get());
                        expr(wi->kidOf("context_expr").get(), s);
                        target(wi->kidOf("optional_vars").get(), s, 'l', nullptr, t0, t1);
                    }
                block(a->kidOf("body").get(), s);
                return;
            }
            if (k == "Match") {
                expr(a->kidOf("subject").get(), s);
                if (auto* cs = a->listOf("cases"))
                    for (auto& c : *cs) {
                        auto* mc = static_cast<PyAstNode*>(c.get());
                        pattern(mc->kidOf("pattern").get(), s);
                        expr(mc->kidOf("guard").get(), s);
                        block(mc->kidOf("body").get(), s);
                    }
                return;
            }
            pyexpr(a, s);
            return;
        }
        default:
            expr(n, s);
            return;
        }
    }

    struct PendingAnn { int scope; std::string name; Node* ann; };
    std::vector<PendingAnn> pending_ann;

    void del_target(Node* t, int s) {
        if (!t) return;
        if (t->type() == NodeType::VARIABLE) {
            auto* v = static_cast<VariableNode*>(t);
            ev(s, v->name, name_tok(t, v->name), 'x');
        } else if (t->type() == NodeType::TUPLE || t->type() == NodeType::LIST) {
            for (auto& e : t->statements()) del_target(e.get(), s);
        } else expr(t, s);
    }
};

// ── resolution: which binding each name means ───────────────────────────────
struct Resolver {
    Analysis& A;
    std::vector<std::set<std::string>>& pyl;
    std::map<int, int>& self_cls;
    std::map<int, int>& cls_param;

    explicit Resolver(Analysis& a) : A(a), pyl(a.pyl), self_cls(a.self_cls), cls_param(a.cls_param) {}
    Scope& S(int s) { return A.scopes[(size_t)s]; }
    bool fn(int s) { char k = S(s).kind; return k == 'f' || k == 'l'; }
    bool pyfn(int s) { return fn(s) && S(s).py; }

    int sym_in(int s, const std::string& n) {
        auto it = S(s).syms.find(n);
        return it == S(s).syms.end() ? -1 : it->second;
    }
    int make(int s, const std::string& n, char kind, int tok) { return new_sym(A, s, n, kind, tok); }

    // NyScope's resolve(): the scope a write lands in
    int write_owner(int s, const std::string& n, char how) {
        Scope& sc = S(s);
        if (sc.globals.count(n)) return 0;
        if (sc.nonlocals.count(n)) {
            for (int p = sc.parent; p >= 0; p = S(p).parent)
                if (fn(p) && (S(p).declared.count(n) || S(p).assigned.count(n) || S(p).nonlocals.count(n))) return p;
            return s;
        }
        if (pyfn(s) && pyl[(size_t)s].count(n)) return s;
        if (sc.declared.count(n) || how == 'l' || how == 'd' || sc.kind == 'c' || sc.kind == 'q') {
            if (how == 'a' && sc.kind == 'q') {}   // (a comprehension assigns nothing itself)
            else return s;
        }
        for (int p = s; p >= 0; p = S(p).parent) {
            if (p != s && S(p).kind == 'c') continue;
            if (p != s && S(p).declared.count(n)) return p;
            if (p != s && S(p).assigned.count(n)) return p;
            if (S(p).globals.count(n)) return 0;
        }
        return s;
    }

    // the scope whose binding a read of n in s means (-1: none)
    int read_owner(int s, const std::string& n) {
        Scope& sc = S(s);
        if (sc.globals.count(n)) return sym_in(0, n) >= 0 ? 0 : -1;
        if (sc.nonlocals.count(n)) {
            for (int p = sc.parent; p >= 0; p = S(p).parent)
                if (fn(p) && sym_in(p, n) >= 0) return p;
            return -1;
        }
        if (pyfn(s) && pyl[(size_t)s].count(n)) return sym_in(s, n) >= 0 ? s : -1;
        for (int p = s; p >= 0; p = S(p).parent) {
            if (p != s && S(p).kind == 'c') continue;
            if (sym_in(p, n) >= 0) return p;
            if (p != s && S(p).globals.count(n)) return sym_in(0, n) >= 0 ? 0 : -1;
        }
        return -1;
    }
    int read_sym(int s, const std::string& n) {
        int o = read_owner(s, n);
        return o < 0 ? -1 : sym_in(o, n);
    }

    void set_occ(int tok, int sym, char role) {
        if (tok < 0 || tok >= (int)A.occ.size() || sym < 0) return;
        if (A.occ[(size_t)tok] >= 0 && A.role[(size_t)tok] == 'd') return;   // a definition stays one
        A.occ[(size_t)tok] = sym;
        A.role[(size_t)tok] = role;
    }

    void run(Walker& W) {
        A.occ.assign(A.toks.size(), -1);
        A.role.assign(A.toks.size(), 0);
        A.attr_of_tok.assign(A.toks.size(), -1);
        pyl.assign(A.scopes.size(), {});
        for (size_t s = 0; s < A.scopes.size(); s++) {
            if (!pyfn((int)s)) continue;
            auto& L = pyl[s];
            Scope& sc = A.scopes[s];
            for (auto& d : sc.declared) L.insert(d.first);
            for (auto& a : sc.assigned) L.insert(a.first);
            for (auto& w : sc.comp_walrus) L.insert(w);
            for (auto& g : sc.globals) L.erase(g.first);
            for (auto& g : sc.nonlocals) L.erase(g.first);
            L.erase("self"); L.erase("this");
        }
        // 1. writes and declarations: the symbol each binds
        for (auto& e : W.evs) {
            if (e.how != 'd' && e.how != 'a' && e.how != 'l' && e.how != 'x') continue;
            int owner = write_owner(e.scope, e.name, e.how);
            int sym = sym_in(owner, e.name);
            if (sym < 0) {
                char kind = e.how == 'd' ? e.kind : (S(owner).kind == 'c' ? 'A' : (e.kind == 'k' ? 'k' : 'v'));
                if (e.how == 'x') kind = 'v';
                sym = make(owner, e.name, kind, e.tok);
                Sym& y = A.syms[(size_t)sym];
                y.s0 = e.s0; y.s1 = e.s1;
                if (e.value) { y.value = e.value; y.value_scope = e.scope; }
            } else {
                Sym& y = A.syms[(size_t)sym];
                if (y.tok < 0 && e.tok >= 0 && e.how != 'x') { y.tok = e.tok; y.s0 = e.s0; y.s1 = e.s1; }
                if (!y.value && e.value && y.kind != 'f' && y.kind != 'M' && y.kind != 'c') { y.value = e.value; y.value_scope = e.scope; }
            }
            char role = e.how == 'x' ? 'x' : (A.syms[(size_t)sym].tok == e.tok ? 'd' : 'w');
            set_occ(e.tok, sym, role);
        }
        // annotated names: the annotation types them
        for (auto& pa : W.pending_ann) {
            int sym = read_sym(pa.scope, pa.name);
            if (sym >= 0 && !A.syms[(size_t)sym].annotation) { A.syms[(size_t)sym].annotation = pa.ann; A.syms[(size_t)sym].ann_scope = pa.scope; }
        }
        // 2. global / nonlocal declarations name the outer binding
        for (auto& e : W.evs) {
            if (e.how != 'G' && e.how != 'N') continue;
            int sym = e.how == 'G' ? sym_in(0, e.name) : -1;
            if (e.how == 'N')
                for (int p = S(e.scope).parent; p >= 0 && sym < 0; p = S(p).parent) if (fn(p)) sym = sym_in(p, e.name);
            if (sym < 0 && e.how == 'G') { sym = make(0, e.name, 'v', -1); }
            set_occ(e.tok, sym, 'r');
        }
        // 3. reads
        for (auto& e : W.evs) {
            if (e.how != 'r') continue;
            int sym = read_sym(e.scope, e.name);
            if (sym >= 0) { set_occ(e.tok, sym, 'r'); continue; }
            if (g_builtins.count(e.name)) continue;
            A.unresolved.push_back(e);
        }
        // members: a class body's names, a method's self
        for (size_t s = 0; s < A.scopes.size(); s++) {
            Scope& sc = A.scopes[s];
            if (sc.kind != 'c') continue;
            for (auto& kv : sc.syms) {
                Sym& y = A.syms[(size_t)kv.second];
                y.member = true;
                if (y.kind == 'v' || y.kind == 'k') y.kind = y.kind == 'k' ? 'k' : 'A';
                sc.members[kv.first] = kv.second;
            }
        }
        for (size_t s = 0; s < A.scopes.size(); s++) {
            Scope& sc = A.scopes[s];
            if (sc.kind != 'f' || sc.cls < 0 || sc.self_sym < 0) continue;
            int owner = sc.owner;
            if (owner >= 0 && A.syms[(size_t)owner].is_classm) cls_param[sc.self_sym] = sc.cls;
            else self_cls[sc.self_sym] = sc.cls;
        }
        // fields: the first `self.x = ...` in a method makes x a member
        for (auto& a : A.attrs) {
            if (!a.store) continue;
            int cs = self_class(a.obj, a.scope);
            if (cs < 0) continue;
            if (S(cs).members.count(a.attr)) continue;
            if (member_of_bases(cs, a.attr, 0) >= 0) continue;
            int id = (int)A.syms.size();
            Sym y;
            y.name = a.attr; y.scope = cs; y.kind = 'F'; y.tok = a.tok; y.member = true;
            y.value = a.value; y.value_scope = a.scope;
            y.s0 = a.tok; y.s1 = a.tok;
            A.syms.push_back(y);
            S(cs).members[a.attr] = id;
        }
        // 4. attributes
        for (size_t i = 0; i < A.attrs.size(); i++) {
            AttrEv& a = A.attrs[i];
            if (a.tok >= 0) A.attr_of_tok[(size_t)a.tok] = (int)i;
            Ty t = type_of(a.obj, a.scope, 0);
            if (t.k == 'c' || t.k == 'i') {
                int cs = A.syms[(size_t)t.sym].body;
                if (cs < 0) continue;
                int m = member(cs, a.attr, 0);
                if (m < 0) {
                    // read here, defined nowhere in this file: one pseudo-member per class and name
                    Sym y;
                    y.name = a.attr; y.scope = cs; y.kind = 'u'; y.member = true;
                    m = (int)A.syms.size();
                    A.syms.push_back(y);
                    S(cs).members[a.attr] = m;
                    A.ext.push_back({a.tok, t.sym, a.attr, a.store, "", 'C'});
                }
                set_occ(a.tok, m, a.store ? (A.syms[(size_t)m].tok == a.tok ? 'd' : 'w') : 'r');
            } else if (t.k == 'm' || t.k == 'x' || t.k == 'X') {
                A.ext.push_back({a.tok, t.sym, a.attr, a.store, t.text, t.k == 'm' ? 'M' : 'X'});
            }
        }
        // 5. keyword arguments name the callee's parameters
        for (auto& c : A.calls) {
            Target tg = target(c.callee, c.scope);
            if (tg.fsym < 0) continue;
            int body = A.syms[(size_t)tg.fsym].body;
            if (body < 0) continue;
            for (auto& g : c.args) {
                if (g.kw.empty() || g.kwtok < 0) continue;
                int p = sym_in(body, g.kw);
                if (p >= 0 && A.syms[(size_t)p].kind == 'p') set_occ(g.kwtok, p, 'r');
            }
        }
    }

    // what a call of `callee` calls: a def of this file (fsym; bound: the
    // first parameter is the receiver), or a name of another module / a builtin
    struct Target { int fsym = -1; bool bound = false; int cls = -1; Sym::TyV ext; std::string builtin; };
    Target target(Node* callee, int scope) {
        Target tg;
        if (!callee) return tg;
        Ty t = type_of(callee, scope, 0);
        if (t.k == 'f') {
            tg.fsym = t.sym;
            const Sym& f = A.syms[(size_t)t.sym];
            if (f.kind == 'M' && !f.is_static) {
                if (callee->type() == NodeType::ATTRIBUTE) {
                    Ty o = type_of(static_cast<AttributeNode*>(callee)->object.get(), scope, 0);
                    tg.bound = o.k == 'i' || (o.k == 'c' && f.is_classm);
                } else tg.bound = false;
            }
        } else if (t.k == 'c') {
            tg.cls = t.sym;
            int body = A.syms[(size_t)t.sym].body;
            int init = body >= 0 ? member(body, "__init__", 0) : -1;
            if (init >= 0 && (A.syms[(size_t)init].kind == 'M' || A.syms[(size_t)init].kind == 'f')) { tg.fsym = init; tg.bound = true; }
        } else if (t.k == 'x' || t.k == 'X' || t.k == 'm') {
            tg.ext = t;
        } else if (t.k == 'B') {
            tg.builtin = t.text;
        } else if (callee->type() == NodeType::VARIABLE) {
            const std::string& nm = static_cast<VariableNode*>(callee)->name;
            if (read_sym(scope, nm) < 0 && g_builtins.count(nm)) tg.builtin = nm;
        }
        return tg;
    }

    // the class scope a receiver is the instance (self) of, or -1
    int self_class(Node* obj, int scope) {
        if (!obj) return -1;
        std::string n;
        if (obj->type() == NodeType::VARIABLE) n = static_cast<VariableNode*>(obj)->name;
        else if (obj->type() == NodeType::SELF) n = obj->tok().value == "this" ? "this" : "self";
        else return -1;
        int sym = read_sym(scope, n);
        auto it = self_cls.find(sym);
        return it == self_cls.end() ? -1 : it->second;
    }

    // a member of class scope cs or of its bases in this file (-1 none)
    int member(int cs, const std::string& attr, int depth) {
        if (cs < 0 || depth > 20) return -1;
        auto it = S(cs).members.find(attr);
        if (it != S(cs).members.end()) return it->second;
        return member_of_bases(cs, attr, depth);
    }
    int member_of_bases(int cs, const std::string& attr, int depth) {
        int owner = S(cs).owner;
        if (owner < 0) return -1;
        Sym& c = A.syms[(size_t)owner];
        for (Node* b : c.base_nodes) {
            Ty t = type_of(b, c.scope, depth + 1);
            if (t.k == 'c' && A.syms[(size_t)t.sym].body >= 0 && t.sym != owner) {
                int m = member(A.syms[(size_t)t.sym].body, attr, depth + 1);
                if (m >= 0) return m;
            }
        }
        return -1;
    }

    using Ty = Sym::TyV;
    Ty mk(char k, int sym = -1, const std::string& text = std::string()) { Ty t; t.k = k; t.sym = sym; t.text = text; return t; }

    Ty sym_type(int sym, int depth) {
        if (sym < 0 || depth > 24) return Ty();
        Sym& y = A.syms[(size_t)sym];
        switch (y.kind) {
        case 'c': case 'e': case 'I': case 'N': return mk('c', sym);
        case 'm': return mk('m', sym);
        case 'n': return mk('x', sym);
        case 'f': case 'M': return mk('f', sym);
        default: break;
        }
        if (self_cls.count(sym)) {
            int cs = self_cls[sym];
            return S(cs).owner >= 0 ? mk('i', S(cs).owner) : Ty();
        }
        if (cls_param.count(sym)) {
            int cs = cls_param[sym];
            return S(cs).owner >= 0 ? mk('c', S(cs).owner) : Ty();
        }
        if (y.ty_state == 2) return y.ty;
        if (y.ty_state == 1) return Ty();
        y.ty_state = 1;
        Ty t;
        if (y.annotation) {
            Ty a = type_of(y.annotation, y.ann_scope >= 0 ? y.ann_scope : y.scope, depth + 1);
            if (a.k == 'c') t = mk('i', a.sym);
            else if (a.k == 'x') t = mk('X', a.sym, a.text);
            else if (a.k == 'B') t = mk('b', -1, a.text);
        }
        if (!t.k && y.value) t = type_of(y.value, y.value_scope >= 0 ? y.value_scope : y.scope, depth + 1);
        Sym& y2 = A.syms[(size_t)sym];   // (type_of may have grown the vector)
        y2.ty = t;
        y2.ty_state = 2;
        return t;
    }

    // the enclosing method's class (for super())
    int enclosing_class(int scope) {
        for (int s = scope; s >= 0; s = S(s).parent) if (S(s).kind == 'f' && S(s).cls >= 0) return S(s).cls;
        return -1;
    }

    Ty type_of(Node* n, int scope, int depth) {
        if (!n || depth > 24 || scope < 0) return Ty();
        switch (n->type()) {
        case NodeType::VARIABLE: case NodeType::SELF: {
            std::string nm = n->type() == NodeType::VARIABLE ? static_cast<VariableNode*>(n)->name
                                                             : (n->tok().value == "this" ? "this" : "self");
            int sym = read_sym(scope, nm);
            if (sym >= 0) return sym_type(sym, depth + 1);
            auto b = g_builtins.find(nm);
            if (b != g_builtins.end() && b->second == 'c') return mk('B', -1, nm);
            return Ty();
        }
        case NodeType::CALL: {
            auto* c = static_cast<CallNode*>(n);
            if (c->callee && c->callee->type() == NodeType::SUPER) {
                int cs = enclosing_class(scope);
                if (cs >= 0 && S(cs).owner >= 0) {
                    Sym& k = A.syms[(size_t)S(cs).owner];
                    for (Node* b : k.base_nodes) {
                        Ty bt = type_of(b, k.scope, depth + 1);
                        if (bt.k == 'c') return mk('i', bt.sym);
                        if (bt.k == 'x') return mk('X', bt.sym, bt.text);
                    }
                }
                return Ty();
            }
            Ty f = type_of(c->callee.get(), scope, depth + 1);
            if (f.k == 'c') return mk('i', f.sym);
            if (f.k == 'x') return mk('X', f.sym, f.text);
            if (f.k == 'B') return mk('b', -1, f.text);
            if (f.k == 'f') {
                Sym& fy = A.syms[(size_t)f.sym];
                if (!fy.returns.empty() && is_word(fy.returns)) {
                    int r = read_sym(fy.scope, fy.returns);
                    if (r >= 0 && A.syms[(size_t)r].kind == 'c') return mk('i', r);
                    if (r >= 0 && A.syms[(size_t)r].kind == 'n') return mk('X', r, "");
                    if (g_builtins.count(fy.returns) && g_builtins[fy.returns] == 'c') return mk('b', -1, fy.returns);
                }
            }
            return Ty();
        }
        case NodeType::ATTRIBUTE: {
            auto* a = static_cast<AttributeNode*>(n);
            Ty o = type_of(a->object.get(), scope, depth + 1);
            if (o.k == 'c' || o.k == 'i') {
                int cs = A.syms[(size_t)o.sym].body;
                int m = member(cs, a->attr, depth + 1);
                if (m >= 0) {
                    Sym& my = A.syms[(size_t)m];
                    if (my.kind == 'M' || my.kind == 'f') {
                        if (my.is_property) {
                            if (!my.returns.empty() && is_word(my.returns)) {
                                int r = read_sym(my.scope, my.returns);
                                if (r >= 0 && A.syms[(size_t)r].kind == 'c') return mk('i', r);
                            }
                            return Ty();
                        }
                        return mk('f', m);
                    }
                    return sym_type(m, depth + 1);
                }
                return Ty();
            }
            if (o.k == 'm' || o.k == 'x') return mk(o.k, o.sym, o.text.empty() ? a->attr : o.text + "." + a->attr);
            if (o.k == 'X') return mk('X', o.sym, o.text.empty() ? a->attr : o.text + "." + a->attr);
            return Ty();
        }
        case NodeType::STRING: return mk('b', -1, "str");
        case NodeType::BYTES: return mk('b', -1, "bytes");
        case NodeType::INTEGER: return mk('b', -1, "int");
        case NodeType::FLOAT: return mk('b', -1, "float");
        case NodeType::TRUE: case NodeType::FALSE: return mk('b', -1, "bool");
        case NodeType::NONE: return mk('b', -1, "NoneType");
        case NodeType::LIST: case NodeType::ARRAY: return mk('b', -1, "list");
        case NodeType::TUPLE: return mk('b', -1, "tuple");
        case NodeType::MAP: return mk('b', -1, "dict");
        case NodeType::LAMBDA: return mk('b', -1, "function");
        case NodeType::COMPREHENSION: {
            int k = static_cast<ComprehensionNode*>(n)->kind & 3;
            static const char* names[] = {"list", "set", "dict", "generator"};
            return mk('b', -1, names[k]);
        }
        case NodeType::PY_AST: {
            const std::string& k = static_cast<PyAstNode*>(n)->kind;
            if (k == "JoinedStr") return mk('b', -1, "str");
            if (k == "Set") return mk('b', -1, "set");
            if (k == "Dict") return mk('b', -1, "dict");
            if (k == "Compare") return mk('b', -1, "bool");
            return Ty();
        }
        case NodeType::BINARY: {
            auto* b = static_cast<BinaryNode*>(n);
            const std::string& o = b->op;
            if (o == "==" || o == "!=" || o == "<" || o == ">" || o == "<=" || o == ">=" || o == "in" || o == "not in"
                || o == "is" || o == "is not") return mk('b', -1, "bool");
            Ty l = type_of(b->left.get(), scope, depth + 1);
            if (l.k == 'b' && (l.text == "str" || l.text == "list") && o == "+") return l;
            return Ty();
        }
        default: return Ty();
        }
    }
};

// ── error recovery by the indentation structure ──────────────────────────────
size_t indent_of(const std::string& s) {
    size_t w = 0;
    for (char c : s) { if (c == ' ') w++; else if (c == '\t') w += 8 - (w % 8); else break; }
    return w;
}
// the leading spaces and tabs, as written (the lexer compares them)
std::string lead(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
    return s.substr(0, i);
}
bool blank(const std::string& s) {
    for (char c : s) if (c != ' ' && c != '\t' && c != '\r') return false;
    return true;
}
bool comment_only(const std::string& s) {
    size_t i = s.find_first_not_of(" \t");
    return i != std::string::npos && s[i] == '#';
}

// Per line: the bracket depth at its start and whether it starts inside a
// triple-quoted string (strings and comments skipped, as the lexer would).
void line_states(const std::vector<std::string>& w, std::vector<int>& depth, std::vector<char>& in_str) {
    depth.assign(w.size() + 1, 0);
    in_str.assign(w.size() + 1, 0);
    int d = 0;
    std::string tq;   // the open triple quote
    for (size_t r = 0; r < w.size(); r++) {
        depth[r] = d;
        in_str[r] = tq.empty() ? 0 : 1;
        const std::string& s = w[r];
        size_t i = 0;
        while (i < s.size()) {
            char c = s[i];
            if (!tq.empty()) {
                if (c == '\\') { i += 2; continue; }
                if (s.compare(i, 3, tq) == 0) { i += 3; tq.clear(); continue; }
                i++;
                continue;
            }
            if (c == '#') break;
            if (c == '"' || c == '\'') {
                if (s.compare(i, 3, std::string(3, c)) == 0) { tq = std::string(3, c); i += 3; continue; }
                size_t j = i + 1;
                while (j < s.size() && s[j] != c) { if (s[j] == '\\') j++; j++; }
                i = j + 1;
                continue;
            }
            if (c == '(' || c == '[' || c == '{') d++;
            else if ((c == ')' || c == ']' || c == '}') && d > 0) d--;
            i++;
        }
    }
    depth[w.size()] = d;
    in_str[w.size()] = tq.empty() ? 0 : 1;
}

bool ends_with_colon(const std::string& s) {
    // the last code character (comments stripped roughly)
    std::string t = s;
    size_t h = std::string::npos;
    char q = 0;
    for (size_t i = 0; i < t.size(); i++) {
        char c = t[i];
        if (q) { if (c == '\\') { i++; continue; } if (c == q) q = 0; continue; }
        if (c == '"' || c == '\'') { q = c; continue; }
        if (c == '#') { h = i; break; }
    }
    if (h != std::string::npos) t = t.substr(0, h);
    size_t e = t.find_last_not_of(" \t\r");
    return e != std::string::npos && t[e] == ':';
}

// Cut the statement around row r out of w (keeping the line count); false
// when nothing could be cut.
bool cut_island(std::vector<std::string>& w, std::vector<char>& patched, int r, const std::string& msg) {
    if (w.empty()) return false;
    if (r < 0) r = 0;
    if (r >= (int)w.size()) r = (int)w.size() - 1;
    std::vector<int> depth;
    std::vector<char> in_str;
    line_states(w, depth, in_str);
    bool indent_err = msg.find("indent") != std::string::npos || msg.find("Indent") != std::string::npos
                   || msg.find("dedent") != std::string::npos || msg.find("Dedent") != std::string::npos;
    // the error is reported on a blank line or at the end: the last code line before it
    while (r > 0 && (blank(w[(size_t)r]) || comment_only(w[(size_t)r])) && !in_str[(size_t)r]) r--;
    // "expected an indented block": the header that has no body
    if (indent_err && msg.find("expected") != std::string::npos) {
        int h = r;
        while (h >= 0 && !ends_with_colon(w[(size_t)h])) h--;
        if (h >= 0 && !patched[(size_t)h]) {
            w[(size_t)h] = lead(w[(size_t)h]) + "pass";
            patched[(size_t)h] = 1;
            return true;
        }
    }
    // the statement's first line: bracket depth 0, not inside a string
    int a = r;
    while (a > 0 && (depth[(size_t)a] > 0 || in_str[(size_t)a])) a--;
    while (a > 0) {   // a backslash continuation
        const std::string& p = w[(size_t)a - 1];
        size_t e = p.find_last_not_of(" \t\r");
        if (e != std::string::npos && p[e] == '\\') a--; else break;
    }
    size_t ind = indent_of(w[(size_t)a]);
    // its last line: where the brackets close, or before the next line
    // indented no deeper when they never do
    int b = a;
    int n = (int)w.size();
    while (b + 1 < n && (depth[(size_t)b + 1] > 0 || in_str[(size_t)b + 1])) {
        if (depth[(size_t)b + 1] > 0 && !in_str[(size_t)b + 1] && !blank(w[(size_t)b + 1]) && indent_of(w[(size_t)b + 1]) <= ind
            && depth[(size_t)a] == 0 && depth[(size_t)b + 1] == depth[(size_t)n]) break;   // never closed: stop at the next statement
        b++;
    }
    // a compound statement's header whose brackets never close (`def f(a, :`
    // being typed): the header alone, so its block stays an island
    if (b > a && depth[(size_t)n] > depth[(size_t)a]) {
        std::string h = w[(size_t)a].substr(lead(w[(size_t)a]).size());
        static const char* heads[] = {"def ", "class ", "if ", "elif ", "for ", "while ", "with ", "async ", "fn ",
                                      "except", "try", "else", "match ", "case ", nullptr};
        bool header = false;
        for (int i = 0; heads[i]; i++) if (h.compare(0, strlen(heads[i]), heads[i]) == 0) header = true;
        int nx2 = a + 1;
        while (nx2 < n && blank(w[(size_t)nx2])) nx2++;
        if (header && nx2 < n && indent_of(w[(size_t)nx2]) > ind) { b = a; r = a; }
    }
    if (b < r) b = r;
    bool already = true;
    for (int i = a; i <= b; i++) if (!patched[(size_t)i]) already = false;
    if (indent_err || already) {
        // unexpected indentation (or a cut that did not help): blank the
        // lines indented at least as deep from here on, the block included
        size_t ind2 = indent_of(w[(size_t)r]);
        int e = r;
        while (e + 1 < n && (blank(w[(size_t)e + 1]) || indent_of(w[(size_t)e + 1]) >= ind2)) e++;
        bool changed = false;
        int from = already ? a : r;
        for (int i = from; i <= e; i++) if (!w[(size_t)i].empty()) { w[(size_t)i].clear(); patched[(size_t)i] = 1; changed = true; }
        if (changed) return true;
        if (!already) return false;
        // the enclosing block's header
        int h = a - 1;
        while (h >= 0 && (blank(w[(size_t)h]) || indent_of(w[(size_t)h]) >= ind)) h--;
        if (h < 0) return false;
        size_t hi = indent_of(w[(size_t)h]);
        int he = h;
        while (he + 1 < n && (blank(w[(size_t)he + 1]) || indent_of(w[(size_t)he + 1]) > hi)) he++;
        w[(size_t)h] = lead(w[(size_t)h]) + "pass";
        patched[(size_t)h] = 1;
        for (int i = h + 1; i <= he; i++) { w[(size_t)i].clear(); patched[(size_t)i] = 1; }
        return true;
    }
    // a block follows: keep it as an island of its own
    int nx = b + 1;
    while (nx < n && (blank(w[(size_t)nx]) || comment_only(w[(size_t)nx]))) nx++;
    bool block_follows = nx < n && indent_of(w[(size_t)nx]) > ind;
    w[(size_t)a] = lead(w[(size_t)a]) + (block_follows ? "if 1:" : "pass");
    patched[(size_t)a] = 1;
    for (int i = a + 1; i <= b; i++) { w[(size_t)i].clear(); patched[(size_t)i] = 1; }
    return true;
}

std::string join_lines(const std::vector<std::string>& w) {
    std::string s;
    size_t n = 0;
    for (auto& l : w) n += l.size() + 1;
    s.reserve(n);
    for (size_t i = 0; i < w.size(); i++) { if (i) s += '\n'; s += w[i]; }
    return s;
}

struct ParseErr { bool ok = true; int row = 0, col = 0; std::string msg; };

// the ast-mode parse of `text` into A (lexer, parser, tree kept)
ParseErr parse_ast(Analysis& A, const std::string& text, const std::string& fname) {
    ParseErr pe;
    A.src = std::make_unique<SourceCode>(SourceCode::from_text(text + "\n", fname));
    A.rep = std::make_unique<Reporter>(*A.src);
    A.lex = std::make_unique<Lexer>(*A.src);
    A.parser = std::make_unique<Parser>(A.rep.get(), nullptr, A.lex.get());
    try {
        A.lex->tokenize();
        if (A.lex->hasErrors()) {
            for (auto& inf : A.lex->info) {
                if (inf.level != LexerInfoLevel::Error) continue;
                pe.ok = false;
                pe.row = inf.info.line();
                pe.col = inf.info.column();
                pe.msg = inf.info.type() == TokenType::UnterminatedStringError ? "unterminated string literal"
                       : !inf.value.empty() ? inf.value : "invalid syntax";
                return pe;
            }
        }
        A.root = A.parser->parseAst("exec");
    } catch (nython::exception::Error& e) {
        pe.ok = false; pe.row = (int)e.location().row; pe.col = (int)e.location().column; pe.msg = e.message();
    } catch (std::exception& e) {
        pe.ok = false; pe.row = 0; pe.col = 0; pe.msg = e.what();
    } catch (std::string& s) {
        pe.ok = false; pe.msg = s;
    } catch (...) {
        pe.ok = false; pe.msg = "invalid syntax";
    }
    return pe;
}

// the engines' parse: their SyntaxError (NyScope's included) and NyScope's report
ParseErr parse_engine(const std::string& text, const std::string& fname, std::string& report) {
    ParseErr pe;
    std::ostringstream rep;
    std::ostream* saved = nython::scope::report_sink();
    nython::scope::report_sink() = &rep;
    try {
        auto source = SourceCode::from_text(text + "\n", fname);
        Reporter reporter(source);
        Lexer lexer(source);
        Parser parser(&reporter, nullptr, &lexer);
        lexer.tokenize();
        parser.parse();
    } catch (nython::exception::Error& e) {
        pe.ok = false; pe.row = (int)e.location().row; pe.col = (int)e.location().column; pe.msg = e.message();
    } catch (std::exception& e) {
        pe.ok = false; pe.msg = e.what();
    } catch (std::string& s) {
        pe.ok = false; pe.msg = s;
    } catch (...) {
        pe.ok = false; pe.msg = "invalid syntax";
    }
    nython::scope::report_sink() = saved;
    report = rep.str();
    return pe;
}

void add_diag(Analysis& A, int row1, int col1, const std::string& msg, int severity, const std::string& code, int len = 0) {
    Diag d;
    uint32_t r = row1 > 0 ? (uint32_t)row1 - 1 : 0;
    if (r >= A.lines.size()) r = A.lines.empty() ? 0 : (uint32_t)A.lines.size() - 1;
    uint32_t c = col1 > 0 ? (uint32_t)col1 - 1 : 0;
    const std::string& ln = A.lines.empty() ? std::string() : A.lines[r];
    uint32_t lc = (uint32_t)cp_of_byte(ln, ln.size());
    if (c > lc) c = lc;
    d.r0 = r; d.c0 = c; d.r1 = r;
    d.c1 = len > 0 ? std::min(lc, c + (uint32_t)len) : lc;
    if (d.c1 <= d.c0) {   // a point: the rest of the line, or one character
        if (lc > c) d.c1 = lc;
        else if (c > 0) { d.c0 = c - 1; d.c1 = c; }
    }
    d.severity = severity;
    d.code = code;
    d.message = msg;
    A.diags.push_back(d);
}

// A syntax error the parser reports at the token after the problem - the
// newline token, which the lexer puts where the next line's code starts,
// a dedent, the end of the file - is about the code line before: its row
// (0-based), and whether it moved there.
int problem_row(const std::vector<std::string>& lines, int row, int col, const std::string& msg, bool& moved) {
    moved = false;
    bool at_break = msg.find("NewLine") != std::string::npos || msg.find("newline") != std::string::npos
                 || msg.find("End") != std::string::npos || msg.find("end of file") != std::string::npos
                 || msg.find("EOF") != std::string::npos || msg.find("Dedent") != std::string::npos
                 || msg.find("Indent") != std::string::npos;
    int r = row - 1;
    int n = (int)lines.size();
    bool blank_line = r < 0 || r >= n || blank(lines[(size_t)r]);
    bool at_start = !blank_line && (col - 1) <= (int)cp_of_byte(lines[(size_t)r], lead(lines[(size_t)r]).size());
    if (!(at_break && at_start) && !blank_line) return r < 0 ? 0 : r;
    int p = std::min(r, n) - (blank_line ? 0 : 1);
    if (p >= n) p = n - 1;
    while (p >= 0 && (blank(lines[(size_t)p]) || comment_only(lines[(size_t)p]))) p--;
    if (p < 0) return r < 0 ? 0 : std::min(r, n - 1);
    moved = true;
    return p;
}

void syntax_diag(Analysis& A, const std::vector<std::string>& work, int row, int col, const std::string& msg, const std::string& code) {
    bool moved;
    int p = problem_row(work, row, col, msg, moved);
    if (moved) {
        const std::string& ln = A.lines[(size_t)p];
        size_t e = ln.find_last_not_of(" \t\r");
        int c = (int)cp_of_byte(ln, e == std::string::npos ? 0 : e);
        add_diag(A, p + 1, c + 1, msg, 1, code, 1);
        return;
    }
    add_diag(A, row, col, msg, 1, code);
}

std::string syntax_code(const std::string& msg) {
    if (msg.find("constant") != std::string::npos) return "nython-const";
    if (msg.find("nonlocal") != std::string::npos) return "nython-nonlocal";
    if (msg.find("indent") != std::string::npos || msg.find("Indent") != std::string::npos) return "indentation-error";
    return "syntax-error";
}

double now_ms() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::shared_ptr<Analysis> analyze(Doc& d) {
    double t_start = now_ms();
    auto A = std::make_shared<Analysis>();
    A->text = d.pt.text();
    split_lines(A->text, A->lines);
    A->line_ascii.resize(A->lines.size());
    for (size_t i = 0; i < A->lines.size(); i++) A->line_ascii[i] = ascii(A->lines[i]) ? 1 : 0;
    A->patched.assign(A->lines.size(), 0);
    A->python = doc_python(d);
    std::string fname = d.path.empty() ? std::string(A->python ? "<document>.py" : "<document>.ny") : d.path;
    // 1. parse, cutting out what does not
    std::vector<std::string> work = A->lines;
    ParseErr pe;
    for (int round = 0; round <= 10; round++) {
        double t0 = now_ms();
        pe = parse_ast(*A, round == 0 ? A->text : join_lines(work), fname);
        A->ms_parse += now_ms() - t0;
        if (pe.ok) break;
        if (round == 10) break;
        bool moved;
        int r0 = problem_row(work, pe.row, pe.col, pe.msg, moved);
        bool on_cut = r0 >= 0 && r0 < (int)A->patched.size() && A->patched[(size_t)r0];
        if (!on_cut) syntax_diag(*A, work, pe.row, pe.col, pe.msg, syntax_code(pe.msg));
        if (!cut_island(work, A->patched, r0, pe.msg)) break;
        A->recoveries++;
    }
    if (!pe.ok) {
        // nothing parsed: an empty module, the error said
        A->toks.clear();
        A->nlex = 0;
        A->scopes.clear();
        Scope m; m.kind = 'm'; m.py = A->python; m.r1 = (uint32_t)A->lines.size();
        A->scopes.push_back(m);
        A->occ.clear(); A->role.clear(); A->attr_of_tok.clear();
        A->ms_total = now_ms() - t_start;
        return A;
    }
    A->work_text = A->recoveries ? join_lines(work) : std::string();
    A->fname = fname;
    // 3. the tokens
    const auto& lt = A->lex->tokens;
    A->toks.reserve(lt.size() + A->parser->ast_extra_toks_.size() + 16);
    auto conv = [&](const Token& t, bool extra) {
        Tk k;
        k.row = t.line() > 0 ? (uint32_t)t.line() - 1 : 0;
        k.col = t.column() > 0 ? (uint32_t)t.column() - 1 : 0;
        if (t.end_row) { k.erow = t.end_row - 1; k.ecol = t.end_col > 0 ? t.end_col - 1 : 0; }
        else {
            k.erow = k.row;
            uint32_t n = 0;
            for (unsigned char c : t.value) if (!u8cont(c)) n++;
            k.ecol = k.col + n;
        }
        k.type = t.type();
        k.cls = t.clazz();
        if (k.type != TokenType::String && k.type != TokenType::Bytes && k.type != TokenType::Comment) k.val = t.value;
        k.extra = extra;
        A->toks.push_back(std::move(k));
    };
    for (auto& t : lt) conv(t, false);
    A->nlex = A->toks.size();
    for (auto& t : A->parser->ast_extra_toks_) conv(t, true);
    // 4. scopes, symbols, occurrences
    Walker W(*A, *A->parser);
    int ms = W.new_scope('m', -1, 0, (int)A->nlex - 1);
    A->scopes[(size_t)ms].py = A->python;
    double tw = now_ms();
    W.block(A->root.get(), ms);
    A->ms_walk = now_ms() - tw;
    // the module's docstring
    if (A->root) {
        auto st = A->root->statements();
        if (!st.empty() && st[0] && st[0]->type() == NodeType::STRING) A->module_doc = st[0]->tok().value;
    }
    double tr = now_ms();
    Resolver R(*A);
    R.run(W);
    A->ms_resolve = now_ms() - tr;
    double tc = now_ms();
    // rows each scope covers
    for (auto& s : A->scopes) {
        if (s.kind == 'm') { s.r0 = 0; s.r1 = A->lines.empty() ? 0 : (uint32_t)A->lines.size() - 1; continue; }
        if (s.t0 >= 0 && s.t0 < (int)A->toks.size()) { s.r0 = A->toks[(size_t)s.t0].row; s.indent = A->toks[(size_t)s.t0].col; }
        if (s.t1 >= 0 && s.t1 < (int)A->toks.size()) s.r1 = A->toks[(size_t)s.t1].erow;
        else s.r1 = s.r0;
        if (s.r1 < s.r0) s.r1 = s.r0;
    }
    // 5. reads that may run before the binding (UnboundLocalError)
    std::map<std::pair<int, std::string>, int> first_bind;   // (scope, name) -> first binding token
    for (auto& e : W.evs) {
        if (e.how != 'a' && e.how != 'l' && e.how != 'd') continue;
        if (e.tok < 0) continue;
        auto key = std::make_pair(e.scope, e.name);
        auto it = first_bind.find(key);
        if (it == first_bind.end() || e.tok < it->second) first_bind[key] = e.tok;
    }
    std::set<std::pair<int, std::string>> warned;
    for (auto& e : W.evs) {
        if (e.how != 'r' || e.tok < 0 || e.tok >= (int)A->nlex) continue;
        int sym = A->occ[(size_t)e.tok];
        if (sym < 0) continue;
        const Sym& y = A->syms[(size_t)sym];
        if (y.scope != e.scope || !R.fn(e.scope) || y.kind == 'p') continue;
        auto it = first_bind.find(std::make_pair(e.scope, e.name));
        if (it == first_bind.end() || e.tok > it->second) continue;
        // a later iteration of a loop around both may have bound it
        bool looped = false;
        for (int l = e.loop; l >= 0 && !looped; ) {
            auto sp = A->loops[(size_t)l];
            if (sp.first >= 0 && it->second >= sp.first && it->second <= sp.second) looped = true;
            // the enclosing loops: those whose span contains this one
            int up = -1;
            for (int k = l - 1; k >= 0; k--) if (A->loops[(size_t)k].first <= sp.first && A->loops[(size_t)k].second >= sp.second) { up = k; break; }
            l = up;
        }
        if (looped) continue;
        // Nython's rule reads an outer binding there when one exists
        if (!R.pyfn(e.scope)) {
            bool outer = false;
            for (int p = A->scopes[(size_t)e.scope].parent; p >= 0 && !outer; p = A->scopes[(size_t)p].parent)
                if (A->scopes[(size_t)p].kind != 'c' && A->scopes[(size_t)p].syms.count(e.name)) outer = true;
            if (outer || g_builtins.count(e.name)) continue;
        }
        if (!warned.insert(std::make_pair(e.scope, e.name)).second) continue;
        const Tk& k = A->toks[(size_t)e.tok];
        add_diag(*A, (int)k.row + 1, (int)k.col + 1,
                 "local variable '" + e.name + "' is read before it is assigned (UnboundLocalError when this runs first)",
                 2, "unbound-local", (int)(k.ecol - k.col));
    }
    A->ms_checks = now_ms() - tc;
    A->ms_total = now_ms() - t_start;
    return A;
}

// The engines' own checks on what parsed (NyScope: const, nonlocal; the two
// binding rules' differences), added to the diagnostics once - only when the
// diagnostics are asked for: a third parse, which completion need not wait for.
void engine_checks(Analysis& A) {
    if (A.engine_done) return;
    A.engine_done = true;
    double t0 = now_ms();
    if (A.recoveries) {
        // the ast-mode parse (Python's tree shape) refused what the engines'
        // parse accepts (a Nython construct it does not shape, `{ ... }`
        // blocks): what the engines run is not an error
        std::string rep0;
        ParseErr orig = parse_engine(A.text, A.fname, rep0);
        if (orig.ok) {
            std::vector<Diag> kept;
            for (auto& g : A.diags) if (g.code != "syntax-error" && g.code != "indentation-error") kept.push_back(g);
            A.diags = kept;
        }
    }
    {
        std::string report;
        ParseErr ee = parse_engine(A.recoveries ? A.work_text : A.text, A.fname, report);
        if (!ee.ok) {
            int r0 = ee.row - 1;
            bool on_cut = r0 >= 0 && r0 < (int)A.patched.size() && A.patched[(size_t)r0];
            std::vector<std::string> wl;
            split_lines(A.recoveries ? A.work_text : A.text, wl);
            if (!on_cut) syntax_diag(A, wl, ee.row, ee.col, ee.msg, syntax_code(ee.msg));
        }
        // file row col qual name how where outer_row okind uses rule def_line insert_line
        std::istringstream rs(report);
        std::string line;
        while (std::getline(rs, line)) {
            std::vector<std::string> f;
            size_t i = 0;
            while (true) { size_t j = line.find('\t', i); f.push_back(line.substr(i, j == std::string::npos ? std::string::npos : j - i)); if (j == std::string::npos) break; i = j + 1; }
            if (f.size() < 11 || f[10] != "nython") continue;
            int row = (int)to_ll(f[1]), col = (int)to_ll(f[2]);
            const std::string& qual = f[3], &nm = f[4], &how = f[5], &where = f[6];
            std::string outer = where == "module" ? "the module's '" + nm + "'"
                                                  : "'" + nm + "' of the enclosing function '" + where.substr(where.find(':') + 1) + "'";
            if (f[7] != "0" && !f[7].empty()) outer += " (line " + f[7] + ")";
            std::string msg;
            if (how == "read")
                msg = "function '" + qual + "' reads '" + nm + "' before binding it: Nython reads " + outer
                    + " there, Python's rule would raise UnboundLocalError";
            else {
                const char* verb = how == "del" ? "deletes" : how == "aug" ? "augments" : "assigns";
                std::string decl = where == "module" ? "global" : "nonlocal";
                msg = "function '" + qual + "' " + verb + " '" + nm + "', rebinding " + outer
                    + " without a declaration - Python's rule makes it a local: declare '" + decl + " " + nm
                    + "' to keep rebinding it, or 'var " + nm + "' for a local";
            }
            add_diag(A, row, col, msg, 3, "nython-scope", (int)nm.size());
        }
    }
    A.ms_engine = now_ms() - t0;
}

Analysis& analysis_of(Doc& d) {
    if (!d.an || d.dirty) {
        d.an = analyze(d);
        d.dirty = false;
        d.same_lines = true;
        d.typed_rows.clear();
        d.generation++;
    }
    return *d.an;
}

// For completion and signature help while a line is being typed: when every
// edit since the last analysis stayed inside one line, that analysis (its
// scopes, its symbols) with the edited lines' current text - no parse. The
// document stays dirty, so anything that needs its tokens parses it.
Analysis& analysis_typing(Doc& d) {
    if (d.an && d.dirty && d.same_lines && d.pt.line_count() == d.an->lines.size()) {
        Analysis& A = *d.an;
        for (long long r : d.typed_rows) {
            if (r < 0 || r >= (long long)A.lines.size()) continue;
            A.lines[(size_t)r] = d.pt.line((size_t)r);
            A.line_ascii[(size_t)r] = ascii(A.lines[(size_t)r]) ? 1 : 0;
        }
        d.typed_rows.clear();
        return A;
    }
    return analysis_of(d);
}

// ── positions in the client's encoding ───────────────────────────────────────
long long enc_col(const Analysis& A, uint32_t row, uint32_t cp) {
    if (row >= A.lines.size() || A.line_ascii[row]) return cp;
    return col_of_byte(A.lines[row], byte_of_cp(A.lines[row], cp), g_enc);
}
uint32_t cp_col(const Analysis& A, long long row, long long ch) {
    if (row < 0 || row >= (long long)A.lines.size() || A.line_ascii[(size_t)row]) return (uint32_t)std::max(0LL, ch);
    const std::string& ln = A.lines[(size_t)row];
    return (uint32_t)cp_of_byte(ln, byte_of_col(ln, ch, g_enc));
}
void pos_json(J& j, const Analysis& A, uint32_t row, uint32_t cp) {
    j.obj().key("line").num(row).key("character").num(enc_col(A, row, cp)).end_obj();
}
void range_json(J& j, const Analysis& A, uint32_t r0, uint32_t c0, uint32_t r1, uint32_t c1) {
    j.obj().key("start"); pos_json(j, A, r0, c0);
    j.key("end"); pos_json(j, A, r1, c1);
    j.end_obj();
}
void tok_range(J& j, const Analysis& A, int t) {
    const Tk& k = A.toks[(size_t)t];
    range_json(j, A, k.row, k.col, k.erow, k.ecol);
}
// the range a statement span covers (whole lines' text, without the newline)
void span_range(J& j, const Analysis& A, int t0, int t1) {
    if (t0 < 0 || t1 < t0) { range_json(j, A, 0, 0, 0, 0); return; }
    // skip the tokens that end a statement (newline, dedent)
    while (t1 > t0 && t1 < (int)A.toks.size() && (A.toks[(size_t)t1].type == TokenType::NewLine || A.toks[(size_t)t1].type == TokenType::Dedent
           || A.toks[(size_t)t1].type == TokenType::Indent || A.toks[(size_t)t1].type == TokenType::End)) t1--;
    const Tk& a = A.toks[(size_t)t0];
    const Tk& b = A.toks[(size_t)t1];
    range_json(j, A, a.row, a.col, b.erow, b.ecol);
}

bool name_type(TokenType t, const std::string& v) {
    return (t == TokenType::Identifier || t == TokenType::Self || t == TokenType::This || t == TokenType::Super || is_word(v))
           && t != TokenType::String && t != TokenType::Bytes && t != TokenType::Integer && t != TokenType::Float;
}

// the name token at (row, cp col): one containing it, else one ending there
int tok_at(const Analysis& A, uint32_t row, uint32_t col) {
    size_t lo = 0, hi = A.nlex;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        const Tk& m = A.toks[mid];
        if (m.row < row || (m.row == row && m.ecol <= col)) lo = mid + 1; else hi = mid;
    }
    int best = -1;
    for (size_t i = lo > 0 ? lo - 1 : 0; i < A.nlex && i <= lo + 1; i++) {
        const Tk& k = A.toks[i];
        if (k.row != row || !name_type(k.type, k.val)) continue;
        if (k.col <= col && col < k.ecol) return (int)i;
        if (k.ecol == col) best = (int)i;
    }
    for (size_t i = A.nlex; i < A.toks.size(); i++) {
        const Tk& k = A.toks[i];
        if (k.row == row && k.col <= col && col <= k.ecol && !k.val.empty()) return (int)i;
    }
    return best;
}

// the innermost scope at (row, cp col)
int scope_at(const Analysis& A, uint32_t row, uint32_t col) {
    int best = 0;
    for (size_t s = 1; s < A.scopes.size(); s++) {
        const Scope& sc = A.scopes[s];
        if (sc.t0 < 0) continue;
        bool in = false;
        if (sc.kind == 'q' || sc.kind == 'l') {
            // an expression's scope: its tokens
            if (sc.t1 < 0) continue;
            const Tk& a = A.toks[(size_t)sc.t0];
            const Tk& b = A.toks[(size_t)std::min<int>(sc.t1, (int)A.toks.size() - 1)];
            in = (row > a.row || (row == a.row && col >= a.col)) && (row < b.erow || (row == b.erow && col <= b.ecol));
        } else if (row > sc.r0 && row <= sc.r1) in = true;
        else if (row == sc.r0) {
            // the header line: inside after its colon
            in = false;
            for (int i = sc.t0; i < (int)A.nlex && A.toks[(size_t)i].row == row; i++)
                if (A.toks[(size_t)i].type == TokenType::Colon && A.toks[(size_t)i].col < col) { in = true; }
        } else if (row > sc.r1) {
            // a line being typed below the block's last statement, indented into it
            if (row >= A.lines.size()) continue;
            const std::string& ln = A.lines[row];
            size_t ind = indent_of(ln);
            if (blank(ln)) ind = (size_t)col;
            if (ind <= sc.indent) continue;
            bool through = true;
            for (uint32_t r = sc.r1 + 1; r < row && through; r++)
                if (!blank(A.lines[r]) && !A.patched[r] && indent_of(A.lines[r]) <= sc.indent) through = false;
            in = through;
        }
        if (!in) continue;
        // the deepest: a scope inside the best one
        int p = (int)s;
        bool inside = false;
        while (p >= 0) { if (p == best) { inside = true; break; } p = A.scopes[(size_t)p].parent; }
        if (inside) best = (int)s;
    }
    return best;
}

const char* kind_word(char k) {
    switch (k) {
    case 'v': return "variable"; case 'k': return "constant"; case 'p': return "parameter"; case 'f': return "function";
    case 'M': return "method"; case 'c': return "class"; case 'm': return "module"; case 'n': return "import";
    case 'F': return "field"; case 'A': return "attribute"; case 'e': return "enum"; case 'E': return "enum member";
    case 'I': return "interface"; case 'N': return "namespace"; case 'u': return "attribute";
    }
    return "variable";
}

void ty_json(J& j, const Analysis& A, const Sym::TyV& t) {
    j.obj();
    j.key("k").str(std::string(1, t.k ? t.k : '0'));
    j.key("sym").num(t.sym);
    j.key("text").str(t.text);
    j.key("name").str(t.sym >= 0 ? A.syms[(size_t)t.sym].name : t.text);
    j.end_obj();
}

std::string first_para(const std::string& doc) {
    return doc;
}

void sym_json(J& j, Analysis& A, int id, bool full = true) {
    Sym& y = A.syms[(size_t)id];
    j.obj();
    j.key("id").num(id);
    j.key("name").str(y.name);
    j.key("kind").str(std::string(1, y.kind));
    j.key("kindWord").str(y.is_property ? "property" : kind_word(y.kind));
    j.key("scope").num(y.scope);
    j.key("scopeKind").str(std::string(1, A.scopes[(size_t)y.scope].kind));
    int owner = A.scopes[(size_t)y.scope].owner;
    j.key("container").str(owner >= 0 ? A.syms[(size_t)owner].name : std::string());
    j.key("containerKind").str(owner >= 0 ? std::string(1, A.syms[(size_t)owner].kind) : std::string());
    if (y.tok >= 0 && y.tok < (int)A.toks.size()) { j.key("range"); tok_range(j, A, y.tok); }
    else j.key("range").null();
    if (y.s0 >= 0) { j.key("full"); span_range(j, A, y.s0, y.s1 >= 0 ? y.s1 : y.s0); }
    else j.key("full").null();
    j.key("detail").str(y.detail);
    j.key("member").boolean(y.member);
    j.key("const").boolean(y.is_const || y.kind == 'k');
    j.key("async").boolean(y.is_async);
    j.key("static").boolean(y.is_static);
    j.key("classmethod").boolean(y.is_classm);
    j.key("property").boolean(y.is_property);
    j.key("generator").boolean(y.generator);
    j.key("body").num(y.body);
    if (full) {
        j.key("doc").str(y.doc);
        j.key("params").arr(); for (auto& p : y.params) j.str(p); j.end_arr();
        j.key("pnames").arr(); for (auto& p : y.pnames) j.str(p); j.end_arr();
        j.key("returns").str(y.returns);
        j.key("imod").str(y.imod);
        j.key("iname").str(y.iname);
        j.key("ilevel").num(y.ilevel);
        j.key("bases").arr(); for (auto& b : y.base_texts) j.str(b); j.end_arr();
        Resolver R(A);
        Sym::TyV t = R.sym_type(id, 0);
        j.key("type"); ty_json(j, A, t);
        // base classes: of this file, or names imported from another module
        j.key("baseTypes").arr();
        for (Node* b : A.syms[(size_t)id].base_nodes) ty_json(j, A, R.type_of(b, A.syms[(size_t)id].scope, 0));
        j.end_arr();
        // a value's text (constants, plain assignments): its first line
        std::string vt;
        Sym& y2 = A.syms[(size_t)id];
        if (y2.value && (y2.kind == 'v' || y2.kind == 'k' || y2.kind == 'A' || y2.kind == 'F' || y2.kind == 'E')) {
            Walker W(A, *A.parser);
            int v0 = W.node_t0(y2.value), v1 = W.span1(y2.value);
            if (v0 >= 0 && v1 >= v0 && v1 - v0 < 40) vt = W.text_of(v0, v1);
        }
        j.key("value").str(vt);
    }
    j.end_obj();
}

// ── queries ──────────────────────────────────────────────────────────────────
std::string op_analyze(Doc& d) {
    Analysis& A = analysis_of(d);
    engine_checks(A);
    J j;
    j.obj();
    j.key("diagnostics").arr();
    for (auto& g : A.diags) {
        j.obj();
        j.key("range"); range_json(j, A, g.r0, g.c0, g.r1, g.c1);
        j.key("severity").num(g.severity);
        j.key("code").str(g.code);
        j.key("source").str("nython");
        j.key("message").str(g.message);
        j.end_obj();
    }
    j.end_arr();
    j.key("unresolved").arr();
    std::set<std::string> seen;
    for (auto& e : A.unresolved) {
        if (e.tok < 0) continue;
        j.obj().key("name").str(e.name).key("range"); tok_range(j, A, e.tok); j.key("scope").num(e.scope).end_obj();
    }
    j.end_arr();
    j.key("starImport").boolean(A.scopes.empty() ? false : A.scopes[0].has_star_import);
    j.key("recoveries").num(A.recoveries);
    j.key("python").boolean(A.python);
    j.key("lines").num((long long)A.lines.size());
    j.key("tokens").num((long long)A.nlex);
    j.key("symbols").num((long long)A.syms.size());
    j.key("scopes").num((long long)A.scopes.size());
    j.key("msParse").raw(nyjson::number(A.ms_parse));
    j.key("msTotal").raw(nyjson::number(A.ms_total));
    j.key("msEngine").raw(nyjson::number(A.ms_engine));
    j.key("msWalk").raw(nyjson::number(A.ms_walk));
    j.key("msResolve").raw(nyjson::number(A.ms_resolve));
    j.key("msChecks").raw(nyjson::number(A.ms_checks));
    j.key("moduleDoc").str(A.module_doc);
    j.end_obj();
    return j.s;
}

// LSP SymbolKind
int lsp_kind(const Sym& y) {
    if (y.is_property) return 7;
    switch (y.kind) {
    case 'c': return 5;
    case 'M': return y.name == "__init__" ? 9 : 6;
    case 'f': return 12;
    case 'F': return 8;
    case 'A': return 8;
    case 'k': return 14;
    case 'e': return 10;
    case 'E': return 22;
    case 'I': return 11;
    case 'N': return 3;
    case 'm': return 2;
    case 'n': return 2;
    }
    return 13;
}

void doc_symbol(J& j, Analysis& A, int id, int depth) {
    Sym& y = A.syms[(size_t)id];
    j.obj();
    j.key("name").str(y.name);
    std::string det = y.detail;
    if ((y.kind == 'v' || y.kind == 'k' || y.kind == 'A' || y.kind == 'F') && det.empty()) det = "";
    j.key("detail").str(det);
    j.key("kind").num(lsp_kind(y));
    // the whole statement, and the name in it
    if (y.s0 >= 0 && y.tok >= 0) {
        int s1 = y.s1 >= y.s0 ? y.s1 : y.tok;
        // a field's "statement" is its name token
        if (y.kind == 'F') { s1 = y.tok; }
        j.key("range"); span_range(j, A, std::min(y.s0, y.tok), std::max(s1, y.tok));
    } else { j.key("range"); tok_range(j, A, y.tok); }
    j.key("selectionRange"); tok_range(j, A, y.tok);
    j.key("children").arr();
    if (y.body >= 0 && depth < 12) {
        const Scope& b = A.scopes[(size_t)y.body];
        std::vector<int> kids;
        bool is_class = b.kind == 'c';
        if (is_class) { for (auto& kv : b.members) kids.push_back(kv.second); }
        else for (auto& kv : b.syms) kids.push_back(kv.second);
        std::sort(kids.begin(), kids.end(), [&](int a, int c) { return A.syms[(size_t)a].tok < A.syms[(size_t)c].tok; });
        for (int k : kids) {
            const Sym& c = A.syms[(size_t)k];
            if (c.tok < 0 || c.kind == 'u' || c.kind == 'p' || c.kind == 'm' || c.kind == 'n') continue;
            if (c.scope != y.body) continue;   // (a base's member)
            if (!is_class && !(c.kind == 'f' || c.kind == 'c' || c.kind == 'e' || c.kind == 'I' || c.kind == 'N')) continue;
            doc_symbol(j, A, k, depth + 1);
        }
    }
    j.end_arr();
    j.end_obj();
}

std::string op_symbols(Doc& d) {
    Analysis& A = analysis_of(d);
    J j;
    j.arr();
    if (!A.scopes.empty()) {
        std::vector<int> top;
        for (auto& kv : A.scopes[0].syms) top.push_back(kv.second);
        std::sort(top.begin(), top.end(), [&](int a, int c) { return A.syms[(size_t)a].tok < A.syms[(size_t)c].tok; });
        for (int k : top) {
            const Sym& y = A.syms[(size_t)k];
            if (y.tok < 0 || y.kind == 'm' || y.kind == 'n' || y.kind == 'u' || A.toks[(size_t)y.tok].extra) continue;
            doc_symbol(j, A, k, 0);
        }
    }
    j.end_arr();
    return j.s;
}

// ── semantic tokens ──────────────────────────────────────────────────────────
// the legend lib/nylsp announces, in this order
enum {
    T_NAMESPACE = 0, T_TYPE, T_CLASS, T_ENUM, T_INTERFACE, T_STRUCT, T_TYPEPARAM, T_PARAMETER, T_VARIABLE,
    T_PROPERTY, T_ENUMMEMBER, T_EVENT, T_FUNCTION, T_METHOD, T_MACRO, T_KEYWORD, T_MODIFIER, T_COMMENT,
    T_STRING, T_NUMBER, T_REGEXP, T_OPERATOR, T_DECORATOR
};
enum {
    M_DECLARATION = 1, M_DEFINITION = 2, M_READONLY = 4, M_STATIC = 8, M_DEPRECATED = 16, M_ABSTRACT = 32,
    M_ASYNC = 64, M_MODIFICATION = 128, M_DOCUMENTATION = 256, M_DEFAULTLIB = 512
};

struct STok { uint32_t row, col, end; int type, mods; };   // columns in the client's encoding

int sym_token_type(const Sym& y) {
    switch (y.kind) {
    case 'p': return T_PARAMETER;
    case 'f': return T_FUNCTION;
    case 'M': return y.is_property ? T_PROPERTY : T_METHOD;
    case 'c': return T_CLASS;
    case 'm': return T_NAMESPACE;
    case 'n': return T_VARIABLE;
    case 'F': case 'A': case 'u': return T_PROPERTY;
    case 'e': return T_ENUM;
    case 'E': return T_ENUMMEMBER;
    case 'I': return T_INTERFACE;
    case 'N': return T_NAMESPACE;
    }
    return T_VARIABLE;
}

std::vector<uint32_t> semantic_data(Analysis& A) {
    std::vector<STok> out;
    std::set<int> decos(A.decorator_toks.begin(), A.decorator_toks.end());
    Resolver R(A);
    // per row: the string tokens' column ranges (code points), for comments
    std::vector<std::vector<std::pair<uint32_t, uint32_t>>> strs(A.lines.size());
    auto push = [&](uint32_t row, uint32_t c0, uint32_t c1, int type, int mods) {
        if (row >= A.lines.size() || A.patched[row] || c1 <= c0) return;
        STok t{row, (uint32_t)enc_col(A, row, c0), (uint32_t)enc_col(A, row, c1), type, mods};
        if (t.end > t.col) out.push_back(t);
    };
    for (size_t i = 0; i < A.nlex; i++) {
        const Tk& k = A.toks[i];
        if (k.row >= A.lines.size()) continue;
        switch (k.type) {
        case TokenType::NewLine: case TokenType::Indent: case TokenType::Dedent: case TokenType::End:
        case TokenType::Block: case TokenType::EndBlock:
            continue;
        default: break;
        }
        if (k.type == TokenType::String || k.type == TokenType::Bytes) {
            for (uint32_t r = k.row; r <= k.erow && r < A.lines.size(); r++) {
                uint32_t c0 = r == k.row ? k.col : 0;
                uint32_t c1 = r == k.erow ? k.ecol : (uint32_t)cp_of_byte(A.lines[r], A.lines[r].size());
                strs[r].push_back({c0, c1});
                push(r, c0, c1, T_STRING, 0);
            }
            continue;
        }
        if (k.type == TokenType::Comment) { push(k.row, k.col, k.ecol, T_COMMENT, 0); continue; }
        if (k.type == TokenType::Integer || k.type == TokenType::Float || k.type == TokenType::Hex || k.type == TokenType::Oct
            || k.type == TokenType::Binary || k.type == TokenType::Complex) { push(k.row, k.col, k.ecol, T_NUMBER, 0); continue; }
        if (k.type == TokenType::Regex) { push(k.row, k.col, k.ecol, T_REGEXP, 0); continue; }
        if (k.type == TokenType::At && decos.count((int)i)) { push(k.row, k.col, k.ecol, T_DECORATOR, 0); continue; }
        if (!is_word(k.val)) continue;
        // a string's prefix (f"...", rb'...'): the lexer reads it as a name of its own
        if (k.val.size() <= 2 && i + 1 < A.nlex && (A.toks[i + 1].type == TokenType::String || A.toks[i + 1].type == TokenType::Bytes)
            && A.toks[i + 1].row == k.row && A.toks[i + 1].col == k.ecol && A.occ[i] < 0) {
            bool prefix = true;
            for (char ch : k.val) if (!strchr("fFrRbBuU", ch)) prefix = false;
            if (prefix) { push(k.row, k.col, k.ecol, T_STRING, 0); continue; }
        }
        int sym = A.occ[i];
        if (sym >= 0) {
            const Sym& y = A.syms[(size_t)sym];
            int type = sym_token_type(y);
            int mods = 0;
            char rl = A.role[i];
            if (rl == 'd') mods |= M_DECLARATION | ((y.kind == 'f' || y.kind == 'M' || y.kind == 'c') ? M_DEFINITION : 0);
            if (rl == 'w' && y.kind != 'p') mods |= M_MODIFICATION;
            if (y.is_const || y.kind == 'k') mods |= M_READONLY;
            if (y.is_async) mods |= M_ASYNC;
            if (y.is_static || y.is_classm) mods |= M_STATIC;
            if (y.kind == 'n' || y.kind == 'm') {
                // an imported name: what it most likely is, by its spelling
                if (y.kind == 'n' && !y.iname.empty() && std::isupper((unsigned char)y.iname[0])) type = T_CLASS;
            }
            if (decos.count((int)i)) type = T_DECORATOR;
            push(k.row, k.col, k.ecol, type, mods);
            continue;
        }
        if (decos.count((int)i)) { push(k.row, k.col, k.ecol, T_DECORATOR, 0); continue; }
        if (A.attr_of_tok[i] >= 0) {
            bool callee = i + 1 < A.nlex && A.toks[i + 1].type == TokenType::ParenOpen;
            push(k.row, k.col, k.ecol, callee ? T_METHOD : T_PROPERTY, 0);
            continue;
        }
        auto b = g_builtins.find(k.val);
        bool called = i + 1 < A.nlex && A.toks[i + 1].type == TokenType::ParenOpen && A.toks[i + 1].row == k.row
                      && A.toks[i + 1].col == k.ecol;
        if ((k.cls == TokenClass::Keyword || k.type == TokenType::True || k.type == TokenType::False || k.type == TokenType::None)
            && !(called && b != g_builtins.end())) {
            push(k.row, k.col, k.ecol, T_KEYWORD, 0);
            continue;
        }
        if (b != g_builtins.end()) {
            int type = b->second == 'c' ? T_CLASS : b->second == 'f' ? T_FUNCTION : T_VARIABLE;
            push(k.row, k.col, k.ecol, type, M_DEFAULTLIB);
            continue;
        }
        if (k.type == TokenType::Identifier) push(k.row, k.col, k.ecol, T_VARIABLE, 0);
    }
    // comments: '#' outside the strings
    for (size_t r = 0; r < A.lines.size(); r++) {
        if (A.patched[r]) continue;
        const std::string& ln = A.lines[r];
        size_t h = ln.find('#');
        while (h != std::string::npos) {
            uint32_t c = (uint32_t)cp_of_byte(ln, h);
            bool in_str = false;
            for (auto& sp : strs[r]) if (c >= sp.first && c < sp.second) { in_str = true; break; }
            if (!in_str) {
                bool has_tok = false;
                for (auto& t : out) if (t.row == r && t.type == T_COMMENT) { has_tok = true; break; }
                if (!has_tok) push((uint32_t)r, c, (uint32_t)cp_of_byte(ln, ln.size()), T_COMMENT, 0);
                break;
            }
            h = ln.find('#', h + 1);
        }
    }
    std::sort(out.begin(), out.end(), [](const STok& a, const STok& b) { return a.row < b.row || (a.row == b.row && a.col < b.col); });
    std::vector<uint32_t> data;
    data.reserve(out.size() * 5);
    uint32_t pr = 0, pc = 0;
    uint32_t last_row = 0, last_end = 0;
    bool any = false;
    for (auto& t : out) {
        if (any && t.row == last_row && t.col < last_end) continue;   // no overlaps
        uint32_t dl = t.row - pr;
        uint32_t dc = dl == 0 ? t.col - pc : t.col;
        data.push_back(dl); data.push_back(dc); data.push_back(t.end - t.col);
        data.push_back((uint32_t)t.type); data.push_back((uint32_t)t.mods);
        pr = t.row; pc = t.col;
        last_row = t.row; last_end = t.end;
        any = true;
    }
    return data;
}

std::string data_json(const std::vector<uint32_t>& d, size_t a = 0, size_t b = std::string::npos) {
    std::string s = "[";
    if (b > d.size()) b = d.size();
    for (size_t i = a; i < b; i++) { if (i > a) s += ','; s += std::to_string(d[i]); }
    s += "]";
    return s;
}

std::string op_tokens(Doc& d) {
    Analysis& A = analysis_of(d);
    d.last_tokens = semantic_data(A);
    d.last_tokens_id = ++g_result_ids;
    return "{\"resultId\":\"" + std::to_string(d.last_tokens_id) + "\",\"data\":" + data_json(d.last_tokens) + "}";
}

std::string op_tokens_delta(Doc& d, const std::string& prev) {
    Analysis& A = analysis_of(d);
    std::vector<uint32_t> now = semantic_data(A);
    if (prev != std::to_string(d.last_tokens_id) || d.last_tokens_id == 0) {
        d.last_tokens = now;
        d.last_tokens_id = ++g_result_ids;
        return "{\"resultId\":\"" + std::to_string(d.last_tokens_id) + "\",\"data\":" + data_json(d.last_tokens) + "}";
    }
    const auto& old = d.last_tokens;
    size_t p = 0;
    while (p < old.size() && p < now.size() && old[p] == now[p]) p++;
    size_t s = 0;
    while (s < old.size() - p && s < now.size() - p && old[old.size() - 1 - s] == now[now.size() - 1 - s]) s++;
    std::string edits = "[]";
    if (p != old.size() || p != now.size()) {
        edits = "[{\"start\":" + std::to_string(p) + ",\"deleteCount\":" + std::to_string(old.size() - p - s)
              + ",\"data\":" + data_json(now, p, now.size() - s) + "}]";
    }
    d.last_tokens = now;
    d.last_tokens_id = ++g_result_ids;
    return "{\"resultId\":\"" + std::to_string(d.last_tokens_id) + "\",\"edits\":" + edits + "}";
}

// ── the occurrence at a position ─────────────────────────────────────────────
const Analysis::Ext* ext_of(const Analysis& A, int tok) {
    for (auto& e : A.ext) if (e.tok == tok) return &e;
    return nullptr;
}

void ext_json(J& j, Analysis& A, const Analysis::Ext& e) {
    j.obj();
    j.key("rk").str(std::string(1, e.rk));
    j.key("recv").num(e.recv);
    j.key("recvName").str(e.recv >= 0 ? A.syms[(size_t)e.recv].name : std::string());
    j.key("recvKind").str(e.recv >= 0 ? std::string(1, A.syms[(size_t)e.recv].kind) : std::string());
    j.key("imod").str(e.recv >= 0 ? A.syms[(size_t)e.recv].imod : std::string());
    j.key("iname").str(e.recv >= 0 ? A.syms[(size_t)e.recv].iname : std::string());
    j.key("path").str(e.path);
    j.key("attr").str(e.attr);
    j.key("store").boolean(e.store);
    if (e.tok >= 0) { j.key("range"); tok_range(j, A, e.tok); }
    j.end_obj();
}

std::string op_at(Doc& d, long long line, long long ch) {
    Analysis& A = analysis_of(d);
    if (line < 0 || line >= (long long)A.lines.size()) return "null";
    uint32_t cp = cp_col(A, line, ch);
    int t = tok_at(A, (uint32_t)line, cp);
    if (t < 0) return "null";
    const Tk& k = A.toks[(size_t)t];
    J j;
    j.obj();
    j.key("tok").num(t);
    j.key("name").str(k.val);
    j.key("range"); tok_range(j, A, t);
    int sym = A.occ[(size_t)t];
    j.key("sym").num(sym);
    j.key("role").str(A.role[(size_t)t] ? std::string(1, A.role[(size_t)t]) : std::string());
    if (sym >= 0) { j.key("symbol"); sym_json(j, A, sym); }
    int ai = A.attr_of_tok[(size_t)t];
    if (ai >= 0) {
        Resolver R(A);
        j.key("objType"); ty_json(j, A, R.type_of(A.attrs[(size_t)ai].obj, A.attrs[(size_t)ai].scope, 0));
        j.key("store").boolean(A.attrs[(size_t)ai].store);
    }
    if (const Analysis::Ext* e = ext_of(A, t)) { j.key("ext"); ext_json(j, A, *e); }
    if (sym < 0 && ai < 0) {
        auto b = g_builtins.find(k.val);
        if (b != g_builtins.end() && k.cls != TokenClass::Keyword) j.key("builtin").str(std::string(1, b->second));
    }
    j.key("keyword").boolean(sym < 0 && (k.cls == TokenClass::Keyword || k.type == TokenType::True || k.type == TokenType::False || k.type == TokenType::None));
    // a module named by an import statement: the dotted name up to here
    for (auto& im : A.imports) {
        if (im.mod_t0 < 0 || t < im.mod_t0 || t > im.mod_t1) continue;
        std::string m;
        for (int i = im.mod_t0; i <= t; i++) m += A.toks[(size_t)i].type == TokenType::Dot ? std::string(".") : A.toks[(size_t)i].val;
        j.key("module").str(std::string((size_t)(im.from ? im.level : 0), '.') + m);
        j.key("moduleFrom").boolean(im.from);
        break;
    }
    for (auto& im : A.imports) {
        if (im.from && im.name_tok == t) { j.key("importedFrom").str(im.module); j.key("importedName").str(im.name); break; }
    }
    j.key("scope").num(scope_at(A, (uint32_t)line, cp));
    j.end_obj();
    return j.s;
}

std::string op_sym(Doc& d, long long id) {
    Analysis& A = analysis_typing(d);
    if (id < 0 || id >= (long long)A.syms.size()) return "null";
    J j;
    sym_json(j, A, (int)id);
    return j.s;
}

std::string op_refs(Doc& d, long long id) {
    Analysis& A = analysis_of(d);
    J j;
    j.arr();
    for (size_t i = 0; i < A.toks.size(); i++) {
        if (A.occ[i] != id) continue;
        j.obj().key("range"); tok_range(j, A, (int)i);
        j.key("role").str(std::string(1, A.role[i] ? A.role[i] : 'r'));
        j.end_obj();
    }
    j.end_arr();
    return j.s;
}

std::string op_visible(Doc& d, long long line, long long ch) {
    Analysis& A = analysis_typing(d);
    uint32_t row = line < 0 ? 0 : (uint32_t)line;
    uint32_t cp = cp_col(A, line, ch);
    int s = scope_at(A, row, cp);
    J j;
    j.arr();
    std::set<std::string> seen;
    int depth = 0;
    for (int p = s; p >= 0; p = A.scopes[(size_t)p].parent, depth++) {
        if (p != s && A.scopes[(size_t)p].kind == 'c') continue;
        for (auto& kv : A.scopes[(size_t)p].syms) {
            const Sym& y = A.syms[(size_t)kv.second];
            if (y.kind == 'u' || !seen.insert(kv.first).second) continue;
            j.obj().key("name").str(kv.first).key("kind").str(std::string(1, y.kind)).key("id").num(kv.second)
             .key("detail").str(y.detail).key("depth").num(depth).key("property").boolean(y.is_property).end_obj();
        }
    }
    j.end_arr();
    return j.s;
}

void members_into(Analysis& A, Resolver& R, int cls, std::set<std::string>& seen, J& j, std::vector<Sym::TyV>& ext_bases, int depth) {
    if (cls < 0 || depth > 16) return;
    Sym& c = A.syms[(size_t)cls];
    if (c.body < 0) return;
    for (auto& kv : A.scopes[(size_t)c.body].members) {
        const Sym& y = A.syms[(size_t)kv.second];
        if (y.kind == 'u' || !seen.insert(kv.first).second) continue;
        j.obj().key("name").str(kv.first).key("kind").str(std::string(1, y.kind)).key("id").num(kv.second)
         .key("detail").str(y.detail).key("from").str(c.name).key("property").boolean(y.is_property)
         .key("static").boolean(y.is_static).key("classmethod").boolean(y.is_classm).end_obj();
    }
    const auto& bases = A.syms[(size_t)cls].base_nodes;
    for (size_t i = 0; i < bases.size(); i++) {
        Sym::TyV t = R.type_of(bases[i], A.syms[(size_t)cls].scope, 0);
        if (t.k == 'c' && t.sym != cls) members_into(A, R, t.sym, seen, j, ext_bases, depth + 1);
        else if (t.k == 'x') ext_bases.push_back(t);
        else if (t.k == 'B') ext_bases.push_back(t);
        else if (!t.k && i < A.syms[(size_t)cls].base_texts.size()) {
            // a name this file does not bind (a star or quoted import's): by its text
            Sym::TyV u;
            u.k = '?';
            u.text = A.syms[(size_t)cls].base_texts[i];
            ext_bases.push_back(u);
        }
    }
}

std::string op_members(Doc& d, long long id) {
    Analysis& A = analysis_typing(d);
    if (id < 0 || id >= (long long)A.syms.size()) return "{\"members\":[],\"externalBases\":[]}";
    Resolver R(A);
    J j;
    j.obj();
    j.key("members").arr();
    std::set<std::string> seen;
    std::vector<Sym::TyV> ext;
    members_into(A, R, (int)id, seen, j, ext, 0);
    j.end_arr();
    j.key("externalBases").arr();
    for (auto& t : ext) ty_json(j, A, t);
    j.end_arr();
    j.end_obj();
    return j.s;
}

std::string op_exports(Doc& d) {
    Analysis& A = analysis_of(d);
    J j;
    j.arr();
    if (!A.scopes.empty()) {
        std::vector<int> top;
        for (auto& kv : A.scopes[0].syms) top.push_back(kv.second);
        std::sort(top.begin(), top.end());
        for (int k : top) {
            const Sym& y = A.syms[(size_t)k];
            if (y.kind == 'u') continue;
            sym_json(j, A, k, true);
        }
    }
    j.end_arr();
    return j.s;
}

std::string op_imports(Doc& d) {
    Analysis& A = analysis_of(d);
    J j;
    j.arr();
    for (auto& im : A.imports) {
        j.obj();
        j.key("sym").num(im.sym);
        j.key("module").str(im.module);
        j.key("name").str(im.name);
        j.key("alias").str(im.alias);
        j.key("level").num(im.level);
        j.key("from").boolean(im.from);
        j.key("quoted").boolean(im.quoted);
        if (im.mod_t0 >= 0 && im.mod_t1 >= im.mod_t0) { j.key("moduleRange"); span_range(j, A, im.mod_t0, im.mod_t1); }
        if (im.name_tok >= 0) { j.key("nameRange"); tok_range(j, A, im.name_tok); }
        if (im.alias_tok >= 0) { j.key("aliasRange"); tok_range(j, A, im.alias_tok); }
        if (im.stmt0 >= 0) { j.key("stmtRange"); span_range(j, A, im.stmt0, im.stmt1); }
        j.end_obj();
    }
    j.end_arr();
    return j.s;
}

std::string op_ext(Doc& d) {
    Analysis& A = analysis_of(d);
    J j;
    j.arr();
    for (auto& e : A.ext) ext_json(j, A, e);
    j.end_arr();
    return j.s;
}

void target_json(J& j, Analysis& A, const Resolver::Target& tg) {
    j.obj();
    j.key("fsym").num(tg.fsym);
    j.key("bound").boolean(tg.bound);
    j.key("cls").num(tg.cls);
    if (tg.fsym >= 0) {
        const Sym& f = A.syms[(size_t)tg.fsym];
        j.key("name").str(f.name);
        j.key("detail").str(f.detail);
        j.key("doc").str(f.doc);
        j.key("params").arr(); for (auto& p : f.params) j.str(p); j.end_arr();
        j.key("pnames").arr(); for (auto& p : f.pnames) j.str(p); j.end_arr();
    }
    if (tg.cls >= 0) { j.key("className").str(A.syms[(size_t)tg.cls].name); j.key("classDoc").str(A.syms[(size_t)tg.cls].doc); }
    j.key("ext"); ty_json(j, A, tg.ext);
    if (tg.ext.k && tg.ext.sym >= 0) {
        j.key("extImod").str(A.syms[(size_t)tg.ext.sym].imod);
        j.key("extIname").str(A.syms[(size_t)tg.ext.sym].iname);
    }
    j.key("builtin").str(tg.builtin);
    j.end_obj();
}

std::string op_calls(Doc& d, long long l0, long long l1) {
    Analysis& A = analysis_of(d);
    Resolver R(A);
    J j;
    j.arr();
    for (auto& c : A.calls) {
        if (c.lp < 0) continue;
        const Tk& lp = A.toks[(size_t)c.lp];
        if ((long long)lp.row < l0 || (long long)lp.row > l1) continue;
        if (A.patched[lp.row]) continue;
        Resolver::Target tg = R.target(c.callee, c.scope);
        j.obj();
        j.key("lp"); pos_json(j, A, lp.row, lp.col);
        j.key("target"); target_json(j, A, tg);
        j.key("args").arr();
        for (auto& g : c.args) {
            if (g.tok < 0 || g.tok >= (int)A.toks.size()) { j.null(); continue; }
            const Tk& k = A.toks[(size_t)g.tok];
            j.obj().key("pos"); pos_json(j, A, k.row, k.col);
            j.key("kw").str(g.kw).key("star").num(g.star);
            if (!g.kw.empty() && g.kwtok >= 0) { j.key("kwRange"); tok_range(j, A, g.kwtok); }
            // the argument's own text when it is a plain name (a hint repeating it is noise)
            j.key("name").str(is_word(k.val) && (g.tok + 1 >= (int)A.nlex || (A.toks[(size_t)g.tok + 1].type == TokenType::Comma
                                     || A.toks[(size_t)g.tok + 1].type == TokenType::ParenClose)) ? k.val : std::string());
            j.end_obj();
        }
        j.end_arr();
        j.end_obj();
    }
    j.end_arr();
    return j.s;
}

// a dotted name's meaning in a scope: [type, symbol of the last part]
std::pair<Sym::TyV, int> resolve_dotted(Analysis& A, Resolver& R, int scope, const std::vector<std::string>& parts) {
    Sym::TyV t;
    int sym = -1;
    if (parts.empty()) return {t, -1};
    if (parts[0] == "self" || parts[0] == "this") {
        sym = R.read_sym(scope, parts[0]);
        t = sym >= 0 ? R.sym_type(sym, 0) : Sym::TyV();
    } else {
        sym = R.read_sym(scope, parts[0]);
        if (sym >= 0) t = R.sym_type(sym, 0);
        else {
            auto b = g_builtins.find(parts[0]);
            if (b != g_builtins.end() && b->second == 'c') { t.k = 'B'; t.text = parts[0]; }
        }
    }
    for (size_t i = 1; i < parts.size(); i++) {
        const std::string& p = parts[i];
        if (p == "()") {   // a call
            if (t.k == 'c') { t.k = 'i'; }
            else if (t.k == 'x') { t.k = 'X'; }
            else if (t.k == 'B') { t.k = 'b'; }
            else if (t.k == 'f' && sym >= 0) {
                const Sym& f = A.syms[(size_t)sym];
                Sym::TyV r;
                if (!f.returns.empty() && is_word(f.returns)) {
                    int rs = R.read_sym(f.scope, f.returns);
                    if (rs >= 0 && A.syms[(size_t)rs].kind == 'c') { r.k = 'i'; r.sym = rs; }
                    else if (g_builtins.count(f.returns)) { r.k = 'b'; r.text = f.returns; }
                }
                t = r;
            } else t = Sym::TyV();
            sym = -1;
            continue;
        }
        if (t.k == 'c' || t.k == 'i') {
            int cs = A.syms[(size_t)t.sym].body;
            int m = R.member(cs, p, 0);
            if (m < 0) return {Sym::TyV(), -1};
            sym = m;
            const Sym& my = A.syms[(size_t)m];
            if (my.kind == 'M' || my.kind == 'f') { t.k = 'f'; t.sym = m; t.text.clear(); }
            else t = R.sym_type(m, 0);
            continue;
        }
        if (t.k == 'm' || t.k == 'x' || t.k == 'X') { t.text = t.text.empty() ? p : t.text + "." + p; sym = -1; continue; }
        return {Sym::TyV(), -1};
    }
    return {t, sym};
}

// The text of a statement from its first line to (row, byte b) and that
// first line, for the scanners below (at most 60 lines back).
void statement_text(const Analysis& A, uint32_t row, size_t b, uint32_t& first) {
    std::vector<int> depth;
    std::vector<char> in_str;
    first = row;
    // a cheap scan of the 60 lines before
    uint32_t from = row > 60 ? row - 60 : 0;
    std::vector<std::string> part(A.lines.begin() + from, A.lines.begin() + row + 1);
    part.back() = part.back().substr(0, b);
    line_states(part, depth, in_str);
    uint32_t r = (uint32_t)part.size() - 1;
    while (r > 0 && (depth[r] > 0 || in_str[r])) r--;
    first = from + r;
}

// Scans [from_row, (row, b)) of the text, character by character, calling
// on(row, byte, ch) outside strings and comments.
template <class F> void scan_code(const Analysis& A, uint32_t from_row, uint32_t row, size_t b, F on) {
    std::string q;
    for (uint32_t r = from_row; r <= row && r < A.lines.size(); r++) {
        const std::string& s = A.lines[r];
        size_t e = r == row ? std::min(b, s.size()) : s.size();
        size_t i = 0;
        while (i < e) {
            char c = s[i];
            if (!q.empty()) {
                if (c == '\\') { i += 2; continue; }
                if (s.compare(i, q.size(), q) == 0) { i += q.size(); q.clear(); continue; }
                i++;
                continue;
            }
            if (c == '#') break;
            if (c == '"' || c == '\'') {
                q = s.compare(i, 3, std::string(3, c)) == 0 ? std::string(3, c) : std::string(1, c);
                i += q.size();
                continue;
            }
            on(r, i, c);
            i++;
        }
        if (q.size() == 1) q.clear();   // a one-quote string ends with its line
    }
}

// the dotted name that ends at byte e of line s: parts, "()" for a call
std::vector<std::string> dotted_before(const std::string& s, size_t e, size_t& start) {
    std::vector<std::string> parts;
    size_t i = e;
    while (true) {
        while (i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\t')) i--;
        if (i > 0 && (s[i - 1] == ')' || s[i - 1] == ']')) {
            // a call or a subscript: skip to its bracket
            char close = s[i - 1], open = close == ')' ? '(' : '[';
            int dep = 0;
            size_t k = i;
            while (k > 0) {
                k--;
                if (s[k] == close) dep++;
                else if (s[k] == open && --dep == 0) break;
            }
            if (dep != 0) break;
            parts.insert(parts.begin(), close == ')' ? std::string("()") : std::string("[]"));
            i = k;
            continue;
        }
        size_t w = i;
        while (w > 0 && id_char((unsigned char)s[w - 1])) w--;
        if (w == i || !id_start((unsigned char)s[w])) break;
        parts.insert(parts.begin(), s.substr(w, i - w));
        i = w;
        size_t j = i;
        while (j > 0 && (s[j - 1] == ' ' || s[j - 1] == '\t')) j--;
        if (j > 0 && s[j - 1] == '.' && !(j > 1 && s[j - 2] == '.')) { i = j - 1; continue; }
        if (j > 1 && s[j - 1] == '.' && s[j - 2] == '?') { i = j - 2; continue; }   // a?.b
        break;
    }
    start = i;
    // a subscript's result is unknown: drop what is before it
    for (size_t k = parts.size(); k-- > 0;) if (parts[k] == "[]") { parts.erase(parts.begin(), parts.begin() + (long)k + 1); break; }
    return parts;
}

std::string op_call_at(Doc& d, long long line, long long ch) {
    Analysis& A = analysis_typing(d);
    if (line < 0 || line >= (long long)A.lines.size()) return "null";
    uint32_t row = (uint32_t)line;
    uint32_t cp = cp_col(A, line, ch);
    size_t b = byte_of_cp(A.lines[row], cp);
    uint32_t first;
    statement_text(A, row, b, first);
    struct Frame { uint32_t row; size_t byte; char open; int commas; std::string kw; std::vector<std::string> used; size_t arg_start_row, arg_start; };
    std::vector<Frame> st;
    scan_code(A, first, row, b, [&](uint32_t r, size_t i, char c) {
        if (c == '(' || c == '[' || c == '{') { st.push_back(Frame{r, i, c, 0, "", {}, r, i + 1}); return; }
        if ((c == ')' || c == ']' || c == '}') && !st.empty()) { st.pop_back(); return; }
        if (st.empty()) return;
        Frame& f = st.back();
        if (c == ',') { if (!f.kw.empty()) f.used.push_back(f.kw); f.commas++; f.kw.clear(); f.arg_start_row = r; f.arg_start = i + 1; return; }
        if (c == '=' && f.open == '(') {
            const std::string& s = A.lines[r];
            bool cmp = (i + 1 < s.size() && s[i + 1] == '=') || (i > 0 && (s[i - 1] == '=' || s[i - 1] == '!' || s[i - 1] == '<' || s[i - 1] == '>'));
            if (cmp) return;
            // the argument so far is one name: a keyword argument
            if (f.arg_start_row == r) {
                std::string a = s.substr(f.arg_start, i - f.arg_start);
                size_t x = a.find_first_not_of(" \t"), y = a.find_last_not_of(" \t");
                if (x != std::string::npos) { a = a.substr(x, y - x + 1); if (is_word(a)) f.kw = a; }
            }
        }
    });
    // the innermost open parenthesis
    int fi = (int)st.size() - 1;
    while (fi >= 0 && st[(size_t)fi].open != '(') fi--;
    if (fi < 0) return "null";
    Frame& f = st[(size_t)fi];
    size_t cstart;
    std::vector<std::string> parts = dotted_before(A.lines[f.row], f.byte, cstart);
    if (parts.empty()) return "null";
    std::string callee;
    for (auto& p : parts) { if (p == "()") callee += "()"; else { if (!callee.empty()) callee += "."; callee += p; } }
    Resolver R(A);
    int scope = scope_at(A, row, cp);
    auto rs = resolve_dotted(A, R, scope, parts);
    Resolver::Target tg;
    Sym::TyV t = rs.first;
    if (t.k == 'f' && t.sym >= 0) {
        tg.fsym = t.sym;
        const Sym& fy = A.syms[(size_t)t.sym];
        if (fy.kind == 'M' && !fy.is_static && parts.size() > 1) {
            std::vector<std::string> recv(parts.begin(), parts.end() - 1);
            auto ro = resolve_dotted(A, R, scope, recv);
            tg.bound = ro.first.k == 'i' || (ro.first.k == 'c' && fy.is_classm);
        }
    } else if (t.k == 'c' && t.sym >= 0) {
        tg.cls = t.sym;
        int body = A.syms[(size_t)t.sym].body;
        int init = body >= 0 ? R.member(body, "__init__", 0) : -1;
        if (init >= 0) { tg.fsym = init; tg.bound = true; }
    } else if (t.k == 'x' || t.k == 'X' || t.k == 'm') tg.ext = t;
    else if (t.k == 'B') tg.builtin = t.text;
    else if (parts.size() == 1 && g_builtins.count(parts[0])) tg.builtin = parts[0];
    J j;
    j.obj();
    j.key("callee").str(callee);
    j.key("parts").arr(); for (auto& p : parts) j.str(p); j.end_arr();
    j.key("active").num(f.commas);
    j.key("kw").str(f.kw);
    j.key("used").arr(); for (auto& u : f.used) j.str(u); j.end_arr();
    j.key("paren"); pos_json(j, A, f.row, (uint32_t)cp_of_byte(A.lines[f.row], f.byte));
    j.key("target"); target_json(j, A, tg);
    j.key("scope").num(scope);
    j.end_obj();
    return j.s;
}

// ── the completion context ───────────────────────────────────────────────────
std::string op_context(Doc& d, long long line, long long ch) {
    Analysis& A = analysis_typing(d);
    J j;
    j.obj();
    if (line < 0 || line >= (long long)A.lines.size()) { j.key("none").boolean(true); j.end_obj(); return j.s; }
    uint32_t row = (uint32_t)line;
    uint32_t cp = cp_col(A, line, ch);
    const std::string& s = A.lines[row];
    size_t b = byte_of_cp(s, cp);
    // inside a string or a comment?
    bool in_str = false, in_comment = false;
    for (size_t i = 0; i < A.nlex; i++) {   // a multi-line string around the line
        const Tk& k = A.toks[i];
        if (k.row > row) break;
        if ((k.type == TokenType::String || k.type == TokenType::Bytes) && k.erow > k.row && !A.patched[k.row]
            && (k.row < row || (k.row == row && k.col < cp)) && (k.erow > row || (k.erow == row && k.ecol > cp))) in_str = true;
    }
    if (!in_str) {
        std::string q;
        for (size_t i = 0; i < b && i < s.size(); i++) {
            char c = s[i];
            if (!q.empty()) {
                if (c == '\\') { i++; continue; }
                if (s.compare(i, q.size(), q) == 0) { i += q.size() - 1; q.clear(); }
                continue;
            }
            if (c == '#') { in_comment = true; break; }
            if (c == '"' || c == '\'') { q = s.compare(i, 3, std::string(3, c)) == 0 ? std::string(3, c) : std::string(1, c); i += q.size() - 1; }
        }
        if (!q.empty()) in_str = true;
    }
    j.key("inString").boolean(in_str);
    j.key("inComment").boolean(in_comment);
    // the word being typed
    size_t w = b;
    while (w > 0 && id_char((unsigned char)s[w - 1])) w--;
    std::string prefix = s.substr(w, b - w);
    j.key("prefix").str(prefix);
    j.key("prefixStart"); pos_json(j, A, row, (uint32_t)cp_of_byte(s, w));
    // what is before it: a receiver, an import, a def's name
    size_t k = w;
    while (k > 0 && (s[k - 1] == ' ' || s[k - 1] == '\t')) k--;
    bool dot = k > 0 && s[k - 1] == '.' && !(k > 1 && s[k - 2] == '.');
    std::string head = s.substr(0, w);
    size_t h0 = head.find_first_not_of(" \t");
    std::string lstripped = h0 == std::string::npos ? std::string() : head.substr(h0);
    int scope = scope_at(A, row, cp);
    j.key("scope").num(scope);
    j.key("scopeKind").str(std::string(1, A.scopes[(size_t)scope].kind));
    auto starts = [&](const char* p) { size_t n = strlen(p); return lstripped.compare(0, n, p) == 0; };
    if (starts("from ") && lstripped.find(" import ") == std::string::npos && lstripped.find(" import") == std::string::npos) {
        std::string m = lstripped.substr(5);
        size_t e = m.find_last_not_of(" \t");
        m = e == std::string::npos ? std::string() : m.substr(0, e + 1);
        j.key("import").str("from-module").key("module").str(m);
    } else if (starts("from ") && lstripped.find(" import") != std::string::npos) {
        std::string m = lstripped.substr(5, lstripped.find(" import") - 5);
        size_t e = m.find_last_not_of(" \t");
        m = e == std::string::npos ? std::string() : m.substr(0, e + 1);
        j.key("import").str("from-name").key("module").str(m);
    } else if (starts("import ") && lstripped.find(" as ") == std::string::npos) {
        j.key("import").str("module").key("module").str(lstripped.substr(7));
    }
    if (starts("def ") || starts("class ") || starts("async def ") || starts("fn ")) {
        if (lstripped.find('(') == std::string::npos) j.key("naming").boolean(true);
    }
    if (dot) {
        size_t rs;
        std::vector<std::string> parts = dotted_before(s, k - 1, rs);
        std::string rt;
        for (auto& p : parts) { if (p == "()") rt += "()"; else { if (!rt.empty()) rt += "."; rt += p; } }
        j.key("receiver").str(rt);
        j.key("receiverParts").arr(); for (auto& p : parts) j.str(p); j.end_arr();
        Resolver R(A);
        auto r = resolve_dotted(A, R, scope, parts);
        if (parts.empty()) {
            // a literal before the dot: "s".upper, [1].append, {}.get
            size_t q = k - 1;
            while (q > 0 && (s[q - 1] == ' ' || s[q - 1] == '\t')) q--;
            char before = q > 0 ? s[q - 1] : 0;
            const char* lit = before == '"' || before == '\'' ? "str" : before == ']' ? "list" : before == '}' ? "dict"
                            : before == ')' ? "tuple" : nullptr;
            if (lit) { r.first.k = 'b'; r.first.sym = -1; r.first.text = lit; }
        }
        j.key("receiverType"); ty_json(j, A, r.first);
        j.key("receiverSym").num(r.second);
        if (r.first.sym >= 0 && (r.first.k == 'm' || r.first.k == 'x' || r.first.k == 'X')) {
            j.key("receiverImod").str(A.syms[(size_t)r.first.sym].imod);
            j.key("receiverIname").str(A.syms[(size_t)r.first.sym].iname);
        }
    }
    j.end_obj();
    return j.s;
}

std::string op_folds(Doc& d) {
    Analysis& A = analysis_of(d);
    J j;
    j.arr();
    // comment blocks
    size_t n = A.lines.size();
    for (size_t r = 0; r < n;) {
        if (!comment_only(A.lines[r])) { r++; continue; }
        size_t e = r;
        while (e + 1 < n && comment_only(A.lines[e + 1])) e++;
        if (e > r) j.obj().key("startLine").num((long long)r).key("endLine").num((long long)e).key("kind").str("comment").end_obj();
        r = e + 1;
    }
    // groups of import statements
    std::vector<std::pair<uint32_t, uint32_t>> rows;
    for (auto& im : A.imports) {
        if (im.stmt0 < 0) continue;
        uint32_t a = A.toks[(size_t)im.stmt0].row, b = A.toks[(size_t)std::max(im.stmt0, im.stmt1)].erow;
        if (!rows.empty() && rows.back().first == a) continue;
        rows.push_back({a, b});
    }
    for (size_t i = 0; i < rows.size();) {
        size_t k = i;
        uint32_t end = rows[i].second;
        while (k + 1 < rows.size()) {
            uint32_t nxt = rows[k + 1].first;
            bool gap = false;
            for (uint32_t r = end + 1; r < nxt; r++) if (!blank(A.lines[r]) && !comment_only(A.lines[r])) gap = true;
            if (gap) break;
            k++;
            end = std::max(end, rows[k].second);
        }
        if (end > rows[i].first) j.obj().key("startLine").num(rows[i].first).key("endLine").num(end).key("kind").str("imports").end_obj();
        i = k + 1;
    }
    j.end_arr();
    return j.s;
}

std::string op_find(Doc& d, const std::string& name) {
    Analysis& A = analysis_of(d);
    if (A.scopes.empty()) return "null";
    auto it = A.scopes[0].syms.find(name);
    if (it == A.scopes[0].syms.end()) return "null";
    J j;
    sym_json(j, A, it->second);
    return j.s;
}

// a member `attr` of the module-level class `cls` (its bases in this file too)
std::string op_find_member(Doc& d, const std::string& cls, const std::string& attr) {
    Analysis& A = analysis_typing(d);
    if (A.scopes.empty()) return "null";
    auto it = A.scopes[0].syms.find(cls);
    if (it == A.scopes[0].syms.end() || A.syms[(size_t)it->second].body < 0) return "null";
    Resolver R(A);
    int m = R.member(A.syms[(size_t)it->second].body, attr, 0);
    if (m < 0 || A.syms[(size_t)m].kind == 'u') return "null";
    J j;
    sym_json(j, A, m);
    return j.s;
}

// ── editing ──────────────────────────────────────────────────────────────────
size_t offset_of(const PieceTable& pt, long long line, long long ch) {
    if (line < 0) return 0;
    if ((size_t)line >= pt.line_count()) return pt.total;
    size_t base = pt.line_start((size_t)line);
    std::string ln = pt.line((size_t)line);
    return base + byte_of_col(ln, ch, g_enc);
}

std::string op_edit(Doc& d, const std::vector<std::string>& a) {
    // edit h sl sc el ec text
    long long sl = to_ll(a[2], -1), sc = to_ll(a[3], 0), el = to_ll(a[4], -1), ec = to_ll(a[5], 0);
    const std::string& text = a[6];
    if (sl < 0) { d.pt.reset(text); d.same_lines = false; }
    else {
        size_t o0 = offset_of(d.pt, sl, sc), o1 = offset_of(d.pt, el, ec);
        if (o1 < o0) std::swap(o0, o1);
        if (sl != el || text.find('\n') != std::string::npos || text.find('\r') != std::string::npos) d.same_lines = false;
        else d.typed_rows.insert(sl);
        d.pt.replace(o0, o1 - o0, text);
    }
    d.edits++;
    d.dirty = true;
    return std::to_string(d.pt.line_count());
}

std::string op_debug(const std::vector<std::string>& a);

}  // namespace

namespace nylsp {
std::string call(const std::vector<std::string>& a) {
    const std::string op = a.empty() ? std::string() : a[0];
    auto need = [&](size_t n) { if (a.size() < n) throw std::runtime_error("_ny_lsp(\"" + op + "\"): " + std::to_string(n - 1) + " arguments expected"); };
    if (op == "open") {
        // open text path [python: "" decided by the path / "1" / "0"]
        need(2);
        auto d = std::make_unique<Doc>();
        d->pt.reset(a[1]);
        if (a.size() > 2) d->path = a[2];
        if (a.size() > 3 && !a[3].empty()) { d->python_forced = true; d->python = a[3] == "1"; }
        long long h = g_next_doc++;
        g_docs[h] = std::move(d);
        return std::to_string(h);
    }
    if (op == "open_file") {
        // open_file path -> a handle, "" when it cannot be read
        need(2);
        std::ifstream in(a[1], std::ios::binary);
        if (!in) return std::string();
        std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        auto d = std::make_unique<Doc>();
        d->pt.reset(text);
        d->path = a[1];
        long long h = g_next_doc++;
        g_docs[h] = std::move(d);
        return std::to_string(h);
    }
    if (op == "close") { need(2); g_docs.erase(to_ll(a[1], -1)); return std::string(); }
    if (op == "encoding") {
        need(2);
        g_enc = a[1] == "utf-8" ? Enc::U8 : a[1] == "utf-32" ? Enc::U32 : Enc::U16;
        return std::string();
    }
    if (op == "builtins") {
        // name\tkind lines
        need(2);
        g_builtins.clear();
        std::istringstream in(a[1]);
        std::string ln;
        while (std::getline(in, ln)) {
            size_t t = ln.find('\t');
            if (t == std::string::npos) g_builtins[ln] = 'v';
            else g_builtins[ln.substr(0, t)] = t + 1 < ln.size() ? ln[t + 1] : 'v';
        }
        for (auto& kv : g_docs) kv.second->dirty = true;
        return std::to_string(g_builtins.size());
    }
    if (op == "debug") return op_debug(a);
    if (op == "docs") return std::to_string(g_docs.size());
    need(2);
    Doc& d = doc_of(a);
    if (op == "set_text") { need(3); d.pt.reset(a[2]); d.dirty = true; d.same_lines = false; d.edits++; return std::string(); }
    if (op == "set_path") { need(3); d.path = a[2]; d.dirty = true; return std::string(); }
    if (op == "edit") { need(7); return op_edit(d, a); }
    if (op == "text") return d.pt.text();
    if (op == "line") { need(3); long long n = to_ll(a[2], -1); return n < 0 || (size_t)n >= d.pt.line_count() ? std::string() : d.pt.line((size_t)n); }
    if (op == "line_count") return std::to_string(d.pt.line_count());
    if (op == "pieces") return std::to_string(d.pt.ps.size());
    if (op == "analyze") return op_analyze(d);
    if (op == "dirty") return d.dirty ? "1" : "0";
    if (op == "generation") return std::to_string(d.generation);
    if (op == "symbols") return op_symbols(d);
    if (op == "tokens") return op_tokens(d);
    if (op == "tokens_delta") { need(3); return op_tokens_delta(d, a[2]); }
    if (op == "at") { need(4); return op_at(d, to_ll(a[2]), to_ll(a[3])); }
    if (op == "sym") { need(3); return op_sym(d, to_ll(a[2], -1)); }
    if (op == "refs") { need(3); return op_refs(d, to_ll(a[2], -1)); }
    if (op == "visible") { need(4); return op_visible(d, to_ll(a[2]), to_ll(a[3])); }
    if (op == "members") { need(3); return op_members(d, to_ll(a[2], -1)); }
    if (op == "exports") return op_exports(d);
    if (op == "imports") return op_imports(d);
    if (op == "ext") return op_ext(d);
    if (op == "calls") { need(4); return op_calls(d, to_ll(a[2]), to_ll(a[3])); }
    if (op == "call_at") { need(4); return op_call_at(d, to_ll(a[2]), to_ll(a[3])); }
    if (op == "context") { need(4); return op_context(d, to_ll(a[2]), to_ll(a[3])); }
    if (op == "folds") return op_folds(d);
    if (op == "verify") {
        // a self-check of the analysis: occurrences whose symbol has another
        // name, and identifiers nothing accounts for (vm_audit122, tools)
        Analysis& A = analysis_of(d);
        J j;
        j.obj().key("mismatch").arr();
        long long unknown = 0, names = 0;
        std::vector<std::string> sample;
        for (size_t i = 0; i < A.toks.size(); i++) {
            const Tk& k = A.toks[i];
            if (A.occ[i] >= 0) {
                names++;
                const Sym& y = A.syms[(size_t)A.occ[i]];
                if (y.name != k.val) {
                    j.obj().key("row").num(k.row).key("col").num(k.col).key("tok").str(k.val).key("sym").str(y.name).end_obj();
                }
            } else if (i < A.nlex && k.type == TokenType::Identifier && A.attr_of_tok[i] < 0 && !g_builtins.count(k.val)
                       && !A.patched[k.row]) {
                unknown++;
                // what comes next tells what it is: a keyword argument, a module path ...
                std::string nx = i + 1 < A.nlex ? A.toks[i + 1].val : std::string();
                std::string pv = i > 0 ? A.toks[i - 1].val : std::string();
                if (a.size() > 2 && a[2] == "1" && nx != "=" && pv != "." && nx != ".")
                    sample.push_back(std::to_string(k.row + 1) + ":" + k.val);
            }
        }
        j.end_arr().key("names").num(names).key("unknown").num(unknown);
        j.key("sample").arr();
        for (size_t s = 0; s < sample.size() && s < 60; s++) j.str(sample[s]);
        j.end_arr();
        j.key("unresolved").num((long long)A.unresolved.size());
        j.end_obj();
        return j.s;
    }
    if (op == "work_text") {
        // the text that parsed after error recovery ("" when it all did), and the rows cut out
        Analysis& A = analysis_of(d);
        J j;
        j.obj().key("text").str(A.recoveries ? A.work_text : std::string()).key("patched").arr();
        for (size_t r = 0; r < A.patched.size(); r++) if (A.patched[r]) j.num((long long)r);
        j.end_arr().end_obj();
        return j.s;
    }
    if (op == "find") { need(3); return op_find(d, a[2]); }
    if (op == "owner") {
        // the def / class symbol whose body scope `a[2]` is
        need(3);
        Analysis& A = analysis_typing(d);
        long long sc = to_ll(a[2], -1);
        if (sc < 0 || sc >= (long long)A.scopes.size() || A.scopes[(size_t)sc].owner < 0) return "null";
        J j;
        sym_json(j, A, A.scopes[(size_t)sc].owner);
        return j.s;
    }
    if (op == "find_member") { need(4); return op_find_member(d, a[2], a[3]); }
    throw std::runtime_error("_ny_lsp: unknown operation '" + op + "'");
}
}  // namespace nylsp

namespace {
const char* ntname(NodeType t) {
    switch (t) {
#define N(x) case NodeType::x: return #x;
        N(SCRIPT) N(STATEMENT) N(STATEMENTS) N(TUPLE) N(LIST) N(MAP) N(MAP_ENTRY) N(ARRAY) N(FLOAT) N(INTEGER) N(STRING)
        N(TRUE) N(FALSE) N(NONE) N(UNDEFINED) N(CALL) N(WITH) N(WITH_ITEM) N(CONST) N(LET) N(INTERVAL) N(GLOBAL) N(COMPLEX)
        N(DEPACK) N(DELETE) N(KEYWORD) N(KEYWORD_ARG) N(SLICE) N(RANGE) N(VARIABLE) N(VARIABLE_DECL) N(ASSIGNMENT)
        N(ASSIGNMENT_AUG) N(YIELD) N(YIELD_FROM) N(WALRUS) N(RETURN) N(BREAK) N(CONTINUE) N(BLOCK) N(ATTRIBUTE) N(SUBSCRIPT)
        N(VAR_ARGS) N(SUPER) N(LAMBDA) N(FUNCTION) N(METHOD) N(CLASS) N(ENUM) N(ENUM_ITEM) N(REF) N(INTERFACE) N(NAMESPACE)
        N(PACKAGE) N(IMPORT) N(SELF) N(PASS) N(IF) N(ELSE) N(ELSEIF) N(FOR) N(WHILE) N(SWITCH) N(CASE) N(DEFAULT) N(REPEAT)
        N(UNLESS) N(TRY) N(FINALLY) N(EXCEPT) N(EXCEPT_ITEM) N(RAISE) N(ASSERT) N(PRINT) N(EXECUTE) N(UNARY) N(BINARY)
        N(BINARY_OP) N(BINARY_RE) N(OPERATOR) N(LOOP) N(MACRO_CALL) N(DYN_BINOP) N(COMPREHENSION) N(OPT_CHAIN) N(CHAIN_HOLE)
        N(BYTES) N(PY_AST)
#undef N
    }
    return "?";
}

// debug src [ast: "1" the ast-mode tree] - the tokens and the tree, as text
std::string op_debug(const std::vector<std::string>& a) {
    std::string src = a.size() > 1 ? a[1] : std::string();
    bool ast = a.size() > 2 && a[2] == "1";
    std::ostringstream o;
    try {
        auto source = SourceCode::from_text(src + "\n", "<debug>.ny");
        Reporter reporter(source);
        Lexer lexer(source);
        Parser parser(&reporter, nullptr, &lexer);
        lexer.tokenize();
        int i = 0;
        for (auto& t : lexer.tokens)
            o << i++ << " " << TokenTypeNames[t.type()] << " cls=" << (int)t.clazz() << " '" << t.value << "' " << t.line() << ":" << t.column() << "-" << t.end_row << ":" << t.end_col << "\n";
        node_ptr root = ast ? parser.parseAst("exec") : parser.parse();
        std::function<void(const node_ptr&, int)> dump = [&](const node_ptr& n, int d) {
            if (!n) return;
            o << std::string((size_t)d * 2, ' ') << ntname(n->type()) << " '" << n->tok().value << "' @" << n->tok().line() << ":" << n->tok().column();
            auto sp = parser.ast_spans_.find(n.get());
            if (sp != parser.ast_spans_.end()) o << " span=" << sp->second.first << ".." << sp->second.second;
            if (n->type() == NodeType::PY_AST) o << " kind=" << static_cast<PyAstNode*>(n.get())->kind;
            if (n->type() == NodeType::VARIABLE) o << " name=" << static_cast<VariableNode*>(n.get())->name;
            if (n->type() == NodeType::ATTRIBUTE) o << " attr=" << static_cast<AttributeNode*>(n.get())->attr;
            if (n->type() == NodeType::FUNCTION) o << " def=" << static_cast<FunctionNode*>(n.get())->name;
            if (n->type() == NodeType::CLASS) o << " class=" << static_cast<ClassNode*>(n.get())->name;
            o << "\n";
            std::vector<node_ptr> kids;
            switch (n->type()) {
            case NodeType::FUNCTION: { auto* f = static_cast<FunctionNode*>(n.get()); kids = f->params; kids.push_back(f->body); break; }
            case NodeType::CLASS: { auto* c = static_cast<ClassNode*>(n.get()); kids = c->bases; kids.push_back(c->body); break; }
            case NodeType::ATTRIBUTE: kids.push_back(static_cast<AttributeNode*>(n.get())->object); break;
            case NodeType::ASSIGNMENT: { auto* x = static_cast<AssignmentNode*>(n.get()); kids = {x->target, x->value_node}; break; }
            case NodeType::CALL: { auto* c = static_cast<CallNode*>(n.get()); kids = c->args; kids.insert(kids.begin(), c->callee); break; }
            case NodeType::FOR: { auto* f = static_cast<ForNode*>(n.get()); kids = {f->var, f->iterable, f->body}; break; }
            case NodeType::VARIABLE_DECL: kids.push_back(static_cast<VarDeclNode*>(n.get())->init); break;
            case NodeType::RETURN: kids.push_back(static_cast<ReturnNode*>(n.get())->expr); break;
            case NodeType::IF: { auto* x = static_cast<IfNode*>(n.get()); kids = {x->condition, x->then_branch, x->else_branch}; break; }
            case NodeType::BINARY: { auto* x = static_cast<BinaryNode*>(n.get()); kids = {x->left, x->right}; break; }
            case NodeType::KEYWORD_ARG: kids.push_back(static_cast<KeywordArgNode*>(n.get())->val); break;
            default: kids = n->statements(); break;
            }
            for (auto& k : kids) dump(k, d + 1);
        };
        dump(root, 0);
    } catch (nython::exception::Error& e) {
        o << "ERROR " << e.location().row << ":" << e.location().column << " " << e.message() << "\n";
    }
    return o.str();
}
}  // namespace
