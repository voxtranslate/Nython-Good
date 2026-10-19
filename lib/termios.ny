# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/termios.ny - Python's termios module (round 83): POSIX terminal
# control. POSIX only: on Windows `import termios` raises
# ModuleNotFoundError, as CPython's does.
#
#     import termios, sys
#     attrs = termios.tcgetattr(fd)    # [iflag, oflag, cflag, lflag, ispeed, ospeed, cc]
#     attrs[3] &= ~termios.ECHO
#     termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
#
# tcgetattr(fd)        the attributes list; cc is a list of 1-byte bytes, with
#                      cc[VMIN] and cc[VTIME] ints in non-canonical mode
# tcsetattr(fd, when, attributes)   TCSANOW / TCSADRAIN / TCSAFLUSH
# tcsendbreak(fd, duration), tcdrain(fd), tcflush(fd, queue), tcflow(fd, action)
# tcgetwinsize(fd) -> (rows, cols), tcsetwinsize(fd, winsize)   (3.11)
# error                the exception (args: errno, message), not an OSError
# The constants (B*, TCSA*, TC*, the flag bits, V*, NCCS, TIOC*, FIO*, ...)
# are the platform's own, generated natively from <termios.h>.
#
# Not here: nothing of CPython's 3.12 module.

if not _sys_platform_posix():
    raise ModuleNotFoundError("No module named 'termios'", name="termios")


def _load():
    var g = globals()
    for pair in _sys_consts("termios"):
        g[pair[0]] = pair[1]


_load()
del _load


class error(Exception):
    pass


error.__module__ = "termios"


def _fd(fd):
    if not isinstance(fd, int):
        var meth = getattr(fd, "fileno", None)
        if meth is None:
            raise TypeError("argument must be an int, or have a fileno() method.")
        fd = meth()
    if fd < 0:
        raise ValueError("file descriptor cannot be a negative integer (" + str(fd) + ")")
    return fd


def _call(f, *args):
    try:
        return f(*args)
    except OSError as e:
        raise error(e.errno, e.strerror) from None


def tcgetattr(fd, /):
    """Get the tty attributes for file descriptor fd."""
    return _call(_sys_tcgetattr, _fd(fd))


def tcsetattr(fd, when, attributes, /):
    """Set the tty attributes for file descriptor fd."""
    if not isinstance(attributes, list) or len(attributes) != 7:
        raise TypeError("tcsetattr, arg 3: must be 7 element list")
    _call(_sys_tcsetattr, _fd(fd), when, attributes)


def tcsendbreak(fd, duration, /):
    """Send a break on file descriptor fd."""
    _call(_sys_tcsendbreak, _fd(fd), duration)


def tcdrain(fd, /):
    """Wait until all output written to file descriptor fd has been transmitted."""
    _call(_sys_tcdrain, _fd(fd))


def tcflush(fd, queue, /):
    """Discard queued data on file descriptor fd."""
    _call(_sys_tcflush, _fd(fd), queue)


def tcflow(fd, action, /):
    """Suspend or resume input or output on file descriptor fd."""
    _call(_sys_tcflow, _fd(fd), action)


def tcgetwinsize(fd, /):
    """Get the tty winsize for file descriptor fd."""
    return tuple(_call(_sys_tcgetwinsize, _fd(fd)))


def tcsetwinsize(fd, winsize, /):
    """Set the tty winsize for file descriptor fd."""
    var w = None
    try:
        w = list(winsize)
    except TypeError:
        raise TypeError("tcsetwinsize, arg 2: must be a two-item sequence") from None
    if len(w) != 2:
        raise TypeError("tcsetwinsize, arg 2: must be a two-item sequence")
    _call(_sys_tcsetwinsize, _fd(fd), w[0], w[1])
