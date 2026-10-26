# vm_audit126.ny - the semantic gaps round 86 found, both engines (round 87,
# part K).
#
#  1. input() with sys.stdin / sys.stdout replaced uses the objects'
#     readline() / write() / flush() as CPython's input() does off a
#     terminal (it read the process's stdin whatever sys.stdin was);
#     None is CPython's "lost sys.stdin" RuntimeError.
#  2. f.__defaults__ / f.__kwdefaults__ assigned are what later calls use
#     (they were only remembered); TypeError for a non-tuple / non-dict,
#     None and del remove them, inspect.signature sees them.
#  3. C.__bases__ assigned rebuilds the MRO of C and its subclasses at once,
#     with CPython's checks and messages (layout, cycles, duplicates, MRO).
#  4. tempfile.mkstemp returns an OS descriptor (os.write / os.close /
#     os.fdopen take it), mode 0o600, bytes components give a bytes path.
#  5. socket.sendmsg(buffers, ancdata, flags, address) sends to the address
#     (a datagram socket); recvmsg returns the sender's address.
#  6. *x / **x of what is not an iterable / a mapping: CPython's messages
#     ("Value after * must be an iterable, not NoneType", "f() argument after
#     ** must be a mapping, not int", "keywords must be strings", "got
#     multiple values for keyword argument").
#  7. Python-language source: a plain dict's keys are not attributes for a
#     method call or del either ({"f": g}.f() is an AttributeError).
#  8. Python-language source: `super` is an ordinary name (a variable, a
#     parameter, a module's own def); only super(...) is the builtin's call.
#  9. Messages name a class of an imported module by its __name__, reprs by
#     its module and __qualname__, as CPython's.
# 10. A TLS handshake still running when asyncio.run() ends is cancelled and
#     its socket closed (client and server side).
#
# Items 7 and 8 run as a Python-language child (a .py file) on the same
# engine. The checks pass under python3 too (the Nython-only ones are marked):
#
#     ./build/nython-cli examples/vm_audit126.ny
#     ./build/nython-cli --vm examples/vm_audit126.ny
#     python3 examples/vm_audit126.ny

import os, sys, io, re, inspect, tempfile, subprocess, socket, shutil

NYTHON = sys.implementation.name == "nython"
ENGINE = ["--vm"] if NYTHON and "--vm" in getattr(sys, "orig_argv", []) else []
POSIX = os.name != "nt"
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    # the exception a call raises, as (type name, text)
    try:
        f()
    except BaseException as e:
        return (type(e).__name__, str(e))
    return "no error"

def scrub(s):
    return re.sub(r"0x[0-9a-fA-F]+", "0x?", s)

T = tempfile.mkdtemp(prefix="ny126_%d_" % os.getpid())

def run_py(src, name):
    # a Python-language program on this engine (a .py file), its output
    p = os.path.join(T, name)
    with open(p, "w") as f:
        f.write(src)
    r = subprocess.run([sys.executable] + ENGINE + [p], capture_output=True, text=True, timeout=300, cwd=T)
    return r.stdout.replace("\r\n", "\n"), r.stderr

# ── 1. input() with replaced streams ─────────────────────────────────────────
class Reader:
    def __init__(self, lines):
        self.lines = list(lines)
        self.calls = 0
    def readline(self):
        self.calls += 1
        return self.lines.pop(0) if self.lines else ""

class Writer:
    # write only: input() ignores a stream without flush, as CPython's
    def __init__(self):
        self.out = []
    def write(self, s):
        self.out.append(s)
        return len(s)

class FlushWriter(Writer):
    def flush(self):
        self.out.append("<flush>")

old_in, old_out, old_err = sys.stdin, sys.stdout, sys.stderr
try:
    sys.stdin = io.StringIO("hello\nworld\nlast")
    sys.stdout = io.StringIO()
    got1 = [input("p1> "), input(), input("x")]
    try:
        input("y")
        got1.append("no EOFError")
    except EOFError as e:
        got1.append(("EOFError", str(e)))
    shown1 = sys.stdout.getvalue()
finally:
    sys.stdin, sys.stdout = old_in, old_out
check("input() reads sys.stdin (a StringIO) line by line, EOFError at its end", got1,
      ["hello", "world", "last", ("EOFError", "EOF when reading a line")])
