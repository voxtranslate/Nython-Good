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
#include <exception>
#include <stdexcept>
#include <new>
#include <ios>
#include <cctype>

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
inline void set_command_line(const std::string& script, int argc, char** args, int first_arg) {
    script_path() = script;
    argv().clear();
    argv().push_back(script);
    for (int i = first_arg; i < argc; i++) argv().push_back(args[i] ? args[i] : "");
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
        return type != "SystemExit" && type != "KeyboardInterrupt" && type != "GeneratorExit";
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

} // namespace nyrt
