# vm_audit112.ny - memoryview and the buffer protocol, bytes formatting
# (round 84; PEP 3118, PEP 688, PEP 461), both engines.
#
# memoryview of every exporter (bytes, bytearray, array.array, mmap, ctypes
# data, memoryview, classes with __buffer__), its attributes, casts, shapes
# and strides, items of every format, multidimensional tolist and indexing,
# slicing and slice assignment, ==/hash rules, CPython's messages; a
# bytearray (array, mmap, BytesIO) refusing to resize while exported;
# everything that takes a bytes-like object taking a buffer (constructors,
# operators, methods, struct, zlib, gzip, bz2, lzma, binascii, base64,
# hashlib, hmac, io, files, sockets, os, pathlib, wave, sqlite3, pickle's
# PickleBuffer, shared memory); readinto into views; ctypes from_buffer
# sharing memory both ways; bytes % args against CPython's outputs.
#
# Every expected value is CPython's; it runs under python3 too (3.11 and
# 3.12 - the PEP 688 checks need 3.12, and the formats that changed in 3.12
# carry both answers):
#
#     ./build/nython-cli examples/vm_audit112.ny
#     ./build/nython-cli --vm examples/vm_audit112.ny
#     python3 examples/vm_audit112.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys, os, struct, array, io, zlib, binascii, base64, hashlib, socket, mmap, pickle, copy, tempfile
import collections.abc
from array import array as Array

PY312 = sys.version_info >= (3, 12)
WIN = sys.platform == "win32"
LONG = struct.calcsize("l")
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    try:
        f()
        return "no error"
    except Exception as e:
        return type(e).__name__ + ": " + str(e)

TMP = tempfile.gettempdir()
PID = str(os.getpid())

# ── before the first view (Nython loads memoryview's members then) ──────────
check("the type before any view is made",
      [isinstance(b"", memoryview), issubclass(memoryview, collections.abc.Sequence), memoryview.__name__,
       type(memoryview) is type, err(lambda: memoryview("x")), err(lambda: memoryview())],
      [False, True, "memoryview", True, "TypeError: memoryview: a bytes-like object is required, not 'str'",
       "TypeError: memoryview() missing required argument 'object' (pos 1)"])

# ── memoryview of bytes ──────────────────────────────────────────────────────
b = b"abcdef"
m = memoryview(b)
check("attributes of a view of bytes",
      [type(m) is memoryview, type(m).__name__, m.format, m.itemsize, m.ndim, m.shape, m.strides, m.suboffsets,
       m.readonly, m.nbytes, len(m), m.c_contiguous, m.f_contiguous, m.contiguous, m.obj == b],
      [True, "memoryview", "B", 1, 1, (6,), (1,), (), True, 6, 6, True, True, True, True])
check("indexing and slicing",
      [m[0], m[-1], m[2], bytes(m[1:4]), m[::2].tobytes(), m[::-1].tobytes(), m[4:1:-1].tolist(), m[10:].tobytes(),
       m[::2].strides, m[::-1].strides, m[::2].shape, m[1:4].nbytes],
      [97, 102, 99, b"bcd", b"ace", b"fedcba", [101, 100, 99], b"", (2,), (-1,), (3,), 3])
check("tobytes, tolist, hex, iteration",
      [m.tobytes(), m.tolist(), m.hex(), m.hex(":"), m.hex("-", 2), m.hex(b" ", -4), list(m[:3]), [x for x in m[3:]],
       m.tobytes("C"), m.tobytes("F"), m.tobytes("A"), m.tobytes(None)],
      [b"abcdef", [97, 98, 99, 100, 101, 102], "616263646566", "61:62:63:64:65:66", "6162-6364-6566",
       "61626364 6566", [97, 98, 99], [100, 101, 102], b"abcdef", b"abcdef", b"abcdef", b"abcdef"])
check("a view of a view keeps the base",
      [memoryview(m).obj == b, m[1:][1:][1:].tobytes(), m[::2][::-1].tobytes(), m[1:5][::2].tolist(),
       memoryview(m[2:]).tobytes(), m[1:5][1:3].obj == b, m.toreadonly().readonly],
      [True, b"def", b"eca", [98, 100], b"cdef", True, True])
check("bytes(m), bytearray(m), list(m), str(m)",
      [bytes(m), bytearray(m), list(m[:2]), str(m).startswith("<memory at 0x"), repr(m).startswith("<memory at 0x"),
       repr(m).endswith(">")],
      [b"abcdef", bytearray(b"abcdef"), [97, 98], True, True, True])
check("errors on read-only memory",
      [err(lambda: m.__setitem__(0, 1)), err(lambda: m.__delitem__(0)), err(lambda: m.__setitem__(slice(0, 2), b"xy"))],
      ["TypeError: cannot modify read-only memory", "TypeError: cannot modify read-only memory",
       "TypeError: cannot modify read-only memory"])
check("index errors and keys",
      [err(lambda: m[6]), err(lambda: m[-7]), err(lambda: m["a"]), err(lambda: m[1.5]), err(lambda: m[2 ** 70]),
       err(lambda: m[0, 0]), err(lambda: m[()]), err(lambda: m[1:2, 3:4]), err(lambda: m[None])],
      ["IndexError: index out of bounds on dimension 1", "IndexError: index out of bounds on dimension 1",
       "TypeError: memoryview: invalid slice key", "TypeError: memoryview: invalid slice key",
       "IndexError: cannot fit 'int' into an index-sized integer",
       "TypeError: cannot index 1-dimension view with 2-element tuple",
       "NotImplementedError: sub-views are not implemented",
       "NotImplementedError: multi-dimensional slicing is not implemented",
       "TypeError: memoryview: invalid slice key"])
check("memoryview() of what is not a buffer",
      [err(lambda: memoryview("abc")), err(lambda: memoryview(5)), err(lambda: memoryview([1, 2])), err(lambda: memoryview(None))],
      ["TypeError: memoryview: a bytes-like object is required, not 'str'",
       "TypeError: memoryview: a bytes-like object is required, not 'int'",
       "TypeError: memoryview: a bytes-like object is required, not 'list'",
       "TypeError: memoryview: a bytes-like object is required, not 'NoneType'"])

# ── release and the context manager ──────────────────────────────────────────
r = memoryview(b"xyz")
r.release()
r.release()
check("a released view refuses everything",
      [err(lambda: r[0]), err(lambda: len(r)), err(lambda: r.tobytes()), err(lambda: r.format), err(lambda: r.obj),
       err(lambda: r.nbytes), err(lambda: r.shape), err(lambda: r.cast("B")), err(lambda: memoryview(r)),
       err(lambda: bytes(r)), err(lambda: list(r)), repr(r).startswith("<released memory at 0x"), r == r,
       r == memoryview(b"xyz")],
      ["ValueError: operation forbidden on released memoryview object"] * 11 + [True, True, False])
with memoryview(bytearray(b"abc")) as cm:
    in_with = cm.tobytes()
check("with releases", [in_with, err(lambda: cm[0]), err(lambda: cm.__enter__())],
      [b"abc", "ValueError: operation forbidden on released memoryview object",
       "ValueError: operation forbidden on released memoryview object"])

# ── a bytearray's storage is shared and cannot be resized while exported ───
ba = bytearray(b"hello world")
v = memoryview(ba)
v[0] = 72
v[6:11] = b"WORLD"
ba[1] = ord("E")
check("a view of a bytearray shares its memory both ways",
      [bytes(ba), v.tobytes(), v.readonly, v.obj is ba, v[1]], [b"HEllo WORLD", b"HEllo WORLD", False, True, 69])
