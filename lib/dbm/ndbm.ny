# nython: module    (import it by name: it runs in a module scope of its own)
# lib/dbm/ndbm.ny - Python's dbm.ndbm (CPython 3.13's Lib/dbm/ndbm.py):
# over the C module _dbm, which Nython does not have - importing it raises
# ImportError, as CPython does where ndbm is not installed.

"""Provide the _dbm module as a dbm submodule."""

from _dbm import *
