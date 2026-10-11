# nython: module    (import it by name: it runs in a module scope of its own)
# lib/weakref.ny - Python's weakref: references that do not keep their
# object alive.
#
#     import weakref
#     r = weakref.ref(obj)          # r() is obj, or None once obj is gone
#     cache = weakref.WeakValueDictionary()
#     weakref.finalize(obj, cleanup, path)
#
# Memory is reclaimed by reference counting plus a cycle collector on both
# engines (GC_NOTES.md): `del x` of the last reference frees the object at
# once, and gc_collect() frees unreachable cycles. Callbacks run at the next
# statement boundary after the object is freed (as __del__ does), not inside
# the statement that freed it - so `del x; print(called)` sees the call.
#
# ref(object[, callback])   r() gives the object or None; callback(r) is
#                           called when the object dies (most recently made
#                           reference first, as Python), unless r died
#                           first; ref(o) is ref(o) when no callback is
#                           given; hash(r) is hash(object) (kept after it
#                           dies; TypeError "weak object has gone away" if
#                           never hashed); r1 == r2 compares the objects
#                           while both live, else identity; __callback__;
#                           subclassable (KeyedRef, WeakMethod)
# ReferenceType             = ref
# proxy(object[, callback]) ProxyType / CallableProxyType: attribute access,
#                           calls, operators, len/iter/indexing forwarded;
#                           ReferenceError("weakly-referenced object no
#                           longer exists") once it is gone; unhashable
# ProxyTypes                (ProxyType, CallableProxyType)
# getweakrefcount(object)   the live references and proxies to it
# getweakrefs(object)       the list of them
# WeakMethod(method[, callback])   a ref to a bound method that is dead when
#                           its object is (calling it gives the bound method)
# WeakValueDictionary       values held weakly: an entry goes when its value
#                           dies; the dict API (get, setdefault, pop,
#                           popitem, update, copy, items/keys/values,
#                           itervaluerefs/valuerefs, | and |=)
# WeakKeyDictionary         keys held weakly (compared by ==, as Python):
#                           the dict API plus keyrefs()
# WeakSet                   members held weakly: the set API (add, discard,
#                           remove, pop, clear, copy, update, the operators
#                           and comparisons, isdisjoint, issubset ...)
# KeyedRef(ob, callback, key)   a ref carrying .key
# finalize(obj, func, /, *args, **kwargs)   calls func(*args, **kwargs)
#                           once: when obj dies, when the finalizer is
#                           called, or at program exit if .atexit (the
#                           default; newest first) - .alive, .detach(),
#                           .peek(), .atexit
#
# Only instances of classes can be weakly referenced (as in Python: not an
# int, str, list, tuple or dict); functions, methods and classes cannot be
# here either - a WeakMethod holds its function strongly and is dead when
# its object is, and WeakKeyDictionary / WeakSet keys must be instances.
# Not here: a callback is not run when the referent and the reference die
# together in one garbage cycle (Python skips it; here it may run), and
# references are not made to the frames, generators or sets Python allows.

__all__ = ["ref", "proxy", "getweakrefcount", "getweakrefs",
           "WeakKeyDictionary", "ReferenceType", "ProxyType",
           "CallableProxyType", "ProxyTypes", "WeakValueDictionary",
           "WeakSet", "WeakMethod", "finalize"]

# The engines' weak reference (taken now: an importer's `import weakref`
# rebinds the global name to this module).
_wr = weakref


def _hexid(o):
    return "0x" + format(id(o), "x")


def _tname(o):
    if o is None:
        return "NoneType"
    return type(o).__name__


# ── who refers to what ──────────────────────────────────────────────────────
# Per referent: one engine reference with a callback (the probe), and engine
# references to the ref / proxy objects made for it, oldest first. When the
# referent dies the probe's callback calls theirs, newest first.
class _Referents:
    def __init__(self, serial, ob):
        self.serial = serial
        self.target = _wr(ob)
        self.probe = _wr(ob, _probe_callback(serial))
        self.refs = []          # engine weak references to our ref objects
        self.basic = None       # engine weak reference to ref(ob) without callback


_by_id = {}          # id(ob) -> [_Referents]  (ids can repeat: checked)
_by_serial = {}      # serial -> id(ob)
_serial = [0]


def _probe_callback(serial):
    def fire(_engine_ref):
        _referent_died(serial)
    return fire