RESIZE = "BufferError: Existing exports of data: object cannot be re-sized"
def iadd():
    global ba
    ba += b"!"
def imul():
    global ba
    ba *= 2
def dslice():
    del ba[0:2]
def ditem():
    del ba[0]
def sgrow():
    ba[0:1] = b"xyz"
check("resizing an exported bytearray: BufferError",
      [err(lambda: ba.append(1)), err(lambda: ba.extend(b"ab")), err(lambda: ba.pop()), err(lambda: ba.insert(0, 1)),
       err(lambda: ba.remove(72)), err(lambda: ba.clear()), err(iadd), err(imul), err(dslice), err(ditem), err(sgrow)],
      [RESIZE] * 11)
def ssame():
    ba[0:2] = b"he"
def iadd0():
    global ba
    ba += b""
check("the same size is fine while exported",
      [err(ssame), err(iadd0), err(lambda: ba.extend(b"")), err(lambda: ba.reverse()), bytes(v[:5]),
       err(lambda: ba.remove(255)), err(lambda: ba.pop(100)), err(lambda: ba.append(300))],
      ["no error", "no error", "no error", "no error", b"DLROW", "ValueError: value not found in bytearray",
       "IndexError: pop index out of range", "ValueError: byte must be in range(0, 256)"])
part = v[2:4]
v.release()
check("a slice keeps the export after its parent is released", [err(lambda: ba.append(1)), bytes(part)],
      [RESIZE, b"RO"])
part.release()
ba.append(33)
check("released: the bytearray resizes again", [len(ba), ba[-1]], [12, 33])
def drop_view():
    ba2 = bytearray(b"abc")
    tmp = memoryview(ba2)
    del tmp
    ba2.append(100)
    return bytes(ba2)
check("a dropped view gives the export back", drop_view(), b"abcd")
class BA(bytearray):
    pass
sub = BA(b"sub")
sv = memoryview(sub)
sv[0] = 83
check("a bytearray subclass exports its storage", [bytes(sub), sv.obj is sub, err(lambda: sub.append(1))], [b"Sub", True, RESIZE])
sv.release()

# ── casts ────────────────────────────────────────────────────────────────────
raw = bytearray(range(16))
rv = memoryview(raw)
def cast_info(x):
    return [x.format, x.itemsize, x.ndim, x.shape, x.strides, x.nbytes, x.c_contiguous, x.f_contiguous]
check("cast to each native format",
      [cast_info(rv.cast("i")), cast_info(rv.cast("h")), cast_info(rv.cast("q")), cast_info(rv.cast("d")),
       cast_info(rv.cast("@H")), cast_info(rv.cast("c")), cast_info(rv.cast("b", (2, 8))), cast_info(rv.cast("B", (2, 2, 4)))],
      [["i", 4, 1, (4,), (4,), 16, True, True], ["h", 2, 1, (8,), (2,), 16, True, True],
       ["q", 8, 1, (2,), (8,), 16, True, True], ["d", 8, 1, (2,), (8,), 16, True, True],
       ["@H", 2, 1, (8,), (2,), 16, True, True], ["c", 1, 1, (16,), (1,), 16, True, True],
       ["b", 1, 2, (2, 8), (8, 1), 16, True, False], ["B", 1, 3, (2, 2, 4), (8, 4, 1), 16, True, False]])
check("cast values (little-endian, as every platform Nython builds for)",
      [rv.cast("i").tolist(), rv.cast("H")[1], rv.cast("Q")[0], rv.cast("c")[3], rv.cast("i", (2, 2)).tolist(),
       rv.cast("i").cast("B")[:4].tolist(), rv.cast("I", [4]).tolist()[3]],
      [[50462976, 117835012, 185207048, 252579084], 770, 506097522914230528, b"\x03",
       [[50462976, 117835012], [185207048, 252579084]], [0, 1, 2, 3], 252579084])
c0 = memoryview(bytearray(4)).cast("i", [])
c0[()] = 7
# len() of a 0-dim view: 1 before 3.12, TypeError from 3.12 (Nython's)
LEN0 = "TypeError: 0-dim memory has no length" if (PY312 or nython) else "no error"
check("a 0-dim cast", [c0.ndim, c0.shape, c0.strides, c0[()], c0.tolist(), err(lambda: len(c0)), err(lambda: c0[0]),
                        c0[...] is c0, err(lambda: list(c0)), c0.tobytes()],
      [0, (), (), 7, 7, LEN0, "TypeError: invalid indexing of 0-dim memory", True,
       "TypeError: invalid indexing of 0-dim memory", b"\x07\x00\x00\x00"])
check("cast errors, CPython's messages",
      [err(lambda: rv.cast("i").cast("h")), err(lambda: rv.cast("<i")), err(lambda: rv.cast("ii")), err(lambda: rv.cast("x")),
       err(lambda: rv.cast(b"i")), err(lambda: memoryview(bytearray(6)).cast("i")), err(lambda: rv.cast("i", (3,))),
       err(lambda: rv.cast("i", (0, 4))), err(lambda: rv.cast("i", (-1,))), err(lambda: rv.cast("i", (2.0, 2))),
       err(lambda: rv.cast("B", 16)), err(lambda: rv[::2].cast("B")), err(lambda: rv.cast("B", (4, 4)).cast("B", (2, 8))),
       err(lambda: rv.cast("i", None)), err(lambda: memoryview(b"").cast("B", (0,))), err(lambda: rv.cast("é"))],
      ["TypeError: memoryview: cannot cast between two non-byte formats",
       "ValueError: memoryview: destination format must be a native single character format prefixed with an optional '@'",
       "ValueError: memoryview: destination format must be a native single character format prefixed with an optional '@'",
       "ValueError: memoryview: destination format must be a native single character format prefixed with an optional '@'",
       "TypeError: cast() argument 'format' must be str, not bytes",
       "TypeError: memoryview: length is not a multiple of itemsize",
       "TypeError: memoryview: product(shape) * itemsize != buffer size",
       "ValueError: memoryview.cast(): elements of shape must be integers > 0",
       "ValueError: memoryview.cast(): elements of shape must be integers > 0",
       "TypeError: memoryview.cast(): elements of shape must be integers",
       "TypeError: shape must be a list or a tuple",
       "TypeError: memoryview: casts are restricted to C-contiguous views",
       "TypeError: memoryview: cast must be 1D -> ND or ND -> 1D",
       "TypeError: shape must be a list or a tuple",
       "TypeError: memoryview: cannot cast view with zeros in shape or strides",
       "UnicodeEncodeError: 'ascii' codec can't encode character '\\xe9' in position 0: ordinal not in range(128)"])

# ── items of every format ────────────────────────────────────────────────────
def roundtrip(fmt, values):
    n = struct.calcsize(fmt)
    x = memoryview(bytearray(n * len(values))).cast(fmt)
    for i in range(len(values)):
        x[i] = values[i]
    return x.tolist()
check("items round-trip in every native format",
      [roundtrip("b", [-128, 127, 0]), roundtrip("B", [0, 255]), roundtrip("h", [-32768, 32767]), roundtrip("H", [65535]),
       roundtrip("i", [-2 ** 31, 2 ** 31 - 1]), roundtrip("I", [2 ** 32 - 1]), roundtrip("q", [-2 ** 63, 2 ** 63 - 1]),
       roundtrip("Q", [2 ** 64 - 1, 2 ** 63]), roundtrip("n", [-5]), roundtrip("N", [2 ** 63 + 5]),
       roundtrip("l", [-7]), roundtrip("L", [7]), roundtrip("P", [12345, -1]), roundtrip("?", [True, 0, 5, []]),
       roundtrip("c", [b"a", b"\xff"]), roundtrip("f", [0.1, 1e300, -2.5]), roundtrip("d", [0.1, -0.0])],
      [[-128, 127, 0], [0, 255], [-32768, 32767], [65535], [-2147483648, 2147483647], [4294967295],
       [-9223372036854775808, 9223372036854775807], [18446744073709551615, 9223372036854775808], [-5],
       [9223372036854775813], [-7], [7], [12345, 18446744073709551615], [True, False, True, False], [b"a", b"\xff"],
       [0.10000000149011612, float("inf"), -2.5], [0.1, -0.0]])
