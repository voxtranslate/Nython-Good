# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/fcntl.ny - Python's fcntl module (round 83): fcntl(2) and ioctl(2) on
# file descriptors, and advisory file locks. POSIX only: on Windows
# `import fcntl` raises ModuleNotFoundError, as CPython's does.
#
#     import fcntl, os
#     fd = os.open(path, os.O_RDWR)
#     flags = fcntl.fcntl(fd, fcntl.F_GETFL)
#     fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
#     fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)     # BlockingIOError when held
#     fcntl.lockf(fd, fcntl.LOCK_SH, 10, 0)              # a byte-range lock
#     rows, cols = struct.unpack("hhhh", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))[:2]
#
# fcntl(fd, cmd, arg=0)      an int arg gives the int result; a bytes/str arg
#                            (at most 1024 bytes) is copied into a buffer and
#                            the buffer comes back as bytes
# ioctl(fd, request, arg=0, mutate_flag=True)
#                            the same; a bytearray with mutate_flag is changed
#                            in place and the call's int result returned
# flock(fd, operation)       flock(2): LOCK_SH, LOCK_EX, LOCK_UN, | LOCK_NB
# lockf(fd, cmd, len=0, start=0, whence=0)
#                            POSIX record locks through fcntl(F_SETLK[W]) as
#                            CPython does it
# fd may be an int or any object with fileno(). The constants are the
# platform's own (F_*, FD_CLOEXEC, LOCK_*, F_OFD_*, F_*SEAL*, DN_*, ...),
# generated natively from <fcntl.h>. Blocking calls (F_SETLKW, flock without
# LOCK_NB) release the GIL while they wait.
#
# Not here: nothing of CPython's 3.12 module is left out; I_* STREAMS
# constants exist only where the platform has them (none of the supported ones).

if not _sys_platform_posix():
    raise ModuleNotFoundError("No module named 'fcntl'", name="fcntl")


def _load():
    var g = globals()
    for pair in _sys_consts("fcntl"):
        g[pair[0]] = pair[1]


_load()
del _load


def _fd(fd):
    # PyObject_AsFileDescriptor
    if not isinstance(fd, int):
        var meth = getattr(fd, "fileno", None)
        if meth is None:
            raise TypeError("argument must be an int, or have a fileno() method.")
        fd = meth()
        if not isinstance(fd, int):
            raise TypeError("fileno() returned a non-integer")
    if fd < 0:
        raise ValueError("file descriptor cannot be a negative integer (" + str(fd) + ")")
    return fd


def _int_arg(v):
    if isinstance(v, float):
        raise TypeError("'float' object cannot be interpreted as an integer")
    if not isinstance(v, int):
        raise TypeError("integer argument expected, got " + type(v).__name__)
    return v


def fcntl(fd, cmd, arg=0, /):
    """Perform the operation `cmd` on file descriptor fd."""
    fd = _fd(fd)
    if isinstance(arg, str):
        arg = arg.encode()
    if isinstance(arg, (bytes, bytearray)):
        if len(arg) > 1024:
            raise ValueError("fcntl argument 3 is too long")
        return _sys_fcntl(fd, _int_arg(cmd), bytes(arg))
    return _sys_fcntl(fd, _int_arg(cmd), _int_arg(arg))


def ioctl(fd, request, arg=0, mutate_flag=True, /):
    """Perform the operation `request` on file descriptor `fd`."""
    fd = _fd(fd)
    if isinstance(arg, str):
        arg = arg.encode()
    if isinstance(arg, bytearray) and mutate_flag:
        var r = _sys_ioctl(fd, _int_arg(request), bytes(arg))
        arg[:] = r[1]
        return r[0]
    if isinstance(arg, (bytes, bytearray)):
        if len(arg) > 1024:
            raise ValueError("ioctl string arg too long")
        return _sys_ioctl(fd, _int_arg(request), bytes(arg))[1]
    return _sys_ioctl(fd, _int_arg(request), _int_arg(arg))


def flock(fd, operation, /):
    """Perform the lock operation `operation` on file descriptor `fd`."""
    _sys_flock(_fd(fd), _int_arg(operation))


def lockf(fd, cmd, len=0, start=0, whence=0, /):
    """A wrapper around the fcntl() locking calls."""
    _sys_lockf(_fd(fd), _int_arg(cmd), _int_arg(len), _int_arg(start), _int_arg(whence))
