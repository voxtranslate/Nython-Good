# vm_audit105.ny - lib/aiagent.ny's NyxAgent: an offline, deterministic
# programming agent (round 82). Nython-only (it reads the engine's own
# parser through ny_facts / text_defuse).
#
# On a small fixture workspace written here: retrieval rankings (BM25F,
# definitions over uses, call-graph neighbours, incremental updates, a JSON
# round trip), per-function facts and the call / import graphs, the rule
# engine's inferences (recursion, may-raise through calls, purity, unused
# functions; stratified negation, explanations), generated unit tests that
# run and pass (and a shrunk counterexample), drafted docstrings, review
# findings at exact lines and the fixes applied, the completion model's mean
# reciprocal rank before and after training, and GitHubLearner against a
# local http.server.
#
#     ./build/nython-cli examples/vm_audit105.ny
#     ./build/nython-cli --vm examples/vm_audit105.ny
import "lib/aiagent.ny"
import os
import sys
import json
import shutil
import threading
from nyxai.rules import RuleEngine
from nyxai.index import WorkspaceIndex, terms_of, stem
from nyxai.facts import ProgramModel
from nyxai.review import Reviewer, fix_text, apply_edits
from nyxai.testgen import TestGenerator, domain_of, doctest_examples, shrink_candidates
from nyxai.docgen import draft_docstring, summary_from_name

results = []

def check(name, got, want):
    results.append([name, repr(got) == repr(want), got, want])

ROOT = os.path.join(os.path.abspath(os_gettempdir()), "nyx105_" + str(os.getpid()))
if os.path.isdir(ROOT):
    shutil.rmtree(ROOT)
os.makedirs(ROOT)

def write(rel, text):
    p = os.path.join(ROOT, rel)
    d = os.path.dirname(p)
    if not os.path.isdir(d):
        os.makedirs(d)
    with open(p, "w") as fh:
        fh.write(text)
    return p

MATHX = '''"""Small numeric helpers."""
LIMIT = 100


def clamp(x: int, lo: int = 0, hi: int = 10) -> int:
    """Clamp x into the range [lo, hi].

    >>> clamp(15)
    10
    >>> clamp(-3)
    0
    """
    if lo > hi:
        raise ValueError("lo > hi")
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def ratio(a, b):
    return a / b


def scale(values, factor=2):
    out = []
    for v in values:
        out.append(clamp(v * factor, -LIMIT, LIMIT))
    return out


def month_name(m: int) -> str:
    """The month's short name; months count from 1."""
    names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    if m < 1:
        raise ValueError("months count from 1")
    return names[m - 1]
'''

CONFIG = '''"""Reading the application's settings."""
import mathx


def parse_config(text):
    """Parse KEY=VALUE lines into a dict of settings."""
    cfg = {}
    for line in text.split("\\n"):
        line = line.strip()
        if line == "" or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError("bad line: " + line)
        parts = line.split("=", 1)
        cfg[parts[0].strip()] = parts[1].strip()
    return cfg


def load_config(path):
    # read the settings file from disk
    with open(path) as f:
        return parse_config(f.read())


def setting_ratio(cfg):
    return mathx.ratio(int(cfg["num"]), int(cfg["den"]))
'''

APP = '''from config import load_config
from mathx import scale


def main(path):
    cfg = load_config(path)
    print(scale([1, 2, 3]))
    return cfg


def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


counter = 0


def bump():
    global counter
    counter = counter + 1
    return counter
'''

README = '''# Demo project

## Configuration
Settings live in a KEY=VALUE file; parse_config reads them and load_config opens the file.

## Numbers
clamp keeps a number within bounds.
'''

BAD = '''import os
import json


def collect(item, bucket=[]):
    bucket.append(item)
    return bucket


def check(x):
    unused = 42
    if x == None:
        return
    return x * 2


def stop(a):
    return a
    print("never")


def risky():
    try:
        return int("x")
    except:
        return 0


class Box:
    def size():
        return 3


def list(items):
    return items


def grade(s):
    if s > 90 and s < 101:
        return "A"
    elif s > 80:
        return "B"
    elif s > 70:
        return "C"
    elif s > 60:
        return "D"
    elif s > 50 or s == 49:
        return "E"
    for i in range(3):
        if i == s:
            return "I"
    while s > 1000:
        s = s - 1
    return "F" if s >= 0 else "?"


print(json.dumps({}))
'''

