// builtins/text.cpp
// Native text services: the whole-document and whole-workspace work an editor
// does on every keystroke or pause, done in C++ instead of Nython.
//
// Why native: the interpreter spends ~1-3 us per Nython statement and never
// frees what a loop allocates (GC_NOTES.md). The IDE rebuilt its completion
// word list by walking every line of the document in Nython on each typed
// character (1,800 lines: ~280 ms per key), checked syntax by spawning a
// second interpreter (--ast) and waiting for it, ran a Myers diff and a
// workspace search as script loops. Each of these is a few milliseconds here.
//
//   text_words(lines, min_len=3, limit=20000)        unique identifiers, first-seen order
//   ny_symbols(lines)                                 outline: [name, kind, row, col, container, detail, depth]
//   ny_check_syntax(source)                           [[row, col, message], ...] from the real lexer/parser
//   text_diff(a_lines, b_lines, max_d=4000)           hunks [a_start, a_len, b_start, b_len] (Myers)
//   fs_list_files(root, max=20000, skip=[...])        relative paths of every file under root, sorted
//   fs_search(root, needle, opts={})                  [[relpath, row, col, text, len], ...]
//   text_fold_ranges(lines, tab=4)                    [[start_row, end_row], ...] by indentation + #region
//   text_line_stats(lines)                            [total, code, comment, blank, docstring]
//   text_todos(lines, tags=[...])                     [[row, col, tag, text, owner], ...]
//   fs_todos(root, tags=[...], max=5000)              [[relpath, row, col, tag, text, owner], ...]
//   text_format_nython(source, indent_unit, opts)     conservative formatter (see below)
//
// Lists arrive either as a Nython list of strings or as one string (split on
// newlines). All rows/columns are 0-based; columns count characters.

#include "platform_compat.hpp"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <sys/stat.h>
#include <dirent.h>

#include "NythonExecutor.hpp"
#include "NyFuzzy.hpp"
#include "builtins/text.hpp"

using namespace nython;
using namespace nython::kernel;
using namespace nython::lexer;
using namespace nython::parser;

namespace {

// ── value helpers ────────────────────────────────────────────────────────────
Container* as_container(const Value& v) {
    if (!v.isCollectable() || !v.value.gc) return nullptr;
    auto* c = dynamic_cast<Container*>(v.value.gc);
    return (c && c->container) ? c : nullptr;
}

int list_len(Container* c) {
    auto li = c->container->find("__len__");
    return li != c->container->end() ? (int)bigint_to_i64(li->second.value.i) : 0;
}

void split_lines(const std::string& s, std::vector<std::string>& out) {
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

// A list of strings, or one string split into lines.
std::vector<std::string> lines_of(NythonExecutor& E, const Value& v) {
    std::vector<std::string> out;
    if (Container* c = as_container(v)) {
        int n = list_len(c);
        out.reserve((size_t)std::max(0, n));
        for (int i = 0; i < n; i++) {
            auto it = c->container->find(std::to_string(i));
            out.push_back(it != c->container->end() ? E.getStringValue(it->second) : std::string());
        }
        return out;
    }
    if (v.type == ValueType::NONE || v.type == ValueType::UNDEFINED) return out;
    split_lines(E.getStringValue(v), out);
    return out;
}

std::vector<std::string> strings_of(NythonExecutor& E, const Value& v) {
    std::vector<std::string> out;
    if (Container* c = as_container(v)) {
        int n = list_len(c);
        for (int i = 0; i < n; i++) {
            auto it = c->container->find(std::to_string(i));
            if (it != c->container->end()) out.push_back(E.getStringValue(it->second));
        }
    }
    return out;
}

Value opt(NythonExecutor& /*E*/, const Value& m, const char* key) {
    if (Container* c = as_container(m)) {
        auto it = c->container->find(key);
        if (it != c->container->end()) return it->second;
    }
    return UNDEFINED_VALUE;
}

bool opt_bool(NythonExecutor& E, const Value& m, const char* key, bool dflt) {
    Value v = opt(E, m, key);
    if (v.type == ValueType::BOOLEAN) return v.value.b;
    if (v.type == ValueType::INTEGER) return bigint_to_i64(v.value.i) != 0;
    return dflt;
}

long long opt_int(NythonExecutor& E, const Value& m, const char* key, long long dflt) {
    Value v = opt(E, m, key);
    if (v.type == ValueType::INTEGER) return bigint_to_i64(v.value.i);
    if (v.type == ValueType::DOUBLE) return (long long)v.value.d;
    return dflt;
}

long long int_arg(const std::vector<Value>& args, size_t i, long long dflt) {
    if (i >= args.size()) return dflt;
    if (args[i].type == ValueType::INTEGER) return bigint_to_i64(args[i].value.i);
    if (args[i].type == ValueType::DOUBLE) return (long long)args[i].value.d;
    return dflt;
}

struct ListBuilder {
    NythonExecutor& E;
    Object* obj;
    int n = 0;
    explicit ListBuilder(NythonExecutor& e) : E(e), obj(new Object((Runnable*)e.runner, "list", Type::LIST)) {}
    void add(const Value& v) { obj->set(std::to_string(n++), v); }
    void add_str(const std::string& s) { add(E.makeStringValue(s)); }
    void add_int(long long x) { add(Value(bigint(x))); }
    Value done() { obj->set("__len__", Value(n)); return Value((Collectable*)obj); }
};

// ── characters ───────────────────────────────────────────────────────────────
inline bool id_start(unsigned char c) { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80; }
inline bool id_char(unsigned char c) { return id_start(c) || (c >= '0' && c <= '9'); }
inline bool u8_cont(unsigned char c) { return (c & 0xC0) == 0x80; }

// Character index of byte offset b in s.
long long char_col(const std::string& s, size_t b) {
    long long n = 0;
    for (size_t i = 0; i < b && i < s.size(); i++) if (!u8_cont((unsigned char)s[i])) n++;
    return n;
}

size_t indent_width(const std::string& s, int tab) {
    size_t w = 0;
    for (char c : s) {
        if (c == ' ') w++;
        else if (c == '\t') w += (size_t)tab - (w % (size_t)tab);
        else break;
    }
    return w;
}

bool is_blank(const std::string& s) {
    for (char c : s) if (c != ' ' && c != '\t' && c != '\r') return false;
    return true;
}

std::string lstrip(const std::string& s) {
    size_t i = 0;
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
    return s.substr(i);
}

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r')) a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r')) b--;
    return s.substr(a, b - a);
}

bool starts_with(const std::string& s, const char* p) {
    size_t n = strlen(p);
    return s.size() >= n && s.compare(0, n, p) == 0;
}

