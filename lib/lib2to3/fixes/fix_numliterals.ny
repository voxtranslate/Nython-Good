# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_numliterals.ny - CPython 3.11's Lib/lib2to3/fixes/fix_numliterals.py (round 87).
"""Fixer that turns 1L into 1, 0755 into 0o755.
"""
# Copyright 2007 Georg Brandl.
# Licensed to PSF under a Contributor Agreement.

# Local imports
from ..pgen2 import token
from .. import fixer_base
from ..fixer_util import Number


class FixNumliterals(fixer_base.BaseFix):
    # This is so simple that we don't need the pattern compiler.

    _accept_type = token.NUMBER

    def match(self, node):
        # Override
        return (node.value.startswith("0") or node.value[-1] in "Ll")

    def transform(self, node, results):
        val = node.value
        if val[-1] in 'Ll':
            val = val[:-1]
        elif val.startswith('0') and val.isdigit() and len(set(val)) > 1:
            val = "0o" + val[1:]

        return Number(val, prefix=node.prefix)
