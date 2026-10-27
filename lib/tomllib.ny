# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/tomllib.ny - Python's tomllib (3.11): TOML 1.0.0 (https://toml.io/en/
# v1.0.0) parsed to Python values. The parser is CPython's Lib/tomllib
# (Taneli Hukkinen's tomli, MIT licence, notice below), its three files
# in one module here, so documents parse to the same values and errors carry
# the same messages.
#
#     import tomllib
#     tomllib.loads('title = "x"\n[owner]\ndob = 1979-05-27T07:32:00-08:00\n')
#     # {'title': 'x', 'owner': {'dob': datetime.datetime(1979, 5, 27, 7, 32,
#     #  tzinfo=datetime.timezone(datetime.timedelta(days=-1, seconds=57600)))}}
#     with open("pyproject.toml", "rb") as f:
#         data = tomllib.load(f)
#
# loads(s, *, parse_float=float), load(fp, *, parse_float=float) (fp opened
# in binary mode: TypeError otherwise, CPython's message), TOMLDecodeError (a
# ValueError: "Invalid value (at line 3, column 7)", "... (at end of
# document)"). Every TOML value: basic/literal/multi-line strings with all
# escapes, integers (decimal, 0x/0o/0b, underscores, +/-), floats (exponents,
# inf, nan, signs), booleans, offset date-times -> datetime with
# datetime.timezone, local date-times -> naive datetime, local dates ->
# date, local times -> time; arrays (mixed types), inline tables, tables,
# arrays of tables, dotted keys, quoted keys, and TOML's redefinition rules
# (a table defined twice, a key overwritten, a dotted key into a table
# defined elsewhere, appending to an inline array... are errors).
#
# Nython only (not in CPython, where tomllib only reads - PEP 680):
# dumps(obj) and dump(obj, fp) write a dict as TOML that loads() reads
# back to an equal dict (see the end of the file).
#
# Differences from CPython: none in what it parses.
#
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2021 Taneli Hukkinen
# Licensed to PSF under a Contributor Agreement.
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2021 Taneli Hukkinen
# Licensed to PSF under a Contributor Agreement.

from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone, tzinfo
import re

__all__ = ("loads", "load", "TOMLDecodeError", "dumps", "dump")

# ── tomllib/_re.py ───────────────────────────────────────────────────────────
# E.g.
# - 00:32:00.999999
# - 00:32:00
_TIME_RE_STR = r"([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(?:\.([0-9]{1,6})[0-9]*)?"

RE_NUMBER = re.compile(
    r"""
0
(?:
    x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*   # hex
    |
    b[01](?:_?[01])*                 # bin
    |
    o[0-7](?:_?[0-7])*               # oct
)
|
[+-]?(?:0|[1-9](?:_?[0-9])*)         # dec, integer part
(?P<floatpart>
    (?:\.[0-9](?:_?[0-9])*)?         # optional fractional part
    (?:[eE][+-]?[0-9](?:_?[0-9])*)?  # optional exponent part
)
""",
    flags=re.VERBOSE,
)
RE_LOCALTIME = re.compile(_TIME_RE_STR)
RE_DATETIME = re.compile(
    rf"""
([0-9]{{4}})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])  # date, e.g. 1988-10-27
(?:
    [Tt ]
    {_TIME_RE_STR}
    (?:([Zz])|([+-])([01][0-9]|2[0-3]):([0-5][0-9]))?  # optional time offset
)?
""",
    flags=re.VERBOSE,
)


def match_to_datetime(match: re.Match) -> datetime | date:
    (
        year_str,
        month_str,
        day_str,
        hour_str,
        minute_str,
        sec_str,
        micros_str,
        zulu_time,
        offset_sign_str,
        offset_hour_str,
        offset_minute_str,
    ) = match.groups()
    year, month, day = int(year_str), int(month_str), int(day_str)
    if hour_str is None:
        return date(year, month, day)
    hour, minute, sec = int(hour_str), int(minute_str), int(sec_str)
    micros = int(micros_str.ljust(6, "0")) if micros_str else 0
    if offset_sign_str:
        tz: tzinfo | None = cached_tz(
            offset_hour_str, offset_minute_str, offset_sign_str
        )
    elif zulu_time:
        tz = timezone.utc
    else:  # local date-time
        tz = None
    return datetime(year, month, day, hour, minute, sec, micros, tzinfo=tz)


