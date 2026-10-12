# bm_fannkuch - pyperformance's fannkuch (the Computer Language Benchmarks
# Game's "fannkuch-redux" flips): list slicing, slice assignment, bound
# list methods, while/else. Runs under python3 too.
import time

def fannkuch(n):
    count = list(range(1, n + 1))
    max_flips = 0
    m = n - 1
    r = n
    check = 0
    perm1 = list(range(n))
    perm = list(range(n))
    perm1_ins = perm1.insert
    perm1_pop = perm1.pop

    while 1:
        if check < 30:
            check += 1

        while r != 1:
            count[r - 1] = r
            r -= 1

        if perm1[0] != 0 and perm1[m] != m:
            perm = perm1[:]
            flips_count = 0
            k = perm[0]
            while k:
                perm[:k + 1] = perm[k::-1]
                flips_count += 1
                k = perm[0]

            if flips_count > max_flips:
                max_flips = flips_count

        while r != n:
            perm1_ins(r, perm1_pop(0))
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1
        else:
            return max_flips


def main():
    t0 = time.perf_counter()
    r = fannkuch(8)
    t1 = time.perf_counter()
    print("result", r)
    print("bench_time", t1 - t0)

main()
