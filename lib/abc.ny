# nython: module    (import it by name: it runs in a module scope of its own)
# lib/abc.ny - Python's abc: abstract base classes (PEP 3119), as CPython
# 3.12's Lib/abc.py over Lib/_py_abc.py (the pure-Python implementation of
# the C accelerator, with the same caches and the same messages).
#
#     from abc import ABC, ABCMeta, abstractmethod
#     class Shape(ABC):
#         @abstractmethod
#         def area(self): ...
#     Shape()          # TypeError: Can't instantiate abstract class Shape
#                      #   without an implementation for abstract method 'area'
#     Shape.register(tuple); isinstance((1, 2), Shape)    # True
#
# ABCMeta            a real metaclass. __new__ computes __abstractmethods__
#                    from the namespace and the bases (_py_abc's algorithm);
#                    a class with abstract methods cannot be instantiated
#                    (3.12's message, the names sorted); register(subclass)
#                    makes a virtual subclass (usable as a class decorator;
#                    "Refusing to create an inheritance cycle"; "Can only
#                    register classes"); __instancecheck__/__subclasscheck__
#                    ask __subclasshook__, then the real MRO, the registry
#                    and the subclasses, with a positive cache and a negative
#                    cache invalidated by every register() anywhere;
#                    _dump_registry, _abc_registry_clear, _abc_caches_clear
# ABC                a class to derive from (its metaclass is ABCMeta)
# abstractmethod     marks a function abstract; under @property,
#                    @classmethod and @staticmethod (abstractmethod
#                    innermost, as Python requires)
# abstractclassmethod, abstractstaticmethod, abstractproperty
#                    the deprecated aliases
# get_cache_token()  changes with every register()
# update_abstractmethods(cls)   recomputes __abstractmethods__ after methods
#                    were added to or implemented in a class
#
# isinstance(5, SomeABC) works for builtin values: type(5) is int. The kinds
# that have no type object here - None, functions, builtins, generators and
# lazy iterators (type() gives "none", "function", "builtin", "generator")
# - are represented by the stand-in classes NoneType, function,
# builtin_function_or_method, generator and iterator below (a generator has
# send(); a lazy iterator such as iter([1]) or zip() does not), so
# collections.abc's checks see what CPython's types define. The builtin
# types have no __dict__ here (int.__mro__ and int.__bases__ they have):
# _ny_namespace gives what CPython's int, str, list, ... define (CPython
# 3.11's tables), so collections.abc's __subclasshook__s inspect them as
# they inspect a class. A hook of your own that reads B.__dict__ for each B
# in C.__mro__ raises AttributeError for a builtin type C (use
# abc._ny_namespace(B), or register the builtin types).
#
# Nython only: abstractmethod also accepts a classmethod, staticmethod or
# property object (the decorator outermost), which Python refuses with
# AttributeError ("attribute '__isabstractmethod__' of 'classmethod' objects
# is not writable").
#
# Not here, or different:
#   - The check against instantiating an abstract class is made by
#     ABCMeta.__call__ (CPython makes it in object.__new__), so
#     object.__new__(AbstractClass) is not refused, and setting
#     __abstractmethods__ on a class whose metaclass is not ABCMeta has no
#     effect.
#   - The registry and the caches hold their classes strongly (CPython's
#     WeakSets): classes are not reclaimed by the engines anyway.
#   - abstractclassmethod / abstractstaticmethod / abstractproperty are
#     functions returning a classmethod / staticmethod / property (the
#     engines' descriptors cannot be subclassed), so isinstance(x,
#     abstractproperty) is not available.
#   - instance.__class__ overridden by a property is not consulted (only
#     type(instance)).

__all__ = ["ABCMeta", "ABC", "abstractmethod", "abstractclassmethod", "abstractstaticmethod",
           "abstractproperty", "get_cache_token", "update_abstractmethods"]


