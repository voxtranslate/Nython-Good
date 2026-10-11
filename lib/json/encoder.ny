# nython: module
# lib/json/encoder.ny - json.encoder: JSONEncoder, encode_basestring(_ascii)
# (CPython 3.12's Lib/json/encoder.py). encode() writes the document with the
# native encoder (builtins/pyjson.cpp) when every value is a dict, list,
# tuple, str, int, float, bool or None; anything else - default=, a set, an
# object - goes through _NyJsonIterEncode, the port of _make_iterencode,
# which iterencode() always uses (so its chunks are Python's).

__all__ = ["JSONEncoder", "encode_basestring", "encode_basestring_ascii"]

INFINITY = float("inf")


def encode_basestring(s):
    """Return a JSON representation of a Python string"""
    return _json_quote(s, false)


def encode_basestring_ascii(s):
    """Return an ASCII-only JSON representation of a Python string"""
    return _json_quote(s, true)


py_encode_basestring = encode_basestring
py_encode_basestring_ascii = encode_basestring_ascii


def _type_name(o):
    return type(o).__name__


# collections' dict and tuple types are classes here; Python's are dict and
# tuple subclasses, which json writes as objects and arrays
def _as_dict(o):
    var n = _type_name(o)
    if (n == "OrderedDict" or n == "defaultdict" or n == "Counter") and hasattr(o, "data") and isinstance(o.data, dict):
        return o.data
    return none


def _as_tuple(o):
    if hasattr(o, "_fields") and hasattr(o, "_values") and isinstance(o._values, tuple):
        return o._values
    return none


def _key_kind(k):
    if isinstance(k, str):
        return "str"
    if isinstance(k, bool) or isinstance(k, int) or isinstance(k, float):
        return "number"
    return type(k).__name__


def _check_sortable(keys):
    # sorted(dct.items()) raises in Python when two keys cannot be ordered
    # (Nython orders an int before a str instead of raising)
    if len(keys) < 2:
        return none
    var k0 = _key_kind(keys[0])
    for i in range(1, len(keys)):
        var ki = _key_kind(keys[i])
        if ki != k0 or (ki != "str" and ki != "number"):
            raise TypeError("'<' not supported between instances of '" + type(keys[i]).__name__ +
                            "' and '" + type(keys[0]).__name__ + "'")
    return none


class _NyJsonIterEncode:
    # Lib/json/encoder.py's _make_iterencode as methods; every method is a
    # generator of the same chunks Python's closures yield.
    def __init__(self, markers, default, encoder, indent, allow_nan,
                 key_separator, item_separator, sort_keys, skipkeys):
        self.markers = markers
        self.default = default
        self.encoder = encoder
        if indent is not none and not isinstance(indent, str):
            indent = " " * indent
        self.indent = indent
        self.allow_nan = allow_nan
        self.key_separator = key_separator
        self.item_separator = item_separator
        self.sort_keys = sort_keys
        self.skipkeys = skipkeys

    def floatstr(self, o):
        var text = ""
        if o != o:
            text = "NaN"
        elif o == INFINITY:
            text = "Infinity"
        elif o == -INFINITY:
            text = "-Infinity"
        else:
            return repr(o)
        if not self.allow_nan:
            raise ValueError("Out of range float values are not JSON compliant: " + repr(o))
        return text

    def scalar(self, value):
        # the text of a str/None/bool/int/float, or none for anything else
        if isinstance(value, str):
            return self.encoder(value)
        if value is none:
            return "null"
        if isinstance(value, bool):
            return "true" if value else "false"
        if isinstance(value, int):
            return repr(int(value))
        if isinstance(value, float):
            return self.floatstr(value)
        return none

    def enter(self, o):
        if self.markers is not none:
            var markerid = id(o)
            if markerid in self.markers:
                raise ValueError("Circular reference detected")
            self.markers[markerid] = o

    def leave(self, o):
        if self.markers is not none:
            del self.markers[id(o)]

    def nested(self, value, level):
        if isinstance(value, list) or isinstance(value, tuple):
            return self.iter_list(value, level)
        if isinstance(value, dict):
            return self.iter_dict(value, level)
        return self.iterencode(value, level)

    def iter_list(self, lst, level):
        if not lst:
            yield "[]"
            return
        self.enter(lst)
        var buf = "["
        var newline_indent = none
        var separator = self.item_separator
        if self.indent is not none:
            level = level + 1
            newline_indent = "\n" + self.indent * level
            separator = self.item_separator + newline_indent
            buf = buf + newline_indent
        var first = true
        for value in lst:
            if first:
                first = false
            else:
                buf = separator
            var text = self.scalar(value)
            if text is not none:
                yield buf + text
            else:
                yield buf
                yield from self.nested(value, level)
        if newline_indent is not none:
            level = level - 1
            yield "\n" + self.indent * level
        yield "]"
        self.leave(lst)

    def iter_dict(self, dct, level):
        if not dct:
            yield "{}"
            return
        self.enter(dct)
        yield "{"
        var newline_indent = none
        var item_separator = self.item_separator
        if self.indent is not none:
            level = level + 1
            newline_indent = "\n" + self.indent * level
            item_separator = self.item_separator + newline_indent
            yield newline_indent
        var first = true
        if self.sort_keys:
            _check_sortable(list(dct.keys()))
        var items = sorted(dct.items()) if self.sort_keys else dct.items()
        for kv in items:
            var key = kv[0]
            var value = kv[1]
            if isinstance(key, str):
                pass
            elif isinstance(key, float):
                key = self.floatstr(key)
            elif isinstance(key, bool):
                key = "true" if key else "false"
            elif key is none:
                key = "null"
            elif isinstance(key, int):
                key = repr(int(key))
            elif self.skipkeys:
                continue
            else:
                raise TypeError("keys must be str, int, float, bool or None, not " + _type_name(key))
            if first:
                first = false
            else:
                yield item_separator
            yield self.encoder(key)
            yield self.key_separator
            var text = self.scalar(value)
            if text is not none:
                yield text
            else:
                yield from self.nested(value, level)
        if newline_indent is not none:
            level = level - 1
            yield "\n" + self.indent * level
        yield "}"
        self.leave(dct)

    def iterencode(self, o, level):
        var text = self.scalar(o)
        if text is not none:
            yield text
            return
        if isinstance(o, list) or isinstance(o, tuple):
            yield from self.iter_list(o, level)
            return
        if isinstance(o, dict):
            yield from self.iter_dict(o, level)
            return
        var d = _as_dict(o)
        if d is not none:
            yield from self.iter_dict(d, level)
            return
        var t = _as_tuple(o)
        if t is not none:
            yield from self.iter_list(t, level)
            return
        self.enter(o)
        var v = self.default(o)
        yield from self.iterencode(v, level)
        self.leave(o)


