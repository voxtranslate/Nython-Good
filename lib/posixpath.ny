# nython: module    (import it by name: it runs in a module scope of its own)
# lib/posixpath.ny - Python's posixpath (round 80): operations on POSIX path
# names, CPython 3.11's Lib/posixpath.py, importable on every platform (on
# Windows too, as CPython's: it only computes, except where it asks the
# file system).
#
#     import posixpath
#     posixpath.join("a", "b/", "c")       # 'a/b/c'
#     posixpath.normpath("//a/./b/../c")   # '//a/c'
#
# normcase, isabs, join, splitdrive, split, splitext, basename, dirname,
# commonprefix, commonpath, getsize, getmtime, getatime, getctime, islink,
# exists, lexists, isdir, isfile, ismount, isjunction (3.12, always False
# here), splitroot (3.12), expanduser (HOME, then pwd), expandvars, normpath
# (POSIX's one or two leading slashes), abspath, realpath(strict=, and
# ALLOW_MISSING), relpath, samefile, sameopenfile, samestat; curdir, pardir,
# sep, pathsep, defpath, altsep, extsep, devnull, supports_unicode_filenames.
# str, bytes and os.PathLike arguments, with CPython's TypeErrors for a mix.
#
# os.path is the native namespace (src/builtins/os.cpp), which gives the
# same results on POSIX paths, except that its split/basename/dirname also
# split at "\" (as Nython's os.path always has).
#
# Everything the module has is here.

curdir = '.'
pardir = '..'
extsep = '.'
sep = '/'
pathsep = ':'
defpath = '/bin:/usr/bin'
altsep = None
devnull = '/dev/null'

import os
import sys
import stat
import genericpath
from genericpath import *

__all__ = ["normcase", "isabs", "join", "splitdrive", "split", "splitext",
           "basename", "dirname", "commonprefix", "getsize", "getmtime",
           "getatime", "getctime", "islink", "exists", "lexists", "isdir", "isfile",
           "ismount", "expanduser", "expandvars", "normpath", "abspath",
           "samefile", "sameopenfile", "samestat",
           "curdir", "pardir", "sep", "pathsep", "defpath", "altsep", "extsep",
           "devnull", "realpath", "supports_unicode_filenames", "relpath",
           "commonpath", "ALLOW_MISSING", "isjunction", "splitroot"]


def _get_sep(path):
    if isinstance(path, bytes):
        return b'/'
    else:
        return '/'


def normcase(s):
    """Normalize case of pathname.  Has no effect under Posix"""
    return os.fspath(s)


def isabs(s):
    """Test whether a path is absolute"""
    s = os.fspath(s)
    var sp = _get_sep(s)
    return s.startswith(sp)


def join(a, *p):
    """Join two or more pathname components, inserting '/' as needed.
    If any component is an absolute path, all previous path components
    will be discarded.  An empty last part will result in a path that
    ends with a separator."""
    a = os.fspath(a)
    var sp = _get_sep(a)
    var path = a
    try:
        if not p:
            path[:0] + sp  #23780: Ensure compatible data type even if p is null.
        for b in map(os.fspath, p):
            if b.startswith(sp):
                path = b
            elif not path or path.endswith(sp):
                path += b
            else:
                path += sp + b
    except (TypeError, AttributeError):
        genericpath._check_arg_types('join', a, *p)
        raise
    return path


def split(p):
    """Split a pathname.  Returns tuple "(head, tail)" where "tail" is
    everything after the final slash.  Either part may be empty."""
    p = os.fspath(p)
    var sp = _get_sep(p)
    var i = p.rfind(sp) + 1
    var head = p[:i]
    var tail = p[i:]
    if head and head != sp * len(head):
        head = head.rstrip(sp)
    return head, tail


def splitext(p):
    p = os.fspath(p)
    if isinstance(p, bytes):
        return genericpath._splitext(p, b'/', None, b'.')
    return genericpath._splitext(p, '/', None, '.')


def splitdrive(p):
    """Split a pathname into drive and path. On Posix, drive is always
    empty."""
    p = os.fspath(p)
    return p[:0], p


def splitroot(p):
    """Split a pathname into drive, root and tail (Python 3.12). On Posix,
    drive is always empty; the root may be empty, a single slash, or two
    slashes. The tail contains anything after the root."""
    p = os.fspath(p)
    var sp = _get_sep(p)
    var empty = p[:0]
    if p[:1] != sp:
        # Relative path, e.g.: 'foo'
        return empty, empty, p
    elif p[1:2] != sp or p[2:3] == sp:
        # Absolute path, e.g.: '/foo', '///foo', '////foo', etc.
        return empty, sp, p[1:]
    else:
        # Precisely two leading slashes, e.g.: '//foo'.
        return empty, p[:2], p[2:]


