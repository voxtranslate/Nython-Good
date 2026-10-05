# nython: module    (import it by name: it runs in a module scope of its own)
# lib/statistics.ny - Python's statistics (3.12).
#
#     import statistics
#     statistics.mean([1, 2, 3, 4.5])            # 2.625
#     statistics.stdev(data); statistics.quantiles(data, n=10)
#     statistics.linear_regression(x, y)       # LinearRegression(slope=..., intercept=...)
#     statistics.NormalDist(100, 15).cdf(130)
#
# Averages: mean, fmean (weights=), geometric_mean, harmonic_mean
# (weights=), median, median_low, median_high, median_grouped, mode,
# multimode, quantiles (n=, method="exclusive"/"inclusive"). Spread:
# pstdev, pvariance, stdev, variance. Two inputs: covariance, correlation
# (method="linear"/"ranked"), linear_regression (proportional=). NormalDist
# (pdf, cdf, inv_cdf, quantiles, overlap, zscore, from_samples, samples,
# mean/median/mode/stdev/variance, + - * / with numbers and other
# NormalDists). StatisticsError (a ValueError).
#
# The results are CPython's, to the last bit: sums are exact (each value
# as an integer ratio, added by denominator, as Python does), means and
# variances are computed as fractions (lib/fractions.ny) and converted
# once, standard deviations are the correctly rounded square root of the
# exact variance, and the result type follows Python's rules (an int mean
# stays an int when exact, Fractions give Fractions, floats floats).
# Decimal is not part of Nython yet; any other number type with
# as_integer_ratio() works. One deliberate difference: stdev/pstdev of data
# holding an infinity or a nan return inf/nan, as variance does (CPython
# 3.12 raises AttributeError there, reading .numerator of a float).
# NormalDist.samples uses lib/random.ny's gauss when that module exists,
# else the same algorithm over a generator of its own (so a seed does not
# give CPython's numbers then).
import math
from fractions import Fraction

__all__ = ["NormalDist", "StatisticsError", "correlation", "covariance", "fmean",
           "geometric_mean", "harmonic_mean", "linear_regression", "mean", "median",
           "median_grouped", "median_high", "median_low", "mode", "multimode", "pstdev",
           "pvariance", "quantiles", "stdev", "variance"]


class StatisticsError(ValueError):
    pass


def _tn(x):
    var n = type(x).__name__
    if n == "string":
        return "str"
    if n == "map":
        return "dict"
    if n == "none":
        return "NoneType"
    return n


def _kind(x):
    # the type _coerce works with: "int" (bools too), "float", "Fraction",
    # or the name of another number type
    if isinstance(x, bool) or isinstance(x, int):
        return "int"
    if isinstance(x, float):
        return "float"
    if isinstance(x, Fraction):
        return "Fraction"
    return _tn(x)


def _coerce(t, s):
    if t == s or s == "int":
        return t
    if t == "int":
        return s
    if (t == "Fraction" and s == "float") or (t == "float" and s == "Fraction"):
        return "float"
    raise TypeError("don't know how to coerce " + t + " and " + s)


def _exact_ratio(x):
    # (numerator, denominator) of x, or (x, None) for an infinity or nan
    if isinstance(x, (int, float, Fraction)):
        try:
            return x.as_integer_ratio()
        except (OverflowError, ValueError):
            return (x, None)
    if not isinstance(x, (str, bytes, list, tuple, dict)) and x is not None:
        if hasattr(x, "as_integer_ratio"):
            try:
                return x.as_integer_ratio()
            except (OverflowError, ValueError):
                return (x, None)
        if hasattr(x, "numerator") and hasattr(x, "denominator"):
            return (x.numerator, x.denominator)
    raise TypeError("can't convert type '" + _tn(x) + "' to numerator/denominator")


def _sum(data):
    # (type, exact total as a Fraction - or an inf/nan float -, count)
    var count = 0
    var kinds = []
    var partials = {}
    var special = None
    var have_special = false
    var last_kind = None
    for x in data:
        var r = _exact_ratio(x)
        var k = _kind(x)
        if k != last_kind:
            last_kind = k
            if k not in kinds:
                kinds.append(k)
        count = count + 1
        if r[1] is None:
            special = r[0] if not have_special else special + r[0]
            have_special = true
        else:
            partials[r[1]] = partials.get(r[1], 0) + r[0]
    var T = _coerce_all(kinds)
    if have_special:
        return (T, special, count)
    return (T, _total(partials), count)


