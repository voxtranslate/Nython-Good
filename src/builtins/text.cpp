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
//   text_defuse(source)                               per line: reads, writes, controlling predicates (round 79)
//   ny_facts(source)                                  per function: parameters, calls, returns, raises, ... (round 82)
//   _ny_ast(source, mode, filename)                   Python's tree from the real parser (lib/ast.ny, round 83)
//
// Lists arrive either as a Nython list of strings or as one string (split on
// newlines). All rows/columns are 0-based; columns count characters.

#include "platform_compat.hpp"

#include <algorithm>
#include <array>
#include <tuple>
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
#ifndef _WIN32
#include <dirent.h>     // Windows: platform_compat.hpp's emulation
#endif

#include "NythonExecutor.hpp"
#include "NyFuzzy.hpp"
#include "builtins/text.hpp"
#include "builtins/nylsp.hpp"   // round 86: lib/nylsp's natives

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
    try {
        auto source = SourceCode::from_text(src, "stdin");
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

// ny_check_file(path) -> the same as ny_check_syntax on the file's text,
// read here (a build checks every file of a project; reading them in the
// interpreter would keep every file's text for the rest of the session).
Value ny_check_file(NythonExecutor& E, std::vector<Value>& args) {
    if (args.empty()) return ListBuilder(E).done();
    std::string path = E.getStringValue(args[0]);
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        ListBuilder out(E), d(E);
        d.add_int(0); d.add_int(0); d.add_str("cannot read " + path);
        out.add(d.done());
        return out.done();
    }
    std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    std::vector<Value> a{E.makeStringValue(text.empty() ? std::string("\n") : text)};
    return ny_check_syntax(E, a);
}

// ── text_defuse (round 79) ───────────────────────────────────────────────────
// Per line of a program, from the real parser's AST: what the statement(s)
// starting there read and write, and the predicates that decide whether it
// runs - the static half of a dynamic slice (lib/ide_debugger.ny's Whyline
// questions; lib/trace.ny's executable lines).
//
//   text_defuse(source) -> a list with one entry per line: none, or
//     {"stmt": true when a statement starts there, "kind": its kind ("assign",
//      "if", "elif", "for", "while", "def", "class", "return", "expr", ...),
//      "reads": [names], "writes": [names],
//      "ctrl": [line, ...]  the predicates it is control dependent on,
//                           innermost first (Ferrante, Ottenstein & Warren's
//                           PDG: an if / elif test, a loop header, an except
//                           clause, a match case),
//      "branch": [how, ...] for each: "then", "else", "body" (a loop's),
//                           "loop-else", "except", "case",
//      "func": the enclosing def's name ("" at module level),
//      "func_line": its line (0), "doc": true for a docstring line,
//      "error": the syntax error when the source does not parse (entry 0)}
//
// Names: a write is a name bound (assignment, for / with / except targets,
// def, class, import, del, a walrus); assigning to x.attr or x[i], an
// augmented assignment to one, or calling a mutating method of a name
// (append, extend, insert, pop, remove, clear, update, add, discard,
// setdefault, sort, reverse, popitem) writes x - the container is the
// variable the recording sees. Names bound inside a comprehension or a
// lambda are not reads of the statement; a nested def's body is its own.
// The parser's own temporaries (__unpack0__ ...) are left out.
struct DefUse {
    bool stmt = false, doc = false;
    std::string kind, func;
    int func_line = 0;
    std::set<std::string> reads, writes;
    std::vector<std::pair<int, std::string>> ctrl;
};

bool defuse_temp(const std::string& n) {
    if (n.empty() || (unsigned char)n[0] < 0x20) return true;
    if (n.rfind("_ny", 0) == 0) return true;
    if (n.size() > 4 && n.compare(0, 2, "__") == 0 && n.compare(n.size() - 2, 2, "__") == 0) {
        for (size_t i = 2; i + 2 < n.size(); i++) if (n[i] >= '0' && n[i] <= '9') return true;
    }
    for (char c : n) if (!(c == '_' || c == '.' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || (unsigned char)c >= 0x80)) return true;
    return false;
}

struct DefUseWalker {
    std::map<int, DefUse> lines;
    std::vector<std::pair<int, std::string>> ctrl;   // innermost last
    std::string func;
    int func_line = 0;

    DefUse& at(int line) {
        DefUse& d = lines[line];
        if (d.ctrl.empty() && !ctrl.empty()) d.ctrl.assign(ctrl.rbegin(), ctrl.rend());
        if (d.func.empty()) { d.func = func; d.func_line = func_line; }
        return d;
    }
    static void add(std::set<std::string>& s, const std::string& n) { if (!defuse_temp(n)) s.insert(n); }
    static std::string base_name(const node_ptr& n) {
        node_ptr x = n;
        for (int g = 0; x && g < 64; g++) {
            if (x->type() == NodeType::VARIABLE) return x->value();
            if (x->type() == NodeType::SELF) return "self";
            if (x->type() == NodeType::ATTRIBUTE) x = std::static_pointer_cast<AttributeNode>(x)->object;
            else if (x->type() == NodeType::SUBSCRIPT) x = std::static_pointer_cast<SubscriptNode>(x)->object;
            else return std::string();
        }
        return std::string();
    }
    // the reads of an expression; `bound`: names bound inside it (a
    // comprehension's targets, a lambda's parameters) are not reads
    void reads(const node_ptr& n, DefUse& d, std::set<std::string>& bound, int depth = 0) {
        if (!n || depth > 200) return;
        auto R = [&](const node_ptr& c) { reads(c, d, bound, depth + 1); };
        switch (n->type()) {
            case NodeType::VARIABLE: {
                std::string v = n->value();
                if (!bound.count(v)) add(d.reads, v);
                return;
            }
            case NodeType::SELF: if (!bound.count("self")) add(d.reads, "self"); return;
            case NodeType::STRING: {
                // "${name}" interpolation
                const std::string& raw = n->token().value;
                size_t p = 0;
                while ((p = raw.find("${", p)) != std::string::npos) {
                    size_t e = raw.find('}', p + 2);
                    if (e == std::string::npos) break;
                    std::string nm = raw.substr(p + 2, e - p - 2);
                    if (!bound.count(nm)) add(d.reads, nm);
                    p = e + 1;
                }
                return;
            }
            case NodeType::ATTRIBUTE: R(std::static_pointer_cast<AttributeNode>(n)->object); return;
            case NodeType::SUBSCRIPT: { auto s = std::static_pointer_cast<SubscriptNode>(n); R(s->object); R(s->index); return; }
            case NodeType::UNARY: R(std::static_pointer_cast<UnaryNode>(n)->operand); return;
            case NodeType::BINARY: { auto b = std::static_pointer_cast<BinaryNode>(n); R(b->left); R(b->right); return; }
            case NodeType::CALL: {
                auto c = std::static_pointer_cast<CallNode>(n);
                R(c->callee);
                for (auto& a : c->args) R(a);
                // a mutating method of a variable writes it
                if (c->callee && c->callee->type() == NodeType::ATTRIBUTE) {
                    static const std::set<std::string> mut = {"append", "extend", "insert", "pop", "remove", "clear",
                        "update", "add", "discard", "setdefault", "sort", "reverse", "popitem", "appendleft", "extendleft", "popleft"};
                    auto an = std::static_pointer_cast<AttributeNode>(c->callee);
                    if (mut.count(an->attr)) { std::string b = base_name(an->object); if (!b.empty() && !bound.count(b)) add(d.writes, b); }
                }
                return;
            }
            case NodeType::KEYWORD_ARG: R(std::static_pointer_cast<KeywordArgNode>(n)->val); return;
            case NodeType::MAP_ENTRY: { auto e = std::static_pointer_cast<MapEntryNode>(n); R(e->key); R(e->val); return; }
            case NodeType::SLICE: { auto s = std::static_pointer_cast<SliceNode>(n); R(s->start); R(s->end_node); R(s->step); return; }
            case NodeType::RANGE: { auto s = std::static_pointer_cast<RangeNode>(n); R(s->start); R(s->end_node); R(s->step); return; }
            case NodeType::WALRUS: { auto w = std::static_pointer_cast<WalrusNode>(n); R(w->init); add(d.writes, w->name); return; }
            case NodeType::IF: {
                auto i = std::static_pointer_cast<IfNode>(n);
                R(i->condition); R(i->then_branch); R(i->else_branch);
                for (auto& e : i->elseif_branches) R(e);
                return;
            }
            case NodeType::YIELD: R(std::static_pointer_cast<YieldNode>(n)->expr); return;
            case NodeType::YIELD_FROM: R(std::static_pointer_cast<YieldFromNode>(n)->expr); return;
            case NodeType::LAMBDA: {
                auto l = std::static_pointer_cast<LambdaNode>(n);
                for (auto& dv : l->defaults) R(dv);
                std::set<std::string> b2 = bound;
                for (auto& p : l->params) { std::string pn = p->value(); while (!pn.empty() && pn[0] == '*') pn.erase(0, 1); b2.insert(pn); }
                reads(l->body, d, b2, depth + 1);
                return;
            }
            case NodeType::COMPREHENSION: {
                auto c = std::static_pointer_cast<ComprehensionNode>(n);
                std::set<std::string> b2 = bound;
                for (auto& cl : c->clauses) {
                    reads(cl.iter, d, b2, depth + 1);
                    std::vector<std::string> ts;
                    target_names(cl.target, ts);
                    for (auto& t : ts) b2.insert(t);
                    for (auto& cd : cl.conds) reads(cd, d, b2, depth + 1);
                }
                reads(c->elt, d, b2, depth + 1);
                reads(c->value, d, b2, depth + 1);
                return;
            }
            case NodeType::OPT_CHAIN: {
                auto o = std::static_pointer_cast<OptChainNode>(n);
                R(o->recv); R(o->index); R(o->call); R(o->rest);
                return;
            }
            case NodeType::FUNCTION: case NodeType::CLASS: return;   // their own statements
            default: break;
        }
        for (auto& c : n->statements()) R(c);
    }
    static void target_names(const node_ptr& t, std::vector<std::string>& out) {
        if (!t) return;
        if (t->type() == NodeType::TUPLE || t->type() == NodeType::LIST) { for (auto& e : t->statements()) target_names(e, out); return; }
        if (t->type() == NodeType::UNARY) { target_names(std::static_pointer_cast<UnaryNode>(t)->operand, out); return; }
        if (t->type() == NodeType::VARIABLE) out.push_back(t->value());
    }
    // an assignment target: its name written, or its container's (and what
    // the target expression reads)
    void target(const node_ptr& t, DefUse& d) {
        if (!t) return;
        std::set<std::string> none;
        switch (t->type()) {
            case NodeType::VARIABLE: add(d.writes, t->value()); return;
            case NodeType::TUPLE: case NodeType::LIST: for (auto& e : t->statements()) target(e, d); return;
            case NodeType::UNARY: target(std::static_pointer_cast<UnaryNode>(t)->operand, d); return;
            case NodeType::ATTRIBUTE: case NodeType::SUBSCRIPT: {
                std::string b = base_name(t);
                if (!b.empty()) { add(d.writes, b); add(d.reads, b); }
                if (t->type() == NodeType::SUBSCRIPT) reads(std::static_pointer_cast<SubscriptNode>(t)->index, d, none);
                else reads(std::static_pointer_cast<AttributeNode>(t)->object, d, none);
                return;
            }
            default: reads(t, d, none); return;
        }
    }
    void block(const node_ptr& b) {
        if (!b) return;
        NodeType t = b->type();
        if (t == NodeType::BLOCK || t == NodeType::STATEMENTS || t == NodeType::SCRIPT) {
            bool first = true;
            for (auto& s : b->statements()) {
                // a docstring: a string statement first in a body
                if (first && s && s->type() == NodeType::STRING) { DefUse& d = at(s->line()); d.doc = true; first = false; continue; }
                first = false;
                stmt(s);
            }
            return;
        }
        stmt(b);
    }
    void stmt(const node_ptr& s) {
        if (!s) return;
        int line = s->line();
        std::set<std::string> none;
        auto mark = [&](const char* kind) -> DefUse& {
            DefUse& d = at(line);
            d.stmt = true;
            if (d.kind.empty()) d.kind = kind;
            return d;
        };
        switch (s->type()) {
            case NodeType::BLOCK: case NodeType::STATEMENTS: block(s); return;
            case NodeType::ASSIGNMENT: {
                auto a = std::static_pointer_cast<AssignmentNode>(s);
                DefUse& d = mark("assign");
                reads(a->value_node, d, none);
                target(a->target, d);
                return;
            }
            case NodeType::ASSIGNMENT_AUG: {
                auto a = std::static_pointer_cast<AugAssignNode>(s);
                DefUse& d = mark("augassign");
                reads(a->value_node, d, none);
                reads(a->target, d, none);
                target(a->target, d);
                return;
            }
            case NodeType::VARIABLE_DECL: {
                auto v = std::static_pointer_cast<VarDeclNode>(s);
                DefUse& d = mark("assign");
                reads(v->init, d, none);
                add(d.writes, v->name);
                return;
            }
            case NodeType::IF: {
                auto i = std::static_pointer_cast<IfNode>(s);
                if (i->is_expr) break;
                DefUse& d = mark("if");
                reads(i->condition, d, none);
                ctrl.push_back({line, "then"});
                block(i->then_branch);
                ctrl.pop_back();
                // each elif test runs when the tests before it were false
                size_t pushed = 0;
                ctrl.push_back({line, "else"}); pushed++;
                for (auto& e : i->elseif_branches) {
                    auto ei = std::static_pointer_cast<IfNode>(e);
                    int el = ei->line();
                    DefUse& ed = at(el);
                    ed.stmt = true;
                    if (ed.kind.empty()) ed.kind = "elif";
                    reads(ei->condition, ed, none);
                    ctrl.push_back({el, "then"});
                    block(ei->then_branch);
                    ctrl.pop_back();
                    ctrl.push_back({el, "else"}); pushed++;
                }
                block(i->else_branch);
                while (pushed--) ctrl.pop_back();
                return;
            }
            case NodeType::WHILE: {
                auto w = std::static_pointer_cast<WhileNode>(s);
                DefUse& d = mark("while");
                reads(w->condition, d, none);
                ctrl.push_back({line, "body"});
                block(w->body);
                ctrl.pop_back();
                ctrl.push_back({line, "loop-else"});
                block(w->else_branch);
                ctrl.pop_back();
                return;
            }
            case NodeType::FOR: {
                auto f = std::static_pointer_cast<ForNode>(s);
                DefUse& d = mark("for");
                reads(f->iterable, d, none);
                target(f->var, d);
                for (auto& u : f->unpack_vars) target(u, d);
                ctrl.push_back({line, "body"});
                block(f->body);
                ctrl.pop_back();
                ctrl.push_back({line, "loop-else"});
                block(f->else_branch);
                ctrl.pop_back();
                return;
            }
            case NodeType::TRY: {
                auto t = std::static_pointer_cast<TryNode>(s);
                mark("try");
                block(t->body);
                for (auto& ec : t->except_clauses) {
                    auto en = std::static_pointer_cast<ExceptNode>(ec);
                    int el = en->line();
                    DefUse& ed = at(el);
                    ed.stmt = true;
                    if (ed.kind.empty()) ed.kind = "except";
                    for (auto& ty : en->types) add(ed.reads, ty);
                    if (!en->var.empty()) add(ed.writes, en->var);
                    ctrl.push_back({el, "except"});
                    block(en->body);
                    ctrl.pop_back();
                }
                block(t->else_clause);
                block(t->finally_clause);
                return;
            }
            case NodeType::WITH: {
                auto w = std::static_pointer_cast<WithNode>(s);
                DefUse& d = mark("with");
                reads(w->expr, d, none);
                if (!w->alias.empty()) add(d.writes, w->alias);
                block(w->body);
                return;
            }
            case NodeType::SWITCH: {
                auto sw = std::static_pointer_cast<SwitchNode>(s);
                DefUse& d = mark("match");
                reads(sw->subject, d, none);
                for (auto& c : sw->cases) {
                    auto cn = std::static_pointer_cast<CaseNode>(c);
                    int cl = cn->line();
                    DefUse& cd = at(cl);
                    cd.stmt = true;
                    if (cd.kind.empty()) cd.kind = "case";
                    reads(cn->value_node, cd, none);
                    ctrl.push_back({cl, "case"});
                    block(cn->body);
                    ctrl.pop_back();
                }
                if (sw->default_case) {
                    ctrl.push_back({line, "case"});
                    auto dn = std::dynamic_pointer_cast<DefaultNode>(sw->default_case);
                    block(dn ? dn->body : sw->default_case);
                    ctrl.pop_back();
                }
                return;
            }
            case NodeType::FUNCTION: {
                auto f = std::static_pointer_cast<FunctionNode>(s);
                DefUse& d = mark("def");
                for (auto& dv : f->defaults) reads(dv, d, none);
                add(d.writes, f->name);
                // its body: a scope of its own, no predicate around it
                auto saved_ctrl = std::move(ctrl);
                ctrl.clear();
                std::string sf = func; int sl = func_line;
                func = f->name; func_line = line;
                block(f->body);
                func = sf; func_line = sl;
                ctrl = std::move(saved_ctrl);
                return;
            }
            case NodeType::CLASS: {
                auto c = std::static_pointer_cast<ClassNode>(s);
                DefUse& d = mark("class");
                for (auto& b : c->bases) reads(b, d, none);
                add(d.writes, c->bind_name.empty() ? c->name : c->bind_name);
                block(c->body);
                return;
            }
            case NodeType::RETURN: { DefUse& d = mark("return"); reads(std::static_pointer_cast<ReturnNode>(s)->expr, d, none); return; }
            case NodeType::RAISE: {
                auto r = std::static_pointer_cast<RaiseNode>(s);
                DefUse& d = mark("raise");
                reads(r->expr, d, none); reads(r->cause, d, none);
                return;
            }
            case NodeType::ASSERT: {
                auto a = std::static_pointer_cast<AssertNode>(s);
                DefUse& d = mark("assert");
                reads(a->condition, d, none); reads(a->message, d, none);
                return;
            }
            case NodeType::IMPORT: {
                auto im = std::static_pointer_cast<ImportNode>(s);
                DefUse& d = mark("import");
                // `from m import a as b` binds b: the parser joins the name
                // and its alias with \x05 (round 82: such an import wrote
                // nothing here)
                if (!im->names.empty()) for (auto& n : im->names) {
                    std::string nm = n;
                    size_t x5 = nm.find('\x05');
                    size_t sp = nm.find(" as ");
                    if (x5 != std::string::npos) nm = nm.substr(x5 + 1);
                    else if (sp != std::string::npos) nm = nm.substr(sp + 4);
                    add(d.writes, nm);
                }
                else if (!im->alias.empty()) add(d.writes, im->alias);
                else { std::string m = im->module_name; size_t dot = m.find('.'); add(d.writes, dot == std::string::npos ? m : m.substr(0, dot)); }
                return;
            }
            case NodeType::DELETE: {
                auto dl = std::static_pointer_cast<DeleteNode>(s);
                DefUse& d = mark("del");
                target(dl->target, d);
                return;
            }
            case NodeType::GLOBAL: mark("global"); return;
            case NodeType::PASS: mark("pass"); return;
            case NodeType::BREAK: mark("break"); return;
            case NodeType::CONTINUE: mark("continue"); return;
            case NodeType::PRINT: {
                auto p = std::static_pointer_cast<PrintNode>(s);
                DefUse& d = mark("expr");
                for (auto& a : p->args) reads(a, d, none);
                reads(p->sep, d, none); reads(p->end, d, none);
                return;
            }
            default: break;
        }
        DefUse& d = mark("expr");
        reads(s, d, none);
    }
};

