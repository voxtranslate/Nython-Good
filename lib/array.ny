# nython: module    (import it by name: it runs in a module scope of its own)
# lib/array.ny - Python's array (round 79): compact arrays of numbers of one
# C type, with CPython's typecodes, sizes, conversions and messages.
#
#     from array import array
#     a = array("i", [1, 2, 3]); a.append(4); a.tobytes()
#     array("d", b"...8-byte doubles...")  array("u", "text")
#     m = memoryview(a); m[0] = 10          # a[0] == 10: the same memory
#
# Typecodes (itemsize): b B (1) u (4, 2 on Windows: wchar_t) h H (2) i I (4)
# l L (8, 4 on Windows and 32-bit builds: C long) q Q (8) f (4) d (8).
# array(typecode[, initializer]) from a list or any iterable, bytes or any
# bytes-like object (frombytes), a str for "u", or another array; typecode,
# itemsize; append, extend, insert, pop, remove, index(x, start, stop),
# count, reverse, byteswap, buffer_info (the items' real address),
# frombytes, tobytes, fromlist, tolist, fromunicode, tounicode, fromfile,
# tofile; len, indexing and slicing (an array), item and slice assignment
# (from an array of the same typecode, extended slices included), del, +, *,
# +=, *=, in, iteration, comparisons (item by item, any two arrays), repr,
# bytes(a), copy/deepcopy, pickling as CPython does it (array(typecode,
# list) below protocol 3, _array_reconstructor with the machine format code
# from 3 on - the same bytes), typecodes, ArrayType. Values are range checked
# with CPython's OverflowError messages; "f" items are rounded to single
# precision.
#
# Round 84: the items are native C values in a bytearray (the machine's own
# layout and byte order), read and written in place by the buffer natives
# (_mv_get/_mv_set at _ny_buf_addr), and an array exports them through the
# buffer protocol (__buffer__, PEP 688): memoryview(a) shares the array's
# memory (format the typecode, "w" for "u" as CPython 3.12's), and while a
# view is exported the array cannot change size - "cannot resize an array
# that is exporting buffers" (BufferError), as CPython's.
#
# Not here: the deprecated "u" typecode's wchar_t surrogate handling on
# Windows (characters outside the BMP).
import sys

__all__ = ["array", "ArrayType", "typecodes"]

typecodes = "bBuhHiIlLqQfd"

_WIN = sys.platform == "win32"
_LONG = 4 if (_WIN or sys.maxsize <= 4294967296) else 8
_SIZES = {"b": 1, "B": 1, "u": 2 if _WIN else 4, "h": 2, "H": 2, "i": 4, "I": 4, "l": _LONG, "L": _LONG,
          "q": 8, "Q": 8, "f": 4, "d": 8}
# the buffer natives' item code for each typecode ("u": its wchar_t)
_CODE = {"b": "b", "B": "B", "u": "H" if _WIN else "I", "h": "h", "H": "H", "i": "i", "I": "I", "l": "l",
         "L": "L", "q": "q", "Q": "Q", "f": "f", "d": "d"}
_SIGNED = {"b": true, "B": false, "h": true, "H": false, "i": true, "I": false, "l": true, "L": false,
           "q": true, "Q": false}
# CPython's machine format codes (arraymodule.c), little-endian
_MFORMAT = {"b": 1, "B": 0, "h": 4, "H": 2, "i": 8, "I": 6, "l": 12 if _LONG == 8 else 8,
            "L": 10 if _LONG == 8 else 6, "q": 12, "Q": 10, "f": 14, "d": 16, "u": 18 if _WIN else 20}
_LMAX = (1 << (8 * _LONG - 1)) - 1
_RESIZE = "cannot resize an array that is exporting buffers"