def abstractmethod(funcobj):
    """A decorator indicating abstract methods.

    Requires that the metaclass is ABCMeta or derived from it.  A
    class that has a metaclass derived from ABCMeta cannot be
    instantiated unless all of its abstract methods are overridden.
    The abstract methods can be called using any of the normal
    'super' call mechanisms.  abstractmethod() may be used to declare
    abstract methods for properties and descriptors.
    """
    funcobj.__isabstractmethod__ = True
    return funcobj


def abstractclassmethod(callable):
    """A decorator indicating abstract classmethods.

    Deprecated, use 'classmethod' with 'abstractmethod' instead.
    """
    callable.__isabstractmethod__ = True
    return classmethod(callable)


def abstractstaticmethod(callable):
    """A decorator indicating abstract staticmethods.

    Deprecated, use 'staticmethod' with 'abstractmethod' instead.
    """
    callable.__isabstractmethod__ = True
    return staticmethod(callable)


def abstractproperty(fget=None, fset=None, fdel=None, doc=None):
    """A decorator indicating abstract properties.

    Deprecated, use 'property' with 'abstractmethod' instead.
    """
    if fget is not None:
        fget.__isabstractmethod__ = True
    if fset is not None:
        return property(fget, fset)
    return property(fget)


# ── The kinds without a type object, and the builtin types' namespaces ──────
# Stand-ins for CPython's types of the values whose type() is a name string
# here. Never instantiated: their methods say what CPython's types define.
class NoneType:
    def __bool__(self):
        return False


class function:
    def __call__(self, *args, **kwargs):
        pass
    def __get__(self, instance, owner=None):
        pass


class builtin_function_or_method:
    def __call__(self, *args, **kwargs):
        pass


class iterator:
    # list_iterator, str_iterator, zip, map, ... (the engines' lazy iterators)
    def __iter__(self):
        return self
    def __next__(self):
        raise StopIteration


class generator:
    def __iter__(self):
        return self
    def __next__(self):
        raise StopIteration
    def send(self, value):
        raise StopIteration
    def throw(self, typ, val=None, tb=None):
        raise typ
    def close(self):
        pass


_standin_names = {"none": NoneType, "function": function, "builtin": builtin_function_or_method,
                  "generator": generator, "iterator": iterator}


def _ny_class_of(x):
    """The class isinstance(x, SomeABC) asks about: type(x), or the stand-in
    of a kind whose type() is a name string."""
    var t = type(x)
    if not isinstance(t, str):
        return t
    if t == "generator":
        # a lazy iterator (iter([1]), zip ...) is a "generator" kind too,
        # without send(); its repr is "<iterator object at ...>"
        return generator if repr(x).startswith("<generator") else iterator
    if t in _standin_names:
        return _standin_names[t]
    if callable(x):
        return function
    if isinstance(x, dict):
        return dict
    return object


_builtin_types = [object, bool, int, float, complex, str, bytes, bytearray, list, tuple, dict,
                  set, frozenset, type, range, slice]


def _is_builtin_type(t):
    for b in _builtin_types:
        if t is b:
            return True
    return False


def _is_type(x):
    # a class or a builtin type (what Python's isinstance(x, type) says)
    if isinstance(x, str):
        return False
    return isinstance(x, type) or _is_builtin_type(x)


def _ny_type_arg(x, message):
    # a class argument: a type, or a kind's name (type(None) is "none"
    # here) taken as its stand-in; anything else is the TypeError Python
    # raises
    if isinstance(x, str) and x in _standin_names:
        return _standin_names[x]
    if not _is_type(x):
        raise TypeError(message)
    return x


