# nython: module    (import it by name: it runs in a module scope of its own)
# lib/dataclasses.ny - Python's dataclasses module: CPython 3.11's
# Lib/dataclasses.py, its algorithms and its messages (round 77).
#
#     from dataclasses import dataclass, field, asdict, replace
#     @dataclass(order=True, frozen=True)
#     class Point:
#         x: int
#         y: int = 0
#         tags: list = field(default_factory=list, compare=False)
#
# dataclass(cls=None, /, *, init, repr, eq, order, unsafe_hash, frozen,
#           match_args, kw_only, slots, weakref_slot)
#                   bare (@dataclass) or called; the fields are the class
#                   body's __annotations__ in definition order, a base
#                   dataclass's first (a redefined field keeps its place);
#                   generates __init__ (CPython's messages for a call that
#                   does not fit: "Point.__init__() missing 1 required
#                   positional argument: 'y'"), __repr__ (recursion-safe),
#                   __eq__, the four orderings, __hash__ by CPython's table
#                   (unsafe_hash / eq / frozen / an explicit __hash__),
#                   frozen __setattr__/__delattr__ (FrozenInstanceError),
#                   __match_args__ (class patterns: case Point(x, y)),
#                   __doc__ ("Point(x: int, y: int = 0)"); a method the body
#                   defines is never overwritten
# field(*, default, default_factory, init, repr, hash, compare, metadata,
#       kw_only)    Field objects (Python's repr); a descriptor default gets
#                   __set_name__
# KW_ONLY (`_: KW_ONLY`), InitVar (InitVar[int], passed to __post_init__),
# ClassVar exclusion (typing.ClassVar, or a string annotation naming it -
# matched by its text, as CPython does), __post_init__, the mutable-default
# ValueError, "non-default argument 'y' follows default argument",
# fields(), asdict()/astuple() (recursive through dataclasses, lists, tuples,
# dicts; other values deep-copied; dict_factory=/tuple_factory=), replace(),
# is_dataclass(), make_dataclass(), FrozenInstanceError, MISSING,
# __dataclass_fields__ / __dataclass_params__
#
# The generated methods are built from Python source, as CPython builds
# them - but all of a class's methods in one exec (CPython 3.13 batches them
# the same way; 3.11 compiles each separately), so a dataclass costs one
# parse, and instances are made by the engines' own argument binding.
#
# Not here: slots=True is accepted and sets __slots__ on the class, but the
# class is not rebuilt and attributes outside the fields are not refused
# (Nython does not enforce __slots__); weakref_slot is checked and ignored;
# abc.update_abstractmethods is not called; __doc__ is made from the fields
# even when the class defines its own __init__; a string annotation is
# recognised as ClassVar / InitVar / KW_ONLY by its text, without looking the
# name up in the class's module (CPython checks the module's binding).
import copy as _copy

__all__ = ["dataclass", "field", "Field", "FrozenInstanceError", "InitVar", "KW_ONLY", "MISSING",
           "fields", "asdict", "astuple", "make_dataclass", "replace", "is_dataclass"]


class FrozenInstanceError(AttributeError):
    # Raised when an attempt is made to modify a frozen class.
    pass


class _HAS_DEFAULT_FACTORY_CLASS:
    # A sentinel object for default values to signal that a default factory
    # will be used.
    def __repr__(self):
        return "<factory>"
_HAS_DEFAULT_FACTORY = _HAS_DEFAULT_FACTORY_CLASS()

class _MISSING_TYPE:
    # A sentinel object to detect if a parameter is supplied or not.
    def __repr__(self):
        return "<dataclasses._MISSING_TYPE object>"
MISSING = _MISSING_TYPE()

class _KW_ONLY_TYPE:
    # A sentinel object to indicate that following fields are keyword-only.
    def __repr__(self):
        return "<dataclasses._KW_ONLY_TYPE object>"
KW_ONLY = _KW_ONLY_TYPE()


