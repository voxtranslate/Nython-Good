# vm_audit103.ny - the interpreter's remaining costs (round 82): exceptions
# that travel without a C++ throw, and loop targets bound straight from an
# iterator's parts.
#
# On the tree-walking interpreter a `raise` statement, and the KeyError /
# IndexError / ZeroDivisionError / AttributeError / StopIteration / ValueError
# the evaluator raises itself, now travel as a pending exception (a flag and
# the exception, CPython's error indicator) back to the `try` that catches it
# - in the same function or in a caller on the interpreter's own stack -
# wherever every construct in between checks for it; across anything else
# (a builtin calling back into Nython code, a generator's own stack, a
# thread, the prelude) they are thrown as before. `for a, b in enumerate(xs)`
# / `zip(...)` / `d.items()` bind the targets from the iterator's parts
# without making a tuple per step. Every scenario here takes a new path and
# its fallback, and checks Python's answers: what is caught where, finally
# and __exit__ ordering, tracebacks, sys.settrace's exception events,
# __context__/__cause__, except*, generators, threads, and every loop
# target shape. It must give the same answers on the VM, under python3 and
# with NY_ASTSPEC=0 (the general paths):
#
#     ./build/nython-cli examples/vm_audit103.ny
#     ./build/nython-cli --vm examples/vm_audit103.ny
#     NY_ASTSPEC=0 ./build/nython-cli examples/vm_audit103.ny
#     python3 examples/vm_audit103.ny
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
import linecache
import threading

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

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

N = 50

# ── 1. raised and caught in the same function ───────────────────────────────
class AppError(Exception):
    pass

class NotFound(AppError):
    def __init__(self, key):
        AppError.__init__(self, key)
        self.key = key

class Invalid(AppError):
    pass

def same_function(n):
    caught = []
    for i in range(n):
        try:
            if i % 3 == 0:
                raise NotFound(i)
            if i % 3 == 1:
                raise Invalid("bad %d" % i)
            caught.append(("none", i))
        except NotFound as e:
            caught.append(("nf", e.key, e.args))
        except AppError as e:
            caught.append(("app", str(e)))
    return caught

r = same_function(N)
check("raised and caught in the same function", [r[0], r[1], r[2], r[48], r[49], len(r)],
      [("nf", 0, (0,)), ("app", "bad 1"), ("none", 2), ("nf", 48, (48,)), ("app", "bad 49"), 50])

def raise_class_forms():
    out = []
    try:
        raise ValueError
    except ValueError as e:
        out.append((type(e).__name__, e.args))
    try:
        raise ValueError()
    except ValueError as e:
        out.append((type(e).__name__, e.args))
    try:
        raise KeyError("k")
    except LookupError as e:
        out.append((type(e).__name__, e.args, str(e)))
    try:
        raise AppError
    except Exception as e:
        out.append((type(e).__name__, e.args))
    return out

check("raise a class, an instance, a builtin", raise_class_forms(),
      [("ValueError", ()), ("ValueError", ()), ("KeyError", ("k",), "'k'"), ("AppError", ())])

def e_unbound():
    try:
        raise ValueError("x")
    except ValueError as e:
        pass
    try:
        e
        return "bound"
    except NameError:
        return "unbound"
    except UnboundLocalError:
        return "unbound"

check("except ... as e unbinds e (pending path)", e_unbound(), "unbound")

def unmatched_then_outer():
    log = []
    try:
        try:
            raise KeyError("inner")
        except ValueError:
            log.append("wrong")
        finally:
            log.append("inner finally")
    except KeyError as e:
        log.append("outer " + str(e))
    return log

check("no clause matches: the outer try in the same function", unmatched_then_outer(),
      ["inner finally", "outer 'inner'"])

# ── 2. raised in a callee, caught in a caller ───────────────────────────────
def lookup(d, k):
    if k not in d:
        raise NotFound(k)
    return d[k]

def validate(v):
    if v % 7 == 0:
        raise Invalid("bad %d" % v)
    return v

def deep(n):
    if n == 0:
        raise ValueError("bottom")
    return deep(n - 1)

