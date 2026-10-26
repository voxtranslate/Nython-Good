# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_getcwdu.ny - CPython 3.11's Lib/lib2to3/fixes/fix_getcwdu.py (round 87).
"""
Fixer that changes os.getcwdu() to os.getcwd().
"""
# Author: Victor Stinner

# Local imports
from .. import fixer_base
from ..fixer_util import Name

class FixGetcwdu(fixer_base.BaseFix):
    BM_compatible = True

    PATTERN = """
              power< 'os' trailer< dot='.' name='getcwdu' > any* >
              """

    def transform(self, node, results):
        name = results["name"]
        name.replace(Name("getcwd", prefix=name.prefix))