def _entry_for(ob, make):
    var k = id(ob)
    var lst = _by_id.get(k)
    if lst is not None:
        for e in lst:
            if e.target() is ob:
                return e
    if not make:
        return None
    _serial[0] = _serial[0] + 1
    var e = _Referents(_serial[0], ob)
    if lst is None:
        lst = []
        _by_id[k] = lst
    lst.append(e)
    _by_serial[e.serial] = k
    return e


def _referent_died(serial):
    var k = _by_serial.pop(serial, None)
    if k is None:
        return
    var lst = _by_id.get(k)
    var entry = None
    if lst is not None:
        var keep = []
        for e in lst:
            if e.serial == serial:
                entry = e
            else:
                keep.append(e)
        if len(keep) == 0:
            _by_id.pop(k, None)
        else:
            _by_id[k] = keep
    if entry is None:
        return
    var i = len(entry.refs) - 1
    while i >= 0:
        var r = entry.refs[i]()
        if r is not None:
            r._ny_dead()
        i -= 1


def _prune(e):
    # references that died stop being listed (a long-lived object given many
    # short-lived references)
    if len(e.refs) >= 16:
        e.refs = [w for w in e.refs if w() is not None]


def _live_refs(ob):
    var e = _entry_for(ob, False)
    var out = []
    if e is None:
        return out
    for w in e.refs:
        var r = w()
        if r is not None and r._ny_alive():
            out.append(r)
    return out


# ── ref ─────────────────────────────────────────────────────────────────────
class ref:
    """ref(object[, callback]) -> weak reference to the object"""

    def __new__(cls, ob, callback=None, *args, **kwargs):
        if callback is None and cls is ref:
            var e0 = _entry_for(ob, False)
            if e0 is not None and e0.basic is not None:
                var b = e0.basic()
                if b is not None and b._ny_alive():
                    return b
        var w = _wr(ob)          # TypeError for what cannot be referenced
        var me = object.__new__(cls)
        object.__setattr__(me, "_ny_w", w)
        object.__setattr__(me, "_ny_cb", callback)
        object.__setattr__(me, "_ny_hash", None)
        object.__setattr__(me, "_ny_dead_seen", False)
        var e = _entry_for(ob, True)
        _prune(e)
        e.refs.append(_wr(me))
        if callback is None and cls is ref:
            e.basic = _wr(me)
        return me

    def __init__(self, ob, callback=None, *args, **kwargs):
        pass

    def __call__(self):
        return self._ny_w()

    def _ny_alive(self):
        return self._ny_w() is not None

    def _ny_dead(self):
        # the referent died: the callback, once
        if self._ny_dead_seen:
            return
        object.__setattr__(self, "_ny_dead_seen", True)
        var cb = self._ny_cb
        object.__setattr__(self, "_ny_cb", None)
        if cb is not None:
            try:
                cb(self)
            except Exception as exc:
                import sys
                sys.stderr.write("Exception ignored in: " + repr(cb) + "\n" +
                                 type(exc).__name__ + ": " + str(exc) + "\n")

    @property
    def __callback__(self):
        if self._ny_w() is None:
            return None
        return self._ny_cb

    def __hash__(self):
        if self._ny_hash is not None:
            return self._ny_hash
        var o = self._ny_w()
        if o is None:
            raise TypeError("weak object has gone away")
        var h = hash(o)
        object.__setattr__(self, "_ny_hash", h)
        return h

    def __eq__(self, other):
        if not isinstance(other, ref):
            return NotImplemented
        var a = self._ny_w()
        var b = other._ny_w()
        if a is None or b is None:
            return self is other
        return a == b

    def __ne__(self, other):
        if not isinstance(other, ref):
            return NotImplemented
        var a = self._ny_w()
        var b = other._ny_w()
        if a is None or b is None:
            return self is not other
        return a != b

    def __repr__(self):
        var o = self._ny_w()
        if o is None:
            return "<weakref at " + _hexid(self) + "; dead>"
        return "<weakref at " + _hexid(self) + "; to '" + _tname(o) + "' at " + _hexid(o) + ">"

    @classmethod
    def __class_getitem__(cls, item):
        return cls


ReferenceType = ref


class KeyedRef(ref):
    """ref with associated data, as WeakValueDictionary keeps them: .key"""

    def __new__(type_, ob, callback, key):
        var me = ref.__new__(type_, ob, callback)
        object.__setattr__(me, "key", key)
        return me

    def __init__(self, ob, callback, key):
        pass


