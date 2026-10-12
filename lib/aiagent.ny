# ═══════════════════════════════════════════════════════════════════════════════
# aiagent.ny - NyxAI: a programming agent that works offline and deterministically
#
#     import "lib/aiagent.ny"
#     var agent = NyxAgent("/path/to/workspace")
#     agent.index_workspace()                 # BM25F index + program model + completion model
#     print(agent.ask("where is the config parsed").text())
#     print(agent.explain("parse_config").text())
#     agent.test("clamp")                     # writes and runs test_<module>_clamp.ny
#     agent.doc("clamp")                      # a drafted docstring, and the edit that inserts it
#     agent.review("app.ny")                  # findings with file:line and a fix suggestion
#     var r = agent.fix("app.ny")             # the mechanical fixes as a diff ...
#     agent.apply(r)                          # ... applied
#
# It answers from the workspace itself, with no model to download and no
# network: everything is computed from the code by the engine's own parser
# (the native ny_facts / text_defuse), so the same workspace gives the same
# answers. The parts (lib/nyxai/, round 82):
#   nyxai.index    retrieval: BM25F over functions, classes, modules and
#                  document sections, definitions over uses, call-graph
#                  neighbours, incremental updates, JSON persistence
#   nyxai.facts    program understanding: per-function facts, the call graph
#                  and the import graph
#   nyxai.rules    reasoning: a forward-chaining rule engine (Rete-style
#                  matching, stratified negation, explanations) - may_raise,
#                  recursive, pure, unused ... inferred over the facts
#   nyxai.review   review rules with mechanical fixes shown as a diff
#   nyxai.testgen  unittest modules from signatures, doctests and observed
#                  behaviour (boundary and random inputs, shrinking)
#   nyxai.docgen   docstrings from the facts
#   lib/nytorch/agent_learn.ny's CompletionRanker: the online model of the
#                  workspace's code that re-ranks the editor's completions
#
# The classes NyxAI kept since round 72 work as before, now on these parts:
# MemoryCell / MemoryStore (a key-value memory saved as JSON),
# CodeKnowledgeBase (documents ranked by BM25 instead of word matching),
# CodeAnalyzer (the review rules; its analyze() is what the IDE's Agent view
# shows), CodeGenerator, GitHubLearner (READMEs and pages through
# urllib.request - any base URL, so it can be pointed at a local mirror),
# DocumentLearner, OnlineLearner, ReasoningEngine (the rule engine: a rule
# fires on the words a question contains, stemmed, not on substrings),
# FileAssistant, IdeIntegration (a JSON-lines server for editors), NyxAI,
# NyxSharedBus, NyxFactory.
#
# Not here: free-form text generation (there is no language model; answers
# are ranked, cited excerpts and facts), and GitHub's code search needs a
# token and the network.
# ═══════════════════════════════════════════════════════════════════════════════

import "lib/nytorch/agent_learn.ny"
from nyxai.facts import ProgramModel, FunctionInfo, ClassInfo, ModuleInfo, default_rules, PY_BUILTINS
from nyxai.index import WorkspaceIndex, terms_of, stem as nyx_stem
from nyxai.rules import RuleEngine
from nyxai.review import Reviewer, fix_text, apply_edits, unified_diff_text
from nyxai.testgen import TestGenerator
from nyxai.docgen import draft_docstring, docstring_edit

# ─── Memory Cell ─────────────────────────────────────────────────────────────

class MemoryCell:
    def __init__(self, key, value, source, confidence):
        self.key = key
        self.value = value
        self.source = source
        self.confidence = confidence
        self.access_count = 0
        self.created_at = time_now()
        self.updated_at = time_now()
        self.tags = []
        self.tag_count = 0
        self.embedding = none

    def touch(self):
        self.access_count = self.access_count + 1
        self.updated_at = time_now()

    def add_tag(self, tag):
        if tag not in self.tags:
            self.tags.append(tag)
            self.tag_count = len(self.tags)

    def has_tag(self, tag):
        return tag in self.tags

    def to_dict(self):
        return {
            "key": self.key,
            "value": self.value,
            "source": self.source,
            "confidence": self.confidence,
            "access_count": self.access_count,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "tags": self.tags
        }

# ─── Memory Store (persistent) ───────────────────────────────────────────────

class MemoryStore:
    def __init__(self, store_path):
        self.store_path = store_path
        self.cells = {}
        self.cell_count = 0
        self.max_cells = 100000
        self.dirty = false
        self._load()

    def _load(self):
        var content = read_file(self.store_path)
        if content == none or len(content) == 0:
            return
        var data = none
        try:
            data = json_decode(content)
        except Exception:
            data = none
        if not isinstance(data, dict):
            return
        for k in list(data.keys()):
            var entry = data[k]
            # an entry that is not a stored cell (an older version saved some
            # whose fields are all null) is skipped
            if not isinstance(entry, dict) or entry.get("key") == none or entry.get("confidence") == none:
                continue
            var cell = MemoryCell(entry["key"], entry["value"], entry["source"], entry["confidence"])
            cell.access_count = entry.get("access_count", 0)
            cell.created_at = entry.get("created_at", cell.created_at)
            cell.updated_at = entry.get("updated_at", cell.updated_at)
            for t in entry.get("tags", []):
                cell.add_tag(t)
            self.cells[k] = cell
        self.cell_count = len(self.cells)

    def save(self):
        if not self.dirty:
            return
        var data = {}
        for k in list(self.cells.keys()):
            data[k] = self.cells[k].to_dict()
        var wire = json_encode(data)
        if wire != none:
            write_file(self.store_path, wire)
        self.dirty = false

    def store(self, key, value, source, confidence):
        var cell = MemoryCell(key, value, source, confidence)
        var old = self.cells.get(key)
        if old != none:
            for t in old.tags:
                cell.add_tag(t)
        self.cells[key] = cell
        self.cell_count = len(self.cells)
        self.dirty = true
        return cell

    def recall(self, key):
        var cell = self.cells.get(key)
        if cell == none:
            return none
        cell.touch()
        self.dirty = true
        return cell

    def forget(self, key):
        if key in self.cells:
            del self.cells[key]
            self.cell_count = len(self.cells)
            self.dirty = true
            return true
        return false

    # Cells ranked by how many of the query's terms (split, stemmed) their key
    # and value share - best first, then the most used.
    def search(self, query):
        var qts = set(terms_of(query))
        var ql = string_lower(query)
        var scored = []
        for k in list(self.cells.keys()):
            var cell = self.cells[k]
            var ts = set(terms_of(str(cell.key) + " " + str(cell.value)))
            var n = len(qts & ts)
            if string_lower(str(cell.key)) == ql:
                n = n + 10
            if n > 0:
                scored.append([-n, -cell.access_count, str(cell.key), cell])
        scored = sorted(scored, key=lambda e: (e[0], e[1], e[2]))
        return [e[3] for e in scored]

    def search_by_tag(self, tag):
        var out = []
        for k in list(self.cells.keys()):
            if self.cells[k].has_tag(tag):
                out.append(self.cells[k])
        return out

    def most_accessed(self, n):
        var cells = list(self.cells.values())
        cells = sorted(cells, key=lambda c: (-c.access_count, str(c.key)))
        return cells[0:n]

    def size(self):
        return self.cell_count

