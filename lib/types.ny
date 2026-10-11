# nython: module    (import it by name: it runs in a module scope of its own)
# lib/types.ny - Python's types module (round 77): names for the types of
# the runtime's values, and helpers for making classes dynamically.
#
#     import types
#     isinstance(f, types.FunctionType)
#     ns = types.SimpleNamespace(a=1, b=2)
#
# SimpleNamespace(mapping_or_iterable=(), /, **kwargs)
#                         attribute namespace; repr namespace(a=1, b=2) in
#                         insertion order (a subclass shows its own name),
#                         == compares the attributes, recursive repr guarded
# MappingProxyType(m)     a read-only live view of a mapping: [] get keys
#                         values items copy len in iter reversed | ==, and
#                         Python's TypeErrors for item assignment/deletion
# ModuleType(name, doc=None)
#                         a module object (__name__ __doc__ __package__
#                         __loader__ __spec__, attributes); isinstance() is
#                         also true for the namespaces `import m` binds
# FunctionType, LambdaType, MethodType, BuiltinFunctionType,
# BuiltinMethodType, GeneratorType, NoneType
#                         the runtime's own type objects: type(f) is
#                         FunctionType, type(obj.m) is MethodType,
#                         type(len) and type([].append) BuiltinFunctionType,
#                         type(None) is NoneType (NoneType() is None);
#                         MethodType(func, obj) binds func to obj (__func__
#                         __self__; a callable that is not a function gives
#                         a binding of another type)
# AsyncGeneratorType, CoroutineType, CodeType, CellType, FrameType,
# TracebackType, WrapperDescriptorType, MethodWrapperType,
# MethodDescriptorType, ClassMethodDescriptorType, GetSetDescriptorType,
# MemberDescriptorType, NotImplementedType
#                         stand-ins (see below) whose isinstance() is true
#                         for the corresponding values of both engines
# EllipsisType            type(...)          GenericAlias  list[int]'s type
# UnionType               int | str's type
# new_class(name, bases=(), kwds=None, exec_body=None)
# prepare_class(name, bases=(), kwds=None) -> (metaclass, namespace, kwds)
# resolve_bases(bases)    __mro_entries__ applied, as class statements do
# get_original_bases(cls) (3.12) __orig_bases__ or __bases__
# DynamicClassAttribute   a property that routes class-level access to the
#                         metaclass's __getattr__ (enum uses it)
# coroutine(func)         marks a generator function as a coroutine
#
# How the stand-ins work: the runtime has no type object for coroutines,
# code, frames, tracebacks, cells or the C-level descriptors, so those are
# classes whose metaclass answers isinstance() by asking what the value is.
# NotImplementedType() returns NotImplemented. FunctionType(code, globals)
# cannot build a function (there is no code object to run): it raises
# TypeError.
#
# Not here: CapsuleType (3.13), the frame/traceback/code objects themselves
# (the stand-ins recognise duck-typed ones), types.coroutine making a
# generator awaitable (it marks the function; the engines' await takes
# generator-based awaitables as they are), coroutine objects (they are task
# handles - ints - on both engines, so CoroutineType matches nothing).

__all__ = ["FunctionType", "LambdaType", "CodeType", "MappingProxyType", "SimpleNamespace",
           "CellType", "GeneratorType", "CoroutineType", "AsyncGeneratorType", "MethodType",
           "BuiltinFunctionType", "BuiltinMethodType", "WrapperDescriptorType",
           "MethodWrapperType", "MethodDescriptorType", "ClassMethodDescriptorType",
           "ModuleType", "TracebackType", "FrameType", "GetSetDescriptorType",
           "MemberDescriptorType", "new_class", "resolve_bases", "prepare_class",
           "DynamicClassAttribute", "coroutine", "GenericAlias", "UnionType",
           "EllipsisType", "NoneType", "NotImplementedType", "get_original_bases"]


def _tname(x):
    if x is None:
        return "NoneType"
    return type(x).__name__


def _is_class(x):
    # isinstance(int, type) is false on this runtime; type(int) is type
    return isinstance(x, type) or type(x) is type


# ── the stand-in type objects ────────────────────────────────────────────────
class _NyTypeMeta(type):
    # The metaclass of the stand-ins: isinstance() asks the class's _check,
    # repr is CPython's (<class 'function'>), and a stand-in is only a
    # subclass of itself.
    def __instancecheck__(cls, obj):
        return cls._check(obj)
    def __subclasscheck__(cls, sub):
        return sub is cls
    def __repr__(cls):
        return "<class '" + cls.__qualname__ + "'>"
    def __call__(cls, *args, **kw):
        # NoneType() is None, NotImplementedType() NotImplemented; the
        # others cannot be made here
        return cls._make(*args, **kw)


