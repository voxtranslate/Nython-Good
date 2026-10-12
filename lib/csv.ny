# nython: module    (import it by name: it runs in a module scope of its own)
# lib/csv.ny - Python's csv (3.12): CSV files read and written as Python
# does.
#
#     import csv
#     with open("data.csv", newline="") as f:
#         for row in csv.reader(f):            # lists of strings
#             ...
#     w = csv.writer(open("out.csv", "w", newline=""), quoting=csv.QUOTE_NONNUMERIC)
#     w.writerow(["name", 1.5])                # "name",1.5\r\n
#     for d in csv.DictReader(lines): ...      # dicts keyed by the header
#
# reader, writer, DictReader, DictWriter; Dialect, excel, excel_tab,
# unix_dialect, register_dialect / unregister_dialect / get_dialect /
# list_dialects, field_size_limit, Sniffer (sniff, has_header); the
# QUOTE_MINIMAL / ALL / NONNUMERIC / NONE / STRINGS / NOTNULL constants and
# csv.Error. Every format parameter Python has: delimiter, quotechar,
# escapechar, doublequote, skipinitialspace, lineterminator, quoting,
# strict - validated with Python's messages.
#
# The reader is Python's state machine (_csv.c) - quoted fields may hold
# delimiters, quotes ("" or escaped) and line breaks, a record may span
# several input lines, strict mode raises where Python's does - with a fast
# path for the common line that has no quote or escape character in it
# (split on the delimiter, no per-character work). A reader takes any
# iterable of strings: a list, a file from open(), a generator. The writer
# writes what Python's writes (\r\n line ends by default, quoting only
# where needed in QUOTE_MINIMAL); booleans are written True/False and None
# as an empty field, as Python writes them.
#
# Files: Nython's open() reads text with \r\n made \n whatever newline=
# says, so a quoted field that holds \r\n in the file reads back as \n
# (records and every other field are the same as Python's).
#
# Sniffer.sniff finds the delimiter by Python's character-frequency method
# and the quote character from quoted fields between delimiters, as
# Python's does; its regular expressions are applied by hand here (the
# doublequote guess follows Python's pattern closely, not exactly).
import sys

__all__ = ["QUOTE_MINIMAL", "QUOTE_ALL", "QUOTE_NONNUMERIC", "QUOTE_NONE",
           "QUOTE_STRINGS", "QUOTE_NOTNULL", "Error", "Dialect", "excel",
           "excel_tab", "field_size_limit", "reader", "writer",
           "register_dialect", "get_dialect", "list_dialects", "Sniffer",
           "unregister_dialect", "DictReader", "DictWriter", "unix_dialect"]

__version__ = "1.0"

QUOTE_MINIMAL = 0
QUOTE_ALL = 1
QUOTE_NONNUMERIC = 2
QUOTE_NONE = 3
QUOTE_STRINGS = 4
QUOTE_NOTNULL = 5


class Error(Exception):
    pass


def _tn(x):
    var n = type(x).__name__
    if n == "string":
        return "str"
    if n == "map":
        return "dict"
    if n == "none":
        return "NoneType"
    return n


_field_limit = [131072]


def field_size_limit(*args):
    if len(args) > 1:
        raise TypeError("field_size_limit expected at most 1 argument, got " + str(len(args)))
    var old = _field_limit[0]
    if len(args) == 1:
        var new_limit = args[0]
        if not isinstance(new_limit, int) or isinstance(new_limit, bool):
            raise TypeError("limit must be an integer")
        _field_limit[0] = new_limit
    return old


# ── dialects ─────────────────────────────────────────────────────────────────
_UNSET = ["unset"]


def _char_param(name, v, dflt, allow_none):
    if id(v) == id(_UNSET):
        return dflt
    if v is None and allow_none:
        return None
    if not isinstance(v, str):
        if allow_none:
            raise TypeError("\"" + name + "\" must be string or None, not " + _tn(v))
        raise TypeError("\"" + name + "\" must be string, not " + _tn(v))
    if len(v) != 1:
        raise TypeError("\"" + name + "\" must be a 1-character string")
    return v


