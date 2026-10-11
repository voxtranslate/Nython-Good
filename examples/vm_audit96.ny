# vm_audit96.ny - the correctness gaps rounds 78-79 found, both engines
# (round 80): two interpreter crashes, object's members on every class,
# builtin exceptions' module, except <expression>, numeric hashes across
# int/float/Fraction/Decimal, dataclass(slots=True), __import__ /
# sys.modules / importlib, relative imports, sys's facts (version_info, hash_info, float_info,
# flags, recursion limit, getsizeof, intern, switch interval, prefix,
# __debug__), sys.excepthook, exec/eval namespaces, locals() with dunder
# names, a live os.environ,
# threading._register_atexit, str.maketrans / translate, and `${` in a
# Python-mode file.
#
# nython: python    (this file's "${...}" literals are Python's text)
#
# The whole file runs under python3 as well (`python3 examples/vm_audit96.ny`);
# every expected value is CPython's, except the few checks marked Nython-only.
#
#     ./build/nython-cli examples/vm_audit96.ny
#     ./build/nython-cli --vm examples/vm_audit96.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import sys
import types
import tempfile
import shutil
import subprocess
import importlib
import importlib.util
import importlib.machinery
import string
import json
import math
import dataclasses
from fractions import Fraction
from decimal import Decimal

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def raises(f):
    # the exception's class name and message, or "no error"
    try:
        f()
    except BaseException as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

TMP = tempfile.mkdtemp(prefix="vm_audit96_" + str(os.getpid()) + "_")
# a child process runs on the engine this file runs on
ENGINE = [sys.executable] + (["--vm"] if nython and "--vm" in sys.orig_argv else [])
EXT = ".ny" if nython else ".py"

def write_module(name, text):
    path = os.path.join(TMP, name + EXT)
    with open(path, "w") as f:
        f.write(text)
    return path

# ── the two interpreter crashes ─────────────────────────────────────────────
class GA:
    __class_getitem__ = classmethod(types.GenericAlias)

ga = GA[int]
check("classmethod(GenericAlias) as __class_getitem__",
      [repr(ga), ga.__origin__ is GA, ga.__args__, repr(GA[int, str])],
      ["__main__.GA[int]", True, (int,), "__main__.GA[int, str]"])

def _gen3():
    yield 1
    yield 2
    yield 3
_g = _gen3()

class GenNext:
    __next__ = _g.__next__
    def __iter__(self):
        return self

check("a generator's bound __next__ as a class attribute", [GenNext.__next__(), list(GenNext())], [1, [2, 3]])

class Holder:
    pass
hd = Holder()
hd.nx = iter([7, 8]).__next__
check("a bound __next__ held by an instance", [hd.nx(), hd.nx()], [7, 8])

class StrAttr:
    label = "text"
check("calling a class's str attribute", raises(lambda: StrAttr.label()), "TypeError: 'str' object is not callable")

# ── object's members on a class naming no base ──────────────────────────────
class P:
    pass

class Base:
    pass

class Derived(Base):
    def __init__(self):
        Base.__init__(self)
        self.x = 1

p = P()
check("object's members reach a class without a base",
      [hasattr(p, "__setattr__"), hasattr(P, "__new__"), hasattr(P, "__init__"), hasattr(P, "__eq__"),
       hasattr(P, "__hash__"), hasattr(P, "__init_subclass__"), hasattr(P, "__repr__"), hasattr(P, "__str__"),
       hasattr(p, "__ne__"), hasattr(p, "__format__"), hasattr(p, "__reduce_ex__"), hasattr(P, "__subclasshook__")],
      [True] * 12)
check("Base.__init__(self) when Base defines none", Derived().x, 1)
check("they are object's", [P.__new__ is object.__new__, P.__init__ is object.__init__, P.__eq__ is object.__eq__,
                            P.__repr__ is object.__repr__, P.__hash__ is object.__hash__],
      [True, True, True, True, True])
p.__setattr__("y", 5)
check("p.__setattr__ / __getattribute__ / __delattr__", [p.y, p.__getattribute__("y"), raises(lambda: p.__delattr__("y")), hasattr(p, "y")],
      [5, 5, "no error", False])
check("object.__eq__ / __ne__ / ordering", [P.__eq__(p, p), P.__eq__(p, P()), P.__ne__(p, p), P.__ne__(p, P()),
                                            P.__lt__(p, p), p.__ge__(p)],
      [True, NotImplemented, False, NotImplemented, NotImplemented, NotImplemented])
check("object.__hash__ is the identity hash", [object.__hash__(p) == hash(p), P.__hash__(p) == hash(p)], [True, True])
check("object.__repr__ / __str__", [object.__repr__(p).startswith("<__main__.P object at 0x"), P.__str__(p) == P.__repr__(p),
                                    object.__repr__(p).endswith(">")],
      [True, True, True])
check("object.__format__", [object.__format__(p, "") == str(p), raises(lambda: object.__format__(p, "x"))],
      [True, "TypeError: unsupported format string passed to P.__format__"])
check("P.__new__(P) makes an instance; __init_subclass__ is bound", [type(P.__new__(P)) is P, P.__init_subclass__()], [True, None])

class SuperEq:
    def __eq__(self, other):
        return super().__eq__(other)
    def __hash__(self):
        return super().__hash__()
    def __repr__(self):
        return "S" + super().__repr__()[1:2]
