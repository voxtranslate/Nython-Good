# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/signal.ny - Python's signal module over the runtime's signal layer
# (src/NyConc.cpp, section 9; round 77). `import signal`.
#
# Handlers run on the main thread, at the next statement after the signal
# arrives, or inside the blocking call the main thread was in (sleep, a lock,
# a queue, a socket), which then resumes with the time it had left. SIGINT's
# default handler raises KeyboardInterrupt (Ctrl+C), as in Python.
#
#   signal(sig, handler)      handler: a callable (signum, frame), SIG_DFL,
#                             SIG_IGN or default_int_handler; returns the old one
#   getsignal(sig)            the handler installed for sig
#   raise_signal(sig)         send sig to this process; its handler runs before
#                             raise_signal returns
#   alarm(sec), setitimer(which, sec, interval=0), getitimer(which), pause()
#                             (POSIX only, as in Python)
#   strsignal(sig), valid_signals()
#   notify(ch, *sigs)         also deliver sigs to channel ch (a thread.Channel
#                             or a channel handle), never blocking: a thread, an
#                             async task or a select can wait for a signal like
#                             any other message (Go's signal.Notify). A SIGINT
#                             delivered to a channel does not raise
#                             KeyboardInterrupt.
#   stop(ch)                  undo notify for ch
#
# Round 85 (POSIX, as CPython's): set_wakeup_fd(fd, warn_on_full_buffer)
# (each signal's number is also written to fd as a byte - asyncio's
# self-pipe), siginterrupt(sig, flag) (SA_RESTART), pthread_kill,
# pthread_sigmask, sigpending, sigwait, sigwaitinfo / sigtimedwait (Linux;
# struct_siginfo), pidfd_send_signal (Linux), ItimerError, SIG_BLOCK /
# SIG_UNBLOCK / SIG_SETMASK, SIGRTMIN / SIGRTMAX and the platform's other
# names, and the Signals / Handlers / Sigmasks enums (made on first use: the
# module's SIGINT ... stay plain ints, equal to their members).
# Not here: set_wakeup_fd's warn_on_full_buffer=False is accepted, and a
# full pipe is never warned about.

SIG_DFL = 0
SIG_IGN = 1
NSIG = 65

def _const(name):
    for pair in _sig_constants():
        if pair[0] == name:
            return pair[1]
    return none

SIGINT = _const("SIGINT")
SIGTERM = _const("SIGTERM")
SIGABRT = _const("SIGABRT")
SIGFPE = _const("SIGFPE")
SIGILL = _const("SIGILL")
SIGSEGV = _const("SIGSEGV")
# POSIX only (none on Windows)
SIGHUP = _const("SIGHUP")
SIGQUIT = _const("SIGQUIT")
SIGTRAP = _const("SIGTRAP")
SIGKILL = _const("SIGKILL")
SIGBUS = _const("SIGBUS")
SIGUSR1 = _const("SIGUSR1")
SIGUSR2 = _const("SIGUSR2")
SIGPIPE = _const("SIGPIPE")
SIGALRM = _const("SIGALRM")
SIGCHLD = _const("SIGCHLD")
SIGCONT = _const("SIGCONT")
SIGSTOP = _const("SIGSTOP")
SIGTSTP = _const("SIGTSTP")
SIGTTIN = _const("SIGTTIN")
SIGTTOU = _const("SIGTTOU")
SIGURG = _const("SIGURG")
SIGXCPU = _const("SIGXCPU")
SIGXFSZ = _const("SIGXFSZ")
SIGVTALRM = _const("SIGVTALRM")
SIGPROF = _const("SIGPROF")
SIGWINCH = _const("SIGWINCH")
SIGIO = _const("SIGIO")
SIGSYS = _const("SIGSYS")
ITIMER_REAL = _const("ITIMER_REAL")
ITIMER_VIRTUAL = _const("ITIMER_VIRTUAL")
ITIMER_PROF = _const("ITIMER_PROF")
# Windows only (none elsewhere)
SIGBREAK = _const("SIGBREAK")
CTRL_C_EVENT = _const("CTRL_C_EVENT")
CTRL_BREAK_EVENT = _const("CTRL_BREAK_EVENT")

