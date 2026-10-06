# vm_audit82.ny - typing, types, inspect, keyword (round 77), both engines.
#
# The shared part runs under python3 too (`python3 examples/vm_audit82.ny`);
# every expected value there is CPython 3.11's. Nython-only checks (the
# lexer's own keywords, check_type, signature_diff, the runtime's
# type(None)) are under `if nython:`.
#
#     ./build/nython-cli examples/vm_audit82.ny
#     ./build/nython-cli --vm examples/vm_audit82.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import keyword
import types
import inspect
import typing
import functools
from typing import (Any, Optional, Union, List, Dict, Set, FrozenSet, Tuple, Type, Callable,
                    Iterable, Iterator, Sequence, Mapping, MutableMapping, Literal, Final,
                    ClassVar, Annotated, NewType, NamedTuple, TypedDict, TypeVar, Generic,
                    Protocol, runtime_checkable, cast, overload, get_overloads, no_type_check,
                    final, get_type_hints, get_origin, get_args, ParamSpec, Concatenate,
                    TypeVarTuple, Unpack, NoReturn, Never, Self, TypeAlias, LiteralString,
                    Required, NotRequired, assert_never, assert_type, is_typeddict,
                    dataclass_transform, ForwardRef, AnyStr, Text, TYPE_CHECKING, Hashable,
                    Sized, Generator, SupportsInt, SupportsIndex, Deque, DefaultDict, Counter)

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(fn):
    # the exception fn() raises, as "Type: message"
    try:
        fn()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

# ── keyword ──────────────────────────────────────────────────────────────────
check("kwlist is CPython's", keyword.kwlist,
      ['False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class',
       'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global',
       'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return',
       'try', 'while', 'with', 'yield'])
check("iskeyword", [keyword.iskeyword("lambda"), keyword.iskeyword("None"), keyword.iskeyword("print"),
                    keyword.iskeyword("match"), keyword.iskeyword(""), keyword.iskeyword(5)],
      [True, True, False, False, False, False])
check("soft keywords", ["_" in keyword.softkwlist, "case" in keyword.softkwlist, "match" in keyword.softkwlist,
                        keyword.issoftkeyword("match"), keyword.issoftkeyword("lambda"), keyword.issoftkeyword(None)],
      [True, True, True, True, False, False])
check("kwlist sorted, no soft ones", [keyword.kwlist == sorted(keyword.kwlist), len(keyword.kwlist),
                                      [k for k in keyword.softkwlist if k in keyword.kwlist]],
      [True, 35, []])

# ── types ────────────────────────────────────────────────────────────────────
def plain(a, b=1):
    return a + b

def gen_fn():
    yield 1

class Cls:
    """Cls doc."""
    attr = 7
    def __init__(self, x, y=3):
        self.x = x
        self.y = y
    def meth(self, z):
        "meth doc"
        return self.x + z
    @classmethod
    def cmeth(cls, q):
        return q
    @staticmethod
    def smeth(r):
        return r

obj = Cls(1)
lam = lambda u, v=2: u * v
check("FunctionType", [isinstance(plain, types.FunctionType), isinstance(lam, types.LambdaType),
                       isinstance(len, types.FunctionType), isinstance(obj.meth, types.FunctionType),
                       isinstance(Cls, types.FunctionType), isinstance(5, types.FunctionType),
                       isinstance(Cls.meth, types.FunctionType)],
      [True, True, False, False, False, False, True])
check("MethodType of the engines' bound methods", [isinstance(obj.meth, types.MethodType), isinstance(plain, types.MethodType),
                                                  isinstance(Cls.cmeth, types.MethodType), isinstance(len, types.MethodType)],
      [True, False, True, False])
check("BuiltinFunctionType", [isinstance(len, types.BuiltinFunctionType), isinstance(print, types.BuiltinMethodType),
                              isinstance(plain, types.BuiltinFunctionType), isinstance(int, types.BuiltinFunctionType)],
      [True, True, False, False])
check("GeneratorType", [isinstance(gen_fn(), types.GeneratorType), isinstance(gen_fn, types.GeneratorType),
                        isinstance([1], types.GeneratorType), isinstance((x for x in [1]), types.GeneratorType)],
      [True, False, False, True])
check("type names", [types.FunctionType.__name__, types.BuiltinFunctionType.__name__, types.MethodType.__name__,
                     types.GeneratorType.__name__, types.ModuleType.__name__, types.NoneType.__name__],
      ["function", "builtin_function_or_method", "method", "generator", "module", "NoneType"])
check("type reprs", [repr(types.FunctionType), repr(types.MethodType), repr(types.NoneType), repr(types.ModuleType)],
      ["<class 'function'>", "<class 'method'>", "<class 'NoneType'>", "<class 'module'>"])

bm = types.MethodType(plain, 10)
check("MethodType binds", [bm(5), bm.__self__, bm.__func__ is plain, isinstance(bm, types.MethodType)],
      [15, 10, True, True])
check("MethodType errors", [err(lambda: types.MethodType(5, obj)), err(lambda: types.MethodType(plain, None))],
      ["TypeError: first argument must be callable", "TypeError: instance must not be None"])

ns = types.SimpleNamespace(a=1, b="x")
check("SimpleNamespace", [repr(ns), ns.a, ns.b, ns == types.SimpleNamespace(a=1, b="x"),
                          ns == types.SimpleNamespace(a=1), ns != types.SimpleNamespace(b="x", a=1)],
      ["namespace(a=1, b='x')", 1, "x", True, False, False])
ns.c = [1]
del ns.a
check("SimpleNamespace is mutable", [repr(ns), hasattr(ns, "a"), vars(ns)], ["namespace(b='x', c=[1])", False, {'b': 'x', 'c': [1]}])
class NS2(types.SimpleNamespace):
    pass
check("SimpleNamespace subclass repr", repr(NS2(k=2)), "NS2(k=2)")
check("SimpleNamespace empty", [repr(types.SimpleNamespace()), err(lambda: types.SimpleNamespace(1, 2))[:9]],
      ["namespace()", "TypeError"])

base_d = {"a": 1, "b": 2}
mp = types.MappingProxyType(base_d)
check("MappingProxyType reads", [mp["a"], mp.get("z", 0), list(mp.keys()), list(mp.values()), list(mp.items()),
                                 len(mp), "a" in mp, "z" in mp, list(mp), repr(mp), mp == {"a": 1, "b": 2}],
      [1, 0, ["a", "b"], [1, 2], [("a", 1), ("b", 2)], 2, True, False, ["a", "b"], "mappingproxy({'a': 1, 'b': 2})", True])
def mp_set():
    mp["c"] = 3
def mp_del():
    del mp["a"]
check("MappingProxyType is read-only", [err(mp_set), err(mp_del), err(lambda: types.MappingProxyType(5))],
      ["TypeError: 'mappingproxy' object does not support item assignment",
       "TypeError: 'mappingproxy' object does not support item deletion",
       "TypeError: mappingproxy() argument must be a mapping, not int"])
base_d["c"] = 3
check("MappingProxyType is a live view", [mp["c"], len(mp), mp.copy(), mp | {"d": 4}],
      [3, 3, {"a": 1, "b": 2, "c": 3}, {"a": 1, "b": 2, "c": 3, "d": 4}])