def callers(n):
    d = {}
    for i in range(0, n, 2):
        d[i] = i * i
    hits = 0
    misses = 0
    invalid = 0
    finals = 0
    els = 0
    for k in range(n):
        try:
            hits += lookup(d, k) % 3
        except NotFound as e:
            misses += 1
        try:
            validate(k)
        except Invalid:
            invalid += 1
        except AppError:
            invalid += 100
        else:
            els += 1
        finally:
            finals += 1
    deepc = 0
    for i in range(20):
        try:
            deep(10)
        except ValueError as e:
            deepc += len(str(e))
    return [hits, misses, invalid, finals, els, deepc]

check("raised in callees, caught in the caller", callers(N), [16, 25, 8, 50, 42, 120])

class Box:
    def __init__(self, v):
        if v < 0:
            raise ValueError("negative %d" % v)
        self.v = v
    def get(self, k):
        if k > self.v:
            raise IndexError("too far")
        return k

def expression_contexts():
    out = []
    b = Box(3)
    def thrower(x):
        raise RuntimeError("t%d" % x)
    # every place a call can sit in a statement
    try:
        x = thrower(1)
    except RuntimeError as e:
        out.append(str(e))
    try:
        y = 0
        y += thrower(2) * 3
    except RuntimeError as e:
        out.append(str(e))
    try:
        z = 1 + thrower(3)
    except RuntimeError as e:
        out.append(str(e))
    try:
        if thrower(4):
            out.append("no")
    except RuntimeError as e:
        out.append(str(e))
    try:
        len([thrower(5)])
    except RuntimeError as e:
        out.append(str(e))
    try:
        b.get(10)
    except IndexError as e:
        out.append(str(e))
    try:
        w = b.get(1) + b.get(2) + b.get(99)
    except IndexError as e:
        out.append("chained " + str(e))
    try:
        Box(-1)
    except ValueError as e:
        out.append(str(e))
    try:
        abs(thrower(6))
    except RuntimeError as e:
        out.append(str(e))
    try:
        thrower(thrower(7))
    except RuntimeError as e:
        out.append(str(e))
    try:
        v = [1, 2][thrower(8)]
    except RuntimeError as e:
        out.append(str(e))
    try:
        not thrower(9)
    except RuntimeError as e:
        out.append(str(e))
    try:
        q = thrower(10) if True else 0
    except RuntimeError as e:
        out.append(str(e))
    try:
        r = (lambda: thrower(11))()
    except RuntimeError as e:
        out.append(str(e))
    return out

check("a raise reaching the caller from every expression context", expression_contexts(),
      ["t1", "t2", "t3", "t4", "t5", "too far", "chained too far", "negative -1",
       "t6", "t7", "t8", "t9", "t10", "t11"])

def side_effects():
    # nothing after the failing call runs: not the rest of the expression,
    # not the store, not the next statement
    log = []
    def bad():
        log.append("bad")
        raise ValueError("v")
    def good(x):
        log.append("good %d" % x)
        return x
    target = "untouched"
    try:
        target = good(1) + bad() + good(2)
        log.append("after")
    except ValueError:
        log.append("caught")
    try:
        good(3)
        bad()
        good(4)
    except ValueError:
        log.append("caught2")
    total = 10
    try:
        total += bad()
    except ValueError:
        log.append("caught3")
    return [log, target, total]

check("nothing runs after the failing call", side_effects(),
      [["good 1", "bad", "caught", "good 3", "bad", "caught2", "bad", "caught3"], "untouched", 10])

def returns_value_after_catch(n):
    if n == 0:
        try:
            raise KeyError(n)
        except KeyError:
            return "caught at 0"
    return returns_value_after_catch(n - 1)

check("a caught exception, then a return through callers", returns_value_after_catch(5), "caught at 0")

def uncaught_in_caller():
    def a():
        raise TypeError("from a")
    def b():
        a()
        return "never"
    def c():
        r = b()
        return r
    try:
        c()
    except TypeError as e:
        return ["caught", str(e), [f for f, s in chain(e)]]

check("an exception through three frames: traceback functions", uncaught_in_caller(),
      ["caught", "from a", ["uncaught_in_caller", "c", "b", "a"]])

