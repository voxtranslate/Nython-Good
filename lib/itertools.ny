# nython: module    (import it by name: it runs in a module scope of its own)
# lib/itertools.ny - Python's itertools: iterator building blocks.
#
#     from itertools import count, chain, groupby, islice, product, tee
#
# infinite        count(start=0, step=1), cycle(iterable), repeat(object[, times])
# terminating     accumulate(iterable[, func, *, initial]), batched(iterable, n),
#                 chain(*iterables), chain.from_iterable(iterable),
#                 compress(data, selectors), dropwhile(pred, iterable),
#                 filterfalse(pred, iterable), groupby(iterable, key=None),
#                 islice(iterable, [start,] stop [, step]), pairwise(iterable),
#                 starmap(func, iterable), takewhile(pred, iterable),
#                 tee(iterable, n=2), zip_longest(*iterables, fillvalue=None)
# combinatoric    product(*iterables, repeat=1), permutations(iterable, r=None),
#                 combinations(iterable, r),
#                 combinations_with_replacement(iterable, r)
#
# Every one is an iterator class, as in CPython: lazy (nothing is read
# from an input before it is needed, and an infinite input is never
# materialised), with Python's argument checking and messages at the call,
# Python's type names (type(chain()).__name__ == "chain") and the reprs
# CPython gives (count(5), repeat('a', 3)). The algorithms are CPython's C
# ones, so the order in which inputs are consumed is the same:
# - groupby's groups share the underlying iterator; advancing the groupby
#   invalidates the previous group, which then yields nothing more.
# - islice stops reading as soon as it reaches stop.
# - tee's iterators share one linked buffer; an item is kept only until
#   every iterator has passed it.
# - product, permutations and combinations read their whole inputs first
#   (as CPython does: they are finite by definition).
#
# The runtime's builtin islice(it, n) / take(n, it) remain available as
# builtins elsewhere; inside a module that imports these names, they are
# Python's.

__all__ = ["accumulate", "batched", "chain", "combinations", "combinations_with_replacement",
           "compress", "count", "cycle", "dropwhile", "filterfalse", "groupby",
           "islice", "pairwise", "permutations", "product", "repeat", "starmap",
           "takewhile", "tee", "zip_longest"]


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


def _pool(x):
    # the whole of an input, for the combinatoric iterators
    return tuple(_iter(x))


# A sentinel no caller can produce: "no value yet".
class _ItertoolsMarker:
    def __repr__(self):
        return "<marker>"

_NO = _ItertoolsMarker()

def _isno(x):
    return isinstance(x, _ItertoolsMarker)


def _as_index(x, what):
    # an int argument (bool counts, as in Python), else Python's TypeError
    if isinstance(x, int):
        return int(x)
    if hasattr(x, "__index__"):
        return x.__index__()
    raise TypeError("'" + _tname(x) + "' object cannot be interpreted as an integer")


def _is_number(x):
    if isinstance(x, (int, float)):
        return true
    if isinstance(x, (str, bytes, bytearray, list, tuple, dict, set, frozenset)):
        return false
    return hasattr(x, "__add__")


# ── infinite iterators ───────────────────────────────────────────────────────
class count:
    "Return a count object whose .__next__() method returns consecutive values."
    def __init__(self, start=0, step=1):
        if not _is_number(start) or not _is_number(step):
            raise TypeError("a number is required")
        self._n = start
        self._step = step

    def __iter__(self):
        return self

    def __next__(self):
        var v = self._n
        self._n = v + self._step
        return v

    def __repr__(self):
        var s = self._step
        if isinstance(s, int) and not isinstance(s, bool) and s == 1:
            return "count(" + repr(self._n) + ")"
        return "count(" + repr(self._n) + ", " + repr(s) + ")"


class cycle:
    "Return elements from the iterable until it is exhausted. Then repeat the sequence indefinitely."
    def __init__(self, iterable):
        self._it = _iter(iterable)
        self._saved = []
        self._i = 0
        self._first = true

    def __iter__(self):
        return self

    def __next__(self):
        if self._first:
            try:
                var v = next(self._it)
                self._saved.append(v)
                return v
            except StopIteration:
                self._first = false
                self._it = none
        if len(self._saved) == 0:
            raise StopIteration
        var w = self._saved[self._i]
        self._i = (self._i + 1) % len(self._saved)
        return w