# ─── Knowledge Base ──────────────────────────────────────────────────────────

class CodeKnowledgeBase:
    def __init__(self, store_path):
        self.memory = MemoryStore(store_path)
        self.docs = WorkspaceIndex("")
        self.doc_count = 0
        self.code_snippets = []
        self.snippet_count = 0
        self.titles = {}

    def add_document(self, title, content, source):
        """Indexes a document's text (BM25) under its title."""
        var rel = "doc:" + title + ".txt"
        self.docs.add_text(rel, content)
        self.titles[rel] = [title, source]
        self.memory.store("doc:" + title, content[0:500], source, 1.0)
        self.doc_count = len(self.titles)

    def add_code_snippet(self, description, code, language, tags):
        var snippet = {"description": description, "code": code, "language": language, "tags": tags, "ts": time_now()}
        self.code_snippets.append(snippet)
        self.snippet_count = len(self.code_snippets)
        var key = "code:" + sha256(code)[0:16]
        var cell = self.memory.store(key, description, "code", 0.9)
        for t in tags:
            cell.add_tag(t)
        self.docs.add_text("snippet:" + key + ".txt", description + "\n" + code)
        self.titles["snippet:" + key + ".txt"] = [description, "code"]

    # The documents that answer a question best, as memory cells (key
    # "doc:<title>", value its best passage, confidence the BM25 score
    # scaled into (0, 1]), then the matching memory cells.
    def query(self, question):
        var out = []
        var hits = self.docs.search(question, 8)
        var top = 0.0
        if len(hits) > 0:
            top = hits[0].score
        for h in hits:
            var t = self.titles.get(h.rel)
            if t == none:
                continue
            var conf = 0.5 + 0.5 * (h.score / top if top > 0 else 0)
            var cell = MemoryCell("doc:" + t[0], h.snippet, t[1], conf)
            out.append(cell)
        for c in self.memory.search(question):
            if not string_startswith(str(c.key), "doc:") and c.confidence > 0.3:
                out.append(c)
        return out

    def find_code(self, description):
        var hits = self.docs.search(description, 5)
        var out = []
        for h in hits:
            if string_startswith(h.rel, "snippet:"):
                var key = h.rel[8:len(h.rel) - 4]
                for s in self.code_snippets:
                    if "code:" + sha256(s["code"])[0:16] == key:
                        out.append(s)
        return out

    def save(self):
        self.memory.save()

# ─── Code Analyzer ───────────────────────────────────────────────────────────
# The review rules of nyxai.review over one text; analyze() keeps the shape
# the IDE reads ({"line", "message", "code", "pattern"} per issue).

class CodeAnalyzer:
    def __init__(self):
        self.reviewer = Reviewer()
        self.patterns = {}
        for r in ["unused-import", "unused-variable", "unreachable-code", "shadowed-builtin", "mutable-default",
                  "bare-except", "none-comparison", "too-complex", "missing-self", "inconsistent-return"]:
            self.patterns[r] = r

    def findings(self, code, rel="<text>"):
        return self.reviewer.review_text(code, rel)

    def analyze(self, code):
        var lines = string_split(code, "\n")
        var issues = []
        for f in self.findings(code):
            var src = ""
            if f.line >= 1 and f.line <= len(lines):
                src = string_strip(lines[f.line - 1])
            issues.append({"line": f.line, "pattern": f.rule, "message": f.message, "code": src,
                           "suggestion": f.suggestion, "severity": f.severity, "fixable": f.fixable()})
        return issues

    def _facts(self, code):
        return ny_facts(code)

    def count_lines(self, code):
        return len(string_split(code, "\n"))

    def count_classes(self, code):
        return len(self._facts(code)["classes"])

    def count_functions(self, code):
        return len(self._facts(code)["functions"])

    def extract_class_names(self, code):
        return [c["name"] for c in self._facts(code)["classes"]]

    def suggest_improvements(self, code):
        var out = []
        var d = self._facts(code)
        if self.count_lines(code) > 500:
            out.append("Consider splitting this file into smaller modules (>500 lines)")
        for f in d["functions"]:
            if f["complexity"] > 10:
                out.append(f["qualname"] + " has cyclomatic complexity " + str(f["complexity"]) + ": split it")
            if f["doc"] == none and f["class"] == "" and f["parent"] == "":
                out.append(f["qualname"] + " has no docstring (@doc drafts one)")
        if len(d["functions"]) > 0 and len(d["classes"]) == 0 and len(d["functions"]) > 15:
            out.append("Consider organizing the functions into classes or modules")
        return out

# ─── Code Generator ──────────────────────────────────────────────────────────

class CodeGenerator:
    def __init__(self):
        self.indent = "    "

    def class_template(self, name, fields, methods):
        var code = "class " + name + ":\n"
        code = code + self.indent + "def __init__(self"
        for f in fields:
            code = code + ", " + f
        code = code + "):\n"
        if len(fields) == 0:
            code = code + self.indent + self.indent + "pass\n"
        for f in fields:
            code = code + self.indent + self.indent + "self." + f + " = " + f + "\n"
        for m in methods:
            code = code + "\n" + self.indent + "def " + m + "(self):\n"
            code = code + self.indent + self.indent + "pass\n"
        return code

    def getter_setter(self, field):
        var code = self.indent + "def get_" + field + "(self):\n"
        code = code + self.indent + self.indent + "return self." + field + "\n"
        code = code + "\n"
        code = code + self.indent + "def set_" + field + "(self, val):\n"
        code = code + self.indent + self.indent + "self." + field + " = val\n"
        return code

    def crud_api(self, entity):
        var i1 = self.indent
        var i2 = self.indent + self.indent
        var code = "# CRUD API for " + entity + "\n"
        code = code + "class " + entity + "Repository:\n"
        code = code + i1 + "def __init__(self):\n"
        code = code + i2 + "self.items = {}\n"
        code = code + i2 + "self.next_id = 1\n\n"
        code = code + i1 + "def create(self, data):\n"
        code = code + i2 + "data[\"id\"] = str(self.next_id)\n"
        code = code + i2 + "self.next_id = self.next_id + 1\n"
        code = code + i2 + "self.items[data[\"id\"]] = data\n"
        code = code + i2 + "return data\n\n"
        code = code + i1 + "def read(self, id):\n"
        code = code + i2 + "return self.items.get(id)\n\n"
        code = code + i1 + "def read_all(self):\n"
        code = code + i2 + "return list(self.items.values())\n\n"
        code = code + i1 + "def update(self, id, data):\n"
        code = code + i2 + "if id not in self.items:\n"
        code = code + i2 + i1 + "return None\n"
        code = code + i2 + "data[\"id\"] = id\n"
        code = code + i2 + "self.items[id] = data\n"
        code = code + i2 + "return data\n\n"
        code = code + i1 + "def delete(self, id):\n"
        code = code + i2 + "return self.items.pop(id, None) is not None\n"
        return code

    def rest_handler(self, entity, port):
        var code = "# REST server for " + entity + "\n"
        code = code + "import \"lib/webserver.ny\"\n"
        code = code + "repo = " + entity + "Repository()\n"
        code = code + "server = HttpServer(\"0.0.0.0\", " + str(port) + ")\n"
        code = code + "server.get(\"/" + string_lower(entity) + "s\", lambda req, res: res.send_json(repo.read_all()))\n"
        code = code + "server.post(\"/" + string_lower(entity) + "s\", lambda req, res: res.send_json(repo.create(req.json_body())))\n"
        code = code + "server.get(\"/" + string_lower(entity) + "s/:id\", lambda req, res: res.send_json(repo.read(req.params[\"id\"])))\n"
        code = code + "server.listen()\n"
        return code

