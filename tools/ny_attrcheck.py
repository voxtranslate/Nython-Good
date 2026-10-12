#!/usr/bin/env python3
"""ny_attrcheck.py - find `self.name` reads that can miss the attribute.

Since round 75 reading an attribute an object does not have raises
AttributeError (it used to read none). A class that assigns `self.cache` only
in some method and reads it elsewhere with `if self.cache == none` worked by
accident before; now the read raises when it runs first. This checker lists,
statically, every `self.name` read in a class whose attribute is

  * assigned only outside construction time - not in __init__/init, not in a
    method __init__ calls (transitively), not in the class body - anywhere
    in the class's hierarchy ("lazy"), or
  * never assigned or defined anywhere in the hierarchy ("unknown").

Both need a look: initialise the attribute in __init__, or read it with
`self?.name` / getattr(self, "name", default) where absence is expected.

    python3 tools/ny_attrcheck.py                 # lib/, lib/nytorch/, the IDE
    python3 tools/ny_attrcheck.py FILE...         # just these files
    python3 tools/ny_attrcheck.py --lazy-only     # skip "unknown"

Exit status 1 if anything is reported.
"""
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_files():
    out = sorted(glob.glob(os.path.join(REPO, "lib", "*.ny")))
    out += sorted(glob.glob(os.path.join(REPO, "lib", "nytorch", "*.ny")))
    out += sorted(glob.glob(os.path.join(REPO, "ide_*.ny")))
    out.append(os.path.join(REPO, "nython_ide.ny"))
    return out


def strip_comment(line):
    out, q, i = [], None, 0
    while i < len(line):
        c = line[i]
        if q:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
            out.append(c)
        elif c == "#":
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def blank_strings(line):
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    return re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)


INIT_NAMES = {"__init__", "init"}
ASSIGN_RE = re.compile(r"\bself\.(\w+)\s*(?:=(?!=)|\?\?=|[-+*/%&|^]=|//=|\*\*=)")
SETATTR_RE = re.compile(r"\b(?:setattr\(\s*self\s*,|self\.register_(?:buffer|parameter|module)\()\s*[\"'](\w+)[\"']")
# Members every object answers (the object protocol, NyMembers.hpp).
PROTOCOL = {"class_name", "type_name", "to_string", "str", "id", "hash", "is_a", "instance_of",
            "equals_to", "same_as", "fields", "attributes", "__class__", "__dict__", "__name__"}
READ_RE = re.compile(r"(?<![\w?])self\.(\w+)")


def parse(files):
    classes = {}
    reads = []   # (file, line, class, method, attr)
    for path in files:
        if not os.path.exists(path):
            continue
        rel = os.path.relpath(path, REPO)
        cur = None
        cur_indent = 0
        meth = None
        meth_indent = None
        in_doc = False
        guards = []
        for ln, raw in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            text = raw.rstrip("\n")
            stripped = text.strip()
            # docstrings: skip triple-quoted blocks
            if in_doc:
                if '"""' in stripped or "'''" in stripped:
                    in_doc = False
                continue
            if stripped.startswith(('"""', "'''")):
                q = stripped[:3]
                if stripped.count(q) < 2:
                    in_doc = True
                continue
            raw_code = strip_comment(text)
            line = blank_strings(raw_code)
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip())
            m = re.match(r"^(\s*)class\s+(\w+)\s*(?:\(([^)]*)\))?\s*:", line)
            if m and (cur is None or len(m.group(1)) <= cur_indent):
                cur = m.group(2)
                cur_indent = len(m.group(1))
                bases = [b.strip() for b in (m.group(3) or "").split(",") if b.strip()]
                c = classes.setdefault(cur, {"bases": bases, "file": rel, "methods": set(), "body": set(),
                                             "assign": {}, "calls": {}})
                c["bases"] = bases
                meth = None
                continue
            if cur and indent <= cur_indent:
                cur = None
                meth = None
            if not cur:
                continue
            c = classes[cur]
            md = re.match(r"^(\s*)(?:async\s+)?def\s+(\w+)\s*\(", line)
            if md and (meth is None or len(md.group(1)) <= meth_indent):
                meth = md.group(2)
                meth_indent = len(md.group(1))
                c["methods"].add(meth)
                continue
            if meth is not None and indent <= meth_indent:
                meth = None
            if meth is None:
                # class body: `name = value`, decorators, nested defs
                mb = re.match(r"^\s*(\w+)\s*(?::[^=]*)?=(?!=)", line)
                if mb:
                    c["body"].add(mb.group(1))
                continue
            for ma in ASSIGN_RE.finditer(line):
                c["assign"].setdefault(ma.group(1), set()).add(meth)
            for ma in SETATTR_RE.finditer(raw_code):
                c["assign"].setdefault(ma.group(1), set()).add(meth)
            for mc in re.finditer(r"\bself\.(\w+)\s*\(", line):
                c["calls"].setdefault(meth, set()).add(mc.group(1))
            assigned_here = set(m.start(1) for m in ASSIGN_RE.finditer(line))
            # hasattr(self, "x") guards reads on its own line and in the block
            # its `if` opens.
            while guards and indent <= guards[-1][0]:
                guards.pop()
            guarded = set(re.findall(r"hasattr\(\s*self\s*,\s*[\"'](\w+)[\"']", raw_code))
            if guarded and re.match(r"^\s*(if|elif|while)\b", raw_code):
                guards.append((indent, guarded))
            for _, g in guards:
                guarded = guarded | g
            for mr in READ_RE.finditer(line):
                if mr.group(1) in guarded or mr.group(1) in PROTOCOL:
                    continue
                if mr.start(1) in assigned_here:
                    # `self.x = ...` is a store, but `self.x += 1` reads too
                    tail = line[mr.end():].lstrip()
                    if tail.startswith("=") or tail.startswith("??="):
                        continue
                reads.append((rel, ln, cur, meth, mr.group(1)))
    return classes, reads