class _MetadataProxy:
    # Field.metadata: a read-only view of the mapping given (CPython's
    # types.MappingProxyType)
    def __init__(self, mapping):
        self._mapping = mapping
    def __getitem__(self, key):
        return self._mapping[key]
    def __setitem__(self, key, value):
        raise TypeError("'mappingproxy' object does not support item assignment")
    def __iter__(self):
        return iter(list(self._mapping.keys()))
    def __len__(self):
        return len(self._mapping)
    def __contains__(self, key):
        return key in self._mapping
    def keys(self):
        return self._mapping.keys()
    def values(self):
        return self._mapping.values()
    def items(self):
        return self._mapping.items()
    def get(self, key, default=none):
        return self._mapping.get(key, default)
    def copy(self):
        return dict(self._mapping)
    def __eq__(self, other):
        if isinstance(other, _MetadataProxy):
            other = other._mapping
        return self._mapping == other
    def __repr__(self):
        return "mappingproxy(" + repr(self._mapping) + ")"

_EMPTY_METADATA = _MetadataProxy({})


# Markers for the various kinds of fields and pseudo-fields.
class _FIELD_BASE:
    def __init__(self, name):
        self.name = name
    def __repr__(self):
        return self.name
_FIELD = _FIELD_BASE("_FIELD")
_FIELD_CLASSVAR = _FIELD_BASE("_FIELD_CLASSVAR")
_FIELD_INITVAR = _FIELD_BASE("_FIELD_INITVAR")

# The name of an attribute on the class where we store the Field objects.
# Also used to check if a class is a Data Class.
_FIELDS = "__dataclass_fields__"
# The name of an attribute on the class that stores the parameters to
# @dataclass.
_PARAMS = "__dataclass_params__"
# The name of the function, that if it exists, is called at the end of
# __init__.
_POST_INIT_NAME = "__post_init__"


def _is_type_obj(t):
    # a class or a builtin type (isinstance(t, type) does not hold for the
    # builtin types here)
    return type(t) is type or isinstance(t, type)

def _type_name(t):
    if _is_type_obj(t):
        return t.__name__
    return repr(t)


class InitVar:
    def __init__(self, type):
        self.type = type

    def __repr__(self):
        return "dataclasses.InitVar[" + _type_name(self.type) + "]"

    def __class_getitem__(cls, type):
        return InitVar(type)


class Field:
    # A field: name and type are filled in when the class is processed.
    def __init__(self, default, default_factory, init, repr, hash, compare, metadata, kw_only):
        self.name = none
        self.type = none
        self.default = default
        self.default_factory = default_factory
        self.init = init
        self.repr = repr
        self.hash = hash
        self.compare = compare
        self.metadata = _EMPTY_METADATA if metadata is none else _MetadataProxy(metadata)
        self.kw_only = kw_only
        self._field_type = none

    def __repr__(self):
        return ("Field(" + "name=" + _r(self.name) + "," + "type=" + _r(self.type) + "," +
                "default=" + _r(self.default) + "," + "default_factory=" + _r(self.default_factory) + "," +
                "init=" + _r(self.init) + "," + "repr=" + _r(self.repr) + "," + "hash=" + _r(self.hash) + "," +
                "compare=" + _r(self.compare) + "," + "metadata=" + _r(self.metadata) + "," +
                "kw_only=" + _r(self.kw_only) + "," + "_field_type=" + str(self._field_type) + ")")

    # PEP 487 __set_name__ for a field whose default is a descriptor: the
    # descriptor's own __set_name__ runs (the Field is later replaced in the
    # class by that default)
    def __set_name__(self, owner, name):
        d = self.default
        if d is MISSING or isinstance(d, (int, float, str, bool, tuple, list, dict)) or d is none:
            return
        if hasattr(d, "__set_name__") and not _is_type_obj(d):
            d.__set_name__(owner, name)

def _r(x):
    return repr(x)


class _DataclassParams:
    def __init__(self, init, repr, eq, order, unsafe_hash, frozen):
        self.init = init
        self.repr = repr
        self.eq = eq
        self.order = order
        self.unsafe_hash = unsafe_hash
        self.frozen = frozen

    def __repr__(self):
        return ("_DataclassParams(" + "init=" + _r(self.init) + "," + "repr=" + _r(self.repr) + "," +
                "eq=" + _r(self.eq) + "," + "order=" + _r(self.order) + "," +
                "unsafe_hash=" + _r(self.unsafe_hash) + "," + "frozen=" + _r(self.frozen) + ")")


