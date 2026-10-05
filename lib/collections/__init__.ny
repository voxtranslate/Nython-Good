# nython: module    (import it by name: it runs in a module scope of its own)
# lib/collections.ny - Python's collections (round 77).
#
#     from collections import deque, Counter, defaultdict, OrderedDict, namedtuple
#
# deque         a ring buffer: O(1) append/appendleft/pop/popleft and
#               indexing, maxlen (the far end drops off), rotate, extendleft
# Counter       counts: most_common, elements, update/subtract, total, + - & |
# defaultdict   a dict whose missing keys are made by default_factory
# OrderedDict   a dict with move_to_end and popitem(last=)
# namedtuple    a tuple class with named fields (_make, _asdict, _replace,
#               _fields, defaults=)
# ChainMap      several mappings searched in order; writes go to the first
# UserDict / UserList   wrappers to subclass
#
# They were native stubs that returned an empty list whatever they were
# given (deque([1, 2]) was []).


def _reprs(items):
    return ", ".join([repr(x) for x in items])


# ── deque ────────────────────────────────────────────────────────────────────
class deque:
    # A circular buffer: _buf holds _n items from _head, wrapping around;
    # it doubles when full, so every end operation is O(1) amortised.
    def __init__(self, iterable=none, maxlen=none):
        if maxlen != none and maxlen < 0:
            raise ValueError("maxlen must be non-negative")
        self.maxlen = maxlen
        self._buf = [none] * 8
        self._head = 0
        self._n = 0
        if iterable != none:
            for x in iterable:
                self.append(x)

    def _grow(self):
        var cap = len(self._buf)
        var nb = [none] * (cap * 2)
        for i in range(self._n):
            nb[i] = self._buf[(self._head + i) % cap]
        self._buf = nb
        self._head = 0

    def _slot(self, i):
        var n = self._n
        if i < 0:
            i = i + n
        if i < 0 or i >= n:
            raise IndexError("deque index out of range")
        return (self._head + i) % len(self._buf)

    def append(self, x):
        if self.maxlen == 0:
            return none
        if self.maxlen != none and self._n == self.maxlen:
            self.popleft()
        if self._n == len(self._buf):
            self._grow()
        self._buf[(self._head + self._n) % len(self._buf)] = x
        self._n = self._n + 1
        return none

    def appendleft(self, x):
        if self.maxlen == 0:
            return none
        if self.maxlen != none and self._n == self.maxlen:
            self.pop()
        if self._n == len(self._buf):
            self._grow()
        self._head = (self._head - 1) % len(self._buf)
        self._buf[self._head] = x
        self._n = self._n + 1
        return none

    def pop(self):
        if self._n == 0:
            raise IndexError("pop from an empty deque")
        var s = (self._head + self._n - 1) % len(self._buf)
        var x = self._buf[s]
        self._buf[s] = none
        self._n = self._n - 1
        return x

    def popleft(self):
        if self._n == 0:
            raise IndexError("pop from an empty deque")
        var x = self._buf[self._head]
        self._buf[self._head] = none
        self._head = (self._head + 1) % len(self._buf)
        self._n = self._n - 1
        return x

    def extend(self, iterable):
        for x in list(iterable):
            self.append(x)
        return none

    def extendleft(self, iterable):
        for x in list(iterable):
            self.appendleft(x)
        return none

    def rotate(self, n=1):
        if self._n == 0:
            return none
        n = n % self._n
        for i in range(n):
            self.appendleft(self.pop())
        return none

    def clear(self):
        self._buf = [none] * 8
        self._head = 0
        self._n = 0
        return none

    def copy(self):
        return deque(self.to_list(), self.maxlen)

    def count(self, x):
        var c = 0
        for y in self.to_list():
            if y == x:
                c = c + 1
        return c

    def index(self, x, start=0, stop=none):
        var items = self.to_list()
        var end = len(items) if stop == none else stop
        for i in range(start, end):
            if items[i] == x:
                return i
        raise ValueError(repr(x) + " is not in deque")

    def insert(self, i, x):
        if self.maxlen != none and self._n == self.maxlen:
            raise IndexError("deque already at its maximum size")
        var items = self.to_list()
        items.insert(i, x)
        self._reset(items)
        return none

    def remove(self, x):
        var items = self.to_list()
        for i in range(len(items)):
            if items[i] == x:
                items.pop(i)
                self._reset(items)
                return none
        raise ValueError(repr(x) + " is not in deque")

    def reverse(self):
        var items = self.to_list()
        items.reverse()
        self._reset(items)
        return none

    def _reset(self, items):
        self.clear()
        for x in items:
            if self._n == len(self._buf):
                self._grow()
            self._buf[self._n] = x
            self._n = self._n + 1

    def to_list(self):
        var cap = len(self._buf)
        return [self._buf[(self._head + i) % cap] for i in range(self._n)]

    def __len__(self):
        return self._n

    def __bool__(self):
        return self._n > 0

    def __getitem__(self, i):
        return self._buf[self._slot(i)]

    def __setitem__(self, i, x):
        self._buf[self._slot(i)] = x

    def __delitem__(self, i):
        var items = self.to_list()
        items.pop(i)
        self._reset(items)

    def __iter__(self):
        return iter(self.to_list())

    def __reversed__(self):
        var items = self.to_list()
        items.reverse()
        return iter(items)

    def __contains__(self, x):
        return x in self.to_list()

    def __eq__(self, other):
        return isinstance(other, deque) and self.to_list() == other.to_list()

    def __ne__(self, other):
        return not self.__eq__(other)

    def __add__(self, other):
        var d = deque(self.to_list(), self.maxlen)
        d.extend(other)
        return d

    def __repr__(self):
        if self.maxlen == none:
            return "deque([" + _reprs(self.to_list()) + "])"
        return "deque([" + _reprs(self.to_list()) + "], maxlen=" + str(self.maxlen) + ")"


