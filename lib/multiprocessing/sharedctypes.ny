# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/multiprocessing/sharedctypes.ny - Value, Array, RawValue, RawArray:
# typed data in shared memory (round 80).
#
# The memory is a file mapped shared by every process that uses it (mmap /
# CreateFileMapping, src/builtins/os_fd.cpp "shm_*"), in the creating
# process's private directory (/dev/shm when there is one); passing the
# object to a Process maps the same pages there. Values are read and written
# with struct's formats for the array module's typecodes ('b' 'B' 'h' 'H'
# 'i' 'I' 'l' 'L' 'q' 'Q' 'f' 'd', 'c' a one-byte bytes, 'u' a str of one
# character, '?') or the ctypes names Python code uses (ctypes is not there,
# so its types are given as strings: "c_int", "c_double", "c_char" ...).
#
# Value(typecode, *args, lock=True) / Array(typecode, size_or_initializer,
# lock=True) are synchronized wrappers: .value / [i] / [a:b] / len(),
# get_lock() (an RLock on the creator's server - lock=False gives none,
# lock=<a Lock or RLock> that one), get_obj(), acquire()/release(), with;
# a 'c' Array has .value (up to the first NUL) and .raw.
# RawValue / RawArray: the same without a lock. Reads and writes of one
# element are each one copy of its bytes; a read-modify-write (v.value += 1)
# needs the lock, as in CPython.

import os
import struct
from multiprocessing import managers as _mg

__all__ = ['RawValue', 'RawArray', 'Value', 'Array', 'copy', 'synchronized']

_CTYPES = {"c_bool": "?", "c_char": "c", "c_wchar": "u", "c_byte": "b", "c_ubyte": "B", "c_short": "h",
           "c_ushort": "H", "c_int": "i", "c_uint": "I", "c_long": "l", "c_ulong": "L", "c_longlong": "q",
           "c_ulonglong": "Q", "c_float": "f", "c_double": "d", "c_int8": "b", "c_uint8": "B",
           "c_int16": "h", "c_uint16": "H", "c_int32": "i", "c_uint32": "I", "c_int64": "q",
           "c_uint64": "Q", "c_size_t": "Q", "c_ssize_t": "q"}
_FORMATS = {"b": "b", "B": "B", "h": "h", "H": "H", "i": "i", "I": "I", "l": "q", "L": "Q", "q": "q", "Q": "Q",
            "f": "f", "d": "d", "c": "c", "u": "I", "?": "?"}
if os.name == "nt":
    _FORMATS["l"] = "i"
    _FORMATS["L"] = "I"


def _typecode(t):
    if isinstance(t, str) and t in _FORMATS:
        return t
    if isinstance(t, str) and t in _CTYPES:
        return _CTYPES[t]
    var n = getattr(t, "__name__", None)
    if n in _CTYPES:
        return _CTYPES[n]
    raise TypeError("unsupported type or typecode: " + repr(t))


class _Segment(object):
    # a shared mapping: the path every process opens, and this process's
    # handle (opened on first use after unpickling)
    def __init__(self, size, path=None):
        if path is None:
            path = os.path.join(_mg._get_temp_dir(), "shm-" + str(os.getpid()) + "-" + os.urandom(6).hex())
            self.h = _ny_os_call("shm_open", path, max(size, 1), True)
        else:
            self.h = _ny_os_call("shm_open", path, 0, False)
        self.path = path
        self.size = size

    def __reduce__(self):
        return (_open_segment, (self.size, self.path))

    def read(self, off, n):
        return _ny_os_call("shm_read", self.h, off, n)

    def write(self, off, data):
        _ny_os_call("shm_write", self.h, off, data)


_segments = {}


def _open_segment(size, path):
    var s = _segments.get(path)
    if s is None:
        s = _Segment(size, path)
        _segments[path] = s
    return s


