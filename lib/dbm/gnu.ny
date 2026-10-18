# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/dbm/gnu.ny - Python's dbm.gnu (CPython 3.13's Lib/dbm/gnu.py): over
# the C module _gdbm, which Nython does not have - importing it raises
# ImportError, as CPython does where gdbm is not installed.

"""Provide the _gdbm module as a dbm submodule."""

from _gdbm import *
