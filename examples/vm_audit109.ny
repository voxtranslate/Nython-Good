# vm_audit109.ny - Python's system and command-line modules, both engines
# (round 83): errno, fcntl, termios, tty, pty, resource, syslog, mmap,
# faulthandler, tracemalloc, locale, gettext, getopt, optparse, fileinput,
# filecmp, sched, cmath, colorsys, readline/rlcompleter, site/sysconfig,
# webbrowser, zipimport/zipapp, encodings, stringprep, bz2, lzma - and the
# os process calls pty needs (fork, forkpty, openpty, waitpid, _exit, exec*).
#
# The shared part runs under python3 too (`python3 examples/vm_audit109.ny`);
# every expected value there is CPython's (bz2 streams byte for byte as
# libbz2 writes them). POSIX-only modules are checked where they exist.
#
#     ./build/nython-cli examples/vm_audit109.ny
#     ./build/nython-cli --vm examples/vm_audit109.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import io
import shutil
import tempfile
import struct
import subprocess

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(f, *a, **k):
    try:
        f(*a, **k)
    except BaseException as e:
        return [type(e).__name__, str(e)]
    return None

posix = sys.platform != "win32"
linux = sys.platform.startswith("linux")
TMP = tempfile.mkdtemp(prefix="ny109_" + str(os.getpid()) + "_")

def tpath(name):
    return os.path.join(TMP, name)

def write_bytes(path, data):
    with open(path, "wb") as f:
        f.write(data)

def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()

def child(code, env=None):
    # run `code` in a fresh interpreter of this engine family; returns
    # [returncode, stdout, stderr] (text)
    p = tpath("child_" + str(len(results)) + ".py")
    with open(p, "w") as f:
        f.write(code)
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run([sys.executable, p], capture_output=True, env=e, timeout=60)
    return [r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace"), p]

# ── errno ────────────────────────────────────────────────────────────────────
import errno
check("errno values", [errno.ENOENT, errno.EACCES, errno.EEXIST, errno.EINVAL, errno.EPIPE, errno.EBADF, errno.EINTR],
      [2, 13, 17, 22, 32, 9, 4])
check("errno.errorcode", [errno.errorcode[2], errno.errorcode[errno.EACCES], errno.errorcode[errno.EPIPE]],
      ["ENOENT", "EACCES", "EPIPE"])
check("errorcode names are the attributes", all(getattr(errno, n) == v for v, n in errno.errorcode.items()), True)
check("every E-name is in errorcode", all(n in errno.errorcode.values() or getattr(errno, n) in errno.errorcode
                                          for n in dir(errno) if n.startswith("E")), True)
check("os.strerror", os.strerror(errno.ENOENT), "No such file or directory")
try:
    open(tpath("missing.txt"))
    e_no = None
except OSError as e:
    e_no = e.errno
check("a real error's errno", e_no, errno.ENOENT)
if linux:
    check("Linux numbers", [errno.EAGAIN, errno.EWOULDBLOCK, errno.EDEADLK, errno.EDEADLOCK, errno.ENOTSUP,
                            errno.EOPNOTSUPP, errno.ECONNREFUSED, errno.ETIMEDOUT],
          [11, 11, 35, 35, 95, 95, 111, 110])
    check("errorcode for shared numbers (CPython's choice)",
          [errno.errorcode[11], errno.errorcode[35], errno.errorcode[95]], ["EAGAIN", "EDEADLOCK", "ENOTSUP"])
    check("Linux table size", len(errno.errorcode) >= 128, True)

# ── fcntl ────────────────────────────────────────────────────────────────────
if posix:
    import fcntl
    p = tpath("lock.bin")
    write_bytes(p, b"0123456789")
    fd = os.open(p, os.O_RDWR)
    check("F_GETFL access mode", fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDWR)
    fcntl.fcntl(fd, fcntl.F_SETFD, fcntl.FD_CLOEXEC)
    check("F_SETFD / F_GETFD", fcntl.fcntl(fd, fcntl.F_GETFD) & fcntl.FD_CLOEXEC, fcntl.FD_CLOEXEC)
    fcntl.flock(fd, fcntl.LOCK_EX)
    fd2 = os.open(p, os.O_RDWR)
    check("flock held elsewhere: BlockingIOError", raises(fcntl.flock, fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)[0],
          "BlockingIOError")
    fcntl.flock(fd, fcntl.LOCK_UN)
    fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)
    fcntl.flock(fd2, fcntl.LOCK_UN)
    check("flock released", True, True)
    fcntl.lockf(fd, fcntl.LOCK_EX, 4, 2)
    fcntl.lockf(fd, fcntl.LOCK_UN, 4, 2)
    check("lockf on a byte range", True, True)
    check("lockf bad command", raises(fcntl.lockf, fd, 0), ["ValueError", "unrecognized lockf argument"])
    class FileLike:
        def fileno(self):
            return fd
    check("an object with fileno()", fcntl.fcntl(FileLike(), fcntl.F_GETFD) & fcntl.FD_CLOEXEC, fcntl.FD_CLOEXEC)
    check("fd type errors", [raises(fcntl.fcntl, "x", fcntl.F_GETFD)[0], raises(fcntl.fcntl, -1, fcntl.F_GETFD)[0]],
          ["TypeError", "ValueError"])
    os.close(fd2)
    os.close(fd)
    check("closed fd: EBADF", raises(fcntl.fcntl, fd, fcntl.F_GETFD)[1].startswith("[Errno 9]"), True)
    import termios
    r, w = os.pipe()
    os.write(w, b"hello")
    check("ioctl FIONREAD with a bytes buffer", struct.unpack("i", fcntl.ioctl(r, termios.FIONREAD, b"\0\0\0\0"))[0], 5)
    buf = bytearray(4)
    check("ioctl mutating a bytearray", [fcntl.ioctl(r, termios.FIONREAD, buf, True), struct.unpack("i", bytes(buf))[0]],
          [0, 5])
    fl = fcntl.fcntl(r, fcntl.F_GETFL)
    fcntl.fcntl(r, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    check("O_NONBLOCK set", fcntl.fcntl(r, fcntl.F_GETFL) & os.O_NONBLOCK, os.O_NONBLOCK)
    check("read from it", os.read(r, 10), b"hello")
    check("empty non-blocking pipe: BlockingIOError", raises(os.read, r, 10)[0], "BlockingIOError")
    os.close(r)
    os.close(w)
    check("constants are ints", [type(fcntl.F_GETFL).__name__, type(fcntl.LOCK_NB).__name__], ["int", "int"])

# ── termios, tty, pty (POSIX) ────────────────────────────────────────────────
if posix:
    import errno
    import termios
    import tty
    import pty
    master, slave = pty.openpty()
    check("openpty gives two descriptors", [type(master).__name__, type(slave).__name__, os.isatty(slave)],
          ["int", "int", True])
    attrs = termios.tcgetattr(slave)
    check("tcgetattr: 7 fields, NCCS control characters", [len(attrs), len(attrs[6]) == termios.NCCS], [7, True])
    check("canonical mode: cc entries are 1-byte bytes", [type(attrs[6][termios.VINTR]).__name__,
                                                          len(attrs[6][termios.VINTR])], ["bytes", 1])
    attrs[3] = attrs[3] & ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    check("tcsetattr: ECHO off", termios.tcgetattr(slave)[3] & termios.ECHO, 0)
    tty.setraw(slave)
    raw = termios.tcgetattr(slave)
    check("tty.setraw: no ICANON, VMIN 1 as an int", [raw[3] & termios.ICANON, raw[6][termios.VMIN], raw[6][termios.VTIME]],
          [0, 1, 0])
    tty.setcbreak(slave, termios.TCSANOW)
    check("tty.setcbreak", termios.tcgetattr(slave)[3] & (termios.ICANON | termios.ECHO), 0)
    os.write(master, b"abc")
    check("raw pty: bytes pass through", os.read(slave, 3), b"abc")
    termios.tcsetwinsize(master, (24, 81))
    check("tcsetwinsize / tcgetwinsize", termios.tcgetwinsize(slave), (24, 81))
    termios.tcflush(slave, termios.TCIOFLUSH)
    termios.tcdrain(slave)
    check("tcflush / tcdrain", True, True)
    pr, pw = os.pipe()
    e = raises(termios.tcgetattr, pr)
    check("tcgetattr on a pipe: termios.error(ENOTTY)", e[0], "error")
    try:
        termios.tcgetattr(pr)
    except termios.error as ex:
        check("termios.error args", [ex.args[0], issubclass(termios.error, OSError)], [errno.ENOTTY, False])
    os.close(pr)
    os.close(pw)
    check("tcsetattr argument check", raises(termios.tcsetattr, slave, termios.TCSANOW, [1, 2]),
          ["TypeError", "tcsetattr, arg 3: must be 7 element list"])
    os.close(slave)
    os.close(master)
    if hasattr(tty, "cfmakeraw"):
        mode = [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0, 0, [b"\0"] * termios.NCCS]
        tty.cfmakeraw(mode)
        check("tty.cfmakeraw (3.12)", [mode[0] & termios.ICRNL, mode[1] & termios.OPOST, mode[2] & termios.CS8,
                                       mode[3] & termios.ICANON, mode[6][termios.VMIN]], [0, 0, termios.CS8, 0, 1])
    check("tty indexes", [tty.IFLAG, tty.OFLAG, tty.CFLAG, tty.LFLAG, tty.ISPEED, tty.OSPEED, tty.CC], [0, 1, 2, 3, 4, 5, 6])

    # fork through a pty: the child's output comes through the master side
    pid, fd = pty.fork()
    if pid == 0:
        os.write(1, b"child says hi\n")
        os._exit(7)
    got = b""
    while b"hi" not in got:
        try:
            chunk = os.read(fd, 100)
        except OSError:
            break
        if not chunk:
            break
        got += chunk
    st = os.waitpid(pid, 0)[1]
    check("pty.fork: the child's output and status",
          [b"child says hi" in got, os.WIFEXITED(st), os.WEXITSTATUS(st), os.waitstatus_to_exitcode(st)],
          [True, True, 7, 7])
    os.close(fd)
    pid = os.fork()
    if pid == 0:
        os._exit(3)
    check("os.fork / os.waitpid", os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]), 3)
    pid = os.fork()
    if pid == 0:
        os.execv("/bin/sh", ["sh", "-c", "exit 5"])
    check("os.execv in a child", os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]), 5)
    pid = os.fork()
    if pid == 0:
        os.execlp("sh", "sh", "-c", "kill -9 $$")
    st = os.waitpid(pid, 0)[1]
    check("a child killed by a signal", [os.WIFSIGNALED(st), os.WTERMSIG(st), os.waitstatus_to_exitcode(st)], [True, 9, -9])
    check("waitpid WNOHANG on no child", raises(os.waitpid, -1, os.WNOHANG)[0], "ChildProcessError")
    r = child("import pty\npty.spawn(['sh', '-c', 'echo spawned-$((40+2))'])\n")
    check("pty.spawn copies the child's output", [r[0], "spawned-42" in r[1]], [0, True])

