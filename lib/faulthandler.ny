# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/faulthandler.ny - Python's faulthandler module (round 83): dump the
# Python stacks on a fault, after a timeout, or on a user signal.
#
#     import faulthandler
#     faulthandler.enable()                        # SIGSEGV, SIGFPE, SIGABRT, SIGBUS, SIGILL
#     faulthandler.dump_traceback(all_threads=False)
#     faulthandler.dump_traceback_later(30, exit=True)    # a watchdog
#     faulthandler.register(signal.SIGUSR1)                # kill -USR1 <pid> dumps the stacks
#
# enable(file=sys.stderr, all_threads=True), disable(), is_enabled(),
# dump_traceback(file=sys.stderr, all_threads=True),
# dump_traceback_later(timeout, repeat=False, file=sys.stderr, exit=False),
# cancel_dump_traceback_later(), register(signum, file=sys.stderr,
# all_threads=True, chain=False) and unregister(signum) (POSIX). `file` is a
# file object with fileno() or a file descriptor. `python -X faulthandler`
# is PYTHONFAULTHANDLER here: set in the environment, the handlers are on
# from the import of this module.
#
# The dump is builtins/nyfault.cpp's: written with write(2) only, reading the
# engines' own frame records (the interpreter's frames and the VM's
# CallFrames, each thread's live or parked ones), so it works from inside a
# signal handler; the fatal handlers run on an alternate signal stack, put
# the previous handler back and raise the signal again. The text is
# CPython's:
#     Fatal Python error: Segmentation fault
#
#     Current thread 0x0000000000000001 (most recent call first):
#       File "crash.py", line 3 in f
#       File "crash.py", line 5 in <module>
# A thread's number is its threading.get_ident().
#
# Not here: the C-level stack (CPython 3.13's c_stack), the "Extension
# modules:" line (Nython has none), Windows' structured exceptions (only the
# C signals are caught there).
import sys as _sys
import os as _os

_file_ref = {}


def _fd(file):
    if isinstance(file, int) and not isinstance(file, bool):
        if file < 0:
            raise ValueError("file is not a valid file descriptor")
        return file
    if file is None:
        file = getattr(_sys, "stderr", None)
        if file is None:
            raise RuntimeError("sys.stderr is None")
    var fileno = getattr(file, "fileno", None)
    if fileno is None:
        raise AttributeError("'" + type(file).__name__ + "' object has no attribute 'fileno'")
    var fd = fileno()
    if not isinstance(fd, int) or fd < 0:
        raise RuntimeError("file.fileno() is not a valid file descriptor")
    var flush = getattr(file, "flush", None)
    if flush is not None:
        try:
            flush()
        except Exception:
            pass
    return fd


def _ident():
    try:
        return thread_os_id()
    except Exception:
        return 0


def enable(file=None, all_threads=True):
    """Enable the fault handler."""
    var fd = _fd(file)
    _file_ref["fatal"] = file
    _fault_enable(fd, bool(all_threads), _ident())


def disable():
    """Disable the fault handler."""
    _file_ref.pop("fatal", None)
    return _fault_disable()


def is_enabled():
    """Check if the handler is enabled."""
    return _fault_is_enabled()


def dump_traceback(file=None, all_threads=True):
    """Dump the traceback of the current thread, or of all threads if all_threads is True, into file."""
    _fault_dump(_fd(file), bool(all_threads), _ident())


def dump_traceback_later(timeout, repeat=False, file=None, exit=False):
    """Dump the traceback of all threads in timeout seconds,
    or each timeout seconds if repeat is True. If exit is True, call _exit(1) which is not safe."""
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        raise TypeError("timeout must be a number")
    if timeout <= 0:
        raise ValueError("timeout must be greater than 0")
    if timeout > 1e15:
        raise OverflowError("timeout value is too large")
    var fd = _fd(file)
    _file_ref["later"] = file
    _fault_later(float(timeout), bool(repeat), fd, bool(exit), _ident())


def cancel_dump_traceback_later():
    """Cancel the previous call to dump_traceback_later()."""
    _fault_cancel_later()
    _file_ref.pop("later", None)


if _sys.platform != "win32":
    def register(signum, file=None, all_threads=True, chain=False):
        """Register a handler for the signal 'signum': dump the traceback of the current
        thread, or of all threads if all_threads is True, into file."""
        var fd = _fd(file)
        _file_ref["user" + str(signum)] = file
        _fault_register(int(signum), fd, bool(all_threads), bool(chain), _ident())

    def unregister(signum):
        """Unregister the handler of the signal 'signum' registered by register()."""
        _file_ref.pop("user" + str(signum), None)
        return _fault_unregister(int(signum))


# CPython's test helpers (faulthandler._sigsegv() ...): crash on purpose
def _sigsegv(release_gil=False):
    _fault_crash("segv")


def _sigabrt():
    _fault_crash("abrt")


def _sigfpe():
    _fault_crash("fpe")


def _read_null():
    _fault_crash("read_null")


if _os.environ.get("PYTHONFAULTHANDLER") or _os.environ.get("NYTHONFAULTHANDLER"):
    try:
        enable()
    except Exception:
        pass
