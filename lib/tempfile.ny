# nython: module    (import it by name: it runs in a module scope of its own)
# lib/tempfile.ny - Python's tempfile: temporary files and directories.
#
#     gettempdir(), gettempprefix(), gettempdirb(), gettempprefixb(),
#     tempdir, template, TMP_MAX
#     mkstemp(suffix=None, prefix=None, dir=None, text=False) -> (fd, path)
#     mkdtemp(suffix=None, prefix=None, dir=None) -> path
#     mktemp(suffix="", prefix="tmp", dir=None)    (deprecated, unsafe)
#     TemporaryDirectory(suffix, prefix, dir, ignore_cleanup_errors, delete)
#     NamedTemporaryFile(mode="w+b", buffering, encoding, newline, suffix,
#                        prefix, dir, delete=True, errors, delete_on_close)
#     TemporaryFile(...)            SpooledTemporaryFile(max_size, mode, ...)
#
# The directory search is CPython's: TMPDIR, TEMP, TMP, then the platform's
# usual places, then the current directory - the first where a file can
# actually be created - made absolute and cached in tempfile.tempdir.
# Files are created exclusively and with mode 0600 (the native os_mkstemp:
# mkstemps on POSIX, O_EXCL on Windows), directories with mode 0700.
#
# Differences from CPython (Nython has no OS-level file descriptors):
#   - mkstemp() returns (handle, path) where handle is a Nython file handle
#     - the integer file_read/file_write/file_close and open()'s file
#     objects work on - open on the new file for reading and writing;
#     close it with file_close(handle). os.close/os.fdopen do not exist.
#   - The random part of a mkstemp() name is 6 characters (mkstemps'
#     template) on POSIX, 8 hex digits on Windows; CPython's is 8 of
#     [a-z0-9_]. mkdtemp() names use CPython's 8 characters.
#   - TemporaryFile() is unlinked right after it is opened on POSIX, as
#     CPython does (its .name is the vanished path, not an fd number); on
#     Windows it is a NamedTemporaryFile, as in CPython.
#   - SpooledTemporaryFile keeps its data in memory (a small buffer class
#     here, since there is no io.BytesIO) until max_size is exceeded or
#     fileno() is called, then rolls over to a TemporaryFile.
#   - Objects left to the garbage collector clean up in __del__ without a
#     ResourceWarning (there is no warnings module).

import os
import shutil as _shutil_mod

__all__ = ["NamedTemporaryFile", "TemporaryFile", "SpooledTemporaryFile",
           "TemporaryDirectory", "mkstemp", "mkdtemp", "mktemp", "TMP_MAX",
           "gettempprefix", "tempdir", "gettempdir", "gettempprefixb",
           "gettempdirb"]

_WINDOWS = os_platform() == "windows"
TMP_MAX = 10000
template = "tmp"
tempdir = none

_NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"


def _random_name():
    var raw = os_urandom(8)
    var out = []
    for b in raw:
        out.append(_NAME_CHARS[b % 37])
    return "".join(out)


# Python's name for a value's type (Nython calls dict "map", str "string").
_PY_TYPE_NAMES = {"map": "dict", "string": "str", "none": "NoneType", "builtin": "builtin_function_or_method"}


def _tname(x):
    var n = x.__class__.__name__ if hasattr(x, "__class__") else type(x).__name__
    return _PY_TYPE_NAMES.get(n, n)


def _fspath(p):
    if isinstance(p, str) or isinstance(p, bytes):
        return p
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    raise TypeError("expected str, bytes or os.PathLike object, not " + type(p).__name__)


def _candidate_tempdir_list():
    var dirlist = []
    for envname in ["TMPDIR", "TEMP", "TMP"]:
        var dirname = os_getenv(envname)
        if dirname:
            dirlist.append(dirname)
    if _WINDOWS:
        dirlist.extend([os_path_expanduser("~\\AppData\\Local\\Temp"),
                        os_path_expandvars("%SYSTEMROOT%\\Temp"),
                        "c:\\temp", "c:\\tmp", "\\temp", "\\tmp"])
    else:
        dirlist.extend(["/tmp", "/var/tmp", "/usr/tmp"])
    try:
        dirlist.append(os_getcwd())
    except Exception:
        dirlist.append(".")
    return dirlist


