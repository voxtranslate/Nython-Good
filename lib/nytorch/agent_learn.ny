# ─── Online-learning coding agent ────────────────────────────────────────────
# An agent that learns while people are coding, in the literal sense: every
# observed piece of source code produces one real gradient-descent update
# (via lib/nytorch/autograd.ny's Variable/AdamVar), not a deferred batch
# retrain. Grounded in the real language, not an invented toy grammar: the
# token categories below come from the same keyword vocabulary the shipped
# syntax highlighter (ide_editor.ny's SyntaxHighlighter) and the real lexer
# (IToken.hpp) use, and tokenize_categories() below follows the same
# char-scan approach that highlighter already uses, kept self-contained here
# rather than imported so nytorch does not gain a GUI dependency.
#
# What it learns: a tiny next-token-CATEGORY language model (keyword /
# identifier / number / string / operator / punct) — small enough to run
# without real ND tensors, but a genuine sequence model, trained online, that
# gets measurably better at predicting Nython's own syntactic structure the
# more real source it observes. See examples/vm_audit40.ny for the evidence:
# perplexity on a held-out file drops as more OTHER files are learned from
# first — the actual signature of learning, not memorising a fixed answer.
#
#   var agent = CodingAgent("demo", "/tmp/ny_agent", 12, 7)
#   agent.observe_file("examples/some_file.ny")
#   agent.suggest_next("keyword")     # -> most likely category after a keyword
#   agent.perplexity_on(some_text)    # lower is better, evaluated without training

# ── real vocabulary, not an invented one ─────────────────────────────────────
# The same keyword list ide_editor.ny's SyntaxHighlighter ships with —
# duplicated rather than imported (nytorch has no business depending on GUI
# code), but sourced from the same real language, not reinvented.
import "lib/nytorch/core.ny"

def _ny_keywords():
    return ["def", "class", "if", "elif", "else", "while", "for", "in",
            "return", "import", "var", "const", "let", "not", "and", "or",
            "xor", "true", "false", "none", "print", "self", "do", "end",
            "break", "continue", "try", "except", "catch", "finally",
            "raise", "throw", "with", "as", "pass", "lambda", "yield",
            "from", "global", "del", "assert", "enum", "interface",
            "struct", "namespace", "module", "new", "is", "instanceof",
            "switch", "case", "default", "async", "await", "static",
            "super", "private", "protected", "public", "extends",
            "implements", "inherits", "use", "unless", "repeat", "until",
            "loop", "delete", "sizeof", "typeof", "execute", "block",
            "package", "fn", "fun", "function"]

var KIND_VOCAB = ["keyword", "identifier", "number", "string", "operator", "punct"]
var KIND_INDEX = {"keyword": 0, "identifier": 1, "number": 2, "string": 3, "operator": 4, "punct": 5}
var KIND_COUNT = 6

def _in_keywords(w):
    var kws = _ny_keywords()
    var i = 0
    while i < len(kws):
        if kws[i] == w:
            return true
        i = i + 1
    return false

def _is_id_char(ch):
    if ch >= "a" and ch <= "z":
        return true
    if ch >= "A" and ch <= "Z":
        return true
    if ch >= "0" and ch <= "9":
        return true
    return ch == "_"

def _is_op_char(ch):
    if ch == "+": return true
    if ch == "-": return true
    if ch == "*": return true
    if ch == "/": return true
    if ch == "%": return true
    if ch == "=": return true
    if ch == "<": return true
    if ch == ">": return true
    if ch == "!": return true
    if ch == "&": return true
    if ch == "|": return true
    if ch == "^": return true
    if ch == "~": return true
    return false

