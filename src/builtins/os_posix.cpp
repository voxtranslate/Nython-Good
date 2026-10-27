#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/os_posix.cpp (round 85)
// The rest of CPython's posixmodule.c - what os_fd.cpp (round 80) and
// nysysmods.cpp (round 83) did not have - plus the clocks of the time
// module, the signal masks and waits of the signal module and the interface
// and ancillary-data calls of the socket module. Reached as
// `_ny_os_call(op, ...)` (os_fd.cpp forwards the ops it does not know here);
// the Python-shaped functions are the prelude's "posix" chunk
// (src/NyPreludePosix.cpp), lib/time.ny, lib/signal.ny and lib/socket.ny.
//
// Every failure raises the OSError subclass of its errno with errno,
// strerror and the file name, as CPython's functions do; a wait releases the
// GIL and, interrupted by a signal, runs the handlers and resumes (PEP 475).
// POSIX only: on Windows every op here is unknown (UNDEFINED), and the
// prelude does not bind the names CPython's nt module lacks.
// ─────────────────────────────────────────────────────────────────────────────

#include "platform_compat.hpp"

#include <cerrno>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <climits>
#include <string>
#include <vector>
#include <algorithm>

#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#include "NyConc.hpp"
#include "NyRuntime.hpp"

#ifndef _WIN32
#  include <unistd.h>
#  include <fcntl.h>
#  include <signal.h>
#  include <sched.h>
#  include <dlfcn.h>
#  include <grp.h>
#  include <pwd.h>
#  include <time.h>
#  include <pthread.h>
#  include <net/if.h>
#  include <netdb.h>
#  include <arpa/inet.h>
#  include <netinet/in.h>
#  include <netinet/tcp.h>
#  include <netinet/udp.h>
#  include <sys/types.h>
#  include <sys/stat.h>
#  include <sys/statvfs.h>
#  include <sys/resource.h>
#  include <sys/wait.h>
#  include <sys/socket.h>
#  include <sys/uio.h>
#  include <sys/un.h>
#  include <spawn.h>
#  if __has_include(<sysexits.h>)
#    include <sysexits.h>
#  endif
#  if __has_include(<sys/xattr.h>)
#    include <sys/xattr.h>
#    define NY_HAVE_XATTR 1
#  endif
#  if defined(__linux__)
#    include <sys/syscall.h>
#    include <sys/mman.h>
#    include <linux/limits.h>
#    if __has_include(<sys/eventfd.h>)
#      include <sys/eventfd.h>
#      define NY_HAVE_EVENTFD 1
#    endif
#    if __has_include(<sys/random.h>)
#      include <sys/random.h>
#      define NY_HAVE_GETRANDOM 1
#    endif
#    if __has_include(<linux/memfd.h>)
#      include <linux/memfd.h>
#    endif
#    include <sys/epoll.h>
#    include <poll.h>
#    define NY_HAVE_EPOLL 1
#  endif
#  if defined(__APPLE__)
#    include <sys/param.h>
#    include <sys/mount.h>
#  endif
// the socket constants' headers (os_posix_socket.inc), where they exist
#  if __has_include(<net/ethernet.h>)
#    include <net/ethernet.h>
#  endif
#  if defined(__linux__)
#    if __has_include(<linux/can.h>)
#      include <linux/can.h>
#    endif
#    if __has_include(<linux/can/raw.h>)
#      include <linux/can/raw.h>
#    endif
#    if __has_include(<linux/can/bcm.h>)
#      include <linux/can/bcm.h>
#      define NY_HAVE_CAN_BCM 1
#    endif
#    if __has_include(<linux/can/isotp.h>)
#      include <linux/can/isotp.h>
#    endif
#    if __has_include(<linux/can/j1939.h>)
#      include <linux/can/j1939.h>
#    endif
#    if __has_include(<linux/tipc.h>)
#      include <linux/tipc.h>
#    endif
#    if __has_include(<linux/vm_sockets.h>)
#      include <linux/vm_sockets.h>
#    endif
#    if __has_include(<linux/if_alg.h>)
#      include <linux/if_alg.h>
#    endif
#    if __has_include(<linux/netlink.h>)
#      include <linux/netlink.h>
#    endif
#    if __has_include(<linux/if_packet.h>)
#      include <linux/if_packet.h>
#    endif
#  endif
#  ifndef NY_HAVE_CAN_BCM
#    define NY_HAVE_CAN_BCM 0
#  endif
#  if defined(__GLIBC__) && __has_include(<libintl.h>)
#    include <libintl.h>
#    include <locale.h>
#    define NY_HAVE_LIBINTL 1
#  endif
extern char** environ;
#endif

using namespace nython;
using namespace nython::kernel;

