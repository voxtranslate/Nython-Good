# nython: module    (import it by name: it runs in a module scope of its own)
# lib/gzip.ny - Python's gzip (round 79): read and write gzip files
# (RFC 1952) over lib/zlib.ny, interchangeable with CPython's and gzip(1)'s.
#
#     import gzip
#     with gzip.open("log.gz", "wt") as f: f.write("text\n")
#     data = gzip.decompress(gzip.compress(b"abc", mtime=0))
#     with gzip.GzipFile(fileobj=io.BytesIO(blob)) as f: f.read()
#
# open(filename, mode="rb", compresslevel=9, encoding, errors, newline):
#     "r" "rb" "w" "wb" "a" "ab" "x" "xb", and "rt" "wt" "at" "xt" through
#     io.TextIOWrapper; filename is a path or a file object
# GzipFile(filename, mode, compresslevel, fileobj, mtime): read (several
#     members in a row, zero padding between them, the CRC-32 and size of
#     each checked: BadGzipFile), write and append (a new member), the
#     original file name and mtime in the header (.mtime after reading),
#     read/read1/readinto/peek/readline/readlines/iteration, seek and tell
#     (forward in write mode, anywhere when reading: back by rewinding),
#     flush(zlib_mode), rewind, closed, name, mode, with
# compress(data, compresslevel=9, mtime=None), decompress(data) (every
#     member), BadGzipFile (an OSError), READ/WRITE, the FTEXT.. flags
#
# Not here: the command-line interface (python -m gzip); a filename given
# as bytes or a path-like object is used through str(). Python's
# GzipFile.flush/seek in write mode and the 128 KiB read buffer are kept
# (the buffer is not an io.BufferedReader).
import io
import os
import time
import zlib

__all__ = ["BadGzipFile", "GzipFile", "open", "compress", "decompress"]

FTEXT = 1
FHCRC = 2
FEXTRA = 4
FNAME = 8
FCOMMENT = 16
READ = "rb"
WRITE = "wb"
_COMPRESS_LEVEL_FAST = 1
_COMPRESS_LEVEL_TRADEOFF = 6
_COMPRESS_LEVEL_BEST = 9
READ_BUFFER_SIZE = 128 * 1024
_EBADF = 9

_builtin_open = open


class BadGzipFile(OSError):
    pass


def _u32(v):
    var x = int(v) & 0xffffffff
    return bytes([x & 255, (x >> 8) & 255, (x >> 16) & 255, (x >> 24) & 255])


def _le(b, off, n):
    var v = 0
    var i = n - 1
    while i >= 0:
        v = (v << 8) | b[off + i]
        i = i - 1
    return v


def open(filename, mode="rb", compresslevel=_COMPRESS_LEVEL_BEST, encoding=none, errors=none, newline=none):
    if "t" in mode:
        if "b" in mode:
            raise ValueError("Invalid mode: " + repr(mode))
    else:
        if encoding is not none:
            raise ValueError("Argument 'encoding' not supported in binary mode")
        if errors is not none:
            raise ValueError("Argument 'errors' not supported in binary mode")
        if newline is not none:
            raise ValueError("Argument 'newline' not supported in binary mode")
    var gz_mode = mode.replace("t", "")
    var binary_file = none
    if isinstance(filename, str) or isinstance(filename, bytes) or hasattr(filename, "__fspath__"):
        binary_file = GzipFile(filename, gz_mode, compresslevel)
    elif hasattr(filename, "read") or hasattr(filename, "write"):
        binary_file = GzipFile(none, gz_mode, compresslevel, filename)
    else:
        raise TypeError("filename must be a str or bytes object, or a file")
    if "t" in mode:
        return io.TextIOWrapper(binary_file, io.text_encoding(encoding), errors, newline)
    return binary_file


def _fspath(p):
    if isinstance(p, str):
        return p
    if isinstance(p, bytes):
        return p.decode("utf-8", "surrogateescape")
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    return str(p)