class WeakMethod(ref):
    """
    A custom `weakref.ref` subclass which simulates a weak reference to
    a bound method, working around the lifetime problem of bound methods.
    """

    def __new__(cls, meth, callback=None):
        var obj = None
        var func = None
        try:
            obj = meth.__self__
            func = meth.__func__
        except AttributeError:
            raise TypeError("argument should be a bound method, not " + repr(_tname(meth))) from None
        var me = ref.__new__(cls, obj, callback)
        object.__setattr__(me, "_func", func)
        object.__setattr__(me, "_name", getattr(func, "__name__", None))
        return me

    def __init__(self, meth, callback=None):
        pass

    def __call__(self):
        var obj = self._ny_w()
        if obj is None:
            return None
        var m = getattr(obj, self._name, None) if self._name is not None else None
        if m is not None and getattr(m, "__func__", None) is self._func:
            return m
        if m is not None and self._name is not None:
            return m
        return None

    def __eq__(self, other):
        if isinstance(other, WeakMethod):
            if not self._ny_alive() or not other._ny_alive():
                return self is other
            return self._ny_w() is other._ny_w() and self._func is other._func
        return NotImplemented

    def __ne__(self, other):
        if isinstance(other, WeakMethod):
            if not self._ny_alive() or not other._ny_alive():
                return self is not other
            return not (self._ny_w() is other._ny_w() and self._func is other._func)
        return NotImplemented

    def __hash__(self):
        return ref.__hash__(self)


# ── proxies ─────────────────────────────────────────────────────────────────
_DEAD = "weakly-referenced object no longer exists"


class ProxyType:
    """A proxy: the object's attributes, operators and protocols, while it
    lives; ReferenceError after."""

    def __init__(self, ob, callback=None):
        object.__setattr__(self, "_ny_cb", callback)
        object.__setattr__(self, "_ny_dead_seen", False)
        object.__setattr__(self, "_ny_w", _wr(ob))
        var e = _entry_for(ob, True)
        _prune(e)
        e.refs.append(_wr(self))

    def _ny_alive(self):
        return self._ny_w() is not None

    def _ny_dead(self):
        if self._ny_dead_seen:
            return
        object.__setattr__(self, "_ny_dead_seen", True)
        var cb = self._ny_cb
        object.__setattr__(self, "_ny_cb", None)
        if cb is not None:
            try:
                cb(self)
            except Exception as exc:
                import sys
                sys.stderr.write("Exception ignored in: " + repr(cb) + "\n" +
                                 type(exc).__name__ + ": " + str(exc) + "\n")

    def _ny_get(self):
        var o = self._ny_w()
        if o is None:
            raise ReferenceError(_DEAD)
        return o

    def __getattr__(self, name):
        return getattr(self._ny_get(), name)

    def __setattr__(self, name, value):
        setattr(self._ny_get(), name, value)

    def __delattr__(self, name):
        delattr(self._ny_get(), name)

    def __repr__(self):
        var o = self._ny_w()
        if o is None:
            return "<weakproxy at " + _hexid(self) + "; dead>"
        return "<weakproxy at " + _hexid(self) + "; to '" + _tname(o) + "' at " + _hexid(o) + ">"

    def __str__(self):
        return str(self._ny_get())

    def __bytes__(self):
        return bytes(self._ny_get())

    def __hash__(self):
        raise TypeError("unhashable type: 'weakref.ProxyType'")

    def __bool__(self):
        return bool(self._ny_get())

    def __len__(self):
        return len(self._ny_get())

    def __iter__(self):
        return iter(self._ny_get())

    def __next__(self):
        return next(self._ny_get())

    def __reversed__(self):
        return reversed(self._ny_get())

    def __contains__(self, x):
        return x in self._ny_get()

    def __getitem__(self, k):
        return self._ny_get()[k]

    def __setitem__(self, k, v):
        self._ny_get()[k] = v

    def __delitem__(self, k):
        del self._ny_get()[k]

    def __eq__(self, other):
        return self._ny_get() == _unproxy(other)

    def __ne__(self, other):
        return self._ny_get() != _unproxy(other)

    def __lt__(self, other):
        return self._ny_get() < _unproxy(other)

    def __le__(self, other):
        return self._ny_get() <= _unproxy(other)

    def __gt__(self, other):
        return self._ny_get() > _unproxy(other)

    def __ge__(self, other):
        return self._ny_get() >= _unproxy(other)

    def __add__(self, other):
        return self._ny_get() + _unproxy(other)

    def __radd__(self, other):
        return _unproxy(other) + self._ny_get()

    def __sub__(self, other):
        return self._ny_get() - _unproxy(other)

    def __rsub__(self, other):
        return _unproxy(other) - self._ny_get()

    def __mul__(self, other):
        return self._ny_get() * _unproxy(other)

    def __rmul__(self, other):
        return _unproxy(other) * self._ny_get()

    def __truediv__(self, other):
        return self._ny_get() / _unproxy(other)

    def __rtruediv__(self, other):
        return _unproxy(other) / self._ny_get()

    def __floordiv__(self, other):
        return self._ny_get() // _unproxy(other)

    def __rfloordiv__(self, other):
        return _unproxy(other) // self._ny_get()

    def __mod__(self, other):
        return self._ny_get() % _unproxy(other)

    def __rmod__(self, other):
        return _unproxy(other) % self._ny_get()

    def __pow__(self, other):
        return self._ny_get() ** _unproxy(other)

    def __rpow__(self, other):
        return _unproxy(other) ** self._ny_get()

    def __and__(self, other):
        return self._ny_get() & _unproxy(other)

    def __or__(self, other):
        return self._ny_get() | _unproxy(other)

    def __xor__(self, other):
        return self._ny_get() ^ _unproxy(other)

    def __lshift__(self, other):
        return self._ny_get() << _unproxy(other)

    def __rshift__(self, other):
        return self._ny_get() >> _unproxy(other)

    def __neg__(self):
        return -self._ny_get()

    def __pos__(self):
        return +self._ny_get()

    def __abs__(self):
        return abs(self._ny_get())

    def __invert__(self):
        return ~self._ny_get()

    def __int__(self):
        return int(self._ny_get())

    def __float__(self):
        return float(self._ny_get())

    def __index__(self):
        return self._ny_get().__index__()

    def __enter__(self):
        return self._ny_get().__enter__()

    def __exit__(self, *a):
        return self._ny_get().__exit__(*a)


