// builtins/net.cpp - the socket layer (round 77), one implementation for both
// engines (the VM reaches it through the builtin bridge, as it does the OS
// layer). lib/socket.ny is the Python-shaped module over these _net_*
// natives; lib/select.ny, lib/asyncio.ny, lib/http.ny and lib/websocket.ny
// are built on it.
//
// Every socket is non-blocking underneath. A call that would block waits in
// nyconc::wait_io (src/NyConc.cpp), which does the right thing wherever it
// is called: a thread releases the GIL while it waits (the old natives held
// it, so one recv() froze every thread); an async task parks on its loop's
// poller, so the loop runs its other tasks - the same socket calls serve
// threaded and async code, no separate async API needed; and a signal's
// handler runs, after which the wait resumes (Ctrl+C raises
// KeyboardInterrupt). A socket's timeout (settimeout) is the longest any one
// call may wait: TimeoutError("timed out") then, as in Python.
//
// Errors are Python's: ConnectionRefusedError, ConnectionResetError,
// BrokenPipeError, TimeoutError, BlockingIOError, gaierror ("[Errno -2] Name
// or service not known"), OSError with errno, on Windows too.
//
// Name resolution blocks: a thread releases the GIL around it; an async
// task resolves on a helper thread and parks until it is done (POSIX), so
// the loop keeps running.
// ─────────────────────────────────────────────────────────────────────────────
#include "platform_compat.hpp"
#ifndef _WIN32
#  include <sys/un.h>
#  include <poll.h>
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "NythonExecutor.hpp"
#include "NyConc.hpp"
#include "builtins/os.hpp"
#include "builtins/net.hpp"

namespace nynet {

#ifdef _WIN32
#  define EINPROGRESS_COMPAT WSAEINPROGRESS
using sock_t = SOCKET;
static const sock_t BAD = INVALID_SOCKET;
static int last_err() { return WSAGetLastError(); }
static bool would_block(int e) { return e == WSAEWOULDBLOCK; }
static bool connect_pending(int e) { return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEALREADY; }
static bool interrupted(int e) { return e == WSAEINTR; }
#else
#  define EINPROGRESS_COMPAT EINPROGRESS
using sock_t = int;
static const sock_t BAD = -1;
static int last_err() { return errno; }
static bool would_block(int e) { return e == EAGAIN || e == EWOULDBLOCK; }
static bool connect_pending(int e) { return e == EINPROGRESS || e == EALREADY; }
static bool interrupted(int e) { return e == EINTR; }
#endif

struct Sock {
    sock_t fd = BAD;
    int family = AF_INET, type = SOCK_STREAM, proto = 0;
    double timeout = -1;          // seconds; < 0 blocking, 0 non-blocking
    TlsConn* tls = nullptr;       // set by builtins/tls.cpp
};

static std::mutex& mu() { static std::mutex* m = new std::mutex(); return *m; }
static std::unordered_map<int64_t, std::shared_ptr<Sock>>& table() {
    static auto* t = new std::unordered_map<int64_t, std::shared_ptr<Sock>>();
    return *t;
}
static int64_t g_next = 1;
static double g_default_timeout = -1;

// ── errors ──────────────────────────────────────────────────────────────────
[[noreturn]] void raise(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }

std::string err_text(int e) {
#ifdef _WIN32
    char buf[512] = {0};
    DWORD n = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, (DWORD)e,
                             MAKELANGID(LANG_ENGLISH, SUBLANG_DEFAULT), buf, sizeof buf, nullptr);
    std::string s(buf, n);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ' || s.back() == '.')) s.pop_back();
    return s.empty() ? "socket error " + std::to_string(e) : s;
#else
    return std::strerror(e);
#endif
}

std::string err_type(int e) {
#ifdef _WIN32
    switch (e) {
        case WSAECONNREFUSED: return "ConnectionRefusedError";
        case WSAECONNRESET: return "ConnectionResetError";
        case WSAECONNABORTED: return "ConnectionAbortedError";
        case WSAESHUTDOWN: return "BrokenPipeError";
        case WSAETIMEDOUT: return "TimeoutError";
        case WSAEWOULDBLOCK: return "BlockingIOError";
        case WSAEINTR: return "InterruptedError";
        case WSAEACCES: return "PermissionError";
        default: return "OSError";
    }
#else
    switch (e) {
        case ECONNREFUSED: return "ConnectionRefusedError";
        case ECONNRESET: return "ConnectionResetError";
        case ECONNABORTED: return "ConnectionAbortedError";
        case EPIPE: case ESHUTDOWN: return "BrokenPipeError";
        case ETIMEDOUT: return "TimeoutError";
        case EAGAIN: return "BlockingIOError";
        case EINTR: return "InterruptedError";
        case ENOENT: return "FileNotFoundError";
        case EACCES: case EPERM: return "PermissionError";
        default: return "OSError";
    }
#endif
}

[[noreturn]] void raise_err(int e) {
#ifdef _WIN32
    raise(err_type(e), "[WinError " + std::to_string(e) + "] " + err_text(e));
#else
    raise(err_type(e), "[Errno " + std::to_string(e) + "] " + err_text(e));
#endif
}

[[noreturn]] static void raise_timeout() { raise("TimeoutError", "timed out"); }

// A wait the runtime ended with an error (cancellation, a signal handler's
// exception) - raised as that exception in the interpreter.
static int wait_ready(sock_t fd, int ev, double ms) {
    try { return nyconc::wait_io((intptr_t)fd, ev, ms); }
    catch (nyconc::NyError& err) {
        if (!err.raw.empty()) throw std::string(err.raw);
        throw std::string("__exc__:" + err.type + ":" + err.msg);
    }
}
static void run_signals() {
    try { nyconc::run_signal_handlers(); }
    catch (nyconc::NyError& err) {
        if (!err.raw.empty()) throw std::string(err.raw);
        throw std::string("__exc__:" + err.type + ":" + err.msg);
    }
}