check("input()'s prompts go to sys.stdout (a StringIO)", shown1, "p1> xy")

w = FlushWriter()
r = Reader(["one\n", "two\r\n"])
try:
    sys.stdin = r
    sys.stdout = w
    got2 = [input(5), input("q")]
finally:
    sys.stdin, sys.stdout = old_in, old_out
check("an object with readline / write / flush: str(prompt) written, flushed, the newline taken off",
      [got2, w.out, r.calls], [["one", "two\r"], ["5", "<flush>", "q", "<flush>"], 2])

w2 = Writer()
try:
    sys.stdin = Reader(["x\n"])
    sys.stdout = w2
    got3 = input("b> ")
finally:
    sys.stdin, sys.stdout = old_in, old_out
check("a stdout without flush is written to (flush not required)", [got3, w2.out], ["x", ["b> "]])

try:
    sys.stdin = Reader(["s\n"])
    sys.stderr = Writer()
    got4 = input()
finally:
    sys.stdin, sys.stderr = old_in, old_err
check("only stdin replaced: read from it", got4, "s")

class BytesReader:
    def readline(self):
        return b"raw\n"
class IntReader:
    def readline(self):
        return 5
lost = []
for nm, val in (("stdin", None), ("stdout", None), ("stderr", None)):
    saved = getattr(sys, nm)
    try:
        setattr(sys, nm, val)
        lost.append(err(lambda: input()))
    finally:
        setattr(sys, nm, saved)
try:
    sys.stdin = BytesReader()
    lost.append(input())
    sys.stdin = IntReader()
    lost.append(err(lambda: input()))
    sys.stdin = io.StringIO("\n")
    lost.append(input())
finally:
    sys.stdin = old_in
check("input(): lost streams, a bytes line, a non-string line, an empty line", lost,
      [("RuntimeError", "input(): lost sys.stdin"), ("RuntimeError", "input(): lost sys.stdout"),
       ("RuntimeError", "input(): lost sys.stderr"), b"raw", ("TypeError", "object.readline() returned non-string"), ""])

# ── 2. __defaults__ / __kwdefaults__ assigned ────────────────────────────────
def f2(a, b=2, c=3):
    return (a, b, c)
d2 = [f2.__defaults__, f2(1)]
f2.__defaults__ = (20, 30)
d2 += [f2.__defaults__, f2(1), f2(1, 5)]
f2.__defaults__ = (9,)
d2 += [f2(1, 2), err(lambda: f2(1))]
f2.__defaults__ = (7, 8, 9)
d2 += [f2(), str(inspect.signature(f2))]
f2.__defaults__ = None
d2 += [f2.__defaults__, err(lambda: f2(1, 2)), err(lambda: setattr(f2, "__defaults__", [1]))]
check("f.__defaults__ assigned: what calls use, aligned to the last positional parameters", d2,
      [(2, 3), (1, 2, 3), (20, 30), (1, 20, 30), (1, 5, 30), (1, 2, 9),
       ("TypeError", "f2() missing 1 required positional argument: 'b'"), (7, 8, 9), "(a=7, b=8, c=9)", None,
       ("TypeError", "f2() missing 1 required positional argument: 'c'"),
       ("TypeError", "__defaults__ must be set to a tuple object")])

def g2(a):
    return a
g2.__defaults__ = (5,)
e2 = [g2(), str(inspect.signature(g2)), g2.__defaults__]
del g2.__defaults__
e2 += [g2.__defaults__, err(lambda: g2())]
t2 = (1, 2)
f2.__defaults__ = t2
e2 += [f2.__defaults__ is t2, f2(0)]
f2.__defaults__ = ()
e2 += [f2.__defaults__, err(lambda: f2(0))]
check("a function without defaults given some; del removes them; the tuple set is the one read", e2,
      [5, "(a=5)", (5,), None, ("TypeError", "g2() missing 1 required positional argument: 'a'"),
       True, (0, 1, 2), (), ("TypeError", "f2() missing 2 required positional arguments: 'b' and 'c'")])

def h2(a, *, k=1, m):
    return (a, k, m)
