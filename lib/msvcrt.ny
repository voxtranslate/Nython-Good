# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/msvcrt.ny - Python's msvcrt module (round 87): the Windows C runtime's
# console I/O, file locking, descriptor modes and OS handles, over the natives
# in src/builtins/nywin.cpp. Windows only: elsewhere `import msvcrt` raises
# ModuleNotFoundError, as CPython's.
#
#     import msvcrt
#     msvcrt.setmode(fd, os.O_BINARY)          -> the previous mode
#     msvcrt.locking(fd, msvcrt.LK_NBLCK, 10)  # OSError when held elsewhere
#     h = msvcrt.get_osfhandle(fd); fd2 = msvcrt.open_osfhandle(h, os.O_RDONLY)
#     if msvcrt.kbhit(): ch = msvcrt.getwch()
#
# locking, setmode, open_osfhandle, get_osfhandle, kbhit, getch, getwch,
# getche, getwche, putch, putwch, ungetch, ungetwch, heapmin, GetErrorMode,
# SetErrorMode; LK_* and SEM_* constants, O_BINARY/O_TEXT/O_WTEXT/O_U8TEXT/
# O_U16TEXT (Nython's addition: CPython keeps them in os); the
# msvcrt.locking / open_osfhandle / get_osfhandle audit events.
#
# Not here: CrtSetReportFile / CrtSetReportMode / CRT_ASSEMBLY_VERSION, which
# only CPython's debug builds have (the MinGW runtime has no debug CRT).

import sys

if sys.platform != "win32":
    raise ModuleNotFoundError("No module named 'msvcrt'", name="msvcrt")

_BITS = 64 if sys.maxsize > 2 ** 32 else 32


def _u(h):
    # a handle as CPython shows it: unsigned
    return h & ((1 << _BITS) - 1)


def _s(h):
    h = int(h)
    if h >= 1 << (_BITS - 1):
        h -= 1 << _BITS
    return h


def _load():
    g = globals()
    for name, value in _msvcrt_consts():
        g[name] = value


_load()


def locking(fd, mode, nbytes, /):
    """Lock part of a file based on file descriptor fd from the C runtime."""
    sys.audit("msvcrt.locking", fd, mode, nbytes)
    _msvcrt_locking(fd, mode, nbytes)


def setmode(fd, mode, /):
    """Set the line-end translation mode for the file descriptor fd."""
    return _msvcrt_setmode(fd, mode)


def open_osfhandle(handle, flags, /):
    """Create a C runtime file descriptor from the file handle handle."""
    sys.audit("msvcrt.open_osfhandle", handle, flags)
    return _msvcrt_open_osfhandle(_s(handle), flags)


def get_osfhandle(fd, /):
    """Return the file handle for the file descriptor fd."""
    sys.audit("msvcrt.get_osfhandle", fd)
    return _u(_msvcrt_get_osfhandle(fd))


def kbhit():
    """Returns a nonzero value if a keypress is waiting to be read. Otherwise, return 0."""
    return _msvcrt_kbhit()


def getch():
    """Read a keypress and return the resulting character as a byte string."""
    return _msvcrt_getch("getch")


def getwch():
    """Wide char variant of getch(), returning a Unicode value."""
    return _msvcrt_getch("getwch")


def getche():
    """Similar to getch(), but the keypress will be echoed if possible."""
    return _msvcrt_getch("getche")


def getwche():
    """Wide char variant of getche(), returning a Unicode value."""
    return _msvcrt_getch("getwche")


def _byte(name, char):
    if not isinstance(char, (bytes, bytearray)) or len(char) != 1:
        if isinstance(char, (bytes, bytearray)):
            raise TypeError("%s(): argument must be a byte string of length 1, not a bytes object of length %d"
                            % (name, len(char)))
        raise TypeError("%s(): argument must be a byte string of length 1, not %s" % (name, type(char).__name__))
    return bytes(char)


def _wchar(name, char):
    if not isinstance(char, str) or len(char) != 1:
        if isinstance(char, str):
            raise TypeError("%s(): argument must be a unicode character, not a string of length %d" % (name, len(char)))
        raise TypeError("%s(): argument must be a unicode character, not %s" % (name, type(char).__name__))
    return char


def putch(char, /):
    """Print the byte string char to the console without buffering."""
    _msvcrt_putch("putch", _byte("putch", char))


def putwch(unicode_char, /):
    """Wide char variant of putch(), accepting a Unicode value."""
    _msvcrt_putch("putwch", _wchar("putwch", unicode_char))


def ungetch(char, /):
    """Opposite of getch: the byte string char is pushed back to the console buffer."""
    _msvcrt_putch("ungetch", _byte("ungetch", char))


def ungetwch(unicode_char, /):
    """Wide char variant of ungetch(), accepting a Unicode value."""
    _msvcrt_putch("ungetwch", _wchar("ungetwch", unicode_char))


def heapmin():
    """Minimize the malloc() heap."""
    _msvcrt_heapmin()


def GetErrorMode():
    """Wrapper around GetErrorMode."""
    return _msvcrt_errormode()


def SetErrorMode(mode, /):
    """Wrapper around SetErrorMode."""
    return _msvcrt_errormode(mode)
