# nython: module    (import it by name: it runs in a module scope of its own)
# lib/unittest.ny - Python's unittest: the unit testing framework.
#
#     TestCase: setUp/tearDown, setUpClass/tearDownClass, addCleanup/
#         doCleanups/enterContext, addClassCleanup/doClassCleanups, subTest,
#         skipTest, fail, id, shortDescription, run, debug, the assert
#         methods - assertEqual (type-specific messages for str, list,
#         tuple, dict, set), assertNotEqual, assertTrue/False, assertIs/
#         IsNot, assertIsNone/IsNotNone, assertIn/NotIn, assertIsInstance/
#         NotIsInstance, assertRaises/assertRaisesRegex (callable and
#         context-manager forms, .exception), assertAlmostEqual/
#         NotAlmostEqual (places, delta), assertGreater/GreaterEqual/Less/
#         LessEqual, assertCountEqual, assertSequenceEqual, assertListEqual,
#         assertTupleEqual, assertSetEqual, assertDictEqual,
#         assertMultiLineEqual, assertRegex/NotRegex, assertLogs/
#         assertNoLogs, addTypeEqualityFunc, maxDiff, longMessage,
#         failureException
#     skip, skipIf, skipUnless, expectedFailure, SkipTest
#     FunctionTestCase, TestSuite, BaseTestSuite, TestLoader
#     (loadTestsFromTestCase, loadTestsFromModule, loadTestsFromName(s),
#     getTestCaseNames, testMethodPrefix, testNamePatterns,
#     sortTestMethodsUsing), defaultTestLoader, TestResult, TextTestResult,
#     TextTestRunner, main / TestProgram (-v, -q, -f, -k, test names)
#
# CPython 3.12's algorithms and output: the failure messages ("1 != 2",
# "Lists differ: ... First differing element 2:", the ndiff of
# pprint.pformat lines with its "?" hint lines - difflib's SequenceMatcher
# and Differ and a pprint subset are written here), the runner's dots /
# "test_x (__main__.C.test_x) ... ok" lines, the ===/--- error blocks,
# "Ran N tests in X.XXXs", "OK", "FAILED (failures=1, errors=2,
# skipped=1)", "NO TESTS RAN", and main()'s exit status (0, 1, or 5 when
# no test ran) through SystemExit.
#
# Differences from CPython (Nython has no frame objects):
#   - A failure's text is "Traceback (most recent call last):" followed by
#     the exception line; there are no frame lines.
#   - main() finds the program's TestCase classes in the __main__ module's
#     globals (_ny_main_globals); setUpModule/tearDownModule there are run.
#     Test discovery in directories (unittest discover) is not provided.
#   - assertRaisesRegex/assertRegex take a pattern string (searched with
#     the runtime's regex engine, ECMAScript syntax - Python's for the
#     common subset) or a compiled pattern with .search().
#   - buffer=True does not capture print() output (print writes to the
#     process's stream directly); assertWarns is not provided (no warnings
#     module); the -c/--catch option is accepted and ignored.

import sys
import os

__all__ = ["TestResult", "TestCase", "IsolatedAsyncioTestCase", "TestSuite",
           "TextTestRunner", "TestLoader", "FunctionTestCase", "main",
           "defaultTestLoader", "SkipTest", "skip", "skipIf", "skipUnless",
           "expectedFailure", "TextTestResult", "installHandler",
           "registerResult", "removeResult", "removeHandler",
           "addModuleCleanup", "doModuleCleanups", "enterModuleContext",
           "BaseTestSuite"]

__unittest = true

DIFF_OMITTED = "\nDiff is %s characters long. Set self.maxDiff to None to see it."
_MAX_LENGTH = 80
_PLACEHOLDER_LEN = 12
_MIN_BEGIN_LEN = 5
_MIN_END_LEN = 5
_MIN_COMMON_LEN = 5
_MIN_DIFF_LEN = _MAX_LENGTH - (_MIN_BEGIN_LEN + _PLACEHOLDER_LEN + _MIN_COMMON_LEN + _PLACEHOLDER_LEN + _MIN_END_LEN)
_NO_TESTS_EXITCODE = 5


class SkipTest(Exception):
    """
    Raise this exception in a test to skip it.

    Usually you can use TestCase.skipTest() or one of the skipping decorators
    instead of raising this directly.
    """
    pass


class _ShouldStop(Exception):
    """
    The test should stop.
    """
    pass


class _UnexpectedSuccess(Exception):
    """
    The test was supposed to fail, but it didn't!
    """
    pass


# ── util ─────────────────────────────────────────────────────────────────────

def _is_class(obj):
    var t = type(obj)
    var n = t.__name__ if hasattr(t, "__name__") else ""
    return n == "class" or n == "type" or isinstance(obj, type)


def _same(a, b):
    return id(a) == id(b)


def _obj_id(x):
    # id() for methods of classes that have an id() method of their own
    return id(x)


def _same_class(a, b):
    # type(a) is type(b): classes by identity, builtin types by kind
    var ha = hasattr(a, "__class__")
    var hb = hasattr(b, "__class__")
    if ha and hb:
        return id(a.__class__) == id(b.__class__)
    if ha or hb:
        return false
    return _kind_of(a) == _kind_of(b)


def _class_of(obj):
    # obj.__class__, or type(obj) for a builtin value (Nython has no
    # __class__ on str, list, dict...)
    if hasattr(obj, "__class__"):
        return obj.__class__
    return type(obj)


def _py_repr(obj):
    # repr() as CPython spells it: None, True and False (Nython's own repr
    # writes none/true/false), also inside lists, tuples, dicts and sets.
    if obj is none:
        return "None"
    if isinstance(obj, bool):
        return "True" if obj else "False"
    var k = _kind_of(obj)
    if k == "list":
        return "[" + ", ".join([_py_repr(x) for x in obj]) + "]"
    if k == "tuple":
        if len(obj) == 1:
            return "(" + _py_repr(obj[0]) + ",)"
        return "(" + ", ".join([_py_repr(x) for x in obj]) + ")"
    if k == "dict":
        return "{" + ", ".join([_py_repr(kk) + ": " + _py_repr(obj[kk]) for kk in obj]) + "}"
    if k == "set" or k == "frozenset":
        if len(obj) == 0:
            return k + "()"
        var body = "{" + ", ".join([_py_repr(x) for x in obj]) + "}"
        return body if k == "set" else "frozenset(" + body + ")"
    return repr(obj)


def _exc_str(value):
    # str(exception) as CPython gives it: a KeyError shows its key's repr
    # (Nython's KeyError("k") reads k; the runtime's own already carry the
    # quotes)
    var s = str(value)
    if isinstance(value, KeyError):
        var a = getattr(value, "args", ())
        if len(a) == 1:
            var a0 = a[0]
            if not isinstance(a0, str):
                return _py_repr(a0)
            if not (len(a0) >= 2 and a0[0] == a0[-1] and (a0[0] == "'" or a0[0] == "\"")):
                return repr(a0)
    return s


def safe_repr(obj, short=false):
    var result = ""
    try:
        result = _py_repr(obj)
    except Exception:
        result = "<" + _class_of(obj).__name__ + " object>"
    if not short or len(result) < _MAX_LENGTH:
        return result
    return result[:_MAX_LENGTH] + " [truncated]..."


def strclass(cls):
    var mod = getattr(cls, "__module__", none)
    if not mod or not isinstance(mod, str):
        mod = "__main__"
    var q = getattr(cls, "__qualname__", none)
    if not q or not isinstance(q, str):
        q = cls.__name__
    return mod + "." + q


def _commonprefix(m):
    if not m:
        return ""
    var s1 = min(m)
    var s2 = max(m)
    var i = 0
    var n = min(len(s1), len(s2))
    while i < n:
        if s1[i] != s2[i]:
            return s1[:i]
        i = i + 1
    return s1[:n]


def _shorten(s, prefixlen, suffixlen):
    var skip = len(s) - prefixlen - suffixlen
    if skip > _PLACEHOLDER_LEN:
        s = s[:prefixlen] + "[" + str(skip) + " chars]" + s[len(s) - suffixlen:]
    return s


def _common_shorten_repr(*args):
    var reps = [safe_repr(a) for a in args]
    var maxlen = max([len(r) for r in reps])
    if maxlen <= _MAX_LENGTH:
        return tuple(reps)
    var prefix = _commonprefix(reps)
    var prefixlen = len(prefix)
    var common_len = _MAX_LENGTH - (maxlen - prefixlen + _MIN_BEGIN_LEN + _PLACEHOLDER_LEN)
    if common_len > _MIN_COMMON_LEN:
        prefix = _shorten(prefix, _MIN_BEGIN_LEN, common_len)
        return tuple([prefix + s[prefixlen:] for s in reps])
    prefix = _shorten(prefix, _MIN_BEGIN_LEN, _MIN_COMMON_LEN)
    return tuple([prefix + _shorten(s[prefixlen:], _MIN_DIFF_LEN, _MIN_END_LEN) for s in reps])


def three_way_cmp(x, y):
    """Return -1 if x < y, 0 if x == y and 1 if x > y"""
    return (x > y) - (x < y)


# The kind a value's exact type stands for, for the type-specific
# assertEqual messages (Nython's type names: map, string, none...).
def _kind_of(x):
    var n = _class_of(x).__name__
    if n == "map":
        return "dict"
    if n == "string":
        return "str"
    return n


def _kind_of_type(t):
    var n = t.__name__
    if n == "map":
        return "dict"
    if n == "string":
        return "str"
    return n


def _re_search(pattern, text):
    # A compiled pattern (with .search) or a pattern string, searched with
    # the runtime's regex engine. Returns the matched text or none.
    if hasattr(pattern, "search"):
        var m = pattern.search(text)
        if m is none:
            return none
        return m.group(0) if hasattr(m, "group") else str(m)
    var r = re_search(pattern, text)
    if r is none:
        return none
    if isinstance(r, str):
        return r
    return r[0]


def _pattern_text(pattern):
    if hasattr(pattern, "pattern"):
        return pattern.pattern
    return pattern


# ── difflib subset (SequenceMatcher, Differ, ndiff) ──────────────────────────