class CallableProxyType(ProxyType):
    """A proxy of a callable object."""

    def __call__(self, *args, **kwargs):
        return self._ny_get()(*args, **kwargs)


ProxyTypes = (ProxyType, CallableProxyType)


def _unproxy(x):
    if isinstance(x, ProxyType):
        return x._ny_get()
    return x


def proxy(ob, callback=None):
    """proxy(object[, callback]) -- create a proxy object that weakly
    references 'object'.

    'callback', if given, is called with a reference to the
    proxy when 'object' is about to be finalized."""
    if callable(ob):
        return CallableProxyType(ob, callback)
    return ProxyType(ob, callback)


def getweakrefcount(ob):
    """Return the number of weak references to 'object'."""
    try:
        return len(_live_refs(ob))
    except Exception:
        return 0


def getweakrefs(ob):
    """Return a list of all weak reference objects pointing to 'object'."""
    try:
        return _live_refs(ob)
    except Exception:
        return []


# ── WeakValueDictionary ─────────────────────────────────────────────────────
def _value_remover(selfref):
    def remove(wr):
        var me = selfref()
        if me is not None:
            var cur = me.data.get(wr.key)
            if cur is wr:
                del me.data[wr.key]
    return remove


class WeakValueDictionary:
    """Mapping class that references values weakly.

    Entries in the dictionary will be discarded when no strong
    reference to the value exists anymore
    """

    def __init__(self, other=(), **kw):
        self.data = {}
        self._remove = _value_remover(ref(self))
        self.update(other, **kw)

    def __getitem__(self, key):
        var o = self.data[key]()
        if o is None:
            raise KeyError(key)
        return o

    def __delitem__(self, key):
        del self.data[key]

    def __len__(self):
        var n = 0
        for wr in list(self.data.values()):
            if wr() is not None:
                n += 1
        return n

    def __contains__(self, key):
        var wr = self.data.get(key)
        if wr is None:
            return False
        return wr() is not None

    def __repr__(self):
        return "<WeakValueDictionary at " + _hexid(self) + ">"

    def __setitem__(self, key, value):
        self.data[key] = KeyedRef(value, self._remove, key)

    def copy(self):
        var dup = WeakValueDictionary()
        for pair in list(self.data.items()):
            var o = pair[1]()
            if o is not None:
                dup[pair[0]] = o
        return dup

    def __copy__(self):
        return self.copy()

    def __deepcopy__(self, memo):
        from copy import deepcopy
        var dup = self.__class__()
        for pair in list(self.data.items()):
            var o = pair[1]()
            if o is not None:
                dup[deepcopy(pair[0], memo)] = o
        return dup

    def get(self, key, default=None):
        var wr = self.data.get(key)
        if wr is None:
            return default
        var o = wr()
        if o is None:
            # This should only happen
            return default
        return o

    def items(self):
        var out = []
        for pair in list(self.data.items()):
            var v = pair[1]()
            if v is not None:
                out.append((pair[0], v))
        return out

    def keys(self):
        var out = []
        for pair in list(self.data.items()):
            if pair[1]() is not None:
                out.append(pair[0])
        return out

    def __iter__(self):
        return iter(self.keys())

    def itervaluerefs(self):
        """Return an iterator that yields the weak references to the values.

        The references are not guaranteed to be 'live' at the time
        they are used, so the result of calling the references needs
        to be checked before being used.  This can be used to avoid
        creating references that will cause the garbage collector to
        keep the values around longer than needed.

        """
        return iter(list(self.data.values()))

    def values(self):
        var out = []
        for wr in list(self.data.values()):
            var o = wr()
            if o is not None:
                out.append(o)
        return out

    def popitem(self):
        while True:
            if len(self.data) == 0:
                raise KeyError("popitem(): dictionary is empty")
            var key = list(self.data.keys())[-1]
            var wr = self.data.pop(key)
            var o = wr()
            if o is not None:
                return (key, o)

    def pop(self, key, *args):
        var o = None
        try:
            o = self.data.pop(key)()
        except KeyError:
            o = None
        if o is None:
            if args:
                return args[0]
            raise KeyError(key)
        return o

    def setdefault(self, key, default=None):
        var o = None
        try:
            o = self.data[key]()
        except KeyError:
            o = None
        if o is None:
            self.data[key] = KeyedRef(default, self._remove, key)
            return default
        return o

    def update(self, other=None, **kwargs):
        var d = self.data
        if other is not None:
            if hasattr(other, "items"):
                for pair in list(other.items()):
                    d[pair[0]] = KeyedRef(pair[1], self._remove, pair[0])
            else:
                for pair in other:
                    d[pair[0]] = KeyedRef(pair[1], self._remove, pair[0])
        for k in kwargs:
            d[k] = KeyedRef(kwargs[k], self._remove, k)

    def valuerefs(self):
        """Return a list of weak references to the values.

        The references are not guaranteed to be 'live' at the time
        they are used, so the result of calling the references needs
        to be checked before being used.  This can be used to avoid
        creating references that will cause the garbage collector to
        keep the values around longer than needed.

        """
        return list(self.data.values())

    def __ior__(self, other):
        self.update(other)
        return self

    def __or__(self, other):
        if isinstance(other, dict) or isinstance(other, WeakValueDictionary):
            var c = self.copy()
            c.update(other)
            return c
        return NotImplemented

    def __ror__(self, other):
        if isinstance(other, dict) or isinstance(other, WeakValueDictionary):
            var c = self.__class__()
            c.update(other)
            c.update(self)
            return c
        return NotImplemented

    def __eq__(self, other):
        if isinstance(other, WeakValueDictionary):
            return dict(self.items()) == dict(other.items())
        if isinstance(other, dict):
            return dict(self.items()) == other
        return NotImplemented