Value text_defuse(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    std::string src;
    if (as_container(args[0])) {
        auto ls = lines_of(E, args[0]);
        for (size_t i = 0; i < ls.size(); i++) { if (i) src += '\n'; src += ls[i]; }
    } else src = E.getStringValue(args[0]);
    std::vector<std::string> src_lines;
    split_lines(src, src_lines);
    DefUseWalker W;
    std::string error;
    try {
        auto source = SourceCode::from_text(src, "stdin");
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer = std::make_shared<Lexer>(source);
        auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)E.runner, lexer.get());
        lexer->tokenize();
        node_ptr ast = parser->parse();
        W.block(ast);
    } catch (nython::exception::Error& e) { error = e.message(); }
    catch (std::exception& e) { error = e.what(); }
    catch (std::string& s) { error = s; }
    catch (...) { error = "could not be parsed"; }
    auto strs = [&](const std::set<std::string>& s) {
        ListBuilder l(E);
        for (auto& x : s) l.add_str(x);
        return l.done();
    };
    for (size_t i = 0; i < src_lines.size(); i++) {
        int line = (int)i + 1;
        auto it = W.lines.find(line);
        if (it == W.lines.end() && !(i == 0 && !error.empty())) { out.add(NONE_VALUE); continue; }
        auto* m = new Object((Runnable*)E.runner, "map", Type::MAP);
        Value mv((Collectable*)m);
        if (it != W.lines.end()) {
            const DefUse& d = it->second;
            (*m->container)["stmt"] = Value(d.stmt);
            (*m->container)["doc"] = Value(d.doc);
            (*m->container)["kind"] = E.makeStringValue(d.kind);
            (*m->container)["reads"] = strs(d.reads);
            (*m->container)["writes"] = strs(d.writes);
            ListBuilder cl(E), br(E);
            for (auto& c : d.ctrl) { cl.add_int(c.first); br.add_str(c.second); }
            (*m->container)["ctrl"] = cl.done();
            (*m->container)["branch"] = br.done();
            (*m->container)["func"] = E.makeStringValue(d.func);
            (*m->container)["func_line"] = Value(bigint((long long)d.func_line));
        }
        if (i == 0 && !error.empty()) (*m->container)["error"] = E.makeStringValue(error);
        out.add(mv);
    }
    return out.done();
}

// ── ny_facts (round 82) ──────────────────────────────────────────────────────
// What a program-understanding tool needs about each function, from the real
// parser's AST (lib/nyxai/facts.ny builds the agent's program model on it:
// explanations, the call and import graphs, docstrings, generated tests and
// the review rules).
//
//   ny_facts(source) -> {
//     "error": none or [line, message] when the source does not parse,
//     "doc": the module docstring or none,
//     "functions": [{ "name", "qualname", "class" (enclosing class or ""),
//         "parent" (enclosing def's qualname or ""), "line" (the def), "first"
//         (its first decorator's line), "end", "decorators": [source text],
//         "is_async", "is_generator", "doc", "doc_line",
//         "params": [{"name", "kind" (inspect's: positional_only,
//             positional_or_keyword, var_positional, keyword_only,
//             var_keyword), "default" (source text or none), "default_kind"
//             ("literal", "list", "dict", "set", "call:<callee>", "name",
//             "expr"; none without one), "annotation" (source text or none)}],
//         "return_annotation", "returns": [[line, has_value, text]],
//         "raises": [[line, exception, text]] (exception "" for a bare raise),
//         "calls": [[line, callee text]], "reads", "writes", "globals",
//         "nonlocals", "excepts": [[line, [types]]] ([] for a bare except),
//         "complexity" (McCabe's v(G): 1 + if/elif/ternary/for/while/except/
//             case/assert/boolean operators/comprehension clauses),
//         "end_reachable" (control can fall off the end: an implicit None)}],
//     "classes": [{"name", "qualname", "line", "end", "bases": [text], "doc",
//                  "methods": [names], "decorators"}],
//     "imports": [{"line", "module", "names": [...], "alias", "quoted"}],
//     "module": the same facts as a function's for the top-level code,
//     "unreachable": [[line, end, after_line, after_kind]] - statements after
//         a return/raise/break/continue (or an if/try whose every branch
//         ends so) in the same block,
//     "bare_excepts": [line], "none_compares": [[line, op]] (== / != None)}
// Lines are 1-based. A function's or class's end includes the comment lines
// inside it (its block ends where the indentation returns to the def's).
struct FParam { std::string name, kind, def, def_kind, ann; bool has_def = false, has_ann = false; };
struct FFunc {
    std::string name, qual, cls, parent, doc, ret_ann;
    int line = 0, first = 0, end = 0, doc_line = 0, complexity = 1;
    bool is_async = false, is_gen = false, has_doc = false, has_ret_ann = false, end_reachable = true;
    std::vector<FParam> params;
    std::vector<std::string> decorators;
    std::vector<std::tuple<int, bool, std::string>> returns;
    std::vector<std::tuple<int, std::string, std::string>> raises;
    std::vector<std::pair<int, std::string>> calls;
    std::vector<std::pair<int, std::vector<std::string>>> excepts;
    std::set<std::string> reads, writes, globals, nonlocals;
    std::vector<std::string> write_order;
};
struct FClass {
    std::string name, qual, doc;
    int line = 0, end = 0;
    bool has_doc = false;
    std::vector<std::string> bases, methods, decorators;
};
struct FImport { int line = 0; std::string module, alias; std::vector<std::string> names; bool quoted = false; };

std::string py_repr_str(const std::string& s) {
    bool sq = s.find('\'') != std::string::npos, dq = s.find('"') != std::string::npos;
    char q = (sq && !dq) ? '"' : '\'';
    std::string o(1, q);
    for (unsigned char c : s) {
        if (c == '\\') o += "\\\\";
        else if (c == (unsigned char)q) { o += '\\'; o += (char)c; }
        else if (c == '\n') o += "\\n";
        else if (c == '\t') o += "\\t";
        else if (c == '\r') o += "\\r";
        else if (c < 0x20 || c == 0x7f) { char b[8]; snprintf(b, sizeof b, "\\x%02x", c); o += b; }
        else o += (char)c;
    }
    o += q;
    return o;
}

// Source text of an expression, from the AST (what a default, a decorator,
// a callee or a returned value says); "..." for what it does not render.
std::string unparse(const node_ptr& n, int depth = 0) {
    if (!n) return std::string();
    if (depth > 24) return "...";
    auto U = [&](const node_ptr& c) { return unparse(c, depth + 1); };
    auto join = [&](const std::vector<node_ptr>& v) {
        std::string o;
        for (size_t i = 0; i < v.size(); i++) { if (i) o += ", "; o += U(v[i]); }
        return o;
    };
    switch (n->type()) {
        case NodeType::INTEGER: case NodeType::FLOAT: return n->token().value;
        case NodeType::STRING: return py_repr_str(n->token().value);
        case NodeType::BYTES: return "b" + py_repr_str(n->token().value);
        case NodeType::TRUE: return "True";
        case NodeType::FALSE: return "False";
        case NodeType::NONE: return "None";
        case NodeType::UNDEFINED: return "undefined";
        case NodeType::VARIABLE: return n->value();
        case NodeType::SELF: return "self";
        case NodeType::SUPER: return "super";
        case NodeType::ATTRIBUTE: { auto a = std::static_pointer_cast<AttributeNode>(n); return U(a->object) + "." + a->attr; }
        case NodeType::SUBSCRIPT: { auto s = std::static_pointer_cast<SubscriptNode>(n); return U(s->object) + "[" + U(s->index) + "]"; }
        case NodeType::SLICE: { auto s = std::static_pointer_cast<SliceNode>(n); std::string o = U(s->start) + ":" + U(s->end_node); if (s->step) o += ":" + U(s->step); return o; }
        case NodeType::CALL: { auto c = std::static_pointer_cast<CallNode>(n); return U(c->callee) + "(" + join(c->args) + ")"; }
        case NodeType::KEYWORD_ARG: { auto k = std::static_pointer_cast<KeywordArgNode>(n); return k->name + "=" + U(k->val); }
        case NodeType::UNARY: {
            auto u = std::static_pointer_cast<UnaryNode>(n);
            if (u->op == "not" || u->op == "!") return "not " + U(u->operand);
            return u->op + U(u->operand);
        }
        case NodeType::BINARY: { auto b = std::static_pointer_cast<BinaryNode>(n); return U(b->left) + " " + b->op + " " + U(b->right); }
        case NodeType::LIST: case NodeType::ARRAY: return "[" + join(n->statements()) + "]";
        case NodeType::TUPLE: { auto e = n->statements(); return "(" + join(e) + (e.size() == 1 ? ",)" : ")"); }
        case NodeType::MAP: {
            std::string o = "{";
            auto es = n->statements();
            for (size_t i = 0; i < es.size(); i++) {
                if (i) o += ", ";
                if (es[i] && es[i]->type() == NodeType::MAP_ENTRY) { auto e = std::static_pointer_cast<MapEntryNode>(es[i]); o += U(e->key) + ": " + U(e->val); }
                else o += U(es[i]);
            }
            return o + "}";
        }
        case NodeType::LAMBDA: return "lambda";
        case NodeType::IF: {
            auto i = std::static_pointer_cast<IfNode>(n);
            if (i->is_expr) return U(i->then_branch) + " if " + U(i->condition) + " else " + U(i->else_branch);
            return "...";
        }
        case NodeType::COMPREHENSION: {
            auto c = std::static_pointer_cast<ComprehensionNode>(n);
            std::string o = U(c->elt);
            if (c->kind == ComprehensionNode::DICT) o += ": " + U(c->value);
            for (auto& cl : c->clauses) {
                o += " for " + U(cl.target) + " in " + U(cl.iter);
                for (auto& cd : cl.conds) o += " if " + U(cd);
            }
            if (c->kind == ComprehensionNode::LIST) return "[" + o + "]";
            if (c->kind == ComprehensionNode::GEN) return "(" + o + ")";
            return "{" + o + "}";
        }
        default: return "...";
    }
}