class _UtSequenceMatcher:
    # difflib.SequenceMatcher (Ratcliff/Obershelp), CPython's algorithm.
    def __init__(self, isjunk=none, a="", b="", autojunk=true):
        self.isjunk = isjunk
        self.a = none
        self.b = none
        self.autojunk = autojunk
        self.set_seqs(a, b)

    def set_seqs(self, a, b):
        self.set_seq1(a)
        self.set_seq2(b)

    def set_seq1(self, a):
        self.a = a
        self.matching_blocks = none
        self.opcodes = none

    def set_seq2(self, b):
        self.b = b
        self.matching_blocks = none
        self.opcodes = none
        self.fullbcount = none
        self._chain_b()

    def _chain_b(self):
        var b = self.b
        var b2j = {}
        var i = 0
        for elt in b:
            var indices = b2j.get(elt)
            if indices is none:
                indices = []
                b2j[elt] = indices
            indices.append(i)
            i = i + 1
        var junk = set()
        if self.isjunk:
            for elt2 in list(b2j.keys()):
                if self.isjunk(elt2):
                    junk.add(elt2)
            for elt3 in junk:
                del b2j[elt3]
        var popular = set()
        var n = len(b)
        if self.autojunk and n >= 200:
            var ntest = n // 100 + 1
            for elt4 in list(b2j.keys()):
                if len(b2j[elt4]) > ntest:
                    popular.add(elt4)
            for elt5 in popular:
                del b2j[elt5]
        self.b2j = b2j
        self.bjunk = junk
        self.bpopular = popular

    def find_longest_match(self, alo, ahi, blo, bhi):
        var a = self.a
        var b = self.b
        var b2j = self.b2j
        var bjunk = self.bjunk
        var besti = alo
        var bestj = blo
        var bestsize = 0
        var j2len = {}
        var i = alo
        while i < ahi:
            var newj2len = {}
            var js = b2j.get(a[i])
            if js is not none:
                for j in js:
                    if j < blo:
                        continue
                    if j >= bhi:
                        break
                    var k = j2len.get(j - 1, 0) + 1
                    newj2len[j] = k
                    if k > bestsize:
                        besti = i - k + 1
                        bestj = j - k + 1
                        bestsize = k
            j2len = newj2len
            i = i + 1
        while besti > alo and bestj > blo and not (b[bestj - 1] in bjunk) and a[besti - 1] == b[bestj - 1]:
            besti = besti - 1
            bestj = bestj - 1
            bestsize = bestsize + 1
        while besti + bestsize < ahi and bestj + bestsize < bhi and not (b[bestj + bestsize] in bjunk) and a[besti + bestsize] == b[bestj + bestsize]:
            bestsize = bestsize + 1
        while besti > alo and bestj > blo and (b[bestj - 1] in bjunk) and a[besti - 1] == b[bestj - 1]:
            besti = besti - 1
            bestj = bestj - 1
            bestsize = bestsize + 1
        while besti + bestsize < ahi and bestj + bestsize < bhi and (b[bestj + bestsize] in bjunk) and a[besti + bestsize] == b[bestj + bestsize]:
            bestsize = bestsize + 1
        return [besti, bestj, bestsize]

    def get_matching_blocks(self):
        if self.matching_blocks is not none:
            return self.matching_blocks
        var la = len(self.a)
        var lb = len(self.b)
        var queue = [[0, la, 0, lb]]
        var matching_blocks = []
        while queue:
            var q = queue.pop()
            var alo = q[0]
            var ahi = q[1]
            var blo = q[2]
            var bhi = q[3]
            var x = self.find_longest_match(alo, ahi, blo, bhi)
            var i = x[0]
            var j = x[1]
            var k = x[2]
            if k:
                matching_blocks.append(x)
                if alo < i and blo < j:
                    queue.append([alo, i, blo, j])
                if i + k < ahi and j + k < bhi:
                    queue.append([i + k, ahi, j + k, bhi])
        matching_blocks.sort()
        var i1 = 0
        var j1 = 0
        var k1 = 0
        var non_adjacent = []
        for blk in matching_blocks:
            var i2 = blk[0]
            var j2 = blk[1]
            var k2 = blk[2]
            if i1 + k1 == i2 and j1 + k1 == j2:
                k1 = k1 + k2
            else:
                if k1:
                    non_adjacent.append([i1, j1, k1])
                i1 = i2
                j1 = j2
                k1 = k2
        if k1:
            non_adjacent.append([i1, j1, k1])
        non_adjacent.append([la, lb, 0])
        self.matching_blocks = non_adjacent
        return non_adjacent

    def get_opcodes(self):
        if self.opcodes is not none:
            return self.opcodes
        var i = 0
        var j = 0
        var answer = []
        for blk in self.get_matching_blocks():
            var ai = blk[0]
            var bj = blk[1]
            var size = blk[2]
            var tag = ""
            if i < ai and j < bj:
                tag = "replace"
            elif i < ai:
                tag = "delete"
            elif j < bj:
                tag = "insert"
            if tag:
                answer.append([tag, i, ai, j, bj])
            i = ai + size
            j = bj + size
            if size:
                answer.append(["equal", ai, i, bj, j])
        self.opcodes = answer
        return answer

    def ratio(self):
        var matches = 0
        for blk in self.get_matching_blocks():
            matches = matches + blk[2]
        return _calculate_ratio(matches, len(self.a) + len(self.b))

    def quick_ratio(self):
        if self.fullbcount is none:
            var fb = {}
            for elt in self.b:
                fb[elt] = fb.get(elt, 0) + 1
            self.fullbcount = fb
        var fullbcount = self.fullbcount
        var avail = {}
        var matches = 0
        for elt2 in self.a:
            var numb = 0
            if elt2 in avail:
                numb = avail[elt2]
            else:
                numb = fullbcount.get(elt2, 0)
            avail[elt2] = numb - 1
            if numb > 0:
                matches = matches + 1
        return _calculate_ratio(matches, len(self.a) + len(self.b))

    def real_quick_ratio(self):
        var la = len(self.a)
        var lb = len(self.b)
        return _calculate_ratio(min(la, lb), la + lb)


def _calculate_ratio(matches, length):
    if length:
        return 2.0 * matches / length
    return 1.0


def _is_character_junk(ch):
    return ch in " \t"


def _keep_original_ws(s, tag_s):
    var out = []
    var i = 0
    var n = min(len(s), len(tag_s))
    while i < n:
        var c = s[i]
        var tag_c = tag_s[i]
        if tag_c == " " and c.isspace():
            out.append(c)
        else:
            out.append(tag_c)
        i = i + 1
    return "".join(out)


class _UtDiffer:
    # difflib.Differ: compare two sequences of lines, CPython's output.
    def __init__(self, linejunk=none, charjunk=none):
        self.linejunk = linejunk
        self.charjunk = charjunk

    def compare(self, a, b):
        var out = []
        var cruncher = _UtSequenceMatcher(self.linejunk, a, b)
        for op in cruncher.get_opcodes():
            var tag = op[0]
            if tag == "replace":
                self._fancy_replace(a, op[1], op[2], b, op[3], op[4], out)
            elif tag == "delete":
                self._dump("-", a, op[1], op[2], out)
            elif tag == "insert":
                self._dump("+", b, op[3], op[4], out)
            else:
                self._dump(" ", a, op[1], op[2], out)
        return out

    def _dump(self, tag, x, lo, hi, out):
        var i = lo
        while i < hi:
            out.append(tag + " " + x[i])
            i = i + 1

    def _plain_replace(self, a, alo, ahi, b, blo, bhi, out):
        if bhi - blo < ahi - alo:
            self._dump("+", b, blo, bhi, out)
            self._dump("-", a, alo, ahi, out)
        else:
            self._dump("-", a, alo, ahi, out)
            self._dump("+", b, blo, bhi, out)

    def _fancy_replace(self, a, alo, ahi, b, blo, bhi, out):
        var best_ratio = 0.74
        var cutoff = 0.75
        var cruncher = _UtSequenceMatcher(self.charjunk)
        var eqi = none
        var eqj = none
        var best_i = 0
        var best_j = 0
        var j = blo
        while j < bhi:
            var bj = b[j]
            cruncher.set_seq2(bj)
            var i = alo
            while i < ahi:
                var ai = a[i]
                if ai == bj:
                    if eqi is none:
                        eqi = i
                        eqj = j
                    i = i + 1
                    continue
                cruncher.set_seq1(ai)
                if cruncher.real_quick_ratio() > best_ratio and cruncher.quick_ratio() > best_ratio and cruncher.ratio() > best_ratio:
                    best_ratio = cruncher.ratio()
                    best_i = i
                    best_j = j
                i = i + 1
            j = j + 1
        if best_ratio < cutoff:
            if eqi is none:
                self._plain_replace(a, alo, ahi, b, blo, bhi, out)
                return
            best_i = eqi
            best_j = eqj
            best_ratio = 1.0
        else:
            eqi = none
        self._fancy_helper(a, alo, best_i, b, blo, best_j, out)
        var aelt = a[best_i]
        var belt = b[best_j]
        if eqi is none:
            var atags = ""
            var btags = ""
            cruncher.set_seqs(aelt, belt)
            for op in cruncher.get_opcodes():
                var tag = op[0]
                var la = op[2] - op[1]
                var lb = op[4] - op[3]
                if tag == "replace":
                    atags = atags + "^" * la
                    btags = btags + "^" * lb
                elif tag == "delete":
                    atags = atags + "-" * la
                elif tag == "insert":
                    btags = btags + "+" * lb
                else:
                    atags = atags + " " * la
                    btags = btags + " " * lb
            self._qformat(aelt, belt, atags, btags, out)
        else:
            out.append("  " + aelt)
        self._fancy_helper(a, best_i + 1, ahi, b, best_j + 1, bhi, out)

    def _fancy_helper(self, a, alo, ahi, b, blo, bhi, out):
        if alo < ahi:
            if blo < bhi:
                self._fancy_replace(a, alo, ahi, b, blo, bhi, out)
            else:
                self._dump("-", a, alo, ahi, out)
        elif blo < bhi:
            self._dump("+", b, blo, bhi, out)

    def _qformat(self, aline, bline, atags, btags, out):
        atags = _keep_original_ws(aline, atags).rstrip()
        btags = _keep_original_ws(bline, btags).rstrip()
        out.append("- " + aline)
        if atags:
            out.append("? " + atags + "\n")
        out.append("+ " + bline)
        if btags:
            out.append("? " + btags + "\n")


def _ndiff(a, b):
    return _UtDiffer(none, _is_character_junk).compare(a, b)


def _splitlines(s, keepends=false):
    var out = []
    var cur = []
    var i = 0
    var n = len(s)
    var start = 0
    while i < n:
        var c = s[i]
        if c == "\n" or c == "\r":
            var end = i + 1
            if c == "\r" and i + 1 < n and s[i + 1] == "\n":
                end = i + 2
            out.append(s[start:end] if keepends else s[start:i])
            start = end
            i = end
            continue
        i = i + 1
    if start < n:
        out.append(s[start:])
    return out


# ── pprint subset (pformat of containers, sorted dicts) ──────────────────────

def _pp_repr(obj):
    # pprint's _safe_repr: dicts with sorted keys, recursively
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        var keys = _pp_sorted_keys(obj)
        var parts = []
        for k in keys:
            parts.append(_pp_repr(k) + ": " + _pp_repr(obj[k]))
        return "{" + ", ".join(parts) + "}"
    if isinstance(obj, list):
        if not obj:
            return "[]"
        return "[" + ", ".join([_pp_repr(x) for x in obj]) + "]"
    if isinstance(obj, tuple):
        if not obj:
            return "()"
        if len(obj) == 1:
            return "(" + _pp_repr(obj[0]) + ",)"
        return "(" + ", ".join([_pp_repr(x) for x in obj]) + ")"
    return _py_repr(obj)


def _pp_sorted_keys(d):
    var keys = list(d.keys())
    try:
        return sorted(keys)
    except Exception:
        return sorted(keys, key=lambda k: (str(_class_of(k).__name__), repr(k)))


def _pformat(obj):
    var out = []
    _pp_format(obj, out, 0, 0)
    return "".join(out)


def _pp_format(obj, out, indent, allowance):
    var rep = _pp_repr(obj)
    var max_width = 80 - indent - allowance
    if len(rep) > max_width:
        if isinstance(obj, dict) and len(obj) > 0:
            out.append("{")
            var keys = _pp_sorted_keys(obj)
            var ind = indent + 1
            var last_index = len(keys) - 1
            var i = 0
            for k in keys:
                var last = i == last_index
                var krep = _pp_repr(k)
                out.append(krep)
                out.append(": ")
                _pp_format(obj[k], out, ind + len(krep) + 2, allowance + 1 if last else 1)
                if not last:
                    out.append(",\n" + " " * ind)
                i = i + 1
            out.append("}")
            return
        if (isinstance(obj, list) or isinstance(obj, tuple)) and len(obj) > 0:
            var is_list = isinstance(obj, list)
            var endchar = "]" if is_list else (",)" if len(obj) == 1 else ")")
            out.append("[" if is_list else "(")
            _pp_items(obj, out, indent, allowance + len(endchar))
            out.append(endchar)
            return
        if (isinstance(obj, set) or isinstance(obj, frozenset)) and len(obj) > 0:
            var items = list(obj)
            try:
                items = sorted(items)
            except Exception:
                pass
            if isinstance(obj, set):
                out.append("{")
                _pp_items(items, out, indent, allowance + 1)
                out.append("}")
            else:
                out.append("frozenset({")
                _pp_items(items, out, indent + 10, allowance + 2)
                out.append("})")
            return
    out.append(rep)


def _pp_items(items, out, indent, allowance):
    var ind = indent + 1
    var delim = ""
    var n = len(items)
    var i = 0
    while i < n:
        var last = i == n - 1
        out.append(delim)
        delim = ",\n" + " " * ind
        _pp_format(items[i], out, ind, allowance if last else 1)
        i = i + 1


# ── results ──────────────────────────────────────────────────────────────────

def _exc_text(err):
    # "Traceback (most recent call last):" and the exception line (Nython
    # keeps no frames).
    var etype = err[0]
    var value = err[1]
    var tname = "Exception"
    if etype is not none:
        tname = etype.__name__
    elif value is not none:
        tname = _class_of(value).__name__
    var mod = getattr(etype, "__module__", none) if etype is not none else none
    if mod is not none and isinstance(mod, str) and mod not in ["__main__", "builtins"]:
        tname = mod + "." + tname
    var msg = ""
    if value is not none:
        try:
            msg = _exc_str(value)
        except Exception:
            msg = "<exception str() failed>"
    var line = tname if msg == "" else tname + ": " + msg
    return "Traceback (most recent call last):\n" + line + "\n"


