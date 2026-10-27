# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/copyreg.ny - Python's copyreg (round 79): the registry and helpers
# pickle and copy use to take objects apart and build them again.
#
#     import copyreg
#     copyreg.pickle(Point, lambda p: (Point, (p.x, p.y)))
#
# pickle(type, function), constructor, dispatch_table (complex is in it, as
# in CPython), __newobj__ / __newobj_ex__ (what NEWOBJ / NEWOBJ_EX call),
# _reconstructor and _reduce_ex (protocols 0 and 1), _slotnames (the slot
# names along the MRO, mangled, cached as cls.__slotnames__), the extension
# registry (add_extension, remove_extension, clear_extension_cache).
#
# Nython: object.__reduce_ex__ / __reduce__ / __getstate__ (the prelude's
# object) call _ny_reduce_ex and _ny_getstate here - CPython's typeobject.c
# reduce_newobj and object_getstate in Python.

__all__ = ["pickle", "constructor", "add_extension", "remove_extension", "clear_extension_cache"]

dispatch_table = {}


def pickle(ob_type, pickle_function, constructor_ob=None):
    if not callable(pickle_function):
        raise TypeError("reduction functions must be callable")
    dispatch_table[ob_type] = pickle_function
    if constructor_ob is not None:
        constructor(constructor_ob)


def constructor(object):
    if not callable(object):
        raise TypeError("constructors must be callable")


def pickle_complex(c):
    return complex, (c.real, c.imag)


dispatch_table[complex] = pickle_complex


# cls.__new__(cls, *args): a class that names no base reads no __new__
# here (object's is not found through it), so object.__new__ stands in
def _ny_new(cls, args, kwargs=None):
    var nw = getattr(cls, "__new__", None)
    if nw is None:
        return object.__new__(cls)
    if kwargs:
        return nw(cls, *args, **kwargs)
    return nw(cls, *args)


def _reconstructor(cls, base, state):
    var obj = None
    if base is object:
        obj = object.__new__(cls)
    else:
        obj = base.__new__(cls, state)
        if base.__init__ != object.__init__:
            base.__init__(obj, state)
    return obj


_HEAPTYPE = 1 << 9


# a class's own namespace ({} for a builtin type, which has none here)
def _cdict(c):
    try:
        return c.__dict__
    except AttributeError:
        return {}

_BUILTIN_TYPES = (int, float, str, bytes, bytearray, list, dict, tuple, set, frozenset, complex, bool)


def _is_builtin_type(t):
    for b in _BUILTIN_TYPES:
        if t is b:
            return True
    return False


def _has_own_getstate(cls):
    for c in cls.__mro__:
        if c is object:
            return False
        if "__getstate__" in _cdict(c):
            return True
    return False


# Python's implementation of object.__reduce_ex__ for protocols 0 and 1
def _reduce_ex(self, proto):
    var cls = self.__class__
    var base = object
    for b in cls.__mro__:
        if _is_builtin_type(b) or b is object:
            base = b
            break
    var state = None
    if base is not object:
        if base is cls:
            raise TypeError("cannot pickle " + repr(cls.__name__) + " object")
        state = base(self)
    var args = (cls, base, state)
    var dict = None
    if _has_own_getstate(cls):
        dict = self.__getstate__()
    else:
        # (3.11: object.__getstate__ exists, so this is the message)
        if getattr(self, "__slots__", None):
            raise TypeError("a class that defines __slots__ without defining __getstate__ cannot be pickled")
        dict = _ny_getstate(self)
    if dict:
        return _reconstructor, args, dict
    return _reconstructor, args


def __newobj__(cls, *args):
    return _ny_new(cls, args)


def __newobj_ex__(cls, args, kwargs):
    return _ny_new(cls, args, kwargs)


def _slotnames(cls):
    var names = _cdict(cls).get("__slotnames__")
    if names is not None:
        return names
    names = []
    if not hasattr(cls, "__slots__"):
        pass
    else:
        for c in cls.__mro__:
            if "__slots__" in _cdict(c):
                var slots = _cdict(c)["__slots__"]
                if isinstance(slots, str):
                    slots = (slots,)
                for name in slots:
                    if name == "__dict__" or name == "__weakref__":
                        continue
                    elif name.startswith("__") and not name.endswith("__"):
                        var stripped = c.__name__.lstrip("_")
                        if stripped:
                            names.append("_" + stripped + name)
                        else:
                            names.append(name)
                    else:
                        names.append(name)
    try:
        cls.__slotnames__ = names
    except Exception:
        pass
    return names


# ── object.__getstate__ / __reduce_ex__ (CPython's typeobject.c) ───────────
def _ny_has_dict(obj):
    try:
        obj.__dict__
        return True
    except AttributeError:
        return False
    except TypeError:
        return False


