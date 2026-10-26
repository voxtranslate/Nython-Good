#!/usr/bin/env python3
"""Generate tools/audit_events.json - CPython's audit events (PEP 578), the
table Nython's engines and library raise them after (round 86).

    python3 tools/gen_audit_events.py                   # docs.python.org + probes
    python3 tools/gen_audit_events.py --doc ~/cpython/Doc   # a CPython checkout's docs
    python3 tools/gen_audit_events.py --offline         # probes only (keeps the docs
                                                        # columns of the existing table)

Three sources, merged:

1. The documentation. Every `.. audit-event:: name args refs` directive of
   CPython's docs (Doc/**/*.rst - `--doc DIR`, for one version: its
   Doc/conf.py names it); without a checkout, the "Audit events table" those
   directives make (docs.python.org/<v>/library/audit_events.html) is read
   for 3.11, 3.12 and 3.13. Each version's list says which events it raises.
2. The library sources. An event the host Pythons' own Lib/*.py raise with
   sys.audit("name", ...) is raised from Python; every other one from C.
3. Probes. Each python3.11 / 3.12 / 3.13 found runs PROBES (below) under a
   hook recording every event as it happens (its arguments' types, and
   whether the frame that raised it is a sys.audit call in a .py file),
   which confirms the version lists and gives each event's argument types.
   Dangerous operations (sethostname, ensurepip, a browser, a mail server)
   are vetoed by the hook: the event is recorded and the operation aborted,
   as PEP 578 says a raising hook does.

Each event's record: module, args (the documented names), raised_from ("C"
or "Python"), versions (the CPython versions raising it), probe_types (per
version, the argument types seen), docs (the references), platform
("windows" for the Windows-only ones), and nython: where Nython raises it
(NYTHON below - "engine", "library", "prelude") or why it does not
("absent: ..."). examples/vm_audit121.ny reads `versions` to keep, under a
python3, only the events that version raises.
"""
import argparse, glob, html, json, os, re, subprocess, sys, sysconfig, tempfile, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tools", "audit_events.json")
VERSIONS = ("3.11", "3.12", "3.13")

