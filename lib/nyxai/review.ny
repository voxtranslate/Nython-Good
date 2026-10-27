# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai/review.ny - code review rules that analyse the program, and the
# mechanical fixes for them, shown as a diff before they are applied
# (round 82).
#
#     from nyxai.review import Reviewer, fix_text
#     rv = Reviewer()
#     for f in rv.review_text(source, "app.ny"):
#         print(f.cite(), f.rule, f.message, "->", f.suggestion)
#     new, diff, applied = fix_text(source, rv.review_text(source, "app.ny"), "app.ny")
#
# Rules (each finding has a file:line, a message and a fix suggestion; the
# ones marked * are fixed mechanically by fix_text / @fix):
#   unused-import *       a name an import binds is read nowhere it is visible
#   unused-variable *     a local assigned and never read in its function -
#                         def-use from text_defuse (the real parser's
#                         per-statement reads and writes), closures included
#   unreachable-code *    statements after a return/raise/break/continue (or
#                         an if/try whose every branch ends so)
#   shadowed-builtin      a parameter, local or module name hides a builtin
#   mutable-default *     a list/dict/set default, shared between calls
#   bare-except *         `except:` also catches KeyboardInterrupt/SystemExit
#   none-comparison *     `x == None` (identity is meant: `x is None`)
#   too-complex           McCabe's cyclomatic complexity above the limit (10)
#   missing-self *        a method without parameters (and, as a convention,
#                         one whose first parameter is not self/cls)
#   inconsistent-return * some returns give a value and some do not (or the
#                         end can be reached): PEP 8's rule
# Fixes are line edits; overlapping ones are applied first come, first
# served, and fix_text returns the unified diff (difflib, patience
# algorithm) of what it changed.
#
# Not here: type errors, style (line length, naming), and anything that
# needs to run the program (nyxai.testgen does that).

__all__ = ["Reviewer", "Finding", "fix_text", "apply_edits", "unified_diff_text", "RULES"]

import re
import difflib
from nyxai.facts import ModuleInfo, PY_BUILTINS

RULES = ["unused-import", "unused-variable", "unreachable-code", "shadowed-builtin", "mutable-default",
         "bare-except", "none-comparison", "too-complex", "missing-self", "inconsistent-return"]

SEVERITY = {"unused-import": "warning", "unused-variable": "warning", "unreachable-code": "warning",
            "shadowed-builtin": "warning", "mutable-default": "warning", "bare-except": "warning",
            "none-comparison": "convention", "too-complex": "refactor", "missing-self": "error",
            "inconsistent-return": "refactor"}

# builtins worth warning about (constants, exceptions and Nython's own
# spellings left out)
SHADOWABLE = set(["abs", "all", "any", "ascii", "bin", "bool", "breakpoint", "bytearray", "bytes", "callable",
                  "chr", "compile", "complex", "dict", "dir", "divmod", "enumerate", "eval", "exec", "filter",
                  "float", "format", "frozenset", "getattr", "globals", "hasattr", "hash", "help", "hex", "id",
                  "input", "int", "isinstance", "issubclass", "iter", "len", "list", "locals", "map", "max",
                  "min", "next", "object", "oct", "open", "ord", "pow", "print", "range", "repr", "reversed",
                  "round", "set", "setattr", "slice", "sorted", "str", "sum", "super", "tuple", "type", "vars",
                  "zip"])

MUTABLE_CALLS = set(["list", "dict", "set", "bytearray", "defaultdict", "collections.defaultdict", "deque",
                     "collections.deque", "OrderedDict", "collections.OrderedDict", "Counter",
                     "collections.Counter"])


class Finding:
    def __init__(self, rel, line, rule, message, suggestion, edits=None):
        self.rel = rel
        self.line = line
        self.rule = rule
        self.severity = SEVERITY.get(rule, "warning")
        self.message = message
        self.suggestion = suggestion
        self.edits = edits if edits is not None else []

    def fixable(self):
        return len(self.edits) > 0

    def cite(self):
        return self.rel + ":" + str(self.line)

    def to_dict(self):
        return {"file": self.rel, "line": self.line, "rule": self.rule, "severity": self.severity,
                "message": self.message, "suggestion": self.suggestion, "fixable": self.fixable()}

    def __repr__(self):
        return "<Finding " + self.cite() + " " + self.rule + ">"


