# vm_audit52.ny - exceptions and control flow, identical on both engines.
#
#   Python's semantics: an exception no clause matches goes on to the
#   enclosing handler after `finally` has run; a bare `raise` re-raises the
#   exception being handled; `finally` runs on return/break/continue and when
#   an except body raises; runtime errors are instances of the builtin
#   classes (ZeroDivisionError is an ArithmeticError, KeyError a
#   LookupError); exceptions keep their type across function frames; `with`
#   hands __exit__ the real exception and a true result suppresses it.
#   Every expected value is what python3 gives for the same code.
#
#     ./build/nython-cli examples/vm_audit52.ny
#     ./build/nython-cli --vm examples/vm_audit52.ny

var pass_n = 0
var fail_n = 0

def check(name, got, want):
    global pass_n, fail_n
    if got == want:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + name + ": got " + str(got) + " want " + str(want))

# ── an unmatched except passes the exception on ─────────────────────────────
def unmatched():
    try:
        try:
            raise KeyError("k")
        except ValueError:
            return "inner"
    except KeyError:
        return "outer"
    return "none"
check("unmatched except reaches the outer handler", unmatched(), "outer")

# ── finally runs, then the exception continues ──────────────────────────────
var log = []
def fin_then_raise():
    try:
        raise ValueError("x")
    finally:
        log.append("cleanup")
def call_fin():
    try:
        fin_then_raise()
        return "no error"
    except ValueError as e:
        return "caught " + str(e)
check("finally then propagate", call_fin(), "caught x")
check("finally ran", log, ["cleanup"])

# ── bare raise re-raises the exception being handled ────────────────────────
def reraise():
    try:
        try:
            raise TypeError("orig")
        except TypeError:
            raise
    except TypeError as e:
        return "re-raised " + str(e)
check("bare raise", reraise(), "re-raised orig")

# ── finally runs when an except body raises ─────────────────────────────────
var log2 = []
def except_body_raises():
    try:
        try:
            raise ValueError("a")
        except ValueError:
            raise IndexError("b")
        finally:
            log2.append("fin")
    except IndexError as e:
        log2.append("outer " + str(e))
except_body_raises()
check("finally after a raising except body", log2, ["fin", "outer b"])

# ── typed except across function frames ─────────────────────────────────────
def deep():
    raise ValueError("deep")
def middle():
    return deep()
def top_level():
    try:
        middle()
    except ValueError as e:
        return "caught " + str(e)
    return "missed"
check("ValueError from two frames down", top_level(), "caught deep")

def div0():
    try:
        return 1 / 0
    except ZeroDivisionError:
        return "zde"
check("runtime ZeroDivisionError is typed", div0(), "zde")

def arith():
    try:
        x = 10 % 0
    except ArithmeticError:
        return "arith"
    return "missed"
check("ArithmeticError catches ZeroDivisionError", arith(), "arith")

def lookup():
    try:
        raise KeyError("k")
    except LookupError:
        return "lookup"
check("LookupError catches KeyError", lookup(), "lookup")

def not_caught_by_sibling():
    try:
        try:
            raise KeyError("k")
        except IndexError:
            return "wrong"
    except Exception as e:
        return "exception"
check("IndexError does not catch KeyError", not_caught_by_sibling(), "exception")

# ── assert, str(e), args ────────────────────────────────────────────────────
def asserting():
    try:
        assert 1 == 2, "one is not two"
    except AssertionError as e:
        return str(e)
check("assert raises AssertionError with its message", asserting(), "one is not two")

def message():
    try:
        raise ValueError("the message")
    except ValueError as e:
        return str(e)
check("str(e) is the message", message(), "the message")

# ── user exception classes ──────────────────────────────────────────────────
class AppError(Exception):
    pass
class NotFound(AppError):
    def __init__(self, what):
        super().__init__("not found: " + what)
        self.what = what

def custom():
    try:
        raise NotFound("page")
    except AppError as e:
        return [str(e), e.what, e.args[0], isinstance(e, Exception), isinstance(e, NotFound)]
check("user exception hierarchy", custom(), ["not found: page", "page", "not found: page", true, true])
check("constructing an Exception subclass", str(AppError("x")), "x")

def raise_class():
    try:
        raise AppError
    except AppError as e:
        return isinstance(e, AppError)
