# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_asserts.ny - CPython 3.11's Lib/lib2to3/fixes/fix_asserts.py (round 87).
"""Fixer that replaces deprecated unittest method names."""

# Author: Ezio Melotti

from ..fixer_base import BaseFix
from ..fixer_util import Name

NAMES = dict(
    assert_="assertTrue",
    assertEquals="assertEqual",
    assertNotEquals="assertNotEqual",
    assertAlmostEquals="assertAlmostEqual",
    assertNotAlmostEquals="assertNotAlmostEqual",
    assertRegexpMatches="assertRegex",
    assertRaisesRegexp="assertRaisesRegex",
    failUnlessEqual="assertEqual",
    failIfEqual="assertNotEqual",
    failUnlessAlmostEqual="assertAlmostEqual",
    failIfAlmostEqual="assertNotAlmostEqual",
    failUnless="assertTrue",
    failUnlessRaises="assertRaises",
    failIf="assertFalse",
)


class FixAsserts(BaseFix):

    PATTERN = """
              power< any+ trailer< '.' meth=(%s)> any* >
              """ % '|'.join(map(repr, NAMES))

    def transform(self, node, results):
        name = results["meth"][0]
        name.replace(Name(NAMES[str(name)], prefix=name.prefix))
