# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/pickle.ny - Python's pickle (round 79): object serialization, every
# protocol (0-5), written after CPython's C pickler (Modules/_pickle.c) so
# that the bytes come out the same.
#
#     import pickle
#     data = pickle.dumps(obj, protocol=4)       obj2 = pickle.loads(data)
#     with open("f.pkl", "wb") as f: pickle.dump(obj, f)
#
# For None, bools, ints of any size, floats, str, bytes, bytearray, tuples,
# lists, dicts, sets and frozensets - nested and shared - dumps(x, p) is
# byte for byte CPython's for every protocol p (frames, memo, batching of
# 1000 items, the Python 2 compatible forms of protocols 0-2: bytes through
# _codecs.encode, sets through __builtin__.set, ...); loads reads every
# opcode of protocols 0-5, Python 2's str opcodes too (encoding=, errors=,
# "bytes"). Classes and functions are pickled by reference (__module__ and
# __qualname__; __main__ is the running program), instances through
# object.__reduce_ex__ (copyreg: __newobj__/__newobj_ex__ at protocol 2+,
# _reconstructor below it, __getnewargs__ / __getnewargs_ex__, __getstate__
# / __setstate__, slot state as a (dict, slots) pair, list and dict
# subclasses' items), __reduce__ / __reduce_ex__ of your own (2 to 6 items,
# a state setter included), copyreg.dispatch_table and Pickler.dispatch_table,
# reducer_override, persistent_id / persistent_load, find_class, the
# extension registry (EXT1/2/4), recursive structures, protocol 5's
# PickleBuffer with buffer_callback / buffers (out-of-band data).
# PickleError, PicklingError and UnpicklingError carry CPython's messages.
#
# Differences, honestly: CPython memoizes by object identity; here strings
# and bytes are memoized by value (CPython's compiler and interning make
# equal constants one object, so the usual cases - repeated literal keys,
# names - come out the same; two equal strings built at run time are one
# memo entry here, two in CPython - still a correct pickle). Two equal
# constant tuples written twice in one CPython expression are one object
# there and two here. A set's elements are written in its iteration order,
# which for Nython's sets is insertion order (CPython's follows the hash
# table). PickleBuffer wraps any buffer (round 84) and raw() is a flat
# memoryview of it, as CPython's. Pickling a lambda or local class fails as in Python
# only when the lookup by name does not find it. No pickletools.

import io
import struct
import copyreg

__all__ = ["PickleError", "PicklingError", "UnpicklingError", "Pickler", "Unpickler", "dump", "dumps",
           "load", "loads", "PickleBuffer", "HIGHEST_PROTOCOL", "DEFAULT_PROTOCOL"]

HIGHEST_PROTOCOL = 5
DEFAULT_PROTOCOL = 4
format_version = "4.0"
compatible_formats = ["1.0", "1.1", "1.2", "1.3", "2.0", "3.0", "4.0", "5.0"]


class PickleError(Exception):
    pass


class PicklingError(PickleError):
    pass


class UnpicklingError(PickleError):
    pass


class _Stop(Exception):
    def __init__(self, value):
        self.value = value


# ── opcodes ─────────────────────────────────────────────────────────────────
MARK = b"("
STOP = b"."
POP = b"0"
POP_MARK = b"1"
DUP = b"2"
FLOAT = b"F"
INT = b"I"
BININT = b"J"
BININT1 = b"K"
LONG = b"L"
BININT2 = b"M"
NONE = b"N"
PERSID = b"P"
BINPERSID = b"Q"
REDUCE = b"R"
STRING = b"S"
BINSTRING = b"T"
SHORT_BINSTRING = b"U"
UNICODE = b"V"
BINUNICODE = b"X"
APPEND = b"a"
BUILD = b"b"
GLOBAL = b"c"
DICT = b"d"
EMPTY_DICT = b"}"
APPENDS = b"e"
GET = b"g"
BINGET = b"h"
INST = b"i"
LONG_BINGET = b"j"
LIST = b"l"
EMPTY_LIST = b"]"
OBJ = b"o"
PUT = b"p"
BINPUT = b"q"
LONG_BINPUT = b"r"
SETITEM = b"s"
TUPLE = b"t"
EMPTY_TUPLE = b")"
SETITEMS = b"u"
BINFLOAT = b"G"
TRUE = b"I01\n"
FALSE = b"I00\n"
PROTO = b"\x80"
NEWOBJ = b"\x81"
EXT1 = b"\x82"
EXT2 = b"\x83"
EXT4 = b"\x84"
TUPLE1 = b"\x85"
TUPLE2 = b"\x86"
TUPLE3 = b"\x87"
NEWTRUE = b"\x88"
NEWFALSE = b"\x89"
LONG1 = b"\x8a"
LONG4 = b"\x8b"
BINBYTES = b"B"
SHORT_BINBYTES = b"C"
SHORT_BINUNICODE = b"\x8c"
BINUNICODE8 = b"\x8d"
BINBYTES8 = b"\x8e"
EMPTY_SET = b"\x8f"
ADDITEMS = b"\x90"
FROZENSET = b"\x91"
NEWOBJ_EX = b"\x92"
STACK_GLOBAL = b"\x93"
MEMOIZE = b"\x94"
FRAME = b"\x95"
BYTEARRAY8 = b"\x96"
NEXT_BUFFER = b"\x97"
READONLY_BUFFER = b"\x98"

_BATCHSIZE = 1000
_FRAME_SIZE_MIN = 4
_FRAME_SIZE_TARGET = 64 * 1024
_FRAME_HEADER_SIZE = 9

# _compat_pickle's mappings that a protocol 0-2 pickle of builtin values,
# classes and copyreg's helpers meets (Python 3 name -> Python 2 name)
_REVERSE_IMPORT_MAPPING = {"builtins": "__builtin__", "copyreg": "copy_reg", "queue": "Queue",
                           "socketserver": "SocketServer", "configparser": "ConfigParser", "reprlib": "repr",
                           "_thread": "thread", "subprocess": "commands", "urllib.parse": "urlparse",
                           "urllib.request": "urllib2", "http.client": "httplib", "collections.abc": "_abcoll",
                           "_functools": "functools", "_pickle": "pickle", "html.parser": "HTMLParser",
                           "http.cookies": "Cookie", "http.cookiejar": "cookielib", "http.server": "BaseHTTPServer"}
_REVERSE_NAME_MAPPING = {("builtins", "range"): ("__builtin__", "xrange"),
                         ("functools", "reduce"): ("__builtin__", "reduce"),
                         ("builtins", "chr"): ("__builtin__", "unichr"),
                         ("builtins", "str"): ("__builtin__", "unicode"),
                         ("builtins", "int"): ("__builtin__", "long"),
                         ("builtins", "zip"): ("itertools", "izip"),
                         ("builtins", "map"): ("itertools", "imap"),
                         ("builtins", "filter"): ("itertools", "ifilter"),
                         ("_functools", "reduce"): ("__builtin__", "reduce")}
_PY2_EXCEPTIONS = ["ArithmeticError", "AssertionError", "AttributeError", "BaseException", "BufferError",
                   "BytesWarning", "DeprecationWarning", "EOFError", "EnvironmentError", "Exception",
                   "FloatingPointError", "FutureWarning", "GeneratorExit", "IOError", "ImportError",
                   "ImportWarning", "IndentationError", "IndexError", "KeyError", "KeyboardInterrupt",
                   "LookupError", "MemoryError", "NameError", "NotImplementedError", "OSError",
                   "OverflowError", "PendingDeprecationWarning", "ReferenceError", "RuntimeError",
                   "RuntimeWarning", "StopIteration", "SyntaxError", "SyntaxWarning", "SystemError",
                   "SystemExit", "TabError", "TypeError", "UnboundLocalError", "UnicodeDecodeError",
                   "UnicodeEncodeError", "UnicodeError", "UnicodeTranslateError", "UnicodeWarning",
                   "UserWarning", "ValueError", "Warning", "ZeroDivisionError"]