def _exc_info_of(e):
    return (_class_of(e), e, none)


def failfast(method):
    def inner(self, *args, **kw):
        if getattr(self, "failfast", false):
            self.stop()
        return method(self, *args, **kw)
    return inner


class TestResult:
    """Holder for test result information.

    Test results are automatically managed by the TestCase and TestSuite
    classes, and do not need to be explicitly manipulated by writers of tests.

    Each instance holds the total number of tests run, and collections of
    failures and errors that occurred among those test runs. The collections
    contain tuples of (testcase, exceptioninfo), where exceptioninfo is the
    formatted traceback of the error that occurred.
    """
    _previousTestClass = none
    _testRunEntered = false
    _moduleSetUpFailed = false

    def __init__(self, stream=none, descriptions=none, verbosity=none):
        self.failfast = false
        self.failures = []
        self.errors = []
        self.testsRun = 0
        self.skipped = []
        self.expectedFailures = []
        self.unexpectedSuccesses = []
        self.collectedDurations = []
        self.shouldStop = false
        self.buffer = false
        self.tb_locals = false
        self._previousTestClass = none
        self._testRunEntered = false
        self._moduleSetUpFailed = false

    def printErrors(self):
        "Called by TestRunner after test run"
        pass

    def startTest(self, test):
        "Called when the given test is about to be run"
        self.testsRun = self.testsRun + 1

    def startTestRun(self):
        """Called once before any tests are executed.

        See startTest for a method called before each test.
        """
        pass

    def stopTest(self, test):
        """Called when the given test has been run"""
        pass

    def stopTestRun(self):
        """Called once after all tests are executed.

        See stopTest for a method called after each test.
        """
        pass

    def addError(self, test, err):
        """Called when an error has occurred. 'err' is a tuple of values as
        returned by sys.exc_info().
        """
        if self.failfast:
            self.stop()
        self.errors.append((test, self._exc_info_to_string(err, test)))

    def addFailure(self, test, err):
        """Called when an error has occurred. 'err' is a tuple of values as
        returned by sys.exc_info()."""
        if self.failfast:
            self.stop()
        self.failures.append((test, self._exc_info_to_string(err, test)))

    def addSubTest(self, test, subtest, err):
        """Called at the end of a subtest.
        'err' is None if the subtest ended successfully, otherwise it's a
        tuple of values as returned by sys.exc_info().
        """
        if err is not none:
            if getattr(self, "failfast", false):
                self.stop()
            if issubclass(err[0], test.failureException):
                self.failures.append((subtest, self._exc_info_to_string(err, test)))
            else:
                self.errors.append((subtest, self._exc_info_to_string(err, test)))

    def addSuccess(self, test):
        "Called when a test has completed successfully"
        pass

    def addSkip(self, test, reason):
        """Called when a test is skipped."""
        self.skipped.append((test, reason))

    def addExpectedFailure(self, test, err):
        """Called when an expected failure/error occurred."""
        self.expectedFailures.append((test, self._exc_info_to_string(err, test)))

    def addUnexpectedSuccess(self, test):
        """Called when a test was expected to fail, but succeed."""
        if self.failfast:
            self.stop()
        self.unexpectedSuccesses.append(test)

    def addDuration(self, test, elapsed):
        """Called when a test finished to run, regardless of its outcome."""
        self.collectedDurations.append((str(test), elapsed))

    def wasSuccessful(self):
        """Tells whether or not this result was a success."""
        return len(self.failures) == 0 and len(self.errors) == 0 and len(self.unexpectedSuccesses) == 0

    def stop(self):
        """Indicates that the tests should be aborted."""
        self.shouldStop = true

    def _exc_info_to_string(self, err, test):
        """Converts a sys.exc_info()-style tuple of values into a string."""
        return _exc_text(err)

    def __repr__(self):
        return "<" + strclass(_class_of(self)) + " run=" + str(self.testsRun) + " errors=" + str(len(self.errors)) + " failures=" + str(len(self.failures)) + ">"


class _WritelnDecorator:
    """Used to decorate file-like objects with a handy 'writeln' method"""
    def __init__(self, stream):
        self.stream = stream

    def write(self, s):
        self.stream.write(s)

    def flush(self):
        if hasattr(self.stream, "flush"):
            self.stream.flush()

    def writeln(self, arg=none):
        if arg:
            self.write(arg)
        self.write("\n")  # text-mode streams translate to \r\n if needed

    def __getattr__(self, attr):
        return getattr(self.stream, attr)


class TextTestResult(TestResult):
    """A test result class that can print formatted text results to a stream.

    Used by TextTestRunner.
    """
    separator1 = "=" * 70
    separator2 = "-" * 70

    def __init__(self, stream, descriptions, verbosity, durations=none):
        TestResult.__init__(self, stream, descriptions, verbosity)
        self.stream = stream
        self.showAll = verbosity > 1
        self.dots = verbosity == 1
        self.descriptions = descriptions
        self._newline = true
        self.durations = durations

    def getDescription(self, test):
        var doc_first_line = test.shortDescription()
        if self.descriptions and doc_first_line:
            return str(test) + "\n" + doc_first_line
        return str(test)

    def startTest(self, test):
        TestResult.startTest(self, test)
        if self.showAll:
            self.stream.write(self.getDescription(test))
            self.stream.write(" ... ")
            self.stream.flush()
            self._newline = false

    def _write_status(self, test, status):
        var is_subtest = isinstance(test, _SubTest)
        if is_subtest or self._newline:
            if not self._newline:
                self.stream.writeln()
            if is_subtest:
                self.stream.write("  ")
            self.stream.write(self.getDescription(test))
            self.stream.write(" ... ")
        self.stream.writeln(status)
        self.stream.flush()
        self._newline = true

    def addSubTest(self, test, subtest, err):
        if err is not none:
            if self.showAll:
                if issubclass(err[0], subtest.failureException):
                    self._write_status(subtest, "FAIL")
                else:
                    self._write_status(subtest, "ERROR")
            elif self.dots:
                if issubclass(err[0], subtest.failureException):
                    self.stream.write("F")
                else:
                    self.stream.write("E")
                self.stream.flush()
        TestResult.addSubTest(self, test, subtest, err)

    def addSuccess(self, test):
        TestResult.addSuccess(self, test)
        if self.showAll:
            self._write_status(test, "ok")
        elif self.dots:
            self.stream.write(".")
            self.stream.flush()

    def addError(self, test, err):
        TestResult.addError(self, test, err)
        if self.showAll:
            self._write_status(test, "ERROR")
        elif self.dots:
            self.stream.write("E")
            self.stream.flush()

    def addFailure(self, test, err):
        TestResult.addFailure(self, test, err)
        if self.showAll:
            self._write_status(test, "FAIL")
        elif self.dots:
            self.stream.write("F")
            self.stream.flush()

    def addSkip(self, test, reason):
        TestResult.addSkip(self, test, reason)
        if self.showAll:
            self._write_status(test, "skipped " + repr(reason))
        elif self.dots:
            self.stream.write("s")
            self.stream.flush()

    def addExpectedFailure(self, test, err):
        TestResult.addExpectedFailure(self, test, err)
        if self.showAll:
            self.stream.writeln("expected failure")
            self.stream.flush()
        elif self.dots:
            self.stream.write("x")
            self.stream.flush()

    def addUnexpectedSuccess(self, test):
        TestResult.addUnexpectedSuccess(self, test)
        if self.showAll:
            self.stream.writeln("unexpected success")
            self.stream.flush()
        elif self.dots:
            self.stream.write("u")
            self.stream.flush()

    def printErrors(self):
        if self.dots or self.showAll:
            self.stream.writeln()
            self.stream.flush()
        self.printErrorList("ERROR", self.errors)
        self.printErrorList("FAIL", self.failures)
        if self.unexpectedSuccesses:
            self.stream.writeln(self.separator1)
            for test in self.unexpectedSuccesses:
                self.stream.writeln("UNEXPECTED SUCCESS: " + self.getDescription(test))
            self.stream.flush()

    def printErrorList(self, flavour, errors):
        for pair in errors:
            self.stream.writeln(self.separator1)
            self.stream.writeln(flavour + ": " + self.getDescription(pair[0]))
            self.stream.writeln(self.separator2)
            self.stream.writeln(str(pair[1]))
            self.stream.flush()


class TextTestRunner:
    """A test runner class that displays results in textual form.

    It prints out the names of tests as they are run, errors as they
    occur, and a summary of the results at the end of the test run.
    """
    resultclass = TextTestResult

    def __init__(self, stream=none, descriptions=true, verbosity=1,
                 failfast=false, buffer=false, resultclass=none, warnings=none,
                 tb_locals=false, durations=none):
        """Construct a TextTestRunner.

        Subclasses should accept **kwargs to ensure compatibility as the
        interface changes.
        """
        if stream is none:
            stream = sys.stderr
        self.stream = _WritelnDecorator(stream)
        self.descriptions = descriptions
        self.verbosity = verbosity
        self.failfast = failfast
        self.buffer = buffer
        self.tb_locals = tb_locals
        self.durations = durations
        self.warnings = warnings
        if resultclass is not none:
            self.resultclass = resultclass

    def _makeResult(self):
        try:
            return self.resultclass(self.stream, self.descriptions, self.verbosity, self.durations)
        except TypeError:
            return self.resultclass(self.stream, self.descriptions, self.verbosity)

    def _printDurations(self, result):
        if not result.collectedDurations:
            return
        var ls = sorted(result.collectedDurations, key=lambda x: x[1], reverse=true)
        if self.durations > 0:
            ls = ls[:self.durations]
        self.stream.writeln("Slowest test durations")
        if hasattr(result, "separator2"):
            self.stream.writeln(result.separator2)
        var hidden = false
        for pair in ls:
            if self.verbosity < 2 and pair[1] < 0.001:
                hidden = true
                continue
            self.stream.writeln("%-10s %s" % ("%.3fs" % pair[1], pair[0]))
        if hidden:
            self.stream.writeln("\n(durations < 0.001s were hidden; use -v to show these durations)")
        else:
            self.stream.writeln("")

    def run(self, test):
        "Run the given test case or test suite."
        var result = self._makeResult()
        result.failfast = self.failfast
        result.buffer = self.buffer
        result.tb_locals = self.tb_locals
        var startTime = perf_counter()
        var startTestRun = getattr(result, "startTestRun", none)
        if startTestRun is not none:
            startTestRun()
        try:
            test(result)
        finally:
            var stopTestRun = getattr(result, "stopTestRun", none)
            if stopTestRun is not none:
                stopTestRun()
        var stopTime = perf_counter()
        var timeTaken = stopTime - startTime
        result.printErrors()
        if self.durations is not none:
            self._printDurations(result)
        if hasattr(result, "separator2"):
            self.stream.writeln(result.separator2)
        var run = result.testsRun
        self.stream.writeln("Ran %d test%s in %.3fs" % (run, "s" if run != 1 else "", timeTaken))
        self.stream.writeln()
        var expectedFails = len(result.expectedFailures)
        var unexpectedSuccesses = len(result.unexpectedSuccesses)
        var skipped = len(result.skipped)
        var infos = []
        if not result.wasSuccessful():
            self.stream.write("FAILED")
            var failed = len(result.failures)
            var errored = len(result.errors)
            if failed:
                infos.append("failures=%d" % failed)
            if errored:
                infos.append("errors=%d" % errored)
        elif run == 0 and not skipped:
            self.stream.write("NO TESTS RAN")
        else:
            self.stream.write("OK")
        if skipped:
            infos.append("skipped=%d" % skipped)
        if expectedFails:
            infos.append("expected failures=%d" % expectedFails)
        if unexpectedSuccesses:
            infos.append("unexpected successes=%d" % unexpectedSuccesses)
        if infos:
            self.stream.writeln(" (" + ", ".join(infos) + ")")
        else:
            self.stream.write("\n")
        self.stream.flush()
        return result


# ── TestCase ─────────────────────────────────────────────────────────────────

