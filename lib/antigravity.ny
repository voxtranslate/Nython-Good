# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/antigravity.ny - `import antigravity` (round 83), as CPython's: it
# asks the webbrowser module to open https://xkcd.com/353/, and provides
# geohash() (xkcd 426, the Munroe algorithm).
#
# Opening a browser: through a webbrowser module when there is one; there
# is none in this tree, and in a headless run (no display, no browser)
# nothing is opened and nothing printed - CPython's webbrowser.open returns
# False there too. geohash() prints exactly what CPython's does.

import hashlib

try:
    import webbrowser
    webbrowser.open("https://xkcd.com/353/")
except ImportError:
    pass


def geohash(latitude, longitude, datedow):
    '''Compute geohash() using the Munroe algorithm.

    >>> geohash(37.421542, -122.085589, b'2005-05-26-10458.68')
    37.857713 -122.544543

    '''
    # https://xkcd.com/426/
    h = hashlib.md5(datedow, usedforsecurity=False).hexdigest()
    p, q = [('%f' % float.fromhex('0.' + x)) for x in (h[:16], h[16:32])]
    print('%d%s %d%s' % (latitude, p[1:], longitude, q[1:]))