check("raise of a class instantiates it", raise_class(), true)

# ── except (A, B) as e; raise X from Y ──────────────────────────────────────
def tuple_clause(k):
    try:
        if k == 0:
            raise KeyError("k")
        raise ValueError("v")
    except (KeyError, ValueError) as e:
        return type(e).__name__
check("except tuple, first type", tuple_clause(0), "KeyError")
check("except tuple, second type", tuple_clause(1), "ValueError")

def chained():
    try:
        try:
            raise KeyError("low")
        except KeyError as low:
            raise ValueError("high") from low
    except ValueError as e:
        return [str(e), type(e.__cause__).__name__]
check("raise from sets __cause__", chained(), ["high", "KeyError"])

# ── try / else ──────────────────────────────────────────────────────────────
def with_else(fail):
    var out = []
    try:
        if fail:
            raise ValueError("x")
        out.append("body")
    except ValueError:
        out.append("except")
    else:
        out.append("else")
    finally:
        out.append("finally")
    return out
check("try/else without an error", with_else(false), ["body", "else", "finally"])
check("try/else with an error", with_else(true), ["except", "finally"])

# ── finally on return / break / continue ────────────────────────────────────
var flog = []
def ret_in_try():
    try:
        return "value"
    finally:
        flog.append("ret")
check("return through finally", ret_in_try(), "value")
for i in range(3):
    try:
        if i == 0:
            continue
        if i == 2:
            break
        flog.append("body" + str(i))
    finally:
        flog.append("f" + str(i))
check("finally on continue and break", flog, ["ret", "f0", "body1", "f1", "f2"])

def finally_overrides():
    try:
        return "try"
    finally:
        return "finally"
check("return in finally wins", finally_overrides(), "finally")

# ── with: __exit__(type, value, tb) and suppression ─────────────────────────
class Manager:
    def __init__(self, suppress):
        self.suppress = suppress
        self.seen = []
    def __enter__(self):
        self.seen.append("enter")
        return self
    def __exit__(self, t, v, tb):
        if t == none:
            self.seen.append("exit clean")
        else:
            self.seen.append("exit " + t.__name__ + " " + str(v))
        return self.suppress

var m1 = Manager(false)
with m1 as mm:
    mm.seen.append("body")
check("with, no exception", m1.seen, ["enter", "body", "exit clean"])

var m2 = Manager(true)
with m2:
    raise ValueError("boom")
check("a true __exit__ suppresses", m2.seen, ["enter", "exit ValueError boom"])

def with_propagates():
    var m3 = Manager(false)
    try:
        with m3:
            raise IndexError("k")
    except IndexError:
        return m3.seen
check("a false __exit__ lets it go on", with_propagates(), ["enter", "exit IndexError k"])

def with_return():
    var m4 = Manager(false)
    with m4:
        return m4
check("return inside with runs __exit__", with_return().seen, ["enter", "exit clean"])

# ── switch default runs ─────────────────────────────────────────────────────
def sw(n):
    var r = "?"
    switch n:
        case 1:
            r = "one"
        default:
            r = "other"
    return r
check("switch case", sw(1), "one")
check("switch default", sw(9), "other")

# ── walrus and while (a) < n ────────────────────────────────────────────────
var L = [1, 2, 3]
var walrus_seen = none
if (n := len(L)) > 2:
    walrus_seen = n
check("walrus in a condition", walrus_seen, 3)
var chunks = []
var src = [4, 5, 6]
while (k := len(src)) > 0:
    chunks.append(k)
    src.pop()
check("walrus in while", chunks, [3, 2, 1])
var a = 0
while (a) < 3:
    a = a + 1
check("parenthesised while condition", a, 3)

# ── `not in` after the right operand raised ─────────────────────────────────
class BadContainer:
    def __contains__(self, x):
        raise ValueError("x")
def not_in(o):
    try:
        return 1 not in o
    except ValueError:
        return "err"
check("not in: raising __contains__", not_in(BadContainer()), "err")
check("not in: still not in afterwards", not_in([2]), true)
check("not in: false case", not_in([1]), false)

# ── top-level except as ─────────────────────────────────────────────────────
var top_msg = ""
try:
    raise ValueError("top")
except ValueError as e:
    top_msg = str(e)
check("top-level except as", top_msg, "top")

print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT52 PASSED ===")
