# vm_audit87.ny - values and errors as Python has them, both engines (round 77).
#
# `in` and ordering TypeErrors; exceptions' str / repr / args and the
# fields OSError and the Unicode errors carry (errno, strerror, filename,
# filename2; encoding, object, start, end, reason) - also on the errors the
# native file layer and the codecs raise; KeyError(key) from the runtime;
# `except obj.attr`; iter(callable, sentinel) and next(it, default);
# gen.throw(type, value, tb) and a bare `raise` in a helper called from an
# except clause; __format__ in f-strings and format(); os.stat_result,
# os.terminal_size, os.times(), os.uname(); generators' __name__, gi_frame,
# gi_code, gi_running, gi_yieldfrom; exec(src, ns) with ns as the live
# globals of what it defines; the reprs of builtin values (floats, recursive
# containers, sets, bytes, complex).
#
# The shared part runs under python3 too (`python3 examples/vm_audit87.ny`);
# every expected value there is CPython's.
#
#     ./build/nython-cli examples/vm_audit87.ny
#     ./build/nython-cli --vm examples/vm_audit87.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import os
import json
import tempfile

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    # [exception class name, str(e)] of what f() raises, or ["ok", repr(result)]
    try:
        r = f()
        return ["ok", repr(r)]
    except Exception as e:
        return [type(e).__name__, str(e)]

# ── `in` and ordering raise TypeError ────────────────────────────────────────
check("in a non-container",
      [err(lambda: 1 in 5), err(lambda: 1 in None), err(lambda: "a" in 5.0), err(lambda: 1 in "abc")],
      [["TypeError", "argument of type 'int' is not iterable"], ["TypeError", "argument of type 'NoneType' is not iterable"],
       ["TypeError", "argument of type 'float' is not iterable"], ["TypeError", "'in <string>' requires string as left operand, not int"]])
check("in still works",
      [1 in [1, 2], "b" in "abc", 3 in (1, 2), "k" in {"k": 1}, 2 in {2}, b"a" in b"abc", 97 in b"abc", 5 not in [1]],
      [True, True, False, True, True, True, True, True])
check("mixed-type ordering",
      [err(lambda: 1 < "a"), err(lambda: [] < 3), err(lambda: None < 1), err(lambda: "a" >= 2),
       err(lambda: {} < {}), err(lambda: (1,) < [1]), err(lambda: [1] < ["a"]), err(lambda: 3 > None)],
      [["TypeError", "'<' not supported between instances of 'int' and 'str'"],
       ["TypeError", "'<' not supported between instances of 'list' and 'int'"],
       ["TypeError", "'<' not supported between instances of 'NoneType' and 'int'"],
       ["TypeError", "'>=' not supported between instances of 'str' and 'int'"],
       ["TypeError", "'<' not supported between instances of 'dict' and 'dict'"],
       ["TypeError", "'<' not supported between instances of 'tuple' and 'list'"],
       ["TypeError", "'<' not supported between instances of 'int' and 'str'"],
       ["TypeError", "'>' not supported between instances of 'int' and 'NoneType'"]])
check("ordering that works",
      [1 < 2.5, True < 2, [1] < [1, 2], (1, "a") < (1, "b"), "a" < "b", b"a" < b"b", [1, [2]] <= [1, [2]],
       float("nan") < 1, [float("nan")] < [1], 2 >= 2.0],
      [True, True, True, True, True, True, True, False, False, True])

# ── exceptions: str, repr, args ──────────────────────────────────────────────
check("KeyError is shown by its key's repr",
      [str(KeyError("k")), repr(KeyError("k")), str(KeyError("k", 2)), str(KeyError()), str(KeyError(5)), KeyError("k").args],
      ["'k'", "KeyError('k')", "('k', 2)", "", "5", ("k",)])
check("BaseException's str and repr",
      [repr(ValueError("x")), repr(ValueError()), repr(ValueError("x", 1)), str(ValueError("x", 1)), str(ValueError()),
       str(Exception(5)), repr(Exception(5)), repr(TypeError([1, "a"])), str(LookupError("a", "b"))],
      ["ValueError('x')", "ValueError()", "ValueError('x', 1)", "('x', 1)", "", "5", "Exception(5)",
       "TypeError([1, 'a'])", "('a', 'b')"])