class repeat:
    "repeat(object [,times]) -> create an iterator which returns the object for the specified number of times.  If not specified, returns the object endlessly."
    def __init__(self, *args, **kwargs):
        var n = len(args)
        var obj = none
        var times = none
        var has_obj = false
        if n > 2:
            raise TypeError("repeat expected at most 2 arguments, got " + str(n))
        if n >= 1:
            obj = args[0]
            has_obj = true
        if n == 2:
            times = args[1]
        for k in kwargs:
            if k == "object" and not has_obj:
                obj = kwargs[k]
                has_obj = true
            elif k == "times" and n < 2:
                times = kwargs[k]
            else:
                raise TypeError("'" + k + "' is an invalid keyword argument for repeat()")
        if not has_obj:
            raise TypeError("repeat() missing required argument 'object' (pos 1)")
        self._obj = obj
        self._left = -1
        if times is not none:
            self._left = _as_index(times, "times")
            if self._left < 0:
                self._left = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._left == 0:
            raise StopIteration
        if self._left > 0:
            self._left -= 1
        return self._obj

    def __length_hint__(self):
        if self._left < 0:
            raise TypeError("len() of unsized object")
        return self._left

    def __repr__(self):
        if self._left < 0:
            return "repeat(" + repr(self._obj) + ")"
        return "repeat(" + repr(self._obj) + ", " + str(self._left) + ")"


# ── terminating iterators ────────────────────────────────────────────────────
class accumulate:
    "Return series of accumulated sums (or other binary function results)."
    def __init__(self, iterable, func=none, initial=none):
        self._it = _iter(iterable)
        self._func = func
        self._total = _NO
        self._initial = initial

    def __iter__(self):
        return self

    def __next__(self):
        if self._initial is not none:
            self._total = self._initial
            self._initial = none
            return self._total
        var v = next(self._it)
        if _isno(self._total):
            self._total = v
        elif self._func is none:
            self._total = self._total + v
        else:
            self._total = self._func(self._total, v)
        return self._total


class batched:
    "Batch data into tuples of length n. The last batch may be shorter."
    def __init__(self, iterable, n):
        var size = _as_index(n, "n")
        if size < 1:
            raise ValueError("n must be at least one")
        self._it = _iter(iterable)
        self._n = size

    def __iter__(self):
        return self

    def __next__(self):
        if self._it is none:
            raise StopIteration
        var out = []
        var it = self._it
        while len(out) < self._n:
            try:
                out.append(next(it))
            except StopIteration:
                break
        if len(out) == 0:
            self._it = none
            raise StopIteration
        return tuple(out)


class chain:
    "Return a chain object whose .__next__() method returns elements from the first iterable until it is exhausted, then elements from the next iterable, until all of the iterables are exhausted."
    def __init__(self, *iterables):
        self._source = _iter(iterables)
        self._active = none

    @classmethod
    def from_iterable(cls, iterable):
        "Alternative chain() constructor taking a single iterable argument that evaluates lazily."
        var c = chain()
        c._source = _iter(iterable)
        return c

    def __iter__(self):
        return self

    def __next__(self):
        while true:
            if self._active is none:
                if self._source is none:
                    raise StopIteration
                try:
                    self._active = _iter(next(self._source))
                except StopIteration:
                    self._source = none
                    raise StopIteration
            try:
                return next(self._active)
            except StopIteration:
                self._active = none


class compress:
    "Return data elements corresponding to true selector elements."
    def __init__(self, data, selectors):
        self._data = _iter(data)
        self._sel = _iter(selectors)

    def __iter__(self):
        return self

    def __next__(self):
        while true:
            var d = next(self._data)
            var s = next(self._sel)
            if s:
                return d


class dropwhile:
    "Drop items from the iterable while predicate(item) is true."
    def __init__(self, predicate, iterable):
        self._pred = predicate
        self._it = _iter(iterable)
        self._dropping = true

    def __iter__(self):
        return self

    def __next__(self):
        var v = next(self._it)
        if self._dropping:
            while self._pred(v):
                v = next(self._it)
            self._dropping = false
        return v


