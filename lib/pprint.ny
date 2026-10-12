# nython: module    (import it by name: it runs in a module scope of its own)
# lib/pprint.ny - Python's pprint (3.12): pretty-printed reprs.
#
#     import pprint
#     pprint.pprint(data)                       # to sys.stdout
#     s = pprint.pformat(data, indent=2, width=60, depth=3, compact=True)
#     pprint.pp(data)                           # sort_dicts=False
#     pprint.saferepr(x); pprint.isreadable(x); pprint.isrecursive(x)
#
# PrettyPrinter(indent, width, depth, stream, compact, sort_dicts,
# underscore_numbers) lays objects out with CPython's algorithm: an object
# whose repr fits in the remaining width is written as it is; a dict, list,
# tuple, set or frozenset that does not is written one item per line (or
# packed, with compact=True) and its items formatted the same way; a long
# string is split at whitespace into adjacent literals (in parentheses at
# the top level), a long bytes object every four bytes; bytearray,
# collections' OrderedDict, defaultdict, Counter, ChainMap, deque, UserDict
# and UserList have their own layouts. Dict keys are sorted (sort_dicts),
# mixed types by type name as Python does. A container that contains
# itself is written <Recursion on list with id=...>; depth= turns deeper
# levels into [...], {...} and (...).
#
# Scalars are written with repr(), so Nython's own spellings show through
# (true, none). Not here: dataclasses, SimpleNamespace and mappingproxy
# layouts (those types are not part of Nython yet) - such objects are
# written with their repr.
import sys

__all__ = ["pprint", "pformat", "isreadable", "isrecursive", "saferepr",
           "PrettyPrinter", "pp"]


def _tn(x):
    # the type's name as Python spells it
    var n = type(x).__name__
    if n == "string":
        return "str"
    if n == "map":
        return "dict"
    if n == "none":
        return "NoneType"
    return n


class _PPOut:
    # what pformat writes to (Python uses io.StringIO)
    def __init__(self):
        self.parts = []

    def write(self, s):
        self.parts.append(s)

    def getvalue(self):
        return "".join(self.parts)


def pprint(object, stream=None, indent=1, width=80, depth=None, *, compact=False,
           sort_dicts=True, underscore_numbers=False):
    var printer = PrettyPrinter(stream=stream, indent=indent, width=width, depth=depth,
                                compact=compact, sort_dicts=sort_dicts,
                                underscore_numbers=underscore_numbers)
    printer.pprint(object)


def pformat(object, indent=1, width=80, depth=None, *, compact=False, sort_dicts=True,
            underscore_numbers=False):
    return PrettyPrinter(indent=indent, width=width, depth=depth, compact=compact,
                         sort_dicts=sort_dicts, underscore_numbers=underscore_numbers).pformat(object)


def pp(object, *args, sort_dicts=False, **kwargs):
    pprint(object, *args, sort_dicts=sort_dicts, **kwargs)


def saferepr(object):
    return PrettyPrinter()._safe_repr(object, {}, None, 0)[0]


def isreadable(object):
    return PrettyPrinter()._safe_repr(object, {}, None, 0)[1]


def isrecursive(object):
    return PrettyPrinter()._safe_repr(object, {}, None, 0)[2]


def _type_str(x):
    # str(type(x)) as Python writes it, for ordering unorderable keys
    return "<class '" + _tn(x) + "'>"


def _is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, complex)


def _comparable(a, b):
    # would Python's a < b work (rather than raise TypeError)?
    if _is_num(a) and _is_num(b):
        return true
    if isinstance(a, str) and isinstance(b, str):
        return true
    if isinstance(a, (bytes, bytearray)) and isinstance(b, (bytes, bytearray)):
        return true
    if isinstance(a, tuple) and isinstance(b, tuple):
        return true
    if isinstance(a, list) and isinstance(b, list):
        return true
    if isinstance(a, (set, frozenset)) and isinstance(b, (set, frozenset)):
        return true
    var ta = _tn(a)
    if ta not in _BUILTIN_TYPE_NAMES and hasattr(a, "__lt__"):
        return true
    var tb = _tn(b)
    return tb not in _BUILTIN_TYPE_NAMES and hasattr(b, "__gt__")