def field(*, default=MISSING, default_factory=MISSING, init=true, repr=true,
          hash=none, compare=true, metadata=none, kw_only=MISSING):
    # an object to identify dataclass fields (it is an error to specify both
    # default and default_factory)
    if default is not MISSING and default_factory is not MISSING:
        raise ValueError("cannot specify both default and default_factory")
    return Field(default, default_factory, init, repr, hash, compare, metadata, kw_only)


def _fields_in_init_order(flds):
    # the fields as __init__ takes them: the normal ones, then the
    # keyword-only ones
    return [[f for f in flds if f.init and not f.kw_only], [f for f in flds if f.init and f.kw_only]]


def _tuple_str(obj_name, flds):
    # "(self.x,self.y,)" for fields x and y (the 0-tuple is "()")
    if not flds:
        return "()"
    return "(" + ",".join([obj_name + "." + f.name for f in flds]) + ",)"


# ── string annotations: ClassVar / InitVar / KW_ONLY by their text ───────────
def _ann_ident(annotation):
    # "typing.ClassVar[int]" -> ["typing", "ClassVar"]; "ClassVar" -> [none,
    # "ClassVar"] (CPython's _MODULE_IDENTIFIER_RE: ^(?:\s*(\w+)\s*\.)?\s*(\w+))
    s = annotation.strip()
    def word(i):
        j = i
        while j < len(s) and (s[j].isalnum() or s[j] == "_"):
            j += 1
        return j
    i = word(0)
    if i == 0:
        return none
    first = s[0:i]
    j = i
    while j < len(s) and s[j] == " ":
        j += 1
    if j < len(s) and s[j] == ".":
        j += 1
        while j < len(s) and s[j] == " ":
            j += 1
        k = word(j)
        if k == j:
            return none
        return [first, s[j:k]]
    return [none, first]

def _str_ann_is(annotation, name, modules):
    if not isinstance(annotation, str):
        return false
    m = _ann_ident(annotation)
    if m is none or m[1] != name:
        return false
    return m[0] is none or m[0] in modules

def _is_classvar(a_type):
    # typing.ClassVar / typing.ClassVar[X] - by its _name (CPython's typing
    # objects carry it) or its repr, so any typing module's ClassVar is seen
    if isinstance(a_type, str) or a_type is none or isinstance(a_type, (int, float)):
        return false
    if getattr(a_type, "_name", none) == "ClassVar":
        return true
    origin = getattr(a_type, "__origin__", none)
    if origin is not none and getattr(origin, "_name", none) == "ClassVar":
        return true
    r = repr(a_type)
    return r == "typing.ClassVar" or r.startswith("typing.ClassVar[")

def _is_initvar(a_type):
    return a_type is InitVar or isinstance(a_type, InitVar)

def _is_kw_only(a_type):
    return a_type is KW_ONLY


def _own_annotations(cls):
    # the annotations the class body itself made (not a base's)
    d = cls.__dict__
    if "__annotations__" in d:
        return d["__annotations__"]
    ann = getattr(cls, "__annotations__", none)
    if not ann:
        return {}
    for b in cls.__mro__[1:]:
        if getattr(b, "__annotations__", none) is ann:
            return {}
    return ann


def _unhashable(v):
    # CPython's proxy for mutability: the default's class has __hash__ None
    if isinstance(v, (list, dict, set, bytearray)):
        return true
    if isinstance(v, (int, float, str, bytes, tuple, frozenset, bool)) or v is none:
        return false
    t = type(v)
    if isinstance(t, str):
        return false
    return getattr(t, "__hash__", 0) is none