m = types.ModuleType("mymod", "the doc")
m.value = 42
check("ModuleType", [repr(m), m.__name__, m.__doc__, m.value, isinstance(m, types.ModuleType),
                     isinstance(functools, types.ModuleType), isinstance({}, types.ModuleType), isinstance(5, types.ModuleType)],
      ["<module 'mymod'>", "mymod", "the doc", 42, True, True, False, False])
check("ModuleType without doc", [types.ModuleType("m2").__doc__, err(lambda: types.ModuleType(5))[:9]], [None, "TypeError"])

check("NoneType / NotImplementedType / EllipsisType",
      [isinstance(None, types.NoneType), isinstance(0, types.NoneType), types.NoneType() is None,
       isinstance(NotImplemented, types.NotImplementedType), types.NotImplementedType() is NotImplemented,
       types.EllipsisType is type(...), isinstance(..., types.EllipsisType)],
      [True, False, True, True, True, True, True])
check("GenericAlias / UnionType",
      [types.GenericAlias(list, (int,)) == list[int], isinstance(list[int], types.GenericAlias),
       isinstance(dict[str, int], types.GenericAlias), isinstance(int | str, types.UnionType),
       isinstance(int, types.UnionType), repr(types.GenericAlias(dict, (str, int)))],
      [True, True, True, True, False, "dict[str, int]"])

class NcBase:
    tag = "base"
class NcMeta(type):
    pass
def nc_body(ns):
    ns["x"] = 1
    ns["hello"] = lambda self: "hi " + str(self.x)
NC = types.new_class("NC", (NcBase,), {}, nc_body)
check("new_class", [NC.__name__, NC.x, NC.tag, issubclass(NC, NcBase), NC().hello()],
      ["NC", 1, "base", True, "hi 1"])
NC2 = types.new_class("NC2", (), {"metaclass": NcMeta})
check("new_class with a metaclass", [type(NC2) is NcMeta, NC2.__name__], [True, "NC2"])
pc = types.prepare_class("P", (NcBase,), {"metaclass": NcMeta, "flag": 1})
check("prepare_class", [pc[0] is NcMeta, pc[1], pc[2]], [True, {}, {"flag": 1}])
class MroE:
    def __mro_entries__(self, bases):
        return (NcBase,)
me = MroE()
check("resolve_bases", [types.resolve_bases((int, me)) == (int, NcBase), types.resolve_bases((int, str)) == (int, str)],
      [True, True])

class DCA:
    def __init__(self):
        self._v = 5
    @types.DynamicClassAttribute
    def v(self):
        return self._v * 2
check("DynamicClassAttribute", [DCA().v, err(lambda: DCA.v)[:14]], [10, "AttributeError"])
check("types.coroutine", [types.coroutine(gen_fn) is gen_fn, err(lambda: types.coroutine(5))],
      [True, "TypeError: types.coroutine() expects a callable"])

# ── function introspection (both engines) ────────────────────────────────────
def full(a, b: int = 2, *args, c, d=4, **kw) -> int:
    "Full doc."
    return 1

def posonly(p, q=5, /, r=6, *, s):
    return p

def outer():
    def inner(x):
        yield x
    return inner

async def coro_fn(x):
    return x

async def agen_fn():
    yield 1

check("__defaults__ / __kwdefaults__", [full.__defaults__, full.__kwdefaults__, plain.__defaults__,
                                         outer.__defaults__, outer.__kwdefaults__, posonly.__defaults__, lam.__defaults__],
      [(2,), {"d": 4}, (1,), None, None, (5, 6), (2,)])
check("__code__ counts", [full.__code__.co_argcount, full.__code__.co_kwonlyargcount, full.__code__.co_posonlyargcount,
                          posonly.__code__.co_argcount, posonly.__code__.co_posonlyargcount, posonly.__code__.co_kwonlyargcount],
      [2, 2, 0, 3, 2, 1])
check("__code__.co_varnames", [full.__code__.co_varnames, posonly.__code__.co_varnames[:4], Cls.meth.__code__.co_varnames[:2],
                               lam.__code__.co_varnames],
      [("a", "b", "c", "d", "args", "kw"), ("p", "q", "r", "s"), ("self", "z"), ("u", "v")])
check("__code__.co_flags", [full.__code__.co_flags & 15, outer().__code__.co_flags & 0x30, coro_fn.__code__.co_flags & 0x80,
                            agen_fn.__code__.co_flags & 0x200, plain.__code__.co_flags & 0x2a0],
      [15, 0x30, 0x80, 0x200, 0])
check("__code__.co_name / co_filename", [full.__code__.co_name, lam.__code__.co_name, full.__code__.co_filename.endswith("vm_audit82.ny")],
      ["full", "<lambda>", True])
check("__qualname__", [full.__qualname__, Cls.meth.__qualname__, obj.meth.__qualname__, outer().__qualname__,
                       lam.__qualname__, Cls.cmeth.__qualname__],
      ["full", "Cls.meth", "Cls.meth", "outer.<locals>.inner", "<lambda>", "Cls.cmeth"])
check("__module__ / __name__", [full.__module__, lam.__name__, Cls.meth.__module__], ["__main__", "<lambda>", "__main__"])
check("__globals__", ["full" in full.__globals__, full.__globals__["plain"] is plain], [True, True])

# ── inspect: signatures ──────────────────────────────────────────────────────
sig = inspect.signature(full)
check("str(signature)", [str(sig), str(inspect.signature(posonly)), str(inspect.signature(plain)),
                         str(inspect.signature(lam)), str(inspect.signature(outer))],
      ["(a, b: int = 2, *args, c, d=4, **kw) -> int", "(p, q=5, /, r=6, *, s)", "(a, b=1)", "(u, v=2)", "()"])
check("signatures of methods and classes", [str(inspect.signature(obj.meth)), str(inspect.signature(Cls.meth)),
                                            str(inspect.signature(Cls)), str(inspect.signature(Cls.cmeth)),
                                            str(inspect.signature(Cls.smeth)), str(inspect.signature(NcBase))],
      ["(z)", "(self, z)", "(x, y=3)", "(q)", "(r)", "()"])

class WithNew:
    def __new__(cls, n, m=0):
        return object.__new__(cls)
class Callme:
    def __call__(self, q, *rest):
        return q
class MetaCall(type):
    def __call__(cls, a, b):
        return a + b
class ByMeta(metaclass=MetaCall):
    pass
class SubCls(Cls):
    pass
check("signatures: __new__, __call__, metaclass __call__, inherited __init__",
      [str(inspect.signature(WithNew)), str(inspect.signature(Callme())), str(inspect.signature(ByMeta)),
       str(inspect.signature(SubCls))],
      ["(n, m=0)", "(q, *rest)", "(a, b)", "(x, y=3)"])
check("signature repr", [repr(sig), repr(sig.parameters["b"]), repr(sig.parameters["args"])],
      ["<Signature (a, b: int = 2, *args, c, d=4, **kw) -> int>", "<Parameter \"b: int = 2\">", "<Parameter \"*args\">"])
check("parameters", [list(sig.parameters), [str(p.kind) for p in sig.parameters.values()],
                     sig.parameters["b"].default, sig.parameters["a"].default is inspect.Parameter.empty,
                     sig.parameters["b"].annotation is int, sig.return_annotation is int,
                     inspect.signature(plain).return_annotation is inspect.Signature.empty],
      [["a", "b", "args", "c", "d", "kw"],
       ["POSITIONAL_OR_KEYWORD", "POSITIONAL_OR_KEYWORD", "VAR_POSITIONAL", "KEYWORD_ONLY", "KEYWORD_ONLY", "VAR_KEYWORD"],
       2, True, True, True, True])
