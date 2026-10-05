# nython: module    (import it by name: it runs in a module scope of its own)
# lib/io.ny - Python's io module (CPython 3.12): in-memory streams and the
# stream base classes.
#
#     import io
#     buf = io.StringIO(); print("hi", file=buf); buf.getvalue()
#     b = io.BytesIO(b"abc"); b.seek(0, io.SEEK_END); b.write(b"d")
#
# StringIO      text in memory: read(n), readline(limit), readlines(hint),
#               write, writelines, seek(pos, whence), tell, getvalue,
#               truncate, iteration, close/closed, with, readable/writable/
#               seekable, newline=None/""/"\n"/"\r"/"\r\n" as Python
#               translates and splits lines
# BytesIO       bytes in memory: the same, plus read1, readinto, getbuffer
#               (a copy here), and writes past the end padded with zeros
# TextIOWrapper text over a binary stream (encoding, errors, newline=None
#               reading universal newlines)
# IOBase, RawIOBase, BufferedIOBase, TextIOBase  base classes to subclass:
#               iteration, readlines, writelines, context management and the
#               closed checks come from IOBase as in Python
# UnsupportedOperation (OSError and ValueError), SEEK_SET/SEEK_CUR/SEEK_END,
# DEFAULT_BUFFER_SIZE, open (the builtin open), text_encoding
#
# StringIO keeps appended text as a list of pieces and joins it only when
# something needs the whole text, so building a string with many write()
# calls is linear, not quadratic.
#
# Not here: FileIO, BufferedReader/Writer/Random/RWPair (open() returns the
# runtime's file objects), getbuffer() as a live memoryview.
# Note: print() writes to a StringIO given as file=; assigning sys.stdout
# does not redirect the print statement (the engines write to the process's
# standard output directly).

SEEK_SET = 0
SEEK_CUR = 1
SEEK_END = 2
DEFAULT_BUFFER_SIZE = 8192

open = open


class UnsupportedOperation(OSError, ValueError):
    pass


def text_encoding(encoding, stacklevel=2):
    """The encoding open() and TextIOWrapper use when none is given."""
    if encoding is not none:
        return encoding
    return "utf-8"


def _closed_error():
    raise ValueError("I/O operation on closed file")


# ── base classes ─────────────────────────────────────────────────────────────
class IOBase:
    """The abstract base class for all I/O classes."""

    _closed_flag = false

    def _unsupported(self, name):
        raise UnsupportedOperation(name)

    def seek(self, pos, whence=0):
        self._unsupported("seek")

    def tell(self):
        return self.seek(0, 1)

    def truncate(self, pos=none):
        self._unsupported("truncate")

    def flush(self):
        self._checkClosed()
        return none

    def close(self):
        if not self._closed_flag:
            try:
                self.flush()
            finally:
                self._closed_flag = true
        return none

    @property
    def closed(self):
        return self._closed_flag

    def _checkClosed(self, msg=none):
        if self.closed:
            raise ValueError("I/O operation on closed file." if msg is none else msg)

    def _checkReadable(self):
        if not self.readable():
            raise UnsupportedOperation("File or stream is not readable.")

    def _checkWritable(self):
        if not self.writable():
            raise UnsupportedOperation("File or stream is not writable.")

    def _checkSeekable(self):
        if not self.seekable():
            raise UnsupportedOperation("File or stream is not seekable.")

    def seekable(self):
        return false

    def readable(self):
        return false

    def writable(self):
        return false

    def __enter__(self):
        self._checkClosed()
        return self

    def __exit__(self, *args):
        self.close()
        return false

    def fileno(self):
        self._unsupported("fileno")

    def isatty(self):
        self._checkClosed()
        return false

    def readline(self, size=-1):
        """Read and return a line of bytes from the stream."""
        if size is none:
            size = -1
        var out = bytearray()
        while size < 0 or len(out) < size:
            var b = self.read(1)
            if not b:
                break
            out = out + b
            if b == b"\n":
                break
        return bytes(out)

    def __iter__(self):
        self._checkClosed()
        return self

    def __next__(self):
        var line = self.readline()
        if not line:
            raise StopIteration()
        return line

    def readlines(self, hint=none):
        """Return a list of lines from the stream (stopping after hint
        characters/bytes when hint is given and positive)."""
        if hint is none or hint <= 0:
            return list(self)
        var n = 0
        var lines = []
        for line in self:
            lines.append(line)
            n = n + len(line)
            if n >= hint:
                break
        return lines

    def writelines(self, lines):
        """Write a list of lines to the stream."""
        self._checkClosed()
        for line in lines:
            self.write(line)
        return none