_tz_cache = {}


def cached_tz(hour_str: str, minute_str: str, sign_str: str) -> timezone:
    # (CPython: functools.lru_cache)
    k = (hour_str, minute_str, sign_str)
    tz = _tz_cache.get(k)
    if tz is None:
        sign = 1 if sign_str == "+" else -1
        tz = timezone(
            timedelta(
                hours=sign * int(hour_str),
                minutes=sign * int(minute_str),
            )
        )
        _tz_cache[k] = tz
    return tz


def match_to_localtime(match: re.Match) -> time:
    hour_str, minute_str, sec_str, micros_str = match.groups()
    micros = int(micros_str.ljust(6, "0")) if micros_str else 0
    return time(int(hour_str), int(minute_str), int(sec_str), micros)


def match_to_number(match: re.Match, parse_float: ParseFloat) -> Any:
    if match.group("floatpart"):
        return parse_float(match.group())
    return int(match.group(), 0)


# ── tomllib/_parser.py ───────────────────────────────────────────────────────

ASCII_CTRL = frozenset(chr(i) for i in range(32)) | frozenset(chr(127))

# Neither of these sets include quotation mark or backslash. They are
# currently handled as separate cases in the parser functions.
ILLEGAL_BASIC_STR_CHARS = ASCII_CTRL - frozenset("\t")
ILLEGAL_MULTILINE_BASIC_STR_CHARS = ASCII_CTRL - frozenset("\t\n")

ILLEGAL_LITERAL_STR_CHARS = ILLEGAL_BASIC_STR_CHARS
ILLEGAL_MULTILINE_LITERAL_STR_CHARS = ILLEGAL_MULTILINE_BASIC_STR_CHARS

ILLEGAL_COMMENT_CHARS = ILLEGAL_BASIC_STR_CHARS

TOML_WS = frozenset(" \t")
TOML_WS_AND_NEWLINE = TOML_WS | frozenset("\n")
BARE_KEY_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" + "-_")
KEY_INITIAL_CHARS = BARE_KEY_CHARS | frozenset("\"'")
HEXDIGIT_CHARS = frozenset("0123456789abcdefABCDEF")

BASIC_STR_ESCAPE_REPLACEMENTS = (
    {
        "\\b": "\u0008",  # backspace
        "\\t": "\u0009",  # tab
        "\\n": "\u000A",  # linefeed
        "\\f": "\u000C",  # form feed
        "\\r": "\u000D",  # carriage return
        '\\"': "\u0022",  # quote
        "\\\\": "\u005C",  # backslash
    }
)


class TOMLDecodeError(ValueError):
    pass


TOMLDecodeError.__module__ = "tomllib"


def load(fp: BinaryIO, /, *, parse_float: ParseFloat = float) -> dict[str, Any]:
    b = fp.read()
    try:
        if isinstance(b, str):
            # (Nython's str has a decode() method: refuse a text file here)
            raise AttributeError("decode")
        s = b.decode()
    except AttributeError:
        raise TypeError(
            "File must be opened in binary mode, e.g. use `open('foo.toml', 'rb')`"
        ) from None
    return loads(s, parse_float=parse_float)


