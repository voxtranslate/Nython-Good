# nython: module    (import it by name: it runs in a module scope of its own)
# lib/fractions.ny - Python's fractions (3.12): exact rational numbers.
#
#     from fractions import Fraction
#     Fraction(3, 4) + Fraction("1/4")       # Fraction(1, 1)
#     Fraction(0.1)                          # Fraction(3602879701896397, 36028797018963968)
#     Fraction("3.1415").limit_denominator(100)
#
# Fraction is built from an int, another Fraction (or any object with
# numerator/denominator), a float (exactly, via as_integer_ratio), a string
# ("3/4", " -1.5e3 ", "1_000.25", with Python's grammar) or two rationals;
# it is kept in lowest terms with a positive denominator. Arithmetic with
# ints and Fractions is exact (+ - * / // % divmod, ** with an integer
# power); with a float it is float arithmetic, with a complex complex
# arithmetic, as Python's. Comparisons are exact against ints, Fractions
# and floats; hash() equals the hash of an equal int or float. round,
# math.floor/ceil/trunc, int(), float() (correctly rounded), str/repr,
# limit_denominator, from_float, from_decimal, as_integer_ratio,
# is_integer, and format specs (e E f F g G %, fill, align, sign, z, #,
# 0, width, grouping, precision - 3.12's __format__).
#
# Differences from Python, all from the runtime rather than the module:
#   - Nython has no NotImplemented: an operator given an unknown type calls
#     that type's reflected method itself when it has one (what Python's
#     protocol would do), else raises Python's TypeError.
#   - Fractions as dict keys are looked up by identity (sets use __hash__);
#     d[Fraction(1, 2)] does not find a key stored as 0.5.
#   - Decimal does not exist yet: from_decimal takes any object with
#     as_integer_ratio().
#   - Fraction is a numbers.Rational by registration (round 77), not by
#     deriving from it as in CPython: isinstance(Fraction(1, 3),
#     numbers.Rational) holds, but Rational is not in Fraction.__mro__
#     and making a Fraction does not go through ABCMeta.
import math

__all__ = ["Fraction"]

_PyHASH_MODULUS = 2305843009213693951     # 2**61 - 1, sys.hash_info.modulus
_PyHASH_INF = 314159


def _tn(x):
    # the type's name as Python spells it
    var n = type(x).__name__
    if n == "string":
        return "str"
    if n == "map":
        return "dict"
    if n == "none":
        return "NoneType"
    return n


def _is_rational(x):
    if isinstance(x, int) or isinstance(x, Fraction):
        return true
    if isinstance(x, float) or isinstance(x, str) or isinstance(x, complex):
        return false
    return hasattr(x, "numerator") and hasattr(x, "denominator")


def _num_den(x):
    # (numerator, denominator) of an int, a Fraction or another rational
    if isinstance(x, Fraction):
        return (x._numerator, x._denominator)
    if isinstance(x, int):
        return (int(x), 1)
    return (x.numerator, x.denominator)


def _digits_end(s, i):
    # the end of \d+(_\d+)* starting at i (i itself when there is none)
    var n = len(s)
    var j = i
    if j >= n or not s[j].isdigit():
        return i
    while j < n and s[j].isdigit():
        j = j + 1
    while j + 1 < n and s[j] == "_" and s[j + 1].isdigit():
        j = j + 1
        while j < n and s[j].isdigit():
            j = j + 1
    return j