# ── resource, syslog (POSIX) ─────────────────────────────────────────────────
if posix:
    import resource
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    check("getrlimit", [type(soft).__name__, soft <= hard or hard == resource.RLIM_INFINITY], ["int", True])
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(soft, 64), hard))
    check("setrlimit lowers the soft limit", resource.getrlimit(resource.RLIMIT_NOFILE)[0], min(soft, 64))
    resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))
    check("and back", resource.getrlimit(resource.RLIMIT_NOFILE), (soft, hard))
    if hard != resource.RLIM_INFINITY:
        check("soft above hard", raises(resource.setrlimit, resource.RLIMIT_NOFILE, (hard + 1, hard)),
              ["ValueError", "current limit exceeds maximum limit"])
    check("resource errors", [raises(resource.getrlimit, -1), raises(resource.getrusage, 12345),
                              raises(resource.setrlimit, resource.RLIMIT_NOFILE, (1, 2, 3))],
          [["ValueError", "invalid resource specified"], ["ValueError", "invalid who parameter"],
           ["ValueError", "expected a tuple of 2 integers"]])
    ru = resource.getrusage(resource.RUSAGE_SELF)
    check("getrusage", [len(ru), ru[0] == ru.ru_utime, type(ru.ru_utime).__name__, ru.ru_maxrss > 0,
                        repr(ru).startswith("resource.struct_rusage(ru_utime=")], [16, True, "float", True, True])
    check("getpagesize", resource.getpagesize() > 0 and resource.getpagesize() & (resource.getpagesize() - 1) == 0, True)
    check("resource.error", resource.error is OSError, True)
    if linux:
        check("RLIM_INFINITY on Linux", resource.RLIM_INFINITY, -1)
        check("prlimit", resource.prlimit(0, resource.RLIMIT_NOFILE), (soft, hard))
    import syslog
    check("LOG_MASK / LOG_UPTO", [syslog.LOG_MASK(syslog.LOG_ERR), syslog.LOG_UPTO(syslog.LOG_ERR), syslog.LOG_USER,
                                  syslog.LOG_LOCAL0, syslog.LOG_ERR], [8, 15, 8, 128, 3])
    syslog.openlog("vm_audit109", syslog.LOG_PID, syslog.LOG_USER)
    old = syslog.setlogmask(syslog.LOG_UPTO(syslog.LOG_ERR))
    syslog.syslog(syslog.LOG_DEBUG, "vm_audit109: masked")
    syslog.syslog("vm_audit109: info")
    check("setlogmask returns the old mask", syslog.setlogmask(old), syslog.LOG_UPTO(syslog.LOG_ERR))
    syslog.closelog()
    check("syslog argument errors", [raises(syslog.syslog)[0], raises(syslog.syslog, 1, 2, 3)[0], raises(syslog.syslog, 5)[0]],
          ["TypeError", "TypeError", "TypeError"])

# ── mmap ─────────────────────────────────────────────────────────────────────
import mmap
p = tpath("map.bin")
write_bytes(p, b"hello world\nline2\nend")
with open(p, "r+b") as f:
    m = mmap.mmap(f.fileno(), 0)
    check("map the file", [len(m), m.size(), m[0], m[-1], m[0:5], m[6:11]], [21, 21, 104, 100, b"hello", b"world"])
    check("find / rfind", [m.find(b"world"), m.find(b"l"), m.rfind(b"l"), m.find(b"zz"), m.find(b"l", 5), m.find(b"o", 0, 5)],
          [6, 2, 12, -1, 9, 4])
    check("readline / tell / read", [m.readline(), m.tell(), m.read(4), m.tell(), m.readline(), m.read(), m.read()],
          [b"hello world\n", 12, b"line", 16, b"2\n", b"end", b""])
    m.seek(0)
    check("read_byte / seek", [m.read_byte(), m.tell()], [104, 1])
    check("find starts at the position", m.find(b"h"), -1)
    m.seek(-3, 2)
    check("seek from the end", m.read(), b"end")
    check("seek out of range", raises(m.seek, 100), ["ValueError", "seek out of range"])
    m[0:5] = b"HELLO"
    m[11] = ord("!")
    check("slice and item assignment", m[0:12], b"HELLO world!")
    check("steps", [m[::2][:6], m[4::-1]], [b"HLOwrd", b"OLLEH"])
    m.move(0, 6, 5)
    check("move", m[:12], b"world world!")
    m.seek(0)
    check("write returns the count", [m.write(b"WORLD"), m.tell()], [5, 5])
    m.flush()
    check("bytes(m)", bytes(m), b"WORLD world!line2\nend")
    check("errors", [raises(m.__getitem__, 100), raises(m.__setitem__, 0, 256), raises(m.__setitem__, slice(0, 2), b"abc")],
          [["IndexError", "mmap index out of range"], ["ValueError", "mmap item value must be in range(0, 256)"],
           ["IndexError", "mmap slice assignment is wrong size"]])
    m.seek(18)
    check("write past the end", raises(m.write, b"toolong"), ["ValueError", "data out of range"])
    m.close()
    check("closed", [m.closed, raises(len, m), raises(m.read)], [True, ["ValueError", "mmap closed or invalid"],
                                                                  ["ValueError", "mmap closed or invalid"]])
check("the file saw the writes", read_bytes(p), b"WORLD world!line2\nend")
with open(p, "rb") as f:
    with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        check("ACCESS_READ refuses writes", raises(m.__setitem__, 0, 65),
              ["TypeError", "mmap can't modify a readonly memory map."])
        check("and resize", raises(m.resize, 100)[0], "TypeError")
    check("with closes", m.closed, True)
with open(p, "r+b") as f:
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_COPY)
    m[0:5] = b"xxxxx"
    check("ACCESS_COPY: private", [m[0:5], read_bytes(p)[0:5]], [b"xxxxx", b"WORLD"])
    m.close()
    m = mmap.mmap(f.fileno(), 0)
    m.resize(30)
    m[21:30] = b"123456789"
    m.close()