# ── WeakKeyDictionary ───────────────────────────────────────────────────────
# Keys compare by == and hash() (as Python's, whose keys are references
# hashing and comparing as their objects): entries in insertion order, and
# an index of them by the key's hash.
def _key_remover(selfref):
    def remove(k):
        var me = selfref()
        if me is not None:
            me._drop_ref(k)
    return remove


class WeakKeyDictionary:
    """ Mapping class that references keys weakly.

    Entries in the dictionary will be discarded when there is no
    longer a strong reference to the key. This can be used to
    associate additional data with an object owned by other parts of
    an application without adding attributes to those objects. This
    can be especially useful with objects that override attribute
    accesses.
    """

    def __init__(self, dict=None):
        self._entries = {}     # serial -> [ref, value, hash]
        self._index = {}       # hash -> [serial, ...]
        self._next = 0
        self._remove = _key_remover(ref(self))
        if dict is not None:
            self.update(dict)

    def _find(self, key):
        var h = hash(key)
        var bucket = self._index.get(h)
        if bucket is None:
            return None
        for s in bucket:
            var e = self._entries[s]
            var k = e[0]()
            if k is not None and (k is key or k == key):
                return s
        return None

    def _drop(self, s):
        var e = self._entries.pop(s, None)
        if e is None:
            return
        var bucket = self._index.get(e[2])
        if bucket is not None:
            if s in bucket:
                bucket.remove(s)
            if len(bucket) == 0:
                self._index.pop(e[2], None)

    def _drop_ref(self, r):
        for s in list(self._entries.keys()):
            if self._entries[s][0] is r:
                self._drop(s)
                return

    def _live(self):
        var out = []
        for s in list(self._entries.keys()):
            var e = self._entries.get(s)
            if e is None:
                continue
            var k = e[0]()
            if k is not None:
                out.append((k, e[1], e[0]))
        return out

    def __delitem__(self, key):
        var s = self._find(key)
        if s is None:
            raise KeyError(key)
        self._drop(s)

    def __getitem__(self, key):
        var s = self._find(key)
        if s is None:
            raise KeyError(key)
        return self._entries[s][1]

    def __len__(self):
        return len(self._live())

    def __repr__(self):
        return "<WeakKeyDictionary at " + _hexid(self) + ">"

    def __setitem__(self, key, value):
        var s = self._find(key)
        if s is not None:
            self._entries[s][1] = value
            return
        var r = ref(key, self._remove)
        var h = hash(key)
        self._next += 1
        self._entries[self._next] = [r, value, h]
        var bucket = self._index.get(h)
        if bucket is None:
            bucket = []
            self._index[h] = bucket
        bucket.append(self._next)

    def copy(self):
        var dup = WeakKeyDictionary()
        for t in self._live():
            dup[t[0]] = t[1]
        return dup

    def __copy__(self):
        return self.copy()

    def __deepcopy__(self, memo):
        from copy import deepcopy
        var dup = self.__class__()
        for t in self._live():
            dup[t[0]] = deepcopy(t[1], memo)
        return dup

    def get(self, key, default=None):
        var s = None
        try:
            s = self._find(key)
        except TypeError:
            return default
        if s is None:
            return default
        return self._entries[s][1]

    def __contains__(self, key):
        try:
            return self._find(key) is not None
        except TypeError:
            return False

    def items(self):
        return [(t[0], t[1]) for t in self._live()]

    def keys(self):
        return [t[0] for t in self._live()]

    def __iter__(self):
        return iter(self.keys())

    def values(self):
        return [t[1] for t in self._live()]

    def keyrefs(self):
        """Return a list of weak references to the keys.

        The references are not guaranteed to be 'live' at the time
        they are used, so the result of calling the references needs
        to be checked before being used.  This can be used to avoid
        creating references that will cause the garbage collector to
        keep the keys around longer than needed.

        """
        return [t[2] for t in self._live()]

    def popitem(self):
        while True:
            if len(self._entries) == 0:
                raise KeyError("popitem(): dictionary is empty")
            var s = list(self._entries.keys())[-1]
            var e = self._entries[s]
            self._drop(s)
            var o = e[0]()
            if o is not None:
                return (o, e[1])

    def pop(self, key, *args):
        var s = self._find(key)
        if s is None:
            if args:
                return args[0]
            raise KeyError(key)
        var v = self._entries[s][1]
        self._drop(s)
        return v

    def setdefault(self, key, default=None):
        var s = self._find(key)
        if s is not None:
            return self._entries[s][1]
        self[key] = default
        return default

    def update(self, dict=None, **kwargs):
        if dict is not None:
            if hasattr(dict, "items"):
                for pair in list(dict.items()):
                    self[pair[0]] = pair[1]
            else:
                for pair in dict:
                    self[pair[0]] = pair[1]
        if len(kwargs):
            self.update(kwargs)

    def __ior__(self, other):
        self.update(other)
        return self

    def __or__(self, other):
        if isinstance(other, dict) or isinstance(other, WeakKeyDictionary):
            var c = self.copy()
            c.update(other)
            return c
        return NotImplemented

    def __ror__(self, other):
        if isinstance(other, dict) or isinstance(other, WeakKeyDictionary):
            var c = self.__class__()
            c.update(other)
            c.update(self)
            return c
        return NotImplemented

    def __eq__(self, other):
        if isinstance(other, WeakKeyDictionary):
            var a = self.items()
            if len(a) != len(other):
                return False
            for pair in a:
                if pair[0] not in other or not (other[pair[0]] == pair[1]):
                    return False
            return True
        return NotImplemented