k2 = [h2.__kwdefaults__]
h2.__kwdefaults__ = {"k": 10, "m": 20}
k2 += [h2(1), h2.__kwdefaults__, str(inspect.signature(h2))]
h2.__kwdefaults__ = None
k2 += [err(lambda: h2(1)), err(lambda: setattr(h2, "__kwdefaults__", 5)), h2(1, k=2, m=3)]
check("f.__kwdefaults__ assigned: the keyword-only parameters' defaults", k2,
      [{"k": 1}, (1, 10, 20), {"k": 10, "m": 20}, "(a, *, k=10, m=20)",
       ("TypeError", "h2() missing 2 required keyword-only arguments: 'k' and 'm'"),
       ("TypeError", "__kwdefaults__ must be set to a dict object"), (1, 2, 3)])

lam2 = lambda x, y=1: x + y
lam2.__defaults__ = (100,)
class C2:
    def m(self, x=1):
        return x
    def n(self, x, *rest, y=2):
        return (x, rest, y)
C2.m.__defaults__ = (42,)
C2.n.__defaults__ = ("dx",)
C2.n.__kwdefaults__ = {"y": "dy"}
def mk2():
    def inner(p=0):
        return p
    return inner
i1, i2 = mk2(), mk2()
i1.__defaults__ = (11,)
def gen2(a=1):
    yield a
gen2.__defaults__ = (3,)
check("lambdas, methods (bound later), closures each their own, generator functions",
      [lam2(1), C2().m(), C2().n(), C2().n(5, 6), i1(), i2(), list(gen2())],
      [101, 42, ("dx", (), "dy"), (5, (6,), "dy"), 11, 0, [3]])

# ── 3. __bases__ assigned ────────────────────────────────────────────────────
class A3:
    def who(self):
        return "A"
    x = 1
class B3:
    def who(self):
        return "B"
    x = 2
    def only_b(self):
        return "ob"
class C3(A3):
    pass
class D3(C3):
    pass
c3, d3 = C3(), D3()
b3 = [c3.who(), d3.who(), C3.x, [k.__name__ for k in D3.__mro__]]
C3.__bases__ = (B3,)
b3 += [c3.who(), d3.who(), C3.x, d3.only_b(), [k.__name__ for k in C3.__mro__], [k.__name__ for k in D3.__mro__]]
b3 += [C3.__bases__ == (B3,), issubclass(C3, B3), issubclass(C3, A3), isinstance(d3, B3), isinstance(d3, A3)]
C3.__bases__ = (A3, B3)
b3 += [c3.who(), d3.only_b(), [k.__name__ for k in D3.__mro__], C3.__base__.__name__]
check("C.__bases__ assigned: the MRO of C and of its subclasses follows at once", b3,
      ["A", "A", 1, ["D3", "C3", "A3", "object"], "B", "B", 2, "ob", ["C3", "B3", "object"], ["D3", "C3", "B3", "object"],
       True, True, False, True, False, "A", "ob", ["D3", "C3", "A3", "B3", "object"], "A3"])

class E3(A3):
    pass
class F3(B3, A3):
    pass
bad3 = []
for v in [5, (), [A3], (5,), (D3,), (C3,), (int,), (list,), (Exception,), (A3, A3), (A3, F3), (int, str), (bool,)]:
    bad3.append(err(lambda: setattr(C3, "__bases__", v)))
bad3.append(err(lambda: delattr(C3, "__bases__")))
bad3.append([k.__name__ for k in C3.__mro__])
check("C.__bases__: CPython's checks and messages, the class unchanged after them", bad3,
      [("TypeError", "can only assign tuple to C3.__bases__, not int"),
       ("TypeError", "can only assign non-empty tuple to C3.__bases__, not ()"),
       ("TypeError", "can only assign tuple to C3.__bases__, not list"),
       ("TypeError", "C3.__bases__ must be tuple of classes, not 'int'"),
       ("TypeError", "a __bases__ item causes an inheritance cycle"),
       ("TypeError", "a __bases__ item causes an inheritance cycle"),
       ("TypeError", "__bases__ assignment: 'int' deallocator differs from 'A3'"),
       ("TypeError", "__bases__ assignment: 'list' object layout differs from 'A3'"),
       ("TypeError", "__bases__ assignment: 'Exception' object layout differs from 'A3'"),
       ("TypeError", "duplicate base class A3"),
       ("TypeError", "Cannot create a consistent method resolution\norder (MRO) for bases A3, F3"),
       ("TypeError", "multiple bases have instance lay-out conflict"),
       ("TypeError", "type 'bool' is not an acceptable base type"),
       ("TypeError", "cannot delete '__bases__' attribute of immutable type 'C3'"),
       ["C3", "A3", "B3", "object"]])