def default_int_handler(signum, frame):
    raise KeyboardInterrupt()

def _to_native(handler):
    if handler == default_int_handler:
        return "default_int_handler"
    return handler

def _from_native(h):
    if h == "default_int_handler":
        return default_int_handler
    return h

def signal(signalnum, handler):
    return _from_native(_sig_signal(signalnum, _to_native(handler)))

def getsignal(signalnum):
    return _from_native(_sig_getsignal(signalnum))

def raise_signal(signalnum):
    _sig_raise(signalnum)

def alarm(seconds):
    return _sig_alarm(seconds)

def pause():
    _sig_pause()

def setitimer(which, seconds, interval=0.0):
    var r = None
    try:
        r = _sig_setitimer(which, seconds, interval)
    except OSError as e:
        raise ItimerError(*e.args)   # (round 85) CPython's ItimerError
    return (r[0], r[1])

def getitimer(which):
    var r = None
    try:
        r = _sig_getitimer(which)
    except OSError as e:
        raise ItimerError(*e.args)
    return (r[0], r[1])

def strsignal(signalnum):
    return _sig_strsignal(signalnum)

def valid_signals():
    if _sys_platform_posix():
        # (round 85) CPython's: the members of sigfillset's set (glibc
        # keeps two real-time signals for itself), Signals where they are one
        return _to_signals(_ny_os_call("valid_signals"))
    return set(_sig_valid())

def _chan_id(ch):
    if isinstance(ch, "int"):
        return ch
    return ch.id

def notify(ch, *signals):
    for s in signals:
        _sig_notify(_chan_id(ch), s)

def stop(ch):
    _sig_stop(_chan_id(ch))

# ── round 85: the rest of CPython's signal module ────────────────────────
# set_wakeup_fd (the self-pipe asyncio's loop reads: every signal's number
# is written to it as a byte), siginterrupt, pthread_kill, pthread_sigmask,
# sigpending, sigwait, sigwaitinfo, sigtimedwait (struct_siginfo),
# pidfd_send_signal, ItimerError, SIG_BLOCK/SIG_UNBLOCK/SIG_SETMASK,
# SIGRTMIN/SIGRTMAX and the platform's other names (SIGCLD, SIGPOLL ...),
# and the Signals / Handlers / Sigmasks enums. POSIX only where CPython's are.

class itimer_error(OSError):
    # CPython's PyErr_NewException("signal.itimer_error", OSError)
    __module__ = "signal"
ItimerError = itimer_error
del itimer_error

def set_wakeup_fd(fd, *, warn_on_full_buffer=True):
    if isinstance(fd, bool) or not isinstance(fd, int):
        raise TypeError("'" + type(fd).__name__ + "' object cannot be interpreted as an integer")
    return _sig_set_wakeup_fd(fd, warn_on_full_buffer)

def _sigint(v):
    if isinstance(v, int):
        return int(v)
    if hasattr(type(v), "__index__"):
        return v.__index__()
    raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")

