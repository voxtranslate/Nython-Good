// NyScope.cpp - static scope checks shared by both engines (see NyScope.hpp).
#include "NyScope.hpp"
#include "ASTNodes.hpp"
#include "Except.hpp"
#include "Script.hpp"

#include <map>
#include <memory>
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
};

struct Scope {
    Kind kind;
    Scope* parent;
    std::map<std::string, Location> declared;  // var/let/const, params, def, class, import, loop/except/with targets
    std::set<std::string> assigned;            // plain assignment targets
    std::map<std::string, Location> consts;    // const declarations here
    std::map<std::string, Location> globals;   // `global x`
    std::map<std::string, Location> nonlocals; // `nonlocal x`
    std::vector<WriteSite> writes;
    // Binding forms whose `global` flag NyScope sets.
    std::vector<WalrusNode*> walruses;
    std::vector<ExceptNode*> excepts;
    std::vector<WithNode*> withs;
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

struct Collector {
    std::unique_ptr<Scope> root;

    Scope* child(Scope* s, Kind k) {
        s->children.push_back(std::make_unique<Scope>(k, s));
        return s->children.back().get();
    }

    static std::string on_line(const Location& at) {
        return "(declared on line " + std::to_string(at.row) + ")";
    }

    // A declaration: var/let/const, def, class, import, a parameter. A name
    // declared const in this scope cannot be declared again, and a const
    // cannot take over a name this scope already declared.
    void declare(Scope* s, const std::string& n, const Location& at, bool is_const = false) {
        if (n.empty()) return;
        auto c = s->consts.find(n);
        if (c != s->consts.end())
            throw SyntaxError(at, "cannot redeclare constant '" + n + "' " + on_line(c->second));
        if (is_const) {
            auto d = s->declared.find(n);
            if (d != s->declared.end())
                throw SyntaxError(at, "cannot redeclare '" + n + "' as a constant " + on_line(d->second));
            s->consts.emplace(n, at);
        }
        s->declared.emplace(n, at);
    }

    void write(Scope* s, const std::string& n, Write how, const Location& at) {
        if (n.empty() || n == "_") return;
        s->writes.push_back({n, how, at});
        if (how == Write::ASSIGN) s->assigned.insert(n);
        else if (how == Write::LOCAL) s->declared.emplace(n, at);
    }