P_ = inspect.Parameter
check("parameter kinds", [repr(P_.POSITIONAL_ONLY), int(P_.KEYWORD_ONLY), P_.VAR_KEYWORD.description,
                          P_.POSITIONAL_ONLY < P_.VAR_POSITIONAL, P_.KEYWORD_ONLY == 3, P_.VAR_POSITIONAL.name,
                          [p.kind for p in inspect.signature(posonly).parameters.values()] == [P_.POSITIONAL_ONLY, P_.POSITIONAL_ONLY, P_.POSITIONAL_OR_KEYWORD, P_.KEYWORD_ONLY]],
      ["<_ParameterKind.POSITIONAL_ONLY: 0>", 3, "variadic keyword", True, True, "VAR_POSITIONAL", True])
check("Parameter.empty", [repr(inspect.Parameter.empty), inspect.Parameter.empty is inspect.Signature.empty], ["<class 'inspect._empty'>", True])

ba = sig.bind(1, 2, 3, c=4, e=5)
check("bind", [ba.arguments, ba.args, ba.kwargs, repr(ba)],
      [{"a": 1, "b": 2, "args": (3,), "c": 4, "kw": {"e": 5}}, (1, 2, 3), {"c": 4, "e": 5},
       "<BoundArguments (a=1, b=2, args=(3,), c=4, kw={'e': 5})>"])
ba2 = sig.bind(1, c=3)
ba2.apply_defaults()
check("apply_defaults", ba2.arguments, {"a": 1, "b": 2, "args": (), "c": 3, "d": 4, "kw": {}})
check("bind errors", [err(lambda: sig.bind()), err(lambda: sig.bind(1)), err(lambda: inspect.signature(plain).bind(1, 2, 3)),
                      err(lambda: inspect.signature(plain).bind(1, a=2)), err(lambda: inspect.signature(plain).bind(1, z=2)),
                      err(lambda: inspect.signature(posonly).bind(p=1, s=2))],
      ["TypeError: missing a required argument: 'a'", "TypeError: missing a required argument: 'c'",
       "TypeError: too many positional arguments", "TypeError: multiple values for argument 'a'",
       "TypeError: got an unexpected keyword argument 'z'",
       "TypeError: 'p' parameter is positional only, but was passed as a keyword"])
check("bind_partial", [sig.bind_partial(1).arguments, sig.bind_partial(c=9).arguments, inspect.signature(plain).bind_partial().args],
      [{"a": 1}, {"c": 9}, ()])
check("BoundArguments ==", [sig.bind(1, c=2) == sig.bind(1, c=2), sig.bind(1, c=2) == sig.bind(2, c=2)], [True, False])

check("replace", [str(sig.replace(return_annotation=str)), str(sig.parameters["b"].replace(default=9)),
                  str(sig.replace(parameters=[P_("x", P_.POSITIONAL_ONLY)]))],
      ["(a, b: int = 2, *args, c, d=4, **kw) -> str", "b: int = 9", "(x, /) -> int"])
mk = inspect.Signature([P_("a", P_.POSITIONAL_ONLY), P_("b", P_.POSITIONAL_OR_KEYWORD, default=1),
                        P_("c", P_.KEYWORD_ONLY, annotation=str), P_("kw", P_.VAR_KEYWORD)], return_annotation=list)
check("Signature built by hand", [str(mk), str(inspect.Signature()), str(inspect.Signature([P_("k", P_.KEYWORD_ONLY)]))],
      ["(a, /, b=1, *, c: str, **kw) -> list", "()", "(*, k)"])
check("Signature validation", [err(lambda: inspect.Signature([P_("a", P_.KEYWORD_ONLY), P_("b", P_.POSITIONAL_ONLY)])),
                               err(lambda: inspect.Signature([P_("a", P_.POSITIONAL_OR_KEYWORD, default=1), P_("b", P_.POSITIONAL_OR_KEYWORD)])),
                               err(lambda: inspect.Signature([P_("a", P_.POSITIONAL_ONLY), P_("a", P_.KEYWORD_ONLY)]))],
      ["ValueError: wrong parameter order: keyword-only parameter before positional-only parameter",
       "ValueError: non-default argument follows default argument", "ValueError: duplicate parameter name: 'a'"])
check("Parameter validation", [err(lambda: P_("1x", P_.POSITIONAL_ONLY)), err(lambda: P_("class", P_.KEYWORD_ONLY)),
                               err(lambda: P_("a", P_.VAR_POSITIONAL, default=1)), err(lambda: P_(5, P_.KEYWORD_ONLY)),
                               err(lambda: P_("a", 7))],
      ["ValueError: '1x' is not a valid parameter name", "ValueError: 'class' is not a valid parameter name",
       "ValueError: variadic positional parameters cannot have default values", "TypeError: name must be a str, not a int",
       "ValueError: value 7 is not a valid Parameter.kind"])
check("Signature / Parameter ==", [inspect.signature(plain) == inspect.signature(lambda a, b=1: 0),
                                   inspect.signature(plain) == inspect.signature(lam), P_("a", 1) == P_("a", 1),
                                   P_("a", 1) == P_("a", 1, default=2), hash(P_("a", 1)) == hash(P_("a", 1))],
      [True, False, True, False, True])

def decorated_target(x, y=1):
    return x
@functools.wraps(decorated_target)
def wrapper(*args, **kwargs):
    return decorated_target(*args, **kwargs)
def with_sig(*args):
    pass
with_sig.__signature__ = inspect.Signature([P_("magic", P_.POSITIONAL_OR_KEYWORD)])
check("signature follows __wrapped__ and __signature__", [str(inspect.signature(wrapper)),
                                                          str(inspect.signature(wrapper, follow_wrapped=False)),
                                                          str(inspect.signature(with_sig))],
      ["(x, y=1)", "(*args, **kwargs)", "(magic)"])
pf = functools.partial(full, 1, c=5)
check("signature of a partial", [str(inspect.signature(functools.partial(plain, 1))), str(inspect.signature(pf)),
                                 str(inspect.signature(functools.partial(plain, b=3)))],
      ["(b=1)", "(b: int = 2, *args, c=5, d=4, **kw) -> int", "(a, *, b=3)"])
check("signatures of builtins", [str(inspect.signature(len)), str(inspect.signature(sorted)), str(inspect.signature(print)),
                                 str(inspect.signature(isinstance)), str(inspect.signature(divmod))],
      ["(obj, /)", "(iterable, /, *, key=None, reverse=False)", "(*args, sep=' ', end='\\n', file=None, flush=False)",
       "(obj, class_or_tuple, /)", "(x, y, /)"])
check("signature errors", [err(lambda: inspect.signature(5)), err(lambda: inspect.signature(getattr))],
      ["TypeError: 5 is not a callable object", "ValueError: no signature found for builtin <built-in function getattr>"])

check("getfullargspec", repr(inspect.getfullargspec(full)),
      "FullArgSpec(args=['a', 'b'], varargs='args', varkw='kw', defaults=(2,), kwonlyargs=['c', 'd'], kwonlydefaults={'d': 4}, annotations={'return': <class 'int'>, 'b': <class 'int'>})")
