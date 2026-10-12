# vm_audit66.ny - OS signals, both engines (round 77).
#
#   handlers        signal.signal / getsignal / SIG_IGN / SIG_DFL, the
#                   handler runs on the main thread with the signal number,
#                   before raise_signal returns, and when another thread
#                   sends the signal
#   Ctrl+C          SIGINT raises KeyboardInterrupt (not an Exception); a
#                   real SIGINT ends a busy loop, a sleep, a lock wait and an
#                   input() through KeyboardInterrupt, finally blocks run, and
#                   an uncaught one exits with status 130 (POSIX)
#   resuming        a sleep a signal interrupts resumes with the time it had
#                   left once the handler returns (PEP 475)
#   channels        signal.notify(ch, sig): signals arrive as channel
#                   messages, select-able with others (Go's signal.Notify)
#   async           a handler runs while an event loop is idle; a raising one
#                   ends async_run, whose tasks are cancelled (finally ran)
#   errors          Python's ValueError/TypeError for bad numbers and handlers
#
# Must pass on both engines:
#     ./build/nython-cli examples/vm_audit66.ny
#     ./build/nython-cli --vm examples/vm_audit66.ny

import signal
import os
import sys
import "lib/thread.ny"

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if repr(got) == repr(want):
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + repr(got) + " want " + repr(want))

def err(f):
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

var posix = sys.platform != "win32"
var exe = sys.executable
# The child processes below run on the engine this file runs on.
var flags = []
if gc_stats()["engine"] == "vm":
    flags = ["--vm"]

# ── handlers ─────────────────────────────────────────────────────────────
var got = []
def on_term(signum, frame):
    got.append(signum)
var old = signal.signal(signal.SIGTERM, on_term)
check("first handler was SIG_DFL", old, signal.SIG_DFL)
signal.raise_signal(signal.SIGTERM)
check("handler ran before raise_signal returned", got, [signal.SIGTERM])
check("getsignal gives the handler", signal.getsignal(signal.SIGTERM) == on_term, true)
check("SIGINT's handler is default_int_handler", signal.getsignal(signal.SIGINT) == signal.default_int_handler, true)
check("signal returns the previous one", signal.signal(signal.SIGTERM, signal.SIG_IGN) == on_term, true)
signal.raise_signal(signal.SIGTERM)
check("SIG_IGN ignores it", got, [signal.SIGTERM])
signal.signal(signal.SIGTERM, on_term)

def raising(signum, frame):
    raise ValueError("from the handler " + str(signum))
signal.signal(signal.SIGTERM, raising)
check("a handler's exception comes out of the call", err(lambda: signal.raise_signal(signal.SIGTERM)), "ValueError: from the handler " + str(signal.SIGTERM))
signal.signal(signal.SIGTERM, signal.SIG_DFL)

# ── KeyboardInterrupt ────────────────────────────────────────────────────
var kb = "none"
try:
    signal.raise_signal(signal.SIGINT)
except Exception:
    kb = "caught as Exception"
except KeyboardInterrupt:
    kb = "KeyboardInterrupt"
check("SIGINT raises KeyboardInterrupt, not an Exception", kb, "KeyboardInterrupt")
check("KeyboardInterrupt is a BaseException", issubclass(KeyboardInterrupt, BaseException), true)
var dk = "none"
try:
    signal.default_int_handler(signal.SIGINT, none)
except KeyboardInterrupt:
    dk = "raised"
check("default_int_handler raises KeyboardInterrupt", dk, "raised")

# ── errors ───────────────────────────────────────────────────────────────
check("bad signal number", err(lambda: signal.signal(0, signal.SIG_IGN)), "ValueError: signal number out of range")
check("bad handler", err(lambda: signal.signal(signal.SIGTERM, 5)), "TypeError: signal handler must be signal.SIG_IGN, signal.SIG_DFL, or a callable object")
var thread_err = []
def set_in_thread():
    thread_err.append(err(lambda: signal.signal(signal.SIGTERM, signal.SIG_IGN)))
var te = Thread(set_in_thread)
te.start()
te.join()
check("only the main thread sets handlers", thread_err, ["ValueError: signal only works in main thread of the main interpreter"])
check("strsignal", signal.strsignal(signal.SIGINT), "Interrupt")
check("valid_signals", signal.SIGINT in signal.valid_signals(), true)

