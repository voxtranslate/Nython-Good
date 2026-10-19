# vm_audit121.ny - CPython's audit events (PEP 578), raised everywhere CPython
# raises them, with its names and arguments (round 86).
#
# A child program installs a hook that records each event as (case, event,
# arguments reduced to stable values - the temporary directory as T, objects
# as their type's name) and runs one case per group of events: the builtins
# (id, breakpoint, input, compile, exec, import, open), code and function
# objects, the restricted attributes (object.__getattr__ / __setattr__ /
# __delattr__), sys (_getframe, settrace, addaudithook, set_asyncgen_hooks,
# unraisablehook, excepthook), time.sleep, _thread, array, marshal, mmap,
# gc, signal, resource, fcntl, syslog, sqlite3, pickle, pdb, pty, glob,
# pathlib, shutil, tempfile, os (system, the exec/spawn/fork family, kill,
# the file and directory calls, the environment, walk), subprocess, urllib,
# http.client, webbrowser, the mail and telnet clients, ctypes and socket;
# then a hook that raises aborts each call it is asked about. The expected
# records are CPython 3.12's; under a python3 both sides keep only the
# events tools/audit_events.json says that version raises (and on Nython
# the ones the table says Nython raises).
#
# Then: nothing is recorded before a hook exists, sys.audit's checks, the
# table itself, input()'s result on a terminal (a pty), and - Nython only -
# lib/nyaudit.ny's policies and `nython --audit-policy` / `--audit-log`.
#
#     ./build/nython-cli examples/vm_audit121.ny
#     ./build/nython-cli --vm examples/vm_audit121.ny
#     python3 examples/vm_audit121.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys, os, json, subprocess, tempfile, shutil

NYTHON = sys.implementation.name == "nython"
VER = "%d.%d" % (sys.version_info[0], sys.version_info[1])
HERE = os.path.dirname(os.path.abspath(__file__))
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

# ── the event table ───────────────────────────────────────────────────────
TABLE = {}
try:
    with open(os.path.join(HERE, "..", "tools", "audit_events.json")) as tf:
        TABLE = json.load(tf)["events"]
except OSError:
    pass

def raised_here(event):
    # does the running Python raise this event? (Nython: the table's
    # "nython" column; CPython X.Y: its "versions")
    r = TABLE.get(event)
    if r is None:
        return False
    if NYTHON:
        return not r["nython"].startswith("absent")
    return VER in r["versions"]

