# nython: module    (import it by name: it runs in a module scope of its own)
# lib/ntpath.ny - Python's ntpath (round 80): operations on Windows path
# names, CPython 3.11's Lib/ntpath.py, importable on every platform (it
# computes the same results on Linux, as CPython's does).
#
#     import ntpath
#     ntpath.join("C:\\a", "b", "/c")       # 'C:/c'
#     ntpath.splitdrive("//srv/share/x")    # ('//srv/share', '/x')
#     ntpath.normpath("A/foo/../B")         # 'A\\B'
#
# normcase, isabs, join, splitdrive (drive letters, UNC shares, \\?\ and
# \\.\ device paths), splitroot (3.12), split, splitext, basename, dirname,
# commonprefix, commonpath, getsize, getmtime, getatime, getctime, islink,
# exists, lexists, isdir, isfile, isjunction (3.12), ismount (lexically:
# drive roots and share roots), expanduser (USERPROFILE, HOMEDRIVE +
# HOMEPATH), expandvars ($var, ${var}, %var%, '...' left alone), normpath,
# abspath, realpath, relpath, samefile, sameopenfile, samestat; curdir,
# pardir, sep, pathsep, defpath, altsep, extsep, devnull,
# supports_unicode_filenames. str, bytes and os.PathLike arguments.
#
# Off Windows abspath joins the working directory and realpath is abspath,
# as CPython's ntpath there. On Windows (Nython built with MinGW) abspath
# and realpath use the native os.path ones (GetFullPathNameW /
# GetFinalPathNameByHandleW); isjunction is always False and ismount does
# not ask the volume manager about folders a volume is mounted on.

curdir = '.'
pardir = '..'
extsep = '.'
sep = '\\'
pathsep = ';'
altsep = '/'
defpath = '.;C:\\bin'
devnull = 'nul'

import os
import sys
import stat
import genericpath
from genericpath import *

__all__ = ["normcase", "isabs", "join", "splitdrive", "split", "splitext",
           "basename", "dirname", "commonprefix", "getsize", "getmtime",
           "getatime", "getctime", "islink", "exists", "lexists", "isdir", "isfile",
           "ismount", "expanduser", "expandvars", "normpath", "abspath",
           "curdir", "pardir", "sep", "pathsep", "defpath", "altsep",
           "extsep", "devnull", "realpath", "supports_unicode_filenames", "relpath",
           "samefile", "sameopenfile", "samestat", "commonpath",
           "ALLOW_MISSING", "isjunction", "splitroot"]

_ON_WINDOWS = os.name == "nt"


def _get_bothseps(path):
    if isinstance(path, bytes):
        return b'\\/'
    else:
        return '\\/'


def normcase(s):
    """Normalize case of pathname.

    Makes all characters lowercase and all slashes into backslashes.
    """
    s = os.fspath(s)
    if isinstance(s, bytes):
        return os.fsencode(os.fsdecode(s).replace('/', '\\').lower())
    return s.replace('/', '\\').lower()


def isabs(s):
    """Test whether a path is absolute"""
    s = os.fspath(s)
    var sp = '\\'
    var asp = '/'
    var colon_sep = ':\\'
    if isinstance(s, bytes):
        sp = b'\\'
        asp = b'/'
        colon_sep = b':\\'
    s = s[:3].replace(asp, sp)
    # Absolute: UNC, device, and paths with a drive and root.
    # LEGACY BUG: isabs("/x") should be false since the path has no drive.
    if s.startswith(sp) or s.startswith(colon_sep, 1):
        return True
    return False


def join(path, *paths):
    path = os.fspath(path)
    var sp = '\\'
    var seps = '\\/'
    var colon = ':'
    if isinstance(path, bytes):
        sp = b'\\'
        seps = b'\\/'
        colon = b':'
    try:
        if not paths:
            path[:0] + sp  #23780: Ensure compatible data type even if p is null.
        var rd = splitdrive(path)
        var result_drive = rd[0]
        var result_path = rd[1]
        for p in map(os.fspath, paths):
            var pd = splitdrive(p)
            var p_drive = pd[0]
            var p_path = pd[1]
            if p_path and p_path[:1] in seps:
                # Second path is absolute
                if p_drive or not result_drive:
                    result_drive = p_drive
                result_path = p_path
                continue
            elif p_drive and p_drive != result_drive:
                if p_drive.lower() != result_drive.lower():
                    # Different drives => ignore the first path entirely
                    result_drive = p_drive
                    result_path = p_path
                    continue
                # Same drive in different case
                result_drive = p_drive
            # Second path is relative to the first
            if result_path and result_path[-1:] not in seps:
                result_path = result_path + sp
            result_path = result_path + p_path
        ## add separator between UNC and non-absolute path
        if (result_path and result_path[:1] not in seps and
                result_drive and result_drive[-1:] != colon):
            return result_drive + sp + result_path
        return result_drive + result_path
    except (TypeError, AttributeError):
        genericpath._check_arg_types('join', path, *paths)
        raise


