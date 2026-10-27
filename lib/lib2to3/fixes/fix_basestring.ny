# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_basestring.ny - CPython 3.11's Lib/lib2to3/fixes/fix_basestring.py (round 87).
"""Fixer for basestring -> str."""
# Author: Christian Heimes

# Local imports
from .. import fixer_base
from ..fixer_util import Name

class FixBasestring(fixer_base.BaseFix):
    BM_compatible = True

    PATTERN = "'basestring'"

    def transform(self, node, results):
        return Name("str", prefix=node.prefix)
