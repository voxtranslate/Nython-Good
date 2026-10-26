# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/nypip/__main__.ny - `nython -m nypip ...` (round 87)
import sys
from nypip.cli import main

sys.exit(main())
