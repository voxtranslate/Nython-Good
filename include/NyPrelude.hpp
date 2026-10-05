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

namespace nyrt {

inline const char* prelude_source() {
    return R"NYPRELUDE(
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
                raise TypeError("a bytes-like object is required, not '" + data.type_name() + "'")
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

    def fileno(self):
        return self.handle

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
        return "<file '" + self.name + "' mode '" + self.mode + "'>"

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

class _NyCode:
    # what compile(source, filename, mode) returns; eval() / exec() run it
    def __init__(self, source, filename, mode):
        self.source = source
        self.co_filename = filename
        self.mode = mode
        self.co_name = "<module>"

    def __repr__(self):
        return "<code object <module>, file \"" + self.co_filename + "\", line 1>"

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
        # (round 77; a class's own __new__ runs before __init__)
        return _ny_object_new(cls)
    @classmethod
    def __init_subclass__(cls, **kw):
        # the end of every super().__init_subclass__(**kw) chain
        if len(kw) > 0:
            raise TypeError(cls.__name__ + ".__init_subclass__() takes no keyword arguments")
    # the root of the class tree (round 77; `object` was undefined):
    # object(), class C(object), object.__init__(self) in a super() chain,
    # and the plain attribute store a __setattr__ hands on to
    # (object.__setattr__(self, k, v) / super().__setattr__(k, v))
    def __init__(self, *args, **kwargs):
        pass

    def __setattr__(self, name, value):
        _ny_setattr_raw(self, name, value)

    def __delattr__(self, name):
        _ny_delattr_raw(self, name)

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

def open(path, mode="r", buffering=-1, encoding="utf-8", errors=none, newline=none, closefd=true, opener=none):
    # Python's parameters in Python's order (round 77: encoding was third)
    if hasattr(path, "__fspath__"):
        path = path.__fspath__()
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

class _NyAsyncGen:
    def __init__(self, g):
        self._g = g

    def __aiter__(self):
        return self

    def __anext__(self):
        try:
            return next(self._g)
        except StopIteration:
            raise StopAsyncIteration()

    def asend(self, value):
        try:
            return self._g.send(value)
        except StopIteration:
            raise StopAsyncIteration()

    def athrow(self, *exc):
        try:
            return self._g.throw(*exc)
        except StopIteration:
            raise StopAsyncIteration()

    def aclose(self):
        self._g.close()

    def __iter__(self):
        return self._g

    def __repr__(self):
        return "<async_generator object>"

def _ny_async_gen(g):
    return _NyAsyncGen(g)

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
)NYPRELUDE";
}

} // namespace nyrt