# ── 3. runtime errors the evaluator raises ──────────────────────────────────
def runtime_errors(n):
    d = {"a": 1}
    xs = [1, 2, 3]
    out = {"key": 0, "index": 0, "zero": 0, "attr": 0, "value": 0, "stop": 0, "type": 0}
    for i in range(n):
        try:
            d["missing%d" % (i % 3)]
        except KeyError as e:
            out["key"] += 1
            last_key = e.args
        try:
            xs[i % 5]
        except IndexError as e:
            out["index"] += 1
            last_index = str(e)
        try:
            i // (i % 2)
        except ZeroDivisionError as e:
            out["zero"] += 1
            last_zero = str(e)
        try:
            i.nosuch
        except AttributeError as e:
            out["attr"] += 1
            last_attr = str(e)
        try:
            int("x%d" % i)
        except ValueError as e:
            out["value"] += 1
            last_value = str(e)
        try:
            next(iter([]))
        except StopIteration as e:
            out["stop"] += 1
        try:
            5 - "a"
        except TypeError as e:
            out["type"] += 1
            last_type = str(e)
    return [out, last_key, last_index, last_zero, last_attr, last_value, last_type]

check("runtime errors caught in the same function", runtime_errors(N),
      [{"key": 50, "index": 20, "zero": 25, "attr": 50, "value": 50, "stop": 50, "type": 50},
       ("missing1",), "list index out of range", "integer division or modulo by zero",
       "'int' object has no attribute 'nosuch'", "invalid literal for int() with base 10: 'x49'",
       "unsupported operand type(s) for -: 'int' and 'str'"])

def get_key(d, k):
    return d[k]

def get_index(xs, i):
    return xs[i]

def divide(a, b):
    return a / b

def runtime_errors_in_callee():
    out = []
    eafp = 0
    d = {}
    for i in range(0, 20, 2):
        d[i] = i
    for k in range(30):
        try:
            eafp += get_key(d, k % 25)
        except KeyError as e:
            eafp -= 1
            out.append(e.args[0]) if k < 6 else None
    try:
        get_index([1], 5)
    except IndexError as e:
        out.append(str(e))
    try:
        divide(1, 0)
    except ZeroDivisionError as e:
        out.append(str(e))
    try:
        eafp += {}["x"]
    except KeyError as e:
        out.append(repr(e))
    return [eafp, out]

check("runtime errors raised in a callee", runtime_errors_in_callee(),
      [79, [1, 3, 5, "list index out of range", "division by zero", "KeyError('x')"]])

def dict_subclass_missing():
    class D(dict):
        def __missing__(self, k):
            return "m-" + str(k)
    d = D()
    d["a"] = 1
    out = [d["a"], d["b"]]
    try:
        out.append({}["c"])
    except KeyError as e:
        out.append(str(e))
    return out

check("a dict subclass's __missing__ is not a KeyError", dict_subclass_missing(), [1, "m-b", "'c'"])

# ── 4. through builtins that call back into Nython code ─────────────────────
def keyfn(x):
    if x == 3:
        raise ValueError("key %d" % x)
    return -x

def through_builtins():
    out = []
    try:
        sorted([1, 2, 3, 4], key=keyfn)
    except ValueError as e:
        out.append("sorted " + str(e))
    try:
        list(map(keyfn, [1, 2, 3]))
    except ValueError as e:
        out.append("map " + str(e))
    try:
        list(filter(keyfn, [3]))
    except ValueError as e:
        out.append("filter " + str(e))
    try:
        min([5, 3, 1], key=keyfn)
    except ValueError as e:
        out.append("min " + str(e))
    try:
        all(keyfn(x) for x in [1, 2, 3])
    except ValueError as e:
        out.append("all " + str(e))
    try:
        [keyfn(x) for x in range(5)]
    except ValueError as e:
        out.append("listcomp " + str(e))
    out.append(sorted([4, 1, 2], key=keyfn))
    return out

check("exceptions through builtin callbacks", through_builtins(),
      ["sorted key 3", "map key 3", "filter key 3", "min key 3", "all key 3", "listcomp key 3", [4, 2, 1]])

def callback_catches():
    # the callback catches its own exception: the builtin goes on
    def safe(x):
        try:
            if x % 2:
                raise ValueError(x)
            return x
        except ValueError:
            return -x
    return [list(map(safe, range(6))), sorted(range(5), key=safe)]

