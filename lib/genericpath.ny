# nython: module    (import it by name: it runs in a module scope of its own)
# lib/genericpath.ny - Python's genericpath (round 80): the path operations
# posixpath and ntpath share (CPython 3.11's Lib/genericpath.py). Do not use
# it directly: posixpath / ntpath (and os.path) re-export what is here.
#
# exists, isfile, isdir, getsize, getmtime, getatime, getctime,
# commonprefix, samestat, samefile, sameopenfile, _splitext,
# _check_arg_types, ALLOW_MISSING (realpath(strict=ALLOW_MISSING)).
#
# Everything the module has is here.
import os
import stat

__all__ = ['commonprefix', 'exists', 'getatime', 'getctime', 'getmtime',
           'getsize', 'isdir', 'isfile', 'samefile', 'sameopenfile',
           'samestat', 'ALLOW_MISSING']


# Does a path exist?
# This is false for dangling symbolic links on systems that support them.
def exists(path):
    """Test whether a path exists.  Returns False for broken symbolic links"""
    try:
        os.stat(path)
    except (OSError, ValueError):
        return False
    return True


# This follows symbolic links, so both islink() and isdir() can be true
# for the same path on systems that support symlinks
def isfile(path):
    """Test whether a path is a regular file"""
    var st = None
    try:
        st = os.stat(path)
    except (OSError, ValueError):
        return False
    return stat.S_ISREG(st.st_mode)


# Is a path a directory?
def isdir(s):
    """Return true if the pathname refers to an existing directory."""
    var st = None
    try:
        st = os.stat(s)
    except (OSError, ValueError):
        return False
    return stat.S_ISDIR(st.st_mode)


def getsize(filename):
    """Return the size of a file, reported by os.stat()."""
    return os.stat(filename).st_size


def getmtime(filename):
    """Return the last modification time of a file, reported by os.stat()."""
    return os.stat(filename).st_mtime


def getatime(filename):
    """Return the last access time of a file, reported by os.stat()."""
    return os.stat(filename).st_atime


def getctime(filename):
    """Return the metadata change time of a file, reported by os.stat()."""
    return os.stat(filename).st_ctime


# Return the longest prefix of all list elements.
def commonprefix(m):
    "Given a list of pathnames, returns the longest common leading component"
    if not m:
        return ''
    # Some people pass in a list of pathname parts to operate in an OS-agnostic
    # fashion; don't try to translate in that case.
    if not isinstance(m[0], (list, tuple)):
        m = tuple(map(os.fspath, m))
    var s1 = min(m)
    var s2 = max(m)
    var i = 0
    for c in s1:
        if c != s2[i]:
            return s1[:i]
        i += 1
    return s1


# Are two stat buffers (obtained from stat, fstat or lstat)
# describing the same file?
def samestat(s1, s2):
    """Test whether two stat buffers reference the same file"""
    return (s1.st_ino == s2.st_ino and
            s1.st_dev == s2.st_dev)


# Are two filenames really pointing to the same file?
def samefile(f1, f2):
    """Test whether two pathnames reference the same actual file or directory

    This is determined by the device number and i-node number and
    raises an exception if an os.stat() call on either pathname fails.
    """
    var s1 = os.stat(f1)
    var s2 = os.stat(f2)
    return samestat(s1, s2)


# Are two open files really referencing the same file?
# (Not necessarily the same file descriptor!)
def sameopenfile(fp1, fp2):
    """Test whether two open file objects reference the same file"""
    var s1 = os.fstat(fp1)
    var s2 = os.fstat(fp2)
    return samestat(s1, s2)


# Split a path in root and extension.
# The extension is everything starting at the last dot in the last
# pathname component; the root is everything before that.
# It is always true that root + ext == p.
def _splitext(p, sep, altsep, extsep):
    """Split the extension from a pathname.

    Extension is everything from the last dot to the end, ignoring
    leading dots.  Returns "(root, ext)"; ext may be empty."""
    # NOTE: This code must work for text and bytes strings.
    var sepIndex = p.rfind(sep)
    if altsep:
        var altsepIndex = p.rfind(altsep)
        sepIndex = max(sepIndex, altsepIndex)

    var dotIndex = p.rfind(extsep)
    if dotIndex > sepIndex:
        # skip all leading dots
        var filenameIndex = sepIndex + 1
        while filenameIndex < dotIndex:
            if p[filenameIndex:filenameIndex + 1] != extsep:
                return p[:dotIndex], p[dotIndex:]
            filenameIndex += 1

    return p, p[:0]


def _check_arg_types(funcname, *args):
    var hasstr = False
    var hasbytes = False
    for s in args:
        if isinstance(s, str):
            hasstr = True
        elif isinstance(s, bytes):
            hasbytes = True
        else:
            raise TypeError(funcname + "() argument must be str, bytes, or os.PathLike object, not "
                            + repr(type(s).__name__)) from None
    if hasstr and hasbytes:
        raise TypeError("Can't mix strings and bytes in path components") from None


# A singleton with a true boolean value.
class _ALLOW_MISSING_TYPE:
    """Special value for use in realpath()."""
    def __repr__(self):
        return 'os.path.ALLOW_MISSING'

    def __reduce__(self):
        return "ALLOW_MISSING"


ALLOW_MISSING = _ALLOW_MISSING_TYPE()