def _get_default_tempdir():
    var dirlist = _candidate_tempdir_list()
    for dir in dirlist:
        if dir != ".":
            dir = os_path_abspath(dir)
        if not os_isdir(dir):
            continue
        var seq = 0
        while seq < 100:
            seq = seq + 1
            var filename = os_path_join(dir, _random_name())
            if os_exists(filename):
                continue
            try:
                var f = open(filename, "xb")
                f.write(b"blat")
                f.close()
                os_unlink(filename)
                return dir
            except FileExistsError:
                pass
            except OSError:
                break
    raise FileNotFoundError("[Errno 2] No usable temporary directory found in " + repr(dirlist))


def gettempprefix():
    """The default prefix for temporary directories as string."""
    return template


def gettempprefixb():
    """The default prefix for temporary directories as bytes."""
    return template.encode("utf-8")


def gettempdir():
    """Returns tempfile.tempdir as str."""
    global tempdir
    if tempdir is none:
        tempdir = _get_default_tempdir()
    return tempdir


def gettempdirb():
    """Returns tempfile.tempdir as bytes."""
    return gettempdir().encode("utf-8")


def _sanitize_params(prefix, suffix, dir):
    var kinds = []
    for x in [prefix, suffix, dir]:
        if x is not none and not isinstance(x, str):
            if hasattr(x, "__fspath__"):
                x = x.__fspath__()
            if isinstance(x, bytes):
                kinds.append("bytes")
            elif isinstance(x, str):
                kinds.append("str")
        elif x is not none:
            kinds.append("str")
    if "bytes" in kinds and "str" in kinds:
        raise TypeError("Can't mix bytes and non-bytes in path components.")
    if "bytes" in kinds:
        raise TypeError("bytes paths are not supported by Nython's tempfile")
    if suffix is none:
        suffix = ""
    if prefix is none:
        prefix = template
    if dir is none:
        dir = gettempdir()
    else:
        dir = _fspath(dir)
    return [prefix, suffix, dir]


def mkstemp(suffix=none, prefix=none, dir=none, text=false):
    """User-callable function to create and return a unique temporary
    file. The return value is a pair (fd, name) where fd is a Nython file
    handle open for reading and writing (close it with file_close(fd)) and
    name is the absolute path of the file.

    The file is readable and writable only by the creating user ID.
    """
    var ps = _sanitize_params(prefix, suffix, dir)
    var path = os_mkstemp(ps[0], ps[1], ps[2])
    var fd = file_open_or_raise(path, "r+" if text else "r+b")
    return (fd, os_path_abspath(path))


def mkdtemp(suffix=none, prefix=none, dir=none):
    """User-callable function to create and return a unique temporary
    directory. The return value is the absolute pathname of the directory.

    The directory is readable, writable, and searchable only by the
    creating user.
    """
    var ps = _sanitize_params(prefix, suffix, dir)
    var seq = 0
    while seq < TMP_MAX:
        seq = seq + 1
        var file = os_path_join(ps[2], ps[0] + _random_name() + ps[1])
        if mkdir(file):
            if not _WINDOWS:
                os_chmod(file, 0o700)
            return os_path_abspath(file)
        if os_exists(file):
            continue
        # Not a name clash: report why the directory cannot be made.
        if not os_isdir(ps[2]):
            if os_exists(ps[2]):
                raise NotADirectoryError("[Errno 20] Not a directory: " + repr(file))
            raise FileNotFoundError("[Errno 2] No such file or directory: " + repr(file))
        raise PermissionError("[Errno 13] Permission denied: " + repr(file))
    raise FileExistsError("[Errno 17] No usable temporary directory name found")