def loads(s: str, /, *, parse_float: ParseFloat = float) -> dict[str, Any]:  # noqa: C901

    # The spec allows converting "\r\n" to "\n", even in string
    # literals. Let's do so to simplify parsing.
    src = s.replace("\r\n", "\n")
    pos = 0
    out = Output(NestedDict(), Flags())
    header: Key = ()
    parse_float = make_safe_parse_float(parse_float)

    # Parse one statement at a time
    # (typically means one line in TOML source)
    while True:
        # 1. Skip line leading whitespace
        pos = skip_chars(src, pos, TOML_WS)

        # 2. Parse rules. Expect one of the following:
        #    - end of file
        #    - end of line
        #    - comment
        #    - key/value pair
        #    - append dict to list (and move to its namespace)
        #    - create dict (and move to its namespace)
        # Skip trailing whitespace when applicable.
        try:
            char = src[pos]
        except IndexError:
            break
        if char == "\n":
            pos += 1
            continue
        if char in KEY_INITIAL_CHARS:
            pos = key_value_rule(src, pos, out, header, parse_float)
            pos = skip_chars(src, pos, TOML_WS)
        elif char == "[":
            try:
                second_char: str | None = src[pos + 1]
            except IndexError:
                second_char = None
            out.flags.finalize_pending()
            if second_char == "[":
                pos, header = create_list_rule(src, pos, out)
            else:
                pos, header = create_dict_rule(src, pos, out)
            pos = skip_chars(src, pos, TOML_WS)
        elif char != "#":
            raise suffixed_err(src, pos, "Invalid statement")

        # 3. Skip comment
        pos = skip_comment(src, pos)

        # 4. Expect end of line or end of file
        try:
            char = src[pos]
        except IndexError:
            break
        if char != "\n":
            raise suffixed_err(
                src, pos, "Expected newline or end of document after a statement"
            )
        pos += 1

    return out.data.dict


class Flags:

    # Marks an immutable namespace (inline array or inline table).
    FROZEN = 0
    # Marks a nest that has been explicitly created and can no longer
    # be opened using the "[table]" syntax.
    EXPLICIT_NEST = 1

    def __init__(self) -> None:
        self._flags: dict[str, dict] = {}
        self._pending_flags: set[tuple[Key, int]] = set()

    def add_pending(self, key: Key, flag: int) -> None:
        self._pending_flags.add((key, flag))

    def finalize_pending(self) -> None:
        for key, flag in self._pending_flags:
            self.set(key, flag, recursive=False)
        self._pending_flags.clear()

    def unset_all(self, key: Key) -> None:
        cont = self._flags
        for k in key[:-1]:
            if k not in cont:
                return
            cont = cont[k]["nested"]
        cont.pop(key[-1], None)

    def set(self, key: Key, flag: int, *, recursive: bool) -> None:  # noqa: A003
        cont = self._flags
        key_parent, key_stem = key[:-1], key[-1]
        for k in key_parent:
            if k not in cont:
                cont[k] = {"flags": set(), "recursive_flags": set(), "nested": {}}
            cont = cont[k]["nested"]
        if key_stem not in cont:
            cont[key_stem] = {"flags": set(), "recursive_flags": set(), "nested": {}}
        cont[key_stem]["recursive_flags" if recursive else "flags"].add(flag)

    def is_(self, key: Key, flag: int) -> bool:
        if not key:
            return False  # document root has no flags
        cont = self._flags
        for k in key[:-1]:
            if k not in cont:
                return False
            inner_cont = cont[k]
            if flag in inner_cont["recursive_flags"]:
                return True
            cont = inner_cont["nested"]
        key_stem = key[-1]
        if key_stem in cont:
            cont = cont[key_stem]
            return flag in cont["flags"] or flag in cont["recursive_flags"]
        return False


class NestedDict:
    def __init__(self) -> None:
        # The parsed content of the TOML document
        self.dict: dict[str, Any] = {}

    def get_or_create_nest(
        self,
        key: Key,
        *,
        access_lists: bool = True,
    ) -> dict:
        cont: Any = self.dict
        for k in key:
            if k not in cont:
                cont[k] = {}
            cont = cont[k]
            if access_lists and isinstance(cont, list):
                cont = cont[-1]
            if not isinstance(cont, dict):
                raise KeyError("There is no nest behind this key")
        return cont

    def append_nest_to_list(self, key: Key) -> None:
        cont = self.get_or_create_nest(key[:-1])
        last_key = key[-1]
        if last_key in cont:
            list_ = cont[last_key]
            if not isinstance(list_, list):
                raise KeyError("An object other than list found behind this key")
            list_.append({})
        else:
            cont[last_key] = [{}]


