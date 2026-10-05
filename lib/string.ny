# nython: module    (import it by name: it runs in a module scope of its own)
# lib/string.ny - Python's string module (3.12).
#
#     import string
#     string.ascii_letters, string.digits, string.punctuation, ...
#     string.capwords("hello   world")             # 'Hello World'
#     string.Template("$who likes $what").substitute(who="tim", what="kung pao")
#     string.Formatter().format("{0:>{1}}", "x", 4)
#
# The constants; capwords; Template ($name, ${name}, $$; substitute raises
# KeyError for a missing name and ValueError for a bare delimiter, with
# Python's line/column; safe_substitute leaves both as they are; a mapping
# and keyword arguments together, keywords first; get_identifiers,
# is_valid; a subclass may change `delimiter`); Formatter (format, vformat,
# parse, get_field, get_value, check_unused_args, format_field,
# convert_field) with Python's parser for format strings and field names,
# so a subclass that overrides one step changes it as in Python.
#
# Template is scanned directly rather than with a regular expression: the
# default pattern is a delimiter followed by $, an identifier
# ([_a-zA-Z][_a-zA-Z0-9]*) or a braced one. A subclass that sets its own
# `idpattern`, `braceidpattern`, `flags` or `pattern` gets Python's
# regular-expression machinery through lib/re.ny.
#
# Note for Nython source: "${...}" inside a string literal is Nython's
# string interpolation, so a ${name} template written as a literal needs
# building at run time ("$" + "{name}"); templates read from files, or
# written $name, are unaffected.
#
# `import string` used to bind nothing (it registered isdigit_str and
# isalpha_str, which stay available as globals for older programs).

__all__ = ["ascii_letters", "ascii_lowercase", "ascii_uppercase", "capwords",
           "digits", "hexdigits", "octdigits", "printable", "punctuation",
           "whitespace", "Formatter", "Template"]

whitespace = " \t\n\r\x0b\x0c"
ascii_lowercase = "abcdefghijklmnopqrstuvwxyz"
ascii_uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
ascii_letters = ascii_lowercase + ascii_uppercase
digits = "0123456789"
hexdigits = digits + "abcdef" + "ABCDEF"
octdigits = "01234567"
punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
printable = digits + ascii_letters + punctuation + whitespace


def capwords(s, sep=None):
    var words = s.split() if sep is None else s.split(sep)
    return (sep or " ").join([w.capitalize() for w in words])


# ── Template ─────────────────────────────────────────────────────────────────
_sentinel_dict = {}
_DEFAULT_IDPATTERN = "(?a:[_a-z][_a-z0-9]*)"


def _id_start(c):
    return c == "_" or ("a" <= c and c <= "z") or ("A" <= c and c <= "Z")


def _id_char(c):
    return _id_start(c) or ("0" <= c and c <= "9")


class _TemplateMatch:
    # what Python's match object tells convert(): the kind of placeholder,
    # the identifier, where it is and its text
    def __init__(self, kind, name, start, end, inv_start, text):
        self.kind = kind          # "escaped", "named", "braced" or "invalid"
        self.name = name
        self.start = start
        self.end = end
        self.inv_start = inv_start
        self.text = text


def _scan_template(tmpl, delim):
    # every placeholder of the default pattern, in order
    var out = []
    var n = len(tmpl)
    var dl = len(delim)
    var i = 0
    if dl == 0:
        return out
    while true:
        var j = tmpl.find(delim, i)
        if j < 0:
            break
        var k = j + dl
        if tmpl.startswith(delim, k):
            out.append(_TemplateMatch("escaped", None, j, k + dl, -1, tmpl[j:k + dl]))
            i = k + dl
            continue
        if k < n and _id_start(tmpl[k]):
            var e = k + 1
            while e < n and _id_char(tmpl[e]):
                e = e + 1
            out.append(_TemplateMatch("named", tmpl[k:e], j, e, -1, tmpl[j:e]))
            i = e
            continue
        if k + 1 < n and tmpl[k] == "{" and _id_start(tmpl[k + 1]):
            var e2 = k + 2
            while e2 < n and _id_char(tmpl[e2]):
                e2 = e2 + 1
            if e2 < n and tmpl[e2] == "}":
                out.append(_TemplateMatch("braced", tmpl[k + 1:e2], j, e2 + 1, -1, tmpl[j:e2 + 1]))
                i = e2 + 1
                continue
        out.append(_TemplateMatch("invalid", None, j, k, k, tmpl[j:k]))
        i = k
    return out