check("a callback catches its own exception", callback_catches(),
      [[0, -1, 2, -3, 4, -5], [3, 1, 0, 2, 4]])

# ── 5. finally and with: ordering, suppression ──────────────────────────────
class CM:
    def __init__(self, log, name, suppress):
        self.log = log
        self.name = name
        self.suppress = suppress
    def __enter__(self):
        self.log.append("enter " + self.name)
        return self
    def __exit__(self, t, v, tb):
        self.log.append("exit " + self.name + " " + (t.__name__ if t is not None else "None") + " " + (str(v) if v is not None else "-"))
        return self.suppress

def raiser(msg):
    raise ValueError(msg)

def with_ordering():
    log = []
    with CM(log, "a", True):
        log.append("body a")
        raise ValueError("in a")
    log.append("after a")
    with CM(log, "b", True):
        raiser("in b")
        log.append("not reached")
    try:
        with CM(log, "c", False):
            with CM(log, "d", False):
                raiser("in d")
    except ValueError as e:
        log.append("caught " + str(e))
    try:
        with CM(log, "e", False):
            try:
                raiser("in e")
            finally:
                log.append("finally e")
    except ValueError as e:
        log.append("caught " + str(e))
    for i in range(3):
        with CM(log, "loop%d" % i, True):
            if i == 1:
                continue
            raiser("l%d" % i)
    return log

check("with: __exit__ arguments, suppression, ordering", with_ordering(),
      ["enter a", "body a", "exit a ValueError in a", "after a",
       "enter b", "exit b ValueError in b",
       "enter c", "enter d", "exit d ValueError in d", "exit c ValueError in d", "caught in d",
       "enter e", "finally e", "exit e ValueError in e", "caught in e",
       "enter loop0", "exit loop0 ValueError l0", "enter loop1", "exit loop1 None -", "enter loop2", "exit loop2 ValueError l2"])

def finally_ordering():
    log = []
    def inner():
        try:
            log.append("inner try")
            raiser("x")
        finally:
            log.append("inner finally")
    def middle():
        try:
            inner()
        finally:
            log.append("middle finally")
    try:
        middle()
    except ValueError:
        log.append("outer except")
    finally:
        log.append("outer finally")
    return log

check("finally bodies run innermost first", finally_ordering(),
      ["inner try", "inner finally", "middle finally", "outer except", "outer finally"])

def finally_replaces():
    out = []
    def f1():
        try:
            raise ValueError("first")
        finally:
            raise KeyError("second")
    try:
        f1()
    except KeyError as e:
        out.append(["replaced", str(e)])
    def f2():
        try:
            raise ValueError("dropped")
        finally:
            return "finally returned"
    out.append(f2())
    def f3():
        for i in range(3):
            try:
                raise ValueError(i)
            finally:
                if i < 2:
                    continue
                break
        return "loop done %d" % i
    out.append(f3())
    def f4():
        try:
            return "body"
        finally:
            out.append("f4 finally")
    out.append(f4())
    return out

check("a finally that raises, returns or continues replaces the exception", finally_replaces(),
      [["replaced", "'second'"], "finally returned", "loop done 2", "f4 finally", "body"])

def handler_raises():
    out = []
    try:
        try:
            raise ValueError("orig")
        except ValueError:
            raise KeyError("handler")
    except KeyError as e:
        out.append([str(e), type(e.__context__).__name__, str(e.__context__), e.__suppress_context__])
    try:
        try:
            raise ValueError("orig2")
        except ValueError as v:
            raise KeyError("from") from v
    except KeyError as e:
        out.append([type(e.__cause__).__name__, str(e.__cause__), e.__suppress_context__])
    try:
        try:
            raise ValueError("orig3")
        except ValueError:
            raise KeyError("none") from None
    except KeyError as e:
        out.append([e.__cause__, e.__suppress_context__, type(e.__context__).__name__])
    try:
        try:
            {}["k"]
        except KeyError:
            [][0]
    except IndexError as e:
        out.append([type(e.__context__).__name__, str(e.__context__)])
    return out

check("__context__ and __cause__", handler_raises(),
      [["'handler'", "ValueError", "orig", False], ["ValueError", "orig2", True], [None, True, "ValueError"],
       ["KeyError", "'k'"]])

