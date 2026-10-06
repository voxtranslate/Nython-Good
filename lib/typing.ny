# nython: module    (import it by name: it runs in a module scope of its own)
# lib/typing.ny - Python's typing module (round 77), after CPython 3.11's
# typing.py: the same classes, algorithms, reprs and error messages, for
# everything below.
#
#     from typing import Optional, List, TypeVar, Generic, Protocol
#
# Special forms   Any NoReturn Never Self LiteralString ClassVar Final Union
#                 Optional Literal TypeAlias Concatenate TypeGuard Required
#                 NotRequired Unpack Annotated - reprs as CPython's
#                 (typing.Optional[int], typing.Union[int, str, NoneType],
#                 typing.Literal['a', 1], typing.Annotated[int, 'm'])
# Union           flattened, deduplicated, order-free ==, Union[X] is X,
#                 Optional[X] == Union[X, None], == to `X | Y`, | with
#                 everything here, isinstance(x, Union[int, str])
# Generic aliases List Dict Set FrozenSet Tuple Type Callable Iterable
#                 Iterator Sequence MutableSequence Mapping MutableMapping
#                 AbstractSet MutableSet Collection Container Sized Hashable
#                 Reversible Generator AsyncGenerator AsyncIterable
#                 AsyncIterator Awaitable Coroutine KeysView ItemsView
#                 ValuesView MappingView ByteString Deque DefaultDict
#                 OrderedDict Counter ChainMap ContextManager
#                 AsyncContextManager Pattern Match: subscriptable with
#                 CPython's arity checks, substitution (List[T][int]),
#                 Callable[[int], str] / Callable[..., T], Tuple[int, ...],
#                 isinstance(x, List) / issubclass(list, List), and calling
#                 List() raises as CPython does
# TypeVar         ~T +T_co -T_contra, bound / constraints / variance checks
# ParamSpec       P.args P.kwargs; TypeVarTuple, Unpack (repr *Ts)
# Generic         Generic[T, ...]; a subclass gets __parameters__ and
#                 __orig_bases__ (both engines record the bases as written)
#                 and is subscriptable (C[int] is an alias whose call makes
#                 a C, with __orig_class__)
# Protocol        structural isinstance()/issubclass() with
#                 @runtime_checkable, Protocol[T], "Protocols cannot be
#                 instantiated", SupportsInt/Float/Complex/Bytes/Index/
#                 Abs/Round
# NamedTuple      class syntax (annotations, defaults, methods, docstring)
#                 and NamedTuple("P", [("x", int)]) / NamedTuple("P", x=int):
#                 indexing, slicing, len, iteration and unpacking, ==/< with
#                 tuples, hash, _fields _field_defaults _asdict _replace
#                 _make __match_args__, repr P(x=1), immutable fields, the
#                 constructor's TypeErrors as CPython's generated __new__
# TypedDict       class syntax (total=, Required/NotRequired, inheritance)
#                 and the functional form; instances are plain dicts;
#                 __required_keys__ __optional_keys__ __total__
#                 __annotations__; is_typeddict
# NewType         typing's class: callable identity, __supertype__, repr
# ForwardRef      get_type_hints(obj, globalns, localns, include_extras):
#                 string annotations evaluated in the module the object was
#                 defined in (functions: __globals__; classes: their
#                 methods' module, the main program's for __main__), the
#                 MRO merged for classes, Annotated stripped unless
#                 include_extras; get_origin / get_args as CPython's
# cast assert_type reveal_type assert_never overload get_overloads
# clear_overloads final no_type_check no_type_check_decorator
# dataclass_transform override (3.12) TYPE_CHECKING Text AnyStr IO TextIO
# BinaryIO
#
# The NoneType that appears in __args__ is types.NoneType, which is
# type(None), as in CPython; the legacy name string "none" given to a form
# is taken as NoneType too (Nython only).
#
# Innovation: check_type(value, tp) - a runtime check of a value against an
# annotation, recursively (List[int], Dict[str, Optional[int]],
# Tuple[int, ...], Union, Literal, Callable, TypedDict keys, Annotated,
# NewType, TypeVar bounds/constraints), the subset of the typeguard /
# beartype idea that fits in a stdlib module; it returns None or raises
# TypeError naming the path to the first mismatch ("value[1]['k'] is str,
# not int"). Containers are checked fully (beartype samples one element;
# this is the exhaustive variant typeguard uses).
#
# Not here (honestly): a TypedDict class's MRO keeps TypedDict (CPython
# puts dict there); TypeVar / NewType __module__ is "typing" / "__main__"
# (the caller's module is not known without frames); the abstract origins
# (Iterable, Mapping...) are collections.abc's when lib/collections/abc.ny
# is present, otherwise stand-ins named like them that check the protocol
# structurally; Protocol members' signatures are not compared (as CPython);
# `*Ts` unpacking syntax in subscripts (the parser has no starred
# subscript) - use Unpack[Ts].

import types
import sys

__all__ = ["Annotated", "Any", "Callable", "ClassVar", "Concatenate", "Final", "ForwardRef",
           "Generic", "Literal", "Optional", "ParamSpec", "Protocol", "Tuple", "Type", "TypeVar",
           "TypeVarTuple", "Union", "AbstractSet", "ByteString", "Container", "ContextManager",
           "Hashable", "ItemsView", "Iterable", "Iterator", "KeysView", "Mapping", "MappingView",
           "MutableMapping", "MutableSequence", "MutableSet", "Sequence", "Sized", "ValuesView",
           "Awaitable", "AsyncIterator", "AsyncIterable", "Coroutine", "Collection",
           "AsyncGenerator", "AsyncContextManager", "Reversible", "SupportsAbs", "SupportsBytes",
           "SupportsComplex", "SupportsFloat", "SupportsIndex", "SupportsInt", "SupportsRound",
           "ChainMap", "Counter", "Deque", "Dict", "DefaultDict", "List", "OrderedDict", "Set",
           "FrozenSet", "NamedTuple", "TypedDict", "Generator", "BinaryIO", "IO", "Match",
           "Pattern", "TextIO", "AnyStr", "assert_type", "assert_never", "cast",
           "clear_overloads", "dataclass_transform", "final", "get_args", "get_origin",
           "get_overloads", "get_type_hints", "is_typeddict", "LiteralString", "Never", "NewType",
           "no_type_check", "no_type_check_decorator", "NoReturn", "NotRequired", "overload",
           "ParamSpecArgs", "ParamSpecKwargs", "Required", "reveal_type", "runtime_checkable",
           "Self", "Text", "TYPE_CHECKING", "TypeAlias", "TypeGuard", "Unpack", "override",
           "check_type"]

NoneType = types.NoneType


def _is_class(x):
    # isinstance(int, type) is false on this runtime; type(int) is type
    return isinstance(x, type) or type(x) is type


def _tname(x):
    if x is None:
        return "NoneType"
    return type(x).__name__


def _is(a, b):
    # identity: `x is C` with a class C on the right asks whether x is an
    # instance of C on this runtime, so an instance is never C itself here
    if _is_class(a) != _is_class(b):
        return False
    return a is b


def _pyrepr(v):
    # repr as CPython spells it (None, True, False - Nython's repr shows
    # none, true, false), into containers
    if v is None:
        return "None"
    if v is True:
        return "True"
    if v is False:
        return "False"
    if isinstance(v, tuple):
        if len(v) == 1:
            return "(" + _pyrepr(v[0]) + ",)"
        return "(" + ", ".join([_pyrepr(x) for x in v]) + ")"
    if isinstance(v, list):
        return "[" + ", ".join([_pyrepr(x) for x in v]) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join([_pyrepr(k) + ": " + _pyrepr(v[k]) for k in v]) + "}"
    return repr(v)


def _dget(d, k, default=None):
    # d.get(k, default) - but a dict read with `.` reads its key first here,
    # and a class namespace or keyword dict may hold a key named "get"
    if k in d:
        return d[k]
    return default


def _is_dunder(attr):
    return attr.startswith("__") and attr.endswith("__")


def _type_convert(arg, module=None, allow_special_forms=False):
    # None (and the runtime's type(None), the string "none") is NoneType,
    # a string is a ForwardRef
    if arg is None:
        return NoneType
    if isinstance(arg, str):
        if arg == "none":
            return NoneType
        return ForwardRef(arg, module=module, is_class=allow_special_forms)
    return arg


def _short_repr(x):
    var r = _pyrepr(x)
    return r[:100]


def _type_check(arg, msg, is_argument=True, module=None, allow_special_forms=False):
    # The argument as a type (None as NoneType, a string as a ForwardRef),
    # or TypeError for what cannot be one
    var invalid_generic_forms = [Generic, Protocol]
    if not allow_special_forms:
        invalid_generic_forms.append(ClassVar)
        if is_argument:
            invalid_generic_forms.append(Final)
    arg = _type_convert(arg, module, allow_special_forms)
    if isinstance(arg, _GenericAlias):
        for f in invalid_generic_forms:
            if arg.__origin__ is f:
                raise TypeError(str(arg) + " is not valid as type argument")
    if _is(arg, Any):
        return arg
    for f in [LiteralString, NoReturn, Never, Self, TypeAlias]:
        if arg is f:
            return arg
    if allow_special_forms and (arg is ClassVar or arg is Final):
        return arg
    if isinstance(arg, _SpecialForm) or _is(arg, Generic) or _is(arg, Protocol):
        raise TypeError("Plain " + str(arg) + " is not valid as type argument")
    if type(arg) is tuple:
        raise TypeError(msg + " Got " + _short_repr(arg) + ".")
    return arg


def _type_repr(obj):
    # A type as typing shows it inside [...]: builtins by name, other
    # classes module-qualified, ... and functions by name
    if isinstance(obj, types.GenericAlias):
        return repr(obj)
    if _is_class(obj):
        var m = getattr(obj, "__module__", "builtins")
        if m == "builtins":
            return obj.__qualname__
        return m + "." + obj.__qualname__
    if obj is Ellipsis:
        return "..."
    if isinstance(obj, types.FunctionType):
        return obj.__name__
    return repr(obj)


