# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/importlib/metadata/_collections.ny - CPython 3.12's importlib.metadata._collections (round 87): the
# installed distributions' metadata (.dist-info / .egg-info directories on
# sys.path, and in zip files on it). Changes for Nython are marked "Nython:".
#
import collections


# from jaraco.collections 3.3
class FreezableDefaultDict(collections.defaultdict):
    """
    Often it is desirable to prevent the mutation of
    a default dict after its initial construction, such
    as to prevent mutation during iteration.

    >>> dd = FreezableDefaultDict(list)
    >>> dd[0].append('1')
    >>> dd.freeze()
    >>> dd[1]
    []
    >>> len(dd)
    1
    """

    def __missing__(self, key):
        return getattr(self, '_frozen', super().__missing__)(key)

    def freeze(self):
        self._frozen = lambda key: self.default_factory()


class Pair(collections.namedtuple('Pair', 'name value')):
    @classmethod
    def parse(cls, text):
        return cls(*map(str.strip, text.split("=", 1)))