class RawIOBase(IOBase):
    """Base class for raw binary I/O."""

    def read(self, size=-1):
        if size is none:
            size = -1
        if size < 0:
            return self.readall()
        var b = bytearray(size)
        var n = self.readinto(b)
        if n is none:
            return none
        return bytes(b[0:n])

    def readall(self):
        var res = bytearray()
        while true:
            var data = self.read(DEFAULT_BUFFER_SIZE)
            if not data:
                break
            res = res + data
        return bytes(res)

    def readinto(self, b):
        self._unsupported("readinto")

    def write(self, b):
        self._unsupported("write")


class BufferedIOBase(IOBase):
    """Base class for buffered IO objects."""

    def read(self, size=-1):
        self._unsupported("read")

    def read1(self, size=-1):
        self._unsupported("read1")

    def readinto(self, b):
        var data = self.read(len(b))
        var n = len(data)
        b[0:n] = data
        return n

    def readinto1(self, b):
        return self.readinto(b)

    def write(self, b):
        self._unsupported("write")

    def detach(self):
        self._unsupported("detach")


class TextIOBase(IOBase):
    """Base class for text I/O."""

    encoding = none
    errors = none
    newlines = none

    def read(self, size=-1):
        self._unsupported("read")

    def write(self, s):
        self._unsupported("write")

    def truncate(self, pos=none):
        self._unsupported("truncate")

    def readline(self, size=-1):
        self._unsupported("readline")

    def detach(self):
        self._unsupported("detach")


# ── StringIO ─────────────────────────────────────────────────────────────────
def _translate_in(s, newline):
    # what write() stores, given the stream's newline
    if newline is none:
        return s.replace("\r\n", "\n").replace("\r", "\n")
    if newline == "\r\n" or newline == "\r":
        return s.replace("\n", newline)
    return s


