# nython: module    (import it by name: it runs in a module scope of its own)
# lib/tokenize.ny - Python's tokenize: Python source broken into tokens, as
# CPython 3.12's tokenizer gives them (round 83).
#
#     import tokenize, io
#     for t in tokenize.generate_tokens(io.StringIO(src).readline):
#         print(tokenize.tok_name[t.type], repr(t.string), t.start, t.end)
#
# generate_tokens(readline)   str lines -> TokenInfo(type, string, start,
#                             end, line); COMMENT and NL tokens included,
#                             every operator OP (TokenInfo.exact_type tells
#                             which), INDENT/DEDENT, NEWLINE ('' when the
#                             last line has no newline), ENDMARKER
# tokenize(readline)          bytes lines: an ENCODING token first, the
#                             source decoded by detect_encoding()'s answer
# detect_encoding(readline)   PEP 263 cookies and the UTF-8 BOM ('utf-8-sig'),
#                             CPython's SyntaxErrors ("unknown encoding: x",
#                             "encoding problem: utf-8")
# untokenize(iterable)        full 5-tuples: the source back exactly (as
#                             CPython's Untokenizer); 2-tuples: source that
#                             tokenizes to the same tokens
# open(filename)              a text file in its detected encoding
# TokenInfo, TokenError, StopTokenizing, the token module's constants
# (FSTRING_START 61, COMMENT 64, NL 65 ... - 3.12's numbers), tok_name,
# EXACT_TOKEN_TYPES; `nython -m tokenize [-e] [file.py]` prints the tokens
# as CPython's does.
#
# f-strings are tokenized as 3.12 does (PEP 701): FSTRING_START, then
# FSTRING_MIDDLE for the literal parts (a doubled brace ends a middle after
# its first brace, as CPython's C tokenizer reports it), the replacement
# fields as ordinary tokens - OP '{', the expression, OP '!' NAME for a
# conversion, OP ':' and the format spec's middles and nested fields, OP
# '}' - and FSTRING_END; f-strings nest.
#
# CPython 3.12 runs its C tokenizer; this one is written in Nython and
# follows its output (checked against python3.12 token by token on the
# round's corpus): the same tokens, positions, `line` attributes (every
# physical line a token spans), and the same TokenError / IndentationError
# messages for an unterminated string, EOF in a multi-line string or
# statement, an unindent that matches no outer level, invalid digits in a
# binary/octal/hex literal, leading zeros, and its TabError ("inconsistent
# use of tabs and spaces in indentation": the indentation measured with tabs
# of 8 and of 1 must agree), with 3.12's fields (the line without its
# newline, the offset past its end). Not here: the C tokenizer's warnings
# (invalid escape sequences, `1if`).
# Nython-only syntax (`a ?? b`, `1..5`, `${...}`) tokenizes as Python
# would see it (OP '?', ...).

import re
import sys
from codecs import lookup, BOM_UTF8
import collections
import itertools as _itertools
from token import *
from token import EXACT_TOKEN_TYPES
import token as _token

# the builtin open, kept before this module defines its own (CPython's
# `from builtins import open as _builtin_open`; run as `-m tokenize`, a
# later `import builtins` would see this module's open as the program's)
_builtin_open = open

__all__ = _token.__all__ + ["tokenize", "generate_tokens", "detect_encoding",
                            "untokenize", "TokenInfo"]

cookie_re = re.compile(r'^[ \t\f]*#.*?coding[:=][ \t]*([-\w.]+)', re.ASCII)
_blank_str_re = re.compile(r'^[ \t\f]*(?:[#\r\n]|$)', re.ASCII)

tabsize = 8


class TokenError(Exception): pass


class StopTokenizing(Exception): pass


_TokenInfoBase = collections.namedtuple('TokenInfo', 'type string start end line')


class TokenInfo(_TokenInfoBase):
    def __repr__(self):
        annotated_type = '%d (%s)' % (self.type, tok_name[self.type])
        return ('TokenInfo(type=%s, string=%r, start=%r, end=%r, line=%r)' %
                (annotated_type, self.string, self.start, self.end, self.line))

    @property
    def exact_type(self):
        if self.type == OP and self.string in EXACT_TOKEN_TYPES:
            return EXACT_TOKEN_TYPES[self.string]
        else:
            return self.type


