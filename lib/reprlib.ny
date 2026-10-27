# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/reprlib.ny - Python's reprlib: reprs of limited size (round 79; bdb and
# pdb show return values with it).
#
#     import reprlib
#     reprlib.repr(list(range(100)))      # '[0, 1, 2, 3, 4, 5, ...]'
#     reprlib.repr("x" * 100)             # "'xxxxxxxxxxxx...xxxxxxxxxxxxx'"
#
# Repr()   fillvalue "...", maxlevel 6, maxtuple 6, maxlist 6, maxarray 5,
#          maxdict 4, maxset 6, maxfrozenset 6, maxdeque 6, maxstring 30,
#          maxlong 40, maxother 30; repr(x), repr1(x, level) dispatching on
#          repr_<typename> (a subclass adds its own), repr_tuple, repr_list,
#          repr_set, repr_frozenset, repr_deque, repr_dict, repr_str,
#          repr_int, repr_instance - CPython's truncation rules
# aRepr, repr(x), recursive_repr(fillvalue="...") (a decorator for
# __repr__ that gives fillvalue for a value already being shown)
#
# Not here: repr_array (there is no array module); Python 3.12's indent.

__all__ = ["Repr", "repr", "recursive_repr"]

_builtin_repr = repr


def recursive_repr(fillvalue="..."):
    "Decorator to make a repr function return fillvalue for a recursive call"

    def decorating_function(user_function):
        repr_running = set()

        def wrapper(self):
            key = id(self)
            if key in repr_running:
                return fillvalue
            repr_running.add(key)
            try:
                result = user_function(self)
            finally:
                repr_running.discard(key)
            return result

        wrapper.__module__ = getattr(user_function, "__module__", None)
        wrapper.__doc__ = getattr(user_function, "__doc__", None)
        wrapper.__name__ = getattr(user_function, "__name__", "wrapper")
        wrapper.__qualname__ = getattr(user_function, "__qualname__", "wrapper")
        wrapper.__wrapped__ = user_function
        return wrapper

    return decorating_function


def _possibly_sorted(x):
    # Since not all sequences of items can be sorted and comparison
    # functions may raise arbitrary exceptions, return an unsorted
    # sequence in that case.
    try:
        return sorted(x)
    except Exception:
        return list(x)


class Repr:

    def __init__(self):
        self.fillvalue = "..."
        self.maxlevel = 6
        self.maxtuple = 6
        self.maxlist = 6
        self.maxarray = 5
        self.maxdict = 4
        self.maxset = 6
        self.maxfrozenset = 6
        self.maxdeque = 6
        self.maxstring = 30
        self.maxlong = 40
        self.maxother = 30

    def repr(self, x):
        return self.repr1(x, self.maxlevel)

    def repr1(self, x, level):
        typename = type(x).__name__
        if " " in typename:
            parts = typename.split()
            typename = "_".join(parts)
        meth = getattr(self, "repr_" + typename, None)
        if meth is not None:
            return meth(x, level)
        return self.repr_instance(x, level)

    def _repr_iterable(self, x, level, left, right, maxiter, trail=""):
        n = len(x)
        if level <= 0 and n:
            s = self.fillvalue
        else:
            newlevel = level - 1
            items = list(x)
            pieces = [self.repr1(elem, newlevel) for elem in items[:maxiter]]
            if n > maxiter:
                pieces.append(self.fillvalue)
            s = ", ".join(pieces)
            if n == 1 and trail:
                right = trail + right
        return "%s%s%s" % (left, s, right)

    def repr_tuple(self, x, level):
        return self._repr_iterable(x, level, "(", ")", self.maxtuple, ",")

    def repr_list(self, x, level):
        return self._repr_iterable(x, level, "[", "]", self.maxlist)

    def repr_set(self, x, level):
        if not x:
            return "set()"
        x = _possibly_sorted(x)
        return self._repr_iterable(x, level, "{", "}", self.maxset)

    def repr_frozenset(self, x, level):
        if not x:
            return "frozenset()"
        x = _possibly_sorted(x)
        return self._repr_iterable(x, level, "frozenset({", "})", self.maxfrozenset)

    def repr_deque(self, x, level):
        return self._repr_iterable(x, level, "deque([", "])", self.maxdeque)

    def repr_dict(self, x, level):
        n = len(x)
        if n == 0:
            return "{}"
        if level <= 0:
            return "{" + self.fillvalue + "}"
        newlevel = level - 1
        pieces = []
        for key in _possibly_sorted(x)[:self.maxdict]:
            keyrepr = self.repr1(key, newlevel)
            valrepr = self.repr1(x[key], newlevel)
            pieces.append("%s: %s" % (keyrepr, valrepr))
        if n > self.maxdict:
            pieces.append(self.fillvalue)
        s = ", ".join(pieces)
        return "{%s}" % (s,)

    def repr_str(self, x, level):
        s = _builtin_repr(x[:self.maxstring])
        if len(s) > self.maxstring:
            i = max(0, (self.maxstring - 3) // 2)
            j = max(0, self.maxstring - 3 - i)
            s = _builtin_repr(x[:i] + x[len(x) - j:])
            s = s[:i] + self.fillvalue + s[len(s) - j:]
        return s

    def repr_int(self, x, level):
        s = _builtin_repr(x)
        if len(s) > self.maxlong:
            i = max(0, (self.maxlong - 3) // 2)
            j = max(0, self.maxlong - 3 - i)
            s = s[:i] + self.fillvalue + s[len(s) - j:]
        return s

    def repr_instance(self, x, level):
        try:
            s = _builtin_repr(x)
            # Bugs in x.__repr__() can cause arbitrary
            # exceptions -- then make up something
        except Exception:
            return "<%s instance at %#x>" % (type(x).__name__, id(x))
        if len(s) > self.maxother:
            i = max(0, (self.maxother - 3) // 2)
            j = max(0, self.maxother - 3 - i)
            s = s[:i] + self.fillvalue + s[len(s) - j:]
        return s


aRepr = Repr()
repr = aRepr.repr
