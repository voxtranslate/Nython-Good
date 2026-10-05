# nython: module    (import it by name: it runs in a module scope of its own)
# lib/pathlib.ny - Python's pathlib: object-oriented file-system paths.
#
#     PurePath, PurePosixPath, PureWindowsPath    path arithmetic only
#     Path, PosixPath, WindowsPath                plus file-system access
#
# Pure paths: the / operator, parts, drive, root, anchor, name, stem,
# suffix, suffixes, parent, parents (indexable, slices, negative indices),
# joinpath, with_name, with_stem, with_suffix, with_segments, relative_to
# (walk_up=), is_relative_to, is_absolute, is_reserved, match, as_posix,
# as_uri, __fspath__, str/repr ("PosixPath('a/b')"), equality, hashing and
# ordering (case-insensitive for Windows paths).
# Path: cwd, home, stat/lstat (an os.stat_result-like object), exists,
# is_dir, is_file, is_symlink, is_mount, is_fifo/is_socket/is_block_device/
# is_char_device, iterdir, glob, rglob, walk, open, read_text, write_text,
# read_bytes, write_bytes, mkdir(parents, exist_ok), rmdir,
# unlink(missing_ok), rename, replace, touch, resolve(strict), absolute,
# expanduser, readlink, symlink_to, chmod, samefile.
#
# Parsing, joining and formatting are CPython 3.12's (posixpath/ntpath
# splitroot and join rules: "//x" keeps two slashes on POSIX, UNC drives
# and "C:" relative drives on Windows), written here for both flavours, so
# PureWindowsPath works on Linux and PurePosixPath on Windows.
#
# Differences from CPython (Nython has no __new__ yet):
#   - Path is the platform's concrete class itself (Path is PosixPath on
#     POSIX, WindowsPath on Windows): Path("a") is a PosixPath, isinstance
#     and subclassing work; type(p) is Path holds, and Path.__name__ is
#     "PosixPath". Instantiating the other platform's class raises
#     NotImplementedError ("cannot instantiate 'WindowsPath' on your system").
#   - PurePath("a") is a PurePath with the platform's flavour, shown as
#     PurePosixPath('a') / PureWindowsPath('a') (it is not an instance of
#     either subclass).
#   - Paths hash by their (case-folded) text, so they work in sets; as dict
#     KEYS they are compared by identity (Nython's dicts key objects by
#     identity, not __hash__/__eq__).
#   - glob() matches hidden files with "*" as CPython does, in directory
#     order; "**" recurses (following symlinks to directories, as 3.12).
#   - owner()/group() and hardlink_to() raise NotImplementedError (no pwd/
#     grp/os.link natives); mkdir(mode) applies mode & ~0o022 (no umask).
#   - Path objects are accepted by the os_* natives and open() (they call
#     __fspath__), so os.listdir(p), open(p) and os.path.join(p, "x") work.

import os
import fnmatch as _fnmatch_mod

__all__ = ["UnsupportedOperation", "PurePath", "PurePosixPath", "PureWindowsPath",
           "Path", "PosixPath", "WindowsPath"]

_IS_WINDOWS = os_platform() == "windows"


# The builtins Path.open/Path.mkdir stand on, under names of their own (a
# bare call inside a method may resolve to a member of the same name).
def _builtin_open(path, mode, encoding="utf-8"):
    if "b" in mode:
        return open(path, mode)
    return open(path, mode, encoding)


def _mkdir_one(path):
    return mkdir(path)

_WIN_RESERVED = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
                 "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
                 "COM\xb9", "COM\xb2", "COM\xb3",
                 "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
                 "LPT\xb9", "LPT\xb2", "LPT\xb3"]


class UnsupportedOperation(NotImplementedError):
    """An exception that is raised when an unsupported operation is called on
    a path object."""
    pass


# ── flavour helpers (posixpath / ntpath) ─────────────────────────────────────

def _posix_splitroot(p):
    if p[:1] != "/":
        return ["", "", p]
    if p[1:2] != "/" or p[2:3] == "/":
        return ["", "/", p[1:]]
    return ["", p[:2], p[2:]]


def _nt_splitroot(p):
    var normp = p.replace("/", "\\")
    if normp[:1] == "\\":
        if normp[1:2] == "\\":
            # UNC drives, e.g. \\server\share or \\?\UNC\server\share
            # Device drives, e.g. \\.\device or \\?\device
            var start = 8 if normp[:8].upper() == "\\\\?\\UNC\\" else 2
            var index = normp.find("\\", start)
            if index == -1:
                return [p, "", ""]
            var index2 = normp.find("\\", index + 1)
            if index2 == -1:
                return [p, "", ""]
            return [p[:index2], p[index2:index2 + 1], p[index2 + 1:]]
        return ["", p[:1], p[1:]]
    if normp[1:2] == ":":
        if normp[2:3] == "\\":
            return [p[:2], p[2:3], p[3:]]
        return [p[:2], "", p[2:]]
    return ["", "", p]


