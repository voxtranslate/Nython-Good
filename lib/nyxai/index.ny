# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai/index.ny - retrieval over a workspace's code and documents: a
# BM25F index of functions, classes, modules and document sections, with
# structure-aware boosts, incremental updates and persistence (round 82).
#
#     from nyxai.index import WorkspaceIndex
#     idx = WorkspaceIndex("/path/to/workspace")
#     idx.build()                                   # every .ny/.py/.md/.txt file
#     for h in idx.search("where is the config parsed", 5):
#         print(h.cite(), h.kind, h.name, h.snippet)  # "src/conf.ny:12 function parse_config ..."
#     idx.update_file(path)                         # one file changed (the IDE's watcher)
#     idx.save("/tmp/ws.idx.json"); idx2 = WorkspaceIndex.load("/tmp/ws.idx.json")
#     idx2.refresh()                                # re-indexes only what changed on disk
#
# Ranking: Okapi BM25 (Robertson & Zaragoza, "The Probabilistic Relevance
# Framework: BM25 and Beyond", 2009) over fields, as BM25F: a chunk's term
# frequency is the weighted sum of its fields' (name 4, docstring 2,
# comments 1.5, code 1, path 1), with k1 = 1.2, b = 0.75 and the
# non-negative idf ln(1 + (N - df + 0.5) / (df + 0.5)). Terms are split as
# code is written - parseHTTPResponse and parse_http_response both give
# parse, http, response (and the whole word) - lower-cased, stop words
# dropped and lightly stemmed (parse/parses/parsed/parsing/parser agree).
#
# Structure-aware boosts, from the real parser's facts (nyxai.facts):
#   - a chunk that *defines* a symbol the query names (its name is a query
#     word, or all of the name's parts are query terms) is boosted over the
#     chunks that only use it (x2);
#   - call-graph neighbours: a function also gets a share (0.3) of the best
#     score among the functions it calls or is called by - one step of score
#     propagation over the graph (as hyperlink-based relevance propagation,
#     Shakery & Zhai 2003), so the caller that ties two hits together, or the
#     helper behind a well-matched entry point, rises.
# Ties are broken by path and line, so results are deterministic.
#
# Not here: phrase or proximity scoring, synonyms or embeddings (everything
# is lexical, offline and deterministic), and files other than text.

__all__ = ["WorkspaceIndex", "Hit", "terms_of", "query_terms", "stem"]

import os
import json
import math
import re
from nyxai.facts import ProgramModel, ModuleInfo

INDEX_VERSION = 1

STOP = set(["a", "an", "and", "are", "as", "at", "be", "by", "do", "does", "for", "from", "has", "have",
            "how", "i", "if", "in", "into", "is", "it", "its", "of", "on", "or", "that", "the", "this",
            "to", "was", "we", "what", "when", "where", "which", "who", "why", "will", "with", "you",
            "def", "return", "self", "var", "let", "none", "true", "false", "elif", "else", "pass",
            "import", "class", "not", "can", "there", "their", "them", "these", "those", "then",
            "than", "s", "use", "used", "using", "get", "set"])

FIELD_W = {"name": 4.0, "doc": 2.0, "comment": 1.5, "code": 1.0, "path": 1.0}
K1 = 1.2
B = 0.75
DEF_BOOST = 2.0
GRAPH_SHARE = 0.3

_WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def stem(w):
    """A light suffix stripper (after Porter's step 1): enough that a word's
    inflections meet."""
    n = len(w)
    if n <= 3:
        return w
    if w.endswith("ies") and n > 4:
        w = w[0:n - 3] + "y"
    elif w.endswith("sses"):
        w = w[0:n - 2]
    elif w.endswith("s") and not w.endswith("ss") and not w.endswith("us") and not w.endswith("is"):
        w = w[0:n - 1]
    n = len(w)
    if w.endswith("ing") and n > 5:
        w = w[0:n - 3]
    elif w.endswith("ed") and n > 4:
        w = w[0:n - 2]
    elif w.endswith("er") and n > 4:
        w = w[0:n - 2]
    n = len(w)
    if w.endswith("e") and n > 4:
        w = w[0:n - 1]
    n = len(w)
    if n > 3 and w[n - 1] == w[n - 2] and w[n - 1] not in "lsz" and w[n - 1] not in "aeiou":
        w = w[0:n - 1]
    return w