class _Outcome:
    def __init__(self, result=none):
        self.expecting_failure = false
        self.result = result
        self.result_supports_subtests = hasattr(result, "addSubTest")
        self.success = true
        self.expectedFailure = none

    # testPartExecutor: run fn(), recording how it ended (CPython's context
    # manager of the same name, as a call).
    def run_part(self, test_case, fn, subTest=false):
        var old_success = self.success
        self.success = true
        try:
            fn()
            if subTest and self.success:
                self.result.addSubTest(test_case.test_case, test_case, none)
        except KeyboardInterrupt:
            raise
        except SkipTest as e:
            self.success = false
            _addSkip(self.result, test_case, str(e))
        except _ShouldStop as _stop:      # `as`: a bare lowercase name would catch everything
            pass
        except BaseException as e2:
            var exc_info = _exc_info_of(e2)
            if self.expecting_failure:
                self.expectedFailure = exc_info
            else:
                self.success = false
                if subTest:
                    self.result.addSubTest(test_case.test_case, test_case, exc_info)
                else:
                    _addError(self.result, test_case, exc_info)
        self.success = self.success and old_success


def _addSkip(result, test_case, reason):
    var addSkip = getattr(result, "addSkip", none)
    if addSkip is not none:
        addSkip(test_case, reason)
    else:
        result.addSuccess(test_case)


def _addError(result, test, exc_info):
    if result is not none and exc_info is not none:
        if issubclass(exc_info[0], test.failureException):
            result.addFailure(test, exc_info)
        else:
            result.addError(test, exc_info)


def _id(obj):
    return obj


def skip(reason):
    """
    Unconditionally skip a test.
    """
    def decorator(test_item):
        if not _is_class(test_item):
            var inner = test_item
            def skip_wrapper(*args, **kwargs):
                raise SkipTest(reason)
            skip_wrapper.__name__ = getattr(inner, "__name__", "skip_wrapper")
            skip_wrapper.__doc__ = getattr(inner, "__doc__", none)
            test_item = skip_wrapper
        test_item.__unittest_skip__ = true
        test_item.__unittest_skip_why__ = reason
        return test_item
    if callable(reason) and not isinstance(reason, str):
        var item = reason
        reason = ""
        return decorator(item)
    return decorator


def skipIf(condition, reason):
    """
    Skip a test if the condition is true.
    """
    if condition:
        return skip(reason)
    return _id


def skipUnless(condition, reason):
    """
    Skip a test unless the condition is true.
    """
    if not condition:
        return skip(reason)
    return _id


def expectedFailure(test_item):
    test_item.__unittest_expecting_failure__ = true
    return test_item


class _BaseTestCaseContext:
    def __init__(self, test_case):
        self.test_case = test_case

    def _raiseFailure(self, standardMsg):
        var msg = self.test_case._formatMessage(self.msg, standardMsg)
        raise self.test_case.failureException(msg)


class _AssertRaisesContext(_BaseTestCaseContext):
    """A context manager used to implement TestCase.assertRaises* methods."""
    def __init__(self, expected, test_case, expected_regex=none):
        _BaseTestCaseContext.__init__(self, test_case)
        self.expected = expected
        self.test_case = test_case
        self.expected_regex = expected_regex
        self.obj_name = none
        self.msg = none
        self.exception = none

    def handle(self, name, args, kwargs):
        """
        If args is empty, assertRaises/Warns is being used as a
        context manager, so check for a 'msg' kwarg and return self.
        If args is not empty, call a callable passing positional and keyword
        arguments.
        """
        var ok = true
        if isinstance(self.expected, tuple):
            for t in self.expected:
                if not (_is_class(t) and issubclass(t, BaseException)):
                    ok = false
        elif not (_is_class(self.expected) and issubclass(self.expected, BaseException)):
            ok = false
        if not ok:
            raise TypeError(name + "() arg 1 must be an exception type or tuple of exception types")
        if not args:
            self.msg = kwargs.pop("msg", none)
            if kwargs:
                raise TypeError(repr(list(kwargs.keys())[0]) + " is an invalid keyword argument for this function")
            return self
        var callable_obj = args[0]
        var rest = list(args[1:])
        self.obj_name = getattr(callable_obj, "__name__", none)
        if self.obj_name is none:
            self.obj_name = str(callable_obj)
        var raised = none
        try:
            callable_obj(*rest, **kwargs)
        except BaseException as e:
            raised = e
        if raised is none:
            self.__exit__(none, none, none)
        elif not self.__exit__(_class_of(raised), raised, none):
            raise raised
        return none

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, tb):
        if exc_type is none:
            var exc_name = getattr(self.expected, "__name__", none)
            if exc_name is none:
                exc_name = str(self.expected)
            if self.obj_name:
                self._raiseFailure(exc_name + " not raised by " + str(self.obj_name))
            else:
                self._raiseFailure(exc_name + " not raised")
        if not issubclass(exc_type, self.expected):
            # let unexpected exceptions pass through
            return false
        # store exception, without traceback, for later retrieval
        self.exception = exc_value
        if self.expected_regex is none:
            return true
        var expected_regex = self.expected_regex
        if _re_search(expected_regex, str(exc_value)) is none:
            self._raiseFailure("\"" + _pattern_text(expected_regex) + "\" does not match \"" + str(exc_value) + "\"")
        return true


class _UtLoggingWatcher:
    def __init__(self, records, output):
        self.records = records
        self.output = output

    def __getitem__(self, i):
        return [self.records, self.output][i]

    def __repr__(self):
        return "_LoggingWatcher(records=" + repr(self.records) + ", output=" + repr(self.output) + ")"


class _AssertLogsContext(_BaseTestCaseContext):
    """A context manager for assertLogs() and assertNoLogs() """
    LOGGING_FORMAT = "%(levelname)s:%(name)s:%(message)s"

    def __init__(self, test_case, logger_name, level, no_logs):
        _BaseTestCaseContext.__init__(self, test_case)
        import logging
        self._logging = logging
        self.logger_name = logger_name
        if level:
            self.level = logging._nameToLevel.get(level, level)
        else:
            self.level = logging.INFO
        self.msg = none
        self.no_logs = no_logs

    def __enter__(self):
        var logging = self._logging
        var logger = none
        if isinstance(self.logger_name, logging.Logger):
            logger = self.logger_name
        else:
            logger = logging.getLogger(self.logger_name)
        self.logger = logger
        var formatter = logging.Formatter(self.LOGGING_FORMAT)
        var watcher = _UtLoggingWatcher([], [])
        var handler = logging.Handler()
        def _emit(record):
            watcher.records.append(record)
            watcher.output.append(handler.format(record))
        handler.emit = _emit
        handler.flush = lambda: none
        handler.setLevel(self.level)
        handler.setFormatter(formatter)
        self.watcher = watcher
        self.old_handlers = list(logger.handlers)
        self.old_level = logger.level
        self.old_propagate = logger.propagate
        logger.handlers = [handler]
        logger.setLevel(self.level)
        logger.propagate = false
        if self.no_logs:
            return none
        return watcher

    def __exit__(self, exc_type, exc_value, tb):
        self.logger.handlers = self.old_handlers
        self.logger.propagate = self.old_propagate
        self.logger.setLevel(self.old_level)
        if exc_type is not none:
            # let unexpected exceptions pass through
            return false
        if self.no_logs:
            # assertNoLogs
            if len(self.watcher.records) > 0:
                self._raiseFailure("Unexpected logs found: " + repr(self.watcher.output))
        else:
            # assertLogs
            if len(self.watcher.records) == 0:
                self._raiseFailure("no logs of level " + str(self._logging.getLevelName(self.level)) + " or higher triggered on " + self.logger.name)
        return false


class _SubTestCM:
    # The context manager subTest() returns.
    def __init__(self, case, msg, params):
        self.case = case
        self.msg = msg
        self.params = params
        self.parent = none
        self.active = false

    def __enter__(self):
        var case = self.case
        if case._outcome is none or not case._outcome.result_supports_subtests:
            return none
        self.active = true
        self.parent = case._subtest
        var params_map = {}
        if self.parent is not none:
            for k in self.parent.params:
                params_map[k] = self.parent.params[k]
        for k2 in self.params:
            params_map[k2] = self.params[k2]
        case._subtest = _SubTest(case, self.msg, params_map)
        self.old_success = case._outcome.success
        case._outcome.success = true
        return none

    def __exit__(self, exc_type, exc_value, tb):
        if not self.active:
            return false
        var case = self.case
        var outcome = case._outcome
        var sub = case._subtest
        var suppress = true
        try:
            if exc_type is none:
                if outcome.success:
                    outcome.result.addSubTest(case, sub, none)
            elif issubclass(exc_type, KeyboardInterrupt):
                suppress = false
            elif issubclass(exc_type, SkipTest):
                outcome.success = false
                _addSkip(outcome.result, sub, str(exc_value))
            elif issubclass(exc_type, _ShouldStop):
                pass
            elif outcome.expecting_failure:
                outcome.expectedFailure = (exc_type, exc_value, none)
            else:
                outcome.success = false
                outcome.result.addSubTest(case, sub, (exc_type, exc_value, none))
            outcome.success = outcome.success and self.old_success
            if suppress:
                if not outcome.success:
                    var result = outcome.result
                    if result is not none and result.failfast:
                        raise _ShouldStop()
                elif outcome.expectedFailure:
                    raise _ShouldStop()
        finally:
            case._subtest = self.parent
        return suppress


_subtest_msg_sentinel = ["<subtest sentinel>"]