def _stand_in(name, check, call=None):
    # a class named `name` (shown as CPython's type), whose instances are
    # the values check() accepts
    var ns = {"_check": staticmethod(check), "_make": staticmethod(call if call is not None else _cannot_make(name))}
    # made under a private name: classes are keyed by name, and "generator"
    # or "function" must stay the runtime's own names
    var cls = _NyTypeMeta("_NyType_" + name.replace("-", "_"), (), ns)
    cls.__name__ = name
    cls.__qualname__ = name
    cls.__module__ = "builtins"
    return cls


def _check_asyncgen(x):
    return isinstance(x, _NyAsyncGen)


def _check_code(x):
    return isinstance(x, _NyFuncCode) or isinstance(x, _NyCode)


def _check_frame(x):
    return hasattr(x, "f_code") and hasattr(x, "f_lineno") and hasattr(x, "f_globals")


def _check_traceback(x):
    return hasattr(x, "tb_frame") and hasattr(x, "tb_lineno") and hasattr(x, "tb_next")


def _check_notimpl(x):
    return x is NotImplemented


def _check_nothing(x):
    return False


def _cannot_make(name):
    def make(*args, **kw):
        raise TypeError("cannot create '" + name + "' instances")
    return make


def _notimpl_new(*args, **kw):
    if len(args) > 0 or len(kw) > 0:
        raise TypeError("NotImplementedType takes no arguments")
    return NotImplemented


# The runtime's own type objects (round 77): type(f) is types.FunctionType
def _ny_sample_function():
    pass


def _ny_sample_generator():
    yield 1


class _NySampleClass:
    def method(self):
        pass


FunctionType = type(_ny_sample_function)
LambdaType = FunctionType
BuiltinFunctionType = type(len)
BuiltinMethodType = BuiltinFunctionType
var _ny_sample_gen = _ny_sample_generator()
GeneratorType = type(_ny_sample_gen)
_ny_sample_gen.close()
MethodType = type(_NySampleClass().method)
NoneType = type(None)
AsyncGeneratorType = _stand_in("async_generator", _check_asyncgen)
CoroutineType = _stand_in("coroutine", _check_nothing)
CodeType = _stand_in("code", _check_code)
CellType = _stand_in("cell", _check_nothing)
FrameType = _stand_in("frame", _check_frame)
TracebackType = _stand_in("traceback", _check_traceback)
WrapperDescriptorType = _stand_in("wrapper_descriptor", _check_nothing)
MethodWrapperType = _stand_in("method-wrapper", _check_nothing)
MethodDescriptorType = _stand_in("method_descriptor", _check_nothing)
ClassMethodDescriptorType = _stand_in("classmethod_descriptor", _check_nothing)
GetSetDescriptorType = _stand_in("getset_descriptor", _check_nothing)
MemberDescriptorType = _stand_in("member_descriptor", _check_nothing)
NotImplementedType = _stand_in("NotImplementedType", _check_notimpl, _notimpl_new)

# Real classes the prelude already has
EllipsisType = type(Ellipsis)
GenericAlias = _NyGenericAlias
UnionType = _NyUnionType


# ── SimpleNamespace ──────────────────────────────────────────────────────────
_ns_repr_active = []


class SimpleNamespace:
    # A plain attribute namespace (CPython's C type, written out)
    def __init__(self, *args, **kwargs):
        if len(args) > 1:
            raise TypeError("SimpleNamespace expected at most 1 positional argument, got " + str(len(args)))
        if len(args) == 1:
            var src = args[0]
            var pairs = [(k, src[k]) for k in src] if isinstance(src, dict) else (src.items() if hasattr(src, "keys") else src)
            for pair in pairs:
                var p = list(pair)
                if len(p) != 2:
                    raise TypeError("cannot convert dictionary update sequence element #0 to a sequence")
                if not isinstance(p[0], str):
                    raise TypeError("keywords must be strings, not '" + _tname(p[0]) + "'")
                setattr(self, p[0], p[1])
        for k in kwargs:
            setattr(self, k, kwargs[k])

    def __repr__(self):
        var name = "namespace" if type(self) is SimpleNamespace else type(self).__name__
        for x in _ns_repr_active:
            if x is self:
                return name + "(...)"
        _ns_repr_active.append(self)
        try:
            var d = self.__dict__
            var parts = [k + "=" + repr(d[k]) for k in d]
        finally:
            _ns_repr_active.pop()
        return name + "(" + ", ".join(parts) + ")"

    def __eq__(self, other):
        if not isinstance(other, SimpleNamespace):
            return NotImplemented
        return self.__dict__ == other.__dict__

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    def __reduce__(self):
        return (type(self), (), self.__dict__)


