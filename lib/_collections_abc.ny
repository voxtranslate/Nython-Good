# nython: module    (import it by name: it runs in a module scope of its own)
# lib/_collections_abc.ny - CPython's internal name for collections.abc
# (what os, typing and collections import): the same module's classes,
# defined in lib/collections/abc.ny so that they are named
# collections.abc.Mapping ... as CPython names them.

from collections.abc import *
from collections.abc import __all__, GenericAlias, EllipsisType, _check_methods, _CallableGenericAlias, _is_param_expr, _type_repr