class takewhile:
    "Return successive entries from an iterable as long as the predicate evaluates to true for each entry."
    def __init__(self, predicate, iterable):
        self._pred = predicate
        self._it = _iter(iterable)
        self._stop = false

    def __iter__(self):
        return self

    def __next__(self):
        if self._stop:
            raise StopIteration
        var v = next(self._it)
        if self._pred(v):
            return v
        self._stop = true
        raise StopIteration


class filterfalse:
    "Return those items of iterable for which function(item) is false. If function is None, return the items that are false."
    def __init__(self, function, iterable):
        self._f = function
        self._it = _iter(iterable)

    def __iter__(self):
        return self

    def __next__(self):
        while true:
            var v = next(self._it)
            if self._f is none:
                if not v:
                    return v
            elif not self._f(v):
                return v


class groupby:
    "make an iterator that returns consecutive keys and groups from the iterable"
    # CPython's algorithm: currkey/currvalue are the item read last;
    # tgtkey the key of the group handed out last. A group reads through
    # the same iterator and is valid only while it is the current one.
    def __init__(self, iterable, key=none):
        self._it = _iter(iterable)
        self._keyfunc = key
        self._tgtkey = _NO
        self._currkey = _NO
        self._currvalue = _NO
        self._currgrouper = none

    def __iter__(self):
        return self

    def _step(self):
        var v = next(self._it)
        var k = v
        if self._keyfunc is not none:
            k = self._keyfunc(v)
        self._currvalue = v
        self._currkey = k

    def __next__(self):
        self._currgrouper = none
        # skip to the next group
        while true:
            if _isno(self._currkey):
                pass
            elif _isno(self._tgtkey):
                break
            elif not (self._tgtkey == self._currkey):
                break
            self._step()
        self._tgtkey = self._currkey
        var g = _groupby_grouper(self, self._tgtkey)
        self._currgrouper = g
        return (self._currkey, g)


class _groupby_grouper:
    def __init__(self, parent, tgtkey):
        self._parent = parent
        self._tgtkey = tgtkey

    def __iter__(self):
        return self

    def __next__(self):
        var gb = self._parent
        if gb._currgrouper is none or id(gb._currgrouper) != id(self):
            raise StopIteration
        if _isno(gb._currvalue):
            gb._step()
        if not (self._tgtkey == gb._currkey):
            raise StopIteration
        var r = gb._currvalue
        gb._currvalue = _NO
        return r


class islice:
    """islice(iterable, stop) --> islice object
islice(iterable, start, stop[, step]) --> islice object

Return an iterator whose next() method returns selected values from an
iterable.  If start is specified, will skip all preceding elements;
otherwise, start defaults to zero.  Step defaults to one.  If
specified as another value, step determines how many values are
skipped between successive calls.  Works like a slice() on a list
but returns an iterator."""
    def __init__(self, *args):
        var n = len(args)
        if n < 2:
            raise TypeError("islice expected at least 2 arguments, got " + str(n))
        if n > 4:
            raise TypeError("islice expected at most 4 arguments, got " + str(n))
        var start = 0
        var stop = -1
        var step = 1
        if n == 2:
            if args[1] is not none:
                stop = _islice_arg(args[1], "Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize.")
        else:
            if args[1] is not none:
                start = _islice_arg(args[1], "Indices for islice() must be None or an integer: 0 <= x <= sys.maxsize.")
            if args[2] is not none:
                stop = _islice_arg(args[2], "Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize.")
            if n == 4 and args[3] is not none:
                step = _islice_arg(args[3], "Step for islice() must be a positive integer or None.")
                if step == 0:
                    raise ValueError("Step for islice() must be a positive integer or None.")
        self._it = _iter(args[0])
        self._next = start
        self._stop = stop
        self._step = step
        self._cnt = 0

    def __iter__(self):
        return self

    def __next__(self):
        var it = self._it
        if it is none:
            raise StopIteration
        var stop = self._stop
        try:
            while self._cnt < self._next:
                next(it)
                self._cnt += 1
            if stop != -1 and self._cnt >= stop:
                self._it = none
                raise StopIteration
            var item = next(it)
        except StopIteration:
            self._it = none
            raise StopIteration
        self._cnt += 1
        self._next += self._step
        if stop != -1 and self._next > stop:
            self._next = stop
        return item


