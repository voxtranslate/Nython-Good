# nython: module    (import it by name: it runs in a module scope of its own)
# lib/re.ny - Python's re (round 77): regular expressions.
#
#     import re
#     m = re.search(r"(?P<key>\w+)\s*=\s*(\d+)", line)
#     if m: print(m["key"], int(m.group(2)))
#
# compile search match fullmatch split findall finditer sub subn escape purge
# error (PatternError), the flags A ASCII I IGNORECASE L LOCALE M MULTILINE
# S DOTALL X VERBOSE U UNICODE T TEMPLATE DEBUG NOFLAG (and RegexFlag),
# Pattern and Match objects - Python 3.12's API, syntax, results and error
# messages, on both engines.
#
# The engine is native (src/builtins/nyre.cpp, include/NyRe.hpp): Python's
# parser ported line by line, compiled to a small program for a backtracking
# matcher with an explicit stack, so a 1 MB subject or deep nesting cannot
# overflow, and with SELECTIVE MEMOIZATION of the states that can be reached
# twice: a pattern without backreferences runs in O(pattern x subject), so the
# classic catastrophic cases - re.match("(a|aa)*c", "a" * 5000),
# re.match("(x+x+)+y", "x" * 5000) - fail at once instead of running for
# years, with exactly the leftmost-first results Python's sre gives. A literal
# prefix, a first-character set and \A / ^ anchoring skip hopeless start
# positions; long subjects are matched with the GIL released. Compiled
# programs are cached natively (512, least recently used out), and so are
# Pattern objects here, as Python does.
#
# Differs from Python:
#   * the flags are plain ints (re.I == 2, re.I | re.M == 10, as Python's
#     values) - repr(re.I) is "2", not "re.IGNORECASE";
#   * \N{NAME} escapes are refused (no Unicode name database); re.L is
#     accepted for bytes and behaves as re.A (ASCII), as on a C locale;
#   * Unicode tables are those of the Python that generated them
#     (tools/gen_re_tables.py), case folding is sre's (simple lower case plus
#     its extra equivalences: s/ſ, k/K-sign, the Greek symbol forms ...);
#   * a group captured inside a negative lookaround is always unset after it
#     (sre can leak one in some nested possessive repeats - a sre bug, like
#     its "span of capturing group is wrong" SystemError);
#   * with a backreference or a (?(group)...) conditional, the part of the
#     pattern that leads to it is not memoized (its outcome depends on the
#     captures), so it can backtrack exponentially - as it does in Python;
#   * patterns may nest groups at most 300 deep (Python: around 330);
#   * Pattern.groupindex is a dict (Python: a read-only mappingproxy);
#     Pattern.scanner() and the deprecated re.template() are not provided.

# ── flags ────────────────────────────────────────────────────────────────────
NOFLAG = 0
T = TEMPLATE = 1
I = IGNORECASE = 2
L = LOCALE = 4
M = MULTILINE = 8
S = DOTALL = 16
U = UNICODE = 32
X = VERBOSE = 64
DEBUG = 128
A = ASCII = 256


class RegexFlag:
    NOFLAG = 0
    TEMPLATE = 1
    IGNORECASE = 2
    LOCALE = 4
    MULTILINE = 8
    DOTALL = 16
    UNICODE = 32
    VERBOSE = 64
    DEBUG = 128
    ASCII = 256
    T = 1
    I = 2
    L = 4
    M = 8
    S = 16
    U = 32
    X = 64
    A = 256


_FLAG_NAMES = [["re.TEMPLATE", 1], ["re.IGNORECASE", 2], ["re.LOCALE", 4], ["re.MULTILINE", 8],
               ["re.DOTALL", 16], ["re.UNICODE", 32], ["re.VERBOSE", 64], ["re.DEBUG", 128],
               ["re.ASCII", 256]]