class _RawBase(object):
    def _setup(self, typecode, length, seg=None):
        self._typecode = typecode
        self._fmt = "<" + _FORMATS[typecode]
        self._itemsize = struct.calcsize(self._fmt)
        self._length = length
        if seg is None:
            seg = _Segment(self._itemsize * max(length, 1))
            _segments[seg.path] = seg
        self._seg = seg

    def _get(self, i):
        var v = struct.unpack(self._fmt, self._seg.read(i * self._itemsize, self._itemsize))[0]
        if self._typecode == "u":
            return chr(v)
        return v

    def _pack(self, v):
        if self._typecode == "u":
            if not isinstance(v, str) or len(v) != 1:
                raise TypeError("unicode string of length 1 expected")
            v = ord(v)
        elif self._typecode == "c":
            if isinstance(v, int) and not isinstance(v, bool):
                v = bytes([v])
            if not isinstance(v, bytes) or len(v) != 1:
                raise TypeError("one character bytes, bytearray or integer expected")
        elif self._typecode in "fd":
            if not isinstance(v, (int, float)):
                raise TypeError("must be real number, not " + type(v).__name__)
        elif self._typecode != "?":
            if isinstance(v, float):
                raise TypeError("int expected instead of float")
            if not isinstance(v, int):
                raise TypeError("an integer is required (got type " + type(v).__name__ + ")")
            # C's wrap-around, as ctypes stores an out-of-range int
            var bits = self._itemsize * 8
            v = v & ((1 << bits) - 1)
            if self._typecode in "bhilq" and v >= (1 << (bits - 1)):
                v -= (1 << bits)
        return struct.pack(self._fmt, v)

    def _set(self, i, v):
        self._seg.write(i * self._itemsize, self._pack(v))


class _RawValue(_RawBase):
    def __init__(self, typecode, *args, _seg=None):
        self._setup(typecode, 1, _seg)
        if _seg is None:
            if args:
                self._set(0, args[0])
            else:
                self._seg.write(0, bytes(self._itemsize))

    @property
    def value(self):
        return self._get(0)

    @value.setter
    def value(self, v):
        self._set(0, v)

    def __reduce__(self):
        return (_rebuild_raw_value, (self._typecode, self._seg))

    def __repr__(self):
        return "%s(%r)" % (_ctype_name(self._typecode), self.value)


def _rebuild_raw_value(typecode, seg):
    return _RawValue(typecode, _seg=seg)


def _ctype_name(tc):
    for k in _CTYPES:
        if _CTYPES[k] == tc:
            return k
    return "c_" + tc


class _RawArray(_RawBase):
    def __init__(self, typecode, size_or_initializer, _seg=None):
        var init = None
        var n = size_or_initializer
        if not isinstance(size_or_initializer, int):
            init = list(size_or_initializer)
            n = len(init)
        self._setup(typecode, n, _seg)
        if _seg is None:
            if init is None:
                self._seg.write(0, bytes(self._itemsize * n))
            else:
                self._seg.write(0, b"".join([self._pack(v) for v in init]))

    def __len__(self):
        return self._length

    def _index(self, i):
        if i < 0:
            i += self._length
        if not 0 <= i < self._length:
            raise IndexError("invalid index")
        return i

    def _all(self):
        var data = self._seg.read(0, self._itemsize * self._length)
        if self._typecode == "c":
            return [data[k:k + 1] for k in range(self._length)]
        var vals = list(struct.unpack("<" + str(self._length) + _FORMATS[self._typecode], data))
        if self._typecode == "u":
            return [chr(v) for v in vals]
        return vals

    def __getitem__(self, i):
        if isinstance(i, slice):
            var items = self._all()[i]
            if self._typecode == "c":
                return b"".join(items)
            if self._typecode == "u":
                return "".join(items)
            return items
        return self._get(self._index(i))

    def __setitem__(self, i, v):
        if isinstance(i, slice):
            var idx = list(range(self._length))[i]
            var vals = list(v)
            if len(vals) != len(idx):
                raise ValueError("Can only assign sequence of same size")
            if i.step is None or i.step == 1:
                if idx:
                    self._seg.write(idx[0] * self._itemsize, b"".join([self._pack(x) for x in vals]))
                return
            var k = 0
            for j in idx:
                self._set(j, vals[k])
                k += 1
            return
        self._set(self._index(i), v)

    def __iter__(self):
        return iter(self._all())

    @property
    def value(self):
        if self._typecode == "c":
            var raw = self._seg.read(0, self._length)
            var z = raw.find(b"\x00")
            return raw if z < 0 else raw[:z]
        if self._typecode == "u":
            var s = "".join(self._all())
            var z2 = s.find("\x00")
            return s if z2 < 0 else s[:z2]
        raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'value'")

    @value.setter
    def value(self, v):
        if self._typecode == "c":
            if len(v) > self._length:
                raise ValueError("byte string too long")
            self._seg.write(0, bytes(v) + (b"\x00" if len(v) < self._length else b""))
            return
        if self._typecode == "u":
            if len(v) > self._length:
                raise ValueError("string too long")
            var k = 0
            for ch in v:
                self._set(k, ch)
                k += 1
            if k < self._length:
                self._set(k, "\x00")
            return
        raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'value'")

    @property
    def raw(self):
        if self._typecode != "c":
            raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'raw'")
        return self._seg.read(0, self._length)

    @raw.setter
    def raw(self, v):
        if self._typecode != "c":
            raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'raw'")
        if len(v) > self._length:
            raise ValueError("byte string too long")
        self._seg.write(0, bytes(v))

    def __reduce__(self):
        return (_rebuild_raw_array, (self._typecode, self._length, self._seg))

    def __repr__(self):
        return "<%s_Array_%d object at %#x>" % (_ctype_name(self._typecode), self._length, id(self))


