# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/coroutines.ny - asyncio.coroutines: coroutine checks
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (iscoroutine, iscoroutinefunction)
