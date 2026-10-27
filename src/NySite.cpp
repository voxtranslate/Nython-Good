// NySite.cpp - virtual environments (PEP 405) and site-packages at startup
// (round 87; see nyrt::SiteState in include/NyRuntime.hpp).
//
// CPython's getpath, as far as Nython needs it: the program's own path - the
// launcher a virtual environment holds (bin/nython, a symbolic link to the
// installation's binary on POSIX; Scripts\nython.exe, a copy, on Windows),
// not resolved through links, or the __NYVENV_LAUNCHER__ a wrapper names
// (read once and removed from the environment, as macOS's
// __PYVENV_LAUNCHER__) - and a pyvenv.cfg beside it or one directory up.
// Then sys.executable is that launcher, sys._base_executable the
// installation's binary (pyvenv.cfg's `home` when the launcher is a copy),
// sys.prefix the environment, and the site-packages directories that exist
// are put after the standard library on the search path:
//
//   in an environment     <env>/lib/nython3.12/site-packages (Windows:
//                         <env>\Lib\site-packages); with
//                         include-system-site-packages = true also:
//   otherwise             the user's (~/.local/lib/nython3.12/site-packages,
//                         %APPDATA%\Nython\Nython312\site-packages; not with
//                         -s or NYTHONNOUSERSITE), then the installation's
//                         <prefix>/lib/site-packages
//
// -S adds none. A .pth file or a sitecustomize / usercustomize module in one
// of them sets run_site: the engines then import site before the program
// (lib/site.ny's _ny_startup processes them).
#include "NyRuntime.hpp"
#include <string>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sys/stat.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#include <dirent.h>
#endif

namespace {

bool is_file(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && !S_ISDIR(st.st_mode);
}
bool is_dir(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}
bool is_sep(char c) {
#ifdef _WIN32
    return c == '/' || c == '\\';
#else
    return c == '/';
#endif
}
std::string dir_of(const std::string& p) {
    size_t i = p.size();
    while (i > 0 && !is_sep(p[i - 1])) i--;
    if (i == 0) return std::string();
    size_t j = i - 1;
    while (j > 0 && is_sep(p[j - 1])) j--;
    return j == 0 ? p.substr(0, 1) : p.substr(0, j);
}
std::string base_of(const std::string& p) {
    size_t i = p.size();
    while (i > 0 && !is_sep(p[i - 1])) i--;
    return p.substr(i);
}
#ifdef _WIN32
const char kSep = '\\';
#else
const char kSep = '/';
#endif
std::string join(const std::string& a, const std::string& b) {
    if (a.empty()) return b;
    if (is_sep(a.back())) return a + b;
    return a + kSep + b;
}
bool absolute(const std::string& p) {
#ifdef _WIN32
    return (p.size() > 1 && p[1] == ':') || (!p.empty() && is_sep(p[0]));
#else
    return !p.empty() && p[0] == '/';
#endif
}
std::string cwd() {
#ifdef _WIN32
    char b[4096];
    DWORD n = GetCurrentDirectoryA(sizeof(b), b);
    return n > 0 && n < sizeof(b) ? std::string(b, n) : std::string();
#else
    char b[4096];
    return getcwd(b, sizeof(b)) ? std::string(b) : std::string();
#endif
}
// "a/./b" and "a//b" tidied (not "..": a link's parent is not textual)
std::string tidy(const std::string& p) {
    std::string out;
    size_t i = 0;
    while (i < p.size()) {
        if (is_sep(p[i])) {
            if (out.empty() || !is_sep(out.back())) out += p[i];
            i++;
            continue;
        }
        if (p[i] == '.' && (i + 1 == p.size() || is_sep(p[i + 1])) && (i == 0 || is_sep(p[i - 1]))) {
            i += (i + 1 < p.size()) ? 2 : 1;
            continue;
        }
        out += p[i++];
    }
    if (out.size() > 1 && is_sep(out.back())) out.pop_back();
    return out;
}

void unset(const char* k) {
#ifdef _WIN32
    _putenv_s(k, "");
#else
    unsetenv(k);
#endif
}

// The path the program was started by: not resolved through symbolic links,
// so a link in an environment's bin/ is that environment's.
std::string program_path(const std::string& argv0) {
    const char* l = std::getenv("__NYVENV_LAUNCHER__");
    if (l && *l) {
        std::string p = l;
        unset("__NYVENV_LAUNCHER__");
        return p;
    }
#ifdef _WIN32
    (void)argv0;
    return nyrt::executable_path();   // a copy in Scripts\ is its own path
#else
    if (argv0.find('/') != std::string::npos)
        return tidy(absolute(argv0) ? argv0 : join(cwd(), argv0));
    if (!argv0.empty())
        if (const char* path = std::getenv("PATH")) {
            std::string all = path;
            size_t a = 0;
            while (a <= all.size()) {
                size_t b = all.find(':', a);
                if (b == std::string::npos) b = all.size();
                std::string d = all.substr(a, b - a);
                if (d.empty()) d = ".";
                std::string c = join(d, argv0);
                if (is_file(c) && access(c.c_str(), X_OK) == 0)
                    return tidy(absolute(c) ? c : join(cwd(), c));
                a = b + 1;
            }
        }
    return nyrt::executable_path();
#endif
}

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) a++;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n')) b--;
    return s.substr(a, b - a);
}

