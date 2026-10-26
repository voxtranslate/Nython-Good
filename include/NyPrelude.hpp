#pragma once
// NyPrelude.hpp - Nython source both engines run before a program starts.
//
// It holds what is easier to write in Nython than natively and must behave
// identically on the interpreter and the VM: today, Python-style file objects.
// `open(path, mode="r")` returns a NythonFile with read/readline/readlines/
// write/writelines/seek/tell/flush/close, context-manager support and line
// iteration. The object sits on the integer handle API (file_open,
// file_read, ...), which both engines share through the builtin bridge, so
// the handle functions still accept a NythonFile wherever they take a handle
// and code written against `open()` returning an int keeps working
// (`fh > 0`, `file_read(fh)`, `file_close(fh)`).
//
// Round 77: the asynchronous protocols the parser desugars to (Parser.cpp,
// async_def_desugar / `async for` / `async with`): _ny_async_cm,
// _ny_async_gen, _ny_aiter, and the aiter()/anext() builtins.
//
// Round 77 also: builtin_mirrors_source() at the end, run on demand.

#include <string>

namespace nyrt {

// (round 84) The buffer protocol's part of the prelude - memoryview's
// members, the managed buffers, the bytes-like helpers - is in
// src/NyPreludeBuffer.cpp, a unit of its own (editing it does not rebuild
// every file that includes this header), loaded on first need as the mirror
// chunk "buffer" (builtin_mirror_chunk); the startup prelude below holds the
// class memoryview and the stubs that load it.
const char* prelude_buffer_source();
// (round 85) The rest of Python's posix (nt on Windows) module - what CPython's
// posixmodule.c has and the "os" chunk below does not - is in
// src/NyPreludePosix.cpp, loaded by the os chunk as the mirror chunk "posix".
const char* prelude_posix_source();
// (round 86) What only a program with an audit hook needs (the events'
// argument helpers, code.replace, types.FunctionType) is src/NyPreludeAudit.cpp,
// the chunk "audit": the first sys.addaudithook loads it.
const char* prelude_audit_source();

inline const char* prelude_source() {
    return R"NYPRELUDE(
# ── memoryview, loaded on first need (round 84) ───────────────────────────
# The class is here, so isinstance(x, memoryview) and subclass checks cost
# nothing; its members, the managed buffers and the helpers are the mirror
# chunk "buffer" (src/NyPreludeBuffer.cpp), which the first view - or the
# first bytes-like argument that is not bytes/bytearray - loads
# (_ny_load_chunk). The helpers' stubs below call the real ones the chunk
# binds in the prelude's scope.
class memoryview:
    """Create a new memoryview object which references the given object."""

    def __new__(cls, *args, **kwargs):
        # memoryview(object): CPython's argument messages
        var n = len(args) + len(kwargs)
        if n > 1:
            if len(kwargs) > 1 and not args:
                raise TypeError("memoryview() takes at most 1 keyword argument (" + str(n) + " given)")
            raise TypeError("memoryview() takes at most 1 argument (" + str(n) + " given)")
        if not args and "object" not in kwargs:
            raise TypeError("memoryview() missing required argument 'object' (pos 1)")
        _ny_load_chunk("buffer")
        return _ny_mv_export(args[0] if args else kwargs["object"], "memoryview: ")

def _ny_is_exporter(obj):
    return (isinstance(obj, bytes) or isinstance(obj, bytearray) or isinstance(obj, memoryview)
            or getattr(type(obj), "__buffer__", None) is not None)

def _ny_bytes_like(obj, what=""):
    if isinstance(obj, bytes) or isinstance(obj, bytearray):
        return obj
    _ny_load_chunk("buffer")
    return _ny_bytes_like(obj, what)

def _ny_buffer_bytes(obj):
    _ny_load_chunk("buffer")
    return _ny_buffer_bytes(obj)

def _ny_writable_view(obj, where="argument"):
    _ny_load_chunk("buffer")
    return _ny_writable_view(obj, where)

def _ny_memview_raw(obj, addr, nbytes, readonly, fmt="B", itemsize=1, shape=None, strides=None, release=None,
                    owner=None):
    _ny_load_chunk("buffer")
    return _ny_memview_raw(obj, addr, nbytes, readonly, fmt, itemsize, shape, strides, release, owner)

def _ny_pct_arg(v, c):
    _ny_load_chunk("buffer")
    return _ny_pct_arg(v, c)

def _ny_mv_export(obj, what):
    _ny_load_chunk("buffer")
    return _ny_mv_export(obj, what)

def _ny_mv_make(mb, addr, fmt, isz, shape, strides, ro):
    _ny_load_chunk("buffer")
    return _ny_mv_make(mb, addr, fmt, isz, shape, strides, ro)

def _ny_mv_copy(m, ro):
    _ny_load_chunk("buffer")
    return _ny_mv_copy(m, ro)

class NythonFile:
    def __init__(self, path, mode, handle, encoding="utf-8"):
        self.name = path
        self.mode = mode
        self.handle = handle
        self.closed = false
        self.binary = "b" in mode
        self.encoding = none if self.binary else encoding
        # open(newline=...): None translates as the platform does (\r\n on
        # Windows); "" and "\n" write text untouched; "\r" and "\r\n"
        # replace each \n (round 77)
        self.newline = none

    def _check(self):
        if self.closed:
            raise ValueError("I/O operation on closed file: " + self.name)

    def read(self, size=-1):
        self._check()
        if size is none:
            size = -1
        if self.binary:
            return file_read_bytes(self.handle, size)
        return file_read(self.handle, size)

    def readline(self, size=-1):
        self._check()
        if self.binary:
            return file_readline_bytes(self.handle, size)
        return file_readline(self.handle, true)

    # (round 84) read into any writable buffer, in place: a bytearray, a
    # memoryview's slice, an array, an mmap
    def readinto(self, b):
        self._check()
        var view = _ny_writable_view(b, "readinto() argument")
        try:
            return file_readinto(self.handle, view._ny_a, len(view))   # in place, no copy
        finally:
            view.release()

    def readinto1(self, b):
        return self.readinto(b)

    def readlines(self, hint=-1):
        self._check()
        var out = []
        var line = self.readline()
        while len(line) > 0:
            out.append(line)
            line = self.readline()
        return out

    def write(self, data):
        self._check()
        if self.binary:
            if not (isinstance(data, "bytes") or isinstance(data, "bytearray")):
                data = _ny_bytes_like(data)     # round 84: any buffer (memoryview, array ...)
            return file_write(self.handle, data)
        if isinstance(data, "bytes") or isinstance(data, "bytearray"):
            raise TypeError("write() argument must be str, not " + data.type_name())
        var text = str(data)
        var n = len(text)
        if self.newline == "\r\n" or self.newline == "\r":
            text = text.replace("\n", self.newline)
        file_write(self.handle, text)
        return n

    def writelines(self, lines):
        self._check()
        for line in lines:
            self.write(line)
        return none

    def readable(self):
        return "r" in self.mode or "+" in self.mode

    def writable(self):
        return "w" in self.mode or "a" in self.mode or "x" in self.mode or "+" in self.mode

    def seekable(self):
        return true

    def truncate(self, size=none):
        self._check()
        return file_truncate(self.handle, size)

    def seek(self, offset, whence=0):
        self._check()
        return file_seek(self.handle, offset, whence)

    def tell(self):
        self._check()
        return file_tell(self.handle)

    def flush(self):
        self._check()
        file_flush(self.handle)
        return none

    def close(self):
        if not self.closed:
            file_close(self.handle)
            self.closed = true
        return none

    # As CPython's io objects: a file dropped without close() is closed when
    # its last reference goes - `open(p).read()` kept the handle until the
    # program ended, and Windows cannot delete or rename an open file
    # (round 77).
    def __del__(self):
        if not getattr(self, "closed", true):
            self.closed = true
            file_close(self.handle)

    def fileno(self):
        # the OS descriptor, as CPython's (round 82: it was the handle number)
        if self.closed:
            raise ValueError("I/O operation on closed file")
        return file_fileno(self.handle)

    def __enter__(self):
        return self

    def __exit__(self, exc_type=none, exc_value=none, tb=none):
        self.close()
        return false

    def __iter__(self):
        return self

    def __next__(self):
        var line = self.readline()
        if len(line) == 0:
            raise StopIteration("end of file")
        return line

    def __gt__(self, other):
        return self.handle > other

    def __ge__(self, other):
        return self.handle >= other

    def __lt__(self, other):
        return self.handle < other

    def __le__(self, other):
        return self.handle <= other

    def __str__(self):
        return "<file '" + str(self.name) + "' mode '" + self.mode + "'>"

class _NyStdStream:
    # sys.stdin / sys.stdout / sys.stderr (round 77): text streams over the
    # same output as print, so writes and prints interleave in order.
    def __init__(self, fd, name, mode):
        self.fd = fd
        self.name = name
        self.mode = mode
        self.encoding = "utf-8"
        self.errors = "strict"
        self.closed = false
        self.line_buffering = fd != 2

    def write(self, s):
        if not isinstance(s, "str"):
            raise TypeError("write() argument must be str, not " + type(s))
        if self.fd == 0:
            raise OSError("not writable")
        return stream_write(self.fd, s)

    def writelines(self, lines):
        for line in lines:
            self.write(line)
        return none

    def flush(self):
        if self.fd != 0:
            stream_flush(self.fd)
        return none

    def read(self, size=-1):
        if self.fd != 0:
            raise OSError("not readable")
        return stream_read(-1 if size is none else size)

    def readline(self, size=-1):
        if self.fd != 0:
            raise OSError("not readable")
        return stream_readline()

    def readlines(self, hint=-1):
        var out = []
        var line = self.readline()
        while len(line) > 0:
            out.append(line)
            line = self.readline()
        return out

    def fileno(self):
        return self.fd

    def isatty(self):
        return stream_isatty(self.fd)

    def readable(self):
        return self.fd == 0

    def writable(self):
        return self.fd != 0

    def seekable(self):
        return false

    def close(self):
        return none

    def __iter__(self):
        return self

    def __next__(self):
        var line = self.readline()
        if len(line) == 0:
            raise StopIteration("end of input")
        return line

    def __enter__(self):
        return self

    def __exit__(self, exc_type=none, exc_value=none, tb=none):
        return false

    def __repr__(self):
        return "<_io.TextIOWrapper name='" + self.name + "' mode='" + self.mode + "' encoding='utf-8'>"

_ny_stdin = _NyStdStream(0, "<stdin>", "r")
_ny_stdout = _NyStdStream(1, "<stdout>", "w")
_ny_stderr = _NyStdStream(2, "<stderr>", "w")

def _ny_print(*args, **kw):
    # print(...) with file=, flush= or *args (the parser hands those here;
    # the plain forms stay the print statement)
    for k in kw:
        if k != "sep" and k != "end" and k != "file" and k != "flush":
            raise TypeError("'" + k + "' is an invalid keyword argument for print()")
    var sep = kw.get("sep")
    var end = kw.get("end")
    var file = kw.get("file")
    if sep is none:
        sep = " "
    elif not isinstance(sep, "str"):
        raise TypeError("sep must be None or a string, not " + type(sep))
    if end is none:
        end = "\n"
    elif not isinstance(end, "str"):
        raise TypeError("end must be None or a string, not " + type(end))
    if file is none:
        # the print statement: to sys.stdout as it is now (it may have
        # been replaced, contextlib.redirect_stdout)
        print(sep.join([str(a) for a in args]), end=end)
        if kw.get("flush", false):
            _ny_stdout.flush()
        return none
    file.write(sep.join([str(a) for a in args]) + end)
    if kw.get("flush", false):
        file.flush()
    return none

class property:
    # Python's property, a data descriptor (round 77): C.__dict__["p"] and C.p
    # are this object, obj.p runs fget, obj.p = v fset, del obj.p fdel. The
    # engines call fget/fset/fdel of this exact class directly (no __get__
    # frame); a subclass goes through its own __get__/__set__/__delete__.
    def __init__(self, fget=None, fset=None, fdel=None, doc=None):
        self.fget = fget
        self.fset = fset
        self.fdel = fdel
        # the getter's docstring when none is given (CPython's getter_doc)
        self._ny_doc_from_fget = false
        if doc is None and fget is not None:
            doc = getattr(fget, "__doc__", None)
            self._ny_doc_from_fget = doc is not None
        self.__doc__ = doc
        self._ny_name = None
        var ab = false
        for f in (fget, fset, fdel):
            if f is not None and getattr(f, "__isabstractmethod__", false):
                ab = true
        self.__isabstractmethod__ = ab
    def __set_name__(self, owner, name):
        self._ny_name = name
    def _ny_copy(self, fget, fset, fdel):
        # CPython's property_copy: None keeps the old function
        if fget is None:
            fget = self.fget
        if fset is None:
            fset = self.fset
        if fdel is None:
            fdel = self.fdel
        var p = type(self)(fget, fset, fdel, None if self._ny_doc_from_fget and fget is not None else self.__doc__)
        p._ny_name = self._ny_name
        return p
    def getter(self, fget):
        return self._ny_copy(fget, self.fset, self.fdel)
    def setter(self, fset):
        return self._ny_copy(self.fget, fset, self.fdel)
    def deleter(self, fdel):
        return self._ny_copy(self.fget, self.fset, fdel)
    def _ny_err(self, obj, what):
        var n = "" if self._ny_name is None else " " + repr(self._ny_name)
        return AttributeError("property" + n + " of " + repr(type(obj).__name__) + " object has no " + what)
    def __get__(self, obj, objtype=None):
        if obj is None:
            return self
        if self.fget is None:
            raise self._ny_err(obj, "getter")
        return self.fget(obj)
    def __set__(self, obj, value):
        if self.fset is None:
            raise self._ny_err(obj, "setter")
        self.fset(obj, value)
    def __delete__(self, obj):
        if self.fdel is None:
            raise self._ny_err(obj, "deleter")
        self.fdel(obj)

def _ny_copy_wrapped(w, f):
    # what staticmethod/classmethod copy from the function (3.10+)
    for a in ("__module__", "__name__", "__qualname__", "__doc__"):
        try:
            _ny_setattr_raw(w, a, getattr(f, a))
        except Exception:
            pass
    w.__wrapped__ = f
    w.__isabstractmethod__ = bool(getattr(f, "__isabstractmethod__", false))

class staticmethod:
    # staticmethod(f) (round 77): a class body's staticmethod objects are
    # taken apart by the engines when the class is made (the function marked
    # static), and C.__dict__ gives this object back.
    def __init__(self, f):
        self.__func__ = f
        _ny_copy_wrapped(self, f)
    def __get__(self, obj, objtype=None):
        return self.__func__
    def __call__(self, *args, **kw):
        return self.__func__(*args, **kw)
    def __repr__(self):
        return "<staticmethod(" + repr(self.__func__) + ")>"

class classmethod:
    # classmethod(f) (round 77), taken apart like staticmethod
    def __init__(self, f):
        self.__func__ = f
        _ny_copy_wrapped(self, f)
    def __get__(self, obj, objtype=None):
        if objtype is None:
            objtype = type(obj)
        return _ny_method_new(self.__func__, objtype)
    def __repr__(self):
        return "<classmethod(" + repr(self.__func__) + ")>"

class ellipsis:
    # the type of `...` (round 77)
    def __repr__(self):
        return "Ellipsis"
    def __reduce__(self):
        return "Ellipsis"
Ellipsis = ellipsis()

class _NyMetaBound:
    # A metaclass method read through a class (Color.from_name): the class is
    # its first argument (round 77).
    def __init__(self, fn, cls):
        self.__func__ = fn
        self.__self__ = cls
    def __call__(self, *args, **kw):
        return self.__func__(self.__self__, *args, **kw)
    def __repr__(self):
        return "<bound method " + getattr(self.__func__, "__name__", "?") + " of " + repr(self.__self__) + ">"

class _NySuper:
    # super() / super(C, obj) used as a value on the interpreter (round 78):
    # the engine answers its other attributes and its methods from the
    # classes after __thisclass__ in the MRO of __self__ (the VM has its own
    # proxy kind).
    def __init__(self, t, obj):
        self.__self_class__ = obj if isinstance(obj, type) else type(obj)
        self.__self__ = obj
        self.__thisclass__ = t
    def __repr__(self):
        return "<super: <class '" + self.__thisclass__.__name__ + "'>, <" + self.__self_class__.__name__ + " object>>"

class _NyModuleTypeMeta(type):
    def __instancecheck__(cls, obj):
        for c in getattr(type(obj), "__mro__", ()):
            if c is cls:
                return True
        return False
    def __repr__(cls):
        if cls is _NyModuleType:
            return "<class 'module'>"
        return "<class '" + cls.__module__ + "." + cls.__qualname__ + "'>"

class _NyModuleType(metaclass=_NyModuleTypeMeta):
    # The type of modules (round 78): type(m) for what `import m` binds is
    # this class on both engines (it was dict), types.ModuleType is it, and
    # ModuleType(name, doc=None) makes a module object of its own.
    def __init__(self, name, doc=None):
        if not isinstance(name, str):
            raise TypeError("module.__init__() argument 'name' must be str, not " + type(name).__name__)
        self.__name__ = name
        self.__doc__ = doc
        self.__package__ = None
        self.__loader__ = None
        self.__spec__ = None
    def __repr__(self):
        # (round 83: `var` - a plain assignment here rebound the program's
        # own global `f` on the interpreter, where prelude functions see the
        # program's globals: repr() of a module made by inspect.getmodule
        # replaced the program's function f with its __file__)
        var f = getattr(self, "__file__", None)
        if f is not None:
            return "<module " + repr(self.__name__) + " from " + repr(f) + ">"
        return "<module " + repr(self.__name__) + ">"
    def __dir__(self):
        return sorted(list(self.__dict__))
_NyModuleType.__name__ = "module"
_NyModuleType.__qualname__ = "module"

def _ny_ann(thunk, text):
    # An annotation's value for __annotations__ (round 77): evaluated when
    # its statement runs, as Python does; one that cannot be evaluated yet - a
    # forward reference, a name of a module not imported - is kept as its
    # source text, as typing's ForwardRef would hold it, instead of failing a
    # program that never reads it.
    try:
        return thunk()
    except Exception:
        return text

def _ny_type_repr(t):
    # How typing shows a type inside list[...] / X | Y: a builtin by its
    # name, a class qualified by its module, None and ... as such.
    if t is None:
        return "None"
    if isinstance(t, _NyGenericAlias) or isinstance(t, _NyUnionType):
        return repr(t)
    if t == Ellipsis:
        return "..."
    if callable(t) and hasattr(t, "__name__"):
        var m = getattr(t, "__module__", "builtins")
        if m == "builtins" or m == None:
            return t.__name__
        return m + "." + t.__name__
    return repr(t)

class _NyGenericAlias:
    # list[int], dict[str, int], tuple[int, ...] (types.GenericAlias) and
    # what a class's __class_getitem__ may return (round 77).
    def __init__(self, origin, args):
        self.__origin__ = origin
        if not isinstance(args, tuple):
            args = (args,)
        self.__args__ = args
        self.__parameters__ = ()
    def __repr__(self):
        if len(self.__args__) == 0:
            return _ny_type_repr(self.__origin__) + "[()]"
        return _ny_type_repr(self.__origin__) + "[" + ", ".join([_ny_type_repr(a) for a in self.__args__]) + "]"
    def __call__(self, *args, **kw):
        return self.__origin__(*args, **kw)
    def __mro_entries__(self, bases):
        return (self.__origin__,)
    def __eq__(self, other):
        if not isinstance(other, _NyGenericAlias):
            return False
        return self.__origin__ == other.__origin__ and self.__args__ == other.__args__
    def __hash__(self):
        return hash(repr(self))
    def __or__(self, other):
        return _ny_union(self, other)
    def __ror__(self, other):
        return _ny_union(other, self)
    def __getitem__(self, item):
        return _NyGenericAlias(self.__origin__, item)

class _NyUnionType:
    # int | str, Foo | None (types.UnionType, round 77)
    def __init__(self, args):
        self.__args__ = args
    def __repr__(self):
        return " | ".join([_ny_type_repr(a) for a in self.__args__])
    def __or__(self, other):
        return _ny_union(self, other)
    def __ror__(self, other):
        return _ny_union(other, self)
    def __eq__(self, other):
        if not isinstance(other, _NyUnionType) or len(self.__args__) != len(other.__args__):
            return False
        for a in self.__args__:
            if a not in other.__args__:
                return False
        return True
    def __hash__(self):
        return hash(len(self.__args__))

def _ny_union(a, b):
    var args = []
    for x in [a, b]:
        if isinstance(x, _NyUnionType):
            for y in x.__args__:
                if y not in args:
                    args.append(y)
        elif x not in args:
            args.append(x)
    if len(args) == 1:
        return args[0]
    return _NyUnionType(tuple(args))

def _ny_star_shape(item, spec):
    # round 84: a comprehension's starred target (`for a, *b in it`): the
    # item reshaped to the target's names - its starred part a list, as
    # Python unpacks (spec: 1 for the starred element, 0 a name, a list a
    # nested tuple; Parser::starTargetSpec)
    var vals = None
    try:
        vals = list(item)
    except TypeError:
        raise TypeError("cannot unpack non-iterable " + type(item).__name__ + " object") from None
    var n = len(spec)
    var star = -1
    for i in range(n):
        if not isinstance(spec[i], list) and spec[i] == 1:
            star = i
    if star < 0:
        if len(vals) > n:
            raise ValueError("too many values to unpack (expected " + str(n) + ")")
        if len(vals) < n:
            raise ValueError("not enough values to unpack (expected " + str(n) + ", got " + str(len(vals)) + ")")
    else:
        if len(vals) < n - 1:
            raise ValueError("not enough values to unpack (expected at least " + str(n - 1) + ", got " + str(len(vals)) + ")")
        var after = n - 1 - star
        vals = vals[:star] + [vals[star:len(vals) - after]] + vals[len(vals) - after:]
    for i in range(n):
        if isinstance(spec[i], list):
            vals[i] = _ny_star_shape(vals[i], spec[i])
    return tuple(vals)

def _ny_star_iter(it, spec):
    for item in it:
        yield _ny_star_shape(item, spec)

def _ny_list_cat(*parts):
    # [*a, b, *c] (the parser hands the pieces here)
    var out = []
    for p in parts:
        for x in p:
            out.append(x)
    return out

def _ny_dict_merge(*parts):
    # {**a, k: v, **b}
    var out = {}
    for p in parts:
        if isinstance(p, dict):
            p = _ny_payload(p)    # a dict subclass's own items (round 77)
        if not hasattr(p, "keys"):
            raise TypeError("'" + type(p) + "' object is not a mapping")
        for k in p.keys():
            out[k] = p[k]
    return out

class slice:
    # slice(stop) / slice(start, stop[, step]): what a[i:j:k] hands an
    # object's __getitem__ / __setitem__ / __delitem__, and an index that
    # slices a list, str, tuple or bytes (round 77; slice() returned none)
    def __init__(self, *args):
        if len(args) == 0:
            raise TypeError("slice expected at least 1 argument, got 0")
        if len(args) > 3:
            raise TypeError("slice expected at most 3 arguments, got " + str(len(args)))
        if len(args) == 1:
            self.start = none
            self.stop = args[0]
            self.step = none
        else:
            self.start = args[0]
            self.stop = args[1]
            self.step = args[2] if len(args) == 3 else none

    def indices(self, length):
        var step = 1 if self.step is none else self.step
        if step == 0:
            raise ValueError("slice step cannot be zero")
        var lower = -1 if step < 0 else 0
        var upper = length - 1 if step < 0 else length
        var start = upper if step < 0 else lower
        if self.start is not none:
            start = self.start
            if start < 0:
                start = max(start + length, lower)
            else:
                start = min(start, upper)
        var stop = lower if step < 0 else upper
        if self.stop is not none:
            stop = self.stop
            if stop < 0:
                stop = max(stop + length, lower)
            else:
                stop = min(stop, upper)
        return (start, stop, step)

    def __eq__(self, other):
        return isinstance(other, slice) and [self.start, self.stop, self.step] == [other.start, other.stop, other.step]

    def __repr__(self):
        return "slice(" + repr(self.start) + ", " + repr(self.stop) + ", " + repr(self.step) + ")"

# ── range, dict views, mappingproxy (round 78) ────────────────────────────
# range() and d.keys()/values()/items() returned lists. They are Python's
# types now, on both engines. The engines make them natively (range() checks
# its arguments as CPython's range_new does; d.keys() makes a view holding
# the dict in _ny_mapping), and iterate them, take their len, test `in` and
# index a range of 64-bit ints without calling these methods: the methods
# are the general case (ints of any size, slices, set operations) and what
# Python code reaches directly (r.__len__(), KeysView mixins ...).
# _ny_range_iter(first, step, n) and _ny_dict_iter(d, kind, reverse) are the
# engines' native iterators (a range_iterator of 64-bit ints, none past
# them; a live dict_keyiterator / dict_valueiterator / dict_itemiterator).

def _ny_rlen(start, stop, step):
    # how many ints range(start, stop, step) holds (CPython's
    # compute_range_length, any size)
    if step > 0:
        if start < stop:
            return (stop - start - 1) // step + 1
        return 0
    if start > stop:
        return (start - stop - 1) // (0 - step) + 1
    return 0

def _ny_rhas(start, stop, step, x):
    # x in range(start, stop, step) for an int x, in O(1)
    if step > 0:
        if x < start or x >= stop:
            return False
    elif x > start or x <= stop:
        return False
    return (x - start) % step == 0

def _ny_rint(x):
    # what range's methods take arithmetically: an int or a bool, exactly
    return type(x) is int or type(x) is bool

def _ny_longrange(first, step, n):
    # iterating a range past 64-bit ints (CPython's longrange_iterator)
    var i = 0
    while i < n:
        yield first + i * step
        i += 1

class range:
    # range(stop) / range(start, stop[, step]): CPython's rangeobject.c - a
    # lazy, immutable sequence of ints of any size; start/stop/step are
    # read-only. Made by the engines (there is no __init__ to call).
    def __setattr__(self, name, value):
        if name == "start" or name == "stop" or name == "step":
            raise AttributeError("readonly attribute")
        raise AttributeError("'range' object has no attribute '" + name + "'")

    def __delattr__(self, name):
        if name == "start" or name == "stop" or name == "step":
            raise AttributeError("readonly attribute")
        raise AttributeError("'range' object has no attribute '" + name + "'")

    def __len__(self):
        var n = _ny_rlen(self.start, self.stop, self.step)
        if n > 9223372036854775807:
            raise OverflowError("Python int too large to convert to C ssize_t")
        return n

    def __bool__(self):
        return _ny_rlen(self.start, self.stop, self.step) != 0

    def __iter__(self):
        var n = _ny_rlen(self.start, self.stop, self.step)
        var it = _ny_range_iter(self.start, self.step, n)
        return _ny_longrange(self.start, self.step, n) if it is None else it

    def __reversed__(self):
        var n = _ny_rlen(self.start, self.stop, self.step)
        var first = self.start + (n - 1) * self.step
        var it = _ny_range_iter(first, 0 - self.step, n)
        return _ny_longrange(first, 0 - self.step, n) if it is None else it

    def __contains__(self, x):
        if _ny_rint(x):
            return _ny_rhas(self.start, self.stop, self.step, x)
        for v in self:
            if v is x or v == x:
                return True
        return False

    def index(self, x):
        if _ny_rint(x):
            if _ny_rhas(self.start, self.stop, self.step, x):
                return (x - self.start) // self.step
            raise ValueError(repr(x) + " is not in range")
        var i = 0
        for v in self:
            if v is x or v == x:
                return i
            i += 1
        raise ValueError("sequence.index(x): x not in sequence")

    def count(self, x):
        if _ny_rint(x):
            return 1 if _ny_rhas(self.start, self.stop, self.step, x) else 0
        var c = 0
        for v in self:
            if v is x or v == x:
                c += 1
        return c

    def __getitem__(self, i):
        var n = _ny_rlen(self.start, self.stop, self.step)
        if isinstance(i, slice):
            var t = i.indices(n)
            return range(self.start + t[0] * self.step, self.start + t[1] * self.step, self.step * t[2])
        if not _ny_rint(i):
            if hasattr(i, "__index__"):
                i = i.__index__()
            else:
                raise TypeError("range indices must be integers or slices, not " + type(i).__name__)
        if i < 0:
            i = i + n
        if i < 0 or i >= n:
            raise IndexError("range object index out of range")
        return self.start + i * self.step

    def __eq__(self, other):
        # by the sequence it describes: range(0) == range(2, 2)
        if not isinstance(other, range):
            return NotImplemented
        if self is other:
            return True
        var n = _ny_rlen(self.start, self.stop, self.step)
        if n != _ny_rlen(other.start, other.stop, other.step):
            return False
        if n == 0:
            return True
        if self.start != other.start:
            return False
        return n == 1 or self.step == other.step

    def __ne__(self, other):
        var r = self.__eq__(other)
        return r if r is NotImplemented else not r

    def __hash__(self):
        var n = _ny_rlen(self.start, self.stop, self.step)
        if n == 0:
            return hash((0, None, None))
        if n == 1:
            return hash((1, self.start, None))
        return hash((n, self.start, self.step))

    def __repr__(self):
        if self.step == 1:
            return "range(" + repr(self.start) + ", " + repr(self.stop) + ")"
        return "range(" + repr(self.start) + ", " + repr(self.stop) + ", " + repr(self.step) + ")"

    def __reduce__(self):
        return (range, (self.start, self.stop, self.step))

def _ny_view_contains(v, x):
    # x in a dict view (dict_items: a (key, value) pair whose key is there
    # with an equal value)
    var d = v._ny_mapping
    if isinstance(v, dict_items):
        if not isinstance(x, tuple) or len(x) != 2:
            return False
        if x[0] not in d:
            return False
        var found = d[x[0]]
        return found is x[1] or found == x[1]
    return x in d

def _ny_view_setlike(o):
    return isinstance(o, (set, frozenset, dict_keys, dict_items))

def _ny_view_all_in(a, b):
    for x in a:
        if x not in b:
            return False
    return True

def _ny_view_cmp(v, other, op):
    # dictview_richcompare: views of keys and items compare as sets with
    # sets and with each other
    if not _ny_view_setlike(other):
        return NotImplemented
    var a = len(v)
    var b = len(other)
    if op == "==":
        return a == b and _ny_view_all_in(v, other)
    if op == "!=":
        return not (a == b and _ny_view_all_in(v, other))
    if op == "<":
        return a < b and _ny_view_all_in(v, other)
    if op == "<=":
        return a <= b and _ny_view_all_in(v, other)
    if op == ">":
        return a > b and _ny_view_all_in(other, v)
    return a >= b and _ny_view_all_in(other, v)

def _ny_view_and(v, other):
    # elements of other that are in the view (CPython's _PyDictView_Intersect)
    var out = set()
    for x in other:
        if _ny_view_contains(v, x):
            out.add(x)
    return out

def _ny_view_isdisjoint(v, other):
    for x in other:
        if _ny_view_contains(v, x):
            return False
    return True

class _NyDictSetView:
    # what dict_keys and dict_items share: the Set operations (a set
    # results, as in CPython), comparisons with sets, isdisjoint
    __hash__ = None
    def __len__(self):
        return len(self._ny_mapping)
    def __contains__(self, x):
        return _ny_view_contains(self, x)
    def __eq__(self, other):
        return _ny_view_cmp(self, other, "==")
    def __ne__(self, other):
        return _ny_view_cmp(self, other, "!=")
    def __lt__(self, other):
        return _ny_view_cmp(self, other, "<")
    def __le__(self, other):
        return _ny_view_cmp(self, other, "<=")
    def __gt__(self, other):
        return _ny_view_cmp(self, other, ">")
    def __ge__(self, other):
        return _ny_view_cmp(self, other, ">=")
    def __and__(self, other):
        return _ny_view_and(self, other)
    def __rand__(self, other):
        return _ny_view_and(self, other)
    def __or__(self, other):
        var s = set(self)
        s.update(other)
        return s
    def __ror__(self, other):
        var s = set(other)
        s.update(self)
        return s
    def __sub__(self, other):
        var s = set(self)
        s.difference_update(other)
        return s
    def __rsub__(self, other):
        var s = set(other)
        s.difference_update(self)
        return s
    def __xor__(self, other):
        var s = set(self)
        s.symmetric_difference_update(other)
        return s
    def __rxor__(self, other):
        var s = set(other)
        s.symmetric_difference_update(self)
        return s
    def isdisjoint(self, other):
        return _ny_view_isdisjoint(self, other)
    @property
    def mapping(self):
        return mappingproxy(self._ny_mapping)

class dict_keys(_NyDictSetView):
    # d.keys(): a live view of the dict's keys
    def __iter__(self):
        return _ny_dict_iter(self._ny_mapping, 0, False)
    def __reversed__(self):
        return _ny_dict_iter(self._ny_mapping, 0, True)
    def __repr__(self):
        return "dict_keys(" + repr(list(self)) + ")"

class dict_items(_NyDictSetView):
    # d.items(): a live view of (key, value) pairs
    def __iter__(self):
        return _ny_dict_iter(self._ny_mapping, 2, False)
    def __reversed__(self):
        return _ny_dict_iter(self._ny_mapping, 2, True)
    def __repr__(self):
        return "dict_items(" + repr(list(self)) + ")"

class dict_values:
    # d.values(): a live view of the values (not a Set; == is identity)
    def __len__(self):
        return len(self._ny_mapping)
    def __iter__(self):
        return _ny_dict_iter(self._ny_mapping, 1, False)
    def __reversed__(self):
        return _ny_dict_iter(self._ny_mapping, 1, True)
    def __repr__(self):
        return "dict_values(" + repr(list(self)) + ")"
    @property
    def mapping(self):
        return mappingproxy(self._ny_mapping)

class mappingproxy:
    # types.MappingProxyType (lib/types.ny names it): a read-only, live view
    # of a mapping - a dict view's .mapping
    def __init__(self, mapping):
        if not (isinstance(mapping, dict) or (hasattr(mapping, "keys") and hasattr(mapping, "__getitem__"))) or isinstance(mapping, (list, tuple, str)):
            raise TypeError("mappingproxy() argument must be a mapping, not " + type(mapping).__name__)
        object.__setattr__(self, "_ny_mapping", mapping)
    def __getitem__(self, key):
        return self._ny_mapping[key]
    def __setitem__(self, key, value):
        raise TypeError("'mappingproxy' object does not support item assignment")
    def __delitem__(self, key):
        raise TypeError("'mappingproxy' object does not support item deletion")
    def __setattr__(self, name, value):
        raise AttributeError("'mappingproxy' object has no attribute '" + name + "'")
    def __delattr__(self, name):
        raise AttributeError("'mappingproxy' object has no attribute '" + name + "'")
    def get(self, key, default=None):
        var m = self._ny_mapping
        if isinstance(m, dict):
            return m[key] if key in m else default
        return m.get(key, default)
    def keys(self):
        return self._ny_mapping.keys()
    def values(self):
        return self._ny_mapping.values()
    def items(self):
        return self._ny_mapping.items()
    def copy(self):
        var m = self._ny_mapping
        if isinstance(m, dict):
            return dict(m)
        return m.copy()
    def __len__(self):
        return len(self._ny_mapping)
    def __contains__(self, key):
        return key in self._ny_mapping
    def __iter__(self):
        return iter(self._ny_mapping)
    def __reversed__(self):
        return reversed(self._ny_mapping)
    def __eq__(self, other):
        if isinstance(other, mappingproxy):
            other = other._ny_mapping
        return self._ny_mapping == other
    def __ne__(self, other):
        return not self.__eq__(other)
    def __or__(self, other):
        if isinstance(other, mappingproxy):
            other = other._ny_mapping
        var d = dict(self._ny_mapping)
        for k in list(other.keys()):
            d[k] = other[k]
        return d
    def __ror__(self, other):
        var d = dict(other)
        for k in list(self._ny_mapping.keys()):
            d[k] = self._ny_mapping[k]
        return d
    def __ior__(self, other):
        raise TypeError("'|=' is not supported by mappingproxy; use '|' instead")
    def __hash__(self):
        return hash(tuple(sorted([repr(k) for k in self._ny_mapping.keys()])))
    def __repr__(self):
        return "mappingproxy(" + repr(self._ny_mapping) + ")"
    def __str__(self):
        return str(self._ny_mapping)

class _NyCode:
    # what compile(source, filename, mode) returns; eval() / exec() run it.
    # _ny_pyrule (round 85): compiled with Python's binding rule (compile()
    # called from Python-language source - lib/ast.ny's for a tree)
    def __init__(self, source, filename, mode, pyrule=false):
        self.source = source
        self.co_filename = filename
        self.mode = mode
        self.co_name = "<module>"
        self._ny_pyrule = pyrule

    def __repr__(self):
        return "<code object <module>, file \"" + self.co_filename + "\", line 1>"

class _NyFuncCode:
    # f.__code__ (round 77): CPython's code-object attributes, made from
    # _ny_fn_info(f). co_varnames holds the parameters (args, keyword-only,
    # *args, **kwargs, as CPython orders them), not the other locals.
    def __init__(self, info):
        self.co_name = info[0]
        self.co_qualname = info[1]
        self.co_filename = info[5]
        self.co_firstlineno = info[6]
        var pos = []
        var kwonly = []
        var star = []
        var npos = 0
        var flags = 3
        for p in info[3]:
            if p[1] == 0:
                npos = npos + 1
            if p[1] <= 1:
                pos.append(p[0])
            elif p[1] == 3:
                kwonly.append(p[0])
            elif p[1] == 2:
                star.insert(0, p[0])
                flags = flags | 4
            else:
                star.append(p[0])
                flags = flags | 8
        self.co_argcount = len(pos)
        self.co_posonlyargcount = npos
        self.co_kwonlyargcount = len(kwonly)
        self.co_varnames = tuple(pos + kwonly + star)
        self.co_nlocals = len(self.co_varnames)
        if "<locals>" in info[1]:
            flags = flags | 16
        var kind = info[4]
        if kind & 1:
            flags = flags | 32
        if kind & 2:
            flags = flags | 128
        if kind & 4:
            flags = flags | 512
        self.co_flags = flags
        self.co_freevars = ()
        self.co_cellvars = ()
    def __repr__(self):
        return "<code object " + self.co_name + ", file \"" + self.co_filename + "\", line " + str(self.co_firstlineno) + ">"

# (round 86) code.replace and types.FunctionType(code, globals, ...): the
# "audit" chunk's (src/NyPreludeAudit.cpp), loaded on first use
def _ny_code_replace(self, **changes):
    _ny_load_chunk("audit")
    return _ny_code_replace(self, **changes)
_NyCode.replace = _ny_code_replace
_NyFuncCode.replace = _ny_code_replace

def _ny_function_new(*args, **kw):
    _ny_load_chunk("audit")
    return _ny_function_new(*args, **kw)

_ny_code_cache = {}
def _ny_code_of(info):
    # one code object per function's code (round 81: f.__code__ is
    # frame.f_code, as in CPython - trace functions compare them); info[7]
    # is the code's identity, checked against what it describes in case it
    # was reused
    if len(info) > 7:
        var k = info[7]
        var c = _ny_code_cache.get(k)
        if c is not None and c.co_name == info[0] and c.co_firstlineno == info[6] and c.co_filename == info[5] and c.co_qualname == info[1]:
            return c
        c = _NyFuncCode(info)
        _ny_code_cache[k] = c
        return c
    return _NyFuncCode(info)

def _ny_fn_attr(f, attr):
    # A function's __defaults__, __kwdefaults__, __code__, __qualname__,
    # __module__, __globals__ (round 77; both engines read them here).
    if attr == "__globals__":
        return _ny_fn_globals(f)
    var info = _ny_fn_info(f)
    if attr == "__qualname__":
        return info[1]
    if attr == "__module__":
        return info[2]
    if attr == "__code__":
        return _ny_code_of(info)
    if attr == "__defaults__":
        var d = [p[3] for p in info[3] if p[1] <= 1 and p[2]]
        return tuple(d) if len(d) > 0 else None
    var kd = {}
    for p in info[3]:
        if p[1] == 3 and p[2]:
            kd[p[0]] = p[3]
    return kd if len(kd) > 0 else None

class _NyNotImplementedType:
    # What a binary or comparison dunder returns for an operand it does not
    # handle: the other operand's reflected method is tried next, then
    # TypeError (== falls back to identity) - round 77.
    def __repr__(self):
        return "NotImplemented"
    def __reduce__(self):
        return "NotImplemented"
NotImplemented = _NyNotImplementedType()

class object:
    @classmethod
    def __subclasses__(cls):
        # the classes naming cls as a base, in the order they were made
        return _ny_subclasses(cls)
    @classmethod
    def mro(cls):
        return list(cls.__mro__)
    def __new__(cls, *args, **kw):
        # object.__new__(cls) / super().__new__(cls): a bare instance
        # (round 77; a class's own __new__ runs before __init__); extra
        # arguments are CPython's object_new errors (round 81)
        if args or kw:
            _ny_ctor_check(cls, True)
        return _ny_object_new(cls)
    @classmethod
    def __init_subclass__(cls, **kw):
        # the end of every super().__init_subclass__(**kw) chain
        if len(kw) > 0:
            raise TypeError(cls.__name__ + ".__init_subclass__() takes no keyword arguments")
    @classmethod
    def __subclasshook__(cls, *args):
        # Abstract classes can override this to customize issubclass()
        # (lib/abc.ny asks it first); object's declines (round 77)
        return NotImplemented
    # the root of the class tree (round 77; `object` was undefined):
    # object(), class C(object), object.__init__(self) in a super() chain,
    # and the plain attribute store a __setattr__ hands on to
    # (object.__setattr__(self, k, v) / super().__setattr__(k, v))
    def __init__(self, *args, **kwargs):
        # extra arguments are CPython's object_init errors (round 81)
        if args or kwargs:
            _ny_ctor_check(type(self), False)

    def __setattr__(self, name, value):
        _ny_setattr_raw(self, name, value)

    def __delattr__(self, name):
        _ny_delattr_raw(self, name)

    # the normal attribute lookup, which a class's own __getattribute__
    # hands on to (round 77); it raises AttributeError, and __getattr__ is
    # the engines' to call after it
    def __getattribute__(self, name):
        return _ny_getattr_raw(self, name)

    # the pickle and copy protocol (round 79): lib/copyreg.ny does what
    # CPython's typeobject.c does - reduce_newobj for protocol 2 and up,
    # copyreg._reduce_ex below it, object_getstate (the attributes, the
    # slots as a (dict, slots) pair)
    def __reduce_ex__(self, protocol):
        import copyreg
        return copyreg._ny_reduce_ex(self, protocol)

    def __reduce__(self):
        import copyreg
        return copyreg._reduce_ex(self, 0)

    def __getstate__(self):
        import copyreg
        return copyreg._ny_getstate(self)

def _ny_ctor_check(cls, is_new):
    # (round 81) object.__new__(cls, *args) / object.__init__(self, *args)
    # given arguments: CPython's object_new / object_init - an error unless
    # the class overrides the other one (a builtin type or exception along
    # the MRO takes its own arguments)
    var own_init = False
    var own_new = False
    for k in cls.__mro__:
        if k is object:
            break
        if getattr(k, "__module__", None) == "builtins":
            return None
        var d = k.__dict__
        if "__init__" in d or "init" in d:
            own_init = True
        if "__new__" in d:
            own_new = True
    if is_new:
        if own_new:
            raise TypeError("object.__new__() takes exactly one argument (the type to instantiate)")
        if not own_init:
            raise TypeError(cls.__name__ + "() takes no arguments")
    else:
        if own_init:
            raise TypeError("object.__init__() takes exactly one argument (the instance to initialize)")
        if not own_new:
            raise TypeError(cls.__name__ + "() takes no arguments")
    return None

class _NyObjectExtra:
    # The rest of object's methods (round 80). They cannot be in object's
    # class body: the engines' protocol dispatch would then find __eq__,
    # __hash__, __repr__ ... in every class (each MRO ends in object) and run
    # them for every ==, hash() and repr(). They are read only where nothing
    # in a class's MRO has the name (the engines' objectMember /
    # object_member): P.__eq__, object.__repr__(x), super().__hash__(),
    # hasattr(p, "__ne__").
    def __eq__(self, other):
        if self is other:
            return True
        return NotImplemented
    def __ne__(self, other):
        var r = type(self).__eq__(self, other)
        if r is NotImplemented:
            return r
        return not r
    def __lt__(self, other):
        return NotImplemented
    def __le__(self, other):
        return NotImplemented
    def __gt__(self, other):
        return NotImplemented
    def __ge__(self, other):
        return NotImplemented
    def __hash__(self):
        # the identity hash hash() gives an object whose class defines none
        if getattr(type(self), "__hash__", None) is _ny_object_extra_hash:
            return hash(self)
        return id(self) >> 4
    def __repr__(self):
        var t = type(self)
        var m = getattr(t, "__module__", None)
        var q = getattr(t, "__qualname__", t.__name__)
        if m is not None and m != "builtins":
            q = m + "." + q
        return "<" + q + " object at " + hex(id(self)) + ">"
    def __str__(self):
        return type(self).__repr__(self)
    def __format__(self, format_spec):
        if not isinstance(format_spec, str):
            raise TypeError("__format__() argument must be str, not " + type(format_spec).__name__)
        if format_spec != "":
            raise TypeError("unsupported format string passed to " + type(self).__name__ + ".__format__")
        return str(self)
    def __sizeof__(self):
        return 16 if type(self) is object else 24
    def __dir__(self):
        return dir(self)
_ny_object_extra_hash = _NyObjectExtra.__hash__

# sys.audit / sys.addaudithook (round 84, PEP 578): the hooks, called in
# the order they were added for every event; the engines raise exec,
# compile, import and builtins.input (only once a hook exists:
# nyrt::audit_on), open() raises open, and the library modules their own.
_ny_audit_hooks = []

def _ny_audit_fire(event, args):
    if event == "import" and len(args) == 2:
        var sm = _ny_sys_ref[0]
        args = args + (getattr(sm, "path", None), getattr(sm, "meta_path", None), getattr(sm, "path_hooks", None))
    for h in list(_ny_audit_hooks):
        h(event, args)

def _ny_sys_audit(*args):
    # sys.audit(event, *args) - (round 86) nothing at all, not even the
    # event's type checked, while no hook exists, as CPython's
    if not args:
        raise TypeError("audit() missing 1 required positional argument: 'event'")
    if _ny_audit_hooks:
        var event = args[0]
        if not isinstance(event, str):
            raise TypeError("expected str for argument 'event', not " + type(event).__name__)
        _ny_audit_fire(event, args[1:])

def _ny_sys_addaudithook(hook):
    # the existing hooks hear of it first; one raising a RuntimeError keeps
    # the new hook out (silently), as CPython's PySys_AddAuditHook
    try:
        _ny_sys_audit("sys.addaudithook")
    except RuntimeError:
        return None
    if not _ny_audit_hooks:
        _ny_load_chunk("audit")   # (round 86) what the events need: src/NyPreludeAudit.cpp
    _ny_audit_hooks.append(hook)
    _ny_audit_enable()

def _ny_audit_startup(policy, log):
    # (round 86) nython --audit-policy FILE / --audit-log FILE (lib/nyaudit.ny)
    import nyaudit
    nyaudit._cli_install(policy, log)

def _ny_site_startup():
    # (round 87) a site-packages directory holds .pth files or a
    # sitecustomize / usercustomize module (nyrt::SiteState): lib/site.ny
    # (its main(), run when it is imported) processes them before the
    # program runs, as CPython's startup imports site; an error is reported
    # and the program still runs
    try:
        import site
    except Exception as e:
        _ny_stderr.write("Error in site startup: " + _ny_format_exc(e, True, [], {}))

def _ny_builtins_module():
    # round 84: the builtins module (lib/builtins.ny) - sys.modules["builtins"],
    # a builtin function's __self__
    import builtins
    return builtins

def _ny_seal_cmodule(mod, names):
    # round 84: the functions CPython implements in C are builtins here too.
    # The engines call this when a module named in include/NyBuiltinFns.hpp
    # has run, with that module's names: a plain function the module binds
    # under one is marked (_ny_mark_builtin: not bound through a class, of
    # type builtin_function_or_method, <built-in function name>) and, when
    # it was written under a private name (_ny_os_fspath), takes the public one
    var ft = type(_ny_seal_cmodule)
    for n in names.split(" "):
        var f = getattr(mod, n, None)
        if type(f) is not ft:
            continue
        if f.__name__ != n and f.__name__.startswith("_"):
            f.__name__ = n
            f.__qualname__ = n
        _ny_mark_builtin(f)

_ny_docs_mod = [None, False]
def _ny_builtin_doc(key):
    # round 84: a builtin's docstring - CPython's, from lib/_nydocs.ny
    # (imported the first time one is asked for); None when it has none
    if not _ny_docs_mod[1]:
        _ny_docs_mod[1] = True
        try:
            import _nydocs
            _ny_docs_mod[0] = _nydocs
        except ImportError:
            pass
    var m = _ny_docs_mod[0]
    if m is None:
        return None
    return m.doc(key)

class _NyExcExtra:
    # BaseException's own __init__, __str__ and __repr__ read as values
    # (round 84): `e.__str__()`, `ValueError.__init__`, `getattr(e,
    # "__repr__")` raised AttributeError. Read, as _NyObjectExtra's, only
    # where nothing in the exception's class lookup has the name; str(),
    # repr() and constructors still go to the engines directly. They give
    # the engine's own results, whatever a subclass overrides.
    def __init__(self, *args, **kwargs):
        _ny_exc_init(self, args, kwargs)
    def __str__(self):
        return _ny_exc_str(self)
    def __repr__(self):
        return _ny_exc_repr(self)

def _ny_complex_part(x):
    # a component as Python shows it: 2.0 -> 2, 1.5 -> 1.5
    var t = repr(float(x))
    if t.endswith(".0"):
        t = t[0:len(t) - 2]
    return t

def _ny_as_complex(o):
    if isinstance(o, complex):
        return o
    if isinstance(o, "bool") or isinstance(o, "int") or isinstance(o, "float"):
        return complex(o, 0)
    return none

class complex:
    # complex(real=0, imag=0), complex("1+2j"); the literal 2j is complex(0, 2.0)
    # (round 77; complex() and 2j read none)
    def __init__(self, real=0, imag=0):
        if isinstance(real, "str"):
            var c = complex._parse(real)
            real = c[0]
            imag = c[1]
        elif isinstance(real, complex):
            var r0 = real
            real = r0.real
            imag = r0.imag + imag
        self.real = float(real)
        self.imag = float(imag)

    @staticmethod
    def _parse(text):
        var t = text.strip().replace(" ", "")
        if t.startswith("(") and t.endswith(")"):
            t = t[1:len(t) - 1]
        if t == "":
            raise ValueError("complex() arg is a malformed string")
        if not (t.endswith("j") or t.endswith("J")):
            return [float(t), 0.0]
        var body = t[0:len(t) - 1]
        var split = -1
        for i in range(len(body) - 1, 0, -1):
            if (body[i] == "+" or body[i] == "-") and body[i - 1] != "e" and body[i - 1] != "E":
                split = i
                break
        try:
            if split < 0:
                var im = 1.0 if body == "" or body == "+" else (-1.0 if body == "-" else float(body))
                return [0.0, im]
            var re = float(body[0:split])
            var ims = body[split:]
            var im2 = 1.0 if ims == "+" else (-1.0 if ims == "-" else float(ims))
            return [re, im2]
        except ValueError:
            raise ValueError("complex() arg is a malformed string")

    # An operand of a number type of its own (fractions.Fraction, ...):
    # its reflected method, as Python's protocol does when complex's own
    # declines (NotImplemented) - 2j + Fraction(1, 2) raised TypeError.
    def __add__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            if not isinstance(o, "str") and hasattr(o, "__radd__"):
                return o.__radd__(self)
            raise TypeError("unsupported operand type(s) for +: 'complex' and '" + type(o) + "'")
        return complex(self.real + c.real, self.imag + c.imag)

    def __radd__(self, o):
        return self.__add__(o)

    def __sub__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            if not isinstance(o, "str") and hasattr(o, "__rsub__"):
                return o.__rsub__(self)
            raise TypeError("unsupported operand type(s) for -: 'complex' and '" + type(o) + "'")
        return complex(self.real - c.real, self.imag - c.imag)

    def __rsub__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            raise TypeError("unsupported operand type(s) for -: '" + type(o) + "' and 'complex'")
        return complex(c.real - self.real, c.imag - self.imag)

    def __mul__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            if not isinstance(o, "str") and hasattr(o, "__rmul__"):
                return o.__rmul__(self)
            raise TypeError("unsupported operand type(s) for *: 'complex' and '" + type(o) + "'")
        return complex(self.real * c.real - self.imag * c.imag, self.real * c.imag + self.imag * c.real)

    def __rmul__(self, o):
        return self.__mul__(o)

    def __truediv__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            if not isinstance(o, "str") and hasattr(o, "__rtruediv__"):
                return o.__rtruediv__(self)
            raise TypeError("unsupported operand type(s) for /: 'complex' and '" + type(o) + "'")
        var d = c.real * c.real + c.imag * c.imag
        if d == 0:
            raise ZeroDivisionError("complex division by zero")
        return complex((self.real * c.real + self.imag * c.imag) / d, (self.imag * c.real - self.real * c.imag) / d)

    def __rtruediv__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            raise TypeError("unsupported operand type(s) for /: '" + type(o) + "' and 'complex'")
        return c.__truediv__(self)

    def __pow__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            if not isinstance(o, "str") and hasattr(o, "__rpow__"):
                return o.__rpow__(self)
            raise TypeError("unsupported operand type(s) for ** or pow(): 'complex' and '" + type(o) + "'")
        if c.imag == 0 and c.real == int(c.real) and abs(c.real) <= 1000:
            # an integer power: exact repeated squaring
            var n = int(c.real)
            var result = complex(1, 0)
            var base = complex(self.real, self.imag) if n >= 0 else complex(1, 0) / self
            n = abs(n)
            while n > 0:
                if n % 2 == 1:
                    result = result * base
                base = base * base
                n = n // 2
            return result
        if self.real == 0 and self.imag == 0:
            if c.real == 0 and c.imag == 0:
                return complex(1, 0)
            return complex(0, 0)
        var r = sqrt(self.real * self.real + self.imag * self.imag)
        var th = atan2(self.imag, self.real)
        var lr = log(r)
        var mag = exp(c.real * lr - c.imag * th)
        var ang = c.imag * lr + c.real * th
        return complex(mag * cos(ang), mag * sin(ang))

    def __rpow__(self, o):
        var c = _ny_as_complex(o)
        if c is none:
            raise TypeError("unsupported operand type(s) for ** or pow(): '" + type(o) + "' and 'complex'")
        return c.__pow__(self)

    def __neg__(self):
        return complex(-self.real, -self.imag)

    def __pos__(self):
        return complex(self.real, self.imag)

    def __abs__(self):
        return sqrt(self.real * self.real + self.imag * self.imag)

    def __bool__(self):
        return self.real != 0 or self.imag != 0

    def __eq__(self, o):
        var c = _ny_as_complex(o)
        return c is not none and self.real == c.real and self.imag == c.imag

    def __ne__(self, o):
        return not self.__eq__(o)

    def __hash__(self):
        if self.imag == 0:
            return hash(self.real)
        return hash(repr(self))

    def conjugate(self):
        return complex(self.real, -self.imag)

    def __repr__(self):
        if self.real == 0 and repr(self.real) == "0.0":
            return _ny_complex_part(self.imag) + "j"
        var im = _ny_complex_part(self.imag)
        if not (im.startswith("-") or im == "nan"):
            im = "+" + im
        return "(" + _ny_complex_part(self.real) + im + "j)"

    def __str__(self):
        return self.__repr__()

def _ny_doc_lines(doc, indent):
    if doc is none:
        return []
    var lines = doc.split("\n")
    # the docstring's own indentation, as inspect.cleandoc removes it
    var margin = none
    for ln in lines[1:]:
        var st = ln.lstrip()
        if st != "":
            var m = len(ln) - len(st)
            if margin is none or m < margin:
                margin = m
    var out = [indent + lines[0].strip()]
    for ln in lines[1:]:
        out.append(((indent + ln[margin:]) if margin is not none else indent + ln.strip()).rstrip())
    while len(out) > 0 and out[len(out) - 1].strip() == "":
        out.pop()
    return out

def help(obj=none):
    # help(x): what x is, its docstring, and for a class its methods' (round
    # 77; help() did nothing)
    if obj is none:
        print("Type help(object) for help about object; dir(object) lists its names.")
        return none
    var kind = type(obj)
    var name = getattr(obj, "__name__", none)
    if name is none:
        name = type(obj)
    var out = []
    if kind == "class":
        out.append("Help on class " + name + ":")
        out.append("")
        out.append("class " + name)
        for ln in _ny_doc_lines(getattr(obj, "__doc__", none), " |  "):
            out.append(ln)
        var methods = [m for m in dir(obj) if not m.startswith("_") or m == "__init__"]
        if len(methods) > 0:
            out.append(" |")
            out.append(" |  Methods defined here:")
        for m in methods:
            var member = getattr(obj, m, none)
            if callable(member):
                out.append(" |")
                out.append(" |  " + m + "(...)")
                for ln in _ny_doc_lines(getattr(member, "__doc__", none), " |      "):
                    out.append(ln)
    elif kind == "function" or kind == "builtin":
        out.append("Help on " + ("built-in function " if kind == "builtin" else "function ") + name + ":")
        out.append("")
        out.append(name + "(...)")
        for ln in _ny_doc_lines(getattr(obj, "__doc__", none), "    "):
            out.append(ln)
    else:
        var cls_doc = getattr(obj, "__doc__", none)
        out.append("Help on " + type(obj) + " object:")
        out.append("")
        for ln in _ny_doc_lines(cls_doc, "    "):
            out.append(ln)
        out.append("    " + ", ".join([n for n in dir(obj) if not n.startswith("_")]))
    print("\n".join(out))
    return none

def exit(code=none):
    # Python's: SystemExit, so finally blocks run and `except SystemExit`
    # can stop it (round 77; it ended the process on the spot). The program
    # ends with the code when nothing catches it.
    raise SystemExit(code)

def quit(code=none):
    raise SystemExit(code)

# compile(tree, filename, mode) and compile(source, filename, mode,
# ast.PyCF_ONLY_AST): both engines' compile() hands these to lib/ast.ny
# (round 83)
def _ny_compile_ast(source, filename, mode, flags):
    import ast
    return ast._ny_compile(source, filename, mode, flags)

# str.encode / bytes.decode / str(b, enc, errors) with a codec or an error
# handler only lib/codecs.ny's registry knows (round 80: both engines call
# these when NyCodecs.hpp has no such codec or handler)
def _ny_codec_encode(s, encoding, errors):
    import codecs
    return codecs._ny_text_encode(s, encoding, errors)

def _ny_codec_decode(b, encoding, errors):
    import codecs
    return codecs._ny_text_decode(b, encoding, errors)

def _ny_open_flags(mode):
    # the os.open flags a mode means (the "open" audit event's third value,
    # as CPython's _io computes them): O_RDONLY 0, O_WRONLY 1, O_RDWR 2,
    # O_CREAT 64, O_EXCL 128, O_TRUNC 512, O_APPEND 1024 (Linux's values)
    var f = 0
    var plus = "+" in mode
    if "x" in mode:
        f = 128 | 64 | (2 if plus else 1)
    elif "w" in mode:
        f = 64 | 512 | (2 if plus else 1)
    elif "a" in mode:
        f = 1024 | 64 | (2 if plus else 1)
    else:
        f = 2 if plus else 0
    return f | 524288   # O_CLOEXEC, as CPython opens every file

def _ny_open_fd(path, mode, encoding, newline, closefd, opener):
    # open(fd) and open(path, opener=f) (round 80; the VM's open calls this
    # for them too)
    if isinstance(path, int) and not isinstance(path, bool):
        # a file descriptor: its own file object, which closes the
        # descriptor unless closefd is false
        var fd = path if closefd else _ny_os_call("dup", path)
        var ff = NythonFile(path, mode, _ny_os_call("fdopen", fd, mode), encoding if encoding is not none else "utf-8")
        ff.newline = newline
        return ff
    # open(path, mode, opener=f): f(path, flags) gives the descriptor
    var flags = 0
    var plus = "+" in mode
    var oc = {}
    for kv in _ny_os_call("constants"):
        oc[kv[0]] = kv[1]
    if "r" in mode:
        flags = oc["O_RDWR"] if plus else oc["O_RDONLY"]
    else:
        flags = oc["O_RDWR"] if plus else oc["O_WRONLY"]
        flags = flags | oc["O_CREAT"]
        if "w" in mode:
            flags = flags | oc["O_TRUNC"]
        if "a" in mode:
            flags = flags | oc["O_APPEND"]
        if "x" in mode:
            flags = flags | oc["O_EXCL"]
    if "b" in mode and "O_BINARY" in oc:
        flags = flags | oc["O_BINARY"]
    var ofd = opener(path, flags)
    var fo = NythonFile(path, mode, _ny_os_call("fdopen", ofd, mode), encoding if encoding is not none else "utf-8")
    fo.newline = newline
    return fo

def open(path, mode="r", buffering=-1, encoding="utf-8", errors=none, newline=none, closefd=true, opener=none):
    # Python's parameters in Python's order (round 77: encoding was third)
    if hasattr(path, "__fspath__"):
        path = path.__fspath__()
    if _ny_audit_hooks:
        _ny_audit_open(path, mode)   # round 84, as CPython's (round 86: the "audit" chunk's)
    if (isinstance(path, int) and not isinstance(path, bool)) or opener is not none:
        return _ny_open_fd(path, mode, encoding, newline, closefd, opener)
    if "b" in mode and encoding != "utf-8" and encoding is not none:
        raise ValueError("binary mode doesn't take an encoding argument")
    if newline is not none and not (newline == "" or newline == "\n" or newline == "\r" or newline == "\r\n"):
        raise ValueError("illegal newline value: " + repr(newline))
    if "b" in mode and newline is not none:
        raise ValueError("binary mode doesn't take a newline argument")
    # an explicit newline= means no platform translation underneath: the
    # handle is opened raw and NythonFile applies newline itself (csv's
    # open(..., newline="") wrote \r\r\n on Windows)
    var native_mode = mode if (newline is none or "b" in mode) else mode + "b"
    var f = NythonFile(path, mode, file_open_or_raise(path, native_mode), encoding if encoding is not none else "utf-8")
    f.newline = newline
    return f

class _NyAsyncCM:
    def __init__(self, m):
        self.m = m

    def __enter__(self):
        if hasattr(self.m, "__aenter__"):
            return async_await(self.m.__aenter__())
        if hasattr(self.m, "__enter__"):
            return self.m.__enter__()
        return self.m

    def __exit__(self, t=none, v=none, tb=none):
        if hasattr(self.m, "__aexit__"):
            return async_await(self.m.__aexit__(t, v, tb))
        if hasattr(self.m, "__exit__"):
            return self.m.__exit__(t, v, tb)
        return false

def _ny_async_cm(m):
    return _NyAsyncCM(m)

# ── coroutine objects (round 78) ─────────────────────────────────────────
# Calling an `async def` gives a _NyCoroutine (Python's `coroutine`): the
# coroutine the runtime runs is behind _ny_coro_h - its handle, which await,
# create_task, gather and asyncio take from the object without calling
# anything - and it can be driven by hand, as a coroutine runner drives one:
# send / throw / close (async_coro_drive). An await of an object whose
# __await__ is a generator runs that generator (_ny_drive_await): its yields
# go to whoever drives the coroutine by hand, or, in a task, a bare yield
# gives the other tasks a turn and anything else is awaited. A coroutine
# that is never awaited warns through warnings when it goes, as CPython's
# does: "RuntimeWarning: coroutine 'f' was never awaited".
def _ny_raise_from(r):
    # what async_coro_drive answered: [0, yielded] / [1, result] / [2, exc]
    if r[0] == 0:
        return r[1]
    if r[0] == 2:
        raise r[1]
    if r[1] is None:
        raise StopIteration()
    raise StopIteration(r[1])

def _ny_exc_of(typ, val=None, tb=None):
    # throw()'s arguments as one exception: throw(E), throw(E, v), throw(e)
    var exc = typ
    if not isinstance(typ, BaseException):
        if val is None:
            exc = typ()
        elif isinstance(val, BaseException):
            exc = val
        else:
            exc = typ(val)
    if tb is not None:
        exc = exc.with_traceback(tb)
    return exc

class _NyCoroDriver:
    # send / throw / close / __next__ over a coroutine handle: the
    # coroutine objects, their __await__ wrappers and the async generators'
    # asend / athrow / aclose awaitables
    _ny_coro_h = 0

    def send(self, value):
        return _ny_raise_from(async_coro_drive(self._ny_coro_h, 0, value))

    def throw(self, typ, val=None, tb=None):
        return _ny_raise_from(async_coro_drive(self._ny_coro_h, 1, _ny_exc_of(typ, val, tb)))

    def close(self):
        async_coro_drive(self._ny_coro_h, 2, None)

    def __next__(self):
        return self.send(None)

    def __iter__(self):
        return self

class _NyCoroutine(_NyCoroDriver):
    # _NyCoroutine(handle, function, name, qualname): the parser's
    # rewriting of an async def makes one per call (Parser.cpp)
    def __init__(self, h, fn, name, qualname):
        self._ny_coro_h = h
        self._ny_fn = fn
        self._ny_frame0 = None
        self.__name__ = name
        self.__qualname__ = qualname

    def __await__(self):
        return _NyCoroWrapper(self)

    @property
    def cr_code(self):
        if _ny_audit_hooks:
            _ny_audit_fire("object.__getattr__", (self, "cr_code"))   # round 86
        return _ny_code_of(_ny_fn_info(self._ny_fn))

    @property
    def cr_running(self):
        return async_coro_info(self._ny_coro_h)[0] == 1

    @property
    def cr_suspended(self):
        return async_coro_info(self._ny_coro_h)[0] == 2

    @property
    def cr_await(self):
        return async_coro_info(self._ny_coro_h)[1]

    @property
    def cr_frame(self):
        # None once it has finished; the frame its body is paused in while
        # it is driven by hand; else a frame at its def line
        if _ny_audit_hooks:
            _ny_audit_fire("object.__getattr__", (self, "cr_frame"))   # round 86
        var info = async_coro_info(self._ny_coro_h)
        if info[0] == 3:
            return None
        if info[2] is not None:
            return info[2]
        if self._ny_frame0 is None:
            var fi = _ny_fn_info(self._ny_fn)
            self._ny_frame0 = _NyFrame(fi[5], fi[6], fi[0], fi[2])
            self._ny_frame0._ny_info = fi
        return self._ny_frame0

    cr_origin = None

    def __repr__(self):
        return "<coroutine object " + self.__qualname__ + " at " + _ny_hexid(self) + ">"

    def __del__(self):
        # its handle goes with it (async_coro_drop: its state, -1 when it is
        # suspended by its runner and was kept to be closed first)
        var st = async_coro_drop(self._ny_coro_h)
        if st == 0:
            _ny_coro_unawaited(self)
        elif st == -1:
            # suspended by its runner: closed, as Python's finalizer does
            try:
                self.close()
            except BaseException:
                pass
            async_coro_release(self._ny_coro_h)

_NyCoroutine.__name__ = "coroutine"
_NyCoroutine.__qualname__ = "coroutine"
_NyCoroutine.__module__ = "builtins"

class _NyCoroWrapper(_NyCoroDriver):
    # what a coroutine's __await__ returns (Python's coroutine_wrapper)
    def __init__(self, co):
        self._ny_coro_h = co._ny_coro_h
        self._ny_co = co

    def __repr__(self):
        return "<coroutine_wrapper object at " + _ny_hexid(self) + ">"

_NyCoroWrapper.__name__ = "coroutine_wrapper"
_NyCoroWrapper.__qualname__ = "coroutine_wrapper"
_NyCoroWrapper.__module__ = "builtins"

def _ny_coro_unawaited(co):
    # CPython's warning for a coroutine that was never awaited, through
    # warnings (lib/warnings.ny)
    try:
        import warnings
        warnings._warn_unawaited_coroutine(co)
    except BaseException:
        pass

def _ny_coro_frame(name):
    # the outermost running frame of the coroutine named `name` (its body)
    var f = _ny_frame_get(0)
    var found = None
    while f is not None:
        if f.f_code.co_name == name:
            found = f
        f = f.f_back
    if found is not None:
        _ny_frame_sync(found)   # its line and locals as it pauses
    return found

def _ny_drive_await(g):
    # `await x` where x.__await__() is a generator (or an iterator): run it
    # as a coroutine runner does, its yields going out (_ny_await_yield)
    var r = [0, None]
    var sends = hasattr(g, "send")
    while true:
        var y = None
        try:
            if r[0] == 0:
                y = g.send(r[1]) if sends else next(g)
            elif r[0] == 1:
                if not hasattr(g, "throw"):
                    raise r[1]
                y = g.throw(r[1])
            else:
                if hasattr(g, "close"):
                    g.close()
                raise GeneratorExit()
        except StopIteration as e:
            return e.value
        var name = _ny_await_manual()
        r = _ny_await_yield(y, g, _ny_coro_frame(name) if name is not None else None)

def _ny_await_iter(g):
    # the handle of a coroutine running _ny_drive_await(g) (the engines'
    # await of an __await__ generator). Round 86: a coroutine's own
    # __await__ (`def __await__(self): return self._coro().__await__()`, the
    # websockets package's connect/serve shape) is that coroutine, awaited
    # as it is when it has not started: driven by hand, its native waits
    # parked the task - and a wait for another task of the loop never ended.
    if type(g) is _NyCoroWrapper and async_coro_info(g._ny_coro_h)[0] == 0:
        return g._ny_coro_h
    return async_coroutine(_ny_drive_await, g)

# ── async generators (round 78: their own objects) ───────────────────────
# An `async def` with a yield gives an _NyAsyncGen (Python's
# async_generator) over a plain generator that runs its body; __anext__,
# asend, athrow and aclose return awaitables of one step of it (Python's
# async_generator_asend / async_generator_athrow), which can also be driven
# by hand. `async for` reads the generator directly.
# sys.set_asyncgen_hooks / get_asyncgen_hooks (round 82): firstiter is
# called with an async generator when it is first stepped, finalizer when
# one that has not finished is collected - asyncio's loop uses them to close
# the generators a program abandoned (loop.shutdown_asyncgens). Kept per
# thread, as CPython keeps them in the thread state.
_ny_agen_hooks_by_thread = {}
_ny_agen_unset = object()

def _ny_agen_hooks_now():
    return _ny_agen_hooks_by_thread.get(thread_os_id(), (None, None))

def _ny_set_asyncgen_hooks(firstiter=_ny_agen_unset, finalizer=_ny_agen_unset):
    if finalizer is not _ny_agen_unset and finalizer is not None and not callable(finalizer):
        raise TypeError("callable finalizer expected, got " + type(finalizer).__name__)
    if firstiter is not _ny_agen_unset and firstiter is not None and not callable(firstiter):
        raise TypeError("callable firstiter expected, got " + type(firstiter).__name__)
    # (round 86) each hook given is audited, the finalizer first - under
    # the names CPython's C code raises (its docs say ..._hooks_...)
    if finalizer is not _ny_agen_unset:
        _ny_sys_audit("sys.set_asyncgen_hook_finalizer")
    if firstiter is not _ny_agen_unset:
        _ny_sys_audit("sys.set_asyncgen_hook_firstiter")
    var cur = _ny_agen_hooks_now()
    var fi = cur[0] if firstiter is _ny_agen_unset else firstiter
    var fn = cur[1] if finalizer is _ny_agen_unset else finalizer
    _ny_agen_hooks_by_thread[thread_os_id()] = (fi, fn)

def _ny_get_asyncgen_hooks():
    var cur = _ny_agen_hooks_now()
    return _NySysAsyncGenHooks((cur[0], cur[1]))

class _NyAsyncGen:
    def __init__(self, g, name="", qualname=""):
        self._g = g
        self._ny_running = False
        self._ny_hooked = False      # firstiter called, finalizer taken (round 82)
        self._ny_finalizer = None
        self._ny_closed = False      # finished or closed: nothing for a finalizer to do
        self.__name__ = name
        self.__qualname__ = qualname

    def _ny_init_hooks(self):
        if self._ny_hooked:
            return
        self._ny_hooked = True
        var h = _ny_agen_hooks_now()
        if h[1] is not None:
            self._ny_finalizer = h[1]
        if h[0] is not None:
            h[0](self)

    def __del__(self):
        # an unfinished generator collected: its finalizer (asyncio's
        # schedules aclose() on its loop), as CPython's _PyGen_Finalize
        var fin = self._ny_finalizer
        if fin is not None and not self._ny_closed:
            self._ny_finalizer = None
            fin(self)

    def __aiter__(self):
        return self

    def __anext__(self):
        self._ny_init_hooks()
        return _NyAGenASend(self, 0, None)

    def asend(self, value):
        self._ny_init_hooks()
        return _NyAGenASend(self, 0, value)

    def athrow(self, typ, val=None, tb=None):
        self._ny_init_hooks()
        return _NyAGenAThrow(self, 1, _ny_exc_of(typ, val, tb))

    def aclose(self):
        self._ny_init_hooks()
        return _NyAGenAThrow(self, 2, None)

    def __iter__(self):
        self._ny_init_hooks()
        return self._g

    @property
    def ag_running(self):
        return self._ny_running

    @property
    def ag_frame(self):
        if _ny_audit_hooks:
            _ny_audit_fire("object.__getattr__", (self, "ag_frame"))   # round 86
        return self._g.gi_frame

    @property
    def ag_code(self):
        if _ny_audit_hooks:
            _ny_audit_fire("object.__getattr__", (self, "ag_code"))   # round 86
        return self._g.gi_code

    @property
    def ag_await(self):
        return None

    @property
    def ag_suspended(self):
        return self._g.gi_suspended

    def __repr__(self):
        return "<async_generator object " + self.__qualname__ + " at " + _ny_hexid(self) + ">"

_NyAsyncGen.__name__ = "async_generator"
_NyAsyncGen.__qualname__ = "async_generator"
_NyAsyncGen.__module__ = "builtins"

def _ny_async_gen(g, name="", qualname=""):
    return _NyAsyncGen(g, name, qualname)

def _ny_agen_step(ag, mode, value):
    # one step of an async generator: next / send (0), throw (1), close (2)
    if ag._ny_running:
        raise RuntimeError("anext(): asynchronous generator is already running")
    ag._ny_running = true
    try:
        if mode == 0:
            return ag._g.send(value)
        if mode == 1:
            return ag._g.throw(value)
        ag._ny_closed = true
        try:
            ag._g.close()
        except RuntimeError:
            raise RuntimeError("async generator ignored GeneratorExit")
        return None
    except StopIteration:
        ag._ny_closed = true
        raise StopAsyncIteration()
    except BaseException:
        if ag._g.gi_frame is None:      # an error ended it
            ag._ny_closed = true
        raise
    finally:
        ag._ny_running = false

class _NyAGenASend(_NyCoroDriver):
    def __init__(self, ag, mode, value):
        self._ny_coro_h = async_coroutine(_ny_agen_step, ag, mode, value)

    def __await__(self):
        return self

    def __del__(self):
        async_coro_release(self._ny_coro_h)

    def __repr__(self):
        return "<" + type(self).__name__ + " object at " + _ny_hexid(self) + ">"

class _NyAGenAThrow(_NyAGenASend):
    pass

_NyAGenASend.__name__ = "async_generator_asend"
_NyAGenASend.__qualname__ = "async_generator_asend"
_NyAGenASend.__module__ = "builtins"
_NyAGenAThrow.__name__ = "async_generator_athrow"
_NyAGenAThrow.__qualname__ = "async_generator_athrow"
_NyAGenAThrow.__module__ = "builtins"

def _ny_adrive(it):
    while true:
        var v = none
        try:
            v = async_await(it.__anext__())
        except StopAsyncIteration:
            return
        yield v

def _ny_aiter(o):
    if isinstance(o, _NyAsyncGen):
        o._ny_init_hooks()     # async for steps it: the hooks run (round 82)
        return o._g
    if hasattr(o, "__aiter__"):
        return _ny_adrive(o.__aiter__())
    return o

def aiter(o):
    if hasattr(o, "__aiter__"):
        return o.__aiter__()
    raise TypeError("'" + str(type(o)) + "' object is not an async iterable")

def anext(it, *default):
    if not hasattr(it, "__anext__"):
        raise TypeError("'" + str(type(it)) + "' object is not an async iterator")
    try:
        return async_await(it.__anext__())
    except StopAsyncIteration:
        if len(default) > 0:
            return default[0]
        raise

# ── frames and tracebacks (round 77) ─────────────────────────────────────
# e.__traceback__ is a chain of _NyTraceback the engines make as the
# exception passes each frame (tb_next, tb_lineno, and the frame's file,
# function and module in _ny_loc, "\x1f"-separated); since round 78 each
# entry holds the frame object itself (_ny_frame: f_locals, f_back ...).
# Frames are the engines' (_NyFrame below), made only when asked for.
def _ny_hexid(o):
    return "0x" + format(id(o), "x")

class _NyCodeInfo:
    # a frame's f_code
    def __init__(self, filename, name):
        self.co_filename = filename
        self.co_name = name
        self.co_qualname = name
        self.co_firstlineno = 0

    def __repr__(self):
        return "<code object " + self.co_name + " at " + _ny_hexid(self) + ", file \"" + self.co_filename + "\", line " + str(self.co_firstlineno) + ">"

class _NyFrame:
    # A frame object (round 78). The engines make one only when a program
    # asks - sys._getframe(), inspect.currentframe(), a traceback's
    # tb_frame, a generator's gi_frame - and set these fields themselves (no
    # __init__ runs): _ny_info (the code, as _ny_fn_info gives a
    # function's), _ny_line, _ny_lasti and _ny_locals. While its call runs,
    # f_lineno / f_lasti / f_locals are read from the running frame
    # (_ny_frame_sync refreshes them: f_locals is what locals() gives
    # there) and f_back is the caller's frame (_ny_frame_back); a frame that
    # outlives its call keeps its last line, locals and caller.
    # _NyFrame(filename, lineno, name, module, back) makes a detached one
    # (a traceback built by types.TracebackType).
    f_trace = None
    f_trace_lines = True
    f_trace_opcodes = False
    _ny_info = None
    _ny_code = None
    _ny_back = None
    _ny_line = 0
    _ny_lasti = -1
    _ny_locals = None
    _ny_detached_globals = None

    def __init__(self, filename, lineno, name, module="__main__", back=None):
        self._ny_info = [name, name, module, [], 0, filename, 0]
        self._ny_line = lineno
        self._ny_back = back
        self._ny_locals = {}
        self._ny_detached_globals = {"__name__": module, "__file__": filename}

    @property
    def f_code(self):
        if _ny_audit_hooks:
            _ny_audit_fire("object.__getattr__", (self, "f_code"))   # round 86
        var c = self._ny_code
        if c is None:
            c = _ny_code_of(self._ny_info)
            self._ny_code = c
        return c

    @property
    def f_lineno(self):
        _ny_frame_sync(self)
        return self._ny_line

    @f_lineno.setter
    def f_lineno(self, lineno):
        # (round 81) a trace function moves its frame to another line, by
        # CPython's rules (the engines check them and make the jump when the
        # trace function returns); a refused jump is a ValueError (pdb's
        # "Jump failed: ...")
        if type(lineno) is not int:
            raise ValueError("lineno must be an integer")
        _ny_frame_jump(self, lineno)

    @property
    def f_lasti(self):
        _ny_frame_sync(self)
        return self._ny_lasti

    @property
    def f_locals(self):
        # a running function's frame: a FrameLocalsProxy (PEP 667, CPython
        # 3.13 - writes reach its variables; round 79); a module's, or a
        # frame that has ended, its variables as a dict
        if _ny_frame_sync(self) and self._ny_info is not None and self._ny_info[0] != "<module>":
            return _NyFrameLocals(self)
        var l = self._ny_locals
        if l is None:
            l = {}
            self._ny_locals = l
        return l

    @property
    def f_globals(self):
        if self._ny_detached_globals is not None:
            return self._ny_detached_globals
        return _ny_frame_globals(self)

    @property
    def f_builtins(self):
        return _ny_builtins_dict()

    @property
    def f_back(self):
        return _ny_frame_back(self)

    def clear(self):
        # Python's: a running frame cannot be cleared; a finished one lets
        # go of its locals
        if _ny_frame_sync(self):
            raise RuntimeError("cannot clear an executing frame")
        self._ny_locals = {}

    def __repr__(self):
        return "<frame at " + _ny_hexid(self) + ", file '" + self.f_code.co_filename + "', line " + str(self.f_lineno) + ", code " + self.f_code.co_name + ">"

# shown as Python's types are (round 78)
_NyFrame.__name__ = "frame"
_NyFrame.__qualname__ = "frame"
_NyFrame.__module__ = "builtins"

class _NyFrameLocals:
    # frame.f_locals of a running function (round 79): PEP 667's
    # FrameLocalsProxy (CPython 3.13). Reads see the frame's variables as
    # they are now; proxy[name] = value changes the variable the running
    # code reads next (_ny_frame_local_set) - from a trace function too;
    # deleting is refused, as there. Once the frame has ended it reads and
    # writes the variables the frame ended with. A dunder name (pdb's
    # __return__ / __exception__) is kept beside the variables, as 3.13's
    # extra locals are - locals() leaves the frame's dunders out.
    def __init__(self, frame):
        self._ny_f = frame

    def _ny_snap(self):
        var f = self._ny_f
        _ny_frame_sync(f)
        var l = f._ny_locals
        if l is None:
            l = {}
            f._ny_locals = l
        var x = getattr(f, "_ny_xlocals", None)
        if x:
            l.update(x)
        return l

    def __getitem__(self, key):
        return self._ny_snap()[key]

    def __setitem__(self, key, value):
        if not isinstance(key, str):
            raise TypeError("local variables must be strings")
        if key.startswith("__") and key.endswith("__") and len(key) > 4:
            var x = getattr(self._ny_f, "_ny_xlocals", None)
            if x is None:
                x = {}
                self._ny_f._ny_xlocals = x
            x[key] = value
        elif not _ny_frame_local_set(self._ny_f, key, value):
            self._ny_snap()[key] = value

    def __delitem__(self, key):
        raise ValueError("cannot remove local variables from FrameLocalsProxy")

    def __contains__(self, key):
        return key in self._ny_snap()

    def __iter__(self):
        return iter(list(self._ny_snap().keys()))

    def __len__(self):
        return len(self._ny_snap())

    def keys(self):
        return self._ny_snap().keys()

    def values(self):
        return self._ny_snap().values()

    def items(self):
        return self._ny_snap().items()

    def get(self, key, default=None):
        return self._ny_snap().get(key, default)

    def copy(self):
        return dict(self._ny_snap())

    def update(self, *args, **kwargs):
        var d = dict(*args, **kwargs)
        for k in list(d.keys()):
            self[k] = d[k]

    def setdefault(self, key, default=None):
        var l = self._ny_snap()
        if key in l:
            return l[key]
        self[key] = default
        return default

    def pop(self, key, *default):
        raise ValueError("cannot remove local variables from FrameLocalsProxy")

    def __eq__(self, other):
        if isinstance(other, _NyFrameLocals):
            return self._ny_snap() == other._ny_snap()
        if isinstance(other, dict):
            return self._ny_snap() == other
        return NotImplemented

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    def __or__(self, other):
        var d = dict(self._ny_snap())
        d.update(other)
        return d

    def __ror__(self, other):
        var d = dict(other)
        d.update(self._ny_snap())
        return d

    def __repr__(self):
        return repr(self._ny_snap())

    __hash__ = None

_NyFrameLocals.__name__ = "FrameLocalsProxy"
_NyFrameLocals.__qualname__ = "FrameLocalsProxy"
_NyFrameLocals.__module__ = "builtins"

# breakpoint() and sys.breakpointhook (round 79): PYTHONBREAKPOINT names the
# hook - unset or empty is pdb.set_trace, "0" turns breakpoint() off,
# "mod.func" imports mod and calls func, a bare name is a builtin's.
def _ny_breakpointhook(*args, **kws):
    var hookname = os_getenv("PYTHONBREAKPOINT")
    if hookname is None or len(hookname) == 0:
        hookname = "pdb.set_trace"
    elif hookname == "0":
        return None
    var cut = hookname.rfind(".")
    var modname = "builtins" if cut < 0 else hookname[:cut]
    var funcname = hookname[cut + 1:]
    var hook = None
    try:
        if modname == "builtins":
            hook = _ny_main_globals()[funcname]
        else:
            var ns = {}
            exec("import " + modname + " as _ny_bp_mod", ns)
            # (eval: the VM binds a native module's alias - math - among the
            # globals, not in ns)
            hook = getattr(eval("_ny_bp_mod", ns), funcname)
    except Exception:
        import warnings
        warnings.warn("Ignoring unimportable $PYTHONBREAKPOINT: \"" + hookname + "\"", RuntimeWarning)
        return None
    return hook(*args, **kws)

def breakpoint(*args, **kws):
    import sys
    var hook = getattr(sys, "breakpointhook", None)
    if hook is None:
        raise RuntimeError("lost sys.breakpointhook")
    if _ny_audit_hooks:
        _ny_audit_fire("builtins.breakpoint", (hook,))   # round 86
    return hook(*args, **kws)

class _NyTraceback:
    # Made by the engines without calling this (fields set directly);
    # types.TracebackType(tb_next, tb_frame, tb_lasti, tb_lineno) calls it.
    tb_lasti = -1
    _ny_frame = None

    def __init__(self, tb_next=None, tb_frame=None, tb_lasti=-1, tb_lineno=0):
        self.tb_next = tb_next
        self.tb_lasti = tb_lasti
        self.tb_lineno = tb_lineno
        self._ny_frame = tb_frame
        self._ny_loc = "<unknown>\x1f<module>\x1f__main__"

    @property
    def tb_frame(self):
        if _ny_audit_hooks:
            _ny_audit_fire("object.__getattr__", (self, "tb_frame"))   # round 86
        if self._ny_frame is None:
            var loc = self._ny_loc.split("\x1f")
            self._ny_frame = _NyFrame(loc[0], self.tb_lineno, loc[1], loc[2])
        return self._ny_frame

    def __repr__(self):
        return "<traceback object at " + _ny_hexid(self) + ">"

_NyTraceback.__name__ = "traceback"   # round 78
_NyTraceback.__qualname__ = "traceback"
_NyTraceback.__module__ = "builtins"

# Every exception has these, as in Python (the engines set them on the
# object when it is raised and caught).
BaseException.__traceback__ = None
BaseException.__cause__ = None
BaseException.__context__ = None
BaseException.__suppress_context__ = False

def _ny_exc_with_traceback(self, tb):
    self.__traceback__ = tb
    return self
BaseException.with_traceback = _ny_exc_with_traceback

def _ny_exc_add_note(self, note):
    if not isinstance(note, str):
        raise TypeError("note must be a str, not '" + type(note).__name__ + "'")
    var notes = getattr(self, "__notes__", None)
    if notes is None:
        notes = []
        self.__notes__ = notes
    notes.append(note)
BaseException.add_note = _ny_exc_add_note

def _ny_exc_info():
    # sys.exc_info()
    var e = _ny_exc_current()
    if e is None:
        return (None, None, None)
    return (type(e), e, getattr(e, "__traceback__", None))

def _ny_getframe(depth=0):
    # sys._getframe(depth): the caller's frame (depth 0) - the engines' own
    # frame object (round 78), the same one each time while it runs
    var f = _ny_frame_get(depth)
    if _ny_audit_hooks:
        _ny_audit_fire("sys._getframe", (f,))   # round 86
    return f

def _ny_getframemodulename(depth=0):
    # (round 86) sys._getframemodulename (3.12)
    _ny_sys_audit("sys._getframemodulename", depth)
    var f = None
    try:
        f = _ny_frame_get(depth)
    except ValueError:
        return None
    var g = f.f_globals
    return g.get("__name__") if g is not None else None

def _ny_current_frames():
    # (round 86) the calling thread's only (HANDOFF 0zG)
    _ny_sys_audit("sys._current_frames")
    return {thread_os_id(): _ny_frame_get(0)}

def _ny_current_exceptions():
    # (round 86) the calling thread's only
    _ny_sys_audit("sys._current_exceptions")
    var e = _ny_exc_current()
    return {} if e is None else {thread_os_id(): e}

# What the engines print for an uncaught exception before their own line
# ("[Nython] Uncaught exception - Type: message"): Python's traceback - the
# chained exceptions first - without that last line.
def _ny_tb_lines(tb, cache):
    # as traceback.StackSummary.format: a run of more than three identical
    # entries (deep recursion) ends with "[Previous line repeated N more times]"
    var out = ""
    var last = None
    var count = 0
    while tb is not None:
        var fr = tb.tb_frame
        var fn = fr.f_code.co_filename
        var key = (fn, tb.tb_lineno, fr.f_code.co_name)
        if key != last:
            if count > 3:
                out += "  [Previous line repeated " + str(count - 3) + " more time" + ("s" if count - 3 > 1 else "") + "]\n"
            last = key
            count = 0
        count += 1
        if count <= 3:
            out += "  File \"" + fn + "\", line " + str(tb.tb_lineno) + ", in " + fr.f_code.co_name + "\n"
            if fn not in cache:
                var lines = []
                try:
                    var f = open(fn)
                    lines = f.readlines()
                    f.close()
                except BaseException:
                    lines = []
                cache[fn] = lines
            var src = cache[fn]
            if tb.tb_lineno >= 1 and tb.tb_lineno <= len(src):
                var line = src[tb.tb_lineno - 1].strip()
                if line != "":
                    out += "    " + line + "\n"
        tb = tb.tb_next
    if count > 3:
        out += "  [Previous line repeated " + str(count - 3) + " more time" + ("s" if count - 3 > 1 else "") + "]\n"
    return out

def _ny_exc_line(e):
    var t = type(e)
    var name = getattr(t, "__name__", "Exception")
    var mod = getattr(t, "__module__", "builtins")
    if mod is not None and mod != "builtins" and mod != "__main__":
        name = mod + "." + name
    var msg = ""
    try:
        msg = str(e)
    except BaseException:
        msg = "<exception str() failed>"
    if msg == "":
        return name + "\n"
    return name + ": " + msg + "\n"

def _ny_format_exc(e, last_line, seen, cache):
    seen.append(id(e))
    var out = ""
    var cause = getattr(e, "__cause__", None)
    var ctx = getattr(e, "__context__", None)
    if cause is not None and id(cause) not in seen:
        out += _ny_format_exc(cause, True, seen, cache) + "\nThe above exception was the direct cause of the following exception:\n\n"
    elif ctx is not None and not getattr(e, "__suppress_context__", False) and id(ctx) not in seen:
        out += _ny_format_exc(ctx, True, seen, cache) + "\nDuring handling of the above exception, another exception occurred:\n\n"
    var tb = getattr(e, "__traceback__", None)
    if tb is not None:
        out += "Traceback (most recent call last):\n" + _ny_tb_lines(tb, cache)
    if last_line:
        out += _ny_exc_line(e)
    return out

# sys.excepthook / sys.__excepthook__ (round 80): the traceback the engines
# print for an uncaught exception, on the current sys.stderr. A program's
# own hook is called instead (_ny_format_uncaught then gives None and the
# engines print nothing more).
_ny_sys_ref = [None]

def _ny_excepthook(exc_type, value, tb):
    var err = None
    if _ny_sys_ref[0] is not None:
        err = getattr(_ny_sys_ref[0], "stderr", None)
    if err is None:
        err = _ny_stderr
    if not isinstance(value, BaseException):
        # reported, not raised (CPython's sys.excepthook)
        err.write("TypeError: print_exception(): Exception expected for value, " + type(value).__name__ + " found\n")
        return
    # the exception's own traceback; the one given only when it has none
    # (CPython's _PyErr_Display puts it on the exception)
    if tb is not None and getattr(value, "__traceback__", None) is None:
        value.__traceback__ = tb
    err.write(_ny_format_exc(value, True, [], {}))

def _ny_format_uncaught(e):
    var s = _ny_sys_ref[0]
    if s is not None:
        var hook = getattr(s, "excepthook", None)
        if hook is not None and _ny_audit_hooks and _ny_audit_excepthook(hook, e):   # round 86
            return None
        if hook is None:
            _ny_stderr.write("sys.excepthook is missing\n")
        elif hook is not _ny_excepthook:
            try:
                hook(type(e), e, getattr(e, "__traceback__", None))
            except BaseException as he:
                _ny_stderr.write("Error in sys.excepthook:\n" + _ny_format_exc(he, True, [], {}) +
                                 "\nOriginal exception was:\n" + _ny_format_exc(e, True, [], {}))
            return None
    try:
        return _ny_format_exc(e, False, [], {})
    except BaseException:
        return ""

# atexit (round 77, lib/atexit.ny): the engines call _ny_run_atexit when
# the program ends - normally, by sys.exit() or by an uncaught exception.
_ny_atexit_handlers = []

def _ny_run_atexit():
    # last registered first; one that raises is reported (SystemExit is
    # not) and the rest still run
    while len(_ny_atexit_handlers) > 0:
        var h = _ny_atexit_handlers.pop()
        try:
            h[0](*h[1], **h[2])
        except SystemExit:
            pass
        except BaseException as e:
            _ny_stderr.write("Exception ignored in atexit callback: " + repr(h[0]) + "\n" + _ny_format_exc(e, True, [], {}))

# ── os's structure sequences and raising functions (round 77) ─────────────
# `import os` binds these in place of the flat builtins of the same name
# (NyRuntime.hpp os_python_members): os.stat() gives an os.stat_result,
# os.get_terminal_size() an os.terminal_size, os.times() / os.uname() their
# results - tuple-like (indexing, slicing, len, iteration, unpacking, == and
# ordering against tuples, hashing) with named fields and read-only, as
# CPython's structseq, but not a tuple subclass (isinstance(st, tuple) is
# false here). os.listdir / rename / replace / mkdir / link / remove raise
# OSError with errno, strerror and the file names (filename2 for two).
class _NyStructSeq:
    _ny_qual = "structseq"
    _ny_names = ()
    _ny_repr_names = None
    _ny_extra = ()
    _ny_exact = True

    def __init__(self, seq=(), dict=None):
        var cls = type(self)
        var t = tuple(seq)
        var n = len(cls._ny_names)
        var total = n + len(cls._ny_extra)
        var q = self._ny_qualname()
        if cls._ny_exact and len(t) != n:
            raise TypeError(q + "() takes a " + str(n) + "-sequence (" + str(len(t)) + "-sequence given)")
        if len(t) < n:
            raise TypeError(q + "() takes an at least " + str(n) + "-sequence (" + str(len(t)) + "-sequence given)")
        if len(t) > total:
            raise TypeError(q + "() takes an at most " + str(total) + "-sequence (" + str(len(t)) + "-sequence given)")
        object.__setattr__(self, "_ny_t", t[:n])
        var i = 0
        for name in cls._ny_names:
            if name is not None:
                object.__setattr__(self, name, t[i])
            i += 1
        var k = 0
        for name in cls._ny_extra:
            var v = None
            if n + k < len(t):
                v = t[n + k]
            elif dict is not None and name in dict:
                v = dict[name]
            object.__setattr__(self, name, v)
            k += 1
        self._ny_fill()

    def _ny_fill(self):
        pass

    def _ny_qualname(self):
        return type(self)._ny_qual

    def __setattr__(self, name, value):
        raise AttributeError("readonly attribute")

    def __delattr__(self, name):
        raise AttributeError("readonly attribute")

    def __len__(self):
        return len(self._ny_t)

    def __getitem__(self, i):
        return self._ny_t[i]

    def __iter__(self):
        return iter(self._ny_t)

    def __contains__(self, x):
        return x in self._ny_t

    def __eq__(self, other):
        if isinstance(other, _NyStructSeq):
            return self._ny_t == other._ny_t
        return self._ny_t == other

    def __ne__(self, other):
        return not self.__eq__(other)

    def __lt__(self, other):
        return self._ny_t < (other._ny_t if isinstance(other, _NyStructSeq) else other)

    def __le__(self, other):
        return self._ny_t <= (other._ny_t if isinstance(other, _NyStructSeq) else other)

    def __gt__(self, other):
        return self._ny_t > (other._ny_t if isinstance(other, _NyStructSeq) else other)

    def __ge__(self, other):
        return self._ny_t >= (other._ny_t if isinstance(other, _NyStructSeq) else other)

    def __hash__(self):
        return hash(self._ny_t)

    def __add__(self, other):
        return self._ny_t + (other._ny_t if isinstance(other, _NyStructSeq) else other)

    def count(self, x):
        return self._ny_t.count(x)

    def index(self, x):
        return self._ny_t.index(x)

    def __reduce__(self):
        return (type(self), (self._ny_t,))

    def __repr__(self):
        var names = type(self)._ny_repr_names
        if names is None:
            names = type(self)._ny_names
        var parts = []
        var i = 0
        for v in self._ny_t:
            parts.append(str(names[i]) + "=" + repr(v))
            i += 1
        return self._ny_qualname() + "(" + ", ".join(parts) + ")"

class stat_result(_NyStructSeq):
    __module__ = "os"
    _ny_qual = "os.stat_result"
    _ny_names = ("st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size", None, None, None)
    _ny_repr_names = ("st_mode", "st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size",
                      "st_atime", "st_mtime", "st_ctime")
    _ny_extra = ("st_atime", "st_mtime", "st_ctime", "st_atime_ns", "st_mtime_ns", "st_ctime_ns",
                 "st_blksize", "st_blocks", "st_rdev")
    _ny_exact = False
    n_sequence_fields = 10
    n_fields = 19
    n_unnamed_fields = 3

    def _ny_fill(self):
        # the float times default to the integer ones (CPython's statresult_new)
        var t = self._ny_t
        if self.st_atime is None:
            object.__setattr__(self, "st_atime", t[7])
        if self.st_mtime is None:
            object.__setattr__(self, "st_mtime", t[8])
        if self.st_ctime is None:
            object.__setattr__(self, "st_ctime", t[9])

class terminal_size(_NyStructSeq):
    __module__ = "os"
    _ny_qual = "os.terminal_size"
    _ny_names = ("columns", "lines")
    n_sequence_fields = 2
    n_fields = 2
    n_unnamed_fields = 0

class times_result(_NyStructSeq):
    __module__ = "posix"
    _ny_names = ("user", "system", "children_user", "children_system", "elapsed")
    n_sequence_fields = 5
    n_fields = 5
    n_unnamed_fields = 0

    def _ny_qualname(self):
        return ("nt" if os_name == "nt" else "posix") + ".times_result"

class uname_result(_NyStructSeq):
    __module__ = "posix"
    _ny_qual = "posix.uname_result"
    _ny_names = ("sysname", "nodename", "release", "version", "machine")
    n_sequence_fields = 5
    n_fields = 5
    n_unnamed_fields = 0

_ny_os_stat_result = stat_result
_ny_os_terminal_size = terminal_size
_ny_os_times_result = times_result
_ny_os_uname_result = uname_result
del stat_result
del terminal_size
del times_result
del uname_result

def _ny_os_stat_of(m):
    var ns = 1000000000
    return _ny_os_stat_result((m["mode"], m["ino"], m["dev"], m["nlink"], m["uid"], m["gid"], m["size"],
                               m["atime_ns"] // ns, m["mtime_ns"] // ns, m["ctime_ns"] // ns,
                               m["atime"], m["mtime"], m["ctime"], m["atime_ns"], m["mtime_ns"], m["ctime_ns"],
                               m.get("blksize"), m.get("blocks"), m.get("rdev")))

def _ny_os_stat(path, *, dir_fd=None, follow_symlinks=True):
    if isinstance(path, int) and not isinstance(path, bool):
        return _ny_os_fstat(path)
    return _ny_os_stat_of(os_stat(path) if follow_symlinks else os_lstat(path))

def _ny_os_lstat(path, *, dir_fd=None):
    return _ny_os_stat_of(os_lstat(path))

def _ny_os_fstat(fd):
    return _ny_os_stat_of(_ny_os_call("fstat", fd))

def _ny_os_get_terminal_size(fd=1):
    return _ny_os_terminal_size(_ny_os_call("terminal_size", fd))

def _ny_os_times():
    return _ny_os_times_result(_ny_os_call("times"))

def _ny_os_uname():
    var u = os_uname()
    return _ny_os_uname_result((u["sysname"], u["nodename"], u["release"], u["version"], u["machine"]))

# (round 86) audited as CPython's posixmodule.c
def _ny_os_listdir(path=None):
    _ny_sys_audit("os.listdir", path)
    return _ny_os_call("listdir", "." if path is None else path)

def _ny_os_rename(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.rename", (src, dst, _ny_audit_dirfd(src_dir_fd), _ny_audit_dirfd(dst_dir_fd)))
    _ny_os_call("rename", src, dst)

def _ny_os_replace(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.rename", (src, dst, _ny_audit_dirfd(src_dir_fd), _ny_audit_dirfd(dst_dir_fd)))
    _ny_os_call("replace", src, dst)

def _ny_os_mkdir(path, mode=511, *, dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.mkdir", (path, mode, _ny_audit_dirfd(dir_fd)))
    _ny_os_call("mkdir", path, mode)

def _ny_os_link(src, dst, *, src_dir_fd=None, dst_dir_fd=None, follow_symlinks=True):
    if _ny_audit_hooks:
        _ny_audit_fire("os.link", (src, dst, _ny_audit_dirfd(src_dir_fd), _ny_audit_dirfd(dst_dir_fd)))
    _ny_os_call("link", src, dst)

# Exception groups (PEP 654, Python 3.11; round 77): BaseExceptionGroup and
# ExceptionGroup with message, exceptions, split, subgroup and derive, and
# the protocol `except*` is desugared onto (Parser::tryStmt): _NyStar holds
# what is left of the exception, _ny_star_match splits each clause's types
# off it, _ny_star_finish raises what remains - CPython's
# _PyExc_PrepReraiseStar: the unhandled and re-raised leaves keep the
# original's shape (a projection), exceptions the handlers raised are
# grouped with them, a naked exception is re-raised as itself.
def _ny_eg_matcher(condition):
    if isinstance(condition, type) or isinstance(condition, tuple):
        return lambda e: isinstance(e, condition)
    if callable(condition):
        return condition
    raise TypeError("expected an exception type, a tuple of exception types, or a callable (other than a class)")

class BaseExceptionGroup(BaseException):
    def __new__(cls, message, exceptions):
        if not isinstance(message, str):
            raise TypeError("argument 1 must be str, not " + type(message).__name__)
        if not isinstance(exceptions, (list, tuple)):
            raise TypeError("second argument (exceptions) must be a sequence")
        if len(exceptions) == 0:
            raise ValueError("second argument (exceptions) must be a non-empty sequence")
        var all_plain = True
        var i = 0
        for e in exceptions:
            if not isinstance(e, BaseException):
                raise ValueError("Item " + str(i) + " of second argument (exceptions) is not an exception")
            if not isinstance(e, Exception):
                all_plain = False
            i += 1
        if cls is BaseExceptionGroup and all_plain:
            cls = ExceptionGroup
        elif cls is ExceptionGroup and not all_plain:
            raise TypeError("Cannot nest BaseExceptions in an ExceptionGroup")
        return super().__new__(cls)
    def __init__(self, message, exceptions):
        self.message = message
        self.exceptions = tuple(exceptions)
        self.args = (message, exceptions)
    def __str__(self):
        var n = len(self.exceptions)
        return self.message + " (" + str(n) + " sub-exception" + ("" if n == 1 else "s") + ")"
    def __repr__(self):
        return type(self).__name__ + "(" + repr(self.message) + ", " + repr(self.args[1]) + ")"
    def derive(self, excs):
        return BaseExceptionGroup(self.message, excs)
    def _ny_copy_meta(self, g):
        g.__traceback__ = self.__traceback__
        g.__cause__ = self.__cause__
        g.__context__ = self.__context__
        var notes = getattr(self, "__notes__", None)
        if notes is not None:
            g.__notes__ = list(notes)
        return g
    def split(self, condition):
        var m = _ny_eg_matcher(condition)
        if m(self):
            return (self, None)
        var matched = []
        var rest = []
        for e in self.exceptions:
            if isinstance(e, BaseExceptionGroup):
                var parts = e.split(condition)
                if parts[0] is not None:
                    matched.append(parts[0])
                if parts[1] is not None:
                    rest.append(parts[1])
            elif m(e):
                matched.append(e)
            else:
                rest.append(e)
        var mg = self._ny_copy_meta(self.derive(matched)) if matched else None
        var rg = self._ny_copy_meta(self.derive(rest)) if rest else None
        return (mg, rg)
    def subgroup(self, condition):
        return self.split(condition)[0]

class ExceptionGroup(BaseExceptionGroup, Exception):
    pass

class _NyStar:
    def __init__(self, exc):
        self.orig = exc
        self.naked = not isinstance(exc, BaseExceptionGroup)
        self.rest = exc
        self.match = None
        self.raised = []
        self.reraised = []

def _ny_star_begin(exc):
    return _NyStar(exc)

def _ny_star_match(st, types):
    var ts = types if isinstance(types, tuple) else (types,)
    for t in ts:
        if isinstance(t, type) and issubclass(t, BaseExceptionGroup):
            raise TypeError("catching ExceptionGroup with except* is not allowed. Use except instead.")
    st.match = None
    if st.rest is None:
        return None
    if st.naked:
        if isinstance(st.rest, types):
            st.match = BaseExceptionGroup("", (st.rest,))
            st.rest = None
    else:
        var parts = st.rest.split(types)
        st.match = parts[0]
        st.rest = parts[1]
    return st.match

def _ny_star_raised(st, e):
    if e is st.match:
        st.reraised.append(e)
    else:
        st.raised.append(e)

def _ny_eg_leaves(g, out):
    for e in g.exceptions:
        if isinstance(e, BaseExceptionGroup):
            _ny_eg_leaves(e, out)
        else:
            out.append(e)

def _ny_star_finish(st):
    if st.naked:
        # one clause at most ran: what it raised, else the exception itself
        if st.raised:
            raise st.raised[0]
        if st.reraised:
            raise st.reraised[0]
        if st.rest is not None:
            raise st.orig
        return
    var keep = []
    if st.rest is not None:
        _ny_eg_leaves(st.rest, keep)
    for g in st.reraised:
        _ny_eg_leaves(g, keep)
    var kept = None
    if keep:
        var all_leaves = []
        _ny_eg_leaves(st.orig, all_leaves)
        if len(all_leaves) == len(keep):
            kept = st.orig
        else:
            kept = st.orig.split(lambda e: not isinstance(e, BaseExceptionGroup) and any(e is k for k in keep))[0]
    if not st.raised:
        if kept is not None:
            raise kept
        return
    var excs = list(st.raised)
    if kept is not None:
        excs.append(kept)
    raise BaseExceptionGroup("", excs)

def _ny_exc_match(e, t):
    # `except <expression>:` (round 80; the parser lowers such clauses onto
    # this): whether the exception handled is an instance of t - a class or
    # a tuple of classes - with CPython's TypeError for anything else (a
    # nested tuple included, as _PyEval_CheckExceptTypeValid)
    var ts = t if isinstance(t, tuple) else (t,)
    for x in ts:
        if not (isinstance(x, type) and issubclass(x, BaseException)):
            raise TypeError("catching classes that do not inherit from BaseException is not allowed")
    for x in ts:
        if isinstance(e, x):
            return True
    return False

# type's own members read from the builtin type (round 83; the engines
# route type.__new__ ... here, nyrt::type_own_member): explicit
# type.__new__(mcs, name, bases, ns) in a metaclass, type.__setattr__(cls,
# name, value) past a metaclass's __setattr__, type.__call__(cls, ...) without
# the metaclass's __call__, ...
def _ny_type_m_new(mcs, *args, **kw):
    if len(args) != 3:
        raise TypeError("type.__new__() takes exactly 3 arguments (" + str(len(args)) + " given)")
    return _ny_type_new(mcs, args[0], args[1], args[2], kw)

def _ny_type_m_init(cls, *args, **kw):
    return None

def _ny_type_m_call(cls, *args, **kw):
    return _ny_type_call(cls, *args, kw)

def _ny_type_m_setattr(cls, name, value):
    if not isinstance(name, str):
        raise TypeError("attribute name must be string, not '" + type(name).__name__ + "'")
    _ny_setattr_raw(cls, name, value)

def _ny_type_m_delattr(cls, name):
    if not isinstance(name, str):
        raise TypeError("attribute name must be string, not '" + type(name).__name__ + "'")
    if not hasattr(cls, name):
        raise AttributeError("type object '" + cls.__name__ + "' has no attribute '" + name + "'")
    _ny_delattr_raw(cls, name)

def _ny_type_m_getattribute(cls, name):
    return object.__getattribute__(cls, name)

def _ny_type_m_prepare(*args, **kw):
    return {}

def _ny_type_m_mro(cls):
    return list(cls.__mro__)

def _ny_type_m_subclasses(cls):
    return cls.__subclasses__()

def _ny_type_m_instancecheck(cls, obj):
    # the default check, without a metaclass's __instancecheck__
    return cls in type(obj).__mro__

def _ny_type_m_subclasscheck(cls, sub):
    return cls in sub.__mro__

def _ny_str_maketrans(*args):
    # str.maketrans (round 80): CPython's three forms and messages
    if len(args) == 0:
        raise TypeError("maketrans expected at least 1 argument, got 0")
    if len(args) > 3:
        raise TypeError("maketrans expected at most 3 arguments, got " + str(len(args)))
    var x = args[0]
    var d = {}
    if len(args) == 1:
        if not isinstance(x, dict):
            raise TypeError("if you give only one argument to maketrans it must be a dict")
        for k in x:
            if isinstance(k, str):
                if len(k) != 1:
                    raise ValueError("string keys in translate table must be of length 1")
                d[ord(k)] = x[k]
            elif isinstance(k, int):
                d[k] = x[k]
            else:
                raise TypeError("keys in translate table must be strings or integers")
        return d
    var y = args[1]
    if not isinstance(y, str):
        raise TypeError("maketrans() argument 2 must be str, not " + type(y).__name__)
    if len(args) == 3 and not isinstance(args[2], str):
        raise TypeError("maketrans() argument 3 must be str, not " + type(args[2]).__name__)
    if not isinstance(x, str):
        raise TypeError("first maketrans argument must be a string if there is a second argument")
    if len(x) != len(y):
        raise ValueError("the first two maketrans arguments must have equal length")
    var i = 0
    for c in x:
        d[ord(c)] = ord(y[i])
        i += 1
    if len(args) == 3:
        for c in args[2]:
            d[ord(c)] = None
    return d

class _NyTransMiss:
    pass
_ny_trans_miss = _NyTransMiss()

def _ny_str_translate(s, table):
    # str.translate (round 80): each character's code point looked up in the
    # table (any object with __getitem__); LookupError keeps the character,
    # None deletes it, an int or a str replaces it
    var out = []
    var plain = type(table) is dict
    for c in s:
        var r = None
        if plain:
            r = table.get(ord(c), _ny_trans_miss)
            if r is _ny_trans_miss:
                out.append(c)
                continue
        else:
            try:
                r = table[ord(c)]
            except LookupError:
                out.append(c)
                continue
        if r is None:
            continue
        if isinstance(r, str):
            out.append(r)
        elif isinstance(r, int):
            if r < 0 or r > 0x10FFFF:
                raise ValueError("character mapping must be in range(0x110000)")
            out.append(chr(r))
        else:
            raise TypeError("character mapping must return integer, None or str")
    return "".join(out)

# ── import machinery as values (round 80) ────────────────────────────────
# sys.modules is the engines' own registry (_ny_modules(): a real dict that
# importing consults and fills); __import__ is the import statement as a
# function; "__main__" is the running program, its globals read through
# the module object.
class _NyMainModule(_NyModuleType):
    # round 81: the real main module - setting or deleting an attribute
    # binds or unbinds the program's global, and its __dict__ (vars()) is
    # the program's globals() itself
    def __init__(self):
        object.__setattr__(self, "__name__", "__main__")
        object.__setattr__(self, "__package__", None)
        object.__setattr__(self, "__loader__", None)
        object.__setattr__(self, "__spec__", None)
    @property
    def __doc__(self):
        # (round 87) the program's docstring, or None: its global __doc__
        return _ny_main_globals().get("__doc__")
    def __getattr__(self, name):
        var g = _ny_main_globals()
        if name in g:
            return g[name]
        raise AttributeError("module '__main__' has no attribute '" + name + "'")
    def __setattr__(self, name, value):
        if name in ("__name__", "__package__", "__loader__", "__spec__"):
            object.__setattr__(self, name, value)
        _ny_main_set(name, value)
    def __delattr__(self, name):
        if not _ny_main_del(name):
            raise AttributeError("module '__main__' has no attribute '" + name + "'")
    @property
    def __dict__(self):
        return _ny_globals_view()
    def __dir__(self):
        return sorted(list(_ny_main_globals()))

def _ny_import_module(name):
    # `import name`, the module itself (not its top-level package)
    var ns = {}
    exec("import " + name + " as _ny_m", ns)
    return ns["_ny_m"]

def _ny_resolve_name(name, package, level):
    # importlib._bootstrap._resolve_name
    var bits = package.rsplit(".", level - 1)
    if len(bits) < level:
        raise ImportError("attempted relative import beyond top-level package")
    var base = bits[0]
    return base + "." + name if name else base

def _ny_calc_package(globals):
    # importlib._bootstrap._calc___package__
    var package = globals.get("__package__")
    var spec = globals.get("__spec__")
    if package is not None:
        return package
    if spec is not None:
        return spec.parent
    if "__name__" not in globals:
        raise KeyError("'__name__' not in globals")
    package = globals["__name__"]
    if "__path__" not in globals:
        package = package.rpartition(".")[0]
    return package

def _ny_handle_fromlist(module, fromlist):
    # importlib._bootstrap._handle_fromlist: each name of fromlist that is
    # not an attribute is imported as a submodule
    for x in fromlist:
        if not isinstance(x, str):
            raise TypeError("Item in " + module.__name__ + ".__all__ must be str, not " + type(x).__name__)
        if x == "*":
            if hasattr(module, "__all__"):
                _ny_handle_fromlist(module, module.__all__)
        elif not hasattr(module, x):
            var from_name = module.__name__ + "." + x
            try:
                _ny_import_module(from_name)
            except ModuleNotFoundError as exc:
                if getattr(exc, "name", None) == from_name or ("'" + from_name + "'") in str(exc):
                    continue
                raise
    return module

def __import__(name, globals=None, locals=None, fromlist=(), level=0):
    # (round 80) CPython's builtin: the top-level package for `import a.b`,
    # the module itself when fromlist names anything (its submodules
    # imported); level > 0 is relative to globals' __package__
    if not isinstance(name, str):
        raise TypeError("module name must be str, not " + type(name).__name__)
    if level < 0:
        raise ValueError("level must be >= 0")
    var full = name
    if level > 0:
        var package = _ny_calc_package(globals) if globals is not None else None
        if not package:
            raise ImportError("attempted relative import with no known parent package")
        full = _ny_resolve_name(name, package, level)
    elif name == "":
        raise ValueError("Empty module name")
    var module = _ny_import_module(full)
    if not fromlist:
        if level == 0:
            return _ny_import_module(name.partition(".")[0])
        if not name:
            return module
        var cut_off = len(name) - len(name.partition(".")[0])
        return _ny_modules()[module.__name__[:len(module.__name__) - cut_off]]
    if hasattr(module, "__path__"):
        return _ny_handle_fromlist(module, fromlist)
    return module

# ── sys.meta_path and sys.path_hooks for the import statement (round 81) ──
# importlib._bootstrap._find_and_load: when a module is not in sys.modules
# yet the engines ask _ny_import_via_hooks(name) first. sys.meta_path's
# default entries stand for the engines' own search (BuiltinImporter, then
# PathFinder - importlib.machinery's classes once it is imported, these
# stand-ins until then), so with no finder or path hook of a program's own
# it answers None at once and the import goes the native way. A finder put
# before them is asked first; one after them only for what they cannot
# find. Through PathFinder, sys.path_hooks are tried on each sys.path entry
# (a package's __path__ for a submodule), their finder kept in
# sys.path_importer_cache (None for an entry no hook takes: the engines'
# own directory search). A spec found is loaded as CPython's
# _load_unlocked: create_module, the module's attributes, sys.modules,
# exec_module.
class _NyNativeFinder:
    def __init__(self, kind):
        self._ny_kind = kind
    def find_spec(self, fullname, path=None, target=None):
        import importlib.machinery
        var c = importlib.machinery.BuiltinImporter if self._ny_kind == "builtin" else importlib.machinery.PathFinder
        return c.find_spec(fullname, path, target)
    def invalidate_caches(self):
        pass
    def __repr__(self):
        if self._ny_kind == "builtin":
            return "<class '_frozen_importlib.BuiltinImporter'>"
        return "<class '_frozen_importlib_external.PathFinder'>"

_ny_hooks_native = object()

def _ny_import_via_hooks(name):
    var sysm = _ny_sys_ref[0]
    if sysm is None:
        return None
    var mp = getattr(sysm, "meta_path", None)
    var hooks = getattr(sysm, "path_hooks", None)
    if not hooks:
        var plain = True
        for f in mp or ():
            if getattr(f, "_ny_kind", None) is None:
                plain = False
                break
        if plain:
            return None
    var path = None
    var parent = name.rpartition(".")[0]
    if parent:
        var pm = sysm.modules.get(parent)
        if pm is None:
            __import__(parent)
            pm = sysm.modules.get(parent)
        if name in sysm.modules:
            return sysm.modules[name]
        path = getattr(pm, "__path__", None)
        if path is None:
            raise ModuleNotFoundError("No module named " + repr(name) + "; " + repr(parent) + " is not a package", name=name)
    for finder in list(mp or ()):
        var kind = getattr(finder, "_ny_kind", None)
        if kind == "builtin":
            if not parent and name in sysm.builtin_module_names:
                return None
            continue
        if kind == "path":
            if hooks:
                var hs = _ny_path_hooks_spec(sysm, name, path, hooks)
                if hs is _ny_hooks_native:
                    return None
                if hs is not None:
                    return _ny_load_spec(sysm, hs)
                continue
            if _ny_find_module(name)[0]:
                return None
            continue
        var fs = getattr(finder, "find_spec", None)
        if fs is None:
            continue
        var spec = fs(name, path, None)
        if spec is not None:
            return _ny_load_spec(sysm, spec)
    return None

def _ny_path_hooks_spec(sysm, name, path, hooks):
    # importlib.machinery.PathFinder._get_spec over sys.path_hooks
    var entries = path if path is not None else sysm.path
    var cache = sysm.path_importer_cache
    var tail = name.rpartition(".")[2]
    for entry in list(entries):
        if not isinstance(entry, str):
            continue
        var finder = None
        if entry in cache:
            finder = cache[entry]
        else:
            # round 84: provisionally no finder while the hooks run - a hook
            # that imports (zipimporter's os.path calls import lazily on
            # Windows) has the entry searched natively instead of entering
            # the hook again without end (a RecursionError for `nython
            # app.pyz` there); a hook's own error leaves no entry
            cache[entry] = None
            try:
                for hook in list(hooks):
                    try:
                        finder = hook(entry)
                        break
                    except ImportError:
                        continue
            except BaseException:
                cache.pop(entry, None)
                raise
            cache[entry] = finder
        if finder is None:
            # no hook takes it: the engines' own search of that directory
            var d = entry if entry else "."
            if os_isfile(d + "/" + tail + ".ny") or os_isfile(d + "/" + tail + "/__init__.ny"):
                return _ny_hooks_native
            continue
        var spec = finder.find_spec(name, None)
        if spec is not None and (spec.loader is not None or spec.submodule_search_locations):
            return spec
    return None

def _ny_load_spec(sysm, spec):
    var name = spec.name
    var loader = spec.loader
    var module = None
    if loader is not None and hasattr(loader, "create_module"):
        module = loader.create_module(spec)
    elif loader is None and not spec.submodule_search_locations:
        raise ImportError("missing loader", name=name)
    if module is None:
        module = _ny_module_new(name)
    for k, v in (("__name__", name), ("__loader__", loader), ("__package__", getattr(spec, "parent", name.rpartition(".")[0])), ("__spec__", spec)):
        try:
            setattr(module, k, v)
        except AttributeError:
            pass
    if spec.submodule_search_locations is not None:
        try:
            module.__path__ = spec.submodule_search_locations
        except AttributeError:
            pass
    if getattr(spec, "has_location", False) and spec.origin is not None:
        try:
            module.__file__ = spec.origin
        except AttributeError:
            pass
    sysm.modules[name] = module
    try:
        if loader is not None and hasattr(loader, "exec_module"):
            loader.exec_module(module)
        elif loader is not None and hasattr(loader, "load_module"):
            loader.load_module(name)
    except BaseException:
        sysm.modules.pop(name, None)
        raise
    module = sysm.modules.pop(name)
    sysm.modules[name] = module
    # (round 83) a submodule is an attribute of its package, as CPython's
    # _find_and_load_unlocked makes it (zipimport's `import pkg.sub`)
    var parent = name.rpartition(".")[0]
    if parent:
        var pm = sysm.modules.get(parent)
        if pm is not None:
            try:
                setattr(pm, name.rpartition(".")[2], module)
            except AttributeError:
                pass
    return module

def _ny_mapping_snapshot(m):
    # (round 81) exec/eval's locals given as a mapping that is not a dict
    # (collections.OrderedDict, a UserDict...): its bindings, read through
    # its own keys() and __getitem__; the engines write back through its
    # __setitem__ what the code bound
    var d = {}
    for k in m.keys():
        d[k] = m[k]
    return d

def _ny_module_spec_attr(module, attr):
    # (round 81) __spec__ / __loader__ of a module the engines imported,
    # made when first read: importlib.machinery's ModuleSpec and loader for
    # its file (BuiltinImporter's for sys, os, math, builtins)
    if attr == "__dict__":
        # (round 83) module.__dict__: its live namespace, as vars(module)
        return vars(module)
    import importlib.machinery
    var m = importlib.machinery
    var name = getattr(module, "__name__", None)
    var f = getattr(module, "__file__", None)
    var spec = None
    if isinstance(f, str) and f:
        var kind = "package" if f.endswith("__init__.ny") else "file"
        spec = m._spec_for_path(name, f, kind)
        # a package's search locations are its __path__, as CPython's
        # module.__path__ is spec.submodule_search_locations (native
        # separators on Windows - they were rebuilt from __file__)
        var pp = getattr(module, "__path__", None)
        if kind == "package" and pp is not None:
            spec.submodule_search_locations = pp
    elif getattr(module, "__path__", None) is not None:
        var p = list(module.__path__)
        spec = m._spec_for_path(name, p[0] if p else "", "namespace")
    else:
        spec = m.ModuleSpec(name, m.BuiltinImporter, origin="built-in")
    try:
        setattr(module, "__spec__", spec)
        setattr(module, "__loader__", spec.loader)
    except AttributeError:
        pass
    return spec if attr == "__spec__" else spec.loader

# ── sys's Python members (round 80): the engines make the sys module and
# call _ny_sys_extend(sys) once ─────────────────────────────────────────
class _NySysAsyncGenHooks(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "asyncgen_hooks"
    _ny_names = ("firstiter", "finalizer")
    n_sequence_fields = 2
    n_fields = 2
    n_unnamed_fields = 0
_NySysAsyncGenHooks.__name__ = "asyncgen_hooks"
_NySysAsyncGenHooks.__qualname__ = "asyncgen_hooks"

class _NySysVersionInfo(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "sys.version_info"
    _ny_names = ("major", "minor", "micro", "releaselevel", "serial")
    n_sequence_fields = 5
    n_fields = 5
    n_unnamed_fields = 0
_NySysVersionInfo.__name__ = "version_info"
_NySysVersionInfo.__qualname__ = "version_info"

class _NySysHashInfo(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "sys.hash_info"
    _ny_names = ("width", "modulus", "inf", "nan", "imag", "algorithm", "hash_bits", "seed_bits", "cutoff")
    n_sequence_fields = 9
    n_fields = 9
    n_unnamed_fields = 0
_NySysHashInfo.__name__ = "hash_info"
_NySysHashInfo.__qualname__ = "hash_info"

class _NySysFloatInfo(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "sys.float_info"
    _ny_names = ("max", "max_exp", "max_10_exp", "min", "min_exp", "min_10_exp", "dig", "mant_dig",
                 "epsilon", "radix", "rounds")
    n_sequence_fields = 11
    n_fields = 11
    n_unnamed_fields = 0
_NySysFloatInfo.__name__ = "float_info"
_NySysFloatInfo.__qualname__ = "float_info"

class _NySysIntInfo(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "sys.int_info"
    _ny_names = ("bits_per_digit", "sizeof_digit", "default_max_str_digits", "str_digits_check_threshold")
    n_sequence_fields = 4
    n_fields = 4
    n_unnamed_fields = 0
_NySysIntInfo.__name__ = "int_info"
_NySysIntInfo.__qualname__ = "int_info"

class _NySysFlags(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "sys.flags"
    _ny_names = ("debug", "inspect", "interactive", "optimize", "dont_write_bytecode", "no_user_site",
                 "no_site", "ignore_environment", "verbose", "bytes_warning", "quiet", "hash_randomization",
                 "isolated", "dev_mode", "utf8_mode", "warn_default_encoding", "safe_path", "int_max_str_digits")
    n_sequence_fields = 18
    n_fields = 18
    n_unnamed_fields = 0
_NySysFlags.__name__ = "flags"
_NySysFlags.__qualname__ = "flags"

class _NySysNamespace:
    # sys.implementation (types.SimpleNamespace in CPython)
    def __init__(self, **kw):
        for k in kw:
            setattr(self, k, kw[k])
    def __repr__(self):
        var parts = []
        for k in self.__dict__:
            parts.append(k + "=" + repr(self.__dict__[k]))
        return "namespace(" + ", ".join(parts) + ")"
    def __eq__(self, other):
        return isinstance(other, _NySysNamespace) and self.__dict__ == other.__dict__

def _ny_getsizeof(obj, default=None):
    # sys.getsizeof (round 80): what CPython 3.11 on a 64-bit build reports
    # for the builtin types - a reasonable estimate of Nython's own use -
    # and __sizeof__() plus the 16-byte GC header for everything else
    if obj is None:
        return 16
    if isinstance(obj, bool):
        return 28
    if isinstance(obj, int):
        var n = abs(obj)
        var digits = 0
        while n > 0:
            n = n >> 30
            digits += 1
        return 24 + 4 * (digits if digits > 0 else 1) if obj != 0 else 28
    if isinstance(obj, float):
        return 24
    if isinstance(obj, str):
        var big = 0
        for c in obj:
            var o = ord(c)
            if o > big:
                big = o
        if big < 128:
            return 48 + len(obj) + 1
        if big < 256:
            return 72 + len(obj) + 1
        if big < 65536:
            return 72 + 2 * (len(obj) + 1)
        return 72 + 4 * (len(obj) + 1)
    if isinstance(obj, bytes):
        return 33 + len(obj)
    if isinstance(obj, bytearray):
        return 56 + len(obj) + (1 if len(obj) else 0)
    if isinstance(obj, tuple):
        return 40 + 8 * len(obj)
    if isinstance(obj, list):
        return 56 + 8 * len(obj)
    if isinstance(obj, (set, frozenset)):
        var size = 8
        while size * 3 <= len(obj) * 5:
            size = size * 4
        return 88 + 16 * size
    if isinstance(obj, dict):
        if len(obj) == 0:
            return 64
        var cap = 8
        while cap * 2 // 3 < len(obj):
            cap = cap * 2
        var ix = 1 if cap <= 128 else (2 if cap <= 32768 else 4)
        return 96 + ix * cap + 24 * (cap * 2 // 3)
    var f = getattr(obj, "__sizeof__", None)
    if f is not None:
        try:
            var r = f()
            if not isinstance(r, int):
                raise TypeError("an integer is required")
            if r < 0:
                raise ValueError("__sizeof__() should return >= 0")
            return r + (32 if hasattr(obj, "__dict__") else 16)
        except (TypeError, ValueError):
            if default is not None:
                return default
            raise
    if default is not None:
        return default
    return 48

def _ny_getrecursionlimit():
    return _ny_recursion_limit()

def _ny_setrecursionlimit(limit):
    if not isinstance(limit, int) or isinstance(limit, bool):
        raise TypeError("'" + type(limit).__name__ + "' object cannot be interpreted as an integer")
    if limit < 1:
        raise ValueError("recursion limit must be greater or equal than 1")
    var depth = len(_ny_stack())
    if limit <= depth:
        raise RecursionError("cannot set the recursion limit to " + str(limit) + " at the recursion depth " +
                             str(depth) + ": the limit is too low")
    _ny_recursion_limit(limit)

def _ny_intern(s):
    if type(s) is not str:
        raise TypeError("intern() argument must be str, not " + type(s).__name__)
    return s

def _ny_sys_call_tracing(func, args):
    return func(*args)

def _ny_getswitchinterval():
    return _ny_sys_info("switch_interval")

def _ny_setswitchinterval(interval):
    # the GIL's hand-over interval (round 80; NyConc.cpp)
    if isinstance(interval, str) or not (isinstance(interval, (int, float)) or hasattr(interval, "__float__")):
        raise TypeError("must be real number, not " + type(interval).__name__)
    var v = float(interval)
    if not (v > 0):
        raise ValueError("switch interval must be strictly positive")
    _ny_sys_info("switch_interval", v)

# ── sys's remaining members (round 85) ──────────────────────────────────
def _ny_sys_index(v):
    if isinstance(v, int):
        return int(v)
    if hasattr(type(v), "__index__"):
        return v.__index__()
    raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")

def _ny_get_int_max_str_digits():
    # the limit on int <-> decimal str conversions (CPython 3.11, gh-95778):
    # 4300 digits unless -X int_max_str_digits / PYTHONINTMAXSTRDIGITS said
    # otherwise; 0 is no limit (both engines check it: NyFormat.hpp)
    return _ny_sys_info("int_max_str_digits")

def _ny_set_int_max_str_digits(maxdigits):
    var n = _ny_sys_index(maxdigits)
    if n != 0 and n < 640:
        raise ValueError("maxdigits must be 0 or larger than 640")
    _ny_sys_info("int_max_str_digits", n)

class _NyUnraisableHookArgs(_NyStructSeq):
    # what sys.unraisablehook is given (CPython's UnraisableHookArgs; not a
    # sys attribute there either)
    __module__ = "builtins"
    _ny_qual = "UnraisableHookArgs"
    _ny_names = ("exc_type", "exc_value", "exc_traceback", "err_msg", "object")
    n_sequence_fields = 5
    n_fields = 5
    n_unnamed_fields = 0
_NyUnraisableHookArgs.__name__ = "UnraisableHookArgs"
_NyUnraisableHookArgs.__qualname__ = "UnraisableHookArgs"

def _ny_unraisablehook(unraisable):
    # sys.unraisablehook / sys.__unraisablehook__: CPython's default report
    # on sys.stderr ("Exception ignored in: <obj>", then the traceback)
    var err = None
    if _ny_sys_ref[0] is not None:
        err = getattr(_ny_sys_ref[0], "stderr", None)
    if err is None:
        err = _ny_stderr
    var obj = unraisable.object
    var msg = unraisable.err_msg
    var head = ""
    if obj is not None:
        var r = None
        try:
            r = repr(obj)
        except BaseException:
            r = "<object repr() failed>"
        head = (msg if msg is not None else "Exception ignored in") + ": " + r + "\n"
    elif msg is not None:
        head = msg + "\n"
    var v = unraisable.exc_value
    var body = ""
    if isinstance(v, BaseException):
        if unraisable.exc_traceback is not None and getattr(v, "__traceback__", None) is None:
            v.__traceback__ = unraisable.exc_traceback
        body = _ny_format_exc(v, True, [], {})
    elif unraisable.exc_type is not None:
        body = unraisable.exc_type.__name__ + ": " + str(v) + "\n"
    err.write(head + body)
    try:
        err.flush()
    except BaseException:
        pass

def _ny_unraisable(exc, err_msg, obj):
    # (round 85) the engines' "Exception ignored in ..." reports (a __del__,
    # a weakref callback, a generator's finally) go through the program's
    # sys.unraisablehook once it has set one: True when that was called,
    # False when the engine prints its own report (the default hook)
    var s = _ny_sys_ref[0]
    if s is None:
        return False
    var h = getattr(s, "unraisablehook", None)
    if _ny_audit_hooks and _ny_audit_unraisable(h, exc, err_msg, obj):   # round 86
        return True
    if h is _ny_unraisablehook or h is None:
        return False
    try:
        h(_NyUnraisableHookArgs((type(exc), exc, getattr(exc, "__traceback__", None), err_msg, obj)))
    except BaseException as e2:
        _ny_unraisablehook(_NyUnraisableHookArgs((type(e2), e2, getattr(e2, "__traceback__", None),
                                                  "Exception ignored in sys.unraisablehook", h)))
    return True

_ny_sys_state = {"dlopenflags": 2, "coro_depth": 0}

def _ny_getdlopenflags():
    # the flags ctypes and the import system would give dlopen (RTLD_NOW)
    return _ny_sys_state["dlopenflags"]

def _ny_setdlopenflags(flags):
    _ny_sys_state["dlopenflags"] = _ny_sys_index(flags)

def _ny_get_coroutine_origin_tracking_depth():
    return _ny_sys_state["coro_depth"]

def _ny_set_coroutine_origin_tracking_depth(depth):
    # coroutines made while it is > 0 record where they were made in
    # cr_origin: ((filename, lineno, function), ...), innermost first
    var n = _ny_sys_index(depth)
    if n < 0:
        raise ValueError("depth must be >= 0")
    _ny_sys_state["coro_depth"] = n

def _ny_getallocatedblocks():
    # the objects the engine's memory manager holds now (its collectors'
    # tracked objects and live strings - CPython counts its allocator's blocks)
    return _ny_sys_info("allocated_blocks")

class _NySysThreadInfo(_NyStructSeq):
    __module__ = "sys"
    _ny_qual = "sys.thread_info"
    _ny_names = ("name", "lock", "version")
    n_sequence_fields = 3
    n_fields = 3
    n_unnamed_fields = 0
_NySysThreadInfo.__name__ = "thread_info"
_NySysThreadInfo.__qualname__ = "thread_info"

def _ny_stdlib_names():
    # sys.stdlib_module_names (round 81): the modules and packages of the
    # standard library directory (lib/), and the ones the engines make
    var names = set(("builtins", "math", "os", "sys"))
    # the library directory: the one of the engines' search path holding
    # the standard library's own files
    var lib = _ny_sys_info("prefix") + "/lib"
    for d in _ny_sys_info("path")[1:]:
        if d and os_isfile(d + "/builtins.ny") and os_isfile(d + "/abc.ny"):
            lib = d
            break
    try:
        for e in os_listdir(lib):
            if e.endswith(".ny"):
                names.add(e[:-3])
            elif not e.startswith(".") and os_isfile(lib + "/" + e + "/__init__.ny"):
                names.add(e)
    except OSError:
        pass
    return frozenset(names)

def _ny_displayhook(value):
    # sys.displayhook / sys.__displayhook__ (round 81): what the prompt does
    # with an expression's value - None is not shown; anything else is
    # printed as its repr on sys.stdout and kept in `_`
    if value is None:
        return None
    _ny_main_set("_", None)
    var text = repr(value)
    var s = _ny_sys_ref[0]
    var out = getattr(s, "stdout", None) if s is not None else None
    if out is None:
        print(text)
    else:
        out.write(text + "\n")
    _ny_main_set("_", value)
    return None

def _ny_prompt_display(value):
    # (round 81) the interactive prompt (-i, the REPL) calls this for an
    # expression's value: False while sys.displayhook is the default (the
    # engines show it themselves), else the program's hook was called
    var s = _ny_sys_ref[0]
    if s is None:
        return False
    var h = getattr(s, "displayhook", None)
    if h is _ny_displayhook:
        return False
    if h is None:
        raise RuntimeError("lost sys.displayhook")
    h(value)
    return True

def _ny_single_display(value):
    # (round 87) an expression statement's value in code compiled in
    # "single" mode (NySingleMode.hpp): sys.displayhook shows it, as
    # CPython's PRINT_EXPR does - None too (the hook ignores it)
    var s = _ny_sys_ref[0]
    if s is None:
        return _ny_displayhook(value)
    var h = getattr(s, "displayhook", None)
    if h is None:
        raise RuntimeError("lost sys.displayhook")
    h(value)
    return None

def _ny_sys_extend(sysmod):
    # the Python-level members of sys: the language level Nython implements
    # (the standard library's ports follow CPython 3.12) in version_info,
    # Nython's own version in sys.implementation, as PyPy does
    var vi = _NySysVersionInfo((3, 12, 0, "final", 0))
    sysmod.version_info = vi
    sysmod.set_asyncgen_hooks = _ny_set_asyncgen_hooks     # round 82
    sysmod.get_asyncgen_hooks = _ny_get_asyncgen_hooks
    sysmod.hexversion = 0x030C00F0
    sysmod.api_version = 1013
    sysmod.implementation = _NySysNamespace(name="nython", cache_tag=None,
                                            version=_NySysVersionInfo((0, 2, 1, "final", 0)),
                                            hexversion=0x000201F0)
    sysmod.hash_info = _NySysHashInfo((64, 2305843009213693951, 314159, 0, 1000003, "fnv", 64, 0, 0))
    sysmod.float_info = _NySysFloatInfo((1.7976931348623157e+308, 1024, 308, 2.2250738585072014e-308,
                                          -1021, -307, 15, 53, 2.220446049250313e-16, 2, 1))
    sysmod.int_info = _NySysIntInfo((32, 4, 4300, 640))   # (round 85: the limit is enforced)
    sysmod.flags = _NySysFlags(tuple(_ny_sys_info("flags")))
    sysmod.float_repr_style = "short"
    sysmod.maxunicode = 1114111
    sysmod.dont_write_bytecode = True
    sysmod.path = _ny_sys_info("path")
    # round 81: the import statement consults these (_ny_import_via_hooks)
    sysmod.meta_path = [_NyNativeFinder("builtin"), _NyNativeFinder("path")]
    sysmod.path_hooks = []
    sysmod.path_importer_cache = {}
    sysmod.stdlib_module_names = _ny_stdlib_names()
    sysmod.getrefcount = _ny_getrefcount
    sysmod.displayhook = _ny_displayhook
    sysmod.__displayhook__ = _ny_displayhook
    sysmod.builtin_module_names = ("builtins", "math", "os", "sys")
    sysmod.orig_argv = _ny_sys_info("orig_argv")
    sysmod.modules = _ny_modules()
    sysmod.getrecursionlimit = _ny_getrecursionlimit
    sysmod.setrecursionlimit = _ny_setrecursionlimit
    sysmod.getsizeof = _ny_getsizeof
    sysmod.intern = _ny_intern
    sysmod.call_tracing = _ny_sys_call_tracing
    sysmod.getdefaultencoding = lambda: "utf-8"
    sysmod.getfilesystemencoding = lambda: "utf-8"
    sysmod.getfilesystemencodeerrors = lambda: "surrogateescape"
    sysmod.is_finalizing = lambda: False
    sysmod.copyright = "Copyright (c) the Nython authors."
    sysmod.excepthook = _ny_excepthook
    sysmod.__excepthook__ = _ny_excepthook
    sysmod.audit = _ny_sys_audit                 # round 84 (PEP 578)
    sysmod.addaudithook = _ny_sys_addaudithook
    sysmod._getframemodulename = _ny_getframemodulename   # round 86
    sysmod._current_frames = _ny_current_frames
    sysmod._current_exceptions = _ny_current_exceptions
    sysmod.getswitchinterval = _ny_getswitchinterval
    sysmod.setswitchinterval = _ny_setswitchinterval
    # round 85
    sysmod.get_int_max_str_digits = _ny_get_int_max_str_digits
    sysmod.set_int_max_str_digits = _ny_set_int_max_str_digits
    sysmod.unraisablehook = _ny_unraisablehook
    sysmod.__unraisablehook__ = _ny_unraisablehook
    sysmod.getallocatedblocks = _ny_getallocatedblocks
    sysmod.get_coroutine_origin_tracking_depth = _ny_get_coroutine_origin_tracking_depth
    sysmod.set_coroutine_origin_tracking_depth = _ny_set_coroutine_origin_tracking_depth
    if os_name != "nt":
        sysmod.getdlopenflags = _ny_getdlopenflags
        sysmod.setdlopenflags = _ny_setdlopenflags
        sysmod.abiflags = ""
        sysmod.thread_info = _NySysThreadInfo(("pthread", "mutex+cond", _ny_sys_info("libc_version")))
    else:
        sysmod.thread_info = _NySysThreadInfo(("nt", None, None))
    sysmod.pycache_prefix = None
    # where the standard library is: <prefix>/lib; (round 87) a virtual
    # environment's directory is sys.prefix, the installation's
    # sys.base_prefix (src/NySite.cpp)
    var root = _ny_sys_info("prefix")
    var venv = _ny_sys_info("venv")
    sysmod.prefix = root if venv[0] is None else venv[0]
    sysmod.exec_prefix = sysmod.prefix
    sysmod.base_prefix = root
    sysmod.base_exec_prefix = root
    sysmod._base_executable = venv[2]
    sysmod.platlibdir = "lib"
    sysmod.__name__ = "sys"
    _ny_sys_ref[0] = sysmod
    var m = _ny_modules()
    if "sys" not in m:
        m["sys"] = sysmod

__debug__ = _ny_sys_info("flags")[3] == 0

# threading._register_atexit (round 80): run when the program ends, before
# the engines wait for the non-daemon threads (CPython's
# threading._shutdown), last registered first
_ny_threading_atexits = []
_ny_threading_atexit_done = [False]

def _ny_run_threading_atexit():
    _ny_threading_atexit_done[0] = True
    while len(_ny_threading_atexits) > 0:
        var h = _ny_threading_atexits.pop()
        try:
            h()
        except BaseException as e:
            _ny_stderr.write("Exception ignored in threading atexit callback: " + repr(h) + "\n" + _ny_format_exc(e, True, [], {}))

# os.environ (round 80): CPython's os._Environ - a mapping over a copy of the
# environment that writes through: setting or deleting a key calls putenv /
# unsetenv, so os.getenv and child processes see it. One object for every
# `import os`.
def _ny_fs_encode(s):
    # os.fsencode's codec (surrogateescape when the codecs have it)
    try:
        return s.encode("utf-8", "surrogateescape")
    except LookupError:
        return s.encode("utf-8")

def _ny_fs_decode(b):
    try:
        return b.decode("utf-8", "surrogateescape")
    except LookupError:
        return b.decode("utf-8", "replace")

class _NyEnviron:
    def __init__(self, data, encoded=False):
        self._data = data
        self._encoded = encoded
    def _key(self, key):
        if self._encoded:
            if not isinstance(key, bytes):
                raise TypeError("bytes expected, not " + type(key).__name__)
            return _ny_fs_decode(key)
        if not isinstance(key, str):
            raise TypeError("str expected, not " + type(key).__name__)
        return key
    def _val(self, value):
        if self._encoded:
            if not isinstance(value, bytes):
                raise TypeError("bytes expected, not " + type(value).__name__)
            return _ny_fs_decode(value)
        if not isinstance(value, str):
            raise TypeError("str expected, not " + type(value).__name__)
        return value
    def _out(self, s):
        return _ny_fs_encode(s) if self._encoded else s
    def __getitem__(self, key):
        var k = self._key(key)
        if k not in self._data:
            raise KeyError(key)
        return self._out(self._data[k])
    def __setitem__(self, key, value):
        var k = self._key(key)
        var v = self._val(value)
        if k == "" or "=" in k:
            raise ValueError("illegal environment variable name")
        if _ny_audit_hooks:   # round 86: os.putenv's
            _ny_audit_fire("os.putenv", (_ny_audit_fsenc(k), _ny_audit_fsenc(v)))
        os_setenv(k, v)
        self._data[k] = v
    def __delitem__(self, key):
        var k = self._key(key)
        if k not in self._data:
            raise KeyError(key)
        if _ny_audit_hooks:   # round 86: os.unsetenv's
            _ny_audit_fire("os.unsetenv", (_ny_audit_fsenc(k),))
        os_unsetenv(k)
        del self._data[k]
    def __iter__(self):
        for k in list(self._data):
            yield self._out(k)
    def __len__(self):
        return len(self._data)
    def __contains__(self, key):
        try:
            return self._key(key) in self._data
        except TypeError:
            return False
    def keys(self):
        return [self._out(k) for k in self._data]
    def values(self):
        return [self._out(self._data[k]) for k in self._data]
    def items(self):
        return [(self._out(k), self._out(self._data[k])) for k in self._data]
    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default
    def setdefault(self, key, value=None):
        if key not in self:
            self[key] = value
        return self[key]
    def pop(self, key, *default):
        if key in self:
            var v = self[key]
            del self[key]
            return v
        if default:
            return default[0]
        raise KeyError(key)
    def popitem(self):
        for k in self._data:
            var v = self._out(self._data[k])
            del self[self._out(k)]
            return (self._out(k), v)
        raise KeyError("popitem(): dictionary is empty")
    def clear(self):
        for k in list(self._data):
            del self[self._out(k)]
    def update(self, other=(), **kw):
        if hasattr(other, "keys"):
            for k in other.keys():
                self[k] = other[k]
        else:
            for kv in other:
                self[kv[0]] = kv[1]
        for k in kw:
            self[k] = kw[k]
    def copy(self):
        return dict(self.items())
    def __eq__(self, other):
        if isinstance(other, _NyEnviron):
            return self._data == other._data and self._encoded == other._encoded
        if isinstance(other, dict):
            return dict(self.items()) == other
        return NotImplemented
    def __ne__(self, other):
        var r = self.__eq__(other)
        return r if r is NotImplemented else not r
    __hash__ = None
    def __or__(self, other):
        if not hasattr(other, "keys"):
            return NotImplemented
        var d = dict(self.items())
        d.update(other)
        return d
    def __ror__(self, other):
        if not hasattr(other, "keys"):
            return NotImplemented
        var d = dict(other)
        d.update(self.items())
        return d
    def __ior__(self, other):
        self.update(other)
        return self
    def __repr__(self):
        var parts = []
        for k in self._data:
            parts.append(repr(self._out(k)) + ": " + repr(self._out(self._data[k])))
        return ("environb({" if self._encoded else "environ({") + ", ".join(parts) + "})"
_NyEnviron.__name__ = "_Environ"
_NyEnviron.__qualname__ = "_Environ"
_NyEnviron.__module__ = "os"

_ny_environ_obj = []
def _ny_os_environ():
    if not _ny_environ_obj:
        var data = os_environ()
        var env = _NyEnviron(data)
        _ny_environ_obj.append(env)
        _ny_environ_obj.append(_NyEnviron(data, True))
    return _ny_environ_obj[0]
def _ny_os_environb():
    _ny_os_environ()
    return _ny_environ_obj[1]


)NYPRELUDE";
}

// The mirror classes of the builtin types (round 77): what a class deriving
// from int, float, str, bytes, bytearray, list, dict, set, frozenset or tuple
// finds where the type stands in its MRO (nyrt::builtin_mirror), and the
// live view obj.__dict__ / vars(obj) gives. The text is in chunks ("#@ name"
// lines): "base" (helpers), one per type, "dictview", "os" (round 80: the
// rest of Python's os, loaded at the first `import os`). Both engines run a
// type's chunk (after "base") the first time a class derives from the type
// or one of its dunders is read (int.__new__), and "dictview" (after "dict")
// at the first instance __dict__ read - not at startup: a program that never
// does pays nothing for them.
inline const char* builtin_mirrors_source() {
    return R"NYMIRRORS(
# ── classes deriving from builtin types (round 77) ───────────────────────
# `class MyInt(int)`, `class Stack(list)`, `class Config(dict)`... : an
# instance holds a value of the type, its payload (the hidden field
# __ny_payload__, which _ny_payload(x) reads - x itself for anything else).
# Where the builtin type stands in such a class's MRO the engines put its
# mirror class below (_NyB_int for int ...), so the type's operators,
# protocol methods and methods answer for the instance through the payload,
# a subclass's own definitions coming first, and int.__new__(cls, v),
# list.__init__(self, it), dict.__setitem__(self, k, v), int.__repr__(x)
# ... are the mirror's functions. Results are plain values of the type
# (MyStr("a").upper() is a str), as in Python. The type's __new__ makes the
# payload from the arguments (int, float, str, bytes, tuple, frozenset); a
# mutable type's starts empty and __init__ fills it (list, dict, set,
# bytearray). As in CPython, the payload's own methods (dict.update ...)
# do not call a subclass's __setitem__.

#@ base
def _ny_bdelegate(name):
    # a method of the type, called on the payload
    def method(self, *args, **kw):
        return getattr(_ny_payload(self), name)(*args, **kw)
    method.__name__ = name
    method.__qualname__ = name
    return method

def _ny_bmethods(cls, names):
    for n in names.split():
        setattr(cls, n, _ny_bdelegate(n))

def _ny_bgeneric(cls, item):
    return _NyGenericAlias(cls, item)

def _ny_bformat(self, spec):
    if spec == "":
        return str(self)
    return format(_ny_payload(self), spec)

# A plain value's own dunders (round 78): (5).__add__(3) is the type's,
# bound to 5 (the engines look in _NyV_<type> first, then the mirror). int's
# and float's binary operators take only their own kinds of operand and
# give NotImplemented for any other - (5).__add__("x"), (5).__eq__(5.0) - as
# Python's do; the mirror's versions compute (a subclass instance's, whose
# engine has no reflected fallback to a plain float or str).
def _ny_vdecline(f, ok):
    def method(self, o, *rest):
        if not isinstance(o, ok):
            return NotImplemented
        return f(self, o, *rest)
    method.__name__ = f.__name__
    method.__qualname__ = f.__name__
    return method

def _ny_vnum(vcls, bcls, ok, names):
    for n in names.split():
        if hasattr(bcls, n):
            setattr(vcls, n, _ny_vdecline(getattr(bcls, n), ok))

#@ int
class _NyB_int:
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, int, int(*args, **kw))
    def __repr__(self):
        return repr(_ny_payload(self))
    def __format__(self, spec):
        return _ny_bformat(self, spec)
    def __hash__(self):
        return hash(_ny_payload(self))
    def __bool__(self):
        return _ny_payload(self) != 0
    def __index__(self):
        return _ny_payload(self)
    def __int__(self):
        return _ny_payload(self)
    def __float__(self):
        return float(_ny_payload(self))
    def __complex__(self):
        return complex(_ny_payload(self))
    def __getnewargs__(self):
        return (_ny_payload(self),)
    def __eq__(self, o):
        return _ny_payload(self) == o
    def __ne__(self, o):
        return _ny_payload(self) != o
    def __lt__(self, o):
        return _ny_payload(self) < o
    def __le__(self, o):
        return _ny_payload(self) <= o
    def __gt__(self, o):
        return _ny_payload(self) > o
    def __ge__(self, o):
        return _ny_payload(self) >= o
    def __add__(self, o):
        return _ny_payload(self) + o
    def __radd__(self, o):
        return o + _ny_payload(self)
    def __sub__(self, o):
        return _ny_payload(self) - o
    def __rsub__(self, o):
        return o - _ny_payload(self)
    def __mul__(self, o):
        return _ny_payload(self) * o
    def __rmul__(self, o):
        return o * _ny_payload(self)
    def __truediv__(self, o):
        return _ny_payload(self) / o
    def __rtruediv__(self, o):
        return o / _ny_payload(self)
    def __floordiv__(self, o):
        return _ny_payload(self) // o
    def __rfloordiv__(self, o):
        return o // _ny_payload(self)
    def __mod__(self, o):
        return _ny_payload(self) % o
    def __rmod__(self, o):
        if isinstance(o, str) or isinstance(o, bytes) or isinstance(o, bytearray):
            return o % (self,)      # "%s" % x: str.__mod__'s, x itself the argument
        return o % _ny_payload(self)
    def __divmod__(self, o):
        return divmod(_ny_payload(self), o)
    def __rdivmod__(self, o):
        return divmod(o, _ny_payload(self))
    def __pow__(self, o, m=None):
        if m is None:
            return _ny_payload(self) ** o
        return pow(_ny_payload(self), o, m)
    def __rpow__(self, o):
        return o ** _ny_payload(self)
    def __lshift__(self, o):
        return _ny_payload(self) << o
    def __rlshift__(self, o):
        return o << _ny_payload(self)
    def __rshift__(self, o):
        return _ny_payload(self) >> o
    def __rrshift__(self, o):
        return o >> _ny_payload(self)
    def __and__(self, o):
        return _ny_payload(self) & o
    def __rand__(self, o):
        return o & _ny_payload(self)
    def __or__(self, o):
        return _ny_payload(self) | o
    def __ror__(self, o):
        return o | _ny_payload(self)
    def __xor__(self, o):
        return _ny_payload(self) ^ o
    def __rxor__(self, o):
        return o ^ _ny_payload(self)
    def __neg__(self):
        return -_ny_payload(self)
    def __pos__(self):
        return _ny_payload(self)
    def __abs__(self):
        return abs(_ny_payload(self))
    def __invert__(self):
        return ~_ny_payload(self)
    def __round__(self, n=None):
        if n is None:
            return round(_ny_payload(self))
        return round(_ny_payload(self), n)
    def __trunc__(self):
        return _ny_payload(self)
    def __floor__(self):
        return _ny_payload(self)
    def __ceil__(self):
        return _ny_payload(self)
    @property
    def real(self):
        return _ny_payload(self)
    @property
    def imag(self):
        return 0
    @property
    def numerator(self):
        return _ny_payload(self)
    @property
    def denominator(self):
        return 1
    @classmethod
    def from_bytes(cls, *args, **kw):
        return cls(int.from_bytes(*args, **kw))
_ny_bmethods(_NyB_int, "as_integer_ratio bit_count bit_length conjugate to_bytes is_integer")
class _NyV_int:
    pass
_ny_vnum(_NyV_int, _NyB_int, int, "__add__ __radd__ __sub__ __rsub__ __mul__ __rmul__ __truediv__ __rtruediv__ __floordiv__ __rfloordiv__ __mod__ __rmod__ __divmod__ __rdivmod__ __pow__ __rpow__ __lshift__ __rlshift__ __rshift__ __rrshift__ __and__ __rand__ __or__ __ror__ __xor__ __rxor__ __eq__ __ne__ __lt__ __le__ __gt__ __ge__")

#@ float
class _NyB_float:
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, float, float(*args, **kw))
    def __repr__(self):
        return repr(_ny_payload(self))
    def __format__(self, spec):
        return _ny_bformat(self, spec)
    def __hash__(self):
        return hash(_ny_payload(self))
    def __bool__(self):
        return _ny_payload(self) != 0
    def __int__(self):
        return int(_ny_payload(self))
    def __float__(self):
        return _ny_payload(self)
    def __complex__(self):
        return complex(_ny_payload(self))
    def __getnewargs__(self):
        return (_ny_payload(self),)
    def __eq__(self, o):
        return _ny_payload(self) == o
    def __ne__(self, o):
        return _ny_payload(self) != o
    def __lt__(self, o):
        return _ny_payload(self) < o
    def __le__(self, o):
        return _ny_payload(self) <= o
    def __gt__(self, o):
        return _ny_payload(self) > o
    def __ge__(self, o):
        return _ny_payload(self) >= o
    def __add__(self, o):
        return _ny_payload(self) + o
    def __radd__(self, o):
        return o + _ny_payload(self)
    def __sub__(self, o):
        return _ny_payload(self) - o
    def __rsub__(self, o):
        return o - _ny_payload(self)
    def __mul__(self, o):
        return _ny_payload(self) * o
    def __rmul__(self, o):
        return o * _ny_payload(self)
    def __truediv__(self, o):
        return _ny_payload(self) / o
    def __rtruediv__(self, o):
        return o / _ny_payload(self)
    def __floordiv__(self, o):
        return _ny_payload(self) // o
    def __rfloordiv__(self, o):
        return o // _ny_payload(self)
    def __mod__(self, o):
        return _ny_payload(self) % o
    def __rmod__(self, o):
        if isinstance(o, str) or isinstance(o, bytes) or isinstance(o, bytearray):
            return o % (self,)      # "%s" % x: str.__mod__'s, x itself the argument
        return o % _ny_payload(self)
    def __divmod__(self, o):
        return divmod(_ny_payload(self), o)
    def __rdivmod__(self, o):
        return divmod(o, _ny_payload(self))
    def __pow__(self, o, m=None):
        if m is None:
            return _ny_payload(self) ** o
        return pow(_ny_payload(self), o, m)
    def __rpow__(self, o):
        return o ** _ny_payload(self)
    def __neg__(self):
        return -_ny_payload(self)
    def __pos__(self):
        return _ny_payload(self)
    def __abs__(self):
        return abs(_ny_payload(self))
    def __round__(self, n=None):
        if n is None:
            return round(_ny_payload(self))
        return round(_ny_payload(self), n)
    def __trunc__(self):
        return int(_ny_payload(self))
    def __floor__(self):
        var p = _ny_payload(self)
        var i = int(p)
        return i if i <= p else i - 1
    def __ceil__(self):
        var p = _ny_payload(self)
        var i = int(p)
        return i if i >= p else i + 1
    @property
    def real(self):
        return _ny_payload(self)
    @property
    def imag(self):
        return 0.0
    @classmethod
    def fromhex(cls, s):
        return cls(float.fromhex(s))
_ny_bmethods(_NyB_float, "as_integer_ratio conjugate hex is_integer")
class _NyV_float:
    pass
_ny_vnum(_NyV_float, _NyB_float, (int, float), "__add__ __radd__ __sub__ __rsub__ __mul__ __rmul__ __truediv__ __rtruediv__ __floordiv__ __rfloordiv__ __mod__ __rmod__ __divmod__ __rdivmod__ __pow__ __rpow__ __eq__ __ne__ __lt__ __le__ __gt__ __ge__")

# str, bytes, bytearray, tuple, list: the sequence protocol
#@ str
class _NyB_str:
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, str, str(*args, **kw))
    def __str__(self):
        return _ny_payload(self)
    def __repr__(self):
        return repr(_ny_payload(self))
    def __format__(self, spec):
        return format(_ny_payload(self), spec)
    def __hash__(self):
        return hash(_ny_payload(self))
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __contains__(self, x):
        return _ny_payload(x) in _ny_payload(self)
    def __getitem__(self, i):
        return _ny_payload(self)[i]
    def __getnewargs__(self):
        return (_ny_payload(self),)
    def __eq__(self, o):
        return _ny_payload(self) == o
    def __ne__(self, o):
        return _ny_payload(self) != o
    def __lt__(self, o):
        return _ny_payload(self) < o
    def __le__(self, o):
        return _ny_payload(self) <= o
    def __gt__(self, o):
        return _ny_payload(self) > o
    def __ge__(self, o):
        return _ny_payload(self) >= o
    def __add__(self, o):
        return _ny_payload(self) + _ny_payload(o)
    def __radd__(self, o):
        return _ny_payload(o) + _ny_payload(self)
    def __mul__(self, n):
        return _ny_payload(self) * n
    def __rmul__(self, n):
        return _ny_payload(self) * n
    def __mod__(self, args):
        return _ny_payload(self) % args
    def __rmod__(self, o):
        if isinstance(o, str) or isinstance(o, bytes) or isinstance(o, bytearray):
            return o % (self,)      # "%s" % x: str.__mod__'s, x itself the argument
        return o % _ny_payload(self)
    @staticmethod
    def maketrans(*args):
        return str.maketrans(*args)
_ny_bmethods(_NyB_str, "capitalize casefold center count encode endswith expandtabs find format format_map index isalnum isalpha isascii isdecimal isdigit isidentifier islower isnumeric isprintable isspace istitle isupper join ljust lower lstrip partition removeprefix removesuffix replace rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill")

#@ bytes
class _NyB_bytes:
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, bytes, bytes(*args, **kw))
    def __bytes__(self):
        return _ny_payload(self)
    def __repr__(self):
        return repr(_ny_payload(self))
    def __hash__(self):
        return hash(_ny_payload(self))
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __contains__(self, x):
        return _ny_payload(x) in _ny_payload(self)
    def __getitem__(self, i):
        return _ny_payload(self)[i]
    def __getnewargs__(self):
        return (_ny_payload(self),)
    def __eq__(self, o):
        return _ny_payload(self) == o
    def __ne__(self, o):
        return _ny_payload(self) != o
    def __lt__(self, o):
        return _ny_payload(self) < o
    def __le__(self, o):
        return _ny_payload(self) <= o
    def __gt__(self, o):
        return _ny_payload(self) > o
    def __ge__(self, o):
        return _ny_payload(self) >= o
    def __add__(self, o):
        return _ny_payload(self) + _ny_payload(o)
    def __radd__(self, o):
        return _ny_payload(o) + _ny_payload(self)
    def __mul__(self, n):
        return _ny_payload(self) * n
    def __rmul__(self, n):
        return _ny_payload(self) * n
    def __mod__(self, args):
        return _ny_payload(self) % args
    @classmethod
    def fromhex(cls, s):
        return cls(bytes.fromhex(s))
    @staticmethod
    def maketrans(*args):
        return bytes.maketrans(*args)
_ny_bmethods(_NyB_bytes, "capitalize center count decode endswith expandtabs find hex index isalnum isalpha isascii isdigit islower isspace istitle isupper join ljust lower lstrip partition removeprefix removesuffix replace rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill")

#@ bytearray
class _NyB_bytearray:
    __hash__ = None
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, bytearray, bytearray())
    def __init__(self, *args, **kw):
        var p = _ny_payload(self)
        p[:] = bytearray(*args, **kw)
    def __repr__(self):
        return type(self).__name__ + "(" + repr(bytes(_ny_payload(self))) + ")"
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __contains__(self, x):
        return _ny_payload(x) in _ny_payload(self)
    def __getitem__(self, i):
        return _ny_payload(self)[i]
    def __setitem__(self, i, v):
        var p = _ny_payload(self)
        p[i] = v
    def __delitem__(self, i):
        var p = _ny_payload(self)
        del p[i]
    def __eq__(self, o):
        return _ny_payload(self) == o
    def __ne__(self, o):
        return _ny_payload(self) != o
    def __lt__(self, o):
        return _ny_payload(self) < o
    def __le__(self, o):
        return _ny_payload(self) <= o
    def __gt__(self, o):
        return _ny_payload(self) > o
    def __ge__(self, o):
        return _ny_payload(self) >= o
    def __add__(self, o):
        return _ny_payload(self) + _ny_payload(o)
    def __iadd__(self, o):
        _ny_payload(self).extend(_ny_payload(o))
        return self
    def __mul__(self, n):
        return _ny_payload(self) * n
    def __rmul__(self, n):
        return _ny_payload(self) * n
    @classmethod
    def fromhex(cls, s):
        return cls(bytearray.fromhex(s))
_ny_bmethods(_NyB_bytearray, "append capitalize center clear copy count decode endswith expandtabs extend find hex index insert isalnum isalpha isascii isdigit islower isspace istitle isupper join ljust lower lstrip partition pop remove removeprefix removesuffix replace reverse rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill")

#@ tuple
class _NyB_tuple:
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, tuple, tuple(*args, **kw))
    def __repr__(self):
        return repr(_ny_payload(self))
    def __hash__(self):
        return hash(_ny_payload(self))
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __contains__(self, x):
        return x in _ny_payload(self)
    def __getitem__(self, i):
        return _ny_payload(self)[i]
    def __getnewargs__(self):
        return (_ny_payload(self),)
    def __eq__(self, o):
        return _ny_payload(self) == _ny_payload(o)
    def __ne__(self, o):
        return _ny_payload(self) != _ny_payload(o)
    def __lt__(self, o):
        return _ny_payload(self) < _ny_payload(o)
    def __le__(self, o):
        return _ny_payload(self) <= _ny_payload(o)
    def __gt__(self, o):
        return _ny_payload(self) > _ny_payload(o)
    def __ge__(self, o):
        return _ny_payload(self) >= _ny_payload(o)
    def __add__(self, o):
        return _ny_payload(self) + _ny_payload(o)
    def __radd__(self, o):
        return _ny_payload(o) + _ny_payload(self)
    def __mul__(self, n):
        return _ny_payload(self) * n
    def __rmul__(self, n):
        return _ny_payload(self) * n
    @classmethod
    def __class_getitem__(cls, item):
        return _ny_bgeneric(cls, item)
_ny_bmethods(_NyB_tuple, "count index")

#@ list
class _NyB_list:
    __hash__ = None
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, list, [])
    def __init__(self, iterable=()):
        var p = _ny_payload(self)
        p.clear()
        p.extend(iterable)
    def __repr__(self):
        return repr(_ny_payload(self))
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __reversed__(self):
        return reversed(_ny_payload(self))
    def __contains__(self, x):
        return x in _ny_payload(self)
    def __getitem__(self, i):
        return _ny_payload(self)[i]
    def __setitem__(self, i, v):
        var p = _ny_payload(self)
        p[i] = v
    def __delitem__(self, i):
        var p = _ny_payload(self)
        del p[i]
    def __eq__(self, o):
        return _ny_payload(self) == _ny_payload(o)
    def __ne__(self, o):
        return _ny_payload(self) != _ny_payload(o)
    def __lt__(self, o):
        return _ny_payload(self) < _ny_payload(o)
    def __le__(self, o):
        return _ny_payload(self) <= _ny_payload(o)
    def __gt__(self, o):
        return _ny_payload(self) > _ny_payload(o)
    def __ge__(self, o):
        return _ny_payload(self) >= _ny_payload(o)
    def __add__(self, o):
        return _ny_payload(self) + _ny_payload(o)
    def __radd__(self, o):
        return _ny_payload(o) + _ny_payload(self)
    def __iadd__(self, o):
        _ny_payload(self).extend(o)
        return self
    def __mul__(self, n):
        return _ny_payload(self) * n
    def __rmul__(self, n):
        return _ny_payload(self) * n
    def __imul__(self, n):
        var p = _ny_payload(self)
        var items = list(p)
        p.clear()
        for _ in range(n):
            p.extend(items)
        return self
    @classmethod
    def __class_getitem__(cls, item):
        return _ny_bgeneric(cls, item)
_ny_bmethods(_NyB_list, "append clear copy count extend index insert pop remove reverse sort")

#@ dict
class _NyB_dict:
    __hash__ = None
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, dict, {})
    def __init__(self, *args, **kw):
        var p = _ny_payload(self)
        p.clear()
        if len(args) > 1:
            raise TypeError("dict expected at most 1 argument, got " + str(len(args)))
        if len(args) == 1:
            p.update(args[0])
        if len(kw) > 0:
            p.update(kw)
    def __repr__(self):
        return repr(_ny_payload(self))
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __reversed__(self):
        return reversed(_ny_payload(self))
    def __contains__(self, k):
        return k in _ny_payload(self)
    def __getitem__(self, k):
        var p = _ny_payload(self)
        if k in p:
            return p[k]
        var missing = getattr(type(self), "__missing__", None)
        if missing is not None:
            return missing(self, k)
        raise KeyError(k)
    def __setitem__(self, k, v):
        var p = _ny_payload(self)
        p[k] = v
    def __delitem__(self, k):
        var p = _ny_payload(self)
        del p[k]
    def __eq__(self, o):
        return _ny_payload(self) == _ny_payload(o)
    def __ne__(self, o):
        return _ny_payload(self) != _ny_payload(o)
    def __or__(self, o):
        return _ny_payload(self) | _ny_payload(o)
    def __ror__(self, o):
        return _ny_payload(o) | _ny_payload(self)
    def __ior__(self, o):
        _ny_payload(self).update(o)
        return self
    @classmethod
    def fromkeys(cls, iterable, value=None):
        var d = cls()
        for k in iterable:
            d[k] = value
        return d
    @classmethod
    def __class_getitem__(cls, item):
        return _ny_bgeneric(cls, item)
_ny_bmethods(_NyB_dict, "clear copy get items keys pop popitem setdefault update values")

#@ set
class _NyB_set:
    __hash__ = None
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, set, set())
    def __init__(self, iterable=()):
        var p = _ny_payload(self)
        p.clear()
        p.update(iterable)
    def __repr__(self):
        var p = _ny_payload(self)
        if len(p) == 0:
            return type(self).__name__ + "()"
        return type(self).__name__ + "(" + repr(p) + ")"
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __contains__(self, x):
        return x in _ny_payload(self)
    def __eq__(self, o):
        return _ny_payload(self) == _ny_payload(o)
    def __ne__(self, o):
        return _ny_payload(self) != _ny_payload(o)
    def __lt__(self, o):
        return _ny_payload(self) < _ny_payload(o)
    def __le__(self, o):
        return _ny_payload(self) <= _ny_payload(o)
    def __gt__(self, o):
        return _ny_payload(self) > _ny_payload(o)
    def __ge__(self, o):
        return _ny_payload(self) >= _ny_payload(o)
    def __and__(self, o):
        return _ny_payload(self) & _ny_payload(o)
    def __rand__(self, o):
        return _ny_payload(o) & _ny_payload(self)
    def __or__(self, o):
        return _ny_payload(self) | _ny_payload(o)
    def __ror__(self, o):
        return _ny_payload(o) | _ny_payload(self)
    def __sub__(self, o):
        return _ny_payload(self) - _ny_payload(o)
    def __rsub__(self, o):
        return _ny_payload(o) - _ny_payload(self)
    def __xor__(self, o):
        return _ny_payload(self) ^ _ny_payload(o)
    def __rxor__(self, o):
        return _ny_payload(o) ^ _ny_payload(self)
    def __iand__(self, o):
        _ny_payload(self).intersection_update(o)
        return self
    def __ior__(self, o):
        _ny_payload(self).update(o)
        return self
    def __isub__(self, o):
        _ny_payload(self).difference_update(o)
        return self
    def __ixor__(self, o):
        _ny_payload(self).symmetric_difference_update(o)
        return self
    @classmethod
    def __class_getitem__(cls, item):
        return _ny_bgeneric(cls, item)
_ny_bmethods(_NyB_set, "add clear copy difference difference_update discard intersection intersection_update isdisjoint issubset issuperset pop remove symmetric_difference symmetric_difference_update union update")

#@ frozenset
class _NyB_frozenset:
    def __new__(cls, *args, **kw):
        return _ny_payload_new(cls, frozenset, frozenset(*args, **kw))
    def __repr__(self):
        var p = _ny_payload(self)
        if len(p) == 0:
            return type(self).__name__ + "()"
        return type(self).__name__ + "(" + repr(set(p)) + ")"
    def __hash__(self):
        return hash(_ny_payload(self))
    def __len__(self):
        return len(_ny_payload(self))
    def __iter__(self):
        return iter(_ny_payload(self))
    def __contains__(self, x):
        return x in _ny_payload(self)
    def __eq__(self, o):
        return _ny_payload(self) == _ny_payload(o)
    def __ne__(self, o):
        return _ny_payload(self) != _ny_payload(o)
    def __lt__(self, o):
        return _ny_payload(self) < _ny_payload(o)
    def __le__(self, o):
        return _ny_payload(self) <= _ny_payload(o)
    def __gt__(self, o):
        return _ny_payload(self) > _ny_payload(o)
    def __ge__(self, o):
        return _ny_payload(self) >= _ny_payload(o)
    def __and__(self, o):
        return _ny_payload(self) & _ny_payload(o)
    def __rand__(self, o):
        return _ny_payload(o) & _ny_payload(self)
    def __or__(self, o):
        return _ny_payload(self) | _ny_payload(o)
    def __ror__(self, o):
        return _ny_payload(o) | _ny_payload(self)
    def __sub__(self, o):
        return _ny_payload(self) - _ny_payload(o)
    def __rsub__(self, o):
        return _ny_payload(o) - _ny_payload(self)
    def __xor__(self, o):
        return _ny_payload(self) ^ _ny_payload(o)
    def __rxor__(self, o):
        return _ny_payload(o) ^ _ny_payload(self)
    @classmethod
    def __class_getitem__(cls, item):
        return _ny_bgeneric(cls, item)
_ny_bmethods(_NyB_frozenset, "copy difference intersection isdisjoint issubset issuperset symmetric_difference union")

#@ slots
# __slots__ and __class__ assignment (round 79). Both engines run this chunk
# the first time a class statement's namespace holds __slots__ or an object's
# __class__ is assigned. A slot is a member descriptor on the class (C.x);
# its value is the instance's field of that name, which the engines read and
# store directly (the descriptor's __get__/__set__ are what C.x.__get__(o)
# calls). A class whose MRO declares __slots__ everywhere (object and the
# builtin types aside) without "__dict__" makes instances that take no other
# attribute (_ny_mark_slots flag 1); without "__weakref__" anywhere, no weak
# reference (flag 2, lib/weakref.ny). (round 80: prelude code - this chunk
# too - resolves the builtins themselves whatever a program rebinds, so the
# _ny_b_ aliases round 79 called them by are gone.)
class _NyMemberDescriptor:
    def __init__(self, name, owner):
        self.__name__ = name
        self.__objclass__ = owner
        self.__qualname__ = getattr(owner, "__qualname__", owner.__name__) + "." + name
    def __get__(self, obj, objtype=None):
        if obj is None:
            return self
        return _ny_getfield(obj, self.__name__)
    def __set__(self, obj, value):
        _ny_setfield(obj, self.__name__, value)
    def __delete__(self, obj):
        try:
            _ny_delfield(obj, self.__name__)
        except KeyError:
            raise AttributeError(self.__name__) from None
    def __repr__(self):
        return "<member '" + self.__name__ + "' of '" + self.__objclass__.__name__ + "' objects>"
_NyMemberDescriptor.__name__ = "member_descriptor"
_NyMemberDescriptor.__qualname__ = "member_descriptor"

def _ny_slots_of(c):
    var d = getattr(c, "__dict__", None)
    if d is None or "__slots__" not in d:
        return None
    var s = d["__slots__"]
    if isinstance(s, str):
        return [s]
    return list(s)

def _ny_builtin_base(c):
    return c is object or getattr(c, "__module__", None) == "builtins"

def _ny_init_slots(cls):
    # type.__new__'s handling of __slots__
    var names = _ny_slots_of(cls)
    var ns = cls.__dict__
    if names and issubclass(cls, (int, bytes, tuple)):
        # variable-size builtins hold no slots (tp_itemsize != 0)
        raise TypeError("nonempty __slots__ not supported for subtype of '" + cls.__bases__[0].__name__ + "'")
    var base_dict = False
    var base_weak = False
    for b in cls.__mro__[1:]:
        if _ny_builtin_base(b):
            continue
        var bs = _ny_slots_of(b)
        if bs is None:
            base_dict = True
            base_weak = True
        else:
            if "__dict__" in bs:
                base_dict = True
            if "__weakref__" in bs:
                base_weak = True
    var has_dict = base_dict
    var has_weak = base_weak
    var made = []
    for n in names:
        if not isinstance(n, str):
            raise TypeError("__slots__ items must be strings, not '" + type(n).__name__ + "'")
        if not n.isidentifier():
            raise TypeError("__slots__ must be identifiers")
        if n == "__dict__":
            if has_dict:
                raise TypeError("__dict__ slot disallowed: we already got one")
            has_dict = True
            continue
        if n == "__weakref__":
            if has_weak:
                raise TypeError("__weakref__ slot disallowed: either we already got one, or __itemsize__ != 0")
            has_weak = True
            continue
        var m = n
        if n.startswith("__") and not n.endswith("__"):
            var stripped = cls.__name__.lstrip("_")
            if stripped:
                m = "_" + stripped + n
        if m in ns:
            raise ValueError(repr(m) + " in __slots__ conflicts with class variable")
        made.append(m)
    for m in made:
        _ny_setattr_raw(cls, m, _NyMemberDescriptor(m, cls))
    _ny_mark_slots(cls, (0 if has_dict else 1) | (0 if has_weak else 2))

def _ny_class_layout(cls):
    # what CPython's compatible_for_assignment compares, simplified: the
    # slots added along the MRO, whether instances have a __dict__, and the
    # builtin type the class derives from
    var slots = []
    var dictful = False
    var builtin = None
    for c in cls.__mro__:
        if c is object:
            continue
        if _ny_builtin_base(c):
            if builtin is None:
                builtin = c.__name__
            continue
        var s = _ny_slots_of(c)
        if s is None:
            dictful = True
            continue
        for n in s:
            if n == "__dict__":
                dictful = True
            elif n != "__weakref__":
                if n.startswith("__") and not n.endswith("__") and c.__name__.lstrip("_"):
                    n = "_" + c.__name__.lstrip("_") + n
                slots.append(n)
    return (dictful, tuple(slots), builtin)

def _ny_set_class(obj, cls):
    # obj.__class__ = cls (object.__class__'s setter; round 86: audited first,
    # as CPython's object_set_class)
    _ny_sys_audit("object.__setattr__", obj, "__class__", cls)
    if not isinstance(cls, type):
        raise TypeError("__class__ must be set to a class, not '" + type(cls).__name__ + "' object")
    var old = type(obj)
    if isinstance(obj, type) or _ny_builtin_base(old) or _ny_builtin_base(cls):
        raise TypeError("__class__ assignment only supported for mutable types or ModuleType subclasses")
    if _ny_class_layout(old) != _ny_class_layout(cls):
        raise TypeError("__class__ assignment: '" + cls.__name__ + "' object layout differs from '" + old.__name__ + "'")
    # (the same TypeError when obj is not an instance of a class)
    _ny_switch_class(obj, cls)

#@ dictview
# obj.__dict__ / vars(obj): a live view of an instance's attributes (round
# 77). Reads see the fields as they are now (its payload, _ny_payload(view),
# is a fresh dict of them, so the dict mirror's methods and every builtin
# read them); writes store or remove fields directly, past __setattr__ and
# descriptors, as CPython's instance dict does.
class _NyInstanceDict(dict):
    def __init__(self, *args, **kw):
        pass
    def __setitem__(self, k, v):
        _ny_setfield(self.__ny_view_of__, k, v)
    def __delitem__(self, k):
        _ny_delfield(self.__ny_view_of__, k)
    def update(self, *args, **kw):
        if len(args) > 1:
            raise TypeError("update expected at most 1 argument, got " + str(len(args)))
        if len(args) == 1:
            var other = args[0]
            if hasattr(other, "keys"):
                for k in list(other.keys()):
                    self[k] = other[k]
            else:
                for kv in other:
                    self[kv[0]] = kv[1]
        for k in kw:
            self[k] = kw[k]
    def __ior__(self, other):
        self.update(other)
        return self
    def setdefault(self, k, default=None):
        var d = _ny_payload(self)
        if k in d:
            return d[k]
        self[k] = default
        return default
    def pop(self, k, *default):
        var d = _ny_payload(self)
        if k in d:
            var v = d[k]
            del self[k]
            return v
        if len(default) > 0:
            return default[0]
        raise KeyError(k)
    def popitem(self):
        var d = _ny_payload(self)
        if len(d) == 0:
            raise KeyError("popitem(): dictionary is empty")
        var k = list(d.keys())[-1]
        var v = d[k]
        del self[k]
        return (k, v)
    def clear(self):
        for k in list(_ny_payload(self).keys()):
            del self[k]

class _NyGlobalsDict(_NyInstanceDict):
    # globals() (round 81): a module's live namespace as a dict - its value
    # is the module's variables as they are now (the engines' payload of a
    # view whose __ny_globals_of__ is the module object, None for the
    # program), and storing or deleting a key binds or unbinds the variable.
    def __setitem__(self, k, v):
        if not isinstance(k, str):
            raise TypeError("globals() keys must be str here, not " + type(k).__name__)
        var o = self.__ny_globals_of__
        if o is None:
            _ny_main_set(k, v)
        else:
            setattr(o, k, v)
    def __delitem__(self, k):
        var o = self.__ny_globals_of__
        if k not in _ny_payload(self):
            raise KeyError(k)
        if o is None:
            _ny_main_del(k)
        else:
            delattr(o, k)
_NyGlobalsDict.__name__ = "dict"
_NyGlobalsDict.__qualname__ = "dict"
#@ os
# ── the rest of Python's os module (round 80) ─────────────────────────────
# Run the first time a program imports os (both engines' os namespace
# builders load this chunk, then bind every (name, value) of _ny_os_members
# - "path.x" into os.path - over the flat os_* builtins of the same name).
# The natives are _ny_os_call's ops in src/builtins/os_fd.cpp; they raise
# the OSError subclass of errno with errno, strerror and the file name.
# os.fspath / os.PathLike, os.scandir / os.DirEntry, os.walk on scandir (as
# CPython 3.12's, no recursion), file descriptors (open/read/write/close/
# pipe/dup/dup2/fdopen/lseek/fsync/isatty/truncate/ftruncate, inheritable
# and blocking flags, the O_* constants), ids and ownership (POSIX), umask,
# getlogin, mkfifo, major/minor/makedev, getloadavg, sched_getaffinity,
# access with F_OK/R_OK/W_OK/X_OK, kill, fsencode/fsdecode, get_exec_path,
# removedirs/renames, the constants curdir/pardir/extsep/altsep/devnull/
# defpath; and os.path's members whose flat builtin keeps a legacy contract
# (dirname("a") is "", split and splitext give tuples, "\" is no separator
# on POSIX, normpath keeps POSIX's "//") or that were missing (splitdrive,
# lexists, samefile, sameopenfile, samestat, ismount, isjunction,
# isdevdrive, getatime, getctime, normcase, commonprefix).
_ny_os_nt = os_name == "nt"

def _ny_os_fspath(path):
    # os.fspath (PEP 519)
    if isinstance(path, str) or isinstance(path, bytes):
        return path
    var t = type(path)
    var f = getattr(t, "__fspath__", None)
    if f is None:
        raise TypeError("expected str, bytes or os.PathLike object, not " + t.__name__)
    var r = f(path)
    if isinstance(r, str) or isinstance(r, bytes):
        return r
    raise TypeError("expected " + t.__name__ + ".__fspath__() to return str or bytes, not " + type(r).__name__)

def _ny_os_fsencode(filename):
    filename = _ny_os_fspath(filename)
    if isinstance(filename, str):
        return filename.encode("utf-8", "surrogateescape")
    return filename

def _ny_os_fsdecode(filename):
    filename = _ny_os_fspath(filename)
    if isinstance(filename, bytes):
        return filename.decode("utf-8", "surrogateescape")
    return filename

def _ny_os_str(path):
    # a path argument as the natives take it (bytes paths decoded)
    path = _ny_os_fspath(path)
    if isinstance(path, bytes):
        return path.decode("utf-8", "surrogateescape")
    return path

class _NyPathLikeMeta(type):
    # isinstance(x, os.PathLike) / issubclass: a class defining __fspath__
    # (abc's __subclasshook__ in CPython; abc itself is not loaded for it)
    def __instancecheck__(cls, obj):
        return cls.__subclasscheck__(type(obj))
    def __subclasscheck__(cls, sub):
        if not isinstance(sub, type):
            raise TypeError("issubclass() arg 1 must be a class")
        for k in sub.__mro__:
            if k is cls:
                return True
        if cls is not _ny_os_PathLike:
            return False
        for k in sub.__mro__:
            var d = getattr(k, "__dict__", None)
            if d is not None and "__fspath__" in d:
                return d["__fspath__"] is not None
        return False

class PathLike(metaclass=_NyPathLikeMeta):
    """Abstract base class for implementing the file system path protocol."""
    __module__ = "os"
    def __new__(cls, *args, **kw):
        if getattr(cls, "__fspath__") is _ny_os_PathLike.__dict__["__fspath__"]:
            raise TypeError("Can't instantiate abstract class " + cls.__name__ + " with abstract method __fspath__")
        return object.__new__(cls)
    def __fspath__(self):
        """Return the file system path representation of the object."""
        raise NotImplementedError
    def __class_getitem__(cls, item):
        return _NyGenericAlias(cls, item)

_ny_os_PathLike = PathLike
del PathLike

# ── os.scandir / os.DirEntry ─────────────────────────────────────────────
class DirEntry:
    __module__ = "posix"
    def __init__(self, top, name, kind, ino, bytes_mode):
        self._ny_name = name
        self._ny_path = _ny_osp_join(top, name)
        self._ny_kind = kind
        self._ny_ino = ino
        self._ny_stat = None
        self._ny_lstat = None
    @property
    def name(self):
        return self._ny_name
    @property
    def path(self):
        return self._ny_path
    def __fspath__(self):
        return self._ny_path
    def __repr__(self):
        return "<DirEntry " + repr(self._ny_name) + ">"
    def __class_getitem__(cls, item):
        return _NyGenericAlias(cls, item)
    def _ny_kindof(self):
        if self._ny_kind == "?":
            var m = self.stat(follow_symlinks=False).st_mode & 0o170000
            self._ny_kind = "d" if m == 0o040000 else "f" if m == 0o100000 else "l" if m == 0o120000 else "o"
        return self._ny_kind
    def inode(self):
        if self._ny_ino == 0:
            self._ny_ino = self.stat(follow_symlinks=False).st_ino
        return self._ny_ino
    def is_symlink(self):
        return self._ny_kindof() == "l"
    def is_junction(self):
        return False
    def _ny_follow(self, want):
        try:
            return (self.stat().st_mode & 0o170000) == want
        except FileNotFoundError:
            return False
    def is_dir(self, *, follow_symlinks=True):
        var k = self._ny_kindof()
        if k == "l" and follow_symlinks:
            return self._ny_follow(0o040000)
        return k == "d"
    def is_file(self, *, follow_symlinks=True):
        var k = self._ny_kindof()
        if k == "l" and follow_symlinks:
            return self._ny_follow(0o100000)
        return k == "f"
    def stat(self, *, follow_symlinks=True):
        # cached, as CPython's (lstat for a link not followed)
        if not follow_symlinks or self._ny_kind == "l" or self._ny_kind == "?":
            if self._ny_lstat is None:
                self._ny_lstat = _ny_os_lstat(_ny_os_str(self._ny_path))
            if not follow_symlinks or (self._ny_lstat.st_mode & 0o170000) != 0o120000:
                return self._ny_lstat
        if self._ny_stat is None:
            self._ny_stat = _ny_os_stat(_ny_os_str(self._ny_path))
        return self._ny_stat

_ny_os_DirEntry = DirEntry
del DirEntry

class _NyScandirIterator:
    def __init__(self, top, items, bytes_mode):
        self._ny_top = top
        self._ny_items = items
        self._ny_i = 0
        self._ny_bytes = bytes_mode
    def __iter__(self):
        return self
    def __next__(self):
        if self._ny_items is None or self._ny_i >= len(self._ny_items):
            self._ny_items = None
            raise StopIteration
        var it = self._ny_items[self._ny_i]
        self._ny_i += 1
        var name = it[0]
        if self._ny_bytes:
            name = name.encode("utf-8", "surrogateescape")
        return _ny_os_DirEntry(self._ny_top, name, it[1], it[2], self._ny_bytes)
    def close(self):
        self._ny_items = None
    def __enter__(self):
        return self
    def __exit__(self, *exc):
        self.close()
        return False
    def __repr__(self):
        return "<posix.ScandirIterator object>"

def _ny_os_scandir(path=None):
    _ny_sys_audit("os.scandir", path)   # round 86
    if path is None:
        path = "."
    if isinstance(path, int) and not isinstance(path, bool):
        raise NotImplementedError("os.scandir() of a file descriptor")
    path = _ny_os_fspath(path)
    return _NyScandirIterator(path, _ny_os_call("scandir", _ny_os_str(path)), isinstance(path, bytes))

def _ny_os_walk(top, topdown=True, onerror=None, followlinks=False):
    # CPython 3.12's os.walk: on scandir, iterative
    _ny_sys_audit("os.walk", top, topdown, onerror, followlinks)   # round 86
    var stack = [_ny_os_fspath(top)]
    while stack:
        top = stack.pop()
        if isinstance(top, tuple):
            yield top
            continue
        var dirs = []
        var nondirs = []
        var walk_dirs = []
        var it = None
        try:
            it = _ny_os_scandir(top)
        except OSError as error:
            if onerror is not None:
                onerror(error)
            continue
        for entry in it:
            var is_dir = False
            try:
                is_dir = entry.is_dir()
            except OSError:
                is_dir = False
            if is_dir:
                dirs.append(entry.name)
            else:
                nondirs.append(entry.name)
            if not topdown and is_dir:
                var walk_into = True
                if not followlinks:
                    try:
                        walk_into = not entry.is_symlink()
                    except OSError:
                        walk_into = True
                if walk_into:
                    walk_dirs.append(entry.path)
        it.close()
        if topdown:
            yield top, dirs, nondirs
            for d in reversed(dirs):
                var new_path = _ny_osp_join(top, d)
                if followlinks or not _ny_osp_islink(new_path):
                    stack.append(new_path)
        else:
            stack.append((top, dirs, nondirs))
            for new_path in reversed(walk_dirs):
                stack.append(new_path)

# ── file descriptors ─────────────────────────────────────────────────────
def _ny_os_fd(fd):
    if isinstance(fd, bool) or not isinstance(fd, int):
        if hasattr(fd, "__index__"):
            return fd.__index__()
        raise TypeError("'" + type(fd).__name__ + "' object cannot be interpreted as an integer")
    return fd

_ny_os_cloexec = []
def _ny_os_open(path, flags, mode=0o777, *, dir_fd=None):
    if _ny_audit_hooks:
        # (round 86) the "open" event, as CPython's os.open: no mode, the
        # flags with the close-on-exec flag every descriptor gets
        if not _ny_os_cloexec:
            var cx = 0
            for kv in _ny_os_call("constants"):
                if kv[0] == ("O_NOINHERIT" if _ny_os_nt else "O_CLOEXEC"):
                    cx = kv[1]
            _ny_os_cloexec.append(cx)
        _ny_audit_fire("open", (path, None, _ny_os_fd(flags) | _ny_os_cloexec[0]))
    return _ny_os_call("open", _ny_os_str(path), _ny_os_fd(flags), _ny_os_fd(mode))

def _ny_os_read(fd, n):
    return _ny_os_call("read", _ny_os_fd(fd), _ny_os_fd(n))

def _ny_os_write(fd, data):
    if isinstance(data, bytearray):
        data = bytes(data)
    elif not isinstance(data, bytes):
        data = _ny_bytes_like(data)      # round 84: any buffer
    return _ny_os_call("write", _ny_os_fd(fd), data)

# (round 84) positioned and vectored I/O: pread/pwrite at an offset without
# moving the file position (POSIX), readv/preadv scatter what one read gives
# into the buffers in order (any writable buffers, filled in place),
# writev/pwritev gather the buffers into one write
def _ny_os_pread(fd, n, offset):
    return _ny_os_call("pread", _ny_os_fd(fd), _ny_os_fd(n), _ny_os_fd(offset))

def _ny_os_pwrite(fd, data, offset):
    return _ny_os_call("pwrite", _ny_os_fd(fd), bytes(_ny_bytes_like(data)), _ny_os_fd(offset))

def _ny_os_seq(buffers, what):
    if isinstance(buffers, (str, bytes, bytearray, dict, set)) or not hasattr(type(buffers), "__getitem__"):
        raise TypeError(what + "() arg 2 must be a sequence")
    return list(buffers)

def _ny_os_scatter(views, data):
    var pos = 0
    for v in views:
        if pos >= len(data):
            break
        var k = min(len(v), len(data) - pos)
        v[0:k] = data[pos:pos + k]
        pos = pos + k
    for v in views:
        v.release()
    return len(data)

def _ny_os_views(buffers, what):
    var views = []
    try:
        for b in _ny_os_seq(buffers, what):
            views.append(_ny_writable_view(b, None))
    except BaseException:
        for v in views:
            v.release()
        raise
    return views

def _ny_os_gather(buffers, what):
    var out = []
    for b in _ny_os_seq(buffers, what):
        out.append(bytes(_ny_bytes_like(b)))
    return b"".join(out)

def _ny_os_readv(fd, buffers):
    var views = _ny_os_views(buffers, "readv")
    var total = 0
    for v in views:
        total = total + len(v)
    return _ny_os_scatter(views, _ny_os_call("read", _ny_os_fd(fd), total))

def _ny_os_preadv(fd, buffers, offset, flags=0):
    var views = _ny_os_views(buffers, "preadv")
    var total = 0
    for v in views:
        total = total + len(v)
    return _ny_os_scatter(views, _ny_os_call("pread", _ny_os_fd(fd), total, _ny_os_fd(offset)))

def _ny_os_writev(fd, buffers):
    return _ny_os_call("write", _ny_os_fd(fd), _ny_os_gather(buffers, "writev"))

def _ny_os_pwritev(fd, buffers, offset, flags=0):
    return _ny_os_call("pwrite", _ny_os_fd(fd), _ny_os_gather(buffers, "pwritev"), _ny_os_fd(offset))

def _ny_os_close(fd):
    _ny_os_call("close", _ny_os_fd(fd))

def _ny_os_closerange(fd_low, fd_high):
    _ny_os_call("closerange", _ny_os_fd(fd_low), _ny_os_fd(fd_high))

def _ny_os_pipe():
    return _ny_os_call("pipe")

def _ny_os_dup(fd):
    return _ny_os_call("dup", _ny_os_fd(fd))

def _ny_os_dup2(fd, fd2, inheritable=True):
    return _ny_os_call("dup2", _ny_os_fd(fd), _ny_os_fd(fd2), inheritable)

def _ny_os_get_inheritable(fd):
    return _ny_os_call("get_inheritable", _ny_os_fd(fd))

def _ny_os_set_inheritable(fd, inheritable):
    _ny_os_call("set_inheritable", _ny_os_fd(fd), inheritable)

def _ny_os_get_blocking(fd):
    return _ny_os_call("get_blocking", _ny_os_fd(fd))

def _ny_os_set_blocking(fd, blocking):
    _ny_os_call("set_blocking", _ny_os_fd(fd), blocking)

def _ny_os_lseek(fd, position, whence):
    return _ny_os_call("lseek", _ny_os_fd(fd), _ny_os_fd(position), _ny_os_fd(whence))

def _ny_os_fsync(fd):
    if not isinstance(fd, int) and hasattr(fd, "fileno"):
        fd = fd.fileno()
    _ny_os_call("fsync", _ny_os_fd(fd))

def _ny_os_isatty(fd):
    return _ny_os_call("isatty", _ny_os_fd(fd))

def _ny_os_ftruncate(fd, length):
    _ny_sys_audit("os.truncate", fd, length)   # round 86
    _ny_os_call("ftruncate", _ny_os_fd(fd), _ny_os_fd(length))

def _ny_os_truncate(path, length):
    if isinstance(path, int) and not isinstance(path, bool):
        return _ny_os_ftruncate(path, length)
    _ny_sys_audit("os.truncate", path, length)   # round 86
    _ny_os_call("truncate", _ny_os_str(path), _ny_os_fd(length))

def _ny_os_fdopen(fd, mode="r", buffering=-1, encoding=None, *args, **kw):
    if not isinstance(fd, int):
        raise TypeError("fdopen() argument must be an int, not " + type(fd).__name__)
    var f = NythonFile(fd, mode, _ny_os_call("fdopen", fd, mode), encoding if encoding is not None else "utf-8")
    return f

def _ny_os_strerror(code):
    return _ny_os_call("strerror", _ny_os_fd(code))

def _ny_os_umask(mask):
    return _ny_os_call("umask", _ny_os_fd(mask))

def _ny_os_getlogin():
    return _ny_os_call("getlogin")

def _ny_os_access(path, mode, *, dir_fd=None, effective_ids=False, follow_symlinks=True):
    return _ny_os_call("access", _ny_os_str(path), _ny_os_fd(mode), effective_ids, follow_symlinks)

def _ny_os_getcwdb():
    return _ny_os_fsencode(os_getcwd())

def _ny_os_get_exec_path(env=None):
    if env is None:
        env = os_environ()
    var path_list = None
    for k in ("PATH", b"PATH"):
        try:
            path_list = env[k]
            break
        except (KeyError, TypeError):
            pass
    if path_list is None:
        path_list = _ny_os_defpath
    if isinstance(path_list, bytes):
        path_list = _ny_os_fsdecode(path_list)
    return path_list.split(os_pathsep)

def _ny_os_removedirs(name):
    _ny_os_rmdir(name)
    var ht = _ny_osp_split(name)
    var head = ht[0]
    var tail = ht[1]
    if not tail:
        ht = _ny_osp_split(head)
        head = ht[0]
        tail = ht[1]
    while head and tail:
        try:
            _ny_os_rmdir(head)
        except OSError:
            break
        ht = _ny_osp_split(head)
        head = ht[0]
        tail = ht[1]

def _ny_os_renames(old, new):
    var ht = _ny_osp_split(new)
    if ht[0] and ht[1] and not os_path_exists(_ny_os_str(ht[0])):
        _ny_os_makedirs(ht[0])
    _ny_os_rename(old, new)
    ht = _ny_osp_split(old)
    if ht[0] and ht[1]:
        try:
            _ny_os_removedirs(ht[0])
        except OSError:
            pass

def _ny_os_kill(pid, sig):
    _ny_sys_audit("os.kill", pid, sig)   # round 86
    _ny_os_call("kill", _ny_os_fd(pid), _ny_os_fd(sig))

# (round 86) the os functions the flat natives (os_system, os_unlink ...)
# implement, audited as CPython's posixmodule.c audits them: the event,
# then the native with the arguments as given
def _ny_os_system(command):
    if _ny_audit_hooks:
        _ny_audit_fire("os.system", (_ny_audit_fsenc(command),))
    return os_system(command)

def _ny_os_remove(path, *, dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.remove", (path, _ny_audit_dirfd(dir_fd)))
    return os_unlink(path)

def _ny_os_unlink(path, *, dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.remove", (path, _ny_audit_dirfd(dir_fd)))
    return os_unlink(path)

def _ny_os_rmdir(path, *, dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.rmdir", (path, _ny_audit_dirfd(dir_fd)))
    return os_rmdir(path)

def _ny_os_chmod(path, mode, *, dir_fd=None, follow_symlinks=True):
    if isinstance(path, int) and not isinstance(path, bool):
        _ny_sys_audit("os.chmod", path, mode, -1)
        return _ny_os_call("fchmod", path, _ny_os_fd(mode))
    if _ny_audit_hooks:
        _ny_audit_fire("os.chmod", (path, mode, _ny_audit_dirfd(dir_fd)))
    return os_chmod(path, mode)

def _ny_os_chdir(path):
    _ny_sys_audit("os.chdir", path)
    if isinstance(path, int) and not isinstance(path, bool):
        return _ny_os_call("fchdir", path)
    return os_chdir(path)

def _ny_os_symlink(src, dst, target_is_directory=False, *, dir_fd=None):
    if _ny_audit_hooks:
        _ny_audit_fire("os.symlink", (src, dst, _ny_audit_dirfd(dir_fd)))
    return os_symlink(src, dst)

def _ny_os_utime(path, *args, **kw):
    if _ny_audit_hooks:
        var times = args[0] if len(args) > 0 else kw.get("times")
        _ny_audit_fire("os.utime", (path, times, kw.get("ns"), _ny_audit_dirfd(kw.get("dir_fd"))))
    return os_utime(path, *args, **kw)

def _ny_os_unsetenv(key):
    if _ny_audit_hooks:
        _ny_audit_fire("os.unsetenv", (_ny_audit_fsenc(key),))
    return os_unsetenv(key)

def _ny_os_makedirs(name, mode=0o777, exist_ok=False):
    # CPython's os.makedirs (os.py): each missing directory by os.mkdir
    var ht = _ny_osp_split(name)
    var head = ht[0]
    var tail = ht[1]
    if not tail:
        ht = _ny_osp_split(head)
        head = ht[0]
        tail = ht[1]
    if head and tail and not os_path_exists(_ny_os_str(head)):
        try:
            _ny_os_makedirs(head, exist_ok=exist_ok)
        except FileExistsError:
            pass
        var cdir = _ny_os_curdir
        if isinstance(tail, bytes):
            cdir = bytes(cdir, "ASCII")
        if tail == cdir:
            return
    try:
        _ny_os_mkdir(name, mode)
    except OSError:
        if not exist_ok or not os_path_isdir(_ny_os_str(name)):
            raise

def _ny_os_cpu_count():
    return os_cpu_count()

# os.environ / os.environb: the base prelude's _NyEnviron (CPython's
# os._Environ - a copy taken at startup that writes through to the process
# environment), one per program; this chunk only lists it (round 80)

def _ny_os_putenv(key, value):
    if _ny_audit_hooks:   # round 86
        _ny_audit_fire("os.putenv", (_ny_audit_fsenc(key), _ny_audit_fsenc(value)))
    os_setenv(_ny_os_str(key), _ny_os_str(value))

# ── os.path where the flat builtins differ from Python ───────────────────
var _ny_osp_ntmod = []
def _ny_osp_nt():
    if not _ny_osp_ntmod:
        import ntpath
        _ny_osp_ntmod.append(ntpath)
    return _ny_osp_ntmod[0]

def _ny_osp_join(a, *p):
    if _ny_os_nt or isinstance(a, bytes):
        if _ny_os_nt:
            return _ny_osp_nt().join(a, *p)
        a = _ny_os_fspath(a)
        var path = a
        for b in p:
            b = _ny_os_fspath(b)
            if not isinstance(b, bytes):
                raise TypeError("Can't mix strings and bytes in path components")
            if b.startswith(b"/"):
                path = b
            elif not path or path.endswith(b"/"):
                path += b
            else:
                path += b"/" + b
        return path
    return os_path_join(a, *p)

def _ny_osp_split(p):
    p = _ny_os_fspath(p)
    if _ny_os_nt:
        return _ny_osp_nt().split(p)
    var sp = b"/" if isinstance(p, bytes) else "/"
    var i = p.rfind(sp) + 1
    var head = p[:i]
    var tail = p[i:]
    if head and head != sp * len(head):
        head = head.rstrip(sp)
    return (head, tail)

def _ny_osp_basename(p):
    p = _ny_os_fspath(p)
    if _ny_os_nt:
        return _ny_osp_nt().basename(p)
    var sp = b"/" if isinstance(p, bytes) else "/"
    return p[p.rfind(sp) + 1:]

def _ny_osp_dirname(p):
    p = _ny_os_fspath(p)
    if _ny_os_nt:
        return _ny_osp_nt().dirname(p)
    var sp = b"/" if isinstance(p, bytes) else "/"
    var head = p[:p.rfind(sp) + 1]
    if head and head != sp * len(head):
        head = head.rstrip(sp)
    return head

def _ny_osp_splitext(p):
    p = _ny_os_fspath(p)
    var sp = "/"
    var asp = None
    var dot = "."
    if isinstance(p, bytes):
        sp = b"/"
        dot = b"."
        if _ny_os_nt:
            sp = b"\\"
            asp = b"/"
    elif _ny_os_nt:
        sp = "\\"
        asp = "/"
    var si = p.rfind(sp)
    if asp:
        si = max(si, p.rfind(asp))
    var di = p.rfind(dot)
    if di > si:
        var fi = si + 1
        while fi < di:
            if p[fi:fi + 1] != dot:
                return (p[:di], p[di:])
            fi += 1
    return (p, p[:0])

def _ny_osp_splitdrive(p):
    p = _ny_os_fspath(p)
    if _ny_os_nt:
        return _ny_osp_nt().splitdrive(p)
    return (p[:0], p)

def _ny_osp_normpath(p):
    p = _ny_os_fspath(p)
    if _ny_os_nt:
        return _ny_osp_nt().normpath(p)
    if isinstance(p, bytes):
        return _ny_os_fsencode(_ny_osp_normpath(_ny_os_fsdecode(p)))
    var r = os_path_normpath(p)
    if p.startswith("//") and not p.startswith("///"):
        r = "/" + r
    return r

def _ny_osp_normcase(s):
    s = _ny_os_fspath(s)
    if _ny_os_nt:
        return _ny_osp_nt().normcase(s)
    return s

def _ny_osp_lexists(path):
    try:
        _ny_os_lstat(path)
    except (OSError, ValueError):
        return False
    return True

def _ny_osp_islink(path):
    try:
        return (_ny_os_lstat(path).st_mode & 0o170000) == 0o120000
    except (OSError, ValueError, AttributeError):
        return False

def _ny_osp_samestat(s1, s2):
    return s1.st_ino == s2.st_ino and s1.st_dev == s2.st_dev

def _ny_osp_samefile(f1, f2):
    return _ny_osp_samestat(_ny_os_stat(f1), _ny_os_stat(f2))

def _ny_osp_sameopenfile(fp1, fp2):
    return _ny_osp_samestat(_ny_os_fstat(fp1), _ny_os_fstat(fp2))

def _ny_osp_ismount(path):
    if _ny_os_nt:
        return _ny_osp_nt().ismount(path)
    var s1 = None
    try:
        s1 = _ny_os_lstat(path)
    except (OSError, ValueError):
        return False
    if (s1.st_mode & 0o170000) == 0o120000:
        return False
    path = _ny_os_fspath(path)
    var parent = _ny_osp_join(path, b".." if isinstance(path, bytes) else "..")
    var s2 = None
    try:
        s2 = _ny_os_lstat(os_path_realpath(_ny_os_str(parent)))
    except (OSError, ValueError):
        return False
    return s1.st_dev != s2.st_dev or s1.st_ino == s2.st_ino

def _ny_osp_isjunction(path):
    _ny_os_fspath(path)
    return False

def _ny_osp_isdevdrive(path):
    _ny_os_fspath(path)
    return False

def _ny_osp_getatime(filename):
    return _ny_os_stat(filename).st_atime

def _ny_osp_getctime(filename):
    return _ny_os_stat(filename).st_ctime

def _ny_osp_commonprefix(m):
    if not m:
        return ""
    if not isinstance(m[0], (list, tuple)):
        m = tuple(map(_ny_os_fspath, m))
    var s1 = min(m)
    var s2 = max(m)
    var i = 0
    for c in s1:
        if c != s2[i]:
            return s1[:i]
        i += 1
    return s1

# ── the members (round 80) ───────────────────────────────────────────────
def _ny_os__exit(status):
    # (round 83) _exit(2): the process ends at once, no cleanup
    _sys_exit(_ny_os_fd(status))

_ny_os_curdir = "."
_ny_os_pardir = ".."
_ny_os_extsep = "."
_ny_os_altsep = "/" if _ny_os_nt else None
_ny_os_devnull = "nul" if _ny_os_nt else "/dev/null"
_ny_os_defpath = ".;C:\\bin" if _ny_os_nt else "/bin:/usr/bin"

def _ny_os_member_list():
    var m = [("fspath", _ny_os_fspath), ("fsencode", _ny_os_fsencode), ("fsdecode", _ny_os_fsdecode),
             ("PathLike", _ny_os_PathLike), ("DirEntry", _ny_os_DirEntry), ("scandir", _ny_os_scandir),
             ("walk", _ny_os_walk), ("open", _ny_os_open), ("read", _ny_os_read), ("write", _ny_os_write),
             ("close", _ny_os_close), ("closerange", _ny_os_closerange), ("pipe", _ny_os_pipe),
             ("dup", _ny_os_dup), ("dup2", _ny_os_dup2), ("get_inheritable", _ny_os_get_inheritable),
             ("set_inheritable", _ny_os_set_inheritable), ("lseek", _ny_os_lseek), ("fsync", _ny_os_fsync),
             ("isatty", _ny_os_isatty), ("ftruncate", _ny_os_ftruncate), ("truncate", _ny_os_truncate),
             ("fdopen", _ny_os_fdopen), ("strerror", _ny_os_strerror), ("umask", _ny_os_umask),
             ("getlogin", _ny_os_getlogin), ("access", _ny_os_access), ("getcwdb", _ny_os_getcwdb),
             ("get_exec_path", _ny_os_get_exec_path), ("removedirs", _ny_os_removedirs),
             ("renames", _ny_os_renames), ("kill", _ny_os_kill), ("error", OSError),
             ("system", _ny_os_system), ("remove", _ny_os_remove), ("unlink", _ny_os_unlink),
             ("rmdir", _ny_os_rmdir), ("chmod", _ny_os_chmod), ("chdir", _ny_os_chdir),
             ("symlink", _ny_os_symlink), ("utime", _ny_os_utime), ("unsetenv", _ny_os_unsetenv),
             ("makedirs", _ny_os_makedirs),
             ("curdir", _ny_os_curdir), ("pardir", _ny_os_pardir), ("extsep", _ny_os_extsep),
             ("altsep", _ny_os_altsep), ("devnull", _ny_os_devnull), ("defpath", _ny_os_defpath),
             ("F_OK", 0), ("R_OK", 4), ("W_OK", 2), ("X_OK", 1), ("SEEK_SET", 0), ("SEEK_CUR", 1), ("SEEK_END", 2),
             ("supports_bytes_environ", not _ny_os_nt), ("environ", _ny_os_environ()), ("putenv", _ny_os_putenv), ("_exit", _ny_os__exit),
             ("path.split", _ny_osp_split), ("path.basename", _ny_osp_basename),
             ("path.dirname", _ny_osp_dirname), ("path.splitext", _ny_osp_splitext),
             ("path.splitdrive", _ny_osp_splitdrive), ("path.normpath", _ny_osp_normpath),
             ("path.normcase", _ny_osp_normcase), ("path.lexists", _ny_osp_lexists),
             ("path.islink", _ny_osp_islink), ("path.samestat", _ny_osp_samestat),
             ("path.samefile", _ny_osp_samefile), ("path.sameopenfile", _ny_osp_sameopenfile),
             ("path.ismount", _ny_osp_ismount), ("path.isjunction", _ny_osp_isjunction),
             ("path.isdevdrive", _ny_osp_isdevdrive), ("path.getatime", _ny_osp_getatime),
             ("path.getctime", _ny_osp_getctime), ("path.commonprefix", _ny_osp_commonprefix),
             ("path.curdir", _ny_os_curdir), ("path.pardir", _ny_os_pardir), ("path.extsep", _ny_os_extsep),
             ("path.altsep", _ny_os_altsep), ("path.devnull", _ny_os_devnull),
             ("path.defpath", _ny_os_defpath), ("path.supports_unicode_filenames", _ny_os_nt)]
    if _ny_os_nt:
        m.append(("path.join", _ny_osp_join))
    for c in _ny_os_call("constants"):
        m.append(c)
    if not _ny_os_nt:
        # (round 84) POSIX's vectored and positioned I/O
        m.append(("readv", _ny_os_readv))
        m.append(("writev", _ny_os_writev))
        m.append(("pread", _ny_os_pread))
        m.append(("pwrite", _ny_os_pwrite))
        m.append(("preadv", _ny_os_preadv))
        m.append(("pwritev", _ny_os_pwritev))
        var ids = _ny_os_call("ids")
        def idf(i):
            def f():
                return _ny_os_call("ids")[i]
            return f
        m.append(("getuid", idf(0)))
        m.append(("geteuid", idf(1)))
        m.append(("getgid", idf(2)))
        m.append(("getegid", idf(3)))
        m.append(("getpgrp", idf(4)))
        def getgroups():
            return _ny_os_call("getgroups")
        def setsid():
            _ny_os_call("setsid")
        def getsid(pid):
            return _ny_os_call("getsid", _ny_os_fd(pid))
        def getpgid(pid):
            return _ny_os_call("getpgid", _ny_os_fd(pid))
        def setpgid(pid, pgrp):
            _ny_os_call("setpgid", _ny_os_fd(pid), _ny_os_fd(pgrp))
        # (round 86) os.chown / os.chmod events as CPython's: the ids as uid_t
        def chown(path, uid, gid, *, dir_fd=None, follow_symlinks=True):
            if _ny_audit_hooks:
                _ny_audit_fire("os.chown", (path, _ny_audit_id(uid), _ny_audit_id(gid), _ny_audit_dirfd(dir_fd)))
            if isinstance(path, int) and not isinstance(path, bool):
                return _ny_os_call("fchown", path, _ny_os_fd(uid), _ny_os_fd(gid))
            _ny_os_call("chown", _ny_os_str(path), _ny_os_fd(uid), _ny_os_fd(gid), follow_symlinks)
        def lchown(path, uid, gid):
            if _ny_audit_hooks:
                _ny_audit_fire("os.chown", (path, _ny_audit_id(uid), _ny_audit_id(gid), -1))
            _ny_os_call("lchown", _ny_os_str(path), _ny_os_fd(uid), _ny_os_fd(gid))
        def fchown(fd, uid, gid):
            if _ny_audit_hooks:
                _ny_audit_fire("os.chown", (fd, _ny_audit_id(uid), _ny_audit_id(gid), -1))
            _ny_os_call("fchown", _ny_os_fd(fd), _ny_os_fd(uid), _ny_os_fd(gid))
        def fchmod(fd, mode):
            _ny_sys_audit("os.chmod", fd, mode, -1)
            _ny_os_call("fchmod", _ny_os_fd(fd), _ny_os_fd(mode))
        def mkfifo(path, mode=0o666, *, dir_fd=None):
            _ny_os_call("mkfifo", _ny_os_str(path), _ny_os_fd(mode))
        def mknod(path, mode=0o600, device=0, *, dir_fd=None):
            _ny_os_call("mknod", _ny_os_str(path), _ny_os_fd(mode), _ny_os_fd(device))
        def major(device):
            return _ny_os_call("major", _ny_os_fd(device))
        def minor(device):
            return _ny_os_call("minor", _ny_os_fd(device))
        def makedev(major, minor):
            return _ny_os_call("makedev", _ny_os_fd(major), _ny_os_fd(minor))
        def getloadavg():
            return _ny_os_call("getloadavg")
        def killpg(pgid, sig):
            _ny_sys_audit("os.killpg", pgid, sig)   # round 86
            _ny_os_call("killpg", _ny_os_fd(pgid), _ny_os_fd(sig))
        def sendfile(out_fd, in_fd, offset, count):
            # (round 82) the kernel's sendfile(2); offset None: the file's position
            return _ny_os_call("sendfile", _ny_os_fd(out_fd), _ny_os_fd(in_fd),
                               None if offset is None else _ny_os_fd(offset), _ny_os_fd(count))
        for f in (getgroups, setsid, getsid, getpgid, setpgid, chown, lchown, fchown, fchmod, mkfifo, mknod,
                  major, minor, makedev, getloadavg, killpg, sendfile):
            f.__module__ = "posix"
            m.append((f.__name__, f))
        # (round 83) the process calls pty needs - fork, forkpty, openpty,
        # login_tty, waitpid, the wait-status macros, the exec family
        # (builtins/nysysmods.cpp); the child of a fork goes on alone
        # (nyconc::after_fork_child)
        def fork():
            return _sys_fork()
        def forkpty():
            return tuple(_sys_forkpty())
        def openpty():
            return tuple(_sys_openpty())
        def login_tty(fd):
            _sys_login_tty(_ny_os_fd(fd))
        def waitpid(pid, options):
            return tuple(_sys_waitpid(_ny_os_fd(pid), _ny_os_fd(options)))
        def ttyname(fd):
            return _sys_ttyname(_ny_os_fd(fd))
        def WIFEXITED(status):
            return _sys_wstatus("exited", status)
        def WEXITSTATUS(status):
            return _sys_wstatus("exitstatus", status)
        def WIFSIGNALED(status):
            return _sys_wstatus("signaled", status)
        def WTERMSIG(status):
            return _sys_wstatus("termsig", status)
        def WIFSTOPPED(status):
            return _sys_wstatus("stopped", status)
        def WSTOPSIG(status):
            return _sys_wstatus("stopsig", status)
        def WCOREDUMP(status):
            return _sys_wstatus("coredump", status)
        def WIFCONTINUED(status):
            return _sys_wstatus("continued", status)
        def waitstatus_to_exitcode(status):
            if _sys_wstatus("exited", status):
                return _sys_wstatus("exitstatus", status)
            if _sys_wstatus("signaled", status):
                return -_sys_wstatus("termsig", status)
            raise ValueError("invalid wait status: " + str(status))
        def execv(path, args):
            _ny_sys_audit("os.exec", path, args, None)   # round 86
            _sys_execv(_ny_os_str(path), [_ny_os_str(a) for a in args], None)
        def execve(path, args, env):
            _ny_sys_audit("os.exec", path, args, env)   # round 86
            _sys_execv(_ny_os_str(path), [_ny_os_str(a) for a in args],
                       [_ny_os_str(k) + "=" + _ny_os_str(env[k]) for k in env])
        def _execvpe(file, args, env=None):
            if _ny_osp_dirname(file):
                if env is None:
                    execv(file, args)
                else:
                    execve(file, args, env)
                return
            var saved = None
            var last = None
            for d in _ny_os_get_exec_path(env):
                var full = _ny_osp_join(d, file)
                try:
                    if env is None:
                        execv(full, args)
                    else:
                        execve(full, args, env)
                except (FileNotFoundError, NotADirectoryError) as e:
                    last = e
                except OSError as e:
                    last = e
                    if saved is None:
                        saved = e
            if saved is not None:
                raise saved
            if last is not None:
                raise last
            raise FileNotFoundError(2, "No such file or directory", file)
        def execl(file, *args):
            execv(file, args)
        def execle(file, *args):
            execve(file, args[:-1], args[-1])
        def execlp(file, *args):
            _execvpe(file, args)
        def execlpe(file, *args):
            _execvpe(file, args[:-1], args[-1])
        def execvp(file, args):
            _execvpe(file, args)
        def execvpe(file, args, env):
            _execvpe(file, args, env)
        for f in (fork, forkpty, openpty, login_tty, waitpid, ttyname, WIFEXITED, WEXITSTATUS, WIFSIGNALED,
                  WTERMSIG, WIFSTOPPED, WSTOPSIG, WCOREDUMP, WIFCONTINUED, waitstatus_to_exitcode, execv, execve,
                  execl, execle, execlp, execlpe, execvp, execvpe):
            f.__module__ = "posix"
            m.append((f.__name__, f))
        m.append(("WNOHANG", _sys_wstatus("WNOHANG", 0)))
        m.append(("WUNTRACED", _sys_wstatus("WUNTRACED", 0)))
        m.append(("WCONTINUED", _sys_wstatus("WCONTINUED", 0)))
        m.append(("environb", _ny_os_environb()))
        m.append(("get_blocking", _ny_os_get_blocking))
        m.append(("set_blocking", _ny_os_set_blocking))
        if os_platform() == "linux":
            def sched_getaffinity(pid):
                return set(_ny_os_call("sched_getaffinity", _ny_os_fd(pid)))
            m.append(("sched_getaffinity", sched_getaffinity))
    # (round 85) the rest of posixmodule.c (statvfs, sysconf, xattrs, the
    # scheduler, posix_spawn, popen, register_at_fork ...): the "posix"
    # chunk, src/NyPreludePosix.cpp - it appends its members to m
    _ny_load_chunk("posix")
    _ny_posix_extend(m)
    return m

_ny_os_members = _ny_os_member_list()
)NYMIRRORS";
}
// The text of one chunk of builtin_mirrors_source() ("" if there is none).
inline std::string builtin_mirror_chunk(const std::string& name) {
    if (name == "buffer") return prelude_buffer_source();   // (round 84) its own unit
    if (name == "posix") return prelude_posix_source();     // (round 85) its own unit
    if (name == "audit") return prelude_audit_source();     // (round 86) its own unit
    static const std::string src = builtin_mirrors_source();
    const std::string mark = "#@ " + name + "\n";
    size_t b = src.find(mark);
    if (b == std::string::npos) return std::string();
    b += mark.size();
    size_t e = src.find("\n#@ ", b);
    return src.substr(b, e == std::string::npos ? std::string::npos : e + 1 - b);
}

} // namespace nyrt