se = SuperEq()
check("super() reaches object's members", [se == se, se == SuperEq(), hash(se) == object.__hash__(se), repr(se)],
      [True, False, True, "S_"])

class WithGetattr:
    def __getattr__(self, name):
        return "ga:" + name
wg = WithGetattr()
check("object's members win over __getattr__", [wg.zz, callable(wg.__setattr__), wg.__init__ is not None], ["ga:zz", True, True])

# ── builtin exception classes are builtins' ─────────────────────────────────
check("builtin exceptions' module and names",
      [KeyError.__module__, ValueError.__module__, OSError.__module__, object.__module__, KeyError.__qualname__,
       repr(KeyError), repr(ZeroDivisionError), StopIteration.__name__],
      ["builtins", "builtins", "builtins", "builtins", "KeyError", "<class 'KeyError'>",
       "<class 'ZeroDivisionError'>", "StopIteration"])
class MyError(Exception):
    pass
check("a program's exception is its module's", [MyError.__module__, repr(MyError)], ["__main__", "<class '__main__.MyError'>"])

# ── ImportError / AttributeError / NameError keyword fields (3.10+) ─────────
ie = ImportError("m", name="x", path="/p")
check("ImportError(name=, path=)", [ie.name, ie.path, ie.msg, ie.args, ImportError("a", "b").name, ImportError("a", "b").msg],
      ["x", "/p", "m", ("m",), None, None])
ae = AttributeError("x", name="n", obj=5)
check("AttributeError(name=, obj=) and NameError(name=)", [ae.name, ae.obj, NameError("x", name="q").name, AttributeError("y").name],
      ["n", 5, "q", None])
class SubImportError(ImportError):
    def __init__(self, msg, mod):
        super().__init__(msg, name=mod)
check("super().__init__(msg, name=...)", SubImportError("m", "mod").name, "mod")
def runtime_names():
    out = []
    try:
        import m96_no_such_module
    except ModuleNotFoundError as e:
        out.append(e.name)
    try:
        P().no_such_attribute
    except AttributeError as e:
        out.append(e.name)
    try:
        no_such_name_96
    except NameError as e:
        out.append(e.name)
    return out
check("the runtime's errors carry their name", runtime_names(), ["m96_no_such_module", "no_such_attribute", "no_such_name_96"])

# ── iterators' methods as values, builtins as one object each ───────────────
it = iter([1, 2])
nx = it.__next__
check("iter([..]).__next__ read as an attribute", [nx(), next(it), raises(nx)], [1, 2, "StopIteration: "])
check("f_builtins holds the builtins themselves",
      [sys._getframe(0).f_builtins["len"] is len, sys._getframe(0).f_builtins["isinstance"] is isinstance, len is len],
      [True, True, True])

# ── except <expression> ─────────────────────────────────────────────────────
class Handler:
    def __init__(self):
        self._error = ValueError
        self.errs = (KeyError, IndexError)
    def run(self, f):
        try:
            f()
        except self._error:
            return "own"
        except self.errs as e:
            return "tuple " + type(e).__name__
        except (TypeError, json.JSONDecodeError) as e:
            return "mixed " + type(e).__name__
        except:
            return "bare"
        return "none"

def raising(e):
    def f():
        raise e
    return f

h = Handler()
check("except self.attr / a tuple attribute / a dotted name",
      [h.run(raising(ValueError("x"))), h.run(raising(KeyError("k"))), h.run(raising(IndexError())),
       h.run(raising(TypeError())), h.run(raising(json.JSONDecodeError("m", "d", 0))), h.run(raising(OSError())),
       h.run(lambda: None)],
      ["own", "tuple KeyError", "tuple IndexError", "mixed TypeError", "own", "bare", "none"])

ERRS = (ZeroDivisionError, OverflowError)
def catch_errs():
    try:
        1 / 0
    except ERRS as e:
        return type(e).__name__
check("except NAME bound to a tuple", catch_errs(), "ZeroDivisionError")

errs = [ArithmeticError, LookupError]
def lookup_errors():
    return (KeyError, IndexError)
def except_forms():
    out = []
    try:
        1 / 0
    except errs[0]:
        out.append("subscript")
    try:
        {}["a"]
    except lookup_errors() as e:
        out.append("call " + type(e).__name__)
    try:
        try:
            raise OSError("x")
        except (ValueError,) + (TypeError,):
            out.append("wrong")
    except OSError as e:
        out.append("passed " + str(e))
    try:
        try:
            raise ValueError("v")
        except 42:
            out.append("never")
    except TypeError as e:
        out.append(str(e))
    try:
        raise KeyError("q")
    except (lambda: KeyError)() as e:
        out.append("lambda " + repr(e.args[0]))
    try:
        try:
            raise IndexError("deep")
        except (ValueError, (TypeError, IndexError)):
            out.append("nested tuple")
    except TypeError as e:
        out.append("no nesting")
    return out
check("except with any expression", except_forms(),
      ["subscript", "call KeyError", "passed x", "catching classes that do not inherit from BaseException is not allowed",
       "lambda 'q'", "no nesting"])