// ── the socket table ────────────────────────────────────────────────────────
std::shared_ptr<Sock> get(int64_t h) {
    std::lock_guard<std::mutex> l(mu());
    auto it = table().find(h);
    if (it == table().end() || it->second->fd == BAD) raise("OSError", "[Errno 9] Bad file descriptor");
    return it->second;
}
static int64_t add(std::shared_ptr<Sock> s) {
    std::lock_guard<std::mutex> l(mu());
    int64_t h = g_next++;
    table()[h] = std::move(s);
    return h;
}
static void set_nonblocking(sock_t fd) {
#ifdef _WIN32
    u_long on = 1;
    ioctlsocket(fd, FIONBIO, &on);
    SetHandleInformation((HANDLE)fd, HANDLE_FLAG_INHERIT, 0);
#else
    ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
    ::fcntl(fd, F_SETFD, FD_CLOEXEC);
#  ifdef SO_NOSIGPIPE
    int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#  endif
#endif
}
static void close_fd(sock_t fd) {
#ifdef _WIN32
    closesocket(fd);
#else
    ::close(fd);
#endif
}

// The time a call may still wait, in ms (< 0: no limit).
struct Clock {
    double timeout;
    std::chrono::steady_clock::time_point end;
    explicit Clock(double t) : timeout(t) {
        if (t > 0) end = std::chrono::steady_clock::now() + std::chrono::microseconds((long long)(t * 1e6));
    }
    double left_ms() const {
        if (timeout < 0) return -1;
        if (timeout == 0) return 0;
        double ms = std::chrono::duration<double, std::milli>(end - std::chrono::steady_clock::now()).count();
        return ms < 0 ? 0 : ms;
    }
};

// Wait until fd is ready for `ev`, within the call's time; false on timeout.
// A non-blocking socket raises BlockingIOError instead of waiting.
static bool await_ready(Sock& s, int ev, const Clock& c) {
    if (s.timeout == 0) raise("BlockingIOError", "[Errno 11] Resource temporarily unavailable");
    double ms = c.left_ms();
    if (ms == 0 && s.timeout > 0) return false;
    return wait_ready(s.fd, ev, ms) != 0;
}

intptr_t sock_fd(const Sock& s) { return (intptr_t)s.fd; }
TlsConn*& sock_tls(Sock& s) { return s.tls; }
double sock_timeout(const Sock& s) { return s.timeout; }
bool sock_wait(Sock& s, int ev, double left_ms) {
    if (s.timeout == 0) raise("BlockingIOError", "[Errno 11] Resource temporarily unavailable");
    if (left_ms == 0) return false;
    return wait_ready(s.fd, ev, left_ms) != 0;
}
void run_pending_signals() { run_signals(); }

// A final error of one send/recv step: a TLS failure is SSLError (its
// text from the TLS layer), anything else the errno's OSError.
[[noreturn]] static void raise_io(Sock& s, int err) {
    if (err < 0 && s.tls) raise("SSLError", tls_error_text(s.tls));
    raise_err(err);
}

// ── addresses ───────────────────────────────────────────────────────────────
struct Addr {
    sockaddr_storage ss{};
    socklen_t len = 0;
};

// getaddrinfo with the GIL released; on an async task, on a helper thread
// while the task waits on a pipe (POSIX), so the loop keeps running.
struct GaiJob {
    std::string host, port;
    addrinfo hints{};
    addrinfo* res = nullptr;
    int rc = 0;
#ifndef _WIN32
    int wfd = -1;
#endif
    bool taken = false;
    ~GaiJob() { if (res && !taken) freeaddrinfo(res); }
};
static int resolve(const std::string& host, const std::string& port, const addrinfo& hints, addrinfo** out) {
    ny_platform::ensure_winsock();
#ifndef _WIN32
    if (nyconc::in_async_task()) {
        int p[2];
        if (::pipe(p) == 0) {
            ::fcntl(p[0], F_SETFL, ::fcntl(p[0], F_GETFL) | O_NONBLOCK);
            ::fcntl(p[0], F_SETFD, FD_CLOEXEC);
            ::fcntl(p[1], F_SETFD, FD_CLOEXEC);
            auto job = std::make_shared<GaiJob>();
            job->host = host; job->port = port; job->hints = hints; job->wfd = p[1];
            std::thread([job] {
                job->rc = getaddrinfo(job->host.empty() ? nullptr : job->host.c_str(),
                                      job->port.empty() ? nullptr : job->port.c_str(), &job->hints, &job->res);
                char c = 1;
                ssize_t w = ::write(job->wfd, &c, 1); (void)w;
                ::close(job->wfd);
            }).detach();
            struct Close { int fd; ~Close() { ::close(fd); } } close_r{p[0]};
            while (true) {
                wait_ready(p[0], nyconc::IO_READ, -1);
                char c;
                ssize_t r = ::read(p[0], &c, 1);
                if (r == 1 || r == 0) break;
                if (errno != EAGAIN && errno != EINTR) break;
            }
            job->taken = true;
            *out = job->res;
            return job->rc;
        }
    }
#endif
    int rc;
    {
        nyconc::GilRelease unlocked;
        rc = getaddrinfo(host.empty() ? nullptr : host.c_str(), port.empty() ? nullptr : port.c_str(), &hints, out);
    }
    return rc;
}
[[noreturn]] static void raise_gai(int rc) {
#ifdef _WIN32
    raise("gaierror", "[Errno " + std::to_string(rc) + "] " + err_text(rc));
#else
    if (rc == EAI_SYSTEM) raise_err(errno);
    raise("gaierror", "[Errno " + std::to_string(rc) + "] " + gai_strerror(rc));
#endif
}

static std::string addr_host(const sockaddr* sa) {
    char buf[INET6_ADDRSTRLEN + 1] = {0};
    if (sa->sa_family == AF_INET) inet_ntop(AF_INET, &((const sockaddr_in*)sa)->sin_addr, buf, sizeof buf);
    else if (sa->sa_family == AF_INET6) inet_ntop(AF_INET6, &((const sockaddr_in6*)sa)->sin6_addr, buf, sizeof buf);
    return buf;
}