def _regex_matches(self):
    # a subclass with its own pattern: Python's regular expression, from
    # lib/re.ny (Template.__init_subclass__ builds the same pattern)
    import re
    var cls = self.__class__
    var pattern = getattr(cls, "pattern", None)
    if pattern is None or isinstance(pattern, str) and getattr(cls, "_ny_pattern_src", None) != pattern:
        if pattern is None:
            var delim = re.escape(cls.delimiter)
            var idp = cls.idpattern
            var bid = cls.braceidpattern or cls.idpattern
            pattern = ("\n            " + delim + "(?:\n              (?P<escaped>" + delim +
                       ")  |   # Escape sequence of two delimiters\n              (?P<named>" + idp +
                       ")       |   # delimiter and a Python identifier\n              {(?P<braced>" + bid +
                       ")} |   # delimiter and a braced identifier\n              (?P<invalid>)             # Other ill-formed delimiter exprs\n            )\n            ")
        var flags = getattr(cls, "flags", re.IGNORECASE)
        cls._ny_pattern = re.compile(pattern, flags | re.VERBOSE) if isinstance(pattern, str) else pattern
        cls._ny_pattern_src = getattr(cls, "pattern", None)
    else:
        cls._ny_pattern = pattern
    var out = []
    for mo in cls._ny_pattern.finditer(self.template):
        var kind = None
        var name = None
        if mo.group("named") is not None:
            kind = "named"
            name = mo.group("named")
        elif mo.group("braced") is not None:
            kind = "braced"
            name = mo.group("braced")
        elif mo.group("escaped") is not None:
            kind = "escaped"
        elif mo.group("invalid") is not None:
            kind = "invalid"
        else:
            raise ValueError("Unrecognized named group in pattern", cls._ny_pattern)
        var inv = mo.start("invalid") if kind == "invalid" else -1
        out.append(_TemplateMatch(kind, name, mo.start(), mo.end(), inv, mo.group()))
    return out


class Template:
    # a string with $-substitutions
    delimiter = "$"
    idpattern = _DEFAULT_IDPATTERN
    braceidpattern = None
    flags = 2          # re.IGNORECASE

    def __init__(self, template):
        self.template = template

    def _matches(self):
        var cls = self.__class__
        if (cls.idpattern == _DEFAULT_IDPATTERN and cls.braceidpattern is None
                and cls.flags == 2 and getattr(cls, "pattern", None) is None):
            return _scan_template(self.template, cls.delimiter)
        return _regex_matches(self)

    def _invalid(self, m):
        var i = m.inv_start
        var lines = self.template[:i].splitlines(True)
        var colno = 1
        var lineno = 1
        if lines:
            colno = i - len("".join(lines[:-1]))
            lineno = len(lines)
        raise ValueError("Invalid placeholder in string: line %d, col %d" % (lineno, colno))

    def _substitute(self, mapping, kws, safe):
        var parts = []
        var pos = 0
        var tmpl = self.template
        for m in self._matches():
            parts.append(tmpl[pos:m.start])
            pos = m.end
            if m.kind == "named" or m.kind == "braced":
                var name = m.name
                if name in kws:
                    parts.append(str(kws[name]))
                elif safe:
                    try:
                        parts.append(str(mapping[name]))
                    except KeyError:
                        parts.append(m.text)
                else:
                    parts.append(str(mapping[name]))
            elif m.kind == "escaped":
                parts.append(self.delimiter)
            elif safe:
                parts.append(m.text)
            else:
                self._invalid(m)
        parts.append(tmpl[pos:])
        return "".join(parts)

    def substitute(self, mapping=_sentinel_dict, /, **kws):
        if id(mapping) == id(_sentinel_dict):
            return self._substitute(kws, {}, false)
        return self._substitute(mapping, kws, false)

    def safe_substitute(self, mapping=_sentinel_dict, /, **kws):
        if id(mapping) == id(_sentinel_dict):
            return self._substitute(kws, {}, true)
        return self._substitute(mapping, kws, true)

    def is_valid(self):
        for m in self._matches():
            if m.kind == "invalid":
                return false
        return true

    def get_identifiers(self):
        var ids = []
        for m in self._matches():
            if (m.kind == "named" or m.kind == "braced") and m.name not in ids:
                ids.append(m.name)
        return ids


# ── Formatter ────────────────────────────────────────────────────────────────
def _get_integer(s):
    # a field name part as an index: its value when it is all decimal
    # digits, else -1
    if s == "":
        return -1
    for c in s:
        if c < "0" or c > "9":
            return -1
    return int(s)


def _parse_field(s, i):
    # CPython's parse_field: from just after '{'; -> (field_name, format_spec,
    # conversion, next index)
    var n = len(s)
    var start = i
    var c = ""
    while i < n:
        c = s[i]
        i = i + 1
        if c == "{":
            raise ValueError("unexpected '{' in field name")
        if c == "[":
            while i < n and s[i] != "]":
                i = i + 1
            c = ""
            continue
        if c == "}" or c == ":" or c == "!":
            break
        c = ""
    var field_name = s[start:i - 1] if c != "" else s[start:i]
    var conversion = None
    if c == "!" or c == ":":
        if c == "!":
            if i >= n:
                raise ValueError("end of string while looking for conversion specifier")
            conversion = s[i]
            i = i + 1
            if i < n:
                var c2 = s[i]
                i = i + 1
                if c2 == "}":
                    return (field_name, "", conversion, i)
                if c2 != ":":
                    raise ValueError("expected ':' after conversion specifier")
        var fstart = i
        var count = 1
        while i < n:
            var c3 = s[i]
            i = i + 1
            if c3 == "{":
                count = count + 1
            elif c3 == "}":
                count = count - 1
                if count == 0:
                    return (field_name, s[fstart:i - 1], conversion, i)
        raise ValueError("unmatched '{' in format spec")
    if c != "}":
        raise ValueError("expected '}' before end of string")
    return (field_name, "", conversion, i)


