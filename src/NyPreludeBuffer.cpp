// NyPreludeBuffer.cpp - the buffer protocol's part of the prelude (round
// 84): memoryview's methods, the managed buffers its views share, and the
// helpers the libraries and the engines call for bytes-like and writable
// buffer arguments (_ny_buffer_bytes, _ny_bytes_like, _ny_writable_view,
// _ny_memview_raw, _ny_pct_arg). It is loaded on first need, as a mirror
// chunk ("buffer": builtin_mirror_chunk, NythonExecutor::ensureMirror,
// VirtualMachine::load_mirror): the startup prelude (NyPrelude.hpp) holds
// the class memoryview and stubs of these helpers that load it
// (_ny_load_chunk) and call the real ones, so a program that never makes a
// view pays nothing for it (it cost 6 ms - 18% - of every start). It is
// Nython source; the natives it calls are the _mv_* of
// src/builtins/nybuffer.cpp and the engines' _ny_buf_* (export, unexport,
// exports, addr).
#include <string>

namespace nyrt {

const char* prelude_buffer_source() {
    return R"NYBUFPRELUDE(
# ── memoryview and the buffer protocol (round 84; PEP 3118, PEP 688) ─────
# A buffer is native memory: the address of its first item, a format and
# item size, a shape and strides in bytes. An exporter gives one -
# bytes / bytearray through the engines (_ny_buf_export: a bytearray's
# storage is then fixed - resizing it raises BufferError until the export is
# given back), array.array, mmap, ctypes data and any class through
# __buffer__ (PEP 688) - and a _NyMBuf (CPython's managed buffer) holds that
# one export for every view made from it (slices, casts, memoryview(m),
# toreadonly()). The export is given back when the last view is released
# (release(), a with block) or when the managed buffer is collected. Items
# are read and written by the _mv_* natives (src/builtins/nybuffer.cpp) at
# their addresses, so a view shares the exporter's memory both ways.
# CPython's memoryobject.c is the model: its rules, checks and messages.
class _NyMBuf:
    # one export: obj (what memoryview(x).obj is), owner (kept alive: holds
    # the memory), kind 0 an engine export of bytes/bytearray, 1 a view an
    # object's __buffer__ gave (inner), 2 raw memory (rel called when given
    # back), 3 exported by a memoryview (inner, whose exports it counts)
    def __del__(self):
        _ny_mbuf_release(self)

def _ny_mbuf(obj, owner, kind):
    var mb = _NyMBuf()
    mb.obj = obj
    mb.owner = owner
    mb.kind = kind
    mb.inner = None
    mb.rel = None
    mb.views = 0
    mb.done = False
    return mb

def _ny_mbuf_release(mb):
    if getattr(mb, "done", True):
        return None
    mb.done = True
    if mb.kind == 0:
        _ny_buf_unexport(mb.owner)
    elif mb.kind == 1 or mb.kind == 3:
        var inner = mb.inner
        if inner._ny_x > 0:
            _ny_setfield(inner, "_ny_x", inner._ny_x - 1)
        if mb.kind == 1:
            var rb = getattr(type(mb.obj), "__release_buffer__", None)
            if rb is not None:
                rb(mb.obj, inner)
    elif mb.rel is not None:
        mb.rel()
    return None

_NY_MV_RELEASED = "operation forbidden on released memoryview object"
_NY_MV_ATTRS = ("obj", "nbytes", "readonly", "itemsize", "format", "ndim", "shape", "strides",
                "suboffsets", "c_contiguous", "f_contiguous", "contiguous")

def _ny_mv_flags(shape, strides, isz):
    # CPython's init_flags: 1 C-contiguous, 2 Fortran-contiguous
    var nd = len(shape)
    if nd == 0:
        return 3
    if nd == 1:
        return 3 if (shape[0] == 1 or strides[0] == isz) else 0
    var n = 1
    for s in shape:
        n = n * s
    if n == 0:
        return 3
    var fl = 0
    var sd = isz
    var c = True
    var i = nd - 1
    while i >= 0:
        if shape[i] > 1 and strides[i] != sd:
            c = False
        sd = sd * shape[i]
        i = i - 1
    if c:
        fl = 1
    sd = isz
    var f = True
    i = 0
    while i < nd:
        if shape[i] > 1 and strides[i] != sd:
            f = False
        sd = sd * shape[i]
        i = i + 1
    if f:
        fl = fl + 2
    return fl

def _ny_mv_make(mb, addr, fmt, isz, shape, strides, ro):
    # a view registered on the managed buffer mb
    var m = object.__new__(memoryview)
    var c = fmt[1:] if fmt[:1] == "@" else fmt      # the item code: one character, or None
    var n = isz
    for s in shape:
        n = n * s
    _ny_setfield(m, "_ny_mb", mb)
    _ny_setfield(m, "_ny_a", addr)
    _ny_setfield(m, "_ny_f", fmt)
    _ny_setfield(m, "_ny_c", c if len(c) == 1 else None)
    _ny_setfield(m, "_ny_i", isz)
    _ny_setfield(m, "_ny_sh", tuple(shape))
    _ny_setfield(m, "_ny_st", tuple(strides))
    _ny_setfield(m, "_ny_ro", bool(ro))
    _ny_setfield(m, "_ny_n", n)
    _ny_setfield(m, "_ny_fl", _ny_mv_flags(shape, strides, isz))
    _ny_setfield(m, "_ny_x", 0)
    _ny_setfield(m, "_ny_h", None)
    mb.views = mb.views + 1
    return m

def _ny_mv_copy(m, ro):
    # another view of m's buffer with m's layout (memoryview(m), toreadonly)
    return _ny_mv_make(m._ny_mb, m._ny_a, m._ny_f, m._ny_i, m._ny_sh, m._ny_st, ro)

def _ny_memview_raw(obj, addr, nbytes, readonly, fmt="B", itemsize=1, shape=None, strides=None, release=None,
                    owner=None):
    # a view of raw memory an exporter written in Nython gives from its
    # __buffer__ (array.array, mmap, ctypes): obj is its .obj, owner (obj by
    # default) what holds the memory; release() is called once the export is
    # given back
    var mb = _ny_mbuf(obj, obj if owner is None else owner, 2)
    mb.rel = release
    if shape is None:
        shape = (nbytes // itemsize,)
    if strides is None:
        var st = []
        var acc = itemsize
        var i = len(shape) - 1
        while i >= 0:
            st.insert(0, acc)
            acc = acc * shape[i]
            i = i - 1
        strides = tuple(st)
    return _ny_mv_make(mb, addr, fmt, itemsize, shape, strides, readonly)

def _ny_mv_export(obj, what):
    # a new view of an exporter's buffer (PyObject_GetBuffer); `what` starts
    # the message for an object that is not one
    if isinstance(obj, memoryview):
        if obj._ny_mb is None:
            raise ValueError(_NY_MV_RELEASED)
        return _ny_mv_copy(obj, obj._ny_ro)
    var e = _ny_buf_export(obj)
    if e is not None:
        var mb = _ny_mbuf(obj, e[3], 0)
        return _ny_mv_make(mb, e[0], "B", 1, (e[1],), (1,), e[2])
    var bf = getattr(type(obj), "__buffer__", None)
    if bf is None:
        raise TypeError(what + "a bytes-like object is required, not '" + type(obj).__name__ + "'")
    var r = bf(obj, 284)          # PyBUF_FULL_RO
    if not isinstance(r, memoryview):
        raise TypeError("__buffer__ returned non-memoryview object")
    if r._ny_mb is None:
        raise ValueError(_NY_MV_RELEASED)
    var mb = _ny_mbuf(obj, r, 1)
    mb.inner = r
    _ny_setfield(r, "_ny_x", r._ny_x + 1)
    return _ny_mv_make(mb, r._ny_a, r._ny_f, r._ny_i, r._ny_sh, r._ny_st, r._ny_ro)

def _ny_buffer_bytes(obj):
    # the bytes any exporter holds, in C order (the engines' bytes-like
    # arguments: bytes(m), b"" + m, b.join([m]), int.from_bytes(m) ...)
    if isinstance(obj, memoryview):
        return obj.tobytes()
    var m = _ny_mv_export(obj, "")
    var b = m.tobytes()
    m.release()
    return b

def _ny_bytes_like(obj, what=""):
    # a library's bytes-like argument (y* in CPython's argument clinic): a
    # bytes or bytearray as it is, any other exporter's bytes
    if isinstance(obj, bytes) or isinstance(obj, bytearray):
        return obj
    if isinstance(obj, memoryview):
        return obj.tobytes()
    if getattr(type(obj), "__buffer__", None) is None:
        raise TypeError(what + "a bytes-like object is required, not '" + type(obj).__name__ + "'")
    return _ny_buffer_bytes(obj)

def _ny_writable_view(obj, where="argument"):
    # a writable buffer argument (w* in CPython's argument clinic), as a flat
    # view of unsigned bytes - readinto(b), recv_into(b), pack_into(b) write
    # through it into the caller's object; `where` begins the message
    # ("readinto() argument"); None: PyObject_GetBuffer's own errors
    # (os.readv: TypeError, then BufferError "Object is not writable.")
    if not _ny_is_exporter(obj):
        if where is None:
            raise TypeError("a bytes-like object is required, not '" + type(obj).__name__ + "'")
        raise TypeError(where + " must be read-write bytes-like object, not " + type(obj).__name__)
    var m = _ny_mv_export(obj, "")
    if m._ny_ro:
        m.release()
        if where is None:
            if isinstance(obj, memoryview):
                raise BufferError("memoryview: underlying buffer is not writable")
            raise BufferError("Object is not writable.")
        raise TypeError(where + " must be read-write bytes-like object, not " + type(obj).__name__)
    if not (m._ny_fl & 1):
        m.release()
        raise BufferError("memoryview: underlying buffer is not C-contiguous")
    if m._ny_c == "B" and len(m._ny_sh) == 1:
        return m
    var b = _ny_mv_make(m._ny_mb, m._ny_a, "B", 1, (m._ny_n,), (1,), False)
    m.release()
    return b

def _ny_pct_arg(v, c):
    # bytes % args (PEP 461): an argument the engines do not convert
    # themselves - %b / %s: __bytes__, then the buffer protocol; %a / %r:
    # ascii(); the numbers: __index__ (o x X c), int() of a number (d i u),
    # __float__ / __index__ (e f g) - with CPython's TypeErrors
    var t = type(v)
    if c == "a":
        return ascii(v).encode("ascii")
    if c == "b":
        var f = getattr(t, "__bytes__", None)
        if f is not None:
            var r = f(v)
            if not isinstance(r, bytes):
                raise TypeError("__bytes__ returned non-bytes (type " + type(r).__name__ + ")")
            return r
        if _ny_is_exporter(v):
            return _ny_buffer_bytes(v)
        raise TypeError("%b requires a bytes-like object, or an object that implements __bytes__, not '" + t.__name__ + "'")
    if c in "oxX":
        if hasattr(t, "__index__"):
            return v.__index__()
        raise TypeError("%" + c + " format: an integer is required, not " + t.__name__)
    if c in "diu":
        # PyNumber_Long: __int__, then __index__
        if hasattr(t, "__int__"):
            try:
                return int(v)
            except TypeError:
                pass
        if hasattr(t, "__index__"):
            return v.__index__()
        raise TypeError("%" + ("d" if c == "i" else c) + " format: a real number is required, not " + t.__name__)
    if c in "eEfFgG":
        if hasattr(t, "__float__"):
            return v.__float__()
        if hasattr(t, "__index__"):
            return float(v.__index__())
        raise TypeError("float argument required, not " + t.__name__)
    if c == "c":
        if hasattr(t, "__index__"):
            return v.__index__()
        raise TypeError("%c requires an integer in range(256) or a single byte")
    if c == "*":
        raise TypeError("* wants int")
    return v

def _ny_mv_index(k):
    # PyNumber_AsSsize_t(key, IndexError)
    if not (isinstance(k, int) or isinstance(k, bool)):
        k = k.__index__()
    if k > 9223372036854775807 or k < -9223372036854775808:
        raise IndexError("cannot fit 'int' into an index-sized integer")
    return int(k)

def _ny_mv_isindex(k):
    if isinstance(k, int) or isinstance(k, bool):
        return True
    if k is None or isinstance(k, (tuple, slice, str, float, bytes, bytearray, list, dict)):
        return False
    return hasattr(type(k), "__index__")

def _ny_mv_code(m):
    # CPython's adjust_fmt: the item code, or NotImplementedError
    if m._ny_c is None:
        raise NotImplementedError("memoryview: unsupported format " + m._ny_f)
    return m._ny_c

def _ny_mv_get(addr, c):
    var v = _mv_get(addr, c)
    if isinstance(v, str):
        return int(v)
    return v

def _ny_mv_range(c, size):
    var bits = 8 * size
    if c == "P":
        return (0 - (1 << (bits - 1)), (1 << bits) - 1)
    if c in "bhilqn":
        return (0 - (1 << (bits - 1)), (1 << (bits - 1)) - 1)
    return (0, (1 << bits) - 1)

def _ny_mv_pack(m, addr, c, v):
    # CPython's pack_single: the item at addr from v, with its checks
    if c in "bhilqnBHILQNP":
        var x = v
        if c == "P":
            if not (isinstance(v, int) or isinstance(v, bool)):
                raise TypeError("memoryview: invalid type for format '" + c + "'")
        elif not (isinstance(v, int) or isinstance(v, bool)):
            if isinstance(v, float) or not hasattr(type(v), "__index__"):
                raise TypeError("memoryview: invalid type for format '" + c + "'")
            x = v.__index__()
        x = int(x)
        var r = _ny_mv_range(c, m._ny_i)
        if x < r[0] or x > r[1]:
            raise ValueError("memoryview: invalid value for format '" + c + "'")
        if x > 9223372036854775807:
            x = x - 18446744073709551616
        if m._ny_mb is None:
            raise ValueError(_NY_MV_RELEASED)
        _mv_set(addr, c, x)
        return None
    if c in "fde":
        var d = 0.0
        if isinstance(v, float):
            d = v
        elif isinstance(v, int) or isinstance(v, bool):
            try:
                d = float(v)
            except OverflowError:
                raise ValueError("memoryview: invalid value for format '" + c + "'")
            if d - d != 0.0:
                # an int past the floats (CPython's OverflowError)
                raise ValueError("memoryview: invalid value for format '" + c + "'")
        elif hasattr(type(v), "__float__"):
            d = v.__float__()
        elif hasattr(type(v), "__index__"):
            d = float(v.__index__())
        else:
            raise TypeError("memoryview: invalid type for format '" + c + "'")
        if m._ny_mb is None:
            raise ValueError(_NY_MV_RELEASED)
        _mv_set(addr, c, d)
        return None
    if c == "?":
        var t = bool(v)
        if m._ny_mb is None:
            raise ValueError(_NY_MV_RELEASED)
        _mv_set(addr, c, t)
        return None
    if c == "c":
        if not isinstance(v, bytes):
            raise TypeError("memoryview: invalid type for format '" + c + "'")
        if len(v) != 1:
            raise ValueError("memoryview: invalid value for format '" + c + "'")
        _mv_set(addr, c, v)
        return None
    raise NotImplementedError("memoryview: format " + c + " not supported")

def _ny_mv_lookup(m, addr, dim, k):
    # CPython's lookup_dimension
    var n = m._ny_sh[dim]
    if k < 0:
        k = k + n
    if k < 0 or k >= n:
        raise IndexError("index out of bounds on dimension " + str(dim + 1))
    return addr + m._ny_st[dim] * k

def _ny_mv_tuple_addr(m, key):
    # CPython's ptr_from_tuple
    var nd = len(m._ny_sh)
    if len(key) > nd:
        raise TypeError("cannot index " + str(nd) + "-dimension view with " + str(len(key)) + "-element tuple")
    var a = m._ny_a
    var d = 0
    for k in key:
        a = _ny_mv_lookup(m, a, d, _ny_mv_index(k))
        d = d + 1
    return a

def _ny_mv_sliced(m, key):
    # CPython's init_slice on the first dimension, as a new view
    var t = key.indices(m._ny_sh[0])
    var n = len(range(t[0], t[1], t[2]))
    var sh = list(m._ny_sh)
    var st = list(m._ny_st)
    var a = m._ny_a + st[0] * t[0]
    sh[0] = n
    st[0] = st[0] * t[2]
    return (a, sh, st)

_NY_MV_NOARG = object()      # "not given" (cast's shape, hex's sep)

def _ny_mv_flat(m):
    # the bytes of a view in C order
    if m._ny_fl & 1:
        return _mv_read(m._ny_a, m._ny_n)
    return _mv_tobytes(m._ny_a, m._ny_i, list(m._ny_sh), list(m._ny_st), "C")

def _ny_mv_unbig(x):
    # tolist of a Q/L/N/P view: an unsigned value past 2**63 comes as text
    if isinstance(x, list):
        return [_ny_mv_unbig(y) for y in x]
    if isinstance(x, str):
        return int(x)
    return x

def _ny_mv_iter(m):
    var i = 0
    var c = m._ny_c
    while True:
        if m._ny_mb is None:
            raise ValueError(_NY_MV_RELEASED)
        if i >= m._ny_sh[0]:
            return
        yield _ny_mv_get(m._ny_a + i * m._ny_st[0], c)
        i = i + 1

def _ny_mv_struct_items(m, s):
    # every item of m unpacked with struct.Struct s (C order)
    var out = []
    var nd = len(m._ny_sh)
    if nd == 0:
        var v = s.unpack_from(_mv_read(m._ny_a, m._ny_i))
        return [v[0] if len(v) == 1 else v]
    var idx = [0] * nd
    for x in m._ny_sh:
        if x == 0:
            return out
    while True:
        var a = m._ny_a
        var d = 0
        while d < nd:
            a = a + idx[d] * m._ny_st[d]
            d = d + 1
        var v = s.unpack_from(_mv_read(a, m._ny_i))
        out.append(v[0] if len(v) == 1 else v)
        var k = nd - 1
        while k >= 0:
            idx[k] = idx[k] + 1
            if idx[k] < m._ny_sh[k]:
                break
            idx[k] = 0
            k = k - 1
        if k < 0:
            return out

def _ny_mv_eq(v, w):
    # CPython's memory_richcompare for ==
    if v._ny_mb is None:
        return v is w
    var ww = w
    var mine = False
    if isinstance(w, memoryview):
        if w._ny_mb is None:
            return v is w
    else:
        try:
            ww = _ny_mv_export(w, "")
        except Exception:
            return NotImplemented
        mine = True
    try:
        # equiv_shape
        if len(v._ny_sh) != len(ww._ny_sh):
            return False
        var i = 0
        while i < len(v._ny_sh):
            if v._ny_sh[i] != ww._ny_sh[i]:
                return False
            if v._ny_sh[i] == 0:
                break
            i = i + 1
        var r = _mv_cmp(v._ny_a, v._ny_f, ww._ny_a, ww._ny_f, list(v._ny_sh), list(v._ny_st), list(ww._ny_st))
        if r >= 0:
            return r == 1
        # a format of several codes: struct's unpacking, as CPython's
        import struct as _ny_struct
        var sv = None
        var sw = None
        try:
            sv = _ny_struct.Struct(v._ny_f)
            sw = _ny_struct.Struct(ww._ny_f)
        except _ny_struct.error:
            return NotImplemented
        var a = _ny_mv_struct_items(v, sv)
        var b = _ny_mv_struct_items(ww, sw)
        if len(a) != len(b):
            return False
        var k = 0
        while k < len(a):
            if not (a[k] == b[k]):
                return False
            k = k + 1
        return True
    finally:
        if mine:
            ww.release()

# memoryview's members: the class itself (and its __new__) is the startup
# prelude's, these are put on it when this chunk loads (_ny_mv_attach)
class _NyMemoryview:
    def __setattr__(self, name, value):
        if name in _NY_MV_ATTRS:
            raise AttributeError("attribute '" + name + "' of 'memoryview' objects is not writable")
        raise AttributeError("'memoryview' object has no attribute '" + name + "'")

    def __delattr__(self, name):
        if name in _NY_MV_ATTRS:
            raise AttributeError("attribute '" + name + "' of 'memoryview' objects is not writable")
        raise AttributeError("'memoryview' object has no attribute '" + name + "'")

    def _ny_chk(self):
        if self._ny_mb is None:
            raise ValueError(_NY_MV_RELEASED)

    @property
    def obj(self):
        self._ny_chk()
        return self._ny_mb.obj

    @property
    def nbytes(self):
        self._ny_chk()
        return self._ny_n

    @property
    def readonly(self):
        self._ny_chk()
        return self._ny_ro

    @property
    def itemsize(self):
        self._ny_chk()
        return self._ny_i

    @property
    def format(self):
        self._ny_chk()
        return self._ny_f

    @property
    def ndim(self):
        self._ny_chk()
        return len(self._ny_sh)

    @property
    def shape(self):
        self._ny_chk()
        return self._ny_sh

    @property
    def strides(self):
        self._ny_chk()
        return self._ny_st

    @property
    def suboffsets(self):
        self._ny_chk()
        return ()

    @property
    def c_contiguous(self):
        self._ny_chk()
        return (self._ny_fl & 1) != 0

    @property
    def f_contiguous(self):
        self._ny_chk()
        return (self._ny_fl & 2) != 0

    @property
    def contiguous(self):
        self._ny_chk()
        return self._ny_fl != 0

    def release(self):
        """Release the underlying buffer exposed by the memoryview object."""
        var mb = self._ny_mb
        if mb is None:
            return None
        if self._ny_x > 0:
            raise BufferError("memoryview has " + str(self._ny_x) + " exported buffer" + ("" if self._ny_x == 1 else "s"))
        _ny_setfield(self, "_ny_mb", None)
        mb.views = mb.views - 1
        if mb.views <= 0:
            _ny_mbuf_release(mb)
        return None

    def __enter__(self):
        self._ny_chk()
        return self

    def __exit__(self, *args):
        self.release()
        return None

    def tobytes(self, order="C"):
        """Return the data in the buffer as a byte string."""
        self._ny_chk()
        if order is None:
            order = "C"
        if not isinstance(order, str):
            raise TypeError("tobytes() argument 'order' must be str or None, not " + type(order).__name__)
        if order != "C" and order != "F" and order != "A":
            raise ValueError("order must be 'C', 'F' or 'A'")
        var fl = self._ny_fl
        if (order == "C" and fl & 1) or (order == "F" and fl & 2) or (order == "A" and fl != 0):
            return _mv_read(self._ny_a, self._ny_n)
        return _mv_tobytes(self._ny_a, self._ny_i, list(self._ny_sh), list(self._ny_st), "F" if order == "F" else "C")

    def tolist(self):
        """Return the data in the buffer as a list of elements."""
        self._ny_chk()
        var c = _ny_mv_code(self)
        var r = _mv_tolist(self._ny_a, c, list(self._ny_sh), list(self._ny_st))
        if c in "QLNP":
            r = _ny_mv_unbig(r)
        return r

    def hex(self, sep=_NY_MV_NOARG, bytes_per_sep=1):
        """Return the data in the buffer as a str of hexadecimal numbers."""
        self._ny_chk()
        var b = _ny_mv_flat(self)
        if sep is _NY_MV_NOARG:
            return b.hex()
        return b.hex(sep, bytes_per_sep)

    def toreadonly(self):
        """Return a readonly version of the memoryview."""
        self._ny_chk()
        return _ny_mv_copy(self, True)

    def cast(self, format, shape=_NY_MV_NOARG):
        """Cast a memoryview to a new format or shape."""
        self._ny_chk()
        if not isinstance(format, str):
            raise TypeError("cast() argument 'format' must be str, not " + type(format).__name__)
        if not (self._ny_fl & 1):
            raise TypeError("memoryview: casts are restricted to C-contiguous views")
        var nd = len(self._ny_sh)
        var given = shape is not _NY_MV_NOARG
        if (given or nd != 1) and 0 in self._ny_sh:
            raise TypeError("memoryview: cannot cast view with zeros in shape or strides")
        var ndim = 1
        if given:
            if not isinstance(shape, (list, tuple)):
                raise TypeError("shape must be a list or a tuple")
            ndim = len(shape)
            if ndim > 64:
                raise ValueError("memoryview: number of dimensions must not exceed 64")
            if nd != 1 and ndim != 1:
                raise TypeError("memoryview: cast must be 1D -> ND or ND -> 1D")
        format.encode("ascii")
        var fi = _mv_fmt(format)
        if fi is None:
            raise ValueError("memoryview: destination format must be a native single character format prefixed with an optional '@'")
        var src = self._ny_c
        if (src is None or src not in "bBc") and fi[0] not in "bBc":
            raise TypeError("memoryview: cannot cast between two non-byte formats")
        var isz = fi[1]
        if self._ny_n % isz:
            raise TypeError("memoryview: length is not a multiple of itemsize")
        var sh = [self._ny_n // isz]
        var st = [isz]
        if given:
            sh = []
            var total = isz
            for x in shape:
                if not (isinstance(x, int) or isinstance(x, bool)):
                    raise TypeError("memoryview.cast(): elements of shape must be integers")
                if x <= 0:
                    raise ValueError("memoryview.cast(): elements of shape must be integers > 0")
                if x > 9223372036854775807 // total:
                    raise ValueError("memoryview.cast(): product(shape) > SSIZE_MAX")
                total = total * x
                sh.append(int(x))
            st = [0] * len(sh)
            var acc = isz
            var i = len(sh) - 1
            while i >= 0:
                st[i] = acc
                acc = acc * sh[i]
                i = i - 1
            if total != self._ny_n:
                raise TypeError("memoryview: product(shape) * itemsize != buffer size")
        return _ny_mv_make(self._ny_mb, self._ny_a, format, isz, sh, st, self._ny_ro)

    def __len__(self):
        self._ny_chk()
        if len(self._ny_sh) == 0:
            raise TypeError("0-dim memory has no length")
        return self._ny_sh[0]

    def __getitem__(self, key):
        self._ny_chk()
        var nd = len(self._ny_sh)
        if nd == 0:
            if isinstance(key, tuple) and len(key) == 0:
                return _ny_mv_get(self._ny_a, _ny_mv_code(self))
            if key is Ellipsis:
                return self
            raise TypeError("invalid indexing of 0-dim memory")
        if _ny_mv_isindex(key):
            var i = _ny_mv_index(key)
            var c = _ny_mv_code(self)
            if nd != 1:
                raise NotImplementedError("multi-dimensional sub-views are not implemented")
            return _ny_mv_get(_ny_mv_lookup(self, self._ny_a, 0, i), c)
        if isinstance(key, slice):
            var t = _ny_mv_sliced(self, key)
            return _ny_mv_make(self._ny_mb, t[0], self._ny_f, self._ny_i, t[1], t[2], self._ny_ro)
        if isinstance(key, tuple):
            var allidx = True
            var allsl = len(key) > 0
            for k in key:
                if not _ny_mv_isindex(k):
                    allidx = False
                if not isinstance(k, slice):
                    allsl = False
            if allidx:
                var c = _ny_mv_code(self)
                if len(key) < nd:
                    raise NotImplementedError("sub-views are not implemented")
                return _ny_mv_get(_ny_mv_tuple_addr(self, key), c)
            if allsl:
                raise NotImplementedError("multi-dimensional slicing is not implemented")
        raise TypeError("memoryview: invalid slice key")

    def __setitem__(self, key, value):
        self._ny_chk()
        var c = _ny_mv_code(self)
        if self._ny_ro:
            raise TypeError("cannot modify read-only memory")
        var nd = len(self._ny_sh)
        if nd == 0:
            if key is Ellipsis or (isinstance(key, tuple) and len(key) == 0):
                _ny_mv_pack(self, self._ny_a, c, value)
                return None
            raise TypeError("invalid indexing of 0-dim memory")
        if _ny_mv_isindex(key):
            if nd > 1:
                raise NotImplementedError("sub-views are not implemented")
            var i = _ny_mv_index(key)
            _ny_mv_pack(self, _ny_mv_lookup(self, self._ny_a, 0, i), c, value)
            return None
        if isinstance(key, slice) and nd == 1:
            var src = _ny_mv_export(value, "")
            try:
                var t = _ny_mv_sliced(self, key)
                var df = self._ny_f[1:] if self._ny_f[:1] == "@" else self._ny_f
                var sf = src._ny_f[1:] if src._ny_f[:1] == "@" else src._ny_f
                if df != sf or self._ny_i != src._ny_i or len(src._ny_sh) != 1 or src._ny_sh[0] != t[1][0]:
                    raise ValueError("memoryview assignment: lvalue and rvalue have different structures")
                var data = _ny_mv_flat(src)
                if self._ny_mb is None:
                    raise ValueError(_NY_MV_RELEASED)
                if t[2][0] == self._ny_i or t[1][0] <= 1:
                    _mv_write(t[0], data)
                else:
                    _mv_store(t[0], self._ny_i, t[1], t[2], data)
            finally:
                src.release()
            return None
        if isinstance(key, tuple):
            var allidx = True
            var allsl = len(key) > 0
            for k in key:
                if not _ny_mv_isindex(k):
                    allidx = False
                if not isinstance(k, slice):
                    allsl = False
            if allidx:
                if len(key) < nd:
                    raise NotImplementedError("sub-views are not implemented")
                _ny_mv_pack(self, _ny_mv_tuple_addr(self, key), c, value)
                return None
            if allsl:
                raise NotImplementedError("memoryview slice assignments are currently restricted to ndim = 1")
        if isinstance(key, slice):
            raise NotImplementedError("memoryview slice assignments are currently restricted to ndim = 1")
        raise TypeError("memoryview: invalid slice key")

    def __delitem__(self, key):
        self._ny_chk()
        _ny_mv_code(self)
        if self._ny_ro:
            raise TypeError("cannot modify read-only memory")
        raise TypeError("cannot delete memory")

    def __iter__(self):
        self._ny_chk()
        var nd = len(self._ny_sh)
        if nd == 0:
            raise TypeError("invalid indexing of 0-dim memory")
        if nd != 1:
            raise NotImplementedError("multi-dimensional sub-views are not implemented")
        _ny_mv_code(self)
        return _ny_mv_iter(self)

    def __eq__(self, other):
        return _ny_mv_eq(self, other)

    def __ne__(self, other):
        var r = _ny_mv_eq(self, other)
        return r if r is NotImplemented else not r

    def __hash__(self):
        if self._ny_h is not None:
            return self._ny_h
        self._ny_chk()
        if not self._ny_ro:
            raise ValueError("cannot hash writable memoryview object")
        if self._ny_c is None or self._ny_c not in "Bbc":
            raise ValueError("memoryview: hashing is restricted to formats 'B', 'b' or 'c'")
        hash(self._ny_mb.obj)
        var h = hash(_ny_mv_flat(self))
        _ny_setfield(self, "_ny_h", h)
        return h

    def __repr__(self):
        if self._ny_mb is None:
            return "<released memory at " + hex(id(self)) + ">"
        return "<memory at " + hex(id(self)) + ">"

    def __buffer__(self, flags):
        # PEP 688: a new view exported by this one (counted: release() is
        # refused while it lives), shaped by the request's flags as
        # CPython's memory_getbuf
        self._ny_chk()
        flags = _ny_mv_index(flags)
        if flags < -2147483648 or flags > 2147483647:
            raise OverflowError("buffer flags out of range")
        var fl = self._ny_fl
        if (flags & 1) and self._ny_ro:
            raise BufferError("memoryview: underlying buffer is not writable")
        if (flags & 0x38) == 0x38 and not (fl & 1):
            raise BufferError("memoryview: underlying buffer is not C-contiguous")
        if (flags & 0x58) == 0x58 and not (fl & 2):
            raise BufferError("memoryview: underlying buffer is not Fortran contiguous")
        if (flags & 0x98) == 0x98 and fl == 0:
            raise BufferError("memoryview: underlying buffer is not contiguous")
        if (flags & 0x18) != 0x18 and not (fl & 1):
            raise BufferError("memoryview: underlying buffer is not C-contiguous")
        var fmt = self._ny_f if (flags & 4) else "B"
        var sh = self._ny_sh
        var st = self._ny_st
        if (flags & 8) == 0:
            if flags & 4:
                raise BufferError("memoryview: cannot cast to unsigned bytes if the format flag is present")
            sh = (self._ny_n // self._ny_i,)
            st = (self._ny_i,)
        elif (flags & 0x18) != 0x18:
            st = list(sh)
            var acc = self._ny_i
            var i = len(sh) - 1
            while i >= 0:
                st[i] = acc
                acc = acc * sh[i]
                i = i - 1
        var mb = _ny_mbuf(self, self._ny_mb.owner, 3)
        mb.inner = self
        _ny_setfield(self, "_ny_x", self._ny_x + 1)
        return _ny_mv_make(mb, self._ny_a, fmt, self._ny_i, sh, st, self._ny_ro)

    def __release_buffer__(self, view):
        if not isinstance(view, memoryview):
            raise TypeError("expected a memoryview object")
        view.release()
        return None

    def __reduce_ex__(self, protocol):
        raise TypeError("cannot pickle memoryview objects")

    def __reduce__(self):
        raise TypeError("cannot pickle memoryview objects")

def _ny_mv_attach():
    for k, v in list(_NyMemoryview.__dict__.items()):
        if k in ("__dict__", "__weakref__", "__module__", "__qualname__", "__doc__", "__new__", "__init__"):
            continue
        var f = getattr(v, "fget", v)
        if hasattr(f, "__qualname__"):
            try:
                f.__qualname__ = "memoryview." + k
            except (AttributeError, TypeError):
                pass
        setattr(memoryview, k, v)
    return None

_ny_mv_attach()
)NYBUFPRELUDE";
}

}  // namespace nyrt