def _get_field(cls, a_name, a_type, default_kw_only):
    # the Field for this name and type; ClassVars and InitVars are returned
    # too, marked as such (f._field_type)
    default = getattr(cls, a_name, MISSING)
    if isinstance(default, Field):
        f = default
    else:
        f = field(default=default)
    f.name = a_name
    f.type = a_type
    f._field_type = _FIELD
    if _is_classvar(a_type) or _str_ann_is(a_type, "ClassVar", ["typing"]):
        f._field_type = _FIELD_CLASSVAR
    if f._field_type is _FIELD:
        if _is_initvar(a_type) or _str_ann_is(a_type, "InitVar", ["dataclasses"]):
            f._field_type = _FIELD_INITVAR
    # Special restrictions for ClassVar and InitVar.
    if f._field_type is _FIELD_CLASSVAR or f._field_type is _FIELD_INITVAR:
        if f.default_factory is not MISSING:
            raise TypeError("field " + f.name + " cannot have a default factory")
    # kw_only validation and assignment.
    if f._field_type is _FIELD or f._field_type is _FIELD_INITVAR:
        if f.kw_only is MISSING:
            f.kw_only = default_kw_only
    elif f.kw_only is not MISSING:
        raise TypeError("field " + f.name + " is a ClassVar but specifies kw_only")
    # For real fields, disallow mutable defaults.
    if f._field_type is _FIELD and f.default is not MISSING and _unhashable(f.default):
        raise ValueError("mutable default " + str(type(f.default)) + " for field " + f.name +
                         " is not allowed: use default_factory")
    return f


# ── the generated methods ────────────────────────────────────────────────────
class _FuncBuilder:
    # Collects the source of a class's methods and the values they refer to,
    # then makes all of them with one exec.
    def __init__(self):
        self.names = []
        self.srcs = []
        self.locals = {}
        self.counter = 0

    def local(self, name, value):
        self.locals[name] = value
        return name

    def add(self, name, args, body, return_type=MISSING):
        ret = ""
        if return_type is not MISSING:
            self.locals["_return_type"] = return_type
            ret = "->_return_type"
        txt = "  def " + name + "(" + ",".join(args) + ")" + ret + ":\n"
        for b in body:
            txt += "   " + b + "\n"
        self.names.append(name)
        self.srcs.append(txt)

    def build(self, qual):
        if not self.names:
            return {}
        params = list(self.locals.keys())
        src = "def _dc_create_fn(" + ",".join(params) + "):\n"
        for s in self.srcs:
            src += s
        src += "  return [" + ",".join(self.names) + "]\n"
        ns = {}
        exec(src, ns)
        made = ns["_dc_create_fn"](*[self.locals[k] for k in params])
        out = {}
        i = 0
        for n in self.names:
            fn = made[i]
            fn.__qualname__ = qual + "." + fn.__name__
            out[n] = fn
            i += 1
        return out


def _field_assign(frozen, name, value, self_name):
    # frozen classes assign their fields through object.__setattr__
    if frozen:
        return "__dataclass_builtins_object__.__setattr__(" + self_name + "," + repr(name) + "," + value + ")"
    return self_name + "." + name + "=" + value

def _field_init(f, frozen, b, self_name, slots):
    # the line of __init__ that initializes this field (none: nothing to do)
    default_name = "_dflt_" + f.name
    if f.default_factory is not MISSING:
        b.local(default_name, f.default_factory)
        if f.init:
            value = default_name + "() if " + f.name + " is _HAS_DEFAULT_FACTORY else " + f.name
        else:
            value = default_name + "()"
    else:
        if f.init:
            if f.default is not MISSING:
                b.local(default_name, f.default)
            value = f.name
        else:
            if slots and f.default is not MISSING:
                b.local(default_name, f.default)
                value = default_name
            else:
                # reading the field uses the class attribute holding the default
                return none
    if f._field_type is _FIELD_INITVAR:
        return none
    return _field_assign(frozen, f.name, value, self_name)

def _init_param(f):
    # the __init__ parameter for this field: 'x:_type_x=_dflt_x'
    if f.default is MISSING and f.default_factory is MISSING:
        default = ""
    elif f.default is not MISSING:
        default = "=_dflt_" + f.name
    else:
        default = "=_HAS_DEFAULT_FACTORY"
    return f.name + ":_type_" + f.name + default

