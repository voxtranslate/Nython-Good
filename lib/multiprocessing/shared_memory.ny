# nython: module    (import it by name: it runs in a module scope of its own)
# lib/multiprocessing/shared_memory.ny - SharedMemory (round 80): a named
# block of memory any process can attach to by name.
#
#     from multiprocessing import shared_memory
#     shm = shared_memory.SharedMemory(create=True, size=1024)
#     shm.buf[:5] = b"hello"            # another process:
#     other = shared_memory.SharedMemory(shm.name)
#     bytes(other.buf[:5])              # b'hello'
#     other.close(); shm.close(); shm.unlink()
#
# SharedMemory(name=None, create=False, size=0): name, size, buf, close(),
# unlink(), the errors and messages of CPython (FileExistsError,
# FileNotFoundError, "'size' must be a positive number different from
# zero"); a generated name is "psm_" and 8 hex digits, as CPython's. The
# block is a file mapped shared (mmap / CreateFileMapping): in /dev/shm on
# Linux (where shm_open puts it too), else in the temporary directory.
# buf is a memoryview of the mapped block (round 84): writes through it are
# seen by every process attached; close() raises BufferError while a view
# made from buf (a slice, a cast) still exports it, as CPython's.
# ShareableList is not here.

import os
import tempfile

__all__ = ['SharedMemory']

_DIR = []


def _shm_dir():
    if not _DIR:
        var d = "/dev/shm"
        if os.name == "nt" or not (os.path.isdir(d) and os.access(d, os.W_OK)):
            d = tempfile.gettempdir()
        _DIR.append(d)
    return _DIR[0]


def _make_filename():
    return "psm_" + os.urandom(4).hex()


class SharedMemory:
    """Creates a new shared memory block or attaches to an existing shared memory block."""

    _name = None
    _h = None
    _buf = None

    def __init__(self, name=None, create=False, size=0):
        if not size >= 0:
            raise ValueError("'size' must be a positive integer")
        if create:
            if size == 0:
                raise ValueError("'size' must be a positive number different from zero")
        if name is None and not create:
            raise ValueError("'name' can only be None if create=True")
        if create and name is None:
            while True:
                name = _make_filename()
                if not os.path.exists(os.path.join(_shm_dir(), name)):
                    break
        var stripped = name.lstrip("/")
        var path = os.path.join(_shm_dir(), stripped)
        self._path = path
        self._name = stripped
        if create:
            self._h = _ny_os_call("shm_open", path, size, True)
        else:
            self._h = _ny_os_call("shm_open", path, 0, False)
        self._size = _ny_os_call("shm_size", self._h)
        self._exports = 1
        var me = self
        def gone():
            me._exports -= 1
        self._buf = _ny_memview_raw(self, _ny_os_call("shm_addr", self._h), self._size, False, release=gone)

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def __reduce__(self):
        return (self.__class__, (self.name, False, self.size))

    def __repr__(self):
        return f'{self.__class__.__name__}({self.name!r}, size={self.size})'

    @property
    def buf(self):
        "A memoryview of contents of the shared memory block."
        return self._buf

    @property
    def name(self):
        "Unique name that identifies the shared memory block."
        return self._name

    @property
    def size(self):
        "Size in bytes."
        return self._size

    def close(self):
        """Closes access to the shared memory from this instance but does
        not destroy the shared memory block."""
        if self._buf is not None:
            self._buf.release()
            self._buf = None
        if self._h is not None and getattr(self, "_exports", 0) > 0:
            raise BufferError("cannot close exported pointers exist")
        if self._h is not None:
            _ny_os_call("shm_close", self._h)
            self._h = None

    def unlink(self):
        """Requests that the underlying shared memory block be destroyed."""
        try:
            os.unlink(self._path)
        except OSError:
            pass
