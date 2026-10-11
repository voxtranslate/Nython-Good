#!/usr/bin/env python3
"""ny_classcheck.py - fail on top-level names defined more than once across lib/.

Nython has no per-module namespace for `import "path"` (an include): every top-level
class and function a module defines lands in one global namespace, and a
later definition silently replaces an earlier one. A caller written against
the replaced definition then gets `none` back from every method the winner
does not have (HANDOFF 5.10: KnowledgeBase was defined four times; 11 of its
12 internal callers were talking to the wrong class).

    python3 tools/ny_classcheck.py            # classes and functions in lib/**
    python3 tools/ny_classcheck.py --classes  # classes only

Exit status 1 if any name is defined twice; each definition is listed with
file:line. Methods (indented defs) are not top-level and are not checked.
"""
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLASS_RE = re.compile(r"^class\s+([A-Za-z_]\w*)")
DEF_RE = re.compile(r"^def\s+([A-Za-z_]\w*)")


MODULE_MARK = "# nython: module"


def is_module(path):
    """A library meant to be imported by name (`import socket`) declares it
    with a `# nython: module` line among its first 20. Such a module runs in
    a scope of its own and its classes are named "module.Class" (round 77),
    so its names cannot collide with anyone else's."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f):
            if n >= 20:
                break
            if line.strip().startswith(MODULE_MARK):
                return True
    return False


def scan(classes_only):
    defs = {}
    for path in sorted(glob.glob(os.path.join(REPO, "lib", "**", "*.ny"), recursive=True)):
        rel = os.path.relpath(path, REPO)
        if is_module(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                m = CLASS_RE.match(line)
                kind = "class"
                if not m and not classes_only:
                    m = DEF_RE.match(line)
                    kind = "def"
                if m:
                    defs.setdefault(m.group(1), []).append((rel, n, kind))
    return {k: v for k, v in defs.items() if len(v) > 1}


def main(argv):
    dups = scan("--classes" in argv)
    if not dups:
        print("ny_classcheck: no duplicate top-level names in lib/")
        return 0
    for name in sorted(dups):
        print(name)
        for rel, n, kind in dups[name]:
            print("  %s:%d  (%s)" % (rel, n, kind))
    print("ny_classcheck: %d name(s) defined more than once" % len(dups))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
