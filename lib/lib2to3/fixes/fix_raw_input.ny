# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_raw_input.ny - CPython 3.11's Lib/lib2to3/fixes/fix_raw_input.py (round 87).
"""Fixer that changes raw_input(...) into input(...)."""
# Author: Andre Roberge

# Local imports
from .. import fixer_base
from ..fixer_util import Name

class FixRawInput(fixer_base.BaseFix):

    BM_compatible = True
    PATTERN = """
              power< name='raw_input' trailer< '(' [any] ')' > any* >
              """

    def transform(self, node, results):
        name = results["name"]
        name.replace(Name("input", prefix=name.prefix))