def _parse(text):
    # Python's _RATIONAL_FORMAT: [sign] (num [/ denom] | [num] [. dec] [e exp]),
    # whitespace around; returns (numerator, denominator) or None
    var s = text.strip()
    var n = len(s)
    var i = 0
    var neg = false
    if i < n and (s[i] == "+" or s[i] == "-"):
        neg = s[i] == "-"
        i = i + 1
    if not (i < n and (s[i].isdigit() or (s[i] == "." and i + 1 < n and s[i + 1].isdigit()))):
        return None
    var j = _digits_end(s, i)
    var num = int(s[i:j].replace("_", "")) if j > i else 0
    var den = 1
    i = j
    # a denominator, with optional whitespace around the slash (3.12)
    var k = i
    while k < n and s[k].isspace():
        k = k + 1
    if k < n and s[k] == "/":
        k = k + 1
        while k < n and s[k].isspace():
            k = k + 1
        j = _digits_end(s, k)
        if j == k or j != n:
            return None
        den = int(s[k:j].replace("_", ""))
        if neg:
            num = -num
        return (num, den)
    if i < n and s[i] == ".":
        i = i + 1
        j = _digits_end(s, i)
        if j > i:
            var dec = s[i:j].replace("_", "")
            var scale = 10 ** len(dec)
            num = num * scale + int(dec)
            den = den * scale
        i = j
    if i < n and (s[i] == "e" or s[i] == "E"):
        i = i + 1
        var eneg = false
        if i < n and (s[i] == "+" or s[i] == "-"):
            eneg = s[i] == "-"
            i = i + 1
        j = _digits_end(s, i)
        if j == i:
            return None
        var ex = int(s[i:j].replace("_", ""))
        i = j
        if eneg:
            den = den * 10 ** ex
        else:
            num = num * 10 ** ex
    if i != n:
        return None
    if neg:
        num = -num
    return (num, den)


def _raw(n, d):
    # a Fraction from coprime n and d > 0, without normalising again
    var f = Fraction(0)
    f._numerator = n
    f._denominator = d
    return f