# ── where Nython raises each event (round 86) ──────────────────────────────
# engine: a native of both engines (include/NythonExecutor.hpp,
# include/VirtualMachine.hpp, src/builtins/*.cpp - nyrt::audit_on() first);
# prelude: include/NyPrelude.hpp's Nython code (both engines); library: a
# lib/ module's own sys.audit call. Anything not named here is not raised,
# for the reason ABSENT gives.
NYTHON = {
    "builtins.id": "engine", "builtins.breakpoint": "prelude", "builtins.input": "engine",
    "builtins.input/result": "engine", "compile": "engine", "exec": "engine", "import": "engine",
    "open": "prelude", "code.__new__": "prelude", "function.__new__": "engine",
    "object.__getattr__": "engine", "object.__setattr__": "engine", "object.__delattr__": "engine",
    "sys._getframe": "engine", "sys._current_frames": "prelude", "sys._current_exceptions": "prelude",
    "sys._getframemodulename": "prelude",
    "sys.settrace": "prelude", "sys.setprofile": "prelude", "sys.addaudithook": "prelude",
    "sys.excepthook": "prelude", "sys.unraisablehook": "prelude",
    "sys.set_asyncgen_hook_firstiter": "prelude", "sys.set_asyncgen_hook_finalizer": "prelude",
    "cpython.run_command": "engine", "cpython.run_file": "engine", "cpython.run_module": "engine",
    "cpython.run_stdin": "engine", "pathlib.Path.walk": "library",
    "os.getxattr": "prelude", "os.setxattr": "prelude", "os.listxattr": "prelude", "os.removexattr": "prelude",
    "_thread.start_new_thread": "library", "array.__new__": "library",
    "marshal.dumps": "library", "marshal.loads": "library", "marshal.load": "library",
    "mmap.__new__": "library", "gc.get_objects": "library", "gc.get_referrers": "library",
    "gc.get_referents": "library", "time.sleep": "engine", "signal.pthread_kill": "library",
    "resource.setrlimit": "library", "resource.prlimit": "library",
    "fcntl.fcntl": "library", "fcntl.ioctl": "library", "fcntl.flock": "library", "fcntl.lockf": "library",
    "syslog.openlog": "library", "syslog.syslog": "library", "syslog.setlogmask": "library",
    "syslog.closelog": "library",
    "sqlite3.connect": "library", "sqlite3.connect/handle": "library",
    "sqlite3.enable_load_extension": "library", "sqlite3.load_extension": "library",
    "pickle.find_class": "library", "pdb.Pdb": "library", "pty.spawn": "library",
    "glob.glob": "library", "glob.glob/2": "library", "pathlib.Path.glob": "library",
    "pathlib.Path.rglob": "library", "shutil.copyfile": "library", "shutil.copymode": "library",
    "shutil.copystat": "library", "shutil.copytree": "library", "shutil.rmtree": "library",
    "shutil.move": "library", "shutil.chown": "library", "shutil.make_archive": "library",
    "shutil.unpack_archive": "library", "tempfile.mkstemp": "library", "tempfile.mkdtemp": "library",
    "subprocess.Popen": "library", "urllib.Request": "library", "http.client.connect": "library",
    "http.client.send": "library", "webbrowser.open": "library",
    "ftplib.connect": "library", "ftplib.sendcmd": "library", "smtplib.connect": "library",
    "smtplib.send": "library", "poplib.connect": "library", "poplib.putline": "library",
    "imaplib.open": "library", "imaplib.send": "library", "telnetlib.Telnet.open": "library",
    "telnetlib.Telnet.write": "library",
    "ctypes.dlopen": "library", "ctypes.dlsym": "library",
    "ctypes.addressof": "library", "ctypes.cdata": "library",
    "ctypes.cdata/buffer": "library", "ctypes.create_string_buffer": "library",
    "ctypes.create_unicode_buffer": "library", "ctypes.string_at": "library",
    "ctypes.wstring_at": "library", "ctypes.get_errno": "library", "ctypes.set_errno": "library",
    "ctypes.get_last_error": "library", "ctypes.set_last_error": "library",
    "socket.__new__": "library", "socket.bind": "library", "socket.connect": "library",
    "socket.getaddrinfo": "library", "socket.gethostbyname": "library",
    "socket.gethostbyaddr": "library", "socket.gethostname": "library",
    "socket.getnameinfo": "library", "socket.getservbyname": "library",
    "socket.getservbyport": "library", "socket.sendmsg": "library", "socket.sendto": "library",
    "socket.sethostname": "library",
    "os.system": "prelude", "os.exec": "prelude", "os.posix_spawn": "prelude",
    "os.fork": "prelude", "os.forkpty": "prelude", "os.kill": "prelude", "os.killpg": "prelude",
    "os.listdir": "prelude", "os.scandir": "prelude", "os.mkdir": "prelude", "os.remove": "prelude",
    "os.rename": "prelude", "os.rmdir": "prelude", "os.chmod": "prelude", "os.chown": "prelude",
    "os.chdir": "prelude", "os.link": "prelude", "os.symlink": "prelude", "os.truncate": "prelude",
    "os.utime": "prelude", "os.putenv": "prelude", "os.unsetenv": "prelude", "os.walk": "prelude",
    "os.fwalk": "prelude", "os.lockf": "prelude",
    # round 87: Windows' own modules (lib/msvcrt.ny, winreg.ny, _winapi.ny)
    # and ensurepip
    "ensurepip.bootstrap": "library",
    "msvcrt.locking": "library", "msvcrt.open_osfhandle": "library", "msvcrt.get_osfhandle": "library",
    "winreg.ConnectRegistry": "library", "winreg.CreateKey": "library", "winreg.DeleteKey": "library",
    "winreg.DeleteValue": "library", "winreg.DisableReflectionKey": "library",
    "winreg.EnableReflectionKey": "library", "winreg.EnumKey": "library", "winreg.EnumValue": "library",
    "winreg.ExpandEnvironmentStrings": "library", "winreg.LoadKey": "library", "winreg.OpenKey": "library",
    "winreg.OpenKey/result": "library", "winreg.PyHKEY.Detach": "library", "winreg.QueryInfoKey": "library",
    "winreg.QueryReflectionKey": "library", "winreg.QueryValue": "library", "winreg.SaveKey": "library",
    "winreg.SetValue": "library",
    "_winapi.CreateFile": "library", "_winapi.CreateNamedPipe": "library", "_winapi.OpenProcess": "library",
}
ABSENT = {
    "nntplib.connect": "absent: no nntplib (removed from CPython in 3.13)",
    "nntplib.putline": "absent: no nntplib (removed from CPython in 3.13)",
    "sys.monitoring.register_callback": "absent: no sys.monitoring (PEP 669)",
    "setopencodehook": "absent: C API only (PyFile_SetOpenCodeHook)",
    "cpython.PyInterpreterState_New": "absent: C API only (one interpreter per process)",
    "cpython.PyInterpreterState_Clear": "absent: C API only (one interpreter per process)",
    "cpython.run_startup": "absent: no PYTHONSTARTUP file at Nython's prompt",
    "cpython.run_interactivehook": "absent: no sys.__interactivehook__",
    "cpython._PySys_ClearAuditHooks": "absent: only C-level hooks (PySys_AddAuditHook) hear it",
    "ctypes.call_function": "absent: raised by CPython's private _ctypes.call_function only",
    "ctypes.dlsym/handle": "absent: raised by CPython's private _ctypes.dlsym only",
    "_thread.start_joinable_thread": "absent: Nython's threading starts threads as 3.12's (_thread.start_new_thread)",
    "os.spawn": "absent: Windows only (POSIX's os.spawn* are fork + exec: os.fork, os.exec)",
    "os.chflags": "absent: BSD/macOS only (no chflags on Linux or Windows)",
    "ctypes.set_exception": "absent: Windows SEH (ctypes structured exceptions) not provided",
    "ctypes.seh_exception": "absent: Windows SEH (ctypes structured exceptions) not provided",
}
WINDOWS = ("msvcrt.", "winreg.", "_winapi.", "os.startfile", "os.add_dll_directory",
           "os.listdrives", "os.listmounts", "os.listvolumes", "ctypes.set_last_error",
           "ctypes.get_last_error", "ctypes.set_exception", "ctypes.seh_exception", "os.spawn")