# What CPython 3.11's builtin types define (their __dict__ keys; __doc__
# left out). A builtin type has no __dict__ here.
_builtin_ns_text = {
    "object": "__class__ __delattr__ __dir__ __eq__ __format__ __ge__ __getattribute__ __getstate__ __gt__ __hash__ __init__ __init_subclass__ __le__ __lt__ __ne__ __new__ __reduce__ __reduce_ex__ __repr__ __setattr__ __sizeof__ __str__ __subclasshook__",
    "int": "__abs__ __add__ __and__ __bool__ __ceil__ __divmod__ __eq__ __float__ __floor__ __floordiv__ __format__ __ge__ __getattribute__ __getnewargs__ __gt__ __hash__ __index__ __int__ __invert__ __le__ __lshift__ __lt__ __mod__ __mul__ __ne__ __neg__ __new__ __or__ __pos__ __pow__ __radd__ __rand__ __rdivmod__ __repr__ __rfloordiv__ __rlshift__ __rmod__ __rmul__ __ror__ __round__ __rpow__ __rrshift__ __rshift__ __rsub__ __rtruediv__ __rxor__ __sizeof__ __sub__ __truediv__ __trunc__ __xor__ as_integer_ratio bit_count bit_length conjugate denominator from_bytes imag numerator real to_bytes",
    "bool": "__and__ __new__ __or__ __rand__ __repr__ __ror__ __rxor__ __xor__",
    "float": "__abs__ __add__ __bool__ __ceil__ __divmod__ __eq__ __float__ __floor__ __floordiv__ __format__ __ge__ __getattribute__ __getformat__ __getnewargs__ __gt__ __hash__ __int__ __le__ __lt__ __mod__ __mul__ __ne__ __neg__ __new__ __pos__ __pow__ __radd__ __rdivmod__ __repr__ __rfloordiv__ __rmod__ __rmul__ __round__ __rpow__ __rsub__ __rtruediv__ __sub__ __truediv__ __trunc__ as_integer_ratio conjugate fromhex hex imag is_integer real",
    "complex": "__abs__ __add__ __bool__ __complex__ __eq__ __format__ __ge__ __getattribute__ __getnewargs__ __gt__ __hash__ __le__ __lt__ __mul__ __ne__ __neg__ __new__ __pos__ __pow__ __radd__ __repr__ __rmul__ __rpow__ __rsub__ __rtruediv__ __sub__ __truediv__ conjugate imag real",
    "str": "__add__ __contains__ __eq__ __format__ __ge__ __getattribute__ __getitem__ __getnewargs__ __gt__ __hash__ __iter__ __le__ __len__ __lt__ __mod__ __mul__ __ne__ __new__ __repr__ __rmod__ __rmul__ __sizeof__ __str__ capitalize casefold center count encode endswith expandtabs find format format_map index isalnum isalpha isascii isdecimal isdigit isidentifier islower isnumeric isprintable isspace istitle isupper join ljust lower lstrip maketrans partition removeprefix removesuffix replace rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill",
    "bytes": "__add__ __bytes__ __contains__ __eq__ __ge__ __getattribute__ __getitem__ __getnewargs__ __gt__ __hash__ __iter__ __le__ __len__ __lt__ __mod__ __mul__ __ne__ __new__ __repr__ __rmod__ __rmul__ __str__ capitalize center count decode endswith expandtabs find fromhex hex index isalnum isalpha isascii isdigit islower isspace istitle isupper join ljust lower lstrip maketrans partition removeprefix removesuffix replace rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill",
    "bytearray": "__add__ __alloc__ __contains__ __delitem__ __eq__ __ge__ __getattribute__ __getitem__ __gt__ __hash__ __iadd__ __imul__ __init__ __iter__ __le__ __len__ __lt__ __mod__ __mul__ __ne__ __new__ __reduce__ __reduce_ex__ __repr__ __rmod__ __rmul__ __setitem__ __sizeof__ __str__ append capitalize center clear copy count decode endswith expandtabs extend find fromhex hex index insert isalnum isalpha isascii isdigit islower isspace istitle isupper join ljust lower lstrip maketrans partition pop remove removeprefix removesuffix replace reverse rfind rindex rjust rpartition rsplit rstrip split splitlines startswith strip swapcase title translate upper zfill",
    "list": "__add__ __class_getitem__ __contains__ __delitem__ __eq__ __ge__ __getattribute__ __getitem__ __gt__ __hash__ __iadd__ __imul__ __init__ __iter__ __le__ __len__ __lt__ __mul__ __ne__ __new__ __repr__ __reversed__ __rmul__ __setitem__ __sizeof__ append clear copy count extend index insert pop remove reverse sort",
    "tuple": "__add__ __class_getitem__ __contains__ __eq__ __ge__ __getattribute__ __getitem__ __getnewargs__ __gt__ __hash__ __iter__ __le__ __len__ __lt__ __mul__ __ne__ __new__ __repr__ __rmul__ count index",
    "dict": "__class_getitem__ __contains__ __delitem__ __eq__ __ge__ __getattribute__ __getitem__ __gt__ __hash__ __init__ __ior__ __iter__ __le__ __len__ __lt__ __ne__ __new__ __or__ __repr__ __reversed__ __ror__ __setitem__ __sizeof__ clear copy fromkeys get items keys pop popitem setdefault update values",
    "set": "__and__ __class_getitem__ __contains__ __eq__ __ge__ __getattribute__ __gt__ __hash__ __iand__ __init__ __ior__ __isub__ __iter__ __ixor__ __le__ __len__ __lt__ __ne__ __new__ __or__ __rand__ __reduce__ __repr__ __ror__ __rsub__ __rxor__ __sizeof__ __sub__ __xor__ add clear copy difference difference_update discard intersection intersection_update isdisjoint issubset issuperset pop remove symmetric_difference symmetric_difference_update union update",
    "frozenset": "__and__ __class_getitem__ __contains__ __eq__ __ge__ __getattribute__ __gt__ __hash__ __iter__ __le__ __len__ __lt__ __ne__ __new__ __or__ __rand__ __reduce__ __repr__ __ror__ __rsub__ __rxor__ __sizeof__ __sub__ __xor__ copy difference intersection isdisjoint issubset issuperset symmetric_difference union",
    "type": "__abstractmethods__ __annotations__ __base__ __bases__ __basicsize__ __call__ __delattr__ __dict__ __dictoffset__ __dir__ __flags__ __getattribute__ __init__ __instancecheck__ __itemsize__ __module__ __mro__ __name__ __new__ __or__ __prepare__ __qualname__ __repr__ __ror__ __setattr__ __sizeof__ __subclasscheck__ __subclasses__ __text_signature__ __weakrefoffset__ mro",
    "range": "__bool__ __contains__ __eq__ __ge__ __getattribute__ __getitem__ __gt__ __hash__ __iter__ __le__ __len__ __lt__ __ne__ __new__ __reduce__ __repr__ __reversed__ count index start step stop",
}
# the unhashable ones: their __hash__ is None
_builtin_unhashable = ["list", "dict", "set", "bytearray"]
_builtin_ns_cache = {}