def _collect_parameters(args):
    # The type variables (TypeVar, ParamSpec, TypeVarTuple) in args, in
    # order of first appearance
    var parameters = []
    for t in args:
        if _is_class(t):
            continue
        if isinstance(t, tuple) or isinstance(t, list):
            for x in t:
                for c in _collect_parameters([x]):
                    if not _contains(parameters, c):
                        parameters.append(c)
        elif hasattr(t, "__typing_subst__"):
            if not _contains(parameters, t):
                parameters.append(t)
        else:
            for x in getattr(t, "__parameters__", ()):
                if not _contains(parameters, x):
                    parameters.append(x)
    return tuple(parameters)


def _contains(seq, x):
    for y in seq:
        if y is x or y == x:
            return True
    return False


def _check_generic(cls, parameters, elen):
    if not elen:
        raise TypeError(str(cls) + " is not a generic class")
    var alen = len(parameters)
    if alen != elen:
        raise TypeError("Too " + ("many" if alen > elen else "few") + " arguments for " + _cls_str(cls)
                        + "; actual " + str(alen) + ", expected " + str(elen))


def _cls_str(cls):
    return repr(cls) if _is_class(cls) else str(cls)


def _deduplicate(params):
    var out = []
    for p in params:
        if not _contains(out, p):
            out.append(p)
    return out


def _union_args(u):
    # the members of a typing Union or of an `X | Y` (whose None is NoneType here)
    var out = []
    for a in u.__args__:
        out.append(NoneType if a is None else a)
    return out


def _remove_dups_flatten(parameters):
    var params = []
    for p in parameters:
        if isinstance(p, _UnionGenericAlias) or isinstance(p, types.UnionType):
            params.extend(_union_args(p))
        else:
            params.append(p)
    return tuple(_deduplicate(params))


def _flatten_literal_params(parameters):
    var params = []
    for p in parameters:
        if isinstance(p, _LiteralGenericAlias):
            params.extend(p.__args__)
        else:
            params.append(p)
    return tuple(params)


def _value_and_type(parameters):
    return [(p, type(p)) for p in parameters]


def _eval_type(t, globalns, localns, recursive_guard=frozenset()):
    # t with every ForwardRef in it evaluated
    if isinstance(t, ForwardRef):
        return t._evaluate(globalns, localns, recursive_guard)
    if isinstance(t, _GenericAlias) or isinstance(t, types.GenericAlias) or isinstance(t, types.UnionType):
        var src_args = _union_args(t) if isinstance(t, types.UnionType) else list(t.__args__)
        var ev_args = []
        var changed = False
        for a in src_args:
            var a2 = ForwardRef(a) if isinstance(a, str) and isinstance(t, types.GenericAlias) else a
            var e = _eval_type(a2, globalns, localns, recursive_guard)
            if e is not a:
                changed = True
            ev_args.append(e)
        if not changed:
            return t
        if isinstance(t, types.GenericAlias):
            return types.GenericAlias(t.__origin__, tuple(ev_args))
        if isinstance(t, types.UnionType):
            return Union[tuple(ev_args)]
        return t.copy_with(tuple(ev_args))
    return t


# ── the special forms ────────────────────────────────────────────────────────
class _SpecialForm:
    # Any of typing's special constructs (Union, Optional, ClassVar, ...):
    # what subscripting it means is its _getitem
    def __init__(self, name, doc, getitem):
        self._name = name
        self.__doc__ = doc
        self._getitem = getitem
        self.__module__ = "typing"

    def __getattr__(self, item):
        if item == "__name__" or item == "__qualname__":
            return self._name
        raise AttributeError(item)

    def __mro_entries__(self, bases):
        raise TypeError("Cannot subclass " + repr(self))

    def __repr__(self):
        return "typing." + self._name

    def __reduce__(self):
        return self._name

    def __call__(self, *args, **kwds):
        raise TypeError("Cannot instantiate " + repr(self))

    def __or__(self, other):
        return Union[self, other]

    def __ror__(self, other):
        return Union[other, self]

    def __instancecheck__(self, obj):
        raise TypeError(str(self) + " cannot be used with isinstance()")

    def __subclasscheck__(self, cls):
        raise TypeError(str(self) + " cannot be used with issubclass()")

    def __getitem__(self, parameters):
        return self._getitem(self, parameters)

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return hash(self._name)


class _LiteralSpecialForm(_SpecialForm):
    def __getitem__(self, parameters):
        if not isinstance(parameters, tuple):
            parameters = (parameters,)
        return self._getitem(self, *parameters)


class _AnyMeta(type):
    def __instancecheck__(self, obj):
        if self is Any:
            raise TypeError("typing.Any cannot be used with isinstance()")
        for c in getattr(type(obj), "__mro__", ()):
            if c is self:
                return True
        return False
    def __repr__(self):
        if self is Any:
            return "typing.Any"
        return "<class '" + self.__module__ + "." + self.__qualname__ + "'>"
    def __call__(cls, *args, **kwargs):
        if cls is Any:
            raise TypeError("Any cannot be instantiated")
        return super().__call__(*args, **kwargs)


class Any(metaclass=_AnyMeta):
    """Special type indicating an unconstrained type."""
    pass


def _not_subscriptable(self, parameters):
    raise TypeError(str(self) + " is not subscriptable")


def _single_type(self, parameters):
    var item = _type_check(parameters, str(self) + " accepts only single type.")
    return _GenericAlias(self, (item,))


def _single_type_named(self, parameters):
    var item = _type_check(parameters, self._name + " accepts only a single type.")
    return _GenericAlias(self, (item,))


def _union_getitem(self, parameters):
    if parameters == ():
        raise TypeError("Cannot take a Union of no types.")
    if not isinstance(parameters, tuple):
        parameters = (parameters,)
    var msg = "Union[arg, ...]: each arg must be a type."
    parameters = tuple([_type_check(p, msg) for p in parameters])
    parameters = _remove_dups_flatten(parameters)
    if len(parameters) == 1:
        return parameters[0]
    if len(parameters) == 2 and _contains(parameters, NoneType):
        return _UnionGenericAlias(self, parameters, name="Optional")
    return _UnionGenericAlias(self, parameters)


def _optional_getitem(self, parameters):
    var arg = _type_check(parameters, str(self) + " requires a single type.")
    return Union[arg, NoneType]


def _literal_getitem(self, *parameters):
    parameters = _flatten_literal_params(parameters)
    var seen = []
    var out = []
    for p in parameters:
        var key = (p, type(p))
        var dup = False
        for s in seen:
            if s[0] == key[0] and s[1] == key[1]:
                dup = True
                break
        if not dup:
            seen.append(key)
            out.append(p)
    return _LiteralGenericAlias(self, tuple(out))


def _concatenate_getitem(self, parameters):
    if parameters == ():
        raise TypeError("Cannot take a Concatenate of no types.")
    if not isinstance(parameters, tuple):
        parameters = (parameters,)
    if not (parameters[-1] is Ellipsis or isinstance(parameters[-1], ParamSpec)):
        raise TypeError("The last parameter to Concatenate should be a ParamSpec variable or ellipsis.")
    var msg = "Concatenate[arg, ...]: each arg must be a type."
    var ps = [_type_check(p, msg) for p in parameters[:-1]]
    ps.append(parameters[-1])
    return _ConcatenateGenericAlias(self, tuple(ps), _paramspec_tvars=True)


def _unpack_getitem(self, parameters):
    var item = _type_check(parameters, str(self) + " accepts only single type.")
    return _UnpackGenericAlias(self, (item,))


NoReturn = _SpecialForm("NoReturn", "Special type indicating functions that never return.", _not_subscriptable)
Never = _SpecialForm("Never", "The bottom type, a type that has no members.", _not_subscriptable)
Self = _SpecialForm("Self", "Used to spell the type of \"self\" in classes.", _not_subscriptable)
LiteralString = _SpecialForm("LiteralString", "Represents an arbitrary literal string.", _not_subscriptable)
ClassVar = _SpecialForm("ClassVar", "Special type construct to mark class variables.", _single_type)
Final = _SpecialForm("Final", "Special typing construct to indicate final names to type checkers.", _single_type)
Union = _SpecialForm("Union", "Union type; Union[X, Y] means either X or Y.", _union_getitem)
Optional = _SpecialForm("Optional", "Optional type; Optional[X] is equivalent to Union[X, None].", _optional_getitem)
Literal = _LiteralSpecialForm("Literal", "Special typing form to define literal types (a.k.a. value types).", _literal_getitem)
TypeAlias = _SpecialForm("TypeAlias", "Special form for marking type aliases.", _not_subscriptable)
Concatenate = _SpecialForm("Concatenate", "Used in conjunction with ParamSpec and Callable to represent a higher order function.", _concatenate_getitem)
TypeGuard = _SpecialForm("TypeGuard", "Special typing construct for marking user-defined type guard functions.", _single_type)
Required = _SpecialForm("Required", "Special typing construct to mark a TypedDict key as required.", _single_type_named)
NotRequired = _SpecialForm("NotRequired", "Special typing construct to mark a TypedDict key as potentially missing.", _single_type_named)
Unpack = _SpecialForm("Unpack", "Type unpack operator.", _unpack_getitem)


