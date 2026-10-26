#!/usr/bin/env python3
"""difftest.py - differential testing of Nython against CPython (round 87).

    python3 tools/difftest.py                       # 200 generated programs, both engines
    python3 tools/difftest.py --count 1000 --seed 7 -j 2
    python3 tools/difftest.py --run prog.py         # one program: the three outputs, diffed
    python3 tools/difftest.py --reduce prog.py      # reduce a disagreement to a minimal program
    python3 tools/difftest.py --lang ny             # .ny programs: the interpreter against the VM

Differential testing (McKeeman 1998, "Differential Testing for Software"):
the same program runs on several implementations of one language and any
difference in what they print is a bug in one of them - CPython is the oracle
for Python-language source, and the two Nython engines are each other's.

The programs are generated (Csmith, Yang et al. 2011, scaled down to Python):
a grammar of Python's constructs - classes with operator dunders, inheritance
and super(), properties, closures and nonlocal, comprehensions, generators,
exceptions and their flow, unpacking, slicing, formatting, builtins and
operators on mixed types - drawn from a seeded random source. Every
observation is a tagged line printed by a guard (`_p(tag, thunk)`) that
reports either the value's repr or the exception's type and text, so one
difference never hides the next and a program that raises keeps running.
The generator only writes deterministic programs (no ids, no string hashes,
no set iteration of strings, no time), so any difference is a finding.

A disagreement is reduced to a small program by delta debugging (Zeller and
Hildebrandt 2002, ddmin) over the statement lists of the program's syntax tree
at every depth, then over its expressions (hierarchical delta debugging,
Misherghi and Su 2006: a subexpression replaced by one of its children or by
a constant), keeping the program interesting: the same tag still differs the
same way (its signature - the engine, the kind of each side's line and the
exception types - is unchanged, so the reduction does not wander to another
bug). Findings are grouped by signature (a difference both engines make the
same way is one finding, "interp+vm") and written to --out as runnable
programs with the outputs each implementation gave.

Exit status: 0 when nothing differed, 1 otherwise.
"""
import argparse
import ast
import hashlib
import os
import random
import re
import subprocess
import sys
import tempfile
import warnings
from concurrent.futures import ThreadPoolExecutor

# the reducer compiles candidates such as `1.5[0:1]`: CPython's "perhaps you
# missed a comma?" warnings about them are noise here
warnings.simplefilter("ignore", SyntaxWarning)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = os.path.join(REPO, "build", "nython-cli")

HARNESS = '''\
import sys
def _r(x, d=0):
    # repr, with the items of a set in a fixed order (CPython's is its hash
    # table's, an implementation detail)
    t = type(x)
    if d < 6 and (t is set or t is frozenset):
        items = sorted([_r(i, d + 1) for i in x])
        if t is frozenset:
            return "frozenset({" + ", ".join(items) + "})" if items else "frozenset()"
        return "{" + ", ".join(items) + "}" if items else "set()"
    if d < 6 and t is list:
        return "[" + ", ".join([_r(i, d + 1) for i in x]) + "]"
    if d < 6 and t is tuple:
        return "(" + ", ".join([_r(i, d + 1) for i in x]) + ("," if len(x) == 1 else "") + ")"
    if d < 6 and t is dict:
        return "{" + ", ".join([_r(k, d + 1) + ": " + _r(v, d + 1) for k, v in x.items()]) + "}"
    return repr(x)
def _p(tag, f):
    try:
        r = f()
    except BaseException as e:
        print(tag, "!", type(e).__name__, str(e))
        return
    try:
        s = _r(r)
    except BaseException as e:
        s = "<repr raised " + type(e).__name__ + ">"
    print(tag, "=", s)
'''

# ── the generator ────────────────────────────────────────────────────────────