class P3:
    pass
class X3(Exception):
    pass
class I3(int):
    pass
class J3(I3):
    pass
lay3 = [err(lambda: setattr(P3, "__bases__", (A3,))), err(lambda: setattr(X3, "__bases__", (object,))),
        err(lambda: setattr(J3, "__bases__", (A3,))), err(lambda: setattr(J3, "__bases__", (int,))),
        err(lambda: setattr(int, "__bases__", (A3,))), err(lambda: setattr(object, "__bases__", (A3,)))]
X3.__bases__ = (ValueError,)
try:
    raise X3("v")
except ValueError as e:
    lay3.append(["caught as ValueError", str(e)])
lay3.append([A3.__subclasses__() == [C3, E3, F3], B3.__subclasses__() == [C3, F3]])
check("layouts: a class of object takes no heap base; exceptions swap among their layout; builtins are immutable", lay3,
      [("TypeError", "__bases__ assignment: 'A3' deallocator differs from 'object'"),
       ("TypeError", "__bases__ assignment: 'object' deallocator differs from 'Exception'"),
       ("TypeError", "__bases__ assignment: 'A3' object layout differs from 'I3'"),
       ("TypeError", "__bases__ assignment: 'int' deallocator differs from 'I3'"),
       ("TypeError", "cannot set '__bases__' attribute of immutable type 'int'"),
       ("TypeError", "cannot set '__bases__' attribute of immutable type 'object'"),
       ["caught as ValueError", "v"], [True, True]])

class S3:
    def __init__(self):
        self.v = 1
    def m(self):
        return self.v
class T3(S3):
    pass
t3 = T3()
warm = [t3.m() for i in range(50)]
class U3:
    def m(self):
        return 99
T3.__bases__ = (U3,)
def sup3():
    class Q1:
        def f(self):
            return "Q1"
    class Q2:
        def f(self):
            return "Q2"
    class K(Q1):
        def f(self):
            return "K" + super().f()
    k = K()
    r = [k.f()]
    K.__bases__ = (Q2,)
    r.append(k.f())
    return r
check("a method looked up many times (the engines' caches), then super() after a change",
      [t3.m(), [t3.m() for i in range(3)], sup3()], [99, [99, 99, 99], ["KQ1", "KQ2"]])

# ── 4. tempfile.mkstemp ──────────────────────────────────────────────────────
import stat as stat_mod
fd4, path4 = tempfile.mkstemp(suffix=".txt", prefix="ny126_", dir=T)
m4 = [isinstance(fd4, int), os.path.basename(path4).startswith("ny126_"), path4.endswith(".txt"), os.path.isabs(path4)]
if POSIX:
    m4.append(oct(stat_mod.S_IMODE(os.stat(path4).st_mode)))
else:
    m4.append("0o600")
m4.append(os.write(fd4, b"hello"))
os.lseek(fd4, 0, 0)
m4.append(os.read(fd4, 10))
fo4 = os.fdopen(fd4, "r+")
fo4.seek(0)
m4.append(fo4.read())
fo4.close()
m4.append(err(lambda: os.close(fd4))[0])
os.unlink(path4)
fd4b, path4b = tempfile.mkstemp(dir=T.encode(), prefix=b"b")
m4 += [type(path4b).__name__, os.path.basename(path4b).startswith(b"b")]
os.close(fd4b)
fd4c, path4c = tempfile.mkstemp(text=True, dir=T)
with os.fdopen(fd4c, "w") as fo:
    fo.write("text\n")
with open(path4c) as fi:
    m4.append(fi.read())
m4.append(err(lambda: tempfile.mkstemp(dir=T, prefix=b"x"))[0])
m4.append(type(tempfile.mkdtemp(dir=T.encode())).__name__)
check("tempfile.mkstemp: an OS descriptor, mode 0o600, bytes paths, text mode", m4,
      [True, True, True, True, "0o600", 5, b"hello", "hello", "OSError", "bytes", True, "text\n", "TypeError", "bytes"])

