# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/xml/parsers/expat.ny - Python's xml.parsers.expat (CPython 3.12's
# Lib/xml/parsers/expat.py, round 87): the names of pyexpat, the parser
# (lib/pyexpat.ny, where round 79's parser written in Nython now lives), with
# its errors and model submodules entered as xml.parsers.expat.errors and
# xml.parsers.expat.model.
"""Interface to the Expat non-validating XML parser."""
import sys

from pyexpat import *

# provide pyexpat submodules as xml.parsers.expat submodules
sys.modules['xml.parsers.expat.model'] = model
sys.modules['xml.parsers.expat.errors'] = errors
