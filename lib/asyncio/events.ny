# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/asyncio/events.ny - asyncio.events: the event loop and its policies
# (the names live in lib/asyncio/__init__.ny; round 82).
from asyncio import (AbstractEventLoopPolicy, AbstractEventLoop, AbstractServer, Handle, TimerHandle, get_event_loop_policy, set_event_loop_policy, get_event_loop, set_event_loop, new_event_loop, get_running_loop, _get_running_loop, BaseDefaultEventLoopPolicy)