# ── 5. sendmsg / recvmsg with addresses ──────────────────────────────────────
if POSIX and hasattr(socket.socket, "sendmsg"):
    a5 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    a5.bind(("127.0.0.1", 0))
    b5 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    b5.bind(("127.0.0.1", 0))
    a5.settimeout(10)
    s5 = [b5.sendmsg([b"he", b"llo"], [], 0, a5.getsockname())]
    data5, anc5, flags5, addr5 = a5.recvmsg(100)
    s5 += [data5, anc5, flags5, addr5 == b5.getsockname()]
    s5.append(b5.sendmsg([memoryview(b"mv")], (), 0, a5.getsockname()))
    s5.append(a5.recvfrom(10)[0])
    b5.connect(a5.getsockname())
    s5.append(b5.sendmsg([b"connected"]))
    s5.append(a5.recvmsg(4)[0])
    s5.append(err(lambda: b5.sendmsg([b"x"], [], 0, "not an address"))[0])
    a5.close()
    b5.close()
    check("sendmsg to an address (UDP); recvmsg gives the sender's address", s5,
          [5, b"hello", [], 0, True, 2, b"mv", 9, b"conn", "TypeError"])
    if hasattr(socket, "AF_UNIX"):
        u1, u2 = socket.socketpair()
        u1.sendmsg([b"pair"])
        r5 = u2.recvmsg(10)
        check("recvmsg on a connected stream socket: no address", [r5[0], r5[3] in (None, "")], [b"pair", True])
        u1.close()
        u2.close()

# ── 6. *x and **x of a wrong kind ────────────────────────────────────────────
def f6(*a, **k):
    return (a, k)
class C6:
    def m(self, *a, **k):
        return (a, k)
class NotMap6:
    def __getitem__(self, k):
        return 1
class Map6:
    def keys(self):
        return ["x"]
    def __getitem__(self, k):
        return 9
none6 = None
flt6 = 1.5
nm6 = NotMap6()
s6 = [err(lambda: [*none6]), err(lambda: (*flt6,)), err(lambda: {*none6}), err(lambda: [1, *none6]),
      err(lambda: f6(*none6)), err(lambda: f6(**none6)), err(lambda: {**none6}), err(lambda: f6(1, *flt6)),
      err(lambda: f6(*none6, **none6)), err(lambda: f6(**[1])), err(lambda: {**[1]}), err(lambda: C6().m(*none6)),
      err(lambda: C6().m(**flt6)), err(lambda: f6(**nm6)), err(lambda: {**nm6}), err(lambda: f6(**{1: 2})),
      err(lambda: f6(**{"a": 1}, **{"a": 2})), err(lambda: f6(**{"a": 1}, a=2)), err(lambda: len(*none6)),
      f6(**Map6()), {**Map6()}, f6(*"ab", **{"z": 1}), [*"ab", *[1]], sorted({*"ab"})]
check("*x / **x: CPython's messages, the callee named", [scrub(str(x)) for x in s6],
      [str(x) for x in [
          ("TypeError", "Value after * must be an iterable, not NoneType"),
          ("TypeError", "Value after * must be an iterable, not float"),
          ("TypeError", "'NoneType' object is not iterable"),
          ("TypeError", "Value after * must be an iterable, not NoneType"),
          ("TypeError", "__main__.f6() argument after * must be an iterable, not NoneType"),
          ("TypeError", "__main__.f6() argument after ** must be a mapping, not NoneType"),
          ("TypeError", "'NoneType' object is not a mapping"),
          ("TypeError", "Value after * must be an iterable, not float"),
          ("TypeError", "__main__.f6() argument after ** must be a mapping, not NoneType"),
          ("TypeError", "__main__.f6() argument after ** must be a mapping, not list"),
          ("TypeError", "'list' object is not a mapping"),
          ("TypeError", "__main__.C6.m() argument after * must be an iterable, not NoneType"),
          ("TypeError", "__main__.C6.m() argument after ** must be a mapping, not float"),
          ("TypeError", "__main__.f6() argument after ** must be a mapping, not NotMap6"),
          ("TypeError", "'NotMap6' object is not a mapping"),
          ("TypeError", "keywords must be strings"),
          ("TypeError", "__main__.f6() got multiple values for keyword argument 'a'"),
          ("TypeError", "__main__.f6() got multiple values for keyword argument 'a'"),
          ("TypeError", "len() argument after * must be an iterable, not NoneType"),
          ((), {"x": 9}), {"x": 9}, (("a", "b"), {"z": 1}), ["a", "b", 1], ["a", "b"]]])