// Scans a line for the parts that are code, marking string and comment
// spans, carrying an open triple-quoted string across lines in `in_triple`
// (0 none, else the quote char). code_mask[i] = true where s[i] is code.
void scan_line(const std::string& s, char& in_triple, std::vector<bool>& code_mask,
               bool* has_comment = nullptr, bool* has_code = nullptr) {
    code_mask.assign(s.size(), false);
    size_t i = 0;
    bool comment = false, code = false;
    while (i < s.size()) {
        if (in_triple) {
            if (i + 2 < s.size() + 0 && s[i] == in_triple && i + 2 < s.size() && s[i + 1] == in_triple && s[i + 2] == in_triple) {
                in_triple = 0;
                i += 3;
                continue;
            }
            if (s[i] == '\\') i++;
            i++;
            continue;
        }
        char c = s[i];
        if (c == '#') { comment = true; break; }
        if (c == '/' && i + 1 < s.size() && s[i + 1] == '/') { comment = true; break; }
        if (c == '"' || c == '\'') {
            if (i + 2 < s.size() && s[i + 1] == c && s[i + 2] == c) {
                in_triple = c;
                code = true;
                i += 3;
                continue;
            }
            code = true;
            size_t j = i + 1;
            while (j < s.size() && s[j] != c) {
                if (s[j] == '\\') j++;
                j++;
            }
            i = j + 1;
            continue;
        }
        if (c != ' ' && c != '\t' && c != '\r') code = true;
        code_mask[i] = true;
        i++;
    }
    if (has_comment) *has_comment = comment;
    if (has_code) *has_code = code;
}

// ── text_words ───────────────────────────────────────────────────────────────
Value text_words(NythonExecutor& E, std::vector<Value>& args) {
    auto lines = args.empty() ? std::vector<std::string>() : lines_of(E, args[0]);
    size_t min_len = (size_t)std::max(1LL, int_arg(args, 1, 3));
    size_t limit = (size_t)std::max(1LL, int_arg(args, 2, 20000));
    std::unordered_set<std::string> seen;
    ListBuilder out(E);
    std::vector<bool> mask;
    char triple = 0;
    for (auto& s : lines) {
        // Words inside strings and comments count too (a name mentioned in a
        // docstring is still worth completing), so only the scan is skipped.
        size_t i = 0;
        while (i < s.size()) {
            unsigned char c = (unsigned char)s[i];
            if (id_start(c) && !(i > 0 && id_char((unsigned char)s[i - 1]))) {
                size_t j = i;
                while (j < s.size() && id_char((unsigned char)s[j])) j++;
                if (j - i >= min_len) {
                    std::string w = s.substr(i, j - i);
                    if (seen.insert(w).second) {
                        out.add_str(w);
                        if (seen.size() >= limit) return out.done();
                    }
                }
                i = j;
            } else i++;
        }
    }
    (void)mask; (void)triple;
    return out.done();
}

// ── ny_symbols ───────────────────────────────────────────────────────────────
// A tolerant, line-based outline of Nython source that works while the file
// is mid-edit and does not parse: classes (with their bases), functions and
// methods (with their parameter lists), fields (self.x = ... inside a
// method, once per class), module-level variables/constants, enums, structs,
// interfaces and namespaces. Kinds: class function method field variable
// constant enum struct interface namespace.
struct SymScope { size_t indent; std::string name; bool is_class; };

std::string read_ident(const std::string& s, size_t& i) {
    size_t j = i;
    while (j < s.size() && id_char((unsigned char)s[j])) j++;
    std::string out = s.substr(i, j - i);
    i = j;
    return out;
}

void skip_ws(const std::string& s, size_t& i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
}

// The text between the bracket at s[i] and its partner (same line only).
std::string bracket_text(const std::string& s, size_t i) {
    if (i >= s.size()) return std::string();
    char open = s[i], close = open == '(' ? ')' : open == '[' ? ']' : '}';
    int depth = 0;
    for (size_t j = i; j < s.size(); j++) {
        if (s[j] == open) depth++;
        else if (s[j] == close) {
            depth--;
            if (depth == 0) return s.substr(i + 1, j - i - 1);
        }
    }
    return s.substr(i + 1);
}

struct Sym { std::string name, kind, container, detail; long long row, col, depth; };

std::vector<Sym> scan_symbols(const std::vector<std::string>& lines) {
    std::vector<Sym> out;
    std::vector<SymScope> scopes;
    std::set<std::pair<std::string, std::string>> fields_seen;
    char triple = 0;
    std::vector<bool> mask;
    for (size_t row = 0; row < lines.size(); row++) {
        const std::string& raw = lines[row];
        bool was_in_triple = triple != 0;
        bool has_comment = false, has_code = false;
        scan_line(raw, triple, mask, &has_comment, &has_code);
        if (was_in_triple || is_blank(raw)) continue;
        size_t ind = indent_width(raw, 4);
        std::string s = lstrip(raw);
        if (s.empty() || s[0] == '#') continue;
        while (!scopes.empty() && scopes.back().indent >= ind) scopes.pop_back();
        size_t col = raw.size() - s.size();
        size_t i = 0;
        auto emit = [&](const std::string& name, const char* kind, size_t name_col, const std::string& container,
                        const std::string& detail) {
            out.push_back({name, kind, container, detail, (long long)row, char_col(raw, name_col),
                           (long long)scopes.size()});
        };
        std::string container;
        bool in_class = false;
        for (auto it = scopes.rbegin(); it != scopes.rend(); ++it)
            if (it->is_class) { container = it->name; in_class = (&*it == &scopes.back()); break; }
        if (starts_with(s, "async ")) { i = 6; skip_ws(s, i); }
        size_t kw_at = i;
        std::string kw = read_ident(s, i);
        if (kw == "class" || kw == "struct" || kw == "interface" || kw == "enum" || kw == "namespace" || kw == "module") {
            skip_ws(s, i);
            size_t nat = i;
            std::string name = read_ident(s, i);
            if (name.empty()) continue;
            std::string detail;
            skip_ws(s, i);
            if (i < s.size() && s[i] == '(') detail = trim(bracket_text(s, i));
            else if (starts_with(s.substr(i), "extends ") || starts_with(s.substr(i), "implements ")) {
                std::string rest = s.substr(i);
                size_t colon = rest.rfind(':');
                detail = trim(rest.substr(0, colon == std::string::npos ? rest.size() : colon));
            } else if (kw == "struct" && i < s.size() && s[i] == ':') {
                detail = trim(s.substr(i + 1));
            }
            const char* kind = kw == "class" ? "class" : kw == "struct" ? "struct" : kw == "interface" ? "interface"
                             : kw == "enum" ? "enum" : "namespace";
            emit(name, kind, col + nat, container, detail);
            if (kw != "enum") scopes.push_back({ind, name, kw == "class" || kw == "struct" || kw == "interface"});
            continue;
        }
        if (kw == "def" || kw == "fn" || kw == "func" || kw == "function") {
            skip_ws(s, i);
            size_t nat = i;
            std::string name = read_ident(s, i);
            if (name.empty()) continue;
            skip_ws(s, i);
            std::string params = (i < s.size() && s[i] == '(') ? trim(bracket_text(s, i)) : std::string();
            emit(name, in_class ? "method" : "function", col + nat, container, "(" + params + ")");
            scopes.push_back({ind, name, false});
            continue;
        }
        (void)kw_at;
        // Fields: self.x = ... in a method of a class.
        if (starts_with(s, "self.") && !container.empty()) {
            size_t j = 5;
            size_t nat = j;
            std::string name = read_ident(s, j);
            skip_ws(s, j);
            if (!name.empty() && j < s.size() && s[j] == '=' && (j + 1 >= s.size() || s[j + 1] != '=')) {
                if (fields_seen.insert({container, name}).second)
                    emit(name, "field", col + nat, container, std::string());
            }
            continue;
        }
        // Module-level (and class-level) variables.
        if (scopes.empty() || in_class) {
            size_t j = 0;
            bool is_const = false;
            if (starts_with(s, "var ")) j = 4;
            else if (starts_with(s, "let ")) j = 4;
            else if (starts_with(s, "const ")) { j = 6; is_const = true; }
            skip_ws(s, j);
            size_t nat = j;
            if (j < s.size() && id_start((unsigned char)s[j])) {
                std::string name = read_ident(s, j);
                skip_ws(s, j);
                if (j < s.size() && s[j] == ':' && j + 1 < s.size() && s[j + 1] != '=') {
                    // annotated: name: T = v
                    while (j < s.size() && s[j] != '=') j++;
                }
                bool assign = j < s.size() && s[j] == '=' && (j + 1 >= s.size() || s[j + 1] != '=');
                bool reserved = name == "if" || name == "elif" || name == "while" || name == "for" || name == "return"
                             || name == "print" || name == "import" || name == "from" || name == "else" || name == "try";
                if (assign && !reserved) {
                    bool upper = true;
                    for (char ch : name) if (ch >= 'a' && ch <= 'z') { upper = false; break; }
                    emit(name, (is_const || (upper && name.size() > 1)) ? "constant" : (in_class ? "field" : "variable"),
                         col + nat, container, std::string());
                }
            }
        }
    }
    return out;
}

