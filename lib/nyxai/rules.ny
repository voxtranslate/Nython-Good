# nython: module    (import it by name: it runs in a module scope of its own)
# lib/nyxai/rules.ny - a forward-chaining rule engine: facts, rules with
# variables, negation, explanations. NyxAI's reasoning part (it replaced
# lib/aiagent.ny's substring matching, round 82).
#
#     from nyxai.rules import RuleEngine
#     eng = RuleEngine()
#     eng.fact("calls", "main", "parse")
#     eng.fact("calls", "parse", "lex")
#     eng.rule("reach", [("calls", "?a", "?b")], [("reaches", "?a", "?b")])
#     eng.rule("reach*", [("reaches", "?a", "?b"), ("calls", "?b", "?c")],
#              [("reaches", "?a", "?c")])
#     eng.run()                                   # 3 new facts
#     eng.query(("reaches", "main", "?x"))        # [{"?x": "parse"}, {"?x": "lex"}]
#     eng.why(("reaches", "main", "lex"))         # the derivation, as text lines
#
# Facts are tuples of values (strings, numbers, booleans, None); the first
# element is the predicate. A pattern is a tuple whose strings starting with
# "?" are variables ("?" or "?_" alone matches anything without binding).
# A rule's conditions are patterns, joined left to right; a condition
# ("not", pred, args...) holds when no fact matches it under the bindings so
# far; ("test", fn) calls fn(bindings) and holds when it returns true. A
# conclusion is a pattern (instantiated with the bindings) or a function
# fn(bindings, engine) called for its effect. Rules may be recursive.
#
# How it runs (after Forgy's Rete, Artificial Intelligence 19, 1982, at a
# small scale): facts are kept in alpha memories, indexed by predicate and by
# (predicate, position, value); a rule is a chain of joins. A new fact is
# matched only against the conditions with its predicate, and the rest of
# the rule is joined against working memory from there - the semi-naive
# ("delta") evaluation of Datalog engines, so a fact is never re-derived from
# scratch. Negation is stratified (Apt, Blair & Walker 1988): rules are
# grouped into strata so that a predicate a rule negates is complete before
# the rule runs; a program whose negations form a cycle is refused
# (ValueError). Every derived fact remembers the rule and premises that first
# produced it, so why() can explain a conclusion - the "how?" explanations of
# expert systems (MYCIN, Shortliffe 1976).
#
# Not here: retraction of facts (the engine is monotonic; reset() starts
# over), salience/conflict-resolution strategies beyond rule order, and
# Rete's sharing of join nodes between rules.

__all__ = ["RuleEngine", "Rule", "is_var"]


def is_var(x):
    return isinstance(x, str) and len(x) > 0 and x[0] == "?"


def _wild(x):
    return x == "?" or x == "?_"


class Rule:
    def __init__(self, name, conditions, conclusions, index):
        self.name = name
        self.conditions = [tuple(c) if not callable(c) else c for c in conditions]
        self.conclusions = conclusions
        self.index = index
        self.stratum = 0
        self.fired = 0

    def positive(self):
        out = []
        for i in range(len(self.conditions)):
            c = self.conditions[i]
            if isinstance(c, tuple) and len(c) > 0 and c[0] != "not" and c[0] != "test":
                out.append(i)
        return out

    def __repr__(self):
        return "Rule(" + repr(self.name) + ")"


