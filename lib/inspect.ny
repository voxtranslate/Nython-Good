# nython: module    (import it by name: it runs in a module scope of its own)
# lib/inspect.ny - Python's inspect module (round 77): signatures, the
# kind predicates, members, docstrings and source code of live objects.
#
#     import inspect
#     str(inspect.signature(f))      # '(a, b=2, *args, c, d=4, **kw) -> int'
#     inspect.signature(f).bind(1, c=3).arguments
#
# signature(obj, *, follow_wrapped=True, globals=None, locals=None, eval_str=False)
#     functions and lambdas (their parameters come from the engines:
#     f.__code__ / __defaults__ / __kwdefaults__ / __annotations__, which both
#     engines now give - _ny_fn_info), bound methods (self dropped),
#     classes (a metaclass __call__, else __new__ / __init__ found in the MRO,
#     first parameter dropped; a class with neither is `()`), callable
#     instances (their __call__), functools.partial objects, an object's
#     __signature__, decorated functions followed through __wrapped__
# Signature(parameters=None, *, return_annotation=Signature.empty)
#     .parameters (a read-only ordered mapping) .return_annotation, str() as
#     CPython's - `(a, /, b, *, c=1, **kw) -> int`, annotations through
#     formatannotation -, bind / bind_partial with CPython 3.11's TypeErrors,
#     replace, ==, hash, from_callable; parameter-order / default / duplicate
#     validation with CPython's ValueErrors
# Parameter(name, kind, *, default=Parameter.empty, annotation=Parameter.empty)
#     .name .kind .default .annotation, the five kinds (POSITIONAL_ONLY ...
#     VAR_KEYWORD; int-like, ordered, .name .value .description, str() is
#     the name), replace, ==, hash, str/repr as CPython
# BoundArguments   .arguments .signature .args .kwargs apply_defaults ==
# get_annotations(obj, *, globals=None, locals=None, eval_str=False)
# formatannotation(annotation, base_module=None)
# getfullargspec(func) -> FullArgSpec, getcallargs(func, /, *args, **kwds)
# isclass ismodule isfunction ismethod isbuiltin isroutine isgenerator
# isgeneratorfunction iscoroutine iscoroutinefunction isasyncgen
# isasyncgenfunction isawaitable isabstract iscode isframe istraceback
# isdatadescriptor ismethoddescriptor ismemberdescriptor isgetsetdescriptor
# ismethodwrapper markcoroutinefunction (3.12)
# getmembers(obj, predicate=None) / getmembers_static   sorted by name
# getmro(cls)   getdoc(obj) (inherited docstrings as CPython's _finddoc)
# cleandoc(doc) getattr_static(obj, attr, default)   unwrap(func, *, stop=None)
# getfile getsourcefile getsourcelines getsource getblock findsource
# indentsize getmodulename getmodule (modules imported here and __main__)
# getcomments (the comment block just above a def/class)
# CO_* flag constants; Parameter.empty is inspect._empty
#
# Source: a function's file and first line come from the engines
# (__code__.co_filename / co_firstlineno, the first decorator's line for a
# decorated def, as CPython); the block is found by indentation (with
# bracket and string continuation), as CPython's tokenize-based
# BlockFinder finds it for ordinary code. A class is found by its qualified
# name in its module's file. A lambda gives the logical line it is on.
#
# Innovation (Nython only): signature_diff(a, b) explains why a callable
# with signature `b` cannot stand in for one with signature `a` - the
# substitutability check of Liskov's principle restricted to calls (every
# call that `a` accepts must bind to `b` the same way), as type checkers
# (mypy's is_callable_compatible) apply it to overriding methods. It returns
# a list of human-readable problems; empty means `b` accepts every call `a`
# accepts.
#
# Not here: frames - the runtime has no frame objects, so currentframe()
# returns None (CPython documents that for implementations without frame
# support), and stack(), trace(), getframeinfo(), getouterframes(),
# getinnerframes(), getargvalues(), getgeneratorstate(),
# getgeneratorlocals(), getcoroutinestate() are not provided; signatures
# of builtins (they carry no __text_signature__: ValueError "no signature
# found for builtin", as CPython for builtins without one); getclosurevars
# (no __closure__ cells); classify_class_attrs; walktree / getclasstree;
# BufferFlags. A function's __code__.co_varnames lists its parameters, not
# its other locals.

import types

__all__ = ["signature", "Signature", "Parameter", "BoundArguments", "get_annotations",
           "formatannotation", "getfullargspec", "FullArgSpec", "getcallargs",
           "isclass", "ismodule", "isfunction", "ismethod", "isbuiltin", "isroutine",
           "isgenerator", "isgeneratorfunction", "iscoroutine", "iscoroutinefunction",
           "isasyncgen", "isasyncgenfunction", "isawaitable", "isabstract", "iscode",
           "isframe", "istraceback", "isdatadescriptor", "ismethoddescriptor",
           "ismemberdescriptor", "isgetsetdescriptor", "ismethodwrapper",
           "markcoroutinefunction", "getmembers", "getmembers_static", "getmro",
           "getdoc", "cleandoc", "getattr_static", "unwrap", "getfile",
           "getsourcefile", "getsourcelines", "getsource", "getblock", "findsource",
           "indentsize", "getmodulename", "getmodule", "getcomments", "currentframe",
           "signature_diff", "CO_OPTIMIZED", "CO_NEWLOCALS", "CO_VARARGS",
           "CO_VARKEYWORDS", "CO_NESTED", "CO_GENERATOR", "CO_NOFREE", "CO_COROUTINE",
           "CO_ITERABLE_COROUTINE", "CO_ASYNC_GENERATOR"]

CO_OPTIMIZED = 1
CO_NEWLOCALS = 2
CO_VARARGS = 4
CO_VARKEYWORDS = 8
CO_NESTED = 16
CO_GENERATOR = 32
CO_NOFREE = 64
CO_COROUTINE = 128
CO_ITERABLE_COROUTINE = 256
CO_ASYNC_GENERATOR = 512

TPFLAGS_IS_ABSTRACT = 1 << 20

_kwlist = frozenset(["False", "None", "True", "and", "as", "assert", "async", "await",
                     "break", "class", "continue", "def", "del", "elif", "else", "except",
                     "finally", "for", "from", "global", "if", "import", "in", "is",
                     "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
                     "while", "with", "yield"])


def _pyrepr(v):
    # repr as CPython spells it (None, True, False - Nython's repr shows
    # none, true, false), into containers: what str(signature) shows
    if v is None:
        return "None"
    if v is True:
        return "True"
    if v is False:
        return "False"
    if isinstance(v, tuple):
        if len(v) == 1:
            return "(" + _pyrepr(v[0]) + ",)"
        return "(" + ", ".join([_pyrepr(x) for x in v]) + ")"
    if isinstance(v, list):
        return "[" + ", ".join([_pyrepr(x) for x in v]) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join([_pyrepr(k) + ": " + _pyrepr(v[k]) for k in v]) + "}"
    return repr(v)


def _dget(d, k, default=None):
    # d.get(k, default) - but a dict read with `.` reads its key first here,
    # and a class namespace or a dict of parameters may hold a key "get"
    if k in d:
        return d[k]
    return default


def _dpop(d, k):
    var v = d[k]
    del d[k]
    return v


def _tname(x):
    if x is None:
        return "NoneType"
    return type(x).__name__


# ── the kind predicates ──────────────────────────────────────────────────────
def isclass(object):
    # isinstance(int, type) is false on this runtime; type(int) is type
    return isinstance(object, type) or type(object) is type


def ismodule(object):
    return isinstance(object, types.ModuleType)


def isfunction(object):
    return isinstance(object, types.FunctionType)


def ismethod(object):
    return isinstance(object, types.MethodType)


def isbuiltin(object):
    return isinstance(object, types.BuiltinFunctionType)


def ismethodwrapper(object):
    return isinstance(object, types.MethodWrapperType)