CHILD = r'''import sys, os
OUT = sys.stdout
T = os.path.realpath(sys.argv[1])
os.chdir(T)
MAIN = os.getpid()
state = {"label": None, "want": (), "veto": (), "fix": None, "busy": False}

class Veto(Exception):
    pass

def red(x):
    # an argument reduced to a stable value: the temporary directory as T,
    # objects by their type's name (never an attribute read: that could be
    # audited, or run a ctypes library's __getattr__)
    if x is None or isinstance(x, bool):
        return x
    if isinstance(x, (int, float)):
        return x
    if isinstance(x, str):
        return x.replace(T, "T")
    if isinstance(x, (bytes, bytearray)):
        b = bytes(x).replace(T.encode(), b"T")
        return b if len(b) <= 40 else "bytes"
    if isinstance(x, tuple) or type(x).__name__ == "UnraisableHookArgs":
        return tuple(red(a) for a in x)
    if isinstance(x, list):
        return [red(a) for a in x]
    if isinstance(x, type):
        return "<" + x.__name__ + ">"
    tn = type(x).__name__
    if isinstance(x, dict) and tn == "dict":
        return {red(k): red(v) for k, v in x.items()} if len(x) < 4 else "mapping"
    if tn in ("code", "_NyCode", "_NyFuncCode"):
        return "code"
    if tn in ("function", "builtin_function_or_method", "method", "method-wrapper"):
        return "function"
    if tn in ("_Environ", "mappingproxy"):
        return "mapping"
    return tn

def hook(event, args):
    if state["label"] is None or state["busy"] or os.getpid() != MAIN:
        return
    if not any(event == w or (w.endswith("*") and event.startswith(w[:-1])) for w in state["want"]):
        return
    state["busy"] = True
    try:
        a = tuple(args)
        if state["fix"] is not None:
            try:
                a = state["fix"](event, a)
            except Exception as e:
                a = ("fix failed", type(e).__name__, str(e))
        OUT.write(repr((state["label"], event, red(a))) + "\n")
        OUT.flush()
    finally:
        state["busy"] = False
    if event in state["veto"]:
        raise Veto(event)

sys.addaudithook(hook)

def case(label, want, fn, veto=(), fix=None):
    state["label"] = label
    state["want"] = want
    state["veto"] = veto
    state["fix"] = fix
    try:
        r = fn()
        if r is not None:
            OUT.write(repr((label, "=", r)) + "\n")
    except Veto:
        pass
    except Exception as e:
        OUT.write(repr((label, "!", type(e).__name__)) + "\n")
    OUT.flush()
    state["label"] = None
    state["fix"] = None

with open("f.txt", "w") as f:
    f.write("data\n")

def types_of(e, a):
    return tuple(type(x).__name__ for x in a)

# ── builtins and the interpreter ─────────────────────────────────────────
import io
case("id", ("builtins.id",), lambda: id(1) > 0 and None, fix=types_of)
def bp():
    sys.breakpointhook = lambda *a, **k: "hooked"
    return breakpoint()
case("breakpoint", ("builtins.breakpoint",), bp)
case("input", ("builtins.input*",), lambda: input("prompt> "))
case("compile", ("compile",), lambda: compile("1", "fname", "eval") and None)
case("exec source", ("compile", "exec"), lambda: exec("x_121 = 1"))
case("eval code", ("compile", "exec"), lambda: eval(compile("6 * 7", "f", "eval")))
def imp():
    import colorsys
case("import", ("import",), imp, fix=lambda e, a: (a[0], a[1]) + tuple(type(x).__name__ for x in a[2:]))
def op():
    open("f.txt").close()
    open("f.txt", "rb").close()
    open("g.txt", "w").close()
case("open", ("open",), op)
def opcode():
    io.open_code("f.txt").close()
case("io.open_code", ("open",), opcode)
def osopen():
    os.close(os.open("f.txt", os.O_RDONLY))
case("os.open", ("open",), osopen, fix=lambda e, a: (a[0], a[1], type(a[2]).__name__))

# ── code and function objects ────────────────────────────────────────────
import types
def code_new():
    c = (lambda: 0).__code__.replace(co_name="renamed")
    return c.co_name
case("code.replace", ("code.__new__",), code_new,
     fix=lambda e, a: (type(a[0]).__name__, a[1], a[2], a[3], a[4], a[5], a[6], type(a[7]).__name__, a[8] & 3))
def fn_new():
    f = types.FunctionType(compile("6 * 7", "f", "eval"), {})
    return f()
case("function.__new__", ("function.__new__",), fn_new)

# ── restricted attributes ────────────────────────────────────────────────
def f_kw(x=1, *, y=2):
    return x
def ga_fn():
    return [f_kw.__code__.co_name, f_kw.__defaults__, f_kw.__kwdefaults__, f_kw.__name__]
case("function attributes", ("object.*",), ga_fn)
def gen():
    yield 1
async def coro():
    pass
async def agen():
    yield 1
def ga_gen():
    g = gen()
    out = [type(g.gi_frame).__name__, g.gi_code.co_name, g.gi_running]
    c = coro()
    out += [type(c.cr_frame).__name__, c.cr_code.co_name]
    c.close()
    a = agen()
    out += [type(a.ag_frame).__name__, a.ag_code is not None]
    return out
case("generator attributes", ("object.*",), ga_gen)
def ga_frame():
    fr = sys._getframe()
    return [fr.f_code.co_name, fr.f_lineno > 0, fr.f_back is not None]
case("frame attributes", ("object.*",), ga_frame)
def ga_tb():
    try:
        1 / 0
    except ZeroDivisionError as e:
        tb = e.__traceback__
        return [type(tb.tb_frame).__name__, tb.tb_lineno > 0]
case("traceback attributes", ("object.*",), ga_tb)
def sa_fn():
    def h(a=1, *, b=2):
        return a
    h.__code__ = (lambda a=1, *, b=2: 2).__code__
    h.__defaults__ = (5,)
    h.__kwdefaults__ = {"b": 3}
    h.__name__ = "h2"
    del h.__defaults__
    del h.__kwdefaults__
    return h.__name__
case("function attribute stores", ("object.*",), sa_fn)
class A121:
    pass
class B121:
    pass
def sa_class():
    a = A121()
    a.__class__ = B121
    a.x = 1
    class C121(A121):
        pass
    C121.__bases__ = (B121,)
    C121.__name__ = "D121"
    C121.__qualname__ = "D121"
    C121.__module__ = "m121"
    C121.__doc__ = "doc"
    C121.other = 1
    del C121.other
    return [type(a).__name__, C121.__name__]
case("__class__ and type attribute stores", ("object.*",), sa_class)

# ── sys ──────────────────────────────────────────────────────────────────
case("sys._getframe", ("sys._getframe",), lambda: sys._getframe().f_code.co_name)
case("sys._getframemodulename", ("sys._getframemodulename",), lambda: sys._getframemodulename())
case("sys._current_frames", ("sys._current_frames",), lambda: type(sys._current_frames()).__name__)
case("sys._current_exceptions", ("sys._current_exceptions",), lambda: type(sys._current_exceptions()).__name__)
case("sys.settrace", ("sys.settrace",), lambda: sys.settrace(None))
case("sys.setprofile", ("sys.setprofile",), lambda: sys.setprofile(None))
case("sys.addaudithook", ("sys.addaudithook",), lambda: sys.addaudithook(lambda e, a: None))
def agh():
    old = sys.get_asyncgen_hooks()
    sys.set_asyncgen_hooks(firstiter=lambda a: None, finalizer=lambda a: None)
    sys.set_asyncgen_hooks(firstiter=None)
    sys.set_asyncgen_hooks(*old)
case("sys.set_asyncgen_hooks", ("sys.set_asyncgen_hook*",), agh)
def unr():
    import gc
    seen = []
    old = sys.unraisablehook
    sys.unraisablehook = lambda u: seen.append(type(u.exc_value).__name__)
    class D121:
        def __del__(self):
            1 / 0
    d = D121()
    del d
    gc.collect()
    sys.unraisablehook = old
    return seen
case("sys.unraisablehook", ("sys.unraisablehook",), unr)

# ── processes, threads, time ─────────────────────────────────────────────
import time, _thread, threading
case("time.sleep", ("time.sleep",), lambda: time.sleep(0))
def thr():
    done = threading.Event()
    _thread.start_new_thread(lambda a: done.set(), (1,))
    return done.wait(10)
case("_thread.start_new_thread", ("_thread.start_new_thread",), thr, fix=types_of)

# ── the C modules' events ────────────────────────────────────────────────
def arr():
    import array
    return [array.array("i", [1, 2]).tolist(), array.array("b").tolist(), array.array("d", (1.5,)).tolist()]
case("array.__new__", ("array.__new__",), arr)
def mar():
    import marshal
    b = marshal.dumps(1)
    marshal.loads(b)
    marshal.load(io.BytesIO(b))
    marshal.dump(2, io.BytesIO())
    return marshal.loads(marshal.dumps([1, "a"]))
case("marshal", ("marshal.*",), mar, fix=lambda e, a: tuple(type(x).__name__ if isinstance(x, bytes) else x for x in a))
def mm():
    import mmap
    m = mmap.mmap(-1, 16)
    m.close()
case("mmap.__new__", ("mmap.__new__",), mm)
def gcs():
    import gc
    gc.get_objects(0)
    gc.get_referrers(12345678)
    return gc.get_referents([5])
case("gc", ("gc.*",), gcs)
def sig():
    import signal
    signal.pthread_kill(threading.get_ident(), 0)
case("signal.pthread_kill", ("signal.pthread_kill",), sig, fix=lambda e, a: (type(a[0]).__name__, a[1]))
def res():
    import resource
    r = resource.getrlimit(resource.RLIMIT_CORE)
    resource.setrlimit(resource.RLIMIT_CORE, r)
    return resource.prlimit(0, resource.RLIMIT_CORE) == r
case("resource", ("resource.*",), res, fix=lambda e, a: tuple(type(x).__name__ if isinstance(x, tuple) else x for x in a))
def fc():
    import fcntl, termios
    fd = os.open("f.txt", os.O_RDWR)
    try:
        fcntl.fcntl(fd, fcntl.F_GETFD)
        try:
            fcntl.ioctl(fd, termios.FIONREAD, b"\0\0\0\0")
        except OSError:
            pass
        fcntl.flock(fd, fcntl.LOCK_UN)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
case("fcntl", ("fcntl.*",), fc, fix=lambda e, a: ("fd",) + a[1:])
def sl():
    import syslog
    syslog.openlog("ident121")
    syslog.setlogmask(syslog.LOG_UPTO(syslog.LOG_DEBUG))
    syslog.syslog("vetoed")
case("syslog", ("syslog.*",), sl, veto=("syslog.syslog",))
def sl2():
    import syslog
    syslog.closelog()
case("syslog.closelog", ("syslog.*",), sl2)
def sq():
    import sqlite3
    c = sqlite3.connect(":memory:")
    try:
        c.enable_load_extension(False)
        c.load_extension("nothing121")
    finally:
        c.close()
case("sqlite3", ("sqlite3.*",), sq, veto=("sqlite3.load_extension",))
def pk():
    import pickle, collections
    return type(pickle.loads(pickle.dumps(collections.OrderedDict(a=1)))).__name__
case("pickle.find_class", ("pickle.find_class",), pk)
def pd():
    import pdb
    pdb.Pdb()
case("pdb.Pdb", ("pdb.Pdb",), pd)
def pt():
    import pty
    pty.spawn("true")
case("pty.spawn", ("pty.spawn",), pt, veto=("pty.spawn",))

# ── files ────────────────────────────────────────────────────────────────
def gl():
    import glob
    return [glob.glob("*.txt"), sorted(glob.iglob("f*"))]
case("glob", ("glob.*",), gl)
def pl():
    import pathlib
    return [str(p) for p in pathlib.Path(".").glob("f.*")] + [str(p) for p in pathlib.Path(".").rglob("g.*")]
case("pathlib", ("pathlib.Path.glob", "pathlib.Path.rglob"), pl)
def plw():
    import pathlib
    return len(list(pathlib.Path(".").walk()))
case("pathlib.Path.walk", ("pathlib.Path.walk",), plw)
def sh():
    import shutil
    shutil.copyfile("f.txt", "s1.txt")
    shutil.copymode("f.txt", "s1.txt")
    shutil.copystat("f.txt", "s1.txt")
    shutil.copy("f.txt", "s2.txt")
    shutil.copy2("f.txt", "s3.txt")
    os.mkdir("sd1")
    shutil.copytree("sd1", "sd2")
    shutil.move("sd2", "sd3")
    shutil.rmtree("sd3")
    shutil.chown("s1.txt", os.getuid())
    a = shutil.make_archive("arch121", "tar", ".", "sd1")
    shutil.unpack_archive(a, "out121", "tar", filter="data")
    return sorted(os.listdir("out121"))
case("shutil", ("shutil.*",), sh, fix=lambda e, a: (a[0], -1) + a[2:] if e == "shutil.chown" else a)
def tf():
    import tempfile
    fd, n = tempfile.mkstemp(dir=T, prefix="p", suffix=".s")
    os.close(fd)
    d = tempfile.mkdtemp(dir=T, prefix="q", suffix=".d")
    return [os.path.isfile(n), os.path.isdir(d)]
case("tempfile", ("tempfile.*",), tf,
     fix=lambda e, a: (os.path.dirname(a[0]) == T, os.path.basename(a[0])[0], a[0][-2:]))

# ── os ───────────────────────────────────────────────────────────────────
case("os.system", ("os.system",), lambda: os.system("true"))
def ls():
    return [sorted(os.listdir("."))[:1], sorted(os.listdir())[:1], sorted(e.name for e in os.scandir("."))[:1]]
case("os.listdir/scandir", ("os.listdir", "os.scandir"), ls)
def mk():
    os.mkdir("od")
    os.makedirs("od2/x")
    os.rmdir("od2/x")
    os.removedirs("od2")
    os.rmdir("od")
    return os.path.exists("od2")
case("os.mkdir/rmdir", ("os.mkdir", "os.rmdir"), mk)
def rn():
    open("o1", "w").close()
    os.rename("o1", "o2")
    os.replace("o2", "o3")
    os.renames("o3", "o4")
    return os.path.exists("o4")
case("os.rename", ("os.rename",), rn)
def perm():
    os.chmod("o4", 0o644)
    os.chown("o4", -1, -1)
    os.lchown("o4", -1, -1)
    fd = os.open("o4", os.O_RDWR)
    try:
        os.fchmod(fd, 0o600)
        os.fchown(fd, -1, -1)
        os.ftruncate(fd, 0)
        os.lockf(fd, os.F_ULOCK, 0)
    finally:
        os.close(fd)
    os.truncate("o4", 0)
    os.utime("o4")
    os.utime("o4", (1, 2))
    return os.stat("o4").st_mtime
case("os.chmod/chown/truncate/utime/lockf", ("os.chmod", "os.chown", "os.truncate", "os.utime", "os.lockf"), perm,
     fix=lambda e, a: tuple("fd" if i == 0 and isinstance(x, int) else x for i, x in enumerate(a)))
def lk():
    os.link("o4", "o5")
    os.symlink("o4", "o6")
    os.remove("o5")
    os.unlink("o6")
    return sorted(n for n in os.listdir(".") if n.startswith("o"))
case("os.link/symlink/remove", ("os.link", "os.symlink", "os.remove"), lk)
def cd():
    os.mkdir("cd1")
    os.chdir("cd1")
    os.chdir("..")
    fd = os.open("cd1", os.O_RDONLY)
    try:
        os.fchdir(fd)
        os.chdir(T)
    finally:
        os.close(fd)
    os.rmdir("cd1")
    return os.getcwd() == T
case("os.chdir", ("os.chdir",), cd, fix=lambda e, a: ("fd",) if isinstance(a[0], int) else a)
def env():
    os.putenv("NY_AUDIT_121", "1")
    os.unsetenv("NY_AUDIT_121")
    os.environ["NY_AUDIT_121"] = "2"
    del os.environ["NY_AUDIT_121"]
    return "NY_AUDIT_121" in os.environ
case("os.putenv/unsetenv", ("os.putenv", "os.unsetenv"), env)
def wk():
    os.makedirs("w1/w2")
    return len(list(os.walk("w1")))
case("os.walk", ("os.walk", "os.scandir"), wk)
def fwk():
    r = len(list(os.fwalk("w1")))
    os.removedirs("w1/w2")
    return r
case("os.fwalk", ("os.fwalk",), fwk)
def kl():
    os.kill(os.getpid(), 0)
    os.killpg(os.getpgid(0), 0)
case("os.kill/killpg", ("os.kill", "os.killpg"), kl, fix=lambda e, a: ("pid", a[1]))
def fk():
    pid = os.fork()
    if pid == 0:
        os._exit(7)
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
case("os.fork", ("os.fork", "os.exec"), fk)
def fkp():
    pid, fd = os.forkpty()
    if pid == 0:
        os._exit(3)
    os.close(fd)
    return os.waitpid(pid, 0)[0] == pid
case("os.forkpty", ("os.forkpty", "os.fork"), fkp)
def ex():
    os.execv("/bin/true", ["true", "x"])
case("os.exec", ("os.exec",), ex, veto=("os.exec",))
def exe():
    os.execve("/bin/true", ["true"], {"A": "1"})
case("os.execve", ("os.exec",), exe, veto=("os.exec",))
def spv():
    return os.spawnv(os.P_WAIT, "/bin/true", ["true"])
case("os.spawnv", ("os.spawn", "os.fork", "os.exec", "os.posix_spawn"), spv)
def psp():
    pid = os.posix_spawn("/bin/true", ["true"], {"A": "1"})
    st = os.waitpid(pid, 0)[1]
    pid = os.posix_spawnp("true", ["true"], os.environ)
    return [st, os.waitpid(pid, 0)[1]]
case("os.posix_spawn", ("os.posix_spawn",), psp)

# ── processes and the network ─────────────────────────────────────────────
def sp():
    import subprocess
    return [subprocess.run(["true"]).returncode, subprocess.run("true", shell=True).returncode]
case("subprocess.Popen", ("subprocess.Popen",), sp)
def ur():
    import urllib.request
    with urllib.request.urlopen("file://" + os.path.join(T, "f.txt")) as r:
        return r.read()
case("urllib.Request", ("urllib.Request",), ur)
def hc():
    import http.client, socket
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    try:
        c = http.client.HTTPConnection("127.0.0.1", srv.getsockname()[1])
        c.connect()
        c.send(b"x")
        c.close()
    finally:
        srv.close()
case("http.client", ("http.client.*",), hc, fix=lambda e, a: (a[0], a[1], "port") if e.endswith("connect") else a)
def wb():
    import webbrowser
    webbrowser.open("http://example.invalid/121")
case("webbrowser.open", ("webbrowser.open",), wb, veto=("webbrowser.open",))
def mail(mod, cls):
    def run():
        import warnings
        warnings.simplefilter("ignore")
        m = __import__(mod)
        getattr(m, cls)("127.0.0.1", 1)
    return run
for mod, cls, ev in (("ftplib", "FTP", "ftplib.connect"), ("smtplib", "SMTP", "smtplib.connect"),
                     ("poplib", "POP3", "poplib.connect"), ("imaplib", "IMAP4", "imaplib.open"),
                     ("telnetlib", "Telnet", "telnetlib.Telnet.open")):
    case(ev, (ev,), mail(mod, cls), veto=(ev,))
import socket, warnings
def sends(mod, make, ev):
    def run():
        warnings.simplefilter("ignore")
        m = __import__(mod)
        a, b = socket.socketpair()
        try:
            make(m, a)
        finally:
            a.close()
            b.close()
    case(ev, (ev,), run, veto=(ev,))
def smtp_send(m, a):
    s = m.SMTP()
    s.sock = a
    s.send("NOOP\r\n")
def ftp_send(m, a):
    f = m.FTP()
    f.sock = a
    f.sendcmd("NOOP")
def telnet_send(m, a):
    t = m.Telnet()
    t.sock = a
    t.write(b"x")
def pop_send(m, a):
    p = object.__new__(m.POP3)
    p._debugging = 0
    p.sock = a
    p._putline(b"NOOP")
def imap_send(m, a):
    i = object.__new__(m.IMAP4)
    i.sock = a
    i.send(b"x")
sends("smtplib", smtp_send, "smtplib.send")
sends("ftplib", ftp_send, "ftplib.sendcmd")
sends("telnetlib", telnet_send, "telnetlib.Telnet.write")
sends("poplib", pop_send, "poplib.putline")
sends("imaplib", imap_send, "imaplib.send")
import ctypes, ctypes.util
def ct():
    lib = ctypes.CDLL(ctypes.util.find_library("c"))
    f = lib.strlen
    f2 = lib["strlen"]
    f.restype = ctypes.c_size_t
    n = f(b"abc")
    i = ctypes.c_int(5)
    ctypes.addressof(i)
    j = ctypes.c_int.from_address(ctypes.addressof(i))
    ba = bytearray(4)
    ctypes.c_int.from_buffer(ba)
    ctypes.c_int.from_buffer_copy(ba)
    s = ctypes.create_string_buffer(b"hi", 8)
    u = ctypes.create_unicode_buffer("hi", 8)
    s2 = ctypes.create_string_buffer(4)
    r = [n, j.value, ctypes.string_at(s, 2), ctypes.wstring_at(u, 2), len(s2)]
    ctypes.set_errno(0)
    r.append(ctypes.get_errno())
    return r
case("ctypes", ("ctypes.*",), ct,
     fix=lambda e, a: (("int",) + a[1:] if e in ("ctypes.cdata", "ctypes.cdata/buffer", "ctypes.string_at", "ctypes.wstring_at")
                       else ("libc",) if e == "ctypes.dlopen" else a))
def so():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", 0))
        s.sendto(b"x", s.getsockname())
        s.connect(s.getsockname())
        s.sendmsg([b"x"])
    finally:
        s.close()
    t = socket.socket()
    try:
        t.connect_ex(("127.0.0.1", 1))
    finally:
        t.close()
    socket.getaddrinfo("127.0.0.1", 80)
    socket.gethostbyname("localhost")
    socket.gethostbyname_ex("localhost")
    socket.gethostbyaddr("127.0.0.1")
    socket.gethostname()
    socket.getnameinfo(("127.0.0.1", 80), 0)
    socket.getservbyname("http", "tcp")
    socket.getservbyport(80, "tcp")
    socket.sethostname("vetoed121")
case("socket", ("socket.*",), so, veto=("socket.sethostname",),
     fix=lambda e, a: tuple(("127.0.0.1", "port") if isinstance(x, tuple) and len(x) == 2 and x[1] not in (0, 1, 80) else x for x in a))
def vetoes():
    out = []
    import subprocess
    for fn, chk in ((lambda: os.mkdir("v1"), lambda: os.path.exists("v1")),
                    (lambda: open("v2.txt", "w"), lambda: os.path.exists("v2.txt")),
                    (lambda: os.remove("f.txt"), lambda: os.path.exists("f.txt")),
                    (lambda: os.rename("f.txt", "v3.txt"), lambda: os.path.exists("v3.txt")),
                    (lambda: subprocess.run(["touch", "v4.txt"]), lambda: os.path.exists("v4.txt")),
                    (lambda: os.system("touch v5.txt"), lambda: os.path.exists("v5.txt")),
                    (lambda: exec("vetoed_121 = 1", globals()), lambda: "vetoed_121" in globals())):
        try:
            fn()
            out.append("ran")
        except Veto as e:
            out.append("vetoed " + str(e))
        out.append(chk())
    return out
case("a raising hook aborts the call", ("os.mkdir", "open", "os.remove", "os.rename", "subprocess.Popen", "os.system", "exec"),
     vetoes, veto=("os.mkdir", "open", "os.remove", "os.rename", "subprocess.Popen", "os.system", "exec"))
OUT.write(repr(("done",)) + "\n")
OUT.flush()
state["label"] = "sys.excepthook"
state["want"] = ("sys.excepthook",)
def eh(t, v, tb):
    OUT.write(repr(("sys.excepthook", "hook called", t.__name__, str(v))) + "\n")
    OUT.flush()
sys.excepthook = eh
raise LookupError("uncaught 121")
'''

