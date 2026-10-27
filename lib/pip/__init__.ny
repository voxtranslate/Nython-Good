# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/pip/__init__.ny - `pip` is nypip, Nython's installer (round 87):
# `nython -m pip install ...` runs `nython -m nypip install ...` (see
# lib/nypip/cli.ny for the commands). pip's own internals (pip._internal)
# are not here.
from nypip import __version__, main

__all__ = ["main", "__version__"]