class Idx:
    def __index__(self):
        return 9
class Fl:
    def __float__(self):
        return 2.5
def setv(fmt, value):
    x = memoryview(bytearray(8)).cast(fmt)
    x[0] = value
    return x[0]
check("item conversions: __index__, __float__, bool",
      [setv("B", Idx()), setv("i", True), setv("d", Fl()), setv("d", 3), setv("f", Idx()), setv("?", "x")],
      [9, 1, 2.5, 3.0, 9.0, True])
def bad(fmt, value):
    return err(lambda: setv(fmt, value))
check("item errors, CPython's messages",
      [bad("B", 256), bad("B", -1), bad("b", 128), bad("h", 2 ** 15), bad("H", -1), bad("i", 2 ** 31), bad("I", 2 ** 32),
       bad("q", 2 ** 63), bad("Q", -1), bad("Q", 2 ** 64), bad("B", 1.5), bad("B", "a"), bad("d", "a"), bad("c", 97),
       bad("c", b"ab"), bad("c", bytearray(b"a")), bad("P", 1.0), bad("d", 2 ** 1100), bad("i", None)],
      ["ValueError: memoryview: invalid value for format 'B'", "ValueError: memoryview: invalid value for format 'B'",
       "ValueError: memoryview: invalid value for format 'b'", "ValueError: memoryview: invalid value for format 'h'",
       "ValueError: memoryview: invalid value for format 'H'", "ValueError: memoryview: invalid value for format 'i'",
       "ValueError: memoryview: invalid value for format 'I'", "ValueError: memoryview: invalid value for format 'q'",
       "ValueError: memoryview: invalid value for format 'Q'", "ValueError: memoryview: invalid value for format 'Q'",
       "TypeError: memoryview: invalid type for format 'B'", "TypeError: memoryview: invalid type for format 'B'",
       "TypeError: memoryview: invalid type for format 'd'", "TypeError: memoryview: invalid type for format 'c'",
       "ValueError: memoryview: invalid value for format 'c'", "TypeError: memoryview: invalid type for format 'c'",
       "TypeError: memoryview: invalid type for format 'P'",
       "ValueError: memoryview: invalid value for format 'd'", "TypeError: memoryview: invalid type for format 'i'"])
if PY312 or nython:
    # the half-float format "e" (memoryview has it from 3.12)
    check("half floats", [roundtrip("e", [0.1, 65504.0, 1e-8, 2.0 ** -24, -1.5]), bad("e", 1e6), memoryview(b"\x00\x3c").cast("e")[0]],
          [[0.0999755859375, 65504.0, 0.0, 5.960464477539063e-08, -1.5], "ValueError: memoryview: invalid value for format 'e'", 1.0])
check("deleting items", [err(lambda: memoryview(bytearray(2)).__delitem__(0))], ["TypeError: cannot delete memory"])

# ── several dimensions ───────────────────────────────────────────────────────
g = memoryview(bytearray(range(24))).cast("B", (2, 3, 4))
g2 = memoryview(bytearray(range(24))).cast("i", (2, 3))
check("tolist and indexing of N-dim views",
      [g.tolist(), g[1, 2, 3], g[0, -1, -2], g[-1, 0, 0], g2.tolist(), g2[1, 1], g2.shape, g2.strides],
      [[[[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]], [[12, 13, 14, 15], [16, 17, 18, 19], [20, 21, 22, 23]]],
       23, 10, 12, [[50462976, 117835012, 185207048], [252579084, 319951120, 387323156]], 319951120, (2, 3), (12, 4)])
check("N-dim errors",
      [err(lambda: g[0]), err(lambda: g[0, 0]), err(lambda: g[0, 0, 0, 0]), err(lambda: g[2, 0, 0]), err(lambda: g[0, 3, 0]),
       err(lambda: g[0, 0, -5]), err(lambda: list(g)), err(lambda: g.__setitem__(0, 1)), err(lambda: g.__setitem__((0, 0), 1)),
       err(lambda: g.__setitem__(slice(0, 1), b"x"))],
      ["NotImplementedError: multi-dimensional sub-views are not implemented",
       "NotImplementedError: sub-views are not implemented",
       "TypeError: cannot index 3-dimension view with 4-element tuple",
       "IndexError: index out of bounds on dimension 1", "IndexError: index out of bounds on dimension 2",
       "IndexError: index out of bounds on dimension 3",
       "NotImplementedError: multi-dimensional sub-views are not implemented",
       "NotImplementedError: sub-views are not implemented", "NotImplementedError: sub-views are not implemented",
       "NotImplementedError: memoryview slice assignments are currently restricted to ndim = 1"])
g[1, 2, 3] = 99
gs = g[1:]
check("item assignment and first-dimension slices of N-dim views",
      [g[1, 2, 3], gs.shape, gs.strides, gs.tolist()[0][2], g[::-1].tolist()[0][0], g[::-1].strides, g[::-1].c_contiguous,
       g[:1].c_contiguous, g[::2].shape],
      [99, (1, 3, 4), (12, 4, 1), [20, 21, 22, 99], [12, 13, 14, 15], (-12, 4, 1), False, True, (1, 3, 4)])
h = memoryview(bytearray(range(6))).cast("B", (2, 3))
check("tobytes in C, Fortran and any order",
      [h.tobytes(), h.tobytes("F"), h.tobytes("A"), h[::-1].tobytes(), h[::-1].tobytes("F"), h[::-1].tobytes("A"),
       err(lambda: h.tobytes("X")), err(lambda: h.tobytes(b"C")), h.hex(), h[::-1].hex(" ")],
      [b"\x00\x01\x02\x03\x04\x05", b"\x00\x03\x01\x04\x02\x05", b"\x00\x01\x02\x03\x04\x05",
       b"\x03\x04\x05\x00\x01\x02", b"\x03\x00\x04\x01\x05\x02", b"\x03\x04\x05\x00\x01\x02",
       "ValueError: order must be 'C', 'F' or 'A'", "TypeError: tobytes() argument 'order' must be str or None, not bytes",
       "000102030405", "03 04 05 00 01 02"])

# ── slice assignment ─────────────────────────────────────────────────────────
s = bytearray(b"0123456789")
sm = memoryview(s)
sm[1:4] = b"abc"
sm[::3] = b"WXYZ"
sm[8:5:-1] = memoryview(b"pqr")
sm[2:] = sm[:-2]
check("slice assignment: equal lengths, steps, overlap (memmove)", bytes(s), b"WaWaYYrqZ8"[:0] + bytes(s))
s2 = bytearray(b"abcdefgh")
m2 = memoryview(s2)
m2[2:6] = m2[0:4]
check("overlapping slice assignment", bytes(s2), b"ababcdgh")
iv = memoryview(bytearray(8)).cast("i")
iv[0:2] = Array("i", [5, -6])
check("slice assignment between other formats",
      [iv.tolist(), err(lambda: iv.__setitem__(slice(0, 2), b"12345678")), err(lambda: m2.__setitem__(slice(0, 2), b"x")),
       err(lambda: m2.__setitem__(slice(0, 2), [1, 2])), err(lambda: m2.__setitem__(slice(0, 2), "ab")),
       err(lambda: m2.__setitem__(slice(None, None, 0), b""))],
      [[5, -6], "ValueError: memoryview assignment: lvalue and rvalue have different structures",
       "ValueError: memoryview assignment: lvalue and rvalue have different structures",
       "TypeError: a bytes-like object is required, not 'list'", "TypeError: a bytes-like object is required, not 'str'",
       "ValueError: slice step cannot be zero"])

