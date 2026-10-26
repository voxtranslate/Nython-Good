# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/lib2to3/__main__.ny - CPython 3.11's Lib/lib2to3/__main__.py (round 87).
import sys
from lib2to3.main import main   # (Nython: -m runs this file as the program, with no __package__)

sys.exit(main("lib2to3.fixes"))