class RuleEngine:
    def __init__(self):
        self.rules = []
        self.reset()

    def reset(self):
        self.facts = {}           # fact -> derivation ([rule name, premises] or None for a given fact)
        self.order = []           # facts in the order they were added
        self.seq = {}             # fact -> its position in order
        self.by_pred = {}         # predicate -> [facts]
        self.by_pos = {}          # (predicate, position, value) -> [facts]
        self._pending = []
        self.derived = 0

    # ── facts ────────────────────────────────────────────────────────────────
    def fact(self, *parts):
        return self.assert_fact(tuple(parts), None)

    def assert_fact(self, f, why=None):
        f = tuple(f)
        if len(f) == 0:
            raise ValueError("a fact needs a predicate")
        if f in self.facts:
            return False
        self.facts[f] = why
        self.seq[f] = len(self.order)
        self.order.append(f)
        p = f[0]
        lst = self.by_pred.get(p)
        if lst is None:
            lst = []
            self.by_pred[p] = lst
        lst.append(f)
        for i in range(1, len(f)):
            k = (p, i, f[i])
            l2 = self.by_pos.get(k)
            if l2 is None:
                l2 = []
                self.by_pos[k] = l2
            l2.append(f)
        self._pending.append(f)
        if why is not None:
            self.derived += 1
        return True

    def has(self, *parts):
        return tuple(parts) in self.facts

    def all_facts(self, pred=None):
        if pred is None:
            return list(self.order)
        return list(self.by_pred.get(pred, []))

    # ── rules ────────────────────────────────────────────────────────────────
    def rule(self, name, conditions, conclusions):
        r = Rule(name, conditions, conclusions, len(self.rules))
        if len(r.positive()) == 0:
            raise ValueError("rule " + repr(name) + " needs a positive condition")
        self.rules.append(r)
        self._strata_ok = False
        return r

    def _heads(self, r):
        out = []
        for c in r.conclusions:
            if isinstance(c, tuple) and len(c) > 0:
                out.append(c[0])
        return out

    # Stratification: a rule negating predicate q goes above every rule that
    # concludes q; positive dependencies keep rules in the same or a higher
    # stratum.
    def _stratify(self):
        for r in self.rules:
            r.stratum = 0
        changed = True
        rounds = 0
        n = len(self.rules)
        while changed:
            changed = False
            rounds += 1
            if rounds > n + 2:
                raise ValueError("the rules' negations are not stratified (a predicate depends on its own negation)")
            for r in self.rules:
                for c in r.conditions:
                    if not isinstance(c, tuple) or len(c) == 0 or c[0] == "test":
                        continue
                    neg = c[0] == "not"
                    pred = c[1] if neg else c[0]
                    for s in self.rules:
                        if pred in self._heads(s):
                            need = s.stratum + 1 if neg else s.stratum
                            if r.stratum < need:
                                r.stratum = need
                                changed = True
        self._strata_ok = True

    # ── matching ─────────────────────────────────────────────────────────────
    def _subst(self, x, b):
        if is_var(x) and not _wild(x):
            return b.get(x, x)
        return x

    def _unify(self, pat, f, b):
        if len(pat) != len(f):
            return None
        out = b
        copied = False
        for i in range(len(pat)):
            p = pat[i]
            if is_var(p):
                if _wild(p):
                    continue
                if p in out:
                    if out[p] != f[i]:
                        return None
                else:
                    if not copied:
                        out = dict(out)
                        copied = True
                    out[p] = f[i]
            elif p != f[i]:
                return None
        if not copied:
            out = dict(out)
        return out

    # the facts that could match a pattern under bindings b (the smallest
    # alpha memory: by a bound position, else by predicate)
    def _candidates(self, pat, b):
        best = None
        for i in range(1, len(pat)):
            v = pat[i]
            if is_var(v):
                if _wild(v) or v not in b:
                    continue
                v = b[v]
            lst = self.by_pos.get((pat[0], i, v))
            if lst is None:
                return []
            if best is None or len(lst) < len(best):
                best = lst
        if best is None:
            best = self.by_pred.get(pat[0], [])
        return best

    def _holds_not(self, cond, b):
        pat = tuple(self._subst(x, b) for x in cond[1:])
        for f in list(self._candidates(pat, b)):
            if self._unify(pat, f, b) is not None:
                return False
        return True

    # Joins conditions [i:] of r under bindings b, the delta fact (sequence
    # number s) having matched condition ci: an earlier condition joins only
    # facts older than it, a later one facts no newer - so each combination
    # of facts is joined exactly once (semi-naive evaluation).
    def _join(self, r, i, ci, s, b, prem, out):
        conds = r.conditions
        if i >= len(conds):
            out.append([b, prem])
            return
        if i == ci:
            self._join(r, i + 1, ci, s, b, prem, out)
            return
        c = conds[i]
        if callable(c):
            if c(b):
                self._join(r, i + 1, ci, s, b, prem, out)
            return
        if c[0] == "test":
            if c[1](b):
                self._join(r, i + 1, ci, s, b, prem, out)
            return
        if c[0] == "not":
            if self._holds_not(c, b):
                self._join(r, i + 1, ci, s, b, prem, out)
            return
        seq = self.seq
        for f in list(self._candidates(c, b)):
            q = seq[f]
            if (i < ci and q >= s) or (i > ci and q > s):
                continue
            nb = self._unify(c, f, b)
            if nb is not None:
                self._join(r, i + 1, ci, s, nb, prem + [f], out)

    def _fire(self, r, b, prem):
        new = 0
        for c in r.conclusions:
            if callable(c):
                c(b, self)
                continue
            f = tuple(self._subst(x, b) for x in c)
            for x in f:
                if is_var(x) and not _wild(x):
                    raise ValueError("rule " + repr(r.name) + ": " + x + " is not bound in its conclusion")
            if self.assert_fact(f, [r.name, prem]):
                new += 1
        r.fired += 1
        return new

    # Runs the rules to a fixpoint, stratum by stratum; returns how many
    # facts were derived.
    def run(self, limit=1000000):
        if not getattr(self, "_strata_ok", False):
            self._stratify()
        strata = sorted(set(r.stratum for r in self.rules))
        before = self.derived
        steps = 0
        for s in strata:
            rules = [r for r in self.rules if r.stratum == s]
            # this stratum has not seen any fact yet: every fact is new to it
            queue = list(self.order)
            self._pending = []
            qi = 0
            while qi < len(queue):
                f = queue[qi]
                qi += 1
                for r in rules:
                    conds = r.conditions
                    for ci in r.positive():
                        c = conds[ci]
                        if c[0] != f[0] or len(c) != len(f):
                            continue
                        b = self._unify(c, f, {})
                        if b is None:
                            continue
                        matches = []
                        self._join(r, 0, ci, self.seq[f], b, [f], matches)
                        for m in matches:
                            prem = m[1]
                            # premises in condition order: the delta fact first
                            # in the list, put it back where its condition is
                            ordered = self._order_premises(r, ci, prem)
                            self._fire(r, m[0], ordered)
                            steps += 1
                            if steps > limit:
                                raise RuntimeError("rule engine: more than " + str(limit) + " firings")
                if len(self._pending) > 0:
                    queue.extend(self._pending)
                    self._pending = []
        return self.derived - before

    def _order_premises(self, r, ci, prem):
        # prem: [delta fact, then the others in condition order]
        out = []
        k = 1
        for i in r.positive():
            if i == ci:
                out.append(prem[0])
            elif k < len(prem):
                out.append(prem[k])
                k += 1
        return out

    # ── questions ────────────────────────────────────────────────────────────
    def query(self, pattern):
        pat = tuple(pattern)
        out = []
        seen = set()
        for f in list(self._candidates(pat, {})):
            b = self._unify(pat, f, {})
            if b is not None:
                key = tuple(sorted(b.items()))
                if key not in seen:
                    seen.add(key)
                    out.append(b)
        return out

    def values(self, pattern, var):
        return [b[var] for b in self.query(pattern)]

    def derivation(self, f):
        return self.facts.get(tuple(f))

    # The proof of a fact, as indented lines: each derived fact with the rule
    # that produced it, then its premises.
    def why(self, f, depth=0, seen=None, limit=40):
        f = tuple(f)
        if seen is None:
            seen = set()
        lines = []
        pad = "  " * depth
        if f not in self.facts:
            return [pad + _show(f) + " is not known"]
        d = self.facts[f]
        if d is None:
            return [pad + _show(f) + "  (given)"]
        if f in seen or len(seen) > limit:
            return [pad + _show(f) + "  (see above)"]
        seen.add(f)
        lines.append(pad + _show(f) + "  by rule " + repr(d[0]) + ", because")
        for p in d[1]:
            lines.extend(self.why(p, depth + 1, seen, limit))
        return lines

    def stats(self):
        return {"facts": len(self.order), "derived": self.derived, "rules": len(self.rules),
                "firings": sum(r.fired for r in self.rules)}


def _show(f):
    return str(f[0]) + "(" + ", ".join(str(x) for x in f[1:]) + ")"
