# vm_audit91.ny - tracing, debugging and profiling, both engines (round 79).
#
# sys.settrace / sys.setprofile with CPython 3.11's events (call, line,
# return, exception; c_call / c_return / c_exception for the profiler) and
# their order for calls, loops, branches, try / with / finally, exceptions
# passing frames, generators and lambdas; the global trace function's
# result as the frame's f_trace, f_trace set from outside, f_trace_lines;
# a trace function runs untraced, one that raises is unset; gettrace /
# getprofile; threading.settrace; PEP 667's f_locals write-through (frame
# locals changed from a trace function and through a running frame's
# f_locals); and the modules over them: bdb (stepping, breakpoints -
# conditions, ignore counts, temporary ones), pdb (scripted sessions:
# break, continue, next, step, return, until, p, pp, args, retval,
# display, list, where, up / down, aliases, `!` statements, post-mortem),
# cProfile / profile / pstats (call counts, primitive calls, callers,
# sorting, CPython's report layout), timeit, trace (line counts, called
# functions, calling relationships, .cover files), cmd, code / codeop; and
# the data-model leftovers of round 78: a nested class's __qualname__, an
# async staticmethod, inspect.signature of a method whose receiver is
# `this`; breakpoint() and sys.breakpointhook.
#
# Every check runs under python3 too (`python3 examples/vm_audit91.ny`), with
# CPython 3.11's and 3.13's values; where they differ (f_locals write-through,
# pdb's help layout and function breakpoint line, trace's line layout) Nython
# follows 3.13 and the check takes the running python3's. (The pure-Python
# profile module's checks are skipped under python3.12+, whose profile.py
# trips over a stray event once settrace was used in the process.)
#
#     ./build/nython-cli examples/vm_audit91.ny
#     ./build/nython-cli --vm examples/vm_audit91.ny
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

# Nython follows 3.13 where 3.11 and 3.13 differ; python3 takes its own
py313 = nython or sys.version_info >= (3, 13)

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    # the reprs now: a list checked may change afterwards
    results.append([name, repr(got) == repr(want), repr(got), repr(want)])

# The line a marker comment ends ("# @name"), from this file's source.
_src_lines = open(sys._getframe().f_code.co_filename).read().split("\n")
def line_of(tag):
    for i in range(len(_src_lines)):
        if _src_lines[i].rstrip().endswith("# " + "@" + tag):
            return i + 1
    return -1

# ── 1. sys.settrace: the events and their order ─────────────────────────────
# Each traced function's events as (event, function, line relative to its
# def, what the event carries).
_events = []
_base = {}

def _rel(frame):
    return frame.f_lineno - _base.get(frame.f_code.co_name, 0)

def _tracer(frame, event, arg):
    name = frame.f_code.co_name
    if name not in _base:
        return None
    if event == "return":
        _events.append((event, name, _rel(frame), arg))
    elif event == "exception":
        _events.append((event, name, _rel(frame), arg[0].__name__, str(arg[1])))
    else:
        _events.append((event, name, _rel(frame)))
    return _tracer

def traced(fn, *args):
    del _events[:]
    sys.settrace(_tracer)
    try:
        r = fn(*args)
    finally:
        sys.settrace(None)
    return r

def t_for(n):   # @t_for
    s = 0
    for i in range(n):
        s += i
    return s

def t_while(n):   # @t_while
    while n > 0:
        n -= 1
    return n

def t_if(x):   # @t_if
    if x > 1:
        y = 1
    elif x > 0:
        y = 2
    else:
        y = 3
    return y

def t_try():   # @t_try
    try:
        z = 1 // 0
    except ZeroDivisionError:
        z = 5
    return z

def t_inner():   # @t_inner
    raise ValueError("bad")

def t_outer():   # @t_outer
    try:
        t_inner()
    except ValueError as e:
        return str(e)

def t_gen():   # @t_gen
    yield 1
    yield 2

def t_usegen():   # @t_usegen
    t = 0
    for v in t_gen():
        t += v
    return t

def t_fin():   # @t_fin
    try:
        raise KeyError("k")
    finally:
        q = 2

def t_callfin():   # @t_callfin
    try:
        t_fin()
    except KeyError:
        pass
    return 0

class _CM:
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

def t_with():   # @t_with
    with _CM() as c:
        x = 1
    return x

def t_loopret():   # @t_loopret
    for i in range(5):
        if i == 1:
            return i

def t_cont(n):   # @t_cont
    t = 0
    for i in range(n):
        if i == 0:
            continue
        t += i
    return t

def t_lam():   # @t_lam
    f = lambda q: q + 1   # @t_lamdef
    return f(2)

def t_retfin():   # @t_retfin
    try:
        return 1
    finally:
        x = 2

def t_fall(n):   # @t_fall
    for i in range(n):
        pass

def t_brkfin():   # @t_brkfin
    while True:
        try:
            break
        finally:
            y = 1
    z = 2

for _nm in ["t_for", "t_while", "t_if", "t_try", "t_inner", "t_outer", "t_gen", "t_usegen", "t_fin", "t_callfin",
            "t_with", "t_loopret", "t_cont", "t_lam", "t_retfin", "t_fall", "t_brkfin"]:
    _base[_nm] = line_of(_nm)
_base["<lambda>"] = line_of("t_lamdef")

check("for loop: the header's line each time it is reached", [traced(t_for, 2), _events],
      [1, [('call', 't_for', 0), ('line', 't_for', 1), ('line', 't_for', 2), ('line', 't_for', 3), ('line', 't_for', 2),
           ('line', 't_for', 3), ('line', 't_for', 2), ('line', 't_for', 4), ('return', 't_for', 4, 1)]])
check("while loop: the test's line each time", [traced(t_while, 2), _events],
      [0, [('call', 't_while', 0), ('line', 't_while', 1), ('line', 't_while', 2), ('line', 't_while', 1), ('line', 't_while', 2),
           ('line', 't_while', 1), ('line', 't_while', 3), ('return', 't_while', 3, 0)]])
check("if / elif / else: each test reached, no line for else", [traced(t_if, 0), _events],
      [3, [('call', 't_if', 0), ('line', 't_if', 1), ('line', 't_if', 3), ('line', 't_if', 6), ('line', 't_if', 7), ('return', 't_if', 7, 3)]])
check("if / elif taken", [traced(t_if, 1), _events],
      [2, [('call', 't_if', 0), ('line', 't_if', 1), ('line', 't_if', 3), ('line', 't_if', 4), ('line', 't_if', 7), ('return', 't_if', 7, 2)]])