class Output:
    # (CPython: a typing.NamedTuple)
    def __init__(self, data, flags):
        self.data = data
        self.flags = flags


def skip_chars(src: str, pos: Pos, chars: Iterable[str]) -> Pos:
    try:
        while src[pos] in chars:
            pos += 1
    except IndexError:
        pass
    return pos


def skip_until(
    src: str,
    pos: Pos,
    expect: str,
    *,
    error_on: frozenset[str],
    error_on_eof: bool,
) -> Pos:
    try:
        new_pos = src.index(expect, pos)
    except ValueError:
        new_pos = len(src)
        if error_on_eof:
            raise suffixed_err(src, new_pos, f"Expected {expect!r}") from None

    if not error_on.isdisjoint(src[pos:new_pos]):
        while src[pos] not in error_on:
            pos += 1
        raise suffixed_err(src, pos, f"Found invalid character {src[pos]!r}")
    return new_pos


def skip_comment(src: str, pos: Pos) -> Pos:
    try:
        char: str | None = src[pos]
    except IndexError:
        char = None
    if char == "#":
        return skip_until(
            src, pos + 1, "\n", error_on=ILLEGAL_COMMENT_CHARS, error_on_eof=False
        )
    return pos


def skip_comments_and_array_ws(src: str, pos: Pos) -> Pos:
    while True:
        pos_before_skip = pos
        pos = skip_chars(src, pos, TOML_WS_AND_NEWLINE)
        pos = skip_comment(src, pos)
        if pos == pos_before_skip:
            return pos


def create_dict_rule(src: str, pos: Pos, out: Output) -> tuple[Pos, Key]:
    pos += 1  # Skip "["
    pos = skip_chars(src, pos, TOML_WS)
    pos, key = parse_key(src, pos)

    if out.flags.is_(key, Flags.EXPLICIT_NEST) or out.flags.is_(key, Flags.FROZEN):
        raise suffixed_err(src, pos, f"Cannot declare {key} twice")
    out.flags.set(key, Flags.EXPLICIT_NEST, recursive=False)
    try:
        out.data.get_or_create_nest(key)
    except KeyError:
        raise suffixed_err(src, pos, "Cannot overwrite a value") from None

    if not src.startswith("]", pos):
        raise suffixed_err(src, pos, "Expected ']' at the end of a table declaration")
    return pos + 1, key


def create_list_rule(src: str, pos: Pos, out: Output) -> tuple[Pos, Key]:
    pos += 2  # Skip "[["
    pos = skip_chars(src, pos, TOML_WS)
    pos, key = parse_key(src, pos)

    if out.flags.is_(key, Flags.FROZEN):
        raise suffixed_err(src, pos, f"Cannot mutate immutable namespace {key}")
    # Free the namespace now that it points to another empty list item...
    out.flags.unset_all(key)
    # ...but this key precisely is still prohibited from table declaration
    out.flags.set(key, Flags.EXPLICIT_NEST, recursive=False)
    try:
        out.data.append_nest_to_list(key)
    except KeyError:
        raise suffixed_err(src, pos, "Cannot overwrite a value") from None

    if not src.startswith("]]", pos):
        raise suffixed_err(src, pos, "Expected ']]' at the end of an array declaration")
    return pos + 2, key