# ── error ────────────────────────────────────────────────────────────────────
class error(Exception):
    def __init__(self, msg, pattern=none, pos=none):
        var text = msg
        var lineno = none
        var colno = none
        if pattern != none and pos != none:
            text = msg + " at position " + str(pos)
            var nl = "\n"
            if isinstance(pattern, bytes):
                nl = b"\n"
            lineno = pattern.count(nl, 0, pos) + 1
            colno = pos - pattern.rfind(nl, 0, pos)
            if nl in pattern:
                text = text + " (line " + str(lineno) + ", column " + str(colno) + ")"
        super().__init__(text)
        self.msg = msg
        self.pattern = pattern
        self.pos = pos
        self.lineno = lineno
        self.colno = colno


PatternError = error


def _is_text(x):
    return isinstance(x, str) or isinstance(x, bytes)


def _empty_like(x):
    if isinstance(x, str):
        return ""
    return b""


# The subject the matches of one finditer/sub share. A string is a value on
# the VM, so Matches holding the string itself would copy the whole subject
# once per match (finditer over a long text: quadratic time and memory); they
# hold this instead. A lone Match (search, match, fullmatch) holds the string.
class _Subject:
    def __init__(self, s):
        self.s = s


def _clip(n, pos, endpos):
    var p = pos
    var e = endpos
    if e == none or e > n:
        e = n
    if e < 0:
        e = 0
    if p < 0:
        p = 0
    if p > n:
        p = n
    return [p, e]


# ── Pattern ──────────────────────────────────────────────────────────────────
class Pattern:
    # _f: the flags it was compiled with (the native cache key); flags: the
    # final flags, inline flags and UNICODE included.
    def __init__(self, pattern, f, info):
        self.pattern = pattern
        self._f = f
        self.groups = info[0]
        self.flags = info[1]
        self._t = 3 + 2 * info[0]     # where a match's texts start
        self.groupindex = {}
        self._names = {}
        var gi = info[2]
        var k = 0
        while k < len(gi):
            self.groupindex[gi[k]] = gi[k + 1]
            self._names[gi[k + 1]] = gi[k]
            k = k + 2

    def search(self, string, pos=0, endpos=none):
        var d = _re_exec(self.pattern, self._f, string, pos, endpos, 0)
        if d is none:
            return none
        if pos == 0 and endpos is none:
            return Match(self, string, 0, len(string), d)
        var pe = _clip(len(string), pos, endpos)
        return Match(self, string, pe[0], pe[1], d)

    def match(self, string, pos=0, endpos=none):
        var d = _re_exec(self.pattern, self._f, string, pos, endpos, 1)
        if d is none:
            return none
        if pos == 0 and endpos is none:
            return Match(self, string, 0, len(string), d)
        var pe = _clip(len(string), pos, endpos)
        return Match(self, string, pe[0], pe[1], d)

    def fullmatch(self, string, pos=0, endpos=none):
        var d = _re_exec(self.pattern, self._f, string, pos, endpos, 2)
        if d is none:
            return none
        if pos == 0 and endpos is none:
            return Match(self, string, 0, len(string), d)
        var pe = _clip(len(string), pos, endpos)
        return Match(self, string, pe[0], pe[1], d)

    def findall(self, string, pos=0, endpos=none):
        return _re_findall(self.pattern, self._f, string, pos, endpos)

    def finditer(self, string, pos=0, endpos=none):
        return _finditer(self, _Subject(string), pos, endpos)

    def split(self, string, maxsplit=0):
        return _re_split(self.pattern, self._f, string, maxsplit)

    def sub(self, repl, string, count=0):
        return _subx(self, repl, string, count)[0]

    def subn(self, repl, string, count=0):
        var r = _subx(self, repl, string, count)
        return (r[0], r[1])

    def __repr__(self):
        var f = self.flags
        if isinstance(self.pattern, str) and (f & (LOCALE | UNICODE | ASCII)) == UNICODE:
            f = f & ~UNICODE
        var r = repr(self.pattern)
        if len(r) > 200:
            r = r[0:200]
        if f == 0:
            return "re.compile(" + r + ")"
        var names = []
        for fn in _FLAG_NAMES:
            if f & fn[1]:
                names.append(fn[0])
                f = f & ~fn[1]
        if f:
            names.append(hex(f))
        return "re.compile(" + r + ", " + "|".join(names) + ")"

    def __eq__(self, other):
        if not isinstance(other, Pattern):
            return false
        return self.flags == other.flags and self.pattern == other.pattern and isinstance(self.pattern, bytes) == isinstance(other.pattern, bytes)

    def __hash__(self):
        return hash(self.pattern) ^ self.flags

    def __copy__(self):
        return self

    def __deepcopy__(self, memo):
        return self