class Gen:
    """A random Python program from a seed: a list of units, each a few
    statements that end in tagged observations."""

    def __init__(self, seed):
        self.r = random.Random(seed)
        self.n = 0
        self.classes = []      # (name, has_add, has_eq, has_lt, has_len, has_iter, base)
        self.funcs = []
        self.out = []

    def tag(self):
        self.n += 1
        return "t%d" % self.n

    def obs(self, expr):
        self.out.append("_p(%r, lambda: (%s))" % (self.tag(), expr))

    def pick(self, xs):
        return self.r.choice(xs)

    # values of many types, as literals or simple expressions
    def scalar(self):
        return self.pick(["0", "1", "-3", "7", "2 ** 70", "-(2 ** 64)", "True", "False", "None",
                          "0.5", "-2.0", "1e300", "3.0", "float('inf')", "''", "'ab'", "'x1'",
                          "'Ab c'", "b'ab'", "b''", "1j", "complex(1, 2)"])

    def container(self):
        return self.pick(["[]", "[1, 2]", "[3, 'a']", "()", "(1,)", "(1, 'a')", "(2, 1)", "{}",
                          "{'a': 1}", "{1: 'x', 2: 'y'}", "{1, 2}", "frozenset({3})", "range(3)",
                          "range(1, 10, 3)", "bytearray(b'xy')", "[[1], [2, 3]]", "'hello'"])

    def value(self, depth=0):
        k = self.r.random()
        if self.classes and k < 0.2:
            c = self.pick(self.classes)
            return "%s(%s)" % (c[0], self.pick(["1", "2", "'s'", "[1, 2]"]))
        if k < 0.55:
            return self.scalar()
        if k < 0.9 or depth > 1:
            return self.container()
        return self.expr(depth + 1)

    def expr(self, depth=0):
        k = self.r.random()
        a, b = self.value(depth + 1), self.value(depth + 1)
        if k < 0.45:
            op = self.pick(["+", "-", "*", "/", "//", "%", "**", "<<", ">>", "&", "|", "^", "@",
                            "==", "!=", "<", "<=", ">", ">=", "in", "not in", "is", "and", "or"])
            return "(%s %s %s)" % (a, op, b)
        if k < 0.55:
            return "(%s%s)" % (self.pick(["-", "+", "~", "not "]), a)
        if k < 0.85:
            f = self.pick(["len", "abs", "int", "float", "str", "bool", "repr", "sorted", "min", "max",
                           "sum", "list", "tuple", "set", "dict", "round", "ord", "chr", "bin", "hex",
                           "oct", "iter", "reversed", "enumerate", "hash", "callable", "type",
                           "any", "all", "frozenset", "bytes", "ascii", "divmod", "pow", "isinstance",
                           "zip", "format", "max", "getattr", "hasattr"])
            if f in ("divmod", "pow", "zip"):
                return "%s(%s, %s)" % (f, a, b)
            if f == "isinstance":
                return "isinstance(%s, %s)" % (a, self.pick(["int", "str", "(int, str)", "list", "object", "bool"]))
            if f == "format":
                return "format(%s, %r)" % (a, self.pick(["", "x", ">5", "^7", ".2f", "+d", "e", "05", ",", "s", "r"]))
            if f in ("getattr", "hasattr"):
                return "%s(%s, %r)" % (f, a, self.pick(["real", "append", "keys", "x", "__len__", "upper"]))
            if f in ("iter", "reversed", "enumerate"):
                return "list(%s(%s))" % (f, a)
            if f == "hash":
                return "hash(%s) == hash(%s)" % (a, a)    # str hashes are randomized
            if f == "type":
                return "type(%s).__name__" % a
            return "%s(%s)" % (f, a)
        if k < 0.93:
            return "%s[%s]" % (a, self.pick(["0", "-1", "1:", "::-1", "1:3", "'a'", "None", "::2", "5"]))
        m = self.pick(["upper()", "split()", "index(1)", "count('a')", "get('a')", "append(1)", "keys()",
                       "items()", "pop()", "copy()", "startswith('a')", "join(['a', 'b'])", "find('b')",
                       "replace('a', 'b')", "strip()", "real", "imag", "bit_length()", "hex()", "decode()",
                       "encode()", "conjugate()", "is_integer()", "__len__()", "__class__.__name__",
                       "union({1})", "isdigit()", "title()", "zfill(4)", "partition('b')"])
        return "(%s).%s" % (a, m)

    # ── units ────────────────────────────────────────────────────────────────
    def u_exprs(self):
        for _ in range(self.r.randint(2, 5)):
            self.obs(self.expr())

    def u_class(self):
        name = "C%d" % len(self.classes)
        base = self.pick([None, None, None] + [c[0] for c in self.classes] + ["Exception", "int", "list", "dict", "str"])
        feats = self.r.sample(["add", "radd", "eq", "lt", "len", "iter", "bool", "repr", "str", "getitem",
                               "contains", "call", "hash", "prop", "static", "cls", "neg", "iadd",
                               "slots", "getattr", "format", "index"], self.r.randint(2, 6))
        L = ["class %s%s:" % (name, "(%s)" % base if base else "")]
        L.append("    kind = %r" % name)
        if "slots" in feats and base is None:
            L.append("    __slots__ = ('v',)")
        if base in (None, "Exception") or base and base.startswith("C"):
            L.append("    def __init__(self, v=0):")
            if base and base.startswith("C"):
                L.append("        super().__init__(v)")
            elif base == "Exception":
                L.append("        super().__init__(v)")
            L.append("        self.v = v")
        def m(sig, body):
            L.append("    def %s:" % sig)
            for line in body:
                L.append("        " + line)
        val = "getattr(self, 'v', self)"
        if "add" in feats:
            m("__add__(self, o)", ["if isinstance(o, %s):" % name, "    return %s(%s + o.v)" % (name, val),
                                  "if isinstance(o, int):" , "    return %s(o)" % name, "return NotImplemented"])
        if "radd" in feats:
            m("__radd__(self, o)", ["return ('radd', o)"])
        if "iadd" in feats:
            m("__iadd__(self, o)", ["self.v = ('iadd', o)", "return self"])
        if "eq" in feats:
            m("__eq__(self, o)", ["return isinstance(o, %s) and %s == getattr(o, 'v', None)" % (name, val)])
        if "hash" in feats:
            m("__hash__(self)", ["return 7"])
        if "lt" in feats:
            m("__lt__(self, o)", ["if not isinstance(o, %s):" % name, "    return NotImplemented",
                                 "return str(self.v) < str(o.v)"])
        if "len" in feats:
            m("__len__(self)", ["return %s" % self.pick(["3", "0", "-1", "'x'", "2 ** 70"])])
        if "bool" in feats:
            m("__bool__(self)", ["return %s" % self.pick(["False", "True", "1"])])
        if "iter" in feats:
            m("__iter__(self)", ["yield 1", "yield self.v"])
        if "getitem" in feats:
            m("__getitem__(self, k)", ["if k == 3:", "    raise IndexError(k)", "return ('item', k)"])
        if "contains" in feats:
            m("__contains__(self, k)", ["return k == 1"])
        if "call" in feats:
            m("__call__(self, *a, **k)", ["return (a, sorted(k))"])
        if "repr" in feats:
            m("__repr__(self)", ["return '%s<' + repr(%s) + '>'" % (name, val)])
        if "str" in feats:
            m("__str__(self)", ["return 'str-%s'" % name])
        if "neg" in feats:
            m("__neg__(self)", ["return 'neg'"])
        if "getattr" in feats:
            m("__getattr__(self, n)", ["if n.startswith('_'):", "    raise AttributeError(n)", "return 'ga-' + n"])
        if "format" in feats:
            m("__format__(self, spec)", ["return 'fmt[' + spec + ']'"])
        if "index" in feats:
            m("__index__(self)", ["return 2"])
        if "prop" in feats:
            L.append("    @property")
            m("p(self)", ["return ('p', self.v)"])
        if "static" in feats:
            L.append("    @staticmethod")
            m("s(a, b=2)", ["return a * b"])
        if "cls" in feats:
            L.append("    @classmethod")
            m("c(cls)", ["return cls.__name__"])
        m("meth(self, x, *rest, k=1)", ["return (x, rest, k)"])
        self.out.extend(L)
        self.classes.append((name, base))
        o = "%s(%s)" % (name, self.pick(["1", "2", "'s'"]))
        for _ in range(self.r.randint(3, 7)):
            e = self.pick([
                "%s + 1" % o, "1 + %s" % o, "%s + %s" % (o, o), "%s == %s" % (o, o), "%s < %s" % (o, o),
                "len(%s)" % o, "list(%s)" % o, "bool(%s)" % o, "repr(%s)" % o, "str(%s)" % o,
                "%s[1]" % o, "%s[3]" % o, "1 in %s" % o, "%s()" % o, "%s(1, a=2)" % o, "(lambda x: (hash(x) == hash(x), hash(x) == 7))(%s)" % o,
                "%s.p" % o, "%s.s(3)" % name, "%s.c()" % name, "-%s" % o, "%s.zz" % o, 'f"{%s:>4}"' % o,
                "[1, 2, 3][%s]" % o, "%s.meth(1, 2, k=3)" % o, "%s.meth()" % o, "%s.meth(1, x=2)" % o,
                "%s.__class__.__name__" % o, "%s.kind" % name, "isinstance(%s, %s)" % (o, name),
                "issubclass(%s, object)" % name, "type(%s) is %s" % (o, name), "%s.__mro__" % name,
                "sorted([%s, %s])" % (o, o), "{%s: 1}" % o, "%s.__dict__" % o, "vars(%s)" % o,
                "max(%s, %s)" % (o, o), "%s * 2" % o, "divmod(%s, 2)" % o, "abs(%s)" % o,
                "%s.v" % o, "setattr(%s, 'w', 1)" % o, "%s.__name__" % name, "%s.__qualname__" % name,
            ])
            self.obs(e)
        self.obs("(lambda o: (o.__iadd__ if hasattr(o, '__iadd__') else o.__class__)(1))(%s)" % o)

    def u_closure(self):
        f = "f%d" % len(self.funcs)
        self.funcs.append(f)
        body = self.pick([
            ["def %s(n):" % f, "    acc = []", "    def inner(x=n):", "        nonlocal n", "        n += x",
             "        acc.append(n)", "        return acc", "    return inner"],
            ["def %s(n):" % f, "    fs = [lambda: i * n for i in range(3)]", "    return lambda k=0: [g() for g in fs] + [k]"],
            ["def %s(n):" % f, "    def mk(i):", "        return lambda: i + n", "    return lambda k=0: [mk(i)() for i in range(n)] + [k]"],
            ["def %s(n):" % f, "    count = 0", "    def inc():", "        nonlocal count", "        count += n",
             "        return count", "    return lambda k=0: (inc(), inc(), k)"],
            ["def %s(n, *a, **kw):" % f, "    def g(*b, **kb):", "        return (n, a, b, sorted(kw), sorted(kb))",
             "    return g"],
        ])
        self.out.extend(body)
        arg = self.pick(["1", "2", "0", "-1"])
        self.obs("%s(%s)()" % (f, arg))
        self.obs("%s(%s)(%s)" % (f, arg, self.pick(["5", "'a'", "None"])))
        self.obs("%s.__name__, %s.__defaults__, %s.__code__.co_argcount" % (f, f, f))

    def u_comp(self):
        src = self.pick(["range(5)", "'abc'", "[3, 1, 2]", "{'a': 1, 'b': 2}", "(1, (2, 3))", "range(-2, 2)",
                         "[[1, 2], [3]]", "[(1, 'a'), (2, 'b')]"])
        e = self.pick([
            "[x for x in %s]", "[x * 2 for x in %s if x]", "{x: str(x) for x in %s}", "sorted({x for x in %s}, key=repr)",
            "list(x for x in %s)", "[y for x in %s for y in (x, x)]", "[(i, x) for i, x in enumerate(%s)]",
            "[a for a, *b in %s]", "[z for x in %s if (z := x)]", "sum(1 for _ in %s)", "max(%s, key=repr, default=None)",
            "[x for x in %s][::-1]", "dict(zip(%s, %s))", "list(map(repr, %s))", "list(filter(None, %s))",
            "[*%s, *%s]", "{**{'k': 0}, **dict.fromkeys(%s)}", "tuple(reversed(list(%s)))",
        ])
        n = e.count("%s")
        self.obs(e % ((src,) * n))

    def u_exc(self):
        f = "g%d" % len(self.funcs)
        self.funcs.append(f)
        exc = self.pick(["ValueError('v')", "KeyError('k')", "TypeError()", "ZeroDivisionError", "StopIteration(3)",
                         "IndexError(1, 2)", "OSError(2, 'nf')", "RuntimeError('r')", "AttributeError('a')",
                         "ArithmeticError", "LookupError('l')", "NotImplementedError"])
        catch = self.pick(["Exception", "ValueError", "LookupError", "(KeyError, IndexError)", "ArithmeticError",
                           "BaseException", "TypeError"])
        shape = self.pick(["plain", "finally", "else", "chain", "nested", "return_finally", "loop"])
        L = ["def %s(flag):" % f, "    log = []"]
        if shape == "plain":
            L += ["    try:", "        if flag:", "            raise %s" % exc, "        log.append('body')",
                  "    except %s as e:" % catch, "        log.append((type(e).__name__, str(e), e.args))", "    return log"]
        elif shape == "finally":
            L += ["    try:", "        try:", "            if flag:", "                raise %s" % exc,
                  "        finally:", "            log.append('fin')", "    except %s as e:" % catch,
                  "        log.append(repr(e))", "    return log"]
        elif shape == "else":
            L += ["    try:", "        if flag:", "            raise %s" % exc, "    except %s:" % catch,
                  "        log.append('exc')", "    else:", "        log.append('else')", "    finally:",
                  "        log.append('fin')", "    return log"]
        elif shape == "chain":
            L += ["    try:", "        try:", "            raise %s" % exc, "        except BaseException as e:",
                  "            raise RuntimeError('outer') %s" % self.pick(["from e", "from None", ""]),
                  "    except RuntimeError as e2:",
                  "        log.append((repr(e2.__cause__), repr(e2.__context__), e2.__suppress_context__))",
                  "    return log"]
        elif shape == "nested":
            L += ["    for i in range(3):", "        try:", "            if i == flag:", "                raise %s" % exc,
                  "            log.append(i)", "        except %s:" % catch, "            log.append('c')",
                  "            %s" % self.pick(["continue", "break", "pass"]), "    return log"]
        elif shape == "return_finally":
            L += ["    try:", "        return 'try'", "    finally:", "        if flag:", "            return 'finally'"]
        else:
            L += ["    i = 0", "    while True:", "        try:", "            i += 1", "            if i > 2:",
                  "                raise %s" % exc, "        except %s:" % catch, "            return (i, 'caught')",
                  "        finally:", "            log.append(i)", "        if i > 5:", "            return log"]
        self.out.extend(L)
        self.obs("%s(0)" % f)
        self.obs("%s(1)" % f)

    def u_gen(self):
        f = "h%d" % len(self.funcs)
        self.funcs.append(f)
        self.out.extend(self.pick([
            ["def %s(n):" % f, "    x = yield n", "    while x is not None:", "        x = yield x * 2", "    return 'done'"],
            ["def %s(n):" % f, "    r = yield from range(n)", "    yield ('r', r)"],
            ["def %s(n):" % f, "    try:", "        yield n", "        yield n + 1", "    finally:", "        n = 0"],
        ]))
        self.obs("list(%s(3))" % f)
        self.obs("(lambda g: (next(g), g.send(5), g.send(None)))(%s(1))" % f)
        self.obs("(lambda g: (next(g), g.throw(ValueError('x'))))(%s(2))" % f)
        self.obs("(lambda g: (next(g), g.close(), list(g)))(%s(4))" % f)

    def u_unpack(self):
        rhs = self.pick(["[1, 2, 3]", "'ab'", "(1,)", "range(4)", "{'a': 1, 'b': 2}", "[(1, 2), (3, 4)]", "5", "None"])
        self.obs(self.pick(["(lambda s: [a for a, b in [s]])(%s)",
                            "(lambda s: (lambda a, *b: (a, b))(*s))(%s)",
                            "(lambda s: dict(**s) if isinstance(s, dict) else [*s])(%s)",
                            "(lambda s: '{}-{}'.format(*s))(%s)",
                            "(lambda s: [*s][1:] + [*s][:1])(%s)"]) % rhs)
        lhs = self.pick(["a, b", "a, *b", "*a, b", "(a, b), c", "[a, b, *c]"])
        tag = self.tag()
        self.out.append("try:")
        self.out.append("    %s = %s" % (lhs, rhs))
        self.out.append("    print(%r, '=', repr(%s))" % (tag, "(" + lhs.replace("*", "") + ",)"))
        self.out.append("except BaseException as e:")
        self.out.append("    print(%r, '!', type(e).__name__, str(e))" % tag)

    def u_format(self):
        v = self.value()
        self.obs(self.pick([
            'f"{(V)!r:>12}"', 'f"{(V):*^9}"', "'%s|%r' % (V, V)", "'%5.2f' % V", "'{0!s:<6}|'.format(V)",
            'f"{(V)=}"', "'%d' % V", "'%x' % V", "'{:,}'.format(V)", "str(V).center(9, '.')",
            "'%-6s|' % (V,)", 'f"{(V):08.3f}"', "'{}'.format(V)", "format(V, '')", "'%s' % V",
            "'%(a)s' % V", "'{0[0]}'.format(V)"]).replace("V", v))

    def u_slices(self):
        seq = self.pick(["[0, 1, 2, 3, 4]", "'abcdef'", "(9, 8, 7)", "range(10)", "b'xyz'", "bytearray(b'12345')"])
        sl = self.pick(["::-1", "1:-1", "-2:", ":100", "::3", "5:1:-2", "-100:2", "::-2", "1:1", "None:None:-1"])
        self.obs("%s[%s]" % (seq, sl))
        self.obs("(lambda s: (s.__class__.__name__, s[slice(1, None, 2)]))(%s)" % seq)
        if seq.startswith("["):
            self.obs("(lambda L: (L.__setitem__(slice(1, 3), ['a']), L)[1])(%s)" % seq)
            self.obs("(lambda L: (L.__delitem__(slice(None, None, 2)), L)[1])(%s)" % seq)

    def u_numeric(self):
        a = self.pick(["7", "-7", "0", "2 ** 63", "-(2 ** 63) - 1", "3.5", "-0.0", "float('nan')", "1e16", "0.1",
                       "True", "10 ** 20", "2.5", "-2.5", "1j", "255"])
        b = self.pick(["2", "-2", "3", "0", "0.5", "-3.0", "True", "1e-5", "64", "float('inf')"])
        self.obs(self.pick(["divmod({a}, {b})", "({a}) // ({b})", "({a}) % ({b})", "round({a}), round({a}, 1)", "pow({a}, {b})",
                       "({a}) ** ({b})", "({a}) < ({b}), ({a}) == ({b}), ({a}) != ({b})", "hash({a}) == hash({a})",
                       "abs({a}) + abs({b})", "str({a}) + '|' + repr({b})", "max({a}, {b}), min({a}, {b})",
                       "format({a}, '.3g') + '|' + format({b}, 'g')", "({a}) & ({b})", "~({a})", "-({a}), +({b})", "int({a})",
                       "float({a})", "({a}).real, ({b}).imag", "({a}) * ({b})", "({a}) / ({b})", "({a}) - ({b})",
                       "complex({a}, {b})", "({a}).conjugate()", "({a}).__round__()", "({a}).bit_length()",
                       "({a}).is_integer()", "({a}).as_integer_ratio()", "({a}).hex()", "int({a}).to_bytes(9, 'little', signed=True)"])
            .format(a=a, b=b))

    def u_augassign(self):
        x = self.pick(["[1]", "(1,)", "'s'", "5", "{'a': 1}", "{1}", "frozenset({2})", "2.5", "b'x'", "bytearray(b'y')"])
        y = self.pick(["[2]", "(2,)", "'t'", "3", "{'b': 2}", "{3}", "range(2)", "0.5", "b'z'", "None", "'s'"])
        op = self.pick(["+=", "-=", "*=", "|=", "&=", "^=", "//=", "%=", "**=", "<<=", "@="])
        tag = self.tag()
        self.out += ["try:", "    _x = %s" % x, "    _alias = _x", "    _x %s %s" % (op, y),
                     "    print(%r, '=', _r((_x, _x is _alias)))" % tag,
                     "except BaseException as e:", "    print(%r, '!', type(e).__name__, str(e))" % tag]

    def u_strmeth(self):
        s = self.pick(["'a,b,,c'", "'  pad  '", "'Hello World'", "'tab\\tsep'", "''", "'a-b-c'", "'ÄÖü'", "'x'"])
        self.obs("(%s).%s" % (s, self.pick([
            "split(',', 1)", "rsplit('-', 1)", "split()", "center(10, '*')", "ljust(6, '.')", "rjust(2)",
            "expandtabs(4)", "partition('-')", "rpartition('x')", "title()", "swapcase()", "casefold()",
            "zfill(6)", "count('')", "find('', 2)", "replace('', '|')", "strip('ap ')", "splitlines(True)",
            "encode('ascii', 'replace')", "encode('utf-8')[:4]", "removeprefix('a')", "isidentifier()",
            "startswith(('a', 'H'))", "index('zz')", "format_map({})", "translate({97: 'A'})", "join([])",
            "__mul__(2)", "__contains__('')", "__getitem__(slice(None, None, -2))", "upper().lower()"])))

    def u_dictset(self):
        d = self.pick(["{'a': 1, 'b': 2}", "{}", "{1: 'x', True: 'y'}", "dict(a=1)"])
        e = self.pick(["{'b': 3}", "{'c': 4}", "{}"])
        st = self.pick(["{1, 2, 3}", "set()", "frozenset({1, 4})", "{2}"])
        self.obs(self.pick(["%s | %s" % (d, e), "{**%s, **%s}" % (d, e), "list((%s).items()) + list((%s).keys())" % (d, e),
                            "(%s).keys() & (%s).keys()" % (d, e), "(%s).keys() - {'a'}" % d, "sorted(%s ^ %s)" % (st, "{1, 9}"),
                            "%s <= %s, %s < %s" % (st, "{1, 2, 3, 4}", st, st), "(%s).popitem() if %s else 'empty'" % (d, d),
                            "dict.fromkeys(%s, 0)" % st, "list(reversed(%s))" % d, "(%s).setdefault('z', [])" % d,
                            "sorted(%s | frozenset({7}))" % st, "type(%s | frozenset()).__name__" % st, "len(%s)" % d,
                            "%s == %s" % (d, e), "%s == dict(%s)" % (d, d), "(%s).get('a', 'dflt')" % d,
                            "{k: v for k, v in sorted((%s).items(), key=repr)}" % d, "%s.isdisjoint(%s)" % (st, "{9}")]))

    def program(self, units):
        kinds = [self.u_exprs, self.u_class, self.u_class, self.u_closure, self.u_comp, self.u_exc,
                 self.u_gen, self.u_unpack, self.u_format, self.u_slices, self.u_numeric, self.u_augassign,
                 self.u_strmeth, self.u_dictset]
        for _ in range(units):
            self.pick(kinds)()
        return HARNESS + "\n".join(self.out) + "\n"