def _builtin_namespace(name):
    if name in _builtin_ns_cache:
        return _builtin_ns_cache[name]
    var ns = {}
    if name in _builtin_ns_text:
        for n in _builtin_ns_text[name].split():
            ns[n] = None if (n == "__hash__" and name in _builtin_unhashable) else True
    _builtin_ns_cache[name] = ns
    return ns


def _ny_namespace(B):
    """B.__dict__ - for a builtin type, what CPython's defines (its methods
    as True, a name set to None as None)."""
    if B is object:
        # the prelude's object, with what CPython's object defines
        if "object" in _builtin_ns_cache:
            return _builtin_ns_cache["object"]
        var ns = dict(_builtin_namespace("object"))
        for k in object.__dict__:
            if not (k in ns):
                ns[k] = True
        _builtin_ns_cache["object"] = ns
        return ns
    try:
        return B.__dict__
    except AttributeError:
        pass
    if _is_builtin_type(B):
        return _builtin_namespace(B.__name__)
    return {}


def _ny_mro(C):
    """C.__mro__ - a builtin type's too (bool's is (bool, int, object))."""
    try:
        return C.__mro__
    except AttributeError:
        pass
    if C is bool:
        return (bool, int, object)
    if C is object:
        return (object,)
    return (C, object)


def _lookup_static(cls, name, nss):
    # getattr(cls, name, None) without running a descriptor: the first
    # namespace along the MRO that defines name (nss: those namespaces)
    for ns in nss:
        if name in ns:
            return ns[name]
    return getattr(cls, name, None)


