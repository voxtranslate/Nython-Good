# nython: module    (import it by name: it runs in a module scope of its own)
# lib/shutil.ny - Python's shutil: high-level file operations.
#
#     copyfileobj, copyfile, copymode, copystat, copy, copy2, ignore_patterns,
#     copytree (symlinks, ignore, copy_function, ignore_dangling_symlinks,
#     dirs_exist_ok), rmtree (ignore_errors, onerror, onexc), move, which,
#     disk_usage, chown (POSIX names only: raises), get_terminal_size,
#     make_archive / unpack_archive / get_archive_formats / get_unpack_formats
#     / register_archive_format / register_unpack_format (format "tar"),
#     Error, SameFileError, SpecialFileError, ExecError, ReadError,
#     RegistryError
#
# Built on the native OS layer (src/builtins/os.cpp): os_stat, os_listdir,
# os_utime, os_chmod, os_symlink, ... Paths may be str or path-like
# (pathlib.Path). CPython's algorithms are followed step by step (copytree
# collects errors into one Error, rmtree reports through onexc(func, path,
# exc) - func is the os function that failed, so a handler can retry it -
# move falls back to copy + delete across file systems, which() honours
# PATHEXT on Windows).
#
# Differences from CPython:
#   - copystat keeps times to the microsecond (os_stat gives float seconds),
#     not the nanosecond; extended attributes and file flags are not copied.
#   - Archives: no compression library is available to Nython, so only the
#     uncompressed "tar" format exists (ustar, read and written here);
#     "zip", "gztar", "bztar" and "xztar" are unknown formats (ValueError /
#     ReadError, as CPython reports a format it does not have).
#   - OSErrors raised here carry errno/strerror/filename; the ones the
#     native layer raises have CPython's message text.

import os
import fnmatch as _fnmatch_mod

__all__ = ["copyfileobj", "copyfile", "copymode", "copystat", "copy", "copy2",
           "copytree", "move", "rmtree", "Error", "SpecialFileError",
           "ExecError", "make_archive", "get_archive_formats",
           "register_archive_format", "unregister_archive_format",
           "get_unpack_formats", "register_unpack_format",
           "unregister_unpack_format", "unpack_archive",
           "ignore_patterns", "chown", "which", "get_terminal_size",
           "SameFileError", "disk_usage"]

_WINDOWS = os_platform() == "windows"
COPY_BUFSIZE = 1024 * 1024 if _WINDOWS else 64 * 1024


class Error(OSError):
    pass

class SameFileError(Error):
    """Raised when source and destination are the same file."""
    pass

class SpecialFileError(OSError):
    """Raised when trying to do a kind of operation (e.g. copying) which is
    not supported on a special file (e.g. a named pipe)"""
    pass

class ExecError(OSError):
    """Raised when a command could not be executed"""
    pass

class ReadError(OSError):
    """Raised when an archive cannot be read"""
    pass

class RegistryError(Exception):
    """Raised when a registry operation with the archiving
    and unpacking registries fails"""
    pass


class usage:
    # disk_usage()'s named tuple (total, used, free), named as CPython's
    def __init__(self, total, used, free):
        self.total = total
        self.used = used
        self.free = free

    def _t(self):
        return (self.total, self.used, self.free)

    def __getitem__(self, i):
        return self._t()[i]

    def __len__(self):
        return 3

    def __iter__(self):
        return iter(self._t())

    def __eq__(self, other):
        if isinstance(other, usage):
            return self._t() == other._t()
        return self._t() == other

    def __hash__(self):
        return hash(self._t())

    def __repr__(self):
        return "usage(total=" + str(self.total) + ", used=" + str(self.used) + ", free=" + str(self.free) + ")"


_usage = usage


class _ShutilTermSize:
    # os.terminal_size: a 2-tuple with named fields.
    def __init__(self, columns, lines):
        self.columns = columns
        self.lines = lines

    def __getitem__(self, i):
        return [self.columns, self.lines][i]

    def __len__(self):
        return 2

    def __iter__(self):
        return iter([self.columns, self.lines])

    def __eq__(self, other):
        if isinstance(other, _ShutilTermSize):
            return self.columns == other.columns and self.lines == other.lines
        if isinstance(other, tuple):
            return (self.columns, self.lines) == other
        return false

    def __hash__(self):
        return hash((self.columns, self.lines))

    def __repr__(self):
        return "os.terminal_size(columns=" + str(self.columns) + ", lines=" + str(self.lines) + ")"