def isroutine(object):
    return (isbuiltin(object) or isfunction(object) or ismethod(object)
            or ismethoddescriptor(object) or ismethodwrapper(object))


def ismethoddescriptor(object):
    if isclass(object) or ismethod(object) or isfunction(object):
        return False
    var tp = type(object)
    return hasattr(tp, "__get__") and not hasattr(tp, "__set__") and not hasattr(tp, "__delete__") and not isinstance(object, (int, float, str, list, tuple, dict))


def isdatadescriptor(object):
    if isclass(object) or ismethod(object) or isfunction(object):
        return False
    if isinstance(object, property):
        return True
    var tp = type(object)
    return hasattr(tp, "__set__") or hasattr(tp, "__delete__")


def ismemberdescriptor(object):
    return isinstance(object, types.MemberDescriptorType)


def isgetsetdescriptor(object):
    return isinstance(object, types.GetSetDescriptorType)


def _fn_flags(f):
    # the engines' function kinds (1 generator, 2 coroutine, 4 async gen)
    while ismethod(f):
        f = f.__func__
    try:
        var info = _ny_fn_info(f)
    except Exception:
        return 0
    if info is None:
        return 0
    return info[4]


def _unwrap_partial(f):
    while type(f).__name__ == "partial" and hasattr(f, "func") and hasattr(f, "args"):
        f = f.func
    return f


def isgeneratorfunction(obj):
    return (_fn_flags(_unwrap_partial(obj)) & 1) != 0


def iscoroutinefunction(obj):
    var f = _unwrap_partial(obj)
    if getattr(f, "_is_coroutine_marker", None) is _is_coroutine_mark:
        return True
    if ismethod(f) and getattr(f.__func__, "_is_coroutine_marker", None) is _is_coroutine_mark:
        return True
    return (_fn_flags(f) & 2) != 0


def isasyncgenfunction(obj):
    return (_fn_flags(_unwrap_partial(obj)) & 4) != 0


class _CoroutineMark:
    def __repr__(self):
        return "<coroutine marker>"

_is_coroutine_mark = _CoroutineMark()


def markcoroutinefunction(func):
    # (3.12) iscoroutinefunction() is then true for func
    if hasattr(func, "__func__"):
        func = func.__func__
    func._is_coroutine_marker = _is_coroutine_mark
    return func


def isgenerator(object):
    return isinstance(object, types.GeneratorType)


def iscoroutine(object):
    return isinstance(object, types.CoroutineType)


def isasyncgen(object):
    return isinstance(object, types.AsyncGeneratorType)


def isawaitable(object):
    if isclass(object):
        return False
    return iscoroutine(object) or hasattr(type(object), "__await__")


def istraceback(object):
    return isinstance(object, types.TracebackType)


def isframe(object):
    return isinstance(object, types.FrameType)


def iscode(object):
    return isinstance(object, types.CodeType)


def isabstract(object):
    if not isclass(object):
        return False
    try:
        return bool(_dget(object.__dict__, "__abstractmethods__")) or bool(getattr(object, "__abstractmethods__", None))
    except Exception:
        return False


# ── members, MRO, docstrings ─────────────────────────────────────────────────
def getmro(cls):
    return cls.__mro__


def _getmembers(object, predicate, getter):
    var results = []
    var processed = set()
    var names = list(dir(object))
    var mro = ()
    if not isclass(object) and isclass(type(object)):
        # an instance's class attributes (dir() of an instance may list only
        # its own attributes here)
        for n in dir(type(object)):
            if n not in names:
                names.append(n)
    if isclass(object):
        mro = (object,) + tuple(getmro(object))
        try:
            for base in object.__bases__:
                var bd = base.__dict__
                for k in bd:
                    if isinstance(bd[k], types.DynamicClassAttribute):
                        names.append(k)
        except AttributeError:
            pass
    for key in names:
        var found = False
        var value = None
        try:
            value = getter(object, key)
            found = key not in processed
        except AttributeError:
            found = False
        if not found:
            for base in mro:
                var d = base.__dict__
                if key in d:
                    value = d[key]
                    found = True
                    break
        if not found:
            continue
        if not predicate or predicate(value):
            results.append((key, value))
        processed.add(key)
    results.sort(key=lambda pair: pair[0])
    return results


def getmembers(object, predicate=None):
    # (name, value) pairs of an object's members, sorted by name
    return _getmembers(object, predicate, getattr)


def getmembers_static(object, predicate=None):
    return _getmembers(object, predicate, getattr_static)


def _findclass(func):
    var qn = getattr(func, "__qualname__", "")
    var parts = qn.split(".")
    if len(parts) < 2 or "<locals>" in parts:
        return None
    var g = None
    try:
        g = func.__globals__
    except Exception:
        return None
    if parts[0] not in g:
        return None
    var cls = g[parts[0]]
    for name in parts[1:-1]:
        cls = getattr(cls, name, None)
        if cls is None:
            return None
    if not isclass(cls):
        return None
    return cls


def _finddoc(obj):
    var name = None
    var cls = None
    if isclass(obj):
        for base in obj.__mro__:
            if base is not object:
                var doc = getattr(base, "__doc__", None)
                if doc is not None:
                    return doc
        return None
    if ismethod(obj):
        name = obj.__func__.__name__
        var owner = obj.__self__
        if isclass(owner) and getattr(getattr(owner, name, None), "__func__", None) is obj.__func__:
            cls = owner
        else:
            cls = owner.__class__
    elif isfunction(obj):
        name = obj.__name__
        cls = _findclass(obj)
        if cls is None or getattr(cls, name, None) is not obj:
            return None
    else:
        return None
    for base in cls.__mro__:
        try:
            var d = getattr(base, name).__doc__
        except AttributeError:
            continue
        if d is not None:
            return d
    return None


def getdoc(object):
    # The documentation string, cleaned up; an undocumented method's
    # comes from the class it overrides
    var doc = None
    try:
        doc = object.__doc__
    except AttributeError:
        return None
    if doc is None:
        try:
            doc = _finddoc(object)
        except (AttributeError, TypeError):
            return None
    if not isinstance(doc, str):
        return None
    return cleandoc(doc)


def cleandoc(doc):
    # Remove the indentation uniformly removable from the second line on,
    # and leading/trailing blank lines
    var lines = doc.expandtabs().split("\n")
    var margin = None
    for line in lines[1:]:
        var content = len(line.lstrip())
        if content:
            var indent = len(line) - content
            if margin is None or indent < margin:
                margin = indent
    if lines:
        lines[0] = lines[0].lstrip()
    if margin is not None:
        for i in range(1, len(lines)):
            lines[i] = lines[i][margin:]
    while lines and not lines[-1]:
        lines.pop()
    while lines and not lines[0]:
        lines.pop(0)
    return "\n".join(lines)


class _Sentinel:
    def __repr__(self):
        return "<sentinel>"

_sentinel = _Sentinel()


def _class_dict(klass):
    try:
        return klass.__dict__
    except Exception:
        return {}


def getattr_static(obj, attr, default=_sentinel):
    # The attribute without running descriptors, properties or __getattr__:
    # the instance's own __dict__, then the classes of the MRO
    var klass_result = _sentinel
    var instance_result = _sentinel
    var mro = ()
    if not isclass(obj):
        var klass = type(obj)
        try:
            var d = obj.__dict__
            if attr in d:
                instance_result = d[attr]
        except Exception:
            pass
        if isclass(klass):
            mro = getattr(klass, "__mro__", ())
    else:
        mro = (obj,) + tuple(getattr(obj, "__mro__", ())[1:])
    for entry in mro:
        var cd = _class_dict(entry)
        if attr in cd:
            klass_result = cd[attr]
            break
    if instance_result is not _sentinel and (klass_result is _sentinel or not isdatadescriptor(klass_result)):
        return instance_result
    if klass_result is not _sentinel:
        return klass_result
    if isclass(obj):
        # the metaclass's attributes
        for entry in getattr(type(obj), "__mro__", ()):
            var md = _class_dict(entry)
            if attr in md:
                return md[attr]
    if default is not _sentinel:
        return default
    raise AttributeError(attr)


