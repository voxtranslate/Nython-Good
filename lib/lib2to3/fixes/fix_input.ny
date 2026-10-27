# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_input.ny - CPython 3.11's Lib/lib2to3/fixes/fix_input.py (round 87).
"""Fixer that changes input(...) into eval(input(...))."""
# Author: Andre Roberge

# Local imports
from .. import fixer_base
from ..fixer_util import Call, Name
from .. import patcomp


context = patcomp.compile_pattern("power< 'eval' trailer< '(' any ')' > >")


class FixInput(fixer_base.BaseFix):
    BM_compatible = True
    PATTERN = """
              power< 'input' args=trailer< '(' [any] ')' > >
              """

    def transform(self, node, results):
        # If we're already wrapped in an eval() call, we're done.
        if context.match(node.parent.parent):
            return

        new = node.clone()
        new.prefix = ""
        return Call(Name("eval"), [new], prefix=node.prefix)