def splitdrive(p):
    """Split a pathname into drive/UNC sharepoint and relative path specifiers.
    Returns a 2-tuple (drive_or_unc, path); either part may be empty.

    If you assign
        result = splitdrive(p)
    It is always true that:
        result[0] + result[1] == p

    If the path contained a drive letter, drive_or_unc will contain everything
    up to and including the colon.  e.g. splitdrive("c:/dir") returns ("c:", "/dir")

    If the path contained a UNC path, the drive_or_unc will contain the host name
    and share up to but not including the fourth directory separator character.
    e.g. splitdrive("//host/computer/dir") returns ("//host/computer", "/dir")

    Paths cannot contain both a drive letter and a UNC path.

    """
    p = os.fspath(p)
    if len(p) >= 2:
        var sp = '\\'
        var asp = '/'
        var colon = ':'
        var unc_prefix = '\\\\?\\UNC\\'
        if isinstance(p, bytes):
            sp = b'\\'
            asp = b'/'
            colon = b':'
            unc_prefix = b'\\\\?\\UNC\\'
        var normp = p.replace(asp, sp)
        if normp[0:2] == sp * 2:
            # UNC drives, e.g. \\server\share or \\?\UNC\server\share
            # Device drives, e.g. \\.\device or \\?\device
            var start = 8 if normp[:8].upper() == unc_prefix else 2
            var index = normp.find(sp, start)
            if index == -1:
                return p, p[:0]
            var index2 = normp.find(sp, index + 1)
            if index2 == -1:
                return p, p[:0]
            return p[:index2], p[index2:]
        if normp[1:2] == colon:
            # Drive-letter drives, e.g. X:
            return p[:2], p[2:]
    return p[:0], p


def splitroot(p):
    """Split a pathname into drive, root and tail (Python 3.12).

    The drive is defined exactly as in splitdrive(). On Windows, the root
    may be a single path separator or an empty string. The tail contains
    anything after the root."""
    p = os.fspath(p)
    var sp = '\\'
    var asp = '/'
    var colon = ':'
    var unc_prefix = '\\\\?\\UNC\\'
    var empty = ''
    if isinstance(p, bytes):
        sp = b'\\'
        asp = b'/'
        colon = b':'
        unc_prefix = b'\\\\?\\UNC\\'
        empty = b''
    var normp = p.replace(asp, sp)
    if normp[:1] == sp:
        if normp[1:2] == sp:
            # UNC drives, e.g. \\server\share or \\?\UNC\server\share
            # Device drives, e.g. \\.\device or \\?\device
            var start = 8 if normp[:8].upper() == unc_prefix else 2
            var index = normp.find(sp, start)
            if index == -1:
                return p, empty, empty
            var index2 = normp.find(sp, index + 1)
            if index2 == -1:
                return p, empty, empty
            return p[:index2], p[index2:index2 + 1], p[index2 + 1:]
        else:
            # Relative path with root, e.g. \Windows
            return empty, p[:1], p[1:]
    elif normp[1:2] == colon:
        if normp[2:3] == sp:
            # Absolute drive-letter path, e.g. X:\Windows
            return p[:2], p[2:3], p[3:]
        else:
            # Relative path with drive, e.g. X:Windows
            return p[:2], empty, p[2:]
    else:
        # Relative path, e.g. Windows
        return empty, empty, p


def split(p):
    """Split a pathname.

    Return tuple (head, tail) where tail is everything after the final slash.
    Either part may be empty."""
    p = os.fspath(p)
    var seps = _get_bothseps(p)
    var dp = splitdrive(p)
    var d = dp[0]
    p = dp[1]
    # set i to index beyond p's last slash
    var i = len(p)
    while i and p[i - 1:i] not in seps:
        i -= 1
    var head = p[:i]
    var tail = p[i:]  # now tail has no slashes
    # remove trailing slashes from head, unless it's all slashes
    head = head.rstrip(seps) or head
    return d + head, tail


def splitext(p):
    p = os.fspath(p)
    if isinstance(p, bytes):
        return genericpath._splitext(p, b'\\', b'/', b'.')
    else:
        return genericpath._splitext(p, '\\', '/', '.')


def basename(p):
    """Returns the final component of a pathname"""
    return split(p)[1]


def dirname(p):
    """Returns the directory component of a pathname"""
    return split(p)[0]


def isjunction(path):
    """Test whether a path is a junction"""
    os.fspath(path)
    return False