# ── 7 and 8: a Python-language program ───────────────────────────────────────
CHILD78 = '''
def t(label, fn):
    try:
        print(label, "=", repr(fn()))
    except Exception as e:
        print(label, "!", type(e).__name__, e)
d = {"f": lambda: 1, "k": 2, "keys": 3}
t("d.k", lambda: d.k)
t("d.f()", lambda: d.f())
t("getattr", lambda: getattr(d, "k"))
t("getattr default", lambda: getattr(d, "k", "dflt"))
t("hasattr", lambda: hasattr(d, "k"))
def st():
    d.z = 1
t("d.z = 1", st)
t("setattr", lambda: setattr(d, "z", 1))
t("d.keys()", lambda: sorted(d.keys()))
t("d.get", lambda: d.get("k"))
def de():
    del d.k
t("del d.k", de)
t("delattr", lambda: delattr(d, "k"))
t("d.f.__name__", lambda: d.f.__name__)
t("d intact", lambda: sorted(d))
n = 5
t("[*n]", lambda: [*n])
t("(*n,)", lambda: (*n,))
t("{*n}", lambda: {*n})
def f(*a, **k):
    return a
t("f(*n)", lambda: f(*n))
t("f(**n)", lambda: f(**n))
t("{**n}", lambda: {**n})
t("[1, *n]", lambda: [1, *n])
class Base:
    def m(self):
        return "base"
class Kid(Base):
    def m(self):
        return "kid+" + super().m()
    def n(self):
        return super(Kid, self).m()
t("super()", lambda: (Kid().m(), Kid().n()))
def take(super=3):
    return super * 2
t("a parameter named super", lambda: (take(), take(super=5)))
class Obj:
    pass
o = Obj()
o.super = 7
t("an attribute named super", lambda: o.super)
t("a lambda parameter", lambda: (lambda super: super + 1)(1))
t("a comprehension variable", lambda: [super for super in range(3)])
super = 10
t("super = 10", lambda: super + 1)
del super
def super():
    return "mine"
t("a module's own def super()", lambda: super())
del super
t("super() after del", lambda: Kid().m())
def shadow(super):
    return super(4)
t("a parameter called", lambda: shadow(lambda v: v * 3))
'''
EXPECTED78 = [
    "d.k ! AttributeError 'dict' object has no attribute 'k'",
    "d.f() ! AttributeError 'dict' object has no attribute 'f'",
    "getattr ! AttributeError 'dict' object has no attribute 'k'",
    "getattr default = 'dflt'",
    "hasattr = False",
    "d.z = 1 ! AttributeError 'dict' object has no attribute 'z'",
    "setattr ! AttributeError 'dict' object has no attribute 'z'",
    "d.keys() = ['f', 'k', 'keys']",
    "d.get = 2",
    "del d.k ! AttributeError 'dict' object has no attribute 'k'",
    "delattr ! AttributeError 'dict' object has no attribute 'k'",
    "d.f.__name__ ! AttributeError 'dict' object has no attribute 'f'",
    "d intact = ['f', 'k', 'keys']",
    "[*n] ! TypeError Value after * must be an iterable, not int",
    "(*n,) ! TypeError Value after * must be an iterable, not int",
    "{*n} ! TypeError 'int' object is not iterable",
    "f(*n) ! TypeError __main__.f() argument after * must be an iterable, not int",
    "f(**n) ! TypeError __main__.f() argument after ** must be a mapping, not int",
    "{**n} ! TypeError 'int' object is not a mapping",
    "[1, *n] ! TypeError Value after * must be an iterable, not int",
    "super() = ('kid+base', 'base')",
    "a parameter named super = (6, 10)",
    "an attribute named super = 7",
    "a lambda parameter = 2",
    "a comprehension variable = [0, 1, 2]",
    "super = 10 = 11",
    "a module's own def super() = 'mine'",
    "super() after del = 'kid+base'",
    "a parameter called = 12",
]
out78, err78 = run_py(CHILD78, "child126.py")
lines78 = out78.strip().split("\n")
for i, want in enumerate(EXPECTED78):
    check("Python-language source: " + want.split(" ")[0], lines78[i] if i < len(lines78) else err78[-300:], want)