class TestCase:
    """A class whose instances are single test cases.

    By default, the test code itself should be placed in a method named
    'runTest'.

    If the fixture may be used for many test cases, create as
    many test methods as are needed. When instantiating such a TestCase
    subclass, specify in the constructor arguments the name of the test method
    that the instance is to execute.

    Test authors should subclass TestCase for their own tests. Construction
    and deconstruction of the test's environment ('fixture') can be
    implemented by overriding the 'setUp' and 'tearDown' methods respectively.

    If it is necessary to override the __init__ method, the base class
    __init__ method must always be called. It is important that subclasses
    should not change the signature of their __init__ method, since instances
    of the classes are instantiated automatically by parts of the framework
    in order to be run.
    """
    failureException = AssertionError
    longMessage = true
    maxDiff = 80 * 8
    _diffThreshold = 2 ** 16
    _classSetupFailed = false
    _class_cleanups = []

    def __init__(self, methodName="runTest"):
        """Create an instance of the class that will use the named test
           method when executed. Raises a ValueError if the instance does
           not have a method with the specified name.
        """
        self._testMethodName = methodName
        self._outcome = none
        self._testMethodDoc = "No test"
        var cls = _class_of(self)
        if not hasattr(cls, methodName):
            if methodName != "runTest":
                # we allow instantiation with no explicit method name
                # but not an *incorrect* or missing method name
                raise ValueError("no such test method in " + str(cls) + ": " + methodName)
        else:
            self._testMethodDoc = getattr(getattr(cls, methodName), "__doc__", none)
        self._cleanups = []
        self._subtest = none
        # Map types to custom assertEqual functions that will compare
        # instances of said type in more detail to generate a more useful
        # error message.
        self._type_equality_funcs = {}
        self.addTypeEqualityFunc(dict, "assertDictEqual")
        self.addTypeEqualityFunc(list, "assertListEqual")
        self.addTypeEqualityFunc(tuple, "assertTupleEqual")
        self.addTypeEqualityFunc(set, "assertSetEqual")
        self.addTypeEqualityFunc(frozenset, "assertSetEqual")
        self.addTypeEqualityFunc(str, "assertMultiLineEqual")

    def addTypeEqualityFunc(self, typeobj, function):
        """Add a type specific assertEqual style function to compare a type.

        This method is for use by TestCase subclasses that need to register
        their own type equality functions to provide nicer error messages.
        """
        self._type_equality_funcs[_kind_of_type(typeobj)] = function

    def addCleanup(self, function, *args, **kwargs):
        """Add a function, with arguments, to be called when the test is
        completed. Functions added are called on a LIFO basis and are
        called after tearDown on test failure or success.

        Cleanup items are called even if setUp fails (unlike tearDown)."""
        self._cleanups.append((function, args, kwargs))

    def enterContext(self, cm):
        """Enters the supplied context manager.

        If successful, also adds its __exit__ method as a cleanup
        function and returns the result of the __enter__ method.
        """
        var result = cm.__enter__()
        self.addCleanup(cm.__exit__, none, none, none)
        return result

    @classmethod
    def addClassCleanup(cls, function, *args, **kwargs):
        """Same as addCleanup, except the cleanup items are called even if
        setUpClass fails (unlike tearDownClass)."""
        cls._class_cleanups.append((function, args, kwargs))

    @classmethod
    def enterClassContext(cls, cm):
        """Same as enterContext, but class-wide."""
        var result = cm.__enter__()
        cls.addClassCleanup(cm.__exit__, none, none, none)
        return result

    def setUp(self):
        "Hook method for setting up the test fixture before exercising it."
        pass

    def tearDown(self):
        "Hook method for deconstructing the test fixture after testing it."
        pass

    @classmethod
    def setUpClass(cls):
        "Hook method for setting up class fixture before running tests in the class."
        pass

    @classmethod
    def tearDownClass(cls):
        "Hook method for deconstructing the class fixture after running all tests in the class."
        pass

    def countTestCases(self):
        return 1

    def defaultTestResult(self):
        return TestResult()

    def shortDescription(self):
        """Returns a one-line description of the test, or None if no
        description has been provided.

        The default implementation of this method returns the first line of
        the specified test method's docstring.
        """
        var doc = self._testMethodDoc
        if not doc or not isinstance(doc, str):
            return none
        return doc.strip().split("\n")[0].strip()

    def id(self):
        return strclass(_class_of(self)) + "." + self._testMethodName

    def __eq__(self, other):
        if not isinstance(other, TestCase):
            return false
        return _same(_class_of(self), _class_of(other)) and self._testMethodName == other._testMethodName

    def __hash__(self):
        return hash((strclass(_class_of(self)), self._testMethodName))

    def __str__(self):
        return self._testMethodName + " (" + strclass(_class_of(self)) + "." + self._testMethodName + ")"

    def __repr__(self):
        return "<" + strclass(_class_of(self)) + " testMethod=" + self._testMethodName + ">"

    def subTest(self, msg=_subtest_msg_sentinel, **params):
        """Return a context manager that will return the enclosed block
        of code in a subtest identified by the optional message and
        keyword parameters.  A failure in the subtest marks the test
        case as failed but resumes execution at the end of the enclosed
        block, allowing further test code to be executed.
        """
        return _SubTestCM(self, msg, params)

    def _addExpectedFailure(self, result, exc_info):
        var addExpectedFailure = getattr(result, "addExpectedFailure", none)
        if addExpectedFailure is not none:
            addExpectedFailure(self, exc_info)
        else:
            result.addSuccess(self)

    def _addUnexpectedSuccess(self, result):
        var addUnexpectedSuccess = getattr(result, "addUnexpectedSuccess", none)
        if addUnexpectedSuccess is not none:
            addUnexpectedSuccess(self)
        else:
            # The test was supposed to fail, but it didn't
            try:
                raise _UnexpectedSuccess()
            except _UnexpectedSuccess as e:
                result.addFailure(self, _exc_info_of(e))

    def _callSetUp(self):
        self.setUp()

    def _callTestMethod(self, method):
        method()

    def _callTearDown(self):
        self.tearDown()

    def _callCleanup(self, function, *args, **kwargs):
        function(*args, **kwargs)

    def run(self, result=none):
        var stopTestRun = none
        if result is none:
            result = self.defaultTestResult()
            var startTestRun = getattr(result, "startTestRun", none)
            stopTestRun = getattr(result, "stopTestRun", none)
            if startTestRun is not none:
                startTestRun()
        result.startTest(self)
        var start_time = perf_counter()
        try:
            var cls = _class_of(self)
            var classMethod = getattr(cls, self._testMethodName, none)
            var testMethod = getattr(self, self._testMethodName)
            if getattr(cls, "__unittest_skip__", false) or getattr(classMethod, "__unittest_skip__", false):
                # If the class or method was skipped.
                var skip_why = getattr(cls, "__unittest_skip_why__", "") or getattr(classMethod, "__unittest_skip_why__", "")
                _addSkip(result, self, skip_why)
                return result
            var expecting_failure = getattr(cls, "__unittest_expecting_failure__", false) or getattr(classMethod, "__unittest_expecting_failure__", false)
            var outcome = _Outcome(result)
            var me = self
            try:
                self._outcome = outcome
                outcome.run_part(self, lambda: me._callSetUp())
                if outcome.success:
                    outcome.expecting_failure = expecting_failure
                    outcome.run_part(self, lambda: me._callTestMethod(testMethod))
                    outcome.expecting_failure = false
                    outcome.run_part(self, lambda: me._callTearDown())
                self.doCleanups()
                if hasattr(result, "addDuration"):
                    result.addDuration(self, perf_counter() - start_time)
                if outcome.success:
                    if expecting_failure:
                        if outcome.expectedFailure:
                            self._addExpectedFailure(result, outcome.expectedFailure)
                        else:
                            self._addUnexpectedSuccess(result)
                    else:
                        result.addSuccess(self)
                return result
            finally:
                outcome.expectedFailure = none
                self._outcome = none
        finally:
            result.stopTest(self)
            if stopTestRun is not none:
                stopTestRun()

    def doCleanups(self):
        """Execute all cleanup functions. Normally called for you after
        tearDown."""
        var outcome = self._outcome or _Outcome()
        var me = self
        while self._cleanups:
            var entry = self._cleanups.pop()
            outcome.run_part(self, lambda: me._callCleanup(entry[0], *entry[1], **entry[2]))
        # return this for backwards compatibility
        # even though we no longer use it internally
        return outcome.success

    @classmethod
    def doClassCleanups(cls):
        """Execute all class cleanup functions. Normally called for you after
        tearDownClass."""
        cls.tearDown_exceptions = []
        while cls._class_cleanups:
            var entry = cls._class_cleanups.pop()
            try:
                entry[0](*entry[1], **entry[2])
            except Exception as e:
                cls.tearDown_exceptions.append(_exc_info_of(e))

    def __call__(self, *args, **kwds):
        return self.run(*args, **kwds)

    def debug(self):
        """Run the test without collecting errors in a TestResult"""
        var cls = _class_of(self)
        var classMethod = getattr(cls, self._testMethodName, none)
        if getattr(cls, "__unittest_skip__", false) or getattr(classMethod, "__unittest_skip__", false):
            # If the class or method was skipped.
            var skip_why = getattr(cls, "__unittest_skip_why__", "") or getattr(classMethod, "__unittest_skip_why__", "")
            raise SkipTest(skip_why)
        self._callSetUp()
        self._callTestMethod(getattr(self, self._testMethodName))
        self._callTearDown()
        while self._cleanups:
            var entry = self._cleanups.pop()
            self._callCleanup(entry[0], *entry[1], **entry[2])

    def skipTest(self, reason):
        """Skip this test."""
        raise SkipTest(reason)

    def fail(self, msg=none):
        """Fail immediately, with the given message."""
        raise self.failureException(msg)

    def assertFalse(self, expr, msg=none):
        """Check that the expression is false."""
        if expr:
            msg = self._formatMessage(msg, safe_repr(expr) + " is not false")
            raise self.failureException(msg)

    def assertTrue(self, expr, msg=none):
        """Check that the expression is true."""
        if not expr:
            msg = self._formatMessage(msg, safe_repr(expr) + " is not true")
            raise self.failureException(msg)

    def _formatMessage(self, msg, standardMsg):
        """Honour the longMessage attribute when generating failure messages.
        If longMessage is False this means:
        * Use only an explicit message if it is provided
        * Otherwise use the standard message for the assert

        If longMessage is True:
        * Use the standard message
        * If an explicit message is provided, plus ' : ' and the explicit message
        """
        if not self.longMessage:
            return msg or standardMsg
        if msg is none:
            return standardMsg
        return standardMsg + " : " + str(msg)

    def assertRaises(self, expected_exception, *args, **kwargs):
        """Fail unless an exception of class expected_exception is raised
           by the callable when invoked with specified positional and
           keyword arguments. If a different type of exception is
           raised, it will not be caught, and the test case will be
           deemed to have suffered an error, exactly as for an
           unexpected exception.

           If called with the callable and arguments omitted, will return a
           context object used like this::

                with self.assertRaises(SomeException):
                    do_something()

           The context manager keeps a reference to the exception as
           the 'exception' attribute. This allows you to inspect the
           exception after the assertion::

               with self.assertRaises(SomeException) as cm:
                   do_something()
               the_exception = cm.exception
               self.assertEqual(the_exception.error_code, 3)
        """
        var context = _AssertRaisesContext(expected_exception, self)
        return context.handle("assertRaises", args, kwargs)

    def assertRaisesRegex(self, expected_exception, expected_regex, *args, **kwargs):
        """Asserts that the message in a raised exception matches a regex.

        Args:
            expected_exception: Exception class expected to be raised.
            expected_regex: Regex (re.Pattern object or string) expected
                    to be found in error message.
            args: Function to be called and extra positional args.
            kwargs: Extra kwargs.
            msg: Optional message used in case of failure. Can only be used
                    when assertRaisesRegex is used as a context manager.
        """
        var context = _AssertRaisesContext(expected_exception, self, expected_regex)
        return context.handle("assertRaisesRegex", args, kwargs)

    def assertLogs(self, logger=none, level=none):
        """Fail unless a log message of level *level* or higher is emitted
        on *logger_name* or its children.  If omitted, *level* defaults to
        INFO and *logger* defaults to the root logger.

        This method must be used as a context manager, and will yield
        a recording object with two attributes: `output` and `records`.
        """
        return _AssertLogsContext(self, logger, level, false)

    def assertNoLogs(self, logger=none, level=none):
        """ Fail unless no log messages of level *level* or higher are emitted
        on *logger_name* or its children.

        This method must be used as a context manager.
        """
        return _AssertLogsContext(self, logger, level, true)

    def _getAssertEqualityFunc(self, first, second):
        """Get a detailed comparison function for the types of the two args.

        Returns: A callable accepting (first, second, msg=None) that will
        raise a failure exception if first != second with a useful human
        readable error message for those types.
        """
        var k1 = _kind_of(first)
        if k1 == _kind_of(second) and _same_class(first, second):
            var asserter = self._type_equality_funcs.get(k1)
            if asserter is not none:
                if isinstance(asserter, str):
                    asserter = getattr(self, asserter)
                return asserter
        return self._baseAssertEqual

    def _baseAssertEqual(self, first, second, msg=none):
        """The default assertEqual implementation, not type specific."""
        if not first == second:
            var reps = _common_shorten_repr(first, second)
            var standardMsg = reps[0] + " != " + reps[1]
            msg = self._formatMessage(msg, standardMsg)
            raise self.failureException(msg)

    def assertEqual(self, first, second, msg=none):
        """Fail if the two objects are unequal as determined by the '=='
           operator.
        """
        var assertion_func = self._getAssertEqualityFunc(first, second)
        assertion_func(first, second, msg)

    def assertNotEqual(self, first, second, msg=none):
        """Fail if the two objects are equal as determined by the '!='
           operator.
        """
        if not first != second:
            msg = self._formatMessage(msg, safe_repr(first) + " == " + safe_repr(second))
            raise self.failureException(msg)

    def assertAlmostEqual(self, first, second, places=none, msg=none, delta=none):
        """Fail if the two objects are unequal as determined by their
           difference rounded to the given number of decimal places
           (default 7) and comparing to zero, or by comparing that the
           difference between the two objects is more than the given
           delta.
        """
        if first == second:
            # shortcut
            return
        if delta is not none and places is not none:
            raise TypeError("specify delta or places not both")
        var diff = abs(first - second)
        var standardMsg = ""
        if delta is not none:
            if diff <= delta:
                return
            standardMsg = safe_repr(first) + " != " + safe_repr(second) + " within " + safe_repr(delta) + " delta (" + safe_repr(diff) + " difference)"
        else:
            if places is none:
                places = 7
            if round(diff, places) == 0:
                return
            standardMsg = safe_repr(first) + " != " + safe_repr(second) + " within " + repr(places) + " places (" + safe_repr(diff) + " difference)"
        msg = self._formatMessage(msg, standardMsg)
        raise self.failureException(msg)

    def assertNotAlmostEqual(self, first, second, places=none, msg=none, delta=none):
        """Fail if the two objects are equal as determined by their
           difference rounded to the given number of decimal places
           (default 7) and comparing to zero, or by comparing that the
           difference between the two objects is less than the given delta.
        """
        if delta is not none and places is not none:
            raise TypeError("specify delta or places not both")
        var diff = abs(first - second)
        var standardMsg = ""
        if delta is not none:
            if not (first == second) and diff > delta:
                return
            standardMsg = safe_repr(first) + " == " + safe_repr(second) + " within " + safe_repr(delta) + " delta (" + safe_repr(diff) + " difference)"
        else:
            if places is none:
                places = 7
            if not (first == second) and round(diff, places) != 0:
                return
            standardMsg = safe_repr(first) + " == " + safe_repr(second) + " within " + repr(places) + " places"
        msg = self._formatMessage(msg, standardMsg)
        raise self.failureException(msg)

    def assertSequenceEqual(self, seq1, seq2, msg=none, seq_type=none):
        """An equality assertion for ordered sequences (like lists and tuples).

        For the purposes of this function, a valid ordered sequence type is one
        which can be indexed, has a length, and has an equality operator.
        """
        var seq_type_name = "sequence"
        if seq_type is not none:
            seq_type_name = _kind_of_type(seq_type)
            if not isinstance(seq1, seq_type):
                raise self.failureException("First sequence is not a " + seq_type_name + ": " + safe_repr(seq1))
            if not isinstance(seq2, seq_type):
                raise self.failureException("Second sequence is not a " + seq_type_name + ": " + safe_repr(seq2))
        var differing = none
        var len1 = 0
        var len2 = 0
        try:
            len1 = len(seq1)
        except Exception:
            differing = "First " + seq_type_name + " has no length.    Non-sequence?"
        if differing is none:
            try:
                len2 = len(seq2)
            except Exception:
                differing = "Second " + seq_type_name + " has no length.    Non-sequence?"
        if differing is none:
            if seq1 == seq2:
                return
            var reps = _common_shorten_repr(seq1, seq2)
            differing = seq_type_name.capitalize() + "s differ: " + reps[0] + " != " + reps[1] + "\n"
            var found = false
            var i = 0
            var n = min(len1, len2)
            while i < n:
                var item1 = seq1[i]
                var item2 = seq2[i]
                if item1 != item2:
                    var r2 = _common_shorten_repr(item1, item2)
                    differing = differing + "\nFirst differing element " + str(i) + ":\n" + r2[0] + "\n" + r2[1] + "\n"
                    found = true
                    break
                i = i + 1
            if not found:
                if len1 == len2 and seq_type is none and not _same_class(seq1, seq2):
                    # The sequences are the same, but have differing types.
                    return
            if len1 > len2:
                differing = differing + "\nFirst " + seq_type_name + " contains " + str(len1 - len2) + " additional elements.\n"
                differing = differing + "First extra element " + str(len2) + ":\n" + safe_repr(seq1[len2]) + "\n"
            elif len1 < len2:
                differing = differing + "\nSecond " + seq_type_name + " contains " + str(len2 - len1) + " additional elements.\n"
                differing = differing + "First extra element " + str(len1) + ":\n" + safe_repr(seq2[len1]) + "\n"
        var standardMsg = differing
        var diffMsg = "\n" + "\n".join(_ndiff(_splitlines(_pformat(seq1)), _splitlines(_pformat(seq2))))
        standardMsg = self._truncateMessage(standardMsg, diffMsg)
        msg = self._formatMessage(msg, standardMsg)
        self.fail(msg)

    def _truncateMessage(self, message, diff):
        var max_diff = self.maxDiff
        if max_diff is none or len(diff) <= max_diff:
            return message + diff
        return message + (DIFF_OMITTED % len(diff))

    def assertListEqual(self, list1, list2, msg=none):
        """A list-specific equality assertion."""
        self.assertSequenceEqual(list1, list2, msg, list)

    def assertTupleEqual(self, tuple1, tuple2, msg=none):
        """A tuple-specific equality assertion."""
        self.assertSequenceEqual(tuple1, tuple2, msg, tuple)

    def assertSetEqual(self, set1, set2, msg=none):
        """A set-specific equality assertion."""
        var difference1 = none
        var difference2 = none
        try:
            difference1 = set1.difference(set2)
        except TypeError as e:
            self.fail("invalid type when attempting set difference: " + str(e))
        except AttributeError as e2:
            self.fail("first argument does not support set difference: " + str(e2))
        try:
            difference2 = set2.difference(set1)
        except TypeError as e3:
            self.fail("invalid type when attempting set difference: " + str(e3))
        except AttributeError as e4:
            self.fail("second argument does not support set difference: " + str(e4))
        if not (difference1 or difference2):
            return
        var lines = []
        if difference1:
            lines.append("Items in the first set but not the second:")
            for item in difference1:
                lines.append(_py_repr(item))
        if difference2:
            lines.append("Items in the second set but not the first:")
            for item2 in difference2:
                lines.append(_py_repr(item2))
        var standardMsg = "\n".join(lines)
        self.fail(self._formatMessage(msg, standardMsg))

    def assertIn(self, member, container, msg=none):
        """Just like self.assertTrue(a in b), but with a nicer default message."""
        if member not in container:
            var standardMsg = safe_repr(member) + " not found in " + safe_repr(container)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertNotIn(self, member, container, msg=none):
        """Just like self.assertTrue(a not in b), but with a nicer default message."""
        if member in container:
            var standardMsg = safe_repr(member) + " unexpectedly found in " + safe_repr(container)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertIs(self, expr1, expr2, msg=none):
        """Just like self.assertTrue(a is b), but with a nicer default message."""
        if not _same(expr1, expr2) and not (expr1 is none and expr2 is none):
            var standardMsg = safe_repr(expr1) + " is not " + safe_repr(expr2)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertIsNot(self, expr1, expr2, msg=none):
        """Just like self.assertTrue(a is not b), but with a nicer default message."""
        if _same(expr1, expr2) or (expr1 is none and expr2 is none):
            var standardMsg = "unexpectedly identical: " + safe_repr(expr1)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertDictEqual(self, d1, d2, msg=none):
        self.assertIsInstance(d1, dict, "First argument is not a dictionary")
        self.assertIsInstance(d2, dict, "Second argument is not a dictionary")
        if d1 != d2:
            var reps = _common_shorten_repr(d1, d2)
            var standardMsg = reps[0] + " != " + reps[1]
            var diff = "\n" + "\n".join(_ndiff(_splitlines(_pformat(d1)), _splitlines(_pformat(d2))))
            standardMsg = self._truncateMessage(standardMsg, diff)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertCountEqual(self, first, second, msg=none):
        """Asserts that two iterables have the same elements, the same number of
        times, without regard to order.

            self.assertEqual(Counter(list(first)),
                             Counter(list(second)))

         Example:
            - [0, 1, 1] and [1, 0, 1] compare equal.
            - [0, 0, 1] and [0, 1] compare unequal.
        """
        var differences = _count_diff_all_purpose(list(first), list(second))
        if differences:
            var standardMsg = "Element counts were not equal:\n"
            var lines = []
            for d in differences:
                lines.append("First has " + str(d[0]) + ", Second has " + str(d[1]) + ":  " + _py_repr(d[2]))
            var diffMsg = "\n".join(lines)
            standardMsg = self._truncateMessage(standardMsg, diffMsg)
            msg = self._formatMessage(msg, standardMsg)
            self.fail(msg)

    def assertMultiLineEqual(self, first, second, msg=none):
        """Assert that two multi-line strings are equal."""
        self.assertIsInstance(first, str, "First argument is not a string")
        self.assertIsInstance(second, str, "Second argument is not a string")
        if first != second:
            # Don't use difflib if the strings are too long
            if len(first) > self._diffThreshold or len(second) > self._diffThreshold:
                self._baseAssertEqual(first, second, msg)
            # Append \n to both strings if either is missing the \n.
            # This allows the final ndiff to show the \n difference. The
            # exception here is if the string is empty, in which case no
            # \n should be added
            var first_presplit = first
            var second_presplit = second
            if first and second:
                if first[-1] != "\n" or second[-1] != "\n":
                    first_presplit = first_presplit + "\n"
                    second_presplit = second_presplit + "\n"
            elif second and second[-1] != "\n":
                second_presplit = second_presplit + "\n"
            elif first and first[-1] != "\n":
                first_presplit = first_presplit + "\n"
            var firstlines = _splitlines(first_presplit, true)
            var secondlines = _splitlines(second_presplit, true)
            # Generate the message and diff, then raise the exception
            var reps = _common_shorten_repr(first, second)
            var standardMsg = reps[0] + " != " + reps[1]
            var diff = "\n" + "".join(_ndiff(firstlines, secondlines))
            standardMsg = self._truncateMessage(standardMsg, diff)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertLess(self, a, b, msg=none):
        """Just like self.assertTrue(a < b), but with a nicer default message."""
        if not a < b:
            var standardMsg = safe_repr(a) + " not less than " + safe_repr(b)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertLessEqual(self, a, b, msg=none):
        """Just like self.assertTrue(a <= b), but with a nicer default message."""
        if not a <= b:
            var standardMsg = safe_repr(a) + " not less than or equal to " + safe_repr(b)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertGreater(self, a, b, msg=none):
        """Just like self.assertTrue(a > b), but with a nicer default message."""
        if not a > b:
            var standardMsg = safe_repr(a) + " not greater than " + safe_repr(b)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertGreaterEqual(self, a, b, msg=none):
        """Just like self.assertTrue(a >= b), but with a nicer default message."""
        if not a >= b:
            var standardMsg = safe_repr(a) + " not greater than or equal to " + safe_repr(b)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertIsNone(self, obj, msg=none):
        """Same as self.assertTrue(obj is None), with a nicer default message."""
        if obj is not none:
            var standardMsg = safe_repr(obj) + " is not None"
            self.fail(self._formatMessage(msg, standardMsg))

    def assertIsNotNone(self, obj, msg=none):
        """Included for symmetry with assertIsNone."""
        if obj is none:
            var standardMsg = "unexpectedly None"
            self.fail(self._formatMessage(msg, standardMsg))

    def assertIsInstance(self, obj, cls, msg=none):
        """Same as self.assertTrue(isinstance(obj, cls)), with a nicer
        default message."""
        if not isinstance(obj, cls):
            var standardMsg = safe_repr(obj) + " is not an instance of " + _type_repr(cls)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertNotIsInstance(self, obj, cls, msg=none):
        """Included for symmetry with assertIsInstance."""
        if isinstance(obj, cls):
            var standardMsg = safe_repr(obj) + " is an instance of " + _type_repr(cls)
            self.fail(self._formatMessage(msg, standardMsg))

    def assertRegex(self, text, expected_regex, msg=none):
        """Fail the test unless the text matches the regular expression."""
        if _re_search(expected_regex, text) is none:
            var standardMsg = "Regex didn't match: " + repr(_pattern_text(expected_regex)) + " not found in " + repr(text)
            msg = self._formatMessage(msg, standardMsg)
            raise self.failureException(msg)

    def assertNotRegex(self, text, unexpected_regex, msg=none):
        """Fail the test if the text matches the regular expression."""
        var m = _re_search(unexpected_regex, text)
        if m is not none:
            var standardMsg = "Regex matched: " + repr(m) + " matches " + repr(_pattern_text(unexpected_regex)) + " in " + repr(text)
            msg = self._formatMessage(msg, standardMsg)
            raise self.failureException(msg)