def _nyx_mkdirs(path):
    if path != "" and not os_isdir(path):
        os_makedirs(path)

# ─── GitHub Learner ──────────────────────────────────────────────────────────
# READMEs and pages through urllib.request (round 77). raw_base / api_base
# can name any server laid out like GitHub's (a mirror, or a local
# http.server in a test).

def _nyx_fetch(url, headers=none, timeout=10):
    import urllib.request
    import urllib.error
    var req = urllib.request.Request(url, headers=headers if headers != none else {"User-Agent": "Nython-NyxAI"})
    try:
        var r = urllib.request.urlopen(req, timeout=timeout)
        var body = r.read()
        var status = r.status
        r.close()
        return [status, body.decode("utf-8", "replace")]
    except urllib.error.HTTPError as e:
        return [e.code, ""]
    except OSError:
        return [0, ""]

class GitHubLearner:
    def __init__(self, kb):
        self.kb = kb
        self.learned_repos = []
        self.repo_count = 0
        self.api_base = "https://api.github.com"
        self.raw_base = "https://raw.githubusercontent.com"
        self.token = ""
        self.timeout = 10

    def set_token(self, token):
        self.token = token

    def readme_url(self, owner, repo_name, branch):
        return self.raw_base + "/" + owner + "/" + repo_name + "/" + branch + "/README.md"

    def learn_from_repo(self, owner, repo_name):
        var content = ""
        for branch in ["main", "master"]:
            var got = _nyx_fetch(self.readme_url(owner, repo_name, branch), none, self.timeout)
            if got[0] == 200 and len(got[1]) > 0:
                content = got[1]
                break
        if len(content) == 0:
            return false
        var name = owner + "/" + repo_name
        self.kb.add_document(name, content, "github:" + name)
        if name not in self.learned_repos:
            self.learned_repos.append(name)
        self.repo_count = len(self.learned_repos)
        return true

    def learn_from_url(self, url, title):
        var got = _nyx_fetch(url, none, self.timeout)
        if got[0] != 200 or len(got[1]) == 0:
            return false
        self.kb.add_document(title, got[1], url)
        return true

    def search_patterns(self, language, pattern):
        # GitHub's code search (it needs a token): the matching items, [] on
        # failure. The query is URL-encoded and the API's headers are sent.
        import urllib.parse
        var q = urllib.parse.quote(pattern + " language:" + language)
        var url = self.api_base + "/search/code?q=" + q + "&per_page=10"
        var hdrs = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "Nython-NyxAI"}
        if self.token != "":
            hdrs["Authorization"] = "Bearer " + self.token
        var got = _nyx_fetch(url, hdrs, self.timeout)
        if got[0] != 200:
            return []
        try:
            return json_decode(got[1]).get("items", [])
        except Exception:
            return []

# ─── Document Learner ────────────────────────────────────────────────────────

class DocumentLearner:
    def __init__(self, kb):
        self.kb = kb
        self.learned_files = []
        self.file_count = 0

    def learn_file(self, filepath):
        var content = read_file(filepath)
        if content == none or len(content) == 0:
            return false
        self.kb.add_document(os_path_basename(filepath), content, "file:" + filepath)
        self.learned_files.append(filepath)
        self.file_count = len(self.learned_files)
        return true

    def learn_directory(self, dirpath, extension):
        var entries = os_listdir(dirpath)
        if entries == none:
            return 0
        var count = 0
        for name in sorted(entries):
            if string_endswith(name, extension):
                if self.learn_file(os_path_join(dirpath, name)):
                    count = count + 1
        return count

    def learn_url(self, url, title):
        var got = _nyx_fetch(url, none, 10)
        if got[0] != 200 or len(got[1]) == 0:
            return false
        var text = html_strip(got[1])
        if len(text) > 0:
            self.kb.add_document(title, text, url)
            return true
        return false

# ─── Online Learner ──────────────────────────────────────────────────────────

class OnlineLearner:
    def __init__(self, kb):
        self.kb = kb
        self.examples = []
        self.example_count = 0
        self.feedback = []
        self.feedback_count = 0

    def learn_from_conversation(self, question, answer, quality):
        var key = "qa:" + sha256(question)[0:16]
        var cell = self.kb.memory.store(key, answer, "conversation", quality)
        cell.add_tag("qa")
        cell.add_tag("conversation")
        self.examples.append({"q": question, "a": answer, "quality": quality, "ts": time_now()})
        self.example_count = len(self.examples)

    def learn_from_correction(self, wrong, correct, context):
        var key = "correction:" + sha256(wrong)[0:12]
        self.kb.memory.store(key, correct, "correction", 0.95)
        self.feedback.append({"wrong": wrong, "correct": correct, "context": context, "ts": time_now()})
        self.feedback_count = len(self.feedback)

    def best_examples(self, n):
        var out = []
        for e in self.examples:
            if len(out) >= n:
                break
            if e["quality"] > 0.7:
                out.append(e)
        return out

# ─── Reasoning Engine ────────────────────────────────────────────────────────
# Rules over facts with variables (nyxai.rules). The round-72 interface is
# kept: add_rule(condition, action) with a condition word fires when a
# question contains that word (stemmed: "errors" matches "error") - as the
# fact mentions(word), not a substring test; add_rule(conditions,
# conclusions) takes patterns.