check("getcallargs", [inspect.getcallargs(full, 1, c=3), inspect.getcallargs(obj.meth, 4), inspect.getcallargs(plain, 1, 2)],
      [{"a": 1, "args": (), "kw": {}, "c": 3, "b": 2, "d": 4}, {"self": obj, "z": 4}, {"a": 1, "b": 2}])
check("getcallargs errors", [err(lambda: inspect.getcallargs(plain)), err(lambda: inspect.getcallargs(plain, 1, 2, 3)),
                             err(lambda: inspect.getcallargs(full, 1))],
      ["TypeError: plain() missing 1 required positional argument: 'a'",
       "TypeError: plain() takes from 1 to 2 positional arguments but 3 were given",
       "TypeError: full() missing 1 required keyword-only argument: 'c'"])

# ── inspect: kinds, members, docs ────────────────────────────────────────────
check("predicates", [inspect.isfunction(full), inspect.isfunction(len), inspect.isbuiltin(len), inspect.isbuiltin(full),
                     inspect.ismethod(obj.meth), inspect.ismethod(Cls.meth), inspect.isclass(Cls), inspect.isclass(int),
                     inspect.isclass(obj), inspect.isroutine(len), inspect.isroutine(full), inspect.isroutine(obj.meth),
                     inspect.isroutine(5), inspect.ismodule(functools), inspect.ismodule(obj)],
      [True, False, True, False, True, False, True, True, False, True, True, True, False, True, False])
check("generator / coroutine predicates", [inspect.isgeneratorfunction(gen_fn), inspect.isgeneratorfunction(full),
                                           inspect.isgenerator(gen_fn()), inspect.isgenerator(gen_fn),
                                           inspect.iscoroutinefunction(coro_fn), inspect.iscoroutinefunction(gen_fn),
                                           inspect.isasyncgenfunction(agen_fn), inspect.isasyncgenfunction(coro_fn),
                                           inspect.isgeneratorfunction(outer()), inspect.isgeneratorfunction(functools.partial(gen_fn))],
      [True, False, True, False, True, False, True, False, True, True])
check("isabstract / iscode / isframe", [inspect.isabstract(Cls), inspect.isabstract(5), inspect.iscode(full.__code__),
                                        inspect.iscode(full), inspect.isframe(5), inspect.istraceback(5)],
      [False, False, True, False, False, False])

class MBase:
    def a1(self):
        "Base a1 doc."
        pass
    def b1(self):
        pass
    k = 3
class MDer(MBase):
    def a1(self):
        pass
    def c1(self):
        pass
check("getmembers", [[n for n, v in inspect.getmembers(MDer, inspect.isfunction)], [n for n, v in inspect.getmembers(MDer) if n == "k"],
                     [n for n, v in inspect.getmembers(MDer(), inspect.ismethod) if not n.startswith("_")]],
      [["a1", "b1", "c1"], ["k"], ["a1", "b1", "c1"]])
check("getmro", [inspect.getmro(MDer) == (MDer, MBase, object), inspect.getmro(SubCls)[:2] == (SubCls, Cls)], [True, True])

def documented():
    """First line.

        Indented more.
    Back.
    """
check("getdoc / cleandoc", [inspect.getdoc(documented), inspect.getdoc(Cls), inspect.getdoc(plain),
                            inspect.getdoc(MDer.a1), inspect.getdoc(MDer().a1), inspect.cleandoc("  a\n    b\n  c\n\n"),
                            inspect.getdoc(SubCls)],
      ["First line.\n\n    Indented more.\nBack.", "Cls doc.", None, "Base a1 doc.", "Base a1 doc.", "a\n  b\nc", "Cls doc."])

class Static:
    cattr = 1
    def meth(self):
        return 2
st = Static()
st.iattr = 5
check("getattr_static", [inspect.getattr_static(st, "iattr"), inspect.getattr_static(st, "cattr"),
                         inspect.getattr_static(st, "meth") is Static.__dict__["meth"], inspect.getattr_static(st, "nope", "dflt"),
                         err(lambda: inspect.getattr_static(st, "nope")), inspect.getattr_static(Static, "cattr")],
      [5, 1, True, "dflt", "AttributeError: nope", 1])

def w1(f):
    @functools.wraps(f)
    def inner1(*a):
        return f(*a)
    return inner1
@w1
@w1
def deep(n):
    return n
loop1 = lambda: 0
loop2 = lambda: 0
loop1.__wrapped__ = loop2
loop2.__wrapped__ = loop1
check("unwrap", [inspect.unwrap(deep).__name__, inspect.unwrap(deep) is not deep, inspect.unwrap(plain) is plain,
                 inspect.unwrap(deep, stop=lambda f: True) is deep, err(lambda: inspect.unwrap(loop1))[:40]],
      ["deep", True, True, True, "ValueError: wrapper loop when unwrapping"])

def ann_fn(a: "int", b: "List[str]" = None) -> "Cls":
    pass
check("get_annotations", [inspect.get_annotations(full), inspect.get_annotations(ann_fn),
                          inspect.get_annotations(ann_fn, eval_str=True), inspect.get_annotations(plain)],
      [{"b": int, "return": int}, {"a": "int", "b": "List[str]", "return": "Cls"},
       {"a": int, "b": List[str], "return": Cls}, {}])
check("signature eval_str", [str(inspect.signature(ann_fn)), str(inspect.signature(ann_fn, eval_str=True))],
      ["(a: 'int', b: 'List[str]' = None) -> 'Cls'", "(a: int, b: List[str] = None) -> __main__.Cls"])
check("formatannotation", [inspect.formatannotation(int), inspect.formatannotation(List[int]), inspect.formatannotation(list[int]),
                           inspect.formatannotation(Cls), inspect.formatannotation(Cls, "__main__"), inspect.formatannotation("x"),
                           inspect.formatannotation(Optional[Dict[str, int]])],
      ["int", "List[int]", "list[int]", "__main__.Cls", "Cls", "'x'", "Optional[Dict[str, int]]"])

# ── inspect: source ──────────────────────────────────────────────────────────
# A comment about src_fn.
def src_fn(a,
           b=2):
    # inside
    if a:
        return (a +
                b)
    return 0

@w1
def src_decorated(x):
    return x

class SrcCls:
    """Doc."""
    def m(self):
        return 1

src_lam = lambda q: q + 1
check("getsource of a function", inspect.getsource(src_fn),
      "def src_fn(a,\n           b=2):\n    # inside\n    if a:\n        return (a +\n                b)\n    return 0\n")
check("getsourcelines", [inspect.getsourcelines(src_fn)[1], len(inspect.getsourcelines(src_fn)[0]),
                         inspect.getsourcelines(SrcCls.m)[0], inspect.getsourcelines(src_lam)[0]],
      [inspect.getsourcelines(src_fn)[1], 7, ["    def m(self):\n", "        return 1\n"], ["src_lam = lambda q: q + 1\n"]])
check("getsource with decorator / of a class", [inspect.getsource(inspect.unwrap(src_decorated)), inspect.getsource(SrcCls)],
      ["@w1\ndef src_decorated(x):\n    return x\n", "class SrcCls:\n    \"\"\"Doc.\"\"\"\n    def m(self):\n        return 1\n"])
