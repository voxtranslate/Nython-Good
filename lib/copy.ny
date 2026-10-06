# nython: module    (import it by name: it runs in a module scope of its own)
# lib/copy.ny - Python's copy: shallow and deep copy operations.
#
#     import copy
#     y = copy.copy(x)        # a new container holding the same items
#     z = copy.deepcopy(x)    # copies all the way down
#
# copy(x)               lists, dicts, sets and bytearrays are copied; values
#                       that cannot change (None, numbers, str, bytes, tuple,
#                       frozenset, functions, classes) are returned as they are;
#                       an instance gets __copy__() if its class has one, else
#                       __reduce_ex__(4) / __reduce__() if the class defines
#                       them, else a new instance of the same class (its
#                       __init__ is not run) with the same attributes, through
#                       __getstate__ / __setstate__ when defined.
# deepcopy(x, memo=None)  the same with every component copied; `memo` maps
#                       id(original) -> copy, so shared references stay shared
#                       and cycles are reproduced (a list holding itself, an
#                       object pointing back at its parent); __deepcopy__(memo)
#                       is used when defined; a tuple whose items are all
#                       their own copies is returned as it is (as Python).
# replace(obj, **changes)  Python 3.13: obj.__replace__(**changes)
# Error (= error)       raised for values that cannot be copied
#
# Differences, from the runtime: an instance is made without running its
# __init__ by setting a no-op __init__ on its class for the moment of the
# call (the runtime has no object.__new__ yet; it is used when it exists).
# Instance attributes are stored with object.__setattr__, so a class's own
# __setattr__ is bypassed, as Python's __dict__.update() does. Generators
# and other runtime iterators cannot be copied (TypeError, as in Python).

__all__ = ["Error", "copy", "deepcopy", "replace"]


class Error(Exception):
    pass

error = Error


def _tname(x):
    return type(x).__name__


# ── what a value is ──────────────────────────────────────────────────────────
def _is_atomic(x):
    # values never copied: they cannot change
    if x is none:
        return true
    if isinstance(x, (bool, int, float, str, bytes)):
        return true
    if isinstance(x, complex):
        return true
    return false

def _runtime_kind(x):
    # a function, bound method, builtin or generator / lazy iterator: kinds
    # whose type object (round 77) equals its legacy name
    var t = type(x)
    return t == "function" or t == "builtin" or t == "generator"

def _is_instance(x):
    # an instance of a class (builtin values answer __class__ too)
    return hasattr(x, "__class__") and not hasattr(x, "__mro__") and not _runtime_kind(x)

def _is_class(x):
    return hasattr(x, "__mro__") and not hasattr(x, "__class__")

def _is_generator(x):
    # a generator or a lazy iterator (zip, map, iter(...))
    return type(x) == "generator"


# ── making an instance without __init__ ──────────────────────────────────────
def _copy_noinit(self, *args, **kwargs):
    pass

_new_lock = rmutex_create()

def _new_instance(cls):
    # an instance of cls whose __init__ has not run
    if hasattr(object, "__new__"):
        return object.__new__(cls)
    # Does cls define __init__ itself, or inherit it (or have none)? An
    # inherited one is restored by deleting the stand-in.
    var own = none
    if hasattr(cls, "__init__"):
        var mine = getattr(cls, "__init__")
        own = mine
        var mro = list(cls.__mro__)
        for i in range(1, len(mro)):
            if hasattr(mro[i], "__init__") and id(getattr(mro[i], "__init__")) == id(mine):
                own = none
                break
    mutex_lock(_new_lock)
    try:
        setattr(cls, "__init__", _copy_noinit)
        try:
            return cls()
        finally:
            if own is none:
                delattr(cls, "__init__")
            else:
                setattr(cls, "__init__", own)
    finally:
        mutex_unlock(_new_lock)


def _state_of(x):
    # what __reduce_ex__ would give as the state: __getstate__(), else the
    # attributes (None when there are none, as object.__getstate__)
    if hasattr(x, "__getstate__"):
        return x.__getstate__()
    var d = vars(x)
    if len(d) == 0:
        return none
    return d


def _set_state(y, state):
    if state is none:
        return
    if hasattr(y, "__setstate__"):
        y.__setstate__(state)
        return
    var slotstate = none
    if isinstance(state, tuple) and len(state) == 2:
        slotstate = state[1]
        state = state[0]
    if state is not none:
        for k in state:
            object.__setattr__(y, k, state[k])
    if slotstate is not none:
        for k in slotstate:
            setattr(y, k, slotstate[k])


def _has_class_attr(cls, name):
    # a hook the class (not the instance) defines
    try:
        getattr(cls, name)
        return true
    except AttributeError:
        return false


# Python's collections types have __copy__; the runtime's (lib/collections.ny)
# have copy() instead.
_collections_types = ["deque", "OrderedDict", "defaultdict", "Counter", "UserDict", "UserList", "ChainMap"]

def _collections_copy(x):
    var cls = x.__class__
    return getattr(cls, "__module__", "") == "collections" and cls.__name__ in _collections_types and hasattr(x, "copy")


def _exception_new(x):
    # an exception made again from its args
    return x.__class__(*x.args)


