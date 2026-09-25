#!/usr/bin/env python3
"""ide_lint.py - catch the IDE's silent-`none` bugs before they run.

Nython does not raise on a missing method or attribute: `obj.missing()` and
`obj.missing` both evaluate to `none` and execution carries on. That is how
`Font.height()` (never defined) put the Run button's label at y=0, and how the
toolbar chips read `theme.on_badge` (never defined) for rounds without anyone
noticing. This checker resolves, statically:

  * self.name(...) and self.name   against every class in the IDE's chain
  * th.name / self.th.name         against IDETheme
  * typed receivers (self.qi., self.git., self.dbg., b. / d.buf., fonts, ...)
    against their classes

and reports every name that no class defines. Exit status 1 if anything is
unresolved.

    python3 tools/ide_lint.py
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHAIN_FILES = ["ide_core.ny", "ide_ops.ny", "ide_paint.ny", "ide_views.ny", "nython_ide.ny"]
CHAIN_CLASSES = ["IDECore", "IDEOps", "IDEPaint", "IDEViews", "NythonIDE"]
SOURCE_FILES = CHAIN_FILES + ["ide_editor.ny", "ide_project.ny", "ide_icons.ny", "ide_workshop.ny",
                              "lib/ide_workbench.ny", "lib/ide_scm.ny", "lib/ide_debugger.ny",
                              "lib/ide_selection.ny", "lib/gui.ny", "lib/gui_motion.ny",
                              "lib/ide_toolchain.ny", "lib/ide_commands.ny", "lib/aiagent.ny", "lib/icons.ny"]

# Receiver expression (regex, matched right before ".name") -> class.
TYPED = [
    (r"self\.qi", "QuickInput"), (r"self\.git", "GitRepo"), (r"self\.dbg", "DebugSession"),
    (r"self\.reg", "CommandRegistry"), (r"self\.notes", "Notifications"), (r"self\.hits", "HitMap"),
    (r"self\.nav", "NavHistory"), (r"self\.frecency", "Frecency"), (r"self\.ws", "Workspace"),
    (r"self\.hl", "SyntaxHighlighter"), (r"self\.selmodel", "SelectionModel"), (r"self\.linediff", "LineDiff"),
    (r"self\.icons", "Icons"), (r"self\.win", "Window"), (r"self\.job", "BgProc"), (r"self\.term_proc", "BgProc"),
    (r"self\.cmdline", "CommandLine"), (r"self\.workshop", "LangWorkshopPanel"), (r"self\.ease", "Ease"),
    (r"self\.ai", "CodeAnalyzer"), (r"self\.qi\.fuzzy", "Fuzzy"),
    (r"self\.f_[a-z_]+", "Font"), (r"self\.buf\(\)", "EditorBuffer"), (r"\bb", "EditorBuffer"),
    (r"d\.buf", "EditorBuffer"), (r"self\.doc\(\)", "Doc"),
    (r"\bth", "IDETheme"), (r"self\.th", "IDETheme"), (r"\br", "Renderer"),
]
BUILTIN_ATTRS = {"append", "pop", "keys", "values", "has_key", "remove", "get", "items", "sort", "size"}


def strip_comment(line):
    out = []
    q = None
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            out.append(c)
            if c == "\\":
                if i + 1 < len(line):
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


def blank_comments(text):
    return "\n".join(strip_comment(ln) for ln in text.split("\n"))


def blank_strings(line):
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)


def parse_classes():
    classes = {}   # name -> {"bases": [...], "members": set()}
    for rel in SOURCE_FILES:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            continue
        cur = None
        for raw in open(path, encoding="utf-8", errors="replace"):
            line = strip_comment(raw.rstrip("\n"))
            m = re.match(r"^class\s+(\w+)\s*(?:\(([^)]*)\))?\s*:", line)
            if m:
                cur = m.group(1)
                bases = [b.strip() for b in (m.group(2) or "").split(",") if b.strip()]
                classes.setdefault(cur, {"bases": bases, "members": set(), "file": rel})
                continue
            if cur and line and not line[0].isspace():
                cur = None
            if cur:
                m2 = re.match(r"^\s+def\s+(\w+)\s*\(", line)
                if m2:
                    classes[cur]["members"].add(m2.group(1))
                for m3 in re.finditer(r"\bself\.(\w+)\s*=(?!=)", line):
                    classes[cur]["members"].add(m3.group(1))
    return classes


def members_of(classes, name, seen=None):
    if seen is None:
        seen = set()
    if name in seen or name not in classes:
        return set()
    seen.add(name)
    out = set(classes[name]["members"])
    for b in classes[name]["bases"]:
        out |= members_of(classes, b, seen)
    return out


def reserved_words():
    src = open(os.path.join(REPO, "src/Lexer.cpp"), encoding="utf-8", errors="replace").read()
    # Every word-shaped token, whatever its class (`new` is not classed as a
    # keyword, and `new = 1` is still a syntax error).
    return set(re.findall(r'TokenDef\(TokenType::\w+, std::string\("([a-z_]+)"\), TokenKind::Name', src)) | {"new", "struct", "module"}


def main():
    classes = parse_classes()
    chain = set()
    for c in CHAIN_CLASSES:
        chain |= members_of(classes, c)
    # Attributes assigned on the IDE from other classes' methods via `self.`
    # are already covered; attributes set on objects (th.sym_method) too:
    theme = members_of(classes, "IDETheme")
    for rel in CHAIN_FILES:
        for raw in open(os.path.join(REPO, rel), encoding="utf-8", errors="replace"):
            for m in re.finditer(r"self\.th\.(\w+)\s*=(?!=)", raw):
                theme.add(m.group(1))
    problems = []
    for rel in CHAIN_FILES:
        path = os.path.join(REPO, rel)
        cur = None
        for ln, raw in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            line = blank_strings(strip_comment(raw))
            mc = re.match(r"^class\s+(\w+)", line)
            if mc:
                cur = mc.group(1)
            elif line and not line[0].isspace():
                cur = None
            in_chain = cur in CHAIN_CLASSES
            own = members_of(classes, cur) if cur and not in_chain else set()
            # self.name / self.name(
            for m in re.finditer(r"\bself\.(\w+)", line):
                name = m.group(1)
                if in_chain and name not in chain:
                    problems.append("%s:%d: self.%s is not defined by the IDE class chain" % (rel, ln, name))
                elif cur and not in_chain and name not in own:
                    problems.append("%s:%d: self.%s is not defined by class %s" % (rel, ln, name, cur))
            if not in_chain:
                continue
            for pat, cls in TYPED:
                for m in re.finditer(r"(?<![\w.])" + pat + r"\.(\w+)", line):
                    name = m.group(1)
                    if pat in (r"\br",) and cls == "Renderer":
                        pass
                    mem = members_of(classes, cls)
                    if cls == "IDETheme":
                        mem = theme
                    if not mem:
                        continue
                    if name in mem or name in BUILTIN_ATTRS:
                        continue
                    # `self.X.Y` where Y is itself a further typed receiver
                    problems.append("%s:%d: %s.%s - %s has no member '%s'" % (rel, ln, pat.replace("\\", "").replace("b", "", 0), name, cls, name))
    # Names declared with a reserved word (var from = ..., def f(self, from)):
    # some of these parse, some are a syntax error only in statement position.
    kw = reserved_words()
    for rel in CHAIN_FILES + ["lib/ide_workbench.ny", "lib/ide_scm.ny", "lib/ide_debugger.ny", "ide_editor.ny"]:
        for ln, raw in enumerate(open(os.path.join(REPO, rel), encoding="utf-8", errors="replace"), 1):
            code = blank_strings(strip_comment(raw))
            names = set(re.findall(r"\bvar\s+([A-Za-z_]\w*)", code))
            names |= set(re.findall(r"^\s*([A-Za-z_]\w*)\s*=[^=]", code))
            for m in re.finditer(r"\bdef\s+\w+\s*\(([^)]*)\)", code):
                for p in m.group(1).split(","):
                    p = p.split("=")[0].strip()
                    if p:
                        names.add(p)
            for bad in sorted((names & kw) - {"self"}):
                problems.append("%s:%d: '%s' is a reserved word" % (rel, ln, bad))
    # `def init(...)` is a constructor alias in this interpreter (nytorch
    # relies on it): calling Class() runs it. A method that merely happens to
    # be called init therefore runs at construction time.
    for rel in SOURCE_FILES:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path) or not (rel.startswith("ide_") or rel.startswith("lib/ide_") or rel == "nython_ide.ny"):
            continue
        for ln, raw in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            if re.match(r"^\s+def\s+init\s*\(", raw):
                problems.append("%s:%d: a method named 'init' is run as a constructor" % (rel, ln))
    # Dead clicks. Every command a menu, palette entry, button or keybinding
    # can name must have a branch in the dispatcher, and every internal
    # "@target" a painter registers in the hit map must be handled by the
    # click router - otherwise the item draws, highlights on hover, and does
    # nothing when clicked.
    chain_src = ""
    for rel in CHAIN_FILES:
        chain_src += blank_comments(open(os.path.join(REPO, rel), encoding="utf-8", errors="replace").read())
    ids = re.findall(r'(?<![\w])_cmd\("([^"@][^"]*)"', chain_src)
    handled = set(re.findall(r'\bid == "([^"]+)"', chain_src))
    prefixes = re.findall(r'string_startswith\(id, "([^"]+)"\)', chain_src)
    for cid in ids:
        if cid not in handled and not any(cid.startswith(pf) for pf in prefixes):
            problems.append("command '%s' is registered but _exec has no branch for it" % cid)
    targets = set(re.findall(r'"(@[a-z][\w.]*)"', re.sub(r'string_startswith\(cmd, "[^"]*"\)', "", chain_src)))
    routed = set(re.findall(r'cmd == "(@[\w.]+)"', chain_src)) | set(re.findall(r'\bc == "(@[\w.]+)"', chain_src))
    # Only exact comparisons count: `string_startswith(cmd, "@dbg")` merely
    # routes to a sub-handler, which must then name the target itself.
    for t in sorted(targets):
        if t not in routed:
            problems.append("click target '%s' is drawn but nothing handles a click on it" % t)
    seen = set()
    for p in problems:
        if p not in seen:
            seen.add(p)
            print(p)
    print("%d unresolved name(s)" % len(seen))
    return 1 if seen else 0


if __name__ == "__main__":
    sys.exit(main())