def reraise_keeps_traceback():
    try:
        try:
            raise ValueError("inner")
        except h.errs:
            return "wrong"
    except ValueError as e:
        return [str(e), e.__traceback__ is not None]
check("an unmatched expression clause re-raises the exception", reraise_keeps_traceback(), ["inner", True])

def except_then_else_finally():
    log = []
    for exc in [None, KeyError("a")]:
        try:
            if exc is not None:
                raise exc
            log.append("body")
        except h.errs:
            log.append("caught")
        else:
            log.append("else")
        finally:
            log.append("finally")
    return log
check("expression clauses with else and finally", except_then_else_finally(),
      ["body", "else", "finally", "caught", "finally"])

def bound_name_in_clause():
    try:
        raise KeyError("z")
    except h.errs as err:
        inside = [type(err).__name__, sys.exc_info()[0] is KeyError, sys.exc_info()[1] is err]
    return inside + [sys.exc_info()[0] is None]
check("the clause's name and sys.exc_info() in and after it", bound_name_in_clause(), ["KeyError", True, True, True])

# ── numeric hashes agree across int, float, Fraction and Decimal ────────────
check("a Decimal and an equal float are one set member",
      [len({Decimal("0.5"), 0.5}), len({0.5, Decimal("0.5")}), len({Decimal(1), 1, 1.0, Fraction(1)}),
       len({Fraction(1, 2), 0.5, Decimal("0.5")}), len({Decimal("0.1"), 0.1})],
      [1, 1, 1, 1, 2])
d = {0.5: "f", 10 ** 30: "big"}
check("dict lookups across numeric types",
      [d[Decimal("0.5")], d[Fraction(1, 2)], d[Decimal(10) ** 30], Decimal("2.5") in {2.5: 1}, Fraction(3, 4) in {0.75}],
      ["f", "f", "big", True, True])
check("the hashes themselves", [hash(Decimal("0.5")) == hash(0.5), hash(Fraction(1, 2)) == hash(0.5),
                                hash(Decimal("1e30")) == hash(10 ** 30), hash(Decimal("-2")) == hash(-2)],
      [True, True, True, True])

# ── dataclass(slots=True) rebuilds the class ────────────────────────────────
@dataclasses.dataclass(slots=True)
class Pt:
    x: int
    y: int = 0

pt = Pt(1)
check("slots dataclass", [Pt.__slots__, hasattr(pt, "__dict__"), repr(pt), pt == Pt(1, 0), type(Pt.__dict__["x"]).__name__],
      [("x", "y"), False, "Pt(x=1, y=0)", True, "member_descriptor"])
check("slots dataclass refuses other attributes", raises(lambda: setattr(pt, "z", 3)),
      "AttributeError: 'Pt' object has no attribute 'z'")
pt.y = 7
check("its fields are settable", [pt.y, dataclasses.astuple(pt), [f.name for f in dataclasses.fields(Pt)]], [7, (1, 7), ["x", "y"]])

@dataclasses.dataclass(slots=True, frozen=True)
class FrozenPt:
    a: int
fp = FrozenPt(2)
check("frozen slots dataclass", [raises(lambda: setattr(fp, "a", 3)), hash(fp) == hash(FrozenPt(2)),
                                 fp.__getstate__(), "__setstate__" in FrozenPt.__dict__],
      ["FrozenInstanceError: cannot assign to field 'a'", True, [2], True])
check("slots=True on a class with __slots__",
      raises(lambda: dataclasses.dataclass(slots=True)(type("Own", (), {"__slots__": ("a",), "__annotations__": {"a": int}}))),
      "TypeError: Own already specifies __slots__")

@dataclasses.dataclass(slots=True)
class Pt3(Pt):
    z: int = 0
check("a slots dataclass deriving from one", [Pt3.__slots__, repr(Pt3(1, 2, 3))], [("z",), "Pt3(x=1, y=2, z=3)"])

# ── __import__, sys.modules, importlib ──────────────────────────────────────
sys.path.insert(0, TMP)
write_module("m96_counted", "import sys\n"
                            "sys.m96_runs = getattr(sys, 'm96_runs', 0) + 1\n"
                            "VALUE = 41\n"
                            "def get():\n"
                            "    return VALUE\n")
import m96_counted
check("a module on sys.path", [m96_counted.VALUE, m96_counted.get(), sys.m96_runs], [41, 41, 1])
check("sys.modules holds it", [sys.modules["m96_counted"] is m96_counted, type(sys.modules) is dict,
                               "sys" in sys.modules, sys.modules["sys"] is sys, "json" in sys.modules,
                               sys.modules["json"] is json, "__main__" in sys.modules],
      [True, True, True, True, True, True, True])
import m96_counted as again
check("a second import is the same module", [again is m96_counted, sys.m96_runs], [True, 1])
m96_counted.lam = lambda x, y=10: x + y
check("a lambda a module holds, called", [m96_counted.lam(1), m96_counted.lam(1, y=2), json.loads.__name__], [11, 3, "loads"])
del sys.modules["m96_counted"]
import m96_counted as fresh
check("del sys.modules[name] makes import load it again", [fresh is m96_counted, sys.m96_runs, fresh.VALUE], [False, 2, 41])

fake = types.ModuleType("m96_fake")
fake.answer = 42
sys.modules["m96_fake"] = fake
import m96_fake
from m96_fake import answer
check("what sys.modules holds is what import binds", [m96_fake is fake, answer], [True, 42])

