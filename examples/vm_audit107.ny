# vm_audit107.ny - imports of Python source files, and quoted imports from
# anywhere (round 82 follow-ups).
#
# `import name` finds name.py (and a package's __init__.py, a namespace
# package of .py files) when no directory holds name.ny - every directory
# is searched for a .ny module before any is for a .py one, so a .py file
# never shadows a library module (Nython's rule; CPython's sys.path order
# lets a stray random.py shadow the standard library). `-m name` runs
# name.py likewise. A quoted import (`import "lib/x.ny"`) is also looked
# for in the library directories and the installation's root, so a program
# run from any directory includes the library's files.
#
# Inside an asyncio task, threading.get_ident()/current_thread()/local are
# the thread running the loop's (a task is not a thread); `_thread`, the
# low-level module; threading.Lock is Python's primitive lock (no owner:
# another thread releases it, its holder acquiring it again waits - it was
# an owned mutex, so the acquire/release-elsewhere idiom raised
# DeadlockError) and frees its native lock with it.
#
# The shared checks pass under python3 too:
#
#     ./build/nython-cli examples/vm_audit107.ny
#     ./build/nython-cli --vm examples/vm_audit107.ny
#     python3 examples/vm_audit107.ny

import os, sys, subprocess, tempfile, importlib, importlib.util

NYTHON = sys.implementation.name == "nython"
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

tmpdir = tempfile.mkdtemp()

def write(rel, text):
    path = os.path.join(tmpdir, rel)
    d = os.path.dirname(path)
    if not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w") as f:
        f.write(text)
    return path

write("pyonly_mod.py", "X = 'py'\ndef f():\n    return 41 + 1\n")
write("pypkg/__init__.py", "NAME = 'pkg'\nfrom . import sub\n")
write("pypkg/sub.py", "def g():\n    return 'sub.g'\nPARENT = __package__\n")
write("nspkg/leaf.py", "LEAF = 'leaf'\n")
write("dual.ny", "WHICH = 'ny'\n")
write("dual.py", "WHICH = 'py'\n")
write("pyonly_main.py", "import sys\nprint('main', __name__, len(sys.argv))\n")
write("fractions.py", "SHADOW = True\n")
sys.path.insert(0, tmpdir)

# ── a module ──────────────────────────────────────────────────────────────
import pyonly_mod
check("import finds name.py", [pyonly_mod.X, pyonly_mod.f(), pyonly_mod.__name__], ["py", 42, "pyonly_mod"])
check("its __file__ is the .py file", os.path.basename(pyonly_mod.__file__), "pyonly_mod.py")
from pyonly_mod import f as ff
check("from name.py import", ff(), 42)
check("importlib.import_module and find_spec", [importlib.import_module("pyonly_mod") is pyonly_mod,
      os.path.basename(importlib.util.find_spec("pyonly_mod").origin)], [True, "pyonly_mod.py"])

# ── packages ──────────────────────────────────────────────────────────────
import pypkg
check("a package's __init__.py", [pypkg.NAME, pypkg.sub.g(), pypkg.sub.PARENT], ["pkg", "sub.g", "pypkg"])
check("its __path__ and __package__", [os.path.basename(pypkg.__path__[0]), pypkg.__package__], ["pypkg", "pypkg"])
from pypkg.sub import g
check("from pkg.sub import name", g(), "sub.g")
check("find_spec of a package names its __init__.py",
      os.path.basename(importlib.util.find_spec("pypkg").origin), "__init__.py")
import nspkg.leaf
check("a namespace package of .py modules", nspkg.leaf.LEAF, "leaf")

# ── .ny first ─────────────────────────────────────────────────────────────
import dual
check("name.ny before name.py in the same directory", dual.WHICH, "ny" if NYTHON else "py")
import fractions
check("a .py file does not shadow a library module", hasattr(fractions, "SHADOW"), not NYTHON)

# ── -m runs name.py ───────────────────────────────────────────────────────
out = subprocess.run([sys.executable, "-m", "pyonly_main", "a", "b"], cwd=tmpdir,
                     capture_output=True, text=True)
check("-m name runs name.py", [out.stdout.strip(), out.returncode], ["main __main__ 3", 0])

