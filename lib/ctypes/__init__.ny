# nython: module
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# ctypes - Python's foreign function library (round 83), over the native
# _ffi_* builtins (src/builtins/ffi.cpp): shared libraries, C data types in
# raw memory, calls into C and C-callable callbacks.
#
# Every ctypes instance is a view of native memory, as in CPython: its
# address (_b_addr), the object owning the memory (_b_base_, or none when it
# owns it - _b_needsfree_), and the objects that must outlive it (_objects:
# the buffers its pointers point into). Fields of structures, elements of
# arrays and pointer contents are views sharing their parent's memory.
#
# Provided: the simple types (c_bool, c_char, c_wchar, c_byte/ubyte, short,
# int, long, longlong (and unsigned), c_size_t/ssize_t/time_t, c_intN/uintN,
# c_float/double/longdouble, c_char_p, c_wchar_p, c_void_p) with CPython's
# platform aliases (c_int is c_long where they have one size); Structure and
# Union (_fields_ in the body or assigned once later, bit fields as the C
# compiler lays them out - GCC/Clang's rule, MSVC's on Windows - _pack_,
# _anonymous_, inheritance), BigEndian/LittleEndian structures and unions;
# arrays (T * n, cached), pointers (POINTER, pointer, contents, indexing,
# slicing, cast); byref, addressof, sizeof, alignment, resize,
# create_string_buffer, create_unicode_buffer, string_at, wstring_at,
# memmove, memset; from_buffer (any writable buffer), from_buffer_copy,
# from_address, in_dll; bytes(obj); CDLL/PyDLL (WinDLL/OleDLL on Windows),
# cdll/pydll loaders, LibraryLoader, attribute and ordinal lookup;
# function pointers with restype/argtypes/errcheck, from_param, the
# _as_parameter_ protocol, ArgumentError with CPython's messages, variadic
# calls; CFUNCTYPE/PYFUNCTYPE (WINFUNCTYPE on Windows) for callbacks and for
# function pointers made from an address or (name, dll); use_errno /
# get_errno / set_errno (use_last_error on Windows); ctypes.util, ctypes.wintypes.
#
# The calls go through libffi when the system has it (loaded at run time);
# without it a built-in caller handles scalar arguments and results on
# x86-64, AArch64 (Linux) and 32/64-bit Windows - _ffi_backend() says which.
#
# CPython's audit events (round 86): ctypes.dlopen (name), ctypes.dlsym
# (library, name), ctypes.addressof (obj), ctypes.cdata (address: from_address,
# from_buffer, in_dll), ctypes.cdata/buffer (pointer, size, offset),
# ctypes.create_string_buffer / create_unicode_buffer (init, size),
# ctypes.string_at / wstring_at (ptr, size), ctypes.get_errno / set_errno
# (get_last_error / set_last_error on Windows) - as CPython raises them; not
# ctypes.call_function / dlsym/handle (only CPython's private _ctypes
# functions raise those).
#
# The buffer protocol (round 84): memoryview(obj) is a view of the object's
# memory with CPython 3.12's PEP 3118 format; from_buffer takes any writable
# buffer (bytearray, mmap, array.array, memoryview, ctypes objects) and
# shares its memory, from_buffer_copy any bytes-like object.
#
# Not provided, honestly: ctypes.pythonapi as CPython's C API (Nython has
# none - it is the process's own symbols); paramflags
# (output parameters of prototypes); callbacks returning structures, or
# called on threads Nython did not start; COM (OleDLL's HRESULT check is
# done, COM interfaces are not); pickling of ctypes instances.

import sys as _sys

__version__ = "1.1.0"

DEFAULT_MODE = 0
_plat = _ffi_platform()
_WIN = _plat[0] == "win32"
RTLD_LOCAL = _plat[2]
RTLD_GLOBAL = _plat[3]
if not _WIN:
    DEFAULT_MODE = RTLD_LOCAL

_SIZES = {}
_ALIGNS = {}
for _t in _ffi_typeinfo():
    _SIZES[_t[0]] = _t[1]
    _ALIGNS[_t[0]] = _t[2]

_FLAG_ERRNO = 1
_FLAG_LASTERR = 2
_FLAG_KEEPGIL = 4
_FLAG_STDCALL = 8
_FLAG_VARIADIC = 16

FUNCFLAG_CDECL = 1
FUNCFLAG_USE_ERRNO = 8
FUNCFLAG_USE_LASTERROR = 16
FUNCFLAG_PYTHONAPI = 4
FUNCFLAG_STDCALL = 0

_M64 = 18446744073709551615

def _s64(v):
    # an int as the signed 64-bit word with the same low bits (the natives
    # take int64; a C value is masked to its type's size anyway)
    if v > 9223372036854775807 or v < -9223372036854775808:
        v = v & _M64
        if v > 9223372036854775807:
            v = v - 18446744073709551616
    return v

def _u(v):
    # the natives give an unsigned value past 2**63 as its decimal text
    if isinstance(v, str):
        return int(v)
    return v

_INT_CODES = "bBhHiIlLqQnNt"

class ArgumentError(Exception):
    pass

# ── the metaclasses ────────────────────────────────────────────────────────
class _CDataType(type):
    def __mul__(cls, n):
        return _array_type(cls, n)

    def __rmul__(cls, n):
        return _array_type(cls, n)

class PyCSimpleType(_CDataType):
    pass

class PyCStructType(_CDataType):
    def __setattr__(cls, name, value):
        if name == "_fields_":
            if cls.__dict__.get("_ny_final_", False):
                raise AttributeError("_fields_ is final")
            type.__setattr__(cls, name, value)
            _layout(cls, value, False)
            return
        type.__setattr__(cls, name, value)

class UnionType(_CDataType):
    def __setattr__(cls, name, value):
        if name == "_fields_":
            if cls.__dict__.get("_ny_final_", False):
                raise AttributeError("_fields_ is final")
            type.__setattr__(cls, name, value)
            _layout(cls, value, True)
            return
        type.__setattr__(cls, name, value)

class PyCArrayType(_CDataType):
    pass

class PyCPointerType(_CDataType):
    pass

class PyCFuncPtrType(_CDataType):
    pass

