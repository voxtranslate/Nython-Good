# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 86)
# lib/nylsp/__main__.ny - `nython -m nylsp [--stdio | --tcp PORT [--host H]]`
# (round 86): the Language Server on standard input/output, or on one TCP
# connection. See lib/nylsp/__init__.ny.
import sys
from nylsp.server import main

sys.exit(main(sys.argv[1:]))
