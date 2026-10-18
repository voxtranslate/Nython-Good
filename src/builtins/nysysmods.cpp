// builtins/nysysmods.cpp - the native side of Python's system modules
// (round 83): errno, fcntl, termios, pty (and the os process calls it
// needs), resource, syslog and locale. lib/<module>.ny is the Python-style
// module over each group; the VM reaches these through the builtin bridge.
// This file is also the one entry point (dispatch_sysmods) for the round's
// other natives: mmap (nymmap.cpp), bz2 (nybz2.cpp), lzma (nylzma.cpp),
// cmath (nycmath.cpp), faulthandler/tracemalloc (nyfault.cpp) and readline
// (nyreadline.cpp).
//
// Everything is the platform's own: the errno table, the fcntl/termios/
// resource/syslog constants and the locale items are generated here from the
// C headers (an #ifdef per name), so a value is what the C library uses.
// POSIX-only groups give an empty constant table on Windows, where the
// Python modules raise ModuleNotFoundError as CPython's do.
//
//   _sys_platform_posix() -> bool
//   _sys_errno_table() -> [[name, value], ...]  (CPython's errnomodule order)
//   _sys_consts(group) -> [[name, value], ...]  group: fcntl termios resource syslog locale mmap
//   _sys_fcntl(fd, cmd, arg)          int arg -> int; bytes arg -> bytes
//   _sys_ioctl(fd, request, arg)      int arg -> int; bytes arg -> [result, bytes]
//   _sys_flock(fd, op)                _sys_lockf(fd, code, len, start, whence)
//   _sys_tcgetattr(fd)                _sys_tcsetattr(fd, when, attrs)
//   _sys_tcsendbreak(fd, duration)    _sys_tcdrain(fd)   _sys_tcflush(fd, q)   _sys_tcflow(fd, a)
//   _sys_tcgetwinsize(fd)             _sys_tcsetwinsize(fd, rows, cols)
//   _sys_openpty() -> [master, slave] _sys_forkpty() -> [pid, fd]   _sys_fork() -> pid
//   _sys_login_tty(fd)                _sys_waitpid(pid, options) -> [pid, status]
//   _sys_wstatus(op, status)          WIFEXITED & co: op "exited" "exitstatus" "signaled" ...
//   _sys_execv(path, argv, env)       env none: the current environment
//   _sys_exit(status)                 _exit(2), no cleanup (os._exit)
//   _sys_ttyname(fd)
//   _sys_getrlimit(res) -> [soft, hard]   _sys_setrlimit(res, soft, hard)
//   _sys_prlimit(pid, res, set, soft, hard) -> [soft, hard] (the old limits)
//   _sys_getrusage(who) -> [utime, stime, maxrss, ...16 fields]
//   _sys_getpagesize()
//   _sys_openlog(ident, logoption, facility)   _sys_syslog(priority, message)
//   _sys_closelog()                   _sys_setlogmask(mask) -> old mask
//   _sys_setlocale(category, locale or none) -> name   (locale.Error as ValueError "\x01locale ...")
//   _sys_localeconv() -> dict         _sys_nl_langinfo(item) -> str
//   _sys_strcoll(a, b) -> int         _sys_strxfrm(s) -> str
//   _sys_win_locale() -> [lang_country, codepage] (Windows: the user's default)
//
// The process's LC_NUMERIC stays "C" (round 83): the engines format floats
// with the C library, and CPython's own float formatting ignores the locale;
// a program's LC_NUMERIC is remembered and put in place only while
// localeconv/nl_langinfo/setlocale(..., None) read it.
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "NyConc.hpp"
#include "builtins/os.hpp"
#include "builtins/sysmods.hpp"
#include <cerrno>
#include <climits>
#include <clocale>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <string>
#include <vector>
#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#  include <process.h>
#else
#  include <fcntl.h>
#  include <unistd.h>
#  include <termios.h>
#  include <sys/ioctl.h>
#  include <sys/file.h>
#  include <sys/resource.h>
#  include <sys/time.h>
#  include <sys/wait.h>
#  include <syslog.h>
#  include <langinfo.h>
#  if defined(__linux__)
#    include <pty.h>
#    include <utmp.h>
#  elif defined(__APPLE__)
#    include <util.h>
#  elif defined(__FreeBSD__)
#    include <libutil.h>
#  endif
#endif

