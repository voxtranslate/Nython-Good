# nython: module    (import it by name: it runs in a module scope of its own)
# lib/glob.ny - Python's glob: pathname pattern expansion.
#
#     glob(pathname, *, root_dir=None, dir_fd=None, recursive=False,
#          include_hidden=False)        -> list of paths
#     iglob(...)                        -> the same, lazily (a generator)
#     escape(pathname)                  wildcards made literal ("[*]")
#     has_magic(s)                      whether s holds * ? or [
#     glob0(dirname, basename), glob1(dirname, pattern)   (undocumented, kept)
#
# CPython's algorithm, step for step: the directory part is expanded first
# (only directories), each component is matched with fnmatch (hidden names
# need a pattern starting with "." unless include_hidden), "**" with
# recursive=True matches any number of directories (the empty one first),
# a pattern without wildcards yields itself when it exists (a broken
# symbolic link included), and a trailing separator matches directories
# only. Results come in directory order, as os.scandir lists them - not
# sorted, exactly as CPython (sort them when order matters).
# Paths are str (or path-like for root_dir); bytes patterns are not
# supported. dir_fd is accepted and must be None (Nython has no directory
# file descriptors).

import os
import fnmatch as _fnmatch_mod

__all__ = ["escape", "glob", "iglob", "has_magic"]

_WINDOWS = os_platform() == "windows"


def _fspath(p):
    if isinstance(p, str):
        return p
    if hasattr(p, "__fspath__"):
        return p.__fspath__()
    raise TypeError("expected str, bytes or os.PathLike object, not " + type(p).__name__)


def _isdir(p):
    return os_isdir(p)


def _lexists(p):
    return os_exists(p) or os_islink(p)


def _ospath_join(a, b):
    return os_path_join(a, b)


def _join(dirname, basename):
    # It is common if dirname or basename is empty
    if not dirname or not basename:
        return dirname or basename
    return os_path_join(dirname, basename)


def _split(p):
    var hs = os_path_split(p)
    return [hs[0], hs[1]]


def has_magic(s):
    for ch in s:
        if ch == "*" or ch == "?" or ch == "[":
            return true
    return false


def _ishidden(path):
    return path[0] == "."


def _isrecursive(pattern):
    return pattern == "**"


def _iterdir(dirname, dironly):
    var arg = dirname if dirname else "."
    if not os_isdir(arg):
        return []
    var names = os_listdir(arg)
    if not dironly:
        return names
    var out = []
    for n in names:
        if os_isdir(os_path_join(arg, n)):
            out.append(n)
    return out


def _glob1(dirname, pattern, dir_fd, dironly, include_hidden=false):
    var names = _iterdir(dirname, dironly)
    if include_hidden or not _ishidden(pattern):
        var keep = []
        for x in names:
            if include_hidden or not _ishidden(x):
                keep.append(x)
        names = keep
    return _fnmatch_mod.filter(names, pattern)


def _glob0(dirname, basename, dir_fd, dironly, include_hidden=false):
    if basename:
        if _lexists(_join(dirname, basename)):
            return [basename]
    else:
        # os.path.split() returns an empty basename for paths ending with a
        # directory separator: 'q*x/' should match only directories.
        if _isdir(dirname):
            return [basename]
    return []


def glob0(dirname, pattern):
    return _glob0(dirname, pattern, none, false)


def glob1(dirname, pattern):
    return _glob1(dirname, pattern, none, false)


def _rlistdir(dirname, dir_fd, dironly, include_hidden=false):
    var names = _iterdir(dirname, dironly)
    for x in names:
        if include_hidden or not _ishidden(x):
            yield x
            var path = _join(dirname, x) if dirname else x
            for y in _rlistdir(path, dir_fd, dironly, include_hidden):
                yield _join(x, y)


def _glob2(dirname, pattern, dir_fd, dironly, include_hidden=false):
    if not dirname or _isdir(dirname):
        yield pattern[:0]
    yield from _rlistdir(dirname, dir_fd, dironly, include_hidden)


def _iglob(pathname, root_dir, dir_fd, recursive, dironly, include_hidden=false):
    var hs = _split(pathname)
    var dirname = hs[0]
    var basename = hs[1]
    if not has_magic(pathname):
        if basename:
            if _lexists(_join(root_dir, pathname)):
                yield pathname
        else:
            # Patterns ending with a slash should match only directories
            if _isdir(_join(root_dir, dirname)):
                yield pathname
        return
    if not dirname:
        if recursive and _isrecursive(basename):
            yield from _glob2(root_dir, basename, dir_fd, dironly, include_hidden)
        else:
            yield from _glob1(root_dir, basename, dir_fd, dironly, include_hidden)
        return
    # os.path.split() returns the argument itself as a dirname if it is a
    # drive or UNC path: no infinite recursion on magic in r'\\?\C:'.
    var dirs = [dirname]
    if dirname != pathname and has_magic(dirname):
        dirs = _iglob(dirname, root_dir, dir_fd, recursive, true, include_hidden)
    var mode = 0
    if has_magic(basename):
        if recursive and _isrecursive(basename):
            mode = 2
        else:
            mode = 1
    for d in dirs:
        var names = none
        if mode == 2:
            names = _glob2(_join(root_dir, d), basename, dir_fd, dironly, include_hidden)
        elif mode == 1:
            names = _glob1(_join(root_dir, d), basename, dir_fd, dironly, include_hidden)
        else:
            names = _glob0(_join(root_dir, d), basename, dir_fd, dironly, include_hidden)
        for name in names:
            yield os_path_join(d, name)


def iglob(pathname, root_dir=none, dir_fd=none, recursive=false, include_hidden=false):
    """Return an iterator which yields the paths matching a pathname pattern."""
    pathname = _fspath(pathname)
    if dir_fd is not none:
        raise NotImplementedError("glob: dir_fd is not supported (no directory file descriptors)")
    if root_dir is not none:
        root_dir = _fspath(root_dir)
    else:
        root_dir = ""
    var it = _iglob(pathname, root_dir, dir_fd, recursive, false, include_hidden)
    if not pathname or (recursive and _isrecursive(pathname[:2])):
        return _skip_empty_first(it)
    return it


def _skip_empty_first(it):
    var first = true
    for s in it:
        if first:
            first = false
            if not s:
                continue
        yield s


def glob(pathname, root_dir=none, dir_fd=none, recursive=false, include_hidden=false):
    """Return a list of paths matching a pathname pattern."""
    return list(iglob(pathname, root_dir, dir_fd, recursive, include_hidden))


def _splitdrive(p):
    if _WINDOWS and len(p) >= 2:
        if p[1] == ":":
            return [p[:2], p[2:]]
        var norm = p.replace("/", "\\")
        if norm[:2] == "\\\\" and norm[2:3] != "\\":
            var index = norm.find("\\", 2)
            if index == -1:
                return [p, ""]
            var index2 = norm.find("\\", index + 1)
            if index2 == -1:
                index2 = len(p)
            return [p[:index2], p[index2:]]
    return ["", p]


def escape(pathname):
    """Escape all special characters."""
    pathname = _fspath(pathname)
    var dp = _splitdrive(pathname)
    var out = []
    for ch in dp[1]:
        if ch == "*" or ch == "?" or ch == "[":
            out.append("[" + ch + "]")
        else:
            out.append(ch)
    return dp[0] + "".join(out)