# the records CPython 3.12 makes (python3.12 examples/vm_audit121.ny with
# NY121_DUMP=1 prints them)
EXPECTED = {
    'id': [('builtins.id', ('int',))],
    'breakpoint': [('builtins.breakpoint', ('function',)), ('=', 'hooked')],
    'input': [('builtins.input', ('prompt> ',)), ('=', 'typed')],
    'compile': [('compile', (b'1', 'fname'))],
    'exec source': [('compile', (b'x_121 = 1', '<string>')), ('exec', ('code',))],
    'eval code': [('compile', (b'6 * 7', 'f')), ('exec', ('code',)), ('=', 42)],
    'import': [('import', ('colorsys', None, 'list', 'list', 'list'))],
    'open': [('open', ('f.txt', 'r', 524288)), ('open', ('f.txt', 'r', 524288)), ('open', ('g.txt', 'w', 524865))],
    'io.open_code': [('open', ('f.txt', 'r', 524288))],
    'os.open': [('open', ('f.txt', None, 'int'))],
    'code.replace': [('code.__new__', ('bytes', 'T/child121.py', 'renamed', 0, 0, 0, 0, 'int', 3)), ('=', 'renamed')],
    'function.__new__': [('function.__new__', ('code',)), ('=', 42)],
    'function attributes': [('object.__getattr__', ('function', '__code__')), ('object.__getattr__', ('function', '__defaults__')), ('object.__getattr__', ('function', '__kwdefaults__')), ('=', ['f_kw', (1,), {'y': 2}, 'f_kw'])],
    'generator attributes': [('object.__getattr__', ('generator', 'gi_frame')), ('object.__getattr__', ('generator', 'gi_code')), ('object.__getattr__', ('coroutine', 'cr_frame')), ('object.__getattr__', ('coroutine', 'cr_code')), ('object.__getattr__', ('async_generator', 'ag_frame')), ('object.__getattr__', ('async_generator', 'ag_code')), ('=', ['frame', 'gen', False, 'frame', 'coro', 'frame', True])],
    'frame attributes': [('object.__getattr__', ('frame', 'f_code')), ('=', ['ga_frame', True, True])],
    'traceback attributes': [('object.__getattr__', ('traceback', 'tb_frame')), ('=', ['frame', True])],
    'function attribute stores': [('object.__getattr__', ('function', '__code__')), ('object.__setattr__', ('function', '__code__', 'code')), ('object.__setattr__', ('function', '__defaults__', (5,))), ('object.__setattr__', ('function', '__kwdefaults__', {'b': 3})), ('object.__delattr__', ('function', '__defaults__')), ('object.__delattr__', ('function', '__kwdefaults__')), ('=', 'h2')],
    '__class__ and type attribute stores': [('object.__setattr__', ('A121', '__class__', '<B121>')), ('object.__setattr__', ('<C121>', '__bases__', ('<B121>',))), ('object.__setattr__', ('<C121>', '__name__', 'D121')), ('object.__setattr__', ('<D121>', '__qualname__', 'D121')), ('object.__setattr__', ('<D121>', '__module__', 'm121')), ('object.__setattr__', ('<D121>', '__doc__', 'doc')), ('=', ['B121', 'D121'])],
    'sys._getframe': [('sys._getframe', ('frame',)), ('=', '<lambda>')],
    'sys._getframemodulename': [('sys._getframemodulename', (0,)), ('=', '__main__')],
    'sys._current_frames': [('sys._current_frames', ()), ('=', 'dict')],
    'sys._current_exceptions': [('sys._current_exceptions', ()), ('=', 'dict')],
    'sys.settrace': [('sys.settrace', ())],
    'sys.setprofile': [('sys.setprofile', ())],
    'sys.addaudithook': [('sys.addaudithook', ())],
    'sys.set_asyncgen_hooks': [('sys.set_asyncgen_hook_finalizer', ()), ('sys.set_asyncgen_hook_firstiter', ()), ('sys.set_asyncgen_hook_firstiter', ()), ('sys.set_asyncgen_hook_finalizer', ()), ('sys.set_asyncgen_hook_firstiter', ())],
    'sys.unraisablehook': [('sys.unraisablehook', ('function', ('<ZeroDivisionError>', 'ZeroDivisionError', 'traceback', None, 'function'))), ('=', ['ZeroDivisionError'])],
    'time.sleep': [('time.sleep', (0,))],                   # (3.13's event: no record from 3.12)
    '_thread.start_new_thread': [('_thread.start_new_thread', ('function', 'tuple', 'NoneType')), ('=', True)],
    'array.__new__': [('array.__new__', ('i', [1, 2])), ('array.__new__', ('b', None)), ('array.__new__', ('d', (1.5,))), ('=', [[1, 2], [], [1.5]])],
    'marshal': [('marshal.dumps', (1, 4)), ('marshal.loads', ('bytes',)), ('marshal.load', ()), ('marshal.dumps', (2, 4)), ('marshal.dumps', ([1, 'a'], 4)), ('marshal.loads', ('bytes',)), ('=', [1, 'a'])],
    'mmap.__new__': [('mmap.__new__', (-1, 16, 0, 0))],
    'gc': [('gc.get_objects', (0,)), ('gc.get_referrers', ((12345678,),)), ('gc.get_referents', (([5],),)), ('=', [5])],
    'signal.pthread_kill': [('signal.pthread_kill', ('int', 0))],
    'resource': [('resource.setrlimit', (4, 'tuple')), ('resource.prlimit', (0, 4, None)), ('=', True)],
    'fcntl': [('fcntl.fcntl', ('fd', 1, None)), ('fcntl.ioctl', ('fd', 21531, b'\x00\x00\x00\x00')), ('fcntl.flock', ('fd', 8)), ('fcntl.lockf', ('fd', 8, None, None, 0))],
    'syslog': [('syslog.openlog', ('ident121', 0, 8)), ('syslog.setlogmask', (255,)), ('syslog.syslog', (6, 'vetoed'))],
    'syslog.closelog': [('syslog.closelog', ())],
    'sqlite3': [('sqlite3.connect', (':memory:',)), ('sqlite3.connect/handle', ('Connection',)), ('sqlite3.enable_load_extension', ('Connection', False)), ('sqlite3.load_extension', ('Connection', 'nothing121'))],
    'pickle.find_class': [('pickle.find_class', ('collections', 'OrderedDict')), ('=', 'OrderedDict')],
    'pdb.Pdb': [('pdb.Pdb', ())],
    'pty.spawn': [('pty.spawn', (('true',),))],
    'glob': [('glob.glob', ('*.txt', False)), ('glob.glob/2', ('*.txt', False, None, None)), ('glob.glob', ('f*', False)), ('glob.glob/2', ('f*', False, None, None)), ('=', [['f.txt', 'g.txt'], ['f.txt']])],
    'pathlib': [('pathlib.Path.glob', ('PosixPath', 'f.*')), ('pathlib.Path.rglob', ('PosixPath', 'g.*')), ('=', ['f.txt', 'g.txt'])],
    'pathlib.Path.walk': [('pathlib.Path.walk', ('PosixPath', None, False)), ('=', 1)],
    'shutil': [('shutil.copyfile', ('f.txt', 's1.txt')), ('shutil.copymode', ('f.txt', 's1.txt')), ('shutil.copystat', ('f.txt', 's1.txt')), ('shutil.copyfile', ('f.txt', 's2.txt')), ('shutil.copymode', ('f.txt', 's2.txt')), ('shutil.copyfile', ('f.txt', 's3.txt')), ('shutil.copystat', ('f.txt', 's3.txt')), ('shutil.copytree', ('sd1', 'sd2')), ('shutil.copystat', ('sd1', 'sd2')), ('shutil.move', ('sd2', 'sd3')), ('shutil.rmtree', ('sd3', None)), ('shutil.chown', ('s1.txt', -1, None)), ('shutil.make_archive', ('arch121', 'tar', '.', 'sd1')), ('shutil.unpack_archive', ('T/arch121.tar', 'out121', 'tar')), ('=', ['sd1'])],
    'tempfile': [('tempfile.mkstemp', (True, 'p', '.s')), ('tempfile.mkdtemp', (True, 'q', '.d')), ('=', [True, True])],
    'os.system': [('os.system', (b'true',)), ('=', 0)],
    'os.listdir/scandir': [('os.listdir', ('.',)), ('os.listdir', (None,)), ('os.scandir', ('.',)), ('=', [['arch121.tar'], ['arch121.tar'], ['arch121.tar']])],
    'os.mkdir/rmdir': [('os.mkdir', ('od', 511, -1)), ('os.mkdir', ('od2', 511, -1)), ('os.mkdir', ('od2/x', 511, -1)), ('os.rmdir', ('od2/x', -1)), ('os.rmdir', ('od2', -1)), ('os.rmdir', ('od', -1)), ('=', False)],
    'os.rename': [('os.rename', ('o1', 'o2', -1, -1)), ('os.rename', ('o2', 'o3', -1, -1)), ('os.rename', ('o3', 'o4', -1, -1)), ('=', True)],
    'os.chmod/chown/truncate/utime/lockf': [('os.chmod', ('o4', 420, -1)), ('os.chown', ('o4', 4294967295, 4294967295, -1)), ('os.chown', ('o4', 4294967295, 4294967295, -1)), ('os.chmod', ('fd', 384, -1)), ('os.chown', ('fd', 4294967295, 4294967295, -1)), ('os.truncate', ('fd', 0)), ('os.lockf', ('fd', 0, 0)), ('os.truncate', ('o4', 0)), ('os.utime', ('o4', None, None, -1)), ('os.utime', ('o4', (1, 2), None, -1)), ('=', 2.0)],
    'os.link/symlink/remove': [('os.link', ('o4', 'o5', -1, -1)), ('os.symlink', ('o4', 'o6', -1)), ('os.remove', ('o5', -1)), ('os.remove', ('o6', -1)), ('=', ['o4', 'out121'])],
    'os.chdir': [('os.chdir', ('cd1',)), ('os.chdir', ('..',)), ('os.chdir', ('fd',)), ('os.chdir', ('T',)), ('=', True)],
    'os.putenv/unsetenv': [('os.putenv', (b'NY_AUDIT_121', b'1')), ('os.unsetenv', (b'NY_AUDIT_121',)), ('os.putenv', (b'NY_AUDIT_121', b'2')), ('os.unsetenv', (b'NY_AUDIT_121',)), ('=', False)],
    'os.walk': [('os.walk', ('w1', True, None, False)), ('os.scandir', ('w1',)), ('os.scandir', ('w1/w2',)), ('=', 2)],
    'os.fwalk': [('os.fwalk', ('w1', True, None, False, None)), ('=', 2)],
    'os.kill/killpg': [('os.kill', ('pid', 0)), ('os.killpg', ('pid', 0))],
    'os.fork': [('os.fork', ()), ('=', 7)],
    'os.forkpty': [('os.forkpty', ()), ('=', True)],
    'os.exec': [('os.exec', ('/bin/true', ['true', 'x'], None))],
    'os.execve': [('os.exec', ('/bin/true', ['true'], {'A': '1'}))],
    'os.spawnv': [('os.fork', ()), ('=', 0)],
    'os.posix_spawn': [('os.posix_spawn', ('/bin/true', ['true'], {'A': '1'})), ('os.posix_spawn', ('true', ['true'], 'mapping')), ('=', [0, 0])],
    'subprocess.Popen': [('subprocess.Popen', ('true', ['true'], None, None)), ('subprocess.Popen', ('/bin/sh', ['/bin/sh', '-c', 'true'], None, None)), ('=', [0, 0])],
    'urllib.Request': [('urllib.Request', ('file://T/f.txt', None, {}, 'GET')), ('=', b'data\n')],
    'http.client': [('http.client.connect', ('HTTPConnection', '127.0.0.1', 'port')), ('http.client.send', ('HTTPConnection', b'x'))],
    'ftplib.connect': [('ftplib.connect', ('FTP', '127.0.0.1', 21))],
    'smtplib.connect': [('smtplib.connect', ('SMTP', '127.0.0.1', 1))],
    'poplib.connect': [('poplib.connect', ('POP3', '127.0.0.1', 1))],
    'imaplib.open': [('imaplib.open', ('IMAP4', '127.0.0.1', 1))],
    'telnetlib.Telnet.open': [('telnetlib.Telnet.open', ('Telnet', '127.0.0.1', 1))],
    'smtplib.send': [('smtplib.send', ('SMTP', b'NOOP\r\n'))],
    'ftplib.sendcmd': [('ftplib.sendcmd', ('FTP', 'NOOP'))],
    'telnetlib.Telnet.write': [('telnetlib.Telnet.write', ('Telnet', b'x'))],
    'poplib.putline': [('poplib.putline', ('POP3', b'NOOP'))],
    'imaplib.send': [('imaplib.send', ('IMAP4', b'x'))],
    'ctypes': [('ctypes.dlopen', ('libc',)), ('ctypes.dlsym', ('CDLL', 'strlen')), ('ctypes.dlsym', ('CDLL', 'strlen')), ('ctypes.addressof', ('c_int',)), ('ctypes.addressof', ('c_int',)), ('ctypes.cdata', ('int',)), ('ctypes.cdata/buffer', ('int', 4, 0)), ('ctypes.cdata', ('int',)), ('ctypes.cdata/buffer', ('int', 4, 0)), ('ctypes.create_string_buffer', (b'hi', 8)), ('ctypes.create_unicode_buffer', ('hi', 8)), ('ctypes.create_string_buffer', (None, 4)), ('ctypes.string_at', ('int', 2)), ('ctypes.wstring_at', ('int', 2)), ('ctypes.set_errno', (0,)), ('ctypes.get_errno', ()), ('=', [3, 5, b'hi', 'hi', 4, 0])],
    'socket': [('socket.__new__', ('socket', 2, 2, 0)), ('socket.bind', ('socket', ('127.0.0.1', 0))), ('socket.sendto', ('socket', ('127.0.0.1', 'port'))), ('socket.connect', ('socket', ('127.0.0.1', 'port'))), ('socket.sendmsg', ('socket', None)), ('socket.__new__', ('socket', 2, 1, 0)), ('socket.connect', ('socket', ('127.0.0.1', 1))), ('socket.getaddrinfo', ('127.0.0.1', 80, 0, 0, 0)), ('socket.gethostbyname', ('localhost',)), ('socket.gethostbyname', ('localhost',)), ('socket.gethostbyaddr', ('127.0.0.1',)), ('socket.gethostname', ()), ('socket.getnameinfo', (('127.0.0.1', 80),)), ('socket.getservbyname', ('http', 'tcp')), ('socket.getservbyport', (80, 'tcp')), ('socket.sethostname', (b'vetoed121',))],
    'a raising hook aborts the call': [('os.mkdir', ('v1', 511, -1)), ('open', ('v2.txt', 'w', 524865)), ('os.remove', ('f.txt', -1)), ('os.rename', ('f.txt', 'v3.txt', -1, -1)), ('subprocess.Popen', ('touch', ['touch', 'v4.txt'], None, None)), ('os.system', (b'touch v5.txt',)), ('exec', ('code',)), ('=', ['vetoed os.mkdir', False, 'vetoed open', False, 'vetoed os.remove', True, 'vetoed os.rename', False, 'vetoed subprocess.Popen', False, 'vetoed os.system', False, 'vetoed exec', False])],
    'sys.excepthook': [('sys.excepthook', ('function', '<LookupError>', 'LookupError', 'traceback')), ('hook called', 'LookupError', 'uncaught 121')],
}