check("resize grows the file", [os.path.getsize(p), read_bytes(p)[-9:]], [30, b"123456789"])
a = mmap.mmap(-1, 16)
check("anonymous", [len(a), a[:4], a.write(b"abc"), a[:4], list(a)[:3]], [16, b"\0\0\0\0", 3, b"abc\0", [b"a", b"b", b"c"]])
check("item values", [a[0], a[3]], [97, 0])
a.close()
write_bytes(tpath("empty.bin"), b"")
with open(tpath("empty.bin"), "rb") as f:
    check("empty file", raises(mmap.mmap, f.fileno(), 0), ["ValueError", "cannot mmap an empty file"])
with open(p, "rb") as f:
    check("too long", raises(mmap.mmap, f.fileno(), 1000, access=mmap.ACCESS_READ),
          ["ValueError", "mmap length is greater than file size"])
check("constants", [mmap.PAGESIZE > 0, mmap.ALLOCATIONGRANULARITY >= mmap.PAGESIZE, mmap.ACCESS_READ, mmap.ACCESS_WRITE,
                    mmap.ACCESS_COPY, mmap.ACCESS_DEFAULT], [True, True, 1, 2, 3, 0])
check("negative length", raises(mmap.mmap, -1, -1)[0], "OverflowError")
if posix:
    a = mmap.mmap(-1, mmap.PAGESIZE * 2, flags=mmap.MAP_PRIVATE, prot=mmap.PROT_READ | mmap.PROT_WRITE)
    a.madvise(mmap.MADV_NORMAL)
    a.resize(mmap.PAGESIZE * 3)
    check("anonymous resize and madvise", len(a), mmap.PAGESIZE * 3)
    a.close()
    big = tpath("big.bin")
    write_bytes(big, b"A" * mmap.ALLOCATIONGRANULARITY + b"tail")
    with open(big, "rb") as f:
        m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ, offset=mmap.ALLOCATIONGRANULARITY)
        check("offset", m[:], b"tail")
        m.close()
    check("access and flags together", raises(mmap.mmap, -1, 10, flags=mmap.MAP_PRIVATE, access=mmap.ACCESS_READ),
          ["ValueError", "mmap can't specify both access and flags, prot."])

# ── cmath ────────────────────────────────────────────────────────────────────
import cmath
import math
check("cmath basics", [cmath.sqrt(-1), cmath.sqrt(4), cmath.exp(0), cmath.log(1), cmath.log10(100), cmath.log(8, 2)],
      [1j, (2 + 0j), (1 + 0j), 0j, (2 + 0j), (3 + 0j)])
check("exact results", [cmath.exp(1j * math.pi), cmath.sqrt(2j), cmath.cos(1 + 1j), cmath.tan(0.5 - 0.25j)],
      [(-1 + 1.2246467991473532e-16j), (1 + 1j), (0.8337300251311491 - 0.9888977057628651j),
       (0.504500702698564 - 0.31242069250258875j)])
check("inverse functions", [cmath.acos(2), cmath.asin(0.5), cmath.atan(1j / 2), cmath.acosh(0.5), cmath.asinh(1j),
                            cmath.atanh(0.5)],
      [complex(0, -1.3169578969248166), (0.5235987755982989 + 0j), 0.5493061443340549j, 1.0471975511965979j, 1.5707963267948966j,
       (0.5493061443340549 + 0j)])
check("hyperbolic", [cmath.sinh(1 + 2j), cmath.cosh(1 + 2j), cmath.tanh(1 + 2j)],
      [(-0.4890562590412937 + 1.4031192506220405j), (-0.64214812471552 + 1.0686074213827783j),
       (1.16673625724092 - 0.24345820118572534j)])
check("polar / rect / phase", [cmath.polar(1 + 1j), cmath.polar(-2), cmath.rect(2, 0), cmath.phase(-1),
                               cmath.phase(complex(-1.0, -0.0)), cmath.phase(1j)],
      [(1.4142135623730951, 0.7853981633974483), (2.0, math.pi), (2 + 0j), math.pi, -math.pi, math.pi / 2])
check("rect(1, pi/2)", cmath.isclose(cmath.rect(1, math.pi / 2), 1j, abs_tol=1e-15), True)
check("constants", [cmath.pi, cmath.e, cmath.tau, cmath.inf, cmath.infj, repr(cmath.nan), repr(cmath.nanj)],
      [math.pi, math.e, 2 * math.pi, float("inf"), complex(0, float("inf")), "nan", "nanj"])
check("predicates", [cmath.isfinite(1 + 1j), cmath.isfinite(complex(1, float("inf"))), cmath.isinf(complex(float("inf"), 0)),
                     cmath.isnan(complex(0, float("nan"))), cmath.isnan(1)], [True, False, True, True, False])
check("isclose", [cmath.isclose(1 + 1j, 1 + 1.0000000001j), cmath.isclose(1, 1.1), cmath.isclose(1, 1.1, rel_tol=0.2),
                  cmath.isclose(0, 1e-10, abs_tol=1e-9), raises(cmath.isclose, 1, 1, rel_tol=-1)],
      [True, False, True, True, ["ValueError", "tolerances must be non-negative"]])
check("domain and range errors", [raises(cmath.log, 0), raises(cmath.atanh, 1), raises(cmath.exp, 1000),
                                  raises(cmath.exp, complex(1, float("inf"))), raises(cmath.sqrt, "x")],
      [["ValueError", "math domain error"], ["ValueError", "math domain error"], ["OverflowError", "math range error"],
       ["ValueError", "math domain error"], ["TypeError", "must be real number, not str"]])
inf = float("inf")
check("special values (C99 Annex G)", [cmath.sqrt(complex(-inf, 1)), cmath.sqrt(complex(inf, -2)), cmath.exp(complex(-inf, 0)),
                                       cmath.log(complex(-inf, 2)), cmath.atan(complex(inf, 1)), cmath.tanh(complex(inf, 3))],
      [complex(0, inf), complex(inf, -0.0), 0j, complex(inf, math.pi), complex(math.pi / 2, 0), complex(1, -0.0)])
check("signed zeros", [math.copysign(1, cmath.sqrt(complex(0.0, -0.0)).imag), math.copysign(1, cmath.sqrt(-0.0).real),
                       cmath.log(0, 2).real], [-1.0, 1.0, -inf])
check("branch cuts", [cmath.sqrt(complex(-4, 0.0)), cmath.sqrt(complex(-4, -0.0)), cmath.asin(complex(2, 0.0)),
                      cmath.asin(complex(2, -0.0))],
      [2j, complex(0, -2), (1.5707963267948966 + 1.3169578969248166j), (1.5707963267948966 - 1.3169578969248166j)])
class HasComplex:
    def __complex__(self):
        return 3 + 4j
class HasFloat:
    def __float__(self):
        return 9.0
check("argument conversion", [cmath.sqrt(HasComplex()), cmath.sqrt(HasFloat()), cmath.polar(HasComplex())[0]],
      [(2 + 1j), (3 + 0j), 5.0])

# ── colorsys ─────────────────────────────────────────────────────────────────
import colorsys
check("rgb_to_hsv / hsv_to_rgb", [colorsys.rgb_to_hsv(0.2, 0.4, 0.4), colorsys.hsv_to_rgb(0.5, 0.5, 0.4),
                                  colorsys.rgb_to_hsv(1, 0, 0), colorsys.hsv_to_rgb(0, 0, 0.5)],
      [(0.5, 0.5, 0.4), (0.2, 0.4, 0.4), (0.0, 1.0, 1), (0.5, 0.5, 0.5)])
check("rgb_to_hls / hls_to_rgb", [colorsys.rgb_to_hls(1, 0, 0), colorsys.hls_to_rgb(1 / 3, 0.5, 1.0),
                                  colorsys.rgb_to_hls(0.5, 0.5, 0.5)],
      [(0.0, 0.5, 1.0), (0.0, 1.0, 0.0), (0.0, 0.5, 0.0)])
y = colorsys.rgb_to_yiq(0.25, 0.5, 0.75)
check("yiq round trip", [round(v, 12) for v in colorsys.yiq_to_rgb(*y)], [0.25, 0.5, 0.75])

# ── sched ────────────────────────────────────────────────────────────────────
import sched
clock = [0.0]
def timefunc():
    return clock[0]
def delayfunc(d):
    clock[0] += d
s = sched.scheduler(timefunc, delayfunc)
log = []
s.enter(2, 1, log.append, ("b",))
s.enter(1, 1, log.append, ("a",))
ev = s.enter(3, 1, log.append, ("c",))
s.enterabs(2, 0, log.append, ("b0",))
def logkw(value=None):
    log.append(value)
