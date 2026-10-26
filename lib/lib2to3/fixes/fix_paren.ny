# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_paren.ny - CPython 3.11's Lib/lib2to3/fixes/fix_paren.py (round 87).
"""Fixer that adds parentheses where they are required

This converts ``[x for x in 1, 2]`` to ``[x for x in (1, 2)]``."""

# By Taek Joo Kim and Benjamin Peterson

# Local imports
from .. import fixer_base
from ..fixer_util import LParen, RParen

# XXX This doesn't support nested for loops like [x for x in 1, 2 for x in 1, 2]
class FixParen(fixer_base.BaseFix):
    BM_compatible = True

    PATTERN = """
        atom< ('[' | '(')
            (listmaker< any
                comp_for<
                    'for' NAME 'in'
                    target=testlist_safe< any (',' any)+ [',']
                     >
                    [any]
                >
            >
            |
            testlist_gexp< any
                comp_for<
                    'for' NAME 'in'
                    target=testlist_safe< any (',' any)+ [',']
                     >
                    [any]
                >
            >)
        (']' | ')') >
    """

    def transform(self, node, results):
        target = results["target"]

        lparen = LParen()
        lparen.prefix = target.prefix
        target.prefix = "" # Make it hug the parentheses
        target.insert_child(0, lparen)
        target.append_child(RParen())