def _init_fn(b, flds, std_fields, kw_only_fields, frozen, has_post_init, self_name, slots, emit):
    # fields without defaults may not follow fields with defaults
    seen_default = false
    for f in std_fields:
        if f.init:
            if not (f.default is MISSING and f.default_factory is MISSING):
                seen_default = true
            elif seen_default:
                raise TypeError("non-default argument " + repr(f.name) + " follows default argument")
    if not emit:
        # the class defines its own __init__
        return none
    for f in flds:
        b.local("_type_" + f.name, f.type)
    b.local("MISSING", MISSING)
    b.local("_HAS_DEFAULT_FACTORY", _HAS_DEFAULT_FACTORY)
    b.local("__dataclass_builtins_object__", object)
    body = []
    for f in flds:
        line = _field_init(f, frozen, b, self_name, slots)
        if line:
            body.append(line)
    if has_post_init:
        params_str = ",".join([f.name for f in flds if f._field_type is _FIELD_INITVAR])
        body.append(self_name + "." + _POST_INIT_NAME + "(" + params_str + ")")
    if not body:
        body = ["pass"]
    params = [_init_param(f) for f in std_fields]
    if kw_only_fields:
        params.append("*")
        params += [_init_param(f) for f in kw_only_fields]
    b.add("__init__", [self_name] + params, body, none)

def _repr_fn(b, flds):
    b.local("_repr_running", set())
    parts = []
    first = true
    for f in flds:
        parts.append(repr((", " if not first else "") + f.name + "=") + "+repr(self." + f.name + ")")
        first = false
    text = "self.__class__.__qualname__+'('" + "".join(["+" + p for p in parts]) + "+')'"
    b.add("__repr__", ["self"], ["_k = id(self)",
                                "if _k in _repr_running:",
                                "    return '...'",
                                "_repr_running.add(_k)",
                                "try:",
                                "    return " + text,
                                "finally:",
                                "    _repr_running.discard(_k)"])

def _frozen_get_del_attr(b, cls, flds):
    b.local("cls", cls)
    b.local("FrozenInstanceError", FrozenInstanceError)
    if flds:
        fields_str = "(" + ",".join([repr(f.name) for f in flds]) + ",)"
    else:
        fields_str = "()"
    b.add("__setattr__", ["self", "name", "value"],
          ["if type(self) is cls or name in " + fields_str + ":",
           "    raise FrozenInstanceError('cannot assign to field ' + repr(name))",
           "super(cls, self).__setattr__(name, value)"])
    b.add("__delattr__", ["self", "name"],
          ["if type(self) is cls or name in " + fields_str + ":",
           "    raise FrozenInstanceError('cannot delete field ' + repr(name))",
           "super(cls, self).__delattr__(name)"])

def _cmp_fn(b, name, op, self_tuple, other_tuple):
    b.add(name, ["self", "other"],
          ["if other.__class__ is self.__class__:",
           "    return " + self_tuple + op + other_tuple,
           "return NotImplemented"])

def _hash_fn(b, flds):
    self_tuple = _tuple_str("self", flds)
    b.add("__hash__", ["self"], ["return hash(" + self_tuple + ")"])


# CPython's _hash_action table: (unsafe_hash, eq, frozen, has-explicit-hash)
# -> none (leave it), "none" (set __hash__ to None), "add", "exception".
def _hash_action(unsafe_hash, eq, frozen, has_explicit_hash):
    if not unsafe_hash:
        if not eq:
            return none
        if not frozen:
            return none if has_explicit_hash else "none"
        return none if has_explicit_hash else "add"
    return "exception" if has_explicit_hash else "add"


_BUILTIN_TYPES = [int, str, float, bool, list, dict, tuple, set, frozenset, bytes, bytearray, complex, object, type]

def _format_annotation(a):
    # inspect.formatannotation, for the class's __doc__ signature
    if isinstance(a, str):
        return repr(a)
    for t in _BUILTIN_TYPES:
        if a is t:
            return a.__name__
    if _is_type_obj(a):
        mod = getattr(a, "__module__", "builtins")
        if mod == "builtins":
            return a.__name__
        return mod + "." + a.__name__
    r = repr(a)
    if r.startswith("typing."):
        return r.replace("typing.", "")
    return r

def _text_sig(std_fields, kw_only_fields):
    def one(f):
        s = f.name
        if f.type is not none:
            s += ": " + _format_annotation(f.type)
        if f.default is not MISSING:
            s += " = " + repr(f.default)
        elif f.default_factory is not MISSING:
            s += " = <factory>"
        return s
    parts = [one(f) for f in std_fields]
    if kw_only_fields:
        parts.append("*")
        parts += [one(f) for f in kw_only_fields]
    return "(" + ", ".join(parts) + ")"