check("co_firstlineno is the first decorator's line", inspect.unwrap(src_decorated).__code__.co_firstlineno,
      src_fn.__code__.co_firstlineno + 8)
check("getfile / getsourcefile / getcomments", [inspect.getfile(src_fn).endswith("vm_audit82.ny"), inspect.getsourcefile(src_fn) == inspect.getfile(src_fn),
                                                inspect.getfile(SrcCls).endswith("vm_audit82.ny"), inspect.getcomments(src_fn),
                                                err(lambda: inspect.getfile(5)), inspect.getmodulename("/a/b/mod.py")],
      [True, True, True, "# ── inspect: source ──────────────────────────────────────────────────────────\n# A comment about src_fn.\n",
       "TypeError: module, class, method, function, traceback, frame, or code object was expected, got int", "mod"])
check("indentsize", [inspect.indentsize("    x"), inspect.indentsize("\tx"), inspect.indentsize("x")], [4, 8, 0])

# ── typing: reprs ────────────────────────────────────────────────────────────
T = TypeVar("T")
K = TypeVar("K")
V = TypeVar("V")
T_co = TypeVar("T_co", covariant=True)
T_contra = TypeVar("T_contra", contravariant=True)
check("typing reprs", [repr(Optional[int]), repr(Union[int, str]), repr(Union[int, str, None]), repr(List[int]),
                       repr(Dict[str, List[int]]), repr(Callable[[int, str], bool]), repr(Callable[..., int]),
                       repr(Callable[[], None]), repr(Tuple[int, ...]), repr(Tuple[()]), repr(Literal[1, "a"]),
                       repr(Annotated[int, "m"]), repr(ClassVar[int]), repr(Final[int]), repr(Type[int]), repr(List),
                       repr(Any), repr(NoReturn), repr(Never), repr(Self), repr(Iterable[int]), repr(Union[int, Cls]),
                       repr(Optional[List[int]]), repr(Set[FrozenSet[str]])],
      ["typing.Optional[int]", "typing.Union[int, str]", "typing.Union[int, str, NoneType]", "typing.List[int]",
       "typing.Dict[str, typing.List[int]]", "typing.Callable[[int, str], bool]", "typing.Callable[..., int]",
       "typing.Callable[[], NoneType]", "typing.Tuple[int, ...]", "typing.Tuple[()]", "typing.Literal[1, 'a']",
       "typing.Annotated[int, 'm']", "typing.ClassVar[int]", "typing.Final[int]", "typing.Type[int]", "typing.List",
       "typing.Any", "typing.NoReturn", "typing.Never", "typing.Self", "typing.Iterable[int]", "typing.Union[int, __main__.Cls]",
       "typing.Optional[typing.List[int]]", "typing.Set[typing.FrozenSet[str]]"])
check("TypeVar reprs", [repr(T), repr(T_co), repr(T_contra), repr(List[T]), repr(Dict[K, V])],
      ["~T", "+T_co", "-T_contra", "typing.List[~T]", "typing.Dict[~K, ~V]"])

# ── typing: Union / Optional ─────────────────────────────────────────────────
check("Union rules", [Union[int] is int, Union[int, int] is int, Union[int, Union[str, float]] == Union[int, str, float],
                      Union[int, str] == Union[str, int], Optional[int] == Union[int, None], Union[int, str] == (int | str),
                      Union[int, str] != Union[int, float], hash(Union[int, str]) == hash(Union[str, int]),
                      Union[int, str, int, str] == Union[int, str], len(Union[int, str, None].__args__)],
      [True, True, True, True, True, True, True, True, True, 3])
check("Union with |", [repr(Union[int, str] | None), repr(int | List[int]), repr(List[int] | None), Optional[int] | str == Union[int, str, None],
                       repr(T | int)],
      ["typing.Union[int, str, NoneType]", "typing.Union[int, typing.List[int]]",
       "typing.Optional[typing.List[int]]", True, "typing.Union[~T, int]"])
check("Union errors", [err(lambda: Union[()]), err(lambda: Optional[int, str]), err(lambda: Union[int, str](3)),
                       err(lambda: ClassVar[int, str])[:10]],
      ["TypeError: Cannot take a Union of no types.",
       "TypeError: typing.Optional requires a single type. Got (<class 'int'>, <class 'str'>).",
       "TypeError: Cannot instantiate typing.Union", "TypeError:"])
check("isinstance with Union", [isinstance(3, Union[int, str]), isinstance(3.0, Optional[int]), isinstance(None, Optional[int]),
                                isinstance("s", Union[int, str]), issubclass(bool, Union[int, str])],
      [True, False, True, True, True])

# ── typing: get_origin / get_args ────────────────────────────────────────────
check("get_origin", [get_origin(List[int]) is list, get_origin(Dict[str, int]) is dict, get_origin(Union[int, str]) is Union,
                     get_origin(Optional[int]) is Union, get_origin(Literal[1]) is Literal, get_origin(Annotated[int, "x"]) is Annotated,
                     get_origin(int) is None, get_origin(list[int]) is list, get_origin(int | str) is types.UnionType,
                     get_origin(Generic) is Generic, get_origin(ClassVar[int]) is ClassVar, get_origin(List) is list,
                     get_origin(Tuple[int]) is tuple, get_origin(Type[int]) is type],
      [True, True, True, True, True, True, True, True, True, True, True, True, True, True])
check("get_origin of the abstract aliases", [get_origin(Callable[[int], str]).__name__, get_origin(Iterable[int]).__module__,
                                             get_origin(Mapping[str, int]).__name__],
      ["Callable", "collections.abc", "Mapping"])
check("get_args", [get_args(Dict[str, int]), get_args(Optional[int]) == (int, types.NoneType), get_args(Callable[[int], str]),
                   get_args(Callable[..., str]), get_args(Annotated[int, "x", 2]), get_args(int), get_args(int | str),
                   get_args(Tuple[int, ...]), get_args(Literal[1, 2]), get_args(list[int]), get_args(List)],
      [(str, int), True, ([int], str), (Ellipsis, str), (int, "x", 2), (), (int, str), (int, Ellipsis), (1, 2), (int,), ()])

# ── typing: generic aliases ──────────────────────────────────────────────────
check("substitution", [List[T][int] == List[int], Dict[str, T][int] == Dict[str, int], Dict[K, V][str, int] == Dict[str, int],
                       List[T].__parameters__ == (T,), Dict[K, List[V]].__parameters__ == (K, V), List[int].__parameters__ == (),
                       repr(Dict[K, List[V]][int, str]), repr(Callable[[T], K][int, str])],
      [True, True, True, True, True, True, "typing.Dict[int, typing.List[str]]", "typing.Callable[[int], str]"])
check("alias errors", [err(lambda: List[int][str]), err(lambda: List[int, str]), err(lambda: List()), err(lambda: Dict()),
                       err(lambda: isinstance([], List[int])), err(lambda: Hashable[int]), err(lambda: Callable[int])],
      ["TypeError: typing.List[int] is not a generic class", "TypeError: Too many arguments for typing.List; actual 2, expected 1",
       "TypeError: Type List cannot be instantiated; use list() instead", "TypeError: Type Dict cannot be instantiated; use dict() instead",
       "TypeError: Subscripted generics cannot be used with class and instance checks", "TypeError: typing.Hashable is not a generic class",
       "TypeError: Callable must be used as Callable[[arg, ...], result]."])
