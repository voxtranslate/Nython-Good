# nython: module    (import it by name: it runs in a module scope of its own)
# lib/asyncio/subprocess.ny - asyncio.subprocess: child processes with streams
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (PIPE, STDOUT, DEVNULL, Process, SubprocessStreamProtocol, create_subprocess_exec, create_subprocess_shell)