# cases whose result needs a newer Python (both sides skipped below it), or
# a module an older one only has
SINCE = {"sys._getframemodulename": "3.12", "pathlib.Path.walk": "3.12"}
UNTIL = {"telnetlib.Telnet.open": "3.12", "telnetlib.Telnet.write": "3.12"}

def vkey(v):
    return tuple(int(x) for x in v.split("."))

def kept(label):
    if NYTHON:
        return True
    if label in SINCE and vkey(VER) < vkey(SINCE[label]):
        return False
    if label in UNTIL and vkey(VER) > vkey(UNTIL[label]):
        return False
    return True

def parse_lines(text):
    import ast
    out = {}
    order = []
    for line in text.splitlines():
        i = line.find("(")
        if i < 0:
            continue
        try:
            rec = ast.literal_eval(line[i:])
        except Exception:
            continue
        if not isinstance(rec, tuple) or not rec:
            continue
        if rec[0] not in out:
            out[rec[0]] = []
            order.append(rec[0])
        out[rec[0]].append(rec[1:])
    return out, order

def filtered(recs):
    # an event this Python does not raise is dropped (results stay)
    return [r for r in recs if r[0] in ("=", "!", "hook called") or raised_here(r[0])]

ENGINE = ["--vm"] if NYTHON and "--vm" in getattr(sys, "orig_argv", []) else []