check("isinstance with aliases", [isinstance([], List), isinstance({}, List), issubclass(list, List), isinstance({}, Dict),
                                  isinstance([1], Iterable), isinstance(5, Iterable), isinstance(len, Callable), isinstance(5, Callable),
                                  isinstance({}, Mapping), isinstance([], Mapping), isinstance([], Sequence), isinstance([], Sized),
                                  isinstance([], Hashable), isinstance((1,), Tuple), isinstance(Cls, Type)],
      [True, False, True, True, True, False, True, False, True, False, True, True, False, True, True])
check("list[int] and List[int]", [List[int] == List[int], List[int] != List[str], hash(List[int]) == hash(List[int]),
                                  List[int] == list[int], repr(Dict[str, list[int]])],
      [True, True, True, False, "typing.Dict[str, list[int]]"])
check("Literal", [Literal[1, 2] == Literal[2, 1], Literal[1, Literal[2, 3]] == Literal[1, 2, 3], repr(Literal[1, 1, 2]),
                  Literal[1] == Literal[True], repr(Literal["a", None])],
      [True, True, "typing.Literal[1, 2]", False, "typing.Literal['a', None]"])
check("Annotated", [Annotated[int, "a"].__metadata__, Annotated[Annotated[int, "a"], "b"] == Annotated[int, "a", "b"],
                    Annotated[int, "a"].__origin__ is int, err(lambda: Annotated[int]), err(lambda: Annotated())],
      [("a",), True, True, "TypeError: Annotated[...] should be used with at least two arguments (a type and an annotation).",
       "TypeError: Type Annotated cannot be instantiated."])
check("special form errors", [err(lambda: Self[int]), err(lambda: NoReturn[int]), err(lambda: isinstance(1, Any)), err(lambda: Any()),
                              err(lambda: Union()), err(lambda: List[ClassVar[int]]), err(lambda: isinstance(1, Union))],
      ["TypeError: typing.Self is not subscriptable", "TypeError: typing.NoReturn is not subscriptable",
       "TypeError: typing.Any cannot be used with isinstance()", "TypeError: Any cannot be instantiated",
       "TypeError: Cannot instantiate typing.Union", "TypeError: typing.ClassVar[int] is not valid as type argument",
       "TypeError: typing.Union cannot be used with isinstance()"])

# ── typing: TypeVar, ParamSpec, TypeVarTuple ─────────────────────────────────
TB = TypeVar("TB", bound=Cls)
TC = TypeVar("TC", int, str)
check("TypeVar attributes", [T.__name__, TB.__bound__ is Cls, TC.__constraints__, T_co.__covariant__, T_co.__contravariant__,
                             T.__bound__, T.__constraints__, T == T, T == TypeVar("T")],
      ["T", True, (int, str), True, False, None, (), True, False])
check("TypeVar errors", [err(lambda: TypeVar("X", int)), err(lambda: TypeVar("X", int, str, bound=int)),
                         err(lambda: TypeVar("X", covariant=True, contravariant=True))],
      ["TypeError: A single constraint is not allowed", "TypeError: Constraints cannot be combined with bound=...",
       "ValueError: Bivariant types are not supported."])
PS = ParamSpec("PS")
TS = TypeVarTuple("TS")
check("ParamSpec / Concatenate / TypeVarTuple", [repr(PS), repr(PS.args), repr(PS.kwargs), repr(Callable[PS, int]),
                                                 repr(Concatenate[int, PS]), repr(TS), repr(Unpack[TS]), PS.args.__origin__ is PS,
                                                 repr(Callable[Concatenate[int, PS], str])],
      ["~PS", "PS.args", "PS.kwargs", "typing.Callable[~PS, int]", "typing.Concatenate[int, ~PS]", "TS", "*TS", True,
       "typing.Callable[typing.Concatenate[int, ~PS], str]"])
check("AnyStr / Text / TYPE_CHECKING", [AnyStr.__constraints__, Text is str, TYPE_CHECKING], [(bytes, str), True, False])

# ── typing: Generic ──────────────────────────────────────────────────────────
class Box(Generic[T]):
    def __init__(self, value):
        self.value = value
    def get(self):
        return self.value
class Pair(Generic[K, V]):
    pass
class IntBox(Box[int]):
    pass
class Box2(Box[T]):
    pass
class Mixed(Pair[str, V], Box[int]):
    pass
bi = Box[int](5)
check("Generic classes", [Box.__parameters__ == (T,), Box.__orig_bases__ == (Generic[T],), repr(Box[int]), bi.value, bi.get(),
                          bi.__orig_class__ == Box[int], type(bi) is Box, Pair.__parameters__ == (K, V), IntBox.__parameters__,
                          Box2.__parameters__ == (T,), Mixed.__parameters__ == (V,), Box[int] == Box[int], Box[int] != Box[str],
                          get_origin(Box[int]) is Box, get_args(Pair[int, str]), issubclass(IntBox, Box), isinstance(IntBox(1), Box),
                          Box.__mro__ == (Box, Generic, object)],
      [True, True, "__main__.Box[int]", 5, 5, True, True, True, (), True, True, True, True, True, (int, str), True, True, True])
def plain_generic():
    class Bad(Generic):
        pass
def generic_multi():
    class Bad2(Generic[T], Generic[K]):
        pass
check("Generic errors", [err(lambda: Box[int, str]), err(lambda: Generic[T][int]), err(plain_generic), err(lambda: Generic[int]),
                         err(lambda: Generic[T, T]), err(lambda: IntBox[int]), err(lambda: Generic[()])],
      ["TypeError: Too many arguments for <class '__main__.Box'>; actual 2, expected 1",
       "TypeError: Cannot subscript already-subscripted typing.Generic[~T]", "TypeError: Cannot inherit from plain Generic",
       "TypeError: Parameters to Generic[...] must all be type variables or parameter specification variables.",
       "TypeError: Parameters to Generic[...] must all be unique", "TypeError: <class '__main__.IntBox'> is not a generic class",
       "TypeError: Parameter list to Generic[...] cannot be empty"])

# ── typing: Protocol ─────────────────────────────────────────────────────────
@runtime_checkable
class Closable(Protocol):
    def close(self):
        pass
class HasClose:
    def close(self):
        return "closed"
class NoClose:
    def open(self):
        pass
class NotRuntime(Protocol):
    def run(self):
        pass
@runtime_checkable
class HasX(Protocol):
    x: int
class XHolder:
    def __init__(self):
        self.x = 1
class ClosedNone:
    close = None
@runtime_checkable
class GenProto(Protocol[T]):
    def get(self) -> T:
        pass
class Impl(Closable):
    pass
def proto_bad_base():
    class PB(Protocol, Cls):
        pass
check("Protocol isinstance", [isinstance(HasClose(), Closable), isinstance(NoClose(), Closable), isinstance(XHolder(), HasX),
                              isinstance(NoClose(), HasX), isinstance(ClosedNone(), Closable), isinstance(bi, GenProto),
                              isinstance(Impl(), Closable), isinstance(5, Closable)],
      [True, False, True, False, False, True, True, False])
check("Protocol issubclass", [issubclass(HasClose, Closable), issubclass(NoClose, Closable), issubclass(Impl, Closable),
                              err(lambda: issubclass(XHolder, HasX)), err(lambda: issubclass(5, Closable))],
      [True, False, True, "TypeError: Protocols with non-method members don't support issubclass()",
       "TypeError: issubclass() arg 1 must be a class"])
