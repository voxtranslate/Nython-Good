# vm_audit99.ny - the semantic gaps round 80 left, both engines (round 81).
#
# except E as e unbinds e; globals() is the module's live namespace and
# sys.modules["__main__"] the real main module; modules have __spec__ and
# __loader__, and the import statement honours sys.meta_path and
# sys.path_hooks; attribute hooks (__setattr__, __delattr__,
# __getattribute__) assigned to a class after its instances stored
# attributes are called; a list iterator reads the live list; a class that
# takes no arguments says so; the default repr is CPython's; a trace
# function can move a frame to another line (f_lineno, pdb's jump);
# sys.getrefcount, sys.stdlib_module_names, sys.displayhook at the prompt,
# -OO; deep recursion under a raised recursion limit.
#
# Every expected value is CPython's (3.11 and 3.12 - where they differ the
# check accepts either); it runs under python3 too:
#
#     ./build/nython-cli examples/vm_audit99.ny
#     ./build/nython-cli --vm examples/vm_audit99.ny
#     python3 examples/vm_audit99.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys, os, subprocess, tempfile

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

tmpdir = tempfile.mkdtemp()

def run_child(args, src, stdin_text=None):
    # the same engine as this program, with `args` before the script
    path = os.path.join(tmpdir, "child_" + str(len(os.listdir(tmpdir))) + ".py")
    with open(path, "w") as f:
        f.write(src)
    cmd = [sys.executable]
    if nython and vm_engine:
        cmd.append("--vm")
    cmd = cmd + args + [path]
    r = subprocess.run(cmd, capture_output=True, text=True, input=stdin_text)
    return r.stdout

vm_engine = False
if nython:
    vm_engine = "--vm" in sys.orig_argv

# ── except E as e: e is unbound when the clause ends ─────────────────────────
def exc_after():
    try:
        raise ValueError("x")
    except ValueError as e:
        pass
    try:
        return e
    except NameError as n:
        return "NameError"
check("except-as: the name is unbound after the clause", exc_after(), "NameError")

def exc_return():
    try:
        raise KeyError(1)
    except KeyError as e:
        return type(e).__name__
check("except-as: return from the clause", exc_return(), "KeyError")

def exc_continue():
    seen = []
    for i in range(3):
        try:
            raise ValueError(i)
        except ValueError as e:
            seen.append(e.args[0])
            if i == 1:
                continue
    return [seen, "e" in locals()]
check("except-as: continue out of the clause unbinds too", exc_continue(), [[0, 1, 2], False])

def exc_raise_out():
    try:
        try:
            raise ValueError(1)
        except ValueError as e:
            raise KeyError(2)
    except KeyError:
        pass
    return "e" in locals()
check("except-as: an exception out of the clause unbinds too", exc_raise_out(), False)

def exc_shadow():
    e = 5
    try:
        raise ValueError(1)
    except ValueError as e:
        pass
    return "e" in locals()
check("except-as: an earlier binding of the name is gone too", exc_shadow(), False)

def exc_del():
    try:
        raise ValueError(1)
    except ValueError as e:
        del e
    return "ok"
check("except-as: del inside the clause", exc_del(), "ok")

def exc_finally():
    out = []
    try:
        try:
            raise ValueError(1)
        except ValueError as e:
            out.append("handler")
        finally:
            out.append("e" in locals())
    except NameError:
        out.append("NameError")
    return out
check("except-as: unbound before the try's finally runs", exc_finally(), ["handler", False])

ERRS = (KeyError, IndexError)
def exc_expr():
    try:
        [][1]
    except ERRS[1] as e:
        pass
    return "e" in locals()
check("except <expression> as e unbinds too", exc_expr(), False)

try:
    raise KeyError(1)
except KeyError as module_level_err:
    pass
check("except-as at module level", "module_level_err" in globals(), False)

def exc_nested_same_name():
    try:
        raise ValueError(1)
    except ValueError as e:
        try:
            raise KeyError(2)
        except KeyError as e:
            pass
        r = "e" in locals()
    return [r, "e" in locals()]