# A real (if coarse) tokeniser: comments and whitespace are skipped, string
# literals and numbers are scanned as whole spans, identifiers are checked
# against the real keyword list, everything else falls to operator/punct.
# Returns category strings, not the underlying text — the language model
# below only ever needs the category sequence.
def tokenize_categories(line):
    var cats = []
    var n = len(line)
    var i = 0
    while i < n:
        var ch = line[i:i + 1]
        if ch == " " or ch == "\t":
            i = i + 1
        elif ch == "#":
            i = n
        elif ch == "\"" or ch == "'":
            var quote = ch
            var j = i + 1
            while j < n and line[j:j + 1] != quote:
                j = j + 1
            if j < n:
                j = j + 1
            cats.append("string")
            i = j
        elif ch >= "0" and ch <= "9":
            var j2 = i
            while j2 < n and ((line[j2:j2 + 1] >= "0" and line[j2:j2 + 1] <= "9") or line[j2:j2 + 1] == "."):
                j2 = j2 + 1
            cats.append("number")
            i = j2
        elif _is_id_char(ch) and not (ch >= "0" and ch <= "9"):
            var j3 = i
            while j3 < n and _is_id_char(line[j3:j3 + 1]):
                j3 = j3 + 1
            var word = line[i:j3]
            if _in_keywords(word):
                cats.append("keyword")
            else:
                cats.append("identifier")
            i = j3
        elif _is_op_char(ch):
            cats.append("operator")
            i = i + 1
        else:
            cats.append("punct")
            i = i + 1
    return cats


# ── a tiny online sequence model ─────────────────────────────────────────────
# Predicts the next token CATEGORY from the current one. Not a real language
# model in the LLM sense - a single-hidden-layer MLP over a 6-way categorical
# vocabulary is deliberately small - but it is a genuine, trained,
# gradient-descent-updated model of Nython's own syntactic structure, which
# nothing in nytorch had before.
class TokenLanguageModel:
    def __init__(self, hidden, seed):
        self.n_kinds = KIND_COUNT
        self.model = MLPVar([self.n_kinds, hidden, self.n_kinds], seed)
        self.opt = AdamVar(self.model.parameters(), 0.02, 0.9, 0.999, 0.00000001)
        self.updates = 0

    def _onehot(self, idx):
        var v = zeros(self.n_kinds)
        v[idx] = 1.0
        return Variable(tensor(v), false)

    # One real gradient-descent step given a (previous, next) category pair
    # — "learns on the fly" in the literal sense: every call is a live
    # update, not something queued for a later batch retrain.
    def observe_pair(self, prev_idx, next_idx):
        self.opt.zero_grad()
        var x = self._onehot(prev_idx)
        var logits = self.model.forward(x)
        var loss = softmax_cross_entropy(logits, next_idx)
        loss.backward()
        self.opt.step()
        self.updates = self.updates + 1
        return loss.data

    def observe_sequence(self, indices):
        var total = 0.0
        var i = 0
        while i < len(indices) - 1:
            total = total + self.observe_pair(indices[i], indices[i + 1])
            i = i + 1
        return total

    def predict_next(self, prev_idx):
        var x = self._onehot(prev_idx)
        var logits = self.model.forward(x)
        var best = 0
        var bi = 1
        while bi < self.n_kinds:
            if logits.data[bi] > logits.data[best]:
                best = bi
            bi = bi + 1
        return best

    # Average cross-entropy over a sequence WITHOUT updating any weight —
    # the standard way to check whether the model generalises to text it
    # has not trained on, rather than only memorising what it has already
    # seen.
    def evaluate(self, indices):
        var total = 0.0
        var n = 0
        var i = 0
        while i < len(indices) - 1:
            var x = self._onehot(indices[i])
            var logits = self.model.forward(x)
            var loss = softmax_cross_entropy(logits, indices[i + 1])
            total = total + loss.data
            n = n + 1
            i = i + 1
        if n == 0:
            return 0.0
        return total / n


# ── persistent per-agent memory ──────────────────────────────────────────────
# Deliberately NOT named KnowledgeBase: that name is independently defined
# three different, incompatible ways across nytorch's own submodules
# (compute.ny, memory.ny, storage.ny — a fourth, also incompatible version
# lives in lib/aiagent.ny) — plain-text import order picks whichever was
# imported last, and a caller written against a DIFFERENT one of those four
# silently gets `none` back from every call instead of an error, since a
# missing method resolves that way here rather than raising. Confirmed by
# probe before writing this note. Ten class names collide this way across
# nytorch/ alone; worth its own dedicated rename-and-fix pass (see
# HANDOFF.md), not attempted here — this file just does not add to the
# pile.
class AgentKnowledge:
    def __init__(self, store_path):
        self.store = store_path
        fs_mkdirs(path_dirname(store_path))

    def remember(self, key, value):
        return kv_set(self.store, key, value)

    def recall(self, key):
        return kv_get(self.store, key)

    def has(self, key):
        return kv_get(self.store, key) != none