def _posix_join(paths):
    var path = paths[0]
    var i = 1
    while i < len(paths):
        var b = paths[i]
        if b.startswith("/"):
            path = b
        elif not path or path.endswith("/"):
            path = path + b
        else:
            path = path + "/" + b
        i = i + 1
    return path


def _nt_join(paths):
    var r = _nt_splitroot(paths[0])
    var result_drive = r[0]
    var result_root = r[1]
    var result_path = r[2]
    var i = 1
    while i < len(paths):
        var q = _nt_splitroot(paths[i])
        i = i + 1
        var p_drive = q[0]
        var p_root = q[1]
        var p_path = q[2]
        if p_root:
            # Second path is absolute
            if p_drive or not result_drive:
                result_drive = p_drive
            result_root = p_root
            result_path = p_path
            continue
        elif p_drive and p_drive != result_drive:
            if p_drive.lower() != result_drive.lower():
                # Different drives => ignore the first path entirely
                result_drive = p_drive
                result_root = p_root
                result_path = p_path
                continue
            # Same drive in different case
            result_drive = p_drive
        # Second path is relative to the first
        if result_path and result_path[-1] not in "\\/":
            result_path = result_path + "\\"
        result_path = result_path + p_path
    # add separator between UNC and non-absolute path
    if result_path and not result_root and result_drive and result_drive[-1:] not in ":\\/":
        return result_drive + "\\" + result_path
    return result_drive + result_root + result_path


# Python's name for a value's type (Nython calls dict "map", str "string").
_PY_TYPE_NAMES = {"map": "dict", "string": "str", "none": "NoneType", "builtin": "builtin_function_or_method"}


def _tname(x):
    var n = x.__class__.__name__ if hasattr(x, "__class__") else type(x).__name__
    return _PY_TYPE_NAMES.get(n, n)


def _fspath_str(arg):
    if isinstance(arg, str):
        return arg
    if hasattr(arg, "__fspath__"):
        var s = arg.__fspath__()
        if isinstance(s, str):
            return s
        raise TypeError("argument should be a str or an os.PathLike object where __fspath__ returns a str, not " + repr(_tname(s)))
    raise TypeError("argument should be a str or an os.PathLike object where __fspath__ returns a str, not " + repr(_tname(arg)))


class _PathParents:
    """This object provides sequence-like access to the logical ancestors
    of a path.  Don't try to construct it yourself."""
    def __init__(self, path):
        self._path = path
        self._drv = path.drive
        self._root = path.root
        self._tail = path._tail

    def __len__(self):
        return len(self._tail)

    def __getitem__(self, idx):
        if isinstance(idx, slice):
            var out = []
            for i in range(*idx.indices(len(self))):
                out.append(self[i])
            return tuple(out)
        var n = len(self)
        if idx >= n or idx < -n:
            raise IndexError(idx)
        if idx < 0:
            idx = idx + n
        return self._path._from_parsed_parts(self._drv, self._root, self._tail[:-idx - 1])

    def __iter__(self):
        var i = 0
        while i < len(self._tail):
            yield self[i]
            i = i + 1

    def __contains__(self, item):
        for p in self:
            if p == item:
                return true
        return false

    def __repr__(self):
        return "<" + type(self._path).__name__ + ".parents>"


# ── PurePath ─────────────────────────────────────────────────────────────────

