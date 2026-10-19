# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/errno.ny - Python's errno module (round 83): the platform's error
# numbers by name, and errorcode, the names by number.
#
#     import errno
#     errno.ENOENT                      # 2 on Linux, macOS and Windows
#     errno.errorcode[errno.EACCES]     # "EACCES"
#     os.strerror(errno.EPIPE)          # "Broken pipe"
#
# The table is generated natively from the C library's <errno.h> (an #ifdef
# per name, builtins/nysysmods.cpp), so every value is the platform's own and
# only the names the platform defines exist - as CPython's errnomodule.c
# builds it. Where two names share a number, errorcode gives the one CPython
# gives (EAGAIN over EWOULDBLOCK, EDEADLOCK over EDEADLK, ENOTSUP over
# EOPNOTSUPP); on Windows the WSAE* Windows Sockets codes are there too.
#
# Not here: nothing - this is the whole module.

errorcode = {}


def _load():
    var g = globals()
    for pair in _sys_errno_table():
        g[pair[0]] = pair[1]
        errorcode[pair[1]] = pair[0]


_load()
del _load