def _fspath(p):
    if isinstance(p, str) or isinstance(p, bytes):
        return p
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    raise TypeError("expected str, bytes or os.PathLike object, not " + type(p).__name__)


def _oserror(cls, eno, strerror, filename=none, filename2=none):
    var text = "[Errno " + str(eno) + "] " + strerror
    if filename is not none:
        text = text + ": " + repr(filename)
    if filename2 is not none:
        text = text + " -> " + repr(filename2)
    var e = cls(text)
    e.errno = eno
    e.strerror = strerror
    e.filename = filename
    e.filename2 = filename2
    return e


def _stat(p, follow_symlinks=true):
    if follow_symlinks:
        return os_stat(p)
    return os_lstat(p)


def _islink(p):
    return os_islink(p)


def _lexists(p):
    return os_exists(p) or os_islink(p)


def _isfifo(mode):
    return (mode & 0o170000) == 0o010000


def _imode(mode):
    return mode & 0o7777


def _samefile(src, dst):
    if not (os_exists(src) and os_exists(dst)):
        return false
    try:
        var a = os_stat(src)
        var b = os_stat(dst)
    except OSError:
        return false
    if a["ino"] != 0 and a["ino"] == b["ino"] and a.get("dev", 0) == b.get("dev", 0):
        return true
    if a["ino"] == 0 or _WINDOWS:
        return _normcase(os_path_abspath(src)) == _normcase(os_path_abspath(dst))
    return false


def _normcase(p):
    if _WINDOWS:
        return p.replace("/", "\\").lower()
    return p


def copyfileobj(fsrc, fdst, length=0):
    """copy data from file-like object fsrc to file-like object fdst"""
    if not length:
        length = COPY_BUFSIZE
    while true:
        var buf = fsrc.read(length)
        if not buf:
            break
        fdst.write(buf)


def copyfile(src, dst, follow_symlinks=true):
    """Copy data from src to dst in the most efficient way possible.

    If follow_symlinks is not set and src is a symbolic link, a new
    symlink will be created instead of copying the file it points to.
    """
    src = _fspath(src)
    dst = _fspath(dst)
    if _samefile(src, dst):
        raise SameFileError(repr(src) + " and " + repr(dst) + " are the same file")
    var i = 0
    for fn in [src, dst]:
        var st = none
        try:
            st = os_stat(fn)
        except OSError:
            # File most likely does not exist
            pass
        if st is not none and _isfifo(st["mode"]):
            raise SpecialFileError("`" + fn + "` is a named pipe")
        i = i + 1
    if not follow_symlinks and _islink(src):
        os_symlink(os_readlink(src), dst)
    else:
        var fsrc = open(src, "rb")
        try:
            var fdst = none
            try:
                fdst = open(dst, "wb")
            except IsADirectoryError as e:
                if not os_exists(dst):
                    raise FileNotFoundError("Directory does not exist: " + dst)
                raise
            try:
                copyfileobj(fsrc, fdst)
            finally:
                fdst.close()
        finally:
            fsrc.close()
    return dst


def copymode(src, dst, follow_symlinks=true):
    """Copy mode bits from src to dst."""
    src = _fspath(src)
    dst = _fspath(dst)
    if not follow_symlinks and _islink(src) and _islink(dst):
        # lchmod is not available on most platforms: nothing to do, as CPython
        return
    var st = _stat(src, follow_symlinks)
    os_chmod(dst, _imode(st["mode"]))


def copystat(src, dst, follow_symlinks=true):
    """Copy file metadata: permission bits, last access time and last
    modification time (and nothing else: no flags or extended attributes)."""
    src = _fspath(src)
    dst = _fspath(dst)
    var follow = follow_symlinks or not (_islink(src) and _islink(dst))
    if not follow:
        # utime/chmod of a link itself are not available: as CPython where
        # the platform lacks them, nothing is copied.
        return
    var st = _stat(src, true)
    os_utime(dst, (st["atime"], st["mtime"]))
    os_chmod(dst, _imode(st["mode"]))


