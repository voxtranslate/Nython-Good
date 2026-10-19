# bm_exceptions - try/except in hot loops: exceptions raised and caught in
# the same function and across calls, a class hierarchy matched by typed
# except clauses, finally blocks, try/else, the EAFP dict idiom
# (KeyError), int() of bad strings (ValueError), and the cheap path where
# nothing is raised. Runs under python3 too.
import time


class AppError(Exception):
    pass


class NotFound(AppError):
    def __init__(self, key):
        AppError.__init__(self, key)
        self.key = key


class Invalid(AppError):
    pass


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


def main():
    t0 = time.perf_counter()
    d = {}
    for i in range(0, 200, 2):
        d[i] = i * i
    hits = 0
    misses = 0
    invalid = 0
    finals = 0
    for rnd in range(30):
        for k in range(200):
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
                hits += 1
            finally:
                finals += 1
    eafp = 0
    for k in range(6000):
        try:
            eafp += d[k % 300]
        except KeyError:
            eafp -= 1
    bad = 0
    for s in ["1", "x", "22", "3.5", "", "-4"] * 400:
        try:
            bad += int(s)
        except ValueError:
            bad += 1000
    deepc = 0
    for i in range(400):
        try:
            deep(10)
        except ValueError as e:
            deepc += len(str(e))
    clean = 0
    for i in range(20000):
        try:
            clean += i
        except Exception:
            clean = -1
    t1 = time.perf_counter()
    print("result", hits, misses, invalid, finals, eafp, bad, deepc, clean)
    print("bench_time", t1 - t0)

main()