def _range_error(tc, v):
    # CPython's messages, in the order its converters check
    if tc == "q":
        if v > 0x7fffffffffffffff or v < -0x8000000000000000:
            return "int too big to convert"
    elif tc == "Q":
        if v < 0:
            return "can't convert negative int to unsigned"
        if v > 0xffffffffffffffff:
            return "int too big to convert"
    elif tc == "L" or tc == "I":
        if v < 0:
            return "can't convert negative value to unsigned int"
        if v > (1 << (8 * _LONG)) - 1:
            return "Python int too large to convert to C unsigned long"
        if tc == "I" and v > 0xffffffff:
            return "unsigned int is greater than maximum"
    else:
        if v > _LMAX or v < -_LMAX - 1:
            return "Python int too large to convert to C long"
        if tc == "b":
            if v > 127:
                return "signed char is greater than maximum"
            if v < -128:
                return "signed char is less than minimum"
        elif tc == "B":
            if v > 255:
                return "unsigned byte integer is greater than maximum"
            if v < 0:
                return "unsigned byte integer is less than minimum"
        elif tc == "h":
            if v > 32767:
                return "signed short integer is greater than maximum"
            if v < -32768:
                return "signed short integer is less than minimum"
        elif tc == "H":
            if v > 65535:
                return "unsigned short is greater than maximum"
            if v < 0:
                return "unsigned short is less than minimum"
        elif tc == "i":
            if v > 0x7fffffff:
                return "signed integer is greater than maximum"
            if v < -0x80000000:
                return "signed integer is less than minimum"
    return none


def _conv(tc, v):
    # an item as the array stores it (TypeError / OverflowError as CPython)
    if tc == "f" or tc == "d":
        if isinstance(v, bool) or isinstance(v, int) or isinstance(v, float):
            return float(v)
        if hasattr(v, "__float__"):
            return float(v)
        raise TypeError("must be real number, not " + type(v).__name__)
    if tc == "u":
        if not isinstance(v, str) or len(v) != 1:
            raise TypeError("array item must be unicode character")
        return v
    if isinstance(v, float):
        raise TypeError("'float' object cannot be interpreted as an integer")
    if not (isinstance(v, int) or isinstance(v, bool)):
        if hasattr(v, "__index__"):
            v = v.__index__()
        else:
            raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")
    var n = int(v)
    var msg = _range_error(tc, n)
    if msg is not none:
        raise OverflowError(msg)
    return n


def _raw(tc, v):
    # an item (already converted) as the buffer natives store it
    if tc == "u":
        return ord(v)
    if tc == "f" or tc == "d":
        return v
    if v > 0x7fffffffffffffff:
        return v - 0x10000000000000000
    return v


def _check_typecode(tc):
    if not isinstance(tc, str) or len(tc) != 1:
        raise TypeError("array() argument 1 must be a unicode character, not " + type(tc).__name__)
    if tc not in _SIZES:
        raise ValueError("bad typecode (must be b, B, u, h, H, i, I, l, L, q, Q, f or d)")


def _pack(tc, items):
    # converted items as the bytes of an array
    var sz = _SIZES[tc]
    var tmp = bytearray(len(items) * sz)
    if items:
        var a = _ny_buf_addr(tmp)
        var c = _CODE[tc]
        var i = 0
        for v in items:
            _mv_set(a + i, c, _raw(tc, v))
            i += sz
    return tmp


def _unpack(tc, data, start=0, n=-1):
    # the items in an array's bytes (a bytearray: its storage is read in place)
    var sz = _SIZES[tc]
    if n < 0:
        n = (len(data) - start) // sz
    if n <= 0:
        return []
    var b = data if isinstance(data, bytearray) else bytearray(data)
    var c = _CODE[tc]
    var r = _mv_tolist(_ny_buf_addr(b) + start, c, [n], [sz])
    if tc == "u":
        return [chr(x) for x in r]
    if tc == "Q" or tc == "L":
        return [int(x) if isinstance(x, str) else x for x in r]
    return r


def _is_array(x):
    return isinstance(x, array)


