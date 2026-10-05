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
        file_write(self.handle, text)
        return len(text)

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
        file = _ny_stdout
    file.write(sep.join([str(a) for a in args]) + end)
    if kw.get("flush", false):
        file.flush()
    return none

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

def exit(code=none):
    # Python's: SystemExit, so finally blocks run and `except SystemExit`
    # can stop it (round 77; it ended the process on the spot). The program
    # ends with the code when nothing catches it.
    raise SystemExit(code)

def quit(code=none):
    raise SystemExit(code)

def open(path, mode="r", encoding="utf-8", errors=none, newline=none, buffering=-1):
    if "b" in mode and encoding != "utf-8" and encoding is not none:
        raise ValueError("binary mode doesn't take an encoding argument")
    return NythonFile(path, mode, file_open_or_raise(path, mode), encoding if encoding is not none else "utf-8")

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
