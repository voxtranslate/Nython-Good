#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/os.cpp
// Filesystem, paths and the environment (os, os.path, shutil, tempfile,
// glob). Time lives in os_time.cpp and processes in os_proc.cpp; both are
// reached through dispatch_os.
//
// Conventions
//   * Every name that existed before keeps its old contract (return value on
//     failure) - the IDE and the libraries depend on them: os_remove/
//     os_rename/os_mkdir return bool, os_listdir returns [] for a missing
//     directory, read_file returns "" for a missing file, os_getenv returns
//     none (or the default) for an unset variable.
//   * The names added in round 74 behave like their Python counterparts and
//     RAISE on failure with a typed exception (FileNotFoundError,
//     PermissionError, IsADirectoryError, NotADirectoryError,
//     FileExistsError, OSError): os_stat/os_lstat, os_rmdir, os_rmtree,
//     os_makedirs, os_unlink, os_copy, os_copytree, os_move, os_chmod,
//     os_symlink, os_readlink, os_touch, os_chdir, os_mkstemp, os_mkdtemp,
//     os_disk_usage, os_path_getsize, os_path_getmtime.
//   * Keyword arguments arrive as a trailing map (see nyos::Args).
// ─────────────────────────────────────────────────────────────────────────────

// Platform compatibility (must come first)
#include "platform_compat.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cmath>
#include <chrono>
#include <thread>
#include <functional>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <ctime>

#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include "NyRuntime.hpp"

#ifndef _WIN32
#  include <sys/statvfs.h>
#  include <sys/utsname.h>
#  include <sys/time.h>
#  include <pwd.h>
#  include <utime.h>
extern char** environ;
#else
#  include <sys/utime.h>
#  include <fcntl.h>
#  include <io.h>
#  include <direct.h>
#endif

using namespace std;
using namespace nython;
using namespace nython::kernel;

namespace {
#ifdef _WIN32
inline bool is_sep(char c) { return c == '/' || c == '\\'; }
const char SEP = '\\';
#else
inline bool is_sep(char c) { return c == '/'; }
const char SEP = '/';
#endif
// basename/dirname/split have always accepted '\' as well as '/' on every
// platform (the interpreter's os_path_basename did); keep that.
inline bool is_any_sep(char c) { return c == '/' || c == '\\'; }
inline std::string sep_str() { return std::string(1, SEP); }
} // namespace