if posix:
    # ── another thread's signal is handled on the main thread ─────────────
    var where = []
    signal.signal(signal.SIGUSR1, lambda s, f: where.append([s, thread_id() == thread_main()]))
    def kill_from_thread():
        os.kill(os.getpid(), signal.SIGUSR1)
    var tk = Thread(kill_from_thread)
    tk.start()
    tk.join()
    var spin = 0
    while spin < 200:
        spin = spin + 1
    check("handled on the main thread", where, [[signal.SIGUSR1, true]])

    # ── a sleep resumes after the handler (PEP 475) ──────────────────────
    var alarms = []
    signal.signal(signal.SIGALRM, lambda s, f: alarms.append(s))
    signal.setitimer(signal.ITIMER_REAL, 0.15)
    var t0 = time_ms()
    sleep(0.5)
    var took = time_ms() - t0
    check("the handler ran during the sleep", alarms, [signal.SIGALRM])
    check("the sleep took its whole time, not more (" + str(took) + " ms)", took >= 480 and took < 900, true)
    check("alarm returns the previous count", signal.alarm(0), 0)
    check("getitimer after", signal.getitimer(signal.ITIMER_REAL)[0], 0.0)

    # ── a wait on the main thread runs a handler and goes on waiting ─────
    var ev = ThreadEvent()
    var hits = []
    signal.signal(signal.SIGUSR2, lambda s, f: hits.append(s))
    def poke_then_set():
        sleep(0.1)
        os.kill(os.getpid(), signal.SIGUSR2)
        sleep(0.1)
        ev.set()
    var tp = Thread(poke_then_set)
    tp.start()
    var waited = ev.wait()
    tp.join()
    check("a handler ran inside event.wait, which then saw the event", [hits, waited], [[signal.SIGUSR2], true])

    # ── signal channels ──────────────────────────────────────────────────
    var ch = Channel(4)
    signal.notify(ch, signal.SIGUSR1, signal.SIGHUP)
    def send_two():
        sleep(0.05)
        os.kill(os.getpid(), signal.SIGHUP)
        sleep(0.05)
        os.kill(os.getpid(), signal.SIGUSR1)
    var tc = Thread(send_two)
    tc.start()
    var first = ch.recv(5)
    var second = ch.recv(5)
    tc.join()
    check("signals arrive on the channel in order", [first, second], [signal.SIGHUP, signal.SIGUSR1])
    var other = Channel(1)
    def later():
        sleep(0.05)
        os.kill(os.getpid(), signal.SIGHUP)
    var tl = Thread(later)
    tl.start()
    var sel = select([["recv", other], ["recv", ch]], 5)
    tl.join()
    check("select sees a signal like a message", [sel[0], sel[1]], [1, signal.SIGHUP])
    signal.stop(ch)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.raise_signal(signal.SIGHUP)
    check("stop unsubscribes", ch.recv(0.05), none)

    # ── async: a handler while the loop waits; a raising one ends it ─────
    var ticks = []
    signal.signal(signal.SIGUSR1, lambda s, f: ticks.append(s))
    var cleaned = []
    async def sleeper(tag):
        try:
            await async_sleep(5)
        finally:
            cleaned.append(tag)
    async def main_task():
        var a = create_task(sleeper("a"))
        var b = create_task(sleeper("b"))
        await async_sleep(0.05)
        signal.raise_signal(signal.SIGUSR1)
        await async_sleep(0.05)
        signal.raise_signal(signal.SIGINT)
        await async_sleep(5)
        return "not reached"
    var outcome = "none"
    try:
        outcome = async_run(main_task())
    except KeyboardInterrupt:
        outcome = "KeyboardInterrupt"
    check("a handler ran inside the event loop", ticks, [signal.SIGUSR1])
    check("Ctrl+C ends async_run", outcome, "KeyboardInterrupt")
    check("its tasks were cancelled, finally blocks ran", sorted(cleaned), ["a", "b"])

    # ── a real SIGINT: busy loop, sleep, input; exit status 130 ──────────
    if os_exists(exe):
        var base = os_path_join(os_gettempdir(), "ny_audit66_" + str(os_getpid()))
        # SIGINT to the child once it is waiting; stdin a pipe that stays open
        # (a shell pipeline), for input(). Each child writes READY just inside its try block, before it blocks;
        # the signal is sent once that file exists (round 81: a fixed 0.6 s
        # raced a loaded machine - a child still importing lib/thread.ny got
        # the SIGINT before its try and the interrupt went uncaught).
        var ready_path = base + "_ready"
        def child(src, piped):
            var path = base + "_child.ny"
            if os_exists(ready_path):
                os_remove(ready_path)
            write_file(path, string_replace(src, "@READY@", "write_file(" + repr(ready_path) + ", \"1\")"))
            var p
            if piped:
                var cmd = "sleep 5 | " + shell_quote(exe)
                for f in flags:
                    cmd = cmd + " " + f
                p = os_spawn(cmd + " " + shell_quote(path))
            else:
                p = os_spawn([exe] + flags + [path])
            var waited = 0.0
            while not os_exists(ready_path) and waited < 30.0:
                sleep(0.05)
                waited = waited + 0.05
            sleep(0.3)   # into the wait itself
            os_kill(p, signal.SIGINT)
            var code = os_wait(p, timeout=10)
            var out = os_proc_read(p)
            os_remove(path)
            if os_exists(ready_path):
                os_remove(ready_path)
            return {"returncode": code, "stdout": out["stdout"], "stderr": out["stderr"]}
        var r1 = child("try:\n    @READY@\n    var n = 0\n    while true:\n        n = n + 1\nfinally:\n    print(\"finally ran\")\n", false)
        check("busy loop: finally ran", string_strip(r1["stdout"]), "finally ran")
        check("busy loop: KeyboardInterrupt reported", string_find(r1["stderr"], "KeyboardInterrupt") >= 0, true)
        check("busy loop: exit status 130", r1["returncode"], 130)
        var r2 = child("try:\n    @READY@\n    sleep(30)\nexcept KeyboardInterrupt:\n    print(\"sleep interrupted\")\n", false)
        check("sleep interrupted", string_strip(r2["stdout"]), "sleep interrupted")
        var r3 = child("try:\n    @READY@\n    input()\nexcept KeyboardInterrupt:\n    print(\"input interrupted\")\n", true)
        check("input interrupted", string_strip(r3["stdout"]), "input interrupted")
        var r4 = child("import \"lib/thread.ny\"\nvar l = Lock()\nvar ready = ThreadEvent()\ndef holder():\n    l.acquire()\n    ready.set()\n    sleep(20)\nvar t = Thread(holder, daemon=true)\nt.start()\nready.wait()\ntry:\n    @READY@\n    l.acquire()\nexcept KeyboardInterrupt:\n    print(\"lock wait interrupted\")\n", false)
        check("lock wait interrupted", string_strip(r4["stdout"]), "lock wait interrupted")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT66 PASSED ===")
