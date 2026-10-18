# nython: module    (import it by name: it runs in a module scope of its own)
# lib/marshal.ny - Python's marshal: CPython's internal value serialization
# (round 83), format version 4 (and 0-3 when asked), written after
# Python/marshal.c.
#
#     import marshal
#     data = marshal.dumps(value[, version])    marshal.loads(data)
#     marshal.dump(value, file[, version])       marshal.load(file)
#     marshal.version == 4
#
# Types: None, True/False, StopIteration, Ellipsis, int (32-bit TYPE_INT,
# else TYPE_LONG in 15-bit digits, any size), float (binary, or text below
# version 2), complex, str (version 4's short-ASCII/ASCII/interned forms,
# TYPE_UNICODE otherwise), bytes and bytearray (TYPE_STRING), tuple (small
# tuples at version 4), list, dict, set, frozenset - nested, with
# references (FLAG_REF / TYPE_REF, version 3+). loads reads everything
# CPython 3.12 writes for these types, versions 0-4, TYPE_INT64 and the
# interned forms included; errors are CPython's ("bad marshal data (unknown
# type code)", EOFError "EOF read where object expected", "unmarshallable
# object").
#
# FLAG_REF, honestly: CPython sets it on an object it writes when that
# object's reference count is above one - which depends on how the value
# was made, not on the value. Here it is set as CPython sets it for a value
# held by a variable and built from literals: the value itself, every int
# in -5..256 (immortal in 3.12), every str, float, complex, other int and
# bytes (constants), and any container that occurs twice in the value;
# equal str/bytes/float/complex/int scalars are written once and referred
# to after (CPython's compiler shares equal constants). So `x = [1, 'a',
# 2.5]; marshal.dumps(x)` is byte for byte CPython's; a value CPython built
# at run time (a float computed into a fresh list) may differ in those flag
# bits only - both read back alike in either.
#
# Not here: code objects (Nython's functions are not CPython bytecode):
# dumps raises ValueError("unmarshallable object") for a function or code
# object, and loads raises ValueError("bad marshal data (code objects are
# not supported here)") for TYPE_CODE. allow_code= (3.13) is accepted.

import struct

__all__ = ["dump", "load", "dumps", "loads", "version"]

version = 4

_NULL = b'0'
_NONE = b'N'
_FALSE = b'F'
_TRUE = b'T'
_STOPITER = b'S'
_ELLIPSIS = b'.'
_INT = 0x69          # 'i'
_INT64 = 0x49        # 'I'
_FLOAT = 0x66        # 'f'
_BINARY_FLOAT = 0x67     # 'g'
_COMPLEX = 0x78      # 'x'
_BINARY_COMPLEX = 0x79   # 'y'
_LONG = 0x6c         # 'l'
_STRING = 0x73       # 's'
_INTERNED = 0x74     # 't'
_REF = 0x72          # 'r'
_TUPLE = 0x28        # '('
_LIST = 0x5b         # '['
_DICT = 0x7b         # '{'
_CODE = 0x63         # 'c'
_UNICODE = 0x75      # 'u'
_UNKNOWN = 0x3f      # '?'
_SET = 0x3c          # '<'
_FROZENSET = 0x3e    # '>'
_ASCII = 0x61        # 'a'
_ASCII_INTERNED = 0x41   # 'A'
_SMALL_TUPLE = 0x29      # ')'
_SHORT_ASCII = 0x7a      # 'z'
_SHORT_ASCII_INTERNED = 0x5a    # 'Z'
_FLAG_REF = 0x80


def _is_ascii(s):
    for ch in s:
        if ord(ch) > 127:
            return False
    return True


def _interned(s):
    # CPython interns the string constants made only of name characters
    for ch in s:
        if not (('a' <= ch <= 'z') or ('A' <= ch <= 'Z') or ('0' <= ch <= '9') or ch == '_'):
            return False
    return True