T = tempfile.mkdtemp(prefix="ny121_%d_" % os.getpid())
child = os.path.join(T, "child121.py")
with open(child, "w") as f:
    f.write(CHILD)
proc = subprocess.run([sys.executable] + ENGINE + [child, T], input="typed\n", capture_output=True, text=True, timeout=600)
got, order = parse_lines(proc.stdout)

if os.environ.get("NY121_DUMP"):
    print("EXPECTED = {")
    for k in order:
        print("    %r: %r," % (k, got[k]))
    print("}")
    print("stderr:", proc.stderr[-2000:])
    sys.exit(0)

check("the child ran every case", ["done" in got, proc.returncode], [True, 1])
for label in EXPECTED:
    if not kept(label):
        continue
    check("audit: " + label, filtered(got.get(label, [])), filtered(EXPECTED[label]))
for label in got:
    if label not in EXPECTED and label != "done":
        check("audit: unexpected case " + label, got[label], None)

def run_py(name, text, args=(), stdin=None, env=None, flags=()):
    path = os.path.join(T, name)
    with open(path, "w") as f:
        f.write(text)
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run([sys.executable] + ENGINE + list(flags) + [path] + list(args), input=stdin,
                          capture_output=True, text=True, timeout=300, env=e, cwd=T)

# ── before a hook exists, and sys.audit's own checks ─────────────────────
r = run_py("before121.py", """import sys, os
seen = []
os.listdir("."); id(1); compile("1", "f", "eval"); exec("pass")
r = [sys.audit("no.hook.yet", 1), sys.audit(5)]          # nothing checked while no hook exists
sys.addaudithook(lambda e, a: seen.append((e, a)))
r.append(list(seen))                                     # a hook hears nothing that came before it
sys.audit("first.event", 1, "two")
r.append(list(seen))
for f in (lambda: sys.audit(5), lambda: sys.audit()):
    try:
        f()
        r.append("no error")
    except TypeError as e:
        r.append(str(e))
class Stop(Exception):
    pass
def stopper(e, a):
    if e == "stop.me":
        raise Stop(a)
sys.addaudithook(stopper)
try:
    sys.audit("stop.me", 7)
    r.append("ran")
except Stop as e:
    r.append(["Stop", e.args])
r.append(seen[-1])                                       # hooks are called in the order they were added
print(repr(r))
""")
check("no hook, then hooks in order", [r.stdout.strip(), r.returncode],
      [repr([None, None, [], [("first.event", (1, "two"))], "expected str for argument 'event', not int",
             "audit() missing 1 required positional argument: 'event'", ["Stop", ((7,),)],
             ("stop.me", (7,))]), 0])