def basename(p):
    """Returns the final component of a pathname"""
    p = os.fspath(p)
    var sp = _get_sep(p)
    var i = p.rfind(sp) + 1
    return p[i:]


def dirname(p):
    """Returns the directory component of a pathname"""
    p = os.fspath(p)
    var sp = _get_sep(p)
    var i = p.rfind(sp) + 1
    var head = p[:i]
    if head and head != sp * len(head):
        head = head.rstrip(sp)
    return head


def isjunction(path):
    """Test whether a path is a junction
    Junctions are not supported on the current platform"""
    os.fspath(path)
    return False


def islink(path):
    """Test whether a path is a symbolic link"""
    var st = None
    try:
        st = os.lstat(path)
    except (OSError, ValueError, AttributeError):
        return False
    return stat.S_ISLNK(st.st_mode)


def lexists(path):
    """Test whether a path exists.  Returns True for broken symbolic links"""
    try:
        os.lstat(path)
    except (OSError, ValueError):
        return False
    return True


def ismount(path):
    """Test whether a path is a mount point"""
    var s1 = None
    try:
        s1 = os.lstat(path)
    except (OSError, ValueError):
        # It doesn't exist -- so not a mount point. :-)
        return False
    # A symlink can never be a mount point
    if stat.S_ISLNK(s1.st_mode):
        return False

    path = os.fspath(path)
    var parent = None
    if isinstance(path, bytes):
        parent = join(path, b'..')
    else:
        parent = join(path, '..')
    parent = realpath(parent)
    var s2 = None
    try:
        s2 = os.lstat(parent)
    except (OSError, ValueError):
        return False

    if s1.st_dev != s2.st_dev:
        return True     # path/.. on a different device as path
    if s1.st_ino == s2.st_ino:
        return True     # path/.. is the same i-node as path
    return False


def expanduser(path):
    """Expand ~ and ~user constructions.  If user or $HOME is unknown,
    do nothing."""
    path = os.fspath(path)
    var tilde = b'~' if isinstance(path, bytes) else '~'
    if not path.startswith(tilde):
        return path
    var sp = _get_sep(path)
    var i = path.find(sp, 1)
    if i < 0:
        i = len(path)
    var userhome = None
    if i == 1:
        if 'HOME' not in os.environ:
            try:
                import pwd
            except ImportError:
                # pwd module unavailable, return path unchanged
                return path
            try:
                userhome = pwd.getpwuid(os.getuid()).pw_dir
            except KeyError:
                return path
        else:
            userhome = os.environ['HOME']
    else:
        try:
            import pwd
        except ImportError:
            return path
        var name = path[1:i]
        if isinstance(name, bytes):
            name = str(name, 'ASCII')
        var pwent = None
        try:
            pwent = pwd.getpwnam(name)
        except KeyError:
            return path
        userhome = pwent.pw_dir
    var root = '/'
    if isinstance(path, bytes):
        userhome = os.fsencode(userhome)
        root = b'/'
    userhome = userhome.rstrip(root)
    return (userhome + path[i:]) or root


_varpattern = r'\$(\w+|\{[^}]*\}?)'
_varsub = [None, None]


def expandvars(path):
    path = os.fspath(path)
    var subf = None
    var start = None
    var end = None
    var environ = None
    if isinstance(path, bytes):
        if b'$' not in path:
            return path
        if not _varsub[1]:
            import re
            _varsub[1] = re.compile(_varpattern.encode(), re.ASCII).sub
        subf = _varsub[1]
        start = b'{'
        end = b'}'
        environ = getattr(os, 'environb', None)
    else:
        if '$' not in path:
            return path
        if not _varsub[0]:
            import re
            _varsub[0] = re.compile(_varpattern, re.ASCII).sub
        subf = _varsub[0]
        start = '{'
        end = '}'
        environ = os.environ

    def repl(m):
        var name = m[1]
        if name.startswith(start):
            if not name.endswith(end):
                return m[0]
            name = name[1:-1]
        try:
            if environ is None:
                return os.fsencode(os.environ[os.fsdecode(name)])
            return environ[name]
        except KeyError:
            return m[0]

    return subf(repl, path)


# (a string literal holding "$" "{" would be Nython interpolation)
expandvars.__doc__ = "Expand shell variables of form $var and $" + "{var}.  Unknown variables\n    are left unchanged."


def normpath(path):
    """Normalize path, eliminating double slashes, etc."""
    path = os.fspath(path)
    var sp = '/'
    var empty = ''
    var dot = '.'
    var dotdot = '..'
    if isinstance(path, bytes):
        sp = b'/'
        empty = b''
        dot = b'.'
        dotdot = b'..'
    if path == empty:
        return dot
    var initial_slashes = 1 if path.startswith(sp) else 0
    # POSIX allows one or two initial slashes, but treats three or more
    # as single slash.
    if initial_slashes and path.startswith(sp * 2) and not path.startswith(sp * 3):
        initial_slashes = 2
    var comps = path.split(sp)
    var new_comps = []
    for comp in comps:
        if comp == empty or comp == dot:
            continue
        if (comp != dotdot or (not initial_slashes and not new_comps) or
                (new_comps and new_comps[-1] == dotdot)):
            new_comps.append(comp)
        elif new_comps:
            new_comps.pop()
    path = sp.join(new_comps)
    if initial_slashes:
        path = sp * initial_slashes + path
    return path or dot


