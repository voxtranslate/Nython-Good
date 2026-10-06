# nython: module    (import it by name: it runs in a module scope of its own)
# lib/functools.ny - Python's functools: higher-order functions and
# operations on callables.
#
#     from functools import reduce, partial, lru_cache, cache, wraps
#
# reduce(function, iterable[, initial])
# partial(func, *args, **keywords)       .func .args .keywords, nested
#                                        partials flattened, Python's repr
# partialmethod(func, *args, **keywords) a partial that binds like a method
# lru_cache(maxsize=128, typed=False)    bare (@lru_cache) or called; real LRU
#                                        order (a circular doubly linked list,
#                                        as CPython's), maxsize None (unbounded)
#                                        and 0 (no caching), cache_info()
#                                        (CacheInfo hits/misses/maxsize/currsize),
#                                        cache_clear(), cache_parameters()
# cache(func)                            lru_cache(maxsize=None)
# cached_property(func)                  computed once per instance, stored as
#                                        an instance attribute (del clears it)
# update_wrapper / wraps                 __module__ __name__ __qualname__ __doc__
#                                        (those the wrapped function has) and
#                                        __wrapped__
# total_ordering(cls)                    the missing rich comparisons
# cmp_to_key(mycmp)                      a key= from an old-style cmp function
# singledispatch(func)                   register(type) / register(type, func),
#                                        register(int | str) (each member), plain
#                                        @register on a function whose first
#                                        parameter is annotated; dispatch through
#                                        the MRO with abstract base classes
#                                        (collections.abc, numbers, your own ABCs
#                                        and their registered virtual subclasses)
#                                        placed by CPython's _compose_mro /
#                                        _c3_mro, "Ambiguous dispatch" between
#                                        two unrelated implicit ABCs; a dispatch
#                                        cache cleared by register() and by
#                                        abc.get_cache_token() changing;
#                                        .dispatch(), .registry, ._clear_cache()
# singledispatchmethod(func)             the same for methods (first argument
#                                        after self)
# WRAPPER_ASSIGNMENTS, WRAPPER_UPDATES
#
# Not here: Python 3.14's Placeholder. A function's attributes cannot be
# listed by the runtime, so update_wrapper copies the named ones but not
# __dict__. An annotation kept as text (from __future__ import annotations,
# a forward reference) is evaluated in functools' scope (functions have no
# __globals__ here), so register() by such an annotation finds builtin
# types and NoneType but not the program's classes (register(cls, f) does).
# None, functions, builtins and generators dispatch on their type()'s name
# ("none", "function", ...): register(type(None)) works as in Python.


__all__ = ["update_wrapper", "wraps", "WRAPPER_ASSIGNMENTS", "WRAPPER_UPDATES",
           "total_ordering", "cache", "cmp_to_key", "lru_cache", "reduce",
           "partial", "partialmethod", "singledispatch", "singledispatchmethod",
           "cached_property"]


def _tname(x):
    if x is none:
        return "NoneType"
    return type(x).__name__


def _iter(x):
    # iter(x) with Python's TypeError for a number (the runtime iterates
    # an int as a range)
    if x is none or isinstance(x, (int, float)):
        raise TypeError("'" + _tname(x) + "' object is not iterable")
    return iter(x)


# A value nothing else can produce ("missing").
class _FunctoolsSentinel:
    def __repr__(self):
        return "<sentinel>"

_MISSING = _FunctoolsSentinel()

def _missing(x):
    return isinstance(x, _FunctoolsSentinel)

# Python's NotImplemented, where the runtime has it.
_NotImplemented = _FunctoolsSentinel()
try:
    _NotImplemented = NotImplemented
except NameError:
    pass

def _is_notimpl(x):
    return id(x) == id(_NotImplemented)


# ── update_wrapper / wraps ───────────────────────────────────────────────────
WRAPPER_ASSIGNMENTS = ("__module__", "__name__", "__qualname__", "__doc__",
                       "__annotations__", "__type_params__")
WRAPPER_UPDATES = ("__dict__",)

def update_wrapper(wrapper, wrapped, assigned=WRAPPER_ASSIGNMENTS, updated=WRAPPER_UPDATES):
    """Update a wrapper function to look like the wrapped function

       wrapper is the function to be updated
       wrapped is the original function
       assigned is a tuple naming the attributes assigned directly
       from the wrapped function to the wrapper function (defaults to
       functools.WRAPPER_ASSIGNMENTS)
       updated is a tuple naming the attributes of the wrapper that
       are updated with the corresponding attribute from the wrapped
       function (defaults to functools.WRAPPER_UPDATES)
    """
    for attr in assigned:
        var value = _MISSING
        try:
            value = getattr(wrapped, attr)
        except AttributeError:
            pass
        if not _missing(value):
            setattr(wrapper, attr, value)
    for attr in updated:
        var target = _MISSING
        try:
            target = getattr(wrapper, attr)
        except AttributeError:
            pass
        if not _missing(target) and hasattr(target, "update"):
            target.update(getattr(wrapped, attr, {}))
    # set last, so a __wrapped__ copied from wrapped's __dict__ is replaced
    wrapper.__wrapped__ = wrapped
    return wrapper