write("mathx.ny", MATHX)
write("config.ny", CONFIG)
write("app.ny", APP)
write("README.md", README)
write("lint/bad.ny", BAD)

# ── ny_facts: the real parser's facts ────────────────────────────────────────
F = ny_facts(MATHX)
fns = {}
for f in F["functions"]:
    fns[f["name"]] = f
check("facts: no syntax error, the module docstring", [F["error"], F["doc"]], [none, "Small numeric helpers."])
check("facts: the functions in order", [f["name"] for f in F["functions"]], ["clamp", "ratio", "scale", "month_name"])
c = fns["clamp"]
check("facts: clamp's parameters", [[p["name"], p["kind"], p["default"], p["annotation"]] for p in c["params"]],
      [["x", "positional_or_keyword", none, "int"], ["lo", "positional_or_keyword", "0", "int"], ["hi", "positional_or_keyword", "10", "int"]])
check("facts: clamp's lines, return annotation", [c["line"], c["end"], c["return_annotation"], c["doc_line"]], [5, 19, "int", 6])
check("facts: clamp's returns", c["returns"], [[16, true, "lo"], [18, true, "hi"], [19, true, "x"]])
check("facts: clamp raises", c["raises"], [[14, "ValueError", "ValueError('lo > hi')"]])
check("facts: clamp's complexity and end", [c["complexity"], c["end_reachable"]], [4, false])
check("facts: scale's calls", fns["scale"]["calls"], [[29, "out.append"], [29, "clamp"]])
check("facts: scale's reads and writes", [sorted(fns["scale"]["reads"]), fns["scale"]["writes"]],
      [["LIMIT", "clamp", "factor", "out", "v", "values"], ["values", "factor", "out", "v"]])
check("facts: ratio falls off nowhere, month_name's raise", [fns["ratio"]["end_reachable"], fns["month_name"]["raises"][0][1]], [false, "ValueError"])
G = ny_facts(CONFIG)
check("facts: imports", [[i["line"], i["module"]] for i in G["imports"]], [[2, "mathx"]])
check("facts: parse_config's complexity (for, if, or, if)", [f["complexity"] for f in G["functions"] if f["name"] == "parse_config"], [5])
B = ny_facts(BAD)
check("facts: unreachable code after return", B["unreachable"], [[19, 19, 18, "return"]])
check("facts: bare except, == None", [B["bare_excepts"], B["none_compares"]], [[25], [[12, "=="]]])
check("facts: a class and its methods", [[k["name"], k["line"], k["methods"]] for k in B["classes"]], [["Box", 29, ["size"]]])
D = ny_facts("def f(a, /, b, *args, c=[1], d: str = 'x', **kw):\n    yield a\n\n@staticmethod\ndef g(): pass\n")
check("facts: parameter kinds", [[p["name"], p["kind"]] for p in D["functions"][0]["params"]],
      [["a", "positional_only"], ["b", "positional_or_keyword"], ["args", "var_positional"], ["c", "keyword_only"], ["d", "keyword_only"], ["kw", "var_keyword"]])
check("facts: defaults' kinds, a generator, decorators", [[p["default_kind"] for p in D["functions"][0]["params"]], D["functions"][0]["is_generator"], D["functions"][1]["decorators"], D["functions"][1]["first"]],
      [[none, none, none, "list", "literal", none], true, ["staticmethod"], 4])
check("facts: a syntax error is reported", ny_facts("def f(:\n")["error"] != none, true)
check("facts and text_defuse: an aliased from-import binds its alias",
      [ny_facts("from m import a as b\n")["imports"][0]["names"], ny_facts("from m import a as b\n")["module"]["writes"], text_defuse("from m import a as b\nprint(b)\n")[0]["writes"]],
      [["a as b"], ["b"], ["b"]])

# ── the program model: call graph, import graph ──────────────────────────────
agent = NyxAgent(ROOT, os.path.join(ROOT, ".state"))
nfiles = agent.index_workspace()
pm = agent.model
check("index: the files", [nfiles, sorted(agent.index.files.keys())], [5, ["README.md", "app.ny", "config.ny", "lint/bad.ny", "mathx.ny"]])
cg = pm.call_graph()
check("call graph: main", cg["app.ny::main"], ["config.ny::load_config", "mathx.ny::scale"])
check("call graph: through a module attribute and a class", [cg["config.ny::setting_ratio"], cg["config.ny::load_config"], cg["mathx.ny::scale"]],
      [["mathx.ny::ratio"], ["config.ny::parse_config"], ["mathx.ny::clamp"]])