check("try / except: the exception event, then the except clause's line", [traced(t_try), _events],
      [5, [('call', 't_try', 0), ('line', 't_try', 1), ('line', 't_try', 2), ('exception', 't_try', 2, 'ZeroDivisionError', 'integer division or modulo by zero'),
           ('line', 't_try', 3), ('line', 't_try', 4), ('line', 't_try', 5), ('return', 't_try', 5, 5)]])
check("an exception leaving a frame: exception and return(None) there, exception in the caller",
      [traced(t_outer), _events],
      ['bad', [('call', 't_outer', 0), ('line', 't_outer', 1), ('line', 't_outer', 2), ('call', 't_inner', 0), ('line', 't_inner', 1),
               ('exception', 't_inner', 1, 'ValueError', 'bad'), ('return', 't_inner', 1, None),
               ('exception', 't_outer', 2, 'ValueError', 'bad'), ('line', 't_outer', 3), ('line', 't_outer', 4), ('return', 't_outer', 4, 'bad')]])
check("a generator: call when resumed, return when it yields", [traced(t_usegen), _events],
      [3, [('call', 't_usegen', 0), ('line', 't_usegen', 1), ('line', 't_usegen', 2), ('call', 't_gen', 0), ('line', 't_gen', 1),
           ('return', 't_gen', 1, 1), ('line', 't_usegen', 3), ('line', 't_usegen', 2), ('call', 't_gen', 1), ('line', 't_gen', 2),
           ('return', 't_gen', 2, 2), ('line', 't_usegen', 3), ('line', 't_usegen', 2), ('call', 't_gen', 2), ('return', 't_gen', 2, None),
           ('line', 't_usegen', 4), ('return', 't_usegen', 4, 3)]])
check("finally runs on the way out; the caller's except", [traced(t_callfin), _events],
      [0, [('call', 't_callfin', 0), ('line', 't_callfin', 1), ('line', 't_callfin', 2), ('call', 't_fin', 0), ('line', 't_fin', 1),
           ('line', 't_fin', 2), ('exception', 't_fin', 2, 'KeyError', "'k'"), ('line', 't_fin', 4), ('return', 't_fin', 4, None),
           ('exception', 't_callfin', 2, 'KeyError', "'k'"), ('line', 't_callfin', 3), ('line', 't_callfin', 4), ('line', 't_callfin', 5),
           ('return', 't_callfin', 5, 0)]])
check("with: the with line again as it exits", [traced(t_with), [e for e in _events if e[1] == "t_with"]],
      [1, [('call', 't_with', 0), ('line', 't_with', 1), ('line', 't_with', 2), ('line', 't_with', 1), ('line', 't_with', 3), ('return', 't_with', 3, 1)]])
check("return from inside a loop", [traced(t_loopret), _events],
      [1, [('call', 't_loopret', 0), ('line', 't_loopret', 1), ('line', 't_loopret', 2), ('line', 't_loopret', 1), ('line', 't_loopret', 2),
           ('line', 't_loopret', 3), ('return', 't_loopret', 3, 1)]])
check("continue: its line, then the header's", [traced(t_cont, 3), _events],
      [3, [('call', 't_cont', 0), ('line', 't_cont', 1), ('line', 't_cont', 2), ('line', 't_cont', 3), ('line', 't_cont', 4),
           ('line', 't_cont', 2), ('line', 't_cont', 3), ('line', 't_cont', 5), ('line', 't_cont', 2), ('line', 't_cont', 3),
           ('line', 't_cont', 5), ('line', 't_cont', 2), ('line', 't_cont', 6), ('return', 't_cont', 6, 3)]])
check("a lambda: call, its one line, return", [traced(t_lam), _events],
      [3, [('call', 't_lam', 0), ('line', 't_lam', 1), ('line', 't_lam', 2), ('call', '<lambda>', 0), ('line', '<lambda>', 0),
           ('return', '<lambda>', 0, 3), ('return', 't_lam', 2, 3)]])
check("return through a finally: the return event on the finally's last line", [traced(t_retfin), _events],
      [1, [('call', 't_retfin', 0), ('line', 't_retfin', 1), ('line', 't_retfin', 2), ('line', 't_retfin', 4), ('return', 't_retfin', 4, 1)]])
check("falling off the end after a loop: return on the header's line; pass has its line", [traced(t_fall, 2), _events],
      [None, [('call', 't_fall', 0), ('line', 't_fall', 1), ('line', 't_fall', 2), ('line', 't_fall', 1), ('line', 't_fall', 2),
              ('line', 't_fall', 1), ('return', 't_fall', 1, None)]])
check("break through a finally", [traced(t_brkfin), _events],
      [None, [('call', 't_brkfin', 0), ('line', 't_brkfin', 1), ('line', 't_brkfin', 2), ('line', 't_brkfin', 3), ('line', 't_brkfin', 5),
              ('line', 't_brkfin', 6), ('return', 't_brkfin', 6, None)]])

# ── 2. trace functions: f_trace, f_trace_lines, errors, gettrace ────────────
def g_target(a):   # @g_target
    b = a + 1
    c = b * 2
    return c

def _local_only(frame, event, arg):
    _events.append(("local", event, frame.f_lineno - line_of("g_target")))
    return _local_only

def _global_picky(frame, event, arg):
    # the global function's result is the frame's local trace function
    _events.append(("global", event, frame.f_code.co_name))
    if frame.f_code.co_name == "g_target":
        return _local_only
    return None

del _events[:]
sys.settrace(_global_picky)
g_target(1)
sys.settrace(None)
check("the global function's result traces the frame", _events,
      [('global', 'call', 'g_target'), ('local', 'line', 1), ('local', 'line', 2), ('local', 'line', 3), ('local', 'return', 3)])

def _no_lines(frame, event, arg):
    if frame.f_code.co_name == "g_target":
        _events.append((event, frame.f_lineno - line_of("g_target")))
        if event == "call":
            frame.f_trace_lines = False
        return _no_lines
    return None

del _events[:]
sys.settrace(_no_lines)
g_target(1)
sys.settrace(None)
check("f_trace_lines = False: no line events", _events, [('call', 0), ('return', 3)])

def g_self_traced():   # @g_self
    fr = sys._getframe()
    fr.f_trace = _local_only_self
    sys.settrace(_quiet)
    x = 1
    y = 2
    sys.settrace(None)
    return x + y