check("args", [ValueError("x", 1).args, ValueError().args, RuntimeError("r").args], [("x", 1), (), ("r",)])
def runtime_key(f):
    try:
        f()
    except KeyError as e:
        return [str(e), e.args, repr(e)]
def del_q():
    d = {}
    del d["q"]
check("KeyError from the runtime carries the key",
      [runtime_key(lambda: {}["k"]), runtime_key(lambda: {}[5]), runtime_key(lambda: {}[(1, 2)]),
       runtime_key(lambda: {1}.remove(3)), runtime_key(lambda: {}.pop("z")), runtime_key(del_q)],
      [["'k'", ("k",), "KeyError('k')"], ["5", (5,), "KeyError(5)"], ["(1, 2)", ((1, 2),), "KeyError((1, 2))"],
       ["3", (3,), "KeyError(3)"], ["'z'", ("z",), "KeyError('z')"], ["'q'", ("q",), "KeyError('q')"]])

o2 = OSError(2, "No such file")
o3 = OSError(2, "No such file", "f.txt")
o5 = OSError(13, "Permission denied", "a.txt", None, "b.txt")
check("OSError(errno, strerror, filename)",
      [str(o2), str(o3), str(o5), o3.errno, o3.strerror, o3.filename, o5.filename2, o3.args, o2.args, o5.args],
      ["[Errno 2] No such file", "[Errno 2] No such file: 'f.txt'", "[Errno 13] Permission denied: 'a.txt' -> 'b.txt'",
       2, "No such file", "f.txt", "b.txt", (2, "No such file"), (2, "No such file"), (13, "Permission denied")])
check("OSError(errno, ...) is the subclass for that errno",
      [type(o2).__name__, type(o5).__name__, type(OSError(17, "x")).__name__, type(OSError(99999, "x")).__name__,
       type(OSError("x")).__name__, isinstance(o2, OSError)],
      ["FileNotFoundError", "PermissionError", "FileExistsError", "OSError", "OSError", True])
check("OSError without an errno",
      [OSError("x").errno, OSError("x").strerror, OSError("x").filename, OSError("x").args, str(OSError("x")),
       str(OSError()), OSError(2, "x", None).args, str(OSError(2, "x", None))],
      [None, None, None, ("x",), "x", "", (2, "x", None), "[Errno 2] x"])
check("FileNotFoundError(2, msg, name)",
      [str(FileNotFoundError(2, "No such file or directory", "a")), FileNotFoundError(2, "x").errno,
       repr(FileNotFoundError(2, "x"))],
      ["[Errno 2] No such file or directory: 'a'", 2, "FileNotFoundError(2, 'x')"])
check("OSError's str follows its fields",
      [str(OSError(2, "x", "it's")), (lambda e: [e.errno, str(e)])(OSError(5, "io"))],
      ["[Errno 2] x: \"it's\"", [5, "[Errno 5] io"]])
check("SystemExit.code and StopIteration.value",
      [SystemExit(3).code, SystemExit().code, SystemExit(1, 2).code, StopIteration(3).value, StopIteration().value],
      [3, None, (1, 2), 3, None])

ude = UnicodeDecodeError("utf-8", b"\xff\xfe", 0, 1, "invalid start byte")
check("UnicodeDecodeError's fields and str",
      [ude.encoding, ude.object, ude.start, ude.end, ude.reason, str(ude), len(ude.args),
       str(UnicodeDecodeError("utf-8", b"\xe2\x82", 0, 2, "unexpected end of data"))],
      ["utf-8", b"\xff\xfe", 0, 1, "invalid start byte", "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte", 5,
       "'utf-8' codec can't decode bytes in position 0-1: unexpected end of data"])
uee = UnicodeEncodeError("ascii", "a\xe9b", 1, 2, "ordinal not in range(128)")
check("UnicodeEncodeError's fields and str",
      [uee.encoding, uee.object, uee.start, uee.end, str(uee),
       str(UnicodeEncodeError("ascii", "€€", 0, 2, "nope"))],
      ["ascii", "a\xe9b", 1, 2, "'ascii' codec can't encode character '\\xe9' in position 1: ordinal not in range(128)",
       "'ascii' codec can't encode characters in position 0-1: nope"])
