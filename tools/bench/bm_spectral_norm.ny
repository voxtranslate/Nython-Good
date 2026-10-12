# bm_spectral_norm - pyperformance's spectral_norm (the Computer Language
# Benchmarks Game): small functions called through a function argument,
# list comprehensions, enumerate, zip, float arithmetic. Runs under python3
# too.
import time

def eval_A(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)


def eval_times_u(func, u):
    return [func((i, u)) for i in range(len(list(u)))]


def eval_AtA_times_u(u):
    return eval_times_u(part_At_times_u, eval_times_u(part_A_times_u, u))


def part_A_times_u(i_u):
    i, u = i_u
    partial_sum = 0
    for j, u_j in enumerate(u):
        partial_sum += eval_A(i, j) * u_j
    return partial_sum


def part_At_times_u(i_u):
    i, u = i_u
    partial_sum = 0
    for j, u_j in enumerate(u):
        partial_sum += eval_A(j, i) * u_j
    return partial_sum


def bench_spectral_norm(n):
    u = [1] * n
    for dummy in range(10):
        v = eval_AtA_times_u(u)
        u = eval_AtA_times_u(v)

    vBv = vv = 0
    for ue, ve in zip(u, v):
        vBv += ue * ve
        vv += ve * ve
    return (vBv / vv) ** 0.5


def main():
    t0 = time.perf_counter()
    r = bench_spectral_norm(80)
    t1 = time.perf_counter()
    print("result", "%.9f" % r)
    print("bench_time", t1 - t0)

main()
