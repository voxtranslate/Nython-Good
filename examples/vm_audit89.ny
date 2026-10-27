# vm_audit89.ny - frames, weak references, coroutine objects, both engines
# (round 78).
#
# Frames: sys._getframe(), inspect.currentframe() / stack() / trace() /
# getframeinfo() / getouterframes() / getinnerframes() / getargvalues(),
# traceback.extract_stack() / walk_stack() / print_stack() and the frames of
# tracebacks are the engines' frame objects - f_code, f_lineno, f_locals
# (the frame's locals as locals() gives them, while it runs and after),
# f_globals, f_builtins, f_back, clear() - made only when asked for; a
# generator's gi_frame is its real frame. logging's caller information
# (%(funcName)s, %(lineno)d, stack_info, exception()) comes from them.
# Weak references reach functions, classes, sets, frozensets, bound methods
# and instances of builtin subclasses. Calling an async def gives a real
# coroutine object (send / throw / close by hand, cr_* attributes, the
# never-awaited warning); async generators give async_generator objects
# whose asend / athrow / aclose are awaitables.
#
# Every check runs under python3 too (`python3 examples/vm_audit89.ny`),
# with CPython's values; a few Nython-only ones (3.12 inspect functions)
# are marked.
#
#     ./build/nython-cli examples/vm_audit89.ny
#     ./build/nython-cli --vm examples/vm_audit89.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

try:
    gc_collect
except NameError:
    import gc
    gc_collect = gc.collect

import sys
import types
import inspect
import traceback
import io
import warnings
import weakref
import asyncio
import logging

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

# The line a marker comment ends ("# @name"), from this file's source.
_src_lines = open(sys._getframe().f_code.co_filename).read().split("\n")
def line_of(tag):
    for i in range(len(_src_lines)):
        if _src_lines[i].rstrip().endswith("# " + "@" + tag):
            return i + 1
    return -1
def src_line(tag):
    return _src_lines[line_of(tag) - 1].strip()

# ── 1. frame objects ────────────────────────────────────────────────────────
def frame_basics(a, b=2):   # @fb_def
    x = a + b
    fr = sys._getframe()
    loc = locals()
    return fr, loc, sys._getframe(0) is fr, sys._getframe(1).f_code.co_name   # @fb_ret

fr, loc, same, caller = frame_basics(1)
check("f_code of a function's frame",
      [fr.f_code.co_name, fr.f_code.co_filename.endswith("vm_audit89.ny"), fr.f_code.co_firstlineno == line_of("fb_def"),
       fr.f_code.co_argcount, fr.f_code.co_varnames[:2], fr.f_code.co_qualname],
      ["frame_basics", True, True, 2, ("a", "b"), "frame_basics"])
check("the same frame object each time, the caller's frame",
      [same, caller, sorted(loc)], [True, "<module>", ["a", "b", "fr", "x"]])
check("a frame that outlived its call keeps its last locals and line",
      [sorted(fr.f_locals), fr.f_locals["x"], fr.f_lineno == line_of("fb_ret"), fr.f_back.f_code.co_name],
      [["a", "b", "fr", "loc", "x"], 3, True, "<module>"])

def live():
    v = 1
    f = sys._getframe()
    n1 = f.f_lineno   # @live1
    v = 2
    seen = f.f_locals["v"]
    n2 = f.f_lineno   # @live2
    return [n1 == line_of("live1"), n2 == line_of("live2"), seen, sorted(f.f_locals) == sorted(locals()), f.f_locals["n1"] == n1]
check("f_lineno and f_locals are read live; locals() agrees", live(), [True, True, 2, True, True])

def chain_c():
    return sys._getframe()
def chain_b():
    return chain_c()
def chain_a():
    return chain_b()
cf = chain_a()
names = []
while cf is not None:
    names.append(cf.f_code.co_name)
    cf = cf.f_back
check("f_back links the callers (kept after they return)", names, ["chain_c", "chain_b", "chain_a", "<module>"])

