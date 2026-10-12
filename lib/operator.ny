# nython: module    (import it by name: it runs in a module scope of its own)
# lib/operator.ny - Python's operator module: the operators as functions.
#
#     from operator import itemgetter, attrgetter, methodcaller, add, iadd
#
# comparisons    lt le eq ne ge gt, not_ truth is_ is_not
# arithmetic     abs add and_ floordiv index inv/invert lshift mod mul matmul
#                neg or_ pos pow rshift sub truediv xor concat
# sequences      contains countOf delitem getitem indexOf setitem length_hint
# in place       iadd iand iconcat ifloordiv ilshift imod imul imatmul ior
#                ipow irshift isub itruediv ixor (return the updated value)
# callables      itemgetter, attrgetter (dotted names), methodcaller, call
# and the dunder aliases (__add__, __lt__, ...), as Python's module has them.
#
# Differences from Python, all from the runtime rather than this module:
# - is_ / is_not compare identity with id(), as `is` is a type test in
#   Nython; values the runtime does not keep as objects (ints, strings)
#   share an identity when equal.
# - The in-place functions on sets and dicts (ior, iand, isub, ixor) update
#   the left operand in place, as Python's do: the runtime's own `s |= t`
#   rebinds s to a new set instead (lists' += is in place, as in Python).
# - length_hint knows len() and __length_hint__; the runtime's own
#   iterators do not report how much is left, so they give the default.

__all__ = ["abs", "add", "and_", "attrgetter", "call", "concat", "contains", "countOf",
           "delitem", "eq", "floordiv", "ge", "getitem", "gt", "iadd", "iand",
           "iconcat", "ifloordiv", "ilshift", "imatmul", "imod", "imul",
           "index", "indexOf", "inv", "invert", "ior", "ipow", "irshift",
           "is_", "is_not", "isub", "itemgetter", "itruediv", "ixor", "le",
           "length_hint", "lshift", "lt", "matmul", "methodcaller", "mod",
           "mul", "ne", "neg", "not_", "or_", "pos", "pow", "rshift",
           "setitem", "sub", "truediv", "truth", "xor"]

# the builtins this module's own abs/pow shadow
_builtin_abs = abs
_builtin_pow = pow


def _tname(x):
    return type(x).__name__


# ── comparisons ──────────────────────────────────────────────────────────────
def lt(a, b):
    "Same as a < b."
    return a < b

def le(a, b):
    "Same as a <= b."
    return a <= b

def eq(a, b):
    "Same as a == b."
    return a == b

def ne(a, b):
    "Same as a != b."
    return a != b

def ge(a, b):
    "Same as a >= b."
    return a >= b

def gt(a, b):
    "Same as a > b."
    return a > b


# ── logical ──────────────────────────────────────────────────────────────────
def not_(a):
    "Same as not a."
    return not a

def truth(a):
    "Return True if a is true, False otherwise."
    return true if a else false

def is_(a, b):
    "Same as a is b."
    return id(a) == id(b)

def is_not(a, b):
    "Same as a is not b."
    return id(a) != id(b)


# ── arithmetic ───────────────────────────────────────────────────────────────
def abs(a):
    "Same as abs(a)."
    return _builtin_abs(a)

def add(a, b):
    "Same as a + b."
    return a + b

def and_(a, b):
    "Same as a & b."
    return a & b

def floordiv(a, b):
    "Same as a // b."
    return a // b

def index(a):
    "Same as a.__index__()."
    if isinstance(a, bool):
        return 1 if a else 0
    if isinstance(a, int):
        return a
    if hasattr(a, "__index__"):
        var r = a.__index__()
        if isinstance(r, bool) or not isinstance(r, int):
            raise TypeError("__index__ returned non-int (type " + _tname(r) + ")")
        return r
    raise TypeError("'" + _tname(a) + "' object cannot be interpreted as an integer")

def inv(a):
    "Same as ~a."
    return ~a

invert = inv

def lshift(a, b):
    "Same as a << b."
    return a << b

def mod(a, b):
    "Same as a % b."
    return a % b

def mul(a, b):
    "Same as a * b."
    return a * b

def matmul(a, b):
    "Same as a @ b."
    return a @ b

def neg(a):
    "Same as -a."
    return -a

def or_(a, b):
    "Same as a | b."
    return a | b

