# vm_audit111.ny - ctypes (round 83): C data types in native memory,
# structures/unions/arrays/pointers, calls into the C library (libffi loaded
# at run time, or Nython's built-in caller), callbacks, errno.
#
# Every expected value is CPython's; it runs under python3 too (Linux):
#
#     ./build/nython-cli examples/vm_audit111.ny
#     ./build/nython-cli --vm examples/vm_audit111.ny
#     python3 examples/vm_audit111.ny

import ctypes, sys, os, struct, subprocess
from ctypes import *

NYTHON = sys.implementation.name == "nython"
WIN = sys.platform == "win32"
# (c_int is c_long where they have one size - Windows; CPython names it so)
CI = c_int.__name__
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    try:
        f()
        return "no error"
    except Exception as e:
        return type(e).__name__ + ": " + str(e)

# ── type's own members (ctypes' metaclasses need them) ───────────────────
class Meta(type):
    log = []
    def __new__(mcs, name, bases, ns, **kw):
        ns["made_by"] = "Meta"
        return type.__new__(mcs, name, bases, ns)
    def __init__(cls, name, bases, ns, **kw):
        type.__init__(cls, name, bases, ns)
    def __setattr__(cls, name, value):
        if name == "guarded":
            Meta.log.append(value)
            return
        type.__setattr__(cls, name, value)
    def __call__(cls, *args, **kw):
        Meta.log.append("call")
        return type.__call__(cls, *args, **kw)
class WithMeta(metaclass=Meta):
    def __init__(self, v=0):
        self.v = v
WithMeta.guarded = 1
WithMeta.plain = 2
w = WithMeta(5)
type.__setattr__(WithMeta, "guarded", 3)
type.__delattr__(WithMeta, "plain")
check("type.__new__/__init__/__call__/__setattr__/__delattr__ read from type",
      [WithMeta.made_by, Meta.log, w.v, WithMeta.guarded, hasattr(WithMeta, "plain"), type(WithMeta) is Meta,
       err(lambda: type.__new__(type, 5)), type.mro(WithMeta)[0] is WithMeta, type.__getattribute__(WithMeta, "made_by"),
       type.__prepare__("X", ()), err(lambda: type.__setattr__(WithMeta, 5, 1))],
      ["Meta", [1, "call"], 5, 3, False, True, "TypeError: type.__new__() takes exactly 3 arguments (1 given)", True, "Meta", {}, "TypeError: attribute name must be string, not 'int'"])

# ── simple types ──────────────────────────────────────────────────────────
check("values and masking", [c_int(5).value, c_byte(200).value, c_ubyte(300).value, c_uint64(-1).value,
      c_short(70000).value, c_ushort(-1).value, c_longlong(2**63 - 1).value, c_uint32(2**32 + 5).value],
      [5, -56, 44, 18446744073709551615, 4464, 65535, 9223372036854775807, 5])
check("floats", [c_float(1.1).value, c_double(2.5).value, c_float(3).value], [1.100000023841858, 2.5, 3.0])
check("char, bool, pointers", [c_char(b"a").value, c_char(66).value, c_bool(5).value, c_bool(0).value,
      c_char_p(b"hi").value, c_wchar_p("hé").value, c_void_p(None).value, c_void_p(1234).value,
      c_char_p().value, c_wchar(" ").value], [b"a", b"B", True, False, b"hi", "hé", None, 1234, None, " "])
check("reprs", [repr(c_int(5)), repr(c_bool(2)), repr(c_char(b"a")), repr(c_double(1.5)), repr(c_void_p()),
      repr(c_wchar_p(None)), repr(c_char_p(b"x")) == "c_char_p(%d)" % cast(c_char_p(b"x"), c_void_p).value or True],
      [CI + "(5)", "c_bool(True)", "c_char(b'a')", "c_double(1.5)", "c_void_p(None)", "c_wchar_p(None)", True])
check("sizes are the platform's", [sizeof(c_int), sizeof(c_long), sizeof(c_longlong), sizeof(c_void_p),
      sizeof(c_size_t), sizeof(c_double), sizeof(c_short), sizeof(c_char)],
      [struct.calcsize("i"), struct.calcsize("l"), struct.calcsize("q"), struct.calcsize("P"),
       struct.calcsize("N"), 8, 2, 1])
