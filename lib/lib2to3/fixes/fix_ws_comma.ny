# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_ws_comma.ny - CPython 3.11's Lib/lib2to3/fixes/fix_ws_comma.py (round 87).
"""Fixer that changes 'a ,b' into 'a, b'.

This also changes '{a :b}' into '{a: b}', but does not touch other
uses of colons.  It does not touch other uses of whitespace.

"""

from .. import pytree
from ..pgen2 import token
from .. import fixer_base

class FixWsComma(fixer_base.BaseFix):

    explicit = True # The user must ask for this fixers

    PATTERN = """
    any<(not(',') any)+ ',' ((not(',') any)+ ',')* [not(',') any]>
    """

    COMMA = pytree.Leaf(token.COMMA, ",")
    COLON = pytree.Leaf(token.COLON, ":")
    SEPS = (COMMA, COLON)

    def transform(self, node, results):
        new = node.clone()
        comma = False
        for child in new.children:
            if child in self.SEPS:
                prefix = child.prefix
                if prefix.isspace() and "\n" not in prefix:
                    child.prefix = ""
                comma = True
            else:
                if comma:
                    prefix = child.prefix
                    if not prefix:
                        child.prefix = " "
                comma = False
        return new
