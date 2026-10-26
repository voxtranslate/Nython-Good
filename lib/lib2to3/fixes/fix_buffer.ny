# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_buffer.ny - CPython 3.11's Lib/lib2to3/fixes/fix_buffer.py (round 87).
# Copyright 2007 Google, Inc. All Rights Reserved.
# Licensed to PSF under a Contributor Agreement.

"""Fixer that changes buffer(...) into memoryview(...)."""

# Local imports
from .. import fixer_base
from ..fixer_util import Name


class FixBuffer(fixer_base.BaseFix):
    BM_compatible = True

    explicit = True # The user must ask for this fixer

    PATTERN = """
              power< name='buffer' trailer< '(' [any] ')' > any* >
              """

    def transform(self, node, results):
        name = results["name"]
        name.replace(Name("memoryview", prefix=name.prefix))