def ancestors(classes, name, seen=None):
    seen = set() if seen is None else seen
    if name in seen or name not in classes:
        return []
    seen.add(name)
    out = [name]
    for b in classes[name]["bases"]:
        out += ancestors(classes, b, seen)
    return out


def descendants(classes, name):
    out, frontier = set(), {name}
    while frontier:
        nxt = set()
        for c, info in classes.items():
            if c not in out and c != name and any(b in frontier for b in info["bases"]):
                nxt.add(c)
        out |= nxt
        frontier = nxt
    return out


def init_time_methods(classes, cls):
    """Methods run while constructing an object whose class is `cls`, a base
    of it or a class derived from it: every __init__/init in that family and
    whatever they call through self (transitively)."""
    hier = ancestors(classes, cls) + sorted(descendants(classes, cls))
    calls = {}
    for c in hier:
        for m, cs in classes[c]["calls"].items():
            calls.setdefault(m, set()).update(cs)
    todo = [m for c in hier for m in classes[c]["methods"] if m in INIT_NAMES]
    seen = set(todo)
    while todo:
        m = todo.pop()
        for n in calls.get(m, ()):
            if n not in seen:
                seen.add(n)
                todo.append(n)
    return seen


def main(argv):
    lazy_only = "--lazy-only" in argv
    files = [a for a in argv if not a.startswith("--")]
    files = [os.path.abspath(f) for f in files] or default_files()
    # Always parse every library file for the class hierarchy.
    classes, _ = parse(default_files())
    c2, reads = parse(files)
    for k, v in c2.items():
        classes.setdefault(k, v)
    problems = []
    cache = {}
    for rel, ln, cls, meth, attr in reads:
        key = (cls, attr)
        if key not in cache:
            hier = ancestors(classes, cls)
            family = hier + sorted(descendants(classes, cls))
            defined = any(attr in classes[c]["methods"] or attr in classes[c]["body"] for c in family)
            where = set()
            for c in family:
                where |= classes[c]["assign"].get(attr, set())
            if defined:
                verdict = None
            elif not where:
                verdict = "unknown"
            else:
                init_ms = init_time_methods(classes, cls)
                verdict = None if where & init_ms else "lazy (assigned only in %s)" % ", ".join(sorted(where))
            cache[key] = verdict
        v = cache[key]
        if v is None or (lazy_only and v == "unknown"):
            continue
        if meth in init_time_methods(classes, cls) and v.startswith("lazy"):
            # read during construction of an attribute a later method sets:
            # still worth a look, reported the same way
            pass
        problems.append("%s:%d: %s.%s read in %s() - %s" % (rel, ln, cls, attr, meth, v))
    for p in problems:
        print(p)
    print("%d reads to check" % len(problems), file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
