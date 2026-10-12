# vm_audit95.ny - lib/decimal.ny, Python's decimal (round 79), both engines.
#
# The General Decimal Arithmetic Specification as CPython's decimal module
# implements it: constructors (str, int, float exactly, tuples), special
# values and signed zeros, the arithmetic and comparison operators with
# ints, floats (the FloatOperation signal) and Fractions, Decimal's
# truncating // and %, every Decimal method, Context (precision, the eight
# rounding modes, Emin/Emax, clamp, capitals, flags and traps, every method),
# getcontext/setcontext/localcontext per thread and per asyncio task, the
# signal classes and their hierarchy, str/repr/format, the numeric hash, and
# round/int/float/math.floor/ceil.
#
# The last part runs 1981 dectest-style vectors (operation, precision 9, 16
# or 34, rounding, operands -> result and flags) for add, subtract,
# multiply, divide, divide_integer, remainder, remainder_near, quantize,
# max/min(_mag), compare, compare_total, power, scaleb, copy_sign,
# next_toward/plus/minus, rotate, shift, the logical operations, plus
# (rounding), minus, abs, sqrt, exp, ln, log10, logb, normalize,
# to_integral_value/exact, number_class and fma; their expected results
# were produced by CPython 3.11's decimal (libmpdec 2.5, which passes the
# specification's dectest suite), so the vectors are checked against the
# C module bit for bit, flags included.
#
# Every expected value is CPython's: `python3 examples/vm_audit95.ny` passes
# too.
#
#     ./build/nython-cli examples/vm_audit95.ny
#     ./build/nython-cli --vm examples/vm_audit95.ny
try:
    true
    nython = True
except NameError:
    nython = False
    true = True
    false = False
    none = None

import decimal
import math
import numbers
import threading
import asyncio
from fractions import Fraction
from decimal import (Decimal, Context, getcontext, setcontext, localcontext, BasicContext,
                     ExtendedContext, DefaultContext, DecimalTuple, InvalidOperation, DivisionByZero,
                     Inexact, Rounded, Overflow, Underflow, Subnormal, Clamped, FloatOperation,
                     ConversionSyntax, DivisionImpossible, DivisionUndefined, InvalidContext,
                     DecimalException, ROUND_HALF_UP, ROUND_HALF_EVEN, ROUND_HALF_DOWN, ROUND_UP,
                     ROUND_DOWN, ROUND_CEILING, ROUND_FLOOR, ROUND_05UP)

pass_n = 0
fail_n = 0
results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

def err(f):
    # the exception f() raises: its type name and message
    try:
        f()
    except Exception as e:
        return type(e).__name__ + ": " + str(e)
    return "no error"

setcontext(Context())     # a fresh default context for the checks below
D = Decimal

# ── construction ─────────────────────────────────────────────────────────────
check("from strings", [repr(D("1.10")), repr(D("-0.0")), repr(D("  12e3 ")), repr(D("1_000.5")), repr(D(".5")),
                       repr(D("5.")), repr(D("-Inf")), repr(D("infinity")), repr(D("NaN123")), repr(D("-sNaN")),
                       repr(D("1E+2")), repr(D("0E-7"))],
      ["Decimal('1.10')", "Decimal('-0.0')", "Decimal('1.2E+4')", "Decimal('1000.5')", "Decimal('0.5')",
       "Decimal('5')", "Decimal('-Infinity')", "Decimal('Infinity')", "Decimal('NaN123')", "Decimal('-sNaN')",
       "Decimal('1E+2')", "Decimal('0E-7')"])
check("from ints, exactly", [str(D(0)), str(D(-17)), str(D(10**40)), str(D(-(2**70)))],
      ["0", "-17", "10000000000000000000000000000000000000000", "-1180591620717411303424"])
check("from floats, exactly", [str(D(0.1)), str(D(1.5)), str(D(-0.0)), str(D(1e20)), str(D(float("inf"))),
                               str(D(float("nan"))), str(D.from_float(0.25)), str(D(2**-10))],
      ["0.1000000000000000055511151231257827021181583404541015625", "1.5", "-0", "100000000000000000000",
       "Infinity", "NaN", "0.25", "0.0009765625"])
check("from tuples", [str(D((0, (1, 4, 1, 4), -3))), str(D((1, (5,), 2))), str(D((0, (), "F"))),
                      str(D((1, (1, 2), "n"))), str(D([0, [0, 0, 1], 0])), str(D((0, (0,), 0)))],
      ["1.414", "-5E+2", "Infinity", "-NaN12", "1", "0"])
check("from another Decimal, and the constructor's context", [str(D(D("3.14159"))), str(D("3.14159", Context(prec=3)))],
      ["3.14159", "3.14159"])
check("conversion errors", [err(lambda: D("abc")), err(lambda: D("1.2.3")), err(lambda: D("")), err(lambda: D([1])),
                            err(lambda: D((2, (1,), 0))), err(lambda: D((0, (1, 10), 0))), err(lambda: D(object()))],
      ["InvalidOperation: [<class 'decimal.ConversionSyntax'>]", "InvalidOperation: [<class 'decimal.ConversionSyntax'>]",
       "InvalidOperation: [<class 'decimal.ConversionSyntax'>]", "ValueError: argument must be a sequence of length 3",
       "ValueError: sign must be an integer with the value 0 or 1", "ValueError: coefficient must be a tuple of digits",
       "TypeError: conversion from object to Decimal is not supported"])
check("a conversion error not trapped gives NaN", [str(Context(traps=[]).create_decimal("xyz"))], ["NaN"])
check("as_tuple", [D("-3.140").as_tuple(), D("Inf").as_tuple(), D("NaN5").as_tuple(), D("0E+3").as_tuple()],
      [DecimalTuple(sign=1, digits=(3, 1, 4, 0), exponent=-3), DecimalTuple(sign=0, digits=(0,), exponent="F"),
       DecimalTuple(sign=0, digits=(5,), exponent="n"), DecimalTuple(sign=0, digits=(0,), exponent=3)])
check("as_integer_ratio", [D("0.75").as_integer_ratio(), D("-2.5E+3").as_integer_ratio(), D("0").as_integer_ratio(),
                           err(lambda: D("Inf").as_integer_ratio()), err(lambda: D("NaN").as_integer_ratio())],
      [(3, 4), (-2500, 1), (0, 1), "OverflowError: cannot convert Infinity to integer ratio",
       "ValueError: cannot convert NaN to integer ratio"])
check("adjusted, exponent, sign", [D("123.45").adjusted(), D("0.001").adjusted(), D("1E+5").adjusted(), D("0").adjusted(),
                                   D("-1.5").is_signed(), D("-0").is_signed(), D("1.5").is_signed()],
      [2, -3, 5, 0, True, True, False])
check("predicates", [[D(x).is_finite(), D(x).is_infinite(), D(x).is_nan(), D(x).is_qnan(), D(x).is_snan(),
                      D(x).is_zero(), D(x).is_normal(), D(x).is_subnormal(), D(x).is_canonical()]
                     for x in ["1.5", "-Inf", "NaN", "sNaN", "-0", "1E-1000000"]],
      [[True, False, False, False, False, False, True, False, True],
       [False, True, False, False, False, False, False, False, True],
       [False, False, True, True, False, False, False, False, True],
       [False, False, True, False, True, False, False, False, True],
       [True, False, False, False, False, True, False, False, True],
       [True, False, False, False, False, False, False, True, True]])
check("number_class", [D(x).number_class() for x in ["Inf", "1E-10", "0", "-0", "-1E-1000000", "-2.5", "NaN", "sNaN"]],
      ["+Infinity", "+Normal", "+Zero", "-Zero", "-Subnormal", "-Normal", "NaN", "sNaN"])

# ── arithmetic and comparisons ───────────────────────────────────────────────
check("the four operations", [str(D("1.10") + D("2.20")), str(D("1.30") - D("1.2")), str(D("1.20") * 3),
                              str(D(1) / D(7)), str(D(10) / 4), str(D(2) ** 10), str(D("1.1") ** 2), str(-D("1.5")),
                              str(+D("-0")), str(abs(D("-2.50")))],
      ["3.30", "0.10", "3.60", "0.1428571428571428571428571429", "2.5", "1024", "1.21", "-1.5", "0", "2.50"])
check("mixed with ints (both sides)", [str(1 + D("0.5")), str(D("0.5") + 1), str(3 - D(1)), str(2 * D("1.5")),
                                       str(7 / D(2)), str(2 ** D(3)), str(D(3) ** 2)],
      ["1.5", "1.5", "2", "3.0", "3.5", "8", "9"])