class JSONEncoder:
    """Extensible JSON <https://json.org> encoder for Python data structures.

    Supports dict, list, tuple, str, int, float, True, False and None. To
    extend it for other objects, subclass it and implement default() to
    return a serializable object for o (or call the base implementation to
    raise a TypeError).
    """
    item_separator = ", "
    key_separator = ": "

    def __init__(self, *, skipkeys=false, ensure_ascii=true,
                 check_circular=true, allow_nan=true, sort_keys=false,
                 indent=none, separators=none, default=none):
        self.skipkeys = skipkeys
        self.ensure_ascii = ensure_ascii
        self.check_circular = check_circular
        self.allow_nan = allow_nan
        self.sort_keys = sort_keys
        self.indent = indent
        if separators is not none:
            self.item_separator = separators[0]
            self.key_separator = separators[1]
        elif indent is not none:
            self.item_separator = ","
        if default is not none:
            self.default = default

    def default(self, o):
        """Implement this method in a subclass such that it returns
        a serializable object for ``o``, or calls the base implementation
        (to raise a ``TypeError``)."""
        raise TypeError("Object of type " + _type_name(o) + " is not JSON serializable")

    def encode(self, o):
        """Return a JSON string representation of a Python data structure.

        >>> JSONEncoder().encode({"foo": ["bar", "baz"]})
        '{"foo": ["bar", "baz"]}'
        """
        if isinstance(o, str):
            return _json_quote(o, self.ensure_ascii)
        if self.__class__.iterencode == JSONEncoder.iterencode:
            var indent = self.indent
            if indent is not none and not isinstance(indent, str):
                indent = " " * indent
            var text = _json_encode(o, indent, self.item_separator, self.key_separator,
                                    self.sort_keys, self.ensure_ascii, self.allow_nan,
                                    self.skipkeys, self.check_circular)
            if text is not none:
                return text
        var chunks = self.iterencode(o, true)
        return "".join(list(chunks))

    def iterencode(self, o, _one_shot=false):
        """Encode the given object and yield each string
        representation as available."""
        var markers = {} if self.check_circular else none
        var enc = encode_basestring_ascii if self.ensure_ascii else encode_basestring
        var it = _NyJsonIterEncode(markers, self.default, enc, self.indent, self.allow_nan,
                                   self.key_separator, self.item_separator, self.sort_keys,
                                   self.skipkeys)
        return it.iterencode(o, 0)