def _indent(s):
    n = 0
    while n < len(s) and (s[n] == " " or s[n] == "\t"):
        n += 1
    return s[0:n]


def _edit(line, end, new):
    """Replace lines line..end (1-based, inclusive) by `new` (a list of
    lines); end = line - 1 inserts before `line`."""
    return {"line": line, "end": end, "new": new}


def apply_edits(lines, edits):
    """Applies non-overlapping line edits (later ones that overlap an
    earlier one are skipped); returns [new lines, edits applied]."""
    order = sorted(range(len(edits)), key=lambda i: (edits[i]["line"], edits[i]["end"], i))
    taken = []
    used = []
    for i in order:
        e = edits[i]
        lo = e["line"]
        hi = max(e["end"], e["line"] - 1)
        clash = False
        for t in taken:
            # an insertion (hi < lo) clashes only with an edit that replaces its line
            if hi >= lo:
                if not (hi < t[0] or lo > t[1]):
                    clash = True
            elif t[1] >= t[0] and lo > t[0] and lo <= t[1]:
                clash = True
        if not clash:
            taken.append([lo, hi])
            used.append(e)
    out = list(lines)
    for e in sorted(used, key=lambda e: (-e["line"], -e["end"])):
        lo = e["line"]
        hi = e["end"]
        if hi < lo:
            out[lo - 1:lo - 1] = e["new"]
        else:
            out[lo - 1:hi] = e["new"]
    return [out, used]


def unified_diff_text(old, new, rel):
    a = [l + "\n" for l in old.split("\n")]
    b = [l + "\n" for l in new.split("\n")]
    return "".join(difflib.unified_diff(a, b, "a/" + rel, "b/" + rel, algorithm="patience"))


def fix_text(text, findings, rel="<text>"):
    """Applies the fixable findings' edits to text; [new text, diff, findings fixed]."""
    edits = []
    owner = []
    for f in findings:
        for e in f.edits:
            edits.append(e)
            owner.append(f)
    res = apply_edits(text.split("\n"), edits)
    used = res[1]
    fixed = []
    for i in range(len(edits)):
        if edits[i] in used and owner[i] not in fixed:
            fixed.append(owner[i])
    new = "\n".join(res[0])
    return [new, unified_diff_text(text, new, rel), fixed]


# The end of an expression starting at s[i]: the next top-level `,` or the
# bracket that closes the enclosing one (strings skipped).
def _expr_end(s, i):
    depth = 0
    q = ""
    j = i
    while j < len(s):
        ch = s[j]
        if q != "":
            if ch == "\\":
                j += 2
                continue
            if ch == q:
                q = ""
        elif ch == "'" or ch == '"':
            q = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return j
            depth -= 1
        elif ch == "," and depth == 0:
            return j
        j += 1
    return j