def _mkeys(m):
    # a mapping's keys (a dict read with `.` reads its key first here)
    if isinstance(m, dict):
        return list(m)
    return list(m.keys())


# ── MappingProxyType ─────────────────────────────────────────────────────────
class MappingProxyType:
    # A read-only, live view of a mapping
    def __init__(self, mapping):
        if not (isinstance(mapping, dict) or (hasattr(mapping, "keys") and hasattr(mapping, "__getitem__"))) or isinstance(mapping, (list, tuple, str)):
            raise TypeError("mappingproxy() argument must be a mapping, not " + _tname(mapping))
        object.__setattr__(self, "_ny_mapping", mapping)

    def __getitem__(self, key):
        return self._ny_mapping[key]

    def __setitem__(self, key, value):
        raise TypeError("'mappingproxy' object does not support item assignment")

    def __delitem__(self, key):
        raise TypeError("'mappingproxy' object does not support item deletion")

    def __setattr__(self, name, value):
        raise AttributeError("'mappingproxy' object has no attribute '" + name + "'")

    def __delattr__(self, name):
        raise AttributeError("'mappingproxy' object has no attribute '" + name + "'")

    def get(self, key, default=None):
        var m = self._ny_mapping
        if isinstance(m, dict):
            return m[key] if key in m else default
        return m.get(key, default)

    def keys(self):
        return _mkeys(self._ny_mapping)

    def values(self):
        var m = self._ny_mapping
        return [m[k] for k in _mkeys(m)]

    def items(self):
        var m = self._ny_mapping
        return [(k, m[k]) for k in _mkeys(m)]

    def copy(self):
        var m = self._ny_mapping
        if isinstance(m, dict):
            return dict(m)
        return m.copy()

    def __len__(self):
        return len(self._ny_mapping)

    def __contains__(self, key):
        return key in self._ny_mapping

    def __iter__(self):
        return iter(_mkeys(self._ny_mapping))

    def __reversed__(self):
        return iter(list(reversed(_mkeys(self._ny_mapping))))

    def __eq__(self, other):
        if isinstance(other, MappingProxyType):
            other = other._ny_mapping
        return self._ny_mapping == other

    def __ne__(self, other):
        return not self.__eq__(other)

    def __or__(self, other):
        if isinstance(other, MappingProxyType):
            other = other._ny_mapping
        var d = dict(self._ny_mapping)
        for k in _mkeys(other):
            d[k] = other[k]
        return d

    def __ror__(self, other):
        var d = dict(other)
        for k in _mkeys(self._ny_mapping):
            d[k] = self._ny_mapping[k]
        return d

    def __ior__(self, other):
        raise TypeError("'|=' is not supported by mappingproxy; use '|' instead")

    def __hash__(self):
        return hash(tuple(sorted([repr(k) for k in _mkeys(self._ny_mapping)])))

    def __repr__(self):
        return "mappingproxy(" + repr(self._ny_mapping) + ")"

    def __str__(self):
        return str(self._ny_mapping)

MappingProxyType.__name__ = "mappingproxy"
MappingProxyType.__qualname__ = "mappingproxy"


# ── ModuleType ───────────────────────────────────────────────────────────────
def _is_module_namespace(x):
    # what `import m` binds here: a dict-like namespace carrying the
    # module's __name__ and __file__
    if type(x) != "dict":
        return False
    return isinstance(getattr(x, "__name__", None), str) and isinstance(getattr(x, "__file__", None), str)


class _ModuleTypeMeta(type):
    def __instancecheck__(cls, obj):
        if type(obj) is cls:
            return True
        for c in getattr(type(obj), "__mro__", ()):
            if c is cls:
                return True
        return _is_module_namespace(obj)
    def __repr__(cls):
        return "<class 'module'>"


class ModuleType(metaclass=_ModuleTypeMeta):
    def __init__(self, name, doc=None):
        if not isinstance(name, str):
            raise TypeError("module.__init__() argument 'name' must be str, not " + _tname(name))
        self.__name__ = name
        self.__doc__ = doc
        self.__package__ = None
        self.__loader__ = None
        self.__spec__ = None

    def __repr__(self):
        var f = getattr(self, "__file__", None)
        if f is not None:
            return "<module " + repr(self.__name__) + " from " + repr(f) + ">"
        return "<module " + repr(self.__name__) + ">"

    def __dir__(self):
        return sorted(list(self.__dict__))

ModuleType.__name__ = "module"
ModuleType.__qualname__ = "module"