# ── the table ────────────────────────────────────────────────────────────
evs = TABLE
check("the table has CPython's documented events", [len(evs) > 170, all(k in evs for k in
      ("open", "exec", "import", "os.system", "socket.connect", "ctypes.dlopen", "subprocess.Popen", "winreg.OpenKey"))],
      [True, True])
check("each record's columns", sorted(set(tuple(sorted(k for k in r if k in ("module", "args", "raised_from", "versions", "nython")))
                                          for r in evs.values())),
      [("args", "module", "nython", "raised_from", "versions")])
check("raised from C or from Python", sorted(set(r["raised_from"] for r in evs.values())), ["C", "Python"])
check("some events of each kind", [evs["os.mkdir"]["raised_from"], evs["shutil.copyfile"]["raised_from"],
                                   evs["os.mkdir"]["args"], evs["glob.glob/2"]["args"], evs["time.sleep"]["versions"]],
      ["C", "Python", ["path", "mode", "dir_fd"], ["pathname", "recursive", "root_dir", "dir_fd"], ["3.13"]])
check("the documented asyncgen names are not the raised ones", [evs["sys.set_asyncgen_hooks_firstiter"]["versions"],
      sorted(evs["sys.set_asyncgen_hook_firstiter"]["versions"])[:2]], [[], ["3.11", "3.12"]])