def mktemp(suffix="", prefix=template, dir=none):
    """User-callable function to return a unique temporary file name. The
    file is not created.

    THIS FUNCTION IS UNSAFE AND SHOULD NOT BE USED.
    """
    if dir is none:
        dir = gettempdir()
    var seq = 0
    while seq < TMP_MAX:
        seq = seq + 1
        var file = os_path_join(dir, prefix + _random_name() + suffix)
        if not os_exists(file):
            return file
    raise FileExistsError("[Errno 17] No usable temporary filename found")


class _TemporaryFileWrapper:
    """Temporary file wrapper

    This class provides a wrapper around files opened for
    temporary use.  In particular, it seeks to automatically
    remove the file when it is no longer needed.
    """
    def __init__(self, file, name, delete=true, delete_on_close=true):
        object.__setattr__(self, "file", file)
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "delete", delete)
        object.__setattr__(self, "_delete_on_close", delete_on_close)
        object.__setattr__(self, "_removed", false)

    def __getattr__(self, name):
        # Attribute lookups are delegated to the underlying file
        return getattr(self.file, name)

    def _remove(self):
        if not self._removed:
            object.__setattr__(self, "_removed", true)
            try:
                os_unlink(self.name)
            except FileNotFoundError:
                pass

    def __enter__(self):
        self.file.__enter__()
        return self

    def __exit__(self, exc, value, tb):
        self.file.__exit__(exc, value, tb)
        if self.delete:
            self._remove()
        return false

    def close(self):
        """Close the temporary file, possibly deleting it."""
        self.file.close()
        if self.delete and self._delete_on_close:
            self._remove()

    @property
    def closed(self):
        return self.file.closed

    def __iter__(self):
        return self

    def __next__(self):
        return self.file.__next__()

    def read(self, *args):
        return self.file.read(*args)

    def readline(self, *args):
        return self.file.readline(*args)

    def readlines(self, *args):
        return self.file.readlines(*args)

    def write(self, data):
        return self.file.write(data)

    def writelines(self, lines):
        return self.file.writelines(lines)

    def seek(self, *args):
        return self.file.seek(*args)

    def tell(self):
        return self.file.tell()

    def flush(self):
        return self.file.flush()

    def truncate(self, *args):
        return self.file.truncate(*args)

    def fileno(self):
        return self.file.fileno()

    def __del__(self):
        try:
            if not self.file.closed:
                self.file.close()
            if self.delete:
                self._remove()
        except Exception:
            pass

    def __repr__(self):
        return "<tempfile._TemporaryFileWrapper file=" + repr(self.file) + ">"


def _open_mode_ok(mode):
    for ch in mode:
        if ch not in "rwxab+t":
            raise ValueError("invalid mode: '" + mode + "'")


def NamedTemporaryFile(mode="w+b", buffering=-1, encoding=none,
                       newline=none, suffix=none, prefix=none,
                       dir=none, delete=true, errors=none,
                       delete_on_close=true):
    """Create and return a temporary file.
    Arguments:
    'prefix', 'suffix', 'dir' -- as for mkstemp.
    'mode' -- the mode argument to io.open (default "w+b").
    'buffering', 'encoding', 'newline', 'errors' -- as for open().
    'delete' -- whether the file is automatically deleted (default True).
    'delete_on_close' -- if 'delete', whether the file is deleted on close
       (default True) or otherwise either on context manager exit
       (if context manager was used) or on object finalization.
    The file is created as mkstemp() would do it.

    Returns an object with a file-like interface; the name of the file
    is accessible as its 'name' attribute.
    """
    _open_mode_ok(mode)
    var ps = _sanitize_params(prefix, suffix, dir)
    var path = os_path_abspath(os_mkstemp(ps[0], ps[1], ps[2]))
    var m = mode
    if "w" in m:
        # the file exists already (created exclusively): open it without
        # losing that, as os.open(O_CREAT|O_EXCL) + fdopen does
        m = m.replace("w", "r")
        if "+" not in m:
            m = m + "+"
    var f = none
    try:
        f = open(path, m, encoding if encoding is not none else "utf-8")
    except Exception as e:
        try:
            os_unlink(path)
        except Exception:
            pass
        raise e
    f.mode = mode
    return _TemporaryFileWrapper(f, path, delete, delete_on_close)


