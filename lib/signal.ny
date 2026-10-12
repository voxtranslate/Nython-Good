# nython: module    (import it by name: it runs in a module scope of its own)
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
    var r = _sig_setitimer(which, seconds, interval)
    return (r[0], r[1])

def getitimer(which):
    var r = _sig_getitimer(which)
    return (r[0], r[1])

def strsignal(signalnum):
    return _sig_strsignal(signalnum)

def valid_signals():
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