# ── dynamic classes ──────────────────────────────────────────────────────────
def resolve_bases(bases):
    # Resolve MRO entries dynamically as specified by PEP 560.
    var new_bases = list(bases)
    var updated = False
    var shift = 0
    for i in range(len(bases)):
        var base = bases[i]
        if _is_class(base):
            continue
        if not hasattr(base, "__mro_entries__"):
            continue
        var new_base = base.__mro_entries__(tuple(bases))
        updated = True
        if not isinstance(new_base, tuple):
            raise TypeError("__mro_entries__ must return a tuple")
        new_bases[i + shift:i + shift + 1] = list(new_base)
        shift = shift + len(new_base) - 1
    if not updated:
        return bases
    return tuple(new_bases)


def _meta_derives(a, b):
    # every metaclass derives from type (issubclass(M, type) is not true
    # on every engine here)
    return a is b or b is type or issubclass(a, b)


def _calculate_meta(meta, bases):
    # the most derived metaclass
    var winner = meta
    for base in bases:
        var base_meta = type(base)
        if _meta_derives(winner, base_meta):
            continue
        if _meta_derives(base_meta, winner):
            winner = base_meta
            continue
        raise TypeError("metaclass conflict: the metaclass of a derived class must be a (non-strict) subclass of the metaclasses of all its bases")
    return winner


def prepare_class(name, bases=(), kwds=None):
    # (metaclass, namespace, kwds) as a class statement would compute them
    if kwds is None:
        kwds = {}
    else:
        kwds = dict(kwds)
    var meta = None
    if "metaclass" in kwds:
        meta = kwds["metaclass"]
        del kwds["metaclass"]
    elif len(bases) > 0:
        meta = type(bases[0])
    else:
        meta = type
    if _is_class(meta):
        meta = _calculate_meta(meta, bases)
    var ns = {}
    var prep = getattr(meta, "__prepare__", None)
    if prep is not None:
        ns = prep(name, bases, **kwds)
    return (meta, ns, kwds)


def new_class(name, bases=(), kwds=None, exec_body=None):
    # Create a class object dynamically using the appropriate metaclass.
    var resolved_bases = resolve_bases(bases)
    var prepared = prepare_class(name, resolved_bases, kwds)
    var meta = prepared[0]
    var ns = prepared[1]
    var kw = prepared[2]
    if exec_body is not None:
        exec_body(ns)
    if resolved_bases is not bases:
        ns["__orig_bases__"] = bases
    return meta(name, resolved_bases, ns, **kw)


def get_original_bases(cls):
    # The bases as written in the class statement (3.12)
    if not _is_class(cls):
        raise TypeError("Expected an instance of type, not " + repr(_tname(cls)))
    var d = cls.__dict__
    if "__orig_bases__" in d:
        return d["__orig_bases__"]
    return cls.__bases__


# ── DynamicClassAttribute ────────────────────────────────────────────────────
class DynamicClassAttribute:
    # A property whose class-level access raises AttributeError, so the
    # metaclass's __getattr__ answers it (an Enum member named like a
    # property, for instance)
    def __init__(self, fget=None, fset=None, fdel=None, doc=None):
        self.fget = fget
        self.fset = fset
        self.fdel = fdel
        self.__doc__ = doc if doc is not None else getattr(fget, "__doc__", None)
        self.overwrite_doc = doc is None
        self.__isabstractmethod__ = bool(getattr(fget, "__isabstractmethod__", False))

    def __get__(self, instance, ownerclass=None):
        if instance is None:
            if self.__isabstractmethod__:
                return self
            raise AttributeError()
        if self.fget is None:
            raise AttributeError("unreadable attribute")
        return self.fget(instance)

    def __set__(self, instance, value):
        if self.fset is None:
            raise AttributeError("can't set attribute")
        self.fset(instance, value)

    def __delete__(self, instance):
        if self.fdel is None:
            raise AttributeError("can't delete attribute")
        self.fdel(instance)

    def getter(self, fget):
        var fdoc = getattr(fget, "__doc__", None) if self.overwrite_doc else None
        var result = type(self)(fget, self.fset, self.fdel, fdoc if fdoc is not None else self.__doc__)
        result.overwrite_doc = self.overwrite_doc
        return result

    def setter(self, fset):
        var result = type(self)(self.fget, fset, self.fdel, self.__doc__)
        result.overwrite_doc = self.overwrite_doc
        return result

    def deleter(self, fdel):
        var result = type(self)(self.fget, self.fset, fdel, self.__doc__)
        result.overwrite_doc = self.overwrite_doc
        return result


# ── coroutine ────────────────────────────────────────────────────────────────
def coroutine(func):
    # Convert regular generator function to a coroutine (marks it; the
    # engines' await already drives generator-based awaitables)
    if not callable(func):
        raise TypeError("types.coroutine() expects a callable")
    try:
        func._is_coroutine = True
    except Exception:
        pass
    return func