def _abstract_set(cls, namespace, bases):
    var abstracts = set()
    for name in namespace:
        if getattr(namespace[name], "__isabstractmethod__", False):
            abstracts.add(name)
    var nss = None
    for base in bases:
        for name in getattr(base, "__abstractmethods__", ()):
            if nss is None:
                nss = [_ny_namespace(B) for B in _ny_mro(cls)]
            var value = _lookup_static(cls, name, nss)
            if getattr(value, "__isabstractmethod__", False):
                abstracts.add(name)
    return frozenset(abstracts)


def _abstract_error(cls, abstracts):
    var names = sorted(abstracts)
    var s = "s" if len(names) > 1 else ""
    raise TypeError("Can't instantiate abstract class " + cls.__name__ +
                    " without an implementation for abstract method" + s +
                    " '" + "', '".join(names) + "'")


def get_cache_token():
    """Returns the current ABC cache token.

    The token is an opaque object (supporting equality testing) identifying the
    current version of the ABC cache for virtual subclasses. The token changes
    with every call to ``register()`` on any ABC.
    """
    return ABCMeta._abc_invalidation_counter


class ABCMeta(type):
    """Metaclass for defining Abstract Base Classes (ABCs).

    Use this metaclass to create an ABC.  An ABC can be subclassed
    directly, and then acts as a mix-in class.  You can also register
    unrelated concrete classes (even built-in classes) and unrelated
    ABCs as 'virtual subclasses' -- these and their descendants will
    be considered subclasses of the registering ABC by the built-in
    issubclass() function, but the registering ABC won't show up in
    their MRO (Method Resolution Order) nor will method
    implementations defined by the registering ABC be callable (not
    even via super()).
    """

    # A global counter that is incremented each time a class is
    # registered as a virtual subclass of anything.  It forces the
    # negative cache to be cleared before its next use.
    _abc_invalidation_counter = 0

    def __new__(mcls, name, bases, namespace, /, **kwargs):
        var cls = super().__new__(mcls, name, bases, namespace, **kwargs)
        cls.__abstractmethods__ = _abstract_set(cls, namespace, bases)
        # Set up inheritance registry (a dict: registration order)
        cls._abc_registry = {}
        cls._abc_cache = set()
        cls._abc_negative_cache = set()
        cls._abc_negative_cache_version = ABCMeta._abc_invalidation_counter
        return cls

    def __call__(cls, *args, **kwargs):
        # CPython refuses an abstract class in object.__new__
        var abstracts = cls.__abstractmethods__
        if abstracts:
            _abstract_error(cls, abstracts)
        return super().__call__(*args, **kwargs)

    def register(cls, subclass):
        """Register a virtual subclass of an ABC.

        Returns the subclass, to allow usage as a class decorator.
        """
        subclass = _ny_type_arg(subclass, "Can only register classes")
        if issubclass(subclass, cls):
            return subclass  # Already a subclass
        # Subtle: test for cycles *after* testing for "already a subclass";
        # this means we allow X.register(X) and interpret it as a no-op.
        if issubclass(cls, subclass):
            # This would create a cycle, which is bad for the algorithm below
            raise RuntimeError("Refusing to create an inheritance cycle")
        cls._abc_registry[subclass] = True
        ABCMeta._abc_invalidation_counter = ABCMeta._abc_invalidation_counter + 1  # Invalidate negative cache
        return subclass

    def _dump_registry(cls, file=None):
        """Debug helper to print the ABC registry."""
        print("Class: " + cls.__module__ + "." + cls.__qualname__, file=file)
        print("Inv. counter: " + str(get_cache_token()), file=file)
        print("_abc_registry: " + _set_repr(list(cls._abc_registry.keys())), file=file)
        print("_abc_cache: " + _set_repr(list(cls._abc_cache)), file=file)
        print("_abc_negative_cache: " + _set_repr(list(cls._abc_negative_cache)), file=file)
        print("_abc_negative_cache_version: " + repr(cls._abc_negative_cache_version), file=file)

    def _abc_registry_clear(cls):
        """Clear the registry (for debugging or testing)."""
        cls._abc_registry = {}

    def _abc_caches_clear(cls):
        """Clear the caches (for debugging or testing)."""
        cls._abc_cache = set()
        cls._abc_negative_cache = set()

    def __instancecheck__(cls, instance):
        """Override for isinstance(instance, cls)."""
        # Inline the cache checking
        var subclass = _ny_class_of(instance)
        if subclass in cls._abc_cache:
            return True
        if (cls._abc_negative_cache_version == ABCMeta._abc_invalidation_counter and
                subclass in cls._abc_negative_cache):
            return False
        # Fall back to the subclass check.
        return cls.__subclasscheck__(subclass)

    def __subclasscheck__(cls, subclass):
        """Override for issubclass(subclass, cls)."""
        subclass = _ny_type_arg(subclass, "issubclass() arg 1 must be a class")
        # Check cache
        if subclass in cls._abc_cache:
            return True
        # Check negative cache; may have to invalidate
        if cls._abc_negative_cache_version < ABCMeta._abc_invalidation_counter:
            # Invalidate the negative cache
            cls._abc_negative_cache = set()
            cls._abc_negative_cache_version = ABCMeta._abc_invalidation_counter
        elif subclass in cls._abc_negative_cache:
            return False
        # Check the subclass hook (object's declines: a class that does not
        # name object as a base does not find the prelude's object here)
        var hook = getattr(cls, "__subclasshook__", None)
        var ok = NotImplemented if hook is None else hook(subclass)
        if ok is not NotImplemented:
            if not isinstance(ok, bool):
                raise AssertionError("__subclasshook__ must return True, False or NotImplemented")
            if ok:
                cls._abc_cache.add(subclass)
            else:
                cls._abc_negative_cache.add(subclass)
            return ok
        # Check if it's a direct subclass
        if cls in getattr(subclass, "__mro__", ()):
            cls._abc_cache.add(subclass)
            return True
        # Check if it's a subclass of a registered class (recursive)
        for rcls in list(cls._abc_registry.keys()):
            if issubclass(subclass, rcls):
                cls._abc_cache.add(subclass)
                return True
        # Check if it's a subclass of a subclass (recursive)
        for scls in cls.__subclasses__():
            if issubclass(subclass, scls):
                cls._abc_cache.add(subclass)
                return True
        # No dice; update negative cache
        cls._abc_negative_cache.add(subclass)
        return False