def _finditer(p, subj, pos, endpos):
    # The matches come from the native scanner in growing batches, so a
    # consumer that stops early does not pay for the rest, and the memo
    # table is shared within a batch.
    var pe = _clip(len(subj.s), pos, endpos)
    var at = pe[0]
    var adv = false
    var batch = 8
    while true:
        var ms = _re_scan(p.pattern, p._f, subj.s, at, pe[1], batch, adv)
        for d in ms:
            yield Match(p, subj, pe[0], pe[1], d)
        if len(ms) < batch:
            return
        var last = ms[len(ms) - 1]
        at = last[2]
        adv = last[2] == last[1]
        if batch < 4096:
            batch = batch * 2


def _subx(p, repl, string, count):
    if _is_text(repl):
        if isinstance(repl, bytes) != isinstance(p.pattern, bytes):
            if isinstance(repl, bytes):
                raise TypeError("sequence item 0: expected str instance, bytes found")
            raise TypeError("sequence item 0: expected a bytes-like object, str found")
        var r = _re_sub(p.pattern, p._f, repl, string, count)
        if isinstance(r[0], int) and r[0] == -1:
            raise error(r[1], repl, r[2])
        return r
    if not callable(repl):
        raise TypeError("decoding to str: need a bytes-like object, " + type(repl).__name__ + " found")
    var pieces = _re_pieces(p.pattern, p._f, string, count)
    var subj = _Subject(string)
    var n = len(string)
    var out = [pieces[0]]
    var nsub = 0
    var i = 1
    var want_bytes = isinstance(string, bytes)
    while i < len(pieces):
        var r = repl(Match(p, subj, 0, n, pieces[i]))
        if r != none:
            if want_bytes and not isinstance(r, bytes):
                raise TypeError("sequence item " + str(len(out)) + ": expected a bytes-like object, " + type(r).__name__ + " found")
            if not want_bytes and not isinstance(r, str):
                raise TypeError("sequence item " + str(len(out)) + ": expected str instance, " + type(r).__name__ + " found")
            out.append(r)
        out.append(pieces[i + 1])
        nsub = nsub + 1
        i = i + 2
    return [_empty_like(string).join(out), nsub]