mf = sys._getframe()
check("the module's frame",
      [mf.f_code.co_name, mf.f_back is None, "pass_n" in mf.f_locals, mf.f_globals["__name__"], mf.f_locals["line_of"] is line_of],
      ["<module>", True, True, "__main__", True])

def too_deep():
    try:
        sys._getframe(100000)
    except ValueError as e:
        return str(e)
check("sys._getframe past the bottom", too_deep(), "call stack is not deep enough")

class Box:
    def __init__(self, v):
        self.v = v
    def where(self):
        f = sys._getframe()
        return [f.f_code.co_name, f.f_code.co_qualname, sorted(f.f_locals), f.f_locals["self"] is self]
check("a method's frame has self", Box(3).where(), ["where", "Box.where", ["f", "self"], True])
check("a lambda's frame", (lambda q: [sys._getframe().f_code.co_name, sys._getframe().f_locals])(4), ["<lambda>", {"q": 4}])
check("f_globals, f_builtins",
      [fr.f_globals["__name__"], "frame_basics" in fr.f_globals, fr.f_builtins["len"] is len, "len" in fr.f_builtins],
      ["__main__", True, True, True])
check("type and repr of a frame",
      [type(fr).__name__, isinstance(fr, types.FrameType), inspect.isframe(fr), repr(fr).startswith("<frame at 0x"),
       repr(fr).endswith(", line " + str(line_of("fb_ret")) + ", code frame_basics>"), fr.f_trace,
       isinstance(fr.f_lasti, int) and fr.f_lasti >= 0],
      ["frame", True, True, True, True, None, True])

def clear_live():
    try:
        sys._getframe().clear()
    except RuntimeError as e:
        return str(e)
fr.clear()
check("clear(): a running frame refuses, a finished one lets go", [clear_live(), fr.f_locals], ["cannot clear an executing frame", {}])

def gen_code_frame():
    yield sys._getframe()
gcf = next(gen_code_frame())
check("code flags and source of a frame",
      [bool(gcf.f_code.co_flags & inspect.CO_GENERATOR), bool(fr.f_code.co_flags & inspect.CO_GENERATOR),
       inspect.getsource(fr).split("\n")[0].startswith("def frame_basics(a, b=2):"),
       inspect.getlineno(fr) == fr.f_lineno, inspect.getsourcefile(fr).endswith("vm_audit89.ny")],
      [True, False, True, True, True])

def nested_outer():
    def nested_inner():
        return sys._getframe().f_code.co_qualname
    return nested_inner()
check("co_qualname of a nested function", nested_outer(), "nested_outer.<locals>.nested_inner")

# ── 2. the frames of a traceback ────────────────────────────────────────────
def tb_inner(n):
    secret = n * 10
    raise ValueError("boom " + str(n))   # @tb_raise
def tb_outer():
    marker = "outer"
    return tb_inner(4)
def tb_catch():
    here = sys._getframe()
    try:
        tb_outer()   # @tb_try
    except ValueError as e:
        tb = e.__traceback__
        t2 = tb.tb_next
        t3 = t2.tb_next
        return [tb.tb_frame is here, tb.tb_lineno == line_of("tb_try"), t2.tb_frame.f_code.co_name,
                t2.tb_frame.f_locals["marker"], t3.tb_frame.f_locals["secret"], t3.tb_lineno == line_of("tb_raise"),
                t2.tb_frame.f_back is here, t3.tb_frame.f_back.f_code.co_name, t3.tb_frame.f_lineno == line_of("tb_raise")]
check("tb_frame is the frame itself, with its locals", tb_catch(), [True, True, "tb_outer", "outer", 40, True, True, "tb_outer", True])

def tb_texts():
    try:
        tb_outer()
    except ValueError as e:
        ex = traceback.extract_tb(e.__traceback__)
        return [[f.name for f in ex], ex[-1].line == src_line("tb_raise"), ex[-1].lineno == line_of("tb_raise"),
                inspect.istraceback(e.__traceback__), type(e.__traceback__).__name__,
                isinstance(e.__traceback__, types.TracebackType)]