class StringIO(TextIOBase):
    """Text I/O implementation using an in-memory buffer."""

    def __init__(self, initial_value="", newline="\n"):
        if initial_value is not none and not isinstance(initial_value, str):
            raise TypeError("initial_value must be str or None, not " + type(initial_value).__name__)
        if newline is not none and not isinstance(newline, str):
            raise TypeError("newline must be str or None, not " + type(newline).__name__)
        if not (newline is none or newline == "" or newline == "\n" or newline == "\r" or newline == "\r\n"):
            raise ValueError("illegal newline value: " + repr(newline))
        self._newline = newline
        self._text = ""          # the joined part
        self._pieces = []        # appended after it, not yet joined
        self._len = 0
        self._pos = 0
        self._closed_flag = false
        self._seen = 0           # newline kinds seen (newline=None): 1 \r, 2 \n, 4 \r\n
        if initial_value:
            self.write(initial_value)
            self._pos = 0

    def _join(self):
        if len(self._pieces) > 0:
            self._text = self._text + "".join(self._pieces)
            self._pieces = []
        return self._text

    def _check(self):
        if self._closed_flag:
            raise ValueError("I/O operation on closed file")

    def _note_newlines(self, s):
        if "\r\n" in s:
            self._seen = self._seen | 4
            s = s.replace("\r\n", "")
        if "\r" in s:
            self._seen = self._seen | 1
        if "\n" in s:
            self._seen = self._seen | 2

    @property
    def newlines(self):
        if self._newline is not none:
            return none
        var kinds = []
        if self._seen & 1:
            kinds.append("\r")
        if self._seen & 2:
            kinds.append("\n")
        if self._seen & 4:
            kinds.append("\r\n")
        if len(kinds) == 0:
            return none
        if len(kinds) == 1:
            return kinds[0]
        return tuple(kinds)

    @property
    def closed(self):
        return self._closed_flag

    @property
    def line_buffering(self):
        return false

    def close(self):
        self._closed_flag = true
        return none

    def readable(self):
        self._check()
        return true

    def writable(self):
        self._check()
        return true

    def seekable(self):
        self._check()
        return true

    def flush(self):
        self._check()
        return none

    def getvalue(self):
        """Retrieve the entire contents of the object."""
        self._check()
        return self._join()

    def write(self, s):
        """Write string to file. Returns the number of characters written."""
        self._check()
        if not isinstance(s, str):
            raise TypeError("string argument expected, got '" + type(s).__name__ + "'")
        var n = len(s)
        if n == 0:
            return 0
        if self._newline is none:
            self._note_newlines(s)
        var t = _translate_in(s, self._newline)
        var tn = len(t)
        if self._pos == self._len:
            self._pieces.append(t)
            self._len = self._len + tn
            self._pos = self._len
            return n
        var text = self._join()
        if self._pos > self._len:
            text = text + "\0" * (self._pos - self._len)
            self._len = self._pos
        text = text[0:self._pos] + t + text[self._pos + tn:]
        self._text = text
        self._pos = self._pos + tn
        if self._pos > self._len:
            self._len = self._pos
        return n

    def read(self, size=-1):
        """Read at most size characters, returned as a string."""
        self._check()
        if size is not none and not isinstance(size, int):
            raise TypeError("argument should be integer or None, not '" + type(size).__name__ + "'")
        var text = self._join()
        if self._pos >= self._len:
            return ""
        var end = self._len
        if size is not none and size >= 0:
            end = min(self._pos + size, self._len)
        var out = text[self._pos:end]
        self._pos = end
        return out

    def _line_end(self, text, start, limit_end):
        # the index after the line that starts at start
        var nl = self._newline
        var i = -1
        if nl is none or nl == "\n":
            i = text.find("\n", start, limit_end)
            return limit_end if i < 0 else i + 1
        if nl == "":
            var j = start
            while j < limit_end:
                var ch = text[j]
                if ch == "\n":
                    return j + 1
                if ch == "\r":
                    if j + 1 < limit_end and text[j + 1] == "\n":
                        return j + 2
                    return j + 1
                j = j + 1
            return limit_end
        i = text.find(nl, start, limit_end)
        return limit_end if i < 0 else i + len(nl)

    def readline(self, size=-1):
        """Read until newline or EOF."""
        self._check()
        if size is not none and not isinstance(size, int):
            raise TypeError("argument should be integer or None, not '" + type(size).__name__ + "'")
        var text = self._join()
        if self._pos >= self._len:
            return ""
        var limit_end = self._len
        if size is not none and size >= 0:
            limit_end = min(self._pos + size, self._len)
        var end = self._line_end(text, self._pos, limit_end)
        var out = text[self._pos:end]
        self._pos = end
        return out

    def __next__(self):
        self._check()
        var line = self.readline()
        if len(line) == 0:
            raise StopIteration()
        return line

    def __iter__(self):
        self._check()
        return self

    def readlines(self, hint=none):
        self._check()
        var lines = []
        var n = 0
        while true:
            var line = self.readline()
            if len(line) == 0:
                break
            lines.append(line)
            n = n + len(line)
            if hint is not none and hint > 0 and n >= hint:
                break
        return lines

    def writelines(self, lines):
        self._check()
        for line in lines:
            self.write(line)
        return none

    def tell(self):
        """Tell the current file position."""
        self._check()
        return self._pos

    def seek(self, pos, whence=0):
        """Change stream position."""
        self._check()
        if not isinstance(pos, int):
            raise TypeError("'" + type(pos).__name__ + "' object cannot be interpreted as an integer")
        if whence == 0:
            if pos < 0:
                raise ValueError("Negative seek position " + str(pos))
            self._pos = pos
        elif whence == 1:
            if pos != 0:
                raise OSError("Can't do nonzero cur-relative seeks")
        elif whence == 2:
            if pos != 0:
                raise OSError("Can't do nonzero end-relative seeks")
            self._pos = self._len
        else:
            raise ValueError("Invalid whence (" + str(whence) + ", should be 0, 1 or 2)")
        return self._pos

    def truncate(self, size=none):
        """Truncate size to pos (the current position by default)."""
        self._check()
        if size is none:
            size = self._pos
        if not isinstance(size, int):
            raise TypeError("'" + type(size).__name__ + "' object cannot be interpreted as an integer")
        if size < 0:
            raise ValueError("Negative size value " + str(size))
        if size < self._len:
            self._text = self._join()[0:size]
            self._len = size
        return size

    def detach(self):
        raise UnsupportedOperation("detach")

    def fileno(self):
        raise UnsupportedOperation("fileno")

    def isatty(self):
        self._check()
        return false

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *args):
        self.close()
        return false

    def __getstate__(self):
        return (self.getvalue(), self._newline, self._pos)