def copy(src, dst, follow_symlinks=true):
    """Copy data and mode bits ("cp src dst"). Return the file's destination.

    The destination may be a directory.
    """
    src = _fspath(src)
    dst = _fspath(dst)
    if os_isdir(dst):
        dst = os_path_join(dst, os_path_basename(src))
    copyfile(src, dst, follow_symlinks)
    copymode(src, dst, follow_symlinks)
    return dst


def copy2(src, dst, follow_symlinks=true):
    """Copy data and metadata. Return the file's destination.

    The destination may be a directory.
    """
    src = _fspath(src)
    dst = _fspath(dst)
    if os_isdir(dst):
        dst = os_path_join(dst, os_path_basename(src))
    copyfile(src, dst, follow_symlinks)
    copystat(src, dst, follow_symlinks)
    return dst


def ignore_patterns(*patterns):
    """Function that can be used as copytree() ignore parameter.

    Patterns is a sequence of glob-style patterns
    that are used to exclude files"""
    def _ignore_patterns(path, names):
        var ignored_names = []
        for pattern in patterns:
            ignored_names.extend(_fnmatch_mod.filter(names, pattern))
        return set(ignored_names)
    return _ignore_patterns


def _listdir_or_raise(path):
    if not os_isdir(path):
        if not _lexists(path):
            raise _oserror(FileNotFoundError, 2, "No such file or directory", path)
        raise _oserror(NotADirectoryError, 20, "Not a directory", path)
    return os_listdir(path)


def _copytree(names, src, dst, symlinks, ignore, copy_function, ignore_dangling_symlinks, dirs_exist_ok):
    var ignored_names = set()
    if ignore is not none:
        ignored_names = ignore(src, list(names))
    if dirs_exist_ok:
        if not os_isdir(dst):
            os_makedirs(dst, exist_ok=true)
    else:
        if _lexists(dst):
            raise _oserror(FileExistsError, 17, "File exists", dst)
        os_makedirs(dst)
    var errors = []
    for name in names:
        if name in ignored_names:
            continue
        var srcname = os_path_join(src, name)
        var dstname = os_path_join(dst, name)
        try:
            if _islink(srcname):
                var linkto = os_readlink(srcname)
                if symlinks:
                    os_symlink(linkto, dstname)
                    copystat(srcname, dstname, not symlinks)
                else:
                    # ignore dangling symlink if the flag is on
                    if not os_exists(srcname) and ignore_dangling_symlinks:
                        continue
                    if os_isdir(srcname):
                        copytree(srcname, dstname, symlinks, ignore, copy_function,
                                 ignore_dangling_symlinks, dirs_exist_ok)
                    else:
                        copy_function(srcname, dstname)
            elif os_isdir(srcname):
                copytree(srcname, dstname, symlinks, ignore, copy_function,
                         ignore_dangling_symlinks, dirs_exist_ok)
            else:
                # Will raise a SpecialFileError for unsupported file types
                copy_function(srcname, dstname)
        # catch the Error from the recursive copytree so that we can
        # continue with other files
        except Error as err:
            errors.extend(err.args[0])
        except OSError as why:
            errors.append((srcname, dstname, str(why)))
    try:
        copystat(src, dst)
    except OSError as why:
        errors.append((src, dst, str(why)))
    if errors:
        raise Error(errors)
    return dst


def copytree(src, dst, symlinks=false, ignore=none, copy_function=none,
             ignore_dangling_symlinks=false, dirs_exist_ok=false):
    """Recursively copy a directory tree and return the destination directory.

    If exception(s) occur, an Error is raised with a list of reasons.
    """
    src = _fspath(src)
    dst = _fspath(dst)
    if copy_function is none:
        copy_function = copy2
    var names = _listdir_or_raise(src)
    return _copytree(names, src, dst, symlinks, ignore, copy_function,
                     ignore_dangling_symlinks, dirs_exist_ok)