check("extract_tb", tb_texts(), [["tb_texts", "tb_outer", "tb_inner"], True, True, True, "traceback", True])

# ── 3. inspect over frames ──────────────────────────────────────────────────
def insp():
    cf = inspect.currentframe()
    st = inspect.stack()   # @insp_stack
    info = inspect.getframeinfo(cf)
    outer = inspect.getouterframes(cf)
    return [cf is sys._getframe(), st[0].function, st[1].function, st[0].lineno == line_of("insp_stack"),
            st[0].code_context[0].strip() == src_line("insp_stack"), st[0].index, st[0].frame is cf,
            info.function, info.filename.endswith("vm_audit89.ny"), type(st[0]).__name__, len(st[0]),
            st[0][3], [o.function for o in outer][:2], type(info).__name__, info[2]]
check("currentframe, stack, getframeinfo, getouterframes", insp(),
      [True, "insp", "<module>", True, True, 0, True, "insp", True, "FrameInfo", 6, "insp", ["insp", "<module>"],
       "Traceback", "insp"])

def argv_fn(a, b, *rest, **kw):
    return inspect.getargvalues(sys._getframe())
av = argv_fn(1, 2, 3, k=4)
check("getargvalues, formatargvalues",
      [av.args, av.varargs, av.keywords, av.locals["rest"], inspect.formatargvalues(*av)],
      [["a", "b"], "rest", "kw", (3,), "(a=1, b=2, *rest=(3,), **kw={'k': 4})"])
try:
    tb_outer()
except ValueError as e:
    tr = inspect.trace()
    inner = inspect.getinnerframes(e.__traceback__)
check("trace, getinnerframes", [[f.function for f in tr], [f.function for f in inner], inner[-1].lineno == line_of("tb_raise")],
      [["<module>", "tb_outer", "tb_inner"], ["<module>", "tb_outer", "tb_inner"], True])

def gen_fn(a):   # @gen_def
    b = a + 1
    yield b   # @gen_y1
    c = b * 2
    yield c   # @gen_y2
g = gen_fn(5)
s0 = [inspect.getgeneratorstate(g), g.gi_frame.f_lineno == line_of("gen_def"), sorted(inspect.getgeneratorlocals(g).items())]
next(g)
s1 = [inspect.getgeneratorstate(g), g.gi_frame.f_lineno == line_of("gen_y1"), sorted(inspect.getgeneratorlocals(g).items())]
gfr = g.gi_frame
next(g)
s2 = [gfr.f_lineno == line_of("gen_y2"), sorted(gfr.f_locals.items()), gfr.f_code.co_name]
list(g)
s3 = [inspect.getgeneratorstate(g), g.gi_frame]
check("a generator's frame", [s0, s1, s2, s3],
      [["GEN_CREATED", True, [("a", 5)]], ["GEN_SUSPENDED", True, [("a", 5), ("b", 6)]],
       [True, [("a", 5), ("b", 6), ("c", 12)], "gen_fn"], ["GEN_CLOSED", None]])

def gen_self():
    yield sys._getframe().f_code.co_name
    yield inspect.getgeneratorstate(gs)
gs = gen_self()
check("a running generator's frame", list(gs), ["gen_self", "GEN_RUNNING"])

# ── 4. traceback over frames ────────────────────────────────────────────────
def tbm():
    st = traceback.extract_stack()   # @tbm_line
    return [st[-1].name, st[-1].lineno == line_of("tbm_line"), st[-1].line == src_line("tbm_line"), st[-2].name]
check("extract_stack", tbm(), ["tbm", True, True, "<module>"])

def tbl(q):
    w = q * 2
    ss = traceback.StackSummary.extract(traceback.walk_stack(sys._getframe()), capture_locals=True)
    return [ss[0].name, ss[0].locals, ss[1].name]
check("walk_stack, StackSummary.extract(capture_locals=True)", tbl(3), ["tbl", {"q": "3", "w": "6"}, "<module>"])

def pst():
    buf = io.StringIO()
    traceback.print_stack(sys._getframe(), file=buf)   # @pst_line
    return buf.getvalue().rstrip("\n").split("\n")