# ── ForwardRef ───────────────────────────────────────────────────────────────
class ForwardRef:
    # An annotation kept as its source text, evaluated by get_type_hints
    def __init__(self, arg, is_argument=True, module=None, *, is_class=False):
        if not isinstance(arg, str):
            raise TypeError("Forward reference must be a string -- got " + repr(arg))
        var src = "(" + arg + ",)[0]" if arg.startswith("*") else arg
        try:
            compile(src, "<string>", "eval")
        except SyntaxError:
            raise SyntaxError("Forward reference must be an expression -- got " + repr(arg))
        self.__forward_arg__ = arg
        self.__forward_code__ = src
        self.__forward_evaluated__ = False
        self.__forward_value__ = None
        self.__forward_is_argument__ = is_argument
        self.__forward_is_class__ = is_class
        self.__forward_module__ = module

    def _evaluate(self, globalns, localns, recursive_guard=frozenset()):
        if self.__forward_arg__ in recursive_guard:
            return self
        if not self.__forward_evaluated__ or localns is not globalns:
            if globalns is None and localns is None:
                globalns = {}
                localns = globalns
            elif globalns is None:
                globalns = localns
            elif localns is None:
                localns = globalns
            var value = eval(self.__forward_code__, globalns, localns)
            var type_ = _type_check(value, "Forward references must evaluate to types.",
                                    self.__forward_is_argument__, None, self.__forward_is_class__)
            var guard = set(recursive_guard)
            guard.add(self.__forward_arg__)
            self.__forward_value__ = _eval_type(type_, globalns, localns, frozenset(guard))
            self.__forward_evaluated__ = True
        return self.__forward_value__

    def __eq__(self, other):
        if not isinstance(other, ForwardRef):
            return NotImplemented
        if self.__forward_evaluated__ and other.__forward_evaluated__:
            return self.__forward_arg__ == other.__forward_arg__ and self.__forward_value__ == other.__forward_value__
        return self.__forward_arg__ == other.__forward_arg__ and self.__forward_module__ == other.__forward_module__

    def __hash__(self):
        return hash((self.__forward_arg__, self.__forward_module__))

    def __or__(self, other):
        return Union[self, other]

    def __ror__(self, other):
        return Union[other, self]

    def __repr__(self):
        var module_repr = "" if self.__forward_module__ is None else ", module=" + repr(self.__forward_module__)
        return "ForwardRef(" + repr(self.__forward_arg__) + module_repr + ")"


# ── type variables ───────────────────────────────────────────────────────────
class _BoundVarianceMixin:
    def _init_bound(self, bound, covariant, contravariant):
        if covariant and contravariant:
            raise ValueError("Bivariant types are not supported.")
        self.__covariant__ = bool(covariant)
        self.__contravariant__ = bool(contravariant)
        if bound:
            self.__bound__ = _type_check(bound, "Bound must be a type.")
        else:
            self.__bound__ = None

    def __or__(self, right):
        return Union[self, right]

    def __ror__(self, left):
        return Union[left, self]

    def __repr__(self):
        var prefix = "~"
        if self.__covariant__:
            prefix = "+"
        elif self.__contravariant__:
            prefix = "-"
        return prefix + self.__name__

    def __reduce__(self):
        return self.__name__

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return id(self)


class TypeVar(_BoundVarianceMixin):
    """Type variable."""
    def __init__(self, name, *constraints, bound=None, covariant=False, contravariant=False):
        self.__name__ = name
        self._init_bound(bound, covariant, contravariant)
        if constraints and bound is not None:
            raise TypeError("Constraints cannot be combined with bound=...")
        if constraints and len(constraints) == 1:
            raise TypeError("A single constraint is not allowed")
        var msg = "TypeVar(name, constraint, ...): constraints must be types."
        self.__constraints__ = tuple([_type_check(t, msg) for t in constraints])
        self.__module__ = "typing"

    def __typing_subst__(self, arg):
        var msg = "Parameters to generic types must be types."
        arg = _type_check(arg, msg, True)
        if isinstance(arg, _GenericAlias) and arg.__origin__ is Unpack:
            raise TypeError(str(arg) + " is not valid as type argument")
        return arg

    def __init_subclass__(cls, *args, **kwargs):
        raise TypeError("type 'TypeVar' is not an acceptable base type")


class TypeVarTuple:
    """Type variable tuple."""
    def __init__(self, name):
        self.__name__ = name
        self.__module__ = "typing"

    def __iter__(self):
        return iter([Unpack[self]])

    def __repr__(self):
        return self.__name__

    def __typing_subst__(self, arg):
        raise TypeError("Substitution of bare TypeVarTuple is not supported")

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return id(self)


class ParamSpecArgs:
    """The args for a ParamSpec object."""
    def __init__(self, origin):
        self.__origin__ = origin

    def __repr__(self):
        return self.__origin__.__name__ + ".args"

    def __eq__(self, other):
        if not isinstance(other, ParamSpecArgs):
            return NotImplemented
        return self.__origin__ is other.__origin__

    def __hash__(self):
        return hash(id(self.__origin__)) + 1


class ParamSpecKwargs:
    """The kwargs for a ParamSpec object."""
    def __init__(self, origin):
        self.__origin__ = origin

    def __repr__(self):
        return self.__origin__.__name__ + ".kwargs"

    def __eq__(self, other):
        if not isinstance(other, ParamSpecKwargs):
            return NotImplemented
        return self.__origin__ is other.__origin__

    def __hash__(self):
        return hash(id(self.__origin__)) + 2


class ParamSpec(_BoundVarianceMixin):
    """Parameter specification variable."""
    def __init__(self, name, *, bound=None, covariant=False, contravariant=False):
        self.__name__ = name
        self._init_bound(bound, covariant, contravariant)
        self.__module__ = "typing"

    @property
    def args(self):
        return ParamSpecArgs(self)

    @property
    def kwargs(self):
        return ParamSpecKwargs(self)

    def __typing_subst__(self, arg):
        if isinstance(arg, list) or isinstance(arg, tuple):
            arg = tuple([_type_check(a, "Expected a type.") for a in arg])
        elif not _is_param_expr(arg):
            raise TypeError("Expected a list of types, an ellipsis, ParamSpec, or Concatenate. Got " + str(arg))
        return arg


def _is_param_expr(arg):
    return arg is Ellipsis or isinstance(arg, tuple) or isinstance(arg, list) or isinstance(arg, ParamSpec) or isinstance(arg, _ConcatenateGenericAlias)


# ── generic aliases ──────────────────────────────────────────────────────────
class _BaseGenericAlias:
    # A generic version of type `origin`
    def _init_base(self, origin, inst=True, name=None):
        self._inst = inst
        self._name = name
        if origin is not None:
            self.__origin__ = origin

    def __call__(self, *args, **kwargs):
        if not self._inst:
            raise TypeError("Type " + self._name + " cannot be instantiated; use " + self.__origin__.__name__ + "() instead")
        var result = self.__origin__(*args, **kwargs)
        try:
            result.__orig_class__ = self
        except Exception:
            pass
        return result

    def __mro_entries__(self, bases):
        var res = []
        if not _contains(bases, self.__origin__):
            res.append(self.__origin__)
        var i = _index_of(bases, self)
        var add_generic = True
        for b in bases[i + 1:]:
            if isinstance(b, _BaseGenericAlias) or (_is_class(b) and issubclass(b, Generic)):
                add_generic = False
                break
        if add_generic:
            res.append(Generic)
        return tuple(res)

    def __getattr__(self, attr):
        if attr == "__name__" or attr == "__qualname__":
            return self._name or self.__origin__.__name__
        if attr == "__origin__" and isinstance(_dget(self.__dict__, "_ny_lazy_origin"), str):
            var o = _resolve_origin(self.__dict__["_ny_lazy_origin"])
            object.__setattr__(self, "__origin__", o)
            return o
        if not _is_dunder(attr) and not attr.startswith("_ny_") and attr not in ("_name", "_inst", "_nparams", "_paramspec_tvars"):
            return getattr(self.__origin__, attr)
        raise AttributeError(attr)

    def __instancecheck__(self, obj):
        return self.__subclasscheck__(type(obj))

    def __subclasscheck__(self, cls):
        raise TypeError("Subscripted generics cannot be used with class and instance checks")


def _index_of(seq, x):
    for i in range(len(seq)):
        if seq[i] is x:
            return i
    return -1


class _GenericAlias(_BaseGenericAlias):
    # List[int], Callable[[int], str], C[int] (C a Generic subclass) ...
    def __init__(self, origin, args, *, inst=True, name=None, _paramspec_tvars=False):
        self._init_base(origin, inst, name)
        if not isinstance(args, tuple):
            args = (args,)
        self.__args__ = tuple([Ellipsis if a is _TypingEllipsis else a for a in args])
        self.__parameters__ = _collect_parameters(args)
        self._paramspec_tvars = _paramspec_tvars
        if not name:
            self.__module__ = getattr(origin, "__module__", "typing")
        else:
            self.__module__ = "typing"

    def __eq__(self, other):
        if not isinstance(other, _GenericAlias):
            return NotImplemented
        return self.__origin__ == other.__origin__ and self.__args__ == other.__args__

    def __ne__(self, other):
        var r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    def __hash__(self):
        return hash(repr(self))

    def __or__(self, right):
        return Union[self, right]

    def __ror__(self, left):
        return Union[left, self]

    def __getitem__(self, args):
        if self.__origin__ is Generic or self.__origin__ is Protocol:
            raise TypeError("Cannot subscript already-subscripted " + str(self))
        if not self.__parameters__:
            raise TypeError(str(self) + " is not a generic class")
        if not isinstance(args, tuple):
            args = (args,)
        args = tuple([_type_convert(p) for p in args])
        var new_args = self._determine_new_args(args)
        return self.copy_with(new_args)

    def _determine_new_args(self, args):
        var params = self.__parameters__
        var alen = len(args)
        var plen = len(params)
        if len(params) == 1 and isinstance(params[0], ParamSpec) and not _is_param_expr(args[0] if alen else None):
            args = (args,)
            alen = 1
        if alen != plen:
            raise TypeError("Too " + ("many" if alen > plen else "few") + " arguments for " + str(self)
                            + "; actual " + str(alen) + ", expected " + str(plen))
        var pairs = [(params[i], args[i]) for i in range(plen)]
        return tuple(self._make_substitution(self.__args__, pairs))

    def _make_substitution(self, args, pairs):
        var new_args = []
        for old_arg in args:
            if _is_class(old_arg):
                new_args.append(old_arg)
                continue
            var new_arg = old_arg
            if hasattr(old_arg, "__typing_subst__"):
                new_arg = old_arg.__typing_subst__(_lookup_pair(pairs, old_arg))
            else:
                var subparams = getattr(old_arg, "__parameters__", ())
                if subparams:
                    var subargs = [_lookup_pair(pairs, x) for x in subparams]
                    new_arg = old_arg[tuple(subargs)]
            if self._name == "Callable" and isinstance(new_arg, tuple):
                new_args.extend(new_arg)
            elif isinstance(old_arg, tuple):
                new_args.append(tuple(self._make_substitution(old_arg, pairs)))
            else:
                new_args.append(new_arg)
        return new_args

    def copy_with(self, args):
        return type(self)(self.__origin__, args, name=self._name, inst=self._inst, _paramspec_tvars=self._paramspec_tvars)

    def __repr__(self):
        var name = "typing." + self._name if self._name else _type_repr(self.__origin__)
        var args = ", ".join([_type_repr(a) for a in self.__args__]) if self.__args__ else "()"
        return name + "[" + args + "]"

    def __mro_entries__(self, bases):
        if isinstance(self.__origin__, _SpecialForm):
            raise TypeError("Cannot subclass " + repr(self))
        if self._name:
            return _BaseGenericAlias.__mro_entries__(self, bases)
        if self.__origin__ is Generic:
            if _contains(bases, Protocol):
                return ()
            var i = _index_of(bases, self)
            for b in bases[i + 1:]:
                if isinstance(b, _BaseGenericAlias) and b is not self:
                    return ()
        return (self.__origin__,)

    def __iter__(self):
        return iter([Unpack[self]])