for _e in _PY2_EXCEPTIONS:
    _REVERSE_NAME_MAPPING[("builtins", _e)] = ("exceptions", _e)
for _e in ["BrokenPipeError", "ChildProcessError", "ConnectionAbortedError", "ConnectionError",
           "ConnectionRefusedError", "ConnectionResetError", "FileExistsError", "FileNotFoundError",
           "InterruptedError", "IsADirectoryError", "NotADirectoryError", "PermissionError",
           "ProcessLookupError", "TimeoutError"]:
    _REVERSE_NAME_MAPPING[("builtins", _e)] = ("exceptions", "OSError")
_REVERSE_NAME_MAPPING[("builtins", "ModuleNotFoundError")] = ("exceptions", "ImportError")

# ... and back (Python 2 name -> Python 3 name), for loading
_IMPORT_MAPPING = {"__builtin__": "builtins", "copy_reg": "copyreg", "Queue": "queue", "cPickle": "pickle",
                   "UserDict": "collections", "UserList": "collections", "UserString": "collections",
                   "SocketServer": "socketserver", "ConfigParser": "configparser", "repr": "reprlib",
                   "thread": "_thread", "commands": "subprocess", "urlparse": "urllib.parse",
                   "urllib2": "urllib.request", "httplib": "http.client", "_abcoll": "collections.abc",
                   "exceptions": "builtins", "StringIO": "io", "cStringIO": "io"}
_NAME_MAPPING = {("__builtin__", "xrange"): ("builtins", "range"),
                 ("__builtin__", "reduce"): ("functools", "reduce"),
                 ("__builtin__", "intern"): ("sys", "intern"),
                 ("__builtin__", "unichr"): ("builtins", "chr"),
                 ("__builtin__", "unicode"): ("builtins", "str"),
                 ("__builtin__", "long"): ("builtins", "int"),
                 ("__builtin__", "basestring"): ("builtins", "str"),
                 ("itertools", "izip"): ("builtins", "zip"),
                 ("itertools", "imap"): ("builtins", "map"),
                 ("itertools", "ifilter"): ("builtins", "filter"),
                 ("itertools", "ifilterfalse"): ("itertools", "filterfalse"),
                 ("itertools", "izip_longest"): ("itertools", "zip_longest"),
                 ("exceptions", "StandardError"): ("builtins", "Exception"),
                 ("UserDict", "IterableUserDict"): ("collections", "UserDict"),
                 ("UserDict", "UserDict"): ("collections", "UserDict"),
                 ("UserList", "UserList"): ("collections", "UserList"),
                 ("UserString", "UserString"): ("collections", "UserString")}


def _hex_lower(n, width):
    var h = "0123456789abcdef"
    var s = ""
    var i = 0
    while i < width:
        s = h[n & 15] + s
        n = n >> 4
        i = i + 1
    return s


def _raw_unicode_escape(s):
    var out = bytearray()
    for ch in s:
        var c = ord(ch)
        if c >= 0x10000:
            out.extend(("\\U" + _hex_lower(c, 8)).encode("ascii"))
        elif c >= 256 or c == 92 or c == 0 or c == 10 or c == 13 or c == 26:
            out.extend(("\\u" + _hex_lower(c, 4)).encode("ascii"))
        else:
            out.append(c)
    return bytes(out)


def _raw_unicode_unescape(b):
    var out = []
    var i = 0
    var n = len(b)
    var run = bytearray()
    while i < n:
        var c = b[i]
        if c == 92 and i + 1 < n and (b[i + 1] == 117 or b[i + 1] == 85):
            # an odd number of backslashes before u/U starts an escape
            var k = i
            while k > 0 and b[k - 1] == 92:
                k = k - 1
            if (i - k) % 2 == 0:
                var width = 4 if b[i + 1] == 117 else 8
                if i + 2 + width > n:
                    raise UnicodeDecodeError("rawunicodeescape", bytes(b), i, n, "truncated \\uXXXX escape")
                out.append(bytes(run).decode("latin-1"))
                run = bytearray()
                out.append(chr(int(bytes(b[i + 2:i + 2 + width]).decode("ascii"), 16)))
                i = i + 2 + width
                continue
        run.append(c)
        i = i + 1
    out.append(bytes(run).decode("latin-1"))
    return "".join(out)


def _escape_decode(b):
    # Python 2 str's repr body (codecs.escape_decode)
    var out = bytearray()
    var i = 0
    var n = len(b)
    while i < n:
        var c = b[i]
        if c != 92 or i + 1 >= n:
            out.append(c)
            i = i + 1
            continue
        var d = b[i + 1]
        i = i + 2
        if d == 110:
            out.append(10)
        elif d == 116:
            out.append(9)
        elif d == 114:
            out.append(13)
        elif d == 92:
            out.append(92)
        elif d == 39:
            out.append(39)
        elif d == 34:
            out.append(34)
        elif d == 97:
            out.append(7)
        elif d == 98:
            out.append(8)
        elif d == 102:
            out.append(12)
        elif d == 118:
            out.append(11)
        elif d == 10:
            pass
        elif d == 120 and i + 2 <= n:
            out.append(int(bytes(b[i:i + 2]).decode("ascii"), 16))
            i = i + 2
        elif 48 <= d <= 55:
            var v = d - 48
            var k = 0
            while k < 2 and i < n and 48 <= b[i] <= 55:
                v = v * 8 + (b[i] - 48)
                i = i + 1
                k = k + 1
            out.append(v & 255)
        else:
            out.append(92)
            out.append(d)
    return bytes(out)


def _u32le(n):
    return bytes([n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255])


def _u64le(n):
    var b = bytearray()
    for i in range(8):
        b.append((n >> (8 * i)) & 255)
    return bytes(b)


def _le_int(b):
    var v = 0
    var i = len(b) - 1
    while i >= 0:
        v = (v << 8) | b[i]
        i = i - 1
    return v


def _encode_long(x):
    # LONG1/LONG4's body: two's complement, little-endian, as few bytes as
    # possible (CPython's save_long)
    if x == 0:
        return b""
    var nbytes = (x.bit_length() >> 3) + 1
    var result = x.to_bytes(nbytes, "little", signed=True)
    if x < 0 and nbytes > 1:
        if result[-1] == 0xff and (result[-2] & 0x80) != 0:
            result = result[:-1]
    return result


def _decode_long(data):
    return int.from_bytes(data, "little", signed=True)


class PickleBuffer:
    """Wrapper for potentially out-of-band buffers"""

    def __init__(self, buffer):
        # (round 84) any buffer, held as a view of it, as CPython's
        self._view = _ny_mv_export(buffer, "")
        self._obj = buffer

    def _ny_live(self):
        if self._view is None:
            raise ValueError("operation forbidden on released PickleBuffer object")
        return self._view

    def raw(self):
        """Return a memoryview of the raw memory underlying this buffer."""
        var v = self._ny_live()
        if not v.contiguous:
            raise BufferError("cannot extract raw buffer from non-contiguous buffer")
        return _ny_mv_make(v._ny_mb, v._ny_a, "B", 1, (v.nbytes,), (1,), v.readonly)

    def release(self):
        """Release the underlying buffer exposed by the PickleBuffer object."""
        if self._view is not None:
            self._view.release()
            self._view = None

    def __buffer__(self, flags):
        var v = self._ny_live()
        return _ny_mv_copy(v, v.readonly)

    def __release_buffer__(self, view):
        view.release()

    @property
    def readonly(self):
        return self._ny_live().readonly