check("call graph: recursion, module-level code", [cg["app.ny::fib"], cg["lint/bad.ny::<module>"]], [["app.ny::fib"], []])
check("callers", [f.qualname for f in pm.callers(pm.find_function("clamp"))], ["scale"])
check("import graph", pm.import_graph(), {"app.ny": ["config.ny", "mathx.ny"], "config.ny": ["mathx.ny"], "lint/bad.ny": [], "mathx.ny": []})
check("external imports", pm.external_imports()["lint/bad.ny"], ["os", "json"])
check("globals read and written", [pm.find_function("scale").globals_read, pm.find_function("bump").globals_written], [["LIMIT", "clamp"], ["counter"]])
check("find: by qualname and file", [repr(x) for x in pm.find("Box.size")] + [repr(x) for x in pm.find("config.ny:parse_config")],
      ["<FunctionInfo lint/bad.ny::Box.size>", "<FunctionInfo config.ny::parse_config>"])
check("reaches", [f.qualname for f in pm.reaches(pm.find_function("main"))], ["load_config", "parse_config", "clamp", "scale"])
check("stats", pm.stats(), {"modules": 4, "functions": 17, "classes": 1, "call_edges": 6})

# ── retrieval ────────────────────────────────────────────────────────────────
def top(q, k=3):
    return [h.qualname + "@" + h.cite() for h in agent.index.search(q, k)]

check("stemming and splitting", [stem("parsing"), stem("parses"), stem("parsed"), stem("parser"), terms_of("parseHTTPResponse total_price")],
      ["pars", "pars", "pars", "pars", ["pars", "http", "respons", "parsehttpresponse", "total", "pric", "total_price"]])
check("ask: where is the config parsed", top("where is the config parsed"), ["parse_config@config.ny:5", "load_config@config.ny:22", "Configuration@README.md:4"])
check("ask: rare words outrank a name", top("clamp a number within bounds", 2), ["Numbers@README.md:7", "clamp@mathx.ny:5"])
check("ask: a definition over its uses", top("clamp", 3), ["clamp@mathx.ny:5", "scale@mathx.ny:29", "Numbers@README.md:7"])
check("ask: ratio - the definition, then its caller", top("ratio", 2), ["ratio@mathx.ny:22", "setting_ratio@config.ny:25"])
hs = agent.index.search("read the settings file from disk", 5)
check("ask: comments count", [hs[0].qualname, hs[0].snippet, hs[0].cite()], ["load_config", "# read the settings file from disk", "config.ny:20"])
check("ask: a call-graph neighbour rises", [[h.qualname, h.boosts] for h in hs if h.qualname in ["parse_config", "main"]],
      [["parse_config", ["call-graph neighbour of load_config"]]])
check("ask: the boost is explained", agent.index.search("clamp", 1)[0].boosts, ["defines clamp", "call-graph neighbour of scale"])
r = agent.ask("where is the config parsed")
check("@ask: cited, linked answer", [r.ok, r.items[0].text, os.path.basename(r.items[0].path), r.items[0].line],
      [true, "1. config.ny:5  function parse_config", "config.ny", 5])
r2 = agent.ask("what does parse_config raise")
check("@ask: what the rules know", [it.text for it in r2.items if "may raise" in it.text or "called by" in it.text],
      ["parse_config may raise ValueError", "parse_config is called by load_config (config.ny:19)"])
check("ask: nothing matches", agent.ask("xylophone quaternion").ok, false)
# incremental update: a new function, then a removed file
write("mathx.ny", MATHX + '''

def lerp(a, b, t):
    """Linear interpolation between a and b."""
    return a + (b - a) * t
''')
agent.file_changed(os.path.join(ROOT, "mathx.ny"))
check("incremental: a changed file is re-indexed", top("linear interpolation", 1), ["lerp@mathx.ny:42"])
os.remove(os.path.join(ROOT, "README.md"))
check("incremental: refresh drops a removed file", [agent.index.refresh(), top("Configuration settings file", 2)],
      [[0, 0, 1], ["load_config@config.ny:20", "parse_config@config.ny:6"]])
