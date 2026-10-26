# nython: module    (import it by name: it runs in a module scope of its own)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/nypip/pubgrub.ny - version solving by PubGrub (round 87).
#
# Natalie Weizenbaum's PubGrub (2018; Dart's pub, then uv and Poetry):
# conflict-driven clause learning over version sets. The facts are
# incompatibilities - sets of terms that must not all hold ("a 1.0 depends on
# b >=2" is {a 1.0, not b >=2}); unit propagation derives terms from them,
# decisions pick versions, and a conflict is resolved into a new, learned
# incompatibility that names its root cause, and the solver backjumps to
# where that incompatibility derives something new. When the root package
# itself becomes incompatible the requirements are unsatisfiable, and the
# derivation graph of that final incompatibility is the explanation, written
# as pub writes it ("Because a 1.x depends on b>=2 and c depends on b<2, a
# 1.x is incompatible with c.").
#
#     solver = Solver(provider)
#     solution = solver.solve()           # {name: version}, root left out
#     except SolveFailure as e: print(e)  # the derivation, in English
#
# Version sets are bit masks over a package's universe - the candidate
# versions the provider lists, ascending - so set algebra is exact whatever
# the version scheme (PEP 440's pre-release, post-release and local-version
# rules make its specifiers no finite union of intervals). A requirement
# that matches no candidate at all is not a term (its negation would always
# hold): it makes the versions requiring it forbidden outright, an external
# incompatibility explained as "a 2.0 depends on b>=3, which doesn't match
# any versions".
#
# The provider (duck-typed):
#     versions(name)             candidate versions ascending, or None when
#                                the package does not exist
#     dependencies(name, version)
#                                a list of Dependency(name, contains, label)
#                                and Forbidden(label, reason) entries; raises
#                                Unavailable(reason) when the version cannot be
#                                used at all (its metadata unreadable ...)
#     format_version(name, version)  optional: one version in a message
#                                ("==1.0", the default); version_text(name,
#                                version) one in a range (str); display_name
#     preferred(name)            optional: a version to try first (one
#                                already installed, or the lock's)
#     cheap_dependencies(name, version)
#                                optional: the dependencies if they are known
#                                without a download (else None) - used to
#                                merge adjacent versions with the same
#                                dependency into one incompatibility
#
# Written in the subset of Python CPython runs too (tests load it under
# python3).

ROOT = "<root>"


class SolveFailure(Exception):
    """The requirements cannot be satisfied; str() is the explanation."""

    def __init__(self, incompatibility, solver):
        self.incompatibility = incompatibility
        self.message = _Reporter(incompatibility, solver).write()
        Exception.__init__(self, self.message)

    def __str__(self):
        return self.message


class Unavailable(Exception):
    """Raised by a provider when one version cannot be used."""

    def __init__(self, reason):
        Exception.__init__(self, reason)
        self.reason = reason


class Dependency:
    """name depends on: `contains(version)` says which versions of `name`
    satisfy it; `label` is how a message writes it (">=2", "==1.*")."""

    def __init__(self, name, contains, label=""):
        self.name = name
        self.contains = contains
        self.label = label

    def key(self):
        return (self.name, self.label)


class Forbidden:
    """A requirement no version can meet (Requires-Python against another
    Python): the depending versions are forbidden, `reason` says why."""

    def __init__(self, label, reason):
        self.label = label
        self.reason = reason

    def key(self):
        return ("", self.label, self.reason)


# ── version sets ────────────────────────────────────────────────────────────

class Universe:
    """The candidate versions of one package, ascending; `fmt` writes one
    version alone ("==1.0", pub's " 1.0.0"), `bare` one in a range."""

    def __init__(self, name, versions, fmt, bare=str):
        self.name = name
        self.versions = list(versions)
        self.index = {}
        for i, v in enumerate(self.versions):
            self.index[v] = i
        self.full = (1 << len(self.versions)) - 1
        self.fmt = fmt
        self.bare = bare

    def text(self, i):
        return self.bare(self.versions[i])

    def single(self, i):
        return self.fmt(self.versions[i])


