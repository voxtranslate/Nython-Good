# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_future.ny - CPython 3.11's Lib/lib2to3/fixes/fix_future.py (round 87).
"""Remove __future__ imports

from __future__ import foo is replaced with an empty line.
"""
# Author: Christian Heimes

# Local imports
from .. import fixer_base
from ..fixer_util import BlankLine

class FixFuture(fixer_base.BaseFix):
    BM_compatible = True

    PATTERN = """import_from< 'from' module_name="__future__" 'import' any >"""

    # This should be run last -- some things check for the import
    run_order = 10

    def transform(self, node, results):
        new = BlankLine()
        new.prefix = node.prefix
        return new