pl = pst()
check("print_stack", [pl[-2].endswith(", line " + str(line_of("pst_line")) + ", in pst"), pl[-1].strip() == src_line("pst_line")],
      [True, True])

def caught_locals():
    try:
        tb_outer()
    except ValueError as e:
        te = traceback.TracebackException.from_exception(e, capture_locals=True)
        return [te.stack[-1].name, te.stack[-1].locals, te.stack[-2].locals]
check("TracebackException(capture_locals=True)", caught_locals(), ["tb_inner", {"n": "4", "secret": "40"}, {"marker": "'outer'"}])

# ── 5. logging's caller information ─────────────────────────────────────────
class ListHandler(logging.Handler):
    def __init__(self):
        logging.Handler.__init__(self)
        self.records = []
    def emit(self, record):
        self.records.append(self.format(record))

lg = logging.getLogger("vm89")
lg.propagate = False
lh = ListHandler()
lh.setFormatter(logging.Formatter("%(funcName)s:%(lineno)d:%(module)s:%(filename)s:%(message)s"))
lg.addHandler(lh)
def log_here():
    lg.warning("hi")   # @log_line
log_here()
def log_stack():
    lg.warning("st", stack_info=True)
log_stack()
def log_exc():
    try:
        tb_outer()
    except ValueError:
        lg.exception("bad")
log_exc()
def log_level2():
    helper_log("two")
def helper_log(m):
    lg.warning(m, stacklevel=2)
log_level2()   # @log_l2
st_lines = lh.records[1].split("\n")
ex_lines = lh.records[2].split("\n")
files = [l for l in ex_lines if l.startswith("  File ")]
check("funcName / lineno / module / filename", lh.records[0], "log_here:" + str(line_of("log_line")) + ":vm_audit89:vm_audit89.ny:hi")
check("stack_info", [st_lines[0].startswith("log_stack:"), st_lines[1], st_lines[-2].endswith(", in log_stack")],
      [True, "Stack (most recent call last):", True])
check("exception() with the frames", [ex_lines[1], len(files), files[-1].endswith(", in tb_inner"), ex_lines[-1]],
      ["Traceback (most recent call last):", 3, True, "ValueError: boom 4"])
check("stacklevel", lh.records[3].split(":")[0:2], ["log_level2", str(line_of("log_l2") - 3)])

logging.captureWarnings(True)
pw = logging.getLogger("py.warnings")
pwh = ListHandler()
pwh.setFormatter(logging.Formatter("%(name)s|%(message)s"))
pw.addHandler(pwh)
pw.propagate = False
with warnings.catch_warnings():
    warnings.simplefilter("always")
    warnings.warn("careful", UserWarning)   # @warn_line
logging.captureWarnings(False)
check("captureWarnings", pwh.records[0].split("\n")[0],
      "py.warnings|" + mf.f_code.co_filename + ":" + str(line_of("warn_line")) + ": UserWarning: careful")

# ── 6. weak references ──────────────────────────────────────────────────────
wlog = []
def wf():
    return 7
r = weakref.ref(wf)
r2 = weakref.ref(wf, lambda ref: wlog.append("function gone"))
w_alive = [r() is wf, r()(), hash(r) == hash(wf), weakref.getweakrefcount(wf) >= 1, type(r) is weakref.ref]
del wf
gc_collect()
check("a weak reference to a function", [w_alive, r() is None, wlog], [[True, 7, True, True, True], True, ["function gone"]])

def make_adder(n):
    def add(x):
        return x + n
    return add
ad = make_adder(2)
ra = weakref.ref(ad)
ra_alive = ra()(3)
lam = lambda: 1
rl = weakref.ref(lam)
del ad, lam
gc_collect()
check("closures and lambdas", [ra_alive, ra() is None, rl() is None], [5, True, True])

class WK:
    pass