class VersionSet:
    def __init__(self, universe, mask, label=None):
        self.u = universe
        self.mask = mask
        self.label = label

    def is_empty(self):
        return self.mask == 0

    def is_any(self):
        return self.mask == self.u.full

    def intersect(self, other):
        m = self.mask & other.mask
        if m == self.mask:
            return self
        if m == other.mask:
            return other
        return VersionSet(self.u, m)

    def union(self, other):
        m = self.mask | other.mask
        if m == self.mask:
            return self
        if m == other.mask:
            return other
        return VersionSet(self.u, m)

    def difference(self, other):
        m = self.mask & ~other.mask
        if m == self.mask:
            return self
        return VersionSet(self.u, m)

    def allows_all(self, other):
        return other.mask & ~self.mask == 0

    def allows_any(self, other):
        return self.mask & other.mask != 0

    def __eq__(self, other):
        return isinstance(other, VersionSet) and self.u is other.u and self.mask == other.mask

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash((self.u.name, self.mask))

    def runs(self):
        out = []
        n = len(self.u.versions)
        i = 0
        while i < n:
            if (self.mask >> i) & 1:
                j = i
                while j + 1 < n and (self.mask >> (j + 1)) & 1:
                    j += 1
                out.append((i, j))
                i = j + 1
            else:
                i += 1
        return out

    def __str__(self):
        # "" for every version, "==1.0" for one, the requirement's own
        # text when the set is the one it made, else ranges between known
        # versions
        if self.label is not None:
            return self.label
        if self.is_any():
            return ""
        n = len(self.u.versions)
        parts = []
        for r in self.runs():
            i, j = r
            if i == j:
                parts.append(self.u.single(i))
            elif i == 0:
                parts.append("<" + self.u.text(j + 1))
            elif j == n - 1:
                parts.append(">=" + self.u.text(i))
            else:
                parts.append(">=" + self.u.text(i) + ",<" + self.u.text(j + 1))
        if not parts:
            return " (no versions)"
        return " | ".join(parts)


class Term:
    """`package in set` (positive) or `not package in set` (negative: the
    package is not selected, or selected at a version outside the set)."""

    def __init__(self, package, vs, positive):
        self.package = package
        self.vs = vs
        self.positive = positive

    def inverse(self):
        return Term(self.package, self.vs, not self.positive)

    def satisfies(self, other):
        return self.package == other.package and self.relation(other) == SUBSET

    def relation(self, other):
        # how this term (as known) relates to `other`: SUBSET when this
        # implies other, DISJOINT when it contradicts it
        if other.positive:
            if self.positive:
                if not self.vs.allows_any(other.vs):
                    return DISJOINT
                if other.vs.allows_all(self.vs):
                    return SUBSET
                return OVERLAPPING
            if self.vs.allows_all(other.vs):
                return DISJOINT
            return OVERLAPPING
        if self.positive:
            if not self.vs.allows_any(other.vs):
                return SUBSET
            if other.vs.allows_all(self.vs):
                return DISJOINT
            return OVERLAPPING
        if self.vs.allows_all(other.vs):
            return SUBSET
        return OVERLAPPING

    def intersect(self, other):
        # None when the intersection is empty
        if self.positive != other.positive:
            pos = self if self.positive else other
            neg = other if self.positive else self
            return _non_empty(pos.package, pos.vs.difference(neg.vs), True)
        if self.positive:
            return _non_empty(self.package, self.vs.intersect(other.vs), True)
        return _non_empty(self.package, self.vs.union(other.vs), False)

    def difference(self, other):
        return self.intersect(other.inverse())

    def __eq__(self, other):
        return (isinstance(other, Term) and self.package == other.package
                and self.positive == other.positive and self.vs == other.vs)

    def __ne__(self, other):
        return not self.__eq__(other)

    def __hash__(self):
        return hash((self.package, self.positive, self.vs.mask))

    def __repr__(self):
        return ("" if self.positive else "not ") + self.package + str(self.vs)