def wraps(wrapped, assigned=WRAPPER_ASSIGNMENTS, updated=WRAPPER_UPDATES):
    """Decorator factory to apply update_wrapper() to a wrapper function

       Returns a decorator that invokes update_wrapper() with the decorated
       function as the wrapper argument and the arguments to wraps() as the
       remaining arguments.
    """
    return partial(update_wrapper, wrapped=wrapped, assigned=assigned, updated=updated)


# ── total_ordering ───────────────────────────────────────────────────────────
# Each derived comparison calls the class's root comparison (looked up on
# the instance's class, as Python's type(self).__lt__) and passes its
# NotImplemented on.
def _gt_from_lt(self, other):
    "Return a > b.  Computed by @total_ordering from (not a < b) and (a != b)."
    var op_result = self.__class__.__lt__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result and self != other

def _le_from_lt(self, other):
    "Return a <= b.  Computed by @total_ordering from (a < b) or (a == b)."
    var op_result = self.__class__.__lt__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return op_result or self == other

def _ge_from_lt(self, other):
    "Return a >= b.  Computed by @total_ordering from (not a < b)."
    var op_result = self.__class__.__lt__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result

def _ge_from_le(self, other):
    "Return a >= b.  Computed by @total_ordering from (not a <= b) or (a == b)."
    var op_result = self.__class__.__le__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result or self == other

def _lt_from_le(self, other):
    "Return a < b.  Computed by @total_ordering from (a <= b) and (a != b)."
    var op_result = self.__class__.__le__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return op_result and self != other

def _gt_from_le(self, other):
    "Return a > b.  Computed by @total_ordering from (not a <= b)."
    var op_result = self.__class__.__le__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result

def _lt_from_gt(self, other):
    "Return a < b.  Computed by @total_ordering from (not a > b) and (a != b)."
    var op_result = self.__class__.__gt__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result and self != other

def _ge_from_gt(self, other):
    "Return a >= b.  Computed by @total_ordering from (a > b) or (a == b)."
    var op_result = self.__class__.__gt__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return op_result or self == other

def _le_from_gt(self, other):
    "Return a <= b.  Computed by @total_ordering from (not a > b)."
    var op_result = self.__class__.__gt__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result

def _le_from_ge(self, other):
    "Return a <= b.  Computed by @total_ordering from (not a >= b) or (a == b)."
    var op_result = self.__class__.__ge__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result or self == other

def _gt_from_ge(self, other):
    "Return a > b.  Computed by @total_ordering from (a >= b) and (a != b)."
    var op_result = self.__class__.__ge__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return op_result and self != other

def _lt_from_ge(self, other):
    "Return a < b.  Computed by @total_ordering from (not a >= b)."
    var op_result = self.__class__.__ge__(self, other)
    if _is_notimpl(op_result):
        return op_result
    return not op_result

_convert = {
    "__lt__": [["__gt__", _gt_from_lt], ["__le__", _le_from_lt], ["__ge__", _ge_from_lt]],
    "__le__": [["__ge__", _ge_from_le], ["__lt__", _lt_from_le], ["__gt__", _gt_from_le]],
    "__gt__": [["__lt__", _lt_from_gt], ["__ge__", _ge_from_gt], ["__le__", _le_from_gt]],
    "__ge__": [["__le__", _le_from_ge], ["__gt__", _gt_from_ge], ["__lt__", _lt_from_ge]],
}

def _user_defined(cls, op):
    # a comparison the class (or a base) defines, not object's own
    if not hasattr(cls, op):
        return false
    if not hasattr(object, op):
        return true
    return id(getattr(cls, op)) != id(getattr(object, op))

def total_ordering(cls):
    "Class decorator that fills in missing ordering methods"
    var roots = [op for op in ["__lt__", "__le__", "__gt__", "__ge__"] if _user_defined(cls, op)]
    if len(roots) == 0:
        raise ValueError("must define at least one ordering operation: < > <= >=")
    var root = max(roots)       # prefer __lt__ to __le__ to __gt__ to __ge__
    for pair in _convert[root]:
        var opname = pair[0]
        if not (opname in roots):
            var opfunc = pair[1]
            opfunc.__name__ = opname
            setattr(cls, opname, opfunc)
    return cls


