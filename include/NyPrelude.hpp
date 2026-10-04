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

namespace nyrt {

inline const char* prelude_source() {
    return R"NYPRELUDE(
class NythonFile:
    def __init__(self, path, mode, handle):
        self.name = path
        self.mode = mode
        self.handle = handle
        self.closed = false

    def _check(self):
        if self.closed:
            raise ValueError("I/O operation on closed file: " + self.name)

    def read(self, size=-1):
        self._check()
        return file_read(self.handle, size)

    def readline(self):
        self._check()
        return file_readline(self.handle, true)

    def readlines(self):
        self._check()
        var out = []
        var line = file_readline(self.handle, true)
        while line != "":
            out.append(line)
            line = file_readline(self.handle, true)
        return out

    def write(self, data):
        self._check()
        return file_write(self.handle, str(data))

    def writelines(self, lines):
        self._check()
        var i = 0
        while i < len(lines):
            file_write(self.handle, str(lines[i]))
            i = i + 1
        return none

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
        if line == "":
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

def open(path, mode="r", encoding="utf-8"):
    return NythonFile(path, mode, file_open_or_raise(path, mode))
)NYPRELUDE";
}

} // namespace nyrt