def _local_only_self(frame, event, arg):
    _events.append((event, frame.f_lineno - line_of("g_self")))
    return _local_only_self

def _quiet(frame, event, arg):
    return None

del _events[:]
g_self_traced()
check("f_trace set on a running frame starts its line events", _events, [('line', 4), ('line', 5), ('line', 6)])

def _raising(frame, event, arg):
    if event == "line" and frame.f_code.co_name == "g_target":
        raise RuntimeError("from the trace function")
    return _raising

caught = None
sys.settrace(_raising)
try:
    g_target(1)
except RuntimeError as e:
    caught = str(e)
after = sys.gettrace()
sys.settrace(None)
check("an exception in the trace function propagates and unsets it", [caught, after is None], ["from the trace function", True])

_inner_calls = []
def _helper_in_trace(n):
    return n + 1

def _tracing_helper(frame, event, arg):
    _inner_calls.append(frame.f_code.co_name)
    _helper_in_trace(1)
    return None

sys.settrace(_tracing_helper)
g_target(1)
sys.settrace(None)
check("a trace function runs untraced", _inner_calls, ["g_target"])

sys.settrace(_tracer)
got_trace = sys.gettrace() is _tracer
sys.settrace(None)
check("gettrace / settrace(None)", [got_trace, sys.gettrace()], [True, None])

# ── 3. sys.setprofile ────────────────────────────────────────────────────────
_prof = []
def _profiler(frame, event, arg):
    if event.startswith("c_"):
        _prof.append((event, getattr(arg, "__name__", "?")))
    else:
        _prof.append((event, frame.f_code.co_name))

def p_work(xs):   # @p_work
    n = len(xs)
    xs.append(n)
    return p_leaf(n)

def p_leaf(n):
    return n * 2

def p_raise():
    raise ValueError("x")

def p_catch():
    try:
        p_raise()
    except ValueError:
        return 1

sys.setprofile(_profiler)
p_work([1, 2])
p_catch()
sys.setprofile(None)
check("profile events: call, return, c_call / c_return for builtins, no lines",
      [e for e in _prof if e[1] not in ("setprofile",)],
      [('call', 'p_work'), ('c_call', 'len'), ('c_return', 'len'), ('c_call', 'append'), ('c_return', 'append'),
       ('call', 'p_leaf'), ('return', 'p_leaf'), ('return', 'p_work'),
       ('call', 'p_catch'), ('call', 'p_raise'), ('return', 'p_raise'), ('return', 'p_catch')])

_prof2 = []
def _prof_args(frame, event, arg):
    if event == "return" and frame.f_code.co_name in ("p_leaf", "p_raise"):
        _prof2.append((frame.f_code.co_name, arg))
    if event == "c_exception":
        _prof2.append(("c_exception", arg.__name__))

def p_cexc():
    try:
        len(5)
    except TypeError:
        pass

sys.setprofile(_prof_args)
p_leaf(4)
p_catch()
p_cexc()
got_prof = sys.getprofile() is _prof_args
sys.setprofile(None)
check("profile return values; None when an exception leaves; c_exception", _prof2,
      [('p_leaf', 8), ('p_raise', None), ('c_exception', 'len')])
check("getprofile", [got_prof, sys.getprofile()], [True, None])

# ── 4. f_locals: writes reach the running frame (PEP 667) ────────────────────
def w_target():   # @w_target
    a = 1
    b = a + 1
    return a, b

def _set_a(frame, event, arg):
    if frame.f_code.co_name == "w_target":
        if event == "line" and frame.f_lineno == line_of("w_target") + 2:
            frame.f_locals["a"] = 100
        return _set_a
    return None

sys.settrace(_set_a)
w_res = w_target()
sys.settrace(None)
check("a trace function's f_locals write changes the variable", w_res, (100, 101))

def w_direct():
    x = 1
    fl = sys._getframe().f_locals
    fl["x"] = 10
    seen = fl["x"]
    return x, seen, "x" in fl, sorted(k for k in fl if k != "fl")

wd = w_direct()
# 3.13's FrameLocalsProxy writes through; 3.11's dict snapshot does not
check("frame.f_locals[name] = v writes through (3.13; 3.11 under python3 keeps x)",
      wd if nython else ((10, 10, True, ['seen', 'x']) if wd[0] == 10 else wd),
      (10, 10, True, ['seen', 'x']) if nython or wd[0] == 10 else (1, 10, True, ['x']))

def w_proxy_ops():
    p = 3
    q = 4
    fl = sys._getframe().f_locals
    out = [fl.get("p"), fl.get("zz", "d"), len([k for k in fl if k in ("p", "q")])]
    fl.update({"q": 40})
    out.append(q)
    return out

wp = w_proxy_ops()
check("f_locals as a mapping: get, update", wp if nython else (wp if wp[3] == 40 else wp[:3] + [40]), [3, 'd', 2, 40])

def w_dead():
    v = 7
    return sys._getframe()

dead = w_dead()
check("an ended frame's f_locals is what it ended with", dead.f_locals["v"], 7)

# ── 5. threading.settrace: threads started afterwards ────────────────────────
import threading

_thread_calls = []
def _thread_tracer(frame, event, arg):
    if event == "call" and frame.f_code.co_name in ("th_work", "th_leaf"):
        _thread_calls.append(frame.f_code.co_name)
    return None

def th_leaf():
    return 1

def th_work():
    return th_leaf() + 1

threading.settrace(_thread_tracer)
th_hook = threading.gettrace() is _thread_tracer
th = threading.Thread(target=th_work)
th.start()
th.join()
threading.settrace(None)
th_main = sys.gettrace()
check("threading.settrace: the thread's calls are traced, this thread's is not set",
      [th_hook, _thread_calls, th_main, threading.gettrace()], [True, ['th_work', 'th_leaf'], None, None])

_thread_prof = []
def _thread_profiler(frame, event, arg):
    if event == "call" and frame.f_code.co_name == "th_leaf":
        _thread_prof.append(event)

threading.setprofile(_thread_profiler)
th2 = threading.Thread(target=th_leaf)
th2.start()
th2.join()
threading.setprofile(None)
check("threading.setprofile", [_thread_prof, threading.getprofile()], [['call'], None])

# ── 6. the data model: nested qualnames, async staticmethods, `this` ─────────
class QOuter:
    class QInner:
        def m(self):
            return 1
        class QDeep:
            pass