# ── cmp_to_key ───────────────────────────────────────────────────────────────
class KeyWrapper:
    # cmp_to_key(f) is one of these without an object; calling it wraps an
    # object, and two wrapped objects compare through f (CPython's C type).
    def __init__(self, cmp, obj=_MISSING):
        self.cmp = cmp
        self.obj = obj

    def __call__(self, obj):
        return KeyWrapper(self.cmp, obj)

    def _other(self, other):
        if not isinstance(other, KeyWrapper):
            raise TypeError("other argument must be K instance")
        return other.obj

    def __lt__(self, other):
        return self.cmp(self.obj, self._other(other)) < 0

    def __gt__(self, other):
        return self.cmp(self.obj, self._other(other)) > 0

    def __eq__(self, other):
        return self.cmp(self.obj, self._other(other)) == 0

    def __ne__(self, other):
        return self.cmp(self.obj, self._other(other)) != 0

    def __le__(self, other):
        return self.cmp(self.obj, self._other(other)) <= 0

    def __ge__(self, other):
        return self.cmp(self.obj, self._other(other)) >= 0

    def __hash__(self):
        raise TypeError("unhashable type: 'functools.KeyWrapper'")

    def __repr__(self):
        return "<functools.KeyWrapper object at " + hex(id(self)) + ">"


def cmp_to_key(mycmp):
    "Convert a cmp= function into a key= function."
    return KeyWrapper(mycmp)


# ── reduce ───────────────────────────────────────────────────────────────────
def reduce(*args):
    """
    reduce(function, iterable[, initial], /) -> value

    Apply a function of two arguments cumulatively to the items of an iterable, from left to right.

    This effectively reduces the iterable to a single value.  If initial is present,
    it is placed before the items of the iterable in the calculation, and serves as
    a default when the iterable is empty.

    For example, reduce(lambda x, y: x+y, [1, 2, 3, 4, 5])
    calculates ((((1 + 2) + 3) + 4) + 5).
    """
    var n = len(args)
    if n < 2:
        raise TypeError("reduce expected at least 2 arguments, got " + str(n))
    if n > 3:
        raise TypeError("reduce expected at most 3 arguments, got " + str(n))
    var function = args[0]
    var it = none
    try:
        it = _iter(args[1])
    except TypeError:
        raise TypeError("reduce() arg 2 must support iteration")
    var value = none
    if n == 3:
        value = args[2]
    else:
        try:
            value = next(it)
        except StopIteration:
            raise TypeError("reduce() of empty iterable with no initial value")
    for element in it:
        value = function(value, element)
    return value


# ── partial ──────────────────────────────────────────────────────────────────
def _class_label(obj, default_module):
    # "functools.partial" for this module's classes, "Sub" for a subclass
    # defined elsewhere (Python's repr rule)
    var cls = obj.__class__
    var name = cls.__name__
    var mod = getattr(cls, "__module__", default_module)
    if mod == default_module:
        return default_module + "." + name
    return name


class partial:
    """partial(func, *args, **keywords) - new function with partial application
    of the given arguments and keywords.
    """
    def __init__(self, *args, **keywords):
        if len(args) == 0:
            raise TypeError("type 'partial' takes at least one argument")
        var func = args[0]
        var pargs = tuple(args[1:])
        if not callable(func):
            raise TypeError("the first argument must be callable")
        if isinstance(func, partial):
            pargs = func.args + pargs
            var kw = {}
            for k in func.keywords:
                kw[k] = func.keywords[k]
            for k in keywords:
                kw[k] = keywords[k]
            keywords = kw
            func = func.func
        self.func = func
        self.args = pargs
        self.keywords = keywords

    def __call__(self, *args, **keywords):
        var kw = {}
        for k in self.keywords:
            kw[k] = self.keywords[k]
        for k in keywords:
            kw[k] = keywords[k]
        return self.func(*self.args, *args, **kw)

    def __repr__(self):
        var parts = [repr(self.func)]
        for a in self.args:
            parts.append(repr(a))
        for k in self.keywords:
            parts.append(str(k) + "=" + repr(self.keywords[k]))
        return _class_label(self, "functools") + "(" + ", ".join(parts) + ")"

    def __reduce__(self):
        return (self.__class__, (self.func,), (self.func, self.args, self.keywords or none, none))