def _islice_arg(x, msg):
    if isinstance(x, int) or hasattr(x, "__index__"):
        var v = x if isinstance(x, int) else x.__index__()
        if v < 0:
            raise ValueError(msg)
        return int(v)
    raise ValueError(msg)


class pairwise:
    "Return an iterator of overlapping pairs taken from the input iterator."
    def __init__(self, iterable):
        self._it = _iter(iterable)
        self._old = _NO

    def __iter__(self):
        return self

    def __next__(self):
        var it = self._it
        if it is none:
            raise StopIteration
        try:
            if _isno(self._old):
                self._old = next(it)
            var nv = next(it)
        except StopIteration:
            self._it = none
            self._old = _NO
            raise StopIteration
        var pair = (self._old, nv)
        self._old = nv
        return pair


class starmap:
    "Return an iterator whose values are returned from the function evaluated with an argument tuple taken from the given sequence."
    def __init__(self, function, iterable):
        self._f = function
        self._it = _iter(iterable)

    def __iter__(self):
        return self

    def __next__(self):
        var args = next(self._it)
        return self._f(*args)


# tee: the iterators share a linked list of items; each node is read from
# the source once, by whichever iterator gets there first.
class _tee_link:
    def __init__(self):
        self.value = none
        self.nxt = none     # the next link once this one is filled


class _tee_source:
    def __init__(self, it):
        self.it = it


class _tee:
    "Iterator wrapped to make it copyable."
    def __init__(self, source, link):
        self._source = source
        self._link = link

    def __iter__(self):
        return self

    def __next__(self):
        var link = self._link
        if link.nxt is none:
            var v = next(self._source.it)    # StopIteration ends every copy
            link.value = v
            link.nxt = _tee_link()
        self._link = link.nxt
        return link.value

    def __copy__(self):
        return _tee(self._source, self._link)


def tee(iterable, n=2):
    "Returns a tuple of n independent iterators."
    var k = _as_index(n, "n")
    if k < 0:
        raise ValueError("n must be >= 0")
    if k == 0:
        return ()
    # an iterator that can copy itself (a tee iterator) is used as it is
    var it = _iter(iterable)
    var first = it
    if not hasattr(it, "__copy__"):
        first = _tee(_tee_source(it), _tee_link())
    var out = [first]
    for i in range(k - 1):
        out.append(first.__copy__())
    return tuple(out)


class zip_longest:
    "Return a zip_longest object whose .__next__() method returns a tuple where the i-th element comes from the i-th iterable argument.  The .__next__() method continues until the longest iterable in the argument sequence is exhausted and then it raises StopIteration.  When the shorter iterables are exhausted, the fillvalue is substituted in their place.  The fillvalue defaults to None or can be specified by a keyword argument."
    def __init__(self, *iterables, **kwargs):
        var fill = none
        for k in kwargs:
            if k != "fillvalue":
                raise TypeError("zip_longest() got an unexpected keyword argument '" + k + "'")
            fill = kwargs[k]
        self._its = [_iter(x) for x in iterables]
        self._active = len(self._its)
        self._fill = fill

    def __iter__(self):
        return self

    def __next__(self):
        if self._active == 0:
            raise StopIteration
        var out = []
        var its = self._its
        for i in range(len(its)):
            var it = its[i]
            if it is none:
                out.append(self._fill)
                continue
            try:
                out.append(next(it))
            except StopIteration:
                its[i] = none
                self._active -= 1
                if self._active == 0:
                    raise StopIteration
                out.append(self._fill)
        return tuple(out)