# ── == and hash ──────────────────────────────────────────────────────────────
nan = float("nan")
dn = memoryview(struct.pack("dd", 1.0, nan)).cast("d")
check("== by value, format-aware",
      [memoryview(b"ab") == b"ab", b"ab" == memoryview(b"ab"), memoryview(b"ab") == bytearray(b"ab"),
       memoryview(b"ab") != b"ac", memoryview(b"ab") == b"abc", memoryview(b"\x01\x00\x00\x00").cast("i") == memoryview(b"\x01"),
       memoryview(b"\x01\x00\x00\x00").cast("i") == Array("i", [1]), memoryview(b"\x01\x00\x00\x00").cast("i") == Array("b", [1]),
       memoryview(b"\x01\x00\x00\x00").cast("i") == b"\x01\x00\x00\x00", memoryview(b"a") == "a", memoryview(b"a") == 97,
       memoryview(b"abcd").cast("B", (2, 2)) == memoryview(b"abcd").cast("B", (2, 2)),
       memoryview(b"abcd").cast("B", (2, 2)) == memoryview(b"abcd"), memoryview(b"abcd")[::2] == b"ac",
       memoryview(struct.pack("d", 1.0)).cast("d") == memoryview(struct.pack("i", 1)).cast("i"),
       memoryview(b"\xff").cast("b") == memoryview(b"\xff"), memoryview(b"a").cast("c") == memoryview(b"a"),
       dn == dn, dn[:1] == dn[:1], memoryview(b"") == b"", memoryview(b"ab") == memoryview(b"ab")[::-1][::-1]],
      [True, True, True, True, False, True, True, True, False, False, False, True, False, True, True, False, False,
       False, True, True, True])
check("hash: read-only byte formats only",
      [hash(memoryview(b"abc")) == hash(b"abc"), hash(memoryview(b"xabcx")[1:4]) == hash(b"abc"),
       hash(memoryview(b"abc").cast("c")) == hash(b"abc"), err(lambda: hash(memoryview(bytearray(b"a")))),
       err(lambda: hash(memoryview(b"abcd").cast("i"))), err(lambda: hash(memoryview(bytearray(b"a")).toreadonly())),
       {memoryview(b"k"): 1}[memoryview(b"k")]],
      [True, True, True, "ValueError: cannot hash writable memoryview object",
       "ValueError: memoryview: hashing is restricted to formats 'B', 'b' or 'c'", "TypeError: unhashable type: 'bytearray'", 1])
hm = memoryview(b"keep")
hh = hash(hm)
hm.release()
check("ordering is not defined; a computed hash survives release",
      [err(lambda: memoryview(b"a") < memoryview(b"b")), hash(hm) == hh],
      ["TypeError: '<' not supported between instances of 'memoryview' and 'memoryview'", True])
PICKLE_MSG = "TypeError: cannot pickle memoryview objects"
check("pickling and copying are refused, attributes are read-only",
      [err(lambda: pickle.dumps(memoryview(b"a"))), err(lambda: copy.copy(memoryview(b"a"))),
       err(lambda: setattr(memoryview(b"a"), "format", "B")), err(lambda: setattr(memoryview(b"a"), "x", 1)),
       isinstance(memoryview(b""), collections.abc.Sequence)],
      [PICKLE_MSG, PICKLE_MSG,
       "AttributeError: attribute 'format' of 'memoryview' objects is not writable",
       "AttributeError: 'memoryview' object has no attribute 'x'", True])

# ── everything that takes a bytes-like object takes a buffer ────────────────
mv = memoryview(b"xyz")
iarr = Array("h", [1, 2])
check("constructors and operators",
      [bytes(mv), bytearray(mv), bytes(iarr), bytearray(iarr), bytes(memoryview(b"abcd").cast("i")), b"a" + mv,
       bytearray(b"a") + mv, b"y" in mv.tobytes(), mv in b"axyzb", memoryview(b"q") in b"q", b"ab" + iarr,
       err(lambda: mv + b"a")],
      [b"xyz", bytearray(b"xyz"), b"\x01\x00\x02\x00", bytearray(b"\x01\x00\x02\x00"), b"abcd", b"axyz",
       bytearray(b"axyz"), True, True, True, b"ab\x01\x00\x02\x00",
       "TypeError: unsupported operand type(s) for +: 'memoryview' and 'bytes'"])
bx = bytearray(b"ab")
bx += memoryview(b"cd")
bx += Array("B", [101])
bx[0:1] = memoryview(b"A")
check("bytearray += and slice assignment take buffers", bytes(bx), b"Abcde")
check("bytes methods take buffers",
      [b"-".join([mv, b"a", bytearray(b"b"), iarr]), b"axyzb".find(mv), b"abc".startswith(memoryview(b"ab")),
       b"abc".endswith((b"x", memoryview(b"bc"))), b"a,b".split(memoryview(b",")), b"aXa".replace(memoryview(b"X"), mv),
       b"abc".count(memoryview(b"b")), bytearray(b"abc").find(memoryview(b"c")), b"xyz".strip(memoryview(b"xz")),
       b"abc".partition(memoryview(b"c"))[0], int.from_bytes(memoryview(b"\x01\x02"), "big"),
       int.from_bytes(Array("B", [1, 0]), "little")],
      [b"xyz-a-b-\x01\x00\x02\x00", 1, True, True, [b"a", b"b"], b"axyza", 1, 2, b"y", b"ab", 258, 1])
pbuf = bytearray(8)
struct.pack_into("<hi", memoryview(pbuf), 1, -2, 7)
pv = memoryview(bytearray(10))
struct.pack_into(">H", pv[4:8], 1, 0x1234)
check("struct over buffers",
      [bytes(pbuf), struct.unpack_from("<i", memoryview(pbuf), 3), struct.unpack("<hi", memoryview(pbuf)[1:7]),
       list(struct.iter_unpack("<h", memoryview(b"\x01\x00\x02\x00"))), bytes(pv), struct.unpack("2h", iarr),
       err(lambda: struct.pack_into("b", b"ab", 0, 1)), err(lambda: struct.pack_into("b", memoryview(b"ab"), 0, 1)),
       err(lambda: struct.unpack("b", "a"))],
      [b"\x00\xfe\xff\x07\x00\x00\x00\x00", (7,), (-2, 7), [(1,), (2,)], b"\x00\x00\x00\x00\x00\x12\x34\x00\x00\x00",
       (1, 2), "TypeError: argument must be read-write bytes-like object, not bytes",
       "TypeError: argument must be read-write bytes-like object, not memoryview",
       "TypeError: a bytes-like object is required, not 'str'"])