def _lookup_pair(pairs, key):
    for p in pairs:
        if p[0] is key:
            return p[1]
    raise KeyError(key)


class _TypingEllipsis:
    """Internal placeholder for ... (ellipsis)."""


class _SpecialGenericAlias(_BaseGenericAlias):
    # List, Dict, Iterable, ... unsubscripted
    def __init__(self, origin, nparams, *, inst=True, name=None):
        if isinstance(origin, str):
            # resolved on first use (collections.abc, contextlib, re load late)
            object.__setattr__(self, "_ny_lazy_origin", origin)
            self._init_base(None, inst, name)
        else:
            if name is None:
                name = origin.__name__
            self._init_base(origin, inst, name)
        self._nparams = nparams
        self.__module__ = "typing"

    def __getitem__(self, params):
        if not isinstance(params, tuple):
            params = (params,)
        var msg = "Parameters to generic types must be types."
        params = tuple([_type_check(p, msg) for p in params])
        _check_generic(self, params, self._nparams)
        return self.copy_with(params)

    def copy_with(self, params):
        return _GenericAlias(self.__origin__, params, name=self._name, inst=self._inst)

    def __repr__(self):
        return "typing." + self._name

    def __instancecheck__(self, obj):
        return isinstance(obj, self.__origin__)

    def __subclasscheck__(self, cls):
        if isinstance(cls, _SpecialGenericAlias):
            return issubclass(cls.__origin__, self.__origin__)
        if not isinstance(cls, _GenericAlias):
            return issubclass(cls, self.__origin__)
        raise TypeError("Subscripted generics cannot be used with class and instance checks")

    def __reduce__(self):
        return self._name

    def __or__(self, right):
        return Union[self, right]

    def __ror__(self, left):
        return Union[left, self]

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return hash(self._name)


class _CallableGenericAlias(_GenericAlias):
    def __repr__(self):
        var args = self.__args__
        if len(args) == 2 and _is_param_expr(args[0]):
            return _GenericAlias.__repr__(self)
        return ("typing.Callable[[" + ", ".join([_type_repr(a) for a in args[:-1]]) + "], "
                + _type_repr(args[-1]) + "]")


class _CallableType(_SpecialGenericAlias):
    def copy_with(self, params):
        return _CallableGenericAlias(self.__origin__, params, name=self._name, inst=self._inst, _paramspec_tvars=True)

    def __getitem__(self, params):
        if not isinstance(params, tuple) or len(params) != 2:
            raise TypeError("Callable must be used as Callable[[arg, ...], result].")
        var args = params[0]
        var result = params[1]
        if isinstance(args, list):
            args = tuple(args)
        result = _type_check(result, "Callable[args, result]: result must be a type.")
        if args is Ellipsis:
            return self.copy_with((_TypingEllipsis, result))
        if not isinstance(args, tuple):
            args = (args,)
        args = tuple([_type_convert(a) for a in args])
        return self.copy_with(args + (result,))

    def __instancecheck__(self, obj):
        return callable(obj)

    def __subclasscheck__(self, cls):
        if isinstance(cls, _GenericAlias):
            raise TypeError("Subscripted generics cannot be used with class and instance checks")
        return callable(cls) and hasattr(cls, "__call__")


class _TupleType(_SpecialGenericAlias):
    def __getitem__(self, params):
        if not isinstance(params, tuple):
            params = (params,)
        if len(params) >= 2 and params[-1] is Ellipsis:
            var msg = "Tuple[t, ...]: t must be a type."
            var ps = tuple([_type_check(p, msg) for p in params[:-1]])
            return self.copy_with(ps + (_TypingEllipsis,))
        var msg2 = "Tuple[t0, t1, ...]: each t must be a type."
        return self.copy_with(tuple([_type_check(p, msg2) for p in params]))


class _UnionGenericAlias(_GenericAlias):
    def copy_with(self, params):
        return Union[params]

    def __eq__(self, other):
        if not isinstance(other, _UnionGenericAlias) and not isinstance(other, types.UnionType):
            return NotImplemented
        var a = list(self.__args__)
        var b = _union_args(other)
        if len(_deduplicate(a)) != len(_deduplicate(b)):
            return False
        for x in a:
            if not _contains(b, x):
                return False
        return True

    def __hash__(self):
        var h = 0
        for a in self.__args__:
            h = h ^ hash(a)
        return h

    def __repr__(self):
        var args = self.__args__
        if len(args) == 2:
            if args[0] is NoneType:
                return "typing.Optional[" + _type_repr(args[1]) + "]"
            elif args[1] is NoneType:
                return "typing.Optional[" + _type_repr(args[0]) + "]"
        return _GenericAlias.__repr__(self)

    def __instancecheck__(self, obj):
        for arg in self.__args__:
            if isinstance(arg, _GenericAlias) and not isinstance(arg, _UnionGenericAlias):
                raise TypeError("Subscripted generics cannot be used with class and instance checks")
            if isinstance(obj, arg):
                return True
        return False

    def __subclasscheck__(self, cls):
        for arg in self.__args__:
            if issubclass(cls, arg):
                return True
        return False


class _LiteralGenericAlias(_GenericAlias):
    def __eq__(self, other):
        if not isinstance(other, _LiteralGenericAlias):
            return NotImplemented
        var a = _value_and_type(self.__args__)
        var b = _value_and_type(other.__args__)
        if len(a) != len(b):
            return False
        for x in a:
            var found = False
            for y in b:
                if x[0] == y[0] and x[1] == y[1]:
                    found = True
                    break
            if not found:
                return False
        return True

    def __hash__(self):
        var h = 0
        for a in self.__args__:
            h = h ^ hash(repr(a))
        return h

    def __repr__(self):
        return "typing.Literal[" + ", ".join([_pyrepr(a) for a in self.__args__]) + "]"


class _ConcatenateGenericAlias(_GenericAlias):
    def copy_with(self, params):
        if isinstance(params[-1], list) or isinstance(params[-1], tuple):
            return tuple(list(params[:-1]) + list(params[-1]))
        if isinstance(params[-1], _ConcatenateGenericAlias):
            params = tuple(list(params[:-1]) + list(params[-1].__args__))
        return _GenericAlias.copy_with(self, params)


class _UnpackGenericAlias(_GenericAlias):
    def __repr__(self):
        return "*" + repr(self.__args__[0])

    @property
    def __typing_is_unpacked_typevartuple__(self):
        return isinstance(self.__args__[0], TypeVarTuple)


class _AnnotatedAlias(_GenericAlias):
    # Annotated[T, meta, ...]: T with metadata
    def __init__(self, origin, metadata):
        if isinstance(origin, _AnnotatedAlias):
            metadata = origin.__metadata__ + metadata
            origin = origin.__origin__
        _GenericAlias.__init__(self, origin, origin)
        self.__metadata__ = metadata

    def copy_with(self, params):
        return _AnnotatedAlias(params[0], self.__metadata__)

    def __repr__(self):
        return "typing.Annotated[" + _type_repr(self.__origin__) + ", " + ", ".join([_pyrepr(a) for a in self.__metadata__]) + "]"

    def __eq__(self, other):
        if not isinstance(other, _AnnotatedAlias):
            return NotImplemented
        return self.__origin__ == other.__origin__ and self.__metadata__ == other.__metadata__

    def __hash__(self):
        return hash(repr(self))

    def __getattr__(self, attr):
        if attr == "__name__" or attr == "__qualname__":
            return "Annotated"
        return _BaseGenericAlias.__getattr__(self, attr)


class _AnnotatedMeta(type):
    def __repr__(cls):
        return "typing.Annotated"
    def __call__(cls, *args, **kwargs):
        raise TypeError("Type Annotated cannot be instantiated.")


class Annotated(metaclass=_AnnotatedMeta):
    """Add context-specific metadata to a type."""
    def __class_getitem__(cls, params):
        if not isinstance(params, tuple):
            params = (params,)
        if len(params) < 2:
            raise TypeError("Annotated[...] should be used with at least two arguments (a type and an annotation).")
        var origin = _type_check(params[0], "Annotated[t, ...]: t must be a type.", True, None, True)
        return _AnnotatedAlias(origin, tuple(params[1:]))

    def __init_subclass__(cls, *args, **kwargs):
        raise TypeError("Cannot subclass typing.Annotated")


# ── Generic ──────────────────────────────────────────────────────────────────
def _is_typevar_like(x):
    return isinstance(x, TypeVar) or isinstance(x, ParamSpec) or (isinstance(x, _UnpackGenericAlias) and isinstance(x.__args__[0], TypeVarTuple))