def _non_empty(package, vs, positive):
    if vs.is_empty():
        return None
    return Term(package, vs, positive)


SUBSET = "subset"
DISJOINT = "disjoint"
OVERLAPPING = "overlapping"


# ── incompatibilities ───────────────────────────────────────────────────────

class Cause:
    """Why an incompatibility holds: kind is "root", "dependency",
    "no-versions", "not-found", "unavailable", "forbidden" (a requirement
    nothing meets) or "conflict" (derived from conflict and other)."""

    def __init__(self, kind, detail=None, conflict=None, other=None):
        self.kind = kind
        self.detail = detail
        self.conflict = conflict
        self.other = other


class Incompatibility:
    def __init__(self, terms, cause):
        if len(terms) != 1 and cause.kind == "conflict":
            # the root package is always selected: leave it out of derived
            # incompatibilities (clearer explanations)
            kept = []
            for t in terms:
                if not (t.positive and t.package == ROOT):
                    kept.append(t)
            terms = kept
        if len(terms) == 1 or (len(terms) == 2 and terms[0].package != terms[1].package):
            self.terms = list(terms)
        else:
            # one term per package: their intersection
            merged = {}
            order = []
            for t in terms:
                if t.package in merged:
                    x = merged[t.package].intersect(t)
                    if x is None:
                        # mutually exclusive terms (never derived in practice):
                        # keep the positive one
                        x = merged[t.package] if merged[t.package].positive else t
                    merged[t.package] = x
                else:
                    merged[t.package] = t
                    order.append(t.package)
            self.terms = [merged[p] for p in order]
        self.cause = cause

    def is_failure(self):
        return len(self.terms) == 0 or (len(self.terms) == 1 and self.terms[0].package == ROOT
                                         and self.terms[0].positive)

    def is_derived(self):
        return self.cause.kind == "conflict"

    def __repr__(self):
        return "{" + ", ".join(repr(t) for t in self.terms) + "}"


# ── the partial solution ────────────────────────────────────────────────────

class Assignment(Term):
    def __init__(self, term, level, index, cause):
        Term.__init__(self, term.package, term.vs, term.positive)
        self.level = level
        self.index = index
        self.cause = cause            # None for a decision

    def is_decision(self):
        return self.cause is None


class PartialSolution:
    def __init__(self):
        self.assignments = []
        self.decisions = {}           # package -> version index
        self.positive = {}            # package -> Term
        self.negative = {}            # package -> Term
        self.attempted = 1
        self.backtracking = False

    def decision_level(self):
        # (the root package's decision is level 1)
        return len(self.decisions)

    def decide(self, package, vs, vindex):
        if self.backtracking:
            self.attempted += 1
        self.backtracking = False
        self.decisions[package] = vindex
        self._assign(Assignment(Term(package, VersionSet(vs.u, 1 << vindex), True),
                                self.decision_level(), len(self.assignments), None))

    def derive(self, term, cause):
        self._assign(Assignment(term, self.decision_level(), len(self.assignments), cause))

    def _assign(self, a):
        self.assignments.append(a)
        self._register(a)

    def _register(self, a):
        p = a.package
        old = self.positive.get(p)
        if old is not None:
            x = old.intersect(a)
            self.positive[p] = x if x is not None else Term(p, VersionSet(a.vs.u, 0), True)
            return
        oldneg = self.negative.get(p)
        term = a if oldneg is None else a.intersect(oldneg)
        if term is None:
            term = Term(p, VersionSet(a.vs.u, 0), True)
        if term.positive:
            self.negative.pop(p, None)
            self.positive[p] = term
        else:
            self.negative[p] = term

    def backtrack(self, level):
        self.backtracking = True
        packages = set()
        while self.assignments and self.assignments[-1].level > level:
            removed = self.assignments.pop()
            packages.add(removed.package)
            if removed.is_decision():
                self.decisions.pop(removed.package, None)
        for p in packages:
            self.positive.pop(p, None)
            self.negative.pop(p, None)
        for a in self.assignments:
            if a.package in packages:
                self._register(a)

    def relation(self, term):
        pos = self.positive.get(term.package)
        if pos is not None:
            return pos.relation(term)
        neg = self.negative.get(term.package)
        if neg is None:
            return OVERLAPPING
        return neg.relation(term)

    def satisfies(self, term):
        return self.relation(term) == SUBSET

    def satisfier(self, term):
        acc = None
        for a in self.assignments:
            if a.package != term.package:
                continue
            if acc is None:
                acc = Term(a.package, a.vs, a.positive)
            else:
                x = acc.intersect(a)
                acc = x if x is not None else Term(a.package, VersionSet(a.vs.u, 0), True)
            if acc.satisfies(term):
                return a
        raise RuntimeError("pubgrub: " + repr(term) + " is not satisfied")

    def unsatisfied(self):
        out = []
        for p, t in self.positive.items():
            if p not in self.decisions:
                out.append(t)
        return out