# ── the base of every C data object ─────────────────────────────────────────
class _CData:
    _size_ = 0
    _align_ = 1

    def _ny_alloc(self):
        var n = type(self)._size_
        object.__setattr__(self, "_b_addr", _ffi_alloc(n))
        object.__setattr__(self, "_b_base_", None)
        object.__setattr__(self, "_b_needsfree_", True)
        object.__setattr__(self, "_objects", None)

    def _ny_view(self, addr, base):
        object.__setattr__(self, "_b_addr", addr)
        object.__setattr__(self, "_b_base_", base)
        object.__setattr__(self, "_b_needsfree_", False)
        object.__setattr__(self, "_objects", None)

    def _ny_keep(self, key, obj):
        # keep obj alive as long as this object's memory (CPython's _objects)
        var root = self
        while root._b_base_ is not None:
            root = root._b_base_
        if root._objects is None:
            object.__setattr__(root, "_objects", {})
        elif not isinstance(root._objects, dict):
            # (round 84) from_buffer's memoryview, kept with the rest
            object.__setattr__(root, "_objects", {"-1": root._objects})
        root._objects[str(id(self)) + ":" + str(key)] = obj

    def __del__(self):
        if getattr(self, "_b_needsfree_", False):
            var a = self._b_addr
            object.__setattr__(self, "_b_needsfree_", False)
            _ffi_free(a)

    # the buffer protocol (PEP 3118, PEP 688; round 84): the object's own
    # memory, writable, with the format CPython's ctypes gives (PEP 3118
    # strings: "<i", "T{<i:x:4x<d:y:}", "&<i"), arrays shaped by their
    # lengths, the innermost element's size as itemsize
    def __buffer__(self, flags):
        var t = type(self)
        var info = _pep3118(t)
        return _ny_memview_raw(self, self._b_addr, t._size_, False, info[0], info[1], info[2])

    def __release_buffer__(self, view):
        view.release()

    def __reduce__(self):
        raise ValueError("ctypes objects containing pointers cannot be pickled")

    def __ctypes_from_outparam__(self):
        return self

    @classmethod
    def from_address(cls, address):
        _ny_sys_audit("ctypes.cdata", address)   # round 86
        var o = cls.__new__(cls)
        o._ny_view(address, None)
        return o

    @classmethod
    def from_buffer(cls, source, offset=0):
        # (round 84) any writable buffer - a bytearray, an mmap, an array, a
        # ctypes object, a memoryview: the object is a view of that memory,
        # keeping the export alive (the bytearray cannot be resized while it
        # lives), as CPython's
        var mv = memoryview(source)
        if mv.readonly:
            mv.release()
            raise TypeError("underlying buffer is not writable")
        if not mv.c_contiguous:
            mv.release()
            raise TypeError("underlying buffer is not C contiguous")
        if offset < 0:
            mv.release()
            raise ValueError("offset cannot be negative")
        if cls._size_ > mv.nbytes - offset:
            var n = mv.nbytes
            mv.release()
            raise ValueError("Buffer size too small (" + str(n) + " instead of at least " +
                             str(offset + cls._size_) + " bytes)")
        _ny_sys_audit("ctypes.cdata/buffer", mv._ny_a, mv.nbytes, offset)
        _ny_sys_audit("ctypes.cdata", mv._ny_a + offset)   # (round 86: as CPython's PyCData_AtAddress)
        var o = cls.__new__(cls)
        o._ny_view(mv._ny_a + offset, None)
        object.__setattr__(o, "_objects", mv)
        return o

    @classmethod
    def from_buffer_copy(cls, source, offset=0):
        if _ny_audit_hooks:
            # (round 86) the source buffer's address and size, as CPython's
            var smv = memoryview(source)
            var at = smv._ny_a
            var nb = smv.nbytes
            smv.release()
            _ny_audit_fire("ctypes.cdata/buffer", (at, nb, offset))
        var data = _ny_bytes_like(source)
        if offset < 0:
            raise ValueError("offset cannot be negative")
        if len(data) < offset + cls._size_:
            raise ValueError("Buffer size too small (" + str(len(data)) + " instead of at least " +
                             str(offset + cls._size_) + " bytes)")
        var o = cls.__new__(cls)
        o._ny_alloc()
        _ffi_write(o._b_addr, data[offset:offset + cls._size_])
        return o

    @classmethod
    def in_dll(cls, dll, name):
        var a = _ffi_dlsym(dll._handle, name)
        if a is None:
            raise ValueError("symbol '" + name + "' not found")
        return cls.from_address(a)

# PEP 3118 formats (round 84), as CPython 3.12's ctypes makes them: a simple
# type's code with its byte order ("<i"; int and long by size: "<q" for an
# 8-byte long), a pointer "&" and its target's, a structure "T{...}" of its
# fields ("<fmt>:<name>:", arrays "(n)", padding "Nx" - trailing padding too),
# a union "B".
def _simple_fmt(code, big):
    var pep = code
    if code == "l":
        pep = "q" if _SIZES["l"] == 8 else "l"
    elif code == "L":
        pep = "Q" if _SIZES["L"] == 8 else "L"
    elif code == "i":
        pep = {2: "h", 4: "i", 8: "q"}.get(_SIZES["i"], "i")
    elif code == "I":
        pep = {2: "H", 4: "I", 8: "Q"}.get(_SIZES["I"], "I")
    return (">" if big else "<") + pep

def _fmt_of(t, big=None):
    if big is None:
        big = _BIG
    if issubclass(t, Array):
        var dims = []
        var e = t
        while issubclass(e, Array):
            dims.append(str(e._length_))
            e = e._type_
        return "(" + ",".join(dims) + ")" + _fmt_of(e, big)
    if issubclass(t, _Pointer):
        return "&" + (_fmt_of(t._type_, big) if isinstance(t._type_, type) else "B")
    if issubclass(t, _SimpleCData):
        return _simple_fmt(t._type_, big)
    if issubclass(t, Union):
        return "B"
    if issubclass(t, Structure):
        var sw = getattr(t, "_ny_swapped_", False)
        var fbig = (not _BIG) if sw else _BIG
        var out = "T{"
        var end = 0
        for f in getattr(t, "_ny_fields_all_", []):
            var pad = f.offset - end
            if pad > 0:
                out = out + ("x" if pad == 1 else str(pad) + "x")
            out = out + _fmt_of(f.type, fbig) + ":" + f.name + ":"
            end = max(end, f.offset + f.type._size_)
        var tail = t._size_ - end
        if tail > 0:
            out = out + ("x" if tail == 1 else str(tail) + "x")
        return out + "}"
    return "B"

def _pep3118(t):
    # (format, itemsize, shape) of a type's buffer
    if issubclass(t, Array):
        var shape = []
        var e = t
        while issubclass(e, Array):
            shape.append(e._length_)
            e = e._type_
        return (_fmt_of(e), e._size_, tuple(shape))
    return (_fmt_of(t), t._size_, ())

# A Python value of type `typ` read at `addr`: simple types give their value
# (subclasses of them an instance), others a view owned by `base`.
def _value_at(typ, addr, base):
    if _is_plain_simple(typ):
        return typ._ny_get(addr)
    var o = typ.__new__(typ)
    o._ny_view(addr, base)
    return o

def _is_plain_simple(typ):
    # a simple type itself (c_int), not a subclass of one (class X(c_int))
    return typ.__dict__.get("_ny_simple_", False) is True

# ── simple types ───────────────────────────────────────────────────────────
class _SimpleCData(_CData, metaclass=PyCSimpleType):
    _type_ = "i"

    def __init__(self, value=None):
        self._ny_alloc()
        if value is not None:
            self.value = value

    def __init_subclass__(cls, **kw):
        var code = cls.__dict__.get("_type_", None)
        if code is not None:
            if not isinstance(code, str) or len(code) != 1 or code not in "bBhHiIlLqQnNtfdg?cuPzZ":
                raise AttributeError("class must define a '_type_' attribute which must be\n"
                                     "a single character string containing one of "
                                     "'cbBhHiIlLdfuzZqQPXOv?g'.")
            type.__setattr__(cls, "_size_", _SIZES[code])
            type.__setattr__(cls, "_align_", _ALIGNS[code])
            type.__setattr__(cls, "_ny_simple_", True)
        else:
            type.__setattr__(cls, "_ny_simple_", "subclass")

    @classmethod
    def _ny_get(cls, addr):
        var c = cls._type_
        var v = _ffi_get(addr, c)
        if c in _INT_CODES or c == "P":
            return _u(v)
        return v

    @classmethod
    def _ny_set(cls, addr, value, owner):
        var c = cls._type_
        if c == "z":
            if value is None:
                _ffi_set(addr, "P", 0)
            elif isinstance(value, int):
                _ffi_set(addr, "P", _s64(value))
            elif isinstance(value, (bytes, bytearray)):
                var buf = _cstr_cached(bytes(value))
                _ffi_set(addr, "P", buf._b_addr)
                if owner is not None:
                    owner._ny_keep(addr, buf)
            else:
                raise TypeError("bytes or integer address expected instead of " + type(value).__name__ + " instance")
        elif c == "Z":
            if value is None:
                _ffi_set(addr, "P", 0)
            elif isinstance(value, int):
                _ffi_set(addr, "P", _s64(value))
            elif isinstance(value, str):
                var wb = _cstr_cached(_ffi_wencode(value), _SIZES["u"])
                _ffi_set(addr, "P", wb._b_addr)
                if owner is not None:
                    owner._ny_keep(addr, wb)
            else:
                raise TypeError("unicode string or integer address expected instead of " + type(value).__name__ + " instance")
        elif c == "P":
            if value is None:
                _ffi_set(addr, "P", 0)
            elif isinstance(value, int):
                _ffi_set(addr, "P", _s64(value))
            else:
                var p = _address_of_param(value)
                if p is None:
                    raise TypeError("cannot be converted to pointer")
                _ffi_set(addr, "P", p[0])
                if owner is not None and p[1] is not None:
                    owner._ny_keep(addr, p[1])
        elif c in "fdg":
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise TypeError("must be real number, not " + type(value).__name__)
            _ffi_set(addr, c, float(value))
        elif c == "?":
            _ffi_set(addr, c, bool(value))
        elif c == "c":
            if isinstance(value, (bytes, bytearray)) and len(value) == 1:
                _ffi_set(addr, c, bytes(value))
            elif isinstance(value, int) and not isinstance(value, bool) and 0 <= value < 256:
                _ffi_set(addr, c, value)
            else:
                raise TypeError("one character bytes, bytearray or integer expected")
        elif c == "u":
            if not isinstance(value, str) or len(value) != 1:
                raise TypeError("one character unicode string expected")
            _ffi_set(addr, c, value)
        else:
            if isinstance(value, float) or not isinstance(value, int):
                if hasattr(value, "__index__"):
                    value = value.__index__()
                else:
                    raise TypeError("'" + type(value).__name__ + "' object cannot be interpreted as an integer")
            _ffi_set(addr, c, _s64(int(value)))

    @property
    def value(self):
        return type(self)._ny_get(self._b_addr)

    @value.setter
    def value(self, v):
        type(self)._ny_set(self._b_addr, v, self)

    def __bool__(self):
        return bool(self.value)

    def __repr__(self):
        var cls = type(self)
        var name = cls.__name__
        if cls.__dict__.get("_ny_simple_", False) is not True:
            return "<" + name + " object at " + hex(id(self)) + ">"
        var c = cls._type_
        if c == "z" or c == "Z":
            var p = _u(_ffi_get(self._b_addr, "P"))
            return name + "(" + (str(p) if p else "None") + ")"
        return name + "(" + _pyrepr(self.value) + ")"

    @classmethod
    def from_param(cls, obj):
        return _simple_from_param(cls, obj)

    @classmethod
    def _ny_spec(cls):
        return cls._type_