# ── dict-like wrappers ───────────────────────────────────────────────────────
class _DictWrapper:
    # The dict protocol over self.data (a Nython dict, ordered)
    def __getitem__(self, k):
        if k in self.data:
            return self.data[k]
        return self.__missing__(k)

    def __missing__(self, k):
        raise KeyError(k)

    def __setitem__(self, k, v):
        self.data[k] = v

    def __delitem__(self, k):
        if not (k in self.data):
            raise KeyError(k)
        del self.data[k]

    def __contains__(self, k):
        return k in self.data

    def __len__(self):
        return len(self.data)

    def __bool__(self):
        return len(self.data) > 0

    def __iter__(self):
        return iter(list(self.data.keys()))

    def __eq__(self, other):
        if isinstance(other, _DictWrapper):
            return self.data == other.data
        return self.data == other

    def __ne__(self, other):
        return not self.__eq__(other)

    def keys(self):
        return self.data.keys()

    def values(self):
        return self.data.values()

    def items(self):
        return self.data.items()

    def get(self, k, default=none):
        if k in self.data:
            return self.data[k]
        return default

    def setdefault(self, k, default=none):
        if not (k in self.data):
            self.data[k] = default
        return self.data[k]

    def pop(self, k, *default):
        if k in self.data:
            var v = self.data[k]
            del self.data[k]
            return v
        if len(default) > 0:
            return default[0]
        raise KeyError(k)

    def popitem(self):
        if len(self.data) == 0:
            raise KeyError("popitem(): dictionary is empty")
        var k = list(self.data.keys())[len(self.data) - 1]
        var v = self.data[k]
        del self.data[k]
        return (k, v)

    def update(self, other=none, **kw):
        if other != none:
            if hasattr(other, "keys"):
                for k in other.keys():
                    self[k] = other[k]
            else:
                for kv in other:
                    self[kv[0]] = kv[1]
        for k in kw:
            self[k] = kw[k]
        return none

    def clear(self):
        self.data = {}
        return none

    def to_dict(self):
        return dict(self.data)


class UserDict(_DictWrapper):
    def __init__(self, data=none, **kw):
        self.data = {}
        self.update(data, **kw)

    def copy(self):
        return UserDict(dict(self.data))

    def __repr__(self):
        return repr(self.data)


class OrderedDict(_DictWrapper):
    def __init__(self, data=none, **kw):
        self.data = {}
        self.update(data, **kw)

    def move_to_end(self, key, last=true):
        if not (key in self.data):
            raise KeyError(key)
        var v = self.data[key]
        del self.data[key]
        if last:
            self.data[key] = v
        else:
            var rest = self.data
            self.data = {}
            self.data[key] = v
            for k in rest:
                self.data[k] = rest[k]
        return none

    def popitem(self, last=true):
        if len(self.data) == 0:
            raise KeyError("dictionary is empty")
        var ks = list(self.data.keys())
        var k = ks[len(ks) - 1] if last else ks[0]
        var v = self.data[k]
        del self.data[k]
        return (k, v)

    def copy(self):
        return OrderedDict(dict(self.data))

    def __eq__(self, other):
        if isinstance(other, OrderedDict):
            return list(self.data.items()) == list(other.data.items())
        if isinstance(other, _DictWrapper):
            return self.data == other.data
        return self.data == other

    def __reversed__(self):
        var ks = list(self.data.keys())
        ks.reverse()
        return iter(ks)

    def __repr__(self):
        if len(self.data) == 0:
            return "OrderedDict()"
        return "OrderedDict(" + repr(self.data) + ")"