class ReasoningEngine:
    def __init__(self, kb):
        self.kb = kb
        self.engine = RuleEngine()
        self.rules = []
        self.rule_count = 0
        self.actions = []

    def add_rule(self, condition_key, action_template):
        if isinstance(condition_key, list):
            var r = self.engine.rule("rule" + str(len(self.rules)), condition_key, action_template)
            self.rules.append({"condition": condition_key, "action": action_template})
            self.rule_count = len(self.rules)
            return r
        var conds = []
        for t in terms_of(str(condition_key)):
            conds.append(("mentions", t))
        if len(conds) == 0:
            conds.append(("mentions", string_lower(str(condition_key))))
        var idx = len(self.actions)
        self.actions.append(action_template)
        var r2 = self.engine.rule("suggest:" + str(condition_key), conds, [("suggest", idx)])
        self.rules.append({"condition": condition_key, "action": action_template})
        self.rule_count = len(self.rules)
        return r2

    # The actions of the rules a context's words make fire, in rule order.
    def infer(self, context):
        self.engine.reset()
        for t in terms_of(str(context)):
            self.engine.fact("mentions", t)
        self.engine.run()
        var idxs = sorted(self.engine.values(("suggest", "?i"), "?i"))
        return [self.actions[i] for i in idxs]

    def explain(self, question):
        var results = self.kb.query(question)
        if len(results) == 0:
            return "I don't have information about that yet. Ask me to learn it!"
        var best = results[0]
        return "Based on my knowledge (source: " + str(best.source) + ", confidence: " + str(round(best.confidence, 2)) + "): " + str(best.value)

# ─── File Assistant ──────────────────────────────────────────────────────────

class FileAssistant:
    def __init__(self, workspace):
        self.workspace = workspace
        _nyx_mkdirs(workspace)

    def create_file(self, filename, content):
        var path = os_path_join(self.workspace, filename)
        if write_file(path, content):
            return "Created: " + path
        return "Failed to create: " + path

    def read_file(self, filename):
        var path = os_path_join(self.workspace, filename)
        # `cat` rather than `read_file`: inside a method named read_file the
        # bare name resolves back to this method.
        var content = cat(path)
        if content == none:
            return "File not found: " + path
        return content

    def list_files(self):
        var entries = os_listdir(self.workspace)
        if entries == none:
            return []
        return sorted(entries)

    def delete_file(self, filename):
        var path = os_path_join(self.workspace, filename)
        if os_remove(path):
            return "Deleted: " + path
        return "Failed to delete: " + path

    def append_to_file(self, filename, content):
        return append_text(os_path_join(self.workspace, filename), content)

    def create_nython_file(self, filename, description, classes, functions):
        var code = "# " + description + "\n\n"
        var gen = CodeGenerator()
        for c in classes:
            code = code + gen.class_template(c, [], []) + "\n"
        for f in functions:
            code = code + "def " + f + "():\n    pass\n\n"
        return self.create_file(filename, code)

# ─── The programming agent ───────────────────────────────────────────────────
# A reply: lines to show, each optionally a link to file:line.

class AgentItem:
    def __init__(self, text, style, path, line):
        self.text = text
        self.style = style          # head, item, code, dim, ok, warn, err, diff+, diff-
        self.path = path            # an absolute path, or ""
        self.line = line            # 1-based, 0 for none

class AgentReply:
    def __init__(self, kind, title):
        self.kind = kind
        self.title = title
        self.items = []
        self.ok = true
        self.diff = ""
        self.edits = []
        self.path = ""              # the file the reply is about (fix: the file to change)
        self.new_text = none        # fix: the text after the fixes
        self.findings = []
        self.hits = []
        self.data = none

    def add(self, text, style="item", path="", line=0):
        self.items.append(AgentItem(text, style, path, line))
        return self

    def lines(self):
        return [it.text for it in self.items]

    def text(self):
        return self.title + "\n" + "\n".join(self.lines())

    def links(self):
        var out = []
        for it in self.items:
            if it.path != "":
                out.append([it.path, it.line])
        return out