def _coerce_all(kinds):
    var T = "int"
    for k in kinds:
        T = _coerce(T, k)
    return T


def _total(partials):
    # sum(Fraction(n, d) for d, n in partials.items()), on integers
    var num = 0
    var den = 1
    for d in partials:
        var n = partials[d]
        var g = math.gcd(den, d)
        num = num * (d // g) + n * (den // g)
        den = den * (d // g)
    return Fraction(num, den)


def _ss(data, c=None):
    # (type, exact sum of squared deviations, exact mean, count)
    if c is not None:
        var devs = []
        for x in data:
            var dx = x - c
            devs.append(dx * dx)
        var r = _sum(devs)
        return (r[0], r[1], c, r[2])
    var count = 0
    var kinds = []
    var last_kind = None
    var sx = {}
    var sxx = {}
    var special = None
    for x in data:
        var r2 = _exact_ratio(x)
        var k = _kind(x)
        if k != last_kind:
            last_kind = k
            if k not in kinds:
                kinds.append(k)
        count = count + 1
        if r2[1] is None:
            special = r2[0] if special is None else special + r2[0]
            continue
        sx[r2[1]] = sx.get(r2[1], 0) + r2[0]
        sxx[r2[1]] = sxx.get(r2[1], 0) + r2[0] * r2[0]
    var T = _coerce_all(kinds)
    if count == 0:
        return (T, Fraction(0), Fraction(0), 0)
    if special is not None:
        return (T, special, special, count)
    var tx = _total(sx)
    var sq = {}
    for d in sxx:
        sq[d * d] = sq.get(d * d, 0) + sxx[d]
    var txx = _total(sq)
    var ssd = (count * txx - tx * tx) / count
    return (T, ssd, tx / count, count)


def _convert(value, T):
    # value (a Fraction, or an inf/nan) as type T
    if isinstance(value, float):
        return value
    if T == "Fraction":
        return value if isinstance(value, Fraction) else Fraction(value)
    if T == "int":
        if isinstance(value, Fraction) and value.denominator != 1:
            return float(value)
        return int(value)
    return float(value)


def _float_sqrt_of_frac(n, m):
    # the correctly rounded square root of n/m (round to odd, then once to
    # a float)
    var q = (n.bit_length() - m.bit_length() - 109) // 2
    var numerator = 0
    var denominator = 1
    if q >= 0:
        numerator = _isqrt_frac_rto(n, m << (2 * q)) << q
    else:
        numerator = _isqrt_frac_rto(n << (-2 * q), m)
        denominator = 1 << (-q)
    return numerator / denominator


def _isqrt_frac_rto(n, m):
    var a = math.isqrt(n // m)
    if a * a * m != n:
        a = a | 1
    return a


def _fail_neg(values, errmsg):
    for x in values:
        if x < 0:
            raise StatisticsError(errmsg)
    return values


def mean(data):
    var r = _sum(data)
    if r[2] < 1:
        raise StatisticsError("mean requires at least one data point")
    return _convert(r[1] / r[2], r[0])


def fmean(data, weights=None):
    if weights is None:
        var items = list(data)
        var n = len(items)
        if not n:
            raise StatisticsError("fmean requires at least one data point")
        return math.fsum(items) / n
    var xs = list(data)
    var ws = list(weights)
    if len(xs) != len(ws):
        raise StatisticsError("data and weights must be the same length")
    var num = math.sumprod(xs, ws)
    var den = math.fsum(ws)
    if not den:
        raise StatisticsError("sum of weights must be non-zero")
    return num / den


def geometric_mean(data):
    try:
        return math.exp(fmean([math.log(x) for x in data]))
    except ValueError:
        raise StatisticsError("geometric mean requires a non-empty dataset containing positive numbers")


def harmonic_mean(data, weights=None):
    data = list(data)
    var errmsg = "harmonic mean does not support negative values"
    var n = len(data)
    if n < 1:
        raise StatisticsError("harmonic_mean requires at least one data point")
    if n == 1 and weights is None:
        var x = data[0]
        if isinstance(x, (int, float, Fraction)):
            if x < 0:
                raise StatisticsError(errmsg)
            return x
        raise TypeError("unsupported type")
    var sum_weights = n
    if weights is None:
        weights = [1] * n
    else:
        weights = list(weights)
        if len(weights) != n:
            raise StatisticsError("Number of weights does not match data size")
        sum_weights = _sum(_fail_neg(weights, errmsg))[1]
    var terms = []
    for k in range(n):
        var w = weights[k]
        var x2 = data[k]
        if x2 < 0:
            raise StatisticsError(errmsg)
        if w:
            if x2 == 0:
                return 0
            terms.append(w / x2)
        else:
            terms.append(0)
    var r = _sum(terms)
    if r[1] <= 0:
        raise StatisticsError("Weighted sum must be positive")
    return _convert(sum_weights / r[1], r[0])


def median(data):
    data = sorted(data)
    var n = len(data)
    if n == 0:
        raise StatisticsError("no median for empty data")
    if n % 2 == 1:
        return data[n // 2]
    var i = n // 2
    return (data[i - 1] + data[i]) / 2


def median_low(data):
    data = sorted(data)
    var n = len(data)
    if n == 0:
        raise StatisticsError("no median for empty data")
    if n % 2 == 1:
        return data[n // 2]
    return data[n // 2 - 1]


def median_high(data):
    data = sorted(data)
    var n = len(data)
    if n == 0:
        raise StatisticsError("no median for empty data")
    return data[n // 2]


def median_grouped(data, interval=1.0):
    data = sorted(data)
    var n = len(data)
    if not n:
        raise StatisticsError("no median for empty data")
    var x = data[n // 2]
    var i = 0
    while i < n and data[i] < x:
        i = i + 1
    var j = i
    while j < n and not (x < data[j]):
        j = j + 1
    try:
        interval = float(interval)
        x = float(x)
    except ValueError:
        raise TypeError("Value cannot be converted to a float")
    var L = x - interval / 2.0
    var cf = i
    var f = j - i
    return L + interval * (n / 2 - cf) / f


def _counts(data):
    var counts = {}
    for x in data:
        counts[x] = counts.get(x, 0) + 1
    return counts


def mode(data):
    var counts = _counts(data)
    if not counts:
        raise StatisticsError("no mode for empty data")
    var best = None
    var bestn = 0
    for k in counts:
        if counts[k] > bestn:
            best = k
            bestn = counts[k]
    return best


def multimode(data):
    var counts = _counts(data)
    if not counts:
        return []
    var maxcount = max(counts.values())
    return [k for k in counts if counts[k] == maxcount]


def quantiles(data, *, n=4, method="exclusive"):
    if n < 1:
        raise StatisticsError("n must be at least 1")
    data = sorted(data)
    var ld = len(data)
    if ld < 2:
        raise StatisticsError("must have at least two data points")
    var result = []
    if method == "inclusive":
        var m = ld - 1
        for i in range(1, n):
            var jd = divmod(i * m, n)
            var j = jd[0]
            var delta = jd[1]
            result.append((data[j] * (n - delta) + data[j + 1] * delta) / n)
        return result
    if method == "exclusive":
        var m2 = ld + 1
        for i in range(1, n):
            var j2 = i * m2 // n
            if j2 < 1:
                j2 = 1
            elif j2 > ld - 1:
                j2 = ld - 1
            var delta2 = i * m2 - j2 * n
            result.append((data[j2 - 1] * (n - delta2) + data[j2] * delta2) / n)
        return result
    raise ValueError("Unknown method: " + repr(method))


def variance(data, xbar=None):
    var r = _ss(data, xbar)
    if r[3] < 2:
        raise StatisticsError("variance requires at least two data points")
    return _convert(r[1] / (r[3] - 1), r[0])


def pvariance(data, mu=None):
    var r = _ss(data, mu)
    if r[3] < 1:
        raise StatisticsError("pvariance requires at least one data point")
    return _convert(r[1] / r[3], r[0])


def _sqrt_of(mss):
    if isinstance(mss, float):
        return math.sqrt(mss)
    return _float_sqrt_of_frac(mss.numerator, mss.denominator)


def stdev(data, xbar=None):
    var r = _ss(data, xbar)
    if r[3] < 2:
        raise StatisticsError("stdev requires at least two data points")
    return _sqrt_of(r[1] / (r[3] - 1))


def pstdev(data, mu=None):
    var r = _ss(data, mu)
    if r[3] < 1:
        raise StatisticsError("pstdev requires at least one data point")
    return _sqrt_of(r[1] / r[3])


def _mean_stdev(data):
    var r = _ss(data)
    if r[3] < 2:
        raise StatisticsError("stdev requires at least two data points")
    var mss = r[1] / (r[3] - 1)
    if isinstance(mss, float):
        return (float(r[2]), float(r[2]) / float(r[1]))
    return (float(r[2]), _float_sqrt_of_frac(mss.numerator, mss.denominator))


def covariance(x, y, /):
    var n = len(x)
    if len(y) != n:
        raise StatisticsError("covariance requires that both inputs have same number of data points")
    if n < 2:
        raise StatisticsError("covariance requires at least two data points")
    var xbar = math.fsum(x) / n
    var ybar = math.fsum(y) / n
    var sxy = math.sumprod([xi - xbar for xi in x], [yi - ybar for yi in y])
    return sxy / (n - 1)


def _rank(data, start=1):
    # ranks, ties averaged (Python's statistics._rank)
    var val_pos = sorted([(data[k], k) for k in range(len(data))])
    var i = start - 1
    var result = [0] * len(val_pos)
    var a = 0
    var n = len(val_pos)
    while a < n:
        var b = a
        while b + 1 < n and val_pos[b + 1][0] == val_pos[a][0]:
            b = b + 1
        var size = b - a + 1
        var rank = i + (size + 1) / 2
        for k in range(a, b + 1):
            result[val_pos[k][1]] = rank
        i = i + size
        a = b + 1
    return result


def correlation(x, y, /, *, method="linear"):
    var n = len(x)
    if len(y) != n:
        raise StatisticsError("correlation requires that both inputs have same number of data points")
    if n < 2:
        raise StatisticsError("correlation requires at least two data points")
    if method != "linear" and method != "ranked":
        raise ValueError("Unknown method: " + repr(method))
    if method == "ranked":
        var start = (n - 1) / -2
        x = _rank(list(x), start)
        y = _rank(list(y), start)
    else:
        var xbar = math.fsum(x) / n
        var ybar = math.fsum(y) / n
        x = [xi - xbar for xi in x]
        y = [yi - ybar for yi in y]
    var sxy = math.sumprod(x, y)
    var sxx = math.sumprod(x, x)
    var syy = math.sumprod(y, y)
    var den = math.sqrt(sxx * syy)
    if den == 0:
        raise StatisticsError("at least one of the inputs is constant")
    return sxy / den


class LinearRegression:
    # Python's namedtuple LinearRegression(slope, intercept)
    _fields = ("slope", "intercept")

    def __init__(self, slope, intercept):
        self.slope = slope
        self.intercept = intercept

    def __iter__(self):
        return iter((self.slope, self.intercept))

    def __len__(self):
        return 2

    def __getitem__(self, i):
        return (self.slope, self.intercept)[i]

    def __eq__(self, other):
        if isinstance(other, LinearRegression):
            return self.slope == other.slope and self.intercept == other.intercept
        if isinstance(other, tuple):
            return (self.slope, self.intercept) == other
        return false

    def __repr__(self):
        return "LinearRegression(slope=" + repr(self.slope) + ", intercept=" + repr(self.intercept) + ")"

    def _asdict(self):
        return {"slope": self.slope, "intercept": self.intercept}


def linear_regression(x, y, /, *, proportional=False):
    var n = len(x)
    if len(y) != n:
        raise StatisticsError("linear regression requires that both inputs have same number of data points")
    if n < 2:
        raise StatisticsError("linear regression requires at least two data points")
    var xbar = 0.0
    var ybar = 0.0
    if not proportional:
        xbar = math.fsum(x) / n
        ybar = math.fsum(y) / n
        x = [xi - xbar for xi in x]
        y = [yi - ybar for yi in y]
    var sxy = math.sumprod(x, y) + 0.0
    var sxx = math.sumprod(x, x)
    if sxx == 0:
        raise StatisticsError("x is constant")
    var slope = sxy / sxx
    var intercept = 0.0 if proportional else ybar - slope * xbar
    return LinearRegression(slope, intercept)


# ── NormalDist ───────────────────────────────────────────────────────────────
_SQRT2 = math.sqrt(2.0)


def _normal_dist_inv_cdf(p, mu, sigma):
    # Wichura's algorithm AS241 (as Python's)
    var q = p - 0.5
    var r = 0.0
    var num = 0.0
    var den = 0.0
    if math.fabs(q) <= 0.425:
        r = 0.180625 - q * q
        num = (((((((2509.0809287301227 * r + 33430.57558358813) * r + 67265.7709270087) * r +
                   45921.95393154987) * r + 13731.69376550946) * r + 1971.5909503065513) * r +
                133.14166789178438) * r + 3.3871328727963665) * q
        den = (((((((5226.495278852854 * r + 28729.085735721943) * r + 39307.89580009271) * r +
                   21213.794301586597) * r + 5394.196021424751) * r + 687.1870074920579) * r +
                42.31333070160091) * r + 1.0)
        return mu + (num / den) * sigma
    r = p if q <= 0.0 else 1.0 - p
    r = math.sqrt(-math.log(r))
    if r <= 5.0:
        r = r - 1.6
        num = (((((((0.0007745450142783414 * r + 0.022723844989269184) * r + 0.2417807251774506) * r +
                   1.2704582524523684) * r + 3.6478483247632045) * r + 5.769497221460691) * r +
                4.630337846156546) * r + 1.4234371107496835)
        den = (((((((1.0507500716444169e-09 * r + 0.0005475938084995345) * r + 0.015198666563616457) * r +
                   0.14810397642748008) * r + 0.6897673349851) * r + 1.6763848301838038) * r +
                2.053191626637759) * r + 1.0)
    else:
        r = r - 5.0
        num = (((((((2.0103343992922881e-07 * r + 2.7115555687434876e-05) * r + 0.0012426609473880784) * r +
                   0.026532189526576124) * r + 0.29656057182850487) * r + 1.7848265399172913) * r +
                5.463784911164114) * r + 6.657904643501103)
        den = (((((((2.0442631033899397e-15 * r + 1.421511758316446e-07) * r + 1.8463183175100548e-05) * r +
                   0.0007868691311456133) * r + 0.014875361290850615) * r + 0.1369298809227358) * r +
                0.599832206555888) * r + 1.0)
    var x = num / den
    if q < 0.0:
        x = -x
    return mu + x * sigma


class _StatsGauss:
    # random.Random(seed).gauss's algorithm over a 64-bit generator
    # (splitmix64; the OS's random source when no seed is given) - for when
    # lib/random.ny is not there
    def __init__(self, seed):
        self._seeded = seed is not None
        self._state = hash(seed) & 0xffffffffffffffff if seed is not None else 0
        self._next = None

    def _random(self):
        if not self._seeded:
            return (int.from_bytes(os_urandom(7), "big") >> 3) / 9007199254740992.0
        self._state = (self._state + 0x9e3779b97f4a7c15) & 0xffffffffffffffff
        var z = self._state
        z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & 0xffffffffffffffff
        z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & 0xffffffffffffffff
        z = z ^ (z >> 31)
        return (z >> 11) / 9007199254740992.0

    def gauss(self, mu=0.0, sigma=1.0):
        var z = self._next
        self._next = None
        if z is None:
            var x2pi = self._random() * math.tau
            var g2rad = math.sqrt(-2.0 * math.log(1.0 - self._random()))
            z = math.cos(x2pi) * g2rad
            self._next = math.sin(x2pi) * g2rad
        return mu + z * sigma


def _gauss_source(seed):
    # Python's random.gauss / random.Random(seed).gauss (lib/random.ny),
    # else the same algorithm over a generator of our own
    try:
        import random
        if seed is None:
            return random.gauss
        return random.Random(seed).gauss
    except (NameError, AttributeError, ImportError, TypeError):
        return _StatsGauss(seed).gauss


class NormalDist:
    # a normal distribution of a random variable
    def __init__(self, mu=0.0, sigma=1.0):
        if sigma < 0.0:
            raise StatisticsError("sigma must be non-negative")
        self._mu = float(mu)
        self._sigma = float(sigma)

    @classmethod
    def from_samples(cls, data):
        var ms = _mean_stdev(data)
        return cls(ms[0], ms[1])

    def samples(self, n, *, seed=None):
        var gauss = _gauss_source(seed)
        return [gauss(self._mu, self._sigma) for _ in range(n)]

    def pdf(self, x):
        var variance = self._sigma * self._sigma
        if not variance:
            raise StatisticsError("pdf() not defined when sigma is zero")
        var diff = x - self._mu
        return math.exp(diff * diff / (-2.0 * variance)) / math.sqrt(math.tau * variance)

    def cdf(self, x):
        if not self._sigma:
            raise StatisticsError("cdf() not defined when sigma is zero")
        return 0.5 * (1.0 + math.erf((x - self._mu) / (self._sigma * _SQRT2)))

    def inv_cdf(self, p):
        if p <= 0.0 or p >= 1.0:
            raise StatisticsError("p must be in the range 0.0 < p < 1.0")
        return _normal_dist_inv_cdf(p, self._mu, self._sigma)

    def quantiles(self, n=4):
        return [self.inv_cdf(i / n) for i in range(1, n)]

    def overlap(self, other):
        if not isinstance(other, NormalDist):
            raise TypeError("Expected another NormalDist instance")
        var X = self
        var Y = other
        if (Y._sigma, Y._mu) < (X._sigma, X._mu):
            X = other
            Y = self
        var X_var = X.variance
        var Y_var = Y.variance
        if not X_var or not Y_var:
            raise StatisticsError("overlap() not defined when sigma is zero")
        var dv = Y_var - X_var
        var dm = math.fabs(Y._mu - X._mu)
        if not dv:
            return 1.0 - math.erf(dm / (2.0 * X._sigma * _SQRT2))
        var a = X._mu * Y_var - Y._mu * X_var
        var b = X._sigma * Y._sigma * math.sqrt(dm * dm + dv * math.log(Y_var / X_var))
        var x1 = (a + b) / dv
        var x2 = (a - b) / dv
        return 1.0 - (math.fabs(Y.cdf(x1) - X.cdf(x1)) + math.fabs(Y.cdf(x2) - X.cdf(x2)))

    def zscore(self, x):
        if not self._sigma:
            raise StatisticsError("zscore() not defined when sigma is zero")
        return (x - self._mu) / self._sigma

    @property
    def mean(self):
        return self._mu

    @property
    def median(self):
        return self._mu

    @property
    def mode(self):
        return self._mu

    @property
    def stdev(self):
        return self._sigma

    @property
    def variance(self):
        return self._sigma * self._sigma

    def __add__(self, other):
        if isinstance(other, NormalDist):
            return NormalDist(self._mu + other._mu, math.hypot(self._sigma, other._sigma))
        return NormalDist(self._mu + other, self._sigma)

    def __sub__(self, other):
        if isinstance(other, NormalDist):
            return NormalDist(self._mu - other._mu, math.hypot(self._sigma, other._sigma))
        return NormalDist(self._mu - other, self._sigma)

    def __mul__(self, other):
        return NormalDist(self._mu * other, self._sigma * math.fabs(other))

    def __truediv__(self, other):
        return NormalDist(self._mu / other, self._sigma / math.fabs(other))

    def __pos__(self):
        return NormalDist(self._mu, self._sigma)

    def __neg__(self):
        return NormalDist(-self._mu, self._sigma)

    def __radd__(self, other):
        return self.__add__(other)

    def __rsub__(self, other):
        return -(self - other)

    def __rmul__(self, other):
        return self.__mul__(other)

    def __eq__(self, other):
        if not isinstance(other, NormalDist):
            return false
        return self._mu == other._mu and self._sigma == other._sigma

    def __hash__(self):
        return hash((self._mu, self._sigma))

    def __repr__(self):
        return self.__class__.__name__ + "(mu=" + repr(self._mu) + ", sigma=" + repr(self._sigma) + ")"