class defaultdict(_DictWrapper):
    def __init__(self, default_factory=none, data=none, **kw):
        if default_factory != none and not callable(default_factory):
            raise TypeError("first argument must be callable or None")
        self.default_factory = default_factory
        self.data = {}
        self.update(data, **kw)

    def __missing__(self, k):
        if self.default_factory == none:
            raise KeyError(k)
        var f = self.default_factory
        var v = f()
        self.data[k] = v
        return v

    def copy(self):
        return defaultdict(self.default_factory, dict(self.data))

    def __repr__(self):
        var fname = "None"
        if self.default_factory != none:
            fname = getattr(self.default_factory, "__name__", repr(self.default_factory))
            if fname in ["list", "dict", "set", "int", "float", "str", "tuple"]:
                fname = "<class '" + fname + "'>"
        return "defaultdict(" + fname + ", " + repr(self.data) + ")"


class Counter(_DictWrapper):
    # counts of hashable things; a missing count is 0
    def __init__(self, iterable=none, **kw):
        self.data = {}
        self.update(iterable, **kw)

    def __missing__(self, k):
        return 0

    def update(self, iterable=none, **kw):
        if iterable != none:
            if hasattr(iterable, "keys"):
                for k in iterable.keys():
                    self.data[k] = self.data.get(k, 0) + iterable[k]
            else:
                for x in iterable:
                    self.data[x] = self.data.get(x, 0) + 1
        for k in kw:
            self.data[k] = self.data.get(k, 0) + kw[k]
        return none

    def subtract(self, iterable=none, **kw):
        if iterable != none:
            if hasattr(iterable, "keys"):
                for k in iterable.keys():
                    self.data[k] = self.data.get(k, 0) - iterable[k]
            else:
                for x in iterable:
                    self.data[x] = self.data.get(x, 0) - 1
        for k in kw:
            self.data[k] = self.data.get(k, 0) - kw[k]
        return none

    def most_common(self, n=none):
        # by count, highest first; equal counts keep first-seen order
        var items = list(self.data.items())
        var order = sorted(range(len(items)), key=lambda i: (-items[i][1], i))
        var out = [(items[i][0], items[i][1]) for i in order]
        if n != none:
            return out[0:n]
        return out

    def elements(self):
        var out = []
        for k in self.data:
            for i in range(self.data[k]):
                out.append(k)
        return iter(out)

    def total(self):
        var t = 0
        for k in self.data:
            t = t + self.data[k]
        return t

    def copy(self):
        return Counter(dict(self.data))

    def _positive(self, d):
        var c = Counter()
        for k in d:
            if d[k] > 0:
                c.data[k] = d[k]
        return c

    def __add__(self, other):
        var d = {}
        for k in self.data:
            d[k] = self.data[k]
        for k in other.data:
            d[k] = d.get(k, 0) + other.data[k]
        return self._positive(d)

    def __sub__(self, other):
        var d = {}
        for k in self.data:
            d[k] = self.data[k] - other.data.get(k, 0)
        return self._positive(d)

    def __or__(self, other):
        var d = {}
        for k in self.data:
            d[k] = self.data[k]
        for k in other.data:
            d[k] = max(d.get(k, 0), other.data[k])
        return self._positive(d)

    def __and__(self, other):
        var d = {}
        for k in self.data:
            if k in other.data:
                d[k] = min(self.data[k], other.data[k])
        return self._positive(d)

    def __repr__(self):
        if len(self.data) == 0:
            return "Counter()"
        return "Counter({" + ", ".join([repr(kv[0]) + ": " + repr(kv[1]) for kv in self.most_common()]) + "})"


# ── ChainMap ─────────────────────────────────────────────────────────────────
class ChainMap:
    def __init__(self, *maps):
        self.maps = list(maps) if len(maps) > 0 else [{}]

    def __getitem__(self, k):
        for m in self.maps:
            if k in m:
                return m[k]
        raise KeyError(k)

    def get(self, k, default=none):
        for m in self.maps:
            if k in m:
                return m[k]
        return default

    def __setitem__(self, k, v):
        self.maps[0][k] = v

    def __delitem__(self, k):
        if not (k in self.maps[0]):
            raise KeyError(k)
        del self.maps[0][k]

    def __contains__(self, k):
        for m in self.maps:
            if k in m:
                return true
        return false

    def keys(self):
        var seen = {}
        var out = []
        var rev = list(self.maps)
        rev.reverse()
        for m in rev:
            for k in m:
                if not (k in seen):
                    seen[k] = true
                    out.append(k)
        return out

    def __iter__(self):
        return iter(self.keys())

    def __len__(self):
        return len(self.keys())

    def items(self):
        return [(k, self[k]) for k in self.keys()]

    def values(self):
        return [self[k] for k in self.keys()]

    def new_child(self, m=none):
        return ChainMap(*([m if m != none else {}] + self.maps))

    @property
    def parents(self):
        return ChainMap(*self.maps[1:])

    def __repr__(self):
        return "ChainMap(" + ", ".join([repr(m) for m in self.maps]) + ")"


