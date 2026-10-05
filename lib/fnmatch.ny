# nython: module    (import it by name: it runs in a module scope of its own)
# lib/fnmatch.ny - Python's fnmatch: Unix shell-style wildcards.
#
#     fnmatch(name, pat)       match after os.path.normcase on both (case-
#                              insensitive with "/" == "\" on Windows)
#     fnmatchcase(name, pat)   match exactly as written
#     filter(names, pat)       the names that match
#     translate(pat)           the regular expression text CPython produces
#                              ("(?s:.*\.txt)\Z"), character for character
#
#     *  any run of characters (also "/" and newlines)    ?  one character
#     [seq] one of seq, with ranges (a-z)    [!seq] one character not in seq
#     a "[" without its "]" is an ordinary character
#
# Not built on a regular-expression engine: a pattern compiles once (cached,
# as CPython's lru_cache) into segments of fixed width separated by "*"; the
# first must match at the start and the last at the end, and each middle one
# is found leftmost with str.find on its literal head - the same matches the
# atomic groups in translate()'s regex give, in linear time per candidate.
# Bracket expressions follow CPython's rules exactly: a "-" first or last is
# literal, a descending range like [z-a] is dropped, [!] matches any
# character and [] (an unclosed one) is literal text.
# bytes patterns and names are matched through latin-1, as CPython does.

import os

__all__ = ["filter", "fnmatch", "fnmatchcase", "translate"]

_WINDOWS = os_platform() == "windows"
_cache = {}
_CACHE_MAX = 32768

# Token kinds of a compiled pattern.
_LIT = 0       # [0, text]          a run of literal characters
_ANY = 1       # [1, none]          ?
_STAR = 2      # [2, none]          *
_SET = 3       # [3, [negate, ranges]]  ranges: [[lo, hi], ...] (characters)
_NEVER = 4     # [4, none]          an empty set: never matches

_RE_SPECIAL = "()[]{}?*+-|^$\\.&~# \t\n\r\v\f"


def _normcase(s):
    if _WINDOWS:
        return s.replace("/", "\\").lower()
    return s


def _to_str(x):
    if isinstance(x, bytes) or isinstance(x, bytearray):
        return x.decode("latin-1")
    return x


def _re_escape(c):
    if c in _RE_SPECIAL:
        return "\\" + c
    return c


# The body of a bracket expression as CPython builds it for the regex
# (backslashes, set-operation characters and inner range hyphens escaped),
# or "" for an empty set and "!" for "any character". `i` is the index just
# after "[", `j` the index of the closing "]".
def _bracket_body(pat, i, j):
    var stuff = pat[i:j]
    if "-" not in stuff:
        stuff = stuff.replace("\\", "\\\\")
    else:
        var chunks = []
        var k = i + 2 if pat[i] == "!" else i + 1
        while true:
            k = pat.find("-", k, j)
            if k < 0:
                break
            chunks.append(pat[i:k])
            i = k + 1
            k = k + 3
        var chunk = pat[i:j]
        if chunk:
            chunks.append(chunk)
        else:
            chunks[-1] = chunks[-1] + "-"
        # Remove empty ranges (invalid in a regex).
        var m = len(chunks) - 1
        while m > 0:
            if chunks[m - 1][-1] > chunks[m][0]:
                chunks[m - 1] = chunks[m - 1][:-1] + chunks[m][1:]
                del chunks[m]
            m = m - 1
        var esc = []
        for s in chunks:
            esc.append(s.replace("\\", "\\\\").replace("-", "\\-"))
        stuff = "-".join(esc)
    # Escape set operations (&&, ~~ and ||).
    var out = []
    for ch in stuff:
        if ch == "&" or ch == "~" or ch == "|":
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)


# The ranges a regex class body (as _bracket_body makes it) denotes.
def _class_ranges(body):
    var atoms = []          # [char, is_range_hyphen]
    var n = len(body)
    var p = 0
    while p < n:
        var ch = body[p]
        if ch == "\\" and p + 1 < n:
            atoms.append([body[p + 1], false])
            p = p + 2
        else:
            atoms.append([ch, ch == "-"])
            p = p + 1
    var ranges = []
    var q = 0
    var na = len(atoms)
    while q < na:
        var lo = atoms[q][0]
        if q + 2 < na and atoms[q + 1][1]:
            var hi = atoms[q + 2][0]
            if lo <= hi:
                ranges.append([lo, hi])
            q = q + 3
        else:
            ranges.append([lo, lo])
            q = q + 1
    return ranges


