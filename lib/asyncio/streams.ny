# nython: module    (import it by name: it runs in a module scope of its own)
# lib/asyncio/streams.ny - asyncio.streams: streams over the protocols
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (StreamReader, StreamWriter, StreamReaderProtocol, open_connection, start_server, IncompleteReadError, LimitOverrunError, FlowControlMixin, _DEFAULT_LIMIT)
import socket as _socket
if getattr(_socket, "AF_UNIX", None) is not None:
    from asyncio import open_unix_connection, start_unix_server
