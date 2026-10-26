# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_unicode.ny - CPython 3.11's Lib/lib2to3/fixes/fix_unicode.py (round 87).
r"""Fixer for unicode.

* Changes unicode to str and unichr to chr.

* If "...\u..." is not unicode literal change it into "...\\u...".

* Change u"..." into "...".

"""

from ..pgen2 import token
from .. import fixer_base

_mapping = {"unichr" : "chr", "unicode" : "str"}

class FixUnicode(fixer_base.BaseFix):
    BM_compatible = True
    PATTERN = "STRING | 'unicode' | 'unichr'"

    def start_tree(self, tree, filename):
        super(FixUnicode, self).start_tree(tree, filename)
        self.unicode_literals = 'unicode_literals' in tree.future_features

    def transform(self, node, results):
        if node.type == token.NAME:
            new = node.clone()
            new.value = _mapping[node.value]
            return new
        elif node.type == token.STRING:
            val = node.value
            if not self.unicode_literals and val[0] in '\'"' and '\\' in val:
                val = r'\\'.join([
                    v.replace('\\u', r'\\u').replace('\\U', r'\\U')
                    for v in val.split(r'\\')
                ])
            if val[0] in 'uU':
                val = val[1:]
            if val == node.value:
                return node
            new = node.clone()
            new.value = val
            return new
