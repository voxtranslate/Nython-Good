#!/usr/bin/env python3
"""tools/gen_vm_audit115.py - records CPython + ncurses' screens for
examples/vm_audit115.ny (round 84).

Runs the test's curses programs under this python3 (which must have
_curses) on a pseudo-terminal, through the test's own emulator, and writes
the screens into the EXPECTED block of the test, between the
"# --- expected (generated) ---" and "# --- end expected ---" lines. The test
compares with them when no python3 with _curses is there to compare with
live.

    python3 tools/gen_vm_audit115.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST = os.path.join(ROOT, "examples", "vm_audit115.ny")


def main():
    out = subprocess.run([sys.executable, TEST, "--record"], capture_output=True, text=True, check=True).stdout
    block = out[out.index("EXPECTED = {"):].rstrip() + "\n"
    with open(TEST) as f:
        src = f.read()
    a = src.index("# --- expected (generated) ---\n") + len("# --- expected (generated) ---\n")
    z = src.index("# --- end expected ---")
    src = src[:a] + block + src[z:]
    with open(TEST, "w") as f:
        f.write(src)
    print("recorded", block.count("\n") - 2, "program runs")


if __name__ == "__main__":
    main()