// ════════════════════════════════════════════════════════════════════════════
// Shared helpers (declared in builtins/os.hpp)
// ════════════════════════════════════════════════════════════════════════════
namespace nyos {

void raise(const std::string& type, const std::string& msg) {
    throw std::string(nyrt::make_exc(type, msg));
}

std::string errno_type(int err) {
    switch (err) {
        case ENOENT:  return "FileNotFoundError";
        case EEXIST:  return "FileExistsError";
        case EACCES:
        case EPERM:   return "PermissionError";
        case EISDIR:  return "IsADirectoryError";
        case ENOTDIR: return "NotADirectoryError";
        case EINTR:   return "InterruptedError";
        case ECHILD:  return "ChildProcessError";
        case ESRCH:   return "ProcessLookupError";
#ifdef ETIMEDOUT
        case ETIMEDOUT: return "TimeoutError";
#endif
        default:      return "OSError";
    }
}

void raise_errno(int err, const std::string& path, const std::string& path2) {
    std::string msg = "[Errno " + std::to_string(err) + "] " + std::strerror(err);
    if (!path.empty())  msg += ": '" + path + "'";
    if (!path2.empty()) msg += " -> '" + path2 + "'";
    raise(errno_type(err), msg);
}

static Container* as_container(const Value& v) {
    if (!v.isCollectable()) return nullptr;
    auto* c = dynamic_cast<Container*>(v.value.gc);
    return (c && c->container) ? c : nullptr;
}
bool is_list(const Value& v) {
    auto* c = as_container(v);
    return c && c->container->count("__len__");
}
bool is_map(const Value& v) {
    auto* c = as_container(v);
    return c && !c->container->count("__len__");
}
std::vector<Value> list_items(const Value& v) {
    std::vector<Value> out;
    auto* c = as_container(v);
    if (!c) return out;
    auto li = c->container->find("__len__");
    if (li == c->container->end()) return out;
    long long n = bigint_to_i64(li->second.value.i);
    for (long long i = 0; i < n; i++) {
        auto it = c->container->find(std::to_string(i));
        out.push_back(it == c->container->end() ? NONE_VALUE : it->second);
    }
    return out;
}
std::vector<std::pair<std::string, Value>> map_items(const Value& v) {
    std::vector<std::pair<std::string, Value>> out;
    auto* c = as_container(v);
    if (!c) return out;
    for (auto& kv : *c->container) {
        const std::string& k = kv.first;
        if (k.size() > 4 && k.rfind("__", 0) == 0 && k.compare(k.size() - 2, 2, "__") == 0) continue;
        out.push_back(kv);
    }
    return out;
}

double to_num(const Value& v, double dflt) {
    switch (v.type) {
        case ValueType::INTEGER: return (double)bigint_to_i64(v.value.i);
        case ValueType::DOUBLE:  return (double)v.value.d;
        case ValueType::BOOLEAN: return v.value.b ? 1.0 : 0.0;
        default: return dflt;
    }
}
long long to_int(const Value& v, long long dflt) {
    switch (v.type) {
        case ValueType::INTEGER: return bigint_to_i64(v.value.i);
        case ValueType::DOUBLE:  return (long long)v.value.d;
        case ValueType::BOOLEAN: return v.value.b ? 1 : 0;
        default: return dflt;
    }
}
Value make_int(long long v) { return Value(bigint(v)); }

Value make_list(NythonExecutor& E, const std::vector<Value>& items) {
    auto* o = new Object((Runnable*)E.runner, "list", Type::LIST);
    for (size_t i = 0; i < items.size(); i++) o->set(std::to_string(i), items[i]);
    o->set("__len__", Value((int)items.size()));
    return Value((Collectable*)o);
}
Value make_str_list(NythonExecutor& E, const std::vector<std::string>& items) {
    std::vector<Value> vs;
    vs.reserve(items.size());
    for (auto& s : items) vs.push_back(E.makeStringValue(s));
    return make_list(E, vs);
}
Value make_map(NythonExecutor& E, const std::vector<std::pair<std::string, Value>>& items) {
    auto* o = new Object((Runnable*)E.runner, "map", Type::MAP);
    for (auto& kv : items) o->set(kv.first, kv.second);
    return Value((Collectable*)o);
}

Args::Args(NythonExecutor& e, std::vector<Value>& args, std::initializer_list<const char*> names)
    : E(e), a(args), kw() {
    if (a.empty() || !is_map(a.back())) return;
    auto items = map_items(a.back());
    if (items.empty()) return;
    for (auto& kv : items) {
        bool known = false;
        for (const char* n : names) if (kv.first == n) { known = true; break; }
        if (!known) return;
    }
    for (auto& kv : items) kw[kv.first] = kv.second;
    a.pop_back();
}
bool Args::has(size_t pos, const char* name) const {
    if (name && kw.count(name)) return true;
    return pos < a.size() && a[pos].type != ValueType::NONE && a[pos].type != ValueType::UNDEFINED;
}
Value Args::get(size_t pos, const char* name) const {
    if (name) { auto it = kw.find(name); if (it != kw.end()) return it->second; }
    return pos < a.size() ? a[pos] : NONE_VALUE;
}
std::string Args::str(size_t pos, const char* name, const std::string& dflt) const {
    if (!has(pos, name)) return dflt;
    return E.getStringValue(get(pos, name));
}
double Args::num(size_t pos, const char* name, double dflt) const {
    return has(pos, name) ? to_num(get(pos, name), dflt) : dflt;
}
long long Args::integer(size_t pos, const char* name, long long dflt) const {
    return has(pos, name) ? to_int(get(pos, name), dflt) : dflt;
}
bool Args::flag(size_t pos, const char* name, bool dflt) const {
    return has(pos, name) ? E.isTruthy(get(pos, name)) : dflt;
}

// ── Paths ───────────────────────────────────────────────────────────────────
std::string cwd() {
    char buf[8192];
    if (::getcwd(buf, sizeof(buf))) return std::string(buf);
    return ".";
}

bool isabs(const std::string& p) {
    if (p.empty()) return false;
#ifdef _WIN32
    if (is_sep(p[0])) return true;
    return p.size() >= 3 && std::isalpha((unsigned char)p[0]) && p[1] == ':' && is_sep(p[2]);
#else
    return p[0] == '/';
#endif
}

std::string normpath(const std::string& p) {
    if (p.empty()) return ".";
    std::string prefix;
    size_t i = 0;
#ifdef _WIN32
    if (p.size() >= 2 && std::isalpha((unsigned char)p[0]) && p[1] == ':') { prefix = p.substr(0, 2); i = 2; }
#endif
    bool abs = i < p.size() && is_sep(p[i]);
    std::vector<std::string> parts;
    std::string cur;
    auto flush = [&]() {
        if (cur.empty() || cur == ".") { cur.clear(); return; }
        if (cur == "..") {
            if (!parts.empty() && parts.back() != "..") parts.pop_back();
            else if (!abs) parts.push_back("..");
        } else parts.push_back(cur);
        cur.clear();
    };
    for (; i < p.size(); i++) {
        if (is_sep(p[i])) flush();
        else cur += p[i];
    }
    flush();
    std::string out = prefix;
    if (abs) out += SEP;
    for (size_t k = 0; k < parts.size(); k++) {
        if (k) out += SEP;
        out += parts[k];
    }
    if (out.empty()) return ".";
    return out;
}

std::string abspath(const std::string& p) {
    if (isabs(p)) return normpath(p);
    return normpath(cwd() + SEP + p);
}

std::string join(const std::string& a, const std::string& b) {
    if (isabs(b)) return b;
    if (a.empty()) return b;
    if (is_any_sep(a.back())) return a + b;
    return a + SEP + b;
}

std::pair<std::string, std::string> split(const std::string& p) {
    size_t pos = std::string::npos;
    for (size_t i = p.size(); i-- > 0;) if (is_any_sep(p[i])) { pos = i; break; }
    if (pos == std::string::npos) return {"", p};
    std::string head = p.substr(0, pos + 1), tail = p.substr(pos + 1);
    // Strip trailing separators from head unless it is all separators ("/").
    size_t end = head.size();
    while (end > 0 && is_any_sep(head[end - 1])) end--;
    if (end > 0) head = head.substr(0, end);
    return {head, tail};
}

std::pair<std::string, std::string> splitext(const std::string& p) {
    size_t base = 0;
    for (size_t i = p.size(); i-- > 0;) if (is_any_sep(p[i])) { base = i + 1; break; }
    size_t dot = p.rfind('.');
    if (dot == std::string::npos || dot < base) return {p, ""};
    // Leading dots of the file name do not start an extension (".bashrc").
    bool only_dots = true;
    for (size_t i = base; i < dot; i++) if (p[i] != '.') { only_dots = false; break; }
    if (only_dots) return {p, ""};
    return {p.substr(0, dot), p.substr(dot)};
}

// fnmatch: * ? [seq] [!seq]. Case-sensitive; '/' is an ordinary character,
// as in Python's fnmatch (glob applies it one path component at a time).
static bool class_match(const std::string& pat, size_t& pi, char c) {
    size_t j = pi + 1;
    bool neg = false;
    if (j < pat.size() && (pat[j] == '!' || pat[j] == '^')) { neg = true; j++; }
    bool matched = false, first = true;
    while (j < pat.size() && (pat[j] != ']' || first)) {
        first = false;
        char lo = pat[j];
        if (j + 2 < pat.size() && pat[j + 1] == '-' && pat[j + 2] != ']') {
            if (c >= lo && c <= pat[j + 2]) matched = true;
            j += 3;
        } else {
            if (c == lo) matched = true;
            j++;
        }
    }
    if (j >= pat.size()) {           // no closing ']': a literal '['
        pi = pi + 1;
        return c == '[';
    }
    pi = j + 1;
    return matched != neg;
}
bool fnmatch(const std::string& s, const std::string& pat) {
    size_t si = 0, pi = 0, star_p = std::string::npos, star_s = 0;
    while (si < s.size()) {
        if (pi < pat.size() && pat[pi] == '*') { star_p = pi++; star_s = si; continue; }
        if (pi < pat.size()) {
            if (pat[pi] == '?') { pi++; si++; continue; }
            if (pat[pi] == '[') {
                size_t np = pi;
                if (class_match(pat, np, s[si])) { pi = np; si++; continue; }
            } else if (pat[pi] == s[si]) { pi++; si++; continue; }
        }
        if (star_p != std::string::npos) { pi = star_p + 1; si = ++star_s; continue; }
        return false;
    }
    while (pi < pat.size() && pat[pi] == '*') pi++;
    return pi == pat.size();
}

} // namespace nyos

