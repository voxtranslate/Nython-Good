# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/sre_parse.ny - Python's sre_parse (round 87; CPython 3.11's
# Lib/sre_parse.py): the deprecated alias of re._parser, its names copied in.

import warnings
warnings.warn(f"module {__name__!r} is deprecated",
              DeprecationWarning,
              stacklevel=2)

from re import _parser as _
globals().update({k: v for k, v in vars(_).items() if k[:2] != '__'})