# ── running ──────────────────────────────────────────────────────────────────

ADDR = re.compile(r"0x[0-9a-fA-F]+")


def norm(text):
    out = []
    for line in text.replace("\r\n", "\n").splitlines():
        line = ADDR.sub("0x?", line)
        out.append(line.rstrip())
    return out


def run(cmd, path, timeout):
    try:
        p = subprocess.run(cmd + [path], capture_output=True, text=True, errors="replace", timeout=timeout,
                           stdin=subprocess.DEVNULL, cwd=os.path.dirname(path),
                           env=dict(os.environ, PYTHONHASHSEED="0"))
        return norm(p.stdout) + (["<exit %d>" % p.returncode] if p.returncode else [])
    except subprocess.TimeoutExpired:
        return ["<timeout>"]


def engines(args):
    e = {}
    if args.lang == "py":
        e["python3"] = [args.python]
    for name in args.engines.split(","):
        e[name] = [args.bin] + (["--vm"] if name == "vm" else [])
    return e


def tagged(lines):
    d = {}
    order = []
    for ln in lines:
        m = re.match(r"(t\d+) ([=!]) ?(.*)$", ln)
        if m:
            if m.group(1) not in d:
                order.append(m.group(1))
            d.setdefault(m.group(1), []).append(m.group(2) + " " + m.group(3))
        else:
            d.setdefault("_other", []).append(ln)
    return d