class NotAModule:
    flag = "obj"
sys.modules["m96_obj"] = NotAModule()
from m96_obj import flag
check("any object in sys.modules", flag, "obj")

check("__import__", [__import__("json") is json, __import__("xml.dom").__name__,
                     __import__("xml.dom", fromlist=["minidom"]).__name__,
                     hasattr(__import__("xml.dom", fromlist=["minidom"]), "minidom"),
                     raises(lambda: __import__("m96_does_not_exist")),
                     raises(lambda: __import__("")), raises(lambda: __import__("json", level=-1))],
      [True, "xml", "xml.dom", True, "ModuleNotFoundError: No module named 'm96_does_not_exist'",
       "ValueError: Empty module name", "ValueError: level must be >= 0"])
check("__import__ relative to a package",
      [__import__("dom", {"__package__": "xml"}, None, ["minidom"], 1).__name__,
       raises(lambda: __import__("x", {"__name__": "top"}, None, [], 1)),
       raises(lambda: __import__("x", {}, None, [], 1)),
       raises(lambda: __import__("x", {"__package__": "xml"}, None, [], 3))],
      ["xml.dom", "ImportError: attempted relative import with no known parent package",
       "KeyError: \"'__name__' not in globals\"", "ImportError: attempted relative import beyond top-level package"])

check("importlib.import_module", [importlib.import_module("json") is json,
                                  importlib.import_module(".decoder", "json").__name__,
                                  importlib.import_module("xml.dom.minidom").__name__,
                                  raises(lambda: importlib.import_module(".x")),
                                  raises(lambda: importlib.import_module("..x", "json"))],
      [True, "json.decoder", "xml.dom.minidom",
       "TypeError: the 'package' argument is required to perform a relative import for '.x'",
       "ImportError: attempted relative import beyond top-level package"])

write_module("m96_reload", "COUNT = [1]\nVALUE = 'first'\n")
import m96_reload
first_count = m96_reload.COUNT
write_module("m96_reload", "VALUE = 'second'\nNEW = True\n# a longer file than the first\n")
importlib.invalidate_caches()
r = importlib.reload(m96_reload)
check("importlib.reload runs the file again in the same module",
      [r is m96_reload, m96_reload.VALUE, m96_reload.NEW, m96_reload.COUNT is first_count],
      [True, "second", True, True])
check("reload of a non-module", raises(lambda: importlib.reload(5)), "TypeError: reload() argument must be a module")

spec_path = write_module("m96_spec", "X = 3\ndef double():\n    return X * 2\n")
spec = importlib.util.spec_from_file_location("m96_spec", spec_path)
mod = importlib.util.module_from_spec(spec)
check("module_from_spec", [mod.__name__, mod.__spec__ is spec, spec.name, spec.origin == spec_path,
                           spec.has_location, spec.parent, "m96_spec" in sys.modules],
      ["m96_spec", True, "m96_spec", True, True, "", False])
spec.loader.exec_module(mod)
check("loader.exec_module runs it", [mod.X, mod.double(), mod.__file__ == spec_path], [3, 6, True])

found = importlib.util.find_spec("json")
check("importlib.util.find_spec", [found.name, found.submodule_search_locations is not None,
                                   importlib.util.find_spec("m96_nothing_here") is None,
                                   importlib.util.find_spec("json.decoder").name,
                                   importlib.util.find_spec("m96_spec") is not None],
      ["json", True, True, "json.decoder", True])
check("importlib.util.resolve_name", [importlib.util.resolve_name(".decoder", "json"),
                                      importlib.util.resolve_name("..a", "p.q.r"), importlib.util.resolve_name("abs", None)],
      ["json.decoder", "p.q.a", "abs"])
check("importlib.machinery", [isinstance(spec, importlib.machinery.ModuleSpec),
                              isinstance(spec.loader, importlib.machinery.SourceFileLoader)],
      [True, True])

os.makedirs(os.path.join(TMP, "pkg96"))
with open(os.path.join(TMP, "pkg96", "__init__" + EXT), "w") as f:
    f.write("NAME = __name__\nPKG = __package__\n")
with open(os.path.join(TMP, "pkg96", "data.txt"), "w") as f:
    f.write("resource text")
import pkg96
import importlib.resources as resources
check("a package's __package__, __path__ and resources",
      [pkg96.NAME, pkg96.PKG, isinstance(pkg96.__path__, list),
       resources.files("pkg96").joinpath("data.txt").read_text(), resources.files(pkg96).name],
      ["pkg96", "pkg96", True, "resource text", "pkg96"])