_BUILTIN_TYPE_NAMES = set(["int", "float", "bool", "str", "bytes", "bytearray", "tuple", "list",
                           "dict", "set", "frozenset", "NoneType", "complex", "function",
                           "builtin_function_or_method", "type", "generator", "range", "slice"])


class _safe_key:
    # orders anything: by < where Python's < works, else by (type, id) as
    # pprint's Python 2 style fallback does
    def __init__(self, obj):
        self.obj = obj

    def __lt__(self, other):
        var a = self.obj
        var b = other.obj
        if _comparable(a, b):
            try:
                return a < b
            except TypeError:
                pass
        return (_type_str(a), id(a)) < (_type_str(b), id(b))


def _safe_tuple(t):
    return (_safe_key(t[0]), _safe_key(t[1]))


def _sorted_items(d):
    var items = list(d.items())
    # keys that are all strings, or all numbers, sort by themselves (dict
    # keys are distinct, so the values never decide); the general case
    # wraps both sides in _safe_key
    var all_str = true
    var all_num = true
    for kv in items:
        var k = kv[0]
        if not isinstance(k, str):
            all_str = false
        if not _is_num(k) or k != k:
            all_num = false
        if not all_str and not all_num:
            break
    if all_str or all_num:
        return sorted(items, key=lambda kv: kv[0])
    return sorted(items, key=_safe_tuple)


def _recursion(object):
    return "<Recursion on %s with id=%s>" % (_tn(object), id(object))


def _wrap_bytes_repr(object, width, allowance):
    var out = []
    var current = b""
    var last = len(object) // 4 * 4
    for i in range(0, len(object), 4):
        var part = object[i:i + 4]
        var candidate = current + part
        if i == last:
            width = width - allowance
        if len(repr(candidate)) > width:
            if current:
                out.append(repr(current))
            current = part
        else:
            current = candidate
    if current:
        out.append(repr(current))
    return out


def _str_parts(line):
    # re.findall(r'\S*\s*', line) without the empty match at the end
    var parts = []
    var n = len(line)
    var i = 0
    while i < n:
        var j = i
        while j < n and not line[j].isspace():
            j = j + 1
        while j < n and line[j].isspace():
            j = j + 1
        parts.append(line[i:j])
        i = j
    return parts


_COLLECTION_NAMES = set(["OrderedDict", "defaultdict", "Counter", "ChainMap", "deque",
                         "UserDict", "UserList", "UserString"])


