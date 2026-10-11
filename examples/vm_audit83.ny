# vm_audit83.ny - weakref, warnings and traceback (round 77), both engines.
#
# Exceptions carry real tracebacks now: e.__traceback__ is a chain of
# traceback objects, one per frame the exception passed, as Python's;
# __context__ / __cause__ / __suppress_context__ are set by the engines;
# sys.exc_info() and sys._getframe() work. lib/traceback.ny formats them as
# Python does, lib/warnings.ny finds the warning's location from the running
# frames, and lib/weakref.ny stands on the engines' weak references (with
# callbacks run when the object is freed - by reference counting at once,
# or by the cycle collector).
#
# Every check also runs under python3 (`python3 examples/vm_audit83.ny`);
# every expected value is CPython's. A few Nython-only checks at the end.
#
#     ./build/nython-cli examples/vm_audit83.ny
#     ./build/nython-cli --vm examples/vm_audit83.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import sys
import os
import io
import linecache
import traceback
import warnings
import weakref
import subprocess

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def collect():
    if nython:
        gc_collect()
    else:
        import gc
        gc.collect()

def engine_args():
    # the child runs on the same engine as this program
    if nython and gc_stats()["engine"] == "vm":
        return ["--vm"]
    return []

THIS = os.path.basename(__file__)

def src(filename, lineno):
    return linecache.getline(filename, lineno).strip()

def chain(e):
    # (function, source line) for each entry of e's traceback, outermost first
    out = []
    tb = e.__traceback__
    while tb is not None:
        out.append((tb.tb_frame.f_code.co_name, src(tb.tb_frame.f_code.co_filename, tb.tb_lineno)))
        tb = tb.tb_next
    return out

# ── tracebacks: one entry per frame the exception passed ────────────────────
def tb_inner():
    raise ValueError("deep")
def tb_middle():
    tb_inner()
def tb_outer():
    tb_middle()

try:
    tb_outer()
except ValueError as e:
    check("traceback chain", chain(e),
          [("<module>", "tb_outer()"), ("tb_outer", "tb_middle()"), ("tb_middle", "tb_inner()"),
           ("tb_inner", 'raise ValueError("deep")')])
    check("tb objects", [e.__traceback__.tb_next.tb_frame.f_code.co_name, type(e.__traceback__.tb_lineno).__name__,
                         os.path.basename(e.__traceback__.tb_frame.f_code.co_filename), e.__traceback__.tb_frame.f_globals["__name__"]],
          ["tb_outer", "int", THIS, "__main__"])
    check("sys.exc_info in a handler", [sys.exc_info()[0] is ValueError, sys.exc_info()[1] is e, sys.exc_info()[2] is e.__traceback__],
          [True, True, True])
    tb_saved = e
check("sys.exc_info outside", sys.exc_info(), (None, None, None))
check("a fresh exception", [ValueError("x").__traceback__, ValueError("x").__cause__, ValueError("x").__context__,
                            ValueError("x").__suppress_context__], [None, None, None, False])

def reraiser():
    try:
        tb_inner()
    except ValueError:
        raise
try:
    reraiser()
except ValueError as e:
    check("bare raise keeps the traceback", chain(e),
          [("<module>", "reraiser()"), ("reraiser", "tb_inner()"), ("tb_inner", 'raise ValueError("deep")')])

try:
    raise tb_saved
except ValueError as e:
    check("raise e puts the new frames first", chain(e),
          [("<module>", "raise tb_saved"), ("<module>", "tb_outer()"), ("tb_outer", "tb_middle()"),
           ("tb_middle", "tb_inner()"), ("tb_inner", 'raise ValueError("deep")')])

def reraise_e():
    try:
        tb_inner()
    except ValueError as q:
        raise q
try:
    reraise_e()
except ValueError as e:
    check("raise e in its handler", chain(e),
          [("<module>", "reraise_e()"), ("reraise_e", "raise q"), ("reraise_e", "tb_inner()"),
           ("tb_inner", 'raise ValueError("deep")')])

class TbCM:
    def __enter__(self):
        return self
    def __exit__(self, t, v, tb):
        self.got = (t.__name__, tb is v.__traceback__, tb.tb_frame.f_code.co_name, chain(v))
        return True
cm = TbCM()
def in_with():
    with cm:
        tb_inner()
in_with()
check("__exit__ gets the traceback", cm.got,
      ("ValueError", True, "in_with", [("in_with", "tb_inner()"), ("tb_inner", 'raise ValueError("deep")')]))

def in_finally():
    try:
        tb_inner()
    finally:
        fin_x = 1
try:
    in_finally()