def unwrap(func, *, stop=None):
    # Follows the __wrapped__ chain from func to the innermost callable
    var f = func
    var memo = [f]
    while hasattr(f, "__wrapped__"):
        if stop is not None and stop(f):
            break
        f = f.__wrapped__
        for seen in memo:
            if seen is f:
                raise ValueError("wrapper loop when unwrapping " + repr(func))
        if len(memo) >= 1000:
            raise ValueError("wrapper loop when unwrapping " + repr(func))
        memo.append(f)
    return f


# ── annotations ──────────────────────────────────────────────────────────────
def get_annotations(obj, *, globals=None, locals=None, eval_str=False):
    # obj's annotations as a new dict; eval_str evaluates the ones kept as
    # strings (from __future__ import annotations, forward references)
    var ann = None
    var obj_globals = None
    var obj_locals = None
    var unwrap_obj = None
    if isclass(obj):
        var d = obj.__dict__
        ann = _dget(d, "__annotations__") if isinstance(d, dict) else None
        obj_globals = _class_globals(obj)
        obj_locals = dict(d)
        unwrap_obj = obj
    elif ismodule(obj):
        ann = getattr(obj, "__annotations__", None)
        obj_globals = obj if isinstance(obj, dict) else getattr(obj, "__dict__", None)
        unwrap_obj = None
    elif callable(obj):
        ann = getattr(obj, "__annotations__", None)
        obj_globals = getattr(obj, "__globals__", None)
        unwrap_obj = obj
    else:
        raise TypeError(repr(obj) + " is not a module, class, or callable.")
    if ann is None:
        return {}
    if not isinstance(ann, dict):
        raise ValueError(repr(obj) + ".__annotations__ is neither a dict nor None")
    if not ann:
        return {}
    if not eval_str:
        return dict(ann)
    if unwrap_obj is not None:
        while True:
            if hasattr(unwrap_obj, "__wrapped__"):
                unwrap_obj = unwrap_obj.__wrapped__
                continue
            if type(unwrap_obj).__name__ == "partial" and hasattr(unwrap_obj, "func"):
                unwrap_obj = unwrap_obj.func
                continue
            break
        if hasattr(unwrap_obj, "__globals__"):
            obj_globals = unwrap_obj.__globals__
    if globals is None:
        globals = obj_globals
    if locals is None:
        locals = obj_locals
    var out = {}
    for key in ann:
        var value = ann[key]
        out[key] = eval(value, globals, locals) if isinstance(value, str) else value
    return out


def _class_globals(cls):
    # The names of the module a class was defined in: its methods know them
    for k in cls.__dict__:
        var v = cls.__dict__[k]
        if isfunction(v):
            try:
                return v.__globals__
            except Exception:
                pass
    if getattr(cls, "__module__", None) == "__main__":
        return _ny_main_globals()
    return {}


def _type_repr_of(annotation):
    if annotation is None:
        return "None"
    if isinstance(annotation, types.GenericAlias):
        return repr(annotation)
    if isclass(annotation):
        var m = getattr(annotation, "__module__", "builtins")
        if m == "builtins":
            return annotation.__qualname__
        return m + "." + annotation.__qualname__
    if annotation is Ellipsis:
        return "..."
    return repr(annotation)


def formatannotation(annotation, base_module=None):
    if getattr(annotation, "__module__", None) == "typing" and not isclass(annotation):
        return repr(annotation).replace("typing.", "")
    if isinstance(annotation, types.GenericAlias):
        return str(annotation)
    if isclass(annotation):
        var m = getattr(annotation, "__module__", "builtins")
        if m == "builtins" or m == base_module:
            return annotation.__qualname__
        return m + "." + annotation.__qualname__
    return _pyrepr(annotation)


# ── Parameter kinds ──────────────────────────────────────────────────────────
class _ParameterKind:
    # An IntEnum member of CPython's: compares and hashes as its value
    def __init__(self, value, name, description):
        self.value = value
        self._value_ = value
        self.name = name
        self._name_ = name
        self.description = description

    def __int__(self):
        return self.value

    def __index__(self):
        return self.value

    def __hash__(self):
        return hash(self.value)

    def _other(self, other):
        if isinstance(other, _ParameterKind):
            return other.value
        if isinstance(other, int) and not isinstance(other, bool):
            return other
        return None

    def __eq__(self, other):
        var o = self._other(other)
        if o is None:
            return NotImplemented
        return self.value == o

    def __ne__(self, other):
        var o = self._other(other)
        if o is None:
            return NotImplemented
        return self.value != o

    def __lt__(self, other):
        var o = self._other(other)
        if o is None:
            return NotImplemented
        return self.value < o

    def __le__(self, other):
        var o = self._other(other)
        if o is None:
            return NotImplemented
        return self.value <= o

    def __gt__(self, other):
        var o = self._other(other)
        if o is None:
            return NotImplemented
        return self.value > o

    def __ge__(self, other):
        var o = self._other(other)
        if o is None:
            return NotImplemented
        return self.value >= o

    def __str__(self):
        return self.name

    def __repr__(self):
        return "<_ParameterKind." + self.name + ": " + str(self.value) + ">"

    def __reduce__(self):
        return self.name

_POSITIONAL_ONLY = _ParameterKind(0, "POSITIONAL_ONLY", "positional-only")
_POSITIONAL_OR_KEYWORD = _ParameterKind(1, "POSITIONAL_OR_KEYWORD", "positional or keyword")
_VAR_POSITIONAL = _ParameterKind(2, "VAR_POSITIONAL", "variadic positional")
_KEYWORD_ONLY = _ParameterKind(3, "KEYWORD_ONLY", "keyword-only")
_VAR_KEYWORD = _ParameterKind(4, "VAR_KEYWORD", "variadic keyword")
_KINDS = [_POSITIONAL_ONLY, _POSITIONAL_OR_KEYWORD, _VAR_POSITIONAL, _KEYWORD_ONLY, _VAR_KEYWORD]


def _kind_of(kind):
    # _ParameterKind(kind): a kind, or its value
    if isinstance(kind, _ParameterKind):
        return kind
    if isinstance(kind, int) and not isinstance(kind, bool) and 0 <= kind <= 4:
        return _KINDS[kind]
    raise ValueError("value " + repr(kind) + " is not a valid Parameter.kind")


class _void:
    """A private marker - used in Parameter & Signature."""


class _empty:
    """Marker object for Signature.empty and Parameter.empty."""