Value ny_symbols(NythonExecutor& E, std::vector<Value>& args) {
    auto lines = args.empty() ? std::vector<std::string>() : lines_of(E, args[0]);
    ListBuilder out(E);
    for (auto& sm : scan_symbols(lines)) {
        ListBuilder item(E);
        item.add_str(sm.name);
        item.add_str(sm.kind);
        item.add_int(sm.row);
        item.add_int(sm.col);
        item.add_str(sm.container);
        item.add_str(sm.detail);
        item.add_int(sm.depth);
        out.add(item.done());
    }
    return out.done();
}

// ── ny_check_syntax ──────────────────────────────────────────────────────────
Value ny_check_syntax(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    std::string src;
    if (as_container(args[0])) {
        // A buffer's line list: joined here instead of by the caller, so the
        // editor does not build (and keep) a copy of the whole text per check.
        auto lines = lines_of(E, args[0]);
        for (size_t i = 0; i < lines.size(); i++) { if (i) src += '\n'; src += lines[i]; }
    } else src = E.getStringValue(args[0]);
    // SourceCode(string) treats an existing path as a file to read; a buffer
    // whose whole text happens to name a file must still be parsed as text.
    if (nython::utils::FileExists(src)) src += "\n";
    try {
        auto source = SourceCode(src);
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer = std::make_shared<Lexer>(source);
        auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)E.runner, lexer.get());
        lexer->tokenize();
        parser->parse();
    } catch (nython::exception::Error& e) {
        ListBuilder d(E);
        d.add_int((long long)e.location().row - 1);
        d.add_int((long long)e.location().column - 1);
        d.add_str(e.message());
        out.add(d.done());
    } catch (std::exception& e) {
        ListBuilder d(E);
        d.add_int(0); d.add_int(0); d.add_str(e.what());
        out.add(d.done());
    } catch (std::string& s) {
        ListBuilder d(E);
        d.add_int(0); d.add_int(0); d.add_str(s);
        out.add(d.done());
    } catch (...) {
        ListBuilder d(E);
        d.add_int(0); d.add_int(0); d.add_str("could not be parsed");
        out.add(d.done());
    }
    return out.done();
}

// ── text_diff (Myers, O((N+M)D) time, snapshots of V for the backtrack) ─────
struct Hunk { int a0, al, b0, bl; };

std::vector<Hunk> myers_hunks(const std::vector<std::string>& a, const std::vector<std::string>& b,
                              size_t nb, long long max_d) {
    std::vector<Hunk> out;
    if (nb > b.size()) nb = b.size();
    // Trim the common prefix and suffix; most edits are local.
    size_t pre = 0;
    while (pre < a.size() && pre < nb && a[pre] == b[pre]) pre++;
    size_t suf = 0;
    while (suf < a.size() - pre && suf < nb - pre && a[a.size() - 1 - suf] == b[nb - 1 - suf]) suf++;
    int n = (int)(a.size() - pre - suf), m = (int)(nb - pre - suf);
    auto A = [&](int i) -> const std::string& { return a[pre + (size_t)i]; };
    auto B = [&](int j) -> const std::string& { return b[pre + (size_t)j]; };
    auto emit = [&](int as, int al, int bs, int bl) { out.push_back({(int)pre + as, al, (int)pre + bs, bl}); };
    if (n == 0 && m == 0) return out;
    if (n == 0 || m == 0) { emit(0, n, 0, m); return out; }
    int maxd = n + m;
    if (max_d > 0 && maxd > max_d) maxd = (int)max_d;
    int off = n + m + 1;
    std::vector<int> v((size_t)(2 * (n + m) + 3), 0);
    std::vector<std::vector<int>> trace;
    int found_d = -1;
    for (int d = 0; d <= maxd; d++) {
        trace.push_back(v);
        for (int k = -d; k <= d; k += 2) {
            int x;
            if (k == -d || (k != d && v[(size_t)(off + k - 1)] < v[(size_t)(off + k + 1)])) x = v[(size_t)(off + k + 1)];
            else x = v[(size_t)(off + k - 1)] + 1;
            int y = x - k;
            while (x < n && y < m && A(x) == B(y)) { x++; y++; }
            v[(size_t)(off + k)] = x;
            if (x >= n && y >= m) { found_d = d; break; }
        }
        if (found_d >= 0) break;
    }
    if (found_d < 0) { emit(0, n, 0, m); return out; }
    // Backtrack: trace[d] is V as it was before round d, so the move that
    // reached (x, y) in round d came from diagonal k+1 (an insertion) or k-1
    // (a deletion); a snake of equal lines (recording nothing) then led to
    // (x, y).
    struct Edit { int a0, a1, b0, b1; };
    std::vector<Edit> edits;
    int x = n, y = m;
    for (int d = found_d; d > 0; d--) {
        auto& vv = trace[(size_t)d];
        int k = x - y;
        int pk = (k == -d || (k != d && vv[(size_t)(off + k - 1)] < vv[(size_t)(off + k + 1)])) ? k + 1 : k - 1;
        int px = vv[(size_t)(off + pk)];
        int py = px - pk;
        if (pk == k + 1) edits.push_back({px, px, py, py + 1});   // insertion of b[py]
        else edits.push_back({px, px + 1, py, py});                // deletion of a[px]
        x = px; y = py;
    }
    std::reverse(edits.begin(), edits.end());
    int ha0 = -1, ha1 = -1, hb0 = -1, hb1 = -1;
    for (auto& e : edits) {
        if (ha0 >= 0 && e.a0 == ha1 && e.b0 == hb1) { ha1 = e.a1; hb1 = e.b1; continue; }
        if (ha0 >= 0) emit(ha0, ha1 - ha0, hb0, hb1 - hb0);
        ha0 = e.a0; ha1 = e.a1; hb0 = e.b0; hb1 = e.b1;
    }
    if (ha0 >= 0) emit(ha0, ha1 - ha0, hb0, hb1 - hb0);
    return out;
}