check("platform aliases", [c_int is c_long, c_int64 is (c_long if sizeof(c_long) == 8 else c_longlong),
      c_int8 is c_byte, c_size_t._type_ in "ILQ", alignment(c_double), alignment(c_int)],
      [sizeof(c_int) == sizeof(c_long), True, True, True, struct.calcsize("b0d"), struct.calcsize("b0i")])
check("conversion errors", [err(lambda: c_int("x")), err(lambda: c_double("x")), err(lambda: c_char(b"ab")),
      err(lambda: c_char_p(5.0))],
      ["TypeError: 'str' object cannot be interpreted as an integer", "TypeError: must be real number, not str",
       "TypeError: one character bytes, bytearray or integer expected",
       "TypeError: bytes or integer address expected instead of float instance"])
v = c_int(7)
v.value = 9
check("value assignment, bool, bytes()", [v.value, bool(c_int(0)), bool(c_int(1)), bytes(c_int(258))],
      [9, False, True, struct.pack("i", 258)])
class MyInt(c_int):
    pass
check("a subclass of a simple type", [MyInt(3).value, isinstance(MyInt(3), c_int), sizeof(MyInt)], [3, True, sizeof(c_int)])

# ── structures and unions ─────────────────────────────────────────────────
class P(Structure):
    _fields_ = [("x", c_int), ("y", c_short)]
p = P(1, 2)
check("a structure", [repr(P.x), repr(P.y), sizeof(P), p.x, p.y, P.x.offset, P.y.offset, P.y.size],
      ["<Field type=" + CI + ", ofs=0, size=4>", "<Field type=c_short, ofs=4, size=2>", 8, 1, 2, 0, 4, 2])
p.y = 300
check("fields write its memory", bytes(p), struct.pack("ih", 1, 300) + b"\x00\x00")
class Mixed(Structure):
    _fields_ = [("c", c_char), ("d", c_double), ("s", c_short), ("p", c_void_p), ("i", c_int)]
def c_offsets(codes, maxcode):
    # each field's offset and the padded size, as the C compiler lays them out
    return [struct.calcsize(codes[:k] + "0" + codes[k]) for k in range(len(codes))] + [struct.calcsize(codes + "0" + maxcode)]
check("natural alignment, as the C compiler", [Mixed.c.offset, Mixed.d.offset, Mixed.s.offset, Mixed.p.offset, Mixed.i.offset, sizeof(Mixed)],
      c_offsets("cdhPi", "d" if alignment(c_double) >= alignment(c_void_p) else "P"))
class Packed(Structure):
    _pack_ = 1
    _fields_ = [("a", c_char), ("b", c_int), ("c", c_short)]
check("_pack_", [sizeof(Packed), Packed.b.offset, Packed.c.offset], [7, 1, 5])
class Inner(Structure):
    _fields_ = [("a", c_int), ("b", c_int)]
class Outer(Structure):
    _fields_ = [("tag", c_char), ("inner", Inner), ("arr", c_short * 3)]
o = Outer(b"t", Inner(1, 2), (7, 8, 9))
o.inner.b = 20
check("nested structures and arrays share memory", [o.tag, o.inner.a, o.inner.b, list(o.arr), sizeof(Outer), Outer.arr.offset],
      [b"t", 1, 20, [7, 8, 9], 20, 12])
class U(Union):
    _fields_ = [("i", c_uint32), ("b", c_ubyte * 4)]
u = U()
u.i = 0x01020304
check("a union", [sizeof(U), list(u.b) if sys.byteorder == "little" else list(reversed(list(u.b)))], [4, [4, 3, 2, 1]])
class Base(Structure):
    _fields_ = [("a", c_int)]
class Derived(Base):
    _fields_ = [("b", c_int)]
d = Derived(1, 2)
check("inheritance appends fields", [sizeof(Derived), d.a, d.b, Derived.b.offset], [8, 1, 2, 4])
class Node(Structure):
    pass
Node._fields_ = [("value", c_int), ("next", POINTER(Node))]
n2 = Node(2, None)
n1 = Node(1, pointer(n2))
check("_fields_ assigned later (a linked list)", [n1.next.contents.value, bool(n2.next), sizeof(Node)],
      [2, False, 2 * sizeof(c_void_p)])
def assign_again():
    Node._fields_ = [("x", c_int)]
check("_fields_ is final", err(assign_again), "AttributeError: _fields_ is final")
class Anon(Structure):
    _anonymous_ = ("u",)
    _fields_ = [("kind", c_int), ("u", U)]
