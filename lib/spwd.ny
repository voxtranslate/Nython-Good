# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/spwd.ny - Python's spwd (round 87; CPython 3.11's Modules/spwdmodule.c,
# deprecated there and removed in 3.13): the shadow password database
# through the C library (getspnam, setspent/getspent/endspent - /etc/shadow
# or whatever NSS is configured with; src/builtins/nycrypt.cpp).
#
#     import spwd
#     spwd.getspnam("root").sp_pwdp        # (reading it needs privileges)
#
# getspnam(name), getspall(); struct_spwd, a structure sequence of nine
# fields (sp_namp, sp_pwdp, sp_lstchg, sp_min, sp_max, sp_warn, sp_inact,
# sp_expire, sp_flag) with sp_nam / sp_pwd as their aliases. KeyError for a
# name that is not there, PermissionError / OSError when the database cannot
# be read, as CPython. Where the C library has no shadow database (Windows,
# macOS) importing it raises ModuleNotFoundError, as CPython there.
import warnings

if not _spwd_supported():
    raise ModuleNotFoundError("No module named 'spwd'", name="spwd")

warnings._deprecated(__name__, remove=(3, 13))

__all__ = ["getspnam", "getspall", "struct_spwd"]


class struct_spwd(_NyStructSeq):
    """spwd.struct_spwd: Results from getsp*() routines.

This object may be accessed either as a 9-tuple of
  (sp_namp,sp_pwdp,sp_lstchg,sp_min,sp_max,sp_warn,sp_inact,sp_expire,sp_flag)
or via the object attributes as named in the above tuple."""
    __module__ = "spwd"
    _ny_qual = "spwd.struct_spwd"
    _ny_names = ("sp_namp", "sp_pwdp", "sp_lstchg", "sp_min", "sp_max", "sp_warn", "sp_inact", "sp_expire", "sp_flag")
    _ny_extra = ("sp_nam", "sp_pwd")
    _ny_exact = False
    n_sequence_fields = 9
    n_fields = 11
    n_unnamed_fields = 0


def _entry(t):
    return struct_spwd(tuple(t) + (t[0], t[1]))


def _error(e):
    import os
    raise OSError(e, os.strerror(e))


def getspnam(arg, /):
    """Return the shadow password database entry for the given user name.

    See `help(spwd)` for more on shadow password database entries."""
    if not isinstance(arg, str):
        raise TypeError("getspnam() argument must be str, not " + type(arg).__name__)
    if "\x00" in arg:
        raise ValueError("embedded null character")
    r = _spwd_getspnam(arg)
    if isinstance(r, int):
        if r == 0:
            raise KeyError("getspnam(): name not found")
        _error(r)
    return _entry(r)


def getspall():
    """Return a list of all available shadow password database entries, in arbitrary order.

    See `help(spwd)` for more on shadow password database entries."""
    r = _spwd_getspall()
    if isinstance(r, int):
        _error(r)
    return [_entry(t) for t in r]