seen_events = set(rec[0] for k in got for rec in got[k] if rec and rec[0] not in ("=", "!", "hook called"))
check("every event the child saw is in the table", sorted(e for e in seen_events if e not in evs), [])
if NYTHON:
    check("Nython raises what its column says", sorted(e for e in seen_events if evs[e]["nython"].startswith("absent")), [])
    raised = [e for e, r in evs.items() if not r["nython"].startswith("absent")]
    check("Nython raises most of CPython's non-Windows events", len(raised) > 140, True)

# ── input()'s result, read from a terminal (a pty) ───────────────────────
def pty_input():
    import pty
    pid, fd = pty.fork()
    if pid == 0:
        try:
            seen = []
            sys.addaudithook(lambda e, a: seen.append((e, a)) if e.startswith("builtins.input") else None)
            v = input("p121> ")
            sys.stdout.write("\nRESULT " + repr([seen, v]) + "\n")
            sys.stdout.flush()
        finally:
            os._exit(0)
    os.write(fd, b"abc\n")
    data = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    os.waitpid(pid, 0)
    os.close(fd)
    for line in data.decode("utf-8", "replace").splitlines():
        if line.startswith("RESULT "):
            return line[7:].strip()
    return data
if os.name == "posix":
    check("input() on a terminal: builtins.input and builtins.input/result", pty_input(),
          repr([[("builtins.input", ("p121> ",)), ("builtins.input/result", ("abc",))], "abc"]))