std::string default_kind(const node_ptr& n) {
    if (!n) return std::string();
    switch (n->type()) {
        case NodeType::INTEGER: case NodeType::FLOAT: case NodeType::STRING: case NodeType::BYTES:
        case NodeType::TRUE: case NodeType::FALSE: case NodeType::NONE: case NodeType::TUPLE: case NodeType::UNARY:
            return "literal";
        case NodeType::LIST: case NodeType::ARRAY: return "list";
        case NodeType::MAP: return "dict";
        case NodeType::COMPREHENSION: {
            int k = std::static_pointer_cast<ComprehensionNode>(n)->kind;
            return k == ComprehensionNode::DICT ? "dict" : k == ComprehensionNode::SET ? "set" : k == ComprehensionNode::LIST ? "list" : "expr";
        }
        case NodeType::CALL: return "call:" + unparse(std::static_pointer_cast<CallNode>(n)->callee);
        case NodeType::VARIABLE: case NodeType::ATTRIBUTE: return "name";
        default: return "expr";
    }
}

struct FactsWalker {
    std::vector<FFunc> funcs;
    std::vector<FClass> classes;
    std::vector<FImport> imports;
    FFunc module;
    std::vector<std::array<int, 3>> unreachable;
    std::vector<std::string> unreachable_kind;
    std::vector<int> bare_excepts;
    std::vector<std::pair<int, std::string>> none_cmps;
    const std::vector<std::string>* src = nullptr;
    std::vector<int> fstack;            // open functions (indices into funcs)
    std::vector<std::string> cstack;    // enclosing classes
    std::vector<int> class_open;        // open classes (indices into classes)
    std::vector<size_t> class_fdepths;  // len(fstack) when each class opened

    FFunc& cur() { return fstack.empty() ? module : funcs[fstack.back()]; }

    void touch(int line) {
        for (int fi : fstack) if (line > funcs[fi].end) funcs[fi].end = line;
        for (int ci : class_open) if (line > classes[ci].end) classes[ci].end = line;
    }
    // Where the block a statement on `line` opens ends: the last non-blank
    // line before the indentation returns to the statement's own.
    int indent_end(int line) {
        if (!src || line < 1 || line > (int)src->size()) return line;
        size_t ind = indent_width((*src)[line - 1], 4);
        int last = line;
        for (int l = line + 1; l <= (int)src->size(); l++) {
            const std::string& s = (*src)[l - 1];
            if (is_blank(s)) continue;
            if (indent_width(s, 4) <= ind) break;
            last = l;
        }
        return last;
    }
    void read(const std::string& n, std::set<std::string>* bound) {
        if (defuse_temp(n)) return;
        if (bound && bound->count(n)) return;
        cur().reads.insert(n);
    }
    void write(const std::string& n) {
        if (defuse_temp(n)) return;
        // directly in a class body: a class attribute, not a variable of
        // the enclosing scope
        if (!class_fdepths.empty() && fstack.size() == class_fdepths.back()) return;
        FFunc& f = cur();
        if (f.writes.insert(n).second) f.write_order.push_back(n);
    }
    void targets(const node_ptr& t, std::set<std::string>* bound) {
        if (!t) return;
        switch (t->type()) {
            case NodeType::VARIABLE: write(t->value()); return;
            case NodeType::TUPLE: case NodeType::LIST: for (auto& e : t->statements()) targets(e, bound); return;
            case NodeType::UNARY: targets(std::static_pointer_cast<UnaryNode>(t)->operand, bound); return;
            case NodeType::ATTRIBUTE: expr(std::static_pointer_cast<AttributeNode>(t)->object, bound); return;
            case NodeType::SUBSCRIPT: { auto s = std::static_pointer_cast<SubscriptNode>(t); expr(s->object, bound); expr(s->index, bound); return; }
            default: expr(t, bound); return;
        }
    }
    void expr(const node_ptr& n, std::set<std::string>* bound, int depth = 0) {
        if (!n || depth > 300) return;
        touch(n->line());
        auto R = [&](const node_ptr& c) { expr(c, bound, depth + 1); };
        switch (n->type()) {
            case NodeType::VARIABLE: read(n->value(), bound); return;
            case NodeType::SELF: read("self", bound); return;
            case NodeType::STRING: {
                const std::string& raw = n->token().value;
                size_t p = 0;
                while ((p = raw.find("${", p)) != std::string::npos) {
                    size_t e = raw.find('}', p + 2);
                    if (e == std::string::npos) break;
                    read(raw.substr(p + 2, e - p - 2), bound);
                    p = e + 1;
                }
                return;
            }
            case NodeType::ATTRIBUTE: R(std::static_pointer_cast<AttributeNode>(n)->object); return;
            case NodeType::SUBSCRIPT: { auto s = std::static_pointer_cast<SubscriptNode>(n); R(s->object); R(s->index); return; }
            case NodeType::UNARY: R(std::static_pointer_cast<UnaryNode>(n)->operand); return;
            case NodeType::BINARY: {
                auto b = std::static_pointer_cast<BinaryNode>(n);
                if (b->op == "and" || b->op == "or" || b->op == "&&" || b->op == "||") cur().complexity++;
                if ((b->op == "==" || b->op == "!=") && ((b->left && b->left->type() == NodeType::NONE) || (b->right && b->right->type() == NodeType::NONE)))
                    none_cmps.push_back({n->line(), b->op});
                R(b->left); R(b->right);
                return;
            }
            case NodeType::CALL: {
                auto c = std::static_pointer_cast<CallNode>(n);
                std::string callee = unparse(c->callee);
                if (!callee.empty() && callee.rfind("__dec", 0) != 0 && callee.rfind("_ny", 0) != 0) cur().calls.push_back({n->line(), callee});
                R(c->callee);
                for (auto& a : c->args) R(a);
                return;
            }
            case NodeType::KEYWORD_ARG: R(std::static_pointer_cast<KeywordArgNode>(n)->val); return;
            case NodeType::MAP_ENTRY: { auto e = std::static_pointer_cast<MapEntryNode>(n); R(e->key); R(e->val); return; }
            case NodeType::SLICE: { auto s = std::static_pointer_cast<SliceNode>(n); R(s->start); R(s->end_node); R(s->step); return; }
            case NodeType::RANGE: { auto s = std::static_pointer_cast<RangeNode>(n); R(s->start); R(s->end_node); R(s->step); return; }
            case NodeType::WALRUS: { auto w = std::static_pointer_cast<WalrusNode>(n); R(w->init); write(w->name); return; }
            case NodeType::IF: {
                auto i = std::static_pointer_cast<IfNode>(n);
                if (i->is_expr) cur().complexity++;
                R(i->condition); R(i->then_branch); R(i->else_branch);
                for (auto& e : i->elseif_branches) R(e);
                return;
            }
            case NodeType::YIELD: cur().is_gen = true; R(std::static_pointer_cast<YieldNode>(n)->expr); return;
            case NodeType::YIELD_FROM: cur().is_gen = true; R(std::static_pointer_cast<YieldFromNode>(n)->expr); return;
            case NodeType::LAMBDA: {
                auto l = std::static_pointer_cast<LambdaNode>(n);
                for (auto& dv : l->defaults) R(dv);
                std::set<std::string> b2 = bound ? *bound : std::set<std::string>();
                for (auto& p : l->params) { std::string pn = p->value(); while (!pn.empty() && pn[0] == '*') pn.erase(0, 1); b2.insert(pn); }
                expr(l->body, &b2, depth + 1);
                return;
            }
            case NodeType::COMPREHENSION: {
                auto c = std::static_pointer_cast<ComprehensionNode>(n);
                std::set<std::string> b2 = bound ? *bound : std::set<std::string>();
                for (auto& cl : c->clauses) {
                    cur().complexity++;
                    expr(cl.iter, &b2, depth + 1);
                    std::vector<std::string> ts;
                    DefUseWalker::target_names(cl.target, ts);
                    for (auto& t : ts) b2.insert(t);
                    for (auto& cd : cl.conds) { cur().complexity++; expr(cd, &b2, depth + 1); }
                }
                expr(c->elt, &b2, depth + 1);
                expr(c->value, &b2, depth + 1);
                return;
            }
            case NodeType::OPT_CHAIN: {
                auto o = std::static_pointer_cast<OptChainNode>(n);
                R(o->recv); R(o->index); R(o->call); R(o->rest);
                return;
            }
            case NodeType::FUNCTION: case NodeType::CLASS: stmt(n); return;
            default: break;
        }
        for (auto& c : n->statements()) R(c);
    }

    // A string token carries the line it starts on (round 83: it was the
    // line it ended on, and this counted the newlines back).
    static int string_first_line(const node_ptr& n) {
        return std::max(1, n->line());
    }
    static bool is_dec_block(const node_ptr& n) {
        if (!n || n->type() != NodeType::BLOCK) return false;
        auto ss = n->statements();
        if (ss.size() != 3 || !ss[0] || ss[0]->type() != NodeType::ASSIGNMENT) return false;
        auto a = std::static_pointer_cast<AssignmentNode>(ss[0]);
        return a->target && a->target->type() == NodeType::VARIABLE && a->target->value().rfind("__dec", 0) == 0;
    }
    // a `break` that leaves the loop this body belongs to
    static bool has_break(const node_ptr& n, int depth = 0) {
        if (!n || depth > 200) return false;
        switch (n->type()) {
            case NodeType::BREAK: return true;
            case NodeType::WHILE: case NodeType::FOR: case NodeType::FUNCTION: case NodeType::CLASS: case NodeType::LAMBDA: return false;
            case NodeType::IF: {
                auto i = std::static_pointer_cast<IfNode>(n);
                if (has_break(i->then_branch, depth + 1) || has_break(i->else_branch, depth + 1)) return true;
                for (auto& e : i->elseif_branches) if (has_break(std::static_pointer_cast<IfNode>(e)->then_branch, depth + 1)) return true;
                return false;
            }
            case NodeType::TRY: {
                auto t = std::static_pointer_cast<TryNode>(n);
                if (has_break(t->body, depth + 1) || has_break(t->else_clause, depth + 1) || has_break(t->finally_clause, depth + 1)) return true;
                for (auto& ec : t->except_clauses) if (has_break(std::static_pointer_cast<ExceptNode>(ec)->body, depth + 1)) return true;
                return false;
            }
            case NodeType::WITH: return has_break(std::static_pointer_cast<WithNode>(n)->body, depth + 1);
            case NodeType::SWITCH: {
                auto sw = std::static_pointer_cast<SwitchNode>(n);
                for (auto& c : sw->cases) if (has_break(std::static_pointer_cast<CaseNode>(c)->body, depth + 1)) return true;
                auto dn = std::dynamic_pointer_cast<DefaultNode>(sw->default_case);
                return has_break(dn ? dn->body : sw->default_case, depth + 1);
            }
            case NodeType::BLOCK: case NodeType::STATEMENTS: case NodeType::SCRIPT:
                for (auto& s : n->statements()) if (has_break(s, depth + 1)) return true;
                return false;
            default: return false;
        }
    }
    // Control never passes the end of this statement (or block).
    static bool terminates(const node_ptr& n, int depth = 0) {
        if (!n || depth > 200) return false;
        switch (n->type()) {
            case NodeType::RETURN: case NodeType::RAISE: case NodeType::BREAK: case NodeType::CONTINUE: return true;
            case NodeType::IF: {
                auto i = std::static_pointer_cast<IfNode>(n);
                if (i->is_expr || !i->else_branch) return false;
                if (!terminates(i->then_branch, depth + 1) || !terminates(i->else_branch, depth + 1)) return false;
                for (auto& e : i->elseif_branches) if (!terminates(std::static_pointer_cast<IfNode>(e)->then_branch, depth + 1)) return false;
                return true;
            }
            case NodeType::TRY: {
                auto t = std::static_pointer_cast<TryNode>(n);
                if (terminates(t->finally_clause, depth + 1)) return true;
                if (!(terminates(t->body, depth + 1) || terminates(t->else_clause, depth + 1))) return false;
                for (auto& ec : t->except_clauses) if (!terminates(std::static_pointer_cast<ExceptNode>(ec)->body, depth + 1)) return false;
                return true;
            }
            case NodeType::WHILE: {
                auto w = std::static_pointer_cast<WhileNode>(n);
                bool forever = w->condition && (w->condition->type() == NodeType::TRUE
                    || (w->condition->type() == NodeType::INTEGER && w->condition->token().value != "0"));
                return forever && !has_break(w->body);
            }
            case NodeType::WITH: return terminates(std::static_pointer_cast<WithNode>(n)->body, depth + 1);
            case NodeType::SWITCH: {
                auto sw = std::static_pointer_cast<SwitchNode>(n);
                if (!sw->default_case) return false;
                for (auto& c : sw->cases) if (!terminates(std::static_pointer_cast<CaseNode>(c)->body, depth + 1)) return false;
                auto dn = std::dynamic_pointer_cast<DefaultNode>(sw->default_case);
                return terminates(dn ? dn->body : sw->default_case, depth + 1);
            }
            case NodeType::BLOCK: case NodeType::STATEMENTS: case NodeType::SCRIPT:
                if (is_dec_block(n)) return false;
                for (auto& s : n->statements()) if (terminates(s, depth + 1)) return true;
                return false;
            default: return false;
        }
    }
    static const char* kind_of(const node_ptr& n) {
        switch (n->type()) {
            case NodeType::RETURN: return "return";
            case NodeType::RAISE: return "raise";
            case NodeType::BREAK: return "break";
            case NodeType::CONTINUE: return "continue";
            case NodeType::IF: return "if";
            case NodeType::TRY: return "try";
            case NodeType::WHILE: return "while";
            default: return "block";
        }
    }
    static int first_line(const node_ptr& n) {
        if (!n) return 0;
        if (is_dec_block(n)) return n->statements()[0]->line();
        if (n->type() == NodeType::BLOCK || n->type() == NodeType::STATEMENTS) {
            auto ss = n->statements();
            return ss.empty() ? n->line() : first_line(ss[0]);
        }
        return n->line();
    }