def key_value_rule(
    src: str, pos: Pos, out: Output, header: Key, parse_float: ParseFloat
) -> Pos:
    pos, key, value = parse_key_value_pair(src, pos, parse_float)
    key_parent, key_stem = key[:-1], key[-1]
    abs_key_parent = header + key_parent

    relative_path_cont_keys = (header + key[:i] for i in range(1, len(key)))
    for cont_key in relative_path_cont_keys:
        # Check that dotted key syntax does not redefine an existing table
        if out.flags.is_(cont_key, Flags.EXPLICIT_NEST):
            raise suffixed_err(src, pos, f"Cannot redefine namespace {cont_key}")
        # Containers in the relative path can't be opened with the table syntax or
        # dotted key/value syntax in following table sections.
        out.flags.add_pending(cont_key, Flags.EXPLICIT_NEST)

    if out.flags.is_(abs_key_parent, Flags.FROZEN):
        raise suffixed_err(
            src, pos, f"Cannot mutate immutable namespace {abs_key_parent}"
        )

    try:
        nest = out.data.get_or_create_nest(abs_key_parent)
    except KeyError:
        raise suffixed_err(src, pos, "Cannot overwrite a value") from None
    if key_stem in nest:
        raise suffixed_err(src, pos, "Cannot overwrite a value")
    # Mark inline table and array namespaces recursively immutable
    if isinstance(value, (dict, list)):
        out.flags.set(header + key, Flags.FROZEN, recursive=True)
    nest[key_stem] = value
    return pos


def parse_key_value_pair(
    src: str, pos: Pos, parse_float: ParseFloat
) -> tuple[Pos, Key, Any]:
    pos, key = parse_key(src, pos)
    try:
        char: str | None = src[pos]
    except IndexError:
        char = None
    if char != "=":
        raise suffixed_err(src, pos, "Expected '=' after a key in a key/value pair")
    pos += 1
    pos = skip_chars(src, pos, TOML_WS)
    pos, value = parse_value(src, pos, parse_float)
    return pos, key, value


def parse_key(src: str, pos: Pos) -> tuple[Pos, Key]:
    pos, key_part = parse_key_part(src, pos)
    key: Key = (key_part,)
    pos = skip_chars(src, pos, TOML_WS)
    while True:
        try:
            char: str | None = src[pos]
        except IndexError:
            char = None
        if char != ".":
            return pos, key
        pos += 1
        pos = skip_chars(src, pos, TOML_WS)
        pos, key_part = parse_key_part(src, pos)
        key += (key_part,)
        pos = skip_chars(src, pos, TOML_WS)


def parse_key_part(src: str, pos: Pos) -> tuple[Pos, str]:
    try:
        char: str | None = src[pos]
    except IndexError:
        char = None
    if char in BARE_KEY_CHARS:
        start_pos = pos
        pos = skip_chars(src, pos, BARE_KEY_CHARS)
        return pos, src[start_pos:pos]
    if char == "'":
        return parse_literal_str(src, pos)
    if char == '"':
        return parse_one_line_basic_str(src, pos)
    raise suffixed_err(src, pos, "Invalid initial character for a key part")


def parse_one_line_basic_str(src: str, pos: Pos) -> tuple[Pos, str]:
    pos += 1
    return parse_basic_str(src, pos, multiline=False)


def parse_array(src: str, pos: Pos, parse_float: ParseFloat) -> tuple[Pos, list]:
    pos += 1
    array: list = []

    pos = skip_comments_and_array_ws(src, pos)
    if src.startswith("]", pos):
        return pos + 1, array
    while True:
        pos, val = parse_value(src, pos, parse_float)
        array.append(val)
        pos = skip_comments_and_array_ws(src, pos)

        c = src[pos : pos + 1]
        if c == "]":
            return pos + 1, array
        if c != ",":
            raise suffixed_err(src, pos, "Unclosed array")
        pos += 1

        pos = skip_comments_and_array_ws(src, pos)
        if src.startswith("]", pos):
            return pos + 1, array