rc = weakref.ref(WK)
wvd = weakref.WeakValueDictionary()
wvd["k"] = WK
wvd["b"] = Box
ws = weakref.WeakSet()
ws.add(WK)
ws.add(Box)
ws.add(WK)
check("classes: ref, WeakValueDictionary, WeakSet",
      [rc() is WK, wvd["k"] is WK, sorted(wvd.keys()), WK in ws, Box in ws, len(ws), Box.__name__ in [c.__name__ for c in ws]],
      [True, True, ["b", "k"], True, True, 2, True])

def k1():
    pass
def k2():
    pass
wkd = weakref.WeakKeyDictionary()
wkd[k1] = "one"
wkd[k2] = "two"
wk_before = [wkd[k1], len(wkd), k2 in wkd]
del k1
gc_collect()
check("WeakKeyDictionary keyed by functions", [wk_before, len(wkd), list(wkd.values())], [["one", 2, True], 1, ["two"]])

fin_log = []
def victim():
    pass
fz = weakref.finalize(victim, fin_log.append, "finalized")
fz_alive = fz.alive
del victim
gc_collect()
check("finalize on a function", [fz_alive, fz.alive, fin_log], [True, False, ["finalized"]])

sset = {1, 2}
set_log = []
rs = weakref.ref(sset, lambda ref: set_log.append("set gone"))
fs = frozenset([3])
rfs = weakref.ref(fs)
s_alive = [rs() is sset, rs() == {1, 2}, rfs() is fs]
del sset, fs
gc_collect()
check("sets and frozensets", [s_alive, rs() is None, rfs() is None, set_log], [[True, True, True], True, True, ["set gone"]])

class MyList(list):
    pass
class MyDict(dict):
    pass
ml = MyList([1])
md = MyDict(a=1)
rml = weakref.ref(ml)
rmd = weakref.ref(md)
b_alive = [rml() is ml, rmd()["a"], rml()[0]]
del ml, md
gc_collect()
check("instances of builtin subclasses", [b_alive, rml() is None, rmd() is None], [[True, 1, 1], True, True])

bx = Box(1)
rb = weakref.ref(bx.where)
wm = weakref.WeakMethod(bx.where)
bm_alive = [rb() is None, wm()()[0]]
del bx
gc_collect()
check("bound methods: a plain ref dies with the method, WeakMethod with the object", [bm_alive, wm() is None], [[True, "where"], True])

def wr_err(v):
    try:
        weakref.ref(v)
        return "ok"
    except TypeError as e:
        return str(e)
check("what cannot be weakly referenced",
      [wr_err(1), wr_err("s"), wr_err([1]), wr_err((1,)), wr_err({}), wr_err(b"x"), wr_err(None)],
      ["cannot create weak reference to 'int' object", "cannot create weak reference to 'str' object",
       "cannot create weak reference to 'list' object", "cannot create weak reference to 'tuple' object",
       "cannot create weak reference to 'dict' object", "cannot create weak reference to 'bytes' object",
       "cannot create weak reference to 'NoneType' object"])

def wsame():
    pass
wa = weakref.ref(wsame)
wb = weakref.ref(wsame)
check("references to a function compare equal and are counted",
      [wa == wb, wa is wb, weakref.getweakrefcount(wsame), len(weakref.getweakrefs(wsame)), repr(wa).startswith("<weakref at 0x")],
      [True, True, 1, 1, True])

def wpf(x):
    return x * 3
pxy = weakref.proxy(wpf)
check("a proxy to a function", [pxy(4), type(pxy) is weakref.CallableProxyType], [12, True])

# ── 7. coroutine objects ────────────────────────────────────────────────────
async def double(x):   # @double_def
    return x * 2

co = double(21)
co_info = [type(co).__name__, inspect.iscoroutine(co), isinstance(co, types.CoroutineType), co.__name__, co.__qualname__,
           co.cr_code.co_name, co.cr_running, co.cr_await, inspect.getcoroutinestate(co),
           repr(co).startswith("<coroutine object double at 0x"), inspect.isawaitable(co),
           co.cr_frame.f_lineno == line_of("double_def"), co.cr_frame.f_code.co_name]
try:
    co.send(None)
    co_res = "no StopIteration"
except StopIteration as e:
    co_res = e.value