def _set_repr(items):
    if len(items) == 0:
        return "set()"
    return "{" + ", ".join([repr(x) for x in items]) + "}"


def update_abstractmethods(cls):
    """Recalculate the set of abstract methods of an abstract class.

    If a class has had one of its abstract methods implemented after the
    class was created, the method will not be considered implemented until
    this function is called. Alternatively, if a new abstract method has been
    added to the class, it will only be considered an abstract method of the
    class after this function is called.

    This function should be called before any use is made of the class,
    usually in class decorators that add methods to the subject class.

    Returns cls, to allow usage as a class decorator.

    If cls is not an instance of ABCMeta, does nothing.
    """
    if not hasattr(cls, "__abstractmethods__"):
        # We check for __abstractmethods__ here because cls might by a C
        # implementation or a python implementation (especially during
        # testing), and we want to handle both cases.
        return cls
    var abstracts = set()
    var nss = [_ny_namespace(B) for B in _ny_mro(cls)]
    # Check the existing abstract methods of the parents, keep only the ones
    # that are not implemented.
    for scls in cls.__bases__:
        for name in getattr(scls, "__abstractmethods__", ()):
            var value = _lookup_static(cls, name, nss)
            if getattr(value, "__isabstractmethod__", False):
                abstracts.add(name)
    # Also add any other newly added abstract methods.
    var own = nss[0]
    for name in own:
        if getattr(own[name], "__isabstractmethod__", False):
            abstracts.add(name)
    cls.__abstractmethods__ = frozenset(abstracts)
    return cls


class ABC(metaclass=ABCMeta):
    """Helper class that provides a standard way to create an ABC using
    inheritance.
    """
    __slots__ = ()