class _CsvDialect:
    # a validated set of format parameters (Python's _csv.Dialect): what
    # reader.dialect and get_dialect() return
    def __init__(self, delimiter, doublequote, escapechar, lineterminator, quotechar,
                 quoting, skipinitialspace, strict):
        self.delimiter = delimiter
        self.doublequote = doublequote
        self.escapechar = escapechar
        self.lineterminator = lineterminator
        self.quotechar = quotechar
        self.quoting = quoting
        self.skipinitialspace = skipinitialspace
        self.strict = strict

    def __repr__(self):
        return "<_csv.Dialect object>"


_PARAMS = ["delimiter", "doublequote", "escapechar", "lineterminator", "quotechar",
           "quoting", "skipinitialspace", "strict"]

_dialects = {}


def _make_dialect(dialect, kw):
    # dialect (a name, a Dialect class or instance, or None) with keyword
    # overrides -> a _CsvDialect, checked as Python checks it
    if isinstance(dialect, str):
        if dialect not in _dialects:
            raise Error("unknown dialect")
        dialect = _dialects[dialect]
    for k in kw:
        if k not in _PARAMS:
            raise TypeError("'" + k + "' is an invalid keyword argument for Dialect()")
    if dialect is not None and isinstance(dialect, _CsvDialect) and len(kw) == 0:
        return dialect
    var v = {}
    for name in _PARAMS:
        if name in kw:
            v[name] = kw[name]
        elif dialect is not None and hasattr(dialect, name):
            v[name] = getattr(dialect, name)
        else:
            v[name] = _UNSET
    var delimiter = _char_param("delimiter", v["delimiter"], ",", false)
    var doublequote = true if id(v["doublequote"]) == id(_UNSET) else bool(v["doublequote"])
    var escapechar = _char_param("escapechar", v["escapechar"], None, true)
    var lt = v["lineterminator"]
    if id(lt) == id(_UNSET):
        lt = "\r\n"
    elif lt is None:
        raise TypeError("lineterminator must be set")
    elif not isinstance(lt, str):
        raise TypeError("\"lineterminator\" must be a string")
    var quotechar = _char_param("quotechar", v["quotechar"], "\"", true)
    var quoting = v["quoting"]
    var quoting_given = id(quoting) != id(_UNSET)
    if not quoting_given:
        quoting = QUOTE_MINIMAL
    elif not isinstance(quoting, int) or isinstance(quoting, bool):
        raise TypeError("\"quoting\" must be an integer")
    if quoting < QUOTE_MINIMAL or quoting > QUOTE_NOTNULL:
        raise TypeError("bad \"quoting\" value")
    if quotechar is None and not quoting_given:
        quoting = QUOTE_NONE
    if quoting != QUOTE_NONE and quotechar is None:
        raise TypeError("quotechar must be set if quoting enabled")
    var sis = false if id(v["skipinitialspace"]) == id(_UNSET) else bool(v["skipinitialspace"])
    var strict = false if id(v["strict"]) == id(_UNSET) else bool(v["strict"])
    return _CsvDialect(delimiter, doublequote, escapechar, lt, quotechar, quoting, sis, strict)


class Dialect:
    # describe a CSV dialect by subclassing and setting the attributes
    _name = ""
    _valid = false
    delimiter = None
    quotechar = None
    escapechar = None
    doublequote = None
    skipinitialspace = None
    lineterminator = None
    quoting = None

    def __init__(self):
        if self.__class__.__name__ != "Dialect":
            self._valid = true
        self._validate()

    def _validate(self):
        try:
            _make_dialect(self, {})
        except TypeError as e:
            raise Error(str(e))


class excel(Dialect):
    delimiter = ","
    quotechar = "\""
    doublequote = true
    skipinitialspace = false
    lineterminator = "\r\n"
    quoting = QUOTE_MINIMAL


class excel_tab(excel):
    delimiter = "\t"