def parse_inline_table(src: str, pos: Pos, parse_float: ParseFloat) -> tuple[Pos, dict]:
    pos += 1
    nested_dict = NestedDict()
    flags = Flags()

    pos = skip_chars(src, pos, TOML_WS)
    if src.startswith("}", pos):
        return pos + 1, nested_dict.dict
    while True:
        pos, key, value = parse_key_value_pair(src, pos, parse_float)
        key_parent, key_stem = key[:-1], key[-1]
        if flags.is_(key, Flags.FROZEN):
            raise suffixed_err(src, pos, f"Cannot mutate immutable namespace {key}")
        try:
            nest = nested_dict.get_or_create_nest(key_parent, access_lists=False)
        except KeyError:
            raise suffixed_err(src, pos, "Cannot overwrite a value") from None
        if key_stem in nest:
            raise suffixed_err(src, pos, f"Duplicate inline table key {key_stem!r}")
        nest[key_stem] = value
        pos = skip_chars(src, pos, TOML_WS)
        c = src[pos : pos + 1]
        if c == "}":
            return pos + 1, nested_dict.dict
        if c != ",":
            raise suffixed_err(src, pos, "Unclosed inline table")
        if isinstance(value, (dict, list)):
            flags.set(key, Flags.FROZEN, recursive=True)
        pos += 1
        pos = skip_chars(src, pos, TOML_WS)


def parse_basic_str_escape(
    src: str, pos: Pos, *, multiline: bool = False
) -> tuple[Pos, str]:
    escape_id = src[pos : pos + 2]
    pos += 2
    if multiline and escape_id in {"\\ ", "\\\t", "\\\n"}:
        # Skip whitespace until next non-whitespace character or end of
        # the doc. Error if non-whitespace is found before newline.
        if escape_id != "\\\n":
            pos = skip_chars(src, pos, TOML_WS)
            try:
                char = src[pos]
            except IndexError:
                return pos, ""
            if char != "\n":
                raise suffixed_err(src, pos, "Unescaped '\\' in a string")
            pos += 1
        pos = skip_chars(src, pos, TOML_WS_AND_NEWLINE)
        return pos, ""
    if escape_id == "\\u":
        return parse_hex_char(src, pos, 4)
    if escape_id == "\\U":
        return parse_hex_char(src, pos, 8)
    try:
        return pos, BASIC_STR_ESCAPE_REPLACEMENTS[escape_id]
    except KeyError:
        raise suffixed_err(src, pos, "Unescaped '\\' in a string") from None


def parse_basic_str_escape_multiline(src: str, pos: Pos) -> tuple[Pos, str]:
    return parse_basic_str_escape(src, pos, multiline=True)


def parse_hex_char(src: str, pos: Pos, hex_len: int) -> tuple[Pos, str]:
    hex_str = src[pos : pos + hex_len]
    if len(hex_str) != hex_len or not HEXDIGIT_CHARS.issuperset(hex_str):
        raise suffixed_err(src, pos, "Invalid hex value")
    pos += hex_len
    hex_int = int(hex_str, 16)
    if not is_unicode_scalar_value(hex_int):
        raise suffixed_err(src, pos, "Escaped character is not a Unicode scalar value")
    return pos, chr(hex_int)


def parse_literal_str(src: str, pos: Pos) -> tuple[Pos, str]:
    pos += 1  # Skip starting apostrophe
    start_pos = pos
    pos = skip_until(
        src, pos, "'", error_on=ILLEGAL_LITERAL_STR_CHARS, error_on_eof=True
    )
    return pos + 1, src[start_pos:pos]  # Skip ending apostrophe


def parse_multiline_str(src: str, pos: Pos, *, literal: bool) -> tuple[Pos, str]:
    pos += 3
    if src.startswith("\n", pos):
        pos += 1

    if literal:
        delim = "'"
        end_pos = skip_until(
            src,
            pos,
            "'''",
            error_on=ILLEGAL_MULTILINE_LITERAL_STR_CHARS,
            error_on_eof=True,
        )
        result = src[pos:end_pos]
        pos = end_pos + 3
    else:
        delim = '"'
        pos, result = parse_basic_str(src, pos, multiline=True)

    # Add at maximum two extra apostrophes/quotes if the end sequence
    # is 4 or 5 chars long instead of just 3.
    if not src.startswith(delim, pos):
        return pos, result
    pos += 1
    if not src.startswith(delim, pos):
        return pos, result + delim
    pos += 1
    return pos, result + (delim * 2)


