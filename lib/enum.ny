# nython: module    (import it by name: it runs in a module scope of its own)
# lib/enum.ny - Python's enum module: CPython 3.11's Lib/enum.py, its
# algorithms and its messages (round 77).
#
#     from enum import Enum, IntEnum, StrEnum, Flag, IntFlag, auto, unique
#     class Color(Enum):
#         RED = 1
#         GREEN = auto()
#     Color.RED, Color["RED"], Color(1), list(Color), Color.RED.name / .value
#
# EnumType (EnumMeta)  the metaclass: members are made from the class body in
#                      definition order (_ignore_, descriptors, dunders,
#                      _sunder_ and private names are not members); Color.RED,
#                      Color["RED"], Color(1) (by value, then _missing_),
#                      iter / reversed / len / in, __members__ (aliases
#                      included, a read-only mapping), repr <enum 'Color'>,
#                      members cannot be reassigned or deleted, a class with
#                      members cannot be subclassed; the functional API
#                      Enum("Color", "RED GREEN") / a list of names / a list
#                      of (name, value) pairs / a dict, with module=,
#                      qualname=, type=, start=, boundary=
# Enum                 name/value/_name_/_value_, reprs and strs as CPython
#                      (<Color.RED: 1>, Color.RED), format() as str(), hash of
#                      the name, aliases for duplicate values, members are
#                      singletons (copy/deepcopy give the member), an __init__
#                      receiving a tuple value's items, a __new__ setting
#                      _value_, _missing_, _generate_next_value_, _order_,
#                      _ignore_, members as dict keys / in sets / in match
#                      statements (case Color.RED:)
# ReprEnum, IntEnum, StrEnum   a member is an int (str): it compares, hashes,
#                      does arithmetic (or string methods) as its value, and
#                      isinstance(member, int) holds; str()/format() are the
#                      value's, repr is the enum's
# Flag, IntFlag        | & ^ ~, membership, iteration over the set flags,
#                      len, bool, aliases for multi-bit values, pseudo-members
#                      for combinations (<Perm.R|W: 6>, Perm(0)), boundaries
#                      STRICT (Flag's default), CONFORM, EJECT, KEEP
#                      (IntFlag's default), as 3.11
# auto, member, nonmember, unique, verify + EnumCheck (UNIQUE, CONTINUOUS,
# NAMED_FLAGS), FlagBoundary, property (enum.property), global_enum_repr,
# global_flag_repr, global_str, global_enum, show_flag_values, bin
#
# How it is built: Nython has no __prepare__ (the class body runs in the
# engine's own namespace), so what CPython's _EnumDict checks while the body
# runs is checked by EnumType.__new__ over the namespace it receives, which
# keeps definition order. Members are made by _proto_member.__set_name__,
# which type.__new__ runs in definition order before __init_subclass__, as in
# CPython. Inside the body an auto() is still an auto object, so arithmetic
# on it (RW = R | W) is kept as an expression and computed when the member is
# made - in CPython R and W are already ints on that line.
#
# A member whose enum mixes in a builtin type (int, str, float, ...) is not a
# value of that type (a builtin type cannot be subclassed by value here): the
# enum class gets the type's operators, comparisons, hash and methods,
# delegated to the member's _value_ - so IntEnum.A + 1, IntEnum.A == 1,
# lst[IntEnum.A], range(IntEnum.A), "%d" % IntEnum.A (the engines honour
# __index__), "s" + StrEnum.B, StrEnum.B.upper() work, and
# isinstance(IntEnum.A, int) is true.
#
# Not here: an IntEnum member and the equal int are different dict keys and
# set elements ({1: x}[IntEnum.A] is a KeyError: the engines key objects by
# class and __hash__); pickling (__reduce_ex__ is kept, no pickle module); a
# name assigned twice in a body (CPython's "Attempted to reuse key") cannot
# be seen without __prepare__, the second value wins; global_enum cannot
# export the members into the module's namespace (no sys.modules);
# _simple_enum / _convert_; a user __new__ calling int.__new__ / str.__new__
# (use object.__new__ and set _value_); 3.11's DeprecationWarnings are not
# issued; where 3.12 differs (`1 in Color` is True there, a TypeError in
# 3.11), 3.11 is followed.

__all__ = ["EnumType", "EnumMeta", "Enum", "IntEnum", "StrEnum", "Flag", "IntFlag", "ReprEnum",
           "auto", "unique", "property", "verify", "member", "nonmember",
           "FlagBoundary", "STRICT", "CONFORM", "EJECT", "KEEP",
           "global_flag_repr", "global_enum_repr", "global_str", "global_enum",
           "EnumCheck", "CONTINUOUS", "NAMED_FLAGS", "UNIQUE", "show_flag_values"]

# The builtins this module's own names shadow (enum.property, enum.bin).
_bltn_property = property
_bltn_bin = bin

# Dummy values for Enum and Flag: there are explicit checks for them before
# they have been created (as in CPython).
Enum = none
Flag = none
EJECT = none
KEEP = none
STRICT = none
CONFORM = none
ReprEnum = none


class nonmember(object):
    # Protects item from becoming an Enum member during class creation.
    def __init__(self, value):
        self.value = value

class member(object):
    # Forces item to become an Enum member during class creation.
    def __init__(self, value):
        self.value = value


def _is_descriptor(obj):
    # Python: an object with __get__, __set__ or __delete__. A Nython class
    # body's functions (methods, static and class methods, lambdas) and
    # properties have none of them, so they are named here.
    if hasattr(obj, "__get__") or hasattr(obj, "__set__") or hasattr(obj, "__delete__"):
        return true
    if type(obj) == "function":
        return true
    if isinstance(obj, (int, float, str, bytes, tuple, list, dict, set)) or obj is none:
        return false
    return hasattr(obj, "fget") and hasattr(obj, "fset")

def _is_dunder(name):
    return len(name) > 4 and name[:2] == "__" and name[-2:] == "__" and name[2] != "_" and name[-3] != "_"

def _is_sunder(name):
    return len(name) > 2 and name[0] == "_" and name[-1] == "_" and name[1:2] != "_" and name[-2:-1] != "_"

def _is_private(cls_name, name):
    # _Color__x (Python's mangled form) - and __x as written, since a Nython
    # class body does not mangle private names
    pattern = "_" + cls_name + "__"
    n = len(pattern)
    if len(name) > n and name.startswith(pattern) and name[n:n + 1] != "_" and (name[-1] != "_" or name[-2] != "_"):
        return true
    return len(name) > 2 and name[:2] == "__" and name[2] != "_" and not name.endswith("__")

def _is_single_bit(num):
    if num == 0:
        return false
    num &= num - 1
    return num == 0

def _iter_bits_lsb(num):
    original = num
    if Enum is not none and isinstance(num, Enum):
        num = num.value
    if num < 0:
        raise ValueError("%r is not a positive integer" % (original,))
    while num:
        b = num & (~num + 1)
        yield b
        num ^= b