    void block(const node_ptr& b, bool doc_ok = false) {
        if (!b) return;
        NodeType t = b->type();
        if ((t == NodeType::BLOCK || t == NodeType::STATEMENTS || t == NodeType::SCRIPT) && !is_dec_block(b)) {
            auto ss = b->statements();
            for (size_t i = 0; i < ss.size(); i++) {
                const node_ptr& s = ss[i];
                if (!s) continue;
                if (i == 0 && doc_ok && s->type() == NodeType::STRING) { touch(s->line()); continue; }
                stmt(s);
                if (i + 1 < ss.size() && terminates(s)) {
                    int ul = first_line(ss[i + 1]);
                    int ue = 0;
                    for (size_t j = i + 1; j < ss.size(); j++) {
                        int fl = first_line(ss[j]);
                        ue = std::max(ue, std::max(fl, indent_end(fl)));
                    }
                    unreachable.push_back({ul, ue, s->line()});
                    unreachable_kind.push_back(kind_of(s));
                    for (size_t j = i + 1; j < ss.size(); j++) stmt(ss[j]);
                    break;
                }
            }
            return;
        }
        stmt(b);
    }

    void def(const node_ptr& s, const std::vector<std::string>& decos, int first) {
        auto f = std::static_pointer_cast<FunctionNode>(s);
        write(f->name);
        FFunc F;
        F.name = f->name;
        F.qual = f->qualname.empty() ? f->name : f->qualname;
        size_t base = class_fdepths.empty() ? (size_t)-1 : class_fdepths.back();
        F.cls = (!cstack.empty() && fstack.size() == base) ? cstack.back() : std::string();
        F.parent = fstack.empty() ? std::string() : funcs[fstack.back()].qual;
        F.line = s->line();
        F.first = first ? first : (f->first_line ? f->first_line : s->line());
        F.end = s->line();
        F.decorators = decos;
        F.is_async = f->is_async || f->is_async_gen;
        F.is_gen = f->is_async_gen;
        F.has_doc = f->has_doc;
        F.doc = f->doc;
        // parameters: names, kinds, defaults and annotations
        std::map<std::string, std::string> anns;
        if (f->annotations && f->annotations->type() == NodeType::MAP) {
            for (auto& e : f->annotations->statements()) {
                if (!e || e->type() != NodeType::MAP_ENTRY) continue;
                auto me = std::static_pointer_cast<MapEntryNode>(e);
                if (!me->key || me->key->type() != NodeType::STRING || !me->val) continue;
                std::string text;
                if (me->val->type() == NodeType::STRING) text = me->val->token().value;
                else if (me->val->type() == NodeType::CALL) {
                    auto c = std::static_pointer_cast<CallNode>(me->val);
                    if (c->args.size() >= 2 && c->args[1] && c->args[1]->type() == NodeType::STRING) text = c->args[1]->token().value;
                    else text = unparse(me->val);
                } else text = unparse(me->val);
                anns[me->key->token().value] = text;
            }
        }
        bool kwonly = false;
        for (size_t i = 0; i < f->params.size(); i++) {
            std::string pn = f->params[i]->value();
            if (pn == "*") { kwonly = true; continue; }
            FParam P;
            if (pn.rfind("**", 0) == 0) { P.name = pn.substr(2); P.kind = "var_keyword"; }
            else if (pn.rfind("*", 0) == 0) { P.name = pn.substr(1); P.kind = "var_positional"; kwonly = true; }
            else { P.name = pn; P.kind = i < f->posonly ? "positional_only" : kwonly ? "keyword_only" : "positional_or_keyword"; }
            node_ptr dv = i < f->defaults.size() ? f->defaults[i] : nullptr;
            if (dv) { P.has_def = true; P.def = unparse(dv); P.def_kind = default_kind(dv); }
            auto ai = anns.find(P.name);
            if (ai != anns.end()) { P.has_ann = true; P.ann = ai->second; }
            F.params.push_back(P);
        }
        auto ri = anns.find("return");
        if (ri != anns.end()) { F.has_ret_ann = true; F.ret_ann = ri->second; }
        // defaults are evaluated in the enclosing scope
        for (auto& dv : f->defaults) expr(dv, nullptr);
        funcs.push_back(F);
        int fi = (int)funcs.size() - 1;
        fstack.push_back(fi);
        for (auto& P : funcs[fi].params) write(P.name);
        if (f->body) {
            auto ss = f->body->statements();
            if (!ss.empty() && ss[0] && ss[0]->type() == NodeType::STRING) funcs[fi].doc_line = string_first_line(ss[0]);
        }
        block(f->body, true);
        funcs[fi].end_reachable = !terminates(f->body);
        int ie = indent_end(funcs[fi].line);
        if (ie > funcs[fi].end) funcs[fi].end = ie;
        int end = funcs[fi].end;
        fstack.pop_back();
        touch(end);
    }

    void klass(const node_ptr& s, const std::vector<std::string>& decos) {
        auto c = std::static_pointer_cast<ClassNode>(s);
        std::string bound = c->bind_name.empty() ? c->name : c->bind_name;
        write(bound);
        FClass C;
        C.name = bound;
        C.qual = c->qualname.empty() ? bound : c->qualname;
        C.line = s->line();
        C.end = s->line();
        C.doc = c->doc;
        C.has_doc = c->has_doc;
        C.decorators = decos;
        for (auto& b : c->bases) { C.bases.push_back(unparse(b)); expr(b, nullptr); }
        classes.push_back(C);
        int ci = (int)classes.size() - 1;
        class_open.push_back(ci);
        cstack.push_back(bound);
        class_fdepths.push_back(fstack.size());
        // the class body: its methods; its other statements count as the
        // enclosing scope's (rarely more than assignments)
        if (c->body) {
            auto ss = c->body->statements();
            for (size_t i = 0; i < ss.size(); i++) {
                node_ptr x = ss[i];
                if (!x) continue;
                if (i == 0 && x->type() == NodeType::STRING) { touch(x->line()); continue; }
                node_ptr inner = x;
                while (is_dec_block(inner)) inner = inner->statements()[1];
                if (inner && inner->type() == NodeType::FUNCTION) classes[ci].methods.push_back(std::static_pointer_cast<FunctionNode>(inner)->name);
                stmt(x);
            }
        }
        class_fdepths.pop_back();
        cstack.pop_back();
        class_open.pop_back();
        int ie = indent_end(classes[ci].line);
        if (ie > classes[ci].end) classes[ci].end = ie;
        touch(classes[ci].end);
    }

    // @d1 @d2 def f: the parser's [__decN__ = d, def, f = __decN__(f)] blocks
    void decorated(const node_ptr& b) {
        std::vector<std::string> decos;
        int first = b->line();
        node_ptr x = b;
        while (is_dec_block(x)) {
            auto ss = x->statements();
            auto a = std::static_pointer_cast<AssignmentNode>(ss[0]);
            decos.push_back(unparse(a->value_node));
            expr(a->value_node, nullptr);
            if (ss[0]->line() < first) first = ss[0]->line();
            x = ss[1];
        }
        if (x && x->type() == NodeType::FUNCTION) def(x, decos, first);
        else if (x && x->type() == NodeType::CLASS) klass(x, decos);
        else stmt(x);
    }

    void stmt(const node_ptr& s) {
        if (!s) return;
        touch(s->line());
        std::set<std::string>* nb = nullptr;
        switch (s->type()) {
            case NodeType::BLOCK: case NodeType::STATEMENTS:
                if (is_dec_block(s)) { decorated(s); return; }
                block(s);
                return;
            case NodeType::FUNCTION: def(s, {}, 0); return;
            case NodeType::CLASS: klass(s, {}); return;
            case NodeType::ASSIGNMENT: {
                auto a = std::static_pointer_cast<AssignmentNode>(s);
                expr(a->value_node, nb);
                targets(a->target, nb);
                return;
            }
            case NodeType::ASSIGNMENT_AUG: {
                auto a = std::static_pointer_cast<AugAssignNode>(s);
                expr(a->value_node, nb);
                expr(a->target, nb);
                targets(a->target, nb);
                return;
            }
            case NodeType::VARIABLE_DECL: {
                auto v = std::static_pointer_cast<VarDeclNode>(s);
                expr(v->init, nb);
                write(v->name);
                return;
            }
            case NodeType::IF: {
                auto i = std::static_pointer_cast<IfNode>(s);
                if (i->is_expr) break;
                cur().complexity++;
                expr(i->condition, nb);
                block(i->then_branch);
                for (auto& e : i->elseif_branches) {
                    auto ei = std::static_pointer_cast<IfNode>(e);
                    touch(ei->line());
                    cur().complexity++;
                    expr(ei->condition, nb);
                    block(ei->then_branch);
                }
                block(i->else_branch);
                return;
            }
            case NodeType::WHILE: {
                auto w = std::static_pointer_cast<WhileNode>(s);
                cur().complexity++;
                expr(w->condition, nb);
                block(w->body);
                block(w->else_branch);
                return;
            }
            case NodeType::FOR: {
                auto f = std::static_pointer_cast<ForNode>(s);
                cur().complexity++;
                expr(f->iterable, nb);
                targets(f->var, nb);
                for (auto& u : f->unpack_vars) targets(u, nb);
                block(f->body);
                block(f->else_branch);
                return;
            }
            case NodeType::TRY: {
                auto t = std::static_pointer_cast<TryNode>(s);
                block(t->body);
                for (auto& ec : t->except_clauses) {
                    auto en = std::static_pointer_cast<ExceptNode>(ec);
                    touch(en->line());
                    cur().complexity++;
                    std::vector<std::string> types;
                    for (auto& ty : en->types) if (!defuse_temp(ty)) { types.push_back(ty); read(ty, nb); }
                    if (en->types.empty()) bare_excepts.push_back(en->line());
                    cur().excepts.push_back({en->line(), types});
                    if (!en->var.empty()) write(en->var);
                    block(en->body);
                }
                block(t->else_clause);
                block(t->finally_clause);
                return;
            }
            case NodeType::WITH: {
                auto w = std::static_pointer_cast<WithNode>(s);
                expr(w->expr, nb);
                if (!w->alias.empty()) write(w->alias);
                block(w->body);
                return;
            }
            case NodeType::SWITCH: {
                auto sw = std::static_pointer_cast<SwitchNode>(s);
                expr(sw->subject, nb);
                for (auto& c : sw->cases) {
                    auto cn = std::static_pointer_cast<CaseNode>(c);
                    touch(cn->line());
                    cur().complexity++;
                    expr(cn->value_node, nb);
                    block(cn->body);
                }
                if (sw->default_case) {
                    auto dn = std::dynamic_pointer_cast<DefaultNode>(sw->default_case);
                    block(dn ? dn->body : sw->default_case);
                }
                return;
            }
            case NodeType::RETURN: {
                auto r = std::static_pointer_cast<ReturnNode>(s);
                bool has_value = r->expr && r->expr->type() != NodeType::NONE;
                cur().returns.push_back({s->line(), has_value, r->expr ? unparse(r->expr) : std::string()});
                expr(r->expr, nb);
                return;
            }
            case NodeType::RAISE: {
                auto r = std::static_pointer_cast<RaiseNode>(s);
                std::string exc;
                if (r->expr) {
                    node_ptr e = r->expr;
                    if (e->type() == NodeType::CALL) e = std::static_pointer_cast<CallNode>(e)->callee;
                    exc = unparse(e);
                }
                cur().raises.push_back({s->line(), exc, r->expr ? unparse(r->expr) : std::string()});
                expr(r->expr, nb);
                expr(r->cause, nb);
                return;
            }
            case NodeType::ASSERT: {
                auto a = std::static_pointer_cast<AssertNode>(s);
                cur().complexity++;
                expr(a->condition, nb);
                expr(a->message, nb);
                return;
            }
            case NodeType::IMPORT: {
                auto im = std::static_pointer_cast<ImportNode>(s);
                FImport I;
                I.line = s->line();
                I.module = im->module_name;
                I.alias = im->alias;
                I.quoted = im->quoted;
                // "from m import a as b": the parser joins name and alias
                // with \x05 (nyrt::import_name_alias); shown as " as "
                for (auto& n : im->names) {
                    std::string nm = n;
                    size_t x5 = nm.find('\x05');
                    if (x5 != std::string::npos) nm = nm.substr(0, x5) + " as " + nm.substr(x5 + 1);
                    I.names.push_back(nm);
                }
                imports.push_back(I);
                if (!im->names.empty()) {
                    for (auto& n : I.names) {
                        std::string nm = n;
                        size_t sp = nm.find(" as ");
                        if (sp != std::string::npos) nm = nm.substr(sp + 4);
                        if (nm != "*") write(nm);
                    }
                } else if (!im->alias.empty()) write(im->alias);
                else if (!im->quoted) { std::string m = im->module_name; size_t dot = m.find('.'); write(dot == std::string::npos ? m : m.substr(0, dot)); }
                return;
            }
            case NodeType::GLOBAL: {
                auto g = std::static_pointer_cast<GlobalNode>(s);
                if (g->is_nonlocal) cur().nonlocals.insert(g->name); else cur().globals.insert(g->name);
                return;
            }
            case NodeType::DELETE: targets(std::static_pointer_cast<DeleteNode>(s)->target, nb); return;
            case NodeType::PRINT: {
                auto p = std::static_pointer_cast<PrintNode>(s);
                cur().calls.push_back({s->line(), "print"});
                for (auto& a : p->args) expr(a, nb);
                expr(p->sep, nb); expr(p->end, nb);
                return;
            }
            case NodeType::PASS: case NodeType::BREAK: case NodeType::CONTINUE: return;
            default: break;
        }
        expr(s, nb);
    }
};