s.enter(4, 1, logkw, kwargs={"value": "kw"})
check("sched.queue", [e.time for e in s.queue] == [1, 2, 2, 3, 4], True)
s.cancel(ev)
s.run()
check("sched.run: time, then priority", [log, clock[0], s.empty()], [["a", "b0", "b", "kw"], 4.0, True])
s.enter(5, 1, log.append, ("x",))
check("run(blocking=False)", s.run(blocking=False) == 5, True)
check("cancel a missing event", raises(s.cancel, ev)[0], "ValueError")

# ── getopt ───────────────────────────────────────────────────────────────────
import getopt
check("getopt", getopt.getopt(["-a", "-bval", "--long=x", "--flag", "arg1", "-a"], "ab:", ["long=", "flag"]),
      ([("-a", ""), ("-b", "val"), ("--long", "x"), ("--flag", "")], ["arg1", "-a"]))
check("gnu_getopt", getopt.gnu_getopt(["arg1", "-a", "-b", "v", "arg2", "--fl"], "ab:", ["flag"]),
      ([("-a", ""), ("-b", "v"), ("--flag", "")], ["arg1", "arg2"]))
check("getopt errors", [raises(getopt.getopt, ["-c"], "ab"), raises(getopt.getopt, ["--long"], "", ["long="]),
                        raises(getopt.getopt, ["--l"], "", ["long", "list"]), raises(getopt.getopt, ["-b"], "b:")],
      [["GetoptError", "option -c not recognized"], ["GetoptError", "option --long requires argument"],
       ["GetoptError", "option --l not a unique prefix"], ["GetoptError", "option -b requires argument"]])
try:
    getopt.getopt(["-z"], "a")
except getopt.GetoptError as e:
    check("GetoptError fields", [e.opt, e.msg, getopt.error is getopt.GetoptError], ["z", "option -z not recognized", True])
check("-- ends options", getopt.getopt(["-a", "--", "-b"], "ab"), ([("-a", "")], ["-b"]))

# ── optparse ─────────────────────────────────────────────────────────────────
import optparse
parser = optparse.OptionParser(usage="%prog [options] FILE", version="%prog 1.0", prog="tool",
                               formatter=optparse.IndentedHelpFormatter(width=78))
parser.add_option("-f", "--file", dest="filename", help="write report to FILE", metavar="FILE")
parser.add_option("-q", "--quiet", action="store_false", dest="verbose", default=True,
                  help="don't print status messages to stdout")
parser.add_option("-n", type="int", dest="num", default=3, help="how many [default: %default]")
parser.add_option("-v", action="count", dest="level")
parser.add_option("-t", "--tag", action="append", dest="tags")
parser.add_option("-m", type="choice", choices=["a", "b"], dest="mode")
group = optparse.OptionGroup(parser, "Dangerous Options", "Caution: use these options at your own risk.")
group.add_option("-g", action="store_true", help="Group option.")
parser.add_option_group(group)
opts, args = parser.parse_args(["-f", "out.txt", "-vv", "--tag=x", "-t", "y", "-n", "7", "in1", "-q", "in2"])
check("optparse values", [opts.filename, opts.verbose, opts.num, opts.level, opts.tags, opts.mode, opts.g, args],
      ["out.txt", False, 7, 2, ["x", "y"], None, None, ["in1", "in2"]])
check("optparse help", parser.format_help(),
      "Usage: tool [options] FILE\n\nOptions:\n  --version             show program's version number and exit\n"
      "  -h, --help            show this help message and exit\n  -f FILE, --file=FILE  write report to FILE\n"
      "  -q, --quiet           don't print status messages to stdout\n  -n NUM                how many [default: 3]\n"
      "  -v                    \n  -t TAGS, --tag=TAGS   \n  -m MODE               \n\n  Dangerous Options:\n"
      "    Caution: use these options at your own risk.\n\n    -g                  Group option.\n")
check("get_usage / version", [parser.get_usage(), parser.get_version()], ["Usage: tool [options] FILE\n", "tool 1.0"])
err = io.StringIO()
saved = sys.stderr
sys.stderr = err
try:
    parser.parse_args(["-m", "z"])
    code = None
except SystemExit as e:
    code = e.code
sys.stderr = saved
check("optparse error exits 2", [code, err.getvalue()],
      [2, "Usage: tool [options] FILE\n\ntool: error: option -m: invalid choice: 'z' (choose from 'a', 'b')\n"])
def cb(option, opt_str, value, parser, extra):
    parser.values.seen = (opt_str, value, extra)
p2 = optparse.OptionParser()
p2.add_option("-c", action="callback", callback=cb, type="string", callback_args=("E",))
p2.add_option("-k", action="store_const", const=42, dest="k")
o2, a2 = p2.parse_args(["-c", "val", "-k"])
check("callback / store_const", [o2.seen, o2.k], [("-c", "val", "E"), 42])
check("conflicting option", raises(p2.add_option, "-k")[0], "OptionConflictError")
check("Values", [str(optparse.Values({"a": 1})), optparse.Values({"a": 1}) == {"a": 1}], ["{'a': 1}", True])
p3 = optparse.OptionParser()
p3.disable_interspersed_args()
check("disable_interspersed_args", p3.parse_args(["a", "-h"])[1], ["a", "-h"])

# ── fileinput ────────────────────────────────────────────────────────────────
import fileinput
f1 = tpath("fi1.txt")
f2 = tpath("fi2.txt")
with open(f1, "w") as f:
    f.write("one\ntwo\n")
with open(f2, "w") as f:
    f.write("three\n")
seen = []
for line in fileinput.input([f1, f2]):
    seen.append((os.path.basename(fileinput.filename()), fileinput.lineno(), fileinput.filelineno(),
                 fileinput.isfirstline(), line))
check("fileinput over two files", seen,
      [("fi1.txt", 1, 1, True, "one\n"), ("fi1.txt", 2, 2, False, "two\n"), ("fi2.txt", 3, 1, True, "three\n")])
with fileinput.input(files=(f1, f2)) as fi:
    first = fi.readline()
    fi.nextfile()
    nxt = fi.readline()
check("readline / nextfile", [first, nxt], ["one\n", "three\n"])
with fileinput.input(f1, inplace=True, backup=".bak") as fi:
    for line in fi:
        sys.stdout.write(line.upper())
check("inplace with a backup", [open(f1).read(), open(f1 + ".bak").read()], ["ONE\nTWO\n", "one\ntwo\n"])
with fileinput.input(f1, mode="rb") as fi:
    check("binary mode", list(fi), [b"ONE\n", b"TWO\n"])
with fileinput.FileInput(f2, openhook=fileinput.hook_encoded("utf-8")) as fi:
    check("hook_encoded", list(fi), ["three\n"])

# ── filecmp ──────────────────────────────────────────────────────────────────
import filecmp
d1 = tpath("d1")
d2 = tpath("d2")
for d in (d1, d2, os.path.join(d1, "sub"), os.path.join(d2, "sub")):
    os.makedirs(d)
write_bytes(os.path.join(d1, "same.txt"), b"same")
write_bytes(os.path.join(d2, "same.txt"), b"same")
write_bytes(os.path.join(d1, "diff.txt"), b"left")
write_bytes(os.path.join(d2, "diff.txt"), b"rite")
write_bytes(os.path.join(d1, "only1.txt"), b"x")
write_bytes(os.path.join(d2, "only2.txt"), b"y")
write_bytes(os.path.join(d1, "sub", "s.txt"), b"s1")
write_bytes(os.path.join(d2, "sub", "s.txt"), b"s2")
check("filecmp.cmp", [filecmp.cmp(os.path.join(d1, "same.txt"), os.path.join(d2, "same.txt")),
                      filecmp.cmp(os.path.join(d1, "diff.txt"), os.path.join(d2, "diff.txt"), shallow=False)], [True, False])
check("cmpfiles", filecmp.cmpfiles(d1, d2, ["same.txt", "diff.txt", "nope.txt"]), (["same.txt"], ["diff.txt"], ["nope.txt"]))
dc = filecmp.dircmp(d1, d2)
check("dircmp", [dc.left_only, dc.right_only, dc.common_dirs, dc.same_files, dc.diff_files, sorted(dc.subdirs)],
      [["only1.txt"], ["only2.txt"], ["sub"], ["same.txt"], ["diff.txt"], ["sub"]])
out = io.StringIO()
saved = sys.stdout
sys.stdout = out
dc.report_full_closure()
sys.stdout = saved
check("dircmp report", out.getvalue().replace(TMP, "T"),
      "diff T/d1 T/d2\nOnly in T/d1 : ['only1.txt']\nOnly in T/d2 : ['only2.txt']\nIdentical files : ['same.txt']\n"
      "Differing files : ['diff.txt']\nCommon subdirectories : ['sub']\n\ndiff T/d1/sub T/d2/sub\n"
      "Differing files : ['s.txt']\n")