class NyxAgent:
    def __init__(self, root, state_dir=none, ranker=none):
        self.root = os_path_abspath(root) if root != "" else ""
        self.state_dir = state_dir if state_dir != none else os_path_join(self.root, ".nython")
        self.index = WorkspaceIndex(self.root)
        self.model = self.index.model
        self.ranker = ranker if ranker != none else CompletionRanker()
        self.reviewer = Reviewer()
        self.testgen = TestGenerator()
        self.indexed = false
        self._rules = none
        self._rules_ver = -1
        self.history = []

    def index_path(self):
        return os_path_join(self.state_dir, "agent_index.json")

    def _path(self, p):
        if p == none or p == "":
            return ""
        if os_path_isabs(p):
            return p
        return os_path_join(self.root, p)

    # ── the workspace ────────────────────────────────────────────────────────
    def index_workspace(self, max_files=2000, use_saved=true):
        """Builds (or loads and refreshes) the index, and trains the
        completion model on the workspace's code. The number of files."""
        var loaded = false
        if use_saved and file_exists(self.index_path()):
            try:
                var idx = WorkspaceIndex.load(self.index_path())
                if idx.root == self.root:
                    idx.refresh(max_files)
                    self.index = idx
                    self.model = idx.model
                    loaded = true
            except Exception:
                loaded = false
        if not loaded:
            self.index = WorkspaceIndex(self.root)
            self.model = self.index.model
            self.index.build(max_files)
        for rel in sorted(self.model.modules):
            self.ranker.observe_source(self.model.modules[rel].text)
        self.indexed = true
        self._rules = none
        return len(self.index.files)

    def file_changed(self, path):
        """The IDE's watcher (or a save) changed a file: re-index it and learn from it."""
        if not self.indexed:
            return false
        var p = self._path(path)
        var rel = self.index.rel_of(p)
        if not self.index.wants(rel):
            return false
        var ok = self.index.update_file(p)
        var m = self.model.modules.get(rel)
        if m != none:
            self.ranker.observe_source(m.text)
        self._rules = none
        return ok

    def sync(self):
        """Picks up what changed on disk since the index was built (by
        modification time): [changed, added, removed]."""
        if not self.indexed:
            return [0, 0, 0]
        var before = {}
        for rel in list(self.index.files.keys()):
            before[rel] = self.index.files[rel]["mtime"]
        var ch = self.index.refresh()
        if ch[0] + ch[1] + ch[2] > 0:
            self._rules = none
            for rel in sorted(self.model.modules):
                var f = self.index.files.get(rel)
                if f != none and before.get(rel) != f["mtime"]:
                    self.ranker.observe_source(self.model.modules[rel].text)
        return ch

    def save(self):
        if not self.indexed:
            return ""
        return self.index.save(self.index_path())

    def _ensure(self):
        if not self.indexed:
            self.index_workspace()

    def rules(self):
        """The rule engine over the program model (rebuilt when files change)."""
        self._ensure()
        if self._rules == none:
            var eng = RuleEngine()
            self.model.rule_facts(eng)
            default_rules(eng)
            eng.run()
            self._rules = eng
        return self._rules

    def _link(self, rel, line):
        return [self._path(rel), line]

    # ── @ask ─────────────────────────────────────────────────────────────────
    def ask(self, question, k=5):
        self._ensure()
        var r = AgentReply("ask", "Ask: " + question)
        var hits = self.index.search(question, k)
        r.hits = hits
        if len(hits) == 0:
            r.ok = false
            r.add("Nothing in the workspace matches (" + str(len(self.index.files)) + " files indexed).", "dim")
            return r
        var i = 1
        for h in hits:
            var head = str(i) + ". " + h.cite() + "  " + h.kind + " " + h.qualname
            r.add(head, "head", self._path(h.rel), h.snippet_line)
            if h.summary != "" and h.summary != h.qualname:
                r.add("   " + h.summary, "dim", self._path(h.rel), h.line)
            if h.snippet != "":
                r.add("   " + str(h.snippet_line) + " | " + h.snippet, "code", self._path(h.rel), h.snippet_line)
            if len(h.boosts) > 0:
                r.add("   (" + "; ".join(h.boosts) + ")", "dim")
            i = i + 1
        # what the rules know about the functions the question names
        var eng = self.rules()
        var words = set(w for w in string_split(string_replace(question, "?", " "), " ") if w != "")
        for f in self.model.functions():
            if f.name in words or f.qualname in words:
                var q = self.model.fid(f)
                var raises = sorted(set(eng.values(("may_raise", q, "?e"), "?e")))
                if len(raises) > 0:
                    r.add(f.qualname + " may raise " + ", ".join(raises), "warn", self._path(f.rel), f.line)
                var callers = self.model.callers(f)
                if len(callers) > 0:
                    r.add(f.qualname + " is called by " + ", ".join(c.qualname + " (" + c.where() + ")" for c in callers), "item", self._path(callers[0].rel), callers[0].line)
        self.history.append(question)
        return r

    # ── @explain ─────────────────────────────────────────────────────────────
    def _resolve(self, symbol):
        self._ensure()
        var found = self.model.find(symbol)
        if len(found) == 0:
            return none
        return found[0]

    def explain(self, symbol):
        var x = self._resolve(symbol)
        var r = AgentReply("explain", "Explain: " + symbol)
        if x == none:
            r.ok = false
            var near = [h.qualname for h in self.index.search(symbol, 3) if h.kind != "section"]
            r.add("No function or class named '" + symbol + "' in the workspace.", "err")
            if len(near) > 0:
                r.add("Closest: " + ", ".join(near), "dim")
            return r
        if isinstance(x, ClassInfo):
            return self._explain_class(x, r)
        var f = x
        var eng = self.rules()
        var q = self.model.fid(f)
        r.data = f
        r.add(f.signature() + "    [" + f.kind() + ", " + f.rel + ":" + str(f.first) + "-" + str(f.end) + "]", "head", self._path(f.rel), f.line)
        if f.doc_summary() != "":
            r.add("\"" + f.doc_summary() + "\"", "dim", self._path(f.rel), max(f.doc_line, f.line))
        else:
            r.add("No docstring (@doc " + f.qualname + " drafts one).", "dim")
        var ps = f.explicit_params()
        if len(ps) > 0:
            var pt = []
            for p in ps:
                var s = p.name
                if p.annotation != none:
                    s = s + ": " + p.annotation
                if p.default != none:
                    s = s + " (default " + p.default + ")"
                if p.kind == "keyword_only":
                    s = s + " (keyword-only)"
                elif p.kind == "var_positional":
                    s = "*" + s
                elif p.kind == "var_keyword":
                    s = "**" + s
                pt.append(s)
            r.add("Parameters: " + "; ".join(pt))
        else:
            r.add("Parameters: none")
        if f.is_generator:
            r.add("A generator: calling it returns an iterator.")
        var valued = [x2 for x2 in f.returns if x2[1]]
        if len(valued) > 0:
            var rs = []
            for x3 in valued:
                if len(rs) < 5:
                    rs.append("`" + x3[2] + "` (line " + str(x3[0]) + ")")
            var tail = ""
            if f.end_reachable or len(valued) < len(f.returns):
                tail = "; None on the other paths"
            r.add("Returns: " + ", ".join(rs) + tail, "item", self._path(f.rel), valued[0][0])
        elif not f.is_generator:
            r.add("Returns: nothing (None)")
        for x4 in f.raises:
            if x4[1] != "":
                r.add("Raises " + x4[1] + " on line " + str(x4[0]) + ": raise " + x4[2], "warn", self._path(f.rel), x4[0])
        for b in sorted(eng.query(("raises_via", q, "?e", "?g")), key=lambda b: (b["?e"], b["?g"])):
            r.add("May raise " + b["?e"] + " through " + str(b["?g"]) + " (rule raise-through)", "warn")
        var callees = self.model.callees(f)
        var ext = []
        var seen = set()
        for x5 in f.raises:
            seen.add(x5[1])
        for c in f.calls:
            var g = self.model.resolve_call(f, c[1])
            if g == none and c[1] not in seen:
                seen.add(c[1])
                ext.append(c[1])
        if len(callees) > 0:
            for g2 in callees:
                r.add("Calls " + g2.qualname + " (" + g2.where() + ")", "item", self._path(g2.rel), g2.line)
        if len(ext) > 0:
            r.add("Calls outside the workspace: " + ", ".join(ext[0:12]))
        var callers = self.model.callers(f)
        for c2 in callers:
            r.add("Called by " + c2.qualname + " (" + c2.where() + ")", "item", self._path(c2.rel), c2.line)
        if len(callers) == 0:
            r.add("Not called anywhere in the workspace.", "dim")
        if len(f.globals_read) > 0 or len(f.globals_written) > 0:
            r.add("Module variables: reads " + (", ".join(f.globals_read) if len(f.globals_read) > 0 else "none") +
                  "; writes " + (", ".join(f.globals_written) if len(f.globals_written) > 0 else "none"))
        var cx = f.complexity
        var grade = "simple"
        if cx > 20:
            grade = "very complex: split it"
        elif cx > 10:
            grade = "complex"
        elif cx > 5:
            grade = "moderate"
        r.add("Cyclomatic complexity " + str(cx) + " (" + grade + ")")
        var facts = []
        if eng.has("recursive", q):
            facts.append("recursive")
        if eng.has("pure", q):
            facts.append("pure (no I/O, no module writes, directly or through its calls)")
        elif eng.has("impure", q):
            var io = eng.values(("io", q, "?c"), "?c")
            facts.append("not pure" + (" (calls " + ", ".join(sorted(set(io))) + ")" if len(io) > 0 else " (through its calls)"))
        if eng.has("unused", q):
            facts.append("never called in the workspace")
        if len(facts) > 0:
            r.add("Inferred: " + "; ".join(facts))
        return r

    def _explain_class(self, c, r):
        r.data = c
        r.add("class " + c.name + ("(" + ", ".join(c.bases) + ")" if len(c.bases) > 0 else "") + "    [" + c.rel + ":" + str(c.line) + "-" + str(c.end) + "]", "head", self._path(c.rel), c.line)
        if c.doc != none and string_strip(c.doc) != "":
            r.add("\"" + string_strip(c.doc).split("\n")[0] + "\"", "dim")
        for f in c.module.functions:
            if f.cls == c.name and f.parent == "":
                r.add(f.kind() + " " + f.signature(), "item", self._path(f.rel), f.line)
        var subs = [k for k in self.model.classes() if c.name in [b.split(".")[-1] for b in k.bases]]
        for k in subs:
            r.add("Subclass " + k.name + " (" + k.where() + ")", "item", self._path(k.rel), k.line)
        return r

    # ── @test ────────────────────────────────────────────────────────────────
    def test(self, symbol, run=true, out_dir=none):
        var r = AgentReply("test", "Test: " + symbol)
        self._ensure()
        var f = self.model.find_function(symbol)
        if f == none:
            r.ok = false
            r.add("No function named '" + symbol + "' in the workspace.", "err")
            return r
        var eng = self.rules()
        var expected = eng.values(("may_raise", self.model.fid(f), "?e"), "?e")
        var res = self.testgen.generate(f, out_dir, expected)
        r.data = res
        if not res.ok:
            r.ok = false
            r.add(res.summary(), "err", self._path(f.rel), f.line)
            return r
        r.path = res.path
        r.add(res.summary() + " (" + str(res.probe_runs) + (" probe run)" if res.probe_runs == 1 else " probe runs)"), "head", res.path, 1)
        r.add("Domains: " + ", ".join(n + ": " + res.domains[n] for n in res.domains), "dim")
        for x in res.findings:
            r.add("Found: " + x, "warn", self._path(f.rel), f.line)
        if run:
            var got = self.testgen.run(res)
            r.ok = got[0]
            var tail = [l for l in string_split(got[1], "\n") if string_strip(l) != ""]
            var last = tail[len(tail) - 3:len(tail)] if len(tail) > 3 else tail
            for l in last:
                r.add(l, "ok" if got[0] else "err")
        return r

    # ── @doc ─────────────────────────────────────────────────────────────────
    def doc(self, symbol):
        var r = AgentReply("doc", "Doc: " + symbol)
        self._ensure()
        var f = self.model.find_function(symbol)
        if f == none:
            r.ok = false
            r.add("No function named '" + symbol + "' in the workspace.", "err")
            return r
        var eng = self.rules()
        var q = self.model.fid(f)
        var mr = []
        for b in sorted(eng.query(("raises_via", q, "?e", "?g")), key=lambda b: (b["?e"], b["?g"])):
            var g = b["?g"]
            if string_contains(g, "::"):
                g = string_split(g, "::")[1]
            mr.append([b["?e"], g])
        var du = text_defuse(f.module.text)
        var text = draft_docstring(f, du, mr)
        var e = docstring_edit(f, du, mr)
        r.data = text
        r.path = f.file
        r.edits = [e]
        r.add("Docstring for " + f.signature() + " (" + f.where() + ")", "head", f.file, f.line)
        for l in string_split(text, "\n"):
            r.add("    " + l, "code")
        var res = apply_edits(f.module.lines, [e])
        r.new_text = string_join(res[0], "\n")
        r.diff = unified_diff_text(f.module.text, r.new_text, f.rel)
        return r

    # ── @review / @fix ───────────────────────────────────────────────────────
    def _module_for(self, path, text=none):
        var p = self._path(path)
        if text != none:
            return ModuleInfo(p, self.index.rel_of(p), text)
        var rel = self.index.rel_of(p)
        var m = self.model.modules.get(rel)
        if m != none and m.path == p:
            return m
        return ModuleInfo(p, rel, read_file(p))

    def review(self, path, text=none):
        var m = self._module_for(path, text)
        var r = AgentReply("review", "Review: " + m.rel)
        r.path = m.path
        var fs = self.reviewer.review_module(m)
        r.findings = fs
        if len(fs) == 0:
            r.add("No findings in " + m.rel + ".", "ok")
            return r
        var nfix = len([f for f in fs if f.fixable()])
        r.add(str(len(fs)) + " finding(s), " + str(nfix) + " fixable by @fix", "head")
        for f in fs:
            var style = "warn"
            if f.severity == "error":
                style = "err"
            elif f.severity == "convention" or f.severity == "refactor":
                style = "item"
            r.add(f.cite() + "  [" + f.rule + "] " + f.message, style, m.path, f.line)
            r.add("    -> " + f.suggestion + (" (fixable)" if f.fixable() else ""), "dim", m.path, f.line)
        return r

    def fix(self, path, text=none):
        """The mechanical fixes for a file as a diff; nothing is written
        (apply() writes it)."""
        var m = self._module_for(path, text)
        var r = AgentReply("fix", "Fix: " + m.rel)
        r.path = m.path
        var fs = [f for f in self.reviewer.review_module(m) if f.fixable()]
        if len(fs) == 0:
            r.add("Nothing to fix mechanically in " + m.rel + ".", "ok")
            r.new_text = m.text
            return r
        var res = fix_text(m.text, fs, m.rel)
        r.new_text = res[0]
        r.diff = res[1]
        r.findings = res[2]
        r.add(str(len(res[2])) + " fix(es) for " + m.rel + " - review the diff, then apply", "head", m.path, 1)
        for f in res[2]:
            r.add("  " + f.cite() + "  " + f.rule + ": " + f.suggestion, "item", m.path, f.line)
        for l in string_split(r.diff, "\n"):
            if string_startswith(l, "+") and not string_startswith(l, "+++"):
                r.add(l, "diff+")
            elif string_startswith(l, "-") and not string_startswith(l, "---"):
                r.add(l, "diff-")
            elif l != "":
                r.add(l, "code")
        return r

    def apply(self, reply):
        """Writes a fix (or a docstring) reply's new text to its file."""
        if reply.new_text == none or reply.path == "":
            return false
        write_file(reply.path, reply.new_text)
        self.file_changed(reply.path)
        return true

    # ── completion ───────────────────────────────────────────────────────────
    def rerank(self, names, kinds, text_before, typed):
        if not self.ranker.trained():
            return [names, kinds]
        return self.ranker.rerank(names, kinds, self.ranker.context(text_before), typed)

    def run_command(self, verb, arg, path=""):
        """The IDE's and the command line's @verb arg."""
        if verb == "ask":
            return self.ask(arg)
        if verb == "explain":
            return self.explain(arg)
        if verb == "test":
            return self.test(arg)
        if verb == "doc":
            return self.doc(arg)
        if verb == "review":
            return self.review(arg if arg != "" else path)
        if verb == "fix":
            return self.fix(arg if arg != "" else path)
        var r = AgentReply("error", "@" + verb)
        r.ok = false
        r.add("unknown agent command '" + verb + "' - try @ask, @explain, @test, @doc, @review, @fix", "err")
        return r