def _process_class(cls, init, repr, eq, order, unsafe_hash, frozen, match_args, kw_only, slots, weakref_slot):
    # The fields: base dataclasses' first (in reverse MRO order, so a more
    # derived class's definition replaces a base's but keeps its place),
    # then the class's own, in definition order.
    flds = {}
    own = cls.__dict__
    _ny_setattr_raw(cls, _PARAMS, _DataclassParams(init, repr, eq, order, unsafe_hash, frozen))
    any_frozen_base = false
    has_dataclass_bases = false
    mro = list(cls.__mro__)
    i = len(mro) - 1
    while i > 0:
        b = mro[i]
        i -= 1
        base_fields = getattr(b, _FIELDS, none)
        if base_fields is not none and not isinstance(base_fields, (int, str)):
            has_dataclass_bases = true
            for name in base_fields:
                f = base_fields[name]
                flds[f.name] = f
            if getattr(b, _PARAMS).frozen:
                any_frozen_base = true
    cls_annotations = _own_annotations(cls)
    cls_fields = []
    KW_ONLY_seen = false
    for name in cls_annotations:
        a_type = cls_annotations[name]
        if _is_kw_only(a_type) or _str_ann_is(a_type, "KW_ONLY", ["dataclasses"]):
            if KW_ONLY_seen:
                raise TypeError(repr_of(name) + " is KW_ONLY, but KW_ONLY has already been specified")
            KW_ONLY_seen = true
            kw_only = true
        else:
            cls_fields.append(_get_field(cls, name, a_type, kw_only))
    for f in cls_fields:
        flds[f.name] = f
        # a Field() class attribute is replaced by the real default (or
        # removed when there is none)
        if f.name in own and isinstance(own[f.name], Field):
            if f.default is MISSING:
                _ny_delattr_raw(cls, f.name)
            else:
                _ny_setattr_raw(cls, f.name, f.default)
    # Field members that don't also have annotations?
    for name in own:
        if isinstance(own[name], Field) and not name in cls_annotations:
            raise TypeError(repr_of(name) + " is a field but has no type annotation")
    if has_dataclass_bases:
        if any_frozen_base and not frozen:
            raise TypeError("cannot inherit non-frozen dataclass from a frozen one")
        if not any_frozen_base and frozen:
            raise TypeError("cannot inherit frozen dataclass from a non-frozen one")
    # Remember all of the fields on our class (including bases). This also
    # marks this class as being a dataclass.
    _ny_setattr_raw(cls, _FIELDS, flds)
    # Was this class defined with an explicit __hash__?
    class_hash = own.get("__hash__", MISSING)
    has_explicit_hash = not (class_hash is MISSING or (class_hash is none and "__eq__" in own))
    if order and not eq:
        raise ValueError("eq must be true if order is true")
    all_init_fields = [flds[n] for n in flds if flds[n]._field_type is _FIELD or flds[n]._field_type is _FIELD_INITVAR]
    split = _fields_in_init_order(all_init_fields)
    std_init_fields = split[0]
    kw_only_init_fields = split[1]
    b = _FuncBuilder()
    if init:
        has_post_init = hasattr(cls, _POST_INIT_NAME)
        _init_fn(b, all_init_fields, std_init_fields, kw_only_init_fields, frozen, has_post_init,
                 "__dataclass_self__" if "self" in flds else "self", slots, "__init__" not in own)
    field_list = [flds[n] for n in flds if flds[n]._field_type is _FIELD]
    if repr and "__repr__" not in own:
        _repr_fn(b, [f for f in field_list if f.repr])
    cmp_fields = [f for f in field_list if f.compare]
    self_tuple = _tuple_str("self", cmp_fields)
    other_tuple = _tuple_str("other", cmp_fields)
    if eq and "__eq__" not in own:
        _cmp_fn(b, "__eq__", "==", self_tuple, other_tuple)
    if order:
        for p in [["__lt__", "<"], ["__le__", "<="], ["__gt__", ">"], ["__ge__", ">="]]:
            if p[0] in own:
                raise TypeError("Cannot overwrite attribute " + p[0] + " in class " + cls.__name__ +
                                ". Consider using functools.total_ordering")
            _cmp_fn(b, p[0], p[1], self_tuple, other_tuple)
    if frozen:
        for n in ["__setattr__", "__delattr__"]:
            if n in own:
                raise TypeError("Cannot overwrite attribute " + n + " in class " + cls.__name__)
        _frozen_get_del_attr(b, cls, field_list)
    action = _hash_action(bool(unsafe_hash), bool(eq), bool(frozen), has_explicit_hash)
    if action == "exception":
        raise TypeError("Cannot overwrite attribute __hash__ in class " + cls.__name__)
    if action == "add":
        _hash_fn(b, [f for f in field_list if (f.compare if f.hash is none else f.hash)])
    made = b.build(cls.__qualname__)
    for n in made:
        _ny_setattr_raw(cls, n, made[n])
    if action == "none":
        _ny_setattr_raw(cls, "__hash__", none)
    if not getattr(cls, "__doc__", none):
        _ny_setattr_raw(cls, "__doc__", cls.__name__ + _text_sig(std_init_fields, kw_only_init_fields))
    if match_args and "__match_args__" not in own:
        _ny_setattr_raw(cls, "__match_args__", tuple([f.name for f in std_init_fields]))
    if weakref_slot and not slots:
        raise TypeError("weakref_slot is True but slots is False")
    if slots:
        if "__slots__" in own:
            raise TypeError(cls.__name__ + " already specifies __slots__")
        _ny_setattr_raw(cls, "__slots__", tuple([f.name for f in field_list]))
    return cls