filecmp.clear_cache()
check("DEFAULT_IGNORES", ".git" in filecmp.DEFAULT_IGNORES and "__pycache__" in filecmp.DEFAULT_IGNORES, True)

# ── gettext ──────────────────────────────────────────────────────────────────
import gettext
def make_mo(entries):
    # GNU .mo, little-endian, entries sorted by the original string
    keys = sorted(entries)
    ids = b""
    strs = b""
    offs = []
    for k in keys:
        offs.append((len(ids), len(k), len(strs), len(entries[k])))
        ids += k + b"\0"
        strs += entries[k] + b"\0"
    n = len(keys)
    keystart = 7 * 4 + 16 * n
    valuestart = keystart + len(ids)
    koffsets = []
    voffsets = []
    for o1, l1, o2, l2 in offs:
        koffsets += [l1, o1 + keystart]
        voffsets += [l2, o2 + valuestart]
    out = struct.pack("Iiiiiii", 0x950412de, 0, n, 7 * 4, 7 * 4 + n * 8, 0, 0)
    for v in koffsets + voffsets:
        out += struct.pack("i", v)
    return out + ids + strs
mo = make_mo({b"": "Content-Type: text/plain; charset=UTF-8\nPlural-Forms: nplurals=2; plural=n != 1;\n".encode(),
              b"Hello": "Hallo".encode(), b"apple\0apples": "Apfel\0Äpfel".encode(),
              b"menu\x04Open": "Öffnen".encode(), b"menu\x04file\0files": "Datei\0Dateien".encode()})
locdir = tpath("locale")
os.makedirs(os.path.join(locdir, "de", "LC_MESSAGES"))
write_bytes(os.path.join(locdir, "de", "LC_MESSAGES", "app.mo"), mo)
t = gettext.translation("app", localedir=locdir, languages=["de"])
check("gettext", [t.gettext("Hello"), t.gettext("missing"), t.ngettext("apple", "apples", 1), t.ngettext("apple", "apples", 5),
                  t.ngettext("pear", "pears", 2)], ["Hallo", "missing", "Apfel", "Äpfel", "pears"])
check("pgettext / npgettext", [t.pgettext("menu", "Open"), t.pgettext("other", "Open"), t.npgettext("menu", "file", "files", 2)],
      ["Öffnen", "Open", "Dateien"])
check("info / charset", [t.info()["content-type"], t.charset(), type(t).__name__], ["text/plain; charset=UTF-8", "UTF-8",
                                                                                      "GNUTranslations"])
check("find", [os.path.basename(gettext.find("app", locdir, ["de"]) or ""), gettext.find("app", locdir, ["fr"])], ["app.mo", None])
check("translation fallback", [type(gettext.translation("app", locdir, ["fr"], fallback=True)).__name__,
                               raises(gettext.translation, "app", locdir, ["fr"])[0]], ["NullTranslations", "FileNotFoundError"])
plural = gettext.c2py("n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2")
check("c2py plural forms", [plural(1), plural(2), plural(5), plural(11), plural(21), plural(22), plural(111)],
      [0, 1, 2, 2, 0, 1, 2])
check("c2py refuses code", raises(gettext.c2py, "__import__('os')")[0], "ValueError")
n = gettext.NullTranslations()
check("NullTranslations", [n.gettext("a"), n.ngettext("a", "b", 2), n.pgettext("c", "a")], ["a", "b", "a"])
t2 = gettext.GNUTranslations(io.BytesIO(mo))
fb = gettext.NullTranslations()
t2.add_fallback(fb)
check("GNUTranslations from a file object", t2.gettext("Hello"), "Hallo")
gettext.bindtextdomain("app", locdir)
check("bindtextdomain / dgettext", [gettext.bindtextdomain("app"), gettext.dgettext("app", "Hello")], [locdir, "Hello"])
t.install()
import builtins
check("install binds _", builtins._("Hello"), "Hallo")
del builtins._

# ── readline, rlcompleter ────────────────────────────────────────────────────
import math
try:
    import readline
    have_readline = True
except ImportError:
    have_readline = False
if have_readline:
    readline.clear_history()
    readline.add_history("first")
    readline.add_history("second")
    readline.add_history("third")
    check("history", [readline.get_current_history_length(), readline.get_history_item(1), readline.get_history_item(3),
                      readline.get_history_item(9)], [3, "first", "third", None])
    readline.replace_history_item(0, "FIRST")
    readline.remove_history_item(1)
    check("replace / remove", [readline.get_history_item(1), readline.get_history_item(2), readline.get_current_history_length()],
          ["FIRST", "third", 2])
    hp = tpath("hist")
    readline.write_history_file(hp)
    readline.clear_history()
    readline.read_history_file(hp)
    check("history file round trip", [readline.get_current_history_length(), readline.get_history_item(2)], [2, "third"])
    readline.set_history_length(1)
    readline.write_history_file(hp)
    check("history_length cuts the file", [readline.get_history_length(), open(hp).read().splitlines()[-1:]], [1, ["third"]])
    readline.set_history_length(-1)
    check("errors", [raises(readline.remove_history_item, 99)[0], raises(readline.read_history_file, tpath("nope"))[0]],
          ["ValueError", "FileNotFoundError"])
    readline.clear_history()
    import rlcompleter
    comp = rlcompleter.Completer({"spam": 1, "spaghetti": 2, "math": math})
    matches = []
    i = 0
    while True:
        c = comp.complete("spa", i)
        if c is None:
            break
        matches.append(c)
        i += 1
    check("rlcompleter global names", sorted(matches), ["spaghetti", "spam"])
    check("rlcompleter attributes", [comp.complete("math.sqr", 0), comp.complete("math.pi", 0)], ["math.sqrt(", "math.pi"])
    check("keywords", rlcompleter.Completer({}).complete("whil", 0), "while ")
    readline.set_completer(comp.complete)
    check("set_completer / get_completer", readline.get_completer() == comp.complete, True)
    readline.set_completer(None)
    check("completer delims", readline.get_completer_delims(), " \t\n`~!@#$%^&*()-=+[{]}\\|;:'\",<>/?")
    readline.set_completer_delims(" ")
    check("set_completer_delims", readline.get_completer_delims(), " ")
    readline.set_completer_delims(" \t\n`~!@#$%^&*()-=+[{]}\\|;:'\",<>/?")

# ── site, sysconfig ──────────────────────────────────────────────────────────
import sysconfig
import site
ver = "%d.%d" % sys.version_info[:2]
check("sysconfig version", [sysconfig.get_python_version(), sysconfig.get_config_var("py_version_short")], [ver, ver])
check("sysconfig path names", sysconfig.get_path_names(), ("stdlib", "platstdlib", "purelib", "platlib", "include", "scripts", "data"))
check("get_paths keys", set(sysconfig.get_path_names()) <= set(sysconfig.get_paths()), True)
check("schemes", ["posix_prefix" in sysconfig.get_scheme_names(), "nt" in sysconfig.get_scheme_names()], [True, True])
check("get_platform", sysconfig.get_platform().startswith("linux") if linux else True, True)
check("config vars", [isinstance(sysconfig.get_config_vars(), dict), sysconfig.get_config_var("no-such-var"),
                      sysconfig.get_config_var("EXE") == (".exe" if not posix else "")], [True, None, True])
check("get_path", sysconfig.get_path("stdlib") == sysconfig.get_paths()["stdlib"], True)
check("default scheme", sysconfig.get_default_scheme() in (("posix_prefix", "posix_local") if posix else ("nt",)), True)
check("site.getuserbase", site.getuserbase() == os.environ.get("PYTHONUSERBASE", os.path.expanduser("~/.local")) if posix else True,
      True)
check("site lists", [isinstance(site.getsitepackages(), list), isinstance(site.getusersitepackages(), str),
                     site.ENABLE_USER_SITE in (True, False, None), isinstance(site.PREFIXES, list)], [True, True, True, True])
sd = tpath("sitedir")
os.makedirs(os.path.join(sd, "extra"))
with open(os.path.join(sd, "x.pth"), "w") as f:
    f.write("# a comment\nextra\nmissing-dir\n")
site.addsitedir(sd)
check("addsitedir reads .pth files", [os.path.join(sd, "extra") in sys.path, os.path.join(sd, "missing-dir") in sys.path,
                                      sd in sys.path], [True, False, True])
check("makepath", site.makepath("a", "b")[0] == os.path.abspath(os.path.join("a", "b")), True)

# ── webbrowser ───────────────────────────────────────────────────────────────
import webbrowser
opened = []
class Recorder(webbrowser.BaseBrowser):
    def open(self, url, new=0, autoraise=True):
        opened.append((url, new))
        return True