# ── 9. class names in messages and reprs ─────────────────────────────────────
os.makedirs(os.path.join(T, "pkg126"))
with open(os.path.join(T, "pkg126", "__init__.py"), "w") as f:
    f.write("")
with open(os.path.join(T, "pkg126", "mod.py"), "w") as f:
    f.write("class Obj:\n    class Inner:\n        pass\n    def meth(self):\n        pass\n"
            "class WithRepr:\n    def __repr__(self):\n        return 'WR'\ndef func():\n    pass\n")
sys.path.insert(0, T)
from pkg126.mod import Obj, func, WithRepr
import pkg126.mod as mod126
sys.path.remove(T)
o9 = Obj()
i9 = Obj.Inner()
n9 = [repr(type(o9)), repr(Obj), repr(Obj.Inner), scrub(repr(o9)), scrub(repr(i9)), scrub(str(o9)),
      Obj.__module__, Obj.__qualname__, Obj.Inner.__qualname__, Obj.__name__, Obj.Inner.__name__,
      scrub(repr(func)), scrub(repr(Obj.meth)), scrub(repr(o9.meth)), str(type(o9)), "%s" % (type(o9),), repr(WithRepr())]
check("reprs: module and __qualname__", n9,
      ["<class 'pkg126.mod.Obj'>", "<class 'pkg126.mod.Obj'>", "<class 'pkg126.mod.Obj.Inner'>",
       "<pkg126.mod.Obj object at 0x?>", "<pkg126.mod.Obj.Inner object at 0x?>", "<pkg126.mod.Obj object at 0x?>",
       "pkg126.mod", "Obj", "Obj.Inner", "Obj", "Inner", "<function func at 0x?>", "<function Obj.meth at 0x?>",
       "<bound method Obj.meth of <pkg126.mod.Obj object at 0x?>>", "<class 'pkg126.mod.Obj'>", "<class 'pkg126.mod.Obj'>", "WR"])
m9 = [err(lambda: o9 + 1), err(lambda: 1 + o9), err(lambda: o9 < o9), err(lambda: o9()), err(lambda: o9.nosuch),
      err(lambda: o9[0]), err(lambda: len(o9)), err(lambda: iter(o9)), err(lambda: -o9), err(lambda: Obj.nosuch),
      err(lambda: o9.meth(1)), err(lambda: [1] + o9), err(lambda: i9 + i9), err(lambda: int(o9)),
      err(lambda: abs(o9)), err(lambda: 1 in o9), err(lambda: next(o9)), err(lambda: Obj(1)), err(lambda: mod126.nosuch),
      err(lambda: float(o9)), err(lambda: list(o9)), err(lambda: round(o9)), err(lambda: sorted([o9, o9])),
      err(lambda: max(o9, o9)), err(lambda: 1 < o9), err(lambda: o9 ** 2), err(lambda: ~o9), err(lambda: hash([o9]))]
check("messages: a class by its __name__", [x[1] for x in m9],
      ["unsupported operand type(s) for +: 'Obj' and 'int'", "unsupported operand type(s) for +: 'int' and 'Obj'",
       "'<' not supported between instances of 'Obj' and 'Obj'", "'Obj' object is not callable",
       "'Obj' object has no attribute 'nosuch'", "'Obj' object is not subscriptable", "object of type 'Obj' has no len()",
       "'Obj' object is not iterable", "bad operand type for unary -: 'Obj'", "type object 'Obj' has no attribute 'nosuch'",
       "Obj.meth() takes 1 positional argument but 2 were given",
       'can only concatenate list (not "Obj") to list', "unsupported operand type(s) for +: 'Inner' and 'Inner'",
       "int() argument must be a string, a bytes-like object or a real number, not 'Obj'", "bad operand type for abs(): 'Obj'",
       "argument of type 'Obj' is not iterable", "'Obj' object is not an iterator", "Obj() takes no arguments",
       "module 'pkg126.mod' has no attribute 'nosuch'", "float() argument must be a string or a real number, not 'Obj'",
       "'Obj' object is not iterable", "type Obj doesn't define __round__ method",
       "'<' not supported between instances of 'Obj' and 'Obj'", "'>' not supported between instances of 'Obj' and 'Obj'",
       "'<' not supported between instances of 'int' and 'Obj'", "unsupported operand type(s) for ** or pow(): 'Obj' and 'int'",
       "bad operand type for unary ~: 'Obj'", "unhashable type: 'list'"])

