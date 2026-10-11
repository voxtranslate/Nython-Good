# bm_fib - recursive Fibonacci: call overhead, global function lookup,
# small-int arithmetic and comparison. Runs under python3 too.
import time

def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def main():
    t0 = time.perf_counter()
    r = 0
    for i in range(3):
        r = fib(24)
    t1 = time.perf_counter()
    print("result", r)
    print("bench_time", t1 - t0)

main()
