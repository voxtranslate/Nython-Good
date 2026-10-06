# nython: module    (import collections.abc / from collections.abc import Mapping)
# lib/collections/abc.ny - Python's collections.abc: the abstract base
# classes for containers (PEP 3119), CPython 3.12's Lib/_collections_abc.py.
#
#     from collections.abc import Mapping, Sequence, Iterable
#     isinstance({}, Mapping); isinstance("s", Sequence)       # True, True
#     class Squares(Sequence):            # __getitem__ and __len__ ...
#         def __getitem__(self, i): ...   # ... give __contains__, __iter__,
#         def __len__(self): ...          # __reversed__, index and count
#
# The one-trick ponies, with CPython's __subclasshook__ (structural: any
# class defining __iter__ is an Iterable, __hash__ = None is not Hashable):
#   Hashable, Awaitable, Coroutine, AsyncIterable, AsyncIterator,
#   AsyncGenerator, Iterable, Iterator, Reversible, Generator, Sized,
#   Container, Callable, Collection, Buffer (3.12)
# The collections, with their mixin methods:
#   Set           <= < >= > == & | - ^ (and reflected), isdisjoint, _hash,
#                 _from_iterable
#   MutableSet    remove, pop, clear, |= &= ^= -=
#   Mapping       get, __contains__, keys/items/values (views), ==
#   MappingView, KeysView, ItemsView, ValuesView
#   MutableMapping  pop, popitem, clear, update, setdefault
#   Sequence      __iter__, __contains__, __reversed__, index, count
#   MutableSequence  append, clear, reverse, extend, pop, remove, +=
#   ByteString    (deprecated in 3.12, as in CPython)
# Iterable[int], Mapping[str, int] ... are generic aliases;
# Callable[[int, str], float] has the flattened __args__ (int, str, float)
# and CPython's repr.
#
# Registered, as CPython does: tuple, str, range -> Sequence; list,
# bytearray -> MutableSequence; bytes, bytearray -> ByteString; dict ->
# MutableMapping; frozenset -> Set; set -> MutableSet; generators ->
# Generator, the lazy iterators -> Iterator, async generators ->
# AsyncGenerator (lib/abc.ny's stand-ins for the kinds without a type
# object); collections' own types are registered by lib/collections.
#
# Where the engines differ from CPython (so these answers differ):
#   - range(), dict.keys()/values()/items(), map(), zip() over lists and
#     filter() return lists, so they are MutableSequences (not KeysView,
#     ItemsView, ...); there are no distinct dict view or mappingproxy types
#     to register.
#   - Coroutine objects are task handles (ints), so a coroutine is not an
#     Awaitable/Coroutine instance; a class defining __await__ is.
#   - memoryview does not exist (not registered).
#   - A class that defines __eq__ without __hash__ is unhashable in Python
#     (its __hash__ is set to None); the engines do not do that, but
#     Hashable's check follows Python's rule.

from abc import ABCMeta, abstractmethod
from abc import _ny_namespace, _ny_mro, iterator as _ny_iterator, generator as _ny_generator
import sys

GenericAlias = type(list[int])
EllipsisType = type(...)

__all__ = ["Awaitable", "Coroutine",
           "AsyncIterable", "AsyncIterator", "AsyncGenerator",
           "Hashable", "Iterable", "Iterator", "Generator", "Reversible",
           "Sized", "Container", "Callable", "Collection",
           "Set", "MutableSet",
           "Mapping", "MutableMapping",
           "MappingView", "KeysView", "ItemsView", "ValuesView",
           "Sequence", "MutableSequence",
           "ByteString", "Buffer",
           ]


### ONE-TRICK PONIES ###

def _check_methods(C, *methods):
    var mro = _ny_mro(C)
    var nss = []     # the namespaces along the MRO, read as far as needed
    for method in methods:
        var found = False
        var i = 0
        while i < len(mro):
            if i == len(nss):
                nss.append(_ny_namespace(mro[i]))
            var ns = nss[i]
            i = i + 1
            if method in ns:
                if ns[method] is None:
                    return NotImplemented
                found = True
                break
            # Python sets __hash__ to None in a class that defines __eq__
            # and not __hash__
            if method == "__hash__" and "__eq__" in ns:
                return NotImplemented
        if not found:
            return NotImplemented
    return True