Value ny_facts(NythonExecutor& E, std::vector<Value>& args) {
    auto* res = new Object((Runnable*)E.runner, "map", Type::MAP);
    Value out((Collectable*)res);
    auto& M = *res->container;
    std::string src = args.empty() ? std::string() : E.getStringValue(args[0]);
    std::vector<std::string> src_lines;
    split_lines(src, src_lines);
    FactsWalker W;
    W.src = &src_lines;
    std::string error;
    int error_line = 0;
    try {
        auto source = SourceCode::from_text(src + "\n", "stdin");
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer = std::make_shared<Lexer>(source);
        auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)E.runner, lexer.get());
        lexer->tokenize();
        node_ptr ast = parser->parse();
        if (ast) {
            auto ss = ast->statements();
            if (!ss.empty() && ss[0] && ss[0]->type() == NodeType::STRING) {
                W.module.has_doc = true;
                W.module.doc = ss[0]->token().value;
                W.module.doc_line = FactsWalker::string_first_line(ss[0]);
            }
            W.block(ast, true);
            W.module.end_reachable = !FactsWalker::terminates(ast);
        }
    } catch (nython::exception::Error& e) { error = e.message(); error_line = (int)e.location().row; }
    catch (std::exception& e) { error = e.what(); }
    catch (std::string& s) { error = s; }
    catch (...) { error = "could not be parsed"; }
    W.module.name = "<module>";
    W.module.qual = "<module>";
    W.module.line = 1;
    W.module.first = 1;
    W.module.end = (int)src_lines.size();
    auto S = [&](const std::string& s) { return E.makeStringValue(s); };
    auto I = [&](long long x) { return Value(bigint(x)); };
    auto strs = [&](const std::set<std::string>& s) { ListBuilder l(E); for (auto& x : s) l.add_str(x); return l.done(); };
    auto vstrs = [&](const std::vector<std::string>& s) { ListBuilder l(E); for (auto& x : s) l.add_str(x); return l.done(); };
    auto newmap = [&]() { return new Object((Runnable*)E.runner, "map", Type::MAP); };
    auto opt_str = [&](bool has, const std::string& s) { return has ? S(s) : NONE_VALUE; };
    auto func_map = [&](const FFunc& F) {
        auto* m = newmap();
        Value mv((Collectable*)m);
        auto& C = *m->container;
        C["name"] = S(F.name);
        C["qualname"] = S(F.qual);
        C["class"] = S(F.cls);
        C["parent"] = S(F.parent);
        C["line"] = I(F.line);
        C["first"] = I(F.first ? F.first : F.line);
        C["end"] = I(F.end);
        C["decorators"] = vstrs(F.decorators);
        C["is_async"] = Value(F.is_async);
        C["is_generator"] = Value(F.is_gen);
        C["doc"] = opt_str(F.has_doc, F.doc);
        C["doc_line"] = I(F.doc_line);
        ListBuilder ps(E);
        for (auto& P : F.params) {
            auto* pm = newmap();
            Value pv((Collectable*)pm);
            auto& PC = *pm->container;
            PC["name"] = S(P.name);
            PC["kind"] = S(P.kind);
            PC["default"] = opt_str(P.has_def, P.def);
            PC["default_kind"] = opt_str(P.has_def, P.def_kind);
            PC["annotation"] = opt_str(P.has_ann, P.ann);
            ps.add(pv);
        }
        C["params"] = ps.done();
        C["return_annotation"] = opt_str(F.has_ret_ann, F.ret_ann);
        ListBuilder rs(E);
        for (auto& r : F.returns) { ListBuilder e(E); e.add_int(std::get<0>(r)); e.add(Value(std::get<1>(r))); e.add_str(std::get<2>(r)); rs.add(e.done()); }
        C["returns"] = rs.done();
        ListBuilder xs(E);
        for (auto& r : F.raises) { ListBuilder e(E); e.add_int(std::get<0>(r)); e.add_str(std::get<1>(r)); e.add_str(std::get<2>(r)); xs.add(e.done()); }
        C["raises"] = xs.done();
        ListBuilder cs(E);
        for (auto& c : F.calls) { ListBuilder e(E); e.add_int(c.first); e.add_str(c.second); cs.add(e.done()); }
        C["calls"] = cs.done();
        C["reads"] = strs(F.reads);
        C["writes"] = vstrs(F.write_order);
        C["globals"] = strs(F.globals);
        C["nonlocals"] = strs(F.nonlocals);
        ListBuilder es(E);
        for (auto& x : F.excepts) { ListBuilder e(E); e.add_int(x.first); e.add(vstrs(x.second)); es.add(e.done()); }
        C["excepts"] = es.done();
        C["complexity"] = I(F.complexity);
        C["end_reachable"] = Value(F.end_reachable);
        return mv;
    };
    if (!error.empty()) {
        ListBuilder e(E);
        e.add_int(error_line);
        e.add_str(error);
        M["error"] = e.done();
    } else M["error"] = NONE_VALUE;
    M["doc"] = opt_str(W.module.has_doc, W.module.doc);
    ListBuilder fs(E);
    for (auto& F : W.funcs) fs.add(func_map(F));
    M["functions"] = fs.done();
    ListBuilder cl(E);
    for (auto& C0 : W.classes) {
        auto* m = newmap();
        Value mv((Collectable*)m);
        auto& C = *m->container;
        C["name"] = S(C0.name);
        C["qualname"] = S(C0.qual);
        C["line"] = I(C0.line);
        C["end"] = I(C0.end);
        C["bases"] = vstrs(C0.bases);
        C["doc"] = opt_str(C0.has_doc, C0.doc);
        C["methods"] = vstrs(C0.methods);
        C["decorators"] = vstrs(C0.decorators);
        cl.add(mv);
    }
    M["classes"] = cl.done();
    ListBuilder im(E);
    for (auto& I0 : W.imports) {
        auto* m = newmap();
        Value mv((Collectable*)m);
        auto& C = *m->container;
        C["line"] = I(I0.line);
        C["module"] = S(I0.module);
        C["names"] = vstrs(I0.names);
        C["alias"] = S(I0.alias);
        C["quoted"] = Value(I0.quoted);
        im.add(mv);
    }
    M["imports"] = im.done();
    M["module"] = func_map(W.module);
    ListBuilder ur(E);
    for (size_t i = 0; i < W.unreachable.size(); i++) {
        ListBuilder e(E);
        e.add_int(W.unreachable[i][0]);
        e.add_int(W.unreachable[i][1]);
        e.add_int(W.unreachable[i][2]);
        e.add_str(W.unreachable_kind[i]);
        ur.add(e.done());
    }
    M["unreachable"] = ur.done();
    ListBuilder be(E);
    for (int l : W.bare_excepts) be.add_int(l);
    M["bare_excepts"] = be.done();
    ListBuilder nc(E);
    for (auto& p : W.none_cmps) { ListBuilder e(E); e.add_int(p.first); e.add_str(p.second); nc.add(e.done()); }
    M["none_compares"] = nc.done();
    return out;
}

// ── _ny_ast (round 83) ───────────────────────────────────────────────────────
// lib/ast.ny's ast.parse is the real parser's tree: Parser::parseAst parses
// in ast mode (Parser.cpp: Python's shapes kept where the parser would
// desugar, every node's token span recorded), and this turns that tree into
// Python's own, as nested maps:
//
//   {"_t": "BinOp", "lineno": 1, "col_offset": 0, "end_lineno": 1,
//    "end_col_offset": 5, "left": {...}, "op": "Add", "right": {...}}
//
// Operators and contexts are their class names ("Add", "Store"); a field
// that is None is absent; constants carry "value", except an int that does
// not fit 64 bits ("_int": its text), bytes ("_bytes": one character per
// byte), complex ("_complex": the imaginary literal) and Ellipsis
// ("_ellipsis") - lib/ast.ny makes those. Positions are CPython's: lines
// from 1, columns UTF-8 byte offsets from 0, ends just past the node.
// Nython-only syntax has Nython node kinds ("NyRange", "NyCoalesce" ...).
//
//   _ny_ast(source, mode="exec", filename="<unknown>")
//     -> {"_t": "Module"/"Expression"/"Interactive"/"FunctionType", ...}
//        or {"_error": [message, line, column, text]} (a SyntaxError)

struct AstPos { long long l = 0, c = 0, el = 0, ec = 0; bool ok = false; };

struct AstExporter {
    NythonExecutor& E;
    Parser& P;
    const std::vector<Token>& toks;
    std::vector<std::string> lines;
    bool in_fstr = false;   // inside an f-string's field: its nodes are located at the f-string
    AstPos fpos;

    AstExporter(NythonExecutor& e, Parser& p, const std::vector<Token>& t) : E(e), P(p), toks(t) {}

    // ── positions ──
    long long bytecol(long long row, long long ccol) const {
        if (ccol < 0) ccol = 0;
        if (row < 1 || row > (long long)lines.size()) return ccol;
        const std::string& s = lines[(size_t)row - 1];
        long long n = 0;
        size_t i = 0;
        while (i < s.size() && n < ccol) {
            i++;
            while (i < s.size() && u8_cont((unsigned char)s[i])) i++;
            n++;
        }
        return (long long)i + (ccol - n);
    }
    AstPos tokPos(const Token& t) const {
        AstPos p;
        p.l = t._location.row;
        p.c = bytecol(p.l, (long long)t._location.column - 1);
        if (t.end_row) {
            p.el = t.end_row;
            p.ec = bytecol(p.el, (long long)t.end_col - 1);
        } else {
            p.el = p.l;
            p.ec = p.c + (long long)t.value.size();
        }
        p.ok = p.l > 0;
        return p;
    }
    // a token by index: the lexer's, or (from Parser::kAstExtra) one of an
    // f-string field's, moved to the source's coordinates (round 83)
    const Token* tokAt(int i) const {
        if (i >= Parser::kAstExtra) {
            size_t k = (size_t)(i - Parser::kAstExtra);
            return k < P.ast_extra_toks_.size() ? &P.ast_extra_toks_[k] : nullptr;
        }
        return i >= 0 && i < (int)toks.size() ? &toks[(size_t)i] : nullptr;
    }
    AstPos spanPos(int t0, int t1) const {
        if (t0 < 0 || t1 < t0) return AstPos{};
        const Token* x0 = tokAt(t0);
        const Token* x1 = tokAt(t1);
        if (!x0 || !x1) return AstPos{};
        AstPos a = tokPos(*x0);
        AstPos b = tokPos(*x1);
        a.el = b.el;
        a.ec = b.ec;
        return a;
    }
    static AstPos merge(AstPos a, const AstPos& b) {
        if (!b.ok) return a;
        if (!a.ok) return b;
        if (b.l < a.l || (b.l == a.l && b.c < a.c)) { a.l = b.l; a.c = b.c; }
        if (b.el > a.el || (b.el == a.el && b.ec > a.ec)) { a.el = b.el; a.ec = b.ec; }
        return a;
    }
    // A node's own position: the parser's span for it, else `derived` (its
    // token and what its children cover).
    AstPos own(const Node* n, const AstPos& derived) const {
        if (in_fstr) return fpos;
        auto it = P.ast_spans_.find(n);
        if (it != P.ast_spans_.end()) {
            AstPos p = spanPos(it->second.first, it->second.second);
            if (p.ok) return p;
        }
        return derived;
    }
    // ... and with the parentheses written around it
    AstPos outer(const Node* n, const AstPos& p) const {
        if (in_fstr) return fpos;
        auto it = P.ast_outer_.find(n);
        if (it != P.ast_outer_.end() && it->second.first >= 0) {
            AstPos o = spanPos(it->second.first, it->second.second);
            if (o.ok) return o;
        }
        return p;
    }
    bool parenthesized(const Node* n) const { return P.ast_outer_.count(n) > 0; }
    std::string flag(const Node* n) const {
        auto it = P.ast_flags_.find(n);
        return it == P.ast_flags_.end() ? std::string() : it->second;
    }

    // ── values ──
    struct NMap { Object* o; Value v; };
    Value S(const std::string& s) { return E.makeStringValue(s); }
    Value I(long long x) { return Value(bigint(x)); }
    NMap node(const char* t) {
        NMap m{new Object((Runnable*)E.runner, "map", Type::MAP), Value()};
        m.v = Value((Collectable*)m.o);
        set(m, "_t", S(t));
        return m;
    }
    void set(NMap& m, const char* k, const Value& v) { (*m.o->container)[k] = v; }
    void setp(NMap& m, const AstPos& p) {
        if (!p.ok) return;
        set(m, "lineno", I(p.l));
        set(m, "col_offset", I(p.c));
        set(m, "end_lineno", I(p.el));
        set(m, "end_col_offset", I(p.ec));
    }
    void setx(NMap& m, const char* k, const node_ptr& n, const char* ctx = "Load") {
        if (!n) return;
        AstPos p;
        set(m, k, expr(n, ctx, p));
    }
    Value exprs(const std::vector<node_ptr>& v, const char* ctx, AstPos* cover = nullptr) {
        ListBuilder l(E);
        for (auto& n : v) {
            AstPos p;
            if (!n) { l.add(NONE_VALUE); continue; }
            l.add(expr(n, ctx, p));
            if (cover) *cover = merge(*cover, p);
        }
        return l.done();
    }
    Value strs(const std::vector<std::string>& v) {
        ListBuilder l(E);
        for (auto& s : v) l.add_str(s);
        return l.done();
    }
    Value emptyList() { ListBuilder l(E); return l.done(); }

    // ── operators ──
    static const char* binop(const std::string& o) {
        static const std::map<std::string, const char*> m = {
            {"+", "Add"}, {"-", "Sub"}, {"*", "Mult"}, {"/", "Div"}, {"//", "FloorDiv"}, {"\\", "FloorDiv"},
            {"%", "Mod"}, {"**", "Pow"}, {"<<", "LShift"}, {">>", "RShift"}, {">>>", "RShift"}, {"|", "BitOr"},
            {"^", "BitXor"}, {"&", "BitAnd"}, {"@", "MatMult"}, {"??", "NyCoalesce"}, {"xor", "NyXor"}, {"^^", "NyXor"}};
        auto it = m.find(o);
        return it == m.end() ? nullptr : it->second;
    }
    static const char* cmpop(const std::string& o) {
        static const std::map<std::string, const char*> m = {
            {"==", "Eq"}, {"!=", "NotEq"}, {"<", "Lt"}, {"<=", "LtE"}, {">", "Gt"}, {">=", "GtE"},
            {"is", "Is"}, {"is not", "IsNot"}, {"in", "In"}, {"not in", "NotIn"},
            {"===", "NyStrictEq"}, {"!==", "NyStrictNotEq"}, {"instanceof", "NyInstanceOf"}};
        auto it = m.find(o);
        return it == m.end() ? nullptr : it->second;
    }
    static const char* augop(std::string o) {
        if (o == "??=") return "NyCoalesce";
        if (!o.empty() && o.back() == '=') o.pop_back();
        if (o == "&&") return "BitAnd";
        if (o == "||") return "BitOr";
        if (o == "~") return "Invert";
        return binop(o);
    }

    // ── expressions ──
    // `p` gets the node's position with any parentheses around it (what its
    // parent covers).
    Value expr(const node_ptr& n, const char* ctx, AstPos& p) {
        if (!n) { p = AstPos{}; return NONE_VALUE; }
        AstPos inner;
        Value v = expr1(n, ctx, inner);
        p = outer(n.get(), inner);
        return v;
    }

    Value constant(const char* /*kindless*/, const Value& v, const AstPos& p) {
        NMap m = node("Constant");
        set(m, "value", v);
        setp(m, p);
        return m.v;
    }

    Value name(const std::string& id, const char* ctx, const AstPos& p) {
        NMap m = node("Name");
        set(m, "id", S(id));
        set(m, "ctx", S(ctx));
        setp(m, p);
        return m.v;
    }

