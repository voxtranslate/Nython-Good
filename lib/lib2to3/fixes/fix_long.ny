# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_long.ny - CPython 3.11's Lib/lib2to3/fixes/fix_long.py (round 87).
# Copyright 2006 Google, Inc. All Rights Reserved.
# Licensed to PSF under a Contributor Agreement.

"""Fixer that turns 'long' into 'int' everywhere.
"""

# Local imports
from lib2to3 import fixer_base
from lib2to3.fixer_util import is_probably_builtin


class FixLong(fixer_base.BaseFix):
    BM_compatible = True
    PATTERN = "'long'"

    def transform(self, node, results):
        if is_probably_builtin(node):
            node.value = "int"
            node.changed()
