#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/os_proc.cpp
// Processes (Python's subprocess, the process side of os) and the command
// line of the running script.
//
//   os_run(cmd, cwd=, env=, input=, timeout=) -> {code, stdout, stderr, ok}
//       cmd as a LIST runs the program directly (fork + execvp, no shell, so
//       nothing in an argument is ever interpreted); cmd as a STRING runs it
//       with /bin/sh -c. env adds to (does not replace) the current
//       environment. timeout is in seconds; when it expires the process
//       group is killed and TimeoutError is raised. A program that cannot be
//       started raises FileNotFoundError / PermissionError. Also subprocess_run.
//   os_spawn(cmd, cwd=, env=, input=) -> pid       start in the background
//   os_proc_read(pid) -> {stdout, stderr}          output since the last read
//   os_poll(pid) -> none while running, else the exit code
//   os_wait(pid, timeout=) -> exit code            TimeoutError on timeout
//   os_kill(pid, sig=15) -> bool                   signals the process group
//   os_system(cmd) -> exit code                    output goes to the terminal
//   os_exec(cmd) / popen / exec_cmd / sh / shell / system / cmd -> stdout
//       (legacy: a shell command's standard output, trailing newlines
//       stripped); process_exec(cmd) -> stdout+stderr
//   os_getpid() / os_getppid(), shell_quote(s), which(prog), sys_argv()
//
// Exit codes: a process killed by signal N reports -N, as in Python.
// merge=True (os_run, os_spawn) sends stderr into the stdout pipe, in the
// order it was written (Python's stderr=subprocess.STDOUT).
// Windows: the same API on Win32 (CreateProcessW, pipes, one Job Object per
// process so os_kill ends the tree). Command strings run through a POSIX sh
// when one is found (NY_SH, sh.exe on PATH, Git for Windows, MSYS2), so shell
// text is portable; otherwise through cmd.exe (NY_SH=cmd forces that).
// ─────────────────────────────────────────────────────────────────────────────

#include "platform_compat.hpp"

#include <chrono>
#include <thread>
#include <algorithm>
#include <cstring>
#include <cerrno>
#include <csignal>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <map>
#include <mutex>

#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include "NyConc.hpp"
#include "NyRuntime.hpp"

#ifndef _WIN32
#  include <sys/wait.h>
#  include <poll.h>
#  include <fcntl.h>
#  include <unistd.h>
#  include <signal.h>
extern char** environ;
#else
#  include <process.h>
#  include <tlhelp32.h>
#endif

using namespace std;
using namespace nython;
using namespace nython::kernel;

namespace {

using nyos::raise;
using nyos::raise_errno;

// Legacy stdout capture through the shell. fread keeps NUL bytes (fgets cut
// the output at the first one); trailing "\n" and "\r" are stripped.
std::string capture(const std::string& cmd, bool strip);

std::string capture_popen(const std::string& cmd, bool strip) {
    nyconc::GilRelease unlocked;     // touches no engine state (round 74, threads)
    std::string result;
    FILE* pipe = ::popen(cmd.c_str(), "r");
    if (!pipe) return result;
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, pipe)) > 0) result.append(buf, n);
    ::pclose(pipe);
    if (strip) while (!result.empty() && (result.back() == '\n' || result.back() == '\r')) result.pop_back();
    return result;
}

// POSIX sh quoting: safe text as is, anything else in single quotes.
std::string quote_posix(const std::string& s) {
    if (!s.empty()) {
        bool safe = true;
        for (char c : s) {
            if (!(std::isalnum((unsigned char)c) || std::strchr("@%+=:,./_-", c))) { safe = false; break; }
        }
        if (safe) return s;
    }
    std::string out = "'";
    for (char c : s) {
        if (c == '\'') out += "'\"'\"'";
        else out += c;
    }
    return out + "'";
}

// One argument of a command line: POSIX sh rules, or on Windows the rules
// CreateProcess / the C runtime split a command line by.
std::string quote_arg(const std::string& s) {
#ifdef _WIN32
    if (!s.empty() && s.find_first_of(" \t\"&|<>^%") == std::string::npos) return s;
    std::string out = "\"";
    size_t bs = 0;
    for (char c : s) {
        if (c == '\\') { bs++; continue; }
        if (c == '"') { out.append(bs * 2 + 1, '\\'); out += '"'; bs = 0; continue; }
        out.append(bs, '\\'); bs = 0; out += c;
    }
    out.append(bs * 2, '\\');
    return out + "\"";
#else
    if (!s.empty()) {
        bool safe = true;
        for (char c : s) {
            if (!(std::isalnum((unsigned char)c) || std::strchr("@%+=:,./_-", c))) { safe = false; break; }
        }
        if (safe) return s;
    }
    std::string out = "'";
    for (char c : s) {
        if (c == '\'') out += "'\"'\"'";
        else out += c;
    }
    return out + "'";
#endif
}

struct Cmd {
    bool shell = false;
    std::string line{};                 // shell form
    std::vector<std::string> argv{};    // direct form
};

Cmd parse_cmd(NythonExecutor& E, const Value& v) {
    Cmd c;
    if (nyos::is_list(v)) {
        for (auto& a : nyos::list_items(v)) c.argv.push_back(E.getStringValue(a));
        if (c.argv.empty()) raise("ValueError", "empty command");
    } else {
        c.shell = true;
        c.line = E.getStringValue(v);
    }
    return c;
}

std::vector<std::pair<std::string, std::string>> parse_env(NythonExecutor& E, const Value& v) {
    std::vector<std::pair<std::string, std::string>> out;
    for (auto& kv : nyos::map_items(v)) out.push_back({kv.first, E.getStringValue(kv.second)});
    return out;
}

double now_s() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

#ifndef _WIN32