# persistence
saved = agent.save()
idx2 = WorkspaceIndex.load(saved)
def answers(ix, q):
    return [[h.qualname, h.cite(), round(h.score, 6)] for h in ix.search(q, 4)]
check("persistence: the same answers after a round trip", [len(idx2.files), idx2.stats() == agent.index.stats(),
      answers(idx2, "where is the config parsed") == answers(agent.index, "where is the config parsed"),
      answers(idx2, "clamp") == answers(agent.index, "clamp")], [4, true, true, true])
write("app.ny", APP + "\n\ndef shutdown():\n    \"\"\"Stop the application cleanly.\"\"\"\n    return 0\n")
check("persistence: refresh re-indexes what changed on disk", [idx2.refresh(), [h.qualname for h in idx2.search("application cleanly", 1)]],
      [[1, 0, 0], ["shutdown"]])
check("sync: the agent picks up the change on disk", [agent.sync(), [h.qualname for h in agent.index.search("application cleanly", 1)], agent.sync()],
      [[1, 0, 0], ["shutdown"], [0, 0, 0]])
agent2 = NyxAgent(ROOT, os.path.join(ROOT, ".state"))
agent2.index_workspace()
check("persistence: an agent loads the saved index", [agent2.indexed, len(agent2.index.files), [h.qualname for h in agent2.index.search("application cleanly", 1)]],
      [true, 4, ["shutdown"]])

# ── the rule engine ──────────────────────────────────────────────────────────
eng = RuleEngine()
eng.fact("calls", "a", "b")
eng.fact("calls", "b", "c")
eng.fact("calls", "c", "a")
eng.fact("calls", "d", "a")
eng.rule("r1", [("calls", "?x", "?y")], [("reaches", "?x", "?y")])
eng.rule("r2", [("reaches", "?x", "?y"), ("calls", "?y", "?z")], [("reaches", "?x", "?z")])
eng.rule("loop", [("reaches", "?x", "?x")], [("cyclic", "?x")])
eng.rule("leaf", [("node", "?x"), ("not", "calls", "?x", "?_")], [("leaf", "?x")])
eng.fact("node", "e")
eng.fact("node", "a")
n = eng.run()
check("rules: transitive closure", sorted(eng.values(("reaches", "d", "?y"), "?y")), ["a", "b", "c"])
check("rules: recursion found", sorted(eng.values(("cyclic", "?x"), "?x")), ["a", "b", "c"])
check("rules: negation", eng.values(("leaf", "?x"), "?x"), ["e"])
check("rules: how many derived", [n, eng.stats()["facts"]], [16, 22])
check("rules: why", eng.why(("reaches", "d", "b")),
      ["reaches(d, b)  by rule 'r2', because", "  reaches(d, a)  by rule 'r1', because", "    calls(d, a)  (given)", "  calls(a, b)  (given)"])
bad = RuleEngine()
bad.rule("p", [("x", "?a"), ("not", "q", "?a")], [("p", "?a")])
bad.rule("q", [("x", "?a"), ("not", "p", "?a")], [("q", "?a")])
bad.fact("x", 1)
try:
    bad.run()
    check("rules: unstratified negation is refused", "ran", "ValueError")
except ValueError:
    check("rules: unstratified negation is refused", "ValueError", "ValueError")
e2 = agent.rules()
check("inferred: recursive", e2.values(("recursive", "?f"), "?f"), ["fib"])
check("inferred: may raise through calls", sorted([b["?f"] for b in e2.query(("may_raise", "?f", "ValueError"))]),
      ["clamp", "load_config", "main", "month_name", "parse_config", "scale"])
check("inferred: raises_via", sorted([[b["?f"], b["?g"]] for b in e2.query(("raises_via", "?f", "ValueError", "?g"))]),
      [["load_config", "parse_config"], ["main", "load_config"], ["main", "scale"], ["scale", "clamp"]])
check("inferred: handled exceptions do not propagate", e2.has("may_raise", "risky", "ValueError"), false)
check("inferred: pure and impure", [e2.has("pure", "clamp"), e2.has("pure", "bump"), e2.has("pure", "main"), e2.has("impure", "load_config")],
      [true, false, false, true])