except ValueError as e:
    check("through a finally", chain(e),
          [("<module>", "in_finally()"), ("in_finally", "tb_inner()"), ("tb_inner", 'raise ValueError("deep")')])

def gen_fail():
    yield 1
    raise ValueError("gen")
g = gen_fail()
next(g)
try:
    next(g)
except ValueError as e:
    check("a generator's frame", chain(e), [("<module>", "next(g)"), ("gen_fail", 'raise ValueError("gen")')])

lam = lambda: 1 / 0
try:
    lam()
except ZeroDivisionError as e:
    check("a lambda's frame", chain(e), [("<module>", "lam()"), ("<lambda>", "lam = lambda: 1 / 0")])

try:
    [1][5]
except IndexError as e:
    check("a runtime error's traceback", chain(e), [("<module>", "[1][5]")])

class Thrower:
    @property
    def boom(self):
        raise KeyError("prop")
    def method(self):
        return self.boom
try:
    Thrower().method()
except KeyError as e:
    check("methods and properties", [x[0] for x in chain(e)], ["<module>", "method", "boom"])

def nested_catch():
    try:
        tb_middle()
    except ValueError as e:
        return chain(e)
check("caught in a function", nested_catch(), [("nested_catch", "tb_middle()"), ("tb_middle", "tb_inner()"),
                                               ("tb_inner", 'raise ValueError("deep")')])
check("with_traceback", [ValueError("w").with_traceback(None).__traceback__,
                         tb_saved.with_traceback(tb_saved.__traceback__) is tb_saved], [None, True])

# ── __context__, __cause__, __suppress_context__ ────────────────────────────
try:
    try:
        raise TypeError("first")
    except TypeError:
        raise ValueError("second")
except ValueError as e:
    check("__context__", [type(e.__context__).__name__, str(e.__context__), e.__cause__, e.__suppress_context__],
          ["TypeError", "first", None, False])
    ctx_err = e
try:
    try:
        raise TypeError("first")
    except TypeError as t:
        raise ValueError("second") from t
except ValueError as e:
    check("raise from", [type(e.__cause__).__name__, e.__context__ is e.__cause__, e.__suppress_context__],
          ["TypeError", True, True])
    cause_err = e
try:
    try:
        raise TypeError("first")
    except TypeError:
        raise ValueError("second") from None
except ValueError as e:
    check("raise from None", [e.__cause__, type(e.__context__).__name__, e.__suppress_context__], [None, "TypeError", True])
try:
    raise ValueError("v") from RuntimeError
except ValueError as e:
    check("raise from a class", type(e.__cause__).__name__, "RuntimeError")
try:
    try:
        1 / 0
    except ZeroDivisionError:
        [][1]
except IndexError as e:
    check("a runtime error's __context__", type(e.__context__).__name__, "ZeroDivisionError")
def handler_calls():
    try:
        raise TypeError("t")
    except TypeError:
        tb_inner()
try:
    handler_calls()
except ValueError as e:
    check("context across a call", [type(e.__context__).__name__, chain(e.__context__)],
          ["TypeError", [("handler_calls", 'raise TypeError("t")')]])
try:
    raise ValueError("plain")
except ValueError as e:
    check("no context outside a handler", e.__context__, None)
try:
    try:
        raise TypeError("a")
    except TypeError:
        pass
    raise ValueError("b")
except ValueError as e:
    check("a finished handler is no context", e.__context__, None)

# ── sys._getframe, extract_stack ────────────────────────────────────────────
def where():
    return [sys._getframe(0).f_code.co_name, sys._getframe(1).f_code.co_name, sys._getframe().f_back.f_code.co_name]
def calls_where():
    return where()
check("sys._getframe", calls_where(), ["where", "calls_where", "calls_where"])
def frame_line():
    return src(sys._getframe(1).f_code.co_filename, sys._getframe(1).f_lineno)
fl = frame_line()
check("f_lineno", fl, "fl = frame_line()")
try:
    sys._getframe(100000)
except ValueError as e:
    check("too deep", str(e), "call stack is not deep enough")
def stack_names():
    return [fs.name for fs in traceback.extract_stack()]
def outer_stack():
    return stack_names()
check("extract_stack", outer_stack()[-3:], ["<module>", "outer_stack", "stack_names"])
def stack_lines():
    return [fs.name for fs in traceback.extract_stack(limit=2)]
def call_sl():
    return stack_lines()
check("extract_stack limit", call_sl(), ["call_sl", "stack_lines"])
def fmt_stack():
    return traceback.format_stack()[-1]
check("format_stack", fmt_stack().endswith("    return traceback.format_stack()[-1]\n"), True)
check("walk_stack", [f.f_code.co_name for f, n in traceback.walk_stack(sys._getframe())][:1], ["<module>"])

