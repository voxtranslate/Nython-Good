# nython: module    (import it by name: it runs in a module scope of its own)
# lib/posix.ny - CPython's posix module (round 85): the operating system's
# calls that os re-exports. POSIX only: on Windows `import posix` raises
# ModuleNotFoundError and lib/nt.ny is its counterpart, as in CPython.
#
#     import posix
#     posix.getcwd(); posix.stat("/"); posix.environ[b"HOME"]
#     posix.getcwd is os.getcwd          # the same functions, not copies
#
# Its members are os's own objects - the engines' natives (os.getcwd ...)
# and the prelude's os and "posix" chunks (src/NyPreludePosix.cpp) - for
# every name CPython's posix has (the prelude's _ny_px_names): so
# os.getcwd.__module__ == "posix" and a pickle of os.getcwd names posix, as
# CPython's do. posix.environ is CPython's: a plain dict of bytes to bytes,
# the environment when the module was first imported (os.environ is the
# mapping that writes through).
#
# Not here: the names Nython's os lacks (the api_diff tool lists them).

if not _sys_platform_posix():
    raise ModuleNotFoundError("No module named 'posix'", name="posix")

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
        env[_os.fsencode(k)] = _os.fsencode(_os.environ[k])
    g["environ"] = env

_load()
del _load
del _os