check("except-as: nested clauses with the same name", exc_nested_same_name(), [False, False])

# ── globals() is the live module dict; __main__ is the real main module ─────
g = globals()
g["gx_live"] = 1
check("globals()[name] = v creates a global", gx_live, 1)
g["gx_live"] = 2
check("globals()[name] = v rebinds it", gx_live, 2)
del g["gx_live"]
try:
    gx_live
    check("del globals()[name] unbinds it", "bound", "NameError")
except NameError:
    check("del globals()[name] unbinds it", "NameError", "NameError")
def set_from_function():
    globals()["gy_live"] = 3
set_from_function()
check("globals() inside a function is the module's", gy_live, 3)
check("globals() is globals()", globals() is globals(), True)
check("globals() is a dict", [isinstance(globals(), dict), type(globals()).__name__], [True, "dict"])
check("globals() reads", ["gy_live" in globals(), globals()["gy_live"], globals().get("nope", "d"), len(globals()) > 5],
      [True, 3, "d", True])
gz_live = 7
check("a new global shows in an old globals()", g["gz_live"], 7)
g.update({"gu1": 1, "gu2": 2})
check("globals().update", [gu1, gu2], [1, 2])
check("globals().setdefault / pop", [g.setdefault("gu3", 33), gu3, g.pop("gu3"), "gu3" in g], [33, 33, 33, False])
exec("gq_exec = 5", globals())
check("exec(src, globals()) binds globals", gq_exec, 5)
def exec_in_function():
    exec("gq_exec2 = 6", globals())
exec_in_function()
check("exec(src, globals()) from a function binds globals", gq_exec2, 6)
check("eval(src, globals())", eval("gq_exec + gq_exec2", globals()), 11)
check("locals() at module level is globals()", locals() is globals(), True)
main = sys.modules["__main__"]
setattr(main, "gm_attr", 4)
check("setattr(sys.modules['__main__'], ...) makes a global", gm_attr, 4)
main.gm_attr2 = 5
check("__main__.x = v makes a global", gm_attr2, 5)
del main.gm_attr2
check("del __main__.x unbinds it", "gm_attr2" in globals(), False)
check("__main__'s attributes are the globals", [main.__name__, main.gy_live, getattr(main, "nope", "d")], ["__main__", 3, "d"])
check("vars(__main__) is globals()", vars(main) is globals(), True)
check("__main__.__dict__ is globals()", main.__dict__ is globals(), True)
def fglobals():
    pass
check("f.__globals__ is globals()", fglobals.__globals__ is globals(), True)
ns = {}
exec("gg = globals()", ns)
check("globals() in exec(src, ns) is ns", ns["gg"] is ns, True)
import collections
od_locals = collections.OrderedDict(a=1)
exec("w = a + 4\nv = 2", {}, od_locals)
check("exec(src, g, a dict subclass) binds through it", [od_locals.get("w"), list(od_locals)], [5, ["a", "w", "v"]])
class LogDict(dict):
    def __setitem__(self, k, v):
        dict.__setitem__(self, k, v * 10)
ld99 = LogDict(base=1)
exec("got = base + 1", ld99)
check("exec(src, a dict subclass as globals)", ld99.get("got"), 20)
import builtins
check("import builtins is the builtin module (a builtins.ny beside the script is not)",
      [builtins.__name__, hasattr(builtins, "print")], ["builtins", True])

# ── __spec__ / __loader__; sys.meta_path and sys.path_hooks ──────────────────
import json, collections
import importlib.machinery, importlib.util, importlib.abc
import textwrap
check("a module's __spec__",
      [type(textwrap.__spec__).__name__, textwrap.__spec__.name, textwrap.__spec__.origin == textwrap.__file__,
       textwrap.__spec__.parent, textwrap.__spec__.has_location],
      ["ModuleSpec", "textwrap", True, "", True])