class Hashable(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __hash__(self):
        return 0

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Hashable:
            return _check_methods(C, "__hash__")
        return NotImplemented


class Awaitable(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __await__(self):
        yield

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Awaitable:
            return _check_methods(C, "__await__")
        return NotImplemented

    @classmethod
    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)


class Coroutine(Awaitable):

    __slots__ = ()

    @abstractmethod
    def send(self, value):
        """Send a value into the coroutine.
        Return next yielded value or raise StopIteration.
        """
        raise StopIteration

    @abstractmethod
    def throw(self, typ, val=None, tb=None):
        """Raise an exception in the coroutine.
        Return next yielded value or raise StopIteration.
        """
        if val is None:
            if tb is None:
                raise typ
            val = typ()
        raise val

    def close(self):
        """Raise GeneratorExit inside coroutine.
        """
        try:
            self.throw(GeneratorExit)
        except (GeneratorExit, StopIteration):
            pass
        else:
            raise RuntimeError("coroutine ignored GeneratorExit")

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Coroutine:
            return _check_methods(C, "__await__", "send", "throw", "close")
        return NotImplemented


class AsyncIterable(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __aiter__(self):
        return AsyncIterator()

    @classmethod
    def __subclasshook__(cls, C):
        if cls is AsyncIterable:
            return _check_methods(C, "__aiter__")
        return NotImplemented

    @classmethod
    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)


class AsyncIterator(AsyncIterable):

    __slots__ = ()

    @abstractmethod
    def __anext__(self):
        """Return the next item or raise StopAsyncIteration when exhausted."""
        raise StopAsyncIteration

    def __aiter__(self):
        return self

    @classmethod
    def __subclasshook__(cls, C):
        if cls is AsyncIterator:
            return _check_methods(C, "__anext__", "__aiter__")
        return NotImplemented


class AsyncGenerator(AsyncIterator):

    __slots__ = ()

    async def __anext__(self):
        """Return the next item from the asynchronous generator.
        When exhausted, raise StopAsyncIteration.
        """
        return await self.asend(None)

    @abstractmethod
    def asend(self, value):
        """Send a value into the asynchronous generator.
        Return next yielded value or raise StopAsyncIteration.
        """
        raise StopAsyncIteration

    @abstractmethod
    def athrow(self, typ, val=None, tb=None):
        """Raise an exception in the asynchronous generator.
        Return next yielded value or raise StopAsyncIteration.
        """
        if val is None:
            if tb is None:
                raise typ
            val = typ()
        raise val

    async def aclose(self):
        """Raise GeneratorExit inside coroutine.
        """
        try:
            await self.athrow(GeneratorExit)
        except (GeneratorExit, StopAsyncIteration):
            pass
        else:
            raise RuntimeError("asynchronous generator ignored GeneratorExit")

    @classmethod
    def __subclasshook__(cls, C):
        if cls is AsyncGenerator:
            return _check_methods(C, "__aiter__", "__anext__",
                                  "asend", "athrow", "aclose")
        return NotImplemented


class Iterable(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __iter__(self):
        while False:
            yield None

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Iterable:
            return _check_methods(C, "__iter__")
        return NotImplemented

    @classmethod
    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)


class Iterator(Iterable):

    __slots__ = ()

    @abstractmethod
    def __next__(self):
        "Return the next item from the iterator. When exhausted, raise StopIteration"
        raise StopIteration

    def __iter__(self):
        return self

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Iterator:
            return _check_methods(C, "__iter__", "__next__")
        return NotImplemented


Iterator.register(_ny_iterator)


class Reversible(Iterable):

    __slots__ = ()

    @abstractmethod
    def __reversed__(self):
        while False:
            yield None

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Reversible:
            return _check_methods(C, "__reversed__", "__iter__")
        return NotImplemented


class Generator(Iterator):

    __slots__ = ()

    def __next__(self):
        """Return the next item from the generator.
        When exhausted, raise StopIteration.
        """
        return self.send(None)

    @abstractmethod
    def send(self, value):
        """Send a value into the generator.
        Return next yielded value or raise StopIteration.
        """
        raise StopIteration

    @abstractmethod
    def throw(self, typ, val=None, tb=None):
        """Raise an exception in the generator.
        Return next yielded value or raise StopIteration.
        """
        if val is None:
            if tb is None:
                raise typ
            val = typ()
        raise val

    def close(self):
        """Raise GeneratorExit inside generator.
        """
        try:
            self.throw(GeneratorExit)
        except (GeneratorExit, StopIteration):
            pass
        else:
            raise RuntimeError("generator ignored GeneratorExit")

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Generator:
            return _check_methods(C, "__iter__", "__next__",
                                  "send", "throw", "close")
        return NotImplemented


Generator.register(_ny_generator)


class Sized(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __len__(self):
        return 0

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Sized:
            return _check_methods(C, "__len__")
        return NotImplemented


class Container(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __contains__(self, x):
        return False

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Container:
            return _check_methods(C, "__contains__")
        return NotImplemented

    @classmethod
    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)


class Collection(Sized, Iterable, Container):

    __slots__ = ()

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Collection:
            return _check_methods(C, "__len__", "__iter__", "__contains__")
        return NotImplemented


class Buffer(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __buffer__(self, flags, /):
        raise NotImplementedError

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Buffer:
            return _check_methods(C, "__buffer__")
        return NotImplemented


Buffer.register(bytes)
Buffer.register(bytearray)


class _CallableGenericAlias(GenericAlias):
    """ Represent `Callable[argtypes, resulttype]`.

    This sets ``__args__`` to a tuple containing the flattened ``argtypes``
    followed by ``resulttype``.

    Example: ``Callable[[int, str], float]`` sets ``__args__`` to
    ``(int, str, float)``.
    """

    def __init__(self, origin, args):
        if not (isinstance(args, tuple) and len(args) == 2):
            raise TypeError(
                "Callable must be used as Callable[[arg, ...], result].")
        var t_args = args[0]
        var t_result = args[1]
        if isinstance(t_args, (tuple, list)):
            args = tuple(list(t_args) + [t_result])
        elif not _is_param_expr(t_args):
            raise TypeError("Expected a list of types, an ellipsis, " +
                            "ParamSpec, or Concatenate. Got " + repr(t_args))
        super().__init__(origin, args)

    def __repr__(self):
        if len(self.__args__) == 2 and _is_param_expr(self.__args__[0]):
            return "collections.abc.Callable[" + _type_repr(self.__args__[0]) + ", " + _type_repr(self.__args__[1]) + "]"
        return ("collections.abc.Callable" +
                "[[" + ", ".join([_type_repr(a) for a in self.__args__[0:len(self.__args__) - 1]]) + "], " +
                _type_repr(self.__args__[len(self.__args__) - 1]) + "]")


def _is_param_expr(obj):
    """Checks if obj matches either a list of types, ``...``, ``ParamSpec`` or
    ``_ConcatenateGenericAlias`` from typing.py
    """
    if obj is Ellipsis:
        return True
    if isinstance(obj, list):
        return True
    var t = type(obj)
    var names = ("ParamSpec", "_ConcatenateGenericAlias")
    return getattr(t, "__module__", "") == "typing" and getattr(t, "__name__", "") in names


def _type_repr(obj):
    """Return the repr() of an object, special-casing types (internal helper).

    Copied from :mod:`typing` since collections.abc
    shouldn't depend on that module.
    """
    if isinstance(obj, GenericAlias):
        return repr(obj)
    if obj is Ellipsis:
        return "..."
    if isinstance(obj, type):
        if obj.__module__ == "builtins":
            return obj.__qualname__
        return obj.__module__ + "." + obj.__qualname__
    if isinstance(obj, "function"):
        return obj.__name__
    return repr(obj)


class Callable(metaclass=ABCMeta):

    __slots__ = ()

    @abstractmethod
    def __call__(self, *args, **kwds):
        return False

    @classmethod
    def __subclasshook__(cls, C):
        if cls is Callable:
            return _check_methods(C, "__call__")
        return NotImplemented

    @classmethod
    def __class_getitem__(cls, item):
        return _CallableGenericAlias(cls, item)


### SETS ###


class Set(Collection):
    """A set is a finite, iterable container.

    This class provides concrete generic implementations of all
    methods except for __contains__, __iter__ and __len__.

    To override the comparisons (presumably for speed, as the
    semantics are fixed), redefine __le__ and __ge__,
    then the other operations will automatically follow suit.
    """

    __slots__ = ()

    def __le__(self, other):
        if not isinstance(other, Set):
            return NotImplemented
        if len(self) > len(other):
            return False
        for elem in self:
            if elem not in other:
                return False
        return True

    def __lt__(self, other):
        if not isinstance(other, Set):
            return NotImplemented
        return len(self) < len(other) and self.__le__(other)

    def __gt__(self, other):
        if not isinstance(other, Set):
            return NotImplemented
        return len(self) > len(other) and self.__ge__(other)

    def __ge__(self, other):
        if not isinstance(other, Set):
            return NotImplemented
        if len(self) < len(other):
            return False
        for elem in other:
            if elem not in self:
                return False
        return True

    def __eq__(self, other):
        if not isinstance(other, Set):
            return NotImplemented
        return len(self) == len(other) and self.__le__(other)

    @classmethod
    def _from_iterable(cls, it):
        '''Construct an instance of the class from any iterable input.

        Must override this method if the class constructor signature
        does not accept an iterable for an input.
        '''
        return cls(it)

    def __and__(self, other):
        if not isinstance(other, Iterable):
            return NotImplemented
        return self._from_iterable(value for value in other if value in self)

    def __rand__(self, other):
        return self.__and__(other)

    def isdisjoint(self, other):
        "Return True if two sets have a null intersection."
        for value in other:
            if value in self:
                return False
        return True

    def __or__(self, other):
        if not isinstance(other, Iterable):
            return NotImplemented
        var chain = (e for s in (self, other) for e in s)
        return self._from_iterable(chain)

    def __ror__(self, other):
        return self.__or__(other)

    def __sub__(self, other):
        if not isinstance(other, Set):
            if not isinstance(other, Iterable):
                return NotImplemented
            other = self._from_iterable(other)
        return self._from_iterable(value for value in self
                                   if value not in other)

    def __rsub__(self, other):
        if not isinstance(other, Set):
            if not isinstance(other, Iterable):
                return NotImplemented
            other = self._from_iterable(other)
        return self._from_iterable(value for value in other
                                   if value not in self)

    def __xor__(self, other):
        if not isinstance(other, Set):
            if not isinstance(other, Iterable):
                return NotImplemented
            other = self._from_iterable(other)
        return (self - other) | (other - self)

    def __rxor__(self, other):
        return self.__xor__(other)

    def _hash(self):
        """Compute the hash value of a set.

        Note that we don't define __hash__: not all sets are hashable.
        But if you define a hashable set type, its __hash__ should
        call this function.

        This must be compatible __eq__.

        All sets ought to compare equal if they contain the same
        elements, regardless of how they are implemented, and
        regardless of the order of the elements; so there's not much
        freedom for __eq__ or __hash__.  We match the algorithm used
        by the built-in frozenset type.
        """
        var MAX = sys.maxsize
        var MASK = 2 * MAX + 1
        var n = len(self)
        var h = 1927868237 * (n + 1)
        h = h & MASK
        for x in self:
            var hx = hash(x)
            h = h ^ ((hx ^ (hx << 16) ^ 89869747) * 3644798167)
            h = h & MASK
        h = h ^ ((h >> 11) ^ (h >> 25))
        h = h * 69069 + 907133923
        h = h & MASK
        if h > MAX:
            h = h - (MASK + 1)
        if h == -1:
            h = 590923713
        return h


Set.register(frozenset)


class MutableSet(Set):
    """A mutable set is a finite, iterable container.

    This class provides concrete generic implementations of all
    methods except for __contains__, __iter__, __len__,
    add(), and discard().

    To override the comparisons (presumably for speed, as the
    semantics are fixed), all you have to do is redefine __le__ and
    then the other operations will automatically follow suit.
    """

    __slots__ = ()

    @abstractmethod
    def add(self, value):
        """Add an element."""
        raise NotImplementedError

    @abstractmethod
    def discard(self, value):
        """Remove an element.  Do not raise an exception if absent."""
        raise NotImplementedError

    def remove(self, value):
        """Remove an element. If not a member, raise a KeyError."""
        if value not in self:
            raise KeyError(value)
        self.discard(value)

    def pop(self):
        """Return the popped value.  Raise KeyError if empty."""
        var it = iter(self)
        var value = None
        try:
            value = next(it)
        except StopIteration:
            raise KeyError()
        self.discard(value)
        return value

    def clear(self):
        """This is slow (creates N new iterators!) but effective."""
        try:
            while True:
                self.pop()
        except KeyError:
            pass

    def __ior__(self, it):
        for value in it:
            self.add(value)
        return self

    def __iand__(self, it):
        for value in (self - it):
            self.discard(value)
        return self

    def __ixor__(self, it):
        if it is self:
            self.clear()
        else:
            if not isinstance(it, Set):
                it = self._from_iterable(it)
            for value in it:
                if value in self:
                    self.discard(value)
                else:
                    self.add(value)
        return self

    def __isub__(self, it):
        if it is self:
            self.clear()
        else:
            for value in it:
                self.discard(value)
        return self


MutableSet.register(set)


### MAPPINGS ###

class Mapping(Collection):
    """A Mapping is a generic container for associating key/value
    pairs.

    This class provides concrete generic implementations of all
    methods except for __getitem__, __iter__, and __len__.
    """

    __slots__ = ()

    # Tell ABCMeta.__new__ that this class should have TPFLAGS_MAPPING set.
    __abc_tpflags__ = 1 << 6 # Py_TPFLAGS_MAPPING

    @abstractmethod
    def __getitem__(self, key):
        raise KeyError

    def get(self, key, default=None):
        "D.get(k[,d]) -> D[k] if k in D, else d.  d defaults to None."
        try:
            return self[key]
        except KeyError:
            return default

    def __contains__(self, key):
        try:
            self[key]
        except KeyError:
            return False
        else:
            return True

    def keys(self):
        "D.keys() -> a set-like object providing a view on D's keys"
        return KeysView(self)

    def items(self):
        "D.items() -> a set-like object providing a view on D's items"
        return ItemsView(self)

    def values(self):
        "D.values() -> an object providing a view on D's values"
        return ValuesView(self)

    def __eq__(self, other):
        if not isinstance(other, Mapping):
            return NotImplemented
        return dict(list(self.items())) == dict(list(other.items()))

    __reversed__ = None


class MappingView(Sized):

    __slots__ = ("_mapping",)

    def __init__(self, mapping):
        self._mapping = mapping

    def __len__(self):
        return len(self._mapping)

    def __repr__(self):
        return type(self).__name__ + "(" + repr(self._mapping) + ")"

    @classmethod
    def __class_getitem__(cls, item):
        return GenericAlias(cls, item)


class KeysView(MappingView, Set):

    __slots__ = ()

    @classmethod
    def _from_iterable(cls, it):
        return set(it)

    def __contains__(self, key):
        return key in self._mapping

    def __iter__(self):
        yield from self._mapping


class ItemsView(MappingView, Set):

    __slots__ = ()

    @classmethod
    def _from_iterable(cls, it):
        return set(it)

    def __contains__(self, item):
        var key = item[0]
        var value = item[1]
        var v = None
        try:
            v = self._mapping[key]
        except KeyError:
            return False
        else:
            return v is value or v == value

    def __iter__(self):
        for key in self._mapping:
            yield (key, self._mapping[key])


class ValuesView(MappingView, Collection):

    __slots__ = ()

    def __contains__(self, value):
        for key in self._mapping:
            var v = self._mapping[key]
            if v is value or v == value:
                return True
        return False

    def __iter__(self):
        for key in self._mapping:
            yield self._mapping[key]


# MutableMapping.pop's "no default given"
class _MissingMarker:
    def __repr__(self):
        return "<marker>"

_marker = _MissingMarker()


class MutableMapping(Mapping):
    """A MutableMapping is a generic container for associating
    key/value pairs.

    This class provides concrete generic implementations of all
    methods except for __getitem__, __setitem__, __delitem__,
    __iter__, and __len__.
    """

    __slots__ = ()

    @abstractmethod
    def __setitem__(self, key, value):
        raise KeyError

    @abstractmethod
    def __delitem__(self, key):
        raise KeyError

    def pop(self, key, default=_marker):
        '''D.pop(k[,d]) -> v, remove specified key and return the corresponding value.
          If key is not found, d is returned if given, otherwise KeyError is raised.
        '''
        var value = None
        try:
            value = self[key]
        except KeyError:
            if default is _marker:
                raise
            return default
        else:
            del self[key]
            return value

    def popitem(self):
        '''D.popitem() -> (k, v), remove and return some (key, value) pair
           as a 2-tuple; but raise KeyError if D is empty.
        '''
        var key = None
        try:
            key = next(iter(self))
        except StopIteration:
            raise KeyError()
        var value = self[key]
        del self[key]
        return (key, value)

    def clear(self):
        "D.clear() -> None.  Remove all items from D."
        try:
            while True:
                self.popitem()
        except KeyError:
            pass

    def update(self, other=(), /, **kwds):
        ''' D.update([E, ]**F) -> None.  Update D from mapping/iterable E and F.
            If E present and has a .keys() method, does:     for k in E: D[k] = E[k]
            If E present and lacks .keys() method, does:     for (k, v) in E: D[k] = v
            In either case, this is followed by: for k, v in F.items(): D[k] = v
        '''
        if isinstance(other, Mapping):
            for key in other:
                self[key] = other[key]
        elif hasattr(other, "keys"):
            for key in other.keys():
                self[key] = other[key]
        else:
            for pair in other:
                self[pair[0]] = pair[1]
        for key in kwds:
            self[key] = kwds[key]

    def setdefault(self, key, default=None):
        "D.setdefault(k[,d]) -> D.get(k,d), also set D[k]=d if k not in D"
        try:
            return self[key]
        except KeyError:
            self[key] = default
        return default


MutableMapping.register(dict)


### SEQUENCES ###

class Sequence(Reversible, Collection):
    """All the operations on a read-only sequence.

    Concrete subclasses must override __new__ or __init__,
    __getitem__, and __len__.
    """

    __slots__ = ()

    # Tell ABCMeta.__new__ that this class should have TPFLAGS_SEQUENCE set.
    __abc_tpflags__ = 1 << 5 # Py_TPFLAGS_SEQUENCE

    @abstractmethod
    def __getitem__(self, index):
        raise IndexError

    def __iter__(self):
        var i = 0
        try:
            while True:
                var v = self[i]
                yield v
                i = i + 1
        except IndexError:
            return

    def __contains__(self, value):
        for v in self:
            if v is value or v == value:
                return True
        return False

    def __reversed__(self):
        for i in reversed(range(len(self))):
            yield self[i]

    def index(self, value, start=0, stop=None):
        '''S.index(value, [start, [stop]]) -> integer -- return first index of value.
           Raises ValueError if the value is not present.

           Supporting start and stop arguments is optional, but
           recommended.
        '''
        if start is not None and start < 0:
            start = max(len(self) + start, 0)
        if stop is not None and stop < 0:
            stop = stop + len(self)

        var i = start
        while stop is None or i < stop:
            var v = None
            try:
                v = self[i]
            except IndexError:
                break
            if v is value or v == value:
                return i
            i = i + 1
        raise ValueError

    def count(self, value):
        "S.count(value) -> integer -- return number of occurrences of value"
        return sum(1 for v in self if v is value or v == value)


Sequence.register(tuple)
Sequence.register(str)
Sequence.register(range)


class ByteString(Sequence):
    """This unifies bytes and bytearray.

    XXX Should add all their methods.
    """

    __slots__ = ()

ByteString.register(bytes)
ByteString.register(bytearray)


class MutableSequence(Sequence):
    """All the operations on a read-write sequence.

    Concrete subclasses must provide __new__ or __init__,
    __getitem__, __setitem__, __delitem__, __len__, and insert().
    """

    __slots__ = ()

    @abstractmethod
    def __setitem__(self, index, value):
        raise IndexError

    @abstractmethod
    def __delitem__(self, index):
        raise IndexError

    @abstractmethod
    def insert(self, index, value):
        "S.insert(index, value) -- insert value before index"
        raise IndexError

    def append(self, value):
        "S.append(value) -- append value to the end of the sequence"
        self.insert(len(self), value)

    def clear(self):
        "S.clear() -> None -- remove all items from S"
        try:
            while True:
                self.pop()
        except IndexError:
            pass

    def reverse(self):
        "S.reverse() -- reverse *IN PLACE*"
        var n = len(self)
        for i in range(n // 2):
            var a = self[i]
            var b = self[n - i - 1]
            self[i] = b
            self[n - i - 1] = a

    def extend(self, values):
        "S.extend(iterable) -- extend sequence by appending elements from the iterable"
        if values is self:
            values = list(values)
        for v in values:
            self.append(v)

    def pop(self, index=-1):
        '''S.pop([index]) -> item -- remove and return item at index (default last).
           Raise IndexError if list is empty or index is out of range.
        '''
        var v = self[index]
        del self[index]
        return v

    def remove(self, value):
        '''S.remove(value) -- remove first occurrence of value.
           Raise ValueError if the value is not present.
        '''
        del self[self.index(value)]

    def __iadd__(self, values):
        self.extend(values)
        return self


MutableSequence.register(list)
MutableSequence.register(bytearray)  # Multiply inheriting, see ByteString


# async generators: the prelude's class (CPython registers its type)
async def _ag():
    yield
AsyncGenerator.register(type(_ag()))