class array:
    """array(typecode [, initializer]) -> array"""

    _ny_ctype = true      # (a C type in CPython: pickle names it as one)

    def __init__(self, typecode, initializer=none):
        _check_typecode(typecode)
        self._tc = typecode
        self._b = bytearray()
        self._exports = 0
        if initializer is none:
            return
        if isinstance(initializer, str):
            if typecode != "u":
                raise TypeError("cannot use a str to initialize an array with typecode '" + typecode + "'")
            self._b = _pack("u", list(initializer))
        elif isinstance(initializer, bytes) or isinstance(initializer, bytearray):
            self.frombytes(initializer)
        elif _is_array(initializer):
            if initializer._tc == "u" and typecode != "u":
                raise TypeError("cannot use a unicode array to initialize an array with typecode '" + typecode + "'")
            if initializer._tc == typecode:
                self._b = bytearray(initializer._b)
            else:
                self._b = _pack(typecode, [_conv(typecode, v) for v in initializer._items()])
        else:
            self._b = _pack(typecode, [_conv(typecode, v) for v in initializer])

    @property
    def typecode(self):
        return self._tc

    @property
    def itemsize(self):
        return _SIZES[self._tc]

    def _new(self, items):
        var r = array(self._tc)
        r._b = _pack(self._tc, items)
        return r

    def _from_bytes(self, data):
        var r = array(self._tc)
        r._b = bytearray(data)
        return r

    def _items(self):
        return _unpack(self._tc, self._b)

    def _get(self, k):
        var v = _mv_get(_ny_buf_addr(self._b) + k * _SIZES[self._tc], _CODE[self._tc])
        if self._tc == "u":
            return chr(v)
        if isinstance(v, str):
            return int(v)
        return v

    def _put(self, k, v):
        # v already converted
        _mv_set(_ny_buf_addr(self._b) + k * _SIZES[self._tc], _CODE[self._tc], _raw(self._tc, v))

    def _resizing(self):
        if self._exports > 0:
            raise BufferError(_RESIZE)

    # ── the buffer protocol (PEP 688; round 84) ─────────────────────────
    def __buffer__(self, flags):
        var e = _ny_buf_export(self._b)     # the storage cannot move while viewed
        self._exports += 1
        var tc = self._tc
        var sz = _SIZES[tc]
        var fmt = ("w" if tc == "u" else tc) if (flags & 4) else "B"
        var arr = self
        var store = self._b
        def gone():
            arr._exports -= 1
            _ny_buf_unexport(store)
        return _ny_memview_raw(self, e[0], e[1], false, fmt, sz, (e[1] // sz,), (sz,), gone, store)

    def __release_buffer__(self, view):
        view.release()

    # ── list-like methods ───────────────────────────────────────────────
    def append(self, v):
        var x = _conv(self._tc, v)
        self._resizing()
        self._b.extend(_pack(self._tc, [x]))

    def extend(self, it):
        if _is_array(it):
            if it._tc != self._tc:
                raise TypeError("can only extend with array of same kind")
            var data = bytes(it._b)
            if data:
                self._resizing()
            self._b.extend(data)
            return
        var conv = [_conv(self._tc, v) for v in it]
        if conv:
            self._resizing()
        self._b.extend(_pack(self._tc, conv))

    def insert(self, i, v):
        var x = _conv(self._tc, v)
        var n = len(self)
        if i < 0:
            i = max(0, i + n)
        if i > n:
            i = n
        self._resizing()
        var sz = _SIZES[self._tc]
        self._b[i * sz:i * sz] = _pack(self._tc, [x])

    def pop(self, i=-1):
        var n = len(self)
        if n == 0:
            raise IndexError("pop from empty array")
        var k = i + n if i < 0 else i
        if k < 0 or k >= n:
            raise IndexError("pop index out of range")
        var v = self._get(k)
        self._resizing()
        var sz = _SIZES[self._tc]
        del self._b[k * sz:(k + 1) * sz]
        return v

    def remove(self, v):
        var items = self._items()
        for i in range(len(items)):
            if items[i] == v:
                self._resizing()
                var sz = _SIZES[self._tc]
                del self._b[i * sz:(i + 1) * sz]
                return
        raise ValueError("array.remove(x): x not in array")

    def index(self, v, start=0, stop=sys.maxsize):
        var items = self._items()
        var n = len(items)
        if start < 0:
            start = max(0, start + n)
        if stop < 0:
            stop = max(0, stop + n)
        var i = start
        while i < min(stop, n):
            if items[i] == v:
                return i
            i = i + 1
        raise ValueError("array.index(x): x not in array")

    def count(self, v):
        var c = 0
        for x in self._items():
            if x == v:
                c = c + 1
        return c

    def reverse(self):
        var items = self._items()
        items.reverse()
        self._b[:] = _pack(self._tc, items)

    def byteswap(self):
        var size = _SIZES[self._tc]
        if size == 1:
            return
        var raw = bytes(self._b)
        var out = bytearray()
        var i = 0
        while i < len(raw):
            out.extend(raw[i:i + size][::-1])
            i = i + size
        self._b[:] = out

    def buffer_info(self):
        var a = _ny_buf_addr(self._b)
        return (a, len(self))

    # ── conversions ─────────────────────────────────────────────────────
    def frombytes(self, data):
        if isinstance(data, str):
            raise TypeError("a bytes-like object is required, not 'str'")
        var b = _ny_bytes_like(data)
        if len(b) % _SIZES[self._tc] != 0:
            raise ValueError("bytes length not a multiple of item size")
        if len(b):
            self._resizing()
        self._b.extend(b)

    def tobytes(self):
        return bytes(self._b)

    def fromlist(self, lst):
        if not isinstance(lst, list):
            raise TypeError("arg must be list")
        var conv = [_conv(self._tc, v) for v in lst]
        if conv:
            self._resizing()
        self._b.extend(_pack(self._tc, conv))

    def tolist(self):
        return self._items()

    def fromunicode(self, s):
        if self._tc != "u":
            raise ValueError("fromunicode() may only be called on unicode type arrays")
        if not isinstance(s, str):
            raise TypeError("fromunicode() argument must be str, not " + type(s).__name__)
        if s:
            self._resizing()
        self._b.extend(_pack("u", list(s)))

    def tounicode(self):
        if self._tc != "u":
            raise ValueError("tounicode() may only be called on unicode type arrays")
        return "".join(self._items())

    def fromfile(self, f, n):
        if n < 0:
            raise ValueError("negative count")
        var want = n * _SIZES[self._tc]
        var data = f.read(want)
        if not isinstance(data, bytes) and not isinstance(data, bytearray):
            raise TypeError("read() didn't return bytes")
        var whole = len(data) - len(data) % _SIZES[self._tc]
        self.frombytes(data[:whole])
        if len(data) < want:
            raise EOFError("read() didn't return enough bytes")

    def tofile(self, f):
        f.write(self.tobytes())

    # ── the sequence protocol ───────────────────────────────────────────
    def __len__(self):
        return len(self._b) // _SIZES[self._tc]

    def __iter__(self):
        return iter(self._items())

    def __contains__(self, v):
        for x in self._items():
            if x == v:
                return true
        return false

    def __getitem__(self, i):
        if isinstance(i, slice):
            var n = len(self)
            var r = i.indices(n)
            var sz = _SIZES[self._tc]
            if r[2] == 1:
                return self._from_bytes(self._b[r[0] * sz:max(r[0], r[1]) * sz])
            return self._new(self._items()[i])
        if not (isinstance(i, int) or hasattr(i, "__index__")):
            raise TypeError("array indices must be integers")
        var n = len(self)
        var k = int(i) if isinstance(i, int) else i.__index__()
        if k < 0:
            k = k + n
        if k < 0 or k >= n:
            raise IndexError("array index out of range")
        return self._get(k)

    def __setitem__(self, i, v):
        if isinstance(i, slice):
            if not _is_array(v):
                raise TypeError("can only assign array (not \"" + type(v).__name__ + "\") to array slice")
            if v._tc != self._tc:
                raise TypeError("bad argument type for built-in operation")
            var n = len(self)
            var r = i.indices(n)
            var sz = _SIZES[self._tc]
            var src = bytes(v._b)
            if r[2] == 1:
                var stop = max(r[0], r[1])
                if len(src) != (stop - r[0]) * sz:
                    self._resizing()
                self._b[r[0] * sz:stop * sz] = src
                return
            var count = len(range(r[0], r[1], r[2]))
            var items = v._items()
            if count != len(items):
                raise ValueError("attempt to assign array of size " + str(len(items))
                                 + " to extended slice of size " + str(count))
            var k = 0
            for j in range(r[0], r[1], r[2]):
                self._put(j, items[k])
                k += 1
            return
        var n = len(self)
        var k = int(i) if isinstance(i, int) else i.__index__()
        if k < 0:
            k = k + n
        if k < 0 or k >= n:
            raise IndexError("array assignment index out of range")
        self._put(k, _conv(self._tc, v))

    def __delitem__(self, i):
        var n = len(self)
        var sz = _SIZES[self._tc]
        if isinstance(i, slice):
            var r = i.indices(n)
            var gone = len(range(r[0], r[1], r[2]))
            if gone == 0:
                return
            self._resizing()
            if r[2] == 1:
                del self._b[r[0] * sz:r[1] * sz]
                return
            var items = self._items()
            del items[i]
            self._b[:] = _pack(self._tc, items)
            return
        var k = int(i) if isinstance(i, int) else i.__index__()
        if k < 0:
            k = k + n
        if k < 0 or k >= n:
            raise IndexError("array assignment index out of range")
        self._resizing()
        del self._b[k * sz:(k + 1) * sz]

    def __add__(self, other):
        if not _is_array(other):
            raise TypeError("can only append array (not \"" + type(other).__name__ + "\") to array")
        if other._tc != self._tc:
            raise TypeError("bad argument type for built-in operation")
        return self._from_bytes(bytes(self._b) + bytes(other._b))

    def __iadd__(self, other):
        if not _is_array(other):
            raise TypeError("can only extend array with array (not \"" + type(other).__name__ + "\")")
        if other._tc != self._tc:
            raise TypeError("can only extend with array of same kind")
        var data = bytes(other._b)
        if data:
            self._resizing()
        self._b.extend(data)
        return self

    def __mul__(self, n):
        if not (isinstance(n, int) or isinstance(n, bool)):
            raise TypeError("can't multiply sequence by non-int of type '" + type(n).__name__ + "'")
        return self._from_bytes(bytes(self._b) * n if n > 0 else b"")

    def __rmul__(self, n):
        return self.__mul__(n)

    def __imul__(self, n):
        var data = bytes(self._b) * n if n > 0 else b""
        if len(data) != len(self._b):
            self._resizing()
            self._b[:] = data
        return self

    # comparisons item by item (any two arrays, as CPython)
    def _cmp(self, other):
        var a = self._items()
        var b = other._items()
        var i = 0
        while i < len(a) and i < len(b):
            if a[i] != b[i]:
                return -1 if a[i] < b[i] else 1
            i = i + 1
        return (len(a) > len(b)) - (len(a) < len(b))

    def __eq__(self, other):
        if not _is_array(other):
            return NotImplemented
        return len(self) == len(other) and self._cmp(other) == 0

    def __ne__(self, other):
        if not _is_array(other):
            return NotImplemented
        return not self.__eq__(other)

    def __lt__(self, other):
        if not _is_array(other):
            return NotImplemented
        return self._cmp(other) < 0

    def __le__(self, other):
        if not _is_array(other):
            return NotImplemented
        return self._cmp(other) <= 0

    def __gt__(self, other):
        if not _is_array(other):
            return NotImplemented
        return self._cmp(other) > 0

    def __ge__(self, other):
        if not _is_array(other):
            return NotImplemented
        return self._cmp(other) >= 0

    __hash__ = none

    def __repr__(self):
        if len(self) == 0:
            return "array('" + self._tc + "')"
        if self._tc == "u":
            return "array('u', " + repr(self.tounicode()) + ")"
        return "array('" + self._tc + "', " + repr(self._items()) + ")"

    def __str__(self):
        return self.__repr__()

    def __copy__(self):
        return self._from_bytes(self._b)

    def __deepcopy__(self, memo):
        return self._from_bytes(self._b)

    def __reduce_ex__(self, protocol):
        if protocol < 3:
            return (array, (self._tc, self.tolist()), none)
        return (_array_reconstructor, (array, self._tc, _MFORMAT[self._tc], self.tobytes()), none)


def _array_reconstructor(arraytype, typecode, mformat_code, items):
    if not isinstance(arraytype, type):
        raise TypeError("first argument must be a type object, not " + type(arraytype).__name__)
    _check_typecode(typecode)
    var a = arraytype(typecode)
    if mformat_code == _MFORMAT.get(typecode):
        a.frombytes(items)
        return a
    # another machine's layout: decode by the format code
    import struct
    var fmts = {0: "<B", 1: "<b", 2: "<H", 3: ">H", 4: "<h", 5: ">h", 6: "<I", 7: ">I", 8: "<i", 9: ">i",
                10: "<Q", 11: ">Q", 12: "<q", 13: ">q", 14: "<f", 15: ">f", 16: "<d", 17: ">d"}
    if mformat_code in (18, 19, 20, 21):
        var enc = {18: "utf-16-le", 19: "utf-16-be", 20: "utf-32-le", 21: "utf-32-be"}[mformat_code]
        a.fromunicode(bytes(items).decode(enc))
        return a
    if mformat_code not in fmts:
        raise ValueError("third argument must be a valid machine format code.")
    var f = fmts[mformat_code]
    var size = struct.calcsize(f)
    var n = len(items) // size
    a.fromlist(list(struct.unpack(f[0] + str(n) + f[1], bytes(items))))
    return a


ArrayType = array
