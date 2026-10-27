# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/exceptions.ny - asyncio.exceptions: asyncio's exceptions
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (CancelledError, InvalidStateError, TimeoutError, IncompleteReadError, LimitOverrunError, SendfileNotAvailableError, BrokenBarrierError, QueueEmpty, QueueFull, QueueShutDown)