def _make_token(t, s, start, end, line):
    return TokenInfo(t, s, start, end, line)


# ── the scanner ──────────────────────────────────────────────────────────────

_OPS3 = ('**=', '//=', '>>=', '<<=', '...', '!=', )
_OPS = sorted(EXACT_TOKEN_TYPES.keys(), key=lambda o: -len(o))
_STR_PREFIXES = ('r', 'u', 'b', 'br', 'rb', 'f', 'fr', 'rf')
_NUM_END_KEYWORDS = ('and', 'else', 'for', 'if', 'in', 'is', 'not', 'or')


def _is_id_start(c):
    return c == '_' or c.isalpha() or (ord(c) > 127 and (c + 'a').isidentifier())


def _is_id_char(c):
    return c == '_' or c.isalnum() or (ord(c) > 127 and ('a' + c).isidentifier())


class _Scanner:
    def __init__(self, lines):
        self.lines = lines
        self.text = "".join(lines)
        starts = []
        p = 0
        for l in lines:
            starts.append(p)
            p += len(l)
        self.starts = starts
        self.n = len(self.text)
        self.ri = 0

    def rc(self, pos):
        # (row, col) of a position: row 1-based, col the index in that line
        st = self.starts
        nl = len(st)
        if nl == 0:
            return (1, 0)
        if pos >= self.n and self.text.endswith("\n"):
            return (nl + 1, 0)
        i = self.ri
        if i >= nl:
            i = nl - 1
        while i > 0 and st[i] > pos:
            i -= 1
        while i + 1 < nl and st[i + 1] <= pos:
            i += 1
        self.ri = i
        return (i + 1, pos - st[i])

    def line_of(self, sr, er):
        if sr < 1 or sr > len(self.lines):
            return ''
        if er < sr:
            er = sr
        if er > len(self.lines):
            er = len(self.lines)
        if sr == er:
            return self.lines[sr - 1]
        return "".join(self.lines[sr - 1:er])


def _read_lines(readline):
    lines = []
    while True:
        try:
            l = readline()
        except StopIteration:
            l = ''
        if not l:
            break
        if not isinstance(l, str):
            raise TypeError("readline() returned a non-string object")
        lines.append(l)
    return lines


def _indent_error(cls, msg, S, row):
    # TabError / IndentationError as CPython 3.12's tokenizer gives them:
    # the line without its newline, the offset just past its end
    text = S.line_of(row, row).rstrip("\r\n")
    return cls(msg, ("<string>", row, len(text) + 1, text, None, None))