def _rmtree_unsafe(path, onexc):
    var names = []
    try:
        names = _listdir_or_raise(path)
    except OSError as err:
        onexc(os_listdir, path, err)
    for name in names:
        var fullname = os_path_join(path, name)
        var is_dir = os_isdir(fullname) and not _islink(fullname)
        if is_dir:
            _rmtree_unsafe(fullname, onexc)
        else:
            try:
                os_unlink(fullname)
            except OSError as err:
                onexc(os_unlink, fullname, err)
    try:
        os_rmdir(path)
    except OSError as err:
        onexc(os_rmdir, path, err)


def rmtree(path, ignore_errors=false, onerror=none, onexc=none, dir_fd=none):
    """Recursively delete a directory tree.

    If ignore_errors is set, errors are ignored; otherwise, if onexc or
    onerror is set, it is called to handle the error with arguments (func,
    path, exc_info) where func is the function that raised the error
    (os_unlink, os_rmdir or os_listdir - Nython's os.unlink, os.rmdir,
    os.listdir), path is the argument to that function and exc_info is a
    (type, value, None) tuple for onerror, the exception for onexc. If
    ignore_errors is false and both onexc and onerror are None, the
    exception is raised. onerror is deprecated and only for backwards
    compatibility with onexc.
    """
    if onerror is not none and onexc is not none:
        raise TypeError("You cannot provide both onerror and onexc")
    if dir_fd is not none:
        raise NotImplementedError("dir_fd unavailable on this platform")
    var handler = none
    if ignore_errors:
        def _ignore(*args):
            pass
        handler = _ignore
    elif onerror is none and onexc is none:
        def _raise(func, p, exc):
            raise exc
        handler = _raise
    elif onerror is not none:
        def _onexc(func, p, exc):
            onerror(func, p, (type(exc), exc, none))
        handler = _onexc
    else:
        handler = onexc
    path = _fspath(path)
    # As CPython's fd-based version: a path that cannot be stat'ed is
    # reported once, through os.lstat.
    try:
        os_lstat(path)
    except OSError as err:
        handler(os_lstat, path, err)
        return
    if _islink(path):
        # symlinks to directories are forbidden, see bug #1669
        try:
            raise OSError("Cannot call rmtree on a symbolic link")
        except OSError as err:
            handler(os_islink, path, err)
            return
    _rmtree_unsafe(path, handler)





def _basename(path):
    path = _fspath(path)
    var seps = "\\/" if _WINDOWS else "/"
    var p = path
    while len(p) > 1 and p[-1] in seps:
        p = p[:-1]
    return os_path_basename(p)


def _abspath(p):
    return os_path_abspath(p)


def _destinsrc(src, dst):
    src = _abspath(src)
    dst = _abspath(dst)
    var sep = os.sep
    if not src.endswith(sep):
        src = src + sep
    if not dst.endswith(sep):
        dst = dst + sep
    return dst.startswith(src)


def move(src, dst, copy_function=none):
    """Recursively move a file or directory to another location. This is
    similar to the Unix "mv" command. Return the file or directory's
    destination.

    If dst is an existing directory or a symlink to a directory, then src
    is moved inside that directory. If the destination already exists but
    is not a directory, it may be overwritten depending on os.rename()
    semantics. If the destination is on another file system, src is copied
    (with copy_function, copy2 by default) and then removed.
    """
    if copy_function is none:
        copy_function = copy2
    src = _fspath(src)
    dst = _fspath(dst)
    var real_dst = dst
    if os_isdir(dst):
        if _samefile(src, dst) and not _islink(src):
            # We might be on a case insensitive filesystem,
            # perform the rename anyway.
            os_rename(src, dst)
            return
        real_dst = os_path_join(dst, _basename(src))
        if _lexists(real_dst):
            raise Error("Destination path '" + real_dst + "' already exists")
    if _lexists(src) and os_rename(src, real_dst):
        return real_dst
    if _islink(src):
        var linkto = os_readlink(src)
        os_symlink(linkto, real_dst)
        os_unlink(src)
    elif os_isdir(src):
        if _destinsrc(src, dst):
            raise Error("Cannot move a directory '" + src + "' into itself '" + dst + "'.")
        copytree(src, real_dst, true, none, copy_function)
        rmtree(src)
    else:
        copy_function(src, real_dst)
        os_unlink(src)
    return real_dst