check("inferred: unused", sorted(e2.values(("unused", "?f"), "?f")), ["bump", "check", "collect", "grade", "lerp", "list", "main", "month_name", "risky", "setting_ratio", "shutdown", "stop"])
# the round-72 interface, now facts and rules
kb = CodeKnowledgeBase(os.path.join(ROOT, ".state", "kb.json"))
re1 = ReasoningEngine(kb)
re1.add_rule("error", "check the error message")
re1.add_rule("slow loop", "profile the loop")
check("ReasoningEngine: words, stemmed", re1.infer("I get errors"), ["check the error message"])
check("ReasoningEngine: no substring matching any more", re1.infer("a terror story"), [])
check("ReasoningEngine: every word of a condition", [re1.infer("this loop is slow"), re1.infer("the loop")], [["profile the loop"], []])

# ── explain ──────────────────────────────────────────────────────────────────
ex = agent.explain("clamp")
check("@explain: from the facts", [it.text for it in ex.items[0:5]],
      ["clamp(x: int, lo: int = 0, hi: int = 10) -> int    [function, mathx.ny:5-19]", "\"Clamp x into the range [lo, hi].\"",
       "Parameters: x: int; lo: int (default 0); hi: int (default 10)",
       "Returns: `lo` (line 16), `hi` (line 18), `x` (line 19)", "Raises ValueError on line 14: raise ValueError('lo > hi')"])
check("@explain: callers, complexity, inferences", [it.text for it in ex.items[5:]],
      ["Called by scale (mathx.ny:26)", "Cyclomatic complexity 4 (simple)",
       "Inferred: pure (no I/O, no module writes, directly or through its calls)"])
ex2 = agent.explain("main")
check("@explain: raised through calls, calls out", [it.text for it in ex2.items if it.text.startswith("May raise") or it.text.startswith("Calls")],
      ["May raise ValueError through load_config (rule raise-through)", "May raise ValueError through scale (rule raise-through)",
       "Calls load_config (config.ny:19)", "Calls scale (mathx.ny:26)", "Calls outside the workspace: print"])
check("@explain: links to file:line", [[os.path.basename(l[0]), l[1]] for l in ex2.links()][0:4], [["app.ny", 5], ["app.ny", 8], ["config.ny", 19], ["mathx.ny", 26]])
check("@explain: a class", [it.text for it in agent.explain("Box").items], ["class Box    [lint/bad.ny:29-31]", "method size()"])
check("@explain: unknown", [agent.explain("nosuchthing").ok], [false])

# ── docstrings ───────────────────────────────────────────────────────────────
check("summaries from names", [summary_from_name("get_total"), summary_from_name("is_valid"), summary_from_name("parse_config"), summary_from_name("__init__", "Box"), summary_from_name("scale")],
      ["Return the total.", "Return whether valid.", "Parse the config.", "Initialize the Box.", "Scale."])
d1 = agent.doc("ratio")
check("@doc: drafted from the facts", d1.data, "Ratio.\n\nArgs:\n    a: The a.\n    b: The b.\n\nReturns:\n    `a / b`.")
d2 = agent.doc("month_name")
check("@doc: raises with its condition", d2.data,
      "The month's short name; months count from 1.\n\nArgs:\n    m (int): The m.\n\nReturns:\n    str: `names[m - 1]`.\n\nRaises:\n    ValueError: If m < 1.")
d3 = agent.doc("parse_config")
check("@doc: uses of a parameter", string_split(d3.data, "\n")[3], "    text: Its split() is called.")
d4 = agent.doc("scale")
check("@doc: iterated over, defaults, propagated raises", string_split(d4.data, "\n"),
      ["Scale.", "", "Args:", "    values: Iterated over.", "    factor (int): Passed to clamp(). Defaults to 2.", "", "Returns:", "    `out`.", "", "Raises:", "    ValueError: Propagated from clamp()."])
check("@doc: the edit puts it under the def", [d1.edits[0]["line"], d1.edits[0]["end"], d1.edits[0]["new"][0]], [23, 22, "    \"\"\"Ratio."])
check("@doc: the new text parses, with the docstring", ny_facts(d1.new_text)["functions"][1]["doc"] != none, true)

# ── review ───────────────────────────────────────────────────────────────────
rv = agent.review("lint/bad.ny")
got = [[f.line, f.rule] for f in rv.findings]
check("@review: findings at exact lines", got,
      [[1, "unused-import"], [5, "mutable-default"], [10, "inconsistent-return"], [11, "unused-variable"], [12, "none-comparison"],
       [19, "unreachable-code"], [25, "bare-except"], [30, "missing-self"], [34, "shadowed-builtin"], [38, "too-complex"]])