class unix_dialect(Dialect):
    delimiter = ","
    quotechar = "\""
    doublequote = true
    skipinitialspace = false
    lineterminator = "\n"
    quoting = QUOTE_ALL


def register_dialect(name, dialect=None, **fmtparams):
    if not isinstance(name, str):
        raise TypeError("dialect name must be a string")
    _dialects[name] = _make_dialect(dialect, fmtparams)


def unregister_dialect(name):
    if name not in _dialects:
        raise Error("unknown dialect")
    del _dialects[name]


def get_dialect(name):
    if name not in _dialects:
        raise Error("unknown dialect")
    return _dialects[name]


def list_dialects():
    return list(_dialects.keys())


register_dialect("excel", excel)
register_dialect("excel-tab", excel_tab)
register_dialect("unix", unix_dialect)


# ── reading ──────────────────────────────────────────────────────────────────
# parser states (_csv.c)
_START_RECORD = 0
_START_FIELD = 1
_ESCAPED_CHAR = 2
_IN_FIELD = 3
_IN_QUOTED_FIELD = 4
_ESCAPE_IN_QUOTED_FIELD = 5
_QUOTE_IN_QUOTED_FIELD = 6
_EAT_CRNL = 7
_AFTER_ESCAPED_CRNL = 8
_EOL = None


def _to_float(s):
    try:
        return float(s)
    except (ValueError, TypeError):
        raise ValueError("could not convert string to float: " + repr(s))