def repr_of(x):
    return repr(x)


def dataclass(cls=none, /, *, init=true, repr=true, eq=true, order=false,
              unsafe_hash=false, frozen=false, match_args=true,
              kw_only=false, slots=false, weakref_slot=false):
    # Add dunder methods based on the fields defined in the class.
    def wrap(cls):
        return _process_class(cls, init, repr, eq, order, unsafe_hash, frozen, match_args, kw_only, slots, weakref_slot)
    # See if we're being called as @dataclass or @dataclass().
    if cls is none:
        return wrap
    return wrap(cls)


def fields(class_or_instance):
    # the fields of this dataclass (a class or an instance), as a tuple of
    # Field objects, in definition order; pseudo-fields excluded
    flds = getattr(class_or_instance, _FIELDS, none)
    if flds is none or isinstance(flds, (int, str)):
        raise TypeError("must be called with a dataclass type or instance")
    return tuple([flds[n] for n in flds if flds[n]._field_type is _FIELD])


def _is_dataclass_instance(obj):
    return not _is_type_obj(obj) and hasattr(type(obj), _FIELDS)

def is_dataclass(obj):
    # True for a dataclass or an instance of one
    cls = obj if _is_type_obj(obj) else type(obj)
    if isinstance(cls, str):
        return false
    return hasattr(cls, _FIELDS)


def asdict(obj, *, dict_factory=dict):
    # the fields of a dataclass instance as a new dictionary, recursively
    if not _is_dataclass_instance(obj):
        raise TypeError("asdict() should be called on dataclass instances")
    return _asdict_inner(obj, dict_factory)

def _asdict_inner(obj, dict_factory):
    if _is_dataclass_instance(obj):
        result = []
        for f in fields(obj):
            value = _asdict_inner(getattr(obj, f.name), dict_factory)
            result.append((f.name, value))
        return dict_factory(result)
    elif isinstance(obj, tuple) and hasattr(obj, "_fields"):
        # a namedtuple: another of the same type
        return type(obj)(*[_asdict_inner(v, dict_factory) for v in obj])
    elif isinstance(obj, (list, tuple)):
        return type(obj)([_asdict_inner(v, dict_factory) for v in obj])
    elif isinstance(obj, dict):
        if hasattr(type(obj), "default_factory"):
            # a defaultdict: same default_factory (as 3.12)
            result = type(obj)(obj.default_factory)
            for k in obj:
                result[_asdict_inner(k, dict_factory)] = _asdict_inner(obj[k], dict_factory)
            return result
        return type(obj)([(_asdict_inner(k, dict_factory), _asdict_inner(obj[k], dict_factory)) for k in obj])
    else:
        return _copy.deepcopy(obj)