# ─── IDE Integration (a JSON-lines server for editors) ───────────────────────

class IdeIntegration:
    def __init__(self, nyx):
        self.nyx = nyx
        self.socket_path = ""
        self.server_fd = -1
        self.port = none
        self._srv = none
        self._serving = false

    def autocomplete(self, prefix, context):
        var words = []
        for c in self.nyx.kb.memory.search(prefix):
            if string_startswith(str(c.key), prefix) and c.key not in words:
                words.append(c.key)
        for n in self.nyx.analyzer.extract_class_names(context):
            if string_startswith(n, prefix) and n not in words:
                words.append(n)
        for t in code_tokens(context):
            if t[1] == "identifier" and string_startswith(t[0], prefix) and t[0] not in words:
                words.append(t[0])
        var kinds = ["word" for w in words]
        var lines = string_split(context, "\n")
        return self.nyx.agent.rerank(words, kinds, lines[len(lines) - 1] if len(lines) > 0 else "", prefix)[0]

    def hover_info(self, symbol):
        if self.nyx.agent.indexed:
            var r = self.nyx.agent.explain(symbol)
            if r.ok:
                return string_join(r.lines()[0:4], "\n")
        var cell = self.nyx.kb.memory.recall(symbol)
        if cell != none:
            return "Symbol: " + symbol + "\nSource: " + cell.source + "\nInfo: " + str(cell.value)
        return "No info for: " + symbol

    def quick_fix(self, issue_msg, code_context):
        return self.nyx.suggest_fix(issue_msg, code_context)

    def format_code(self, code):
        # the IDE's formatter (native text services)
        return text_format_nython(code)

    def start_server(self, port=9999, host="127.0.0.1"):
        # Serves handle_request() to editors: one JSON request per line, one
        # JSON reply per line, a thread per client. self.port is the port.
        import socket
        import threading
        try:
            self._srv = socket.create_server((host, port))
        except OSError:
            return false
        self.port = self._srv.getsockname()[1]
        self.server_fd = self._srv.fileno()
        self._serving = true
        var t = threading.Thread(target=self._accept_loop, daemon=true)
        t.start()
        return true

    def _accept_loop(self):
        import threading
        while self._serving:
            if not self._srv.wait_readable(0.2):
                continue
            try:
                var pair = self._srv.accept()
                threading.Thread(target=self._serve_client, args=(pair[0],), daemon=true).start()
            except OSError:
                break

    def _serve_client(self, conn):
        var f = conn.makefile("rb")
        try:
            while true:
                var line = f.readline()
                if len(line) == 0:
                    break
                var text = line.decode("utf-8", "replace").strip()
                if text == "":
                    continue
                var reply = none
                try:
                    reply = self.handle_request(text)
                except Exception as e:
                    reply = json_encode({"error": type(e).__name__ + ": " + str(e)})
                conn.sendall((reply + "\n").encode("utf-8"))
        except OSError:
            pass
        conn.close()

    def stop_server(self):
        self._serving = false
        if self.server_fd != -1:
            self._srv.close()
            self.server_fd = -1

    def handle_request(self, raw):
        var req = none
        try:
            req = json_decode(raw)
        except Exception:
            req = none
        if not isinstance(req, "map") or not ("command" in req):
            return json_encode({"error": "invalid request"})
        var cmd = req["command"]
        var resp = {}
        if cmd == "autocomplete":
            resp["suggestions"] = self.autocomplete(req["prefix"], req["context"])
        elif cmd == "hover":
            resp["info"] = self.hover_info(req["symbol"])
        elif cmd == "ask":
            resp["answer"] = self.nyx.ask(req["question"])
        elif cmd == "fix":
            resp["fix"] = self.quick_fix(req["issue"], req["code"])
        elif cmd == "generate":
            resp["code"] = self.nyx.generate(req["prompt"])
        elif cmd == "analyze":
            resp["issues"] = self.nyx.analyze(req["code"])
        elif cmd in ["explain", "review", "doc", "test"]:
            var r = self.nyx.agent.run_command(cmd, req.get("arg", ""), req.get("path", ""))
            resp["ok"] = r.ok
            resp["title"] = r.title
            resp["lines"] = r.lines()
            resp["links"] = r.links()
        else:
            resp["error"] = "unknown command: " + str(cmd)
        return json_encode(resp)