# Pattern -> parts as CPython's fnmatch._translate makes them (regex text,
# with none for "*"), and the matcher's tokens.
def _parse(pat):
    var parts = []
    var toks = []
    var i = 0
    var n = len(pat)
    var lit = []
    while i < n:
        var c = pat[i]
        i = i + 1
        if c == "*":
            if len(lit) > 0:
                toks.append([_LIT, "".join(lit)])
                lit = []
            if len(parts) == 0 or parts[-1] is not none:
                parts.append(none)
                toks.append([_STAR, none])
        elif c == "?":
            if len(lit) > 0:
                toks.append([_LIT, "".join(lit)])
                lit = []
            parts.append(".")
            toks.append([_ANY, none])
        elif c == "[":
            var j = i
            if j < n and pat[j] == "!":
                j = j + 1
            if j < n and pat[j] == "]":
                j = j + 1
            while j < n and pat[j] != "]":
                j = j + 1
            if j >= n:
                parts.append("\\[")
                lit.append("[")
            else:
                var stuff = _bracket_body(pat, i, j)
                i = j + 1
                if len(lit) > 0:
                    toks.append([_LIT, "".join(lit)])
                    lit = []
                if stuff == "":
                    parts.append("(?!)")
                    toks.append([_NEVER, none])
                elif stuff == "!":
                    parts.append(".")
                    toks.append([_ANY, none])
                else:
                    var neg = false
                    if stuff[0] == "!":
                        neg = true
                        stuff = "^" + stuff[1:]
                    elif stuff[0] == "^" or stuff[0] == "[":
                        stuff = "\\" + stuff
                    parts.append("[" + stuff + "]")
                    toks.append([_SET, [neg, _class_ranges(stuff[1:] if neg else stuff)]])
        else:
            parts.append(_re_escape(c))
            lit.append(c)
    if len(lit) > 0:
        toks.append([_LIT, "".join(lit)])
    return [parts, toks]


# Tokens -> [segments, has_star]: segments split at "*", each
# [tokens, width] with every token one character wide (literal runs their
# length).
def _compile(pat):
    var c = _cache.get(pat)
    if c is not none:
        return c
    var toks = _parse(pat)[1]
    var segs = []
    var cur = []
    var width = 0
    var star = false
    for t in toks:
        if t[0] == _STAR:
            segs.append([cur, width])
            cur = []
            width = 0
            star = true
        else:
            cur.append(t)
            width = width + (len(t[1]) if t[0] == _LIT else 1)
    segs.append([cur, width])
    c = [segs, star]
    if len(_cache) >= _CACHE_MAX:
        _cache.clear()
    _cache[pat] = c
    return c


def _in_set(spec, ch):
    var hit = false
    for r in spec[1]:
        if r[0] <= ch and ch <= r[1]:
            hit = true
            break
    return hit != spec[0]


# Does segment `seg` match `s` at position `pos` (its width already fits)?
def _seg_at(seg, s, pos):
    for t in seg[0]:
        var k = t[0]
        if k == _LIT:
            if not s.startswith(t[1], pos):
                return false
            pos = pos + len(t[1])
        elif k == _ANY:
            pos = pos + 1
        elif k == _SET:
            if not _in_set(t[1], s[pos]):
                return false
            pos = pos + 1
        else:
            return false
    return true


def _match(s, pat):
    var c = _compile(pat)
    var segs = c[0]
    var n = len(s)
    var first = segs[0]
    if not c[1]:
        return first[1] == n and _seg_at(first, s, 0)
    var last = segs[-1]
    if first[1] + last[1] > n:
        return false
    if not _seg_at(first, s, 0):
        return false
    var end = n - last[1]
    if not _seg_at(last, s, end):
        return false
    var pos = first[1]
    var k = 1
    var nsegs = len(segs) - 1
    while k < nsegs:
        var seg = segs[k]
        var w = seg[1]
        var head = seg[0][0] if len(seg[0]) > 0 else none
        var found = false
        while pos + w <= end:
            if head is not none and head[0] == _LIT:
                var at = s.find(head[1], pos)
                if at < 0 or at + w > end:
                    return false
                pos = at
            if _seg_at(seg, s, pos):
                found = true
                break
            pos = pos + 1
        if not found:
            return false
        pos = pos + w
        k = k + 1
    return true


def _check_types(name, pat):
    var nb = isinstance(name, bytes) or isinstance(name, bytearray)
    var pb = isinstance(pat, bytes) or isinstance(pat, bytearray)
    if nb != pb:
        if pb:
            raise TypeError("cannot use a bytes pattern on a string-like object")
        raise TypeError("cannot use a string pattern on a bytes-like object")


def fnmatchcase(name, pat):
    """Test whether FILENAME matches PATTERN, including case."""
    _check_types(name, pat)
    return _match(_to_str(name), _to_str(pat))


def fnmatch(name, pat):
    """Test whether FILENAME matches PATTERN (both through os.path.normcase)."""
    _check_types(name, pat)
    return _match(_normcase(_to_str(name)), _normcase(_to_str(pat)))


def filter(names, pat):
    """Construct a list from those elements of the iterable NAMES that match PAT."""
    var result = []
    var p = _normcase(_to_str(pat))
    for name in names:
        _check_types(name, pat)
        if _match(_normcase(_to_str(name)), p):
            result.append(name)
    return result


def translate(pat):
    """Translate a shell PATTERN to a regular expression (CPython's text)."""
    var parts = _parse(pat)[0]
    var res = []
    var i = 0
    var n = len(parts)
    while i < n and parts[i] is not none:
        res.append(parts[i])
        i = i + 1
    while i < n:
        i = i + 1
        if i == n:
            res.append(".*")
            break
        var fixed = []
        while i < n and parts[i] is not none:
            fixed.append(parts[i])
            i = i + 1
        var f = "".join(fixed)
        if i == n:
            res.append(".*")
            res.append(f)
        else:
            res.append("(?>.*?" + f + ")")
    return "(?s:" + "".join(res) + ")\\Z"