def astuple(obj, *, tuple_factory=tuple):
    # the field values of a dataclass instance as a new tuple, recursively
    if not _is_dataclass_instance(obj):
        raise TypeError("astuple() should be called on dataclass instances")
    return _astuple_inner(obj, tuple_factory)

def _astuple_inner(obj, tuple_factory):
    if _is_dataclass_instance(obj):
        result = []
        for f in fields(obj):
            result.append(_astuple_inner(getattr(obj, f.name), tuple_factory))
        return tuple_factory(result)
    elif isinstance(obj, tuple) and hasattr(obj, "_fields"):
        return type(obj)(*[_astuple_inner(v, tuple_factory) for v in obj])
    elif isinstance(obj, (list, tuple)):
        return type(obj)([_astuple_inner(v, tuple_factory) for v in obj])
    elif isinstance(obj, dict):
        if hasattr(type(obj), "default_factory"):
            result = type(obj)(obj.default_factory)
            for k in obj:
                result[_astuple_inner(k, tuple_factory)] = _astuple_inner(obj[k], tuple_factory)
            return result
        return type(obj)([(_astuple_inner(k, tuple_factory), _astuple_inner(obj[k], tuple_factory)) for k in obj])
    else:
        return _copy.deepcopy(obj)


_KEYWORDS = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
             "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
             "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
             "return", "try", "while", "with", "yield"]

def make_dataclass(cls_name, fields, *, bases=(), namespace=none, init=true, repr=true, eq=true,
                   order=false, unsafe_hash=false, frozen=false, match_args=true, kw_only=false,
                   slots=false, weakref_slot=false):
    # a new dataclass named cls_name; fields is an iterable of name,
    # (name, type) or (name, type, Field)
    if namespace is none:
        namespace = {}
    seen = []
    annotations = {}
    defaults = {}
    for item in fields:
        if isinstance(item, str):
            name = item
            tp = "typing.Any"
        elif len(item) == 2:
            name = item[0]
            tp = item[1]
        elif len(item) == 3:
            name = item[0]
            tp = item[1]
            defaults[name] = item[2]
        else:
            raise TypeError("Invalid field: " + repr_of(item))
        if not isinstance(name, str) or not name.isidentifier():
            raise TypeError("Field names must be valid identifiers: " + repr_of(name))
        if name in _KEYWORDS:
            raise TypeError("Field names must not be keywords: " + repr_of(name))
        if name in seen:
            raise TypeError("Field name duplicated: " + repr_of(name))
        seen.append(name)
        annotations[name] = tp
    ns = {}
    for k in namespace:
        ns[k] = namespace[k]
    for k in defaults:
        ns[k] = defaults[k]
    ns["__annotations__"] = annotations
    meta = type
    for bb in bases:
        if type(bb) is not type and isinstance(bb, type):
            meta = type(bb)
    cls = meta(cls_name, tuple(bases), ns)
    return dataclass(cls, init=init, repr=repr, eq=eq, order=order, unsafe_hash=unsafe_hash, frozen=frozen,
                     match_args=match_args, kw_only=kw_only, slots=slots, weakref_slot=weakref_slot)


def replace(obj, /, **changes):
    # a new object of obj's class, with the given fields changed (init=False
    # fields cannot be; an InitVar without a default must be given)
    if not _is_dataclass_instance(obj):
        raise TypeError("replace() should be called on dataclass instances")
    flds = getattr(obj, _FIELDS)
    for n in flds:
        f = flds[n]
        if f._field_type is _FIELD_CLASSVAR:
            continue
        if not f.init:
            if f.name in changes:
                raise ValueError("field " + f.name + " is declared with init=False, it cannot be specified with replace()")
            continue
        if f.name not in changes:
            if f._field_type is _FIELD_INITVAR and f.default is MISSING:
                raise ValueError("InitVar " + repr_of(f.name) + " must be specified with replace()")
            changes[f.name] = getattr(obj, f.name)
    return type(obj)(**changes)