check("a module's __loader__", [textwrap.__loader__ is textwrap.__spec__.loader, type(textwrap.__loader__).__name__],
      [True, "SourceFileLoader"])
check("a package's __spec__",
      [collections.__spec__.name, collections.__spec__.submodule_search_locations == collections.__path__,
       collections.__spec__.parent],
      ["collections", True, "collections"])
check("the program's __spec__", __spec__, None)
check("sys.meta_path's defaults", [len(sys.meta_path) >= 2, all(hasattr(f, "find_spec") for f in sys.meta_path)], [True, True])

class VirtFinder:
    def __init__(self):
        self.asked = []
    def find_spec(self, name, path, target=None):
        self.asked.append(name)
        if name == "virt_mod_99":
            return importlib.util.spec_from_loader(name, VirtLoader())
        return None
class VirtLoader(importlib.abc.Loader):
    def create_module(self, spec):
        return None
    def exec_module(self, module):
        module.value = 42
        module.hello = lambda: "hi"
vf = VirtFinder()
sys.meta_path.insert(0, vf)
import virt_mod_99
check("a finder put first on sys.meta_path supplies a module",
      [virt_mod_99.value, virt_mod_99.hello(), virt_mod_99.__name__, virt_mod_99.__spec__.name,
       type(virt_mod_99.__loader__).__name__, "virt_mod_99" in sys.modules],
      [42, "hi", "virt_mod_99", "virt_mod_99", "VirtLoader", True])
from virt_mod_99 import value as virt_value
import virt_mod_99
check("imported once; from-import of it", [virt_value, vf.asked.count("virt_mod_99")], [42, 1])
sys.meta_path.remove(vf)
try:
    import no_such_module_99
    check("ModuleNotFoundError after the finders", "imported", "MNF")
except ModuleNotFoundError as e:
    check("ModuleNotFoundError after the finders", e.name, "no_such_module_99")

class LastFinder:
    def find_spec(self, name, path, target=None):
        if name == "last_mod_99":
            return importlib.util.spec_from_loader(name, VirtLoader())
        return None
sys.meta_path.append(LastFinder())
import last_mod_99
import json as json_again
check("a finder at the end only sees what the others did not find", [last_mod_99.value, json_again is json], [42, True])
sys.meta_path.pop()

hook_dir = os.path.join(tmpdir, "hooked99")
class HookFinder:
    def __init__(self, path):
        if not path.endswith("hooked99"):
            raise ImportError("not mine")
        self.path = path
    def find_spec(self, name, target=None):
        if name == "hooked_mod_99":
            return importlib.util.spec_from_loader(name, HookLoader())
        return None
class HookLoader(importlib.abc.Loader):
    def create_module(self, spec):
        return None
    def exec_module(self, module):
        module.v = "from the hook"
sys.path_hooks.insert(0, HookFinder)
sys.path.insert(0, hook_dir)
import hooked_mod_99
check("sys.path_hooks: a hook's finder supplies a module", hooked_mod_99.v, "from the hook")
check("sys.path_importer_cache keeps the hook's finder", type(sys.path_importer_cache[hook_dir]).__name__, "HookFinder")
sys.path_hooks.remove(HookFinder)
sys.path.pop(0)

# ── attribute hooks assigned after instances stored attributes ──────────────
class Late:
    pass
late = Late()
late.x = 1
hook_log = []
def late_setattr(self, k, v):
    hook_log.append("set " + k)
    object.__setattr__(self, k, v)
Late.__setattr__ = late_setattr
late.y = 2
def late_delattr(self, k):
    hook_log.append("del " + k)
    object.__delattr__(self, k)
Late.__delattr__ = late_delattr
del late.y
def late_getattribute(self, k):
    hook_log.append("get " + k)
    return object.__getattribute__(self, k)
Late.__getattribute__ = late_getattribute
late_x = late.x
check("hooks assigned to the class later are called", [late_x, hook_log], [1, ["set y", "del y", "get x"]])
del Late.__getattribute__
del Late.__setattr__
del Late.__delattr__
late.z = 3
late_z = late.z
del late.z
check("hooks deleted from the class are no longer called", [late_z, hook_log], [3, ["set y", "del y", "get x"]])
class LateBase:
    pass