def _type_repr(cls):
    # %r of a class: "<class 'int'>"; a tuple of classes as a tuple
    if isinstance(cls, tuple):
        if len(cls) == 1:
            return "(" + _type_repr(cls[0]) + ",)"
        return "(" + ", ".join([_type_repr(c) for c in cls]) + ")"
    var name = getattr(cls, "__name__", none)
    if name is none:
        return repr(cls)
    if name in ["int", "str", "float", "bool", "list", "tuple", "dict", "set", "frozenset", "bytes", "bytearray", "complex", "object", "type", "map"]:
        return "<class '" + ("dict" if name == "map" else name) + "'>"
    var mod = getattr(cls, "__module__", none)
    if not mod or not isinstance(mod, str):
        mod = "__main__"
    if mod == "builtins" or (mod == "__main__" and _is_builtin_exc_name(name)):
        return "<class '" + name + "'>"
    return "<class '" + mod + "." + name + "'>"


_BUILTIN_EXC_NAMES = ["BaseException", "Exception", "ValueError", "TypeError", "KeyError",
                      "IndexError", "AttributeError", "NameError", "RuntimeError", "OSError",
                      "FileNotFoundError", "ZeroDivisionError", "ArithmeticError", "LookupError",
                      "AssertionError", "StopIteration", "NotImplementedError", "OverflowError",
                      "PermissionError", "FileExistsError", "IsADirectoryError",
                      "NotADirectoryError", "TimeoutError", "UnicodeError", "SystemExit",
                      "KeyboardInterrupt", "RecursionError", "ImportError", "ModuleNotFoundError",
                      "EOFError", "MemoryError", "ConnectionError", "BrokenPipeError"]