def q_make():
    class QLocal:
        def meth(self):
            return 2
    return QLocal

check("a nested class's __qualname__", [QOuter.__qualname__, QOuter.QInner.__qualname__, QOuter.QInner.QDeep.__qualname__,
                                        QOuter.QInner.__name__, QOuter.QInner.m.__qualname__],
      ['QOuter', 'QOuter.QInner', 'QOuter.QInner.QDeep', 'QInner', 'QOuter.QInner.m'])
check("a class in a function: f.<locals>.C", [q_make().__qualname__, q_make().__name__, q_make().meth.__qualname__],
      ['q_make.<locals>.QLocal', 'QLocal', 'q_make.<locals>.QLocal.meth'])

import asyncio

class AsyncStatic:
    @staticmethod
    async def double(x):
        await asyncio.sleep(0)
        return x * 2

    @staticmethod
    async def chain(x):
        return await AsyncStatic.double(x) + 1

check("an async staticmethod", [asyncio.run(AsyncStatic.double(4)), asyncio.run(AsyncStatic.chain(5)),
                                asyncio.run(AsyncStatic().double(1))], [8, 11, 2])

import inspect

class ThisRecv:
    def m(this, x, y=2):
        return x + y

check("inspect.signature keeps a receiver named this", [str(inspect.signature(ThisRecv.m)), str(inspect.signature(ThisRecv().m))],
      ['(this, x, y=2)', '(x, y=2)'])

# ── 7. breakpoint() and sys.breakpointhook ───────────────────────────────────
_bp_calls = []
def _my_hook(*args, **kws):
    _bp_calls.append((args, kws))
    return "hooked"

old_hook = sys.breakpointhook
sys.breakpointhook = _my_hook
bp_r = breakpoint(1, k=2)
sys.breakpointhook = old_hook
check("breakpoint() calls sys.breakpointhook", [bp_r, _bp_calls], ["hooked", [((1,), {'k': 2})]])
# the hook reads the process environment when it is called (Nython's
# os.environ is a snapshot that does not write through: os_setenv)
def _putenv(k, v):
    if nython:
        os_setenv(k, v)
    else:
        os.environ[k] = v
_putenv("PYTHONBREAKPOINT", "0")
check("PYTHONBREAKPOINT=0 turns breakpoint() off", breakpoint(), None)
_putenv("PYTHONBREAKPOINT", "math.sqrt")
check("PYTHONBREAKPOINT=mod.func calls that", sys.breakpointhook(16.0), 4.0)
if nython:
    os.unsetenv("PYTHONBREAKPOINT")
else:
    del os.environ["PYTHONBREAKPOINT"]
check("sys.__breakpointhook__ is the original", sys.__breakpointhook__ is old_hook, True)

# ── 8. bdb ───────────────────────────────────────────────────────────────────
import bdb
import pdb

def dbg_target(n):   # @dbg_target
    total = 0
    for i in range(n):
        total += i * 2   # @dbg_body
    result = total + 1
    return result   # @dbg_ret

def dbg_caller():   # @dbg_caller
    v = dbg_target(3)
    w = v + 1
    return w

_T = line_of("dbg_target")

class LineRecorder(bdb.Bdb):
    def __init__(self):
        bdb.Bdb.__init__(self)
        self.seen = []
    def user_call(self, frame, args):
        self.seen.append(("call", frame.f_code.co_name))
        self.set_step()
    def user_line(self, frame):
        if frame.f_code.co_name == "dbg_target":
            self.seen.append(("line", frame.f_lineno - _T))
        self.set_step()
    def user_return(self, frame, value):
        self.seen.append(("return", frame.f_code.co_name, value))
        self.set_step()

bdb.Breakpoint.clearBreakpoints()
rec = LineRecorder()
rec_r = rec.runcall(dbg_target, 2)
check("Bdb stepping: every line of the call", [rec_r, rec.seen],
      [3, [('line', 1), ('line', 2), ('line', 3), ('line', 2), ('line', 3), ('line', 2), ('line', 4), ('line', 5), ('return', 'dbg_target', 3)]])

class BreakRecorder(bdb.Bdb):
    def __init__(self):
        bdb.Bdb.__init__(self)
        self.hits = []
    def user_line(self, frame):
        # user_line runs where the debugger stops: the first line, then breakpoints
        if frame.f_lineno == line_of("dbg_body"):
            self.hits.append((frame.f_lineno - _T, frame.f_locals["i"], frame.f_locals["total"]))
        self.set_continue()

bdb.Breakpoint.clearBreakpoints()
brec = BreakRecorder()
brk_err = brec.set_break(__file__, line_of("dbg_body"))
brec.runcall(dbg_target, 3)
check("Bdb breakpoints: set_continue stops only there", [brk_err, brec.hits], [None, [(3, 0, 0), (3, 1, 0), (3, 2, 2)]])
bp1 = bdb.Breakpoint.bpbynumber[1]
check("a Breakpoint's fields and hits", [bp1.number, bp1.line - _T, bp1.hits, bp1.enabled, bp1.temporary, bp1.file == os.path.abspath(__file__)],
      [1, 3, 3, True, False, True])
check("bpformat", bp1.bpformat().replace(bp1.file, "FILE").replace(str(bp1.line), "L"),
      "1   breakpoint   keep yes   at FILE:L\n\tbreakpoint already hit 3 times")
check("set_break on a line past the end", brec.set_break(__file__, 99999).replace(os.path.abspath(__file__), "FILE"),
      "Line FILE:99999 does not exist")
bp1.disable()   # breakpoints are shared by every debugger
brec2 = BreakRecorder()
brec2.set_break(__file__, line_of("dbg_body"), cond="i == 2")
brec2.hits = []
brec2.runcall(dbg_target, 4)
check("a conditional breakpoint", brec2.hits, [(3, 2, 2)])
def _bpnum_err(arg):
    try:
        brec.get_bpbynumber(arg)
    except ValueError as e:
        return str(e)
    return "ok"
check("get_bpbynumber's errors", [_bpnum_err(""), _bpnum_err("x"), _bpnum_err("99"), _bpnum_err("1")],
      ["Breakpoint number expected", "Non-numeric breakpoint number x", "Breakpoint number 99 out of range", "ok"])
check("clear_bpbynumber / clear_break", [brec.clear_bpbynumber("1"), _bpnum_err("1"),
                                         brec.clear_break(__file__, 5).replace(os.path.abspath(__file__), "FILE")],
      [None, "Breakpoint 1 already deleted", "There is no breakpoint at FILE:5"])