def reraise():
    out = []
    def f():
        try:
            raise ValueError("re")
        except ValueError:
            out.append("handled once")
            raise
    try:
        f()
    except ValueError as e:
        out.append(["reraised", str(e), [s for fn, s in chain(e)]])
    def g():
        try:
            raise KeyError("again")
        except KeyError as e:
            raise e
    try:
        g()
    except KeyError as e:
        out.append(str(e))
    return out

check("bare raise and raise e", reraise(),
      ["handled once", ["reraised", "re", ["f()", 'raise ValueError("re")']], "'again'"])

# ── 6. tracebacks ───────────────────────────────────────────────────────────
def tb_c(d):
    return d["nokey"]
def tb_b(d):
    x = tb_c(d) + 1
    return x
def tb_a():
    return tb_b({})

def tracebacks():
    out = []
    try:
        tb_a()
    except KeyError as e:
        out.append(chain(e))
    try:
        for i in range(2):
            try:
                tb_a()
            except KeyError as e:
                out.append(len(chain(e)))
                raise
    except KeyError as e:
        out.append(chain(e)[0])
    return out

check("traceback entries, frame by frame", tracebacks(),
      [[("tracebacks", "tb_a()"), ("tb_a", "return tb_b({})"), ("tb_b", "x = tb_c(d) + 1"), ("tb_c", 'return d["nokey"]')],
       4, ("tracebacks", "tb_a()")])

def tb_in_loop():
    lines = []
    for i in range(3):
        try:
            if i == 2:
                raise ValueError("loop")
        except ValueError as e:
            lines.append(chain(e))
    return lines

check("a traceback made in a loop", tb_in_loop(), [[("tb_in_loop", 'raise ValueError("loop")')]])

# ── 7. sys.settrace: exception events ───────────────────────────────────────
_events = []

def _tracer(frame, event, arg):
    name = frame.f_code.co_name
    if not name.startswith("tr_"):
        return None
    if event == "exception":
        _events.append(("exception", name, arg[0].__name__, str(arg[1])))
    elif event == "return":
        _events.append(("return", name, arg))
    elif event == "call":
        _events.append(("call", name))
    return _tracer

def tr_inner(x):
    if x:
        raise ValueError("traced")
    return 1

def tr_outer():
    try:
        tr_inner(1)
    except ValueError:
        pass
    try:
        return tr_inner(1)
    finally:
        pass

def traced():
    del _events[:]
    sys.settrace(_tracer)
    try:
        tr_outer()
    except ValueError:
        pass
    finally:
        sys.settrace(None)
    return list(_events)

check("sys.settrace: exception and return events", traced(),
      [("call", "tr_outer"), ("call", "tr_inner"), ("exception", "tr_inner", "ValueError", "traced"), ("return", "tr_inner", None),
       ("exception", "tr_outer", "ValueError", "traced"),
       ("call", "tr_inner"), ("exception", "tr_inner", "ValueError", "traced"), ("return", "tr_inner", None),
       ("exception", "tr_outer", "ValueError", "traced"), ("return", "tr_outer", None)])

def after_trace():
    # the same functions untraced again: no events, same answers
    del _events[:]
    out = []
    for i in range(3):
        try:
            tr_inner(i % 2)
            out.append("ok")
        except ValueError:
            out.append("err")
    return [out, _events]

check("untraced again", after_trace(), [["ok", "err", "ok"], []])

# ── 8. loops: try inside, break and continue ────────────────────────────────
def loop_flow():
    log = []
    for i in range(6):
        try:
            if i == 1:
                continue
            if i == 4:
                break
            if i % 2 == 0:
                raise ValueError(i)
            log.append(("plain", i))
        except ValueError as e:
            log.append(("caught", e.args[0]))
            if i == 2:
                continue
        finally:
            log.append(("finally", i))
        log.append(("end", i))
    n = 0
    while True:
        n += 1
        try:
            if n > 3:
                raise StopIteration
        except StopIteration:
            break
    log.append(("while", n))
    return log