class _CsvReader:
    # csv.reader's iterator
    def __init__(self, f, dialect):
        self.dialect = dialect
        self.line_num = 0
        self._it = iter(f)
        self._fields = []
        self._field = []
        self._field_len = 0
        self._state = _START_RECORD
        self._numeric = false

    def __iter__(self):
        return self

    def _save_field(self):
        var s = "".join(self._field)
        self._field = []
        self._field_len = 0
        if self._numeric:
            self._numeric = false
            self._fields.append(_to_float(s))
        else:
            self._fields.append(s)

    def _add_char(self, c):
        if self._field_len >= _field_limit[0]:
            raise Error("field larger than field limit (" + str(_field_limit[0]) + ")")
        self._field.append(c)
        self._field_len = self._field_len + 1

    def _process(self, c):
        var d = self.dialect
        var st = self._state
        if st == _START_RECORD:
            if c is None:
                return
            if c == "\n" or c == "\r":
                self._state = _EAT_CRNL
                return
            st = _START_FIELD
            self._state = _START_FIELD
        if st == _START_FIELD:
            if c is None or c == "\n" or c == "\r":
                self._save_field()
                self._state = _START_RECORD if c is None else _EAT_CRNL
            elif c == d.quotechar and d.quoting != QUOTE_NONE:
                self._state = _IN_QUOTED_FIELD
            elif c == d.escapechar:
                self._state = _ESCAPED_CHAR
            elif c == " " and d.skipinitialspace:
                pass
            elif c == d.delimiter:
                self._save_field()
            else:
                if d.quoting == QUOTE_NONNUMERIC:
                    self._numeric = true
                self._add_char(c)
                self._state = _IN_FIELD
            return
        if st == _ESCAPED_CHAR:
            if c == "\n" or c == "\r":
                self._add_char(c)
                self._state = _AFTER_ESCAPED_CRNL
                return
            if c is None:
                c = "\n"
            self._add_char(c)
            self._state = _IN_FIELD
            return
        if st == _AFTER_ESCAPED_CRNL:
            if c is None:
                return
            st = _IN_FIELD
        if st == _IN_FIELD:
            if c is None or c == "\n" or c == "\r":
                self._save_field()
                self._state = _START_RECORD if c is None else _EAT_CRNL
            elif c == d.escapechar:
                self._state = _ESCAPED_CHAR
            elif c == d.delimiter:
                self._save_field()
                self._state = _START_FIELD
            else:
                # (the state stays: after an escaped line break, a line
                # end does not end the record until a delimiter or a
                # second line break has been seen - as _csv.c behaves)
                self._add_char(c)
            return
        if st == _IN_QUOTED_FIELD:
            if c is None:
                pass
            elif c == d.escapechar:
                self._state = _ESCAPE_IN_QUOTED_FIELD
            elif c == d.quotechar and d.quoting != QUOTE_NONE:
                if d.doublequote:
                    self._state = _QUOTE_IN_QUOTED_FIELD
                else:
                    self._state = _IN_FIELD
            else:
                self._add_char(c)
            return
        if st == _ESCAPE_IN_QUOTED_FIELD:
            if c is None:
                c = "\n"
            self._add_char(c)
            self._state = _IN_QUOTED_FIELD
            return
        if st == _QUOTE_IN_QUOTED_FIELD:
            if d.quoting != QUOTE_NONE and c == d.quotechar:
                self._add_char(c)
                self._state = _IN_QUOTED_FIELD
            elif c == d.delimiter:
                self._save_field()
                self._state = _START_FIELD
            elif c is None or c == "\n" or c == "\r":
                self._save_field()
                self._state = _START_RECORD if c is None else _EAT_CRNL
            elif not d.strict:
                self._add_char(c)
                self._state = _IN_FIELD
            else:
                raise Error("'" + d.delimiter + "' expected after '" + d.quotechar + "'")
            return
        if st == _EAT_CRNL:
            if c == "\n" or c == "\r":
                pass
            elif c is None:
                self._state = _START_RECORD
            else:
                raise Error("new-line character seen in unquoted field - do you need to open the file with newline=''?")

    def _fast_line(self, line):
        # the fields of a whole record on one line with no quote or escape
        # character and no line break inside: the state machine's result
        # without running it; None when the line needs the state machine
        var d = self.dialect
        if (d.quotechar is not None and d.quoting != QUOTE_NONE and d.quotechar in line) or (d.escapechar is not None and d.escapechar in line):
            return None
        if d.skipinitialspace and d.delimiter == " ":
            return None
        var body = line
        if body.endswith("\r\n"):
            body = body[:-2]
        elif body.endswith("\n") or body.endswith("\r"):
            body = body[:-1]
        if "\n" in body or "\r" in body:
            return None
        if body == "":
            return []
        var parts = body.split(d.delimiter)
        var limit = _field_limit[0]
        for k in range(len(parts)):
            var p = parts[k]
            if d.skipinitialspace:
                p = p.lstrip(" ")
                parts[k] = p
            if len(p) > limit:
                raise Error("field larger than field limit (" + str(limit) + ")")
            if d.quoting == QUOTE_NONNUMERIC and p != "":
                parts[k] = _to_float(p)
        return parts

    def __next__(self):
        self._fields = []
        self._field = []
        self._field_len = 0
        self._state = _START_RECORD
        self._numeric = false
        while true:
            var line = None
            try:
                line = next(self._it)
            except StopIteration:
                if self._field_len != 0 or self._state == _IN_QUOTED_FIELD:
                    if self.dialect.strict:
                        raise Error("unexpected end of data")
                    self._save_field()
                    break
                raise StopIteration
            if not isinstance(line, str):
                raise Error("iterator should return strings, not " + _tn(line) +
                            " (the file should be opened in text mode)")
            self.line_num = self.line_num + 1
            if self._state == _START_RECORD:
                var fast = self._fast_line(line)
                if fast is not None:
                    return fast
            for c in line:
                self._process(c)
            self._process(None)
            if self._state == _START_RECORD:
                break
        var fields = self._fields
        self._fields = []
        return fields


def reader(csvfile, dialect=None, **fmtparams):
    # (no dialect given means Python's defaults, not the "excel" entry: then
    # quotechar=None alone switches quoting off, as in _csv)
    if csvfile is None or isinstance(csvfile, (int, float, bool)):
        raise TypeError("'" + _tn(csvfile) + "' object is not iterable")
    try:
        iter(csvfile)
    except TypeError:
        raise TypeError("'" + _tn(csvfile) + "' object is not iterable")
    return _CsvReader(csvfile, _make_dialect(dialect, fmtparams))


