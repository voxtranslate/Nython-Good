# nython: module    (import it by name: it runs in a module scope of its own)
# lib/struct.ny - Python's struct (3.12): bytes <-> packed binary records.
#
#     import struct
#     struct.pack("<hI", -2, 7)              # b'\xfe\xff\x07\x00\x00\x00'
#     struct.unpack(">d", data)              # (3.5,)
#     s = struct.Struct("!4sHH"); s.size; s.pack_into(buf, 2, b"abcd", 1, 2)
#
# pack, unpack, calcsize, iter_unpack, pack_into, unpack_from, Struct and
# struct.error, with Python's format language: a byte order first - "@"
# native order, sizes and alignment (the default), "=" native order with
# standard sizes, "<" little-endian, ">" and "!" big-endian - then codes with
# optional repeat counts (whitespace between them is ignored):
#   x pad byte   c bytes of length 1   b B signed/unsigned char   ? bool
#   h H short    i I int    l L long    q Q long long    n N ssize_t/size_t
#   e f d IEEE 754 half, single, double    s p bytes / Pascal string
#   P void pointer
# n, N and P are native only. Native sizes are this machine's (a long is 8
# bytes on 64-bit Linux and macOS, 4 on Windows and 32-bit builds) and an
# item is aligned to its size, as a C compiler lays out a struct. Integers
# are range checked with Python's messages; floats are encoded exactly
# (rounded half to even into f and e, OverflowError when too large); the
# same bytes come out as CPython's.
#
# Buffers are bytes or bytearray (Nython has no memoryview): pack_into
# writes into a bytearray. Formats are parsed once and cached.
import math
import sys

__all__ = ["calcsize", "pack", "pack_into", "unpack", "unpack_from",
           "iter_unpack", "Struct", "error"]


class error(Exception):
    pass


_IS64 = sys.maxsize > 4294967296
_WINDOWS = sys.platform == "win32"
_NATIVE_LITTLE = getattr(sys, "byteorder", "little") == "little"   # every platform Nython builds for

# native sizes (alignment = size)
_NATIVE_SIZE = {"x": 1, "c": 1, "b": 1, "B": 1, "?": 1, "h": 2, "H": 2, "i": 4, "I": 4,
                "l": 8 if (_IS64 and not _WINDOWS) else 4,
                "L": 8 if (_IS64 and not _WINDOWS) else 4,
                "q": 8, "Q": 8, "n": 8 if _IS64 else 4, "N": 8 if _IS64 else 4,
                "e": 2, "f": 4, "d": 8, "s": 1, "p": 1, "P": 8 if _IS64 else 4}
_STD_SIZE = {"x": 1, "c": 1, "b": 1, "B": 1, "?": 1, "h": 2, "H": 2, "i": 4, "I": 4,
             "l": 4, "L": 4, "q": 8, "Q": 8, "e": 2, "f": 4, "d": 8, "s": 1, "p": 1}
_SIGNED = "bhilqn"
_UNSIGNED = "BHILQNP"


def _tn(x):
    var n = type(x).__name__
    if n == "string":
        return "str"
    if n == "map":
        return "dict"
    if n == "none":
        return "NoneType"
    return n


class _StructLayout:
    # a parsed format: (code, count, offset) items, the total size, the
    # number of values it packs, and its byte order
    def __init__(self, fmt):
        if isinstance(fmt, (bytes, bytearray)):
            fmt = bytes(fmt).decode("latin-1")
        elif not isinstance(fmt, str):
            raise TypeError("Struct() argument 1 must be a str or bytes object, not " + _tn(fmt))
        self.format = fmt
        if "\x00" in fmt:
            raise ValueError("embedded null character")
        var i = 0
        var n = len(fmt)
        var mode = "@"
        if n > 0 and fmt[0] in "@=<>!":
            mode = fmt[0]
            i = 1
        self.native = mode == "@"
        self.little = _NATIVE_LITTLE if mode in "@=" else mode == "<"
        var sizes = _NATIVE_SIZE if self.native else _STD_SIZE
        var items = []
        var size = 0
        var nvalues = 0
        while i < n:
            var c = fmt[i]
            i = i + 1
            if c.isspace():
                continue
            var num = 1
            if c >= "0" and c <= "9":
                num = ord(c) - 48
                while i < n and fmt[i] >= "0" and fmt[i] <= "9":
                    num = num * 10 + ord(fmt[i]) - 48
                    i = i + 1
                if i >= n:
                    raise error("repeat count given without format specifier")
                c = fmt[i]
                i = i + 1
            if c not in sizes:
                raise error("bad char in struct format")
            var isz = sizes[c]
            if self.native and size > 0 and isz > 1 and c not in "spx":
                size = size + (isz - 1) - (size - 1) % isz
            if c == "s" or c == "p":
                items.append((c, num, size))
                nvalues = nvalues + 1
                size = size + num
            elif c == "x":
                size = size + num
            else:
                for k in range(num):
                    items.append((c, 1, size))
                    size = size + isz
                nvalues = nvalues + num
        self.items = items
        self.size = size
        self.nvalues = nvalues
        self.sizes = sizes


