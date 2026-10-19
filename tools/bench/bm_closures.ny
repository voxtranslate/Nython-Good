# bm_closures - closure-heavy code: function factories, nonlocal counters,
# lambdas passed to sorted()/map(), composition of closures, a memoizing
# decorator over a dict in a closure. Runs under python3 too.
import time


def make_adder(n):
    def add(x):
        return x + n
    return add


def make_counter():
    count = 0

    def inc(step):
        nonlocal count
        count += step
        return count
    return inc


def compose(f, g):
    return lambda x: f(g(x))


def memoize(fn):
    cache = {}

    def wrapper(n):
        if n in cache:
            return cache[n]
        r = fn(n)
        cache[n] = r
        return r
    return wrapper


def make_pipeline(k):
    fns = []
    for i in range(k):
        fns.append(make_adder(i))

    def run(x):
        for f in fns:
            x = f(x)
        return x
    return run


def main():
    t0 = time.perf_counter()
    total = 0
    adders = [make_adder(i) for i in range(50)]
    for rnd in range(360):
        for a in adders:
            total += a(rnd)
    c = make_counter()
    for i in range(120000):
        c(1)
    total += c(0)
    f = compose(make_adder(3), make_adder(4))
    g = compose(f, f)
    for i in range(48000):
        total += g(i)
    p = make_pipeline(20)
    for i in range(4800):
        total += p(i)
    data = [(i * 7919) % 1000 for i in range(3000)]
    for rnd in range(24):
        s = sorted(data, key=lambda v: (v % 10, -v))
        total += s[0] + s[-1]
        total += sum(map(lambda v: v * 2, data))

    @memoize
    def mfib(n):
        if n < 2:
            return n
        return mfib(n - 1) + mfib(n - 2)
    for i in range(1800):
        total += mfib(i % 90) % 1000
    t1 = time.perf_counter()
    print("result", total)
    print("bench_time", t1 - t0)

main()
