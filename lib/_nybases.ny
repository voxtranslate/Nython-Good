# nython: module
# nython: python    (Python's rules: `is` is identity, a name a function binds is its local)
# lib/_nybases.ny - C.__bases__ = value (round 87): CPython's type_set_bases
# checks, in its order and words, for both engines (the prelude's
# _bases_check imports this module the first time a class's bases are
# assigned). The checks run over a model of CPython's instance layouts: a
# class's tp_base (best_base of its bases), whether a type is
# garbage-collected (its deallocator), the type a layout comes from
# (compatible_with_tp_base walked up) and the slots it adds - so the
# assignments CPython refuses are refused here with its messages
# ("'int' deallocator differs from 'A'", "'list' object layout differs from
# 'A'", "multiple bases have instance lay-out conflict"). check() returns the
# new bases; the engines then rebuild the class's MRO and its subclasses'.

_GC_BUILTINS = ("list", "dict", "tuple", "set", "frozenset", "type")
# the builtin types no class may derive from (no Py_TPFLAGS_BASETYPE)
_FINAL_TYPES = ("bool", "NoneType", "range", "slice", "memoryview", "function", "method", "generator",
                "coroutine", "builtin_function_or_method", "ellipsis", "NotImplementedType")
_OWN_LAYOUT_EXC = ("BaseException", "BaseExceptionGroup", "StopIteration", "SystemExit", "ImportError",
                    "ModuleNotFoundError", "OSError", "SyntaxError", "IndentationError", "TabError",
                    "AttributeError", "NameError", "UnicodeError", "UnicodeEncodeError", "UnicodeDecodeError",
                    "UnicodeTranslateError")
def _tp_heap(t):
    return getattr(t, "__module__", "builtins") != "builtins"
def _tp_isexc(t):
    return issubclass(t, BaseException)
def _tp_slots(t):
    # the __slots__ a class body named (None: a __dict__), without __dict__ / __weakref__
    d = t.__dict__
    if "__slots__" not in d:
        return None
    s = d["__slots__"]
    if isinstance(s, str):
        s = (s,)
    return tuple([x for x in s if x != "__dict__" and x != "__weakref__"])
def _tp_base(t):
    if t is object:
        return None
    if _tp_heap(t):
        return _best_base(t.__bases__)
    if t is bool:
        return int
    if _tp_isexc(t) and t is not BaseException:
        return t.__bases__[0]
    return object
def _extra_ivars(t):
    if _tp_heap(t):
        s = _tp_slots(t)
        return s is not None and len(s) > 0
    if _tp_isexc(t):
        return t.__name__ in _OWN_LAYOUT_EXC
    return t is not object and t is not bool
def _solid_base(t):
    b = _tp_base(t)
    base = object if b is None else _solid_base(b)
    return t if _extra_ivars(t) else base
def _best_base(bases):
    winner = None
    base = None
    for b in bases:
        if not _tp_heap(b) and b.__name__ in _FINAL_TYPES:
            raise TypeError("type '" + b.__name__ + "' is not an acceptable base type")
        cand = _solid_base(b)
        if winner is None:
            winner = cand
            base = b
        elif issubclass(winner, cand):
            pass
        elif issubclass(cand, winner):
            winner = cand
            base = b
        else:
            raise TypeError("multiple bases have instance lay-out conflict")
    return object if base is None else base
def _tp_gc(t):
    return _tp_heap(t) or _tp_isexc(t) or t.__name__ in _GC_BUILTINS
def _layout_root(t):
    # compatible_with_tp_base, walked up: the type the layout comes from
    while True:
        p = _tp_base(t)
        if p is None:
            return t
        if _tp_heap(t):
            s = _tp_slots(t)
            if not _tp_heap(p) or (s is not None and len(s) > 0):
                return t
        elif _tp_isexc(t):
            if t.__name__ in _OWN_LAYOUT_EXC:
                return t
        elif t is not bool:
            return t
        t = p
def _same_slots_added(a, b):
    if not _tp_heap(a) or not _tp_heap(b):
        return False
    base = _tp_base(a)
    if issubclass(base, (int, tuple, bytes)):
        return False   # a variable-sized base: the dict is not where the sizes say
    sa = _tp_slots(a)
    sb = _tp_slots(b)
    if sa is None or sb is None:
        return sa is None and sb is None
    return sa == sb
def _c3(cls, bases):
    seqs = [list(b.__mro__) for b in bases] + [list(bases)]
    out = [cls]
    while True:
        seqs = [s for s in seqs if len(s) > 0]
        if len(seqs) == 0:
            return out
        cand = None
        for s in seqs:
            bad = False
            for s2 in seqs:
                if s[0] in s2[1:]:
                    bad = True
                    break
            if not bad:
                cand = s[0]
                break
        if cand is None:
            heads = []
            for s in seqs:
                if s[0] not in heads:
                    heads.append(s[0])
            raise TypeError("Cannot create a consistent method resolution\norder (MRO) for bases " + ", ".join([h.__name__ for h in heads]))
        out.append(cand)
        for s in seqs:
            if s[0] is cand:
                s.pop(0)
def check(cls, value):
    name = cls.__name__
    if not _tp_heap(cls):
        if value is None:
            raise TypeError("cannot delete '__bases__' attribute of immutable type '" + name + "'")
        raise TypeError("cannot set '__bases__' attribute of immutable type '" + name + "'")
    if value is None:
        raise TypeError("cannot delete '__bases__' attribute of immutable type '" + name + "'")
    if not isinstance(value, tuple):
        raise TypeError("can only assign tuple to " + name + ".__bases__, not " + type(value).__name__)
    if len(value) == 0:
        raise TypeError("can only assign non-empty tuple to " + name + ".__bases__, not ()")
    for b in value:
        if not isinstance(b, type):
            raise TypeError(name + ".__bases__ must be tuple of classes, not '" + type(b).__name__ + "'")
        if issubclass(b, cls):
            raise TypeError("a __bases__ item causes an inheritance cycle")
    new_base = _best_base(value)
    old_base = _best_base(cls.__bases__)
    if _tp_gc(new_base) != _tp_gc(old_base):
        raise TypeError("__bases__ assignment: '" + new_base.__name__ + "' deallocator differs from '" + old_base.__name__ + "'")
    nb = _layout_root(new_base)
    ob = _layout_root(old_base)
    if nb is not ob and (_tp_base(nb) is not _tp_base(ob) or not _same_slots_added(nb, ob)):
        raise TypeError("__bases__ assignment: '" + new_base.__name__ + "' object layout differs from '" + old_base.__name__ + "'")
    seen = []
    for b in value:
        if b in seen:
            raise TypeError("duplicate base class " + b.__name__)
        seen.append(b)
    _c3(cls, value)
    return list(value)


def base_of(cls):
    # C.__base__: the base its instances' layout comes from (tp_base)
    if cls is object:
        return None
    return _best_base(cls.__bases__)