# ─── NyxAI Core ──────────────────────────────────────────────────────────────

class NyxAI:
    def __init__(self, name, workspace):
        self.name = name
        self.workspace = workspace
        self.version = "2.0.0"
        self.started_at = time_now()
        self.interaction_count = 0
        _nyx_mkdirs(workspace)
        self.kb = CodeKnowledgeBase(os_path_join(workspace, "nyx_memory.json"))
        self.analyzer = CodeAnalyzer()
        self.generator = CodeGenerator()
        self.files = FileAssistant(workspace)
        self.github = GitHubLearner(self.kb)
        self.docs = DocumentLearner(self.kb)
        self.online = OnlineLearner(self.kb)
        self.reasoning = ReasoningEngine(self.kb)
        self.agent = NyxAgent(workspace, os_path_join(workspace, ".nython"))
        self.ide = IdeIntegration(self)
        self.context_history = []
        self.history_count = 0
        self.max_history = 50
        self.is_learning = true
        self.verbose = false
        self._init_rules()
        self._load_builtins()

    def _init_rules(self):
        self.reasoning.add_rule("error", "Check for syntax errors and undefined variables (@review runs the analysis)")
        self.reasoning.add_rule("slow", "Profile it (Run > Profile with cProfile) before optimising")
        self.reasoning.add_rule("memory", "Use generators rather than building large lists at once")
        self.reasoning.add_rule("network", "Check the connection, set timeouts and retry with backoff")
        self.reasoning.add_rule("class", "Initialise every instance attribute in __init__")
        self.reasoning.add_rule("loop", "Make sure every loop has a reachable exit condition")
        self.reasoning.add_rule("import", "Put imports at the top of the file")
        self.reasoning.add_rule("test", "@test <function> writes a unittest module for it")

    def _load_builtins(self):
        self.kb.add_document("Nython", "Nython is a Python-like language with its own lexer, parser, bytecode compiler and virtual machine. It runs Python code and adds var/let/const, optional chaining a?.b, null coalescing a ?? b and suffix literals.", "builtin")
        self.kb.add_document("imports", "import name runs a module in a scope of its own; import \"lib/file.ny\" includes a file; from m import x binds names.", "builtin")
        self.kb.add_document("classes", "Define a class with class Name: and initialise it in def __init__(self). Methods take self first.", "builtin")
        self.kb.add_document("loops", "Use for item in items: or while condition: with an indented body; range(start, stop) counts.", "builtin")
        self.kb.add_document("tensors", "nytorch's Tensor and autograd: tensor([1.0, 2.0]) makes a tensor.", "builtin")

    def ask(self, question):
        self.interaction_count = self.interaction_count + 1
        if len(self.context_history) < self.max_history:
            self.context_history.append({"q": question, "ts": time_now()})
            self.history_count = len(self.context_history)
        var answer = ""
        if self.agent.indexed and len(self.agent.index.files) > 0:
            var r = self.agent.ask(question, 3)
            if r.ok:
                answer = string_join(r.lines(), "\n")
        if answer == "":
            answer = self.reasoning.explain(question)
        var inferences = self.reasoning.infer(question)
        if len(inferences) > 0:
            answer = answer + "\n\nSuggestions:\n"
            for s in inferences:
                answer = answer + "- " + str(s) + "\n"
        if self.is_learning:
            self.online.learn_from_conversation(question, answer, 0.6)
        return answer

    def analyze(self, code):
        var issues = self.analyzer.analyze(code)
        var suggestions = self.analyzer.suggest_improvements(code)
        var d = ny_facts(code)
        return {"stats": {"lines": self.analyzer.count_lines(code), "classes": len(d["classes"]),
                          "functions": len(d["functions"]), "issues": len(issues), "suggestions": len(suggestions)},
                "issues": issues, "suggestions": suggestions, "class_names": [c["name"] for c in d["classes"]]}

    def generate(self, prompt):
        var prompt_lower = string_lower(prompt)
        var words = string_split(prompt, " ")
        var cap = none
        for w in words:
            if len(w) > 0 and w[0] >= "A" and w[0] <= "Z":
                cap = w
                break
        if string_contains(prompt_lower, "crud") or string_contains(prompt_lower, "repository"):
            return self.generator.crud_api(cap if cap != none else "Entity")
        if string_contains(prompt_lower, "class"):
            return self.generator.class_template(cap if cap != none else "MyClass", ["value"], ["process", "to_string"])
        if string_contains(prompt_lower, "rest") or string_contains(prompt_lower, "api") or string_contains(prompt_lower, "server"):
            return self.generator.rest_handler(cap if cap != none else "Item", 8080)
        var snippets = self.kb.find_code(prompt)
        if len(snippets) > 0:
            return "# Found existing snippet:\n" + snippets[0]["code"]
        return "# TODO: " + prompt + "\nclass Solution:\n    def __init__(self):\n        pass\n\n    def solve(self):\n        pass\n"

    def suggest_fix(self, issue, code_context):
        var out = []
        if code_context != none and code_context != "":
            for f in self.analyzer.findings(code_context):
                out.append("line " + str(f.line) + ": " + f.message + " -> " + f.suggestion)
        for s in self.reasoning.infer(issue):
            out.append(str(s))
        for c in self.kb.query(issue)[0:3]:
            out.append("From KB: " + str(c.value))
        return out

    def learn_github(self, owner, repo):
        if self.github.learn_from_repo(owner, repo):
            return self.name + ": Learned from " + owner + "/" + repo
        return self.name + ": Could not learn from " + owner + "/" + repo

    def learn_file(self, filepath):
        if self.docs.learn_file(filepath):
            return self.name + ": Learned from " + filepath
        return self.name + ": Could not read " + filepath

    def learn_url(self, url, title):
        if self.docs.learn_url(url, title):
            return self.name + ": Learned from " + url
        return self.name + ": Could not fetch " + url

    def remember(self, key, value):
        self.kb.memory.store(key, value, "user", 1.0)
        return self.name + ": Remembered '" + key + "'"

    def recall(self, key):
        var cell = self.kb.memory.recall(key)
        if cell == none:
            return self.name + ": I don't know about '" + key + "' yet"
        return str(cell.value)

    def forget(self, key):
        self.kb.memory.forget(key)
        return self.name + ": Forgot '" + key + "'"

    def create_file(self, filename, content):
        return self.files.create_file(filename, content)

    def read_file(self, filename):
        return self.files.read_file(filename)

    def list_workspace(self):
        return self.files.list_files()

    def correct(self, wrong, correct):
        self.online.learn_from_correction(wrong, correct, "user feedback")
        return self.name + ": Thanks for the correction! I'll remember that."

    def save(self):
        self.kb.save()
        self.agent.save()
        return self.name + ": Memory saved to disk"

    def status(self):
        return {
            "name": self.name,
            "version": self.version,
            "memory_cells": self.kb.memory.size(),
            "documents": self.kb.doc_count,
            "code_snippets": self.kb.snippet_count,
            "interactions": self.interaction_count,
            "uptime_seconds": time_now() - self.started_at,
            "workspace": self.workspace,
            "github_repos_learned": self.github.repo_count,
            "files_learned": self.docs.file_count,
            "files_indexed": len(self.agent.index.files)
        }

    def greeting(self):
        return "Hi! I'm " + self.name + " v" + self.version + ", your Nython programming agent.\n" + "I have " + str(self.kb.memory.size()) + " memory cells and " + str(self.kb.doc_count) + " documents.\n" + "Ask me about your code, or use @explain, @test, @doc, @review and @fix."

    def start_ide_server(self):
        return self.ide.start_server()

    def handle_ide(self, raw_request):
        return self.ide.handle_request(raw_request)

    def autocomplete(self, prefix, context):
        return self.ide.autocomplete(prefix, context)

