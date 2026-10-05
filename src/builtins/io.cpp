#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/io.cpp
// File I/O (handle + path), KV store, ZIP
// ─────────────────────────────────────────────────────────────────────────────
// HOW THIS FILE WORKS:
//   dispatch_io() is called from NythonExecutor::callBuiltin().
//   It has full access to the executor via the `E` reference (same as `*this`
//   in the original monolithic main.cpp).  Every helper that was previously
//   a member call (getStringValue, makeStringValue, callBuiltin, etc.) is
//   accessed through `E.` — keeping code changes minimal.
// ─────────────────────────────────────────────────────────────────────────────

// Platform compatibility (must come first)
#include "platform_compat.hpp"

#include <algorithm>
#include <fstream>
#include <set>
#include <sstream>
#include <regex>
#include <cstdlib>
#include <cmath>
#include <chrono>
#include <random>
#include <thread>
#include <mutex>
#include <functional>
#include <iomanip>
#include <string>
#include <vector>
#include <map>
#include <ctime>
#include <cwctype>
#include <locale>

// Full executor definition (needed for E.getStringValue etc.)
#include "NythonExecutor.hpp"
#include "builtins/io.hpp"
#include "builtins/os.hpp"
#include "NyRuntime.hpp"
#include <cerrno>
#include <cstring>

// ── Namespace imports (match main.cpp) ────────────────────────────────────────
using namespace std;
using namespace nython;
using namespace nython::io;
using namespace nython::node;
using namespace nython::lexer;
using namespace nython::kernel;
using namespace nython::parser;
using namespace nython::reader;
using namespace nython::exception;

namespace {

// A file handle argument: the int file_open returns, or a file object from
// open() (its "handle" attribute) - an interpreter instance, or the map an
// instance becomes when the VM passes it through the builtin bridge.
long long handle_of(NythonExecutor& E, const Value& v) {
    if (v.type == ValueType::INTEGER) return bigint_to_i64(v.value.i);
    if (v.type == ValueType::DOUBLE) return (long long)v.value.d;
    if (nyos::is_map(v)) {
        for (auto& kv : nyos::map_items(v)) if (kv.first == "handle") return handle_of(E, kv.second);
        return -1;
    }
    if (v.type == ValueType::USERDATA && v.value.p && !E.string_ptrs_.count(v.value.p)
        && E.instance_properties.count(v.value.p)) {
        auto* pctx = E.instance_properties[v.value.p];
        if (pctx) {
            try {
                Value h = pctx->getByName("handle");
                if (h.type == ValueType::INTEGER || h.type == ValueType::DOUBLE) return handle_of(E, h);
            } catch (...) {}
        }
    }
    return -1;
}

// "r" "w" "a" "x" plus "+" "b" "t", as Python spells them, to an fopen mode.
// "x" (create, fail if it exists) is glibc's "wx".
std::string fopen_mode(const std::string& mode) {
    std::string m = mode.empty() ? "r" : mode;
    std::string base;
    bool plus = m.find('+') != std::string::npos, bin = m.find('b') != std::string::npos;
    if (m.find('x') != std::string::npos) base = "w";
    else if (m.find('w') != std::string::npos) base = "w";
    else if (m.find('a') != std::string::npos) base = "a";
    else base = "r";
    std::string out = base;
    if (plus) out += "+";
    if (bin) out += "b";   // text mode translates line endings on Windows only
#ifndef _WIN32
    if (m.find('x') != std::string::npos) out += "x";
#endif
    return out;
}

// kv store lines are "key \x1F value"; escape the separator, newlines and
// backslashes so any string round-trips (a newline used to end the value).
std::string kv_escape(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '\\') o += "\\\\";
        else if (c == '\n') o += "\\n";
        else if (c == '\r') o += "\\r";
        else if (c == '\x1F') o += "\\u";
        else o += c;
    }
    return o;
}
std::string kv_unescape(const std::string& s) {
    std::string o;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char n = s[++i];
            if (n == 'n') o += '\n';
            else if (n == 'r') o += '\r';
            else if (n == 'u') o += '\x1F';
            else o += n;
        } else o += s[i];
    }
    return o;
}
std::map<std::string, std::string> kv_load(const std::string& store, std::vector<std::string>* order = nullptr) {
    std::map<std::string, std::string> db;
    std::ifstream fin(store, std::ios::binary);
    if (!fin.is_open()) return db;
    std::string line;
    while (std::getline(fin, line)) {
        auto eq = line.find('\x1F');
        if (eq == std::string::npos) continue;
        std::string k = kv_unescape(line.substr(0, eq));
        if (order && !db.count(k)) order->push_back(k);
        db[k] = kv_unescape(line.substr(eq + 1));
    }
    return db;
}
bool kv_save(const std::string& store, const std::map<std::string, std::string>& db) {
    std::ofstream fout(store, std::ios::binary | std::ios::trunc);
    if (!fout.is_open()) return false;
    for (auto& kv : db) fout << kv_escape(kv.first) << '\x1F' << kv_escape(kv.second) << '\n';
    return true;
}