void set_cloexec_nonblock(int fd, bool nonblock) {
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
    if (nonblock) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

bool make_pipe(int p[2]) {
    if (::pipe(p) != 0) return false;
    set_cloexec_nonblock(p[0], false);
    set_cloexec_nonblock(p[1], false);
    return true;
}

void ignore_sigpipe() {
    static std::once_flag once;
    std::call_once(once, [] { ::signal(SIGPIPE, SIG_IGN); });
}

// fork + exec with pipes for stdin/stdout/stderr. Returns the pid; the
// parent's ends are returned in in_fd/out_fd/err_fd (in_fd == -1 when there is
// no input). Raises when the program cannot be started.
pid_t start_process(const Cmd& c, const std::string& cwd,
                    const std::vector<std::pair<std::string, std::string>>& env,
                    bool want_stdin, int& in_fd, int& out_fd, int& err_fd, bool merge = false) {
    ignore_sigpipe();
    int in_p[2] = {-1, -1}, out_p[2], err_p[2], ex_p[2];
    if (want_stdin && !make_pipe(in_p)) raise_errno(errno, "pipe");
    if (!make_pipe(out_p) || !make_pipe(err_p) || !make_pipe(ex_p)) raise_errno(errno, "pipe");
    // argv/env prepared before fork: nothing but async-signal-safe calls in
    // the child.
    std::vector<char*> argv;
    std::string sh = "/bin/sh", dash_c = "-c";
    // The child's environment: ours plus `env`. Built here, before fork -
    // setenv() in the child can deadlock on the allocator lock when another
    // thread held it at the moment of fork.
    std::vector<std::string> env_strs;
    std::vector<char*> envp;
    if (!env.empty()) {
        for (char** e = environ; e && *e; e++) {
            std::string kv = *e;
            std::string k = kv.substr(0, kv.find('='));
            bool overridden = false;
            for (auto& o : env) if (o.first == k) { overridden = true; break; }
            if (!overridden) env_strs.push_back(kv);
        }
        for (auto& o : env) env_strs.push_back(o.first + "=" + o.second);
        for (auto& s2 : env_strs) envp.push_back(const_cast<char*>(s2.c_str()));
        envp.push_back(nullptr);
    }
    if (c.shell) {
        argv = {const_cast<char*>(sh.c_str()), const_cast<char*>(dash_c.c_str()), const_cast<char*>(c.line.c_str()), nullptr};
    } else {
        for (auto& a : c.argv) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);
    }
    pid_t pid = ::fork();
    if (pid < 0) raise_errno(errno, "fork");
    if (pid > 0) ::setpgid(pid, pid);   // also in the child; whichever runs first
    if (pid == 0) {
        ::setpgid(0, 0);
        int devnull = -1;
        if (want_stdin) ::dup2(in_p[0], 0);
        else { devnull = ::open("/dev/null", O_RDONLY); if (devnull >= 0) ::dup2(devnull, 0); }
        ::dup2(out_p[1], 1);
        ::dup2(merge ? out_p[1] : err_p[1], 2);   // merge: stderr into the stdout pipe
        ::signal(SIGPIPE, SIG_DFL);
        int err = 0;
        if (!cwd.empty() && ::chdir(cwd.c_str()) != 0) err = errno;
        if (!err) {
            if (!envp.empty()) environ = envp.data();
            ::execvp(argv[0], argv.data());
            err = errno;
        }
        char tag = cwd.empty() || err != ENOENT ? 'e' : 'c';
        if (!cwd.empty() && ::access(cwd.c_str(), F_OK) != 0) tag = 'c';
        char msg[8] = {tag, (char)(err & 0xFF), (char)((err >> 8) & 0xFF), 0};
        ssize_t w = ::write(ex_p[1], msg, 3);
        (void)w;
        ::_exit(127);
    }
    if (want_stdin) ::close(in_p[0]);
    ::close(out_p[1]);
    ::close(err_p[1]);
    ::close(ex_p[1]);
    // The exec pipe closes (CLOEXEC) when exec succeeds; otherwise the child
    // wrote why it could not start.
    char msg[3];
    ssize_t n;
    do { n = ::read(ex_p[0], msg, 3); } while (n < 0 && errno == EINTR);
    ::close(ex_p[0]);
    if (n == 3) {
        int err = (unsigned char)msg[1] | ((unsigned char)msg[2] << 8);
        int st;
        ::waitpid(pid, &st, 0);
        if (want_stdin) ::close(in_p[1]);
        ::close(out_p[0]);
        ::close(err_p[0]);
        if (msg[0] == 'c') raise_errno(err ? err : ENOENT, cwd);
        raise_errno(err, c.shell ? sh : c.argv[0]);
    }
    in_fd = want_stdin ? in_p[1] : -1;
    if (in_fd >= 0) set_cloexec_nonblock(in_fd, true);
    out_fd = out_p[0];
    err_fd = err_p[0];
    set_cloexec_nonblock(out_fd, true);
    set_cloexec_nonblock(err_fd, true);
    return pid;
}

int decode_status(int st) {
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    if (WIFSIGNALED(st)) return -WTERMSIG(st);
    return -1;
}

// Read whatever is available without blocking. Returns false at EOF.
bool drain(int fd, std::string& into) {
    // Per thread, on the heap: 64 KB of stack is too much for the small
    // stacks async tasks and generators run on (round 76).
    static thread_local std::vector<char> buf(65536);
    while (true) {
        ssize_t n = ::read(fd, buf.data(), buf.size());
        if (n > 0) { into.append(buf.data(), (size_t)n); continue; }
        if (n == 0) return false;
        if (errno == EINTR) continue;
        return true;   // EAGAIN: nothing more for now
    }
}

struct Proc {
    int out_fd = -1, err_fd = -1;
    int in_fd = -1;          // os_spawn(..., stdin=true): kept open for os_proc_write
    std::string out{}, err{};
    bool done = false;
    int code = 0;
};
std::map<long long, Proc>& procs() {
    static std::map<long long, Proc> p;
    return p;
}
std::mutex& procs_mutex() {
    static std::mutex m;
    return m;
}

void pump(Proc& p) {
    if (p.out_fd >= 0 && !drain(p.out_fd, p.out)) { ::close(p.out_fd); p.out_fd = -1; }
    if (p.err_fd >= 0 && !drain(p.err_fd, p.err)) { ::close(p.err_fd); p.err_fd = -1; }
}

