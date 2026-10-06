// NyExcTypes.hpp - the builtin exception hierarchy, shared by both engines.
//
// Both the interpreter and the VM used to treat every builtin exception name
// as unrelated to every other: `except ArithmeticError` never caught a
// ZeroDivisionError, `except LookupError` never caught a KeyError, and only
// the literal names Exception/BaseException/Error acted as catch-alls. This
// is the one table both consult, following Python's own hierarchy.
#pragma once
#include <cerrno>
#include <cstdint>
#include <cstdio>
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
        {"StopAsyncIteration", "Exception"},
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
        // ssl's (round 77, src/builtins/tls.cpp)
        {"SSLError", "OSError"},
        {"SSLCertVerificationError", "SSLError"},
        {"SSLEOFError", "SSLError"},
        {"SSLZeroReturnError", "SSLError"},
        {"SSLWantReadError", "SSLError"},
        {"SSLWantWriteError", "SSLError"},
        {"SSLSyscallError", "SSLError"},
        // The concurrency runtime's (src/NyConc.cpp).
        {"DeadlockError", "RuntimeError"},
        {"LockOrderError", "RuntimeError"},
        // A BaseException, as in Python 3.8+: `except Exception` does not
        // swallow a cancellation.
        {"CancelledError", "BaseException"},
        {"ChannelClosedError", "Exception"},
        // weakref.proxy's error and the warning categories (round 77,
        // lib/weakref.ny, lib/warnings.ny): Python's builtins.
        {"ReferenceError", "Exception"},
        {"Warning", "Exception"},
        {"UserWarning", "Warning"},
        {"DeprecationWarning", "Warning"},
        {"PendingDeprecationWarning", "Warning"},
        {"SyntaxWarning", "Warning"},
        {"RuntimeWarning", "Warning"},
        {"FutureWarning", "Warning"},
        {"ImportWarning", "Warning"},
        {"UnicodeWarning", "Warning"},
        {"BytesWarning", "Warning"},
        {"ResourceWarning", "Warning"},
        {"EncodingWarning", "Warning"},
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
        "StopIteration", "StopAsyncIteration", "MemoryError", "EOFError", "EnvironmentError",
        "SSLError", "SSLCertVerificationError", "SSLEOFError", "SSLZeroReturnError",
        "SSLWantReadError", "SSLWantWriteError", "SSLSyscallError",
        "IsADirectoryError", "NotADirectoryError", "InterruptedError",
        "ChildProcessError", "ProcessLookupError", "BlockingIOError",
        "BrokenPipeError", "ConnectionRefusedError", "ConnectionResetError",
        "ConnectionAbortedError", "gaierror", "herror",
        "DeadlockError", "LockOrderError", "CancelledError", "ChannelClosedError",
        "ReferenceError", "Warning", "UserWarning", "DeprecationWarning",
        "PendingDeprecationWarning", "SyntaxWarning", "RuntimeWarning", "FutureWarning",
        "ImportWarning", "UnicodeWarning", "BytesWarning", "ResourceWarning", "EncodingWarning",
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

// ── What str(e) is made from for the exceptions with fields (round 77) ──────
// Both engines keep an exception's fields as attributes (errno, strerror,
// filename, filename2 of an OSError; encoding, object, start, end, reason of
// the Unicode errors) and make str(e) from them as CPython's
// Objects/exceptions.c does; these are the pieces they share.
// SyntaxError(msg, (filename, lineno, offset, text[, end_lineno,
// end_offset])) and ImportError(msg) keep `msg` as CPython's do.
enum NyExcKind { NYX_PLAIN = 0, NYX_KEY = 1, NYX_OS = 2, NYX_UDECODE = 3, NYX_UENCODE = 4, NYX_UTRANSLATE = 5,
                 NYX_SYNTAX = 6, NYX_IMPORT = 7 };