namespace {

using nyos::raise;
using nyos::raise_errno;
using nyos::make_int;
using nyos::make_list;

#ifndef _WIN32
Value tuple_of(NythonExecutor& E, const std::vector<Value>& items) {
    // (round 85) a real tuple: the "__tuple__" mark set through a cast of
    // value.p never reached the container, so os.pipe() gave a list
    return E.makeListValue(items, true);
}
Value pairs(NythonExecutor& E, const std::vector<std::pair<const char*, long long>>& kv) {
    std::vector<Value> out;
    for (auto& p : kv) out.push_back(tuple_of(E, {E.makeStringValue(p.first), make_int(p.second)}));
    return make_list(E, out);
}
int fdv(NythonExecutor& E, const Value& v) {
    if (v.type != ValueType::INTEGER && v.type != ValueType::BOOLEAN)
        raise("TypeError", "an integer is required (got type " + E.typeNameOf(v) + ")");
    long long fd = nyos::to_int(v, -1);
    if (fd < INT_MIN || fd > INT_MAX) raise("OverflowError", "fd is greater than maximum");
    return (int)fd;
}
std::string bytes_or_str(NythonExecutor& E, const Value& v) {
    if (auto* bo = E.bytesOf(v)) return bo->s;
    return E.getStringValue(v);
}
// A blocking call: the GIL released around it, EINTR retried after the
// signal handlers ran (they may raise). Returns the call's result; err its
// errno when that is negative.
template<class F> long long blocking(F&& f, int& err) {
    while (true) {
        long long r;
        err = 0;
        {
            nyconc::GilRelease un;
            r = f();
            if (r < 0) err = errno;
        }
        if (r < 0 && err == EINTR) {
            if (nyconc::signal_pending()) nyconc::run_signal_handlers();
            continue;
        }
        return r;
    }
}
// A list of ints (a signal set, cpu ids, groups) from a list/tuple/set value.
std::vector<long long> int_items(NythonExecutor& E, const Value& v) {
    std::vector<long long> out;
    for (auto& x : nyos::list_items(v)) {
        if (x.type != ValueType::INTEGER && x.type != ValueType::BOOLEAN)
            raise("TypeError", "'" + E.typeNameOf(x) + "' object cannot be interpreted as an integer");
        out.push_back(nyos::to_int(x, 0));
    }
    return out;
}
// sigset from signal numbers (CPython's iterable_to_sigset: range checked)
sigset_t sigset_of(NythonExecutor& E, const Value& v) {
    sigset_t s;
    sigemptyset(&s);
    for (long long n : int_items(E, v)) {
        if (n < 1 || n >= NSIG) raise("ValueError", "signal number " + std::to_string(n) + " out of range [1; " + std::to_string(NSIG - 1) + "]");
        sigaddset(&s, (int)n);
    }
    return s;
}
Value sigset_list(NythonExecutor& E, const sigset_t& s) {
    std::vector<Value> out;
    for (int i = 1; i < NSIG; i++) if (sigismember(&s, i) == 1) out.push_back(make_int(i));
    return make_list(E, out);
}
Value siginfo_list(NythonExecutor& E, const siginfo_t& si) {
    long long band = 0;
#if defined(__linux__)
    band = (long long)si.si_band;
#endif
    return make_list(E, {make_int(si.si_signo), make_int(si.si_code), make_int(si.si_errno), make_int((long long)si.si_pid),
                         make_int((long long)si.si_uid), make_int((long long)si.si_status), make_int(band)});
}
Value rusage_list(NythonExecutor& E, const struct rusage& ru) {
    auto tv = [](const struct timeval& t) { return Value((double)t.tv_sec + (double)t.tv_usec * 1e-6); };
    return make_list(E, {tv(ru.ru_utime), tv(ru.ru_stime), make_int(ru.ru_maxrss), make_int(ru.ru_ixrss),
                         make_int(ru.ru_idrss), make_int(ru.ru_isrss), make_int(ru.ru_minflt), make_int(ru.ru_majflt),
                         make_int(ru.ru_nswap), make_int(ru.ru_inblock), make_int(ru.ru_oublock), make_int(ru.ru_msgsnd),
                         make_int(ru.ru_msgrcv), make_int(ru.ru_nsignals), make_int(ru.ru_nvcsw), make_int(ru.ru_nivcsw)});
}

// ── the name tables of sysconf / pathconf / confstr (CPython's own) ────────
struct NameVal { const char* n; int v; };
const std::vector<NameVal>& confstr_table() {
    static const std::vector<NameVal> t = {
#ifdef _CS_GNU_LIBC_VERSION
    {"CS_GNU_LIBC_VERSION", _CS_GNU_LIBC_VERSION},
#endif
#ifdef _CS_GNU_LIBPTHREAD_VERSION
    {"CS_GNU_LIBPTHREAD_VERSION", _CS_GNU_LIBPTHREAD_VERSION},
#endif
#ifdef _CS_LFS64_CFLAGS
    {"CS_LFS64_CFLAGS", _CS_LFS64_CFLAGS},
#endif
#ifdef _CS_LFS64_LDFLAGS
    {"CS_LFS64_LDFLAGS", _CS_LFS64_LDFLAGS},
#endif
#ifdef _CS_LFS64_LIBS
    {"CS_LFS64_LIBS", _CS_LFS64_LIBS},
#endif
#ifdef _CS_LFS64_LINTFLAGS
    {"CS_LFS64_LINTFLAGS", _CS_LFS64_LINTFLAGS},
#endif
#ifdef _CS_LFS_CFLAGS
    {"CS_LFS_CFLAGS", _CS_LFS_CFLAGS},
#endif
#ifdef _CS_LFS_LDFLAGS
    {"CS_LFS_LDFLAGS", _CS_LFS_LDFLAGS},
#endif
#ifdef _CS_LFS_LIBS
    {"CS_LFS_LIBS", _CS_LFS_LIBS},
#endif
#ifdef _CS_LFS_LINTFLAGS
    {"CS_LFS_LINTFLAGS", _CS_LFS_LINTFLAGS},
#endif
#ifdef _CS_PATH
    {"CS_PATH", _CS_PATH},
#endif
#ifdef _CS_XBS5_ILP32_OFF32_CFLAGS
    {"CS_XBS5_ILP32_OFF32_CFLAGS", _CS_XBS5_ILP32_OFF32_CFLAGS},
#endif
#ifdef _CS_XBS5_ILP32_OFF32_LDFLAGS
    {"CS_XBS5_ILP32_OFF32_LDFLAGS", _CS_XBS5_ILP32_OFF32_LDFLAGS},
#endif
#ifdef _CS_XBS5_ILP32_OFF32_LIBS
    {"CS_XBS5_ILP32_OFF32_LIBS", _CS_XBS5_ILP32_OFF32_LIBS},
#endif
#ifdef _CS_XBS5_ILP32_OFF32_LINTFLAGS
    {"CS_XBS5_ILP32_OFF32_LINTFLAGS", _CS_XBS5_ILP32_OFF32_LINTFLAGS},
#endif
#ifdef _CS_XBS5_ILP32_OFFBIG_CFLAGS
    {"CS_XBS5_ILP32_OFFBIG_CFLAGS", _CS_XBS5_ILP32_OFFBIG_CFLAGS},
#endif
#ifdef _CS_XBS5_ILP32_OFFBIG_LDFLAGS
    {"CS_XBS5_ILP32_OFFBIG_LDFLAGS", _CS_XBS5_ILP32_OFFBIG_LDFLAGS},
#endif
#ifdef _CS_XBS5_ILP32_OFFBIG_LIBS
    {"CS_XBS5_ILP32_OFFBIG_LIBS", _CS_XBS5_ILP32_OFFBIG_LIBS},
#endif
#ifdef _CS_XBS5_ILP32_OFFBIG_LINTFLAGS
    {"CS_XBS5_ILP32_OFFBIG_LINTFLAGS", _CS_XBS5_ILP32_OFFBIG_LINTFLAGS},
#endif
#ifdef _CS_XBS5_LP64_OFF64_CFLAGS
    {"CS_XBS5_LP64_OFF64_CFLAGS", _CS_XBS5_LP64_OFF64_CFLAGS},
#endif
#ifdef _CS_XBS5_LP64_OFF64_LDFLAGS
    {"CS_XBS5_LP64_OFF64_LDFLAGS", _CS_XBS5_LP64_OFF64_LDFLAGS},
#endif
#ifdef _CS_XBS5_LP64_OFF64_LIBS
    {"CS_XBS5_LP64_OFF64_LIBS", _CS_XBS5_LP64_OFF64_LIBS},
#endif
#ifdef _CS_XBS5_LP64_OFF64_LINTFLAGS
    {"CS_XBS5_LP64_OFF64_LINTFLAGS", _CS_XBS5_LP64_OFF64_LINTFLAGS},
#endif
#ifdef _CS_XBS5_LPBIG_OFFBIG_CFLAGS
    {"CS_XBS5_LPBIG_OFFBIG_CFLAGS", _CS_XBS5_LPBIG_OFFBIG_CFLAGS},
#endif
#ifdef _CS_XBS5_LPBIG_OFFBIG_LDFLAGS
    {"CS_XBS5_LPBIG_OFFBIG_LDFLAGS", _CS_XBS5_LPBIG_OFFBIG_LDFLAGS},
#endif
#ifdef _CS_XBS5_LPBIG_OFFBIG_LIBS
    {"CS_XBS5_LPBIG_OFFBIG_LIBS", _CS_XBS5_LPBIG_OFFBIG_LIBS},
#endif
#ifdef _CS_XBS5_LPBIG_OFFBIG_LINTFLAGS
    {"CS_XBS5_LPBIG_OFFBIG_LINTFLAGS", _CS_XBS5_LPBIG_OFFBIG_LINTFLAGS},
#endif
    };
    return t;
}
const std::vector<NameVal>& pathconf_table() {
    static const std::vector<NameVal> t = {
#ifdef _PC_ALLOC_SIZE_MIN
    {"PC_ALLOC_SIZE_MIN", _PC_ALLOC_SIZE_MIN},
#endif
#ifdef _PC_ASYNC_IO
    {"PC_ASYNC_IO", _PC_ASYNC_IO},
#endif
#ifdef _PC_CHOWN_RESTRICTED
    {"PC_CHOWN_RESTRICTED", _PC_CHOWN_RESTRICTED},
#endif
#ifdef _PC_FILESIZEBITS
    {"PC_FILESIZEBITS", _PC_FILESIZEBITS},
#endif
#ifdef _PC_LINK_MAX
    {"PC_LINK_MAX", _PC_LINK_MAX},
#endif
#ifdef _PC_MAX_CANON
    {"PC_MAX_CANON", _PC_MAX_CANON},
#endif
#ifdef _PC_MAX_INPUT
    {"PC_MAX_INPUT", _PC_MAX_INPUT},
#endif
#ifdef _PC_NAME_MAX
    {"PC_NAME_MAX", _PC_NAME_MAX},
#endif
#ifdef _PC_NO_TRUNC
    {"PC_NO_TRUNC", _PC_NO_TRUNC},
#endif
#ifdef _PC_PATH_MAX
    {"PC_PATH_MAX", _PC_PATH_MAX},
#endif
#ifdef _PC_PIPE_BUF
    {"PC_PIPE_BUF", _PC_PIPE_BUF},
#endif
#ifdef _PC_PRIO_IO
    {"PC_PRIO_IO", _PC_PRIO_IO},
#endif
#ifdef _PC_REC_INCR_XFER_SIZE
    {"PC_REC_INCR_XFER_SIZE", _PC_REC_INCR_XFER_SIZE},
#endif
#ifdef _PC_REC_MAX_XFER_SIZE
    {"PC_REC_MAX_XFER_SIZE", _PC_REC_MAX_XFER_SIZE},
#endif
#ifdef _PC_REC_MIN_XFER_SIZE
    {"PC_REC_MIN_XFER_SIZE", _PC_REC_MIN_XFER_SIZE},
#endif
#ifdef _PC_REC_XFER_ALIGN
    {"PC_REC_XFER_ALIGN", _PC_REC_XFER_ALIGN},
#endif
#ifdef _PC_SOCK_MAXBUF
    {"PC_SOCK_MAXBUF", _PC_SOCK_MAXBUF},
#endif
#ifdef _PC_SYMLINK_MAX
    {"PC_SYMLINK_MAX", _PC_SYMLINK_MAX},
#endif
#ifdef _PC_SYNC_IO
    {"PC_SYNC_IO", _PC_SYNC_IO},
#endif
#ifdef _PC_VDISABLE
    {"PC_VDISABLE", _PC_VDISABLE},
#endif
    };
    return t;
}
const std::vector<NameVal>& sysconf_table() {
    static const std::vector<NameVal> t = {
#include "os_posix_sysconf.inc"
    };
    return t;
}
// A name argument of sysconf/pathconf/confstr: an int, or a key of the table
int conf_name(NythonExecutor& E, const Value& v, const std::vector<NameVal>& t) {
    if (v.type == ValueType::INTEGER) return (int)nyos::to_int(v, 0);
    if (!E.isStringValue(v)) raise("TypeError", "configuration names must be strings or integers");
    std::string n = E.getStringValue(v);
    for (auto& e : t) if (n == e.n) return e.v;
    raise("ValueError", "unrecognized configuration name");
}
Value table_pairs(NythonExecutor& E, const std::vector<NameVal>& t) {
    std::vector<Value> out;
    for (auto& e : t) out.push_back(tuple_of(E, {E.makeStringValue(e.n), make_int(e.v)}));
    return make_list(E, out);
}
#endif

} // namespace