    void flattenBool(const node_ptr& n, const std::string& op, std::vector<node_ptr>& out) {
        if (n && n->type() == NodeType::BINARY && !parenthesized(n.get())) {
            auto* b = static_cast<BinaryNode*>(n.get());
            std::string o = b->op == "&&" ? "and" : b->op == "||" ? "or" : b->op;
            if (o == op) { flattenBool(b->left, op, out); out.push_back(b->right); return; }
        }
        out.push_back(n);
    }

    Value intConst(const Token& t, const AstPos& p) {
        std::string s;
        for (char c : t.value) if (c != '_') s += c;
        NMap m = node("Constant");
        int base = 10;
        std::string digits = s;
        if (s.size() > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; digits = s.substr(2); }
        else if (s.size() > 2 && s[0] == '0' && (s[1] == 'o' || s[1] == 'O')) { base = 8; digits = s.substr(2); }
        else if (s.size() > 2 && s[0] == '0' && (s[1] == 'b' || s[1] == 'B')) { base = 2; digits = s.substr(2); }
        bool done = false;
        if (digits.size() < 16 || (base == 10 && digits.size() < 18)) {
            try {
                size_t used = 0;
                long long x = std::stoll(digits, &used, base);
                if (used == digits.size()) { set(m, "value", I(x)); done = true; }
            } catch (...) {}
        }
        if (!done) set(m, "_int", S(s));
        setp(m, p);
        return m.v;
    }

    Value bytesConst(const std::string& raw, const AstPos& p) {
        std::string u;   // one character per byte (U+0000..U+00FF)
        for (unsigned char c : raw) {
            if (c < 0x80) u += (char)c;
            else { u += (char)(0xC0 | (c >> 6)); u += (char)(0x80 | (c & 0x3F)); }
        }
        NMap m = node("Constant");
        set(m, "_bytes", S(u));
        setp(m, p);
        return m.v;
    }

    Value keyword(const std::string* arg, const node_ptr& val, AstPos p) {
        NMap m = node("keyword");
        if (arg) set(m, "arg", S(*arg));
        AstPos vp;
        set(m, "value", expr(val, "Load", vp));
        setp(m, merge(p, vp));
        return m.v;
    }

    Value call(CallNode* c, const AstPos& own_p, AstPos& cover) {
        NMap m = node("Call");
        AstPos fp;
        set(m, "func", expr(c->callee, "Load", fp));
        cover = merge(cover, fp);
        ListBuilder args(E), kws(E);
        for (auto& a : c->args) {
            if (!a) continue;
            AstPos ap;
            if (a->type() == NodeType::KEYWORD_ARG) {
                auto* k = static_cast<KeywordArgNode*>(a.get());
                Value kv = keyword(&k->name, k->val, own(a.get(), tokPos(a->tok())));
                kws.add(kv);
                continue;
            }
            if (a->type() == NodeType::UNARY && static_cast<UnaryNode*>(a.get())->op == "**") {
                Value kv = keyword(nullptr, static_cast<UnaryNode*>(a.get())->operand, own(a.get(), tokPos(a->tok())));
                kws.add(kv);
                continue;
            }
            args.add(expr(a, "Load", ap));
            cover = merge(cover, ap);
        }
        set(m, "args", args.done());
        set(m, "keywords", kws.done());
        setp(m, own(c, own_p));
        return m.v;
    }

    Value arg(const node_ptr& pn, const std::string& nm, const node_ptr& ann) {
        NMap m = node("arg");
        set(m, "arg", S(nm));
        AstPos ap;
        if (ann) set(m, "annotation", expr(ann, "Load", ap));
        AstPos p = own(pn.get(), tokPos(pn->tok()));
        setp(m, p);
        return m.v;
    }

    Value arguments(const std::vector<node_ptr>& params, const std::vector<node_ptr>& defs, size_t posonly,
                    const node_ptr& anns) {
        std::map<std::string, node_ptr> ann;
        if (anns && anns->type() == NodeType::MAP)
            for (auto& e : static_cast<MapNode*>(anns.get())->entries) {
                auto* me = static_cast<MapEntryNode*>(e.get());
                if (me->key) ann[me->key->tok().value] = me->val;
            }
        ListBuilder po(E), as(E), kwo(E), kwd(E), dfl(E);
        Value vararg = NONE_VALUE, kwarg = NONE_VALUE;
        bool star = false;
        size_t npos = 0;
        for (size_t i = 0; i < params.size(); i++) {
            std::string pn = params[i]->value();
            node_ptr d = i < defs.size() ? defs[i] : nullptr;
            if (pn == "*") { star = true; continue; }
            if (pn.size() > 1 && pn[0] == '*' && pn[1] == '*') {
                std::string nm = pn.substr(2);
                kwarg = arg(params[i], nm, ann.count(nm) ? ann[nm] : nullptr);
                continue;
            }
            if (pn.size() > 1 && pn[0] == '*') {
                std::string nm = pn.substr(1);
                vararg = arg(params[i], nm, ann.count(nm) ? ann[nm] : nullptr);
                star = true;
                continue;
            }
            Value a = arg(params[i], pn, ann.count(pn) ? ann[pn] : nullptr);
            if (star) {
                kwo.add(a);
                if (d) { AstPos dp; kwd.add(expr(d, "Load", dp)); } else kwd.add(NONE_VALUE);
                continue;
            }
            if (npos < posonly) po.add(a); else as.add(a);
            npos++;
            if (d) { AstPos dp; dfl.add(expr(d, "Load", dp)); }
        }
        NMap m = node("arguments");
        set(m, "posonlyargs", po.done());
        set(m, "args", as.done());
        if (vararg.type != ValueType::NONE) set(m, "vararg", vararg);
        set(m, "kwonlyargs", kwo.done());
        set(m, "kw_defaults", kwd.done());
        if (kwarg.type != ValueType::NONE) set(m, "kwarg", kwarg);
        set(m, "defaults", dfl.done());
        return m.v;
    }

    Value comprehension(ComprehensionNode* c, AstPos& cover) {
        static const char* kinds[] = {"ListComp", "SetComp", "DictComp", "GeneratorExp"};
        NMap m = node(kinds[c->kind & 3]);
        AstPos ep;
        if (c->kind == ComprehensionNode::DICT) {
            set(m, "key", expr(c->elt, "Load", ep));
            cover = merge(cover, ep);
            set(m, "value", expr(c->value, "Load", ep));
        } else set(m, "elt", expr(c->elt, "Load", ep));
        cover = merge(cover, ep);
        ListBuilder gens(E);
        for (auto& cl : c->clauses) {
            NMap g = node("comprehension");
            AstPos tp, ip;
            set(g, "target", expr(cl.target, "Store", tp));
            set(g, "iter", expr(cl.iter, "Load", ip));
            cover = merge(cover, merge(tp, ip));
            AstPos cp;
            set(g, "ifs", exprs(cl.conds, "Load", &cp));
            cover = merge(cover, cp);
            set(g, "is_async", I(flag(cl.iter.get()) == "async" ? 1 : 0));
            gens.add(g.v);
        }
        set(m, "generators", gens.done());
        return m.v;
    }

    Value joinedStr(PyAstNode* js, const AstPos& p, bool is_spec) {
        NMap m = node("JoinedStr");
        ListBuilder vals(E);
        const std::vector<node_ptr>* parts = js->listOf("values");
        bool last_field = false;
        // round 83: an f-string the parser located part by part
        // (Parser::fstringAst): each part at its own position
        const bool exact = js->numOf("exact", 0) != 0 && !in_fstr;
        if (parts) for (auto& part : *parts) {
            if (!part) continue;
            if (part->type() == NodeType::STRING) {
                NMap c = node("Constant");
                set(c, "value", S(part->tok().value));
                setp(c, exact ? tokPos(part->tok()) : p);
                vals.add(c.v);
                last_field = false;
                continue;
            }
            if (part->type() == NodeType::PY_AST) {
                auto* fv = static_cast<PyAstNode*>(part.get());
                NMap f = node("FormattedValue");
                const AstPos fp = exact ? tokPos(fv->tok()) : p;
                bool saved = in_fstr;
                AstPos saved_p = fpos;
                if (!(exact && fv->numOf("exact", 0))) {
                    in_fstr = true;
                    fpos = p;
                }
                AstPos vp;
                set(f, "value", expr(fv->kidOf("value"), "Load", vp));
                in_fstr = saved;
                fpos = saved_p;
                set(f, "conversion", I(fv->numOf("conversion", -1)));
                node_ptr spec = fv->kidOf("format_spec");
                if (spec && spec->type() == NodeType::PY_AST)
                    set(f, "format_spec", joinedStr(static_cast<PyAstNode*>(spec.get()), exact ? tokPos(spec->tok()) : p, true));
                setp(f, fp);
                vals.add(f.v);
                last_field = true;
            }
        }
        // CPython 3.12 ends a format spec whose last part is a field with an
        // empty Constant (its tokenizer's empty FSTRING_MIDDLE), located
        // where the spec ends
        if (is_spec && last_field) {
            NMap c = node("Constant");
            set(c, "value", S(""));
            AstPos z = p;
            if (exact) { z.l = p.el; z.c = p.ec; }
            setp(c, z);
            vals.add(c.v);
        }
        set(m, "values", vals.done());
        setp(m, p);
        return m.v;
    }

    Value pyAstExpr(PyAstNode* a, const node_ptr& n, const char* ctx, AstPos& p) {
        const std::string& k = a->kind;
        AstPos d = tokPos(n->tok());
        if (k == "Compare") {
            NMap m = node("Compare");
            AstPos lp;
            set(m, "left", expr(a->kidOf("left"), "Load", lp));
            ListBuilder ops(E);
            if (auto* os = a->strlOf("ops")) for (auto& o : *os) { const char* c = cmpop(o); ops.add_str(c ? c : o); }
            set(m, "ops", ops.done());
            AstPos cp;
            set(m, "comparators", exprs(*a->listOf("comparators"), "Load", &cp));
            p = own(n.get(), merge(lp, cp));
            setp(m, p);
            return m.v;
        }
        if (k == "NamedExpr") {
            NMap m = node("NamedExpr");
            AstPos tp, vp;
            set(m, "target", expr(a->kidOf("target"), "Store", tp));
            set(m, "value", expr(a->kidOf("value"), "Load", vp));
            p = own(n.get(), merge(tp, vp));
            setp(m, p);
            return m.v;
        }
        if (k == "Await") {
            NMap m = node("Await");
            AstPos vp;
            set(m, "value", expr(a->kidOf("value"), "Load", vp));
            p = own(n.get(), merge(d, vp));
            setp(m, p);
            return m.v;
        }
        if (k == "Ellipsis") {
            p = own(n.get(), d);
            NMap m = node("Constant");
            set(m, "_ellipsis", Value(true));
            setp(m, p);
            return m.v;
        }
        if (k == "Complex") {
            p = own(n.get(), d);
            NMap m = node("Constant");
            const std::string* t = a->strOf("text");
            set(m, "_complex", S(t ? *t : std::string("0j")));
            setp(m, p);
            return m.v;
        }
        if (k == "JoinedStr") {
            p = own(n.get(), d);
            return joinedStr(a, p, false);
        }
        if (k == "Slice") {
            NMap m = node("Slice");
            AstPos c = d, x;
            if (a->kidOf("lower")) { set(m, "lower", expr(a->kidOf("lower"), "Load", x)); c = merge(c, x); }
            if (a->kidOf("upper")) { set(m, "upper", expr(a->kidOf("upper"), "Load", x)); c = merge(c, x); }
            if (a->kidOf("step")) { set(m, "step", expr(a->kidOf("step"), "Load", x)); c = merge(c, x); }
            p = own(n.get(), c);
            setp(m, p);
            return m.v;
        }
        if (k == "Set") {
            NMap m = node("Set");
            AstPos c = d;
            set(m, "elts", exprs(*a->listOf("elts"), "Load", &c));
            p = own(n.get(), c);
            setp(m, p);
            return m.v;
        }
        if (k == "Dict") {
            NMap m = node("Dict");
            AstPos c = d;
            set(m, "keys", exprs(*a->listOf("keys"), "Load", &c));
            set(m, "values", exprs(*a->listOf("values"), "Load", &c));
            p = own(n.get(), c);
            setp(m, p);
            return m.v;
        }
        if (k == "keyword") {
            p = own(n.get(), d);
            return keyword(a->strOf("arg"), a->kidOf("value"), p);
        }
        // a statement-only kind where an expression stands
        p = own(n.get(), d);
        NMap m = node("NyNode");
        set(m, "kind", S(k));
        setp(m, p);
        return m.v;
    }