bdb.Breakpoint.clearBreakpoints()

class IgnoreRec(BreakRecorder):
    pass
irec = IgnoreRec()
irec.set_break(__file__, line_of("dbg_body"), temporary=True)
tbp = bdb.Breakpoint.bpbynumber[1]
tbp.ignore = 1
irec.hits = []
irec.do_clear = lambda arg: irec.clear_bpbynumber(arg)
irec.runcall(dbg_target, 3)
check("ignore count, then a temporary breakpoint deletes itself", [irec.hits, bdb.Breakpoint.bpbynumber[1], tbp.hits],
      [[(3, 1, 0)], None, 2])
bdb.Breakpoint.clearBreakpoints()

# ── 9. pdb, scripted ─────────────────────────────────────────────────────────
_ABS = os.path.abspath(__file__)

def _norm(text):
    # this file's path as FILE; the frames of bdb's own run / runcall (a
    # library's path and line) left out
    out = []
    lines = text.replace(_ABS, "FILE").split("\n")
    skip = False
    for ln in lines:
        if skip:
            skip = False
            continue
        if "bdb.py(" in ln or "bdb.ny(" in ln:
            skip = True
            continue
        out.append(ln.rstrip())
    return out

def run_pdb(cmds, func, *args):
    bdb.Breakpoint.clearBreakpoints()
    out = io.StringIO()
    p = pdb.Pdb(stdin=io.StringIO("\n".join(cmds) + "\n"), stdout=out, readrc=False)
    r = p.runcall(func, *args)
    bdb.Breakpoint.clearBreakpoints()
    return r, _norm(out.getvalue())

B = line_of("dbg_body")
pr, pout = run_pdb(["b %d" % B, "c", "p total", "p i", "n", "p total", "c", "p i, total", "args", "cl 1", "r", "retval", "c"],
                   dbg_target, 3)
check("pdb: break, continue, p, next, args, clear, return, retval", [pr, pout],
      [7, ['> FILE(%d)dbg_target()' % (_T + 1), '-> total = 0',
           '(Pdb) Breakpoint 1 at FILE:%d' % B,
           '(Pdb) > FILE(%d)dbg_target()' % B, '-> total += i * 2   # @dbg_body',
           '(Pdb) 0', '(Pdb) 0',
           '(Pdb) > FILE(%d)dbg_target()' % (B - 1), '-> for i in range(n):',
           '(Pdb) 0',
           '(Pdb) > FILE(%d)dbg_target()' % B, '-> total += i * 2   # @dbg_body',
           '(Pdb) (1, 0)', '(Pdb) n = 3',
           '(Pdb) Deleted breakpoint 1 at FILE:%d' % B,
           '(Pdb) --Return--', '> FILE(%d)dbg_target()->7' % (B + 2), '-> return result   # @dbg_ret',
           '(Pdb) 7', '(Pdb)']])

pr2, pout2 = run_pdb(["display total", "n", "n", "n", "!total = 100", "p total", "whatis total", "pp [1, 2]", "p nosuch",
                      "alias pt p total + 1", "pt", "until %d" % (B + 1), "p result", "c"], dbg_target, 2)
check("pdb: display, ! statements change the frame, whatis, pp, errors, alias, until", [pr2, pout2],
      [103, ['> FILE(%d)dbg_target()' % (_T + 1), '-> total = 0',
             '(Pdb) display total: ** raised NameError: name \'total\' is not defined **',
             '(Pdb) > FILE(%d)dbg_target()' % (B - 1), '-> for i in range(n):',
             'display total: 0  [old: ** raised NameError: name \'total\' is not defined **]',
             '(Pdb) > FILE(%d)dbg_target()' % B, '-> total += i * 2   # @dbg_body',
             '(Pdb) > FILE(%d)dbg_target()' % (B - 1), '-> for i in range(n):',
             '(Pdb) (Pdb) 100', "(Pdb) <class 'int'>", '(Pdb) [1, 2]',
             "(Pdb) *** NameError: name 'nosuch' is not defined", '(Pdb) (Pdb) 101',
             '(Pdb) > FILE(%d)dbg_target()' % (B + 1), '-> result = total + 1',
             'display total: 102  [old: 0]',
             '(Pdb) *** NameError: name \'result\' is not defined', '(Pdb)']])

pr3, pout3 = run_pdb(["b dbg_target", "c", "up", "p v if 'v' in dir() else 'no v'", "down", "s", "s", "w", "q"], dbg_caller)
check("pdb: a function breakpoint, up / down, step, where", [pr3, pout3],
      [None, ['> FILE(%d)dbg_caller()' % (line_of("dbg_caller") + 1), '-> v = dbg_target(3)',
              '(Pdb) Breakpoint 1 at FILE:%d' % (_T + 1 if py313 else _T),
              '(Pdb) > FILE(%d)dbg_target()' % (_T + 1), '-> total = 0',
              '(Pdb) > FILE(%d)dbg_caller()' % (line_of("dbg_caller") + 1), '-> v = dbg_target(3)',
              "(Pdb) 'no v'",
              '(Pdb) > FILE(%d)dbg_target()' % (_T + 1), '-> total = 0',
              '(Pdb) > FILE(%d)dbg_target()' % (_T + 2), '-> for i in range(n):',
              '(Pdb) > FILE(%d)dbg_target()' % B, '-> total += i * 2   # @dbg_body',
              '  FILE(%d)dbg_caller()' % (line_of("dbg_caller") + 1), '-> v = dbg_target(3)',
              '> FILE(%d)dbg_target()' % B, '-> total += i * 2   # @dbg_body', '(Pdb)']])

def pm_target(k):   # @pm_target
    secret = k + 1
    raise ValueError("post mortem")

def pm_outer():   # @pm_outer
    return pm_target(40)

try:
    pm_outer()
except ValueError:
    pm_tb = sys.exc_info()[2]
pm_out = io.StringIO()
pmd = pdb.Pdb(stdin=io.StringIO("p secret\nargs\nup\np k if 'k' in dir() else 'no k'\nl %d, %d\nq\n" % (line_of("pm_outer"), line_of("pm_outer") + 1)),
              stdout=pm_out, readrc=False)
