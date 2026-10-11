# nython: module    (import it by name: it runs in a module scope of its own)
# lib/array.ny - Python's array (round 79): compact arrays of numbers of one
# C type, with CPython's typecodes, sizes, conversions and messages.
#
#     from array import array
#     a = array("i", [1, 2, 3]); a.append(4); a.tobytes()
#     array("d", b"...8-byte doubles...")  array("u", "text")
#
# Typecodes (itemsize): b B (1) u (4, 2 on Windows: wchar_t) h H (2) i I (4)
# l L (8, 4 on Windows and 32-bit builds: C long) q Q (8) f (4) d (8).
# array(typecode[, initializer]) from a list or any iterable, bytes or
# bytearray (frombytes), a str for "u", or another array; typecode,
# itemsize; append, extend, insert, pop, remove, index(x, start, stop),
# count, reverse, byteswap, buffer_info, frombytes, tobytes, fromlist,
# tolist, fromunicode, tounicode, fromfile, tofile; len, indexing and
# slicing (an array), item and slice assignment (from an array of the same
# typecode, extended slices included), del, +, *, +=, *=, in, iteration,
# comparisons (item by item, any two arrays), repr, bytes(a), copy/deepcopy,
# pickling as CPython does it (array(typecode, list) below protocol 3,
# _array_reconstructor with the machine format code from 3 on - the same
# bytes), typecodes, ArrayType. Values are range checked with CPython's
# OverflowError messages; "f" items are rounded to single precision.
#
# Not here: the buffer protocol (Nython has no memoryview; bytes(a) and
# tobytes() give the data), the deprecated "u" typecode's wchar_t surrogate
# handling on Windows (characters outside the BMP).
import struct
import sys

__all__ = ["array", "ArrayType", "typecodes"]

typecodes = "bBuhHiIlLqQfd"

_WIN = sys.platform == "win32"
_LONG = 4 if (_WIN or sys.maxsize <= 4294967296) else 8
_SIZES = {"b": 1, "B": 1, "u": 2 if _WIN else 4, "h": 2, "H": 2, "i": 4, "I": 4, "l": _LONG, "L": _LONG,
          "q": 8, "Q": 8, "f": 4, "d": 8}
_SIGNED = {"b": true, "B": false, "h": true, "H": false, "i": true, "I": false, "l": true, "L": false,
           "q": true, "Q": false}
# struct codes for little-endian standard sizes
_STRUCT = {"b": "b", "B": "B", "h": "h", "H": "H", "i": "i", "I": "I", "l": "q" if _LONG == 8 else "i",
           "L": "Q" if _LONG == 8 else "I", "q": "q", "Q": "Q", "f": "f", "d": "d"}
# CPython's machine format codes (arraymodule.c), little-endian
_MFORMAT = {"b": 1, "B": 0, "h": 4, "H": 2, "i": 8, "I": 6, "l": 12 if _LONG == 8 else 8,
            "L": 10 if _LONG == 8 else 6, "q": 12, "Q": 10, "f": 14, "d": 16, "u": 18 if _WIN else 20}
_LMAX = (1 << (8 * _LONG - 1)) - 1


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


def _f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def _conv(tc, v):
    # an item as the array stores it (TypeError / OverflowError as CPython)
    if tc == "f" or tc == "d":
        if isinstance(v, bool) or isinstance(v, int) or isinstance(v, float):
            var x = float(v)
            if tc == "f":
                if x != x or x in (float("inf"), float("-inf")):
                    return x
                if abs(x) > 3.4028234663852886e38:
                    return float("inf") if x > 0 else float("-inf")
                return _f32(x)
            return x
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


def _check_typecode(tc):
    if not isinstance(tc, str) or len(tc) != 1:
        raise TypeError("array() argument 1 must be a unicode character, not " + type(tc).__name__)
    if tc not in _SIZES:
        raise ValueError("bad typecode (must be b, B, u, h, H, i, I, l, L, q, Q, f or d)")


def _pack(tc, items):
    if tc == "u":
        var enc = "utf-16-le" if _WIN else "utf-32-le"
        return "".join(items).encode(enc)
    if not items:
        return b""
    return struct.pack("<" + str(len(items)) + _STRUCT[tc], *items)