Value text_diff(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.size() < 2) return out.done();
    auto a = lines_of(E, args[0]);
    auto b = lines_of(E, args[1]);
    for (auto& h : myers_hunks(a, b, b.size(), int_arg(args, 2, 4000))) {
        ListBuilder hb(E);
        hb.add_int(h.a0); hb.add_int(h.al); hb.add_int(h.b0); hb.add_int(h.bl);
        out.add(hb.done());
    }
    return out.done();
}

// text_diff_classify(old_lines_or_none, new_lines, nb=len(new)) -> one kind
// per new line, as the editor gutter draws them: 0 unchanged, 1 added,
// 2 modified (a deletion run meeting an insertion run), 3 unchanged but
// with lines deleted just below it. The same rules as lib/ide_scm.ny's
// LineDiff.classify, whose Nython Myers diff this replaces in the editor.
Value text_diff_classify(NythonExecutor& E, std::vector<Value>& args) {
    auto b = args.size() > 1 ? lines_of(E, args[1]) : std::vector<std::string>();
    size_t nb = (size_t)std::max(0LL, int_arg(args, 2, (long long)b.size()));
    if (nb > b.size()) nb = b.size();
    std::vector<int> kinds(nb, 0);
    bool no_base = args.empty() || args[0].type == ValueType::NONE || args[0].type == ValueType::UNDEFINED;
    if (no_base) std::fill(kinds.begin(), kinds.end(), 1);
    else {
        auto a = lines_of(E, args[0]);
        for (auto& h : myers_hunks(a, b, nb, int_arg(args, 3, 4000))) {
            for (int t = 0; t < h.bl; t++) {
                size_t r = (size_t)(h.b0 + t);
                if (r < nb) kinds[r] = t < h.al ? 2 : 1;
            }
            if (h.al > h.bl) {
                long long at = h.bl > 0 ? h.b0 + h.bl - 1 : h.b0 - 1;
                if (at < 0) at = 0;
                if ((size_t)at < nb && kinds[(size_t)at] == 0) kinds[(size_t)at] = 3;
            }
        }
    }
    ListBuilder out(E);
    for (int k : kinds) out.add(Value(k));
    return out.done();
}

// ── workspace walking ────────────────────────────────────────────────────────
const char* kDefaultSkip[] = {".git", ".hg", ".svn", "node_modules", "__pycache__", ".nyide_cache", "build", ".cache", nullptr};

bool is_dir(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

void walk(const std::string& root, const std::string& rel, const std::unordered_set<std::string>& skip,
          size_t max, std::vector<std::string>& out, int depth, bool skip_hidden = false, int max_depth = 40) {
    if (out.size() >= max || depth > max_depth) return;
    std::string dir = rel.empty() ? root : root + "/" + rel;
    DIR* d = opendir(dir.c_str());
    if (!d) return;
    std::vector<std::string> names;
    while (dirent* e = readdir(d)) {
        std::string nm = e->d_name;
        if (nm == "." || nm == "..") continue;
        if (skip_hidden && nm[0] == '.') continue;
        names.push_back(nm);
    }
    closedir(d);
    std::sort(names.begin(), names.end());
    std::vector<std::string> dirs;
    for (auto& nm : names) {
        std::string r = rel.empty() ? nm : rel + "/" + nm;
        std::string full = root + "/" + r;
        if (is_dir(full)) {
            if (!skip.count(nm)) dirs.push_back(r);
        } else {
            out.push_back(r);
            if (out.size() >= max) return;
        }
    }
    for (auto& r : dirs) walk(root, r, skip, max, out, depth + 1, skip_hidden, max_depth);
}

std::unordered_set<std::string> skip_set(NythonExecutor& E, const Value& v) {
    std::unordered_set<std::string> skip;
    if (as_container(v)) for (auto& s : strings_of(E, v)) skip.insert(s);
    else for (int i = 0; kDefaultSkip[i]; i++) skip.insert(kDefaultSkip[i]);
    return skip;
}

// fs_list_files(root, opts={}) opts: max (20000), skip [dir names] (default
// .git build node_modules __pycache__ ...), hidden (true: include dot
// names), depth (40), full (false: paths relative to root).
Value fs_list_files(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    std::string root = E.getStringValue(args[0]);
    while (root.size() > 1 && (root.back() == '/' || root.back() == '\\')) root.pop_back();
    Value o = args.size() > 1 ? args[1] : UNDEFINED_VALUE;
    size_t max = (size_t)std::max(1LL, opt_int(E, o, "max", 20000));
    auto skip = skip_set(E, opt(E, o, "skip"));
    bool hidden = opt_bool(E, o, "hidden", false);
    int depth = (int)opt_int(E, o, "depth", 40);
    bool full = opt_bool(E, o, "full", false);
    std::vector<std::string> files;
    walk(root, "", skip, max, files, 0, !hidden, depth);
    for (auto& f : files) out.add_str(full ? root + "/" + f : f);
    return out.done();
}

bool looks_binary(const std::string& s) {
    size_t n = std::min<size_t>(s.size(), 4096);
    for (size_t i = 0; i < n; i++) if (s[i] == '\0') return true;
    return false;
}

bool read_small(const std::string& path, size_t max_size, std::string& out) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0 || (size_t)st.st_size > max_size) return false;
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    out.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    return !looks_binary(out);
}

// Glob with * ? and ** over '/'-separated relative paths; a pattern without
// '/' matches the file name anywhere.
bool glob_match(const char* p, const char* s) {
    while (*p) {
        if (p[0] == '*' && p[1] == '*') {
            p += 2;
            if (*p == '/') p++;
            for (const char* t = s;; t++) {
                if (glob_match(p, t)) return true;
                if (!*t) return false;
            }
        }
        if (*p == '*') {
            p++;
            for (const char* t = s;; t++) {
                if (glob_match(p, t)) return true;
                if (!*t || *t == '/') return false;
            }
        }
        if (!*s) return false;
        if (*p != '?' && *p != *s) return false;
        p++; s++;
    }
    return *s == 0;
}

