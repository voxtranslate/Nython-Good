# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/fixes/fix_funcattrs.ny - CPython 3.11's Lib/lib2to3/fixes/fix_funcattrs.py (round 87).
"""Fix function attribute names (f.func_x -> f.__x__)."""
# Author: Collin Winter

# Local imports
from .. import fixer_base
from ..fixer_util import Name


class FixFuncattrs(fixer_base.BaseFix):
    BM_compatible = True

    PATTERN = """
    power< any+ trailer< '.' attr=('func_closure' | 'func_doc' | 'func_globals'
                                  | 'func_name' | 'func_defaults' | 'func_code'
                                  | 'func_dict') > any* >
    """

    def transform(self, node, results):
        attr = results["attr"][0]
        attr.replace(Name(("__%s__" % attr.value[5:]),
                          prefix=attr.prefix))