class PurePath:
    """Base class for manipulating paths without I/O.

    PurePath represents a filesystem path and offers operations which
    don't imply any actual filesystem I/O.  Depending on your system,
    instantiating a PurePath gives a path with the POSIX or the Windows
    flavour (shown as PurePosixPath or PureWindowsPath).
    """
    _windows = _IS_WINDOWS
    _shown_name = "PureWindowsPath" if _IS_WINDOWS else "PurePosixPath"

    def __init__(self, *args):
        var paths = []
        for arg in args:
            if isinstance(arg, PurePath):
                if arg._windows and not self._windows:
                    # GH-103631: convert separators for backwards compatibility
                    for rp in arg._raw_paths:
                        paths.append(rp.replace("\\", "/"))
                else:
                    paths.extend(arg._raw_paths)
            else:
                paths.append(_fspath_str(arg))
        self._raw_paths = paths
        self._load_parts()

    # The flavour
    @property
    def _sep(self):
        return "\\" if self._windows else "/"

    def _splitroot(self, p):
        if self._windows:
            return _nt_splitroot(p)
        return _posix_splitroot(p)

    def _parse_path(self, path):
        if not path:
            return ["", "", []]
        var sep = self._sep
        if self._windows:
            path = path.replace("/", "\\")
        var r = self._splitroot(path)
        var drv = r[0]
        var root = r[1]
        var rel = r[2]
        if not root and drv.startswith(sep) and not drv.endswith(sep):
            var drv_parts = drv.split(sep)
            if len(drv_parts) == 4 and drv_parts[2] not in ["?", "."]:
                # e.g. //server/share
                root = sep
            elif len(drv_parts) == 6:
                # e.g. //?/unc/server/share
                root = sep
        var parsed = []
        for x in rel.split(sep):
            if x and x != ".":
                parsed.append(x)
        return [drv, root, parsed]

    def _load_parts(self):
        var paths = self._raw_paths
        var path = ""
        if len(paths) == 1:
            path = paths[0]
        elif len(paths) > 1:
            path = _nt_join(paths) if self._windows else _posix_join(paths)
        var r = self._parse_path(path)
        self._drv = r[0]
        self._root = r[1]
        self._tail = r[2]
        self._str = self._format_parsed_parts(r[0], r[1], r[2]) or "."

    def _format_parsed_parts(self, drv, root, tail):
        var sep = self._sep
        if drv or root:
            return drv + root + sep.join(tail)
        if tail and self._windows and _nt_splitroot(tail[0])[0]:
            return sep.join(["."] + tail)
        return sep.join(tail)

    def _from_parsed_parts(self, drv, root, tail):
        var path_str = self._format_parsed_parts(drv, root, tail)
        var path = self.with_segments(path_str)
        path._str = path_str or "."
        path._drv = drv
        path._root = root
        path._tail = list(tail)
        return path

    def with_segments(self, *pathsegments):
        """Construct a new path object from any number of path-like objects.
        Subclasses may override this method to customize how new path objects
        are created from methods like `iterdir()`.
        """
        return self.__class__(*pathsegments)

    def __str__(self):
        """Return the string representation of the path, suitable for
        passing to system calls."""
        return self._str

    def __fspath__(self):
        return self._str

    def as_posix(self):
        """Return the string representation of the path with forward (/)
        slashes."""
        return self._str.replace(self._sep, "/")

    def __bytes__(self):
        """Return the bytes representation of the path."""
        return self._str.encode("utf-8")

    def _class_name(self):
        var n = self.__class__.__name__
        if n == "PurePath":
            return self._shown_name
        return n

    def __repr__(self):
        return self._class_name() + "(" + repr(self.as_posix()) + ")"

    def as_uri(self):
        """Return the path as a 'file' URI."""
        if not self.is_absolute():
            raise ValueError("relative path can't be expressed as a file URI")
        var drive = self.drive
        var prefix = "file://"
        var path = ""
        if self._windows:
            if len(drive) == 2 and drive[1] == ":":
                # It's a path on a local drive => 'file:///c:/a/b'
                prefix = "file:///" + drive
                path = self.as_posix()[2:]
            elif drive:
                # It's a path on a network drive => 'file://host/share/a/b'
                prefix = "file:"
                path = self.as_posix()
            else:
                path = self.as_posix()
        else:
            path = str(self)
        return prefix + _quote_path(path)

    @property
    def _str_normcase(self):
        if self._windows:
            return self._str.lower()
        return self._str

    @property
    def _parts_normcase(self):
        return self._str_normcase.split(self._sep)

    def __eq__(self, other):
        if not isinstance(other, PurePath):
            return false
        return self._str_normcase == other._str_normcase and self._windows == other._windows

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash(self._str_normcase)

    def _cmp_check(self, other, op):
        if not isinstance(other, PurePath) or self._windows != other._windows:
            raise TypeError("'" + op + "' not supported between instances of '" + self.__class__.__name__ + "' and '" + _tname(other) + "'")

    def __lt__(self, other):
        self._cmp_check(other, "<")
        return self._parts_normcase < other._parts_normcase

    def __le__(self, other):
        self._cmp_check(other, "<=")
        return self._parts_normcase <= other._parts_normcase

    def __gt__(self, other):
        self._cmp_check(other, ">")
        return self._parts_normcase > other._parts_normcase

    def __ge__(self, other):
        self._cmp_check(other, ">=")
        return self._parts_normcase >= other._parts_normcase

    @property
    def drive(self):
        """The drive prefix (letter or UNC path), if any."""
        return self._drv

    @property
    def root(self):
        """The root of the path, if any."""
        return self._root

    @property
    def anchor(self):
        """The concatenation of the drive and root, or ''."""
        return self._drv + self._root

    @property
    def name(self):
        """The final path component, if any."""
        if not self._tail:
            return ""
        return self._tail[-1]

    @property
    def suffix(self):
        """The final component's last suffix, if any.

        This includes the leading period. For example: '.txt'
        """
        var name = self.name
        var i = name.rfind(".")
        if 0 < i and i < len(name) - 1:
            return name[i:]
        return ""

    @property
    def suffixes(self):
        """A list of the final component's suffixes, if any.

        These include the leading periods. For example: ['.tar', '.gz']
        """
        var name = self.name
        if name.endswith("."):
            return []
        name = name.lstrip(".")
        var out = []
        for s in name.split(".")[1:]:
            out.append("." + s)
        return out

    @property
    def stem(self):
        """The final path component, minus its last suffix."""
        var name = self.name
        var i = name.rfind(".")
        if 0 < i and i < len(name) - 1:
            return name[:i]
        return name

    def with_name(self, name):
        """Return a new path with the file name changed."""
        if not self.name:
            raise ValueError(repr(self) + " has an empty name")
        if not name or self._sep in name or (self._windows and "/" in name) or name == ".":
            raise ValueError("Invalid name " + repr(name))
        var tail = list(self._tail)
        tail[-1] = name
        return self._from_parsed_parts(self._drv, self._root, tail)

    def with_stem(self, stem):
        """Return a new path with the stem changed."""
        return self.with_name(stem + self.suffix)

    def with_suffix(self, suffix):
        """Return a new path with the file suffix changed.  If the path
        has no suffix, add given suffix.  If the given suffix is an empty
        string, remove the suffix from the path.
        """
        if self._sep in suffix or (self._windows and "/" in suffix):
            raise ValueError("Invalid suffix " + repr(suffix))
        if (suffix and not suffix.startswith(".")) or suffix == ".":
            raise ValueError("Invalid suffix " + repr(suffix))
        var name = self.name
        if not name:
            raise ValueError(repr(self) + " has an empty name")
        var old_suffix = self.suffix
        if not old_suffix:
            name = name + suffix
        else:
            name = name[:len(name) - len(old_suffix)] + suffix
        return self._from_parsed_parts(self._drv, self._root, self._tail[:-1] + [name])

    def relative_to(self, other, *_deprecated, walk_up=false):
        """Return the relative path to another path identified by the passed
        arguments.  If the operation is not possible (because this is not
        related to the other path), raise ValueError.

        The *walk_up* parameter controls whether `..` may be used to resolve
        the path.
        """
        if _deprecated:
            other = self.with_segments(other, *_deprecated)
        elif not isinstance(other, PurePath):
            other = self.with_segments(other)
        var candidates = [other] + list(other.parents)
        var step = 0
        var found = none
        for path in candidates:
            if self.is_relative_to(path):
                found = path
                break
            elif not walk_up:
                raise ValueError(repr(str(self)) + " is not in the subpath of " + repr(str(other)))
            elif path.name == "..":
                raise ValueError("'..' segment in " + repr(str(other)) + " cannot be walked")
            step = step + 1
        if found is none:
            raise ValueError(repr(str(self)) + " and " + repr(str(other)) + " have different anchors")
        var parts = [".."] * step + self._tail[len(found._tail):]
        return self.with_segments(*parts)

    def is_relative_to(self, other, *_deprecated):
        """Return True if the path is relative to another path or False.
        """
        if _deprecated:
            other = self.with_segments(other, *_deprecated)
        elif not isinstance(other, PurePath):
            other = self.with_segments(other)
        return other == self or other in self.parents

    @property
    def parts(self):
        """An object providing sequence-like access to the
        components in the filesystem path."""
        if self._drv or self._root:
            return tuple([self._drv + self._root] + self._tail)
        return tuple(self._tail)

    def joinpath(self, *pathsegments):
        """Combine this path with one or several arguments, and return a
        new path representing either a subpath (if all arguments are relative
        paths) or a totally different path (if one of the arguments is
        anchored).
        """
        return self.with_segments(self, *pathsegments)

    def __truediv__(self, key):
        if not (isinstance(key, str) or isinstance(key, PurePath) or hasattr(key, "__fspath__")):
            raise TypeError("unsupported operand type(s) for /: '" + self.__class__.__name__ + "' and '" + _tname(key) + "'")
        return self.joinpath(key)

    def __rtruediv__(self, key):
        if not (isinstance(key, str) or hasattr(key, "__fspath__")):
            raise TypeError("unsupported operand type(s) for /: '" + _tname(key) + "' and '" + self.__class__.__name__ + "'")
        return self.with_segments(key, self)

    @property
    def parent(self):
        """The logical parent of the path."""
        if not self._tail:
            return self
        return self._from_parsed_parts(self._drv, self._root, self._tail[:-1])

    @property
    def parents(self):
        """A sequence of this path's logical parents."""
        return _PathParents(self)

    def is_absolute(self):
        """True if the path is absolute (has both a root and, if applicable,
        a drive)."""
        if self._windows:
            return bool(self._drv and self._root)
        return bool(self._root)

    def is_reserved(self):
        """Return True if the path contains one of the special names reserved
        by the system, if any."""
        if not self._windows or not self._tail:
            return false
        # NOTE: the rules for reserved names seem somewhat complicated
        # (e.g. r"..\NUL" is reserved but not r"foo\NUL" if "foo" does not
        # exist). We err on the side of caution and return True for paths
        # which are not considered reserved by Windows.
        if self._drv.startswith("\\\\"):
            # UNC paths are never reserved.
            return false
        var name = self._tail[-1].split(".")[0].split(":")[0].rstrip(" ")
        return name.upper() in _WIN_RESERVED

    def match(self, path_pattern, case_sensitive=none):
        """
        Return True if this path matches the given pattern.
        """
        if isinstance(path_pattern, PurePath):
            path_pattern = str(path_pattern)
        if case_sensitive is none:
            case_sensitive = not self._windows
        var pat = self.with_segments(path_pattern)
        var pat_parts = list(pat.parts)
        if not pat_parts:
            raise ValueError("empty pattern")
        var parts = list(self.parts)
        if not case_sensitive:
            var lp = []
            for p in parts:
                lp.append(p.lower())
            parts = lp
            var lq = []
            for q in pat_parts:
                lq.append(q.lower())
            pat_parts = lq
        if pat._drv or pat._root:
            if len(pat_parts) != len(parts):
                return false
            if pat_parts[0] != parts[0]:
                return false
            pat_parts = pat_parts[1:]
            parts = parts[1:]
        elif len(pat_parts) > len(parts):
            return false
        var i = 1
        while i <= len(pat_parts):
            if not _fnmatch_mod.fnmatchcase(parts[-i], pat_parts[-i]):
                return false
            i = i + 1
        return true