bool path_matches(const std::string& rel, const std::vector<std::string>& globs) {
    std::string base = rel.substr(rel.find_last_of('/') == std::string::npos ? 0 : rel.find_last_of('/') + 1);
    for (auto& g : globs) {
        if (g.empty()) continue;
        if (g.find('/') == std::string::npos) { if (glob_match(g.c_str(), base.c_str())) return true; }
        else if (glob_match(g.c_str(), rel.c_str())) return true;
    }
    return false;
}

std::vector<std::string> split_globs(const std::string& s) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == ',') { if (!trim(cur).empty()) out.push_back(trim(cur)); cur.clear(); }
        else cur += c;
    }
    if (!trim(cur).empty()) out.push_back(trim(cur));
    return out;
}

inline char lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }

// fs_search(root, needle, opts) opts: case (false), word (false), regex
// (false), include "a,b", exclude "a,b", max_results (2000), max_files
// (20000), max_size (2 MB), skip [dir names], skip_files [relative paths],
// hidden (false: dot names skipped). Rows 0-based, col in characters.
Value fs_search(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.size() < 2) return out.done();
    std::string root = E.getStringValue(args[0]);
    while (root.size() > 1 && (root.back() == '/' || root.back() == '\\')) root.pop_back();
    std::string needle = E.getStringValue(args[1]);
    if (needle.empty()) return out.done();
    Value o = args.size() > 2 ? args[2] : UNDEFINED_VALUE;
    bool cs = opt_bool(E, o, "case", false);
    bool word = opt_bool(E, o, "word", false);
    bool use_re = opt_bool(E, o, "regex", false);
    size_t max_results = (size_t)opt_int(E, o, "max_results", 2000);
    size_t max_files = (size_t)opt_int(E, o, "max_files", 20000);
    size_t max_size = (size_t)opt_int(E, o, "max_size", 2 * 1024 * 1024);
    Value inc = opt(E, o, "include"), exc = opt(E, o, "exclude");
    auto includes = split_globs(inc.type == ValueType::UNDEFINED ? std::string() : E.getStringValue(inc));
    auto excludes = split_globs(exc.type == ValueType::UNDEFINED ? std::string() : E.getStringValue(exc));
    auto skip = skip_set(E, opt(E, o, "skip"));
    bool hidden = opt_bool(E, o, "hidden", false);
    std::unordered_set<std::string> skip_files;
    for (auto& f : strings_of(E, opt(E, o, "skip_files"))) skip_files.insert(f);
    std::vector<std::string> files;
    walk(root, "", skip, max_files, files, 0, !hidden, 40);
    std::regex re;
    if (use_re) {
        try {
            re = std::regex(needle, cs ? std::regex::ECMAScript : (std::regex::ECMAScript | std::regex::icase));
        } catch (std::regex_error&) { return out.done(); }
    }
    std::string nl = needle;
    if (!cs) for (auto& c : nl) c = lower(c);
    std::string text, low;
    for (auto& rel : files) {
        if (skip_files.count(rel)) continue;
        if (!includes.empty() && !path_matches(rel, includes)) continue;
        if (!excludes.empty() && path_matches(rel, excludes)) continue;
        if (!read_small(root + "/" + rel, max_size, text)) continue;
        std::vector<std::string> lines;
        split_lines(text, lines);
        for (size_t row = 0; row < lines.size(); row++) {
            const std::string& ln = lines[row];
            auto add = [&](size_t at, size_t len) {
                ListBuilder h(E);
                h.add_str(rel);
                h.add_int((long long)row);
                h.add_int(char_col(ln, at));
                h.add_str(ln.size() > 400 ? ln.substr(0, 400) : ln);
                h.add_int(char_col(ln.substr(at), len));
                out.add(h.done());
            };
            if (use_re) {
                for (auto it = std::sregex_iterator(ln.begin(), ln.end(), re); it != std::sregex_iterator(); ++it) {
                    if (it->length(0) == 0) continue;
                    add((size_t)it->position(0), (size_t)it->length(0));
                    if (out.n >= (int)max_results) return out.done();
                }
                continue;
            }
            const std::string* hay = &ln;
            if (!cs) { low = ln; for (auto& c : low) c = lower(c); hay = &low; }
            size_t at = 0;
            while ((at = hay->find(nl, at)) != std::string::npos) {
                bool ok = true;
                if (word) {
                    if (at > 0 && id_char((unsigned char)(*hay)[at - 1])) ok = false;
                    size_t e = at + nl.size();
                    if (e < hay->size() && id_char((unsigned char)(*hay)[e])) ok = false;
                }
                if (ok) {
                    add(at, nl.size());
                    if (out.n >= (int)max_results) return out.done();
                }
                at += std::max<size_t>(1, nl.size());
            }
        }
    }
    return out.done();
}

// fs_symbols(root, opts={}) -> [[relpath, name, kind, row, col, container], ...]
// Every symbol ny_symbols finds, in every file under root whose name matches
// opts.include (default "*.ny"), up to opts.max (20000) symbols.
Value fs_symbols(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    std::string root = E.getStringValue(args[0]);
    while (root.size() > 1 && (root.back() == '/' || root.back() == '\\')) root.pop_back();
    Value o = args.size() > 1 ? args[1] : UNDEFINED_VALUE;
    Value inc = opt(E, o, "include");
    auto includes = split_globs(inc.type == ValueType::UNDEFINED ? std::string("*.ny") : E.getStringValue(inc));
    size_t max = (size_t)std::max(1LL, opt_int(E, o, "max", 20000));
    auto skip = skip_set(E, opt(E, o, "skip"));
    std::vector<std::string> files;
    walk(root, "", skip, 20000, files, 0, true, 40);
    std::string text;
    size_t n = 0;
    for (auto& rel : files) {
        if (n >= max) break;
        if (!includes.empty() && !path_matches(rel, includes)) continue;
        if (!read_small(root + "/" + rel, 2 * 1024 * 1024, text)) continue;
        std::vector<std::string> lines;
        split_lines(text, lines);
        for (auto& sm : scan_symbols(lines)) {
            if (sm.kind == "field" || sm.kind == "variable") continue;   // definitions people jump to
            ListBuilder h(E);
            h.add_str(rel); h.add_str(sm.name); h.add_str(sm.kind);
            h.add_int(sm.row); h.add_int(sm.col); h.add_str(sm.container);
            out.add(h.done());
            if (++n >= max) break;
        }
    }
    return out.done();
}