pmd.reset()
pmd.interaction(None, pm_tb)
check("pdb post-mortem: the traceback's frames and their locals", _norm(pm_out.getvalue()),
      ['> FILE(%d)pm_target()' % (line_of("pm_target") + 2), '-> raise ValueError("post mortem")',
       '(Pdb) 41', '(Pdb) k = 40',
       '(Pdb) > FILE(%d)pm_outer()' % (line_of("pm_outer") + 1), '-> return pm_target(40)',
       "(Pdb) 'no k'",
       '(Pdb) %3d  \tdef pm_outer():   # @pm_outer' % line_of("pm_outer"),
       '%3d  ->\t    return pm_target(40)' % (line_of("pm_outer") + 1),
       '(Pdb)'])

ll_out = run_pdb(["ll", "c"], dbg_target, 1)[1]
check("pdb longlist", ll_out[2:9],
      ['(Pdb) %3d  \tdef dbg_target(n):   # @dbg_target' % _T,
       '%3d  ->\t    total = 0' % (_T + 1),
       '%3d  \t    for i in range(n):' % (_T + 2),
       '%3d  \t        total += i * 2   # @dbg_body' % (_T + 3),
       '%3d  \t    result = total + 1' % (_T + 4),
       '%3d  \t    return result   # @dbg_ret' % (_T + 5),
       '(Pdb)'])

run_out = io.StringIO()
bdb.Breakpoint.clearBreakpoints()
prun = pdb.Pdb(stdin=io.StringIO("s\nn\np n\nq\n"), stdout=run_out, readrc=False)
prun.run("dbg_target(2)", {"dbg_target": dbg_target})
check("Pdb.run: exec'd code, then a step into the call", _norm(run_out.getvalue()),
      ['> <string>(1)<module>()', '(Pdb) --Call--', '> FILE(%d)dbg_target()' % _T, '-> def dbg_target(n):   # @dbg_target',
       '(Pdb) > FILE(%d)dbg_target()' % (_T + 1), '-> total = 0', '(Pdb) 2', '(Pdb)'])

help_out = io.StringIO()
ph = pdb.Pdb(stdin=io.StringIO(""), stdout=help_out, readrc=False)
ph.onecmd("help next")
ph.onecmd("help nosuchcmd")
check("pdb help (3.13's layout)", help_out.getvalue().split("\n"),
      (['      Usage: n(ext)', '      ', '      Continue execution until the next line in the current function',
        '      is reached or it returns.'] if py313 else
       ['n(ext)', '        Continue execution until the next line in the current function', '        is reached or it returns.']) +
      ["*** No help for 'nosuchcmd'", ''])

# ── 10. cProfile, profile, pstats: exact call counts ─────────────────────────
import cProfile
import profile
import pstats
import re

def fib(n):   # @fib
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def prof_main(xs):   # @prof_main
    total = 0
    k = 0
    while k < 3:
        total += fib(k + 3) + len(xs)
        k += 1
    return total

_here = os.path.basename(__file__)
def _entry(st, name):
    # a function of this file by name, or a builtin by its label
    for key in st.stats:
        if key[2] == name and (os.path.basename(key[0]) == _here or key[0] == "~" or key[0] == ""):
            return key, st.stats[key]
    return None, None

pr = cProfile.Profile()
pr.enable()
p_r = prof_main([1, 2])
pr.disable()
cst = pstats.Stats(pr)
fk, fv = _entry(cst, "fib")
mk, mv = _entry(cst, "prof_main")
check("cProfile: recursive calls (29 calls, 3 primitive)", [p_r, fv[1], fv[0], fk[1] - line_of("fib"), mv[0], mv[1]],
      [16, 29, 3, 0, 1, 1])
check("cProfile: callers in (calls, primitive calls, ...) form",
      sorted((c[2], v[0], v[1]) for c, v in fv[4].items()), [('fib', 26, 6), ('prof_main', 3, 3)])
lk, lv = _entry(cst, "<built-in method builtins.len>")
dk, dv = _entry(cst, "<method 'disable' of '_lsprof.Profiler' objects>")
check("cProfile: builtins and disable() counted", [lk, lv[:2], dk[0], dv[:2]],
      [('~', 0, '<built-in method builtins.len>'), (3, 3), '~', (1, 1)])
check("cProfile: times are consistent", [fv[2] >= 0, fv[3] >= fv[2], mv[3] >= fv[3]], [True, True, True])

pout = io.StringIO()
pstats.Stats(pr, stream=pout).strip_dirs().sort_stats("calls").print_stats()
plines = pout.getvalue().split("\n")
fibline = [ln for ln in plines if ln.endswith("(fib)")][0]
check("print_stats: the header and the recursive ncalls column",
      [bool(re.match(r"^\s+\d+ function calls \(\d+ primitive calls\) in \d+\.\d{3} seconds$", plines[0])),
       "   Ordered by: call count" in plines, fibline.split()[0], fibline.split()[-1]],
      [True, True, "29/3", "%s:%d(fib)" % (_here, line_of("fib"))])
cols = [ln for ln in plines if "ncalls" in ln][0]
check("print_stats: the column titles", cols.split(), ['ncalls', 'tottime', 'percall', 'cumtime', 'percall', 'filename:lineno(function)'])

rout = io.StringIO()
pstats.Stats(pr, stream=rout).strip_dirs().sort_stats("ncalls").print_stats(1)
check("print_stats(1): one line, reduced", [ln for ln in rout.getvalue().split("\n") if "List reduced" in ln][0].strip()[:18],
      "List reduced from ")
cout = io.StringIO()
pstats.Stats(pr, stream=cout).strip_dirs().print_callers("fib")
cl = cout.getvalue().split("\n")
ci = [i for i in range(len(cl)) if "<-" in cl[i]][0]
check("print_callers", [cl[ci].split()[1:3], cl[ci].split()[-1], cl[ci + 1].split()[0], cl[ci + 1].split()[-1]],
      [["<-", "26/6"], "%s:%d(fib)" % (_here, line_of("fib")), "3", "%s:%d(prof_main)" % (_here, line_of("prof_main"))])
ceout = io.StringIO()
pstats.Stats(pr, stream=ceout).strip_dirs().print_callees("prof_main")
ce = ceout.getvalue().split("\n")
ci = [i for i in range(len(ce)) if "->" in ce[i]][0]
check("print_callees", [ce[ci].split()[1:3], ce[ci].split()[-1], ce[ci + 1].strip()[-30:]],
      [["->", "3"], "%s:%d(fib)" % (_here, line_of("fib")), "{built-in method builtins.len}"])