# ── BytesIO ──────────────────────────────────────────────────────────────────
def _as_bytes(b):
    if isinstance(b, bytes) or isinstance(b, bytearray):
        return b
    if isinstance(b, str):
        raise TypeError("a bytes-like object is required, not 'str'")
    if hasattr(b, "tobytes"):
        return b.tobytes()
    raise TypeError("a bytes-like object is required, not '" + type(b).__name__ + "'")


class BytesIO(BufferedIOBase):
    """Buffered I/O implementation using an in-memory bytes buffer."""

    def __init__(self, initial_bytes=none):
        self._buf = bytearray()
        self._pos = 0
        self._closed_flag = false
        if initial_bytes is not none:
            self._buf = bytearray(_as_bytes(initial_bytes))

    def _check(self):
        if self._closed_flag:
            raise ValueError("I/O operation on closed file.")

    @property
    def closed(self):
        return self._closed_flag

    def close(self):
        self._closed_flag = true
        return none

    def readable(self):
        self._check()
        return true

    def writable(self):
        self._check()
        return true

    def seekable(self):
        self._check()
        return true

    def flush(self):
        self._check()
        return none

    def getvalue(self):
        """Retrieve the entire contents of the BytesIO object."""
        self._check()
        return bytes(self._buf)

    def getbuffer(self):
        """A copy of the contents (Python gives a live memoryview)."""
        self._check()
        return bytearray(self._buf)

    def write(self, b):
        """Write bytes to file. Return the number of bytes written."""
        self._check()
        var data = _as_bytes(b)
        var n = len(data)
        if n == 0:
            return 0
        var size = len(self._buf)
        if self._pos > size:
            self._buf.extend(bytes(self._pos - size))
            size = self._pos
        if self._pos == size:
            self._buf.extend(data)
        else:
            self._buf[self._pos:self._pos + n] = data
        self._pos = self._pos + n
        return n

    def read(self, size=-1):
        """Read at most size bytes, returned as a bytes object."""
        self._check()
        var n = len(self._buf)
        if self._pos >= n:
            return b""
        var end = n
        if size is not none and size >= 0:
            end = min(self._pos + size, n)
        var out = bytes(self._buf[self._pos:end])
        self._pos = end
        return out

    def read1(self, size=-1):
        return self.read(size)

    def readinto(self, b):
        self._check()
        var data = self.read(len(b))
        var n = len(data)
        b[0:n] = data
        return n

    def readline(self, size=-1):
        """Next line from the file, as a bytes object."""
        self._check()
        var n = len(self._buf)
        if self._pos >= n:
            return b""
        var limit = n
        if size is not none and size >= 0:
            limit = min(self._pos + size, n)
        var i = self._buf.find(b"\n", self._pos, limit)
        var end = limit if i < 0 else i + 1
        var out = bytes(self._buf[self._pos:end])
        self._pos = end
        return out

    def __next__(self):
        self._check()
        var line = self.readline()
        if len(line) == 0:
            raise StopIteration()
        return line

    def __iter__(self):
        self._check()
        return self

    def readlines(self, hint=none):
        self._check()
        var lines = []
        var total = 0
        while true:
            var line = self.readline()
            if len(line) == 0:
                break
            lines.append(line)
            total = total + len(line)
            if hint is not none and hint > 0 and total >= hint:
                break
        return lines

    def writelines(self, lines):
        self._check()
        for line in lines:
            self.write(line)
        return none

    def tell(self):
        self._check()
        return self._pos

    def seek(self, pos, whence=0):
        """Change stream position."""
        self._check()
        if not isinstance(pos, int):
            raise TypeError("'" + type(pos).__name__ + "' object cannot be interpreted as an integer")
        if whence == 0:
            if pos < 0:
                raise ValueError("negative seek value " + str(pos))
            self._pos = pos
        elif whence == 1:
            self._pos = max(0, self._pos + pos)
        elif whence == 2:
            self._pos = max(0, len(self._buf) + pos)
        else:
            raise ValueError("invalid whence (" + str(whence) + ", should be 0, 1 or 2)")
        return self._pos

    def truncate(self, size=none):
        """Truncate the file to at most size bytes (the position by default)."""
        self._check()
        if size is none:
            size = self._pos
        if size < 0:
            raise ValueError("negative size value " + str(size))
        if size < len(self._buf):
            self._buf = self._buf[0:size]
        return size

    def isatty(self):
        self._check()
        return false

    def fileno(self):
        raise UnsupportedOperation("fileno")

    def detach(self):
        raise UnsupportedOperation("detach")

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *args):
        self.close()
        return false