// Handles opened in text mode (no "b"): reading them turns \r\n into \n,
// Python's universal newlines. The Windows C runtime does that itself for
// a text-mode FILE*; elsewhere it is done here, so a CRLF file reads the same
// on every platform. Binary handles stay byte-exact.
std::set<FILE*>& text_handles() {
    static std::set<FILE*> s;
    return s;
}
void text_newlines(FILE* f, std::string& s) {
#ifndef _WIN32
    if (!text_handles().count(f) || s.find('\r') == std::string::npos) return;
    std::string o;
    o.reserve(s.size());
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '\r' && i + 1 < s.size() && s[i + 1] == '\n') continue;
        o += s[i];
    }
    s.swap(o);
#else
    (void)f; (void)s;
#endif
}
void track_text(FILE* f, const std::string& mode) {
    if (f && mode.find('b') == std::string::npos) text_handles().insert(f);
}

} // namespace

// ════════════════════════════════════════════════════════════════════════════════
// dispatch_io
// ════════════════════════════════════════════════════════════════════════════════
Value dispatch_io(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx) {
    // Local aliases — identical names to original main.cpp code so the
    // extracted if-blocks compile unchanged.
    auto  makeStringValue  = [&](const std::string& s) { return E.makeStringValue(s); };
    auto  getStringValue   = [&](const Value& v)       { return E.getStringValue(v); };
    auto  isStringValue    = [&](const Value& v)       { return E.isStringValue(v); };
    auto  callBuiltin      = [&](const std::string& n, std::vector<Value>& a, Context* c)
                                { return E.callBuiltin(n, a, c); };
    auto  callFunctionValue= [&](Value fn, std::vector<Value>& a, Context* c)
                                { return E.callFunctionValue(fn, a, c); };
    auto  isTruthy         = [&](Value v) { return E.isTruthy(v); };
    auto  evalNode         = [&](node_ptr n, Context* c) { return E.evalNode(n, c); };
    auto& file_handles     = E.file_handles;
    auto& next_file_handle = E.next_file_handle;
    Runnable* runner       = E.runner;
    auto& func_names       = E.func_names;
    auto& instance_to_class= E.instance_to_class;
    auto& instance_properties = E.instance_properties;
    auto& class_by_name    = E.class_by_name;
    auto& class_parent     = E.class_parent;
    auto& super_parent_stack = E.super_parent_stack;
    auto& func_ast_nodes   = E.func_ast_nodes;
    auto& func_id_store    = E.func_id_store;
    auto& instance_store   = E.instance_store;
    auto& string_store     = E.string_store;
    auto  registerBuiltin  = [&](const std::string& n) { E.registerBuiltin(n); };
    auto  callMethod       = [&](Value inst, const std::string& mname, std::vector<Value>& a, Context* c)
                                { return E.callMethod(inst, mname, a, c); };
    auto  printValue       = [&](const Value& v, Context* c = nullptr) { E.printValue(v, c ? c : ctx); };

    // ── shape_to_size helper (used by tensor builtins) ───────────────────────
    auto shape_to_size = [&](const Value& v) -> int {
        if (v.type == ValueType::INTEGER) return (int)bigint_to_i64(v.value.i);
        if (v.type == ValueType::DOUBLE)  return (int)v.value.d;
        if (v.isCollectable()) {
            auto* c = dynamic_cast<Container*>(v.value.gc);
            if (c && c->container) {
                auto li = c->container->find("__len__");
                int len = (li != c->container->end()) ? (int)bigint_to_i64(li->second.value.i) : 0;
                if (len == 0) return 0;
                int total = 1;
                for (int k = 0; k < len; k++) {
                    auto ei = c->container->find(std::to_string(k));
                    if (ei != c->container->end()) {
                        if (ei->second.type == ValueType::INTEGER)
                            total *= (int)bigint_to_i64(ei->second.value.i);
                        else if (ei->second.type == ValueType::DOUBLE)
                            total *= (int)ei->second.value.d;
                    }
                }
                return total;
            }
        }
        return 0;
    };

// ── Extracted builtin implementations ────────────────────────────────────────
        // =====================================================================
        // KEY-VALUE STORE (flat file, one "key \x1F value" line per entry)
        // =====================================================================
        if (name == "kv_set") {
            // kv_set(store_file, key, value_str) -> bool
            if (args.size() >= 3) {
                std::string store = getStringValue(args[0]);
                auto db = kv_load(store);
                db[getStringValue(args[1])] = getStringValue(args[2]);
                return Value(kv_save(store, db));
            }
            return Value(false);
        }
        if (name == "kv_get") {
            // kv_get(store_file, key) -> string or none
            if (args.size() >= 2) {
                auto db = kv_load(getStringValue(args[0]));
                auto it = db.find(getStringValue(args[1]));
                if (it != db.end()) return makeStringValue(it->second);
            }
            return NONE_VALUE;
        }
        if (name == "kv_del") {
            // kv_del(store_file, key) -> bool
            if (args.size() >= 2) {
                std::string store = getStringValue(args[0]);
                auto db = kv_load(store);
                bool erased = db.erase(getStringValue(args[1])) > 0;
                if (erased) kv_save(store, db);
                return Value(erased);
            }
            return Value(false);
        }
        if (name == "kv_keys") {
            // kv_keys(store_file) -> list of key strings
            if (!args.empty()) {
                std::vector<std::string> order;
                kv_load(getStringValue(args[0]), &order);
                return nyos::make_str_list(E, order);
            }
            return NONE_VALUE;
        }
        if (name == "kv_all") {
            // kv_all(store_file) -> map {key: value}
            if (!args.empty()) {
                auto* obj = new Object((Runnable*)runner, "map", Type::MAP);
                for (auto& kv : kv_load(getStringValue(args[0]))) obj->set(kv.first, makeStringValue(kv.second));
                return Value((Collectable*)obj);
            }
            return NONE_VALUE;
        }
        // ===================== COMPLETE I/O MODULE =====================
        if (name == "input") {
            // input(prompt): one line from stdin (NyConc.cpp: read_stdin_line -
            // the GIL is released while it waits, Ctrl+C raises
            // KeyboardInterrupt); EOFError at the end of input, as in Python.
            if (!args.empty()) std::cout << E.strOf(args[0]) << std::flush;
            std::string line;
            bool ok;
            try { ok = nyconc::read_stdin_line(line); }
            catch (nyconc::NyError& err) {
                if (!err.raw.empty()) throw std::string(err.raw);
                throw std::string("__exc__:" + err.type + ":" + err.msg);
            }
            if (!ok) E.pyRaise("EOFError", "EOF when reading a line");
            return E.makeStringValue(line);
        }
        // ── Handle-based files ───────────────────────────────────────────────
        // file_open(path, mode="r") -> int handle, or -1. Every handle
        // function also accepts the file object open() returns.
        if (name == "file_open" || name == "file_open_or_raise") {
            nyos::Args A(E, args, {"mode"});
            std::string path = A.str(0, "path");
            std::string mode = A.str(1, "mode", "r");
            bool raise = name == "file_open_or_raise";
            struct stat st;
            if (path.empty()) {
                if (raise) nyos::raise_errno(ENOENT, path);
                return Value(-1);
            }
            if (::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
                // fopen() of a directory for reading succeeds on Linux.
                if (raise) nyos::raise_errno(EISDIR, path);
                return Value(-1);
            }
            if (mode.find('x') != std::string::npos && ::stat(path.c_str(), &st) == 0) {
                if (raise) nyos::raise_errno(EEXIST, path);
                return Value(-1);
            }
            errno = 0;
            FILE* f = fopen(path.c_str(), fopen_mode(mode).c_str());
            if (!f) {
                if (raise) nyos::raise_errno(errno ? errno : ENOENT, path);
                return Value(-1);
            }
            track_text(f, mode);
            int handle = next_file_handle++;
            file_handles[handle] = f;
            return Value(handle);
        }
        if (name == "open") {
            // Reached only if the prelude's open() was replaced by a user
            // definition that calls the builtin: the legacy int handle.
            if (args.empty()) return Value(-1);
            std::string mode = args.size() >= 2 ? getStringValue(args[1]) : "r";
            FILE* f = fopen(getStringValue(args[0]).c_str(), fopen_mode(mode).c_str());
            if (!f) return Value(-1);
            track_text(f, mode);
            int handle = next_file_handle++;
            file_handles[handle] = f;
            return Value(handle);
        }
        auto file_of = [&](size_t i) -> FILE* {
            if (i >= args.size()) return nullptr;
            long long h = handle_of(E, args[i]);
            auto it = file_handles.find((int)h);
            return it == file_handles.end() ? nullptr : it->second;
        };
        if (name == "file_close" || name == "fclose") {
            if (args.empty()) return Value(false);
            long long h = handle_of(E, args[0]);
            auto it = file_handles.find((int)h);
            if (it == file_handles.end()) return Value(false);
            text_handles().erase(it->second);
            fclose(it->second);
            file_handles.erase(it);
            return Value(true);
        }
        if (name == "file_read" || name == "fread") {
            // file_read(h, size=-1): size < 0 reads to the end. Reads in
            // chunks, so pipes and other unseekable files work too (it used
            // to size the read with ftell/fseek).
            FILE* f = file_of(0);
            if (!f) return makeStringValue("");
            long long size = args.size() >= 2 ? nyos::to_int(args[1], -1) : -1;
            std::string content;
            if (size < 0) {
                // On the heap: a 64 KB array here made every call of
                // dispatch_io - every builtin the chain passes through it -
                // take 64 KB of stack, which overflowed the small stacks of
                // async tasks and generators (round 76).
                std::vector<char> buf(65536);
                size_t n;
                while ((n = fread(buf.data(), 1, buf.size(), f)) > 0) content.append(buf.data(), n);
            } else if (size > 0) {
                content.resize((size_t)size);
                size_t r = fread(&content[0], 1, (size_t)size, f);
                content.resize(r);
            }
            text_newlines(f, content);
            return makeStringValue(content);
        }
        if (name == "file_read_bytes") {
            // file_read_bytes(h, size=-1) -> bytes: a binary-mode read
            // (no newline translation).
            FILE* f = file_of(0);
            if (!f) nyos::raise("ValueError", "I/O operation on closed file");
            long long size = args.size() >= 2 ? nyos::to_int(args[1], -1) : -1;
            std::string content;
            if (size < 0) {
                std::vector<char> buf(65536);
                size_t n;
                while ((n = fread(buf.data(), 1, buf.size(), f)) > 0) content.append(buf.data(), n);
            } else if (size > 0) {
                content.resize((size_t)size);
                size_t r = fread(&content[0], 1, (size_t)size, f);
                content.resize(r);
            }
            return E.makeBytesValue(content);
        }
        if (name == "file_readline_bytes") {
            // file_readline_bytes(h, limit=-1) -> bytes up to and including
            // b"\n" (at most limit bytes); b"" at the end of the file.
            FILE* f = file_of(0);
            if (!f) nyos::raise("ValueError", "I/O operation on closed file");
            long long limit = args.size() >= 2 ? nyos::to_int(args[1], -1) : -1;
            std::string line;
            int c;
            while ((limit < 0 || (long long)line.size() < limit) && (c = fgetc(f)) != EOF) {
                line += (char)c;
                if (c == '\n') break;
            }
            return E.makeBytesValue(line);
        }
        if (name == "file_truncate") {
            // file_truncate(h, size=current position) -> the new size
            FILE* f = file_of(0);
            if (!f) nyos::raise("ValueError", "I/O operation on closed file");
            fflush(f);
            long long size = args.size() >= 2 && args[1].type != ValueType::NONE ? nyos::to_int(args[1], 0) : (long long)ftell(f);
#ifdef _WIN32
            if (_chsize_s(_fileno(f), size) != 0) nyos::raise_errno(errno ? errno : EINVAL, "truncate");
#else
            if (ftruncate(fileno(f), (off_t)size) != 0) nyos::raise_errno(errno ? errno : EINVAL, "truncate");
#endif
            return nyos::make_int(size);
        }
        if (name == "file_write" || name == "fwrite") {
            // A str is written as UTF-8; bytes/bytearray as they are.
            FILE* f = file_of(0);
            if (!f || args.size() < 2) return Value(-1);
            if (auto* bo = E.bytesOf(args[1])) {
                size_t written = fwrite(bo->s.data(), 1, bo->s.size(), f);
                return Value(static_cast<int>(written));
            }
            std::string data = getStringValue(args[1]);
            size_t written = fwrite(data.data(), 1, data.size(), f);
            return Value(static_cast<int>(written));
        }
        if (name == "file_readline" || name == "freadline") {
            // file_readline(h, keep_newline=false). Without keep_newline the
            // line ending is stripped and EOF is none (legacy); with it the
            // "\n" stays and EOF is "" (what file objects need). Lines of any
            // length - an 8 KB buffer used to split long lines in two.
            FILE* f = file_of(0);
            bool keep = args.size() >= 2 && E.isTruthy(args[1]);
            if (!f) return keep ? makeStringValue("") : NONE_VALUE;
            std::string line;
            int c;
            bool any = false;
            while ((c = fgetc(f)) != EOF) {
                any = true;
                line += (char)c;
                if (c == '\n') break;
            }
            if (!any) return keep ? makeStringValue("") : NONE_VALUE;
            text_newlines(f, line);
            if (!keep) while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
            return makeStringValue(line);
        }
        if (name == "file_seek") {
            // file_seek(h, offset, whence=0) -> new position (0 set, 1 cur, 2 end)
            FILE* f = file_of(0);
            if (!f) nyos::raise("ValueError", "file_seek: not an open file");
            long long off = args.size() >= 2 ? nyos::to_int(args[1], 0) : 0;
            int wh = args.size() >= 3 ? (int)nyos::to_int(args[2], 0) : 0;
            int w = wh == 1 ? SEEK_CUR : wh == 2 ? SEEK_END : SEEK_SET;
            if (fseek(f, (long)off, w) != 0) nyos::raise_errno(errno ? errno : EINVAL, "seek");
            return nyos::make_int((long long)ftell(f));
        }
        if (name == "file_tell") {
            FILE* f = file_of(0);
            if (!f) nyos::raise("ValueError", "file_tell: not an open file");
            return nyos::make_int((long long)ftell(f));
        }
        if (name == "file_flush") {
            FILE* f = file_of(0);
            if (f) fflush(f);
            return Value(f != nullptr);
        }
        if (name == "file_readlines" || name == "readlines") {
            // Read all lines from a file path
            if (args.size() >= 1) {
                std::string path = getStringValue(args[0]);
                std::ifstream file(path, std::ios::binary);   // \r stripped below, on every platform
                if (file.is_open()) {
                    Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                    int idx = 0;
                    std::string line;
                    while (std::getline(file, line)) {
                        if (!line.empty() && line.back() == '\r') line.pop_back();
                        result->set(std::to_string(idx++), makeStringValue(line));
                    }
                    result->set("__len__", Value(idx));
                    return Value((Collectable*)result);
                }
            }
            return NONE_VALUE;
        }
        if (name == "file_writelines" || name == "writelines") {
            // Write list of lines to file
            if (args.size() >= 2) {
                std::string path = getStringValue(args[0]);
                std::ofstream file(path, std::ios::binary);
                if (file.is_open() && args[1].isCollectable()) {
                    for (auto& v : nyos::list_items(args[1])) file << getStringValue(v) << "\n";
                    return Value(true);
                }
            }
            return Value(false);
        }
        if (name == "file_append" || name == "append_file") {
            // Append string to file
            if (args.size() >= 2) {
                std::ofstream file(getStringValue(args[0]), std::ios::binary | std::ios::app);
                if (file.is_open()) {
                    file << getStringValue(args[1]);
                    return Value(true);
                }
            }
            return Value(false);
        }
        if (name == "file_size") {
            // int64: a 3 GB file used to read -1073741824.
            if (args.size() >= 1) {
                struct stat st;
                if (stat(getStringValue(args[0]).c_str(), &st) == 0)
                    return nyos::make_int((long long)st.st_size);
            }
            return Value(-1);
        }
        // file_mtime(path) -> last modification time in milliseconds since the
        // epoch, or -1 when the path does not exist. On a directory it changes
        // whenever an entry is created, removed or renamed, which is what lets
        // the IDE watch a workspace by comparing one integer per folder.
        if (name == "file_mtime") {
            if (!args.empty()) {
                std::string path = getStringValue(args[0]);
                struct stat st;
                if (stat(path.c_str(), &st) == 0) {
#if defined(__APPLE__)
                    long long ms = (long long)st.st_mtimespec.tv_sec * 1000 + st.st_mtimespec.tv_nsec / 1000000;
#elif defined(_WIN32)
                    double t = (double)st.st_mtime;
                    nyos::precise_time(path, 'm', t);         // _stat has whole seconds
                    long long ms = (long long)(t * 1000.0);
#else
                    long long ms = (long long)st.st_mtim.tv_sec * 1000 + st.st_mtim.tv_nsec / 1000000;
#endif
                    return Value(bigint(ms));
                }
            }
            return Value(-1);
        }
        if (name == "print_to" || name == "fprint") {
            // Print to file: print_to(path, data)
            if (args.size() >= 2) {
                std::ofstream file(getStringValue(args[0]), std::ios::binary | std::ios::app);
                if (file.is_open()) {
                    file << getStringValue(args[1]) << "\n";
                    return Value(true);
                }
            }
            return Value(false);
        }
        if (name == "eprint" || name == "print_err") {
            // Print to stderr
            for (size_t i = 0; i < args.size(); i++) {
                if (i > 0) std::cerr << " ";
                if (args[i].type == ValueType::USERDATA)
                    std::cerr << getStringValue(args[i]);
                else
                    std::cerr << args[i].toString();
            }
            std::cerr << std::endl;
            return NONE_VALUE;
        }
        // ── sys.stdin / sys.stdout / sys.stderr (round 77) ──────────────
        // The prelude's _NyStdStream objects sit on these: text goes through
        // the same std::cout / std::cerr as print, so the two interleave in
        // order.
        if (name == "stream_write") {
            // stream_write(fd, text): writes text as is; the characters written
            long long fd = args.size() > 0 ? nyos::to_int(args[0], 1) : 1;
            std::string s = args.size() > 1 ? getStringValue(args[1]) : std::string();
            if (fd == 2) { std::cerr << s; std::cerr.flush(); }
            else std::cout << s;
            long long chars = 0;
            for (unsigned char c : s) if ((c & 0xC0) != 0x80) chars++;
            return Value((int64_t)chars);
        }
        if (name == "stream_flush") {
            long long fd = args.size() > 0 ? nyos::to_int(args[0], 1) : 1;
            if (fd == 2) { std::cerr.flush(); fflush(stderr); }
            else { std::cout.flush(); fflush(stdout); }
            return NONE_VALUE;
        }
        if (name == "stream_isatty") {
            long long fd = args.size() > 0 ? nyos::to_int(args[0], 1) : 1;
#ifdef _WIN32
            return Value(_isatty((int)fd) != 0);
#else
            return Value(isatty((int)fd) != 0);
#endif
        }
        if (name == "stream_readline") {
            // one line of stdin with its "\n" ("" at the end of input; the
            // last line has none when the input does not end with one)
            std::string line;
            bool ok;
            try { ok = nyconc::read_stdin_line(line); }
            catch (nyconc::NyError& err) {
                if (!err.raw.empty()) throw std::string(err.raw);
                throw std::string("__exc__:" + err.type + ":" + err.msg);
            }
            if (!ok) return makeStringValue("");
            if (!std::cin.eof()) line += "\n";
            return makeStringValue(line);
        }
        if (name == "stream_read") {
            // stream_read(size=-1): the rest of stdin, or up to size bytes
            long long size = args.size() > 0 ? nyos::to_int(args[0], -1) : -1;
            std::string out;
            if (size < 0) {
                std::string line;
                while (true) {
                    bool ok;
                    try { ok = nyconc::read_stdin_line(line); }
                    catch (nyconc::NyError& err) {
                        if (!err.raw.empty()) throw std::string(err.raw);
                        throw std::string("__exc__:" + err.type + ":" + err.msg);
                    }
                    if (!ok) break;
                    out += line;
                    if (std::cin.eof()) break;
                    out += "\n";
                }
            } else if (size > 0) {
                std::vector<char> buf((size_t)size);
                std::streamsize got;
                {
                    nyconc::GilRelease rel;
                    std::cin.read(buf.data(), (std::streamsize)size);
                    got = std::cin.gcount();
                }
                std::cin.clear();
                out.assign(buf.data(), (size_t)got);
            }
            return makeStringValue(out);
        }
        if (name == "flush") {
            std::cout << std::flush;
            fflush(stdout);
            return NONE_VALUE;
        }

    return UNDEFINED_VALUE;  // not handled by this module
}

#pragma GCC diagnostic pop
