# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_exec.ny - CPython 3.11's Lib/lib2to3/fixes/fix_exec.py (round 87).
# Copyright 2006 Google, Inc. All Rights Reserved.
# Licensed to PSF under a Contributor Agreement.

"""Fixer for exec.

This converts usages of the exec statement into calls to a built-in
exec() function.

exec code in ns1, ns2 -> exec(code, ns1, ns2)
"""

# Local imports
from .. import fixer_base
from ..fixer_util import Comma, Name, Call


class FixExec(fixer_base.BaseFix):
    BM_compatible = True

    PATTERN = """
    exec_stmt< 'exec' a=any 'in' b=any [',' c=any] >
    |
    exec_stmt< 'exec' (not atom<'(' [any] ')'>) a=any >
    """

    def transform(self, node, results):
        assert results
        syms = self.syms
        a = results["a"]
        b = results.get("b")
        c = results.get("c")
        args = [a.clone()]
        args[0].prefix = ""
        if b is not None:
            args.extend([Comma(), b.clone()])
        if c is not None:
            args.extend([Comma(), c.clone()])

        return Call(Name("exec"), args, prefix=node.prefix)