# ── the agent itself ─────────────────────────────────────────────────────────
class CodingAgent:
    def __init__(self, agent_id, storage_dir, hidden, seed):
        self.agent_id = agent_id
        self.model = TokenLanguageModel(hidden, seed)
        self.kb = AgentKnowledge(storage_dir + "/" + agent_id + "/agent_kb.kv")
        self.files_seen = 0
        self.tokens_seen = 0

    def _categorize(self, text):
        var lines = string_split(text, "\n")
        var cats = []
        var i = 0
        while i < len(lines):
            cats = cats + tokenize_categories(lines[i])
            i = i + 1
        var idxs = []
        var j = 0
        while j < len(cats):
            idxs.append(KIND_INDEX[cats[j]])
            j = j + 1
        return idxs

    # Trains on one piece of real source, one gradient step per adjacent
    # token-category pair — exactly the granularity a user typing would
    # produce it at.
    def observe_source(self, text):
        var idxs = self._categorize(text)
        var loss_sum = self.model.observe_sequence(idxs)
        self.files_seen = self.files_seen + 1
        self.tokens_seen = self.tokens_seen + len(idxs)
        self.kb.remember("files_seen", str(self.files_seen))
        self.kb.remember("tokens_seen", str(self.tokens_seen))
        return loss_sum

    def observe_file(self, path):
        var text = read_file(path)
        if text == none:
            return 0.0
        return self.observe_source(text)

    def suggest_next(self, prev_category):
        if not KIND_INDEX.has_key(prev_category):
            return "identifier"
        var idx = KIND_INDEX[prev_category]
        var best = self.model.predict_next(idx)
        return KIND_VOCAB[best]

    # Perplexity-style score (average cross-entropy, no training) on text
    # the agent has not been trained on — the actual measure of whether it
    # learned something general about Nython's structure.
    def perplexity_on(self, text):
        var idxs = self._categorize(text)
        return self.model.evaluate(idxs)



# ── the completion ranker (round 82) ─────────────────────────────────────────
# The model above, put to work: lib/aiagent.ny's NyxAgent and the IDE re-rank
# the editor's completion list with it, trained on the user's own workspace.
#
# CodeTokenModel is an online n-gram model of code tokens - Hindle, Barr, Su,
# Gabel & Devanbu, "On the Naturalness of Software" (ICSE 2012), showed code
# is repetitive enough that n-gram models predict the next token well - with
# Witten-Bell interpolation of trigram, bigram and unigram estimates, and a
# cache of the most recent identifiers (Tu, Su & Devanbu, "On the Localness
# of Software", FSE 2014: what was just written is likely again). Every
# observed token updates the counts at once (it learns as code is read or
# typed). CompletionRanker combines it with the category MLP above
# (TokenLanguageModel: what kind of token follows this kind, trained by
# gradient steps on the same text) and re-orders candidates: a candidate
# that starts with what was typed stays ahead of a fuzzy match, and within
# those the model decides. completion_mrr() measures it as the mean
# reciprocal rank of the token the user went on to type, before and after
# training (vm_audit105).

var _NY_TOKEN_RE = none

def code_tokens(text):
    """[[text, category], ...] of a source text: strings and numbers whole,
    comments dropped (the categories above: keyword, identifier, number,
    string, operator, punct)."""
    import re
    global _NY_TOKEN_RE
    if _NY_TOKEN_RE == none:
        _NY_TOKEN_RE = re.compile(r'"""[\s\S]*?"""|' + r"'''[\s\S]*?'''|" + r'"(?:[^"\\\n]|\\.)*"|' + r"'(?:[^'\\\n]|\\.)*'|" + r"#[^\n]*|[A-Za-z_][A-Za-z0-9_]*|[0-9]+(?:\.[0-9]+)?|==|!=|<=|>=|\*\*|//|->|\+=|-=|\*=|/=|[-+*/%=<>!&|^~@]|[()\[\]{}:,.;]")
    var out = []
    for t in _NY_TOKEN_RE.findall(text):
        var c = t[0:1]
        if c == "#":
            continue
        if c == "\"" or c == "'":
            out.append([t, "string"])
        elif c >= "0" and c <= "9":
            out.append([t, "number"])
        elif _is_id_char(c):
            if _in_keywords(t):
                out.append([t, "keyword"])
            else:
                out.append([t, "identifier"])
        elif _is_op_char(c):
            out.append([t, "operator"])
        else:
            out.append([t, "punct"])
    return out