def _scalar_key(v):
    t = type(v)
    if t is str:
        return ('s', v)
    if t is bytes:
        return ('b', v)
    if t is float:
        return ('f', struct.pack('<d', v))
    if t is complex:
        return ('c', struct.pack('<dd', v.real, v.imag))
    if t is int:
        return ('i', v)
    return None


class _Writer:
    def __init__(self, ver):
        self.version = ver
        self.out = bytearray()
        self.refs = {}         # key -> index
        self.nrefs = 0
        self.counts = {}       # id(container) -> occurrences
        self.depth = 0

    def count(self, v):
        t = type(v)
        if t is list or t is dict or t is set or t is frozenset or t is tuple:
            k = id(v)
            c = self.counts.get(k, 0) + 1
            self.counts[k] = c
            if c > 1:
                return
            if t is dict:
                for kk in v:
                    self.count(kk)
                    self.count(v[kk])
            else:
                for x in v:
                    self.count(x)

    def w_byte(self, b):
        self.out.append(b)

    def w_long(self, x):
        self.out += struct.pack('<i', x)

    def w_size(self, n):
        if n > 0x7fffffff:
            raise ValueError("unmarshallable object")
        self.out += struct.pack('<i', n)

    def w_pstring(self, b):
        self.w_size(len(b))
        self.out += b

    def w_short_pstring(self, b):
        self.out.append(len(b))
        self.out += b

    def ref_key(self, v):
        k = _scalar_key(v)
        if k is not None:
            return k
        return ('o', id(v))

    def w_ref(self, v, code, top):
        # True when a reference was written; else the type code, flagged
        if self.version < 3:
            self.w_byte(code)
            return False
        key = self.ref_key(v)
        if key in self.refs:
            self.w_byte(_REF)
            self.w_long(self.refs[key])
            return True
        flag = top or key[0] != 'o' or self.counts.get(id(v), 0) > 1
        if flag:
            self.refs[key] = self.nrefs
            self.nrefs += 1
            self.w_byte(code | _FLAG_REF)
        else:
            self.w_byte(code)
        return False

    def w_object(self, v, top=False):
        self.depth += 1
        if self.depth > 2000:
            raise ValueError("object too deeply nested to marshal")
        try:
            self._w(v, top)
        finally:
            self.depth -= 1

    def _w(self, v, top):
        if v is None:
            self.out += _NONE
            return
        if v is StopIteration:
            self.out += _STOPITER
            return
        if v is Ellipsis:
            self.out += _ELLIPSIS
            return
        if v is False:
            self.out += _FALSE
            return
        if v is True:
            self.out += _TRUE
            return
        t = type(v)
        if t is int:
            if -0x80000000 <= v <= 0x7fffffff:
                if self.w_ref(v, _INT, top):
                    return
                self.w_long(v)
                return
            if self.w_ref(v, _LONG, top):
                return
            a = -v if v < 0 else v
            digits = []
            while a:
                digits.append(a & 0x7fff)
                a >>= 15
            n = len(digits)
            self.w_long(-n if v < 0 else n)
            for d in digits:
                self.out += struct.pack('<H', d)
            return
        if t is float:
            if self.version > 1:
                if self.w_ref(v, _BINARY_FLOAT, top):
                    return
                self.out += struct.pack('<d', v)
            else:
                if self.w_ref(v, _FLOAT, top):
                    return
                self.w_short_pstring(_float_text(v))
            return
        if t is complex:
            if self.version > 1:
                if self.w_ref(v, _BINARY_COMPLEX, top):
                    return
                self.out += struct.pack('<dd', v.real, v.imag)
            else:
                if self.w_ref(v, _COMPLEX, top):
                    return
                self.w_short_pstring(_float_text(v.real))
                self.w_short_pstring(_float_text(v.imag))
            return
        if t is str:
            if self.version >= 4 and _is_ascii(v):
                interned = _interned(v)
                b = v.encode('ascii')
                if len(b) < 256:
                    if self.w_ref(v, _SHORT_ASCII_INTERNED if interned else _SHORT_ASCII, top):
                        return
                    self.w_short_pstring(b)
                else:
                    if self.w_ref(v, _ASCII_INTERNED if interned else _ASCII, top):
                        return
                    self.w_pstring(b)
                return
            # (TYPE_INTERNED from version 3, as CPython's w_object)
            code = _INTERNED if (self.version >= 3 and _interned(v)) else _UNICODE
            if self.w_ref(v, code, top):
                return
            self.w_pstring(v.encode('utf-8', 'surrogatepass'))
            return
        if t is bytes or t is bytearray:
            # a bytearray is an object of its own (flagged when shared or
            # written at the top, as any object CPython holds twice)
            if self.w_ref(v, _STRING, top):
                return
            self.w_pstring(bytes(v))
            return
        if t is tuple:
            if self.version >= 4 and len(v) < 256:
                if self.w_ref(v, _SMALL_TUPLE, top):
                    return
                self.w_byte(len(v))
            else:
                if self.w_ref(v, _TUPLE, top):
                    return
                self.w_size(len(v))
            for x in v:
                self.w_object(x)
            return
        if t is list:
            if self.w_ref(v, _LIST, top):
                return
            self.w_size(len(v))
            for x in v:
                self.w_object(x)
            return
        if t is dict:
            if self.w_ref(v, _DICT, top):
                return
            for k in v:
                self.w_object(k)
                self.w_object(v[k])
            self.out += _NULL
            return
        if t is set or t is frozenset:
            if self.w_ref(v, _SET if t is set else _FROZENSET, top):
                return
            self.w_size(len(v))
            for x in v:
                self.w_object(x)
            return
        raise ValueError("unmarshallable object")