def _ny_getstate(obj, required=False):
    var state = None
    if _ny_has_dict(obj):
        var d = obj.__dict__
        if len(d):
            state = dict(d)
    var slotnames = _slotnames(type(obj))
    if len(slotnames) > 0:
        var slots = {}
        for name in slotnames:
            var sentinel = slots
            var v = getattr(obj, name, sentinel)
            if v is not sentinel:
                slots[name] = v
        if len(slots) > 0:
            state = (state, slots)
    return state


def _ny_getnewargs(obj):
    var cls = type(obj)
    var gx = getattr(cls, "__getnewargs_ex__", None)
    if gx is not None:
        var na = obj.__getnewargs_ex__()
        if not isinstance(na, tuple):
            raise TypeError("__getnewargs_ex__ should return a tuple, not '" + type(na).__name__ + "'")
        if len(na) != 2:
            raise ValueError("__getnewargs_ex__ should return a tuple of length 2, not " + str(len(na)))
        if not isinstance(na[0], tuple):
            raise TypeError("first item of the tuple returned by __getnewargs_ex__ must be a tuple, not '"
                            + type(na[0]).__name__ + "'")
        if not isinstance(na[1], dict):
            raise TypeError("second item of the tuple returned by __getnewargs_ex__ must be a dict, not '"
                            + type(na[1]).__name__ + "'")
        return na[0], na[1]
    var g = getattr(cls, "__getnewargs__", None)
    if g is not None:
        var a = obj.__getnewargs__()
        if not isinstance(a, tuple):
            raise TypeError("__getnewargs__ should return a tuple, not '" + type(a).__name__ + "'")
        return a, None
    return None, None


def _ny_reduce_newobj(obj):
    var cls = type(obj)
    var na = _ny_getnewargs(obj)
    var args = na[0]
    var kwargs = na[1]
    var hasargs = args is not None
    var newobj = None
    var newargs = None
    if kwargs is None or len(kwargs) == 0:
        newobj = __newobj__
        newargs = (cls,) + (args if args is not None else ())
    else:
        newobj = __newobj_ex__
        newargs = (cls, args, kwargs)
    var state = None
    if _has_own_getstate(cls):
        state = obj.__getstate__()
    else:
        state = _ny_getstate(obj, not (hasargs or isinstance(obj, list) or isinstance(obj, dict)))
    var listitems = iter(obj) if isinstance(obj, list) else None
    var dictitems = iter(obj.items()) if isinstance(obj, dict) else None
    return newobj, newargs, state, listitems, dictitems


_EXC_FIELDS = ("args", "errno", "strerror", "filename", "filename2", "winerror", "characters_written", "msg",
               "lineno", "offset", "text", "end_lineno", "end_offset", "print_file_and_line", "code", "value",
               "name", "path", "obj", "encoding", "object", "start", "end", "reason", "exceptions", "message")


def _ny_reduce_ex(obj, proto):
    # object.__reduce_ex__: a class's own __reduce__ wins
    var cls = type(obj)
    for c in cls.__mro__:
        if c is object:
            break
        if "__reduce__" in _cdict(c):
            return obj.__reduce__()
    if isinstance(obj, BaseException):
        # BaseException.__reduce__: (type, args) and the instance's own
        # attributes (not the ones CPython keeps in the exception itself)
        var d = obj.__dict__ if _ny_has_dict(obj) else {}
        var st = {}
        for k in d:
            if not k.startswith("__") and k not in _EXC_FIELDS:
                st[k] = d[k]
        if len(st):
            return cls, tuple(obj.args), st
        return cls, tuple(obj.args)
    if proto >= 2:
        return _ny_reduce_newobj(obj)
    return _reduce_ex(obj, proto)


# ── the extension registry ──────────────────────────────────────────────────
_extension_registry = {}
_inverted_registry = {}
_extension_cache = {}


def add_extension(module, name, code):
    code = int(code)
    if not 1 <= code <= 0x7fffffff:
        raise ValueError("code out of range")
    var key = (module, name)
    if _extension_registry.get(key) == code and _inverted_registry.get(code) == key:
        return
    if key in _extension_registry:
        raise ValueError("key " + str(key) + " is already registered with code " + str(_extension_registry[key]))
    if code in _inverted_registry:
        raise ValueError("code " + str(code) + " is already in use for key " + str(_inverted_registry[code]))
    _extension_registry[key] = code
    _inverted_registry[code] = key


def remove_extension(module, name, code):
    var key = (module, name)
    if _extension_registry.get(key) != code or _inverted_registry.get(code) != key:
        raise ValueError("key " + str(key) + " is not registered with code " + str(code))
    del _extension_registry[key]
    del _inverted_registry[code]
    if code in _extension_cache:
        del _extension_cache[code]


def clear_extension_cache():
    _extension_cache.clear()