// ════════════════════════════════════════════════════════════════════════════
// File-system internals
// ════════════════════════════════════════════════════════════════════════════
namespace {

using nyos::raise;
using nyos::raise_errno;

bool path_stat(const std::string& p, struct stat& st) { return ::stat(p.c_str(), &st) == 0; }
bool path_lstat(const std::string& p, struct stat& st) {
#ifdef _WIN32
    return ::stat(p.c_str(), &st) == 0;
#else
    return ::lstat(p.c_str(), &st) == 0;
#endif
}
bool is_dir(const std::string& p) { struct stat st; return path_stat(p, st) && S_ISDIR(st.st_mode); }
bool is_file(const std::string& p) { struct stat st; return path_stat(p, st) && S_ISREG(st.st_mode); }
bool exists(const std::string& p) { struct stat st; return path_stat(p, st); }
bool is_link(const std::string& p) {
#ifdef _WIN32
    (void)p; return false;
#else
    struct stat st; return ::lstat(p.c_str(), &st) == 0 && S_ISLNK(st.st_mode);
#endif
}

std::vector<std::string> list_names(const std::string& dir) {
    auto v = ny_fs::listdir(dir);
    std::sort(v.begin(), v.end());
    return v;
}

// Join for walk/glob output: always '/' after a relative/absolute prefix the
// caller wrote, keeping the caller's own spelling.
std::string child_path(const std::string& dir, const std::string& name) {
    if (dir.empty()) return name;
    if (is_any_sep(dir.back())) return dir + name;
    return dir + "/" + name;
}

double ts_of(const struct stat& st, char which) {
#if defined(__APPLE__)
    const struct timespec& t = which == 'm' ? st.st_mtimespec : which == 'a' ? st.st_atimespec : st.st_ctimespec;
    return (double)t.tv_sec + t.tv_nsec / 1e9;
#elif defined(_WIN32)
    return (double)(which == 'm' ? st.st_mtime : which == 'a' ? st.st_atime : st.st_ctime);
#else
    const struct timespec& t = which == 'm' ? st.st_mtim : which == 'a' ? st.st_atim : st.st_ctim;
    return (double)t.tv_sec + t.tv_nsec / 1e9;
#endif
}

Value stat_map(NythonExecutor& E, const struct stat* st, bool link) {
    using nyos::make_int;
    bool ok = st != nullptr;
    std::vector<std::pair<std::string, Value>> m = {
        {"exists",  Value(ok)},
        {"size",    make_int(ok ? (long long)st->st_size : 0)},
        {"is_file", Value(ok && S_ISREG(st->st_mode))},
        {"is_dir",  Value(ok && S_ISDIR(st->st_mode))},
        {"is_link", Value(link)},
        {"mtime",   Value(ok ? ts_of(*st, 'm') : 0.0)},
        {"atime",   Value(ok ? ts_of(*st, 'a') : 0.0)},
        {"ctime",   Value(ok ? ts_of(*st, 'c') : 0.0)},
        {"mtime_ms", make_int(ok ? (long long)(ts_of(*st, 'm') * 1000.0) : 0)},
        {"mode",    make_int(ok ? (long long)st->st_mode : 0)},
        {"permissions", make_int(ok ? (long long)(st->st_mode & 07777) : 0)},
        {"uid",     make_int(ok ? (long long)st->st_uid : 0)},
        {"gid",     make_int(ok ? (long long)st->st_gid : 0)},
        {"nlink",   make_int(ok ? (long long)st->st_nlink : 0)},
        {"ino",     make_int(ok ? (long long)st->st_ino : 0)},
    };
    return nyos::make_map(E, m);
}

void copy_file_or_raise(const std::string& src, const std::string& dst) {
    struct stat st;
    if (!path_stat(src, st)) raise_errno(errno, src);
    if (S_ISDIR(st.st_mode)) raise_errno(EISDIR, src);
    std::ifstream in(src, std::ios::binary);
    if (!in.is_open()) raise_errno(errno ? errno : EACCES, src);
    if (is_dir(dst)) raise_errno(EISDIR, dst);
    std::ofstream out(dst, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) raise_errno(errno ? errno : EACCES, dst);
    if (st.st_size > 0) out << in.rdbuf();
    out.close();
    if (!out) raise("OSError", "write failed: '" + dst + "'");
#ifndef _WIN32
    ::chmod(dst.c_str(), st.st_mode & 07777);
#endif
}

void rmtree_or_raise(const std::string& p) {
    struct stat st;
    if (!path_lstat(p, st)) raise_errno(errno, p);
    if (S_ISDIR(st.st_mode)) {       // lstat: a link to a directory is not followed
        for (auto& n : ny_fs::listdir(p)) rmtree_or_raise(nyos::join(p, n));
        if (::rmdir(p.c_str()) != 0) raise_errno(errno, p);
    } else {
        if (::remove(p.c_str()) != 0) raise_errno(errno, p);
    }
}

void copytree_or_raise(const std::string& src, const std::string& dst) {
    struct stat st;
    if (!path_stat(src, st)) raise_errno(errno, src);
    if (!S_ISDIR(st.st_mode)) raise_errno(ENOTDIR, src);
    if (exists(dst)) raise_errno(EEXIST, dst);
    if (NY_MKDIR(dst.c_str(), 0755) != 0) raise_errno(errno, dst);
    for (auto& n : list_names(src)) {
        std::string s = nyos::join(src, n), d = nyos::join(dst, n);
#ifndef _WIN32
        if (is_link(s)) {
            char buf[4096];
            ssize_t k = ::readlink(s.c_str(), buf, sizeof(buf) - 1);
            if (k < 0) raise_errno(errno, s);
            buf[k] = 0;
            if (::symlink(buf, d.c_str()) != 0) raise_errno(errno, d);
            continue;
        }
#endif
        if (is_dir(s)) copytree_or_raise(s, d);
        else copy_file_or_raise(s, d);
    }
#ifndef _WIN32
    ::chmod(dst.c_str(), st.st_mode & 07777);
#endif
}

void walk_into(NythonExecutor& E, const std::string& dir, std::vector<Value>& out) {
    std::vector<std::string> dirs, files;
    for (auto& n : list_names(dir)) {
        if (is_dir(child_path(dir, n))) dirs.push_back(n);
        else files.push_back(n);
    }
    out.push_back(nyos::make_list(E, {E.makeStringValue(dir),
                                      nyos::make_str_list(E, dirs),
                                      nyos::make_str_list(E, files)}));
    for (auto& d : dirs) {
        std::string sub = child_path(dir, d);
        if (!is_link(sub)) walk_into(E, sub, out);   // links are listed, not followed
    }
}

void walk_paths(const std::string& dir, std::vector<std::string>& out) {
    for (auto& n : list_names(dir)) {
        std::string p = child_path(dir, n);
        out.push_back(p);
        if (is_dir(p) && !is_link(p)) walk_paths(p, out);
    }
}

bool has_magic(const std::string& s) { return s.find_first_of("*?[") != std::string::npos; }

// glob, one component at a time. "**" matches zero or more directories;
// names starting with '.' only match a pattern that starts with '.'.
void glob_rec(const std::string& prefix, const std::vector<std::string>& comps, size_t i,
              std::vector<std::string>& out) {
    std::string dir = prefix.empty() ? "." : prefix;
    if (i == comps.size()) { if (!prefix.empty()) out.push_back(prefix); return; }
    const std::string& c = comps[i];
    bool last = i + 1 == comps.size();
    if (c == "**") {
        if (last) {                       // "dir/**": everything below dir
            for (auto& n : list_names(dir)) {
                if (n[0] == '.') continue;
                std::string p = child_path(prefix, n);
                out.push_back(p);
                if (is_dir(p) && !is_link(p)) glob_rec(p, comps, i, out);
            }
            return;
        }
        glob_rec(prefix, comps, i + 1, out);                    // zero directories
        for (auto& n : list_names(dir)) {                        // one or more
            if (n[0] == '.') continue;
            std::string p = child_path(prefix, n);
            if (is_dir(p) && !is_link(p)) glob_rec(p, comps, i, out);
        }
        return;
    }
    if (!has_magic(c)) {
        std::string p = child_path(prefix, c);
        if (last) { struct stat st; if (path_lstat(p, st)) out.push_back(p); }
        else if (is_dir(p)) glob_rec(p, comps, i + 1, out);
        return;
    }
    for (auto& n : list_names(dir)) {
        if (n[0] == '.' && c[0] != '.') continue;
        if (!nyos::fnmatch(n, c)) continue;
        std::string p = child_path(prefix, n);
        if (last) out.push_back(p);
        else if (is_dir(p)) glob_rec(p, comps, i + 1, out);
    }
}

std::vector<std::string> glob(const std::string& pattern) {
    std::vector<std::string> out;
    if (pattern.empty()) return out;
    if (!has_magic(pattern)) {
        struct stat st;
        if (path_lstat(pattern, st)) out.push_back(pattern);
        return out;
    }
    std::vector<std::string> comps;
    std::string cur, prefix;
    size_t i = 0;
#ifdef _WIN32
    if (pattern.size() >= 2 && pattern[1] == ':') { prefix = pattern.substr(0, 2); i = 2; }
#endif
    if (i < pattern.size() && is_any_sep(pattern[i])) { prefix += pattern[i]; i++; }
    for (; i < pattern.size(); i++) {
        if (is_any_sep(pattern[i])) { if (!cur.empty()) comps.push_back(cur); cur.clear(); }
        else cur += pattern[i];
    }
    if (!cur.empty()) comps.push_back(cur);
    glob_rec(prefix, comps, 0, out);
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

std::string gettempdir() {
    for (const char* k : {"TMPDIR", "TEMP", "TMP"}) {
        const char* v = std::getenv(k);
        if (v && *v) {
            std::string s = v;
            while (s.size() > 1 && is_any_sep(s.back())) s.pop_back();
            return s;
        }
    }
#ifdef _WIN32
    char buf[MAX_PATH + 1];
    DWORD n = GetTempPathA(MAX_PATH, buf);
    if (n > 0) {
        std::string s(buf, n);
        while (s.size() > 3 && is_any_sep(s.back())) s.pop_back();
        return s;
    }
    return ".";
#else
    return "/tmp";
#endif
}

std::string home_dir() {
#ifdef _WIN32
    const char* h = std::getenv("USERPROFILE");
    if (h && *h) return h;
    const char* d = std::getenv("HOMEDRIVE");
    const char* p = std::getenv("HOMEPATH");
    if (d && p) return std::string(d) + p;
    return "";
#else
    const char* h = std::getenv("HOME");
    if (h && *h) return h;
    struct passwd* pw = getpwuid(getuid());
    return pw && pw->pw_dir ? pw->pw_dir : "";
#endif
}

std::string expanduser(const std::string& p) {
    if (p.empty() || p[0] != '~') return p;
    size_t end = 1;
    while (end < p.size() && !is_any_sep(p[end])) end++;
    std::string user = p.substr(1, end - 1);
    std::string home;
    if (user.empty()) home = home_dir();
    else {
#ifndef _WIN32
        struct passwd* pw = getpwnam(user.c_str());
        if (!pw || !pw->pw_dir) return p;
        home = pw->pw_dir;
#else
        return p;
#endif
    }
    if (home.empty()) return p;
    return home + p.substr(end);
}

std::string expandvars(const std::string& s) {
    std::string out;
    size_t i = 0;
    auto is_name = [](char c) { return std::isalnum((unsigned char)c) || c == '_'; };
    while (i < s.size()) {
        if (s[i] == '$' && i + 1 < s.size()) {
            if (s[i + 1] == '{') {
                size_t close = s.find('}', i + 2);
                if (close != std::string::npos) {
                    const char* v = std::getenv(s.substr(i + 2, close - i - 2).c_str());
                    if (v) { out += v; i = close + 1; continue; }
                }
            } else if (is_name(s[i + 1])) {
                size_t j = i + 1;
                while (j < s.size() && is_name(s[j])) j++;
                const char* v = std::getenv(s.substr(i + 1, j - i - 1).c_str());
                if (v) { out += v; i = j; continue; }
            }
        }
#ifdef _WIN32
        if (s[i] == '%') {
            size_t close = s.find('%', i + 1);
            if (close != std::string::npos && close > i + 1) {
                const char* v = std::getenv(s.substr(i + 1, close - i - 1).c_str());
                if (v) { out += v; i = close + 1; continue; }
            }
        }
#endif
        out += s[i++];
    }
    return out;
}

std::vector<std::string> components(const std::string& p) {
    std::vector<std::string> v;
    std::string cur;
    for (char c : p) {
        if (is_any_sep(c)) { if (!cur.empty()) v.push_back(cur); cur.clear(); }
        else cur += c;
    }
    if (!cur.empty()) v.push_back(cur);
    return v;
}

std::string relpath(const std::string& path, const std::string& start) {
    std::vector<std::string> a = components(nyos::abspath(path));
    std::vector<std::string> b = components(nyos::abspath(start.empty() ? "." : start));
    size_t k = 0;
    while (k < a.size() && k < b.size() && a[k] == b[k]) k++;
    std::string out;
    for (size_t i = k; i < b.size(); i++) { if (!out.empty()) out += SEP; out += ".."; }
    for (size_t i = k; i < a.size(); i++) { if (!out.empty()) out += SEP; out += a[i]; }
    return out.empty() ? "." : out;
}

// Whole-file read for read_bytes/cat. A directory is an IsADirectoryError
// instead of the raw C++ stream failure it used to surface as.
bool read_all(const std::string& path, std::string& out) {
    if (is_dir(path)) raise_errno(EISDIR, path);
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open()) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

} // namespace

// ════════════════════════════════════════════════════════════════════════════
// dispatch_os
// ════════════════════════════════════════════════════════════════════════════
Value dispatch_os(NythonExecutor& E,
                  const std::string& name,
                  std::vector<Value>& args,
                  Context* ctx) {
    using namespace nyos;
    auto S = [&](size_t i, const std::string& d = "") -> std::string {
        return (i < args.size() && args[i].type != ValueType::NONE) ? E.getStringValue(args[i]) : d;
    };
    auto Str = [&](const std::string& s) { return E.makeStringValue(s); };

    // Time and processes live in their own files.
    {
        Value r = dispatch_os_time(E, name, args, ctx);
        if (r.type != ValueType::UNDEFINED) return r;
        r = dispatch_os_proc(E, name, args, ctx);
        if (r.type != ValueType::UNDEFINED) return r;
    }

    // ── Paths ────────────────────────────────────────────────────────────────
    if (name == "os_path_join" || name == "path_join") {
        // Python semantics: an absolute component restarts the path
        // (os_path_join("a", "/b") is "/b"; it used to be "a//b").
        std::string r;
        for (size_t i = 0; i < args.size(); i++) {
            std::string part = E.getStringValue(args[i]);
            r = i ? nyos::join(r, part) : part;
        }
        return Str(r);
    }
    if (name == "os_path_basename" || name == "path_basename") return Str(nyos::split(S(0)).second);
    if (name == "os_path_dirname" || name == "path_dirname") {
        // "/x" -> "/" (it used to be ""). A bare file name keeps its legacy
        // dirname "." (Python says ""), which callers join onto.
        std::string p = S(0);
        auto hs = nyos::split(p);
        if (hs.first.empty()) return Str(p.empty() ? "" : ".");
        return Str(hs.first);
    }
    // ".tar.gz" -> ".gz"; no extension for "/a.b/c" or ".bashrc" (both used
    // to report one).
    if (name == "os_path_ext" || name == "path_ext") return Str(nyos::splitext(S(0)).second);
    if (name == "os_path_split") {
        auto hs = nyos::split(S(0));
        return make_str_list(E, {hs.first, hs.second});
    }
    if (name == "os_path_splitext") {
        auto re = nyos::splitext(S(0));
        return make_str_list(E, {re.first, re.second});
    }
    if (name == "os_path_normpath" || name == "os_path_normalize") return Str(nyos::normpath(S(0)));
    if (name == "os_path_abspath") return Str(nyos::abspath(S(0, ".")));
    if (name == "os_path_abs" || name == "os_path_realpath") {
        // Resolves symbolic links when the path exists; a path that does not
        // exist yet is made absolute instead of becoming "" as it used to.
        std::string p = S(0, ".");
        char buf[8192];
        if (ny_realpath(p.c_str(), buf)) return Str(std::string(buf));
        return Str(nyos::abspath(p));
    }
    if (name == "os_path_relpath") {
        Args A(E, args, {"start"});
        return Str(relpath(A.str(0, "path", "."), A.str(1, "start", ".")));
    }
    if (name == "os_path_isabs") return Value(nyos::isabs(S(0)));
    if (name == "os_path_expanduser") return Str(expanduser(S(0)));
    if (name == "os_path_expandvars") return Str(expandvars(S(0)));
    if (name == "os_path_commonpath") {
        auto items = list_items(args.empty() ? NONE_VALUE : args[0]);
        if (items.empty()) raise("ValueError", "os_path_commonpath() arg is an empty sequence");
        std::vector<std::vector<std::string>> all;
        bool abs = nyos::isabs(E.getStringValue(items[0]));
        for (auto& it : items) all.push_back(components(nyos::normpath(E.getStringValue(it))));
        std::string out = abs ? sep_str() : "";
        for (size_t i = 0;; i++) {
            bool ok = i < all[0].size();
            for (auto& v : all) if (!ok || i >= v.size() || v[i] != all[0][i]) ok = false;
            if (!ok) break;
            if (!out.empty() && !is_any_sep(out.back())) out += SEP;
            out += all[0][i];
        }
        return Str(out.empty() && !abs ? "" : out);
    }
    if (name == "os_fnmatch" || name == "fnmatch") return Value(nyos::fnmatch(S(0), S(1)));
    if (name == "os_glob" || name == "glob") return make_str_list(E, glob(S(0)));

    // ── Existence and type ───────────────────────────────────────────────────
    // All stat-based: an existing but unreadable file exists (`exists` and
    // `os_exists` used to try to open it for reading).
    if (name == "os_exists" || name == "path_exists" || name == "exists" || name == "os_path_exists")
        return Value(!args.empty() && exists(S(0)));
    if (name == "os_isdir" || name == "path_isdir" || name == "os_path_isdir") return Value(is_dir(S(0)));
    if (name == "os_isfile" || name == "path_isfile" || name == "os_path_isfile") return Value(is_file(S(0)));
    if (name == "os_islink" || name == "os_path_islink") return Value(is_link(S(0)));
    if (name == "os_path_getsize") {
        struct stat st;
        if (!path_stat(S(0), st)) raise_errno(errno, S(0));
        return make_int((long long)st.st_size);
    }
    if (name == "os_path_getmtime") {
        struct stat st;
        if (!path_stat(S(0), st)) raise_errno(errno, S(0));
        return Value(ts_of(st, 'm'));
    }
    if (name == "os_access") {
        // os_access(path, "r" | "w" | "x" | "rw" | "" (exists)) -> bool
        std::string p = S(0), m = S(1, "");
        int mode = 0;
        if (m.find('r') != std::string::npos) mode |= 4;
        if (m.find('w') != std::string::npos) mode |= 2;
#ifndef _WIN32
        if (m.find('x') != std::string::npos) mode |= 1;
        return Value(::access(p.c_str(), mode ? mode : F_OK) == 0);
#else
        return Value(::_access(p.c_str(), mode & 6) == 0);
#endif
    }

    // ── Stat ─────────────────────────────────────────────────────────────────
    if (name == "fs_stat") {
        // Never raises: a missing path is {exists: false, size: 0, ...}.
        std::string p = S(0);
        struct stat st;
        bool link = is_link(p);
        if (path_stat(p, st)) return stat_map(E, &st, link);
        return stat_map(E, nullptr, link);
    }
    if (name == "os_stat" || name == "os_lstat") {
        std::string p = S(0);
        struct stat st;
        bool ok = name == "os_stat" ? path_stat(p, st) : path_lstat(p, st);
        if (!ok) raise_errno(errno, p);
        return stat_map(E, &st, is_link(p));
    }

    // ── Directories ──────────────────────────────────────────────────────────
    if (name == "os_listdir" || name == "listdir" || name == "list_dir" || name == "ls") {
        std::string dir = args.empty() ? "." : S(0, ".");
        return make_str_list(E, ny_fs::listdir(dir));
    }
    if (name == "os_mkdir" || name == "fs_mkdirs") {
        // Recursive on both engines (the VM's was one level); true when the
        // directory exists afterwards. A FILE at the path is not a directory,
        // so that is false (it used to be true).
        std::string p = S(0);
        if (p.empty()) return Value(false);
        ny_fs::mkdirs(p);
        return Value(is_dir(p));
    }
    if (name == "mkdir") {
        // Like the shell command: one level, false when it already exists.
        std::string p = S(0);
        if (p.empty()) return Value(false);
        return Value(NY_MKDIR(p.c_str(), 0755) == 0);
    }
    if (name == "os_makedirs") {
        Args A(E, args, {"exist_ok"});
        std::string p = A.str(0, "path");
        bool exist_ok = A.flag(1, "exist_ok", false);
        if (exists(p)) {
            if (exist_ok && is_dir(p)) return Value(true);
            raise_errno(EEXIST, p);
        }
        errno = 0;
        ny_fs::mkdirs(p);
        if (!is_dir(p)) raise_errno(errno ? errno : EACCES, p);
        return Value(true);
    }
    if (name == "os_rmdir") {
        std::string p = S(0);
        if (::rmdir(p.c_str()) != 0) raise_errno(errno, p);
        return Value(true);
    }
    if (name == "os_rmtree") {
        Args A(E, args, {"ignore_errors"});
        std::string p = A.str(0, "path");
        if (A.flag(1, "ignore_errors", false)) {
            try { rmtree_or_raise(p); } catch (std::string&) { return Value(false); }
            return Value(true);
        }
        rmtree_or_raise(p);
        return Value(true);
    }
    if (name == "os_walk") {
        // [[dirpath, [dirnames], [filenames]], ...], top-down, names sorted.
        std::vector<Value> out;
        std::string top = S(0, ".");
        if (is_dir(top)) walk_into(E, top, out);
        return make_list(E, out);
    }
    if (name == "fs_walk") {
        // Every entry below dir, recursively, as paths (it used to list one
        // level only, despite the name).
        std::string dir = S(0, ".");
        std::vector<std::string> out;
        if (is_dir(dir)) walk_paths(dir, out);
        return make_str_list(E, out);
    }

    // ── Files ────────────────────────────────────────────────────────────────
    if (name == "os_remove" || name == "remove_file" || name == "file_delete") {
        if (args.empty()) return Value(false);
        return Value(std::remove(S(0).c_str()) == 0);
    }
    if (name == "os_unlink") {
        std::string p = S(0);
        if (is_dir(p) && !is_link(p)) raise_errno(EISDIR, p);
        if (std::remove(p.c_str()) != 0) raise_errno(errno, p);
        return Value(true);
    }
    if (name == "os_rename" || name == "file_rename") {
        if (args.size() < 2) return Value(false);
        return Value(std::rename(S(0).c_str(), S(1).c_str()) == 0);
    }
    if (name == "file_copy") {
        // Legacy bool form. It opened the destination first, so a missing
        // source left an empty destination file behind.
        if (args.size() < 2) return Value(false);
        try { copy_file_or_raise(S(0), S(1)); } catch (std::string&) { return Value(false); }
        return Value(true);
    }
    if (name == "os_copy" || name == "os_copyfile") {
        std::string src = S(0), dst = S(1);
        if (name == "os_copy" && is_dir(dst)) dst = nyos::join(dst, nyos::split(src).second);
        copy_file_or_raise(src, dst);
        return Str(dst);
    }
    if (name == "os_copytree") {
        std::string src = S(0), dst = S(1);
        copytree_or_raise(src, dst);
        return Str(dst);
    }
    if (name == "os_move") {
        std::string src = S(0), dst = S(1);
        if (!exists(src) && !is_link(src)) raise_errno(ENOENT, src);
        if (is_dir(dst)) dst = nyos::join(dst, nyos::split(src).second);
        if (std::rename(src.c_str(), dst.c_str()) == 0) return Str(dst);
        if (errno != EXDEV) raise_errno(errno, src, dst);
        // Across file systems: copy, then remove the source.
        if (is_dir(src)) { copytree_or_raise(src, dst); rmtree_or_raise(src); }
        else { copy_file_or_raise(src, dst); if (std::remove(src.c_str()) != 0) raise_errno(errno, src); }
        return Str(dst);
    }
    if (name == "os_chmod") {
        std::string p = S(0);
        long long mode = args.size() > 1 ? to_int(args[1], 0644) : 0644;
#ifdef _WIN32
        if (::_chmod(p.c_str(), (mode & 0200) ? (_S_IREAD | _S_IWRITE) : _S_IREAD) != 0) raise_errno(errno, p);
#else
        if (::chmod(p.c_str(), (mode_t)mode) != 0) raise_errno(errno, p);
#endif
        return Value(true);
    }
    if (name == "os_symlink") {
        std::string src = S(0), dst = S(1);
#ifdef _WIN32
        raise("OSError", "symbolic links are not supported on this platform");
#else
        if (::symlink(src.c_str(), dst.c_str()) != 0) raise_errno(errno, src, dst);
        return Value(true);
#endif
    }
    if (name == "os_readlink") {
        std::string p = S(0);
#ifdef _WIN32
        raise("OSError", "symbolic links are not supported on this platform");
#else
        char buf[8192];
        ssize_t k = ::readlink(p.c_str(), buf, sizeof(buf) - 1);
        if (k < 0) raise_errno(errno, p);
        return Str(std::string(buf, (size_t)k));
#endif
    }
    if (name == "os_touch") {
        std::string p = S(0);
        if (is_dir(p)) {
            // a directory's times can still be updated
        } else if (!exists(p)) {
            std::ofstream f(p, std::ios::app);
            if (!f.is_open()) raise_errno(errno ? errno : EACCES, p);
        }
#ifdef _WIN32
        if (::_utime(p.c_str(), nullptr) != 0) raise_errno(errno, p);
#else
        if (::utime(p.c_str(), nullptr) != 0) raise_errno(errno, p);
#endif
        return Value(true);
    }
    if (name == "read_bytes") {
        std::string data;
        if (!read_all(S(0), data)) return NONE_VALUE;
        std::vector<Value> out;
        out.reserve(data.size());
        for (unsigned char c : data) out.push_back(Value((int)c));
        return make_list(E, out);
    }
    if (name == "write_bytes") {
        // write_bytes(path, list_of_ints) -> bool. A value outside 0..255 is a
        // ValueError; it used to wrap silently (300 wrote 44, "a" wrote 0).
        if (args.size() < 2 || !is_list(args[1])) return Value(false);
        std::string data;
        for (auto& v : list_items(args[1])) {
            if (v.type != ValueType::INTEGER) raise("TypeError", "write_bytes: expected a list of ints");
            long long b = bigint_to_i64(v.value.i);
            if (b < 0 || b > 255) raise("ValueError", "write_bytes: byte must be in range(0, 256), got " + std::to_string(b));
            data += (char)(unsigned char)b;
        }
        std::ofstream f(S(0), std::ios::binary | std::ios::trunc);
        if (!f.is_open()) return Value(false);
        f.write(data.data(), (std::streamsize)data.size());
        return Value(true);
    }
    if (name == "cat") {
        std::string data;
        if (!read_all(S(0), data)) return NONE_VALUE;
        return Str(data);
    }
    if (name == "write") {
        if (args.size() < 2) return Value(false);
        std::ofstream f(S(0), std::ios::binary | std::ios::trunc);
        if (!f.is_open()) return Value(false);
        f << E.getStringValue(args[1]);
        return Value(true);
    }
    if (name == "append") {
        // append(path, text) - the VM had it; now both engines do.
        if (args.size() < 2) return Value(false);
        std::ofstream f(S(0), std::ios::binary | std::ios::app);
        if (!f.is_open()) return Value(false);
        f << E.getStringValue(args[1]);
        return Value(true);
    }

    // ── Temporary files ──────────────────────────────────────────────────────
    if (name == "os_gettempdir") return Str(gettempdir());
    if (name == "os_mkstemp" || name == "os_mkdtemp") {
        // os_mkstemp(prefix="tmp", suffix="", dir=gettempdir()) -> path of a
        // new empty file, created exclusively (mode 0600).
        // os_mkdtemp(prefix="tmp", dir=gettempdir()) -> path of a new directory.
        bool file = name == "os_mkstemp";
        Args A(E, args, {"prefix", "suffix", "dir"});
        std::string prefix = A.str(0, "prefix", "tmp");
        std::string suffix = file ? A.str(1, "suffix", "") : "";
        std::string dir = A.str(file ? 2 : 1, "dir", "");
        if (dir.empty()) dir = gettempdir();
#ifndef _WIN32
        std::string tmpl = nyos::join(dir, prefix + "XXXXXX" + suffix);
        std::vector<char> buf(tmpl.begin(), tmpl.end());
        buf.push_back('\0');
        if (file) {
            int fd = ::mkstemps(buf.data(), (int)suffix.size());
            if (fd < 0) raise_errno(errno, tmpl);
            ::close(fd);
        } else if (!::mkdtemp(buf.data())) {
            raise_errno(errno, tmpl);
        }
        return Str(std::string(buf.data()));
#else
        static const char* hex = "0123456789abcdef";
        for (int attempt = 0; attempt < 100; attempt++) {
            std::string r;
            for (int k = 0; k < 8; k++) r += hex[std::rand() % 16];
            std::string p = nyos::join(dir, prefix + r + suffix);
            if (file) {
                int fd = ::_open(p.c_str(), _O_CREAT | _O_EXCL | _O_RDWR, _S_IREAD | _S_IWRITE);
                if (fd >= 0) { ::_close(fd); return Str(p); }
            } else if (::_mkdir(p.c_str()) == 0) {
                return Str(p);
            }
            if (errno != EEXIST) raise_errno(errno, p);
        }
        raise("FileExistsError", "could not create a unique temporary name in '" + dir + "'");
#endif
    }
    if (name == "os_disk_usage") {
        std::string p = S(0, ".");
#ifndef _WIN32
        struct statvfs sv;
        if (::statvfs(p.c_str(), &sv) != 0) raise_errno(errno, p);
        long long total = (long long)sv.f_blocks * (long long)sv.f_frsize;
        long long free_ = (long long)sv.f_bavail * (long long)sv.f_frsize;
        long long used = (long long)(sv.f_blocks - sv.f_bfree) * (long long)sv.f_frsize;
#else
        ULARGE_INTEGER avail, tot, fr;
        if (!GetDiskFreeSpaceExA(p.c_str(), &avail, &tot, &fr)) raise("OSError", "cannot read disk usage of '" + p + "'");
        long long total = (long long)tot.QuadPart, free_ = (long long)avail.QuadPart;
        long long used = (long long)(tot.QuadPart - fr.QuadPart);
#endif
        return make_map(E, {{"total", make_int(total)}, {"used", make_int(used)}, {"free", make_int(free_)}});
    }

    // ── Working directory ────────────────────────────────────────────────────
    if (name == "getcwd" || name == "os_getcwd" || name == "pwd") return Str(nyos::cwd());
    if (name == "chdir" || name == "cd" || name == "os_chdir") {
        if (args.empty()) return Value(false);
        bool ok = ::chdir(S(0).c_str()) == 0;
        if (!ok && name == "os_chdir") raise_errno(errno, S(0));
        return Value(ok);
    }

    // ── Environment ──────────────────────────────────────────────────────────
    if (name == "os_getenv" || name == "getenv" || name == "env") {
        // none (or the default) when unset, on both engines - the VM's own
        // version returned "".
        Args A(E, args, {"default"});
        if (!A.has(0, "key")) return NONE_VALUE;
        const char* v = std::getenv(A.str(0, "key").c_str());
        if (v) return Str(std::string(v));
        return A.has(1, "default") ? A.get(1, "default") : NONE_VALUE;
    }
    if (name == "os_setenv") {
        if (args.size() < 2) return Value(false);
        std::string k = S(0);
        if (k.empty() || k.find('=') != std::string::npos)
            raise("ValueError", "illegal environment variable name: '" + k + "'");
        return Value(setenv(k.c_str(), E.getStringValue(args[1]).c_str(), 1) == 0);
    }
    if (name == "os_unsetenv") {
        if (args.empty()) return Value(false);
#ifdef _WIN32
        return Value(_putenv_s(S(0).c_str(), "") == 0);
#else
        return Value(::unsetenv(S(0).c_str()) == 0);
#endif
    }
    if (name == "os_environ") {
        std::vector<std::pair<std::string, Value>> m;
#ifdef _WIN32
        char** envp = _environ;
#else
        char** envp = environ;
#endif
        for (char** e = envp; e && *e; e++) {
            std::string kv = *e;
            size_t eq = kv.find('=');
            if (eq == std::string::npos || eq == 0) continue;
            m.push_back({kv.substr(0, eq), Str(kv.substr(eq + 1))});
        }
        return make_map(E, m);
    }

    // ── System information ───────────────────────────────────────────────────
    if (name == "os_platform") {
#if defined(_WIN32)
        return Str("windows");
#elif defined(__APPLE__)
        return Str("darwin");
#elif defined(__FreeBSD__)
        return Str("freebsd");
#else
        return Str("linux");
#endif
    }
    if (name == "os_cpu_count") {
        unsigned n = std::thread::hardware_concurrency();
        return Value((int)(n ? n : 1));
    }
    if (name == "os_hostname") {
        char buf[256] = {0};
        if (gethostname(buf, sizeof(buf) - 1) != 0) return Str("");
        return Str(std::string(buf));
    }
    if (name == "os_username") {
#ifndef _WIN32
        struct passwd* pw = getpwuid(geteuid());
        if (pw && pw->pw_name) return Str(pw->pw_name);
        const char* u = std::getenv("USER");
#else
        const char* u = std::getenv("USERNAME");
#endif
        return Str(u ? u : "");
    }
    if (name == "os_home") return Str(home_dir());
    if (name == "os_uname") {
#ifndef _WIN32
        struct utsname u;
        if (::uname(&u) != 0) raise_errno(errno, "");
        return make_map(E, {{"sysname", Str(u.sysname)}, {"nodename", Str(u.nodename)},
                            {"release", Str(u.release)}, {"version", Str(u.version)},
                            {"machine", Str(u.machine)}});
#else
        char host[256] = {0};
        gethostname(host, sizeof(host) - 1);
        return make_map(E, {{"sysname", Str("Windows")}, {"nodename", Str(host)},
                            {"release", Str("")}, {"version", Str("")}, {"machine", Str("")}});
#endif
    }

    return UNDEFINED_VALUE;  // not handled by this module
}

#pragma GCC diagnostic pop