namespace nyos {

Value os_call_posix(NythonExecutor& E, const std::string& op, std::vector<Value>& args) {
#ifdef _WIN32
    (void)E; (void)op; (void)args;
    return UNDEFINED_VALUE;
#else
    auto A = [&](size_t i) -> Value { return i + 1 < args.size() ? args[i + 1] : NONE_VALUE; };
    auto I = [&](size_t i, long long d) -> long long { return i + 1 < args.size() ? to_int(args[i + 1], d) : d; };
    auto S = [&](size_t i) -> std::string { return i + 1 < args.size() ? E.getStringValue(args[i + 1]) : std::string(); };
    auto B = [&](size_t i) -> bool { return i + 1 < args.size() && E.isTruthy(args[i + 1]); };
    auto N = [&](size_t i) -> bool { return i + 1 >= args.size() || args[i + 1].type == ValueType::NONE; };
    auto Str = [&](const std::string& s) { return E.makeStringValue(s); };
    auto FD = [&](size_t i) -> int { return fdv(E, A(i)); };
    auto ok = [&](int r, const std::string& path = "") { if (r != 0) raise_errno(errno, path); return NONE_VALUE; };

    // ── constants: [(name, value), ...] ─────────────────────────────────────
    if (op == "posix_constants") {
        std::vector<std::pair<const char*, long long>> c;
#define NYC(n) c.push_back({#n, (long long)(n)})
#ifdef CLD_EXITED
        NYC(CLD_EXITED); NYC(CLD_KILLED); NYC(CLD_DUMPED); NYC(CLD_TRAPPED); NYC(CLD_STOPPED); NYC(CLD_CONTINUED);
#endif
#ifdef NY_HAVE_EVENTFD
        NYC(EFD_CLOEXEC); NYC(EFD_NONBLOCK); NYC(EFD_SEMAPHORE);
#endif
#ifdef EX_OK
        NYC(EX_OK); NYC(EX_USAGE); NYC(EX_DATAERR); NYC(EX_NOINPUT); NYC(EX_NOUSER); NYC(EX_NOHOST); NYC(EX_UNAVAILABLE);
        NYC(EX_SOFTWARE); NYC(EX_OSERR); NYC(EX_OSFILE); NYC(EX_CANTCREAT); NYC(EX_IOERR); NYC(EX_TEMPFAIL);
        NYC(EX_PROTOCOL); NYC(EX_NOPERM); NYC(EX_CONFIG);
#endif
#ifdef F_LOCK
        NYC(F_LOCK); NYC(F_TLOCK); NYC(F_ULOCK); NYC(F_TEST);
#endif
#ifdef NY_HAVE_GETRANDOM
        NYC(GRND_NONBLOCK); NYC(GRND_RANDOM);
#endif
#ifdef MFD_CLOEXEC
        NYC(MFD_CLOEXEC); NYC(MFD_ALLOW_SEALING); NYC(MFD_HUGETLB);
#endif
#ifdef MFD_HUGE_SHIFT
        NYC(MFD_HUGE_SHIFT); NYC(MFD_HUGE_MASK); NYC(MFD_HUGE_64KB); NYC(MFD_HUGE_512KB); NYC(MFD_HUGE_1MB);
        NYC(MFD_HUGE_2MB); NYC(MFD_HUGE_8MB); NYC(MFD_HUGE_16MB); NYC(MFD_HUGE_32MB); NYC(MFD_HUGE_256MB);
        NYC(MFD_HUGE_512MB); NYC(MFD_HUGE_1GB); NYC(MFD_HUGE_2GB); NYC(MFD_HUGE_16GB);
#endif
#ifdef NGROUPS_MAX
        NYC(NGROUPS_MAX);
#endif
#ifdef O_FSYNC
        NYC(O_FSYNC);
#endif
#ifdef POSIX_FADV_NORMAL
        NYC(POSIX_FADV_NORMAL); NYC(POSIX_FADV_SEQUENTIAL); NYC(POSIX_FADV_RANDOM); NYC(POSIX_FADV_NOREUSE);
        NYC(POSIX_FADV_WILLNEED); NYC(POSIX_FADV_DONTNEED);
#endif
        c.push_back({"POSIX_SPAWN_OPEN", 0}); c.push_back({"POSIX_SPAWN_CLOSE", 1}); c.push_back({"POSIX_SPAWN_DUP2", 2});
        NYC(PRIO_PROCESS); NYC(PRIO_PGRP); NYC(PRIO_USER);
#if defined(__linux__)
        c.push_back({"P_PID", (long long)P_PID}); c.push_back({"P_PGID", (long long)P_PGID}); c.push_back({"P_ALL", (long long)P_ALL});
        c.push_back({"P_PIDFD", 3});
#endif
        NYC(RTLD_LAZY); NYC(RTLD_NOW); NYC(RTLD_GLOBAL); NYC(RTLD_LOCAL);
#ifdef RTLD_NODELETE
        NYC(RTLD_NODELETE);
#endif
#ifdef RTLD_NOLOAD
        NYC(RTLD_NOLOAD);
#endif
#ifdef RTLD_DEEPBIND
        NYC(RTLD_DEEPBIND);
#endif
#ifdef RWF_HIPRI
        NYC(RWF_HIPRI); NYC(RWF_DSYNC); NYC(RWF_SYNC); NYC(RWF_NOWAIT);
#endif
#ifdef RWF_APPEND
        NYC(RWF_APPEND);
#endif
        NYC(SCHED_OTHER); NYC(SCHED_FIFO); NYC(SCHED_RR);
#ifdef SCHED_BATCH
        NYC(SCHED_BATCH);
#endif
#ifdef SCHED_IDLE
        NYC(SCHED_IDLE);
#endif
#ifdef SCHED_RESET_ON_FORK
        NYC(SCHED_RESET_ON_FORK);
#endif
#ifdef SPLICE_F_MOVE
        NYC(SPLICE_F_MOVE); NYC(SPLICE_F_NONBLOCK); NYC(SPLICE_F_MORE);
#endif
        NYC(ST_RDONLY); NYC(ST_NOSUID);
#ifdef ST_NODEV
        NYC(ST_NODEV); NYC(ST_NOEXEC); NYC(ST_SYNCHRONOUS); NYC(ST_MANDLOCK); NYC(ST_WRITE); NYC(ST_APPEND);
        NYC(ST_NOATIME); NYC(ST_NODIRATIME); NYC(ST_RELATIME);
#endif
        NYC(TMP_MAX);
#ifdef WEXITED
        NYC(WEXITED); NYC(WSTOPPED); NYC(WNOWAIT);
#endif
#ifdef NY_HAVE_XATTR
#  ifdef XATTR_CREATE
        NYC(XATTR_CREATE); NYC(XATTR_REPLACE);
#  endif
#  ifdef XATTR_SIZE_MAX
        NYC(XATTR_SIZE_MAX);
#  endif
#endif
#if defined(__linux__)
#  ifdef CLONE_VM
        NYC(CLONE_FILES); NYC(CLONE_FS); NYC(CLONE_NEWCGROUP); NYC(CLONE_NEWIPC); NYC(CLONE_NEWNET); NYC(CLONE_NEWNS);
        NYC(CLONE_NEWPID); NYC(CLONE_NEWUSER); NYC(CLONE_NEWUTS); NYC(CLONE_SIGHAND); NYC(CLONE_SYSVSEM);
        NYC(CLONE_THREAD); NYC(CLONE_VM);
#  endif
#  ifdef CLONE_NEWTIME
        NYC(CLONE_NEWTIME);
#  endif
#endif
        return pairs(E, c);
    }
    if (op == "clock_constants") {
        std::vector<std::pair<const char*, long long>> c;
        NYC(CLOCK_REALTIME); NYC(CLOCK_MONOTONIC);
#ifdef CLOCK_PROCESS_CPUTIME_ID
        NYC(CLOCK_PROCESS_CPUTIME_ID);
#endif
#ifdef CLOCK_THREAD_CPUTIME_ID
        NYC(CLOCK_THREAD_CPUTIME_ID);
#endif
#ifdef CLOCK_MONOTONIC_RAW
        NYC(CLOCK_MONOTONIC_RAW);
#endif
#ifdef CLOCK_BOOTTIME
        NYC(CLOCK_BOOTTIME);
#endif
#ifdef CLOCK_TAI
        NYC(CLOCK_TAI);
#endif
#ifdef CLOCK_UPTIME_RAW
        NYC(CLOCK_UPTIME_RAW);
#endif
#ifdef CLOCK_HIGHRES
        NYC(CLOCK_HIGHRES);
#endif
#ifdef CLOCK_PROF
        NYC(CLOCK_PROF);
#endif
#ifdef CLOCK_UPTIME
        NYC(CLOCK_UPTIME);
#endif
        return pairs(E, c);
    }
    if (op == "signal_constants") {
        std::vector<std::pair<const char*, long long>> c;
        NYC(SIG_BLOCK); NYC(SIG_UNBLOCK); NYC(SIG_SETMASK);
        c.push_back({"SIGRTMIN", (long long)SIGRTMIN}); c.push_back({"SIGRTMAX", (long long)SIGRTMAX});
#ifdef SIGCLD
        NYC(SIGCLD);
#endif
#ifdef SIGIOT
        NYC(SIGIOT);
#endif
#ifdef SIGPOLL
        NYC(SIGPOLL);
#endif
#ifdef SIGPWR
        NYC(SIGPWR);
#endif
#ifdef SIGSTKFLT
        NYC(SIGSTKFLT);
#endif
#ifdef SIGEMT
        NYC(SIGEMT);
#endif
#ifdef SIGINFO
        NYC(SIGINFO);
#endif
        c.push_back({"NSIG", (long long)NSIG});
        return pairs(E, c);
    }
#undef NYC
    if (op == "socket_constants") {
        // the socket module's integer constants it did not have (CPython's
        // names), from this platform's headers
        std::vector<std::pair<const char*, long long>> c;
        auto C = [&](const char* n, long long v) { c.push_back({n, v}); };
#include "os_posix_socket.inc"
        return pairs(E, c);
    }
    if (op == "sysconf_names") return table_pairs(E, sysconf_table());
    if (op == "pathconf_names") return table_pairs(E, pathconf_table());
    if (op == "confstr_names") return table_pairs(E, confstr_table());

    // ── process ───────────────────────────────────────────────────────────
    if (op == "abort") { std::fflush(nullptr); ::abort(); }
    if (op == "chroot") { std::string p = S(0); return ok(::chroot(p.c_str()), p); }
    if (op == "ctermid") { char buf[L_ctermid + 1] = {0}; char* r = ::ctermid(buf); return Str(r ? r : ""); }
    if (op == "fchdir") return ok(::fchdir(FD(0)));
    if (op == "fdatasync") {
        int fd = FD(0), err;
#if defined(__APPLE__)
        long long r = blocking([&] { return (long long)::fsync(fd); }, err);
#else
        long long r = blocking([&] { return (long long)::fdatasync(fd); }, err);
#endif
        if (r < 0) raise_errno(err, "");
        return NONE_VALUE;
    }
    if (op == "sync") { nyconc::GilRelease un; ::sync(); return NONE_VALUE; }
    if (op == "setpgrp") return ok(::setpgid(0, 0));
    if (op == "nice") {
        errno = 0;
        int r = ::nice((int)I(0, 0));
        if (r == -1 && errno != 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "getpriority") {
        errno = 0;
        int r = ::getpriority((int)I(0, 0), (id_t)I(1, 0));
        if (r == -1 && errno != 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "setpriority") return ok(::setpriority((int)I(0, 0), (id_t)I(1, 0), (int)I(2, 0)));
    if (op == "setuid") return ok(::setuid((uid_t)I(0, 0)));
    if (op == "setgid") return ok(::setgid((gid_t)I(0, 0)));
    if (op == "seteuid") return ok(::seteuid((uid_t)I(0, 0)));
    if (op == "setegid") return ok(::setegid((gid_t)I(0, 0)));
    if (op == "setreuid") return ok(::setreuid((uid_t)I(0, -1), (uid_t)I(1, -1)));
    if (op == "setregid") return ok(::setregid((gid_t)I(0, -1), (gid_t)I(1, -1)));
#if defined(__linux__)
    if (op == "getresuid" || op == "getresgid") {
        unsigned r = 0, e = 0, s = 0;
        int rc = op == "getresuid" ? ::getresuid((uid_t*)&r, (uid_t*)&e, (uid_t*)&s) : ::getresgid((gid_t*)&r, (gid_t*)&e, (gid_t*)&s);
        if (rc != 0) raise_errno(errno, "");
        return tuple_of(E, {make_int(r), make_int(e), make_int(s)});
    }
    if (op == "setresuid") return ok(::setresuid((uid_t)I(0, -1), (uid_t)I(1, -1), (uid_t)I(2, -1)));
    if (op == "setresgid") return ok(::setresgid((gid_t)I(0, -1), (gid_t)I(1, -1), (gid_t)I(2, -1)));
#endif
    if (op == "setgroups") {
        std::vector<gid_t> g;
        for (long long x : int_items(E, A(0))) g.push_back((gid_t)x);
        return ok(::setgroups(g.size(), g.empty() ? nullptr : g.data()));
    }
    if (op == "initgroups") return ok(::initgroups(S(0).c_str(), (gid_t)I(1, 0)));
    if (op == "getgrouplist") {
        std::string user = S(0);
        int n = 64;
        std::vector<gid_t> g;
        while (true) {
            g.assign((size_t)n, 0);
            int cnt = n;
#if defined(__APPLE__)
            int r = ::getgrouplist(user.c_str(), (int)I(1, 0), (int*)g.data(), &cnt);
#else
            int r = ::getgrouplist(user.c_str(), (gid_t)I(1, 0), g.data(), &cnt);
#endif
            if (r >= 0) { g.resize((size_t)cnt); break; }
            if (n > 65536) raise_errno(EINVAL, "");
            n = cnt > n ? cnt : n * 2;
        }
        std::vector<Value> out;
        for (gid_t x : g) out.push_back(make_int((long long)x));
        return make_list(E, out);
    }
    if (op == "tcgetpgrp") {
        pid_t r = ::tcgetpgrp(FD(0));
        if (r < 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "tcsetpgrp") return ok(::tcsetpgrp(FD(0), (pid_t)I(1, 0)));
#if defined(__linux__)
    if (op == "setns") return ok(::setns(FD(0), (int)I(1, 0)));
    if (op == "unshare") return ok(::unshare((int)I(0, 0)));
#endif

    // ── wait3 / wait4 / waitid ────────────────────────────────────────────
    if (op == "wait4" || op == "wait3") {
        pid_t pid = op == "wait4" ? (pid_t)I(0, -1) : (pid_t)-1;
        int opts = (int)I(op == "wait4" ? 1 : 0, 0), status = 0, err;
        struct rusage ru;
        std::memset(&ru, 0, sizeof ru);
        long long r = blocking([&] { return (long long)::wait4(pid, &status, opts, &ru); }, err);
        if (r < 0) raise_errno(err, "");
        return tuple_of(E, {make_int(r), make_int(status), rusage_list(E, ru)});
    }
#if defined(__linux__) || defined(__APPLE__)
    if (op == "waitid") {
        idtype_t idt = (idtype_t)I(0, 0);
        id_t id = (id_t)I(1, 0);
        int opts = (int)I(2, 0), err;
        siginfo_t si;
        std::memset(&si, 0, sizeof si);
        long long r = blocking([&] { return (long long)::waitid(idt, id, &si, opts); }, err);
        if (r < 0) raise_errno(err, "");
        if (si.si_pid == 0) return NONE_VALUE;   // WNOHANG and nothing to report
        return make_list(E, {make_int((long long)si.si_pid), make_int((long long)si.si_uid), make_int(si.si_signo),
                             make_int((long long)si.si_status), make_int(si.si_code)});
    }
#endif

    // ── the scheduler ───────────────────────────────────────────────────────
    if (op == "sched_get_priority_max" || op == "sched_get_priority_min") {
        int r = op == "sched_get_priority_max" ? ::sched_get_priority_max((int)I(0, 0)) : ::sched_get_priority_min((int)I(0, 0));
        if (r < 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "sched_yield") { ::sched_yield(); return NONE_VALUE; }
#if defined(__linux__)
    if (op == "sched_getscheduler") {
        int r = ::sched_getscheduler((pid_t)I(0, 0));
        if (r < 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "sched_setscheduler") {
        struct sched_param sp;
        std::memset(&sp, 0, sizeof sp);
        sp.sched_priority = (int)I(2, 0);
        if (::sched_setscheduler((pid_t)I(0, 0), (int)I(1, 0), &sp) < 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    if (op == "sched_getparam") {
        struct sched_param sp;
        if (::sched_getparam((pid_t)I(0, 0), &sp) < 0) raise_errno(errno, "");
        return make_int(sp.sched_priority);
    }
    if (op == "sched_setparam") {
        struct sched_param sp;
        std::memset(&sp, 0, sizeof sp);
        sp.sched_priority = (int)I(1, 0);
        return ok(::sched_setparam((pid_t)I(0, 0), &sp));
    }
    if (op == "sched_rr_get_interval") {
        struct timespec ts;
        if (::sched_rr_get_interval((pid_t)I(0, 0), &ts) < 0) raise_errno(errno, "");
        return Value((double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec);
    }
    if (op == "sched_setaffinity") {
        cpu_set_t set;
        CPU_ZERO(&set);
        for (long long c : int_items(E, A(1))) {
            if (c < 0) raise("ValueError", "negative CPU number");
            if (c >= CPU_SETSIZE) raise("ValueError", "invalid CPU number");   // the kernel's set is fixed here
            CPU_SET((int)c, &set);
        }
        return ok(::sched_setaffinity((pid_t)I(0, 0), sizeof set, &set));
    }
#endif

    // ── sysconf / pathconf / fpathconf / confstr ───────────────────────────
    if (op == "sysconf") {
        int name = conf_name(E, A(0), sysconf_table());
        errno = 0;
        long r = ::sysconf(name);
        if (r == -1 && errno != 0) raise_errno(errno, "");
        return make_int(r);
    }
    if (op == "pathconf" || op == "fpathconf") {
        int name = conf_name(E, A(1), pathconf_table());
        errno = 0;
        long r;
        std::string p;
        if (op == "fpathconf" || A(0).type == ValueType::INTEGER) r = ::fpathconf(FD(0), name);
        else { p = S(0); r = ::pathconf(p.c_str(), name); }
        if (r == -1 && errno != 0) raise_errno(errno, p);
        return make_int(r);
    }
    if (op == "confstr") {
        int name = conf_name(E, A(0), confstr_table());
        errno = 0;
        size_t n = ::confstr(name, nullptr, 0);
        if (n == 0) {
            if (errno) raise_errno(errno, "");
            return NONE_VALUE;
        }
        std::string buf(n, '\0');
        ::confstr(name, &buf[0], n);
        buf.resize(n - 1);
        return Str(buf);
    }

    // ── statvfs ─────────────────────────────────────────────────────────────
    if (op == "statvfs" || op == "fstatvfs") {
        struct statvfs st;
        std::string p;
        int r, err;
        if (op == "fstatvfs" || A(0).type == ValueType::INTEGER) { int fd = FD(0); r = (int)blocking([&] { return (long long)::fstatvfs(fd, &st); }, err); }
        else { p = S(0); r = (int)blocking([&] { return (long long)::statvfs(p.c_str(), &st); }, err); }
        if (r != 0) raise_errno(err, p);
        return make_list(E, {make_int((long long)st.f_bsize), make_int((long long)st.f_frsize), make_int((long long)st.f_blocks),
                             make_int((long long)st.f_bfree), make_int((long long)st.f_bavail), make_int((long long)st.f_files),
                             make_int((long long)st.f_ffree), make_int((long long)st.f_favail), make_int((long long)st.f_flag),
                             make_int((long long)st.f_namemax), make_int((long long)st.f_fsid)});
    }

    // ── descriptors ───────────────────────────────────────────────────────
    if (op == "pipe2") {
        int fds[2];
#if defined(__linux__)
        if (::pipe2(fds, (int)I(0, 0)) != 0) raise_errno(errno, "");
#else
        if (::pipe(fds) != 0) raise_errno(errno, "");
#endif
        return tuple_of(E, {make_int(fds[0]), make_int(fds[1])});
    }
    if (op == "lockf") {
        int fd = FD(0), cmd = (int)I(1, 0), err;
        off_t len = (off_t)I(2, 0);
        long long r = blocking([&] { return (long long)::lockf(fd, cmd, len); }, err);
        if (r < 0) raise_errno(err, "");
        return NONE_VALUE;
    }
#if defined(__linux__)
    if (op == "posix_fadvise" || op == "posix_fallocate") {
        int fd = FD(0);
        off_t off = (off_t)I(1, 0), len = (off_t)I(2, 0);
        int r;
        while (true) {
            if (op == "posix_fadvise") r = ::posix_fadvise(fd, off, len, (int)I(3, 0));
            else { nyconc::GilRelease un; r = ::posix_fallocate(fd, off, len); }
            if (r == EINTR) { if (nyconc::signal_pending()) nyconc::run_signal_handlers(); continue; }
            break;
        }
        if (r != 0) raise_errno(r, "");   // these return the error instead of setting errno
        return NONE_VALUE;
    }
    if (op == "copy_file_range" || op == "splice") {
        int src = FD(0), dst = FD(1), err;
        long long count = I(2, 0);
        if (count < 0) raise("ValueError", "count cannot be negative");
        bool hs = !N(3), hd = !N(4);
        loff_t os = hs ? (loff_t)I(3, 0) : 0, od = hd ? (loff_t)I(4, 0) : 0;
        unsigned flags = (unsigned)I(5, 0);
        long long r;
        if (op == "copy_file_range")
            r = blocking([&] { return (long long)::copy_file_range(src, hs ? &os : nullptr, dst, hd ? &od : nullptr, (size_t)count, 0); }, err);
        else
            r = blocking([&] { return (long long)::splice(src, hs ? &os : nullptr, dst, hd ? &od : nullptr, (size_t)count, flags); }, err);
        if (r < 0) raise_errno(err, "");
        return make_int(r);
    }
    if (op == "memfd_create") {
        std::string name = S(0);
        int fd = (int)::syscall(SYS_memfd_create, name.c_str(), (unsigned)I(1, 1));
        if (fd < 0) raise_errno(errno, "");
        return make_int(fd);
    }
#  ifdef SYS_pidfd_open
    if (op == "pidfd_open") {
        int fd = (int)::syscall(SYS_pidfd_open, (pid_t)I(0, 0), (unsigned)I(1, 0));
        if (fd < 0) raise_errno(errno, "");
        return make_int(fd);
    }
#  endif
#  ifdef SYS_pidfd_send_signal
    if (op == "pidfd_send_signal") {
        long long sig = I(1, 0);
        int r = (int)::syscall(SYS_pidfd_send_signal, FD(0), (int)sig, nullptr, (unsigned)I(3, 0));
        if (r < 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
#  endif
#endif
#ifdef NY_HAVE_EVENTFD
    if (op == "eventfd") {
        int fd = ::eventfd((unsigned)I(0, 0), (int)I(1, EFD_CLOEXEC));
        if (fd < 0) raise_errno(errno, "");
        return make_int(fd);
    }
    if (op == "eventfd_read") {
        int fd = FD(0), err;
        eventfd_t v = 0;
        long long r = blocking([&] { return (long long)::eventfd_read(fd, &v); }, err);
        if (r < 0) raise_errno(err, "");
        return make_int((long long)v);
    }
    if (op == "eventfd_write") {
        int fd = FD(0), err;
        Value vv = A(1);
        if (vv.type != ValueType::INTEGER) raise("TypeError", "'" + E.typeNameOf(vv) + "' object cannot be interpreted as an integer");
        nypy::BigInt bv = bigint_to_nbig(vv.value.i);
        uint64_t u = 0;
        if (bv.neg || bv.bit_length() > 64) raise("OverflowError", "Python int too large to convert to C unsigned long");
        for (size_t k = bv.mag.size(); k-- > 0;) u = (u << 32) | bv.mag[k];
        long long r = blocking([&] { return (long long)::eventfd_write(fd, (eventfd_t)u); }, err);
        if (r < 0) raise_errno(err, "");
        return NONE_VALUE;
    }
#endif
#ifdef NY_HAVE_GETRANDOM
    if (op == "getrandom") {
        long long n = I(0, 0);
        if (n < 0) raise_errno(EINVAL, "");
        unsigned flags = (unsigned)I(1, 0);
        std::string buf((size_t)n, '\0');
        int err;
        long long r = blocking([&] { return (long long)::getrandom(n ? &buf[0] : nullptr, (size_t)n, flags); }, err);
        if (r < 0) raise_errno(err, "");
        buf.resize((size_t)r);
        return E.makeBytesValue(buf);
    }
#endif

    // ── extended attributes ────────────────────────────────────────────────
#ifdef NY_HAVE_XATTR
    if (op == "getxattr" || op == "setxattr" || op == "listxattr" || op == "removexattr") {
        // a0: a path (str) or a descriptor (int) or None (listxattr: "."),
        // the attribute name next, follow_symlinks last
        Value tgt = A(0);
        bool is_fd = tgt.type == ValueType::INTEGER;
        int fd = is_fd ? FD(0) : -1;
        std::string path = is_fd ? std::string() : tgt.type == ValueType::NONE ? std::string(".") : S(0);
        bool follow = args.size() > 1 ? E.isTruthy(args.back()) : true;
        std::string shown = is_fd ? std::string() : path;
        if (op == "listxattr") {
            std::vector<char> buf(256);
            ssize_t r;
            while (true) {
                r = is_fd ? ::flistxattr(fd, buf.data(), buf.size())
                    : follow ? ::listxattr(path.c_str(), buf.data(), buf.size()) : ::llistxattr(path.c_str(), buf.data(), buf.size());
                if (r < 0 && errno == ERANGE && buf.size() < (1u << 24)) { buf.resize(buf.size() * 4); continue; }
                break;
            }
            if (r < 0) raise_errno(errno, shown);
            std::vector<Value> out;
            size_t start = 0;
            for (size_t k = 0; k < (size_t)r; k++)
                if (buf[k] == '\0') { if (k > start) out.push_back(Str(std::string(&buf[start], k - start))); start = k + 1; }
            return make_list(E, out);
        }
        std::string attr = bytes_or_str(E, A(1));
        if (op == "getxattr") {
            std::vector<char> buf(128);
            ssize_t r;
            while (true) {
                r = is_fd ? ::fgetxattr(fd, attr.c_str(), buf.data(), buf.size())
                    : follow ? ::getxattr(path.c_str(), attr.c_str(), buf.data(), buf.size())
                             : ::lgetxattr(path.c_str(), attr.c_str(), buf.data(), buf.size());
                if (r < 0 && errno == ERANGE && buf.size() < (1u << 24)) { buf.resize(buf.size() * 8); continue; }
                break;
            }
            if (r < 0) raise_errno(errno, shown);
            return E.makeBytesValue(std::string(buf.data(), (size_t)r));
        }
        if (op == "setxattr") {
            std::string value = bytes_or_str(E, A(2));
            int flags = (int)I(3, 0);
            int r = is_fd ? ::fsetxattr(fd, attr.c_str(), value.data(), value.size(), flags)
                    : follow ? ::setxattr(path.c_str(), attr.c_str(), value.data(), value.size(), flags)
                             : ::lsetxattr(path.c_str(), attr.c_str(), value.data(), value.size(), flags);
            if (r < 0) raise_errno(errno, shown);
            return NONE_VALUE;
        }
        int r = is_fd ? ::fremovexattr(fd, attr.c_str())
                : follow ? ::removexattr(path.c_str(), attr.c_str()) : ::lremovexattr(path.c_str(), attr.c_str());
        if (r < 0) raise_errno(errno, shown);
        return NONE_VALUE;
    }
#endif

    // ── posix_spawn / posix_spawnp ─────────────────────────────────────────
    // a0 path, a1 argv (list of str), a2 env (list of "K=V" or None: this
    // process's), a3 file_actions (list of tuples), a4 setpgroup (None or
    // int), a5 resetids, a6 setsid, a7 setsigmask (None or list), a8
    // setsigdef (None or list), a9 scheduler (None or (policy, priority)),
    // a10 use the PATH (posix_spawnp)
    if (op == "posix_spawn") {
        std::string path = S(0);
        std::vector<std::string> av, ev;
        for (auto& x : list_items(A(1))) av.push_back(E.getStringValue(x));
        bool has_env = !N(2);
        if (has_env) for (auto& x : list_items(A(2))) ev.push_back(E.getStringValue(x));
        posix_spawn_file_actions_t fa;
        posix_spawnattr_t at;
        bool has_fa = false;
        posix_spawnattr_init(&at);
        struct Done {
            posix_spawnattr_t* at; posix_spawn_file_actions_t* fa; bool* has;
            ~Done() { posix_spawnattr_destroy(at); if (*has) posix_spawn_file_actions_destroy(fa); }
        } done{&at, &fa, &has_fa};
        std::vector<std::string> keep;   // the paths file actions point at
        if (!N(3)) {
            auto acts = list_items(A(3));
            if (!acts.empty()) { posix_spawn_file_actions_init(&fa); has_fa = true; }
            keep.reserve(acts.size());
            for (auto& act : acts) {
                auto f = list_items(act);
                if (f.empty()) raise("TypeError", "Each file_actions element must be a non-empty tuple");
                long long tag = to_int(f[0], -1);
                int r = 0;
                if (tag == 0) {
                    if (f.size() != 5) raise("TypeError", "A open file_action tuple must have 5 elements");
                    keep.push_back(E.getStringValue(f[2]));
                    r = posix_spawn_file_actions_addopen(&fa, (int)to_int(f[1], 0), keep.back().c_str(), (int)to_int(f[3], 0), (mode_t)to_int(f[4], 0));
                } else if (tag == 1) {
                    if (f.size() != 2) raise("TypeError", "A close file_action tuple must have 2 elements");
                    r = posix_spawn_file_actions_addclose(&fa, (int)to_int(f[1], 0));
                } else if (tag == 2) {
                    if (f.size() != 3) raise("TypeError", "A dup2 file_action tuple must have 3 elements");
                    r = posix_spawn_file_actions_adddup2(&fa, (int)to_int(f[1], 0), (int)to_int(f[2], 0));
                } else raise("TypeError", "Unknown file_actions identifier");
                if (r != 0) raise_errno(r, "");
            }
        }
        short flags = 0;
        if (!N(4)) { flags |= POSIX_SPAWN_SETPGROUP; posix_spawnattr_setpgroup(&at, (pid_t)I(4, 0)); }
        if (B(5)) flags |= POSIX_SPAWN_RESETIDS;
        if (B(6)) {
#ifdef POSIX_SPAWN_SETSID
            flags |= POSIX_SPAWN_SETSID;
#else
            raise("NotImplementedError", "The setsid option is not supported on this platform.");
#endif
        }
        if (!N(7)) { sigset_t s = sigset_of(E, A(7)); flags |= POSIX_SPAWN_SETSIGMASK; posix_spawnattr_setsigmask(&at, &s); }
        if (!N(8)) { sigset_t s = sigset_of(E, A(8)); flags |= POSIX_SPAWN_SETSIGDEF; posix_spawnattr_setsigdefault(&at, &s); }
        if (!N(9)) {
#if defined(POSIX_SPAWN_SETSCHEDULER)
            auto sch = list_items(A(9));
            struct sched_param sp;
            std::memset(&sp, 0, sizeof sp);
            sp.sched_priority = sch.size() > 1 ? (int)to_int(sch[1], 0) : 0;
            if (!sch.empty() && sch[0].type != ValueType::NONE) {
                flags |= POSIX_SPAWN_SETSCHEDULER;
                posix_spawnattr_setschedpolicy(&at, (int)to_int(sch[0], 0));
            }
            flags |= POSIX_SPAWN_SETSCHEDPARAM;
            posix_spawnattr_setschedparam(&at, &sp);
#else
            raise("NotImplementedError", "The scheduler option is not supported in this system.");
#endif
        }
        if (flags) posix_spawnattr_setflags(&at, flags);
        std::vector<char*> argv, envp;
        for (auto& s : av) argv.push_back(const_cast<char*>(s.c_str()));
        argv.push_back(nullptr);
        for (auto& s : ev) envp.push_back(const_cast<char*>(s.c_str()));
        envp.push_back(nullptr);
        pid_t pid = 0;
        int r = B(10) ? ::posix_spawnp(&pid, path.c_str(), has_fa ? &fa : nullptr, &at, argv.data(), has_env ? envp.data() : environ)
                      : ::posix_spawn(&pid, path.c_str(), has_fa ? &fa : nullptr, &at, argv.data(), has_env ? envp.data() : environ);
        if (r != 0) raise_errno(r, path);
        return make_int(pid);
    }

    // ── time: the POSIX clocks ──────────────────────────────────────────────
    if (op == "clock_gettime" || op == "clock_gettime_ns" || op == "clock_getres") {
        struct timespec ts;
        clockid_t id = (clockid_t)I(0, 0);
        int r = op == "clock_getres" ? ::clock_getres(id, &ts) : ::clock_gettime(id, &ts);
        if (r != 0) raise_errno(errno, "");
        if (op == "clock_gettime_ns") {
            nypy::BigInt b = nypy::BigInt((int64_t)ts.tv_sec) * nypy::BigInt((int64_t)1000000000) + nypy::BigInt((int64_t)ts.tv_nsec);
            return intValue(b);
        }
        return Value((double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec);
    }
    if (op == "clock_settime" || op == "clock_settime_ns") {
        struct timespec ts;
        clockid_t id = (clockid_t)I(0, 0);
        Value t = A(1);
        if (op == "clock_settime") {
            double d = t.type == ValueType::DOUBLE ? (double)t.value.d : (double)to_int(t, 0);
            double sec = std::floor(d);
            ts.tv_sec = (time_t)sec;
            ts.tv_nsec = (long)std::llround((d - sec) * 1e9);
            if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        } else {
            long long ns = to_int(t, 0);
            long long sec = ns / 1000000000LL, rem = ns % 1000000000LL;
            if (rem < 0) { rem += 1000000000LL; sec--; }
            ts.tv_sec = (time_t)sec; ts.tv_nsec = (long)rem;
        }
        return ok(::clock_settime(id, &ts));
    }
    // (time.pthread_getcpuclockid and signal.pthread_kill need the runtime's
    // thread records: _sig_pthread in src/NyConc.cpp)

    // ── signal: masks and synchronous waits ────────────────────────────────
    if (op == "pthread_sigmask") {
        long long how = I(0, 0);
        sigset_t s = sigset_of(E, A(1)), old;
        int r = ::pthread_sigmask((int)how, &s, &old);
        if (r != 0) raise_errno(r, "");
        return sigset_list(E, old);
    }
    if (op == "sigpending") {
        sigset_t s;
        if (::sigpending(&s) != 0) raise_errno(errno, "");
        return sigset_list(E, s);
    }
    if (op == "sigwait") {
        sigset_t s = sigset_of(E, A(0));
        int sig = 0, r;
        { nyconc::GilRelease un; r = ::sigwait(&s, &sig); }
        if (r != 0) raise_errno(r, "");
        return make_int(sig);
    }
#if defined(__linux__)
    if (op == "sigwaitinfo" || op == "sigtimedwait") {
        sigset_t s = sigset_of(E, A(0));
        siginfo_t si;
        std::memset(&si, 0, sizeof si);
        struct timespec ts{};
        bool timed = op == "sigtimedwait";
        if (timed) {
            Value t = A(1);
            double d = t.type == ValueType::DOUBLE ? (double)t.value.d : (double)to_int(t, 0);
            if (d < 0) raise("ValueError", "timeout must be non-negative");
            ts.tv_sec = (time_t)d;
            ts.tv_nsec = (long)((d - (double)ts.tv_sec) * 1e9);
        }
        int err;
        long long r = blocking([&] { return (long long)(timed ? ::sigtimedwait(&s, &si, &ts) : ::sigwaitinfo(&s, &si)); }, err);
        if (r < 0) {
            if (timed && err == EAGAIN) return NONE_VALUE;
            raise_errno(err, "");
        }
        return siginfo_list(E, si);
    }
#endif
    // ── select.epoll (Linux) ──────────────────────────────────────────────
#ifdef NY_HAVE_EPOLL
    if (op == "select_constants") {
        std::vector<std::pair<const char*, long long>> c;
#define NYC(n) c.push_back({#n, (long long)(n)})
        NYC(EPOLLIN); NYC(EPOLLOUT); NYC(EPOLLPRI); NYC(EPOLLERR); NYC(EPOLLHUP); NYC(EPOLLRDHUP);
        NYC(EPOLLRDNORM); NYC(EPOLLRDBAND); NYC(EPOLLWRNORM); NYC(EPOLLWRBAND); NYC(EPOLLMSG);
        c.push_back({"EPOLLET", (long long)(unsigned)EPOLLET}); NYC(EPOLLONESHOT); NYC(EPOLL_CLOEXEC);
#  ifdef EPOLLEXCLUSIVE
        NYC(EPOLLEXCLUSIVE);
#  endif
        NYC(POLLRDNORM); NYC(POLLRDBAND); NYC(POLLWRNORM); NYC(POLLWRBAND); NYC(POLLMSG);
#  ifdef POLLRDHUP
        NYC(POLLRDHUP);
#  endif
        NYC(PIPE_BUF);
#undef NYC
        return pairs(E, c);
    }
    if (op == "epoll_create") {
        int fd = ::epoll_create1((int)I(0, 0) | EPOLL_CLOEXEC);
        if (fd < 0) raise_errno(errno, "");
        return make_int(fd);
    }
    if (op == "epoll_ctl") {
        // (epfd, op 1 add / 2 del / 3 mod, fd, events)
        struct epoll_event ev;
        std::memset(&ev, 0, sizeof ev);
        ev.events = (uint32_t)I(3, 0);
        ev.data.fd = (int)I(2, -1);
        if (::epoll_ctl(FD(0), (int)I(1, 0), (int)I(2, -1), &ev) != 0) raise_errno(errno, "");
        return NONE_VALUE;
    }
    if (op == "epoll_wait") {
        // (epfd, timeout in seconds or None, maxevents) -> [(fd, events)];
        // interrupted by a signal: the handlers run, the wait resumes with
        // the time left (PEP 475)
        int epfd = FD(0);
        bool forever = N(1);
        double secs = 0;
        if (!forever) { Value t = A(1); secs = t.type == ValueType::DOUBLE ? (double)t.value.d : (double)to_int(t, 0); }
        int maxev = (int)I(2, 1);
        std::vector<struct epoll_event> evs((size_t)std::max(1, maxev));
        auto deadline = std::chrono::steady_clock::now() + std::chrono::microseconds((long long)(secs * 1e6));
        int n, err;
        while (true) {
            int ms = -1;
            if (!forever) {
                double left = std::chrono::duration<double>(deadline - std::chrono::steady_clock::now()).count();
                ms = left <= 0 ? 0 : (int)std::min(std::ceil(left * 1000.0), 2147483647.0);
            }
            {
                nyconc::GilRelease un;
                n = ::epoll_wait(epfd, evs.data(), maxev, ms);
                err = n < 0 ? errno : 0;
            }
            if (n < 0 && err == EINTR) { if (nyconc::signal_pending()) nyconc::run_signal_handlers(); continue; }
            break;
        }
        if (n < 0) raise_errno(err, "");
        std::vector<Value> out;
        for (int k = 0; k < n; k++) out.push_back(tuple_of(E, {make_int(evs[(size_t)k].data.fd), make_int((long long)evs[(size_t)k].events)}));
        return make_list(E, out);
    }
#endif

    // ── locale: the C library's message catalogs (glibc's libintl) ─────────
    if (op == "intl") {
#ifdef NY_HAVE_LIBINTL
        std::string sub = S(0);
        std::string s1 = N(1) ? std::string() : S(1), s2 = N(2) ? std::string() : S(2);
        const char* p1 = N(1) ? nullptr : s1.c_str();
        const char* p2 = N(2) ? nullptr : s2.c_str();
        if (sub == "gettext") return Str(::gettext(p1 ? p1 : ""));
        if (sub == "dgettext") return Str(::dgettext(p1, p2 ? p2 : ""));
        if (sub == "dcgettext") return Str(::dcgettext(p1, p2 ? p2 : "", (int)I(3, LC_MESSAGES)));
        if (sub == "textdomain") {
            const char* r = ::textdomain(p1);
            if (!r) raise_errno(errno, "");
            return Str(r);
        }
        if (sub == "bindtextdomain") {
            if (!p1 || !*p1) raise_errno(EINVAL, "");
            errno = 0;
            const char* r = ::bindtextdomain(p1, p2);
            if (!r) raise_errno(errno ? errno : ENOMEM, "");
            return Str(r);
        }
        if (sub == "bind_textdomain_codeset") {
            errno = 0;
            const char* r = ::bind_textdomain_codeset(p1, p2);
            if (!r) { if (errno) raise_errno(errno, ""); return NONE_VALUE; }
            return Str(r);
        }
#endif
        return UNDEFINED_VALUE;
    }
    if (op == "valid_signals") {
        // CPython's: sigfillset's members (glibc keeps 32 and 33 for itself)
        sigset_t s;
        sigfillset(&s);
        return sigset_list(E, s);
    }
    if (op == "strsignal_raw") {
        const char* s = ::strsignal((int)I(0, 0));
        return s ? Str(s) : NONE_VALUE;
    }

    // ── socket: interfaces, hosts, ancillary data ──────────────────────────
    if (op == "CMSG_LEN" || op == "CMSG_SPACE") {
        long long n = I(0, 0);
        if (n < 0 || n > (long long)(INT_MAX - CMSG_SPACE(0))) raise("OverflowError", op + "() argument out of range");
        return make_int(op == "CMSG_LEN" ? (long long)CMSG_LEN((size_t)n) : (long long)CMSG_SPACE((size_t)n));
    }
    if (op == "if_nameindex") {
        struct if_nameindex* ni = ::if_nameindex();
        if (!ni) raise_errno(errno, "");
        std::vector<Value> out;
        for (struct if_nameindex* p = ni; p->if_index != 0; p++)
            out.push_back(tuple_of(E, {make_int((long long)p->if_index), Str(p->if_name ? p->if_name : "")}));
        ::if_freenameindex(ni);
        return make_list(E, out);
    }
    if (op == "if_nametoindex") {
        unsigned idx = ::if_nametoindex(bytes_or_str(E, A(0)).c_str());
        if (idx == 0) raise("OSError", "no interface with this name");
        return make_int(idx);
    }
    if (op == "if_indextoname") {
        long long idx = I(0, 0);
        if (idx < 0 || idx > (long long)UINT_MAX) raise("OverflowError", "index is too large");
        char buf[IF_NAMESIZE + 1] = {0};
        if (!::if_indextoname((unsigned)idx, buf)) raise_errno(errno, "");
        return Str(buf);
    }
    if (op == "sethostname") {
        std::string n = bytes_or_str(E, A(0));
        return ok(::sethostname(n.c_str(), n.size()));
    }
    if (op == "gethostbyname_ex") {
        // (hostname, aliases, addresses) of the IPv4 addresses, as CPython's
        std::string name = S(0);
        struct addrinfo hints;
        std::memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_INET;
        hints.ai_flags = AI_CANONNAME;
        struct addrinfo* res = nullptr;
        int rc;
        { nyconc::GilRelease un; rc = ::getaddrinfo(name.c_str(), nullptr, &hints, &res); }
        if (rc != 0) raise("gaierror", "[Errno " + std::to_string(rc) + "] " + ::gai_strerror(rc));
        std::string canon = res && res->ai_canonname ? res->ai_canonname : name;
        std::vector<Value> addrs;
        std::vector<std::string> seen;
        for (struct addrinfo* p = res; p; p = p->ai_next) {
            if (p->ai_family != AF_INET) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            ::inet_ntop(AF_INET, &((struct sockaddr_in*)p->ai_addr)->sin_addr, buf, sizeof buf);
            if (std::find(seen.begin(), seen.end(), std::string(buf)) != seen.end()) continue;
            seen.push_back(buf);
            addrs.push_back(Str(buf));
        }
        ::freeaddrinfo(res);
        std::vector<Value> aliases;
        return tuple_of(E, {Str(canon), make_list(E, aliases), make_list(E, addrs)});
    }
    if (op == "getprotobyname") {
        std::string name = S(0);
        struct protoent* pe = ::getprotobyname(name.c_str());
        if (!pe) raise("OSError", "protocol not found");
        return make_int(pe->p_proto);
    }
    // sendmsg(fd, data, [(level, type, data)...], flags) -> bytes sent;
    // EAGAIN raises BlockingIOError (lib/socket.ny waits and retries)
    if (op == "sendmsg") {
        int fd = FD(0);
        std::string data = bytes_or_str(E, A(1));
        std::string ctl;
        for (auto& item : list_items(A(2))) {
            auto f = list_items(item);
            if (f.size() != 3) raise("TypeError", "sendmsg() ancillary data items must be (level, type, data) tuples");
            std::string d = bytes_or_str(E, f[2]);
            size_t at = ctl.size();
            ctl.resize(at + CMSG_SPACE(d.size()), '\0');
            struct cmsghdr* cm = (struct cmsghdr*)&ctl[at];
            cm->cmsg_level = (int)to_int(f[0], 0);
            cm->cmsg_type = (int)to_int(f[1], 0);
            cm->cmsg_len = CMSG_LEN(d.size());
            if (!d.empty()) std::memcpy(CMSG_DATA(cm), d.data(), d.size());
        }
        struct iovec iov;
        iov.iov_base = data.empty() ? nullptr : &data[0];
        iov.iov_len = data.size();
        struct msghdr mh;
        std::memset(&mh, 0, sizeof mh);
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        if (!ctl.empty()) { mh.msg_control = &ctl[0]; mh.msg_controllen = ctl.size(); }
        ssize_t r;
        do r = ::sendmsg(fd, &mh, (int)I(3, 0) | MSG_DONTWAIT); while (r < 0 && errno == EINTR);
        if (r < 0) raise_errno(errno, "");
        return make_int((long long)r);
    }
    // recvmsg(fd, bufsize, ancbufsize, flags) -> (data, [(level, type, data)...], msg_flags)
    if (op == "recvmsg") {
        int fd = FD(0);
        long long bufsize = I(1, 0), ancsize = I(2, 0);
        if (bufsize < 0) raise("ValueError", "negative buffer size in recvmsg()");
        if (ancsize < 0) raise("ValueError", "negative buffer size in recvmsg()");
        std::string buf((size_t)bufsize, '\0'), ctl((size_t)ancsize, '\0');
        struct iovec iov;
        iov.iov_base = bufsize ? &buf[0] : nullptr;
        iov.iov_len = (size_t)bufsize;
        struct msghdr mh;
        std::memset(&mh, 0, sizeof mh);
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        if (ancsize) { mh.msg_control = &ctl[0]; mh.msg_controllen = (size_t)ancsize; }
        ssize_t r;
        do r = ::recvmsg(fd, &mh, (int)I(3, 0) | MSG_DONTWAIT
#ifdef MSG_CMSG_CLOEXEC
                         | MSG_CMSG_CLOEXEC
#endif
                         ); while (r < 0 && errno == EINTR);
        if (r < 0) raise_errno(errno, "");
        buf.resize((size_t)r);
        std::vector<Value> anc;
        if (ancsize)
            for (struct cmsghdr* cm = CMSG_FIRSTHDR(&mh); cm; cm = CMSG_NXTHDR(&mh, cm)) {
                size_t len = cm->cmsg_len - CMSG_LEN(0);
                anc.push_back(tuple_of(E, {make_int(cm->cmsg_level), make_int(cm->cmsg_type),
                                            E.makeBytesValue(std::string((const char*)CMSG_DATA(cm), len))}));
            }
        int mflags = mh.msg_flags;
#ifdef MSG_CMSG_CLOEXEC
        mflags &= ~MSG_CMSG_CLOEXEC;   // ours (received descriptors close on exec), not the caller's
#endif
        return tuple_of(E, {E.makeBytesValue(buf), make_list(E, anc), make_int(mflags)});
    }
    (void)Str;
    return UNDEFINED_VALUE;
#endif
}

} // namespace nyos

#pragma GCC diagnostic pop
