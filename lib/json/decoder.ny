# nython: module
# lib/json/decoder.ny - json.decoder: JSONDecoder, JSONDecodeError, scanstring
# (CPython 3.12's Lib/json/decoder.py; the scanning is builtins/pyjson.cpp,
# which follows Modules/_json.c - see lib/json/__init__.ny).

__all__ = ["JSONDecoder", "JSONDecodeError"]

NaN = float("nan")
PosInf = float("inf")
NegInf = float("-inf")

_CONSTANTS = {"-Infinity": NegInf, "Infinity": PosInf, "NaN": NaN}


class JSONDecodeError(ValueError):
    """Subclass of ValueError with the following additional properties:

    msg: The unformatted error message
    doc: The JSON document being parsed
    pos: The start index of doc where parsing failed
    lineno: The line corresponding to pos
    colno: The column corresponding to pos
    """
    def __init__(self, msg, doc, pos):
        var lineno = doc.count("\n", 0, pos) + 1
        var colno = pos - doc.rfind("\n", 0, pos)
        var errmsg = "%s: line %d column %d (char %d)" % (msg, lineno, colno, pos)
        ValueError.__init__(self, errmsg)
        self.msg = msg
        self.doc = doc
        self.pos = pos
        self.lineno = lineno
        self.colno = colno

    def __reduce__(self):
        return (self.__class__, (self.msg, self.doc, self.pos))


def scanstring(s, end, strict=true):
    """Scan the string s for a JSON string. End is the index of the
    character in s after the quote that started the JSON string.
    Returns a tuple of the decoded string and the index of the character in s
    after the end quote."""
    var r = _json_scanstring(s, end, strict)
    if not r[0]:
        raise JSONDecodeError(r[1], s, r[2])
    return (r[1], r[2])


def _constant(name):
    return _CONSTANTS[name]


class JSONDecoder:
    """Simple JSON <https://json.org> decoder

    Performs the following translations in decoding by default:
    object -> dict, array -> list, string -> str, number (int) -> int,
    number (real) -> float, true -> True, false -> False, null -> None.
    It also understands ``NaN``, ``Infinity``, and ``-Infinity`` as
    their corresponding ``float`` values, which is outside the JSON spec.
    """

    def __init__(self, *, object_hook=none, parse_float=none,
                 parse_int=none, parse_constant=none, strict=true,
                 object_pairs_hook=none):
        self.object_hook = object_hook
        self.parse_float = parse_float if parse_float is not none else float
        self.parse_int = parse_int if parse_int is not none else int
        self.parse_constant = parse_constant if parse_constant is not none else _constant
        self.strict = strict
        self.object_pairs_hook = object_pairs_hook
        self.memo = {}
        # with hooks the scanner returns a tree that _hook() finishes: numbers
        # as ("i"|"f"|"c", text) for parse_* (raw bit 1), objects as
        # ("o", pairs) for object_pairs_hook (bit 2), dicts for object_hook
        self._raw = 0
        if parse_float is not none or parse_int is not none or parse_constant is not none:
            self._raw = self._raw | 1
        if object_pairs_hook is not none:
            self._raw = self._raw | 2
        self._hooked = self._raw != 0 or object_hook is not none

    def decode(self, s, _w=none):
        """Return the Python representation of ``s`` (a ``str`` instance
        containing a JSON document)."""
        if self.__class__.raw_decode == JSONDecoder.raw_decode:
            var r = _json_scan(s, 0, self.strict, self._raw, true)
            if not r[0]:
                raise JSONDecodeError(r[1], s, r[2])
            if self._hooked:
                return self._hook(r[1])
            return r[1]
        # a subclass's raw_decode, called as Python's decode calls it
        var start = _skip_ws(s, 0)
        var got = self.raw_decode(s, start)
        var end = _skip_ws(s, got[1])
        if end != len(s):
            raise JSONDecodeError("Extra data", s, end)
        return got[0]

    def raw_decode(self, s, idx=0):
        """Decode a JSON document from ``s`` (a ``str`` beginning with
        a JSON document) and return a 2-tuple of the Python
        representation and the index in ``s`` where the document ended."""
        var r = _json_scan(s, idx, self.strict, self._raw, false)
        if not r[0]:
            raise JSONDecodeError(r[1], s, r[2])
        if self._hooked:
            return (self._hook(r[1]), r[2])
        return (r[1], r[2])

    def scan_once(self, s, idx):
        """(value, end) at idx; StopIteration(idx) when no value starts there."""
        var r = _json_scan(s, idx, self.strict, self._raw, false)
        if not r[0]:
            if r[1] == "Expecting value" and r[2] == idx:
                raise StopIteration(idx)
            raise JSONDecodeError(r[1], s, r[2])
        if self._hooked:
            return (self._hook(r[1]), r[2])
        return (r[1], r[2])

    def _hook(self, node):
        # the scanner's tree: arrays are lists, objects dicts or ("o", [k, v,
        # ...]), numbers ("i" | "f" | "c", text) when parse_* hooks are set.
        # Hooks run in document order, an object's after its members', as
        # Python's scanner calls them; lists and dicts are finished in place.
        if isinstance(node, list):
            for i in range(len(node)):
                var x = node[i]
                if isinstance(x, list) or isinstance(x, dict) or isinstance(x, tuple):
                    node[i] = self._hook(x)
            return node
        if isinstance(node, dict):
            for k in list(node.keys()):
                var v = node[k]
                if isinstance(v, list) or isinstance(v, dict) or isinstance(v, tuple):
                    node[k] = self._hook(v)
            if self.object_hook is not none:
                return self.object_hook(node)
            return node
        if isinstance(node, tuple):
            var tag = node[0]
            if tag == "o":
                var flat = node[1]
                var pairs = []
                var i = 0
                while i < len(flat):
                    pairs.append((flat[i], self._hook(flat[i + 1])))
                    i = i + 2
                if self.object_pairs_hook is not none:
                    return self.object_pairs_hook(pairs)
                var d = {}
                for kv in pairs:
                    d[kv[0]] = kv[1]
                if self.object_hook is not none:
                    return self.object_hook(d)
                return d
            if tag == "i":
                return self.parse_int(node[1])
            if tag == "f":
                return self.parse_float(node[1])
            return self.parse_constant(node[1])
        return node


def _skip_ws(s, i):
    var n = len(s)
    while i < n and (s[i] == " " or s[i] == "\t" or s[i] == "\n" or s[i] == "\r"):
        i = i + 1
    return i
