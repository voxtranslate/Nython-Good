# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/syslog.ny - Python's syslog module (round 83): the Unix system
# logger. POSIX only: on Windows `import syslog` raises ModuleNotFoundError,
# as CPython's does.
#
#     import syslog
#     syslog.openlog("myapp", syslog.LOG_PID, syslog.LOG_DAEMON)
#     syslog.syslog(syslog.LOG_WARNING, "disk almost full")
#     syslog.syslog("an info message")
#     old = syslog.setlogmask(syslog.LOG_UPTO(syslog.LOG_NOTICE))
#
# openlog(ident=None, logoption=0, facility=LOG_USER); syslog([priority,]
# message) (opens the log first, ident the basename of sys.argv[0], as
# CPython 3.12 does); closelog(); setlogmask(maskpri) -> the old mask;
# LOG_MASK(pri), LOG_UPTO(pri); the LOG_* priorities, facilities and options
# of the platform (<syslog.h>, natively).
#
# The sys.audit events CPython raises (round 86): syslog.openlog (ident,
# logoption, facility), syslog.syslog (priority, message), syslog.setlogmask
# (maskpri), syslog.closelog ().

if not _sys_platform_posix():
    raise ModuleNotFoundError("No module named 'syslog'", name="syslog")

import sys as _sys


def _load():
    var g = globals()
    for pair in _sys_consts("syslog"):
        g[pair[0]] = pair[1]


_load()
del _load

_opened = False


def openlog(ident=None, logoption=0, facility=LOG_USER):
    """Set logging options of subsequent syslog() calls."""
    global _opened
    if ident is not None and not isinstance(ident, str):
        raise TypeError("openlog() argument 'ident' must be str or None, not " + type(ident).__name__)
    if ident is None:
        var argv = getattr(_sys, "argv", None)
        if argv and isinstance(argv[0], str) and argv[0]:
            ident = argv[0].replace("\\", "/").rsplit("/", 1)[-1]
    _ny_sys_audit("syslog.openlog", ident, logoption, facility)
    _sys_openlog(ident, logoption, facility)
    _opened = True


def syslog(*args):
    """syslog([priority=LOG_INFO,] message)
    Send the string message to the system logger."""
    var priority = LOG_INFO
    var message = None
    if len(args) == 1:
        message = args[0]
    elif len(args) == 2:
        priority = args[0]
        message = args[1]
    else:
        raise TypeError("syslog.syslog requires 1 to 2 arguments")
    if not isinstance(priority, int):
        raise TypeError("'" + type(priority).__name__ + "' object cannot be interpreted as an integer")
    if not isinstance(message, str):
        raise TypeError("syslog() argument must be str, not " + type(message).__name__)
    _ny_sys_audit("syslog.syslog", priority, message)
    if not _opened:
        openlog()
    _sys_syslog(priority, message)


def closelog():
    """Reset the syslog module values and call the system library closelog()."""
    global _opened
    _ny_sys_audit("syslog.closelog")
    if _opened:
        _sys_closelog()
        _opened = False


def setlogmask(maskpri, /):
    """Set the priority mask to maskpri and return the previous mask value."""
    _ny_sys_audit("syslog.setlogmask", maskpri)
    return _sys_setlogmask(maskpri)


def LOG_MASK(pri, /):
    """Calculates the mask for the individual priority pri."""
    return 1 << pri


def LOG_UPTO(pri, /):
    """Calculates the mask for all priorities up to and including pri."""
    return (1 << (pri + 1)) - 1