# ── Parameter ────────────────────────────────────────────────────────────────
class Parameter:
    """Represents a parameter in a function signature."""
    POSITIONAL_ONLY = _POSITIONAL_ONLY
    POSITIONAL_OR_KEYWORD = _POSITIONAL_OR_KEYWORD
    VAR_POSITIONAL = _VAR_POSITIONAL
    KEYWORD_ONLY = _KEYWORD_ONLY
    VAR_KEYWORD = _VAR_KEYWORD
    empty = _empty

    def __init__(self, name, kind, *, default=_empty, annotation=_empty):
        self._kind = _kind_of(kind)
        if default is not _empty:
            if self._kind is _VAR_POSITIONAL or self._kind is _VAR_KEYWORD:
                raise ValueError(self._kind.description + " parameters cannot have default values")
        self._default = default
        self._annotation = annotation
        if name is _empty:
            raise ValueError("name is a required attribute for Parameter")
        if not isinstance(name, str):
            raise TypeError("name must be a str, not a " + _tname(name))
        if len(name) > 1 and name[0] == "." and name[1:].isdigit():
            if self._kind is not _POSITIONAL_OR_KEYWORD:
                raise ValueError("implicit arguments must be passed as positional or keyword arguments, not " + self._kind.description)
            self._kind = _POSITIONAL_ONLY
            name = "implicit" + name[1:]
        var is_keyword = name in _kwlist and self._kind is not _POSITIONAL_ONLY
        if is_keyword or not name.isidentifier():
            raise ValueError(repr(name) + " is not a valid parameter name")
        self._name = name

    @property
    def name(self):
        return self._name

    @property
    def default(self):
        return self._default

    @property
    def annotation(self):
        return self._annotation

    @property
    def kind(self):
        return self._kind

    def replace(self, *, name=_void, kind=_void, annotation=_void, default=_void):
        if name is _void:
            name = self._name
        if kind is _void:
            kind = self._kind
        if annotation is _void:
            annotation = self._annotation
        if default is _void:
            default = self._default
        return type(self)(name, kind, default=default, annotation=annotation)

    def __str__(self):
        var kind = self._kind
        var formatted = self._name
        if self._annotation is not _empty:
            formatted = formatted + ": " + formatannotation(self._annotation)
        if self._default is not _empty:
            if self._annotation is not _empty:
                formatted = formatted + " = " + _pyrepr(self._default)
            else:
                formatted = formatted + "=" + _pyrepr(self._default)
        if kind is _VAR_POSITIONAL:
            formatted = "*" + formatted
        elif kind is _VAR_KEYWORD:
            formatted = "**" + formatted
        return formatted

    def __repr__(self):
        return "<" + type(self).__name__ + " \"" + str(self) + "\">"

    def __hash__(self):
        return hash((self._name, self._kind.value, repr(self._annotation), repr(self._default)))

    def __eq__(self, other):
        if self is other:
            return True
        if not isinstance(other, Parameter):
            return NotImplemented
        return (self._name == other._name and self._kind is other._kind
                and self._default == other._default and self._annotation == other._annotation)

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r


# ── BoundArguments ───────────────────────────────────────────────────────────
class BoundArguments:
    """Result of Signature.bind: the arguments mapped to the parameters."""

    def __init__(self, signature, arguments):
        self.arguments = arguments
        self._signature = signature

    @property
    def signature(self):
        return self._signature

    @property
    def args(self):
        var args = []
        var params = self._signature.parameters
        for param_name in params:
            var param = params[param_name]
            if param.kind is _VAR_KEYWORD or param.kind is _KEYWORD_ONLY:
                break
            if param_name not in self.arguments:
                break
            var arg = self.arguments[param_name]
            if param.kind is _VAR_POSITIONAL:
                args.extend(arg)
            else:
                args.append(arg)
        return tuple(args)

    @property
    def kwargs(self):
        var kwargs = {}
        var kwargs_started = False
        var params = self._signature.parameters
        for param_name in params:
            var param = params[param_name]
            if not kwargs_started:
                if param.kind is _VAR_KEYWORD or param.kind is _KEYWORD_ONLY:
                    kwargs_started = True
                elif param_name not in self.arguments:
                    kwargs_started = True
                    continue
            if not kwargs_started:
                continue
            if param_name in self.arguments:
                var arg = self.arguments[param_name]
                if param.kind is _VAR_KEYWORD:
                    for k in arg:
                        kwargs[k] = arg[k]
                else:
                    kwargs[param_name] = arg
        return kwargs

    def apply_defaults(self):
        # Fill in the defaults of the parameters not bound (() for *args,
        # {} for **kwargs)
        var arguments = self.arguments
        var new_arguments = {}
        var params = self._signature.parameters
        for name in params:
            var param = params[name]
            if name in arguments:
                new_arguments[name] = arguments[name]
            elif param.default is not _empty:
                new_arguments[name] = param.default
            elif param.kind is _VAR_POSITIONAL:
                new_arguments[name] = ()
            elif param.kind is _VAR_KEYWORD:
                new_arguments[name] = {}
        self.arguments = new_arguments

    def __eq__(self, other):
        if self is other:
            return True
        if not isinstance(other, BoundArguments):
            return NotImplemented
        return self.signature == other.signature and self.arguments == other.arguments

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    def __repr__(self):
        var args = []
        for arg in self.arguments:
            args.append(arg + "=" + _pyrepr(self.arguments[arg]))
        return "<" + type(self).__name__ + " (" + ", ".join(args) + ")>"


# ── Signature ────────────────────────────────────────────────────────────────
class Signature:
    """The signature of a callable: its Parameters and return annotation."""
    empty = _empty

    def __init__(self, parameters=None, *, return_annotation=_empty, __validate_parameters__=True):
        var params = {}
        if parameters is not None:
            if __validate_parameters__:
                var top_kind = _POSITIONAL_ONLY
                var seen_default = False
                for param in parameters:
                    var kind = param.kind
                    var name = param.name
                    if kind < top_kind:
                        raise ValueError("wrong parameter order: " + top_kind.description
                                         + " parameter before " + kind.description + " parameter")
                    elif kind > top_kind:
                        top_kind = kind
                    if kind is _POSITIONAL_ONLY or kind is _POSITIONAL_OR_KEYWORD:
                        if param.default is _empty:
                            if seen_default:
                                raise ValueError("non-default argument follows default argument")
                        else:
                            seen_default = True
                    if name in params:
                        raise ValueError("duplicate parameter name: " + repr(name))
                    params[name] = param
            else:
                for param in parameters:
                    params[param.name] = param
        self._parameters = types.MappingProxyType(params)
        self._return_annotation = return_annotation

    @classmethod
    def from_callable(cls, obj, *, follow_wrapped=True, globals=None, locals=None, eval_str=False):
        return _signature_from_callable(obj, follow_wrapped, True, globals, locals, eval_str, cls)

    @property
    def parameters(self):
        return self._parameters

    @property
    def return_annotation(self):
        return self._return_annotation

    def replace(self, *, parameters=_void, return_annotation=_void):
        if parameters is _void:
            parameters = list(self._parameters.values())
        if return_annotation is _void:
            return_annotation = self._return_annotation
        return type(self)(parameters, return_annotation=return_annotation)

    def _hash_basis(self):
        var params = tuple([p for p in self._parameters.values() if p.kind is not _KEYWORD_ONLY])
        var kwo = {}
        for p in self._parameters.values():
            if p.kind is _KEYWORD_ONLY:
                kwo[p.name] = p
        return (params, kwo, self._return_annotation)

    def __hash__(self):
        var b = self._hash_basis()
        var kw_names = sorted(list(b[1]))
        return hash((tuple([hash(p) for p in b[0]]), tuple([hash(b[1][k]) for k in kw_names]), repr(b[2])))

    def __eq__(self, other):
        if self is other:
            return True
        if not isinstance(other, Signature):
            return NotImplemented
        var a = self._hash_basis()
        var b = other._hash_basis()
        return a[0] == b[0] and a[1] == b[1] and a[2] == b[2]

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    def _bind(self, args, kwargs, partial=False):
        # CPython 3.11's algorithm and messages (inspect.Signature._bind)
        var arguments = {}
        var plist = list(self._parameters.values())
        var pi = 0
        var ai = 0
        var start_ex = -1
        kwargs = dict(kwargs)
        while True:
            if ai >= len(args):
                # no more positional arguments
                if pi >= len(plist):
                    break
                var param = plist[pi]
                pi = pi + 1
                if param.kind is _VAR_POSITIONAL:
                    break
                elif param.name in kwargs:
                    if param.kind is _POSITIONAL_ONLY:
                        raise TypeError(repr(param.name) + " parameter is positional only, but was passed as a keyword")
                    start_ex = pi - 1
                    break
                elif param.kind is _VAR_KEYWORD or param.default is not _empty:
                    start_ex = pi - 1
                    break
                else:
                    if partial:
                        start_ex = pi - 1
                        break
                    raise TypeError("missing a required argument: " + repr(param.name))
            else:
                var arg_val = args[ai]
                ai = ai + 1
                if pi >= len(plist):
                    raise TypeError("too many positional arguments")
                var param = plist[pi]
                pi = pi + 1
                if param.kind is _VAR_KEYWORD or param.kind is _KEYWORD_ONLY:
                    raise TypeError("too many positional arguments")
                if param.kind is _VAR_POSITIONAL:
                    var values = [arg_val]
                    while ai < len(args):
                        values.append(args[ai])
                        ai = ai + 1
                    arguments[param.name] = tuple(values)
                    break
                if param.name in kwargs and param.kind is not _POSITIONAL_ONLY:
                    raise TypeError("multiple values for argument " + repr(param.name))
                arguments[param.name] = arg_val
        var kwargs_param = None
        var rest = plist[start_ex:] if start_ex >= 0 else plist[pi:]
        for param in rest:
            if param.kind is _VAR_KEYWORD:
                kwargs_param = param
                continue
            if param.kind is _VAR_POSITIONAL:
                continue
            var param_name = param.name
            if param_name not in kwargs:
                if not partial and param.default is _empty:
                    raise TypeError("missing a required argument: " + repr(param_name))
            else:
                if param.kind is _POSITIONAL_ONLY:
                    raise TypeError(repr(param.name) + " parameter is positional only, but was passed as a keyword")
                arguments[param_name] = kwargs[param_name]
                del kwargs[param_name]
        if kwargs:
            if kwargs_param is not None:
                arguments[kwargs_param.name] = kwargs
            else:
                raise TypeError("got an unexpected keyword argument " + repr(list(kwargs)[0]))
        return BoundArguments(self, arguments)

    def bind(self, /, *args, **kwargs):
        # BoundArguments for this call, or TypeError if it does not fit
        return self._bind(args, kwargs)

    def bind_partial(self, /, *args, **kwargs):
        return self._bind(args, kwargs, True)

    def __str__(self):
        var result = []
        var render_pos_only_separator = False
        var render_kw_only_separator = True
        for param in self._parameters.values():
            var formatted = str(param)
            var kind = param.kind
            if kind is _POSITIONAL_ONLY:
                render_pos_only_separator = True
            elif render_pos_only_separator:
                result.append("/")
                render_pos_only_separator = False
            if kind is _VAR_POSITIONAL:
                render_kw_only_separator = False
            elif kind is _KEYWORD_ONLY and render_kw_only_separator:
                result.append("*")
                render_kw_only_separator = False
            result.append(formatted)
        if render_pos_only_separator:
            result.append("/")
        var rendered = "(" + ", ".join(result) + ")"
        if self._return_annotation is not _empty:
            rendered = rendered + " -> " + formatannotation(self._return_annotation)
        return rendered

    def __repr__(self):
        return "<" + type(self).__name__ + " " + str(self) + ">"