def _parts(word):
    """camelCase / snake_case / HTTPServer parts of an identifier, lower-cased."""
    out = []
    for piece in word.split("_"):
        if piece == "":
            continue
        cur = ""
        n = len(piece)
        for i in range(n):
            ch = piece[i]
            if cur != "":
                prev = piece[i - 1]
                nxt = piece[i + 1] if i + 1 < n else ""
                boundary = False
                if ch.isupper() and (prev.islower() or prev.isdigit()):
                    boundary = True
                elif ch.isupper() and prev.isupper() and nxt != "" and nxt.islower():
                    boundary = True
                elif ch.isdigit() != prev.isdigit():
                    boundary = True
                if boundary:
                    out.append(cur.lower())
                    cur = ""
            cur = cur + ch
        if cur != "":
            out.append(cur.lower())
    return out


class _Tokenizer:
    def __init__(self):
        self.cache = {}

    def word(self, w):
        t = self.cache.get(w)
        if t is not None:
            return t
        ps = _parts(w)
        out = []
        for p in ps:
            if len(p) < 2 or p in STOP or p.isdigit():
                continue
            out.append(stem(p))
        whole = w.lower().strip("_")
        if len(ps) > 1 and whole not in STOP and len(whole) > 2:
            out.append(whole)
        if len(self.cache) < 200000:
            self.cache[w] = out
        return out

    def parts(self, w):
        """The stemmed parts of an identifier, without the whole word."""
        out = []
        for p in _parts(w):
            if len(p) >= 2 and p not in STOP and not p.isdigit():
                out.append(stem(p))
        return out

    def add(self, text, tf, weight):
        n = 0
        for w in _WORD_RE.findall(text):
            for t in self.word(w):
                tf[t] = tf.get(t, 0.0) + weight
                n += 1
        return n


_TOK = _Tokenizer()


def terms_of(text):
    """The index terms of a text, in order (with repeats)."""
    out = []
    for w in _WORD_RE.findall(text):
        out.extend(_TOK.word(w))
    return out


def query_terms(q):
    return terms_of(q)


class Hit:
    def __init__(self, chunk, score, base):
        self.chunk = chunk
        self.rel = chunk["rel"]
        self.kind = chunk["kind"]
        self.name = chunk["name"]
        self.qualname = chunk["qual"]
        self.line = chunk["line"]
        self.end = chunk["end"]
        self.summary = chunk["summary"]
        self.score = score
        self.base = base           # the BM25F score before the boosts
        self.boosts = []
        self.snippet = ""
        self.snippet_line = chunk["line"]

    def cite(self):
        return self.rel + ":" + str(self.snippet_line)

    def __repr__(self):
        return "<Hit " + self.cite() + " " + self.kind + " " + self.name + " " + str(round(self.score, 3)) + ">"


def _comment_text(line):
    i = line.find("#")
    if i < 0:
        return ""
    return line[i + 1:]