def TemporaryFile(mode="w+b", buffering=-1, encoding=none,
                  newline=none, suffix=none, prefix=none,
                  dir=none, errors=none):
    """Create and return a temporary file.
    Arguments:
    'prefix', 'suffix', 'dir' -- as for mkstemp.
    'mode' -- the mode argument to io.open (default "w+b").
    'buffering', 'encoding', 'newline', 'errors' -- as for open().
    The file is created as mkstemp() would do it.

    Returns an object with a file-like interface.  The file has no
    name (POSIX: it is removed at once), and will cease to exist when
    it is closed.
    """
    if _WINDOWS:
        return NamedTemporaryFile(mode, buffering, encoding, newline, suffix, prefix, dir, true, errors)
    _open_mode_ok(mode)
    var ps = _sanitize_params(prefix, suffix, dir)
    var path = os_path_abspath(os_mkstemp(ps[0], ps[1], ps[2]))
    var m = mode
    if "w" in m:
        m = m.replace("w", "r")
        if "+" not in m:
            m = m + "+"
    var f = none
    try:
        f = open(path, m, encoding if encoding is not none else "utf-8")
    finally:
        os_unlink(path)
    f.mode = mode
    return f


class _SpooledBuffer:
    # An in-memory file: str or bytes, with a position.
    def __init__(self, binary):
        self.binary = binary
        self._data = b"" if binary else ""
        self._pos = 0
        self.closed = false

    def _check(self):
        if self.closed:
            raise ValueError("I/O operation on closed file.")

    def write(self, s):
        self._check()
        if self.binary:
            if not (isinstance(s, bytes) or isinstance(s, bytearray)):
                raise TypeError("a bytes-like object is required, not '" + _tname(s) + "'")
            s = bytes(s)
        elif not isinstance(s, str):
            raise TypeError("string argument expected, got '" + _tname(s) + "'")
        var n = len(self._data)
        if self._pos > n:
            self._data = self._data + ((b"\0" if self.binary else "\0") * (self._pos - n))
        self._data = self._data[:self._pos] + s + self._data[self._pos + len(s):]
        self._pos = self._pos + len(s)
        return len(s)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def read(self, size=-1):
        self._check()
        if size is none or size < 0:
            var r = self._data[self._pos:]
            self._pos = len(self._data)
            return r
        var r2 = self._data[self._pos:self._pos + size]
        self._pos = self._pos + len(r2)
        return r2

    def readline(self, size=-1):
        self._check()
        var nl = b"\n" if self.binary else "\n"
        var i = self._data.find(nl, self._pos)
        var end = len(self._data) if i < 0 else i + 1
        if size is not none and size >= 0 and self._pos + size < end:
            end = self._pos + size
        var r = self._data[self._pos:end]
        self._pos = end
        return r

    def readlines(self, hint=-1):
        var out = []
        var line = self.readline()
        while line:
            out.append(line)
            line = self.readline()
        return out

    def seek(self, pos, whence=0):
        self._check()
        if whence == 0:
            self._pos = pos
        elif whence == 1:
            self._pos = self._pos + pos
        else:
            self._pos = len(self._data) + pos
        if self._pos < 0:
            raise ValueError("negative seek value " + str(self._pos))
        return self._pos

    def tell(self):
        self._check()
        return self._pos

    def truncate(self, size=none):
        self._check()
        if size is none:
            size = self._pos
        self._data = self._data[:size]
        return size

    def getvalue(self):
        return self._data

    def flush(self):
        pass

    def close(self):
        self.closed = true

    def __iter__(self):
        return self

    def __next__(self):
        var line = self.readline()
        if not line:
            raise StopIteration()
        return line