# ── signature() ──────────────────────────────────────────────────────────────
def _signature_bound_method(sig):
    var params = list(sig.parameters.values())
    if not params or params[0].kind is _VAR_KEYWORD or params[0].kind is _KEYWORD_ONLY:
        raise ValueError("invalid method signature")
    var kind = params[0].kind
    if kind is _POSITIONAL_OR_KEYWORD or kind is _POSITIONAL_ONLY:
        params = params[1:]
    return sig.replace(parameters=params)


def _signature_from_function(cls, func, globals=None, locals=None, eval_str=False):
    var info = _ny_fn_info(func)
    if info is None:
        raise TypeError(repr(func) + " is not a Python function")
    var annotations = get_annotations(func, globals=globals, locals=locals, eval_str=eval_str)
    var ret = _dget(annotations, "return", _empty)
    var params = []
    for p in info[3]:
        var name = p[0]
        var default = p[3] if p[2] else _empty
        params.append(Parameter(name, _KINDS[p[1]], default=default, annotation=_dget(annotations, name, _empty)))
    return cls(params, return_annotation=ret, __validate_parameters__=False)


def _is_partial(obj):
    return type(obj).__name__ == "partial" and hasattr(obj, "func") and hasattr(obj, "args") and hasattr(obj, "keywords")


def _signature_get_partial(wrapped_sig, partial, extra_args=()):
    var old_params = wrapped_sig.parameters
    var new_params = {}
    for k in old_params:
        new_params[k] = old_params[k]
    var partial_args = tuple(partial.args or ())
    var partial_keywords = partial.keywords or {}
    if extra_args:
        partial_args = tuple(extra_args) + partial_args
    var ba = None
    try:
        ba = wrapped_sig.bind_partial(*partial_args, **partial_keywords)
    except TypeError:
        raise ValueError("partial object " + repr(partial) + " has incorrect arguments")
    var transform_to_kwonly = False
    var moved = []
    for param_name in old_params:
        var param = old_params[param_name]
        if param_name in ba.arguments:
            var arg_value = ba.arguments[param_name]
            if param.kind is _POSITIONAL_ONLY:
                _dpop(new_params, param_name)
                continue
            if param.kind is _POSITIONAL_OR_KEYWORD:
                if param_name in partial_keywords:
                    transform_to_kwonly = True
                    new_params[param_name] = param.replace(default=arg_value)
                else:
                    _dpop(new_params, param_name)
                    continue
            if param.kind is _KEYWORD_ONLY:
                new_params[param_name] = param.replace(default=arg_value)
        if transform_to_kwonly:
            if param.kind is _POSITIONAL_OR_KEYWORD:
                var np = _dpop(new_params, param_name).replace(kind=_KEYWORD_ONLY)
                new_params[param_name] = np
            elif param.kind is _KEYWORD_ONLY or param.kind is _VAR_KEYWORD:
                var keep = _dpop(new_params, param_name)
                new_params[param_name] = keep
            elif param.kind is _VAR_POSITIONAL:
                _dpop(new_params, param_name)
    return wrapped_sig.replace(parameters=[new_params[k] for k in new_params])


# The text signatures CPython 3.11's builtins carry (__text_signature__),
# for the same builtins here (the natives carry none)
_BUILTIN_SIGS = {
    "abs": "(x, /)", "all": "(iterable, /)", "any": "(iterable, /)", "ascii": "(obj, /)",
    "bin": "(number, /)", "callable": "(obj, /)", "chr": "(i, /)",
    "compile": "(source, filename, mode, flags=0, dont_inherit=False, optimize=-1, *, _feature_version=-1)",
    "delattr": "(obj, name, /)", "divmod": "(x, y, /)", "eval": "(source, globals=None, locals=None, /)",
    "exec": "(source, globals=None, locals=None, /, *, closure=None)", "format": "(value, format_spec='', /)",
    "globals": "()", "hasattr": "(obj, name, /)", "hash": "(obj, /)", "hex": "(number, /)", "id": "(obj, /)",
    "input": "(prompt='', /)", "isinstance": "(obj, class_or_tuple, /)", "issubclass": "(cls, class_or_tuple, /)",
    "len": "(obj, /)", "locals": "()", "oct": "(number, /)", "ord": "(c, /)", "pow": "(base, exp, mod=None)",
    "print": "(*args, sep=' ', end='\\n', file=None, flush=False)", "repr": "(obj, /)",
    "round": "(number, ndigits=None)", "setattr": "(obj, name, value, /)",
    "sorted": "(iterable, /, *, key=None, reverse=False)", "sum": "(iterable, /, start=0)",
}


def _split_top(text):
    # the comma-separated pieces of text, not split inside brackets or strings
    var out = []
    var cur = ""
    var depth = 0
    var quote = ""
    var i = 0
    while i < len(text):
        var c = text[i]
        if quote:
            cur = cur + c
            if c == "\\" and i + 1 < len(text):
                cur = cur + text[i + 1]
                i = i + 2
                continue
            if c == quote:
                quote = ""
        elif c == "'" or c == "\"":
            quote = c
            cur = cur + c
        elif c in "([{":
            depth = depth + 1
            cur = cur + c
        elif c in ")]}":
            depth = depth - 1
            cur = cur + c
        elif c == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur = cur + c
        i = i + 1
    if cur.strip():
        out.append(cur.strip())
    return out