def disk_usage(path):
    """Return disk usage statistics about the given path.

    Returned value is a named tuple with attributes 'total', 'used' and
    'free', which are the amount of total, used and free space, in bytes.
    """
    var d = os_disk_usage(_fspath(path))
    return _usage(d["total"], d["used"], d["free"])


def chown(path, user=none, group=none):
    """Change owner user and group of the given path."""
    if user is none and group is none:
        raise ValueError("user and/or group must be set")
    raise NotImplementedError("chown is not available in Nython (no os.chown)")


def get_terminal_size(fallback=(80, 24)):
    """Get the size of the terminal window.

    For each of the two dimensions, the environment variable, COLUMNS
    and LINES respectively, is checked. If the variable is defined and
    the value is a positive integer, it is used. When COLUMNS or LINES is
    not defined, the terminal connected to sys.__stdout__ is queried; if
    that fails (stdout is not a terminal), the fallback is used.
    """
    var columns = 0
    var lines = 0
    try:
        columns = int(os_getenv("COLUMNS"))
    except Exception:
        columns = 0
    try:
        lines = int(os_getenv("LINES"))
    except Exception:
        lines = 0
    if columns <= 0 or lines <= 0:
        var size = [fallback[0], fallback[1]]
        if stream_isatty(1):
            var t = os_get_terminal_size(1)
            size = [t[0], t[1]]
        if columns <= 0:
            columns = size[0] or fallback[0]
        if lines <= 0:
            lines = size[1] or fallback[1]
    return _ShutilTermSize(columns, lines)


def _access_check(fn, mode):
    var m = ""
    if mode & 4:
        m = m + "r"
    if mode & 2:
        m = m + "w"
    if mode & 1:
        m = m + "x"
    return os_exists(fn) and os_access(fn, m) and not os_isdir(fn)


def which(cmd, mode=1, path=none):
    """Given a command, mode, and a PATH string, return the path which
    conforms to the given mode on the PATH, or None if there is no such
    file.

    `mode` defaults to os.F_OK | os.X_OK (1). `path` defaults to the result
    of os.environ.get("PATH"), or can be overridden with a custom search
    path.
    """
    cmd = _fspath(cmd)
    var hs = os_path_split(cmd)
    if hs[0]:
        if _access_check(cmd, mode):
            return cmd
        return none
    if path is none:
        path = os_getenv("PATH")
        if path is none:
            path = "/bin:/usr/bin" if not _WINDOWS else ".;C:\\bin"
    if not path:
        return none
    path = _fspath(path)
    var dirs = path.split(os_pathsep)
    var files = [cmd]
    if _WINDOWS:
        # The current directory comes first, then PATH; PATHEXT names the
        # executable extensions (a name with one of them is tried as is).
        if not any([d == "." for d in dirs]):
            dirs.insert(0, ".")
        var pathext_source = os_getenv("PATHEXT")
        if not pathext_source:
            pathext_source = ".COM;.EXE;.BAT;.CMD;.VBS;.JS;.WS;.MSC"
        var pathext = [ext for ext in pathext_source.split(os_pathsep) if ext]
        var low = cmd.lower()
        if any([low.endswith(ext.lower()) for ext in pathext]):
            files = [cmd]
        else:
            files = [cmd + ext for ext in pathext]
    var seen = set()
    for d in dirs:
        var normdir = d.lower() if _WINDOWS else d
        if normdir not in seen:
            seen.add(normdir)
            for thefile in files:
                var name = os_path_join(d, thefile)
                if _access_check(name, mode):
                    return name
    return none


# ── Archives ─────────────────────────────────────────────────────────────────
# Only the uncompressed POSIX tar format: no compression library exists in
# Nython. The writer emits ustar headers (CPython's tarfile reads them; its
# default since 3.8 is pax, which differs only for long names and extended
# attributes); the reader accepts ustar/gnu headers.