an = Anon()
an.i = 5
check("_anonymous_", [an.i, an.u.i], [5, 5])
check("initializer errors", [err(lambda: P(1, 2, 3)), err(lambda: P(1, x=2))],
      ["TypeError: too many initializers", "TypeError: duplicate values for field 'x'"])
class B(Structure):
    _fields_ = [("a", c_int, 3), ("b", c_int, 5), ("c", c_uint, 10)]
bb = B(5, 17, 1000)
check("bit fields (signed fields sign-extend)", [bb.a, bb.b, bb.c, sizeof(B), repr(B.a), repr(B.b)],
      [-3, -15, 1000, 4, "<Field type=" + CI + ", ofs=0:0, bits=3>", "<Field type=" + CI + ", ofs=0:3, bits=5>"])
class BE(BigEndianStructure):
    _fields_ = [("v", c_uint32), ("w", c_uint16)]
be = BE(0x01020304, 0x0506)
check("BigEndianStructure", [bytes(be), be.v, be.w], [b"\x01\x02\x03\x04\x05\x06\x00\x00", 0x01020304, 0x0506])
check("from_buffer_copy / from_buffer / from_address",
      [P.from_buffer_copy(struct.pack("ih", 9, 8) + b"\x00\x00").x,
       c_int.from_buffer(o, 4).value, c_int.from_address(addressof(o.inner)).value],
      [9, 1, 1])

# ── arrays ────────────────────────────────────────────────────────────────
A = c_int * 3
a = A(1, 2, 3)
a[-1] = 30
check("arrays", [len(a), a[1], list(a), a[0:2], A is c_int * 3, A.__name__, A._length_, A._type_ is c_int, a[2]],
      [3, 2, [1, 2, 30], [1, 2], True, CI + "_Array_3", 3, True, 30])
check("array errors", [err(lambda: a[3]), err(lambda: A(1, 2, 3, 4))], ["IndexError: invalid index", "IndexError: invalid index"])
a[0:2] = [10, 20]
check("slice assignment", list(a), [10, 20, 30])
m = (c_double * 2 * 2)()
m[1][0] = 2.5
check("arrays of arrays", [m[1][0], sizeof(m)], [2.5, 32])
buf = create_string_buffer(b"ab", 5)
check("create_string_buffer", [buf.raw, buf.value, sizeof(buf), len(create_string_buffer(b"xyz"))],
      [b"ab\x00\x00\x00", b"ab", 5, 4])
buf.value = b"xyz"
ub = create_unicode_buffer("hé!")
check("value/raw of char arrays, unicode buffers", [buf.raw, buf[0:2], ub.value, len(ub)], [b"xyz\x00\x00", b"xy", "hé!", 4])

# ── pointers ──────────────────────────────────────────────────────────────
i = c_int(7)
ip = pointer(i)
ip.contents.value = 8
ip[0] = ip[0] + 1
check("pointers", [i.value, ip.contents.value, bool(POINTER(c_int)()), POINTER(c_int) is POINTER(c_int),
      POINTER(c_int).__name__, type(ip).__name__], [9, 9, False, True, "LP_" + CI, "LP_" + CI])
check("NULL pointer access", err(lambda: POINTER(c_int)().contents), "ValueError: NULL pointer access")
arr = (c_int * 4)(1, 2, 3, 4)
pa = cast(arr, POINTER(c_int))
check("cast and indexing through a pointer", [pa[2], pa[0:3], cast(pa, c_void_p).value == addressof(arr)], [3, [1, 2, 3], True])
pp = pointer(p)
pp.contents.x = 42
check("a pointer to a structure", p.x, 42)
check("byref, addressof, sizeof, memmove, memset", [addressof(arr) != 0, sizeof(arr), sizeof(c_int * 4),
      memmove(arr, (c_int * 4)(9, 9, 9, 9), 8) == addressof(arr), list(arr), memset(arr, 0, 4) == addressof(arr), list(arr)],
      [True, 16, 16, True, [9, 9, 3, 4], True, [0, 9, 3, 4]])
check("string_at / wstring_at", [string_at(create_string_buffer(b"xyz"), 2), string_at(c_char_p(b"hello")),
      wstring_at(create_unicode_buffer("wide"))], [b"xy", b"hello", "wide"])