class PurePosixPath(PurePath):
    """PurePath subclass for non-Windows systems.

    On a POSIX system, instantiating a PurePath should return this object.
    However, you can also instantiate it directly on any system.
    """
    _windows = false
    _shown_name = "PurePosixPath"


class PureWindowsPath(PurePath):
    """PurePath subclass for Windows systems.

    On a Windows system, instantiating a PurePath should return this object.
    However, you can also instantiate it directly on any system.
    """
    _windows = true
    _shown_name = "PureWindowsPath"


_SAFE_URI = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/"


def _quote_path(path):
    var out = []
    for b in path.encode("utf-8"):
        var ch = chr(b)
        if b < 128 and ch in _SAFE_URI:
            out.append(ch)
        else:
            var h = hex(b)[2:].upper()
            if len(h) < 2:
                h = "0" + h
            out.append("%" + h)
    return "".join(out)


# ── stat results ─────────────────────────────────────────────────────────────

class _PathStatResult:
    # os.stat_result: st_* attributes and the 10-item tuple view.
    def __init__(self, m):
        self.st_mode = m["mode"]
        self.st_ino = m["ino"]
        self.st_dev = m.get("dev", 0)
        self.st_nlink = m["nlink"]
        self.st_uid = m["uid"]
        self.st_gid = m["gid"]
        self.st_size = m["size"]
        self.st_atime = m["atime"]
        self.st_mtime = m["mtime"]
        self.st_ctime = m["ctime"]
        self.st_atime_ns = int(m["atime"] * 1000000000)
        self.st_mtime_ns = int(m["mtime"] * 1000000000)
        self.st_ctime_ns = int(m["ctime"] * 1000000000)

    def _tuple(self):
        return (self.st_mode, self.st_ino, self.st_dev, self.st_nlink, self.st_uid,
                self.st_gid, self.st_size, int(self.st_atime), int(self.st_mtime), int(self.st_ctime))

    def __getitem__(self, i):
        return self._tuple()[i]

    def __len__(self):
        return 10

    def __iter__(self):
        return iter(self._tuple())

    def __eq__(self, other):
        if isinstance(other, _PathStatResult):
            return self._tuple() == other._tuple()
        return self._tuple() == other

    def __repr__(self):
        var t = self._tuple()
        return ("os.stat_result(st_mode=" + str(t[0]) + ", st_ino=" + str(t[1]) + ", st_dev=" + str(t[2]) +
                ", st_nlink=" + str(t[3]) + ", st_uid=" + str(t[4]) + ", st_gid=" + str(t[5]) +
                ", st_size=" + str(t[6]) + ", st_atime=" + str(t[7]) + ", st_mtime=" + str(t[8]) +
                ", st_ctime=" + str(t[9]) + ")")