check("UnicodeTranslateError's str",
      [str(UnicodeTranslateError("€", 0, 1, "bad")), UnicodeTranslateError("ab", 0, 2, "r").encoding],
      ["can't translate character '\\u20ac' in position 0: bad", None])
def decode_fields():
    try:
        b"ab\xff".decode("utf-8")
    except UnicodeDecodeError as e:
        return [e.encoding, e.object, e.start, e.end, e.reason, str(e)]
def encode_fields():
    try:
        "x\xe9".encode("ascii")
    except UnicodeEncodeError as e:
        return [e.encoding, e.object, e.start, e.end, e.reason, str(e)]
check("the codecs' errors carry the fields",
      [decode_fields(), encode_fields()],
      [["utf-8", b"ab\xff", 2, 3, "invalid start byte", "'utf-8' codec can't decode byte 0xff in position 2: invalid start byte"],
       ["ascii", "x\xe9", 1, 2, "ordinal not in range(128)", "'ascii' codec can't encode character '\\xe9' in position 1: ordinal not in range(128)"]])

class ParseError(Exception):
    def __init__(self, msg, line):
        self.msg = msg
        self.line = line
        super().__init__(msg, line)
    def __str__(self):
        return self.msg + " at line " + str(self.line)
class Computed(Exception):
    def __init__(self, a, b):
        super().__init__("computed %s-%s" % (a, b))
        self.a = a
class NoSuper(Exception):
    def __init__(self, x):
        self.x = x
class OwnStr(ValueError):
    def __str__(self):
        return "custom"
class OwnRepr(ValueError):
    def __repr__(self):
        return "<own>"
check("a subclass's own message is kept",
      [str(ParseError("bad token", 3)), ParseError("bad token", 3).msg, ParseError("bad token", 3).args,
       str(Computed(1, 2)), Computed(1, 2).args, repr(Computed(1, 2))],
      ["bad token at line 3", "bad token", ("bad token", 3), "computed 1-2", ("computed 1-2",), "Computed('computed 1-2')"])
check("args come from the constructor without super().__init__",
      [str(NoSuper(5)), NoSuper(5).args, repr(NoSuper(5)), NoSuper(5).x], ["5", (5,), "NoSuper(5)", 5])
check("__str__ and __repr__ of exception subclasses",
      [str(OwnStr("a")), repr(OwnStr("a")), str(OwnRepr("a")), repr(OwnRepr("a")), repr([OwnRepr("b")])],
      ["custom", "OwnStr('a')", "a", "<own>", "[<own>]"])
se = SyntaxError("bad", ("prog.py", 3, 5, "x = (", 3, 6))
check("SyntaxError's fields and str",
      [se.msg, se.filename, se.lineno, se.offset, se.text, se.end_lineno, se.end_offset, str(se), len(se.args),
       str(SyntaxError("m", ("/a/b/f.py", 7, 1, "t"))), str(SyntaxError("only")), SyntaxError("only").msg,
       SyntaxError("only").lineno],
      ["bad", "prog.py", 3, 5, "x = (", 3, 6, "bad (prog.py, line 3)", 2, "m (f.py, line 7)", "only", "only", None])
def compile_error():
    try:
        compile("x = (", "<snippet>", "exec")
    except SyntaxError as e:
        return [isinstance(e.msg, str), len(str(e)) > 0]
check("a SyntaxError from compile() has its msg", compile_error(), [True, True])
check("ImportError.msg", [ImportError("no mod").msg, ImportError("a", "b").msg, str(ImportError("no mod"))],
      ["no mod", None, "no mod"])
def zde():
    try:
        1 // 0
    except ZeroDivisionError as e:
        return [hasattr(e, "msg"), e.args, str(e)]
check("no msg attribute on other exceptions",
      [hasattr(ValueError("x"), "msg"), zde()], [False, [False, ("integer division or modulo by zero",), "integer division or modulo by zero"]])
class MyOSError(OSError):
    pass
