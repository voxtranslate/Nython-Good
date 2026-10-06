#pragma once
// NyRuntime.hpp - runtime facts and exception conventions shared by both
// engines (the tree-walking interpreter and the bytecode VM).
//
//  * the command line a script was started with (sys.argv) and its path
//    (__file__), filled in by main.cpp before the program runs;
//  * the builtin exception hierarchy, so `except OSError` catches a
//    FileNotFoundError on both engines;
//  * the string form native code raises exceptions in
//    ("__exc__:TypeName:message") and how to take one apart;
//  * whether the name in `except Name:` is a type or a variable.

#include <string>
#include <vector>
#include <unordered_set>
#include <exception>
#include <stdexcept>
#include <new>
#include <ios>
#include <cctype>

#include <cstdlib>
#include <cstdio>

namespace nyrt {

// ── Command line ────────────────────────────────────────────────────────────
// argv()[0] is the script path; the rest are the arguments after it.
inline std::vector<std::string>& argv() {
    static std::vector<std::string> a;
    return a;
}
inline std::string& script_path() {
    static std::string p;
    return p;
}
// Absolute path of the running interpreter binary (sys.executable).
inline std::string& executable_path() {
    static std::string p;
    return p;
}
// Where `import name` also looks for name.ny, after the importing file's
// directory and the working directory (round 77): every directory of
// NYTHONPATH (':'-separated, ';' on Windows), then the standard library
// beside the interpreter - <exe dir>/lib and <exe dir>/../lib (the build
// directory sits in the project), so a program anywhere finds `import
// socket`. Each entry ends with a separator.
inline std::vector<std::string> library_dirs() {
    std::vector<std::string> out;
    auto add = [&](std::string d) {
        if (d.empty()) return;
        if (d.back() != '/' && d.back() != '\\') d += '/';
        for (auto& o : out) if (o == d) return;
        out.push_back(d);
    };
    if (const char* np = std::getenv("NYTHONPATH")) {
#ifdef _WIN32
        const char sep = ';';
#else
        const char sep = ':';
#endif
        std::string all = np;
        size_t a = 0;
        while (a <= all.size()) {
            size_t b = all.find(sep, a);
            if (b == std::string::npos) b = all.size();
            add(all.substr(a, b - a));
            a = b + 1;
        }
    }
    std::string exe = executable_path();
    size_t cut = exe.find_last_of("/\\");
    if (cut != std::string::npos) {
        std::string dir = exe.substr(0, cut + 1);
        add(dir + "lib");
        add(dir + "../lib");
    }
    return out;
}

// The exit status for an uncaught SystemExit whose message (str(e)) is
// `msg`: "" or "None" -> 0, an integer -> it, anything else is printed on
// stderr -> 1 (as Python).
inline int system_exit_status(const std::string& msg) {
    if (msg.empty() || msg == "None" || msg == "none") return 0;
    size_t i = (msg[0] == '-' || msg[0] == '+') ? 1 : 0;
    bool digits = i < msg.size();
    for (size_t k = i; k < msg.size(); k++) if (msg[k] < '0' || msg[k] > '9') { digits = false; break; }
    if (digits && msg.size() < 10) return std::atoi(msg.c_str());
    std::fprintf(stderr, "%s\n", msg.c_str());
    return 1;
}

// -W options, in order (round 77): sys.warnoptions, which lib/warnings.ny
// processes when it is imported, as Python does.
inline std::vector<std::string>& warn_options() { static std::vector<std::string> v; return v; }

inline void set_command_line(const std::string& script, int argc, char** args, int first_arg) {
    script_path() = script;
    argv().clear();
    argv().push_back(script);
    for (int i = first_arg; i < argc; i++) argv().push_back(args[i] ? args[i] : "");
}

// ── Classes made by a class statement run again (round 77) ───────────────────
// Each run of a class statement makes a new class; a re-run is registered as
// "Name#n" on both engines (classes are keyed by name). What is shown -
// type(x), __name__, reprs, messages - is Name.
inline std::string shown_class_name(const std::string& n) {
    size_t h = n.rfind('#');
    if (h == std::string::npos || h == 0 || h + 1 >= n.size()) return n;
    for (size_t i = h + 1; i < n.size(); i++) if (n[i] < '0' || n[i] > '9') return n;
    return n.substr(0, h);
}

// A module's class is keyed "module.Class" (round 77): its own name, as
// __name__ and a metaclass's `name` argument give it.
inline std::string bare_class_name(const std::string& n) {
    size_t dot = n.rfind('.');
    return dot == std::string::npos ? n : n.substr(dot + 1);
}

// The parser's decorator temporaries (`__decN__ = D` before a decorated def,
// src/Parser.cpp): a class body binds them, but they are no part of the
// class's namespace - C.__dict__ and the namespace a metaclass gets leave
// them out, on both engines (round 77).
inline bool is_decorator_temp(const std::string& n) {
    if (n.size() < 8 || n.compare(0, 5, "__dec") != 0 || n.compare(n.size() - 2, 2, "__") != 0) return false;
    for (size_t i = 5; i + 2 < n.size(); i++) if (n[i] < '0' || n[i] > '9') return false;
    return true;
}
// A class body's binding a metaclass's __prepare__ mapping must not see
// (round 77): a decorator temporary, and the bindings the desugaring of
// `@D def f` makes before its last (`__decN__ = D; def f; f = __decN__(f)`:
// Python binds f once, decorated). `skip` counts the pending ones per body.
inline bool decorator_binding(const std::string& n, int& skip) {
    if (is_decorator_temp(n)) { ++skip; return true; }
    if (skip > 0) { --skip; return true; }
    return false;
}

// issubclass over the builtin types (round 77): a type derives from itself
// and from object, bool from int.
inline bool builtin_type_derives(const std::string& sub, const std::string& sup) {
    if (sub.empty() || sup.empty()) return false;
    return sub == sup || sup == "object" || (sub == "bool" && sup == "int");
}

// ── Classes deriving from builtin types (round 77) ───────────────────────────
// `class MyInt(int)`: an instance holds a value of the type, its payload, in
// the hidden field below (a "__" name, so a dict view of the fields - vars(),
// obj.__dict__ - leaves it out on both engines). Where the type stands in
// the class's MRO, both engines put the prelude's mirror class of the type
// (_NyB_int ...: its operators, protocol and methods over the payload).
inline const char* payload_field() { return "__ny_payload__"; }
// Fields the engines keep on an instance for themselves ("__ny_*": the
// payload, the owner of an instance-dict view, the view itself): never part
// of vars(obj) / obj.__dict__ / dir(obj).
inline bool hidden_field(const std::string& n) { return n.size() > 7 && n.compare(0, 5, "__ny_") == 0; }
// The mirror class of a builtin type that can be subclassed, nullptr otherwise.
inline const char* builtin_mirror(const std::string& t) {
    static const char* const names[][2] = {
        {"int", "_NyB_int"}, {"float", "_NyB_float"}, {"str", "_NyB_str"}, {"bytes", "_NyB_bytes"},
        {"bytearray", "_NyB_bytearray"}, {"list", "_NyB_list"}, {"dict", "_NyB_dict"},
        {"set", "_NyB_set"}, {"frozenset", "_NyB_frozenset"}, {"tuple", "_NyB_tuple"},
    };
    if (t.empty() || t.size() > 9) return nullptr;
    for (auto& n : names) if (t == n[0]) return n[1];
    return nullptr;
}
// The dunders the mirror classes define: reading one from a builtin type
// (int.__new__, dict.__setitem__, int.__repr__) loads the mirrors.
inline bool mirror_dunder(const std::string& a) {
    static const char* const names[] = {
        "__abs__", "__add__", "__and__", "__bool__", "__bytes__", "__ceil__", "__class_getitem__", "__complex__",
        "__contains__", "__delitem__", "__divmod__", "__eq__", "__float__", "__floor__", "__floordiv__", "__format__",
        "__ge__", "__getitem__", "__getnewargs__", "__gt__", "__hash__", "__iadd__", "__iand__", "__imul__", "__index__",
        "__init__", "__int__", "__invert__", "__ior__", "__isub__", "__iter__", "__ixor__", "__le__", "__len__",
        "__lshift__", "__lt__", "__mod__", "__mul__", "__ne__", "__neg__", "__new__", "__or__", "__pos__", "__pow__",
        "__radd__", "__rand__", "__rdivmod__", "__repr__", "__reversed__", "__rfloordiv__", "__rlshift__", "__rmod__",
        "__rmul__", "__ror__", "__round__", "__rpow__", "__rrshift__", "__rshift__", "__rsub__", "__rtruediv__",
        "__rxor__", "__setitem__", "__str__", "__sub__", "__truediv__", "__trunc__", "__xor__",
    };
    if (a.size() < 5 || a[0] != '_' || a[1] != '_') return false;
    for (const char* n : names) if (a == n) return true;
    return false;
}
// The builtin type a mirror class stands for ("" for any other class name).
inline std::string mirror_builtin(const std::string& cls) {
    if (cls.size() < 6 || cls.compare(0, 5, "_NyB_") != 0) return std::string();
    std::string t = cls.substr(5);
    return builtin_mirror(t) ? t : std::string();
}
// The builtins a payload instance reaches as itself: the ones that ask for
// its class, dunders or identity, or store it (every other builtin is given
// the payload - math_sqrt(Celsius(4.0)), os_path_join(Name("a")), int(...)).
inline bool payload_transparent(const std::string& n) {
    if (n.size() > 4 && n[0] == '_' && n[1] == 'n' && n[2] == 'y' && n[3] == '_') return true;   // _ny_* (the prelude's)
    static const char* const pre[] = {"thread_", "mutex_", "channel_", "queue_", "future_", "task_", "atomic_",
                                       "rwlock_", "cond_", "sem_", "barrier_", "latch_", "async_", "gc_", "pool_"};
    for (const char* p : pre) if (n.rfind(p, 0) == 0) return true;
    static const std::unordered_set<std::string> names = {
        "type", "typeof", "isinstance", "issubclass", "id", "hash", "repr", "str", "ascii", "format", "print",
        "println", "len", "iter", "next", "bool", "callable", "getattr", "setattr", "hasattr", "delattr", "vars",
        "dir", "super", "weakref", "min", "max", "help", "object", "property", "staticmethod", "classmethod",
        "display", "show", "__format_value__", "anext", "aiter", "reversed",
    };
    return names.count(n) > 0;
}

// ── Module namespaces over the flat builtins ─────────────────────────────────
// `import os` binds a namespace so Python-style code works: os.getcwd() is
// os_getcwd(), os.path.join() is os_path_join(). Given every builtin name,
// returns (member path, builtin name) pairs; "path.join" is a member of the
// nested os.path namespace.
inline std::vector<std::pair<std::string, std::string>>
module_members(const std::string& module, const std::vector<std::string>& builtin_names) {
    std::vector<std::pair<std::string, std::string>> out;
    if (module != "os") return out;
    for (auto& n : builtin_names) {
        if (n.rfind("os_path_", 0) == 0) out.push_back({"path." + n.substr(8), n});
        else if (n.rfind("os_", 0) == 0) out.push_back({n.substr(3), n});
    }
    return out;
}

// The builtin a member of a builtin used as a namespace names: time.sleep is
// time_sleep, time.time is time, time.monotonic is time_monotonic. `has`
// says whether a builtin exists. "" when there is none.
template <typename HasFn>
std::string builtin_member(const std::string& base, const std::string& member, HasFn has) {
    if (has(base + "_" + member)) return base + "_" + member;
    if (base == "time" && has(member)) return member;
    return "";
}

// ── Builtin exception hierarchy ─────────────────────────────────────────────
// Parent of a builtin exception type, "" for the root / unknown names.
inline std::string builtin_exc_parent(const std::string& t) {
    static const char* table[][2] = {
        {"Exception", "BaseException"},
        {"SystemExit", "BaseException"}, {"KeyboardInterrupt", "BaseException"},
        {"GeneratorExit", "BaseException"},
        {"Error", "Exception"},
        {"OSError", "Exception"}, {"IOError", "OSError"}, {"EnvironmentError", "OSError"},
        {"FileNotFoundError", "OSError"}, {"FileExistsError", "OSError"},
        {"PermissionError", "OSError"}, {"IsADirectoryError", "OSError"},
        {"NotADirectoryError", "OSError"}, {"TimeoutError", "OSError"},
        {"InterruptedError", "OSError"}, {"ChildProcessError", "OSError"},
        {"ProcessLookupError", "OSError"}, {"BlockingIOError", "OSError"},
        {"ConnectionError", "OSError"}, {"BrokenPipeError", "ConnectionError"},
        {"ConnectionRefusedError", "ConnectionError"}, {"ConnectionResetError", "ConnectionError"},
        {"ArithmeticError", "Exception"}, {"ZeroDivisionError", "ArithmeticError"},
        {"OverflowError", "ArithmeticError"}, {"FloatingPointError", "ArithmeticError"},
        {"LookupError", "Exception"}, {"IndexError", "LookupError"}, {"KeyError", "LookupError"},
        {"RuntimeError", "Exception"}, {"RecursionError", "RuntimeError"},
        {"NotImplementedError", "RuntimeError"},
        {"ValueError", "Exception"}, {"UnicodeError", "ValueError"},
        {"UnicodeDecodeError", "UnicodeError"}, {"UnicodeEncodeError", "UnicodeError"},
        {"UnicodeTranslateError", "UnicodeError"}, {"ConnectionAbortedError", "ConnectionError"},
        {"gaierror", "OSError"}, {"herror", "OSError"},
        {"TypeError", "Exception"}, {"NameError", "Exception"},
        {"AttributeError", "Exception"}, {"ImportError", "Exception"},
        {"ModuleNotFoundError", "ImportError"}, {"AssertionError", "Exception"},
        {"StopIteration", "Exception"}, {"MemoryError", "Exception"},
        {"StopAsyncIteration", "Exception"}, {"CancelledError", "BaseException"},
        {"SSLError", "OSError"}, {"SSLCertVerificationError", "SSLError"}, {"SSLEOFError", "SSLError"},
        {"SSLZeroReturnError", "SSLError"}, {"SSLWantReadError", "SSLError"},
        {"SSLWantWriteError", "SSLError"}, {"SSLSyscallError", "SSLError"},
        {"SyntaxError", "Exception"}, {"EOFError", "Exception"},
    };
    for (auto& row : table) if (t == row[0]) return row[1];
    return "";
}
inline bool is_builtin_exc(const std::string& t) {
    return t == "BaseException" || !builtin_exc_parent(t).empty();
}

// Does an exception of type `type` satisfy `except filter`? `user_parent`
// returns the parent of a user-defined class ("" when it is not one), so a
// class deriving from OSError is caught by `except OSError` and the other
// way round.
template <typename ParentFn>
bool exc_matches(const std::string& type, const std::string& filter, ParentFn user_parent) {
    if (filter.empty()) return true;
    if (filter == "BaseException") return true;
    // Anything that is not a system-exit style signal is an Exception; an
    // untyped raise (a plain string) is too.
    if (filter == "Exception" || filter == "Error") {
        return type != "SystemExit" && type != "KeyboardInterrupt" && type != "GeneratorExit" &&
               type != "CancelledError";
    }
    std::string cur = type;
    for (int depth = 0; depth < 32 && !cur.empty(); depth++) {
        if (cur == filter) return true;
        std::string up = user_parent(cur);
        if (up.empty()) up = builtin_exc_parent(cur);
        cur = up;
    }
    return false;
}

// `except Name:` with no `as` has always meant "catch everything and bind the
// message to Name" (`except e:`). A name that is clearly a type - a builtin
// exception, or anything Capitalised - is a type filter instead, as in Python.
inline bool except_name_is_type(const std::string& name) {
    if (name.empty()) return false;
    if (is_builtin_exc(name)) return true;
    return std::isupper(static_cast<unsigned char>(name[0])) != 0;
}

// ── Exception strings ───────────────────────────────────────────────────────
inline std::string make_exc(const std::string& type, const std::string& msg) {
    return "__exc__:" + type + ":" + msg;
}

// Split an exception string into type and message. Understands the tagged
// form "__exc__:Type:msg" and the "TypeError: msg" form the VM uses for its
// own errors. Anything else is an untyped error: type "" and the whole text.
inline void parse_exc(const std::string& s, std::string& type, std::string& msg) {
    type.clear(); msg = s;
    if (s.rfind("__exc__:", 0) == 0) {
        size_t c2 = s.find(':', 8);
        type = s.substr(8, c2 == std::string::npos ? std::string::npos : c2 - 8);
        msg = c2 == std::string::npos ? std::string() : s.substr(c2 + 1);
        return;
    }
    size_t colon = s.find(": ");
    if (colon != std::string::npos && colon > 0 && colon < 40) {
        std::string head = s.substr(0, colon);
        bool ident = std::isupper(static_cast<unsigned char>(head[0])) != 0;
        for (char c : head) if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_') ident = false;
        if (ident && (is_builtin_exc(head) || head.size() > 5)) {
            size_t e = head.size();
            bool looks = is_builtin_exc(head)
                || (e > 5 && (head.compare(e - 5, 5, "Error") == 0))
                || (e > 9 && (head.compare(e - 9, 9, "Exception") == 0));
            if (looks) { type = head; msg = s.substr(colon + 2); }
        }
    }
}

// The type of a C++ exception that escaped from native code.
inline std::string native_exc_type(const std::exception& e) {
    if (dynamic_cast<const std::ios_base::failure*>(&e)) return "OSError";
    if (dynamic_cast<const std::bad_alloc*>(&e)) return "MemoryError";
    if (dynamic_cast<const std::out_of_range*>(&e)) return "IndexError";
    if (dynamic_cast<const std::invalid_argument*>(&e)) return "ValueError";
    if (dynamic_cast<const std::overflow_error*>(&e)) return "OverflowError";
    return "RuntimeError";
}

// repr of a class, as Python shows it: <class 'int'> for a builtin type and
// the prelude's own classes, <class '__main__.A'> for a class of the program,
// <class 'mod.A'> for a module's (round 77; it was <class A>).
inline bool is_builtin_type_name(const std::string& n) {
    static const char* const names[] = {"int", "float", "str", "bool", "list", "dict", "tuple", "set", "frozenset",
                                        "bytes", "bytearray", "complex", "object", "type", "slice", "range"};
    for (const char* x : names) if (n == x) return true;
    return false;
}
inline std::string class_repr(const std::string& full) {
    std::string n = shown_class_name(full);
    if (is_builtin_type_name(n)) return "<class '" + n + "'>";
    if (n.find('.') == std::string::npos) n = "__main__." + n;
    return "<class '" + n + "'>";
}

// `from m import a as b`: ImportNode::names holds "a\x05b" (the parser);
// both engines bind it with this split - {name in the module, name bound}.
inline std::pair<std::string, std::string> import_name_alias(const std::string& n) {
    size_t p = n.find('\x05');
    if (p == std::string::npos) return {n, n};
    return {n.substr(0, p), n.substr(p + 1)};
}

// Standard module names a bare `import` binds to the Python module in
// lib/<name>.ny when there is one (round 77). They were acknowledgements of
// builtin groups - `import json` bound no `json`, so json.dumps was a
// NameError; the legacy flat builtins (json_encode, re_match, random_int,
// ...) stay registered regardless.
inline bool prefers_lib_module(const std::string& name) {
    static const char* const names[] = {"json", "re", "random", "datetime", "time",
                                        "io", "string", "threading", "struct", "math_lib"};
    for (const char* n : names) if (name == n) return true;
    return false;
}

// Builtins that take file-system paths: an argument with __fspath__ (a
// pathlib.Path, os.PathLike) reaches them as the string it returns, as
// Python's os functions and open() accept path-like objects (both engines:
// NythonExecutor::callBuiltin, and the VM's builtin bridge).
inline bool takes_paths(const std::string& n) {
    if (n.rfind("os_", 0) == 0 || n.rfind("file_", 0) == 0 || n.rfind("path_", 0) == 0 ||
        n.rfind("fs_", 0) == 0)
        return true;
    static const char* const names[] = {"open", "read_file", "write_file", "append_file", "read_bytes",
                                        "write_bytes", "read_text", "write_text", "load_text",
                                        "save_text", "append_text", "listdir", "list_dir", "glob",
                                        "fnmatch", "remove_file", "subprocess_run"};
    for (const char* x : names) if (n == x) return true;
    return false;
}

} // namespace nyrt