# ── traceback formatting ────────────────────────────────────────────────────
F = tb_saved.__traceback__.tb_frame.f_code.co_filename
def norm(text):
    out = text.replace(F, "F")
    lines = []
    for ln in out.split("\n"):
        if ln.startswith('  File "F", line '):
            rest = ln[len('  File "F", line '):]
            ln = '  File "F", line N' + rest[rest.index(","):]
        lines.append(ln)
    return "\n".join(lines)

try:
    tb_outer()
except ValueError as e:
    deep_err = e
check("format_exception", norm("".join(traceback.format_exception(deep_err))),
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    tb_outer()\n'
      '  File "F", line N, in tb_outer\n    tb_middle()\n  File "F", line N, in tb_middle\n    tb_inner()\n'
      '  File "F", line N, in tb_inner\n    raise ValueError("deep")\nValueError: deep\n')
check("format_exception old signature", traceback.format_exception(type(deep_err), deep_err, deep_err.__traceback__),
      traceback.format_exception(deep_err))
check("format_exception limit", norm("".join(traceback.format_exception(deep_err, limit=1))),
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    tb_outer()\nValueError: deep\n')
check("format_exception negative limit", norm("".join(traceback.format_exception(deep_err, limit=-1))),
      'Traceback (most recent call last):\n  File "F", line N, in tb_inner\n    raise ValueError("deep")\nValueError: deep\n')
check("format_tb", [norm(x) for x in traceback.format_tb(deep_err.__traceback__)][1:],
      ['  File "F", line N, in tb_outer\n    tb_middle()\n', '  File "F", line N, in tb_middle\n    tb_inner()\n',
       '  File "F", line N, in tb_inner\n    raise ValueError("deep")\n'])
check("chained: context", norm("".join(traceback.format_exception(ctx_err))),
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    raise TypeError("first")\nTypeError: first\n'
      '\nDuring handling of the above exception, another exception occurred:\n\n'
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    raise ValueError("second")\nValueError: second\n')
check("chained: cause", norm("".join(traceback.format_exception(cause_err))),
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    raise TypeError("first")\nTypeError: first\n'
      '\nThe above exception was the direct cause of the following exception:\n\n'
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    raise ValueError("second") from t\nValueError: second\n')
check("chain=False", norm("".join(traceback.format_exception(ctx_err, chain=False))),
      'Traceback (most recent call last):\n  File "F", line N, in <module>\n    raise ValueError("second")\nValueError: second\n')
check("format_exception_only", [traceback.format_exception_only(ValueError("x")), traceback.format_exception_only(ValueError()),
                                traceback.format_exception_only(ValueError, ValueError("y"))],
      [["ValueError: x\n"], ["ValueError\n"], ["ValueError: y\n"]])
class CustomErr(Exception):
    pass
check("a user exception", traceback.format_exception_only(CustomErr("c")), ["CustomErr: c\n"])
noted = ValueError("n")
noted.add_note("note one")
noted.add_note("two\nlines")
check("notes", traceback.format_exception_only(noted), ["ValueError: n\n", "note one\n", "two\n", "lines\n"])
check("no exception", traceback.format_exception(None, None, None), ["NoneType: None\n"])
check("format_exc outside", traceback.format_exc(), "NoneType: None\n")
try:
    tb_inner()
except ValueError:
    fe = traceback.format_exc()
check("format_exc", norm(fe), 'Traceback (most recent call last):\n  File "F", line N, in <module>\n    tb_inner()\n'
                              '  File "F", line N, in tb_inner\n    raise ValueError("deep")\nValueError: deep\n')
buf = io.StringIO()
try:
    tb_inner()
except ValueError:
    traceback.print_exc(file=buf)
check("print_exc", norm(buf.getvalue()) == norm(fe), True)
buf = io.StringIO()
traceback.print_exception(deep_err, file=buf)
check("print_exception", buf.getvalue(), "".join(traceback.format_exception(deep_err)))
buf = io.StringIO()
traceback.print_tb(deep_err.__traceback__, limit=1, file=buf)
check("print_tb", norm(buf.getvalue()), '  File "F", line N, in <module>\n    tb_outer()\n')
try:
    traceback.format_exception(deep_err, deep_err)
except ValueError as e:
    check("value without tb", str(e), "Both or neither of value and tb must be given")
try:
    traceback.format_exception(5)
except TypeError as e:
    check("not an exception", str(e), "Exception expected for value, int found")

# ── StackSummary, FrameSummary, TracebackException ──────────────────────────
fs = traceback.FrameSummary("f.py", 3, "fn", line="x = 1")
check("FrameSummary", [fs.filename, fs.lineno, fs.name, fs.line, fs == ("f.py", 3, "fn", "x = 1"), list(fs), fs[2], len(fs), repr(fs)],
      ["f.py", 3, "fn", "x = 1", True, ["f.py", 3, "fn", "x = 1"], "fn", 4, "<FrameSummary file f.py, line 3 in fn>"])
check("FrameSummary equality", [fs == traceback.FrameSummary("f.py", 3, "fn", line="other"), fs == traceback.FrameSummary("f.py", 4, "fn")],
      [True, False])
check("FrameSummary with no file", traceback.FrameSummary("nofile.py", 3, "fn").line, "")
ss = traceback.StackSummary.from_list([("a.py", 1, "f", "pass"), ("b.py", 2, "g", "return 1")])
check("StackSummary.format", ss.format(), ['  File "a.py", line 1, in f\n    pass\n', '  File "b.py", line 2, in g\n    return 1\n'])
check("format_list", traceback.format_list([("a.py", 1, "f", "pass")]), ['  File "a.py", line 1, in f\n    pass\n'])
check("recursion is folded", traceback.StackSummary.from_list([("a.py", 5, "rec", "rec()")] * 6).format(),
      ['  File "a.py", line 5, in rec\n    rec()\n'] * 3 + ["  [Previous line repeated 3 more times]\n"])
check("one more time", traceback.StackSummary.from_list([("a.py", 5, "rec", "rec()")] * 4).format()[-1],
      "  [Previous line repeated 1 more time]\n")
st = traceback.extract_tb(deep_err.__traceback__)
check("extract_tb", [len(st), st[-1].name, st[-1].line, st[0].line, os.path.basename(st[0].filename)],
      [4, "tb_inner", 'raise ValueError("deep")', "tb_outer()", THIS])
check("extract_tb limit", [x.name for x in traceback.extract_tb(deep_err.__traceback__, limit=2)], ["<module>", "tb_outer"])
check("walk_tb", [f.f_code.co_name for f, n in traceback.walk_tb(deep_err.__traceback__)], ["<module>", "tb_outer", "tb_middle", "tb_inner"])
te = traceback.TracebackException.from_exception(deep_err)
check("TracebackException", [te.exc_type is ValueError, str(te), len(te.stack), te.stack[-1].name, te.__cause__, te.__context__,
                             te.__suppress_context__, list(te.format_exception_only())],
      [True, "deep", 4, "tb_inner", None, None, False, ["ValueError: deep\n"]])
check("TracebackException.format", "".join(te.format()), "".join(traceback.format_exception(deep_err)))
te2 = traceback.TracebackException(type(cause_err), cause_err, cause_err.__traceback__)
check("TracebackException chain", [type(te2.__cause__).__name__, te2.__cause__.exc_type.__name__, te2.__suppress_context__],
      ["TracebackException", "TypeError", True])
buf = io.StringIO()
te.print(file=buf)
check("TracebackException.print", buf.getvalue(), "".join(te.format()))
check("TracebackException equality", te == traceback.TracebackException.from_exception(deep_err), True)

# ── warnings ────────────────────────────────────────────────────────────────
check("default filters", [(f[0], f[1], f[2].__name__, f[3], f[4]) for f in warnings.filters],
      [("default", None, "DeprecationWarning", "__main__", 0), ("ignore", None, "DeprecationWarning", None, 0),
       ("ignore", None, "PendingDeprecationWarning", None, 0), ("ignore", None, "ImportWarning", None, 0),
       ("ignore", None, "ResourceWarning", None, 0)])
check("categories", [issubclass(DeprecationWarning, Warning), issubclass(Warning, Exception), issubclass(UserWarning, Warning),
                     issubclass(ResourceWarning, Warning), issubclass(FutureWarning, Warning), issubclass(ReferenceError, Exception),
                     [c.__name__ for c in DeprecationWarning.__mro__][:4]],
      [True, True, True, True, True, True, ["DeprecationWarning", "Warning", "Exception", "BaseException"]])

def emit(msg, cat=UserWarning, level=1):
    warnings.warn(msg, cat, stacklevel=level)

with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    emit("one")
    emit("two", level=2)
    emit("three", level=50)
check("warn and its location", [(str(x.message), x.category.__name__, os.path.basename(x.filename), src(x.filename, x.lineno)) for x in w[:2]],
      [("one", "UserWarning", THIS, "warnings.warn(msg, cat, stacklevel=level)"), ("two", "UserWarning", THIS, 'emit("two", level=2)')])
check("beyond the stack", [w[2].filename, w[2].lineno], ["sys", 1])
check("WarningMessage", [isinstance(w[0].message, UserWarning), w[0].file, w[0].line, w[0].source, str(w[0])[:60]],
      [True, None, None, None, "{message : UserWarning('one'), category : 'UserWarning', fil"])

with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("default")
    for i in range(3):
        emit("same")
    emit("other")
    emit("same")
check("default: once per location", [str(x.message) for x in w], ["same", "other"])
def emit_here(msg):
    warnings.warn(msg)
def emit_there(msg):
    warnings.warn(msg)
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("once")
    emit_here("x")
    emit_there("x")
    emit_here("y")
check("once", [str(x.message) for x in w], ["x", "y"])
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("module")
    emit_here("m")
    emit_there("m")
check("module", len(w), 1)
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    emit_here("a")
    emit_here("a")
check("always", len(w), 2)
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("ignore")
    emit("ignored")
check("ignore", w, [])
with warnings.catch_warnings():
    warnings.simplefilter("error")
    try:
        emit("boom")
        check("error", "no raise", "raised")
    except UserWarning as e:
        check("error", [type(e).__name__, str(e)], ["UserWarning", "boom"])
with warnings.catch_warnings(record=True) as w:
    emit("dep", DeprecationWarning)
    emit("pend", PendingDeprecationWarning)
    emit("dep", DeprecationWarning)
check("the default filters at work", [str(x.message) for x in w], ["dep"])
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    warnings.filterwarnings("ignore", message="skip.*")
    emit("skip me")
    emit("SKIP me too")
    emit("keep")
    emit("not skip")
check("filter by message (case-insensitive, at the start)", [str(x.message) for x in w], ["keep", "not skip"])
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    warnings.filterwarnings("error", category=DeprecationWarning)
    emit("u")
    try:
        emit("d", DeprecationWarning)
        raised = False
    except DeprecationWarning:
        raised = True
check("filter by category", [len(w), raised], [1, True])
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    warnings.filterwarnings("ignore", module="__ma")
    emit("by module")
    warnings.resetwarnings()
    warnings.filterwarnings("ignore", module="other")
    warnings.simplefilter("always", append=True)
    emit("shown")
check("filter by module", [str(x.message) for x in w], ["shown"])
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    warnings.filterwarnings("ignore", lineno=1)
    emit("line filter")
check("filter by line", len(w), 1)
with warnings.catch_warnings():
    warnings.resetwarnings()
    check("resetwarnings", warnings.filters, [])
    warnings.simplefilter("ignore")
    warnings.simplefilter("error", append=True)
    warnings.simplefilter("ignore")
    check("filters order, duplicates", [f[0] for f in warnings.filters], ["ignore", "error"])
    warnings.filterwarnings("ignore", message="dup")
    warnings.filterwarnings("ignore", message="dup")
    check("duplicate pattern filters", len(warnings.filters), 3)
check("catch_warnings restores", [(f[0], f[2].__name__) for f in warnings.filters][:2], [("default", "DeprecationWarning"), ("ignore", "DeprecationWarning")])
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("always")
    warnings.warn(RuntimeWarning("inst"))
    warnings.warn("res", ResourceWarning, source=w)
check("a Warning instance", [w[0].category.__name__, type(w[0].message).__name__, str(w[0].message), w[1].source is w], ["RuntimeWarning", "RuntimeWarning", "inst", True])
try:
    warnings.warn("x", int)
except TypeError as e:
    check("not a category", str(e), "category must be a Warning subclass, not 'type'")
check("formatwarning", [warnings.formatwarning("msg", UserWarning, "f.py", 3, "x = 1"), warnings.formatwarning("msg", UserWarning, "nofile.py", 3)],
      ["f.py:3: UserWarning: msg\n  x = 1\n", "nofile.py:3: UserWarning: msg\n"])
check("formatwarning reads the line", warnings.formatwarning("m", UserWarning, __file__, 1).endswith("\n  # vm_audit83.ny - weakref, warnings and traceback (round 77), both engines.\n"), True)
buf = io.StringIO()
warnings.showwarning("m", RuntimeWarning, "f.py", 7, file=buf, line="")
check("showwarning", buf.getvalue(), "f.py:7: RuntimeWarning: m\n")
buf = io.StringIO()
olderr = sys.stderr
sys.stderr = buf
with warnings.catch_warnings():
    warnings.simplefilter("always")
    warnings.warn_explicit("explicit", UserWarning, "g.py", 12, module="g", registry={})
sys.stderr = olderr
check("to sys.stderr", buf.getvalue(), "g.py:12: UserWarning: explicit\n")
seen = []
def my_show(message, category, filename, lineno, file=None, line=None):
    seen.append((str(message), category.__name__))
old_show = warnings.showwarning
warnings.showwarning = my_show
with warnings.catch_warnings():
    warnings.simplefilter("always")
    emit("custom")
warnings.showwarning = old_show
check("showwarning replaced", seen, [("custom", "UserWarning")])
reg = {}
with warnings.catch_warnings(record=True) as w:
    warnings.simplefilter("default")
    warnings.warn_explicit("e1", UserWarning, "h.py", 5, registry=reg)
    warnings.warn_explicit("e1", UserWarning, "h.py", 5, registry=reg)
    warnings.warn_explicit("e1", UserWarning, "h.py", 6, registry=reg)
check("warn_explicit registry", [len(w), reg.get(("e1", UserWarning, 5))], [2, True])
with warnings.catch_warnings(record=True) as w:
    warnings.resetwarnings()
    warnings._setoption("error::RuntimeWarning")
    check("_setoption", warnings.filters[0], ("error", None, RuntimeWarning, None, 0))
try:
    warnings._setoption("bogus")
except warnings._OptionError as e:
    check("bad option", str(e), "invalid action: 'bogus'")
buf = io.StringIO()
sys.stderr = buf
warnings._processoptions(["badaction", "ignore::NoSuchWarning", "error:::x:-1"])
sys.stderr = olderr
check("_processoptions", buf.getvalue(), "Invalid -W option ignored: invalid action: 'badaction'\n"
      "Invalid -W option ignored: unknown warning category: 'NoSuchWarning'\nInvalid -W option ignored: invalid lineno -1\n")
cw = warnings.catch_warnings()
cw.__enter__()
try:
    cw.__enter__()
except RuntimeError as e:
    check("catch_warnings entered twice", str(e), "Cannot enter catch_warnings() twice")
cw.__exit__(None, None, None)
check("catch_warnings repr", [repr(warnings.catch_warnings()), repr(warnings.catch_warnings(record=True))],
      ["catch_warnings()", "catch_warnings(record=True)"])
with warnings.catch_warnings(record=True, action="always") as w:
    emit_here("act")
    emit_here("act")
check("catch_warnings(action=)", len(w), 2)
check("WarningMessage str", str(warnings.WarningMessage("a", UserWarning, "f", 1)),
      "{message : 'a', category : 'UserWarning', filename : 'f', lineno : 1, line : None}")

# ── weakref ─────────────────────────────────────────────────────────────────
class Obj:
    def __init__(self, v):
        self.v = v

o = Obj(1)
r = weakref.ref(o)
check("ref", [r() is o, weakref.ref(o) is r, r.__callback__, type(r) is weakref.ref, weakref.ReferenceType is weakref.ref], [True, True, None, True, True])
calls = []
def cb1(wr):
    calls.append(("cb1", wr is r2, wr() is None))
def cb2(wr):
    calls.append(("cb2", wr is r3))
r2 = weakref.ref(o, cb1)
r3 = weakref.ref(o, cb2)
check("refs with callbacks", [r2 is r, r2() is o, r2.__callback__ is cb1, weakref.getweakrefcount(o), len(weakref.getweakrefs(o))],
      [False, True, True, 3, 3])
check("equal while alive", [r == r2, r != r2, hash(r) == hash(o)], [True, False, True])
h = hash(r)
del o
check("the referent died", [r(), r2(), calls, r2.__callback__], [None, None, [("cb2", True), ("cb1", True, True)], None])
check("dead refs", [r == r2, r == r, hash(r) == h], [False, True, True])
check("repr", [repr(r).startswith("<weakref at 0x"), repr(r).endswith("; dead>")], [True, True])
o = Obj(2)
check("repr alive", ("; to 'Obj' at 0x" in repr(weakref.ref(o))), True)
try:
    weakref.ref(5)
except TypeError as e:
    check("not referenceable", str(e), "cannot create weak reference to 'int' object")
dead = weakref.ref(Obj(3))
check("a temporary dies at once", dead(), None)
try:
    hash(weakref.ref(Obj(4)))
except TypeError as e:
    check("never hashed", str(e), "weak object has gone away")

a = Obj("a")
b = Obj("b")
a.other = b
b.other = a
ra = weakref.ref(a)
cyc = []
rb = weakref.ref(b, lambda w: cyc.append("b gone"))
del a
del b
collect()
check("a cycle is collected", [ra(), rb(), cyc], [None, None, ["b gone"]])

from weakref import ref as WRef
class KR(WRef):
    def __new__(cls, ob, callback=None, tag="t"):
        inst = super().__new__(cls, ob, callback)
        inst.tag = tag
        return inst
    def __init__(self, ob, callback=None, tag="t"):
        super().__init__(ob, callback)
o = Obj(5)
kr = KR(o, None, "mine")
check("a subclass of ref", [kr() is o, kr.tag, kr is not weakref.ref(o), isinstance(kr, weakref.ref)], [True, "mine", True, True])
keyed = weakref.KeyedRef(o, None, "k")
check("KeyedRef", [keyed.key, keyed() is o], ["k", True])

class M:
    def meth(self):
        return 42
m = M()
wm = weakref.WeakMethod(m.meth)
check("WeakMethod", [wm()(), wm() == m.meth], [42, True])
try:
    weakref.WeakMethod(len)
except TypeError as e:
    check("WeakMethod of a function", str(e).startswith("argument should be a bound method"), True)
del m
check("WeakMethod dies with its object", wm(), None)

# proxies
o = Obj(7)
p = weakref.proxy(o)
check("proxy", [p.v, type(p) is weakref.ProxyType, isinstance(p, weakref.ProxyTypes)], [7, True, True])
p.v = 8
check("proxy setattr", o.v, 8)
class Callme:
    def __call__(self, x):
        return x * 2
    def __len__(self):
        return 3
cc = Callme()
cp = weakref.proxy(cc)
check("callable proxy", [cp(4), type(cp) is weakref.CallableProxyType, len(cp)], [8, True, 3])
try:
    hash(p)
    check("proxy hash", "hashed", "TypeError")
except TypeError:
    check("proxy hash", "TypeError", "TypeError")
pcalls = []
p2 = weakref.proxy(o, lambda pr: pcalls.append("proxy cb"))
check("getweakrefcount counts proxies", weakref.getweakrefcount(o), 2)
del o
try:
    p.v
except ReferenceError as e:
    check("dead proxy", str(e), "weakly-referenced object no longer exists")
check("proxy callback", pcalls, ["proxy cb"])

# WeakValueDictionary
d = weakref.WeakValueDictionary()
x = Obj(10)
y = Obj(20)
d["x"] = x
d["y"] = y
check("WeakValueDictionary", [len(d), d["x"] is x, sorted(d.keys()), "x" in d, d.get("z", "no")], [2, True, ["x", "y"], True, "no"])
del x
check("a value died", [len(d), "x" in d, d.get("x", "gone"), list(d.keys())], [1, False, "gone", ["y"]])
try:
    d["x"]
except KeyError:
    check("KeyError for a dead value", True, True)
z = Obj(30)
check("setdefault", [d.setdefault("z", z) is z, d.setdefault("z", y) is z], [True, True])
check("pop", [d.pop("z") is z, d.pop("z", "none")], [True, "none"])
d.update({"w": z}, q=y)
check("update", sorted(d.keys()), ["q", "w", "y"])
c2 = d.copy()
check("copy", [type(c2).__name__, sorted(c2.keys())], ["WeakValueDictionary", ["q", "w", "y"]])
check("items and values", [sorted([k for k, v in d.items()]), len(list(d.values())), len(d.valuerefs())], [["q", "w", "y"], 3, 3])
pk, pv = d.popitem()
check("popitem", [pk in ["q", "w", "y"], len(d)], [True, 2])
del z
collect()

# WeakKeyDictionary
k1 = Obj(1)
k2 = Obj(2)
wk = weakref.WeakKeyDictionary()
wk[k1] = "a"
wk[k2] = "b"
check("WeakKeyDictionary", [wk[k1], len(wk), k1 in wk, wk.get(Obj(9), "none"), len(wk.keyrefs())], ["a", 2, True, "none", 2])
del k1
check("a key died", [len(wk), list(wk.values())], [1, ["b"]])
class Key:
    def __init__(self, n):
        self.n = n
    def __eq__(self, other):
        return isinstance(other, Key) and other.n == self.n
    def __hash__(self):
        return hash(self.n)
ka = Key(1)
kb = Key(1)
wk2 = weakref.WeakKeyDictionary()
wk2[ka] = "first"
check("keys compare by ==", [wk2[kb], kb in wk2], ["first", True])
wk2[kb] = "second"
check("an equal key replaces the value", [len(wk2), wk2[ka]], [1, "second"])
check("pop and setdefault", [wk2.pop(ka), len(wk2), wk2.setdefault(kb, "s") , wk2[kb]], ["second", 0, "s", "s"])
try:
    wk2[5] = 1
except TypeError as e:
    check("an int key", str(e), "cannot create weak reference to 'int' object")

# WeakSet
s = weakref.WeakSet()
m1 = Obj(1)
m2 = Obj(2)
s.add(m1)
s.add(m2)
s.add(m1)
check("WeakSet", [len(s), m1 in s, Obj(3) in s], [2, True, False])
del m1
check("a member died", len(s), 1)
s2 = weakref.WeakSet([m2])
m3 = Obj(3)
s3 = weakref.WeakSet([m2, m3])
check("WeakSet comparisons", [s == s2, s <= s3, s < s3, s3 > s, s3 >= s3, s.isdisjoint(weakref.WeakSet([m3]))], [True, True, True, True, True, True])
check("WeakSet operators", [len(s | s3), len(s3 - s), len(s & s3), len(s ^ s3), len(s3.difference([m3]))], [2, 1, 1, 1, 1])
s3.discard(m3)
s3.remove(m2)
check("discard and remove", len(s3), 0)
try:
    s3.remove(m2)
except KeyError:
    check("remove a missing member", True, True)

# finalize
log = []
def fin(tag):
    log.append(tag)
    return "done " + tag
o = Obj(3)
f = weakref.finalize(o, fin, "o")
check("finalize", [f.alive, f.atexit, f.peek()[0] is o, f.peek()[1] is fin, f.peek()[2], f.peek()[3]], [True, True, True, True, ("o",), {}])
del o
check("finalize runs when the object dies", [log, f.alive, f(), f.peek()], [["o"], False, None, None])
o2 = Obj(4)
f2 = weakref.finalize(o2, fin, "o2")
check("calling a finalizer", [f2(), f2(), log[-1], f2.alive], ["done o2", None, "o2", False])
del o2
check("only once", log, ["o", "o2"])
o3 = Obj(5)
f3 = weakref.finalize(o3, fin, "o3")
det = f3.detach()
check("detach", [det[0] is o3, det[1] is fin, det[2], det[3], f3.alive, f3.detach()], [True, True, ("o3",), {}, False, None])
del o3
del det
check("detached never runs", log, ["o", "o2"])
o4 = Obj(6)
f4 = weakref.finalize(o4, fin, "o4")
f4.atexit = False
check("atexit flag", [f4.atexit, ("for 'Obj' at" in repr(f4))], [False, True])
del o4

# at exit: atexit handlers newest first, then the finalizers still alive
code = ("import atexit\nimport weakref\nclass O:\n    pass\no = O()\nweakref.finalize(o, print, 'fin')\n"
        "atexit.register(print, 'first')\natexit.register(print, 'second')\n"
        "def bad():\n    raise ValueError('in handler')\natexit.register(bad)\nprint('main')\n")
pr = subprocess.run([sys.executable] + engine_args() + ["-c", code], capture_output=True, text=True)
check("atexit and finalize at exit", [pr.stdout, pr.returncode, "Exception ignored in atexit callback" in pr.stderr, "ValueError: in handler" in pr.stderr],
      ["main\nsecond\nfirst\nfin\n", 0, True, True])
code = "import atexit\natexit.register(print, 'still runs')\ndef f():\n    raise ValueError('boom')\nf()\n"
pr = subprocess.run([sys.executable] + engine_args() + ["-c", code], capture_output=True, text=True)
check("an uncaught exception's traceback", [pr.stderr.splitlines()[:3], pr.stdout, pr.returncode],
      [["Traceback (most recent call last):", '  File "<string>", line 5, in <module>', '  File "<string>", line 4, in f'], "still runs\n", 1])

# ── Nython only ─────────────────────────────────────────────────────────────
if nython:
    @warnings.deprecated("use g")
    def old_f(x):
        return x + 1
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        v = old_f(1)
    check("deprecated (PEP 702)", [v, len(w), w[0].category.__name__, str(w[0].message), src(w[0].filename, w[0].lineno), old_f.__deprecated__],
          [2, 1, "DeprecationWarning", "use g", "v = old_f(1)", "use g"])
    @warnings.deprecated("old class")
    class OldC:
        def __init__(self, a):
            self.a = a
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        oc = OldC(5)
    check("deprecated class", [oc.a, len(w), str(w[0].message)], [5, 1, "old class"])
    # the engines' builtin: callbacks, at the next statement
    eng = []
    t = Obj(1)
    raw = weakref._wr(t, lambda w: eng.append(w() is None))
    del t
    check("the engines' weakref callback", eng, [True])
    import atexit
    check("atexit API", [atexit.register(fin, "x") is fin, atexit._ncallbacks() >= 1], [True, True])
    atexit.unregister(fin)
    check("frames: f_locals is empty, f_globals has the module", [sys._getframe().f_locals, sys._getframe().f_globals["__name__"]], [{}, "__main__"])

for res in results:
    if res[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + res[0] + ": got " + repr(res[2]) + " want " + repr(res[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT83 PASSED ===")