check("try in loops with break and continue", loop_flow(),
      [("caught", 0), ("finally", 0), ("end", 0), ("finally", 1), ("caught", 2), ("finally", 2),
       ("plain", 3), ("finally", 3), ("end", 3), ("finally", 4), ("while", 4)])

def nested_try_loops():
    total = 0
    for i in range(10):
        for j in range(10):
            try:
                try:
                    if (i + j) % 4 == 0:
                        raise KeyError(j)
                    total += 1
                except IndexError:
                    total += 1000
            except KeyError:
                if j > 7:
                    break
                total += 100
    return total

check("nested try in nested loops", nested_try_loops(), 2072)

# ── 9. generators ───────────────────────────────────────────────────────────
def gen_raises(n):
    for i in range(n):
        if i == 2:
            raise ValueError("gen %d" % i)
        yield i

def gen_catches():
    for i in range(4):
        try:
            if i % 2:
                raise KeyError(i)
            yield ("ok", i)
        except KeyError as e:
            yield ("caught", e.args[0])

def gen_finally(log):
    try:
        yield 1
        yield 2
    finally:
        log.append("gen finally")

def generators():
    out = []
    got = []
    try:
        for v in gen_raises(5):
            got.append(v)
    except ValueError as e:
        out.append([got, str(e)])
    out.append(list(gen_catches()))
    log = []
    g = gen_finally(log)
    out.append(next(g))
    g.close()
    out.append(log)
    def thrown():
        try:
            yield 1
        except ValueError as e:
            yield "thrown " + str(e)
    g2 = thrown()
    next(g2)
    out.append(g2.throw(ValueError("in")))
    def stop_in_gen():
        yield 1
        raise StopIteration
    try:
        list(stop_in_gen())
    except RuntimeError as e:
        out.append(str(e))
    log2 = []
    for v in gen_finally(log2):
        if v == 1:
            break
    out.append(log2)
    return out

check("exceptions in generators", generators(),
      [[[0, 1], "gen 2"], [("ok", 0), ("caught", 1), ("ok", 2), ("caught", 3)], 1, ["gen finally"],
       "thrown in", "generator raised StopIteration", ["gen finally"]])

# ── 10. threads ─────────────────────────────────────────────────────────────
def thread_work(res, k):
    total = 0
    for i in range(200):
        try:
            if i % k == 0:
                raise ValueError(i)
            total += 1
        except ValueError:
            total -= 1
    try:
        deep(5)
    except ValueError as e:
        total += 1000
    res.append(total)