_cache = {}


def _layout(fmt):
    var key = fmt
    if isinstance(fmt, (bytes, bytearray)):
        key = "b:" + bytes(fmt).decode("latin-1")
    elif isinstance(fmt, str):
        key = "s:" + fmt
    else:
        return _StructLayout(fmt)
    var l = _cache.get(key)
    if l is None:
        if len(_cache) > 200:
            _cache.clear()
        l = _StructLayout(fmt)
        _cache[key] = l
    return l


# ── integers ─────────────────────────────────────────────────────────────────
def _as_int(v):
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, int):
        return v
    if not isinstance(v, (float, str, bytes, bytearray, list, tuple, dict)) and hasattr(v, "__index__"):
        return v.__index__()
    raise error("required argument is not an integer")


def _pack_int(c, v, size, little):
    v = _as_int(v)
    if c == "P":
        if v < -(1 << (8 * size - 1)) or v >= (1 << (8 * size)):
            raise error("int too large to convert")
        if v < 0:
            v = v + (1 << (8 * size))
        return v.to_bytes(size, "little" if little else "big")
    if c in _SIGNED:
        var lo = -(1 << (8 * size - 1))
        var hi = (1 << (8 * size - 1)) - 1
        if v < lo or v > hi:
            raise error("'" + c + "' format requires " + str(lo) + " <= number <= " + str(hi))
        return v.to_bytes(size, "little" if little else "big", signed=True)
    var top = (1 << (8 * size)) - 1
    if v < 0 or v > top:
        raise error("'" + c + "' format requires 0 <= number <= " + str(top))
    return v.to_bytes(size, "little" if little else "big")


# ── IEEE 754 floats ──────────────────────────────────────────────────────────
# (exponent bits, mantissa bits) for e, f, d
_FLOAT_SHAPE = {"e": (5, 10), "f": (8, 23), "d": (11, 52)}


def _round_shift(n, shift):
    # round(n / 2**shift), ties to even, for n >= 0 (a left shift if shift < 0)
    if shift <= 0:
        return n << (-shift)
    var q = n >> shift
    var rem = n - (q << shift)
    var half = 1 << (shift - 1)
    if rem > half or (rem == half and (q & 1) == 1):
        q = q + 1
    return q


def _float_bits(x, code):
    # the IEEE 754 encoding of float x in format e, f or d, as an int
    var shape = _FLOAT_SHAPE[code]
    var ebits = shape[0]
    var mbits = shape[1]
    var bias = (1 << (ebits - 1)) - 1
    var signbit = 1 << (ebits + mbits)
    var expall = (1 << ebits) - 1
    var sign = signbit if math.copysign(1.0, x) < 0 else 0
    if x != x:
        return sign | (expall << mbits) | (1 << (mbits - 1))
    if x == float("inf") or x == float("-inf"):
        return sign | (expall << mbits)
    x = abs(x)
    if x == 0.0:
        return sign
    var r = x.as_integer_ratio()          # x = r[0] / r[1], r[1] a power of two
    var num = r[0]
    var k = r[1].bit_length() - 1
    var e = num.bit_length() - 1 - k      # 2**e <= x < 2**(e + 1)
    var emin = 1 - bias
    if e < emin:
        # subnormal: a multiple of 2**(emin - mbits); rounding may carry it
        # into the smallest normal number, which the encoding absorbs
        var q = _round_shift(num, k + emin - mbits)
        return sign | q
    var m = _round_shift(num, k + e - mbits)
    if m == (1 << (mbits + 1)):
        m = m >> 1
        e = e + 1
    if e > bias:
        raise OverflowError("float too large to pack with " + code + " format")
    return sign | ((e + bias) << mbits) | (m - (1 << mbits))


