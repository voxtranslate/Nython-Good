# nython: module    (import it by name: it runs in a module scope of its own)
# lib/mmap.ny - Python's mmap module (round 83): memory-mapped files.
#
#     import mmap
#     with open("data.bin", "r+b") as f:
#         mm = mmap.mmap(f.fileno(), 0)          # the whole file, read/write, shared
#         mm[0:5] = b"HELLO"; mm.find(b"x"); mm.readline(); mm.seek(0)
#         mm.flush(); mm.close()
#     anon = mmap.mmap(-1, 4096)                  # anonymous memory
#
# mmap(fileno, length, flags=MAP_SHARED, prot=PROT_WRITE|PROT_READ,
#      access=ACCESS_DEFAULT, offset=0)          (POSIX)
# mmap(fileno, length, tagname=None, access=ACCESS_DEFAULT, offset=0)
#                                                (Windows: CreateFileMapping /
#                                                 MapViewOfFile; tagname names it)
# close, closed, find(sub, start=pos, end=len) / rfind, flush(offset, size),
# madvise(option, start, length), move(dest, src, count), read(n),
# read_byte, readline, resize(newsize) (mremap on Linux), seek(pos, whence),
# size() (the file's size), tell, write(data) -> count, write_byte(int),
# len(), m[i] (an int), m[a:b:c] (bytes), m[i] = int, m[a:b] = bytes,
# iteration (1-byte bytes, as CPython's sequence protocol gives), with,
# the buffer protocol (round 84: __buffer__, PEP 688 - memoryview(m) is a
# view of the mapped memory itself, readonly for ACCESS_READ; bytes(m),
# bytearray(m), f.readinto(m), m.write(memoryview) ... through it; close()
# and resize() raise BufferError while a view is exported), and the
# constants: ACCESS_DEFAULT/READ/WRITE/COPY, PAGESIZE, ALLOCATIONGRANULARITY,
# MAP_SHARED/PRIVATE/ANONYMOUS/..., PROT_READ/WRITE/EXEC, MADV_* (the
# platform's own, natively); error (OSError). CPython's argument checks and
# messages ("mmap closed or invalid", "mmap can't modify a readonly memory
# map.", "data out of range", "mmap index out of range", ...).
#
# Not here: trackfd (3.13).
import sys as _sys

error = OSError
ACCESS_DEFAULT = 0
ACCESS_READ = 1
ACCESS_WRITE = 2
ACCESS_COPY = 3

_posix = _sys_platform_posix()


def _load():
    var g = globals()
    for pair in _mmap_consts():
        g[pair[0]] = pair[1]


_load()
del _load

if _posix:
    _DEFAULT_FLAGS = MAP_SHARED
    _DEFAULT_PROT = PROT_WRITE | PROT_READ
else:
    _DEFAULT_FLAGS = 0
    _DEFAULT_PROT = 0


def _index(v, what="an integer"):
    if isinstance(v, bool) or not isinstance(v, int):
        var ix = getattr(type(v), "__index__", None)
        if ix is None:
            raise TypeError("'" + type(v).__name__ + "' object cannot be interpreted as an integer")
        return ix(v)
    return v


def _buffer(data):
    # any bytes-like object (round 84: memoryview, array, another mmap ...)
    return _ny_bytes_like(data)


