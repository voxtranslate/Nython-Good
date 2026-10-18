# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/protocols.ny - asyncio.protocols: the protocol classes
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (BaseProtocol, Protocol, DatagramProtocol, SubprocessProtocol, BufferedProtocol)