# ── the solver ──────────────────────────────────────────────────────────────

class Solver:
    def __init__(self, provider, root_dependencies):
        """root_dependencies: the requirements, as Dependency/Forbidden
        entries (what the root package depends on)."""
        self.provider = provider
        self.root_deps = list(root_dependencies)
        self.universes = {}
        self.exists = {}
        self.incompat = {}            # package -> [Incompatibility]
        self.solution = PartialSolution()
        self.listed = {}              # (package, dep key) -> [mask, ...] already added
        self.steps = 0

    # names and versions as messages write them
    def display(self, package):
        if package == ROOT:
            return "you"
        f = getattr(self.provider, "display_name", None)
        return f(package) if f is not None else package

    def fmt(self, package):
        f = getattr(self.provider, "format_version", None)
        if f is None:
            return lambda v: "==" + str(v)
        return lambda v: f(package, v)

    def bare(self, package):
        f = getattr(self.provider, "version_text", None)
        if f is None:
            return str
        return lambda v: f(package, v)

    def universe(self, package):
        u = self.universes.get(package)
        if u is None:
            if package == ROOT:
                vs = ["0"]
                self.exists[package] = True
            else:
                vs = self.provider.versions(package)
                self.exists[package] = vs is not None
                if vs is None:
                    vs = []
            u = Universe(package, vs, self.fmt(package), self.bare(package))
            self.universes[package] = u
        return u

    def set_of(self, dep):
        u = self.universe(dep.name)
        m = 0
        for i, v in enumerate(u.versions):
            if dep.contains(v):
                m |= 1 << i
        return VersionSet(u, m, dep.label if dep.label else None)

    def add(self, inc):
        for t in inc.terms:
            self.incompat.setdefault(t.package, []).append(inc)

    def solve(self):
        root_u = self.universe(ROOT)
        self.add(Incompatibility([Term(ROOT, VersionSet(root_u, root_u.full), False)], Cause("root")))
        nxt = ROOT
        while nxt is not None:
            self.propagate(nxt)
            nxt = self.choose()
        out = {}
        for p, vi in self.solution.decisions.items():
            if p != ROOT:
                out[p] = self.universes[p].versions[vi]
        return out

    def propagate(self, package):
        changed = [package]
        while changed:
            p = changed.pop(0)
            lst = self.incompat.get(p, [])
            i = len(lst) - 1
            while i >= 0:
                inc = lst[i]
                i -= 1
                r = self.propagate_one(inc)
                if r is _CONFLICT:
                    root_cause = self.resolve(inc)
                    changed = []
                    q = self.propagate_one(root_cause)
                    if q is not None and q is not _CONFLICT:
                        changed.append(q)
                    break
                if r is not None and r not in changed:
                    changed.append(r)

    def propagate_one(self, inc):
        unsat = None
        for t in inc.terms:
            rel = self.solution.relation(t)
            if rel == DISJOINT:
                return None
            if rel == OVERLAPPING:
                if unsat is not None:
                    return None
                unsat = t
        if unsat is None:
            return _CONFLICT
        self.solution.derive(unsat.inverse(), inc)
        return unsat.package

    def resolve(self, inc):
        new_inc = False
        while not inc.is_failure():
            recent_term = None
            recent_sat = None
            difference = None
            prev_level = 1
            for t in inc.terms:
                sat = self.solution.satisfier(t)
                if recent_sat is None:
                    recent_term = t
                    recent_sat = sat
                elif recent_sat.index < sat.index:
                    prev_level = max(prev_level, recent_sat.level)
                    recent_term = t
                    recent_sat = sat
                    difference = None
                else:
                    prev_level = max(prev_level, sat.level)
                if recent_term is t:
                    difference = recent_sat.difference(recent_term)
                    if difference is not None:
                        prev_level = max(prev_level, self.solution.satisfier(difference.inverse()).level)
            if prev_level < recent_sat.level or recent_sat.cause is None:
                self.solution.backtrack(prev_level)
                if new_inc:
                    self.add(inc)
                return inc
            terms = [t for t in inc.terms if t is not recent_term]
            for t in recent_sat.cause.terms:
                if t.package != recent_sat.package:
                    terms.append(t)
            if difference is not None:
                terms.append(difference.inverse())
            inc = Incompatibility(terms, Cause("conflict", conflict=inc, other=recent_sat.cause))
            new_inc = True
        raise SolveFailure(inc, self)

    def choose(self):
        unsat = self.solution.unsatisfied()
        if not unsat:
            return None
        # fewest candidate versions first (a conflict that must come is
        # found sooner), then the order the packages were met
        best = None
        best_n = -1
        for t in unsat:
            n = bin(t.vs.mask).count("1")
            if best is None or n < best_n:
                best = t
                best_n = n
        package = best.package
        u = best.vs.u
        if package != ROOT and not self.exists.get(package, True):
            self.add(Incompatibility([Term(package, VersionSet(u, u.full), True)], Cause("not-found")))
            return package
        if best.vs.mask == 0:
            self.add(Incompatibility([best], Cause("no-versions")))
            return package
        vi = self.pick(package, best.vs)
        self.steps += 1
        if package == ROOT:
            incs = self.root_incompatibilities(best.vs)
        else:
            incs = self.version_incompatibilities(package, u, vi)
        conflict = False
        for inc in incs:
            self.add(inc)
            ok = True
            for t in inc.terms:
                if t.package != package and not self.solution.satisfies(t):
                    ok = False
                    break
            conflict = conflict or ok
        if not conflict:
            self.solution.decide(package, best.vs, vi)
        return package

    def pick(self, package, vs):
        pref = getattr(self.provider, "preferred", None)
        if pref is not None and package != ROOT:
            v = pref(package)
            if v is not None:
                i = vs.u.index.get(v)
                if i is not None and (vs.mask >> i) & 1:
                    return i
        return vs.mask.bit_length() - 1

    def root_incompatibilities(self, root_vs):
        out = []
        root_term = Term(ROOT, root_vs, True)
        for d in self.root_deps:
            out.append(self.dependency_incompatibility(root_term, d))
        return out

    def dependency_incompatibility(self, depender, d):
        if isinstance(d, Forbidden):
            return Incompatibility([depender], Cause("forbidden", (d.label, d.reason)))
        vs = self.set_of(d)
        if vs.is_empty():
            why = "not-found" if not self.exists.get(d.name, True) else "no-versions"
            return Incompatibility([depender], Cause("forbidden", (self.display(d.name) + d.label, why)))
        return Incompatibility([depender, Term(d.name, vs, False)], Cause("dependency", d.name))

    def version_incompatibilities(self, package, u, vi):
        v = u.versions[vi]
        try:
            deps = self.provider.dependencies(package, v)
        except Unavailable as e:
            return [Incompatibility([Term(package, VersionSet(u, 1 << vi), True)], Cause("unavailable", e.reason))]
        cheap = getattr(self.provider, "cheap_dependencies", None)
        out = []
        for d in deps:
            k = d.key()
            done = self.listed.get((package, k))
            if done is not None and any((m >> vi) & 1 for m in done):
                continue
            # the run of adjacent versions with the same dependency, as far as
            # their dependencies are known without a download
            mask = 1 << vi
            if cheap is not None:
                for step in (-1, 1):
                    j = vi + step
                    while 0 <= j < len(u.versions):
                        ds = cheap(package, u.versions[j])
                        if ds is None or not any(x.key() == k for x in ds):
                            break
                        mask |= 1 << j
                        j += step
            self.listed.setdefault((package, k), []).append(mask)
            out.append(self.dependency_incompatibility(Term(package, VersionSet(u, mask), True), d))
        return out