# a Stats dumped and read back
import tempfile
_tmpd = tempfile.mkdtemp()
dump_path = os.path.join(_tmpd, "prof_%d.out" % os.getpid())
pr.dump_stats(dump_path)
back = pstats.Stats(dump_path)
check("dump_stats / Stats(file)", _entry(back, "fib")[1][:2], (3, 29))
sp = pstats.Stats(pr).get_stats_profile()
check("get_stats_profile", [sp.func_profiles["fib"].ncalls, sp.func_profiles["fib"].line_number - line_of("fib")], ["29/3", 0])

with cProfile.Profile() as pr2:
    fib(4)
check("Profile as a context manager", _entry(pstats.Stats(pr2), "fib")[1][:2], (1, 9))
pr3 = cProfile.Profile()
check("runcall", [pr3.runcall(fib, 5), _entry(pstats.Stats(pr3), "fib")[1][:2]], [5, (1, 15)])

pp = profile.Profile()
pp_ok = True
try:
    pp_r = pp.runcall(prof_main, [1])
except AssertionError:
    # python3.12+ only: its profile.py meets a stray "return" event from
    # sys.setprofile once sys.settrace was used earlier in the process
    if nython:
        raise
    pp_ok = False
if pp_ok:
    pst = pstats.Stats(pp)
    pk, pv = _entry(pst, "fib")
    check("profile (the pure-Python profiler): counts", [pp_r, pv[0], pv[1]], [13, 3, 29])
    check("profile: callers map to counts", sorted((c[2], n) for c, n in pv[4].items()), [('fib', 26), ('prof_main', 3)])
    check("profile: a builtin's key", _entry(pst, "len")[0], ('', 0, 'len'))
check("sort keys", [pstats.SortKey.CUMULATIVE.value, pstats.SortKey.TIME.value, sorted(pstats.Stats.sort_arg_dict_default)[:4]],
      ['cumulative', 'time', ['calls', 'cumtime', 'cumulative', 'filename']])

# ── 11. timeit ───────────────────────────────────────────────────────────────
import timeit

_clock = [0]
def _fake_timer():
    return _clock[0] / 64.0      # exact binary fractions

def _advance():
    _clock[0] += 1

ft = timeit.Timer(_advance, timer=_fake_timer)
check("Timer.timeit with a given timer", ft.timeit(number=5), 5 / 64.0)
check("Timer.repeat", ft.repeat(repeat=3, number=2), [2 / 64.0, 2 / 64.0, 2 / 64.0])
_tries = []
check("Timer.autorange: 1, 2, 5, 10, 20 ... until >= 0.2 s",
      [ft.autorange(lambda n, t: _tries.append(n)), _tries], [(20, 20 / 64.0), [1, 2, 5, 10, 20]])
st_t = timeit.Timer("_advance(); _advance()", setup="_clock[0] += 100", timer=_fake_timer,
                    globals={"_advance": _advance, "_clock": _clock})
check("string statements with setup and globals", st_t.timeit(number=3), 6 / 64.0)
_setups = [0]
def _setup_fn():
    _setups[0] += 1
timeit.repeat("pass", setup=_setup_fn, repeat=4, number=3)
check("setup runs once per repeat", _setups[0], 4)
check("timeit.timeit returns seconds", [type(timeit.timeit("x = 1", number=10)).__name__], ['float'])
try:
    timeit.Timer("x = = 1")
    t_err = "no error"
except SyntaxError:
    t_err = "SyntaxError"
check("a statement that does not compile", t_err, "SyntaxError")
try:
    timeit.Timer("return 1")
    t_err2 = "no error"
except SyntaxError:
    t_err2 = "SyntaxError"
check("a statement outside the template is refused", t_err2, "SyntaxError")
check("Timer.src has the statement inside CPython's template", "_t0 = _timer()" in timeit.Timer("pass").src if nython else True, True)

_saved_out = sys.stdout
_tbuf = io.StringIO()
sys.stdout = _tbuf
timeit.main(["-n", "3", "-r", "2", "-s", "a = 1", "b = a + 1"])
sys.stdout = _saved_out
check("timeit's command line output", bool(re.match(r"^3 loops, best of 2: \d+(\.\d+)? (nsec|usec|msec|sec) per loop\n$", _tbuf.getvalue())),
      True)

# ── 12. trace ────────────────────────────────────────────────────────────────
import trace

tr = trace.Trace(count=1, trace=0)
tr_r = tr.runfunc(dbg_target, 3)
tres = tr.results()
check("trace counts: lines and how often they ran", [tr_r, sorted((k[1] - _T, v) for k, v in tres.counts.items()
                                                            if os.path.basename(k[0]) == _here)],
      [7, [(1, 1), (2, 4), (3, 3), (4, 1), (5, 1)]])
trf = trace.Trace(count=0, trace=0, countfuncs=1)
trf.runfunc(dbg_caller)
check("trace countfuncs", sorted(k[2] for k in trf.results().calledfuncs if os.path.basename(k[0]) == _here),
      ['dbg_caller', 'dbg_target'])
check("trace countfuncs: the module name", sorted(set(k[1] for k in trf.results().calledfuncs if os.path.basename(k[0]) == _here)),
      ['vm_audit91'])
trc = trace.Trace(count=0, trace=0, countcallers=1)
trc.runfunc(dbg_caller)
check("trace countcallers", sorted((a[2], b[2]) for a, b in trc.results().callers
                                   if os.path.basename(a[0]) == _here and os.path.basename(b[0]) == _here),
      [('dbg_caller', 'dbg_target')])

_tbuf = io.StringIO()
sys.stdout = _tbuf
trace.Trace(count=0, trace=1).runfunc(dbg_target, 1)
sys.stdout = _saved_out
_sep = ":  " if py313 else ": "     # 3.13 prints ": " and the line with print's separator
check("trace=1 prints each line as it runs (3.13's layout)",
      [ln for ln in _tbuf.getvalue().split("\n") if ln and "bdb" not in ln][:4],
      [' --- modulename: vm_audit91, funcname: dbg_target',
       '%s(%d)%s    total = 0' % (_here, _T + 1, _sep),
       '%s(%d)%s    for i in range(n):' % (_here, _T + 2, _sep),
       '%s(%d)%s        total += i * 2   # @dbg_body' % (_here, _T + 3, _sep)])

cover_path = os.path.join(_tmpd, "w_%d.cover" % os.getpid())
wr = trace.CoverageResults().write_results_file(cover_path, ["a = 1\n", "if a:\n", "    b = 2\n", "else:\n", "    b = 3\n"],
                                                {1: 1, 2: 1, 3: 1, 5: 1}, {1: 1, 2: 1, 3: 4})