namespace {

using KV = std::vector<std::pair<std::string, int64_t>>;

[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }
[[noreturn]] void fail_errno(int err) { nyos::raise_errno(err, ""); }

int64_t iarg(std::vector<Value>& a, size_t i, int64_t dflt = 0) {
    if (i >= a.size() || a[i].type == ValueType::NONE) return dflt;
    if (a[i].type != ValueType::INTEGER && a[i].type != ValueType::BOOLEAN) {
        if (a[i].type == ValueType::DOUBLE) fail("TypeError", "'float' object cannot be interpreted as an integer");
        fail("TypeError", "an integer is required");
    }
    return (int64_t)nyos::to_int(a[i], dflt);
}
std::string sarg(NythonExecutor& E, std::vector<Value>& a, size_t i) {
    if (i >= a.size()) return std::string();
    if (auto* b = E.bytesOf(a[i])) return b->s;
    return E.strOf(a[i]);
}
Value kv_list(NythonExecutor& E, const KV& kv) {
    std::vector<Value> out;
    out.reserve(kv.size());
    for (auto& p : kv) {
        std::vector<Value> pair{E.makeStringValue(p.first), Value((int64_t)p.second)};
        out.push_back(E.makeListValue(pair));
    }
    return E.makeListValue(out);
}
Value ints(NythonExecutor& E, std::initializer_list<int64_t> v) {
    std::vector<Value> out;
    for (int64_t x : v) out.push_back(Value((int64_t)x));
    return E.makeListValue(out);
}

#define K(name) kv.push_back({#name, (int64_t)(name)})

// ── errno: CPython's errnomodule.c order (a later name for the same value
// wins errorcode: EAGAIN over EWOULDBLOCK, EDEADLOCK over EDEADLK, ENOTSUP
// over EOPNOTSUPP, as CPython gives on Linux) ───────────────────────────────
KV errno_table() {
    KV kv;
#ifdef ENODEV
    K(ENODEV);
#endif
#ifdef ENOCSI
    K(ENOCSI);
#endif
#ifdef EHOSTUNREACH
    K(EHOSTUNREACH);
#endif
#ifdef ENOMSG
    K(ENOMSG);
#endif
#ifdef EUCLEAN
    K(EUCLEAN);
#endif
#ifdef EL2NSYNC
    K(EL2NSYNC);
#endif
#ifdef EL2HLT
    K(EL2HLT);
#endif
#ifdef ENODATA
    K(ENODATA);
#endif
#ifdef ENOTBLK
    K(ENOTBLK);
#endif
#ifdef ENOSYS
    K(ENOSYS);
#endif
#ifdef EPIPE
    K(EPIPE);
#endif
#ifdef EINVAL
    K(EINVAL);
#endif
#ifdef EOVERFLOW
    K(EOVERFLOW);
#endif
#ifdef EADV
    K(EADV);
#endif
#ifdef EINTR
    K(EINTR);
#endif
#ifdef EUSERS
    K(EUSERS);
#endif
#ifdef ENOTEMPTY
    K(ENOTEMPTY);
#endif
#ifdef ENOBUFS
    K(ENOBUFS);
#endif
#ifdef EPROTO
    K(EPROTO);
#endif
#ifdef EREMOTE
    K(EREMOTE);
#endif
#ifdef ENAVAIL
    K(ENAVAIL);
#endif
#ifdef ECHILD
    K(ECHILD);
#endif
#ifdef ELOOP
    K(ELOOP);
#endif
#ifdef EXDEV
    K(EXDEV);
#endif
#ifdef E2BIG
    K(E2BIG);
#endif
#ifdef ESRCH
    K(ESRCH);
#endif
#ifdef EMSGSIZE
    K(EMSGSIZE);
#endif
#ifdef EAFNOSUPPORT
    K(EAFNOSUPPORT);
#endif
#ifdef EBADR
    K(EBADR);
#endif
#ifdef EHOSTDOWN
    K(EHOSTDOWN);
#endif
#ifdef EPFNOSUPPORT
    K(EPFNOSUPPORT);
#endif
#ifdef ENOPROTOOPT
    K(ENOPROTOOPT);
#endif
#ifdef EBUSY
    K(EBUSY);
#endif
#ifdef EWOULDBLOCK
    K(EWOULDBLOCK);
#endif
#ifdef EBADFD
    K(EBADFD);
#endif
#ifdef EDOTDOT
    K(EDOTDOT);
#endif
#ifdef EISCONN
    K(EISCONN);
#endif
#ifdef ENOANO
    K(ENOANO);
#endif
#ifdef ESHUTDOWN
    K(ESHUTDOWN);
#endif
#ifdef ECHRNG
    K(ECHRNG);
#endif
#ifdef ELIBBAD
    K(ELIBBAD);
#endif
#ifdef ENONET
    K(ENONET);
#endif
#ifdef EBADE
    K(EBADE);
#endif
#ifdef EBADF
    K(EBADF);
#endif
#ifdef EMULTIHOP
    K(EMULTIHOP);
#endif
#ifdef EIO
    K(EIO);
#endif
#ifdef EUNATCH
    K(EUNATCH);
#endif
#ifdef EPROTOTYPE
    K(EPROTOTYPE);
#endif
#ifdef ENOSPC
    K(ENOSPC);
#endif
#ifdef ENOEXEC
    K(ENOEXEC);
#endif
#ifdef EALREADY
    K(EALREADY);
#endif
#ifdef ENETDOWN
    K(ENETDOWN);
#endif
#ifdef ENOTNAM
    K(ENOTNAM);
#endif
#ifdef EACCES
    K(EACCES);
#endif
#ifdef ELNRNG
    K(ELNRNG);
#endif
#ifdef EILSEQ
    K(EILSEQ);
#endif
#ifdef ENOTDIR
    K(ENOTDIR);
#endif
#ifdef ENOTUNIQ
    K(ENOTUNIQ);
#endif
#ifdef EPERM
    K(EPERM);
#endif
#ifdef EDOM
    K(EDOM);
#endif
#ifdef EXFULL
    K(EXFULL);
#endif
#ifdef ECONNREFUSED
    K(ECONNREFUSED);
#endif
#ifdef EISDIR
    K(EISDIR);
#endif
#ifdef EPROTONOSUPPORT
    K(EPROTONOSUPPORT);
#endif
#ifdef EROFS
    K(EROFS);
#endif
#ifdef EADDRNOTAVAIL
    K(EADDRNOTAVAIL);
#endif
#ifdef EIDRM
    K(EIDRM);
#endif
#ifdef ECOMM
    K(ECOMM);
#endif
#ifdef ESRMNT
    K(ESRMNT);
#endif
#ifdef EREMOTEIO
    K(EREMOTEIO);
#endif
#ifdef EL3RST
    K(EL3RST);
#endif
#ifdef EBADMSG
    K(EBADMSG);
#endif
#ifdef ENFILE
    K(ENFILE);
#endif
#ifdef ELIBMAX
    K(ELIBMAX);
#endif
#ifdef ESPIPE
    K(ESPIPE);
#endif
#ifdef ENOLINK
    K(ENOLINK);
#endif
#ifdef ENETRESET
    K(ENETRESET);
#endif
#ifdef ETIMEDOUT
    K(ETIMEDOUT);
#endif
#ifdef ENOENT
    K(ENOENT);
#endif
#ifdef EEXIST
    K(EEXIST);
#endif
#ifdef EDQUOT
    K(EDQUOT);
#endif
#ifdef ENOSTR
    K(ENOSTR);
#endif
#ifdef EBADSLT
    K(EBADSLT);
#endif
#ifdef EBADRQC
    K(EBADRQC);
#endif
#ifdef ELIBACC
    K(ELIBACC);
#endif
#ifdef EFAULT
    K(EFAULT);
#endif
#ifdef EFBIG
    K(EFBIG);
#endif
#ifdef EDEADLK
    K(EDEADLK);
#endif
#ifdef ENOTCONN
    K(ENOTCONN);
#endif
#ifdef EDESTADDRREQ
    K(EDESTADDRREQ);
#endif
#ifdef ELIBSCN
    K(ELIBSCN);
#endif
#ifdef ENOLCK
    K(ENOLCK);
#endif
#ifdef EISNAM
    K(EISNAM);
#endif
#ifdef ECONNABORTED
    K(ECONNABORTED);
#endif
#ifdef ENETUNREACH
    K(ENETUNREACH);
#endif
#ifdef ESTALE
    K(ESTALE);
#endif
#ifdef ENOSR
    K(ENOSR);
#endif
#ifdef ENOMEM
    K(ENOMEM);
#endif
#ifdef ENOTSOCK
    K(ENOTSOCK);
#endif
#ifdef ESTRPIPE
    K(ESTRPIPE);
#endif
#ifdef EMLINK
    K(EMLINK);
#endif
#ifdef ERANGE
    K(ERANGE);
#endif
#ifdef ELIBEXEC
    K(ELIBEXEC);
#endif
#ifdef EL3HLT
    K(EL3HLT);
#endif
#ifdef ECONNRESET
    K(ECONNRESET);
#endif
#ifdef EADDRINUSE
    K(EADDRINUSE);
#endif
#ifdef EOPNOTSUPP
    K(EOPNOTSUPP);
#endif
#ifdef EREMCHG
    K(EREMCHG);
#endif
#ifdef EAGAIN
    K(EAGAIN);
#endif
#ifdef ENAMETOOLONG
    K(ENAMETOOLONG);
#endif
#ifdef ENOTTY
    K(ENOTTY);
#endif
#ifdef ERESTART
    K(ERESTART);
#endif
#ifdef ESOCKTNOSUPPORT
    K(ESOCKTNOSUPPORT);
#endif
#ifdef ETIME
    K(ETIME);
#endif
#ifdef EBFONT
    K(EBFONT);
#endif
#ifdef EDEADLOCK
    K(EDEADLOCK);
#endif
#ifdef ETOOMANYREFS
    K(ETOOMANYREFS);
#endif
#ifdef EMFILE
    K(EMFILE);
#endif
#ifdef ETXTBSY
    K(ETXTBSY);
#endif
#ifdef EINPROGRESS
    K(EINPROGRESS);
#endif
#ifdef ENXIO
    K(ENXIO);
#endif
#ifdef ENOPKG
    K(ENOPKG);
#endif
#ifdef ENOMEDIUM
    K(ENOMEDIUM);
#endif
#ifdef EMEDIUMTYPE
    K(EMEDIUMTYPE);
#endif
#ifdef ECANCELED
    K(ECANCELED);
#endif
#ifdef ENOKEY
    K(ENOKEY);
#endif
#ifdef EKEYEXPIRED
    K(EKEYEXPIRED);
#endif
#ifdef EKEYREVOKED
    K(EKEYREVOKED);
#endif
#ifdef EKEYREJECTED
    K(EKEYREJECTED);
#endif
#ifdef EOWNERDEAD
    K(EOWNERDEAD);
#endif
#ifdef ENOTRECOVERABLE
    K(ENOTRECOVERABLE);
#endif
#ifdef ERFKILL
    K(ERFKILL);
#endif
#ifdef EHWPOISON
    K(EHWPOISON);
#endif
#ifdef ENOTSUP
    K(ENOTSUP);
#endif
    // the BSDs and macOS
#ifdef EAUTH
    K(EAUTH);
#endif
#ifdef EBADARCH
    K(EBADARCH);
#endif
#ifdef EBADEXEC
    K(EBADEXEC);
#endif
#ifdef EBADMACHO
    K(EBADMACHO);
#endif
#ifdef EBADRPC
    K(EBADRPC);
#endif
#ifdef EDEVERR
    K(EDEVERR);
#endif
#ifdef EFTYPE
    K(EFTYPE);
#endif
#ifdef ENEEDAUTH
    K(ENEEDAUTH);
#endif
#ifdef ENOATTR
    K(ENOATTR);
#endif
#ifdef ENOPOLICY
    K(ENOPOLICY);
#endif
#ifdef EPROCLIM
    K(EPROCLIM);
#endif
#ifdef EPROCUNAVAIL
    K(EPROCUNAVAIL);
#endif
#ifdef EPROGMISMATCH
    K(EPROGMISMATCH);
#endif
#ifdef EPROGUNAVAIL
    K(EPROGUNAVAIL);
#endif
#ifdef EPWROFF
    K(EPWROFF);
#endif
#ifdef ERPCMISMATCH
    K(ERPCMISMATCH);
#endif
#ifdef ESHLIBVERS
    K(ESHLIBVERS);
#endif
#ifdef EQFULL
    K(EQFULL);
#endif
#ifdef ENOTCAPABLE
    K(ENOTCAPABLE);
#endif
#ifdef _WIN32
    // Windows Sockets error codes, as CPython's errno module has them there
    K(WSAEINTR); K(WSAEBADF); K(WSAEACCES); K(WSAEFAULT); K(WSAEINVAL); K(WSAEMFILE);
    K(WSAEWOULDBLOCK); K(WSAEINPROGRESS); K(WSAEALREADY); K(WSAENOTSOCK); K(WSAEDESTADDRREQ);
    K(WSAEMSGSIZE); K(WSAEPROTOTYPE); K(WSAENOPROTOOPT); K(WSAEPROTONOSUPPORT);
    K(WSAESOCKTNOSUPPORT); K(WSAEOPNOTSUPP); K(WSAEPFNOSUPPORT); K(WSAEAFNOSUPPORT);
    K(WSAEADDRINUSE); K(WSAEADDRNOTAVAIL); K(WSAENETDOWN); K(WSAENETUNREACH); K(WSAENETRESET);
    K(WSAECONNABORTED); K(WSAECONNRESET); K(WSAENOBUFS); K(WSAEISCONN); K(WSAENOTCONN);
    K(WSAESHUTDOWN); K(WSAETOOMANYREFS); K(WSAETIMEDOUT); K(WSAECONNREFUSED); K(WSAELOOP);
    K(WSAENAMETOOLONG); K(WSAEHOSTDOWN); K(WSAEHOSTUNREACH); K(WSAENOTEMPTY); K(WSAEPROCLIM);
    K(WSAEUSERS); K(WSAEDQUOT); K(WSAESTALE); K(WSAEREMOTE); K(WSASYSNOTREADY);
    K(WSAVERNOTSUPPORTED); K(WSANOTINITIALISED); K(WSAEDISCON);
#endif
    return kv;
}

KV fcntl_consts() {
    KV kv;
#ifndef _WIN32
    K(F_DUPFD); K(F_GETFD); K(F_SETFD); K(F_GETFL); K(F_SETFL); K(F_GETLK); K(F_SETLK); K(F_SETLKW);
    K(F_GETOWN); K(F_SETOWN); K(F_RDLCK); K(F_WRLCK); K(F_UNLCK); K(FD_CLOEXEC);
    K(LOCK_SH); K(LOCK_EX); K(LOCK_NB); K(LOCK_UN);
#ifdef F_DUPFD_CLOEXEC
    K(F_DUPFD_CLOEXEC);
#endif
#ifdef F_GETSIG
    K(F_GETSIG); K(F_SETSIG);
#endif
#ifdef F_GETLK64
    K(F_GETLK64); K(F_SETLK64); K(F_SETLKW64);
#endif
#ifdef F_GETLEASE
    K(F_GETLEASE); K(F_SETLEASE); K(F_NOTIFY);
#endif
#ifdef F_EXLCK
    K(F_EXLCK); K(F_SHLCK);
#endif
#ifdef F_GETPIPE_SZ
    K(F_GETPIPE_SZ); K(F_SETPIPE_SZ);
#endif
#ifdef F_OFD_GETLK
    K(F_OFD_GETLK); K(F_OFD_SETLK); K(F_OFD_SETLKW);
#endif
#ifdef F_ADD_SEALS
    K(F_ADD_SEALS); K(F_GET_SEALS); K(F_SEAL_SEAL); K(F_SEAL_SHRINK); K(F_SEAL_GROW); K(F_SEAL_WRITE);
#endif
#ifdef F_SEAL_FUTURE_WRITE
    K(F_SEAL_FUTURE_WRITE);
#endif
#ifdef DN_ACCESS
    K(DN_ACCESS); K(DN_MODIFY); K(DN_CREATE); K(DN_DELETE); K(DN_RENAME); K(DN_ATTRIB); K(DN_MULTISHOT);
#endif
#ifdef FASYNC
    K(FASYNC);
#endif
#ifdef F_FULLFSYNC
    K(F_FULLFSYNC);
#endif
#ifdef F_NOCACHE
    K(F_NOCACHE);
#endif
#ifdef F_GETPATH
    K(F_GETPATH);
#endif
#ifdef LOCK_MAND
    K(LOCK_MAND); K(LOCK_READ); K(LOCK_WRITE); K(LOCK_RW);
#endif
#ifdef FICLONE
    K(FICLONE);
#endif
#ifdef FICLONERANGE
    K(FICLONERANGE);
#endif
#endif
    return kv;
}

KV termios_consts() {
    KV kv;
#ifndef _WIN32
    K(B0); K(B50); K(B75); K(B110); K(B134); K(B150); K(B200); K(B300); K(B600); K(B1200); K(B1800);
    K(B2400); K(B4800); K(B9600); K(B19200); K(B38400);
#ifdef B57600
    K(B57600);
#endif
#ifdef B115200
    K(B115200);
#endif
#ifdef B230400
    K(B230400);
#endif
#ifdef B460800
    K(B460800);
#endif
#ifdef B500000
    K(B500000); K(B576000); K(B921600); K(B1000000); K(B1152000); K(B1500000); K(B2000000);
#endif
#ifdef B2500000
    K(B2500000); K(B3000000); K(B3500000); K(B4000000);
#endif
    K(TCSANOW); K(TCSADRAIN); K(TCSAFLUSH);
#ifdef TCSASOFT
    K(TCSASOFT);
#endif
    K(TCIFLUSH); K(TCOFLUSH); K(TCIOFLUSH); K(TCOOFF); K(TCOON); K(TCIOFF); K(TCION);
    K(IGNBRK); K(BRKINT); K(IGNPAR); K(PARMRK); K(INPCK); K(ISTRIP); K(INLCR); K(IGNCR); K(ICRNL);
#ifdef IUCLC
    K(IUCLC);
#endif
    K(IXON); K(IXANY); K(IXOFF);
#ifdef IMAXBEL
    K(IMAXBEL);
#endif
#ifdef IUTF8
    K(IUTF8);
#endif
    K(OPOST);
#ifdef OLCUC
    K(OLCUC);
#endif
#ifdef ONLCR
    K(ONLCR);
#endif
#ifdef OCRNL
    K(OCRNL); K(ONOCR); K(ONLRET);
#endif
#ifdef OFILL
    K(OFILL); K(OFDEL);
#endif
#ifdef NLDLY
    K(NLDLY); K(CRDLY); K(TABDLY); K(BSDLY); K(VTDLY); K(FFDLY);
    K(NL0); K(NL1); K(CR0); K(CR1); K(CR2); K(CR3); K(TAB0); K(TAB1); K(TAB2); K(TAB3);
    K(BS0); K(BS1); K(VT0); K(VT1); K(FF0); K(FF1);
#endif
#ifdef XTABS
    K(XTABS);
#endif
    K(CSIZE); K(CSTOPB); K(CREAD); K(PARENB); K(PARODD); K(HUPCL); K(CLOCAL);
    K(CS5); K(CS6); K(CS7); K(CS8);
#ifdef CIBAUD
    K(CIBAUD);
#endif
#ifdef CRTSCTS
    K(CRTSCTS);
#endif
#ifdef CBAUD
    K(CBAUD);
#endif
#ifdef CBAUDEX
    K(CBAUDEX);
#endif
#ifdef CMSPAR
    K(CMSPAR);
#endif
    K(ISIG); K(ICANON);
#ifdef XCASE
    K(XCASE);
#endif
    K(ECHO); K(ECHOE); K(ECHOK); K(ECHONL);
#ifdef ECHOCTL
    K(ECHOCTL); K(ECHOPRT); K(ECHOKE); K(FLUSHO); K(PENDIN);
#endif
    K(NOFLSH); K(TOSTOP); K(IEXTEN);
#ifdef EXTPROC
    K(EXTPROC);
#endif
    K(VINTR); K(VQUIT); K(VERASE); K(VKILL); K(VEOF); K(VTIME); K(VMIN);
#ifdef VSWTC
    K(VSWTC);
#endif
#ifdef VSWTCH
    K(VSWTCH);
#endif
    K(VSTART); K(VSTOP); K(VSUSP); K(VEOL);
#ifdef VREPRINT
    K(VREPRINT); K(VDISCARD); K(VWERASE); K(VLNEXT); K(VEOL2);
#endif
    K(NCCS);
#ifdef CEOF
    K(CEOF); K(CEOL); K(CEOT); K(CERASE); K(CINTR); K(CKILL); K(CQUIT); K(CSTART); K(CSTOP); K(CSUSP);
#endif
#ifdef CDSUSP
    K(CDSUSP); K(CFLUSH); K(CLNEXT); K(CRPRNT); K(CWERASE);
#endif
#ifdef EXTA
    K(EXTA); K(EXTB);
#endif
    K(TIOCGWINSZ); K(TIOCSWINSZ); K(TIOCSCTTY); K(TIOCNOTTY); K(TIOCGPGRP); K(TIOCSPGRP); K(TIOCOUTQ);
    K(TIOCSTI); K(TIOCMGET); K(TIOCMSET); K(TIOCMBIS); K(TIOCMBIC); K(TIOCEXCL); K(TIOCNXCL);
#ifdef TIOCINQ
    K(TIOCINQ);
#endif
    K(TIOCM_LE); K(TIOCM_DTR); K(TIOCM_RTS); K(TIOCM_ST); K(TIOCM_SR); K(TIOCM_CTS); K(TIOCM_CAR);
    K(TIOCM_RNG); K(TIOCM_DSR); K(TIOCM_CD); K(TIOCM_RI);
#ifdef TIOCCONS
    K(TIOCCONS);
#endif
#ifdef TIOCPKT
    K(TIOCPKT); K(TIOCPKT_DATA); K(TIOCPKT_FLUSHREAD); K(TIOCPKT_FLUSHWRITE); K(TIOCPKT_STOP);
    K(TIOCPKT_START); K(TIOCPKT_NOSTOP); K(TIOCPKT_DOSTOP);
#endif
    K(FIONBIO); K(FIONREAD); K(FIOCLEX); K(FIONCLEX); K(FIOASYNC);
#ifdef TIOCGSERIAL
    K(TIOCGSERIAL); K(TIOCSSERIAL);
#endif
#ifdef TIOCLINUX
    K(TIOCLINUX);
#endif
#ifdef TIOCGETD
    K(TIOCGETD); K(TIOCSETD);
#endif
#ifdef TCGETS
    K(TCGETS); K(TCSETS); K(TCSETSW); K(TCSETSF); K(TCGETA); K(TCSETA); K(TCSETAW); K(TCSETAF);
    K(TCSBRK); K(TCXONC); K(TCFLSH); K(TCSBRKP);
#endif
#endif
    return kv;
}

KV resource_consts() {
    KV kv;
#ifndef _WIN32
    K(RLIMIT_CPU); K(RLIMIT_FSIZE); K(RLIMIT_DATA); K(RLIMIT_STACK); K(RLIMIT_CORE);
#ifdef RLIMIT_RSS
    K(RLIMIT_RSS);
#endif
#ifdef RLIMIT_NPROC
    K(RLIMIT_NPROC);
#endif
    K(RLIMIT_NOFILE);
#ifdef RLIMIT_OFILE
    K(RLIMIT_OFILE);
#endif
#ifdef RLIMIT_MEMLOCK
    K(RLIMIT_MEMLOCK);
#endif
#ifdef RLIMIT_VMEM
    K(RLIMIT_VMEM);
#endif
#ifdef RLIMIT_AS
    K(RLIMIT_AS);
#endif
#ifdef RLIMIT_MSGQUEUE
    K(RLIMIT_MSGQUEUE);
#endif
#ifdef RLIMIT_NICE
    K(RLIMIT_NICE);
#endif
#ifdef RLIMIT_RTPRIO
    K(RLIMIT_RTPRIO);
#endif
#ifdef RLIMIT_RTTIME
    K(RLIMIT_RTTIME);
#endif
#ifdef RLIMIT_SIGPENDING
    K(RLIMIT_SIGPENDING);
#endif
#ifdef RLIMIT_SBSIZE
    K(RLIMIT_SBSIZE);
#endif
#ifdef RLIMIT_SWAP
    K(RLIMIT_SWAP);
#endif
#ifdef RLIMIT_NPTS
    K(RLIMIT_NPTS);
#endif
#ifdef RLIMIT_KQUEUES
    K(RLIMIT_KQUEUES);
#endif
    K(RUSAGE_SELF); K(RUSAGE_CHILDREN);
#ifdef RUSAGE_THREAD
    K(RUSAGE_THREAD);
#endif
#ifdef RUSAGE_BOTH
    K(RUSAGE_BOTH);
#endif
    // RLIM_INFINITY as CPython gives it: the C value read as a signed
    // 64-bit number (-1 on Linux; 2**63-1 on macOS)
    kv.push_back({"RLIM_INFINITY", (int64_t)(rlim_t)RLIM_INFINITY});
#endif
    return kv;
}

KV syslog_consts() {
    KV kv;
#ifndef _WIN32
    K(LOG_EMERG); K(LOG_ALERT); K(LOG_CRIT); K(LOG_ERR); K(LOG_WARNING); K(LOG_NOTICE); K(LOG_INFO); K(LOG_DEBUG);
    K(LOG_PID); K(LOG_CONS); K(LOG_NDELAY);
#ifdef LOG_ODELAY
    K(LOG_ODELAY);
#endif
#ifdef LOG_NOWAIT
    K(LOG_NOWAIT);
#endif
#ifdef LOG_PERROR
    K(LOG_PERROR);
#endif
    K(LOG_KERN); K(LOG_USER); K(LOG_MAIL); K(LOG_DAEMON); K(LOG_AUTH); K(LOG_LPR);
    K(LOG_LOCAL0); K(LOG_LOCAL1); K(LOG_LOCAL2); K(LOG_LOCAL3); K(LOG_LOCAL4); K(LOG_LOCAL5); K(LOG_LOCAL6); K(LOG_LOCAL7);
#ifdef LOG_SYSLOG
    K(LOG_SYSLOG);
#endif
#ifdef LOG_CRON
    K(LOG_CRON);
#endif
#ifdef LOG_UUCP
    K(LOG_UUCP);
#endif
#ifdef LOG_NEWS
    K(LOG_NEWS);
#endif
#ifdef LOG_AUTHPRIV
    K(LOG_AUTHPRIV);
#endif
#ifdef LOG_FTP
    K(LOG_FTP);
#endif
#ifdef LOG_NETINFO
    K(LOG_NETINFO); K(LOG_REMOTEAUTH); K(LOG_INSTALL); K(LOG_RAS);
#endif
#ifdef LOG_LAUNCHD
    K(LOG_LAUNCHD);
#endif
#endif
    return kv;
}

KV locale_consts() {
    KV kv;
    K(LC_CTYPE); K(LC_COLLATE); K(LC_TIME); K(LC_MONETARY); K(LC_NUMERIC); K(LC_ALL);
#ifdef LC_MESSAGES
    K(LC_MESSAGES);
#endif
    kv.push_back({"CHAR_MAX", (int64_t)CHAR_MAX});
#ifndef _WIN32
    K(CODESET); K(D_T_FMT); K(D_FMT); K(T_FMT); K(T_FMT_AMPM);
    K(DAY_1); K(DAY_2); K(DAY_3); K(DAY_4); K(DAY_5); K(DAY_6); K(DAY_7);
    K(ABDAY_1); K(ABDAY_2); K(ABDAY_3); K(ABDAY_4); K(ABDAY_5); K(ABDAY_6); K(ABDAY_7);
    K(MON_1); K(MON_2); K(MON_3); K(MON_4); K(MON_5); K(MON_6); K(MON_7); K(MON_8); K(MON_9); K(MON_10);
    K(MON_11); K(MON_12);
    K(ABMON_1); K(ABMON_2); K(ABMON_3); K(ABMON_4); K(ABMON_5); K(ABMON_6); K(ABMON_7); K(ABMON_8);
    K(ABMON_9); K(ABMON_10); K(ABMON_11); K(ABMON_12);
    K(RADIXCHAR); K(THOUSEP); K(YESEXPR); K(NOEXPR); K(CRNCYSTR); K(ERA); K(ERA_D_T_FMT);
    K(ERA_D_FMT); K(ERA_T_FMT); K(ALT_DIGITS); K(AM_STR); K(PM_STR);
#endif
    return kv;
}
#undef K

#ifndef _WIN32
// ── locale: the process's LC_NUMERIC stays "C" ─────────────────────────────
std::mutex& loc_mu() { static std::mutex* m = new std::mutex(); return *m; }
std::string& numeric_name() { static std::string* s = new std::string("C"); return *s; }
struct NumericIn {
    // the program's LC_NUMERIC while this lives (the GIL is held)
    bool swapped = false;
    NumericIn() {
        if (numeric_name() != "C") swapped = std::setlocale(LC_NUMERIC, numeric_name().c_str()) != nullptr;
    }
    ~NumericIn() { if (swapped) std::setlocale(LC_NUMERIC, "C"); }
};
#endif

std::string locale_text(const char* s) {
    // the locale's text as UTF-8 (CPython decodes with the locale encoding;
    // invalid UTF-8 is taken as Latin-1)
    std::string in = s ? s : "";
    size_t i = 0;
    bool ok = true;
    while (i < in.size()) {
        unsigned char c = (unsigned char)in[i];
        size_t n = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
        if (!n || i + n > in.size()) { ok = false; break; }
        for (size_t k = 1; k < n; k++) if (((unsigned char)in[i + k] >> 6) != 2) { ok = false; break; }
        if (!ok) break;
        i += n;
    }
    if (ok) return in;
    std::string out;
    for (unsigned char c : in) {
        if (c < 0x80) out.push_back((char)c);
        else { out.push_back((char)(0xC0 | (c >> 6))); out.push_back((char)(0x80 | (c & 0x3F))); }
    }
    return out;
}

Value grouping_list(NythonExecutor& E, const char* s) {
    std::vector<Value> v;
    if (s && s[0] != '\0') {
        int i = -1;
        do {
            i++;
            v.push_back(Value((int64_t)(signed char)s[i]));
        } while (s[i] != '\0' && s[i] != CHAR_MAX);
    }
    return E.makeListValue(v);
}

std::wstring to_wide(const std::string& s) {
    std::wstring w;
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        uint32_t cp;
        size_t n;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c >> 5) == 6) { cp = c & 0x1F; n = 2; }
        else if ((c >> 4) == 14) { cp = c & 0x0F; n = 3; }
        else { cp = c & 0x07; n = 4; }
        for (size_t k = 1; k < n && i + k < s.size(); k++) cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
        i += n;
        if (cp == 0) fail("ValueError", "embedded null character");
        if (sizeof(wchar_t) == 2 && cp >= 0x10000) {
            cp -= 0x10000;
            w.push_back((wchar_t)(0xD800 + (cp >> 10)));
            w.push_back((wchar_t)(0xDC00 + (cp & 0x3FF)));
        } else {
            w.push_back((wchar_t)cp);
        }
    }
    return w;
}
std::string from_wide(const std::wstring& w) {
    std::string out;
    for (size_t i = 0; i < w.size(); i++) {
        uint32_t cp = (uint32_t)w[i];
        if (sizeof(wchar_t) == 2 && cp >= 0xD800 && cp < 0xDC00 && i + 1 < w.size()) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + ((uint32_t)w[i + 1] - 0xDC00);
            i++;
        }
        if (cp > 0x10FFFF) cp &= 0x1FFFFF;
        if (cp < 0x80) out.push_back((char)cp);
        else if (cp < 0x800) { out.push_back((char)(0xC0 | (cp >> 6))); out.push_back((char)(0x80 | (cp & 0x3F))); }
        else if (cp < 0x10000) {
            out.push_back((char)(0xE0 | (cp >> 12))); out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else {
            out.push_back((char)(0xF0 | (cp >> 18))); out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F))); out.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