def _code_token_key(tc):
    if tc[1] == "string":
        return "<str>"
    if tc[1] == "number":
        return "<num>"
    return tc[0]


class CodeTokenModel:
    def __init__(self, cache_size=400):
        self.uni = {}
        self.bi = {}          # prev -> {tok: count}
        self.bi_n = {}        # prev -> how many tokens followed it
        self.tri = {}         # prev2 + " " + prev -> {tok: count}
        self.tri_n = {}
        self.total = 0
        self.cache = []       # the most recent identifiers
        self.cache_counts = {}
        self.cache_size = cache_size
        self.lam_cache = 0.15

    def _bump(self, table, totals, key, tok):
        var d = table.get(key)
        if d == none:
            d = {}
            table[key] = d
        d[tok] = d.get(tok, 0) + 1
        totals[key] = totals.get(key, 0) + 1

    def observe_tokens(self, toks):
        var p2 = "<s>"
        var p1 = "<s>"
        for tc in toks:
            var t = _code_token_key(tc)
            self.uni[t] = self.uni.get(t, 0) + 1
            self.total = self.total + 1
            self._bump(self.bi, self.bi_n, p1, t)
            self._bump(self.tri, self.tri_n, p2 + " " + p1, t)
            if tc[1] == "identifier":
                self.remember(t)
            p2 = p1
            p1 = t
        return len(toks)

    def remember(self, t):
        self.cache.append(t)
        self.cache_counts[t] = self.cache_counts.get(t, 0) + 1
        if len(self.cache) > self.cache_size:
            var old = self.cache.pop(0)
            var n = self.cache_counts[old] - 1
            if n <= 0:
                del self.cache_counts[old]
            else:
                self.cache_counts[old] = n

    # Witten-Bell: (c(h, w) + T(h) P_lower(w)) / (c(h) + T(h))
    def _wb(self, d, n, tok, lower):
        if d == none:
            return lower
        var types = len(d)
        return (d.get(tok, 0) + types * lower) / (n + types)

    def prob(self, tok, p2, p1):
        var v = len(self.uni) + 1
        var p_uni = (self.uni.get(tok, 0) + 1.0) / (self.total + v)
        var p_bi = self._wb(self.bi.get(p1), self.bi_n.get(p1, 0), tok, p_uni)
        var h = p2 + " " + p1
        var p = self._wb(self.tri.get(h), self.tri_n.get(h, 0), tok, p_bi)
        if len(self.cache) > 0:
            var pc = self.cache_counts.get(tok, 0) / len(self.cache)
            p = (1.0 - self.lam_cache) * p + self.lam_cache * pc
        return p