def pos(a):
    "Same as +a."
    return +a

def pow(a, b):
    "Same as a ** b."
    return a ** b

def rshift(a, b):
    "Same as a >> b."
    return a >> b

def sub(a, b):
    "Same as a - b."
    return a - b

def truediv(a, b):
    "Same as a / b."
    return a / b

def xor(a, b):
    "Same as a ^ b."
    return a ^ b


# ── sequences ────────────────────────────────────────────────────────────────
def _concatenable(a):
    return isinstance(a, (str, list, tuple, bytes, bytearray)) or hasattr(a, "__getitem__")

def concat(a, b):
    "Same as a + b, for a and b sequences."
    if not _concatenable(a):
        raise TypeError("'" + _tname(a) + "' object can't be concatenated")
    return a + b

def contains(a, b):
    "Same as b in a (note reversed operands)."
    return b in a

def countOf(a, b):
    "Return the number of items in a which are, or which equal, b."
    var n = 0
    for i in a:
        if id(i) == id(b) or i == b:
            n += 1
    return n

def delitem(a, b):
    "Same as del a[b]."
    del a[b]

def getitem(a, b):
    "Same as a[b]."
    return a[b]

def indexOf(a, b):
    "Return the first index of b in a."
    var i = 0
    for j in a:
        if id(j) == id(b) or j == b:
            return i
        i += 1
    raise ValueError("sequence.index(x): x not in sequence")

def setitem(a, b, c):
    "Same as a[b] = c."
    a[b] = c

def length_hint(obj, default=0):
    """
    Return an estimate of the number of items in obj.
    This is useful for presizing containers when building from an iterable.

    If the object supports len(), the result will be exact. Otherwise, it may
    over- or under-estimate by an arbitrary amount. The result will be an
    integer >= 0.
    """
    if isinstance(default, bool) or not isinstance(default, int):
        raise TypeError("'" + _tname(default) + "' object cannot be interpreted as an integer")
    try:
        return len(obj)
    except TypeError:
        pass
    if not hasattr(obj, "__length_hint__"):
        return default
    var val = none
    try:
        val = obj.__length_hint__()
    except TypeError:
        return default
    if isinstance(val, bool) or not isinstance(val, int):
        raise TypeError("__length_hint__ must be integer, not " + _tname(val))
    if val < 0:
        raise ValueError("__length_hint__() should return >= 0")
    return val


# ── calling ──────────────────────────────────────────────────────────────────
def call(obj, *args, **kwargs):
    "Same as obj(*args, **kwargs)."
    return obj(*args, **kwargs)


class attrgetter:
    """
    Return a callable object that fetches the given attribute(s) from its operand.
    After f = attrgetter('name'), the call f(r) returns r.name.
    After g = attrgetter('name', 'date'), the call g(r) returns (r.name, r.date).
    After h = attrgetter('name.first', 'name.last'), the call h(r) returns
    (r.name.first, r.name.last).
    """
    def __init__(self, *attrs):
        if len(attrs) == 0:
            raise TypeError("attrgetter expected 1 argument, got 0")
        for a in attrs:
            if not isinstance(a, str):
                raise TypeError("attribute name must be a string")
        self._attrs = tuple(attrs)
        self._paths = [a.split(".") for a in attrs]

    def _get(self, obj, path):
        var o = obj
        for name in path:
            o = getattr(o, name)
        return o

    def __call__(self, obj):
        if len(self._paths) == 1:
            return self._get(obj, self._paths[0])
        return tuple([self._get(obj, p) for p in self._paths])

    def __repr__(self):
        return "operator.attrgetter(" + ", ".join([repr(a) for a in self._attrs]) + ")"

    def __reduce__(self):
        return (attrgetter, self._attrs)


class itemgetter:
    """
    Return a callable object that fetches the given item(s) from its operand.
    After f = itemgetter(2), the call f(r) returns r[2].
    After g = itemgetter(2, 5, 3), the call g(r) returns (r[2], r[5], r[3])
    """
    def __init__(self, *items):
        if len(items) == 0:
            raise TypeError("itemgetter expected 1 argument, got 0")
        self._items = tuple(items)
        self._one = len(items) == 1

    def __call__(self, obj):
        if self._one:
            return obj[self._items[0]]
        return tuple([obj[i] for i in self._items])

    def __repr__(self):
        return "operator.itemgetter(" + ", ".join([repr(i) for i in self._items]) + ")"

    def __reduce__(self):
        return (itemgetter, self._items)