check("a coroutine object", co_info,
      ["coroutine", True, True, "double", "double", "double", False, None, "CORO_CREATED", True, True, True, "double"])
check("send(None) runs it to the end: StopIteration(value)", [co_res, inspect.getcoroutinestate(co), co.cr_frame], [42, "CORO_CLOSED", None])

def reused():
    try:
        co.send(None)
    except RuntimeError as e:
        return str(e)
check("a finished coroutine cannot be resumed", reused(), "cannot reuse already awaited coroutine")

class Ping:
    # an awaitable whose __await__ is a generator: its yields go to the runner
    def __await__(self):
        got = yield "ping"
        return got * 2

async def pinger():   # @pinger_def
    a = await Ping()
    b = await Ping()   # @pinger_b
    return a + b

co = pinger()
r1 = co.send(None)
st1 = [r1, inspect.getcoroutinestate(co), co.cr_suspended, type(co.cr_await).__name__]
r2 = co.send(10)
st2 = [r2, co.cr_frame.f_code.co_name, co.cr_frame.f_locals, co.cr_frame.f_lineno == line_of("pinger_b")]
try:
    co.send(5)
    r3 = "no StopIteration"
except StopIteration as e:
    r3 = e.value
check("driven by hand: send() gives what __await__ yields", [st1, st2, r3, inspect.getcoroutinestate(co)],
      [["ping", "CORO_SUSPENDED", True, "generator"], ["ping", "pinger", {"a": 20}, True], 30, "CORO_CLOSED"])

async def catcher():
    try:
        await Ping()
    except ValueError as e:
        return "caught " + str(e)
co = catcher()
co.send(None)
try:
    co.throw(ValueError("x"))
    thrown = "no StopIteration"
except StopIteration as e:
    thrown = e.value
async def uncaught():
    await Ping()
co = uncaught()
co.send(None)
try:
    co.throw(KeyError("k"))
    thrown2 = "nothing"
except KeyError as e:
    thrown2 = "KeyError " + str(e)
check("throw() at the paused await", [thrown, thrown2, inspect.getcoroutinestate(co)], ["caught x", "KeyError 'k'", "CORO_CLOSED"])

clog = []
async def closer():
    try:
        await Ping()
    finally:
        clog.append("finally")
co = closer()
co.send(None)
co.close()
check("close() runs the finally blocks", [clog, inspect.getcoroutinestate(co)], [["finally"], "CORO_CLOSED"])
co = double(1)
co.close()
check("close() before it starts", inspect.getcoroutinestate(co), "CORO_CLOSED")

async def stubborn():
    try:
        await Ping()
    except GeneratorExit:
        pass
    await Ping()
co = stubborn()
co.send(None)
try:
    co.close()
    ignored = "closed"
except RuntimeError as e:
    ignored = str(e)
check("a coroutine that ignores GeneratorExit", ignored, "coroutine ignored GeneratorExit")
co.close()

sl = asyncio.sleep(0)
check("coroutine functions and their objects",
      [inspect.iscoroutinefunction(double), inspect.iscoroutinefunction(frame_basics),
       bool(pinger.__code__.co_flags & inspect.CO_COROUTINE), asyncio.iscoroutine(sl), type(sl).__name__],
      [True, False, True, True, "coroutine"])
sl.close()

def send_value_first():
    c = double(1)
    try:
        c.send(5)
    except TypeError as e:
        c.close()
        return str(e)
check("a just-started coroutine takes only None", send_value_first(), "can't send non-None value to a just-started coroutine")

async def delegate():
    return await pinger()
co = delegate()
d1 = co.send(None)
d2 = co.send(1)
try:
    co.send(2)
    d3 = "no StopIteration"
except StopIteration as e:
    d3 = e.value
check("an awaited coroutine's yields reach the runner too", [d1, d2, d3], ["ping", "ping", 6])

co = double(4)
it = co.__await__()
try:
    next(it)
    aw_res = "no StopIteration"
except StopIteration as e:
    aw_res = e.value