def _pyrepr(v):
    # CPython's repr, whatever the source mode prints for True/False/None
    if v is True:
        return "True"
    if v is False:
        return "False"
    if v is None:
        return "None"
    return repr(v)

def _simple_type(name, code):
    var cls = PyCSimpleType(name, (_SimpleCData,), {"_type_": code, "__module__": "ctypes"})
    return cls

c_byte = _simple_type("c_byte", "b")
c_ubyte = _simple_type("c_ubyte", "B")
c_short = _simple_type("c_short", "h")
c_ushort = _simple_type("c_ushort", "H")
c_long = _simple_type("c_long", "l")
c_ulong = _simple_type("c_ulong", "L")
if _SIZES["i"] == _SIZES["l"]:
    c_int = c_long
    c_uint = c_ulong
else:
    c_int = _simple_type("c_int", "i")
    c_uint = _simple_type("c_uint", "I")
if _SIZES["q"] == _SIZES["l"]:
    c_longlong = c_long
    c_ulonglong = c_ulong
else:
    c_longlong = _simple_type("c_longlong", "q")
    c_ulonglong = _simple_type("c_ulonglong", "Q")
c_float = _simple_type("c_float", "f")
c_double = _simple_type("c_double", "d")
if _SIZES["g"] == _SIZES["d"]:
    c_longdouble = c_double
else:
    c_longdouble = _simple_type("c_longdouble", "g")
c_bool = _simple_type("c_bool", "?")
c_char = _simple_type("c_char", "c")
c_wchar = _simple_type("c_wchar", "u")
c_char_p = _simple_type("c_char_p", "z")
c_wchar_p = _simple_type("c_wchar_p", "Z")
c_void_p = _simple_type("c_void_p", "P")
c_voidp = c_void_p

def _int_of_size(n, signed):
    for t in ([c_byte, c_short, c_int, c_long, c_longlong] if signed else [c_ubyte, c_ushort, c_uint, c_ulong, c_ulonglong]):
        if t._size_ == n:
            return t
    return None

c_int8 = c_byte
c_uint8 = c_ubyte
c_int16 = _int_of_size(2, True)
c_uint16 = _int_of_size(2, False)
c_int32 = _int_of_size(4, True)
c_uint32 = _int_of_size(4, False)
c_int64 = _int_of_size(8, True)
c_uint64 = _int_of_size(8, False)
c_size_t = _int_of_size(_SIZES["N"], False)
c_ssize_t = _int_of_size(_SIZES["n"], True)
c_time_t = _int_of_size(_SIZES["t"], True)

# A NUL-terminated copy of `data` in native memory (what a c_char_p made
# from bytes points to).
# A bytes/str argument passed as char*/wchar_t* points into a C copy; CPython
# points into the object itself, which outlives the call (strtod's end
# pointer, strchr's result read later). The copies of the last 512 distinct
# values stay alive, so pointers into them remain valid as long.
_cstr_cache = {}
_cstr_order = []

def _cstr_cached(data, unit=1):
    var key = (unit, data)
    var got = _cstr_cache.get(key, None)
    if got is not None:
        return got
    got = _CString(data, unit)
    _cstr_cache[key] = got
    _cstr_order.append(key)
    if len(_cstr_order) > 512:
        var old = _cstr_order.pop(0)
        _cstr_cache.pop(old, None)
    return got

class _CString:
    def __init__(self, data, unit=1):
        self._b_addr = _ffi_alloc(len(data) + unit)
        _ffi_write(self._b_addr, data)

    def __del__(self):
        if self._b_addr:
            _ffi_free(self._b_addr)
            self._b_addr = 0

def _simple_from_param(cls, obj):
    var c = cls._type_
    if isinstance(obj, cls):
        return obj
    if hasattr(obj, "_as_parameter_") and not isinstance(obj, _CData):
        return _simple_from_param(cls, obj._as_parameter_)
    if c == "z":
        if obj is None or isinstance(obj, (bytes, int)) and not isinstance(obj, bool):
            return cls(obj)
        if isinstance(obj, _CArgObject) or isinstance(obj, Array) and obj._type_ is c_char:
            return obj
        if isinstance(obj, _Pointer) and obj._type_ is c_char:
            return obj
        raise TypeError("wrong type")
    if c == "Z":
        if obj is None or isinstance(obj, (str, int)) and not isinstance(obj, bool):
            return cls(obj)
        if isinstance(obj, Array) and obj._type_ is c_wchar or isinstance(obj, _CArgObject):
            return obj
        raise TypeError("wrong type")
    if c == "P":
        if obj is None or isinstance(obj, int) and not isinstance(obj, bool):
            return cls(obj)
        if isinstance(obj, (bytes, str)):
            return (c_char_p if isinstance(obj, bytes) else c_wchar_p)(obj)
        if isinstance(obj, (_Pointer, Array, _CArgObject, _CFuncPtr)) or isinstance(obj, _SimpleCData) and obj._type_ in "zZP":
            return obj
        raise TypeError("wrong type")
    if c in "fdg":
        if isinstance(obj, (int, float)) and not isinstance(obj, bool):
            return cls(obj)
        raise TypeError("wrong type")
    if c == "?":
        return cls(obj)
    if c == "c":
        if isinstance(obj, bytes) and len(obj) == 1 or isinstance(obj, int) and not isinstance(obj, bool):
            return cls(obj)
        raise TypeError("wrong type")
    if c == "u":
        if isinstance(obj, str) and len(obj) == 1:
            return cls(obj)
        raise TypeError("wrong type")
    if isinstance(obj, int):
        return cls(obj)
    raise TypeError("wrong type")

# ── byref ──────────────────────────────────────────────────────────────────
class _CArgObject:
    def __init__(self, obj, offset):
        self._obj = obj
        self._addr = obj._b_addr + offset

    def __repr__(self):
        return "<cparam 'P' (" + hex(self._addr) + ")>"

def byref(obj, offset=0):
    if not isinstance(obj, _CData):
        raise TypeError("byref() argument must be a ctypes instance, not '" + type(obj).__name__ + "'")
    return _CArgObject(obj, offset)

def addressof(obj):
    if not isinstance(obj, _CData):
        raise TypeError("invalid type")
    _ny_sys_audit("ctypes.addressof", obj)   # round 86
    return obj._b_addr

def sizeof(obj):
    if isinstance(obj, type) and issubclass(obj, _CData):
        return obj._size_
    if isinstance(obj, _CData):
        return type(obj)._size_
    raise TypeError("this type has no size")