# ── copy ─────────────────────────────────────────────────────────────────────
def copy(x):
    """Shallow copy operation on arbitrary Python objects.

    See the module's __doc__ string for more info.
    """
    if _is_atomic(x):
        return x
    if isinstance(x, list):
        return list(x)
    if isinstance(x, tuple) or isinstance(x, frozenset):
        return x
    if isinstance(x, dict):
        return x.copy()
    if isinstance(x, set):
        return x.copy()
    if isinstance(x, bytearray):
        return bytearray(x)
    if _is_class(x):
        return x
    if _is_instance(x):
        var cls = x.__class__
        if _has_class_attr(cls, "__copy__"):
            return x.__copy__()
        if _collections_copy(x):
            return x.copy()
        var rv = _reduce(x, cls)
        if rv is not none:
            if isinstance(rv, str):
                return x
            return _reconstruct(x, none, rv)
        if isinstance(x, BaseException):
            var e = _exception_new(x)
            _set_state(e, _plain_state(x))
            return e
        var y = _new_instance(cls)
        _set_state(y, _state_of(x))
        return y
    if _is_generator(x):
        raise TypeError("cannot pickle '" + _tname(x) + "' object")
    if callable(x):
        return x
    raise Error("un(shallow)copyable object of type " + _tname(x))


def _plain_state(x):
    # an exception's attributes beyond its args
    var d = vars(x)
    var out = {}
    for k in d:
        if k != "args" and k != "msg":
            out[k] = d[k]
    if len(out) == 0:
        return none
    return out


def _reduce(x, cls):
    # __reduce_ex__(4) / __reduce__() when the class defines one
    if _has_class_attr(cls, "__reduce_ex__"):
        return x.__reduce_ex__(4)
    if _has_class_attr(cls, "__reduce__"):
        return x.__reduce__()
    return none


# ── deepcopy ─────────────────────────────────────────────────────────────────
def deepcopy(x, memo=none, _nil=[]):
    """Deep copy operation on arbitrary Python objects.

    See the module's __doc__ string for more info.
    """
    if memo is none:
        memo = {}
    if _is_atomic(x):
        return x
    var d = id(x)
    var y = memo.get(d, _nil)
    if id(y) != id(_nil):
        return y
    if isinstance(x, list):
        y = []
        memo[d] = y
        for a in x:
            y.append(deepcopy(a, memo))
    elif isinstance(x, tuple):
        y = _deepcopy_tuple(x, memo)
    elif isinstance(x, dict):
        y = {}
        memo[d] = y
        for k in x:
            y[deepcopy(k, memo)] = deepcopy(x[k], memo)
    elif isinstance(x, frozenset):
        y = frozenset([deepcopy(a, memo) for a in x])
    elif isinstance(x, set):
        y = set()
        memo[d] = y
        for a in x:
            y.add(deepcopy(a, memo))
    elif isinstance(x, bytearray):
        y = bytearray(x)
    elif _is_class(x):
        y = x
    elif _is_instance(x):
        y = _deepcopy_instance(x, memo)
    elif _is_generator(x):
        raise TypeError("cannot pickle '" + _tname(x) + "' object")
    elif callable(x):
        y = x
    else:
        raise Error("un(deep)copyable object of type " + _tname(x))
    # a value that is its own copy is not memoized
    if id(y) != id(x):
        memo[d] = y
        _keep_alive(x, memo)
    return y


def _deepcopy_tuple(x, memo):
    var y = [deepcopy(a, memo) for a in x]
    # not memoized itself, but a recursive structure inside may have put it
    # in the memo already
    var got = memo.get(id(x), _nil_tuple)
    if id(got) != id(_nil_tuple):
        return got
    for i in range(len(x)):
        if id(x[i]) != id(y[i]):
            return tuple(y)
    return x

_nil_tuple = []


def _deepcopy_instance(x, memo):
    var cls = x.__class__
    if _has_class_attr(cls, "__deepcopy__"):
        return x.__deepcopy__(memo)
    var rv = _reduce(x, cls)
    if rv is not none:
        if isinstance(rv, str):
            return x
        return _reconstruct(x, memo, rv)
    var y = none
    var state = none
    if isinstance(x, BaseException):
        y = x.__class__(*deepcopy(list(x.args), memo))
        state = _plain_state(x)
    else:
        y = _new_instance(cls)
        state = _state_of(x)
    memo[id(x)] = y
    if state is not none:
        state = deepcopy(state, memo)
    _set_state(y, state)
    return y


def _keep_alive(x, memo):
    """Keeps a reference to the object x in the memo.

    Because we remember objects by their id, we have
    to assure that possibly temporary objects are kept
    alive by referencing them.
    We store a reference at the id of the memo, which should
    normally not be used unless someone tries to deepcopy
    the memo itself...
    """
    var k = id(memo)
    if k in memo:
        memo[k].append(x)
    else:
        memo[k] = [x]


def _reconstruct(x, memo, rv):
    # rv: (callable, args[, state[, listitems[, dictitems]]]) as __reduce_ex__ gives
    var n = len(rv)
    if n < 2:
        raise Error("__reduce__ must return a tuple of 2 to 5 items")
    var func = rv[0]
    var args = rv[1]
    var state = rv[2] if n > 2 else none
    var listiter = rv[3] if n > 3 else none
    var dictiter = rv[4] if n > 4 else none
    var deep = memo is not none
    if deep and args:
        args = deepcopy(args, memo)
    var y = func(*args)
    if deep:
        memo[id(x)] = y
    if state is not none:
        if deep:
            state = deepcopy(state, memo)
        _set_state(y, state)
    if listiter is not none:
        for item in listiter:
            y.append(deepcopy(item, memo) if deep else item)
    if dictiter is not none:
        for pair in dictiter:
            var key = pair[0]
            var value = pair[1]
            if deep:
                key = deepcopy(key, memo)
                value = deepcopy(value, memo)
            y[key] = value
    return y


# ── replace (Python 3.13) ────────────────────────────────────────────────────
def replace(obj, **changes):
    """Return a new object replacing specified fields with new values.

    This is especially useful for immutable objects, like named tuples or
    frozen dataclasses.
    """
    if _is_instance(obj) and _has_class_attr(obj.__class__, "__replace__"):
        return obj.__replace__(**changes)
    raise TypeError("replace() does not support " + _tname(obj) + " objects")