class Reviewer:
    def __init__(self, max_complexity=10, rules=None):
        self.max_complexity = max_complexity
        self.rules = rules if rules is not None else list(RULES)

    def review_text(self, text, rel="<text>"):
        return self.review_module(ModuleInfo(rel, rel, text))

    def review_module(self, m):
        out = []
        if m.error is not None:
            out.append(Finding(m.rel, m.error[0], "syntax-error", "the file does not parse: " + m.error[1],
                               "fix the syntax error first; no other rule ran"))
            return out
        du = text_defuse(m.text)
        for rule in self.rules:
            fn = getattr(self, "_r_" + rule.replace("-", "_"))
            fn(m, du, out)
        return sorted(out, key=lambda f: (f.line, RULES.index(f.rule) if f.rule in RULES else 99))

    # ── helpers ──────────────────────────────────────────────────────────────
    def _line(self, m, n):
        if n >= 1 and n <= len(m.lines):
            return m.lines[n - 1]
        return ""

    def _reads_in(self, du, lo, hi):
        s = set()
        for ln in range(max(lo, 1), min(hi, len(du)) + 1):
            e = du[ln - 1]
            if e is not None and "reads" in e:
                for r in e["reads"]:
                    s.add(r)
        return s

    def _header_end(self, m, f):
        """The line of a def's header that ends with its colon."""
        ln = f.line
        depth = 0
        while ln <= len(m.lines):
            t = m.lines[ln - 1]
            for ch in t:
                if ch in "([{":
                    depth += 1
                elif ch in ")]}":
                    depth -= 1
            if depth <= 0 and t.rstrip().endswith(":"):
                return ln
            ln += 1
        return f.line

    # ── rules ────────────────────────────────────────────────────────────────
    def _r_unused_import(self, m, du, out):
        all_reads = set(m.top.reads)
        for f in m.functions:
            for r in f.reads:
                all_reads.add(r)
        exported = set()
        for x in re.findall(r"__all__\s*=\s*\[([^\]]*)\]", m.text):
            for nm in re.findall(r"[\"']([A-Za-z_][A-Za-z0-9_]*)[\"']", x):
                exported.add(nm)
        for im in m.imports:
            if im["quoted"]:
                continue
            ln = im["line"]
            inner = m.function_at(ln)
            reads = all_reads
            if inner is not None:
                reads = self._reads_in(du, inner.first, inner.end)
            names = []
            if len(im["names"]) > 0:
                for n in im["names"]:
                    b = n.split(" as ")[-1].strip()
                    if b != "*":
                        names.append([n, b])
            elif im["alias"] != "":
                names.append([im["module"] + " as " + im["alias"], im["alias"]])
            else:
                names.append([im["module"], im["module"].split(".")[0]])
            unused = [x for x in names if x[1] not in reads and x[1] not in exported and not x[1].startswith("_")]
            if len(unused) == 0:
                continue
            text = self._line(m, ln)
            for x in unused:
                edits = []
                st = text.strip()
                if len(names) == 1 and (st.startswith("import ") or st.startswith("from ")) and ";" not in st and not st.endswith("\\") and "(" not in st:
                    edits = [_edit(ln, ln, [])]
                elif len(names) > 1 and st.startswith("from ") and " import " in st and "(" not in st and ";" not in st and len(unused) < len(names):
                    keep = [y[0] for y in names if y not in unused]
                    head = st[0:st.index(" import ") + 8]
                    edits = [_edit(ln, ln, [_indent(text) + head + ", ".join(keep)])]
                what = "'" + x[1] + "'"
                out.append(Finding(m.rel, ln, "unused-import", "unused import " + what,
                                   "remove the import of " + what, edits))
                if len(names) > 1:
                    break   # one edit rewrites the line for all of them

    def _r_unused_variable(self, m, du, out):
        for f in m.functions:
            cand = {}
            # names the function's own statements write (text_defuse), plain
            # names only (the facts' writes leave attribute targets out)
            plain = set(f.writes)
            for ln in range(f.first, min(f.end, len(du)) + 1):
                e = du[ln - 1]
                if e is None or not e.get("stmt", False) or e.get("func_line", 0) != f.line:
                    continue
                if e.get("kind") not in ["assign", "augassign", "with", "except"]:
                    continue
                for w in e["writes"]:
                    if w in plain and w not in cand:
                        cand[w] = ln
            if len(cand) == 0:
                continue
            reads = self._reads_in(du, f.first, f.end)
            params = set(p.name for p in f.params)
            for name in sorted(cand, key=lambda n: (cand[n], n)):
                if name in reads or name in params or name in f.globals or name in f.nonlocals:
                    continue
                if name.startswith("_") or name == "self":
                    continue
                ln = cand[name]
                text = self._line(m, ln)
                edits = []
                mt = re.match(r"^(\s*)(?:var\s+|let\s+)?" + name + r"\s*=\s*(.+)$", text)
                nxt = self._line(m, ln + 1)
                single = len(_indent(nxt)) <= len(_indent(text)) or nxt.strip() == ""
                if mt is not None and single and "#" not in text and not mt.group(2).startswith("="):
                    value = mt.group(2).strip()
                    if "(" in value:
                        edits = [_edit(ln, ln, [mt.group(1) + value])]
                    else:
                        edits = [_edit(ln, ln, [])]
                out.append(Finding(m.rel, ln, "unused-variable",
                                   "local variable '" + name + "' is assigned to but never used (in " + f.qualname + ")",
                                   "remove the assignment, or use '_' if the value is meant to be discarded", edits))

    def _r_unreachable_code(self, m, du, out):
        for u in m.unreachable:
            lo = u[0]
            hi = u[1]
            # a block cannot be left empty: keep a `pass` if the terminator
            # was the block's only statement (it never is: it comes first)
            out.append(Finding(m.rel, lo, "unreachable-code",
                               "unreachable code after '" + u[3] + "' on line " + str(u[2]),
                               "remove lines " + str(lo) + "-" + str(hi) + ", or move them before line " + str(u[2]),
                               [_edit(lo, hi, [])]))

    def _r_shadowed_builtin(self, m, du, out):
        seen = set()
        for f in m.functions:
            for p in f.params:
                if p.name in SHADOWABLE:
                    key = (f.line, p.name)
                    if key not in seen:
                        seen.add(key)
                        out.append(Finding(m.rel, f.line, "shadowed-builtin",
                                           "parameter '" + p.name + "' of " + f.qualname + " shadows the builtin " + p.name + "()",
                                           "rename it, e.g. '" + p.name + "_'"))
            for w in f.writes:
                if w in SHADOWABLE and w not in [p.name for p in f.params]:
                    ln = self._first_write(du, f, w)
                    out.append(Finding(m.rel, ln, "shadowed-builtin",
                                       "local '" + w + "' in " + f.qualname + " shadows the builtin " + w + "()",
                                       "rename it, e.g. '" + w + "_'"))
        for w in m.top.writes:
            if w in SHADOWABLE:
                ln = self._first_write(du, m.top, w)
                out.append(Finding(m.rel, ln, "shadowed-builtin",
                                   "module-level '" + w + "' shadows the builtin " + w + "()",
                                   "rename it, e.g. '" + w + "_'"))

    def _first_write(self, du, f, name):
        lo = f.first if f.qualname != "<module>" else 1
        hi = f.end
        for ln in range(max(lo, 1), min(hi, len(du)) + 1):
            e = du[ln - 1]
            if e is None or not e.get("stmt", False):
                continue
            if f.qualname != "<module>" and e.get("func_line", 0) != f.line:
                continue
            if f.qualname == "<module>" and e.get("func", "") != "":
                continue
            if name in e["writes"]:
                return ln
        return f.line

    def _r_mutable_default(self, m, du, out):
        for f in m.functions:
            for p in f.params:
                dk = p.default_kind
                if dk is None:
                    continue
                mutable = dk == "list" or dk == "dict" or dk == "set"
                if dk.startswith("call:") and dk[5:] in MUTABLE_CALLS:
                    mutable = True
                if not mutable:
                    continue
                edits = self._fix_mutable_default(m, f, p)
                out.append(Finding(m.rel, f.line, "mutable-default",
                                   "default value " + p.default + " of parameter '" + p.name + "' in " + f.qualname +
                                   " is created once and shared between calls",
                                   "use None as the default and create the value in the body", edits))

    def _fix_mutable_default(self, m, f, p):
        hend = self._header_end(m, f)
        for ln in range(f.line, hend + 1):
            t = self._line(m, ln)
            mt = re.search(r"\b" + p.name + r"\s*(:[^=,()]*)?=\s*", t)
            if mt is None:
                continue
            st = mt.end()
            en = _expr_end(t, st)
            src = t[st:en].strip()
            if src == "":
                return []
            new_line = t[0:st] + "None" + t[en:]
            # the body's indentation, after the docstring
            body_ln = hend + 1
            if f.doc_line > 0:
                body_ln = f.doc_line
                # past the docstring's closing quotes
                d = self._line(m, body_ln)
                q = '"""' if '"""' in d else ("'''" if "'''" in d else "")
                if q != "" and d.count(q) < 2:
                    k = body_ln + 1
                    while k <= len(m.lines) and q not in self._line(m, k):
                        k += 1
                    body_ln = k
                body_ln += 1
            ind = _indent(self._line(m, hend + 1))
            if ind == "":
                ind = _indent(self._line(m, f.line)) + "    "
            return [_edit(ln, ln, [new_line]),
                    _edit(body_ln, body_ln - 1, [ind + "if " + p.name + " is None:", ind + "    " + p.name + " = " + src])]
        return []

    def _r_bare_except(self, m, du, out):
        for ln in m.bare_excepts:
            t = self._line(m, ln)
            edits = []
            mt = re.search(r"\bexcept\s*:", t)
            if mt is not None:
                edits = [_edit(ln, ln, [t[0:mt.start()] + "except Exception:" + t[mt.end():]])]
            out.append(Finding(m.rel, ln, "bare-except",
                               "bare 'except:' also catches KeyboardInterrupt and SystemExit",
                               "catch Exception (or the exceptions you expect)", edits))

    def _r_none_comparison(self, m, du, out):
        done = set()
        for nc in m.none_compares:
            ln = nc[0]
            op = nc[1]
            if (ln, op) in done:
                continue
            done.add((ln, op))
            t = self._line(m, ln)
            new = t
            if op == "==":
                new = re.sub(r"\s*==\s*(None|none)\b", r" is \1", t)
            else:
                new = re.sub(r"\s*!=\s*(None|none)\b", r" is not \1", t)
            edits = []
            if new != t:
                edits = [_edit(ln, ln, [new])]
            want = "is" if op == "==" else "is not"
            out.append(Finding(m.rel, ln, "none-comparison",
                               "comparison to None with '" + op + "'",
                               "use '" + want + " None': None is a singleton, and == can be overridden", edits))

    def _r_too_complex(self, m, du, out):
        for f in m.functions:
            if f.complexity > self.max_complexity:
                out.append(Finding(m.rel, f.line, "too-complex",
                                   f.qualname + " is too complex (cyclomatic complexity " + str(f.complexity) +
                                   " > " + str(self.max_complexity) + ")",
                                   "split it into smaller functions (each branch is another path to test)"))

    def _r_missing_self(self, m, du, out):
        for f in m.functions:
            if f.cls == "" or f.parent != "":
                continue
            if "staticmethod" in f.decorators:
                continue
            if len(f.params) == 0:
                t = self._line(m, f.line)
                edits = []
                mt = re.search(r"\bdef\s+" + f.name + r"\s*\(\s*\)", t)
                first = "cls" if "classmethod" in f.decorators else "self"
                if mt is not None:
                    edits = [_edit(f.line, f.line, [t[0:mt.start()] + "def " + f.name + "(" + first + ")" + t[mt.end():]])]
                out.append(Finding(m.rel, f.line, "missing-self",
                                   "method " + f.qualname + " has no '" + first + "' parameter",
                                   "add '" + first + "' as its first parameter (or make it a @staticmethod)", edits))
            else:
                p0 = f.params[0].name
                want = ["cls", "mcs", "metacls"] if ("classmethod" in f.decorators or f.name == "__new__" or f.name == "__init_subclass__" or f.name == "__class_getitem__") else ["self", "this"]
                if p0 not in want and f.params[0].kind != "var_positional":
                    r = Finding(m.rel, f.line, "missing-self",
                                "first parameter '" + p0 + "' of method " + f.qualname + " is not named '" + want[0] + "'",
                                "name it '" + want[0] + "' (it receives the " + ("class" if want[0] == "cls" else "instance") + ")")
                    r.severity = "convention"
                    out.append(r)

    def _r_inconsistent_return(self, m, du, out):
        for f in m.functions:
            if f.is_generator or f.name == "__init__":
                continue
            valued = [r for r in f.returns if r[1]]
            if len(valued) == 0:
                continue
            bare = [r for r in f.returns if not r[1] and r[2] == ""]
            if len(bare) == 0 and not f.end_reachable:
                continue
            edits = []
            for r in bare:
                t = self._line(m, r[0])
                mt = re.match(r"^(\s*)return\s*(#.*)?$", t)
                if mt is not None:
                    edits.append(_edit(r[0], r[0], [mt.group(1) + "return None" + ((" " + mt.group(2)) if mt.group(2) is not None else "")]))
            if f.end_reachable:
                # after the function's last code line, at the body's indentation
                last = f.end
                while last > f.line and (self._line(m, last).strip() == "" or self._line(m, last).strip().startswith("#")):
                    last -= 1
                ind = _indent(self._line(m, self._header_end(m, f) + 1))
                if ind == "":
                    ind = _indent(self._line(m, f.line)) + "    "
                edits.append(_edit(last + 1, last, [ind + "return None"]))
            how = []
            if len(bare) > 0:
                how.append("a bare 'return' on line " + ", ".join(str(r[0]) for r in bare))
            if f.end_reachable:
                how.append("the end can be reached (an implicit None)")
            out.append(Finding(m.rel, f.line, "inconsistent-return",
                               f.qualname + " returns a value on line " + ", ".join(str(r[0]) for r in valued) +
                               " but not always: " + "; ".join(how),
                               "return None explicitly where no value is returned (PEP 8)", edits))
