# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_standarderror.ny - CPython 3.11's Lib/lib2to3/fixes/fix_standarderror.py (round 87).
# Copyright 2007 Google, Inc. All Rights Reserved.
# Licensed to PSF under a Contributor Agreement.

"""Fixer for StandardError -> Exception."""

# Local imports
from .. import fixer_base
from ..fixer_util import Name


class FixStandarderror(fixer_base.BaseFix):
    BM_compatible = True
    PATTERN = """
              'StandardError'
              """

    def transform(self, node, results):
        return Name("Exception", prefix=node.prefix)