def _is_builtin_exc_name(name):
    return name in _BUILTIN_EXC_NAMES


def _count_diff_all_purpose(actual, expected):
    "Returns list of (cnt_act, cnt_exp, elem) triples where the counts differ"
    # elements need not be hashable
    var s = list(actual)
    var t = list(expected)
    var m = len(s)
    var n = len(t)
    var used_s = [false] * m
    var used_t = [false] * n
    var result = []
    var i = 0
    while i < m:
        if used_s[i]:
            i = i + 1
            continue
        var elem = s[i]
        var cnt_s = 0
        var cnt_t = 0
        var j = i
        while j < m:
            if not used_s[j] and s[j] == elem:
                cnt_s = cnt_s + 1
                used_s[j] = true
            j = j + 1
        var k = 0
        while k < n:
            if not used_t[k] and t[k] == elem:
                cnt_t = cnt_t + 1
                used_t[k] = true
            k = k + 1
        if cnt_s != cnt_t:
            result.append((cnt_s, cnt_t, elem))
        i = i + 1
    i = 0
    while i < n:
        if used_t[i]:
            i = i + 1
            continue
        var elem2 = t[i]
        var cnt = 0
        var j2 = i
        while j2 < n:
            if not used_t[j2] and t[j2] == elem2:
                cnt = cnt + 1
                used_t[j2] = true
            j2 = j2 + 1
        result.append((0, cnt, elem2))
        i = i + 1
    return result


class FunctionTestCase(TestCase):
    """A test case that wraps a test function.

    This is useful for slipping pre-existing test functions into the
    unittest framework. Optionally, set-up and tidy-up functions can be
    supplied. As with TestCase, the tidy-up ('tearDown') function will
    always be called if the set-up ('setUp') function ran successfully.
    """
    def __init__(self, testFunc, setUp=none, tearDown=none, description=none):
        TestCase.__init__(self)
        self._setUpFunc = setUp
        self._tearDownFunc = tearDown
        self._testFunc = testFunc
        self._description = description

    def setUp(self):
        if self._setUpFunc is not none:
            self._setUpFunc()

    def tearDown(self):
        if self._tearDownFunc is not none:
            self._tearDownFunc()

    def runTest(self):
        self._testFunc()

    def run(self, result=none):
        self._testMethodName = "runTest"
        return TestCase.run(self, result)

    def id(self):
        return getattr(self._testFunc, "__name__", "<function>")

    def __eq__(self, other):
        if not isinstance(other, FunctionTestCase):
            return false
        return _same(self._setUpFunc, other._setUpFunc) and _same(self._tearDownFunc, other._tearDownFunc) and _same(self._testFunc, other._testFunc) and self._description == other._description

    def __hash__(self):
        return hash((_obj_id(self._setUpFunc), _obj_id(self._tearDownFunc), _obj_id(self._testFunc), self._description))

    def __str__(self):
        return strclass(_class_of(self)) + " (" + getattr(self._testFunc, "__name__", "<function>") + ")"

    def __repr__(self):
        return "<" + strclass(_class_of(self)) + " tec=" + repr(self._testFunc) + ">"

    def shortDescription(self):
        if self._description is not none:
            return self._description
        var doc = getattr(self._testFunc, "__doc__", none)
        if doc and isinstance(doc, str):
            return doc.split("\n")[0].strip()
        return none


class _SubTest(TestCase):
    def __init__(self, test_case, message, params):
        TestCase.__init__(self)
        self._message = message
        self.test_case = test_case
        self.params = params
        self.failureException = test_case.failureException

    def runTest(self):
        raise NotImplementedError("subtests cannot be run directly")

    def _subDescription(self):
        var parts = []
        if not _same(self._message, _subtest_msg_sentinel):
            parts.append("[" + str(self._message) + "]")
        if self.params:
            var descs = []
            for k in self.params:
                descs.append(str(k) + "=" + _py_repr(self.params[k]))
            parts.append("(" + ", ".join(descs) + ")")
        return " ".join(parts) or "(<subtest>)"

    def id(self):
        return self.test_case.id() + " " + self._subDescription()

    def shortDescription(self):
        """Returns a one-line description of the subtest, or None if no
        description has been provided.
        """
        return self.test_case.shortDescription()

    def __str__(self):
        return str(self.test_case) + " " + self._subDescription()


# ── suites ───────────────────────────────────────────────────────────────────

class BaseTestSuite:
    """A simple test suite that doesn't provide class or module shared fixtures.
    """
    _cleanup = true

    def __init__(self, tests=()):
        self._tests = []
        self._removed_tests = 0
        self.addTests(tests)

    def __repr__(self):
        return "<" + strclass(_class_of(self)) + " tests=" + repr(list(self)) + ">"

    def __eq__(self, other):
        if not isinstance(other, BaseTestSuite):
            return false
        return list(self) == list(other)

    def __iter__(self):
        return iter(self._tests)

    def countTestCases(self):
        var cases = self._removed_tests
        for test in self:
            if test:
                cases = cases + test.countTestCases()
        return cases

    def addTest(self, test):
        # sanity checks
        if not callable(test):
            raise TypeError(repr(test) + " is not callable")
        if _is_class(test) and (issubclass(test, TestCase) or issubclass(test, TestSuite)):
            raise TypeError("TestCases and TestSuites must be instantiated before passing them to addTest()")
        self._tests.append(test)

    def addTests(self, tests):
        if isinstance(tests, str):
            raise TypeError("tests must be an iterable of tests, not a string")
        for test in tests:
            self.addTest(test)

    def run(self, result):
        var index = 0
        for test in list(self._tests):
            if result.shouldStop:
                break
            test(result)
            index = index + 1
        return result

    def _removeTestAtIndex(self, index):
        """Stop holding a reference to the TestCase at index."""
        try:
            var test = self._tests[index]
            if hasattr(test, "countTestCases"):
                self._removed_tests = self._removed_tests + test.countTestCases()
            self._tests[index] = none
        except Exception:
            pass

    def __call__(self, *args, **kwds):
        return self.run(*args, **kwds)

    def debug(self):
        """Run the tests without collecting errors in a TestResult"""
        for test in self:
            test.debug()


def _isnotsuite(test):
    "A crude way to tell apart testcases and suites with duck-typing"
    try:
        iter(test)
    except TypeError:
        return true
    return not hasattr(test, "_tests")


class _ErrorHolder:
    """
    Placeholder for a TestCase inside a result. As far as a TestResult
    is concerned, this looks exactly like a unit test. Used to insert
    arbitrary errors into a test suite run.
    """
    failureException = none

    def __init__(self, description):
        self.description = description

    def id(self):
        return self.description

    def shortDescription(self):
        return none

    def __repr__(self):
        return "<ErrorHolder description=" + repr(self.description) + ">"

    def __str__(self):
        return self.id()

    def run(self, result):
        # could call result.addError(...) - but this test-like object
        # shouldn't be run anyway
        pass

    def __call__(self, result):
        return self.run(result)

    def countTestCases(self):
        return 0


class TestSuite(BaseTestSuite):
    """A test suite is a composite test consisting of a number of TestCases.

    For use, create an instance of TestSuite, then add test case instances.
    When all tests have been added, the suite can be passed to a test
    runner, such as TextTestRunner. It will run the individual test cases
    in the order in which they were added, aggregating the results. When
    subclassing, do not forget to call the base class constructor.
    """
    def run(self, result, debug=false):
        var topLevel = false
        if not getattr(result, "_testRunEntered", false):
            result._testRunEntered = true
            topLevel = true
        for test in list(self._tests):
            if result.shouldStop:
                break
            if test is none:
                continue
            if _isnotsuite(test):
                self._tearDownPreviousClass(test, result)
                self._handleClassSetUp(test, result)
                result._previousTestClass = _class_of(test)
                if getattr(_class_of(test), "_classSetupFailed", false) or getattr(result, "_moduleSetUpFailed", false):
                    continue
            if not debug:
                test(result)
            else:
                test.debug()
        if topLevel:
            self._tearDownPreviousClass(none, result)
            result._testRunEntered = false
        return result

    def debug(self):
        """Run the tests without collecting errors in a TestResult"""
        var debug = _DebugResult()
        self.run(debug, true)

    def _handleClassSetUp(self, test, result):
        var previousClass = getattr(result, "_previousTestClass", none)
        var currentClass = _class_of(test)
        if previousClass is not none and _same(currentClass, previousClass):
            return
        if result._moduleSetUpFailed:
            return
        if getattr(currentClass, "__unittest_skip__", false):
            return
        var failed = false
        try:
            currentClass._classSetupFailed = false
        except Exception:
            pass
        var setUpClass = getattr(currentClass, "setUpClass", none)
        var doClassCleanups = getattr(currentClass, "doClassCleanups", none)
        if setUpClass is not none:
            var className = strclass(currentClass)
            try:
                setUpClass()
            except Exception as e:
                if isinstance(result, _DebugResult):
                    raise
                failed = true
                try:
                    currentClass._classSetupFailed = true
                except Exception:
                    pass
                self._createClassOrModuleLevelException(result, e, "setUpClass", className)
            if failed and doClassCleanups is not none:
                doClassCleanups()
                for exc_info in getattr(currentClass, "tearDown_exceptions", []):
                    self._createClassOrModuleLevelException(result, exc_info[1], "setUpClass", className, exc_info)

    def _createClassOrModuleLevelException(self, result, exc, method_name, parent, info=none):
        var errorName = method_name + " (" + parent + ")"
        self._addClassOrModuleLevelException(result, exc, errorName, info)

    def _addClassOrModuleLevelException(self, result, exception, errorName, info=none):
        var error = _ErrorHolder(errorName)
        var addSkip = getattr(result, "addSkip", none)
        if addSkip is not none and isinstance(exception, SkipTest):
            addSkip(error, str(exception))
        else:
            if not info:
                result.addError(error, _exc_info_of(exception))
            else:
                result.addError(error, info)

    def _tearDownPreviousClass(self, test, result):
        var previousClass = getattr(result, "_previousTestClass", none)
        if previousClass is none:
            return
        if test is not none and _same(_class_of(test), previousClass):
            return
        if getattr(previousClass, "_classSetupFailed", false):
            return
        if getattr(result, "_moduleSetUpFailed", false):
            return
        if getattr(previousClass, "__unittest_skip__", false):
            return
        var tearDownClass = getattr(previousClass, "tearDownClass", none)
        var doClassCleanups = getattr(previousClass, "doClassCleanups", none)
        if tearDownClass is none and doClassCleanups is none:
            return
        var className = strclass(previousClass)
        if tearDownClass is not none:
            try:
                tearDownClass()
            except Exception as e:
                if isinstance(result, _DebugResult):
                    raise
                self._createClassOrModuleLevelException(result, e, "tearDownClass", className)
        if doClassCleanups is not none:
            doClassCleanups()
            for exc_info in getattr(previousClass, "tearDown_exceptions", []):
                if isinstance(result, _DebugResult):
                    raise exc_info[1]
                self._createClassOrModuleLevelException(result, exc_info[1], "tearDownClass", className, exc_info)


class _DebugResult:
    "Used by the TestSuite to hold previous class when running in debug."
    _previousTestClass = none
    _moduleSetUpFailed = false
    shouldStop = false

    def __init__(self):
        self._previousTestClass = none
        self._moduleSetUpFailed = false
        self.shouldStop = false
        self._testRunEntered = false


# ── loading ──────────────────────────────────────────────────────────────────