# ── WeakSet ─────────────────────────────────────────────────────────────────
class WeakSet:
    """A set whose members are referenced weakly (compared by == and
    hash(), as Python's)."""

    def __init__(self, data=None):
        self._d = WeakKeyDictionary()
        if data is not None:
            self.update(data)

    def __iter__(self):
        return iter(self._d.keys())

    def __len__(self):
        return len(self._d)

    def __contains__(self, item):
        return item in self._d

    def __reduce__(self):
        return (self.__class__, (list(self),), getattr(self, "__dict__", None))

    def add(self, item):
        self._d[item] = True

    def clear(self):
        for k in self._d.keys():
            self._d.pop(k, None)

    def copy(self):
        return self.__class__(self)

    def pop(self):
        while True:
            try:
                var pair = self._d.popitem()
                return pair[0]
            except KeyError:
                raise KeyError("pop from empty WeakSet") from None

    def remove(self, item):
        del self._d[item]

    def discard(self, item):
        self._d.pop(item, None)

    def update(self, other):
        for element in other:
            self.add(element)

    def __ior__(self, other):
        self.update(other)
        return self

    def difference(self, other):
        var newset = self.copy()
        newset.difference_update(other)
        return newset
    def __sub__(self, other):
        if not _setlike(other):
            return NotImplemented
        return self.difference(other)

    def difference_update(self, other):
        self.__isub__(other)
    def __isub__(self, other):
        if other is self:
            self.clear()
        else:
            for item in list(other):
                self.discard(item)
        return self

    def intersection(self, other):
        return self.__class__([item for item in other if item in self])
    def __and__(self, other):
        if not _setlike(other):
            return NotImplemented
        return self.intersection(other)

    def intersection_update(self, other):
        self.__iand__(other)
    def __iand__(self, other):
        var keep = [item for item in other if item in self]
        self.clear()
        for item in keep:
            self.add(item)
        return self

    def issubset(self, other):
        for item in self:
            if item not in other:
                return False
        return True
    def __le__(self, other):
        if not _setlike(other):
            return NotImplemented
        return self.issubset(other)

    def __lt__(self, other):
        if not _setlike(other):
            return NotImplemented
        return len(self) < len(other) and self.issubset(other)

    def issuperset(self, other):
        for item in other:
            if item not in self:
                return False
        return True
    def __ge__(self, other):
        if not _setlike(other):
            return NotImplemented
        return self.issuperset(other)

    def __gt__(self, other):
        if not _setlike(other):
            return NotImplemented
        return len(self) > len(other) and self.issuperset(other)

    def __eq__(self, other):
        if not isinstance(other, self.__class__):
            return NotImplemented
        return len(self) == len(other) and self.issubset(other)

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return NotImplemented
        return not r

    def symmetric_difference(self, other):
        var newset = self.copy()
        newset.symmetric_difference_update(other)
        return newset
    def __xor__(self, other):
        if not _setlike(other):
            return NotImplemented
        return self.symmetric_difference(other)

    def symmetric_difference_update(self, other):
        self.__ixor__(other)
    def __ixor__(self, other):
        if other is self:
            self.clear()
        else:
            for item in list(other):
                if item in self:
                    self.discard(item)
                else:
                    self.add(item)
        return self

    def union(self, other):
        var newset = self.copy()
        newset.update(other)
        return newset
    def __or__(self, other):
        if not _setlike(other):
            return NotImplemented
        return self.union(other)

    def isdisjoint(self, other):
        return len(self.intersection(other)) == 0

    def __repr__(self):
        return "{" + ", ".join([repr(x) for x in self]) + "}"