def alignment(obj):
    if isinstance(obj, type) and issubclass(obj, _CData):
        return obj._align_
    if isinstance(obj, _CData):
        return type(obj)._align_
    raise TypeError("no alignment info")

def resize(obj, size):
    if not obj._b_needsfree_:
        raise ValueError("Memory cannot be resized because this object doesn't own it")
    if size < type(obj)._size_:
        raise ValueError("minimum size is " + str(type(obj)._size_))
    object.__setattr__(obj, "_b_addr", _ffi_realloc(obj._b_addr, size))

# ── structures and unions ──────────────────────────────────────────────────
class CField:
    def __init__(self, name, typ, offset, size, bitofs=-1, bits=0, index=0, swapped=False):
        self.name = name
        self.type = typ
        self.offset = offset
        self.size = size if bits == 0 else (bits << 16) | bitofs
        self._bitofs = bitofs
        self._bits = bits
        self._index = index
        self._swapped = swapped

    def __repr__(self):
        if self._bits:
            return "<Field type=" + self.type.__name__ + ", ofs=" + str(self.offset) + ":" + str(self._bitofs) + ", bits=" + str(self._bits) + ">"
        return "<Field type=" + self.type.__name__ + ", ofs=" + str(self.offset) + ", size=" + str(self.size) + ">"

    def __get__(self, obj, owner=None):
        if obj is None:
            return self
        var addr = obj._b_addr + self.offset
        if self._bits:
            return _u(_ffi_getbits(addr, self.type._type_, self._bitofs, self._bits))
        if self._swapped:
            return _swapped_get(self.type, addr)
        return _value_at(self.type, addr, obj)

    def __set__(self, obj, value):
        var addr = obj._b_addr + self.offset
        if self._bits:
            _ffi_setbits(addr, self.type._type_, self._bitofs, self._bits, _s64(int(value)))
            return
        if self._swapped:
            _swapped_set(self.type, addr, value)
            return
        _store_value(self.type, addr, value, obj)

def _store_value(typ, addr, value, owner):
    if _is_plain_simple(typ):
        if isinstance(value, typ):
            value = value.value
        typ._ny_set(addr, value, owner)
        return
    if isinstance(value, _CData) and isinstance(value, typ):
        _ffi_memmove(addr, value._b_addr, typ._size_)
        if value._objects is not None:
            owner._ny_keep(addr, value)
        return
    if issubclass(typ, _Pointer):
        if value is None:
            _ffi_set(addr, "P", 0)
            return
        if isinstance(value, Array) and value._type_ is typ._type_ or isinstance(value, _CArgObject):
            var a = value._b_addr if isinstance(value, Array) else value._addr
            _ffi_set(addr, "P", a)
            owner._ny_keep(addr, value)
            return
        raise TypeError("incompatible types, " + type(value).__name__ + " instance instead of " + typ.__name__ + " instance")
    if issubclass(typ, Array) and isinstance(value, (bytes, str, tuple, list)):
        var view = typ.__new__(typ)
        view._ny_view(addr, owner)
        if isinstance(value, (tuple, list)):
            var i = 0
            for v in value:
                view[i] = v
                i = i + 1
        else:
            view.value = value
        return
    if issubclass(typ, (Structure, Union)) and isinstance(value, tuple):
        var s = typ.__new__(typ)
        s._ny_view(addr, owner)
        s.__init__(*value)
        return
    if issubclass(typ, _SimpleCData):
        # a subclass of a simple type
        if isinstance(value, _CData):
            value = value.value
        typ._ny_set(addr, value, owner)
        return
    raise TypeError("incompatible types, " + type(value).__name__ + " instance instead of " + typ.__name__ + " instance")

def _swapped_get(typ, addr):
    var raw = _ffi_read(addr, typ._size_)
    var tmp = _ffi_alloc(typ._size_)
    _ffi_write(tmp, raw[::-1])
    var v = typ._ny_get(tmp)
    _ffi_free(tmp)
    return v

def _swapped_set(typ, addr, value):
    var tmp = _ffi_alloc(typ._size_)
    typ._ny_set(tmp, value, None)
    _ffi_write(addr, _ffi_read(tmp, typ._size_)[::-1])
    _ffi_free(tmp)

def _align_up(n, a):
    return (n + a - 1) // a * a