def abspath(path):
    """Return an absolute path."""
    path = os.fspath(path)
    if not isabs(path):
        var cwd = os.getcwdb() if isinstance(path, bytes) else os.getcwd()
        path = join(cwd, path)
    return normpath(path)


def realpath(filename, *, strict=False):
    """Return the canonical path of the specified filename, eliminating any
symbolic links encountered in the path."""
    filename = os.fspath(filename)
    var r = _joinrealpath(filename[:0], filename, strict, {})
    return abspath(r[0])


# Join two paths, normalizing and eliminating any symbolic links
# encountered in the second path.
def _joinrealpath(path, rest, strict, seen):
    var sp = '/'
    var cur = '.'
    var par = '..'
    if isinstance(path, bytes):
        sp = b'/'
        cur = b'.'
        par = b'..'
    var ignored_error = OSError
    if strict is ALLOW_MISSING:
        ignored_error = FileNotFoundError
    elif strict:
        ignored_error = ()

    if isabs(rest):
        rest = rest[1:]
        path = sp

    while rest:
        var parts = rest.partition(sp)
        var name = parts[0]
        rest = parts[2]
        if not name or name == cur:
            # current dir
            continue
        if name == par:
            # parent dir
            if path:
                var hd = split(path)
                path = hd[0]
                name = hd[1]
                if name == par:
                    path = join(path, par, par)
            else:
                path = par
            continue
        var newpath = join(path, name)
        var is_link = False
        try:
            var st = os.lstat(newpath)
            is_link = stat.S_ISLNK(st.st_mode)
        except ignored_error:
            is_link = False
        if not is_link:
            path = newpath
            continue
        # Resolve the symbolic link
        if newpath in seen:
            # Already seen this path
            path = seen[newpath]
            if path is not None:
                # use cached value
                continue
            # The symlink is not resolved, so we must have a symlink loop.
            if strict:
                # Raise OSError(errno.ELOOP)
                os.stat(newpath)
            else:
                # Return already resolved part + rest of the path unchanged.
                return join(newpath, rest), False
        seen[newpath] = None  # not resolved symlink
        var r = _joinrealpath(path, os.readlink(newpath), strict, seen)
        path = r[0]
        if not r[1]:
            return join(path, rest), False
        seen[newpath] = path  # resolved symlink

    return path, True


supports_unicode_filenames = (sys.platform == 'darwin')


def relpath(path, start=None):
    """Return a relative version of a path"""
    if not path:
        raise ValueError("no path specified")

    path = os.fspath(path)
    var cur = '.'
    var sp = '/'
    var par = '..'
    if isinstance(path, bytes):
        cur = b'.'
        sp = b'/'
        par = b'..'

    if start is None:
        start = cur
    else:
        start = os.fspath(start)

    try:
        var start_list = [x for x in abspath(start).split(sp) if x]
        var path_list = [x for x in abspath(path).split(sp) if x]
        # Work out how much of the filepath is shared by start and path.
        var i = len(commonprefix([start_list, path_list]))

        var rel_list = [par] * (len(start_list) - i) + path_list[i:]
        if not rel_list:
            return cur
        return join(*rel_list)
    except (TypeError, AttributeError, DeprecationWarning):
        genericpath._check_arg_types('relpath', path, start)
        raise


def commonpath(paths):
    """Given a sequence of path names, returns the longest common sub-path."""
    paths = tuple(map(os.fspath, paths))
    if not paths:
        raise ValueError('commonpath() arg is an empty sequence')
    var sp = '/'
    var cur = '.'
    if isinstance(paths[0], bytes):
        sp = b'/'
        cur = b'.'

    try:
        var split_paths = [path.split(sp) for path in paths]
        var abss = set(p[:1] == sp for p in paths)
        if len(abss) != 1:
            raise ValueError("Can't mix absolute and relative paths") from None
        var is_abs = list(abss)[0]

        split_paths = [[c for c in s if c and c != cur] for s in split_paths]
        var s1 = min(split_paths)
        var s2 = max(split_paths)
        var common = s1
        var i = 0
        for c in s1:
            if c != s2[i]:
                common = s1[:i]
                break
            i += 1

        var prefix = sp if is_abs else sp[:0]
        return prefix + sp.join(common)
    except (TypeError, AttributeError):
        genericpath._check_arg_types('commonpath', *paths)
        raise