check("@review: messages and suggestions", [rv.findings[0].message, rv.findings[1].suggestion, rv.findings[9].message],
      ["unused import 'os'", "use None as the default and create the value in the body", "grade is too complex (cyclomatic complexity 12 > 10)"])
check("@review: fixable ones", [f.rule for f in rv.findings if f.fixable()],
      ["unused-import", "mutable-default", "inconsistent-return", "unused-variable", "none-comparison", "unreachable-code", "bare-except", "missing-self"])
fx = agent.fix("lint/bad.ny")
nl = string_split(fx.new_text, "\n")
check("@fix: the diff is shown before anything is written", [read_file(os.path.join(ROOT, "lint/bad.ny")) == BAD, string_startswith(fx.diff, "--- a/lint/bad.ny\n+++ b/lint/bad.ny\n")], [true, true])
check("@fix: the fixed lines", nl[0:16],
      ["import json", "", "", "def collect(item, bucket=None):", "    if bucket is None:", "        bucket = []", "    bucket.append(item)",
       "    return bucket", "", "", "def check(x):", "    if x is None:", "        return None", "    return x * 2", "", ""])
check("@fix: more fixed lines", [nl[16:19], nl[22:26], nl[27:30]],
      [["def stop(a):", "    return a", ""], ["        return int(\"x\")", "    except Exception:", "        return 0", ""], ["class Box:", "    def size(self):", "        return 3"]])
check("@fix: the result parses and only the rest remains", [ny_facts(fx.new_text)["error"], [f.rule for f in Reviewer().review_text(fx.new_text, "bad.ny")]],
      [none, ["shadowed-builtin", "too-complex"]])
agent.apply(fx)
check("@fix: applied", read_file(os.path.join(ROOT, "lint/bad.ny")) == fx.new_text, true)
# CodeAnalyzer keeps the shape the IDE reads
iss = CodeAnalyzer().analyze(BAD)
check("CodeAnalyzer.analyze", [len(iss), iss[0]["line"], iss[0]["pattern"], iss[0]["code"], sorted(iss[0].keys())],
      [10, 1, "unused-import", "import os", ["code", "fixable", "line", "message", "pattern", "severity", "suggestion"]])
check("CodeAnalyzer counts from the parser", [CodeAnalyzer().count_functions(BAD), CodeAnalyzer().count_classes(BAD), CodeAnalyzer().extract_class_names(BAD)], [7, 1, ["Box"]])

# ── generated tests ──────────────────────────────────────────────────────────
check("domains from annotations", [domain_of("int"), domain_of("list[str]"), domain_of("Optional[float]"), domain_of("str | None"), domain_of("Foo")],
      [["int", none, false], ["list", "str", false], ["float", none, true], ["str", none, true], none])
check("doctest examples", doctest_examples(">>> f(1)\n2\n>>> g()\nTraceback (most recent call last):\nValueError: x\n"),
      [["f(1)", ["2"]], ["g()", ["Traceback (most recent call last):", "ValueError: x"]]])
check("shrink candidates", [shrink_candidates("100"), shrink_candidates("-9"), shrink_candidates("'abcd'"), shrink_candidates("[3, 1]")],
      [["0", "50", "75", "88", "94", "97", "99"], ["0", "-5", "-7", "-8"], ["''", "'ab'", "'bcd'", "'abc'"], ["[]", "[3]", "[1]"]])
t1 = agent.test("clamp")
res = t1.data
check("@test: clamp's module written", [t1.ok, os.path.basename(res.path), res.domains, res.findings], [true, "test_mathx_clamp.ny", {"x": "int", "lo": "int", "hi": "int"}, []])
src = res.source
check("@test: from the docstring's examples", ["self.assertEqual(repr(clamp(15)), '10')" in src, "self.assertEqual(repr(clamp(-3)), '0')" in src], [true, true])
check("@test: boundary values observed", ["self.assertEqual(clamp(-1, 0, 10), 0)" in src, "self.assertEqual(clamp(3, 0, -1), 0)" in src or "with self.assertRaises(ValueError):\n            clamp(3, 0, -1)" in src],
      [true, true])