class CompletionRanker:
    # The category MLP has 36 transitions to learn: a sample of each file's
    # pairs (max_category_pairs) and a total budget (max_category_steps) keep
    # its gradient steps - the slow part - from growing with the workspace.
    def __init__(self, hidden=8, seed=11, category_model=true, max_category_pairs=24, max_category_steps=240):
        self.ngram = CodeTokenModel()
        self.cat = none
        if category_model:
            self.cat = TokenLanguageModel(hidden, seed)
        self.max_category_pairs = max_category_pairs
        self.max_category_steps = max_category_steps
        self.files = 0
        self.tokens = 0
        self.cat_steps = 0
        self.gamma = 0.5
        self._cat_probs = none

    def trained(self):
        return self.files > 0

    def observe_source(self, text):
        """Learns from one source text: every token updates the n-gram
        counts; a sample of its category pairs takes gradient steps."""
        var toks = code_tokens(text)
        self.ngram.observe_tokens(toks)
        self.files = self.files + 1
        self.tokens = self.tokens + len(toks)
        if self.cat != none and len(toks) > 1 and self.cat_steps < self.max_category_steps:
            var n = len(toks) - 1
            var step = 1
            if n > self.max_category_pairs:
                step = int(n / self.max_category_pairs)
            var i = 0
            while i < n and self.cat_steps < self.max_category_steps:
                self.cat.observe_pair(KIND_INDEX[toks[i][1]], KIND_INDEX[toks[i + 1][1]])
                self.cat_steps = self.cat_steps + 1
                i = i + step
            self._cat_probs = none
        return len(toks)

    # P(category of the next token | category of the previous one), from the
    # MLP, kept as a 6x6 table until it is trained again
    def category_prob(self, prev_cat, cat):
        if self.cat == none:
            return 1.0
        if self._cat_probs == none:
            import math
            var table = []
            var a = 0
            while a < KIND_COUNT:
                var logits = self.cat.model.forward(self.cat._onehot(a))
                var mx = logits.data[0]
                var j = 1
                while j < KIND_COUNT:
                    if logits.data[j] > mx:
                        mx = logits.data[j]
                    j = j + 1
                var row = []
                var z = 0.0
                j = 0
                while j < KIND_COUNT:
                    var e = math.exp(logits.data[j] - mx)
                    row.append(e)
                    z = z + e
                    j = j + 1
                j = 0
                while j < KIND_COUNT:
                    row[j] = row[j] / z
                    j = j + 1
                table.append(row)
                a = a + 1
            self._cat_probs = table
        return self._cat_probs[KIND_INDEX.get(prev_cat, 1)][KIND_INDEX.get(cat, 1)]

    def context(self, text_before):
        """[prev2, prev1, category of prev1] from the text before the word."""
        var toks = code_tokens(text_before)
        var n = len(toks)
        var p2 = "<s>"
        var p1 = "<s>"
        var c1 = "punct"
        if n >= 1:
            p1 = _code_token_key(toks[n - 1])
            c1 = toks[n - 1][1]
        if n >= 2:
            p2 = _code_token_key(toks[n - 2])
        return [p2, p1, c1]

    def score(self, cand, ctx):
        import math
        var p = self.ngram.prob(cand, ctx[0], ctx[1])
        var cat = "identifier"
        if _in_keywords(cand):
            cat = "keyword"
        return math.log(p) + self.gamma * math.log(max(self.category_prob(ctx[2], cat), 0.000001))

    def rerank(self, names, kinds, ctx, typed=""):
        """The candidates re-ordered: those starting with `typed` (matching
        case first) ahead of fuzzy matches, the model's order within each
        group, the original order breaking ties. [names, kinds]."""
        if not self.trained() or len(names) < 2:
            return [names, kinds]
        var low = typed.lower()
        var keyed = []
        var i = 0
        while i < len(names):
            var nm = names[i]
            var grp = 2
            if typed != "" and nm.startswith(typed):
                grp = 0
            elif typed != "" and nm.lower().startswith(low):
                grp = 1
            keyed.append([grp, -self.score(nm, ctx), i])
            i = i + 1
        keyed = sorted(keyed)
        var on = []
        var ok = []
        for k in keyed:
            on.append(names[k[2]])
            ok.append(kinds[k[2]])
        return [on, ok]


def completion_mrr(ranker, text, base_names, base_kinds, prefix_len=1, min_len=3, use_model=true, limit=60):
    """The mean reciprocal rank of each identifier of `text` in the
    completion list the IDE shows after its first prefix_len characters are
    typed (ac_index_rank over the base names and the text's own words),
    re-ranked by the model or not. [mrr, positions]."""
    var ix = ac_index_new()
    ac_index_set_base(ix, base_names, base_kinds)
    ac_index_scan(ix, string_split(text, "\n"), min_len)
    var toks = code_tokens(text)
    var total = 0.0
    var n = 0
    var p2 = "<s>"
    var p1 = "<s>"
    var c1 = "punct"
    var i = 0
    while i < len(toks):
        var t = toks[i][0]
        var c = toks[i][1]
        if (c == "identifier" or c == "keyword") and len(t) >= min_len:
            var typed = t[0:prefix_len]
            var res = ac_index_rank(ix, typed, limit, typed)
            var names = res[0]
            if use_model:
                names = ranker.rerank(names, res[1], [p2, p1, c1], typed)[0]
            var k = 0
            var rank = 0
            while k < len(names):
                if names[k] == t:
                    rank = k + 1
                    break
                k = k + 1
            if rank > 0:
                total = total + 1.0 / rank
            n = n + 1
        p2 = p1
        p1 = _code_token_key(toks[i])
        c1 = c
        i = i + 1
    if n == 0:
        return [0.0, 0]
    return [total / n, n]