check("__await__ gives an iterator over it", [type(it).__name__, aw_res], ["coroutine_wrapper", 8])

class Acct:
    def __init__(self, v):
        self.v = v
    async def total(self, extra):
        return self.v + extra
co = Acct(5).total(2)
qn = co.__qualname__
try:
    co.send(None)
except StopIteration as e:
    acct = e.value
check("an async method", [qn, acct], ["Acct.total", 7])

async def twice():
    c = double(2)
    a = await c
    try:
        await c
    except RuntimeError as e:
        return [a, str(e)]
async def gathered():
    d3 = double(3)
    t = asyncio.create_task(d3)
    r = await asyncio.gather(double(1), double(2), t)
    return r + [t.get_coro() is d3]
async def awaits_ping():
    v = await asyncio.sleep(0, "slept")
    return [v, await Ping2()]
class Ping2:
    def __await__(self):
        yield
        return "bare yield"
check("await, asyncio.run, create_task, gather", [asyncio.run(twice()), asyncio.run(gathered()), asyncio.run(awaits_ping())],
      [[4, "cannot reuse already awaited coroutine"], [2, 4, 6, True], ["slept", "bare yield"]])

with warnings.catch_warnings(record=True) as wrec:
    warnings.simplefilter("always")
    lost = double(9)
    del lost
    gc_collect()
check("a coroutine never awaited warns when it goes",
      [[str(w.message) for w in wrec], [w.category.__name__ for w in wrec]],
      [["coroutine 'double' was never awaited"], ["RuntimeWarning"]])

running_state = []
async def self_state():
    running_state.append(inspect.getcoroutinestate(me))
    return 1
me = self_state()
try:
    me.send(None)
except StopIteration:
    pass
check("CORO_RUNNING inside", running_state, ["CORO_RUNNING"])

# ── 8. async generators ─────────────────────────────────────────────────────
async def agen(n):
    for i in range(n):
        yield i * 10

ag = agen(3)
ag_info = [type(ag).__name__, inspect.isasyncgen(ag), isinstance(ag, types.AsyncGeneratorType), ag.__name__, ag.__qualname__,
           ag.ag_running, repr(ag).startswith("<async_generator object agen at 0x")]
step = ag.__anext__()
try:
    step.send(None)
    first = "no StopIteration"
except StopIteration as e:
    first = e.value
check("an async generator object", [ag_info, type(step).__name__, first],
      [["async_generator", True, True, "agen", "agen", False, True], "async_generator_asend", 0])

async def use_agen():
    out = []
    a = agen(4)
    out.append(await a.__anext__())
    out.append(await a.asend(None))
    async for v in a:
        out.append(v)
    try:
        await a.__anext__()
    except StopAsyncIteration:
        out.append("stop")
    b = agen(5)
    out.append(await b.__anext__())
    await b.aclose()
    try:
        await b.__anext__()
    except StopAsyncIteration:
        out.append("closed")
    c = agen(2)
    await c.__anext__()
    try:
        await c.athrow(ValueError("into it"))
    except ValueError as e:
        out.append("thrown: " + str(e))
    return out
check("__anext__ / asend / aclose / athrow are awaitables", asyncio.run(use_agen()),
      [0, 10, 20, 30, "stop", 0, "closed", "thrown: into it"])
ag3 = agen(1)
ag3_before = [ag3.ag_frame is not None, ag3.ag_frame.f_locals]
async def drain():
    return [x async for x in ag3]
check("ag_frame", [ag3_before, asyncio.run(drain()), ag3.ag_frame], [[True, {"n": 1}], [0], None])
athrow_obj = agen(1).athrow(ValueError)
check("athrow's awaitable", type(athrow_obj).__name__, "async_generator_athrow")
athrow_obj.close()

if nython:
    # Nython only: Python 3.12's getasyncgenstate / getasyncgenlocals
    ag2 = agen(2)
    check("getasyncgenstate (3.12)", [inspect.getasyncgenstate(ag2), inspect.getasyncgenlocals(ag2)], ["AGEN_CREATED", {"n": 2}])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT89 PASSED ===")