def show_flag_values(value):
    return list(_iter_bits_lsb(value))

def bin(num, max_bits=none):
    # Like the builtin bin(), except negative values are represented in
    # twos-complement, and the leading bit always indicates sign
    # (0=positive, 1=negative): bin(10) == '0b0 1010', bin(~10) == '0b1 0101'
    ceiling = 2 ** num.bit_length()
    if num >= 0:
        s = _bltn_bin(num + ceiling).replace("1", "0", 1)
    else:
        s = _bltn_bin(~num ^ (ceiling - 1) + ceiling)
    sign = s[:3]
    digits = s[3:]
    if max_bits is not none:
        if len(digits) < max_bits:
            digits = (sign[-1] * max_bits + digits)[-max_bits:]
    return "%s %s" % (sign, digits)

def _high_bit(value):
    # index of the highest bit, or -1 if value is zero or negative
    return value.bit_length() - 1

def _power_of_two(value):
    if value < 1:
        return false
    return value == 2 ** _high_bit(value)


class _auto_null_type:
    def __repr__(self):
        return "_auto_null"
_auto_null = _auto_null_type()

# Operators on auto() values inside a class body (RW = R | W). CPython's
# _EnumDict has replaced R and W by their values when that line runs; without
# __prepare__ they are still auto objects here, so the expression is kept and
# computed when the member is made (its operands, defined earlier, have their
# values by then).
class _AutoOps:
    def __or__(self, o):
        return _AutoExpr(lambda a, b: a | b, self, o)
    def __ror__(self, o):
        return _AutoExpr(lambda a, b: a | b, o, self)
    def __and__(self, o):
        return _AutoExpr(lambda a, b: a & b, self, o)
    def __rand__(self, o):
        return _AutoExpr(lambda a, b: a & b, o, self)
    def __xor__(self, o):
        return _AutoExpr(lambda a, b: a ^ b, self, o)
    def __rxor__(self, o):
        return _AutoExpr(lambda a, b: a ^ b, o, self)
    def __add__(self, o):
        return _AutoExpr(lambda a, b: a + b, self, o)
    def __radd__(self, o):
        return _AutoExpr(lambda a, b: a + b, o, self)
    def __sub__(self, o):
        return _AutoExpr(lambda a, b: a - b, self, o)
    def __rsub__(self, o):
        return _AutoExpr(lambda a, b: a - b, o, self)
    def __mul__(self, o):
        return _AutoExpr(lambda a, b: a * b, self, o)
    def __rmul__(self, o):
        return _AutoExpr(lambda a, b: a * b, o, self)
    def __lshift__(self, o):
        return _AutoExpr(lambda a, b: a << b, self, o)
    def __rshift__(self, o):
        return _AutoExpr(lambda a, b: a >> b, self, o)
    def __invert__(self):
        return _AutoExpr(lambda a, b: ~a, self, none)
    def __neg__(self):
        return _AutoExpr(lambda a, b: -a, self, none)

def _auto_resolve(x):
    if isinstance(x, _AutoExpr):
        return x.fn(_auto_resolve(x.a), _auto_resolve(x.b))
    if isinstance(x, auto):
        if x.value is _auto_null:
            raise TypeError("auto() value used before it was assigned")
        return x.value
    return x

class _AutoExpr(_AutoOps):
    def __init__(self, fn, a, b):
        self.fn = fn
        self.a = a
        self.b = b
    def __repr__(self):
        return "<auto() expression>"

class auto(_AutoOps):
    # Instances are replaced with an appropriate value in Enum class suites.
    def __init__(self, value=_auto_null):
        self.value = value
    def __repr__(self):
        return "auto(%r)" % (self.value,)


class property:
    # enum.property (CPython's is a DynamicClassAttribute): a member reads
    # the attribute through fget, the enum class reads the member of that
    # name - so members called `name` or `value` coexist with the name and
    # value of every member.
    def __init__(self, fget=none, fset=none, fdel=none, doc=none):
        self.fget = fget
        self.fset = fset
        self.fdel = fdel
        self.__doc__ = doc if doc is not none else getattr(fget, "__doc__", none)
        self.name = none
        self.clsname = none
        self.member = none

    def getter(self, fget):
        p = type(self)(fget, self.fset, self.fdel, self.__doc__)
        return p

    def setter(self, fset):
        return type(self)(self.fget, fset, self.fdel, self.__doc__)

    def deleter(self, fdel):
        return type(self)(self.fget, self.fset, fdel, self.__doc__)

    def __get__(self, instance, ownerclass=none):
        if instance is none:
            mm = ownerclass._member_map_
            if self.name in mm:
                return mm[self.name]
            raise AttributeError("%r has no attribute %r" % (ownerclass, self.name))
        if self.fget is none:
            mm = ownerclass._member_map_ if ownerclass is not none else type(instance)._member_map_
            if self.name in mm:
                return mm[self.name]
            raise AttributeError("%r has no attribute %r" % (ownerclass, self.name))
        return self.fget(instance)

    def __set__(self, instance, value):
        if self.fset is none:
            raise AttributeError("<enum %r> cannot set attribute %r" % (self.clsname, self.name))
        return self.fset(instance, value)

    def __delete__(self, instance):
        if self.fdel is none:
            raise AttributeError("<enum %r> cannot delete attribute %r" % (self.clsname, self.name))
        return self.fdel(instance)

    def __set_name__(self, ownerclass, name):
        self.name = name
        self.clsname = ownerclass.__name__


# ── data types mixed into an enum (int, str, float, ...) ─────────────────────
# A member of such an enum is an object holding its value; the enum class
# gets the type's operators, delegated to the value (see the header).
_DATA_TYPES = [int, str, float, bool, bytes, complex]

def _is_data_type(t):
    for d in _DATA_TYPES:
        if t is d:
            return true
    return false

def _dv(x):
    # a data-backed member's value; anything else as it is
    if getattr(type(x), "_ny_data_", false):
        return x._value_
    return x

def _is_num(x):
    return isinstance(x, (int, float, complex)) and not getattr(type(x), "_ny_data_", false)

def _binop(fn, accept):
    def op(self, other):
        o = _dv(other)
        if not accept(o):
            return NotImplemented
        return fn(self._value_, o)
    return op

def _rbinop(fn, accept):
    def op(self, other):
        o = _dv(other)
        if not accept(o):
            return NotImplemented
        return fn(o, self._value_)
    return op

def _unop(fn):
    def op(self):
        return fn(self._value_)
    return op

def _accept_num(o):
    return isinstance(o, (int, float, complex))

def _accept_int(o):
    return isinstance(o, int)

def _accept_str(o):
    return isinstance(o, str)

def _accept_any(o):
    return true