def _module_items(module):
    # [name, value] pairs of a module: a globals dict, a module namespace,
    # or any object with attributes.
    var out = []
    if isinstance(module, dict):
        for k in module:
            out.append([k, module[k]])
        return out
    for k2 in dir(module):
        try:
            out.append([k2, getattr(module, k2)])
        except Exception:
            pass
    return out


def _module_get(module, name):
    if isinstance(module, dict):
        return module[name]
    return getattr(module, name)


class TestLoader:
    """
    This class is responsible for loading tests according to various criteria
    and returning them wrapped in a TestSuite
    """
    testMethodPrefix = "test"
    sortTestMethodsUsing = three_way_cmp
    testNamePatterns = none
    suiteClass = TestSuite

    def __init__(self):
        self.errors = []
        self.testNamePatterns = none

    def loadTestsFromTestCase(self, testCaseClass):
        """Return a suite of all test cases contained in testCaseClass"""
        if issubclass(testCaseClass, TestSuite):
            raise TypeError("Test cases should not be derived from TestSuite. Maybe you meant to derive from TestCase?")
        var testCaseNames = []
        if not (_same(testCaseClass, TestCase) or _same(testCaseClass, FunctionTestCase)):
            testCaseNames = self.getTestCaseNames(testCaseClass)
            if not testCaseNames and hasattr(testCaseClass, "runTest"):
                testCaseNames = ["runTest"]
        var tests = []
        for name in testCaseNames:
            tests.append(testCaseClass(name))
        return self.suiteClass(tests)

    def loadTestsFromModule(self, module, pattern=none):
        """Return a suite of all test cases contained in the given module"""
        var tests = []
        for item in _module_items(module):
            var obj = item[1]
            if _is_class(obj) and issubclass(obj, TestCase) and not (_same(obj, TestCase) or _same(obj, FunctionTestCase) or _same(obj, _SubTest)):
                tests.append(self.loadTestsFromTestCase(obj))
        var load_tests = none
        if isinstance(module, dict):
            load_tests = module.get("load_tests")
        else:
            load_tests = getattr(module, "load_tests", none)
        var suite = self.suiteClass(tests)
        if load_tests is not none and callable(load_tests):
            return load_tests(self, suite, pattern)
        return suite

    def loadTestsFromName(self, name, module=none):
        """Return a suite of all test cases given a string specifier.

        The name may resolve either to a module, a test case class, a
        test method within a test case class, or a callable object which
        returns a TestCase or TestSuite instance.

        The method optionally resolves the names relative to a given module
        (here a globals dict or a module namespace).
        """
        if module is none:
            module = _ny_main_globals()
        var parts = name.split(".")
        var parent = none
        var obj = module
        for part in parts:
            parent = obj
            try:
                obj = _module_get(obj, part)
            except Exception:
                raise AttributeError("module '__main__' has no attribute '" + part + "'")
        if _is_class(obj) and issubclass(obj, TestCase):
            return self.loadTestsFromTestCase(obj)
        if isinstance(obj, TestSuite):
            return obj
        if parent is not none and _is_class(parent) and issubclass(parent, TestCase):
            var mname = parts[-1]
            var inst = parent(mname)
            return self.suiteClass([inst])
        if isinstance(obj, TestCase):
            return obj
        if callable(obj):
            var test = obj()
            if isinstance(test, TestSuite) or isinstance(test, TestCase):
                return test
            raise TypeError("calling " + repr(obj) + " returned " + repr(test) + ", not a test")
        raise TypeError("don't know how to make test from: " + repr(obj))

    def loadTestsFromNames(self, names, module=none):
        """Return a suite of all test cases found using the given sequence
        of string specifiers. See 'loadTestsFromName()'.
        """
        var suites = []
        for name in names:
            suites.append(self.loadTestsFromName(name, module))
        return self.suiteClass(suites)

    def getTestCaseNames(self, testCaseClass):
        """Return a sorted sequence of method names found within testCaseClass
        """
        var prefix = self.testMethodPrefix
        var patterns = self.testNamePatterns
        var names = []
        for attrname in dir(testCaseClass):
            if not attrname.startswith(prefix):
                continue
            var testFunc = getattr(testCaseClass, attrname, none)
            if not callable(testFunc):
                continue
            if patterns is not none:
                var fullName = strclass(testCaseClass) + "." + attrname
                import fnmatch
                var hit = false
                for p in patterns:
                    if fnmatch.fnmatchcase(fullName, p):
                        hit = true
                        break
                if not hit:
                    continue
            if attrname not in names:
                names.append(attrname)
        if self.sortTestMethodsUsing:
            var cmp = self.sortTestMethodsUsing
            names = _sort_cmp(names, cmp)
        return names


def _sort_cmp(items, cmp):
    # sort with a three-way comparison function (functools.cmp_to_key)
    var out = list(items)
    var i = 1
    while i < len(out):
        var x = out[i]
        var j = i - 1
        while j >= 0 and cmp(out[j], x) > 0:
            out[j + 1] = out[j]
            j = j - 1
        out[j + 1] = x
        i = i + 1
    return out


defaultTestLoader = TestLoader()


def getTestCaseNames(testCaseClass, prefix, sortUsing=three_way_cmp, testNamePatterns=none):
    var loader = TestLoader()
    loader.testMethodPrefix = prefix
    loader.sortTestMethodsUsing = sortUsing
    loader.testNamePatterns = testNamePatterns
    return loader.getTestCaseNames(testCaseClass)


def makeSuite(testCaseClass, prefix="test", sortUsing=three_way_cmp, suiteClass=TestSuite):
    var loader = TestLoader()
    loader.testMethodPrefix = prefix
    loader.sortTestMethodsUsing = sortUsing
    loader.suiteClass = suiteClass
    return loader.loadTestsFromTestCase(testCaseClass)


def findTestCases(module, prefix="test", sortUsing=three_way_cmp, suiteClass=TestSuite):
    var loader = TestLoader()
    loader.testMethodPrefix = prefix
    loader.sortTestMethodsUsing = sortUsing
    loader.suiteClass = suiteClass
    return loader.loadTestsFromModule(module)


# ── module fixtures and signals (accepted; minimal) ─────────────────────────

_module_cleanups = []


def addModuleCleanup(function, *args, **kwargs):
    """Same as addCleanup, except the cleanup items are called even if
    setUpModule fails (unlike tearDownModule)."""
    _module_cleanups.append((function, args, kwargs))


def enterModuleContext(cm):
    """Same as enterContext, but module-wide."""
    var result = cm.__enter__()
    addModuleCleanup(cm.__exit__, none, none, none)
    return result


def doModuleCleanups():
    """Execute all module cleanup functions. Normally called for you after
    tearDownModule."""
    var exceptions = []
    while _module_cleanups:
        var entry = _module_cleanups.pop()
        try:
            entry[0](*entry[1], **entry[2])
        except Exception as exc:
            exceptions.append(exc)
    # Swallows all but first exception. If a multi-exception handler
    # gets written we should use that here instead.
    if exceptions:
        raise exceptions[0]


def installHandler():
    pass


def removeHandler(method=none):
    if method is not none:
        return method
    return none


def registerResult(result):
    pass


def removeResult(result):
    return false


IsolatedAsyncioTestCase = TestCase


# ── main ─────────────────────────────────────────────────────────────────────

_MAIN_USAGE = """usage: %(prog)s [-h] [-v] [-q] [--locals] [--durations N] [-f] [-c] [-b]
       [-k TESTNAMEPATTERNS]
       [tests ...]
"""


class TestProgram:
    """A command-line program that runs a set of tests; this is primarily
       for making test modules conveniently executable.
    """
    def __init__(self, module="__main__", defaultTest=none, argv=none,
                 testRunner=none, testLoader=none, exit=true, verbosity=1,
                 failfast=none, catchbreak=none, buffer=none, warnings=none,
                 tb_locals=false, durations=none):
        if isinstance(module, str) and module == "__main__":
            self.module = _ny_main_globals()
        elif isinstance(module, str):
            raise ImportError("unittest.main(module=" + repr(module) + "): only '__main__' or a namespace is supported")
        else:
            self.module = module
        if argv is none:
            argv = sys.argv
        self.exit = exit
        self.failfast = failfast
        self.catchbreak = catchbreak
        self.verbosity = verbosity
        self.buffer = buffer
        self.tb_locals = tb_locals
        self.durations = durations
        self.warnings = warnings
        self.defaultTest = defaultTest
        self.testRunner = testRunner
        self.testLoader = testLoader if testLoader is not none else defaultTestLoader
        self.progName = os_path_basename(argv[0]) if argv else "python -m unittest"
        self.testNamePatterns = none
        self.result = none
        self.parseArgs(argv)
        self.runTests()

    def usageExit(self, msg=none):
        if msg:
            print(msg)
        print(_MAIN_USAGE % {"prog": self.progName}, end="")
        raise SystemExit(2)

    def parseArgs(self, argv):
        var names = []
        var patterns = []
        var args = list(argv[1:])
        var i = 0
        while i < len(args):
            var a = args[i]
            if a in ["-h", "--help"]:
                self.usageExit()
            elif a in ["-v", "--verbose"]:
                self.verbosity = 2
            elif a in ["-q", "--quiet"]:
                self.verbosity = 0
            elif a in ["-f", "--failfast"]:
                self.failfast = true
            elif a in ["-c", "--catch"]:
                self.catchbreak = true
            elif a in ["-b", "--buffer"]:
                self.buffer = true
            elif a == "--locals":
                self.tb_locals = true
            elif a == "--durations":
                i = i + 1
                self.durations = int(args[i])
            elif a == "-k":
                i = i + 1
                patterns.append(args[i])
            elif a.startswith("-k"):
                patterns.append(a[2:])
            elif a.startswith("-") and len(a) > 1:
                self.usageExit("unrecognized arguments: " + a)
            else:
                names.append(a)
            i = i + 1
        if patterns:
            self.testNamePatterns = [("*" + p + "*") if "*" not in p else p for p in patterns]
        if names:
            self.testNames = names
        elif self.defaultTest is none:
            self.testNames = none
        elif isinstance(self.defaultTest, str):
            self.testNames = [self.defaultTest]
        else:
            self.testNames = list(self.defaultTest)
        self.createTests()

    def createTests(self, from_discovery=false, Loader=none):
        if self.testNamePatterns:
            self.testLoader.testNamePatterns = self.testNamePatterns
        if self.testNames is none:
            self.test = self.testLoader.loadTestsFromModule(self.module)
        else:
            self.test = self.testLoader.loadTestsFromNames(self.testNames, self.module)

    def _module_hook(self, name):
        if isinstance(self.module, dict):
            return self.module.get(name)
        return getattr(self.module, name, none)

    def runTests(self):
        if self.catchbreak:
            installHandler()
        var testRunner = self.testRunner
        if testRunner is none:
            testRunner = TextTestRunner
        if _is_class(testRunner):
            try:
                testRunner = testRunner(none, true, self.verbosity, self.failfast or false, self.buffer or false, none, self.warnings, self.tb_locals, self.durations)
            except TypeError:
                testRunner = testRunner()
        # The __main__ module's fixtures run inside the run, around its tests,
        # as TestSuite runs them in CPython (before the summary is printed).
        var setUpModule = self._module_hook("setUpModule")
        var tearDownModule = self._module_hook("tearDownModule")
        var tests = self.test
        var holder = TestSuite([])
        def _with_module_fixtures(result):
            var failed = false
            if setUpModule is not none and callable(setUpModule):
                try:
                    setUpModule()
                except Exception as e:
                    failed = true
                    holder._addClassOrModuleLevelException(result, e, "setUpModule (__main__)")
            if not failed:
                tests(result)
                if tearDownModule is not none and callable(tearDownModule):
                    try:
                        tearDownModule()
                    except Exception as e2:
                        holder._addClassOrModuleLevelException(result, e2, "tearDownModule (__main__)")
            try:
                doModuleCleanups()
            except Exception as e3:
                holder._addClassOrModuleLevelException(result, e3, "tearDownModule (__main__)")
            return result
        self.result = testRunner.run(_with_module_fixtures)
        if self.exit:
            if self.result.testsRun == 0 and len(self.result.skipped) == 0:
                raise SystemExit(_NO_TESTS_EXITCODE)
            elif self.result.wasSuccessful():
                raise SystemExit(0)
            else:
                raise SystemExit(1)


main = TestProgram