def _signature_fromstr(cls, text):
    # A Signature from a text signature such as "(obj, /, *, key=None)"
    var pieces = _split_top(text.strip()[1:-1])
    var params = []
    var kind = _POSITIONAL_OR_KEYWORD
    for piece in pieces:
        if piece == "/":
            params = [p.replace(kind=_POSITIONAL_ONLY) for p in params]
            continue
        if piece == "*":
            kind = _KEYWORD_ONLY
            continue
        if piece.startswith("**"):
            params.append(Parameter(piece[2:], _VAR_KEYWORD))
            continue
        if piece.startswith("*"):
            params.append(Parameter(piece[1:], _VAR_POSITIONAL))
            kind = _KEYWORD_ONLY
            continue
        if "=" in piece:
            var at = piece.index("=")
            params.append(Parameter(piece[:at].strip(), kind, default=eval(piece[at + 1:].strip())))
        else:
            params.append(Parameter(piece, kind))
    return cls(params, __validate_parameters__=False)


# the builtins those signatures belong to (a builtin is matched by identity:
# a method of a builtin value can share the name)
_BUILTIN_OBJS = [abs, all, any, ascii, bin, callable, chr, compile, delattr, divmod, eval, exec, format,
                 globals, hasattr, hash, hex, id, input, isinstance, issubclass, len, locals, oct, ord,
                 pow, print, repr, round, setattr, sorted, sum]


def _builtin_signature(cls, obj):
    var name = getattr(obj, "__name__", None)
    if isinstance(name, str) and name in _BUILTIN_SIGS:
        for b in _BUILTIN_OBJS:
            if b is obj:
                return _signature_fromstr(cls, _BUILTIN_SIGS[name])
    raise ValueError("no signature found for builtin " + repr(obj))


def _user_method(cls, name):
    # a user-defined (Python) function `name` of a class, through its MRO
    for base in getattr(cls, "__mro__", (cls,)):
        var d = _class_dict(base)
        if name in d:
            var m = d[name]
            if _ny_fn_info(m) is not None or isinstance(m, (staticmethod, classmethod)):
                return m
            return None
    return None


def _signature_from_callable(obj, follow_wrapped=True, skip_bound_arg=True, globals=None,
                             locals=None, eval_str=False, sigcls=None):
    if sigcls is None:
        sigcls = Signature
    if not callable(obj):
        raise TypeError(repr(obj) + " is not a callable object")
    if ismethod(obj):
        var msig = _signature_from_callable(obj.__func__, follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls)
        if skip_bound_arg:
            return _signature_bound_method(msig)
        return msig
    if follow_wrapped:
        obj = unwrap(obj, stop=lambda f: hasattr(f, "__signature__") or ismethod(f))
        if ismethod(obj):
            return _signature_from_callable(obj, follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls)
    var sig = getattr(obj, "__signature__", None) if not isclass(obj) or "__signature__" in _class_dict(obj) else None
    if sig is not None:
        if not isinstance(sig, Signature):
            raise TypeError("unexpected object " + repr(sig) + " in __signature__ attribute")
        return sig
    if isfunction(obj):
        return _signature_from_function(sigcls, obj, globals, locals, eval_str)
    if isbuiltin(obj):
        return _builtin_signature(sigcls, obj)
    if _is_partial(obj):
        var wrapped_sig = _signature_from_callable(obj.func, follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls)
        return _signature_get_partial(wrapped_sig, obj)
    if isclass(obj):
        if not hasattr(obj, "__mro__") or type(obj) == "builtin":
            raise ValueError("no signature found for builtin type " + repr(obj))
        # a metaclass's __call__
        var meta = type(obj)
        if meta is not type and isclass(meta):
            var call = _user_method(meta, "__call__")
            if call is not None:
                return _signature_bound_method(_signature_from_callable(call, follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls))
        for base in obj.__mro__:
            var d = _class_dict(base)
            if "__new__" in d and _ny_fn_info(d["__new__"]) is not None and _tname(base) != "builtin" and base.__name__ != "object":
                var nsig = _signature_from_callable(d["__new__"], follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls)
                if skip_bound_arg:
                    nsig = _signature_bound_method(nsig)
                return nsig
            if "__init__" in d and _ny_fn_info(d["__init__"]) is not None and base.__name__ != "object":
                var isig = _signature_from_callable(d["__init__"], follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls)
                if skip_bound_arg:
                    isig = _signature_bound_method(isig)
                return isig
        for base in obj.__mro__:
            if base.__module__ == "builtins" and base.__name__ != "object":
                raise ValueError("no signature found for builtin type " + repr(base))
        return sigcls([])
    # an object with __call__
    var call = _user_method(type(obj), "__call__")
    if call is not None:
        return _signature_bound_method(_signature_from_callable(call, follow_wrapped, skip_bound_arg, globals, locals, eval_str, sigcls))
    raise ValueError("callable " + repr(obj) + " is not supported by signature")


def signature(obj, *, follow_wrapped=True, globals=None, locals=None, eval_str=False):
    # The Signature of a callable
    return Signature.from_callable(obj, follow_wrapped=follow_wrapped, globals=globals, locals=locals, eval_str=eval_str)


# ── getfullargspec, getcallargs ──────────────────────────────────────────────
class FullArgSpec:
    # FullArgSpec(args, varargs, varkw, defaults, kwonlyargs, kwonlydefaults,
    # annotations): CPython's named tuple
    _fields = ("args", "varargs", "varkw", "defaults", "kwonlyargs", "kwonlydefaults", "annotations")

    def __init__(self, args, varargs, varkw, defaults, kwonlyargs, kwonlydefaults, annotations):
        self.args = args
        self.varargs = varargs
        self.varkw = varkw
        self.defaults = defaults
        self.kwonlyargs = kwonlyargs
        self.kwonlydefaults = kwonlydefaults
        self.annotations = annotations
        self._values = (args, varargs, varkw, defaults, kwonlyargs, kwonlydefaults, annotations)

    def __getitem__(self, i):
        return self._values[i]

    def __len__(self):
        return 7

    def __iter__(self):
        return iter(list(self._values))

    def __eq__(self, other):
        if isinstance(other, FullArgSpec):
            return self._values == other._values
        return self._values == other

    def __repr__(self):
        var parts = []
        for i in range(7):
            parts.append(self._fields[i] + "=" + repr(self._values[i]))
        return "FullArgSpec(" + ", ".join(parts) + ")"


def getfullargspec(func):
    # CPython's FullArgSpec, from the signature (bound methods keep self,
    # as CPython's does)
    var sig = None
    try:
        sig = _signature_from_callable(func, False, False)
    except Exception:
        raise TypeError("unsupported callable")
    var args = []
    var varargs = None
    var varkw = None
    var posonlyargs = []
    var kwonlyargs = []
    var annotations = {}
    var defaults = ()
    var kwdefaults = {}
    if sig.return_annotation is not _empty:
        annotations["return"] = sig.return_annotation
    for param in sig.parameters.values():
        var kind = param.kind
        var name = param.name
        if kind is _POSITIONAL_ONLY:
            posonlyargs.append(name)
            if param.default is not _empty:
                defaults = defaults + (param.default,)
        elif kind is _POSITIONAL_OR_KEYWORD:
            args.append(name)
            if param.default is not _empty:
                defaults = defaults + (param.default,)
        elif kind is _VAR_POSITIONAL:
            varargs = name
        elif kind is _KEYWORD_ONLY:
            kwonlyargs.append(name)
            if param.default is not _empty:
                kwdefaults[name] = param.default
        elif kind is _VAR_KEYWORD:
            varkw = name
        if param.annotation is not _empty:
            annotations[name] = param.annotation
    if not kwdefaults:
        kwdefaults = None
    if not defaults:
        defaults = None
    return FullArgSpec(posonlyargs + args, varargs, varkw, defaults, kwonlyargs, kwdefaults, annotations)