class partialmethod:
    """Method descriptor with partial application of the given arguments
    and keywords.

    Supports wrapping existing descriptors and handles non-descriptor
    callables as instance methods.
    """
    def __init__(self, *args, **keywords):
        if len(args) == 0:
            raise TypeError("partialmethod expected at least 1 argument, got 0")
        var func = args[0]
        var pargs = tuple(args[1:])
        if not callable(func) and not hasattr(func, "__get__"):
            raise TypeError(repr(func) + " is not callable or a descriptor")
        if isinstance(func, partialmethod):
            self.func = func.func
            self.args = func.args + pargs
            var kw = {}
            for k in func.keywords:
                kw[k] = func.keywords[k]
            for k in keywords:
                kw[k] = keywords[k]
            self.keywords = kw
        else:
            self.func = func
            self.args = pargs
            self.keywords = keywords

    def __repr__(self):
        var a = ", ".join([repr(x) for x in self.args])
        var kw = ", ".join([str(k) + "=" + repr(self.keywords[k]) for k in self.keywords])
        return _class_label(self, "functools") + "(" + repr(self.func) + ", " + a + ", " + kw + ")"

    def _make_unbound_method(self):
        var pm = self
        def _method(cls_or_self, *args, **keywords):
            var kw = {}
            for k in pm.keywords:
                kw[k] = pm.keywords[k]
            for k in keywords:
                kw[k] = keywords[k]
            return pm.func(cls_or_self, *pm.args, *args, **kw)
        _method._partialmethod = self
        return _method

    def __get__(self, obj, cls=none):
        if obj is none:
            return self._make_unbound_method()
        # Python's: a partial of func bound to obj (func.__get__(obj, cls)),
        # so .args are the partial's own; a callable that does not bind
        # gets obj as its first argument instead
        var bound = _bound_to(self.func, obj)
        var result = none
        if bound is none:
            result = partial(self.func, obj, *self.args, **self.keywords)
        else:
            result = partial(bound, *self.args, **self.keywords)
        result.__self__ = obj
        return result


def _bound_to(func, obj):
    # func bound to obj when it is a method of obj's class (the runtime's
    # functions have no __get__), else None
    var name = getattr(func, "__name__", none)
    if not isinstance(name, str) or not hasattr(obj, "__class__"):
        return none
    var cls = obj.__class__
    if not hasattr(cls, name) or id(getattr(cls, name)) != id(func):
        return none
    if name in vars(obj):
        return none
    return getattr(obj, name)


# ── lru_cache / cache ────────────────────────────────────────────────────────
class CacheInfo:
    # Python's CacheInfo(hits, misses, maxsize, currsize): a named tuple
    # (indexable, unpackable, equal to the plain tuple of its values)
    _fields = ("hits", "misses", "maxsize", "currsize")

    def __init__(self, hits, misses, maxsize, currsize):
        self.hits = hits
        self.misses = misses
        self.maxsize = maxsize
        self.currsize = currsize

    def _tuple(self):
        return (self.hits, self.misses, self.maxsize, self.currsize)

    def __getitem__(self, i):
        return self._tuple()[i]

    def __len__(self):
        return 4

    def __iter__(self):
        return iter(self._tuple())

    def __eq__(self, other):
        if isinstance(other, CacheInfo):
            return self._tuple() == other._tuple()
        return self._tuple() == other

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash(self._tuple())

    def _asdict(self):
        return {"hits": self.hits, "misses": self.misses, "maxsize": self.maxsize, "currsize": self.currsize}

    def __repr__(self):
        return ("CacheInfo(hits=" + repr(self.hits) + ", misses=" + repr(self.misses) +
                ", maxsize=" + repr(self.maxsize) + ", currsize=" + repr(self.currsize) + ")")

_CacheInfo = CacheInfo


class _FunctoolsKwdMark:
    # separates positional from keyword arguments in a cache key
    def __repr__(self):
        return "<kwd_mark>"

_kwd_mark = _FunctoolsKwdMark()

def _make_key(args, kwds, typed):
    # The key of one call: the positional arguments, then a marker and the
    # keyword items, then (typed) the argument types. A single int or str
    # argument is its own key, as in CPython.
    var key = list(args)
    if len(kwds) > 0:
        key.append(_kwd_mark)
        for k in kwds:
            key.append(k)
            key.append(kwds[k])
    if typed:
        for v in args:
            key.append(_tname(v))
        for k in kwds:
            key.append(_tname(kwds[k]))
    elif len(key) == 1 and (isinstance(key[0], str) or (isinstance(key[0], int) and not isinstance(key[0], bool))):
        return key[0]
    return tuple(key)


