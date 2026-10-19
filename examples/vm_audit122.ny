# vm_audit122.ny - lib/nylsp, the Language Server (round 86; Nython only:
# python3 cannot run the server - it is Nython code over Nython's own
# parser - so this test drives `nython -m nylsp` and checks what it says).
#
# A client written here does what an editor does: it starts
# `sys.executable [--vm] -m nylsp` as a child with pipes (the engine this
# test runs on), speaks JSON-RPC with LSP's Content-Length framing, writes a
# fixture workspace under a per-pid temporary directory, opens documents,
# edits them incrementally, and checks the exact answers to: initialize's
# capabilities and position encoding, work done progress while the
# workspace is indexed, publishDiagnostics (syntax errors - several, by the
# error recovery -, NyScope's const and binding-rule notes, an
# UnboundLocalError read, undefined names, unknown modules and names, NyxAI's
# review rules; appearing and clearing again, also when another module's
# exports change), completion (names in scope, members of a class, an
# instance, a module, a builtin type, keywords, module names; nothing in
# strings or comments; inside code that does not parse) and its resolve,
# hover, signatureHelp, definition / declaration / typeDefinition across
# files, references, documentHighlight, prepareRename and rename (a
# WorkspaceEdit across two modules that respects scopes - Nython's rule in a
# .ny file, Python's in a .py file), documentSymbol, workspace/symbol,
# foldingRange, formatting / rangeFormatting, semanticTokens (full and
# delta), codeAction (NyxAI's fixes), inlayHint, $/cancelRequest, the error
# codes (before initialize, unknown method, after shutdown), the exit
# status, the utf-32 encoding, `--tcp`. Positions are UTF-16 code units,
# with a non-BMP character (U+1F600, two units) before names on a line.
# The latency of completion and hover on nython_ide.ny's chain is measured.
#
#     ./build/nython-cli examples/vm_audit122.ny
#     ./build/nython-cli --vm examples/vm_audit122.ny

import os
import sys
import time
import socket
import subprocess
import tempfile

results = []

# compared as JSON (json_encode orders an object's keys)
def check(name, got, want):
    ok = json_encode(got) == json_encode(want)
    results.append([name, ok, repr(got), repr(want)])
    if not ok:
        print("FAIL:", name)
        print("   got: ", repr(got))
        print("   want:", repr(want))

def check_true(name, cond, info=None):
    check(name if info is None else name + " (" + str(info) + ")", bool(cond), True)

exe = sys.executable
engine = ["--vm"] if "--vm" in sys.orig_argv else []
pid = os.getpid()
root = os.path.realpath(os.path.join(tempfile.gettempdir(), "ny_audit122_" + str(pid)))


# ── the fixture workspace ─────────────────────────────────────────────────────
def write(rel, text):
    p = os.path.join(root, rel)
    d = os.path.dirname(p)
    if not os.path.isdir(d):
        os.makedirs(d)
    f = open(p, "w")
    f.write(text)
    f.close()
    return p

GEOMETRY = """# geometry - shapes for the nylsp test
\"\"\"Shapes and helpers.\"\"\"

const PI = 3.14159

class Shape:
    \"\"\"A shape with a name.\"\"\"
    def __init__(self, name):
        self.name = name

    def describe(self):
        \"\"\"What the shape is.\"\"\"
        return self.name + ": " + str(self.area())

    def area(self):
        return 0

class Circle(Shape):
    \"\"\"A circle of radius r.\"\"\"
    def __init__(self, r):
        Shape.__init__(self, "circle")
        self.r = r

    def area(self):
        return PI * self.r * self.r

def scale(shape, factor=2):
    \"\"\"Scale a shape's radius by factor.\"\"\"
    shape.r = shape.r * factor
    return shape

counter = 0

def bump():
    counter = counter + 1
    return counter
"""

APP = """from geometry import Circle, scale
import geometry

def total(items):
    var x = 0
    for it in items:
        x = x + it.area()
    return x

def label(c):
    x = "\U0001F600 " + c.name
    return x

x = 10
c = Circle(2)
big = scale(c, factor=3)
print(total([c, big]), geometry.PI, label(c), c.area(), len("ab"))
"""

PYAPP = """x = 10

def label(c):
    x = "py " + c
    return x

def show():
    return x + 1
"""

BROKEN = """import os

const LIMIT = 3

def f(a):
    LIMIT = 4
    return a +

def g(b):
    return [b,, 2]
"""

PKG_INIT = """\"\"\"A package.\"\"\"
from .util import helper
"""

PKG_UTIL = """def helper(n):
    \"\"\"Help with n.\"\"\"
    return n * 2
"""

USES = """from geometry import missing_name
from pkg import helper

def work(data):
    result = []
    for item in data:
        result.
    count = len(result)
    return count

def other(values):
    total = helper(len(values), )
    return total
"""

FORMAT = """def f( a,b ):
  x=a+b
  return x
"""

p_geo = write("geometry.ny", GEOMETRY)
p_app = write("app.ny", APP)
p_py = write("pyapp.py", PYAPP)
p_broken = write("broken.ny", BROKEN)
write("pkg/__init__.ny", PKG_INIT)
p_util = write("pkg/util.ny", PKG_UTIL)
p_uses = write("uses.ny", USES)
p_fmt = write("fmt.ny", FORMAT)

def uri(p):
    return "file://" + p

# the UTF-16 column of the nth `needle` on line `line` of a text (and the
# line's index), so the positions below are not counted by hand
def col(text, line, needle, nth=1, plus=0):
    ln = text.split("\n")[line]
    i = -1
    for k in range(nth):
        i = ln.index(needle, i + 1)
    return len(ln[:i].encode("utf-16-le")) // 2 + plus

def line_of(text, needle, nth=1):
    lines = text.split("\n")
    k = 0
    for i in range(len(lines)):
        if needle in lines[i]:
            k += 1
            if k == nth:
                return i
    return -1

def LC(text, needle_line, needle, nth=1, line_nth=1):
    l = line_of(text, needle_line, line_nth)
    return [l, col(text, l, needle, nth)]