def kind(line):
    # the signature of one observation: a value, or an exception's type
    if line is None:
        return "missing"
    if line.startswith("!"):
        return "raises " + line.split()[1] if len(line.split()) > 1 else "raises"
    return "value"


def disagreements(outs, ref):
    """{(engine, tag): (ref line, engine line)} for every observation that differs."""
    found = {}
    R = tagged(outs[ref])
    for eng, lines in outs.items():
        if eng == ref:
            continue
        E = tagged(lines)
        for t in set(R) | set(E):
            a, b = R.get(t), E.get(t)
            if a != b:
                found[(eng, t)] = ("\n".join(a) if a else None, "\n".join(b) if b else None)
    return found


def signature(eng, a, b):
    ka = kind(a.split("\n")[0] if a else None)
    kb = kind(b.split("\n")[0] if b else None)
    return (eng, ka, kb)


def write_tmp(src, suffix, d):
    fd, p = tempfile.mkstemp(suffix=suffix, dir=d)
    with os.fdopen(fd, "w") as f:
        f.write(src)
    return p


def outputs(src, args, d):
    p = write_tmp(src, "." + args.lang, d)
    try:
        return {name: run(cmd, p, args.timeout) for name, cmd in engines(args).items()}
    finally:
        os.unlink(p)


# ── delta debugging ──────────────────────────────────────────────────────────