inline bool ny_exc_kind_unicode(int k) { return k == NYX_UDECODE || k == NYX_UENCODE || k == NYX_UTRANSLATE; }
// The kind of exception class `derives(base)` describes (the most specific
// base that has fields).
template <typename DerivesFn>
inline int ny_exc_kind(DerivesFn derives) {
    if (derives("KeyError")) return NYX_KEY;
    if (derives("OSError")) return NYX_OS;
    if (derives("UnicodeDecodeError")) return NYX_UDECODE;
    if (derives("UnicodeEncodeError")) return NYX_UENCODE;
    if (derives("UnicodeTranslateError")) return NYX_UTRANSLATE;
    if (derives("SyntaxError")) return NYX_SYNTAX;
    if (derives("ImportError")) return NYX_IMPORT;
    return NYX_PLAIN;
}
// The fields SyntaxError(msg, details) sets from details, in order.
inline const char* const* ny_syntax_fields() {
    static const char* const f[] = {"filename", "lineno", "offset", "text", "end_lineno", "end_offset"};
    return f;
}
// str(SyntaxError): "msg (file.py, line 3)" - the file's base name - or
// with what of the two it has (CPython's SyntaxError_str).
inline std::string ny_syntax_message(const std::string& msg, bool has_file, const std::string& file,
                                     bool has_line, long long line) {
    if (!has_file && !has_line) return msg;
    std::string base = file;
    size_t cut = base.find_last_of("/\\");
    if (cut != std::string::npos) base = base.substr(cut + 1);
    if (has_file && has_line) return msg + " (" + base + ", line " + std::to_string(line) + ")";
    if (has_file) return msg + " (" + base + ")";
    return msg + " (line " + std::to_string(line) + ")";
}

// The OSError subclass OSError(errno, ...) makes for an errno (CPython's
// errnomap), "" when there is none (it stays OSError).
inline const char* ny_errno_exc_class(long e) {
#ifdef EAGAIN
    if (e == EAGAIN) return "BlockingIOError";
#endif
#ifdef EWOULDBLOCK
    if (e == EWOULDBLOCK) return "BlockingIOError";
#endif
#ifdef EALREADY
    if (e == EALREADY) return "BlockingIOError";
#endif
#ifdef EINPROGRESS
    if (e == EINPROGRESS) return "BlockingIOError";
#endif
#ifdef ECHILD
    if (e == ECHILD) return "ChildProcessError";
#endif
#ifdef EPIPE
    if (e == EPIPE) return "BrokenPipeError";
#endif
#ifdef ESHUTDOWN
    if (e == ESHUTDOWN) return "BrokenPipeError";
#endif
#ifdef ECONNABORTED
    if (e == ECONNABORTED) return "ConnectionAbortedError";
#endif
#ifdef ECONNREFUSED
    if (e == ECONNREFUSED) return "ConnectionRefusedError";
#endif
#ifdef ECONNRESET
    if (e == ECONNRESET) return "ConnectionResetError";
#endif
#ifdef EEXIST
    if (e == EEXIST) return "FileExistsError";
#endif
#ifdef ENOENT
    if (e == ENOENT) return "FileNotFoundError";
#endif
#ifdef EISDIR
    if (e == EISDIR) return "IsADirectoryError";
#endif
#ifdef ENOTDIR
    if (e == ENOTDIR) return "NotADirectoryError";
#endif
#ifdef EINTR
    if (e == EINTR) return "InterruptedError";
#endif
#ifdef EACCES
    if (e == EACCES) return "PermissionError";
#endif
#ifdef EPERM
    if (e == EPERM) return "PermissionError";
#endif
#ifdef ESRCH
    if (e == ESRCH) return "ProcessLookupError";
#endif
#ifdef ETIMEDOUT
    if (e == ETIMEDOUT) return "TimeoutError";
#endif
    return "";
}

inline void ny_u8_append(uint32_t cp, std::string& out) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}
// A Python string literal at s[i] ('...' or "...", the escapes repr()
// writes): its text in `out` and i moved past it; false when there is none.
inline bool ny_unquote_py(const std::string& s, size_t& i, std::string& out) {
    if (i >= s.size() || (s[i] != '\'' && s[i] != '"')) return false;
    char q = s[i];
    std::string r;
    size_t j = i + 1;
    auto hexv = [&](size_t at, int n, uint32_t& v) {
        v = 0;
        if (at + (size_t)n > s.size()) return false;
        for (int k = 0; k < n; k++) {
            char c = s[at + (size_t)k];
            int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (d < 0) return false;
            v = v * 16 + (uint32_t)d;
        }
        return true;
    };
    while (j < s.size()) {
        char c = s[j];
        if (c == q) { out = r; i = j + 1; return true; }
        if (c != '\\') { r += c; j++; continue; }
        if (j + 1 >= s.size()) return false;
        char e = s[j + 1];
        uint32_t v = 0;
        switch (e) {
            case '\\': r += '\\'; j += 2; break;
            case '\'': r += '\''; j += 2; break;
            case '"': r += '"'; j += 2; break;
            case 'n': r += '\n'; j += 2; break;
            case 'r': r += '\r'; j += 2; break;
            case 't': r += '\t'; j += 2; break;
            case 'a': r += '\a'; j += 2; break;
            case 'b': r += '\b'; j += 2; break;
            case 'f': r += '\f'; j += 2; break;
            case 'v': r += '\v'; j += 2; break;
            case '0': r += '\0'; j += 2; break;
            case 'x': if (!hexv(j + 2, 2, v)) return false; ny_u8_append(v, r); j += 4; break;
            case 'u': if (!hexv(j + 2, 4, v)) return false; ny_u8_append(v, r); j += 6; break;
            case 'U': if (!hexv(j + 2, 8, v)) return false; ny_u8_append(v, r); j += 10; break;
            default: r += '\\'; r += e; j += 2; break;
        }
    }
    return false;
}