# ── writing ──────────────────────────────────────────────────────────────────
def _is_number(x):
    # PyNumber_Check: ints, floats, complex, bools, and objects with
    # __index__ / __int__ / __float__
    if isinstance(x, (int, float, complex)):
        return true
    if isinstance(x, (str, bytes, bytearray, list, tuple, dict)) or x is None:
        return false
    return hasattr(x, "__index__") or hasattr(x, "__int__") or hasattr(x, "__float__")


class _CsvWriter:
    def __init__(self, f, dialect):
        self.dialect = dialect
        self._write = f.write
        var d = dialect
        # the characters that make a field need quoting (or escaping)
        var special = d.delimiter + "\n\r" + d.lineterminator
        if d.quotechar is not None:
            special = special + d.quotechar
        if d.escapechar is not None:
            special = special + d.escapechar
        self._special = special

    def _field_text(self, field, quoted):
        # one field as written: quoted when the quoting mode says so or
        # when it holds a special character; quotes doubled or escaped
        var d = self.dialect
        var s = field
        var special = false
        for c in self._special:
            if c in s:
                special = true
                break
        if not special:
            if quoted:
                return d.quotechar + s + d.quotechar
            return s
        var out = []
        for c in s:
            if c in self._special:
                var want_escape = false
                if d.quoting == QUOTE_NONE:
                    want_escape = true
                else:
                    if c == d.quotechar:
                        if d.doublequote:
                            out.append(d.quotechar)
                        else:
                            want_escape = true
                    elif c == d.escapechar:
                        want_escape = true
                    if not want_escape:
                        quoted = true
                if want_escape:
                    if d.escapechar is None:
                        raise Error("need to escape, but no escapechar set")
                    out.append(d.escapechar)
            out.append(c)
        if quoted:
            return d.quotechar + "".join(out) + d.quotechar
        return "".join(out)

    def writerow(self, row):
        var d = self.dialect
        try:
            iter(row)
        except TypeError:
            raise Error("iterable expected, not " + _tn(row))
        if isinstance(row, (int, float)) or row is None:
            raise Error("iterable expected, not " + _tn(row))
        var parts = []
        var reclen = 0
        for field in row:
            var quoted = false
            if d.quoting == QUOTE_NONNUMERIC:
                quoted = not _is_number(field)
            elif d.quoting == QUOTE_ALL:
                quoted = true
            elif d.quoting == QUOTE_STRINGS:
                quoted = isinstance(field, str)
            elif d.quoting == QUOTE_NOTNULL:
                quoted = field is not None
            var text = ""
            if field is None:
                text = ""
            elif isinstance(field, str):
                text = field
            elif isinstance(field, bool):
                text = "True" if field else "False"
            else:
                text = str(field)
            if text == "" and d.delimiter == " " and d.skipinitialspace:
                # an empty field between spaces would read back as nothing
                if d.quoting == QUOTE_NONE or (field is None and (d.quoting == QUOTE_STRINGS or d.quoting == QUOTE_NOTNULL)):
                    raise Error("empty field must be quoted if delimiter is a space and skipinitialspace is true")
                quoted = true
            var piece = self._field_text(text, quoted)
            parts.append(piece)
            reclen = reclen + len(piece)
        if len(parts) == 1 and reclen == 0:
            if d.quoting == QUOTE_NONE:
                raise Error("single empty field record must be quoted")
            parts = [d.quotechar + d.quotechar]
        return self._write(d.delimiter.join(parts) + d.lineterminator)

    def writerows(self, rows):
        for row in rows:
            self.writerow(row)


def writer(csvfile, dialect=None, **fmtparams):
    var d = _make_dialect(dialect, fmtparams)
    if not hasattr(csvfile, "write"):
        raise TypeError("argument 1 must have a \"write\" method")
    return _CsvWriter(csvfile, d)