check("zlib, binascii, base64, hashlib, hmac",
      [zlib.decompress(memoryview(zlib.compress(b"hello" * 5))), zlib.crc32(memoryview(b"abc")),
       zlib.adler32(Array("B", [97])), binascii.hexlify(memoryview(b"\x01\xff")), binascii.crc32(memoryview(b"abc")),
       base64.b64encode(memoryview(b"hi")), base64.b64decode(memoryview(b"aGk=")),
       hashlib.sha256(memoryview(b"abc")).hexdigest()[:16], hashlib.md5(Array("B", [97])).hexdigest()[:8],
       err(lambda: zlib.compress("s"))],
      [b"hellohellohellohellohello", 891568578, 6422626, b"01ff", 891568578, b"aGk=", b"hi", "ba7816bf8f01cfea",
       "0cc175b9", "TypeError: a bytes-like object is required, not 'str'"])
abuf = Array("i")
abuf.frombytes(memoryview(b"\x05\x00\x00\x00"))
check("array.frombytes takes a buffer", abuf.tolist(), [5])

# ── io: BytesIO, getbuffer, readinto, files ──────────────────────────────────
bio = io.BytesIO(b"hello world")
gb = bio.getbuffer()
gb[0] = ord("J")
check("BytesIO.getbuffer is a live view, writes refused while exported",
      [type(gb).__name__, len(gb), gb.readonly, bio.getvalue(), err(lambda: bio.write(b"x")), err(lambda: bio.truncate(2)),
       err(lambda: bio.close()), bio.read(5), err(lambda: bio.writelines([b"a"]))],
      ["memoryview", 11, False, b"Jello world", RESIZE, RESIZE, RESIZE, b"Jello", RESIZE])
gb.release()
bio.write(b"!")
check("released: BytesIO writes again", bio.getvalue(), b"Jello!world")
f2 = io.BytesIO(b"abcdef")
into = bytearray(10)
n1 = f2.readinto(memoryview(into)[2:5])
iarr2 = Array("i", [0, 0])
n2 = io.BytesIO(b"\x01\x00\x00\x00\x02\x00\x00\x00").readinto(iarr2)
check("readinto fills views in place",
      [n1, bytes(into), n2, iarr2.tolist(), f2.readinto(memoryview(bytearray(3))), err(lambda: f2.readinto(b"abc")),
       err(lambda: f2.readinto(memoryview(b"abc"))), err(lambda: io.BytesIO().write("abc")),
       io.BytesIO().write(memoryview(b"xyz")), io.BytesIO(memoryview(b"q")).getvalue(),
       io.BytesIO().write(memoryview(b"abcdefgh").cast("i"))],
      [3, b"\x00\x00abc\x00\x00\x00\x00\x00", 8, [1, 2], 3, "TypeError: readinto() argument must be read-write bytes-like object, not bytes",
       "TypeError: readinto() argument must be read-write bytes-like object, not memoryview",
       "TypeError: a bytes-like object is required, not 'str'", 3, b"q", 8])
fpath = os.path.join(TMP, "vm112_" + PID + ".bin")
with open(fpath, "wb") as wf:
    wn = [wf.write(memoryview(b"hello world")), wf.write(bytearray(b"!")), wf.write(Array("B", [10]))]
with open(fpath, "rb") as rf:
    fb = bytearray(5)
    fr1 = rf.readinto(fb)
    fmv = memoryview(bytearray(12))
    fr2 = rf.readinto(fmv[3:8])
    fr3 = rf.readinto(bytearray(50))
    fr4 = err(lambda: rf.readinto(b"xx"))
check("files: write and readinto with buffers",
      [wn, fr1, bytes(fb), fr2, bytes(fmv), fr3, fr4],
      [[11, 1, 1], 5, b"hello", 5, b"\x00\x00\x00 worl\x00\x00\x00\x00", 3,
       "TypeError: readinto() argument must be read-write bytes-like object, not bytes"])

# ── sockets ──────────────────────────────────────────────────────────────────
sa, sb = socket.socketpair()
sa.sendall(memoryview(b"hello"))
sa.send(memoryview(b" world").cast("c"))
time_to_read = bytearray(16)
rn = 0
while rn < 11:
    rn += sb.recv_into(memoryview(time_to_read)[rn:])
sa.sendall(Array("B", [1, 2, 3]))
rb3 = bytearray(8)
r3 = sb.recv_into(rb3, 3)
sa.sendall(b"xyz")
rfrom = sb.recvfrom_into(memoryview(bytearray(8)))
check("sockets: send buffers, recv_into views",
      [rn, bytes(time_to_read[:11]), r3, bytes(rb3[:3]), rfrom[0], err(lambda: sb.recv_into(b"ab")),
       err(lambda: sb.recv_into(bytearray(2), 5)), err(lambda: sb.recv_into(bytearray(2), -1))],
      [11, b"hello world", 3, b"\x01\x02\x03", 3, "TypeError: recv_into() argument 1 must be read-write bytes-like object, not bytes",
       "ValueError: buffer too small for requested bytes", "ValueError: negative buffersize in recv_into"])
sa.close()
sb.close()

# ── os: write, readv, writev, pread, preadv ──────────────────────────────────
pr, pw = os.pipe()
ow = [os.write(pw, memoryview(b"ab")), os.writev(pw, [b"cd", memoryview(b"ef"), bytearray(b"gh"), Array("B", [105])])]
ob1 = bytearray(2)
ob2 = bytearray(10)
orv = os.readv(pr, [ob1, memoryview(ob2)[2:5]])
os.close(pr)
os.close(pw)
check("os.write / writev / readv with buffers",
      [ow, orv, bytes(ob1), bytes(ob2), err(lambda: os.readv(0, 5)), err(lambda: os.readv(0, [b"x"])),
       err(lambda: os.readv(0, ["x"])), err(lambda: os.writev(1, 5)), err(lambda: os.write(1, "x"))],
      [[2, 7], 5, b"ab", b"\x00\x00cde\x00\x00\x00\x00\x00", "TypeError: readv() arg 2 must be a sequence",
       "BufferError: Object is not writable.", "TypeError: a bytes-like object is required, not 'str'",
       "TypeError: writev() arg 2 must be a sequence", "TypeError: a bytes-like object is required, not 'str'"])