def _lru_cache_wrapper(user_function, maxsize, typed):
    # The cache: key -> link; links form a circular doubly linked list in
    # use order, root's PREV the most recent, root's NEXT the oldest.
    var PREV = 0
    var NEXT = 1
    var KEY = 2
    var RESULT = 3
    var cache = {}
    var hits = 0
    var misses = 0
    var full = false
    var lock = rmutex_create()
    var root = [none, none, none, none]
    root[PREV] = root
    root[NEXT] = root
    var wrapper = none

    if maxsize == 0:
        def _nocache(*args, **kwds):
            # no caching: just counts the calls
            nonlocal misses
            misses += 1
            return user_function(*args, **kwds)
        wrapper = _nocache
    elif maxsize is none:
        def _unbounded(*args, **kwds):
            # unlimited size: no ordering to keep
            nonlocal hits, misses
            var key = _make_key(args, kwds, typed)
            var result = cache.get(key, _MISSING)
            if not _missing(result):
                hits += 1
                return result
            misses += 1
            result = user_function(*args, **kwds)
            cache[key] = result
            return result
        wrapper = _unbounded
    else:
        def _bounded(*args, **kwds):
            # size limited: the least recently used entry goes first
            nonlocal root, hits, misses, full
            var key = _make_key(args, kwds, typed)
            mutex_lock(lock)
            try:
                var link = cache.get(key)
                if link is not none:
                    # move the link to the most recent end
                    var link_prev = link[PREV]
                    var link_next = link[NEXT]
                    var result = link[RESULT]
                    link_prev[NEXT] = link_next
                    link_next[PREV] = link_prev
                    var last = root[PREV]
                    last[NEXT] = link
                    root[PREV] = link
                    link[PREV] = last
                    link[NEXT] = root
                    hits += 1
                    return result
                misses += 1
            finally:
                mutex_unlock(lock)
            var value = user_function(*args, **kwds)
            mutex_lock(lock)
            try:
                if key in cache:
                    # the same call was cached while this one ran
                    pass
                elif full:
                    # reuse the old root for the new entry; the oldest
                    # entry becomes the root
                    var oldroot = root
                    oldroot[KEY] = key
                    oldroot[RESULT] = value
                    root = oldroot[NEXT]
                    var oldkey = root[KEY]
                    root[KEY] = none
                    root[RESULT] = none
                    del cache[oldkey]
                    cache[key] = oldroot
                else:
                    var last2 = root[PREV]
                    var newlink = [last2, root, key, value]
                    last2[NEXT] = newlink
                    root[PREV] = newlink
                    cache[key] = newlink
                    full = len(cache) >= maxsize
            finally:
                mutex_unlock(lock)
            return value
        wrapper = _bounded

    def cache_info():
        "Report cache statistics"
        return _CacheInfo(hits, misses, maxsize, len(cache))

    def cache_clear():
        "Clear the cache and cache statistics"
        nonlocal hits, misses, full
        mutex_lock(lock)
        try:
            cache.clear()
            root[PREV] = root
            root[NEXT] = root
            root[KEY] = none
            root[RESULT] = none
            hits = 0
            misses = 0
            full = false
        finally:
            mutex_unlock(lock)

    wrapper.cache_info = cache_info
    wrapper.cache_clear = cache_clear
    return wrapper


def lru_cache(maxsize=128, typed=false):
    """Least-recently-used cache decorator.

    If *maxsize* is set to None, the LRU features are disabled and the cache
    can grow without bound.

    If *typed* is True, arguments of different types will be cached separately.
    For example, f(3.0) and f(3) will be treated as distinct calls with
    distinct results.

    Arguments to the cached function must be hashable.

    View the cache statistics named tuple (hits, misses, maxsize, currsize)
    with f.cache_info().  Clear the cache and statistics with f.cache_clear().
    Access the underlying function with f.__wrapped__.
    """
    if isinstance(maxsize, int):
        # a negative maxsize is treated as 0
        if maxsize < 0:
            maxsize = 0
    elif callable(maxsize) and isinstance(typed, bool):
        # the user function was passed in directly via the maxsize argument
        var user_function = maxsize
        var wrapper = _lru_cache_wrapper(user_function, 128, typed)
        wrapper.cache_parameters = _cache_parameters(128, typed)
        return update_wrapper(wrapper, user_function)
    elif maxsize is not none:
        raise TypeError("Expected first argument to be an integer, a callable, or None")
    var size = maxsize

    def decorating_function(user_function):
        var w = _lru_cache_wrapper(user_function, size, typed)
        w.cache_parameters = _cache_parameters(size, typed)
        return update_wrapper(w, user_function)
    return decorating_function


def _cache_parameters(maxsize, typed):
    def cache_parameters():
        return {"maxsize": maxsize, "typed": typed}
    return cache_parameters


def cache(user_function):
    'Simple lightweight unbounded cache.  Sometimes called "memoize".'
    return lru_cache(maxsize=none)(user_function)


# ── cached_property ──────────────────────────────────────────────────────────
class cached_property:
    # A non-data descriptor: the first read through an instance calls func
    # and stores the value as the instance's attribute of the same name,
    # which later reads find first; `del obj.name` makes the next read
    # compute it again.
    def __init__(self, func):
        self.func = func
        self.attrname = none
        self.__doc__ = getattr(func, "__doc__", none)
        self.__module__ = getattr(func, "__module__", none)

    def __set_name__(self, owner, name):
        if self.attrname is none:
            self.attrname = name
        elif name != self.attrname:
            raise TypeError("Cannot assign the same cached_property to two different names (" +
                            repr(self.attrname) + " and " + repr(name) + ").")

    def __get__(self, instance, owner=none):
        if instance is none:
            return self
        var name = self.attrname
        if name is none:
            raise TypeError("Cannot use cached_property instance without calling __set_name__ on it.")
        var val = self.func(instance)
        object.__setattr__(instance, name, val)
        return val


