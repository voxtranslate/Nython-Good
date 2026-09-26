#!/usr/bin/env python3
"""sweep.py - run every test file on both engines and compare to a baseline.

    python3 tools/sweep.py                          # this build, both engines
    python3 tools/sweep.py --base /tmp/obuild/nython_orig

A run fails when it exits non-zero, times out, or prints "N failed" with N > 0,
"FAILED" or a "FAIL " line - the exit code alone hides most test failures
(HANDOFF.md §2). With --base, the same files are run on the baseline binary
and only the DIFFERENCE is reported: files that pass there and fail here
(regressions) and the reverse (fixes). Comparing sets, not counts, keeps a
fix from masking a new failure.
"""
import glob
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAIL_RE = re.compile(r"(?<![\w-])([1-9]\d*) failed|FAILED|^FAIL |\bFAIL \[", re.M)


def files():
    out = sorted(glob.glob(os.path.join(REPO, "examples", "test_*.ny")))
    out += sorted(glob.glob(os.path.join(REPO, "examples", "vm_audit*.ny")))
    out += sorted(glob.glob(os.path.join(REPO, "examples", "gui_tests", "test_*.ny")))
    return out


def run_one(binary, path, vm, timeout):
    cmd = [binary] + (["--vm"] if vm else []) + [path]
    env = dict(os.environ, NY_STUB_AUTOQUIT="40")
    try:
        p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, errors="replace",
                           timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    text = p.stdout + p.stderr
    if FAIL_RE.search(text):
        return "fail", text
    if p.returncode != 0:
        return "exit%d" % p.returncode, text
    return "ok", text


def sweep(binary, timeout, jobs):
    tasks = [(f, vm) for f in files() for vm in (False, True)]
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        res = list(ex.map(lambda t: (t, run_one(binary, t[0], t[1], timeout)), tasks))
    return {(os.path.relpath(f, REPO), "vm" if vm else "interp"): r for (f, vm), r in res}


def main(argv):
    base = None
    binary = os.path.join(REPO, "build", "nython-cli")
    timeout = 180
    jobs = 4
    verbose = False
    i = 0
    while i < len(argv):
        if argv[i] == "--base":
            base = argv[i + 1]
            i += 1
        elif argv[i] == "--bin":
            binary = argv[i + 1]
            i += 1
        elif argv[i] == "--timeout":
            timeout = int(argv[i + 1])
            i += 1
        elif argv[i] == "-j":
            jobs = int(argv[i + 1])
            i += 1
        elif argv[i] == "-v":
            verbose = True
        i += 1
    cur = sweep(binary, timeout, jobs)
    bad = sorted(k for k, v in cur.items() if v[0] != "ok")
    print("%d runs, %d not ok" % (len(cur), len(bad)))
    for k in bad:
        print("  %-55s %-6s %s" % (k[0], k[1], cur[k][0]))
        if verbose:
            tail = "\n".join(cur[k][1].strip().split("\n")[-6:])
            print("      " + tail.replace("\n", "\n      "))
    if base:
        old = sweep(base, timeout, jobs)
        reg = sorted(k for k in cur if cur[k][0] != "ok" and old.get(k, ("ok",))[0] == "ok")
        fix = sorted(k for k in cur if cur[k][0] == "ok" and old.get(k, ("ok",))[0] != "ok")
        print("\nregressions (ok on base, not ok now): %d" % len(reg))
        for k in reg:
            print("  %-55s %-6s %s" % (k[0], k[1], cur[k][0]))
            tail = "\n".join(cur[k][1].strip().split("\n")[-6:])
            print("      " + tail.replace("\n", "\n      "))
        print("fixed (not ok on base, ok now): %d" % len(fix))
        for k in fix:
            print("  %-55s %-6s was %s" % (k[0], k[1], old[k][0]))
        return 1 if reg else 0
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