# ── quoted imports from any directory (Nython's form) ────────────────────
if NYTHON:
    script = write("quoted.ny", 'import "lib/heapq.ny" as hq\nprint(hq.nlargest(2, [1, 5, 3]))\n')
    out = subprocess.run([sys.executable, script], cwd=tmpdir, capture_output=True, text=True)
    check("import \"lib/x.ny\" from outside the installation", [out.stdout.strip(), out.returncode], ["[5, 3]", 0])
    script = write("quoted_vm.ny", 'import "lib/heapq.ny" as hq\nprint(hq.nsmallest(1, [4, 2]))\n')
    out = subprocess.run([sys.executable, "--vm", script], cwd=tmpdir, capture_output=True, text=True)
    check("... and on the VM", [out.stdout.strip(), out.returncode], ["[2]", 0])
    out = subprocess.run([sys.executable, "-c", 'import "nosuch/x.ny"'], cwd=tmpdir, capture_output=True, text=True)
    check("a quoted import that is nowhere is still an ImportError", ["ImportError" in out.stderr, out.returncode], [True, 1])
else:
    for n in ["import \"lib/x.ny\" from outside the installation", "... and on the VM",
              "a quoted import that is nowhere is still an ImportError"]:
        results.append([n, True, None, None])

# ── threads seen from asyncio tasks; _thread ─────────────────────────────
import threading, asyncio, _thread, time, gc

tl = threading.local()
tl.v = "main"
async def in_task():
    seen = [threading.get_ident() == threading.main_thread().ident,
            threading.current_thread() is threading.main_thread(),
            getattr(tl, "v", None)]
    tl.v = "set by a task"
    return seen
check("a task runs on its loop's thread: get_ident, current_thread, threading.local",
      [asyncio.run(in_task()), tl.v], [[True, True, "main"], "set by a task"])

lk = _thread.allocate_lock()
box = []
def worker(a, b, k=0):
    box.append(a + b + k)
    box.append(_thread.get_ident() != threading.main_thread().ident)
    lk.release()
lk.acquire()
ident = _thread.start_new_thread(worker, (1, 2), {"k": 3})
lk.acquire(timeout=10)
check("_thread.start_new_thread / allocate_lock / get_ident",
      [box, isinstance(ident, int), _thread.get_ident() == threading.get_ident(),
       isinstance(lk, _thread.LockType), _thread.error is RuntimeError], [[6, True], True, True, True, True])
def errs():
    out = []
    for f in [lambda: _thread.start_new_thread(worker, [1, 2]),
              lambda: _thread.start_new_thread(worker, (1, 2), [1]),
              lambda: _thread.stack_size(100)]:
        try:
            f()
            out.append("no error")
        except (TypeError, ValueError) as e:
            out.append(type(e).__name__ + ": " + str(e))
    return out
check("_thread's argument errors", errs(), ["TypeError: 2nd arg must be a tuple",
      "TypeError: optional 3rd arg must be a dictionary", "ValueError: size not valid: 100 bytes"])
def lock_errors():
    out = []
    l = threading.Lock()
    for f in [lambda: l.release(), lambda: threading.RLock().release(),
              lambda: l.acquire(False, 1), lambda: l.acquire(timeout=-2)]:
        try:
            f()
            out.append("no error")
        except (RuntimeError, ValueError) as e:
            out.append(type(e).__name__ + ": " + str(e))
    l.acquire()
    out.append([l.acquire(timeout=0.02), l.locked(), repr(l).startswith("<locked _thread.lock object at 0x")])
    return out
check("threading.Lock is Python's: no owner, its errors, waiting on itself times out", lock_errors(),
      ["RuntimeError: release unlocked lock", "RuntimeError: cannot release un-acquired lock",
       "ValueError: can't specify a timeout for a non-blocking call", "ValueError: timeout value must be positive",
       [False, True, True]])

def interrupted():
    try:
        _thread.interrupt_main()
        for i in range(2000):
            time.sleep(0.001)
        return "not interrupted"
    except KeyboardInterrupt:
        return "KeyboardInterrupt"
check("_thread.interrupt_main raises KeyboardInterrupt in the main thread", interrupted(), "KeyboardInterrupt")

if NYTHON:
    def lock_freed():
        l = threading.Lock()
        h = l._id
        l = None
        gc.collect()
        try:
            mutex_locked(h)
            return False
        except BaseException:
            return True
    check("a threading.Lock's native mutex goes with it", lock_freed(), True)
else:
    results.append(["a threading.Lock's native mutex goes with it", True, None, None])

# ── a missing module is still ModuleNotFoundError ─────────────────────────
try:
    import no_such_module_anywhere_107
    check("missing module", "imported", "ModuleNotFoundError")
except ModuleNotFoundError as e:
    check("missing module", [type(e).__name__, e.name], ["ModuleNotFoundError", "no_such_module_anywhere_107"])

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
    print("=== VM_AUDIT107 PASSED ===")
