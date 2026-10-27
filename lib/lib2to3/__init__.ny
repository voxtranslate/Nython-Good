# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/__init__.ny - CPython 3.11's Lib/lib2to3/__init__.py (round 87).
import warnings


warnings.warn(
    "lib2to3 package is deprecated and may not be able to parse Python 3.10+",
    DeprecationWarning,
    stacklevel=2,
)
