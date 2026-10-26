# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_imports2.ny - CPython 3.11's Lib/lib2to3/fixes/fix_imports2.py (round 87).
"""Fix incompatible imports and module references that must be fixed after
fix_imports."""
from . import fix_imports


MAPPING = {
            'whichdb': 'dbm',
            'anydbm': 'dbm',
          }


class FixImports2(fix_imports.FixImports):

    run_order = 7

    mapping = MAPPING
