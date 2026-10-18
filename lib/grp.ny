# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/grp.ny - Python's grp module (round 80): the Unix group database,
# through the C library (getgrnam/getgrgid/getgrent, src/builtins/os_fd.cpp).
#
#     import grp
#     grp.getgrgid(os.getgid()).gr_name
#     grp.getgrnam("root").gr_mem           # the members' names
#
# getgrgid(gid), getgrnam(name), getgrall(); struct_group, a structure
# sequence with gr_name, gr_passwd, gr_gid, gr_mem (a list). KeyError and
# TypeError with CPython's messages. POSIX only: importing it on Windows
# raises ModuleNotFoundError, as CPython.
#
# Everything the module has is here.

if os_name == "nt":
    raise ModuleNotFoundError("No module named 'grp'", name="grp")

__all__ = ["getgrgid", "getgrnam", "getgrall", "struct_group"]


class struct_group(_NyStructSeq):
    """grp.struct_group: Results from getgr*() routines."""
    __module__ = "grp"
    _ny_qual = "grp.struct_group"
    _ny_names = ("gr_name", "gr_passwd", "gr_gid", "gr_mem")
    n_sequence_fields = 4
    n_fields = 4
    n_unnamed_fields = 0


def getgrgid(id):
    """Return the group database entry for the given numeric group ID."""
    if not isinstance(id, int):
        if hasattr(id, "__index__") and not isinstance(id, float):
            id = id.__index__()
        else:
            raise TypeError("gid should be integer, not " + type(id).__name__)
    if id < -1:
        raise OverflowError("gid is less than minimum")
    if id > 4294967295:
        raise OverflowError("gid is greater than maximum")
    var t = _ny_os_call("getgrgid", int(id))
    if t is None:
        raise KeyError("getgrgid(): gid not found: " + str(int(id)))
    return struct_group(t)


def getgrnam(name):
    """Return the group database entry for the given group name."""
    if not isinstance(name, str):
        raise TypeError("getgrnam() argument must be str, not " + type(name).__name__)
    if "\x00" in name:
        raise ValueError("embedded null character")
    var t = _ny_os_call("getgrnam", name)
    if t is None:
        raise KeyError("getgrnam(): name not found: " + repr(name))
    return struct_group(t)


def getgrall():
    """Return a list of all available group entries, in arbitrary order."""
    return [struct_group(t) for t in _ny_os_call("getgrall")]
