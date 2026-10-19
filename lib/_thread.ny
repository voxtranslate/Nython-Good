# nython: module
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# _thread - Python's low-level threading module (round 82), over the
# runtime lib/threading.ny uses (src/NyConc.cpp: OS threads under one GIL).
#
#   start_new_thread(function, args[, kwargs]) -> ident (start_new),
#   allocate_lock() / LockType (allocate), RLock, get_ident, get_native_id,
#   interrupt_main(signum=SIGINT), exit() / exit_thread(), stack_size,
#   TIMEOUT_MAX, error (RuntimeError), _count(), _local,
#   daemon_threads_allowed(), _excepthook, _ExceptHookArgs.
#
# As in CPython, a thread started here is not waited for at exit, and an
# exception escaping its function is reported ("Exception ignored in
# thread started by: ...") without stopping the program; SystemExit ends
# the thread quietly.

import threading as _threading

error = RuntimeError
TIMEOUT_MAX = _threading.TIMEOUT_MAX
LockType = _threading.Lock
lock = _threading.Lock
RLock = _threading.RLock
_local = _threading.local
_excepthook = _threading.excepthook
_ExceptHookArgs = _threading._ExceptHookArgs

def allocate_lock():
    return _threading.Lock()

allocate = allocate_lock

def get_ident():
    return _threading.get_ident()

def get_native_id():
    return _threading.get_native_id()

def _report(function, e):
    eprint("Exception ignored in thread started by: " + repr(function))
    try:
        import traceback
        traceback.print_exception(type(e), e, e.__traceback__)
    except BaseException:
        eprint(type(e).__name__ + ": " + str(e))

def start_new_thread(function, args, kwargs=None):
    if not isinstance(args, tuple):
        raise TypeError("2nd arg must be a tuple")
    if kwargs is not None and not isinstance(kwargs, dict):
        raise TypeError("optional 3rd arg must be a dictionary")
    if not callable(function):
        raise TypeError("first arg must be callable")
    _ny_sys_audit("_thread.start_new_thread", function, args, kwargs)   # round 86: CPython 3.12's event
    var kw = kwargs if kwargs is not None else {}
    def boot():
        try:
            function(*args, **kw)
        except SystemExit:
            pass
        except BaseException as e:
            _report(function, e)
    var ident = thread_create(boot)
    thread_set_daemon(ident, True)
    return ident

start_new = start_new_thread

def exit():
    raise SystemExit()

exit_thread = exit

def interrupt_main(signum=None):
    # the effect of the signal arriving in the main thread: its Python
    # handler runs there (SIGINT's default one raises KeyboardInterrupt);
    # nothing happens while the signal is ignored or left to the system
    import signal as _signal
    if signum is None:
        signum = _signal.SIGINT
    var h = _signal.getsignal(signum)
    if h is None or h == _signal.SIG_DFL or h == _signal.SIG_IGN:
        return
    _signal.raise_signal(signum)

def stack_size(size=0):
    if not isinstance(size, int):
        raise TypeError("'" + type(size).__name__ + "' object cannot be interpreted as an integer")
    if size != 0 and size < 32768:
        raise ValueError("size not valid: " + str(size) + " bytes")
    return 0

def _count():
    var n = thread_count() - 1
    return n if n > 0 else 0

def daemon_threads_allowed():
    return True