class Generic:
    """Abstract base class for generic types."""
    _is_protocol = False

    def __class_getitem__(cls, params):
        if not isinstance(params, tuple):
            params = (params,)
        params = tuple([_type_convert(p) for p in params])
        if cls is Generic or cls is Protocol:
            if not params:
                raise TypeError("Parameter list to " + cls.__qualname__ + "[...] cannot be empty")
            for p in params:
                if not _is_typevar_like(p):
                    raise TypeError("Parameters to " + cls.__name__ + "[...] must all be type variables or parameter specification variables.")
            if len(_deduplicate(params)) != len(params):
                raise TypeError("Parameters to " + cls.__name__ + "[...] must all be unique")
        else:
            var cparams = _dget(cls.__dict__, "__parameters__")
            if cparams is None:
                cparams = getattr(cls, "__parameters__", ())
            if len(cparams) == 1 and isinstance(cparams[0], ParamSpec) and not (len(params) == 1 and _is_param_expr(params[0])):
                params = (params,)
            _check_generic(cls, params, len(cparams))
        return _GenericAlias(cls, params, _paramspec_tvars=True)

    def __init_subclass__(cls, *args, **kwargs):
        var d = cls.__dict__
        var has_orig = "__orig_bases__" in d
        var error = False
        if has_orig:
            error = _contains_identical(d["__orig_bases__"], Generic)
        else:
            error = _contains_identical(cls.__bases__, Generic) and cls.__name__ != "Protocol" and type(cls) is not _TypedDictMeta
        if error:
            raise TypeError("Cannot inherit from plain Generic")
        var tvars = []
        if has_orig:
            tvars = _collect_parameters(d["__orig_bases__"])
            var gvars = None
            for base in d["__orig_bases__"]:
                if isinstance(base, _GenericAlias) and base.__origin__ is Generic:
                    if gvars is not None:
                        raise TypeError("Cannot inherit from Generic[...] multiple times.")
                    gvars = base.__parameters__
            if gvars is not None:
                var missing = [t for t in tvars if not _contains(gvars, t)]
                if missing:
                    raise TypeError("Some type variables (" + ", ".join([str(t) for t in missing])
                                    + ") are not listed in Generic[" + ", ".join([str(g) for g in gvars]) + "]")
                tvars = gvars
        cls.__parameters__ = tuple(tvars)


def _contains_identical(seq, x):
    for y in seq:
        if y is x:
            return True
    return False


# ── Protocol ─────────────────────────────────────────────────────────────────
_TYPING_INTERNALS = ["__parameters__", "__orig_bases__", "__orig_class__", "_is_protocol",
                     "_is_runtime_protocol", "__final__", "__protocol_attrs__"]
_SPECIAL_NAMES = ["__abstractmethods__", "__annotations__", "__dict__", "__doc__", "__init__",
                  "__module__", "__new__", "__slots__", "__subclasshook__", "__weakref__",
                  "__class_getitem__", "__qualname__", "__init_subclass__", "__match_args__"]
_EXCLUDED_ATTRIBUTES = _TYPING_INTERNALS + _SPECIAL_NAMES + ["_MutableMapping__marker"]


def _get_protocol_attrs(cls):
    var attrs = []
    for base in cls.__mro__:
        if base.__name__ in ("Protocol", "Generic", "object"):
            continue
        var d = base.__dict__
        var ann = _dget(d, "__annotations__", {})
        for attr in list(d) + list(ann):
            if not attr.startswith("_abc_") and attr not in _EXCLUDED_ATTRIBUTES and attr not in attrs:
                attrs.append(attr)
    return attrs


def _is_callable_members_only(cls):
    for attr in _get_protocol_attrs(cls):
        if not callable(getattr(cls, attr, None)):
            return False
    return True


def _nominal_subclass(sub, cls):
    for c in getattr(sub, "__mro__", ()):
        if c is cls:
            return True
    return False


class _ProtocolMeta(type):
    def __instancecheck__(cls, instance):
        if getattr(cls, "_is_protocol", False) and not getattr(cls, "_is_runtime_protocol", False):
            raise TypeError("Instance and class checks can only be used with @runtime_checkable protocols")
        if (not getattr(cls, "_is_protocol", False) or _is_callable_members_only(cls)) and _nominal_subclass(type(instance), cls):
            return True
        if cls._is_protocol:
            var ok = True
            for attr in _get_protocol_attrs(cls):
                if not hasattr(instance, attr):
                    ok = False
                    break
                if callable(getattr(cls, attr, None)) and getattr(instance, attr) is None:
                    ok = False
                    break
            if ok:
                return True
        return _nominal_subclass(type(instance), cls)

    def __subclasscheck__(cls, other):
        if _dget(cls.__dict__, "_is_protocol", False):
            if not getattr(cls, "_is_runtime_protocol", False):
                raise TypeError("Instance and class checks can only be used with @runtime_checkable protocols")
            if not _is_callable_members_only(cls):
                raise TypeError("Protocols with non-method members don't support issubclass()")
            if not _is_class(other):
                raise TypeError("issubclass() arg 1 must be a class")
            if _nominal_subclass(other, cls):
                return True
            for attr in _get_protocol_attrs(cls):
                var found = False
                for base in getattr(other, "__mro__", (other,)):
                    var bd = {}
                    try:
                        bd = base.__dict__
                    except Exception:
                        bd = {}
                    if attr in bd:
                        if bd[attr] is None:
                            return False
                        found = True
                        break
                    var ann = _dget(bd, "__annotations__", {}) if isinstance(bd, dict) else {}
                    if attr in ann and getattr(other, "_is_protocol", False):
                        found = True
                        break
                if not found:
                    if hasattr(other, attr) and getattr(other, "__module__", "") == "builtins":
                        continue
                    return False
            return True
        return _nominal_subclass(other, cls)

    def __call__(cls, *args, **kwargs):
        if _dget(cls.__dict__, "_is_protocol", False):
            raise TypeError("Protocols cannot be instantiated")
        return super().__call__(*args, **kwargs)


class Protocol(Generic, metaclass=_ProtocolMeta):
    """Base class for protocol classes."""
    _is_protocol = True
    _is_runtime_protocol = False

    def __init_subclass__(cls, *args, **kwargs):
        _generic_init_subclass(cls)
        if not _dget(cls.__dict__, "_is_protocol", False):
            cls._is_protocol = _contains_identical(cls.__bases__, Protocol)
        if not cls._is_protocol:
            return
        for base in cls.__bases__:
            var ok = base is object or base is Generic or (_is_class(base) and issubclass(base, Generic) and getattr(base, "_is_protocol", False))
            if not ok and getattr(base, "__module__", "") in ("collections.abc", "contextlib"):
                ok = True
            if not ok:
                raise TypeError("Protocols can only inherit from other protocols, got " + repr(base))


def _generic_init_subclass(cls):
    # Generic.__init_subclass__ for a Protocol subclass
    var d = cls.__dict__
    var tvars = ()
    if "__orig_bases__" in d:
        tvars = _collect_parameters(d["__orig_bases__"])
        var gvars = None
        for base in d["__orig_bases__"]:
            if isinstance(base, _GenericAlias) and (base.__origin__ is Generic):
                if gvars is not None:
                    raise TypeError("Cannot inherit from Generic[...] multiple times.")
                gvars = base.__parameters__
        if gvars is not None:
            tvars = gvars
    cls.__parameters__ = tuple(tvars)


def runtime_checkable(cls):
    # Mark a protocol class as a runtime protocol (isinstance/issubclass)
    if not _is_class(cls) or not issubclass(cls, Generic) or not getattr(cls, "_is_protocol", False):
        raise TypeError("@runtime_checkable can be only applied to protocol classes, got " + repr(cls))
    cls._is_runtime_protocol = True
    return cls


# ── the aliases ──────────────────────────────────────────────────────────────
_cabc_state = [False, None]


def _collections_abc():
    # collections.abc when lib/collections/abc.ny is there (imported once)
    if not _cabc_state[0]:
        _cabc_state[0] = True
        try:
            import collections.abc as _found_abc
            _cabc_state[1] = _found_abc
        except Exception:
            _cabc_state[1] = None
    return _cabc_state[1]


_stand_ins = {}


def _resolve_origin(path):
    # "collections.abc.Iterable", "collections.deque", "contextlib.X",
    # "re.Pattern" -> the class
    var parts = path.split(".")
    var name = parts[-1]
    if path.startswith("collections.abc."):
        var abc = _collections_abc()
        if abc is not None and hasattr(abc, name):
            return getattr(abc, name)
        return _abc_stand_in(name)
    if parts[0] == "collections":
        import collections as _collections_mod
        return getattr(_collections_mod, name)
    if parts[0] == "contextlib":
        import contextlib as _contextlib_mod
        return getattr(_contextlib_mod, name)
    if parts[0] == "re":
        import re as _re_mod
        return getattr(_re_mod, name)
    raise AttributeError(path)


def _has(x, name):
    if isinstance(x, (list, tuple, str, dict, set, frozenset, bytes, bytearray)):
        return name in _builtin_members.get(_tname(x), ())
    return hasattr(x, name)

_builtin_members = {
    "list": ("__iter__", "__len__", "__contains__", "__getitem__", "__reversed__", "__setitem__"),
    "tuple": ("__iter__", "__len__", "__contains__", "__getitem__", "__reversed__", "__hash__"),
    "str": ("__iter__", "__len__", "__contains__", "__getitem__", "__reversed__", "__hash__"),
    "bytes": ("__iter__", "__len__", "__contains__", "__getitem__", "__reversed__", "__hash__"),
    "bytearray": ("__iter__", "__len__", "__contains__", "__getitem__", "__reversed__", "__setitem__"),
    "dict": ("__iter__", "__len__", "__contains__", "__getitem__", "__reversed__", "__setitem__", "keys"),
    "set": ("__iter__", "__len__", "__contains__"),
    "frozenset": ("__iter__", "__len__", "__contains__", "__hash__"),
}

_stand_in_rules = {
    "Hashable": ["__hash__"], "Awaitable": ["__await__"], "Coroutine": ["send", "throw", "__await__"],
    "AsyncIterable": ["__aiter__"], "AsyncIterator": ["__aiter__", "__anext__"],
    "Iterable": ["__iter__"], "Iterator": ["__iter__", "__next__"], "Reversible": ["__reversed__", "__iter__"],
    "Sized": ["__len__"], "Container": ["__contains__"], "Collection": ["__len__", "__iter__", "__contains__"],
    "Callable": ["__call__"], "Set": ["__len__", "__iter__", "__contains__"],
    "MutableSet": ["__len__", "__iter__", "__contains__", "add", "discard"],
    "Mapping": ["__getitem__", "__len__", "__iter__", "keys"],
    "MutableMapping": ["__getitem__", "__setitem__", "__len__", "__iter__", "keys"],
    "Sequence": ["__getitem__", "__len__", "__iter__"],
    "MutableSequence": ["__getitem__", "__setitem__", "__len__", "insert"],
    "ByteString": [], "MappingView": ["__len__"], "KeysView": ["__len__", "__iter__"],
    "ItemsView": ["__len__", "__iter__"], "ValuesView": ["__len__", "__iter__"],
    "Generator": ["send", "throw", "__next__"], "AsyncGenerator": ["asend", "athrow", "__anext__"],
}