class LateSub(LateBase):
    pass
ls = LateSub()
ls.a = 1
LateBase.__setattr__ = late_setattr
ls.b = 2
check("a hook assigned to a base class later", hook_log[-1], "set b")
del LateBase.__setattr__

# ── a list iterator reads the live list ─────────────────────────────────────
def live_loops():
    out = []
    a = [1, 2, 3]
    for x in a:
        out.append(x)
        if x < 3 and len(a) < 6:
            a.append(x + 10)
    b = [1, 2, 3, 4, 5]
    seen = []
    for x in b:
        seen.append(x)
        if len(b) > 2:
            b.pop()
    s = [3, 1, 2]
    sorted_seen = []
    for x in s:
        sorted_seen.append(x)
        s.sort()
    return [out, seen, sorted_seen]
check("for over a list sees appends, pops and sorts", live_loops(), [[1, 2, 3, 11, 12], [1, 2, 3], [3, 2, 3]])
def live_iter():
    c = [1, 2, 3]
    it = iter(c)
    c.append(4)
    r1 = list(it)
    it = iter(c)
    next(it)
    c.clear()
    r2 = list(it)
    c = [1, 2]
    it = iter(c)
    r3 = [list(it), list(it)]
    c.append(3)
    r4 = list(it)
    return [r1, r2, r3, r4]
check("iter(list) is live; exhausted it stays exhausted", live_iter(), [[1, 2, 3, 4], [], [[1, 2], []], []])
def live_enumerate():
    d = [0, 1, 2, 3]
    out = []
    for i, x in enumerate(d):
        out.append(x)
        if i == 0:
            d.append(9)
    return out
check("enumerate over a growing list", live_enumerate(), [0, 1, 2, 3, 9])
def live_gen():
    l = [1, 2]
    for x in l:
        yield x
        if x < 100:
            l.append(x * 10)
check("a generator's loop over a list it grows", list(live_gen())[:6], [1, 2, 10, 20, 100, 200])
def live_hot(n):
    # long enough for the loop to be specialized (round 80's FOR_ITER_LIST)
    total = 0
    for k in range(n):
        l = [1, 2, 3]
        for x in l:
            total += x
            if len(l) < 5:
                l.append(0)
    return total
check("a specialized list loop stays live", live_hot(200), 1200)
check("a tuple loop", [x * 2 for x in (1, 2, 3)], [2, 4, 6])
def remove_while_iterating():
    l = [1, 2, 3, 4, 5, 6]
    for x in l:
        if x % 2 == 0:
            l.remove(x)
    return l
check("removing while iterating skips as in CPython", remove_while_iterating(), [1, 3, 5])

# ── calling a class with arguments it does not take ──────────────────────────
class NoArgs:
    pass
def err_of(f):
    try:
        f()
        return "no error"
    except TypeError as e:
        return str(e)
check("P(1, 2) with no __init__ or __new__", err_of(lambda: NoArgs(1, 2)), "NoArgs() takes no arguments")
check("P(x=1)", err_of(lambda: NoArgs(x=1)), "NoArgs() takes no arguments")
check("P() still works", type(NoArgs()).__name__, "NoArgs")
class FromObject(object):
    pass
check("class C(object): C(1)", err_of(lambda: FromObject(1)), "FromObject() takes no arguments")
check("object(1)", err_of(lambda: object(1)), "object() takes no arguments")
class OwnNew:
    def __new__(cls, *a):
        return object.__new__(cls)
check("a class with its own __new__ takes them", type(OwnNew(1, 2)).__name__, "OwnNew")
class OwnInit:
    def __init__(self, a):
        self.a = a
check("a class with its own __init__ takes them", OwnInit(5).a, 5)
class InitPassesUp:
    def __init__(self, a):
        super().__init__(a)