# ── UserList ─────────────────────────────────────────────────────────────────
class UserList:
    def __init__(self, initlist=none):
        self.data = list(initlist) if initlist != none else []

    def append(self, x):
        self.data.append(x)

    def extend(self, xs):
        for x in xs:
            self.data.append(x)

    def insert(self, i, x):
        self.data.insert(i, x)

    def pop(self, i=-1):
        return self.data.pop(i)

    def remove(self, x):
        self.data.remove(x)

    def index(self, x):
        return self.data.index(x)

    def count(self, x):
        return self.data.count(x)

    def sort(self, key=none, reverse=false):
        self.data = sorted(self.data, key=key, reverse=reverse)

    def reverse(self):
        self.data.reverse()

    def __len__(self):
        return len(self.data)

    def __getitem__(self, i):
        return self.data[i]

    def __setitem__(self, i, v):
        self.data[i] = v

    def __iter__(self):
        return iter(self.data)

    def __contains__(self, x):
        return x in self.data

    def __eq__(self, other):
        if isinstance(other, UserList):
            return self.data == other.data
        return self.data == other

    def __repr__(self):
        return repr(self.data)


# ── namedtuple ───────────────────────────────────────────────────────────────
class _NamedTupleBase:
    # An instance: the values in field order, readable by name and index.
    def __init__(self, *args, **kw):
        var fields = self._fields
        if len(args) > len(fields):
            raise TypeError(self._typename + "() takes " + str(len(fields)) + " positional arguments but " + str(len(args)) + " were given")
        var vals = list(args)
        for i in range(len(args), len(fields)):
            var f = fields[i]
            if f in kw:
                vals.append(kw[f])
            elif f in self._field_defaults:
                vals.append(self._field_defaults[f])
            else:
                raise TypeError(self._typename + "() missing required argument: '" + f + "'")
        for k in kw:
            if not (k in fields):
                raise TypeError(self._typename + "() got an unexpected keyword argument '" + k + "'")
            var at = fields.index(k)
            if at < len(args):
                raise TypeError(self._typename + "() got multiple values for argument '" + k + "'")
        self._values = tuple(vals)
        for i in range(len(fields)):
            setattr(self, fields[i], vals[i])

    def __getitem__(self, i):
        return self._values[i]

    def __len__(self):
        return len(self._values)

    def __iter__(self):
        return iter(list(self._values))

    def __contains__(self, x):
        return x in self._values

    def __eq__(self, other):
        if isinstance(other, _NamedTupleBase):
            return self._values == other._values
        return self._values == other

    def __ne__(self, other):
        return not self.__eq__(other)

    def __lt__(self, other):
        return self._values < (other._values if isinstance(other, _NamedTupleBase) else other)

    def __hash__(self):
        return hash(repr(self._values))

    def __repr__(self):
        var parts = []
        for i in range(len(self._fields)):
            parts.append(self._fields[i] + "=" + repr(self._values[i]))
        return self._typename + "(" + ", ".join(parts) + ")"

    def _asdict(self):
        var d = {}
        for i in range(len(self._fields)):
            d[self._fields[i]] = self._values[i]
        return d

    def _replace(self, **kw):
        var d = self._asdict()
        for k in kw:
            if not (k in d):
                raise ValueError("Got unexpected field names: " + repr([k]))
            d[k] = kw[k]
        return self.__class__(*[d[f] for f in self._fields])

    def count(self, x):
        return list(self._values).count(x)

    def index(self, x):
        return list(self._values).index(x)


def namedtuple(typename, field_names, defaults=none, rename=false, module=none):
    # field_names: a list, or a string "x y" / "x, y"
    var names = field_names
    if isinstance(field_names, "str"):
        names = field_names.replace(",", " ").split()
    names = [str(n) for n in names]
    var seen = {}
    for i in range(len(names)):
        var n = names[i]
        var bad = not n.isidentifier() or n.startswith("_") or n in seen
        if bad and rename:
            names[i] = "_" + str(i)
        elif bad:
            raise ValueError("Invalid field name: " + repr(n))
        seen[names[i]] = true
    var field_defaults = {}
    if defaults != none:
        var dl = list(defaults)
        if len(dl) > len(names):
            raise TypeError("Got more default values than field names")
        for j in range(len(dl)):
            field_defaults[names[len(names) - len(dl) + j]] = dl[j]

    class _NT(_NamedTupleBase):
        pass
    _NT._typename = typename
    _NT._fields = tuple(names)
    _NT._field_defaults = field_defaults

    def _make(iterable):
        return _NT(*list(iterable))
    _NT._make = staticmethod(_make)
    return _NT