check("write_results_file: counts, >>>>>> for lines never run", [wr, open(cover_path).read()],
      [(3, 4), "    1: a = 1\n    1: if a:\n    4:     b = 2\n       else:\n>>>>>>     b = 3\n"])

src_path = os.path.join(_tmpd, "trmod_%d.py" % os.getpid())
with open(src_path, "w") as f:
    f.write("def tf(n):\n    if n > 0:\n        return 1\n    return 0\n")
tns = {"__file__": src_path, "__name__": "trmod"}    # trace follows code whose globals have __file__
exec(compile(open(src_path).read(), src_path, "exec"), tns)
trw = trace.Trace(count=1, trace=0)
trw.runfunc(tns["tf"], 2)
trw.runfunc(tns["tf"], 3)
cov_dir = os.path.join(_tmpd, "cov")
trw.results().write_results(show_missing=False, coverdir=cov_dir)
cov_files = os.listdir(cov_dir)
check("write_results: a .cover file per module",
      [len(cov_files), cov_files[0].endswith("trmod_%d.cover" % os.getpid()),
       open(os.path.join(cov_dir, cov_files[0])).read()],
      [1, True, "       def tf(n):\n    2:     if n > 0:\n    2:         return 1\n           return 0\n"])

# ── 13. cmd ──────────────────────────────────────────────────────────────────
import cmd

class Shell(cmd.Cmd):
    prompt = "> "
    intro = "welcome"
    def __init__(self, **kw):
        cmd.Cmd.__init__(self, **kw)
        self.log = []
    def do_add(self, arg):
        "add A B: print the sum"
        a, b = arg.split()
        self.stdout.write("%d\n" % (int(a) + int(b)))
    def do_quit(self, arg):
        return True
    def do_EOF(self, arg):
        return True
    def default(self, line):
        self.log.append("default:" + line)
    def precmd(self, line):
        self.log.append("pre:" + line)
        return line
    def postcmd(self, stop, line):
        self.log.append("post:" + ("None" if stop is None else "True" if stop is True else "other"))
        return stop
    def help_topic(self):
        self.stdout.write("about the topic\n")

sh_out = io.StringIO()
sh = Shell(stdin=io.StringIO("add 1 2\nfoo bar\n\n?add\nhelp topic\n!x\nquit\n"), stdout=sh_out)
sh.use_rawinput = False
sh.cmdloop()
check("Cmd.cmdloop: dispatch, default, an empty line repeats, ? and help_, the hooks",
      [sh_out.getvalue(), sh.log],
      ["welcome\n> 3\n> > > add A B: print the sum\n> about the topic\n> > ",
       ['pre:add 1 2', 'post:None', 'pre:foo bar', 'default:foo bar', 'post:None', 'pre:', 'default:foo bar',
        'post:None', 'pre:?add', 'post:None', 'pre:help topic', 'post:None', 'pre:!x', 'default:!x', 'post:None',
        'pre:quit', 'post:True']])
check("Cmd.parseline", [sh.parseline("add 1 2"), sh.parseline("?x"), sh.parseline("!ls"), sh.parseline("  "), sh.parseline("7up")],
      [('add', '1 2', 'add 1 2'), ('help', 'x', 'help x'), (None, None, '!ls'), (None, None, ''), ('7up', '', '7up')])
h_out = io.StringIO()
Shell(stdout=h_out).onecmd("help")
check("help's command list", h_out.getvalue(),
      "\nDocumented commands (type help <topic>):\n========================================\nadd  help\n\n"
      "Miscellaneous help topics:\n==========================\ntopic\n\n"
      "Undocumented commands:\n======================\nEOF  quit\n\n")
c_out = io.StringIO()
cmd.Cmd(stdout=c_out).columnize(["alpha", "be", "c", "delta", "e", "f"], displaywidth=14)
check("columnize", c_out.getvalue(), "alpha  delta\nbe     e    \nc      f    \n")
check("completenames", sorted(Shell().completenames("he")), ['help'])

# ── 14. code and codeop ──────────────────────────────────────────────────────
import code
import codeop

check("codeop.compile_command: complete, incomplete, wrong",
      [codeop.compile_command("x = 1") is not None, codeop.compile_command("if x:"), codeop.compile_command("(1,"),
       codeop.compile_command("def f():\n    return 1"), codeop.compile_command("s = '''abc"),
       codeop.compile_command("# just a comment") is not None],
      [True, None, None, None, None, True])
try:
    codeop.compile_command("x = = 1")
    cc_err = "none"
except SyntaxError:
    cc_err = "SyntaxError"
check("codeop.compile_command: a syntax error", cc_err, "SyntaxError")

ic = code.InteractiveConsole({"z": 5})
ic_out = []
ic.write = lambda data: ic_out.append(data)
_cbuf = io.StringIO()
sys.stdout = _cbuf
pushes = [ic.push("y = z * 2"), ic.push("def f(a):"), ic.push("    return a + y"), ic.push(""), ic.push("f(1)"),
          ic.push("1 / 0"), ic.push("x = = 1")]
sys.stdout = _saved_out
check("InteractiveConsole.push: more input, values shown, errors reported",
      [pushes, _cbuf.getvalue(), ic.locals["y"], "".join(ic_out).count("Traceback (most recent call last):"),
       "ZeroDivisionError: division by zero" in "".join(ic_out).split("\n"), "".join(ic_out).split("\n")[-2][:12]],
      [[False, True, True, False, False, False, False], "11\n", 10, 1, True, "SyntaxError:"])
ii = code.InteractiveInterpreter({})
check("InteractiveInterpreter.runsource", [ii.runsource("q = 4"), ii.runsource("for i in []:"), ii.locals["q"]], [False, True, 4])
_lines = ["a = 6", "a * 7"]
_ibuf = io.StringIO()
sys.stdout = _ibuf
_saved_err = sys.stderr
sys.stderr = _ibuf
code.interact(banner="hi", readfunc=lambda prompt: _lines.pop(0) if _lines else (_ for _ in ()).throw(EOFError()),
              local={}, exitmsg="bye")
sys.stdout = _saved_out
sys.stderr = _saved_err
check("code.interact with a readfunc", _ibuf.getvalue(), "hi\n42\n\nbye\n")

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + r[2] + " want " + r[3])
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT91 PASSED ===")
