# nython: module    (import it by name: it runs in a module scope of its own)
# lib/random.ny - Python's random module (CPython 3.12's Lib/random.py).
#
#     import random
#     random.seed(42); random.random(); random.randint(1, 6)
#     random.choice(xs); random.shuffle(xs); random.sample(xs, 3)
#     r = random.Random(7); r.gauss(0, 1)
#
# The same seed gives the same numbers as CPython, bit for bit: the core is
# CPython's Mersenne Twister (builtins/pyrandom.cpp, the natives _mt_*), seeded
# the way _randommodule.c seeds it - an int by init_by_array over its 32-bit
# words, a str/bytes (version 2) through sha512, a float through hash() - and
# every method below is Python's algorithm, so random(), getrandbits(),
# randrange/randint/choice/shuffle/sample (with CPython's choice between a
# pool and a set of selections), choices (bisecting cumulative weights),
# gauss (its cached second value), and the distributions all consume the
# generator exactly as Python does.
#
# Random          the generator class; subclass it and override random()
#                 (and optionally getrandbits()) for another core generator
# SystemRandom    os.urandom-backed; getstate/setstate raise NotImplementedError
# module functions  seed random uniform triangular randint choice randrange
#                 sample shuffle choices normalvariate lognormvariate
#                 expovariate vonmisesvariate gammavariate gauss betavariate
#                 binomialvariate paretovariate weibullvariate getstate
#                 setstate getrandbits randbytes (methods of one shared Random)
#
# Differences from Python: the state is a bytearray inside the object (the
# natives update it in place); a subclass that overrides random() but not
# getrandbits() gets Python's random()-based _randbelow, decided by comparing
# methods (Nython has no __init_subclass__); sample() accepts any object with
# __len__ and __getitem__ (Python insists on a registered Sequence).
import math

__all__ = ["Random", "SystemRandom", "betavariate", "binomialvariate", "choice", "choices",
           "expovariate", "gammavariate", "gauss", "getrandbits", "getstate", "lognormvariate",
           "normalvariate", "paretovariate", "randbytes", "randint", "random", "randrange",
           "sample", "seed", "setstate", "shuffle", "triangular", "uniform", "vonmisesvariate",
           "weibullvariate"]

NV_MAGICCONST = 4 * math.exp(-0.5) / math.sqrt(2.0)
TWOPI = 2.0 * math.pi
LOG4 = math.log(4.0)
SG_MAGICCONST = 1.0 + math.log(4.5)
BPF = 53
RECIP_BPF = 2 ** -BPF


def _index(x):
    # operator.index
    if isinstance(x, bool):
        return 1 if x else 0
    if isinstance(x, int):
        return x
    if hasattr(x, "__index__"):
        return x.__index__()
    raise TypeError("'" + type(x).__name__ + "' object cannot be interpreted as an integer")


def _bisect_right(a, x, lo, hi):
    while lo < hi:
        var mid = (lo + hi) // 2
        if x < a[mid]:
            hi = mid
        else:
            lo = mid + 1
    return lo


def _accumulate(xs):
    var out = []
    var first = true
    var total = 0
    for x in xs:
        if first:
            total = x
            first = false
        else:
            total = total + x
        out.append(total)
    return out


def _is_sequence(p):
    if isinstance(p, list) or isinstance(p, tuple) or isinstance(p, str) or isinstance(p, range):
        return true
    if isinstance(p, bytes) or isinstance(p, bytearray):
        return true
    if isinstance(p, dict) or isinstance(p, set) or isinstance(p, frozenset):
        return false
    return hasattr(p, "__getitem__") and hasattr(p, "__len__")


def _sha512_digest(data):
    var h = _hash_new("sha512", data)
    var d = _hash_digest(h)
    _hash_free(h)
    return d