class mmap:
    """Windows: mmap(fileno, length[, tagname[, access[, offset]]])

    Maps length bytes from the file specified by the file handle fileno,
    and returns a mmap object.

    Unix: mmap(fileno, length[, flags[, prot[, access[, offset[, trackfd]]]]])

    Maps length bytes from the file specified by the file descriptor fileno,
    and returns a mmap object."""

    if _posix:
        def __init__(self, fileno, length, flags=_DEFAULT_FLAGS, prot=_DEFAULT_PROT, access=ACCESS_DEFAULT,
                     offset=0, *, trackfd=True):
            self._h = None
            fileno = _index(fileno)
            length = _index(length)
            offset = _index(offset)
            if length < 0:
                raise OverflowError("memory mapped length must be positive")
            if offset < 0:
                raise OverflowError("memory mapped offset must be positive")
            if access != ACCESS_DEFAULT and (flags != MAP_SHARED or prot != (PROT_WRITE | PROT_READ)):
                raise ValueError("mmap can't specify both access and flags, prot.")
            if access == ACCESS_READ:
                flags = MAP_SHARED
                prot = PROT_READ
            elif access == ACCESS_WRITE:
                flags = MAP_SHARED
                prot = PROT_READ | PROT_WRITE
            elif access == ACCESS_COPY:
                flags = MAP_PRIVATE
                prot = PROT_READ | PROT_WRITE
            elif access == ACCESS_DEFAULT:
                if (prot & PROT_READ) and (prot & PROT_WRITE):
                    pass
                elif prot & PROT_WRITE:
                    access = ACCESS_WRITE
                else:
                    access = ACCESS_READ
            else:
                raise ValueError("mmap invalid access parameter.")
            if fileno == -1 and length == 0:
                raise OSError(22, "Invalid argument")
            var r = _mmap_new(fileno, length, flags, prot, access, offset, None)
            self._h = r[0]
            self._size = r[1]
            self._access = access
            self._offset = offset
            self._pos = 0
            self._closed = False
            self._fileno = fileno
            self._exports = 0
    else:
        def __init__(self, fileno, length, tagname=None, access=ACCESS_DEFAULT, offset=0):
            self._h = None
            fileno = _index(fileno)
            length = _index(length)
            offset = _index(offset)
            if length < 0:
                raise OverflowError("memory mapped length must be positive")
            if offset < 0:
                raise OverflowError("memory mapped offset must be positive")
            if access not in (ACCESS_DEFAULT, ACCESS_READ, ACCESS_WRITE, ACCESS_COPY):
                raise ValueError("mmap invalid access parameter.")
            var r = _mmap_new(fileno, length, 0, 0, access, offset, tagname)
            self._h = r[0]
            self._size = r[1]
            self._access = access
            self._offset = offset
            self._pos = 0
            self._closed = False
            self._fileno = fileno
            self._exports = 0

    # ── state ────────────────────────────────────────────────────────────
    def _check(self):
        if self._closed or self._h is None:
            raise ValueError("mmap closed or invalid")

    def _check_writable(self):
        if self._access == ACCESS_READ:
            raise TypeError("mmap can't modify a readonly memory map.")

    @property
    def closed(self):
        return self._closed

    def close(self):
        if getattr(self, "_exports", 0) > 0:
            raise BufferError("cannot close exported pointers exist")
        if not self._closed and self._h is not None:
            _mmap_close(self._h)
        self._closed = True

    # ── the buffer protocol (PEP 688; round 84) ──────────────────────────
    def __buffer__(self, flags):
        self._check()
        var ro = self._access == ACCESS_READ
        if (flags & 1) and ro:
            raise BufferError("Object is not writable.")
        self._exports += 1
        var me = self
        def gone():
            me._exports -= 1
        return _ny_memview_raw(self, _mmap_addr(self._h), self._size, ro, release=gone)

    def __release_buffer__(self, view):
        view.release()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *args):
        self.close()

    def __len__(self):
        self._check()
        return self._size

    def size(self):
        self._check()
        return _mmap_filesize(self._h)

    def tell(self):
        self._check()
        return self._pos

    def seek(self, pos, whence=0):
        self._check()
        pos = _index(pos)
        var where = 0
        if whence == 0:
            where = pos
        elif whence == 1:
            where = self._pos + pos
        elif whence == 2:
            where = self._size + pos
        else:
            raise ValueError("unknown seek type")
        if where > self._size or where < 0:
            raise ValueError("seek out of range")
        self._pos = where

    def seekable(self):
        return True

    # ── reading ──────────────────────────────────────────────────────────
    def read(self, n=None, /):
        self._check()
        var remaining = self._size - self._pos if self._pos < self._size else 0
        if n is None:
            n = remaining
        else:
            n = _index(n)
            if n < 0 or n > remaining:
                n = remaining
        var start = self._pos
        self._pos = start + n
        return _mmap_read(self._h, start, start + n, 1)

    def read_byte(self):
        self._check()
        if self._pos >= self._size:
            raise ValueError("read byte out of range")
        var b = _mmap_byte(self._h, self._pos)
        self._pos += 1
        return b

    def readline(self):
        self._check()
        var remaining = self._size - self._pos if self._pos < self._size else 0
        if remaining == 0:
            return b""
        var end = _mmap_line_end(self._h, self._pos)
        var start = self._pos
        self._pos = end
        return _mmap_read(self._h, start, end, 1)

    def _range(self, start, end):
        if start is None:
            start = self._pos
        if end is None:
            end = self._size
        start = _index(start)
        end = _index(end)
        if start < 0:
            start += self._size
        if start < 0:
            start = 0
        elif start > self._size:
            start = self._size
        if end < 0:
            end += self._size
        if end < 0:
            end = 0
        elif end > self._size:
            end = self._size
        return start, end

    def find(self, sub, start=None, end=None, /):
        self._check()
        var r = self._range(start, end)
        return _mmap_find(self._h, _buffer(sub), r[0], r[1], False)

    def rfind(self, sub, start=None, end=None, /):
        self._check()
        var r = self._range(start, end)
        return _mmap_find(self._h, _buffer(sub), r[0], r[1], True)

    # ── writing ──────────────────────────────────────────────────────────
    def write(self, data, /):
        self._check()
        self._check_writable()
        data = _buffer(data)
        if self._pos > self._size or self._size - self._pos < len(data):
            raise ValueError("data out of range")
        _mmap_write(self._h, self._pos, data, 1)
        self._pos += len(data)
        return len(data)

    def write_byte(self, byte, /):
        self._check()
        self._check_writable()
        byte = _index(byte)
        if byte < 0 or byte > 255:
            raise ValueError("byte must be in range(0, 256)")
        if self._pos >= self._size:
            raise ValueError("write byte out of range")
        _mmap_setbyte(self._h, self._pos, byte)
        self._pos += 1

    def flush(self, offset=0, size=None, /):
        self._check()
        if size is None:
            size = self._size
        offset = _index(offset)
        size = _index(size)
        if size < 0 or offset < 0 or self._size - offset < size:
            raise ValueError("flush values out of range")
        if self._access == ACCESS_READ or self._access == ACCESS_COPY:
            return None
        _mmap_flush(self._h, offset, size)
        return None

    if _posix:
        def madvise(self, option, start=0, length=None, /):
            self._check()
            start = _index(start)
            if start < 0 or start >= self._size:
                raise ValueError("madvise start out of bounds")
            if length is None:
                length = self._size
            length = _index(length)
            if length < 0:
                raise ValueError("madvise length invalid")
            if start + length > self._size:
                length = self._size - start
            _mmap_madvise(self._h, option, start, length)

    def move(self, dest, src, count, /):
        self._check()
        self._check_writable()
        dest = _index(dest)
        src = _index(src)
        count = _index(count)
        if dest < 0 or src < 0 or count < 0 or self._size - dest < count or self._size - src < count:
            raise ValueError("source, destination, or count out of range")
        _mmap_move(self._h, dest, src, count)

    def resize(self, newsize, /):
        self._check()
        if self._exports > 0:
            raise BufferError("mmap can't resize with extant buffers exported.")
        if self._access != ACCESS_WRITE and self._access != ACCESS_DEFAULT:
            raise TypeError("mmap can't resize a readonly or copy-on-write memory map.")
        newsize = _index(newsize)
        if newsize < 0:
            raise ValueError("new size out of range")
        _mmap_resize(self._h, newsize)
        self._size = newsize

    # ── the sequence protocol ────────────────────────────────────────────
    def __getitem__(self, key):
        self._check()
        if isinstance(key, slice):
            var r = key.indices(self._size)
            var start = r[0]
            var stop = r[1]
            var step = r[2]
            if step == 1:
                if stop < start:
                    stop = start
                return _mmap_read(self._h, start, stop, 1)
            return _mmap_read(self._h, start, stop, step)
        if not isinstance(key, int) and getattr(type(key), "__index__", None) is None:
            raise TypeError("mmap indices must be integers")
        var i = _index(key)
        if i < 0:
            i += self._size
        if i < 0 or i >= self._size:
            raise IndexError("mmap index out of range")
        return _mmap_byte(self._h, i)

    def __setitem__(self, key, value):
        self._check()
        self._check_writable()
        if isinstance(key, slice):
            var r = key.indices(self._size)
            var start = r[0]
            var stop = r[1]
            var step = r[2]
            var data = None
            try:
                data = _buffer(value)
            except TypeError:
                raise TypeError("mmap slice assignment must be bytes") from None
            var n = len(range(start, stop, step))
            if len(data) != n:
                raise IndexError("mmap slice assignment is wrong size")
            if n:
                _mmap_write(self._h, start, data, step)
            return
        if not isinstance(key, int) and getattr(type(key), "__index__", None) is None:
            raise TypeError("mmap indices must be integer")
        var i = _index(key)
        if i < 0:
            i += self._size
        if i < 0 or i >= self._size:
            raise IndexError("mmap index out of range")
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError("mmap item value must be an int")
        if value < 0 or value > 255:
            raise ValueError("mmap item value must be in range(0, 256)")
        _mmap_setbyte(self._h, i, value)

    def __delitem__(self, key):
        raise TypeError("mmap object doesn't support item deletion")

    def __iter__(self):
        self._check()
        var i = 0
        while i < self._size:
            yield bytes([_mmap_byte(self._h, i)])
            i += 1

    def __contains__(self, item):
        self._check()
        if isinstance(item, (bytes, bytearray)) and len(item) == 1:
            return _mmap_find(self._h, bytes(item), 0, self._size, False) >= 0
        for b in self:
            if b == item:
                return True
        return False

    def __reduce__(self):
        raise TypeError("cannot pickle 'mmap.mmap' object")


mmap.__module__ = "mmap"
