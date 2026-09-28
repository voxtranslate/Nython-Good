#pragma once
// builtins/os.hpp
// Filesystem, paths, processes, environment and time.
// Part of the Nython builtin module system.
// Each dispatch_* function returns the result Value, or UNDEFINED_VALUE if
// the builtin name is not handled by this module (pass to next module).
//
// dispatch_os (src/builtins/os.cpp) handles files, paths and the environment
// and forwards to dispatch_os_time (os_time.cpp) and dispatch_os_proc
// (os_proc.cpp). The helpers below are shared by the three files and by
// io.cpp; they are only usable where NythonExecutor is a complete type.

#include "Value.hpp"
#include "Context.hpp"
#include <string>
#include <vector>
#include <map>
#include <utility>
#include <initializer_list>

struct NythonExecutor;   // forward declaration — full def in NythonExecutor.hpp

/// Dispatch builtins belonging to the Os module.
/// Returns UNDEFINED_VALUE when `name` is not handled here.
Value dispatch_os(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx);

/// Time builtins (time_*, sleep_ms, monotonic, ...).
Value dispatch_os_time(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx);

/// Process builtins (os_run, os_spawn, os_poll, ...).
Value dispatch_os_proc(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx);

namespace nyos {

// Raise a Nython exception of the given type ("FileNotFoundError", ...).
[[noreturn]] void raise(const std::string& type, const std::string& msg);
// Raise the exception matching errno `err` ("[Errno 2] No such file or
// directory: 'path'"), the way Python's OSError subclasses read.
[[noreturn]] void raise_errno(int err, const std::string& path, const std::string& path2 = "");
std::string errno_type(int err);

// Argument access. Keyword arguments reach a builtin as a trailing map (the
// VM's CALL_KW convention, which the interpreter now follows for the names
// in its kwmap_builtins set); Args takes that map off the end when every key
// in it is one of `names`, so a map passed positionally is left alone.
struct Args {
    NythonExecutor& E;
    std::vector<Value>& a;
    std::map<std::string, Value> kw;
    Args(NythonExecutor& e, std::vector<Value>& args, std::initializer_list<const char*> names);
    bool has(size_t pos, const char* name) const;
    Value get(size_t pos, const char* name) const;          // NONE when absent
    std::string str(size_t pos, const char* name, const std::string& dflt = "") const;
    double num(size_t pos, const char* name, double dflt) const;
    long long integer(size_t pos, const char* name, long long dflt) const;
    bool flag(size_t pos, const char* name, bool dflt) const;
};

double to_num(const Value& v, double dflt);
long long to_int(const Value& v, long long dflt);
Value make_int(long long v);
Value make_list(NythonExecutor& E, const std::vector<Value>& items);
Value make_str_list(NythonExecutor& E, const std::vector<std::string>& items);
Value make_map(NythonExecutor& E, const std::vector<std::pair<std::string, Value>>& items);
bool is_list(const Value& v);
bool is_map(const Value& v);
std::vector<Value> list_items(const Value& v);
std::vector<std::pair<std::string, Value>> map_items(const Value& v);

// Paths (pure string operations; see os.cpp for the exact rules).
std::string cwd();
std::string normpath(const std::string& p);
std::string abspath(const std::string& p);
std::string join(const std::string& a, const std::string& b);
bool isabs(const std::string& p);
std::pair<std::string, std::string> split(const std::string& p);
std::pair<std::string, std::string> splitext(const std::string& p);
bool fnmatch(const std::string& name, const std::string& pat);

// Modification/access/creation times at full precision on Windows, whose
// _stat gives whole seconds (a rewrite within the same second looked
// unchanged to file watchers). which: 'm', 'a' or 'c'. false when the path
// cannot be read; not used elsewhere, where struct stat is exact.
#ifdef _WIN32
inline bool precise_time(const std::string& path, char which, double& out) {
    int n = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    if (n <= 0) return false;
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &w[0], n);
    WIN32_FILE_ATTRIBUTE_DATA d;
    if (!GetFileAttributesExW(w.c_str(), GetFileExInfoStandard, &d)) return false;
    const FILETIME& ft = which == 'm' ? d.ftLastWriteTime : which == 'a' ? d.ftLastAccessTime : d.ftCreationTime;
    unsigned long long t = ((unsigned long long)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    out = (double)(t - 116444736000000000ULL) / 1e7;     // 100 ns ticks since 1601 -> s since 1970
    return true;
}
#endif

} // namespace nyos