class Random:
    """Random number generator base class used by bound module functions.

    Used to instantiate instances of Random to get generators that don't
    share state.

    Class Random can also be subclassed if you want to use a different basic
    generator of your own devising: in that case, override the following
    methods:  random(), seed(), getstate(), and setstate().
    Optionally, implement a getrandbits() method so that randrange()
    can cover arbitrarily large ranges.
    """

    VERSION = 3
    # how _randbelow draws: none until first used, then "native" (this
    # module's generator), "bits" (an overridden getrandbits) or "float" (an
    # overridden random() alone, Python's _randbelow_without_getrandbits)
    _rbmode = none

    def __init__(self, x=none):
        self._state = none
        self.gauss_next = none
        self.seed(x)
        self.gauss_next = none

    def seed(self, a=none, version=2):
        """Initialize internal state from a seed.

        The only supported seed types are None, int, float,
        str, bytes, and bytearray.
        """
        if version == 1 and (isinstance(a, str) or isinstance(a, bytes)):
            if isinstance(a, bytes):
                a = a.decode("latin-1")
            var x = (ord(a[0]) << 7) if len(a) > 0 else 0
            for ch in a:
                x = ((1000003 * x) ^ ord(ch)) & 0xFFFFFFFFFFFFFFFF
            x = x ^ len(a)
            a = -2 if x == -1 else x
        elif version == 2 and (isinstance(a, str) or isinstance(a, bytes) or isinstance(a, bytearray)):
            if isinstance(a, str):
                a = a.encode()
            a = bytes(a)
            a = int.from_bytes(a + _sha512_digest(a), "big")
        elif not (a is none or isinstance(a, int) or isinstance(a, float)):
            raise TypeError("The only supported seed types are: None,\nint, float, str, bytes, and bytearray.")
        # _random.Random.seed: None from the OS, an int by its absolute
        # value, anything else by its hash (as an unsigned 64-bit number)
        if a is none:
            self._state = _mt_seed(int.from_bytes(os_urandom(624 * 4), "little"))
        elif isinstance(a, int):
            self._state = _mt_seed(abs(int(a)))
        else:
            var h = hash(a)
            if h < 0:
                h = h + (1 << 64)
            self._state = _mt_seed(h)
        self.gauss_next = none

    def random(self):
        """random() -> x in the interval [0, 1)."""
        return _mt_random(self._state)

    def getrandbits(self, k):
        """getrandbits(k) -> x.  Generates an int with k random bits."""
        if not isinstance(k, int):
            raise TypeError("'" + type(k).__name__ + "' object cannot be interpreted as an integer")
        return _mt_getrandbits(self._state, k)

    def getstate(self):
        """Return internal state; can be passed to setstate() later."""
        return (self.VERSION, _mt_getstate(self._state), self.gauss_next)

    def setstate(self, state):
        """Restore internal state from object returned by getstate()."""
        var version = state[0]
        if version == 3:
            self._state = _mt_setstate(state[1])
            self.gauss_next = state[2]
        elif version == 2:
            self._state = _mt_setstate(tuple([x % (2 ** 32) for x in state[1]]))
            self.gauss_next = state[2]
        else:
            raise ValueError("state with version " + str(version) + " passed to Random.setstate() of version " + str(self.VERSION))

    def __getstate__(self):
        return self.getstate()

    def __setstate__(self, state):
        self.setstate(state)

    # ── evenly distributed integers ──
    def _pick_randbelow(self):
        var cls = self.__class__
        if cls.getrandbits == Random.getrandbits and cls.random == Random.random:
            return "native"
        if cls.getrandbits == Random.getrandbits:
            return "float"
        return "bits"

    def _randbelow_mode(self):
        var mode = self._rbmode
        if mode is none:
            mode = self._pick_randbelow()
            self._rbmode = mode
        return mode

    def _randbelow(self, n):
        "Return a random int in the range [0,n).  Defined for n > 0."
        var mode = self._rbmode
        if mode == "native":
            return _mt_randbelow(self._state, n)
        if mode is none:
            mode = self._randbelow_mode()
        if mode == "native":
            return _mt_randbelow(self._state, n)
        if mode == "bits":
            return self._randbelow_with_getrandbits(n)
        return self._randbelow_without_getrandbits(n)

    def _randbelow_with_getrandbits(self, n):
        var k = n.bit_length()
        var r = self.getrandbits(k)
        while r >= n:
            r = self.getrandbits(k)
        return r

    def _randbelow_without_getrandbits(self, n, maxsize=1 << BPF):
        if n >= maxsize:
            return math.floor(self.random() * n)
        var rem = maxsize % n
        var limit = (maxsize - rem) / maxsize
        var r = self.random()
        while r >= limit:
            r = self.random()
        return math.floor(r * maxsize) % n

    # ── bytes ──
    def randbytes(self, n):
        """Generate n random bytes."""
        return self.getrandbits(n * 8).to_bytes(n, "little")

    # ── integers ──
    def randrange(self, start, stop=none, step=1):
        """Choose a random item from range(stop) or range(start, stop[, step])."""
        var istart = start if isinstance(start, int) and not isinstance(start, bool) else _index(start)
        if stop is none:
            if step != 1:
                raise TypeError("Missing a non-None stop argument")
            if istart > 0:
                return self._randbelow(istart)
            raise ValueError("empty range for randrange()")
        var istop = stop if isinstance(stop, int) and not isinstance(stop, bool) else _index(stop)
        var width = istop - istart
        var istep = step if isinstance(step, int) and not isinstance(step, bool) else _index(step)
        if istep == 1:
            if width > 0:
                return istart + self._randbelow(width)
            raise ValueError("empty range in randrange(" + str(start) + ", " + str(stop) + ")")
        var n = 0
        if istep > 0:
            n = (width + istep - 1) // istep
        elif istep < 0:
            n = (width + istep + 1) // istep
        else:
            raise ValueError("zero step for randrange()")
        if n <= 0:
            raise ValueError("empty range in randrange(" + str(start) + ", " + str(stop) + ", " + str(step) + ")")
        return istart + istep * self._randbelow(n)

    def randint(self, a, b):
        """Return random integer in range [a, b], including both end points."""
        if isinstance(a, int) and isinstance(b, int) and b >= a and not isinstance(a, bool) and not isinstance(b, bool):
            # randrange(a, b + 1)'s draw, without its argument checks
            return a + self._randbelow(b + 1 - a)
        return self.randrange(a, b + 1)

    # ── sequences ──
    def choice(self, seq):
        """Choose a random element from a non-empty sequence."""
        if not len(seq):
            raise IndexError("Cannot choose from an empty sequence")
        return seq[self._randbelow(len(seq))]

    def shuffle(self, x):
        """Shuffle list x in place, and return None."""
        if isinstance(x, list) and self._randbelow_mode() == "native":
            # the same swaps, natively (builtins/pyrandom.cpp)
            _mt_shuffle(self._state, x)
            return none
        var i = len(x) - 1
        while i >= 1:
            var j = self._randbelow(i + 1)
            var t = x[i]
            x[i] = x[j]
            x[j] = t
            i = i - 1
        return none

    def sample(self, population, k, *, counts=none):
        """Chooses k unique random elements from a population sequence."""
        if not _is_sequence(population):
            raise TypeError("Population must be a sequence.  For dicts or sets, use sorted(d).")
        var n = len(population)
        if counts is not none:
            var cum_counts = _accumulate(counts)
            if len(cum_counts) != n:
                raise ValueError("The number of counts does not match the population")
            var total = cum_counts.pop()
            if not isinstance(total, int):
                raise TypeError("Counts must be integers")
            if total <= 0:
                raise ValueError("Total of counts must be greater than zero")
            var selections = self.sample(range(total), k=k)
            var hi = len(cum_counts)
            return [population[_bisect_right(cum_counts, s, 0, hi)] for s in selections]
        if not (0 <= k and k <= n):
            raise ValueError("Sample larger than population or is negative")
        var result = [none] * k
        var setsize = 21
        if k > 5:
            setsize = setsize + 4 ** math.ceil(math.log(k * 3, 4))
        if n <= setsize:
            var pool = list(population)
            for i in range(k):
                var j = self._randbelow(n - i)
                result[i] = pool[j]
                pool[j] = pool[n - i - 1]
        else:
            var selected = set()
            for i in range(k):
                var j = self._randbelow(n)
                while j in selected:
                    j = self._randbelow(n)
                selected.add(j)
                result[i] = population[j]
        return result

    def choices(self, population, weights=none, *, cum_weights=none, k=1):
        """Return a k sized list of population elements chosen with replacement."""
        var n = len(population)
        if cum_weights is none:
            if weights is none:
                var nf = n + 0.0
                return [population[math.floor(self.random() * nf)] for i in range(k)]
            if isinstance(weights, int) and not isinstance(weights, bool):
                raise TypeError("The number of choices must be a keyword argument: k=" + str(weights))
            cum_weights = _accumulate(weights)
        elif weights is not none:
            raise TypeError("Cannot specify both weights and cumulative weights")
        if len(cum_weights) != n:
            raise ValueError("The number of weights does not match the population")
        var total = cum_weights[-1] + 0.0
        if total <= 0.0:
            raise ValueError("Total of weights must be greater than zero")
        if not math.isfinite(total):
            raise ValueError("Total of weights must be finite")
        var hi = n - 1
        return [population[_bisect_right(cum_weights, self.random() * total, 0, hi)] for i in range(k)]

    # ── real-valued distributions ──
    def uniform(self, a, b):
        """Get a random number in the range [a, b) or [a, b] depending on rounding."""
        return a + (b - a) * self.random()

    def triangular(self, low=0.0, high=1.0, mode=none):
        """Triangular distribution."""
        var u = self.random()
        var c = 0.5
        if mode is not none:
            if high - low == 0:
                return low
            c = (mode - low) / (high - low)
        if u > c:
            u = 1.0 - u
            c = 1.0 - c
            var t = low
            low = high
            high = t
        return low + (high - low) * math.sqrt(u * c)

    def normalvariate(self, mu=0.0, sigma=1.0):
        """Normal distribution.  mu is the mean, and sigma is the standard deviation."""
        var z = 0.0
        while true:
            var u1 = self.random()
            var u2 = 1.0 - self.random()
            z = NV_MAGICCONST * (u1 - 0.5) / u2
            var zz = z * z / 4.0
            if zz <= -math.log(u2):
                break
        return mu + z * sigma

    def gauss(self, mu=0.0, sigma=1.0):
        """Gaussian distribution.  mu is the mean, and sigma is the standard deviation."""
        var z = self.gauss_next
        self.gauss_next = none
        if z is none:
            var x2pi = self.random() * TWOPI
            var g2rad = math.sqrt(-2.0 * math.log(1.0 - self.random()))
            z = math.cos(x2pi) * g2rad
            self.gauss_next = math.sin(x2pi) * g2rad
        return mu + z * sigma

    def lognormvariate(self, mu, sigma):
        """Log normal distribution."""
        return math.exp(self.normalvariate(mu, sigma))

    def expovariate(self, lambd=1.0):
        """Exponential distribution.  lambd is 1.0 divided by the desired mean."""
        return -math.log(1.0 - self.random()) / lambd

    def vonmisesvariate(self, mu, kappa):
        """Circular data distribution."""
        if kappa <= 1e-6:
            return TWOPI * self.random()
        var s = 0.5 / kappa
        var r = s + math.sqrt(1.0 + s * s)
        var z = 0.0
        while true:
            var u1 = self.random()
            z = math.cos(math.pi * u1)
            var d = z / (r + z)
            var u2 = self.random()
            if u2 < 1.0 - d * d or u2 <= (1.0 - d) * math.exp(d):
                break
        var q = 1.0 / r
        var f = (q + z) / (1.0 + q * z)
        var u3 = self.random()
        if u3 > 0.5:
            return (mu + math.acos(f)) % TWOPI
        return (mu - math.acos(f)) % TWOPI

    def gammavariate(self, alpha, beta):
        """Gamma distribution.  Not the gamma function!"""
        if alpha <= 0.0 or beta <= 0.0:
            raise ValueError("gammavariate: alpha and beta must be > 0.0")
        if alpha > 1.0:
            var ainv = math.sqrt(2.0 * alpha - 1.0)
            var bbb = alpha - LOG4
            var ccc = alpha + ainv
            while true:
                var u1 = self.random()
                if not (1e-7 < u1 and u1 < 0.9999999):
                    continue
                var u2 = 1.0 - self.random()
                var v = math.log(u1 / (1.0 - u1)) / ainv
                var x = alpha * math.exp(v)
                var z = u1 * u1 * u2
                var r = bbb + ccc * v - x
                if r + SG_MAGICCONST - 4.5 * z >= 0.0 or r >= math.log(z):
                    return x * beta
        elif alpha == 1.0:
            return -math.log(1.0 - self.random()) * beta
        var x = 0.0
        while true:
            var u = self.random()
            var b = (math.e + alpha) / math.e
            var p = b * u
            if p <= 1.0:
                x = p ** (1.0 / alpha)
            else:
                x = -math.log((b - p) / alpha)
            var u1 = self.random()
            if p > 1.0:
                if u1 <= x ** (alpha - 1.0):
                    break
            elif u1 <= math.exp(-x):
                break
        return x * beta

    def betavariate(self, alpha, beta):
        """Beta distribution."""
        var y = self.gammavariate(alpha, 1.0)
        if y:
            return y / (y + self.gammavariate(beta, 1.0))
        return 0.0

    def paretovariate(self, alpha):
        """Pareto distribution.  alpha is the shape parameter."""
        var u = 1.0 - self.random()
        return u ** (-1.0 / alpha)

    def weibullvariate(self, alpha, beta):
        """Weibull distribution."""
        var u = 1.0 - self.random()
        return alpha * (-math.log(u)) ** (1.0 / beta)

    # ── discrete distributions ──
    def binomialvariate(self, n=1, p=0.5):
        """Binomial random variable (Python 3.12)."""
        if n < 0:
            raise ValueError("n must be non-negative")
        if p <= 0.0 or p >= 1.0:
            if p == 0.0:
                return 0
            if p == 1.0:
                return n
            raise ValueError("p must be in the range 0.0 <= p <= 1.0")
        if n == 1:
            return 1 if self.random() < p else 0
        if p > 0.5:
            return n - self.binomialvariate(n, 1.0 - p)
        if n * p < 10.0:
            var x = 0
            var y = 0
            var c = math.log2(1.0 - p)
            if not c:
                return x
            while true:
                y = y + math.floor(math.log2(self.random()) / c) + 1
                if y > n:
                    return x
                x = x + 1
        var setup_complete = false
        var spq = math.sqrt(n * p * (1.0 - p))
        var b = 1.15 + 2.53 * spq
        var a = -0.0873 + 0.0248 * b + 0.01 * p
        var c = n * p + 0.5
        var vr = 0.92 - 4.2 / b
        var alpha = 0.0
        var lpq = 0.0
        var m = 0
        var h = 0.0
        while true:
            var u = self.random()
            u = u - 0.5
            var us = 0.5 - math.fabs(u)
            var k = math.floor((2.0 * a / us + b) * u + c)
            if k < 0 or k > n:
                continue
            var v = self.random()
            if us >= 0.07 and v <= vr:
                return k
            if not setup_complete:
                alpha = (2.83 + 5.1 / b) * spq
                lpq = math.log(p / (1.0 - p))
                m = math.floor((n + 1) * p)
                h = math.lgamma(m + 1) + math.lgamma(n - m + 1)
                setup_complete = true
            v = v * (alpha / (a / (us * us) + b))
            if math.log(v) <= h - math.lgamma(k + 1) - math.lgamma(n - k + 1) + (k - m) * lpq:
                return k