// A Python address value -> sockaddr, for `family`.
Addr parse_addr(NythonExecutor& E, int family, const Value& v, bool for_bind) {
    Addr a;
#ifndef _WIN32
    if (family == AF_UNIX) {
        std::string path;
        if (auto* bo = E.bytesOf(v)) path = bo->s;
        else if (E.isStringValue(v)) path = E.getStringValue(v);
        else raise("TypeError", "a str or bytes path is required for an AF_UNIX address");
        sockaddr_un un{};
        un.sun_family = AF_UNIX;
        if (path.size() >= sizeof un.sun_path) raise("OSError", "AF_UNIX path too long");
        std::memcpy(un.sun_path, path.data(), path.size());
        std::memcpy(&a.ss, &un, sizeof un);
        a.len = (socklen_t)(offsetof(sockaddr_un, sun_path) + path.size() + (path.empty() || path[0] != '\0' ? 1 : 0));
        return a;
    }
#endif
    std::vector<Value> parts = E.iterItems(v, nullptr);
    if (parts.size() < 2) raise("TypeError", family == AF_INET6 ? "AF_INET6 address must be a tuple (host, port[, flowinfo[, scopeid]])"
                                                              : "AF_INET address must be tuple, not " + E.typeNameOf(v));
    std::string host;
    if (auto* bo = E.bytesOf(parts[0])) host = bo->s;
    else if (E.isStringValue(parts[0])) host = E.getStringValue(parts[0]);
    else if (parts[0].type == ValueType::NONE) host = "";
    else raise("TypeError", "str, bytes or bytearray expected, not " + E.typeNameOf(parts[0]));
    if (parts[1].type != ValueType::INTEGER) raise("TypeError", "'" + E.typeNameOf(parts[1]) + "' object cannot be interpreted as an integer");
    int64_t port = bigint_to_i64(parts[1].value.i);
    if (port < 0 || port > 65535) raise("OverflowError", "port must be 0-65535.");
    if (family == AF_INET) {
        sockaddr_in in{};
        in.sin_family = AF_INET;
        in.sin_port = htons((uint16_t)port);
        if (host.empty()) in.sin_addr.s_addr = htonl(INADDR_ANY);
        else if (host == "<broadcast>") in.sin_addr.s_addr = htonl(INADDR_BROADCAST);
        else if (inet_pton(AF_INET, host.c_str(), &in.sin_addr) != 1) {
            addrinfo hints{}; hints.ai_family = AF_INET;
            addrinfo* res = nullptr;
            int rc = resolve(host, "", hints, &res);
            if (rc != 0 || !res) raise_gai(rc);
            in.sin_addr = ((sockaddr_in*)res->ai_addr)->sin_addr;
            freeaddrinfo(res);
        }
        std::memcpy(&a.ss, &in, sizeof in);
        a.len = sizeof in;
        return a;
    }
    if (family == AF_INET6) {
        sockaddr_in6 in6{};
        in6.sin6_family = AF_INET6;
        in6.sin6_port = htons((uint16_t)port);
        if (parts.size() >= 3 && parts[2].type == ValueType::INTEGER) in6.sin6_flowinfo = htonl((uint32_t)bigint_to_i64(parts[2].value.i));
        if (parts.size() >= 4 && parts[3].type == ValueType::INTEGER) in6.sin6_scope_id = (uint32_t)bigint_to_i64(parts[3].value.i);
        if (host.empty()) in6.sin6_addr = in6addr_any;
        else if (inet_pton(AF_INET6, host.c_str(), &in6.sin6_addr) != 1) {
            addrinfo hints{}; hints.ai_family = AF_INET6;
            addrinfo* res = nullptr;
            int rc = resolve(host, "", hints, &res);
            if (rc != 0 || !res) raise_gai(rc);
            in6.sin6_addr = ((sockaddr_in6*)res->ai_addr)->sin6_addr;
            freeaddrinfo(res);
        }
        std::memcpy(&a.ss, &in6, sizeof in6);
        a.len = sizeof in6;
        return a;
    }
    (void)for_bind;
    raise("OSError", "address family " + std::to_string(family) + " not supported");
}

Value addr_value(NythonExecutor& E, const sockaddr* sa, socklen_t len) {
    if (!sa || len == 0) return NONE_VALUE;
    if (sa->sa_family == AF_INET) {
        auto* in = (const sockaddr_in*)sa;
        return E.makeListValue({E.makeStringValue(addr_host(sa)), intValue((int64_t)ntohs(in->sin_port))}, true);
    }
    if (sa->sa_family == AF_INET6) {
        auto* in6 = (const sockaddr_in6*)sa;
        return E.makeListValue({E.makeStringValue(addr_host(sa)), intValue((int64_t)ntohs(in6->sin6_port)),
                                intValue((int64_t)ntohl(in6->sin6_flowinfo)), intValue((int64_t)in6->sin6_scope_id)}, true);
    }
#ifndef _WIN32
    if (sa->sa_family == AF_UNIX) {
        auto* un = (const sockaddr_un*)sa;
        size_t n = len > offsetof(sockaddr_un, sun_path) ? (size_t)len - offsetof(sockaddr_un, sun_path) : 0;
        std::string p(un->sun_path, std::min(n, sizeof un->sun_path));
        if (!p.empty() && p[0] != '\0') p = p.c_str();   // up to the NUL
        return E.makeStringValue(p);
    }
#endif
    return NONE_VALUE;
}