# ── where globals come from ─────────────────────────────────────────────────
_main_override = []


def _ny_set_main(ns):
    # a spawned multiprocessing child runs its parent's main program as
    # __mp_main__ in the namespace ns: "__main__" and "__mp_main__" are
    # looked up there (round 80; CPython aliases sys.modules["__main__"])
    del _main_override[:]
    _main_override.append(ns)


def _main_globals():
    # the running program's globals (sys.modules["__main__"] in CPython)
    if _main_override:
        return _main_override[0]
    return _ny_main_globals()


# the builtins every program starts with (the prelude's private names left out)
def _builtins_dict():
    import sys
    return sys._getframe(0).f_builtins


_BUILTINS = _builtins_dict()


def _builtin(name):
    if not isinstance(name, str) or name not in _BUILTINS:
        raise AttributeError(name)
    return _BUILTINS[name]


class _ModuleView:
    """A namespace dict seen as a module (the running program's globals)."""

    def __init__(self, name, ns):
        self.__name__ = name
        self._ns = ns

    def get(self, attr):
        if attr in self._ns:
            return self._ns[attr]
        raise AttributeError(attr)


_module_cache = {}


def _import(module):
    if module == "builtins":
        return "builtins"
    if module == "__main__" or module == "__mp_main__":
        return _ModuleView("__main__", _main_globals())
    if module == "copyreg":
        return copyreg
    if module == "_codecs" or module == "codecs":
        return "_codecs"
    if module == "posix" or module == "nt" or module == "os":
        # CPython's os functions are posix's / nt's (round 80); imported
        # here, as the VM's exec("import os", ns) binds no name in ns
        import os
        return os
    var m = _module_cache.get(module)
    if m is not None:
        return m
    var ns = {}
    exec("import " + module + " as _ny_mod", ns)
    m = ns["_ny_mod"]
    _module_cache[module] = m
    return m


def _codecs_encode(obj, encoding="utf-8", errors="strict"):
    return obj.encode(encoding, errors)


def _attr_of(mod, name):
    if mod == "builtins":
        return _builtin(name)
    if mod == "_codecs":
        if name == "encode":
            return _codecs_encode
        raise AttributeError(name)
    if isinstance(mod, _ModuleView):
        return mod.get(name)
    return getattr(mod, name)


def _getattribute(mod, name):
    var parent = None
    var obj = mod
    var first = True
    for subpath in name.split("."):
        if subpath == "<locals>":
            raise AttributeError("Can't get local attribute " + repr(name) + " on " + repr(mod))
        parent = obj
        if first:
            obj = _attr_of(mod, subpath)
            first = False
        else:
            obj = getattr(obj, subpath)
    return obj, parent


_BUILTIN_TYPE_NAMES = {"int": int, "float": float, "str": str, "bytes": bytes, "bytearray": bytearray,
                       "list": list, "dict": dict, "tuple": tuple, "set": set, "frozenset": frozenset,
                       "bool": bool, "complex": complex, "object": object, "type": type, "range": range,
                       "slice": slice, "getattr": getattr}


def _whichmodule(obj, name):
    var m = getattr(obj, "__module__", None)
    if m is not None:
        return m
    return "__main__"


def _os_function_name(obj):
    # The name os gives a builtin function (os.getpid is the builtin
    # os_getpid): CPython pickles it as posix.getpid / nt.getpid (round 80)
    import os
    for k in dir(os):
        if k.startswith("_") or k == "path":
            continue
        if getattr(os, k, None) is obj:
            return k
    return None


def _global_name(obj):
    # (module, qualified name) of a class or function, builtins included
    if obj is _codecs_encode:
        return "_codecs", "encode"
    for k in _BUILTIN_TYPE_NAMES:
        if _BUILTIN_TYPE_NAMES[k] is obj:
            return "builtins", k
    var name = getattr(obj, "__qualname__", None)
    if name is None:
        name = getattr(obj, "__name__", None)
    if name is None:
        raise PicklingError("Can't pickle " + repr(obj) + ": it has no __name__")
    var module = _whichmodule(obj, name)
    if module == "builtins" or module == "__builtin__":
        module = "builtins"
        if type(obj).__name__ == "builtin_function_or_method" and (name.startswith("os_") or name not in _BUILTINS):
            var osname = _os_function_name(obj)
            if osname is not None:
                import os
                return ("nt" if os.name == "nt" else "posix"), osname
    elif module == "__mp_main__":
        # what a spawned child's main program defines is __main__'s too
        module = "__main__"
    if module == "__main__" and "." not in name:
        # the builtin exception classes and functions say __main__ here
        try:
            if _builtin(name) is obj:
                module = "builtins"
        except Exception:
            pass
    return module, name


def _is_type_object(x):
    return isinstance(x, type)


def _is_function(x):
    var tn = type(x).__name__
    return tn == "function" or tn == "builtin_function_or_method"