NYTHON["ctypes.get_last_error"] = "library"
NYTHON["ctypes.set_last_error"] = "library"
# the argument names of events CPython raises without documenting them
# (from its sources)
UNDOCUMENTED_ARGS = {"pathlib.Path.walk": ["self", "on_error", "follow_symlinks"],
                     "_thread.start_joinable_thread": ["function", "handle", "daemon"]}
# documented names CPython's code never raises (its probes show the real
# ones): the record of the documented name points to the raised one
DOC_ERRATA = {"sys.set_asyncgen_hooks_firstiter": "sys.set_asyncgen_hook_firstiter",
              "sys.set_asyncgen_hooks_finalizer": "sys.set_asyncgen_hook_finalizer"}


# ── the probes: one operation (or a few) per event ─────────────────────────
# Run in a fresh temporary directory under a hook that writes one JSON line
# per event to a descriptor (os.write - never itself audited), so events of
# children (fork, exec) and of the interpreter's finalization are seen too.
PROBES = r'''
import sys, os, json, linecache
_fd = int(sys.argv[1])
_state = {"probe": "", "busy": False}
veto = set()
class Veto(Exception):
    pass
def _tname(a):
    t = type(a)
    return t.__name__ if t.__module__ in ("builtins", "__builtin__") else t.__module__ + "." + t.__qualname__
def _hook(event, args):
    if _state["busy"]:
        return
    _state["busy"] = True
    try:
        frm = None
        try:
            f = sys._getframe(1)
            line = linecache.getline(f.f_code.co_filename, f.f_lineno)
            frm = "Python" if "audit(" in line and f.f_code.co_filename.endswith(".py") else "C"
        except Exception:
            pass
        rec = {"probe": _state["probe"], "event": event, "types": [_tname(a) for a in args], "from": frm}
        os.write(_fd, (json.dumps(rec) + "\n").encode())
    finally:
        _state["busy"] = False
    if event in veto:
        raise Veto(event)
sys.addaudithook(_hook)

import tempfile
TMP = tempfile.mkdtemp()
os.chdir(TMP)
with open("f.txt", "w") as f:
    f.write("data\n")

def probe(label, code):
    _state["probe"] = label
    try:
        exec(code, {"veto": veto, "Veto": Veto, "TMP": TMP})
    except BaseException as e:
        pass
    veto.clear()
    _state["probe"] = ""

P = []
def p(label, code):
    P.append((label, code))

p("builtins.id", "id(1)")
p("builtins.breakpoint", "import sys\nsys.breakpointhook = lambda *a, **k: None\nbreakpoint()")
p("builtins.input", "import sys, io\nold = sys.stdin\nsys.stdin = io.StringIO('typed\\n')\ntry:\n    input('prompt> ')\nfinally:\n    sys.stdin = old")
p("compile", "compile('1', 'fname', 'eval')")
p("exec", "exec('x = 1')\neval(compile('2', 'f', 'eval'))")
p("import", "import colorsys")
p("open", "open('f.txt').close()\nimport io\nio.open_code('f.txt').close()\nos.close(os.open('f.txt', os.O_RDONLY))")
p("code.__new__", "(lambda: 0).__code__.replace(co_name='x')")
p("function.__new__", "import types\ntypes.FunctionType((lambda: 0).__code__, {})")
p("object.__getattr__", """
import sys, asyncio
def f(): pass
f.__code__; f.__globals__; f.__defaults__; f.__kwdefaults__; f.__closure__; f.__builtins__
def g():
    yield 1
gi = g(); gi.gi_frame; gi.gi_code
async def c(): pass
co = c(); co.cr_frame; co.cr_code; co.close()
async def ag():
    yield 1
a = ag(); a.ag_frame; a.ag_code
fr = sys._getframe(); fr.f_back; fr.f_code; fr.f_globals; fr.f_builtins; fr.f_locals; fr.f_trace
try:
    1 / 0
except ZeroDivisionError as e:
    tb = e.__traceback__; tb.tb_frame; tb.tb_next
""")
p("object.__setattr__", """
def f(): pass
f.__code__ = (lambda: 1).__code__
f.__defaults__ = (); f.__kwdefaults__ = {}; f.__name__ = 'h'; f.__qualname__ = 'h'; f.__doc__ = 'd'
class A: pass
class B: pass
class C(A): pass
a = A(); a.__class__ = B
C.__bases__ = (B,)
C.__name__ = 'D'; C.__qualname__ = 'D'; C.__module__ = 'm'; C.__doc__ = 'x'; C.attr = 1
""")
p("object.__delattr__", """
class A:
    x = 1
del A.x
def f(): pass
f.__doc__ = 'x'
del f.__doc__
try:
    del f.__defaults__
except Exception:
    pass
try:
    del f.__kwdefaults__
except Exception:
    pass
""")
p("sys._getframe", "import sys\nsys._getframe()\nsys._getframe(0)")
p("sys._current_frames", "import sys\nsys._current_frames()")
p("sys._current_exceptions", "import sys\nsys._current_exceptions()")
p("sys._getframemodulename", "import sys\nsys._getframemodulename()")
p("sys.settrace", "import sys\nsys.settrace(None)")
p("sys.setprofile", "import sys\nsys.setprofile(None)")
p("sys.addaudithook", "import sys\nsys.addaudithook(lambda e, a: None)")
p("sys.set_asyncgen_hooks", "import sys\nold = sys.get_asyncgen_hooks()\nsys.set_asyncgen_hooks(firstiter=lambda a: None, finalizer=lambda a: None)\nsys.set_asyncgen_hooks(*old)")
p("sys.unraisablehook", "import sys, gc\nsys.unraisablehook = lambda u: None\nclass D:\n    def __del__(self):\n        1 / 0\nD()\ngc.collect()")
p("sys.monitoring.register_callback", "import sys\nsys.monitoring.register_callback(1, 1, None)")
p("_thread.start_new_thread", "import threading\nt = threading.Thread(target=lambda: None)\nt.start()\nt.join()")
p("array.__new__", "import array\narray.array('i', [1, 2])\narray.array('u')")
p("marshal", "import marshal, io\nb = marshal.dumps(1)\nmarshal.loads(b)\nmarshal.load(io.BytesIO(b))\nmarshal.dump(1, io.BytesIO())")
p("mmap.__new__", "import mmap\nmmap.mmap(-1, 16).close()")
p("gc", "import gc\ngc.get_objects(0)\ngc.get_referrers(1)\ngc.get_referents([])")
p("time.sleep", "import time\ntime.sleep(0)")
p("signal.pthread_kill", "import signal, threading\nsignal.pthread_kill(threading.get_ident(), 0)")
p("resource", "import resource\nr = resource.getrlimit(resource.RLIMIT_CORE)\nresource.setrlimit(resource.RLIMIT_CORE, r)\nresource.prlimit(0, resource.RLIMIT_CORE)")
p("fcntl", """
import fcntl, os, termios, struct
fd = os.open('f.txt', os.O_RDWR)
fcntl.fcntl(fd, fcntl.F_GETFL)
try:
    fcntl.ioctl(fd, termios.FIONREAD, b'\\0\\0\\0\\0')
except OSError:
    pass
fcntl.flock(fd, fcntl.LOCK_UN)
fcntl.lockf(fd, fcntl.LOCK_UN)
os.close(fd)
""")
p("syslog", "import syslog\nveto.add('syslog.syslog')\nsyslog.openlog('x')\nsyslog.setlogmask(255)\nsyslog.closelog()\nsyslog.syslog('m')")
p("sqlite3", "import sqlite3\nc = sqlite3.connect(':memory:')\nveto.add('sqlite3.load_extension')\ntry:\n    c.enable_load_extension(False)\n    c.load_extension('x')\nexcept Exception:\n    pass\nc.close()")
p("pickle.find_class", "import pickle, collections\npickle.loads(pickle.dumps(collections.OrderedDict()))\nimport io\npickle._Unpickler(io.BytesIO(pickle.dumps(collections.OrderedDict()))).load()")
p("pdb.Pdb", "import pdb\npdb.Pdb()")
p("pty.spawn", "import pty\nveto.add('pty.spawn')\npty.spawn('true')")
p("glob", "import glob\nglob.glob('*.txt')\nlist(glob.iglob('*.txt'))")
p("pathlib", "import pathlib\nlist(pathlib.Path('.').glob('*.txt'))\nlist(pathlib.Path('.').rglob('*.txt'))")
p("shutil", """
import shutil, os
shutil.copyfile('f.txt', 'g.txt'); shutil.copymode('f.txt', 'g.txt'); shutil.copystat('f.txt', 'g.txt')
shutil.copy('f.txt', 'h.txt'); shutil.copy2('f.txt', 'i.txt')
os.mkdir('d1'); shutil.copytree('d1', 'd2'); shutil.move('d2', 'd3'); shutil.rmtree('d3')
shutil.chown('f.txt', os.getuid())
a = shutil.make_archive('arch', 'zip', '.', 'd1'); shutil.unpack_archive(a, 'out', 'zip')
""")
p("tempfile", "import tempfile, os\nfd, n = tempfile.mkstemp(); os.close(fd)\ntempfile.mkdtemp()\ntempfile.NamedTemporaryFile().close()\ntempfile.TemporaryDirectory().cleanup()")
p("subprocess.Popen", "import subprocess\nsubprocess.run(['true'])")
p("urllib.Request", "import urllib.request, os\nurllib.request.urlopen('file://' + os.path.abspath('f.txt')).close()")
p("http.client", """
import http.client, socket
srv = socket.socket(); srv.bind(('127.0.0.1', 0)); srv.listen(1)
c = http.client.HTTPConnection('127.0.0.1', srv.getsockname()[1])
c.connect(); c.send(b'x'); c.close(); srv.close()
""")
p("webbrowser.open", "import webbrowser\nveto.add('webbrowser.open')\nwebbrowser.open('http://example.invalid/')")
for mod, cls, ev in (("ftplib", "FTP", "ftplib.connect"), ("smtplib", "SMTP", "smtplib.connect"),
                     ("poplib", "POP3", "poplib.connect"), ("imaplib", "IMAP4", "imaplib.open"),
                     ("telnetlib", "Telnet", "telnetlib.Telnet.open"), ("nntplib", "NNTP", "nntplib.connect")):
    p(ev, "import warnings\nwarnings.simplefilter('ignore')\nimport %s\nveto.add(%r)\n%s.%s('127.0.0.1', 1)" % (mod, ev, mod, cls))
p("ensurepip.bootstrap", "import ensurepip\nveto.add('ensurepip.bootstrap')\nensurepip.bootstrap()")
p("ctypes", """
import ctypes, ctypes.util
lib = ctypes.CDLL(ctypes.util.find_library('c'))
f = lib.strlen
f.restype = ctypes.c_size_t
f(b'abc')
i = ctypes.c_int(5)
ctypes.addressof(i)
ctypes.c_int.from_address(ctypes.addressof(i))
ba = bytearray(4)
ctypes.c_int.from_buffer(ba); ctypes.c_int.from_buffer_copy(ba)
s = ctypes.create_string_buffer(b'hi', 8); u = ctypes.create_unicode_buffer('hi', 8)
ctypes.string_at(s, 2); ctypes.wstring_at(u, 2)
ctypes.set_errno(0); ctypes.get_errno()
""")
p("socket", """
import socket
veto.add('socket.sethostname')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('127.0.0.1', 0))
s.sendto(b'x', s.getsockname())
s.sendmsg([b'x'], [], 0, s.getsockname())
s.connect(s.getsockname())
s.close()
t = socket.socket(); t.connect_ex(('127.0.0.1', 1)); t.close()
socket.getaddrinfo('127.0.0.1', 80)
socket.gethostbyname('localhost'); socket.gethostbyname_ex('localhost')
socket.gethostbyaddr('127.0.0.1'); socket.gethostname(); socket.getnameinfo(('127.0.0.1', 80), 0)
socket.getservbyname('http', 'tcp'); socket.getservbyport(80, 'tcp')
socket.sethostname('nope')
""")
p("os", """
import os, signal
os.system('true')
os.listdir('.'); os.scandir('.').close(); os.mkdir('od'); os.makedirs('od2/x')
os.rmdir('od2/x'); os.removedirs('od2')
open('o1', 'w').close(); os.rename('o1', 'o2'); os.replace('o2', 'o3'); os.renames('o3', 'o4')
os.chmod('o4', 0o644); os.chown('o4', -1, -1); os.lchown('o4', -1, -1)
fd = os.open('o4', os.O_RDWR); os.fchmod(fd, 0o644); os.fchown(fd, -1, -1); os.ftruncate(fd, 0)
os.lockf(fd, os.F_ULOCK, 0); os.close(fd)
os.truncate('o4', 0); os.utime('o4'); os.utime('o4', (1, 2))
os.link('o4', 'o5'); os.symlink('o4', 'o6'); os.remove('o5'); os.unlink('o6')
os.chdir('od'); os.chdir('..')
fd = os.open('od', os.O_RDONLY); os.fchdir(fd); os.chdir('..'); os.close(fd)
os.rmdir('od')
os.putenv('NY_AUDIT_X', '1'); os.unsetenv('NY_AUDIT_X')
list(os.walk('.')); list(os.fwalk('.'))
os.kill(os.getpid(), 0); os.killpg(os.getpgid(0), 0)
pid = os.fork()
if pid == 0:
    os._exit(0)
os.waitpid(pid, 0)
os.spawnv(os.P_WAIT, '/bin/true', ['true'])
os.waitpid(os.posix_spawn('/bin/true', ['true'], os.environ), 0)
os.waitpid(os.posix_spawnp('true', ['true'], os.environ), 0)
pid = os.fork()
if pid == 0:
    try:
        os.execv('/bin/true', ['true'])
    finally:
        os._exit(0)
os.waitpid(pid, 0)
pid, fd = os.forkpty()
if pid == 0:
    os._exit(0)
os.waitpid(pid, 0); os.close(fd)
try:
    os.setxattr('f.txt', 'user.x', b'1'); os.getxattr('f.txt', 'user.x'); os.listxattr('f.txt'); os.removexattr('f.txt', 'user.x')
except OSError:
    pass
""")
for label, code in P:
    probe(label, code)
_state["probe"] = "sys.excepthook"
sys.excepthook = lambda *a: None
raise ZeroDivisionError("the end")
'''