// ── text_fold_ranges ─────────────────────────────────────────────────────────
// A region starts at a non-blank line followed by more-indented lines and
// runs to the last line of that deeper block (blank lines inside are part of
// it, trailing blank lines are not). "# region" / "# endregion" pairs fold
// too. Ranges are [start, end] rows, start = the header line.
Value text_fold_ranges(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    auto lines = lines_of(E, args[0]);
    int tab = (int)std::max(1LL, int_arg(args, 1, 4));
    int n = (int)lines.size();
    std::vector<int> ind((size_t)n, -1);
    char triple = 0;
    std::vector<bool> mask;
    for (int i = 0; i < n; i++) {
        bool was = triple != 0;
        scan_line(lines[(size_t)i], triple, mask);
        // Continuation lines of a triple-quoted string belong to the line that
        // opened it: treat them as maximally indented so they fold with it.
        if (was) ind[(size_t)i] = 1 << 20;
        else if (!is_blank(lines[(size_t)i])) ind[(size_t)i] = (int)indent_width(lines[(size_t)i], tab);
    }
    std::vector<std::pair<int, int>> ranges;
    // Indentation blocks via a stack of open headers.
    std::vector<std::pair<int, int>> stack;   // (indent, header row)
    int last_code = -1;
    for (int i = 0; i < n; i++) {
        int w = ind[(size_t)i];
        if (w < 0) continue;
        while (!stack.empty() && w <= stack.back().first) {
            auto top = stack.back();
            stack.pop_back();
            if (last_code > top.second) ranges.push_back({top.second, last_code});
        }
        // Is the next non-blank line deeper? Then this line opens a block.
        int j = i + 1;
        while (j < n && ind[(size_t)j] < 0) j++;
        if (j < n && ind[(size_t)j] > w && w < (1 << 20)) stack.push_back({w, i});
        last_code = i;
    }
    while (!stack.empty()) {
        auto top = stack.back();
        stack.pop_back();
        if (last_code > top.second) ranges.push_back({top.second, last_code});
    }
    // #region markers
    std::vector<int> open;
    for (int i = 0; i < n; i++) {
        std::string t = trim(lines[(size_t)i]);
        if (starts_with(t, "# region") || starts_with(t, "#region") || starts_with(t, "// region")) open.push_back(i);
        else if ((starts_with(t, "# endregion") || starts_with(t, "#endregion") || starts_with(t, "// endregion")) && !open.empty()) {
            ranges.push_back({open.back(), i});
            open.pop_back();
        }
    }
    std::sort(ranges.begin(), ranges.end());
    ranges.erase(std::unique(ranges.begin(), ranges.end()), ranges.end());
    for (auto& r : ranges) {
        ListBuilder h(E);
        h.add_int(r.first);
        h.add_int(r.second);
        out.add(h.done());
    }
    return out.done();
}

// ── text_line_stats ──────────────────────────────────────────────────────────
// [total, code, comment, blank, docstring] - a line with both code and a
// trailing comment counts as code (Code::Blocks' "code and comments" goes
// under code here; comment means comment-only).
Value text_line_stats(NythonExecutor& E, std::vector<Value>& args) {
    auto lines = args.empty() ? std::vector<std::string>() : lines_of(E, args[0]);
    long long code = 0, comment = 0, blank = 0, doc = 0;
    char triple = 0;
    std::vector<bool> mask;
    for (auto& ln : lines) {
        bool was = triple != 0;
        bool has_comment = false, has_code = false;
        scan_line(ln, triple, mask, &has_comment, &has_code);
        bool opens_doc = !was && triple != 0;
        if (was || (opens_doc && trim(ln).size() >= 3 && (trim(ln)[0] == '"' || trim(ln)[0] == '\''))) { doc++; continue; }
        if (is_blank(ln)) { blank++; continue; }
        std::string t = trim(ln);
        bool starts_str = !t.empty() && (t[0] == '"' || t[0] == '\'') && t.size() >= 6 && t[1] == t[0] && t[2] == t[0];
        if (starts_str) { doc++; continue; }
        if (!has_code && has_comment) { comment++; continue; }
        code++;
    }
    ListBuilder out(E);
    out.add_int((long long)lines.size());
    out.add_int(code); out.add_int(comment); out.add_int(blank); out.add_int(doc);
    return out.done();
}

// ── TODO scanning ────────────────────────────────────────────────────────────
// A tag counts in a comment only: "# TODO: x", "# FIXME(bob): y", "// NOTE z".
struct Todo { size_t row; long long col; std::string tag, text, owner; };

void todos_in(const std::vector<std::string>& lines, const std::vector<std::string>& tags, std::vector<Todo>& out, size_t max) {
    char triple = 0;
    std::vector<bool> mask;
    for (size_t row = 0; row < lines.size() && out.size() < max; row++) {
        const std::string& ln = lines[row];
        bool was = triple != 0;
        scan_line(ln, triple, mask);
        if (was) continue;
        // Comment start: first '#' or '//' that is code (not in a string).
        size_t cstart = std::string::npos;
        {
            char t2 = 0;
            size_t i = 0;
            while (i < ln.size()) {
                char c = ln[i];
                if (t2) { if (c == '\\') i++; else if (c == t2) t2 = 0; i++; continue; }
                if (c == '"' || c == '\'') { t2 = c; i++; continue; }
                if (c == '#') { cstart = i + 1; break; }
                if (c == '/' && i + 1 < ln.size() && ln[i + 1] == '/') { cstart = i + 2; break; }
                i++;
            }
        }
        if (cstart == std::string::npos) continue;
        for (auto& tag : tags) {
            size_t at = ln.find(tag, cstart);
            if (at == std::string::npos) continue;
            if (at > 0 && id_char((unsigned char)ln[at - 1])) continue;
            size_t e = at + tag.size();
            if (e < ln.size() && id_char((unsigned char)ln[e])) continue;
            std::string owner;
            if (e < ln.size() && ln[e] == '(') {
                size_t close = ln.find(')', e);
                if (close != std::string::npos) { owner = ln.substr(e + 1, close - e - 1); e = close + 1; }
            }
            while (e < ln.size() && (ln[e] == ':' || ln[e] == ' ' || ln[e] == '-')) e++;
            out.push_back({row, char_col(ln, at), tag, trim(ln.substr(e)), owner});
            break;
        }
    }
}

std::vector<std::string> todo_tags(NythonExecutor& E, std::vector<Value>& args, size_t i) {
    std::vector<std::string> tags;
    if (args.size() > i && as_container(args[i])) tags = strings_of(E, args[i]);
    if (tags.empty()) tags = {"TODO", "FIXME", "BUG", "HACK", "XXX", "NOTE", "OPTIMIZE", "REVIEW"};
    return tags;
}

Value text_todos(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    auto lines = lines_of(E, args[0]);
    auto tags = todo_tags(E, args, 1);
    std::vector<Todo> found;
    todos_in(lines, tags, found, 100000);
    for (auto& t : found) {
        ListBuilder h(E);
        h.add_int((long long)t.row); h.add_int(t.col); h.add_str(t.tag); h.add_str(t.text); h.add_str(t.owner);
        out.add(h.done());
    }
    return out.done();
}