check("@test: a property over random inputs", "def test_property_deterministic(self):" in src, true)
check("@test: it ran and passed", [t1.items[-1].text if len(t1.items) > 0 else "", t1.ok], ["OK", true])
ok_m = agent.testgen.run(res, true)
check("@test: runnable with -m unittest", [ok_m[0], ok_m[1].strip().split("\n")[-1]], [true, "OK"])
t2 = agent.test("month_name")
check("@test: a counterexample, shrunk", [t2.ok, t2.data.findings], [true, ["month_name(13) raises IndexError: list index out of range  (shrunk from month_name(17))"]])
check("@test: the counterexample is pinned down", "def test_counterexample_1(self):\n        # shrunk counterexample: is raising IndexError here intended?\n        with self.assertRaises(IndexError):\n            month_name(13)" in t2.data.source, true)
t3 = agent.test("ratio")
check("@test: untyped parameters probed", [t3.ok, t3.data.domains, "with self.assertRaises(ZeroDivisionError):\n            ratio(3, 0)" in t3.data.source], [true, {"a": "int", "b": "int"}, true])
# a function that never returns for one input: that case is lost, the rest run
write("slow.ny", 'def settle(n: int) -> int:\n    """Returns n - but never returns for -1."""\n    while n == -1:\n        pass\n    return n\n\n\ndef numbers(n):\n    yield n\n')
agent.file_changed(os.path.join(ROOT, "slow.ny"))
agent.testgen.timeout = 4.0
t4 = agent.test("settle")
agent.testgen.timeout = 10.0
check("@test: a hang is a finding, the other cases still run", [t4.ok, t4.data.findings, t4.data.tests > 5],
      [true, ["settle(-1) did not return within 4.0s"], true])
check("@test: nothing to test", [agent.test("nope").ok, agent.test("numbers").ok, agent.test("numbers").items[0].text],
      [false, false, "no tests for numbers: generators and async functions are not supported"])

# a Python module: the generated test loads it by path, so it runs under
# nython and under python3 alike
write("geom.py", 'def area(w: float, h: float = 1.0) -> float:\n    """Area of a w by h rectangle.\n\n    >>> area(2.0, 3.0)\n    6.0\n    """\n    if w < 0 or h < 0:\n        raise ValueError("negative side")\n    return w * h\n')
agent.file_changed(os.path.join(ROOT, "geom.py"))
t5 = agent.test("area")
check("@test: a .py module", [t5.ok, os.path.basename(t5.data.path), t5.data.domains], [true, "test_geom_area.py", {"w": "float", "h": "float"}])
check("@test: it runs with nython -m unittest", agent.testgen.run(t5.data, true)[0], true)
py3 = shutil.which("python3")
if py3 is not none:
    import subprocess
    pr = subprocess.run([py3, "-m", "unittest", "test_geom_area"], cwd=ROOT, capture_output=True, text=True, timeout=60)
    check("@test: and with python3 -m unittest", [pr.returncode, pr.stderr.strip().split("\n")[-1]], [0, "OK"])
else:
    check("@test: and with python3 -m unittest", [0, "OK"], [0, "OK"])

# ── the completion model ─────────────────────────────────────────────────────
SHOP1 = '''class Cart:
    def __init__(self):
        self.items = []
        self.total_price = 0

    def add_item(self, item):
        self.items.append(item)
        self.total_price = self.total_price + item.price

    def remove_item(self, item):
        self.items.remove(item)
        self.total_price = self.total_price - item.price
'''
SHOP2 = '''class Order:
    def __init__(self, cart):
        self.items = list(cart.items)
        self.total_price = cart.total_price

    def add_item(self, item):
        self.items.append(item)
        self.total_price = self.total_price + item.price

    def item_count(self):
        return len(self.items)
'''
HELD = '''class Wishlist:
    def __init__(self, owner):
        self.owner = owner
        self.items = []
        self.total_price = 0

    def add_item(self, item):
        self.items.append(item)
        self.total_price = self.total_price + item.price

    def is_empty(self):
        return len(self.items) == 0
'''
base_n = ["def", "class", "return", "self", "import", "if", "else", "for", "while", "in", "and", "or", "not", "none", "print", "len", "list", "range", "isinstance", "true", "false", "total", "type", "tuple", "try", "item", "items", "iter", "int", "input", "append", "abs", "all", "any"]
base_k = ["keyword" for _ in base_n]
rk = CompletionRanker()
before = completion_mrr(rk, HELD, base_n, base_k, 1, 3, false)
untrained = completion_mrr(rk, HELD, base_n, base_k, 1, 3, true)
rk.observe_source(SHOP1)
rk.observe_source(SHOP2)
after = completion_mrr(rk, HELD, base_n, base_k, 1, 3, true)
check("completion: an untrained model keeps the IDE's order", untrained, before)
check("completion: MRR improves after training", [after[0] > before[0] + 0.1, after[1], round(before[0], 3), round(after[0], 3)], [true, 34, 0.639, 0.975])
check("completion: trained on the workspace", [rk.files, rk.tokens, rk.cat_steps > 0], [2, 142, true])
ctx = rk.context("        self.")
check("completion: the context", ctx, ["self", ".", "punct"])
check("completion: after self., the fields first", rk.rerank(["item", "items", "item_count"], ["word", "word", "word"], ctx, "i")[0], ["items", "item", "item_count"])
check("completion: the agent re-ranks too", agent.rerank(["fib", "factor", "f"], ["word", "word", "word"], "    return ", "f")[0][0], "fib")