_NUM_OPS = [["add", lambda a, b: a + b], ["sub", lambda a, b: a - b], ["mul", lambda a, b: a * b],
            ["truediv", lambda a, b: a / b], ["floordiv", lambda a, b: a // b], ["mod", lambda a, b: a % b],
            ["pow", lambda a, b: a ** b], ["divmod", lambda a, b: divmod(a, b)]]
_INT_OPS = [["lshift", lambda a, b: a << b], ["rshift", lambda a, b: a >> b], ["and", lambda a, b: a & b],
            ["or", lambda a, b: a | b], ["xor", lambda a, b: a ^ b]]
_CMP_OPS = [["eq", lambda a, b: a == b], ["ne", lambda a, b: a != b], ["lt", lambda a, b: a < b],
            ["le", lambda a, b: a <= b], ["gt", lambda a, b: a > b], ["ge", lambda a, b: a >= b]]

def _num_rmod(self, other):
    # "fmt" % member: an engine may ask the member before formatting; it
    # formats as str.__mod__ would (%d of an IntEnum is its int)
    if isinstance(other, (str, bytes)):
        return other % (self,)
    o = _dv(other)
    if not _accept_num(o):
        return NotImplemented
    return o % self._value_

def _data_hash(self):
    return hash(self._value_)

def _data_bool(self):
    return bool(self._value_)

def _data_str(self):
    return str(self._value_)

def _data_format(self, format_spec):
    return format(self._value_, format_spec)

def _data_getattr(self, name):
    # the value's methods and attributes (bit_length, upper, real...)
    if name[:1] == "_":
        raise AttributeError("'" + type(self).__name__ + "' object has no attribute '" + name + "'")
    v = self._value_
    if hasattr(v, name):
        return getattr(v, name)
    raise AttributeError("'" + type(self).__name__ + "' object has no attribute '" + name + "'")

def _data_len(self):
    return len(self._value_)

def _data_iter(self):
    return iter(self._value_)

def _data_getitem(self, k):
    return self._value_[k]

def _data_contains(self, x):
    return _dv(x) in self._value_

def _data_methods(member_type):
    # name -> function, for an enum mixing in member_type
    m = {"__hash__": _data_hash, "__bool__": _data_bool, "__getattr__": _data_getattr}
    numeric = member_type is int or member_type is bool or member_type is float or member_type is complex
    if numeric:
        for p in _NUM_OPS:
            m["__" + p[0] + "__"] = _binop(p[1], _accept_num)
            m["__r" + p[0] + "__"] = _rbinop(p[1], _accept_num)
        m["__rmod__"] = _num_rmod
        m["__neg__"] = _unop(lambda a: -a)
        m["__pos__"] = _unop(lambda a: +a)
        m["__abs__"] = _unop(lambda a: abs(a))
        m["__int__"] = _unop(lambda a: int(a))
        m["__float__"] = _unop(lambda a: float(a))
        m["__complex__"] = _unop(lambda a: complex(a))
        m["__round__"] = lambda self, n=none: round(self._value_) if n is none else round(self._value_, n)
        if member_type is not float and member_type is not complex:
            for p in _INT_OPS:
                m["__" + p[0] + "__"] = _binop(p[1], _accept_int)
                m["__r" + p[0] + "__"] = _rbinop(p[1], _accept_int)
            m["__invert__"] = _unop(lambda a: ~a)
            m["__index__"] = _unop(lambda a: int(a))
        for p in _CMP_OPS:
            m["__" + p[0] + "__"] = _binop(p[1], _accept_num)
    elif member_type is str or member_type is bytes:
        m["__add__"] = _binop(lambda a, b: a + b, _accept_str if member_type is str else _accept_any)
        m["__radd__"] = _rbinop(lambda a, b: a + b, _accept_str if member_type is str else _accept_any)
        m["__mul__"] = _binop(lambda a, b: a * b, _accept_int)
        m["__rmul__"] = _rbinop(lambda a, b: a * b, _accept_int)
        m["__mod__"] = _binop(lambda a, b: a % b, _accept_any)
        m["__len__"] = _data_len
        m["__iter__"] = _data_iter
        m["__getitem__"] = _data_getitem
        m["__contains__"] = _data_contains
        acc = _accept_str if member_type is str else _accept_any
        for p in _CMP_OPS:
            m["__" + p[0] + "__"] = _binop(p[1], acc)
    return m

def _install_data_type(enum_class, member_type, classdict):
    # what a mixed-in builtin type gives the class (not over the body's own)
    meths = _data_methods(member_type)
    for name in meths:
        if name not in classdict:
            _ny_setattr_raw(enum_class, name, meths[name])
    _ny_setattr_raw(enum_class, "_ny_data_", true)

def _data_str_method(member_type):
    # member_type.__str__ for ReprEnum: the value's str
    return _data_str


class _proto_member:
    # intermediate step for enum members between class execution and final
    # creation: type.__new__ runs __set_name__ on it, in definition order
    def __init__(self, value):
        self.value = value

    def __set_name__(self, enum_class, member_name):
        # convert each quasi-member into an instance of the new enum class
        value = self.value
        if not isinstance(value, tuple):
            args = (value,)
        else:
            args = value
        member_type = enum_class._member_type_
        if member_type is tuple:
            args = (args,)
        new_member = enum_class._ny_new_member_
        if new_member is none:
            enum_member = object.__new__(enum_class)
        elif not enum_class._use_args_:
            enum_member = new_member(enum_class)
        else:
            enum_member = new_member(enum_class, *args)
        if not hasattr(enum_member, "_value_"):
            if member_type is object:
                enum_member._value_ = value
            else:
                try:
                    enum_member._value_ = member_type(*args)
                except Exception as exc:
                    new_exc = TypeError("_value_ not set in __new__, unable to create it")
                    new_exc.__cause__ = exc
                    raise new_exc
        value = enum_member._value_
        enum_member._name_ = member_name
        enum_member.__objclass__ = enum_class
        enum_member.__init__(*args)
        enum_member._sort_order_ = len(enum_class._member_names_)

        is_flag = enum_class._ny_is_flag_
        if is_flag:
            if isinstance(value, int):
                enum_class._flag_mask_ |= value
                if _is_single_bit(value):
                    enum_class._singles_mask_ |= value
            enum_class._all_bits_ = 2 ** (enum_class._flag_mask_.bit_length()) - 1

        # If another member with the same value was already defined, the
        # new member becomes an alias to the existing one.
        found = false
        v2m = enum_class._value2member_map_
        try:
            if value in v2m:
                enum_member = v2m[value]
                found = true
        except TypeError:
            for name in enum_class._member_map_:
                canonical_member = enum_class._member_map_[name]
                if canonical_member._value_ == value:
                    enum_member = canonical_member
                    found = true
                    break
        if not found:
            # this could still be an alias if the value is multi-bit and the
            # class is a flag class
            if not is_flag:
                enum_class._member_names_.append(member_name)
            elif isinstance(value, int) and _is_single_bit(value):
                enum_class._member_names_.append(member_name)
        # if necessary, get redirect in place and then add it to _member_map_
        found_descriptor = enum_class._ny_descr_.get(member_name)
        if found_descriptor is not none:
            redirect = property()
            redirect.member = enum_member
            redirect.__set_name__(enum_class, member_name)
            redirect.fget = found_descriptor.fget
            redirect.fset = getattr(found_descriptor, "fset", none)
            redirect.fdel = getattr(found_descriptor, "fdel", none)
            _ny_setattr_raw(enum_class, member_name, redirect)
        else:
            _ny_setattr_raw(enum_class, member_name, enum_member)
        # now add to _member_map_ (even aliases)
        enum_class._member_map_[member_name] = enum_member
        try:
            if value not in v2m:
                v2m[value] = enum_member
        except TypeError:
            # keep track of the value in a list so containment checks are quick
            enum_class._unhashable_values_.append(value)


class _EnumMembers:
    # Color.__members__: a read-only view of the member map (CPython's
    # mappingproxy), aliases included
    def __init__(self, mapping):
        self._mapping = mapping
    def __getitem__(self, key):
        return self._mapping[key]
    def __setitem__(self, key, value):
        raise TypeError("'mappingproxy' object does not support item assignment")
    def __delitem__(self, key):
        raise TypeError("'mappingproxy' object does not support item deletion")
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
        if isinstance(other, _EnumMembers):
            other = other._mapping
        return self._mapping == other
    def __repr__(self):
        return "mappingproxy(" + repr(self._mapping) + ")"


_SUNDER_ALLOWED = ["_order_", "_generate_next_value_", "_numeric_repr_", "_missing_", "_ignore_",
                   "_iter_member_", "_iter_member_by_value_", "_iter_member_by_def_"]


# ── what the metaclass needs before a class exists ───────────────────────────
def _check_for_existing_members_(class_name, bases):
    for chain in bases:
        if _is_data_type(chain):
            continue
        for base in chain.__mro__:
            if isinstance(base, EnumType) and base._member_names_:
                raise TypeError("<enum %r> cannot extend %r" % (class_name, base))

def _get_mixins_(class_name, bases):
    # the type for creating enum members, and the first inherited enum class
    if not bases:
        return [object, Enum]
    _check_for_existing_members_(class_name, bases)
    first_enum = bases[-1]
    if not isinstance(first_enum, EnumType):
        raise TypeError("new enumerations should be created as `EnumName([mixin_type, ...] [data_type,] enum_type)`")
    member_type = _find_data_type_(class_name, bases)
    if member_type is none:
        member_type = object
    return [member_type, first_enum]

def _find_data_repr_(class_name, bases):
    for chain in bases:
        if _is_data_type(chain):
            return repr
        for base in chain.__mro__:
            if base is object:
                continue
            elif isinstance(base, EnumType):
                # if we hit an Enum, use its _value_repr_
                return base._value_repr_
            elif _is_data_type(base):
                return repr
            else:
                d = base.__dict__
                if "__repr__" in d:
                    return d["__repr__"]
    return none

def _find_data_type_(class_name, bases):
    data_types = []
    for chain in bases:
        if _is_data_type(chain):
            if chain not in data_types:
                data_types.append(chain)
            continue
        candidate = none
        for base in chain.__mro__:
            if base is object:
                continue
            elif isinstance(base, EnumType):
                if base._member_type_ is not object:
                    if base._member_type_ not in data_types:
                        data_types.append(base._member_type_)
                    break
            elif _is_data_type(base):
                if base not in data_types:
                    data_types.append(base)
                break
            else:
                d = base.__dict__
                if "__new__" in d or "__dataclass_fields__" in d:
                    t = candidate if candidate is not none else base
                    if t not in data_types:
                        data_types.append(t)
                    break
                if candidate is none:
                    candidate = base
    if len(data_types) > 1:
        raise TypeError("too many data types for %r: %r" % (class_name, set(data_types)))
    elif data_types:
        return data_types[0]
    return none

def _find_new_(classdict, member_type, first_enum):
    # the __new__ used for creating the enum members (none: object.__new__),
    # whether it should be saved as __new_member__, and whether it gets the
    # member's value as arguments
    nw = classdict.get("__new__", none)
    save_new = first_enum is not none and nw is not none
    if nw is none:
        for method in ["__new_member__", "__new__"]:
            for possible in [member_type, first_enum]:
                if possible is none or possible is object or _is_data_type(possible):
                    continue
                if possible is Enum or (Enum is not none and isinstance(possible, EnumType) and method == "__new__"):
                    # Enum.__new__ is the value lookup, never a member maker
                    continue
                target = getattr(possible, method, none)
                if target is not none and target is not object.__new__:
                    nw = target
                    break
            if nw is not none:
                break
    use_args = not (first_enum is none or nw is none)
    return [nw, save_new, use_args]


def _collect_descriptors(bases):
    # the properties of the bases (enum.property first), by name: a member of
    # such a name is reached through a redirect, so the property keeps
    # working for every member
    found = {}
    seen = []
    for chain in bases:
        if _is_data_type(chain):
            continue
        for base in chain.__mro__:
            if base is object or _is_data_type(base) or base in seen:
                continue
            seen.append(base)
            d = base.__dict__
            for k in d:
                v = d[k]
                if isinstance(v, property):
                    if k not in found or not isinstance(found[k], property):
                        found[k] = v
                elif k not in found and type(v) != "function" and hasattr(v, "fget") and not isinstance(v, (int, str, float)):
                    found[k] = v
    return found


class EnumType(type):
    # Metaclass for Enum

    def __new__(metacls, cls, bases, classdict, boundary=none, _simple=false, **kwds):
        if _simple:
            return super().__new__(metacls, cls, bases, classdict, **kwds)
        mixins = _get_mixins_(cls, bases)
        member_type = mixins[0]
        first_enum = mixins[1]
        #
        # What CPython's _EnumDict checks while the body runs (no
        # __prepare__ here): which names become members, auto() values,
        # _ignore_, nonmember()/member(), the reserved _sunder_ names.
        gnv = none
        if first_enum is not none:
            gnv = getattr(first_enum, "_generate_next_value_", none)
        ignore = []
        if "_ignore_" in classdict:
            ign = classdict["_ignore_"]
            if isinstance(ign, str):
                ignore = ign.replace(",", " ").split()
            else:
                ignore = list(ign)
        member_names = []
        last_values = []
        auto_called = false
        removed = []
        for key in list(classdict.keys()):
            value = classdict[key]
            if _is_private(cls, key):
                pass
            elif _is_sunder(key):
                if key not in _SUNDER_ALLOWED:
                    raise ValueError("_sunder_ names, such as %r, are reserved for future Enum use" % (key,))
                if key == "_generate_next_value_":
                    if auto_called:
                        raise TypeError("_generate_next_value_ must be defined before members")
                    gnv = value
                elif key == "_ignore_":
                    already = [n for n in ignore if n in member_names]
                    if already:
                        raise ValueError("_ignore_ cannot specify already set names: %r" % (set(already),))
            elif _is_dunder(key):
                if key == "__order__":
                    classdict["_order_"] = value
                    del classdict["__order__"]
                    removed.append("__order__")
            elif key in ignore:
                pass
            elif isinstance(value, nonmember):
                # unwrap value here; it won't be processed by the below `else`
                classdict[key] = value.value
            elif _is_descriptor(value):
                pass
            else:
                if isinstance(value, member):
                    # unwrap value here -- it will become a member
                    value = value.value
                if isinstance(value, _AutoExpr):
                    value = _auto_resolve(value)
                non_auto_store = true
                single = false
                if isinstance(value, auto):
                    single = true
                    value = (value,)
                if type(value) is tuple and any([isinstance(v, auto) for v in value]):
                    auto_valued = []
                    for v in value:
                        if isinstance(v, auto):
                            non_auto_store = false
                            if v.value is _auto_null:
                                if gnv is none:
                                    raise TypeError("auto() used without a _generate_next_value_")
                                v.value = gnv(key, 1, len(member_names), last_values[:])
                                auto_called = true
                            v = v.value
                            last_values.append(v)
                        auto_valued.append(v)
                    if single:
                        value = auto_valued[0]
                    else:
                        value = tuple(auto_valued)
                member_names.append(key)
                if non_auto_store:
                    last_values.append(value)
                classdict[key] = value
        #
        # remove any keys listed in _ignore_
        ignore.append("_ignore_")
        for key in ignore:
            if key in classdict:
                del classdict[key]
                removed.append(key)
        #
        # check for illegal enum names (any others?)
        invalid_names = [n for n in member_names if n == "mro" or n == ""]
        if invalid_names:
            raise ValueError("invalid enum member name(s) %s" % (",".join([repr(n) for n in invalid_names]),))
        #
        # adjust the sunders
        _order_ = classdict.get("_order_", none)
        if "_order_" in classdict:
            del classdict["_order_"]
            removed.append("_order_")
        #
        # data type of member and the controlling Enum class
        found = _find_new_(classdict, member_type, first_enum)
        nw = found[0]
        save_new = found[1]
        use_args = found[2]
        classdict["_new_member_"] = nw if nw is not none else object.__new__
        classdict["_ny_new_member_"] = nw
        classdict["_use_args_"] = use_args
        #
        # convert future enum members into temporary _proto_members
        for name in member_names:
            classdict[name] = _proto_member(classdict[name])
        #
        # house-keeping structures
        classdict["_member_names_"] = []
        classdict["_member_map_"] = {}
        classdict["_value2member_map_"] = {}
        classdict["_unhashable_values_"] = []
        classdict["_member_type_"] = member_type
        classdict["_value_repr_"] = _find_data_repr_(cls, bases)
        classdict["_ny_descr_"] = _collect_descriptors(bases)
        #
        # Flag structures (only for a Flag)
        is_flag = false
        if Flag is none:
            is_flag = cls == "Flag"
        else:
            for b in bases:
                if not _is_data_type(b) and issubclass(b, Flag):
                    is_flag = true
        classdict["_ny_is_flag_"] = is_flag
        if is_flag:
            classdict["_boundary_"] = boundary if boundary is not none else getattr(first_enum, "_boundary_", none)
            classdict["_flag_mask_"] = 0
            classdict["_singles_mask_"] = 0
            classdict["_all_bits_"] = 0
            classdict["_inverted_"] = none
        enum_class = super().__new__(metacls, cls, bases, classdict, **kwds)
        # the class was built from its body (type.__new__ adopts it): what
        # the namespace dropped is dropped from the class too
        for key in removed:
            if key not in classdict and hasattr(enum_class, key) and key in enum_class.__dict__:
                _ny_delattr_raw(enum_class, key)
        #
        # update classdict with any changes made by __init_subclass__
        own = enum_class.__dict__
        for k in own:
            classdict[k] = own[k]
        #
        # a builtin data type mixed in: its operators, delegated to the value
        if _is_data_type(member_type) and member_type in bases:
            _install_data_type(enum_class, member_type, classdict)
        #
        # Also, special handling for ReprEnum
        if ReprEnum is not none and ReprEnum in bases:
            if member_type is object:
                raise TypeError("ReprEnum subclasses must be mixed with a data type (i.e. int, str, float, etc.)")
            if "__format__" not in classdict:
                if _is_data_type(member_type):
                    _ny_setattr_raw(enum_class, "__format__", _data_format)
                else:
                    _ny_setattr_raw(enum_class, "__format__", member_type.__format__)
                classdict["__format__"] = enum_class.__format__
            if "__str__" not in classdict:
                if _is_data_type(member_type):
                    _ny_setattr_raw(enum_class, "__str__", _data_str_method(member_type))
                else:
                    method = getattr(member_type, "__str__", none)
                    if method is none:
                        method = getattr(member_type, "__repr__", none)
                    if method is not none:
                        _ny_setattr_raw(enum_class, "__str__", method)
                classdict["__str__"] = enum_class.__str__
        # double check that repr and friends are not the (user) mixin's
        if first_enum is not none and member_type is not object and not _is_data_type(member_type):
            for name in ["__repr__", "__str__", "__format__"]:
                if name not in classdict:
                    data_type_method = getattr(member_type, name, none)
                    found_method = getattr(enum_class, name, none)
                    if data_type_method is not none and found_method == data_type_method:
                        _ny_setattr_raw(enum_class, name, getattr(first_enum, name))
        #
        # for Flag, add __or__, __and__, __xor__, and __invert__
        if Flag is not none and is_flag:
            for name in ["__or__", "__and__", "__xor__", "__ror__", "__rand__", "__rxor__", "__invert__"]:
                if name not in classdict:
                    _ny_setattr_raw(enum_class, name, Flag.__dict__[name])
                    classdict[name] = true
        #
        # if the user defined their own __new__, save it before it gets
        # clobbered in case they subclass later
        if save_new:
            _ny_setattr_raw(enum_class, "__new_member__", nw)
        #
        # _order_ checking: a list, flags' multi-bit and alias names removed,
        # then compared with the members
        if _order_ is not none:
            if isinstance(_order_, str):
                _order_ = _order_.replace(",", " ").split()
        if Flag is not none and is_flag:
            # set correct __iter__
            member_list = [m._value_ for m in enum_class]
            if member_list != sorted(member_list):
                _ny_setattr_raw(enum_class, "_ny_iter_by_def_", true)
            if _order_:
                _order_ = [o for o in _order_ if o not in enum_class._member_map_ or _is_single_bit(enum_class[o]._value_)]
        if _order_:
            _order_ = [o for o in _order_ if o not in enum_class._member_map_ or o in enum_class._member_names_]
            if _order_ != enum_class._member_names_:
                raise TypeError("member order does not match _order_:\n  %r\n  %r" % (enum_class._member_names_, _order_))
        return enum_class

    def __bool__(cls):
        # classes/types should always be True.
        return true

    def __call__(cls, value, names=none, *, module=none, qualname=none, type=none, start=1, boundary=none):
        # Either returns an existing member (Color(3)), or creates a new enum
        # class (the functional API: Enum("Color", "RED GREEN BLUE")).
        if names is none:
            return _enum_lookup(cls, value)
        return _create_(cls, value, names, module, qualname, type, start, boundary)

    def __contains__(cls, member):
        # True if member is a member of this enum; TypeError (3.11) for
        # anything that is not an enum member
        if not isinstance(member, Enum):
            raise TypeError("unsupported operand type(s) for 'in': '%s' and '%s'" % (_tname(member), _tname(cls)))
        return isinstance(member, cls) and member._name_ in cls._member_map_

    def __delattr__(cls, attr):
        # nicer error message when someone tries to delete an attribute
        if attr in getattr(cls, "_member_map_", {}):
            raise AttributeError("%r cannot delete member %r." % (cls.__name__, attr))
        super().__delattr__(attr)

    def __dir__(cls):
        interesting = ["__class__", "__contains__", "__doc__", "__getitem__", "__iter__", "__len__",
                       "__members__", "__module__", "__name__", "__qualname__"] + cls._member_names_
        if cls._ny_new_member_ is not none:
            interesting.append("__new__")
        return sorted(set(interesting))

    def __getattr__(cls, name):
        # the enum member matching `name`
        if _is_dunder(name) or name == "_member_map_":
            raise AttributeError(name)
        mm = cls._member_map_
        if name in mm:
            return mm[name]
        raise AttributeError(name)

    def __getitem__(cls, name):
        # the member matching `name`
        return cls._member_map_[name]

    def __iter__(cls):
        # members in definition order
        return (cls._member_map_[name] for name in cls._member_names_)

    def __len__(cls):
        # the number of members (no aliases)
        return len(cls._member_names_)

    @_bltn_property
    def __members__(cls):
        # a read-only mapping of member name -> member, aliases included
        return _EnumMembers(cls._member_map_)

    def __repr__(cls):
        if Flag is not none and issubclass(cls, Flag):
            return "<flag %r>" % (cls.__name__,)
        return "<enum %r>" % (cls.__name__,)

    def __reversed__(cls):
        # members in reverse definition order
        return (cls._member_map_[name] for name in reversed(cls._member_names_))

    def __setattr__(cls, name, value):
        # Block attempts to reassign Enum members.
        if name in getattr(cls, "_member_map_", {}):
            raise AttributeError("cannot reassign member %r" % (name,))
        super().__setattr__(name, value)

EnumMeta = EnumType


def _tname(x):
    if x is none:
        return "NoneType"
    if isinstance(x, EnumType):
        return type(x).__name__
    t = type(x)
    if isinstance(t, str):
        return t
    return t.__name__


def _enum_lookup(cls, value):
    # Color(value): the member with that value, else _missing_'s answer
    if type(value) is cls:
        # For lookups like Color(Color.RED)
        return value
    v2m = cls._value2member_map_
    try:
        if value in v2m:
            return v2m[value]
    except TypeError:
        # not there, now do long search -- O(n) behavior
        for name in cls._member_map_:
            m = cls._member_map_[name]
            if m._value_ == value:
                return m
    # still not found -- verify that members exist
    if not cls._member_map_:
        raise TypeError("%r has no members defined" % (cls,))
    # still not found -- try _missing_ hook
    exc = none
    result = none
    try:
        result = cls._missing_(value)
    except Exception as e:
        exc = e
        result = none
    if isinstance(result, cls):
        return result
    elif Flag is not none and issubclass(cls, Flag) and cls._boundary_ is EJECT and isinstance(result, int):
        return result
    ve_exc = ValueError("%r is not a valid %s" % (value, cls.__qualname__))
    if result is none and exc is none:
        raise ve_exc
    elif exc is none:
        exc = TypeError("error in %s._missing_: returned %r instead of None or a valid member" % (cls.__name__, result))
    if not isinstance(exc, ValueError):
        exc.__context__ = ve_exc
    raise exc


def _create_(cls, class_name, names, module, qualname, type_, start, boundary):
    # The functional API. `names` can be a string of member names separated
    # by spaces or commas (values counted from `start`), an iterable of
    # member names, an iterable of (member name, value) pairs, or a mapping
    # of member name -> value.
    metacls = type(cls)
    bases = (cls,) if type_ is none else (type_, cls)
    mixins = _get_mixins_(class_name, bases)
    first_enum = mixins[1]
    classdict = {}
    if isinstance(names, str):
        names = names.replace(",", " ").split()
    if isinstance(names, (tuple, list)) and names and isinstance(names[0], str):
        original_names = names
        names = []
        last_values = []
        count = 0
        for name in original_names:
            value = first_enum._generate_next_value_(name, start, count, last_values[:])
            last_values.append(value)
            names.append((name, value))
            count += 1
    if names is none:
        names = ()
    # Here, names is either an iterable of (name, value) or a mapping.
    for item in names:
        if isinstance(item, str):
            classdict[item] = names[item]
        else:
            classdict[item[0]] = item[1]
    if module is not none:
        classdict["__module__"] = module
    if qualname is not none:
        classdict["__qualname__"] = qualname
    return metacls.__new__(metacls, class_name, bases, classdict, boundary=boundary)


class Enum(metaclass=EnumType):
    # Create a collection of name/value pairs.
    #
    #     class Color(Enum):
    #         RED = 1
    #         BLUE = 2
    #     Color.RED -> <Color.RED: 1>, Color(1), Color["RED"], len(Color)

    def __new__(cls, value):
        # members are made while the class is created; this is the lookup by
        # value (Color(3)), as in CPython where EnumType.__call__ reaches it
        return _enum_lookup(cls, value)

    def __init__(self, *args, **kwds):
        pass

    @staticmethod
    def _generate_next_value_(name, start, count, last_values):
        # the next value when not given: the last one + 1
        if not last_values:
            return start
        try:
            last = last_values[-1]
            last_values.sort()
            if last == last_values[-1]:
                return last + 1
            raise TypeError("unsortable")
        except TypeError:
            for v in reversed(last_values):
                try:
                    return v + 1
                except TypeError:
                    pass
            return start

    @classmethod
    def _missing_(cls, value):
        return none

    def __repr__(self):
        v_repr = type(self)._value_repr_
        if v_repr is none:
            v_repr = repr
        return "<%s.%s: %s>" % (type(self).__name__, self._name_, v_repr(self._value_))

    def __str__(self):
        return "%s.%s" % (type(self).__name__, self._name_)

    def __dir__(self):
        interesting = ["__class__", "__doc__", "__eq__", "__hash__", "__module__", "name", "value"]
        return sorted(set(interesting))

    def __format__(self, format_spec):
        return format(str(self), format_spec)

    def __hash__(self):
        return hash(self._name_)

    def __reduce_ex__(self, proto):
        return (type(self), (self._value_,))

    def __deepcopy__(self, memo):
        return self

    def __copy__(self):
        return self

    @property
    def name(self):
        # The name of the Enum member.
        return self._name_

    @property
    def value(self):
        # The value of the Enum member.
        return self._value_

# (a _sunder_ name cannot be in an enum body)
_ny_setattr_raw(Enum, "_ny_data_", false)


class ReprEnum(Enum):
    # Only changes the repr(), leaving str() and format() to the mixed-in type.
    pass


class IntEnum(int, ReprEnum):
    # Enum where members are also (and must be) ints
    pass


class StrEnum(str, ReprEnum):
    # Enum where members are also (and must be) strings

    def __new__(cls, *values):
        # values must already be of type `str`
        if len(values) > 3:
            raise TypeError("too many arguments for str(): %r" % (values,))
        if len(values) == 1:
            # it must be a string
            if not isinstance(values[0], str):
                raise TypeError("%r is not a string" % (values[0],))
        if len(values) >= 2:
            # check that encoding argument is a string
            if not isinstance(values[1], str):
                raise TypeError("encoding must be a string, not %r" % (values[1],))
        if len(values) == 3:
            # check that errors argument is a string
            if not isinstance(values[2], str):
                raise TypeError("errors must be a string, not %r" % (values[2],))
        if len(values) == 1:
            value = values[0]
        else:
            value = str(*values)
        obj = object.__new__(cls)
        obj._value_ = value
        return obj

    @staticmethod
    def _generate_next_value_(name, start, count, last_values):
        # the lower-cased version of the member name
        return name.lower()


class FlagBoundary(StrEnum):
    # control how out of range values are handled
    # "strict" -> error is raised             [default for Flag]
    # "conform" -> extra bits are discarded
    # "eject" -> lose flag status
    # "keep" -> keep flag status and all bits [default for IntFlag]
    STRICT = auto()
    CONFORM = auto()
    EJECT = auto()
    KEEP = auto()

STRICT = FlagBoundary.STRICT
CONFORM = FlagBoundary.CONFORM
EJECT = FlagBoundary.EJECT
KEEP = FlagBoundary.KEEP


class Flag(Enum, boundary=STRICT):
    # Support for flags

    _numeric_repr_ = repr

    @staticmethod
    def _generate_next_value_(name, start, count, last_values):
        # the next power of two above the highest value so far
        if not count:
            return start if start is not none else 1
        last_value = max(last_values)
        try:
            high_bit = _high_bit(last_value)
        except Exception:
            raise TypeError("invalid flag value %r" % (last_value,))
        return 2 ** (high_bit + 1)

    @classmethod
    def _iter_member_by_value_(cls, value):
        # the members in value, in increasing value order
        for val in _iter_bits_lsb(value & cls._flag_mask_):
            yield cls._value2member_map_.get(val)

    @classmethod
    def _iter_member_by_def_(cls, value):
        # the members in value, in definition order
        for m in sorted(list(cls._iter_member_by_value_(value)), key=lambda m: m._sort_order_):
            yield m

    @classmethod
    def _iter_member_(cls, value):
        if getattr(cls, "_ny_iter_by_def_", false):
            return cls._iter_member_by_def_(value)
        return cls._iter_member_by_value_(value)

    @classmethod
    def _missing_(cls, value):
        # a composite member containing all canonical members present in
        # `value`; non-member values depend on the _boundary_ setting
        if not isinstance(value, int):
            raise ValueError("%r is not a valid %s" % (value, cls.__qualname__))
        # check boundaries
        # - value must be in range (e.g. -16 <-> +15, i.e. ~15 <-> 15)
        # - value must not include any skipped flags (e.g. if bit 2 is not
        #   defined, then 0d10 is invalid)
        flag_mask = cls._flag_mask_
        singles_mask = cls._singles_mask_
        all_bits = cls._all_bits_
        neg_value = none
        if not (~all_bits <= value and value <= all_bits) or value & (all_bits ^ flag_mask):
            if cls._boundary_ is STRICT:
                max_bits = max(value.bit_length(), flag_mask.bit_length())
                raise ValueError("%r invalid value %r\n    given %s\n  allowed %s" % (
                                 cls, value, bin(value, max_bits), bin(flag_mask, max_bits)))
            elif cls._boundary_ is CONFORM:
                value = value & flag_mask
            elif cls._boundary_ is EJECT:
                return value
            elif cls._boundary_ is KEEP:
                if value < 0:
                    value = max(all_bits + 1, 2 ** value.bit_length()) + value
            else:
                raise ValueError("%r unknown flag boundary %r" % (cls, cls._boundary_))
        if value < 0:
            neg_value = value
            value = all_bits + 1 + value
        # get members and unknown
        unknown = value & ~flag_mask
        aliases = value & ~singles_mask
        member_value = value & singles_mask
        if unknown and cls._boundary_ is not KEEP:
            raise ValueError("%s(%r) -->  unknown values %r [%s]" % (cls.__name__, value, unknown, bin(unknown)))
        # construct a singleton enum pseudo-member
        pseudo_member = object.__new__(cls)
        pseudo_member._value_ = value
        if member_value or aliases:
            members = []
            combined_value = 0
            for m in cls._iter_member_(member_value):
                members.append(m)
                combined_value |= m._value_
            if aliases:
                value = member_value | aliases
                for n in cls._member_map_:
                    pm = cls._member_map_[n]
                    if pm not in members and pm._value_ and pm._value_ & value == pm._value_:
                        members.append(pm)
                        combined_value |= pm._value_
            unknown = value ^ combined_value
            pseudo_member._name_ = "|".join([m._name_ for m in members])
            if not combined_value:
                pseudo_member._name_ = none
            elif unknown and cls._boundary_ is STRICT:
                raise ValueError("%r: no members with value %r" % (cls, unknown))
            elif unknown:
                pseudo_member._name_ += "|%s" % (cls._numeric_repr_(unknown),)
        else:
            pseudo_member._name_ = none
        # use setdefault in case another thread already created a composite
        # with this value; note: zero is a special case -- always add it
        v2m = cls._value2member_map_
        if value in v2m:
            pseudo_member = v2m[value]
        else:
            v2m[value] = pseudo_member
        if neg_value is not none:
            v2m[neg_value] = pseudo_member
        return pseudo_member

    def __contains__(self, other):
        # True if self has at least the same flags set as other
        if not isinstance(other, type(self)):
            raise TypeError("unsupported operand type(s) for 'in': %r and %r" % (_tname(other), type(self).__qualname__))
        return other._value_ & self._value_ == other._value_

    def __iter__(self):
        # the flags in self, in definition order
        for m in self._iter_member_(self._value_):
            yield m

    def __len__(self):
        return self._value_.bit_count()

    def __repr__(self):
        cls_name = type(self).__name__
        v_repr = type(self)._value_repr_
        if v_repr is none:
            v_repr = repr
        if self._name_ is none:
            return "<%s: %s>" % (cls_name, v_repr(self._value_))
        return "<%s.%s: %s>" % (cls_name, self._name_, v_repr(self._value_))

    def __str__(self):
        cls_name = type(self).__name__
        if self._name_ is none:
            return "%s(%r)" % (cls_name, self._value_)
        return "%s.%s" % (cls_name, self._name_)

    def __bool__(self):
        return bool(self._value_)

    def _get_value(self, flag):
        if isinstance(flag, type(self)):
            return flag._value_
        elif self._member_type_ is not object and isinstance(flag, self._member_type_):
            return flag
        return NotImplemented

    def __or__(self, other):
        other_value = self._get_value(other)
        if other_value is NotImplemented:
            return NotImplemented
        for flag in [self, other]:
            if self._get_value(flag) is none:
                raise TypeError("'" + str(flag) + "' cannot be combined with other flags with |")
        return type(self)(self._value_ | other_value)

    def __and__(self, other):
        other_value = self._get_value(other)
        if other_value is NotImplemented:
            return NotImplemented
        for flag in [self, other]:
            if self._get_value(flag) is none:
                raise TypeError("'" + str(flag) + "' cannot be combined with other flags with &")
        return type(self)(self._value_ & other_value)

    def __xor__(self, other):
        other_value = self._get_value(other)
        if other_value is NotImplemented:
            return NotImplemented
        for flag in [self, other]:
            if self._get_value(flag) is none:
                raise TypeError("'" + str(flag) + "' cannot be combined with other flags with ^")
        return type(self)(self._value_ ^ other_value)

    def __invert__(self):
        if self._get_value(self) is none:
            raise TypeError("'" + str(self) + "' cannot be inverted")
        if self._inverted_ is none:
            if self._boundary_ is EJECT or self._boundary_ is KEEP:
                self._inverted_ = type(self)(~self._value_)
            else:
                self._inverted_ = type(self)(self._singles_mask_ & ~self._value_)
        return self._inverted_

    def __rand__(self, other):
        return self.__and__(other)

    def __ror__(self, other):
        return self.__or__(other)

    def __rxor__(self, other):
        return self.__xor__(other)


class IntFlag(int, ReprEnum, Flag, boundary=KEEP):
    # Support for integer-based Flags
    pass


def unique(enumeration):
    # Class decorator for enumerations ensuring unique member values.
    duplicates = []
    mm = enumeration.__members__
    for name in mm:
        m = mm[name]
        if name != m.name:
            duplicates.append((name, m.name))
    if duplicates:
        alias_details = ", ".join(["%s -> %s" % (d[0], d[1]) for d in duplicates])
        raise ValueError("duplicate values found in %r: %s" % (enumeration, alias_details))
    return enumeration


def global_enum_repr(self):
    # module.member instead of class.member (the last module of a dotted name)
    module = type(self).__module__.split(".")[-1]
    return "%s.%s" % (module, self._name_)

def global_flag_repr(self):
    module = type(self).__module__.split(".")[-1]
    cls_name = type(self).__name__
    if self._name_ is none:
        return "%s.%s(%r)" % (module, cls_name, self._value_)
    if _is_single_bit(self._value_):
        return "%s.%s" % (module, self._name_)
    if self._boundary_ is not FlagBoundary.KEEP:
        return "|".join(["%s.%s" % (module, name) for name in self.name.split("|")])
    name = []
    for n in self._name_.split("|"):
        if n[0].isdigit():
            name.append(n)
        else:
            name.append("%s.%s" % (module, n))
    return "|".join(name)

def global_str(self):
    # the member's name instead of class.name
    if self._name_ is none:
        return "%s(%r)" % (type(self).__name__, self._value_)
    return self._name_

def global_enum(cls, update_str=false):
    # members' repr references the module instead of the class (Nython: the
    # members are not exported into the module's namespace - no sys.modules)
    if issubclass(cls, Flag):
        _ny_setattr_raw(cls, "__repr__", global_flag_repr)
    else:
        _ny_setattr_raw(cls, "__repr__", global_enum_repr)
    if not issubclass(cls, ReprEnum) or update_str:
        _ny_setattr_raw(cls, "__str__", global_str)
    return cls


class EnumCheck(StrEnum):
    # various conditions to check an enumeration for
    CONTINUOUS = "no skipped integer values"
    NAMED_FLAGS = "multi-flag aliases may not contain unnamed flags"
    UNIQUE = "one name per value"

CONTINUOUS = EnumCheck.CONTINUOUS
NAMED_FLAGS = EnumCheck.NAMED_FLAGS
UNIQUE = EnumCheck.UNIQUE


class verify:
    # Check an enumeration for various constraints (see EnumCheck).
    def __init__(self, *checks):
        self.checks = checks

    def __call__(self, enumeration):
        checks = self.checks
        cls_name = enumeration.__name__
        if Flag is not none and issubclass(enumeration, Flag):
            enum_type = "flag"
        elif issubclass(enumeration, Enum):
            enum_type = "enum"
        else:
            raise TypeError("the 'verify' decorator only works with Enum and Flag")
        for check in checks:
            if check is UNIQUE:
                # check for duplicate names
                duplicates = []
                mm = enumeration.__members__
                for name in mm:
                    if name != mm[name].name:
                        duplicates.append((name, mm[name].name))
                if duplicates:
                    alias_details = ", ".join(["%s -> %s" % (d[0], d[1]) for d in duplicates])
                    raise ValueError("aliases found in %r: %s" % (enumeration, alias_details))
            elif check is CONTINUOUS:
                values = set([e.value for e in enumeration])
                if len(values) < 2:
                    continue
                low = min(values)
                high = max(values)
                missing = []
                if enum_type == "flag":
                    # check for powers of two
                    for i in range(_high_bit(low) + 1, _high_bit(high)):
                        if 2 ** i not in values:
                            missing.append(2 ** i)
                else:
                    # check for powers of one
                    for i in range(low + 1, high):
                        if i not in values:
                            missing.append(i)
                if missing:
                    raise ValueError(("invalid %s %r: missing values %s" % (
                                     enum_type, cls_name, ", ".join([str(m) for m in missing])))[:256])
            elif check is NAMED_FLAGS:
                # examine each alias and check for unnamed flags
                member_names = enumeration._member_names_
                member_values = [m.value for m in enumeration]
                missing_names = []
                missing_value = 0
                for name in enumeration._member_map_:
                    alias = enumeration._member_map_[name]
                    if name in member_names:
                        # not an alias
                        continue
                    if alias.value < 0:
                        # negative numbers are not checked
                        continue
                    values = list(_iter_bits_lsb(alias.value))
                    missed = [v for v in values if v not in member_values]
                    if missed:
                        missing_names.append(name)
                        for v in missed:
                            missing_value |= v
                if missing_names:
                    if len(missing_names) == 1:
                        alias = "alias %s is missing" % (missing_names[0],)
                    else:
                        alias = "aliases %s and %s are missing" % (", ".join(missing_names[:-1]), missing_names[-1])
                    if _is_single_bit(missing_value):
                        value = "value 0x%x" % (missing_value,)
                    else:
                        value = "combined values of 0x%x" % (missing_value,)
                    raise ValueError("invalid Flag %r: %s %s [use enum.show_flag_values(value) for details]" % (
                                     cls_name, alias, value))
        return enumeration