# ── singledispatch ───────────────────────────────────────────────────────────
# The builtin types have no __mro__ or __bases__ here: these give Python's.
# The kinds type() names with a string (None is "none", a function
# "function", a builtin "builtin", a generator "generator") dispatch on that
# name: register(type(None), f) registers it, as Python's NoneType.
_builtin_types = [bool, int, float, complex, str, bytes, bytearray, list, tuple,
                  dict, set, frozenset, type, range, slice, object]
_kind_names = ["none", "function", "builtin", "generator"]

def _class_of(x):
    var t = type(x)
    if isinstance(t, str) and not (t in _kind_names):
        # another legacy name: a bound method (the VM's), a typed map (its
        # tag) - a function, a dict, or object
        if callable(x):
            return "function"
        return dict if isinstance(x, dict) else object
    return t

def _is_builtin_type(x):
    for t in _builtin_types:
        if x is t:
            return true
    return false

def _mro_of(cls):
    var mro = none
    if isinstance(cls, str):
        return [cls, object]
    try:
        mro = list(cls.__mro__)
    except AttributeError:
        if cls is bool:
            mro = [bool, int]
        else:
            mro = [cls]
    var has_object = false
    for c in mro:
        if c is object:
            has_object = true
    if not has_object:
        mro.append(object)
    return mro

def _bases_of(cls):
    if isinstance(cls, str):
        return (object,)
    try:
        return tuple(cls.__bases__)
    except AttributeError:
        pass
    if cls is object:
        return ()
    if cls is bool:
        return (int,)
    return (object,)

def _is_class(x):
    if isinstance(x, str):
        return x in _kind_names
    if _is_builtin_type(x):
        return true
    return isinstance(x, type) or hasattr(x, "__mro__")

def _issub(cls, typ):
    # issubclass, for the kind names too (a name is a subclass of itself
    # and of object; an ABC answers for it)
    if isinstance(typ, str):
        return isinstance(cls, str) and cls == typ
    if isinstance(cls, str) and not hasattr(typ, "__abstractmethods__"):
        return typ is object
    return issubclass(cls, typ)

def _has_abstracts(x):
    return not isinstance(x, str) and hasattr(x, "__abstractmethods__")

def _in(x, seq):
    # x in seq, by identity for classes (a type object == its name)
    for y in seq:
        if y is x or (isinstance(x, str) and isinstance(y, str) and x == y):
            return true
    return false


def _c3_merge(sequences):
    """Merges MROs in *sequences* to a single MRO using the C3 algorithm.

    Adapted from https://www.python.org/download/releases/2.3/mro/.

    """
    var result = []
    while true:
        sequences = [s for s in sequences if s]   # purge empty sequences
        if not sequences:
            return result
        var candidate = none
        for s1 in sequences:   # find merge candidates among seq heads
            candidate = s1[0]
            for s2 in sequences:
                if _in(candidate, s2[1:]):
                    candidate = none
                    break      # reject the current head, it appears later
            if candidate is not none:
                break
        if candidate is none:
            raise RuntimeError("Inconsistent hierarchy")
        result.append(candidate)
        # remove the chosen candidate
        for seq in sequences:
            if seq[0] is candidate or (isinstance(candidate, str) and seq[0] == candidate):
                del seq[0]


def _c3_mro(cls, abcs=none):
    """Computes the method resolution order using extended C3 linearization.

    If no *abcs* are given, the algorithm works exactly like the built-in C3
    linearization used for method resolution.

    If given, *abcs* is a list of abstract base classes that should be inserted
    into the resulting MRO. Unrelated ABCs are ignored and don't end up in the
    result. The algorithm inserts ABCs where their functionality is introduced,
    i.e. issubclass(cls, abc) returns True for the class itself but returns
    False for all its direct base classes. Implicit ABCs for a given class
    (either registered or inferred from the presence of a special method like
    __len__) are inserted directly after the last ABC explicitly listed in the
    MRO of said class. If two implicit ABCs end up next to each other in the
    resulting MRO, their ordering depends on the order of types in *abcs*.

    """
    var bases = _bases_of(cls)
    var boundary = 0
    var n = len(bases)
    for i in range(n):
        if _has_abstracts(bases[n - 1 - i]):
            boundary = n - i
            break   # Bases up to the last explicit ABC are considered first.
    abcs = list(abcs) if abcs else []
    var explicit_bases = list(bases[0:boundary])
    var abstract_bases = []
    var other_bases = list(bases[boundary:])
    for base in abcs:
        if _issub(cls, base) and not any([_issub(b, base) for b in bases]):
            # If *cls* is the class that introduces behaviour described by
            # an ABC *base*, insert said ABC to its MRO.
            abstract_bases.append(base)
    for base in abstract_bases:
        abcs = [a for a in abcs if not (a is base)]
    var explicit_c3_mros = [_c3_mro(base, abcs=abcs) for base in explicit_bases]
    var abstract_c3_mros = [_c3_mro(base, abcs=abcs) for base in abstract_bases]
    var other_c3_mros = [_c3_mro(base, abcs=abcs) for base in other_bases]
    return _c3_merge(
        [[cls]] +
        explicit_c3_mros + abstract_c3_mros + other_c3_mros +
        [explicit_bases] + [abstract_bases] + [other_bases]
    )


