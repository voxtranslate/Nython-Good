# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 87)
# lib/ensurepip/__main__.ny - `nython -m ensurepip` (round 87)
import ensurepip
import sys

if __name__ == "__main__":
    sys.exit(ensurepip._main())