check("Protocol errors", [err(lambda: isinstance(HasClose(), NotRuntime)), err(lambda: Closable()), err(lambda: runtime_checkable(HasClose)),
                          err(proto_bad_base)],
      ["TypeError: Instance and class checks can only be used with @runtime_checkable protocols",
       "TypeError: Protocols cannot be instantiated",
       "TypeError: @runtime_checkable can be only applied to protocol classes, got <class '__main__.HasClose'>",
       "TypeError: Protocols can only inherit from other protocols, got <class '__main__.Cls'>"])
check("Protocol attributes", [Closable._is_protocol, Impl._is_protocol, GenProto.__parameters__ == (T,), Impl().close() is None,
                              repr(GenProto[int])],
      [True, False, True, True, "__main__.GenProto[int]"])
class IntLike:
    def __int__(self):
        return 3
    def __index__(self):
        return 3
check("SupportsInt / SupportsIndex", [isinstance(IntLike(), SupportsInt), isinstance(Cls(1), SupportsInt), isinstance(IntLike(), SupportsIndex)],
      [True, False, True])

# ── typing: NamedTuple ───────────────────────────────────────────────────────
class Employee(NamedTuple):
    """An employee."""
    name: str
    id: int = 3
    def describe(self):
        return self.name + "#" + str(self.id)
e = Employee("ann")
e2 = Employee("bob", 7)
n_, i_ = e2
check("NamedTuple basics", [repr(e), e.name, e.id, e[0], e[1], e[-1], len(e), list(e), n_, i_, e2.describe(), e[0:1]],
      ["Employee(name='ann', id=3)", "ann", 3, "ann", 3, 3, 2, ["ann", 3], "bob", 7, "bob#7", ("ann",)])
check("NamedTuple API", [Employee._fields, Employee._field_defaults, Employee.__annotations__ == {"name": str, "id": int},
                         e._asdict(), repr(e._replace(id=9)), repr(Employee._make(["c", 1])), Employee.__match_args__,
                         Employee.__doc__, Employee(id=5, name="k").id],
      [("name", "id"), {"id": 3}, True, {"name": "ann", "id": 3}, "Employee(name='ann', id=9)", "Employee(name='c', id=1)",
       ("name", "id"), "An employee.", 5])
check("NamedTuple as a tuple", [e == ("ann", 3), e == Employee("ann", 3), e != e2, hash(e) == hash(("ann", 3)), e < e2,
                                e + (1,), "ann" in e, e.count(3), e.index(3), sorted([e2, e]) == [e, e2], {e: 1}[Employee("ann")]],
      [True, True, True, True, True, ("ann", 3, 1), True, 1, 1, True, 1])
def nt_set():
    e.id = 5
def nt_set2():
    e.zz = 1
def nt_order():
    class Bad(NamedTuple):
        a: int = 1
        b: str
def nt_overwrite():
    class Bad2(NamedTuple):
        x: int
        def _asdict(self):
            return {}
check("NamedTuple errors", [err(lambda: Employee()), err(lambda: Employee("a", 1, 2)), err(lambda: Employee(nam="x")),
                            err(lambda: Employee("a", name="b")), err(nt_set), err(nt_set2), err(nt_order),
                            err(lambda: e._replace(zz=1)), err(nt_overwrite)],
      ["TypeError: Employee.__new__() missing 1 required positional argument: 'name'",
       "TypeError: Employee.__new__() takes from 2 to 3 positional arguments but 4 were given",
       "TypeError: Employee.__new__() got an unexpected keyword argument 'nam'",
       "TypeError: Employee.__new__() got multiple values for argument 'name'",
       "AttributeError: can't set attribute", "AttributeError: 'Employee' object has no attribute 'zz'",
       "TypeError: Non-default namedtuple field b cannot follow default field a",
       "ValueError: Got unexpected field names: ['zz']", "AttributeError: Cannot overwrite NamedTuple attribute _asdict"])
Pt = NamedTuple("Pt", [("x", int), ("y", int)])
Pk = NamedTuple("Pk", a=int, b=str)
pt = Pt(1, 2)
check("NamedTuple functional form", [repr(pt), pt.x + pt.y, Pt._fields, Pk._fields, repr(Pk(1, "s")), Pt.__annotations__ == {"x": int, "y": int},
                                     err(lambda: Pt(1)), err(lambda: Pt(1, 2, 3))],
      ["Pt(x=1, y=2)", 3, ("x", "y"), ("a", "b"), "Pk(a=1, b='s')", True,
       "TypeError: Pt.__new__() missing 1 required positional argument: 'y'",
       "TypeError: Pt.__new__() takes 3 positional arguments but 4 were given"])
def nt_match(v):
    match v:
        case Employee(name="ann"):
            return "named ann"
        case Employee(n, 7):
            return "id 7: " + n
    return "other"
check("NamedTuple in match", [nt_match(e), nt_match(e2), nt_match(5)], ["named ann", "id 7: bob", "other"])

# ── typing: TypedDict ────────────────────────────────────────────────────────
class Movie(TypedDict):
    name: str
    year: int
class PartialMovie(TypedDict, total=False):
    name: str
    rating: Required[float]
class Sequel(Movie, total=False):
    prequel: str
    extra: NotRequired[int]
mv = Movie(name="Blade Runner", year=1982)
check("TypedDict instances are dicts", [mv, type(mv) is dict, Movie(name="x") == {"name": "x"}, Movie({"a": 1})],
      [{"name": "Blade Runner", "year": 1982}, True, True, {"a": 1}])
check("TypedDict keys", [sorted(Movie.__required_keys__), sorted(Movie.__optional_keys__), Movie.__total__,
                         sorted(PartialMovie.__required_keys__), sorted(PartialMovie.__optional_keys__), PartialMovie.__total__,
                         sorted(Sequel.__required_keys__), sorted(Sequel.__optional_keys__), list(Sequel.__annotations__)],
      [["name", "year"], [], True, ["rating"], ["name"], False, ["name", "year"], ["extra", "prequel"], ["name", "year", "prequel", "extra"]])
check("TypedDict checks", [is_typeddict(Movie), is_typeddict(dict), is_typeddict(Employee), err(lambda: isinstance({}, Movie)),
                           err(lambda: issubclass(dict, Movie))],
      [True, False, False, "TypeError: TypedDict does not support instance and class checks",
       "TypeError: TypedDict does not support instance and class checks"])
Point2D = TypedDict("Point2D", {"x": int, "y": int}, total=False)
check("TypedDict functional form", [Point2D(x=1), sorted(Point2D.__optional_keys__), Point2D.__annotations__ == {"x": int, "y": int},
                                    is_typeddict(Point2D)],
      [{"x": 1}, ["x", "y"], True, True])
check("get_type_hints of a TypedDict", get_type_hints(Sequel), {"name": str, "year": int, "prequel": str, "extra": int})

# ── typing: NewType, cast, overload, final, misc ─────────────────────────────
UserId = NewType("UserId", int)
check("NewType", [UserId(5), UserId.__supertype__ is int, repr(UserId), UserId.__name__, repr(Optional[UserId]), repr(UserId | None)],
      [5, True, "__main__.UserId", "UserId", "typing.Optional[__main__.UserId]", "typing.Optional[__main__.UserId]"])