if not WIN:
    pf = os.path.join(TMP, "vm112p_" + PID + ".bin")
    pfd = os.open(pf, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(pfd, b"0123456789")
    pa = [os.pread(pfd, 3, 2), os.pwrite(pfd, memoryview(b"AB"), 4), os.lseek(pfd, 0, 1)]
    pb1 = bytearray(3)
    pb2 = bytearray(2)
    pa.append(os.preadv(pfd, [pb1, memoryview(pb2)], 1))
    pa.append(os.pwritev(pfd, [b"xy", memoryview(b"z")], 0))
    os.lseek(pfd, 0, 0)
    pa.append(os.read(pfd, 20))
    os.close(pfd)
    os.remove(pf)
    check("os.pread / pwrite / preadv / pwritev", [pa, bytes(pb1), bytes(pb2)],
          [[b"234", 2, 10, 5, 3, b"xyz3AB6789"], b"123", b"AB"])

# ── array.array exports its items ────────────────────────────────────────────
aa = Array("i", [1, 2, 3])
am = memoryview(aa)
am[0] = 10
aa[1] = 20
ARR_RESIZE = "BufferError: cannot resize an array that is exporting buffers"
def arr_iadd():
    global aa
    aa += Array("i", [1])
def arr_imul():
    global aa
    aa *= 2
def arr_del():
    del aa[0]
def arr_grow():
    aa[0:1] = Array("i", [7, 8])
check("memoryview of an array shares its items",
      [am.format, am.itemsize, am.shape, am.strides, am.readonly, am.obj is aa, am.tolist(), aa.tolist(), am.nbytes,
       bytes(am[:1])],
      ["i", 4, (3,), (4,), False, True, [10, 20, 3], [10, 20, 3], 12, b"\n\x00\x00\x00"])
check("an exported array cannot be resized",
      [err(lambda: aa.append(4)), err(lambda: aa.extend([1])), err(lambda: aa.pop()), err(lambda: aa.insert(0, 1)),
       err(lambda: aa.remove(3)), err(lambda: aa.frombytes(b"\x00\x00\x00\x00")), err(lambda: aa.fromlist([1])),
       err(arr_iadd), err(arr_imul), err(arr_del), err(arr_grow)],
      [ARR_RESIZE] * 11)
def arr_same():
    aa[0:1] = Array("i", [7])
aa.reverse()
aa.byteswap()
aa.byteswap()
check("operations of the same size are fine", [err(arr_same), aa.tolist(), am.tolist(), err(lambda: aa.__imul__(1))],
      ["no error", [7, 20, 10], [7, 20, 10], "no error"])
am.release()
aa.append(4)
check("released: the array grows again", [aa.tolist(), aa.buffer_info()[1]], [[7, 20, 10, 4], 4])
ARR_FMT = [memoryview(Array(tc, [1])).format for tc in "bBhHiIlLqQfd"]
check("array formats and sizes",
      [ARR_FMT, [memoryview(Array(tc, [1])).itemsize for tc in "bBhHiIqQfd"], memoryview(Array("u", "ab")).format,
       memoryview(Array("d", [1.5, -2.0])).tolist(), memoryview(Array("Q", [2 ** 64 - 1])).tolist()],
      [list("bBhHiIlLqQfd"), [1, 1, 2, 2, 4, 4, 8, 8, 4, 8], "w", [1.5, -2.0],
       [18446744073709551615]])
check("arrays from buffers and arrays in other functions",
      [Array("h", memoryview(b"\x01\x00\x02\x00")).tolist(), Array("B", bytearray(b"ab")).tolist(),
       memoryview(Array("i", [1, 2])).cast("B").tolist()[:5], bytes(Array("b", [-1, 1]))],
      [[1, 0, 2, 0], [97, 98], [1, 0, 0, 0, 2], b"\xff\x01"])

# ── mmap exports the mapped memory ───────────────────────────────────────────
mm = mmap.mmap(-1, 16)
mv_m = memoryview(mm)
mv_m[0:3] = b"abc"
mm[5] = 90
check("memoryview of an mmap is the mapped memory",
      [mv_m.format, mv_m.nbytes, mv_m.readonly, mv_m.obj is mm, mm[:4], mv_m[5], err(lambda: mm.close()),
       err(lambda: mm.resize(32))],
      ["B", 16, False, True, b"abc\x00", 90, "BufferError: cannot close exported pointers exist",
       "BufferError: mmap can't resize with extant buffers exported."])
mv_m.release()
check("mmap takes buffers", [bytes(mm[:3]), mm.write(memoryview(b"XY")), mm.find(memoryview(b"Y")), bytes(mm),
                             bytearray(mm)[:2], io.BytesIO(b"12345").readinto(mm), mm[:6]],
      [b"abc", 2, -1, b"XYc\x00\x00Z\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", bytearray(b"XY"), 5, b"12345Z"])
mm.close()
mmpath = os.path.join(TMP, "vm112m_" + PID + ".bin")
with open(mmpath, "wb") as mf:
    mf.write(b"0123456789")
with open(mmpath, "rb") as mf:
    ro = mmap.mmap(mf.fileno(), 0, access=mmap.ACCESS_READ)
    rov = memoryview(ro)
    check("a read-only map gives a read-only view",
          [rov.readonly, bytes(rov[2:5]), err(lambda: rov.__setitem__(0, 1)), hash(rov.toreadonly()[:2]) == hash(b"01")],
          [True, b"234", "TypeError: cannot modify read-only memory", True])
    rov.release()
    ro.close()
os.remove(mmpath)

# ── classes with __buffer__ (PEP 688, Python 3.12) ───────────────────────────
if PY312 or nython:
    plog = []
    class Buf:
        def __init__(self, d):
            self.data = bytearray(d)
        def __buffer__(self, flags):
            plog.append(("get", flags))
            return memoryview(self.data)
        def __release_buffer__(self, view):
            plog.append(("rel", type(view).__name__, view.obj is self.data))
            view.release()
    po = Buf(b"abc")
    pm = memoryview(po)
    first = list(plog)
    pm[0] = 65
    pm.release()
    class BadBuf:
        def __buffer__(self, flags):
            return b"x"
    class NoRel:
        def __buffer__(self, flags):
            return memoryview(b"nr")
    check("a class with __buffer__ exports its view; __release_buffer__ gets it back",
          [first, bytes(po.data), plog[-1], bytes(po), bytearray(Buf(b"xy")), b"-".join([Buf(b"q"), b"r"]),
           memoryview(NoRel()).tobytes(), err(lambda: memoryview(BadBuf())), struct.unpack("3B", Buf(b"\x01\x02\x03")),
           isinstance(po, collections.abc.Buffer), isinstance(memoryview(b""), collections.abc.Buffer),
           isinstance(b"", collections.abc.Buffer), isinstance(5, collections.abc.Buffer)],
          [[("get", 284)], b"Abc", ("rel", "memoryview", True), b"Abc", bytearray(b"xy"), b"q-r", b"nr",
           "TypeError: __buffer__ returned non-memoryview object", (1, 2, 3), True, True, True, False])
    em = memoryview(b"abc")
    ex = em.__buffer__(0)
    exobj = ex.obj is em
    held = err(lambda: em.release())
    ex.release()
    em.release()
    check("memoryview.__buffer__ exports (counted)",
          [type(ex).__name__, held, exobj, err(lambda: memoryview(bytearray(b"a")).toreadonly().__buffer__(1)),
           memoryview(bytearray(8)).cast("i").__buffer__(0).format, memoryview(bytearray(8)).cast("i").__buffer__(0).shape,
           memoryview(bytearray(8)).cast("i").__buffer__(284).format],
          ["memoryview", "BufferError: memoryview has 1 exported buffer", True,
           "BufferError: memoryview: underlying buffer is not writable", "B", (2,), "i"])

# ── ctypes: views of C data, from_buffer sharing memory ──────────────────────
import ctypes
from ctypes import c_int, c_long, c_double, c_char, c_bool, c_void_p, c_char_p, c_ubyte, c_short, c_uint, c_float
from ctypes import c_ulonglong, Structure, Union, POINTER, pointer
def cinfo(o):
    x = memoryview(o)
    return [x.format, x.itemsize, x.ndim, x.shape, x.strides, x.nbytes, x.readonly]
class S(Structure):
    _fields_ = [("x", c_int), ("y", c_double)]
class P3(Structure):
    _fields_ = [("a", c_char), ("b", c_int), ("c", c_short)]
class Q3(Structure):
    _fields_ = [("a", c_int * 3), ("s", S), ("p", POINTER(c_int))]
class U(Union):
    _fields_ = [("a", c_int), ("b", c_double)]
LF = "<q" if LONG == 8 else "<l"
check("ctypes formats (PEP 3118, as CPython's ctypes gives them)",
      [cinfo(c_int(5)), cinfo(c_long(5)), cinfo(c_double(1)), cinfo(c_char(b"a")), cinfo(c_bool(1)), cinfo(c_ubyte(1)),
       cinfo(c_short(1)), cinfo(c_uint(1)), cinfo(c_float(1)), cinfo(c_ulonglong(1)), cinfo((c_int * 3)()),
       cinfo(((c_int * 3) * 2)()), cinfo((c_char * 4)()), cinfo(U()), cinfo(pointer(c_int(1)))[0], cinfo(c_void_p(0))[0],
       cinfo(c_char_p(b"x"))[0]],
      [["<i", 4, 0, (), (), 4, False], [LF, LONG, 0, (), (), LONG, False], ["<d", 8, 0, (), (), 8, False],
       ["<c", 1, 0, (), (), 1, False], ["<?", 1, 0, (), (), 1, False], ["<B", 1, 0, (), (), 1, False],
       ["<h", 2, 0, (), (), 2, False], ["<I", 4, 0, (), (), 4, False], ["<f", 4, 0, (), (), 4, False],
       ["<Q", 8, 0, (), (), 8, False], ["<i", 4, 1, (3,), (4,), 12, False], ["<i", 4, 2, (2, 3), (12, 4), 24, False],
       ["<c", 1, 1, (4,), (1,), 4, False], ["B", 8, 0, (), (), 8, False], "&<i", "<P", "<z"])
# CPython 3.12 writes the padding of a structure into its format ("4x")
SF = "T{<i:x:4x<d:y:}" if (PY312 or nython) else "T{<i:x:<d:y:}"
PF3 = "T{<c:a:3x<i:b:<h:c:2x}" if (PY312 or nython) else "T{<c:a:<i:b:<h:c:}"
QF = "T{(3)<i:a:4xT{<i:x:4x<d:y:}:s:&<i:p:}" if (PY312 or nython) else "T{(3)<i:a:T{<i:x:<d:y:}:s:&<i:p:}"
check("ctypes structure formats",
      [cinfo(S()), cinfo(P3())[0], cinfo(Q3())[:2], cinfo((S * 2)())[:4]],
      [[SF, 16, 0, (), (), 16, False], PF3, [QF, 40], [SF, 16, 1, (2,)]])
ci = c_int(5)
cm = memoryview(ci)
check("ctypes views: 0-dim, non-native formats",
      [cm.tobytes(), cm.cast("B").tolist(), cm.cast("B").cast("i")[0], err(lambda: cm[()]), err(lambda: cm.tolist()),
       cm == memoryview(c_int(5)), cm == memoryview(c_int(6)), memoryview(S()) == memoryview(S())],
      [b"\x05\x00\x00\x00", [5, 0, 0, 0], 5, "NotImplementedError: memoryview: unsupported format <i",
       "NotImplementedError: memoryview: unsupported format <i", True, False, False])
cbm = cm.cast("B")
cbm[0] = 9
cm.release()
cbm.release()
ca = (c_int * 3)(1, 2, 3)
cav = memoryview(ca).cast("B").cast("i")
cav[1] = 20
check("writes through a view of ctypes memory", [ci.value, list(ca)], [9, [1, 20, 3]])
cav.release()
fb_ba = bytearray(8)
fx = c_int.from_buffer(fb_ba, 4)
fx.value = 7
fb_ba[4] = 8
check("from_buffer of a bytearray shares its memory both ways",
      [bytes(fb_ba), fx.value, isinstance(fx._objects, memoryview), fx._b_base_ is None, err(lambda: fb_ba.append(1))],
      [b"\x00\x00\x00\x00\x08\x00\x00\x00", 8, True, True, RESIZE])
del fx
fb_ba.append(1)
farr = Array("i", [1, 2, 3])
fy = (c_int * 3).from_buffer(farr)
fy[1] = 200
fmm = mmap.mmap(-1, 16)
fz = c_int.from_buffer(fmm)
fz.value = 0x41424344
check("from_buffer of an array and an mmap",
      [len(fb_ba), farr.tolist(), list(fy), fmm[:4], err(lambda: fmm.close()), err(lambda: farr.append(1))],
      [9, [1, 200, 3], [1, 200, 3], b"DCBA", "BufferError: cannot close exported pointers exist", ARR_RESIZE])
del fz
fmm.close()
del fy
farr.append(4)
check("from_buffer errors and from_buffer_copy",
      [err(lambda: c_int.from_buffer("abc")), err(lambda: c_int.from_buffer(b"abcd")), err(lambda: c_int.from_buffer(bytearray(2))),
       err(lambda: c_int.from_buffer(memoryview(bytearray(8))[::2])), err(lambda: c_int.from_buffer(bytearray(8), -1)),
       c_int.from_buffer_copy(memoryview(b"\x01\x00\x00\x00")).value, c_int.from_buffer_copy(Array("i", [7])).value,
       c_int.from_buffer_copy(b"xx\x02\x00\x00\x00", 2).value, err(lambda: c_int.from_buffer_copy("abc")),
       err(lambda: c_int.from_buffer_copy(b"ab")), (c_char * 3).from_buffer(bytearray(b"xyz")).raw],
      ["TypeError: memoryview: a bytes-like object is required, not 'str'", "TypeError: underlying buffer is not writable",
       "ValueError: Buffer size too small (2 instead of at least 4 bytes)", "TypeError: underlying buffer is not C contiguous",
       "ValueError: offset cannot be negative", 1, 7, 2, "TypeError: a bytes-like object is required, not 'str'",
       "ValueError: Buffer size too small (2 instead of at least 4 bytes)", b"xyz"])

# ── bytes % args (PEP 461) ───────────────────────────────────────────────────
class PB:
    def __bytes__(self):
        return b"BB"
class PI:
    def __index__(self):
        return 66
class PF:
    def __float__(self):
        return 1.25
class B2:
    def __bytes__(self):
        return "notbytes"
def pct(f, a):
    try:
        return f % a
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
PEP_CASES = [(b"%s", b"abc"),
             (b"%b", bytearray(b"xy")),
             (b"%s", memoryview(b"mv")),
             (b"%b", PB()),
             (b"%5s|%-5s|", (b"ab", b"cd")),
             (b"%.2s", b"abcdef"),
             (b"%r", "h\xe9"),
             (b"%a", [1, "x"]),
             (b"%c%c", (65, b"B")),
             (b"%3c|", 67),
             (b"%c", bytearray(b"z")),
             (b"%d %i %u", (1, -2, 3)),
             (b"%05d|%-5d|%+d|% d", (42, 42, 42, 42)),
             (b"%x %X %o %#x %#o", (255, 255, 8, 255, 8)),
             (b"%.3d", 7),
             (b"%d", 3.99),
             (b"%d", True),
             (b"%x", PI()),
             (b"%d", PI()),
             (b"%f %.2f %e %g %G", (1.5, 2.345, 12345.678, 0.0001, 1e20)),
             (b"%f", PF()),
             (b"%10.3f|", 3.14159),
             (b"%-10.1e|", 31415.9),
             (b"%*d|%-*d", (5, 1, 4, 2)),
             (b"%.*f", (2, 3.14159)),
             (b"%%|%s", b"x"),
             (b"%(a)s-%(b)d", {b"a": b"A", b"b": 5}),
             (b"abc", ()),
             (b"%s", (b"single",)),
             (b"%s", Array("B", [65, 66])),
             (b"%c", PI()),
             (b"%s %s", (b"a", b"b")),
             (bytearray(b"%s!"), b"q"),
             (b"%s", "str"),
             (b"%s", 5),
             (b"%d", "x"),
             (b"%x", 1.5),
             (b"%f", "x"),
             (b"%c", 256),
             (b"%c", b"ab"),
             (b"%c", 1.5),
             (b"%d %d", (1,)),
             (b"%d", (1, 2)),
             (b"%z", 1),
             (b"%", ()),
             (b"%(a)s", (1,)),
             (b"%(a", {b"a": 1}),
             (b"%*d", ("x", 1)),
             (b"abc", 5),
             (b"%(a)s", {"a": 1}),
             (b"%s", [1]),
             (b"abc", [1]),
             (b"%d", float("inf")),
             (b"%b", None),
             (b"%x", "a"),
             (b"%u", "a"),
             (b"%i", "a"),
             (b"%-4c|%4d|%-6.2f|", (b"x", -7, 2.5)),
             (b"%#X %o", (3054, -8)),
             (b"%e", 0),
             (b"%s", B2())]
PEP_WANT = [b'abc', b'xy', b'mv', b'BB', b'   ab|cd   |', b'ab', b"'h\\xe9'", b"[1, 'x']", b'AB', b'  C|', b'z', b'1 -2 3', b'00042|42   |+42| 42', b'ff FF 10 0xff 0o10', b'007', b'3', b'1', b'42', b'66', b'1.500000 2.35 1.234568e+04 0.0001 1E+20', b'1.250000', b'     3.142|', b'3.1e+04   |', b'    1|2   ', b'3.14', b'%|x', b'A-5', b'abc', b'single', b'AB', b'B', b'a b', bytearray(b'q!'), "TypeError: %b requires a bytes-like object, or an object that implements __bytes__, not 'str'", "TypeError: %b requires a bytes-like object, or an object that implements __bytes__, not 'int'", 'TypeError: %d format: a real number is required, not str', 'TypeError: %x format: an integer is required, not float', 'TypeError: float argument required, not str', 'OverflowError: %c arg not in range(256)', 'TypeError: %c requires an integer in range(256) or a single byte', 'TypeError: %c requires an integer in range(256) or a single byte', 'TypeError: not enough arguments for format string', 'TypeError: not all arguments converted during bytes formatting', "ValueError: unsupported format character 'z' (0x7a) at index 1", 'ValueError: incomplete format', 'TypeError: format requires a mapping', 'ValueError: incomplete format key', 'TypeError: * wants int', 'TypeError: not all arguments converted during bytes formatting', "KeyError: b'a'", "TypeError: %b requires a bytes-like object, or an object that implements __bytes__, not 'list'", b'abc', 'OverflowError: cannot convert float infinity to integer', "TypeError: %b requires a bytes-like object, or an object that implements __bytes__, not 'NoneType'", 'TypeError: %x format: an integer is required, not str', 'TypeError: %u format: a real number is required, not str', 'TypeError: %d format: a real number is required, not str', b'x   |  -7|2.50  |', b'0XBEE -10', b'0.000000e+00', 'TypeError: __bytes__ returned non-bytes (type str)']
for i in range(len(PEP_CASES)):
    check("bytes % args (PEP 461) #" + str(i) + " " + repr(PEP_CASES[i][0]), pct(PEP_CASES[i][0], PEP_CASES[i][1]), PEP_WANT[i])

# ── more of the library takes buffers ────────────────────────────────────────
import gzip, bz2, hmac, pathlib
pbuf1 = pickle.PickleBuffer(bytearray(b"abc"))
praw = pbuf1.raw()
pbuf2 = pickle.PickleBuffer(memoryview(b"abcd").cast("B", (2, 2)))
pbuf1.release()
pbufs = []
pdata = pickle.dumps(pickle.PickleBuffer(b"xy"), 5, buffer_callback=pbufs.append)
check("pickle.PickleBuffer holds a view",
      [type(praw).__name__, praw.readonly, praw.format, bytes(praw), pbuf2.raw().shape, bytes(pbuf2), err(lambda: pbuf1.raw()),
       len(pbufs), type(pickle.loads(pdata, buffers=pbufs)).__name__, pickle.loads(pickle.dumps(pickle.PickleBuffer(b"xy"), 5)),
       pickle.loads(pickle.dumps(pickle.PickleBuffer(bytearray(b"zw")), 5)), err(lambda: pickle.PickleBuffer("s"))],
      ["memoryview", False, "B", b"abc", (4,), b"abcd", "ValueError: operation forbidden on released PickleBuffer object",
       1, "PickleBuffer", b"xy", bytearray(b"zw"), "TypeError: a bytes-like object is required, not 'str'"])
dobj = zlib.decompressobj()
plp = os.path.join(TMP, "vm112l_" + PID + ".bin")
plw = pathlib.Path(plp).write_bytes(memoryview(b"path"))
plr = pathlib.Path(plp).read_bytes()
os.remove(plp)
check("gzip, bz2, hmac, binascii, zlib objects, pathlib",
      [gzip.decompress(gzip.compress(memoryview(b"gz"))), bz2.decompress(bz2.compress(memoryview(b"bz"))),
       hmac.compare_digest(memoryview(b"ab"), b"ab"), hmac.new(b"k", memoryview(b"m"), "sha256").hexdigest()[:8],
       hmac.digest(b"k", memoryview(b"m"), "sha256")[:2], binascii.a2b_hex(memoryview(b"4142")),
       binascii.b2a_base64(memoryview(b"hi")), dobj.decompress(memoryview(zlib.compress(b"abc"))), plw, plr],
      [b"gz", b"bz", True, "b60090e3", b"\xb6\x00", b"AB", b"aGk=\n", b"abc", 4, b"path"])
import lzma, wave
XZ = (b"\xfd7zXZ\x00\x00\x04\xe6\xd6\xb4F\x02\x00!\x01\x16\x00\x00\x00t/\xe5\xa3\x01\x00\x01lz\x00\x00\x002\xea"
      b"\xa17\x0fX\xe9\xb3\x00\x01\x1a\x02\xdc.\xa5~\x1f\xb6\xf3}\x01\x00\x00\x00\x00\x04YZ")
wvb = io.BytesIO()
wvw = wave.open(wvb, "wb")
wvw.setnchannels(1)
wvw.setsampwidth(2)
wvw.setframerate(8000)
wvw.writeframes(memoryview(b"\x01\x00\x02\x00"))
wvw.writeframes(Array("h", [3]))
wvw.close()
wvb.seek(0)
wvr = wave.open(wvb, "rb")
check("lzma and wave take buffers",
      [lzma.decompress(memoryview(XZ)), lzma.LZMADecompressor().decompress(Array("B", list(XZ))),
       wvr.getnframes(), wvr.readframes(10)],
      [b"lz", b"lz", 3, b"\x01\x00\x02\x00\x03\x00"])
wvr.close()
try:
    import sqlite3
except ImportError:
    sqlite3 = None
if sqlite3 is not None:
    sqc = sqlite3.connect(":memory:")
    sqc.execute("create table t(b blob)")
    sqc.execute("insert into t values (?)", (memoryview(b"blob"),))
    sqc.execute("insert into t values (?)", (sqlite3.Binary(b"bin"),))
    sqc.execute("insert into t values (?)", (memoryview(b"abcd")[1:3],))
    check("sqlite3: Binary is memoryview, views bind as blobs",
          [type(sqlite3.Binary(b"x")).__name__, [r[0] for r in sqc.execute("select b from t")]],
          ["memoryview", [b"blob", b"bin", b"bc"]])
    sqc.close()
if not WIN:
    from multiprocessing import shared_memory
    shm = shared_memory.SharedMemory(create=True, size=16)
    shb = shm.buf
    shb[0:3] = b"shm"
    shpart = shm.buf[0:2]
    shinfo = [type(shb).__name__, len(shb), shb.readonly, bytes(shm.buf[:3]), err(lambda: shm.close())]
    shpart.release()
    del shb
    shm.close()
    shm.unlink()
    check("SharedMemory.buf is a memoryview of the block", shinfo,
          ["memoryview", 16, False, b"shm", "BufferError: cannot close exported pointers exist"])

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT112 PASSED ===")
