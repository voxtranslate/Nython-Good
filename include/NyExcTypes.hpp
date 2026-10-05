// NyExcTypes.hpp - the builtin exception hierarchy, shared by both engines.
//
// Both the interpreter and the VM used to treat every builtin exception name
// as unrelated to every other: `except ArithmeticError` never caught a
// ZeroDivisionError, `except LookupError` never caught a KeyError, and only
// the literal names Exception/BaseException/Error acted as catch-alls. This
// is the one table both consult, following Python's own hierarchy.
#pragma once
#include <string>
#include <unordered_map>
#include <vector>

namespace nython {

// Parent of a builtin exception class, "" for BaseException, or nullptr when
// the name is not a builtin exception class at all.
inline const char* ny_builtin_exc_parent(const std::string& name) {
    static const std::unordered_map<std::string, const char*> parents = {
        {"BaseException", ""},
        {"Exception", "BaseException"},
        {"SystemExit", "BaseException"},
        {"KeyboardInterrupt", "BaseException"},
        {"GeneratorExit", "BaseException"},
        {"Error", "Exception"},              // Nython's own generic name
        {"ArithmeticError", "Exception"},
        {"ZeroDivisionError", "ArithmeticError"},
        {"OverflowError", "ArithmeticError"},
        {"FloatingPointError", "ArithmeticError"},
        {"LookupError", "Exception"},
        {"KeyError", "LookupError"},
        {"IndexError", "LookupError"},
        {"ValueError", "Exception"},
        {"UnicodeError", "ValueError"},
        {"UnicodeDecodeError", "UnicodeError"},
        {"UnicodeEncodeError", "UnicodeError"},
        {"UnicodeTranslateError", "UnicodeError"},
        {"TypeError", "Exception"},
        {"AttributeError", "Exception"},
        {"NameError", "Exception"},
        {"UnboundLocalError", "NameError"},
        {"RuntimeError", "Exception"},
        {"NotImplementedError", "RuntimeError"},
        {"RecursionError", "RuntimeError"},
        {"OSError", "Exception"},
        {"IOError", "OSError"},
        {"FileNotFoundError", "OSError"},
        {"FileExistsError", "OSError"},
        {"PermissionError", "OSError"},
        {"TimeoutError", "OSError"},
        {"ConnectionError", "OSError"},
        {"ImportError", "Exception"},
        {"ModuleNotFoundError", "ImportError"},
        {"SyntaxError", "Exception"},
        {"AssertionError", "Exception"},
        {"StopIteration", "Exception"},
        {"MemoryError", "Exception"},
        {"EOFError", "Exception"},
        // The OS layer's typed errors (include/builtins/os.hpp raises them).
        {"EnvironmentError", "OSError"},
        {"IsADirectoryError", "OSError"},
        {"NotADirectoryError", "OSError"},
        {"InterruptedError", "OSError"},
        {"ChildProcessError", "OSError"},
        {"ProcessLookupError", "OSError"},
        {"BlockingIOError", "OSError"},
        {"BrokenPipeError", "ConnectionError"},
        {"ConnectionRefusedError", "ConnectionError"},
        {"ConnectionResetError", "ConnectionError"},
        {"ConnectionAbortedError", "ConnectionError"},
        // socket.gaierror / socket.herror (round 77, the network layer)
        {"gaierror", "OSError"},
        {"herror", "OSError"},
        // The concurrency runtime's (src/NyConc.cpp).
        {"DeadlockError", "RuntimeError"},
        {"LockOrderError", "RuntimeError"},
        {"CancelledError", "Exception"},
        {"ChannelClosedError", "Exception"},
    };
    auto it = parents.find(name);
    return it == parents.end() ? nullptr : it->second;
}

inline bool ny_is_builtin_exc(const std::string& name) {
    return ny_builtin_exc_parent(name) != nullptr;
}

// True when builtin exception `name` is `want` or derives from it.
inline bool ny_builtin_exc_is(const std::string& name, const std::string& want) {
    std::string cur = name;
    for (int guard = 0; guard < 16 && !cur.empty(); guard++) {
        if (cur == want) return true;
        const char* p = ny_builtin_exc_parent(cur);
        if (!p) return false;
        cur = p;
    }
    return false;
}

// Every builtin exception class name, parents before children.
inline const std::vector<std::string>& ny_builtin_exc_names() {
    static const std::vector<std::string> names = {
        "BaseException", "Exception", "SystemExit", "KeyboardInterrupt",
        "GeneratorExit", "Error", "ArithmeticError", "ZeroDivisionError",
        "OverflowError", "FloatingPointError", "LookupError", "KeyError",
        "IndexError", "ValueError", "UnicodeError", "UnicodeDecodeError",
        "UnicodeEncodeError", "UnicodeTranslateError", "TypeError",
        "AttributeError", "NameError", "UnboundLocalError", "RuntimeError",
        "NotImplementedError", "RecursionError", "OSError", "IOError",
        "FileNotFoundError", "FileExistsError", "PermissionError",
        "TimeoutError", "ConnectionError", "ImportError",
        "ModuleNotFoundError", "SyntaxError", "AssertionError",
        "StopIteration", "MemoryError", "EOFError", "EnvironmentError",
        "IsADirectoryError", "NotADirectoryError", "InterruptedError",
        "ChildProcessError", "ProcessLookupError", "BlockingIOError",
        "BrokenPipeError", "ConnectionRefusedError", "ConnectionResetError",
        "ConnectionAbortedError", "gaierror", "herror",
        "DeadlockError", "LockOrderError", "CancelledError", "ChannelClosedError",
    };
    return names;
}

// Splits "Type: message" when Type is a builtin exception class name - the
// form runtime errors are reported in on the VM - and "__exc__:Type:message",
// the interpreter's tagged form. Returns false for anything else.
inline bool ny_split_exc_message(const std::string& m, std::string& type, std::string& msg) {
    if (m.size() > 8 && m.compare(0, 8, "__exc__:") == 0) {
        size_t c = m.find(':', 8);
        type = m.substr(8, c == std::string::npos ? std::string::npos : c - 8);
        msg = c == std::string::npos ? std::string() : m.substr(c + 1);
        return !type.empty();
    }
    size_t c = m.find(": ");
    if (c == std::string::npos || c == 0 || c > 40) return false;
    std::string t = m.substr(0, c);
    if (!ny_is_builtin_exc(t)) return false;
    type = t;
    msg = m.substr(c + 2);
    return true;
}

// The TypeError message for a call that does not fit a function's
// parameters, in Python's words. `missing`: required parameters nothing
// supplied; min_pos/max_pos: how many positional arguments it takes (max_pos
// < 0 for *args); given: how many were passed. "" when the call fits.
inline std::string ny_arity_error(const std::string& fname, const std::vector<std::string>& missing,
                                  size_t min_pos, long max_pos, size_t given) {
    bool too_many = max_pos >= 0 && given > (size_t)max_pos;
    if (!too_many && missing.empty()) return std::string();   // the call fits: no strings built
    std::string f = (fname.empty() ? std::string("<lambda>") : fname) + "()";
    if (max_pos >= 0 && given > (size_t)max_pos) {
        std::string takes = min_pos == (size_t)max_pos ? std::to_string(max_pos)
                          : "from " + std::to_string(min_pos) + " to " + std::to_string(max_pos);
        return f + " takes " + takes + " positional argument" + (max_pos == 1 && min_pos == 1 ? "" : "s")
             + " but " + std::to_string(given) + (given == 1 ? " was" : " were") + " given";
    }
    if (!missing.empty()) {
        std::string names;
        for (size_t i = 0; i < missing.size(); i++) {
            if (i) names += missing.size() == 2 ? " and " : (i + 1 == missing.size() ? ", and " : ", ");
            names += "'" + missing[i] + "'";
        }
        return f + " missing " + std::to_string(missing.size()) + " required positional argument"
             + (missing.size() == 1 ? "" : "s") + ": " + names;
    }
    return "";
}

} // namespace nython