def _missing_arguments(f_name, argnames, pos, values):
    var names = [repr(name) for name in argnames if name not in values]
    var missing = len(names)
    var s = ""
    if missing == 1:
        s = names[0]
    elif missing == 2:
        s = names[0] + " and " + names[1]
    else:
        s = ", ".join(names[:-2]) + ", " + names[-2] + " and " + names[-1]
    raise TypeError(f_name + "() missing " + str(missing) + " required " + ("positional" if pos else "keyword-only")
                    + " argument" + ("" if missing == 1 else "s") + ": " + s)


def _too_many(f_name, args, kwonly, varargs, defcount, given, values):
    var atleast = len(args) - defcount
    var kwonly_given = len([arg for arg in kwonly if arg in values])
    var plural = False
    var sig = ""
    if varargs:
        plural = atleast != 1
        sig = "at least " + str(atleast)
    elif defcount:
        plural = True
        sig = "from " + str(atleast) + " to " + str(len(args))
    else:
        plural = len(args) != 1
        sig = str(len(args))
    var kwonly_sig = ""
    if kwonly_given:
        kwonly_sig = (" positional argument" + ("s" if given != 1 else "") + " (and " + str(kwonly_given)
                      + " keyword-only argument" + ("s" if kwonly_given != 1 else "") + ")")
    raise TypeError(f_name + "() takes " + sig + " positional argument" + ("s" if plural else "") + " but "
                    + str(given) + kwonly_sig + " " + ("was" if given == 1 and not kwonly_given else "were") + " given")


def getcallargs(func, /, *positional, **named):
    # {parameter: value} for a call, as CPython's (its algorithm, the order
    # of the dict and its TypeErrors)
    var spec = getfullargspec(func)
    var args = spec.args
    var varargs = spec.varargs
    var varkw = spec.varkw
    var defaults = spec.defaults
    var kwonlyargs = spec.kwonlyargs
    var kwonlydefaults = spec.kwonlydefaults
    var f_name = func.__name__
    var arg2value = {}
    if ismethod(func) and func.__self__ is not None:
        positional = (func.__self__,) + tuple(positional)
    var num_pos = len(positional)
    var num_args = len(args)
    var num_defaults = len(defaults) if defaults else 0
    var n = min(num_pos, num_args)
    for i in range(n):
        arg2value[args[i]] = positional[i]
    if varargs:
        arg2value[varargs] = tuple(positional[n:])
    var possible_kwargs = set(args + kwonlyargs)
    if varkw:
        arg2value[varkw] = {}
    for kw in named:
        var value = named[kw]
        if kw not in possible_kwargs:
            if not varkw:
                raise TypeError(f_name + "() got an unexpected keyword argument " + repr(kw))
            arg2value[varkw][kw] = value
            continue
        if kw in arg2value:
            raise TypeError(f_name + "() got multiple values for argument " + repr(kw))
        arg2value[kw] = value
    if num_pos > num_args and not varargs:
        _too_many(f_name, args, kwonlyargs, varargs, num_defaults, num_pos, arg2value)
    if num_pos < num_args:
        var req = args[:num_args - num_defaults]
        for arg in req:
            if arg not in arg2value:
                _missing_arguments(f_name, req, True, arg2value)
        var rest = args[num_args - num_defaults:]
        for i in range(len(rest)):
            if rest[i] not in arg2value:
                arg2value[rest[i]] = defaults[i]
    var missing = 0
    for kwarg in kwonlyargs:
        if kwarg not in arg2value:
            if kwonlydefaults and kwarg in kwonlydefaults:
                arg2value[kwarg] = kwonlydefaults[kwarg]
            else:
                missing = missing + 1
    if missing:
        _missing_arguments(f_name, kwonlyargs, False, arg2value)
    return arg2value


# ── source code ──────────────────────────────────────────────────────────────
def getfile(object):
    # The file an object was defined in
    if ismodule(object):
        var f = getattr(object, "__file__", None)
        if f:
            return f
        raise TypeError(repr(object) + " is a built-in module")
    if isclass(object):
        if hasattr(object, "__module__") and object.__module__ != "builtins":
            for k in _class_dict(object):
                var v = _class_dict(object)[k]
                if isfunction(v):
                    return v.__code__.co_filename
            var g = _class_globals(object)
            if g and "__file__" in g:
                return g["__file__"]
            if object.__module__ == "__main__":
                raise OSError("source code not available")
        raise TypeError(repr(object) + " is a built-in class")
    if ismethod(object):
        object = object.__func__
    if isfunction(object):
        object = object.__code__
    if istraceback(object):
        object = object.tb_frame
    if isframe(object):
        object = object.f_code
    if iscode(object):
        return object.co_filename
    raise TypeError("module, class, method, function, traceback, frame, or code object was expected, got " + _tname(object))


def getsourcefile(object):
    var filename = getfile(object)
    if filename.endswith(".ny") or filename.endswith(".py"):
        return filename
    return None


def getmodulename(path):
    var fname = path.replace("\\", "/").split("/")[-1]
    for suffix in [".ny", ".py", ".pyc"]:
        if fname.endswith(suffix) and len(fname) > len(suffix):
            return fname[:len(fname) - len(suffix)]
    return None


def getmodule(object, _filename=None):
    # The module an object was defined in, when it is one this program
    # imported (or the main program's globals for __main__)
    if ismodule(object):
        return object
    var g = None
    if ismethod(object):
        object = object.__func__
    if isfunction(object):
        try:
            g = object.__globals__
        except Exception:
            g = None
    elif isclass(object):
        g = _class_globals(object)
    if g is None:
        return None
    var m = types.ModuleType(getattr(object, "__module__", "__main__"))
    for k in g:
        try:
            setattr(m, k, g[k])
        except Exception:
            pass
    return m


def indentsize(line):
    var expline = line.expandtabs()
    return len(expline) - len(expline.lstrip())


def _read_lines(filename):
    try:
        var f = open(filename)
    except Exception:
        raise OSError("could not get source code")
    var text = f.read()
    f.close()
    var lines = text.split("\n")
    var out = [ln + "\n" for ln in lines[:-1]]
    if lines[-1] != "":
        out.append(lines[-1])
    return out


def _scan_line(line, state):
    # Brackets still open and the string still open at the end of `line`
    # (state = [depth, quote]): enough of tokenize to know where a logical
    # line ends
    var depth = state[0]
    var quote = state[1]
    var i = 0
    var n = len(line)
    while i < n:
        var c = line[i]
        if quote:
            if c == "\\":
                i = i + 2
                continue
            if line[i:i + len(quote)] == quote:
                i = i + len(quote)
                quote = ""
                continue
            i = i + 1
            continue
        if c == "#":
            break
        if c == "\"" or c == "'":
            var q3 = line[i:i + 3]
            if q3 == c * 3:
                quote = q3
                i = i + 3
            else:
                quote = c
                i = i + 1
            continue
        if c in "([{":
            depth = depth + 1
        elif c in ")]}":
            depth = depth - 1
        i = i + 1
    if len(quote) == 1:
        if not line.rstrip("\n").endswith("\\"):
            quote = ""
    return [depth, quote]


def _logical_end(lines, start):
    # the index of the last physical line of the logical line at `start`
    var state = [0, ""]
    var i = start
    while i < len(lines):
        state = _scan_line(lines[i], state)
        var cont = lines[i].rstrip("\n").endswith("\\") and not state[1]
        if state[0] <= 0 and not state[1] and not cont:
            return i
        i = i + 1
    return len(lines) - 1


