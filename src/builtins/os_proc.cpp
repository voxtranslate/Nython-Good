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
// Windows: os_run goes through the shell (_popen) with stderr and stdin
// redirected through temporary files; timeout is not enforced there and
// os_spawn/os_poll/os_wait/os_kill are not supported yet (they raise).
// ─────────────────────────────────────────────────────────────────────────────

#include "platform_compat.hpp"

#include <chrono>
#include <thread>
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
#endif

using namespace std;
using namespace nython;
using namespace nython::kernel;

namespace {

using nyos::raise;
using nyos::raise_errno;

// Legacy stdout capture through the shell. fread keeps NUL bytes (fgets cut
// the output at the first one); trailing "\n" and "\r" are stripped.
std::string capture(const std::string& cmd, bool strip) {
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
                    bool want_stdin, int& in_fd, int& out_fd, int& err_fd) {
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
        ::dup2(err_p[1], 2);
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
    char buf[65536];
    while (true) {
        ssize_t n = ::read(fd, buf, sizeof buf);
        if (n > 0) { into.append(buf, (size_t)n); continue; }
        if (n == 0) return false;
        if (errno == EINTR) continue;
        return true;   // EAGAIN: nothing more for now
    }
}

struct Proc {
    int out_fd = -1, err_fd = -1;
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
        return true;
    }
    if (r < 0 && errno == ECHILD) { p.done = true; p.code = -1; return true; }
    return false;
}

#endif  // !_WIN32

Value run(NythonExecutor& E, std::vector<Value>& args) {
    nyos::Args A(E, args, {"cwd", "env", "input", "timeout", "shell", "check"});
    if (!A.has(0, "cmd")) raise("TypeError", "os_run() missing the command");
    Cmd c = parse_cmd(E, A.get(0, "cmd"));
    std::string cwd = A.str(1, "cwd", "");
    auto env = A.has(2, "env") ? parse_env(E, A.get(2, "env")) : std::vector<std::pair<std::string, std::string>>{};
    bool has_input = A.has(3, "input");
    std::string input = A.str(3, "input", "");
    double timeout = A.num(4, "timeout", -1.0);
    bool check = A.flag(99, "check", false);
    std::string out, err;
    int code = -1;
#ifndef _WIN32
    int in_fd, out_fd, err_fd;
    pid_t pid = start_process(c, cwd, env, has_input, in_fd, out_fd, err_fd);
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
        int r = ::poll(fds, (nfds_t)nf, wait_ms);
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
    while (::waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    code = decode_status(st);
    if (timed_out) {
        std::ostringstream m;
        m << "command timed out after " << timeout << " seconds";
        raise("TimeoutError", m.str());
    }
#else
    std::string line;
    if (c.shell) line = c.line;
    else for (size_t i = 0; i < c.argv.size(); i++) { if (i) line += " "; line += quote_arg(c.argv[i]); }
    if (!cwd.empty()) line = "cd /d " + quote_arg(cwd) + " && " + line;
    char tmpbuf[L_tmpnam];
    std::string err_path = std::string(std::tmpnam(tmpbuf)) + ".err";
    std::string in_path;
    if (has_input) {
        in_path = std::string(std::tmpnam(tmpbuf)) + ".in";
        std::ofstream f(in_path, std::ios::binary);
        f << input;
        line += " < " + quote_arg(in_path);
    }
    line += " 2> " + quote_arg(err_path);
    std::vector<std::pair<std::string, std::string>> saved;
    for (auto& kv : env) {
        const char* old = std::getenv(kv.first.c_str());
        saved.push_back({kv.first, old ? old : ""});
        _putenv_s(kv.first.c_str(), kv.second.c_str());
    }
    FILE* p = _popen(line.c_str(), "rb");
    if (!p) raise("OSError", "cannot start: " + line);
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
    code = _pclose(p);
    for (auto& kv : saved) _putenv_s(kv.first.c_str(), kv.second.c_str());
    {
        std::ifstream f(err_path, std::ios::binary);
        std::ostringstream ss; ss << f.rdbuf(); err = ss.str();
    }
    std::remove(err_path.c_str());
    if (!in_path.empty()) std::remove(in_path.c_str());
    (void)timeout;
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
        return Str(capture(S(0) + " 2>&1", false));
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
        raise("OSError", "os_spawn is not supported on Windows yet");
#else
        nyos::Args A(E, args, {"cwd", "env", "input"});
        if (!A.has(0, "cmd")) raise("TypeError", "os_spawn() missing the command");
        Cmd c = parse_cmd(E, A.get(0, "cmd"));
        auto env = A.has(2, "env") ? parse_env(E, A.get(2, "env")) : std::vector<std::pair<std::string, std::string>>{};
        bool has_input = A.has(3, "input");
        std::string input = A.str(3, "input", "");
        int in_fd, out_fd, err_fd;
        pid_t pid = start_process(c, A.str(1, "cwd", ""), env, has_input, in_fd, out_fd, err_fd);
        if (in_fd >= 0) {
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
        procs()[(long long)pid] = std::move(p);
        return Value((int)pid);
#endif
    }
    if (name == "os_proc_read" || name == "os_poll" || name == "os_wait") {
#ifdef _WIN32
        raise("OSError", name + " is not supported on Windows yet");
#else
        nyos::Args A(E, args, {"timeout"});
        long long pid = A.integer(0, "pid", -1);
        std::unique_lock<std::mutex> lk(procs_mutex());
        auto it = procs().find(pid);
        if (it == procs().end()) raise("ChildProcessError", "no child process with pid " + std::to_string(pid) + " was started by os_spawn");
        Proc& p = it->second;
        if (name == "os_proc_read") {
            pump(p);
            reap(pid, p);
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
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            lk.lock();
            it = procs().find(pid);
            if (it == procs().end()) raise("ChildProcessError", "process table changed while waiting");
        }
#endif
    }
    if (name == "os_kill") {
        nyos::Args A(E, args, {"sig"});
        long long pid = A.integer(0, "pid", -1);
        int sig = (int)A.integer(1, "sig", 15);
        if (pid <= 0) raise("ValueError", "os_kill(): invalid pid " + std::to_string(pid));
#ifdef _WIN32
        (void)sig;
        raise("OSError", "os_kill is not supported on Windows yet");
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
        return Value(0);
#else
        return Value((int)::getppid());
#endif
    }

    // ── Helpers ──────────────────────────────────────────────────────────────
    if (name == "shell_quote" || name == "os_shell_quote") return Str(quote_arg(S(0)));
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