check("object.__init__ given arguments by an __init__",
      err_of(lambda: InitPassesUp(1)), "object.__init__() takes exactly one argument (the instance to initialize)")
class NewPassesUp:
    def __new__(cls, a):
        return super().__new__(cls, a)
check("object.__new__ given arguments by a __new__",
      err_of(lambda: NewPassesUp(1)), "object.__new__() takes exactly one argument (the type to instantiate)")
class BothOwn:
    def __new__(cls, a):
        return super().__new__(cls)
    def __init__(self, a):
        self.a = a
check("__new__ and __init__ both taking it", BothOwn(3).a, 3)
class InheritsInit(OwnInit):
    pass
check("an inherited __init__ takes them", InheritsInit(6).a, 6)
class ExcNoInit(Exception):
    pass
check("an exception class takes any arguments", ExcNoInit(1, 2).args, (1, 2))
class IntSub(int):
    pass
check("a builtin subclass takes its type's arguments", [IntSub(5), IntSub("7")], [5, 7])
class ListSub(list):
    pass
check("a list subclass", ListSub((1, 2)), [1, 2])
class WithInitSubclass:
    def __init_subclass__(cls, **kw):
        cls.tag = kw.get("tag")
class Tagged(WithInitSubclass, tag="t"):
    pass
check("class keywords still reach __init_subclass__", Tagged.tag, "t")
check("a NoArgs subclass with its own __init__", err_of(lambda: type("Sub", (NoArgs,), {"__init__": lambda self, a: None})(1)), "no error")

# ── the default repr ─────────────────────────────────────────────────────────
class Plain:
    pass
pl = Plain()
r = repr(pl)
check("the default repr is <module.Qualname object at 0x...>",
      [r.startswith("<__main__.Plain object at 0x"), r.endswith(">"), r == str(pl), r == object.__repr__(pl)],
      [True, True, True, True])
check("the address is id()'s", r == "<__main__.Plain object at " + hex(id(pl)) + ">", True)
class Outer:
    class Inner:
        pass
check("a nested class's qualname", repr(Outer.Inner()).startswith("<__main__.Outer.Inner object at 0x"), True)
def make_local():
    class Local:
        pass
    return Local()
check("a class in a function", repr(make_local()).startswith("<__main__.make_local.<locals>.Local object at 0x"), True)
class OwnModule:
    __module__ = "elsewhere"
check("a class's own __module__", repr(OwnModule()).startswith("<elsewhere.OwnModule object at 0x"), True)
check("in a container", repr([pl]) == "[" + r + "]", True)
check("in an f-string and format()", [f"{pl}" == r, format(pl) == r, "%s" % (pl,) == r], [True, True, True])
class OnlyStr:
    def __str__(self):
        return "S"
check("__str__ alone leaves repr the default", [str(OnlyStr()), repr(OnlyStr()).startswith("<__main__.OnlyStr object at")], ["S", True])

# ── a trace function moves a frame to another line (f_lineno) ───────────────
def jump_run(func, jump_from, jump_to, event="line"):
    out = []
    first = func.__code__.co_firstlineno
    state = {"done": False, "err": None}
    lines = []
    def tracer(frame, ev, arg):
        if frame.f_code is not func.__code__:
            return None
        if ev == "line":
            lines.append(frame.f_lineno - first)
        if not state["done"] and ev == event and frame.f_lineno - first == jump_from:
            state["done"] = True
            try:
                frame.f_lineno = first + jump_to
            except ValueError as e:
                state["err"] = str(e)
        return tracer
    sys.settrace(tracer)
    try:
        func(out)
    finally:
        sys.settrace(None)
    return [out, state["err"], lines]

def j_forward(out):
    out.append(1)
    out.append(2)
    out.append(3)
    out.append(4)
check("jump forward", jump_run(j_forward, 1, 3), [[3, 4], None, [1, 4]])

def j_backward(out):
    out.append(1)
    out.append(2)
    if len(out) < 5:
        out.append(4)
    out.append(5)