def islink(path):
    """Test whether a path is a symbolic link.
    This will always return false for Windows prior to 6.0.
    """
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
    """Test whether a path is a mount point (a drive root, the root of a
    share, or a mounted volume)"""
    path = os.fspath(path)
    var seps = _get_bothseps(path)
    path = abspath(path)
    var rr = splitdrive(path)
    var root = rr[0]
    var rest = rr[1]
    if root and root[:1] in seps:
        return (not rest) or (rest in seps)
    if rest and rest in seps:
        return True
    return False


def expanduser(path):
    """Expand ~ and ~user constructs.

    If user or $HOME is unknown, do nothing."""
    path = os.fspath(path)
    var tilde = b'~' if isinstance(path, bytes) else '~'
    if not path.startswith(tilde):
        return path
    var i = 1
    var n = len(path)
    while i < n and path[i:i + 1] not in _get_bothseps(path):
        i += 1

    var userhome = None
    if 'USERPROFILE' in os.environ:
        userhome = os.environ['USERPROFILE']
    elif not 'HOMEPATH' in os.environ:
        return path
    else:
        var drive = os.environ.get('HOMEDRIVE', '')
        userhome = join(drive, os.environ['HOMEPATH'])

    if i != 1:  #~user
        var target_user = path[1:i]
        if isinstance(target_user, bytes):
            target_user = os.fsdecode(target_user)
        var current_user = os.environ.get('USERNAME')

        if target_user != current_user:
            # Try to guess user home directory.  By default all user
            # profile directories are located in the same place and are
            # named by corresponding usernames.  If userhome isn't a
            # normal profile directory, this guess is likely wrong,
            # so we bail out.
            if current_user != basename(userhome):
                return path
            userhome = join(dirname(userhome), target_user)

    if isinstance(path, bytes):
        userhome = os.fsencode(userhome)

    return userhome + path[i:]


# Expand paths containing shell variable substitutions.
# The following rules apply:
#       - no expansion within single quotes
#       - '$$' is translated into '$'
#       - '%%' is translated into '%' if '%%' are not seen in %var1%%var2%
#       - ${varname} is accepted.
#       - $varname is accepted.
#       - %varname% is accepted.
#       - varnames can be made out of letters, digits and the characters '_-'
#         (though is not verified in the ${varname} and %varname% cases)
_varpattern = r"'[^']*'?|%(%|[^%]*%?)|\$(\$|[-\w]+|\{[^}]*\}?)"
_varsub = [None, None]


def expandvars(path):
    path = os.fspath(path)
    var subf = None
    var percent = '%'
    var brace = '{'
    var rbrace = '}'
    var dollar = '$'
    var environ = None
    if isinstance(path, bytes):
        if b'$' not in path and b'%' not in path:
            return path
        if not _varsub[1]:
            import re
            _varsub[1] = re.compile(_varpattern.encode(), re.ASCII).sub
        subf = _varsub[1]
        percent = b'%'
        brace = b'{'
        rbrace = b'}'
        dollar = b'$'
        environ = getattr(os, 'environb', None)
    else:
        if '$' not in path and '%' not in path:
            return path
        if not _varsub[0]:
            import re
            _varsub[0] = re.compile(_varpattern, re.ASCII).sub
        subf = _varsub[0]
        environ = os.environ

    def repl(m):
        var lastindex = m.lastindex
        if lastindex is None:
            return m[0]
        var name = m[lastindex]
        if lastindex == 1:
            if name == percent:
                return name
            if not name.endswith(percent):
                return m[0]
            name = name[:-1]
        else:
            if name == dollar:
                return name
            if name.startswith(brace):
                if not name.endswith(rbrace):
                    return m[0]
                name = name[1:-1]

        try:
            if environ is None:
                return os.fsencode(os.environ[os.fsdecode(name)])
            else:
                return environ[name]
        except KeyError:
            return m[0]

    return subf(repl, path)


# (a string literal holding "$" "{" would be Nython interpolation)
expandvars.__doc__ = "Expand shell variables of the forms $var, $" + "{var} and %var%.\n\n    Unknown variables are left unchanged."


def normpath(path):
    """Normalize path, eliminating double slashes, etc."""
    path = os.fspath(path)
    var sp = '\\'
    var asp = '/'
    var cur = '.'
    var par = '..'
    if isinstance(path, bytes):
        sp = b'\\'
        asp = b'/'
        cur = b'.'
        par = b'..'
    path = path.replace(asp, sp)
    var pp = splitdrive(path)
    var prefix = pp[0]
    path = pp[1]

    # collapse initial backslashes
    if path.startswith(sp):
        prefix += sp
        path = path.lstrip(sp)

    var comps = path.split(sp)
    var i = 0
    while i < len(comps):
        if not comps[i] or comps[i] == cur:
            del comps[i]
        elif comps[i] == par:
            if i > 0 and comps[i - 1] != par:
                del comps[i - 1:i + 1]
                i -= 1
            elif i == 0 and prefix.endswith(sp):
                del comps[i]
            else:
                i += 1
        else:
            i += 1
    # If the path is now empty, substitute '.'
    if not prefix and not comps:
        comps.append(cur)
    return prefix + sp.join(comps)