if _sys_platform_posix():
    def _load_more():
        var g = globals()
        for pair in _ny_os_call("signal_constants"):
            g[pair[0]] = pair[1]
    _load_more()
    del _load_more

    class struct_siginfo(_NyStructSeq):
        """struct_siginfo: Result from sigwaitinfo or sigtimedwait."""
        __module__ = "signal"
        _ny_qual = "signal.struct_siginfo"
        _ny_names = ("si_signo", "si_code", "si_errno", "si_pid", "si_uid", "si_status", "si_band")
        n_sequence_fields = 7
        n_fields = 7
        n_unnamed_fields = 0

    def _sigset(s, what):
        # (Nython iterates an int as a range: not here)
        if isinstance(s, (int, float)) or not hasattr(type(s), "__iter__"):
            raise TypeError("'" + type(s).__name__ + "' object is not iterable")
        var out = []
        try:
            for x in s:
                out.append(_sigint(x))
        except TypeError:
            raise TypeError(what + " must be an iterable of signal numbers")
        return out

    def _to_signals(nums):
        # CPython's _int_to_enum: Signals members where there is one
        var sig_enum = _make_enums()["Signals"]
        var out = set()
        for n in nums:
            try:
                out.add(sig_enum(n))
            except ValueError:
                out.add(n)
        return out

    def siginterrupt(signalnum, flag):
        _sig_siginterrupt(_sigint(signalnum), bool(flag))

    def pthread_kill(thread_id, signalnum):
        _ny_sys_audit("signal.pthread_kill", thread_id, signalnum)
        _sig_pthread("kill", _sigint(thread_id), _sigint(signalnum))

    def pthread_sigmask(how, mask):
        return _to_signals(_ny_os_call("pthread_sigmask", _sigint(how), _sigset(mask, "mask")))

    def sigpending():
        return _to_signals(_ny_os_call("sigpending"))

    def sigwait(sigset):
        return _ny_os_call("sigwait", _sigset(sigset, "sigset"))

    if os_platform() == "linux":
        def sigwaitinfo(sigset):
            return struct_siginfo(tuple(_ny_os_call("sigwaitinfo", _sigset(sigset, "sigset"))))

        def sigtimedwait(sigset, timeout):
            if isinstance(timeout, str) or not (isinstance(timeout, (int, float)) or hasattr(timeout, "__float__")):
                raise TypeError("an integer or float is required, not " + type(timeout).__name__)
            if timeout < 0:
                raise ValueError("timeout must be non-negative")
            var r = _ny_os_call("sigtimedwait", _sigset(sigset, "sigset"), float(timeout))
            if r is None:
                return None
            return struct_siginfo(tuple(r))

        def pidfd_send_signal(pidfd, sig, siginfo=None, flags=0):
            if siginfo is not None:
                raise TypeError("siginfo must be None")
            _ny_os_call("pidfd_send_signal", _sigint(pidfd), _sigint(sig), None, _sigint(flags))

# the enums (CPython's _IntEnum._convert_): the signal numbers stay ints
# here (Signals(2) is SIGINT, signal.SIGINT == Signals.SIGINT), made the
# first time one is asked for - a program that never does pays no import
_enums = {}
def _make_enums():
    if _enums:
        return _enums
    import enum
    var g = globals()
    var sigs = {}
    var hand = {}
    var masks = {}
    for n in list(g):
        var v = g[n]
        if not isinstance(v, int) or isinstance(v, bool):
            continue
        if n.isupper() and ((n.startswith("SIG") and not n.startswith("SIG_")) or n.startswith("CTRL_")):
            sigs[n] = v
        elif n in ("SIG_DFL", "SIG_IGN"):
            hand[n] = v
        elif n in ("SIG_BLOCK", "SIG_UNBLOCK", "SIG_SETMASK"):
            masks[n] = v
    def order(d):
        return sorted(d.items(), key=lambda kv: (kv[1], kv[0]))
    _enums["Signals"] = enum.IntEnum("Signals", order(sigs), module="signal")
    _enums["Handlers"] = enum.IntEnum("Handlers", order(hand), module="signal")
    if masks:
        _enums["Sigmasks"] = enum.IntEnum("Sigmasks", order(masks), module="signal")
    return _enums

def __getattr__(name):
    if name == "Signals" or name == "Handlers" or (name == "Sigmasks" and _sys_platform_posix()):
        return _make_enums()[name]
    raise AttributeError("module 'signal' has no attribute '" + name + "'")

def __dir__():
    var names = list(globals())
    names.extend(["Signals", "Handlers"])
    if _sys_platform_posix():
        names.append("Sigmasks")
    return sorted(names)