check("jump backward", jump_run(j_backward, 5, 2), [[1, 2, 4, 2, 4, 5], None, [1, 2, 3, 4, 5, 3, 4, 5]])

def j_out_of_loop(out):
    for i in range(3):
        out.append(i)
        out.append(10)
    out.append(4)
check("jump out of a for loop", jump_run(j_out_of_loop, 3, 4), [[0, 4], None, [1, 2, 3]])

def j_into_loop(out):
    out.append(1)
    for i in range(3):
        out.append(i)
    out.append(4)
check("no jump into a for loop", jump_run(j_into_loop, 1, 3),
      [[1, 0, 1, 2, 4], "can't jump into the body of a for loop", [1, 2, 3, 2, 3, 2, 3, 2, 4]])

def j_into_if(out):
    out.append(1)
    if len(out) > 5:
        out.append(3)
    out.append(4)
check("jump into an if body", jump_run(j_into_if, 1, 3), [[3, 4], None, [1, 4]])

def j_into_while(out):
    n = 0
    out.append(2)
    while n < 1:
        out.append(4)
        n += 1
    out.append(6)
check("jump into a while body", jump_run(j_into_while, 2, 4), [[4, 6], None, [1, 2, 5, 3, 6]])

def j_into_except(out):
    out.append(1)
    try:
        out.append(3)
    except ValueError:
        out.append(5)
    out.append(6)
check("no jump into an except block", jump_run(j_into_except, 1, 5),
      [[1, 3, 6], "can't jump into an 'except' block as there's no exception", [1, 2, 3, 6]])

def j_into_try(out):
    out.append(1)
    try:
        out.append(3)
        out.append(4)
    except ValueError:
        out.append(6)
    out.append(7)
check("jump into a try body", jump_run(j_into_try, 1, 4), [[4, 7], None, [1, 7]])

def j_out_of_except(out):
    try:
        raise ValueError
    except ValueError:
        out.append(4)
        out.append(5)
    out.append(6)
check("jump out of an except block", jump_run(j_out_of_except, 4, 6), [[6], None, [1, 2, 3, 4]])

def j_into_finally(out):
    out.append(1)
    try:
        out.append(3)
    finally:
        out.append(5)
    out.append(6)
check("jump into a finally block", jump_run(j_into_finally, 1, 5), [[5, 6], None, [1, 6]])

def j_out_of_finally(out):
    try:
        out.append(2)
    finally:
        out.append(4)
        out.append(5)
    out.append(6)
check("jump out of a finally block", jump_run(j_out_of_finally, 4, 6), [[2, 6], None, [1, 2, 4]])

def j_into_with(out):
    import contextlib
    out.append(2)
    with contextlib.nullcontext():
        out.append(4)
    out.append(5)
jw = jump_run(j_into_with, 2, 4)
check("no jump into a with block", [jw[0], jw[1] is not None, jw[2]], [[2, 4, 5], True, [1, 2, 3, 4, 3, 5]])

def j_before(out):
    out.append(1)
jb = jump_run(j_before, 1, -1)
check("no jump before the code block", [jb[0], jb[1].endswith("comes before the current code block")], [[1], True])

def j_after(out):
    out.append(1)
ja = jump_run(j_after, 1, 100)
check("no jump after the code block", [ja[0], ja[1].endswith("comes after the current code block")], [[1], True])

def j_blank(out):
    out.append(1)

    out.append(3)
    out.append(4)
check("a jump to a blank line goes to the next line", jump_run(j_blank, 1, 2), [[3, 4], None, [1, 4]])

def j_from_call(out):
    out.append(1)
    out.append(2)
check("no jump from a call event", jump_run(j_from_call, 0, 2, "call"),
      [[1, 2], "can't jump from the 'call' trace event of a new frame", [1, 2]])

def j_from_return(out):
    out.append(1)
    out.append(2)
check("no jump from a return event", jump_run(j_from_return, 2, 1, "return"),
      [[1, 2], "can only jump from a 'line' trace event", [1, 2]])