# ── Pickler ─────────────────────────────────────────────────────────────────
class Pickler:
    """Writes the pickle of an object to a binary file (CPython's _pickle)."""

    def __init__(self, file, protocol=None, fix_imports=True, buffer_callback=None):
        if protocol is None:
            protocol = DEFAULT_PROTOCOL
        if protocol < 0:
            protocol = HIGHEST_PROTOCOL
        elif not 0 <= protocol <= HIGHEST_PROTOCOL:
            raise ValueError("pickle protocol must be <= " + str(HIGHEST_PROTOCOL))
        if buffer_callback is not None and protocol < 5:
            raise ValueError("buffer_callback needs protocol >= 5")
        try:
            self._file_write = file.write
        except AttributeError:
            raise TypeError("file must have a 'write' attribute") from None
        self.proto = int(protocol)
        self.bin = protocol >= 1
        self.fast = 0
        self.fix_imports = fix_imports and protocol < 3
        self._buffer_callback = buffer_callback
        self.memo = {}
        self._fresh = 0
        self._out = bytearray()
        self._frame_start = -1
        self._framing = False

    def clear_memo(self):
        self.memo.clear()

    # ── output, framed at protocol 4+ (CPython's _Pickler_Write) ───────────
    def _write(self, data):
        if self._framing and self._frame_start == -1:
            self._frame_start = len(self._out)
            self._out.extend(b"\xfe" * _FRAME_HEADER_SIZE)
        self._out.extend(data)

    def _commit_frame(self):
        if not self._framing or self._frame_start == -1:
            return
        var fs = self._frame_start
        var flen = len(self._out) - fs - _FRAME_HEADER_SIZE
        if flen >= _FRAME_SIZE_MIN:
            self._out[fs:fs + _FRAME_HEADER_SIZE] = FRAME + _u64le(flen)
        else:
            del self._out[fs:fs + _FRAME_HEADER_SIZE]
        self._frame_start = -1

    def _boundary(self):
        if not self._framing or self._frame_start == -1:
            return
        if len(self._out) - self._frame_start - _FRAME_HEADER_SIZE >= _FRAME_SIZE_TARGET:
            self._commit_frame()

    def _write_bytes(self, header, data):
        # large payloads go outside frames
        var bypass = len(data) >= _FRAME_SIZE_TARGET
        var framing = self._framing
        if bypass:
            self._commit_frame()
            self._framing = False
        self._write(header)
        self._write(data)
        self._framing = framing

    def dump(self, obj):
        if not hasattr(self, "_file_write"):
            raise PicklingError("Pickler.__init__() was not called by " + type(self).__name__ + ".__init__()")
        self._out = bytearray()
        self._frame_start = -1
        self._framing = False
        self._pers_func = getattr(self, "persistent_id", None)
        self._reducer_override = getattr(self, "reducer_override", None)
        if self.proto >= 2:
            self._write(PROTO + bytes([self.proto]))
            if self.proto >= 4:
                self._framing = True
        self.save(obj)
        self._write(STOP)
        self._commit_frame()
        self._file_write(bytes(self._out))
        self._out = bytearray()

    # ── the memo ───────────────────────────────────────────────────────────
    def _memo_key(self, obj):
        var t = type(obj)
        if t is str:
            return ("s", obj)
        if t is bytes:
            return ("b", obj)
        return id(obj)

    def _memoize(self, obj, key=None):
        if self.fast:
            return
        var idx = len(self.memo)
        self.memo[self._memo_key(obj) if key is None else key] = (idx, obj)
        if self.proto >= 4:
            self._write(MEMOIZE)
        elif not self.bin:
            self._write(PUT + str(idx).encode("ascii") + b"\n")
        elif idx < 256:
            self._write(BINPUT + bytes([idx]))
        else:
            self._write(LONG_BINPUT + _u32le(idx))

    def _get(self, idx):
        if not self.bin:
            self._write(GET + str(idx).encode("ascii") + b"\n")
        elif idx < 256:
            self._write(BINGET + bytes([idx]))
        else:
            self._write(LONG_BINGET + _u32le(idx))

    def _in_memo(self, obj):
        return self._memo_key(obj) in self.memo

    def _memo_get(self, obj):
        self._get(self.memo[self._memo_key(obj)][0])

    # ── save ───────────────────────────────────────────────────────────────
    def save(self, obj, save_persistent_id=True):
        self._boundary()
        if save_persistent_id and self._pers_func is not None:
            var pid = self._pers_func(obj)
            if pid is not None:
                self._save_pers(pid)
                return
        if obj is None:
            self._write(NONE)
            return
        var t = type(obj)
        if t is bool:
            if self.proto >= 2:
                self._write(NEWTRUE if obj else NEWFALSE)
            else:
                self._write(TRUE if obj else FALSE)
            return
        if t is int:
            self._save_long(obj)
            return
        if t is float:
            self._save_float(obj)
            return
        var key = self._memo_key(obj)
        if key in self.memo:
            self._get(self.memo[key][0])
            return
        if t is bytes:
            self._save_bytes(obj)
            return
        if t is str:
            self._save_str(obj)
            return
        if t is dict or t is _NyInstanceDict or t is _NyGlobalsDict:
            # (round 87: an instance's live __dict__ - and globals() - pickle
            # as the dict they stand for, as CPython's real dicts do;
            # lib2to3's grammar pickles its own __dict__)
            self._save_dict(obj)
            return
        if t is set:
            self._save_set(obj)
            return
        if t is frozenset:
            self._save_frozenset(obj)
            return
        if t is list:
            self._save_list(obj)
            return
        if t is tuple:
            self._save_tuple(obj)
            return
        if t is bytearray:
            self._save_bytearray(obj)
            return
        if t is PickleBuffer:
            self._save_picklebuffer(obj)
            return
        var rv = NotImplemented
        if self._reducer_override is not None:
            rv = self._reducer_override(obj)
        if rv is NotImplemented:
            if _is_type_object(obj):
                self._save_type(obj)
                return
            if _is_function(obj):
                self.save_global(obj)
                return
            var reduce = None
            var dt = getattr(self, "dispatch_table", copyreg.dispatch_table)
            try:
                reduce = dt.get(t)
            except TypeError:
                reduce = None
            if reduce is not None:
                rv = reduce(obj)
            else:
                # a class's own __reduce_ex__, else its own __reduce__,
                # else object.__reduce_ex__ (copyreg)
                var found = False
                for c in t.__mro__:
                    if c is object:
                        break
                    if "__reduce_ex__" in copyreg._cdict(c):
                        rv = obj.__reduce_ex__(self.proto)
                        found = True
                        break
                    if "__reduce__" in copyreg._cdict(c):
                        rv = obj.__reduce__()
                        found = True
                        break
                if not found:
                    rv = copyreg._ny_reduce_ex(obj, self.proto)
        if isinstance(rv, str):
            self.save_global(obj, rv)
            return
        if not isinstance(rv, tuple):
            raise PicklingError("__reduce__ must return a string or tuple")
        self._save_reduce(rv, obj)

    def _save_pers(self, pid):
        if self.bin:
            self.save(pid, False)
            self._write(BINPERSID)
        else:
            var s = str(pid)
            for ch in s:
                if ord(ch) > 127:
                    raise PicklingError("persistent IDs in protocol 0 must be ASCII strings")
            self._write(PERSID + s.encode("ascii") + b"\n")

    def _save_long(self, obj):
        if -0x80000000 <= obj <= 0x7fffffff:
            if self.bin:
                if obj < 0 or obj > 0xffff:
                    self._write(BININT + (obj & 0xffffffff).to_bytes(4, "little"))
                elif obj > 0xff:
                    self._write(BININT2 + obj.to_bytes(2, "little"))
                else:
                    self._write(BININT1 + bytes([obj]))
            else:
                self._write(INT + str(obj).encode("ascii") + b"\n")
            return
        if self.proto >= 2:
            var enc = _encode_long(obj)
            var n = len(enc)
            if n < 256:
                self._write(LONG1 + bytes([n]) + enc)
            else:
                self._write(LONG4 + _u32le(n) + enc)
            return
        self._write(LONG + repr(obj).encode("ascii") + b"L\n")

    def _save_float(self, obj):
        if self.bin:
            self._write(BINFLOAT + struct.pack(">d", obj))
        else:
            self._write(FLOAT + repr(obj).encode("ascii") + b"\n")

    def _save_bytes(self, obj):
        if self.proto < 3:
            if len(obj) == 0:
                self._save_reduce((bytes, ()), obj)
            else:
                self._save_reduce((_codecs_encode, (obj.decode("latin-1"), "latin1")), obj)
            return
        self._save_bytes_data(obj, obj)

    def _save_bytes_data(self, obj, data):
        var n = len(data)
        if n <= 0xff:
            self._write_bytes(SHORT_BINBYTES + bytes([n]), data)
        elif n <= 0xffffffff:
            self._write_bytes(BINBYTES + _u32le(n), data)
        elif self.proto >= 4:
            self._write_bytes(BINBYTES8 + _u64le(n), data)
        else:
            raise OverflowError("serializing a bytes object larger than 4 GiB requires pickle protocol 4 or higher")
        self._memoize(obj)

    def _save_bytearray(self, obj):
        if self.proto < 5:
            if len(obj) == 0:
                self._save_reduce((bytearray, ()), obj)
            else:
                self._save_reduce((bytearray, (bytes(obj),)), obj)
            return
        self._write_bytes(BYTEARRAY8 + _u64le(len(obj)), bytes(obj))
        self._memoize(obj)

    def _save_picklebuffer(self, obj):
        if self.proto < 5:
            raise PicklingError("PickleBuffer can only be pickled with protocol >= 5")
        var in_band = True
        if self._buffer_callback is not None:
            in_band = bool(self._buffer_callback(obj))
        if in_band:
            var raw = obj._ny_live().tobytes()
            if obj.readonly:
                self._save_bytes_data(obj, raw)
            else:
                self._write_bytes(BYTEARRAY8 + _u64le(len(raw)), raw)
                self._memoize(obj)
        else:
            self._write(NEXT_BUFFER)
            if obj.readonly:
                self._write(READONLY_BUFFER)

    def _save_str(self, obj, key=None):
        if self.bin:
            var enc = obj.encode("utf-8")
            var n = len(enc)
            if n <= 0xff and self.proto >= 4:
                self._write_bytes(SHORT_BINUNICODE + bytes([n]), enc)
            elif n <= 0xffffffff:
                self._write_bytes(BINUNICODE + _u32le(n), enc)
            elif self.proto >= 4:
                self._write_bytes(BINUNICODE8 + _u64le(n), enc)
            else:
                raise OverflowError("serializing a string larger than 4 GiB requires pickle protocol 4 or higher")
        else:
            self._write(UNICODE + _raw_unicode_escape(obj) + b"\n")
        self._memoize(obj, key)

    def _save_tuple(self, obj):
        var n = len(obj)
        if n == 0:
            if self.proto:
                self._write(EMPTY_TUPLE)
            else:
                self._write(MARK + TUPLE)
            return
        if n <= 3 and self.proto >= 2:
            for e in obj:
                self.save(e)
            if self._in_memo(obj):
                for i in range(n):
                    self._write(POP)
                self._memo_get(obj)
                return
            self._write([EMPTY_TUPLE, TUPLE1, TUPLE2, TUPLE3][n])
            self._memoize(obj)
            return
        self._write(MARK)
        for e in obj:
            self.save(e)
        if self._in_memo(obj):
            if self.bin:
                self._write(POP_MARK)
            else:
                self._write(POP * (n + 1))
            self._memo_get(obj)
            return
        self._write(TUPLE)
        self._memoize(obj)

    def _save_list(self, obj):
        if self.bin:
            self._write(EMPTY_LIST)
        else:
            self._write(MARK + LIST)
        self._memoize(obj)
        if len(obj) == 0:
            return
        if self.proto > 0:
            self._batch_list_exact(obj)
        else:
            self._batch_list(iter(obj))

    def _batch_list_exact(self, obj):
        var n = len(obj)
        if n == 1:
            self.save(obj[0])
            self._write(APPEND)
            return
        var total = 0
        while True:
            self._write(MARK)
            var this_batch = 0
            while total < len(obj):
                self.save(obj[total])
                total = total + 1
                this_batch = this_batch + 1
                if this_batch == _BATCHSIZE:
                    break
            self._write(APPENDS)
            if total >= len(obj):
                break

    def _batch_list(self, it):
        if not self.bin:
            for x in it:
                self.save(x)
                self._write(APPEND)
            return
        var sentinel = []
        while True:
            var first = next(it, sentinel)
            if first is sentinel:
                break
            var second = next(it, sentinel)
            if second is sentinel:
                self.save(first)
                self._write(APPEND)
                break
            self._write(MARK)
            self.save(first)
            var n = 1
            var x = second
            while x is not sentinel:
                self.save(x)
                n = n + 1
                if n == _BATCHSIZE:
                    break
                x = next(it, sentinel)
            self._write(APPENDS)
            if n != _BATCHSIZE:
                break

    def _save_dict(self, obj):
        if self.bin:
            self._write(EMPTY_DICT)
        else:
            self._write(MARK + DICT)
        self._memoize(obj)
        if len(obj) == 0:
            return
        if self.proto > 0:
            self._batch_dict_exact(obj)
        else:
            self._batch_dict(iter(obj.items()))

    def _batch_dict_exact(self, obj):
        var size = len(obj)
        var keys = list(obj)
        if size == 1:
            self.save(keys[0])
            self.save(obj[keys[0]])
            self._write(SETITEM)
            return
        var pos = 0
        while True:
            self._write(MARK)
            var i = 0
            while pos < len(keys):
                var k = keys[pos]
                pos = pos + 1
                self.save(k)
                self.save(obj[k])
                i = i + 1
                if i == _BATCHSIZE:
                    break
            self._write(SETITEMS)
            if len(obj) != size:
                raise RuntimeError("dictionary changed size during iteration")
            if i != _BATCHSIZE:
                break

    def _batch_dict(self, it):
        if not self.bin:
            for kv in it:
                if not isinstance(kv, tuple) or len(kv) != 2:
                    raise TypeError("dict items iterator must return 2-tuples")
                self.save(kv[0])
                self.save(kv[1])
                self._write(SETITEM)
            return
        var sentinel = []
        while True:
            var first = next(it, sentinel)
            if first is sentinel:
                break
            var second = next(it, sentinel)
            if second is sentinel:
                self.save(first[0])
                self.save(first[1])
                self._write(SETITEM)
                break
            self._write(MARK)
            self.save(first[0])
            self.save(first[1])
            var n = 1
            var kv = second
            while kv is not sentinel:
                self.save(kv[0])
                self.save(kv[1])
                n = n + 1
                if n == _BATCHSIZE:
                    break
                kv = next(it, sentinel)
            self._write(SETITEMS)
            if n != _BATCHSIZE:
                break

    def _save_set(self, obj):
        if self.proto < 4:
            self._save_reduce((set, (list(obj),)), obj)
            return
        self._write(EMPTY_SET)
        self._memoize(obj)
        var items = list(obj)
        var size = len(items)
        if size == 0:
            return
        var pos = 0
        while True:
            self._write(MARK)
            var i = 0
            while pos < size:
                self.save(items[pos])
                pos = pos + 1
                i = i + 1
                if i == _BATCHSIZE:
                    break
            self._write(ADDITEMS)
            if len(obj) != size:
                raise RuntimeError("set changed size during iteration")
            if i != _BATCHSIZE:
                break

    def _save_frozenset(self, obj):
        if self.proto < 4:
            self._save_reduce((frozenset, (list(obj),)), obj)
            return
        self._write(MARK)
        for e in obj:
            self.save(e)
        if self._in_memo(obj):
            self._write(POP_MARK)
            self._memo_get(obj)
            return
        self._write(FROZENSET)
        self._memoize(obj)

    def _save_type(self, obj):
        if obj is type(None):
            return self._save_reduce((type, (None,)), obj)
        if obj is type(NotImplemented):
            return self._save_reduce((type, (NotImplemented,)), obj)
        if obj is type(...):
            return self._save_reduce((type, (...,)), obj)
        return self.save_global(obj)

    def save_global(self, obj, name=None):
        var module_name = None
        if name is None:
            var mn = _global_name(obj)
            module_name = mn[0]
            name = mn[1]
        else:
            module_name = _whichmodule(obj, name)
        var parent = None
        var module = None
        if module_name == "builtins":
            module = "builtins"
            try:
                var found = _builtin(name)
            except Exception:
                raise PicklingError("Can't pickle " + repr(obj) + ": attribute lookup " + name
                                    + " on builtins failed") from None
            parent = module
        elif module_name == "_codecs":
            module = "_codecs"
            parent = module
        else:
            try:
                module = _import(module_name)
            except Exception:
                raise PicklingError("Can't pickle " + repr(obj) + ": import of module " + repr(module_name)
                                    + " failed") from None
            var got = None
            try:
                var r = _getattribute(module, name)
                got = r[0]
                parent = r[1]
            except AttributeError:
                raise PicklingError("Can't pickle " + repr(obj) + ": attribute lookup " + name + " on "
                                    + module_name + " failed") from None
            if got is not obj:
                raise PicklingError("Can't pickle " + repr(obj) + ": it's not the same object as "
                                    + module_name + "." + name)
        if self.proto >= 2:
            var code = copyreg._extension_registry.get((module_name, name))
            if code:
                if code <= 0xff:
                    self._write(EXT1 + bytes([code]))
                elif code <= 0xffff:
                    self._write(EXT2 + bytes([code & 0xff, code >> 8]))
                else:
                    self._write(EXT4 + _u32le(code))
                return
        var lastname = name.rpartition(".")[2]
        if parent is module:
            name = lastname
        if self.proto >= 4:
            if getattr(obj, "_ny_ctype", False):
                # a type CPython implements in C makes its __module__ and
                # __qualname__ strings anew: never found in the memo
                self._fresh = self._fresh + 1
                self._save_str(module_name, ("fresh", self._fresh))
                self._fresh = self._fresh + 1
                self._save_str(name, ("fresh", self._fresh))
            else:
                self.save(module_name)
                self.save(name)
            self._write(STACK_GLOBAL)
        elif parent is not module:
            self._save_reduce((getattr, (parent, lastname)), None)
        else:
            var mn = module_name
            var nm = name
            if self.proto < 3 and self.fix_imports:
                var r2 = _REVERSE_NAME_MAPPING.get((mn, nm))
                if r2 is not None:
                    mn = r2[0]
                    nm = r2[1]
                elif mn in _REVERSE_IMPORT_MAPPING:
                    mn = _REVERSE_IMPORT_MAPPING[mn]
            var enc = "utf-8" if self.proto == 3 else "ascii"
            try:
                self._write(GLOBAL + mn.encode(enc) + b"\n" + nm.encode(enc) + b"\n")
            except UnicodeEncodeError:
                raise PicklingError("can't pickle global identifier '" + module_name + "." + name
                                    + "' using pickle protocol " + str(self.proto)) from None
        self._memoize(obj)

    def _save_reduce(self, rv, obj):
        var size = len(rv)
        if size < 2 or size > 6:
            raise PicklingError("tuple returned by __reduce__ must contain 2 through 6 elements")
        var func = rv[0]
        var args = rv[1]
        var state = rv[2] if size > 2 else None
        var listitems = rv[3] if size > 3 else None
        var dictitems = rv[4] if size > 4 else None
        var state_setter = rv[5] if size > 5 else None
        if not callable(func):
            raise PicklingError("first item of the tuple returned by __reduce__ must be callable")
        if not isinstance(args, tuple):
            raise PicklingError("second item of the tuple returned by __reduce__ must be a tuple")
        if listitems is not None and not hasattr(listitems, "__next__"):
            raise PicklingError("fourth element of the tuple returned by __reduce__ must be an iterator, not "
                                + type(listitems).__name__)
        if dictitems is not None and not hasattr(dictitems, "__next__"):
            raise PicklingError("fifth element of the tuple returned by __reduce__ must be an iterator, not "
                                + type(dictitems).__name__)
        if state_setter is not None and not callable(state_setter):
            raise PicklingError("sixth element of the tuple returned by __reduce__ must be a function, not "
                                + type(state_setter).__name__)
        var fname = getattr(func, "__name__", "") if self.proto >= 2 else ""
        if fname == "__newobj_ex__":
            if len(args) != 3:
                raise PicklingError("length of the NEWOBJ_EX argument tuple must be exactly 3, not "
                                    + str(len(args)))
            var cls = args[0]
            if not _is_type_object(cls):
                raise PicklingError("first item from NEWOBJ_EX argument tuple must be a class, not "
                                    + type(cls).__name__)
            if not isinstance(args[1], tuple):
                raise PicklingError("second item from NEWOBJ_EX argument tuple must be a tuple, not "
                                    + type(args[1]).__name__)
            if not isinstance(args[2], dict):
                raise PicklingError("third item from NEWOBJ_EX argument tuple must be a dict, not "
                                    + type(args[2]).__name__)
            if self.proto >= 4:
                self.save(cls)
                self.save(args[1])
                self.save(args[2])
                self._write(NEWOBJ_EX)
            else:
                import functools
                var p = functools.partial(cls.__new__, cls, *args[1], **args[2])
                self.save(p)
                self.save(())
                self._write(REDUCE)
        elif fname == "__newobj__":
            if len(args) < 1:
                raise PicklingError("__newobj__ arglist is empty")
            var cls = args[0]
            if not _is_type_object(cls):
                raise PicklingError("args[0] from __newobj__ args is not a type")
            if obj is not None and type(obj) is not cls:
                raise PicklingError("args[0] from __newobj__ args has the wrong class")
            self.save(cls)
            self.save(tuple(args[1:]))
            self._write(NEWOBJ)
        else:
            self.save(func)
            self.save(args)
            self._write(REDUCE)
        if obj is not None:
            if self._in_memo(obj):
                self._write(POP)
                self._memo_get(obj)
                return
            self._memoize(obj)
        if listitems is not None:
            self._batch_list(listitems)
        if dictitems is not None:
            self._batch_dict(dictitems)
        if state is not None:
            if state_setter is None:
                self.save(state)
                self._write(BUILD)
            else:
                self.save(state_setter)
                self.save(obj)
                self.save(state)
                self._write(TUPLE2)
                self._write(REDUCE)
                self._write(POP)