_ARCHIVE_FORMATS = {}
_UNPACK_FORMATS = {}


def _tar_octal(n, width):
    var s = oct(n)[2:]
    while len(s) < width - 1:
        s = "0" + s
    return s.encode("ascii") + b"\0"


def _tar_field(text, width):
    var b = text.encode("utf-8")
    if len(b) > width:
        raise ValueError("name too long for a tar header: " + repr(text))
    return b + b"\0" * (width - len(b))


def _tar_split_name(name):
    var b = name.encode("utf-8")
    if len(b) <= 100:
        return ["", name]
    var i = len(name) - 1
    while i > 0:
        if name[i] == "/":
            var prefix = name[:i]
            var rest = name[i + 1:]
            if len(prefix.encode("utf-8")) <= 155 and len(rest.encode("utf-8")) <= 100:
                return [prefix, rest]
        i = i - 1
    raise ValueError("name too long for a ustar header: " + repr(name))


def _tar_header(name, size, mode, mtime, typeflag, linkname=""):
    var pn = _tar_split_name(name)
    var h = bytearray()
    h.extend(_tar_field(pn[1], 100))
    h.extend(_tar_octal(mode & 0o7777, 8))
    h.extend(_tar_octal(0, 8))          # uid
    h.extend(_tar_octal(0, 8))          # gid
    h.extend(_tar_octal(size, 12))
    h.extend(_tar_octal(int(mtime), 12))
    h.extend(b"        ")               # checksum placeholder
    h.extend(typeflag)
    h.extend(_tar_field(linkname, 100))
    h.extend(b"ustar\x0000")
    h.extend(_tar_field("", 32))        # uname
    h.extend(_tar_field("", 32))        # gname
    h.extend(_tar_octal(0, 8))          # devmajor
    h.extend(_tar_octal(0, 8))          # devminor
    h.extend(_tar_field(pn[0], 155))
    h.extend(b"\0" * 12)
    var chk = 0
    for c in h:
        chk = chk + c
    var cs = oct(chk)[2:]
    while len(cs) < 6:
        cs = "0" + cs
    var csb = cs.encode("ascii") + b"\0 "
    var i = 0
    while i < 8:
        h[148 + i] = csb[i]
        i = i + 1
    return bytes(h)


def _tar_add(out, path, arcname):
    var st = os_lstat(path)
    if _islink(path):
        out.write(_tar_header(arcname, 0, st["mode"], st["mtime"], b"2", os_readlink(path)))
    elif os_isdir(path):
        var dn = arcname if arcname.endswith("/") else arcname + "/"
        out.write(_tar_header(dn, 0, st["mode"], st["mtime"], b"5"))
        var names = sorted(os_listdir(path))
        for n in names:
            _tar_add(out, os_path_join(path, n), arcname.rstrip("/") + "/" + n if arcname not in [".", ""] else n)
    else:
        var f = open(path, "rb")
        var data = f.read()
        f.close()
        out.write(_tar_header(arcname, len(data), st["mode"], st["mtime"], b"0"))
        out.write(data)
        var pad = (512 - len(data) % 512) % 512
        if pad:
            out.write(b"\0" * pad)


def _make_tarball(base_name, base_dir, compress="", verbose=0, dry_run=0, owner=none, group=none, logger=none, root_dir=none):
    var archive_name = base_name + ".tar"
    var archive_dir = os_path_split(archive_name)[0]
    if archive_dir and not os_exists(archive_dir):
        if not dry_run:
            os_makedirs(archive_dir, exist_ok=true)
    if dry_run:
        return archive_name
    var src = base_dir if root_dir is none else os_path_join(root_dir, base_dir)
    var out = open(archive_name, "wb")
    try:
        var arc = base_dir
        while arc.startswith("./"):
            arc = arc[2:]
        if arc == "" or arc == ".":
            out.write(_tar_header("./", 0, os_stat(src)["mode"], os_stat(src)["mtime"], b"5"))
            for n in sorted(os_listdir(src)):
                _tar_add(out, os_path_join(src, n), "./" + n)
        else:
            _tar_add(out, src, arc)
        out.write(b"\0" * 1024)
    finally:
        out.close()
    return archive_name


