# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/queues.ny - asyncio.queues: the queues
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (Queue, PriorityQueue, LifoQueue, QueueFull, QueueEmpty, QueueShutDown)