def ddmin(items, test):
    """Zeller and Hildebrandt's ddmin: a 1-minimal sublist of `items` that
    still passes `test` (which must pass for `items`)."""
    n = 2
    while len(items) >= 2:
        chunk = max(1, len(items) // n)
        subsets = [items[i:i + chunk] for i in range(0, len(items), chunk)]
        progressed = False
        for i, s in enumerate(subsets):
            comp = [x for j, t in enumerate(subsets) if j != i for x in t]
            if test(s):
                items, n, progressed = s, 2, True
                break
            if len(subsets) > 2 and test(comp):
                items, n, progressed = comp, max(n - 1, 2), True
                break
        if not progressed:
            if n >= len(items):
                break
            n = min(len(items), n * 2)
    return items


class Reducer:
    def __init__(self, src, eng, tag, sig, args, d):
        self.args, self.d = args, d
        self.eng, self.tag, self.sig = eng, tag, sig
        self.tree = ast.parse(src)
        self.tests = 0
        self.cache = {}

    def interesting(self, tree):
        try:
            src = ast.unparse(ast.fix_missing_locations(tree))
            compile(src, "<reduce>", "exec")
        except Exception:
            return False
        if src in self.cache:
            return self.cache[src]
        self.tests += 1
        a = argparse.Namespace(**vars(self.args))
        a.engines = self.eng if self.eng != "python3" else a.engines
        outs = outputs(src, a, self.d)
        ref = "python3" if self.args.lang == "py" else "interp"
        dis = disagreements(outs, ref)
        ok = False
        for (eng, t), (x, y) in dis.items():
            if eng == self.eng and t == self.tag and signature(eng, x, y) == self.sig:
                ok = True
        self.cache[src] = ok
        return ok

    def bodies(self, node):
        for field in ("body", "orelse", "finalbody", "handlers"):
            v = getattr(node, field, None)
            if isinstance(v, list) and v and isinstance(v[0], (ast.stmt, ast.excepthandler)):
                yield node, field
        for child in ast.iter_child_nodes(node):
            yield from self.bodies(child)

    def reduce_lists(self):
        changed = True
        while changed:
            changed = False
            for owner, field in list(self.bodies(self.tree)):
                cur = getattr(owner, field)
                if len(cur) <= 1 and field != "handlers":
                    continue

                def test(sub, owner=owner, field=field, cur=cur):
                    if not sub and field in ("body", "handlers") and not isinstance(owner, ast.Module):
                        return False
                    setattr(owner, field, sub)
                    ok = self.interesting(self.tree)
                    setattr(owner, field, cur)
                    return ok
                new = ddmin(list(cur), test)
                if len(new) < len(cur):
                    setattr(owner, field, new)
                    changed = True

    def reduce_exprs(self):
        # each expression replaced by a child expression or a constant, while
        # the disagreement stays (one pass over the tree per change)
        changed = True
        while changed:
            changed = False
            for node in list(ast.walk(self.tree)):
                for field, value in ast.iter_fields(node):
                    if not isinstance(value, ast.expr) or isinstance(value, (ast.Constant, ast.Name)):
                        continue
                    cands = [c for c in ast.iter_child_nodes(value) if isinstance(c, ast.expr)]
                    cands += [ast.Constant(1), ast.Constant("a"), ast.Constant(None)]
                    for c in cands:
                        setattr(node, field, c)
                        if self.interesting(self.tree):
                            changed = True
                            break
                        setattr(node, field, value)
                    if changed:
                        break
                if changed:
                    break

    def run(self):
        self.reduce_lists()
        self.reduce_exprs()
        self.reduce_lists()
        return ast.unparse(self.tree) + "\n"


# ── the driver ───────────────────────────────────────────────────────────────


def one(seed, args, d):
    src = Gen(seed).program(args.units)
    outs = outputs(src, args, d)
    ref = "python3" if args.lang == "py" else "interp"
    return seed, src, outs, disagreements(outs, ref)


def show(outs, tags=None):
    for name, lines in outs.items():
        print("── %s" % name)
        for ln in lines:
            if tags is None or ln.split(" ", 1)[0] in tags or not re.match(r"t\d+ ", ln):
                print("   " + ln)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--python", default="python3")
    ap.add_argument("--engines", default="interp,vm")
    ap.add_argument("--lang", choices=["py", "ny"], default="py")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--units", type=int, default=6)
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("-j", "--jobs", type=int, default=2)
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "difftest"))
    ap.add_argument("--no-reduce", action="store_true")
    ap.add_argument("--max-reduce", type=int, default=40, help="disagreement groups to reduce")
    ap.add_argument("--run", metavar="PROG")
    ap.add_argument("--reduce", metavar="PROG")
    ap.add_argument("--print", metavar="SEED", type=int, help="print the program a seed generates")
    args = ap.parse_args()
    args.bin = os.path.abspath(args.bin)
    if args.lang == "ny" and args.engines == "interp,vm":
        pass
    os.makedirs(args.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="difftest_")
    ref = "python3" if args.lang == "py" else "interp"
    if args.lang == "ny":
        args.engines = "interp,vm"

    if args.print is not None:
        sys.stdout.write(Gen(args.print).program(args.units))
        return 0
    if args.run or args.reduce:
        src = open(args.run or args.reduce).read()
        outs = outputs(src, args, work)
        dis = disagreements(outs, ref)
        if args.run:
            show(outs)
            for (eng, t), (a, b) in sorted(dis.items()):
                print("DIFF %s %s: %s | %s" % (eng, t, a, b))
            return 1 if dis else 0
        if not dis:
            print("no disagreement")
            return 0
        (eng, t), (a, b) = sorted(dis.items())[0]
        red = Reducer(src, eng, t, signature(eng, a, b), args, work).run()
        print(red)
        show(outputs(red, args, work), {t})
        return 1

    groups = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for seed, src, outs, dis in ex.map(lambda s: one(s, args, work), range(args.seed, args.seed + args.count)):
            for (eng, t), (a, b) in dis.items():
                # the same disagreement on every engine is one finding,
                # reduced on the first of them
                same = sorted([eng] + [e for (e, t2), (a2, b2) in dis.items() if t2 == t and e != eng and b2 == b])
                if eng != same[0]:
                    continue
                label = "+".join(same)
                sig = signature(eng, a, b)
                # finer: the exception types / first words of each side
                key = (label, (a or "")[:60], (b or "")[:60]) if sig[1] == sig[2] == "value" else (label,) + sig + ((a or "").split("\n")[0][:40],)
                groups.setdefault(key, []).append((seed, t, src, a, b, sig, label))
    print("%d programs, %d disagreeing observations in %d groups" % (
        args.count, sum(len(v) for v in groups.values()), len(groups)))
    findings = []
    seen_src = set()
    for i, (key, items) in enumerate(sorted(groups.items(), key=lambda kv: -len(kv[1]))):
        seed, t, src, a, b, sig, label = items[0]
        red = src
        if not args.no_reduce and i < args.max_reduce:
            red = Reducer(src, sig[0], t, sig, args, work).run()
        h = hashlib.sha1((red + "\0" + label + "\0" + t).encode()).hexdigest()[:10]   # (one finding per program, engines and tag)
        if h in seen_src:
            continue
        seen_src.add(h)
        outs = outputs(red, args, work)
        path = os.path.join(args.out, "finding_%s.py" % h)
        with open(path, "w") as f:
            f.write("# difftest finding: %s (seed %d, tag %s, %d occurrences)\n" % (label, seed, t, len(items)))
            for name, lines in outs.items():
                for ln in lines:
                    if ln.startswith(t + " ") or not re.match(r"t\d+ ", ln):
                        f.write("# %-8s %s\n" % (name, ln))
            f.write(red)
        findings.append((len(items), label, path, a, b))
    for n, label, path, a, b in findings:
        print("%4d x %-9s %s: %s\n         nython:  %s\n         %s" % (
            n, label, ref, (a or "<missing>").split("\n")[0][:110], (b or "<missing>").split("\n")[0][:110], path))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
