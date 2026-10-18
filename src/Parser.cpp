#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#include "Parser.hpp"
#include <functional>
#include <map>
#include <cctype>
#include <set>
#include "NyExcTypes.hpp"
#include "SourceCode.hpp"
#include "Except.hpp"
#include "Script.hpp"
#include "ASTNodes.hpp"
#include "DynamicLang.hpp"
#include "NyScope.hpp"
#include "NyRuntime.hpp"   // nyrt::cli_flags (-O drops asserts, round 80)

// Set by stmt() when `async` precedes a def; consumed by functionDecl().
static bool s_async_def_next = false;

using nython::node::Script;
using namespace nython::node;

namespace nython::parser {

// A body's docstring: its first statement, when that is a string literal.
static bool docstringOf(const node_ptr& body, std::string& out){
    if(!body) return false;
    // -OO (round 81): docstrings are dropped, as CPython compiles them -
    // __doc__ is None
    if(nyrt::cli_flags().optimize >= 2) return false;
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

// VarDeclNode::unpack for n targets, the starred one at `star` (-1: none):
// n exactly, or -3 - (n - 1) - "at least n - 1" (round 77; -1 is a starred
// target list of unknown length, -2 no unpacking).
static int unpackCode(int n, int star){
    return star < 0 ? n : -3 - (n - 1);
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
        // nonlocal / const / global binding forms (NyScope.hpp); not in ast
        // mode (round 83: ast.parse checks no scopes - CPython's symtable
        // pass reports those at compile time)
        // round 85: with the source, which tells whether it is Python-language
        // (Python's binding rule; `stdin` is the engines' own text - the prelude)
        if(!ast_mode_){
            std::string file = scanner->source.fileName();
            if(file == "stdin") file.clear();
            nython::scope::check(root, file, scanner->source.sourceCode());
        }
        return root;
    }
    catch (SyntaxError& ex) { throw ex; }
}

// ── ast mode (round 83) ──────────────────────────────────────────────────────
// lib/ast.ny's ast.parse is built on this parser: `_ny_ast(source, mode)`
// (src/builtins/text.cpp) parses with ast_mode_ set, and the parser then
// keeps Python's shape where it would desugar (PyAstNode: decorators,
// chained comparisons, slices, f-strings, starred displays, unpacking
// assignments, match, except clauses, imports, with items ...), records
// the token span of each node it returns (ast_spans_; ast_outer_ for the
// parentheses around an expression), does not mangle private names, keeps
// asserts under -O and runs no scope checks. The tree is never executed.

// The last token read, past the newlines/indentation/semicolons that end a
// statement.
int Parser::lastTok() const {
    int i = scanner->current - 1;
    while(i >= 0){
        TokenType t = scanner->tokens[(size_t)i].type();
        if(t != TokenType::NewLine && t != TokenType::Indent && t != TokenType::Dedent
           && t != TokenType::SemiColon && t != TokenType::End) break;
        i--;
    }
    return i;
}

void Parser::spanSet(const Node* n, int t0){
    if(!n || ast_spans_.count(n)) return;
    int nt = (int)scanner->tokens.size();
    while(t0 < nt){
        TokenType t = scanner->tokens[(size_t)t0].type();
        if(t != TokenType::NewLine && t != TokenType::Indent && t != TokenType::Dedent) break;
        t0++;
    }
    int t1 = lastTok();
    if(t0 < 0 || t1 < t0) return;
    ast_spans_[n] = {t0, t1};
}

// The tree for ast.parse(source, mode=...): "exec" a Script, "eval" one
// expression (a tuple display allowed), "single" a Script of the
// statements, "func_type" a PyAstNode FunctionType.
node_ptr Parser::parseAst(const std::string& mode){
    ast_mode_ = true;
    if(mode == "eval" || mode == "func_type"){
        while(have(TokenType::NewLine) || have(TokenType::Indent) || have(TokenType::Dedent)) {}
        Token tok = token();
        node_ptr result;
        if(mode == "eval"){
            if(see(TokenType::End)) throw SyntaxError(tok.location(), "invalid syntax");
            int t0 = scanner->current;
            result = exprList(tok);
            spanSet(result.get(), t0);
        } else {
            // (argtypes) -> returns
            mustBe(TokenType::ParenOpen);
            std::vector<node_ptr> args;
            while(!see(TokenType::ParenClose) && !see(TokenType::End)){
                int a0 = scanner->current;
                node_ptr a;
                if(have(TokenType::Mul) || have(TokenType::Exp)){
                    Token st = prev();
                    a = make_node<UnaryNode>(st, expression());
                } else a = expression();
                spanSet(a.get(), a0);
                args.push_back(a);
                if(!have(TokenType::Comma)) break;
            }
            mustBe(TokenType::ParenClose);
            mustBe(TokenType::RightArrow);
            int r0 = scanner->current;
            node_ptr ret = expression();
            spanSet(ret.get(), r0);
            auto ft = std::make_shared<PyAstNode>(tok, "FunctionType");
            ft->list("argtypes", args)->kid("returns", ret);
            result = ft;
        }
        while(have(TokenType::NewLine) || have(TokenType::Indent) || have(TokenType::Dedent) || have(TokenType::SemiColon)) {}
        if(!see(TokenType::End)) throw SyntaxError(token().location(), "invalid syntax");
        return result;
    }
    return parse();
}

std::string Parser::dottedName(){
    // Accept identifier or string literal for import paths
    if (have(TokenType::String)) {
        return prev().value;
    }
    // a module's name is not mangled (round 78: `import __x` in a class
    // binds the mangled name, importStmt, but imports __x)
    mangle_stack_.push_back(std::string());
    struct Pop { std::vector<std::string>& s; ~Pop(){ s.pop_back(); } } pop_{mangle_stack_};
    // A module may be named by a word that is a Nython keyword (`import
    // enum`, `import struct`): identifier() takes those.
    std::string name = identifier();
    while(have(TokenType::Dot)) name += "." + identifier();
    return name;
}

static bool isAugAssignType(TokenType t);
static void checkAssignable(const node_ptr& t);

// Soft keywords (round 77). Nython reserves many words Python programs use
// as ordinary names (`new = old + 1`, `def f(ref):`, `obj.self`,
// `match = re.match(...)`). Each is a keyword only where its construct
// starts - `new A()`, `var x = 1`, `ref x = y`, `unless c:`, `loop:` - and
// an ordinary name everywhere else. These are the words that can be names;
// the literals (true/false/none/null/undefined) stay reserved, as Python's
// True/False/None are.
static bool nameKeyword(TokenType t){
    switch(t){
    case TokenType::Repeat: case TokenType::Execute: case TokenType::Delete: case TokenType::Default:
    case TokenType::Final: case TokenType::Loop: case TokenType::Block: case TokenType::Use:
    case TokenType::Static: case TokenType::Public: case TokenType::Private: case TokenType::Protected:
    case TokenType::Abstract: case TokenType::Print: case TokenType::Typeof: case TokenType::Sizeof:
    case TokenType::Ref: case TokenType::Let: case TokenType::Var: case TokenType::Const:
    case TokenType::NameSpace: case TokenType::Package: case TokenType::Interface: case TokenType::Struct:
    case TokenType::Enum: case TokenType::EndBlock: case TokenType::Fn: case TokenType::Fun:
    case TokenType::Function: case TokenType::New: case TokenType::Do: case TokenType::Switch:
    case TokenType::Case: case TokenType::Then: case TokenType::Extends: case TokenType::Inherits:
    case TokenType::Implements: case TokenType::Unless: case TokenType::Until: case TokenType::Equals:
    case TokenType::Instanceof: case TokenType::Subclassof: case TokenType::Parentof:
    case TokenType::Self: case TokenType::This:
        return true;
    default:
        return false;
    }
}

// After a word at the start of a statement: does the token at peek(k) show
// the word is a name (`ref = x`, `new.attr`, `loop[0] += 1`, `match, x =
// ...`, `print == f`)? Only tokens that cannot begin the expression or body
// a keyword statement takes count (so `print -1`, `unless (x):` and `repeat
// 3:` stay statements).
bool Parser::usedAsName(int k){
    Token nt = peek(k);
    TokenType t = nt.type();
    if(t == TokenType::Assign || isAugAssignType(t) || t == TokenType::NullCoalesceAssign) return true;
    switch(t){
    case TokenType::Dot: case TokenType::OptDot: case TokenType::OptBracket: case TokenType::Comma:
    case TokenType::SemiColon: case TokenType::End: case TokenType::ParenClose: case TokenType::BracketClose:
    case TokenType::BraceClose: case TokenType::Equal: case TokenType::NotEqual: case TokenType::DeepEqual:
    case TokenType::NotDeepEqual: case TokenType::Less: case TokenType::Great: case TokenType::LessEqual:
    case TokenType::GreatEqual: case TokenType::Div: case TokenType::Mod: case TokenType::RevDiv:
    case TokenType::Exp: case TokenType::BinOr: case TokenType::BinAnd: case TokenType::BinXor:
    case TokenType::ShiftLeft: case TokenType::ShiftRight: case TokenType::At: case TokenType::And:
    case TokenType::Or: case TokenType::Xor: case TokenType::In: case TokenType::Is: case TokenType::If:
    case TokenType::Else: case TokenType::For: case TokenType::NullCoalesce: case TokenType::Interval:
        return true;
    default:
        return false;
    }
}

// `var`/`let`/`const`/`ref` begin a declaration when a name follows
// (`ref x = y`, `let a, b = 1, 2`; `var (a, b), c = ...` and `var *h, t =
// ...` too); `ref = weakref.ref`, `const.x` and `let(...)` use the word as
// a name.
bool Parser::declFollows(){
    TokenType t1 = peek(1).type();
    if(t1 == TokenType::Identifier) return !nython::is_dyntok_value(peek(1).value);
    if(see(TokenType::Var) && (t1 == TokenType::ParenOpen || t1 == TokenType::Mul)) return true;
    if(nameKeyword(t1) || t1 == TokenType::Await || t1 == TokenType::Async){
        TokenType t2 = peek(2).type();
        return t2 == TokenType::Assign || t2 == TokenType::Comma || t2 == TokenType::Colon
            || t2 == TokenType::NewLine || t2 == TokenType::SemiColon || t2 == TokenType::End;
    }
    return false;
}

std::string Parser::identifier(){
    // Allow keywords to be used as identifiers (function/variable names)
    if(see(TokenType::Identifier)) {
        next();
        return prev().value;
    }
    // Accept common keywords as identifiers when used as names
    TokenType t = token().type();
    if(nameKeyword(t)) {   // the soft keywords (round 77)
        std::string name = token().value;
        next();
        return name;
    }
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
        ||t==TokenType::ShiftAssign||t==TokenType::ComplementAssign||t==TokenType::MatMulAssign;
}

bool Parser::isAugAssign(){
    return see(TokenType::AddAssign)||see(TokenType::SubAssign)||see(TokenType::MulAssign)
        ||see(TokenType::DivAssign)||see(TokenType::AndAssign)||see(TokenType::OrAssign)
        ||see(TokenType::XorAssign)||see(TokenType::BinAndAssign)||see(TokenType::BinOrAssign)
        ||see(TokenType::BinXorAssign)||see(TokenType::ModAssign)||see(TokenType::RevDivAssign)
        ||see(TokenType::ExpAssign)||see(TokenType::ShiftLeftAssign)||see(TokenType::ShiftRightAssign)
        ||see(TokenType::ShiftAssign)||see(TokenType::ComplementAssign)
        ||see(TokenType::NullCoalesceAssign)||see(TokenType::MatMulAssign);
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
    if(see(TokenType::Package) && !usedAsName() && have(TokenType::Package)){   // `package = 1` is a name (round 77)
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
    if(module_ann_used_ && !ast_mode_) node->add(annotationsDecl(tok));   // round 83: not in ast mode
    for(auto& s : stmts) node->add(s);
    return node;
}

node_ptr Parser::stmt(){
    while(have(TokenType::NewLine)||have(TokenType::SemiColon)) {}
    if(see(TokenType::End)) return nullptr;
    return statement();
}

node_ptr Parser::statement_(){   // round 83: statement() records its span in ast mode (Parser.hpp)
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

    // Variable declarations (soft keywords: `ref = x` is an assignment)
    if(see(TokenType::Var) && declFollows()) return varDecl(false, false);
    if(see(TokenType::Let) && declFollows()) return varDecl(false, true);
    if(see(TokenType::Const) && declFollows()) return varDecl(true, false);
    if(see(TokenType::Ref) && declFollows()) return varDecl(false, false);

    // Control flow
    if(see(TokenType::Unless) && !usedAsName() && peek().type() != TokenType::NewLine) {
        Token tok = token();
        next(); // consume unless
        bool has_paren = have(TokenType::ParenOpen);
        node_ptr cond = expression();
        if(has_paren) mustBe(TokenType::ParenClose);
        have(TokenType::Colon); if(see(TokenType::Then) && !usedAsName()) next();
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
    if(see(TokenType::Repeat) && !usedAsName()) return repeatStmt();

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
        // Any expression (PEP 614, round 77): a (dotted) name, a call of
        // one (its arguments parsed as a call's: `@lru_cache(typed=True)`),
        // `@decos[1]`, `@(lambda f: f)`, `@a.b(1).c`. Keywords that are
        // names (`@repeat`, `@final`) read as names, as everywhere.
        node_ptr dec_expr = ternary();
        have(TokenType::NewLine);
        // `@staticmethod async def f(x)`: no method (round 78, functionDecl)
        if(dec_expr && dec_expr->type() == NodeType::VARIABLE && dec_expr->value() == "staticmethod") next_def_static_ = true;
        // Parse the decorated function or class
        node_ptr target = statement();
        if(ast_mode_){
            // round 83: Python's decorator_list (outermost first); a stacked
            // decorator's statement() returned a Decorated already
            if(target && target->type() == NodeType::PY_AST && static_cast<PyAstNode*>(target.get())->kind == "Decorated"){
                auto& decs = static_cast<PyAstNode*>(target.get())->lists[0].second;
                decs.insert(decs.begin(), dec_expr);
                return target;
            }
            auto d = std::make_shared<PyAstNode>(dec_tok, "Decorated");
            d->list("decorators", {dec_expr})->kid("target", target);
            return d;
        }
        {
            // a decorated function's co_firstlineno is its first decorator's
            // line, as in CPython (round 77; stacked decorators wrap it in
            // blocks [__decN__ = d, target, f = __decN__(f)])
            node_ptr t = target;
            while(t && t->type() == NodeType::BLOCK && t->statements().size() == 3) t = t->statements()[1];
            if(t && t->type() == NodeType::FUNCTION) static_cast<FunctionNode*>(t.get())->first_line = dec_tok.line();
        }
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
            if(ast_mode_){   // round 83: AsyncFor, its iterable as written
                ast_flags_[f.get()] = "async";
                while(have(TokenType::NewLine)) {}
                if(see(TokenType::Else) && f->type() == NodeType::FOR){
                    next(); have(TokenType::Colon);
                    static_cast<ForNode*>(f.get())->else_branch = blockOrStmt();
                }
                return f;
            }
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
            || next_type == TokenType::ParenOpen
            // `fn == g`, `function is None` (round 77). `def` is always a
            // declaration, and `fn xor(...)` declares a function named xor
            || (!see(TokenType::Def) && usedAsName()
                && !(next_type == TokenType::Xor && peek(2).type() == TokenType::ParenOpen)));
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
            || nt == TokenType::NewLine || nt == TokenType::End || usedAsName();
    };
    if(see(TokenType::Class)) return classDecl();
    if(see(TokenType::Interface) && !soft_name()) return interfaceDecl();
    if(see(TokenType::Struct) && !soft_name()) return structDecl();
    if((see(TokenType::Typeof)||see(TokenType::Sizeof)) && peek().type() == TokenType::ParenOpen) {
        Token tok = token();
        // typeof(x) is Nython's name of x's type ("int", "string"); type(x)
        // is Python's type object (round 77). sizeof(x) calls whatever
        // `sizeof` names - the builtin (len) unless the program binds it
        // (round 83: it was rewritten to len(x), so a program's own sizeof,
        // ctypes', was never called and its own len was)
        std::string fn_name = tok.value;
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
    if(see(TokenType::Abstract) && peek().type() == TokenType::Class) { next(); return classDecl(); } // abstract class
    // `loop:` / `block:` are statements; `loop.run(...)`, `loop = ...`,
    // `block[0]` use them as names (asyncio's loop, round 77).
    auto keyword_as_name = [&]() {
        TokenType nt = peek().type();
        return nt == TokenType::Dot || nt == TokenType::Assign || nt == TokenType::BracketOpen
            || nt == TokenType::ParenOpen || nt == TokenType::Comma || nt == TokenType::AddAssign
            || nt == TokenType::SubAssign || nt == TokenType::MulAssign || nt == TokenType::DivAssign
            || usedAsName();
    };
    if(see(TokenType::Loop) && !keyword_as_name()) return loopStmt();
    if(see(TokenType::Block) && !keyword_as_name()) return blockStmt();
    if(see(TokenType::Repeat) && !usedAsName()) return repeatStmt();
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
                                  && (peek(1).type() == TokenType::Identifier
                                      || (nameKeyword(peek(1).type())   // `nonlocal new, ref` (round 77)
                                          && (peek(2).type() == TokenType::Comma || peek(2).type() == TokenType::NewLine
                                              || peek(2).type() == TokenType::SemiColon || peek(2).type() == TokenType::End))))) {
        bool is_global = see(TokenType::Global);
        next(); // consume 'global' / 'nonlocal'
        // The declarations stay in the tree as GlobalNodes (no-ops on both
        // engines) so NyScope can check them: `nonlocal x` needs an
        // enclosing function's x, and a walrus / `except ... as` / `with
        // ... as` of a global-declared name binds the module's.
        auto decls = make_node<BlockNode>(token());
        std::vector<std::string> names;   // round 83: ast mode's Global / Nonlocal
        do {
            Token ntok = token();
            std::string n = identifier();
            if(!outer_decls_.empty()) outer_decls_.back().push_back(n);
            if(is_global && !global_decls_.empty()) global_decls_.back().push_back(n);
            decls->add(make_node<GlobalNode>(ntok, n, !is_global));
            names.push_back(n);
        } while(have(TokenType::Comma));
        have(TokenType::SemiColon); have(TokenType::NewLine);
        if(ast_mode_){
            auto g = std::make_shared<PyAstNode>(decls->token(), is_global ? "Global" : "Nonlocal");
            g->strl("names", names);
            return g;
        }
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
    // `raise`/`del` are Python's keywords; their Nython spellings `throw`
    // and `delete` are names when used as one (round 77).
    if(see(TokenType::Raise) && !(value() == "throw" && usedAsName())) return raiseStmt();
    if(see(TokenType::Assert)) return assertStmt();

    // Misc
    // round 83: in ast mode `print(...)` is Python's call (an expression
    // statement); the Nython statement form `print x` stays a statement
    if(see(TokenType::Print) && !usedAsName() && !(ast_mode_ && peek().type() == TokenType::ParenOpen)) return printStmt();
    if(see(TokenType::Import)||see(TokenType::From)) return importStmt();
    if(see(TokenType::Delete) && !(value() == "delete" && usedAsName())) return deleteStmt();
    if(see(TokenType::With)) return withStmt();
    // `match` is Python's soft keyword: a statement only when its line is
    // `match <subject>:` ending a header (`match = re.match(...)`,
    // `match.group(1)`, `match(x)` use the name); `switch` likewise.
    if(see(TokenType::Switch) && !usedAsName()) {
        if(value() != "match") return switchStmt();
        int depth = 0;
        bool header = false;
        for(int k = 1; k < 4096; k++){
            TokenType tt = peek(k).type();
            if(tt == TokenType::End) break;
            if(tt == TokenType::ParenOpen || tt == TokenType::BracketOpen || tt == TokenType::BraceOpen) { depth++; continue; }
            if(tt == TokenType::ParenClose || tt == TokenType::BracketClose || tt == TokenType::BraceClose) { if(--depth < 0) break; continue; }
            if(depth > 0) continue;
            if(tt == TokenType::NewLine || tt == TokenType::SemiColon || tt == TokenType::Indent || tt == TokenType::Dedent) break;
            if(tt == TokenType::Colon){
                TokenType after = peek(k + 1).type();
                header = k > 1 && (after == TokenType::NewLine || after == TokenType::Indent
                                   || after == TokenType::BraceOpen || after == TokenType::End);
                break;
            }
        }
        if(header) return switchStmt();
    }

    // Lua-style  do ... end  as a standalone statement
    // (blockOrStmt handles do-blocks as sub-blocks of while/for; this handles top-level)
    if(see(TokenType::Do) && peek().type() != TokenType::BraceOpen && !usedAsName()) {
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

    // Block - or a dict/set display starting an expression statement
    // (`{}["x"]` raises KeyError, round 77)
    if(see(TokenType::BraceOpen)) return (ast_mode_ || braceIsExpression()) ? expressionStmt() : block();   // round 83: Python's is always a display

    // Annotated assignment (PEP 526): `x: int = 5`, `self.x: T = v`,
    // `x: int` (an annotation alone binds nothing). The annotation is
    // parsed and dropped; `name: T = v` declares name in the current
    // scope, as Python's annotated assignment makes it local.
    if(see(TokenType::Identifier) || see(TokenType::Self) || see(TokenType::This) || nameKeyword(token().type())) {
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
                            && (peek(k + 1).clazz() != TokenClass::Keyword || after == TokenType::None
                                || nameKeyword(after));
                break;
            }
            bool name = tt == TokenType::Identifier || tt == TokenType::Self || tt == TokenType::This || nameKeyword(tt);
            if(name && prevt == TokenType::Dot){ prevt = tt; continue; }
            if(tt == TokenType::Dot && prevt != TokenType::Dot){ prevt = tt; continue; }
            if(tt == TokenType::BracketOpen && prevt != TokenType::Dot){ depth++; continue; }
            break;
        }
        if(annotated){
            Token tok0 = token();
            bool simple = k == 1 && (see(TokenType::Identifier) || nameKeyword(token().type()));
            node_ptr target = asTarget(postfix());
            mustBe(TokenType::Colon);
            int a0 = scanner->current;
            node_ptr ann = ternary();   // the annotation (not expression(): `T = v` is not an assignment)
            int a1 = scanner->current;
            node_ptr value = nullptr;
            if(ast_mode_){
                // round 83: AnnAssign (a tuple display may be its value)
                if(have(TokenType::Assign)) value = see(TokenType::Yield) ? expression() : exprList(token());
                consumed_semi_ = have(TokenType::SemiColon);
                if(!consumed_semi_) have(TokenType::NewLine);
                auto n = std::make_shared<PyAstNode>(tok0, "AnnAssign");
                n->kid("target", target)->kid("annotation", ann)->kid("value", value)->num("simple", simple ? 1 : 0);
                return n;
            }
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

    // Assignment with unpacking or several targets at statement level -
    // Python's `(star_targets '=')+ star_expressions`:
    //   a, b = b, a        x.y, z[0] = f()        a, *rest = seq
    //   (a, b), c = (1, 2), 3      [a, *b] = v      i, = [9]
    //   a, b = c, d = 1, 2  (the value is evaluated once, then every target
    //                        list takes it, left to right - round 77)
    // Found by scanning the statement for its top-level `=`s: this form is
    // used when a comma comes before the last one or a target is bracketed.
    if(see(TokenType::Identifier) || see(TokenType::Mul) || see(TokenType::ParenOpen) || see(TokenType::BracketOpen)
       || nameKeyword(token().type())) {
        std::vector<int> eqs;          // offsets of the top-level `=`s
        bool comma_before_last = false, bracketed_group = false;
        {
            // [from, to) is one bracketed target: (a, b) / [a, *b]
            auto whole_bracket = [&](int from, int to) {
                if(to - from < 2) return false;
                TokenType o = peek(from).type(), c = peek(to - 1).type();
                if(!((o == TokenType::ParenOpen && c == TokenType::ParenClose)
                     || (o == TokenType::BracketOpen && c == TokenType::BracketClose))) return false;
                int d2 = 0;
                for(int q = from; q < to; q++){
                    auto qt = peek(q).type();
                    if(qt == TokenType::ParenOpen || qt == TokenType::BracketOpen || qt == TokenType::BraceOpen) d2++;
                    else if(qt == TokenType::ParenClose || qt == TokenType::BracketClose || qt == TokenType::BraceClose){
                        if(--d2 == 0 && q != to - 1) return false;
                    }
                }
                return true;
            };
            int depth = 0, group_start = 0; bool comma = false;
            for(int k = 0; k < 4096; k++) {
                auto tt = peek(k).type();   // End is the last token: never read past it
                if(tt == TokenType::End || ((tt == TokenType::NewLine || tt == TokenType::SemiColon
                   || tt == TokenType::Indent || tt == TokenType::Dedent) && depth == 0)) break;
                if(tt == TokenType::ParenOpen || tt == TokenType::BracketOpen || tt == TokenType::BraceOpen) { depth++; continue; }
                if(tt == TokenType::ParenClose || tt == TokenType::BracketClose || tt == TokenType::BraceClose) { if(--depth < 0) break; continue; }
                if(depth != 0) continue;
                if(tt == TokenType::Lambda || tt == TokenType::Colon) break;
                if(tt == TokenType::Comma) { comma = true; continue; }
                if(tt == TokenType::Assign) {
                    if(peek(k).value != "=") break;   // :=
                    if(whole_bracket(group_start, k)) bracketed_group = true;
                    eqs.push_back(k);
                    if(comma) comma_before_last = true;
                    group_start = k + 1;
                    continue;
                }
                if(isAugAssignType(tt) || tt == TokenType::NullCoalesceAssign) break;
            }
        }
        if(!eqs.empty() && (comma_before_last || bracketed_group)) {
            Token op = token();
            Token first_tok = token();
            // round 83: t0/t1 - the group's tokens (ast mode's Tuple target)
            struct Group { std::vector<node_ptr> ts; int star = -1; bool comma = false; int t0 = -1, t1 = -1; };
            std::vector<Group> groups;
            in_assign_target_ = true;
            try {
                for(size_t g = 0; g < eqs.size(); g++){
                    Group gr;
                    gr.t0 = scanner->current;
                    while(true){
                        if(have(TokenType::Mul)) {
                            gr.star = (int)gr.ts.size();
                            Token st = prev();
                            int s0 = scanner->current - 1;
                            node_ptr t = asTarget(postfix());
                            if(ast_mode_){   // round 83: the Starred target itself
                                st.value = "*";
                                t = make_node<UnaryNode>(st, t);
                                spanSet(t.get(), s0);
                            }
                            gr.ts.push_back(t);
                        }
                        else gr.ts.push_back(asTarget(postfix()));
                        if(!have(TokenType::Comma)) break;
                        gr.comma = true;
                        if(see(TokenType::Assign)) break;
                    }
                    gr.t1 = lastTok();
                    for(auto& t : gr.ts) checkAssignable(isStarElem(t) ? static_cast<UnaryNode*>(t.get())->operand : t);
                    groups.push_back(std::move(gr));
                    op = token();
                    mustBe(TokenType::Assign);
                }
            } catch(...) { in_assign_target_ = false; throw; }
            in_assign_target_ = false;
            // the value: one expression or a tuple display (`*x` allowed)
            std::vector<node_ptr> vals;
            int v0 = scanner->current;
            node_ptr value = see(TokenType::Yield) && ast_mode_ ? expression() : exprList(op, &vals);
            consumed_semi_ = have(TokenType::SemiColon);
            if(!consumed_semi_) have(TokenType::NewLine);
            if(ast_mode_){
                // round 83: Assign(targets, value) - a target list unpacked
                // is a Tuple (bracketed ones are the Tuple/List postfix() read)
                spanSet(value.get(), v0);
                std::vector<node_ptr> targets;
                for(auto& g : groups){
                    if(g.ts.size() == 1 && !g.comma && g.star < 0) { targets.push_back(g.ts[0]); continue; }
                    auto tup = make_node<TupleNode>(first_tok);
                    for(auto& t : g.ts) tup->add(t);
                    if(g.t0 >= 0 && g.t1 >= g.t0) ast_spans_[tup.get()] = {g.t0, g.t1};
                    targets.push_back(tup);
                }
                auto n = std::make_shared<PyAstNode>(first_tok, "Assign");
                n->list("targets", targets)->kid("value", value);
                return n;
            }
            auto block = make_node<BlockNode>(op);
            auto tmp_name = [&]() { return unpackTemp(); };
            auto var_ref = [&](const std::string& n) { Token t = op; t.value = n; return make_node<VariableNode>(t); };
            auto assign_to = [&](node_ptr t, node_ptr v) { bindTarget(op, t, v, block); };
            auto unpack = [&](const std::vector<node_ptr>& ts, int si, const std::string& src) { bindTargets(op, ts, si, src, block); };
            // A target list that is one plain target takes the value itself;
            // one bracketed target, [a, *b] = v / (a, b) = v, unpacks it.
            auto unpacks = [](const Group& g){ return g.ts.size() > 1 || g.star >= 0 || g.comma; };
            // `a, b = b, a`: a display of exactly as many values needs no
            // count check (several values are all evaluated first).
            auto code_for = [&](const Group& g) {
                if(g.star < 0 && !vals.empty() && vals.size() == g.ts.size()) return -2;
                return unpackCode((int)g.ts.size(), g.star);
            };
            if(groups.size() == 1) {
                auto& g = groups[0];
                if(!unpacks(g)) { assign_to(g.ts[0], value); return block; }
                std::string src = tmp_name();
                auto decl = make_node<VarDeclNode>(op, src, value, false, false);
                static_cast<VarDeclNode*>(decl.get())->unpack = code_for(g);
                block->add(decl);
                unpack(g.ts, g.star, src);
                return block;
            }
            std::string src = tmp_name();
            block->add(make_node<VarDeclNode>(op, src, value, false, false));
            for(auto& g : groups) {
                if(!unpacks(g)) { assign_to(g.ts[0], var_ref(src)); continue; }
                std::string gs = tmp_name();
                auto decl = make_node<VarDeclNode>(op, gs, var_ref(src), false, false);
                static_cast<VarDeclNode*>(decl.get())->unpack = code_for(g);
                block->add(decl);
                unpack(g.ts, g.star, gs);
            }
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
    // `x = 1, 2`, `x = y = *a, b`, `x += 1, 2`, `f(), g()`: a tuple display
    // - the value of the (innermost) assignment, else the statement's own
    // expression (round 77: the comma was a syntax error).
    if(see(TokenType::Comma) || isStarElem(expr)
       || (expr && expr->type() == NodeType::ASSIGNMENT && isStarElem(static_cast<AssignmentNode*>(expr.get())->value_node))){
        Token ct = token();
        node_ptr* slot = &expr;
        while(*slot && (*slot)->type() == NodeType::ASSIGNMENT){
            node_ptr& v = static_cast<AssignmentNode*>(slot->get())->value_node;
            if(!v || v->type() != NodeType::ASSIGNMENT){ slot = &v; break; }
            slot = &v;
        }
        if(*slot && (*slot)->type() == NodeType::ASSIGNMENT_AUG)
            slot = &static_cast<AugAssignNode*>(slot->get())->value_node;
        *slot = exprList(ct, nullptr, *slot);
    }
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
    return expr;
}

// Python's star_expressions: one expression, or a comma-separated tuple
// display that may hold `*x` items (`return 1, 2`, `yield *a, b`, `x =
// *a, b`) - a tuple, as in Python (round 77: `return a, b` made a list).
// `first` is an item already parsed. When `items` is given and the result
// is a display without `*`, it receives the items.
static bool endsExprList(TokenType t){
    return t == TokenType::NewLine || t == TokenType::SemiColon || t == TokenType::End || t == TokenType::Dedent
        || t == TokenType::ParenClose || t == TokenType::BracketClose || t == TokenType::BraceClose
        || t == TokenType::Colon || t == TokenType::Assign || t == TokenType::Indent;
}
node_ptr Parser::exprList(Token tok, std::vector<node_ptr>* items, node_ptr first){
    if(!first) first = starElem();
    if(!see(TokenType::Comma)){
        if(isStarElem(first)) throw SyntaxError(tok.location(), "can't use starred expression here");
        return first;
    }
    std::vector<node_ptr> elems{first};
    bool starred = isStarElem(first);
    int trailing = -1;   // round 83: a trailing comma ends the tuple's span (ast mode)
    while(have(TokenType::Comma)){
        if(endsExprList(token().type())) { trailing = scanner->current - 1; break; }
        node_ptr e = starElem();
        // `a, b += 1` / `x = 1, y = 2`: an assignment is not an item
        if(e && (e->type() == NodeType::ASSIGNMENT_AUG || e->type() == NodeType::ASSIGNMENT))
            throw SyntaxError(e->token().location(), e->type() == NodeType::ASSIGNMENT_AUG
                              ? "'tuple' is an illegal expression for augmented assignment" : "invalid syntax");
        starred = starred || isStarElem(e);
        elems.push_back(e);
    }
    if(starred && !ast_mode_) return catStarred(tok, elems, "tuple");   // round 83: ast mode keeps the display
    auto tup = make_node<TupleNode>(tok);
    for(auto& e : elems) tup->add(e);
    if(items) *items = elems;
    if(ast_mode_ && trailing >= 0){
        auto o = ast_outer_.find(first.get());
        auto sp0 = ast_spans_.find(first.get());
        int t0 = (o != ast_outer_.end() && o->second.first >= 0) ? o->second.first
               : sp0 != ast_spans_.end() ? sp0->second.first : -1;
        if(t0 >= 0) ast_spans_[tup.get()] = {t0, trailing};
    }
    return tup;
}

// Binding a value to an assignment target (round 77, shared by assignment
// statements, `for` targets and `with ... as` targets): a tuple/list target
// unpacks the value through a hidden temporary - VarDeclNode::unpack makes
// both engines read an iterator into a list and check the count - and each
// element is bound in turn (nested ones recursively, the starred one to a
// slice); any other target is assigned.
std::string Parser::unpackTemp(){
    static int unpack_counter = 0;
    return "__unpack" + std::to_string(unpack_counter++) + "__";
}
void Parser::bindTarget(const Token& op, node_ptr t, node_ptr value, node_ptr block){
    if(t->type() == NodeType::TUPLE || t->type() == NodeType::LIST) {
        std::string tn = unpackTemp();
        std::vector<node_ptr> inner; int istar = -1;
        for(auto& e : t->statements()) {
            if(isStarElem(e)) {
                istar = (int)inner.size();
                inner.push_back(static_cast<UnaryNode*>(e.get())->operand);
            } else inner.push_back(e);
        }
        auto decl = make_node<VarDeclNode>(op, tn, value, false, false);
        static_cast<VarDeclNode*>(decl.get())->unpack = unpackCode((int)inner.size(), istar);
        block->add(decl);
        bindTargets(op, inner, istar, tn, block);
        return;
    }
    block->add(make_node<AssignmentNode>(op, asTarget(t), value));
}
void Parser::bindTargets(const Token& op, const std::vector<node_ptr>& ts, int si, const std::string& src, node_ptr block){
    auto var_ref = [&](const std::string& n) { Token t = op; t.value = n; return make_node<VariableNode>(t); };
    auto int_node = [&](long v) { Token t = op; t.value = std::to_string(v); t.type(TokenType::Integer); return make_node<IntegerNode>(t); };
    int n = (int)ts.size();
    int n_before = si < 0 ? n : si;
    for(int i = 0; i < n_before; i++)
        bindTarget(op, ts[i], make_node<SubscriptNode>(op, var_ref(src), int_node(i)), block);
    if(si < 0) return;
    int n_after = n - si - 1;
    // the starred target is always a list (Python's), from any sequence -
    // through the prelude's _ny_list_cat, which a program's own `list`
    // cannot shadow
    Token lt = op; lt.value = "_ny_list_cat";
    auto sl = make_node<CallNode>(op, make_node<AttributeNode>(op, var_ref(src), "slice"));
    sl->add(int_node(si));
    if(n_after > 0) sl->add(int_node(-n_after));
    auto as_list = make_node<CallNode>(lt, make_node<VariableNode>(lt));
    as_list->add(sl);
    bindTarget(op, ts[si], as_list, block);
    for(int j = 0; j < n_after; j++)
        bindTarget(op, ts[si + 1 + j], make_node<SubscriptNode>(op, var_ref(src), int_node(-(n_after - j))), block);
}

// What an assignment may bind (round 77): a name, an attribute, an item or
// a slice (spelled obj.slice(...)), or a tuple/list of those with one `*`;
// anything else is Python's SyntaxError ("cannot assign to literal").
static void checkAssignable(const node_ptr& t){
    if(!t) return;
    switch(t->type()){
    case NodeType::VARIABLE: case NodeType::ATTRIBUTE: case NodeType::SUBSCRIPT: case NodeType::SELF:
    case NodeType::OPT_CHAIN:
        return;
    case NodeType::TUPLE: case NodeType::LIST:
        for(auto& e : t->statements()) checkAssignable(isStarElem(e) ? static_cast<UnaryNode*>(e.get())->operand : e);
        return;
    case NodeType::CALL: {
        auto* c = static_cast<CallNode*>(t.get());
        if(c->callee && c->callee->type() == NodeType::ATTRIBUTE && static_cast<AttributeNode*>(c->callee.get())->attr == "slice") return;
        throw SyntaxError(t->token().location(), "cannot assign to function call");
    }
    case NodeType::TRUE: case NodeType::FALSE: case NodeType::NONE: case NodeType::UNDEFINED:
        // Nython's spellings true/false/none/null are literals, but a
        // program written for both languages binds them in a branch Nython
        // never runs (`except NameError: true = True`): left as it was, an
        // assignment that does nothing. Python's True/False/None are not.
        if(t->token().value == "True" || t->token().value == "False" || t->token().value == "None")
            throw SyntaxError(t->token().location(), "cannot assign to " + t->token().value);
        return;
    case NodeType::INTEGER: case NodeType::FLOAT: case NodeType::STRING: case NodeType::BYTES:
    case NodeType::COMPLEX:
        throw SyntaxError(t->token().location(), "cannot assign to literal");
    default:
        throw SyntaxError(t->token().location(), "cannot assign to expression");
    }
}

// `self` / `this` where a name is bound - an assignment, `del`, a walrus,
// an unpacking target - are the variable of that name (round 77), as in
// Python; inside tuple/list targets too.
node_ptr Parser::asTarget(node_ptr t){
    if(!t) return t;
    if(t->type() == NodeType::SELF){
        Token vt = t->token();
        if(vt.value != "this") vt.value = "self";
        return make_node<VariableNode>(vt);
    }
    if(t->type() == NodeType::TUPLE || t->type() == NodeType::LIST){
        auto& el = t->type() == NodeType::TUPLE ? static_cast<TupleNode*>(t.get())->elements
                                                : static_cast<ListNode*>(t.get())->elements;
        for(auto& e : el){
            if(e && e->type() == NodeType::UNARY && static_cast<UnaryNode*>(e.get())->op == "*"){
                auto* u = static_cast<UnaryNode*>(e.get());
                u->operand = asTarget(u->operand);
            } else e = asTarget(e);
        }
    }
    return t;
}

// See Parser.hpp: the token after the `}` matching this `{` continues an
// expression, or the braces hold a display (`{"k": 1}`, `{1, 2}`, `{**d}`).
bool Parser::braceIsExpression(){
    int depth = 0, k = 0;
    for(; k < 1 << 20; k++){
        TokenType tt = peek(k).type();
        if(tt == TokenType::End) return false;
        if(tt == TokenType::BraceOpen || tt == TokenType::ParenOpen || tt == TokenType::BracketOpen) depth++;
        else if(tt == TokenType::BraceClose || tt == TokenType::ParenClose || tt == TokenType::BracketClose){
            if(--depth == 0) break;
        }
    }
    TokenType after = peek(k + 1).type();
    switch(after){
    // what ends a statement or follows a block is not a continuation
    case TokenType::SemiColon: case TokenType::End: case TokenType::NewLine: case TokenType::Dedent:
    case TokenType::Indent: case TokenType::BraceClose: case TokenType::ParenClose: case TokenType::BracketClose:
    case TokenType::Else: case TokenType::For: case TokenType::While:
        break;
    case TokenType::BracketOpen: case TokenType::ParenOpen: case TokenType::Add: case TokenType::Sub:
    case TokenType::Mul:
        return true;
    default:
        if(usedAsName(k + 1)) return true;
    }
    // the contents: `**d` / `*s`, `key: value`, or `a, b` with no `=`
    // (a block starts with a statement keyword, or binds something)
    TokenType t1 = peek(1).type();
    if(t1 == TokenType::Exp || t1 == TokenType::Mul) return true;
    bool literal = t1 == TokenType::String || t1 == TokenType::Integer || t1 == TokenType::Float
                || t1 == TokenType::Bytes || t1 == TokenType::Complex || t1 == TokenType::True
                || t1 == TokenType::False || t1 == TokenType::None;
    if(!literal && peek(1).clazz() == TokenClass::Keyword && !nameKeyword(t1)) return false;
    int d = 0;
    bool comma = false;
    for(int q = 1; q < k; q++){
        TokenType tt = peek(q).type();
        if(tt == TokenType::BraceOpen || tt == TokenType::ParenOpen || tt == TokenType::BracketOpen) { d++; continue; }
        if(tt == TokenType::BraceClose || tt == TokenType::ParenClose || tt == TokenType::BracketClose) { d--; continue; }
        if(d != 0) continue;
        if(tt == TokenType::Lambda) return false;
        if(tt == TokenType::Colon && !comma){
            TokenType after = peek(q + 1).type();
            return after != TokenType::NewLine && after != TokenType::Indent;
        }
        if(tt == TokenType::Comma) { comma = true; continue; }
        if(tt == TokenType::Assign || isAugAssignType(tt) || tt == TokenType::SemiColon || tt == TokenType::NewLine
           || tt == TokenType::Indent) return false;
    }
    if(comma) return true;
    // `{x}` alone on a line is a set display (round 78: it read as a block
    // holding x - harmless, but `{[1]}` did not raise "unhashable type"),
    // unless a soft keyword starts a statement there (`{ print "x" }`,
    // `{ repeat 3: ... }`)
    if(k <= 1) return false;
    if(nameKeyword(t1) && !usedAsName(2)) return false;
    return true;
}

node_ptr Parser::expression(){
    return assignment();
}

node_ptr Parser::assignment_(){   // round 83: assignment() records its span in ast mode (Parser.hpp)
    node_ptr left = ternary();
    // `self = x`, `(self := x)`: the name (round 77)
    if(left && left->type() == NodeType::SELF && (see(TokenType::Assign) || isAugAssign()))
        left = asTarget(left);
    // name := value (the lexer gives := the Assign token type with value
    // ":="): an expression that binds and yields the value. It used to parse
    // as a plain assignment, which is a statement - `if (n := len(L)) > 2`
    // compared against a leftover stack value on the VM.
    if(see(TokenType::Assign) && token().value == ":=" && left && left->type() == NodeType::VARIABLE){
        Token op = token(); next();
        node_ptr init = ternary();
        if(ast_mode_){   // round 83: NamedExpr, its target the Name node
            auto n = std::make_shared<PyAstNode>(op, "NamedExpr");
            n->kid("target", left)->kid("value", init);
            return n;
        }
        return make_node<WalrusNode>(op, left->value(), init);
    }
    // `a?.b = v` has no meaning when a is none: an optional chain is read-only.
    if(left && left->type() == NodeType::OPT_CHAIN && (see(TokenType::Assign) || isAugAssign()))
        throw SyntaxError(token().location(), "cannot assign to an optional chain (?. / ?[)");
    if(see(TokenType::Assign)) checkAssignable(left);   // `f() = 1`, `1 = x` (round 77)
    if(have(TokenType::Assign)){
        Token op = prev();
        // `x = *a, b`: the value is a tuple display (expressionStmt)
        node_ptr right = see(TokenType::Mul) ? starElem() : assignment(); // right-associative
        return make_node<AssignmentNode>(op, left, right);
    }
    if(isAugAssign()){
        Token op = token();
        next();
        node_ptr right = see(TokenType::Mul) ? starElem() : assignment();
        return make_node<AugAssignNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::ternary_(){   // round 83: ternary() records its span in ast mode (Parser.hpp)
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
           && !see(TokenType::ParenClose) && !see(TokenType::BracketClose) && !see(TokenType::BraceClose)
           && !see(TokenType::Comma) && !see(TokenType::Colon) && !see(TokenType::Dedent))
            yexpr = exprList(tok);   // `x = yield a, b` yields a tuple (round 77)
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
node_ptr Parser::coalesce_(){   // round 83: coalesce() records its span in ast mode (Parser.hpp)
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
node_ptr Parser::rangeExpr_(){   // round 83: rangeExpr() records its span in ast mode (Parser.hpp)
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
        if(inclusive && ast_mode_){   // round 83: NyRange(inclusive=1)
            auto r = make_node<RangeNode>(tok, lo, hi, step);
            ast_flags_[r.get()] = "inclusive";
            return r;
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

node_ptr Parser::logicalOr_(){   // round 83: logicalOr() records its span in ast mode (Parser.hpp)
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
node_ptr Parser::logicalAnd_(){   // round 83: logicalAnd() records its span in ast mode (Parser.hpp)
    // `not` binds looser than every comparison, as in Python: `not a < b`
    // is `not (a < b)` and `not x in s` is `not (x in s)`. It used to be
    // parsed only as a unary prefix (unary()), so `not 1 < 0` was
    // `(not 1) < 0`, false.
    std::function<node_ptr()> notLevel = [&]() -> node_ptr {
        if(see(TokenType::Not) && peek().type()!=TokenType::In){
            next();
            Token op = prev(); op.value = "not";
            node_ptr operand = notLevel();
            return make_node<UnaryNode>(op, operand);
        }
        return equality();
    };
    node_ptr left = notLevel();
    while(have(TokenType::And)){
        Token op = prev(); op.value = "and";
        node_ptr right = notLevel();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::bitwiseOr_(){   // round 83: bitwiseOr() records its span in ast mode (Parser.hpp)
    node_ptr left = bitwiseXor();
    while(have(TokenType::BinOr)){
        Token op = prev(); node_ptr right = bitwiseXor();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::bitwiseXor_(){   // round 83: bitwiseXor() records its span in ast mode (Parser.hpp)
    node_ptr left = bitwiseAnd();
    while(have(TokenType::BinXor)){
        Token op = prev(); node_ptr right = bitwiseAnd();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::bitwiseAnd_(){   // round 83: bitwiseAnd() records its span in ast mode (Parser.hpp)
    node_ptr left = shift();
    while(have(TokenType::BinAnd)){
        Token op = prev(); node_ptr right = shift();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::equality(){
    return comparison();
}

// Python's comparisons: < > <= >= == != in, not in, is, is not (and
// Nython's === !== equals instanceof) are one precedence level and chain -
// `a < b == c in d` is `a < b and b == c and c in d`, each operand
// evaluated once, left to right, stopping at the first false (round 77:
// == and != sat a level below the others, so `1 < 3 > 2 == 2` compared
// a bool with 2, and `in`/`is` did not chain at all). A middle operand
// that is not a plain name or literal is evaluated once into a hidden
// name.
node_ptr Parser::comparison_(){   // round 83: comparison() records its span in ast mode (Parser.hpp)
    node_ptr first = bitwiseOr();
    std::vector<Token> ops;
    std::vector<node_ptr> operands{first};
    while(true){
        Token op = token();
        std::string o;
        if(see(TokenType::Less)) o = "<";
        else if(see(TokenType::Great)) o = ">";
        else if(see(TokenType::LessEqual)) o = "<=";
        else if(see(TokenType::GreatEqual)) o = ">=";
        else if(see(TokenType::Equal)) o = "==";
        else if(see(TokenType::NotEqual)) o = "!=";
        else if(see(TokenType::DeepEqual) || see(TokenType::Equals)) o = "===";
        else if(see(TokenType::NotDeepEqual)) o = "!==";
        else if(see(TokenType::In)) o = "in";
        else if(see(TokenType::Instanceof)) o = "instanceof";
        else if(see(TokenType::Not) && peek().type() == TokenType::In) { next(); o = "not in"; }
        else if(see(TokenType::Is)) { if(peek().type() == TokenType::Not) { next(); o = "is not"; } else o = "is"; }
        else break;
        next();
        op.value = o;
        ops.push_back(op);
        operands.push_back(bitwiseOr());
    }
    if(ops.empty()) return first;
    if(ast_mode_){   // round 83: Compare(left, ops, comparators), unchained
        auto c = std::make_shared<PyAstNode>(ops[0], "Compare");
        std::vector<std::string> os;
        for(auto& o : ops) os.push_back(o.value);
        c->kid("left", operands[0])->strl("ops", os)
         ->list("comparators", std::vector<node_ptr>(operands.begin() + 1, operands.end()));
        return c;
    }
    if(ops.size() == 1) return make_node<BinaryNode>(ops[0], operands[0], operands[1]);
    auto simple = [](const node_ptr& n){
        if(!n) return true;
        switch(n->type()){
        case NodeType::VARIABLE: case NodeType::INTEGER: case NodeType::FLOAT: case NodeType::STRING:
        case NodeType::TRUE: case NodeType::FALSE: case NodeType::NONE: case NodeType::SELF: return true;
        default: return false;
        }
    };
    static int cmp_counter = 0;
    node_ptr result;
    node_ptr left = operands[0];
    for(size_t i = 0; i < ops.size(); i++){
        node_ptr right = operands[i + 1];
        node_ptr right_use = right;      // what this comparison reads
        node_ptr right_next = right;     // what the next one reads
        if(i + 1 < ops.size() && !simple(right)){
            Token t = ops[i]; t.value = "__cmp" + std::to_string(cmp_counter++) + "__";
            right_use = make_node<WalrusNode>(t, t.value, right);
            right_next = make_node<VariableNode>(t);
        }
        node_ptr cmp = make_node<BinaryNode>(ops[i], left, right_use);
        if(!result) result = cmp;
        else { Token at = ops[i]; at.value = "and"; result = make_node<BinaryNode>(at, result, cmp); }
        left = right_next;
    }
    return result;
}

node_ptr Parser::shift_(){   // round 83: shift() records its span in ast mode (Parser.hpp)
    node_ptr left = addition();
    while(have(TokenType::ShiftLeft)||have(TokenType::ShiftRight)){
        Token op = prev(); node_ptr right = addition();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::addition_(){   // round 83: addition() records its span in ast mode (Parser.hpp)
    node_ptr left = multiplication();
    while(have(TokenType::Add)||have(TokenType::Sub)){
        Token op = prev(); node_ptr right = multiplication();
        left = make_node<BinaryNode>(op, left, right);
    }
    return left;
}

node_ptr Parser::multiplication_(){   // round 83: multiplication() records its span in ast mode (Parser.hpp)
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

node_ptr Parser::power_(){   // round 83: power() records its span in ast mode (Parser.hpp)
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

node_ptr Parser::unary_(){   // round 83: unary() records its span in ast mode (Parser.hpp)
    // `new` is the instantiation operator only before a class name (`new
    // A()`, `new mod.A`); `new = old + 1`, `obj.new`, `f(new)` use the name
    // (round 77).
    if(see(TokenType::New) && peek().type() == TokenType::Identifier
       && !nython::is_dyntok_value(peek().value) && have(TokenType::New)){
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

node_ptr Parser::postfix_(){   // round 83: postfix() records its span in ast mode (Parser.hpp)
    int pf0 = scanner->current;   // round 83: where each step's span starts (ast mode)
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
            // `print(*xs, sep="-")` inside an expression (`x = print(...)`,
            // `f(print(a, end=""))`): the prelude's _ny_print, which the
            // statement form uses for these too (round 77: the builtin
            // ignored sep= on the interpreter and printed the keyword map
            // on the VM)
            if(!ast_mode_ && expr && expr->type() == NodeType::VARIABLE && expr->value() == "print"
               && expr->token().type() == TokenType::Print){
                bool needs = false;
                for(auto& a : call->args)
                    if(a->type() == NodeType::KEYWORD_ARG || isStarElem(a)
                       || (a->type() == NodeType::UNARY && static_cast<UnaryNode*>(a.get())->op == "**")) needs = true;
                if(needs){
                    Token pt = expr->token(); pt.value = "_ny_print";
                    call->callee = make_node<VariableNode>(pt);
                }
            }
            expr = call;
            if(ast_mode_) spanSet(expr.get(), pf0);   // round 83
        } else if(have(TokenType::BracketOpen)){
            // Subscript or slice
            expr = parseSubscriptTail(prev(), expr);
            if(ast_mode_) spanSet(expr.get(), pf0);   // round 83
        } else if(have(TokenType::Dot)){
            // Attribute access.
            Token tok = token();
            std::string attr = memberName();
            expr = make_node<AttributeNode>(tok, expr, attr);
            if(ast_mode_) spanSet(expr.get(), pf0);   // round 83
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
        // `f(x := 1)` is a positional argument, a walrus (round 78: the
        // lexer gives := the Assign type, so it read as the keyword x)
        if(word_tok(token()) && peek(1).type() == TokenType::Assign && peek(1).value != ":="
           && peek(2).type() != TokenType::Assign) { // distinguish name=val from name==val
            Token kw_tok = rawToken();   // a keyword's name is not mangled (round 78)
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
    int p0 = scanner->current - 1;   // round 83: the `(`
    if(!see(TokenType::ParenClose)){
        call->add(parse_call_arg());
        while(have(TokenType::Comma) && !see(TokenType::ParenClose)){
            call->add(parse_call_arg());
        }
    }
    mustBe(TokenType::ParenClose);
    // round 83: a generator expression that is the only argument has the
    // call's parentheses (CPython's positions)
    if(ast_mode_ && call->args.size() == 1 && call->args[0]->type() == NodeType::COMPREHENSION
       && static_cast<ComprehensionNode*>(call->args[0].get())->kind == ComprehensionNode::GEN
       && !ast_spans_.count(call->args[0].get()))
        ast_spans_[call->args[0].get()] = {p0, scanner->current - 1};
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
    if(ast_mode_){
        // round 83: Python's subscript - Slice(lower, upper, step) nodes and
        // expressions, a Tuple of them when there is a comma
        std::vector<node_ptr> items;
        bool comma = false;
        int tup0 = scanner->current;
        while(!see(TokenType::BracketClose) && !see(TokenType::End)){
            int s0 = scanner->current;
            node_ptr lo, hi, st;
            bool is_slice = false;
            if(!see(TokenType::Colon)) lo = starElem();
            if(see(TokenType::Colon)){
                is_slice = true;
                next();
                if(!see(TokenType::Colon) && !see(TokenType::Comma) && !see(TokenType::BracketClose)) hi = expression();
                if(have(TokenType::Colon) && !see(TokenType::Comma) && !see(TokenType::BracketClose)) st = expression();
            }
            if(is_slice){
                auto sl = std::make_shared<PyAstNode>(tok, "Slice");
                sl->kid("lower", lo)->kid("upper", hi)->kid("step", st);
                spanSet(sl.get(), s0);
                items.push_back(sl);
            } else items.push_back(lo);
            if(!have(TokenType::Comma)) break;
            comma = true;
        }
        int tup1 = lastTok();
        mustBe(TokenType::BracketClose);
        node_ptr index;
        if(comma || items.size() != 1){
            auto tup = make_node<TupleNode>(tok);
            for(auto& it : items) tup->add(it);
            if(tup1 >= tup0) ast_spans_[tup.get()] = {tup0, tup1};
            index = tup;
        } else index = items[0];
        return make_node<SubscriptNode>(tok, expr, index);
    }
    // A subscript list with a slice in it - `x[1:2, ::3]`, `x[:, 0]`,
    // `x[0, 1:]` (round 77: a syntax error) - indexes with a tuple whose
    // slices are slice objects, as Python builds it. A lone slice keeps the
    // expr.slice(...) form below, which both engines (and slice assignment)
    // read.
    {
        int depth = 0;
        bool comma = false, colon = false;
        for(int k = 0; k < 1 << 20; k++){
            TokenType tt = peek(k).type();
            if(tt == TokenType::End) break;
            if(tt == TokenType::ParenOpen || tt == TokenType::BracketOpen || tt == TokenType::BraceOpen) { depth++; continue; }
            if(tt == TokenType::ParenClose || tt == TokenType::BracketClose || tt == TokenType::BraceClose) { if(--depth < 0) break; continue; }
            if(depth != 0) continue;
            if(tt == TokenType::Lambda) break;
            if(tt == TokenType::Comma) comma = true;
            else if(tt == TokenType::Colon) colon = true;
        }
        if(comma && colon){
            Token st = tok; st.value = "slice";
            auto tup = make_node<TupleNode>(tok);
            while(!see(TokenType::BracketClose)){
                node_ptr parts[3] = {nullptr, nullptr, nullptr};
                bool is_slice = false;
                if(!see(TokenType::Colon)) parts[0] = expression();
                for(int p = 1; p < 3 && see(TokenType::Colon); p++){
                    next();
                    is_slice = true;
                    if(!see(TokenType::Colon) && !see(TokenType::Comma) && !see(TokenType::BracketClose)) parts[p] = expression();
                }
                if(is_slice){
                    auto sl = make_node<CallNode>(st, make_node<VariableNode>(st));
                    for(auto& pp : parts) sl->add(pp ? pp : make_none_node());
                    tup->add(sl);
                } else tup->add(parts[0]);
                if(!have(TokenType::Comma)) break;
            }
            mustBe(TokenType::BracketClose);
            return make_node<SubscriptNode>(tok, expr, tup);
        }
    }
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

node_ptr Parser::primary_(){   // round 83: primary() records its span in ast mode (Parser.hpp)
    // `...` where an expression starts is the Ellipsis object (`def f(): ...`,
    // tuple[int, ...], x[..., 0]); between two operands it is the inclusive
    // range a...b.
    if(see(TokenType::Ellipsis)) {
        Token et = token(); next();
        if(ast_mode_) return std::make_shared<PyAstNode>(et, "Ellipsis");   // round 83: Constant(Ellipsis)
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
            if(ast_mode_){   // round 83: Await(value)
                auto aw = std::make_shared<PyAstNode>(at, "Await");
                aw->kid("value", operand);
                return aw;
            }
            at.value = "async_await";
            auto call = make_node<CallNode>(at, make_node<VariableNode>(at));
            call->add(operand);
            return call;
        }
        Token nt_tok = token(); next();
        return make_node<VariableNode>(nt_tok);
    }
    // Handle typeof/sizeof as identifiers that resolve to builtins - when
    // called; otherwise they are ordinary names (round 77: `sizeof = 2`
    // rebound len)
    if((see(TokenType::Typeof)||see(TokenType::Sizeof)) && peek().type() == TokenType::ParenOpen) {
        Token tok = token();
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
// round 83: an f-string in ast mode - Python's JoinedStr(values) of
// Constant and FormattedValue(value, conversion, format_spec) nodes, a
// format spec a JoinedStr of its own; the fields are split as fstringNode
// splits them. A field that does not parse is a SyntaxError here (the
// engines' f-strings read it as a name).
// round 83: with `atp` - where each byte of raw is in the source
// (fstrPositions) - every part gets CPython 3.12's exact position: a literal
// run (a plain literal joined to it with its quotes), a field from its { to
// its }, a format spec from its : to the field's }, and the field's
// expression the positions of its own tokens (moved from the field's text
// to the source; its spans index ast_extra_toks_ from kAstExtra). Without
// it every part is located at the whole f-string (and so are a field's
// nodes).
node_ptr Parser::fstringAst(const Token& str_tok, const std::string& raw, const FPositions* atp){
    std::vector<node_ptr> parts;
    std::string current;
    size_t cur_start = 0;   // where `current` began in raw
    const bool exact = atp != nullptr && atp->size() == raw.size() + 1;
    static const FPositions none_at;
    const FPositions& at = exact ? *atp : none_at;   // raw index -> (row, column) in the source
    auto place = [&](Token& t, size_t i0, size_t i1) {
        if (!exact) return;
        t._location.row = at[i0].r; t._location.column = at[i0].c;
        t.end_row = at[i1].er; t.end_col = at[i1].ec;
    };
    auto lit = [&](const std::string& text, size_t i0, size_t i1) -> node_ptr {
        Token ltok = str_tok; ltok.value = text;
        ltok.type(TokenType::String);
        place(ltok, i0, i1);
        return make_node<StringNode>(ltok);
    };
    size_t fi = 0;
    while (fi < raw.size()) {
        if (raw[fi] == '{' && fi + 1 < raw.size() && raw[fi+1] != '{') {
            const size_t fopen = fi;
            fi++;
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
            if (fi >= raw.size()) throw SyntaxError(str_tok.location(), "f-string: expecting '}'");
            const size_t fclose = fi;
            fi++;   // the closing '}'
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
            const size_t expr_end = fopen + 1 + k;   // where the expression's text ends in raw
            if (k < field.size() && field[k] == '!') {
                conv = field.substr(k + 1, 1);
                k += 2;
            }
            size_t spec_colon = 0;
            if (k < field.size() && field[k] == ':') { spec = field.substr(k + 1); has_spec = true; spec_colon = fopen + 1 + k; }
            bool debug = false;
            {
                size_t e = expr_str.find_last_not_of(" \t\n");
                if (e != std::string::npos && expr_str[e] == '=' && e > 0) {
                    char before = expr_str[e - 1];
                    if (before != '=' && before != '!' && before != '<' && before != '>') {
                        // f"{x=}": the text before it and the expression's
                        // own text (with its =) are one Constant, as CPython's
                        if (current.empty()) cur_start = fopen + 1;
                        current += expr_str;
                        parts.push_back(lit(current, cur_start, expr_end));
                        current.clear();
                        debug = true;
                        expr_str = expr_str.substr(0, e);
                        if (conv.empty() && !has_spec) conv = "r";
                    }
                }
            }
            if (!debug && !current.empty()) { parts.push_back(lit(current, cur_start, fopen)); current.clear(); }
            size_t b0 = expr_str.find_first_not_of(" \t\n");
            if (b0 == std::string::npos) throw SyntaxError(str_tok.location(), "f-string: valid expression required before '}'");
            size_t e0 = expr_str.find_last_not_of(" \t\n");
            expr_str = expr_str.substr(b0, e0 - b0 + 1);
            const size_t expr_at = fopen + 1 + b0;   // the expression's first character in raw
            node_ptr expr_node;
            bool field_exact = false;
            {
                reader::SourceCode sub_src("(" + expr_str + ")");
                nython::exception::Reporter sub_reporter(sub_src);
                auto sub_lex = std::make_shared<Lexer>(sub_src);
                sub_lex->force_python_strings = true;
                sub_lex->tokenize();
                if (exact) {
                    // the field's tokens in the source's coordinates: a
                    // (row, column) of "(" + expr_str + ")" -> its byte in
                    // expr_str -> where that byte is in the source
                    std::map<std::pair<uint32_t,uint32_t>, size_t> idx;
                    uint32_t r = 1, c = 2;
                    for (size_t i = 0; i < expr_str.size(); i++) {
                        idx[{r, c}] = i;
                        unsigned char ch = (unsigned char)expr_str[i];
                        if (ch == '\n') { r++; c = 1; }
                        else if (i + 1 >= expr_str.size() || (((unsigned char)expr_str[i + 1]) & 0xC0) != 0x80) c++;
                    }
                    idx[{r, c}] = expr_str.size();
                    field_exact = true;
                    for (auto& t : sub_lex->tokens) {
                        auto s0 = idx.find({t._location.row, t._location.column});
                        auto s1 = idx.find({t.end_row, t.end_col});
                        if (s0 == idx.end() || s1 == idx.end()) continue;   // "(", ")", the end
                        t._location.row = at[expr_at + s0->second].r;
                        t._location.column = at[expr_at + s0->second].c;
                        t.end_row = at[expr_at + s1->second].er;
                        t.end_col = at[expr_at + s1->second].ec;
                    }
                }
                Parser sub_parser(&sub_reporter, runner, sub_lex.get());
                sub_parser.ast_mode_ = true;
                sub_parser.ast_fstr_exact_ = false;   // an f-string in the field: located at itself
                sub_parser.self_scope_ = self_scope_;
                node_ptr e = sub_parser.exprList(sub_parser.token());
                expr_node = e;
                while (sub_parser.have(TokenType::NewLine)) {}
                if (!sub_parser.see(TokenType::End)) throw SyntaxError(str_tok.location(), "f-string: expecting '}'");
                if (field_exact) {
                    // the field's spans, over its tokens kept here
                    const int base = kAstExtra + (int)ast_extra_toks_.size();
                    for (auto& t : sub_lex->tokens) ast_extra_toks_.push_back(t);
                    for (auto& kv : sub_parser.ast_spans_) {
                        if (kv.second.first < 0 || kv.second.second >= kAstExtra) continue;
                        std::pair<int,int> sp = kv.second;
                        // a tuple's span takes in the parentheses written
                        // around it: the field's own are the wrapping ones
                        if (kv.first == e.get() && sp.first == 0 && sp.second >= 2) { sp.first++; sp.second--; }
                        ast_spans_[kv.first] = {base + sp.first, base + sp.second};
                    }
                    for (auto& kv : sub_parser.ast_outer_) {
                        if (kv.first == e.get()) continue;   // the parentheses the field was wrapped in
                        if (kv.second.first >= 0 && kv.second.second < kAstExtra)
                            ast_outer_[kv.first] = {base + kv.second.first, base + kv.second.second};
                        else
                            ast_outer_[kv.first] = {-2, -2};
                    }
                } else {
                    // the field's nodes are located at the f-string (their own
                    // positions are within the field's text)
                    for (auto& kv : sub_parser.ast_outer_) ast_outer_[kv.first] = {-2, -2};
                }
                fstr_nodes_.push_back(e);
                for (auto& kv : sub_parser.ast_flags_) ast_flags_[kv.first] = kv.second;
            }
            int conversion = -1;
            if (conv == "r") conversion = 'r';
            else if (conv == "s") conversion = 's';
            else if (conv == "a") conversion = 'a';
            else if (!conv.empty()) throw SyntaxError(str_tok.location(), "f-string: invalid conversion character '" + conv + "': expected 's', 'r', or 'a'");
            node_ptr spec_node;
            if (has_spec) {
                const size_t spec_at = spec_colon + 1;
                if (exact) {
                    FPositions sub(at.begin() + (long)spec_at, at.begin() + (long)fclose + 1);
                    spec_node = fstringAst(str_tok, spec, &sub);
                } else spec_node = fstringAst(str_tok, spec);
                if (exact) place(spec_node->_token, spec_colon, fclose);
            }
            Token fvt = str_tok;
            place(fvt, fopen, fclose + 1);
            auto fv = std::make_shared<PyAstNode>(fvt, "FormattedValue");
            fv->kid("value", expr_node)->num("conversion", conversion)->kid("format_spec", spec_node);
            if (field_exact) fv->num("exact", 1);
            parts.push_back(fv);
        } else if (raw[fi] == '{' && fi + 1 < raw.size() && raw[fi+1] == '{') {
            if (current.empty()) cur_start = fi;
            current += '{'; fi += 2;
        } else if (raw[fi] == '}' && fi + 1 < raw.size() && raw[fi+1] == '}') {
            if (current.empty()) cur_start = fi;
            current += '}'; fi += 2;
        } else if (raw[fi] == '}') {
            throw SyntaxError(str_tok.location(), "f-string: single '}' is not allowed");
        } else { if (current.empty()) cur_start = fi; current += raw[fi]; fi++; }
    }
    if (!current.empty()) parts.push_back(lit(current, cur_start, raw.size()));
    auto js = std::make_shared<PyAstNode>(str_tok, "JoinedStr");
    js->list("values", parts);
    if (exact) js->num("exact", 1);
    return js;
}

// round 83: the literal runs and {fields} of an f-string's text - raw (the
// lexer's value) or `source` text (escapes not decoded: \N{...} and an
// escaped character belong to the literal run) - as [a, b) byte ranges from
// `base`; false where the text does not split (left to the parser).
namespace {
struct FSeg { char kind; size_t a, b; };   // 'L' a literal run, 'F' a {field}
bool fstr_segments(const std::string& s, bool source, std::vector<FSeg>& out, size_t base = 0) {
    const size_t npos = std::string::npos;
    size_t i = 0, n = s.size(), lit0 = npos;
    auto flush = [&](size_t end) { if (lit0 != npos) { out.push_back({'L', base + lit0, base + end}); lit0 = npos; } };
    while (i < n) {
        char c = s[i];
        if (source && c == '\\' && i + 1 < n) {
            if (lit0 == npos) lit0 = i;
            if (s[i+1] == 'N' && i + 2 < n && s[i+2] == '{') {
                size_t j = s.find('}', i + 3);
                if (j == npos) return false;
                i = j + 1;
                continue;
            }
            i += (s[i+1] == '{' || s[i+1] == '}') ? 1 : 2;
            continue;
        }
        if ((c == '{' || c == '}') && i + 1 < n && s[i+1] == c) { if (lit0 == npos) lit0 = i; i += 2; continue; }
        if (c == '{') {
            flush(i);
            size_t f0 = i++;
            int depth = 1;
            char quote = 0;
            while (i < n) {
                char d = s[i];
                if (quote) { if (d == quote) quote = 0; }
                else if (d == '\'' || d == '"') quote = d;
                else if (d == '{' || d == '[' || d == '(') depth++;
                else if (d == ']' || d == ')') depth--;
                else if (d == '}') { depth--; if (depth == 0) break; }
                i++;
            }
            if (i >= n) return false;
            out.push_back({'F', base + f0, base + ++i});
            continue;
        }
        if (c == '}') return false;
        if (lit0 == npos) lit0 = i;
        i++;
    }
    flush(n);
    return true;
}
}

// round 83: where each byte of an f-string's value (raw) is in the source:
// the literal's source text - one f-string, or a run of literals the lexer
// joined (`"a" f"{x}"`) - split as raw is, the two matched part for part (a
// field's text must be the same in both; a literal run is located from its
// first character to its last, a plain literal of the run with its prefix
// and quotes, as CPython 3.12). False when they do not match (a raw
// f-string, an escape that makes a brace, bytes): the parts are then
// located at the whole string.
bool Parser::fstrPositions(const Token& str_tok, const std::string& raw, FPositions& at){
    if (!scanner || str_tok.end_row == 0) return false;
    if (ast_line_starts_.empty()) {
        ast_src_ = scanner->source.sourceCode();
        ast_line_starts_.push_back(0);
        for (size_t i = 0; i < ast_src_.size(); i++) if (ast_src_[i] == '\n') ast_line_starts_.push_back(i + 1);
    }
    auto offset = [&](uint32_t r, uint32_t c, size_t& out) -> bool {
        if (r < 1 || r > ast_line_starts_.size()) return false;
        size_t i = ast_line_starts_[r - 1];
        for (uint32_t k = 1; k < c; k++) {
            if (i >= ast_src_.size() || ast_src_[i] == '\n') return false;
            i++;
            while (i < ast_src_.size() && (((unsigned char)ast_src_[i]) & 0xC0) == 0x80) i++;
        }
        out = i;
        return true;
    };
    size_t a = 0, b = 0;
    if (!offset(str_tok._location.row, str_tok._location.column, a) || !offset(str_tok.end_row, str_tok.end_col, b) || b <= a) return false;
    const std::string text = ast_src_.substr(a, b - a);
    // the source position of every byte of the text
    std::vector<std::pair<uint32_t,uint32_t>> sp(text.size() + 1);
    {
        uint32_t r = str_tok._location.row, c = str_tok._location.column;
        for (size_t i = 0; i < text.size(); i++) {
            sp[i] = {r, c};
            unsigned char ch = (unsigned char)text[i];
            if (ch == '\n') { r++; c = 1; }
            else if (i + 1 >= text.size() || (((unsigned char)text[i + 1]) & 0xC0) != 0x80) c++;
        }
        sp[text.size()] = {r, c};
    }
    // the literals of the text, each split into its parts
    std::vector<FSeg> src;
    size_t i = 0;
    const size_t n = text.size();
    while (i < n) {
        char c = text[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') { i++; continue; }
        if (c == '\\' && i + 1 < n && (text[i+1] == '\n' || text[i+1] == '\r')) { i += 2; continue; }
        if (c == '#') { while (i < n && text[i] != '\n') i++; continue; }
        size_t p0 = i;
        bool rawp = false, fp = false;
        auto prefix_char = [&](char ch) -> bool {
            char l = (char)std::tolower((unsigned char)ch);
            if (l == 'r') rawp = true;
            else if (l == 'f') fp = true;
            else if (l != 'u') return false;   // bytes, or not a literal
            return true;
        };
        if (p0 == 0) {
            // the first literal's prefix is a token of its own, before the text
            for (size_t k = a; k > 0 && std::isalpha((unsigned char)ast_src_[k - 1]); k--)
                if (!prefix_char(ast_src_[k - 1])) return false;
        }
        while (i < n && std::isalpha((unsigned char)text[i])) {
            if (!prefix_char(text[i])) return false;
            i++;
        }
        if (i >= n || (text[i] != '\'' && text[i] != '"')) return false;
        const size_t ql = (i + 2 < n && text[i+1] == text[i] && text[i+2] == text[i]) ? 3 : 1;
        const std::string q = text.substr(i, ql);
        i += ql;
        const size_t b0 = i;
        while (i < n && text.compare(i, ql, q) != 0) i += text[i] == '\\' ? 2 : 1;
        if (i >= n) return false;
        const size_t b1 = i;
        i += ql;
        if (fp) {
            if (rawp) return false;   // a raw f-string: not mapped
            if (!fstr_segments(text.substr(b0, b1 - b0), true, src, b0)) return false;
        } else if (b1 > b0 || src.empty() || src.back().kind == 'L') {
            src.push_back({'L', p0, i});   // a plain literal, with its prefix and quotes
        }
    }
    std::vector<FSeg> m;   // consecutive literal runs are one
    for (auto& g : src) {
        if (g.kind == 'L' && !m.empty() && m.back().kind == 'L') m.back().b = g.b;
        else m.push_back(g);
    }
    std::vector<FSeg> rs;
    if (!fstr_segments(raw, false, rs) || rs.size() != m.size()) return false;
    // a byte where one part ends and the next begins has two positions:
    // where the next one starts (r, c) and where the last one ends (er, ec)
    auto both = [](std::pair<uint32_t,uint32_t> x) { return FPos{x.first, x.second, x.first, x.second}; };
    at.assign(raw.size() + 1, both(sp[0]));
    for (size_t k = 0; k < rs.size(); k++) {
        if (rs[k].kind != m[k].kind) return false;
        const size_t ra = rs[k].a, rb = rs[k].b, ma = m[k].a;
        if (rs[k].kind == 'F') {
            const size_t len = rb - ra;
            if (m[k].b - ma != len || text.compare(ma, len, raw, ra, len) != 0) return false;
            for (size_t j = 0; j < len; j++) { at[ra + j].r = sp[ma + j].first; at[ra + j].c = sp[ma + j].second; }
            for (size_t j = 1; j < len; j++) { at[ra + j].er = sp[ma + j].first; at[ra + j].ec = sp[ma + j].second; }
        } else {
            for (size_t j = ra; j < rb; j++) { at[j].r = sp[ma].first; at[j].c = sp[ma].second; }
            for (size_t j = ra + 1; j < rb; j++) { at[j].er = sp[ma].first; at[j].ec = sp[ma].second; }
        }
        at[rb].er = sp[m[k].b].first;
        at[rb].ec = sp[m[k].b].second;
        at[rb].r = at[rb].er;   // (the next part, if any, sets its own start)
        at[rb].c = at[rb].ec;
    }
    if (rs.empty()) at[0] = both(sp[text.size()]);   // f'': nothing to locate but the end
    return true;
}

node_ptr Parser::fstringNode(const Token& str_tok, const std::string& raw){
    if(ast_mode_){   // round 83
        FPositions at;
        if(ast_fstr_exact_ && fstrPositions(str_tok, raw, at)) return fstringAst(str_tok, raw, &at);
        return fstringAst(str_tok, raw);
    }
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
            {
                // `{ x }`: the spaces around the expression are not code (a
                // leading one read as an indent; round 77)
                size_t b0 = expr_str.find_first_not_of(" \t\n");
                size_t e0 = expr_str.find_last_not_of(" \t\n");
                if (b0 == std::string::npos) continue;
                expr_str = expr_str.substr(b0, e0 - b0 + 1);
            }
            node_ptr expr_node;
            try {
                reader::SourceCode sub_src(expr_str);
                nython::exception::Reporter sub_reporter(sub_src);
                auto sub_lex = std::make_shared<Lexer>(sub_src);
                sub_lex->tokenize();
                Parser sub_parser(&sub_reporter, runner, sub_lex.get());
                sub_parser.mangle_stack_ = mangle_stack_;   // f"{self.__x}" (round 78)
                sub_parser.self_scope_ = self_scope_;
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

node_ptr Parser::atom_(){   // round 83: atom() records its span in ast mode (Parser.hpp)
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
        // round 80: not in a raw string nor in a Python-mode file's quoted
        // strings (the lexer makes those TokenClass::Default)
        bool has_interp = sv.find("${") != std::string::npos && str_tok.clazz() != TokenClass::Default;
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
        if(ast_mode_){   // round 83: Constant(complex)
            auto c = std::make_shared<PyAstNode>(ct, "Complex");
            c->str("text", ct.value);
            return c;
        }
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

    // Self/Super. `this` is Nython's self only inside a def whose first
    // parameter is self/this; elsewhere it is the ordinary name `this`
    // (round 77).
    if(see(TokenType::This) && !(std::find(self_scope_.begin(), self_scope_.end(), true) != self_scope_.end())){
        next();
        return make_node<VariableNode>(prev());
    }
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
        int p0 = scanner->current - 1;   // round 83: the `(` (ast mode's outer span)
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
            if(starred && !in_assign_target_ && !ast_mode_) return catStarred(tok, tuple->statements(), "tuple");
            return tuple;
        }
        if(isStarElem(expr)) throw SyntaxError(tok.location(), "cannot use starred expression here");
        mustBe(TokenType::ParenClose);
        if(ast_mode_ && expr) ast_outer_[expr.get()] = {p0, scanner->current - 1};   // round 83
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
           || t == TokenType::Var || t == TokenType::Const
           || nameKeyword(t)) {   // the other soft keywords (round 77)
            next();
            Token id_tok = prev();
            return make_node<VariableNode>(id_tok);
        }
    }

    // If we got here, unexpected token — error
    // (round 84: the lexer's PEP 3131 error, CPython's message as it is)
    if (tok.type() == TokenType::UnterminatedStringError
        && (tok.value.rfind("invalid character '", 0) == 0 || tok.value.rfind("invalid non-printable character U+", 0) == 0))
        throw SyntaxError(tok.location(), tok.value);
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
                    static_cast<VarDeclNode*>(decl.get())->unpack = unpackCode((int)names.size(), si);
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
    // `if c then ...`; `if c: then = 1` assigns the name (round 77)
    have(TokenType::Colon); if(see(TokenType::Then) && !usedAsName()) next();
    node_ptr then_b = blockOrStmt();
    auto node = make_node<IfNode>(tok, cond, then_b);
    auto if_node = std::static_pointer_cast<IfNode>(node);

    // Else-if chains
    while(have(TokenType::NewLine)) {}
    std::vector<int> elif_at;   // round 83: each elif's first token (ast mode)
    while(have(TokenType::ElseIf)||have(TokenType::ElseIf)||(see(TokenType::Else)&&peek().type()==TokenType::If)){
        if(prev().type()==TokenType::Else) next(); // consume 'if'
        elif_at.push_back(scanner->current - 1);
        Token eitok = prev();   // the elif's own line (round 79: sys.settrace's line event)
        // Same rule as the if-condition above: let expression() own the parens.
        node_ptr eicond = expression();
        have(TokenType::Colon);
        node_ptr eibody = blockOrStmt();
        if_node->elseif_branches.push_back(make_node<IfNode>(eitok, eicond, eibody));
        while(have(TokenType::NewLine)) {}
    }

    // Else
    if(have(TokenType::Else)){
        have(TokenType::Colon);
        if_node->else_branch = blockOrStmt();
    }
    // round 83: an elif's If runs to the end of the statement, as CPython's
    if(ast_mode_)
        for(size_t i = 0; i < elif_at.size(); i++) spanSet(if_node->elseif_branches[i].get(), elif_at[i]);
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
    // `for (init; cond; step)` / `for (x in xs)` wrap the header in
    // parentheses; `for (a, b) in ...` / `for (a, b), c in ...` is a
    // parenthesised target (round 77).
    bool hp = false;
    if(see(TokenType::ParenOpen)){
        int depth = 0, k = 0;
        for(; k < 1 << 20; k++){
            TokenType tt = peek(k).type();
            if(tt == TokenType::End) break;
            if(tt == TokenType::ParenOpen || tt == TokenType::BracketOpen || tt == TokenType::BraceOpen) depth++;
            else if(tt == TokenType::ParenClose || tt == TokenType::BracketClose || tt == TokenType::BraceClose){
                if(--depth == 0) break;
            }
        }
        TokenType after = peek(k).type() == TokenType::End ? TokenType::End : peek(k + 1).type();
        if(after != TokenType::In && after != TokenType::Comma) hp = have(TokenType::ParenOpen);
    }
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
    auto mark_global = [&](const node_ptr& v) {
        if(global_decls_.empty()) return;
        auto& g = global_decls_.back();
        static_cast<VariableNode*>(v.get())->global_ref = std::find(g.begin(), g.end(), v->value()) != g.end();
    };
    // Plain names (`for x in`, `for k, v in`) are the loop's own variables.
    // Any other target list - `for a, *rest in`, `for (p, q), r in`, `for
    // [m, n] in`, `for self.i in`, `for d["k"] in` - binds through a hidden
    // loop variable at the top of the body (round 77: a syntax error).
    bool plain = true;
    {
        int k = 0;
        while(true){
            TokenType tt = peek(k).type();
            if(!(tt == TokenType::Identifier || (nameKeyword(tt) && tt != TokenType::Self && tt != TokenType::This))) { plain = false; break; }
            TokenType nt = peek(k + 1).type();
            if(nt == TokenType::In) break;
            if(nt != TokenType::Comma || peek(k + 2).type() == TokenType::In) { plain = false; break; }
            k += 2;
        }
    }
    node_ptr var;
    std::vector<node_ptr> unpack_vars;
    node_ptr complex_target;
    if(plain){
        var = make_node<VariableNode>(token());
        mark_global(var);
        next(); // consume variable name
        // Check for tuple unpacking: for k, v in ...
        while(have(TokenType::Comma)) {
            unpack_vars.push_back(make_node<VariableNode>(token()));
            mark_global(unpack_vars.back());
            next();
        }
    } else {
        Token tt0 = token();
        int ft0 = scanner->current;   // round 83
        std::vector<node_ptr> ts;
        bool comma = false, starred = false;
        in_assign_target_ = true;
        try {
            while(!see(TokenType::In)){
                if(see(TokenType::Mul)){
                    int s0 = scanner->current;   // round 83
                    Token st = token(); next(); st.value = "*";
                    ts.push_back(make_node<UnaryNode>(st, asTarget(postfix())));
                    if(ast_mode_) spanSet(ts.back().get(), s0);
                    starred = true;
                } else ts.push_back(asTarget(postfix()));
                if(!have(TokenType::Comma)) break;
                comma = true;
            }
        } catch(...) { in_assign_target_ = false; throw; }
        in_assign_target_ = false;
        for(auto& t : ts) checkAssignable(isStarElem(t) ? static_cast<UnaryNode*>(t.get())->operand : t);
        if(ts.size() == 1 && !comma && !starred) complex_target = ts[0];
        else {
            auto tup = make_node<TupleNode>(tt0);
            for(auto& t : ts) tup->add(t);
            complex_target = tup;
        }
        if(ast_mode_ && complex_target){
            // round 83: the target as written
            if(complex_target->type() == NodeType::TUPLE && !(ts.size() == 1 && !comma && !starred)) spanSet(complex_target.get(), ft0);
            mustBe(TokenType::In);
            node_ptr iter = exprList(token());
            if(hp) mustBe(TokenType::ParenClose);
            have(TokenType::Colon);
            node_ptr body = blockOrStmt();
            return make_node<ForNode>(tok, complex_target, iter, body);
        }
        Token vt = tt0; vt.value = "__for" + unpackTemp();
        var = make_node<VariableNode>(vt);
    }
    mustBe(TokenType::In);
    // `for x in 1, 2:` iterates the tuple
    node_ptr iter = exprList(token());
    if(hp) mustBe(TokenType::ParenClose);
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    if(complex_target){
        // the targets are bound first in each pass; plain names in them are
        // the loop's own (declared) unless declared global/nonlocal
        Token op = var->token();
        auto pre = make_node<BlockNode>(op);
        auto tmp = make_node<BlockNode>(op);
        bindTarget(op, complex_target, make_node<VariableNode>(op), tmp);
        for(auto& s : tmp->statements()){
            if(s->type() == NodeType::ASSIGNMENT){
                auto* as = static_cast<AssignmentNode*>(s.get());
                if(as->target && as->target->type() == NodeType::VARIABLE){
                    std::string n = as->target->value();
                    bool outer = !outer_decls_.empty()
                        && std::find(outer_decls_.back().begin(), outer_decls_.back().end(), n) != outer_decls_.back().end();
                    if(!outer){ pre->add(make_node<VarDeclNode>(as->target->token(), n, as->value_node)); continue; }
                    mark_global(as->target);
                }
            }
            pre->add(s);
        }
        pre->add(body);
        body = pre;
    }
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

static node_ptr async_def_desugar(const Token& tok, node_ptr fn, bool is_generator, bool class_method = false,
                                  bool class_static = false) {
    auto* f = static_cast<FunctionNode*>(fn.get());
    Token t = tok;
    auto name_tok = [&](const std::string& v) { Token x = t; x.value = v; return x; };
    // An async @staticmethod (round 79): its own name is not in scope in its
    // body (the class's attribute is), so the coroutine cannot call it
    // again by name. Its body runs as an inner function of the same name
    // instead, which consumes the token first:
    //
    //     @staticmethod                     @staticmethod
    //     async def m(a):          ==>      def m(a):
    //         body                              def m(a):
    //                                               async_body_begin()
    //                                               body
    //                                           return _NyCoroutine(async_coroutine_def(
    //                                               lambda: m(a), "m"), m, "m", "C.m")
    if (class_static && !is_generator) {
        Token it = name_tok(f->name);
        auto ib = make_node<BlockNode>(t);
        Token bb = name_tok("async_body_begin");
        ib->add(make_node<CallNode>(bb, make_node<VariableNode>(bb)));
        if (f->body) {
            if (f->body->type() == NodeType::BLOCK) for (auto& st : f->body->statements()) ib->add(st);
            else ib->add(f->body);
        }
        auto inner = make_node<FunctionNode>(it, f->name, ib, false);
        auto* in = static_cast<FunctionNode*>(inner.get());
        for (auto& p : f->params) in->add(p);
        in->defaults.assign(f->params.size(), nullptr);
        in->posonly = f->posonly;
        in->qualname = f->qualname;
        in->is_async = true;
        auto again = make_node<CallNode>(t, make_node<VariableNode>(it));
        forward_params(t, static_cast<CallNode*>(again.get()), f->params, 0);
        auto closure = make_node<LambdaNode>(name_tok("lambda"), again);
        Token mk = name_tok("async_coroutine_def");
        auto make = make_node<CallNode>(mk, make_node<VariableNode>(mk));
        make->add(closure);
        make->add(make_node<StringNode>(name_tok(f->name)));
        Token ct = name_tok("_NyCoroutine");
        auto coro = make_node<CallNode>(ct, make_node<VariableNode>(ct));
        coro->add(make);
        coro->add(make_node<VariableNode>(it));
        coro->add(make_node<StringNode>(name_tok(f->name)));
        coro->add(make_node<StringNode>(name_tok(f->qualname.empty() ? f->name : f->qualname)));
        auto body = make_node<BlockNode>(t);
        body->add(inner);
        body->add(make_node<ReturnNode>(t, coro));
        f->body = body;
        return fn;
    }
    bool method = !f->params.empty() &&
        (f->params[0]->value() == "self" || f->params[0]->value() == "this");
    // A method whose first parameter is not self (`async def m(s)`, an
    // async classmethod's cls) is reached through that parameter (round 78).
    std::string via;
    if (!method && class_method && !f->params.empty() &&
        f->params[0]->value()[0] != '*' && f->params[0]->value() != "/") {
        method = true;
        via = f->params[0]->value();
    }
    // The function itself (a method: self.name), as the call below names it.
    auto self_ref = [&]() -> node_ptr {
        if (method && via.empty()) return make_node<AttributeNode>(name_tok(f->name), make_node<SelfNode>(name_tok("self")), f->name);
        if (method) return make_node<AttributeNode>(name_tok(f->name), make_node<VariableNode>(name_tok(via)), f->name);
        return make_node<VariableNode>(name_tok(f->name));
    };
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
        // its name and qualname (round 78; as strings: a static method's
        // own name is not in scope in its body)
        wrap->add(make_node<StringNode>(name_tok(f->name)));
        wrap->add(make_node<StringNode>(name_tok(f->qualname.empty() ? f->name : f->qualname)));
        auto body = make_node<BlockNode>(t);
        body->add(inner);
        body->add(make_node<ReturnNode>(t, wrap));
        f->body = body;
        return fn;
    }
    node_ptr ref = self_ref();
    auto again = make_node<CallNode>(t, ref);
    forward_params(t, static_cast<CallNode*>(again.get()), f->params, method ? 1 : 0);
    auto closure = make_node<LambdaNode>(name_tok("lambda"), again);
    Token mk = name_tok("async_coroutine_def");
    auto make = make_node<CallNode>(mk, make_node<VariableNode>(mk));
    make->add(closure);
    make->add(make_node<StringNode>(name_tok(f->name)));
    // The coroutine object (round 78): _NyCoroutine(handle, the function)
    // - the handle is what the runtime runs, the function gives its name,
    // qualname and code.
    Token ct = name_tok("_NyCoroutine");
    auto coro = make_node<CallNode>(ct, make_node<VariableNode>(ct));
    coro->add(make);
    coro->add(self_ref());
    coro->add(make_node<StringNode>(name_tok(f->name)));
    coro->add(make_node<StringNode>(name_tok(f->qualname.empty() ? f->name : f->qualname)));
    Token bt = name_tok("async_body_begin");
    auto begin = make_node<CallNode>(bt, make_node<VariableNode>(bt));
    auto then_blk = make_node<BlockNode>(t);
    then_blk->add(make_node<ReturnNode>(t, coro));
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
    // a def directly in a class body is a method whatever its first
    // parameter is called, unless it is a static method (round 78)
    bool class_method = !ann_scope_.empty() && ann_scope_.back() == 'c' && !next_def_static_;
    bool class_static = !ann_scope_.empty() && ann_scope_.back() == 'c' && next_def_static_;   // round 79
    next_def_static_ = false;
    Token tok = token();
    next(); // consume def/function/fn
    // `def __m` in a class binds _C__m; __qualname__ is C.__m (round 78)
    std::string raw_name = rawToken().value;
    std::string name = identifier();
    if(name != raw_name && name != mangled(raw_name)) raw_name = name;
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
    std::string qualname = qualOf(raw_name);
    qual_stack_.push_back(qualname + ".<locals>");
    self_scope_.push_back(!params.empty() && (params[0]->value() == "self" || params[0]->value() == "this"));
    node_ptr body;
    try { body = blockOrStmt(); } catch(...) { self_scope_.pop_back(); throw; }
    self_scope_.pop_back();
    qual_stack_.pop_back();
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
    {
        // __qualname__ and the async flags, for inspect (round 77)
        auto* fnp = static_cast<FunctionNode*>(fn.get());
        fnp->qualname = qualname;
        fnp->is_async = is_async;
        fnp->is_async_gen = is_async && is_gen;
    }
    if(!fn_ann.empty()){
        // f.__annotations__: {"param": ann, ..., "return": ann}
        auto m = make_node<MapNode>(tok);
        for(auto& [k, v] : fn_ann){
            Token kt = tok; kt.value = k;
            m->add(make_node<MapEntryNode>(tok, make_node<StringNode>(kt), v));
        }
        static_cast<FunctionNode*>(fn.get())->annotations = m;
    }
    if(is_async && !ast_mode_) return async_def_desugar(tok, fn, is_gen, class_method && name != "__new__", class_static);   // round 83: not in ast mode
    return fn;
}


// A bare `*` must be followed by a keyword-only parameter, as in Python
// (round 77): `def f(*)`, `lambda *: 0`, `def f(*, **kw)` are SyntaxErrors.
static void checkBareStar(const std::vector<node_ptr>& params, const Token& at){
    for(size_t i = 0; i < params.size(); i++){
        if(params[i]->value() != "*") continue;
        if(i + 1 >= params.size() || params[i + 1]->value().rfind("**", 0) == 0)
            throw SyntaxError(at.location(), "named arguments must follow bare *");
    }
}

std::vector<node_ptr> Parser::lambdaParamList(){
    std::vector<node_ptr> params;
    param_defaults_.clear();
    lambda_posonly_ = 0;
    if(see(TokenType::Colon)) return params; // no params
    // Python's lambda parameters (round 77): `*` alone (keyword-only ones
    // follow), `/` (positional-only ones precede), *args, **kw, defaults.
    auto parse_one_param = [&]() {
        if(see(TokenType::Mul) && (peek(1).type() == TokenType::Comma || peek(1).type() == TokenType::Colon)){
            Token st = token(); next();
            st.value = "*";
            params.push_back(make_node<VariableNode>(st));
            param_defaults_.push_back(nullptr);
            return;
        }
        if(see(TokenType::Div) && (peek(1).type() == TokenType::Comma || peek(1).type() == TokenType::Colon)){
            next();
            lambda_posonly_ = params.size();
            return;
        }
        bool va = have(TokenType::Mul);
        bool kw = !va && have(TokenType::Exp);
        Token ptok = token();
        ptok.value = token().value;
        if(ptok.type() != TokenType::Identifier && !nameKeyword(ptok.type()) && ptok.clazz() != TokenClass::Keyword)
            throw SyntaxError(ptok.location(), "invalid syntax: expected a parameter name, found " + ptok.value);
        next();
        auto pnode = make_node<VariableNode>(ptok);
        if(ast_mode_) spanSet(pnode.get(), scanner->current - 1);   // round 83
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
    checkBareStar(params, token());
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
            int n0 = scanner->current;   // round 83: the arg's span (ast mode)
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
                // `*args: *Ts` (PEP 646) is a starred annotation
                node_ptr ann = (ast_mode_ && va && see(TokenType::Mul)) ? starElem() : ternary();
                param_ann_.push_back({ptok.value, annotationValue(ann, a0, scanner->current)});
            }
            if(ast_mode_) spanSet(pnode.get(), n0);   // round 83
            if(have(TokenType::Assign)) param_defaults_.push_back(expression());
            else param_defaults_.push_back(nullptr);
        };
        parse_one_param();
        while(have(TokenType::Comma) && !see(TokenType::ParenClose)){
            parse_one_param();
        }
        checkBareStar(params, token());
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
    // `class __H` inside a class binds _C__H; its __name__ stays __H
    // (round 78)
    std::string raw_name = rawToken().value;
    std::string name = identifier();
    std::string bind_as;
    if(name != raw_name && name == mangled(raw_name)){
        bind_as = name;
        name = raw_name;
    }
    // Optional bases: class Foo(Bar, Baz) or class Foo extends Bar
    // Supports: extends, inherits, and parenthesized syntax
    std::vector<node_ptr> bases;
    // A base: a name or a dotted one (class C(threading.Thread)); the engines
    // look it up when the class statement runs. `metaclass=M` and other
    // keywords are read and not used.
    std::vector<std::pair<std::string, node_ptr>> class_kw;
    auto base = [&]() {
        // round 83: in ast mode a keyword is a PyAstNode keyword(arg, value)
        auto ast_kw = [&](const std::string& kn, node_ptr v, int k0) -> node_ptr {
            if(!ast_mode_) return v;
            auto kw = std::make_shared<PyAstNode>(tok, "keyword");
            if(kn != "**") kw->str("arg", kn);
            kw->kid("value", v);
            spanSet(kw.get(), k0);
            return kw;
        };
        if((see(TokenType::Identifier) || nameKeyword(token().type())) && peek().type() == TokenType::Assign){
            int k0 = scanner->current;
            std::string kn = identifier();
            next();
            node_ptr v = expression();
            class_kw.push_back({kn, ast_kw(kn, v, k0)});
            return;
        }
        // `class C(**kw)`: the dict's items are keywords too (round 77;
        // the engines expand an entry named "**")
        if(have(TokenType::Exp)){
            int k0 = scanner->current - 1;
            node_ptr v = ternary();
            class_kw.push_back({"**", ast_kw("**", v, k0)});
            return;
        }
        if(ast_mode_ && !see(TokenType::Mul)){ bases.push_back(expression()); return; }   // round 83: the expression as written
        // `class C(*bases)`: each item a base (round 78; the engines expand
        // a starred base)
        if(have(TokenType::Mul)){
            Token st = prev();
            bases.push_back(make_node<UnaryNode>(st, ternary()));
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
        // a dotted base may end in a word Nython reserves (weakref.ref,
        // round 77)
        while(see(TokenType::Dot) && (peek(1).type() == TokenType::Identifier || nameKeyword(peek(1).type())
                                      || peek(1).clazz() == TokenClass::Keyword)){ next(); bn += "." + identifier(); }
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
    std::string class_qualname = qualOf(name);   // Outer.Inner, f.<locals>.C (round 79)
    qual_stack_.push_back(class_qualname);   // its methods are "C.m" (round 77)
    // the body's private names are mangled with this class's name (round 78)
    {
        size_t u = name.find_first_not_of('_');
        mangle_stack_.push_back(u == std::string::npos ? std::string() : name.substr(u));
    }
    node_ptr body;
    {
        struct Pop { std::vector<std::string>& s; ~Pop(){ s.pop_back(); } } pop_{mangle_stack_};
        body = blockOrStmt();
    }
    qual_stack_.pop_back();
    ann_scope_.pop_back();
    // the docstring, before `var __annotations__ = {}` is put ahead of it
    // (round 77: a class with annotations lost its __doc__)
    std::string class_doc;
    bool class_has_doc = docstringOf(body, class_doc);
    if(class_ann_used_.back() && body && !ast_mode_){   // round 83: not in ast mode
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
        cp->has_doc = class_has_doc;
        cp->doc = class_doc;
        if(!bind_as.empty()) cp->bind_name = bind_as;   // round 78
        cp->qualname = class_qualname;                  // round 79
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
        have(TokenType::Comma);
        // `struct P: x, y=0` on one line ends with it (round 77)
        if(!has_brace && !has_indent && (see(TokenType::NewLine) || see(TokenType::SemiColon))) break;
        have(TokenType::NewLine);
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
        have(TokenType::Comma);
        // the one-line form `enum C: A, B` ends with its line (round 77: it
        // read the next statement's words as more members)
        if(!has_brace && !has_indent && (see(TokenType::NewLine) || see(TokenType::SemiColon))) break;
        have(TokenType::NewLine);
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
    // `return a, b` / `return *a, b` return a tuple, as in Python (round
    // 77: a list)
    if(!see(TokenType::NewLine)&&!see(TokenType::SemiColon)&&!see(TokenType::End)&&!see(TokenType::Dedent))
        expr = exprList(tok);
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
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
    // `yield a, b` yields a tuple (round 77: a syntax error)
    if(!see(TokenType::NewLine)&&!see(TokenType::SemiColon)&&!see(TokenType::End)&&!see(TokenType::Dedent)) expr = exprList(tok);
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
    return make_node<YieldNode>(tok, expr);
}


// `print(` begins the call form when its matching `)` ends the statement;
// otherwise the parentheses belong to an expression (`print (a + b) * 2`).
static bool endsStatement(TokenType t){
    return t == TokenType::NewLine || t == TokenType::SemiColon || t == TokenType::End || t == TokenType::Dedent
        || t == TokenType::BraceClose;   // `{ print(a, b) }` (round 77: printed the tuple)
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

// round 83: an import in ast mode - Import(names) / ImportFrom(module,
// names, level), each name an alias(name, asname) with its own span
node_ptr Parser::importAst(){
    Token tok = token();
    auto alias_of = [&](const std::string& n, const std::string& as, int a0) -> node_ptr {
        auto a = std::make_shared<PyAstNode>(tok, "alias");
        a->str("name", n);
        if(!as.empty()) a->str("asname", as);
        spanSet(a.get(), a0);
        return a;
    };
    std::vector<node_ptr> names;
    if(have(TokenType::From)){
        long long level = 0;
        while(true){
            if(have(TokenType::Dot)) level += 1;
            else if(have(TokenType::Interval)) level += 2;
            else if(have(TokenType::Ellipsis)) level += 3;
            else break;
        }
        bool has_mod = !(level > 0 && see(TokenType::Import));
        std::string mod = has_mod ? dottedName() : std::string();
        mustBe(TokenType::Import);
        if(see(TokenType::Mul)){
            int a0 = scanner->current;
            next();
            names.push_back(alias_of("*", "", a0));
        } else {
            bool paren = have(TokenType::ParenOpen);
            auto skip_nl = [&]() { if(paren) while(have(TokenType::NewLine) || have(TokenType::Indent) || have(TokenType::Dedent)) {} };
            skip_nl();
            while(true){
                int a0 = scanner->current;
                std::string n = identifier();
                std::string as;
                if(have(TokenType::As)) as = identifier();
                names.push_back(alias_of(n, as, a0));
                skip_nl();
                if(!have(TokenType::Comma)) break;
                skip_nl();
                if(paren && see(TokenType::ParenClose)) break;
            }
            if(paren) mustBe(TokenType::ParenClose);
        }
        consumed_semi_ = have(TokenType::SemiColon);
        if(!consumed_semi_) have(TokenType::NewLine);
        auto n = std::make_shared<PyAstNode>(tok, "ImportFrom");
        if(has_mod) n->str("module", mod);
        n->list("names", names)->num("level", level);
        return n;
    }
    mustBe(TokenType::Import);
    do {
        int a0 = scanner->current;
        std::string mod = dottedName();
        std::string as;
        if(have(TokenType::As)) as = identifier();
        names.push_back(alias_of(mod, as, a0));
    } while(have(TokenType::Comma));
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
    auto n = std::make_shared<PyAstNode>(tok, "Import");
    n->list("names", names);
    return n;
}

node_ptr Parser::importStmt(){
    if(ast_mode_) return importAst();   // round 83
    Token tok = token();
    if(have(TokenType::From)){
        // a relative import (round 80: `from . import a`, `from ..m import
        // b`): its leading dots stay in the module's name - the engines
        // resolve them against the importing module's __package__
        std::string dots;
        while(true){
            if(have(TokenType::Dot)) dots += ".";
            else if(have(TokenType::Interval)) dots += "..";
            else if(have(TokenType::Ellipsis)) dots += "...";
            else break;
        }
        bool quoted = dots.empty() && see(TokenType::String);
        std::string mod = dots + ((!dots.empty() && see(TokenType::Import)) ? std::string() : dottedName());
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
    // `import os, sys`, `import a.b as c, d`: one import per name, in order
    // (round 77: the comma was a syntax error)
    std::vector<node_ptr> imps;
    do {
        bool quoted = see(TokenType::String);
        std::string mod = dottedName();
        auto imp = make_node<ImportNode>(tok, mod);
        std::static_pointer_cast<ImportNode>(imp)->quoted = quoted;
        if(have(TokenType::As)){
            std::static_pointer_cast<ImportNode>(imp)->alias = identifier();
        }
        imps.push_back(imp);
    } while(have(TokenType::Comma));
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
    if(imps.size() == 1) return imps[0];
    auto blk = make_node<BlockNode>(tok);
    for(auto& i : imps) blk->add(i);
    return blk;
}

// An except* clause's body may not leave it with return, nor with a
// break/continue of a loop outside it (round 78; CPython's compiler: the
// clause runs as part of a group being split). A def, lambda or class
// inside starts afresh; a loop inside owns its break/continue.
static void checkExceptStarFlow(const node_ptr& n, bool in_loop){
    if(!n) return;
    auto bad = [&]{ throw SyntaxError(n->token().location(), "'break', 'continue' and 'return' cannot appear in an except* block"); };
    switch(n->type()){
    case NodeType::RETURN: bad(); break;
    case NodeType::BREAK: case NodeType::CONTINUE: if(!in_loop) bad(); break;
    case NodeType::BLOCK: case NodeType::STATEMENTS:
        for(auto& s : n->statements()) checkExceptStarFlow(s, in_loop);
        break;
    case NodeType::IF: {
        auto* in = static_cast<IfNode*>(n.get());
        if(in->is_expr) break;
        checkExceptStarFlow(in->then_branch, in_loop);
        for(auto& b : in->elseif_branches) checkExceptStarFlow(b, in_loop);
        checkExceptStarFlow(in->else_branch, in_loop);
        break;
    }
    case NodeType::TRY: {
        auto* tn = static_cast<TryNode*>(n.get());
        checkExceptStarFlow(tn->body, in_loop);
        for(auto& e : tn->except_clauses) checkExceptStarFlow(e, in_loop);
        checkExceptStarFlow(tn->else_clause, in_loop);
        checkExceptStarFlow(tn->finally_clause, in_loop);
        break;
    }
    case NodeType::EXCEPT: checkExceptStarFlow(static_cast<ExceptNode*>(n.get())->body, in_loop); break;
    case NodeType::WITH: checkExceptStarFlow(static_cast<WithNode*>(n.get())->body, in_loop); break;
    case NodeType::WHILE:
        checkExceptStarFlow(static_cast<WhileNode*>(n.get())->body, true);
        checkExceptStarFlow(static_cast<WhileNode*>(n.get())->else_branch, in_loop);
        break;
    case NodeType::FOR:
        checkExceptStarFlow(static_cast<ForNode*>(n.get())->body, true);
        checkExceptStarFlow(static_cast<ForNode*>(n.get())->else_branch, in_loop);
        break;
    case NodeType::REPEAT: checkExceptStarFlow(static_cast<RepeatNode*>(n.get())->body, true); break;
    default: break;   // expressions, def, lambda, class
    }
}

// round 83: a try statement in ast mode - a TryNode whose except clauses
// are PyAstNode ExceptHandler(type, name, body) nodes, `except*` marked in
// ast_flags_ ("star": TryStar); else/finally are read by statement().
node_ptr Parser::tryAst(){
    Token tok = token();
    mustBe(TokenType::Try);
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    auto try_node = make_node<TryNode>(tok, body);
    auto tn = std::static_pointer_cast<TryNode>(try_node);
    while(have(TokenType::NewLine)) {}
    bool star = false, plain = false;
    while(see(TokenType::Except) && !(value() == "catch" && usedAsName())){
        int h0 = scanner->current;
        Token etok = token();
        next();
        bool is_star = have(TokenType::Mul);
        if(is_star) star = true; else plain = true;
        if(star && plain) throw SyntaxError(etok.location(), "cannot have both 'except' and 'except*' on the same 'try'");
        node_ptr type;
        std::string name;
        if(!see(TokenType::Colon) && !see(TokenType::As)){
            type = ternary();
            if(see(TokenType::Comma)) throw SyntaxError(token().location(), "multiple exception types must be parenthesized");
        }
        if(is_star && !type) throw SyntaxError(etok.location(), "expected one or more exception types");
        if(have(TokenType::As)) name = identifier();
        have(TokenType::Colon);
        node_ptr hbody = blockOrStmt();
        if(is_star) checkExceptStarFlow(hbody, false);
        auto h = std::make_shared<PyAstNode>(etok, "ExceptHandler");
        h->kid("type", type);
        if(!name.empty()) h->str("name", name);
        h->kid("body", hbody);
        spanSet(h.get(), h0);
        tn->except_clauses.push_back(h);
        while(have(TokenType::NewLine)) {}
    }
    if(star) ast_flags_[try_node.get()] = "star";
    return try_node;
}

node_ptr Parser::tryStmt(){
    if(ast_mode_) return tryAst();   // round 83
    Token tok = token();
    mustBe(TokenType::Try);
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    auto try_node = make_node<TryNode>(tok, body);
    auto tn = std::static_pointer_cast<TryNode>(try_node);
    while(have(TokenType::NewLine)) {}
    // `except*` (PEP 654, round 77) desugars onto the prelude's _NyStar:
    //     try: BODY                      try: BODY
    //     except* T1 as e: H1     ==>    except BaseException as __starN__:
    //     except* T2: H2                     var __ststN__ = _ny_star_begin(__starN__)
    //                                        if _ny_star_match(__ststN__, T1) is not None:
    //                                            try: raise __ststN__.match
    //                                            except BaseException:
    //                                                try: e = __ststN__.match; H1
    //                                                except BaseException as __stxN__:
    //                                                    _ny_star_raised(__ststN__, __stxN__)
    //                                        ... (T2) ...
    //                                        _ny_star_finish(__ststN__)
    // Raising the match first makes it the exception a bare `raise` in the
    // handler re-raises, as in Python. else/finally attach as usual.
    if(see(TokenType::Except) && peek(1).type() == TokenType::Mul){
        static int star_counter = 0;
        int id = star_counter++;
        std::string ev = "__star" + std::to_string(id) + "__";
        std::string sv = "__stst" + std::to_string(id) + "__";
        std::string xv = "__stx" + std::to_string(id) + "__";
        auto T = [&](const std::string& v){ Token t = tok; t.value = v; return t; };
        auto var = [&](const std::string& n) -> node_ptr { return make_node<VariableNode>(T(n)); };
        auto call = [&](const std::string& fn, std::vector<node_ptr> args) -> node_ptr {
            auto c = make_node<CallNode>(T(fn), var(fn));
            for(auto& a : args) c->add(a);
            return c;
        };
        auto catch_all = [&](const std::string& as, node_ptr b) -> node_ptr {
            auto en = make_node<ExceptNode>(tok, "BaseException", as, b);
            auto enp = std::static_pointer_cast<ExceptNode>(en);
            enp->types = {"BaseException"};
            enp->var = as;
            return en;
        };
        auto match_of = [&]() -> node_ptr { return make_node<AttributeNode>(T("match"), var(sv), "match"); };
        auto handler = make_node<BlockNode>(tok);
        handler->add(make_node<VarDeclNode>(tok, sv, call("_ny_star_begin", {var(ev)})));
        while(see(TokenType::Except)){
            if(peek(1).type() != TokenType::Mul)
                throw SyntaxError(token().location(), "cannot have both 'except' and 'except*' on the same 'try'");
            next(); next();   // except *
            if(see(TokenType::Colon)) throw SyntaxError(token().location(), "expected one or more exception types");
            node_ptr types = ternary();
            std::string alias;
            if(have(TokenType::As)) alias = identifier();
            have(TokenType::Colon);
            node_ptr hbody = blockOrStmt();
            checkExceptStarFlow(hbody, false);   // round 78
            auto run = make_node<BlockNode>(tok);
            if(!alias.empty()) run->add(make_node<AssignmentNode>(T("="), var(alias), match_of()));
            run->add(hbody);
            auto collect = make_node<TryNode>(tok, run);
            std::static_pointer_cast<TryNode>(collect)->except_clauses.push_back(
                catch_all(xv, call("_ny_star_raised", {var(sv), var(xv)})));
            auto activate = make_node<TryNode>(tok, make_node<RaiseNode>(tok, match_of()));
            auto collect_blk = make_node<BlockNode>(tok);
            collect_blk->add(collect);
            std::static_pointer_cast<TryNode>(activate)->except_clauses.push_back(catch_all("", collect_blk));
            auto then_blk = make_node<BlockNode>(tok);
            then_blk->add(activate);
            Token nt = T("is not");
            auto cond = make_node<BinaryNode>(nt, call("_ny_star_match", {var(sv), types}), make_node<NoneNode>(T("none")));
            handler->add(make_node<IfNode>(tok, cond, then_blk));
            while(have(TokenType::NewLine)) {}
        }
        handler->add(call("_ny_star_finish", {var(sv)}));
        tn->except_clauses.push_back(catch_all(ev, handler));
        return try_node;
    }
    // A bare name after `except` is a TYPE when it names an exception class
    // (a builtin one, or anything capitalised, as class names are) and the
    // Nython catch-all binding `except e:` otherwise. Both engines used to
    // read every bare name as a binding, so `except ValueError:` caught
    // everything - and rebound the name ValueError to the exception.
    // round 79: a private class name counts too (`except _Stop:`, after its
    // leading underscores) - it was a catch-all binding named _Stop, which
    // caught every exception
    auto is_type_name = [](const std::string& n) {
        size_t u = 0;
        while (u < n.size() && n[u] == '_') u++;
        return nython::ny_is_builtin_exc(n) || (u < n.size() && n[u] >= 'A' && n[u] <= 'Z')
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
    // round 80: `except <expression>:` - any expression, as Python's grammar
    // has it (`except self._error:`, `except errs[0]:`, `except get():`,
    // `except (A, B) + extra as e:`). The forms the engines match by name
    // (a dotted name, a parenthesised list of them) keep their path; from
    // the first clause with an expression on, the clauses are lowered to
    // one catch-all whose body tests them in order:
    //     except BaseException as __exmN__:
    //         if _ny_exc_match(__exmN__, EXPR):  e = __exmN__; BODY
    //         elif _ny_exc_match(__exmN__, (A, B)): BODY2
    //         else: raise
    // (the prelude's _ny_exc_match is CPython's PyErr_GivenExceptionMatches,
    // with its TypeError for a non-exception class).
    struct EClause { Token etok; std::string ename, ealias, var; std::vector<std::string> types; node_ptr texpr; node_ptr body; };
    std::vector<EClause> eclauses;
    auto tk = [&](int k) { return k == 0 ? token() : peek(k); };
    auto ends_clause = [&](int k) {
        TokenType tt = tk(k).type();
        return tt == TokenType::Colon || tt == TokenType::As || tt == TokenType::NewLine || tt == TokenType::BraceOpen
               || tt == TokenType::Indent || tt == TokenType::SemiColon || tt == TokenType::End;
    };
    auto dotted_end = [&](int k) -> int {
        TokenType tt = tk(k).type();
        bool name = tt == TokenType::Identifier
                    || ((tt == TokenType::Struct || tt == TokenType::Enum || tt == TokenType::Interface
                         || tt == TokenType::NameSpace || tt == TokenType::Package) && tk(k + 1).type() == TokenType::Dot);
        if(!name) return -1;
        k++;
        while(tk(k).type() == TokenType::Dot && tk(k + 1).type() == TokenType::Identifier) k += 2;
        return k;
    };
    auto names_clause = [&]() {
        if(see(TokenType::As) || ends_clause(0)) return true;
        if(see(TokenType::ParenOpen)){
            int k = 1;
            while(tk(k).type() != TokenType::ParenClose){
                int e = dotted_end(k);
                if(e < 0) return false;
                k = e;
                if(tk(k).type() == TokenType::Comma) k++;
                else if(tk(k).type() != TokenType::ParenClose) return false;
            }
            return ends_clause(k + 1);
        }
        int e = dotted_end(0);
        return e >= 0 && ends_clause(e);
    };
    while(see(TokenType::Except) && !(value() == "catch" && usedAsName())){   // `catch = 1` is a name (round 77)
        Token etok = token();   // the clause's own line (round 79: sys.settrace's line event, tracebacks)
        next(); // consume 'except'
        std::string ename, ealias;
        std::vector<std::string> types;
        std::string var;
        node_ptr texpr;
        if(!names_clause()){
            texpr = ternary();
            if(have(TokenType::As)) { ealias = identifier(); var = ealias; }
        } else if(see(TokenType::As)){
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
        eclauses.push_back(EClause{etok, ename, ealias, var, std::move(types), texpr, ebody});
        while(have(TokenType::NewLine)) {}
    }
    size_t first_expr = eclauses.size();
    for(size_t i = 0; i < eclauses.size(); i++) if(eclauses[i].texpr) { first_expr = i; break; }
    for(size_t i = 0; i < first_expr; i++){
        EClause& c = eclauses[i];
        auto en = make_node<ExceptNode>(c.etok, c.ename, c.ealias, c.body);
        auto enp = std::static_pointer_cast<ExceptNode>(en);
        enp->types = std::move(c.types);
        enp->var = std::move(c.var);
        tn->except_clauses.push_back(en);
    }
    if(first_expr < eclauses.size()){
        static int exm_counter = 0;
        Token t0 = eclauses[first_expr].etok;
        std::string ev = "__exm" + std::to_string(exm_counter++) + "__";
        auto T = [&](const Token& base, const std::string& v){ Token t = base; t.value = v; return t; };
        auto var_of = [&](const Token& base, const std::string& n) -> node_ptr { return make_node<VariableNode>(T(base, n)); };
        // a dotted name the engines would have looked up: the same lookup
        auto name_expr = [&](const Token& base, const std::string& dn) -> node_ptr {
            size_t a = dn.find('.');
            node_ptr e = var_of(base, dn.substr(0, a));
            while(a != std::string::npos){
                size_t b = dn.find('.', a + 1);
                std::string part = dn.substr(a + 1, b == std::string::npos ? std::string::npos : b - a - 1);
                e = make_node<AttributeNode>(T(base, part), e, part);
                a = b;
            }
            return e;
        };
        // the clause's binding: a local, or the module's for a `global` name
        auto bind = [&](const Token& base, const std::string& n) -> node_ptr {
            bool is_global = !global_decls_.empty()
                             && std::find(global_decls_.back().begin(), global_decls_.back().end(), n) != global_decls_.back().end();
            if(!is_global) return make_node<VarDeclNode>(T(base, n), n, var_of(base, ev));
            auto vn = std::make_shared<VariableNode>(T(base, n));
            vn->global_ref = true;
            return make_node<AssignmentNode>(T(base, "="), vn, var_of(base, ev));
        };
        node_ptr chain = make_node<RaiseNode>(eclauses.back().etok);   // nothing matched: re-raised
        for(size_t j = eclauses.size(); j-- > first_expr;){
            EClause& c = eclauses[j];
            auto run = make_node<BlockNode>(c.etok);
            if(!c.var.empty()) run->add(bind(c.etok, c.var));
            run->add(c.body);
            node_ptr test;
            if(c.texpr) test = c.texpr;
            else if(!c.types.empty()){
                if(c.types.size() == 1) test = name_expr(c.etok, c.types[0]);
                else {
                    auto tup = make_node<TupleNode>(c.etok);
                    for(auto& n : c.types) tup->add(name_expr(c.etok, n));
                    test = tup;
                }
            }
            if(!test){ chain = run; continue; }   // a catch-all clause
            auto call = make_node<CallNode>(T(c.etok, "_ny_exc_match"), var_of(c.etok, "_ny_exc_match"));
            call->add(var_of(c.etok, ev));
            call->add(test);
            auto ifn = make_node<IfNode>(c.etok, call, run);
            std::static_pointer_cast<IfNode>(ifn)->else_branch = chain;
            chain = ifn;
        }
        auto en = make_node<ExceptNode>(t0, "BaseException", ev, chain);
        auto enp = std::static_pointer_cast<ExceptNode>(en);
        enp->types = {"BaseException"};
        enp->var = ev;
        // round 81: `as e` is unbound when the clause ends (CPython deletes it)
        for(size_t j = first_expr; j < eclauses.size(); j++){
            const std::string& n = eclauses[j].var;
            if(n.empty()) continue;
            bool seen = false;
            for(auto& u : enp->unbind_names) if(u.first == n) seen = true;
            if(seen) continue;
            bool is_global = !global_decls_.empty()
                             && std::find(global_decls_.back().begin(), global_decls_.back().end(), n) != global_decls_.back().end();
            enp->unbind_names.push_back({n, is_global});
        }
        tn->except_clauses.push_back(en);
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
    // -O (round 80): assert statements are dropped, as CPython compiles them
    if(nyrt::cli_flags().optimize > 0 && !ast_mode_) return make_node<PassNode>(tok);   // round 83: kept in ast mode
    return make_node<AssertNode>(tok, cond, msg);
}

node_ptr Parser::switchStmt(){
    Token tok = token(); mustBe(TokenType::Switch);
    if(tok.value == "match") return matchStmt(tok, ast_mode_ ? exprList(token()) : expression());   // round 83: `match a, b:` in ast mode
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
    int t0 = scanner->current;   // round 83: spans (ast mode)
    auto item = [&](){
        if(have(TokenType::Mul)){
            int s0 = scanner->current - 1;
            seq->star = (int)seq->subs.size(); seq->star_name = identifier();
            seq->subs.push_back(std::make_shared<MatchPat>());
            seq->subs.back()->t0 = s0; seq->subs.back()->t1 = lastTok();
        } else seq->subs.push_back(matchOrPattern());
    };
    item();
    if(!see(TokenType::Comma) && seq->star < 0) return seq->subs[0];
    while(have(TokenType::Comma)){
        if(see(TokenType::Colon) || see(TokenType::If)) break;
        item();
    }
    seq->t0 = t0; seq->t1 = lastTok();
    return seq;
}

std::shared_ptr<Parser::MatchPat> Parser::matchOrPattern(){
    int t0 = scanner->current;   // round 83: spans (ast mode)
    auto first = matchClosedPattern();
    std::shared_ptr<MatchPat> p = first;
    if(see(TokenType::BinOr)){
        p = std::make_shared<MatchPat>(); p->kind = MatchPat::OR;
        p->subs.push_back(first);
        while(have(TokenType::BinOr)) p->subs.push_back(matchClosedPattern());
        p->t0 = t0; p->t1 = lastTok();
    }
    if(have(TokenType::As)){
        if(!p->as_name.empty()){
            auto w = std::make_shared<MatchPat>(); w->kind = MatchPat::OR;
            w->subs.push_back(p); p = w;
            p->t0 = t0; p->t1 = lastTok() - 1;
        }
        p->as_name = identifier();
        p->as_t0 = t0; p->as_t1 = lastTok();
    }
    return p;
}

// round 83: a closed pattern's span (ast mode); a parenthesised one keeps
// the span of the pattern inside, as CPython's
std::shared_ptr<Parser::MatchPat> Parser::matchClosedPattern(){
    int t0 = scanner->current;
    auto p = matchClosedPattern_();
    if(p && p->t0 < 0){ p->t0 = t0; p->t1 = lastTok(); }
    return p;
}

std::shared_ptr<Parser::MatchPat> Parser::matchClosedPattern_(){
    auto p = std::make_shared<MatchPat>();
    Token tok = token();
    // Items of a bracketed sequence, `*name` allowed once.
    auto seq_items = [&](TokenType close){
        p->kind = MatchPat::SEQ;
        while(!see(close)){
            while(have(TokenType::NewLine)) {}
            if(see(close)) break;
            if(have(TokenType::Mul)){
                int s0 = scanner->current - 1;   // round 83
                p->star = (int)p->subs.size(); p->star_name = identifier();
                p->subs.push_back(std::make_shared<MatchPat>());
                p->subs.back()->t0 = s0; p->subs.back()->t1 = lastTok();
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
       || see(TokenType::Sub) || see(TokenType::True) || see(TokenType::False) || see(TokenType::None)
       || see(TokenType::Bytes) || see(TokenType::Complex)){   // b"x", 2j (round 77)
        p->kind = MatchPat::VALUE; p->value = unary();
        // a complex literal: `case 1 + 2j`, `case -1 - 2j`
        if((see(TokenType::Add) || see(TokenType::Sub)) && peek(1).type() == TokenType::Complex){
            Token op = token(); next();
            node_ptr im = unary();
            p->value = make_node<BinaryNode>(op, p->value, im);
        }
        return p;
    }
    throw SyntaxError(tok.location(), "Unexpected token in a case pattern: " + tok.value);
}

// round 83: a pattern as Python's tree has it (ast mode): MatchValue,
// MatchSingleton, MatchSequence/MatchStar, MatchMapping, MatchClass,
// MatchAs, MatchOr, each with its span
node_ptr Parser::patAst(const std::shared_ptr<MatchPat>& p){
    Token tok = token();
    auto mk = [&](const char* kind, int t0, int t1) {
        auto n = std::make_shared<PyAstNode>(tok, kind);
        if(t0 >= 0 && t1 >= t0) ast_spans_[n.get()] = {t0, t1};
        return n;
    };
    node_ptr out;
    switch(p->kind){
    case MatchPat::WILD:
        out = mk("MatchAs", p->t0, p->t1);
        break;
    case MatchPat::CAPTURE: {
        auto n = mk("MatchAs", p->t0, p->t1);
        n->str("name", p->name);
        out = n;
        break;
    }
    case MatchPat::VALUE: {
        node_ptr v = p->value;
        bool single = v && (v->type() == NodeType::NONE || v->type() == NodeType::TRUE || v->type() == NodeType::FALSE);
        auto n = mk(single ? "MatchSingleton" : "MatchValue", p->t0, p->t1);
        n->kid("value", v);
        out = n;
        break;
    }
    case MatchPat::OR: {
        if(p->subs.size() == 1){ out = patAst(p->subs[0]); break; }
        auto n = mk("MatchOr", p->t0, p->t1);
        std::vector<node_ptr> ps;
        for(auto& s : p->subs) ps.push_back(patAst(s));
        n->list("patterns", ps);
        out = n;
        break;
    }
    case MatchPat::SEQ: {
        auto n = mk("MatchSequence", p->t0, p->t1);
        std::vector<node_ptr> ps;
        for(size_t i = 0; i < p->subs.size(); i++){
            if((int)i == p->star){
                auto st = mk("MatchStar", p->subs[i]->t0, p->subs[i]->t1);
                if(p->star_name != "_") st->str("name", p->star_name);
                ps.push_back(st);
            } else ps.push_back(patAst(p->subs[i]));
        }
        n->list("patterns", ps);
        out = n;
        break;
    }
    case MatchPat::CLASS: {
        auto n = mk("MatchClass", p->t0, p->t1);
        std::vector<node_ptr> ps, kps;
        std::vector<std::string> ks;
        for(auto& s : p->subs) ps.push_back(patAst(s));
        for(auto& kv : p->kw){ ks.push_back(kv.first); kps.push_back(patAst(kv.second)); }
        n->kid("cls", p->value)->list("patterns", ps)->strl("kwd_attrs", ks)->list("kwd_patterns", kps);
        out = n;
        break;
    }
    case MatchPat::MAP: {
        auto n = mk("MatchMapping", p->t0, p->t1);
        std::vector<node_ptr> ks, ps;
        for(auto& kv : p->items){ ks.push_back(kv.first); ps.push_back(patAst(kv.second)); }
        n->list("keys", ks)->list("patterns", ps);
        if(!p->rest.empty()) n->str("rest", p->rest);
        out = n;
        break;
    }
    }
    if(!p->as_name.empty()){
        auto n = mk("MatchAs", p->as_t0, p->as_t1);
        n->kid("pattern", out)->str("name", p->as_name);
        out = n;
    }
    return out;
}

node_ptr Parser::matchStmt(Token tok, node_ptr subject){
    if(ast_mode_){
        // round 83: Match(subject, cases=[match_case(pattern, guard, body)])
        have(TokenType::Colon);
        bool has_brace = have(TokenType::BraceOpen);
        have(TokenType::NewLine);
        bool has_indent = have(TokenType::Indent);
        auto at_end = [&]() -> bool {
            if(has_brace && see(TokenType::BraceClose)) return true;
            if(has_indent && see(TokenType::Dedent)) return true;
            return see(TokenType::End);
        };
        std::vector<node_ptr> cases;
        while(!at_end()){
            while(have(TokenType::NewLine)) {}
            if(at_end()) break;
            if(!have(TokenType::Case))
                throw SyntaxError(token().location(), "Expected 'case' in a match statement, got: " + token().value);
            auto pat = matchPattern();
            node_ptr guard;
            if(have(TokenType::If)) guard = expression();
            mustBe(TokenType::Colon);
            node_ptr body = blockOrStmt();
            auto mc = std::make_shared<PyAstNode>(tok, "match_case");
            mc->kid("pattern", patAst(pat))->kid("guard", guard)->kid("body", body);
            cases.push_back(mc);
        }
        if(has_indent) have(TokenType::Dedent);
        if(has_brace) have(TokenType::BraceClose);
        have(TokenType::NewLine);
        auto m = std::make_shared<PyAstNode>(tok, "Match");
        m->kid("subject", subject)->list("cases", cases);
        return m;
    }
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
            // a sequence pattern matches lists and tuples (round 77: tuples
            // never matched `case (a, b)`), not str/bytes
            auto seq_types = make_node<TupleNode>(tok);
            seq_types->add(var_ref("list"));
            seq_types->add(var_ref("tuple"));
            node_ptr r = call("isinstance", {path(), seq_types});
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
                    assign(p->star_name, call("_ny_list_cat", {sl}));   // always a list (round 77)
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

// `del a, b`, `del x[0], y.z`, `del (a, [b, c])`: each target in turn, left
// to right, as Python deletes them (round 77: a comma was a syntax error).
void Parser::delTargets(node_ptr t, std::vector<node_ptr>& out){
    if(t && (t->type() == NodeType::TUPLE || t->type() == NodeType::LIST)){
        for(auto& e : t->statements()) delTargets(e, out);
        return;
    }
    out.push_back(asTarget(t));
}

node_ptr Parser::deleteStmt(){
    Token tok = token(); mustBe(TokenType::Delete);
    if(ast_mode_){
        // round 83: Delete(targets), each as written (a tuple stays one)
        std::vector<node_ptr> ts;
        do {
            if(endsExprList(token().type())) break;
            ts.push_back(asTarget(ternary()));
        } while(have(TokenType::Comma));
        if(ts.empty()) throw SyntaxError(tok.location(), "invalid syntax");
        consumed_semi_ = have(TokenType::SemiColon);
        if(!consumed_semi_) have(TokenType::NewLine);
        auto d = std::make_shared<PyAstNode>(tok, "Delete");
        d->list("targets", ts);
        return d;
    }
    std::vector<node_ptr> targets;
    do {
        if(endsExprList(token().type())) break;
        delTargets(ternary(), targets);
    } while(have(TokenType::Comma));
    if(targets.empty()) throw SyntaxError(tok.location(), "invalid syntax: del needs a target");
    consumed_semi_ = have(TokenType::SemiColon);
    if(!consumed_semi_) have(TokenType::NewLine);
    if(targets.size() == 1) return make_node<DeleteNode>(tok, targets[0]);
    auto blk = make_node<BlockNode>(tok);
    for(auto& t : targets) blk->add(make_node<DeleteNode>(tok, t));
    return blk;
}

// with A() as a, B() as b: body  ==  with A() as a: (with B() as b: body)
// `async with` (is_async) passes each manager through _ny_async_cm.
node_ptr Parser::withStmt(bool is_async){
    Token tok = token(); mustBe(TokenType::With);
    // `with (A() as a, B() as b):` (Python 3.10): the items in parentheses,
    // over several lines if need be - when the `)` matching the first `(`
    // ends the header; `with (a, b):` is two managers, as in CPython
    // (round 77).
    bool paren = false;
    if(see(TokenType::ParenOpen)){
        int depth = 0, k = 0;
        for(; k < 1 << 20; k++){
            TokenType tt = peek(k).type();
            if(tt == TokenType::End) break;
            if(tt == TokenType::ParenOpen || tt == TokenType::BracketOpen || tt == TokenType::BraceOpen) depth++;
            else if(tt == TokenType::ParenClose || tt == TokenType::BracketClose || tt == TokenType::BraceClose){
                if(--depth == 0) break;
            }
        }
        paren = peek(k).type() != TokenType::End && peek(k + 1).type() == TokenType::Colon;
        if(paren) next();
    }
    auto skip_nl = [&]() { if(paren) while(have(TokenType::NewLine) || have(TokenType::Indent) || have(TokenType::Dedent)) {} };
    // `as` binds a name, or any target (`as self.f`, `as (a, b)`): then a
    // hidden name, bound to the target first thing in the body
    std::vector<std::pair<node_ptr, std::string>> items;
    std::vector<std::pair<std::string, node_ptr>> bind_after;
    skip_nl();
    if(ast_mode_){
        // round 83: With/AsyncWith(items, body), each a withitem(context_expr,
        // optional_vars) with the target as written
        std::vector<node_ptr> witems;
        do {
            skip_nl();
            if(paren && see(TokenType::ParenClose)) break;
            node_ptr expr = ternary();
            node_ptr target;
            if(have(TokenType::As)){
                in_assign_target_ = true;
                try { target = asTarget(postfix()); } catch(...) { in_assign_target_ = false; throw; }
                in_assign_target_ = false;
            }
            auto wi = std::make_shared<PyAstNode>(tok, "withitem");
            wi->kid("context_expr", expr)->kid("optional_vars", target);
            witems.push_back(wi);
            skip_nl();
        } while(have(TokenType::Comma));
        if(paren){ skip_nl(); mustBe(TokenType::ParenClose); }
        have(TokenType::Colon);
        node_ptr body = blockOrStmt();
        auto w = std::make_shared<PyAstNode>(tok, is_async ? "AsyncWith" : "With");
        w->list("items", witems)->kid("body", body);
        return w;
    }
    do {
        skip_nl();
        if(paren && see(TokenType::ParenClose)) break;
        node_ptr expr = ternary();
        if(is_async) expr = wrap_call("_ny_async_cm", expr);
        std::string alias;
        if(have(TokenType::As)){
            bool simple = (see(TokenType::Identifier) || nameKeyword(token().type()))
                       && (peek().type() == TokenType::Comma || peek().type() == TokenType::Colon
                           || peek().type() == TokenType::ParenClose || peek().type() == TokenType::NewLine);
            if(simple) alias = identifier();
            else {
                in_assign_target_ = true;
                node_ptr t;
                try { t = asTarget(postfix()); } catch(...) { in_assign_target_ = false; throw; }
                in_assign_target_ = false;
                alias = "__with" + unpackTemp();
                bind_after.push_back({alias, t});
            }
        }
        items.emplace_back(expr, alias);
        skip_nl();
    } while(have(TokenType::Comma));
    if(paren){ skip_nl(); mustBe(TokenType::ParenClose); }
    have(TokenType::Colon);
    node_ptr body = blockOrStmt();
    if(!bind_after.empty()){
        auto pre = make_node<BlockNode>(tok);
        for(auto& [hidden, t] : bind_after){
            Token ht = tok; ht.value = hidden;
            bindTarget(tok, t, make_node<VariableNode>(ht), pre);
        }
        pre->add(body);
        body = pre;
    }
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
    if(ast_mode_) return expr;   // round 83: the annotation itself
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

node_ptr Parser::lambdaExpr_(){   // round 83: lambdaExpr() records its span in ast mode (Parser.hpp)
    Token tok = token(); mustBe(TokenType::Lambda);
    // A lambda inside a parameter list (`def f(g=lambda n: n, h=2)`) has
    // defaults of its own: the list's are put back after it (round 78 - the
    // lambda took them, and h lost its default).
    auto outer_defaults = std::move(param_defaults_);
    param_defaults_.clear();
    struct Restore {
        std::vector<node_ptr>& d; std::vector<node_ptr> saved;
        ~Restore() { d = std::move(saved); }
    } restore_defaults{param_defaults_, std::move(outer_defaults)};
    std::vector<node_ptr> params;
    // Only parse params if not immediately followed by ':'
    if(!see(TokenType::Colon)){
        params = lambdaParamList();
    }
    size_t posonly = lambda_posonly_;
    mustBe(TokenType::Colon);
    yield_seen_.push_back(false);
    self_scope_.push_back(!params.empty() && (params[0]->value() == "self" || params[0]->value() == "this"));
    node_ptr body;
    // the body is a single expression: `lambda: (yield)`, not a tuple
    try { body = ternary(); } catch(...) { self_scope_.pop_back(); yield_seen_.pop_back(); throw; }
    self_scope_.pop_back();
    yield_seen_.pop_back();
    auto lam = make_node<LambdaNode>(tok, body);
    static_cast<LambdaNode*>(lam.get())->qualname = qualOf("<lambda>");   // round 77
    for(auto& p : params) lam->add(p);
    static_cast<LambdaNode*>(lam.get())->defaults = std::move(param_defaults_);
    static_cast<LambdaNode*>(lam.get())->posonly = posonly;   // round 77
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
            // consume trailing 'end' for then/end syntax - a lone `end`,
            // not the name (`end = 5` after a block, round 77)
            if(see(TokenType::EndBlock) && (peek().type() == TokenType::NewLine || peek().type() == TokenType::End
                                            || peek().type() == TokenType::SemiColon || peek().type() == TokenType::Dedent)) next();
            else have(TokenType::End);
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
    // work here too. Every simple statement ends at its `;` (round 77: after
    // `if c: pass; x = 1` or `if c: del a; b = 2`, the rest ran unconditionally).
    auto ended_by_semi = [&]() { return consumed_semi_ || prev().type() == TokenType::SemiColon; };
    if(!ended_by_semi()) return first;
    auto blk = make_node<BlockNode>(this->token());
    if(first) blk->add(first);
    while(ended_by_semi()){
        if(see(TokenType::NewLine)||see(TokenType::End)||see(TokenType::Dedent)) break;
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
        if(async_clause && ast_mode_) ast_flags_[cl.iter.get()] = "async";   // round 83: is_async=1
        else if(!ast_mode_){
            // round 84: a starred target (`for a, *b in it`): the names stay
            // the target and each item is reshaped first (the prelude's
            // _ny_star_iter: the starred part a list, CPython's count errors);
            // ast mode keeps Python's Starred
            if(node_ptr spec = starTargetSpec(cl.target)){
                if(async_clause) throw SyntaxError(tok.location(), "a starred target in an async comprehension is not supported");
                auto call = std::static_pointer_cast<CallNode>(wrap_call("_ny_star_iter", cl.iter));
                call->add(spec);
                cl.iter = call;
            }
            if(async_clause) cl.iter = wrap_call("_ny_aiter", cl.iter);
        }
        while(have(TokenType::If)) cl.conds.push_back(logicalOr());
        cp->clauses.push_back(std::move(cl));
    } while(haveCompFor());
    return comp;
}

// A comprehension target: a name, or a (possibly nested, possibly
// parenthesised) comma-separated list of targets.
node_ptr Parser::compTargetOne(){
    Token tok = token();
    if(ast_mode_){
        // round 83: Python's target - `(x)` is x, `(a, b)` a Tuple, `[a]` a
        // List, `*x` Starred, an attribute or item too
        int t0 = scanner->current;
        if(see(TokenType::Mul)){
            Token st = token(); next(); st.value = "*";
            node_ptr t = make_node<UnaryNode>(st, compTargetOne());
            spanSet(t.get(), t0);
            return t;
        }
        if(have(TokenType::ParenOpen) || have(TokenType::BracketOpen)){
            bool list = prev().type() == TokenType::BracketOpen;
            if(have(list ? TokenType::BracketClose : TokenType::ParenClose)){
                node_ptr e = list ? make_node<ListNode>(tok) : make_node<TupleNode>(tok);
                spanSet(e.get(), t0);
                return e;
            }
            node_ptr t = compTarget();
            mustBe(list ? TokenType::BracketClose : TokenType::ParenClose);
            if(list){
                auto l = make_node<ListNode>(tok);
                if(t->type() == NodeType::TUPLE && !ast_outer_.count(t.get())) for(auto& e : t->statements()) l->add(e);
                else l->add(t);
                spanSet(l.get(), t0);
                return l;
            }
            if(t->type() == NodeType::TUPLE && !ast_outer_.count(t.get())){ ast_spans_.erase(t.get()); spanSet(t.get(), t0); }
            else ast_outer_[t.get()] = {t0, scanner->current - 1};
            return t;
        }
        node_ptr t = asTarget(postfix());
        return t;
    }
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
    // round 84: `*name` (a starred target, lowered by starTargetSpec)
    if(see(TokenType::Mul)){
        Token st = token();
        next();
        st.value = "*";
        Token id = token();
        id.value = identifier();
        return make_node<UnaryNode>(st, make_node<VariableNode>(id));
    }
    Token id = token();
    id.value = identifier();
    return make_node<VariableNode>(id);
}

// round 84: a comprehension target holding a starred name, rewritten in
// place to the plain names, and the shape _ny_star_iter reshapes items to:
// a list per tuple level, 1 for its starred element, 0 for a name, a list
// for a nested tuple. nullptr when the target has no starred name.
node_ptr Parser::starTargetSpec(node_ptr& target){
    if(!target || target->type() != NodeType::TUPLE) return nullptr;
    bool any = false;
    std::function<node_ptr(node_ptr&)> walk = [&](node_ptr& t) -> node_ptr {
        Token tk = t->token();
        auto spec = std::static_pointer_cast<ListNode>(make_node<ListNode>(tk));
        auto& elems = static_cast<TupleNode*>(t.get())->elements;   // rewritten in place
        int stars = 0;
        for(auto& e : elems){
            Token it = tk; it.type(TokenType::Integer);
            if(isStarElem(e)){
                if(++stars > 1) throw SyntaxError(e->token().location(), "multiple starred expressions in assignment");
                any = true;
                e = static_cast<UnaryNode*>(e.get())->operand;
                it.value = "1";
                spec->add(make_node<IntegerNode>(it));
            } else if(e->type() == NodeType::TUPLE){
                spec->add(walk(e));
            } else {
                it.value = "0";
                spec->add(make_node<IntegerNode>(it));
            }
        }
        return spec;
    };
    node_ptr spec = walk(target);
    return any ? spec : nullptr;
}

node_ptr Parser::compTarget(){
    Token tok = token();
    int t0 = scanner->current;   // round 83
    node_ptr first = compTargetOne();
    if(!see(TokenType::Comma)) return first;
    auto tup = make_node<TupleNode>(tok);
    tup->add(first);
    while(have(TokenType::Comma)){
        if(see(TokenType::In) || see(TokenType::ParenClose) || see(TokenType::BracketClose)) break;
        tup->add(compTargetOne());
    }
    if(ast_mode_) spanSet(tup.get(), t0);
    return tup;
}

node_ptr Parser::starElem_(){   // round 83: starElem() records its span in ast mode (Parser.hpp)
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

node_ptr Parser::listLiteral_(){   // round 83: listLiteral() records its span in ast mode (Parser.hpp)
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
    if(starred && !in_assign_target_ && !ast_mode_) return catStarred(tok, list->statements(), nullptr);   // round 83
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

node_ptr Parser::mapLiteral_(){   // round 83: mapLiteral() records its span in ast mode (Parser.hpp)
    Token tok = token();
    mustBe(TokenType::BraceOpen);
    if(ast_mode_){
        // round 83: Dict(keys, values) - a None key for `**d` - or Set(elts),
        // or a dict/set comprehension
        std::vector<node_ptr> keys, vals;
        auto dict = [&]() -> node_ptr {
            auto d = std::make_shared<PyAstNode>(tok, "Dict");
            d->list("keys", keys)->list("values", vals);
            return d;
        };
        if(have(TokenType::BraceClose)) return dict();
        if(have(TokenType::Exp)){ keys.push_back(nullptr); vals.push_back(bitwiseOr()); }
        else {
            node_ptr first = starElem();
            if(!isStarElem(first) && have(TokenType::Colon)){
                node_ptr v = expression();
                if(haveCompFor()){
                    node_ptr comp = comprehension(tok, ComprehensionNode::DICT, first, v);
                    mustBe(TokenType::BraceClose);
                    return comp;
                }
                keys.push_back(first); vals.push_back(v);
            } else {
                if(!isStarElem(first) && haveCompFor()){
                    node_ptr comp = comprehension(tok, ComprehensionNode::SET, first, nullptr);
                    mustBe(TokenType::BraceClose);
                    return comp;
                }
                std::vector<node_ptr> elts{first};
                while(have(TokenType::Comma) && !see(TokenType::BraceClose)) elts.push_back(starElem());
                mustBe(TokenType::BraceClose);
                auto st = std::make_shared<PyAstNode>(tok, "Set");
                st->list("elts", elts);
                return st;
            }
        }
        while(have(TokenType::Comma) && !see(TokenType::BraceClose)){
            if(have(TokenType::Exp)){ keys.push_back(nullptr); vals.push_back(bitwiseOr()); continue; }
            node_ptr k = expression();
            mustBe(TokenType::Colon);
            node_ptr v = expression();
            keys.push_back(k); vals.push_back(v);
        }
        mustBe(TokenType::BraceClose);
        return dict();
    }
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