def _abc_check(name, x):
    if name == "Callable":
        return callable(x)
    if name == "Hashable":
        return not isinstance(x, (list, dict, set, bytearray))
    if name == "Iterator" or name == "Generator":
        if isinstance(x, "generator"):
            return name == "Iterator" or hasattr(x, "send")
    if name == "Iterable" and isinstance(x, "generator"):
        return True
    if name in ("Sequence", "Reversible") and isinstance(x, (dict, set, frozenset)):
        return False
    if name in ("Mapping", "MutableMapping") and not isinstance(x, dict) and isinstance(x, (list, tuple, str, set, frozenset, bytes, bytearray)):
        return False
    if name in ("Set", "MutableSet") and isinstance(x, (list, tuple, str, dict, bytes, bytearray)):
        return False
    if name == "MutableSequence" and isinstance(x, (tuple, str, bytes)):
        return False
    if name == "ByteString":
        return isinstance(x, (bytes, bytearray))
    if name in ("Set", "MutableSet") and isinstance(x, (set, frozenset)):
        return name == "Set" or isinstance(x, set)
    for m in _stand_in_rules.get(name, []):
        if not _has(x, m):
            return False
    return True


class _AbcStandInMeta(type):
    def __instancecheck__(cls, obj):
        return _abc_check(cls._ny_abc_name, obj)
    def __subclasscheck__(cls, sub):
        if sub is cls:
            return True
        var probe = {"list": [], "tuple": (), "str": "", "dict": {}, "set": set(), "frozenset": frozenset(),
                     "bytes": b"", "bytearray": bytearray()}
        var n = getattr(sub, "__name__", "")
        if getattr(sub, "__module__", "") == "builtins" and n in probe:
            return _abc_check(cls._ny_abc_name, probe[n])
        for m in _stand_in_rules.get(cls._ny_abc_name, []):
            if not hasattr(sub, m):
                return False
        return True
    def __repr__(cls):
        return "<class 'collections.abc." + cls._ny_abc_name + "'>"


def _abc_stand_in(name):
    if name in _stand_ins:
        return _stand_ins[name]
    var cls = _AbcStandInMeta("_NyAbc_" + name, (), {"_ny_abc_name": name})
    cls.__name__ = name
    cls.__qualname__ = name
    cls.__module__ = "collections.abc"
    _stand_ins[name] = cls
    return cls


_alias = _SpecialGenericAlias

Hashable = _alias("collections.abc.Hashable", 0, name="Hashable")
Awaitable = _alias("collections.abc.Awaitable", 1, name="Awaitable")
Coroutine = _alias("collections.abc.Coroutine", 3, name="Coroutine")
AsyncIterable = _alias("collections.abc.AsyncIterable", 1, name="AsyncIterable")
AsyncIterator = _alias("collections.abc.AsyncIterator", 1, name="AsyncIterator")
Iterable = _alias("collections.abc.Iterable", 1, name="Iterable")
Iterator = _alias("collections.abc.Iterator", 1, name="Iterator")
Reversible = _alias("collections.abc.Reversible", 1, name="Reversible")
Sized = _alias("collections.abc.Sized", 0, name="Sized")
Container = _alias("collections.abc.Container", 1, name="Container")
Collection = _alias("collections.abc.Collection", 1, name="Collection")
Callable = _CallableType("collections.abc.Callable", 2, name="Callable")
AbstractSet = _alias("collections.abc.Set", 1, name="AbstractSet")
MutableSet = _alias("collections.abc.MutableSet", 1, name="MutableSet")
Mapping = _alias("collections.abc.Mapping", 2, name="Mapping")
MutableMapping = _alias("collections.abc.MutableMapping", 2, name="MutableMapping")
Sequence = _alias("collections.abc.Sequence", 1, name="Sequence")
MutableSequence = _alias("collections.abc.MutableSequence", 1, name="MutableSequence")
ByteString = _alias("collections.abc.ByteString", 0, name="ByteString")
Tuple = _TupleType(tuple, -1, inst=False, name="Tuple")
List = _alias(list, 1, inst=False, name="List")
Deque = _alias("collections.deque", 1, name="Deque")
Set = _alias(set, 1, inst=False, name="Set")
FrozenSet = _alias(frozenset, 1, inst=False, name="FrozenSet")
MappingView = _alias("collections.abc.MappingView", 1, name="MappingView")
KeysView = _alias("collections.abc.KeysView", 1, name="KeysView")
ItemsView = _alias("collections.abc.ItemsView", 2, name="ItemsView")
ValuesView = _alias("collections.abc.ValuesView", 1, name="ValuesView")
ContextManager = _alias("contextlib.AbstractContextManager", 1, name="ContextManager")
AsyncContextManager = _alias("contextlib.AbstractAsyncContextManager", 1, name="AsyncContextManager")
Dict = _alias(dict, 2, inst=False, name="Dict")
DefaultDict = _alias("collections.defaultdict", 2, name="DefaultDict")
OrderedDict = _alias("collections.OrderedDict", 2, name="OrderedDict")
Counter = _alias("collections.Counter", 1, name="Counter")
ChainMap = _alias("collections.ChainMap", 2, name="ChainMap")
Generator = _alias("collections.abc.Generator", 3, name="Generator")
AsyncGenerator = _alias("collections.abc.AsyncGenerator", 2, name="AsyncGenerator")
Type = _alias(type, 1, inst=False, name="Type")
Pattern = _alias("re.Pattern", 1, name="Pattern")
Match = _alias("re.Match", 1, name="Match")

T = TypeVar("T")
KT = TypeVar("KT")
VT = TypeVar("VT")
T_co = TypeVar("T_co", covariant=True)
V_co = TypeVar("V_co", covariant=True)
VT_co = TypeVar("VT_co", covariant=True)
T_contra = TypeVar("T_contra", contravariant=True)
CT_co = TypeVar("CT_co", covariant=True, bound=type)
AnyStr = TypeVar("AnyStr", bytes, str)
Text = str
TYPE_CHECKING = False


# ── runtime protocols ────────────────────────────────────────────────────────
@runtime_checkable
class SupportsInt(Protocol):
    """An ABC with one abstract method __int__."""
    def __int__(self) -> int:
        pass


@runtime_checkable
class SupportsFloat(Protocol):
    """An ABC with one abstract method __float__."""
    def __float__(self) -> float:
        pass


@runtime_checkable
class SupportsComplex(Protocol):
    """An ABC with one abstract method __complex__."""
    def __complex__(self) -> complex:
        pass


@runtime_checkable
class SupportsBytes(Protocol):
    """An ABC with one abstract method __bytes__."""
    def __bytes__(self) -> bytes:
        pass


@runtime_checkable
class SupportsIndex(Protocol):
    """An ABC with one abstract method __index__."""
    def __index__(self) -> int:
        pass


@runtime_checkable
class SupportsAbs(Protocol[T_co]):
    """An ABC with one abstract method __abs__ that is covariant in its return type."""
    def __abs__(self):
        pass


@runtime_checkable
class SupportsRound(Protocol[T_co]):
    """An ABC with one abstract method __round__ that is covariant in its return type."""
    def __round__(self, ndigits: int = 0):
        pass


# ── NamedTuple ───────────────────────────────────────────────────────────────
_prohibited = ["__new__", "__init__", "__slots__", "__getnewargs__", "_fields", "_field_defaults",
               "_make", "_replace", "_asdict", "_source"]


def _join_names(names):
    # 'a', 'a' and 'b', 'a', 'b', and 'c' (CPython's missing-argument lists)
    var q = ["'" + n + "'" for n in names]
    if len(q) == 1:
        return q[0]
    if len(q) == 2:
        return q[0] + " and " + q[1]
    return ", ".join(q[:-1]) + ", and " + q[-1]


class NamedTupleMeta(type):
    def __new__(mcs, typename, bases, ns, **kwds):
        var cls = super().__new__(mcs, typename, bases, ns)
        if not _dget(ns, "_ny_namedtuple_root", False):
            _setup_namedtuple(cls, typename, bases, ns)
        return cls

    def __call__(cls, *args, **kwargs):
        if _dget(cls.__dict__, "_ny_namedtuple_root", False):
            return _namedtuple_functional(*args, **kwargs)
        return super().__call__(*args, **kwargs)


def _setup_namedtuple(cls, typename, bases, ns):
    for base in bases:
        if base is not NamedTuple and base is not Generic:
            raise TypeError("can only inherit from a NamedTuple type and Generic")
    var types_ = _dget(ns, "__annotations__", {})
    var default_names = []
    var fields = []
    var annotations = {}
    for field_name in types_:
        fields.append(field_name)
        annotations[field_name] = _type_check(types_[field_name], "field " + field_name + " annotation must be a type")
        if field_name in ns:
            default_names.append(field_name)
        elif default_names:
            raise TypeError("Non-default namedtuple field " + field_name + " cannot follow default field"
                            + ("s" if len(default_names) > 1 else "") + " " + ", ".join(default_names))
    for key in ns:
        if key in _prohibited:
            raise AttributeError("Cannot overwrite NamedTuple attribute " + key)
    var defaults = {}
    for n in default_names:
        defaults[n] = ns[n]
    cls._fields = tuple(fields)
    cls._field_defaults = defaults
    cls.__annotations__ = annotations
    cls.__match_args__ = tuple(fields)
    cls._ny_typename = typename
    for n in default_names:
        try:
            delattr(cls, n)
        except Exception:
            pass
    for i in range(len(fields)):
        setattr(cls, fields[i], _nt_field(i))


def _namedtuple_functional(typename, fields=None, /, **kwargs):
    if fields is None:
        fields = [(k, kwargs[k]) for k in kwargs]
    elif kwargs:
        raise TypeError("Either list of fields or keywords can be provided to NamedTuple, not both")
    var ann = {}
    for pair in fields:
        var p = list(pair)
        ann[p[0]] = p[1]
    return NamedTupleMeta(typename, (NamedTuple,), {"__annotations__": ann, "__module__": "__main__"})