def _setlike(x):
    return isinstance(x, WeakSet) or isinstance(x, set) or isinstance(x, frozenset)


# ── finalize ────────────────────────────────────────────────────────────────
class _FinalizeInfo:
    def __init__(self):
        self.weakref = None
        self.func = None
        self.args = None
        self.kwargs = None
        self.atexit = True
        self.index = 0


class finalize:
    """Class for finalization of weakrefable objects

    finalize(obj, func, *args, **kwargs) returns a callable finalizer
    object which will be called when obj is garbage collected. The
    first time the finalizer is called it evaluates func(*arg, **kwargs)
    and returns the result. After this the finalizer is dead, and
    calling it just returns None.

    When the program exits any remaining finalizers for which the
    atexit attribute is true will be run in reverse order of creation.
    By default atexit is true.
    """

    # Finalizer objects don't have any state of their own.  They are
    # just used as keys to lookup _Info objects in the registry.  This
    # ensures that they cannot be part of a ref-cycle.

    _registry = {}
    _shutdown = False
    _index_iter = [0]
    _dirty = False
    _registered_with_atexit = False

    def __init__(self, obj, func, *args, **kwargs):
        if not finalize._registered_with_atexit:
            # We may register the exit function more than once because
            # of a thread race, but that is harmless
            import atexit
            atexit.register(finalize._exitfunc)
            finalize._registered_with_atexit = True
        var info = _FinalizeInfo()
        info.weakref = ref(obj, self)
        info.func = func
        info.args = args
        info.kwargs = kwargs if kwargs else None
        info.atexit = True
        finalize._index_iter[0] = finalize._index_iter[0] + 1
        info.index = finalize._index_iter[0]
        finalize._registry[self] = info
        finalize._dirty = True

    def __call__(self, _=None):
        """If alive then mark as dead and return func(*args, **kwargs);
        otherwise return None"""
        var info = finalize._registry.pop(self, None)
        if info is not None and not finalize._shutdown:
            return info.func(*info.args, **(info.kwargs or {}))
        return None

    def detach(self):
        """If alive then mark as dead and return (obj, func, args, kwargs);
        otherwise return None"""
        var info = finalize._registry.get(self)
        var obj = info.weakref() if info is not None else None
        if obj is not None and finalize._registry.pop(self, None) is not None:
            return (obj, info.func, info.args, info.kwargs or {})
        return None

    def peek(self):
        """If alive then return (obj, func, args, kwargs);
        otherwise return None"""
        var info = finalize._registry.get(self)
        var obj = info.weakref() if info is not None else None
        if obj is not None:
            return (obj, info.func, info.args, info.kwargs or {})
        return None

    @property
    def alive(self):
        """Whether finalizer is alive"""
        return self in finalize._registry

    @property
    def atexit(self):
        """Whether finalizer should be called at exit"""
        var info = finalize._registry.get(self)
        return info is not None and info.atexit

    @atexit.setter
    def atexit(self, value):
        var info = finalize._registry.get(self)
        if info is not None:
            info.atexit = bool(value)

    def __repr__(self):
        var info = finalize._registry.get(self)
        var obj = info.weakref() if info is not None else None
        if obj is None:
            return "<" + type(self).__name__ + " object at " + _hexid(self) + "; dead>"
        return ("<" + type(self).__name__ + " object at " + _hexid(self) + "; for " +
                repr(_tname(obj)) + " at " + _hexid(obj) + ">")

    @classmethod
    def _select_for_exit(cls):
        # Return live finalizers marked for exit, oldest first
        var L = []
        for f in list(finalize._registry.keys()):
            var i = finalize._registry[f]
            if i.atexit:
                L.append((f, i))
        L.sort(key=lambda item: item[1].index)
        return [p[0] for p in L]

    @classmethod
    def _exitfunc(cls):
        # At shutdown invoke finalizers for which atexit is true.
        # This is called once all other non-daemonic threads have been
        # joined.
        try:
            if finalize._registry:
                var pending = None
                while True:
                    if pending is None or finalize._dirty:
                        pending = finalize._select_for_exit()
                        finalize._dirty = False
                    if not pending:
                        break
                    var f = pending.pop()
                    try:
                        # gc is disabled, so (assuming no daemonic
                        # threads) the following is the only line in
                        # this function which might trigger creation
                        # of a new finalizer
                        f()
                    except Exception as exc:
                        import sys
                        sys.stderr.write("Exception ignored in: " + repr(f) + "\n" +
                                         type(exc).__name__ + ": " + str(exc) + "\n")
        finally:
            # prevent any more finalizers from executing during shutdown
            finalize._shutdown = True
