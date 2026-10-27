# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nt.ny - CPython's nt module (round 85): the Windows counterpart of
# lib/posix.ny, the calls os re-exports there. Windows only: elsewhere
# `import nt` raises ModuleNotFoundError, as in CPython.
#
# Its members are os's own objects for every name both os and CPython's
# posix/nt lists have (the prelude's _ny_px_names - CPython's nt has a
# subset of them); nt.environ is a dict of str to str, as CPython's (keys
# upper-cased).
#
# Not here: nt's Windows-only extras (_getfinalpathname, _getvolumepathname,
# startfile, add_dll_directory ...).

if _sys_platform_posix():
    raise ModuleNotFoundError("No module named 'nt'", name="nt")

import os as _os

def _load():
    var g = globals()
    for n in _ny_px_names:
        if n == "environ":
            continue
        if hasattr(_os, n):
            g[n] = getattr(_os, n)
    var env = {}
    for k in _os.environ:
        env[k.upper()] = _os.environ[k]
    g["environ"] = env

_load()
del _load
del _os