def _nt_field(i):
    # the property reading field i of a NamedTuple
    def get(self):
        return self[i]
    return property(get)


class NamedTuple(tuple, metaclass=NamedTupleMeta):
    """Typed version of namedtuple."""
    # a tuple subclass (round 77): isinstance(p, tuple), and the tuple's
    # operators, hashing, slicing and methods come from tuple
    _ny_namedtuple_root = True
    _fields = ()
    _field_defaults = {}

    def __new__(cls, *args, **kwargs):
        var fields = cls._fields
        var defaults = cls._field_defaults
        var qn = cls.__name__ + ".__new__()"
        var npos = len(fields)
        var nreq = len([f for f in fields if f not in defaults])
        if len(args) > npos:
            var takes = str(npos + 1) if nreq == npos else "from " + str(nreq + 1) + " to " + str(npos + 1)
            raise TypeError(qn + " takes " + takes + " positional argument" + ("" if npos == 0 and nreq == npos else "s")
                            + " but " + str(len(args) + 1) + " were given")
        for k in kwargs:
            if k not in fields:
                raise TypeError(qn + " got an unexpected keyword argument '" + k + "'")
            if fields.index(k) < len(args):
                raise TypeError(qn + " got multiple values for argument '" + k + "'")
        var vals = list(args)
        var missing = []
        for i in range(len(args), npos):
            var f = fields[i]
            if f in kwargs:
                vals.append(kwargs[f])
            elif f in defaults:
                vals.append(defaults[f])
            else:
                missing.append(f)
                vals.append(None)
        if missing:
            raise TypeError(qn + " missing " + str(len(missing)) + " required positional argument"
                            + ("s" if len(missing) > 1 else "") + ": " + _join_names(missing))
        return tuple.__new__(cls, vals)

    def __setattr__(self, name, value):
        if name in type(self)._fields:
            raise AttributeError("can't set attribute")
        raise AttributeError("'" + type(self).__name__ + "' object has no attribute '" + name + "'")

    def __delattr__(self, name):
        raise AttributeError("can't delete attribute")

    def __repr__(self):
        var parts = []
        for i in range(len(self._fields)):
            parts.append(self._fields[i] + "=" + repr(self[i]))
        return type(self).__name__ + "(" + ", ".join(parts) + ")"

    def _asdict(self):
        var d = {}
        for i in range(len(self._fields)):
            d[self._fields[i]] = self[i]
        return d

    def _replace(self, **kwds):
        var vals = []
        for f in self._fields:
            if f in kwds:
                vals.append(kwds[f])
                del kwds[f]
            else:
                vals.append(getattr(self, f))
        if kwds:
            raise ValueError("Got unexpected field names: " + repr(list(kwds)))
        return type(self)(*vals)

    @classmethod
    def _make(cls, iterable):
        var vals = list(iterable)
        if len(vals) != len(cls._fields):
            raise TypeError("Expected " + str(len(cls._fields)) + " arguments, got " + str(len(vals)))
        return tuple.__new__(cls, vals)

    def __getnewargs__(self):
        return tuple(self)


# ── TypedDict ────────────────────────────────────────────────────────────────
class _TypedDictMeta(type):
    def __new__(mcs, name, bases, ns, total=True, **kwds):
        var tp_dict = super().__new__(mcs, name, bases, ns)
        if _dget(ns, "_ny_typeddict_root", False):
            return tp_dict
        for base in bases:
            if type(base) is not _TypedDictMeta and base is not Generic:
                raise TypeError("cannot inherit from both a TypedDict type and a non-TypedDict base class")
        var annotations = {}
        var own = _dget(ns, "__annotations__", {})
        var msg = "TypedDict('Name', {f0: t0, f1: t1, ...}); each t must be a type"
        var own_annotations = {}
        for n in own:
            own_annotations[n] = _type_check(own[n], msg)
        var required_keys = set()
        var optional_keys = set()
        for base in bases:
            if base is TypedDict:
                continue
            var bd = base.__dict__
            var ba = _dget(bd, "__annotations__", {})
            for k in ba:
                annotations[k] = ba[k]
            var base_required = _dget(bd, "__required_keys__", set())
            required_keys = required_keys | set(base_required)
            optional_keys = optional_keys - set(base_required)
            var base_optional = _dget(bd, "__optional_keys__", set())
            required_keys = required_keys - set(base_optional)
            optional_keys = optional_keys | set(base_optional)
        for k in own_annotations:
            annotations[k] = own_annotations[k]
        for key in own_annotations:
            var ann = own_annotations[key]
            var origin = get_origin(ann)
            if origin is Annotated:
                var aargs = get_args(ann)
                if aargs:
                    ann = aargs[0]
                    origin = get_origin(ann)
            var is_required = total
            if origin is Required:
                is_required = True
            elif origin is NotRequired:
                is_required = False
            if is_required:
                required_keys.add(key)
                optional_keys.discard(key)
            else:
                optional_keys.add(key)
                required_keys.discard(key)
        tp_dict.__annotations__ = annotations
        tp_dict.__required_keys__ = frozenset(required_keys)
        tp_dict.__optional_keys__ = frozenset(optional_keys)
        if "__total__" not in tp_dict.__dict__:
            tp_dict.__total__ = total
        return tp_dict

    def __call__(cls, *args, **kwargs):
        if _dget(cls.__dict__, "_ny_typeddict_root", False):
            return _typeddict_functional(*args, **kwargs)
        return dict(*args, **kwargs)

    def __subclasscheck__(cls, other):
        raise TypeError("TypedDict does not support instance and class checks")

    def __instancecheck__(cls, other):
        raise TypeError("TypedDict does not support instance and class checks")


def _typeddict_functional(typename, fields=None, /, *, total=True, **kwargs):
    if fields is None:
        fields = kwargs
    elif kwargs:
        raise TypeError("TypedDict takes either a dict or keyword arguments, but not both")
    var ns = {"__annotations__": dict(fields), "__module__": "__main__"}
    return _TypedDictMeta(typename, (TypedDict,), ns, total=total)


class TypedDict(metaclass=_TypedDictMeta):
    """A simple typed namespace. At runtime it is equivalent to a plain dict."""
    _ny_typeddict_root = True

    def __init_subclass__(cls, *args, **kwargs):
        pass


def is_typeddict(tp):
    return _is_class(tp) and type(tp) is _TypedDictMeta and tp is not TypedDict


# ── NewType ──────────────────────────────────────────────────────────────────
class NewType:
    """NewType creates simple unique types with almost zero runtime overhead."""
    def __init__(self, name, tp):
        self.__qualname__ = name
        if "." in name:
            name = name.split(".")[-1]
        self.__name__ = name
        self.__supertype__ = tp
        self.__module__ = "__main__"

    def __call__(self, x):
        return x

    def __mro_entries__(self, bases):
        raise TypeError("Cannot subclass an instance of NewType. Perhaps you were looking for: `X = NewType('X', "
                        + self.__name__ + ")`")

    def __repr__(self):
        return self.__module__ + "." + self.__qualname__

    def __reduce__(self):
        return self.__qualname__

    def __or__(self, other):
        return Union[self, other]

    def __ror__(self, other):
        return Union[other, self]


# ── IO ───────────────────────────────────────────────────────────────────────
class IO(Generic[AnyStr]):
    """Generic base class for TextIO and BinaryIO."""
    @property
    def mode(self):
        raise NotImplementedError

    @property
    def name(self):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError

    def read(self, n=-1):
        raise NotImplementedError

    def write(self, s):
        raise NotImplementedError


class BinaryIO(IO[bytes]):
    """Typed version of the return of open() in binary mode."""
    pass


class TextIO(IO[str]):
    """Typed version of the return of open() in text mode."""
    pass


# ── functions ────────────────────────────────────────────────────────────────
def cast(typ, val):
    # val, unchanged (a signal to the type checker)
    return val


def assert_type(val, typ, /):
    return val


def reveal_type(obj, /):
    print("Runtime type is " + repr(type(obj).__name__), file=sys.stderr)
    return obj


def assert_never(arg, /):
    var value = _pyrepr(arg)
    if len(value) > 100:
        value = value[:100] + "..."
    raise AssertionError("Expected code to be unreachable, but got: " + value)


def _overload_dummy(*args, **kwds):
    raise NotImplementedError("You should not call an overloaded function. A series of @overload-decorated "
                              "functions outside a stub module should always be followed by an "
                              "implementation that is not @overload-ed.")


_overload_registry = {}


def overload(func):
    # Records func as one overload of its (module, qualname); returns a
    # function that raises when called
    var f = getattr(func, "__func__", func)
    try:
        var key = f.__module__ + ":" + f.__qualname__
        var lineno = f.__code__.co_firstlineno
        if key not in _overload_registry:
            _overload_registry[key] = {}
        _overload_registry[key][lineno] = func
    except AttributeError:
        pass
    return _overload_dummy


def get_overloads(func):
    var f = getattr(func, "__func__", func)
    var key = f.__module__ + ":" + f.__qualname__
    if key not in _overload_registry:
        return []
    return list(_overload_registry[key].values())


def clear_overloads():
    _overload_registry.clear()


def final(f):
    try:
        f.__final__ = True
    except Exception:
        pass
    return f


def override(method, /):
    # (3.12) marks a method as overriding one of its base classes'
    try:
        method.__override__ = True
    except Exception:
        pass
    return method


def no_type_check(arg):
    # Annotations of arg (and of the functions defined in a class) are not
    # type hints
    if _is_class(arg):
        for key in dir(arg):
            var obj = getattr(arg, key, None)
            if obj is None:
                continue
            if getattr(obj, "__qualname__", None) != arg.__qualname__ + "." + getattr(obj, "__name__", ""):
                continue
            if isinstance(obj, types.FunctionType):
                obj.__no_type_check__ = True
            if isinstance(obj, types.MethodType):
                obj.__func__.__no_type_check__ = True
            if _is_class(obj):
                no_type_check(obj)
    try:
        arg.__no_type_check__ = True
    except Exception:
        pass
    return arg