# ── DictReader / DictWriter ──────────────────────────────────────────────────
class DictReader:
    def __init__(self, f, fieldnames=None, restkey=None, restval=None, dialect="excel", *args, **kwds):
        if fieldnames is not None and not isinstance(fieldnames, (list, tuple, str)):
            fieldnames = list(fieldnames)
        self._fieldnames = fieldnames
        self.restkey = restkey
        self.restval = restval
        self.reader = reader(f, dialect, *args, **kwds)
        self.dialect = dialect
        self.line_num = 0

    def __iter__(self):
        return self

    @property
    def fieldnames(self):
        if self._fieldnames is None:
            try:
                self._fieldnames = next(self.reader)
            except StopIteration:
                pass
        self.line_num = self.reader.line_num
        return self._fieldnames

    @fieldnames.setter
    def fieldnames(self, value):
        self._fieldnames = value

    def __next__(self):
        if self.line_num == 0:
            self.fieldnames
        var row = next(self.reader)
        self.line_num = self.reader.line_num
        while row == []:
            row = next(self.reader)
        var names = self.fieldnames
        var d = dict(zip(names, row))
        var lf = len(names)
        var lr = len(row)
        if lf < lr:
            d[self.restkey] = row[lf:]
        elif lf > lr:
            for key in names[lr:]:
                d[key] = self.restval
        return d


class DictWriter:
    def __init__(self, f, fieldnames, restval="", extrasaction="raise", dialect="excel", *args, **kwds):
        if fieldnames is not None and not isinstance(fieldnames, (list, tuple, str)):
            fieldnames = list(fieldnames)
        self.fieldnames = fieldnames
        self.restval = restval
        extrasaction = extrasaction.lower()
        if extrasaction not in ("raise", "ignore"):
            raise ValueError("extrasaction (" + extrasaction + ") must be 'raise' or 'ignore'")
        self.extrasaction = extrasaction
        self.writer = writer(f, dialect, *args, **kwds)

    def writeheader(self):
        var header = dict(zip(self.fieldnames, self.fieldnames))
        return self.writerow(header)

    def _dict_to_list(self, rowdict):
        if self.extrasaction == "raise":
            var wrong = []
            for k in rowdict.keys():
                if k not in self.fieldnames:
                    wrong.append(k)
            if wrong:
                raise ValueError("dict contains fields not in fieldnames: " + ", ".join([repr(x) for x in wrong]))
        return [rowdict.get(key, self.restval) for key in self.fieldnames]

    def writerow(self, rowdict):
        return self.writer.writerow(self._dict_to_list(rowdict))

    def writerows(self, rowdicts):
        return self.writer.writerows([self._dict_to_list(r) for r in rowdicts])


# ── Sniffer ──────────────────────────────────────────────────────────────────
def _is_wordch(c):
    return c == "_" or c.isalnum()


def _sniff_delim_char(c):
    # [^\w\n"']
    return c != "\n" and c != "\"" and c != "'" and not _is_wordch(c)


def _close_quote(data, q, start, after):
    # the first k >= start with data[k] == q and after(k + 1) true (the
    # lazy .*?(?P=quote) of Python's patterns), or -1
    var k = data.find(q, start)
    while k >= 0:
        if after(k + 1):
            return k
        k = data.find(q, k + 1)
    return -1


