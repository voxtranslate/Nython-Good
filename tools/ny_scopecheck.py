#!/usr/bin/env python3
"""tools/ny_scopecheck.py - where Nython's binding rule and Python's differ (round 85).

Nython's rule: inside a function a plain assignment rebinds the nearest
existing binding (an enclosing function's, then the module's) and makes a
local only when there is none. Python's: a name a function binds anywhere
is a local of the whole function unless declared global / nonlocal.
Python-language source (.py, `# nython: python`) follows Python's rule
(src/NyScope.cpp); everything else Nython's.

This is the census: for every function in the files given (default: every
lib/**/*.ny and the IDE's own .ny files), each name a function assigns,
augments or deletes that an enclosing function or the module binds, with no
global / nonlocal / var for it. The cases come from the parser itself
(`nython --scope-report`, NyScope.cpp's differences()), so they are what
the engines see. Each is classified:

  (a) rebind   the function uses the outer value - an augmented assignment,
               a del, or a read of the name on or before the line of the
               first write: a rebinding meant, which needs `global x` /
               `nonlocal x` (correct under both rules). Under Python's rule
               without it: UnboundLocalError (or a silent local).
  (b) clobber  the function writes first, over a name the outer scope binds
               with a def, class or import (a function / class / module
               replaced by a local's value): a local was meant - a real bug
               under Nython's rule; `var x` fixes it (or nothing, once the
               file is Python-language).
  (c) unclear  the function writes first over an outer variable: a local
               under Python's rule, the outer variable under Nython's - which
               one was meant needs reading; or it reads a name before a local
               binding of it (a for / with / except target, import, def, var):
               the outer variable under Nython's rule, UnboundLocalError under
               Python's. Listed.

    python3 tools/ny_scopecheck.py                    # summary of lib/ + the IDE
    python3 tools/ny_scopecheck.py --list [a|b|c] [files...]
    python3 tools/ny_scopecheck.py --python-ready [files...]
                     # the files whose functions bind as Python's rule says
                     # they should: no case (a) or (c) left (case (b) is what
                     # marking them `# nython: python` fixes)
    python3 tools/ny_scopecheck.py --fix [files...]  # adds the declarations
                     # case (a) needs (global / nonlocal), in place - a
                     # migration in the spirit of 2to3 / pyupgrade, driven by
                     # the parser's own scope analysis
    python3 tools/ny_scopecheck.py --fix-locals [files...]  # `var` for case
                     # (b) in Nython-language files

--bin picks the binary (default build/nython-cli).
"""
import argparse
import collections
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

Case = collections.namedtuple("Case", "file line col func name how outer oline okind uses rule defline insline")

KIND = {"p": "parameter", "d": "def", "c": "class", "i": "import", "v": "var", "t": "target",
        "n": "enum/namespace", "a": "assignment", "g": "global"}


def default_files():
    out = []
    for d, _, fs in os.walk(os.path.join(ROOT, "lib")):
        for f in fs:
            if f.endswith(".ny"):
                out.append(os.path.join(d, f))
    for f in os.listdir(ROOT):
        if f.endswith(".ny") and (f.startswith("ide_") or f == "nython_ide.ny"):
            out.append(os.path.join(ROOT, f))
    return sorted(out)


def report(binary, files):
    cases, errors = [], []
    for k in range(0, len(files), 64):
        batch = files[k:k + 64]
        r = subprocess.run([binary, "--scope-report"] + batch, capture_output=True, text=True)
        for ln in r.stdout.splitlines():
            p = ln.split("\t")
            if len(p) != 13:
                continue
            cases.append(Case(p[0], int(p[1]), int(p[2]), p[3], p[4], p[5], p[6], int(p[7]), p[8],
                              p[9] == "1", p[10], int(p[11]), int(p[12])))
        if r.stderr.strip():
            errors.append(r.stderr.strip())
    return cases, errors


def classify(c):
    if c.how == "read":
        return "c"   # read before a local binding: which variable was meant needs reading
    if c.uses or c.how in ("aug", "del"):
        return "a"
    if c.okind in ("d", "c", "i", "n"):
        return "b"
    return "c"