def parse_basic_str(src: str, pos: Pos, *, multiline: bool) -> tuple[Pos, str]:
    if multiline:
        error_on = ILLEGAL_MULTILINE_BASIC_STR_CHARS
        parse_escapes = parse_basic_str_escape_multiline
    else:
        error_on = ILLEGAL_BASIC_STR_CHARS
        parse_escapes = parse_basic_str_escape
    result = ""
    start_pos = pos
    while True:
        try:
            char = src[pos]
        except IndexError:
            raise suffixed_err(src, pos, "Unterminated string") from None
        if char == '"':
            if not multiline:
                return pos + 1, result + src[start_pos:pos]
            if src.startswith('"""', pos):
                return pos + 3, result + src[start_pos:pos]
            pos += 1
            continue
        if char == "\\":
            result += src[start_pos:pos]
            pos, parsed_escape = parse_escapes(src, pos)
            result += parsed_escape
            start_pos = pos
            continue
        if char in error_on:
            raise suffixed_err(src, pos, f"Illegal character {char!r}")
        pos += 1


def parse_value(  # noqa: C901
    src: str, pos: Pos, parse_float: ParseFloat
) -> tuple[Pos, Any]:
    try:
        char: str | None = src[pos]
    except IndexError:
        char = None

    # IMPORTANT: order conditions based on speed of checking and likelihood

    # Basic strings
    if char == '"':
        if src.startswith('"""', pos):
            return parse_multiline_str(src, pos, literal=False)
        return parse_one_line_basic_str(src, pos)

    # Literal strings
    if char == "'":
        if src.startswith("'''", pos):
            return parse_multiline_str(src, pos, literal=True)
        return parse_literal_str(src, pos)

    # Booleans
    if char == "t":
        if src.startswith("true", pos):
            return pos + 4, True
    if char == "f":
        if src.startswith("false", pos):
            return pos + 5, False

    # Arrays
    if char == "[":
        return parse_array(src, pos, parse_float)

    # Inline tables
    if char == "{":
        return parse_inline_table(src, pos, parse_float)

    # Dates and times
    datetime_match = RE_DATETIME.match(src, pos)
    if datetime_match:
        try:
            datetime_obj = match_to_datetime(datetime_match)
        except ValueError as e:
            raise suffixed_err(src, pos, "Invalid date or datetime") from e
        return datetime_match.end(), datetime_obj
    localtime_match = RE_LOCALTIME.match(src, pos)
    if localtime_match:
        return localtime_match.end(), match_to_localtime(localtime_match)

    # Integers and "normal" floats.
    # The regex will greedily match any type starting with a decimal
    # char, so needs to be located after handling of dates and times.
    number_match = RE_NUMBER.match(src, pos)
    if number_match:
        return number_match.end(), match_to_number(number_match, parse_float)

    # Special floats
    first_three = src[pos : pos + 3]
    if first_three in {"inf", "nan"}:
        return pos + 3, parse_float(first_three)
    first_four = src[pos : pos + 4]
    if first_four in {"-inf", "+inf", "-nan", "+nan"}:
        return pos + 4, parse_float(first_four)

    raise suffixed_err(src, pos, "Invalid value")


def suffixed_err(src: str, pos: Pos, msg: str) -> TOMLDecodeError:

    def coord_repr(src: str, pos: Pos) -> str:
        if pos >= len(src):
            return "end of document"
        line = src.count("\n", 0, pos) + 1
        if line == 1:
            column = pos + 1
        else:
            column = pos - src.rindex("\n", 0, pos)
        return f"line {line}, column {column}"

    return TOMLDecodeError(f"{msg} (at {coord_repr(src, pos)})")


def is_unicode_scalar_value(codepoint: int) -> bool:
    return (0 <= codepoint <= 55295) or (57344 <= codepoint <= 1114111)


def make_safe_parse_float(parse_float: ParseFloat) -> ParseFloat:
    # The default `float` callable never returns illegal types. Optimize it.
    if parse_float is float:  # type: ignore[comparison-overlap]
        return float

    def safe_parse_float(float_str: str) -> Any:
        float_value = parse_float(float_str)
        if isinstance(float_value, (dict, list)):
            raise ValueError("parse_float must not return dicts or lists")
        return float_value

    return safe_parse_float