def _layout(cls, fields, is_union):
    if not isinstance(fields, (list, tuple)):
        raise TypeError("_fields_ must be a sequence of pairs")
    var base = None
    for b in cls.__mro__[1:]:
        if isinstance(b, (PyCStructType, UnionType)) and "_ny_fields_all_" in b.__dict__:
            base = b
            break
    var pack = getattr(cls, "_pack_", 0)
    if pack and (not isinstance(pack, int) or pack < 0):
        raise ValueError("_pack_ must be a non-negative integer")
    var swapped = getattr(cls, "_ny_swapped_", False)
    var offset = base._size_ if base is not None and not is_union else 0
    var align = base._align_ if base is not None else 1
    var size = 0
    var allf = list(base._ny_fields_all_) if base is not None else []
    var bitpos = -1          # bit position inside the current bit-field run
    var unit_ofs = 0
    var unit_size = 0
    var spec = list(base._ny_spec_parts_) if base is not None else []
    var has_bits = base is not None and base.__dict__.get("_ny_has_bits_", False)
    var index = len(allf)
    for f in fields:
        if not isinstance(f, (tuple, list)) or len(f) < 2:
            raise TypeError("'_fields_' must be a sequence of (name, C type) pairs")
        var name = f[0]
        var typ = f[1]
        if not isinstance(typ, type) or not issubclass(typ, _CData):
            raise TypeError("second item in _fields_ tuple (index " + str(index) + ") must be a C type")
        var fsize = typ._size_
        var falign = typ._align_
        if pack:
            falign = min(falign, pack)
        if len(f) > 2:
            has_bits = True
            var bits = f[2]
            if not _is_plain_simple(typ) or typ._type_ not in "bBhHiIlLqQ?":
                raise TypeError("bit fields not allowed for type " + typ.__name__)
            if bits <= 0 or bits > fsize * 8:
                raise ValueError("number of bits invalid for bit field '" + name + "'")
            var unit_bits = fsize * 8
            if is_union:
                var cf = CField(name, typ, 0, fsize, 0, bits, index)
                size = max(size, fsize)
            else:
                if _WIN:
                    # MSVC: a run shares a unit while the type's size stays the same
                    if bitpos < 0 or unit_size != fsize or bitpos + bits > unit_bits:
                        offset = _align_up(offset if bitpos < 0 else unit_ofs + unit_size, falign)
                        unit_ofs = offset
                        unit_size = fsize
                        bitpos = 0
                        offset = unit_ofs + fsize
                    var cf = CField(name, typ, unit_ofs, fsize, bitpos, bits, index)
                    bitpos = bitpos + bits
                else:
                    # GCC/Clang: placed at the next free bit unless it would
                    # cross a boundary of its type's alignment unit
                    var curbit = offset * 8 if bitpos < 0 else unit_ofs * 8 + bitpos
                    var ubytes = falign
                    var start = (curbit // (ubytes * 8)) * ubytes
                    if curbit + bits > start * 8 + unit_bits:
                        start = _align_up((curbit + 7) // 8, ubytes)
                        curbit = start * 8
                    unit_ofs = start
                    bitpos = curbit - start * 8
                    var cf = CField(name, typ, unit_ofs, fsize, bitpos, bits, index)
                    bitpos = bitpos + bits
                    offset = max(offset, (unit_ofs * 8 + bitpos + 7) // 8)
                    unit_size = fsize
        else:
            if is_union:
                var cf = CField(name, typ, 0, fsize, -1, 0, index, swapped)
                size = max(size, fsize)
            else:
                if bitpos >= 0:
                    if _WIN:
                        offset = unit_ofs + unit_size
                    bitpos = -1
                offset = _align_up(offset, falign)
                var cf = CField(name, typ, offset, fsize, -1, 0, index, swapped)
                offset = offset + fsize
        align = max(align, falign)
        type.__setattr__(cls, name, cf)
        allf.append(cf)
        spec.append(typ._ny_spec())
        index = index + 1
    if is_union:
        type.__setattr__(cls, "_size_", _align_up(max(size, base._size_ if base is not None else 0), align))
    else:
        type.__setattr__(cls, "_size_", _align_up(offset, align))
    type.__setattr__(cls, "_align_", align)
    type.__setattr__(cls, "_ny_fields_all_", allf)
    if has_bits or pack:
        # libffi cannot express bit fields or packing: the struct as words
        # of its alignment (classified as integers, as such a struct is)
        var al = cls._align_
        var unit = {1: "B", 2: "H", 4: "I", 8: "Q"}.get(al, "B")
        if unit == "B":
            al = 1
        spec = ["[" + str(cls._size_ // al) + unit + "]"]
    type.__setattr__(cls, "_ny_spec_parts_", spec)
    type.__setattr__(cls, "_ny_has_bits_", has_bits)
    type.__setattr__(cls, "_ny_final_", True)
    var anon = cls.__dict__.get("_anonymous_", None)
    if anon:
        for an in anon:
            var af = cls.__dict__.get(an, None)
            if not isinstance(af, CField):
                raise AttributeError("'" + an + "' is specified in _anonymous_ but not in _fields_")
            for sub in af.type._ny_fields_all_:
                type.__setattr__(cls, sub.name, _AnonField(af, sub))

class _AnonField:
    def __init__(self, outer, inner):
        self._outer = outer
        self._inner = inner

    def __get__(self, obj, owner=None):
        if obj is None:
            return self._inner
        return self._inner.__get__(self._outer.__get__(obj))

    def __set__(self, obj, value):
        self._inner.__set__(self._outer.__get__(obj), value)

class _StructBase(_CData):
    def __init__(self, *args, **kwargs):
        self._ny_alloc()
        var fields = type(self).__dict__.get("_ny_fields_all_", None)
        if fields is None:
            fields = getattr(type(self), "_ny_fields_all_", [])
        if len(args) > len(fields):
            raise TypeError("too many initializers")
        var i = 0
        for a in args:
            setattr(self, fields[i].name, a)
            i = i + 1
        for k in kwargs:
            var j = 0
            while j < len(args):
                if fields[j].name == k:
                    raise TypeError("duplicate values for field '" + k + "'")
                j = j + 1
            setattr(self, k, kwargs[k])

    def __init_subclass__(cls, **kw):
        var f = cls.__dict__.get("_fields_", None)
        if f is not None:
            _layout(cls, f, isinstance(cls, UnionType))
        else:
            # inherits the base's layout until it gets fields of its own
            for b in cls.__mro__[1:]:
                if "_ny_fields_all_" in b.__dict__:
                    type.__setattr__(cls, "_size_", b._size_)
                    type.__setattr__(cls, "_align_", b._align_)
                    break

    @classmethod
    def from_param(cls, obj):
        if isinstance(obj, cls):
            return obj
        if isinstance(obj, tuple):
            return cls(*obj)
        raise TypeError("expected " + cls.__name__ + " instance instead of " + type(obj).__name__)

    @classmethod
    def _ny_spec(cls):
        if isinstance(cls, UnionType):
            # a union by value: its largest member (libffi has no unions)
            var best = None
            for f in getattr(cls, "_ny_fields_all_", []):
                if best is None or f.type._size_ > best.type._size_:
                    best = f
            if best is None:
                return "{}"
            var s = best.type._ny_spec()
            var pad = cls._size_ - best.type._size_
            return "{" + s + ("[" + str(pad) + "B]" if pad > 0 else "") + "}"
        return "{" + "".join(getattr(cls, "_ny_spec_parts_", [])) + "}"

class Structure(_StructBase, metaclass=PyCStructType):
    pass

class Union(_StructBase, metaclass=UnionType):
    pass

def _swapped_init_subclass(cls, union):
    type.__setattr__(cls, "_ny_swapped_", True)

_BIG = _sys.byteorder == "big"

class _SwappedStructType(PyCStructType):
    pass

class _SwappedUnionType(UnionType):
    pass

class BigEndianStructure(Structure, metaclass=_SwappedStructType):
    _ny_swapped_ = not _BIG

class LittleEndianStructure(Structure, metaclass=_SwappedStructType):
    _ny_swapped_ = _BIG

class BigEndianUnion(Union, metaclass=_SwappedUnionType):
    _ny_swapped_ = not _BIG

class LittleEndianUnion(Union, metaclass=_SwappedUnionType):
    _ny_swapped_ = _BIG

# ── arrays ─────────────────────────────────────────────────────────────────
class Array(_CData, metaclass=PyCArrayType):
    _type_ = None
    _length_ = 0

    def __init__(self, *args):
        self._ny_alloc()
        if len(args) > type(self)._length_:
            raise IndexError("invalid index")
        var i = 0
        for a in args:
            self[i] = a
            i = i + 1

    def __len__(self):
        return type(self)._length_

    def _ny_index(self, i):
        var n = type(self)._length_
        if not isinstance(i, int):
            raise TypeError("indices must be integers")
        if i < 0:
            i = i + n
        if i < 0 or i >= n:
            raise IndexError("invalid index")
        return i

    def __getitem__(self, i):
        var t = type(self)._type_
        if isinstance(i, slice):
            var items = [self[k] for k in range(*i.indices(len(self)))]
            if t is c_char:
                return b"".join(items)
            if t is c_wchar:
                return "".join(items)
            return items
        i = self._ny_index(i)
        return _value_at(t, self._b_addr + i * t._size_, self)

    def __setitem__(self, i, v):
        var t = type(self)._type_
        if isinstance(i, slice):
            var ks = list(range(*i.indices(len(self))))
            if len(ks) != len(v):
                raise ValueError("Can only assign sequence of same size")
            var j = 0
            for k in ks:
                self[k] = v[j]
                j = j + 1
            return
        i = self._ny_index(i)
        _store_value(t, self._b_addr + i * t._size_, v, self)

    def __iter__(self):
        var i = 0
        var n = len(self)
        while i < n:
            yield self[i]
            i = i + 1

    @property
    def value(self):
        var t = type(self)._type_
        if t is c_char:
            var raw = _ffi_read(self._b_addr, len(self))
            var z = raw.find(b"\x00")
            return raw if z < 0 else raw[:z]
        if t is c_wchar:
            var s = _ffi_wdecode(_ffi_read(self._b_addr, len(self) * t._size_))
            var z = s.find("\x00")
            return s if z < 0 else s[:z]
        raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'value'")

    @value.setter
    def value(self, v):
        var t = type(self)._type_
        if t is c_char:
            if not isinstance(v, (bytes, bytearray)):
                raise TypeError("bytes expected instead of " + type(v).__name__ + " instance")
            if len(v) > len(self):
                raise ValueError("byte string too long")
            _ffi_write(self._b_addr, bytes(v))
            if len(v) < len(self):
                _ffi_set(self._b_addr + len(v), "c", 0)
            return
        if t is c_wchar:
            if not isinstance(v, str):
                raise TypeError("unicode string expected instead of " + type(v).__name__ + " instance")
            if len(v) > len(self):
                raise ValueError("string too long")
            _ffi_write(self._b_addr, _ffi_wencode(v))
            if len(v) < len(self):
                _ffi_set(self._b_addr + len(v) * t._size_, "u", "\x00")
            return
        raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'value'")

    @property
    def raw(self):
        if type(self)._type_ is not c_char:
            raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'raw'")
        return _ffi_read(self._b_addr, len(self))

    @raw.setter
    def raw(self, v):
        if type(self)._type_ is not c_char:
            raise AttributeError("'" + type(self).__name__ + "' object has no attribute 'raw'")
        if len(v) > len(self):
            raise ValueError("byte string too long")
        _ffi_write(self._b_addr, bytes(v))

    @classmethod
    def from_param(cls, obj):
        if isinstance(obj, cls):
            return obj
        raise TypeError("expected " + cls.__name__ + " instance instead of " + type(obj).__name__)

    @classmethod
    def _ny_spec(cls):
        return "{[" + str(cls._length_) + cls._type_._ny_spec() + "]}"

_array_types = {}

def _array_type(typ, n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("can't multiply sequence by non-int of type '" + type(n).__name__ + "'")
    if n < 0:
        raise ValueError("Array length must be >= 0, not " + str(n))
    var key = (id(typ), n)
    var got = _array_types.get(key, None)
    if got is not None:
        return got
    var cls = PyCArrayType(typ.__name__ + "_Array_" + str(n), (Array,),
                           {"_type_": typ, "_length_": n, "__module__": "ctypes"})
    type.__setattr__(cls, "_size_", typ._size_ * n)
    type.__setattr__(cls, "_align_", typ._align_)
    _array_types[key] = cls
    _keepalive_types.append(typ)
    return cls

_keepalive_types = []

def ARRAY(typ, length):
    return typ * length

# ── pointers ───────────────────────────────────────────────────────────────
class _Pointer(_CData, metaclass=PyCPointerType):
    _type_ = None
    _size_ = _SIZES["P"]
    _align_ = _ALIGNS["P"]

    def __init__(self, obj=None):
        self._ny_alloc()
        if obj is not None:
            self.contents = obj

    def _ny_target(self):
        return _u(_ffi_get(self._b_addr, "P")) or 0

    @property
    def contents(self):
        var a = self._ny_target()
        if not a:
            raise ValueError("NULL pointer access")
        var t = type(self)._type_
        var o = t.__new__(t)
        o._ny_view(a, None)
        object.__setattr__(o, "_objects", self._objects)
        return o

    @contents.setter
    def contents(self, obj):
        var t = type(self)._type_
        if not isinstance(obj, t):
            raise TypeError("expected " + t.__name__ + " instead of " + type(obj).__name__)
        _ffi_set(self._b_addr, "P", obj._b_addr)
        self._ny_keep("contents", obj)

    def __getitem__(self, i):
        var t = type(self)._type_
        var a = self._ny_target()
        if isinstance(i, slice):
            if i.stop is None:
                raise ValueError("slice stop is required")
            var items = [self[k] for k in range(i.start or 0, i.stop, i.step or 1)]
            if t is c_char:
                return b"".join(items)
            if t is c_wchar:
                return "".join(items)
            return items
        if not a:
            raise ValueError("NULL pointer access")
        return _value_at(t, a + i * t._size_, self)

    def __setitem__(self, i, v):
        var t = type(self)._type_
        var a = self._ny_target()
        if not a:
            raise ValueError("NULL pointer access")
        _store_value(t, a + i * t._size_, v, self)

    def __bool__(self):
        return self._ny_target() != 0

    def __repr__(self):
        return "<" + type(self).__module__ + "." + type(self).__name__ + " object at " + hex(id(self)) + ">"

    @classmethod
    def from_param(cls, obj):
        if obj is None or isinstance(obj, cls):
            return obj
        if isinstance(obj, _CArgObject) and isinstance(obj._obj, cls._type_):
            return obj
        if isinstance(obj, cls._type_):
            return byref(obj)
        if isinstance(obj, Array) and issubclass(obj._type_, cls._type_):
            return obj
        if isinstance(obj, _Pointer) and obj._type_ is cls._type_:
            return obj
        raise TypeError("expected " + cls.__name__ + " instance instead of " + type(obj).__name__)

    @classmethod
    def _ny_spec(cls):
        return "P"

_pointer_types = {}

def POINTER(typ):
    if typ is None:
        return c_void_p
    var key = id(typ)
    var got = _pointer_types.get(key, None)
    if got is not None:
        return got
    if isinstance(typ, str):
        var cls = PyCPointerType("LP_" + typ, (_Pointer,), {"__module__": "ctypes"})
        _pointer_types[key] = cls
        return cls
    var cls = PyCPointerType("LP_" + typ.__name__, (_Pointer,), {"_type_": typ, "__module__": "ctypes"})
    _pointer_types[key] = cls
    _keepalive_types.append(typ)
    return cls

def pointer(obj):
    return POINTER(type(obj))(obj)

def SetPointerType(pointer_cls, cls):
    type.__setattr__(pointer_cls, "_type_", cls)

def cast(obj, typ):
    var a = _address_of_param(obj)
    if a is None:
        raise ArgumentError("argument 1: TypeError: wrong type")
    if not (isinstance(typ, type) and (issubclass(typ, (_Pointer, _CFuncPtr)) or
                                       issubclass(typ, _SimpleCData) and typ._type_ in "zZP")):
        raise TypeError("cast() argument 2 must be a pointer type, not " + type(typ).__name__)
    var r = typ.__new__(typ)
    r._ny_alloc()
    _ffi_set(r._b_addr, "P", a[0])
    if a[1] is not None:
        r._ny_keep("cast", a[1])
    return r

# (address, object to keep alive) of anything that can stand for a pointer
def _address_of_param(obj):
    if obj is None:
        return (0, None)
    if isinstance(obj, int) and not isinstance(obj, bool):
        return (_s64(obj), None)
    if isinstance(obj, _CArgObject):
        return (obj._addr, obj._obj)
    if isinstance(obj, (Array, _StructBase)):
        return (obj._b_addr, obj)
    if isinstance(obj, (_Pointer, _CFuncPtr)):
        return (_u(_ffi_get(obj._b_addr, "P")) or 0, obj)
    if isinstance(obj, _SimpleCData):
        if obj._type_ in "zZP":
            return (_u(_ffi_get(obj._b_addr, "P")) or 0, obj)
        return (obj._b_addr, obj)
    if isinstance(obj, bytes):
        var b = _CString(obj)
        return (b._b_addr, b)
    if isinstance(obj, str):
        var w = _CString(_ffi_wencode(obj), _SIZES["u"])
        return (w._b_addr, w)
    return None

# ── buffers and raw memory ─────────────────────────────────────────────────
def create_string_buffer(init, size=None):
    if isinstance(init, (bytes, bytearray)):
        if size is None:
            size = len(init) + 1
        _ny_sys_audit("ctypes.create_string_buffer", init, size)   # round 86
        var buf = (c_char * size)()
        buf.raw = bytes(init)[:size]
        return buf
    if isinstance(init, int):
        _ny_sys_audit("ctypes.create_string_buffer", None, init)
        return (c_char * init)()
    raise TypeError(repr(init))

c_buffer = create_string_buffer

def create_unicode_buffer(init, size=None):
    if isinstance(init, str):
        if size is None:
            size = len(_ffi_wencode(init)) // _SIZES["u"] + 1
        _ny_sys_audit("ctypes.create_unicode_buffer", init, size)   # round 86
        var buf = (c_wchar * size)()
        buf.value = init
        return buf
    if isinstance(init, int):
        _ny_sys_audit("ctypes.create_unicode_buffer", None, init)
        return (c_wchar * init)()
    raise TypeError(repr(init))

def string_at(ptr, size=-1):
    var a = _address_of_param(ptr)[0]
    _ny_sys_audit("ctypes.string_at", a, size)   # round 86
    if size < 0:
        size = _ffi_strlen(a)
    return _ffi_read(a, size)

def wstring_at(ptr, size=-1):
    var a = _address_of_param(ptr)[0]
    _ny_sys_audit("ctypes.wstring_at", a, size)   # round 86
    if size < 0:
        size = _ffi_wcslen(a)
    return _ffi_wdecode(_ffi_read(a, size * _SIZES["u"]))

def memmove(dst, src, count):
    return _ffi_memmove(_address_of_param(dst)[0], _address_of_param(src)[0], count)

def memset(dst, c, count):
    return _ffi_memset(_address_of_param(dst)[0], c, count)

# ── errno ──────────────────────────────────────────────────────────────────
def get_errno():
    _ny_sys_audit("ctypes.get_errno")   # round 86
    return _ffi_errno(False, 0)

def set_errno(value):
    _ny_sys_audit("ctypes.set_errno", value)
    return _ffi_errno(True, value)

if _WIN:
    def get_last_error():
        _ny_sys_audit("ctypes.get_last_error")   # round 86
        return _ffi_last_error(False, 0)

    def set_last_error(value):
        _ny_sys_audit("ctypes.set_last_error", value)
        return _ffi_last_error(True, value)

    def GetLastError():
        return _ffi_last_error(False, 0)

    def FormatError(code=None):
        return "Windows Error " + str(code if code is not None else GetLastError())

    def WinError(code=None, descr=None):
        if code is None:
            code = GetLastError()
        if descr is None:
            descr = FormatError(code).strip()
        return OSError(None, descr, None, code)

# ── foreign functions ──────────────────────────────────────────────────────
def _argspec(conv, i):
    # (type spec, value for _ffi_call, object to keep alive) of a converted argument
    if conv is None:
        return ("P", 0, None)
    if isinstance(conv, _CArgObject):
        return ("P", conv._addr, conv._obj)
    if isinstance(conv, _SimpleCData):
        var c = type(conv)._type_
        if c in "zZP":
            return ("P", _u(_ffi_get(conv._b_addr, "P")) or 0, conv)
        return (c, conv.value, None)
    if isinstance(conv, _StructBase):
        return (type(conv)._ny_spec(), conv._b_addr, conv)
    if isinstance(conv, (Array,)):
        return ("P", conv._b_addr, conv)
    if isinstance(conv, (_Pointer, _CFuncPtr)):
        return ("P", _u(_ffi_get(conv._b_addr, "P")) or 0, conv)
    raise ArgumentError("argument " + str(i + 1) + ": TypeError: Don't know how to convert parameter " + str(i + 1))

def _default_conv(a, i):
    # an argument without an argtypes entry (CPython's ConvParam)
    if hasattr(a, "_as_parameter_") and not isinstance(a, _CData):
        return _default_conv(a._as_parameter_, i)
    if a is None:
        return ("P", 0, None)
    if isinstance(a, bool):
        return ("i", int(a), None)
    if isinstance(a, int):
        return ("i", _s64(a), None)
    if isinstance(a, bytes):
        var b = _cstr_cached(a)
        return ("P", b._b_addr, b)
    if isinstance(a, str):
        var w = _cstr_cached(_ffi_wencode(a), _SIZES["u"])
        return ("P", w._b_addr, w)
    if isinstance(a, (_CData, _CArgObject)):
        return _argspec(a, i)
    raise ArgumentError("argument " + str(i + 1) + ": TypeError: Don't know how to convert parameter " + str(i + 1))

def _restype_spec(rt):
    if rt is None:
        return "v"
    if isinstance(rt, type) and issubclass(rt, _CData):
        return rt._ny_spec()
    if callable(rt):
        return "i"
    raise TypeError("restype must be a type, a callable, or None")

def _convert_result(rt, raw, func, args):
    if rt is None:
        return None
    if isinstance(rt, type) and issubclass(rt, _CData):
        if _is_plain_simple(rt):
            var c = rt._type_
            if c in _INT_CODES or c == "P":
                return _u(raw)
            return raw
        if issubclass(rt, _SimpleCData):
            var o = rt()
            if rt._type_ in "zZP":
                _ffi_set(o._b_addr, "P", _s64(_u(raw) or 0) if isinstance(raw, (int, str)) else 0)
            else:
                o.value = _u(raw) if rt._type_ in _INT_CODES else raw
            return o
        if issubclass(rt, (_Pointer, _CFuncPtr)):
            var p = rt.__new__(rt)
            p._ny_alloc()
            _ffi_set(p._b_addr, "P", _s64(_u(raw) or 0))
            return p
        if issubclass(rt, _StructBase):
            return rt.from_buffer_copy(raw)
        return raw
    return rt(raw)

class _CFuncPtr(_CData, metaclass=PyCFuncPtrType):
    _flags_ = FUNCFLAG_CDECL
    _restype_ = c_int
    _argtypes_ = None
    _size_ = _SIZES["P"]
    _align_ = _ALIGNS["P"]

    def __init__(self, *args):
        self._ny_alloc()
        object.__setattr__(self, "_ny_restype", getattr(type(self), "_restype_", c_int))
        object.__setattr__(self, "_ny_argtypes", getattr(type(self), "_argtypes_", None))
        object.__setattr__(self, "_ny_errcheck", None)
        object.__setattr__(self, "_ny_cb", 0)
        object.__setattr__(self, "_ny_cbfn", None)
        object.__setattr__(self, "__name__", "")
        if len(args) == 0:
            return
        var a = args[0]
        if isinstance(a, int) and not isinstance(a, bool):
            _ffi_set(self._b_addr, "P", _s64(a))
        elif isinstance(a, tuple):
            var name = a[0]
            var dll = a[1]
            _ny_sys_audit("ctypes.dlsym", dll, name)   # round 86
            var addr = _ffi_dlsym(dll._handle, name) if isinstance(name, str) else None
            if addr is None:
                raise AttributeError("function '" + str(name) + "' not found")
            _ffi_set(self._b_addr, "P", addr)
            object.__setattr__(self, "__name__", name)
        elif callable(a):
            self._ny_make_callback(a)
        else:
            raise TypeError("argument must be callable or integer function address")

    def _ny_make_callback(self, fn):
        var cls = type(self)
        var argtypes = list(cls._argtypes_ or [])
        var rt = getattr(cls, "_restype_", c_int)
        for t in argtypes:
            if not (isinstance(t, type) and issubclass(t, _CData)):
                raise TypeError("item in _argtypes_ has no from_param method")
        def wrapper(*cargs):
            var pyargs = []
            var i = 0
            for v in cargs:
                var t = argtypes[i]
                if _is_plain_simple(t):
                    if t._type_ in _INT_CODES or t._type_ == "P":
                        v = _u(v)
                    pyargs.append(v)
                elif issubclass(t, _StructBase):
                    pyargs.append(t.from_buffer_copy(v))
                elif issubclass(t, (_Pointer, _CFuncPtr)) or issubclass(t, _SimpleCData):
                    var o = t.__new__(t)
                    o._ny_alloc()
                    if issubclass(t, _SimpleCData) and t._type_ not in "zZP":
                        o.value = v
                    else:
                        _ffi_set(o._b_addr, "P", _s64(_u(v) or 0) if not isinstance(v, (bytes, str)) else 0)
                    pyargs.append(o)
                else:
                    pyargs.append(v)
                i = i + 1
            var r = fn(*pyargs)
            if rt is None:
                return None
            if isinstance(r, _SimpleCData):
                r = r.value
            if isinstance(r, bool):
                r = int(r)
            return r
        var specs = [t._ny_spec() for t in argtypes]
        var got = _ffi_callback(wrapper, cls._ny_native_flags(), _restype_spec(rt), specs)
        _ffi_set(self._b_addr, "P", got[0])
        object.__setattr__(self, "_ny_cb", got[1])
        object.__setattr__(self, "_ny_cbfn", fn)

    def __del__(self):
        var cb = getattr(self, "_ny_cb", 0)
        if cb:
            object.__setattr__(self, "_ny_cb", 0)
            _ffi_callback_free(cb)
        _CData.__del__(self)

    @classmethod
    def _ny_native_flags(cls):
        var f = 0
        if cls._flags_ & FUNCFLAG_USE_ERRNO:
            f = f | _FLAG_ERRNO
        if cls._flags_ & FUNCFLAG_USE_LASTERROR:
            f = f | _FLAG_LASTERR
        if cls._flags_ & FUNCFLAG_PYTHONAPI:
            f = f | _FLAG_KEEPGIL
        if _WIN and not (cls._flags_ & FUNCFLAG_CDECL):
            f = f | _FLAG_STDCALL
        return f

    @property
    def restype(self):
        return self._ny_restype

    @restype.setter
    def restype(self, t):
        if t is not None and not (isinstance(t, type) and issubclass(t, _CData)) and not callable(t):
            raise TypeError("restype must be a type, a callable, or None")
        object.__setattr__(self, "_ny_restype", t)

    @property
    def argtypes(self):
        return self._ny_argtypes

    @argtypes.setter
    def argtypes(self, ts):
        if ts is None:
            object.__setattr__(self, "_ny_argtypes", None)
            return
        var out = []
        var i = 0
        for t in ts:
            if not hasattr(t, "from_param"):
                raise TypeError("item " + str(i + 1) + " in _argtypes_ has no from_param method")
            out.append(t)
            i = i + 1
        object.__setattr__(self, "_ny_argtypes", tuple(out))

    @property
    def errcheck(self):
        return self._ny_errcheck

    @errcheck.setter
    def errcheck(self, f):
        if f is not None and not callable(f):
            raise TypeError("the errcheck attribute must be callable")
        object.__setattr__(self, "_ny_errcheck", f)

    def __bool__(self):
        return (_u(_ffi_get(self._b_addr, "P")) or 0) != 0

    def __repr__(self):
        if self.__name__:
            return "<" + type(self).__name__ + " object at " + hex(id(self)) + ">"
        return "<" + type(self).__name__ + " object at " + hex(id(self)) + ">"

    def __call__(self, *args, **kwargs):
        if kwargs:
            raise TypeError("this function takes no keyword arguments")
        var fn = _u(_ffi_get(self._b_addr, "P")) or 0
        if not fn:
            raise ValueError("NULL function pointer")
        var argtypes = self._ny_argtypes
        var specs = []
        var vals = []
        var keep = []
        var nfixed = len(args)
        var flags = type(self)._ny_native_flags()
        if argtypes is not None:
            if len(args) < len(argtypes):
                raise TypeError("this function takes at least " + str(len(argtypes)) + " argument" +
                                ("s" if len(argtypes) != 1 else "") + " (" + str(len(args)) + " given)")
            if len(args) > len(argtypes) and not (type(self)._flags_ & FUNCFLAG_CDECL):
                raise TypeError("this function takes " + str(len(argtypes)) + " argument" +
                                ("s" if len(argtypes) != 1 else "") + " (" + str(len(args)) + " given)")
            nfixed = len(argtypes)
            if len(args) > len(argtypes):
                flags = flags | _FLAG_VARIADIC
        var i = 0
        for a in args:
            var sp = None
            if argtypes is not None and i < len(argtypes):
                var conv = None
                try:
                    conv = argtypes[i].from_param(a)
                except ArgumentError:
                    raise
                except Exception as e:
                    raise ArgumentError("argument " + str(i + 1) + ": " + type(e).__name__ + ": " + str(e))
                if hasattr(conv, "_as_parameter_") and not isinstance(conv, (_CData, _CArgObject)):
                    conv = conv._as_parameter_
                if isinstance(conv, int) and not isinstance(conv, bool):
                    sp = ("P" if argtypes[i]._ny_spec() in "PzZ" else argtypes[i]._ny_spec(), _s64(conv), None)
                else:
                    sp = _argspec(conv, i)
            else:
                sp = _default_conv(a, i)
                if flags & _FLAG_VARIADIC and sp[0] == "f":
                    sp = ("d", sp[1], sp[2])
            specs.append(sp[0])
            var v = sp[1]
            if isinstance(v, int) and not isinstance(v, bool):
                v = _s64(v)
            vals.append(v)
            keep.append(sp[2])
            i = i + 1
        var rt = self._ny_restype
        var raw = _ffi_call(fn, flags, nfixed, _restype_spec(rt), specs, vals)
        var result = _convert_result(rt, raw, self, args)
        if self._ny_errcheck is not None:
            result = self._ny_errcheck(result, self, args)
        return result

    @classmethod
    def from_param(cls, obj):
        if obj is None or isinstance(obj, cls):
            return obj
        if isinstance(obj, _CFuncPtr):
            return obj
        if isinstance(obj, int):
            return obj
        raise TypeError("expected CFunctionType instance instead of " + type(obj).__name__)

    @classmethod
    def _ny_spec(cls):
        return "P"

_c_functype_cache = {}

def CFUNCTYPE(restype, *argtypes, use_errno=False, use_last_error=False):
    var flags = FUNCFLAG_CDECL
    if use_errno:
        flags = flags | FUNCFLAG_USE_ERRNO
    if use_last_error:
        flags = flags | FUNCFLAG_USE_LASTERROR
    var key = (id(restype), tuple(id(t) for t in argtypes), flags)
    var got = _c_functype_cache.get(key, None)
    if got is not None:
        return got
    var cls = PyCFuncPtrType("CFunctionType", (_CFuncPtr,),
                             {"_argtypes_": argtypes, "_restype_": restype, "_flags_": flags, "__module__": "ctypes"})
    _c_functype_cache[key] = cls
    _keepalive_types.append([restype, argtypes])
    return cls

def PYFUNCTYPE(restype, *argtypes):
    return PyCFuncPtrType("CFunctionType", (_CFuncPtr,),
                          {"_argtypes_": argtypes, "_restype_": restype,
                           "_flags_": FUNCFLAG_CDECL | FUNCFLAG_PYTHONAPI, "__module__": "ctypes"})

if _WIN:
    def WINFUNCTYPE(restype, *argtypes, use_errno=False, use_last_error=False):
        var flags = FUNCFLAG_STDCALL
        if use_errno:
            flags = flags | FUNCFLAG_USE_ERRNO
        if use_last_error:
            flags = flags | FUNCFLAG_USE_LASTERROR
        return PyCFuncPtrType("WinFunctionType", (_CFuncPtr,),
                              {"_argtypes_": argtypes, "_restype_": restype, "_flags_": flags, "__module__": "ctypes"})

# ── shared libraries ───────────────────────────────────────────────────────
class CDLL:
    _func_flags_ = FUNCFLAG_CDECL
    _func_restype_ = c_int
    _name = None
    _handle = 0

    def __init__(self, name, mode=DEFAULT_MODE, handle=None, use_errno=False, use_last_error=False, winmode=None):
        if name is not None and hasattr(name, "__fspath__"):
            name = name.__fspath__()
        self._name = name
        var flags = self._func_flags_
        if use_errno:
            flags = flags | FUNCFLAG_USE_ERRNO
        if use_last_error:
            flags = flags | FUNCFLAG_USE_LASTERROR
        var restype = self._func_restype_
        class _FuncPtr(_CFuncPtr):
            _flags_ = flags
            _restype_ = restype
        self._FuncPtr = _FuncPtr
        if handle is None:
            var m = mode
            if not _WIN and mode == 0:
                m = RTLD_LOCAL | 2
            elif not _WIN:
                m = mode | 2         # RTLD_NOW
            _ny_sys_audit("ctypes.dlopen", name)   # round 86
            self._handle = _ffi_dlopen(name, m)
        else:
            self._handle = handle

    def __repr__(self):
        return "<" + type(self).__name__ + " '" + str(self._name) + "', handle " + format(self._handle & _M64, "x") + " at " + hex(id(self)) + ">"

    def __getattr__(self, name):
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        var func = self.__getitem__(name)
        object.__setattr__(self, name, func)
        return func

    def __getitem__(self, name_or_ordinal):
        _ny_sys_audit("ctypes.dlsym", self, name_or_ordinal)   # round 86
        if isinstance(name_or_ordinal, int):
            raise AttributeError("function ordinal " + str(name_or_ordinal) + " not found")
        var addr = _ffi_dlsym(self._handle, name_or_ordinal, True)
        var func = self._FuncPtr(addr)
        object.__setattr__(func, "__name__", name_or_ordinal)
        return func

class PyDLL(CDLL):
    _func_flags_ = FUNCFLAG_CDECL | FUNCFLAG_PYTHONAPI

if _WIN:
    class WinDLL(CDLL):
        _func_flags_ = FUNCFLAG_STDCALL

    class HRESULT(_SimpleCData):
        _type_ = "l"

        @classmethod
        def _check_retval_(cls, value):
            if value < 0:
                raise WinError(value)
            return value

    class OleDLL(CDLL):
        _func_flags_ = FUNCFLAG_STDCALL
        _func_restype_ = HRESULT

class LibraryLoader:
    def __init__(self, dlltype):
        self._dlltype = dlltype

    def __getattr__(self, name):
        if name[0] == "_":
            raise AttributeError(name)
        try:
            var dll = self._dlltype(name)
        except OSError:
            raise AttributeError(name)
        object.__setattr__(self, name, dll)
        return dll

    def __getitem__(self, name):
        return getattr(self, name)

    def LoadLibrary(self, name):
        return self._dlltype(name)

cdll = LibraryLoader(CDLL)
pydll = LibraryLoader(PyDLL)
if _WIN:
    windll = LibraryLoader(WinDLL)
    oledll = LibraryLoader(OleDLL)
    pythonapi = PyDLL(None)
else:
    pythonapi = PyDLL(None)


def _ffi_backend_name():
    return _ffi_backend()