# ── 10. a TLS handshake when asyncio.run() ends ──────────────────────────────
import asyncio, time
ssl_mod = None
try:
    import ssl as ssl_mod
except ImportError:
    ssl_mod = None
if ssl_mod is not None and getattr(ssl_mod, "HAS_TLS", True):
    # a server that accepts and never answers the ClientHello
    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(4)
    port10 = lsock.getsockname()[1]
    state10 = {}
    async def client10():
        try:
            await asyncio.open_connection("127.0.0.1", port10, ssl=ssl_mod.create_default_context(), server_hostname="localhost")
            state10["outcome"] = "connected"
        except asyncio.CancelledError:
            state10["outcome"] = "cancelled"
            raise
        except BaseException as e:
            state10["outcome"] = type(e).__name__
    async def main10():
        state10["task"] = asyncio.create_task(client10())
        await asyncio.sleep(0.3)
        return "main done"
    t0 = time.monotonic()
    r10 = asyncio.run(main10())
    took10 = time.monotonic() - t0
    lsock.settimeout(10)
    conn10, _ = lsock.accept()
    conn10.settimeout(10)
    try:
        hello = conn10.recv(5)
        rest = b""
        while True:
            more = conn10.recv(65536)
            if not more:
                break
            rest += more
        closed10 = "closed"
    except socket.timeout:
        hello, closed10 = b"", "still open"
    except OSError:
        hello, closed10 = b"", "closed"
    conn10.close()
    lsock.close()
    check("a client's TLS handshake left running by asyncio.run(): cancelled, its socket closed, at once",
          [r10, state10.get("outcome"), state10["task"].cancelled(), hello[:1], closed10, took10 < 20],
          ["main done", "cancelled", True, b"\x16", "closed", True])

def make_certs():
    d = os.path.join(T, "tls")
    os.makedirs(d)
    ext = os.path.join(d, "ext.cnf")
    with open(ext, "w") as f:
        f.write("subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n")
    steps = [["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", d + "/server.key",
              "-out", d + "/server.pem", "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"]]
    for s in steps:
        try:
            r = subprocess.run(s, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            if r.returncode != 0:
                return None
        except Exception:
            return None
    return d

CERTS = make_certs() if ssl_mod is not None and getattr(ssl_mod, "HAS_TLS", True) and shutil.which("openssl") else None
if CERTS is not None:
    # a TLS server whose client connects and never sends its ClientHello
    state10b = {}
    async def main10b():
        served = []
        async def handle(reader, writer):
            served.append("client_connected_cb")
            writer.close()
        sctx = ssl_mod.SSLContext(ssl_mod.PROTOCOL_TLS_SERVER)
        sctx.load_cert_chain(CERTS + "/server.pem", CERTS + "/server.key")
        server = await asyncio.start_server(handle, "127.0.0.1", 0, ssl=sctx, ssl_handshake_timeout=30)
        port = server.sockets[0].getsockname()[1]
        raw = socket.create_connection(("127.0.0.1", port), timeout=10)
        state10b["raw"] = raw
        await asyncio.sleep(0.3)
        state10b["handshake tasks"] = len([t for t in asyncio.all_tasks() if t is not asyncio.current_task()])
        return served
    t0 = time.monotonic()
    r10b = asyncio.run(main10b())
    took10b = time.monotonic() - t0
    raw10 = state10b["raw"]
    try:
        got10b = raw10.recv(100)
    except socket.timeout:
        got10b = "still open"
    except OSError:
        got10b = b""
    raw10.close()
    check("a server's TLS handshake left running by asyncio.run(): a task of the loop, cancelled, the connection closed",
          [r10b, state10b["handshake tasks"], got10b, took10b < 20], [[], 1, b"", True])

# ── done ──────────────────────────────────────────────────────────────────────
shutil.rmtree(T, ignore_errors=True)
pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT126 PASSED ===")