def probe(exe):
    """{event: {"types": [...], "from": "C"|"Python"|None}} as exe raises them."""
    r, w = os.pipe()
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(PROBES)
        path = f.name
    try:
        proc = subprocess.Popen([exe, "-I", "-X", "warn_default_encoding=0", path, str(w)], pass_fds=(w,),
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(w)
        data = b""
        while True:
            b = os.read(r, 65536)
            if not b:
                break
            data += b
        proc.wait(timeout=300)
    finally:
        os.close(r)
        os.unlink(path)
    out = {}
    for line in data.decode().splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        e = rec["event"]
        if e not in out:
            out[e] = {"types": rec["types"], "from": rec["from"]}
        elif rec["from"] == "Python":
            out[e]["from"] = "Python"
    return out


def doc_events_rst(docdir):
    """{event: (args, refs)} from the audit-event directives under docdir."""
    ev = {}
    pat = re.compile(r"^\s*\.\.\s+audit-event::\s+(\S+)\s*(.*?)\s*$")
    for path in glob.glob(os.path.join(docdir, "**", "*.rst"), recursive=True):
        rel = os.path.relpath(path, docdir)
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = pat.match(line)
                if not m:
                    continue
                name, rest = m.group(1), m.group(2)
                parts = rest.split(None, 1)
                args = [a.strip() for a in parts[0].split(",") if a.strip()] if parts and parts[0] != "\"\"" else []
                refs = parts[1].split() if len(parts) > 1 else []
                old = ev.setdefault(name, ([], []))
                ev[name] = (old[0] or args, old[1] + [rel.replace(".rst", ".html")] + refs)
    return ev


def doc_events_html(text):
    """{event: (args, refs)} from a rendered audit_events.html."""
    ev = {}
    rows = re.findall(r'<tr class="row-(?:even|odd)"><td><p>(.*?)</p></td>\s*<td><p>(.*?)</p></td>\s*<td><p>(.*?)</p></td>',
                      text, re.S)
    for name, args, refs in rows:
        ev[html.unescape(name)] = ([html.unescape(a) for a in re.findall(r'<span class="pre">(.*?)</span>', args)],
                                   [html.unescape(h) for h in re.findall(r'href="(.*?)"', refs)])
    return ev


def python_raised():
    """{event: "module"} for every sys.audit("event", ...) in the host Pythons' Lib."""
    out = {}
    pat = re.compile(r"""\baudit\(\s*(?:f?)["']([^"'{]+)["']""")
    for v in ("3.12", "3.11", "3.13"):
        lib = "/usr/lib/python" + v
        if not os.path.isdir(lib):
            continue
        for path in glob.glob(os.path.join(lib, "**", "*.py"), recursive=True):
            if ("/test/" in path or "site-packages" in path or "dist-packages" in path or "idlelib" in path
                    or "_pyrepl" in path):
                continue
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in pat.finditer(text):
                mod = os.path.relpath(path, lib)[:-3].replace(os.sep, ".")
                if mod.endswith(".__init__"):
                    mod = mod[:-9]
                out.setdefault(m.group(1), mod)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--doc", help="a CPython checkout's Doc directory (one version: its conf.py's)")
    ap.add_argument("--html-dir", help="saved audit_events.html pages, named audit_events-3.12.html ...")
    ap.add_argument("--offline", action="store_true", help="no download: keep the docs columns of the existing table")
    ap.add_argument("-o", "--output", default=OUT)
    a = ap.parse_args()

    docs = {}       # version -> {event: (args, refs)}
    sources = {}
    if a.doc:
        ver = None
        try:
            conf = open(os.path.join(a.doc, "..", "Include", "patchlevel.h")).read()
            m = re.search(r'#define PY_VERSION\s+"(\d+\.\d+)', conf)
            ver = m.group(1) if m else None
        except OSError:
            pass
        ver = ver or "3.12"
        docs[ver] = doc_events_rst(a.doc)
        sources[ver] = "audit-event directives under " + os.path.abspath(a.doc)
    for v in VERSIONS:
        if v in docs:
            continue
        text = None
        if a.html_dir and os.path.exists(os.path.join(a.html_dir, "audit_events-%s.html" % v)):
            text = open(os.path.join(a.html_dir, "audit_events-%s.html" % v), encoding="utf-8").read()
            sources[v] = "saved audit_events.html"
        elif not a.offline:
            url = "https://docs.python.org/%s/library/audit_events.html" % v
            try:
                text = urllib.request.urlopen(url, timeout=30).read().decode("utf-8")
                sources[v] = url + " (the table of the docs' audit-event directives)"
            except Exception as e:
                print("could not read", url, "-", e, file=sys.stderr)
        if text:
            docs[v] = doc_events_html(text)
    old = {}
    if a.offline and os.path.exists(a.output):
        old = json.load(open(a.output)).get("events", {})
        for v in VERSIONS:
            if v not in docs:
                docs[v] = {e: (r.get("args", []), r.get("docs", [])) for e, r in old.items() if v in r.get("doc_versions", [])}
                sources[v] = "the existing table's documentation columns"

    pyraised = python_raised()
    probes = {}
    for v in VERSIONS:
        exe = "/usr/bin/python" + v
        if os.path.exists(exe):
            print("probing", exe, file=sys.stderr)
            probes[v] = probe(exe)

    names = set()
    for d in docs.values():
        names |= set(d)
    for pr in probes.values():
        names |= {e for e in pr if not e.startswith("cpython.run_")}   # (the probe's own run)
    events = {}
    for e in sorted(names):
        args, refs, dv = [], [], []
        for v in ("3.12", "3.13", "3.11"):      # the names of 3.12's docs first (Nython's language level)
            if e in docs.get(v, {}):
                dv.append(v)
                args = args or docs[v][e][0]
                for r in docs[v][e][1]:
                    if r not in refs:
                        refs.append(r)
        dv.sort()
        args = args or UNDOCUMENTED_ARGS.get(e, [])
        pv = [v for v in VERSIONS if e in probes.get(v, {})]
        versions = sorted(set(dv) | set(pv))
        seen_from = [probes[v][e]["from"] for v in pv if probes[v][e]["from"]]
        if seen_from:
            frm = "Python" if "Python" in seen_from else "C"
        else:
            frm = "Python" if e in pyraised else "C"
        if e.startswith("cpython.") and not seen_from:
            frm = "C"          # Modules/main.c (asyncio's REPL raises cpython.run_stdin from Python too)
        if frm == "Python" and e in pyraised:
            mod = pyraised[e]
        else:
            mod = e.split(".")[0] if "." in e else "builtins"
            if e.startswith("object.") or e in ("compile", "exec", "open", "import"):
                mod = "builtins"
            if e.startswith("cpython."):
                mod = "(interpreter)"
        rec = {"module": mod, "args": args, "raised_from": frm, "versions": versions,
               "doc_versions": dv, "probe_types": {v: probes[v][e]["types"] for v in pv}, "docs": refs}
        if any(e == w or (w.endswith(".") and e.startswith(w)) for w in WINDOWS):
            rec["platform"] = "windows"
        rec["nython"] = NYTHON.get(e) or ABSENT.get(e) or ("absent: Windows only" if rec.get("platform") else "absent")
        if e in DOC_ERRATA:
            rec["note"] = "the documented name: CPython raises " + DOC_ERRATA[e]
            rec["versions"] = [v for v in versions if v not in probes]
            rec["nython"] = "absent: never raised under this name (Nython raises " + DOC_ERRATA[e] + ", as CPython)"
        events[e] = rec
    for e, real in DOC_ERRATA.items():
        if e in events and real in events:
            events[real]["args"] = events[real]["args"] or events[e]["args"]
            events[real]["docs"] = events[real]["docs"] or events[e]["docs"]
    table = {
        "generated_by": "tools/gen_audit_events.py (round 86)",
        "sources": {v: sources.get(v, "") for v in VERSIONS if v in sources},
        "probed": sorted(probes),
        "events": events,
    }
    with open(a.output, "w") as f:
        json.dump(table, f, indent=1, sort_keys=False)
        f.write("\n")
    print("%d events -> %s" % (len(events), a.output), file=sys.stderr)


if __name__ == "__main__":
    main()