def _formatter_parser(s):
    # (literal_text, field_name, format_spec, conversion) tuples, as
    # _string.formatter_parser makes them
    var out = []
    var n = len(s)
    var i = 0
    while i < n:
        var start = i
        var c = ""
        var markup = false
        while i < n:
            c = s[i]
            i = i + 1
            if c == "{" or c == "}":
                markup = true
                break
        var at_end = i >= n
        var ln = i - start
        if c == "}" and markup and (at_end or s[i] != "}"):
            raise ValueError("Single '}' encountered in format string")
        if at_end and c == "{" and markup:
            raise ValueError("Single '{' encountered in format string")
        if not at_end and markup:
            if s[i] == c:
                i = i + 1
                markup = false
            else:
                ln = ln - 1
        elif markup:
            ln = ln - 1
        var literal = s[start:start + ln]
        if not markup:
            out.append((literal, None, None, None))
            continue
        var f = _parse_field(s, i)
        i = f[3]
        out.append((literal, f[0], f[1], f[2]))
    return out


def _field_name_split(name):
    # -> (first, [(is_attr, key), ...]) as _string.formatter_field_name_split
    var n = len(name)
    var i = 0
    while i < n and name[i] != "." and name[i] != "[":
        i = i + 1
    var first_s = name[:i]
    var idx = _get_integer(first_s)
    var first = idx if idx != -1 else first_s
    var rest = []
    while i < n:
        var c = name[i]
        i = i + 1
        var key = ""
        if c == ".":
            var st = i
            while i < n and name[i] != "." and name[i] != "[":
                i = i + 1
            key = name[st:i]
            if key == "":
                raise ValueError("Empty attribute in format string")
            rest.append((true, key))
        elif c == "[":
            var st2 = i
            while i < n and name[i] != "]":
                i = i + 1
            if i >= n:
                raise ValueError("Missing ']' in format string")
            key = name[st2:i]
            i = i + 1
            if key == "":
                raise ValueError("Empty attribute in format string")
            var k = _get_integer(key)
            rest.append((false, k if k != -1 else key))
        else:
            raise ValueError("Only '.' or '[' may follow ']' in format field specifier")
    return (first, rest)


class Formatter:
    def format(self, format_string, /, *args, **kwargs):
        return self.vformat(format_string, args, kwargs)

    def vformat(self, format_string, args, kwargs):
        var used_args = set()
        var r = self._vformat(format_string, args, kwargs, used_args, 2)
        self.check_unused_args(used_args, args, kwargs)
        return r[0]

    def _vformat(self, format_string, args, kwargs, used_args, recursion_depth, auto_arg_index=0):
        if recursion_depth < 0:
            raise ValueError("Max string recursion exceeded")
        var result = []
        for item in self.parse(format_string):
            var literal_text = item[0]
            var field_name = item[1]
            var format_spec = item[2]
            var conversion = item[3]
            if literal_text:
                result.append(literal_text)
            if field_name is not None:
                if field_name == "":
                    if isinstance(auto_arg_index, bool) and not auto_arg_index:
                        raise ValueError("cannot switch from manual field specification to automatic field numbering")
                    field_name = str(auto_arg_index)
                    auto_arg_index = auto_arg_index + 1
                elif field_name.isdigit():
                    if not isinstance(auto_arg_index, bool) and auto_arg_index:
                        raise ValueError("cannot switch from manual field specification to automatic field numbering")
                    auto_arg_index = false
                var got = self.get_field(field_name, args, kwargs)
                used_args.add(got[1])
                var obj = self.convert_field(got[0], conversion)
                var sub = self._vformat(format_spec, args, kwargs, used_args, recursion_depth - 1, auto_arg_index)
                auto_arg_index = sub[1]
                result.append(self.format_field(obj, sub[0]))
        return ("".join(result), auto_arg_index)

    def get_value(self, key, args, kwargs):
        if isinstance(key, int):
            return args[key]
        return kwargs[key]

    def check_unused_args(self, used_args, args, kwargs):
        pass

    def format_field(self, value, format_spec):
        return format(value, format_spec)

    def convert_field(self, value, conversion):
        if conversion is None:
            return value
        if conversion == "s":
            return str(value)
        if conversion == "r":
            return repr(value)
        if conversion == "a":
            return ascii(value)
        raise ValueError("Unknown conversion specifier " + str(conversion))

    def parse(self, format_string):
        return iter(_formatter_parser(format_string))

    def get_field(self, field_name, args, kwargs):
        var sp = _field_name_split(field_name)
        var obj = self.get_value(sp[0], args, kwargs)
        for part in sp[1]:
            if part[0]:
                obj = getattr(obj, part[1])
            else:
                obj = obj[part[1]]
        return (obj, sp[0])