// true when the process has exited (code set)
bool reap(long long pid, Proc& p) {
    if (p.done) return true;
    int st = 0;
    pid_t r = ::waitpid((pid_t)pid, &st, WNOHANG);
    if (r == (pid_t)pid) {
        p.done = true;
        p.code = decode_status(st);
        // Collect what is still buffered in the pipes.
        for (int k = 0; k < 50 && (p.out_fd >= 0 || p.err_fd >= 0); k++) {
            pump(p);
            if (p.out_fd >= 0 || p.err_fd >= 0) std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        if (p.out_fd >= 0) { ::close(p.out_fd); p.out_fd = -1; }
        if (p.err_fd >= 0) { ::close(p.err_fd); p.err_fd = -1; }
        if (p.in_fd >= 0) { ::close(p.in_fd); p.in_fd = -1; }
        return true;
    }
    if (r < 0 && errno == ECHILD) { p.done = true; p.code = -1; return true; }
    return false;
}

#endif  // !_WIN32

#ifdef _WIN32
// ── Windows: the same process layer on Win32 ────────────────────────────────
// CreateProcessW with pipes for stdin/stdout/stderr, each process in its own
// Job Object (os_kill ends the whole tree, as a POSIX process group does),
// non-blocking reads through PeekNamedPipe. Command STRINGS run through a
// POSIX sh when there is one - NY_SH, sh.exe on PATH, or Git for Windows /
// MSYS2 in their usual places - so the same shell text works on every
// platform (the IDE's git, build and tool command lines are POSIX); without
// one they go to cmd.exe. NY_SH=cmd forces cmd.exe.
std::wstring widen(const std::string& s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

bool is_file_w(const std::string& p) {
    DWORD a = GetFileAttributesW(widen(p).c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

const std::string& posix_sh() {
    static std::string sh;
    static std::once_flag once;
    std::call_once(once, [] {
        const char* e = std::getenv("NY_SH");
        if (e && *e) {
            if (!std::strcmp(e, "cmd")) return;
            if (is_file_w(e)) { sh = e; return; }
        }
        const char* path = std::getenv("PATH");
        std::string dirs = path ? path : "", cur;
        for (char ch : dirs + ";") {
            if (ch != ';') { cur += ch; continue; }
            if (!cur.empty() && is_file_w(cur + "\\sh.exe")) { sh = cur + "\\sh.exe"; return; }
            cur.clear();
        }
        std::vector<std::string> roots;
        for (const char* v : {"ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"})
            if (const char* r = std::getenv(v)) roots.push_back(std::string(r) + "\\Git");
        if (const char* la = std::getenv("LOCALAPPDATA")) roots.push_back(std::string(la) + "\\Programs\\Git");
        roots.push_back("C:\\msys64");
        for (auto& r : roots)
            for (const char* sub : {"\\bin\\sh.exe", "\\usr\\bin\\sh.exe"})
                if (is_file_w(r + sub)) { sh = r + sub; return; }
    });
    return sh;
}

std::string win_cmdline(const Cmd& c) {
    std::vector<std::string> argv;
    if (c.shell) {
        const std::string& sh = posix_sh();
        if (sh.empty()) {
            // cmd.exe /s /c "...": the outer quotes go, the rest runs as typed.
            const char* comspec = std::getenv("ComSpec");
            return quote_arg(comspec && *comspec ? comspec : "cmd.exe") + " /d /s /c \"" + c.line + "\"";
        }
        argv = {sh, "-c", c.line};
    } else {
        argv = c.argv;
    }
    std::string line;
    for (size_t i = 0; i < argv.size(); i++) { if (i) line += ' '; line += quote_arg(argv[i]); }
    return line;
}

// The child's environment block: ours with `env` over it (names compare
// without case, as Windows does), sorted as CreateProcess expects.
std::wstring env_block(const std::vector<std::pair<std::string, std::string>>& env) {
    std::vector<std::wstring> vars;
    LPWCH cur = GetEnvironmentStringsW();
    for (LPWCH q = cur; q && *q; q += wcslen(q) + 1) vars.push_back(q);
    if (cur) FreeEnvironmentStringsW(cur);
    auto name_of = [](const std::wstring& kv) { return kv.substr(0, kv.find(L'=', 1)); };
    for (auto& o : env) {
        std::wstring k = widen(o.first);
        vars.erase(std::remove_if(vars.begin(), vars.end(),
                   [&](const std::wstring& v) { return _wcsicmp(name_of(v).c_str(), k.c_str()) == 0; }), vars.end());
        vars.push_back(k + L"=" + widen(o.second));
    }
    std::sort(vars.begin(), vars.end(), [&](const std::wstring& a, const std::wstring& b) {
        return _wcsicmp(name_of(a).c_str(), name_of(b).c_str()) < 0;
    });
    std::wstring block;
    for (auto& v : vars) { block += v; block.push_back(L'\0'); }
    block.push_back(L'\0');
    return block;
}

void close_h(HANDLE& h) {
    if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
    h = INVALID_HANDLE_VALUE;
}

struct WinChild {
    long long pid = -1;
    HANDLE in = INVALID_HANDLE_VALUE, out = INVALID_HANDLE_VALUE, err = INVALID_HANDLE_VALUE;
    HANDLE proc = nullptr, job = nullptr;
};

// Starts the process suspended, puts it in a new job, then lets it run.
// `merge` sends its stderr into the stdout pipe (subprocess's
// stderr=STDOUT). Raises when the program cannot be started.
WinChild start_process(const Cmd& c, const std::string& cwd,
                       const std::vector<std::pair<std::string, std::string>>& env,
                       bool want_stdin, bool merge) {
    // One spawn at a time: every pipe end a child may inherit exists only
    // while its own CreateProcess runs, so no child inherits another's.
    static std::mutex spawn_mutex;
    std::lock_guard<std::mutex> lk(spawn_mutex);
    SECURITY_ATTRIBUTES sa{sizeof(SECURITY_ATTRIBUTES), nullptr, 1};   // inheritable (TRUE is #undef-ed: NodeType::TRUE)
    HANDLE in_r = INVALID_HANDLE_VALUE, in_w = INVALID_HANDLE_VALUE;
    HANDLE out_r = INVALID_HANDLE_VALUE, out_w = INVALID_HANDLE_VALUE;
    HANDLE err_r = INVALID_HANDLE_VALUE, err_w = INVALID_HANDLE_VALUE;
    auto close_all = [&] { close_h(in_r); close_h(in_w); close_h(out_r); close_h(out_w); close_h(err_r); close_h(err_w); };
    bool ok = CreatePipe(&out_r, &out_w, &sa, 0) && SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    if (ok && !merge) ok = CreatePipe(&err_r, &err_w, &sa, 0) && SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
    if (ok && want_stdin) ok = CreatePipe(&in_r, &in_w, &sa, 0) && SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    if (ok && !want_stdin) {
        in_r = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);
        ok = in_r != INVALID_HANDLE_VALUE;
    }
    if (!ok) { close_all(); raise("OSError", "cannot create pipes for a child process"); }
    STARTUPINFOW si{};
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = merge ? out_w : err_w;
    PROCESS_INFORMATION pi{};
    std::wstring cl = widen(win_cmdline(c));
    std::vector<wchar_t> clbuf(cl.begin(), cl.end());
    clbuf.push_back(L'\0');
    std::wstring wcwd = widen(cwd), envb;
    if (!env.empty()) envb = env_block(env);
    // No console window flashes up when the (GUI) IDE runs a console program.
    DWORD flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
    BOOL created = CreateProcessW(nullptr, clbuf.data(), nullptr, nullptr, 1, flags,
                                  env.empty() ? nullptr : (LPVOID)envb.data(),
                                  cwd.empty() ? nullptr : wcwd.c_str(), &si, &pi);
    DWORD e = created ? 0 : GetLastError();
    close_h(in_r); close_h(out_w); close_h(err_w);    // the child's ends
    if (!created) {
        close_all();
        if (!cwd.empty() && GetFileAttributesW(wcwd.c_str()) == INVALID_FILE_ATTRIBUTES) raise_errno(ENOENT, cwd);
        std::string prog = c.shell ? (posix_sh().empty() ? std::string("cmd.exe") : posix_sh()) : c.argv[0];
        raise_errno(e == ERROR_ACCESS_DENIED ? EACCES : ENOENT, prog);
    }
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (job && !AssignProcessToJobObject(job, pi.hProcess)) { CloseHandle(job); job = nullptr; }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);
    WinChild ch;
    ch.pid = (long long)pi.dwProcessId;
    ch.in = want_stdin ? in_w : INVALID_HANDLE_VALUE;
    ch.out = out_r;
    ch.err = merge ? INVALID_HANDLE_VALUE : err_r;
    ch.proc = pi.hProcess;
    ch.job = job;
    return ch;
}

// Read whatever is available without blocking. Returns false at EOF.
bool drain(HANDLE h, std::string& into) {
    // Per thread, on the heap (see the POSIX drain above).
    static thread_local std::vector<char> buf_v(65536);
    char* buf = buf_v.data();
    const size_t buf_size = buf_v.size();
    while (true) {
        DWORD avail = 0;
        if (!PeekNamedPipe(h, nullptr, 0, nullptr, &avail, nullptr)) return false;   // broken pipe: EOF
        if (avail == 0) return true;
        DWORD n = 0;
        if (!ReadFile(h, buf, avail < buf_size ? avail : (DWORD)buf_size, &n, nullptr)) return false;
        into.append(buf, n);
    }
}

// Writes `data` to a child's stdin from a thread of its own and closes it, so
// a child that writes a lot before reading cannot deadlock the caller.
std::thread feed_stdin(HANDLE in, std::string data) {
    return std::thread([in, data = std::move(data)]() mutable {
        size_t off = 0;
        while (off < data.size()) {
            DWORD w = 0;
            DWORD chunk = (DWORD)std::min<size_t>(data.size() - off, (size_t)1 << 20);
            if (!WriteFile(in, data.data() + off, chunk, &w, nullptr) || w == 0) break;
            off += w;
        }
        CloseHandle(in);
    });
}

// A child's text output reads with "\n" line ends, as Python's text mode
// reads it (universal newlines: "\r\n" and a lone "\r" are "\n"). Windows
// programs write "\r\n"; without this every captured line ended in "\r"
// (round 77). `cr`: the chunk before ended in "\r" (its "\n" may come next).
std::string text_newlines(const std::string& s, bool& cr, bool final) {
    std::string r;
    r.reserve(s.size());
    for (char ch : s) {
        if (cr) { cr = false; r += '\n'; if (ch == '\n') continue; }
        if (ch == '\r') { cr = true; continue; }
        r += ch;
    }
    if (final && cr) { cr = false; r += '\n'; }
    return r;
}

struct Proc {
    HANDLE out_h = INVALID_HANDLE_VALUE, err_h = INVALID_HANDLE_VALUE;
    HANDLE in_h = INVALID_HANDLE_VALUE;   // os_spawn(..., stdin=true)
    HANDLE proc = nullptr, job = nullptr;
    std::string out{}, err{};
    bool out_cr = false, err_cr = false;   // text_newlines carry-over
    bool done = false;
    int code = 0;
    int killed_sig = 0;    // reported as -sig, as a signal is on POSIX
};
std::map<long long, Proc>& procs() {
    static std::map<long long, Proc> p;
    return p;
}
std::mutex& procs_mutex() {
    static std::mutex m;
    return m;
}

void pump(Proc& p) {
    if (p.out_h != INVALID_HANDLE_VALUE && !drain(p.out_h, p.out)) close_h(p.out_h);
    if (p.err_h != INVALID_HANDLE_VALUE && !drain(p.err_h, p.err)) close_h(p.err_h);
}

// true when the process has exited (code set)
bool reap(long long, Proc& p) {
    if (p.done) return true;
    if (!p.proc || WaitForSingleObject(p.proc, 0) != WAIT_OBJECT_0) return false;
    DWORD code = 0;
    GetExitCodeProcess(p.proc, &code);
    p.done = true;
    p.code = p.killed_sig ? -p.killed_sig : (int)code;
    for (int k = 0; k < 50 && (p.out_h != INVALID_HANDLE_VALUE || p.err_h != INVALID_HANDLE_VALUE); k++) {
        pump(p);
        if (p.out_h != INVALID_HANDLE_VALUE || p.err_h != INVALID_HANDLE_VALUE) Sleep(2);
    }
    close_h(p.out_h);
    close_h(p.err_h);
    close_h(p.in_h);
    CloseHandle(p.proc);
    p.proc = nullptr;
    if (p.job) { CloseHandle(p.job); p.job = nullptr; }
    return true;
}

// Runs a child to completion: output collected, input fed, the whole tree
// ended if `timeout` (seconds, > 0) expires. The GIL is released while it
// waits.
void run_to_end(const Cmd& c, const std::string& cwd,
                const std::vector<std::pair<std::string, std::string>>& env,
                bool has_input, const std::string& input, bool merge, double timeout,
                std::string& out, std::string& err, int& code, bool& timed_out) {
    WinChild ch = start_process(c, cwd, env, has_input, merge);
    std::thread writer;
    if (ch.in != INVALID_HANDLE_VALUE) {
        if (input.empty()) close_h(ch.in);
        else { writer = feed_stdin(ch.in, input); ch.in = INVALID_HANDLE_VALUE; }
    }
    double deadline = timeout > 0 ? now_s() + timeout : -1;
    timed_out = false;
    while (true) {
        if (ch.out != INVALID_HANDLE_VALUE && !drain(ch.out, out)) close_h(ch.out);
        if (ch.err != INVALID_HANDLE_VALUE && !drain(ch.err, err)) close_h(ch.err);
        DWORD w;
        { nyconc::GilRelease unlocked; w = WaitForSingleObject(ch.proc, 5); }
        if (w == WAIT_OBJECT_0) break;
        if (deadline > 0 && now_s() >= deadline) {
            timed_out = true;
            if (ch.job) TerminateJobObject(ch.job, 1); else TerminateProcess(ch.proc, 1);
            nyconc::GilRelease unlocked;
            WaitForSingleObject(ch.proc, INFINITE);
            break;
        }
    }
    for (int k = 0; k < 50 && (ch.out != INVALID_HANDLE_VALUE || ch.err != INVALID_HANDLE_VALUE); k++) {
        if (ch.out != INVALID_HANDLE_VALUE && !drain(ch.out, out)) close_h(ch.out);
        if (ch.err != INVALID_HANDLE_VALUE && !drain(ch.err, err)) close_h(ch.err);
        if (ch.out != INVALID_HANDLE_VALUE || ch.err != INVALID_HANDLE_VALUE) Sleep(2);
    }
    close_h(ch.out);
    close_h(ch.err);
    {
        bool cr = false;
        out = text_newlines(out, cr, true);
        cr = false;
        err = text_newlines(err, cr, true);
    }
    if (writer.joinable()) { nyconc::GilRelease unlocked; writer.join(); }
    DWORD ec = 0;
    GetExitCodeProcess(ch.proc, &ec);
    code = timed_out ? -9 : (int)ec;
    CloseHandle(ch.proc);
    if (ch.job) CloseHandle(ch.job);
}
#endif  // _WIN32

Value run(NythonExecutor& E, std::vector<Value>& args) {
    nyos::Args A(E, args, {"cwd", "env", "input", "timeout", "shell", "check", "merge"});
    if (!A.has(0, "cmd")) raise("TypeError", "os_run() missing the command");
    Cmd c = parse_cmd(E, A.get(0, "cmd"));
    std::string cwd = A.str(1, "cwd", "");
    auto env = A.has(2, "env") ? parse_env(E, A.get(2, "env")) : std::vector<std::pair<std::string, std::string>>{};
    bool has_input = A.has(3, "input");
    std::string input = A.str(3, "input", "");
    double timeout = A.num(4, "timeout", -1.0);
    bool check = A.flag(99, "check", false);
    bool merge = A.flag(99, "merge", false);     // stderr into stdout, in order
    std::string out, err;
    int code = -1;
#ifndef _WIN32
    int in_fd, out_fd, err_fd;
    pid_t pid = start_process(c, cwd, env, has_input, in_fd, out_fd, err_fd, merge);
    size_t written = 0;
    if (in_fd >= 0 && input.empty()) { ::close(in_fd); in_fd = -1; }
    double deadline = timeout > 0 ? now_s() + timeout : -1;
    bool timed_out = false;
    while (out_fd >= 0 || err_fd >= 0 || in_fd >= 0) {
        struct pollfd fds[3];
        int nf = 0;
        int i_out = -1, i_err = -1, i_in = -1;
        if (out_fd >= 0) { fds[nf] = {out_fd, POLLIN, 0}; i_out = nf++; }
        if (err_fd >= 0) { fds[nf] = {err_fd, POLLIN, 0}; i_err = nf++; }
        if (in_fd >= 0)  { fds[nf] = {in_fd, POLLOUT, 0}; i_in = nf++; }
        int wait_ms = 200;
        if (deadline > 0) {
            double left = deadline - now_s();
            if (left <= 0) { timed_out = true; break; }
            wait_ms = (int)std::min(200.0, left * 1000.0 + 1);
        }
        int r;
        { nyconc::GilRelease unlocked; r = ::poll(fds, (nfds_t)nf, wait_ms); }
        if (r < 0 && errno != EINTR) break;
        if (r <= 0) continue;
        if (i_out >= 0 && (fds[i_out].revents & (POLLIN | POLLHUP | POLLERR))) {
            if (!drain(out_fd, out)) { ::close(out_fd); out_fd = -1; }
        }
        if (i_err >= 0 && (fds[i_err].revents & (POLLIN | POLLHUP | POLLERR))) {
            if (!drain(err_fd, err)) { ::close(err_fd); err_fd = -1; }
        }
        if (i_in >= 0 && (fds[i_in].revents & (POLLOUT | POLLERR | POLLHUP))) {
            if (fds[i_in].revents & (POLLERR | POLLHUP)) { ::close(in_fd); in_fd = -1; }
            else {
                ssize_t w = ::write(in_fd, input.data() + written, input.size() - written);
                if (w > 0) written += (size_t)w;
                else if (w < 0 && errno != EAGAIN && errno != EINTR) { ::close(in_fd); in_fd = -1; }
                if (in_fd >= 0 && written >= input.size()) { ::close(in_fd); in_fd = -1; }
            }
        }
    }
    if (timed_out) {
        ::kill(-pid, SIGKILL);
        ::kill(pid, SIGKILL);
        if (in_fd >= 0) ::close(in_fd);
        if (out_fd >= 0) { drain(out_fd, out); ::close(out_fd); }
        if (err_fd >= 0) { drain(err_fd, err); ::close(err_fd); }
    }
    int st = 0;
    { nyconc::GilRelease unlocked; while (::waitpid(pid, &st, 0) < 0 && errno == EINTR) {} }
    code = decode_status(st);
    if (timed_out) {
        std::ostringstream m;
        m << "command timed out after " << timeout << " seconds";
        raise("TimeoutError", m.str());
    }
#else
    bool timed_out = false;
    run_to_end(c, cwd, env, has_input, input, merge, timeout, out, err, code, timed_out);
    if (timed_out) {
        std::ostringstream m;
        m << "command timed out after " << timeout << " seconds";
        raise("TimeoutError", m.str());
    }
#endif
    if (check && code != 0)
        raise("ChildProcessError", "command returned non-zero exit status " + std::to_string(code));
    return nyos::make_map(E, {
        {"code",   Value(code)},
        {"stdout", E.makeStringValue(out)},
        {"stderr", E.makeStringValue(err)},
        {"ok",     Value(code == 0)},
    });
}

// Legacy capture: the command's standard output (its stderr goes to ours).
// On Windows through the same shell choice as os_run, not _popen's cmd.exe,
// so POSIX command text works there too.
std::string capture(const std::string& cmd, bool strip) {
#ifdef _WIN32
    Cmd c;
    c.shell = true;
    c.line = cmd;
    std::string out, err;
    int code = 0;
    bool timed_out = false;
    try {
        run_to_end(c, "", {}, false, "", false, -1, out, err, code, timed_out);
    } catch (...) {
        return std::string();
    }
    if (!err.empty()) { std::fwrite(err.data(), 1, err.size(), stderr); std::fflush(stderr); }
    if (strip) while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    return out;
#else
    return capture_popen(cmd, strip);
#endif
}

} // namespace

Value dispatch_os_proc(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx) {
    (void)ctx;
    auto S = [&](size_t i, const std::string& d = "") -> std::string {
        return (i < args.size() && args[i].type != ValueType::NONE) ? E.getStringValue(args[i]) : d;
    };
    auto Str = [&](const std::string& s) { return E.makeStringValue(s); };

    // ── Legacy shell capture ─────────────────────────────────────────────────
    // The VM had its own shell/system/cmd returning the raw wait status (768
    // for exit 3) while printing the output; both engines now return the
    // captured standard output, as the interpreter always did.
    if (name == "os_exec" || name == "popen" || name == "exec_cmd" || name == "sh"
        || name == "shell" || name == "system" || name == "cmd") {
        if (args.empty()) return name == "os_exec" ? Str("") : NONE_VALUE;
        return Str(capture(S(0), true));
    }
    if (name == "process_exec") {
        // stdout and stderr together. The "2>&1" used to be appended to the
        // command text, so it only applied to its LAST simple command.
        if (args.empty()) return Str("");
#ifdef _WIN32
        // stderr merged at the pipe: " 2>&1" on the text only redirected
        // its last command.
        Cmd c;
        c.shell = true;
        c.line = S(0);
        std::string out, err;
        int code = 0;
        bool timed_out = false;
        run_to_end(c, "", {}, false, "", true, -1, out, err, code, timed_out);
        return Str(out);
#else
        return Str(capture("{ " + S(0) + "\n} 2>&1", false));
#endif
    }
    if (name == "os_system") {
        if (args.empty()) return Value(0);
        std::fflush(stdout);
        std::cout.flush();
        int st = std::system(S(0).c_str());
#ifndef _WIN32
        return Value(st == -1 ? -1 : decode_status(st));
#else
        return Value(st);
#endif
    }
    if (name == "os_run" || name == "subprocess_run") return run(E, args);

    // ── Background processes ─────────────────────────────────────────────────
    if (name == "os_spawn") {
#ifdef _WIN32
        nyos::Args A(E, args, {"cwd", "env", "input", "merge", "stdin"});
        if (!A.has(0, "cmd")) raise("TypeError", "os_spawn() missing the command");
        Cmd c = parse_cmd(E, A.get(0, "cmd"));
        auto env = A.has(2, "env") ? parse_env(E, A.get(2, "env")) : std::vector<std::pair<std::string, std::string>>{};
        bool keep_stdin = A.flag(99, "stdin", false);
        bool has_input = A.has(3, "input") || keep_stdin;
        std::string input = A.str(3, "input", "");
        WinChild ch = start_process(c, A.str(1, "cwd", ""), env, has_input, A.flag(99, "merge", false));
        HANDLE kept_in = INVALID_HANDLE_VALUE;
        if (ch.in != INVALID_HANDLE_VALUE) {
            if (keep_stdin) {
                kept_in = ch.in;
                if (!input.empty()) { DWORD w = 0; WriteFile(kept_in, input.data(), (DWORD)input.size(), &w, nullptr); }
            }
            else if (input.empty()) close_h(ch.in);
            else feed_stdin(ch.in, input).detach();
        }
        std::lock_guard<std::mutex> lk(procs_mutex());
        Proc p;
        p.in_h = kept_in;
        p.out_h = ch.out;
        p.err_h = ch.err;
        p.proc = ch.proc;
        p.job = ch.job;
        procs()[ch.pid] = std::move(p);
        return Value((int)ch.pid);
#else
        nyos::Args A(E, args, {"cwd", "env", "input", "merge", "stdin"});
        if (!A.has(0, "cmd")) raise("TypeError", "os_spawn() missing the command");
        Cmd c = parse_cmd(E, A.get(0, "cmd"));
        auto env = A.has(2, "env") ? parse_env(E, A.get(2, "env")) : std::vector<std::pair<std::string, std::string>>{};
        bool keep_stdin = A.flag(99, "stdin", false);
        bool has_input = A.has(3, "input") || keep_stdin;
        std::string input = A.str(3, "input", "");
        int in_fd, out_fd, err_fd;
        pid_t pid = start_process(c, A.str(1, "cwd", ""), env, has_input, in_fd, out_fd, err_fd, A.flag(99, "merge", false));
        int kept_in = -1;
        if (in_fd >= 0 && keep_stdin) {
            // stdin stays open: os_proc_write feeds it, os_proc_close_stdin ends it
            fcntl(in_fd, F_SETFL, fcntl(in_fd, F_GETFL) & ~O_NONBLOCK);
            fcntl(in_fd, F_SETFD, FD_CLOEXEC);
            kept_in = in_fd;
            size_t off = 0;
            while (off < input.size()) {
                ssize_t w = ::write(in_fd, input.data() + off, input.size() - off);
                if (w <= 0) break;
                off += (size_t)w;
            }
        } else if (in_fd >= 0) {
            // Small inputs fit the pipe; larger ones are written as the child
            // reads, bounded so a child that never reads cannot hang us.
            fcntl(in_fd, F_SETFL, fcntl(in_fd, F_GETFL) & ~O_NONBLOCK);
            size_t off = 0;
            while (off < input.size()) {
                ssize_t w = ::write(in_fd, input.data() + off, input.size() - off);
                if (w <= 0) break;
                off += (size_t)w;
            }
            ::close(in_fd);
        }
        std::lock_guard<std::mutex> lk(procs_mutex());
        Proc p;
        p.out_fd = out_fd;
        p.err_fd = err_fd;
        p.in_fd = kept_in;
        procs()[(long long)pid] = std::move(p);
        return Value((int)pid);
#endif
    }
    // A running process's stdin (os_spawn(..., stdin=true)): text written
    // to it, then closed for end-of-input (round 77: the IDE's Run takes
    // the program's input this way).
    if (name == "os_proc_write" || name == "os_proc_close_stdin") {
        long long pid = args.size() > 0 ? nyos::to_int(args[0], -1) : -1;
        std::string data = args.size() > 1 ? E.getStringValue(args[1]) : std::string();
        std::unique_lock<std::mutex> lk(procs_mutex());
        auto it = procs().find(pid);
        if (it == procs().end()) raise("ChildProcessError", "no child process with pid " + std::to_string(pid) + " was started by os_spawn");
        Proc& p = it->second;
#ifdef _WIN32
        if (name == "os_proc_close_stdin") { close_h(p.in_h); return NONE_VALUE; }
        if (p.in_h == INVALID_HANDLE_VALUE) raise("OSError", "the process's stdin is not open (os_spawn(..., stdin=true))");
        // A duplicate, so a close or reap on another thread while this one
        // writes cannot hand the write a recycled handle.
        HANDLE h = INVALID_HANDLE_VALUE;
        if (!DuplicateHandle(GetCurrentProcess(), p.in_h, GetCurrentProcess(), &h, 0, 0 /* not inheritable */, DUPLICATE_SAME_ACCESS))
            raise("OSError", "the process's stdin cannot be written");
        lk.unlock();
        DWORD w = 0;
        BOOL ok;
        {
            nyconc::GilRelease rel;
            ok = WriteFile(h, data.data(), (DWORD)data.size(), &w, nullptr);
        }
        CloseHandle(h);
        if (!ok) raise("BrokenPipeError", "the process has closed its input");
        return Value((int64_t)w);
#else
        if (name == "os_proc_close_stdin") { if (p.in_fd >= 0) { ::close(p.in_fd); p.in_fd = -1; } return NONE_VALUE; }
        if (p.in_fd < 0) raise("OSError", "the process's stdin is not open (os_spawn(..., stdin=true))");
        // A duplicate, so a close or reap on another thread while this one
        // writes cannot hand the write a recycled descriptor.
        int fd = ::fcntl(p.in_fd, F_DUPFD_CLOEXEC, 0);
        if (fd < 0) raise_errno(errno, "stdin");
        lk.unlock();
        size_t off = 0;
        {
            nyconc::GilRelease rel;
            while (off < data.size()) {
                ssize_t w = ::write(fd, data.data() + off, data.size() - off);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) break;
                off += (size_t)w;
            }
        }
        ::close(fd);
        if (off < data.size()) raise("BrokenPipeError", "the process has closed its input");
        return Value((int64_t)off);
#endif
    }
    if (name == "os_proc_read" || name == "os_poll" || name == "os_wait") {
        nyos::Args A(E, args, {"timeout"});
        long long pid = A.integer(0, "pid", -1);
        std::unique_lock<std::mutex> lk(procs_mutex());
        auto it = procs().find(pid);
        if (it == procs().end()) raise("ChildProcessError", "no child process with pid " + std::to_string(pid) + " was started by os_spawn");
        Proc& p = it->second;
        if (name == "os_proc_read") {
            pump(p);
            reap(pid, p);
#ifdef _WIN32
            p.out = text_newlines(p.out, p.out_cr, p.done);
            p.err = text_newlines(p.err, p.err_cr, p.done);
#endif
            Value r = nyos::make_map(E, {{"stdout", Str(p.out)}, {"stderr", Str(p.err)}, {"done", Value(p.done)}});
            p.out.clear();
            p.err.clear();
            return r;
        }
        if (name == "os_poll") {
            pump(p);
            if (reap(pid, p)) return Value(p.code);
            return NONE_VALUE;
        }
        // os_wait
        double timeout = A.num(1, "timeout", -1.0);
        double deadline = timeout >= 0 ? now_s() + timeout : -1;
        while (true) {
            pump(p);
            if (reap(pid, p)) return Value(p.code);
            if (deadline >= 0 && now_s() >= deadline) {
                std::ostringstream m;
                m << "process " << pid << " still running after " << timeout << " seconds";
                raise("TimeoutError", m.str());
            }
            lk.unlock();
            { nyconc::GilRelease unlocked; std::this_thread::sleep_for(std::chrono::milliseconds(5)); }
            lk.lock();
            it = procs().find(pid);
            if (it == procs().end()) raise("ChildProcessError", "process table changed while waiting");
        }
    }
    if (name == "os_kill") {
        nyos::Args A(E, args, {"sig"});
        long long pid = A.integer(0, "pid", -1);
        int sig = (int)A.integer(1, "sig", 15);
        if (pid <= 0) raise("ValueError", "os_kill(): invalid pid " + std::to_string(pid));
#ifdef _WIN32
        // A process os_spawn started is ended with its whole job (the tree it
        // started), as a POSIX process group; it then reports -sig. sig 0
        // only asks whether the process is alive.
        {
            std::lock_guard<std::mutex> lk(procs_mutex());
            auto it = procs().find(pid);
            if (it != procs().end() && !it->second.done && it->second.proc) {
                Proc& p = it->second;
                if (sig == 0) return Value(WaitForSingleObject(p.proc, 0) == WAIT_TIMEOUT);
                p.killed_sig = sig;
                BOOL ok = p.job ? TerminateJobObject(p.job, 1) : TerminateProcess(p.proc, 1);
                return Value(ok != 0);
            }
        }
        HANDLE h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, 0, (DWORD)pid);
        if (!h) return Value(false);
        BOOL ok = sig == 0 ? WaitForSingleObject(h, 0) == WAIT_TIMEOUT : TerminateProcess(h, 1);
        CloseHandle(h);
        return Value(ok != 0);
#else
        bool ours;
        {
            std::lock_guard<std::mutex> lk(procs_mutex());
            ours = procs().count(pid) > 0;
        }
        // A process os_spawn started leads its own process group, so the
        // whole tree it started goes with it.
        if (ours && ::kill(-(pid_t)pid, sig) == 0) return Value(true);
        return Value(::kill((pid_t)pid, sig) == 0);
#endif
    }
    if (name == "os_getpid") {
#ifdef _WIN32
        return Value((int)_getpid());
#else
        return Value((int)::getpid());
#endif
    }
    if (name == "os_getppid") {
#ifdef _WIN32
        // The parent's pid from a process snapshot, as Python's os.getppid.
        DWORD me = GetCurrentProcessId(), parent = 0;
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap != INVALID_HANDLE_VALUE) {
            PROCESSENTRY32W pe{};
            pe.dwSize = sizeof pe;
            for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe))
                if (pe.th32ProcessID == me) { parent = pe.th32ParentProcessID; break; }
            CloseHandle(snap);
        }
        return Value((int)parent);