    Value expr1(const node_ptr& n, const char* ctx, AstPos& p) {
        Node* raw = n.get();
        AstPos d = tokPos(raw->tok());
        switch (raw->type()) {
        case NodeType::INTEGER:
            p = own(raw, d);
            return intConst(raw->tok(), p);
        case NodeType::FLOAT: {
            p = own(raw, d);
            std::string s;
            for (char c : raw->tok().value) if (c != '_') s += c;
            return constant(nullptr, Value(std::strtod(s.c_str(), nullptr)), p);
        }
        case NodeType::STRING: {
            p = own(raw, d);
            NMap m = node("Constant");
            set(m, "value", S(raw->tok().value));
            // u"..." keeps its prefix as the kind
            const Token& t = raw->tok();
            if (t._location.row >= 1 && t._location.row <= lines.size() && !in_fstr) {
                const std::string& ln = lines[t._location.row - 1];
                size_t b = (size_t)bytecol(t._location.row, (long long)t._location.column - 1);
                if (b < ln.size() && (ln[b] == 'u' || ln[b] == 'U')) set(m, "kind", S("u"));
            }
            setp(m, p);
            return m.v;
        }
        case NodeType::BYTES:
            p = own(raw, d);
            return bytesConst(raw->tok().value, p);
        case NodeType::TRUE: case NodeType::FALSE: case NodeType::NONE: {
            p = own(raw, d);
            const std::string& t = raw->tok().value;
            if (t == "True") return constant(nullptr, Value(true), p);
            if (t == "False") return constant(nullptr, Value(false), p);
            if (t == "None") return constant(nullptr, NONE_VALUE, p);
            return name(t, ctx, p);   // true / false / none / null are names in Python
        }
        case NodeType::UNDEFINED:
            p = own(raw, d);
            return name(raw->tok().value, ctx, p);
        case NodeType::VARIABLE:
            p = own(raw, d);
            return name(static_cast<VariableNode*>(raw)->name, ctx, p);
        case NodeType::SELF: case NodeType::SUPER:
            p = own(raw, d);
            return name(raw->tok().value, ctx, p);
        case NodeType::LIST: case NodeType::TUPLE: case NodeType::ARRAY: {
            NMap m = node(raw->type() == NodeType::TUPLE ? "Tuple" : "List");
            AstPos c = raw->type() == NodeType::TUPLE ? AstPos{} : d;
            set(m, "elts", exprs(raw->statements(), ctx, &c));
            set(m, "ctx", S(ctx));
            p = own(raw, c.ok ? c : d);
            setp(m, p);
            return m.v;
        }
        case NodeType::MAP: {
            NMap m = node("Dict");
            ListBuilder ks(E), vs(E);
            AstPos c = d;
            for (auto& e : static_cast<MapNode*>(raw)->entries) {
                auto* me = static_cast<MapEntryNode*>(e.get());
                AstPos kp, vp;
                ks.add(expr(me->key, "Load", kp));
                vs.add(expr(me->val, "Load", vp));
                c = merge(c, merge(kp, vp));
            }
            set(m, "keys", ks.done());
            set(m, "values", vs.done());
            p = own(raw, c);
            setp(m, p);
            return m.v;
        }
        case NodeType::UNARY: {
            auto* u = static_cast<UnaryNode*>(raw);
            AstPos op;
            if (u->op == "*") {
                NMap m = node("Starred");
                set(m, "value", expr(u->operand, ctx, op));
                set(m, "ctx", S(ctx));
                p = own(raw, merge(d, op));
                setp(m, p);
                return m.v;
            }
            const char* o = u->op == "-" ? "USub" : u->op == "+" ? "UAdd" : u->op == "~" ? "Invert"
                          : (u->op == "not" || u->op == "!") ? "Not" : nullptr;
            NMap m = node(o ? "UnaryOp" : "NyUnaryOp");
            set(m, "op", S(o ? o : u->op));
            set(m, "operand", expr(u->operand, "Load", op));
            p = own(raw, merge(d, op));
            setp(m, p);
            return m.v;
        }
        case NodeType::BINARY: {
            auto* b = static_cast<BinaryNode*>(raw);
            std::string o = b->op == "&&" ? "and" : b->op == "||" ? "or" : b->op;
            if (o == "and" || o == "or") {
                std::vector<node_ptr> vals;
                flattenBool(b->left, o, vals);
                vals.push_back(b->right);
                NMap m = node("BoolOp");
                set(m, "op", S(o == "and" ? "And" : "Or"));
                AstPos c;
                set(m, "values", exprs(vals, "Load", &c));
                p = own(raw, c);
                setp(m, p);
                return m.v;
            }
            if (const char* co = cmpop(o)) {
                NMap m = node("Compare");
                AstPos lp, rp;
                set(m, "left", expr(b->left, "Load", lp));
                ListBuilder ops(E);
                ops.add_str(co);
                set(m, "ops", ops.done());
                ListBuilder cs(E);
                cs.add(expr(b->right, "Load", rp));
                set(m, "comparators", cs.done());
                p = own(raw, merge(lp, rp));
                setp(m, p);
                return m.v;
            }
            const char* bo = binop(o);
            NMap m = node("BinOp");
            AstPos lp, rp;
            set(m, "left", expr(b->left, "Load", lp));
            set(m, "op", S(bo ? bo : o));
            set(m, "right", expr(b->right, "Load", rp));
            p = own(raw, merge(lp, rp));
            setp(m, p);
            return m.v;
        }
        case NodeType::IF: {
            auto* in = static_cast<IfNode*>(raw);
            NMap m = node("IfExp");
            AstPos tp, bp, ep;
            set(m, "test", expr(in->condition, "Load", tp));
            set(m, "body", expr(in->then_branch, "Load", bp));
            set(m, "orelse", expr(in->else_branch, "Load", ep));
            p = own(raw, merge(merge(tp, bp), ep));
            setp(m, p);
            return m.v;
        }
        case NodeType::ATTRIBUTE: {
            auto* a = static_cast<AttributeNode*>(raw);
            NMap m = node("Attribute");
            AstPos vp;
            set(m, "value", expr(a->object, "Load", vp));
            set(m, "attr", S(a->attr));
            set(m, "ctx", S(ctx));
            p = own(raw, merge(vp, d));
            setp(m, p);
            return m.v;
        }
        case NodeType::SUBSCRIPT: {
            auto* s = static_cast<SubscriptNode*>(raw);
            NMap m = node("Subscript");
            AstPos vp, ip;
            set(m, "value", expr(s->object, "Load", vp));
            set(m, "slice", expr(s->index, "Load", ip));
            set(m, "ctx", S(ctx));
            p = own(raw, merge(vp, ip));
            setp(m, p);
            return m.v;
        }
        case NodeType::CALL: {
            AstPos c = d;
            Value v = call(static_cast<CallNode*>(raw), d, c);
            p = own(raw, c);
            return v;
        }
        case NodeType::LAMBDA: {
            auto* l = static_cast<LambdaNode*>(raw);
            NMap m = node("Lambda");
            set(m, "args", arguments(l->params, l->defaults, l->posonly, nullptr));
            AstPos bp;
            set(m, "body", expr(l->body, "Load", bp));
            p = own(raw, merge(d, bp));
            setp(m, p);
            return m.v;
        }
        case NodeType::YIELD: case NodeType::YIELD_FROM: {
            node_ptr e = raw->type() == NodeType::YIELD ? static_cast<YieldNode*>(raw)->expr : static_cast<YieldFromNode*>(raw)->expr;
            NMap m = node(raw->type() == NodeType::YIELD ? "Yield" : "YieldFrom");
            AstPos vp;
            if (e) set(m, "value", expr(e, "Load", vp));
            p = own(raw, merge(d, vp));
            setp(m, p);
            return m.v;
        }
        case NodeType::WALRUS: {
            auto* w = static_cast<WalrusNode*>(raw);
            NMap m = node("NamedExpr");
            set(m, "target", name(w->name, "Store", d));
            AstPos vp;
            set(m, "value", expr(w->init, "Load", vp));
            p = own(raw, merge(d, vp));
            setp(m, p);
            return m.v;
        }
        case NodeType::COMPREHENSION: {
            AstPos c;
            Value v = comprehension(static_cast<ComprehensionNode*>(raw), c);
            p = own(raw, c);
            Object* o = static_cast<Object*>(v.value.gc);
            NMap m{o, v};
            setp(m, p);
            return v;
        }
        case NodeType::RANGE: {
            auto* r = static_cast<RangeNode*>(raw);
            NMap m = node("NyRange");
            AstPos a, b, c;
            set(m, "lower", expr(r->start, "Load", a));
            set(m, "upper", expr(r->end_node, "Load", b));
            if (r->step) set(m, "step", expr(r->step, "Load", c));
            set(m, "inclusive", I(flag(raw) == "inclusive" ? 1 : 0));
            p = own(raw, merge(merge(a, b), c));
            setp(m, p);
            return m.v;
        }
        case NodeType::PY_AST:
            return pyAstExpr(static_cast<PyAstNode*>(raw), n, ctx, p);
        default: {
            p = own(raw, d);
            NMap m = node("NyNode");
            set(m, "kind", S(std::to_string((int)raw->type())));
            setp(m, p);
            return m.v;
        }
        }
    }

    // ── statements ──
    void stmts(const node_ptr& n, ListBuilder& out) {
        if (!n) return;
        NodeType t = n->type();
        if (t == NodeType::BLOCK || t == NodeType::STATEMENTS || t == NodeType::SCRIPT) {
            for (auto& s : n->statements()) stmts(s, out);
            return;
        }
        AstPos p;
        out.add(stmt(n, p));
    }
    Value body(const node_ptr& n) {
        ListBuilder l(E);
        stmts(n, l);
        return l.done();
    }

    Value funcDef(FunctionNode* f, const node_ptr& n, Value decos, AstPos& p) {
        NMap m = node(f->is_async ? "AsyncFunctionDef" : "FunctionDef");
        set(m, "name", S(f->name));
        set(m, "args", arguments(f->params, f->defaults, f->posonly, f->annotations));
        set(m, "body", body(f->body));
        set(m, "decorator_list", decos);
        if (f->annotations && f->annotations->type() == NodeType::MAP)
            for (auto& e : static_cast<MapNode*>(f->annotations.get())->entries) {
                auto* me = static_cast<MapEntryNode*>(e.get());
                if (me->key && me->key->tok().value == "return") { AstPos rp; set(m, "returns", expr(me->val, "Load", rp)); }
            }
        set(m, "type_params", emptyList());
        p = own(n.get(), tokPos(n->tok()));
        setp(m, p);
        return m.v;
    }

    Value classDef(ClassNode* c, const node_ptr& n, Value decos, AstPos& p) {
        NMap m = node("ClassDef");
        set(m, "name", S(c->name));
        ListBuilder bs(E), ks(E);
        for (auto& b : c->bases) { AstPos bp; bs.add(expr(b, "Load", bp)); }
        for (auto& kv : c->keywords) {
            if (kv.second && kv.second->type() == NodeType::PY_AST) { AstPos kp; ks.add(expr(kv.second, "Load", kp)); continue; }
            ks.add(keyword(kv.first == "**" ? nullptr : &kv.first, kv.second, AstPos{}));
        }
        set(m, "bases", bs.done());
        set(m, "keywords", ks.done());
        set(m, "body", body(c->body));
        set(m, "decorator_list", decos);
        set(m, "type_params", emptyList());
        p = own(n.get(), tokPos(n->tok()));
        setp(m, p);
        return m.v;
    }

    Value ifStmt(IfNode* in, const node_ptr& n, size_t from, AstPos& p) {
        // an If; elif branches [from..] become nested Ifs in orelse
        NMap m = node("If");
        AstPos tp;
        if (from == 0) {
            set(m, "test", expr(in->condition, "Load", tp));
            set(m, "body", body(in->then_branch));
            p = own(n.get(), tokPos(n->tok()));
        } else {
            auto* ei = static_cast<IfNode*>(in->elseif_branches[from - 1].get());
            set(m, "test", expr(ei->condition, "Load", tp));
            set(m, "body", body(ei->then_branch));
            p = own(in->elseif_branches[from - 1].get(), tokPos(ei->tok()));
        }
        if (from < in->elseif_branches.size()) {
            ListBuilder l(E);
            AstPos ep;
            l.add(ifStmt(in, n, from + 1, ep));
            set(m, "orelse", l.done());
        } else set(m, "orelse", body(in->else_branch));
        setp(m, p);
        return m.v;
    }

    Value assignChain(AssignmentNode* a, const node_ptr& n, AstPos& p) {
        // x = y = v: Assign(targets=[x, y], value=v)
        ListBuilder ts(E);
        node_ptr v = n;
        AstPos cover;
        while (v && v->type() == NodeType::ASSIGNMENT && v->tok().value != ":=") {
            auto* av = static_cast<AssignmentNode*>(v.get());
            AstPos tp;
            ts.add(expr(av->target, "Store", tp));
            cover = merge(cover, tp);
            v = av->value_node;
        }
        NMap m = node("Assign");
        set(m, "targets", ts.done());
        AstPos vp;
        set(m, "value", expr(v, "Load", vp));
        // (the parser's span can end at a tuple value's first item: `x = *a, b`)
        p = merge(own(n.get(), merge(cover, vp)), merge(cover, vp));
        setp(m, p);
        (void)a;
        return m.v;
    }

    Value pyAstStmt(PyAstNode* a, const node_ptr& n, AstPos& p) {
        const std::string& k = a->kind;
        AstPos d = tokPos(n->tok());
        if (k == "Decorated") {
            Value decos = exprs(*a->listOf("decorators"), "Load");
            node_ptr t = a->kidOf("target");
            if (t && t->type() == NodeType::FUNCTION) return funcDef(static_cast<FunctionNode*>(t.get()), t, decos, p);
            if (t && t->type() == NodeType::CLASS) return classDef(static_cast<ClassNode*>(t.get()), t, decos, p);
            return stmt(t, p);
        }
        NMap m = node(k.c_str());
        if (k == "Assign") {
            set(m, "targets", exprs(*a->listOf("targets"), "Store"));
            setx(m, "value", a->kidOf("value"));
        } else if (k == "AnnAssign") {
            setx(m, "target", a->kidOf("target"), "Store");
            setx(m, "annotation", a->kidOf("annotation"));
            setx(m, "value", a->kidOf("value"));
            set(m, "simple", I(a->numOf("simple")));
        } else if (k == "Global" || k == "Nonlocal") {
            set(m, "names", strs(*a->strlOf("names")));
        } else if (k == "Import" || k == "ImportFrom") {
            if (const std::string* mod = a->strOf("module")) set(m, "module", S(*mod));
            ListBuilder l(E);
            for (auto& al : *a->listOf("names")) {
                auto* aa = static_cast<PyAstNode*>(al.get());
                NMap am = node("alias");
                set(am, "name", S(*aa->strOf("name")));
                if (const std::string* as = aa->strOf("asname")) set(am, "asname", S(*as));
                setp(am, own(al.get(), tokPos(al->tok())));
                l.add(am.v);
            }
            set(m, "names", l.done());
            if (k == "ImportFrom") set(m, "level", I(a->numOf("level")));
        } else if (k == "Delete") {
            set(m, "targets", exprs(*a->listOf("targets"), "Del"));
        } else if (k == "With" || k == "AsyncWith") {
            ListBuilder l(E);
            for (auto& it : *a->listOf("items")) {
                auto* wi = static_cast<PyAstNode*>(it.get());
                NMap w = node("withitem");
                setx(w, "context_expr", wi->kidOf("context_expr"));
                setx(w, "optional_vars", wi->kidOf("optional_vars"), "Store");
                l.add(w.v);
            }
            set(m, "items", l.done());
            set(m, "body", body(a->kidOf("body")));
        } else if (k == "Match") {
            setx(m, "subject", a->kidOf("subject"));
            ListBuilder l(E);
            for (auto& c : *a->listOf("cases")) {
                auto* mc = static_cast<PyAstNode*>(c.get());
                NMap cm = node("match_case");
                set(cm, "pattern", pattern(mc->kidOf("pattern")));
                setx(cm, "guard", mc->kidOf("guard"));
                set(cm, "body", body(mc->kidOf("body")));
                l.add(cm.v);
            }
            set(m, "cases", l.done());
        } else {
            // an expression kind as a statement
            AstPos ep;
            Value v = pyAstExpr(a, n, "Load", ep);
            NMap e = node("Expr");
            set(e, "value", v);
            p = outer(n.get(), ep);
            setp(e, p);
            return e.v;
        }
        p = own(n.get(), d);
        setp(m, p);
        return m.v;
    }