class _PaddedFile:
    """A file with bytes put back in front of it (CPython's _PaddedFile)."""

    def __init__(self, f, prepend=b""):
        self._buffer = prepend
        self._length = len(prepend)
        self.file = f
        self._read = 0

    def read(self, size):
        if self._read is none:
            return self.file.read(size)
        if self._read + size <= self._length:
            var r = self._read
            self._read = self._read + size
            return self._buffer[r:self._read]
        var r = self._read
        self._read = none
        return self._buffer[r:] + self.file.read(size - self._length + r)

    def prepend(self, prepend=b""):
        if self._read is none:
            self._buffer = prepend
        else:
            self._read = self._read - len(prepend)
            return
        self._length = len(self._buffer)
        self._read = 0

    def seek(self, off):
        self._read = none
        self._buffer = none
        return self.file.seek(off)

    def seekable(self):
        return true


def _read_exact(fp, n):
    var data = fp.read(n)
    while len(data) < n:
        var b = fp.read(n - len(data))
        if not b:
            raise EOFError("Compressed file ended before the end-of-stream marker was reached")
        data = data + b
    return data


def _read_gzip_header(fp):
    var magic = fp.read(2)
    if magic == b"":
        return none
    if magic != b"\x1f\x8b":
        raise BadGzipFile("Not a gzipped file (" + repr(magic) + ")")
    var h = _read_exact(fp, 8)
    var method = h[0]
    var flag = h[1]
    var last_mtime = _le(h, 2, 4)
    if method != 8:
        raise BadGzipFile("Unknown compression method")
    if flag & FEXTRA:
        var xl = _read_exact(fp, 2)
        _read_exact(fp, xl[0] | (xl[1] << 8))
    if flag & FNAME:
        while true:
            var s = fp.read(1)
            if not s or s == b"\x00":
                break
    if flag & FCOMMENT:
        while true:
            var s = fp.read(1)
            if not s or s == b"\x00":
                break
    if flag & FHCRC:
        _read_exact(fp, 2)
    return last_mtime


class _GzipReader:
    """The decompressed bytes of a gzip file, member after member
    (CPython's _GzipReader over _compression.DecompressReader)."""

    def __init__(self, fp):
        self._fp = _PaddedFile(fp)
        self._eof = false
        self._pos = 0
        self._size = -1
        self._decompressor = zlib.decompressobj(-zlib.MAX_WBITS)
        self._new_member = true
        self._last_mtime = none
        self._crc = 0
        self._stream_size = 0

    def _init_read(self):
        self._crc = 0
        self._stream_size = 0

    def read(self, size=-1):
        if size < 0:
            var chunks = []
            while true:
                var d = self.read(1 << 30)
                if not d:
                    break
                chunks.append(d)
            return b"".join(chunks)
        if not size or self._eof:
            return b""
        var uncompress = b""
        while true:
            if self._decompressor.eof:
                self._read_eof()
                self._new_member = true
                self._decompressor = zlib.decompressobj(-zlib.MAX_WBITS)
            if self._new_member:
                self._init_read()
                var m = _read_gzip_header(self._fp)
                if m is none:
                    self._size = self._pos
                    self._eof = true
                    return b""
                self._last_mtime = m
                self._new_member = false
            var buf = self._fp.read(io.DEFAULT_BUFFER_SIZE)
            uncompress = self._decompressor.decompress(buf, size)
            if self._decompressor.unconsumed_tail != b"":
                self._fp.prepend(self._decompressor.unconsumed_tail)
            elif self._decompressor.unused_data != b"":
                self._fp.prepend(self._decompressor.unused_data)
            if uncompress != b"":
                break
            if buf == b"" and not self._decompressor.eof:
                raise EOFError("Compressed file ended before the end-of-stream marker was reached")
        self._crc = zlib.crc32(uncompress, self._crc)
        self._stream_size = self._stream_size + len(uncompress)
        self._pos = self._pos + len(uncompress)
        return uncompress

    def _read_eof(self):
        var t = _read_exact(self._fp, 8)
        var crc32 = _le(t, 0, 4)
        var isize = _le(t, 4, 4)
        if crc32 != self._crc:
            raise BadGzipFile("CRC check failed " + hex(crc32) + " != " + hex(self._crc))
        elif isize != (self._stream_size & 0xffffffff):
            raise BadGzipFile("Incorrect length of data produced")
        # members may be followed by zero padding
        var c = b"\x00"
        while c == b"\x00":
            c = self._fp.read(1)
        if c:
            self._fp.prepend(c)

    def rewind(self):
        self._fp.seek(0)
        self._eof = false
        self._pos = 0
        self._decompressor = zlib.decompressobj(-zlib.MAX_WBITS)
        self._new_member = true