_ARCHIVE_FORMATS["tar"] = [_make_tarball, [["compress", ""]], "uncompressed tar file"]


def get_archive_formats():
    """Returns a list of supported formats for archiving and unarchiving.

    Each element of the returned sequence is a tuple (name, description)
    """
    var formats = []
    for name in _ARCHIVE_FORMATS:
        formats.append((name, _ARCHIVE_FORMATS[name][2]))
    formats.sort()
    return formats


def register_archive_format(name, function, extra_args=none, description=""):
    """Registers an archive format."""
    if extra_args is none:
        extra_args = []
    if not callable(function):
        raise TypeError("The " + repr(function) + " object is not callable")
    if not isinstance(extra_args, (tuple, list)):
        raise TypeError("extra_args needs to be a sequence")
    for element in extra_args:
        if not isinstance(element, (tuple, list)) or len(element) != 2:
            raise TypeError("extra_args elements are : (arg_name, value)")
    _ARCHIVE_FORMATS[name] = [function, extra_args, description]


def unregister_archive_format(name):
    del _ARCHIVE_FORMATS[name]


def make_archive(base_name, format, root_dir=none, base_dir=none, verbose=0,
                 dry_run=0, owner=none, group=none, logger=none):
    """Create an archive file (eg. zip or tar).

    'base_name' is the name of the file to create, minus any format-specific
    extension; 'format' is the archive format: one of the names
    get_archive_formats() lists ("tar" here).

    'root_dir' is a directory that will be the root directory of the
    archive; 'base_dir' is the directory where we start archiving from
    (relative to root_dir).
    """
    base_name = _fspath(base_name)
    if format not in _ARCHIVE_FORMATS:
        raise ValueError("unknown archive format '" + str(format) + "'")
    var fmt = _ARCHIVE_FORMATS[format]
    if root_dir is not none:
        root_dir = _fspath(root_dir)
        base_name = os_path_abspath(base_name)
    if base_dir is none:
        base_dir = "."
    var func = fmt[0]
    if id(func) == id(_make_tarball):
        return func(base_name, base_dir, "", verbose, dry_run, owner, group, logger, root_dir)
    var save_cwd = none
    if root_dir is not none:
        save_cwd = os_getcwd()
        os_chdir(root_dir)
    try:
        var kwargs = {"dry_run": dry_run, "logger": logger}
        for kv in fmt[1]:
            kwargs[kv[0]] = kv[1]
        return func(base_name, base_dir, **kwargs)
    finally:
        if save_cwd is not none:
            os_chdir(save_cwd)


def _tar_parse_octal(b):
    var s = b.decode("ascii", "replace").strip(" \0")
    if not s:
        return 0
    return int(s, 8)


def _tar_cstr(b):
    var i = b.find(b"\0")
    if i >= 0:
        b = b[:i]
    return b.decode("utf-8", "replace")