def _generate(lines):
    S = _Scanner(lines)
    text = S.text
    n = S.n
    indents = [0]
    altindents = [0]
    parenlev = 0
    continued = False
    pos = 0
    line_start = True        # at the start of a physical line
    stmt_tokens = False      # tokens seen on the current logical line
    # f-string states, innermost last: [kind, quote, triple, raw, depth]
    # kind 'lit' (literal text), 'expr' (a replacement field's expression),
    # 'spec' (its format spec)
    fstack = []
    nested_closed = False    # a nested field just closed inside a format spec

    def tok(t, s, a, b):
        sr, sc = S.rc(a)
        if t == NEWLINE or t == NL:
            # a newline ends on its own line, one past its last character
            return TokenInfo(t, s, (sr, sc), (sr, sc + len(s)), S.line_of(sr, sr))
        er, ec = S.rc(b)
        return TokenInfo(t, s, (sr, sc), (er, ec), S.line_of(sr, er))

    def err(msg, at, plus=1):
        var where = S.rc(at)
        raise TokenError(msg, (where[0], where[1] + plus))

    while True:
        # ── the start of a physical line ──
        if line_start and not fstack:
            line_start = False
            if pos >= n:
                break
            if parenlev == 0 and not continued:
                column = 0
                altcol = 0       # the column with tabs counted as 1 (the C tokenizer's)
                p = pos
                while p < n:
                    c = text[p]
                    if c == ' ':
                        column += 1
                        altcol += 1
                    elif c == '\t':
                        column = (column // tabsize + 1) * tabsize
                        altcol += 1
                    elif c == '\f':
                        column = 0
                        altcol = 0
                    else:
                        break
                    p += 1
                if p >= n:
                    # trailing whitespace with no newline
                    pos = p
                    break
                c = text[p]
                if c == '#' or c == '\r' or c == '\n':
                    # a comment-only or blank line: COMMENT? NL
                    if c == '#':
                        e = p
                        while e < n and text[e] != '\n' and text[e] != '\r':
                            e += 1
                        yield tok(COMMENT, text[p:e], p, e)
                        p = e
                    if p < n:
                        e = p + 1
                        if text[p] == '\r' and e < n and text[e] == '\n':
                            e += 1
                        yield tok(NL, text[p:e], p, e)
                        p = e
                    else:
                        yield tok(NL, '', p, p)
                    pos = p
                    line_start = True
                    continue
                def tab_error():
                    raise _indent_error(TabError, "inconsistent use of tabs and spaces in indentation",
                                        S, S.rc(p)[0])
                if column == indents[-1]:
                    if altcol != altindents[-1]:
                        tab_error()
                elif column > indents[-1]:
                    if altcol <= altindents[-1]:
                        tab_error()
                    indents.append(column)
                    altindents.append(altcol)
                    yield tok(INDENT, text[pos:p], pos, p)
                while column < indents[-1]:
                    if column not in indents:
                        raise _indent_error(IndentationError,
                                            "unindent does not match any outer indentation level",
                                            S, S.rc(p)[0])
                    indents.pop()
                    altindents.pop()
                    if column == indents[-1] and altcol != altindents[-1]:
                        tab_error()
                    yield tok(DEDENT, '', p, p)
                pos = p
            else:
                continued = False
        if pos >= n:
            break
        c = text[pos]

        # ── inside an f-string's literal text or format spec ──
        if fstack and fstack[-1][0] != 'expr':
            st = fstack[-1]
            kind, q, triple, raw = st[0], st[1], st[2], st[3]
            start = pos
            p = pos
            buf = ''
            ended = False
            while True:
                if p >= n:
                    if triple:
                        err("unterminated triple-quoted f-string literal (detected at line %d)" % S.rc(n)[0], st[5], 1)
                    err("unterminated f-string literal (detected at line %d)" % S.rc(n)[0], st[5], 1)
                ch = text[p]
                if kind == 'lit' and (text.startswith(q * 3, p) if triple else ch == q):
                    ended = True
                    break
                if kind == 'spec' and ch == q and not triple:
                    ended = True
                    break
                if ch == '\n' and not triple:
                    if kind == 'spec':
                        err("f-string: newlines are not allowed in format specifiers for single quoted f-strings", p, 1)
                    err("unterminated f-string literal (detected at line %d)" % S.rc(p)[0], st[5], 1)
                if ch == '\\' and not raw:
                    if p + 1 < n and text[p + 1] == 'N' and p + 2 < n and text[p + 2] == '{':
                        e = text.find('}', p + 3)
                        if e < 0:
                            e = n - 1
                        buf += text[p:e + 1]
                        p = e + 1
                        continue
                    if p + 1 < n and text[p + 1] not in '{}':
                        buf += text[p:p + 2]
                        p += 2
                        continue
                    buf += ch
                    p += 1
                    continue
                if ch == '\\' and raw:
                    if p + 1 < n and text[p + 1] not in '{}':
                        buf += text[p:p + 2]
                        p += 2
                        continue
                    buf += ch
                    p += 1
                    continue
                if ch == '{':
                    if kind == 'lit' and p + 1 < n and text[p + 1] == '{':
                        buf += '{'
                        yield tok(FSTRING_MIDDLE, buf, start, p + 1)
                        buf = ''
                        p += 2
                        start = p
                        continue
                    break
                if ch == '}':
                    if kind == 'lit' and p + 1 < n and text[p + 1] == '}':
                        buf += '}'
                        yield tok(FSTRING_MIDDLE, buf, start, p + 1)
                        buf = ''
                        p += 2
                        start = p
                        continue
                    if kind == 'lit':
                        err("f-string: single '}' is not allowed", p, 1)
                    break
                buf += ch
                p += 1
            if buf or (kind == 'spec' and nested_closed):
                yield tok(FSTRING_MIDDLE, buf, start, p)
            nested_closed = False
            pos = p
            if ended:
                if kind == 'spec':
                    err("f-string: expecting '}'", p, 1)
                e = p + (3 if triple else 1)
                yield tok(FSTRING_END, text[p:e], p, e)
                fstack.pop()
                pos = e
                stmt_tokens = True
                if fstack and fstack[-1][0] == 'spec':
                    nested_closed = True
                continue
            ch = text[pos]
            if ch == '{':
                yield tok(OP, '{', pos, pos + 1)
                pos += 1
                fstack.append(['expr', q, triple, raw, 0, st[5], kind])
                continue
            # '}' closing the replacement field of a format spec
            yield tok(OP, '}', pos, pos + 1)
            pos += 1
            fstack.pop()          # the spec
            fstack.pop()          # its field's expression
            if fstack and fstack[-1][0] == 'spec':
                nested_closed = True
            continue

        # ── whitespace ──
        if c == ' ' or c == '\t' or c == '\f':
            pos += 1
            continue
        # ── a comment ──
        if c == '#':
            if fstack:
                err("f-string expression part cannot include '#'", pos, 1)
            e = pos
            while e < n and text[e] != '\n' and text[e] != '\r':
                e += 1
            yield tok(COMMENT, text[pos:e], pos, e)
            pos = e
            continue
        # ── a newline ──
        if c == '\n' or c == '\r':
            e = pos + 1
            if c == '\r' and e < n and text[e] == '\n':
                e += 1
            if fstack:
                # inside a replacement field of a triple-quoted f-string
                st = fstack[-1]
                if not st[2]:
                    err("unterminated f-string literal (detected at line %d)" % S.rc(pos)[0], st[5], 1)
                yield tok(NL, text[pos:e], pos, e)
                pos = e
                continue
            if parenlev > 0 or not stmt_tokens:
                yield tok(NL, text[pos:e], pos, e)
            else:
                yield tok(NEWLINE, text[pos:e], pos, e)
                stmt_tokens = False
            pos = e
            line_start = True
            continue
        # ── a line continuation ──
        if c == '\\':
            e = pos + 1
            if e < n and text[e] == '\r':
                e += 1
            if e < n and text[e] == '\n':
                pos = e + 1
                if pos >= n:
                    err("unexpected EOF while parsing", pos, 0)
                continued = True
                line_start = True
                continue
            err("unexpected character after line continuation character", pos, 1)

        start = pos
        # ── a number ──
        if c.isdigit() or (c == '.' and pos + 1 < n and text[pos + 1].isdigit()):
            p = pos
            if c == '0' and p + 1 < n and text[p + 1] in 'xXoObB':
                base = text[p + 1].lower()
                digits = {'x': '0123456789abcdefABCDEF', 'o': '01234567', 'b': '01'}[base]
                name = {'x': 'hexadecimal', 'o': 'octal', 'b': 'binary'}[base]
                p += 2
                count = 0
                while p < n and (text[p] in digits or (text[p] == '_' and p + 1 < n and text[p + 1] in digits)):
                    if text[p] != '_':
                        count += 1
                    p += 1
                if p < n and (text[p].isdigit() or (base == 'x' and _is_id_char(text[p]) and False)):
                    err("invalid digit '%s' in %s literal" % (text[p], name), p, 1)
                if count == 0:
                    err("invalid %s literal" % name, p, 1)
            else:
                def digitpart(p):
                    while p < n and (text[p].isdigit() or (text[p] == '_' and p + 1 < n and text[p + 1].isdigit())):
                        p += 1
                    return p
                is_float = False
                if c == '.':
                    p = digitpart(p + 1)
                    is_float = True
                else:
                    p = digitpart(p)
                    if p < n and text[p] == '.':
                        p = digitpart(p + 1)
                        is_float = True
                if p < n and text[p] in 'eE':
                    q = p + 1
                    if q < n and text[q] in '+-':
                        q += 1
                    if q < n and text[q].isdigit():
                        p = digitpart(q)
                        is_float = True
                    else:
                        err("invalid decimal literal", p, 1)
                if p < n and text[p] in 'jJ':
                    p += 1
                elif not is_float:
                    s0 = text[start:p].replace('_', '')
                    if len(s0) > 1 and s0[0] == '0' and s0.strip('0') != '':
                        err("leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers", start, 1)
            if p < n and _is_id_start(text[p]):
                ok = False
                for kw in _NUM_END_KEYWORDS:
                    if text.startswith(kw, p):
                        ok = True
                        break
                if not ok:
                    err("invalid decimal literal", p, 1)
            yield tok(NUMBER, text[start:p], start, p)
            stmt_tokens = True
            pos = p
            continue
        # ── a name, or a string's prefix ──
        if _is_id_start(c):
            p = pos + 1
            while p < n and _is_id_char(text[p]):
                p += 1
            word = text[pos:p]
            if p < n and (text[p] == '"' or text[p] == "'") and word.lower() in _STR_PREFIXES:
                c = text[p]
                prefix = word
                pos = p
            else:
                yield tok(NAME, word, start, p)
                stmt_tokens = True
                pos = p
                continue
        else:
            prefix = ''
        # ── a string ──
        if c == '"' or c == "'":
            q = c
            triple = text.startswith(q * 3, pos)
            lo = prefix.lower()
            raw = 'r' in lo
            if 'f' in lo:
                e = pos + (3 if triple else 1)
                yield tok(FSTRING_START, text[start:e], start, e)
                stmt_tokens = True
                fstack.append(['lit', q, triple, raw, 0, start])
                pos = e
                continue
            p = pos + (3 if triple else 1)
            while True:
                if p >= n:
                    if triple:
                        err("unterminated triple-quoted string literal (detected at line %d)" % S.rc(n)[0], start, 1)
                    if fstack:
                        err("f-string: expecting '}'", start, 1)
                    err("unterminated string literal (detected at line %d)" % S.rc(start)[0], start, 1)
                ch = text[p]
                if ch == '\\':
                    p += 2
                    continue
                if triple:
                    if text.startswith(q * 3, p):
                        p += 3
                        break
                elif ch == q:
                    p += 1
                    break
                elif ch == '\n':
                    if fstack:
                        err("f-string: expecting '}'", start, 1)
                    err("unterminated string literal (detected at line %d)" % S.rc(start)[0], start, 1)
                p += 1
            yield tok(STRING, text[start:p], start, p)
            stmt_tokens = True
            pos = p
            continue
        # ── inside a replacement field: what ends its expression ──
        if fstack:
            st = fstack[-1]
            if st[4] == 0:
                if c == '}':
                    yield tok(OP, '}', pos, pos + 1)
                    pos += 1
                    fstack.pop()
                    if fstack and fstack[-1][0] == 'spec':
                        nested_closed = True
                    continue
                if c == '!' and not text.startswith('!=', pos):
                    yield tok(OP, '!', pos, pos + 1)
                    pos += 1
                    continue
                if c == ':':
                    yield tok(OP, ':', pos, pos + 1)
                    pos += 1
                    fstack.append(['spec', st[1], st[2], st[3], 0, st[5]])
                    nested_closed = False
                    continue
        # ── an operator ──
        op = None
        for o in _OPS:
            if text.startswith(o, pos):
                op = o
                break
        if op is None:
            if ord(c) < 128 and c.isprintable():
                op = c
            else:
                err("invalid character '%s' (U+%04X)" % (c, ord(c)), pos, 1)
        e = pos + len(op)
        if op in '([{':
            if fstack:
                fstack[-1][4] += 1
            else:
                parenlev += 1
        elif op in ')]}':
            if fstack:
                fstack[-1][4] -= 1
            elif parenlev > 0:
                parenlev -= 1
            else:
                err("unmatched '%s'" % op, pos, 1)
        yield tok(OP, op, pos, e)
        stmt_tokens = True
        pos = e

    # ── the end of the input ──
    if fstack:
        st = fstack[-1]
        if st[2]:
            err("unterminated triple-quoted f-string literal (detected at line %d)" % S.rc(n)[0], st[5], 1)
        err("unterminated f-string literal (detected at line %d)" % S.rc(n)[0], st[5], 1)
    if continued or parenlev > 0:
        r = len(lines)
        raise TokenError("unexpected EOF in multi-line statement", (r, 0))
    if stmt_tokens:
        # the last line has no newline: an empty NEWLINE after it
        r, cc = S.rc(n)
        yield TokenInfo(NEWLINE, '', (r, cc), (r, cc + 1), S.line_of(r, r))
    last = len(lines) + 1
    for _ in indents[1:]:
        yield TokenInfo(DEDENT, '', (last, 0), (last, 0), '')
    yield TokenInfo(ENDMARKER, '', (last, 0), (last, 0), '')


def _generate_tokens_from_lines(lines):
    try:
        yield from _generate(lines)
    except TokenError as e:
        raise TokenError(_transform_msg(e.args[0]), e.args[1])


def _transform_msg(msg):
    """Transform error messages from the C tokenizer into the Python tokenize

    The C tokenizer is more picky than the Python one, so we need to massage
    the error messages a bit for backwards compatibility.
    """
    if "unterminated triple-quoted string literal" in msg:
        return "EOF in multi-line string"
    return msg


# ── untokenize (CPython's Untokenizer) ───────────────────────────────────────

class Untokenizer:

    def __init__(self):
        self.tokens = []
        self.prev_row = 1
        self.prev_col = 0
        self.prev_type = None
        self.encoding = None

    def add_whitespace(self, start):
        row, col = start
        if row < self.prev_row or row == self.prev_row and col < self.prev_col:
            raise ValueError("start ({},{}) precedes previous end ({},{})"
                             .format(row, col, self.prev_row, self.prev_col))
        row_offset = row - self.prev_row
        if row_offset:
            self.tokens.append("\\\n" * row_offset)
            self.prev_col = 0
        col_offset = col - self.prev_col
        if col_offset:
            self.tokens.append(" " * col_offset)

    def escape_brackets(self, token):
        characters = []
        consume_until_next_bracket = False
        for character in token:
            if character == "}":
                if consume_until_next_bracket:
                    consume_until_next_bracket = False
                else:
                    characters.append(character)
            if character == "{":
                n_backslashes = 0
                k = len(characters) - 2
                while k >= 0 and characters[k] == "\\":
                    n_backslashes += 1
                    k -= 1
                if n_backslashes % 2 == 0:
                    characters.append(character)
                else:
                    consume_until_next_bracket = True
            characters.append(character)
        return "".join(characters)

    def untokenize(self, iterable):
        it = iter(iterable)
        indents = []
        startline = False
        for t in it:
            if len(t) == 2:
                self.compat(t, it)
                break
            tok_type, token, start, end, line = t
            if tok_type == ENCODING:
                self.encoding = token
                continue
            if tok_type == ENDMARKER:
                break
            if tok_type == INDENT:
                indents.append(token)
                continue
            elif tok_type == DEDENT:
                indents.pop()
                self.prev_row, self.prev_col = end
                continue
            elif tok_type in (NEWLINE, NL):
                startline = True
            elif startline and indents:
                indent = indents[-1]
                if start[1] >= len(indent):
                    self.tokens.append(indent)
                    self.prev_col = len(indent)
                startline = False
            elif tok_type == FSTRING_MIDDLE:
                if '{' in token or '}' in token:
                    token = self.escape_brackets(token)
                    last_line = token.splitlines()[-1]
                    end_line, end_col = end
                    extra_chars = last_line.count("{{") + last_line.count("}}")
                    end = (end_line, end_col + extra_chars)
            elif tok_type in (STRING, FSTRING_START) and self.prev_type in (STRING, FSTRING_END):
                self.tokens.append(" ")

            self.add_whitespace(start)
            self.tokens.append(token)
            self.prev_row, self.prev_col = end
            if tok_type in (NEWLINE, NL):
                self.prev_row += 1
                self.prev_col = 0
            self.prev_type = tok_type
        return "".join(self.tokens)

    def compat(self, token, iterable):
        indents = []
        toks_append = self.tokens.append
        startline = token[0] in (NEWLINE, NL)
        prevstring = False
        in_fstring = 0

        for tok in _itertools.chain([token], iterable):
            toknum, tokval = tok[:2]
            if toknum == ENCODING:
                self.encoding = tokval
                continue

            if toknum in (NAME, NUMBER):
                tokval += ' '

            # Insert a space between two consecutive strings
            if toknum == STRING:
                if prevstring:
                    tokval = ' ' + tokval
                prevstring = True
            else:
                prevstring = False

            if toknum == FSTRING_START:
                in_fstring += 1
            elif toknum == FSTRING_END:
                in_fstring -= 1
            if toknum == INDENT:
                indents.append(tokval)
                continue
            elif toknum == DEDENT:
                indents.pop()
                continue
            elif toknum in (NEWLINE, NL):
                startline = True
            elif startline and indents:
                toks_append(indents[-1])
                startline = False
            elif toknum == FSTRING_MIDDLE:
                tokval = self.escape_brackets(tokval)

            # Insert a space between two consecutive brackets if we are in an f-string
            if tokval in {"{", "}"} and self.tokens and self.tokens[-1] == tokval and in_fstring:
                tokval = ' ' + tokval

            # Insert a space between two consecutive f-strings
            if toknum in (STRING, FSTRING_START) and self.prev_type in (STRING, FSTRING_END):
                self.tokens.append(" ")

            toks_append(tokval)
            self.prev_type = toknum


def untokenize(iterable):
    """Transform tokens back into Python source code.
    It returns a bytes object, encoded using the ENCODING
    token, which is the first token sequence output by tokenize.

    Each element returned by the iterable must be a token sequence
    with at least two elements, a token number and token value.  If
    only two tokens are passed, the resulting output is poor.
    """
    ut = Untokenizer()
    out = ut.untokenize(iterable)
    if ut.encoding is not None:
        out = out.encode(ut.encoding)
    return out


# ── encodings (PEP 263) ──────────────────────────────────────────────────────

def _get_normal_name(orig_enc):
    """Imitates get_normal_name in tokenizer.c."""
    # Only care about the first 12 characters.
    enc = orig_enc[:12].lower().replace("_", "-")
    if enc == "utf-8" or enc.startswith("utf-8-"):
        return "utf-8"
    if enc in ("latin-1", "iso-8859-1", "iso-latin-1") or \
       enc.startswith(("latin-1-", "iso-8859-1-", "iso-latin-1-")):
        return "iso-8859-1"
    return orig_enc


def detect_encoding(readline):
    """
    The detect_encoding() function is used to detect the encoding that should
    be used to decode a Python source file.  It requires one argument, readline,
    in the same way as the tokenize() generator.

    It will call readline a maximum of twice, and return the encoding used
    (as a string) and a list of any lines (left as bytes) it has read in.
    """
    filename = getattr(getattr(readline, '__self__', None), 'name', None)
    bom_found = False
    encoding = None
    default = 'utf-8'

    def read_or_stop():
        try:
            return readline()
        except StopIteration:
            return b''

    def find_cookie(line):
        try:
            # Decode as UTF-8. Either the line is an encoding declaration,
            # in which case it should be pure ASCII, or it must be UTF-8
            # per default encoding.
            line_string = line.decode('utf-8')
        except UnicodeDecodeError:
            msg = "invalid or missing encoding declaration"
            if filename is not None:
                msg = '{} for {!r}'.format(msg, filename)
            raise SyntaxError(msg)

        match = cookie_re.match(line_string)
        if not match:
            return None
        var encoding = _get_normal_name(match.group(1))
        try:
            codec = lookup(encoding)
        except LookupError:
            # This behaviour mimics the Python interpreter
            if filename is None:
                msg = "unknown encoding: " + encoding
            else:
                msg = "unknown encoding for {!r}: {}".format(filename,
                        encoding)
            raise SyntaxError(msg)

        if bom_found:
            if encoding != 'utf-8':
                # This behaviour mimics the Python interpreter
                if filename is None:
                    msg = 'encoding problem: utf-8'
                else:
                    msg = 'encoding problem for {!r}: utf-8'.format(filename)
                raise SyntaxError(msg)
            encoding += '-sig'
        return encoding

    first = read_or_stop()
    if first.startswith(BOM_UTF8):
        bom_found = True
        first = first[3:]
        default = 'utf-8-sig'
    if not first:
        return default, []

    encoding = find_cookie(first)
    if encoding:
        return encoding, [first]
    if not _blank_str_re.match(first.decode('latin-1')):
        return default, [first]

    second = read_or_stop()
    if not second:
        return default, [first]

    encoding = find_cookie(second)
    if encoding:
        return encoding, [first, second]

    return default, [first, second]


def open(filename):
    """Open a file in read only mode using the encoding detected by
    detect_encoding().
    """
    import io
    buffer = _builtin_open(filename, 'rb')
    try:
        encoding, lines = detect_encoding(buffer.readline)
        buffer.seek(0)
        data = buffer.read()
        buffer.close()
        if encoding == 'utf-8-sig' and data.startswith(BOM_UTF8):
            data = data[3:]
            encoding = 'utf-8'
        text = io.StringIO(data.decode(encoding))
        text.name = filename
        text.mode = 'r'
        text.encoding = encoding
        return text
    except:
        buffer.close()
        raise


def tokenize(readline):
    """
    The tokenize() generator requires one argument, readline, which
    must be a callable object which provides the same interface as the
    readline() method of built-in file objects.  Each call to the function
    should return one line of input as bytes.

    The first token sequence will always be an ENCODING token
    which tells you which encoding was used to decode the bytes stream.
    """
    encoding, consumed = detect_encoding(readline)
    raw = list(consumed)
    while True:
        try:
            l = readline()
        except StopIteration:
            l = b''
        if not l:
            break
        raw.append(l)
    if encoding is not None:
        if encoding == "utf-8-sig":
            # BOM will already have been stripped.
            encoding = "utf-8"
        yield TokenInfo(ENCODING, encoding, (0, 0), (0, 0), '')
    lines = []
    for b in raw:
        lines.append(b.decode(encoding or 'utf-8'))
    yield from _generate_tokens_from_lines(lines)


def generate_tokens(readline):
    """Tokenize a source reading Python code as unicode strings.

    This has the same API as tokenize(), except that it expects the *readline*
    callable to return str objects instead of bytes.
    """
    return _generate_tokens_from_lines(_read_lines(readline))


def main():
    import argparse

    # Helper error handling routines
    def perror(message):
        sys.stderr.write(message)
        sys.stderr.write('\n')

    def error(message, filename=None, location=None):
        if location:
            var fields = (filename,) + location + (message,)
            perror("%s:%d:%d: error: %s" % fields)
        elif filename:
            perror("%s: error: %s" % (filename, message))
        else:
            perror("error: %s" % message)
        sys.exit(1)

    # Parse the arguments and options
    parser = argparse.ArgumentParser(prog='python -m tokenize')
    parser.add_argument(dest='filename', nargs='?',
                        metavar='filename.py',
                        help='the file to tokenize; defaults to stdin')
    parser.add_argument('-e', '--exact', dest='exact', action='store_true',
                        help='display token names using the exact type')
    args = parser.parse_args()

    try:
        # Tokenize the input
        if args.filename:
            filename = args.filename
            with _builtin_open(filename, 'rb') as f:
                tokens = list(tokenize(f.readline))
        else:
            filename = "<stdin>"
            tokens = generate_tokens(sys.stdin.readline)

        # Output the tokenization
        for token in tokens:
            token_type = token.type
            if args.exact:
                token_type = token.exact_type
            token_range = "%d,%d-%d,%d:" % (token.start + token.end)
            print("%-20s%-15s%-15r" %
                  (token_range, tok_name[token_type], token.string))
    except IndentationError as err:
        line, column = err.args[1][1:3]
        error(err.args[0], filename, (line, column))
    except TokenError as err:
        line, column = err.args[1]
        error(err.args[0], filename, (line, column))
    except SyntaxError as err:
        error(err, filename)
    except OSError as err:
        error(err)
    except KeyboardInterrupt:
        print("interrupted\n")


if __name__ == "__main__":
    main()