webbrowser.register("recorder", Recorder, preferred=True)
check("webbrowser.open through a registered browser",
      [webbrowser.open("http://example.invalid/a"), webbrowser.open_new("u2"), webbrowser.open_new_tab("u3"), opened],
      [True, True, True, [("http://example.invalid/a", 0), ("u2", 1), ("u3", 2)]])
check("webbrowser.get", [isinstance(webbrowser.get("recorder"), Recorder), raises(webbrowser.get, "no-such-browser-xyz")[0]],
      [True, "Error"])
check("webbrowser.Error", issubclass(webbrowser.Error, Exception), True)

# ── zipimport, zipapp ────────────────────────────────────────────────────────
import zipfile
import zipimport
import zipapp
zp = tpath("mods.zip")
with zipfile.ZipFile(zp, "w") as z:
    z.writestr("ny109zmod.py", "x = 41\ndef f():\n    return x + 1\n")
    z.writestr("ny109zpkg/__init__.py", "name = 'pkg'\n")
    z.writestr("ny109zpkg/sub.py", "from . import name\nval = name + '.sub'\n")
sys.path.insert(0, zp)
import ny109zmod
import ny109zpkg.sub
check("import from a zip on sys.path", [ny109zmod.f(), ny109zpkg.sub.val, zp in ny109zmod.__file__,
                                         ny109zmod.__file__.endswith("ny109zmod.py")], [42, "pkg.sub", True, True])
zi = zipimport.zipimporter(zp)
check("zipimporter", [zi.is_package("ny109zpkg"), zi.is_package("ny109zmod"), zi.get_source("ny109zmod").splitlines()[0],
                      zi.archive == zp, zi.find_spec("ny109zmod").name, zi.find_spec("nothere")],
      [True, False, "x = 41", True, "ny109zmod", None])
check("zipimport errors", [raises(zipimport.zipimporter, tpath("not-a-zip"))[0], issubclass(zipimport.ZipImportError, ImportError)],
      ["ZipImportError", True])
sys.path.remove(zp)
src = tpath("appsrc")
os.makedirs(src)
with open(os.path.join(src, "app.py"), "w") as f:
    f.write("import sys\ndef main():\n    print('hello from app', len(sys.argv))\n")
target = tpath("app.pyz")
zipapp.create_archive(src, target, interpreter="/usr/bin/env python3", main="app:main")
check("zipapp archive", [read_bytes(target)[:23], zipapp.get_interpreter(target)], [b"#!/usr/bin/env python3\n", "/usr/bin/env python3"])
r = subprocess.run([sys.executable, target, "a", "b"], capture_output=True, timeout=60)
check("running the archive", [r.returncode, r.stdout.decode().strip()], [0, "hello from app 3"])
check("zipapp errors", [raises(zipapp.create_archive, src, tpath("x.pyz"), main="bad")[0],
                        raises(zipapp.create_archive, tpath("nosrc"), tpath("y.pyz"))[0]],
      ["ZipAppError", "ZipAppError"])
r = subprocess.run([sys.executable, "-m", "zipapp", src, "-o", tpath("cli.pyz"), "-m", "app:main"], capture_output=True,
                   timeout=60)
check("python -m zipapp", [r.returncode, zipfile.is_zipfile(tpath("cli.pyz"))], [0, True])

# ── encodings, stringprep ────────────────────────────────────────────────────
import codecs
import encodings
import encodings.aliases
check("normalize_encoding", [encodings.normalize_encoding("Latin 1"), encodings.normalize_encoding("utf-8"),
                             encodings.normalize_encoding("  x--y ")], ["Latin_1", "utf_8", "x_y"])
check("search_function", [encodings.search_function("cp1251").name, encodings.search_function("no-such-codec")],
      ["cp1251", None])
check("code pages", ["Привет".encode("cp1251"), b"\xcf\xf0".decode("cp1251"),
                     "€".encode("iso8859_15"), "A".encode("cp037"), "ж".encode("koi8_r"),
                     b"\xe9".decode("iso8859_2"), "š".encode("cp1250")],
      [b"\xcf\xf0\xe8\xe2\xe5\xf2", "Пр", b"\xa4", b"\xc1", b"\xd6", "é", b"\x9a"])
check("codecs.lookup names", [codecs.lookup("koi8_r").name, codecs.lookup("latin2").name, codecs.lookup("CP1252").name],
      ["koi8-r", "iso8859-2", "cp1252"])
check("aliases", [encodings.aliases.aliases["utf8"], encodings.aliases.aliases["latin1"], encodings.aliases.aliases["866"]],
      ["utf_8", "latin_1", "cp866"])
import encodings.utf_8
import encodings.cp1252
check("codec modules", [encodings.utf_8.encode("é"), encodings.utf_8.decode(b"\xc3\xa9"),
                        encodings.cp1252.getregentry().name, encodings.cp1252.Codec().encode("€")],
      [(b"\xc3\xa9", 1), ("é", 2), "cp1252", (b"\x80", 1)])
check("errors through a code page", ["a一b".encode("cp1251", "replace"), b"\x98".decode("cp1251", "replace")],
      [b"a?b", "�"])
check("unknown encoding", raises(codecs.lookup, "no-such-codec"), ["LookupError", "unknown encoding: no-such-codec"])
import stringprep
check("stringprep tables", [stringprep.in_table_a1("ȡ"), stringprep.in_table_a1("a"), stringprep.in_table_b1("­"),
                            stringprep.map_table_b3("ß"), stringprep.map_table_b2("A"), stringprep.in_table_c11(" "),
                            stringprep.in_table_c12(" "), stringprep.in_table_c21("\x00"), stringprep.in_table_c22("‍"),
                            stringprep.in_table_c3(""), stringprep.in_table_c4("￾"), stringprep.in_table_c6("￹"),
                            stringprep.in_table_c7("⿰"), stringprep.in_table_c8("‎"), stringprep.in_table_c9("\U000e0001"),
                            stringprep.in_table_d1("א"), stringprep.in_table_d2("a"), stringprep.in_table_d1("a")],
      [True, False, True, "ss", "a", True, True, True, True, True, True, True, True, True, True, True, True, False])
check("stringprep B.2/B.3", [stringprep.map_table_b2("Ⅳ"), stringprep.map_table_b3("İ"), stringprep.map_table_b2("ẞ")],
      ["ⅳ", "i̇", "ss"])

# ── bz2 ──────────────────────────────────────────────────────────────────────
import bz2
import hashlib
check("bz2: libbz2's bytes", [bz2.compress(b"").hex(), bz2.compress(b"hello world\n" * 3, 1).hex(),
                              bz2.compress(b"abcabc" * 50 + b"xyz", 9).hex()],
      ["425a683917724538509000000000",
       "425a6831314159265359a354569200000751800010400006449080200022bfd5434f4420c988e222296b56988c7c5dc914e142428d515a48",
       "425a6839314159265359f7c2d3c8000000018038000070200030c002951a69b942e9161177dbf177245385090f7c2d3c80"])
big = bytes(range(256)) * 4000 + b"tail" * 100000
cbig = bz2.compress(big, 1)
check("bz2: several blocks, as libbz2", [len(cbig), hashlib.sha256(cbig).hexdigest()],
      [10188, "c0a4cdd702965834e093ee5bd939ffd43aaef3636ef978208142012f57c3fb46"])
check("bz2 round trips", [bz2.decompress(cbig) == big, bz2.decompress(bz2.compress(b"x" * 1000000)) == b"x" * 1000000],
      [True, True])
c = bz2.BZ2Compressor(9)
parts = c.compress(b"incremental ") + c.compress(b"data" * 1000) + c.flush()
check("BZ2Compressor", [parts == bz2.compress(b"incremental " + b"data" * 1000), raises(c.flush), raises(c.compress, b"x")],
      [True, ["ValueError", "Repeated call to flush()"], ["ValueError", "Compressor has been flushed"]])
d = bz2.BZ2Decompressor()
data = bz2.compress(b"0123456789" * 100)
out1 = d.decompress(data[:20])
check("BZ2Decompressor: a partial stream", [out1, d.eof, d.needs_input], [b"", False, True])
out2 = d.decompress(data[20:] + b"TRAILING", max_length=100)
check("max_length and unused_data", [len(out2), d.eof, d.needs_input], [100, False, False])
out3 = d.decompress(b"")
check("the rest", [len(out3), d.eof, d.unused_data, d.needs_input], [900, True, b"TRAILING", False])
check("after the end", raises(d.decompress, b"x"), ["EOFError", "End of stream already reached"])
check("bz2 errors", [raises(bz2.decompress, b"not bzip2 data"), raises(bz2.BZ2Compressor, 0),
                     raises(bz2.decompress, bz2.compress(b"abc")[:-3])],
      [["OSError", "Invalid data stream"], ["ValueError", "compresslevel must be between 1 and 9"],
       ["ValueError", "Compressed data ended before the end-of-stream marker was reached"]])