def _rebuild_raw_array(typecode, length, seg):
    var a = object.__new__(_RawArray)
    a._setup(typecode, length, seg)
    return a


def RawValue(typecode_or_type, *args):
    """Returns a ctypes object allocated from shared memory"""
    return _RawValue(_typecode(typecode_or_type), *args)


def RawArray(typecode_or_type, size_or_initializer):
    """Returns a ctypes array allocated from shared memory"""
    return _RawArray(_typecode(typecode_or_type), size_or_initializer)


def _the_lock(lock):
    from multiprocessing import synchronize
    if lock is True or lock is None:
        return synchronize.RLock()
    if not hasattr(lock, "acquire"):
        raise AttributeError("%r has no method 'acquire'" % lock)
    return lock


def Value(typecode_or_type, *args, lock=True, ctx=None):
    """Return a synchronization wrapper for a Value"""
    var obj = RawValue(typecode_or_type, *args)
    if lock is False:
        return obj
    return Synchronized(obj, _the_lock(lock))


def Array(typecode_or_type, size_or_initializer, *, lock=True, ctx=None):
    """Return a synchronization wrapper for a RawArray"""
    var obj = RawArray(typecode_or_type, size_or_initializer)
    if lock is False:
        return obj
    return SynchronizedArray(obj, _the_lock(lock))


def copy(obj):
    if isinstance(obj, _RawArray):
        return _RawArray(obj._typecode, obj[:] if obj._typecode not in "cu" else list(obj))
    return _RawValue(obj._typecode, obj.value)


def synchronized(obj, lock=None, ctx=None):
    if isinstance(obj, _RawArray):
        return SynchronizedArray(obj, _the_lock(lock))
    return Synchronized(obj, _the_lock(lock))


class SynchronizedBase(object):

    def __init__(self, obj, lock=None, ctx=None):
        self._obj = obj
        self._lock = lock
        self.acquire = self._lock.acquire
        self.release = self._lock.release

    def __enter__(self):
        return self._lock.__enter__()

    def __exit__(self, *args):
        return self._lock.__exit__(*args)

    def __reduce__(self):
        return (_rebuild_sync, (type(self), self._obj, self._lock))

    def get_obj(self):
        return self._obj

    def get_lock(self):
        return self._lock

    def __repr__(self):
        return '<%s wrapper for %s>' % (type(self).__name__, self._obj)


def _rebuild_sync(cls, obj, lock):
    return cls(obj, lock)


class Synchronized(SynchronizedBase):

    @property
    def value(self):
        with self._lock:
            return self._obj.value

    @value.setter
    def value(self, v):
        with self._lock:
            self._obj.value = v


class SynchronizedArray(SynchronizedBase):

    def __len__(self):
        return len(self._obj)

    def __getitem__(self, i):
        with self._lock:
            return self._obj[i]

    def __setitem__(self, i, value):
        with self._lock:
            self._obj[i] = value

    def __iter__(self):
        with self._lock:
            return iter(self._obj[:] if self._obj._typecode not in "cu" else list(self._obj))

    @property
    def value(self):
        with self._lock:
            return self._obj.value

    @value.setter
    def value(self, v):
        with self._lock:
            self._obj.value = v

    @property
    def raw(self):
        with self._lock:
            return self._obj.raw

    @raw.setter
    def raw(self, v):
        with self._lock:
            self._obj.raw = v