def _unpack_tarfile(filename, extract_dir, filter=none):
    """Unpack tar `filename` to `extract_dir`."""
    var f = none
    try:
        f = open(filename, "rb")
    except OSError:
        raise ReadError(filename + " is not a compressed or uncompressed tar file")
    var data = f.read()
    f.close()
    var pos = 0
    var n = len(data)
    var any_ok = false
    var dir_times = []
    while pos + 512 <= n:
        var hdr = data[pos:pos + 512]
        if hdr == b"\0" * 512:
            break
        var chk = 0
        var k = 0
        while k < 512:
            chk = chk + (32 if k >= 148 and k < 156 else hdr[k])
            k = k + 1
        if _tar_parse_octal(hdr[148:156]) != chk:
            raise ReadError(filename + " is not a compressed or uncompressed tar file")
        any_ok = true
        var name = _tar_cstr(hdr[0:100])
        var prefix = _tar_cstr(hdr[345:500]) if hdr[257:262] == b"ustar" else ""
        if prefix:
            name = prefix + "/" + name
        var mode = _tar_parse_octal(hdr[100:108])
        var size = _tar_parse_octal(hdr[124:136])
        var mtime = _tar_parse_octal(hdr[136:148])
        var typeflag = hdr[156:157]
        var linkname = _tar_cstr(hdr[157:257])
        pos = pos + 512
        var body = data[pos:pos + size]
        pos = pos + size + (512 - size % 512) % 512
        # Refuse absolute names and ones that climb out of extract_dir
        # (tarfile's "data" filter rules for the paths).
        var clean = name
        while clean.startswith("./"):
            clean = clean[2:]
        clean = clean.rstrip("/")
        if clean == "" or clean == ".":
            continue
        if clean.startswith("/") or ".." in clean.split("/"):
            raise ReadError("refusing to extract " + repr(name) + " outside the destination directory")
        var target = os_path_join(extract_dir, clean.replace("/", os.sep))
        if typeflag == b"5":
            os_makedirs(target, exist_ok=true)
            dir_times.append([target, mode, mtime])
        elif typeflag == b"2":
            var parent = os_path_split(target)[0]
            if parent:
                os_makedirs(parent, exist_ok=true)
            if _lexists(target):
                os_unlink(target)
            os_symlink(linkname, target)
        elif typeflag == b"0" or typeflag == b"\0" or typeflag == b"7":
            var parent2 = os_path_split(target)[0]
            if parent2:
                os_makedirs(parent2, exist_ok=true)
            var out = open(target, "wb")
            out.write(body)
            out.close()
            os_chmod(target, mode & 0o7777)
            os_utime(target, (mtime, mtime))
    if not any_ok:
        raise ReadError(filename + " is not a compressed or uncompressed tar file")
    for d in dir_times:
        os_chmod(d[0], d[1] & 0o7777)
        os_utime(d[0], (d[2], d[2]))


_UNPACK_FORMATS["tar"] = [[".tar"], _unpack_tarfile, [], "uncompressed tar file"]


def get_unpack_formats():
    """Returns a list of supported formats for unpacking.

    Each element of the returned sequence is a tuple
    (name, extensions, description)
    """
    var formats = []
    for name in _UNPACK_FORMATS:
        var info = _UNPACK_FORMATS[name]
        formats.append((name, info[0], info[3]))
    formats.sort()
    return formats


def register_unpack_format(name, extensions, function, extra_args=none, description=""):
    """Registers an unpack format."""
    if extra_args is none:
        extra_args = []
    var existing_extensions = {}
    for nm in _UNPACK_FORMATS:
        for ext in _UNPACK_FORMATS[nm][0]:
            existing_extensions[ext] = nm
    for extension in extensions:
        if extension in existing_extensions:
            raise RegistryError(extension + " is already registered for \"" + existing_extensions[extension] + "\"")
    if not callable(function):
        raise TypeError("The registered function must be a callable")
    _UNPACK_FORMATS[name] = [extensions, function, extra_args, description]


def unregister_unpack_format(name):
    """Removes the pack format from the registry."""
    del _UNPACK_FORMATS[name]


def _find_unpack_format(filename):
    for name in _UNPACK_FORMATS:
        for extension in _UNPACK_FORMATS[name][0]:
            if filename.endswith(extension):
                return name
    return none


def unpack_archive(filename, extract_dir=none, format=none, filter=none):
    """Unpack an archive.

    `filename` is the name of the archive. `extract_dir` is the name of the
    target directory (the current directory by default). `format` is the
    archive format; when not given, it is guessed from the extension.
    """
    if extract_dir is none:
        extract_dir = os_getcwd()
    extract_dir = _fspath(extract_dir)
    filename = _fspath(filename)
    var info = none
    if format is not none:
        if format not in _UNPACK_FORMATS:
            raise ValueError("Unknown unpack format '" + str(format) + "'")
        info = _UNPACK_FORMATS[format]
    else:
        var fmt = _find_unpack_format(filename)
        if fmt is none:
            raise ReadError("Unknown archive format '" + filename + "'")
        info = _UNPACK_FORMATS[fmt]
    var func = info[1]
    var kwargs = {}
    for kv in info[2]:
        kwargs[kv[0]] = kv[1]
    if id(func) == id(_unpack_tarfile):
        func(filename, extract_dir, filter)
    else:
        func(filename, extract_dir, **kwargs)