// "[Errno 2] No such file or directory: 'a' -> 'b'" - how the native OS
// layer words an OSError (the names as repr() writes them) - back into its
// fields, so the object an except clause binds has errno, strerror and
// filename (filename2). False when the message is not of that form.
struct NyErrnoParts {
    long err = 0;
    std::string strerror{}, f1{}, f2{};
    bool has_f1 = false, has_f2 = false;
};
inline bool ny_parse_errno_message(const std::string& m, NyErrnoParts& p) {
    if (m.compare(0, 7, "[Errno ") != 0) return false;
    size_t i = 7;
    bool neg = i < m.size() && m[i] == '-';
    if (neg) i++;
    size_t d0 = i;
    while (i < m.size() && m[i] >= '0' && m[i] <= '9') i++;
    if (i == d0 || i - d0 > 9 || i + 1 >= m.size() || m[i] != ']' || m[i + 1] != ' ') return false;
    p.err = std::stol(m.substr(d0, i - d0)) * (neg ? -1 : 1);
    size_t rest = i + 2;
    for (size_t c = m.find(": ", rest); c != std::string::npos; c = m.find(": ", c + 1)) {
        size_t j = c + 2;
        std::string a, b;
        if (!ny_unquote_py(m, j, a)) continue;
        if (j == m.size()) {
            p.strerror = m.substr(rest, c - rest); p.f1 = a; p.has_f1 = true;
            return true;
        }
        if (m.compare(j, 4, " -> ") == 0) {
            size_t k = j + 4;
            if (ny_unquote_py(m, k, b) && k == m.size()) {
                p.strerror = m.substr(rest, c - rest); p.f1 = a; p.has_f1 = true; p.f2 = b; p.has_f2 = true;
                return true;
            }
        }
    }
    p.strerror = m.substr(rest);
    return true;
}

// '\xe9', '€', '\U0001f600': a character as the Unicode errors show it.
inline std::string ny_unicode_char_escape(uint32_t cp) {
    char buf[16];
    if (cp <= 0xFF) std::snprintf(buf, sizeof buf, "\\x%02x", (unsigned)cp);
    else if (cp <= 0xFFFF) std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned)cp);
    else std::snprintf(buf, sizeof buf, "\\U%08x", (unsigned)cp);
    return buf;
}
// str(UnicodeDecodeError / UnicodeEncodeError / UnicodeTranslateError):
// `one` is the byte (decode) or code point (encode, translate) at start
// when the range is that one item inside the object, -1 otherwise.
inline std::string ny_unicode_error_message(int kind, const std::string& encoding, long long one,
                                            long long start, long long end, const std::string& reason) {
    std::string pos = std::to_string(start), rng = std::to_string(start) + "-" + std::to_string(end - 1);
    if (kind == NYX_UDECODE) {
        if (one >= 0) {
            char buf[8];
            std::snprintf(buf, sizeof buf, "0x%02x", (unsigned)(one & 0xFF));
            return "'" + encoding + "' codec can't decode byte " + buf + " in position " + pos + ": " + reason;
        }
        return "'" + encoding + "' codec can't decode bytes in position " + rng + ": " + reason;
    }
    std::string head = kind == NYX_UENCODE ? "'" + encoding + "' codec can't encode" : std::string("can't translate");
    if (one >= 0) return head + " character '" + ny_unicode_char_escape((uint32_t)one) + "' in position " + pos + ": " + reason;
    return head + " characters in position " + rng + ": " + reason;
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