def rel(f):
    try:
        return os.path.relpath(f, ROOT)
    except ValueError:
        return f


def describe(c):
    where = "the module" if c.outer == "module" else "the enclosing " + c.outer.replace("function:", "function ")
    verb = {"assign": "assigns", "aug": "augments", "del": "deletes", "read": "reads, before binding it,"}[c.how]
    return "%s:%d:%d: %s: %s '%s' of %s (%s, line %d)" % (
        rel(c.file), c.line, c.col, c.func, verb, c.name, where, KIND.get(c.okind, c.okind), c.oline)


def lines_of(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def fix_declarations(cases):
    """Case (a): `global x` / `nonlocal x` as the first statement of the function."""
    by_file = collections.defaultdict(list)
    for c in cases:
        if classify(c) == "a" and c.insline > 0:
            by_file[c.file].append(c)
    done = 0
    for f, cs in by_file.items():
        lines = lines_of(f)
        # one declaration line per function and kind, inserted bottom-up
        groups = collections.OrderedDict()
        for c in cs:
            kw = "global" if c.outer == "module" else "nonlocal"
            groups.setdefault((c.insline, kw), []).append(c.name)
        for (ins, kw), names in sorted(groups.items(), key=lambda g: -g[0][0]):
            if ins - 1 >= len(lines):
                continue
            target = lines[ins - 1]
            indent = target[:len(target) - len(target.lstrip())]
            names = sorted(set(names))
            lines.insert(ins - 1, indent + kw + " " + ", ".join(names) + "   # ny_scopecheck --fix (round 85)")
            done += len(names)
        write_lines(f, lines)
    return done


def fix_locals(cases):
    """Case (b) in a Nython-language file: the first write becomes `var x = ...`."""
    done = 0
    by_file = collections.defaultdict(list)
    for c in cases:
        if classify(c) == "b" and c.rule == "nython" and c.how == "assign":
            by_file[c.file].append(c)
    for f, cs in by_file.items():
        lines = lines_of(f)
        for c in sorted(cs, key=lambda c: (-c.line, -c.col)):
            ln = lines[c.line - 1]
            k = c.col - 1
            rest = ln[k + len(c.name):].lstrip()
            if ln[k:k + len(c.name)] == c.name and ln[:k].strip() == "" and rest.startswith("=") and not rest.startswith("=="):
                lines[c.line - 1] = ln[:k] + "var " + ln[k:]
                done += 1
        write_lines(f, lines)
    return done


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--bin", default=os.path.join(ROOT, "build", "nython-cli"))
    ap.add_argument("--list", nargs="?", const="abc", default=None)
    ap.add_argument("--python-ready", action="store_true")
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--fix-locals", action="store_true")
    a = ap.parse_args()
    files = [os.path.abspath(f) for f in a.files] or default_files()
    cases, errors = report(a.bin, files)
    for e in errors:
        print(e, file=sys.stderr)
    if a.fix:
        print("declarations added: %d" % fix_declarations(cases))
        return 0
    if a.fix_locals:
        print("var added: %d" % fix_locals(cases))
        return 0
    per = collections.defaultdict(lambda: collections.Counter())
    for c in cases:
        per[c.file][classify(c)] += 1
    if a.python_ready:
        for f in files:
            n = per.get(f, collections.Counter())
            if n["a"] == 0 and n["c"] == 0:
                print(rel(f))
        return 0
    if a.list is not None:
        for c in cases:
            if classify(c) in a.list:
                print("(%s) %s" % (classify(c), describe(c)))
        return 0
    total = collections.Counter(classify(c) for c in cases)
    print("%d files, %d cases: (a) rebind %d, (b) clobber %d, (c) unclear %d" % (
        len(files), len(cases), total["a"], total["b"], total["c"]))
    for f in sorted(per, key=lambda f: -sum(per[f].values())):
        n = per[f]
        print("  %-48s a %3d  b %3d  c %3d" % (rel(f), n["a"], n["b"], n["c"]))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