std::string lower(std::string s) {
    for (auto& c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return s;
}

bool has_site_hooks(const std::string& dir) {
    for (const char* m : {"sitecustomize", "usercustomize"})
        for (const char* e : {".ny", ".py"})
            if (is_file(join(dir, std::string(m) + e))) return true;
#ifdef _WIN32
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(join(dir, "*.pth").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    bool any = false;
    do { if (fd.cFileName[0] != '.') { any = true; break; } } while (FindNextFileA(h, &fd));
    FindClose(h);
    return any;
#else
    DIR* d = opendir(dir.c_str());
    if (!d) return false;
    bool any = false;
    while (struct dirent* e = readdir(d)) {
        size_t n = std::strlen(e->d_name);
        if (n > 4 && e->d_name[0] != '.' && std::strcmp(e->d_name + n - 4, ".pth") == 0) { any = true; break; }
    }
    closedir(d);
    return any;
#endif
}

std::string user_base() {
    const char* b = std::getenv("PYTHONUSERBASE");
    if (b && *b) return b;
#ifdef _WIN32
    const char* a = std::getenv("APPDATA");
    return join(a && *a ? std::string(a) : std::string("~"), "Nython");
#else
    const char* h = std::getenv("HOME");
    return join(h && *h ? std::string(h) : std::string(), ".local");
#endif
}

} // namespace

namespace nyrt {

void site_init(const std::string& argv0) {
    SiteState& st = site_state();
    st.site_dirs.clear();
    std::string prog = program_path(argv0);
    std::string real = executable_path();
    // pyvenv.cfg beside the launcher or one directory up
    std::string d1 = dir_of(prog), d2 = dir_of(d1);
    std::string cfg;
    if (!d1.empty() && is_file(join(d1, "pyvenv.cfg"))) cfg = join(d1, "pyvenv.cfg");
    else if (!d2.empty() && is_file(join(d2, "pyvenv.cfg"))) cfg = join(d2, "pyvenv.cfg");
    if (!cfg.empty()) {
        std::string home;
        bool sys_site = false;
        std::ifstream in(cfg);
        std::string line;
        while (std::getline(in, line)) {
            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string k = lower(trim(line.substr(0, eq))), v = trim(line.substr(eq + 1));
            if (k == "home") home = v;
            else if (k == "include-system-site-packages") sys_site = lower(v) == "true";
        }
        st.venv = dir_of(cfg);
        st.venv_cfg = cfg;
        st.system_site = sys_site;
        // the installation's binary: the launcher resolved (a link), or
        // home's binary of the same name when the launcher is a copy
        std::string base = real;
        if (!home.empty() && dir_of(real) == d1) {
            std::string h = join(home, base_of(real));
            if (is_file(h)) base = h;
        }
        base_executable() = base;
        executable_path() = prog;
    }
    if (cli_flags().no_site) return;
    auto add = [&](const std::string& d) {
        if (!is_dir(d)) return;
        std::string e = d;
        if (!is_sep(e.back())) e += kSep;
        for (auto& o : st.site_dirs) if (o == e) return;
        st.site_dirs.push_back(e);
        if (!st.run_site && has_site_hooks(d)) st.run_site = true;
    };
    if (!st.venv.empty()) {
#ifdef _WIN32
        add(join(join(st.venv, "Lib"), "site-packages"));
#else
        add(join(join(join(st.venv, "lib"), "nython3.12"), "site-packages"));
#endif
    }
    if (st.venv.empty() || st.system_site) {
        const char* nus = std::getenv("NYTHONNOUSERSITE");
        if (!cli_flags().no_user_site && !(nus && *nus) && !cli_flags().ignore_environment) {
#ifdef _WIN32
            add(join(join(user_base(), "Nython312"), "site-packages"));
#else
            add(join(join(join(user_base(), "lib"), "nython3.12"), "site-packages"));
#endif
        }
        auto std_dirs = stdlib_dirs();
        if (!std_dirs.empty()) {
            std::string lib = std_dirs.back();
            while (lib.size() > 1 && is_sep(lib.back())) lib.pop_back();
            add(join(lib, "site-packages"));
        }
    }
}

} // namespace nyrt