_CONFLICT = object()


# ── the explanation (pub's failure.dart) ────────────────────────────────────

class _Reporter:
    def __init__(self, root, solver):
        self.root = root
        self.solver = solver
        self.derivations = {}
        self.lines = []
        self.numbers = {}

    def write(self):
        if self.root.is_derived():
            self.count(self.root)
            self.visit(self.root)
        else:
            self.out(self.root, "Because " + self.text(self.root) + ", version solving failed.", False)
        width = 0
        if self.numbers:
            width = len("(" + str(max(self.numbers.values())) + ") ")
        res = []
        last_empty = False
        for msg, num in self.lines:
            if msg == "":
                if not last_empty:
                    res.append("")
                last_empty = True
                continue
            last_empty = False
            if num is not None:
                res.append(("(" + str(num) + ")").ljust(width) + msg)
            else:
                res.append(" " * width + msg)
        return "\n".join(res)

    def count(self, inc):
        k = id(inc)
        if k in self.derivations:
            self.derivations[k] += 1
            return
        self.derivations[k] = 1
        if inc.is_derived():
            self.count(inc.cause.conflict)
            self.count(inc.cause.other)

    def out(self, inc, msg, numbered):
        if numbered:
            n = len(self.numbers) + 1
            self.numbers[id(inc)] = n
            self.lines.append((msg, n))
        else:
            self.lines.append((msg, None))

    def line(self, inc):
        return self.numbers.get(id(inc))

    def visit(self, inc, conclusion=False):
        numbered = conclusion or self.derivations.get(id(inc), 0) > 1
        conj = "So," if (conclusion or inc is self.root) else "And"
        s = self.text(inc)
        c = inc.cause
        cc = c.conflict
        oc = c.other
        if cc.is_derived() and oc.is_derived():
            cl = self.line(cc)
            ol = self.line(oc)
            if cl is not None and ol is not None:
                self.out(inc, "Because " + self.and_text(cc, oc, cl, ol) + ", " + s + ".", numbered)
            elif cl is not None or ol is not None:
                if cl is not None:
                    with_line = cc
                    without = oc
                    ln = cl
                else:
                    with_line = oc
                    without = cc
                    ln = ol
                self.visit(without)
                self.out(inc, conj + " because " + self.text(with_line) + " (" + str(ln) + "), " + s + ".", numbered)
            else:
                single_c = self.single_line(cc)
                single_o = self.single_line(oc)
                if single_o or single_c:
                    first = cc if single_o else oc
                    second = oc if single_o else cc
                    self.visit(first)
                    self.visit(second)
                    self.out(inc, "Thus, " + s + ".", numbered)
                else:
                    self.visit(cc, True)
                    self.lines.append(("", None))
                    self.visit(oc)
                    self.out(inc, conj + " because " + self.text(cc) + " (" + str(self.line(cc)) + "), " + s + ".", numbered)
        elif cc.is_derived() or oc.is_derived():
            derived = cc if cc.is_derived() else oc
            ext = oc if cc.is_derived() else cc
            dl = self.line(derived)
            if dl is not None:
                self.out(inc, "Because " + self.and_text(ext, derived, None, dl) + ", " + s + ".", numbered)
            elif self.collapsible(derived):
                dc = derived.cause
                col_derived = dc.conflict if dc.conflict.is_derived() else dc.other
                col_ext = dc.other if dc.conflict.is_derived() else dc.conflict
                self.visit(col_derived)
                self.out(inc, conj + " because " + self.and_text(col_ext, ext) + ", " + s + ".", numbered)
            else:
                self.visit(derived)
                self.out(inc, conj + " because " + self.text(ext) + ", " + s + ".", numbered)
        else:
            self.out(inc, "Because " + self.and_text(cc, oc) + ", " + s + ".", numbered)

    def single_line(self, inc):
        c = inc.cause
        return not c.conflict.is_derived() and not c.other.is_derived()

    def collapsible(self, inc):
        if self.derivations.get(id(inc), 0) > 1:
            return False
        c = inc.cause
        if c.conflict.is_derived() and c.other.is_derived():
            return False
        if not c.conflict.is_derived() and not c.other.is_derived():
            return False
        complex_ = c.conflict if c.conflict.is_derived() else c.other
        return id(complex_) not in self.numbers

    # terms and incompatibilities in words
    def terse(self, t, allow_every=False):
        if t.package == ROOT:
            return "you"
        name = self.solver.display(t.package)
        if allow_every and t.vs.is_any():
            return "every version of " + name
        return name + str(t.vs)

    def ref(self, t):
        return self.solver.display(t.package)

    def verb(self, inc, subject_term):
        if subject_term is not None and subject_term.package == ROOT:
            return "require"
        return "depends on" if inc.cause.kind == "dependency" else "requires"

    def text(self, inc):
        c = inc.cause
        t = inc.terms
        if c.kind == "dependency":
            dep = t[0] if t[0].positive else t[1]
            dee = t[1] if t[0].positive else t[0]
            return self.terse(dep, True) + " " + self.verb(inc, dep) + " " + self.terse(dee)
        if c.kind == "forbidden":
            label, why = c.detail
            subj = self.terse(t[0], True)
            if t[0].package == ROOT:
                head = "you require " + label
            elif why in ("no-versions", "not-found"):
                head = subj + " depends on " + label
            else:
                head = subj + " requires " + label
            if why == "no-versions":
                return head + ", which doesn't match any versions"
            if why == "not-found":
                return head + ", which doesn't exist"
            return head + " (" + why + ")"
        if c.kind == "no-versions":
            return "no versions of " + self.ref(t[0]) + " match " + str(t[0].vs).strip()
        if c.kind == "not-found":
            return self.ref(t[0]) + " doesn't exist"
        if c.kind == "unavailable":
            return self.terse(t[0], True) + " is unavailable (" + str(c.detail) + ")"
        if c.kind == "root":
            return "the requirements are required"
        if inc.is_failure():
            return "version solving failed"
        if len(t) == 1:
            x = t[0]
            word = "forbidden" if x.positive else "required"
            return (self.ref(x) if x.vs.is_any() else self.terse(x)) + " is " + word
        if len(t) == 2:
            a = t[0]
            b = t[1]
            if a.positive == b.positive:
                if a.positive:
                    pa = self.ref(a) if a.vs.is_any() else self.terse(a)
                    pb = self.ref(b) if b.vs.is_any() else self.terse(b)
                    return pa + " is incompatible with " + pb
                return "either " + self.terse(a) + " or " + self.terse(b)
        pos = [self.terse(x) for x in t if x.positive]
        neg = [self.terse(x) for x in t if not x.positive]
        if pos and neg:
            if len(pos) == 1:
                pt = [x for x in t if x.positive][0]
                v = "require" if pt.package == ROOT else "requires"
                return self.terse(pt, True) + " " + v + " " + " or ".join(neg)
            return "if " + " and ".join(pos) + " then " + " or ".join(neg)
        if pos:
            return "one of " + " or ".join(pos) + " must be false"
        return "one of " + " or ".join(neg) + " must be true"

    def and_text(self, a, b, aline=None, bline=None):
        r = self.requires_both(a, b, aline, bline)
        if r is None:
            r = self.requires_through(a, b, aline, bline)
        if r is None:
            r = self.requires_forbidden(a, b, aline, bline)
        if r is not None:
            return r
        s = self.text(a)
        if aline is not None:
            s += " (" + str(aline) + ")"
        s += " and " + self.text(b)
        if bline is not None:
            s += " (" + str(bline) + ")"
        return s

    def single(self, inc, positive):
        found = None
        for t in inc.terms:
            if t.positive == positive:
                if found is not None:
                    return None
                found = t
        return found

    def requires_both(self, a, b, aline, bline):
        if len(a.terms) == 1 or len(b.terms) == 1:
            return None
        ap = self.single(a, True)
        bp = self.single(b, True)
        if ap is None or bp is None or ap.package != bp.package:
            return None
        an = " or ".join(self.terse(t) for t in a.terms if not t.positive)
        bn = " or ".join(self.terse(t) for t in b.terms if not t.positive)
        dep = a.cause.kind == "dependency" and b.cause.kind == "dependency"
        if ap.package == ROOT:
            verb = "require"
        else:
            verb = "depends on" if dep else "requires"
        s = self.terse(ap, True) + " " + verb + " both " + an
        if aline is not None:
            s += " (" + str(aline) + ")"
        s += " and " + bn
        if bline is not None:
            s += " (" + str(bline) + ")"
        return s

    def requires_through(self, a, b, aline, bline):
        if len(a.terms) == 1 or len(b.terms) == 1:
            return None
        an = self.single(a, False)
        bn = self.single(b, False)
        if an is None and bn is None:
            return None
        ap = self.single(a, True)
        bp = self.single(b, True)
        if an is not None and bp is not None and an.package == bp.package and an.inverse().satisfies(bp):
            prior, prior_neg, prior_line, latter, latter_line = a, an, aline, b, bline
        elif bn is not None and ap is not None and bn.package == ap.package and bn.inverse().satisfies(ap):
            prior, prior_neg, prior_line, latter, latter_line = b, bn, bline, a, aline
        else:
            return None
        pps = [t for t in prior.terms if t.positive]
        if len(pps) > 1:
            s = "if " + " or ".join(self.terse(t) for t in pps) + " then "
        else:
            s = self.terse(pps[0], True) + " " + self.verb(prior, pps[0]) + " "
        s += self.terse(prior_neg)
        if prior_line is not None:
            s += " (" + str(prior_line) + ")"
        s += " which " + ("depends on " if latter.cause.kind == "dependency" else "requires ")
        s += " or ".join(self.terse(t) for t in latter.terms if not t.positive)
        if latter_line is not None:
            s += " (" + str(latter_line) + ")"
        return s

    def requires_forbidden(self, a, b, aline, bline):
        if len(a.terms) != 1 and len(b.terms) != 1:
            return None
        if len(a.terms) == 1:
            prior, latter, prior_line, latter_line = b, a, bline, aline
        else:
            prior, latter, prior_line, latter_line = a, b, aline, bline
        neg = self.single(prior, False)
        if neg is None:
            return None
        if not neg.inverse().satisfies(latter.terms[0]):
            return None
        pps = [t for t in prior.terms if t.positive]
        if len(pps) > 1:
            s = "if " + " or ".join(self.terse(t) for t in pps) + " then "
        else:
            s = self.terse(pps[0], True) + " " + self.verb(prior, pps[0]) + " "
        k = latter.cause.kind
        if k == "no-versions":
            s += self.terse(neg) + " which doesn't match any versions"
        elif k == "not-found":
            s += self.terse(neg) + " which doesn't exist"
        elif k == "forbidden":
            label, why = latter.cause.detail
            s += self.terse(neg) + " which " + ("depends on " if why in ("no-versions", "not-found") else "requires ") + label
            if why == "no-versions":
                s += ", which doesn't match any versions"
            elif why == "not-found":
                s += ", which doesn't exist"
            else:
                s += " (" + why + ")"
        elif k == "unavailable":
            s += self.terse(neg) + " which is unavailable (" + str(latter.cause.detail) + ")"
        else:
            s += self.terse(neg) + " which is forbidden"
        if prior_line is not None:
            s += " (" + str(prior_line) + ")"
        if latter_line is not None:
            s += " (" + str(latter_line) + ")"
        return s