check("an OSError subclass parses its arguments too",
      [MyOSError(2, "x", "f").filename, str(MyOSError(2, "x", "f")), type(MyOSError(2, "x")).__name__],
      ["f", "[Errno 2] x: 'f'", "MyOSError"])

# ── OSErrors from the native file layer ──────────────────────────────────────
base = os.path.join(tempfile.gettempdir(), "ny_audit87_" + str(os.getpid()))
missing = os.path.join(base, "nope")
os.mkdir(base)
def oserr(f):
    try:
        f()
        return "no error"
    except OSError as e:
        return [type(e).__name__, e.errno, e.strerror, e.filename, e.filename2, str(e)]
def fnf(name):
    return ["FileNotFoundError", 2, "No such file or directory", name, None, "[Errno 2] No such file or directory: " + repr(name)]
def fnf2(a, b):
    return ["FileNotFoundError", 2, "No such file or directory", a, b, "[Errno 2] No such file or directory: " + repr(a) + " -> " + repr(b)]
check("open / stat / listdir / remove / rmdir a missing path",
      [oserr(lambda: open(missing)), oserr(lambda: os.stat(missing)), oserr(lambda: os.listdir(missing)),
       oserr(lambda: os.remove(missing)), oserr(lambda: os.rmdir(missing)), oserr(lambda: os.lstat(missing))],
      [fnf(missing), fnf(missing), fnf(missing), fnf(missing), fnf(missing), fnf(missing)])
check("rename gives both names",
      [oserr(lambda: os.rename(missing, missing + "2")), oserr(lambda: os.replace(missing, missing + "3"))],
      [fnf2(missing, missing + "2"), fnf2(missing, missing + "3")])
check("mkdir of an existing directory",
      oserr(lambda: os.mkdir(base)), ["FileExistsError", 17, "File exists", base, None, "[Errno 17] File exists: " + repr(base)])
def catch_by_class():
    try:
        open(missing)
    except FileNotFoundError as e:
        return [e.filename == missing, e.errno, isinstance(e, OSError)]
check("except FileNotFoundError as e: e.filename", catch_by_class(), [True, 2, True])
f1 = os.path.join(base, "f1.txt")
fh = open(f1, "w")
fh.write("hello")
fh.close()
os.rename(f1, f1 + ".b")
check("os.rename / os.replace / os.listdir work", [os.listdir(base), os.path.exists(f1)], [["f1.txt.b"], False])
os.replace(f1 + ".b", f1)
if hasattr(os, "link") and os.name != "nt":
    os.link(f1, f1 + ".lnk")
    check("os.link", [sorted(os.listdir(base)), oserr(lambda: os.link(f1, f1 + ".lnk"))[1]], [["f1.txt", "f1.txt.lnk"], 17])
    os.remove(f1 + ".lnk")

# ── os.stat_result, os.terminal_size, os.times(), os.uname() ────────────────
st = os.stat(f1)
check("os.stat() is an os.stat_result",
      [type(st).__name__, st.st_size, st[6], st.st_mode == st[0], st.st_ino == st[1], st.st_dev == st[2],
       st.st_nlink == st[3], st.st_uid == st[4], st.st_gid == st[5], len(st), len(list(st)), tuple(st)[6]],
      ["stat_result", 5, 5, True, True, True, True, True, True, 10, 10, 5])