#ifndef _WIN32
// a pid or status argument: C int
int fdarg(std::vector<Value>& a, size_t i) {
    int64_t v = iarg(a, i, -1);
    if (v < INT_MIN || v > INT_MAX) fail("OverflowError", "Python int too large to convert to C int");
    return (int)v;
}
#endif

} // namespace

std::vector<std::string> sysmods_builtin_names() {
    std::vector<std::string> v = {
        "_sys_platform_posix", "_sys_errno_table", "_sys_consts", "_sys_fcntl", "_sys_ioctl", "_sys_flock",
        "_sys_lockf", "_sys_tcgetattr", "_sys_tcsetattr", "_sys_tcsendbreak", "_sys_tcdrain", "_sys_tcflush",
        "_sys_tcflow", "_sys_tcgetwinsize", "_sys_tcsetwinsize", "_sys_openpty", "_sys_forkpty", "_sys_fork",
        "_sys_login_tty", "_sys_waitpid", "_sys_wstatus", "_sys_execv", "_sys_exit", "_sys_ttyname",
        "_sys_getrlimit", "_sys_setrlimit", "_sys_prlimit", "_sys_getrusage", "_sys_getpagesize",
        "_sys_openlog", "_sys_syslog", "_sys_closelog", "_sys_setlogmask", "_sys_setlocale",
        "_sys_localeconv", "_sys_nl_langinfo", "_sys_strcoll", "_sys_strxfrm", "_sys_win_locale"};
    for (auto& n : bz2_builtin_names()) v.push_back(n);
    for (auto& n : mmap_builtin_names()) v.push_back(n);
    for (auto& n : lzma_builtin_names()) v.push_back(n);
    for (auto& n : cmath_builtin_names()) v.push_back(n);
    for (auto& n : fault_builtin_names()) v.push_back(n);
    for (auto& n : readline_builtin_names()) v.push_back(n);
    return v;
}