def j_nested_loops(out):
    for i in range(2):
        for j in range(2):
            out.append(i * 10 + j)
            out.append(-1)
    out.append(5)
check("jump out of two loops", jump_run(j_nested_loops, 4, 5), [[0, 5], None, [1, 2, 3, 4]])

def j_try_else(out):
    try:
        out.append(2)
    except ValueError:
        out.append(4)
    else:
        out.append(6)
    out.append(7)
check("jump into a try's else", jump_run(j_try_else, 2, 6), [[6, 7], None, [1, 2, 7]])

def j_loop_header(out):
    for i in range(3):
        out.append(i)
        out.append(-1)
    out.append(4)
check("jump back to a for loop's header starts it again", jump_run(j_loop_header, 3, 1),
      [[0, 0, -1, 1, -1, 2, -1, 4], None, [1, 2, 3, 2, 3, 1, 2, 3, 1, 2, 3, 1, 4]])

def j_in_loop_body(out):
    for i in range(2):
        out.append(i)
        out.append(-1)
        out.append(-2)
    out.append(5)
check("jump forward inside a loop body", jump_run(j_in_loop_body, 2, 4), [[-2, 1, -1, -2, 5], None, [1, 2, 1, 2, 3, 4, 1, 5]])

try:
    sys._getframe().f_lineno = 3
    check("f_lineno outside a trace function", "no error", "ValueError")
except ValueError:
    check("f_lineno outside a trace function", "ValueError", "ValueError")

# pdb's jump command
pdb_prog = '''import pdb, sys
def f():
    out = []
    pdb.set_trace()
    out.append(1)
    out.append(2)
    out.append(3)
    return out
print("RESULT", f())
'''
pdb_out = run_child([], pdb_prog, "jump 7\ncontinue\n")
check("pdb's jump command", [l[l.index("RESULT"):] for l in pdb_out.splitlines() if "RESULT" in l], ["RESULT [3]"])

# ── sys: getrefcount, stdlib_module_names, displayhook, -OO ──────────────────
rc_obj = []
rc_a = sys.getrefcount(rc_obj)
rc_alias = rc_obj
rc_b = sys.getrefcount(rc_obj)
del rc_alias
rc_c = sys.getrefcount(rc_obj)
check("sys.getrefcount counts references", [rc_a >= 2, rc_b - rc_a, rc_c - rc_a], [True, 1, 0])
def rc_in_list():
    o = object()
    before = sys.getrefcount(o)
    holder = [o, o, o]
    return sys.getrefcount(o) - before
check("sys.getrefcount: references held by a list", rc_in_list(), 3)
check("sys.getrefcount of a small int is large", sys.getrefcount(1) > 100, True)
check("sys.stdlib_module_names",
      [type(sys.stdlib_module_names).__name__, "json" in sys.stdlib_module_names, "os" in sys.stdlib_module_names,
       "collections" in sys.stdlib_module_names, "sys" in sys.stdlib_module_names, "no_such_mod" in sys.stdlib_module_names],
      ["frozenset", True, True, True, True, False])
check("sys.displayhook is the default", sys.displayhook is sys.__displayhook__, True)
import io
dh_buf = io.StringIO()
dh_old = sys.stdout
sys.stdout = dh_buf
try:
    sys.displayhook(5)
    sys.displayhook(None)
    sys.displayhook("s")
finally:
    sys.stdout = dh_old
check("sys.displayhook writes the repr, skips None", dh_buf.getvalue(), "5\n's'\n")
check("sys.displayhook keeps the value in _", _, "s")

prompt_out = run_child(["-q", "-i"], "import sys\n",
                       "sys.displayhook = lambda v: print('HOOK', 'NONE' if v is None else repr(v))\n1+1\nNone\n'x'\n")
check("the interactive prompt calls sys.displayhook",
      [l.replace(">>> ", "").strip() for l in prompt_out.splitlines() if "HOOK" in l],
      ["HOOK 2", "HOOK NONE", "HOOK 'x'"])