def _unpack(tc, data):
    if tc == "u":
        var enc = "utf-16-le" if _WIN else "utf-32-le"
        return list(bytes(data).decode(enc))
    var n = len(data) // _SIZES[tc]
    if n == 0:
        return []
    return list(struct.unpack("<" + str(n) + _STRUCT[tc], bytes(data)))


def _is_array(x):
    return isinstance(x, array)


class array:
    """array(typecode [, initializer]) -> array"""

    _ny_ctype = true      # (a C type in CPython: pickle names it as one)

    def __init__(self, typecode, initializer=none):
        _check_typecode(typecode)
        self._tc = typecode
        self._a = []
        if initializer is none:
            return
        if isinstance(initializer, str):
            if typecode != "u":
                raise TypeError("cannot use a str to initialize an array with typecode '" + typecode + "'")
            self._a = list(initializer)
        elif isinstance(initializer, bytes) or isinstance(initializer, bytearray):
            self.frombytes(initializer)
        elif _is_array(initializer):
            if initializer._tc == "u" and typecode != "u":
                raise TypeError("cannot use a unicode array to initialize an array with typecode '" + typecode + "'")
            self._a = [_conv(typecode, v) for v in initializer._a]
        else:
            self._a = [_conv(typecode, v) for v in initializer]

    @property
    def typecode(self):
        return self._tc

    @property
    def itemsize(self):
        return _SIZES[self._tc]

    def _new(self, items):
        var r = array(self._tc)
        r._a = items
        return r

    # ── list-like methods ───────────────────────────────────────────────
    def append(self, v):
        self._a.append(_conv(self._tc, v))

    def extend(self, it):
        if _is_array(it):
            if it._tc != self._tc:
                raise TypeError("can only extend with array of same kind")
            self._a.extend(list(it._a))
            return
        var conv = [_conv(self._tc, v) for v in it]
        self._a.extend(conv)

    def insert(self, i, v):
        self._a.insert(i, _conv(self._tc, v))

    def pop(self, i=-1):
        if len(self._a) == 0:
            raise IndexError("pop from empty array")
        var n = len(self._a)
        var k = i + n if i < 0 else i
        if k < 0 or k >= n:
            raise IndexError("pop index out of range")
        return self._a.pop(k)

    def remove(self, v):
        for i in range(len(self._a)):
            if self._a[i] == v:
                del self._a[i]
                return
        raise ValueError("array.remove(x): x not in array")

    def index(self, v, start=0, stop=sys.maxsize):
        var n = len(self._a)
        if start < 0:
            start = max(0, start + n)
        if stop < 0:
            stop = max(0, stop + n)
        var i = start
        while i < min(stop, n):
            if self._a[i] == v:
                return i
            i = i + 1
        raise ValueError("array.index(x): x not in array")

    def count(self, v):
        var c = 0
        for x in self._a:
            if x == v:
                c = c + 1
        return c

    def reverse(self):
        self._a.reverse()

    def byteswap(self):
        if self._tc == "u":
            var size = _SIZES["u"]
            var raw = bytearray(_pack("u", self._a))
            var out = bytearray()
            var i = 0
            while i < len(raw):
                out.extend(bytes(reversed(raw[i:i + size])))
                i = i + size
            self._a = _unpack("u", out)
            return
        var size = _SIZES[self._tc]
        if size == 1:
            return
        var raw = _pack(self._tc, self._a)
        var out = bytearray()
        var i = 0
        while i < len(raw):
            out.extend(bytes(reversed(raw[i:i + size])))
            i = i + size
        self._a = _unpack(self._tc, out)

    def buffer_info(self):
        return (id(self), len(self._a))

    # ── conversions ─────────────────────────────────────────────────────
    def frombytes(self, data):
        if isinstance(data, str):
            raise TypeError("a bytes-like object is required, not 'str'")
        var b = bytes(data)
        if len(b) % _SIZES[self._tc] != 0:
            raise ValueError("bytes length not a multiple of item size")
        self._a.extend(_unpack(self._tc, b))

    def tobytes(self):
        return _pack(self._tc, self._a)

    def fromlist(self, lst):
        if not isinstance(lst, list):
            raise TypeError("arg must be list")
        var conv = [_conv(self._tc, v) for v in lst]
        self._a.extend(conv)

    def tolist(self):
        return list(self._a)

    def fromunicode(self, s):
        if self._tc != "u":
            raise ValueError("fromunicode() may only be called on unicode type arrays")
        if not isinstance(s, str):
            raise TypeError("fromunicode() argument must be str, not " + type(s).__name__)
        self._a.extend(list(s))

    def tounicode(self):
        if self._tc != "u":
            raise ValueError("tounicode() may only be called on unicode type arrays")
        return "".join(self._a)

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
        return len(self._a)

    def __iter__(self):
        return iter(list(self._a))

    def __contains__(self, v):
        for x in self._a:
            if x == v:
                return true
        return false

    def __getitem__(self, i):
        if isinstance(i, slice):
            return self._new(self._a[i])
        if not (isinstance(i, int) or hasattr(i, "__index__")):
            raise TypeError("array indices must be integers")
        var n = len(self._a)
        var k = int(i)
        if k < 0:
            k = k + n
        if k < 0 or k >= n:
            raise IndexError("array index out of range")
        return self._a[k]

    def __setitem__(self, i, v):
        if isinstance(i, slice):
            if not _is_array(v):
                raise TypeError("can only assign array (not \"" + type(v).__name__ + "\") to array slice")
            if v._tc != self._tc:
                raise TypeError("bad argument type for built-in operation")
            var items = list(v._a)
            var r = i.indices(len(self._a))
            if r[2] != 1:
                var count = len(range(r[0], r[1], r[2]))
                if count != len(items):
                    raise ValueError("attempt to assign array of size " + str(len(items))
                                     + " to extended slice of size " + str(count))
            self._a[i] = items
            return
        var n = len(self._a)
        var k = int(i)
        if k < 0:
            k = k + n
        if k < 0 or k >= n:
            raise IndexError("array assignment index out of range")
        self._a[k] = _conv(self._tc, v)

    def __delitem__(self, i):
        if isinstance(i, slice):
            del self._a[i]
            return
        var n = len(self._a)
        var k = int(i)
        if k < 0:
            k = k + n
        if k < 0 or k >= n:
            raise IndexError("array assignment index out of range")
        del self._a[k]

    def __add__(self, other):
        if not _is_array(other):
            raise TypeError("can only append array (not \"" + type(other).__name__ + "\") to array")
        if other._tc != self._tc:
            raise TypeError("bad argument type for built-in operation")
        return self._new(self._a + other._a)

    def __iadd__(self, other):
        if not _is_array(other):
            raise TypeError("can only extend array with array (not \"" + type(other).__name__ + "\")")
        if other._tc != self._tc:
            raise TypeError("can only extend with array of same kind")
        self._a.extend(list(other._a))
        return self

    def __mul__(self, n):
        if not (isinstance(n, int) or isinstance(n, bool)):
            raise TypeError("can't multiply sequence by non-int of type '" + type(n).__name__ + "'")
        return self._new(self._a * n if n > 0 else [])

    def __rmul__(self, n):
        return self.__mul__(n)

    def __imul__(self, n):
        self._a = self._a * n if n > 0 else []
        return self

    # comparisons item by item (any two arrays, as CPython)
    def _cmp(self, other):
        var a = self._a
        var b = other._a
        var i = 0
        while i < len(a) and i < len(b):
            if a[i] != b[i]:
                return -1 if a[i] < b[i] else 1
            i = i + 1
        return (len(a) > len(b)) - (len(a) < len(b))

    def __eq__(self, other):
        if not _is_array(other):
            return NotImplemented
        return len(self._a) == len(other._a) and self._cmp(other) == 0

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
        if len(self._a) == 0:
            return "array('" + self._tc + "')"
        if self._tc == "u":
            return "array('u', " + repr("".join(self._a)) + ")"
        return "array('" + self._tc + "', " + repr(list(self._a)) + ")"

    def __str__(self):
        return self.__repr__()

    def __bytes__(self):
        return self.tobytes()

    def __copy__(self):
        return self._new(list(self._a))

    def __deepcopy__(self, memo):
        return self._new(list(self._a))

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