def _float_text(x):
    # PyOS_double_to_string(x, 'g', 17, 0)
    if x != x:
        return b'nan'
    if x == float('inf'):
        return b'inf'
    if x == float('-inf'):
        return b'-inf'
    return ('%.17g' % x).encode('ascii')


def dumps(value, version=version, /):
    """Return the bytes object that would be written to a file by dump(value, file)."""
    w = _Writer(version)
    w.count(value)
    w.w_object(value, True)
    return bytes(w.out)


def dump(value, file, version=version, /):
    """Write the value on the open file."""
    file.write(dumps(value, version))


class _Reader:
    def __init__(self, data, allow_code):
        self.data = data
        self.pos = 0
        self.refs = []
        self.allow_code = allow_code
        self.depth = 0

    def r_bytes(self, n):
        if self.pos + n > len(self.data):
            raise EOFError("marshal data too short")
        b = self.data[self.pos:self.pos + n]
        self.pos += n
        return bytes(b)

    def r_byte(self):
        if self.pos >= len(self.data):
            raise EOFError("EOF read where object expected")
        b = self.data[self.pos]
        self.pos += 1
        return b

    def r_long(self):
        return struct.unpack('<i', self.r_bytes(4))[0]

    def r_size(self):
        n = self.r_long()
        if n < 0:
            raise ValueError("bad marshal data (bytes object size out of range)")
        return n

    def r_float_str(self):
        n = self.r_byte()
        return float(self.r_bytes(n).decode('ascii'))

    def r_object(self):
        self.depth += 1
        if self.depth > 2000:
            raise ValueError("recursion limit exceeded")
        try:
            return self._r()
        finally:
            self.depth -= 1

    def _r(self):
        code = self.r_byte()
        flag = code & _FLAG_REF
        t = code & ~_FLAG_REF

        def keep(v):
            if flag:
                self.refs.append(v)
            return v

        if t == 0x30:          # TYPE_NULL
            return _NullMark
        if t == 0x4e:
            return None
        if t == 0x46:
            return False
        if t == 0x54:
            return True
        if t == 0x53:
            return StopIteration
        if t == 0x2e:
            return Ellipsis
        if t == _INT:
            return keep(self.r_long())
        if t == _INT64:
            lo = struct.unpack('<q', self.r_bytes(8))[0]
            return keep(lo)
        if t == _LONG:
            n = self.r_long()
            neg = n < 0
            if neg:
                n = -n
            v = 0
            shift = 0
            for i in range(n):
                d = struct.unpack('<H', self.r_bytes(2))[0]
                if d > 0x7fff:
                    raise ValueError("bad marshal data (digit out of range in long)")
                v |= d << shift
                shift += 15
            return keep(-v if neg else v)
        if t == _FLOAT:
            return keep(self.r_float_str())
        if t == _BINARY_FLOAT:
            return keep(struct.unpack('<d', self.r_bytes(8))[0])
        if t == _COMPLEX:
            re_ = self.r_float_str()
            im = self.r_float_str()
            return keep(complex(re_, im))
        if t == _BINARY_COMPLEX:
            re_, im = struct.unpack('<dd', self.r_bytes(16))
            return keep(complex(re_, im))
        if t == _STRING:
            return keep(self.r_bytes(self.r_size()))
        if t == _UNICODE or t == _INTERNED:
            return keep(self.r_bytes(self.r_size()).decode('utf-8', 'surrogatepass'))
        if t == _ASCII or t == _ASCII_INTERNED:
            return keep(self.r_bytes(self.r_size()).decode('latin-1'))
        if t == _SHORT_ASCII or t == _SHORT_ASCII_INTERNED:
            return keep(self.r_bytes(self.r_byte()).decode('latin-1'))
        if t == _TUPLE or t == _SMALL_TUPLE:
            n = self.r_byte() if t == _SMALL_TUPLE else self.r_size()
            idx = len(self.refs)
            if flag:
                self.refs.append(None)
            items = []
            for i in range(n):
                items.append(self._item("tuple"))
            v = tuple(items)
            if flag:
                self.refs[idx] = v
            return v
        if t == _LIST:
            n = self.r_size()
            v = []
            keep(v)
            for i in range(n):
                v.append(self._item("list"))
            return v
        if t == _DICT:
            v = {}
            keep(v)
            while True:
                k = self.r_object()
                if k is _NullMark:
                    break
                val = self.r_object()
                if val is _NullMark:
                    break
                v[k] = val
            return v
        if t == _SET or t == _FROZENSET:
            n = self.r_size()
            idx = len(self.refs)
            if flag:
                self.refs.append(None)
            items = []
            for i in range(n):
                items.append(self._item("set"))
            v = set(items) if t == _SET else frozenset(items)
            if flag:
                self.refs[idx] = v
            return v
        if t == _REF:
            n = self.r_long()
            if n < 0 or n >= len(self.refs):
                raise ValueError("bad marshal data (invalid reference)")
            v = self.refs[n]
            if v is None:
                raise ValueError("bad marshal data (invalid reference)")
            return v
        if t == _CODE:
            raise ValueError("bad marshal data (code objects are not supported here)")
        raise ValueError("bad marshal data (unknown type code)")

    def _item(self, what):
        v = self.r_object()
        if v is _NullMark:
            raise TypeError("NULL object in marshal data for " + what)
        return v


class _NullMarkType:
    pass


_NullMark = _NullMarkType()


def loads(data, /, *, allow_code=True):
    """Convert the bytes-like object to a value."""
    if isinstance(data, str):
        raise TypeError("a bytes-like object is required, not 'str'")
    r = _Reader(bytes(data), allow_code)
    v = r.r_object()
    if v is _NullMark:
        raise TypeError("NULL object in marshal data for object")
    return v


def load(file, /, *, allow_code=True):
    """Read one value from the open file and return it."""
    data = file.read()
    r = _Reader(bytes(data), allow_code)
    v = r.r_object()
    if v is _NullMark:
        raise TypeError("NULL object in marshal data for object")
    rest = len(data) - r.pos
    if rest > 0 and hasattr(file, "seek"):
        try:
            file.seek(-rest, 1)
        except Exception:
            pass
    return v