def threads():
    res = []
    ts = [threading.Thread(target=thread_work, args=(res, k)) for k in (2, 3, 5, 7)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return sorted(res)

check("exceptions raised and caught in threads", threads(), [1000, 1066, 1120, 1142])

# ── 11. exception groups ────────────────────────────────────────────────────
def groups():
    out = []
    def raise_group():
        raise ExceptionGroup("eg", [ValueError("v1"), KeyError("k1"), ValueError("v2")])
    try:
        raise_group()
    except* ValueError as eg:
        out.append(sorted(str(x) for x in eg.exceptions))
    except* KeyError as eg:
        out.append([repr(x) for x in eg.exceptions])
    try:
        try:
            raise_group()
        except* ValueError:
            out.append("values handled")
    except ExceptionGroup as rest:
        out.append([type(x).__name__ for x in rest.exceptions])
    return out

check("except* over an exception group raised in a callee", groups(),
      [["v1", "v2"], ["KeyError('k1')"], "values handled", ["KeyError"]])

# ── 12. module level and lambdas (the thrown path) ──────────────────────────
mod_log = []
for i in range(4):
    try:
        if i % 2:
            raise ValueError(i)
        mod_log.append(i)
    except ValueError as e:
        mod_log.append(-e.args[0])
try:
    lookup({}, "m")
except NotFound as e:
    mod_log.append(e.key)
check("module-level try", mod_log, [0, -1, 2, -3, "m"])

def lambdas():
    f = lambda d, k: d[k]
    out = []
    for k in ["a", "b"]:
        try:
            out.append(f({"a": 1}, k))
        except KeyError as e:
            out.append(str(e))
    return out

check("a lambda raising", lambdas(), [1, "'b'"])

def recursion():
    def r(n):
        return r(n + 1)
    try:
        r(0)
    except RecursionError:
        return "recursion caught"

check("RecursionError caught", recursion(), "recursion caught")

def class_body_raise():
    try:
        class K:
            x = 1
            raise ValueError("in class body")
    except ValueError as e:
        return str(e)

check("raised in a class body", class_body_raise(), "in class body")

def assert_fails():
    out = []
    for i in range(3):
        try:
            assert i != 1, "i is %d" % i
            out.append(i)
        except AssertionError as e:
            out.append(str(e))
    return out

check("assert", assert_fails(), [0, "i is 1", 2])

def try_else_return():
    out = []
    def f(x):
        try:
            if x:
                raise ValueError(x)
        except ValueError:
            return "except"
        else:
            return "else"
        finally:
            out.append("finally %s" % x)
    out.append(f(0))
    out.append(f(1))
    return out

check("try/except/else/finally with returns", try_else_return(),
      ["finally 0", "else", "finally 1", "except"])

def while_condition_raises():
    n = [0]
    def cond():
        n[0] += 1
        if n[0] > 3:
            raise KeyError("cond")
        return True
    try:
        while cond():
            pass
    except KeyError as e:
        return [n[0], str(e)]

check("a while condition raising", while_condition_raises(), [4, "'cond'"])

def exc_info_in_handler():
    try:
        raise ValueError("info")
    except ValueError:
        t, v, tb = sys.exc_info()
        return [t.__name__, str(v), tb is not None, sys.exc_info()[0] is ValueError]

check("sys.exc_info in a handler", exc_info_in_handler(), ["ValueError", "info", True, True])

def exc_after_handler():
    try:
        raise ValueError("gone")
    except ValueError:
        pass
    return sys.exc_info()

check("sys.exc_info after the handler", exc_after_handler(), (None, None, None))

# ── 13. loop targets: tuples not made ───────────────────────────────────────
def loops_unpack():
    out = []
    xs = ["a", "b", "c"]
    out.append([(i, x) for i, x in enumerate(xs)])
    acc = []
    for i, x in enumerate(xs):
        acc.append(i * 10)
        acc.append(x)
    out.append(acc)
    acc = []
    for i, x in enumerate(xs, 5):
        acc.append((i, x))
    out.append(acc)
    acc = []
    for i, x in enumerate(xs, start=-1):
        acc.append((i, x))
    out.append(acc)
    acc = []
    for a, b in zip([1, 2, 3], "xyz"):
        acc.append((a, b))
    out.append(acc)
    acc = []
    for a, b, c in zip(range(3), [4, 5, 6, 7], (8, 9, 10)):
        acc.append(a + b + c)
    out.append(acc)
    acc = []
    for a, b in zip([1, 2], [3]):
        acc.append((a, b))
    out.append(acc)
    d = {"x": 1, "y": 2}
    acc = []
    for k, v in d.items():
        acc.append((k, v))
    out.append(acc)
    acc = []
    for k, v in [(1, 2), (3, 4)]:
        acc.append(k * v)
    out.append(acc)
    acc = []
    for k, v in [[1, 2], [3, 4]]:
        acc.append(k - v)
    out.append(acc)
    acc = []
    for a, b in ["ab", "cd"]:
        acc.append(b + a)
    out.append(acc)
    acc = []
    for a, b in ((x, x * x) for x in range(3)):
        acc.append(b - a)
    out.append(acc)
    acc = []
    for i, (a, b) in enumerate([(1, 2), (3, 4)]):
        acc.append(i + a * b)
    out.append(acc)
    acc = []
    for a, *rest in [(1, 2, 3), (4,)]:
        acc.append((a, rest))
    out.append(acc)
    acc = []
    for (a, b), c in zip([(1, 2), (3, 4)], "pq"):
        acc.append((a, b, c))
    out.append(acc)
    acc = []
    for i, x in enumerate(gen_raises(2)):
        acc.append((i, x))
    out.append(acc)
    acc = []
    for i, (k, v) in enumerate(sorted(d.items())):
        acc.append((i, k, v))
    out.append(acc)
    return out

check("loop targets over enumerate, zip, items and others", loops_unpack(),
      [[(0, "a"), (1, "b"), (2, "c")], [0, "a", 10, "b", 20, "c"], [(5, "a"), (6, "b"), (7, "c")],
       [(-1, "a"), (0, "b"), (1, "c")], [(1, "x"), (2, "y"), (3, "z")], [12, 15, 18], [(1, 3)],
       [("x", 1), ("y", 2)], [2, 12], [-1, -1], ["ba", "dc"], [0, 0, 2], [2, 13], [(1, [2, 3]), (4, [])],
       [(1, 2, "p"), (3, 4, "q")], [(0, 0), (1, 1)], [(0, "x", 1), (1, "y", 2)]])

def loops_unpack_flow():
    out = []
    last = None
    for i, x in enumerate("abcdef"):
        if i == 1:
            continue
        if x == "e":
            break
        last = (i, x)
    out.append([last, i, x])
    for a, b in zip([1], [2]):
        pass
    else:
        out.append(["else", a, b])
    for a, b in zip([], []):
        out.append("never")
    else:
        out.append("empty else")
    def find(pairs, want):
        for k, v in pairs:
            if v == want:
                return k
        return None
    out.append([find(enumerate([5, 6, 7]), 7), find(zip("ab", [1, 2]), 1), find({"q": 9}.items(), 9), find(enumerate([]), 1)])
    return out

check("break, continue, else and return in unpacking loops", loops_unpack_flow(),
      [[(3, "d"), 4, "e"], ["else", 1, 2], "empty else", [2, "a", "q", None]])

def loops_unpack_errors():
    out = []
    try:
        for a, b in [(1, 2, 3)]:
            out.append("no")
    except ValueError as e:
        out.append(str(e))
    try:
        for a, b, c in [(1, 2)]:
            out.append("no")
    except ValueError as e:
        out.append(str(e))
    try:
        for a, b in [5]:
            out.append("no")
    except TypeError as e:
        out.append("TypeError")
    try:
        for a, b, c in zip([1], [2]):
            out.append("no")
    except ValueError as e:
        out.append(str(e))
    try:
        for a, b in enumerate([(1, 2)], 0):
            out.append((a, b))
        for a, b, c in enumerate([1]):
            out.append("no")
    except ValueError as e:
        out.append(str(e))
    try:
        for a, b in zip([1, 2], [3, 4], strict=True):
            out.append(a + b)
        for a, b in zip([1, 2], [3], strict=True):
            out.append(a + b)
    except ValueError as e:
        out.append(str(e))
    return out

check("unpacking counts checked", loops_unpack_errors(),
      ["too many values to unpack (expected 2)", "not enough values to unpack (expected 3, got 2)", "TypeError",
       "not enough values to unpack (expected 3, got 2)", (0, (1, 2)), "not enough values to unpack (expected 3, got 2)",
       4, 6, 4, "zip() argument 2 is shorter than argument 1"])

def loop_vars_scope():
    # the targets are the function's locals, rebinding globals declared so
    global gk, gv
    for gk, gv in enumerate([7, 8]):
        pass
    total = 0
    for i, v in enumerate(range(100)):
        total += i * v
    return [gk, gv, total]

check("loop targets declared global", loop_vars_scope(), [1, 8, 328350])

def zip_mutation():
    xs = [1, 2, 3]
    out = []
    for i, x in enumerate(xs):
        if i == 0:
            xs.append(4)
        out.append(x)
    d = {"a": 1}
    try:
        for k, v in d.items():
            d["b"] = 2
    except RuntimeError as e:
        out.append(str(e))
    return out

check("a list growing under enumerate; a dict changing size under items", zip_mutation(),
      [1, 2, 3, 4, "dictionary changed size during iteration"])

class Pair:
    def __init__(self, a, b):
        self.a = a
        self.b = b
    def __iter__(self):
        return iter([self.a, self.b])

def unpack_objects():
    out = []
    for i, (a, b) in enumerate([Pair(1, 2), Pair(3, 4)]):
        out.append(i + a + b)
    for a, b in [Pair(5, 6)]:
        out.append(a * b)
    for p, q in zip([Pair(7, 8)], [9]):
        a, b = p
        out.append(a + b + q)
    return out

check("objects unpacked as loop targets", unpack_objects(), [3, 8, 30, 24])

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT103 PASSED ===")