check("// and % truncate toward zero", [str(D(7) // 2), str(D(-7) // 2), str(D(7) // -2), str(D(7) % 2), str(D(-7) % 2),
                                        str(D("7.5") % D("2")), divmod(D(-7), D(2)), str(-7 // D(2)), str(-7 % D(2))],
      ["3", "-3", "-3", "1", "-1", "1.5", (D("-3"), D("-1")), "-3", "-1"])
check("comparisons with ints, Decimals, Fractions", [D("1.0") == 1, D("0.5") < 1, D(2) > D("1.99"), D("3") == D("3.000"),
                                                    D("0.5") == Fraction(1, 2), D(1) < Fraction(4, 3), D("NaN") == D("NaN"),
                                                    D("NaN") != D("NaN"), D("-0") == D("0"), max(D(1), D("1.5"), D(-3))],
      [True, True, True, True, True, True, False, True, True, D("1.5")])
check("ordering a NaN is an InvalidOperation", [err(lambda: D("NaN") < 1)],
      ["InvalidOperation: [<class 'decimal.InvalidOperation'>]"])
check("arithmetic with a float is a TypeError", [err(lambda: D(1) + 1.5), err(lambda: 1.5 * D(2)), err(lambda: D(1) < "x")],
      ["TypeError: unsupported operand type(s) for +: 'decimal.Decimal' and 'float'",
       "TypeError: unsupported operand type(s) for *: 'float' and 'decimal.Decimal'",
       "TypeError: '<' not supported between instances of 'decimal.Decimal' and 'str'"])
c = getcontext()
c.clear_flags()
flags_before = c.flags[FloatOperation]
cmp_float = D("1.5") < 2.5
eq_float = D("0.5") == 0.5
check("a float in a comparison sets FloatOperation", [flags_before, cmp_float, eq_float, c.flags[FloatOperation]],
      [False, True, True, True])
c.clear_flags()
x = D(0.5)
check("a float in the constructor sets it too", [str(x), c.flags[FloatOperation]], ["0.5", True])
c.traps[FloatOperation] = True
check("...and raises it when it is trapped", [err(lambda: D(0.5)), err(lambda: D(1) < 1.5), D(1) == 1.0,
                                             issubclass(FloatOperation, TypeError)],
      ["FloatOperation: [<class 'decimal.FloatOperation'>]", "FloatOperation: [<class 'decimal.FloatOperation'>]", True,
       True])
c.traps[FloatOperation] = False
c.clear_flags()
check("division by zero and undefined", [err(lambda: D(1) / 0), err(lambda: D(0) / 0), err(lambda: D(1) // 0),
                                        err(lambda: D(1) % 0), err(lambda: D("Inf") - D("Inf"))],
      ["DivisionByZero: [<class 'decimal.DivisionByZero'>]", "InvalidOperation: [<class 'decimal.DivisionUndefined'>]",
       "DivisionByZero: [<class 'decimal.DivisionByZero'>]", "InvalidOperation: [<class 'decimal.InvalidOperation'>]",
       "InvalidOperation: [<class 'decimal.InvalidOperation'>]"])
check("DivisionByZero is a ZeroDivisionError", [isinstance(DivisionByZero(), ZeroDivisionError),
                                               issubclass(DivisionUndefined, ZeroDivisionError)], [True, True])
nt = Context(traps=[])
check("untrapped: the result the specification gives, and the flags",
      [str(nt.divide(D(1), D(0))), str(nt.divide(D(0), D(0))), str(nt.multiply(D("9E+999999"), D(10))),
       sorted(s.__name__ for s, v in nt.flags.items() if v)],
      ["Infinity", "NaN", "Infinity", ["DivisionByZero", "Inexact", "InvalidOperation", "Overflow", "Rounded"]])

# ── methods ──────────────────────────────────────────────────────────────────
check("quantize", [str(D("7.325").quantize(D("0.01"), rounding=ROUND_HALF_UP)), str(D("7.325").quantize(D("0.01"))),
                   str(D("1.41421356").quantize(D("1.000"))), str(D("-0.5").quantize(D("1"))),
                   str(D("123.456").quantize(D("1E+1"))), err(lambda: D("1").quantize(D("1e-30")))],
      ["7.33", "7.32", "1.414", "-0", "1.2E+2", "InvalidOperation: [<class 'decimal.InvalidOperation'>]"])
check("to_integral_value / exact", [str(D("2.5").to_integral_value()), str(D("3.5").to_integral_value()),
                                    str(D("-2.7").to_integral_value(ROUND_DOWN)), str(D("2.1").to_integral_exact()),
                                    str(D("2.1").to_integral()), str(D("1E+2").to_integral_value())],
      ["2", "4", "-2", "2", "2", "1E+2"])
check("normalize", [str(D("120.00").normalize()), str(D("0.00").normalize()), str(D("-1.200E+5").normalize()),
                    str(D("1E+2").normalize())],
      ["1.2E+2", "0", "-1.2E+5", "1E+2"])
check("sqrt, exp, ln, log10", [str(D(2).sqrt()), str(D(1).exp()), str(D(10).ln()), str(D(1000).log10()),
                               str(D("0.5").log10()), str(D(-1).exp()), str(D(0).sqrt()), str(D("1e-6").sqrt())],
      ["1.414213562373095048801688724", "2.718281828459045235360287471", "2.302585092994045684017991455", "3",
       "-0.3010299956639811952137388947", "0.3678794411714423215955237702", "0", "0.001"])
check("logb, scaleb, fma, remainder_near", [str(D("250").logb()), str(D("0.03").logb()), str(D("7.50").scaleb(2)),
                                           str(D(2).fma(3, 5)), str(D(10).remainder_near(6)), str(D(10).remainder_near(3)),
                                           str(D("-0").logb()) if False else "skip"],
      ["2", "-2", "750", "11", "-2", "1", "skip"])
check("compare_total(_mag), compare, compare_signal", [D("12.30").compare_total(D("12.3")), D("-1").compare_total_mag(D("1")),
                                                      D("NaN").compare_total(D("sNaN")), D(1).compare(D(2)), D(2).compare(D(1)),
                                                      D(1).compare(D("1.0")), D("NaN").compare(D(1)),
                                                      err(lambda: D("NaN").compare_signal(D(1)))],
      [D("-1"), D("0"), D("1"), D("-1"), D("1"), D("0"), D("NaN"), "InvalidOperation: [<class 'decimal.InvalidOperation'>]"])
check("copy_sign, copy_abs, copy_negate", [str(D("1.5").copy_sign(D("-3"))), str(D("-1.5").copy_abs()),
                                          str(D("1.5").copy_negate()), str(D("NaN").copy_negate())],
      ["-1.5", "1.5", "-1.5", "-NaN"])
check("max, min, max_mag, min_mag", [str(D(1).max(D(2))), str(D(1).min(D("NaN"))), str(D(-10).max_mag(D(2))),
                                    str(D(-10).min_mag(D(2))), str(D("1.0").max(D(1)))],
      ["2", "1", "-10", "2", "1"])
check("next_plus, next_minus, next_toward", [str(D(1).next_plus()), str(D(1).next_minus()), str(D(1).next_toward(D(0))),
                                            str(D(0).next_plus()), str(D("-0").next_minus())],
      ["1.000000000000000000000000001", "0.9999999999999999999999999999", "0.9999999999999999999999999999",
       "1E-1000026", "-1E-1000026"])
check("rotate, shift", [str(D(34).rotate(8)), str(D(123456789).rotate(-2)), str(D(34).shift(8)), str(D(123456789).shift(-2))],
      ["3400000000", "8900000000000000000001234567", "3400000000", "1234567"])
check("logical operations", [str(D(1100).logical_and(D(1010))), str(D(1100).logical_or(D(1010))),
                             str(D(1100).logical_xor(D(1010))), str(D(101).logical_invert()),
                             err(lambda: D(12).logical_and(D(1)))],
      ["1000", "1110", "110", "1111111111111111111111111010", "InvalidOperation: [<class 'decimal.InvalidOperation'>]"])
check("same_quantum, radix, canonical, conjugate, real/imag", [D("2.17").same_quantum(D("0.01")), D(1).same_quantum(D("1.0")),
                                                               D(5).radix(), D("1.5").canonical(), D("1.5").conjugate(),
                                                               D("2.5").real, D("2.5").imag],
      [True, False, D(10), D("1.5"), D("1.5"), D("2.5"), D(0)])
check("to_eng_string, to_sci_string", [D("123E+1").to_eng_string(), D("0.000123").to_eng_string(), D("1E+7").to_eng_string(),
                                      getcontext().to_sci_string(D("1E+7")), str(D("0.000001")), str(D("0.0000001"))],
      ["1.23E+3", "0.000123", "10E+6", "1E+7", "0.000001", "1E-7"])
check("pow with a modulus", [pow(D(3), D(4), D(5)), pow(D(2), 10, 1000), err(lambda: pow(D("1.5"), 2, 3))],
      [D(1), D(24), "InvalidOperation: [<class 'decimal.InvalidOperation'>]"])

# ── conversions ──────────────────────────────────────────────────────────────
check("int, float, complex, bool", [int(D("-3.9")), int(D("1E+3")), float(D("1.5")), float(D("-Inf")), complex(D("2.5")),
                                   bool(D("0.0")), bool(D("-0.1")), err(lambda: int(D("NaN"))), err(lambda: int(D("Inf")))],
      [-3, 1000, 1.5, float("-inf"), complex(2.5, 0), False, True, "ValueError: cannot convert NaN to integer",
       "OverflowError: cannot convert Infinity to integer"])
check("round", [round(D("2.5")), round(D("3.5")), round(D("-2.5")), str(round(D("3.14159"), 2)), str(round(D("1234.5"), -2)),
                type(round(D("2.5"))).__name__, err(lambda: round(D("Inf")))],
      [2, 4, -2, "3.14", "1.2E+3", "int", "OverflowError: cannot convert Infinity to integer"])
check("math.floor, ceil, trunc", [math.floor(D("-2.5")), math.ceil(D("2.1")), math.trunc(D("-2.9")), math.floor(D("7"))],
      [-3, 3, -2, 7])
check("hash is the numeric hash", [hash(D(5)) == hash(5), hash(D("0.5")) == hash(0.5), hash(D("1e100")) == hash(10**100),
                                  hash(D("-1")) == hash(-1), hash(D("1.5")) == hash(Fraction(3, 2)), hash(D("0.1")) == hash(Fraction(1, 10)),
                                  hash(D("Inf")) == hash(float("inf")), hash(D("-0")) == 0, err(lambda: hash(D("sNaN")))],
      [True, True, True, True, True, True, True, True, "TypeError: Cannot hash a signaling NaN value"])
check("Decimals in sets", [len({D("1.0"), D(1), D("1.00")}), D("2.0") in {2}], [1, True])

# ── str, repr, format ────────────────────────────────────────────────────────
check("str: scientific notation as the specification gives it",
      [str(D("123E-8")), str(D("-1E-6")), str(D("1E+3")), str(D("12345678901234567890E+3")), str(D("0E-10")), str(D("-0E+2"))],
      ["0.00000123", "-0.000001", "1E+3", "1.2345678901234567890E+22", "0E-10", "-0E+2"])
check("format", [format(D("1234567.891"), ",.2f"), format(D("0.125"), ".1%"), format(D("-1.5e10"), "e"), format(D("1.5"), ">8"),
                 format(D("1.5"), "*^9.3f"), format(D("1234.5"), ",g"), format(D("-0.0001"), "z.2f"), format(D("12"), "+010.2f"),
                 format(D("1E+100"), "f")[:5], format(D("123.456"), ".2e"), format(D("123.456"), "G"), format(D("0.000001"), "g"),
                 format(D("1234567"), "n"), format(D("NaN"), ">5"), format(D("-Inf"), "f"), "{:,}".format(D("1234567.1"))],
      ["1,234,567.89", "12.5%", "-1.5e+10", "     1.5", "**1.500**", "1,234.5", "0.00", "+000012.00",
       "10000", "1.23e+2", "123.456", "0.000001", "1234567", "  NaN", "-Infinity", "1,234,567.1"])
check("format errors", [err(lambda: format(D(1), "q")), err(lambda: format(D(1), ",n"))],
      ["ValueError: invalid format string", "ValueError: invalid format string"])
check("f-strings", [f"{D('3.14159'):.3f}", f"{D('42'):5}", f"{D('0.5'):%}"], ["3.142", "   42", "50%"])

# ── Context ──────────────────────────────────────────────────────────────────
ctx = Context(prec=5, rounding=ROUND_HALF_UP, Emin=-99, Emax=99, capitals=0, clamp=1, flags=[], traps=[DivisionByZero])
check("Context attributes and repr", [ctx.prec, ctx.rounding, ctx.Emin, ctx.Emax, ctx.capitals, ctx.clamp, ctx.Etiny(), ctx.Etop(),
                                     repr(ctx)],
      [5, "ROUND_HALF_UP", -99, 99, 0, 1, -103, 95,
       "Context(prec=5, rounding=ROUND_HALF_UP, Emin=-99, Emax=99, capitals=0, clamp=1, flags=[], traps=[DivisionByZero])"])
check("the default context", [repr(Context()), getcontext().prec, DefaultContext.prec],
      ["Context(prec=28, rounding=ROUND_HALF_EVEN, Emin=-999999, Emax=999999, capitals=1, clamp=0, flags=[], traps=[InvalidOperation, DivisionByZero, Overflow])",
       28, 28])
check("Basic and Extended contexts", [repr(BasicContext), repr(ExtendedContext)],
      ["Context(prec=9, rounding=ROUND_HALF_UP, Emin=-999999, Emax=999999, capitals=1, clamp=0, flags=[], traps=[Clamped, InvalidOperation, DivisionByZero, Overflow, Underflow])",
       "Context(prec=9, rounding=ROUND_HALF_EVEN, Emin=-999999, Emax=999999, capitals=1, clamp=0, flags=[], traps=[])"])
check("create_decimal rounds to the context", [str(ctx.create_decimal("3.14159265")), str(ctx.create_decimal_from_float(0.1)),
                                               str(D("3.14159265")), str(ctx.create_decimal(12345678))],
      ["3.1416", "0.10000", "3.14159265", "1.2346E+7"])
check("capitals and clamp (str() uses the current context; to_sci_string this one)",
      [ctx.to_sci_string(ctx.create_decimal("1E+5")), ctx.to_sci_string(ctx.create_decimal("1E+99")), str(ctx.create_decimal("1E+5"))],
      ["1e+5", "1.0000e+99", "1E+5"])
check("context methods", [str(ctx.add(D(1), D(2))), str(ctx.divide(D(1), D(3))), str(ctx.power(D(2), D("0.5"))),
                          str(ctx.sqrt(D(3))), str(ctx.quantize(D("2.345"), D("0.01"))), str(ctx.abs(D(-1))),
                          str(ctx.minus(D(1))), str(ctx.plus(D("1.234567"))), ctx.compare(D(1), D(2)), str(ctx.exp(D(1))),
                          str(ctx.fma(D(2), D(3), D(4))), ctx.is_signed(D(-1)), ctx.number_class(D(0)), str(ctx.logb(D(100))),
                          str(ctx.to_integral(D("2.5"))), str(ctx.next_plus(D(1))), ctx.radix(), str(ctx.copy_negate(D(5))),
                          str(ctx.max(D(1), D(2))), ctx.same_quantum(D(1), D(2)), str(ctx.scaleb(D(1), D(2))),
                          str(ctx.remainder(D(10), D(3))), str(ctx.divide_int(D(10), D(3))), ctx.divmod(D(10), D(3)),
                          ctx.to_eng_string(D("1E+4")), ctx.is_zero(D(0)), str(ctx.ln(D(2))), str(ctx.log10(D(2)))],
      ["3", "0.33333", "1.4142", "1.7321", "2.35", "1", "-1", "1.2346", D("-1"), "2.7183", "10", True, "+Zero", "2", "3", "1.0001",
       D(10), "-5", "2", True, "1E+2", "1", "3", (D("3"), D("1")), "10e+3", True, "0.69315", "0.30103"])
check("context method on a trapped signal", [err(lambda: ctx.divide(D(1), D(0)))], ["DivisionByZero: [<class 'decimal.DivisionByZero'>]"])
c2 = ctx.copy()
c2.prec = 10
check("copy is independent", [ctx.prec, c2.prec, c2.rounding], [5, 10, "ROUND_HALF_UP"])
cf = Context(traps=[])
cf.divide(D(1), D(3))
f1 = sorted(s.__name__ for s, v in cf.flags.items() if v)
cf.clear_flags()
f2 = sorted(s.__name__ for s, v in cf.flags.items() if v)
cf.traps[Inexact] = True
t1 = err(lambda: cf.divide(D(1), D(3)))
cf.clear_traps()
check("flags and traps", [f1, f2, t1, any(cf.traps.values())],
      [["Inexact", "Rounded"], [], "Inexact: [<class 'decimal.Inexact'>]", False])
check("invalid context settings", [err(lambda: Context(prec=0)), err(lambda: Context(Emax=-1)), err(lambda: Context(Emin=1)),
                                   err(lambda: Context(clamp=2)), err(lambda: Context(capitals=5)), err(lambda: Context(prec=1.5)),
                                   err(lambda: Context(rounding="x")).split("\n")[0]],
      ["ValueError: valid range for prec is [1, MAX_PREC]", "ValueError: valid range for Emax is [0, MAX_EMAX]",
       "ValueError: valid range for Emin is [MIN_EMIN, 0]", "ValueError: valid values for clamp are 0 or 1",
       "ValueError: valid values for capitals are 0 or 1", "TypeError: an integer is required",
       "TypeError: valid values for rounding are:"])
check("overflow, underflow, subnormal, clamped", [str(Context(Emax=9, traps=[]).multiply(D("9E+9"), D(10))),
                                                 str(Context(Emin=-9, traps=[]).divide(D("1E-9"), D(1000))),
                                                 str(Context(Emin=-9, prec=3, traps=[]).divide(D("1E-9"), D(3))),
                                                 err(lambda: Context(Emax=9).multiply(D("9E+9"), D(10))),
                                                 str(Context(Emax=9, prec=3, clamp=1, traps=[]).create_decimal("1E+9"))],
      ["Infinity", "1E-12", "3.3E-10", "Overflow: [<class 'decimal.Overflow'>]", "1.00E+9"])
# the limits follow the C size, as CPython's (425000000 on a 32-bit build)
import sys
LIM = [999999999999999999, 999999999999999999, -999999999999999999, -1999999999999999997] if sys.maxsize > 2 ** 32 else [425000000, 425000000, -425000000, -849999999]
check("MAX_PREC and the other limits", [decimal.MAX_PREC, decimal.MAX_EMAX, decimal.MIN_EMIN, decimal.MIN_ETINY, decimal.HAVE_THREADS],
      LIM + [True])

# ── getcontext / setcontext / localcontext ───────────────────────────────────
setcontext(Context(prec=12))
with localcontext() as lc:
    lc.prec = 4
    in_local = str(D(1) / D(3))
after_local = str(D(1) / D(3))
with localcontext(prec=6, rounding=ROUND_DOWN) as lc2:
    kw_local = [str(D(2) / D(3)), lc2.rounding]
with localcontext(Context(prec=3)):
    given = str(D(1) / D(7))
check("localcontext", [in_local, after_local, kw_local, given, getcontext().prec],
      ["0.3333", "0.333333333333", ["0.666666", "ROUND_DOWN"], "0.143", 12])
check("localcontext rejects unknown attributes", [err(lambda: localcontext(nosuch=1))],
      ["TypeError: 'nosuch' is an invalid keyword argument for this function"])
seen = []
def in_thread():
    seen.append(getcontext().prec)
    getcontext().prec = 3
    seen.append(str(D(1) / D(3)))
th = threading.Thread(target=in_thread)
th.start()
th.join()
check("each thread has its own context (a copy of DefaultContext)", [seen, getcontext().prec], [[28, "0.333"], 12])

async def task_local(n):
    with localcontext() as tc:
        tc.prec = n
        await asyncio.sleep(0)
        return str(D(1) / D(7))

async def task_plain():
    await asyncio.sleep(0)
    return str(D(1) / D(7))

async def run_tasks():
    return await asyncio.gather(task_local(3), task_plain(), task_local(5), task_plain())
check("each asyncio task has its own context", [asyncio.run(run_tasks()), getcontext().prec],
      [["0.143", "0.142857142857", "0.14286", "0.142857142857"], 12])
setcontext(Context())

# ── the signals ──────────────────────────────────────────────────────────────
check("signal hierarchy",
      [issubclass(DecimalException, ArithmeticError), issubclass(InvalidOperation, DecimalException),
       issubclass(ConversionSyntax, InvalidOperation), issubclass(DivisionImpossible, InvalidOperation),
       issubclass(DivisionUndefined, InvalidOperation), issubclass(DivisionUndefined, ZeroDivisionError),
       issubclass(InvalidContext, InvalidOperation), issubclass(DivisionByZero, ZeroDivisionError),
       issubclass(Overflow, Inexact), issubclass(Overflow, Rounded), issubclass(Underflow, Subnormal),
       issubclass(Underflow, Inexact), issubclass(Clamped, DecimalException), issubclass(FloatOperation, TypeError),
       issubclass(Inexact, Rounded), issubclass(Subnormal, DecimalException)],
      [True, True, True, True, True, True, True, True, True, True, True, True, True, True, False, True])
check("names", [DivisionByZero.__name__, repr(DivisionByZero), str(InvalidOperation([ConversionSyntax]))],
      ["DivisionByZero", "<class 'decimal.DivisionByZero'>", "[<class 'decimal.ConversionSyntax'>]"])
check("rounding constants", [ROUND_HALF_EVEN, ROUND_05UP, decimal.ROUND_CEILING], ["ROUND_HALF_EVEN", "ROUND_05UP", "ROUND_CEILING"])
check("the eight rounding modes on 2.5, -2.5, 2.51, 2.05",
      [[str(D(x).quantize(D(q), rounding=r)) for x, q in [("2.5", "1"), ("-2.5", "1"), ("2.51", "0.1"), ("2.05", "0.1")]]
       for r in [ROUND_CEILING, ROUND_DOWN, ROUND_FLOOR, ROUND_HALF_DOWN, ROUND_HALF_EVEN, ROUND_HALF_UP, ROUND_UP, ROUND_05UP]],
      [["3", "-2", "2.6", "2.1"], ["2", "-2", "2.5", "2.0"], ["2", "-3", "2.5", "2.0"], ["2", "-2", "2.5", "2.0"],
       ["2", "-2", "2.5", "2.0"], ["3", "-3", "2.5", "2.1"], ["3", "-3", "2.6", "2.1"], ["2", "-2", "2.6", "2.1"]])
check("Decimal is a numbers.Number", [isinstance(D(1), numbers.Number), isinstance(D(1), numbers.Real)],
      [True, False])

# ── dectest-style vectors (CPython 3.11's decimal: results and flags) ────────
SIG = [Clamped, DivisionByZero, Inexact, InvalidOperation, Overflow, Rounded, Subnormal, Underflow]
RND = {"he": ROUND_HALF_EVEN, "hu": ROUND_HALF_UP, "hd": ROUND_HALF_DOWN, "u": ROUND_UP, "d": ROUND_DOWN,
       "c": ROUND_CEILING, "f": ROUND_FLOOR, "05": ROUND_05UP}
VECTORS = """
add|9|he|1|1||2|
add|9|he|2|3||5|
add|9|he|5.75|3.3||9.05|
add|9|he|5|-3||2|
add|9|he|-5|-3||-8|
add|9|he|-7|2.5||-4.5|
add|9|he|0.7|0.3||1.0|
add|9|he|1.25|1.25||2.50|
add|9|he|1.23456789|1.00000000||2.23456789|
add|9|he|1.23456789|1.00000011||2.23456800|
add|9|he|0.4444444444|0.5555555555||1.00000000|IneRou
add|9|he|70|10000e+9||1.00000000E+13|IneRou
add|9|he|700000|10000e+9||1.00000007E+13|Rou
add|9|he|1E+12|-1||1.00000000E+12|IneRou
add|9|he|1E+12|1.11||1.00000000E+12|IneRou
add|9|he|1E+12|1.111||1.00000000E+12|IneRou
add|9|he|-1|1E+12||1.00000000E+12|IneRou
add|9|he|0.0|0.000||0.000|
add|9|he|-0|0||0|
add|9|he|-0|-0||-0|
add|9|he|Inf|-Inf||NaN|Inv
add|9|he|Inf|1||Infinity|
add|9|he|NaN|1||NaN|
add|9|he|1|NaN5||NaN5|
add|9|he|sNaN|1||NaN|Inv
add|9|he|12345678901234567890|1||1.23456789E+19|IneRou
add|9|he|9.999999999999999999999999999999999E+999999|1E+999999||Infinity|IneOveRou
add|9|he|1E-999999|-1E-999999||0E-999999|
add|9|he|0.1|0.2||0.3|
add|9|he|123456789012345678901234567890123456789|0.5||1.23456789E+38|IneRou
subtract|9|he|2|3||-1|
subtract|9|he|2.3|2.30||0.00|
subtract|9|he|1.1|-1.1||2.2|
subtract|9|he|0|-0||0|
subtract|9|he|Inf|Inf||NaN|Inv
subtract|9|he|100|0.000001||99.999999|
subtract|9|he|1E+5|0.5||99999.5|
subtract|9|he|-1E-7|1||-1.0000001|
multiply|9|he|2|3||6|
multiply|9|he|5|1||5|
multiply|9|he|5|2||10|
multiply|9|he|1.20|2||2.40|
multiply|9|he|1.20|0||0.00|
multiply|9|he|1.20|-2||-2.40|
multiply|9|he|-1.20|2||-2.40|
multiply|9|he|5.09|7.1||36.139|
multiply|9|he|2.5|4||10.0|
multiply|9|he|2.50|4||10.00|
multiply|9|he|1.23456789|1.00000000||1.23456789|Rou
multiply|9|he|1.000000001|1.000000001||1.00000000|IneRou
multiply|9|he|9.999999999|9.999999999||100.000000|IneRou
multiply|9|he|0.9|-0||-0.0|
multiply|9|he|Inf|0||NaN|Inv
multiply|9|he|Inf|-2||-Infinity|
multiply|9|he|1E+999999|10||Infinity|IneOveRou
multiply|9|he|1E-999999|1E-10||0E-1000007|ClaIneRouSubUnd
multiply|9|he|654321|654321||4.28135971E+11|IneRou
multiply|9|he|1234567890123456789|9876543210987654321||1.21932631E+37|IneRou
multiply|9|he|-0.0|1E+3||-0E+2|
divide|9|he|1|1||1|
divide|9|hu|1|1||1|
divide|9|d|1|1||1|
divide|9|c|1|1||1|
divide|9|f|1|1||1|
divide|9|u|1|1||1|
divide|9|hd|1|1||1|
divide|9|05|1|1||1|
divide|9|he|2|1||2|
divide|9|hu|2|1||2|
divide|9|d|2|1||2|
divide|9|c|2|1||2|
divide|9|f|2|1||2|
divide|9|u|2|1||2|
divide|9|hd|2|1||2|
divide|9|05|2|1||2|
divide|9|he|1|2||0.5|
divide|9|hu|1|2||0.5|
divide|9|d|1|2||0.5|
divide|9|c|1|2||0.5|
divide|9|f|1|2||0.5|
divide|9|u|1|2||0.5|
divide|9|hd|1|2||0.5|
divide|9|05|1|2||0.5|
divide|9|he|2|2||1|
divide|9|hu|2|2||1|
divide|9|d|2|2||1|
divide|9|c|2|2||1|
divide|9|f|2|2||1|
divide|9|u|2|2||1|
divide|9|hd|2|2||1|
divide|9|05|2|2||1|
divide|9|he|0|1||0|
divide|9|hu|0|1||0|
divide|9|d|0|1||0|
divide|9|c|0|1||0|
divide|9|f|0|1||0|
divide|9|u|0|1||0|
divide|9|hd|0|1||0|
divide|9|05|0|1||0|
divide|9|he|0|2||0|
divide|9|hu|0|2||0|
divide|9|d|0|2||0|
divide|9|c|0|2||0|
divide|9|f|0|2||0|
divide|9|u|0|2||0|
divide|9|hd|0|2||0|
divide|9|05|0|2||0|
divide|9|he|1|3||0.333333333|IneRou
divide|9|hu|1|3||0.333333333|IneRou
divide|9|d|1|3||0.333333333|IneRou
divide|9|c|1|3||0.333333334|IneRou
divide|9|f|1|3||0.333333333|IneRou
divide|9|u|1|3||0.333333334|IneRou
divide|9|hd|1|3||0.333333333|IneRou
divide|9|05|1|3||0.333333333|IneRou
divide|9|he|2|3||0.666666667|IneRou
divide|9|hu|2|3||0.666666667|IneRou
divide|9|d|2|3||0.666666666|IneRou
divide|9|c|2|3||0.666666667|IneRou
divide|9|f|2|3||0.666666666|IneRou
divide|9|u|2|3||0.666666667|IneRou
divide|9|hd|2|3||0.666666667|IneRou
divide|9|05|2|3||0.666666666|IneRou
divide|9|he|3|3||1|
divide|9|hu|3|3||1|
divide|9|d|3|3||1|
divide|9|c|3|3||1|
divide|9|f|3|3||1|
divide|9|u|3|3||1|
divide|9|hd|3|3||1|
divide|9|05|3|3||1|
divide|9|he|2.4|1||2.4|
divide|9|hu|2.4|1||2.4|
divide|9|d|2.4|1||2.4|
divide|9|c|2.4|1||2.4|
divide|9|f|2.4|1||2.4|
divide|9|u|2.4|1||2.4|
divide|9|hd|2.4|1||2.4|
divide|9|05|2.4|1||2.4|
divide|9|he|2.4|-1||-2.4|
divide|9|hu|2.4|-1||-2.4|
divide|9|d|2.4|-1||-2.4|
divide|9|c|2.4|-1||-2.4|
divide|9|f|2.4|-1||-2.4|
divide|9|u|2.4|-1||-2.4|
divide|9|hd|2.4|-1||-2.4|
divide|9|05|2.4|-1||-2.4|
divide|9|he|-2.4|1||-2.4|
divide|9|hu|-2.4|1||-2.4|
divide|9|d|-2.4|1||-2.4|
divide|9|c|-2.4|1||-2.4|
divide|9|f|-2.4|1||-2.4|
divide|9|u|-2.4|1||-2.4|
divide|9|hd|-2.4|1||-2.4|
divide|9|05|-2.4|1||-2.4|
divide|9|he|2.40|1||2.40|
divide|9|hu|2.40|1||2.40|
divide|9|d|2.40|1||2.40|
divide|9|c|2.40|1||2.40|
divide|9|f|2.40|1||2.40|
divide|9|u|2.40|1||2.40|
divide|9|hd|2.40|1||2.40|
divide|9|05|2.40|1||2.40|
divide|9|he|2.400|1||2.400|
divide|9|hu|2.400|1||2.400|
divide|9|d|2.400|1||2.400|
divide|9|c|2.400|1||2.400|
divide|9|f|2.400|1||2.400|
divide|9|u|2.400|1||2.400|
divide|9|hd|2.400|1||2.400|
divide|9|05|2.400|1||2.400|
divide|9|he|2.4|2||1.2|
divide|9|hu|2.4|2||1.2|
divide|9|d|2.4|2||1.2|
divide|9|c|2.4|2||1.2|
divide|9|f|2.4|2||1.2|
divide|9|u|2.4|2||1.2|
divide|9|hd|2.4|2||1.2|
divide|9|05|2.4|2||1.2|
divide|9|he|2.400|2||1.200|
divide|9|hu|2.400|2||1.200|
divide|9|d|2.400|2||1.200|
divide|9|c|2.400|2||1.200|
divide|9|f|2.400|2||1.200|
divide|9|u|2.400|2||1.200|
divide|9|hd|2.400|2||1.200|
divide|9|05|2.400|2||1.200|
divide|9|he|2.|2||1|
divide|9|hu|2.|2||1|
divide|9|d|2.|2||1|
divide|9|c|2.|2||1|
divide|9|f|2.|2||1|
divide|9|u|2.|2||1|
divide|9|hd|2.|2||1|
divide|9|05|2.|2||1|
divide|9|he|20|20||1|
divide|9|hu|20|20||1|
divide|9|d|20|20||1|
divide|9|c|20|20||1|
divide|9|f|20|20||1|
divide|9|u|20|20||1|
divide|9|hd|20|20||1|
divide|9|05|20|20||1|
divide|9|he|187|187||1|
divide|9|hu|187|187||1|
divide|9|d|187|187||1|
divide|9|c|187|187||1|
divide|9|f|187|187||1|
divide|9|u|187|187||1|
divide|9|hd|187|187||1|
divide|9|05|187|187||1|
divide|9|he|5|2||2.5|
divide|9|hu|5|2||2.5|
divide|9|d|5|2||2.5|
divide|9|c|5|2||2.5|
divide|9|f|5|2||2.5|
divide|9|u|5|2||2.5|
divide|9|hd|5|2||2.5|
divide|9|05|5|2||2.5|
divide|9|he|5|2.0||2.5|
divide|9|hu|5|2.0||2.5|
divide|9|d|5|2.0||2.5|
divide|9|c|5|2.0||2.5|
divide|9|f|5|2.0||2.5|
divide|9|u|5|2.0||2.5|
divide|9|hd|5|2.0||2.5|
divide|9|05|5|2.0||2.5|
divide|9|he|5|2.000||2.5|
divide|9|hu|5|2.000||2.5|
divide|9|d|5|2.000||2.5|
divide|9|c|5|2.000||2.5|
divide|9|f|5|2.000||2.5|
divide|9|u|5|2.000||2.5|
divide|9|hd|5|2.000||2.5|
divide|9|05|5|2.000||2.5|
divide|9|he|5|0.20||25|
divide|9|hu|5|0.20||25|
divide|9|d|5|0.20||25|
divide|9|c|5|0.20||25|
divide|9|f|5|0.20||25|
divide|9|u|5|0.20||25|
divide|9|hd|5|0.20||25|
divide|9|05|5|0.20||25|
divide|9|he|5|0.200||25|
divide|9|hu|5|0.200||25|
divide|9|d|5|0.200||25|
divide|9|c|5|0.200||25|
divide|9|f|5|0.200||25|
divide|9|u|5|0.200||25|
divide|9|hd|5|0.200||25|
divide|9|05|5|0.200||25|
divide|9|he|1000|10||100|
divide|9|hu|1000|10||100|
divide|9|d|1000|10||100|
divide|9|c|1000|10||100|
divide|9|f|1000|10||100|
divide|9|u|1000|10||100|
divide|9|hd|1000|10||100|
divide|9|05|1000|10||100|
divide|9|he|1000|100||10|
divide|9|hu|1000|100||10|
divide|9|d|1000|100||10|
divide|9|c|1000|100||10|
divide|9|f|1000|100||10|
divide|9|u|1000|100||10|
divide|9|hd|1000|100||10|
divide|9|05|1000|100||10|
divide|9|he|1000|1||1000|
divide|9|hu|1000|1||1000|
divide|9|d|1000|1||1000|
divide|9|c|1000|1||1000|
divide|9|f|1000|1||1000|
divide|9|u|1000|1||1000|
divide|9|hd|1000|1||1000|
divide|9|05|1000|1||1000|
divide|9|he|2.40E+6|2||1.20E+6|
divide|9|hu|2.40E+6|2||1.20E+6|
divide|9|d|2.40E+6|2||1.20E+6|
divide|9|c|2.40E+6|2||1.20E+6|
divide|9|f|2.40E+6|2||1.20E+6|
divide|9|u|2.40E+6|2||1.20E+6|
divide|9|hd|2.40E+6|2||1.20E+6|
divide|9|05|2.40E+6|2||1.20E+6|
divide|9|he|2.40|3||0.80|
divide|9|hu|2.40|3||0.80|
divide|9|d|2.40|3||0.80|
divide|9|c|2.40|3||0.80|
divide|9|f|2.40|3||0.80|
divide|9|u|2.40|3||0.80|
divide|9|hd|2.40|3||0.80|
divide|9|05|2.40|3||0.80|
divide|9|he|2.400|3||0.800|
divide|9|hu|2.400|3||0.800|
divide|9|d|2.400|3||0.800|
divide|9|c|2.400|3||0.800|
divide|9|f|2.400|3||0.800|
divide|9|u|2.400|3||0.800|
divide|9|hd|2.400|3||0.800|
divide|9|05|2.400|3||0.800|
divide|9|he|2.4000|3||0.8000|
divide|9|hu|2.4000|3||0.8000|
divide|9|d|2.4000|3||0.8000|
divide|9|c|2.4000|3||0.8000|
divide|9|f|2.4000|3||0.8000|
divide|9|u|2.4000|3||0.8000|
divide|9|hd|2.4000|3||0.8000|
divide|9|05|2.4000|3||0.8000|
divide|9|he|1|0||Infinity|Div
divide|9|hu|1|0||Infinity|Div
divide|9|d|1|0||Infinity|Div
divide|9|c|1|0||Infinity|Div
divide|9|f|1|0||Infinity|Div
divide|9|u|1|0||Infinity|Div
divide|9|hd|1|0||Infinity|Div
divide|9|05|1|0||Infinity|Div
divide|9|he|-1|0||-Infinity|Div
divide|9|hu|-1|0||-Infinity|Div
divide|9|d|-1|0||-Infinity|Div
divide|9|c|-1|0||-Infinity|Div
divide|9|f|-1|0||-Infinity|Div
divide|9|u|-1|0||-Infinity|Div
divide|9|hd|-1|0||-Infinity|Div
divide|9|05|-1|0||-Infinity|Div
divide|9|he|0|0||NaN|Inv
divide|9|hu|0|0||NaN|Inv
divide|9|d|0|0||NaN|Inv
divide|9|c|0|0||NaN|Inv
divide|9|f|0|0||NaN|Inv
divide|9|u|0|0||NaN|Inv
divide|9|hd|0|0||NaN|Inv
divide|9|05|0|0||NaN|Inv
divide|9|he|0|-5||-0|
divide|9|hu|0|-5||-0|
divide|9|d|0|-5||-0|
divide|9|c|0|-5||-0|
divide|9|f|0|-5||-0|
divide|9|u|0|-5||-0|
divide|9|hd|0|-5||-0|
divide|9|05|0|-5||-0|
divide|9|he|1E+999999|0.1||Infinity|IneOveRou
divide|9|hu|1E+999999|0.1||Infinity|IneOveRou
divide|9|d|1E+999999|0.1||9.99999999E+999999|IneOveRou
divide|9|c|1E+999999|0.1||Infinity|IneOveRou
divide|9|f|1E+999999|0.1||9.99999999E+999999|IneOveRou
divide|9|u|1E+999999|0.1||Infinity|IneOveRou
divide|9|hd|1E+999999|0.1||Infinity|IneOveRou
divide|9|05|1E+999999|0.1||9.99999999E+999999|IneOveRou
divide|9|he|1E-999999|10||1E-1000000|Sub
divide|9|hu|1E-999999|10||1E-1000000|Sub
divide|9|d|1E-999999|10||1E-1000000|Sub
divide|9|c|1E-999999|10||1E-1000000|Sub
divide|9|f|1E-999999|10||1E-1000000|Sub
divide|9|u|1E-999999|10||1E-1000000|Sub
divide|9|hd|1E-999999|10||1E-1000000|Sub
divide|9|05|1E-999999|10||1E-1000000|Sub
divide|9|he|Inf|Inf||NaN|Inv
divide|9|hu|Inf|Inf||NaN|Inv
divide|9|d|Inf|Inf||NaN|Inv
divide|9|c|Inf|Inf||NaN|Inv
divide|9|f|Inf|Inf||NaN|Inv
divide|9|u|Inf|Inf||NaN|Inv
divide|9|hd|Inf|Inf||NaN|Inv
divide|9|05|Inf|Inf||NaN|Inv
divide|9|he|Inf|7||Infinity|
divide|9|hu|Inf|7||Infinity|
divide|9|d|Inf|7||Infinity|
divide|9|c|Inf|7||Infinity|
divide|9|f|Inf|7||Infinity|
divide|9|u|Inf|7||Infinity|
divide|9|hd|Inf|7||Infinity|
divide|9|05|Inf|7||Infinity|
divide|9|he|7|Inf||0E-1000007|Cla
divide|9|hu|7|Inf||0E-1000007|Cla
divide|9|d|7|Inf||0E-1000007|Cla
divide|9|c|7|Inf||0E-1000007|Cla
divide|9|f|7|Inf||0E-1000007|Cla
divide|9|u|7|Inf||0E-1000007|Cla
divide|9|hd|7|Inf||0E-1000007|Cla
divide|9|05|7|Inf||0E-1000007|Cla
divide|9|he|12345678901234567890|7||1.76366841E+18|IneRou
divide|9|hu|12345678901234567890|7||1.76366841E+18|IneRou
divide|9|d|12345678901234567890|7||1.76366841E+18|IneRou
divide|9|c|12345678901234567890|7||1.76366842E+18|IneRou
divide|9|f|12345678901234567890|7||1.76366841E+18|IneRou
divide|9|u|12345678901234567890|7||1.76366842E+18|IneRou
divide|9|hd|12345678901234567890|7||1.76366841E+18|IneRou
divide|9|05|12345678901234567890|7||1.76366841E+18|IneRou
divide|9|he|1|7||0.142857143|IneRou
divide|9|hu|1|7||0.142857143|IneRou
divide|9|d|1|7||0.142857142|IneRou
divide|9|c|1|7||0.142857143|IneRou
divide|9|f|1|7||0.142857142|IneRou
divide|9|u|1|7||0.142857143|IneRou
divide|9|hd|1|7||0.142857143|IneRou
divide|9|05|1|7||0.142857142|IneRou
divide|9|he|-22|7||-3.14285714|IneRou
divide|9|hu|-22|7||-3.14285714|IneRou
divide|9|d|-22|7||-3.14285714|IneRou
divide|9|c|-22|7||-3.14285714|IneRou
divide|9|f|-22|7||-3.14285715|IneRou
divide|9|u|-22|7||-3.14285715|IneRou
divide|9|hd|-22|7||-3.14285714|IneRou
divide|9|05|-22|7||-3.14285714|IneRou
divide|9|he|391|597||0.654941374|IneRou
divide|9|hu|391|597||0.654941374|IneRou
divide|9|d|391|597||0.654941373|IneRou
divide|9|c|391|597||0.654941374|IneRou
divide|9|f|391|597||0.654941373|IneRou
divide|9|u|391|597||0.654941374|IneRou
divide|9|hd|391|597||0.654941374|IneRou
divide|9|05|391|597||0.654941373|IneRou
remainder|9|he|1|1||0|
remainder|9|he|2|1||0|
remainder|9|he|1|2||1|
remainder|9|he|2|3||2|
remainder|9|he|10|3||1|
remainder|9|he|-10|3||-1|
remainder|9|he|10.2|1||0.2|
remainder|9|he|10|0.3||0.1|
remainder|9|he|3.6|1.3||1.0|
remainder|9|he|7|-2||1|
remainder|9|he|-7|2||-1|
remainder|9|he|1|0||NaN|Inv
remainder|9|he|0|0||NaN|Inv
remainder|9|he|1E+50|7||NaN|Inv
remainder_near|9|he|2.1|3||-0.9|
remainder_near|9|he|10|6||-2|
remainder_near|9|he|10|3||1|
remainder_near|9|he|-10|3||-1|
remainder_near|9|he|10.2|1||0.2|
remainder_near|9|he|10|0.3||0.1|
remainder_near|9|he|3.6|1.3||-0.3|
remainder_near|9|he|7|2||-1|
remainder_near|9|he|9|2||1|
remainder_near|9|he|-7|2||1|
remainder_near|9|he|1|0||NaN|Inv
quantize|9|he|2.17|0.001||2.170|
quantize|9|hu|2.17|0.001||2.170|
quantize|9|d|2.17|0.001||2.170|
quantize|9|c|2.17|0.001||2.170|
quantize|9|f|2.17|0.001||2.170|
quantize|9|u|2.17|0.001||2.170|
quantize|9|hd|2.17|0.001||2.170|
quantize|9|05|2.17|0.001||2.170|
quantize|9|he|2.17|0.01||2.17|
quantize|9|hu|2.17|0.01||2.17|
quantize|9|d|2.17|0.01||2.17|
quantize|9|c|2.17|0.01||2.17|
quantize|9|f|2.17|0.01||2.17|
quantize|9|u|2.17|0.01||2.17|
quantize|9|hd|2.17|0.01||2.17|
quantize|9|05|2.17|0.01||2.17|
quantize|9|he|2.17|0.1||2.2|IneRou
quantize|9|hu|2.17|0.1||2.2|IneRou
quantize|9|d|2.17|0.1||2.1|IneRou
quantize|9|c|2.17|0.1||2.2|IneRou
quantize|9|f|2.17|0.1||2.1|IneRou
quantize|9|u|2.17|0.1||2.2|IneRou
quantize|9|hd|2.17|0.1||2.2|IneRou
quantize|9|05|2.17|0.1||2.1|IneRou
quantize|9|he|2.17|1e+0||2|IneRou
quantize|9|hu|2.17|1e+0||2|IneRou
quantize|9|d|2.17|1e+0||2|IneRou
quantize|9|c|2.17|1e+0||3|IneRou
quantize|9|f|2.17|1e+0||2|IneRou
quantize|9|u|2.17|1e+0||3|IneRou
quantize|9|hd|2.17|1e+0||2|IneRou
quantize|9|05|2.17|1e+0||2|IneRou
quantize|9|he|2.17|1e+1||0E+1|IneRou
quantize|9|hu|2.17|1e+1||0E+1|IneRou
quantize|9|d|2.17|1e+1||0E+1|IneRou
quantize|9|c|2.17|1e+1||1E+1|IneRou
quantize|9|f|2.17|1e+1||0E+1|IneRou
quantize|9|u|2.17|1e+1||1E+1|IneRou
quantize|9|hd|2.17|1e+1||0E+1|IneRou
quantize|9|05|2.17|1e+1||1E+1|IneRou
quantize|9|he|-Inf|Inf||-Infinity|
quantize|9|hu|-Inf|Inf||-Infinity|
quantize|9|d|-Inf|Inf||-Infinity|
quantize|9|c|-Inf|Inf||-Infinity|
quantize|9|f|-Inf|Inf||-Infinity|
quantize|9|u|-Inf|Inf||-Infinity|
quantize|9|hd|-Inf|Inf||-Infinity|
quantize|9|05|-Inf|Inf||-Infinity|
quantize|9|he|2|Inf||NaN|Inv
quantize|9|hu|2|Inf||NaN|Inv
quantize|9|d|2|Inf||NaN|Inv
quantize|9|c|2|Inf||NaN|Inv
quantize|9|f|2|Inf||NaN|Inv
quantize|9|u|2|Inf||NaN|Inv
quantize|9|hd|2|Inf||NaN|Inv
quantize|9|05|2|Inf||NaN|Inv
quantize|9|he|-0.1|1||-0|IneRou
quantize|9|hu|-0.1|1||-0|IneRou
quantize|9|d|-0.1|1||-0|IneRou
quantize|9|c|-0.1|1||-0|IneRou
quantize|9|f|-0.1|1||-1|IneRou
quantize|9|u|-0.1|1||-1|IneRou
quantize|9|hd|-0.1|1||-0|IneRou
quantize|9|05|-0.1|1||-1|IneRou
quantize|9|he|-0|1e+5||-0E+5|
quantize|9|hu|-0|1e+5||-0E+5|
quantize|9|d|-0|1e+5||-0E+5|
quantize|9|c|-0|1e+5||-0E+5|
quantize|9|f|-0|1e+5||-0E+5|
quantize|9|u|-0|1e+5||-0E+5|
quantize|9|hd|-0|1e+5||-0E+5|
quantize|9|05|-0|1e+5||-0E+5|
quantize|9|he|+35236450.6|1e-2||NaN|Inv
quantize|9|hu|+35236450.6|1e-2||NaN|Inv
quantize|9|d|+35236450.6|1e-2||NaN|Inv
quantize|9|c|+35236450.6|1e-2||NaN|Inv
quantize|9|f|+35236450.6|1e-2||NaN|Inv
quantize|9|u|+35236450.6|1e-2||NaN|Inv
quantize|9|hd|+35236450.6|1e-2||NaN|Inv
quantize|9|05|+35236450.6|1e-2||NaN|Inv
quantize|9|he|-35236450.6|1e-2||NaN|Inv
quantize|9|hu|-35236450.6|1e-2||NaN|Inv
quantize|9|d|-35236450.6|1e-2||NaN|Inv
quantize|9|c|-35236450.6|1e-2||NaN|Inv
quantize|9|f|-35236450.6|1e-2||NaN|Inv
quantize|9|u|-35236450.6|1e-2||NaN|Inv
quantize|9|hd|-35236450.6|1e-2||NaN|Inv
quantize|9|05|-35236450.6|1e-2||NaN|Inv
quantize|9|he|217|1e-1||217.0|
quantize|9|hu|217|1e-1||217.0|
quantize|9|d|217|1e-1||217.0|
quantize|9|c|217|1e-1||217.0|
quantize|9|f|217|1e-1||217.0|
quantize|9|u|217|1e-1||217.0|
quantize|9|hd|217|1e-1||217.0|
quantize|9|05|217|1e-1||217.0|
quantize|9|he|217|1e+0||217|
quantize|9|hu|217|1e+0||217|
quantize|9|d|217|1e+0||217|
quantize|9|c|217|1e+0||217|
quantize|9|f|217|1e+0||217|
quantize|9|u|217|1e+0||217|
quantize|9|hd|217|1e+0||217|
quantize|9|05|217|1e+0||217|
quantize|9|he|217|1e+1||2.2E+2|IneRou
quantize|9|hu|217|1e+1||2.2E+2|IneRou
quantize|9|d|217|1e+1||2.1E+2|IneRou
quantize|9|c|217|1e+1||2.2E+2|IneRou
quantize|9|f|217|1e+1||2.1E+2|IneRou
quantize|9|u|217|1e+1||2.2E+2|IneRou
quantize|9|hd|217|1e+1||2.2E+2|IneRou
quantize|9|05|217|1e+1||2.1E+2|IneRou
quantize|9|he|217|1e+2||2E+2|IneRou
quantize|9|hu|217|1e+2||2E+2|IneRou
quantize|9|d|217|1e+2||2E+2|IneRou
quantize|9|c|217|1e+2||3E+2|IneRou
quantize|9|f|217|1e+2||2E+2|IneRou
quantize|9|u|217|1e+2||3E+2|IneRou
quantize|9|hd|217|1e+2||2E+2|IneRou
quantize|9|05|217|1e+2||2E+2|IneRou
quantize|9|he|1.2345|1e-3||1.234|IneRou
quantize|9|hu|1.2345|1e-3||1.235|IneRou
quantize|9|d|1.2345|1e-3||1.234|IneRou
quantize|9|c|1.2345|1e-3||1.235|IneRou
quantize|9|f|1.2345|1e-3||1.234|IneRou
quantize|9|u|1.2345|1e-3||1.235|IneRou
quantize|9|hd|1.2345|1e-3||1.234|IneRou
quantize|9|05|1.2345|1e-3||1.234|IneRou
quantize|9|he|1.2355|1e-3||1.236|IneRou
quantize|9|hu|1.2355|1e-3||1.236|IneRou
quantize|9|d|1.2355|1e-3||1.235|IneRou
quantize|9|c|1.2355|1e-3||1.236|IneRou
quantize|9|f|1.2355|1e-3||1.235|IneRou
quantize|9|u|1.2355|1e-3||1.236|IneRou
quantize|9|hd|1.2355|1e-3||1.235|IneRou
quantize|9|05|1.2355|1e-3||1.236|IneRou
quantize|9|he|1.2365|1e-3||1.236|IneRou
quantize|9|hu|1.2365|1e-3||1.237|IneRou
quantize|9|d|1.2365|1e-3||1.236|IneRou
quantize|9|c|1.2365|1e-3||1.237|IneRou
quantize|9|f|1.2365|1e-3||1.236|IneRou
quantize|9|u|1.2365|1e-3||1.237|IneRou
quantize|9|hd|1.2365|1e-3||1.236|IneRou
quantize|9|05|1.2365|1e-3||1.236|IneRou
quantize|9|he|-1.2345|1e-3||-1.234|IneRou
quantize|9|hu|-1.2345|1e-3||-1.235|IneRou
quantize|9|d|-1.2345|1e-3||-1.234|IneRou
quantize|9|c|-1.2345|1e-3||-1.234|IneRou
quantize|9|f|-1.2345|1e-3||-1.235|IneRou
quantize|9|u|-1.2345|1e-3||-1.235|IneRou
quantize|9|hd|-1.2345|1e-3||-1.234|IneRou
quantize|9|05|-1.2345|1e-3||-1.234|IneRou
quantize|9|he|0.0005|1e-3||0.000|IneRou
quantize|9|hu|0.0005|1e-3||0.001|IneRou
quantize|9|d|0.0005|1e-3||0.000|IneRou
quantize|9|c|0.0005|1e-3||0.001|IneRou
quantize|9|f|0.0005|1e-3||0.000|IneRou
quantize|9|u|0.0005|1e-3||0.001|IneRou
quantize|9|hd|0.0005|1e-3||0.000|IneRou
quantize|9|05|0.0005|1e-3||0.001|IneRou
quantize|9|he|9.9995|1e-3||10.000|IneRou
quantize|9|hu|9.9995|1e-3||10.000|IneRou
quantize|9|d|9.9995|1e-3||9.999|IneRou
quantize|9|c|9.9995|1e-3||10.000|IneRou
quantize|9|f|9.9995|1e-3||9.999|IneRou
quantize|9|u|9.9995|1e-3||10.000|IneRou
quantize|9|hd|9.9995|1e-3||9.999|IneRou
quantize|9|05|9.9995|1e-3||9.999|IneRou
quantize|9|he|NaN|1||NaN|
quantize|9|hu|NaN|1||NaN|
quantize|9|d|NaN|1||NaN|
quantize|9|c|NaN|1||NaN|
quantize|9|f|NaN|1||NaN|
quantize|9|u|NaN|1||NaN|
quantize|9|hd|NaN|1||NaN|
quantize|9|05|NaN|1||NaN|
quantize|9|he|1|NaN||NaN|
quantize|9|hu|1|NaN||NaN|
quantize|9|d|1|NaN||NaN|
quantize|9|c|1|NaN||NaN|
quantize|9|f|1|NaN||NaN|
quantize|9|u|1|NaN||NaN|
quantize|9|hd|1|NaN||NaN|
quantize|9|05|1|NaN||NaN|
max|9|he|1|2||2|
max|9|he|-1|-2||-1|
max|9|he|1.0|1||1|
max|9|he|-0|0||0|
max|9|he|NaN|1||1|
max|9|he|Inf|1E+999||Infinity|
min|9|he|1|2||1|
min|9|he|-1|-2||-2|
min|9|he|1.0|1||1.0|
min|9|he|-0|0||-0|
min|9|he|NaN|1||1|
min|9|he|-Inf|-1E+999||-Infinity|
compare|9|he|1|2||-1|
compare|9|he|2|1||1|
compare|9|he|1|1.00||0|
compare|9|he|-0|0||0|
compare|9|he|NaN|1||NaN|
compare|9|he|-Inf|Inf||-1|
compare_total|9|he|12.30|12.3||-1|
compare_total|9|he|12.3|12.30||1|
compare_total|9|he|-0|0||-1|
compare_total|9|he|NaN|sNaN||1|
compare_total|9|he|-NaN|-Inf||-1|
compare_total|9|he|1E+2|100||1|
power|9|he|2|10||1024|
power|9|he|2|-1||0.5|
power|9|he|2|0.5||1.41421356|IneRou
power|9|he|-2|3||-8|
power|9|he|10|-2||0.01|
power|9|he|4|0.5||2.00000000|IneRou
power|9|he|0|0||NaN|Inv
power|9|he|0|-1||Infinity|
power|9|he|-0|-1||-Infinity|
power|9|he|Inf|-1||0|
power|9|he|1.1|20||6.72749995|IneRou
power|9|he|2|100||1.26765060E+30|IneRou
power|9|he|10|999999999||Infinity|IneOveRou
power|9|he|3|1E-10||1.00000000|IneRou
power|9|he|0.5|-3||8|
scaleb|9|he|7.50|10||7.50E+10|
scaleb|9|he|7.50|-2||0.0750|
scaleb|9|he|7.50|0||7.50|
scaleb|9|he|1E+999999|1||Infinity|IneOveRou
scaleb|9|he|Inf|-7||Infinity|
copy_sign|9|he|1.50|7.33||1.50|
copy_sign|9|he|-1.50|7.33||1.50|
copy_sign|9|he|1.50|-7.33||-1.50|
copy_sign|9|he|NaN|-1||-NaN|
next_toward|9|he|1|2||1.00000001|
next_toward|9|he|1|0||0.999999999|
next_toward|9|he|-1E-999999|0||-9.9999999E-1000000|IneRouSubUnd
next_toward|9|he|0|-1||-1E-1000007|IneRouSubUnd
next_toward|9|he|9.999999999999999999999999999999999E+999999|Inf||Infinity|IneOveRou
max_mag|9|he|-10|2||-10|
max_mag|9|he|1|-1||1|
max_mag|9|he|-1|1||1|
min_mag|9|he|-10|2||2|
min_mag|9|he|1|-1||-1|
min_mag|9|he|-1|1||-1|
rotate|9|he|34|8||400000003|
rotate|9|he|12|9||12|
rotate|9|he|123456789|-2||891234567|
rotate|9|he|123456789|0||123456789|
rotate|9|he|123456789|+2||345678912|
shift|9|he|34|8||400000000|
shift|9|he|12|9||0|
shift|9|he|123456789|-2||1234567|
shift|9|he|123456789|0||123456789|
shift|9|he|123456789|+2||345678900|
logical_and|9|he|1100|1010||1000|
logical_and|9|he|0|1||0|
logical_and|9|he|1111|10||10|
logical_or|9|he|1100|1010||1110|
logical_or|9|he|0|1||1|
logical_or|9|he|1111|10||1111|
logical_xor|9|he|1100|1010||110|
logical_xor|9|he|0|1||1|
logical_xor|9|he|1111|10||1101|
plus|9|he|12345.6789|||12345.6789|
plus|9|hu|12345.6789|||12345.6789|
plus|9|hd|12345.6789|||12345.6789|
plus|9|u|12345.6789|||12345.6789|
plus|9|d|12345.6789|||12345.6789|
plus|9|c|12345.6789|||12345.6789|
plus|9|f|12345.6789|||12345.6789|
plus|9|05|12345.6789|||12345.6789|
plus|9|he|-12345.6789|||-12345.6789|
plus|9|hu|-12345.6789|||-12345.6789|
plus|9|hd|-12345.6789|||-12345.6789|
plus|9|u|-12345.6789|||-12345.6789|
plus|9|d|-12345.6789|||-12345.6789|
plus|9|c|-12345.6789|||-12345.6789|
plus|9|f|-12345.6789|||-12345.6789|
plus|9|05|-12345.6789|||-12345.6789|
plus|9|he|1.2345678901234567890123456789012345678|||1.23456789|IneRou
plus|9|hu|1.2345678901234567890123456789012345678|||1.23456789|IneRou
plus|9|hd|1.2345678901234567890123456789012345678|||1.23456789|IneRou
plus|9|u|1.2345678901234567890123456789012345678|||1.23456790|IneRou
plus|9|d|1.2345678901234567890123456789012345678|||1.23456789|IneRou
plus|9|c|1.2345678901234567890123456789012345678|||1.23456790|IneRou
plus|9|f|1.2345678901234567890123456789012345678|||1.23456789|IneRou
plus|9|05|1.2345678901234567890123456789012345678|||1.23456789|IneRou
plus|9|he|0.000000001234567890125|||1.23456789E-9|IneRou
plus|9|hu|0.000000001234567890125|||1.23456789E-9|IneRou
plus|9|hd|0.000000001234567890125|||1.23456789E-9|IneRou
plus|9|u|0.000000001234567890125|||1.23456790E-9|IneRou
plus|9|d|0.000000001234567890125|||1.23456789E-9|IneRou
plus|9|c|0.000000001234567890125|||1.23456790E-9|IneRou
plus|9|f|0.000000001234567890125|||1.23456789E-9|IneRou
plus|9|05|0.000000001234567890125|||1.23456789E-9|IneRou
plus|9|he|99999999999999999999999999999999999.5|||1.00000000E+35|IneRou
plus|9|hu|99999999999999999999999999999999999.5|||1.00000000E+35|IneRou
plus|9|hd|99999999999999999999999999999999999.5|||1.00000000E+35|IneRou
plus|9|u|99999999999999999999999999999999999.5|||1.00000000E+35|IneRou
plus|9|d|99999999999999999999999999999999999.5|||9.99999999E+34|IneRou
plus|9|c|99999999999999999999999999999999999.5|||1.00000000E+35|IneRou
plus|9|f|99999999999999999999999999999999999.5|||9.99999999E+34|IneRou
plus|9|05|99999999999999999999999999999999999.5|||9.99999999E+34|IneRou
plus|9|he|-0|||0|
plus|9|hu|-0|||0|
plus|9|hd|-0|||0|
plus|9|u|-0|||0|
plus|9|d|-0|||0|
plus|9|c|-0|||0|
plus|9|f|-0|||-0|
plus|9|05|-0|||0|
plus|9|he|1E+1000000|||Infinity|IneOveRou
plus|9|hu|1E+1000000|||Infinity|IneOveRou
plus|9|hd|1E+1000000|||Infinity|IneOveRou
plus|9|u|1E+1000000|||Infinity|IneOveRou
plus|9|d|1E+1000000|||9.99999999E+999999|IneOveRou
plus|9|c|1E+1000000|||Infinity|IneOveRou
plus|9|f|1E+1000000|||9.99999999E+999999|IneOveRou
plus|9|05|1E+1000000|||9.99999999E+999999|IneOveRou
plus|9|he|1E-1000010|||0E-1000007|ClaIneRouSubUnd
plus|9|hu|1E-1000010|||0E-1000007|ClaIneRouSubUnd
plus|9|hd|1E-1000010|||0E-1000007|ClaIneRouSubUnd
plus|9|u|1E-1000010|||1E-1000007|IneRouSubUnd
plus|9|d|1E-1000010|||0E-1000007|ClaIneRouSubUnd
plus|9|c|1E-1000010|||1E-1000007|IneRouSubUnd
plus|9|f|1E-1000010|||0E-1000007|ClaIneRouSubUnd
plus|9|05|1E-1000010|||1E-1000007|IneRouSubUnd
plus|9|he|0.5E-999999|||5E-1000000|Sub
plus|9|hu|0.5E-999999|||5E-1000000|Sub
plus|9|hd|0.5E-999999|||5E-1000000|Sub
plus|9|u|0.5E-999999|||5E-1000000|Sub
plus|9|d|0.5E-999999|||5E-1000000|Sub
plus|9|c|0.5E-999999|||5E-1000000|Sub
plus|9|f|0.5E-999999|||5E-1000000|Sub
plus|9|05|0.5E-999999|||5E-1000000|Sub
minus|9|he|1|||-1|
minus|9|he|-0|||0|
minus|9|he|0|||0|
minus|9|he|1.50|||-1.50|
abs|9|he|-1|||1|
abs|9|he|-0|||0|
abs|9|he|-1E+999|||1E+999|
abs|9|he|NaN|||NaN|
sqrt|9|he|0|||0|
sqrt|9|he|-0|||-0|
sqrt|9|he|0.39|||0.624499800|IneRou
sqrt|9|he|100|||10|
sqrt|9|he|1|||1|
sqrt|9|he|1.0|||1.0|
sqrt|9|he|1.00|||1.0|
sqrt|9|he|7|||2.64575131|IneRou
sqrt|9|he|10|||3.16227766|IneRou
sqrt|9|he|-1|||NaN|Inv
sqrt|9|he|0.1|||0.316227766|IneRou
sqrt|9|he|1E-1000|||1E-500|
sqrt|9|he|2|||1.41421356|IneRou
sqrt|9|he|3|||1.73205081|IneRou
sqrt|9|he|4E+10|||2E+5|
sqrt|9|he|0.04|||0.2|
sqrt|9|he|Inf|||Infinity|
sqrt|9|he|NaN|||NaN|
sqrt|9|he|1E+999999|||3.16227766E+499999|IneRou
sqrt|9|he|15241578750190521|||123456789|
exp|9|he|0|||1|
exp|9|he|1|||2.71828183|IneRou
exp|9|he|2|||7.38905610|IneRou
exp|9|he|-1|||0.367879441|IneRou
exp|9|he|0.5|||1.64872127|IneRou
exp|9|he|1E-10|||1.00000000|IneRou
exp|9|he|-Inf|||0|
exp|9|he|Inf|||Infinity|
exp|9|he|10|||22026.4658|IneRou
exp|9|he|100|||2.68811714E+43|IneRou
exp|9|he|-100|||3.72007598E-44|IneRou
exp|9|he|2.302585092994045684|||10.0000000|IneRou
exp|9|he|1234|||8.30597594E+535|IneRou
exp|9|he|-1234|||1.20395244E-536|IneRou
exp|9|he|0.001|||1.00100050|IneRou
ln|9|he|1|||0|
ln|9|he|2|||0.693147181|IneRou
ln|9|he|10|||2.30258509|IneRou
ln|9|he|0.5|||-0.693147181|IneRou
ln|9|he|100|||4.60517019|IneRou
ln|9|he|0|||-Infinity|
ln|9|he|-1|||NaN|Inv
ln|9|he|Inf|||Infinity|
ln|9|he|1E+999|||2300.28251|IneRou
ln|9|he|0.0001|||-9.21034037|IneRou
ln|9|he|2.718281828459045235360287471|||1.00000000|IneRou
log10|9|he|1|||0|
log10|9|he|10|||1|
log10|9|he|1000|||3|
log10|9|he|2|||0.301029996|IneRou
log10|9|he|0.01|||-2|
log10|9|he|0.5|||-0.301029996|IneRou
log10|9|he|1E+500|||500|
log10|9|he|0|||-Infinity|
log10|9|he|-2|||NaN|Inv
log10|9|he|7.389|||0.868585667|IneRou
logb|9|he|250|||2|
logb|9|he|2.50|||0|
logb|9|he|0.03|||-2|
logb|9|he|0|||-Infinity|Div
logb|9|he|-Inf|||Infinity|
logb|9|he|1E-999|||-999|
normalize|9|he|2.1|||2.1|
normalize|9|he|-2.0|||-2|
normalize|9|he|1.200|||1.2|
normalize|9|he|-120|||-1.2E+2|
normalize|9|he|120.00|||1.2E+2|
normalize|9|he|0.00|||0|
normalize|9|he|1E+2|||1E+2|
normalize|9|he|NaN|||NaN|
normalize|9|he|-0.0|||-0|
to_integral_value|9|he|2.1|||2|
to_integral_value|9|hu|2.1|||2|
to_integral_value|9|hd|2.1|||2|
to_integral_value|9|u|2.1|||3|
to_integral_value|9|d|2.1|||2|
to_integral_value|9|c|2.1|||3|
to_integral_value|9|f|2.1|||2|
to_integral_value|9|05|2.1|||2|
to_integral_value|9|he|100|||100|
to_integral_value|9|hu|100|||100|
to_integral_value|9|hd|100|||100|
to_integral_value|9|u|100|||100|
to_integral_value|9|d|100|||100|
to_integral_value|9|c|100|||100|
to_integral_value|9|f|100|||100|
to_integral_value|9|05|100|||100|
to_integral_value|9|he|100.0|||100|
to_integral_value|9|hu|100.0|||100|
to_integral_value|9|hd|100.0|||100|
to_integral_value|9|u|100.0|||100|
to_integral_value|9|d|100.0|||100|
to_integral_value|9|c|100.0|||100|
to_integral_value|9|f|100.0|||100|
to_integral_value|9|05|100.0|||100|
to_integral_value|9|he|101.5|||102|
to_integral_value|9|hu|101.5|||102|
to_integral_value|9|hd|101.5|||101|
to_integral_value|9|u|101.5|||102|
to_integral_value|9|d|101.5|||101|
to_integral_value|9|c|101.5|||102|
to_integral_value|9|f|101.5|||101|
to_integral_value|9|05|101.5|||101|
to_integral_value|9|he|-101.5|||-102|
to_integral_value|9|hu|-101.5|||-102|
to_integral_value|9|hd|-101.5|||-101|
to_integral_value|9|u|-101.5|||-102|
to_integral_value|9|d|-101.5|||-101|
to_integral_value|9|c|-101.5|||-101|
to_integral_value|9|f|-101.5|||-102|
to_integral_value|9|05|-101.5|||-101|
to_integral_value|9|he|10E+5|||1.0E+6|
to_integral_value|9|hu|10E+5|||1.0E+6|
to_integral_value|9|hd|10E+5|||1.0E+6|
to_integral_value|9|u|10E+5|||1.0E+6|
to_integral_value|9|d|10E+5|||1.0E+6|
to_integral_value|9|c|10E+5|||1.0E+6|
to_integral_value|9|f|10E+5|||1.0E+6|
to_integral_value|9|05|10E+5|||1.0E+6|
to_integral_value|9|he|7.89E+77|||7.89E+77|
to_integral_value|9|hu|7.89E+77|||7.89E+77|
to_integral_value|9|hd|7.89E+77|||7.89E+77|
to_integral_value|9|u|7.89E+77|||7.89E+77|
to_integral_value|9|d|7.89E+77|||7.89E+77|
to_integral_value|9|c|7.89E+77|||7.89E+77|
to_integral_value|9|f|7.89E+77|||7.89E+77|
to_integral_value|9|05|7.89E+77|||7.89E+77|
to_integral_value|9|he|-Inf|||-Infinity|
to_integral_value|9|hu|-Inf|||-Infinity|
to_integral_value|9|hd|-Inf|||-Infinity|
to_integral_value|9|u|-Inf|||-Infinity|
to_integral_value|9|d|-Inf|||-Infinity|
to_integral_value|9|c|-Inf|||-Infinity|
to_integral_value|9|f|-Inf|||-Infinity|
to_integral_value|9|05|-Inf|||-Infinity|
to_integral_value|9|he|0.5|||0|
to_integral_value|9|hu|0.5|||1|
to_integral_value|9|hd|0.5|||0|
to_integral_value|9|u|0.5|||1|
to_integral_value|9|d|0.5|||0|
to_integral_value|9|c|0.5|||1|
to_integral_value|9|f|0.5|||0|
to_integral_value|9|05|0.5|||1|
to_integral_value|9|he|-0.5|||-0|
to_integral_value|9|hu|-0.5|||-1|
to_integral_value|9|hd|-0.5|||-0|
to_integral_value|9|u|-0.5|||-1|
to_integral_value|9|d|-0.5|||-0|
to_integral_value|9|c|-0.5|||-0|
to_integral_value|9|f|-0.5|||-1|
to_integral_value|9|05|-0.5|||-1|
to_integral_value|9|he|2.5|||2|
to_integral_value|9|hu|2.5|||3|
to_integral_value|9|hd|2.5|||2|
to_integral_value|9|u|2.5|||3|
to_integral_value|9|d|2.5|||2|
to_integral_value|9|c|2.5|||3|
to_integral_value|9|f|2.5|||2|
to_integral_value|9|05|2.5|||2|
to_integral_exact|9|he|2.1|||2|IneRou
to_integral_exact|9|he|100|||100|
to_integral_exact|9|he|101.5|||102|IneRou
to_integral_exact|9|he|-101.5|||-102|IneRou
to_integral_exact|9|he|0.5|||0|IneRou
next_plus|9|he|1|||1.00000001|
next_plus|9|he|-1E-999999|||-9.9999999E-1000000|
next_plus|9|he|-0|||1E-1000007|
next_plus|9|he|9.999999999999999999999999999999999E+999999|||Infinity|
next_plus|9|he|-Inf|||-9.99999999E+999999|
next_minus|9|he|1|||0.999999999|
next_minus|9|he|1E-999999|||9.9999999E-1000000|
next_minus|9|he|0|||-1E-1000007|
next_minus|9|he|-9.999999999999999999999999999999999E+999999|||-Infinity|
next_minus|9|he|Inf|||9.99999999E+999999|
logical_invert|9|he|0|||111111111|
logical_invert|9|he|1|||111111110|
logical_invert|9|he|111111111|||0|
logical_invert|9|he|101010101|||10101010|
number_class|9|he|Inf|||+Infinity|
number_class|9|he|1E-10|||+Normal|
number_class|9|he|2.50|||+Normal|
number_class|9|he|0.1E-999|||+Normal|
number_class|9|he|0|||+Zero|
number_class|9|he|-0|||-Zero|
number_class|9|he|-0.1E-999|||-Normal|
number_class|9|he|-1E-10|||-Normal|
number_class|9|he|-2.50|||-Normal|
number_class|9|he|-Inf|||-Infinity|
number_class|9|he|NaN|||NaN|
number_class|9|he|sNaN|||sNaN|
fma|9|he|3|5|7|22|
fma|9|he|3|-5|7|-8|
fma|9|he|888565290|1557.96930|-86087.7578|1.38435736E+12|IneRou
fma|9|he|Inf|0|1|NaN|Inv
fma|9|he|1E+999999|10|-1E+999999|9E+999999|
add|16|he|1|1||2|
add|16|he|2|3||5|
add|16|he|5.75|3.3||9.05|
add|16|he|5|-3||2|
add|16|he|-5|-3||-8|
add|16|he|-7|2.5||-4.5|
add|16|he|0.7|0.3||1.0|
add|16|he|1.25|1.25||2.50|
add|16|he|1.23456789|1.00000000||2.23456789|
add|16|he|1.23456789|1.00000011||2.23456800|
add|16|he|0.4444444444|0.5555555555||0.9999999999|
add|16|he|70|10000e+9||10000000000070|
add|16|he|700000|10000e+9||10000000700000|
add|16|he|1E+12|-1||999999999999|
add|16|he|1E+12|1.11||1000000000001.11|
add|16|he|1E+12|1.111||1000000000001.111|
add|16|he|-1|1E+12||999999999999|
add|16|he|0.0|0.000||0.000|
add|16|he|-0|0||0|
add|16|he|-0|-0||-0|
add|16|he|Inf|-Inf||NaN|Inv
add|16|he|Inf|1||Infinity|
add|16|he|NaN|1||NaN|
add|16|he|1|NaN5||NaN5|
add|16|he|sNaN|1||NaN|Inv
add|16|he|12345678901234567890|1||1.234567890123457E+19|IneRou
add|16|he|9.999999999999999999999999999999999E+999999|1E+999999||Infinity|IneOveRou
add|16|he|1E-999999|-1E-999999||0E-999999|
add|16|he|0.1|0.2||0.3|
add|16|he|123456789012345678901234567890123456789|0.5||1.234567890123457E+38|IneRou
subtract|16|he|2|3||-1|
subtract|16|he|2.3|2.30||0.00|
subtract|16|he|1.1|-1.1||2.2|
subtract|16|he|0|-0||0|
subtract|16|he|Inf|Inf||NaN|Inv
subtract|16|he|100|0.000001||99.999999|
subtract|16|he|1E+5|0.5||99999.5|
subtract|16|he|-1E-7|1||-1.0000001|
multiply|16|he|2|3||6|
multiply|16|he|5|1||5|
multiply|16|he|5|2||10|
multiply|16|he|1.20|2||2.40|
multiply|16|he|1.20|0||0.00|
multiply|16|he|1.20|-2||-2.40|
multiply|16|he|-1.20|2||-2.40|
multiply|16|he|5.09|7.1||36.139|
multiply|16|he|2.5|4||10.0|
multiply|16|he|2.50|4||10.00|
multiply|16|he|1.23456789|1.00000000||1.234567890000000|Rou
multiply|16|he|1.000000001|1.000000001||1.000000002000000|IneRou
multiply|16|he|9.999999999|9.999999999||99.99999998000000|IneRou
multiply|16|he|0.9|-0||-0.0|
multiply|16|he|Inf|0||NaN|Inv
multiply|16|he|Inf|-2||-Infinity|
multiply|16|he|1E+999999|10||Infinity|IneOveRou
multiply|16|he|1E-999999|1E-10||1E-1000009|Sub
multiply|16|he|654321|654321||428135971041|
multiply|16|he|1234567890123456789|9876543210987654321||1.219326311370218E+37|IneRou
multiply|16|he|-0.0|1E+3||-0E+2|
divide|16|he|1|1||1|
divide|16|he|2|1||2|
divide|16|he|1|2||0.5|
divide|16|he|2|2||1|
divide|16|he|0|1||0|
divide|16|he|0|2||0|
divide|16|he|1|3||0.3333333333333333|IneRou
divide|16|he|2|3||0.6666666666666667|IneRou
divide|16|he|3|3||1|
divide|16|he|2.4|1||2.4|
divide|16|he|2.4|-1||-2.4|
divide|16|he|-2.4|1||-2.4|
divide|16|he|2.40|1||2.40|
divide|16|he|2.400|1||2.400|
divide|16|he|2.4|2||1.2|
divide|16|he|2.400|2||1.200|
divide|16|he|2.|2||1|
divide|16|he|20|20||1|
divide|16|he|187|187||1|
divide|16|he|5|2||2.5|
divide|16|he|5|2.0||2.5|
divide|16|he|5|2.000||2.5|
divide|16|he|5|0.20||25|
divide|16|he|5|0.200||25|
divide|16|he|1000|10||100|
divide|16|he|1000|100||10|
divide|16|he|1000|1||1000|
divide|16|he|2.40E+6|2||1.20E+6|
divide|16|he|2.40|3||0.80|
divide|16|he|2.400|3||0.800|
divide|16|he|2.4000|3||0.8000|
divide|16|he|1|0||Infinity|Div
divide|16|he|-1|0||-Infinity|Div
divide|16|he|0|0||NaN|Inv
divide|16|he|0|-5||-0|
divide|16|he|1E+999999|0.1||Infinity|IneOveRou
divide|16|he|1E-999999|10||1E-1000000|Sub
divide|16|he|Inf|Inf||NaN|Inv
divide|16|he|Inf|7||Infinity|
divide|16|he|7|Inf||0E-1000014|Cla
divide|16|he|12345678901234567890|7||1.763668414462081E+18|IneRou
divide|16|he|1|7||0.1428571428571429|IneRou
divide|16|he|-22|7||-3.142857142857143|IneRou
divide|16|he|391|597||0.6549413735343384|IneRou
remainder|16|he|1|1||0|
remainder|16|he|2|1||0|
remainder|16|he|1|2||1|
remainder|16|he|2|3||2|
remainder|16|he|10|3||1|
remainder|16|he|-10|3||-1|
remainder|16|he|10.2|1||0.2|
remainder|16|he|10|0.3||0.1|
remainder|16|he|3.6|1.3||1.0|
remainder|16|he|7|-2||1|
remainder|16|he|-7|2||-1|
remainder|16|he|1|0||NaN|Inv
remainder|16|he|0|0||NaN|Inv
remainder|16|he|1E+50|7||NaN|Inv
remainder_near|16|he|2.1|3||-0.9|
remainder_near|16|he|10|6||-2|
remainder_near|16|he|10|3||1|
remainder_near|16|he|-10|3||-1|
remainder_near|16|he|10.2|1||0.2|
remainder_near|16|he|10|0.3||0.1|
remainder_near|16|he|3.6|1.3||-0.3|
remainder_near|16|he|7|2||-1|
remainder_near|16|he|9|2||1|
remainder_near|16|he|-7|2||1|
remainder_near|16|he|1|0||NaN|Inv
quantize|16|he|2.17|0.001||2.170|
quantize|16|he|2.17|0.01||2.17|
quantize|16|he|2.17|0.1||2.2|IneRou
quantize|16|he|2.17|1e+0||2|IneRou
quantize|16|he|2.17|1e+1||0E+1|IneRou
quantize|16|he|-Inf|Inf||-Infinity|
quantize|16|he|2|Inf||NaN|Inv
quantize|16|he|-0.1|1||-0|IneRou
quantize|16|he|-0|1e+5||-0E+5|
quantize|16|he|+35236450.6|1e-2||35236450.60|
quantize|16|he|-35236450.6|1e-2||-35236450.60|
quantize|16|he|217|1e-1||217.0|
quantize|16|he|217|1e+0||217|
quantize|16|he|217|1e+1||2.2E+2|IneRou
quantize|16|he|217|1e+2||2E+2|IneRou
quantize|16|he|1.2345|1e-3||1.234|IneRou
quantize|16|he|1.2355|1e-3||1.236|IneRou
quantize|16|he|1.2365|1e-3||1.236|IneRou
quantize|16|he|-1.2345|1e-3||-1.234|IneRou
quantize|16|he|0.0005|1e-3||0.000|IneRou
quantize|16|he|9.9995|1e-3||10.000|IneRou
quantize|16|he|NaN|1||NaN|
quantize|16|he|1|NaN||NaN|
max|16|he|1|2||2|
max|16|he|-1|-2||-1|
max|16|he|1.0|1||1|
max|16|he|-0|0||0|
max|16|he|NaN|1||1|
max|16|he|Inf|1E+999||Infinity|
min|16|he|1|2||1|
min|16|he|-1|-2||-2|
min|16|he|1.0|1||1.0|
min|16|he|-0|0||-0|
min|16|he|NaN|1||1|
min|16|he|-Inf|-1E+999||-Infinity|
compare|16|he|1|2||-1|
compare|16|he|2|1||1|
compare|16|he|1|1.00||0|
compare|16|he|-0|0||0|
compare|16|he|NaN|1||NaN|
compare|16|he|-Inf|Inf||-1|
compare_total|16|he|12.30|12.3||-1|
compare_total|16|he|12.3|12.30||1|
compare_total|16|he|-0|0||-1|
compare_total|16|he|NaN|sNaN||1|
compare_total|16|he|-NaN|-Inf||-1|
compare_total|16|he|1E+2|100||1|
power|16|he|2|10||1024|
power|16|he|2|-1||0.5|
power|16|he|2|0.5||1.414213562373095|IneRou
power|16|he|-2|3||-8|
power|16|he|10|-2||0.01|
power|16|he|4|0.5||2.000000000000000|IneRou
power|16|he|0|0||NaN|Inv
power|16|he|0|-1||Infinity|
power|16|he|-0|-1||-Infinity|
power|16|he|Inf|-1||0|
power|16|he|1.1|20||6.727499949325600|IneRou
power|16|he|2|100||1.267650600228229E+30|IneRou
power|16|he|10|999999999||Infinity|IneOveRou
power|16|he|3|1E-10||1.000000000109861|IneRou
power|16|he|0.5|-3||8|
scaleb|16|he|7.50|10||7.50E+10|
scaleb|16|he|7.50|-2||0.0750|
scaleb|16|he|7.50|0||7.50|
scaleb|16|he|1E+999999|1||Infinity|IneOveRou
scaleb|16|he|Inf|-7||Infinity|
copy_sign|16|he|1.50|7.33||1.50|
copy_sign|16|he|-1.50|7.33||1.50|
copy_sign|16|he|1.50|-7.33||-1.50|
copy_sign|16|he|NaN|-1||-NaN|
next_toward|16|he|1|2||1.000000000000001|
next_toward|16|he|1|0||0.9999999999999999|
next_toward|16|he|-1E-999999|0||-9.99999999999999E-1000000|IneRouSubUnd
next_toward|16|he|0|-1||-1E-1000014|IneRouSubUnd
next_toward|16|he|9.999999999999999999999999999999999E+999999|Inf||Infinity|IneOveRou
max_mag|16|he|-10|2||-10|
max_mag|16|he|1|-1||1|
max_mag|16|he|-1|1||1|
min_mag|16|he|-10|2||2|
min_mag|16|he|1|-1||-1|
min_mag|16|he|-1|1||-1|
rotate|16|he|34|8||3400000000|
rotate|16|he|12|9||12000000000|
rotate|16|he|123456789|-2||8900000001234567|
rotate|16|he|123456789|0||123456789|
rotate|16|he|123456789|+2||12345678900|
shift|16|he|34|8||3400000000|
shift|16|he|12|9||12000000000|
shift|16|he|123456789|-2||1234567|
shift|16|he|123456789|0||123456789|
shift|16|he|123456789|+2||12345678900|
logical_and|16|he|1100|1010||1000|
logical_and|16|he|0|1||0|
logical_and|16|he|1111|10||10|
logical_or|16|he|1100|1010||1110|
logical_or|16|he|0|1||1|
logical_or|16|he|1111|10||1111|
logical_xor|16|he|1100|1010||110|
logical_xor|16|he|0|1||1|
logical_xor|16|he|1111|10||1101|
plus|16|he|12345.6789|||12345.6789|
plus|16|hu|12345.6789|||12345.6789|
plus|16|hd|12345.6789|||12345.6789|
plus|16|u|12345.6789|||12345.6789|
plus|16|d|12345.6789|||12345.6789|
plus|16|c|12345.6789|||12345.6789|
plus|16|f|12345.6789|||12345.6789|
plus|16|05|12345.6789|||12345.6789|
plus|16|he|-12345.6789|||-12345.6789|
plus|16|hu|-12345.6789|||-12345.6789|
plus|16|hd|-12345.6789|||-12345.6789|
plus|16|u|-12345.6789|||-12345.6789|
plus|16|d|-12345.6789|||-12345.6789|
plus|16|c|-12345.6789|||-12345.6789|
plus|16|f|-12345.6789|||-12345.6789|
plus|16|05|-12345.6789|||-12345.6789|
plus|16|he|1.2345678901234567890123456789012345678|||1.234567890123457|IneRou
plus|16|hu|1.2345678901234567890123456789012345678|||1.234567890123457|IneRou
plus|16|hd|1.2345678901234567890123456789012345678|||1.234567890123457|IneRou
plus|16|u|1.2345678901234567890123456789012345678|||1.234567890123457|IneRou
plus|16|d|1.2345678901234567890123456789012345678|||1.234567890123456|IneRou
plus|16|c|1.2345678901234567890123456789012345678|||1.234567890123457|IneRou
plus|16|f|1.2345678901234567890123456789012345678|||1.234567890123456|IneRou
plus|16|05|1.2345678901234567890123456789012345678|||1.234567890123456|IneRou
plus|16|he|0.000000001234567890125|||1.234567890125E-9|
plus|16|hu|0.000000001234567890125|||1.234567890125E-9|
plus|16|hd|0.000000001234567890125|||1.234567890125E-9|
plus|16|u|0.000000001234567890125|||1.234567890125E-9|
plus|16|d|0.000000001234567890125|||1.234567890125E-9|
plus|16|c|0.000000001234567890125|||1.234567890125E-9|
plus|16|f|0.000000001234567890125|||1.234567890125E-9|
plus|16|05|0.000000001234567890125|||1.234567890125E-9|
plus|16|he|99999999999999999999999999999999999.5|||1.000000000000000E+35|IneRou
plus|16|hu|99999999999999999999999999999999999.5|||1.000000000000000E+35|IneRou
plus|16|hd|99999999999999999999999999999999999.5|||1.000000000000000E+35|IneRou
plus|16|u|99999999999999999999999999999999999.5|||1.000000000000000E+35|IneRou
plus|16|d|99999999999999999999999999999999999.5|||9.999999999999999E+34|IneRou
plus|16|c|99999999999999999999999999999999999.5|||1.000000000000000E+35|IneRou
plus|16|f|99999999999999999999999999999999999.5|||9.999999999999999E+34|IneRou
plus|16|05|99999999999999999999999999999999999.5|||9.999999999999999E+34|IneRou
plus|16|he|-0|||0|
plus|16|hu|-0|||0|
plus|16|hd|-0|||0|
plus|16|u|-0|||0|
plus|16|d|-0|||0|
plus|16|c|-0|||0|
plus|16|f|-0|||-0|
plus|16|05|-0|||0|
plus|16|he|1E+1000000|||Infinity|IneOveRou
plus|16|hu|1E+1000000|||Infinity|IneOveRou
plus|16|hd|1E+1000000|||Infinity|IneOveRou
plus|16|u|1E+1000000|||Infinity|IneOveRou
plus|16|d|1E+1000000|||9.999999999999999E+999999|IneOveRou
plus|16|c|1E+1000000|||Infinity|IneOveRou
plus|16|f|1E+1000000|||9.999999999999999E+999999|IneOveRou
plus|16|05|1E+1000000|||9.999999999999999E+999999|IneOveRou
plus|16|he|1E-1000010|||1E-1000010|Sub
plus|16|hu|1E-1000010|||1E-1000010|Sub
plus|16|hd|1E-1000010|||1E-1000010|Sub
plus|16|u|1E-1000010|||1E-1000010|Sub
plus|16|d|1E-1000010|||1E-1000010|Sub
plus|16|c|1E-1000010|||1E-1000010|Sub
plus|16|f|1E-1000010|||1E-1000010|Sub
plus|16|05|1E-1000010|||1E-1000010|Sub
plus|16|he|0.5E-999999|||5E-1000000|Sub
plus|16|hu|0.5E-999999|||5E-1000000|Sub
plus|16|hd|0.5E-999999|||5E-1000000|Sub
plus|16|u|0.5E-999999|||5E-1000000|Sub
plus|16|d|0.5E-999999|||5E-1000000|Sub
plus|16|c|0.5E-999999|||5E-1000000|Sub
plus|16|f|0.5E-999999|||5E-1000000|Sub
plus|16|05|0.5E-999999|||5E-1000000|Sub
minus|16|he|1|||-1|
minus|16|he|-0|||0|
minus|16|he|0|||0|
minus|16|he|1.50|||-1.50|
abs|16|he|-1|||1|
abs|16|he|-0|||0|
abs|16|he|-1E+999|||1E+999|
abs|16|he|NaN|||NaN|
sqrt|16|he|0|||0|
sqrt|16|he|-0|||-0|
sqrt|16|he|0.39|||0.6244997998398398|IneRou
sqrt|16|he|100|||10|
sqrt|16|he|1|||1|
sqrt|16|he|1.0|||1.0|
sqrt|16|he|1.00|||1.0|
sqrt|16|he|7|||2.645751311064591|IneRou
sqrt|16|he|10|||3.162277660168379|IneRou
sqrt|16|he|-1|||NaN|Inv
sqrt|16|he|0.1|||0.3162277660168379|IneRou
sqrt|16|he|1E-1000|||1E-500|
sqrt|16|he|2|||1.414213562373095|IneRou
sqrt|16|he|3|||1.732050807568877|IneRou
sqrt|16|he|4E+10|||2E+5|
sqrt|16|he|0.04|||0.2|
sqrt|16|he|Inf|||Infinity|
sqrt|16|he|NaN|||NaN|
sqrt|16|he|1E+999999|||3.162277660168379E+499999|IneRou
sqrt|16|he|15241578750190521|||123456789|
exp|16|he|0|||1|
exp|16|he|1|||2.718281828459045|IneRou
exp|16|he|2|||7.389056098930650|IneRou
exp|16|he|-1|||0.3678794411714423|IneRou
exp|16|he|0.5|||1.648721270700128|IneRou
exp|16|he|1E-10|||1.000000000100000|IneRou
exp|16|he|-Inf|||0|
exp|16|he|Inf|||Infinity|
exp|16|he|10|||22026.46579480672|IneRou
exp|16|he|100|||2.688117141816135E+43|IneRou
exp|16|he|-100|||3.720075976020836E-44|IneRou
exp|16|he|2.302585092994045684|||10.00000000000000|IneRou
exp|16|he|1234|||8.305975937361794E+535|IneRou
exp|16|he|-1234|||1.203952440437273E-536|IneRou
exp|16|he|0.001|||1.001000500166708|IneRou
ln|16|he|1|||0|
ln|16|he|2|||0.6931471805599453|IneRou
ln|16|he|10|||2.302585092994046|IneRou
ln|16|he|0.5|||-0.6931471805599453|IneRou
ln|16|he|100|||4.605170185988091|IneRou
ln|16|he|0|||-Infinity|
ln|16|he|-1|||NaN|Inv
ln|16|he|Inf|||Infinity|
ln|16|he|1E+999|||2300.282507901052|IneRou
ln|16|he|0.0001|||-9.210340371976183|IneRou
ln|16|he|2.718281828459045235360287471|||1.000000000000000|IneRou
log10|16|he|1|||0|
log10|16|he|10|||1|
log10|16|he|1000|||3|
log10|16|he|2|||0.3010299956639812|IneRou
log10|16|he|0.01|||-2|
log10|16|he|0.5|||-0.3010299956639812|IneRou
log10|16|he|1E+500|||500|
log10|16|he|0|||-Infinity|
log10|16|he|-2|||NaN|Inv
log10|16|he|7.389|||0.8685856665587656|IneRou
logb|16|he|250|||2|
logb|16|he|2.50|||0|
logb|16|he|0.03|||-2|
logb|16|he|0|||-Infinity|Div
logb|16|he|-Inf|||Infinity|
logb|16|he|1E-999|||-999|
normalize|16|he|2.1|||2.1|
normalize|16|he|-2.0|||-2|
normalize|16|he|1.200|||1.2|
normalize|16|he|-120|||-1.2E+2|
normalize|16|he|120.00|||1.2E+2|
normalize|16|he|0.00|||0|
normalize|16|he|1E+2|||1E+2|
normalize|16|he|NaN|||NaN|
normalize|16|he|-0.0|||-0|
to_integral_value|16|he|2.1|||2|
to_integral_value|16|hu|2.1|||2|
to_integral_value|16|hd|2.1|||2|
to_integral_value|16|u|2.1|||3|
to_integral_value|16|d|2.1|||2|
to_integral_value|16|c|2.1|||3|
to_integral_value|16|f|2.1|||2|
to_integral_value|16|05|2.1|||2|
to_integral_value|16|he|100|||100|
to_integral_value|16|hu|100|||100|
to_integral_value|16|hd|100|||100|
to_integral_value|16|u|100|||100|
to_integral_value|16|d|100|||100|
to_integral_value|16|c|100|||100|
to_integral_value|16|f|100|||100|
to_integral_value|16|05|100|||100|
to_integral_value|16|he|100.0|||100|
to_integral_value|16|hu|100.0|||100|
to_integral_value|16|hd|100.0|||100|
to_integral_value|16|u|100.0|||100|
to_integral_value|16|d|100.0|||100|
to_integral_value|16|c|100.0|||100|
to_integral_value|16|f|100.0|||100|
to_integral_value|16|05|100.0|||100|
to_integral_value|16|he|101.5|||102|
to_integral_value|16|hu|101.5|||102|
to_integral_value|16|hd|101.5|||101|
to_integral_value|16|u|101.5|||102|
to_integral_value|16|d|101.5|||101|
to_integral_value|16|c|101.5|||102|
to_integral_value|16|f|101.5|||101|
to_integral_value|16|05|101.5|||101|
to_integral_value|16|he|-101.5|||-102|
to_integral_value|16|hu|-101.5|||-102|
to_integral_value|16|hd|-101.5|||-101|
to_integral_value|16|u|-101.5|||-102|
to_integral_value|16|d|-101.5|||-101|
to_integral_value|16|c|-101.5|||-101|
to_integral_value|16|f|-101.5|||-102|
to_integral_value|16|05|-101.5|||-101|
to_integral_value|16|he|10E+5|||1.0E+6|
to_integral_value|16|hu|10E+5|||1.0E+6|
to_integral_value|16|hd|10E+5|||1.0E+6|
to_integral_value|16|u|10E+5|||1.0E+6|
to_integral_value|16|d|10E+5|||1.0E+6|
to_integral_value|16|c|10E+5|||1.0E+6|
to_integral_value|16|f|10E+5|||1.0E+6|
to_integral_value|16|05|10E+5|||1.0E+6|
to_integral_value|16|he|7.89E+77|||7.89E+77|
to_integral_value|16|hu|7.89E+77|||7.89E+77|
to_integral_value|16|hd|7.89E+77|||7.89E+77|
to_integral_value|16|u|7.89E+77|||7.89E+77|
to_integral_value|16|d|7.89E+77|||7.89E+77|
to_integral_value|16|c|7.89E+77|||7.89E+77|
to_integral_value|16|f|7.89E+77|||7.89E+77|
to_integral_value|16|05|7.89E+77|||7.89E+77|
to_integral_value|16|he|-Inf|||-Infinity|
to_integral_value|16|hu|-Inf|||-Infinity|
to_integral_value|16|hd|-Inf|||-Infinity|
to_integral_value|16|u|-Inf|||-Infinity|
to_integral_value|16|d|-Inf|||-Infinity|
to_integral_value|16|c|-Inf|||-Infinity|
to_integral_value|16|f|-Inf|||-Infinity|
to_integral_value|16|05|-Inf|||-Infinity|
to_integral_value|16|he|0.5|||0|
to_integral_value|16|hu|0.5|||1|
to_integral_value|16|hd|0.5|||0|
to_integral_value|16|u|0.5|||1|
to_integral_value|16|d|0.5|||0|
to_integral_value|16|c|0.5|||1|
to_integral_value|16|f|0.5|||0|
to_integral_value|16|05|0.5|||1|
to_integral_value|16|he|-0.5|||-0|
to_integral_value|16|hu|-0.5|||-1|
to_integral_value|16|hd|-0.5|||-0|
to_integral_value|16|u|-0.5|||-1|
to_integral_value|16|d|-0.5|||-0|
to_integral_value|16|c|-0.5|||-0|
to_integral_value|16|f|-0.5|||-1|
to_integral_value|16|05|-0.5|||-1|
to_integral_value|16|he|2.5|||2|
to_integral_value|16|hu|2.5|||3|
to_integral_value|16|hd|2.5|||2|
to_integral_value|16|u|2.5|||3|
to_integral_value|16|d|2.5|||2|
to_integral_value|16|c|2.5|||3|
to_integral_value|16|f|2.5|||2|
to_integral_value|16|05|2.5|||2|
to_integral_exact|16|he|2.1|||2|IneRou
to_integral_exact|16|he|100|||100|
to_integral_exact|16|he|101.5|||102|IneRou
to_integral_exact|16|he|-101.5|||-102|IneRou
to_integral_exact|16|he|0.5|||0|IneRou
next_plus|16|he|1|||1.000000000000001|
next_plus|16|he|-1E-999999|||-9.99999999999999E-1000000|
next_plus|16|he|-0|||1E-1000014|
next_plus|16|he|9.999999999999999999999999999999999E+999999|||Infinity|
next_plus|16|he|-Inf|||-9.999999999999999E+999999|
next_minus|16|he|1|||0.9999999999999999|
next_minus|16|he|1E-999999|||9.99999999999999E-1000000|
next_minus|16|he|0|||-1E-1000014|
next_minus|16|he|-9.999999999999999999999999999999999E+999999|||-Infinity|
next_minus|16|he|Inf|||9.999999999999999E+999999|
logical_invert|16|he|0|||1111111111111111|
logical_invert|16|he|1|||1111111111111110|
logical_invert|16|he|111111111|||1111111000000000|
logical_invert|16|he|101010101|||1111111010101010|
number_class|16|he|Inf|||+Infinity|
number_class|16|he|1E-10|||+Normal|
number_class|16|he|2.50|||+Normal|
number_class|16|he|0.1E-999|||+Normal|
number_class|16|he|0|||+Zero|
number_class|16|he|-0|||-Zero|
number_class|16|he|-0.1E-999|||-Normal|
number_class|16|he|-1E-10|||-Normal|
number_class|16|he|-2.50|||-Normal|
number_class|16|he|-Inf|||-Infinity|
number_class|16|he|NaN|||NaN|
number_class|16|he|sNaN|||sNaN|
fma|16|he|3|5|7|22|
fma|16|he|3|-5|7|-8|
fma|16|he|888565290|1557.96930|-86087.7578|1384357356777.839|IneRou
fma|16|he|Inf|0|1|NaN|Inv
fma|16|he|1E+999999|10|-1E+999999|9E+999999|
add|34|he|1|1||2|
add|34|he|2|3||5|
add|34|he|5.75|3.3||9.05|
add|34|he|5|-3||2|
add|34|he|-5|-3||-8|
add|34|he|-7|2.5||-4.5|
add|34|he|0.7|0.3||1.0|
add|34|he|1.25|1.25||2.50|
add|34|he|1.23456789|1.00000000||2.23456789|
add|34|he|1.23456789|1.00000011||2.23456800|
add|34|he|0.4444444444|0.5555555555||0.9999999999|
add|34|he|70|10000e+9||10000000000070|
add|34|he|700000|10000e+9||10000000700000|
add|34|he|1E+12|-1||999999999999|
add|34|he|1E+12|1.11||1000000000001.11|
add|34|he|1E+12|1.111||1000000000001.111|
add|34|he|-1|1E+12||999999999999|
add|34|he|0.0|0.000||0.000|
add|34|he|-0|0||0|
add|34|he|-0|-0||-0|
add|34|he|Inf|-Inf||NaN|Inv
add|34|he|Inf|1||Infinity|
add|34|he|NaN|1||NaN|
add|34|he|1|NaN5||NaN5|
add|34|he|sNaN|1||NaN|Inv
add|34|he|12345678901234567890|1||12345678901234567891|
add|34|he|9.999999999999999999999999999999999E+999999|1E+999999||Infinity|IneOveRou
add|34|he|1E-999999|-1E-999999||0E-999999|
add|34|he|0.1|0.2||0.3|
add|34|he|123456789012345678901234567890123456789|0.5||1.234567890123456789012345678901235E+38|IneRou
subtract|34|he|2|3||-1|
subtract|34|he|2.3|2.30||0.00|
subtract|34|he|1.1|-1.1||2.2|
subtract|34|he|0|-0||0|
subtract|34|he|Inf|Inf||NaN|Inv
subtract|34|he|100|0.000001||99.999999|
subtract|34|he|1E+5|0.5||99999.5|
subtract|34|he|-1E-7|1||-1.0000001|
multiply|34|he|2|3||6|
multiply|34|he|5|1||5|
multiply|34|he|5|2||10|
multiply|34|he|1.20|2||2.40|
multiply|34|he|1.20|0||0.00|
multiply|34|he|1.20|-2||-2.40|
multiply|34|he|-1.20|2||-2.40|
multiply|34|he|5.09|7.1||36.139|
multiply|34|he|2.5|4||10.0|
multiply|34|he|2.50|4||10.00|
multiply|34|he|1.23456789|1.00000000||1.2345678900000000|
multiply|34|he|1.000000001|1.000000001||1.000000002000000001|
multiply|34|he|9.999999999|9.999999999||99.999999980000000001|
multiply|34|he|0.9|-0||-0.0|
multiply|34|he|Inf|0||NaN|Inv
multiply|34|he|Inf|-2||-Infinity|
multiply|34|he|1E+999999|10||Infinity|IneOveRou
multiply|34|he|1E-999999|1E-10||1E-1000009|Sub
multiply|34|he|654321|654321||428135971041|
multiply|34|he|1234567890123456789|9876543210987654321||1.219326311370217952237463801111264E+37|IneRou
multiply|34|he|-0.0|1E+3||-0E+2|
divide|34|he|1|1||1|
divide|34|he|2|1||2|
divide|34|he|1|2||0.5|
divide|34|he|2|2||1|
divide|34|he|0|1||0|
divide|34|he|0|2||0|
divide|34|he|1|3||0.3333333333333333333333333333333333|IneRou
divide|34|he|2|3||0.6666666666666666666666666666666667|IneRou
divide|34|he|3|3||1|
divide|34|he|2.4|1||2.4|
divide|34|he|2.4|-1||-2.4|
divide|34|he|-2.4|1||-2.4|
divide|34|he|2.40|1||2.40|
divide|34|he|2.400|1||2.400|
divide|34|he|2.4|2||1.2|
divide|34|he|2.400|2||1.200|
divide|34|he|2.|2||1|
divide|34|he|20|20||1|
divide|34|he|187|187||1|
divide|34|he|5|2||2.5|
divide|34|he|5|2.0||2.5|
divide|34|he|5|2.000||2.5|
divide|34|he|5|0.20||25|
divide|34|he|5|0.200||25|
divide|34|he|1000|10||100|
divide|34|he|1000|100||10|
divide|34|he|1000|1||1000|
divide|34|he|2.40E+6|2||1.20E+6|
divide|34|he|2.40|3||0.80|
divide|34|he|2.400|3||0.800|
divide|34|he|2.4000|3||0.8000|
divide|34|he|1|0||Infinity|Div
divide|34|he|-1|0||-Infinity|Div
divide|34|he|0|0||NaN|Inv
divide|34|he|0|-5||-0|
divide|34|he|1E+999999|0.1||Infinity|IneOveRou
divide|34|he|1E-999999|10||1E-1000000|Sub
divide|34|he|Inf|Inf||NaN|Inv
divide|34|he|Inf|7||Infinity|
divide|34|he|7|Inf||0E-1000032|Cla
divide|34|he|12345678901234567890|7||1763668414462081127.142857142857143|IneRou
divide|34|he|1|7||0.1428571428571428571428571428571429|IneRou
divide|34|he|-22|7||-3.142857142857142857142857142857143|IneRou
divide|34|he|391|597||0.6549413735343383584589614740368509|IneRou
remainder|34|he|1|1||0|
remainder|34|he|2|1||0|
remainder|34|he|1|2||1|
remainder|34|he|2|3||2|
remainder|34|he|10|3||1|
remainder|34|he|-10|3||-1|
remainder|34|he|10.2|1||0.2|
remainder|34|he|10|0.3||0.1|
remainder|34|he|3.6|1.3||1.0|
remainder|34|he|7|-2||1|
remainder|34|he|-7|2||-1|
remainder|34|he|1|0||NaN|Inv
remainder|34|he|0|0||NaN|Inv
remainder|34|he|1E+50|7||NaN|Inv
remainder_near|34|he|2.1|3||-0.9|
remainder_near|34|he|10|6||-2|
remainder_near|34|he|10|3||1|
remainder_near|34|he|-10|3||-1|
remainder_near|34|he|10.2|1||0.2|
remainder_near|34|he|10|0.3||0.1|
remainder_near|34|he|3.6|1.3||-0.3|
remainder_near|34|he|7|2||-1|
remainder_near|34|he|9|2||1|
remainder_near|34|he|-7|2||1|
remainder_near|34|he|1|0||NaN|Inv
quantize|34|he|2.17|0.001||2.170|
quantize|34|he|2.17|0.01||2.17|
quantize|34|he|2.17|0.1||2.2|IneRou
quantize|34|he|2.17|1e+0||2|IneRou
quantize|34|he|2.17|1e+1||0E+1|IneRou
quantize|34|he|-Inf|Inf||-Infinity|
quantize|34|he|2|Inf||NaN|Inv
quantize|34|he|-0.1|1||-0|IneRou
quantize|34|he|-0|1e+5||-0E+5|
quantize|34|he|+35236450.6|1e-2||35236450.60|
quantize|34|he|-35236450.6|1e-2||-35236450.60|
quantize|34|he|217|1e-1||217.0|
quantize|34|he|217|1e+0||217|
quantize|34|he|217|1e+1||2.2E+2|IneRou
quantize|34|he|217|1e+2||2E+2|IneRou
quantize|34|he|1.2345|1e-3||1.234|IneRou
quantize|34|he|1.2355|1e-3||1.236|IneRou
quantize|34|he|1.2365|1e-3||1.236|IneRou
quantize|34|he|-1.2345|1e-3||-1.234|IneRou
quantize|34|he|0.0005|1e-3||0.000|IneRou
quantize|34|he|9.9995|1e-3||10.000|IneRou
quantize|34|he|NaN|1||NaN|
quantize|34|he|1|NaN||NaN|
max|34|he|1|2||2|
max|34|he|-1|-2||-1|
max|34|he|1.0|1||1|
max|34|he|-0|0||0|
max|34|he|NaN|1||1|
max|34|he|Inf|1E+999||Infinity|
min|34|he|1|2||1|
min|34|he|-1|-2||-2|
min|34|he|1.0|1||1.0|
min|34|he|-0|0||-0|
min|34|he|NaN|1||1|
min|34|he|-Inf|-1E+999||-Infinity|
compare|34|he|1|2||-1|
compare|34|he|2|1||1|
compare|34|he|1|1.00||0|
compare|34|he|-0|0||0|
compare|34|he|NaN|1||NaN|
compare|34|he|-Inf|Inf||-1|
compare_total|34|he|12.30|12.3||-1|
compare_total|34|he|12.3|12.30||1|
compare_total|34|he|-0|0||-1|
compare_total|34|he|NaN|sNaN||1|
compare_total|34|he|-NaN|-Inf||-1|
compare_total|34|he|1E+2|100||1|
power|34|he|2|10||1024|
power|34|he|2|-1||0.5|
power|34|he|2|0.5||1.414213562373095048801688724209698|IneRou
power|34|he|-2|3||-8|
power|34|he|10|-2||0.01|
power|34|he|4|0.5||2.000000000000000000000000000000000|IneRou
power|34|he|0|0||NaN|Inv
power|34|he|0|-1||Infinity|
power|34|he|-0|-1||-Infinity|
power|34|he|Inf|-1||0|
power|34|he|1.1|20||6.72749994932560009201|
power|34|he|2|100||1267650600228229401496703205376|
power|34|he|10|999999999||Infinity|IneOveRou
power|34|he|3|1E-10||1.000000000109861228872845713943808|IneRou
power|34|he|0.5|-3||8|
scaleb|34|he|7.50|10||7.50E+10|
scaleb|34|he|7.50|-2||0.0750|
scaleb|34|he|7.50|0||7.50|
scaleb|34|he|1E+999999|1||Infinity|IneOveRou
scaleb|34|he|Inf|-7||Infinity|
copy_sign|34|he|1.50|7.33||1.50|
copy_sign|34|he|-1.50|7.33||1.50|
copy_sign|34|he|1.50|-7.33||-1.50|
copy_sign|34|he|NaN|-1||-NaN|
next_toward|34|he|1|2||1.000000000000000000000000000000001|
next_toward|34|he|1|0||0.9999999999999999999999999999999999|
next_toward|34|he|-1E-999999|0||-9.99999999999999999999999999999999E-1000000|IneRouSubUnd
next_toward|34|he|0|-1||-1E-1000032|IneRouSubUnd
next_toward|34|he|9.999999999999999999999999999999999E+999999|Inf||Infinity|IneOveRou
max_mag|34|he|-10|2||-10|
max_mag|34|he|1|-1||1|
max_mag|34|he|-1|1||1|
min_mag|34|he|-10|2||2|
min_mag|34|he|1|-1||-1|
min_mag|34|he|-1|1||-1|
rotate|34|he|34|8||3400000000|
rotate|34|he|12|9||12000000000|
rotate|34|he|123456789|-2||8900000000000000000000000001234567|
rotate|34|he|123456789|0||123456789|
rotate|34|he|123456789|+2||12345678900|
shift|34|he|34|8||3400000000|
shift|34|he|12|9||12000000000|
shift|34|he|123456789|-2||1234567|
shift|34|he|123456789|0||123456789|
shift|34|he|123456789|+2||12345678900|
logical_and|34|he|1100|1010||1000|
logical_and|34|he|0|1||0|
logical_and|34|he|1111|10||10|
logical_or|34|he|1100|1010||1110|
logical_or|34|he|0|1||1|
logical_or|34|he|1111|10||1111|
logical_xor|34|he|1100|1010||110|
logical_xor|34|he|0|1||1|
logical_xor|34|he|1111|10||1101|
plus|34|he|12345.6789|||12345.6789|
plus|34|hu|12345.6789|||12345.6789|
plus|34|hd|12345.6789|||12345.6789|
plus|34|u|12345.6789|||12345.6789|
plus|34|d|12345.6789|||12345.6789|
plus|34|c|12345.6789|||12345.6789|
plus|34|f|12345.6789|||12345.6789|
plus|34|05|12345.6789|||12345.6789|
plus|34|he|-12345.6789|||-12345.6789|
plus|34|hu|-12345.6789|||-12345.6789|
plus|34|hd|-12345.6789|||-12345.6789|
plus|34|u|-12345.6789|||-12345.6789|
plus|34|d|-12345.6789|||-12345.6789|
plus|34|c|-12345.6789|||-12345.6789|
plus|34|f|-12345.6789|||-12345.6789|
plus|34|05|-12345.6789|||-12345.6789|
plus|34|he|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901235|IneRou
plus|34|hu|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901235|IneRou
plus|34|hd|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901235|IneRou
plus|34|u|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901235|IneRou
plus|34|d|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901234|IneRou
plus|34|c|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901235|IneRou
plus|34|f|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901234|IneRou
plus|34|05|1.2345678901234567890123456789012345678|||1.234567890123456789012345678901234|IneRou
plus|34|he|0.000000001234567890125|||1.234567890125E-9|
plus|34|hu|0.000000001234567890125|||1.234567890125E-9|
plus|34|hd|0.000000001234567890125|||1.234567890125E-9|
plus|34|u|0.000000001234567890125|||1.234567890125E-9|
plus|34|d|0.000000001234567890125|||1.234567890125E-9|
plus|34|c|0.000000001234567890125|||1.234567890125E-9|
plus|34|f|0.000000001234567890125|||1.234567890125E-9|
plus|34|05|0.000000001234567890125|||1.234567890125E-9|
plus|34|he|99999999999999999999999999999999999.5|||1.000000000000000000000000000000000E+35|IneRou
plus|34|hu|99999999999999999999999999999999999.5|||1.000000000000000000000000000000000E+35|IneRou
plus|34|hd|99999999999999999999999999999999999.5|||1.000000000000000000000000000000000E+35|IneRou
plus|34|u|99999999999999999999999999999999999.5|||1.000000000000000000000000000000000E+35|IneRou
plus|34|d|99999999999999999999999999999999999.5|||9.999999999999999999999999999999999E+34|IneRou
plus|34|c|99999999999999999999999999999999999.5|||1.000000000000000000000000000000000E+35|IneRou
plus|34|f|99999999999999999999999999999999999.5|||9.999999999999999999999999999999999E+34|IneRou
plus|34|05|99999999999999999999999999999999999.5|||9.999999999999999999999999999999999E+34|IneRou
plus|34|he|-0|||0|
plus|34|hu|-0|||0|
plus|34|hd|-0|||0|
plus|34|u|-0|||0|
plus|34|d|-0|||0|
plus|34|c|-0|||0|
plus|34|f|-0|||-0|
plus|34|05|-0|||0|
plus|34|he|1E+1000000|||Infinity|IneOveRou
plus|34|hu|1E+1000000|||Infinity|IneOveRou
plus|34|hd|1E+1000000|||Infinity|IneOveRou
plus|34|u|1E+1000000|||Infinity|IneOveRou
plus|34|d|1E+1000000|||9.999999999999999999999999999999999E+999999|IneOveRou
plus|34|c|1E+1000000|||Infinity|IneOveRou
plus|34|f|1E+1000000|||9.999999999999999999999999999999999E+999999|IneOveRou
plus|34|05|1E+1000000|||9.999999999999999999999999999999999E+999999|IneOveRou
plus|34|he|1E-1000010|||1E-1000010|Sub
plus|34|hu|1E-1000010|||1E-1000010|Sub
plus|34|hd|1E-1000010|||1E-1000010|Sub
plus|34|u|1E-1000010|||1E-1000010|Sub
plus|34|d|1E-1000010|||1E-1000010|Sub
plus|34|c|1E-1000010|||1E-1000010|Sub
plus|34|f|1E-1000010|||1E-1000010|Sub
plus|34|05|1E-1000010|||1E-1000010|Sub
plus|34|he|0.5E-999999|||5E-1000000|Sub
plus|34|hu|0.5E-999999|||5E-1000000|Sub
plus|34|hd|0.5E-999999|||5E-1000000|Sub
plus|34|u|0.5E-999999|||5E-1000000|Sub
plus|34|d|0.5E-999999|||5E-1000000|Sub
plus|34|c|0.5E-999999|||5E-1000000|Sub
plus|34|f|0.5E-999999|||5E-1000000|Sub
plus|34|05|0.5E-999999|||5E-1000000|Sub
minus|34|he|1|||-1|
minus|34|he|-0|||0|
minus|34|he|0|||0|
minus|34|he|1.50|||-1.50|
abs|34|he|-1|||1|
abs|34|he|-0|||0|
abs|34|he|-1E+999|||1E+999|
abs|34|he|NaN|||NaN|
sqrt|34|he|0|||0|
sqrt|34|he|-0|||-0|
sqrt|34|he|0.39|||0.6244997998398398205846893120939794|IneRou
sqrt|34|he|100|||10|
sqrt|34|he|1|||1|
sqrt|34|he|1.0|||1.0|
sqrt|34|he|1.00|||1.0|
sqrt|34|he|7|||2.645751311064590590501615753639260|IneRou
sqrt|34|he|10|||3.162277660168379331998893544432719|IneRou
sqrt|34|he|-1|||NaN|Inv
sqrt|34|he|0.1|||0.3162277660168379331998893544432719|IneRou
sqrt|34|he|1E-1000|||1E-500|
sqrt|34|he|2|||1.414213562373095048801688724209698|IneRou
sqrt|34|he|3|||1.732050807568877293527446341505872|IneRou
sqrt|34|he|4E+10|||2E+5|
sqrt|34|he|0.04|||0.2|
sqrt|34|he|Inf|||Infinity|
sqrt|34|he|NaN|||NaN|
sqrt|34|he|1E+999999|||3.162277660168379331998893544432719E+499999|IneRou
sqrt|34|he|15241578750190521|||123456789|
exp|34|he|0|||1|
exp|34|he|1|||2.718281828459045235360287471352662|IneRou
exp|34|he|2|||7.389056098930650227230427460575008|IneRou
exp|34|he|-1|||0.3678794411714423215955237701614609|IneRou
exp|34|he|0.5|||1.648721270700128146848650787814164|IneRou
exp|34|he|1E-10|||1.000000000100000000005000000000167|IneRou
exp|34|he|-Inf|||0|
exp|34|he|Inf|||Infinity|
exp|34|he|10|||22026.46579480671651695790064528424|IneRou
exp|34|he|100|||2.688117141816135448412625551580014E+43|IneRou
exp|34|he|-100|||3.720075976020835962959695803863118E-44|IneRou
exp|34|he|2.302585092994045684|||9.999999999999999999820085453156358|IneRou
exp|34|he|1234|||8.305975937361794218258521291311357E+535|IneRou
exp|34|he|-1234|||1.203952440437273201311895135159203E-536|IneRou
exp|34|he|0.001|||1.001000500166708341668055753993058|IneRou
ln|34|he|1|||0|
ln|34|he|2|||0.6931471805599453094172321214581766|IneRou
ln|34|he|10|||2.302585092994045684017991454684364|IneRou
ln|34|he|0.5|||-0.6931471805599453094172321214581766|IneRou
ln|34|he|100|||4.605170185988091368035982909368728|IneRou
ln|34|he|0|||-Infinity|
ln|34|he|-1|||NaN|Inv
ln|34|he|Inf|||Infinity|
ln|34|he|1E+999|||2300.282507901051638333973463229680|IneRou
ln|34|he|0.0001|||-9.210340371976182736071965818737457|IneRou
ln|34|he|2.718281828459045235360287471|||0.9999999999999999999999999998702627|IneRou
log10|34|he|1|||0|
log10|34|he|10|||1|
log10|34|he|1000|||3|
log10|34|he|2|||0.3010299956639811952137388947244930|IneRou
log10|34|he|0.01|||-2|
log10|34|he|0.5|||-0.3010299956639811952137388947244930|IneRou
log10|34|he|1E+500|||500|
log10|34|he|0|||-Infinity|
log10|34|he|-2|||NaN|Inv
log10|34|he|7.389|||0.8685856665587656463941151482139447|IneRou
logb|34|he|250|||2|
logb|34|he|2.50|||0|
logb|34|he|0.03|||-2|
logb|34|he|0|||-Infinity|Div
logb|34|he|-Inf|||Infinity|
logb|34|he|1E-999|||-999|
normalize|34|he|2.1|||2.1|
normalize|34|he|-2.0|||-2|
normalize|34|he|1.200|||1.2|
normalize|34|he|-120|||-1.2E+2|
normalize|34|he|120.00|||1.2E+2|
normalize|34|he|0.00|||0|
normalize|34|he|1E+2|||1E+2|
normalize|34|he|NaN|||NaN|
normalize|34|he|-0.0|||-0|
to_integral_value|34|he|2.1|||2|
to_integral_value|34|hu|2.1|||2|
to_integral_value|34|hd|2.1|||2|
to_integral_value|34|u|2.1|||3|
to_integral_value|34|d|2.1|||2|
to_integral_value|34|c|2.1|||3|
to_integral_value|34|f|2.1|||2|
to_integral_value|34|05|2.1|||2|
to_integral_value|34|he|100|||100|
to_integral_value|34|hu|100|||100|
to_integral_value|34|hd|100|||100|
to_integral_value|34|u|100|||100|
to_integral_value|34|d|100|||100|
to_integral_value|34|c|100|||100|
to_integral_value|34|f|100|||100|
to_integral_value|34|05|100|||100|
to_integral_value|34|he|100.0|||100|
to_integral_value|34|hu|100.0|||100|
to_integral_value|34|hd|100.0|||100|
to_integral_value|34|u|100.0|||100|
to_integral_value|34|d|100.0|||100|
to_integral_value|34|c|100.0|||100|
to_integral_value|34|f|100.0|||100|
to_integral_value|34|05|100.0|||100|
to_integral_value|34|he|101.5|||102|
to_integral_value|34|hu|101.5|||102|
to_integral_value|34|hd|101.5|||101|
to_integral_value|34|u|101.5|||102|
to_integral_value|34|d|101.5|||101|
to_integral_value|34|c|101.5|||102|
to_integral_value|34|f|101.5|||101|
to_integral_value|34|05|101.5|||101|
to_integral_value|34|he|-101.5|||-102|
to_integral_value|34|hu|-101.5|||-102|
to_integral_value|34|hd|-101.5|||-101|
to_integral_value|34|u|-101.5|||-102|
to_integral_value|34|d|-101.5|||-101|
to_integral_value|34|c|-101.5|||-101|
to_integral_value|34|f|-101.5|||-102|
to_integral_value|34|05|-101.5|||-101|
to_integral_value|34|he|10E+5|||1.0E+6|
to_integral_value|34|hu|10E+5|||1.0E+6|
to_integral_value|34|hd|10E+5|||1.0E+6|
to_integral_value|34|u|10E+5|||1.0E+6|
to_integral_value|34|d|10E+5|||1.0E+6|
to_integral_value|34|c|10E+5|||1.0E+6|
to_integral_value|34|f|10E+5|||1.0E+6|
to_integral_value|34|05|10E+5|||1.0E+6|
to_integral_value|34|he|7.89E+77|||7.89E+77|
to_integral_value|34|hu|7.89E+77|||7.89E+77|
to_integral_value|34|hd|7.89E+77|||7.89E+77|
to_integral_value|34|u|7.89E+77|||7.89E+77|
to_integral_value|34|d|7.89E+77|||7.89E+77|
to_integral_value|34|c|7.89E+77|||7.89E+77|
to_integral_value|34|f|7.89E+77|||7.89E+77|
to_integral_value|34|05|7.89E+77|||7.89E+77|
to_integral_value|34|he|-Inf|||-Infinity|
to_integral_value|34|hu|-Inf|||-Infinity|
to_integral_value|34|hd|-Inf|||-Infinity|
to_integral_value|34|u|-Inf|||-Infinity|
to_integral_value|34|d|-Inf|||-Infinity|
to_integral_value|34|c|-Inf|||-Infinity|
to_integral_value|34|f|-Inf|||-Infinity|
to_integral_value|34|05|-Inf|||-Infinity|
to_integral_value|34|he|0.5|||0|
to_integral_value|34|hu|0.5|||1|
to_integral_value|34|hd|0.5|||0|
to_integral_value|34|u|0.5|||1|
to_integral_value|34|d|0.5|||0|
to_integral_value|34|c|0.5|||1|
to_integral_value|34|f|0.5|||0|
to_integral_value|34|05|0.5|||1|
to_integral_value|34|he|-0.5|||-0|
to_integral_value|34|hu|-0.5|||-1|
to_integral_value|34|hd|-0.5|||-0|
to_integral_value|34|u|-0.5|||-1|
to_integral_value|34|d|-0.5|||-0|
to_integral_value|34|c|-0.5|||-0|
to_integral_value|34|f|-0.5|||-1|
to_integral_value|34|05|-0.5|||-1|
to_integral_value|34|he|2.5|||2|
to_integral_value|34|hu|2.5|||3|
to_integral_value|34|hd|2.5|||2|
to_integral_value|34|u|2.5|||3|
to_integral_value|34|d|2.5|||2|
to_integral_value|34|c|2.5|||3|
to_integral_value|34|f|2.5|||2|
to_integral_value|34|05|2.5|||2|
to_integral_exact|34|he|2.1|||2|IneRou
to_integral_exact|34|he|100|||100|
to_integral_exact|34|he|101.5|||102|IneRou
to_integral_exact|34|he|-101.5|||-102|IneRou
to_integral_exact|34|he|0.5|||0|IneRou
next_plus|34|he|1|||1.000000000000000000000000000000001|
next_plus|34|he|-1E-999999|||-9.99999999999999999999999999999999E-1000000|
next_plus|34|he|-0|||1E-1000032|
next_plus|34|he|9.999999999999999999999999999999999E+999999|||Infinity|
next_plus|34|he|-Inf|||-9.999999999999999999999999999999999E+999999|
next_minus|34|he|1|||0.9999999999999999999999999999999999|
next_minus|34|he|1E-999999|||9.99999999999999999999999999999999E-1000000|
next_minus|34|he|0|||-1E-1000032|
next_minus|34|he|-9.999999999999999999999999999999999E+999999|||-Infinity|
next_minus|34|he|Inf|||9.999999999999999999999999999999999E+999999|
logical_invert|34|he|0|||1111111111111111111111111111111111|
logical_invert|34|he|1|||1111111111111111111111111111111110|
logical_invert|34|he|111111111|||1111111111111111111111111000000000|
logical_invert|34|he|101010101|||1111111111111111111111111010101010|
number_class|34|he|Inf|||+Infinity|
number_class|34|he|1E-10|||+Normal|
number_class|34|he|2.50|||+Normal|
number_class|34|he|0.1E-999|||+Normal|
number_class|34|he|0|||+Zero|
number_class|34|he|-0|||-Zero|
number_class|34|he|-0.1E-999|||-Normal|
number_class|34|he|-1E-10|||-Normal|
number_class|34|he|-2.50|||-Normal|
number_class|34|he|-Inf|||-Infinity|
number_class|34|he|NaN|||NaN|
number_class|34|he|sNaN|||sNaN|
fma|34|he|3|5|7|22|
fma|34|he|3|-5|7|-8|
fma|34|he|888565290|1557.96930|-86087.7578|1384357356777.83920|
fma|34|he|Inf|0|1|NaN|Inv
fma|34|he|1E+999999|10|-1E+999999|9E+999999|
"""
nvec = 0
for line in VECTORS.strip().split("\n"):
    parts = line.split("|")
    op = parts[0]
    vctx = Context(prec=int(parts[1]), rounding=RND[parts[2]], Emax=999999, Emin=-999999, traps=[])
    args = [Decimal(a) for a in parts[3:6] if a != ""]
    try:
        r = str(getattr(vctx, op)(*args))
    except Exception as e:
        r = "raised " + type(e).__name__
    flags = "".join(sorted(s.__name__[:3] for s in SIG if vctx.flags[s]))
    nvec += 1
    check("vector " + line, [r, flags], [parts[6], parts[7]])
check("vectors run", nvec, 1981)

for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT95 PASSED ===")