# ── GitHubLearner over a local http.server ───────────────────────────────────
import http.server
SITE = os.path.join(ROOT, "site")
os.makedirs(os.path.join(SITE, "octo", "demo", "main"))
with open(os.path.join(SITE, "octo", "demo", "main", "README.md"), "w") as fh:
    fh.write("# Demo\nThe demo repository explains widget calibration in detail.\n")
with open(os.path.join(SITE, "guide.html"), "w") as fh:
    fh.write("<html><body><h1>Guide</h1><p>Sprocket alignment steps.</p></body></html>")

class _H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, request, client_address, server):
        http.server.SimpleHTTPRequestHandler.__init__(self, request, client_address, server, directory=SITE)
    def log_message(self, format, *args):
        pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _H)
port = srv.server_address[1]
th = threading.Thread(target=srv.serve_forever, daemon=true)
th.start()
nyx = NyxAI("Nyx", os.path.join(ROOT, "nyxws"))
nyx.github.raw_base = "http://127.0.0.1:" + str(port)
check("GitHubLearner: a README through urllib", [nyx.github.learn_from_repo("octo", "demo"), nyx.github.learned_repos], [true, ["octo/demo"]])
check("GitHubLearner: a missing repository", nyx.github.learn_from_repo("octo", "missing"), false)
q = nyx.kb.query("widget calibration")
check("the learned README answers questions", [q[0].key, q[0].source], ["doc:octo/demo", "github:octo/demo"])
check("DocumentLearner: a page", [nyx.docs.learn_url("http://127.0.0.1:" + str(port) + "/guide.html", "guide"), nyx.kb.query("sprocket alignment")[0].key], [true, "doc:guide"])
srv.shutdown()
srv.server_close()

# ── NyxAI and the IDE protocol on the agent ──────────────────────────────────
nyx2 = NyxAI("Nyx2", ROOT)
nyx2.agent.index_workspace()
a1 = nyx2.ask("where is the config parsed")
check("NyxAI.ask cites the workspace", string_split(a1, "\n")[0], "1. config.ny:5  function parse_config")
reply = json.loads(nyx2.handle_ide(json.dumps({"command": "explain", "arg": "fib"})))
check("IDE protocol: explain", [reply["ok"], reply["lines"][0], reply["links"][0][1]], [true, "fib(n)    [function, app.ny:11-14]", 11])
check("IDE protocol: hover", string_split(nyx2.ide.hover_info("bump"), "\n")[0], "bump()    [function, app.ny:20-23]")
check("memory: store, recall, search, persist", [nyx2.remember("lang", "Nython"), nyx2.recall("lang"), nyx2.kb.memory.search("lang")[0].value, nyx2.save()],
      ["Nyx2: Remembered 'lang'", "Nython", "Nython", "Nyx2: Memory saved to disk"])
check("memory: loaded back", MemoryStore(os.path.join(ROOT, "nyx_memory.json")).recall("lang").value, "Nython")
check("NyxAI: generate", [string_startswith(nyx2.generate("a class Point"), "class Point:"), "def read_all(self)" in nyx2.generate("crud for Item")], [true, true])

shutil.rmtree(ROOT)

pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
        print("FAIL " + r[0] + ": got " + repr(r[2]) + " want " + repr(r[3]))
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT105 PASSED ===")