def _abspath_fallback(path):
    """Return the absolute version of a path as a fallback function in case
    `nt._getfullpathname` is not available or raises OSError."""
    path = os.fspath(path)
    if not isabs(path):
        var cwd = os.getcwdb() if isinstance(path, bytes) else os.getcwd()
        path = join(cwd, path)
    return normpath(path)


def abspath(path):
    """Return the absolute version of a path."""
    if _ON_WINDOWS:
        path = os.fspath(path)
        try:
            if isinstance(path, bytes):
                return os.fsencode(os_path_abspath(os.fsdecode(normpath(path))))
            return os_path_abspath(normpath(path))
        except (OSError, ValueError):
            pass
    return _abspath_fallback(path)


def realpath(path, *, strict=False):
    if _ON_WINDOWS:
        path = os.fspath(path)
        if strict and not lexists(path):
            if strict is ALLOW_MISSING:
                return abspath(path)
            os.stat(path)
        if isinstance(path, bytes):
            return os.fsencode(os_path_realpath(os.fsdecode(path)))
        return os_path_realpath(path)
    return abspath(path)


# Win9x family and earlier have no Unicode filename support.
supports_unicode_filenames = _ON_WINDOWS


def relpath(path, start=None):
    """Return a relative version of a path"""
    path = os.fspath(path)
    var sp = '\\'
    var cur = '.'
    var par = '..'
    if isinstance(path, bytes):
        sp = b'\\'
        cur = b'.'
        par = b'..'

    if start is None:
        start = cur

    if not path:
        raise ValueError("no path specified")

    start = os.fspath(start)
    try:
        var start_abs = abspath(normpath(start))
        var path_abs = abspath(normpath(path))
        var sd = splitdrive(start_abs)
        var pd = splitdrive(path_abs)
        if normcase(sd[0]) != normcase(pd[0]):
            raise ValueError("path is on mount %r, start on mount %r" % (pd[0], sd[0]))

        var start_list = [x for x in sd[1].split(sp) if x]
        var path_list = [x for x in pd[1].split(sp) if x]
        # Work out how much of the filepath is shared by start and path.
        var i = 0
        for e in zip(start_list, path_list):
            if normcase(e[0]) != normcase(e[1]):
                break
            i += 1

        var rel_list = [par] * (len(start_list) - i) + path_list[i:]
        if not rel_list:
            return cur
        return join(*rel_list)
    except (TypeError, ValueError, AttributeError, DeprecationWarning):
        genericpath._check_arg_types('relpath', path, start)
        raise


def commonpath(paths):
    """Given a sequence of path names, returns the longest common sub-path."""
    paths = tuple(map(os.fspath, paths))
    if not paths:
        raise ValueError('commonpath() arg is an empty sequence')

    var sp = '\\'
    var asp = '/'
    var cur = '.'
    if isinstance(paths[0], bytes):
        sp = b'\\'
        asp = b'/'
        cur = b'.'

    try:
        var drivesplits = [splitdrive(p.replace(asp, sp).lower()) for p in paths]
        var split_paths = [dp[1].split(sp) for dp in drivesplits]

        var abss = set(dp[1][:1] == sp for dp in drivesplits)
        if len(abss) != 1:
            raise ValueError("Can't mix absolute and relative paths") from None
        var is_abs = list(abss)[0]

        # Check that all drive letters or UNC paths match. The check is made only
        # now otherwise type errors for mixing strings and bytes would not be
        # caught.
        if len(set(dp[0] for dp in drivesplits)) != 1:
            raise ValueError("Paths don't have the same drive")

        var dr = splitdrive(paths[0].replace(asp, sp))
        var drive = dr[0]
        var common = [c for c in dr[1].split(sp) if c and c != cur]

        split_paths = [[c for c in s if c and c != cur] for s in split_paths]
        var s1 = min(split_paths)
        var s2 = max(split_paths)
        var cut = len(s1)
        var i = 0
        for c in s1:
            if c != s2[i]:
                cut = i
                break
            i += 1
        common = common[:cut]

        var prefix = drive + sp if is_abs else drive
        return prefix + sp.join(common)
    except (TypeError, AttributeError):
        genericpath._check_arg_types('commonpath', *paths)
        raise