def write_file(rel, text):
    path = os.path.join(TMP, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
write_file("rel96/__init__" + EXT, "from . import a\nfrom .a import fa as fa2\nfrom .sub import deep\nINIT = 'init'\n")
write_file("rel96/a" + EXT, "def fa():\n    return 'fa'\n_private = 1\n")
write_file("rel96/star" + EXT, "from .a import *\n")
write_file("rel96/sub/__init__" + EXT, "from .. import a\nfrom ..a import fa\nfrom . import deep\nX = fa()\n")
write_file("rel96/sub/deep" + EXT, "from .. import a as parent_a\n"
                                   "VALUE = 'deep'\n"
                                   "def beyond():\n"
                                   "    from ... import nothing\n"
                                   "def missing_module():\n"
                                   "    from .nothere import x\n"
                                   "def missing_name():\n"
                                   "    from . import nothere\n")
write_file("rel96/sub/inner/__init__" + EXT, "")
write_file("rel96/sub/inner/leaf" + EXT, "from ... import a as top_a\nfrom ...sub import X\n"
                                         "def four():\n    from .... import nothing_at_all\n")
write_module("toprel96", "def f():\n    from . import x\n")
import rel96
import rel96.star
import toprel96
check("relative imports", [rel96.INIT, rel96.a.fa(), rel96.fa2(), rel96.sub.X, rel96.sub.a is rel96.a,
                           rel96.sub.deep.VALUE, rel96.sub.deep.parent_a is rel96.a,
                           rel96.star.fa(), hasattr(rel96.star, "_private"), sys.modules["rel96.sub.deep"] is rel96.sub.deep],
      ["init", "fa", "fa", "fa", True, "deep", True, "fa", False, True])
from rel96.sub.inner import leaf
check("three and four dots", [leaf.top_a is rel96.a, leaf.X, raises(leaf.four)],
      [True, "fa", "ImportError: attempted relative import beyond top-level package"])

# ── pkgutil and runpy over importlib ────────────────────────────────────────
import pkgutil
import runpy
write_file("rel96/data.txt", "pkg data")
check("pkgutil.iter_modules", [[(m.name, m.ispkg) for m in pkgutil.iter_modules(rel96.__path__)],
                               [m.name for m in pkgutil.iter_modules(rel96.sub.__path__, "rel96.sub.")],
                               type(next(pkgutil.iter_modules(rel96.__path__)).module_finder).__name__,
                               raises(lambda: list(pkgutil.iter_modules("x")))],
      [[("a", False), ("star", False), ("sub", True)], ["rel96.sub.deep", "rel96.sub.inner"], "FileFinder",
       "ValueError: path must be None or list of paths to look for modules in"])
check("pkgutil.walk_packages", [m.name for m in pkgutil.walk_packages(rel96.__path__, "rel96.")],
      ["rel96.a", "rel96.star", "rel96.sub", "rel96.sub.deep", "rel96.sub.inner", "rel96.sub.inner.leaf"])
check("pkgutil.get_data / resolve_name", [pkgutil.get_data("rel96", "data.txt"), pkgutil.resolve_name("rel96.a:fa")(),
                                         pkgutil.resolve_name("rel96.sub.X"), pkgutil.resolve_name("rel96.sub:") is rel96.sub,
                                         raises(lambda: pkgutil.resolve_name("1bad"))],
      [b"pkg data", "fa", "fa", True, "ValueError: invalid format: '1bad'"])
check("pkgutil.get_importer / extend_path", [type(pkgutil.get_importer(TMP)).__name__, pkgutil.extend_path("x", "y"),
                                            pkgutil.extend_path([], "rel96") == rel96.__path__],
      ["FileFinder", "x", True])

write_module("run96", "import sys\nRAN = __name__\nARGV0 = sys.argv[0]\nSEEN = sys.modules.get(__name__) is not None\n"
                      "if __name__ == '__main__':\n    MAIN = True\n")
g96 = runpy.run_module("run96")
g96b = runpy.run_module("run96", run_name="__main__", init_globals={"EXTRA": 1})
check("runpy.run_module", [g96["RAN"], "MAIN" in g96, g96b["RAN"], g96b["MAIN"], g96b["EXTRA"],
                           g96["__file__"].endswith("run96" + EXT), g96["__spec__"].name, "run96" in sys.modules],
      ["run96", False, "__main__", True, 1, True, "run96", False])
argv_before = sys.argv[0]
g96c = runpy.run_module("run96", alter_sys=True)
check("run_module(alter_sys=True)", [g96c["ARGV0"].endswith("run96" + EXT), g96c["SEEN"], sys.argv[0] == argv_before,
                                     "run96" in sys.modules],
      [True, True, True, False])
check("run_module's errors", [raises(lambda: runpy.run_module("rel96")), raises(lambda: runpy.run_module("nothing96")),
                              raises(lambda: runpy.run_module(".x"))],
      ["ImportError: No module named rel96.__main__; 'rel96' is a package and cannot be directly executed",
       "ImportError: No module named nothing96", "ImportError: Relative module names not supported"])
runpath_script = write_module("runpath96", "X = 5\nNAME = __name__\n")
write_file("rundir96/__main__" + EXT, "WHO = __name__\nfrom helper96 import H\n")
write_file("rundir96/helper96" + EXT, "H = 'helper'\n")
rp = runpy.run_path(runpath_script)
rd = runpy.run_path(os.path.join(TMP, "rundir96"))
check("runpy.run_path", [rp["X"], rp["NAME"], runpy.run_path(runpath_script, run_name="named")["NAME"], rd["WHO"], rd["H"],
                         os.path.join(TMP, "rundir96") in sys.path],
      [5, "<run_path>", "named", "<run_path>", "helper", False])

write_module("broken96","import sys\nsys.broken96_runs = getattr(sys, 'broken96_runs', 0) + 1\nraise ValueError('broken')\n")
check("a module that fails is not kept", [raises(lambda: importlib.import_module("broken96")), "broken96" in sys.modules,
                                          raises(lambda: importlib.import_module("broken96")), sys.broken96_runs],
      ["ValueError: broken", False, "ValueError: broken", 2])
check("relative import errors", [raises(rel96.sub.deep.beyond), raises(toprel96.f), raises(rel96.sub.deep.missing_module),
                                 raises(rel96.sub.deep.missing_name)[:58]],
      ["ImportError: attempted relative import beyond top-level package",
       "ImportError: attempted relative import with no known parent package",
       "ModuleNotFoundError: No module named 'rel96.sub.nothere'",
       "ImportError: cannot import name 'nothere' from 'rel96.sub'"])

write_module("m96_delsys","import sys\nV = sys.maxsize > 0\ndel sys\ndef ok():\n    return V\n")
import m96_delsys
check("a module's `del sys` leaves the importer's sys", [m96_delsys.ok(), sys.maxsize > 0, hasattr(m96_delsys, "sys")],
      [True, True, False])

ns = {}
exec("import math as m", ns)
check("exec('import math as m', ns) binds m in ns", [ns["m"] is math, "sqrt" in ns, "PI" in ns], [True, False, False])
check("... and not among the program's globals", "m" in globals(), False)
zz96 = 5
check("eval(name, {}) sees only that dict and the builtins",
      [raises(lambda: eval("zz96", {})).startswith("NameError: name 'zz96' is not defined"), eval("len('ab')", {}),
       eval("zz96", {"zz96": 1})],
      [True, 2, 1])

# ── sys's facts ─────────────────────────────────────────────────────────────
vi = sys.version_info
check("sys.version_info", [type(vi).__name__, len(vi), vi[0] == vi.major, vi >= (3, 0), vi[:2] == (vi.major, vi.minor),
                           vi.releaselevel in ("alpha", "beta", "candidate", "final"), isinstance(sys.hexversion, int)],
      ["version_info", 5, True, True, True, True, True])
check("sys.implementation", [sys.implementation.name == ("nython" if nython else "cpython"),
                             len(sys.implementation.version) == 5, hasattr(sys.implementation, "cache_tag")],
      [True, True, True])
hi = sys.hash_info
check("sys.hash_info", [hi.width, hi.modulus, hi.inf, hi.imag, hash(float("inf")) == hi.inf, len(hi) == 9],
      [64, 2 ** 61 - 1, 314159, 1000003, True, True])
fi = sys.float_info
check("sys.float_info", [fi.max, fi.min, fi.epsilon, fi.dig, fi.mant_dig, fi.max_exp, fi.min_exp, fi.radix, fi.rounds,
                         fi[0] == fi.max, len(fi)],
      [1.7976931348623157e+308, 2.2250738585072014e-308, 2.220446049250313e-16, 15, 53, 1024, -1021, 2, 1, True, 11])
check("sys.int_info and sys.flags", [sys.int_info.bits_per_digit > 0, sys.flags.optimize, sys.flags.debug,
                                     isinstance(sys.flags.verbose, int), len(sys.int_info) >= 4, type(sys.flags).__name__],
      [True, 0, 0, True, True, "flags"])
check("sys.flags is read-only", raises(lambda: setattr(sys.flags, "optimize", 1))[:15], "AttributeError:")
old_limit = sys.getrecursionlimit()
check("sys.getrecursionlimit", old_limit, 1000)
sys.setrecursionlimit(1500)
check("sys.setrecursionlimit", sys.getrecursionlimit(), 1500)
def depth(n):
    return 0 if n == 0 else 1 + depth(n - 1)
sys.setrecursionlimit(1500)
check("a raised limit allows deeper recursion", depth(1050), 1050)
sys.setrecursionlimit(200)
check("a lowered limit stops it sooner", raises(lambda: depth(400))[:14], "RecursionError")
sys.setrecursionlimit(old_limit)
check("setrecursionlimit's errors", [raises(lambda: sys.setrecursionlimit(0)), raises(lambda: sys.setrecursionlimit("x"))],
      ["ValueError: recursion limit must be greater or equal than 1",
       "TypeError: 'str' object cannot be interpreted as an integer"])
class Sized:
    def __sizeof__(self):
        return 100
check("sys.getsizeof", [sys.getsizeof([1, 2]) - sys.getsizeof([]), sys.getsizeof(1.5), sys.getsizeof(0), sys.getsizeof(None),
                        sys.getsizeof(()) < sys.getsizeof((1,)), sys.getsizeof(Sized()), sys.getsizeof("ab") - sys.getsizeof("a"),
                        sys.getsizeof(b"abc") - sys.getsizeof(b"")],
      [16, 24, 28, 16, True, 132, 1, 3])
check("sys.intern", [sys.intern("ab" + "c"), raises(lambda: sys.intern(5))], ["abc", "TypeError: intern() argument must be str, not int"])
check("__debug__", __debug__, True)
opt = subprocess.run(ENGINE + ["-O", "-c", "import sys\nassert False, 'kept'\nprint(int(__debug__), sys.flags.optimize)"],
                     capture_output=True, text=True)
check("-O: __debug__ is False, asserts are dropped", opt.stdout.strip(), "0 1")
check("sys.path and sys.modules['__main__']",
      [isinstance(sys.path, list), all(isinstance(x, str) for x in sys.path), sys.modules["__main__"].zz96,
       sys.modules[__name__].zz96, sys.modules["__main__"].__name__],
      [True, True, 5, 5, "__main__"])
check("sys.getdefaultencoding and friends", [sys.getdefaultencoding(), sys.getfilesystemencoding(), sys.maxunicode],
      ["utf-8", "utf-8", 1114111])
check("sys.prefix and friends", [os.path.isdir(os.path.join(sys.prefix, "lib")), isinstance(sys.base_prefix, str),
                                 isinstance(sys.exec_prefix, str), sys.platlibdir, sys.__name__,
                                 sys.modules["os.path"] is os.path],
      [True, True, True, "lib", "sys", True])
old_si = sys.getswitchinterval()
sys.setswitchinterval(0.001)
si = sys.getswitchinterval()
sys.setswitchinterval(1e-9)
si_small = sys.getswitchinterval()
sys.setswitchinterval(old_si)
check("sys.getswitchinterval / setswitchinterval",
      [old_si, si, si_small, raises(lambda: sys.setswitchinterval(0)), raises(lambda: sys.setswitchinterval("x")),
       raises(lambda: sys.setswitchinterval(None))],
      [0.005, 0.001, 0.0, "ValueError: switch interval must be strictly positive", "TypeError: must be real number, not str",
       "TypeError: must be real number, not NoneType"])
check("object.__subclasshook__()", object.__subclasshook__() is NotImplemented, True)

# ── sys.excepthook ──────────────────────────────────────────────────────────
import io
check("sys.excepthook is sys.__excepthook__", [sys.excepthook is sys.__excepthook__, callable(sys.excepthook)], [True, True])
hook_buf = io.StringIO()
saved_stderr = sys.stderr
sys.stderr = hook_buf
try:
    raise ValueError("hooked")
except ValueError as e:
    sys.excepthook(type(e), e, e.__traceback__)
    sys.excepthook(type(e), e, None)
    hook_tb_kept = e.__traceback__ is not None
sys.excepthook(int, 2, None)
sys.stderr = saved_stderr
hook_text = hook_buf.getvalue()
check("the default hook prints the traceback on sys.stderr",
      [hook_text.startswith("Traceback (most recent call last):\n"),
       hook_text.endswith("ValueError: hooked\n"
                          "TypeError: print_exception(): Exception expected for value, int found\n"),
       hook_text.count("Traceback (most recent call last):"), hook_text.count("ValueError: hooked\n"), hook_tb_kept],
      [True, True, 2, 2, True])
hook_script = write_module("hook96", "import sys\n"
                                     "def hook(t, v, tb):\n"
                                     "    print('hook:', t.__name__, v, 'tb' if tb is not None else 'no tb')\n"
                                     "sys.excepthook = hook\n"
                                     "raise KeyError('k')\n")
hooked = subprocess.run(ENGINE + [hook_script], capture_output=True, text=True)
check("a program's sys.excepthook reports an uncaught exception", [hooked.stdout, hooked.stderr, hooked.returncode],
      ["hook: KeyError 'k' tb\n", "", 1])
bad_hook = write_module("badhook96", "import sys\n"
                                     "def hook(t, v, tb):\n"
                                     "    1 / 0\n"
                                     "sys.excepthook = hook\n"
                                     "raise KeyError('k')\n")
failed = subprocess.run(ENGINE + [bad_hook], capture_output=True, text=True)
check("a hook that fails", [failed.stderr.startswith("Error in sys.excepthook:\nTraceback (most recent call last):\n"),
                            "ZeroDivisionError: division by zero\n\nOriginal exception was:\nTraceback" in failed.stderr,
                            "KeyError: 'k'\n" in failed.stderr, failed.returncode],
      [True, True, True, 1])

# ── locals() lists user variables with dunder names ─────────────────────────
def with_dunders():
    __x__ = 1
    y = 2
    if 1 < y < 3:
        pass
    try:
        raise KeyError()
    except h.errs:
        pass
    return sorted(locals())
check("locals() keeps __x__", with_dunders(), ["__x__", "y"])
__audit_marker__ = "1"
check("globals() keeps a module's dunder names", "__audit_marker__" in globals(), True)

# ── os.environ is live ──────────────────────────────────────────────────────
KEY = "NY96_" + str(os.getpid())
os.environ[KEY] = "abc"
check("setting os.environ reaches the process environment", [os.getenv(KEY), os.environ[KEY], KEY in os.environ], ["abc", "abc", True])
child = subprocess.run([sys.executable, "-c", "import os; print(os.environ.get('" + KEY + "'))"],
                       capture_output=True, text=True)
check("... and child processes", child.stdout.strip(), "abc")
check("os.environ.get / pop / setdefault", [os.environ.get(KEY), os.environ.pop(KEY), os.getenv(KEY),
                                            os.environ.setdefault(KEY, "d"), os.getenv(KEY)],
      ["abc", "abc", None, "d", "d"])
del os.environ[KEY]
check("deleting a key unsets it", [os.getenv(KEY), KEY in os.environ, raises(lambda: os.environ[KEY])],
      [None, False, "KeyError: '" + KEY + "'"])
import collections.abc
check("os.environ is a MutableMapping, not a dict", [type(os.environ).__name__, isinstance(os.environ, collections.abc.MutableMapping),
                                                     isinstance(os.environ, dict), type(os.environ.copy()) is dict,
                                                     repr(os.environ).startswith("environ({")],
      ["_Environ", True, False, True, True])
check("its type checks", [raises(lambda: os.environ.__setitem__(KEY, 5)), raises(lambda: os.environ.__setitem__(5, "x"))],
      ["TypeError: str expected, not int", "TypeError: str expected, not int"])
os.environ.update({KEY: "u"})
import os as os_again
check("one os.environ for every import", [os_again.environ is os.environ, os_again.environ[KEY]], [True, "u"])
if os.name == "posix":
    check("os.environb", [os.environb[KEY.encode()], (KEY.encode() in os.environb)], [b"u", True])
del os.environ[KEY]

# ── threading._register_atexit (and ThreadPoolExecutor's use of it) ─────────
script = os.path.join(TMP, "atexit96.py")
with open(script, "w") as f:
    f.write("import atexit, threading, time\n"
            "from concurrent.futures import ThreadPoolExecutor\n"
            "def work():\n"
            "    time.sleep(0.3)\n"
            "    print('thread done', flush=True)\n"
            "threading._register_atexit(lambda: print('threading atexit', flush=True))\n"
            "atexit.register(lambda: print('atexit', flush=True))\n"
            "threading.Thread(target=work).start()\n"
            "pool = ThreadPoolExecutor(2)\n"
            "fut = pool.submit(lambda: time.sleep(0.2) or print('pool job', flush=True))\n"
            "print('main done', flush=True)\n")
argv = ENGINE + [script]
out = subprocess.run(argv, capture_output=True, text=True).stdout.split("\n")
check("threading atexit hooks run before the threads are joined, atexit after",
      [out[0], out[1], sorted(out[2:4]), out[4]],
      ["main done", "threading atexit", ["pool job", "thread done"], "atexit"])
import threading
check("worker threads of a pool are not daemons", raises(lambda: threading._register_atexit(print)), "no error")

# ── str.maketrans / translate, bytes.maketrans / translate ──────────────────
check("str.maketrans", [str.maketrans("ab", "xy"), str.maketrans("ab", "xy", "c"), str.maketrans({"a": "1", "b": None, 99: 100}),
                        "".maketrans("a", "b")],
      [{97: 120, 98: 121}, {97: 120, 98: 121, 99: None}, {97: "1", 98: None, 99: 100}, {97: 98}])
check("str.translate", ["abcab".translate(str.maketrans("ab", "xy", "c")), "abc".translate({97: None, 98: "BB", 99: 100}),
                        "abc".translate({}), "héllo".translate({ord("é"): "e"}), "abc".translate([None, "x"]),
                        "abc".translate(str.maketrans({"a": "☃"}))],
      ["xyxy", "BBd", "abc", "hello", "abc", "☃bc"])
class CustomTable:
    def __getitem__(self, k):
        if k == 97:
            return "A"
        raise LookupError(k)
check("translate with any mapping", "banana".translate(CustomTable()), "bAnAnA")
check("maketrans / translate errors",
      [raises(lambda: str.maketrans()), raises(lambda: str.maketrans("a")), raises(lambda: str.maketrans("ab", "c")),
       raises(lambda: str.maketrans({"ab": 1})), raises(lambda: str.maketrans({1.5: 1})), raises(lambda: str.maketrans(1, "a")),
       raises(lambda: "a".translate({97: 1.5})), raises(lambda: "a".translate({97: 0x110000})),
       raises(lambda: "a".translate())],
      ["TypeError: maketrans expected at least 1 argument, got 0",
       "TypeError: if you give only one argument to maketrans it must be a dict",
       "ValueError: the first two maketrans arguments must have equal length",
       "ValueError: string keys in translate table must be of length 1",
       "TypeError: keys in translate table must be strings or integers",
       "TypeError: first maketrans argument must be a string if there is a second argument",
       "TypeError: character mapping must return integer, None or str",
       "ValueError: character mapping must be in range(0x110000)",
       "TypeError: str.translate() takes exactly one argument (0 given)"])
table = bytes.maketrans(b"ab", b"xy")
check("bytes.maketrans / translate", [len(table), table[97:99], b"abcab".translate(table, b"c"), b"abc".translate(None, b"b"),
                                      bytearray(b"aab").translate(table)],
      [256, b"xy", b"xyxy", b"ac", bytearray(b"xxy")])

# ── `${` in a Python-mode file is Python's text ─────────────────────────────
name = "world"
tmpl = string.Template("${name} and $name")
check("string.Template with ${...} literals", [tmpl.substitute(name="x"), "${name}", r"${name}", len("${a}")],
      ["x and x", "$" + "{name}", "$" + "{name}", 4])
check("f-strings and ${", [f"${name}", f"${{name}}"], ["$world", "$" + "{name}"])
if nython:
    # Nython-only: code that is not marked Python still interpolates
    ns2 = {"v": 7}
    exec('r = "${v}"', ns2)
    check("Nython code (exec) still interpolates ${...}", ns2["r"], "7")

shutil.rmtree(TMP, ignore_errors=True)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT96 PASSED ===")