# ── a client ─────────────────────────────────────────────────────────────────
class Client:
    def __init__(self, args=None):
        self.p = subprocess.Popen([exe] + engine + ["-m", "nylsp"] + (args or []), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buf = b""
        self.err = ""
        self.id = 0
        self.notes = []
        self.server_requests = []
        self.code = None

    def frame(self, msg):
        body = json_encode(msg).encode("utf-8")
        return ("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body

    def write(self, data):
        self.p.stdin.write(data)
        self.p.stdin.flush()

    def send(self, msg):
        self.write(self.frame(msg))

    def _fill(self, timeout):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            r = os_proc_read(self.p.pid)
            got = False
            if len(r["stdout"]) > 0:
                self.buf = self.buf + r["stdout"].encode("utf-8")
                got = True
            if len(r["stderr"]) > 0:
                self.err = self.err + r["stderr"]
                got = True
            if got:
                return True
            if r["done"]:
                if self.code is None:
                    self.code = os_poll(self.p.pid)
                return False
            time.sleep(0.002)
        return False

    def read(self, timeout=30):
        t0 = time.monotonic()
        while True:
            end = self.buf.find(b"\r\n\r\n")
            if end >= 0:
                n = int(self.buf[:end].decode("ascii").split(":")[1].strip())
                if len(self.buf) >= end + 4 + n:
                    m = json_decode(self.buf[end + 4:end + 4 + n].decode("utf-8"))
                    self.buf = self.buf[end + 4 + n:]
                    return m
            left = timeout - (time.monotonic() - t0)
            if left <= 0 or not self._fill(left):
                return None

    def dispatch(self, m):
        if "method" in m and "id" in m:
            # a request from the server: answer it
            self.server_requests.append(m)
            self.send({"jsonrpc": "2.0", "id": m["id"], "result": None})
        elif "method" in m:
            self.notes.append(m)

    def request(self, method, params, timeout=30):
        self.id += 1
        rid = self.id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self.wait_response(rid, timeout)

    def wait_response(self, rid, timeout=30):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            m = self.read(timeout - (time.monotonic() - t0))
            if m is None:
                break
            if "method" not in m and m.get("id") == rid:
                return m
            self.dispatch(m)
        return {"timeout": method_of(rid)}

    def req(self, method, params, timeout=30):
        m = self.request(method, params, timeout)
        if "result" in m:
            return m["result"]
        return {"error": m.get("error"), "timeout": m.get("timeout")}

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def wait_note(self, method, pred=None, timeout=30):
        """The next notification `method` (matching pred), kept ones first."""
        for i in range(len(self.notes)):
            n = self.notes[i]
            if n["method"] == method and (pred is None or pred(n["params"])):
                self.notes.pop(i)
                return n["params"]
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            m = self.read(timeout - (time.monotonic() - t0))
            if m is None:
                break
            if m.get("method") == method and "id" not in m and (pred is None or pred(m["params"])):
                return m["params"]
            self.dispatch(m)
        return None

    def diagnostics(self, u, timeout=30):
        return self.wait_note("textDocument/publishDiagnostics", lambda p: p["uri"] == u, timeout)

    def wait_exit(self, timeout=20):
        t0 = time.monotonic()
        while self.code is None and time.monotonic() - t0 < timeout:
            self._fill(0.2)
            c = os_poll(self.p.pid)
            if c is not None and c >= -1 and c != -1:
                self.code = c
        return self.code

def method_of(rid):
    return "request " + str(rid)

def P(line, ch):
    return {"line": line, "character": ch}

def R(l0, c0, l1, c1):
    return {"start": P(l0, c0), "end": P(l1, c1)}

def doc_pos(u, line, ch):
    return {"textDocument": {"uri": u}, "position": P(line, ch)}

def labels(items):
    return sorted([it["label"] for it in items])


# ── initialize ───────────────────────────────────────────────────────────────
c = Client()
r = c.request("textDocument/hover", doc_pos(uri(p_app), 0, 0))
check("a request before initialize: ServerNotInitialized", r.get("error", {}).get("code"), -32002)

caps = {
    "general": {"positionEncodings": ["utf-16"]},
    "window": {"workDoneProgress": True},
    "textDocument": {"completion": {"completionItem": {"snippetSupport": False}},
                     "semanticTokens": {"requests": {"full": {"delta": True}}}},
    "workspace": {"workspaceEdit": {"documentChanges": False}},
}
init = c.req("initialize", {"processId": pid, "rootUri": uri(root), "capabilities": caps,
                            "initializationOptions": {"diagnosticDelay": 0}})
sc = init["capabilities"]
check("serverInfo", init["serverInfo"]["name"], "nylsp")
check("position encoding", sc["positionEncoding"], "utf-16")
check("incremental sync", sc["textDocumentSync"], {"change": 2, "openClose": True, "save": {"includeText": False}})
check("providers",
      [sc["hoverProvider"], sc["definitionProvider"], sc["declarationProvider"], sc["typeDefinitionProvider"],
       sc["referencesProvider"], sc["documentHighlightProvider"], sc["renameProvider"], sc["workspaceSymbolProvider"],
       sc["foldingRangeProvider"], sc["documentFormattingProvider"], sc["documentRangeFormattingProvider"],
       sc["inlayHintProvider"]],
      [True, True, True, True, True, True, {"prepareProvider": True}, True, True, True, True, {"resolveProvider": False}])
check("completion provider", sc["completionProvider"]["triggerCharacters"], ["."])
check("signature help triggers", sc["signatureHelpProvider"]["triggerCharacters"], ["(", ","])
check("semantic tokens legend",
      [sc["semanticTokensProvider"]["legend"]["tokenTypes"][:9], sc["semanticTokensProvider"]["full"]],
      [["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable"], {"delta": True}])
check("code action kinds", sc["codeActionProvider"]["codeActionKinds"], ["quickfix", "source.fixAll"])
r = c.request("initialize", {"processId": pid, "rootUri": uri(root), "capabilities": {}})
check("initialize twice: InvalidRequest", r.get("error", {}).get("code"), -32600)

# ── initialized: the workspace is indexed, with work done progress ───────────
c.notify("initialized", {})
begin = c.wait_note("$/progress", lambda p: p["value"]["kind"] == "begin")
end = c.wait_note("$/progress", lambda p: p["value"]["kind"] == "end", 60)
create = [m for m in c.server_requests if m["method"] == "window/workDoneProgress/create"]
check("window/workDoneProgress/create first", [len(create), create[0]["params"]["token"] if create else None], [1, "nylsp-index"])
check("progress begin", [begin["token"], begin["value"]["title"], begin["value"]["percentage"]], ["nylsp-index", "Indexing the workspace", 0])
check("progress end", end["value"], {"kind": "end", "message": "indexed 8 files"})

# ── didOpen and diagnostics ──────────────────────────────────────────────────
def open_doc(p, text, lang="nython"):
    c.notify("textDocument/didOpen", {"textDocument": {"uri": uri(p), "languageId": lang, "version": 1, "text": text}})

def brief(ds):
    return [[d["range"]["start"]["line"], d["range"]["start"]["character"], d["severity"], d["code"], d["source"]] for d in ds]

open_doc(p_app, APP)
open_doc(p_geo, GEOMETRY)
open_doc(p_py, PYAPP, "python")
open_doc(p_broken, BROKEN)
open_doc(p_uses, USES)
d_app = c.diagnostics(uri(p_app))
d_geo = c.diagnostics(uri(p_geo))
d_py = c.diagnostics(uri(p_py))
d_broken = c.diagnostics(uri(p_broken))
d_uses = c.diagnostics(uri(p_uses))
check("app.ny: label's plain `x = ...` rebinds the module's x by Nython's rule (an information note)",
      brief(d_app["diagnostics"]), [[10, 4, 3, "nython-scope", "nython"]])
check("diagnostics carry the document's version", d_app["version"], 1)
check("geometry.ny: bump rebinds the module's counter",
      brief(d_geo["diagnostics"]), [[34, 4, 3, "nython-scope", "nython"]])
check("... the note's message", d_geo["diagnostics"][0]["message"],
      "function 'bump' assigns 'counter', rebinding the module's 'counter' (line 32) without a declaration - "
      + "Python's rule makes it a local: declare 'global counter' to keep rebinding it, or 'var counter' for a local")
check("pyapp.py: Python's rule makes label's x a local (no note)", d_py["diagnostics"], [])
check("broken.ny: two syntax errors (the error recovery goes on after the first), NyScope's const check "
      + "on what parsed, the unused import (NyxAI)",
      brief(d_broken["diagnostics"]),
      [[6, 13, 1, "syntax-error", "nython"], [9, 14, 1, "syntax-error", "nython"], [5, 4, 1, "nython-const", "nython"],
       [0, 0, 2, "unused-import", "nyxai"]])
check("... their messages", [d["message"] for d in d_broken["diagnostics"]],
      ["Unexpected token: newline", "Unexpected token: ,", "cannot assign to constant 'LIMIT' (declared on line 3)",
       "unused import 'os' (remove the import of 'os')"])
check("uses.ny: the line being typed, a name geometry does not define (and does not use: NyxAI)",
      brief(d_uses["diagnostics"]), [[6, 14, 1, "syntax-error", "nython"], [0, 21, 2, "unresolved-import-name", "nython"],
                                     [0, 0, 2, "unused-import", "nyxai"]])
check("... the message", d_uses["diagnostics"][1]["message"], "cannot import name 'missing_name' from 'geometry'")

# ── fixing broken.ny incrementally: the diagnostics change and clear ────────
def change(p, version, edits):
    c.notify("textDocument/didChange", {"textDocument": {"uri": uri(p), "version": version},
                                        "contentChanges": [{"range": R(e[0], e[1], e[2], e[3]), "text": e[4]} for e in edits]})

change(p_broken, 2, [[6, 14, 6, 14, " 1"]])
d2 = c.diagnostics(uri(p_broken))
check("one syntax error left", brief(d2["diagnostics"]),
      [[9, 14, 1, "syntax-error", "nython"], [5, 4, 1, "nython-const", "nython"], [0, 0, 2, "unused-import", "nyxai"]])
change(p_broken, 3, [[9, 14, 9, 15, ""]])
d3 = c.diagnostics(uri(p_broken))
check("then only the constant's assignment and the import", brief(d3["diagnostics"]),
      [[5, 4, 1, "nython-const", "nython"], [0, 0, 2, "unused-import", "nyxai"]])
check("the version is the last change's", d3["version"], 3)
# two edits in one didChange, applied in order: rename the local, drop the import
change(p_broken, 4, [[5, 4, 5, 9, "local"], [6, 11, 6, 16, "a + local"], [0, 0, 1, 0, ""]])
d4 = c.diagnostics(uri(p_broken))
check("all fixed: the diagnostics clear", d4["diagnostics"], [])
t = c.req("nython/documentText", {"textDocument": {"uri": uri(p_broken)}})
check("the incremental edits gave the right text", t["text"],
      "\nconst LIMIT = 3\n\ndef f(a):\n    local = 4\n    return a + local\n\ndef g(b):\n    return [b, 2]\n")

# a module's exports change: its importers are checked again (the dependency graph)
change(p_geo, 2, [[36, 0, 36, 0, "\ndef missing_name():\n    return 1\n"]])
d_uses2 = c.diagnostics(uri(p_uses))
check("defining missing_name in geometry clears uses.ny's warning", brief(d_uses2["diagnostics"]),
      [[6, 14, 1, "syntax-error", "nython"], [0, 0, 2, "unused-import", "nyxai"]])
c.diagnostics(uri(p_geo))

# ── UTF-16 positions: a non-BMP character on a line ─────────────────────────
# line 10 of app.ny:  '    x = "😀 " + c.name' - the emoji is 2 UTF-16 units
ec = col(APP, 10, "c.name")
check("UTF-16 column of c after the emoji", ec, 16)
h = c.req("textDocument/hover", doc_pos(uri(p_app), 10, ec))
check("hover after a non-BMP character", [h["range"], h["contents"]["value"]],
      [R(10, 16, 10, 17), "```python\n(parameter) c\n```"])
h = c.req("textDocument/hover", doc_pos(uri(p_app), 10, ec + 2))
check("... and on its attribute", h["range"], R(10, 18, 10, 22))
# an incremental edit inside the line, after the emoji (UTF-16 columns)
change(p_app, 2, [[10, 11, 10, 11, "\U0001F600"]])
t = c.req("nython/documentText", {"textDocument": {"uri": uri(p_app)}})
check("an insertion at UTF-16 column 11 (after the emoji)", t["text"].split("\n")[10], "    x = \"\U0001F600\U0001F600 \" + c.name")
h = c.req("textDocument/hover", doc_pos(uri(p_app), 10, 18))
check("c moved two units", h["range"], R(10, 18, 10, 19))
change(p_app, 3, [[10, 9, 10, 11, ""]])
t = c.req("nython/documentText", {"textDocument": {"uri": uri(p_app)}})
check("deleting the surrogate pair (two units)", t["text"], APP)
check("the piece table has the edits' pieces", t["pieces"] > 1, True)

# ── hover ────────────────────────────────────────────────────────────────────
def hover(p, line, ch):
    r = c.req("textDocument/hover", doc_pos(uri(p), line, ch))
    return r["contents"]["value"] if r else r
check("hover: a class imported from another module (its docstring)", hover(p_app, 14, col(APP, 14, "Circle")),
      "```python\n(class) class Circle(Shape)\n```\n---\nA circle of radius r.")
check("hover: a function across modules", hover(p_app, 15, col(APP, 15, "scale")),
      "```python\n(function) def scale(shape, factor=2)\n```\n---\nScale a shape's radius by factor.")
check("hover: a variable's inferred type (an instance of the class)", hover(p_app, 14, 0),
      "```python\n(variable) c: Circle\n```")
check("hover: a module", hover(p_app, 1, 8), "```python\n(module) geometry\n```\n---\nShapes and helpers.")
check("hover: a constant through the module", hover(p_app, 16, col(APP, 16, "PI")),
      "```python\n(constant) PI: float = 3.14159\n```")
check("hover: a method through an instance", hover(p_app, 16, col(APP, 16, "area")),
      "```python\n(method) def Circle.area(self)\n```")
check("hover: a builtin", hover(p_app, 16, col(APP, 16, "len"))[:75],
      "```python\n(builtin function) len(obj, /)\n```\n---\nReturn the number of items")
check("hover: a field set through self", hover(p_geo, 21, col(GEOMETRY, 21, "r =")), "```python\n(field) Circle.r\n```")
check("hover: a local declared with var", hover(p_app, 4, 8), "```python\n(variable) x: int = 0\n```")
check("hover: a keyword has none", c.req("textDocument/hover", doc_pos(uri(p_app), 3, 1)), None)
check("hover: a generator", hover(p_geo, 26, 4), "```python\n(function) def scale(shape, factor=2)\n```\n---\nScale a shape's radius by factor.")

# ── completion ───────────────────────────────────────────────────────────────
def complete(p, line, ch):
    r = c.req("textDocument/completion", doc_pos(uri(p), line, ch))
    return r["items"]

# type a line at the end of app.ny, then complete in it
change(p_app, 4, [[17, 0, 17, 0, "c."]])
items = complete(p_app, 17, 2)
check("completion: an instance's members, its base class's too", labels(items),
      ["__init__", "area", "describe", "name", "r"])
area = [it for it in items if it["label"] == "area"][0]
check("... a method's kind and detail", [area["kind"], area["detail"]], [2, "def area(self)"])
desc = c.req("completionItem/resolve", [it for it in items if it["label"] == "describe"][0])
check("completionItem/resolve adds the docstring", desc["documentation"]["value"], "```python\ndef describe(self)\n```\nWhat the shape is.")
change(p_app, 5, [[17, 0, 17, 2, "geometry.s"]])
items = complete(p_app, 17, 10)
check("completion: a module's names, by the prefix (the exact case first)", [it["label"] for it in items], ["scale", "Shape"])
change(p_app, 6, [[17, 0, 17, 10, "to"]])
items = complete(p_app, 17, 2)
check("completion: names in scope by the prefix (the exact prefix first)", items[0]["label"], "total")
change(p_app, 7, [[17, 0, 17, 2, "whi"]])
items = complete(p_app, 17, 3)
check("completion: keywords", [items[0]["label"], items[0]["kind"]], ["while", 14])
change(p_app, 8, [[17, 0, 17, 3, "x = \"geom"]])
check("no completion inside a string", complete(p_app, 17, 9), [])
change(p_app, 9, [[17, 0, 17, 9, "# geom"]])
check("no completion inside a comment", complete(p_app, 17, 6), [])
change(p_app, 10, [[17, 0, 17, 6, "\"x\"."]])
items = complete(p_app, 17, 4)
check("completion: a builtin type's methods", [n in labels(items) for n in ["upper", "split", "join"]], [True, True, True])
change(p_app, 11, [[17, 0, 17, 4, ""]])
items = complete(p_app, 10, 4)
check("completion in a function sees its parameters and the module's names",
      [n in labels(items) for n in ["c", "x", "total", "label", "Circle", "scale", "geometry", "print", "len"]],
      [True, True, True, True, True, True, True, True, True])
check("... not another function's locals", "it" in labels(items), False)
# inside code that does not parse (uses.ny line 6 is '        result.')
items = complete(p_uses, 6, 15)
check("completion after a dot on a line that does not parse (a list's methods)",
      [n in labels(items) for n in ["append", "extend", "pop", "sort"]], [True, True, True, True])
change(p_uses, 2, [[11, 31, 11, 31, "va"]])
items = complete(p_uses, 11, 33)
check("... and names inside an unfinished call", [it["label"] for it in items][:1], ["values"])
change(p_uses, 3, [[11, 31, 11, 33, ""]])
# module names after import / from
change(p_app, 12, [[17, 0, 17, 0, "from geo"]])
items = complete(p_app, 17, 8)
check("completion: module names after from", items[0]["label"], "geometry")
change(p_app, 13, [[17, 0, 17, 8, "from pkg import h"]])
items = complete(p_app, 17, 17)
check("completion: a package's names after import", items[0]["label"], "helper")
change(p_app, 14, [[17, 0, 17, 17, "import py"]])
items = complete(p_app, 17, 9)
check("completion: a .py module of the workspace", items[0]["label"], "pyapp")
change(p_app, 15, [[17, 0, 17, 9, ""]])

# ── signature help ───────────────────────────────────────────────────────────
change(p_app, 16, [[17, 0, 17, 0, "scale(c, "]])
sh = c.req("textDocument/signatureHelp", doc_pos(uri(p_app), 17, 9))
check("signature help while the call is typed", [sh["signatures"][0]["label"], sh["activeParameter"],
                                                 sh["signatures"][0]["parameters"]],
      ["scale(shape, factor=2)", 1, [{"label": [6, 11]}, {"label": [13, 21]}]])
check("... with the docstring", sh["signatures"][0]["documentation"]["value"], "Scale a shape's radius by factor.")
change(p_app, 17, [[17, 0, 17, 9, "scale(factor="]])
sh = c.req("textDocument/signatureHelp", doc_pos(uri(p_app), 17, 13))
check("... a keyword argument picks its parameter", sh["activeParameter"], 1)
change(p_app, 18, [[17, 0, 17, 13, "Circle("]])
sh = c.req("textDocument/signatureHelp", doc_pos(uri(p_app), 17, 7))
check("... a class: its __init__ without self", [sh["signatures"][0]["label"], sh["activeParameter"]], ["Circle(r)", 0])
change(p_app, 19, [[17, 0, 17, 7, "c.describe("]])
sh = c.req("textDocument/signatureHelp", doc_pos(uri(p_app), 17, 11))
check("... a method through an instance (bound)", sh["signatures"][0]["label"], "describe()")
change(p_app, 20, [[17, 0, 17, 11, "print(len("]])
sh = c.req("textDocument/signatureHelp", doc_pos(uri(p_app), 17, 10))
check("... a builtin", sh["signatures"][0]["label"], "len(obj, /)")
change(p_app, 21, [[17, 0, 17, 10, ""]])
t = c.req("nython/documentText", {"textDocument": {"uri": uri(p_app)}})
check("app.ny is back as it was", t["text"], APP)

# ── definition, declaration, type definition ─────────────────────────────────
def loc(l):
    return [l["uri"][len(uri(root)) + 1:], l["range"]["start"]["line"], l["range"]["start"]["character"]]
def defn(method, p, line, ch):
    r = c.req(method, doc_pos(uri(p), line, ch))
    return [loc(l) for l in r] if isinstance(r, list) else r
check("definition across modules: a class", defn("textDocument/definition", p_app, 14, col(APP, 14, "Circle")),
      [["geometry.ny", 17, 6]])
check("... a function", defn("textDocument/definition", p_app, 15, col(APP, 15, "scale")), [["geometry.ny", 26, 4]])
check("... an attribute of an imported module", defn("textDocument/definition", p_app, 16, col(APP, 16, "PI")),
      [["geometry.ny", 3, 6]])
check("... a method through an instance", defn("textDocument/definition", p_app, 16, col(APP, 16, "area")),
      [["geometry.ny", 23, 8]])
check("... the module of an import", defn("textDocument/definition", p_app, 1, 9), [["geometry.ny", 0, 0]])
check("... through a package's re-export (pkg/__init__ imports it from .util)",
      defn("textDocument/definition", p_uses, 1, col(USES, 1, "helper")), [["pkg/util.ny", 0, 4]])
check("... a local", defn("textDocument/definition", p_app, 7, 11), [["app.ny", 4, 8]])
check("... an inherited member (self.area in Shape)", defn("textDocument/definition", p_geo, 12, col(GEOMETRY, 12, "area")),
      [["geometry.ny", 14, 8]])
check("... a base class's member (Shape.__init__ through the class)",
      defn("textDocument/definition", p_geo, 20, col(GEOMETRY, 20, "__init__")), [["geometry.ny", 7, 8]])
check("declaration: the import that binds it here",
      defn("textDocument/declaration", p_app, 14, col(APP, 14, "Circle")), [["app.ny", 0, 21]])
check("type definition: the class of an instance",
      defn("textDocument/typeDefinition", p_app, 15, col(APP, 15, "c,")), [["geometry.ny", 17, 6]])
check("a builtin has no definition", c.req("textDocument/definition", doc_pos(uri(p_app), 16, col(APP, 16, "len"))), None)

# ── references and highlights ────────────────────────────────────────────────
def refs(p, line, ch, decl=True):
    r = c.req("textDocument/references", {"textDocument": {"uri": uri(p)}, "position": P(line, ch),
                                         "context": {"includeDeclaration": decl}})
    return sorted([loc(l) for l in r]) if isinstance(r, list) else r
check("references of a function across modules", refs(p_app, 15, col(APP, 15, "scale")),
      [["app.ny", 0, 29], ["app.ny", 15, 6], ["geometry.ny", 26, 4]])
check("... without the declaration", refs(p_app, 15, col(APP, 15, "scale"), False), [["app.ny", 0, 29], ["app.ny", 15, 6]])
check("references of a module's constant (through `import geometry`)", refs(p_geo, 3, 6),
      [["app.ny", 16, col(APP, 16, "PI")], ["geometry.ny", 3, 6], ["geometry.ny", 24, 15]])
check("references of a method (through an instance in another module)", refs(p_geo, 23, 8),
      [["app.ny", 16, col(APP, 16, "area")], ["geometry.ny", 23, 8]])
hl = c.req("textDocument/documentHighlight", doc_pos(uri(p_app), 14, 0))
check("document highlight: the write and the reads",
      sorted([[x["range"]["start"]["line"], x["range"]["start"]["character"], x["kind"]] for x in hl]),
      [[14, 0, 3], [15, 12, 2], [16, 13, 2], [16, col(APP, 16, "c)"), 2], [16, col(APP, 16, "c.area"), 2]])

# ── rename ───────────────────────────────────────────────────────────────────
def edits_of(we):
    out = []
    for u in sorted(we["changes"]):
        for e in we["changes"][u]:
            out.append([u[len(uri(root)) + 1:], e["range"]["start"]["line"], e["range"]["start"]["character"],
                        e["range"]["end"]["character"], e["newText"]])
    return sorted(out)
def rename(p, line, ch, new):
    return c.req("textDocument/rename", {"textDocument": {"uri": uri(p)}, "position": P(line, ch), "newName": new})
pr = c.req("textDocument/prepareRename", doc_pos(uri(p_app), 14, 5))
check("prepareRename", pr, {"placeholder": "Circle", "range": R(14, 4, 14, 10)})
check("rename a class across two modules", edits_of(rename(p_app, 14, 5, "Disc")),
      [["app.ny", 0, 21, 27, "Disc"], ["app.ny", 14, 4, 10, "Disc"], ["geometry.ny", 17, 6, 12, "Disc"]])
# Nython's rule: label's plain `x = ...` rebinds the module's x; total's `var x` is its own
check("rename a module variable (.ny): the function that rebinds it follows; a var local does not",
      edits_of(rename(p_app, 13, 0, "y")), [["app.ny", 10, 4, 5, "y"], ["app.ny", 11, 11, 12, "y"], ["app.ny", 13, 0, 1, "y"]])
check("rename a var local: that function only", edits_of(rename(p_app, 6, 8, "acc")),
      [["app.ny", 4, 8, 9, "acc"], ["app.ny", 6, 8, 9, "acc"], ["app.ny", 6, 12, 13, "acc"], ["app.ny", 7, 11, 12, "acc"]])
# Python's rule (.py): label's x is its local
check("rename a module variable (.py): a function's assignment is its local", edits_of(rename(p_py, 0, 0, "y")),
      [["pyapp.py", 0, 0, 1, "y"], ["pyapp.py", 7, 11, 12, "y"]])
check("rename the .py function's local", edits_of(rename(p_py, 3, 4, "s")), [["pyapp.py", 3, 4, 5, "s"], ["pyapp.py", 4, 11, 12, "s"]])
check("rename a parameter", edits_of(rename(p_geo, 26, 10, "obj")),
      [["geometry.ny", 26, 10, 15, "obj"], ["geometry.ny", 28, 4, 9, "obj"], ["geometry.ny", 28, 14, 19, "obj"],
       ["geometry.ny", 29, 11, 16, "obj"]])
check("rename a parameter: keyword arguments naming it follow, in other modules too", edits_of(rename(p_geo, 26, 18, "by")),
      [["app.ny", 15, 15, 21, "by"], ["geometry.ny", 26, 17, 23, "by"], ["geometry.ny", 28, 24, 30, "by"]])
check("rename a method: through instances in another module", edits_of(rename(p_geo, 23, 8, "surface")),
      [["app.ny", 16, col(APP, 16, "area"), col(APP, 16, "area") + 4, "surface"], ["geometry.ny", 23, 8, 12, "surface"]])
check("rename a field: every self.r", edits_of(rename(p_geo, 21, 13, "radius")),
      [["geometry.ny", 21, 13, 14, "radius"], ["geometry.ny", 24, 25, 26, "radius"], ["geometry.ny", 24, 34, 35, "radius"]])
r = c.request("textDocument/rename", {"textDocument": {"uri": uri(p_app)}, "position": P(16, col(APP, 16, "len")), "newName": "size"})
check("a builtin cannot be renamed", [r["error"]["code"], r["error"]["message"]], [-32803, "'len' is a builtin and cannot be renamed"])
r = c.request("textDocument/rename", {"textDocument": {"uri": uri(p_app)}, "position": P(14, 5), "newName": "not valid"})
check("a new name must be an identifier", r["error"]["code"], -32602)
r = c.request("textDocument/prepareRename", doc_pos(uri(p_app), 1, 9))
check("a module cannot be renamed", r["error"]["message"], "renaming a module needs its file renamed")

# ── symbols ──────────────────────────────────────────────────────────────────
ds = c.req("textDocument/documentSymbol", {"textDocument": {"uri": uri(p_geo)}})
def tree(syms):
    return [[s["name"], s["kind"]] + ([tree(s["children"])] if s["children"] else []) for s in syms]
check("documentSymbol: hierarchical", tree(ds),
      [["PI", 14], ["Shape", 5, [["__init__", 9], ["name", 8], ["describe", 6], ["area", 6]]],
       ["Circle", 5, [["__init__", 9], ["r", 8], ["area", 6]]], ["scale", 12], ["counter", 13], ["bump", 12],
       ["missing_name", 12]])
check("... ranges: the statement and its name; the signature", [ds[1]["range"], ds[1]["selectionRange"], ds[3]["detail"]],
      [R(5, 0, 15, 16), R(5, 6, 5, 11), "(shape, factor=2)"])
ws = c.req("workspace/symbol", {"query": "circ"})
check("workspace/symbol: fuzzy", [[s["name"], s["kind"], loc(s["location"])] for s in ws][:1],
      [["Circle", 5, ["geometry.ny", 17, 6]]])
ws = c.req("workspace/symbol", {"query": "helper"})
check("... any module of the workspace", [[s["name"], loc(s["location"])] for s in ws][:1], [["helper", ["pkg/util.ny", 0, 4]]])
ws = c.req("workspace/symbol", {"query": "describe"})
check("... methods, with their class", [[s["name"], s["kind"], s.get("containerName")] for s in ws][:1], [["describe", 6, "Shape"]])

# ── folding, formatting ──────────────────────────────────────────────────────
fr = c.req("textDocument/foldingRange", {"textDocument": {"uri": uri(p_geo)}})
check("folding ranges", [[f["startLine"], f["endLine"]] + ([f["kind"]] if "kind" in f else []) for f in fr][:5],
      [[5, 15], [7, 8], [10, 12], [14, 15], [17, 24]])
open_doc(p_fmt, FORMAT)
c.diagnostics(uri(p_fmt))
fe = c.req("textDocument/formatting", {"textDocument": {"uri": uri(p_fmt)}, "options": {"tabSize": 4, "insertSpaces": True}})
check("formatting: the formatter's line edits", fe,
      [{"newText": "def f( a, b ):\n    x = a+b\n    return x\n", "range": R(0, 0, 3, 0)}])
fe = c.req("textDocument/rangeFormatting", {"textDocument": {"uri": uri(p_fmt)}, "range": R(1, 0, 1, 5),
                                            "options": {"tabSize": 4, "insertSpaces": True}})
check("range formatting: the hunks in the range", len(fe), 1)

# ── semantic tokens ──────────────────────────────────────────────────────────
types = sc["semanticTokensProvider"]["legend"]["tokenTypes"]
def decode(data):
    out = []
    l = 0
    ch = 0
    for i in range(0, len(data), 5):
        if data[i] != 0:
            l += data[i]
            ch = 0
        ch += data[i + 1]
        out.append([l, ch, data[i + 2], types[data[i + 3]], data[i + 4]])
    return out
st = c.req("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(p_py)}})
check("semantic tokens: names classified by their binding (bit 0 declaration, 1 definition)",
      decode(st["data"])[:9],
      [[0, 0, 1, "variable", 1], [0, 4, 2, "number", 0], [2, 0, 3, "keyword", 0], [2, 4, 5, "function", 3],
       [2, 10, 1, "parameter", 1], [3, 4, 1, "variable", 1], [3, 8, 5, "string", 0], [3, 16, 1, "parameter", 0],
       [4, 4, 6, "keyword", 0]])
TOK = "const K = 1\n# note\nprint(len(\"s\"), K)\n"
p_tok = write("tok.ny", TOK)
open_doc(p_tok, TOK)
c.diagnostics(uri(p_tok))
st2 = c.req("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(p_tok)}})
check("... readonly (const), comments, builtins (defaultLibrary)", decode(st2["data"]),
      [[0, 0, 5, "keyword", 0], [0, 6, 1, "variable", 5], [0, 10, 1, "number", 0], [1, 0, 6, "comment", 0],
       [2, 0, 5, "function", 512], [2, 6, 3, "function", 512], [2, 10, 3, "string", 0], [2, 16, 1, "variable", 4]])
change(p_tok, 2, [[1, 0, 1, 6, "x = 2"]])
dl = c.req("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": uri(p_tok)}, "previousResultId": st2["resultId"]})
check("semantic tokens delta: one edit", [len(dl["edits"]), dl["edits"][0]["start"], dl["edits"][0]["deleteCount"]], [1, 17, 2])
applied = st2["data"][:dl["edits"][0]["start"]] + dl["edits"][0]["data"] + st2["data"][dl["edits"][0]["start"] + dl["edits"][0]["deleteCount"]:]
st3 = c.req("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(p_tok)}})
check("... applied to the previous data it gives the new tokens", applied, st3["data"])
check("... the comment became a variable and a number", decode(st3["data"])[3:5], [[1, 0, 1, "variable", 1], [1, 4, 1, "number", 0]])
check("... a new result id", dl["resultId"] != st2["resultId"], True)
dl2 = c.req("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": uri(p_tok)}, "previousResultId": st3["resultId"]})
check("... nothing changed: no edits", dl2["edits"], [])
dl3 = c.req("textDocument/semanticTokens/full/delta", {"textDocument": {"uri": uri(p_tok)}, "previousResultId": "nope"})
check("... an unknown previous result: the full data", "data" in dl3, True)

# ── code actions ─────────────────────────────────────────────────────────────
FIX = "import os\nimport sys\n\ndef f(x):\n    if x == None:\n        return 1\n    print(sys.argv)\n"
p_fix = write("fix.ny", FIX)
open_doc(p_fix, FIX)
dfix = c.diagnostics(uri(p_fix))
check("NyxAI's findings as diagnostics with codes", sorted([[d["code"], d["range"]["start"]["line"], d["source"]] for d in dfix["diagnostics"]]),
      [["inconsistent-return", 3, "nyxai"], ["none-comparison", 4, "nyxai"], ["unused-import", 0, "nyxai"]])
def actions(p, rng, only):
    return c.req("textDocument/codeAction", {"textDocument": {"uri": uri(p)}, "range": rng,
                                              "context": {"diagnostics": [], "only": only}})
ca = actions(p_fix, R(0, 0, 0, 9), ["quickfix"])
check("a quick fix for the unused import", [[a["title"], a["kind"], a["edit"]["changes"][uri(p_fix)]] for a in ca],
      [["NyxAI: remove the import of 'os'", "quickfix", [{"newText": "", "range": R(0, 0, 1, 0)}]]])
ca = actions(p_fix, R(4, 0, 4, 0), ["quickfix"])
check("... for x == None", [a["edit"]["changes"][uri(p_fix)][0]["newText"] for a in ca], ["    if x is None:\n"])
ca = actions(p_fix, R(0, 0, 0, 0), ["source.fixAll"])
check("source.fixAll: every fix at once", [[a["title"], a["kind"], len(a["edit"]["changes"][uri(p_fix)])] for a in ca],
      [["NyxAI: fix all (3)", "source.fixAll.nyxai", 3]])
ca = actions(p_geo, R(34, 0, 34, 20), ["quickfix"])
check("the binding-rule note's fixes: global, or var", [[a["title"], a["edit"]["changes"][uri(p_geo)][0]["newText"]] for a in ca],
      [["Declare 'global counter' (keep rebinding the outer 'counter')", "    global counter\n"],
       ["Make 'counter' a local (var counter)", "var "]])

# ── inlay hints ──────────────────────────────────────────────────────────────
ih = c.req("textDocument/inlayHint", {"textDocument": {"uri": uri(p_app)}, "range": R(14, 0, 16, 0)})
check("inlay hints: parameter names at call sites (across modules)",
      [[x["position"]["line"], x["position"]["character"], x["label"], x["kind"]] for x in ih],
      [[14, 11, "r:", 2], [15, 12, "shape:", 2], [16, 12, "items:", 2]])
ih = c.req("textDocument/inlayHint", {"textDocument": {"uri": uri(p_geo)}, "range": R(0, 0, 40, 0)})
check("... a method called through its class (unbound: self is an argument; named as its parameter, no hint)",
      [[x["position"]["line"], x["label"]] for x in ih], [[20, "name:"]])

# ── $/cancelRequest, errors ──────────────────────────────────────────────────
c.id += 1
rid = c.id
c.write(c.frame({"jsonrpc": "2.0", "id": rid, "method": "workspace/symbol", "params": {"query": "a"}})
        + c.frame({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": rid}}))
m = c.wait_response(rid)
check("$/cancelRequest: RequestCancelled", m.get("error", {}).get("code"), -32800)
r = c.request("textDocument/notAThing", {})
check("an unknown method: MethodNotFound", r["error"]["code"], -32601)
r = c.request("textDocument/hover", doc_pos("file:///not/open.ny", 0, 0))
check("a document that is not open: InvalidParams", r["error"]["code"], -32602)
st = c.req("nython/stats", {})
check("nython/stats", [st["encoding"], st["pending"], st["requests"]["cancelled"] >= 1], ["utf-16", 0, True])

# ── latency on nython_ide.ny's chain ─────────────────────────────────────────
big_path = None
for cand in [os.path.join(os.getcwd(), "ide_tools.ny"), os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(sys.argv[0]))), "ide_tools.ny")]:
    if os.path.isfile(cand):
        big_path = os.path.realpath(cand)
        break
if big_path is not None:
    text = open(big_path).read()
    lines = text.split("\n")
    open_doc(big_path, text)
    t0 = time.monotonic()
    syms = c.req("textDocument/documentSymbol", {"textDocument": {"uri": uri(big_path)}})
    first = (time.monotonic() - t0) * 1000
    target = None
    for i in range(len(lines) // 2, len(lines)):
        if lines[i].startswith("        ") and "self." in lines[i]:
            target = i
            break
    col0 = lines[target].index("self.") + 5
    times = []
    hover_times = []
    for k in range(5):
        t0 = time.monotonic()
        it = c.req("textDocument/completion", doc_pos(uri(big_path), target, col0))
        times.append((time.monotonic() - t0) * 1000)
        t0 = time.monotonic()
        hv = c.req("textDocument/hover", doc_pos(uri(big_path), target, col0))
        hover_times.append((time.monotonic() - t0) * 1000)
    # typing in a line: an edit, then completion (the analysis is reused while a line is typed)
    typing = []
    def edit_and_complete(version, edit, line, ch):
        c.id += 1
        rid = c.id
        t0 = time.monotonic()
        c.write(c.frame({"jsonrpc": "2.0", "method": "textDocument/didChange", "params": {
                    "textDocument": {"uri": uri(big_path), "version": version},
                    "contentChanges": [{"range": R(edit[0], edit[1], edit[2], edit[3]), "text": edit[4]}]}})
                + c.frame({"jsonrpc": "2.0", "id": rid, "method": "textDocument/completion", "params": doc_pos(uri(big_path), line, ch)}))
        m = c.wait_response(rid)
        return [(time.monotonic() - t0) * 1000, m]
    for k in range(5):
        res = edit_and_complete(2 + 2 * k, [target, col0, target, col0, "x"], target, col0 + 1)
        typing.append(res[0])
        change(big_path, 3 + 2 * k, [[target, col0, target, col0 + 1, ""]])
    # an edit that adds a line: parsed again
    res = edit_and_complete(20, [target, 0, target, 0, "\n"], target + 1, col0)
    reparse = res[0]
    if os.environ.get("NY_AUDIT122_DEBUG"):
        print("target", target, repr(lines[target]), col0, "hover", hv, "reparse items", len(res[1].get("result", {}).get("items", [])))
    times.sort()
    hover_times.sort()
    typing.sort()
    print("latency on " + os.path.basename(big_path) + " (" + str(len(lines)) + " lines): first parse + symbols "
          + str(int(first)) + " ms; completion median " + str(int(times[2])) + " ms, hover median "
          + str(int(hover_times[2])) + " ms; completion while typing in a line median " + str(int(typing[2]))
          + " ms; completion after a new line (parsed again) " + str(int(reparse)) + " ms")
    check_true("completion on a large file: the class's members", len(it["items"]) > 20)
    check_true("completion and hover stay fast after the first parse (median < 250 ms, even under load)",
               times[2] < 250 and hover_times[2] < 250 and typing[2] < 250, [int(times[2]), int(hover_times[2]), int(typing[2])])
    c.notify("textDocument/didClose", {"textDocument": {"uri": uri(big_path)}})
    c.diagnostics(uri(big_path))

# ── shutdown and exit ────────────────────────────────────────────────────────
c.notify("textDocument/didClose", {"textDocument": {"uri": uri(p_fix)}})
cleared = c.diagnostics(uri(p_fix))
check("didClose clears the document's diagnostics", cleared["diagnostics"], [])
check("shutdown", c.req("shutdown", None), None)
r = c.request("textDocument/hover", doc_pos(uri(p_app), 0, 0))
check("a request after shutdown: InvalidRequest", r["error"]["code"], -32600)
c.notify("exit", None)
check("exit after shutdown: status 0", c.wait_exit(), 0)

# ── a second server: utf-32, exit without shutdown ───────────────────────────
c = Client()
init = c.req("initialize", {"processId": pid, "rootUri": None, "capabilities": {"general": {"positionEncodings": ["utf-32", "utf-16"]}}})
check("utf-32 when the client prefers it", init["capabilities"]["positionEncoding"], "utf-32")
c.notify("initialized", {})
open_doc(p_app, APP)
h = c.req("textDocument/hover", doc_pos(uri(p_app), 10, 15))
check("... columns are code points then (c is 15)", h["range"], R(10, 15, 10, 16))
c.notify("exit", None)
check("exit without shutdown: status 1", c.wait_exit(), 1)

# ── --tcp ────────────────────────────────────────────────────────────────────
c3 = Client(["--tcp", "0"])
port = None
t0 = time.monotonic()
while port is None and time.monotonic() - t0 < 20:
    c3._fill(0.2)
    i = c3.err.find("listening on 127.0.0.1:")
    if i >= 0 and "\n" in c3.err[i:]:
        port = int(c3.err[i + 23:c3.err.index("\n", i)])
check("--tcp prints its port", port is not None, True)
if port is not None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1", port))
    s.settimeout(20)
    def tcp_send(m):
        body = json_encode(m).encode("utf-8")
        s.sendall(("Content-Length: " + str(len(body)) + "\r\n\r\n").encode("ascii") + body)
    tcp_send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}})
    buf = b""
    while True:
        e = buf.find(b"\r\n\r\n")
        if e >= 0 and len(buf) >= e + 4 + int(buf[:e].decode("ascii").split(":")[1]):
            break
        d = s.recv(65536)
        if not d:
            break
        buf = buf + d
    resp = json_decode(buf[buf.find(b"\r\n\r\n") + 4:].decode("utf-8"))
    check("--tcp: initialize over the socket", resp["result"]["serverInfo"]["name"], "nylsp")
    tcp_send({"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
    tcp_send({"jsonrpc": "2.0", "method": "exit"})
    check("--tcp: exit status", c3.wait_exit(), 0)
    s.close()

# ── the end ──────────────────────────────────────────────────────────────────
import shutil
shutil.rmtree(root, ignore_errors=True)
pass_n = 0
fail_n = 0
for r in results:
    if r[1]:
        pass_n = pass_n + 1
    else:
        fail_n = fail_n + 1
print("Results: " + str(pass_n) + " passed, " + str(fail_n) + " failed")
if fail_n == 0:
    print("=== VM_AUDIT122 PASSED ===")
else:
    print("=== VM_AUDIT122 FAILED ===")