Value fs_todos(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    std::string root = E.getStringValue(args[0]);
    while (root.size() > 1 && (root.back() == '/' || root.back() == '\\')) root.pop_back();
    auto tags = todo_tags(E, args, 1);
    size_t max = (size_t)std::max(1LL, int_arg(args, 2, 5000));
    std::vector<std::string> files;
    std::unordered_set<std::string> skip;
    for (int i = 0; kDefaultSkip[i]; i++) skip.insert(kDefaultSkip[i]);
    walk(root, "", skip, 20000, files, 0);
    std::string text;
    size_t total = 0;
    for (auto& rel : files) {
        if (total >= max) break;
        if (!read_small(root + "/" + rel, 2 * 1024 * 1024, text)) continue;
        std::vector<std::string> lines;
        split_lines(text, lines);
        std::vector<Todo> found;
        todos_in(lines, tags, found, max - total);
        for (auto& t : found) {
            ListBuilder h(E);
            h.add_str(rel); h.add_int((long long)t.row); h.add_int(t.col); h.add_str(t.tag); h.add_str(t.text); h.add_str(t.owner);
            out.add(h.done());
            total++;
        }
    }
    return out.done();
}

// ── text_format_nython ───────────────────────────────────────────────────────
// A conservative formatter: it never reorders or joins tokens, so it cannot
// change what a program means. Per line: indentation re-expressed in the
// document's unit (tabs or N spaces) by nesting level, trailing whitespace
// removed, one space after commas and around the common binary and
// assignment operators - outside strings and comments only. Across lines:
// runs of blank lines capped (2 at top level, 1 inside blocks). Lines inside
// triple-quoted strings are left exactly as they are.
//   text_format_nython(source, unit="    ", opts={spaces: true})
std::string space_ops(const std::string& code_in) {
    // Tokenize enough to find operators outside strings.
    const std::string& s = code_in;
    std::string out;
    size_t i = 0;
    auto prev_sig = [&]() -> char {
        for (size_t k = out.size(); k > 0; k--) if (out[k - 1] != ' ') return out[k - 1];
        return 0;
    };
    static const char* ops3[] = {"**=", "//=", ">>=", "<<=", "===", "!==", nullptr};
    static const char* ops2[] = {"==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "->", ":=", nullptr};
    while (i < s.size()) {
        char c = s[i];
        if (c == '"' || c == '\'') {
            size_t j = i + 1;
            while (j < s.size() && s[j] != c) { if (s[j] == '\\') j++; j++; }
            out += s.substr(i, std::min(j + 1, s.size()) - i);
            i = j + 1;
            continue;
        }
        if (c == '#') { out += s.substr(i); break; }
        if (c == ',') {
            while (!out.empty() && out.back() == ' ') out.pop_back();
            out += ',';
            i++;
            if (i < s.size() && s[i] != ' ' && s[i] != ')' && s[i] != ']' && s[i] != '}') out += ' ';
            continue;
        }
        const char* hit = nullptr;
        for (int k = 0; ops3[k] && !hit; k++) if (s.compare(i, 3, ops3[k]) == 0) hit = ops3[k];
        for (int k = 0; ops2[k] && !hit; k++) if (s.compare(i, 2, ops2[k]) == 0) hit = ops2[k];
        if (!hit && (c == '=' || c == '<' || c == '>')) {
            static const char one[2][2] = {{0, 0}, {0, 0}};
            (void)one;
            hit = c == '=' ? "=" : c == '<' ? "<" : ">";
        }
        if (hit) {
            size_t len = strlen(hit);
            // Keyword arguments and defaults inside brackets keep `name=value`.
            int depth = 0;
            for (char ch : out) { if (ch == '(' || ch == '[' || ch == '{') depth++; else if (ch == ')' || ch == ']' || ch == '}') depth--; }
            bool tight = (len == 1 && hit[0] == '=' && depth > 0);
            // `<`/`>` used as brackets (generics) or in `->` are left alone.
            char p = prev_sig();
            if (tight) {
                // Keyword arguments and defaults: `name=value`, as PEP 8 has it.
                while (!out.empty() && out.back() == ' ') out.pop_back();
                out += '=';
                i += len;
                while (i < s.size() && s[i] == ' ') i++;
                continue;
            }
            if (p == 0 || p == '(' || p == '[' || p == ',') {
                out += s.substr(i, len);
                i += len;
                continue;
            }
            while (!out.empty() && out.back() == ' ') out.pop_back();
            out += ' ';
            out += hit;
            i += len;
            while (i < s.size() && s[i] == ' ') i++;
            if (i < s.size()) out += ' ';
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

Value text_format_nython(NythonExecutor& E, std::vector<Value>& args) {
    if (args.empty()) return NONE_VALUE;
    auto lines = lines_of(E, args[0]);
    std::string unit = args.size() > 1 ? E.getStringValue(args[1]) : std::string("    ");
    if (unit.empty()) unit = "    ";
    Value o = args.size() > 2 ? args[2] : UNDEFINED_VALUE;
    bool spaces = opt_bool(E, o, "spaces", true);
    int tab = unit == "\t" ? 4 : (int)unit.size();
    std::vector<std::string> out;
    std::vector<size_t> widths;       // stack of source indent widths
    char triple = 0;
    std::vector<bool> mask;
    int blank_run = 0;
    for (auto& raw : lines) {
        bool was = triple != 0;
        scan_line(raw, triple, mask);
        if (was) { out.push_back(raw); blank_run = 0; continue; }
        std::string r = raw;
        while (!r.empty() && (r.back() == ' ' || r.back() == '\t' || r.back() == '\r')) r.pop_back();
        if (r.empty()) {
            blank_run++;
            int cap = widths.empty() || widths.back() == 0 ? 2 : 1;
            if (blank_run <= cap) out.push_back(std::string());
            continue;
        }
        blank_run = 0;
        size_t w = indent_width(r, tab);
        // Nesting level from the stack of distinct indentation widths.
        while (!widths.empty() && widths.back() > w) widths.pop_back();
        if (widths.empty() || widths.back() < w) widths.push_back(w);
        size_t level = widths.size() - 1;
        if (!widths.empty() && widths.front() > 0) level = widths.size();
        std::string body = lstrip(r);
        if (spaces && !(triple && !was)) body = space_ops(body);
        std::string ind;
        for (size_t k = 0; k < level; k++) ind += unit;
        out.push_back(ind + body);
    }
    // No trailing blank lines beyond the final newline's empty line.
    while (out.size() > 1 && out.back().empty() && out[out.size() - 2].empty()) out.pop_back();
    std::string joined;
    for (size_t i = 0; i < out.size(); i++) {
        if (i) joined += '\n';
        joined += out[i];
    }
    return E.makeStringValue(joined);
}

// ── completion index ─────────────────────────────────────────────────────────
// A per-document completion index that lives in C++. The IDE used to rebuild
// its candidate list (symbols, every identifier in the file, keywords,
// builtins) in Nython whenever a completion session started, and to allocate
// a fresh result list per keystroke - memory the interpreter never gives
// back. Here the candidates are kept natively; a rescan happens only when the
// document changed, and ranking returns cached string Values, so a keystroke
// allocates one result list and nothing else.
//   ac_index_new() -> handle
//   ac_index_set_base(h, names, kinds)      fixed candidates (keywords, builtins)
//   ac_index_scan(h, lines, min_len=3)      this document's symbols and words -> [n_symbols, n_words]
//   ac_index_rank(h, query, limit=60, exclude="") -> [names, kinds], best first
// Scores: nyfuzzy (best alignment) * 10 + a kind bonus (definitions 5,
// keywords 3), stable, so the document's own definitions win ties.
struct AcItem { std::string name, kind; int bonus; };
struct AcIndex {
    std::vector<AcItem> base{}, symbols{}, words{}, merged{};
    std::unordered_map<std::string, Value> vals{};   // cached string Values
    void merge() {
        merged.clear();
        std::unordered_set<std::string> seen;
        for (auto* g : {&symbols, &base, &words})
            for (auto& it : *g)
                if (seen.insert(it.name).second) merged.push_back(it);
    }
};
std::mutex g_ac_mu;
std::map<long long, AcIndex> g_ac;
long long g_ac_next = 1;

int kind_bonus(const std::string& k) {
    if (k == "keyword") return 3;
    if (k == "builtin" || k == "text") return 0;
    return 5;   // class, function, method, field, variable, constant, ...
}

Value ac_val(NythonExecutor& E, AcIndex& ix, const std::string& s) {
    auto it = ix.vals.find(s);
    if (it != ix.vals.end()) return it->second;
    Value v = E.makeStringValue(s);
    ix.vals.emplace(s, v);
    return v;
}

Value ac_index_new(NythonExecutor&, std::vector<Value>&) {
    std::lock_guard<std::mutex> lk(g_ac_mu);
    long long h = g_ac_next++;
    g_ac[h];
    return Value(bigint(h));
}

AcIndex* ac_get(const std::vector<Value>& args) {
    long long h = int_arg(args, 0, 0);
    auto it = g_ac.find(h);
    return it == g_ac.end() ? nullptr : &it->second;
}

Value ac_index_set_base(NythonExecutor& E, std::vector<Value>& args) {
    std::lock_guard<std::mutex> lk(g_ac_mu);
    AcIndex* ix = ac_get(args);
    if (!ix || args.size() < 3) return Value(0);
    auto names = strings_of(E, args[1]);
    auto kinds = strings_of(E, args[2]);
    ix->base.clear();
    for (size_t i = 0; i < names.size(); i++) {
        std::string k = i < kinds.size() ? kinds[i] : std::string("keyword");
        ix->base.push_back({names[i], k, kind_bonus(k)});
    }
    ix->merge();
    return Value((int)ix->base.size());
}

Value ac_index_scan(NythonExecutor& E, std::vector<Value>& args) {
    std::vector<std::string> lines = args.size() > 1 ? lines_of(E, args[1]) : std::vector<std::string>();
    size_t min_len = (size_t)std::max(1LL, int_arg(args, 2, 3));
    std::lock_guard<std::mutex> lk(g_ac_mu);
    AcIndex* ix = ac_get(args);
    ListBuilder out(E);
    if (!ix) return out.done();
    ix->symbols.clear();
    for (auto& sm : scan_symbols(lines)) ix->symbols.push_back({sm.name, sm.kind, kind_bonus(sm.kind)});
    ix->words.clear();
    std::unordered_set<std::string> seen;
    for (auto& ln : lines) {
        size_t i = 0;
        while (i < ln.size()) {
            unsigned char c = (unsigned char)ln[i];
            if (id_start(c) && !(i > 0 && id_char((unsigned char)ln[i - 1]))) {
                size_t j = i;
                while (j < ln.size() && id_char((unsigned char)ln[j])) j++;
                if (j - i >= min_len) {
                    std::string w = ln.substr(i, j - i);
                    if (seen.insert(w).second) ix->words.push_back({w, "text", 0});
                }
                i = j;
            } else i++;
        }
        if (ix->words.size() > 50000) break;
    }
    ix->merge();
    out.add_int((long long)ix->symbols.size());
    out.add_int((long long)ix->words.size());
    return out.done();
}

Value ac_index_rank(NythonExecutor& E, std::vector<Value>& args) {
    std::string q = args.size() > 1 ? E.getStringValue(args[1]) : std::string();
    size_t limit = (size_t)std::max(1LL, int_arg(args, 2, 60));
    std::string exclude = args.size() > 3 ? E.getStringValue(args[3]) : std::string();
    std::lock_guard<std::mutex> lk(g_ac_mu);
    AcIndex* ix = ac_get(args);
    ListBuilder names(E), kinds(E), out(E);
    if (!ix) { out.add(names.done()); out.add(kinds.done()); return out.done(); }
    auto tq = nyfuzzy::codepoints(q);
    if (tq.size() > 64) tq.resize(64);
    std::vector<std::pair<long long, size_t>> hits;
    for (size_t i = 0; i < ix->merged.size(); i++) {
        const AcItem& it = ix->merged[i];
        if (!exclude.empty() && it.name == exclude) continue;
        int sc = 0;
        if (!tq.empty()) {
            auto tt = nyfuzzy::codepoints(it.name);
            if (tt.size() > 256) tt.resize(256);
            if (!nyfuzzy::score(tq, tt, sc)) continue;
        }
        hits.push_back({(long long)sc * 10 + it.bonus, i});
    }
    std::stable_sort(hits.begin(), hits.end(), [](auto& a, auto& b) { return a.first > b.first; });
    for (size_t k = 0; k < hits.size() && k < limit; k++) {
        const AcItem& it = ix->merged[hits[k].second];
        names.add(ac_val(E, *ix, it.name));
        kinds.add(ac_val(E, *ix, it.kind));
    }
    out.add(names.done());
    out.add(kinds.done());
    return out.done();
}

}  // namespace

Value dispatch_text(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* /*ctx*/) {
    if (name.size() < 5) return UNDEFINED_VALUE;
    switch (name[0]) {
        case 't':
            if (name == "text_words") return text_words(E, args);
            if (name == "text_diff") return text_diff(E, args);
            if (name == "text_diff_classify") return text_diff_classify(E, args);
            if (name == "text_fold_ranges") return text_fold_ranges(E, args);
            if (name == "text_line_stats") return text_line_stats(E, args);
            if (name == "text_todos") return text_todos(E, args);
            if (name == "text_format_nython") return text_format_nython(E, args);
            break;
        case 'a':
            if (name == "ac_index_new") return ac_index_new(E, args);
            if (name == "ac_index_set_base") return ac_index_set_base(E, args);
            if (name == "ac_index_scan") return ac_index_scan(E, args);
            if (name == "ac_index_rank") return ac_index_rank(E, args);
            break;
        case 'n':
            if (name == "ny_symbols") return ny_symbols(E, args);
            if (name == "ny_check_syntax") return ny_check_syntax(E, args);
            break;
        case 'f':
            if (name == "fs_list_files") return fs_list_files(E, args);
            if (name == "fs_search") return fs_search(E, args);
            if (name == "fs_todos") return fs_todos(E, args);
            if (name == "fs_symbols") return fs_symbols(E, args);
            break;
    }
    return UNDEFINED_VALUE;
}