class SpooledTemporaryFile:
    """Temporary file wrapper, specialized to switch from an in-memory
    buffer to a real file when it exceeds a certain size or when a
    fileno is needed.
    """
    def __init__(self, max_size=0, mode="w+b", buffering=-1,
                 encoding=none, newline=none, suffix=none, prefix=none,
                 dir=none, errors=none):
        self._file = _SpooledBuffer("b" in mode)
        self._max_size = max_size
        self._rolled = false
        self._TemporaryFileArgs = [mode, buffering, encoding, newline, suffix, prefix, dir, errors]

    def _check(self, file):
        if self._rolled:
            return
        var max_size = self._max_size
        if max_size and file.tell() > max_size:
            self.rollover()

    def rollover(self):
        if self._rolled:
            return
        var file = self._file
        var a = self._TemporaryFileArgs
        var newfile = TemporaryFile(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        newfile.write(file.getvalue())
        newfile.seek(file.tell(), 0)
        self._file = newfile
        self._rolled = true

    def __enter__(self):
        if self._file.closed:
            raise ValueError("Cannot enter context with closed file")
        return self

    def __exit__(self, exc, value, tb):
        self._file.close()
        return false

    def __iter__(self):
        return self._file.__iter__()

    def __next__(self):
        return self._file.__next__()

    def close(self):
        self._file.close()

    @property
    def closed(self):
        return self._file.closed

    @property
    def encoding(self):
        if self._rolled:
            return self._file.encoding
        return none if "b" in self._TemporaryFileArgs[0] else (self._TemporaryFileArgs[2] or "utf-8")

    @property
    def mode(self):
        return self._TemporaryFileArgs[0]

    @property
    def name(self):
        if self._rolled:
            return self._file.name
        return none

    def fileno(self):
        self.rollover()
        return self._file.fileno()

    def flush(self):
        self._file.flush()

    def isatty(self):
        return false

    def read(self, *args):
        return self._file.read(*args)

    def readline(self, *args):
        return self._file.readline(*args)

    def readlines(self, *args):
        return self._file.readlines(*args)

    def seek(self, *args):
        return self._file.seek(*args)

    def tell(self):
        return self._file.tell()

    def truncate(self, size=none):
        if size is none:
            return self._file.truncate()
        if self._max_size and size > self._max_size:
            self.rollover()
        return self._file.truncate(size)

    def write(self, s):
        var file = self._file
        var rv = file.write(s)
        self._check(file)
        return rv

    def writelines(self, iterable):
        var file = self._file
        var rv = file.writelines(iterable)
        self._check(file)
        return rv

    def readable(self):
        return true

    def seekable(self):
        return true

    def writable(self):
        return true


class TemporaryDirectory:
    """Create and return a temporary directory.  This has the same
    behavior as mkdtemp but can be used as a context manager.  For
    example:

        with TemporaryDirectory() as tmpdir:
            ...

    Upon exiting the context, the directory and everything contained
    in it are removed (unless delete=False is passed).
    """
    def __init__(self, suffix=none, prefix=none, dir=none,
                 ignore_cleanup_errors=false, delete=true):
        self.name = mkdtemp(suffix, prefix, dir)
        self._ignore_cleanup_errors = ignore_cleanup_errors
        self._delete = delete
        self._done = false

    def _rmtree(self):
        if self._ignore_cleanup_errors:
            _shutil_mod.rmtree(self.name, true)
            return
        def _onexc(func, path, exc):
            if isinstance(exc, PermissionError):
                # make it writable and try again, as CPython does
                try:
                    os_chmod(path, 0o700)
                    func(path)
                    return
                except Exception:
                    pass
            if isinstance(exc, FileNotFoundError):
                return
            raise exc
        _shutil_mod.rmtree(self.name, false, none, _onexc)

    def __repr__(self):
        return "<TemporaryDirectory " + repr(self.name) + ">"

    def __enter__(self):
        return self.name

    def __exit__(self, exc, value, tb):
        if self._delete:
            self.cleanup()
        return false

    def cleanup(self):
        if not self._done:
            self._done = true
            if os_exists(self.name) or os_islink(self.name):
                self._rmtree()

    def __del__(self):
        try:
            if self._delete and not self._done:
                self.cleanup()
        except Exception:
            pass
