# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_reduce.ny - CPython 3.11's Lib/lib2to3/fixes/fix_reduce.py (round 87).
# Copyright 2008 Armin Ronacher.
# Licensed to PSF under a Contributor Agreement.

"""Fixer for reduce().

Makes sure reduce() is imported from the functools module if reduce is
used in that module.
"""

from lib2to3 import fixer_base
from lib2to3.fixer_util import touch_import



class FixReduce(fixer_base.BaseFix):

    BM_compatible = True
    order = "pre"

    PATTERN = """
    power< 'reduce'
        trailer< '('
            arglist< (
                (not(argument<any '=' any>) any ','
                 not(argument<any '=' any>) any) |
                (not(argument<any '=' any>) any ','
                 not(argument<any '=' any>) any ','
                 not(argument<any '=' any>) any)
            ) >
        ')' >
    >
    """

    def transform(self, node, results):
        touch_import('functools', 'reduce', node)