def _bits_float(bits, code):
    var shape = _FLOAT_SHAPE[code]
    var ebits = shape[0]
    var mbits = shape[1]
    var bias = (1 << (ebits - 1)) - 1
    var neg = (bits >> (ebits + mbits)) & 1
    var ef = (bits >> mbits) & ((1 << ebits) - 1)
    var mant = bits & ((1 << mbits) - 1)
    var v = 0.0
    if ef == (1 << ebits) - 1:
        v = float("nan") if mant != 0 else float("inf")
    elif ef == 0:
        v = math.ldexp(float(mant), 1 - bias - mbits)
    else:
        v = math.ldexp(float(mant + (1 << mbits)), ef - bias - mbits)
    if neg:
        return math.copysign(v, -1.0)
    return v


def _as_float(v):
    if isinstance(v, float):
        return v
    if isinstance(v, int):
        return float(v)
    if not isinstance(v, (str, bytes, bytearray, list, tuple, dict)) and hasattr(v, "__float__"):
        return float(v)
    if not isinstance(v, (str, bytes, bytearray, list, tuple, dict)) and hasattr(v, "__index__"):
        return float(v.__index__())
    raise error("required argument is not a float")


# ── packing ──────────────────────────────────────────────────────────────────
def _pack_parts(layout, values):
    if len(values) != layout.nvalues:
        raise error("pack expected " + str(layout.nvalues) + " items for packing (got " + str(len(values)) + ")")
    var out = bytearray(layout.size)
    var little = layout.little
    var sizes = layout.sizes
    var vi = 0
    for it in layout.items:
        var c = it[0]
        var off = it[2]
        var v = values[vi]
        vi = vi + 1
        var chunk = b""
        if c == "s" or c == "p":
            if not isinstance(v, (bytes, bytearray)):
                raise error("argument for '" + c + "' must be a bytes object")
            var cnt = it[1]
            if c == "s":
                chunk = bytes(v[:cnt])
            elif cnt > 0:
                var body = bytes(v[:cnt - 1])
                chunk = bytes([min(len(body), 255)]) + body
        elif c == "c":
            if not isinstance(v, (bytes, bytearray)) or len(v) != 1:
                raise error("char format requires a bytes object of length 1")
            chunk = bytes(v)
        elif c == "?":
            chunk = b"\x01" if v else b"\x00"
        elif c == "e" or c == "f" or c == "d":
            var fb = _float_bits(_as_float(v), c)
            chunk = fb.to_bytes(sizes[c], "little" if little else "big")
        else:
            chunk = _pack_int(c, v, sizes[c], little)
        if len(chunk) > 0:
            out[off:off + len(chunk)] = chunk
    return out


def _unpack_at(layout, buf, base):
    var res = []
    var little = layout.little
    var sizes = layout.sizes
    var order = "little" if little else "big"
    for it in layout.items:
        var c = it[0]
        var off = base + it[2]
        if c == "s":
            res.append(bytes(buf[off:off + it[1]]))
        elif c == "p":
            var cnt = it[1]
            if cnt == 0:
                res.append(b"")
            else:
                var ln = buf[off]
                if ln >= cnt:
                    ln = cnt - 1
                res.append(bytes(buf[off + 1:off + 1 + ln]))
        elif c == "c":
            res.append(bytes(buf[off:off + 1]))
        elif c == "?":
            res.append(buf[off] != 0)
        elif c == "e" or c == "f" or c == "d":
            var bits = int.from_bytes(bytes(buf[off:off + sizes[c]]), order)
            res.append(_bits_float(bits, c))
        else:
            res.append(int.from_bytes(bytes(buf[off:off + sizes[c]]), order, signed=c in _SIGNED))
    return tuple(res)