def _compose_mro(cls, types):
    """Calculates the method resolution order for a given class *cls*.

    Includes relevant abstract base classes (with their respective bases) from
    the *types* iterable. Uses a modified C3 linearization algorithm.

    """
    var bases = _mro_of(cls)
    # Remove entries which are already present in the __mro__ or unrelated.
    def is_related(typ):
        return (not _in(typ, bases) and _is_class(typ) and not isinstance(typ, str)
                and _issub(cls, typ))
    types = [n for n in types if is_related(n)]
    # Remove entries which are strict bases of other entries (they will end up
    # in the MRO anyway.
    def is_strict_base(typ):
        for other in types:
            if not (typ is other) and _in(typ, _mro_of(other)):
                return true
        return false
    types = [n for n in types if not is_strict_base(n)]
    # Subclasses of the ABCs in *types* which are also implemented by
    # *cls* can be used to stabilize ABC ordering.
    var mro = []
    for typ in types:
        var found = []
        var subs = []
        try:
            subs = typ.__subclasses__()
        except AttributeError:
            subs = []
        for sub in subs:
            if not _in(sub, bases) and _issub(cls, sub):
                found.append([s for s in _mro_of(sub) if _in(s, types)])
        if not found:
            mro.append(typ)
            continue
        # Favor subclasses with the biggest number of useful bases
        found = sorted(found, key=len, reverse=true)
        for sub in found:
            for subcls in sub:
                if not _in(subcls, mro):
                    mro.append(subcls)
    return _c3_mro(cls, abcs=mro)


def _find_impl(cls, registry):
    """Returns the best matching implementation from *registry* for type *cls*.

    Where there is no registered implementation for a specific type, its method
    resolution order is used to find a more generic implementation.

    Note: if *registry* does not contain an implementation for the base
    *object* type, this function may return None.

    """
    var mro = _compose_mro(cls, registry.keys())
    var cls_mro = _mro_of(cls)
    var best = none
    for t in mro:
        if best is not none:
            # If *best* is an implicit ABC but there is another unrelated,
            # equally matching implicit ABC, refuse the temptation to guess.
            if (t in registry and not _in(t, cls_mro)
                              and not _in(best, cls_mro)
                              and not _issub(best, t)):
                raise RuntimeError("Ambiguous dispatch: " + str(best) + " or " + str(t))
            break
        if t in registry:
            best = t
    return registry.get(best)


class _DispatchRegistry:
    # The registry, read-only as Python's MappingProxyType: keyed by class
    # (a type object is also == its name, so classes are compared by
    # identity), in registration order.
    def __init__(self):
        self._pairs = []

    def _set(self, cls, func):
        for p in self._pairs:
            if _in(cls, [p[0]]):
                p[1] = func
                return
        self._pairs.append([cls, func])

    def _find(self, cls):
        for p in self._pairs:
            if _in(cls, [p[0]]):
                return p
        return none

    def __getitem__(self, cls):
        var p = self._find(cls)
        if p is none:
            raise KeyError(cls)
        return p[1]

    def get(self, cls, default=none):
        var p = self._find(cls)
        return default if p is none else p[1]

    def __contains__(self, cls):
        return self._find(cls) is not none

    def __len__(self):
        return len(self._pairs)

    def __iter__(self):
        return iter([p[0] for p in self._pairs])

    def keys(self):
        return [p[0] for p in self._pairs]

    def values(self):
        return [p[1] for p in self._pairs]

    def items(self):
        return [(p[0], p[1]) for p in self._pairs]

    def __repr__(self):
        return "mappingproxy({" + ", ".join([repr(p[0]) + ": " + repr(p[1]) for p in self._pairs]) + "})"


def _is_union_type(cls):
    # int | str (types.UnionType), typing.Union[int, str]
    if isinstance(cls, str) or _is_class(cls):
        return false
    if type(cls).__name__ in ["_NyUnionType", "UnionType"]:
        return true
    var origin = getattr(cls, "__origin__", none)
    return origin is not none and repr(origin) == "typing.Union"

def _union_args(cls):
    return tuple(getattr(cls, "__args__", ()))

def _is_valid_dispatch_type(cls):
    if _is_class(cls):
        return true
    return _is_union_type(cls) and all([_is_class(arg) for arg in _union_args(cls)])