check("cast / assert_type", [cast(int, "x"), cast("List[int]", [1]), assert_type(3, int)], ["x", [1], 3])
check("assert_never", err(lambda: assert_never(5)), "AssertionError: Expected code to be unreachable, but got: 5")

@overload
def ov(x: int) -> int:
    ...
@overload
def ov(x: str) -> str:
    ...
def ov(x):
    return x
class OvC:
    @overload
    def m(self, a: int) -> int:
        ...
    @overload
    def m(self, a: str) -> str:
        ...
    def m(self, a):
        return a
check("overload / get_overloads", [ov(3), len(get_overloads(ov)), [str(inspect.signature(f)) for f in get_overloads(ov)],
                                   len(get_overloads(OvC.m)), len(get_overloads(plain)), err(lambda: overload(plain)(1))[:19]],
      [3, 2, ["(x: int) -> int", "(x: str) -> str"], 2, 0, "NotImplementedError"])
@final
def fin_fn():
    pass
@final
class FinC:
    pass
check("final", [fin_fn.__final__, FinC.__final__], [True, True])
@no_type_check
def ntc(a: "nonexistent") -> int:
    pass
check("no_type_check", [get_type_hints(ntc), ntc.__no_type_check__], [{}, True])
@dataclass_transform(kw_only_default=True)
def dt_deco(cls):
    return cls
check("dataclass_transform", dt_deco.__dataclass_transform__,
      {"eq_default": True, "order_default": False, "kw_only_default": True, "field_specifiers": (), "kwargs": {}})

# ── typing: get_type_hints ───────────────────────────────────────────────────
def hinted(a: "int", b: "List[str]", c: Optional["Cls"] = None) -> "Box[int]":
    pass
class Hinted:
    x: int
    y: "Optional[str]" = None
    z: Annotated[int, "meta"] = 0
class HintedSub(Hinted):
    w: "Dict[str, int]"
check("get_type_hints of a function", get_type_hints(hinted),
      {"a": int, "b": List[str], "c": Optional[Cls], "return": Box[int]})
check("get_type_hints of classes", [get_type_hints(Hinted), get_type_hints(HintedSub), get_type_hints(Hinted, include_extras=True)["z"]],
      [{"x": int, "y": Optional[str], "z": int}, {"x": int, "y": Optional[str], "z": int, "w": Dict[str, int]}, Annotated[int, "meta"]])
check("get_type_hints of plain values", [get_type_hints(plain), get_type_hints(full), err(lambda: get_type_hints(5))],
      [{}, {"b": int, "return": int}, "TypeError: 5 is not a module, class, method, or function."])
check("ForwardRef", [repr(ForwardRef("int")), ForwardRef("int") == ForwardRef("int"), err(lambda: ForwardRef(5)),
                     err(lambda: ForwardRef("1 +"))[:11]],
      ["ForwardRef('int')", True, "TypeError: Forward reference must be a string -- got 5", "SyntaxError"])

# ── what the modules needed from the engines (round 77) ──────────────────────
def kw_collect(**kw):
    return kw
def kw_dunder(a, *, __v__=1):
    return __v__
def mk_closure(n):
    def inner():
        return n
    return inner
c1 = mk_closure(1)
c2 = mk_closure(2)
check("dunder keywords", [kw_collect(__x__=1, y=2), kw_dunder(0), kw_dunder(0, __v__=5)], [{"__x__": 1, "y": 2}, 1, 5])
check("a lambda's first parameter named self", [(lambda self: self)(5), (lambda self, k=2: self * k)(4)], [5, 8])
check("closures of one def are distinct", [c1 is c2, c1 is c1, id(c1) == id(c2), c1(), c2()], [False, True, False, 1, 2])
check("class __dict__ holds dunder names", ["__init__" in Cls.__dict__, "__orig_bases__" in Box.__dict__, "__orig_bases__" in Cls.__dict__,
                                            "__orig_class__" in bi.__dict__, "_is_protocol" in Closable.__dict__],
      [True, True, False, True, True])
check("a module's class made with metaclass= keeps its identity", [Closable.__bases__[0] is Protocol, typing.SupportsAbs.__bases__[0] is Protocol,
                                                                  typing.NamedTuple("Pq", [("a", int)])._fields, types.NoneType() is None],
      [True, True, ("a",), True])
check("__mro_entries__ gets the bases as written", [len(MroE.__mro_entries__.__code__.co_varnames), types.resolve_bases((me,)) == (NcBase,)],
      [2, True])

# ── Nython only ──────────────────────────────────────────────────────────────
if nython:
    check("nykwlist: the lexer's own keywords", ["var" in keyword.nykwlist, "let" in keyword.nykwlist, "fn" in keyword.nykwlist,
                                                "struct" in keyword.nykwlist, "if" in keyword.nykwlist, "match" in keyword.nykwlist,
                                                keyword.isnykeyword("unless"), keyword.isnykeyword("lambda"),
                                                keyword.nykwlist == sorted(keyword.nykwlist)],
          [True, True, True, True, False, False, True, False, True])
    check("type(None) given to a form", [Union[int, type(None)] == Optional[int], repr(Optional[type(None)])],
          [True, "<class 'NoneType'>"])
    check("SimpleNamespace(mapping) (3.13)", [repr(types.SimpleNamespace({"a": 1}, b=2)), repr(types.SimpleNamespace([("q", 1)]))],
          ["namespace(a=1, b=2)", "namespace(q=1)"])
    check("currentframe (no frames here)", inspect.currentframe(), None)
    check("check_type accepts", [typing.check_type([1, 2], List[int]), typing.check_type({"a": None}, Dict[str, Optional[int]]),
                                 typing.check_type((1, "a"), Tuple[int, str]), typing.check_type(3, Union[int, str]),
                                 typing.check_type(mv, Movie), typing.check_type(2, Literal[1, 2]), typing.check_type(1, float),
                                 isinstance(typing.check_type(Cls(1), TB), Cls), typing.check_type((1, 2, 3), Tuple[int, ...])],
          [[1, 2], {"a": None}, (1, "a"), 3, mv, 2, 1, True, (1, 2, 3)])
    check("check_type rejects", [err(lambda: typing.check_type([1, "x"], List[int])),
                                 err(lambda: typing.check_type({"a": "s"}, Dict[str, Optional[int]])),
                                 err(lambda: typing.check_type((1,), Tuple[int, str])),
                                 err(lambda: typing.check_type({"name": "x"}, Movie)),
                                 err(lambda: typing.check_type(3, Literal["a"])),
                                 err(lambda: typing.check_type("s", int))],
          ["TypeError: value[1] is str, not int", "TypeError: value['a'] is str, not Optional[int]",
           "TypeError: value has 1 items, not 2", "TypeError: value is missing the required key 'year'",
           "TypeError: value is 3, not one of 'a'", "TypeError: value is str, not int"])
    def over_base(self, a, b=1):
        pass
    def over_ok(self, a, b=1, c=2):
        pass
    def over_bad(self, x):
        pass
    check("signature_diff", [inspect.signature_diff(over_base, over_ok), inspect.signature_diff(over_base, over_bad)],
          [[], ["parameter 'a' is called 'x': a call passing a= by keyword fails",
                "no parameter takes positional argument 3 ('b')"]])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT82 PASSED ===")
