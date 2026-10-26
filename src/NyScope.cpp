// NyScope.cpp - static scope checks shared by both engines (see NyScope.hpp).
#include "NyScope.hpp"
#include "ASTNodes.hpp"
#include "Except.hpp"
#include "Script.hpp"
#include "NyRuntime.hpp"   // round 85: library_dirs (the warnings' default filter)

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace nython::scope {

using namespace nython::node;
using nython::exception::SyntaxError;
using nython::lexer::Location;

namespace {

enum class Kind { MODULE, FUNCTION, CLASS, COMP };

// How a name is written:
//   ASSIGN  `x = v`, `x += v`: rebinds the nearest binding, else a local
//   LOCAL   for target, walrus, except/with ... as: a local (or the module's
//           / enclosing function's when declared global / nonlocal)
//   DEL     `del x`: unbinds the nearest binding
enum class Write { ASSIGN, LOCAL, DEL };

struct Scope;

struct WriteSite {
    std::string name;
    Write how;
    Location where;
    VariableNode* node = nullptr;   // round 85: the name written (an assignment's or del's target)
    bool aug = false;               // round 85: `x op= v`
};

// A position in the source, for ordering (round 85).
struct Pos {
    uint32_t row = 0, col = 0;
    Pos() = default;
    Pos(const Location& l) : row(l.row), col(l.column) {}
};

// A declaration: where, and (round 85) what declared the name first - 'p'
// a parameter, 'd' def, 'c' class, 'i' import, 'v' var/let/const, 't' a
// for/with/except target or walrus, 'n' an enum/interface/namespace.
struct Decl : Location {
    char kind = 'v';
    Decl(const Location& l, char k = 'v') : Location(l), kind(k) {}
};

struct Scope {
    Kind kind;
    Scope* parent;
    bool py = false;    // round 85: Python's binding rule here (NyScope.hpp)
    Node* fn = nullptr; // round 85: the def or lambda this function scope is
    std::map<std::string, Decl> declared;      // var/let/const, params, def, class, import, loop/except/with targets
    std::set<std::string> assigned;            // plain assignment targets
    std::map<std::string, Location> consts;    // const declarations here
    std::map<std::string, Location> globals;   // `global x`
    std::map<std::string, Location> nonlocals; // `nonlocal x`
    std::set<std::string> comp_walrus;         // round 85: names a walrus in a comprehension binds here (PEP 572)
    std::vector<WriteSite> writes;
    // Binding forms whose `global` flag NyScope sets.
    std::vector<WalrusNode*> walruses;
    std::vector<ExceptNode*> excepts;
    std::vector<WithNode*> withs;
    std::vector<VariableNode*> reads;          // names read here (round 81)
    std::vector<std::unique_ptr<Scope>> children;
    Scope(Kind k, Scope* p) : kind(k), parent(p) {}

    // The function (or module) a class or comprehension body lives in: the
    // scope its plain names resolve through.
    bool binds(const std::string& n) const {
        return declared.count(n) || assigned.count(n) || nonlocals.count(n);
    }
};

std::string bare(std::string n) {
    while (!n.empty() && n[0] == '*') n.erase(0, 1);
    return n;
}

// The lines of a source, made only when a def line may carry the opt-in
// comment (round 85).
struct Lines {
    const std::string* code = nullptr;
    std::vector<size_t> starts;
    bool any = false;   // the source holds "nython: python" at all
    void init(const std::string& c) {
        code = &c;
        // ('#' first: memchr skips through a source by its rarest character)
        any = c.find("# nython: python") != std::string::npos;
        if (!any) return;
        starts.push_back(0);
        for (size_t i = 0; i < c.size(); i++) if (c[i] == '\n') starts.push_back(i + 1);
    }
    // whether line `row` (1-based) ends with the comment `# nython: python`
    bool opts_in(uint32_t row) const {
        if (!any || row == 0 || row > starts.size()) return false;
        size_t b = starts[row - 1], e = row < starts.size() ? starts[row] : code->size();
        std::string ln = code->substr(b, e - b);
        size_t h = ln.find('#');
        while (h != std::string::npos) {
            size_t p = ln.find_first_not_of(" \t", h + 1);
            if (p != std::string::npos && ln.compare(p, 7, "nython:") == 0) {
                size_t w = ln.find_first_not_of(" \t", p + 7);
                if (w != std::string::npos && ln.compare(w, 6, "python") == 0) return true;
            }
            h = ln.find('#', h + 1);
        }
        return false;
    }
};

struct Collector {
    std::unique_ptr<Scope> root;
    // round 87: `super(...)` calls in Python-language source, with their
    // scope: one that sees a binding of the name super (a parameter, a
    // module's own `def super`) calls that, as CPython looks the name up
    std::vector<std::pair<CallNode*, Scope*>> super_calls;
    Lines lines;           // round 85
    bool cur_aug = false;  // round 85: the target being written is an augmented assignment's

    Scope* child(Scope* s, Kind k) {
        s->children.push_back(std::make_unique<Scope>(k, s));
        Scope* c = s->children.back().get();
        c->py = s->py;   // round 85: the rule is inherited
        return c;
    }

    static std::string on_line(const Location& at) {
        return "(declared on line " + std::to_string(at.row) + ")";
    }

    // A declaration: var/let/const, def, class, import, a parameter. A name
    // declared const in this scope cannot be declared again, and a const
    // cannot take over a name this scope already declared.
    void declare(Scope* s, const std::string& n, const Location& at, bool is_const = false, char kind = 'v') {
        if (n.empty()) return;
        auto c = s->consts.find(n);
        if (c != s->consts.end())
            throw SyntaxError(at, "cannot redeclare constant '" + n + "' " + on_line(c->second));
        if (is_const) {
            auto d = s->declared.find(n);
            if (d != s->declared.end())
                throw SyntaxError(at, "cannot redeclare '" + n + "' as a constant " + on_line(d->second));
            s->consts.try_emplace(n, at);
        }
        s->declared.try_emplace(n, at, kind);   // (made only when new)
    }

    void write(Scope* s, const std::string& n, Write how, const Location& at, VariableNode* node = nullptr) {
        // `_` was left out of every scope check; under Python's rule it is a
        // name like any other (`_ = f()` in a function is its local)
        if (n.empty() || (n == "_" && !s->py)) return;
        s->writes.push_back({n, how, at, node, cur_aug});
        if (how == Write::ASSIGN) s->assigned.insert(n);
        else if (how == Write::LOCAL) s->declared.try_emplace(n, at, 't');
    }

    // An assignment / loop target: a name, or a tuple/list of targets.
    void target(const node_ptr& t, Scope* s, Write how) {
        if (!t) return;
        switch (t->type()) {
        case NodeType::VARIABLE:
            write(s, bare(t->value()), how, t->token().location(), static_cast<VariableNode*>(t.get()));
            break;
        case NodeType::TUPLE: case NodeType::LIST: case NodeType::ARRAY:
            for (auto& e : t->statements()) target(e, s, how);
            break;
        case NodeType::UNARY: {   // *rest in an unpacking target
            auto u = std::static_pointer_cast<UnaryNode>(t);
            target(u->operand, s, how);
            break;
        }
        default:
            walk(t, s);   // attribute / subscript targets: their parts are reads
            break;
        }
    }

    void params(const std::vector<node_ptr>& ps, Scope* fs) {
        for (auto& p : ps) if (p) declare(fs, bare(p->value()), p->token().location(), false, 'p');
    }

    void all(const std::vector<node_ptr>& v, Scope* s) { for (auto& n : v) walk(n, s); }

    void walk(const node_ptr& n, Scope* s) {
        if (!n) return;
        // round 86: the nodes of Python-language source (Node::py_src): both
        // engines take CPython's path for them where Nython is lenient
        if (s->py) n->py_src = 1;
        switch (n->type()) {
        case NodeType::FUNCTION: {
            auto* f = static_cast<FunctionNode*>(n.get());   // (no count traffic)
            all(f->defaults, s);
            if (!f->name.empty()) declare(s, f->name, n->token().location(), false, 'd');
            Scope* fs = child(s, Kind::FUNCTION);
            fs->fn = n.get();
            // round 85: `def f(...):  # nython: python` opts a Nython function in
            if (!fs->py && lines.opts_in(n->token().location().row)) fs->py = true;
            f->py_rule = fs->py;   // round 86: the rule of its body (the VM's VMCode::py)
            params(f->params, fs);
            walk(f->body, fs);
            break;
        }
        case NodeType::LAMBDA: {
            auto* f = static_cast<LambdaNode*>(n.get());
            all(f->defaults, s);
            Scope* fs = child(s, Kind::FUNCTION);
            fs->fn = n.get();
            f->py_rule = fs->py;   // round 86
            params(f->params, fs);
            walk(f->body, fs);
            break;
        }
        case NodeType::CLASS: {
            auto* c = static_cast<ClassNode*>(n.get());
            all(c->bases, s);
            declare(s, c->name, n->token().location(), false, 'c');
            walk(c->body, child(s, Kind::CLASS));
            break;
        }
        case NodeType::INTERFACE: {
            auto* c = static_cast<InterfaceNode*>(n.get());
            declare(s, c->name, n->token().location(), false, 'n');
            walk(c->body, child(s, Kind::CLASS));
            break;
        }
        case NodeType::NAMESPACE: {
            auto* c = static_cast<NameSpaceNode*>(n.get());
            declare(s, c->name, n->token().location(), false, 'n');
            walk(c->body, child(s, Kind::CLASS));
            break;
        }
        case NodeType::ENUM: {
            auto* e = static_cast<EnumNode*>(n.get());
            declare(s, e->name, n->token().location(), false, 'n');
            for (auto& it : e->items)
                if (it && it->type() == NodeType::ENUM_ITEM)
                    walk(std::static_pointer_cast<EnumItemNode>(it)->value_node, s);
            break;
        }
        case NodeType::VARIABLE_DECL: {
            auto* d = static_cast<VarDeclNode*>(n.get());
            walk(d->init, s);
            declare(s, d->name, n->token().location(), d->is_const);
            break;
        }
        case NodeType::ASSIGNMENT: {
            auto* a = static_cast<AssignmentNode*>(n.get());
            walk(a->value_node, s);
            target(a->target, s, Write::ASSIGN);
            break;
        }
        case NodeType::ASSIGNMENT_AUG: {
            auto* a = static_cast<AugAssignNode*>(n.get());
            walk(a->value_node, s);
            if (a->target && a->target->type() == NodeType::VARIABLE)   // `x += 1` reads x first
                s->reads.push_back(static_cast<VariableNode*>(a->target.get()));
            cur_aug = true;
            target(a->target, s, Write::ASSIGN);
            cur_aug = false;
            break;
        }
        case NodeType::VARIABLE:
            s->reads.push_back(static_cast<VariableNode*>(n.get()));
            break;
        case NodeType::WALRUS: {
            auto* w = static_cast<WalrusNode*>(n.get());
            walk(w->init, s);
            write(s, w->name, Write::LOCAL, n->token().location());
            s->walruses.push_back(w);
            // round 85: in a comprehension it binds in the scope around
            // the comprehensions (PEP 572)
            if (s->kind == Kind::COMP) {
                Scope* t = s;
                while (t && t->kind == Kind::COMP) t = t->parent;
                if (t) t->comp_walrus.insert(w->name);
            }
            break;
        }
        case NodeType::DELETE: {
            auto* d = static_cast<DeleteNode*>(n.get());
            if (d->target && d->target->type() == NodeType::VARIABLE)
                write(s, d->target->value(), Write::DEL, d->target->token().location(),
                      static_cast<VariableNode*>(d->target.get()));
            else walk(d->target, s);
            break;
        }
        case NodeType::FOR: {
            auto* f = static_cast<ForNode*>(n.get());
            walk(f->iterable, s);
            target(f->var, s, Write::LOCAL);
            for (auto& u : f->unpack_vars) target(u, s, Write::LOCAL);
            walk(f->body, s);
            walk(f->else_branch, s);
            break;
        }
        case NodeType::WHILE: {
            auto* w = static_cast<WhileNode*>(n.get());
            walk(w->condition, s); walk(w->body, s); walk(w->else_branch, s);
            break;
        }
        case NodeType::REPEAT: {
            auto* r = static_cast<RepeatNode*>(n.get());
            walk(r->count, s); walk(r->body, s);
            break;
        }
        case NodeType::IF: {
            auto* i = static_cast<IfNode*>(n.get());
            walk(i->condition, s); walk(i->then_branch, s);
            all(i->elseif_branches, s);
            walk(i->else_branch, s);
            break;
        }
        case NodeType::SWITCH: {
            auto* w = static_cast<SwitchNode*>(n.get());
            walk(w->subject, s); all(w->cases, s); walk(w->default_case, s);
            break;
        }
        case NodeType::CASE: {
            auto* c = static_cast<CaseNode*>(n.get());
            walk(c->value_node, s); walk(c->body, s);
            break;
        }
        case NodeType::DEFAULT:
            walk(static_cast<DefaultNode*>(n.get())->body, s);
            break;
        case NodeType::TRY: {
            auto* t = static_cast<TryNode*>(n.get());
            walk(t->body, s);
            for (auto& ec : t->except_clauses) {
                if (!ec || ec->type() != NodeType::EXCEPT) { walk(ec, s); continue; }
                auto* e = static_cast<ExceptNode*>(ec.get());
                if (!e->var.empty()) {
                    write(s, e->var, Write::LOCAL, ec->token().location());
                    s->excepts.push_back(e);
                }
                walk(e->body, s);
            }
            walk(t->else_clause, s); walk(t->finally_clause, s);
            break;
        }
        case NodeType::WITH: {
            auto* w = static_cast<WithNode*>(n.get());
            walk(w->expr, s);
            if (!w->alias.empty()) {
                write(s, w->alias, Write::LOCAL, n->token().location());
                s->withs.push_back(w);
            }
            walk(w->body, s);
            break;
        }
        case NodeType::GLOBAL: {
            auto* g = static_cast<GlobalNode*>(n.get());
            Location at = n->token().location();
            if (g->is_nonlocal) {
                if (s->kind == Kind::MODULE)
                    throw SyntaxError(at, "nonlocal declaration not allowed at module level");
                if (s->globals.count(g->name))
                    throw SyntaxError(at, "name '" + g->name + "' is nonlocal and global");
                s->nonlocals.emplace(g->name, at);
            } else {
                if (s->nonlocals.count(g->name))
                    throw SyntaxError(at, "name '" + g->name + "' is nonlocal and global");
                s->globals.emplace(g->name, at);
            }
            break;
        }
        case NodeType::IMPORT: {
            auto* im = static_cast<ImportNode*>(n.get());
            if (!im->alias.empty()) declare(s, im->alias, n->token().location(), false, 'i');
            for (auto& nm : im->names) declare(s, nm, n->token().location(), false, 'i');
            break;
        }
        case NodeType::COMPREHENSION: {
            auto* c = static_cast<ComprehensionNode*>(n.get());
            Scope* cs = child(s, Kind::COMP);
            for (auto& cl : c->clauses) {
                walk(cl.iter, cs);
                target(cl.target, cs, Write::LOCAL);
                all(cl.conds, cs);
            }
            walk(c->elt, cs); walk(c->value, cs);
            break;
        }
        case NodeType::CALL: {
            auto* c = static_cast<CallNode*>(n.get());
            // round 87: a starred display's helper in Python-language source
            // takes no int as an iterable (its _py form, the engines' natives;
            // the prelude's for a starred comprehension target's iterable)
            if (s->py && c->callee && c->callee->type() == NodeType::VARIABLE) {
                auto* v = static_cast<VariableNode*>(c->callee.get());
                if (v->name == "_ny_list_cat" || v->name == "_ny_set_cat" || v->name == "_ny_star_iter") {
                    // a new node: the VM compiles a name from its token
                    Token t = v->token();
                    t.value = v->name + "_py";
                    c->callee = std::make_shared<VariableNode>(t);
                }
            }
            if (s->py && c->callee && c->callee->type() == NodeType::SUPER) super_calls.push_back({c, s});
            walk(c->callee, s); all(c->args, s);
            break;
        }
        case NodeType::KEYWORD_ARG: walk(static_cast<KeywordArgNode*>(n.get())->val, s); break;
        case NodeType::UNARY: walk(static_cast<UnaryNode*>(n.get())->operand, s); break;
        case NodeType::BINARY: {
            auto* b = static_cast<BinaryNode*>(n.get());
            walk(b->left, s); walk(b->right, s);
            break;
        }
        case NodeType::ATTRIBUTE: walk(static_cast<AttributeNode*>(n.get())->object, s); break;
        case NodeType::SUBSCRIPT: {
            auto* x = static_cast<SubscriptNode*>(n.get());
            walk(x->object, s); walk(x->index, s);
            break;
        }
        case NodeType::SLICE: {
            auto* x = static_cast<SliceNode*>(n.get());
            walk(x->start, s); walk(x->end_node, s); walk(x->step, s);
            break;
        }
        case NodeType::RANGE: {
            auto* x = static_cast<RangeNode*>(n.get());
            walk(x->start, s); walk(x->end_node, s); walk(x->step, s);
            break;
        }
        case NodeType::MAP_ENTRY: {
            auto* x = static_cast<MapEntryNode*>(n.get());
            walk(x->key, s); walk(x->val, s);
            break;
        }
        case NodeType::RETURN: walk(static_cast<ReturnNode*>(n.get())->expr, s); break;
        case NodeType::YIELD: walk(static_cast<YieldNode*>(n.get())->expr, s); break;
        case NodeType::YIELD_FROM: walk(static_cast<YieldFromNode*>(n.get())->expr, s); break;
        case NodeType::RAISE: {
            auto* r = static_cast<RaiseNode*>(n.get());
            walk(r->expr, s); walk(r->cause, s);
            break;
        }
        case NodeType::ASSERT: {
            auto* a = static_cast<AssertNode*>(n.get());
            walk(a->condition, s); walk(a->message, s);
            break;
        }
        case NodeType::PRINT: {
            auto* p = static_cast<PrintNode*>(n.get());
            all(p->args, s); walk(p->sep, s); walk(p->end, s);
            break;
        }
        case NodeType::OPT_CHAIN: {
            auto* o = static_cast<OptChainNode*>(n.get());
            walk(o->recv, s); walk(o->index, s); walk(o->call, s); walk(o->rest, s);
            break;
        }
        case NodeType::DYN_BINOP: {
            auto* d = static_cast<DynBinopNode*>(n.get());
            walk(d->lhs, s); walk(d->rhs, s);
            break;
        }
        case NodeType::COMPLEX:
            all(static_cast<ComplexNode*>(n.get())->items, s);
            break;
        default:
            // Blocks, statement lists, list/tuple/map literals, script.
            all(n->statements(), s);
            break;
        }
    }
};

// The scope a write lands in, or null for "a new local of `s`".
Scope* resolve(Scope* s, const WriteSite& w) {
    if (s->globals.count(w.name)) {
        Scope* m = s;
        while (m->parent) m = m->parent;
        return m;
    }
    // Class and comprehension bodies resolve through the function around
    // them, but a name they declare themselves stays theirs.
    if (s->nonlocals.count(w.name)) {
        for (Scope* p = s->parent; p; p = p->parent)
            if (p->kind == Kind::FUNCTION && p->binds(w.name)) return p;
        return nullptr;
    }
    // A class body's assignment makes a class attribute.
    if (s->declared.count(w.name) || w.how == Write::LOCAL || s->kind == Kind::CLASS) return s;
    for (Scope* p = s; p; p = p->parent) {
        if (p != s && p->kind == Kind::CLASS) continue;
        if (p->declared.count(w.name) || p->consts.count(w.name)) return p;
        if (p != s && p->assigned.count(w.name)) return p;
        if (p->globals.count(w.name)) {
            Scope* m = p;
            while (m->parent) m = m->parent;
            return m;
        }
    }
    return s;
}

// ── Python's rule and the two rules' differences (round 85) ─────────────────

// What check_scope needs besides the tree.
struct Pass {
    bool top_locals = false;         // RuleScope: a snippet exec'd in a Python-language function
    bool warn = false;               // print the differences of Nython-rule functions (warn_filter)
    std::ostream* report = nullptr;  // --scope-report
    std::string file;
    Scope* root = nullptr;
};

// Python's rule: the names function scope `s` binds - its locals.
std::set<std::string> py_locals(const Scope* s) {
    std::set<std::string> L;
    for (auto& d : s->declared) L.insert(d.first);
    for (auto& a : s->assigned) L.insert(a);
    for (auto& w : s->writes) if (w.how == Write::DEL) L.insert(w.name);
    for (auto& n : s->comp_walrus) L.insert(n);
    for (auto& g : s->globals) L.erase(g.first);
    for (auto& g : s->nonlocals) L.erase(g.first);
    // self / this stay as they are (a method's receiver: STORE_SELF / LOAD_SELF)
    L.erase("self");
    L.erase("this");
    return L;
}

bool before(const Pos& a, const Pos& b) { return a.row < b.row || (a.row == b.row && a.col < b.col); }

// Where and how `outer` binds n (for the reports): its declaration, else
// its first plain assignment ('a'), else 'g' (only declared global there).
void outer_binding(const Scope* outer, const std::string& n, Pos& at, char& kind) {
    auto od = outer->declared.find(n);
    if (od != outer->declared.end()) { at = Pos(od->second); kind = od->second.kind; return; }
    for (auto& w : outer->writes)
        if (w.how == Write::ASSIGN && w.name == n) { at = Pos(w.where); kind = 'a'; return; }
    kind = 'g';
}

std::string qual_of(const Scope* s) {
    if (!s || !s->fn) return "<module>";
    if (s->fn->type() == NodeType::FUNCTION) {
        auto* f = static_cast<FunctionNode*>(s->fn);
        return f->qualname.empty() ? f->name : f->qualname;
    }
    auto* l = static_cast<LambdaNode*>(s->fn);
    return l->qualname.empty() ? std::string("<lambda>") : l->qualname;
}

uint32_t def_line(const Scope* s) { return s->fn ? s->fn->token().location().row : 0; }

// The line of a function's first statement after its docstring, where a
// declaration can be put (0: none - a body on the def line, a lambda).
uint32_t insert_line(const Scope* s) {
    if (!s->fn || s->fn->type() != NodeType::FUNCTION) return 0;
    auto* f = static_cast<FunctionNode*>(s->fn);
    if (!f->body) return 0;
    auto st = f->body->statements();
    size_t i = 0;
    if (!st.empty() && st[0] && st[0]->type() == NodeType::STRING) i = 1;
    if (i >= st.size() || !st[i]) return 0;
    uint32_t row = st[i]->token().location().row;
    return row > def_line(s) ? row : 0;
}

// Where Nython's rule and Python's give `s` (a function) different
// bindings: a plain assignment, augmented assignment or del of a name an
// enclosing function or the module binds, with no global / nonlocal for it
// and no declaration of it earlier in the function - Nython rebinds (or
// unbinds) the outer variable, Python makes it a local. One per name, the
// first such write.
void differences(Scope* s, Pass& ps) {
    std::set<std::string> seen;
    for (auto& w : s->writes) {
        if (w.how == Write::LOCAL || !w.node) continue;
        const std::string& n = w.name;
        if (n == "self" || n == "this" || n == "_" || seen.count(n)) continue;
        if (s->globals.count(n) || s->nonlocals.count(n)) continue;
        Pos wp(w.where);
        auto d = s->declared.find(n);
        if (d != s->declared.end() && before(Pos(d->second), wp)) continue;
        Scope* outer = nullptr;
        for (Scope* p = s->parent; p; p = p->parent) {
            if (p->kind == Kind::CLASS || p->kind == Kind::COMP) continue;
            if (p->globals.count(n)) { outer = ps.root; break; }
            if (p->declared.count(n) || p->assigned.count(n) || p->nonlocals.count(n)) { outer = p; break; }
        }
        if (!outer) continue;
        seen.insert(n);
        char okind = 'a';
        Pos opos;
        outer_binding(outer, n, opos, okind);
        // the function uses the outer value: an augmented assignment, a
        // del, or a read of the name on or before the line of the write
        bool uses = w.aug || w.how == Write::DEL;
        for (size_t i = 0; !uses && i < s->reads.size(); i++)
            if (s->reads[i]->name == n && s->reads[i]->token().location().row <= wp.row) uses = true;
        const char* how = w.how == Write::DEL ? "del" : w.aug ? "aug" : "assign";
        std::string where = outer == ps.root ? std::string("module") : "function:" + qual_of(outer);
        if (ps.report)
            *ps.report << ps.file << '\t' << wp.row << '\t' << wp.col << '\t' << qual_of(s) << '\t' << n << '\t'
                       << how << '\t' << where << '\t' << opos.row << '\t' << okind << '\t' << (uses ? 1 : 0) << '\t'
                       << (s->py ? "python" : "nython") << '\t' << def_line(s) << '\t' << insert_line(s) << '\n';
        if (ps.warn && !s->py) {
            const char* verb = w.how == Write::DEL ? "deletes" : w.aug ? "augments" : "assigns";
            std::string what = outer == ps.root
                ? "rebinding the module's '" + n + "'"
                : "rebinding '" + n + "' of the enclosing function '" + qual_of(outer) + "'";
            if (opos.row) what += " (line " + std::to_string(opos.row) + ")";
            std::string decl = outer == ps.root ? "global" : "nonlocal";
            std::cerr << ps.file << ":" << wp.row << ":" << wp.col << ": warning: function '" << qual_of(s) << "' "
                      << verb << " '" << n << "', " << what << " without a declaration - Python's rule makes it a"
                      << " local of the function: declare '" << decl << " " << n << "' to keep rebinding it, or"
                      << " 'var " << n << "' for a local [nython-scope]\n";
        }
    }
    // A read of a name the function binds later with a local form (a for /
    // with / except target, import, def, class, var): Nython reads the outer
    // variable there, Python's rule raises UnboundLocalError ("read").
    for (auto& [n, at] : s->declared) {
        if (seen.count(n) || s->globals.count(n) || s->nonlocals.count(n) || n == "self" || n == "this") continue;
        if (at.kind == 'p') continue;
        Pos dp(at);
        VariableNode* first = nullptr;
        for (auto* r : s->reads)
            if (r->name == n && before(Pos(r->token().location()), dp)
                && (!first || before(Pos(r->token().location()), Pos(first->token().location())))) first = r;
        if (!first) continue;
        Scope* outer = nullptr;
        for (Scope* p = s->parent; p; p = p->parent) {
            if (p->kind == Kind::CLASS || p->kind == Kind::COMP) continue;
            if (p->globals.count(n)) { outer = ps.root; break; }
            if (p->declared.count(n) || p->assigned.count(n) || p->nonlocals.count(n)) { outer = p; break; }
        }
        if (!outer) continue;
        Pos rp(first->token().location());
        Pos opos;
        char okind = 'a';
        outer_binding(outer, n, opos, okind);
        std::string where = outer == ps.root ? std::string("module") : "function:" + qual_of(outer);
        if (ps.report)
            *ps.report << ps.file << '\t' << rp.row << '\t' << rp.col << '\t' << qual_of(s) << '\t' << n << '\t'
                       << "read" << '\t' << where << '\t' << opos.row << '\t' << okind << '\t' << 1 << '\t'
                       << (s->py ? "python" : "nython") << '\t' << def_line(s) << '\t' << 0 << '\n';
        if (ps.warn && !s->py)
            std::cerr << ps.file << ":" << rp.row << ":" << rp.col << ": warning: function '" << qual_of(s) << "' reads '"
                      << n << "' before binding it (line " << dp.row << "): Nython reads the "
                      << (outer == ps.root ? std::string("module's '") + n + "'" : "enclosing function's '" + n + "'")
                      << " there, Python's rule raises UnboundLocalError [nython-scope]\n";
    }
}

void check_scope(Scope* s, Pass& ps) {
    // nonlocal x: an enclosing function must bind x.
    for (auto& [name, at] : s->nonlocals) {
        bool found = false;
        for (Scope* p = s->parent; p && !found; p = p->parent)
            if (p->kind == Kind::FUNCTION && p->binds(name)) found = true;
        if (!found) throw SyntaxError(at, "no binding for nonlocal '" + name + "' found");
    }
    // round 85: Python's rule - the names the function binds are its locals
    const bool pyf = s->py && s->kind == Kind::FUNCTION;
    std::set<std::string> L;
    if (pyf) L = py_locals(s);
    for (auto& w : s->writes) {
        Scope* t = pyf && L.count(w.name) ? s : resolve(s, w);
        if (!t) continue;
        auto c = t->consts.find(w.name);
        if (c == t->consts.end()) continue;
        std::string what = w.how == Write::DEL ? "delete" : "assign to";
        throw SyntaxError(w.where, "cannot " + what + " constant '" + w.name +
                                   "' (declared on line " + std::to_string(c->second.row) + ")");
    }
    for (auto* x : s->walruses) x->global_ref = s->globals.count(x->name) > 0;
    for (auto* x : s->excepts) x->var_global = s->globals.count(x->var) > 0;
    for (auto* x : s->withs) x->alias_global = s->globals.count(x->alias) > 0;
    // A name a function binds anywhere in its body (an assignment, a loop
    // or except/with target, a def, an import, a parameter), not declared
    // global or nonlocal there: reading it while unbound is CPython's
    // UnboundLocalError (round 81).
    if (s->kind == Kind::FUNCTION)
        for (auto* r : s->reads)
            if (!s->globals.count(r->name) && !s->nonlocals.count(r->name)
                && (s->declared.count(r->name) || s->assigned.count(r->name)))
                r->local_read = true;
    // round 85: Python's rule marks each read, assignment and del of a local
    // (VariableNode::py_bind 1); both engines then use the function's own
    // scope for it. A snippet exec'd in a Python-language function binds
    // its top level's names in its own scope (py_bind 2).
    if (pyf) {
        for (auto* r : s->reads) if (L.count(r->name)) r->py_bind = 1;
        for (auto& w : s->writes) if (w.node && L.count(w.name)) w.node->py_bind = 1;
    } else if (s->kind == Kind::MODULE && ps.top_locals) {
        for (auto& w : s->writes)
            if (w.node && w.how != Write::LOCAL && !s->globals.count(w.name)) w.node->py_bind = 2;
    }
    if (s->kind == Kind::FUNCTION && (ps.report || ps.warn)) differences(s, ps);
    for (auto& c : s->children) check_scope(c.get(), ps);
}

// round 85: the Python-language files parsed so far, and this thread's rule
std::mutex& py_files_mu() { static std::mutex m; return m; }
std::set<std::string>& py_files() { static std::set<std::string> s; return s; }
thread_local int t_rule_python = -1;   // -1: decided by the source
thread_local bool t_rule_top = false;

// Whether the warnings are wanted for `file` (warn_filter: see NyScope.hpp).
bool warn_matches(const std::string& filter, const std::string& file) {
    if (filter == "all") return true;
    if (filter != "1" && filter != "on" && filter != "yes" && filter != "true") return file.find(filter) != std::string::npos;
    if (file[0] == '<') return true;   // -c, stdin
    // not the standard library's
    namespace fs = std::filesystem;
    static std::vector<std::string> libs = [] {
        std::vector<std::string> out;
        for (auto& d : nyrt::library_dirs()) {
            std::error_code ec;
            fs::path p = fs::weakly_canonical(fs::path(d), ec);
            if (!ec) out.push_back(p.generic_string());
        }
        return out;
    }();
    std::error_code ec;
    std::string f = fs::weakly_canonical(fs::path(file), ec).generic_string();
    if (ec) return true;
    for (auto& l : libs) if (!l.empty() && f.compare(0, l.size(), l) == 0) return false;
    return true;
}

} // namespace

bool python_source(const std::string& file, const std::string& code) {
    if (file.size() > 3 && file.compare(file.size() - 3, 3, ".py") == 0) return true;
    // the leading comment block (as the lexer reads `# nython: module`)
    size_t i = 0;
    while (i < code.size()) {
        size_t e = code.find('\n', i);
        if (e == std::string::npos) e = code.size();
        size_t b = code.find_first_not_of(" \t\r", i);
        if (b == std::string::npos || b >= e) { i = e + 1; continue; }   // a blank line
        if (code[b] != '#') break;                                       // the code starts
        size_t p = std::string_view(code.data() + b, e - b).find("nython:");   // (in this line only)
        if (p != std::string_view::npos) p += b;
        if (p != std::string::npos && p < e) {
            size_t w = code.find_first_not_of(" \t", p + 7);
            if (w != std::string::npos && w + 6 <= e && code.compare(w, 6, "python") == 0
                && (w + 6 == e || !(std::isalnum((unsigned char)code[w + 6]) || code[w + 6] == '_' || code[w + 6] == '-')))
                return true;
        }
        i = e + 1;
    }
    return false;
}

bool lexer_python(const std::string& file, const std::string& code) {
    if (t_rule_python >= 0) return t_rule_python == 1;
    if (file == "stdin") return false;   // the prelude (Parser::parse)
    return python_source(file, code);
}

bool python_file(const std::string& file) {
    std::lock_guard<std::mutex> lk(py_files_mu());
    return py_files().count(file) > 0;
}

bool code_rule(const std::string& name, const std::string& code, bool caller_python) {
    auto ends = [&](const char* x) { size_t n = std::char_traits<char>::length(x); return name.size() > n && name.compare(name.size() - n, n, x) == 0; };
    if (!name.empty() && name[0] != '<' && (ends(".ny") || ends(".py"))) return python_source(name, code);
    return caller_python;
}

RuleScope::RuleScope(bool python, bool top_locals) : saved_python(t_rule_python), saved_top(t_rule_top) {
    t_rule_python = python ? 1 : 0;
    t_rule_top = top_locals;
}
RuleScope::~RuleScope() { t_rule_python = saved_python; t_rule_top = saved_top; }

std::string& warn_filter() {
    static std::string f = [] { const char* e = std::getenv("NY_SCOPE_WARN"); return std::string(e && std::string(e) != "0" ? e : ""); }();
    return f;
}
std::ostream*& report_sink() { static std::ostream* s = nullptr; return s; }

void check(const node_ptr& root) { check(root, std::string(), std::string()); }

void check(const node_ptr& root, const std::string& file, const std::string& code) {
    if (!root) return;
    bool py;
    if (t_rule_python >= 0) py = t_rule_python == 1;
    else {
        py = python_source(file, code);
        if (py && !file.empty()) {
            std::lock_guard<std::mutex> lk(py_files_mu());
            py_files().insert(file);
        }
    }
    Pass ps;
    ps.top_locals = t_rule_top;
    ps.report = report_sink();
    ps.file = file;
    const std::string& wf = warn_filter();
    ps.warn = !wf.empty() && !file.empty() && warn_matches(wf, file);
    Collector c;
    c.root = std::make_unique<Scope>(Kind::MODULE, nullptr);
    c.root->py = py;
    if (!py && !file.empty()) c.lines.init(code);   // a def may opt in (not in the engines' own text)
    ps.root = c.root.get();
    c.walk(root, c.root.get());
    // round 87: a super(...) call that sees a binding of `super` calls it
    // (class bodies are not seen from their methods, as in Python)
    for (auto& [call, sc] : c.super_calls) {
        bool bound = false;
        for (Scope* x = sc; x && !bound; x = x->parent) {
            if (x != sc && x->kind == Kind::CLASS) continue;
            bound = x->binds("super") || x->globals.count("super");
        }
        if (!bound) continue;
        Token t = call->callee->token();
        t.value = "super";
        auto v = std::make_shared<VariableNode>(t);
        v->py_src = 1;
        call->callee = v;
    }
    check_scope(c.root.get(), ps);
}

static void target_names(const node_ptr& t, std::set<std::string>& out) {
    if (!t) return;
    if (t->type() == NodeType::VARIABLE) { out.insert(t->value()); return; }
    if (t->type() == NodeType::TUPLE || t->type() == NodeType::LIST)
        for (auto& e : t->statements()) target_names(e, out);
}

static void module_stmt(const node_ptr& st, std::set<std::string>& out);
// A branch: a block of statements, or one statement.
static void module_branch(const node_ptr& b, std::set<std::string>& out) {
    if (!b) return;
    if (b->type() == NodeType::BLOCK || b->type() == NodeType::STATEMENTS || b->type() == NodeType::STATEMENT) {
        for (auto& st : b->statements()) module_stmt(st, out);
    } else module_stmt(b, out);
}
static void module_stmt(const node_ptr& st, std::set<std::string>& out) {
    if (!st) return;
    switch (st->type()) {
        case NodeType::FUNCTION: out.insert(std::static_pointer_cast<FunctionNode>(st)->name); break;
        case NodeType::CLASS: out.insert(std::static_pointer_cast<ClassNode>(st)->name); break;
        case NodeType::INTERFACE: out.insert(std::static_pointer_cast<InterfaceNode>(st)->name); break;
        case NodeType::ENUM: out.insert(std::static_pointer_cast<EnumNode>(st)->name); break;
        case NodeType::NAMESPACE: out.insert(std::static_pointer_cast<NameSpaceNode>(st)->name); break;
        case NodeType::VARIABLE_DECL: {
            auto vd = std::static_pointer_cast<VarDeclNode>(st);
            if (!vd->name.empty() && vd->name.rfind("__", 0) != 0) out.insert(vd->name);
            break;
        }
        case NodeType::ASSIGNMENT: target_names(std::static_pointer_cast<AssignmentNode>(st)->target, out); break;
        case NodeType::IF: {
            auto in = std::static_pointer_cast<IfNode>(st);
            if (in->is_expr) break;
            module_branch(in->then_branch, out);
            for (auto& b : in->elseif_branches) module_branch(b, out);
            module_branch(in->else_branch, out);
            break;
        }
        case NodeType::TRY: {
            auto tn = std::static_pointer_cast<TryNode>(st);
            module_branch(tn->body, out);
            module_branch(tn->else_clause, out);
            break;
        }
        case NodeType::BLOCK: case NodeType::STATEMENTS: case NodeType::STATEMENT:
            for (auto& s2 : st->statements()) module_stmt(s2, out);
            break;
        default: break;
    }
}
void module_names(const node_ptr& root, std::set<std::string>& out) {
    if (!root) return;
    for (auto& st : root->statements()) module_stmt(st, out);
}

// The classes a module's top level defines (inside top-level blocks, if and
// try too).
static void module_classes(const node_ptr& st, std::vector<ClassNode*>& out) {
    if (!st) return;
    switch (st->type()) {
        case NodeType::CLASS: out.push_back(static_cast<ClassNode*>(st.get())); break;
        case NodeType::IF: {
            auto in = std::static_pointer_cast<IfNode>(st);
            if (in->is_expr) break;
            module_classes(in->then_branch, out);
            for (auto& b : in->elseif_branches) module_classes(b, out);
            module_classes(in->else_branch, out);
            break;
        }
        case NodeType::TRY: {
            auto tn = std::static_pointer_cast<TryNode>(st);
            module_classes(tn->body, out);
            module_classes(tn->else_clause, out);
            break;
        }
        case NodeType::BLOCK: case NodeType::STATEMENTS: case NodeType::STATEMENT:
            for (auto& s2 : st->statements()) module_classes(s2, out);
            break;
        default: break;
    }
}
void qualify_module_classes(const node_ptr& root, const std::string& module) {
    if (!root || module.empty()) return;
    std::vector<ClassNode*> classes;
    for (auto& st : root->statements()) module_classes(st, classes);
    std::set<std::string> own;
    for (auto* c : classes) if (c->bind_name.empty()) own.insert(c->name);
    for (auto* c : classes) {
        if (!c->bind_name.empty()) continue;
        for (auto& b : c->bases) {
            if (!b || b->type() != NodeType::VARIABLE || !own.count(b->value())) continue;
            Token t = b->token();
            t.value = module + "." + b->value();
            b = std::make_shared<VariableNode>(t);
        }
        c->bind_name = c->name;
        c->name = module + "." + c->name;
    }
}

// ── --python-compat-report (round 86) ───────────────────────────────────────
// A portability lint for Nython-language code meant to run under CPython
// too: every construct the parser can see whose meaning differs from
// Python's, from the same tree and facts the engines use (Node::py_src -
// Python-language parts are skipped - and NyScope's binding differences).
// The idea is Python 2.6's `-3` switch (PEP 361: warnings, at the places
// they occur, for what Python 3 would do differently) and 2to3's fixer
// list, and the "differences from CPython" pages PyPy and Jython keep:
// the incompatibilities named and located instead of found by failures.
// Static, so it reports what the tree shows for certain (a str literal
// joined with a number, `for i in 10`, `x is int`, a name bound only to dict
// displays read with a dot, Nython's spellings of the literals, list.sort()'s
// value used, a function rebinding a module name); what depends on run-time
// types (`"a" + n` for an int n) is not reported.
namespace {

struct Compat {
    struct Item { uint32_t row, col; std::string kind, msg; };
    std::vector<Item> items;
    std::vector<std::string> lines;          // the source, for literal spellings
    // name -> 1 bound only to dict displays, 2 only to classes (type(x),
    // x.__class__, a builtin type's word, a loop over an __mro__), 0 otherwise
    std::vector<std::map<std::string, int>> scopes;

    // where an expression begins: its leftmost operand's token (a call's or
    // an attribute's own token is its bracket or dot)
    static Node* start(Node* n) {
        for (int guard = 0; n && guard < 64; guard++) {
            Node* next = nullptr;
            switch (n->type()) {
                case NodeType::CALL: next = static_cast<CallNode*>(n)->callee.get(); break;
                case NodeType::ATTRIBUTE: next = static_cast<AttributeNode*>(n)->object.get(); break;
                case NodeType::SUBSCRIPT: next = static_cast<SubscriptNode*>(n)->object.get(); break;
                case NodeType::BINARY: next = static_cast<BinaryNode*>(n)->left.get(); break;
                default: break;
            }
            if (!next) return n;
            n = next;
        }
        return n;
    }
    void add(Node* n, const std::string& kind, const std::string& msg) {
        Location l = start(n)->token().location();
        items.push_back({l.row, l.column, kind, msg});
    }
    static bool is_block(Node* n) {
        auto t = n->type();
        return t == NodeType::SCRIPT || t == NodeType::BLOCK || t == NodeType::STATEMENTS || t == NodeType::STATEMENT;
    }
    static std::string callee_name(Node* n) {
        if (!n || n->type() != NodeType::CALL) return "";
        auto* c = static_cast<CallNode*>(n);
        return c->callee && c->callee->type() == NodeType::VARIABLE ? c->callee->value() : "";
    }
    // certainly a str
    static bool strish(Node* n) {
        if (!n) return false;
        if (n->type() == NodeType::STRING) return true;
        std::string cn = callee_name(n);
        if (cn == "str" || cn == "repr" || cn == "format" || cn == "__format_value__" || cn == "chr" || cn == "ascii"
            || cn == "hex" || cn == "oct" || cn == "bin") return true;
        if (n->type() == NodeType::BINARY) {
            auto* b = static_cast<BinaryNode*>(n);
            if (b->op == "+") return strish(b->left.get()) || strish(b->right.get());
            if (b->op == "%") return b->left && b->left->type() == NodeType::STRING;
        }
        return false;
    }
    // certainly an int (what Nython iterates as range(n))
    static bool intish(Node* n, std::string* what = nullptr) {
        if (!n) return false;
        if (n->type() == NodeType::INTEGER) return true;
        std::string cn = callee_name(n);
        if (cn == "len" || cn == "int" || cn == "ord" || cn == "hash" || cn == "id") { if (what) *what = cn + "(...)"; return true; }
        if (n->type() == NodeType::UNARY) {
            auto* u = static_cast<UnaryNode*>(n);
            return (u->op == "-" || u->op == "+") && intish(u->operand.get(), what);
        }
        if (n->type() == NodeType::BINARY) {
            auto* b = static_cast<BinaryNode*>(n);
            if (b->op == "+" || b->op == "-" || b->op == "*" || b->op == "//" || b->op == "%")
                return intish(b->left.get(), what) && intish(b->right.get(), what);
        }
        return false;
    }
    // certainly not a str: what it is, else ""
    static std::string nonstr(Node* n) {
        if (!n) return "";
        switch (n->type()) {
            case NodeType::INTEGER: case NodeType::FLOAT: case NodeType::COMPLEX: return "a number";
            case NodeType::TRUE: case NodeType::FALSE: return "a bool";
            case NodeType::NONE: return "None";
            case NodeType::LIST: case NodeType::ARRAY: return "a list";
            case NodeType::MAP: return "a dict";
            case NodeType::TUPLE: return "a tuple";
            default: break;
        }
        std::string cn = callee_name(n);
        if (cn == "len" || cn == "int" || cn == "float" || cn == "ord" || cn == "abs" || cn == "round" || cn == "sum"
            || cn == "hash" || cn == "id" || cn == "divmod") return cn + "(...)";
        if (cn == "list" || cn == "dict" || cn == "tuple" || cn == "set" || cn == "sorted") return "a " + (cn == "sorted" ? std::string("list") : cn);
        if (n->type() == NodeType::BINARY) {
            auto* b = static_cast<BinaryNode*>(n);
            static const std::set<std::string> arith = {"-", "/", "//", "**", "&", "|", "^", "<<", ">>"};
            static const std::set<std::string> cmp = {"==", "!=", "<", "<=", ">", ">=", "in", "not in", "is", "is not", "and", "or"};
            if (arith.count(b->op)) return "arithmetic";
            if (cmp.count(b->op) && b->op != "and" && b->op != "or") return "a bool";
            if ((b->op == "*" || b->op == "+") && intish(b->left.get()) && intish(b->right.get())) return "arithmetic";
        }
        if (n->type() == NodeType::UNARY) {
            auto* u = static_cast<UnaryNode*>(n);
            if (u->op == "-" || u->op == "~") return "a number";
            if (u->op == "not" || u->op == "!") return "a bool";
        }
        return "";
    }
    bool spelled(Node* n, const std::string& w) {
        Location l = n->token().location();
        if (l.row == 0 || l.row > lines.size() || l.column == 0) return false;
        const std::string& ln = lines[l.row - 1];
        size_t c = l.column - 1;
        if (ln.compare(c, w.size(), w) != 0) return false;
        size_t e = c + w.size();
        return e >= ln.size() || !(std::isalnum((unsigned char)ln[e]) || ln[e] == '_');
    }
    int dict_only(const std::string& name) {
        for (auto it = scopes.rbegin(); it != scopes.rend(); ++it) {
            auto f = it->find(name);
            if (f != it->end()) return f->second;
        }
        return 0;
    }
    bool bound(const std::string& name) {
        for (auto& sc : scopes) if (sc.count(name)) return true;
        return false;
    }
    static const std::set<std::string>& type_words() {
        static const std::set<std::string> words = {"int", "float", "str", "bool", "list", "dict", "tuple", "set",
            "frozenset", "bytes", "bytearray", "complex", "object", "Object", "string", "map", "array", "function",
            "Integer", "String", "Float", "List", "Map", "Dict", "Array", "Function", "Any", "any"};
        return words;
    }
    // what a value bound to a name is: 1 a dict display, 2 a class, 0 else
    static int value_kind(Node* v) {
        if (!v) return 0;
        if (v->type() == NodeType::MAP) return 1;
        if (callee_name(v) == "type" && static_cast<CallNode*>(v)->args.size() == 1) return 2;
        if (v->type() == NodeType::ATTRIBUTE && static_cast<AttributeNode*>(v)->attr == "__class__") return 2;
        if (v->type() == NodeType::VARIABLE && type_words().count(v->value())) return 2;
        return 0;
    }
    // a name that by convention holds a class (cls, tp, base, C, member_type,
    // thisclass, a field _member_type_ ...): Python code compares such names
    // with `is` by identity, and so does Nython when they hold a class
    static bool typeish_name(std::string n) {
        while (!n.empty() && n.back() == '_') n.pop_back();
        while (!n.empty() && n.front() == '_') n.erase(0, 1);
        static const std::set<std::string> names = {"cls", "klass", "kls", "typ", "tp", "type", "mcs", "mcls",
            "metacls", "metaclass", "base", "origin", "kind"};
        if (names.count(n)) return true;
        if (n.size() == 1 && std::isupper((unsigned char)n[0])) return true;
        auto ends = [&](const std::string& suf) { return n.size() >= suf.size() && n.compare(n.size() - suf.size(), suf.size(), suf) == 0; };
        return ends("type") || ends("class") || ends("cls") || ends("Type") || ends("Class");
    }
    // the names a scope binds and whether only dict displays: its own
    // statements, not those of the functions and classes it defines
    void bindings(Node* n, std::map<std::string, int>& m) {
        if (!n) return;
        auto put = [&](const std::string& name, int kind) {
            auto f = m.find(name);
            if (f == m.end()) m[name] = kind;
            else if (f->second != kind) f->second = 0;
        };
        switch (n->type()) {
        case NodeType::FUNCTION: put(static_cast<FunctionNode*>(n)->name, 0); return;
        case NodeType::CLASS: put(static_cast<ClassNode*>(n)->name, 0); return;
        case NodeType::LAMBDA: return;
        case NodeType::ASSIGNMENT: {
            auto* a = static_cast<AssignmentNode*>(n);
            if (a->target && a->target->type() == NodeType::VARIABLE)
                put(a->target->value(), value_kind(a->value_node.get()));
            return;
        }
        case NodeType::VARIABLE_DECL: {
            auto* d = static_cast<VarDeclNode*>(n);
            put(d->name, value_kind(d->init.get()));
            return;
        }
        case NodeType::ASSIGNMENT_AUG: {
            auto* a = static_cast<AugAssignNode*>(n);
            if (a->target && a->target->type() == NodeType::VARIABLE) put(a->target->value(), 0);
            return;
        }
        case NodeType::FOR: {
            auto* f = static_cast<ForNode*>(n);
            // a loop over a class's __mro__ / __bases__ / mro() / __subclasses__() binds classes
            int k = 0;
            Node* it = f->iterable.get();
            if (it && it->type() == NodeType::CALL) it = static_cast<CallNode*>(it)->callee.get();
            if (it && it->type() == NodeType::ATTRIBUTE) {
                const std::string& at = static_cast<AttributeNode*>(it)->attr;
                if (at == "__mro__" || at == "__bases__" || at == "mro" || at == "__subclasses__") k = 2;
            }
            if (f->var) put(f->var->value(), f->unpack_vars.empty() ? k : 0);
            for (auto& u : f->unpack_vars) if (u) put(u->value(), 0);
            bindings(f->body.get(), m); bindings(f->else_branch.get(), m);
            return;
        }
        case NodeType::IF: {
            auto* i = static_cast<IfNode*>(n);
            if (i->is_expr) return;
            bindings(i->then_branch.get(), m);
            for (auto& b : i->elseif_branches) bindings(b.get(), m);
            bindings(i->else_branch.get(), m);
            return;
        }
        case NodeType::WHILE: {
            auto* w = static_cast<WhileNode*>(n);
            bindings(w->body.get(), m); bindings(w->else_branch.get(), m);
            return;
        }
        case NodeType::TRY: {
            auto* t = static_cast<TryNode*>(n);
            bindings(t->body.get(), m);
            for (auto& e : t->except_clauses) if (e && e->type() == NodeType::EXCEPT) bindings(static_cast<ExceptNode*>(e.get())->body.get(), m);
            bindings(t->else_clause.get(), m); bindings(t->finally_clause.get(), m);
            return;
        }
        case NodeType::WITH: {
            auto* w = static_cast<WithNode*>(n);
            if (!w->alias.empty()) put(w->alias, 0);
            bindings(w->body.get(), m);
            return;
        }
        case NodeType::IMPORT: {
            auto* im = static_cast<ImportNode*>(n);
            if (!im->alias.empty()) put(im->alias, 0);
            for (auto& nm : im->names) put(nm, 0);
            return;
        }
        default:
            if (is_block(n)) for (auto& s : n->statements()) bindings(s.get(), m);
            return;
        }
    }
    void enter(Node* body, const std::vector<node_ptr>* params) {
        scopes.emplace_back();
        if (params) for (auto& p : *params) if (p) scopes.back()[p->value()] = 0;
        bindings(body, scopes.back());
    }

    void check_iter(Node* it) {
        std::string what;
        if (!intish(it, &what)) return;
        add(it, "int-iter", std::string("iterates an int") + (what.empty() ? "" : " (" + what + ")")
            + ": Nython counts 0..n-1, Python raises TypeError - write range(...)");
    }
    void check_binary(BinaryNode* b) {
        if (b->op == "+") {
            Node* l = b->left.get(); Node* r = b->right.get();
            std::string w;
            if (strish(l) && !(w = nonstr(r)).empty()) {}
            else if (strish(r) && !(w = nonstr(l)).empty()) {}
            else w.clear();
            if (!w.empty())
                add(b, "concat", "str + a non-str value (" + w + "): Nython converts it to text, Python raises TypeError"
                    " - write str(...) or an f-string");
            return;
        }
        if ((b->op == "is" || b->op == "is not" || b->op == "instanceof") && b->right && b->right->type() == NodeType::VARIABLE) {
            const std::string& tn = b->right->value();
            // a builtin type's word: with a value on the left, Nython's type
            // test (a class of the program's: the same, but `x is C` is most
            // often a sentinel compared, identity in both - not reported; nor
            // a type word the program binds, which `is` compares as a value)
            if (!type_words().count(tn) || bound(tn)) return;
            // a class on the left is compared by identity in both: type(x),
            // x.__class__, a name bound only to classes or named as one is
            Node* l = b->left.get();
            if (value_kind(l) == 2) return;
            if (l && l->type() == NodeType::VARIABLE && (dict_only(l->value()) == 2 || typeish_name(l->value()))) return;
            if (l && l->type() == NodeType::ATTRIBUTE && typeish_name(static_cast<AttributeNode*>(l)->attr)) return;
            add(b, "is-type", "`" + b->op + " " + tn + "` of a value is Nython's type test: Python compares identity ("
                + (b->op == "is not" ? "True" : "False") + ") - write isinstance(...)");
        }
    }
    void check_attr(AttributeNode* a, bool store) {
        if (!a->object || a->object->type() != NodeType::VARIABLE) return;
        const std::string& nm = a->object->value();
        if (nyrt::is_dict_method_name(a->attr) || a->attr.rfind("__", 0) == 0) return;
        if (dict_only(nm) != 1) return;   // bound only to dict displays
        add(a, "dict-attr", std::string(store ? "sets" : "reads") + " the dict's key '" + a->attr + "' as an attribute:"
            " Python raises AttributeError - write " + nm + "[\"" + a->attr + "\"]" + (store ? " = ..." : ""));
    }
    void check_call(CallNode* c, bool discarded) {
        std::string cn = callee_name(c);
        if (!cn.empty()) {
            std::vector<Node*> pos;   // the positional arguments
            for (auto& a : c->args)
                if (a && a->type() != NodeType::KEYWORD_ARG && !(a->type() == NodeType::UNARY && static_cast<UnaryNode*>(a.get())->op.find('*') != std::string::npos))
                    pos.push_back(a.get());
            // the builtins that iterate their (only, first, every) argument
            if (pos.size() == 1 && (cn == "list" || cn == "tuple" || cn == "set" || cn == "frozenset" || cn == "iter"
                || cn == "sorted" || cn == "enumerate" || cn == "min" || cn == "max" || cn == "any" || cn == "all"))
                check_iter(pos[0]);
            else if (!pos.empty() && cn == "sum") check_iter(pos[0]);
            else if (cn == "zip") for (Node* p : pos) check_iter(p);
            else if (pos.size() >= 2 && (cn == "map" || cn == "filter")) check_iter(pos[1]);
        }
        if (!discarded && c->callee && c->callee->type() == NodeType::ATTRIBUTE) {
            const std::string& m = static_cast<AttributeNode*>(c->callee.get())->attr;
            if (m == "sort")
                add(c, "sort-value", "list.sort() gives the list in Nython, None in Python - sort, then use the list (or sorted(...))");
            else if (m == "reverse")
                add(c, "sort-value", "list.reverse() gives the list in Nython, None in Python - reverse, then use the list (or reversed(...))");
        }
    }
    void check_literal(Node* n) {
        static const std::pair<const char*, const char*> spell[] = {
            {"true", "True"}, {"false", "False"}, {"none", "None"}, {"null", "None"}, {"undefined", "None (or a sentinel)"}};
        for (auto& sp : spell) {
            if (!spelled(n, sp.first)) continue;
            add(n, "literal", std::string("`") + sp.first + "` is Nython's spelling: to Python it is an undefined name - write " + sp.second);
            return;
        }
    }

    void all(const std::vector<node_ptr>& v) { for (auto& x : v) walk(x.get()); }
    void walk(Node* n, bool discarded = false) {
        if (!n) return;
        const bool ny = !n->py_src;
        switch (n->type()) {
        case NodeType::FUNCTION: {
            auto* f = static_cast<FunctionNode*>(n);
            all(f->defaults);
            enter(f->body.get(), &f->params);
            walk(f->body.get());
            scopes.pop_back();
            return;
        }
        case NodeType::LAMBDA: {
            auto* f = static_cast<LambdaNode*>(n);
            all(f->defaults);
            enter(nullptr, &f->params);
            walk(f->body.get());
            scopes.pop_back();
            return;
        }
        case NodeType::CLASS: {
            auto* c = static_cast<ClassNode*>(n);
            all(c->bases);
            walk(c->body.get());
            return;
        }
        case NodeType::BINARY: {
            auto* b = static_cast<BinaryNode*>(n);
            if (ny) check_binary(b);
            walk(b->left.get()); walk(b->right.get());
            return;
        }
        case NodeType::UNARY: walk(static_cast<UnaryNode*>(n)->operand.get()); return;
        case NodeType::ATTRIBUTE: {
            auto* a = static_cast<AttributeNode*>(n);
            if (ny) check_attr(a, false);
            walk(a->object.get());
            return;
        }
        case NodeType::SUBSCRIPT: {
            auto* x = static_cast<SubscriptNode*>(n);
            walk(x->object.get()); walk(x->index.get());
            return;
        }
        case NodeType::CALL: {
            auto* c = static_cast<CallNode*>(n);
            if (ny) check_call(c, discarded);
            walk(c->callee.get()); all(c->args);
            return;
        }
        case NodeType::KEYWORD_ARG: walk(static_cast<KeywordArgNode*>(n)->val.get()); return;
        case NodeType::FOR: {
            auto* f = static_cast<ForNode*>(n);
            if (ny) check_iter(f->iterable.get());
            walk(f->iterable.get()); walk(f->body.get()); walk(f->else_branch.get());
            return;
        }
        case NodeType::COMPREHENSION: {
            auto* c = static_cast<ComprehensionNode*>(n);
            for (auto& cl : c->clauses) {
                if (ny) check_iter(cl.iter.get());
                walk(cl.iter.get()); all(cl.conds);
            }
            walk(c->elt.get()); walk(c->value.get());
            return;
        }
        case NodeType::ASSIGNMENT: {
            auto* a = static_cast<AssignmentNode*>(n);
            walk(a->value_node.get());
            if (a->target && a->target->type() == NodeType::ATTRIBUTE) {
                auto* at = static_cast<AttributeNode*>(a->target.get());
                if (ny) check_attr(at, true);
                walk(at->object.get());
            } else if (a->target && a->target->type() != NodeType::VARIABLE) walk(a->target.get());
            return;
        }
        case NodeType::ASSIGNMENT_AUG: {
            auto* a = static_cast<AugAssignNode*>(n);
            walk(a->value_node.get());
            if (a->target && a->target->type() != NodeType::VARIABLE) walk(a->target.get());
            return;
        }
        case NodeType::VARIABLE_DECL: {
            walk(static_cast<VarDeclNode*>(n)->init.get());
            return;
        }
        case NodeType::TRUE: case NodeType::FALSE: case NodeType::NONE: case NodeType::UNDEFINED:
            if (ny) check_literal(n);
            return;
        case NodeType::IF: {
            auto* i = static_cast<IfNode*>(n);
            walk(i->condition.get()); walk(i->then_branch.get());
            all(i->elseif_branches);
            walk(i->else_branch.get());
            return;
        }
        case NodeType::WHILE: {
            auto* w = static_cast<WhileNode*>(n);
            walk(w->condition.get()); walk(w->body.get()); walk(w->else_branch.get());
            return;
        }
        case NodeType::REPEAT: {
            auto* r = static_cast<RepeatNode*>(n);
            walk(r->count.get()); walk(r->body.get());
            return;
        }
        case NodeType::TRY: {
            auto* t = static_cast<TryNode*>(n);
            walk(t->body.get());
            for (auto& e : t->except_clauses) {
                if (e && e->type() == NodeType::EXCEPT) walk(static_cast<ExceptNode*>(e.get())->body.get());
                else walk(e.get());
            }
            walk(t->else_clause.get()); walk(t->finally_clause.get());
            return;
        }
        case NodeType::WITH: {
            auto* w = static_cast<WithNode*>(n);
            walk(w->expr.get()); walk(w->body.get());
            return;
        }
        case NodeType::RETURN: walk(static_cast<ReturnNode*>(n)->expr.get()); return;
        case NodeType::YIELD: walk(static_cast<YieldNode*>(n)->expr.get()); return;
        case NodeType::YIELD_FROM: {
            Node* e = static_cast<YieldFromNode*>(n)->expr.get();
            if (ny) check_iter(e);
            walk(e);
            return;
        }
        case NodeType::RAISE: {
            auto* r = static_cast<RaiseNode*>(n);
            walk(r->expr.get()); walk(r->cause.get());
            return;
        }
        case NodeType::ASSERT: {
            auto* a = static_cast<AssertNode*>(n);
            walk(a->condition.get()); walk(a->message.get());
            return;
        }
        case NodeType::PRINT: {
            auto* p = static_cast<PrintNode*>(n);
            all(p->args); walk(p->sep.get()); walk(p->end.get());
            return;
        }
        case NodeType::SWITCH: {
            auto* w = static_cast<SwitchNode*>(n);
            walk(w->subject.get()); all(w->cases); walk(w->default_case.get());
            return;
        }
        case NodeType::CASE: {
            auto* c = static_cast<CaseNode*>(n);
            walk(c->value_node.get()); walk(c->body.get());
            return;
        }
        case NodeType::DEFAULT: walk(static_cast<DefaultNode*>(n)->body.get()); return;
        case NodeType::MAP_ENTRY: {
            auto* x = static_cast<MapEntryNode*>(n);
            walk(x->key.get()); walk(x->val.get());
            return;
        }
        case NodeType::SLICE: {
            auto* x = static_cast<SliceNode*>(n);
            walk(x->start.get()); walk(x->end_node.get()); walk(x->step.get());
            return;
        }
        case NodeType::RANGE: {
            auto* x = static_cast<RangeNode*>(n);
            walk(x->start.get()); walk(x->end_node.get()); walk(x->step.get());
            return;
        }
        case NodeType::OPT_CHAIN: {
            auto* o = static_cast<OptChainNode*>(n);
            walk(o->recv.get()); walk(o->index.get()); walk(o->call.get()); walk(o->rest.get());
            return;
        }
        case NodeType::DELETE: walk(static_cast<DeleteNode*>(n)->target.get()); return;
        case NodeType::COMPLEX: all(static_cast<ComplexNode*>(n)->items); return;
        default: {
            const bool blk = is_block(n);
            for (auto& s : n->statements()) walk(s.get(), blk);
            return;
        }
        }
    }
};

} // namespace

void compat_report(const node_ptr& root, const std::string& file, const std::string& code,
                   const std::string& scope_lines, std::ostream& out) {
    if (!root) return;
    Compat c;
    {
        size_t b = 0;
        while (b <= code.size()) {
            size_t e = code.find('\n', b);
            if (e == std::string::npos) e = code.size();
            c.lines.push_back(code.substr(b, e - b));
            b = e + 1;
        }
    }
    c.enter(root.get(), nullptr);
    c.walk(root.get());
    // the binding differences NyScope reported for this file (differences():
    // file line col function name how where outer_line outer_kind uses rule ...)
    size_t p = 0;
    while (p < scope_lines.size()) {
        size_t e = scope_lines.find('\n', p);
        if (e == std::string::npos) e = scope_lines.size();
        std::vector<std::string> f;
        size_t q = p;
        while (q <= e) {
            size_t t = scope_lines.find('\t', q);
            if (t == std::string::npos || t > e) t = e;
            f.push_back(scope_lines.substr(q, t - q));
            q = t + 1;
        }
        p = e + 1;
        if (f.size() < 11 || f[10] != "nython") continue;
        const std::string& how = f[5];
        const bool mod = f[6] == "module";
        std::string verb = how == "del" ? "deletes" : how == "aug" ? "augments" : how == "read" ? "reads" : "assigns";
        std::string outer = mod ? "the module's '" + f[4] + "'" : "'" + f[4] + "' of the enclosing function '" + f[6].substr(9) + "'";
        std::string msg = "function '" + f[3] + "' " + verb + " '" + f[4] + "'";
        if (how == "read")
            msg += " before binding it: Nython reads " + outer + ", Python raises UnboundLocalError";
        else
            msg += ", rebinding " + outer + (f[7] != "0" ? " (line " + f[7] + ")" : std::string()) + ": Python's rule makes it a local - declare '"
                   + (mod ? "global " : "nonlocal ") + f[4] + "'";
        uint32_t row = (uint32_t)std::strtoul(f[1].c_str(), nullptr, 10), col = (uint32_t)std::strtoul(f[2].c_str(), nullptr, 10);
        c.items.push_back({row, col, "binding", msg});
    }
    std::stable_sort(c.items.begin(), c.items.end(), [](const Compat::Item& a, const Compat::Item& b) {
        return a.row < b.row || (a.row == b.row && a.col < b.col);
    });
    for (auto& it : c.items) out << file << ":" << it.row << ":" << it.col << ": " << it.kind << ": " << it.msg << "\n";
}

} // namespace nython::scope
