#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#include "Parser.hpp"
#include <functional>
#include <set>
#include "NyExcTypes.hpp"
#include "SourceCode.hpp"
#include "Except.hpp"
#include "Script.hpp"
#include "ASTNodes.hpp"
#include "DynamicLang.hpp"
#include "NyScope.hpp"

// Set by stmt() when `async` precedes a def; consumed by functionDecl().
static bool s_async_def_next = false;

using nython::node::Script;
using namespace nython::node;

namespace nython::parser {

// A body's docstring: its first statement, when that is a string literal.
static bool docstringOf(const node_ptr& body, std::string& out){
    if(!body) return false;
    node_ptr first = body;
    for(int d = 0; d < 3 && first && first->type() != NodeType::STRING; d++){
        auto st = first->statements();
        if(st.empty() || first->type() == NodeType::CALL) return false;
        first = st[0];
    }
    if(!first || first->type() != NodeType::STRING) return false;
    out = first->token().value;
    return true;
}

// A `*x` element of a display (Parser::starElem).
static bool isStarElem(const node_ptr& n){
    return n && n->type() == NodeType::UNARY && static_cast<UnaryNode*>(n.get())->op == "*";
}


std::vector<std::string> operators = {
    ">>>=",">>>","===","!==","**=","&&=","||=","^^=","<<=",">>=","**","++","--","&&","||","^^",
    "<<",">>",">=","<=","==","!=","+=","-=","*=","/=","\\=","%=","~=","&=","|=","^=",">","<","&",
    "|","^","~","%","+","-","*","/","\\","!","=",
    "and","or","xor","not","sizeof","typeof","not in","in","is","is not","print"
};

std::vector<std::string> binaries = {
    ">>>","===","!==","**","&&","||","^^",
    "<<",">>",">=","<=","==","!=",">","<","&",
    "|","^","~","%","+","-","*","/","\\",
    "and","or","xor","not","not in","in","is","is not"
};

Parser::Parser(Reporter* reporter, Runnable* runner_arg, Lexer* lexer): IParser(reporter), runner{runner_arg}, scanner{lexer}, param_defaults_{} {}

node_ptr Parser::parse() {
    try {
        node_ptr root = script();
        nython::scope::check(root);   // nonlocal / const / global binding forms (NyScope.hpp)
        return root;
    }
    catch (SyntaxError& ex) { throw ex; }
}

std::string Parser::dottedName(){
    // Accept identifier or string literal for import paths
    if (have(TokenType::String)) {
        return prev().value;
    }
    // A module may be named by a word that is a Nython keyword (`import
    // enum`, `import struct`): identifier() takes those.
    std::string name = identifier();
    while(have(TokenType::Dot)) name += "." + identifier();
    return name;
}

std::string Parser::identifier(){
    // Allow keywords to be used as identifiers (function/variable names)
    if(see(TokenType::Identifier)) {
        next();
        return prev().value;
    }
    // Accept common keywords as identifiers when used as names
    TokenType t = token().type();
    if(t == TokenType::Repeat || t == TokenType::Execute || t == TokenType::Delete
       || t == TokenType::Default || t == TokenType::Final || t == TokenType::Loop
       || t == TokenType::Block || t == TokenType::Use || t == TokenType::Global
       || t == TokenType::Static || t == TokenType::Public || t == TokenType::Private
       || t == TokenType::Protected || t == TokenType::Abstract || t == TokenType::Super
       || t == TokenType::Import || t == TokenType::From || t == TokenType::As
       || t == TokenType::Is || t == TokenType::In || t == TokenType::Print
       || t == TokenType::Typeof || t == TokenType::Sizeof || t == TokenType::Yield
       || t == TokenType::Raise || t == TokenType::Pass || t == TokenType::Assert
       || t == TokenType::With || t == TokenType::Ref || t == TokenType::Let
       || t == TokenType::Var || t == TokenType::Const
       // Declaration keywords double as names too (round 77): Python code
       // says `namespace=` (argparse.parse_args), `struct`, `module`...
       || t == TokenType::NameSpace || t == TokenType::Package || t == TokenType::Interface
       || t == TokenType::Struct || t == TokenType::Enum
       // Async keywords double as ordinary names: lib/thread.ny declares
       // `def await(self)`, which the VM's import path rejected with
       // "Expected Identifier, but found Await".
       || t == TokenType::Await || t == TokenType::Async
       || t == TokenType::EndBlock || t == TokenType::Fn
       || t == TokenType::Function || t == TokenType::New
       || t == TokenType::Try || t == TokenType::Except
       || t == TokenType::Finally || t == TokenType::Break || t == TokenType::Continue
       || t == TokenType::Return || t == TokenType::If || t == TokenType::Else
       || t == TokenType::For || t == TokenType::While || t == TokenType::Do
       || t == TokenType::Switch || t == TokenType::Case || t == TokenType::Def
       || t == TokenType::Class || t == TokenType::Interface
       || t == TokenType::Enum || t == TokenType::Not || t == TokenType::And
       || t == TokenType::Or || t == TokenType::Xor || t == TokenType::True
       || t == TokenType::False || t == TokenType::None || t == TokenType::Lambda
       || t == TokenType::Then || t == TokenType::Extends || t == TokenType::Inherits
       || t == TokenType::Implements || t == TokenType::NameSpace
       || t == TokenType::Package || t == TokenType::Interface) {
        std::string name = token().value;
        next();
        return name;
    }
    mustBe(TokenType::Identifier);
    return prev().value;
}

bool Parser::isFlowStatement(){
    return see(TokenType::Break)||see(TokenType::Continue)||see(TokenType::Return)||see(TokenType::Yield)||see(TokenType::Raise);
}

bool Parser::isYield(){ return see(TokenType::Yield); }

bool Parser::isCompoundStatement(){
    return see(TokenType::Colon)||see(TokenType::Block)||see(TokenType::If)||see(TokenType::While)
        ||see(TokenType::For)||see(TokenType::Try)||see(TokenType::With)||see(TokenType::Def)
        ||see(TokenType::Function)||see(TokenType::Fn)||see(TokenType::Fun)||see(TokenType::Var)||see(TokenType::Let)||see(TokenType::Const)||see(TokenType::Ref)
        ||see(TokenType::Class)||see(TokenType::Unless)||see(TokenType::Interface)||see(TokenType::Struct)||see(TokenType::Typeof)||see(TokenType::Sizeof)||see(TokenType::Global)||see(TokenType::Loop)||see(TokenType::Block)||see(TokenType::Repeat)
        ||see(TokenType::Enum)||see(TokenType::Switch)||see(TokenType::NameSpace)||see(TokenType::Repeat);
}

bool Parser::isImportStatement(){ return see(TokenType::From)||see(TokenType::Import); }

static bool isAugAssignType(TokenType t){
    return t==TokenType::AddAssign||t==TokenType::SubAssign||t==TokenType::MulAssign
        ||t==TokenType::DivAssign||t==TokenType::AndAssign||t==TokenType::OrAssign
        ||t==TokenType::XorAssign||t==TokenType::BinAndAssign||t==TokenType::BinOrAssign
        ||t==TokenType::BinXorAssign||t==TokenType::ModAssign||t==TokenType::RevDivAssign
        ||t==TokenType::ExpAssign||t==TokenType::ShiftLeftAssign||t==TokenType::ShiftRightAssign
        ||t==TokenType::ShiftAssign||t==TokenType::ComplementAssign;
}

bool Parser::isAugAssign(){
    return see(TokenType::AddAssign)||see(TokenType::SubAssign)||see(TokenType::MulAssign)
        ||see(TokenType::DivAssign)||see(TokenType::AndAssign)||see(TokenType::OrAssign)
        ||see(TokenType::XorAssign)||see(TokenType::BinAndAssign)||see(TokenType::BinOrAssign)
        ||see(TokenType::BinXorAssign)||see(TokenType::ModAssign)||see(TokenType::RevDivAssign)
        ||see(TokenType::ExpAssign)||see(TokenType::ShiftLeftAssign)||see(TokenType::ShiftRightAssign)
        ||see(TokenType::ShiftAssign)||see(TokenType::ComplementAssign)
        ||see(TokenType::NullCoalesceAssign);
}

bool Parser::isOperator(){
    return contains(value(),operators);
}

bool Parser::isClosing(){
    return see(TokenType::ParenClose)||see(TokenType::BraceClose)||see(TokenType::BracketClose);
}

bool Parser::isOperatorCall(){
    return contains(value(),operators) && peek().type()==TokenType::ParenOpen;
}

bool Parser::isComparison(){
    return see(TokenType::GreatEqual)||see(TokenType::LessEqual)||see(TokenType::Less)
        ||see(TokenType::Great)||see(TokenType::Equal)||see(TokenType::NotEqual)||see(TokenType::Equals)
        ||see(TokenType::In)||see(TokenType::Is)||(see(TokenType::Not)&&peek().type()==TokenType::In)
        ||(see(TokenType::Is)&&peek().type()==TokenType::Not)
        ||see(TokenType::DeepEqual)||see(TokenType::NotDeepEqual)||see(TokenType::DeepEqual)
        ||see(TokenType::Instanceof)||see(TokenType::Parentof)||see(TokenType::Subclassof);
}

bool Parser::isTrailer(){
    return see(TokenType::ParenOpen)||see(TokenType::BracketOpen)||see(TokenType::Dot);
}

bool Parser::isModifier(){
    return see(TokenType::Public)||see(TokenType::Protected)||see(TokenType::Private)||see(TokenType::Static)||see(TokenType::Abstract);
}

bool Parser::isKeyWord(){
    return (!see(TokenType::Self)&&!see(TokenType::This)&&!see(TokenType::Super)&&peek().type()!=TokenType::Dot)
        && token().clazz()==TokenClass::Keyword;
}

// ═══════════════════════════════════════════════════════════════════════════
// SCRIPT & STATEMENT ENTRY
// ═══════════════════════════════════════════════════════════════════════════

node_ptr Parser::script(){
    Token tok = this->token();
    if(have(TokenType::Package)){
        tok.value = dottedName();
        have(TokenType::SemiColon);
    } else {
        tok.value = "nython";
    }
    node_ptr node = node_ptr(new Script(tok));
    module_ann_used_ = false;
    future_annotations_ = false;
    std::vector<node_ptr> stmts;
    while(!see(TokenType::End)){
        if(have(TokenType::NewLine));
        else if(have(TokenType::SemiColon));
        else stmts.push_back(stmt());
    }
    mustBe(TokenType::End);
    // A module that annotates a name has __annotations__ (round 77).
    if(module_ann_used_) node->add(annotationsDecl(tok));
    for(auto& s : stmts) node->add(s);
    return node;
}

node_ptr Parser::stmt(){
    while(have(TokenType::NewLine)||have(TokenType::SemiColon)) {}
    if(see(TokenType::End)) return nullptr;
    return statement();
}

node_ptr Parser::statement(){
    // ── Dynamic keyword dispatch ───────────────────────────────────
    // If the current token is a dynamic keyword (__dyntok:ID:name),
    // look up its registered rules and route accordingly.
    if (see(TokenType::Identifier) && nython::is_dyntok_value(token().value)) {
        Token dyn_tok = token();
        std::string dyn_name = nython::decode_dyntok_name(dyn_tok.value);
        auto& reg = nython::DynamicLangRegistry::instance();

        // PREFIX_OP rule: dynamic keyword used as prefix operator
        // (handled in expression(), not here — fall through to expression())

        // MACRO rule: collect tokens to EOL, build MacroCallNode
        const nython::DynamicRule* macro_rule = reg.macro_rule_for(dyn_name);
        if (macro_rule) {
            next(); // consume the macro keyword token
            // Collect all tokens until NewLine, Colon (body start), or End
            std::vector<std::string> args;
            while (!see(TokenType::NewLine) && !see(TokenType::End) &&
                   !see(TokenType::Colon) && !see(TokenType::SemiColon)) {
                args.push_back(token().value);
                next();
            }
            return make_node<MacroCallNode>(dyn_tok, dyn_name, args);
        }

        // INFIX_OP rule: dynamic keyword used as infix — handled in expression()
        // If it's just a defined token with no special rule, fall through to
        // expression parsing (it will be treated as an identifier).
    }

    // Variable declarations
    if(see(TokenType::Var)) return varDecl(false, false);
    if(see(TokenType::Let)) return varDecl(false, true);
    if(see(TokenType::Const)) return varDecl(true, false);
    if(see(TokenType::Ref)) return varDecl(false, false);

    // Control flow
    if(see(TokenType::Unless)) {
        Token tok = token();
        next(); // consume unless
        bool has_paren = have(TokenType::ParenOpen);
        node_ptr cond = expression();
        if(has_paren) mustBe(TokenType::ParenClose);
        have(TokenType::Colon); have(TokenType::Then);
        node_ptr body = blockOrStmt();
        // unless cond: body → if not cond: body
        // Create a NOT unary around the condition
        Token not_tok = tok;
        not_tok.value = "not";
        auto negated = make_node<UnaryNode>(not_tok, cond);
        return make_node<IfNode>(tok, negated, body);
    }
    if(see(TokenType::If)) return ifStmt();
    if(see(TokenType::While)) {
        auto wnode = whileStmt();
        // Check for else clause after while (Python while/else)
        while(have(TokenType::NewLine)) {}
        if(see(TokenType::Else)) {
            next(); // consume else
            have(TokenType::Colon);
            auto else_body = blockOrStmt();
            if(wnode->type() == NodeType::WHILE)
                static_cast<WhileNode*>(wnode.get())->else_branch = else_body;
        }
        return wnode;
    }
    if(see(TokenType::For)) {
        auto fnode = forStmt();
        // Check for else clause after for (Python for/else)
        while(have(TokenType::NewLine)) {}
        if(see(TokenType::Else)) {
            next(); // consume else
            have(TokenType::Colon);
            if (fnode->type() == NodeType::FOR)
                static_cast<ForNode*>(fnode.get())->else_branch = blockOrStmt();
        }
        return fnode;
    }
    if(see(TokenType::Repeat)) return repeatStmt();

    // Definitions
    // Decorator: @expr before def/class, where expr is a name, a dotted
    // name (@prop.setter, @mod.deco) or either called (@deco(args)).
    //   @D
    //   def f(...): ...
    // becomes
    //   __decN__ = D          (evaluated first, as in Python: for
    //                          @x.setter, x must still be the property)
    //   def f(...): ...
    //   f = __decN__(f)
    if(have(TokenType::At)) {
        Token dec_tok = token();
        // Allow keywords as decorator names (e.g. @repeat)
        std::string decorator_name;
        if(see(TokenType::Identifier)) {
            decorator_name = identifier();
        } else {
            decorator_name = token().value;
            next();
        }
        Token call_tok = dec_tok; call_tok.value = decorator_name;
        node_ptr dec_expr = make_node<VariableNode>(call_tok);
        while(see(TokenType::Dot)) {
            next();
            Token at = token();
            std::string an = at.value;
            next();
            dec_expr = make_node<AttributeNode>(at, dec_expr, an);
        }
        // Optional (args) after decorator: @decorator(arg1, arg2)
        if(have(TokenType::ParenOpen)) {
            auto factory_call = make_node<CallNode>(call_tok, dec_expr);
            for(auto& a : argList()) factory_call->add(a);
            mustBe(TokenType::ParenClose);
            dec_expr = factory_call;
        }
        have(TokenType::NewLine);
        // Parse the decorated function or class
        node_ptr target = statement();
        std::string target_name;
        if(target->type() == NodeType::FUNCTION)
            target_name = static_cast<FunctionNode*>(target.get())->name;
        else if(target->type() == NodeType::CLASS)
            target_name = static_cast<ClassNode*>(target.get())->name;
        else if(target->type() == NodeType::BLOCK) {
            // Stacked decorators: inner @dec already returned a block.
            // The assigned name is the last assignment's LHS in the block.
            auto* blk = static_cast<BlockNode*>(target.get());
            const auto& stmts = blk->statements();
            for (auto it = stmts.rbegin(); it != stmts.rend(); ++it) {
                if ((*it)->type() == NodeType::ASSIGNMENT) {
                    auto* asgn = static_cast<AssignmentNode*>(it->get());
                    if (asgn->target && asgn->target->type() == NodeType::VARIABLE) {
                        target_name = asgn->target->value();
                        break;
                    }
                }
            }
        }
        if(!target_name.empty()) {
            static int dec_counter = 0;
            std::string tmp = "__dec" + std::to_string(dec_counter++) + "__";
            auto block = make_node<BlockNode>(dec_tok);
            Token tmp_tok = dec_tok; tmp_tok.value = tmp;
            block->add(make_node<AssignmentNode>(dec_tok, make_node<VariableNode>(tmp_tok), dec_expr));
            block->add(target);
            Token tgt_tok = dec_tok; tgt_tok.value = target_name;
            auto final_call = make_node<CallNode>(tmp_tok, make_node<VariableNode>(tmp_tok));
            final_call->add(make_node<VariableNode>(tgt_tok));
            auto assign_target = make_node<VariableNode>(tgt_tok);
            block->add(make_node<AssignmentNode>(dec_tok, assign_target, final_call));
            return block;
        }
        return target;
    }
    if(see(TokenType::Async)) {
        next();
        // `async for x in it`: the iterable goes through _ny_aiter, which
        // drives __aiter__/__anext__ (awaiting each step) until
        // StopAsyncIteration; an async generator or a plain iterable is
        // iterated directly. `async with m`: the manager goes through
        // _ny_async_cm, whose __enter__/__exit__ await m.__aenter__()/
        // m.__aexit__() (or use m's __enter__/__exit__). Both helpers are in
        // NyPrelude.hpp, so the engines run ordinary for/with statements.
        // `async def`: functionDecl() turns the body into a coroutine (see
        // async_def_desugar).
        if(see(TokenType::For)){
            node_ptr f = forStmt();
            if(f && f->type() == NodeType::FOR){
                auto* fn = static_cast<ForNode*>(f.get());
                fn->iterable = wrap_call("_ny_aiter", fn->iterable);
            }
            return f;
        }
        if(see(TokenType::With)) return withStmt(true);
        if(!(see(TokenType::Def)||see(TokenType::Function)||see(TokenType::Fn)||see(TokenType::Fun)))
            return statement();
        s_async_def_next = true;
    }
    if(see(TokenType::Def)||see(TokenType::Function)||see(TokenType::Fn)||see(TokenType::Fun)) {
        // If the keyword is followed by = [ ( . += -= etc., treat it as an identifier/assignment
        // rather than a function declaration (e.g. `fn = x[0:5]` where fn is a variable name)
        TokenType next_type = peek().type();
        bool used_as_var = (next_type == TokenType::Assign
            || next_type == TokenType::AddAssign || next_type == TokenType::SubAssign
            || next_type == TokenType::MulAssign  || next_type == TokenType::DivAssign
            || next_type == TokenType::ModAssign  || next_type == TokenType::BracketOpen
            || next_type == TokenType::Dot        || next_type == TokenType::NewLine
            || next_type == TokenType::SemiColon  || next_type == TokenType::Comma
            || next_type == TokenType::End        || next_type == TokenType::Dedent
            // fn(args) where 'fn/function/fun' is a variable name being called:
            // If the keyword is immediately followed by '(' and no identifier precedes it,
            // it must be a call expression, not a function declaration (which requires a name).
            || next_type == TokenType::ParenOpen);
        if (!used_as_var) return functionDecl();
        // Fall through to expression statement (identifier + assignment)
    }
    // `interface`, `struct`, `enum`, `namespace` start a declaration unless
    // used as a name (`namespace = ...`, `struct.pack(...)`).
    auto soft_name = [&]() {
        TokenType nt = peek().type();
        return nt == TokenType::Dot || nt == TokenType::Assign || nt == TokenType::BracketOpen
            || nt == TokenType::ParenOpen || nt == TokenType::Comma || nt == TokenType::AddAssign
            || nt == TokenType::SubAssign || nt == TokenType::MulAssign || nt == TokenType::DivAssign
            || nt == TokenType::NewLine || nt == TokenType::End;
    };
    if(see(TokenType::Class)) return classDecl();
    if(see(TokenType::Interface) && !soft_name()) return interfaceDecl();
    if(see(TokenType::Struct) && !soft_name()) return structDecl();
    if(see(TokenType::Typeof)||see(TokenType::Sizeof)) {
        Token tok = token();
        std::string fn_name = tok.value == "typeof" ? "type" : "len";
        next(); // consume keyword
        mustBe(TokenType::ParenOpen);
        auto arg = expression();
        mustBe(TokenType::ParenClose);
        Token call_tok = tok; call_tok.value = fn_name;
        auto fn_var = make_node<VariableNode>(call_tok);
        auto call = make_node<CallNode>(call_tok, fn_var);
        call->add(arg);
        have(TokenType::SemiColon); have(TokenType::NewLine);
        return call;
    }
    if(see(TokenType::Abstract)) { next(); return classDecl(); } // abstract class
    // `loop:` / `block:` are statements; `loop.run(...)`, `loop = ...`,
    // `block[0]` use them as names (asyncio's loop, round 77).
    auto keyword_as_name = [&]() {
        TokenType nt = peek().type();
        return nt == TokenType::Dot || nt == TokenType::Assign || nt == TokenType::BracketOpen
            || nt == TokenType::ParenOpen || nt == TokenType::Comma || nt == TokenType::AddAssign
            || nt == TokenType::SubAssign || nt == TokenType::MulAssign || nt == TokenType::DivAssign;
    };
    if(see(TokenType::Loop) && !keyword_as_name()) return loopStmt();
    if(see(TokenType::Block) && !keyword_as_name()) return blockStmt();
    if(see(TokenType::Repeat)) return repeatStmt();
    if(see(TokenType::Enum) && !soft_name()) return enumDecl();
    if(see(TokenType::NameSpace) && !soft_name()) return namespaceDecl();

    // Flow statements
    // global x, y / nonlocal x, y. A plain assignment already rebinds the
    // nearest existing binding; the declarations matter for a `for` loop
    // variable (otherwise a new local), and `global` makes every later use
    // of the name in this function the module's - creating it if it does
    // not exist yet, and skipping an enclosing function's variable of the
    // same name (VariableNode::global_ref).
    if(see(TokenType::Global) || (see(TokenType::Identifier) && token().value == "nonlocal"
                                  && peek(1).type() == TokenType::Identifier)) {
        bool is_global = see(TokenType::Global);
        next(); // consume 'global' / 'nonlocal'
        // The declarations stay in the tree as GlobalNodes (no-ops on both
        // engines) so NyScope can check them: `nonlocal x` needs an
        // enclosing function's x, and a walrus / `except ... as` / `with
        // ... as` of a global-declared name binds the module's.
        auto decls = make_node<BlockNode>(token());
        do {
            Token ntok = token();
            std::string n = identifier();
            if(!outer_decls_.empty()) outer_decls_.back().push_back(n);
            if(is_global && !global_decls_.empty()) global_decls_.back().push_back(n);
            decls->add(make_node<GlobalNode>(ntok, n, !is_global));
        } while(have(TokenType::Comma));
        have(TokenType::SemiColon); have(TokenType::NewLine);
        return decls;
    }
    if(see(TokenType::Return)) return returnStmt();
    if(see(TokenType::Break)) return breakStmt();
    if(see(TokenType::Continue)) return continueStmt();
    if(see(TokenType::Pass)) return passStmt();
    if(see(TokenType::Yield)) return yieldStmt();

    // Exception handling
    if(see(TokenType::Try)) {
        auto tnode = tryStmt();
        auto tn = std::static_pointer_cast<TryNode>(tnode);
        // Check for else clause
        while(have(TokenType::NewLine)) {}
        if(see(TokenType::Else)) {
            next();
            have(TokenType::Colon);
            tn->else_clause = blockOrStmt();
        }
        // Check for finally clause
        while(have(TokenType::NewLine)) {}
        if(see(TokenType::Finally)) {
            next();
            have(TokenType::Colon);
            tn->finally_clause = blockOrStmt();
        }
        return tnode;
    }
    if(see(TokenType::Raise)) return raiseStmt();
    if(see(TokenType::Assert)) return assertStmt();

    // Misc
    if(see(TokenType::Print)) return printStmt();
    if(see(TokenType::Import)||see(TokenType::From)) return importStmt();
    if(see(TokenType::Delete)) return deleteStmt();
    if(see(TokenType::With)) return withStmt();
    if(see(TokenType::Switch)) return switchStmt();

    // Lua-style  do ... end  as a standalone statement
    // (blockOrStmt handles do-blocks as sub-blocks of while/for; this handles top-level)
    if(see(TokenType::Do) && peek().type() != TokenType::BraceOpen) {
        Token tok = token();
        next(); // consume 'do'
        // Python-style do: body \n while cond
        bool colon_style = have(TokenType::Colon);
        have(TokenType::NewLine);
        auto blk = make_node<BlockNode>(tok);
        if(have(TokenType::Indent)) {
            while(!see(TokenType::EndBlock)&&!see(TokenType::Dedent)&&!see(TokenType::End)&&!see(TokenType::While)){
                blk->add(stmt());
                while(have(TokenType::NewLine)||have(TokenType::SemiColon)) {}
            }
            have(TokenType::Dedent);
        } else {
            while(!see(TokenType::EndBlock)&&!see(TokenType::End)&&!see(TokenType::While)) {
                blk->add(stmt());
                while(have(TokenType::NewLine)||have(TokenType::SemiColon)) {}
            }
        }
        // Python-style: do: body while cond  →  desugar to while(true) { body; if(!cond) break; }
        if(colon_style && see(TokenType::While)) {
            next(); // consume 'while'
            bool hp = have(TokenType::ParenOpen);
            node_ptr cond = expression();
            if(hp) mustBe(TokenType::ParenClose);
            have(TokenType::SemiColon); have(TokenType::NewLine);
            Token not_tok = tok; not_tok.value = "not";
            auto neg_cond = make_node<UnaryNode>(not_tok, cond);
            auto brk = make_node<BreakNode>(tok);
            auto guard = make_node<IfNode>(tok, neg_cond, brk);
            blk->add(guard);
            auto true_cond = make_node<BoolNode>(tok, true);
            return make_node<WhileNode>(tok, true_cond, blk);
        }
        have(TokenType::EndBlock); // consume 'end' (Lua-style)
        have(TokenType::NewLine);
        return blk;
    }
    // C-style do { } while(cond) — distinct from Lua "do ... end"
    // Detect: do {  (brace immediately after do = C-style)
    if(see(TokenType::Do) && peek().type() == TokenType::BraceOpen) {        Token tok = token();
        next(); // consume 'do'
        node_ptr body = block(); // parses the { ... } block
        // Consume optional newlines between } and while
        while(have(TokenType::NewLine)) {}
        if(see(TokenType::While)) {
            next(); // consume 'while'
            bool hp = have(TokenType::ParenOpen);
            node_ptr cond = expression();
            if(hp) mustBe(TokenType::ParenClose);
            have(TokenType::SemiColon); have(TokenType::NewLine);
            // Desugar:  do { body } while(cond)
            //        →  while(true) { body; if(!cond) break; }
            auto blk = make_node<BlockNode>(tok);
            blk->add(body);
            Token not_tok = tok; not_tok.value = "not";
            auto neg_cond = make_node<UnaryNode>(not_tok, cond);
            auto brk = make_node<BreakNode>(tok);
            auto guard = make_node<IfNode>(tok, neg_cond, brk);
            blk->add(guard);
            auto true_cond = make_node<BoolNode>(tok, true);
            return make_node<WhileNode>(tok, true_cond, blk);
        }
        // No while → just a bare brace block after 'do' (unusual, but valid)
        return body;
    }

    // Block
    if(see(TokenType::BraceOpen)) return block();

    // Annotated assignment (PEP 526): `x: int = 5`, `self.x: T = v`,
    // `x: int` (an annotation alone binds nothing). The annotation is
    // parsed and dropped; `name: T = v` declares name in the current
    // scope, as Python's annotated assignment makes it local.
    if(see(TokenType::Identifier) || see(TokenType::Self) || see(TokenType::This)) {
        int k = 0, depth = 0; bool annotated = false;
        TokenType prevt = TokenType::Dot;
        for(; k < 256; k++){
            TokenType tt = peek(k).type();
            if(depth > 0){
                if(tt == TokenType::BracketOpen) depth++;
                else if(tt == TokenType::BracketClose) { if(--depth == 0) prevt = TokenType::BracketClose; }
                else if(tt == TokenType::End || tt == TokenType::NewLine) break;
                continue;
            }
            if(tt == TokenType::Colon){
                TokenType after = peek(k + 1).type();
                annotated = k > 0 && prevt != TokenType::Dot && after != TokenType::NewLine && after != TokenType::Indent
                            && after != TokenType::End && after != TokenType::SemiColon && after != TokenType::Dedent
                            && peek(k + 1).clazz() != TokenClass::Keyword;
                break;
            }
            bool name = tt == TokenType::Identifier || tt == TokenType::Self || tt == TokenType::This;
            if(name && prevt == TokenType::Dot){ prevt = tt; continue; }
            if(tt == TokenType::Dot && prevt != TokenType::Dot){ prevt = tt; continue; }
            if(tt == TokenType::BracketOpen && prevt != TokenType::Dot){ depth++; continue; }
            break;
        }
        if(annotated){
            Token tok0 = token();
            bool simple = k == 1 && see(TokenType::Identifier);
            node_ptr target = postfix();
            mustBe(TokenType::Colon);
            int a0 = scanner->current;
            node_ptr ann = ternary();   // the annotation (not expression(): `T = v` is not an assignment)
            int a1 = scanner->current;
            node_ptr value = nullptr;
            if(have(TokenType::Assign)) value = expression();
            have(TokenType::SemiColon); have(TokenType::NewLine);
            node_ptr assign = nullptr;
            if(value) assign = simple ? make_node<VarDeclNode>(tok0, target->value(), value)
                                      : make_node<AssignmentNode>(tok0, target, value);
            // A simple name annotated in a class body or the module is
            // stored in __annotations__ (after the value, as CPython does);
            // in a function, and for `a.b: T` / `a[i]: T`, it is not kept.
            char sc = ann_scope_.empty() ? 'm' : ann_scope_.back();
            if(!simple || sc == 'f') return assign ? assign : make_node<PassNode>(tok0);
            if(sc == 'c') class_ann_used_.back() = true; else module_ann_used_ = true;
            Token at = tok0; at.value = "__annotations__";
            Token kt = tok0; kt.value = target->value();
            auto slot = make_node<SubscriptNode>(at, make_node<VariableNode>(at), make_node<StringNode>(kt));
            auto store = make_node<AssignmentNode>(tok0, slot, annotationValue(ann, a0, a1));
            if(!assign) return store;
            auto blk = make_node<BlockNode>(tok0);
            blk->add(assign);
            blk->add(store);
            return blk;
        }
    }

    // Multi-target assignment at statement level:
    //   a, b = b, a        x.y, z[0] = f()        a, *rest = seq
    //   (a, b), c = (1, 2), 3
    // Found by scanning for a comma before the `=` outside any brackets.
    if(see(TokenType::Identifier) || see(TokenType::Mul) || see(TokenType::ParenOpen) || see(TokenType::BracketOpen)) {
        bool multi = false;
        {
            int depth = 0; bool comma = false;
            for(int k = 0; k < 4096; k++) {
                Token t;
                try { t = peek(k); } catch(...) { break; }
                auto tt = t.type();
                if(tt == TokenType::End || ((tt == TokenType::NewLine || tt == TokenType::SemiColon
                   || tt == TokenType::Indent || tt == TokenType::Dedent) && depth == 0)) break;
                if(tt == TokenType::ParenOpen || tt == TokenType::BracketOpen || tt == TokenType::BraceOpen) { depth++; continue; }
                if(tt == TokenType::ParenClose || tt == TokenType::BracketClose || tt == TokenType::BraceClose) { if(--depth < 0) break; continue; }
                if(depth != 0) continue;
                if(tt == TokenType::Lambda || tt == TokenType::Colon) break;
                if(tt == TokenType::Comma) { comma = true; continue; }
                if(tt == TokenType::Assign) {
                    // a, b = ...; also [a, *b] = ... / (a, b) = ... (one
                    // bracketed target, unpacked)
                    bool bracketed = k > 0 && (peek(0).type() == TokenType::ParenOpen || peek(0).type() == TokenType::BracketOpen)
                                     && (peek(k - 1).type() == TokenType::ParenClose || peek(k - 1).type() == TokenType::BracketClose);
                    if (bracketed) {
                        // the brackets must close exactly before the `=`
                        int d2 = 0; bool whole = true;
                        for (int q = 0; q < k; q++) {
                            auto qt = peek(q).type();
                            if (qt == TokenType::ParenOpen || qt == TokenType::BracketOpen || qt == TokenType::BraceOpen) d2++;
                            else if (qt == TokenType::ParenClose || qt == TokenType::BracketClose || qt == TokenType::BraceClose) { if (--d2 == 0 && q != k - 1) { whole = false; break; } }
                        }
                        bracketed = whole;
                    }
                    multi = (comma || bracketed) && t.value == "=";
                    break;
                }
                if(isAugAssignType(tt)) break;
            }
        }
        if(multi) {
            Token op = token();
            std::vector<node_ptr> targets;
            int star = -1;
            in_assign_target_ = true;
            try {
                do {
                    if(see(TokenType::Assign)) break;
                    if(have(TokenType::Mul)) { star = (int)targets.size(); targets.push_back(postfix()); }
                    else targets.push_back(postfix());
                } while(have(TokenType::Comma));
            } catch(...) { in_assign_target_ = false; throw; }
            in_assign_target_ = false;
            op = token();
            mustBe(TokenType::Assign);
            std::vector<node_ptr> vals;
            vals.push_back(ternary());
            while(have(TokenType::Comma)) { if(see(TokenType::NewLine) || see(TokenType::SemiColon)) break; vals.push_back(ternary()); }
            have(TokenType::SemiColon); have(TokenType::NewLine);
            auto block = make_node<BlockNode>(op);
            static int unpack_counter = 0;
            auto tmp_name = [&]() { return "__unpack" + std::to_string(unpack_counter++) + "__"; };
            auto var_ref = [&](const std::string& n) { Token t = op; t.value = n; return make_node<VariableNode>(t); };
            auto int_node = [&](long v) { Token t = op; t.value = std::to_string(v); t.type(TokenType::Integer); return make_node<IntegerNode>(t); };
            std::function<void(const std::vector<node_ptr>&, int, const std::string&)> unpack;
            std::function<void(node_ptr, node_ptr)> assign_to = [&](node_ptr t, node_ptr value) {
                if(t->type() == NodeType::TUPLE || t->type() == NodeType::LIST) {
                    std::string tn = tmp_name();
                    std::vector<node_ptr> inner; int istar = -1;
                    for(auto& e : t->statements()) {
                        if(e->type() == NodeType::UNARY && e->value() == "*") {
                            istar = (int)inner.size();
                            inner.push_back(static_cast<UnaryNode*>(e.get())->operand);
                        } else inner.push_back(e);
                    }
                    auto decl = make_node<VarDeclNode>(op, tn, value, false, false);
                    static_cast<VarDeclNode*>(decl.get())->unpack = istar < 0 ? (int)inner.size() : -1;
                    block->add(decl);
                    unpack(inner, istar, tn);
                    return;
                }
                block->add(make_node<AssignmentNode>(op, t, value));
            };
            unpack = [&](const std::vector<node_ptr>& ts, int si, const std::string& src) {
                int n = (int)ts.size();
                int n_before = si < 0 ? n : si;
                for(int i = 0; i < n_before; i++)
                    assign_to(ts[i], make_node<SubscriptNode>(op, var_ref(src), int_node(i)));
                if(si < 0) return;
                int n_after = n - si - 1;
                auto sl = make_node<CallNode>(op, make_node<AttributeNode>(op, var_ref(src), "slice"));
                sl->add(int_node(si));
                if(n_after > 0) sl->add(int_node(-n_after));
                assign_to(ts[si], sl);
                for(int j = 0; j < n_after; j++)
                    assign_to(ts[si + 1 + j], make_node<SubscriptNode>(op, var_ref(src), int_node(-(n_after - j))));
            };
            // One bracketed target, [a, *b] = v / (a, b) = v: its elements
            // are the targets.
            if(targets.size() == 1 && star < 0 && vals.size() == 1
               && (targets[0]->type() == NodeType::TUPLE || targets[0]->type() == NodeType::LIST)) {
                assign_to(targets[0], vals[0]);
                return block;
            }
            std::string src = tmp_name();
            if(vals.size() == 1) {
                auto decl = make_node<VarDeclNode>(op, src, vals[0], false, false);
                static_cast<VarDeclNode*>(decl.get())->unpack = star < 0 ? (int)targets.size() : -1;
                block->add(decl);
            }
            else {
                // Several values: evaluated first, all of them (a, b = b, a).
                auto lst = make_node<ListNode>(op);
                for(auto& v : vals) lst->add(v);
                block->add(make_node<VarDeclNode>(op, src, lst, false, false));
            }
            unpack(targets, star, src);
            return block;
        }
    }
    // Expression statement (assignment, call, etc.)
    return expressionStmt();
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPRESSION PARSING (precedence climbing)
// ═══════════════════════════════════════════════════════════════════════════

node_ptr Parser::expressionStmt(){
    node_ptr expr = expression();
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
    return expr;
}

node_ptr Parser::expression(){
    return assignment();
}

node_ptr Parser::assignment(){
    node_ptr left = ternary();
    // name := value (the lexer gives := the Assign token type with value
    // ":="): an expression that binds and yields the value. It used to parse
    // as a plain assignment, which is a statement - `if (n := len(L)) > 2`
    // compared against a leftover stack value on the VM.
    if(see(TokenType::Assign) && token().value == ":=" && left && left->type() == NodeType::VARIABLE){
        Token op = token(); next();
        node_ptr init = ternary();
        return make_node<WalrusNode>(op, left->value(), init);
    }
    // `a?.b = v` has no meaning when a is none: an optional chain is read-only.
    if(left && left->type() == NodeType::OPT_CHAIN && (see(TokenType::Assign) || isAugAssign()))
        throw SyntaxError(token().location(), "cannot assign to an optional chain (?. / ?[)");
    if(have(TokenType::Assign)){
        Token op = prev();
        node_ptr right = assignment(); // right-associative
        return make_node<AssignmentNode>(op, left, right);
    }
    if(isAugAssign()){
        Token op = token();
        next();
        node_ptr right = assignment();
        return make_node<AugAssignNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::ternary(){
    // yield as expression: allows "var x = yield val" and "x = yield val"
    if(see(TokenType::Yield)) {
        Token tok = token(); next(); // consume 'yield'
        if(!yield_seen_.empty()) yield_seen_.back() = true;
        if(have(TokenType::From)){
            node_ptr src = expression();
            return make_node<YieldFromNode>(tok, src);
        }
        node_ptr yexpr = nullptr;
        if(!see(TokenType::NewLine) && !see(TokenType::SemiColon) && !see(TokenType::End)
           && !see(TokenType::ParenClose) && !see(TokenType::BracketClose))
            yexpr = expression();
        return make_node<YieldNode>(tok, yexpr);
    }
    node_ptr expr = coalesce();
    // C-style ternary: cond ? then : else
    if(have(TokenType::QuestionMark)){
        Token tok = prev();
        node_ptr then_expr = expression();
        mustBe(TokenType::Colon);
        node_ptr else_expr = expression();
        auto node = make_node<IfNode>(tok, expr, then_expr);
        std::static_pointer_cast<IfNode>(node)->else_branch = else_expr;
        std::static_pointer_cast<IfNode>(node)->is_expr = true;
        return node;
    }
    // Python-style ternary: value if cond else other
    if(have(TokenType::If)){
        Token tok = prev();
        node_ptr condition = coalesce();
        mustBe(TokenType::Else);
        node_ptr else_expr = expression();
        auto node = make_node<IfNode>(tok, condition, expr);
        std::static_pointer_cast<IfNode>(node)->else_branch = else_expr;
        std::static_pointer_cast<IfNode>(node)->is_expr = true;
        return node;
    }
    return expr;
}

// a ?? b: a, unless a is none or undefined - then b, which is evaluated
// only in that case. Binds looser than `or` and tighter than the ternaries
// (C#'s and JavaScript's place), and groups to the right: a ?? b ?? c.
node_ptr Parser::coalesce(){
    node_ptr left = rangeExpr();
    if(have(TokenType::NullCoalesce)){
        Token tok = prev();
        tok.value = "??";
        node_ptr right = coalesce();
        return make_node<BinaryNode>(tok, left, right);
    }
    return left;
}

// Range / interval:  a..b   (inclusive of a, exclusive of b)
//                    a...b  (inclusive of both ends)
//                    a..b..step
//
// The lexer has always emitted Interval and Ellipsis tokens and RangeNode /
// evalRange have always existed; nothing ever connected them, so `for i in 1..3`
// was a syntax error even though every piece needed to run it was present.
// Sits directly above logicalOr so `1..n` binds tighter than `and`/`or` but
// looser than arithmetic, making `1..n+1` mean `1..(n+1)`.
node_ptr Parser::rangeExpr(){
    node_ptr lo = logicalOr();
    if(see(TokenType::Interval) || see(TokenType::Ellipsis)){
        bool inclusive = see(TokenType::Ellipsis);
        Token tok = token();
        next();
        node_ptr hi = logicalOr();
        node_ptr step = nullptr;
        // a..b..step
        if(see(TokenType::Interval)){
            next();
            step = logicalOr();
        }
        if(inclusive){
            // `a...b` includes b. Represent it as a half-open range ending at
            // b+1 so one evaluator serves both forms.
            Token one = tok;
            one.value = "1";
            one.type(TokenType::Integer);
            Token plus = tok;
            plus.value = "+";
            plus.type(TokenType::Add);
            hi = make_node<BinaryNode>(plus, hi, make_node<IntegerNode>(one));
        }
        return make_node<RangeNode>(tok, lo, hi, step);
    }
    return lo;
}

node_ptr Parser::logicalOr(){
    node_ptr left = logicalAnd();
    while(have(TokenType::Or)||have(TokenType::Xor)){
        Token op = prev();
        if (op.value == "xor" || op.value == "^^") op.value = "xor";
        else op.value = "or";
        node_ptr right = logicalAnd();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

// Python's precedence, loosest first: or, and, comparisons (==, <, in,
// is, ...), |, ^, &, shifts, arithmetic. The bitwise operators used to sit
// below the comparisons, as in C, so `d & 1 == 0` read d & (1 == 0).
node_ptr Parser::logicalAnd(){
    node_ptr left = equality();
    while(have(TokenType::And)){
        Token op = prev(); op.value = "and";
        node_ptr right = equality();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::bitwiseOr(){
    node_ptr left = bitwiseXor();
    while(have(TokenType::BinOr)){
        Token op = prev(); node_ptr right = bitwiseXor();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::bitwiseXor(){
    node_ptr left = bitwiseAnd();
    while(have(TokenType::BinXor)){
        Token op = prev(); node_ptr right = bitwiseAnd();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::bitwiseAnd(){
    node_ptr left = shift();
    while(have(TokenType::BinAnd)){
        Token op = prev(); node_ptr right = shift();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::equality(){
    node_ptr left = comparison();
    while(true){
        Token op = token();
        if(have(TokenType::Equal))          { op.value = "=="; left = make_node<BinaryNode>(op, left, comparison()); }
        else if(have(TokenType::NotEqual))  { op.value = "!="; left = make_node<BinaryNode>(op, left, comparison()); }
        else if(have(TokenType::DeepEqual)) { op.value = "==="; left = make_node<BinaryNode>(op, left, comparison()); }
        else if(have(TokenType::NotDeepEqual)){op.value = "!=="; left = make_node<BinaryNode>(op, left, comparison()); }
        else if(have(TokenType::Equals))     { op.value = "==="; left = make_node<BinaryNode>(op, left, comparison()); }
        else break;
    }
    return left;
}

node_ptr Parser::comparison(){
    node_ptr left = bitwiseOr();
    while(true){
        Token op = token();
        bool is_cmp = false;
        std::string cmp_op;
        if(see(TokenType::Less)) { is_cmp = true; cmp_op = "<"; }
        else if(see(TokenType::Great)) { is_cmp = true; cmp_op = ">"; }
        else if(see(TokenType::LessEqual)) { is_cmp = true; cmp_op = "<="; }
        else if(see(TokenType::GreatEqual)) { is_cmp = true; cmp_op = ">="; }
        
        if(is_cmp) {
            next(); // consume the operator
            op.value = cmp_op;
            node_ptr right = bitwiseOr();
            // Check for chained comparison
            if(left->type() == NodeType::BINARY) {
                auto* left_bin = static_cast<BinaryNode*>(left.get());
                std::string lop = left_bin->op;
                // Direct comparison on left: a < b → chain as (a < b) AND (b op c)
                if(lop == "<" || lop == ">" || lop == "<=" || lop == ">=" || lop == "==" || lop == "!=") {
                    Token and_tok = op; and_tok.value = "and";
                    auto right_cmp = make_node<BinaryNode>(op, left_bin->right, right);
                    left = make_node<BinaryNode>(and_tok, left, right_cmp);
                    continue;
                }
                // AND chain on left (from previous chaining): dig out rightmost comparison
                if(lop == "and") {
                    // The right side of the AND should be a comparison
                    if(left_bin->right->type() == NodeType::BINARY) {
                        auto* rbin = static_cast<BinaryNode*>(left_bin->right.get());
                        std::string rop = rbin->op;
                        if(rop == "<" || rop == ">" || rop == "<=" || rop == ">=" || rop == "==" || rop == "!=") {
                            Token and_tok = op; and_tok.value = "and";
                            auto new_cmp = make_node<BinaryNode>(op, rbin->right, right);
                            left = make_node<BinaryNode>(and_tok, left, new_cmp);
                            continue;
                        }
                    }
                }
            }
            left = make_node<BinaryNode>(op, left, right);
        }
        else if(have(TokenType::In))      { op.value = "in"; left = make_node<BinaryNode>(op, left, bitwiseOr()); }
        else if(see(TokenType::Not) && peek().type()==TokenType::In) { next(); next(); op.value = "not in"; left = make_node<BinaryNode>(op, left, bitwiseOr()); }
        else if(have(TokenType::Is))      { if(have(TokenType::Not)) op.value = "is not"; else op.value = "is"; left = make_node<BinaryNode>(op, left, bitwiseOr()); }
        else if(have(TokenType::Instanceof)){op.value = "instanceof"; left = make_node<BinaryNode>(op, left, bitwiseOr()); }
        else break;
    }
    return left;
}

node_ptr Parser::shift(){
    node_ptr left = addition();
    while(have(TokenType::ShiftLeft)||have(TokenType::ShiftRight)){
        Token op = prev(); node_ptr right = addition();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::addition(){
    node_ptr left = multiplication();
    while(have(TokenType::Add)||have(TokenType::Sub)){
        Token op = prev(); node_ptr right = multiplication();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::multiplication(){
    node_ptr left = power();
    // `a @ b` (matrix multiplication: __matmul__). At the start of a
    // statement `@` is a decorator; statement() takes that before this.
    while(have(TokenType::Mul)||have(TokenType::Div)||have(TokenType::Mod)||have(TokenType::RevDiv)||have(TokenType::At)){
        Token op = prev(); if(op.type() == TokenType::At) op.value = "@";
        node_ptr right = power();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::power(){
    // A sign binds looser than ** on its left, as in Python: -2**2 is
    // -(2**2) == -4, not (-2)**2. The exponent is parsed here too, so it may
    // carry its own sign (2**-1).
    if(have(TokenType::Add)||have(TokenType::Sub)||have(TokenType::Complement)){
        Token op = prev();
        node_ptr operand = power();
        return make_node<UnaryNode>(op, operand);
    }
    node_ptr left = unary();
    if(have(TokenType::Exp)){
        Token op = prev(); op.value = "**"; node_ptr right = power();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::unary(){
    if(have(TokenType::New)){
        // `new` had no parsing rule at all - it fell into the "keyword
        // usable as an identifier" lists (see identifier() and the
        // primary() fallback), so `new A()` parsed as two disconnected
        // fragments: a reference to a nonexistent variable named "new",
        // then an orphaned `A()` the statement parser had to resynchronize
        // past at the next newline. `new A` read the same way, silently
        // discarding "A" entirely.
        //
        // `new A()` and `new A()` should differ from bare `A`/`A()`:
        // `A` alone names the class value itself; `A()` and `new A()` both
        // instantiate; `new A` (no explicit parens) also instantiates, with
        // zero arguments, the same as `A()` - "new" makes instantiation
        // explicit rather than changing what gets built.
        Token new_tok = prev();
        node_ptr target = postfix();
        if(target->type() != NodeType::CALL){
            target = make_node<CallNode>(new_tok, target);
        }
        return target;
    }
    if(have(TokenType::Add)||have(TokenType::Sub)||have(TokenType::Not)||have(TokenType::Complement)
      ||have(TokenType::DoubleAdd)||have(TokenType::DoubleSub)){
        Token op = prev();
        node_ptr operand = unary();
        return make_node<UnaryNode>(op, operand);
    }
    return postfix();
}

node_ptr Parser::postfix(){
    node_ptr expr = primary();
    // Indents consumed to join a continued method chain. The lexer pairs each
    // Indent with a Dedent; since this indent never opened a block, the matching
    // Dedent would otherwise be left for the statement parser, which rejects it.
    int joined_indents = 0;
    // Optional chaining (ASTNodes.hpp, OptChainNode): after `recv?.x`, the
    // steps that follow are parsed onto oc->hole and become oc->rest when
    // the chain ends (or the next `?` link starts a chain around it).
    std::shared_ptr<OptChainNode> oc;
    auto close_chain = [&]() {
        if(!oc) return;
        oc->rest = expr.get() == oc->hole.get() ? nullptr : expr;
        expr = oc;
        oc = nullptr;
    };
    while(true){
        // A method chain may continue on the following line:
        //     [1,2,3]
        //         .filter(...)
        // The lexer emits NewLine and Indent between ']' and '.', which ended
        // the statement. Skip them only when a '.' genuinely follows, so
        // ordinary statement boundaries are unaffected.
        {
            int look = 0;
            while(peek(look).type() == TokenType::NewLine
               || peek(look).type() == TokenType::Indent
               || peek(look).type() == TokenType::Dedent) look++;
            if(look > 0 && (peek(look).type() == TokenType::Dot || peek(look).type() == TokenType::OptDot)){
                for(int k=0;k<look;k++){
                    if(token().type() == TokenType::Indent) joined_indents++;
                    next();
                }
            }
        }
        if(see(TokenType::OptDot) || see(TokenType::OptBracket)){
            // recv?.name  recv?.m(args)  recv?[k]  recv?.[k]  recv?.(args)
            Token qtok = token();
            bool bracket = see(TokenType::OptBracket);
            next();
            close_chain();
            auto node = std::make_shared<OptChainNode>(qtok, expr);
            if(bracket || see(TokenType::BracketOpen)){
                mustBe(TokenType::BracketOpen);
                node_ptr sub = parseSubscriptTail(prev(), node->recv_hole);
                if(sub->type() == NodeType::SUBSCRIPT){
                    node->kind = OptChainNode::INDEX;
                    node->index = std::static_pointer_cast<SubscriptNode>(sub)->index;
                } else {
                    node->kind = OptChainNode::SLICE;
                    node->call = sub;
                }
            } else if(have(TokenType::ParenOpen)){
                auto call = std::make_shared<CallNode>(prev(), node->recv_hole);
                parseCallArgs(call);
                node->kind = OptChainNode::CALL;
                node->call = call;
            } else {
                Token mtok = token();
                std::string attr = memberName();
                if(have(TokenType::ParenOpen)){
                    auto call = std::make_shared<CallNode>(prev(), make_node<AttributeNode>(mtok, node->recv_hole, attr));
                    parseCallArgs(call);
                    node->kind = OptChainNode::METHOD;
                    node->name = attr;
                    node->call = call;
                } else {
                    node->kind = OptChainNode::ATTR;
                    node->name = attr;
                }
            }
            oc = node;
            expr = node->hole;
            continue;
        }
        if(have(TokenType::ParenOpen)){
            // Function call
            Token tok = prev();
            auto call = std::make_shared<CallNode>(tok, expr);
            parseCallArgs(call);
            expr = call;
        } else if(have(TokenType::BracketOpen)){
            // Subscript or slice
            expr = parseSubscriptTail(prev(), expr);
        } else if(have(TokenType::Dot)){
            // Attribute access.
            Token tok = token();
            std::string attr = memberName();
            expr = make_node<AttributeNode>(tok, expr, attr);
        } else if(see(TokenType::DoubleAdd) || see(TokenType::DoubleSub) || see(TokenType::RightArrow)
                  || see(TokenType::Identifier)){
            // Postfix ++/--, an arrow function or a dynamic infix operator
            // applies to the whole optional chain, not to its last step.
            close_chain();
            if(!postfixOther(expr)) break;
        } else break;
    }
    close_chain();
    // Consume the Dedent(s) the lexer paired with the Indent(s) skipped above.
    // Those indents never opened a block, so nothing else will claim them and
    // the statement parser would reject the stray Dedent.
    while(joined_indents > 0){
        if(see(TokenType::Dedent)){ next(); joined_indents--; continue; }
        // The statement's terminating NewLine can sit in front of the Dedent.
        // Consuming it here is safe: statement parsers treat it as optional.
        if(see(TokenType::NewLine) && peek(1).type() == TokenType::Dedent){ next(); continue; }
        break;
    }
    return expr;
}

// The arguments of a call, after its `(`, through the `)`.
void Parser::parseCallArgs(std::shared_ptr<CallNode> call){
    auto parse_call_arg = [&]() -> node_ptr {
        if(have(TokenType::Mul)){
            Token star = prev();
            node_ptr operand = expression();
            return make_node<UnaryNode>(star, operand);
        }
        if(have(TokenType::Exp)){
            Token dstar = prev();
            node_ptr operand = expression();
            return make_node<UnaryNode>(dstar, operand);
        }
        // Keyword argument: name=value (must look ahead before expression() consumes it as assignment)
        // A keyword spelled like a name is still a valid argument name
        // here (`max(xs, default=0)`): no expression starts `default =`.
        auto word_tok = [&](const Token& t) {
            if (t.type() == TokenType::Identifier) return true;
            // any keyword that is a word (fn=, func=, def=: `fn` is a keyword
            // of its own kind, so `f(fn=x)` was a positional argument)
            if (t.clazz() != TokenClass::Keyword || t.value.empty()) return false;
            for (char c : t.value) if (!(std::isalnum((unsigned char)c) || c == '_')) return false;
            return !std::isdigit((unsigned char)t.value[0]);
        };
        if(word_tok(token()) && peek(1).type() == TokenType::Assign
           && peek(2).type() != TokenType::Assign) { // distinguish name=val from name==val
            Token kw_tok = token();
            std::string kw_name = kw_tok.value;
            next(); // consume name
            next(); // consume =
            node_ptr kw_val = expression();
            return make_node<KeywordArgNode>(kw_tok, kw_name, kw_val);
        }
        node_ptr first_expr = expression();
        // Generator expression argument: f(expr for t in it if c ...)
        if(haveCompFor())
            return comprehension(prev(), ComprehensionNode::GEN, first_expr, nullptr);
        return first_expr;
    };
    if(!see(TokenType::ParenClose)){
        call->add(parse_call_arg());
        while(have(TokenType::Comma) && !see(TokenType::ParenClose)){
            call->add(parse_call_arg());
        }
    }
    mustBe(TokenType::ParenClose);
}

// `expr[` ... `]` after its `[` (tok): a SubscriptNode, or a slice as the
// method call expr.slice(start, stop[, step]).
node_ptr Parser::parseSubscriptTail(Token tok, node_ptr expr){
    auto make_int = [&](int v) -> node_ptr {
        Token zt = tok; zt.value = std::to_string(v);
        return make_node<IntegerNode>(zt);
    };
    auto make_none_node = [&]() -> node_ptr {
        Token nt = tok; nt.value = "none";
        return make_node<NoneNode>(nt);
    };
    // Check for [:...] (empty start)
    if(see(TokenType::Colon)) {
        next(); // consume first :
        // An omitted start is none, not 0: s[::-1] starts at the end.
        node_ptr start_expr = make_none_node();
        node_ptr end_expr = nullptr;
        node_ptr step_expr = nullptr;
        if(see(TokenType::Colon)) {
            // [::step]
            next(); // consume second :
            if(!see(TokenType::BracketClose))
                step_expr = expression();
        } else if(!see(TokenType::BracketClose)) {
            end_expr = expression();
            if(have(TokenType::Colon)) {
                // [:end:step]
                if(!see(TokenType::BracketClose))
                    step_expr = expression();
            }
        }
        mustBe(TokenType::BracketClose);
        std::vector<node_ptr> slice_args;
        slice_args.push_back(start_expr);
        if(end_expr) slice_args.push_back(end_expr);
        else if(step_expr) slice_args.push_back(make_none_node());
        if(step_expr) slice_args.push_back(step_expr);
        auto attr = make_node<AttributeNode>(tok, expr, "slice");
        auto call = make_node<CallNode>(tok, attr);
        for(auto& sa : slice_args) call->add(sa);
        return call;
    } else {
        node_ptr index = expression();
        if(have(TokenType::Colon)) {
            // [start:end] or [start:end:step] or [start:]
            node_ptr end_expr = nullptr;
            node_ptr step_expr = nullptr;
            if(!see(TokenType::BracketClose) && !see(TokenType::Colon))
                end_expr = expression();
            if(have(TokenType::Colon)) {
                if(!see(TokenType::BracketClose))
                    step_expr = expression();
            }
            mustBe(TokenType::BracketClose);
            std::vector<node_ptr> slice_args;
            slice_args.push_back(index);
            if(end_expr) slice_args.push_back(end_expr);
            else if(step_expr) slice_args.push_back(make_none_node());
            if(step_expr) slice_args.push_back(step_expr);
            auto attr = make_node<AttributeNode>(tok, expr, "slice");
            auto call = make_node<CallNode>(tok, attr);
            for(auto& sa : slice_args) call->add(sa);
            return call;
        } else {
            // x[a, b]: the index is the tuple (a, b), as in Python (dict
            // keys, numpy-style indices, dict[str, int]) - round 77
            if(see(TokenType::Comma)){
                auto tup = make_node<TupleNode>(tok);
                tup->add(index);
                while(have(TokenType::Comma) && !see(TokenType::BracketClose)) tup->add(expression());
                index = tup;
            }
            mustBe(TokenType::BracketClose);
            return make_node<SubscriptNode>(tok, expr, index);
        }
    }
}

// The name after `.` or `?.`: an identifier, or an operator (1.+(2, 3)).
std::string Parser::memberName(){
    // Attribute access.
    //
    // An OPERATOR is a legal member name here: `1.+(2, 3)` calls the
    // `+` member of 1, which is how an object language with operators as
    // methods should read. Previously identifier() demanded a Name
    // token, so `1.+(2,3)` failed with "Expected Identifier, but found
    // Add" — the operator method could be defined but never called by
    // name.
    std::string attr;
    // Comparisons too (1.<(2, 3)); their tokens do not all carry
    // their spelling, so it comes from the type.
    const char* rel = see(TokenType::Equal) ? "==" : see(TokenType::NotEqual) ? "!="
                    : see(TokenType::Less) ? "<" : see(TokenType::LessEqual) ? "<="
                    : see(TokenType::Great) ? ">" : see(TokenType::GreatEqual) ? ">=" : nullptr;
    if(rel){
        attr = rel;
        next();
    } else if(token().clazz() == TokenClass::Operator
       && !see(TokenType::Dot) && !see(TokenType::ParenOpen)){
        attr = token().value;
        next();
    } else {
        attr = identifier();
    }
    return attr;
}

// Postfix ++ / --, an arrow function (x => body) or a dynamic infix
// operator after `expr`; false when none follows.
bool Parser::postfixOther(node_ptr& expr){
    if(have(TokenType::DoubleAdd)){
        Token tok = prev();
        tok.value = "++";
        expr = make_node<UnaryNode>(tok, expr);
    } else if(have(TokenType::DoubleSub)){
        Token tok = prev();
        tok.value = "--";
        expr = make_node<UnaryNode>(tok, expr);
    } else if(see(TokenType::RightArrow)){
        // Arrow function:  x => body  OR  (params) => body  OR  () => body
        // RightArrow is produced by both  ->  and  =>
        Token arrow_tok = token();
        next(); // consume =>  or  ->
        node_ptr body = expression();
        auto lam = make_node<LambdaNode>(arrow_tok, body);
        // Extract parameters from the left-hand side
        if(expr->type() == NodeType::TUPLE) {
            // (a, b, c) => body  — each element is a param
            auto* tup = static_cast<TupleNode*>(expr.get());
            for(auto& el : tup->elements) lam->add(el);
        } else if(expr->type() == NodeType::VARIABLE) {
            // x => body  — single identifier param
            lam->add(expr);
        }
        // (anything else: zero-param arrow)
        expr = lam;
        return false;   // nothing applies after an arrow function
    } else if(see(TokenType::Identifier)) {
        // ── Dynamic infix operators ────────────────────────────
        // Check for dynamic keyword used as INFIX_OP, or __dynop: symbol
        auto& dynreg2 = nython::DynamicLangRegistry::instance();
        std::string tok_val = token().value;
        std::string infix_name;
        bool is_dyn_infix = false;
        if (nython::is_dyntok_value(tok_val)) {
            std::string dname = nython::decode_dyntok_name(tok_val);
            if (dynreg2.infix_rule_for(dname)) {
                infix_name = dname;
                is_dyn_infix = true;
            }
        } else if (nython::is_dynop_value(tok_val)) {
            std::string dsym = nython::decode_dynop_sym(tok_val);
            auto* dop = dynreg2.find_operator(dsym);
            if (dop && dop->arity == nython::DynamicOperator::Arity::INFIX) {
                infix_name = dsym;
                is_dyn_infix = true;
            }
        }
        if (is_dyn_infix) {
            Token op_tok = token();
            next(); // consume the operator token
            node_ptr rhs = unary(); // parse RHS at unary precedence
            expr = make_node<DynBinopNode>(op_tok, infix_name, expr, rhs);
        } else {
            return false;
        }
    } else return false;
    return true;
}

node_ptr Parser::primary(){
    // `...` where an expression starts is the Ellipsis object (`def f(): ...`,
    // tuple[int, ...], x[..., 0]); between two operands it is the inclusive
    // range a...b.
    if(see(TokenType::Ellipsis)) {
        Token et = token(); next();
        et.value = "Ellipsis";
        return make_node<VariableNode>(et);
    }
    // await expr -> async_await(expr): suspends the current task until the
    // awaitable (coroutine, task, future, sleep, gather, wait_for) is done; a
    // plain value is returned as is. `await` followed by something that cannot
    // start an expression is the ordinary name `await`.
    if(see(TokenType::Await)) {
        TokenType nt = peek().type();
        bool as_name = nt == TokenType::ParenClose || nt == TokenType::Comma || nt == TokenType::NewLine
            || nt == TokenType::Assign || nt == TokenType::BracketClose || nt == TokenType::Colon
            || nt == TokenType::End || nt == TokenType::SemiColon || nt == TokenType::Dot
            || nt == TokenType::Dedent || nt == TokenType::BraceClose;
        if(!as_name) {
            Token at = token(); next();
            node_ptr operand = unary();
            at.value = "async_await";
            auto call = make_node<CallNode>(at, make_node<VariableNode>(at));
            call->add(operand);
            return call;
        }
        Token nt_tok = token(); next();
        return make_node<VariableNode>(nt_tok);
    }
    // Handle typeof/sizeof as identifiers that resolve to builtins
    if(see(TokenType::Typeof)||see(TokenType::Sizeof)) {
        Token tok = token();
        tok.value = (tok.value == "typeof") ? "type" : "len";
        next();
        return make_node<VariableNode>(tok);
    }
    return atom();
}

// An f-string: literal text and {expr[!conv][:spec]} fields, joined with +.
// Each field becomes __format_value__(expr, spec, conv) - one builtin on both
// engines that applies the conversion (!r/!s/!a) and the format spec with
// Python's semantics; a spec may itself contain {fields}. Both used to be
// dropped: f"{x:.2f}" printed x unformatted and f"{s!r}" printed s.
node_ptr Parser::fstringNode(const Token& str_tok, const std::string& raw){
    std::vector<node_ptr> parts;
    std::string current;
    auto lit = [&](const std::string& text) {
        Token ltok = str_tok; ltok.value = text;
        return make_node<StringNode>(ltok);
    };
    size_t fi = 0;
    while (fi < raw.size()) {
        if (raw[fi] == '{' && fi + 1 < raw.size() && raw[fi+1] != '{') {
            if (!current.empty()) { parts.push_back(lit(current)); current.clear(); }
            fi++;
            // The field runs to the matching '}' (nested braces, brackets
            // and quoted strings inside the expression are skipped over).
            std::string field;
            int depth = 1;
            char quote = 0;
            while (fi < raw.size()) {
                char c = raw[fi];
                if (quote) { if (c == quote) quote = 0; }
                else if (c == '\'' || c == '"') quote = c;
                else if (c == '{' || c == '[' || c == '(') depth++;
                else if (c == ']' || c == ')') depth--;
                else if (c == '}') { depth--; if (depth == 0) break; }
                field += c; fi++;
            }
            if (fi < raw.size()) fi++;   // the closing '}'
            // Split expr / !conv / :spec at the top level.
            size_t k = 0; int lvl = 0; quote = 0;
            std::string expr_str, conv, spec;
            bool has_spec = false;
            for (; k < field.size(); k++) {
                char c = field[k];
                if (quote) { if (c == quote) quote = 0; continue; }
                if (c == '\'' || c == '"') { quote = c; continue; }
                if (c == '(' || c == '[' || c == '{') lvl++;
                else if (c == ')' || c == ']' || c == '}') lvl--;
                else if (lvl == 0 && c == '!' && k + 1 < field.size() && field[k+1] != '=' &&
                         (k + 2 >= field.size() || field[k+2] == ':')) break;
                else if (lvl == 0 && c == ':') break;
            }
            expr_str = field.substr(0, k);
            if (k < field.size() && field[k] == '!') {
                conv = field.substr(k + 1, 1);
                k += 2;
            }
            if (k < field.size() && field[k] == ':') { spec = field.substr(k + 1); has_spec = true; }
            // {expr=} (Python 3.8): the expression's text, '=', then its
            // repr - or str/format when a conversion or spec is given.
            {
                size_t e = expr_str.find_last_not_of(" \t");
                if (e != std::string::npos && expr_str[e] == '=' && e > 0) {
                    char before = expr_str[e - 1];
                    if (before != '=' && before != '!' && before != '<' && before != '>') {
                        current += expr_str;
                        if (!current.empty()) { parts.push_back(lit(current)); current.clear(); }
                        expr_str = expr_str.substr(0, e);
                        if (conv.empty() && !has_spec) conv = "r";
                    }
                }
            }
            if (expr_str.empty()) continue;
            node_ptr expr_node;
            try {
                reader::SourceCode sub_src(expr_str);
                nython::exception::Reporter sub_reporter(sub_src);
                auto sub_lex = std::make_shared<Lexer>(sub_src);
                sub_lex->tokenize();
                Parser sub_parser(&sub_reporter, runner, sub_lex.get());
                expr_node = sub_parser.expression();
            } catch(...) {
                Token vtok = str_tok; vtok.value = expr_str;
                expr_node = make_node<VariableNode>(vtok);
            }
            Token sfn = str_tok; sfn.value = "__format_value__";
            auto call = make_node<CallNode>(str_tok, make_node<VariableNode>(sfn));
            call->add(expr_node);
            call->add(has_spec && spec.find('{') != std::string::npos ? fstringNode(str_tok, spec) : lit(spec));
            call->add(lit(conv));
            parts.push_back(call);
        } else if (raw[fi] == '{' && fi + 1 < raw.size() && raw[fi+1] == '{') {
            current += '{'; fi += 2;
        } else if (raw[fi] == '}' && fi + 1 < raw.size() && raw[fi+1] == '}') {
            current += '}'; fi += 2;
        } else { current += raw[fi]; fi++; }
    }
    if (!current.empty()) parts.push_back(lit(current));
    if (parts.empty()) return lit("");
    node_ptr result = parts[0];
    // A single field still yields a string.
    if (parts.size() == 1 && result->type() != NodeType::STRING) {
        Token op_tok = str_tok; op_tok.value = "+";
        return make_node<BinaryNode>(op_tok, lit(""), result);
    }
    for (size_t pi = 1; pi < parts.size(); pi++) {
        Token op_tok = str_tok; op_tok.value = "+";
        result = make_node<BinaryNode>(op_tok, result, parts[pi]);
    }
    return result;
}

node_ptr Parser::atom(){
    Token tok = token();

    // Literals
    if(have(TokenType::Integer)) return make_node<IntegerNode>(prev());
    if(have(TokenType::Float)||have(TokenType::Float)) return make_node<FloatNode>(prev());
    if(have(TokenType::String)||have(TokenType::String)||have(TokenType::String)
      ||have(TokenType::String)||have(TokenType::String)) {
        Token str_tok = prev();
        // Backtick template literal:  `hello ${name}`  →  treat like f-string with ${} → {}
        // Check if string contains ${...} markers (set by lexer converting ${ → \x02 or left raw)
        // We detect raw ${  in the stored string value and process as interpolation
        std::string& sv = str_tok.value;
        bool has_interp = sv.find("${") != std::string::npos;
        if(has_interp) {
            // Convert ${expr} → same pipeline as f-string {expr}
            // Replace ${ with { for re-use of f-string parser below
            std::string converted;
            for(size_t ti = 0; ti < sv.size(); ti++) {
                if(sv[ti] == '$' && ti+1 < sv.size() && sv[ti+1] == '{') {
                    converted += '{'; ti++; // skip '$', next char is '{'
                } else converted += sv[ti];
            }
            str_tok.value = converted;
            sv = str_tok.value;
            // Fall through to f-string parsing below
            goto parse_fstring;
        }
        return make_node<StringNode>(str_tok);
        parse_fstring:
            return fstringNode(str_tok, str_tok.value);
    }
    if(have(TokenType::Bytes)) {
        // adjacent bytes literals join, as in Python: b"a" b"b" == b"ab"
        Token bt = prev();
        while(have(TokenType::Bytes)) bt.value += prev().value;
        return make_node<BytesNode>(bt);
    }
    // An imaginary literal, 2j / 1.5J: complex(0, 2.0) (round 77; it read none)
    if(have(TokenType::Complex)){
        Token ct = prev();
        std::string num = ct.value;
        if(!num.empty() && (num.back() == 'j' || num.back() == 'J')) num.pop_back();
        if(num.find('.') == std::string::npos && num.find('e') == std::string::npos && num.find('E') == std::string::npos) num += ".0";
        Token ft = ct; ft.value = "complex";
        auto call = make_node<CallNode>(ct, make_node<VariableNode>(ft));
        Token zt = ct; zt.value = "0"; zt.type(TokenType::Integer);
        call->add(make_node<IntegerNode>(zt));
        Token nt = ct; nt.value = num; nt.type(TokenType::Float);
        call->add(make_node<FloatNode>(nt));
        return call;
    }
    if(have(TokenType::True)) return make_node<BoolNode>(prev(), true);
    if(have(TokenType::False)) return make_node<BoolNode>(prev(), false);
    if(have(TokenType::None)||have(TokenType::None)||have(TokenType::None)) return make_node<NoneNode>(prev());
    if(have(TokenType::Undefined)) return make_node<UndefinedNode>(prev());
    if(have(TokenType::Ellipsis)) {
        // `...` → a special "ellipsis" singleton value; represent as a string "..."
        Token et = prev(); et.value = "...";
        return make_node<StringNode>(et);
    }

    // Self/Super
    if(have(TokenType::Self)||have(TokenType::This)) return make_node<SelfNode>(prev());
    if(have(TokenType::Super)) return make_node<SuperNode>(prev());

    // Identifier (includes f-string detection)
    if(have(TokenType::Identifier)) {
        Token id_tok = prev();
        // F-string: f"hello {expr}"
        if (id_tok.value == "f" && (see(TokenType::String) || token().kind() == TokenKind::String)) {
            Token str_tok = token();
            next(); // consume the string
            return fstringNode(str_tok, str_tok.value);
        }
        auto vn = std::make_shared<VariableNode>(id_tok);
        if(!global_decls_.empty()){
            auto& g = global_decls_.back();
            vn->global_ref = std::find(g.begin(), g.end(), id_tok.value) != g.end();
        }
        return vn;
    }

    // Lambda: lambda params: body  OR  fn(params) => body
    if(see(TokenType::Lambda)) return lambdaExpr();

    // Parenthesized expression or tuple
    if(have(TokenType::ParenOpen)){
        if(have(TokenType::ParenClose)) return make_node<TupleNode>(tok); // empty tuple
        // Walrus operator: (var name = expr)
        if(see(TokenType::Var) && peek(1).type()==TokenType::Identifier && peek(2).type()==TokenType::Assign) {
            next(); // consume 'var'
            std::string wname = identifier();
            mustBe(TokenType::Assign);
            node_ptr init = expression();
            mustBe(TokenType::ParenClose);
            return make_node<WalrusNode>(tok, wname, init);
        }
        node_ptr expr = starElem();
        // Standalone generator expression: (expr for t in it if c ...)
        if(!isStarElem(expr) && haveCompFor()){
            node_ptr comp = comprehension(tok, ComprehensionNode::GEN, expr, nullptr);
            mustBe(TokenType::ParenClose);
            return comp;
        }
        if(have(TokenType::Comma)){
            // Tuple
            auto tuple = make_node<TupleNode>(tok);
            tuple->add(expr);
            bool starred = isStarElem(expr);
            if(!see(TokenType::ParenClose)){
                node_ptr e = starElem();
                starred = starred || isStarElem(e);
                tuple->add(e);
                while(have(TokenType::Comma)&&!see(TokenType::ParenClose)){
                    node_ptr e2 = starElem();
                    starred = starred || isStarElem(e2);
                    tuple->add(e2);
                }
            }
            mustBe(TokenType::ParenClose);
            if(starred && !in_assign_target_) return catStarred(tok, tuple->statements(), "tuple");
            return tuple;
        }
        if(isStarElem(expr)) throw SyntaxError(tok.location(), "cannot use starred expression here");
        mustBe(TokenType::ParenClose);
        return expr;
    }

    // List literal [a, b, c]
    if(see(TokenType::BracketOpen)) return listLiteral();

    // Map literal {k: v, ...}
    if(see(TokenType::BraceOpen)) return mapLiteral();

    // Keywords used as identifiers (variable references)
    // In Nython, everything is an object - any identifier-like token can name a variable
    {
        TokenType t = tok.type();
        if(t == TokenType::EndBlock || t == TokenType::Fn
           || t == TokenType::Function || t == TokenType::New
           || t == TokenType::Try || t == TokenType::Except
           || t == TokenType::Finally || t == TokenType::Break || t == TokenType::Continue
           || t == TokenType::Return || t == TokenType::If || t == TokenType::Else
           || t == TokenType::For || t == TokenType::While || t == TokenType::Do
           || t == TokenType::Switch || t == TokenType::Case || t == TokenType::Def
           || t == TokenType::Class || t == TokenType::Enum
           || t == TokenType::Not || t == TokenType::And
           || t == TokenType::Or || t == TokenType::Xor
           || t == TokenType::Lambda || t == TokenType::Then
           || t == TokenType::Extends || t == TokenType::Inherits
           || t == TokenType::Implements || t == TokenType::NameSpace
           || t == TokenType::Package || t == TokenType::Interface || t == TokenType::Struct
           || t == TokenType::Repeat || t == TokenType::Execute || t == TokenType::Delete
           || t == TokenType::Default || t == TokenType::Final || t == TokenType::Loop
           || t == TokenType::Block || t == TokenType::Use || t == TokenType::Global
           || t == TokenType::Static || t == TokenType::Public || t == TokenType::Private
           || t == TokenType::Protected || t == TokenType::Abstract || t == TokenType::Super
           || t == TokenType::Import || t == TokenType::From || t == TokenType::As
           || t == TokenType::Is || t == TokenType::In || t == TokenType::Print
           || t == TokenType::Typeof || t == TokenType::Sizeof || t == TokenType::Yield
           || t == TokenType::Raise || t == TokenType::Pass || t == TokenType::Assert
           || t == TokenType::With || t == TokenType::Ref || t == TokenType::Let
           || t == TokenType::Var || t == TokenType::Const) {
            next();
            Token id_tok = prev();
            return make_node<VariableNode>(id_tok);
        }
    }

    // If we got here, unexpected token — error
    throw SyntaxError(tok.location(), "Unexpected token: " + tok.value);
    return nullptr;
}

// ═══════════════════════════════════════════════════════════════════════════
// STATEMENT IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════════════════

node_ptr Parser::varDecl(bool is_const, bool is_let){
    Token tok = token();
    next(); // consume var/let/const
    
    // Handle nested tuple unpacking: var (a, b), c = ...
    if (see(TokenType::ParenOpen)) {
        // Parse `(name1, name2, ...), more_names = rhs`
        std::vector<std::string> names;
        std::vector<int> nested_starts;  // groups: index -> count of sub-names
        // Parse first group
        next(); // consume (
        nested_starts.push_back((int)names.size());
        int group_start = (int)names.size();
        while (!see(TokenType::ParenClose) && !see(TokenType::End)) {
            if (see(TokenType::Mul)) { next(); names.push_back("*" + identifier()); }
            else names.push_back(identifier());
            have(TokenType::Comma);
        }
        int group_size = (int)names.size() - group_start;
        mustBe(TokenType::ParenClose);
        std::string group_tmp = "__ng" + std::to_string(group_start) + "__";
        // After ), check for more names
        while (have(TokenType::Comma)) {
            names.push_back(identifier());
        }
        // Now parse = rhs
        auto block = make_node<BlockNode>(tok);
        if (have(TokenType::Assign)) {
            std::vector<node_ptr> vals;
            vals.push_back(expression());
            while (have(TokenType::Comma)) vals.push_back(expression());
            // Build outer unpack: n_outer = group_tmp (placeholder) + rest
            // The group_tmp covers a sub-tuple at position 0
            // Outer names: group_tmp, names[group_size], names[group_size+1], ...
            std::vector<std::string> outer_names;
            outer_names.push_back(group_tmp);
            for (int i = group_size; i < (int)names.size(); i++)
                outer_names.push_back(names[i]);
            // Perform outer unpack from vals
            if (vals.size() == 1) {
                std::string outer_src = "__outer_src__";
                {
                    auto decl = make_node<VarDeclNode>(tok, outer_src, vals[0], false, false);
                    static_cast<VarDeclNode*>(decl.get())->unpack = (int)outer_names.size();
                    block->add(decl);
                }
                for (int i = 0; i < (int)outer_names.size(); i++) {
                    Token tmp_tok = tok; tmp_tok.value = outer_src;
                    auto tmp_var = make_node<VariableNode>(tmp_tok);
                    Token idx_tok = tok; idx_tok.value = std::to_string(i);
                    auto idx_node = make_node<IntegerNode>(idx_tok);
                    auto subscript = make_node<SubscriptNode>(tok, tmp_var, idx_node);
                    block->add(make_node<VarDeclNode>(tok, outer_names[i], subscript, is_const, is_let));
                }
            } else {
                // Multiple RHS values
                for (int i = 0; i < (int)outer_names.size() && i < (int)vals.size(); i++)
                    block->add(make_node<VarDeclNode>(tok, outer_names[i], vals[i], is_const, is_let));
            }
            // Now unpack group_tmp into names[0..group_size-1]
            for (int i = 0; i < group_size; i++) {
                Token tmp_tok = tok; tmp_tok.value = group_tmp;
                auto tmp_var = make_node<VariableNode>(tmp_tok);
                Token idx_tok = tok; idx_tok.value = std::to_string(i);
                auto idx_node = make_node<IntegerNode>(idx_tok);
                auto subscript = make_node<SubscriptNode>(tok, tmp_var, idx_node);
                block->add(make_node<VarDeclNode>(tok, names[i], subscript, is_const, is_let));
            }
        }
        have(TokenType::SemiColon);
        return block;
    }

    // Handle starred first variable: var *head, last = ...
    bool first_is_star = false;
    if (see(TokenType::Mul)) {
        next(); // consume *
        first_is_star = true;
    }
    std::string name = (first_is_star ? "*" : "") + identifier();
    
    // Check for multi-assignment: var a, b = 1, 2  OR var first, *rest = list
    if(see(TokenType::Comma)) {
        std::vector<std::string> names;
        names.push_back(name);
        int star_idx = first_is_star ? 0 : -1;  // index of *rest variable, -1 if none
        while(have(TokenType::Comma)) {
            if(see(TokenType::Mul)) {
                next(); // consume *
                star_idx = (int)names.size();
                names.push_back("*" + identifier());
            } else {
                names.push_back(identifier());
            }
        }
        // Parse = and comma-separated values
        auto block = make_node<BlockNode>(tok);
        if(have(TokenType::Assign)) {
            std::vector<node_ptr> vals;
            vals.push_back(expression());
            while(have(TokenType::Comma)) vals.push_back(expression());
            if (vals.size() == 1 && names.size() > 1) {
                // Single RHS -> list unpacking: var a, b = func()
                std::string tmp = "__unpack_src__";
                // Find star index
                int si = -1;
                for(size_t k=0;k<names.size();k++) if(!names[k].empty()&&names[k][0]=='*') { si=(int)k; break; }
                {
                    auto decl = make_node<VarDeclNode>(tok, tmp, vals[0], false, false);
                    static_cast<VarDeclNode*>(decl.get())->unpack = si < 0 ? (int)names.size() : -1;
                    block->add(decl);
                }
                if(si < 0) {
                    // No star: straight index assignment
                    for(size_t i = 0; i < names.size(); i++) {
                        Token tmp_tok = tok; tmp_tok.value = tmp;
                        auto tmp_var = make_node<VariableNode>(tmp_tok);
                        Token idx_tok = tok; idx_tok.value = std::to_string(i);
                        auto idx_node = make_node<IntegerNode>(idx_tok);
                        auto subscript = make_node<SubscriptNode>(tok, tmp_var, idx_node);
                        block->add(make_node<VarDeclNode>(tok, names[i], subscript, is_const, is_let));
                    }
                } else {
                    // Star unpack: first si vars get indices 0..si-1
                    // *star gets slice si..-(names.size()-si-1)
                    // trailing vars get indices from the end
                    int n_after = (int)names.size() - si - 1;
                    for(int i = 0; i < si; i++) {
                        Token tmp_tok = tok; tmp_tok.value = tmp;
                        auto tmp_var = make_node<VariableNode>(tmp_tok);
                        Token idx_tok = tok; idx_tok.value = std::to_string(i);
                        auto idx_node = make_node<IntegerNode>(idx_tok);
                        auto subscript = make_node<SubscriptNode>(tok, tmp_var, idx_node);
                        block->add(make_node<VarDeclNode>(tok, names[i], subscript, is_const, is_let));
                    }
                    // Star variable gets slice(si, -n_after or end)
                    {
                        Token tmp_tok = tok; tmp_tok.value = tmp;
                        auto tmp_var = make_node<VariableNode>(tmp_tok);
                        // Use slice node: tmp[si:-n_after] or tmp[si:]
                        auto start_n = make_node<IntegerNode>(tok); start_n->token().value = std::to_string(si);
                        // Emit a call to slice method: tmp.slice(si, len-n_after)
                        // Generate: var star_name = __unpack_src__.slice(si) or .slice(si, -n_after)
                        std::string star_name = names[si].substr(1); // strip *
                        auto tmp_var2 = make_node<VariableNode>(tmp_tok);
                        auto slice_attr = make_node<AttributeNode>(tok, tmp_var2, "slice");
                        auto slice_call = make_node<CallNode>(tok, slice_attr);
                        Token si_tok=tok; si_tok.value=std::to_string(si); si_tok.type(TokenType::Integer);
                        slice_call->add(make_node<IntegerNode>(si_tok));
                        if(n_after > 0) {
                            Token ne_tok = tok; ne_tok.value = std::to_string(-n_after); ne_tok.type(TokenType::Integer);
                            slice_call->add(make_node<IntegerNode>(ne_tok));
                        }
                        block->add(make_node<VarDeclNode>(tok, star_name, slice_call, is_const, is_let));
                    }
                    // Trailing variables get indices from the end
                    for(int i = 0; i < n_after; i++) {
                        Token tmp_tok = tok; tmp_tok.value = tmp;
                        auto tmp_var = make_node<VariableNode>(tmp_tok);
                        // Index = -(n_after - i)
                        Token idx_tok = tok; idx_tok.value = std::to_string(-(n_after - i)); idx_tok.type(TokenType::Integer);
                        auto idx_node = make_node<IntegerNode>(idx_tok);
                        auto subscript = make_node<SubscriptNode>(tok, tmp_var, idx_node);
                        block->add(make_node<VarDeclNode>(tok, names[si+1+i], subscript, is_const, is_let));
                    }
                }
            } else {
                for(size_t i = 0; i < names.size(); i++) {
                    node_ptr init = (i < vals.size()) ? vals[i] : nullptr;
                    block->add(make_node<VarDeclNode>(tok, names[i], init, is_const, is_let));
                }
            }
        } else {
            for(auto& n : names)
                block->add(make_node<VarDeclNode>(tok, n, nullptr, is_const, is_let));
        }
        have(TokenType::SemiColon); have(TokenType::NewLine);
        return block;
    }
    
    node_ptr init = nullptr;
    if(have(TokenType::Assign)) init = expression();
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<VarDeclNode>(tok, name, init, is_const, is_let);
}

node_ptr Parser::ifStmt(){
    Token tok = token();
    mustBe(TokenType::If);
    // Python style: if cond:  OR  C style: if(cond){  OR walrus: if(var n = expr):
    //
    // The opening paren is only consumed for the walrus form. It used to be
    // consumed unconditionally, after which expression() stopped at the closing
    // paren and mustBe(ParenClose) ran, so anything following the group was a
    // syntax error:
    //     if (a > 0) or (b < 5):   ->  Unexpected token: :
    // Leaving the paren for expression() lets it parse the whole condition,
    // parenthesised sub-groups and all.
    bool walrus_form = see(TokenType::ParenOpen)
                    && peek(1).type()==TokenType::Var
                    && peek(2).type()==TokenType::Identifier
                    && peek(3).type()==TokenType::Assign;
    bool has_paren = false;
    if(walrus_form) has_paren = have(TokenType::ParenOpen);
    node_ptr cond;
    // Walrus operator inside if: if (var name = expr): OR if (var n = expr) > val:
    if(has_paren && see(TokenType::Var) && peek(1).type()==TokenType::Identifier && peek(2).type()==TokenType::Assign) {
        next(); // consume 'var'
        std::string wname = identifier();
        mustBe(TokenType::Assign);
        node_ptr init = expression();
        mustBe(TokenType::ParenClose);
        node_ptr walrus = make_node<WalrusNode>(tok, wname, init);
        has_paren = false; // paren already consumed
        // Check for trailing comparison: (var n = expr) > val, >= val, == val, etc.
        auto tt = token().type();
        if (tt == TokenType::Great     || tt == TokenType::GreatEqual  ||
            tt == TokenType::Less      || tt == TokenType::LessEqual   ||
            tt == TokenType::Equal     || tt == TokenType::NotEqual    ||
            tt == TokenType::And       || tt == TokenType::Or) {
            Token op_tok = token(); next();
            node_ptr rhs = expression();
            cond = make_node<BinaryNode>(op_tok, walrus, rhs);
        } else {
            cond = walrus;
        }
    } else {
        cond = expression();
        if(has_paren) mustBe(TokenType::ParenClose);
    }
    have(TokenType::Colon); have(TokenType::Then);
    node_ptr then_b = blockOrStmt();
    auto node = make_node<IfNode>(tok, cond, then_b);
    auto if_node = std::static_pointer_cast<IfNode>(node);

    // Else-if chains
    while(have(TokenType::NewLine)) {}
    while(have(TokenType::ElseIf)||have(TokenType::ElseIf)||(see(TokenType::Else)&&peek().type()==TokenType::If)){
        if(prev().type()==TokenType::Else) next(); // consume 'if'
        // Same rule as the if-condition above: let expression() own the parens.
        node_ptr eicond = expression();
        have(TokenType::Colon);
        node_ptr eibody = blockOrStmt();
        if_node->elseif_branches.push_back(make_node<IfNode>(tok, eicond, eibody));
        while(have(TokenType::NewLine)) {}
    }

    // Else
    if(have(TokenType::Else)){
        have(TokenType::Colon);
        if_node->else_branch = blockOrStmt();
    }
    return node;
}

node_ptr Parser::whileStmt(){
    Token tok = token();
    mustBe(TokenType::While);
    // The paren is consumed only for the walrus form `while (var n = e)`;
    // otherwise it belongs to the condition, as for `if`: `while (a) < 3:`
    // was a syntax error.
    bool walrus_form = see(TokenType::ParenOpen)
                    && peek(1).type()==TokenType::Var
                    && peek(2).type()==TokenType::Identifier
                    && peek(3).type()==TokenType::Assign;
    bool hp = walrus_form && have(TokenType::ParenOpen);
    node_ptr cond;
    // Walrus operator inside while: while (var name = expr) != 0:
    if(hp && see(TokenType::Var) && peek(1).type()==TokenType::Identifier && peek(2).type()==TokenType::Assign) {
        next(); // consume 'var'
        std::string wname = identifier();
        mustBe(TokenType::Assign);
        node_ptr init = expression();
        mustBe(TokenType::ParenClose);
        node_ptr walrus = make_node<WalrusNode>(tok, wname, init);
        hp = false; // paren already consumed
        // Check for trailing comparison: (var n = expr) != 0, > val, etc.
        auto tt = token().type();
        if (tt == TokenType::Great     || tt == TokenType::GreatEqual  ||
            tt == TokenType::Less      || tt == TokenType::LessEqual   ||
            tt == TokenType::Equal     || tt == TokenType::NotEqual    ||
            tt == TokenType::And       || tt == TokenType::Or) {
            Token op_tok = token(); next();
            node_ptr rhs = expression();
            cond = make_node<BinaryNode>(op_tok, walrus, rhs);
        } else {
            cond = walrus;
        }
    } else {
        cond = expression();
        if(hp) mustBe(TokenType::ParenClose);
    }
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    return make_node<WhileNode>(tok, cond, body);
}

node_ptr Parser::forStmt(){
    Token tok = token();
    mustBe(TokenType::For);
    bool hp = have(TokenType::ParenOpen);
    // Check for C-style: for (init; cond; step) body
    // Detect by looking ahead: if next is 'var' or identifier followed by '='
    if(hp && (see(TokenType::Var) || (see(TokenType::Identifier) && peek().type()==TokenType::Assign))) {
        // C-style for loop
        node_ptr init_stmt = statement(); // var i = 0 or i = 0
        have(TokenType::SemiColon); // consume optional ; between init and cond
        node_ptr cond = expression();
        have(TokenType::SemiColon); // consume optional ; between cond and step
        node_ptr step = statement(); // i += 1 or i = i + 1
        mustBe(TokenType::ParenClose);
        have(TokenType::Colon);
        node_ptr body_node = blockOrStmt();
        // Desugar to: { init; while (cond) { body; step; } }
        auto block = make_node<BlockNode>(tok);
        block->add(init_stmt);
        // Build while body: body + step
        auto while_body = make_node<BlockNode>(tok);
        while_body->add(body_node);
        while_body->add(step);
        auto while_node = make_node<WhileNode>(tok, cond, while_body);
        block->add(while_node);
        return block;
    }
    node_ptr var = make_node<VariableNode>(token());
    auto mark_global = [&](const node_ptr& v) {
        if(global_decls_.empty()) return;
        auto& g = global_decls_.back();
        static_cast<VariableNode*>(v.get())->global_ref = std::find(g.begin(), g.end(), v->value()) != g.end();
    };
    mark_global(var);
    next(); // consume variable name
    // Check for tuple unpacking: for k, v in ...
    std::vector<node_ptr> unpack_vars;
    while(have(TokenType::Comma)) {
        unpack_vars.push_back(make_node<VariableNode>(token()));
        mark_global(unpack_vars.back());
        next();
    }
    mustBe(TokenType::In);
    node_ptr iter = expression();
    if(hp) mustBe(TokenType::ParenClose);
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    auto fnode = make_node<ForNode>(tok, var, iter, body);
    if(!outer_decls_.empty()){
        auto& d = outer_decls_.back();
        auto declared = [&](const std::string& n){ return std::find(d.begin(), d.end(), n) != d.end(); };
        bool rb = declared(var->value());
        for(auto& u : unpack_vars) rb = rb || declared(u->value());
        static_cast<ForNode*>(fnode.get())->rebinds = rb;
    }
    static_cast<ForNode*>(fnode.get())->unpack_vars = std::move(unpack_vars);
    return fnode;
}

// ── async def ────────────────────────────────────────────────────────────────
// Both engines run coroutines through the shared runtime (src/NyConc.cpp), so
// `async def` needs no engine support. It desugars to a gate at the top of the
// body:
//
//     async def f(a, b=1, *rest, k=2, **kw):
//         body
//   ==>
//     def f(a, b=1, *rest, k=2, **kw):
//         if async_body_begin():
//             return async_coroutine_def(lambda: f(a, b, *rest, k=k, **kw), "f")
//         body
//
// Calling f binds the arguments as usual and returns a coroutine holding a
// closure over them. When the coroutine runs, the runtime sets a per-thread
// token and calls the closure, which calls f again with the same arguments -
// keyword-only ones and **kw as keywords (round 77: they were dropped, and a
// bare `*` raised NameError); async_body_begin() consumes the token and the
// body executes. Methods (first parameter self/this) refer to themselves as
// self.name, so the coroutine holds the bound method.
//
// An `async def` whose body yields is an async generator (round 77):
//
//     async def g(a):                     def g(a):
//         body (yield ...)       ==>          def _ny_agen_body(a):
//                                                 body
//                                             return _ny_async_gen(_ny_agen_body(a))
//
// The body is an ordinary generator whose awaits suspend the task iterating
// it; _ny_async_gen (NyPrelude.hpp) gives it __aiter__/__anext__/asend/
// athrow/aclose, so `async for`, anext() and the asyncio library drive it.

// Adds f's parameters to `call` as the arguments that rebind them: positional
// ones by position, *rest spread, the keyword-only ones (after `*` or *rest)
// as keywords, **kw spread as keywords.
static void forward_params(const Token& t, CallNode* call, const std::vector<node_ptr>& params, size_t from) {
    auto name_tok = [&](const std::string& v) { Token x = t; x.value = v; return x; };
    bool kwonly = false;
    for (size_t i = from; i < params.size(); i++) {
        std::string pn = params[i]->value();
        if (pn == "*") { kwonly = true; continue; }
        if (pn.rfind("**", 0) == 0) {
            call->add(make_node<UnaryNode>(name_tok("**"), make_node<VariableNode>(name_tok(pn.substr(2)))));
        } else if (pn.rfind("*", 0) == 0) {
            call->add(make_node<UnaryNode>(name_tok("*"), make_node<VariableNode>(name_tok(pn.substr(1)))));
            kwonly = true;
        } else if (kwonly) {
            call->add(make_node<KeywordArgNode>(name_tok(pn), pn, make_node<VariableNode>(name_tok(pn))));
        } else {
            call->add(make_node<VariableNode>(name_tok(pn)));
        }
    }
}

static node_ptr async_def_desugar(const Token& tok, node_ptr fn, bool is_generator) {
    auto* f = static_cast<FunctionNode*>(fn.get());
    Token t = tok;
    auto name_tok = [&](const std::string& v) { Token x = t; x.value = v; return x; };
    if (is_generator) {
        Token bt = name_tok("_ny_agen_body");
        auto inner = make_node<FunctionNode>(bt, "_ny_agen_body", f->body, false);
        auto* in = static_cast<FunctionNode*>(inner.get());
        for (auto& p : f->params) in->add(p);
        in->defaults.assign(f->params.size(), nullptr);
        auto call = make_node<CallNode>(bt, make_node<VariableNode>(bt));
        forward_params(t, static_cast<CallNode*>(call.get()), f->params, 0);
        Token wt = name_tok("_ny_async_gen");
        auto wrap = make_node<CallNode>(wt, make_node<VariableNode>(wt));
        wrap->add(call);
        auto body = make_node<BlockNode>(t);
        body->add(inner);
        body->add(make_node<ReturnNode>(t, wrap));
        f->body = body;
        return fn;
    }
    bool method = !f->params.empty() &&
        (f->params[0]->value() == "self" || f->params[0]->value() == "this");
    node_ptr ref;
    if (method) ref = make_node<AttributeNode>(name_tok(f->name), make_node<SelfNode>(name_tok("self")), f->name);
    else ref = make_node<VariableNode>(name_tok(f->name));
    auto again = make_node<CallNode>(t, ref);
    forward_params(t, static_cast<CallNode*>(again.get()), f->params, method ? 1 : 0);
    auto closure = make_node<LambdaNode>(name_tok("lambda"), again);
    Token mk = name_tok("async_coroutine_def");
    auto make = make_node<CallNode>(mk, make_node<VariableNode>(mk));
    make->add(closure);
    make->add(make_node<StringNode>(name_tok(f->name)));
    Token bt = name_tok("async_body_begin");
    auto begin = make_node<CallNode>(bt, make_node<VariableNode>(bt));
    auto then_blk = make_node<BlockNode>(t);
    then_blk->add(make_node<ReturnNode>(t, make));
    auto guard = make_node<IfNode>(t, begin, then_blk);
    auto body = make_node<BlockNode>(t);
    body->add(guard);
    if (f->body) {
        if (f->body->type() == NodeType::BLOCK) for (auto& st : f->body->statements()) body->add(st);
        else body->add(f->body);
    }
    f->body = body;
    return fn;
}

node_ptr Parser::functionDecl(bool is_method){
    bool is_async = s_async_def_next;
    s_async_def_next = false;
    Token tok = token();
    next(); // consume def/function/fn
    std::string name = identifier();
    std::vector<node_ptr> params;
    if(see(TokenType::ParenOpen)) {
        next(); // consume (
        param_ann_.clear();
        params = paramList();
        mustBe(TokenType::ParenClose);
    } else param_ann_.clear();
    size_t posonly = param_posonly_;   // the body's own functions reset it
    auto fn_ann = std::move(param_ann_);
    param_ann_.clear();
    // `-> T`: the return annotation
    if(have(TokenType::RightArrow)) {
        int a0 = scanner->current;
        node_ptr r = ternary();
        fn_ann.push_back({"return", annotationValue(r, a0, scanner->current)});
    }
    have(TokenType::Colon);
    outer_decls_.emplace_back();
    global_decls_.emplace_back();
    auto saved_defaults = std::move(param_defaults_);
    yield_seen_.push_back(false);
    ann_scope_.push_back('f');
    node_ptr body = blockOrStmt();
    ann_scope_.pop_back();
    bool is_gen = yield_seen_.back();
    yield_seen_.pop_back();
    param_defaults_ = std::move(saved_defaults);
    outer_decls_.pop_back();
    global_decls_.pop_back();
    auto fn = make_node<FunctionNode>(tok, name, body, is_method);
    {
        auto* fnp = static_cast<FunctionNode*>(fn.get());
        fnp->has_doc = docstringOf(body, fnp->doc);
    }
    for(auto& p : params) fn->add(p);
    static_cast<FunctionNode*>(fn.get())->defaults = std::move(param_defaults_);
    static_cast<FunctionNode*>(fn.get())->posonly = posonly;
    if(!fn_ann.empty()){
        // f.__annotations__: {"param": ann, ..., "return": ann}
        auto m = make_node<MapNode>(tok);
        for(auto& [k, v] : fn_ann){
            Token kt = tok; kt.value = k;
            m->add(make_node<MapEntryNode>(tok, make_node<StringNode>(kt), v));
        }
        static_cast<FunctionNode*>(fn.get())->annotations = m;
    }
    if(is_async) return async_def_desugar(tok, fn, is_gen);
    return fn;
}


std::vector<node_ptr> Parser::lambdaParamList(){
    std::vector<node_ptr> params;
    param_defaults_.clear();
    if(see(TokenType::Colon)) return params; // no params
    auto parse_one_param = [&]() {
        bool va = have(TokenType::Mul);
        bool kw = !va && have(TokenType::Exp);
        Token ptok = token();
        ptok.value = token().value;
        next();
        auto pnode = make_node<VariableNode>(ptok);
        if(va) static_cast<VariableNode*>(pnode.get())->name = "*" + ptok.value;
        else if(kw) static_cast<VariableNode*>(pnode.get())->name = "**" + ptok.value;
        else static_cast<VariableNode*>(pnode.get())->name = ptok.value;
        params.push_back(pnode);
        if(have(TokenType::Assign)) param_defaults_.push_back(expression());
        else param_defaults_.push_back(nullptr);
    };
    parse_one_param();
    while(have(TokenType::Comma) && !see(TokenType::Colon)){
        parse_one_param();
    }
    return params;
}
std::vector<node_ptr> Parser::paramList(){
    std::vector<node_ptr> params;
    param_defaults_.clear();
    param_posonly_ = 0;
    if(!see(TokenType::ParenClose)){
        // Check for *args or **kwargs
        auto parse_one_param = [&]() {
            // A bare `*`: the parameters after it are keyword-only.
            if(see(TokenType::Mul) && (peek(1).type() == TokenType::Comma || peek(1).type() == TokenType::ParenClose)){
                Token st = token(); next();
                st.value = "*";
                params.push_back(make_node<VariableNode>(st));
                param_defaults_.push_back(nullptr);
                return;
            }
            // A bare `/` (PEP 570): the parameters before it are
            // positional-only (FunctionNode::posonly; both engines refuse
            // them as keywords, and a **kwargs parameter takes such a keyword).
            if(see(TokenType::Div) && (peek(1).type() == TokenType::Comma || peek(1).type() == TokenType::ParenClose)){
                next();
                param_posonly_ = params.size();
                return;
            }
            bool va = have(TokenType::Mul);
            bool kw = !va && have(TokenType::Exp);
            // Accept identifier or keyword as param name
            Token ptok = token();
            ptok.value = token().value; // ensure we get the text
            next();
            auto pnode = make_node<VariableNode>(ptok);
            if(va) static_cast<VariableNode*>(pnode.get())->name = "*" + ptok.value;
            else if(kw) static_cast<VariableNode*>(pnode.get())->name = "**" + ptok.value;
            else static_cast<VariableNode*>(pnode.get())->name = ptok.value;
            params.push_back(pnode);
            // `name: T`: kept for the function's __annotations__
            if(have(TokenType::Colon)) {
                int a0 = scanner->current;
                node_ptr ann = ternary();
                param_ann_.push_back({ptok.value, annotationValue(ann, a0, scanner->current)});
            }
            if(have(TokenType::Assign)) param_defaults_.push_back(expression());
            else param_defaults_.push_back(nullptr);
        };
        parse_one_param();
        while(have(TokenType::Comma) && !see(TokenType::ParenClose)){
            parse_one_param();
        }
    }
    return params;
}

std::vector<node_ptr> Parser::argList(){
    std::vector<node_ptr> args;
    if(!see(TokenType::ParenClose)){
        auto parse_arg = [&]() -> node_ptr {
            if(have(TokenType::Mul)){
                // *args spread: create UnaryNode with op="*"
                Token star = prev();
                node_ptr operand = expression();
                return make_node<UnaryNode>(star, operand);
            }
            if(have(TokenType::Exp)){
                // **kwargs spread: create UnaryNode with op="**"
                Token dstar = prev();
                node_ptr operand = expression();
                return make_node<UnaryNode>(dstar, operand);
            }
            return expression();
        };
        args.push_back(parse_arg());
        while(have(TokenType::Comma)) args.push_back(parse_arg());
    }
    return args;
}

node_ptr Parser::classDecl(){
    Token tok = token();
    mustBe(TokenType::Class);
    std::string name = identifier();
    // Optional bases: class Foo(Bar, Baz) or class Foo extends Bar
    // Supports: extends, inherits, and parenthesized syntax
    std::vector<node_ptr> bases;
    // A base: a name or a dotted one (class C(threading.Thread)); the engines
    // look it up when the class statement runs. `metaclass=M` and other
    // keywords are read and not used.
    std::vector<std::pair<std::string, node_ptr>> class_kw;
    auto base = [&]() {
        if(see(TokenType::Identifier) && peek().type() == TokenType::Assign){
            std::string kn = identifier();
            next();
            class_kw.push_back({kn, expression()});
            return;
        }
        // A (dotted) name, or any other expression (Generic[T], a call).
        int k = 0;
        bool plain = true;
        while(true){
            TokenType tt = peek(k).type();
            if(tt == TokenType::Comma || tt == TokenType::ParenClose) break;
            if(k % 2 == 0 ? (tt != TokenType::Identifier && peek(k).clazz() != TokenClass::Keyword)
                          : tt != TokenType::Dot) { plain = false; break; }
            k++;
        }
        if(!plain){ bases.push_back(expression()); return; }
        Token bt = token();
        std::string bn = identifier();
        while(see(TokenType::Dot) && peek(1).type() == TokenType::Identifier){ next(); bn += "." + identifier(); }
        bt.value = bn;
        bases.push_back(make_node<VariableNode>(bt));
    };
    if(have(TokenType::ParenOpen)){
        if(!see(TokenType::ParenClose)){
            base();
            while(have(TokenType::Comma) && !see(TokenType::ParenClose)) base();
        }
        mustBe(TokenType::ParenClose);
    } else if(have(TokenType::Extends) || have(TokenType::Inherits)) {
        // class Foo extends Bar or class Foo inherits Bar
        bases.push_back(make_node<VariableNode>(token())); next();
        while(have(TokenType::Comma)){ bases.push_back(make_node<VariableNode>(token())); next(); }
    }
    // Optional: implements InterfaceA, InterfaceB
    if(have(TokenType::Implements)) {
        // Store interface names as additional bases for now
        bases.push_back(make_node<VariableNode>(token())); next();
        while(have(TokenType::Comma)){ bases.push_back(make_node<VariableNode>(token())); next(); }
    }
    // Handle colon-based inheritance: class Foo : Bar (only if no extends/inherits).
    // Only when the names are followed by the block (a newline, a brace, or
    // a second colon ending the line): `class A: x = 1` and `class A: x: int
    // = 1` are Python one-line bodies (round 77: they read as base `x`).
    if(bases.empty() && see(TokenType::Colon) && peek(1).type() == TokenType::Identifier){
        int k = 1;
        while(peek(k).type() == TokenType::Identifier && peek(k + 1).type() == TokenType::Comma) k += 2;
        TokenType after = peek(k + 1).type();
        auto ends = [](TokenType t){ return t == TokenType::NewLine || t == TokenType::Indent || t == TokenType::BraceOpen
                                            || t == TokenType::End; };
        bool inherit = peek(k).type() == TokenType::Identifier
                       && (ends(after) || (after == TokenType::Colon && ends(peek(k + 2).type())));
        if(inherit){
            next();
            bases.push_back(make_node<VariableNode>(token())); next();
            while(have(TokenType::Comma)){ bases.push_back(make_node<VariableNode>(token())); next(); }
            have(TokenType::Colon);
        }
    }
    have(TokenType::Colon); // consume : before block
    ann_scope_.push_back('c');
    class_ann_used_.push_back(false);
    node_ptr body = blockOrStmt();
    ann_scope_.pop_back();
    if(class_ann_used_.back() && body){
        // the class body starts with `var __annotations__ = {}`
        auto nb = make_node<BlockNode>(body->token());
        nb->add(annotationsDecl(tok));
        if(body->type() == NodeType::BLOCK) for(auto& s : body->statements()) nb->add(s);
        else nb->add(body);
        body = nb;
    }
    class_ann_used_.pop_back();
    auto cls = make_node<ClassNode>(tok, name, body);
    std::static_pointer_cast<ClassNode>(cls)->bases = bases;
    std::static_pointer_cast<ClassNode>(cls)->keywords = std::move(class_kw);
    {
        auto* cp = static_cast<ClassNode*>(cls.get());
        cp->has_doc = docstringOf(body, cp->doc);
    }
    return cls;
}

node_ptr Parser::interfaceDecl(){
    Token tok = token();
    mustBe(TokenType::Interface);
    std::string name = identifier();
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    return make_node<InterfaceNode>(tok, name, body);
}

// `struct Point: x, y=0` (comma or newline separated, brace or indent
// block - same grammar as enumDecl just below) desugars to a class with an
// auto-generated `__init__(self, x, y=0): self.x = x; self.y = y`. A
// value-carrying record IS what a class with only that constructor already
// is here, so reusing ClassNode means inheritance, is_a, the object
// protocol, and both engines' class compilation all work for structs with
// no separate implementation anywhere else in either engine.
node_ptr Parser::structDecl(){
    Token tok = token();
    mustBe(TokenType::Struct);
    std::string name = identifier();
    have(TokenType::Colon);
    bool has_brace = have(TokenType::BraceOpen);
    have(TokenType::NewLine);
    bool has_indent = have(TokenType::Indent);
    auto end_check = [&]() -> bool {
        if(has_brace) return see(TokenType::BraceClose);
        if(has_indent) return see(TokenType::Dedent);
        return see(TokenType::End)||see(TokenType::NewLine);
    };
    std::vector<Token> field_toks;
    std::vector<node_ptr> field_defaults;
    while(!end_check()&&!see(TokenType::End)){
        while(have(TokenType::NewLine)) {}
        if(end_check()) break;
        Token ftok = token();
        std::string fname = identifier();
        ftok.value = fname;
        node_ptr fdefault = nullptr;
        if(have(TokenType::Assign)) fdefault = expression();
        field_toks.push_back(ftok);
        field_defaults.push_back(fdefault);
        have(TokenType::Comma); have(TokenType::NewLine);
    }
    if(has_indent) have(TokenType::Dedent);
    if(has_brace) have(TokenType::BraceClose);

    Token self_tok = tok; self_tok.value = "self";
    auto init_body = make_node<BlockNode>(tok);
    for(auto& ftok : field_toks){
        // `self` inside a method body must be a SelfNode, not a generic
        // VariableNode referencing a variable named "self" - the VM
        // compiles the two completely differently (visit(), NT::SELF vs
        // NT::VARIABLE): real `self.x` compiles to a dedicated LOAD_SELF
        // opcode, while a VariableNode named "self" compiles to
        // LOAD_NAME "self", an ordinary name lookup that finds nothing
        // (self isn't bound as a regular local - it's carried on the call
        // frame instead), so `self.x = x` silently wrote to none.x and
        // every struct field field read back none. Only the PARAMETER
        // declaration below (`self` as the first param name) stays a
        // VariableNode; it's just a name there, not a self-reference.
        auto self_ref = make_node<SelfNode>(self_tok);
        auto target = make_node<AttributeNode>(ftok, self_ref, ftok.value);
        auto value = make_node<VariableNode>(ftok);
        init_body->add(make_node<AssignmentNode>(ftok, target, value));
    }
    auto init_fn = make_node<FunctionNode>(tok, "__init__", init_body, true);
    init_fn->add(make_node<VariableNode>(self_tok));
    std::vector<node_ptr> defaults; defaults.push_back(nullptr);
    for(size_t i=0;i<field_toks.size();i++){
        init_fn->add(make_node<VariableNode>(field_toks[i]));
        defaults.push_back(field_defaults[i]);
    }
    static_cast<FunctionNode*>(init_fn.get())->defaults = std::move(defaults);

    auto class_body = make_node<BlockNode>(tok);
    class_body->add(init_fn);
    return make_node<ClassNode>(tok, name, class_body);
}

node_ptr Parser::enumDecl(){
    Token tok = token();
    mustBe(TokenType::Enum);
    std::string name = identifier();
    have(TokenType::Colon);
    bool has_brace = have(TokenType::BraceOpen);
    have(TokenType::NewLine);
    bool has_indent = have(TokenType::Indent);
    auto en = make_node<EnumNode>(tok, name);
    auto end_check = [&]() -> bool {
        if(has_brace) return see(TokenType::BraceClose);
        if(has_indent) return see(TokenType::Dedent);
        return see(TokenType::End)||see(TokenType::NewLine);
    };
    while(!end_check()&&!see(TokenType::End)){
        while(have(TokenType::NewLine)) {}
        if(end_check()) break;
        Token itok = token();
        std::string iname = identifier();
        node_ptr ival = nullptr;
        if(have(TokenType::Assign)) ival = expression();
        en->add(make_node<EnumItemNode>(itok, iname, ival));
        have(TokenType::Comma); have(TokenType::NewLine);
    }
    if(has_brace) have(TokenType::BraceClose);
    if(has_indent) have(TokenType::Dedent);
    have(TokenType::NewLine);
    return en;
}

node_ptr Parser::namespaceDecl(){
    Token tok = token();
    mustBe(TokenType::NameSpace);
    std::string name = identifier();
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    return make_node<NameSpaceNode>(tok, name, body);
}

node_ptr Parser::returnStmt(){
    Token tok = token();
    mustBe(TokenType::Return);
    node_ptr expr = nullptr;
    if(!see(TokenType::NewLine)&&!see(TokenType::SemiColon)&&!see(TokenType::End))
        expr = expression();
    // Support multiple return values: return a, b, c -> return [a, b, c]
    if(see(TokenType::Comma) && expr) {
        auto list = make_node<ListNode>(tok);
        list->add(expr);
        while(have(TokenType::Comma)) {
            list->add(expression());
        }
        expr = list;
    }
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<ReturnNode>(tok, expr);
}

node_ptr Parser::breakStmt(){
    Token tok = token(); mustBe(TokenType::Break);
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<BreakNode>(tok);
}

node_ptr Parser::continueStmt(){
    Token tok = token(); mustBe(TokenType::Continue);
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<ContinueNode>(tok);
}

node_ptr Parser::passStmt(){
    Token tok = token(); mustBe(TokenType::Pass);
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<PassNode>(tok);
}

node_ptr Parser::yieldStmt(){
    Token tok = token(); mustBe(TokenType::Yield);
    if(!yield_seen_.empty()) yield_seen_.back() = true;
    // yield from <iterable>
    if(have(TokenType::From)){
        node_ptr src = expression();
        have(TokenType::SemiColon); have(TokenType::NewLine);
        return make_node<YieldFromNode>(tok, src);
    }
    node_ptr expr = nullptr;
    if(!see(TokenType::NewLine)&&!see(TokenType::SemiColon)) expr = expression();
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<YieldNode>(tok, expr);
}


// `print(` begins the call form when its matching `)` ends the statement;
// otherwise the parentheses belong to an expression (`print (a + b) * 2`).
static bool endsStatement(TokenType t){
    return t == TokenType::NewLine || t == TokenType::SemiColon || t == TokenType::End || t == TokenType::Dedent;
}

node_ptr Parser::printStmt(){
    Token tok = token(); mustBe(TokenType::Print);
    auto node = make_node<PrintNode>(tok);
    auto pn = std::static_pointer_cast<PrintNode>(node);
    bool call_form = false;
    if(see(TokenType::ParenOpen)){
        int depth = 1;
        for(int k = 1; k < 100000; ++k){
            TokenType t = peek(k).type();
            if(t == TokenType::End) break;
            if(t == TokenType::ParenOpen) depth++;
            else if(t == TokenType::ParenClose && --depth == 0){
                call_form = endsStatement(peek(k + 1).type());
                break;
            }
        }
    }
    if(call_form){
        // The arguments as a call's; print(*xs), file= and flush= (round
        // 77) make it a call of the prelude's _ny_print, the rest stays the
        // print statement both engines run natively.
        mustBe(TokenType::ParenOpen);
        auto args_call = make_node<CallNode>(tok, make_node<VariableNode>(tok));
        auto ac = std::static_pointer_cast<CallNode>(args_call);
        while(!see(TokenType::ParenClose) && !see(TokenType::End)){
            // `end` is also the block keyword (TokenType::EndBlock), so it is
            // matched by spelling as well as by identifier.
            if((see(TokenType::Identifier) || see(TokenType::EndBlock)) && (value() == "sep" || value() == "end")
               && peek().type() == TokenType::Assign){
                Token kt = token();
                std::string kw = value();
                next();
                mustBe(TokenType::Assign);
                ac->add(make_node<KeywordArgNode>(kt, kw, expression()));
            } else if(see(TokenType::Mul) || see(TokenType::Exp)){
                Token st = token();
                next();
                ac->add(make_node<UnaryNode>(st, expression()));
            } else if((see(TokenType::Identifier) || token().clazz() == TokenClass::Keyword) && peek().type() == TokenType::Assign
                      && peek(2).type() != TokenType::Assign){
                Token kt = token();
                std::string kw = value();
                next();
                mustBe(TokenType::Assign);
                ac->add(make_node<KeywordArgNode>(kt, kw, expression()));
            } else {
                ac->add(expression());
            }
            if(!have(TokenType::Comma)) break;
        }
        mustBe(TokenType::ParenClose);
        bool plain = true;
        for(auto& a : ac->args){
            if(a->type() == NodeType::KEYWORD_ARG){
                auto k = std::static_pointer_cast<KeywordArgNode>(a);
                if(k->name != "sep" && k->name != "end") plain = false;
            } else if(a->type() == NodeType::UNARY){
                auto u = std::static_pointer_cast<UnaryNode>(a);
                if(u->op == "*" || u->op == "**") plain = false;
            }
        }
        if(!plain){
            Token ft = tok; ft.value = "_ny_print";
            auto call = make_node<CallNode>(tok, make_node<VariableNode>(ft));
            for(auto& a : ac->args) call->add(a);
            have(TokenType::SemiColon); have(TokenType::NewLine);
            return call;
        }
        for(auto& a : ac->args){
            if(a->type() == NodeType::KEYWORD_ARG){
                auto k = std::static_pointer_cast<KeywordArgNode>(a);
                if(k->name == "sep") pn->sep = k->val; else pn->end = k->val;
            } else node->add(a);
        }
        pn->call_form = true;
    } else if(!see(TokenType::NewLine)&&!see(TokenType::SemiColon)&&!see(TokenType::End)){
        node->add(expression());
        while(have(TokenType::Comma)) node->add(expression());
    }
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return node;
}

node_ptr Parser::importStmt(){
    Token tok = token();
    if(have(TokenType::From)){
        bool quoted = see(TokenType::String);
        std::string mod = dottedName();
        mustBe(TokenType::Import);
        // `from __future__ import annotations` (PEP 563): annotations are
        // kept as their source text. The other features are always on.
        if(mod == "__future__"){
            bool paren = have(TokenType::ParenOpen);
            while(true){
                std::string feat = identifier();
                if(feat == "annotations") future_annotations_ = true;
                if(!have(TokenType::Comma)) break;
                if(paren && see(TokenType::ParenClose)) break;
            }
            if(paren) mustBe(TokenType::ParenClose);
            have(TokenType::SemiColon); have(TokenType::NewLine);
            return make_node<PassNode>(tok);
        }
        auto imp = make_node<ImportNode>(tok, mod);
        std::static_pointer_cast<ImportNode>(imp)->quoted = quoted;
        auto& names = std::static_pointer_cast<ImportNode>(imp)->names;
        if(have(TokenType::Mul)){
            names.push_back("*");
        } else {
            // `from m import a, b as c` and the parenthesised form over
            // several lines with a trailing comma; an alias travels as
            // "a\x05c" (nyrt::import_name_alias).
            bool paren = have(TokenType::ParenOpen);
            auto skip_nl = [&]() { if(paren) while(have(TokenType::NewLine) || have(TokenType::Indent) || have(TokenType::Dedent)) {} };
            skip_nl();
            while(true){
                std::string n = identifier();
                if(have(TokenType::As)) n += std::string(1, '\x05') + identifier();
                names.push_back(n);
                skip_nl();
                if(!have(TokenType::Comma)) break;
                skip_nl();
                if(paren && see(TokenType::ParenClose)) break;
            }
            if(paren) mustBe(TokenType::ParenClose);
        }
        have(TokenType::SemiColon); have(TokenType::NewLine);
        return imp;
    }
    mustBe(TokenType::Import);
    bool quoted = see(TokenType::String);
    std::string mod = dottedName();
    auto imp = make_node<ImportNode>(tok, mod);
    std::static_pointer_cast<ImportNode>(imp)->quoted = quoted;
    if(have(TokenType::As)){
        std::static_pointer_cast<ImportNode>(imp)->alias = identifier();
    }
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return imp;
}

node_ptr Parser::tryStmt(){
    Token tok = token();
    mustBe(TokenType::Try);
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    auto try_node = make_node<TryNode>(tok, body);
    auto tn = std::static_pointer_cast<TryNode>(try_node);
    while(have(TokenType::NewLine)) {}
    // A bare name after `except` is a TYPE when it names an exception class
    // (a builtin one, or anything capitalised, as class names are) and the
    // Nython catch-all binding `except e:` otherwise. Both engines used to
    // read every bare name as a binding, so `except ValueError:` caught
    // everything - and rebound the name ValueError to the exception.
    auto is_type_name = [](const std::string& n) {
        return nython::ny_is_builtin_exc(n) || (!n.empty() && n[0] >= 'A' && n[0] <= 'Z')
               || n.find('.') != std::string::npos;
    };
    // `except mod.Error`: the whole dotted name; both engines look it up in
    // scope when matching (round 77; it was cut to "Error", and a lower-case
    // last part - `except socket.error` - became a catch-all binding).
    auto dotted = [&]() {
        std::string n = identifier();
        while (see(TokenType::Dot) && peek(1).type() == TokenType::Identifier) {
            next(); n += "." + identifier();
        }
        return n;
    };
    while(see(TokenType::Except)){
        next(); // consume 'except'
        std::string ename, ealias;
        std::vector<std::string> types;
        std::string var;
        if(see(TokenType::As)){
            // "except as e:" — catch-all with alias
            next(); // consume 'as'
            if(see(TokenType::Identifier)) ealias = identifier();
            var = ealias;
        } else if(have(TokenType::ParenOpen)){
            // except (A, B) as e:
            while(!see(TokenType::ParenClose) && !see(TokenType::End)){
                types.push_back(dotted());
                if(!have(TokenType::Comma)) break;
            }
            mustBe(TokenType::ParenClose);
            if(!types.empty()) ename = types[0];
            if(have(TokenType::As)) { ealias = identifier(); var = ealias; }
        } else if(see(TokenType::Identifier)
                  // a module named like a declaration keyword: `except
                  // struct.error` was a syntax error
                  || ((see(TokenType::Struct) || see(TokenType::Enum) || see(TokenType::Interface)
                       || see(TokenType::NameSpace) || see(TokenType::Package))
                      && peek(1).type() == TokenType::Dot)){
            ename = dotted();
            if(have(TokenType::As)) { ealias = identifier(); types.push_back(ename); var = ealias; }
            else if(is_type_name(ename)) types.push_back(ename);
            else var = ename;
        }
        have(TokenType::Colon);
        node_ptr ebody = blockOrStmt();
        auto en = make_node<ExceptNode>(tok, ename, ealias, ebody);
        auto enp = std::static_pointer_cast<ExceptNode>(en);
        enp->types = std::move(types);
        enp->var = std::move(var);
        tn->except_clauses.push_back(en);
        while(have(TokenType::NewLine)) {}
    }
    return try_node;
}

node_ptr Parser::raiseStmt(){
    Token tok = token(); next(); // consume raise/throw
    node_ptr expr = nullptr;
    node_ptr cause = nullptr;
    if(!see(TokenType::NewLine)&&!see(TokenType::SemiColon)&&!see(TokenType::End)
       &&!see(TokenType::Dedent)) {
        expr = expression();
        // raise X from Y
        if(have(TokenType::From)) cause = expression();
    }
    have(TokenType::SemiColon); have(TokenType::NewLine);
    auto rn = make_node<RaiseNode>(tok, expr);
    std::static_pointer_cast<RaiseNode>(rn)->cause = cause;
    return rn;
}

node_ptr Parser::assertStmt(){
    Token tok = token(); mustBe(TokenType::Assert);
    node_ptr cond = expression();
    node_ptr msg = nullptr;
    if(have(TokenType::Comma)) msg = expression();
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<AssertNode>(tok, cond, msg);
}

node_ptr Parser::switchStmt(){
    Token tok = token(); mustBe(TokenType::Switch);
    if(tok.value == "match") return matchStmt(tok, expression());
    bool hp = have(TokenType::ParenOpen);
    node_ptr subject = expression();
    if(hp) mustBe(TokenType::ParenClose);
    have(TokenType::Colon);
    bool has_brace = have(TokenType::BraceOpen);
    have(TokenType::NewLine);
    bool has_indent = have(TokenType::Indent);
    auto sw = make_node<SwitchNode>(tok, subject);
    auto sn = std::static_pointer_cast<SwitchNode>(sw);
    // Parse case/default blocks
    auto at_end = [&]() -> bool {
        if(has_brace && see(TokenType::BraceClose)) return true;
        if(has_indent && see(TokenType::Dedent)) return true;
        if(see(TokenType::End)) return true;
        return false;
    };
    while(!at_end()){
        while(have(TokenType::NewLine)) {}
        if(at_end()) break;
        // Consume any stale indent/dedent from case bodies
        while(have(TokenType::Indent)||have(TokenType::Dedent)) {}
        while(have(TokenType::NewLine)) {}
        if(at_end()) break;
        if(have(TokenType::Case)){
            node_ptr val = expression();
            mustBe(TokenType::Colon);
            node_ptr body = blockOrStmt();
            sn->cases.push_back(make_node<CaseNode>(tok, val, body));
        } else if(have(TokenType::Default)){
            mustBe(TokenType::Colon);
            sn->default_case = make_node<DefaultNode>(tok, blockOrStmt());
        } else break;
    }
    if(has_indent) have(TokenType::Dedent);
    if(has_brace) have(TokenType::BraceClose);
    have(TokenType::NewLine);
    return sw;
}

// ── match: Python's structural pattern matching ──────────────────────────
//
// `match` used to be `switch` under another name: every case was an
// expression compared with ==, so `case x if x > 5`, `case [a, b]`,
// `case 1 | 2` (which evaluated 1|2 == 3) and `case Point(x=0)` all
// misbehaved. The patterns now parse into MatchPat and the statement
// desugars, on both engines alike, into
//
//     var __msN__ = subject
//     var __mdN__ = false
//     if not __mdN__ and <structural test>:
//         <bindings>
//         if <guard>:                 (when there is one)
//             __mdN__ = true
//             <body>
//
// one `if` per case. The test reads the subject only through isinstance,
// len, ==, `in`, hasattr/getattr, [] and attribute access, and binds
// nothing, so the bindings are made only once a case's shape matched.

std::shared_ptr<Parser::MatchPat> Parser::matchPattern(){
    // Top level: an open sequence `case a, *rest:` is a sequence pattern.
    auto seq = std::make_shared<MatchPat>(); seq->kind = MatchPat::SEQ;
    auto item = [&](){
        if(have(TokenType::Mul)){
            seq->star = (int)seq->subs.size(); seq->star_name = identifier();
            seq->subs.push_back(std::make_shared<MatchPat>());
        } else seq->subs.push_back(matchOrPattern());
    };
    item();
    if(!see(TokenType::Comma) && seq->star < 0) return seq->subs[0];
    while(have(TokenType::Comma)){
        if(see(TokenType::Colon) || see(TokenType::If)) break;
        item();
    }
    return seq;
}

std::shared_ptr<Parser::MatchPat> Parser::matchOrPattern(){
    auto first = matchClosedPattern();
    std::shared_ptr<MatchPat> p = first;
    if(see(TokenType::BinOr)){
        p = std::make_shared<MatchPat>(); p->kind = MatchPat::OR;
        p->subs.push_back(first);
        while(have(TokenType::BinOr)) p->subs.push_back(matchClosedPattern());
    }
    if(have(TokenType::As)){
        if(!p->as_name.empty()){
            auto w = std::make_shared<MatchPat>(); w->kind = MatchPat::OR;
            w->subs.push_back(p); p = w;
        }
        p->as_name = identifier();
    }
    return p;
}

std::shared_ptr<Parser::MatchPat> Parser::matchClosedPattern(){
    auto p = std::make_shared<MatchPat>();
    Token tok = token();
    // Items of a bracketed sequence, `*name` allowed once.
    auto seq_items = [&](TokenType close){
        p->kind = MatchPat::SEQ;
        while(!see(close)){
            while(have(TokenType::NewLine)) {}
            if(see(close)) break;
            if(have(TokenType::Mul)){
                p->star = (int)p->subs.size(); p->star_name = identifier();
                p->subs.push_back(std::make_shared<MatchPat>());
            } else p->subs.push_back(matchOrPattern());
            while(have(TokenType::NewLine)) {}
            if(!have(TokenType::Comma)) break;
        }
        while(have(TokenType::NewLine)) {}
        mustBe(close);
    };
    if(see(TokenType::Identifier)){
        std::string name = tok.value; next();
        node_ptr expr;
        if(see(TokenType::Dot) || see(TokenType::ParenOpen)){
            expr = make_node<VariableNode>(tok);
            while(see(TokenType::Dot)){
                next(); Token at = token(); std::string an = at.value; next();
                expr = make_node<AttributeNode>(at, expr, an);
            }
        }
        if(!expr){
            if(name == "_") p->kind = MatchPat::WILD;
            else { p->kind = MatchPat::CAPTURE; p->name = name; }
            return p;
        }
        if(!have(TokenType::ParenOpen)){ p->kind = MatchPat::VALUE; p->value = expr; return p; }
        // Class pattern: Cls(p1, p2, attr=p3)
        p->kind = MatchPat::CLASS; p->value = expr;
        while(!see(TokenType::ParenClose)){
            while(have(TokenType::NewLine)) {}
            if(see(TokenType::ParenClose)) break;
            if(see(TokenType::Identifier) && peek(1).type() == TokenType::Assign && peek(1).value == "="){
                std::string kn = token().value; next(); next();
                p->kw.push_back({kn, matchOrPattern()});
            } else p->subs.push_back(matchOrPattern());
            while(have(TokenType::NewLine)) {}
            if(!have(TokenType::Comma)) break;
        }
        mustBe(TokenType::ParenClose);
        return p;
    }
    if(have(TokenType::BracketOpen)){ seq_items(TokenType::BracketClose); return p; }
    if(have(TokenType::ParenOpen)){
        if(have(TokenType::ParenClose)){ p->kind = MatchPat::SEQ; return p; }
        // (p) groups; (p,) and (p, q) are sequences.
        if(!see(TokenType::Mul)){
            auto inner = matchOrPattern();
            if(have(TokenType::ParenClose)) return inner;
            p->kind = MatchPat::SEQ; p->subs.push_back(inner);
            mustBe(TokenType::Comma);
            seq_items(TokenType::ParenClose);
            return p;
        }
        seq_items(TokenType::ParenClose); return p;
    }
    if(have(TokenType::BraceOpen)){
        p->kind = MatchPat::MAP;
        while(!see(TokenType::BraceClose)){
            while(have(TokenType::NewLine)) {}
            if(see(TokenType::BraceClose)) break;
            if(have(TokenType::Exp)){ p->rest = identifier(); }
            else {
                node_ptr key = unary();
                mustBe(TokenType::Colon);
                p->items.push_back({key, matchOrPattern()});
            }
            while(have(TokenType::NewLine)) {}
            if(!have(TokenType::Comma)) break;
        }
        while(have(TokenType::NewLine)) {}
        mustBe(TokenType::BraceClose);
        return p;
    }
    if(see(TokenType::Integer) || see(TokenType::Float) || see(TokenType::String)
       || see(TokenType::Sub) || see(TokenType::True) || see(TokenType::False) || see(TokenType::None)){
        p->kind = MatchPat::VALUE; p->value = unary(); return p;
    }
    throw SyntaxError(tok.location(), "Unexpected token in a case pattern: " + tok.value);
}

node_ptr Parser::matchStmt(Token tok, node_ptr subject){
    static int match_counter = 0;
    int id = match_counter++;
    std::string subj = "__ms" + std::to_string(id) + "__";
    std::string done = "__md" + std::to_string(id) + "__";
    auto T = [&](const std::string& v){ Token t = tok; t.value = v; return t; };
    auto var_ref = [&](const std::string& n){ return make_node<VariableNode>(T(n)); };
    auto int_node = [&](long v){ Token t = T(std::to_string(v)); t.type(TokenType::Integer); return make_node<IntegerNode>(t); };
    auto str_node = [&](const std::string& v){ Token t = T(v); t.type(TokenType::String); return make_node<StringNode>(t); };
    auto bin = [&](const std::string& op, node_ptr a, node_ptr b){ return make_node<BinaryNode>(T(op), a, b); };
    auto call = [&](const std::string& fn, std::vector<node_ptr> args){
        auto c = make_node<CallNode>(T(fn), var_ref(fn));
        for(auto& a : args) c->add(a);
        return c;
    };
    auto conj = [&](node_ptr a, node_ptr b) -> node_ptr { if(!a) return b; if(!b) return a; return bin("and", a, b); };
    using Path = std::function<node_ptr()>;
    auto sub = [&](Path base, node_ptr idx) -> Path { return [=]() -> node_ptr { return make_node<SubscriptNode>(T("["), base(), idx); }; };
    auto builtin_type = [](node_ptr cls){
        static const std::set<std::string> t = {"int","float","str","bool","list","dict","set","tuple","bytes","bytearray","frozenset"};
        return cls && cls->type() == NodeType::VARIABLE && t.count(cls->value());
    };
    // Where the i-th positional sub-pattern of a class pattern reads from.
    auto positional = [&](std::shared_ptr<MatchPat> p, Path path, size_t i) -> Path {
        if(builtin_type(p->value) && p->subs.size() == 1) return path;
        node_ptr cls = p->value;
        return [=, &T, &int_node]() -> node_ptr {
            auto names = make_node<AttributeNode>(T("__match_args__"), cls, "__match_args__");
            auto c = make_node<CallNode>(T("getattr"), make_node<VariableNode>(T("getattr")));
            c->add(path());
            c->add(make_node<SubscriptNode>(T("["), names, int_node((long)i)));
            return c;
        };
    };
    std::function<node_ptr(std::shared_ptr<MatchPat>, Path)> test;
    test = [&](std::shared_ptr<MatchPat> p, Path path) -> node_ptr {
        switch(p->kind){
        case MatchPat::WILD: case MatchPat::CAPTURE: return nullptr;
        case MatchPat::VALUE: return bin("==", path(), p->value);
        case MatchPat::OR: {
            node_ptr r;
            for(auto& a : p->subs){
                node_ptr t = test(a, path);
                if(!t) return nullptr;
                r = r ? bin("or", r, t) : t;
            }
            return r;
        }
        case MatchPat::SEQ: {
            long n = (long)p->subs.size();
            node_ptr r = call("isinstance", {path(), var_ref("list")});
            if(p->star < 0) r = conj(r, bin("==", call("len", {path()}), int_node(n)));
            else r = conj(r, bin(">=", call("len", {path()}), int_node(n - 1)));
            for(long i = 0; i < n; i++){
                if(i == p->star) continue;
                long idx = (p->star >= 0 && i > p->star) ? -(n - i) : i;
                r = conj(r, test(p->subs[i], sub(path, int_node(idx))));
            }
            return r;
        }
        case MatchPat::CLASS: {
            node_ptr r = call("isinstance", {path(), p->value});
            for(size_t i = 0; i < p->subs.size(); i++)
                r = conj(r, test(p->subs[i], positional(p, path, i)));
            for(auto& kv : p->kw){
                std::string an = kv.first;
                r = conj(r, call("hasattr", {path(), str_node(an)}));
                Path ap = [=, &T]() -> node_ptr { return make_node<AttributeNode>(T(an), path(), an); };
                r = conj(r, test(kv.second, ap));
            }
            return r;
        }
        case MatchPat::MAP: {
            node_ptr r = call("isinstance", {path(), var_ref("dict")});
            for(auto& kv : p->items){
                r = conj(r, bin("in", kv.first, path()));
                r = conj(r, test(kv.second, sub(path, kv.first)));
            }
            return r;
        }
        }
        return nullptr;
    };
    std::function<bool(std::shared_ptr<MatchPat>)> binds_any = [&](std::shared_ptr<MatchPat> p) -> bool {
        if(!p->as_name.empty() || p->kind == MatchPat::CAPTURE || !p->rest.empty()) return true;
        if(p->kind == MatchPat::SEQ && p->star >= 0 && !p->star_name.empty() && p->star_name != "_") return true;
        for(auto& s : p->subs) if(binds_any(s)) return true;
        for(auto& kv : p->kw) if(binds_any(kv.second)) return true;
        for(auto& kv : p->items) if(binds_any(kv.second)) return true;
        return false;
    };
    std::function<void(std::shared_ptr<MatchPat>, Path, node_ptr)> bind;
    bind = [&](std::shared_ptr<MatchPat> p, Path path, node_ptr out) {
        auto assign = [&](const std::string& n, node_ptr v){ out->add(make_node<AssignmentNode>(T("="), var_ref(n), v)); };
        switch(p->kind){
        case MatchPat::CAPTURE: assign(p->name, path()); break;
        case MatchPat::OR: {
            if(!binds_any(p)) break;
            // The alternative that matched decides the bindings.
            node_ptr chain, last;
            for(auto& a : p->subs){
                auto blk = make_node<BlockNode>(tok);
                bind(a, path, blk);
                node_ptr t = test(a, path);
                if(!t){
                    if(last) std::static_pointer_cast<IfNode>(last)->else_branch = blk; else chain = blk;
                    break;
                }
                auto ifn = make_node<IfNode>(tok, t, blk);
                if(last) std::static_pointer_cast<IfNode>(last)->else_branch = ifn; else chain = ifn;
                last = ifn;
            }
            if(chain) out->add(chain);
            break;
        }
        case MatchPat::SEQ: {
            long n = (long)p->subs.size();
            for(long i = 0; i < n; i++){
                if(i == p->star){
                    if(p->star_name.empty() || p->star_name == "_") continue;
                    long after = n - i - 1;
                    auto sl = make_node<CallNode>(T("slice"), make_node<AttributeNode>(T("slice"), path(), "slice"));
                    sl->add(int_node(i));
                    if(after > 0) sl->add(int_node(-after));
                    assign(p->star_name, sl);
                    continue;
                }
                long idx = (p->star >= 0 && i > p->star) ? -(n - i) : i;
                bind(p->subs[i], sub(path, int_node(idx)), out);
            }
            break;
        }
        case MatchPat::CLASS:
            for(size_t i = 0; i < p->subs.size(); i++) bind(p->subs[i], positional(p, path, i), out);
            for(auto& kv : p->kw){
                std::string an = kv.first;
                Path ap = [=, &T]() -> node_ptr { return make_node<AttributeNode>(T(an), path(), an); };
                bind(kv.second, ap, out);
            }
            break;
        case MatchPat::MAP:
            for(auto& kv : p->items) bind(kv.second, sub(path, kv.first), out);
            if(!p->rest.empty()){
                // rest = {k: path[k] for k in path if k not in [keys]}
                std::string k = "__mk" + std::to_string(id) + "__";
                auto comp = std::make_shared<ComprehensionNode>(tok, ComprehensionNode::DICT);
                comp->elt = var_ref(k);
                comp->value = make_node<SubscriptNode>(T("["), path(), var_ref(k));
                ComprehensionNode::Clause cl;
                cl.target = var_ref(k); cl.iter = path();
                auto keys = make_node<ListNode>(tok);
                for(auto& kv : p->items) keys->add(kv.first);
                cl.conds.push_back(bin("not in", var_ref(k), keys));
                comp->clauses.push_back(cl);
                assign(p->rest, comp);
            }
            break;
        default: break;
        }
        if(!p->as_name.empty()) assign(p->as_name, path());
    };

    have(TokenType::Colon);
    bool has_brace = have(TokenType::BraceOpen);
    have(TokenType::NewLine);
    bool has_indent = have(TokenType::Indent);
    auto out = make_node<BlockNode>(tok);
    out->add(make_node<VarDeclNode>(tok, subj, subject, false, false));
    out->add(make_node<VarDeclNode>(tok, done, make_node<BoolNode>(T("false"), false), false, false));
    auto at_end = [&]() -> bool {
        if(has_brace && see(TokenType::BraceClose)) return true;
        if(has_indent && see(TokenType::Dedent)) return true;
        return see(TokenType::End);
    };
    Path root = [&, subj]() -> node_ptr { return var_ref(subj); };
    auto not_done = [&](){ return make_node<UnaryNode>(T("not"), var_ref(done)); };
    auto set_done = [&](){ return make_node<AssignmentNode>(T("="), var_ref(done), make_node<BoolNode>(T("true"), true)); };
    while(!at_end()){
        while(have(TokenType::NewLine)) {}
        if(at_end()) break;
        if(have(TokenType::Case)){
            auto pat = matchPattern();
            node_ptr guard;
            if(have(TokenType::If)) guard = expression();
            mustBe(TokenType::Colon);
            node_ptr body = blockOrStmt();
            auto inner = make_node<BlockNode>(tok);
            bind(pat, root, inner);
            auto run = make_node<BlockNode>(tok);
            run->add(set_done());
            run->add(body);
            if(guard) inner->add(make_node<IfNode>(tok, guard, run));
            else inner->add(run);
            out->add(make_node<IfNode>(tok, conj(not_done(), test(pat, root)), inner));
        } else if(have(TokenType::Default)){
            mustBe(TokenType::Colon);
            auto run = make_node<BlockNode>(tok);
            run->add(set_done());
            run->add(blockOrStmt());
            out->add(make_node<IfNode>(tok, not_done(), run));
        } else {
            throw SyntaxError(token().location(), "Expected 'case' in a match statement, got: " + token().value);
        }
    }
    if(has_indent) have(TokenType::Dedent);
    if(has_brace) have(TokenType::BraceClose);
    have(TokenType::NewLine);
    return out;
}

node_ptr Parser::deleteStmt(){
    Token tok = token(); mustBe(TokenType::Delete);
    node_ptr target = expression();
    have(TokenType::SemiColon); have(TokenType::NewLine);
    return make_node<DeleteNode>(tok, target);
}

// with A() as a, B() as b: body  ==  with A() as a: (with B() as b: body)
// `async with` (is_async) passes each manager through _ny_async_cm.
node_ptr Parser::withStmt(bool is_async){
    Token tok = token(); mustBe(TokenType::With);
    std::vector<std::pair<node_ptr, std::string>> items;
    do {
        node_ptr expr = expression();
        if(is_async) expr = wrap_call("_ny_async_cm", expr);
        std::string alias;
        if(have(TokenType::As)) alias = identifier();
        items.emplace_back(expr, alias);
    } while(have(TokenType::Comma));
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    for(size_t i = items.size(); i-- > 0;){
        node_ptr w = make_node<WithNode>(tok, items[i].first, items[i].second, body);
        if(i > 0){
            auto blk = make_node<BlockNode>(tok);
            blk->add(w);
            body = blk;
        } else body = w;
    }
    return body;
}

// helper(arg) as a call node located at arg
node_ptr Parser::wrap_call(const std::string& helper, node_ptr arg){
    Token t = arg ? arg->token() : token();
    t.value = helper;
    auto call = make_node<CallNode>(t, make_node<VariableNode>(t));
    call->add(arg);
    return call;
}

// The source text of tokens [from, to), spaced as Python prints an
// expression (`dict[str, int]`, `int | None`, `Callable[[int], str]`):
// the string form of an annotation.
std::string Parser::tokenText(int from, int to){
    auto quote = [](const std::string& s) {
        char q = (s.find('\'') != std::string::npos && s.find('"') == std::string::npos) ? '"' : '\'';
        std::string r(1, q);
        for(char c : s){
            if(c == '\\' || c == q) r += '\\';
            if(c == '\n') { r += "\\n"; continue; }
            r += c;
        }
        return r + q;
    };
    std::string out, prev, prev2;
    for(int i = from; i < to && i < (int)scanner->tokens.size(); i++){
        const Token& t = scanner->tokens[i];
        if(t.type() == TokenType::NewLine || t.type() == TokenType::Indent || t.type() == TokenType::Dedent) continue;
        std::string s = t.type() == TokenType::String ? quote(t.value) : t.value;
        bool space = false;
        if(!out.empty()){
            bool unary = (prev == "-" || prev == "+" || prev == "~")
                         && (prev2.empty() || prev2 == "(" || prev2 == "[" || prev2 == "," || prev2 == "|");
            if(prev == ",") space = true;
            else if(s == "," || s == ")" || s == "]" || s == "." || s == "(" || s == "[") space = false;
            else if(prev == "(" || prev == "[" || prev == "." || unary) space = false;
            else space = true;
        }
        if(space) out += ' ';
        out += s;
        prev2 = prev;
        prev = s;
    }
    return out;
}

// What __annotations__ holds for an annotation: its source text under
// `from __future__ import annotations`, else _ny_ann(lambda: T, "T") - the
// value, or the text when T cannot be evaluated yet (a forward reference,
// a name from an unimported module), so an annotation never breaks a
// program that does not read it.
node_ptr Parser::annotationValue(node_ptr expr, int from, int to){
    Token t = expr ? expr->token() : token();
    t.value = tokenText(from, to);
    auto text = make_node<StringNode>(t);
    if(future_annotations_ || !expr) return text;
    Token ht = t; ht.value = "_ny_ann";
    auto call = make_node<CallNode>(ht, make_node<VariableNode>(ht));
    Token lt = t; lt.value = "lambda";
    call->add(make_node<LambdaNode>(lt, expr));
    call->add(text);
    return call;
}

node_ptr Parser::annotationsDecl(const Token& t){
    Token at = t; at.value = "__annotations__";
    return make_node<VarDeclNode>(at, "__annotations__", make_node<MapNode>(at));
}

// `for` or `async for` in a comprehension; sets comp_async_ for the latter.
bool Parser::haveCompFor(){
    if(have(TokenType::For)){ comp_async_ = false; return true; }
    if(see(TokenType::Async) && peek().type() == TokenType::For){
        next(); next();
        comp_async_ = true;
        return true;
    }
    return false;
}

node_ptr Parser::lambdaExpr(){
    Token tok = token(); mustBe(TokenType::Lambda);
    std::vector<node_ptr> params;
    // Only parse params if not immediately followed by ':'
    if(!see(TokenType::Colon)){
        params = lambdaParamList();
    }
    mustBe(TokenType::Colon);
    yield_seen_.push_back(false);
    node_ptr body = expression();
    yield_seen_.pop_back();
    auto lam = make_node<LambdaNode>(tok, body);
    for(auto& p : params) lam->add(p);
    static_cast<LambdaNode*>(lam.get())->defaults = std::move(param_defaults_);
    return lam;
}

// ═══════════════════════════════════════════════════════════════════════════
// BLOCK PARSING (supports Python-style indent, C-style braces, Lua do/end)
// ═══════════════════════════════════════════════════════════════════════════

node_ptr Parser::block(){
    Token tok = token();
    auto blk = make_node<BlockNode>(tok);
    if(have(TokenType::BraceOpen)){
        // C/JS style
        while(have(TokenType::NewLine)||have(TokenType::Indent)||have(TokenType::Dedent)) {}
        while(!see(TokenType::BraceClose)&&!see(TokenType::End)){
            blk->add(stmt());
            while(have(TokenType::NewLine)||have(TokenType::SemiColon)||have(TokenType::Indent)||have(TokenType::Dedent)) {}
        }
        have(TokenType::Dedent);
        mustBe(TokenType::BraceClose);
    } else if(have(TokenType::Do)){
        // Lua style
        while(have(TokenType::NewLine)||have(TokenType::Indent)||have(TokenType::Dedent)) {}
        while(!see(TokenType::EndBlock)&&!see(TokenType::End)){
            blk->add(stmt());
            while(have(TokenType::NewLine)||have(TokenType::SemiColon)||have(TokenType::Indent)||have(TokenType::Dedent)) {}
        }
        have(TokenType::EndBlock)||have(TokenType::End);
    } else {
        // Python style: indent-based (uses Indent/Dedent tokens from lexer)
        have(TokenType::NewLine);
        if(have(TokenType::Indent)){
            while(!see(TokenType::Dedent)&&!see(TokenType::End)){
                blk->add(stmt());
                while(have(TokenType::NewLine)||have(TokenType::SemiColon)) {}
            }
            have(TokenType::Dedent);
            have(TokenType::EndBlock)||have(TokenType::End); // consume trailing 'end' for then/end syntax
        } else {
            // Single statement
            blk->add(statement());
        }
    }
    return blk;
}

node_ptr Parser::blockOrStmt(){
    // Consume EVERY pending newline, not just one. A header whose expression
    // spans lines — `for j in ["x", "y",` / `"z"]:` — leaves more than one
    // NewLine token queued, so after eating a single newline the next token was
    // another NewLine rather than Indent. The indented suite was therefore not
    // recognised as a block and the first statement of the body was parsed as a
    // lone inline statement, which failed with a bare "Unexpected token".
    // Symptom: a `var` declaration as the first line of a body under a
    // multi-line loop header was a syntax error, while the same loop with the
    // list on one line parsed fine.
    while(have(TokenType::NewLine)) { }
    if(see(TokenType::BraceOpen)||see(TokenType::Do)||see(TokenType::Indent))
        return block();
    consumed_semi_ = false;
    node_ptr first = statement();
    // An inline suite may hold several statements separated by semicolons:
    //     def set_pos(self, x, y): self.x = x; self.y = y
    // Only the first was parsed; everything after the ';' was silently dropped,
    // so set_pos() assigned x and left y untouched. That is what drew the IDE's
    // output console at the top of the window instead of inside the panel.
    // Semicolons already worked at top level (see script()/stmt()); they now
    // work here too.
    if(!consumed_semi_) return first;
    auto blk = make_node<BlockNode>(this->token());
    if(first) blk->add(first);
    while(consumed_semi_){
        if(see(TokenType::NewLine)||see(TokenType::End)) break;
        consumed_semi_ = false;
        node_ptr more = statement();
        if(more) blk->add(more);
    }
    have(TokenType::NewLine);
    return blk;
}

// ═══════════════════════════════════════════════════════════════════════════
// COLLECTION LITERALS
// ═══════════════════════════════════════════════════════════════════════════

// A comprehension's clauses, the first `for` already consumed:
//   for T in ITER (if COND)* (for T in ITER (if COND)*)*
// Conditions and iterables stop before a ternary's `if`/`else` (logicalOr),
// so `[x for x in xs if a if b]` has two conditions rather than being read
// as a malformed conditional expression.
node_ptr Parser::comprehension(Token tok, int kind, node_ptr elt, node_ptr value){
    auto comp = make_node<ComprehensionNode>(tok, kind);
    auto cp = std::static_pointer_cast<ComprehensionNode>(comp);
    cp->elt = elt; cp->value = value;
    do {
        bool async_clause = comp_async_;
        comp_async_ = false;
        ComprehensionNode::Clause cl;
        cl.target = compTarget();
        mustBe(TokenType::In);
        cl.iter = logicalOr();
        if(async_clause) cl.iter = wrap_call("_ny_aiter", cl.iter);
        while(have(TokenType::If)) cl.conds.push_back(logicalOr());
        cp->clauses.push_back(std::move(cl));
    } while(haveCompFor());
    return comp;
}

// A comprehension target: a name, or a (possibly nested, possibly
// parenthesised) comma-separated list of targets.
node_ptr Parser::compTargetOne(){
    Token tok = token();
    if(have(TokenType::ParenOpen)){
        node_ptr t = compTarget();
        mustBe(TokenType::ParenClose);
        if(t->type() != NodeType::TUPLE){
            auto tup = make_node<TupleNode>(tok); tup->add(t); return tup;
        }
        return t;
    }
    if(have(TokenType::BracketOpen)){
        node_ptr t = compTarget();
        mustBe(TokenType::BracketClose);
        if(t->type() != NodeType::TUPLE){
            auto tup = make_node<TupleNode>(tok); tup->add(t); return tup;
        }
        return t;
    }
    Token id = token();
    id.value = identifier();
    return make_node<VariableNode>(id);
}

node_ptr Parser::compTarget(){
    Token tok = token();
    node_ptr first = compTargetOne();
    if(!see(TokenType::Comma)) return first;
    auto tup = make_node<TupleNode>(tok);
    tup->add(first);
    while(have(TokenType::Comma)){
        if(see(TokenType::In) || see(TokenType::ParenClose) || see(TokenType::BracketClose)) break;
        tup->add(compTargetOne());
    }
    return tup;
}

node_ptr Parser::starElem(){
    if(see(TokenType::Mul)){
        Token st = token();
        next();
        st.value = "*";
        return make_node<UnaryNode>(st, ternary());
    }
    return expression();
}

// [a, *b, c] -> _ny_list_cat([a], b, [c]); wrap names tuple/set around it.
node_ptr Parser::catStarred(Token tok, const std::vector<node_ptr>& elems, const char* wrap){
    Token ft = tok; ft.value = "_ny_list_cat";
    auto call = make_node<CallNode>(tok, make_node<VariableNode>(ft));
    std::shared_ptr<ListNode> run;
    for(auto& e : elems){
        if(isStarElem(e)){
            if(run){ call->add(run); run.reset(); }
            call->add(static_cast<UnaryNode*>(e.get())->operand);
        } else {
            if(!run) run = std::static_pointer_cast<ListNode>(make_node<ListNode>(tok));
            run->add(e);
        }
    }
    if(run) call->add(run);
    if(!wrap) return call;
    Token wt = tok; wt.value = wrap;
    auto w = make_node<CallNode>(tok, make_node<VariableNode>(wt));
    w->add(call);
    return w;
}

node_ptr Parser::listLiteral(){
    Token tok = token();
    mustBe(TokenType::BracketOpen);
    if(see(TokenType::BracketClose)){
        next();
        return make_node<ListNode>(tok); // empty list []
    }
    // Parse first expression
    node_ptr first = starElem();
    // List comprehension: [expr for t in it if c ... for t2 in it2 ...]
    if(!isStarElem(first) && haveCompFor()){
        node_ptr comp = comprehension(tok, ComprehensionNode::LIST, first, nullptr);
        mustBe(TokenType::BracketClose);
        return comp;
    }
    // Regular list literal
    auto list = make_node<ListNode>(tok);
    list->add(first);
    bool starred = isStarElem(first);
    while(have(TokenType::Comma)&&!see(TokenType::BracketClose)){
        node_ptr e = starElem();
        starred = starred || isStarElem(e);
        list->add(e);
    }
    mustBe(TokenType::BracketClose);
    if(starred && !in_assign_target_) return catStarred(tok, list->statements(), nullptr);
    return list;
}

node_ptr Parser::loopStmt(){
    Token tok = token();
    mustBe(TokenType::Loop);
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    // loop is just while(true) { body }
    auto cond = make_node<BoolNode>(tok, true);
    return make_node<WhileNode>(tok, cond, body);
}

node_ptr Parser::blockStmt(){
    Token tok = token();
    mustBe(TokenType::Block);
    have(TokenType::Colon);
    return blockOrStmt();
}

node_ptr Parser::repeatStmt(){
    Token tok = token();
    mustBe(TokenType::Repeat);
    // Counted form: `repeat N:` runs the body N times. Only the
    // `repeat: ... until cond` form existed, so a count was parsed as the start
    // of the body and the parser then demanded `until`, reporting
    // "Expected Until, but found Colon".
    if(!see(TokenType::Colon) && !see(TokenType::NewLine) && !see(TokenType::BraceOpen)){
        node_ptr count = expression();
        have(TokenType::Colon);
        node_ptr rbody = blockOrStmt();
        // Desugar to:  var __repeat_i = 0
        //              while __repeat_i < N:  body; __repeat_i = __repeat_i + 1
        static int repeat_seq = 0;
        std::string ctr = "__repeat_i" + std::to_string(repeat_seq++);
        Token id_tok = tok; id_tok.value = ctr;
        Token zero_tok = tok; zero_tok.value = "0";
        Token one_tok  = tok; one_tok.value  = "1";
        Token lt_tok   = tok; lt_tok.value   = "<";
        Token add_tok  = tok; add_tok.value  = "+";

        auto zero  = make_node<IntegerNode>(zero_tok);
        auto decl  = make_node<VarDeclNode>(tok, ctr, zero);
        auto cond  = make_node<BinaryNode>(lt_tok, make_node<VariableNode>(id_tok), count);
        auto inc   = make_node<AssignmentNode>(tok, make_node<VariableNode>(id_tok),
                        make_node<BinaryNode>(add_tok, make_node<VariableNode>(id_tok),
                                              make_node<IntegerNode>(one_tok)));
        auto inner = make_node<BlockNode>(tok);
        inner->add(rbody);
        inner->add(inc);
        auto outer = make_node<BlockNode>(tok);
        outer->add(decl);
        outer->add(make_node<WhileNode>(tok, cond, inner));
        return outer;
    }
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    // repeat...until: execute body, then check condition
    // Transform to: do { body } while(!condition)
    mustBe(TokenType::Until);
    bool has_paren = have(TokenType::ParenOpen);
    node_ptr cond = expression();
    if(has_paren) mustBe(TokenType::ParenClose);
    // Create: while(true) { body; if(cond) break; }
    auto block = make_node<BlockNode>(tok);
    block->add(body);
    auto brk = make_node<BreakNode>(tok);
    auto if_break = make_node<IfNode>(tok, cond, brk);
    block->add(if_break);
    auto true_cond = make_node<BoolNode>(tok, true);
    return make_node<WhileNode>(tok, true_cond, block);
}

node_ptr Parser::mapLiteral(){
    Token tok = token();
    mustBe(TokenType::BraceOpen);
    // Could be a map or a block — if first token is identifier followed by colon, it's a map
    if(see(TokenType::BraceClose)){
        next(); return make_node<MapNode>(tok); // empty map
    }
    auto map = make_node<MapNode>(tok);
    // {**d, k: v, **e}: _ny_dict_merge(d, {k: v}, e)
    if(see(TokenType::Exp)){
        Token ft = tok; ft.value = "_ny_dict_merge";
        auto call = make_node<CallNode>(tok, make_node<VariableNode>(ft));
        std::shared_ptr<MapNode> run;
        do {
            if(see(TokenType::BraceClose)) break;
            if(have(TokenType::Exp)){
                if(run){ call->add(run); run.reset(); }
                call->add(ternary());
            } else {
                node_ptr k = expression();
                mustBe(TokenType::Colon);
                node_ptr v = expression();
                if(!run) run = std::static_pointer_cast<MapNode>(make_node<MapNode>(tok));
                run->add(make_node<MapEntryNode>(tok, k, v));
            }
        } while(have(TokenType::Comma));
        if(run) call->add(run);
        mustBe(TokenType::BraceClose);
        return call;
    }
    node_ptr key = starElem();
    if(!isStarElem(key) && have(TokenType::Colon)){
        // It's a map
        node_ptr val = expression();
        // Dict comprehension: {k: v for t in it if c ...}
        if(haveCompFor()) {
            node_ptr comp = comprehension(tok, ComprehensionNode::DICT, key, val);
            mustBe(TokenType::BraceClose);
            return comp;
        }
        map->add(make_node<MapEntryNode>(tok, key, val));
        std::shared_ptr<CallNode> merged;   // set once a **e appears
        while(have(TokenType::Comma)&&!see(TokenType::BraceClose)){
            if(have(TokenType::Exp)){
                if(!merged){
                    Token ft = tok; ft.value = "_ny_dict_merge";
                    merged = std::static_pointer_cast<CallNode>(make_node<CallNode>(tok, make_node<VariableNode>(ft)));
                }
                if(!map->statements().empty()) merged->add(map);
                map = make_node<MapNode>(tok);
                merged->add(ternary());
                continue;
            }
            node_ptr k = expression();
            mustBe(TokenType::Colon);
            node_ptr v = expression();
            map->add(make_node<MapEntryNode>(tok, k, v));
        }
        mustBe(TokenType::BraceClose);
        if(merged){
            if(!map->statements().empty()) merged->add(map);
            return merged;
        }
        return map;
    }
    // Set literal: {expr1, expr2, ...}
    // Build as: set([expr1, expr2, ...])
    // Set literal or set comprehension: {expr ...}
    // Set comprehension: {e for t in it if c ...}
    if (!isStarElem(key) && haveCompFor()) {
        node_ptr comp = comprehension(tok, ComprehensionNode::SET, key, nullptr);
        mustBe(TokenType::BraceClose);
        return comp;
    }
    auto list = make_node<ListNode>(tok);
    list->add(key);
    bool starred = isStarElem(key);
    while(have(TokenType::Comma) && !see(TokenType::BraceClose)){
        node_ptr e = starElem();
        starred = starred || isStarElem(e);
        list->add(e);
    }
    mustBe(TokenType::BraceClose);
    if(starred) return catStarred(tok, list->statements(), "set");
    // Wrap in set([...]) call
    Token set_tok = tok; set_tok.value = "set";
    auto set_var = make_node<VariableNode>(set_tok);
    auto call = make_node<CallNode>(tok, set_var);
    call->add(list);
    return call;
}

node_ptr Parser::tupleLiteral(){
    Token tok = token();
    mustBe(TokenType::ParenOpen);
    auto tuple = make_node<TupleNode>(tok);
    if(!see(TokenType::ParenClose)){
        tuple->add(expression());
        while(have(TokenType::Comma)) tuple->add(expression());
    }
    mustBe(TokenType::ParenClose);
    return tuple;
}

} // namespace nython::parser

#pragma GCC diagnostic pop