# ── Unpickler ───────────────────────────────────────────────────────────────
class _Mark:
    pass


class Unpickler:
    """Reads a pickle from a binary file and rebuilds the object."""

    def __init__(self, file, fix_imports=True, encoding="ASCII", errors="strict", buffers=None):
        self._file = file
        self._data = None
        self._pos = 0
        self._frame = None
        self._fpos = 0
        self.fix_imports = fix_imports
        self.encoding = encoding
        self.errors = errors
        self._buffers = iter(buffers) if buffers is not None else None
        self.memo = {}
        self.proto = 0
        self._dispatch = None

    # (loads gives the bytes themselves: no file object in between)
    def _set_bytes(self, data):
        self._data = data
        self._pos = 0

    def _read_raw(self, n):
        if self._data is not None:
            var p = self._pos
            var b = self._data[p:p + n]
            self._pos = p + len(b)
            return b
        return self._file.read(n)

    def _readline_raw(self):
        if self._data is not None:
            var p = self._pos
            var i = self._data.find(b"\n", p)
            if i < 0:
                self._pos = len(self._data)
                return self._data[p:]
            self._pos = i + 1
            return self._data[p:i + 1]
        return self._file.readline()

    def _read(self, n):
        if self._frame is not None:
            var fp = self._fpos
            if fp + n <= len(self._frame):
                self._fpos = fp + n
                return self._frame[fp:fp + n]
            if fp < len(self._frame):
                raise UnpicklingError("pickle exhausted before end of frame")
            self._frame = None
        var b = self._read_raw(n)
        if len(b) < n:
            raise UnpicklingError("pickle data was truncated")
        return b

    def _readline(self):
        if self._frame is not None:
            var fp = self._fpos
            var i = self._frame.find(b"\n", fp)
            if i >= 0:
                self._fpos = i + 1
                return self._frame[fp:i + 1]
            if fp < len(self._frame):
                raise UnpicklingError("pickle exhausted before end of frame")
            self._frame = None
        var line = self._readline_raw()
        if not line.endswith(b"\n"):
            raise UnpicklingError("pickle data was truncated")
        return line

    def load(self):
        if not hasattr(self, "_file"):
            raise UnpicklingError("Unpickler.__init__() was not called by " + type(self).__name__ + ".__init__()")
        self.stack = []
        self.metastack = []
        self.proto = 0
        self._frame = None
        var first = True
        while True:
            var key = None
            if self._frame is not None and self._fpos < len(self._frame):
                key = self._frame[self._fpos]
                self._fpos = self._fpos + 1
            else:
                if self._frame is not None:
                    self._frame = None
                var b = self._read_raw(1)
                if not b:
                    raise EOFError("Ran out of input")
                key = b[0]
            first = False
            try:
                self._op(key)
            except _Stop as s:
                return s.value

    def _pop_mark(self):
        if not self.metastack:
            raise UnpicklingError("could not find MARK")
        var items = self.stack
        self.stack = self.metastack.pop()
        return items

    def _top(self):
        if not self.stack:
            raise UnpicklingError("unpickling stack underflow")
        return self.stack[-1]

    def _pop(self):
        if not self.stack:
            raise UnpicklingError("unpickling stack underflow")
        return self.stack.pop()

    def _memo_put(self, idx, v):
        if idx < 0:
            raise ValueError("negative PUT argument")
        self.memo[idx] = v

    def _memo_get(self, idx):
        if idx not in self.memo:
            raise UnpicklingError("Memo value not found at index " + str(idx))
        self.stack.append(self.memo[idx])

    def _decode_str(self, b):
        if self.encoding == "bytes":
            return b
        return b.decode(self.encoding, self.errors)

    def persistent_load(self, pid):
        raise UnpicklingError("A load persistent id instruction was encountered,\nbut no persistent_load "
                              + "function was specified.")

    def find_class(self, module, name):
        _ny_sys_audit("pickle.find_class", module, name)   # round 86: CPython's event
        if self.proto < 3 and self.fix_imports:
            var r = _NAME_MAPPING.get((module, name))
            if r is not None:
                module = r[0]
                name = r[1]
            elif module in _IMPORT_MAPPING:
                module = _IMPORT_MAPPING[module]
        var mod = None
        try:
            mod = _import(module)
        except Exception:
            raise ModuleNotFoundError("No module named " + repr(module)) from None
        try:
            if self.proto >= 4:
                return _getattribute(mod, name)[0]
            return _attr_of(mod, name)
        except AttributeError:
            raise AttributeError("Can't get attribute " + repr(name) + " on <module " + repr(module) + ">") from None

    def _instantiate(self, klass, args):
        if args or not _is_type_object(klass) or hasattr(klass, "__getinitargs__"):
            try:
                return klass(*args)
            except TypeError as err:
                raise TypeError("in constructor for " + klass.__name__ + ": " + str(err)) from None
        return copyreg._ny_new(klass, ())

    def _op(self, key):
        var st = self.stack
        if key == 0x80:                        # PROTO
            var p = self._read(1)[0]
            if not 0 <= p <= HIGHEST_PROTOCOL:
                raise ValueError("unsupported pickle protocol: " + str(p))
            self.proto = p
        elif key == 0x95:                      # FRAME
            var n = _le_int(self._read(8))
            if self._frame is not None and self._fpos < len(self._frame):
                raise UnpicklingError("beginning of a new frame before end of current frame")
            self._frame = self._read_raw(n)
            self._fpos = 0
            if len(self._frame) < n:
                raise UnpicklingError("pickle data was truncated")
        elif key == 0x2e:                      # STOP
            raise _Stop(self._pop())
        elif key == 0x28:                      # MARK
            self.metastack.append(self.stack)
            self.stack = []
        elif key == 0x4e:                      # NONE
            st.append(None)
        elif key == 0x88:
            st.append(True)
        elif key == 0x89:
            st.append(False)
        elif key == 0x49:                      # INT
            var data = self._readline()
            if data == b"00\n":
                st.append(False)
            elif data == b"01\n":
                st.append(True)
            else:
                st.append(int(data.decode("ascii").strip(), 0))
        elif key == 0x4a:                      # BININT
            st.append(int.from_bytes(self._read(4), "little", signed=True))
        elif key == 0x4b:
            st.append(self._read(1)[0])
        elif key == 0x4d:
            st.append(_le_int(self._read(2)))
        elif key == 0x4c:                      # LONG
            var v = self._readline()[:-1].decode("ascii")
            if v and v[-1] == "L":
                v = v[:-1]
            st.append(int(v, 0))
        elif key == 0x8a:                      # LONG1
            var n = self._read(1)[0]
            st.append(_decode_long(self._read(n)))
        elif key == 0x8b:                      # LONG4
            var n = int.from_bytes(self._read(4), "little", signed=True)
            if n < 0:
                raise UnpicklingError("LONG pickle has negative byte count")
            st.append(_decode_long(self._read(n)))
        elif key == 0x46:                      # FLOAT
            st.append(float(self._readline()[:-1].decode("ascii")))
        elif key == 0x47:                      # BINFLOAT
            st.append(struct.unpack(">d", self._read(8))[0])
        elif key == 0x53:                      # STRING
            var data = self._readline()[:-1]
            if len(data) >= 2 and data[0] == data[-1] and (data[0] == 34 or data[0] == 39):
                data = data[1:-1]
            else:
                raise UnpicklingError("the STRING opcode argument must be quoted")
            st.append(self._decode_str(_escape_decode(data)))
        elif key == 0x54:                      # BINSTRING
            var n = int.from_bytes(self._read(4), "little", signed=True)
            if n < 0:
                raise UnpicklingError("BINSTRING pickle has negative byte count")
            st.append(self._decode_str(self._read(n)))
        elif key == 0x55:                      # SHORT_BINSTRING
            var n = self._read(1)[0]
            st.append(self._decode_str(self._read(n)))
        elif key == 0x42:                      # BINBYTES
            var n = _le_int(self._read(4))
            st.append(bytes(self._read(n)))
        elif key == 0x43:                      # SHORT_BINBYTES
            var n = self._read(1)[0]
            st.append(bytes(self._read(n)))
        elif key == 0x8e:                      # BINBYTES8
            var n = _le_int(self._read(8))
            st.append(bytes(self._read(n)))
        elif key == 0x96:                      # BYTEARRAY8
            var n = _le_int(self._read(8))
            st.append(bytearray(self._read(n)))
        elif key == 0x97:                      # NEXT_BUFFER
            if self._buffers is None:
                raise UnpicklingError("pickle stream refers to out-of-band data but no *buffers* argument was given")
            var sentinel = []
            var buf = next(self._buffers, sentinel)
            if buf is sentinel:
                raise UnpicklingError("not enough out-of-band buffers")
            st.append(buf)
        elif key == 0x98:                      # READONLY_BUFFER
            var b = self._top()
            if isinstance(b, bytearray):
                st[-1] = bytes(b)
            elif not isinstance(b, bytes):
                # a buffer: a read-only view of it, as CPython's (round 84)
                var m = memoryview(b)
                if not m.readonly:
                    st[-1] = m.toreadonly()
                m.release()
        elif key == 0x56:                      # UNICODE
            st.append(_raw_unicode_unescape(self._readline()[:-1]))
        elif key == 0x58:                      # BINUNICODE
            var n = _le_int(self._read(4))
            st.append(bytes(self._read(n)).decode("utf-8"))
        elif key == 0x8d:                      # BINUNICODE8
            var n = _le_int(self._read(8))
            st.append(bytes(self._read(n)).decode("utf-8"))
        elif key == 0x8c:                      # SHORT_BINUNICODE
            var n = self._read(1)[0]
            st.append(bytes(self._read(n)).decode("utf-8"))
        elif key == 0x74:                      # TUPLE
            var items = self._pop_mark()
            self.stack.append(tuple(items))
        elif key == 0x29:                      # EMPTY_TUPLE
            st.append(())
        elif key == 0x85:
            st[-1] = (st[-1],)
        elif key == 0x86:
            var b = st.pop()
            var a = st.pop()
            st.append((a, b))
        elif key == 0x87:
            var c = st.pop()
            var b = st.pop()
            var a = st.pop()
            st.append((a, b, c))
        elif key == 0x5d:                      # EMPTY_LIST
            st.append([])
        elif key == 0x7d:                      # EMPTY_DICT
            st.append({})
        elif key == 0x8f:                      # EMPTY_SET
            st.append(set())
        elif key == 0x91:                      # FROZENSET
            var items = self._pop_mark()
            self.stack.append(frozenset(items))
        elif key == 0x6c:                      # LIST
            var items = self._pop_mark()
            self.stack.append(list(items))
        elif key == 0x64:                      # DICT
            var items = self._pop_mark()
            var d = {}
            var i = 0
            while i < len(items):
                d[items[i]] = items[i + 1]
                i = i + 2
            self.stack.append(d)
        elif key == 0x69:                      # INST
            var module = self._readline()[:-1].decode("ascii")
            var name = self._readline()[:-1].decode("ascii")
            var klass = self.find_class(module, name)
            var args = self._pop_mark()
            self.stack.append(self._instantiate(klass, tuple(args)))
        elif key == 0x6f:                      # OBJ
            var args = self._pop_mark()
            var cls = args.pop(0)
            self.stack.append(self._instantiate(cls, tuple(args)))
        elif key == 0x81:                      # NEWOBJ
            var args = st.pop()
            var cls = st.pop()
            st.append(copyreg._ny_new(cls, args))
        elif key == 0x92:                      # NEWOBJ_EX
            var kwargs = st.pop()
            var args = st.pop()
            var cls = st.pop()
            st.append(copyreg._ny_new(cls, args, kwargs))
        elif key == 0x63:                      # GLOBAL
            var module = self._readline()[:-1].decode("utf-8")
            var name = self._readline()[:-1].decode("utf-8")
            st.append(self.find_class(module, name))
        elif key == 0x93:                      # STACK_GLOBAL
            var name = st.pop()
            var module = st.pop()
            if type(name) is not str or type(module) is not str:
                raise UnpicklingError("STACK_GLOBAL requires str")
            st.append(self.find_class(module, name))
        elif key == 0x82 or key == 0x83 or key == 0x84:   # EXT1/2/4
            var code = 0
            if key == 0x82:
                code = self._read(1)[0]
            elif key == 0x83:
                code = _le_int(self._read(2))
            else:
                code = int.from_bytes(self._read(4), "little", signed=True)
            self._get_extension(code)
        elif key == 0x52:                      # REDUCE
            var args = st.pop()
            var func = st[-1]
            st[-1] = func(*args)
        elif key == 0x30:                      # POP
            if self.stack:
                self.stack.pop()
            else:
                self._pop_mark()
        elif key == 0x31:                      # POP_MARK
            self._pop_mark()
        elif key == 0x32:                      # DUP
            st.append(st[-1])
        elif key == 0x67:                      # GET
            self._memo_get(int(self._readline()[:-1].decode("ascii")))
        elif key == 0x68:                      # BINGET
            self._memo_get(self._read(1)[0])
        elif key == 0x6a:                      # LONG_BINGET
            self._memo_get(_le_int(self._read(4)))
        elif key == 0x70:                      # PUT
            var i = int(self._readline()[:-1].decode("ascii"))
            self._memo_put(i, self._top())
        elif key == 0x71:                      # BINPUT
            self._memo_put(self._read(1)[0], self._top())
        elif key == 0x72:                      # LONG_BINPUT
            var i = _le_int(self._read(4))
            if i > 0x7fffffff:
                raise ValueError("negative LONG_BINPUT argument")
            self._memo_put(i, self._top())
        elif key == 0x94:                      # MEMOIZE
            self.memo[len(self.memo)] = self._top()
        elif key == 0x61:                      # APPEND
            var v = st.pop()
            var lst = st[-1]
            lst.append(v)
        elif key == 0x65:                      # APPENDS
            var items = self._pop_mark()
            var lst = self.stack[-1]
            if type(lst) is list:
                lst.extend(items)
            else:
                var ext = getattr(lst, "extend", None)
                if ext is not None:
                    ext(items)
                else:
                    for x in items:
                        lst.append(x)
        elif key == 0x73:                      # SETITEM
            var v = st.pop()
            var k = st.pop()
            st[-1][k] = v
        elif key == 0x75:                      # SETITEMS
            var items = self._pop_mark()
            var d = self.stack[-1]
            var i = 0
            while i < len(items):
                d[items[i]] = items[i + 1]
                i = i + 2
        elif key == 0x90:                      # ADDITEMS
            var items = self._pop_mark()
            var s = self.stack[-1]
            if isinstance(s, set):
                s.update(items)
            else:
                for x in items:
                    s.add(x)
        elif key == 0x62:                      # BUILD
            var state = st.pop()
            var inst = st[-1]
            self._build(inst, state)
        elif key == 0x50:                      # PERSID
            var pid = self._readline()[:-1].decode("ascii")
            st.append(self.persistent_load(pid))
        elif key == 0x51:                      # BINPERSID
            var pid = st.pop()
            st.append(self.persistent_load(pid))
        else:
            # (as _pickle.c: printable ASCII as itself, anything else as \xNN)
            if 0x20 <= key and key <= 0x7e and key != 0x27 and key != 0x5c:
                raise UnpicklingError("invalid load key, '" + chr(key) + "'.")
            raise UnpicklingError("invalid load key, '\\x%02x'." % key)

    def _build(self, inst, state):
        var setstate = getattr(inst, "__setstate__", None)
        if setstate is not None:
            setstate(state)
            return
        var slotstate = None
        if isinstance(state, tuple) and len(state) == 2:
            slotstate = state[1]
            state = state[0]
        if state:
            var d = inst.__dict__
            for k in state:
                d[k] = state[k]
        if slotstate:
            for k in slotstate:
                setattr(inst, k, slotstate[k])

    def _get_extension(self, code):
        var obj = copyreg._extension_cache.get(code)
        if obj is not None:
            self.stack.append(obj)
            return
        var key = copyreg._inverted_registry.get(code)
        if not key:
            if code <= 0:
                raise UnpicklingError("EXT specifies code <= 0")
            raise ValueError("unregistered extension code " + str(code))
        obj = self.find_class(key[0], key[1])
        copyreg._extension_cache[code] = obj
        self.stack.append(obj)