def _sniff_matches(data, which):
    # Sniffer's four regular expressions, findall()ed by hand: a list of
    # (quote, delim, space) for each match (delim/space None when the
    # pattern has no such group)
    var out = []
    var n = len(data)
    var i = 0
    while i < n:
        var m = None
        var mend = -1
        if which == 0 or which == 2:
            # (?P<delim>[^\w\n"'])(?P<space> ?)(?P<quote>["']).*?(?P=quote)<end>
            var dch = data[i]
            if _sniff_delim_char(dch):
                var sp = ""
                var qpos = i + 1
                if qpos < n and data[qpos] == " ":
                    sp = " "
                    qpos = qpos + 1
                if qpos < n and (data[qpos] == "\"" or data[qpos] == "'"):
                    var q = data[qpos]
                    var k = -1
                    if which == 0:
                        k = _close_quote(data, q, qpos + 1, lambda p: p < n and data[p] == dch)
                        if k >= 0:
                            mend = k + 2
                    else:
                        k = _close_quote(data, q, qpos + 1, lambda p: p >= n or data[p] == "\n")
                        if k >= 0:
                            mend = k + 1
                    if k >= 0:
                        m = (q, dch, sp)
        else:
            # (?:^|\n)(?P<quote>["']).*?(?P=quote)<end>
            var qp = -1
            if (i == 0 or data[i - 1] == "\n") and (data[i] == "\"" or data[i] == "'"):
                qp = i
            elif data[i] == "\n" and i + 1 < n and (data[i + 1] == "\"" or data[i + 1] == "'"):
                qp = i + 1
            if qp >= 0:
                var q2 = data[qp]
                if which == 1:
                    var k2 = _close_quote(data, q2, qp + 1, lambda p: p < n and _sniff_delim_char(data[p]))
                    if k2 >= 0:
                        var sp2 = " " if k2 + 2 < n and data[k2 + 2] == " " else ""
                        m = (q2, data[k2 + 1], sp2)
                        mend = k2 + 2 + len(sp2)
                else:
                    var k3 = _close_quote(data, q2, qp + 1, lambda p: p >= n or data[p] == "\n")
                    if k3 >= 0:
                        m = (q2, None, None)
                        mend = k3 + 1
        if m is not None:
            out.append(m)
            i = mend if mend > i else i + 1
        else:
            i = i + 1
    return out


def _has_doublequote(data, delim, quotechar):
    # Python's dq_regexp, approximately: a field (between delimiters, on
    # one line) that is quoted, possibly after and before non-word
    # characters, and has a quote inside
    for line in data.split("\n"):
        var fields = line.split(delim) if delim else [line]
        for f in fields:
            var a = f.find(quotechar)
            var b = f.rfind(quotechar)
            if a < 0 or f.count(quotechar) < 3:
                continue
            var ok = true
            for c in f[:a] + f[b + 1:]:
                if _is_wordch(c):
                    ok = false
                    break
            if ok:
                return true
    return false