check("concatenated streams", bz2.decompress(bz2.compress(b"one") + bz2.compress(b"two")), b"onetwo")
bp = tpath("t.bz2")
with bz2.open(bp, "wt", encoding="utf-8") as f:
    f.write("line one\nline two\né\n")
with bz2.open(bp, "rt", encoding="utf-8") as f:
    check("bz2.open text", [f.readline(), f.read()], ["line one\n", "line two\né\n"])
with bz2.BZ2File(bp) as f:
    f.seek(5)
    check("BZ2File seek / tell / peek", [f.read(3), f.tell(), f.peek(1)[:1]], [b"one", 8, b"\n"])
bio = io.BytesIO()
with bz2.BZ2File(bio, "w", compresslevel=1) as f:
    f.write(b"to a file object")
check("BZ2File over a file object", bz2.decompress(bio.getvalue()), b"to a file object")
with bz2.open(bp, "ab") as f:
    f.write(b"appended\n")
check("append mode adds a stream", bz2.decompress(read_bytes(bp)).endswith(b"appended\n"), True)

# ── lzma ─────────────────────────────────────────────────────────────────────
import lzma
xz = bytes.fromhex("fd377a585a000004e6d6b4460200210116000000742fe5a3e00153001a5d00371e4ad07cef8fe79e11c528194e84522039dbd3"
                   "117965cc000000000020cfed312b5abd22000136d4020000007f210ac7b1c467fb020000000004595a")
check("lzma: CPython's .xz", lzma.decompress(xz), b"nython lzma test\n" * 20)
alone = bytes.fromhex("5d00008000ffffffffffffffff00309b0a4324c8b6080a49bf62da0fa1ffffff81c40000")
check("lzma: a .lzma file", [lzma.decompress(alone), lzma.decompress(alone, format=lzma.FORMAT_ALONE)],
      [b"alone format", b"alone format"])
dz = lzma.LZMADecompressor()
check("check id", [dz.check, dz.decompress(xz[:30]), dz.check, dz.eof], [lzma.CHECK_UNKNOWN, b"", lzma.CHECK_CRC64, False])
check("the rest of the stream", [len(dz.decompress(xz[30:] + b"extra")), dz.eof, dz.unused_data], [340, True, b"extra"])
check("after the end", raises(dz.decompress, b"x"), ["EOFError", "Already at end of stream"])
check("lzma errors", [raises(lzma.decompress, b"garbage data here"), raises(lzma.LZMACompressor, format=lzma.FORMAT_RAW),
                      raises(lzma.LZMADecompressor, format=lzma.FORMAT_RAW),
                      raises(lzma.LZMACompressor, format=lzma.FORMAT_ALONE, check=lzma.CHECK_CRC32),
                      raises(lzma.LZMACompressor, preset=1, filters=[]),
                      raises(lzma.LZMACompressor, format=lzma.FORMAT_RAW, filters=[{"id": 99}]),
                      raises(lzma.LZMACompressor, format=lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA2, "bad": 1}])],
      [["LZMAError", "Input format not supported by decoder"], ["ValueError", "Must specify filters for FORMAT_RAW"],
       ["ValueError", "Must specify filters for FORMAT_RAW"], ["ValueError", "Integrity checks are only supported by FORMAT_XZ"],
       ["ValueError", "Cannot specify both preset and filter chain"], ["ValueError", "Invalid filter ID: 99"],
       ["ValueError", "Invalid filter specifier for LZMA filter"]])
check("filter properties", [lzma._encode_filter_properties({"id": lzma.FILTER_LZMA2, "preset": 6}),
                            lzma._decode_filter_properties(lzma.FILTER_LZMA2, b"\x16"),
                            lzma._decode_filter_properties(lzma.FILTER_DELTA, b"\x03")],
      [b"\x16", {"id": 33, "dict_size": 8388608}, {"id": 3, "dist": 4}])
check("is_check_supported", [lzma.is_check_supported(lzma.CHECK_NONE), lzma.is_check_supported(lzma.CHECK_CRC64),
                             lzma.is_check_supported(lzma.CHECK_SHA256)], [True, True, True])
payload = b"The quick brown fox jumps over the lazy dog. " * 200
check("lzma round trips", [lzma.decompress(lzma.compress(payload)) == payload,
                           lzma.decompress(lzma.compress(payload, check=lzma.CHECK_SHA256)) == payload,
                           lzma.decompress(lzma.compress(payload, format=lzma.FORMAT_ALONE)) == payload,
                           lzma.decompress(lzma.compress(payload, preset=9 | lzma.PRESET_EXTREME)) == payload],
      [True, True, True, True])
filters = [{"id": lzma.FILTER_DELTA, "dist": 4}, {"id": lzma.FILTER_LZMA2, "preset": 1}]
raw = lzma.compress(payload, format=lzma.FORMAT_RAW, filters=filters)
check("FORMAT_RAW with a filter chain", lzma.decompress(raw, format=lzma.FORMAT_RAW, filters=filters) == payload, True)
c = lzma.LZMACompressor(check=lzma.CHECK_CRC32)
stream = c.compress(b"part one, ") + c.compress(b"part two") + c.flush()
dz = lzma.LZMADecompressor()
check("incremental, CHECK_CRC32", [dz.decompress(stream), dz.check], [b"part one, part two", lzma.CHECK_CRC32])
lp = tpath("t.xz")
with lzma.open(lp, "wt", encoding="utf-8") as f:
    f.write("xz line\nsecond\n")
with lzma.open(lp, "rt", encoding="utf-8") as f:
    check("lzma.open text", f.readlines(), ["xz line\n", "second\n"])
with lzma.LZMAFile(lp) as f:
    check("LZMAFile", [f.read(2), f.tell(), f.seekable()], [b"xz", 2, True])
check("concatenated streams", lzma.decompress(lzma.compress(b"a") + lzma.compress(b"b")), b"ab")
if nython:
    # without liblzma (NY_NO_LIBLZMA=1 pretends it is absent) the native
    # decoder still reads .xz and .lzma; a compressor names the library
    r = child("import lzma\nprint(int(lzma.decompress(bytes.fromhex('" + xz.hex() + "')) == b'nython lzma test\\n' * 20))\n"
              "print(lzma.decompress(bytes.fromhex('" + alone.hex() + "')))\n"
              "try:\n    lzma.compress(b'x')\nexcept lzma.LZMAError as e:\n    print(int('liblzma' in str(e)))\n",
              {"NY_NO_LIBLZMA": "1"})
    check("without liblzma: the native decoder", [r[0]] + r[1].split(), [0, "1", "b'alone", "format'", "1"])

# ── faulthandler ─────────────────────────────────────────────────────────────
import faulthandler
import threading
check("faulthandler off", faulthandler.is_enabled(), False)
faulthandler.enable()
check("enable / disable", [faulthandler.is_enabled(), faulthandler.disable(), faulthandler.is_enabled(), faulthandler.disable()],
      [True, True, False, False])
fp = tpath("dump.txt")
def deep_dump(f):
    line = sys._getframe().f_lineno; faulthandler.dump_traceback(f, all_threads=False)
    return line
with open(fp, "w") as f:
    l1 = deep_dump(f)
text = open(fp).read().splitlines()
check("dump_traceback: this thread", [text[0], text[1]],
      ["Stack (most recent call first):", '  File "%s", line %d in deep_dump' % (__file__, l1)])
with open(fp, "w") as f:
    faulthandler.dump_traceback(f.fileno(), all_threads=True)
text = open(fp).read().splitlines()
check("dump_traceback: all threads", [text[0], text[1].endswith(" in <module>")],
      ["Current thread 0x%016x (most recent call first):" % threading.get_ident(), True])
check("argument errors", [raises(faulthandler.dump_traceback_later, 0), raises(faulthandler.dump_traceback_later, -1)],
      [["ValueError", "timeout must be greater than 0"], ["ValueError", "timeout must be greater than 0"]])
faulthandler.cancel_dump_traceback_later()
r = child("import faulthandler\nfaulthandler.enable()\ndef crash():\n    faulthandler._sigsegv()\ncrash()\n")
lines = r[2].splitlines()
check("a segfault is reported", [r[0] == -11 if posix else r[0] != 0, lines[0], lines[1], lines[2].startswith("Current thread 0x"),
                                  lines[3], lines[4]],
      [True, "Fatal Python error: Segmentation fault", "", True, '  File "%s", line 4 in crash' % r[3],
       '  File "%s", line 5 in <module>' % r[3]])