check("stat times",
      [isinstance(st.st_mtime, float), isinstance(st[8], int), st[8] == int(st.st_mtime), isinstance(st.st_mtime_ns, int),
       st.st_mtime_ns // 1000000000 == st[8], isinstance(st.st_atime, float), isinstance(st.st_ctime, float)],
      [True, True, True, True, True, True, True])
check("stat_result slicing, comparison, repr", [st[6:7], st[-4], st == tuple(st), repr(st)[:26]],
      [(5,), 5, True, "os.stat_result(st_mode=" + str(st.st_mode)[:3]])
check("os.lstat / os.fstat", [type(os.lstat(f1)).__name__, os.lstat(f1).st_size], ["stat_result", 5])
fh = open(f1)
check("os.fstat(fd)", [os.fstat(fh.fileno()).st_size, os.stat(fh.fileno()).st_size], [5, 5])
fh.close()
sr = os.stat_result((1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
check("os.stat_result(seq)",
      [sr.st_size, sr.st_mtime, sr[9], repr(sr), err(lambda: os.stat_result((1, 2)))],
      [7, 9, 10, "os.stat_result(st_mode=1, st_ino=2, st_dev=3, st_nlink=4, st_uid=5, st_gid=6, st_size=7, st_atime=8, st_mtime=9, st_ctime=10)",
       ["TypeError", "os.stat_result() takes an at least 10-sequence (2-sequence given)"]])
check("stat_result is read-only", err(lambda: setattr(st, "st_size", 1))[0], "AttributeError")
ts = os.terminal_size((80, 24))
cols, lines = ts
check("os.terminal_size",
      [ts.columns, ts.lines, ts[0], ts[1], repr(ts), len(ts), tuple(ts), ts == (80, 24), cols, lines,
       err(lambda: os.terminal_size((1, 2, 3)))],
      [80, 24, 80, 24, "os.terminal_size(columns=80, lines=24)", 2, (80, 24), True, 80, 24,
       ["TypeError", "os.terminal_size() takes a 2-sequence (3-sequence given)"]])
def term():
    try:
        t = os.get_terminal_size()
        return [type(t).__name__, isinstance(t.columns, int), isinstance(t.lines, int)]
    except OSError as e:
        # off a console: on Windows a Windows error (winerror 6, errno EBADF
        # mapped from it, "[WinError 6] ..."), as CPython gives
        if os.name == "nt":
            return ["terminal_size", e.errno is not None, e.winerror == 6 and str(e).startswith("[WinError 6] ")]
        return ["terminal_size", e.errno is not None, True]
check("os.get_terminal_size()", term(), ["terminal_size", True, True])
tm = os.times()
check("os.times()",
      [type(tm).__name__, len(tm), [isinstance(getattr(tm, n), float) for n in ["user", "system", "children_user", "children_system", "elapsed"]],
       tm[0] == tm.user],
      ["times_result", 5, [True, True, True, True, True], True])
if hasattr(os, "uname"):
    un = os.uname()
    check("os.uname()",
          [type(un).__name__, len(un), un[0] == un.sysname, isinstance(un.release, str), isinstance(un.nodename, str),
           isinstance(un.machine, str), isinstance(un.version, str), repr(un)[:27]],
          ["uname_result", 5, True, True, True, True, True, "posix.uname_result(sysname="])
os.remove(f1)
os.rmdir(base)
check("cleaned up", os.path.exists(base), False)

# ── except with an attribute expression ──────────────────────────────────────
class NS:
    pass
ns_obj = NS()
class MyE(Exception):
    pass
ns_obj.E = MyE
def ex_attr():
    try:
        raise MyE("a")
    except ns_obj.E as e:
        return "caught " + str(e)
def ex_mod():
    try:
        json.loads("{")
    except json.JSONDecodeError as e:
        return "json " + type(e).__name__
def ex_tuple():
    try:
        raise KeyError("z")
    except (ns_obj.E, KeyError) as e:
        return "tuple " + type(e).__name__
check("except obj.attr / mod.Error", [ex_attr(), ex_mod(), ex_tuple()],
      ["caught a", "json JSONDecodeError", "tuple KeyError"])

# ── iter(callable, sentinel), next(it, default) ──────────────────────────────
def counter_fn(limit):
    box = [0]
    def nxt():
        box[0] += 1
        return box[0] if box[0] < limit else None
    return nxt
check("iter(callable, sentinel)",
      [list(iter(counter_fn(4), None)), [x * 10 for x in iter(counter_fn(3), None)]],
      [[1, 2, 3], [10, 20]])
it_s = iter(counter_fn(3), None)
check("next over iter(callable, sentinel)", [next(it_s), next(it_s), next(it_s, "done"), next(it_s, "done2")],
      [1, 2, "done", "done2"])
class Ticker:
    def __init__(self):
        self.n = 0
    def __call__(self):
        self.n += 1
        return self.n
check("a callable object and a sentinel", list(iter(Ticker(), 4)), [1, 2, 3])
check("iter(v, w) needs a callable", err(lambda: iter(5, 0)), ["TypeError", "iter(v, w): v must be callable"])
check("next(it, default) on every iterator kind",
      [next(iter([]), "d"), next(iter([1]), "d"), next(iter(""), "d"), next(iter({}), "d"), next(iter(()), "d"),
       next(iter(set()), "d"), next(iter(range(0)), "d"), next(iter(b""), "d"), next((x for x in []), "d"),
       next(iter([]), None)],
      ["d", 1, "d", "d", "d", "d", "d", "d", "d", None])
def gen_empty():
    return
    yield 1
def gen_two():
    yield 1
    yield 2
g2 = gen_two()
check("next(gen, default)", [next(gen_empty(), "e"), next(g2, "e"), next(g2, "e"), next(g2, "e")], ["e", 1, 2, "e"])
class Cnt:
    def __init__(self):
        self.i = 0
    def __iter__(self):
        return self
    def __next__(self):
        self.i += 1
        if self.i > 2:
            raise StopIteration
        return self.i
c3 = Cnt()
check("next(obj, default)", [next(c3, "d"), next(c3, "d"), next(c3, "d")], [1, 2, "d"])
check("next() of a non-iterator", [err(lambda: next([1])), err(lambda: next(5))],
      [["TypeError", "'list' object is not an iterator"], ["TypeError", "'int' object is not an iterator"]])

# ── generator throw forms; a bare raise in a helper ──────────────────────────
def catcher():
    try:
        yield 1
    except ValueError as e:
        yield "caught " + repr(e)
    yield 3
def throw_with(*a):
    g = catcher()
    next(g)
    try:
        return g.throw(*a)
    except Exception as e:
        return "propagated " + repr(e)
check("gen.throw forms",
      [throw_with(ValueError), throw_with(ValueError("inst")), throw_with(ValueError, "val"),
       throw_with(ValueError, ValueError("v"), None), throw_with(ValueError, ("a", "b")), throw_with(ValueError, None),
       throw_with(KeyError, "kk"), throw_with(ValueError("x"), "y")],
      ["caught ValueError()", "caught ValueError('inst')", "caught ValueError('val')", "caught ValueError('v')",
       "caught ValueError('a', 'b')", "caught ValueError()", "propagated KeyError('kk')",
       "propagated TypeError('instance exception may not have a separate value')"])
def reraiser():
    raise
def bare_nested():
    try:
        try:
            raise ValueError("inner")
        except ValueError:
            reraiser()
    except ValueError as e:
        return "re " + str(e)
def bare_closure():
    def helper():
        raise
    try:
        try:
            raise KeyError("k2")
        except KeyError:
            helper()
    except KeyError as e:
        return "re2 " + repr(e)
def bare_none():
    try:
        reraiser()
    except RuntimeError as e:
        return "rt " + str(e)
check("bare raise in a helper called from an except clause", [bare_nested(), bare_closure(), bare_none()],
      ["re inner", "re2 KeyError('k2')", "rt No active exception to reraise"])

# ── __format__ ───────────────────────────────────────────────────────────────
class F:
    def __format__(self, spec):
        return "F<" + spec + ">"
    def __repr__(self):
        return "Frepr"
    def __str__(self):
        return "Fstr"
class G:
    def __repr__(self):
        return "Grepr"
class Bad:
    def __format__(self, spec):
        return 5
fo = F()
check("f-strings and format() call __format__",
      [f"{fo}", f"{fo:>10}", f"{fo!r}", f"{fo!s}", format(fo, "abc"), format(fo), "{} {:x}".format(fo, fo), "{!r}".format(fo),
       f"{fo:{'ab'}}"],
      ["F<>", "F<>10>", "Frepr", "Fstr", "F<abc>", "F<>", "F<> F<x>", "Frepr", "F<ab>"])
check("object.__format__",
      [format(G()), f"{G()}", f"{G()!r}", err(lambda: format(G(), "10")), err(lambda: f"{G():>4}")],
      ["Grepr", "Grepr", "Grepr", ["TypeError", "unsupported format string passed to G.__format__"],
       ["TypeError", "unsupported format string passed to G.__format__"]])
check("__format__ must return a str", err(lambda: format(Bad(), "")), ["TypeError", "__format__ must return a str, not int"])
check("builtin values' __format__",
      [(255).__format__("x"), "ab".__format__(">4"), (1.5).__format__(".2f"), format(255, "#x"), f"{'x'!r:>5}",
       format(True, ">6"), err(lambda: format([1], ">6"))],
      ["ff", "  ab", "1.50", "0xff", "  'x'", "     1", ["TypeError", "unsupported format string passed to list.__format__"]])

# ── generators' attributes ───────────────────────────────────────────────────
def gen1():
    yield 1
    yield 2
class K:
    def meth(self):
        yield 5
g = gen1()
check("generator names", [g.__name__, g.__qualname__, K().meth().__name__, K().meth().__qualname__, (x for x in []).__name__],
      ["gen1", "gen1", "meth", "K.meth", "<genexpr>"])
check("gi_code, gi_running, gi_yieldfrom",
      [g.gi_code.co_name, g.gi_code.co_name == gen1.__code__.co_name, g.gi_running, g.gi_yieldfrom, g.gi_frame is not None],
      ["gen1", True, False, None, True])
def finished():
    h = gen1()
    list(h)
    return [h.gi_frame, h.gi_running]
def closed():
    h = gen1()
    next(h)
    h.close()
    return h.gi_frame
def running_inside():
    box = []
    def gg():
        box.append(hh.gi_running)
        yield 1
    hh = gg()
    next(hh)
    return box
def yield_from_active():
    def inner():
        yield 1
        yield 2
    def outer():
        yield from inner()
    o = outer()
    before = o.gi_yieldfrom
    next(o)
    return [before, o.gi_yieldfrom is not None, o.gi_yieldfrom.__name__]
def frame_lines():
    def gg():
        x = 1
        yield x
        yield 2
    h = gg()
    first = h.gi_frame.f_lineno
    next(h)
    second = h.gi_frame.f_lineno
    next(h)
    third = h.gi_frame.f_lineno
    return [second - first, third - first, h.gi_frame.f_code.co_name]
check("gi_frame", [finished(), closed(), running_inside(), yield_from_active(), frame_lines()],
      [[None, False], None, [True], [None, True, "inner"], [2, 3, "gg"]])

# ── exec(src, ns): ns is the live globals ────────────────────────────────────
def exec_exports():
    ns = {}
    exec("def __foo__():\n    return 1\nclass __Bar__:\n    pass\n__x__ = 3\ny = 4", ns)
    return [sorted(k for k in ns if k != "__builtins__"), ns["__foo__"](), ns["__x__"]]
def exec_live():
    ns = {"a": 1}
    exec("def f():\n    return a", ns)
    ns["a"] = 2
    return ns["f"]()
def exec_late():
    ns = {}
    exec("def f():\n    return b", ns)
    ns["b"] = 7
    return ns["f"]()
def exec_global_writes():
    ns = {}
    exec("x = 1\ndef inc():\n    global x\n    x += 1\n", ns)
    ns["inc"]()
    ns["inc"]()
    return ns["x"]
def exec_patched():
    ns = {}
    exec("def f():\n    return g()\ndef g():\n    return 'g'", ns)
    ns["g"] = lambda: "patched"
    return ns["f"]()
def exec_locals():
    gl = {}
    lo = {}
    exec("z = 5", gl, lo)
    return ["z" in gl, lo.get("z")]
def exec_name():
    ns = {"__name__": "mymod"}
    exec("n = __name__", ns)
    return ns["n"]
def eval_live():
    ns = {"q": 1}
    f = eval("lambda: q", ns)
    ns["q"] = 5
    return f()
check("exec namespaces",
      [exec_exports(), exec_live(), exec_late(), exec_global_writes(), exec_patched(), exec_locals(), exec_name(),
       eval("a + b", {"a": 1, "b": 2}), eval_live()],
      [[["__Bar__", "__foo__", "__x__", "y"], 1, 3], 2, 7, 3, "patched", [False, 5], "mymod", 3, 5])

# ── reprs of builtin values ──────────────────────────────────────────────────
check("float reprs",
      [repr(1e16), repr(1e15), repr(-0.0), repr(float("inf")), repr(float("-inf")), repr(float("nan")), repr(1.5e-7),
       repr(0.1), repr(1 / 3), repr(123456789012345678.0), repr(1e-4), repr(1e-5), repr(2.0), repr(1e22), repr(5e-324),
       str(1e16), str(-0.0), str(100.0), repr([1.0, -0.0, 1e100]), f"{1e16}", "%r" % -0.0, "%s" % 1e16],
      ["1e+16", "1000000000000000.0", "-0.0", "inf", "-inf", "nan", "1.5e-07", "0.1", "0.3333333333333333",
       "1.2345678901234568e+17", "0.0001", "1e-05", "2.0", "1e+22", "5e-324", "1e+16", "-0.0", "100.0",
       "[1.0, -0.0, 1e+100]", "1e+16", "-0.0", "1e+16"])
def rec_list():
    a = [1]
    a.append(a)
    return repr(a)
def rec_dict():
    d = {}
    d["self"] = d
    return repr(d)
def rec_mutual():
    a = [1]
    b = [a]
    a.append(b)
    return [repr(a), repr(b)]
def rec_through_tuple():
    t = ([],)
    t[0].append(t)
    return repr(t)
def rec_dict_list():
    d = {"l": []}
    d["l"].append(d)
    return str(d)
def shared():
    a = []
    return repr([a, a, (a,)])
check("recursive containers",
      [rec_list(), rec_dict(), rec_mutual(), rec_through_tuple(), rec_dict_list(), shared()],
      ["[1, [...]]", "{'self': {...}}", ["[1, [[...]]]", "[[1, [...]]]"], "([(...)],)", "{'l': [{...}]}", "[[], [], ([],)]"])
check("nested containers", [repr([1, [2, (3, "a")], {"k": [4.5]}, (4,), ()]), str([1, "a", ("b",), {"c": "d"}])],
      ["[1, [2, (3, 'a')], {'k': [4.5]}, (4,), ()]", "[1, 'a', ('b',), {'c': 'd'}]"])
check("sets", [repr(set()), repr({1}), repr(frozenset()), repr(frozenset({1})), str({"a"}), repr({(1, 2)})],
      ["set()", "{1}", "frozenset()", "frozenset({1})", "{'a'}", "{(1, 2)}"])
check("bytes", [repr(b""), repr(b"a'b"), repr(b'a"b'), repr(b"\x00\xff\n\t\\"), repr(bytearray(b"x")), str(b"ab"),
                repr(bytearray())],
      ["b''", "b\"a'b\"", "b'a\"b'", "b'\\x00\\xff\\n\\t\\\\'", "bytearray(b'x')", "b'ab'", "bytearray(b'')"])
check("complex", [repr(1j), repr(1 + 2j), repr(-1j), repr(complex(1, 0)), repr(complex(0, 0)), str(2.5j), repr(1e20j)],
      ["1j", "(1+2j)", "(-0-1j)", "(1+0j)", "0j", "2.5j", "1e+20j"])
check("strings and tuples",
      [repr("a'b"), repr('a"b'), repr("\n\t\x00\x7f"), repr("\xe9"), repr("​"), repr("\\"), repr((1,)), repr(((),))],
      ["\"a'b\"", "'a\"b'", "'\\n\\t\\x00\\x7f'", "'\xe9'", "'\\u200b'", "'\\\\'", "(1,)", "((),)"])
check("ints, types, slices, Ellipsis",
      [repr(10 ** 30), repr(-5), repr(int), repr(len), repr(slice(1, 2, 3)), repr(...), repr(NotImplemented)],
      ["1000000000000000000000000000000", "-5", "<class 'int'>", "<built-in function len>", "slice(1, 2, 3)",
       "Ellipsis", "NotImplemented"])
check("an exception in a container", [repr([ValueError("x")]), str((KeyError("k"),))],
      ["[ValueError('x')]", "(KeyError('k'),)"])

# ── Nython only ──────────────────────────────────────────────────────────────
if nython:
    # true / none are Nython's spelling, by design
    check("Nython's spellings stay", [repr(True), repr(None), str([None, True]), format(None)],
          ["true", "none", "[none, true]", "none"])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT87 PASSED ===")
