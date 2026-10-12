# nython: module    (import it by name: it runs in a module scope of its own)
# lib/dbm/gnu.ny - Python's dbm.gnu (CPython 3.13's Lib/dbm/gnu.py): over
# the C module _gdbm, which Nython does not have - importing it raises
# ImportError, as CPython does where gdbm is not installed.

"""Provide the _gdbm module as a dbm submodule."""

try:
    from _gdbm import *
except ImportError as msg:
    raise ImportError(str(msg) + ', please install the python3-gdbm package')