r = child("import faulthandler, time\nfaulthandler.dump_traceback_later(0.2, exit=True)\nfor i in range(100):\n    time.sleep(0.1)\n")
lines = r[2].splitlines()
check("dump_traceback_later: the watchdog", [r[0], lines[0], lines[1].startswith("Thread 0x"),
                                              lines[2].startswith('  File "%s", line 4 in <module>' % r[3])],
      [1, "Timeout (0:00:00.200000)!", True, True])
if posix:
    import signal
    with open(fp, "w") as f:
        faulthandler.register(signal.SIGUSR1, file=f, all_threads=False)
        line = sys._getframe().f_lineno; os.kill(os.getpid(), signal.SIGUSR1)
        check("register / unregister", [faulthandler.unregister(signal.SIGUSR1), faulthandler.unregister(signal.SIGUSR1)],
              [True, False])
    text = open(fp).read().splitlines()
    check("a user signal dumps the stack", text[:2],
          ["Stack (most recent call first):", '  File "%s", line %d in <module>' % (__file__, line)])
    check("fatal signals cannot be registered", raises(faulthandler.register, signal.SIGSEGV)[0], "RuntimeError")

# ── tracemalloc ──────────────────────────────────────────────────────────────
import tracemalloc
import gc
check("tracemalloc off", [tracemalloc.is_tracing(), tracemalloc.get_traced_memory()], [False, (0, 0)])
tracemalloc.start()
check("start", [tracemalloc.is_tracing(), tracemalloc.get_traceback_limit()], [True, 1])
alloc_line = sys._getframe().f_lineno + 1
blob = [bytes(1000) + bytes([i % 256]) for i in range(200)]
snap = tracemalloc.take_snapshot()
stats = snap.statistics("lineno")
mine = [s for s in stats if s.traceback[0].filename == __file__ and s.traceback[0].lineno == alloc_line]
check("the allocating line is in the statistics", [len(mine), mine[0].size >= 200 * 1000 if mine else False,
                                                    mine[0].count >= 200 if mine else False], [1, True, True])
cur, peak = tracemalloc.get_traced_memory()
check("get_traced_memory", [cur >= 200 * 1000, peak >= cur], [True, True])
tracemalloc.reset_peak()
cur2, peak2 = tracemalloc.get_traced_memory()
check("reset_peak", peak2 - cur2 < 100000, True)
obj_line = sys._getframe().f_lineno + 1
tracked = [1, 2, 3, "four"]
tb = tracemalloc.get_object_traceback(tracked)
check("get_object_traceback", [tb is not None, tb[0].lineno if tb else None, tb[0].filename == __file__ if tb else None],
      [True, obj_line, True])
del blob
gc.collect()
snap2 = tracemalloc.take_snapshot()
diff = [s for s in snap2.compare_to(snap, "lineno") if s.traceback[0].filename == __file__ and s.traceback[0].lineno == alloc_line]
check("compare_to sees the memory go", [len(diff), diff[0].size_diff < -150000 if diff else False], [1, True])
filtered = snap.filter_traces([tracemalloc.Filter(True, __file__)])
check("Filter", all(t.traceback[0].filename == __file__ for t in filtered.traces), True)
check("Statistic str", str(mine[0]).startswith("%s:%d: size=" % (__file__, alloc_line)) if mine else False, True)
by_file = snap.statistics("filename")
check("statistics by filename", any(s.traceback[0].filename == __file__ for s in by_file), True)
tracemalloc.stop()
check("stop", [tracemalloc.is_tracing(), tracemalloc.get_traced_memory(), tracemalloc.get_object_traceback(tracked)],
      [False, (0, 0), None])
def inner_alloc():
    return [bytes(5000) for _ in range(10)]
def outer_alloc():
    return inner_alloc()
tracemalloc.start(5)
keep = outer_alloc()
snap3 = tracemalloc.take_snapshot()
tracemalloc.stop()
deep = [s for s in snap3.statistics("traceback") if s.traceback[-1].filename == __file__ and len(s.traceback) >= 3
        and s.size >= 50000]
check("nframe=5 keeps the callers", [len(deep) >= 1, snap3.traceback_limit], [True, 5])
check("start(0)", raises(tracemalloc.start, 0), ["ValueError", "the number of frames must be in range [1; 65535]"])
check("Traceback.format", tracemalloc.Traceback(((__file__, 1),)).format(), ['  File "%s", line 1' % __file__, '    # vm_audit109.ny - Python\'s system and command-line modules, both engines'])

# ── locale ───────────────────────────────────────────────────────────────────
import locale
import codecs
check("setlocale C", [locale.setlocale(locale.LC_ALL, "C"), locale.setlocale(locale.LC_NUMERIC), locale.getlocale(locale.LC_NUMERIC)],
      ["C", "C", (None, None)])
conv = locale.localeconv()
check("localeconv in C", [conv["decimal_point"], conv["thousands_sep"], conv["grouping"], conv["int_frac_digits"],
                          conv["currency_symbol"], locale.CHAR_MAX], [".", "", [], 127, "", 127])
check("normalize", [locale.normalize("en_US"), locale.normalize("de_DE.utf8"), locale.normalize("C"), locale.normalize("ja_jp.eucjp"),
                    locale.normalize("de")], ["en_US.ISO8859-1", "de_DE.UTF-8", "C", "ja_JP.eucJP", "de_DE.ISO8859-1"])
check("_parse_localename", [locale._parse_localename("en_US.UTF-8"), locale._parse_localename("C")], [("en_US", "UTF-8"), (None, None)])
check("formatting in C", [locale.format_string("%d", 1234567, grouping=True), locale.str(1.5), locale.atof("2.5"),
                          locale.atoi("42"), locale.format_string("%s and %.1f", ("x", 2.25))], ["1234567", "1.5", 2.5, 42, "x and 2.2"])
locale._override_localeconv = {"thousands_sep": ",", "grouping": [3, 3, 0], "decimal_point": "."}
check("grouping", [locale.format_string("%d", 1234567, grouping=True), locale.format_string("%.2f", 1234567.891, grouping=True),
                   locale.atof("1,234.5"), locale.atoi("1,234"), locale.delocalize("1,234.5"), locale.localize("1234.5", grouping=True)],
      ["1,234,567", "1,234,567.89", 1234.5, 1234, "1234.5", "1,234.5"])
locale._override_localeconv = {"currency_symbol": "$", "mon_decimal_point": ".", "mon_thousands_sep": ",", "mon_grouping": [3, 3, 0],
                               "frac_digits": 2, "int_frac_digits": 2, "p_cs_precedes": 1, "p_sep_by_space": 0, "p_sign_posn": 1,
                               "n_cs_precedes": 1, "n_sep_by_space": 0, "n_sign_posn": 1, "positive_sign": "", "negative_sign": "-",
                               "int_curr_symbol": "USD "}
check("currency", [locale.currency(1234.5, grouping=True), locale.currency(-5), locale.currency(3, symbol=False),
                   locale.currency(7, international=True)], ["$1,234.50", "-$5.00", "3.00", "USD 7.00"])
locale._override_localeconv = {}
check("strcoll / strxfrm", [locale.strcoll("a", "b") < 0, locale.strcoll("b", "a") > 0, locale.strcoll("a", "a"),
                            locale.strxfrm("abc")], [True, True, 0, "abc"])
check("unsupported locale", [raises(locale.setlocale, locale.LC_ALL, "xx_NOT.valid")[0], issubclass(locale.Error, Exception)],
      ["Error", True])
if posix:
    check("nl_langinfo", [locale.nl_langinfo(locale.DAY_1), locale.nl_langinfo(locale.ABMON_1), locale.nl_langinfo(locale.RADIXCHAR),
                          locale.nl_langinfo(locale.D_T_FMT)], ["Sunday", "Jan", ".", "%a %b %e %H:%M:%S %Y"])
if linux:
    check("CODESET in C", locale.nl_langinfo(locale.CODESET), "ANSI_X3.4-1968")
check("getpreferredencoding is a codec", codecs.lookup(locale.getpreferredencoding(False)).name != "", True)
try:
    locale.setlocale(locale.LC_NUMERIC, "C.UTF-8")
    check("floats print the same whatever LC_NUMERIC is", [str(0.5), repr(2.25), "%.1f" % 1.5], ["0.5", "2.25", "1.5"])
except locale.Error:
    pass
locale.setlocale(locale.LC_ALL, "C")

# ── done ─────────────────────────────────────────────────────────────────────
shutil.rmtree(TMP, ignore_errors=True)
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT109 PASSED ===")