    Value pattern(const node_ptr& n) {
        if (!n || n->type() != NodeType::PY_AST) return NONE_VALUE;
        auto* a = static_cast<PyAstNode*>(n.get());
        const std::string& k = a->kind;
        NMap m = node(k.c_str());
        if (k == "MatchValue" || k == "MatchSingleton") {
            node_ptr v = a->kidOf("value");
            if (k == "MatchSingleton") {
                const std::string& t = v->tok().value;
                set(m, "value", t == "True" || t == "true" ? Value(true) : t == "False" || t == "false" ? Value(false) : NONE_VALUE);
            } else setx(m, "value", v);
        } else if (k == "MatchSequence" || k == "MatchOr") {
            ListBuilder l(E);
            for (auto& s : *a->listOf("patterns")) l.add(pattern(s));
            set(m, "patterns", l.done());
        } else if (k == "MatchStar") {
            if (const std::string* nm = a->strOf("name")) set(m, "name", S(*nm));
        } else if (k == "MatchMapping") {
            set(m, "keys", exprs(*a->listOf("keys"), "Load"));
            ListBuilder l(E);
            for (auto& s : *a->listOf("patterns")) l.add(pattern(s));
            set(m, "patterns", l.done());
            if (const std::string* r = a->strOf("rest")) set(m, "rest", S(*r));
        } else if (k == "MatchClass") {
            setx(m, "cls", a->kidOf("cls"));
            ListBuilder l(E), kp(E);
            for (auto& s : *a->listOf("patterns")) l.add(pattern(s));
            for (auto& s : *a->listOf("kwd_patterns")) kp.add(pattern(s));
            set(m, "patterns", l.done());
            set(m, "kwd_attrs", strs(*a->strlOf("kwd_attrs")));
            set(m, "kwd_patterns", kp.done());
        } else if (k == "MatchAs") {
            if (node_ptr pp = a->kidOf("pattern")) set(m, "pattern", pattern(pp));
            if (const std::string* nm = a->strOf("name")) set(m, "name", S(*nm));
        }
        setp(m, own(n.get(), AstPos{}));
        return m.v;
    }

    Value stmt(const node_ptr& n, AstPos& p) {
        Node* raw = n.get();
        AstPos d = tokPos(raw->tok());
        switch (raw->type()) {
        case NodeType::FUNCTION:
            return funcDef(static_cast<FunctionNode*>(raw), n, emptyList(), p);
        case NodeType::CLASS:
            return classDef(static_cast<ClassNode*>(raw), n, emptyList(), p);
        case NodeType::INTERFACE: {
            auto* in = static_cast<InterfaceNode*>(raw);
            NMap m = node("ClassDef");
            set(m, "name", S(in->name));
            set(m, "bases", emptyList());
            set(m, "keywords", emptyList());
            set(m, "body", body(in->body));
            set(m, "decorator_list", emptyList());
            set(m, "type_params", emptyList());
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::RETURN: {
            NMap m = node("Return");
            setx(m, "value", static_cast<ReturnNode*>(raw)->expr);
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::ASSIGNMENT:
            return assignChain(static_cast<AssignmentNode*>(raw), n, p);
        case NodeType::ASSIGNMENT_AUG: {
            auto* a = static_cast<AugAssignNode*>(raw);
            NMap m = node("AugAssign");
            setx(m, "target", a->target, "Store");
            const char* o = augop(a->op);
            set(m, "op", S(o ? o : a->op));
            setx(m, "value", a->value_node);
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::VARIABLE_DECL: {
            // Nython's var/let/const x = v: an assignment of x
            auto* v = static_cast<VarDeclNode*>(raw);
            NMap m = node("Assign");
            ListBuilder ts(E);
            ts.add(name(v->name, "Store", d));
            set(m, "targets", ts.done());
            if (v->init) setx(m, "value", v->init);
            else set(m, "value", constant(nullptr, NONE_VALUE, d));
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::FOR: {
            auto* f = static_cast<ForNode*>(raw);
            NMap m = node(flag(raw) == "async" ? "AsyncFor" : "For");
            if (f->unpack_vars.empty()) setx(m, "target", f->var, "Store");
            else {
                NMap t = node("Tuple");
                std::vector<node_ptr> all{f->var};
                for (auto& u : f->unpack_vars) all.push_back(u);
                AstPos c;
                set(t, "elts", exprs(all, "Store", &c));
                set(t, "ctx", S("Store"));
                setp(t, c);
                set(m, "target", t.v);
            }
            setx(m, "iter", f->iterable);
            set(m, "body", body(f->body));
            set(m, "orelse", body(f->else_branch));
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::WHILE: {
            auto* w = static_cast<WhileNode*>(raw);
            NMap m = node("While");
            setx(m, "test", w->condition);
            set(m, "body", body(w->body));
            set(m, "orelse", body(w->else_branch));
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::IF: {
            auto* in = static_cast<IfNode*>(raw);
            if (in->is_expr) break;
            return ifStmt(in, n, 0, p);
        }
        case NodeType::TRY: {
            auto* t = static_cast<TryNode*>(raw);
            NMap m = node(flag(raw) == "star" ? "TryStar" : "Try");
            set(m, "body", body(t->body));
            ListBuilder hs(E);
            for (auto& h : t->except_clauses) {
                if (!h || h->type() != NodeType::PY_AST) continue;
                auto* ha = static_cast<PyAstNode*>(h.get());
                NMap hm = node("ExceptHandler");
                setx(hm, "type", ha->kidOf("type"));
                if (const std::string* nm = ha->strOf("name")) set(hm, "name", S(*nm));
                set(hm, "body", body(ha->kidOf("body")));
                setp(hm, own(h.get(), tokPos(h->tok())));
                hs.add(hm.v);
            }
            set(m, "handlers", hs.done());
            set(m, "orelse", body(t->else_clause));
            set(m, "finalbody", body(t->finally_clause));
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::RAISE: {
            auto* r = static_cast<RaiseNode*>(raw);
            NMap m = node("Raise");
            setx(m, "exc", r->expr);
            setx(m, "cause", r->cause);
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::ASSERT: {
            auto* a = static_cast<AssertNode*>(raw);
            NMap m = node("Assert");
            setx(m, "test", a->condition);
            setx(m, "msg", a->message);
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::PASS: case NodeType::BREAK: case NodeType::CONTINUE: {
            NMap m = node(raw->type() == NodeType::PASS ? "Pass" : raw->type() == NodeType::BREAK ? "Break" : "Continue");
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::DELETE: {
            NMap m = node("Delete");
            std::vector<node_ptr> one{static_cast<DeleteNode*>(raw)->target};
            set(m, "targets", exprs(one, "Del"));
            p = own(raw, d);
            setp(m, p);
            return m.v;
        }
        case NodeType::PRINT: {
            // Nython's print statement: print(args, sep=, end=)
            auto* pr = static_cast<PrintNode*>(raw);
            p = own(raw, d);
            NMap c = node("Call");
            set(c, "func", name("print", "Load", d));
            set(c, "args", exprs(pr->args, "Load"));
            ListBuilder kws(E);
            std::string sep = "sep", end = "end";
            if (pr->sep) kws.add(keyword(&sep, pr->sep, p));
            if (pr->end) kws.add(keyword(&end, pr->end, p));
            set(c, "keywords", kws.done());
            setp(c, p);
            NMap e = node("Expr");
            set(e, "value", c.v);
            setp(e, p);
            return e.v;
        }
        case NodeType::PY_AST:
            return pyAstStmt(static_cast<PyAstNode*>(raw), n, p);
        default:
            break;
        }
        // an expression statement
        AstPos ep;
        Value v = expr(n, "Load", ep);
        NMap e = node("Expr");
        set(e, "value", v);
        p = ep;
        setp(e, p);
        return e.v;
    }
};

Value ny_ast(NythonExecutor& E, std::vector<Value>& args) {
    std::string src = args.empty() ? std::string() : E.getStringValue(args[0]);
    std::string mode = args.size() > 1 && args[1].type != ValueType::NONE ? E.getStringValue(args[1]) : std::string("exec");
    std::string fname = args.size() > 2 && args[2].type != ValueType::NONE ? E.getStringValue(args[2]) : std::string("<unknown>");
    std::vector<std::string> src_lines;
    split_lines(src, src_lines);
    auto err_map = [&](const std::string& msg, long long line, long long col) {
        auto* m = new Object((Runnable*)E.runner, "map", Type::MAP);
        Value mv((Collectable*)m);
        ListBuilder e(E);
        e.add_str(msg);
        e.add_int(line);
        e.add_int(col);
        e.add_str(line >= 1 && line <= (long long)src_lines.size() ? src_lines[(size_t)line - 1] : std::string());
        (*m->container)["_error"] = e.done();
        return mv;
    };
    try {
        auto source = SourceCode::from_text(src + "\n", fname);
        auto reporter = std::make_shared<Reporter>(source);
        auto lexer = std::make_shared<Lexer>(source);
        lexer->force_python_strings = true;
        lexer->force_python_names = true;   // round 86: ast.parse is CPython's parser - `true` is a Name
        auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)E.runner, lexer.get());
        lexer->tokenize();
        if (lexer->hasErrors()) {
            for (auto& inf : lexer->info) {
                if (inf.level != LexerInfoLevel::Error) continue;
                const Token& t = inf.info;
                std::string what = t.type() == TokenType::UnterminatedStringError ? "unterminated string literal"
                                 : "invalid syntax";
                return err_map(what + " (detected at line " + std::to_string(t.line()) + ")", t.line(), t.column());
            }
        }
        node_ptr ast = parser->parseAst(mode);
        AstExporter X(E, *parser, lexer->tokens);
        X.lines = src_lines;
        if (mode == "eval") {
            AstExporter::NMap m = X.node("Expression");
            AstPos p;
            X.set(m, "body", X.expr(ast, "Load", p));
            return m.v;
        }
        if (mode == "func_type") {
            auto* ft = static_cast<PyAstNode*>(ast.get());
            AstExporter::NMap m = X.node("FunctionType");
            X.set(m, "argtypes", X.exprs(*ft->listOf("argtypes"), "Load"));
            X.setx(m, "returns", ft->kidOf("returns"));
            return m.v;
        }
        AstExporter::NMap m = X.node(mode == "single" ? "Interactive" : "Module");
        X.set(m, "body", X.body(ast));
        if (mode != "single") X.set(m, "type_ignores", X.emptyList());
        return m.v;
    } catch (nython::exception::Error& e) {
        return err_map(e.message(), (long long)e.location().row, (long long)e.location().column);
    } catch (std::exception& e) {
        return err_map(e.what(), 0, 0);
    } catch (std::string& s) {
        return err_map(s, 0, 0);
    } catch (...) {
        return err_map("invalid syntax", 0, 0);
    }
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

// fs_line_stats(root, include="*.ny") -> [[relpath, total, code, comment,
// blank, docstring], ...] for Code Statistics.
Value fs_line_stats(NythonExecutor& E, std::vector<Value>& args) {
    ListBuilder out(E);
    if (args.empty()) return out.done();
    std::string root = E.getStringValue(args[0]);
    while (root.size() > 1 && (root.back() == '/' || root.back() == '\\')) root.pop_back();
    auto includes = split_globs(args.size() > 1 ? E.getStringValue(args[1]) : std::string("*.ny"));
    std::unordered_set<std::string> skip;
    for (int i = 0; kDefaultSkip[i]; i++) skip.insert(kDefaultSkip[i]);
    std::vector<std::string> files;
    walk(root, "", skip, 20000, files, 0, true, 40);
    std::string text;
    for (auto& rel : files) {
        if (!includes.empty() && !path_matches(rel, includes)) continue;
        if (!read_small(root + "/" + rel, 8 * 1024 * 1024, text)) continue;
        std::vector<std::string> lines;
        split_lines(text, lines);
        if (!lines.empty() && lines.back().empty()) lines.pop_back();   // the final newline
        long long code = 0, comment = 0, blank = 0, doc = 0;
        char triple = 0;
        std::vector<bool> mask;
        for (auto& ln : lines) {
            bool was = triple != 0;
            bool has_comment = false, has_code = false;
            scan_line(ln, triple, mask, &has_comment, &has_code);
            std::string t = trim(ln);
            bool starts_doc = t.size() >= 3 && (t[0] == '"' || t[0] == '\'') && t[1] == t[0] && t[2] == t[0];
            if (was || starts_doc) { doc++; continue; }
            if (is_blank(ln)) { blank++; continue; }
            if (!has_code && has_comment) { comment++; continue; }
            code++;
        }
        ListBuilder h(E);
        h.add_str(rel); h.add_int((long long)lines.size());
        h.add_int(code); h.add_int(comment); h.add_int(blank); h.add_int(doc);
        out.add(h.done());
    }
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
    // `??=` and `??` are operators too (a `??=` split into `?? =` would no
    // longer parse); `?.` and `?[` are not spaced.
    static const char* ops3[] = {"**=", "//=", ">>=", "<<=", "===", "!==", "?\?=", nullptr};
    static const char* ops2[] = {"==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "->", ":=", "??", nullptr};
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
            if (name == "text_defuse") return text_defuse(E, args);   // round 79
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
            if (name == "ny_check_file") return ny_check_file(E, args);
            if (name == "ny_facts") return ny_facts(E, args);   // round 82
            break;
        case '_':
            if (name == "_ny_ast") return ny_ast(E, args);   // round 83: lib/ast.ny's parse
            if (name == "_ny_lsp") {   // round 86: lib/nylsp's natives (nylsp.cpp) - text in, text out
                std::vector<std::string> a;
                a.reserve(args.size());
                for (auto& v : args) {
                    if (v.type == ValueType::INTEGER) a.push_back(std::to_string(bigint_to_i64(v.value.i)));
                    else if (v.type == ValueType::BOOLEAN) a.push_back(v.value.b ? "1" : "0");
                    else if (v.type == ValueType::NONE || v.type == ValueType::UNDEFINED) a.push_back(std::string());
                    else a.push_back(E.getStringValue(v));
                }
                std::string out;
                try { out = nylsp::call(a); }
                catch (std::exception& e) { throw std::string("__exc__:ValueError:") + e.what(); }
                return E.makeStringValue(out);
            }
            break;
        case 'f':
            if (name == "fs_list_files") return fs_list_files(E, args);
            if (name == "fs_search") return fs_search(E, args);
            if (name == "fs_todos") return fs_todos(E, args);
            if (name == "fs_symbols") return fs_symbols(E, args);
            if (name == "fs_line_stats") return fs_line_stats(E, args);
            break;
    }
    return UNDEFINED_VALUE;
}