oo_prog = '''import sys
def f():
    "doc of f"
class K:
    "doc of K"
print(str(f.__doc__ is None) + " " + str(K.__doc__ is None) + " " + str(f.__doc__) + " " + str(sys.flags.optimize))
'''
check("-OO drops docstrings", run_child(["-OO"], oo_prog).strip().lower(), "true true none 2")
check("-O keeps them", run_child(["-O"], oo_prog).strip().lower(), "false false doc of f 1")

# ── deep recursion under a raised recursion limit ───────────────────────────
old_limit = sys.getrecursionlimit()
sys.setrecursionlimit(5000)
def deep(n):
    if n == 0:
        return 0
    return 1 + deep(n - 1)
class DeepObj:
    def down(self, n):
        return 0 if n == 0 else 1 + self.down(n - 1)
def deep_gen(n):
    if n > 0:
        yield from deep_gen(n - 1)
    yield n
try:
    deep_results = [deep(3000), DeepObj().down(3000), sum(1 for _ in deep_gen(400))]
except RecursionError:
    deep_results = "RecursionError"
check("3000 frames deep with sys.setrecursionlimit(5000)", deep_results, [3000, 3000, 401])
def too_deep(n):
    return too_deep(n + 1)
try:
    too_deep(0)
    check("past the limit is still a RecursionError", "no error", "RecursionError")
except RecursionError:
    check("past the limit is still a RecursionError", "RecursionError", "RecursionError")
sys.setrecursionlimit(old_limit)
import threading
thread_res = []
def deep_in_thread():
    sys.setrecursionlimit(5000)
    try:
        thread_res.append(deep(3000))
    except RecursionError:
        thread_res.append("RecursionError")
t = threading.Thread(target=deep_in_thread)
t.start()
t.join()
sys.setrecursionlimit(old_limit)
check("3000 frames deep in a thread", thread_res, [3000])

# ── more of this kind: frame globals, sets, function reprs, __class__ ──────
def caller_globals():
    return sys._getframe(1).f_globals
check("f_globals is globals()", [sys._getframe().f_globals is globals(), caller_globals() is globals()], [True, True])
def inject(name, value):
    sys._getframe(1).f_globals[name] = value
inject("fg_injected", 41)
check("sys._getframe(1).f_globals[name] = v binds a global", fg_injected + 1, 42)
check("a module function's __globals__ is its module's namespace",
      textwrap.TextWrapper.__init__.__globals__ is vars(textwrap), True)
set99 = {1, 2, 3}
def grow_set():
    for x in set99:
        set99.add(x + 10)
try:
    grow_set()
    check("a set changed during iteration", "no error", "RuntimeError: Set changed size during iteration")
except RuntimeError as e:
    check("a set changed during iteration", "RuntimeError: " + str(e), "RuntimeError: Set changed size during iteration")
seen99 = []
for x in {5, 6}:
    seen99.append(x)
check("a set iterated without change", sorted(seen99), [5, 6])
shrink99 = {1, 2, 3}
try:
    for x in shrink99:
        shrink99.discard(3)
    check("a set shrunk during iteration", "no error", "RuntimeError")
except RuntimeError:
    check("a set shrunk during iteration", "RuntimeError", "RuntimeError")
def plain99():
    pass
class R99:
    def m(self):
        return __class__
    @staticmethod
    def s():
        pass
def outer99():
    def inner():
        pass
    return inner
check("function reprs are CPython's",
      [repr(plain99) == "<function plain99 at " + hex(id(plain99)) + ">",
       repr(R99.m).startswith("<function R99.m at 0x"), repr(R99.s).startswith("<function R99.s at 0x"),
       repr(outer99()).startswith("<function outer99.<locals>.inner at 0x"), str(plain99) == repr(plain99)],
      [True, True, True, True, True])
check("__class__ in a method is its class", R99().m() is R99, True)
class R99Sub(R99):
    pass
check("__class__ is the defining class, not the instance's", R99Sub().m() is R99, True)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT99 PASSED ===")
