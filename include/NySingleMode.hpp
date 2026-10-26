#pragma once
// compile(source, filename, "single") (round 87): CPython's interactive
// mode - every expression statement of the code, at its top level or in
// the compound statements there (not in a function or class body), shows
// its value through sys.displayhook (the compiler's PRINT_EXPR when
// c_interactive and the nesting level is the module's). doctest compiles
// each example so; the prompt of lib/code.ny could.
//
// Both engines run such a code object by parsing its source as "exec" code
// and then rewriting each expression statement `e` into the call
// `_ny_single_display(e)` (the prelude's: it calls sys.displayhook, or
// raises "lost sys.displayhook"). The rewrite touches the tree just parsed,
// which nothing else holds yet.
#include "ASTNodes.hpp"
#include "Script.hpp"
#include "NyRuntime.hpp"

namespace nython::node {

// a statement that is an expression (its value would be shown)
inline bool single_is_expression(const node_ptr& n) {
    if (!n) return false;
    switch (n->type()) {
        case NodeType::TUPLE: case NodeType::LIST: case NodeType::MAP: case NodeType::FLOAT:
        case NodeType::INTEGER: case NodeType::STRING: case NodeType::TRUE: case NodeType::FALSE:
        case NodeType::NONE: case NodeType::CALL: case NodeType::INTERVAL: case NodeType::COMPLEX:
        case NodeType::SLICE: case NodeType::RANGE: case NodeType::VARIABLE: case NodeType::ATTRIBUTE:
        case NodeType::SUBSCRIPT: case NodeType::LAMBDA: case NodeType::UNARY: case NodeType::BINARY:
        case NodeType::BINARY_OP: case NodeType::BINARY_RE: case NodeType::DYN_BINOP:
        case NodeType::COMPREHENSION: case NodeType::OPT_CHAIN: case NodeType::BYTES: case NodeType::SELF:
        case NodeType::WALRUS:
            return true;
        case NodeType::IF:
            return static_cast<IfNode*>(n.get())->is_expr;
        default:
            return false;
    }
}

inline node_ptr single_display_call(const node_ptr& e) {
    Token t = e->tok();
    t.value = "_ny_single_display";
    auto c = std::make_shared<CallNode>(t, std::make_shared<VariableNode>(t));
    c->args.push_back(e);
    c->py_src = e->py_src;
    c->callee->py_src = e->py_src;
    return c;
}

inline void single_display_stmt(node_ptr& n, int depth);

inline void single_display_list(std::vector<node_ptr>& v, int depth) {
    for (auto& s : v) single_display_stmt(s, depth);
}

// rewrite one statement slot (a statement list's element, a branch)
inline void single_display_stmt(node_ptr& n, int depth) {
    if (!n || depth > 200) return;
    if (single_is_expression(n)) { n = single_display_call(n); return; }
    switch (n->type()) {
        case NodeType::SCRIPT: single_display_list(static_cast<Script*>(n.get())->decls, depth + 1); break;
        case NodeType::STATEMENTS: single_display_list(static_cast<StatementsNode*>(n.get())->stmts, depth + 1); break;
        case NodeType::BLOCK: single_display_list(static_cast<BlockNode*>(n.get())->stmts, depth + 1); break;
        case NodeType::IF: {
            auto* f = static_cast<IfNode*>(n.get());
            single_display_stmt(f->then_branch, depth + 1);
            for (auto& ei : f->elseif_branches) {
                if (ei && ei->type() == NodeType::IF) single_display_stmt(static_cast<IfNode*>(ei.get())->then_branch, depth + 1);
            }
            single_display_stmt(f->else_branch, depth + 1);
            break;
        }
        case NodeType::WHILE: {
            auto* w = static_cast<WhileNode*>(n.get());
            single_display_stmt(w->body, depth + 1);
            single_display_stmt(w->else_branch, depth + 1);
            break;
        }
        case NodeType::FOR: {
            auto* f = static_cast<ForNode*>(n.get());
            single_display_stmt(f->body, depth + 1);
            single_display_stmt(f->else_branch, depth + 1);
            break;
        }
        case NodeType::TRY: {
            auto* t = static_cast<TryNode*>(n.get());
            single_display_stmt(t->body, depth + 1);
            for (auto& ec : t->except_clauses)
                if (ec && ec->type() == NodeType::EXCEPT) single_display_stmt(static_cast<ExceptNode*>(ec.get())->body, depth + 1);
            single_display_stmt(t->else_clause, depth + 1);
            single_display_stmt(t->finally_clause, depth + 1);
            break;
        }
        case NodeType::WITH: single_display_stmt(static_cast<WithNode*>(n.get())->body, depth + 1); break;
        default: break;   // a def, a class, an assignment ...: nothing is shown
    }
}

inline void single_display(node_ptr& ast) { single_display_stmt(ast, 0); }

// A module's docstring (round 87: a module had no __doc__ at all, so
// doctest found no module docstring's examples): its first statement when
// that is a string literal, as CPython's compiler stores it; none under -OO.
inline bool module_docstring(const node_ptr& ast, std::string& out) {
    if (!ast || nyrt::cli_flags().optimize >= 2) return false;
    node_ptr first = ast;
    for (int d = 0; d < 4 && first; d++) {
        NodeType t = first->type();
        if (t == NodeType::STRING) { out = first->tok().value; return true; }
        if (t != NodeType::SCRIPT && t != NodeType::STATEMENTS && t != NodeType::BLOCK && t != NodeType::STATEMENT) return false;
        auto st = first->statements();
        if (st.empty()) return false;
        first = st[0];
    }
    if (first && first->type() == NodeType::STRING) { out = first->tok().value; return true; }
    return false;
}

} // namespace nython::node