Value dispatch_sysmods(NythonExecutor& E, const std::string& name, std::vector<Value>& a, Context* ctx) {
    if (name.size() < 6 || name[0] != '_') return UNDEFINED_VALUE;
    if (name.compare(0, 5, "_bz2_") == 0) return dispatch_bz2(E, name, a, ctx);
    if (name.compare(0, 6, "_mmap_") == 0) return dispatch_mmap(E, name, a, ctx);
    if (name.compare(0, 6, "_lzma_") == 0) return dispatch_lzma(E, name, a, ctx);
    if (name.compare(0, 7, "_cmath_") == 0) return dispatch_cmath(E, name, a, ctx);
    if (name.compare(0, 7, "_fault_") == 0 || name.compare(0, 4, "_tm_") == 0) return dispatch_fault(E, name, a, ctx);
    if (name.compare(0, 4, "_rl_") == 0) return dispatch_readline(E, name, a, ctx);
    if (name.compare(0, 5, "_sys_") != 0) return UNDEFINED_VALUE;

    if (name == "_sys_platform_posix") {
#ifdef _WIN32
        return Value(false);
#else
        return Value(true);
#endif
    }
    if (name == "_sys_errno_table") return kv_list(E, errno_table());
    if (name == "_sys_consts") {
        std::string g = sarg(E, a, 0);
        if (g == "fcntl") return kv_list(E, fcntl_consts());
        if (g == "termios") return kv_list(E, termios_consts());
        if (g == "resource") return kv_list(E, resource_consts());
        if (g == "syslog") return kv_list(E, syslog_consts());
        if (g == "locale") return kv_list(E, locale_consts());
        return kv_list(E, KV());
    }
    if (name == "_sys_strcoll") {
        std::wstring x = to_wide(sarg(E, a, 0)), y = to_wide(sarg(E, a, 1));
        return Value((int64_t)std::wcscoll(x.c_str(), y.c_str()));
    }
    if (name == "_sys_strxfrm") {
        std::wstring x = to_wide(sarg(E, a, 0));
        size_t n = std::wcsxfrm(nullptr, x.c_str(), 0);
        std::wstring buf(n + 1, L'\0');
        std::wcsxfrm(&buf[0], x.c_str(), n + 1);
        buf.resize(n);
        return E.makeStringValue(from_wide(buf));
    }
#ifdef _WIN32
    if (name == "_sys_setlocale") {
        int cat = (int)iarg(a, 0);
        const char* r;
        if (a.size() < 2 || a[1].type == ValueType::NONE) r = std::setlocale(cat, nullptr);
        else { std::string l = sarg(E, a, 1); r = std::setlocale(cat, l.c_str()); }
        if (!r) fail("ValueError", "\x01locale unsupported locale setting");
        return E.makeStringValue(locale_text(r));
    }
    if (name == "_sys_localeconv") {
        struct lconv* lc = std::localeconv();
        Value d = E.makeDictValue();
        Container* c = E.contOf(d);
        auto S = [&](const char* k, const char* v) { E.dictSet(c, E.makeStringValue(k), E.makeStringValue(locale_text(v))); };
        auto I = [&](const char* k, char v) { E.dictSet(c, E.makeStringValue(k), Value((int64_t)(signed char)v)); };
        S("int_curr_symbol", lc->int_curr_symbol); S("currency_symbol", lc->currency_symbol);
        S("mon_decimal_point", lc->mon_decimal_point); S("mon_thousands_sep", lc->mon_thousands_sep);
        E.dictSet(c, E.makeStringValue("mon_grouping"), grouping_list(E, lc->mon_grouping));
        S("positive_sign", lc->positive_sign); S("negative_sign", lc->negative_sign);
        I("int_frac_digits", lc->int_frac_digits); I("frac_digits", lc->frac_digits);
        I("p_cs_precedes", lc->p_cs_precedes); I("p_sep_by_space", lc->p_sep_by_space);
        I("n_cs_precedes", lc->n_cs_precedes); I("n_sep_by_space", lc->n_sep_by_space);
        I("p_sign_posn", lc->p_sign_posn); I("n_sign_posn", lc->n_sign_posn);
        S("decimal_point", lc->decimal_point); S("thousands_sep", lc->thousands_sep);
        E.dictSet(c, E.makeStringValue("grouping"), grouping_list(E, lc->grouping));
        return d;
    }
    if (name == "_sys_win_locale") {
        char lang[64] = {0}, country[64] = {0};
        GetLocaleInfoA(LOCALE_USER_DEFAULT, LOCALE_SISO639LANGNAME, lang, sizeof lang);
        GetLocaleInfoA(LOCALE_USER_DEFAULT, LOCALE_SISO3166CTRYNAME, country, sizeof country);
        std::vector<Value> v{E.makeStringValue(std::string(lang) + "_" + country),
                             E.makeStringValue("cp" + std::to_string(GetACP()))};
        return E.makeListValue(v);
    }
    if (name == "_sys_getpagesize") {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        return Value((int64_t)si.dwPageSize);
    }
    if (name == "_sys_exit") { std::fflush(stdout); _exit((int)iarg(a, 0)); }
    fail("OSError", name.substr(5) + " is not available on Windows");
#else
    // ── locale ──────────────────────────────────────────────────────────────
    if (name == "_sys_setlocale") {
        std::lock_guard<std::mutex> l(loc_mu());
        int cat = (int)iarg(a, 0);
        if (cat != LC_ALL && cat != LC_CTYPE && cat != LC_COLLATE && cat != LC_TIME && cat != LC_MONETARY &&
            cat != LC_NUMERIC
#ifdef LC_MESSAGES
            && cat != LC_MESSAGES
#endif
            )
            fail("ValueError", "\x01locale invalid locale category");
        if (a.size() < 2 || a[1].type == ValueType::NONE) {
            NumericIn in;
            const char* r = std::setlocale(cat, nullptr);
            if (!r) fail("ValueError", "\x01locale locale query failed");
            return E.makeStringValue(r);
        }
        std::string want = sarg(E, a, 1);
        if (want.find('\0') != std::string::npos) fail("ValueError", "embedded null character");
        std::string result;
        {
            NumericIn in;      // so LC_ALL's other categories are set with the program's numeric one
            const char* r = std::setlocale(cat, want.c_str());
            if (!r) fail("ValueError", "\x01locale unsupported locale setting");
            result = r;
            if (cat == LC_ALL || cat == LC_NUMERIC) {
                const char* n = std::setlocale(LC_NUMERIC, nullptr);
                numeric_name() = n ? n : "C";
                in.swapped = numeric_name() != "C";   // put "C" back whatever was set
                if (!in.swapped) std::setlocale(LC_NUMERIC, "C");
            }
        }
        return E.makeStringValue(result);
    }
    if (name == "_sys_localeconv") {
        std::lock_guard<std::mutex> l(loc_mu());
        NumericIn in;
        struct lconv* lc = std::localeconv();
        Value d = E.makeDictValue();
        Container* c = E.contOf(d);
        auto S = [&](const char* k, const char* v) { E.dictSet(c, E.makeStringValue(k), E.makeStringValue(locale_text(v))); };
        auto I = [&](const char* k, char v) { E.dictSet(c, E.makeStringValue(k), Value((int64_t)(signed char)v)); };
        S("int_curr_symbol", lc->int_curr_symbol); S("currency_symbol", lc->currency_symbol);
        S("mon_decimal_point", lc->mon_decimal_point); S("mon_thousands_sep", lc->mon_thousands_sep);
        E.dictSet(c, E.makeStringValue("mon_grouping"), grouping_list(E, lc->mon_grouping));
        S("positive_sign", lc->positive_sign); S("negative_sign", lc->negative_sign);
        I("int_frac_digits", lc->int_frac_digits); I("frac_digits", lc->frac_digits);
        I("p_cs_precedes", lc->p_cs_precedes); I("p_sep_by_space", lc->p_sep_by_space);
        I("n_cs_precedes", lc->n_cs_precedes); I("n_sep_by_space", lc->n_sep_by_space);
        I("p_sign_posn", lc->p_sign_posn); I("n_sign_posn", lc->n_sign_posn);
        S("decimal_point", lc->decimal_point); S("thousands_sep", lc->thousands_sep);
        E.dictSet(c, E.makeStringValue("grouping"), grouping_list(E, lc->grouping));
        return d;
    }
    if (name == "_sys_nl_langinfo") {
        std::lock_guard<std::mutex> l(loc_mu());
        int64_t item = iarg(a, 0);
        static const nl_item known[] = {CODESET, D_T_FMT, D_FMT, T_FMT, T_FMT_AMPM, DAY_1, DAY_2, DAY_3, DAY_4, DAY_5,
            DAY_6, DAY_7, ABDAY_1, ABDAY_2, ABDAY_3, ABDAY_4, ABDAY_5, ABDAY_6, ABDAY_7, MON_1, MON_2, MON_3, MON_4,
            MON_5, MON_6, MON_7, MON_8, MON_9, MON_10, MON_11, MON_12, ABMON_1, ABMON_2, ABMON_3, ABMON_4, ABMON_5,
            ABMON_6, ABMON_7, ABMON_8, ABMON_9, ABMON_10, ABMON_11, ABMON_12, RADIXCHAR, THOUSEP, YESEXPR, NOEXPR,
            CRNCYSTR, ERA, ERA_D_T_FMT, ERA_D_FMT, ERA_T_FMT, ALT_DIGITS, AM_STR, PM_STR};
        bool ok = false;
        for (nl_item k : known) if ((int64_t)k == item) ok = true;
        if (!ok) fail("ValueError", "unsupported langinfo constant");
        NumericIn in;
        return E.makeStringValue(locale_text(nl_langinfo((nl_item)item)));
    }
    if (name == "_sys_win_locale") return NONE_VALUE;

    // ── fcntl ───────────────────────────────────────────────────────────────
    if (name == "_sys_fcntl") {
        int fd = fdarg(a, 0);
        int cmd = (int)iarg(a, 1);
        if (a.size() > 2 && E.bytesOf(a[2])) {
            std::string buf = E.bytesOf(a[2])->s;
            if (buf.size() > 1024) fail("ValueError", "fcntl argument 3 is too long");
            char tmp[1024];
            std::memcpy(tmp, buf.data(), buf.size());
            int r;
            { nyconc::GilRelease un; r = ::fcntl(fd, cmd, tmp); }
            if (r < 0) fail_errno(errno);
            return E.makeBytesValue(std::string(tmp, buf.size()));
        }
        long arg = (long)iarg(a, 2, 0);
        int r;
        { nyconc::GilRelease un; r = ::fcntl(fd, cmd, arg); }
        if (r < 0) fail_errno(errno);
        return Value((int64_t)r);
    }
    if (name == "_sys_ioctl") {
        int fd = fdarg(a, 0);
        unsigned long req = (unsigned long)(uint64_t)iarg(a, 1);
        if (a.size() > 2 && E.bytesOf(a[2])) {
            std::string buf = E.bytesOf(a[2])->s;
            if (buf.size() > 1024) fail("ValueError", "ioctl string arg too long");
            char tmp[1024];
            std::memset(tmp, 0, sizeof tmp);
            std::memcpy(tmp, buf.data(), buf.size());
            int r = ::ioctl(fd, req, tmp);
            if (r < 0) fail_errno(errno);
            std::vector<Value> v{Value((int64_t)r), E.makeBytesValue(std::string(tmp, buf.size()))};
            return E.makeListValue(v);
        }
        int arg = (int)iarg(a, 2, 0);
        int r = ::ioctl(fd, req, (long)arg);
        if (r < 0) fail_errno(errno);
        return Value((int64_t)r);
    }
    if (name == "_sys_flock") {
        int fd = fdarg(a, 0);
        int op = (int)iarg(a, 1);
        int r;
        { nyconc::GilRelease un; r = ::flock(fd, op); }
        if (r < 0) fail_errno(errno);
        return NONE_VALUE;
    }
    if (name == "_sys_lockf") {
        int fd = fdarg(a, 0);
        int64_t code = iarg(a, 1);
        struct flock l;
        std::memset(&l, 0, sizeof l);
        if (code == LOCK_UN) l.l_type = F_UNLCK;
        else if (code & LOCK_SH) l.l_type = F_RDLCK;
        else if (code & LOCK_EX) l.l_type = F_WRLCK;
        else fail("ValueError", "unrecognized lockf argument");
        l.l_len = (off_t)iarg(a, 2, 0);
        l.l_start = (off_t)iarg(a, 3, 0);
        l.l_whence = (short)iarg(a, 4, 0);
        int r;
        { nyconc::GilRelease un; r = ::fcntl(fd, (code & LOCK_NB) ? F_SETLK : F_SETLKW, &l); }
        if (r < 0) fail_errno(errno);
        return NONE_VALUE;
    }

    // ── termios ─────────────────────────────────────────────────────────────
    if (name == "_sys_tcgetattr") {
        int fd = fdarg(a, 0);
        struct termios m;
        if (tcgetattr(fd, &m) < 0) fail_errno(errno);
        std::vector<Value> cc;
        for (int i = 0; i < NCCS; i++) cc.push_back(E.makeBytesValue(std::string(1, (char)m.c_cc[i])));
        if ((m.c_lflag & ICANON) == 0) {
            cc[VMIN] = Value((int64_t)m.c_cc[VMIN]);
            cc[VTIME] = Value((int64_t)m.c_cc[VTIME]);
        }
        std::vector<Value> v{Value((int64_t)m.c_iflag), Value((int64_t)m.c_oflag), Value((int64_t)m.c_cflag),
                             Value((int64_t)m.c_lflag), Value((int64_t)cfgetispeed(&m)),
                             Value((int64_t)cfgetospeed(&m)), E.makeListValue(cc)};
        return E.makeListValue(v);
    }
    if (name == "_sys_tcsetattr") {
        int fd = fdarg(a, 0);
        int when = (int)iarg(a, 1);
        if (a.size() < 3) fail("TypeError", "tcsetattr, arg 3: must be 7 element list");
        std::vector<Value> t = E.iterItems(a[2], E.globalContext());
        if (t.size() != 7) fail("TypeError", "tcsetattr, arg 3: must be 7 element list");
        struct termios m;
        if (tcgetattr(fd, &m) < 0) fail_errno(errno);
        m.c_iflag = (tcflag_t)nyos::to_int(t[0], 0);
        m.c_oflag = (tcflag_t)nyos::to_int(t[1], 0);
        m.c_cflag = (tcflag_t)nyos::to_int(t[2], 0);
        m.c_lflag = (tcflag_t)nyos::to_int(t[3], 0);
        speed_t isp = (speed_t)nyos::to_int(t[4], 0), osp = (speed_t)nyos::to_int(t[5], 0);
        std::vector<Value> cc = E.iterItems(t[6], E.globalContext());
        if (cc.size() != NCCS) fail("TypeError", "tcsetattr: attributes[6] must be " + std::to_string(NCCS) + " element list");
        for (int i = 0; i < NCCS; i++) {
            if (auto* b = E.bytesOf(cc[i])) {
                if (b->s.size() != 1) fail("TypeError", "tcsetattr: elements of attributes must be characters or integers");
                m.c_cc[i] = (cc_t)(unsigned char)b->s[0];
            } else if (cc[i].type == ValueType::INTEGER) {
                m.c_cc[i] = (cc_t)nyos::to_int(cc[i], 0);
            } else {
                fail("TypeError", "tcsetattr: elements of attributes must be characters or integers");
            }
        }
        if (cfsetispeed(&m, isp) < 0) fail_errno(errno);
        if (cfsetospeed(&m, osp) < 0) fail_errno(errno);
        if (tcsetattr(fd, when, &m) < 0) fail_errno(errno);
        return NONE_VALUE;
    }
    if (name == "_sys_tcsendbreak") {
        if (tcsendbreak(fdarg(a, 0), (int)iarg(a, 1)) < 0) fail_errno(errno);
        return NONE_VALUE;
    }
    if (name == "_sys_tcdrain") {
        int fd = fdarg(a, 0), r;
        { nyconc::GilRelease un; r = tcdrain(fd); }
        if (r < 0) fail_errno(errno);
        return NONE_VALUE;
    }
    if (name == "_sys_tcflush") {
        if (tcflush(fdarg(a, 0), (int)iarg(a, 1)) < 0) fail_errno(errno);
        return NONE_VALUE;
    }
    if (name == "_sys_tcflow") {
        if (tcflow(fdarg(a, 0), (int)iarg(a, 1)) < 0) fail_errno(errno);
        return NONE_VALUE;
    }
    if (name == "_sys_tcgetwinsize") {
        struct winsize w;
        if (ioctl(fdarg(a, 0), TIOCGWINSZ, &w) < 0) fail_errno(errno);
        return ints(E, {(int64_t)w.ws_row, (int64_t)w.ws_col});
    }
    if (name == "_sys_tcsetwinsize") {
        int fd = fdarg(a, 0);
        struct winsize w;
        if (ioctl(fd, TIOCGWINSZ, &w) < 0) fail_errno(errno);
        int64_t rows = iarg(a, 1), cols = iarg(a, 2);
        if (rows < 0 || rows > 65535 || cols < 0 || cols > 65535) fail("OverflowError", "winsize value(s) out of range.");
        w.ws_row = (unsigned short)rows;
        w.ws_col = (unsigned short)cols;
        if (ioctl(fd, TIOCSWINSZ, &w) < 0) fail_errno(errno);
        return NONE_VALUE;
    }

    // ── pty and the process calls it needs ──────────────────────────────────
    if (name == "_sys_openpty") {
        int m, s;
#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__)
        if (openpty(&m, &s, nullptr, nullptr, nullptr) < 0) fail_errno(errno);
#else
        m = posix_openpt(O_RDWR | O_NOCTTY);
        if (m < 0 || grantpt(m) < 0 || unlockpt(m) < 0) fail_errno(errno);
        s = ::open(ptsname(m), O_RDWR | O_NOCTTY);
        if (s < 0) fail_errno(errno);
#endif
        // non-inheritable, as os.openpty's (PEP 446)
        fcntl(m, F_SETFD, FD_CLOEXEC);
        fcntl(s, F_SETFD, FD_CLOEXEC);
        return ints(E, {m, s});
    }
    if (name == "_sys_fork" || name == "_sys_forkpty") {
        std::fflush(stdout);
        std::fflush(stderr);
        int fd = -1;
        pid_t pid;
        if (name == "_sys_fork") pid = ::fork();
        else {
#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__)
            pid = ::forkpty(&fd, nullptr, nullptr, nullptr);
#else
            errno = ENOSYS; pid = -1;
#endif
        }
        if (pid < 0) fail_errno(errno);
        if (pid == 0) nyconc::after_fork_child();   // (round 83) only this thread goes on
        if (name == "_sys_fork") return Value((int64_t)pid);
        return ints(E, {(int64_t)pid, fd});
    }
    if (name == "_sys_login_tty") {
        int fd = fdarg(a, 0);
#if defined(__linux__) || defined(__APPLE__) || defined(__FreeBSD__)
        if (login_tty(fd) < 0) fail_errno(errno);
#else
        setsid();
        if (ioctl(fd, TIOCSCTTY, 0) < 0) fail_errno(errno);
        dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
        if (fd > 2) close(fd);
#endif
        return NONE_VALUE;
    }
    if (name == "_sys_waitpid") {
        pid_t pid = (pid_t)iarg(a, 0);
        int opts = (int)iarg(a, 1, 0);
        int status = 0;
        pid_t r;
        while (true) {
            { nyconc::GilRelease un; r = ::waitpid(pid, &status, opts); }
            if (r < 0 && errno == EINTR) { if (nyconc::signal_pending()) nyconc::run_signal_handlers(); continue; }
            break;
        }
        if (r < 0) fail_errno(errno);
        return ints(E, {(int64_t)r, (int64_t)status});
    }
    if (name == "_sys_wstatus") {
        std::string op = sarg(E, a, 0);
        int st = (int)iarg(a, 1);
        if (op == "exited") return Value(bool(WIFEXITED(st)));
        if (op == "exitstatus") return Value((int64_t)WEXITSTATUS(st));
        if (op == "signaled") return Value(bool(WIFSIGNALED(st)));
        if (op == "termsig") return Value((int64_t)WTERMSIG(st));
        if (op == "stopped") return Value(bool(WIFSTOPPED(st)));
        if (op == "stopsig") return Value((int64_t)WSTOPSIG(st));
#ifdef WCOREDUMP
        if (op == "coredump") return Value(bool(WCOREDUMP(st)));
#endif
#ifdef WIFCONTINUED
        if (op == "continued") return Value(bool(WIFCONTINUED(st)));
#endif
        if (op == "WNOHANG") return Value((int64_t)WNOHANG);
        if (op == "WUNTRACED") return Value((int64_t)WUNTRACED);
#ifdef WCONTINUED
        if (op == "WCONTINUED") return Value((int64_t)WCONTINUED);
#endif
        fail("ValueError", "unknown wait status operation");
    }
    if (name == "_sys_execv") {
        std::string path = sarg(E, a, 0);
        std::vector<std::string> argv, envs;
        for (auto& v : E.iterItems(a[1], E.globalContext())) argv.push_back(E.bytesOf(v) ? E.bytesOf(v)->s : E.strOf(v));
        if (argv.empty()) fail("ValueError", "execv() arg 2 must not be empty");
        if (argv[0].empty()) fail("ValueError", "execv() arg 2 first element cannot be empty");
        bool with_env = a.size() > 2 && a[2].type != ValueType::NONE;
        if (with_env) for (auto& v : E.iterItems(a[2], E.globalContext())) envs.push_back(E.strOf(v));
        std::vector<char*> av, ev;
        for (auto& s : argv) av.push_back(const_cast<char*>(s.c_str()));
        av.push_back(nullptr);
        for (auto& s : envs) ev.push_back(const_cast<char*>(s.c_str()));
        ev.push_back(nullptr);
        std::fflush(stdout);
        std::fflush(stderr);
        if (with_env) ::execve(path.c_str(), av.data(), ev.data());
        else ::execv(path.c_str(), av.data());
        nyos::raise_errno(errno, path);
    }
    if (name == "_sys_exit") {
        std::fflush(stdout);
        std::fflush(stderr);
        ::_exit((int)iarg(a, 0));
    }
    if (name == "_sys_ttyname") {
        const char* r = ::ttyname(fdarg(a, 0));
        if (!r) fail_errno(errno);
        return E.makeStringValue(r);
    }

    // ── resource ────────────────────────────────────────────────────────────
    if (name == "_sys_getrlimit" || name == "_sys_setrlimit" || name == "_sys_prlimit") {
        bool pr = name == "_sys_prlimit";
        int64_t res = iarg(a, pr ? 1 : 0);
        if (res < 0 || res >= RLIM_NLIMITS) fail("ValueError", "invalid resource specified");
        auto lim = [](int64_t v) -> rlim_t { return v == -1 ? RLIM_INFINITY : (rlim_t)v; };
        if (name == "_sys_getrlimit") {
            struct rlimit rl;
            if (getrlimit((int)res, &rl) < 0) fail_errno(errno);
            return ints(E, {(int64_t)rl.rlim_cur, (int64_t)rl.rlim_max});
        }
        if (name == "_sys_setrlimit") {
            struct rlimit rl;
            rl.rlim_cur = lim(iarg(a, 1));
            rl.rlim_max = lim(iarg(a, 2));
            if (setrlimit((int)res, &rl) < 0) {
                if (errno == EINVAL) fail("ValueError", "current limit exceeds maximum limit");
                if (errno == EPERM) fail("ValueError", "not allowed to raise maximum limit");
                fail_errno(errno);
            }
            return NONE_VALUE;
        }
#if defined(__linux__)
        pid_t pid = (pid_t)iarg(a, 0);
        bool set = a.size() > 2 && nyos::to_int(a[2], 0) != 0;
        struct rlimit nw, old;
        if (set) { nw.rlim_cur = lim(iarg(a, 3)); nw.rlim_max = lim(iarg(a, 4)); }
        if (prlimit(pid, (__rlimit_resource)res, set ? &nw : nullptr, &old) < 0) {
            if (errno == EINVAL) fail("ValueError", "current limit exceeds maximum limit");
            fail_errno(errno);
        }
        return ints(E, {(int64_t)old.rlim_cur, (int64_t)old.rlim_max});
#else
        fail("OSError", "prlimit is not available on this platform");
#endif
    }
    if (name == "_sys_getrusage") {
        int who = (int)iarg(a, 0);
        struct rusage ru;
        if (getrusage(who, &ru) < 0) {
            if (errno == EINVAL) fail("ValueError", "invalid who parameter");
            fail_errno(errno);
        }
        auto tv = [](const struct timeval& t) { return (double)t.tv_sec + (double)t.tv_usec * 0.000001; };
        std::vector<Value> v{Value(tv(ru.ru_utime)), Value(tv(ru.ru_stime)), Value((int64_t)ru.ru_maxrss),
                             Value((int64_t)ru.ru_ixrss), Value((int64_t)ru.ru_idrss), Value((int64_t)ru.ru_isrss),
                             Value((int64_t)ru.ru_minflt), Value((int64_t)ru.ru_majflt), Value((int64_t)ru.ru_nswap),
                             Value((int64_t)ru.ru_inblock), Value((int64_t)ru.ru_oublock),
                             Value((int64_t)ru.ru_msgsnd), Value((int64_t)ru.ru_msgrcv),
                             Value((int64_t)ru.ru_nsignals), Value((int64_t)ru.ru_nvcsw), Value((int64_t)ru.ru_nivcsw)};
        return E.makeListValue(v);
    }
    if (name == "_sys_getpagesize") return Value((int64_t)sysconf(_SC_PAGESIZE));

    // ── syslog ──────────────────────────────────────────────────────────────
    if (name == "_sys_openlog") {
        static std::string* ident = new std::string();
        bool has = a.size() > 0 && a[0].type != ValueType::NONE;
        if (has) *ident = sarg(E, a, 0);
        ::openlog(has ? ident->c_str() : nullptr, (int)iarg(a, 1, 0), (int)iarg(a, 2, LOG_USER));
        return NONE_VALUE;
    }
    if (name == "_sys_syslog") {
        std::string msg = sarg(E, a, 1);
        int pri = (int)iarg(a, 0);
        { nyconc::GilRelease un; ::syslog(pri, "%s", msg.c_str()); }
        return NONE_VALUE;
    }
    if (name == "_sys_closelog") { ::closelog(); return NONE_VALUE; }
    if (name == "_sys_setlogmask") return Value((int64_t)::setlogmask((int)iarg(a, 0)));
#endif
    return UNDEFINED_VALUE;
}