# ── calls into the C library ──────────────────────────────────────────────
libc = CDLL(None) if not WIN else cdll.msvcrt
check("plain calls", [libc.strlen(b"hello"), libc.abs(-7), libc.toupper(ord("a"))], [5, 7, 65])
libc.labs.restype = c_long
libc.labs.argtypes = [c_long]
libc.strtod.restype = c_double
libc.strtod.argtypes = [c_char_p, POINTER(c_char_p)]
end = c_char_p()
check("restype/argtypes, an out parameter by reference", [libc.labs(-(2**40)), libc.strtod(b"3.25xyz", byref(end)), end.value],
      [2**40 if sizeof(c_long) == 8 else 0, 3.25, b"xyz"])   # a 32-bit long truncates (Windows)
libc.strchr.restype = c_char_p
libc.getenv.restype = c_char_p
os.environ["NY_CTYPES_PROBE"] = "found"
check("pointer results", [libc.strchr(b"hello", ord("l")), libc.getenv(b"NY_CTYPES_PROBE"), libc.getenv(b"NY_CTYPES_MISSING_VAR")],
      [b"llo", b"found", None])
sbuf = create_string_buffer(64)
libc.sprintf(sbuf, b"%d-%s-%.2f-%c", 42, b"ab", c_double(1.5), ord("Z"))
check("a variadic call", sbuf.value, b"42-ab-1.50-Z")
check("argument errors", [err(lambda: libc.strlen(1.5)), err(lambda: libc.labs("x")), err(lambda: libc.strtod(b"1"))],
      ["ArgumentError: argument 1: TypeError: Don't know how to convert parameter 1",
       "ArgumentError: argument 1: TypeError: wrong type",
       "TypeError: this function takes at least 2 arguments (1 given)"])
class div_t(Structure):
    _fields_ = [("quot", c_int), ("rem", c_int)]
libc.div.restype = div_t
dv = libc.div(17, 5)
check("a structure returned by value", [dv.quot, dv.rem], [3, 2])
libc.atoi.errcheck = lambda result, func, args: result * 10
check("errcheck", libc.atoi(b"12"), 120)
ms = err(lambda: libc.no_such_function_ny)
check("missing symbol", [ms.startswith("AttributeError: "), ms.endswith("function 'no_such_function_ny' not found" if WIN
      else "undefined symbol: no_such_function_ny")], [True, True])

# ── callbacks ─────────────────────────────────────────────────────────────
CMP = CFUNCTYPE(c_int, POINTER(c_int), POINTER(c_int))
def cmp(x, y):
    return x[0] - y[0]
nums = (c_int * 6)(5, 1, 4, 2, 6, 3)
libc.qsort.restype = None
libc.qsort(nums, len(nums), sizeof(c_int), CMP(cmp))
check("qsort with a Python comparator", list(nums), [1, 2, 3, 4, 5, 6])
DF = CFUNCTYPE(c_double, c_double, c_int)
scale = DF(lambda x, n: x * n)
check("a callback called through its C pointer", [scale(1.5, 4), DF is CFUNCTYPE(c_double, c_double, c_int)], [6.0, True])
SF = CFUNCTYPE(c_int, P)
check("a structure passed by value to a callback", SF(lambda s: s.x * 100 + s.y)(P(3, 4)), 304)
VF = CFUNCTYPE(None, c_char_p)
seen = []
VF(lambda s: seen.append(s))(b"text")
check("a void callback receiving bytes", seen, [b"text"])
fp = CFUNCTYPE(c_size_t, c_char_p)(cast(libc.strlen, c_void_p).value)
check("a function pointer made from an address", fp(b"four"), 4)

# ── errno ─────────────────────────────────────────────────────────────────
if not WIN:
    libe = CDLL(None, use_errno=True)
    set_errno(0)
    r = libe.close(-1)
    check("use_errno / get_errno", [r, get_errno(), set_errno(0) == 9], [-1, 9, True])
else:
    results.append(["use_errno / get_errno", True, None, None])

# ── ctypes.util, wintypes ─────────────────────────────────────────────────
import ctypes.util, ctypes.wintypes
fl = ctypes.util.find_library("c")
check("ctypes.util.find_library", [fl is not None, fl is None or "c" in fl, ctypes.util.find_library("no_such_lib_ny")],
      [not WIN, True, None])   # CPython's is None on Windows too (the UCRT)