# ── Nython only: writing TOML ────────────────────────────────────────────────
# CPython's tomllib only reads (PEP 680 leaves writing to third-party
# packages such as tomli-w). dumps(obj) / dump(obj, fp) write a dict as
# TOML 1.0 that loads() reads back to an equal dict: plain values first as
# key = value lines, then each sub-table as [a.b] and each list of tables as
# [[a.b]]; tables inside arrays and dicts nested in inline values are inline
# tables, other lists inline arrays. Keys are bare when they can be
# (A-Z a-z 0-9 _ -), quoted otherwise; strings are basic strings with
# TOML's escapes; floats round-trip (repr, inf, -inf, nan); datetimes,
# dates and times are written as TOML's offset/local date-times, local
# dates and local times. A value TOML cannot hold (None, a time with a
# tzinfo, an object) raises TypeError / ValueError.

_BARE_KEY_RE = re.compile(r"[A-Za-z0-9_-]+\Z")
_TOML_ESC = {"\\": "\\\\", '"': '\\"', "\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r"}


def _dump_key(k):
    if not isinstance(k, str):
        raise TypeError("TOML keys must be strings, not " + type(k).__name__)
    if _BARE_KEY_RE.match(k):
        return k
    return _dump_str(k)


def _dump_str(s):
    out = ['"']
    for ch in s:
        e = _TOML_ESC.get(ch)
        if e is not None:
            out.append(e)
        elif ch < " " or ch == "\x7f":
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _is_table_array(v):
    if not isinstance(v, (list, tuple)) or len(v) == 0:
        return False
    for x in v:
        if not isinstance(x, dict):
            return False
    return True


def _dump_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return _dump_str(v)
    if isinstance(v, int):
        return str(int(v))
    if isinstance(v, float):
        if v != v:
            return "nan"
        if v == float("inf"):
            return "inf"
        if v == float("-inf"):
            return "-inf"
        return repr(v)
    if isinstance(v, datetime):
        return v.isoformat()
    if isinstance(v, date):
        return v.isoformat()
    if isinstance(v, time):
        if v.tzinfo is not None:
            raise ValueError("TOML cannot hold a time with a time zone: " + repr(v))
        return v.isoformat()
    if isinstance(v, dict):
        parts = []
        for k in v:
            parts.append(_dump_key(k) + " = " + _dump_value(v[k]))
        if not parts:
            return "{}"
        return "{ " + ", ".join(parts) + " }"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_dump_value(x) for x in v) + "]"
    raise TypeError("Object of type " + type(v).__name__ + " is not TOML serializable")


def _dump_table(table, path, out, header):
    plain = []
    tables = []
    for k in table:
        v = table[k]
        if isinstance(v, dict):
            tables.append((k, v, False))
        elif _is_table_array(v):
            tables.append((k, v, True))
        else:
            plain.append((k, v))
    if header and (plain or not tables):
        if out:
            out.append("")
        out.append("[" + ".".join(_dump_key(p) for p in path) + "]")
    for k, v in plain:
        out.append(_dump_key(k) + " = " + _dump_value(v))
    for k, v, is_array in tables:
        sub = path + [k]
        if is_array:
            for item in v:
                if out:
                    out.append("")
                out.append("[[" + ".".join(_dump_key(p) for p in sub) + "]]")
                _dump_table(item, sub, out, False)
        else:
            _dump_table(v, sub, out, True)


def dumps(obj, /):
    # (Nython only; see above)
    if not isinstance(obj, dict):
        raise TypeError("dumps() takes a dict, not " + type(obj).__name__)
    out = []
    _dump_table(obj, [], out, False)
    if not out:
        return ""
    return "\n".join(out) + "\n"


def dump(obj, fp, /):
    # (Nython only) writes dumps(obj) as UTF-8 to a binary file
    fp.write(dumps(obj).encode())