# ── the functions ───────────────────────────────────────────────────────────
class _BytesSink:
    def __init__(self):
        self.data = b""

    def write(self, b):
        self.data = b
        return len(b)


def dump(obj, file, protocol=None, fix_imports=True, buffer_callback=None):
    Pickler(file, protocol, fix_imports, buffer_callback).dump(obj)


def dumps(obj, protocol=None, fix_imports=True, buffer_callback=None):
    # plain data at protocols 4 and 5: the same bytes, natively (round 80,
    # src/builtins/nypickle.cpp; none when obj holds anything else)
    if buffer_callback is None:
        var p = DEFAULT_PROTOCOL if protocol is None else protocol
        if p == 4 or p == 5:
            var fast = _ny_pickle_dumps(obj, p)
            if fast is not None:
                return fast
    var sink = _BytesSink()
    Pickler(sink, protocol, fix_imports, buffer_callback).dump(obj)
    return sink.data


def load(file, fix_imports=True, encoding="ASCII", errors="strict", buffers=None):
    return Unpickler(file, fix_imports, encoding, errors, buffers).load()


def loads(data, fix_imports=True, encoding="ASCII", errors="strict", buffers=None):
    if isinstance(data, str):
        raise TypeError("a bytes-like object is required, not 'str'")
    if buffers is None:
        # plain data, natively (round 80; (False, None) for anything else)
        var r = _ny_pickle_loads(bytes(data))
        if r[0]:
            return r[1]
    var u = Unpickler(None, fix_imports, encoding, errors, buffers)
    u._set_bytes(bytes(data))
    return u.load()
