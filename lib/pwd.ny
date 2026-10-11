# nython: module    (import it by name: it runs in a module scope of its own)
# lib/pwd.ny - Python's pwd module (round 80): the Unix password database,
# through the C library (getpwnam/getpwuid/getpwent, src/builtins/os_fd.cpp)
# - /etc/passwd, NSS, whatever the system is configured with.
#
#     import pwd
#     pwd.getpwuid(os.getuid()).pw_dir      # the user's home directory
#     pwd.getpwnam("root").pw_uid           # 0
#
# getpwuid(uid), getpwnam(name), getpwall(); struct_passwd, a structure
# sequence (indexable, unpackable, compares with tuples) with pw_name,
# pw_passwd, pw_uid, pw_gid, pw_gecos, pw_dir, pw_shell. KeyError and
# TypeError with CPython's messages. POSIX only: importing it on Windows
# raises ModuleNotFoundError, as CPython.
#
# Everything the module has is here.

if os_name == "nt":
    raise ModuleNotFoundError("No module named 'pwd'", name="pwd")

__all__ = ["getpwuid", "getpwnam", "getpwall", "struct_passwd"]


class struct_passwd(_NyStructSeq):
    """pwd.struct_passwd: Results from getpw*() routines."""
    __module__ = "pwd"
    _ny_qual = "pwd.struct_passwd"
    _ny_names = ("pw_name", "pw_passwd", "pw_uid", "pw_gid", "pw_gecos", "pw_dir", "pw_shell")
    n_sequence_fields = 7
    n_fields = 7
    n_unnamed_fields = 0


def _uid(uid, fn):
    if isinstance(uid, bool) or not isinstance(uid, int):
        if hasattr(uid, "__index__"):
            return uid.__index__()
        raise TypeError("'" + type(uid).__name__ + "' object cannot be interpreted as an integer")
    return uid


def getpwuid(uid):
    """Return the password database entry for the given numeric user ID."""
    uid = _uid(uid, "getpwuid")
    var t = None
    if -2147483648 <= uid <= 4294967295:
        t = _ny_os_call("getpwuid", uid)
    if t is None:
        raise KeyError("getpwuid(): uid not found: " + str(uid))
    return struct_passwd(t)


def getpwnam(name):
    """Return the password database entry for the given user name."""
    if not isinstance(name, str):
        raise TypeError("getpwnam() argument must be str, not " + type(name).__name__)
    if "\x00" in name:
        raise ValueError("embedded null character")
    var t = _ny_os_call("getpwnam", name)
    if t is None:
        raise KeyError("getpwnam(): name not found: " + repr(name))
    return struct_passwd(t)


def getpwall():
    """Return a list of all available password database entries, in arbitrary order."""
    return [struct_passwd(t) for t in _ny_os_call("getpwall")]