# ── combinatoric iterators ───────────────────────────────────────────────────
class product:
    "Cartesian product of input iterables.  Equivalent to nested for-loops."
    def __init__(self, *iterables, **kwargs):
        var rep = 1
        for k in kwargs:
            if k != "repeat":
                raise TypeError("product() got an unexpected keyword argument '" + k + "'")
            rep = _as_index(kwargs[k], "repeat")
        if rep < 0:
            raise ValueError("repeat argument cannot be negative")
        var pools = [_pool(x) for x in iterables]
        var all_pools = []
        for r in range(rep):
            for p in pools:
                all_pools.append(p)
        self._pools = all_pools
        self._indices = none
        self._done = false
        for p in all_pools:
            if len(p) == 0:
                self._done = true

    def __iter__(self):
        return self

    def __next__(self):
        if self._done:
            raise StopIteration
        var pools = self._pools
        var n = len(pools)
        if self._indices is none:
            self._indices = [0] * n
            return tuple([p[0] for p in pools])
        var idx = self._indices
        # odometer: advance the rightmost index that can move
        var i = n - 1
        while i >= 0:
            idx[i] += 1
            if idx[i] < len(pools[i]):
                break
            idx[i] = 0
            i -= 1
        if i < 0:
            self._done = true
            raise StopIteration
        return tuple([pools[j][idx[j]] for j in range(n)])


class permutations:
    "Return successive r-length permutations of elements in the iterable."
    def __init__(self, iterable, r=none):
        var pool = _pool(iterable)
        var n = len(pool)
        var rr = n
        if r is not none:
            if isinstance(r, bool) or not isinstance(r, int):
                raise TypeError("Expected int as r")
            rr = r
        if rr < 0:
            raise ValueError("r must be non-negative")
        self._pool = pool
        self._n = n
        self._r = rr
        self._indices = list(range(n))
        self._cycles = list(range(n, n - rr, -1))
        self._started = false
        self._done = rr > n

    def __iter__(self):
        return self

    def __next__(self):
        if self._done:
            raise StopIteration
        var pool = self._pool
        var r = self._r
        var indices = self._indices
        if not self._started:
            self._started = true
            return tuple([pool[i] for i in indices[:r]])
        if self._n == 0 or r == 0:
            self._done = true
            raise StopIteration
        var cycles = self._cycles
        var n = self._n
        var i = r - 1
        while i >= 0:
            cycles[i] -= 1
            if cycles[i] == 0:
                var moved = indices[i]
                var j = i
                while j < n - 1:
                    indices[j] = indices[j + 1]
                    j += 1
                indices[n - 1] = moved
                cycles[i] = n - i
            else:
                var k = cycles[i]
                var tmp = indices[i]
                indices[i] = indices[n - k]
                indices[n - k] = tmp
                return tuple([pool[q] for q in indices[:r]])
            i -= 1
        self._done = true
        raise StopIteration


class combinations:
    "Return successive r-length combinations of elements in the iterable."
    def __init__(self, iterable, r):
        if isinstance(r, bool) or not isinstance(r, int):
            r = _as_index(r, "r")
        if r < 0:
            raise ValueError("r must be non-negative")
        self._pool = _pool(iterable)
        self._r = r
        self._indices = list(range(r))
        self._started = false
        self._done = r > len(self._pool)

    def __iter__(self):
        return self

    def __next__(self):
        if self._done:
            raise StopIteration
        var pool = self._pool
        var r = self._r
        var indices = self._indices
        if not self._started:
            self._started = true
            return tuple([pool[i] for i in indices])
        var n = len(pool)
        var i = r - 1
        while i >= 0 and indices[i] == i + n - r:
            i -= 1
        if i < 0:
            self._done = true
            raise StopIteration
        indices[i] += 1
        var j = i + 1
        while j < r:
            indices[j] = indices[j - 1] + 1
            j += 1
        return tuple([pool[q] for q in indices])


class combinations_with_replacement:
    "Return successive r-length combinations of elements in the iterable allowing individual elements to have successive repeats."
    def __init__(self, iterable, r):
        if isinstance(r, bool) or not isinstance(r, int):
            r = _as_index(r, "r")
        if r < 0:
            raise ValueError("r must be non-negative")
        self._pool = _pool(iterable)
        self._r = r
        self._indices = [0] * r
        self._started = false
        self._done = len(self._pool) == 0 and r > 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._done:
            raise StopIteration
        var pool = self._pool
        var r = self._r
        var indices = self._indices
        if not self._started:
            self._started = true
            return tuple([pool[i] for i in indices])
        var n = len(pool)
        var i = r - 1
        while i >= 0 and indices[i] == n - 1:
            i -= 1
        if i < 0:
            self._done = true
            raise StopIteration
        var v = indices[i] + 1
        var j = i
        while j < r:
            indices[j] = v
            j += 1
        return tuple([pool[q] for q in indices])