class SystemRandom(Random):
    """Alternate random number generator using sources provided
    by the operating system (os.urandom)."""

    def random(self):
        """Get the next random number in the range 0.0 <= X < 1.0."""
        return (int.from_bytes(os_urandom(7), "big") >> 3) * RECIP_BPF

    def getrandbits(self, k):
        """getrandbits(k) -> x.  Generates an int with k random bits."""
        if k < 0:
            raise ValueError("number of bits must be non-negative")
        var numbytes = (k + 7) // 8
        var x = int.from_bytes(os_urandom(numbytes), "big")
        return x >> (numbytes * 8 - k)

    def randbytes(self, n):
        """Generate n random bytes."""
        return os_urandom(n)

    def seed(self, *args, **kwds):
        "Stub method.  Not used for a system random number generator."
        return none

    def _notimplemented(self, *args, **kwds):
        raise NotImplementedError("System entropy source does not have state.")

    def getstate(self, *args, **kwds):
        raise NotImplementedError("System entropy source does not have state.")

    def setstate(self, *args, **kwds):
        raise NotImplementedError("System entropy source does not have state.")


# One shared generator, seeded from the OS; its methods are the module's
# functions.
_inst = Random()
seed = _inst.seed
random = _inst.random
uniform = _inst.uniform
triangular = _inst.triangular
randint = _inst.randint
choice = _inst.choice
randrange = _inst.randrange
sample = _inst.sample
shuffle = _inst.shuffle
choices = _inst.choices
normalvariate = _inst.normalvariate
lognormvariate = _inst.lognormvariate
expovariate = _inst.expovariate
vonmisesvariate = _inst.vonmisesvariate
gammavariate = _inst.gammavariate
gauss = _inst.gauss
betavariate = _inst.betavariate
binomialvariate = _inst.binomialvariate
paretovariate = _inst.paretovariate
weibullvariate = _inst.weibullvariate
getstate = _inst.getstate
setstate = _inst.setstate
getrandbits = _inst.getrandbits
randbytes = _inst.randbytes