# ── Match ────────────────────────────────────────────────────────────────────
class Match:
    # _d is the native match: [lastindex, start0, end0, start1, end1, ...,
    # text0, text1, ...] (none and -1 for a group that did not take part);
    # _s the subject string, or the _Subject a finditer/sub shares.
    def __init__(self, pat, subj, pos, endpos, d):
        self._p = pat
        self._s = subj
        self.pos = pos
        self.endpos = endpos
        self._d = d
        self._t = pat._t

    @property
    def re(self):
        return self._p

    @property
    def string(self):
        if isinstance(self._s, _Subject):
            return self._s.s
        return self._s

    @property
    def lastindex(self):
        return self._d[0]

    @property
    def lastgroup(self):
        if self._d[0] is none:
            return none
        return self._p._names.get(self._d[0])

    def _index(self, g):
        if isinstance(g, int):
            if g >= 0 and g <= self._p.groups:
                return g
        elif _is_text(g):
            var i = self._p.groupindex.get(g)
            if i is not none:
                return i
        raise IndexError("no such group")

    def group(self, *args):
        if len(args) == 0:
            return self._d[self._t]
        if len(args) == 1:
            return self._d[self._t + self._index(args[0])]
        return tuple([self._d[self._t + self._index(g)] for g in args])

    def __getitem__(self, g):
        return self._d[self._t + self._index(g)]

    def groups(self, default=none):
        var out = []
        for i in range(1, self._p.groups + 1):
            var t = self._d[self._t + i]
            if t == none:
                out.append(default)
            else:
                out.append(t)
        return tuple(out)

    def groupdict(self, default=none):
        var r = {}
        var gi = self._p.groupindex
        for name in gi:
            var t = self._d[self._t + gi[name]]
            if t == none:
                r[name] = default
            else:
                r[name] = t
        return r

    def start(self, group=0):
        return self._d[1 + 2 * self._index(group)]

    def end(self, group=0):
        return self._d[2 + 2 * self._index(group)]

    def span(self, group=0):
        var i = self._index(group)
        return (self._d[1 + 2 * i], self._d[2 + 2 * i])

    @property
    def regs(self):
        return tuple([(self._d[1 + 2 * i], self._d[2 + 2 * i]) for i in range(self._p.groups + 1)])

    def expand(self, template):
        var items = _re_template(self._p.pattern, self._p._f, template)
        if len(items) == 3 and isinstance(items[0], int) and items[0] == -1:
            raise error(items[1], template, items[2])
        var out = []
        for it in items:
            if isinstance(it, int):
                var t = self._d[self._t + it]
                if t != none:
                    out.append(t)
            else:
                out.append(it)
        return _empty_like(template).join(out)

    def __repr__(self):
        var r = repr(self._d[self._t])
        if len(r) > 50:
            r = r[0:50]
        return "<re.Match object; span=(" + str(self._d[1]) + ", " + str(self._d[2]) + "), match=" + r + ">"

    def __copy__(self):
        return self

    def __deepcopy__(self, memo):
        return self


# ── the module functions ─────────────────────────────────────────────────────
_cache = {}
_MAXCACHE = 512


_cache0 = {}      # flags 0, by pattern alone: the common case, one lookup


def _compile(pattern, flags):
    if flags == 0:
        var p0 = _cache0.get(pattern)
        if p0 is not none:
            return p0
    if isinstance(pattern, Pattern):
        if flags:
            raise ValueError("cannot process flags argument with a compiled pattern")
        return pattern
    if not _is_text(pattern):
        raise TypeError("first argument must be string or compiled pattern")
    var key = ("b" if isinstance(pattern, bytes) else "s", flags, pattern)
    var p = _cache.get(key)
    if p is not none:
        return p
    var info = _re_compile(pattern, flags)
    if info[0] == -1:
        raise error(info[1], pattern, info[2])
    p = Pattern(pattern, flags, info)
    if len(_cache) >= _MAXCACHE:
        var oldest = none
        for k in _cache:
            oldest = k
            break
        _cache.pop(oldest)
        _cache0.clear()
    _cache[key] = p
    if flags == 0:
        _cache0[pattern] = p
    return p


def compile(pattern, flags=0):
    return _compile(pattern, flags)


def search(pattern, string, flags=0):
    return _compile(pattern, flags).search(string)


def match(pattern, string, flags=0):
    return _compile(pattern, flags).match(string)


def fullmatch(pattern, string, flags=0):
    return _compile(pattern, flags).fullmatch(string)


def split(pattern, string, maxsplit=0, flags=0):
    return _compile(pattern, flags).split(string, maxsplit)


def findall(pattern, string, flags=0):
    return _compile(pattern, flags).findall(string)


def finditer(pattern, string, flags=0):
    return _compile(pattern, flags).finditer(string)


def sub(pattern, repl, string, count=0, flags=0):
    return _compile(pattern, flags).sub(repl, string, count)


def subn(pattern, repl, string, count=0, flags=0):
    return _compile(pattern, flags).subn(repl, string, count)


def escape(pattern):
    return _re_escape(pattern)


def purge():
    _cache.clear()
    _cache0.clear()
    _re_purge()