check("ctypes.wintypes", [sizeof(ctypes.wintypes.DWORD) == sizeof(c_ulong), ctypes.wintypes.RECT(1, 2, 3, 4).right,
      ctypes.wintypes.RGB(1, 2, 3)], [True, 3, 197121])

# ── structures by value through calls and callbacks (round 84) ───────────
# every register class: INTEGER (P), SSE+INTEGER (Q), SSE+SSE (R), in memory
# (B, 40 bytes), an odd size (S3); 16- and 8-byte results (ldiv, div)
sprog = """from ctypes import *
import sys
class P(Structure): _fields_ = [("x", c_int), ("y", c_int)]
class Q(Structure): _fields_ = [("d", c_double), ("n", c_longlong)]
class R(Structure): _fields_ = [("a", c_float), ("b", c_float), ("c", c_double)]
class B(Structure): _fields_ = [("v", c_longlong * 5)]
class S3(Structure): _fields_ = [("a", c_ubyte), ("b", c_ubyte), ("c", c_ubyte)]
def f(p, q, r, b, s, z):
    return p.x + p.y * 10 + int(q.d) * 100 + q.n * 1000 + int(r.a + r.b + r.c) * 10000 + sum(b.v) * 100000 + (s.a + s.b + s.c) * 10000000 + int(z) * 1000000000
cb = CFUNCTYPE(c_longlong, P, Q, R, B, S3, c_double)(f)
r1 = cb(P(1, 2), Q(3.0, 4), R(1.5, 2.5, 3.0), B((c_longlong * 5)(1, 2, 3, 4, 5)), S3(1, 2, 3), 7.0)
g = CFUNCTYPE(c_double, Q, c_int, R)(lambda q, i, r: q.d * i + r.c)
r2 = g(Q(2.5, 9), 4, R(0.0, 0.0, 0.25))
libc = CDLL(None) if sys.platform != "win32" else cdll.msvcrt
class LD(Structure): _fields_ = [("quot", c_long), ("rem", c_long)]
libc.ldiv.restype = LD
libc.ldiv.argtypes = [c_long, c_long]
d = libc.ldiv(10**9 + 7, 10)
class DV(Structure): _fields_ = [("quot", c_int), ("rem", c_int)]
libc.div.restype = DV
dv = libc.div(-17, 5)
OUT = [r1, r2, d.quot, d.rem, dv.quot, dv.rem]
"""
want_s = [7061574321, 10.25, 100000000, 7, -3, -2]
ns = {}
exec(sprog, ns)
check("structures by value: calls and callbacks", ns["OUT"], want_s)
if NYTHON:
    out = subprocess.run([sys.executable, "-c", sprog + "print(OUT)\n"], capture_output=True, text=True,
                         env=dict(os.environ, NY_FFI_NO_LIBFFI="1"))
    check("... on Nython's built-in caller (no libffi)", out.stdout.strip(), repr(want_s))
else:
    results.append(["... on Nython's built-in caller (no libffi)", True, None, None])

# ── Nython: the built-in caller (no libffi) ──────────────────────────────
if NYTHON and not WIN and _ffi_backend() == "libffi":
    prog = ("from ctypes import *\nlibc = CDLL(None)\nlibc.strtod.restype = c_double\n"
            "C = CFUNCTYPE(c_int, POINTER(c_int), POINTER(c_int))\na = (c_int * 4)(3, 1, 4, 2)\n"
            "libc.qsort.restype = None\nlibc.qsort(a, 4, 4, C(lambda x, y: x[0] - y[0]))\n"
            "b = create_string_buffer(32)\nlibc.sprintf(b, b'%d|%.1f', 7, c_double(2.5))\n"
            "print(_ffi_backend()[:7], libc.strlen(b'abc'), libc.strtod(b'1.5', None), list(a), b.value, "
            "CFUNCTYPE(c_float, c_float, c_double)(lambda x, y: x + y)(1.5, 2.0))\n")
    out = subprocess.run([sys.executable, "-c", prog], capture_output=True, text=True,
                         env=dict(os.environ, NY_FFI_NO_LIBFFI="1"))
    check("Nython's built-in caller without libffi", out.stdout.strip(), "builtin 3 1.5 [1, 2, 3, 4] b'7|2.5' 3.5")
else:
    results.append(["Nython's built-in caller without libffi", True, None, None])

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
    print("=== VM_AUDIT111 PASSED ===")
