# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/futures.ny - asyncio.futures: Future and its helpers
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (Future, wrap_future, isfuture, _chain_future)