def _first_annotation(func):
    # (name, type) of the first annotated parameter, as
    # next(iter(get_type_hints(func).items())): an annotation kept as text
    # (from __future__ import annotations, a forward reference) is
    # evaluated here, which finds the builtin types and NoneType
    var ann = getattr(func, "__annotations__", {})
    for name in ann:
        if name == "return":
            continue
        var t = ann[name]
        if isinstance(t, str):
            if t == "None" or t == "NoneType":
                t = type(none)
            else:
                try:
                    t = eval(t)
                except Exception:
                    pass
        return (name, t)
    var names = list(ann.keys())
    if len(names) > 0:
        return (names[0], ann[names[0]])
    return none


def singledispatch(func):
    """Single-dispatch generic function decorator.

    Transforms a function into a generic function, which can have different
    behaviours depending upon the type of its first argument. The decorated
    function acts as the default implementation, and additional
    implementations can be registered using the register() attribute of the
    generic function.
    """
    var registry = _DispatchRegistry()
    var dispatch_cache = {}
    var cache_token = none
    var funcname = getattr(func, "__name__", "singledispatch function")

    def dispatch(cls):
        """generic_func.dispatch(cls) -> <function implementation>

        Runs the dispatch algorithm to return the best available implementation
        for the given *cls* registered on *generic_func*.
        """
        nonlocal cache_token
        if cache_token is not none:
            var current_token = _abc_cache_token()
            if cache_token != current_token:
                dispatch_cache.clear()
                cache_token = current_token
        if cls in dispatch_cache:
            return dispatch_cache[cls]
        var p = registry._find(cls)
        var impl = none
        if p is not none:
            impl = p[1]
        else:
            impl = _find_impl(cls, registry)
        dispatch_cache[cls] = impl
        return impl

    def register(cls, func=none):
        """generic_func.register(cls, func) -> func

        Registers a new implementation for the given *cls* on a *generic_func*.
        """
        nonlocal cache_token
        if _is_valid_dispatch_type(cls):
            if func is none:
                def _register_deco(f):
                    return register(cls, f)
                return _register_deco
        else:
            if func is not none:
                raise TypeError("Invalid first argument to `register()`. " + repr(cls) + " is not a class or union type.")
            var ann = getattr(cls, "__annotations__", {})
            if not ann:
                raise TypeError("Invalid first argument to `register()`: " + repr(cls) +
                                ". Use either `@register(some_class)` or plain `@register` on an annotated function.")
            func = cls
            var first = _first_annotation(func)
            var argname = first[0]
            cls = first[1]
            if not _is_valid_dispatch_type(cls):
                if _is_union_type(cls):
                    raise TypeError("Invalid annotation for " + repr(argname) + ". " + repr(cls) + " not all arguments are classes.")
                else:
                    raise TypeError("Invalid annotation for " + repr(argname) + ". " + repr(cls) + " is not a class.")
        var members = _union_args(cls) if _is_union_type(cls) else (cls,)
        for arg in members:
            registry._set(arg, func)
            if cache_token is none and _has_abstracts(arg):
                cache_token = _abc_cache_token()
        dispatch_cache.clear()
        return func

    def wrapper(*args, **kw):
        if len(args) == 0:
            raise TypeError(funcname + " requires at least 1 positional argument")
        return dispatch(_class_of(args[0]))(*args, **kw)

    registry._set(object, func)
    wrapper.register = register
    wrapper.dispatch = dispatch
    wrapper.registry = registry
    wrapper._clear_cache = dispatch_cache.clear
    update_wrapper(wrapper, func)
    return wrapper


def _abc_cache_token():
    # abc.get_cache_token(); abc is loaded once an ABC is registered
    import abc as _abc_mod
    return _abc_mod.get_cache_token()


class singledispatchmethod:
    """Single-dispatch generic method descriptor.

    Supports wrapping existing descriptors and handles non-descriptor
    callables as instance methods.
    """
    def __init__(self, func):
        if not callable(func) and not hasattr(func, "__get__"):
            raise TypeError(repr(func) + " is not callable or a descriptor")
        self.dispatcher = singledispatch(func)
        self.func = func

    def register(self, cls, method=none):
        """generic_method.register(cls, func) -> func

        Registers a new implementation for the given *cls* on a *generic_method*.
        """
        return self.dispatcher.register(cls, func=method)

    def __get__(self, obj, cls=none):
        var dispatcher = self.dispatcher
        var funcname = getattr(self.func, "__name__", "singledispatchmethod method")
        def _method(*args, **kwargs):
            if len(args) == 0:
                raise TypeError(funcname + " requires at least 1 positional argument")
            var method = dispatcher.dispatch(_class_of(args[0]))
            if obj is none:
                return method(*args, **kwargs)
            return method(obj, *args, **kwargs)
        _method.register = self.register
        update_wrapper(_method, self.func)
        return _method
