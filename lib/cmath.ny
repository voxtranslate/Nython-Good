# nython: module    (import it by name: it runs in a module scope of its own)
# lib/cmath.ny - Python's cmath module (round 83): mathematical functions
# for complex numbers.
#
#     import cmath
#     cmath.sqrt(-1)                 # 1j
#     cmath.exp(1j * cmath.pi)       # (-1+1.2246467991473532e-16j)
#     cmath.polar(1 + 1j)            # (1.4142135623730951, 0.7853981633974483)
#     cmath.log(8, 2)                # (3+0j)
#
# sqrt, exp, log(x[, base]), log10, the trigonometric (cos sin tan acos asin
# atan) and hyperbolic (cosh sinh tanh acosh asinh atanh) functions, phase,
# polar, rect, isfinite, isinf, isnan, isclose(a, b, *, rel_tol=1e-09,
# abs_tol=0.0), and pi, e, tau, inf, infj, nan, nanj.
#
# The functions are builtins/nycmath.cpp: CPython's cmathmodule.c algorithm
# for algorithm (Kahan's branch cuts, rescaling against overflow and
# subnormals, log1p near |z| = 1), with its special-value tables for
# infinite and NaN operands (C99 Annex G) and its errors - ValueError "math
# domain error" (log(0), atanh(1), exp(1+infj), ...) and OverflowError "math
# range error" - in the same places. Arguments are complex numbers, ints,
# floats, or objects with __complex__, __float__ or __index__.
#
# Not here: nothing of CPython's module.

pi = 3.141592653589793
e = 2.718281828459045
tau = 6.283185307179586
inf = float("inf")
nan = float("nan")
infj = complex(0.0, inf)
nanj = complex(0.0, nan)


def _c(z):
    # PyArg's "D" conversion: complex, or a number made complex
    if isinstance(z, complex):
        return z
    if isinstance(z, bool) or isinstance(z, int) or isinstance(z, float):
        return complex(float(z), 0.0)
    var t = type(z)
    var m = getattr(t, "__complex__", None)
    if m is not None:
        var c = m(z)
        if not isinstance(c, complex):
            raise TypeError("__complex__ returned non-complex (type " + type(c).__name__ + ")")
        return c
    m = getattr(t, "__float__", None)
    if m is not None:
        return complex(m(z), 0.0)
    m = getattr(t, "__index__", None)
    if m is not None:
        return complex(float(m(z)), 0.0)
    raise TypeError("must be real number, not " + t.__name__)


def _f(x):
    if isinstance(x, bool) or isinstance(x, int) or isinstance(x, float):
        return float(x)
    if isinstance(x, complex):
        raise TypeError("must be real number, not complex")
    var t = type(x)
    var m = getattr(t, "__float__", None)
    if m is not None:
        return m(x)
    m = getattr(t, "__index__", None)
    if m is not None:
        return float(m(x))
    raise TypeError("must be real number, not " + t.__name__)


def _call(name, z):
    var c = _c(z)
    var r = _cmath_call(name, c.real, c.imag)
    return complex(r[0], r[1])


def sqrt(z, /):
    """Return the square root of z."""
    return _call("sqrt", z)


def exp(z, /):
    """Return the exponential value e**z."""
    return _call("exp", z)


def log(x, base=None, /):
    """log(z[, base]) -> the logarithm of z to the given base.

    If the base is not specified, returns the natural logarithm (base e) of z."""
    if base is None:
        return _call("log", x)
    var a = _c(x)
    var b = _c(base)
    var r = _cmath_log(a.real, a.imag, b.real, b.imag)
    return complex(r[0], r[1])


def log10(z, /):
    """Return the base-10 logarithm of z."""
    return _call("log10", z)


def acos(z, /):
    """Return the arc cosine of z."""
    return _call("acos", z)


def acosh(z, /):
    """Return the inverse hyperbolic cosine of z."""
    return _call("acosh", z)


def asin(z, /):
    """Return the arc sine of z."""
    return _call("asin", z)


def asinh(z, /):
    """Return the inverse hyperbolic sine of z."""
    return _call("asinh", z)


def atan(z, /):
    """Return the arc tangent of z."""
    return _call("atan", z)


def atanh(z, /):
    """Return the inverse hyperbolic tangent of z."""
    return _call("atanh", z)


def cos(z, /):
    """Return the cosine of z."""
    return _call("cos", z)


def cosh(z, /):
    """Return the hyperbolic cosine of z."""
    return _call("cosh", z)


def sin(z, /):
    """Return the sine of z."""
    return _call("sin", z)


def sinh(z, /):
    """Return the hyperbolic sine of z."""
    return _call("sinh", z)


def tan(z, /):
    """Return the tangent of z."""
    return _call("tan", z)


def tanh(z, /):
    """Return the hyperbolic tangent of z."""
    return _call("tanh", z)


def phase(z, /):
    """Return argument, also known as the phase angle, of a complex."""
    var c = _c(z)
    return _cmath_phase(c.real, c.imag)


def polar(z, /):
    """Convert a complex from rectangular coordinates to polar coordinates.

    r is the distance from 0 and phi the phase angle."""
    var c = _c(z)
    var phi = _cmath_phase(c.real, c.imag)
    var r = _cmath_abs(c.real, c.imag)
    return (r, phi)


def rect(r, phi, /):
    """Convert from polar coordinates to rectangular coordinates."""
    var v = _cmath_rect(_f(r), _f(phi))
    return complex(v[0], v[1])


def _finite(x):
    return x == x and x != inf and x != -inf


def isfinite(z, /):
    """Return True if both the real and imaginary parts of z are finite, else False."""
    var c = _c(z)
    return _finite(c.real) and _finite(c.imag)


def isnan(z, /):
    """Checks if the real or imaginary part of z not a number (NaN)."""
    var c = _c(z)
    return c.real != c.real or c.imag != c.imag


def isinf(z, /):
    """Checks if the real or imaginary part of z is infinite."""
    var c = _c(z)
    return c.real in (inf, -inf) or c.imag in (inf, -inf)


def isclose(a, b, *, rel_tol=1e-09, abs_tol=0.0):
    """Determine whether two complex numbers are close in value."""
    var x = _c(a)
    var y = _c(b)
    rel_tol = _f(rel_tol)
    abs_tol = _f(abs_tol)
    if rel_tol < 0.0 or abs_tol < 0.0:
        raise ValueError("tolerances must be non-negative")
    if x.real == y.real and x.imag == y.imag:
        return True
    if x.real in (inf, -inf) or x.imag in (inf, -inf) or y.real in (inf, -inf) or y.imag in (inf, -inf):
        return False
    var diff = _cmath_abs(x.real - y.real, x.imag - y.imag)
    return (diff <= rel_tol * _cmath_abs(y.real, y.imag) or diff <= rel_tol * _cmath_abs(x.real, x.imag)
            or diff <= abs_tol)