class PrettyPrinter:
    def __init__(self, indent=1, width=80, depth=None, stream=None, *, compact=False,
                 sort_dicts=True, underscore_numbers=False):
        indent = int(indent)
        width = int(width)
        if indent < 0:
            raise ValueError("indent must be >= 0")
        if depth is not None and depth <= 0:
            raise ValueError("depth must be > 0")
        if not width:
            raise ValueError("width must be != 0")
        self._depth = depth
        self._indent_per_level = indent
        self._width = width
        if stream is not None:
            self._stream = stream
        else:
            self._stream = sys.stdout
        self._compact = bool(compact)
        self._sort_dicts = sort_dicts
        self._underscore_numbers = underscore_numbers
        self._readable = true
        self._recursive = false

    def pprint(self, object):
        if self._stream is not None:
            var out = _PPOut()
            self._format(object, out, 0, 0, {}, 0)
            self._stream.write(out.getvalue() + "\n")

    def pformat(self, object):
        var out = _PPOut()
        self._format(object, out, 0, 0, {}, 0)
        return out.getvalue()

    def isrecursive(self, object):
        return self.format(object, {}, 0, 0)[2]

    def isreadable(self, object):
        var r = self.format(object, {}, 0, 0)
        return r[1] and not r[2]

    def _format(self, object, stream, indent, allowance, context, level):
        var objid = id(object)
        if objid in context:
            stream.write(_recursion(object))
            self._recursive = true
            self._readable = false
            return
        var rep = self._repr(object, context, level)
        var max_width = self._width - indent - allowance
        if len(rep) > max_width:
            var p = self._printer_for(object)
            if p is not None:
                context[objid] = 1
                p(object, stream, indent, allowance, context, level + 1)
                del context[objid]
                return
        stream.write(rep)

    def _printer_for(self, object):
        # Python's _dispatch[type(object).__repr__]: the exact builtin types
        # and collections' classes
        var t = _tn(object)
        if t == "dict":
            return self._pprint_dict
        if t == "list":
            return self._pprint_list
        if t == "tuple":
            return self._pprint_tuple
        if t == "set" or t == "frozenset":
            return self._pprint_set
        if t == "str":
            return self._pprint_str
        if t == "bytes":
            return self._pprint_bytes
        if t == "bytearray":
            return self._pprint_bytearray
        if t in _COLLECTION_NAMES:
            import collections
            if t == "OrderedDict" and isinstance(object, collections.OrderedDict):
                return self._pprint_ordered_dict
            if t == "defaultdict" and isinstance(object, collections.defaultdict):
                return self._pprint_default_dict
            if t == "Counter" and isinstance(object, collections.Counter):
                return self._pprint_counter
            if t == "ChainMap" and isinstance(object, collections.ChainMap):
                return self._pprint_chain_map
            if t == "deque" and isinstance(object, collections.deque):
                return self._pprint_deque
            if t == "UserDict" or t == "UserList" or t == "UserString":
                return self._pprint_user_data
        return None

    def _pprint_dict(self, object, stream, indent, allowance, context, level):
        stream.write("{")
        if self._indent_per_level > 1:
            stream.write((self._indent_per_level - 1) * " ")
        if len(object):
            var items = _sorted_items(object) if self._sort_dicts else list(object.items())
            self._format_dict_items(items, stream, indent, allowance + 1, context, level)
        stream.write("}")

    def _pprint_ordered_dict(self, object, stream, indent, allowance, context, level):
        if not len(object):
            stream.write(repr(object))
            return
        var name = _tn(object)
        stream.write(name + "(")
        self._format(list(object.items()), stream, indent + len(name) + 1, allowance + 1, context, level)
        stream.write(")")

    def _pprint_list(self, object, stream, indent, allowance, context, level):
        stream.write("[")
        self._format_items(object, stream, indent, allowance + 1, context, level)
        stream.write("]")

    def _pprint_tuple(self, object, stream, indent, allowance, context, level):
        stream.write("(")
        var endchar = ",)" if len(object) == 1 else ")"
        self._format_items(object, stream, indent, allowance + len(endchar), context, level)
        stream.write(endchar)

    def _pprint_set(self, object, stream, indent, allowance, context, level):
        if not len(object):
            stream.write(repr(object))
            return
        var endchar = "}"
        if _tn(object) == "set":
            stream.write("{")
        else:
            stream.write(_tn(object) + "({")
            endchar = "})"
            indent = indent + len(_tn(object)) + 1
        var items = sorted(object, key=_safe_key)
        self._format_items(items, stream, indent, allowance + len(endchar), context, level)
        stream.write(endchar)

    def _pprint_str(self, object, stream, indent, allowance, context, level):
        if not len(object):
            stream.write(repr(object))
            return
        var chunks = []
        var lines = object.splitlines(True)
        if level == 1:
            indent = indent + 1
            allowance = allowance + 1
        var max_width = self._width - indent
        var max_width1 = max_width
        var rep = ""
        for i in range(len(lines)):
            var line = lines[i]
            rep = repr(line)
            if i == len(lines) - 1:
                max_width1 = max_width1 - allowance
            if len(rep) <= max_width1:
                chunks.append(rep)
            else:
                var parts = _str_parts(line)
                var max_width2 = max_width
                var current = ""
                for j in range(len(parts)):
                    var part = parts[j]
                    var candidate = current + part
                    if j == len(parts) - 1 and i == len(lines) - 1:
                        max_width2 = max_width2 - allowance
                    if len(repr(candidate)) > max_width2:
                        if current:
                            chunks.append(repr(current))
                        current = part
                    else:
                        current = candidate
                if current:
                    chunks.append(repr(current))
        if len(chunks) == 1:
            stream.write(rep)
            return
        if level == 1:
            stream.write("(")
        for i in range(len(chunks)):
            if i > 0:
                stream.write("\n" + " " * indent)
            stream.write(chunks[i])
        if level == 1:
            stream.write(")")

    def _pprint_bytes(self, object, stream, indent, allowance, context, level):
        if len(object) <= 4:
            stream.write(repr(object))
            return
        var parens = level == 1
        if parens:
            indent = indent + 1
            allowance = allowance + 1
            stream.write("(")
        var delim = ""
        for rep in _wrap_bytes_repr(object, self._width - indent, allowance):
            stream.write(delim)
            stream.write(rep)
            if not delim:
                delim = "\n" + " " * indent
        if parens:
            stream.write(")")

    def _pprint_bytearray(self, object, stream, indent, allowance, context, level):
        stream.write("bytearray(")
        self._pprint_bytes(bytes(object), stream, indent + 10, allowance + 1, context, level + 1)
        stream.write(")")

    def _format_dict_items(self, items, stream, indent, allowance, context, level):
        indent = indent + self._indent_per_level
        var delimnl = ",\n" + " " * indent
        var last_index = len(items) - 1
        for i in range(len(items)):
            var key = items[i][0]
            var ent = items[i][1]
            var last = i == last_index
            var rep = self._repr(key, context, level)
            stream.write(rep)
            stream.write(": ")
            self._format(ent, stream, indent + len(rep) + 2, allowance if last else 1, context, level)
            if not last:
                stream.write(delimnl)

    def _format_items(self, items, stream, indent, allowance, context, level):
        indent = indent + self._indent_per_level
        if self._indent_per_level > 1:
            stream.write((self._indent_per_level - 1) * " ")
        var delimnl = ",\n" + " " * indent
        var delim = ""
        var max_width = self._width - indent + 1
        var width = max_width
        var seq = list(items)
        var n = len(seq)
        for k in range(n):
            var ent = seq[k]
            var last = k == n - 1
            if last:
                max_width = max_width - allowance
                width = width - allowance
            if self._compact:
                var rep = self._repr(ent, context, level)
                var w = len(rep) + 2
                if width < w:
                    width = max_width
                    if delim:
                        delim = delimnl
                if width >= w:
                    width = width - w
                    stream.write(delim)
                    delim = ", "
                    stream.write(rep)
                    continue
            stream.write(delim)
            delim = delimnl
            self._format(ent, stream, indent, allowance if last else 1, context, level)

    def _repr(self, object, context, level):
        var r = self.format(object, context.copy(), self._depth, level)
        if not r[1]:
            self._readable = false
        if r[2]:
            self._recursive = true
        return r[0]

    def format(self, object, context, maxlevels, level):
        return self._safe_repr(object, context, maxlevels, level)

    def _pprint_default_dict(self, object, stream, indent, allowance, context, level):
        if not len(object):
            stream.write(repr(object))
            return
        var rdf = self._repr(object.default_factory, context, level)
        # a builtin type written as Python's repr writes a class (as
        # collections.defaultdict's own repr does)
        var fname = getattr(object.default_factory, "__name__", None)
        if fname in ["list", "dict", "set", "int", "float", "str", "tuple"]:
            rdf = "<class '" + fname + "'>"
        var name = _tn(object)
        indent = indent + len(name) + 1
        stream.write(name + "(" + rdf + ",\n" + " " * indent)
        self._pprint_dict(object, stream, indent, allowance + 1, context, level)
        stream.write(")")

    def _pprint_counter(self, object, stream, indent, allowance, context, level):
        if not len(object):
            stream.write(repr(object))
            return
        var name = _tn(object)
        stream.write(name + "({")
        if self._indent_per_level > 1:
            stream.write((self._indent_per_level - 1) * " ")
        var items = object.most_common()
        self._format_dict_items(items, stream, indent + len(name) + 1, allowance + 2, context, level)
        stream.write("})")

    def _pprint_chain_map(self, object, stream, indent, allowance, context, level):
        if not len(object.maps):
            stream.write(repr(object))
            return
        var name = _tn(object)
        stream.write(name + "(")
        indent = indent + len(name) + 1
        var maps = object.maps
        for i in range(len(maps)):
            if i == len(maps) - 1:
                self._format(maps[i], stream, indent, allowance + 1, context, level)
                stream.write(")")
            else:
                self._format(maps[i], stream, indent, 1, context, level)
                stream.write(",\n" + " " * indent)

    def _pprint_deque(self, object, stream, indent, allowance, context, level):
        if not len(object):
            stream.write(repr(object))
            return
        var name = _tn(object)
        stream.write(name + "(")
        indent = indent + len(name) + 1
        stream.write("[")
        if object.maxlen is None:
            self._format_items(list(object), stream, indent, allowance + 2, context, level)
            stream.write("])")
        else:
            self._format_items(list(object), stream, indent, 2, context, level)
            var rml = self._repr(object.maxlen, context, level)
            stream.write("],\n" + " " * indent + "maxlen=" + rml + ")")

    def _pprint_user_data(self, object, stream, indent, allowance, context, level):
        self._format(object.data, stream, indent, allowance, context, level - 1)

    def _safe_repr(self, object, context, maxlevels, level):
        var t = _tn(object)
        if t == "int":
            if self._underscore_numbers:
                return (format(object, "_d"), true, false)
            return (repr(object), true, false)
        if t == "dict":
            if not object:
                return ("{}", true, false)
            var objid = id(object)
            if maxlevels and level >= maxlevels:
                return ("{...}", false, objid in context)
            if objid in context:
                return (_recursion(object), false, true)
            context[objid] = 1
            var readable = true
            var recursive = false
            var components = []
            level = level + 1
            var items = _sorted_items(object) if self._sort_dicts else list(object.items())
            for kv in items:
                var kr = self.format(kv[0], context, maxlevels, level)
                var vr = self.format(kv[1], context, maxlevels, level)
                components.append(kr[0] + ": " + vr[0])
                readable = readable and kr[1] and vr[1]
                if kr[2] or vr[2]:
                    recursive = true
            del context[objid]
            return ("{" + ", ".join(components) + "}", readable, recursive)
        if t == "list" or t == "tuple":
            var fmt_open = "["
            var fmt_close = "]"
            if t == "list":
                if not object:
                    return ("[]", true, false)
            elif len(object) == 1:
                fmt_open = "("
                fmt_close = ",)"
            else:
                if not object:
                    return ("()", true, false)
                fmt_open = "("
                fmt_close = ")"
            var oid = id(object)
            if maxlevels and level >= maxlevels:
                return (fmt_open + "..." + fmt_close, false, oid in context)
            if oid in context:
                return (_recursion(object), false, true)
            context[oid] = 1
            var readable2 = true
            var recursive2 = false
            var comps = []
            level = level + 1
            for o in object:
                var orr = self.format(o, context, maxlevels, level)
                comps.append(orr[0])
                if not orr[1]:
                    readable2 = false
                if orr[2]:
                    recursive2 = true
            del context[oid]
            return (fmt_open + ", ".join(comps) + fmt_close, readable2, recursive2)
        var rep = repr(object)
        if t in ("str", "bytes", "bytearray", "float", "complex", "bool", "NoneType"):
            return (rep, true, false)
        return (rep, bool(rep) and not rep.startswith("<"), false)