// ── data ────────────────────────────────────────────────────────────────────
// What a send takes: bytes-like, or a str (sent as UTF-8 - Python would
// raise TypeError; Nython strings are UTF-8 already, so it is accepted).
static std::string data_arg(NythonExecutor& E, const Value& v) {
    if (auto* bo = E.bytesOf(v)) return bo->s;
    if (E.isStringValue(v)) return E.getStringValue(v);
    raise("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}

// Plain or TLS: one send / recv step. Returns bytes moved, or -1 with the
// event to wait for in *wait (0 when the error is final: *err set).
static long io_send(Sock& s, const char* p, size_t n, int flags, int* wait, int* err) {
    if (s.tls) return tls_write(s.tls, p, n, wait, err);
#ifdef _WIN32
    int r = ::send(s.fd, p, (int)std::min<size_t>(n, INT32_MAX), flags);
#else
    ssize_t r = ::send(s.fd, p, n, flags | MSG_NOSIGNAL);
#endif
    if (r >= 0) return (long)r;
    int e = last_err();
    *wait = (would_block(e) || interrupted(e)) ? nyconc::IO_WRITE : 0;
    *err = e;
    return -1;
}
static long io_recv(Sock& s, char* p, size_t n, int flags, int* wait, int* err) {
    if (s.tls) return tls_read(s.tls, p, n, wait, err);
#ifdef _WIN32
    int r = ::recv(s.fd, p, (int)std::min<size_t>(n, INT32_MAX), flags);
#else
    ssize_t r = ::recv(s.fd, p, n, flags);
#endif
    if (r >= 0) return (long)r;
    int e = last_err();
    *wait = (would_block(e) || interrupted(e)) ? nyconc::IO_READ : 0;
    *err = e;
    return -1;
}

std::string recv_some(Sock& s, size_t n, int flags) {
    std::string buf(n, '\0');
    Clock c(s.timeout);
    while (true) {
        int wait = 0, err = 0;
        long r = io_recv(s, &buf[0], n, flags, &wait, &err);
        if (r >= 0) { buf.resize((size_t)r); return buf; }
        if (!wait) raise_io(s, err);
        if (interrupted(err)) { run_signals(); continue; }
        if (!await_ready(s, wait, c)) raise_timeout();
    }
}
size_t send_some(Sock& s, const std::string& data, size_t off, int flags, const Clock* shared) {
    Clock own(s.timeout);
    const Clock& c = shared ? *shared : own;
    while (true) {
        int wait = 0, err = 0;
        long r = io_send(s, data.data() + off, data.size() - off, flags, &wait, &err);
        if (r >= 0) return (size_t)r;
        if (!wait) raise_io(s, err);
        if (interrupted(err)) { run_signals(); continue; }
        if (!await_ready(s, wait, c)) raise_timeout();
    }
}
void send_all(Sock& s, const std::string& data, int flags) {
    Clock c(s.timeout);          // the timeout covers the whole sendall (Python 3.5+)
    size_t off = 0;
    while (off < data.size()) off += send_some(s, data, off, flags, &c);
}

// Connect with the socket's timeout. Returns 0 or the error code.
static int connect_raw(Sock& s, const Addr& a) {
    Clock c(s.timeout);
    int rc = ::connect(s.fd, (const sockaddr*)&a.ss, a.len);
    if (rc == 0) return 0;
    int e = last_err();
    if (interrupted(e)) e = EINPROGRESS_COMPAT;
    if (!connect_pending(e) && e != EINPROGRESS_COMPAT) return e;
    if (s.timeout == 0) return e;
    int ready = wait_ready(s.fd, nyconc::IO_WRITE, c.left_ms());
    if (!ready) return -1;     // timed out
    int so = 0;
    socklen_t sl = sizeof so;
    ::getsockopt(s.fd, SOL_SOCKET, SO_ERROR, (char*)&so, &sl);
    return so;
}

// ── builtins ────────────────────────────────────────────────────────────────
static int64_t int_arg(NythonExecutor& E, const nyos::Args& A, size_t i, const char* name, int64_t dflt) {
    if (!A.has(i, name)) return dflt;
    Value v = A.get(i, name);
    if (v.type == ValueType::BOOLEAN) return v.value.b ? 1 : 0;
    if (v.type != ValueType::INTEGER) raise("TypeError", "'" + E.typeNameOf(v) + "' object cannot be interpreted as an integer");
    return bigint_to_i64(v.value.i);
}
static int64_t handle_of(NythonExecutor& E, const Value& v) {
    if (v.type != ValueType::INTEGER) raise("TypeError", "a socket handle is required, not " + E.typeNameOf(v));
    return bigint_to_i64(v.value.i);
}

} // namespace nynet

using namespace nynet;

static const std::vector<std::string>& net_names() {
    static const std::vector<std::string> n = {
        "_net_socket", "_net_socketpair", "_net_fromfd", "_net_close", "_net_detach", "_net_fileno",
        "_net_settimeout", "_net_gettimeout", "_net_setdefaulttimeout", "_net_getdefaulttimeout",
        "_net_bind", "_net_listen", "_net_accept", "_net_connect", "_net_connect_ex",
        "_net_send", "_net_sendall", "_net_recv", "_net_sendto", "_net_recvfrom", "_net_shutdown",
        "_net_setsockopt", "_net_getsockopt", "_net_getsockname", "_net_getpeername",
        "_net_getaddrinfo", "_net_gethostname", "_net_gethostbyname", "_net_gethostbyaddr",
        "_net_getnameinfo", "_net_inet_pton", "_net_inet_ntop", "_net_select", "_net_constants",
        "_net_info", "_net_wait"};
    return n;
}
std::vector<std::string> net_builtin_names() { return net_names(); }

Value dispatch_net(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    if (name.size() < 6 || name.compare(0, 5, "_net_") != 0) return UNDEFINED_VALUE;
    (void)ctx;
    ny_platform::ensure_winsock();
    nyos::Args A(E, args, {"family", "type", "proto", "flags", "timeout", "backlog", "how", "level",
                           "option", "value", "buflen", "host", "port", "address", "data", "bufsize"});

    if (name == "_net_socket") {
        int family = (int)int_arg(E, A, 0, "family", AF_INET);
        int type = (int)int_arg(E, A, 1, "type", SOCK_STREAM);
        int proto = (int)int_arg(E, A, 2, "proto", 0);
#ifdef _WIN32
        if (family == 1) raise("OSError", "[WinError 10047] AF_UNIX sockets are not supported on Windows");
#endif
        sock_t fd = ::socket(family, type, proto);
        if (fd == BAD) raise_err(last_err());
        set_nonblocking(fd);
        auto s = std::make_shared<Sock>();
        s->fd = fd; s->family = family; s->type = type; s->proto = proto; s->timeout = g_default_timeout;
        return intValue(add(s));
    }
    if (name == "_net_socketpair") {
#ifdef _WIN32
        // Windows: a connected loopback TCP pair
        sock_t l = ::socket(AF_INET, SOCK_STREAM, 0);
        if (l == BAD) raise_err(last_err());
        sockaddr_in in{}; in.sin_family = AF_INET; in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int alen = sizeof in;
        if (::bind(l, (sockaddr*)&in, sizeof in) != 0 || ::listen(l, 1) != 0 || ::getsockname(l, (sockaddr*)&in, &alen) != 0) {
            int e = last_err(); closesocket(l); raise_err(e);
        }
        sock_t a = ::socket(AF_INET, SOCK_STREAM, 0);
        if (a == BAD || ::connect(a, (sockaddr*)&in, sizeof in) != 0) { int e = last_err(); closesocket(l); raise_err(e); }
        sock_t b = ::accept(l, nullptr, nullptr);
        closesocket(l);
        if (b == BAD) { int e = last_err(); closesocket(a); raise_err(e); }
        int family = AF_INET;
#else
        int family = (int)int_arg(E, A, 0, "family", AF_UNIX);
        int type = (int)int_arg(E, A, 1, "type", SOCK_STREAM);
        int sv[2];
        if (::socketpair(family, type, 0, sv) != 0) raise_err(errno);
        sock_t a = sv[0], b = sv[1];
#endif
        set_nonblocking(a); set_nonblocking(b);
        auto sa = std::make_shared<Sock>(); sa->fd = a; sa->family = family; sa->timeout = g_default_timeout;
        auto sb = std::make_shared<Sock>(); sb->fd = b; sb->family = family; sb->timeout = g_default_timeout;
        return E.makeListValue({intValue(add(sa)), intValue(add(sb))});
    }
    if (name == "_net_fromfd") {
        // a socket over an existing descriptor (socket(fileno=...)); it is
        // taken over, not duplicated
        int64_t fd = int_arg(E, A, 0, "fileno", -1);
        if (fd < 0) raise("ValueError", "negative file descriptor");
        auto s = std::make_shared<Sock>();
        s->fd = (sock_t)fd;
        s->family = (int)int_arg(E, A, 1, "family", AF_INET);
        s->type = (int)int_arg(E, A, 2, "type", SOCK_STREAM);
        s->timeout = g_default_timeout;
        set_nonblocking(s->fd);
        return intValue(add(s));
    }
    if (name == "_net_close" || name == "_net_detach") {
        int64_t h = handle_of(E, A.get(0, nullptr));
        std::shared_ptr<Sock> s;
        {
            std::lock_guard<std::mutex> l(mu());
            auto it = table().find(h);
            if (it == table().end()) return name == "_net_detach" ? intValue(-1) : NONE_VALUE;
            s = it->second;
            table().erase(it);
        }
        if (s->tls) { tls_free(s->tls); s->tls = nullptr; }
        if (name == "_net_detach") return intValue((int64_t)s->fd);
        if (s->fd != BAD) close_fd(s->fd);
        s->fd = BAD;
        return NONE_VALUE;
    }
    if (name == "_net_fileno") {
        int64_t h = handle_of(E, A.get(0, nullptr));
        std::lock_guard<std::mutex> l(mu());
        auto it = table().find(h);
        return intValue(it == table().end() ? -1 : (int64_t)it->second->fd);
    }
    if (name == "_net_settimeout") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        Value t = A.get(1, "timeout");
        if (t.type == ValueType::NONE) s->timeout = -1;
        else {
            double d = nyos::to_num(t, -2);
            if (d < 0) raise("ValueError", "Timeout value out of range");
            s->timeout = d;
        }
        return NONE_VALUE;
    }
    if (name == "_net_gettimeout") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        return s->timeout < 0 ? NONE_VALUE : Value(s->timeout);
    }
    if (name == "_net_setdefaulttimeout") {
        Value t = A.get(0, "timeout");
        if (t.type == ValueType::NONE) g_default_timeout = -1;
        else {
            double d = nyos::to_num(t, -2);
            if (d < 0) raise("ValueError", "Timeout value out of range");
            g_default_timeout = d;
        }
        return NONE_VALUE;
    }
    if (name == "_net_getdefaulttimeout") return g_default_timeout < 0 ? NONE_VALUE : Value(g_default_timeout);
    if (name == "_net_bind") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        Addr a = parse_addr(E, s->family, A.get(1, "address"), true);
        if (::bind(s->fd, (const sockaddr*)&a.ss, a.len) != 0) raise_err(last_err());
        return NONE_VALUE;
    }
    if (name == "_net_listen") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int backlog = (int)int_arg(E, A, 1, "backlog", 128);
        if (::listen(s->fd, backlog < 0 ? 0 : backlog) != 0) raise_err(last_err());
        return NONE_VALUE;
    }
    if (name == "_net_accept") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        Clock c(s->timeout);
        while (true) {
            Addr a; a.len = sizeof a.ss;
            sock_t fd = ::accept(s->fd, (sockaddr*)&a.ss, &a.len);
            if (fd != BAD) {
                set_nonblocking(fd);
                auto n = std::make_shared<Sock>();
                n->fd = fd; n->family = s->family; n->type = s->type; n->proto = s->proto;
                n->timeout = g_default_timeout;
                return E.makeListValue({intValue(add(n)), addr_value(E, (const sockaddr*)&a.ss, a.len)});
            }
            int e = last_err();
            if (interrupted(e)) { run_signals(); continue; }
#ifndef _WIN32
            if (e == ECONNABORTED) continue;   // the peer left before we accepted: wait for the next one
#endif
            if (!would_block(e)) raise_err(e);
            if (!await_ready(*s, nyconc::IO_READ, c)) raise_timeout();
        }
    }
    if (name == "_net_connect" || name == "_net_connect_ex") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        Addr a = parse_addr(E, s->family, A.get(1, "address"), false);
        int rc = connect_raw(*s, a);
        if (name == "_net_connect_ex") {
#ifdef _WIN32
            return intValue(rc < 0 ? WSAETIMEDOUT : rc);
#else
            return intValue(rc < 0 ? ETIMEDOUT : rc);
#endif
        }
        if (rc < 0) raise_timeout();
        if (rc != 0) raise_err(rc);
        return NONE_VALUE;
    }
    if (name == "_net_send") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        std::string data = data_arg(E, A.get(1, "data"));
        int flags = (int)int_arg(E, A, 2, "flags", 0);
        return intValue((int64_t)send_some(*s, data, 0, flags, nullptr));
    }
    if (name == "_net_sendall") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        std::string data = data_arg(E, A.get(1, "data"));
        send_all(*s, data, (int)int_arg(E, A, 2, "flags", 0));
        return NONE_VALUE;
    }
    if (name == "_net_recv") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int64_t n = int_arg(E, A, 1, "bufsize", 4096);
        if (n < 0) raise("ValueError", "negative buffersize in recv");
        int flags = (int)int_arg(E, A, 2, "flags", 0);
        if (n == 0) return E.makeBytesValue("");
        return E.makeBytesValue(recv_some(*s, (size_t)std::min<int64_t>(n, 64 << 20), flags));
    }
    if (name == "_net_sendto") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        std::string data = data_arg(E, A.get(1, "data"));
        Addr a = parse_addr(E, s->family, A.get(2, "address"), false);
        int flags = (int)int_arg(E, A, 3, "flags", 0);
        Clock c(s->timeout);
        while (true) {
#ifdef _WIN32
            int r = ::sendto(s->fd, data.data(), (int)data.size(), flags, (const sockaddr*)&a.ss, a.len);
#else
            ssize_t r = ::sendto(s->fd, data.data(), data.size(), flags | MSG_NOSIGNAL, (const sockaddr*)&a.ss, a.len);
#endif
            if (r >= 0) return intValue((int64_t)r);
            int e = last_err();
            if (interrupted(e)) { run_signals(); continue; }
            if (!would_block(e)) raise_err(e);
            if (!await_ready(*s, nyconc::IO_WRITE, c)) raise_timeout();
        }
    }
    if (name == "_net_recvfrom") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int64_t n = int_arg(E, A, 1, "bufsize", 65536);
        if (n < 0) raise("ValueError", "negative buffersize in recvfrom");
        int flags = (int)int_arg(E, A, 2, "flags", 0);
        std::string buf((size_t)std::max<int64_t>(n, 1), '\0');
        Clock c(s->timeout);
        while (true) {
            Addr a; a.len = sizeof a.ss;
#ifdef _WIN32
            int r = ::recvfrom(s->fd, &buf[0], (int)buf.size(), flags, (sockaddr*)&a.ss, &a.len);
#else
            ssize_t r = ::recvfrom(s->fd, &buf[0], buf.size(), flags, (sockaddr*)&a.ss, &a.len);
#endif
            if (r >= 0) {
                buf.resize((size_t)std::min<int64_t>(r, n));
                return E.makeListValue({E.makeBytesValue(buf), addr_value(E, (const sockaddr*)&a.ss, a.len)});
            }
            int e = last_err();
            if (interrupted(e)) { run_signals(); continue; }
            if (!would_block(e)) raise_err(e);
            if (!await_ready(*s, nyconc::IO_READ, c)) raise_timeout();
        }
    }
    if (name == "_net_shutdown") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int how = (int)int_arg(E, A, 1, "how", SHUT_RDWR);
        if (::shutdown(s->fd, how) != 0) raise_err(last_err());
        return NONE_VALUE;
    }
    if (name == "_net_setsockopt") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int level = (int)int_arg(E, A, 1, "level", SOL_SOCKET);
        int opt = (int)int_arg(E, A, 2, "option", 0);
        Value v = A.get(3, "value");
        int rc;
        if (auto* bo = E.bytesOf(v)) rc = ::setsockopt(s->fd, level, opt, bo->s.data(), (socklen_t)bo->s.size());
        else {
            int iv = (int)nyos::to_int(v, 0);
            rc = ::setsockopt(s->fd, level, opt, (const char*)&iv, sizeof iv);
        }
        if (rc != 0) raise_err(last_err());
        return NONE_VALUE;
    }
    if (name == "_net_getsockopt") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int level = (int)int_arg(E, A, 1, "level", SOL_SOCKET);
        int opt = (int)int_arg(E, A, 2, "option", 0);
        int64_t buflen = int_arg(E, A, 3, "buflen", 0);
        if (buflen > 0) {
            std::string buf((size_t)buflen, '\0');
            socklen_t sl = (socklen_t)buflen;
            if (::getsockopt(s->fd, level, opt, &buf[0], &sl) != 0) raise_err(last_err());
            buf.resize(sl);
            return E.makeBytesValue(buf);
        }
        int iv = 0;
        socklen_t sl = sizeof iv;
        if (::getsockopt(s->fd, level, opt, (char*)&iv, &sl) != 0) raise_err(last_err());
        return intValue((int64_t)iv);
    }
    if (name == "_net_getsockname" || name == "_net_getpeername") {
        auto s = get(handle_of(E, A.get(0, nullptr)));
        Addr a; a.len = sizeof a.ss;
        int rc = name == "_net_getsockname" ? ::getsockname(s->fd, (sockaddr*)&a.ss, &a.len)
                                            : ::getpeername(s->fd, (sockaddr*)&a.ss, &a.len);
        if (rc != 0) raise_err(last_err());
        return addr_value(E, (const sockaddr*)&a.ss, a.len);
    }
    if (name == "_net_getaddrinfo") {
        Value hv = A.get(0, "host"), pv = A.get(1, "port");
        std::string host, port;
        if (auto* bo = E.bytesOf(hv)) host = bo->s;
        else if (E.isStringValue(hv)) host = E.getStringValue(hv);
        if (pv.type == ValueType::INTEGER) port = std::to_string(bigint_to_i64(pv.value.i));
        else if (auto* bo = E.bytesOf(pv)) port = bo->s;
        else if (E.isStringValue(pv)) port = E.getStringValue(pv);
        addrinfo hints{};
        hints.ai_family = (int)int_arg(E, A, 2, "family", AF_UNSPEC);
        hints.ai_socktype = (int)int_arg(E, A, 3, "type", 0);
        hints.ai_protocol = (int)int_arg(E, A, 4, "proto", 0);
        hints.ai_flags = (int)int_arg(E, A, 5, "flags", 0);
        if (host.empty() && hv.type == ValueType::NONE && !(hints.ai_flags & AI_PASSIVE)) host = "";
        addrinfo* res = nullptr;
        int rc = resolve(host, port, hints, &res);
        if (rc != 0) raise_gai(rc);
        std::vector<Value> out;
        for (addrinfo* r = res; r; r = r->ai_next) {
            out.push_back(E.makeListValue({intValue(r->ai_family), intValue(r->ai_socktype), intValue(r->ai_protocol),
                E.makeStringValue(r->ai_canonname ? r->ai_canonname : ""), addr_value(E, r->ai_addr, (socklen_t)r->ai_addrlen)}, true));
        }
        freeaddrinfo(res);
        return E.makeListValue(out);
    }
    if (name == "_net_gethostname") {
        char buf[256] = {0};
        if (::gethostname(buf, sizeof buf - 1) != 0) raise_err(last_err());
        return E.makeStringValue(buf);
    }
    if (name == "_net_gethostbyname") {
        std::string host = E.getStringValue(A.get(0, "host"));
        in_addr a4{};
        if (inet_pton(AF_INET, host.c_str(), &a4) == 1) return E.makeStringValue(host);
        addrinfo hints{}; hints.ai_family = AF_INET;
        addrinfo* res = nullptr;
        int rc = resolve(host, "", hints, &res);
        if (rc != 0 || !res) raise_gai(rc);
        std::string ip = addr_host(res->ai_addr);
        freeaddrinfo(res);
        return E.makeStringValue(ip);
    }
    if (name == "_net_gethostbyaddr" || name == "_net_getnameinfo") {
        // gethostbyaddr(ip) -> (name, [], [ip]); getnameinfo((host, port), flags) -> (host, port)
        Value v = A.get(0, "address");
        std::string ip; int port = 0;
        if (E.isStringValue(v)) ip = E.getStringValue(v);
        else {
            auto parts = E.iterItems(v, nullptr);
            if (parts.size() < 2) raise("TypeError", "getnameinfo() argument 1 must be a tuple");
            ip = E.getStringValue(parts[0]);
            port = (int)nyos::to_int(parts[1], 0);
        }
        addrinfo hints{}; hints.ai_flags = AI_NUMERICHOST;
        addrinfo* res = nullptr;
        int rc = resolve(ip, "", hints, &res);
        if (rc != 0 || !res) {
            hints.ai_flags = 0;
            rc = resolve(ip, "", hints, &res);
            if (rc != 0 || !res) raise_gai(rc);
        }
        char host[1025] = {0}, serv[32] = {0};
        if (res->ai_family == AF_INET) ((sockaddr_in*)res->ai_addr)->sin_port = htons((uint16_t)port);
        if (res->ai_family == AF_INET6) ((sockaddr_in6*)res->ai_addr)->sin6_port = htons((uint16_t)port);
        int flags = name == "_net_getnameinfo" ? (int)int_arg(E, A, 1, "flags", 0) : NI_NAMEREQD;
        int gr;
        {
            nyconc::GilRelease unlocked;
            gr = getnameinfo(res->ai_addr, (socklen_t)res->ai_addrlen, host, sizeof host, serv, sizeof serv, flags);
        }
        std::string addr_txt = addr_host(res->ai_addr);
        freeaddrinfo(res);
        if (gr != 0) {
            if (name == "_net_gethostbyaddr") raise("herror", "[Errno 1] Unknown host");
            raise_gai(gr);
        }
        if (name == "_net_getnameinfo") return E.makeListValue({E.makeStringValue(host), E.makeStringValue(serv)}, true);
        return E.makeListValue({E.makeStringValue(host), E.makeListValue({}), E.makeListValue({E.makeStringValue(addr_txt)})}, true);
    }
    if (name == "_net_inet_pton") {
        int family = (int)int_arg(E, A, 0, "family", AF_INET);
        std::string txt = E.getStringValue(A.get(1, nullptr));
        unsigned char buf[16];
        if (family != AF_INET && family != AF_INET6) raise("OSError", "[Errno 97] Address family not supported by protocol");
        if (inet_pton(family, txt.c_str(), buf) != 1) raise("OSError", "illegal IP address string passed to inet_pton");
        return E.makeBytesValue(std::string((char*)buf, family == AF_INET ? 4 : 16));
    }
    if (name == "_net_inet_ntop") {
        int family = (int)int_arg(E, A, 0, "family", AF_INET);
        Value v = A.get(1, nullptr);
        auto* bo = E.bytesOf(v);
        if (!bo) raise("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
        if (family == AF_INET && bo->s.size() != 4) raise("ValueError", "invalid length of packed IP address string");
        if (family == AF_INET6 && bo->s.size() != 16) raise("ValueError", "invalid length of packed IP address string");
        if (family != AF_INET && family != AF_INET6) raise("ValueError", "unknown address family " + std::to_string(family));
        char buf[INET6_ADDRSTRLEN + 1] = {0};
        inet_ntop(family, bo->s.data(), buf, sizeof buf);
        return E.makeStringValue(buf);
    }
    if (name == "_net_select") {
        // select(rfds, wfds, xfds, timeout) over descriptors -> [r, w, x]
        auto collect = [&](const Value& v) {
            std::vector<int64_t> out;
            if (v.type == ValueType::NONE) return out;
            for (auto& it : E.iterItems(v, nullptr)) out.push_back(nyos::to_int(it, -1));
            return out;
        };
        std::vector<int64_t> r = collect(A.get(0, nullptr)), w = collect(A.get(1, nullptr)), x = collect(A.get(2, nullptr));
        Value tv = A.get(3, "timeout");
        double ms = tv.type == ValueType::NONE ? -1 : nyos::to_num(tv, 0) * 1000.0;
        if (ms < -0.5 && tv.type != ValueType::NONE) raise("ValueError", "timeout must be non-negative");
        std::vector<nyconc::IoReq> reqs;
        auto put = [&](int64_t fd, int ev) {
            for (auto& q : reqs) if (q.fd == (intptr_t)fd) { q.events |= ev; return; }
            nyconc::IoReq q; q.fd = (intptr_t)fd; q.events = ev; reqs.push_back(q);
        };
        for (auto fd : r) put(fd, nyconc::IO_READ);
        for (auto fd : w) put(fd, nyconc::IO_WRITE);
        for (auto fd : x) put(fd, 0);
        try { nyconc::wait_io_many(reqs, ms); }
        catch (nyconc::NyError& err) {
            if (!err.raw.empty()) throw std::string(err.raw);
            throw std::string("__exc__:" + err.type + ":" + err.msg);
        }
        auto ready = [&](int64_t fd, int ev) {
            for (auto& q : reqs) if (q.fd == (intptr_t)fd) return (q.revents & (ev | nyconc::IO_ERR)) != 0;
            return false;
        };
        std::vector<Value> ro, wo, xo;
        for (auto fd : r) if (ready(fd, nyconc::IO_READ)) ro.push_back(intValue(fd));
        for (auto fd : w) if (ready(fd, nyconc::IO_WRITE)) wo.push_back(intValue(fd));
        for (auto fd : x) if (ready(fd, 0)) xo.push_back(intValue(fd));
        return E.makeListValue({E.makeListValue(ro), E.makeListValue(wo), E.makeListValue(xo)});
    }
    if (name == "_net_wait") {
        // _net_wait(handle, events, timeout) -> ready events (0: timed out)
        auto s = get(handle_of(E, A.get(0, nullptr)));
        int ev = (int)int_arg(E, A, 1, "flags", nyconc::IO_READ);
        Value tv = A.get(2, "timeout");
        double ms = tv.type == ValueType::NONE ? -1 : nyos::to_num(tv, 0) * 1000.0;
        if (s->tls && (ev & nyconc::IO_READ) && tls_pending(s->tls) > 0) return intValue(nyconc::IO_READ);
        return intValue(wait_ready(s->fd, ev, ms));
    }
    if (name == "_net_info") {
        // [family, type, proto] of a socket
        auto s = get(handle_of(E, A.get(0, nullptr)));
        return E.makeListValue({intValue(s->family), intValue(s->type), intValue(s->proto)});
    }
    if (name == "_net_constants") {
        std::vector<Value> out;
        auto add_c = [&](const char* n, int64_t v) { out.push_back(E.makeListValue({E.makeStringValue(n), intValue(v)})); };
        add_c("AF_INET", AF_INET); add_c("AF_INET6", AF_INET6); add_c("AF_UNSPEC", AF_UNSPEC);
#ifndef _WIN32
        add_c("AF_UNIX", AF_UNIX);
#endif
        add_c("SOCK_STREAM", SOCK_STREAM); add_c("SOCK_DGRAM", SOCK_DGRAM); add_c("SOCK_RAW", SOCK_RAW);
        add_c("SOL_SOCKET", SOL_SOCKET); add_c("SO_REUSEADDR", SO_REUSEADDR); add_c("SO_KEEPALIVE", SO_KEEPALIVE);
        add_c("SO_BROADCAST", SO_BROADCAST); add_c("SO_RCVBUF", SO_RCVBUF); add_c("SO_SNDBUF", SO_SNDBUF);
        add_c("SO_ERROR", SO_ERROR); add_c("SO_TYPE", SO_TYPE); add_c("SO_LINGER", SO_LINGER);
        add_c("SO_RCVTIMEO", SO_RCVTIMEO); add_c("SO_SNDTIMEO", SO_SNDTIMEO);
#ifdef SO_REUSEPORT
        add_c("SO_REUSEPORT", SO_REUSEPORT);
#endif
        add_c("IPPROTO_TCP", IPPROTO_TCP); add_c("IPPROTO_UDP", IPPROTO_UDP); add_c("IPPROTO_IP", IPPROTO_IP);
        add_c("IPPROTO_IPV6", IPPROTO_IPV6); add_c("TCP_NODELAY", TCP_NODELAY);
#ifdef IPV6_V6ONLY
        add_c("IPV6_V6ONLY", IPV6_V6ONLY);
#endif
        add_c("IP_TTL", IP_TTL); add_c("IP_MULTICAST_TTL", IP_MULTICAST_TTL);
        add_c("SHUT_RD", SHUT_RD); add_c("SHUT_WR", SHUT_WR); add_c("SHUT_RDWR", SHUT_RDWR);
        add_c("MSG_PEEK", MSG_PEEK); add_c("MSG_OOB", MSG_OOB);
#ifdef MSG_DONTWAIT
        add_c("MSG_DONTWAIT", MSG_DONTWAIT);
#endif
#ifdef MSG_WAITALL
        add_c("MSG_WAITALL", MSG_WAITALL);
#endif
        add_c("AI_PASSIVE", AI_PASSIVE); add_c("AI_CANONNAME", AI_CANONNAME); add_c("AI_NUMERICHOST", AI_NUMERICHOST);
#ifdef AI_NUMERICSERV
        add_c("AI_NUMERICSERV", AI_NUMERICSERV);
#endif
        add_c("NI_NUMERICHOST", NI_NUMERICHOST); add_c("NI_NUMERICSERV", NI_NUMERICSERV); add_c("NI_NAMEREQD", NI_NAMEREQD);
        add_c("INADDR_ANY", INADDR_ANY); add_c("INADDR_LOOPBACK", INADDR_LOOPBACK); add_c("INADDR_BROADCAST", (int64_t)(uint32_t)INADDR_BROADCAST);
        add_c("SOMAXCONN", SOMAXCONN);
        add_c("has_ipv6", 1);
        return E.makeListValue(out);
    }
    return UNDEFINED_VALUE;
}