# ── lib/nyaudit.ny (Nython's own) ─────────────────────────────────────────
if NYTHON:
    import nyaudit
    p = nyaudit.Policy(default="deny")
    p.allow("import").allow("open", mode="r").allow("open", path=T + "/*", mode="w")
    p.deny("os.system", message="no shell here")
    p.allow("socket.connect", address="127.0.0.1:*")
    p.allow("subprocess.Popen", "true")
    def d(e, a):
        return p.decide(e, a)[0]
    check("nyaudit: decisions by event and argument patterns",
          [d("import", ("x", None, [], [], [])), d("open", ("/etc/passwd", "r", 0)), d("open", ("/etc/passwd", "w", 1)),
           d("open", (T + "/a.txt", "w", 1)), d("os.system", (b"ls",)), d("socket.connect", (None, ("127.0.0.1", 80))),
           d("socket.connect", (None, ("10.1.2.3", 80))), d("os.remove", ("x", -1)), d("subprocess.Popen", ("true", ["true"], None, None)),
           d("subprocess.Popen", ("rm", ["rm"], None, None))],
          ["allow", "allow", "deny", "allow", "deny", "allow", "deny", "deny", "allow", "deny"])
    check("nyaudit: the deciding rule", [p.decide("os.system", (b"x",))[1].message, p.decide("os.chdir", ("/",))[1]],
          ["no shell here", None])
    check("nyaudit: the policy's text, parsed back", nyaudit.parse(p.text()).text(), p.text())
    q = nyaudit.parse('''# a policy
default allow
deny  os.system  message="no shells"
deny  open path=/etc/* mode=w*
log   socket.*
allow os.*
''')
    check("nyaudit: a policy file", [q.default, [r.action + " " + r.event for r in q.rules],
                                     q.decide("open", ("/etc/x", "w", 1))[0], q.decide("open", ("/etc/x", "r", 0))[0],
                                     q.decide("os.system", (b"x",))[1].message, q.decide("socket.connect", (None, ("h", 1)))[0]],
          ["allow", ["deny os.system", "deny open", "log socket.*", "allow os.*"], "deny", "allow", "no shells", "allow"])
    jq = nyaudit.parse(json.dumps({"default": "deny", "rules": [["allow", "import"], ["allow", "open", {"mode": "r"}]]}))
    check("nyaudit: the JSON form", [jq.decide("import", ("m",))[0], jq.decide("open", ("f", "r", 0))[0], jq.decide("open", ("f", "w", 1))[0]],
          ["allow", "allow", "deny"])
    with p.granted("os.remove", path=T + "/*"):
        inside = [d("os.remove", (T + "/x", -1)), d("os.remove", ("/x", -1))]
    check("nyaudit: granted() lends a capability for a block", [inside, d("os.remove", (T + "/x", -1))],
          [["allow", "deny"], "deny"])
    check("nyaudit: the event table's argument names", [nyaudit.event_args("open"), nyaudit.event_args("socket.connect")],
          [("path", "mode", "flags"), ("self", "address")])
    check("nyaudit's argument names are the table's",
          sorted(e for e, names in nyaudit._EVENT_ARGS.items() if TABLE.get(e, {}).get("args") != list(names)), [])
    e1 = nyaudit.AuditDenied("os.system", (b"ls",))
    check("nyaudit: AuditDenied", [isinstance(e1, PermissionError), str(e1), e1.event], [True, "audit policy denies os.system(ls)", "os.system"])
    def bad(f):
        try:
            f()
            return "no error"
        except Exception as e:
            return type(e).__name__ + ": " + str(e)
    check("nyaudit: bad policies", [bad(lambda: nyaudit.Policy(default="maybe")), bad(lambda: nyaudit.parse("permit x")),
                                    bad(lambda: nyaudit.Rule("allow", ""))],
          ["ValueError: default must be 'allow' or 'deny', not 'maybe'", "ValueError: policy line 1: unknown directive 'permit'",
           "TypeError: a rule's event is a non-empty glob string"])

    # an installed policy, in a child (hooks cannot be removed)
    r = run_py("policy121.py", """import nyaudit, os, sys
p = nyaudit.Policy(default="allow", keep=50)
p.deny("os.system").deny("open", path="/etc/*", mode="w*")
p.install()
out = []
try:
    os.system("true")
    out.append("ran")
except PermissionError as e:
    out.append([type(e).__name__, str(e)])
try:
    open("/etc/nyaudit_121_never", "w")
    out.append("opened")
except PermissionError as e:
    out.append(type(e).__name__)
with open("ok121.txt", "w") as f:
    f.write("x")
out.append(os.path.exists("ok121.txt"))
try:
    p.allow("os.system")
    out.append("loosened")
except RuntimeError as e:
    out.append(str(e))
out.append([d for e, a, d in p.events if e in ("os.system", "open")][:3])
out.append(p.denied)
print(repr(out))
""")
    check("nyaudit: an installed policy denies, allows and is frozen", [r.stdout.strip(), r.returncode],
          [repr([["AuditDenied", "audit policy denies os.system(true)"], "AuditDenied", True,
                 "the audit policy is installed and frozen: it cannot be changed", ["deny", "deny", "allow"], 2]), 0])

    # nython --audit-policy FILE: installed before the program's first statement
    pol = os.path.join(T, "p121.txt")
    log = os.path.join(T, "events121.jsonl")
    with open(pol, "w") as f:
        f.write("default allow\nlog " + log + "\ndeny os.system message=\"no shells (policy file)\"\n")
    prog = """import os, sys
try:
    os.system("true")
except PermissionError as e:
    print("denied:", e)
os.listdir(".")
print("done")
"""
    r = run_py("prog121.py", prog, flags=["--audit-policy", pol])
    first = None
    names = []
    try:
        with open(log) as f:
            recs = [json.loads(line) for line in f if line.strip()]
        first = recs[0]
        names = [x["event"] for x in recs]
    except (OSError, ValueError, IndexError):
        pass
    check("nython --audit-policy: the program runs under it", [r.stdout, r.returncode],
          ["denied: no shells (policy file)\ndone\n", 0])
    check("nython --audit-policy: cpython.run_file first, then the program's events",
          [first, "os.system" in names, "os.listdir" in names, [x["decision"] for x in recs if x["event"] == "os.system"]],
          [{"event": "cpython.run_file", "args": [os.path.join(T, "prog121.py")], "decision": "allow"}, True, True, ["deny"]])

    # --audit-log, then a policy derived from the log
    log2 = os.path.join(T, "events121b.jsonl")
    prog2 = """import os
with open("data121.txt", "w") as f:
    f.write("1")
print(open("data121.txt").read(), "data121.txt" in os.listdir("."))
"""
    r1 = run_py("prog121b.py", prog2, flags=["--audit-log", log2])
    derived = subprocess.run([sys.executable] + ENGINE + ["-m", "nyaudit", "derive", log2], capture_output=True, text=True, cwd=T).stdout
    pol2 = os.path.join(T, "p121b.txt")
    with open(pol2, "w") as f:
        f.write(derived)
    r2 = run_py("prog121b.py", prog2, flags=["--audit-policy", pol2])
    r3 = run_py("prog121c.py", prog2 + "os.system('true')\n", flags=["--audit-policy", pol2])
    check("nython --audit-log: every event logged", [r1.stdout, r1.returncode, derived.startswith("# derived by nyaudit"),
                                                     "default deny" in derived, "allow cpython.run_file" in derived,
                                                     "allow os.listdir" in derived],
          ["1 True\n", 0, True, True, True, True])
    check("a derived policy runs that program and refuses anything else",
          [r2.stdout, r2.returncode, r3.returncode != 0, "PermissionError" in r3.stderr or "AuditDenied" in r3.stderr],
          ["1 True\n", 0, True, True])
    r4 = subprocess.run([sys.executable] + ENGINE + ["--audit-log", log2 + ".c", "-c", "pass"], capture_output=True, text=True, cwd=T)
    with open(log2 + ".c") as f:
        firstc = json.loads(f.readline())
    check("nython --audit-log -c: cpython.run_command", [r4.returncode, firstc], [0, {"event": "cpython.run_command", "args": ["pass"], "decision": "allow"}])

shutil.rmtree(T, ignore_errors=True)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT121 PASSED ===")