def _S_IFMT(mode):
    return mode & 0o170000


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


def _lexists(p):
    return os_exists(p) or os_islink(p)


# ── concrete paths ───────────────────────────────────────────────────────────

class _ConcretePath(PurePath):
    """PurePath subclass that can make system calls.

    Path represents a filesystem path but unlike PurePath, also offers
    methods to do system calls on path objects. Path is the class of the
    platform (PosixPath or WindowsPath).
    """
    def __init__(self, *args, **kwargs):
        if self._windows != _IS_WINDOWS:
            raise NotImplementedError("cannot instantiate " + repr(self.__class__.__name__) + " on your system")
        PurePath.__init__(self, *args)

    def _make_child_relpath(self, name):
        var path_str = self._str
        var tail = self._tail
        if tail:
            path_str = path_str + self._sep + name
        elif path_str != ".":
            path_str = path_str + name
        else:
            path_str = name
        var path = self.with_segments(path_str)
        path._str = path_str
        path._drv = self._drv
        path._root = self._root
        path._tail = tail + [name]
        return path

    @classmethod
    def cwd(cls):
        """Return a new path pointing to the current working directory."""
        return cls(os_getcwd())

    @classmethod
    def home(cls):
        """Return a new path pointing to the user's home directory (as
        returned by os.path.expanduser('~')).
        """
        return cls("~").expanduser()

    def stat(self, follow_symlinks=true):
        """
        Return the result of the stat() system call on this path, like
        os.stat() does.
        """
        if follow_symlinks:
            return _PathStatResult(os_stat(self._str))
        return _PathStatResult(os_lstat(self._str))

    def lstat(self):
        """
        Like stat(), except if the path points to a symlink, the symlink's
        status information is returned, rather than its target's.
        """
        return self.stat(false)

    def exists(self, follow_symlinks=true):
        """
        Whether this path exists.

        This method normally follows symlinks; to check whether a symlink exists,
        add the argument follow_symlinks=False.
        """
        if follow_symlinks:
            return os_exists(self._str)
        return _lexists(self._str)

    def is_dir(self):
        """
        Whether this path is a directory.
        """
        return os_isdir(self._str)

    def is_file(self):
        """
        Whether this path is a regular file (also True for symlinks pointing
        to regular files).
        """
        return os_isfile(self._str)

    def is_symlink(self):
        """
        Whether this path is a symbolic link.
        """
        return os_islink(self._str)

    def _mode_is(self, fmt):
        try:
            return _S_IFMT(os_stat(self._str)["mode"]) == fmt
        except OSError:
            return false

    def is_block_device(self):
        """
        Whether this path is a block device.
        """
        return self._mode_is(0o060000)

    def is_char_device(self):
        """
        Whether this path is a character device.
        """
        return self._mode_is(0o020000)

    def is_fifo(self):
        """
        Whether this path is a FIFO.
        """
        return self._mode_is(0o010000)

    def is_socket(self):
        """
        Whether this path is a socket.
        """
        return self._mode_is(0o140000)

    def is_junction(self):
        """
        Whether this path is a junction.
        """
        return false

    def is_mount(self):
        """
        Check if this path is a mount point
        """
        if not self.exists() or not self.is_dir():
            return false
        if self._windows:
            return self.is_absolute() and len(self._tail) == 0
        var p = os_path_realpath(self._str)
        if p == "/":
            return true
        try:
            var st = os_lstat(self._str)
            if os_islink(self._str):
                return false
            var parent = os_lstat(os_path_join(self._str, ".."))
            var dev1 = st.get("dev", 0)
            var dev2 = parent.get("dev", 0)
            if dev1 != dev2:
                return true
            return st["ino"] == parent["ino"]
        except OSError:
            return false

    def samefile(self, other_path):
        """Return whether other_path is the same or not as this file
        (as returned by os.path.samefile()).
        """
        var st = self.stat()
        var other_st = none
        if isinstance(other_path, _ConcretePath):
            other_st = other_path.stat()
        else:
            other_st = self.with_segments(other_path).stat()
        if st.st_ino != 0:
            return st.st_ino == other_st.st_ino and st.st_dev == other_st.st_dev
        return os_path_realpath(self._str).lower() == os_path_realpath(_fspath_str(other_path)).lower()

    def _listdir(self):
        var p = self._str
        if not os_isdir(p):
            if not _lexists(p):
                raise _oserror(FileNotFoundError, 2, "No such file or directory", p)
            raise _oserror(NotADirectoryError, 20, "Not a directory", p)
        return os_listdir(p)

    def iterdir(self):
        """Yield path objects of the directory contents.

        The children are yielded in arbitrary order, and the
        special entries '.' and '..' are not included.
        """
        var names = self._listdir()
        for name in names:
            yield self._make_child_relpath(name)

    def _glob_parts(self, pattern):
        var pat = self.with_segments(pattern)
        if pat._drv or pat._root:
            raise NotImplementedError("Non-relative patterns are unsupported")
        var parts = list(pat._tail)
        if not parts:
            raise ValueError("Unacceptable pattern: " + repr(pattern))
        var raw = _fspath_str(pattern)
        if raw.endswith("/") or (self._windows and raw.endswith("\\")):
            parts.append("")
        return parts

    def _glob_select(self, path, parts, i, case_sensitive, out):
        if i >= len(parts):
            out.append(path)
            return
        var part = parts[i]
        if part == "":
            if path.is_dir():
                out.append(path)
            return
        if part == "**":
            # this directory and every directory below it
            var seen = []
            var stack = [path]
            var dirs = []
            while stack:
                var d = stack.pop(0)
                dirs.append(d)
                try:
                    var names = d._listdir()
                except OSError:
                    names = []
                for nm in names:
                    var child = d._make_child_relpath(nm)
                    if os_isdir(child._str):
                        stack.append(child)
            var nxt = i + 1
            while nxt < len(parts) and parts[nxt] == "**":
                nxt = nxt + 1
            if nxt >= len(parts):
                for d2 in dirs:
                    out.append(d2)
                return
            for d3 in dirs:
                self._glob_select(d3, parts, nxt, case_sensitive, out)
            return
        if part == "..":
            self._glob_select(path._make_child_relpath(".."), parts, i + 1, case_sensitive, out)
            return
        var last = i == len(parts) - 1
        if not _fnmatch_has_magic(part):
            var child2 = path._make_child_relpath(part)
            if last:
                if _lexists(child2._str):
                    out.append(child2)
            elif os_isdir(child2._str):
                self._glob_select(child2, parts, i + 1, case_sensitive, out)
            return
        var names2 = []
        try:
            names2 = path._listdir()
        except OSError:
            return
        var pat = part if case_sensitive else part.lower()
        for name in names2:
            var cand = name if case_sensitive else name.lower()
            if _fnmatch_mod.fnmatchcase(cand, pat):
                var child3 = path._make_child_relpath(name)
                if last:
                    out.append(child3)
                elif os_isdir(child3._str):
                    self._glob_select(child3, parts, i + 1, case_sensitive, out)

    def glob(self, pattern, case_sensitive=none):
        """Iterate over this subtree and yield all existing files (of any
        kind, including directories) matching the given relative pattern.
        """
        var parts = self._glob_parts(pattern)
        if case_sensitive is none:
            case_sensitive = not self._windows
        var out = []
        self._glob_select(self, parts, 0, case_sensitive, out)
        for p in out:
            yield p

    def rglob(self, pattern, case_sensitive=none):
        """Recursively yield all existing files (of any kind, including
        directories) matching the given relative pattern, anywhere in
        this subtree.
        """
        var parts = self._glob_parts(pattern)
        if case_sensitive is none:
            case_sensitive = not self._windows
        var out = []
        self._glob_select(self, ["**"] + parts, 0, case_sensitive, out)
        for p in out:
            yield p

    def walk(self, top_down=true, on_error=none, follow_symlinks=false):
        """Walk the directory tree from this directory, similar to os.walk()."""
        var paths = [self]
        while paths:
            var path = paths.pop()
            if isinstance(path, tuple):
                yield path
                continue
            var names = none
            try:
                names = path._listdir()
            except OSError as error:
                if on_error is not none:
                    on_error(error)
                continue
            var dirnames = []
            var filenames = []
            for name in names:
                var full = os_path_join(path._str, name)
                var is_dir = os_isdir(full) and (follow_symlinks or not os_islink(full))
                if is_dir:
                    dirnames.append(name)
                else:
                    filenames.append(name)
            if top_down:
                yield (path, dirnames, filenames)
            else:
                paths.append((path, dirnames, filenames))
            var k = len(dirnames) - 1
            while k >= 0:
                paths.append(path._make_child_relpath(dirnames[k]))
                k = k - 1

    def absolute(self):
        """Return an absolute version of this path by prepending the current
        working directory. No normalization or symlink resolution is performed.

        Use resolve() to get the canonical path to a file.
        """
        if self.is_absolute():
            return self
        var cwd = os_getcwd()
        if self._windows and self._drv:
            # A drive-relative path (C:foo) resolves against that drive's cwd;
            # Nython knows only the current drive's.
            cwd = os_path_abspath(self._drv)
        return self.with_segments(cwd, self._str)

    def resolve(self, strict=false):
        """
        Make the path absolute, resolving all symlinks on the way and also
        normalizing it.
        """
        var p = self._str
        if strict and not os_exists(p):
            os_stat(p)
        var s = os_path_realpath(p)
        return self.with_segments(s)

    def owner(self):
        """
        Return the login name of the file owner.
        """
        raise NotImplementedError("Path.owner() is unsupported on this system")

    def group(self):
        """
        Return the group name of the file gid.
        """
        raise NotImplementedError("Path.group() is unsupported on this system")

    def readlink(self):
        """
        Return the path to which the symbolic link points.
        """
        return self.with_segments(os_readlink(self._str))

    def open(self, mode="r", buffering=-1, encoding=none, errors=none, newline=none):
        """
        Open the file pointed by this path and return a file object, as
        the built-in open() function does.
        """
        if "b" in mode:
            return _builtin_open(self._str, mode)
        return _builtin_open(self._str, mode, encoding if encoding is not none else "utf-8")

    def read_bytes(self):
        """
        Open the file in bytes mode, read it, and close the file.
        """
        var f = self.open("rb")
        try:
            return f.read()
        finally:
            f.close()

    def read_text(self, encoding=none, errors=none):
        """
        Open the file in text mode, read it, and close the file.
        """
        var f = self.open("r", -1, encoding, errors)
        try:
            return f.read()
        finally:
            f.close()

    def write_bytes(self, data):
        """
        Open the file in bytes mode, write to it, and close the file.
        """
        if not (isinstance(data, bytes) or isinstance(data, bytearray)):
            raise TypeError("memoryview: a bytes-like object is required, not '" + _tname(data) + "'")
        var f = self.open("wb")
        try:
            f.write(data)
        finally:
            f.close()
        return len(data)

    def write_text(self, data, encoding=none, errors=none, newline=none):
        """
        Open the file in text mode, write to it, and close the file.
        """
        if not isinstance(data, str):
            raise TypeError("data must be str, not " + _tname(data))
        var f = self.open("w", -1, encoding, errors, newline)
        try:
            f.write(data)
        finally:
            f.close()
        return len(data)

    def touch(self, mode=0o666, exist_ok=true):
        """
        Create this file with the given access mode, if it doesn't exist.
        """
        var p = self._str
        if exist_ok and _lexists(p):
            os_utime(p)
            return
        var f = _builtin_open(p, "ab" if exist_ok else "xb")
        f.close()
        if mode != 0o666:
            os_chmod(p, mode & 0o755)

    def mkdir(self, mode=0o777, parents=false, exist_ok=false):
        """
        Create a new directory at this given path.
        """
        var p = self._str
        if _mkdir_one(p):
            if mode != 0o777:
                os_chmod(p, mode & ~0o022 & 0o7777)
            return
        if _lexists(p):
            if not exist_ok or not os_isdir(p):
                raise _oserror(FileExistsError, 17, "File exists", p)
            return
        var parent = self.parent
        if not os_isdir(parent._str):
            if not parents or parent == self:
                if _lexists(parent._str):
                    raise _oserror(NotADirectoryError, 20, "Not a directory", p)
                raise _oserror(FileNotFoundError, 2, "No such file or directory", p)
            parent.mkdir(0o777, true, true)
            self.mkdir(mode, false, exist_ok)
            return
        raise _oserror(PermissionError, 13, "Permission denied", p)

    def chmod(self, mode, follow_symlinks=true):
        """
        Change the permissions of the path, like os.chmod().
        """
        os_chmod(self._str, mode)

    def lchmod(self, mode):
        """
        Like chmod(), except if the path points to a symlink, the symlink's
        permissions are changed, rather than its target's.
        """
        self.chmod(mode, false)

    def unlink(self, missing_ok=false):
        """
        Remove this file or link.
        If the path is a directory, use rmdir() instead.
        """
        var p = self._str
        if not _lexists(p):
            if missing_ok:
                return
            raise _oserror(FileNotFoundError, 2, "No such file or directory", p)
        os_unlink(p)

    def rmdir(self):
        """
        Remove this directory.  The directory must be empty.
        """
        os_rmdir(self._str)

    def _rename_error(self, src, dst):
        if not _lexists(src):
            return _oserror(FileNotFoundError, 2, "No such file or directory", src, dst)
        if os_isdir(dst) and not os_isdir(src):
            return _oserror(IsADirectoryError, 21, "Is a directory", src, dst)
        if os_isdir(src) and _lexists(dst) and not os_isdir(dst):
            return _oserror(NotADirectoryError, 20, "Not a directory", src, dst)
        if os_isdir(src) and os_isdir(dst):
            return _oserror(OSError, 39, "Directory not empty", src, dst)
        var parent = os_path_split(dst)[0]
        if parent and not os_isdir(parent):
            return _oserror(FileNotFoundError, 2, "No such file or directory", src, dst)
        if self._windows and _lexists(dst):
            return _oserror(FileExistsError, 17, "File exists", src, dst)
        return _oserror(OSError, 18, "Invalid cross-device link", src, dst)

    def rename(self, target):
        """
        Rename this path to the target path.

        The target path may be absolute or relative. Relative paths are
        interpreted relative to the current working directory, *not* the
        directory of the Path object.

        Returns the new Path instance pointing to the target path.
        """
        var dst = _fspath_str(target)
        if not os_rename(self._str, dst):
            raise self._rename_error(self._str, dst)
        return self.with_segments(target)

    def replace(self, target):
        """
        Rename this path to the target path, overwriting if that path exists.

        Returns the new Path instance pointing to the target path.
        """
        var dst = _fspath_str(target)
        if self._windows and os_isfile(dst) and _lexists(self._str):
            os_unlink(dst)
        if not os_rename(self._str, dst):
            raise self._rename_error(self._str, dst)
        return self.with_segments(target)

    def symlink_to(self, target, target_is_directory=false):
        """
        Make this path a symlink pointing to the target path.
        Note the order of arguments (link, target) is the reverse of os.symlink.
        """
        os_symlink(_fspath_str(target), self._str)

    def hardlink_to(self, target):
        """
        Make this path a hard link pointing to the same file as *target*.
        """
        raise NotImplementedError("os.link() not available on this system")

    def expanduser(self):
        """ Return a new path with expanded ~ and ~user constructs
        (as returned by os.path.expanduser)
        """
        if not (self._drv or self._root) and self._tail and self._tail[0][:1] == "~":
            var homedir = os_path_expanduser(self._tail[0])
            if homedir[:1] == "~":
                raise RuntimeError("Could not determine home directory.")
            var r = self._parse_path(homedir)
            return self._from_parsed_parts(r[0], r[1], r[2] + self._tail[1:])
        return self


class PosixPath(_ConcretePath, PurePosixPath):
    """Path subclass for non-Windows systems.

    On a POSIX system, instantiating a Path should return this object.
    """
    _windows = false


class WindowsPath(_ConcretePath, PureWindowsPath):
    """Path subclass for Windows systems.

    On a Windows system, instantiating a Path should return this object.
    """
    _windows = true


# Path(...) is the platform's concrete class (no __new__ in Nython yet).
Path = WindowsPath if _IS_WINDOWS else PosixPath


def _fnmatch_has_magic(s):
    for ch in s:
        if ch == "*" or ch == "?" or ch == "[":
            return true
    return false