# ── the rational operations, on numerators and denominators ─────────────────
def _add(na, da, nb, db):
    var g = math.gcd(da, db)
    if g == 1:
        return _raw(na * db + da * nb, da * db)
    var s = da // g
    var t = na * (db // g) + nb * s
    var g2 = math.gcd(t, g)
    if g2 == 1:
        return _raw(t, s * db)
    return _raw(t // g2, s * (db // g2))


def _sub(na, da, nb, db):
    return _add(na, da, -nb, db)


def _mul(na, da, nb, db):
    var g1 = math.gcd(na, db)
    if g1 > 1:
        na = na // g1
        db = db // g1
    var g2 = math.gcd(nb, da)
    if g2 > 1:
        nb = nb // g2
        da = da // g2
    return _raw(na * nb, db * da)


def _div(na, da, nb, db):
    if nb == 0:
        raise ZeroDivisionError("Fraction(%s, 0)" % db)
    var g1 = math.gcd(na, nb)
    if g1 > 1:
        na = na // g1
        nb = nb // g1
    var g2 = math.gcd(db, da)
    if g2 > 1:
        da = da // g2
        db = db // g2
    var n = na * db
    var d = nb * da
    if d < 0:
        n = -n
        d = -d
    return _raw(n, d)


def _floordiv(na, da, nb, db):
    return (na * db) // (da * nb)


def _mod(na, da, nb, db):
    return Fraction((na * db) % (nb * da), da * db)


def _divmod(na, da, nb, db):
    var qr = divmod(na * db, da * nb)
    return (qr[0], Fraction(qr[1], da * db))


def _rational_op(op, na, da, nb, db):
    if op == "+":
        return _add(na, da, nb, db)
    if op == "-":
        return _sub(na, da, nb, db)
    if op == "*":
        return _mul(na, da, nb, db)
    if op == "/":
        return _div(na, da, nb, db)
    if op == "//":
        return _floordiv(na, da, nb, db)
    if op == "%":
        return _mod(na, da, nb, db)
    return _divmod(na, da, nb, db)


def _float_op(op, x, y):
    if op == "+":
        return x + y
    if op == "-":
        return x - y
    if op == "*":
        return x * y
    if op == "/":
        return x / y
    if op == "//":
        return x // y
    if op == "%":
        return x % y
    return divmod(x, y)


_RNAMES = {"+": "__radd__", "-": "__rsub__", "*": "__rmul__", "/": "__rtruediv__",
           "//": "__rfloordiv__", "%": "__rmod__", "divmod": "__rdivmod__"}


def _forward(a, b, op):
    # a <op> b for a Fraction a
    if isinstance(b, Fraction):
        return _rational_op(op, a._numerator, a._denominator, b._numerator, b._denominator)
    if isinstance(b, int):
        return _rational_op(op, a._numerator, a._denominator, int(b), 1)
    if isinstance(b, float):
        return _float_op(op, float(a), b)
    if isinstance(b, complex) and op in ("+", "-", "*", "/"):
        return _float_op(op, complex(float(a)), b)
    # Python's NotImplemented: the other operand's reflected method
    var rname = _RNAMES[op]
    if not isinstance(b, (str, list, tuple, dict)) and hasattr(b, rname):
        return getattr(b, rname)(a)
    if op == "divmod":
        raise TypeError("unsupported operand type(s) for divmod(): '" + _tn(a) + "' and '" + _tn(b) + "'")
    raise TypeError("unsupported operand type(s) for " + op + ": '" + _tn(a) + "' and '" + _tn(b) + "'")


def _reverse(b, a, op):
    # a <op> b for a Fraction b and a non-Fraction a
    if _is_rational(a):
        var p = _num_den(a)
        return _rational_op(op, p[0], p[1], b._numerator, b._denominator)
    if isinstance(a, float):
        return _float_op(op, a, float(b))
    if isinstance(a, complex) and op in ("+", "-", "*", "/"):
        return _float_op(op, a, complex(float(b)))
    if op == "divmod":
        raise TypeError("unsupported operand type(s) for divmod(): '" + _tn(a) + "' and '" + _tn(b) + "'")
    raise TypeError("unsupported operand type(s) for " + op + ": '" + _tn(a) + "' and '" + _tn(b) + "'")


# ── formatting (3.12's Fraction.__format__) ─────────────────────────────────
def _round_to_exponent(n, d, exponent, no_neg_zero=False):
    # n/d rounded to a multiple of 10**exponent, ties to even:
    # (negative, significand)
    if exponent >= 0:
        d = d * 10 ** exponent
    else:
        n = n * 10 ** (-exponent)
    var qr = divmod(n + (d >> 1), d)
    var q = qr[0]
    if qr[1] == 0 and (d & 1) == 0:
        q = q & -2
    var sign = (q < 0) if no_neg_zero else (n < 0)
    return (sign, abs(q))


def _round_to_figures(n, d, figures):
    # n/d rounded to `figures` significant digits: (negative, significand,
    # exponent)
    if n == 0:
        return (false, 0, 1 - figures)
    var str_n = str(abs(n))
    var str_d = str(d)
    var m = len(str_n) - len(str_d) + (1 if str_d <= str_n else 0)
    var exponent = m - figures
    var r = _round_to_exponent(n, d, exponent)
    var significand = r[1]
    if len(str(significand)) == figures + 1:
        significand = significand // 10
        exponent = exponent + 1
    return (r[0], significand, exponent)


def _parse_float_spec(spec):
    # (?:(fill)?(align))?(sign)?(z)?(#)?(0(?=\d))?(width)?([,_])?(\.prec)?(type)
    # -> dict, or None when the spec does not match
    var r = {"fill": None, "align": None, "sign": "", "z": false, "alt": false,
             "zeropad": false, "width": None, "sep": None, "prec": None, "type": None}
    var n = len(spec)
    var i = 0
    if n >= 2 and spec[1] in "<>=^":
        r["fill"] = spec[0]
        r["align"] = spec[1]
        i = 2
    elif n >= 1 and spec[0] in "<>=^":
        r["align"] = spec[0]
        i = 1
    if i < n and spec[i] in "+- ":
        r["sign"] = spec[i]
        i = i + 1
    if i < n and spec[i] == "z":
        r["z"] = true
        i = i + 1
    if i < n and spec[i] == "#":
        r["alt"] = true
        i = i + 1
    if i + 1 < n and spec[i] == "0" and spec[i + 1].isdigit():
        r["zeropad"] = true
        i = i + 1
    var j = i
    while j < n and spec[j] in "0123456789":
        j = j + 1
    if j > i:
        var w = spec[i:j]
        if len(w) > 1 and w[0] == "0":
            return None
        r["width"] = int(w)
        i = j
    if i < n and spec[i] in ",_":
        r["sep"] = spec[i]
        i = i + 1
    if i < n and spec[i] == ".":
        i = i + 1
        j = i
        while j < n and spec[j] in "0123456789":
            j = j + 1
        if j == i or (j - i > 1 and spec[i] == "0"):
            return None
        r["prec"] = int(spec[i:j])
        i = j
    if i == n - 1 and spec[i] in "eEfFgG%":
        r["type"] = spec[i]
        return r
    return None


def _format_fraction(self, format_spec):
    var m = _parse_float_spec(format_spec)
    if m is None:
        raise ValueError("Invalid format specifier " + repr(format_spec) +
                         " for object of type " + repr(_tn(self)))
    if m["align"] is not None and m["zeropad"]:
        raise ValueError("Invalid format specifier " + repr(format_spec) +
                         " for object of type " + repr(_tn(self)) +
                         "; can't use explicit alignment when zero-padding")
    var fill = m["fill"] or " "
    var align = m["align"] or ">"
    var pos_sign = "" if m["sign"] == "-" else m["sign"]
    var no_neg_zero = m["z"]
    var alternate_form = m["alt"]
    var zeropad = m["zeropad"]
    var minimumwidth = m["width"] or 0
    var thousands_sep = m["sep"] or ""
    var precision = 6 if m["prec"] is None else m["prec"]
    var presentation_type = m["type"]
    var trim_zeros = presentation_type in "gG" and not alternate_form
    var trim_point = not alternate_form
    var exponent_indicator = "E" if presentation_type in "EFG" else "e"
    var negative = false
    var significand = 0
    var exponent = 0
    var scientific = false
    var point_pos = 0
    if presentation_type in "fF%":
        exponent = -precision
        if presentation_type == "%":
            exponent = exponent - 2
        var rr = _round_to_exponent(self._numerator, self._denominator, exponent, no_neg_zero)
        negative = rr[0]
        significand = rr[1]
        scientific = false
        point_pos = precision
    else:
        var figures = max(precision, 1) if presentation_type in "gG" else precision + 1
        var rf = _round_to_figures(self._numerator, self._denominator, figures)
        negative = rf[0]
        significand = rf[1]
        exponent = rf[2]
        scientific = presentation_type in "eE" or exponent > 0 or exponent + figures <= -4
        point_pos = figures - 1 if scientific else -exponent
    var suffix = ""
    if presentation_type == "%":
        suffix = "%"
    elif scientific:
        var e = exponent + point_pos
        suffix = exponent_indicator + ("-" if e < 0 else "+") + str(abs(e)).zfill(2)
    var digits = str(significand).zfill(point_pos + 1)
    var sign = "-" if negative else pos_sign
    var leading = digits[:len(digits) - point_pos]
    var frac_part = digits[len(digits) - point_pos:]
    if trim_zeros:
        frac_part = frac_part.rstrip("0")
    var separator = "" if trim_point and not frac_part else "."
    var trailing = separator + frac_part + suffix
    if zeropad:
        var min_leading = minimumwidth - len(sign) - len(trailing)
        leading = leading.zfill(3 * min_leading // 4 + 1 if thousands_sep else min_leading)
    if thousands_sep:
        var first_pos = 1 + (len(leading) - 1) % 3
        var parts = [leading[:first_pos]]
        for pos in range(first_pos, len(leading), 3):
            parts.append(thousands_sep + leading[pos:pos + 3])
        leading = "".join(parts)
    var body = leading + trailing
    var padding = fill * (minimumwidth - len(sign) - len(body))
    if align == ">":
        return padding + sign + body
    if align == "<":
        return sign + body + padding
    if align == "^":
        var half = len(padding) // 2
        return padding[:half] + sign + body + padding[half:]
    return sign + padding + body


class Fraction:
    # numerator / denominator in lowest terms, denominator > 0
    def __init__(self, numerator=0, denominator=None, *, _normalize=True):
        if denominator is None:
            if isinstance(numerator, int):
                self._numerator = int(numerator)
                self._denominator = 1
                return
            if isinstance(numerator, Fraction):
                self._numerator = numerator._numerator
                self._denominator = numerator._denominator
                return
            if isinstance(numerator, float):
                var r = numerator.as_integer_ratio()
                self._numerator = r[0]
                self._denominator = r[1]
                return
            if isinstance(numerator, str):
                var p = _parse(numerator)
                if p is None:
                    raise ValueError("Invalid literal for Fraction: " + repr(numerator))
                numerator = p[0]
                denominator = p[1]
            elif _is_rational(numerator):
                self._numerator = numerator.numerator
                self._denominator = numerator.denominator
                return
            elif not isinstance(numerator, (list, tuple, dict, complex)) and hasattr(numerator, "as_integer_ratio"):
                var r2 = numerator.as_integer_ratio()
                self._numerator = r2[0]
                self._denominator = r2[1]
                return
            else:
                raise TypeError("argument should be a string or a Rational instance")
        elif isinstance(numerator, int) and isinstance(denominator, int):
            numerator = int(numerator)
            denominator = int(denominator)
        elif _is_rational(numerator) and _is_rational(denominator):
            var a = _num_den(numerator)
            var b = _num_den(denominator)
            numerator = a[0] * b[1]
            denominator = b[0] * a[1]
        else:
            raise TypeError("both arguments should be Rational instances")
        if denominator == 0:
            raise ZeroDivisionError("Fraction(%s, 0)" % numerator)
        if _normalize:
            var g = math.gcd(numerator, denominator)
            if denominator < 0:
                g = -g
            numerator = numerator // g
            denominator = denominator // g
        self._numerator = numerator
        self._denominator = denominator

    @classmethod
    def from_float(cls, f):
        if isinstance(f, int):
            return cls(f)
        if not isinstance(f, float):
            raise TypeError("%s.from_float() only takes floats, not %r (%s)" % (cls.__name__, f, _tn(f)))
        var r = f.as_integer_ratio()
        return cls(r[0], r[1])

    @classmethod
    def from_decimal(cls, dec):
        if isinstance(dec, int):
            return cls(dec)
        if isinstance(dec, (float, str)) or not hasattr(dec, "as_integer_ratio"):
            raise TypeError("%s.from_decimal() only takes Decimals, not %r (%s)" % (cls.__name__, dec, _tn(dec)))
        var r = dec.as_integer_ratio()
        return cls(r[0], r[1])

    def is_integer(self):
        return self._denominator == 1

    def as_integer_ratio(self):
        return (self._numerator, self._denominator)

    def limit_denominator(self, max_denominator=1000000):
        # the closest Fraction with denominator <= max_denominator
        # (continued fractions, then the better of the two bounds)
        if max_denominator < 1:
            raise ValueError("max_denominator should be at least 1")
        if self._denominator <= max_denominator:
            return Fraction(self)
        var p0 = 0
        var q0 = 1
        var p1 = 1
        var q1 = 0
        var n = self._numerator
        var d = self._denominator
        while true:
            var a = n // d
            var q2 = q0 + a * q1
            if q2 > max_denominator:
                break
            var np1 = p0 + a * p1
            p0 = p1
            q0 = q1
            p1 = np1
            q1 = q2
            var nd = n - a * d
            n = d
            d = nd
        var k = (max_denominator - q0) // q1
        var bound1 = Fraction(p0 + k * p1, q0 + k * q1)
        var bound2 = Fraction(p1, q1)
        if abs(bound2 - self) <= abs(bound1 - self):
            return bound2
        return bound1

    @property
    def numerator(self):
        return self._numerator

    @property
    def denominator(self):
        return self._denominator

    @property
    def real(self):
        return +self

    @property
    def imag(self):
        return 0

    def conjugate(self):
        return +self

    def __repr__(self):
        return "%s(%s, %s)" % (self.__class__.__name__, self._numerator, self._denominator)

    def __str__(self):
        if self._denominator == 1:
            return str(self._numerator)
        return "%s/%s" % (self._numerator, self._denominator)

    def __format__(self, format_spec):
        if not format_spec:
            return str(self)
        return _format_fraction(self, format_spec)

    # ── arithmetic ──
    def __add__(self, other):
        return _forward(self, other, "+")

    def __radd__(self, other):
        return _reverse(self, other, "+")

    def __sub__(self, other):
        return _forward(self, other, "-")

    def __rsub__(self, other):
        return _reverse(self, other, "-")

    def __mul__(self, other):
        return _forward(self, other, "*")

    def __rmul__(self, other):
        return _reverse(self, other, "*")

    def __truediv__(self, other):
        return _forward(self, other, "/")

    def __rtruediv__(self, other):
        return _reverse(self, other, "/")

    def __floordiv__(self, other):
        return _forward(self, other, "//")

    def __rfloordiv__(self, other):
        return _reverse(self, other, "//")

    def __mod__(self, other):
        return _forward(self, other, "%")

    def __rmod__(self, other):
        return _reverse(self, other, "%")

    def __divmod__(self, other):
        return _forward(self, other, "divmod")

    def __rdivmod__(self, other):
        return _reverse(self, other, "divmod")

    def __pow__(self, other):
        if _is_rational(other):
            var p = _num_den(other)
            if p[1] == 1:
                var power = p[0]
                if power >= 0:
                    return _raw(self._numerator ** power, self._denominator ** power)
                if self._numerator > 0:
                    return _raw(self._denominator ** (-power), self._numerator ** (-power))
                if self._numerator == 0:
                    raise ZeroDivisionError("Fraction(%s, 0)" % (self._denominator ** (-power)))
                return _raw((-self._denominator) ** (-power), (-self._numerator) ** (-power))
            return float(self) ** (p[0] / p[1])
        if isinstance(other, (float, complex)):
            return float(self) ** other
        if not isinstance(other, (str, list, tuple, dict)) and hasattr(other, "__rpow__"):
            return other.__rpow__(self)
        raise TypeError("unsupported operand type(s) for ** or pow(): '" + _tn(self) + "' and '" + _tn(other) + "'")

    def __rpow__(self, other):
        if self._denominator == 1 and self._numerator >= 0:
            return other ** self._numerator
        if _is_rational(other):
            var p = _num_den(other)
            return Fraction(p[0], p[1]) ** self
        if self._denominator == 1:
            return other ** self._numerator
        return other ** float(self)

    def __pos__(self):
        return _raw(self._numerator, self._denominator)

    def __neg__(self):
        return _raw(-self._numerator, self._denominator)

    def __abs__(self):
        return _raw(abs(self._numerator), self._denominator)

    def __int__(self):
        if self._numerator < 0:
            return -((-self._numerator) // self._denominator)
        return self._numerator // self._denominator

    def __trunc__(self):
        if self._numerator < 0:
            return -((-self._numerator) // self._denominator)
        return self._numerator // self._denominator

    def __floor__(self):
        return self._numerator // self._denominator

    def __ceil__(self):
        return -((-self._numerator) // self._denominator)

    def __float__(self):
        # int / int is correctly rounded, so this is the nearest float
        return self._numerator / self._denominator

    def __complex__(self):
        return complex(float(self))

    def __round__(self, ndigits=None):
        # ties to even
        if ndigits is None:
            var fr = divmod(self._numerator, self._denominator)
            var fl = fr[0]
            var rem2 = fr[1] * 2
            if rem2 < self._denominator:
                return fl
            if rem2 > self._denominator:
                return fl + 1
            if fl % 2 == 0:
                return fl
            return fl + 1
        var shift = 10 ** abs(ndigits)
        if ndigits > 0:
            return Fraction(round(self * shift), shift)
        return Fraction(round(self / shift) * shift)

    def __hash__(self):
        # Python's numeric hash: equal ints, floats and Fractions hash alike
        var d = self._denominator
        var h = 0
        if d % _PyHASH_MODULUS == 0:
            h = _PyHASH_INF
        else:
            var dinv = pow(d, _PyHASH_MODULUS - 2, _PyHASH_MODULUS)
            h = hash(hash(abs(self._numerator)) * dinv)
        var result = h if self._numerator >= 0 else -h
        return -2 if result == -1 else result

    def __eq__(self, other):
        if isinstance(other, Fraction):
            return self._numerator == other._numerator and self._denominator == other._denominator
        if isinstance(other, int):
            return self._numerator == int(other) and self._denominator == 1
        if _is_rational(other):
            return self._numerator == other.numerator and self._denominator == other.denominator
        if isinstance(other, complex):
            if other.imag != 0:
                return false
            other = other.real
        if isinstance(other, float):
            if math.isnan(other) or math.isinf(other):
                return false
            var r = other.as_integer_ratio()
            return self._numerator == r[0] and self._denominator == r[1]
        return false

    def __ne__(self, other):
        return not self.__eq__(other)

    def _cmp(self, other, opname):
        # -1 / 0 / 1 against a rational or a finite float; None for a nan
        # (every comparison false); +-2 for an infinity
        if _is_rational(other):
            var p = _num_den(other)
            var x = self._numerator * p[1]
            var y = self._denominator * p[0]
            return -1 if x < y else (1 if x > y else 0)
        if isinstance(other, float):
            if math.isnan(other):
                return None
            if math.isinf(other):
                return -2 if other > 0 else 2
            var r = other.as_integer_ratio()
            var x2 = self._numerator * r[1]
            var y2 = self._denominator * r[0]
            return -1 if x2 < y2 else (1 if x2 > y2 else 0)
        var rev = {"<": "__gt__", ">": "__lt__", "<=": "__ge__", ">=": "__le__"}[opname]
        if not isinstance(other, (str, list, tuple, dict)) and hasattr(other, rev):
            return ("reflected", getattr(other, rev)(self))
        raise TypeError("'" + opname + "' not supported between instances of '" + _tn(self) + "' and '" + _tn(other) + "'")

    def __lt__(self, other):
        var c = self._cmp(other, "<")
        if isinstance(c, tuple):
            return c[1]
        return c is not None and c < 0

    def __gt__(self, other):
        var c = self._cmp(other, ">")
        if isinstance(c, tuple):
            return c[1]
        return c is not None and c > 0

    def __le__(self, other):
        var c = self._cmp(other, "<=")
        if isinstance(c, tuple):
            return c[1]
        return c is not None and c <= 0

    def __ge__(self, other):
        var c = self._cmp(other, ">=")
        if isinstance(c, tuple):
            return c[1]
        return c is not None and c >= 0

    def __bool__(self):
        return self._numerator != 0

    def __reduce__(self):
        return (self.__class__, (self._numerator, self._denominator))

    def __copy__(self):
        return self

    def __deepcopy__(self, memo):
        return self


# A numbers.Rational, as CPython's Fraction (which derives from it): a
# virtual subclass here (round 77).
import numbers as _numbers
_numbers.Rational.register(Fraction)