def getblock(lines):
    # The lines of the block at the top of `lines` (a def, a class, or a
    # lambda's logical line); decorators before it are part of it
    if not lines:
        return []
    var i = 0
    while i < len(lines) and lines[i].lstrip().startswith("@"):
        i = _logical_end(lines, i) + 1
    if i >= len(lines):
        return list(lines)
    var head = lines[i].lstrip()
    var is_def = head.startswith("def ") or head.startswith("class ") or head.startswith("async def ") or head.startswith("fn ")
    var end = _logical_end(lines, i)
    if not is_def:
        return list(lines[:end + 1])
    # a one-line body (`def f(): return 1`)
    var header = "".join(lines[i:end + 1]).rstrip()
    if not header.endswith(":") and ":" in header:
        var tail = header.split("#")[0].rstrip()
        if not tail.endswith(":"):
            return list(lines[:end + 1])
    var base = indentsize(lines[i])
    var last = end
    var j = end + 1
    while j < len(lines):
        var stripped = lines[j].strip()
        if stripped == "" or stripped.startswith("#"):
            j = j + 1
            continue
        if indentsize(lines[j]) <= base:
            break
        last = _logical_end(lines, j)
        j = last + 1
    return list(lines[:last + 1])


def _class_line(lines, qualname):
    # the line where class `qualname` ("Outer.Inner") is defined
    var parts = qualname.split(".")
    var start = 0
    var indent = -1
    var found = -1
    for name in parts:
        found = -1
        var i = start
        while i < len(lines):
            var line = lines[i]
            var s = line.lstrip()
            var ind = indentsize(line)
            if s and not s.startswith("#") and indent >= 0 and ind <= indent and i > start:
                break
            if (s.startswith("class " + name + "(") or s.startswith("class " + name + ":")
                    or s.startswith("class " + name + " ")) and ind > indent:
                found = i
                break
            i = i + 1
        if found < 0:
            return -1
        indent = indentsize(lines[found])
        start = found
    return found


def findsource(object):
    # (all the lines of the file, the index of the object's first line)
    var file = getsourcefile(object)
    if file is None:
        raise OSError("source code not available")
    var lines = _read_lines(file)
    if not lines:
        raise OSError("could not get source code")
    if ismodule(object):
        return (lines, 0)
    if isclass(object):
        var at = _class_line(lines, object.__qualname__)
        if at < 0:
            raise OSError("could not find class definition")
        while at > 0 and lines[at - 1].lstrip().startswith("@") and indentsize(lines[at - 1]) == indentsize(lines[at]):
            at = at - 1
        return (lines, at)
    if ismethod(object):
        object = object.__func__
    if isfunction(object):
        object = object.__code__
    if iscode(object):
        var lnum = object.co_firstlineno - 1
        if lnum < 0 or lnum >= len(lines):
            raise OSError("lineno is out of bounds")
        return (lines, lnum)
    raise OSError("could not find code object")


def getsourcelines(object):
    # (the source lines of the object, the line number of the first)
    object = unwrap(object)
    var found = findsource(object)
    var lines = found[0]
    var lnum = found[1]
    if ismodule(object):
        return (lines, 0)
    return (getblock(lines[lnum:]), lnum + 1)


def getsource(object):
    return "".join(getsourcelines(object)[0])


def getcomments(object):
    # The comment lines just above an object's definition (or at the top
    # of a module's file), or None
    var found = None
    try:
        found = findsource(object)
    except (OSError, TypeError):
        return None
    var lines = found[0]
    var lnum = found[1]
    if ismodule(object):
        var start = 0
        if lines and lines[0][:2] == "#!":
            start = 1
        while start < len(lines) and lines[start].strip() in ("", "#"):
            start = start + 1
        var comments = []
        while start < len(lines) and lines[start].strip()[:1] == "#":
            comments.append(lines[start].expandtabs())
            start = start + 1
        return "".join(comments) if comments else None
    if lnum <= 0:
        return None
    var indent = indentsize(lines[lnum])
    var end = lnum - 1
    if end >= 0 and lines[end].lstrip()[:1] == "#" and indentsize(lines[end]) == indent:
        var comments = [lines[end].expandtabs().lstrip()]
        end = end - 1
        while end >= 0 and lines[end].lstrip()[:1] == "#" and indentsize(lines[end]) == indent:
            comments.insert(0, lines[end].expandtabs().lstrip())
            end = end - 1
        while comments and comments[0].strip() == "#":
            comments.pop(0)
        while comments and comments[-1].strip() == "#":
            comments.pop()
        return "".join(comments) if comments else None
    return None


def currentframe():
    # The runtime has no frame objects: None, as CPython documents for
    # implementations without stack frame support
    return None


# ── signature_diff (Nython) ──────────────────────────────────────────────────
def _params_of(sig):
    return list(sig.parameters.values())


def signature_diff(expected, actual):
    # Why a callable with signature `actual` cannot replace one with
    # signature `expected`: every call `expected` accepts must bind to
    # `actual` (Liskov substitutability for calls - what a type checker
    # checks for an overriding method). Arguments may be callables or
    # Signatures. An empty list: `actual` accepts every such call.
    if not isinstance(expected, Signature):
        expected = signature(expected)
    if not isinstance(actual, Signature):
        actual = signature(actual)
    var problems = []
    var ep = _params_of(expected)
    var ap = _params_of(actual)
    var a_by_name = {}
    for p in ap:
        a_by_name[p.name] = p
    var a_varpos = None
    var a_varkw = None
    for p in ap:
        if p.kind is _VAR_POSITIONAL:
            a_varpos = p
        if p.kind is _VAR_KEYWORD:
            a_varkw = p
    var a_positional = [p for p in ap if p.kind is _POSITIONAL_ONLY or p.kind is _POSITIONAL_OR_KEYWORD]
    var e_positional = [p for p in ep if p.kind is _POSITIONAL_ONLY or p.kind is _POSITIONAL_OR_KEYWORD]
    # positional slots: expected's i-th positional argument lands on actual's i-th
    for i in range(len(e_positional)):
        var e = e_positional[i]
        if i < len(a_positional):
            var a = a_positional[i]
            if e.kind is _POSITIONAL_OR_KEYWORD and a.name != e.name and a_varkw is None:
                problems.append("parameter " + repr(e.name) + " is called " + repr(a.name) + ": a call passing " + e.name + "= by keyword fails")
            if e.kind is _POSITIONAL_OR_KEYWORD and a.kind is _POSITIONAL_ONLY:
                problems.append("parameter " + repr(e.name) + " is positional-only: a call passing it by keyword fails")
            if e.default is not _empty and a.default is _empty:
                problems.append("parameter " + repr(a.name) + " has no default: a call omitting " + repr(e.name) + " fails")
        elif a_varpos is None:
            problems.append("no parameter takes positional argument " + str(i + 1) + " (" + repr(e.name) + ")")
    for i in range(len(e_positional), len(a_positional)):
        var a = a_positional[i]
        if a.default is _empty:
            problems.append("extra required parameter " + repr(a.name) + ": calls that " + "omit it fail")
    for e in ep:
        if e.kind is _VAR_POSITIONAL and a_varpos is None:
            problems.append("no *" + e.name + ": calls with extra positional arguments fail")
        if e.kind is _VAR_KEYWORD and a_varkw is None:
            problems.append("no **" + e.name + ": calls with extra keyword arguments fail")
        if e.kind is _KEYWORD_ONLY:
            var a = _dget(a_by_name, e.name)
            if a is None or a.kind is _POSITIONAL_ONLY or a.kind is _VAR_POSITIONAL:
                if a_varkw is None:
                    problems.append("no parameter takes keyword argument " + repr(e.name))
            elif e.default is not _empty and a.default is _empty:
                problems.append("parameter " + repr(a.name) + " has no default: a call omitting " + repr(e.name) + " fails")
    for a in ap:
        if a.kind is _KEYWORD_ONLY and a.default is _empty:
            var e = None
            for x in ep:
                if x.name == a.name and x.kind is not _POSITIONAL_ONLY and x.kind is not _VAR_POSITIONAL:
                    e = x
            if e is None:
                problems.append("extra required keyword-only parameter " + repr(a.name))
    return problems