class WorkspaceIndex:
    def __init__(self, root="", exts=None):
        self.root = root
        self.exts = exts if exts is not None else [".ny", ".py", ".md", ".txt", ".rst"]
        self.model = ProgramModel(root)
        self.reset()

    def reset(self):
        self.chunks = {}          # id -> chunk dict
        self.files = {}           # rel -> {"mtime", "ids": [...]}
        self.postings = {}        # term -> {id: weighted tf}
        self.df = {}
        self.total_len = 0.0
        self.next_id = 1
        self.by_key = {}          # "rel::qualname" -> chunk id
        self.updates = 0

    # ── building ─────────────────────────────────────────────────────────────
    def rel_of(self, path):
        return self.model.rel_of(path)

    def wants(self, rel):
        return any(rel.endswith(e) for e in self.exts)

    def build(self, max_files=2000):
        n = 0
        for rel in fs_list_files(self.root, max_files, [".git", "node_modules", "build", "__pycache__", ".nython"]):
            if self.wants(rel):
                if self.update_file(os.path.join(self.root, rel)):
                    n += 1
        return n

    def update_file(self, path, text=None):
        """(Re-)indexes one file; a file gone from disk is removed."""
        rel = self.rel_of(path)
        if text is None:
            if not os.path.isfile(path):
                return self.remove_file(path)
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                return False
        mtime = file_mtime(path) if os.path.exists(path) else -1
        self._drop(rel)
        ids = []
        if rel.endswith(".ny") or rel.endswith(".py"):
            m = self.model.add_file(path, text)
            for c in self._code_chunks(m):
                ids.append(self._add_chunk(c))
        else:
            for c in self._text_chunks(rel, text):
                ids.append(self._add_chunk(c))
        self.files[rel] = {"mtime": mtime, "ids": ids}
        self.updates += 1
        return True

    def add_text(self, rel, text):
        """Indexes text under a relative name (an unsaved buffer, a test)."""
        return self.update_file(os.path.join(self.root, rel), text)

    def remove_file(self, path):
        rel = self.rel_of(path)
        had = rel in self.files
        self._drop(rel)
        if rel in self.files:
            del self.files[rel]
        self.model.remove_file(path)
        return had

    def _drop(self, rel):
        f = self.files.get(rel)
        if f is None:
            return
        for cid in f["ids"]:
            c = self.chunks.get(cid)
            if c is None:
                continue
            for t in c["tf"]:
                p = self.postings.get(t)
                if p is not None and cid in p:
                    del p[cid]
                    self.df[t] = self.df[t] - 1
                    if self.df[t] <= 0:
                        del self.df[t]
                        del self.postings[t]
            self.total_len -= c["len"]
            if c["key"] in self.by_key and self.by_key[c["key"]] == cid:
                del self.by_key[c["key"]]
            del self.chunks[cid]
        f["ids"] = []

    def _add_chunk(self, c):
        cid = self.next_id
        self.next_id += 1
        c["id"] = cid
        self.chunks[cid] = c
        for t in c["tf"]:
            p = self.postings.get(t)
            if p is None:
                p = {}
                self.postings[t] = p
            p[cid] = c["tf"][t]
            self.df[t] = self.df.get(t, 0) + 1
        self.total_len += c["len"]
        if c["key"] != "":
            self.by_key[c["key"]] = cid
        return cid

    def _chunk(self, rel, kind, name, qual, line, end, summary, key):
        return {"rel": rel, "kind": kind, "name": name, "qual": qual, "line": line, "end": end,
                "summary": summary, "key": key, "tf": {}, "len": 0.0}

    def _fill(self, c, fields):
        tf = c["tf"]
        total = 0.0
        for f in fields:
            w = FIELD_W[f[0]]
            total += _TOK.add(f[1], tf, w) * w
        c["len"] = total
        return c

    def _code_chunks(self, m):
        out = []
        lines = m.lines
        owned = [0] * (len(lines) + 2)     # lines inside a def or class
        path_text = m.rel.replace("/", " ").replace(".", " ")
        for f in m.functions:
            code = []
            com = []
            lo = f.first
            hi = min(f.end, len(lines))
            for ln in range(lo, hi + 1):
                owned[ln] = 1
                t = lines[ln - 1]
                ct = _comment_text(t)
                if ct != "":
                    com.append(ct)
                    t = t[0:len(t) - len(ct) - 1]
                code.append(t)
            name_text = f.name + " " + f.qualname.replace(".", " ") + " " + f.cls
            summary = f.signature()
            if f.doc_summary() != "":
                summary = summary + " - " + f.doc_summary()
            kind = f.kind()
            c = self._chunk(m.rel, kind, f.name, f.qualname, f.first, f.end, summary, f.key)
            out.append(self._fill(c, [["name", name_text], ["doc", f.doc or ""], ["comment", " ".join(com)],
                                      ["code", "\n".join(code)], ["path", path_text]]))
        for k in m.classes:
            # the class's own lines: up to its first method
            hi = k.end
            for f in m.functions:
                if f.cls == k.name and f.first > k.line and f.first - 1 < hi:
                    hi = f.first - 1
            code = []
            com = []
            for ln in range(k.line, min(hi, len(lines)) + 1):
                owned[ln] = 1
                t = lines[ln - 1]
                ct = _comment_text(t)
                if ct != "":
                    com.append(ct)
                code.append(t)
            summary = "class " + k.name
            if len(k.bases) > 0:
                summary = summary + "(" + ", ".join(k.bases) + ")"
            if k.doc is not None and k.doc.strip() != "":
                summary = summary + " - " + k.doc.strip().split("\n")[0]
            c = self._chunk(m.rel, "class", k.name, k.qualname, k.line, k.end, summary, k.key)
            out.append(self._fill(c, [["name", k.name + " " + " ".join(k.methods)], ["doc", k.doc or ""],
                                      ["comment", " ".join(com)], ["code", "\n".join(code) + " " + " ".join(k.bases)],
                                      ["path", path_text]]))
        # the module: its docstring and top-level lines
        code = []
        com = []
        first = 0
        last = 0
        for ln in range(1, len(lines) + 1):
            if owned[ln] == 1:
                continue
            t = lines[ln - 1]
            if t.strip() == "":
                continue
            if first == 0:
                first = ln
            last = ln
            ct = _comment_text(t)
            if ct != "":
                com.append(ct)
                t = t[0:len(t) - len(ct) - 1]
            code.append(t)
        if first > 0 or m.doc is not None:
            summary = "module " + m.name
            if m.doc is not None and m.doc.strip() != "":
                summary = summary + " - " + m.doc.strip().split("\n")[0]
            c = self._chunk(m.rel, "module", m.short, m.name, max(first, 1), max(last, 1), summary, m.top.key)
            out.append(self._fill(c, [["name", m.short], ["doc", m.doc or ""], ["comment", " ".join(com)],
                                      ["code", "\n".join(code)], ["path", path_text]]))
        return out

    def _text_chunks(self, rel, text):
        """A document: one chunk per heading section (Markdown), else per
        paragraph group of up to 30 lines."""
        out = []
        lines = text.split("\n")
        path_text = rel.replace("/", " ").replace(".", " ")
        start = 1
        title = os.path.basename(rel)
        buf = []
        md = rel.endswith(".md") or rel.endswith(".rst")

        def flush(end_line):
            if len(buf) == 0 or "".join(buf).strip() == "":
                return
            c = self._chunk(rel, "section", title, title, start, end_line, title, "")
            out.append(self._fill(c, [["name", title], ["doc", "\n".join(buf)], ["path", path_text]]))

        for i in range(len(lines)):
            ln = lines[i]
            is_head = md and ln.startswith("#")
            if is_head or (not md and len(buf) >= 30 and ln.strip() == ""):
                flush(i)
                buf = []
                start = i + 1
                if is_head:
                    title = ln.lstrip("#").strip()
            buf.append(ln)
        flush(len(lines))
        return out

    # ── searching ────────────────────────────────────────────────────────────
    def avgdl(self):
        n = len(self.chunks)
        if n == 0:
            return 1.0
        return max(self.total_len / n, 1.0)

    def idf(self, t):
        n = len(self.chunks)
        df = self.df.get(t, 0)
        return math.log(1.0 + (n - df + 0.5) / (df + 0.5))

    def score_terms(self, qts):
        scores = {}
        avg = self.avgdl()
        uniq = []
        for t in qts:
            if t not in uniq:
                uniq.append(t)
        for t in uniq:
            p = self.postings.get(t)
            if p is None:
                continue
            w = self.idf(t)
            for cid in p:
                tf = p[cid]
                dl = self.chunks[cid]["len"]
                s = w * (tf * (K1 + 1.0)) / (tf + K1 * (1.0 - B + B * dl / avg))
                scores[cid] = scores.get(cid, 0.0) + s
        return scores

    def search(self, query, k=5, kinds=None):
        """The k best chunks for a query, best first, as Hits."""
        qts = query_terms(query)
        base = self.score_terms(qts)
        if len(base) == 0:
            return []
        raw_words = set(w.lower() for w in _WORD_RE.findall(query))
        qset = set(qts)
        final = {}
        boosts = {}
        for cid in base:
            c = self.chunks[cid]
            s = base[cid]
            bl = []
            nm = c["name"].lower()
            if c["kind"] != "section" and c["kind"] != "module":
                parts = _TOK.parts(c["name"])
                defines = nm in raw_words or (len(parts) > 0 and all(p in qset for p in parts))
                if defines:
                    s = s * DEF_BOOST
                    bl.append("defines " + c["name"])
            final[cid] = s
            boosts[cid] = bl
        # one step of propagation over the call graph
        graph = self.model.call_graph() if len(self.model.modules) > 0 else {}
        rev = {}
        for a in graph:
            for b2 in graph[a]:
                lst = rev.get(b2)
                if lst is None:
                    lst = []
                    rev[b2] = lst
                lst.append(a)
        prop = {}
        for cid in final:
            key = self.chunks[cid]["key"]
            if key == "":
                continue
            for nk in graph.get(key, []) + rev.get(key, []):
                nid = self.by_key.get(nk)
                if nid is None or nid == cid:
                    continue
                share = GRAPH_SHARE * final[cid]
                if share > prop.get(nid, [0.0, ""])[0]:
                    prop[nid] = [share, self.chunks[cid]["name"]]
        for nid in prop:
            if nid not in final:
                final[nid] = 0.0
                boosts[nid] = []
                base[nid] = 0.0
            final[nid] = final[nid] + prop[nid][0]
            boosts[nid].append("call-graph neighbour of " + prop[nid][1])
        ids = []
        for cid in final:
            if kinds is None or self.chunks[cid]["kind"] in kinds:
                ids.append(cid)
        ids = sorted(ids, key=lambda i: (-round(final[i], 9), self.chunks[i]["rel"], self.chunks[i]["line"]))
        out = []
        for cid in ids[0:k]:
            h = Hit(self.chunks[cid], final[cid], base[cid])
            h.boosts = boosts[cid]
            self._snippet(h, qset)
            out.append(h)
        return out

    def _lines_of(self, rel):
        m = self.model.modules.get(rel)
        if m is not None:
            return m.lines
        p = os.path.join(self.root, rel)
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                return fh.read().split("\n")
        except OSError:
            return []

    def _snippet(self, h, qset):
        lines = self._lines_of(h.rel)
        best = -1
        best_n = 0
        lo = max(h.line, 1)
        hi = min(h.end, len(lines))
        for ln in range(lo, hi + 1):
            n = 0
            for t in terms_of(lines[ln - 1]):
                if t in qset:
                    n += 1
            if n > best_n:
                best_n = n
                best = ln
        if best < 0:
            best = lo
        h.snippet_line = best
        if best >= 1 and best <= len(lines):
            h.snippet = lines[best - 1].strip()

    # ── persistence ──────────────────────────────────────────────────────────
    def to_json(self):
        files = {}
        for rel in sorted(self.files):
            f = self.files[rel]
            cs = []
            for cid in f["ids"]:
                c = self.chunks[cid]
                cs.append([c["kind"], c["name"], c["qual"], c["line"], c["end"], c["summary"], c["key"], c["len"], c["tf"]])
            files[rel] = {"mtime": f["mtime"], "chunks": cs}
        return {"version": INDEX_VERSION, "root": self.root, "exts": self.exts, "files": files}

    def save(self, path):
        d = os.path.dirname(path)
        if d != "" and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(self.to_json()))
        os.replace(tmp, path)
        return path

    @staticmethod
    def from_json(d):
        if d.get("version") != INDEX_VERSION:
            raise ValueError("not a NyxAI index (version " + str(d.get("version")) + ")")
        idx = WorkspaceIndex(d["root"], d["exts"])
        for rel in sorted(d["files"]):
            f = d["files"][rel]
            ids = []
            for cs in f["chunks"]:
                c = idx._chunk(rel, cs[0], cs[1], cs[2], cs[3], cs[4], cs[5], cs[6])
                c["len"] = cs[7]
                c["tf"] = cs[8]
                ids.append(idx._add_chunk(c))
            idx.files[rel] = {"mtime": f["mtime"], "ids": ids}
            # the program model is rebuilt from the sources (the native
            # parser is fast); a file gone or changed is left to refresh()
            p = os.path.join(idx.root, rel)
            if (rel.endswith(".ny") or rel.endswith(".py")) and os.path.isfile(p) and file_mtime(p) == f["mtime"]:
                try:
                    idx.model.add_file(p)
                except OSError:
                    pass
        return idx

    @staticmethod
    def load(path):
        with open(path, encoding="utf-8") as fh:
            return WorkspaceIndex.from_json(json.loads(fh.read()))

    def refresh(self, max_files=2000):
        """Brings a loaded index up to date with the disk: changed and new
        files re-indexed, deleted ones dropped. [changed, added, removed]."""
        seen = set()
        changed = 0
        added = 0
        for rel in fs_list_files(self.root, max_files, [".git", "node_modules", "build", "__pycache__", ".nython"]):
            if not self.wants(rel):
                continue
            seen.add(rel)
            p = os.path.join(self.root, rel)
            f = self.files.get(rel)
            if f is None:
                self.update_file(p)
                added += 1
            elif f["mtime"] != file_mtime(p):
                self.update_file(p)
                changed += 1
        removed = 0
        for rel in sorted(self.files):
            if rel not in seen:
                self.remove_file(os.path.join(self.root, rel))
                removed += 1
        return [changed, added, removed]

    def stats(self):
        return {"files": len(self.files), "chunks": len(self.chunks), "terms": len(self.postings),
                "avgdl": round(self.avgdl(), 2)}