def no_type_check_decorator(decorator):
    def wrapped_decorator(*args, **kwds):
        return no_type_check(decorator(*args, **kwds))
    try:
        wrapped_decorator.__wrapped__ = decorator
        wrapped_decorator.__name__ = decorator.__name__
    except Exception:
        pass
    return wrapped_decorator


def dataclass_transform(*, eq_default=True, order_default=False, kw_only_default=False,
                        field_specifiers=(), **kwargs):
    def decorator(cls_or_fn):
        cls_or_fn.__dataclass_transform__ = {
            "eq_default": eq_default,
            "order_default": order_default,
            "kw_only_default": kw_only_default,
            "field_specifiers": field_specifiers,
            "kwargs": kwargs,
        }
        return cls_or_fn
    return decorator


# ── introspection ────────────────────────────────────────────────────────────
def get_origin(tp):
    # The unsubscripted version of a type (list for List[int], Union for
    # Optional[int], ...), None for what is not generic
    if isinstance(tp, _AnnotatedAlias):
        return Annotated
    if isinstance(tp, _BaseGenericAlias) or isinstance(tp, types.GenericAlias) or isinstance(tp, ParamSpecArgs) or isinstance(tp, ParamSpecKwargs):
        return tp.__origin__
    if _is(tp, Generic):
        return Generic
    if isinstance(tp, types.UnionType):
        return types.UnionType
    return None


def _should_unflatten_callable_args(tp, args):
    return getattr(tp, "_name", None) == "Callable" and not (len(args) == 2 and _is_param_expr(args[0]))


def get_args(tp):
    # The type arguments, substitutions done (Callable's as [args], result)
    if isinstance(tp, _AnnotatedAlias):
        return (tp.__origin__,) + tp.__metadata__
    if isinstance(tp, _GenericAlias) or isinstance(tp, types.GenericAlias):
        var res = tp.__args__
        if isinstance(tp, _GenericAlias) and _should_unflatten_callable_args(tp, res):
            res = (list(res[:-1]), res[-1])
        return res
    if isinstance(tp, types.UnionType):
        return tuple(_union_args(tp))
    return ()


def _strip_annotations(t):
    if isinstance(t, _AnnotatedAlias):
        return _strip_annotations(t.__origin__)
    if isinstance(t, _GenericAlias) and (t.__origin__ is Required or t.__origin__ is NotRequired):
        return _strip_annotations(t.__args__[0])
    if isinstance(t, _GenericAlias):
        var stripped = tuple([_strip_annotations(a) for a in t.__args__])
        if stripped == t.__args__:
            return t
        return t.copy_with(stripped)
    if isinstance(t, types.GenericAlias):
        var stripped2 = tuple([_strip_annotations(a) for a in t.__args__])
        if stripped2 == t.__args__:
            return t
        return types.GenericAlias(t.__origin__, stripped2)
    return t


def _class_globals(cls):
    var d = {}
    try:
        d = cls.__dict__
    except Exception:
        return {}
    for k in d:
        var v = d[k]
        if isinstance(v, types.FunctionType):
            try:
                return v.__globals__
            except Exception:
                pass
    if getattr(cls, "__module__", None) == "__main__":
        return _ny_main_globals()
    return {}


def get_type_hints(obj, globalns=None, localns=None, include_extras=False):
    # Type hints of a module, class, method or function: obj.__annotations__
    # with string annotations evaluated, a class's merged over its MRO
    if getattr(obj, "__no_type_check__", None):
        return {}
    if _is_class(obj):
        var hints = {}
        for base in reversed(list(obj.__mro__)):
            var bd = {}
            try:
                bd = base.__dict__
            except Exception:
                continue
            var base_globals = _class_globals(base) if globalns is None else globalns
            var ann = _dget(bd, "__annotations__", {}) if isinstance(bd, dict) else {}
            var base_locals = dict(bd) if localns is None else localns
            if localns is None and globalns is None:
                var tmp = base_globals
                base_globals = base_locals
                base_locals = tmp
            for name in ann:
                var value = ann[name]
                if value is None:
                    value = NoneType
                if isinstance(value, str):
                    value = ForwardRef(value, False, None, is_class=True)
                hints[name] = _eval_type(value, base_globals, base_locals)
        if include_extras:
            return hints
        var out = {}
        for k in hints:
            out[k] = _strip_annotations(hints[k])
        return out
    if globalns is None:
        if isinstance(obj, types.ModuleType):
            globalns = obj if isinstance(obj, dict) else obj.__dict__
        else:
            var nsobj = obj
            while hasattr(nsobj, "__wrapped__"):
                nsobj = nsobj.__wrapped__
            globalns = getattr(nsobj, "__globals__", {})
        if localns is None:
            localns = globalns
    elif localns is None:
        localns = globalns
    var hints2 = getattr(obj, "__annotations__", None)
    if hints2 is None:
        if isinstance(obj, types.FunctionType) or isinstance(obj, types.MethodType) or isinstance(obj, types.ModuleType) or isinstance(obj, types.BuiltinFunctionType):
            return {}
        raise TypeError(repr(obj) + " is not a module, class, method, or function.")
    var res = {}
    for name in hints2:
        var value = hints2[name]
        if value is None:
            value = NoneType
        if isinstance(value, str):
            value = ForwardRef(value, not isinstance(obj, types.ModuleType), None, is_class=False)
        res[name] = _eval_type(value, globalns, localns)
    if include_extras:
        return res
    var out2 = {}
    for k in res:
        out2[k] = _strip_annotations(res[k])
    return out2


# ── check_type (Nython) ──────────────────────────────────────────────────────
def _describe(x):
    return _tname(x)


def _check(value, tp, path):
    # None when value fits tp, else the reason
    if _is(tp, Any) or _is(tp, object):
        return None
    if isinstance(tp, str):
        tp = ForwardRef(tp)
    if isinstance(tp, ForwardRef):
        return None if not tp.__forward_evaluated__ else _check(value, tp.__forward_value__, path)
    if tp is None or tp is NoneType:
        return None if value is None else path + " is " + _describe(value) + ", not None"
    if isinstance(tp, NewType):
        return _check(value, tp.__supertype__, path)
    if isinstance(tp, TypeVar):
        if tp.__bound__ is not None:
            return _check(value, tp.__bound__, path)
        if tp.__constraints__:
            for c in tp.__constraints__:
                if _check(value, c, path) is None:
                    return None
            return path + " is " + _describe(value) + ", not one of " + ", ".join([_type_repr(c) for c in tp.__constraints__])
        return None
    if isinstance(tp, _AnnotatedAlias):
        return _check(value, tp.__origin__, path)
    if isinstance(tp, _UnionGenericAlias) or isinstance(tp, types.UnionType):
        for a in _union_args(tp):
            if _check(value, a, path) is None:
                return None
        return path + " is " + _describe(value) + ", not " + repr(tp).replace("typing.", "")
    if isinstance(tp, _LiteralGenericAlias):
        for a in tp.__args__:
            if value == a and type(value) == type(a):
                return None
        return path + " is " + _pyrepr(value) + ", not one of " + ", ".join([_pyrepr(a) for a in tp.__args__])
    if is_typeddict(tp):
        if not isinstance(value, dict):
            return path + " is " + _describe(value) + ", not a dict"
        for k in tp.__required_keys__:
            if k not in value:
                return path + " is missing the required key " + repr(k)
        for k in value:
            if k not in tp.__annotations__:
                return path + " has an unexpected key " + repr(k)
            var r = _check(value[k], tp.__annotations__[k], path + "[" + repr(k) + "]")
            if r is not None:
                return r
        return None
    var origin = get_origin(tp)
    if origin is ClassVar or origin is Final or origin is Required or origin is NotRequired:
        return _check(value, tp.__args__[0], path)
    if tp is Callable or (isinstance(tp, _CallableGenericAlias)):
        return None if callable(value) else path + " is " + _describe(value) + ", not callable"
    if isinstance(tp, _SpecialGenericAlias):
        return None if isinstance(value, tp) else path + " is " + _describe(value) + ", not " + tp._name
    if origin is not None:
        var args = get_args(tp)
        if not isinstance(value, origin):
            return path + " is " + _describe(value) + ", not " + _type_repr(origin)
        if origin is tuple:
            if len(args) == 2 and args[1] is Ellipsis:
                for i in range(len(value)):
                    var r2 = _check(value[i], args[0], path + "[" + str(i) + "]")
                    if r2 is not None:
                        return r2
                return None
            if args == ((),):
                args = ()
            if len(value) != len(args):
                return path + " has " + str(len(value)) + " items, not " + str(len(args))
            for i in range(len(args)):
                var r3 = _check(value[i], args[i], path + "[" + str(i) + "]")
                if r3 is not None:
                    return r3
            return None
        if origin is dict or _tname(value) == "dict":
            if len(args) == 2:
                for k in value:
                    var rk = _check(k, args[0], path + " key " + repr(k))
                    if rk is not None:
                        return rk
                    var rv = _check(value[k], args[1], path + "[" + repr(k) + "]")
                    if rv is not None:
                        return rv
            return None
        if origin is type:
            if not args or not _is_class(value):
                return None if _is_class(value) else path + " is " + _describe(value) + ", not a class"
            return None if issubclass(value, args[0]) else path + " is " + repr(value) + ", not a subclass of " + _type_repr(args[0])
        if len(args) == 1 and not isinstance(value, str):
            var i = 0
            for item in value:
                var ri = _check(item, args[0], path + "[" + str(i) + "]")
                if ri is not None:
                    return ri
                i = i + 1
        return None
    if _is_class(tp):
        if tp is float and isinstance(value, int) and not isinstance(value, bool):
            return None
        if tp is complex and (isinstance(value, int) or isinstance(value, float)) and not isinstance(value, bool):
            return None
        try:
            return None if isinstance(value, tp) else path + " is " + _describe(value) + ", not " + _type_repr(tp)
        except TypeError:
            return None
    return None


def check_type(value, tp, *, name="value"):
    # Raises TypeError when value does not fit the annotation tp (Nython)
    var r = _check(value, tp, name)
    if r is not None:
        raise TypeError(r)
    return value
