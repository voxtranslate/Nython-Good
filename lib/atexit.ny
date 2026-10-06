# nython: module    (import it by name: it runs in a module scope of its own)
# lib/atexit.ny - Python's atexit: functions called when the program ends.
#
#     import atexit
#     @atexit.register
#     def goodbye():
#         print("bye")
#
# register(func, *args, **kwargs)   func(*args, **kwargs) at exit; returns
#                           func (so it works as a decorator)
# unregister(func)          removes every registration of func (compared
#                           with ==); nothing if it was not registered
# _run_exitfuncs()          runs (and clears) the handlers now
# _clear()                  forgets every handler
# _ncallbacks()             how many are registered
#
# The handlers run last registered first when the program ends - normally,
# through sys.exit() / SystemExit, or with an uncaught exception (after its
# traceback is printed and the program's threads have finished), on both
# engines; not when the process is killed by a signal or os._exit() is
# called. One that raises is reported on stderr ("Exception ignored in
# atexit callback: ...", with its traceback) and the rest still run; a
# SystemExit raised by one is ignored. The list lives in the prelude
# (_ny_atexit_handlers, run by _ny_run_atexit), which the engines call.
#
# Not here: a handler registered while the handlers run is run as well (in
# CPython it is too, from 3.12 on).

__all__ = ["register", "unregister"]


def register(func, *args, **kwargs):
    """Register a function to be executed upon normal program termination.

    func is returned to facilitate usage as a decorator."""
    if not callable(func):
        raise TypeError("the first argument must be callable")
    _ny_atexit_handlers.append((func, args, kwargs))
    return func


def unregister(func):
    """Unregister an exit function which was previously registered using
    atexit.register"""
    var keep = []
    for h in _ny_atexit_handlers:
        if not (h[0] == func):
            keep.append(h)
    _ny_atexit_handlers[:] = keep


def _run_exitfuncs():
    """Run all registered exit functions."""
    _ny_run_atexit()


def _clear():
    """Clear the list of previously registered exit functions."""
    _ny_atexit_handlers[:] = []


def _ncallbacks():
    """Return the number of registered exit functions."""
    return len(_ny_atexit_handlers)