    // An assignment / loop target: a name, or a tuple/list of targets.
    void target(const node_ptr& t, Scope* s, Write how) {
        if (!t) return;
        switch (t->type()) {
        case NodeType::VARIABLE:
            write(s, bare(t->value()), how, t->token().location());
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
        for (auto& p : ps) if (p) declare(fs, bare(p->value()), p->token().location());
    }

    void all(const std::vector<node_ptr>& v, Scope* s) { for (auto& n : v) walk(n, s); }

    void walk(const node_ptr& n, Scope* s) {
        if (!n) return;
        switch (n->type()) {
        case NodeType::FUNCTION: {
            auto f = std::static_pointer_cast<FunctionNode>(n);
            all(f->defaults, s);
            if (!f->name.empty()) declare(s, f->name, n->token().location());
            Scope* fs = child(s, Kind::FUNCTION);
            params(f->params, fs);
            walk(f->body, fs);
            break;
        }
        case NodeType::LAMBDA: {
            auto f = std::static_pointer_cast<LambdaNode>(n);
            all(f->defaults, s);
            Scope* fs = child(s, Kind::FUNCTION);
            params(f->params, fs);
            walk(f->body, fs);
            break;
        }
        case NodeType::CLASS: {
            auto c = std::static_pointer_cast<ClassNode>(n);
            all(c->bases, s);
            declare(s, c->name, n->token().location());
            walk(c->body, child(s, Kind::CLASS));
            break;
        }
        case NodeType::INTERFACE: {
            auto c = std::static_pointer_cast<InterfaceNode>(n);
            declare(s, c->name, n->token().location());
            walk(c->body, child(s, Kind::CLASS));
            break;
        }
        case NodeType::NAMESPACE: {
            auto c = std::static_pointer_cast<NameSpaceNode>(n);
            declare(s, c->name, n->token().location());
            walk(c->body, child(s, Kind::CLASS));
            break;
        }
        case NodeType::ENUM: {
            auto e = std::static_pointer_cast<EnumNode>(n);
            declare(s, e->name, n->token().location());
            for (auto& it : e->items)
                if (it && it->type() == NodeType::ENUM_ITEM)
                    walk(std::static_pointer_cast<EnumItemNode>(it)->value_node, s);
            break;
        }
        case NodeType::VARIABLE_DECL: {
            auto d = std::static_pointer_cast<VarDeclNode>(n);
            walk(d->init, s);
            declare(s, d->name, n->token().location(), d->is_const);
            break;
        }
        case NodeType::ASSIGNMENT: {
            auto a = std::static_pointer_cast<AssignmentNode>(n);
            walk(a->value_node, s);
            target(a->target, s, Write::ASSIGN);
            break;
        }
        case NodeType::ASSIGNMENT_AUG: {
            auto a = std::static_pointer_cast<AugAssignNode>(n);
            walk(a->value_node, s);
            target(a->target, s, Write::ASSIGN);
            break;
        }
        case NodeType::WALRUS: {
            auto w = std::static_pointer_cast<WalrusNode>(n);
            walk(w->init, s);
            write(s, w->name, Write::LOCAL, n->token().location());
            s->walruses.push_back(w.get());
            break;
        }
        case NodeType::DELETE: {
            auto d = std::static_pointer_cast<DeleteNode>(n);
            if (d->target && d->target->type() == NodeType::VARIABLE)
                write(s, d->target->value(), Write::DEL, d->target->token().location());
            else walk(d->target, s);
            break;
        }
        case NodeType::FOR: {
            auto f = std::static_pointer_cast<ForNode>(n);
            walk(f->iterable, s);
            target(f->var, s, Write::LOCAL);
            for (auto& u : f->unpack_vars) target(u, s, Write::LOCAL);
            walk(f->body, s);
            walk(f->else_branch, s);
            break;
        }
        case NodeType::WHILE: {
            auto w = std::static_pointer_cast<WhileNode>(n);
            walk(w->condition, s); walk(w->body, s); walk(w->else_branch, s);
            break;
        }
        case NodeType::REPEAT: {
            auto r = std::static_pointer_cast<RepeatNode>(n);
            walk(r->count, s); walk(r->body, s);
            break;
        }
        case NodeType::IF: {
            auto i = std::static_pointer_cast<IfNode>(n);
            walk(i->condition, s); walk(i->then_branch, s);
            all(i->elseif_branches, s);
            walk(i->else_branch, s);
            break;
        }
        case NodeType::SWITCH: {
            auto w = std::static_pointer_cast<SwitchNode>(n);
            walk(w->subject, s); all(w->cases, s); walk(w->default_case, s);
            break;
        }
        case NodeType::CASE: {
            auto c = std::static_pointer_cast<CaseNode>(n);
            walk(c->value_node, s); walk(c->body, s);
            break;
        }
        case NodeType::DEFAULT:
            walk(std::static_pointer_cast<DefaultNode>(n)->body, s);
            break;
        case NodeType::TRY: {
            auto t = std::static_pointer_cast<TryNode>(n);
            walk(t->body, s);
            for (auto& ec : t->except_clauses) {
                if (!ec || ec->type() != NodeType::EXCEPT) { walk(ec, s); continue; }
                auto e = std::static_pointer_cast<ExceptNode>(ec);
                if (!e->var.empty()) {
                    write(s, e->var, Write::LOCAL, ec->token().location());
                    s->excepts.push_back(e.get());
                }
                walk(e->body, s);
            }
            walk(t->else_clause, s); walk(t->finally_clause, s);
            break;
        }
        case NodeType::WITH: {
            auto w = std::static_pointer_cast<WithNode>(n);
            walk(w->expr, s);
            if (!w->alias.empty()) {
                write(s, w->alias, Write::LOCAL, n->token().location());
                s->withs.push_back(w.get());
            }
            walk(w->body, s);
            break;
        }
        case NodeType::GLOBAL: {
            auto g = std::static_pointer_cast<GlobalNode>(n);
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
            auto im = std::static_pointer_cast<ImportNode>(n);
            if (!im->alias.empty()) declare(s, im->alias, n->token().location());
            for (auto& nm : im->names) declare(s, nm, n->token().location());
            break;
        }
        case NodeType::COMPREHENSION: {
            auto c = std::static_pointer_cast<ComprehensionNode>(n);
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
            auto c = std::static_pointer_cast<CallNode>(n);
            walk(c->callee, s); all(c->args, s);
            break;
        }
        case NodeType::KEYWORD_ARG: walk(std::static_pointer_cast<KeywordArgNode>(n)->val, s); break;
        case NodeType::UNARY: walk(std::static_pointer_cast<UnaryNode>(n)->operand, s); break;
        case NodeType::BINARY: {
            auto b = std::static_pointer_cast<BinaryNode>(n);
            walk(b->left, s); walk(b->right, s);
            break;
        }
        case NodeType::ATTRIBUTE: walk(std::static_pointer_cast<AttributeNode>(n)->object, s); break;
        case NodeType::SUBSCRIPT: {
            auto x = std::static_pointer_cast<SubscriptNode>(n);
            walk(x->object, s); walk(x->index, s);
            break;
        }
        case NodeType::SLICE: {
            auto x = std::static_pointer_cast<SliceNode>(n);
            walk(x->start, s); walk(x->end_node, s); walk(x->step, s);
            break;
        }
        case NodeType::RANGE: {
            auto x = std::static_pointer_cast<RangeNode>(n);
            walk(x->start, s); walk(x->end_node, s); walk(x->step, s);
            break;
        }
        case NodeType::MAP_ENTRY: {
            auto x = std::static_pointer_cast<MapEntryNode>(n);
            walk(x->key, s); walk(x->val, s);
            break;
        }
        case NodeType::RETURN: walk(std::static_pointer_cast<ReturnNode>(n)->expr, s); break;
        case NodeType::YIELD: walk(std::static_pointer_cast<YieldNode>(n)->expr, s); break;
        case NodeType::YIELD_FROM: walk(std::static_pointer_cast<YieldFromNode>(n)->expr, s); break;
        case NodeType::RAISE: {
            auto r = std::static_pointer_cast<RaiseNode>(n);
            walk(r->expr, s); walk(r->cause, s);
            break;
        }
        case NodeType::ASSERT: {
            auto a = std::static_pointer_cast<AssertNode>(n);
            walk(a->condition, s); walk(a->message, s);
            break;
        }
        case NodeType::PRINT: {
            auto p = std::static_pointer_cast<PrintNode>(n);
            all(p->args, s); walk(p->sep, s); walk(p->end, s);
            break;
        }
        case NodeType::OPT_CHAIN: {
            auto o = std::static_pointer_cast<OptChainNode>(n);
            walk(o->recv, s); walk(o->index, s); walk(o->call, s); walk(o->rest, s);
            break;
        }
        case NodeType::DYN_BINOP: {
            auto d = std::static_pointer_cast<DynBinopNode>(n);
            walk(d->lhs, s); walk(d->rhs, s);
            break;
        }
        case NodeType::COMPLEX:
            all(std::static_pointer_cast<ComplexNode>(n)->items, s);
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

void check_scope(Scope* s) {
    // nonlocal x: an enclosing function must bind x.
    for (auto& [name, at] : s->nonlocals) {
        bool found = false;
        for (Scope* p = s->parent; p && !found; p = p->parent)
            if (p->kind == Kind::FUNCTION && p->binds(name)) found = true;
        if (!found) throw SyntaxError(at, "no binding for nonlocal '" + name + "' found");
    }
    for (auto& w : s->writes) {
        Scope* t = resolve(s, w);
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
    for (auto& c : s->children) check_scope(c.get());
}

} // namespace

void check(const node_ptr& root) {
    if (!root) return;
    Collector c;
    c.root = std::make_unique<Scope>(Kind::MODULE, nullptr);
    c.walk(root, c.root.get());
    check_scope(c.root.get());
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

} // namespace nython::scope