# ── TextIOWrapper ────────────────────────────────────────────────────────────
class TextIOWrapper(TextIOBase):
    """Character and line based layer over a binary stream (read and write
    the whole of what is asked; the text decoded so far is kept)."""

    def __init__(self, buffer, encoding=none, errors=none, newline=none, line_buffering=false, write_through=false):
        self.buffer = buffer
        self.encoding = text_encoding(encoding)
        self.errors = "strict" if errors is none else errors
        if not (newline is none or newline == "" or newline == "\n" or newline == "\r" or newline == "\r\n"):
            raise ValueError("illegal newline value: " + repr(newline))
        self._newline = newline
        self.line_buffering = line_buffering
        self.write_through = write_through
        self._pending = ""     # decoded text not yet returned
        self._closed_flag = false

    @property
    def closed(self):
        return self.buffer.closed

    @property
    def name(self):
        return self.buffer.name

    def readable(self):
        return self.buffer.readable()

    def writable(self):
        return self.buffer.writable()

    def seekable(self):
        return self.buffer.seekable()

    def fileno(self):
        return self.buffer.fileno()

    def isatty(self):
        return self.buffer.isatty()

    def flush(self):
        self.buffer.flush()
        return none

    def close(self):
        if not self.buffer.closed:
            self.flush()
            self.buffer.close()
        return none

    def detach(self):
        var b = self.buffer
        self.buffer = none
        return b

    def _decode(self, data):
        var text = bytes(data).decode(self.encoding, self.errors)
        if self._newline is none:
            text = text.replace("\r\n", "\n").replace("\r", "\n")
        return text

    def write(self, s):
        if not isinstance(s, str):
            raise TypeError("write() argument must be str, not " + type(s).__name__)
        var t = s
        if self._newline is not none and self._newline != "" and self._newline != "\n":
            t = t.replace("\n", self._newline)
        self.buffer.write(t.encode(self.encoding, self.errors))
        if self.line_buffering and ("\n" in s or "\r" in s):
            self.flush()
        return len(s)

    def read(self, size=-1):
        var rest = self._decode(self.buffer.read())
        var text = self._pending + rest
        if size is none or size < 0:
            self._pending = ""
            return text
        self._pending = text[size:]
        return text[0:size]

    def readline(self, size=-1):
        if len(self._pending) == 0 or not ("\n" in self._pending):
            self._pending = self._pending + self._decode(self.buffer.read())
        var text = self._pending
        var i = text.find("\n")
        var end = len(text) if i < 0 else i + 1
        if size is not none and size >= 0 and size < end:
            end = size
        self._pending = text[end:]
        return text[0:end]

    def __next__(self):
        var line = self.readline()
        if len(line) == 0:
            raise StopIteration()
        return line

    def __iter__(self):
        return self

    def seek(self, pos, whence=0):
        self._pending = ""
        return self.buffer.seek(pos, whence)

    def tell(self):
        return self.buffer.tell() - len(self._pending.encode(self.encoding, self.errors))