class GzipFile(io.BufferedIOBase):
    """A gzip file: like a binary file object, compressing what is written
    and decompressing what is read."""

    myfileobj = none

    def __init__(self, filename=none, mode=none, compresslevel=_COMPRESS_LEVEL_BEST, fileobj=none, mtime=none):
        if mode and ("t" in mode or "U" in mode):
            raise ValueError("Invalid mode: " + repr(mode))
        if mode and "b" not in mode:
            mode = mode + "b"
        if fileobj is none:
            fileobj = _builtin_open(_fspath(filename), mode or "rb")
            self.myfileobj = fileobj
        if filename is none:
            filename = getattr(fileobj, "name", "")
            if not (isinstance(filename, str) or isinstance(filename, bytes)):
                filename = ""
        else:
            filename = _fspath(filename)
        var origmode = mode
        if mode is none:
            mode = getattr(fileobj, "mode", "rb")
        self._rbuf = b""
        self._rpos = 0
        self._offset_r = 0
        if mode.startswith("r"):
            self.mode = READ
            self._reader = _GzipReader(fileobj)
            self.name = filename
        elif mode.startswith("w") or mode.startswith("a") or mode.startswith("x"):
            self.mode = WRITE
            self.name = filename
            self.crc = 0
            self.size = 0
            self.offset = 0
            self.compress = zlib.compressobj(compresslevel, zlib.DEFLATED, -zlib.MAX_WBITS, zlib.DEF_MEM_LEVEL, 0)
            self._write_mtime = mtime
        else:
            raise ValueError("Invalid mode: " + repr(mode))
        self.fileobj = fileobj
        if self.mode == WRITE:
            self._write_gzip_header(compresslevel)

    @property
    def mtime(self):
        """Last modification time read from stream, or None"""
        if self.mode != READ:
            return none
        return self._reader._last_mtime

    def __repr__(self):
        var s = repr(self.fileobj)
        return "<gzip " + s[1:-1] + " " + hex(id(self)) + ">"

    def _write_gzip_header(self, compresslevel):
        var f = self.fileobj
        f.write(b"\x1f\x8b\x08")
        var fname = b""
        try:
            var bn = os.path.basename(self.name)
            fname = bn if isinstance(bn, bytes) else bn.encode("latin-1")
            if fname.endswith(b".gz"):
                fname = fname[:-3]
        except UnicodeEncodeError:
            fname = b""
        var flags = FNAME if fname else 0
        f.write(bytes([flags]))
        var mtime = self._write_mtime
        if mtime is none:
            mtime = time.time()
        f.write(_u32(int(mtime)))
        if compresslevel == _COMPRESS_LEVEL_BEST:
            f.write(b"\x02")
        elif compresslevel == _COMPRESS_LEVEL_FAST:
            f.write(b"\x04")
        else:
            f.write(b"\x00")
        f.write(b"\xff")
        if fname:
            f.write(fname + b"\x00")

    def _check_not_closed(self):
        if self.fileobj is none:
            raise ValueError("I/O operation on closed file.")

    def write(self, data):
        self._check_not_closed()
        if self.mode != WRITE:
            raise OSError(_EBADF, "write() on read-only GzipFile object")
        if not (isinstance(data, bytes) or isinstance(data, bytearray)):
            if isinstance(data, str):
                raise TypeError("memoryview: a bytes-like object is required, not 'str'")
            data = zlib._data(data)
        var length = len(data)
        if length > 0:
            self.fileobj.write(self.compress.compress(data))
            self.size = self.size + length
            self.crc = zlib.crc32(data, self.crc)
            self.offset = self.offset + length
        return length

    # ── reading: a buffer over the decompressed stream ─────────────────────
    def _fill(self, n):
        # at least n bytes buffered (fewer at the end)
        while len(self._rbuf) - self._rpos < n:
            var d = self._reader.read(max(n, READ_BUFFER_SIZE))
            if not d:
                break
            self._rbuf = self._rbuf[self._rpos:] + d
            self._rpos = 0

    def _check_read(self, what):
        self._check_not_closed()
        if self.mode != READ:
            raise OSError(_EBADF, what + "() on write-only GzipFile object")

    def read(self, size=-1):
        self._check_read("read")
        if size is none or size < 0:
            var rest = self._rbuf[self._rpos:] + self._reader.read()
            self._rbuf = b""
            self._rpos = 0
            self._offset_r = self._offset_r + len(rest)
            return rest
        self._fill(size)
        var out = self._rbuf[self._rpos:self._rpos + size]
        self._rpos = self._rpos + len(out)
        self._offset_r = self._offset_r + len(out)
        return out

    def read1(self, size=-1):
        self._check_read("read1")
        if size is none or size < 0:
            size = io.DEFAULT_BUFFER_SIZE
        if self._rpos >= len(self._rbuf):
            self._fill(1)
        var out = self._rbuf[self._rpos:self._rpos + size]
        self._rpos = self._rpos + len(out)
        self._offset_r = self._offset_r + len(out)
        return out

    def readinto(self, b):
        var d = self.read(len(b))
        b[0:len(d)] = d
        return len(d)

    def peek(self, n):
        self._check_read("peek")
        if self._rpos >= len(self._rbuf):
            self._fill(max(n, 1))
        return self._rbuf[self._rpos:]

    def readline(self, size=-1):
        self._check_not_closed()
        var out = b""
        while true:
            var avail = self._rbuf[self._rpos:]
            var nl = avail.find(b"\n")
            if nl >= 0:
                var take = nl + 1
                if size is not none and size >= 0 and len(out) + take > size:
                    take = size - len(out)
                out = out + avail[:take]
                self._rpos = self._rpos + take
                break
            if size is not none and size >= 0 and len(out) + len(avail) >= size:
                var take = size - len(out)
                out = out + avail[:take]
                self._rpos = self._rpos + take
                break
            out = out + avail
            self._rpos = len(self._rbuf)
            self._fill(1)
            if self._rpos >= len(self._rbuf):
                break
        self._offset_r = self._offset_r + len(out)
        return out

    def readlines(self, hint=-1):
        var lines = []
        var total = 0
        while true:
            var line = self.readline()
            if not line:
                break
            lines.append(line)
            total = total + len(line)
            if hint is not none and hint > 0 and total >= hint:
                break
        return lines

    def __iter__(self):
        return self

    def __next__(self):
        var line = self.readline()
        if not line:
            raise StopIteration
        return line

    @property
    def closed(self):
        return self.fileobj is none

    def close(self):
        var fileobj = self.fileobj
        if fileobj is none:
            return
        self.fileobj = none
        try:
            if self.mode == WRITE:
                fileobj.write(self.compress.flush())
                fileobj.write(_u32(self.crc))
                fileobj.write(_u32(self.size & 0xffffffff))
        finally:
            var myfileobj = self.myfileobj
            if myfileobj:
                self.myfileobj = none
                myfileobj.close()

    def flush(self, zlib_mode=zlib.Z_SYNC_FLUSH):
        self._check_not_closed()
        if self.mode == WRITE:
            self.fileobj.write(self.compress.flush(zlib_mode))
            self.fileobj.flush()

    def fileno(self):
        return self.fileobj.fileno()

    def rewind(self):
        if self.mode != READ:
            raise OSError("Can't rewind in write mode")
        self._reader.rewind()
        self._rbuf = b""
        self._rpos = 0
        self._offset_r = 0

    def readable(self):
        return self.mode == READ

    def writable(self):
        return self.mode == WRITE

    def seekable(self):
        return true

    def tell(self):
        self._check_not_closed()
        if self.mode == WRITE:
            return self.offset
        return self._offset_r

    def seek(self, offset, whence=io.SEEK_SET):
        if self.mode == WRITE:
            if whence != io.SEEK_SET:
                if whence == io.SEEK_CUR:
                    offset = self.offset + offset
                else:
                    raise ValueError("Seek from end not supported")
            if offset < self.offset:
                raise OSError("Negative seek in write mode")
            var count = offset - self.offset
            var chunk = b"\x00" * 1024
            for i in range(count // 1024):
                self.write(chunk)
            self.write(b"\x00" * (count % 1024))
            return self.offset
        self._check_not_closed()
        if whence == io.SEEK_CUR:
            offset = self._offset_r + offset
        elif whence == io.SEEK_END:
            while self.read(io.DEFAULT_BUFFER_SIZE):
                pass
            offset = self._offset_r + offset
        elif whence != io.SEEK_SET:
            raise ValueError("Invalid value for whence: " + str(whence))
        if offset < self._offset_r:
            self.rewind()
        var left = offset - self._offset_r
        while left > 0:
            var d = self.read(min(io.DEFAULT_BUFFER_SIZE, left))
            if not d:
                break
            left = left - len(d)
        return self._offset_r

    def __enter__(self):
        self._check_not_closed()
        return self

    def __exit__(self, *args):
        self.close()
        return false

    def __del__(self):
        # a GzipFile dropped while open is finished, as IOBase.__del__ does
        try:
            self.close()
        except Exception:
            pass


def _create_simple_gzip_header(compresslevel, mtime=none):
    if mtime is none:
        mtime = time.time()
    var xfl = 0
    if compresslevel == _COMPRESS_LEVEL_BEST:
        xfl = 2
    elif compresslevel == _COMPRESS_LEVEL_FAST:
        xfl = 4
    return b"\x1f\x8b\x08\x00" + _u32(int(mtime)) + bytes([xfl, 255])


def compress(data, compresslevel=_COMPRESS_LEVEL_BEST, mtime=none):
    var d = zlib._data(data)
    var header = _create_simple_gzip_header(compresslevel, mtime)
    var trailer = _u32(zlib.crc32(d)) + _u32(len(d) & 0xffffffff)
    return header + zlib.compress(d, compresslevel, -15) + trailer


def decompress(data):
    var members = []
    data = bytes(zlib._data(data))
    while true:
        var fp = io.BytesIO(data)
        if _read_gzip_header(fp) is none:
            return b"".join(members)
        var do = zlib.decompressobj(-zlib.MAX_WBITS)
        var decompressed = do.decompress(data[fp.tell():])
        if not do.eof or len(do.unused_data) < 8:
            raise EOFError("Compressed file ended before the end-of-stream marker was reached")
        var crc = _le(do.unused_data, 0, 4)
        var length = _le(do.unused_data, 4, 4)
        if crc != zlib.crc32(decompressed):
            raise BadGzipFile("CRC check failed")
        if length != (len(decompressed) & 0xffffffff):
            raise BadGzipFile("Incorrect length of data produced")
        members.append(decompressed)
        data = do.unused_data[8:].lstrip(b"\x00")