#else
        return Value((int)::getppid());
#endif
    }

    // ── Helpers ──────────────────────────────────────────────────────────────
    // Quoted for the shell that runs command strings (os_shell()): a POSIX
    // sh on Linux and macOS, and on Windows too when one was found; cmd.exe
    // rules otherwise.
    if (name == "shell_quote" || name == "os_shell_quote") {
#ifdef _WIN32
        return Str(posix_sh().empty() ? quote_arg(S(0)) : quote_posix(S(0)));
#else
        return Str(quote_posix(S(0)));
#endif
    }
    // os_shell() -> the program that runs command strings: /bin/sh, or on
    // Windows the POSIX sh found (NY_SH, PATH, Git for Windows, MSYS2) or
    // cmd.exe when there is none.
    if (name == "os_shell") {
#ifdef _WIN32
        if (!posix_sh().empty()) return Str(posix_sh());
        const char* comspec = std::getenv("ComSpec");
        return Str(comspec && *comspec ? comspec : "cmd.exe");
#else
        return Str("/bin/sh");
#endif
    }
    if (name == "which" || name == "os_which") {
        std::string prog = S(0);
        if (prog.empty()) return NONE_VALUE;
        auto runnable = [](const std::string& p) {
            struct stat st;
            if (::stat(p.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) return false;
#ifdef _WIN32
            return true;
#else
            return ::access(p.c_str(), X_OK) == 0;
#endif
        };
        std::vector<std::string> exts = {""};
#ifdef _WIN32
        const char* pe = std::getenv("PATHEXT");
        std::string pathext = pe ? pe : ".COM;.EXE;.BAT;.CMD";
        std::string cur;
        for (char ch : pathext + ";") { if (ch == ';') { if (!cur.empty()) exts.push_back(cur); cur.clear(); } else cur += ch; }
        const char psep = ';';
#else
        const char psep = ':';
#endif
        if (prog.find('/') != std::string::npos || prog.find('\\') != std::string::npos) {
            for (auto& e : exts) if (runnable(prog + e)) return Str(prog + e);
            return NONE_VALUE;
        }
        const char* path = std::getenv("PATH");
        std::string dirs = path ? path : "";
        std::string dir;
        for (size_t i = 0; i <= dirs.size(); i++) {
            if (i == dirs.size() || dirs[i] == psep) {
                std::string d = dir.empty() ? "." : dir;
                for (auto& e : exts) {
                    std::string cand = nyos::join(d, prog + e);
                    if (runnable(cand)) return Str(cand);
                }
                dir.clear();
            } else dir += dirs[i];
        }
        return NONE_VALUE;
    }
    if (name == "sys_argv") return nyos::make_str_list(E, nyrt::argv());

    return UNDEFINED_VALUE;
}

#pragma GCC diagnostic pop
