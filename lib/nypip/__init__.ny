# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/nypip/__init__.ny - nypip, Nython's package installer (round 87).

__version__ = "0.2.1"


def main(argv=None):
    from nypip.cli import main as _main
    return _main(argv)