# ─── Shared Memory Bus (shares knowledge between NyxAI instances) ────────────

class NyxSharedBus:
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.instances = {}
        self.instance_count = 0
        self.server_fd = -1
        self.running = false

    def register(self, nyx):
        self.instances[nyx.name] = nyx
        self.instance_count = len(self.instances)

    def broadcast_memory(self, key, value, source):
        for n in sorted(self.instances.keys()):
            self.instances[n].kb.memory.store(key, value, "shared:" + source, 0.8)

    def sync_all(self):
        var names = sorted(self.instances.keys())
        if len(names) < 2:
            return
        for a in names:
            var popular = self.instances[a].kb.memory.most_accessed(50)
            for b in names:
                if b != a:
                    for cell in popular:
                        self.instances[b].kb.memory.store(cell.key, cell.value, "sync:" + a, cell.confidence * 0.9)

    def save_all(self):
        for n in sorted(self.instances.keys()):
            self.instances[n].save()

# ─── Factory ─────────────────────────────────────────────────────────────────

class NyxFactory:
    def __init__(self):
        self.bus = none

    def create(self, name, workspace):
        var nyx = NyxAI(name, workspace)
        if self.bus != none:
            self.bus.register(nyx)
        return nyx

    def create_cluster(self, names, workspace_root):
        var cluster = []
        for n in names:
            var nyx = NyxAI(n, os_path_join(workspace_root, n))
            cluster.append(nyx)
            if self.bus != none:
                self.bus.register(nyx)
        return cluster

    def sync_cluster(self):
        if self.bus != none:
            self.bus.sync_all()

    def save_cluster(self):
        if self.bus != none:
            self.bus.save_all()