def _check_buffer(buf, what):
    if not isinstance(buf, (bytes, bytearray)):
        raise TypeError("a bytes-like object is required, not '" + _tn(buf) + "'")


def calcsize(fmt):
    return _layout(fmt).size


def pack(fmt, *values):
    return bytes(_pack_parts(_layout(fmt), values))


def unpack(fmt, buffer):
    var layout = _layout(fmt)
    _check_buffer(buffer, "unpack")
    if len(buffer) != layout.size:
        raise error("unpack requires a buffer of " + str(layout.size) + " bytes")
    return _unpack_at(layout, buffer, 0)


def _offset(offset, buflen):
    if offset < 0:
        if offset + buflen < 0:
            raise error("offset " + str(offset) + " out of range for " + str(buflen) + "-byte buffer")
        return offset + buflen
    return offset


def unpack_from(fmt, buffer, offset=0):
    var layout = _layout(fmt)
    _check_buffer(buffer, "unpack_from")
    var n = len(buffer)
    var off = _offset(offset, n)
    if n - off < layout.size:
        if offset < 0:
            raise error("not enough data to unpack " + str(layout.size) + " bytes at offset " + str(offset))
        raise error("unpack_from requires a buffer of at least " + str(layout.size + off) +
                    " bytes for unpacking " + str(layout.size) + " bytes at offset " + str(off) +
                    " (actual buffer size is " + str(n) + ")")
    return _unpack_at(layout, buffer, off)


def pack_into(fmt, buffer, offset, *values):
    var layout = _layout(fmt)
    if not isinstance(buffer, bytearray):
        if isinstance(buffer, bytes):
            raise TypeError("argument must be read-write bytes-like object, not bytes")
        raise TypeError("argument must be read-write bytes-like object, not " + _tn(buffer))
    var data = _pack_parts(layout, values)
    var n = len(buffer)
    var off = offset
    if offset < 0:
        if offset + layout.size > 0:
            raise error("no space to pack " + str(layout.size) + " bytes at offset " + str(offset))
        if offset + n < 0:
            raise error("offset " + str(offset) + " out of range for " + str(n) + "-byte buffer")
        off = offset + n
    if n - off < layout.size:
        raise error("pack_into requires a buffer of at least " + str(layout.size + off) +
                    " bytes for packing " + str(layout.size) + " bytes at offset " + str(off) +
                    " (actual buffer size is " + str(n) + ")")
    buffer[off:off + layout.size] = data


def iter_unpack(fmt, buffer):
    var layout = _layout(fmt)
    _check_buffer(buffer, "iter_unpack")
    if layout.size == 0:
        raise error("cannot iteratively unpack with a struct of length 0")
    if len(buffer) % layout.size != 0:
        raise error("iterative unpacking requires a buffer of a multiple of " + str(layout.size) + " bytes")
    return _StructIter(layout, buffer)


class _StructIter:
    # struct.iter_unpack's iterator (lazy, with __length_hint__)
    def __init__(self, layout, buf):
        self._layout = layout
        self._buf = buf
        self._pos = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._pos + self._layout.size > len(self._buf):
            raise StopIteration
        var r = _unpack_at(self._layout, self._buf, self._pos)
        self._pos = self._pos + self._layout.size
        return r

    def __length_hint__(self):
        return (len(self._buf) - self._pos) // self._layout.size


class Struct:
    # a compiled format: format, size, pack, unpack, pack_into,
    # unpack_from, iter_unpack
    def __init__(self, format):
        self._l = _layout(format)
        self.format = self._l.format
        self.size = self._l.size

    def pack(self, *values):
        return bytes(_pack_parts(self._l, values))

    def unpack(self, buffer):
        return unpack(self.format, buffer)

    def unpack_from(self, buffer, offset=0):
        return unpack_from(self.format, buffer, offset)

    def pack_into(self, buffer, offset, *values):
        pack_into(self.format, buffer, offset, *values)

    def iter_unpack(self, buffer):
        return iter_unpack(self.format, buffer)

    def __repr__(self):
        return "Struct(" + repr(self.format) + ")"