class methodcaller:
    """
    Return a callable object that calls the given method on its operand.
    After f = methodcaller('name'), the call f(r) returns r.name().
    After g = methodcaller('name', 'date', foo=1), the call g(r) returns
    r.name('date', foo=1).
    """
    def __init__(self, *args, **kwargs):
        if len(args) == 0:
            raise TypeError("methodcaller needs at least one argument, the method name")
        if not isinstance(args[0], str):
            raise TypeError("method name must be a string")
        self._name = args[0]
        self._args = tuple(args[1:])
        self._kwargs = kwargs

    def __call__(self, obj):
        return getattr(obj, self._name)(*self._args, **self._kwargs)

    def __repr__(self):
        var parts = [repr(self._name)]
        for a in self._args:
            parts.append(repr(a))
        for k in self._kwargs:
            parts.append(k + "=" + repr(self._kwargs[k]))
        return "operator.methodcaller(" + ", ".join(parts) + ")"


# ── in place ─────────────────────────────────────────────────────────────────
# a op= b, returning the result. Lists' += and *= extend in place; sets and
# dicts are updated in place here explicitly (see the header).
def iadd(a, b):
    "Same as a += b."
    a += b
    return a

def iand(a, b):
    "Same as a &= b."
    if isinstance(a, set) and isinstance(b, (set, frozenset)):
        a.intersection_update(b)
        return a
    a &= b
    return a

def iconcat(a, b):
    "Same as a += b, for a and b sequences."
    if not _concatenable(a):
        raise TypeError("'" + _tname(a) + "' object can't be concatenated")
    a += b
    return a

def ifloordiv(a, b):
    "Same as a //= b."
    a //= b
    return a

def ilshift(a, b):
    "Same as a <<= b."
    a <<= b
    return a

def imod(a, b):
    "Same as a %= b."
    a %= b
    return a

def imul(a, b):
    "Same as a *= b."
    a *= b
    return a

def imatmul(a, b):
    "Same as a @= b."
    if hasattr(a, "__imatmul__"):
        return a.__imatmul__(b)
    return a @ b

def ior(a, b):
    "Same as a |= b."
    if isinstance(a, set) and isinstance(b, (set, frozenset)):
        a.update(b)
        return a
    if isinstance(a, dict) and isinstance(b, dict):
        a.update(b)
        return a
    a |= b
    return a

def ipow(a, b):
    "Same as a **= b."
    a **= b
    return a

def irshift(a, b):
    "Same as a >>= b."
    a >>= b
    return a

def isub(a, b):
    "Same as a -= b."
    if isinstance(a, set) and isinstance(b, (set, frozenset)):
        a.difference_update(b)
        return a
    a -= b
    return a

def itruediv(a, b):
    "Same as a /= b."
    a /= b
    return a

def ixor(a, b):
    "Same as a ^= b."
    if isinstance(a, set) and isinstance(b, (set, frozenset)):
        a.symmetric_difference_update(b)
        return a
    a ^= b
    return a


# ── the dunder aliases ───────────────────────────────────────────────────────
__lt__ = lt
__le__ = le
__eq__ = eq
__ne__ = ne
__ge__ = ge
__gt__ = gt
__not__ = not_
__abs__ = abs
__add__ = add
__and__ = and_
__call__ = call
__floordiv__ = floordiv
__index__ = index
__inv__ = inv
__invert__ = inv
__lshift__ = lshift
__mod__ = mod
__mul__ = mul
__matmul__ = matmul
__neg__ = neg
__or__ = or_
__pos__ = pos
__pow__ = pow
__rshift__ = rshift
__sub__ = sub
__truediv__ = truediv
__xor__ = xor
__concat__ = concat
__contains__ = contains
__delitem__ = delitem
__getitem__ = getitem
__setitem__ = setitem
__iadd__ = iadd
__iand__ = iand
__iconcat__ = iconcat
__ifloordiv__ = ifloordiv
__ilshift__ = ilshift
__imod__ = imod
__imul__ = imul
__imatmul__ = imatmul
__ior__ = ior
__ipow__ = ipow
__irshift__ = irshift
__isub__ = isub
__itruediv__ = itruediv
__ixor__ = ixor
