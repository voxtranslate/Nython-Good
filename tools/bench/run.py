#!/usr/bin/env python3
"""tools/bench/run.py - Nython's benchmark suite runner (round 80).

Runs each tools/bench/bm_*.ny N times on a Nython binary (the VM by
default, `--interp` for the tree-walking interpreter), optionally on a
baseline binary (`--base`) and on python3 (`--python`), and prints a table
of the min and median times with the speedup of the binary over the
baseline. Runs of the binaries are interleaved (base, new, base, new...)
so load from other processes on the machine affects both alike.

The time of a run is what the benchmark prints itself as `bench_time <s>`
(the work only: no process start, prelude or imports); `--wall` uses the
whole process's wall time instead. Every run's `result ...` line must equal
python3's (the benchmarks are deterministic), so a speedup that came from a
wrong answer is reported as an error rather than as a win.

    python3 tools/bench/run.py                       # build/nython-cli --vm, 5 runs
    python3 tools/bench/run.py --engine interp       # the tree-walking interpreter
    python3 tools/bench/run.py --base /tmp/old/nython-cli -n 7 --python
    python3 tools/bench/run.py -k fib -k richards    # a subset
    python3 tools/bench/run.py --bin build-win/nywin # under Wine (a wrapper script)
    python3 tools/bench/run.py --json out.json       # the raw numbers too
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def bench_files(keys):
    files = sorted(f for f in os.listdir(HERE) if f.startswith("bm_") and f.endswith(".ny"))
    if keys:
        files = [f for f in files if any(k in f for k in keys)]
    return files


def run_one(cmd, timeout):
    t0 = time.perf_counter()
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    wall = time.perf_counter() - t0
    result, btime = None, None
    for line in p.stdout.splitlines():
        if line.startswith("result"):
            result = line.strip()
        elif line.startswith("bench_time"):
            try:
                btime = float(line.split()[1])
            except (IndexError, ValueError):
                pass
    return p.returncode, result, btime, wall, p.stdout + p.stderr


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=os.path.join(ROOT, "build", "nython-cli"), help="the Nython binary measured")
    ap.add_argument("--base", help="a baseline Nython binary to compare against")
    ap.add_argument("--interp", action="store_true", help="run the interpreter instead of the VM (--vm)")
    ap.add_argument("--engine", choices=["interp", "vm"], help="the engine measured (round 81; --interp is --engine interp)")
    ap.add_argument("--python", action="store_true", help="also time python3 for reference")
    ap.add_argument("-n", type=int, default=5, help="runs per benchmark and binary (default 5)")
    ap.add_argument("-k", action="append", default=[], help="only benchmarks whose file name contains this")
    ap.add_argument("--wall", action="store_true", help="whole-process wall time instead of bench_time")
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--json", help="write the raw times to this file")
    args = ap.parse_args()

    if args.engine:
        args.interp = args.engine == "interp"
    eng = [] if args.interp else ["--vm"]
    files = bench_files(args.k)
    if not files:
        sys.exit("no benchmarks match")
    raw = {}
    errors = 0
    rows = []
    for f in files:
        path = os.path.join(HERE, f)
        name = f[3:-3]
        want = None
        py_times = []
        if True:   # python3's answer is the reference, always
            rc, want, bt, wall, out = run_one([sys.executable, path], args.timeout)
            if rc != 0 or want is None:
                print(f"{name}: python3 failed:\n{out}", file=sys.stderr)
                errors += 1
                continue
            if args.python:
                py_times.append(wall if args.wall else bt)
                for _ in range(args.n - 1):
                    rc, res, bt, wall, out = run_one([sys.executable, path], args.timeout)
                    py_times.append(wall if args.wall else bt)
        binaries = [("new", args.bin)] + ([("base", args.base)] if args.base else [])
        times = {k: [] for k, _ in binaries}
        bad = False
        for i in range(args.n):
            order = binaries if i % 2 == 0 else list(reversed(binaries))
            for key, b in order:
                rc, res, bt, wall, out = run_one([b] + eng + [path], args.timeout)
                if rc != 0 or res != want:
                    print(f"{name} [{key}: {b}] wrong: exit {rc}, got {res!r}, want {want!r}\n{out[-2000:]}",
                          file=sys.stderr)
                    bad = True
                    break
                times[key].append(wall if args.wall or bt is None else bt)
            if bad:
                break
        if bad:
            errors += 1
            continue
        raw[name] = {"python3": py_times, **times}
        new_min, new_med = min(times["new"]), statistics.median(times["new"])
        row = [name, new_min, new_med]
        if args.base:
            b_min, b_med = min(times["base"]), statistics.median(times["base"])
            row += [b_min, b_med, b_min / new_min if new_min else 0.0]
        if args.python:
            p_min = min(py_times)
            row += [p_min, new_min / p_min if p_min else 0.0]
        rows.append(row)
        print_row(row, args, header=(len(rows) == 1))
        sys.stdout.flush()
    if args.base and rows:
        sp = [r[5] for r in rows if r[5] > 0]
        if sp:
            gm = 1.0
            for s in sp:
                gm *= s
            gm **= 1.0 / len(sp)
            print(f"{'geometric mean speedup':<34}{gm:>8.2f}x")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(raw, fh, indent=1)
    if errors:
        print(f"{errors} benchmark(s) failed", file=sys.stderr)
        sys.exit(1)


def print_row(row, args, header=False):
    if header:
        h = f"{'benchmark':<16}{'min':>9}{'median':>9}"
        if args.base:
            h += f"{'base min':>10}{'base med':>10}{'speedup':>9}"
        if args.python:
            h += f"{'python3':>9}{'x py':>8}"
        print(h)
        print("-" * len(h))
    s = f"{row[0]:<16}{row[1]:>9.3f}{row[2]:>9.3f}"
    i = 3
    if args.base:
        s += f"{row[3]:>10.3f}{row[4]:>10.3f}{row[5]:>8.2f}x"
        i = 6
    if args.python:
        s += f"{row[i]:>9.4f}{row[i+1]:>7.1f}x"
    print(s)


if __name__ == "__main__":
    main()