class Sniffer:
    def __init__(self):
        self.preferred = [",", "\t", ";", " ", ":"]

    def sniff(self, sample, delimiters=None):
        var g = self._guess_quote_and_delimiter(sample, delimiters)
        var quotechar = g[0]
        var doublequote = g[1]
        var delimiter = g[2]
        var skipinitialspace = g[3]
        if not delimiter:
            var g2 = self._guess_delimiter(sample, delimiters)
            delimiter = g2[0]
            skipinitialspace = g2[1]
        if not delimiter:
            raise Error("Could not determine delimiter")

        class dialect(Dialect):
            _name = "sniffed"
            lineterminator = "\r\n"
            quoting = QUOTE_MINIMAL

        dialect.doublequote = doublequote
        dialect.delimiter = delimiter
        dialect.quotechar = quotechar or "\""
        dialect.skipinitialspace = skipinitialspace
        return dialect

    def _guess_quote_and_delimiter(self, data, delimiters):
        var matches = []
        for which in range(4):
            matches = _sniff_matches(data, which)
            if matches:
                break
        if not matches:
            return ("", false, None, 0)
        var quotes = {}
        var delims = {}
        var spaces = 0
        for m in matches:
            var key = m[0]
            if key:
                quotes[key] = quotes.get(key, 0) + 1
            if m[1] is None:
                continue
            key = m[1]
            if key and (delimiters is None or key in delimiters):
                delims[key] = delims.get(key, 0) + 1
            if m[2]:
                spaces = spaces + 1
        var quotechar = max(quotes, key=lambda k: quotes[k])
        var delim = ""
        var skipinitialspace = 0
        if delims:
            delim = max(delims, key=lambda k: delims[k])
            skipinitialspace = delims[delim] == spaces
            if delim == "\n":
                delim = ""
        return (quotechar, _has_doublequote(data, delim, quotechar), delim, skipinitialspace)

    def _guess_delimiter(self, data, delimiters):
        var lines = [ln for ln in data.split("\n") if ln]
        var ascii_chars = [chr(c) for c in range(127)]
        var chunkLength = min(10, len(lines))
        var iteration = 0
        var charFrequency = {}
        var modes = {}
        var delims = {}
        var start = 0
        var end = chunkLength
        while start < len(lines):
            iteration = iteration + 1
            for line in lines[start:end]:
                for char in ascii_chars:
                    var metaFrequency = charFrequency.get(char, {})
                    var freq = line.count(char)
                    metaFrequency[freq] = metaFrequency.get(freq, 0) + 1
                    charFrequency[char] = metaFrequency
            for char in charFrequency.keys():
                var items = list(charFrequency[char].items())
                if len(items) == 1 and items[0][0] == 0:
                    continue
                if len(items) > 1:
                    var best = items[0]
                    for it in items:
                        if it[1] > best[1]:
                            best = it
                    var rest = 0
                    var removed = false
                    for it in items:
                        if not removed and it[0] == best[0] and it[1] == best[1]:
                            removed = true
                            continue
                        rest = rest + it[1]
                    modes[char] = (best[0], best[1] - rest)
                else:
                    modes[char] = items[0]
            var total = float(min(chunkLength * iteration, len(lines)))
            var consistency = 1.0
            var threshold = 0.9
            while len(delims) == 0 and consistency >= threshold:
                for k in modes:
                    var v = modes[k]
                    if v[0] > 0 and v[1] > 0:
                        if (v[1] / total) >= consistency and (delimiters is None or k in delimiters):
                            delims[k] = v
                consistency = consistency - 0.01
            if len(delims) == 1:
                var delim = list(delims.keys())[0]
                return (delim, lines[0].count(delim) == lines[0].count(delim + " "))
            start = end
            end = end + chunkLength
        if not delims:
            return ("", 0)
        if len(delims) > 1:
            for d in self.preferred:
                if d in delims:
                    return (d, lines[0].count(d) == lines[0].count(d + " "))
        var pairs = sorted([(delims[k], k) for k in delims])
        var delim2 = pairs[-1][1]
        return (delim2, lines[0].count(delim2) == lines[0].count(delim2 + " "))

    def has_header(self, sample):
        var rdr = reader(_split_keepends(sample), self.sniff(sample))
        var header = next(rdr)
        var columns = len(header)
        var columnTypes = {}
        for i in range(columns):
            columnTypes[i] = None
        var checked = 0
        for row in rdr:
            if checked > 20:
                break
            checked = checked + 1
            if len(row) != columns:
                continue
            for col in list(columnTypes.keys()):
                var thisType = "complex"
                if not _is_complex_text(row[col]):
                    thisType = len(row[col])
                if thisType != columnTypes[col]:
                    if columnTypes[col] is None:
                        columnTypes[col] = thisType
                    else:
                        del columnTypes[col]
        var hasHeader = 0
        for col in columnTypes:
            var colType = columnTypes[col]
            if isinstance(colType, int):
                if len(header[col]) != colType:
                    hasHeader = hasHeader + 1
                else:
                    hasHeader = hasHeader - 1
            elif colType is None or not _is_complex_text(header[col]):
                hasHeader = hasHeader + 1
            else:
                hasHeader = hasHeader - 1
        return hasHeader > 0


def _is_complex_text(s):
    # would complex(s) succeed?
    try:
        float(s)
        return true
    except (ValueError, TypeError, OverflowError):
        pass
    try:
        complex(s)
        return true
    except Exception:
        return false


def _split_keepends(s):
    # io.StringIO(s)'s lines: split after each \n
    var out = []
    var start = 0
    var k = s.find("\n")
    while k >= 0:
        out.append(s[start:k + 1])
        start = k + 1
        k = s.find("\n", start)
    if start < len(s):
        out.append(s[start:])
    return out
