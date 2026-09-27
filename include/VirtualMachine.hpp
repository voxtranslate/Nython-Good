#pragma once// VirtualMachine.hpp — Nython Bytecode VM
// Compiler: AST → Bytecode. VM: Stack-based execution engine.
#ifndef __VIRTUAL_MACHINE__HPP
#define __VIRTUAL_MACHINE__HPP

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmisleading-indentation"

#include <memory>
#include <vector>
#include <deque>
#include <string>
#include <unordered_map>
#include <functional>
#include <unordered_set>
#include <optional>
#include <cassert>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <cmath>
#include <stdexcept>
#include <algorithm>
#include <limits>
#include <fstream>
#include <sys/stat.h>
#include <sys/types.h>
#ifndef _WIN32
#include <sys/resource.h>
#include <dirent.h>
#include <unistd.h>
#include <pthread.h>
#endif
#include <ctime>
#include <cstdlib>
#include <thread>
#include <chrono>
#include <functional>
#include <unordered_set>
#include <cerrno>
#include "NyTensor.hpp"
#include "NyJson.hpp"
#include "NyFuzzy.hpp"
#include "NyOrderedMap.hpp"
#include "NyBigInt.hpp"
#include "NyStr.hpp"
#include "NyFormat.hpp"
#include "NyRuntime.hpp"
#include "NyPrelude.hpp"
#include "NyConc.hpp"   // concurrency runtime shared with the interpreter
#include <random>

#include "Value.hpp"
#include "Object.hpp"
#include "Lexer.hpp"
#include "Parser.hpp"
#include "Runnable.hpp"
#include "GarbageCollector.hpp"
#include "ASTNodes.hpp"
#include "Context.hpp"

using nython::Runnable;
using nython::kernel::Value;
using nython::kernel::ValueType;
using nython::kernel::Object;
using nython::gc::GarbageCollector;

namespace nython::vm {

// ═══════════════════════════════════════════════════════════════════════════
// OPCODE
// ═══════════════════════════════════════════════════════════════════════════
enum class Op : uint8_t {
    LOAD_CONST, LOAD_NAME, STORE_NAME, DEFINE_NAME,
    LOAD_ATTR,  STORE_ATTR, LOAD_SUBSCR, STORE_SUBSCR, DELETE_SUBSCR, DELETE_ATTR,
    BUILD_LIST, BUILD_MAP,
    DUP_TOP, POP_TOP, ROT_TWO, ROT_THREE,
    BINARY_ADD, BINARY_SUB, BINARY_MUL, BINARY_DIV,
    BINARY_MOD, BINARY_POW, BINARY_FLOOR_DIV,
    BINARY_AND, BINARY_OR,  BINARY_XOR, BINARY_LSHIFT, BINARY_RSHIFT,
    COMPARE_EQ, COMPARE_NE, COMPARE_LT, COMPARE_LE,
    COMPARE_GT, COMPARE_GE, COMPARE_IN, COMPARE_NOT_IN,
    COMPARE_IS, COMPARE_IS_NOT,
    COMPARE_IS_TYPE, COMPARE_IS_NOT_TYPE,
    UNARY_NEG, UNARY_NOT, UNARY_BITNOT, UNARY_POS,
    JUMP_FORWARD, JUMP_IF_TRUE, JUMP_IF_FALSE, JUMP_ABSOLUTE,
    JUMP_IF_TRUE_OR_POP, JUMP_IF_FALSE_OR_POP,
    MAKE_FUNCTION, CALL_FUNCTION, CALL_METHOD, RETURN_VALUE, YIELD_VALUE, YIELD_FROM_OP,
    MAKE_CLASS, LOAD_SELF,
    GET_ITER, FOR_ITER, UNPACK_SEQ,
    PRINT, IMPORT_NAME, NOP, HALT,
    IADD, ISUB, IMUL, IDIV, IMOD,
    RAISE_ERROR, SETUP_EXCEPT, END_EXCEPT, CALL_KW, CALL_EX,
    LIST_EXTEND, LIST_APPEND, LOAD_SUPER,
    RAISE, STORE_EXCEPT_AS,
    LOAD_SELF_ATTR, STORE_SELF_ATTR,
    // `===`/`!==` (strict: no int/float coercion, unlike COMPARE_EQ) and
    // logical `xor`/`^^` (truthiness xor - BINARY_XOR above is the bitwise
    // `^`, a different operator). These parsed into a BinaryNode fine but
    // bin_op() had no case for any of the three, so they compiled to NOP -
    // the operands were left on the stack instead of being combined and
    // consumed, corrupting whatever ran next (see HANDOFF.md).
    COMPARE_SEQ, COMPARE_SNE, LOGICAL_XOR,
    // A tuple display `(a, b)`: BUILD_LIST's items, as a tuple (VMVal::is_tuple).
    BUILD_TUPLE,
};

// ═══════════════════════════════════════════════════════════════════════════
// INSTRUCTION
// ═══════════════════════════════════════════════════════════════════════════
struct Instruction {
    Op  op;
    int arg;
    int line;
    Instruction(Op o, int a=0, int ln=0) : op(o), arg(a), line(ln) {}
};

// ═══════════════════════════════════════════════════════════════════════════
// VMVAL  — runtime value for the VM stack
// ═══════════════════════════════════════════════════════════════════════════
enum class VMType : uint8_t {
    NONE, BOOL, INT, FLOAT, STRING, LIST, MAP,
    FUNCTION, CLASS, INSTANCE, ITERATOR, GENERATOR, NATIVE, UNDEFINED, SUPER_PROXY,
};

struct VMCode;  // forward declaration (defined after VMVal)
struct VMVal;
// Dicts, instance fields and closure environments: insertion-ordered, so a
// dict iterates in the order its keys were added (as in Python).
using VMMap = nypy::OrderedMap<VMVal>;
using NativeFunc = std::function<struct VMVal(std::vector<struct VMVal>&)>;

struct VMVal {
    VMType type = VMType::NONE;
    bool   b    = false;
    int64_t i   = 0;
    double  d   = 0.0;
    std::string s;
    std::shared_ptr<std::vector<VMVal>>                        list;
    std::shared_ptr<VMMap>     map;
    std::shared_ptr<VMCode>                                    code;
    NativeFunc                                                 native;
    std::shared_ptr<std::pair<int,std::vector<VMVal>>>         iter;
    std::shared_ptr<struct GenState>                           gen;
    std::string class_name;
    // Closure environment: captured variables from enclosing scope
    std::shared_ptr<VMMap>     closure_env;

    // A LIST with b == true is a tuple: immutable, printed with parentheses,
    // never equal to a list, hashable as a dict key. An INT whose s is not
    // empty is a big int: s holds its exact decimal value and i the value
    // saturated to 64 bits (for code that only needs an index or a count).
    bool is_tuple() const { return type==VMType::LIST && b; }
    bool is_bigint() const { return type==VMType::INT && !s.empty(); }
    static VMVal make_tuple(std::vector<VMVal> items={}) {
        VMVal x=make_list(std::move(items)); x.b=true; return x;
    }
    static VMVal make_bigint(const nypy::BigInt& v) {
        int64_t t;
        if(v.to_i64(t)) return make_int(t);
        VMVal x; x.type=VMType::INT; x.s=v.to_string();
        x.i=v.neg?INT64_MIN:INT64_MAX;
        return x;
    }
    static VMVal make_none()              { return {}; }
    static VMVal make_bool(bool v)        { VMVal x; x.type=VMType::BOOL;  x.b=v; return x; }
    static VMVal make_int(int64_t v)      { VMVal x; x.type=VMType::INT;   x.i=v; return x; }
    static VMVal make_float(double v)     { VMVal x; x.type=VMType::FLOAT; x.d=v; return x; }
    static VMVal make_str(std::string v)  { VMVal x; x.type=VMType::STRING;x.s=std::move(v); return x; }
    static VMVal make_list(std::vector<VMVal> items={}) {
        VMVal x; x.type=VMType::LIST;
        x.list=std::make_shared<std::vector<VMVal>>(std::move(items)); return x;
    }
    static VMVal make_map() {
        VMVal x; x.type=VMType::MAP;
        x.map=std::make_shared<VMMap>(); return x;
    }
    static VMVal make_func(std::shared_ptr<VMCode> c) {
        VMVal x; x.type=VMType::FUNCTION; x.code=c; return x;
    }
    static VMVal make_class(std::shared_ptr<VMCode> c, std::string name) {
        VMVal x; x.type=VMType::CLASS; x.code=c; x.class_name=std::move(name); return x;
    }
    static VMVal make_instance(std::string cname,
        std::shared_ptr<VMMap> attrs) {
        VMVal x; x.type=VMType::INSTANCE; x.class_name=std::move(cname); x.map=attrs; return x;
    }
    static VMVal make_native(NativeFunc f) {
        VMVal x; x.type=VMType::NATIVE; x.native=std::move(f); return x;
    }
    static VMVal make_iter(std::vector<VMVal> items) {
        VMVal x; x.type=VMType::ITERATOR;
        x.iter=std::make_shared<std::pair<int,std::vector<VMVal>>>(0,std::move(items)); return x;
    }

    bool is_truthy() const {
        switch(type){
        case VMType::NONE:   return false;
        case VMType::BOOL:   return b;
        case VMType::INT:    return i!=0||!s.empty();
        case VMType::FLOAT:  return d!=0.0;
        case VMType::STRING: return !s.empty();
        case VMType::LIST:   return list&&!list->empty();
        case VMType::MAP:    return map&&!map->empty();
        default:             return true;
        }
    }

    std::string to_string() const;
    std::string repr() const;

    bool operator==(const VMVal& o) const {
        if(type!=o.type){
            if((type==VMType::INT&&o.type==VMType::FLOAT)||(type==VMType::FLOAT&&o.type==VMType::INT)){
                if(!s.empty()||!o.s.empty()) return num_compare(*this,o)==0;
                return type==VMType::INT ? (double)i==o.d : d==(double)o.i;
            }
            // true == 1 and false == 0, as on the interpreter (and in Python).
            if(type==VMType::BOOL&&o.type==VMType::INT) return (int64_t)b==o.i;
            if(type==VMType::INT&&o.type==VMType::BOOL) return i==(int64_t)o.b;
            if(type==VMType::BOOL&&o.type==VMType::FLOAT) return (double)b==o.d;
            if(type==VMType::FLOAT&&o.type==VMType::BOOL) return d==(double)o.b;
            return false;
        }
        switch(type){
        case VMType::NONE:   return true;
        case VMType::BOOL:   return b==o.b;
        case VMType::INT:    return i==o.i&&s==o.s;
        case VMType::FLOAT:  return d==o.d;
        case VMType::STRING: return s==o.s;
        case VMType::LIST:
            if(b!=o.b) return false;   // a list is never equal to a tuple
            if(!list&&!o.list) return true;
            if(!list||!o.list) return false;
            if(list->size()!=o.list->size()) return false;
            for(size_t idx=0;idx<list->size();idx++)
                if(!((*list)[idx]==(*o.list)[idx])) return false;
            return true;
        case VMType::MAP:
            if(!map&&!o.map) return true;
            if(!map||!o.map) return false;
            if(map->size()!=o.map->size()) return false;
            for(auto& [k,v]:*map){
                auto it=o.map->find(k);
                if(it==o.map->end()||!(v==it->second)) return false;}
            return true;
        case VMType::INSTANCE:
            // Two instances are equal only if same pointer (identity comparison)
            return map.get()==o.map.get();
        default:             return false;
        }
    }
    bool operator!=(const VMVal& o) const { return !(*this==o); }
    // Python ordering for numbers (bool is an int), strings and lists/tuples
    // (element by element); anything else is unordered and reads false.
    bool operator<(const VMVal& o) const {
        if(type==VMType::INT&&o.type==VMType::INT&&s.empty()&&o.s.empty()) return i<o.i;
        if(is_num()&&o.is_num()) { int c=num_compare(*this,o); return c==-1; }
        if(type==VMType::STRING&&o.type==VMType::STRING) return s<o.s;
        if(type==VMType::LIST&&o.type==VMType::LIST&&list&&o.list){
            size_t n=std::min(list->size(),o.list->size());
            for(size_t k=0;k<n;k++){
                const VMVal& x=(*list)[k]; const VMVal& y=(*o.list)[k];
                if(x==y) continue;
                return x<y;
            }
            return list->size()<o.list->size();
        }
        return false;
    }
    bool is_num() const { return type==VMType::INT||type==VMType::FLOAT||type==VMType::BOOL; }
    // This number as a nypy::NumV (false if it is not a number).
    bool to_numv(nypy::NumV& n) const {
        switch(type){
            case VMType::BOOL: n=nypy::NumV::I(b?1:0); return true;
            case VMType::INT:
                if(s.empty()){ n=nypy::NumV::I(i); return true; }
                { nypy::BigInt bi; nypy::BigInt::parse(s,10,bi); n=nypy::NumV::B(bi); return true; }
            case VMType::FLOAT: n=nypy::NumV::F(d); return true;
            default: return false;
        }
    }
    static VMVal from_numv(const nypy::NumV& n){
        if(n.k==3) return make_float(n.d);
        if(n.k==1) return make_int(n.i);
        return make_bigint(n.b);
    }
    // -1/0/1, or 2 when unordered (NaN).
    static int num_compare(const VMVal& a, const VMVal& b){
        nypy::NumV x,y;
        if(!a.to_numv(x)||!b.to_numv(y)) return 2;
        return nypy::num_cmp(x,y);
    }
    bool operator<=(const VMVal& o) const {
        if(is_num()&&o.is_num()){ int c=num_compare(*this,o); return c==-1||c==0; }
        return *this==o||*this<o;
    }
    bool operator> (const VMVal& o) const { return o<*this; }
    bool operator>=(const VMVal& o) const { return o<=*this; }
};

// ═══════════════════════════════════════════════════════════════════════════
// VMCODE — compiled code object
// ═══════════════════════════════════════════════════════════════════════════
struct ExceptionEntry {
    int try_start = 0;
    int try_end   = 0;
    // One entry per `except` clause, tried in source order - mirrors the
    // interpreter's evalTry (NythonExecutor.hpp), which walks tn->except_clauses
    // and runs the first one whose declared type matches (or is a parent of)
    // the raised exception's type, or that has no declared type at all. The
    // VM used to have a single `handler`/`alias` here and always ran the
    // FIRST except clause's body regardless of its declared type - every
    // other clause's body wasn't even compiled.
    struct Clause {
        std::string type_name;   // empty = catch-all, matches any exception
        std::string bind_var;    // empty = don't bind (bare "except:")
        int handler = 0;         // bytecode offset of this clause's body
    };
    std::vector<Clause> clauses;
    // Bytecode offset of the `else` clause's body (runs only if the try body
    // did NOT raise), or -1 if there is none. Previously not compiled at all.
    int else_handler = -1;
    // Offset immediately after the whole try/except/else, used when an
    // exception is raised but no clause's type matches - the interpreter
    // silently falls through to `finally` in that case rather than
    // re-raising, so the VM matches that instead of leaving the exception
    // to propagate further up.
    int end = 0;
};

struct VMCode {
    std::string              name;
    std::string              parent_class;
    std::string              owner_class;   // class that defines this method
    std::vector<Instruction> instructions;
    std::vector<VMVal>       constants;
    std::vector<std::string> names;
    std::vector<std::string> param_names;
    std::vector<VMVal>       param_defaults; // parallel to param_names; UNDEFINED = no default
    bool                     is_class      = false;
    bool                     is_method     = false;
    bool                     is_static     = false;
    bool                     is_classmethod= false;
    bool                     is_generator  = false;
    std::shared_ptr<VMMap> closure_env;
    std::vector<std::shared_ptr<VMCode>> sub_codes;
    std::vector<ExceptionEntry>          exc_table;

    int add_const(VMVal v) {
        if(v.type==VMType::NONE){
            for(int i=0;i<(int)constants.size();i++)
                if(constants[i].type==VMType::NONE) return i;
        }
        if(v.type==VMType::STRING){
            for(int i=0;i<(int)constants.size();i++)
                if(constants[i].type==VMType::STRING&&constants[i].s==v.s) return i;
        }
        constants.push_back(std::move(v));
        return (int)constants.size()-1;
    }
    int add_name(const std::string& n) {
        for(int i=0;i<(int)names.size();i++) if(names[i]==n) return i;
        names.push_back(n);
        return (int)names.size()-1;
    }
    int  emit(Op op, int arg=0, int line=0) {
        instructions.emplace_back(op,arg,line);
        return (int)instructions.size()-1;
    }
    void patch(int idx, int arg) { instructions[idx].arg=arg; }
    bool has_yield() const {
        for(auto& ins:instructions) if(ins.op==Op::YIELD_VALUE||ins.op==Op::YIELD_FROM_OP) return true;
        for(auto& sub:sub_codes) if(sub && sub->has_yield()) return true;
        return false;
    }
    int  here() const { return (int)instructions.size(); }
};


// ── VMVal method bodies (defined after VMCode is complete) ────────────────
// Object dict keys (instances, functions) by identity: the key text holds an
// id, this holds the value it stands for.
inline std::unordered_map<std::string, VMVal>& vm_key_objs() {
    static std::unordered_map<std::string, VMVal> m; return m;
}
// A dict key's stored text (NyStr.hpp: nypy::key_of_*) back to a value.
inline VMVal vm_key_value(const std::string& k) {
    switch(nypy::key_kind(k)){
        case nypy::K_STR: return VMVal::make_str(nypy::key_payload(k));
        case nypy::K_INT: { nypy::BigInt b; nypy::BigInt::parse(k.substr(2),10,b); return VMVal::make_bigint(b); }
        case nypy::K_FLOAT: return VMVal::make_float(std::strtod(k.c_str()+2,nullptr));
        case nypy::K_NONE: return VMVal::make_none();
        case nypy::K_TUPLE: {
            std::vector<VMVal> items;
            for(auto& part:nypy::key_tuple_parts(k)) items.push_back(vm_key_value(part));
            return VMVal::make_tuple(std::move(items));
        }
        case nypy::K_OBJ: {
            auto it=vm_key_objs().find(k.substr(2));
            return it!=vm_key_objs().end()?it->second:VMVal::make_none();
        }
    }
    return VMVal::make_none();
}
inline bool vm_internal_key(const std::string& k){ return k.size()>=2&&k[0]=='_'&&k[1]=='_'; }

inline std::string VMVal::to_string() const {
    switch(type){
    case VMType::NONE:    return "none";
    case VMType::BOOL:    return b?"true":"false";
    case VMType::INT:     return s.empty()?std::to_string(i):s;
    // Shortest text that reads back as the same float, as Python prints it
    // (0.1 + 0.2 -> 0.30000000000000004, 2.0, 1e+16) - NyFormat.hpp, the
    // same function the interpreter uses.
    case VMType::FLOAT:   return nypy::float_repr(d);
    case VMType::STRING:  return s;
    case VMType::LIST:{
        std::string r=b?"(":"[";
        if(list) for(size_t k=0;k<list->size();k++){
            if(k)r+=", ";
            const VMVal& e=(*list)[k];
            r+=(e.type==VMType::LIST&&e.list==list)?(b?"(...)":"[...]"):e.repr();
        }
        if(b&&list&&list->size()==1) r+=",";
        return r+(b?")":"]");
    }
    case VMType::MAP:{
        std::string r="{"; bool first=true;
        if(map) for(auto&[k,v]:*map){
            if(vm_internal_key(k)) continue;
            if(!first)r+=", ";
            r+=vm_key_value(k).repr()+": "+((v.type==VMType::MAP&&v.map==map)?std::string("{...}"):v.repr());
            first=false;
        }
        return r+"}";
    }
    case VMType::FUNCTION: return "<function "+(code?code->name:"?")+">"; 
    case VMType::CLASS:    return "<class "+class_name+">";
    case VMType::INSTANCE: {
        if(map){
            auto it=map->find("msg");
            if(it!=map->end()&&it->second.type==VMType::STRING)
                return class_name+": "+it->second.s;
        }
        return "<"+class_name+" instance>";
    }
    case VMType::NATIVE:
        if(class_name.rfind("__builtin__:",0)==0) return "<built-in function "+class_name.substr(12)+">";
        return "<native>";
    case VMType::ITERATOR: return "<iterator>";
        case VMType::GENERATOR: return "<generator>";
    default:               return "undefined";
    }
}
inline std::string VMVal::repr() const {
    // Python's repr of a string (quotes and escapes chosen as Python does),
    // matching the interpreter.
    if(type==VMType::STRING) return nypy::str_repr(s);
    return to_string();
}


// ═══════════════════════════════════════════════════════════════════════════
// COMPILER  —  AST  →  VMCode
// ═══════════════════════════════════════════════════════════════════════════
// Names that denote a TYPE rather than a variable, used when compiling `is`.
// Free function because both the Compiler and the VM need it and it has no
// state. A lowercase bare name stays a value comparison; a capitalised one is
// treated as a class name, which is resolved against class_reg_ at runtime.
inline bool isTypeNameToken(const std::string& n) {
    static const std::set<std::string> t = {
        "int","Integer","integer","float","Float","double","Double",
        "str","String","string","bool","Boolean","boolean",
        "list","List","array","Array","map","Map","dict","Dict",
        "tuple","Tuple","set","Set",
        "none","None","function","Function","Object","object","any","Any"
    };
    if(t.count(n)) return true;
    return !n.empty() && n[0]>='A' && n[0]<='Z';
}

class Compiler {
    std::shared_ptr<VMCode>              code_;
    std::vector<std::shared_ptr<VMCode>> code_stack_;
    int comp_counter_ = 0;

    void push_code(const std::string& name, bool is_class=false) {
        auto c=std::make_shared<VMCode>(); c->name=name; c->is_class=is_class;
        code_stack_.push_back(code_); code_=c;
    }
    std::shared_ptr<VMCode> pop_code() {
        auto c=code_; code_=code_stack_.back(); code_stack_.pop_back();
        // If this code is a method inside a class, tag its owner_class
        if(code_->is_class && c->owner_class.empty())
            c->owner_class = code_->name;
        code_->sub_codes.push_back(c); return c;
    }
    VMCode& C() { return *code_; }

    void emit(Op op,int arg=0,int ln=0)    { C().emit(op,arg,ln); }
    void emit_lc(VMVal v,int ln=0)         { emit(Op::LOAD_CONST,  C().add_const(std::move(v)),ln); }
    void emit_ln(const std::string& n,int l=0){ emit(Op::LOAD_NAME,  C().add_name(n),l); }
    void emit_sn(const std::string& n,int l=0){ emit(Op::STORE_NAME, C().add_name(n),l); }
    void emit_dn(const std::string& n,int l=0){ emit(Op::DEFINE_NAME,C().add_name(n),l); }
    int  ln(nython::node::node_ptr nd) { return nd?nd->token().location().row:0; }

    // Integer literal tokens keep their source spelling verbatim
    // ("0xFF", "0o17", "0b1010"), but plain std::stoll(s) - base 10 by
    // default - stops at the first non-decimal digit, so it silently
    // parsed just the leading "0" of every one of these and returned 0,
    // instead of 255/15/10. Matches the interpreter's evalInteger
    // (NythonExecutor.hpp), which already does this prefix check.
    // Exact at any size: a literal past 64 bits is a big int (it used to
    // throw out of std::stoll).
    static VMVal int_literal(const std::string& v){
        return VMVal::make_bigint(nypy::parse_int_literal(v));
    }
    static int64_t parse_int_literal(const std::string& v){
        if(v.size()>2 && v[0]=='0'){
            if(v[1]=='x'||v[1]=='X') return std::stoll(v,nullptr,16);
            if(v[1]=='o'||v[1]=='O') return std::stoll(v.substr(2),nullptr,8);
            if(v[1]=='b'||v[1]=='B') return std::stoll(v.substr(2),nullptr,2);
        }
        return std::stoll(v);
    }

    static constexpr int BREAK_PH=-9991, CONT_PH=-9992;
    // is_for: the loop keeps an iterator on the value stack between iterations
    // (pushed by GET_ITER, popped by FOR_ITER on exhaustion). A `break` jumps
    // past FOR_ITER, so it must pop that iterator itself or it is left behind
    // and the *enclosing* loop's FOR_ITER advances it instead of its own.
    struct LoopCtx { int start; std::vector<int> breaks,conts; bool is_for=false; };
    std::vector<LoopCtx> loops_;

public:
    Compiler() : code_(std::make_shared<VMCode>()) { code_->name="<module>"; }

    std::shared_ptr<VMCode> compile(nython::node::node_ptr root) {
        if(!root) return code_;
        visit(root);
        emit(Op::HALT);
        return code_;
    }

private:
    using NT = nython::node::NodeType;
    using np = nython::node::node_ptr;

    // ─── statement wrapper — pops discarded expression results ─────────────
    void visit_stmt(np nd) {
        if(!nd) return;
        auto nt=nd->type();
        visit(nd);
        // Pop the result if this is a call-as-statement (result unused)
        bool is_expr_stmt = (nt==NT::CALL || nt==NT::TUPLE || nt==NT::LIST);
        if(is_expr_stmt) emit(Op::POP_TOP,0,ln(nd));
    }

    // ─── dispatch ──────────────────────────────────────────────────────────
    void visit(np nd) {
        if(!nd) return;
        int l=ln(nd);
        if(nd->type()==NT::WALRUS) std::cerr<<"[DBG] visit WALRUS node!\n";
        switch(nd->type()) {
        // Literals
        case NT::INTEGER: emit_lc(int_literal(nd->token().value),l); break;
        case NT::FLOAT:   emit_lc(VMVal::make_float(std::stod(nd->token().value)),l); break;
        case NT::STRING:  emit_lc(VMVal::make_str(nd->token().value),l); break;
        case NT::TRUE:    emit_lc(VMVal::make_bool(true),l); break;
        case NT::FALSE:   emit_lc(VMVal::make_bool(false),l); break;
        case NT::NONE:    emit_lc(VMVal::make_none(),l); break;

        // Names
        case NT::VARIABLE: emit_ln(nd->token().value,l); break;
        case NT::SELF:     emit(Op::LOAD_SELF,0,l); break;
        case NT::SUPER:    emit(Op::LOAD_SUPER,0,l); break;

        // Var decl
        case NT::VARIABLE_DECL: {
            auto vd=std::static_pointer_cast<nython::node::VarDeclNode>(nd);
            if(vd->init) visit(vd->init); else emit_lc(VMVal::make_none(),l);
            emit_dn(vd->name,l); break;
        }

        // Assign
        case NT::ASSIGNMENT: {
            auto an=std::static_pointer_cast<nython::node::AssignmentNode>(nd);
            // Special case: slice assignment obj[s:e] = val
            // (parser encodes as CallNode(obj.slice, [s,e]) as target)
            if(an->target && an->target->type()==NT::CALL) {
                auto cn=std::static_pointer_cast<nython::node::CallNode>(an->target);
                if(cn->callee && cn->callee->type()==NT::ATTRIBUTE) {
                    auto attr=std::static_pointer_cast<nython::node::AttributeNode>(cn->callee);
                    if(attr->attr=="slice" && cn->args.size()>=1 && cn->args.size()<=3) {
                        // STORE_SUBSCR pops: idx=TOS, obj=TOS1, val=TOS2
                        // So emit order (bottom→top): val, obj, [start,stop(,step)]
                        // (L[a:] = x has no stop: none).
                        visit(an->value_node);         // push val FIRST (lands at bottom)
                        visit(attr->object);           // push obj
                        for(auto& sa:cn->args) visit(sa);
                        if(cn->args.size()==1) emit_lc(VMVal::make_none(),l);
                        emit(Op::BUILD_LIST,(int)std::max<size_t>(2,cn->args.size()),l);
                        emit(Op::STORE_SUBSCR,0,l);
                        break;
                    }
                }
                // Unknown call target: evaluate and discard
                visit(an->value_node);
                emit(Op::POP_TOP,0,l);
                break;
            }
            // Collect chained targets: a = b = 5 → [a, b], val=5
            {
                std::vector<nython::node::AssignmentNode*> chain;
                auto cur=an.get();
                while(cur->value_node && cur->value_node->type()==NT::ASSIGNMENT){
                    chain.push_back(cur);
                    cur=std::static_pointer_cast<nython::node::AssignmentNode>(cur->value_node).get();
                }
                chain.push_back(cur);  // last in chain
                // Emit the actual value (bottom of chain)
                visit(cur->value_node);
                // Store into each target from first to last, DUP_TOP before all but last
                for(int ci=0;ci<(int)chain.size();ci++){
                    if(ci<(int)chain.size()-1) emit(Op::DUP_TOP,0,l);
                    store(chain[ci]->target,l);
                }
            }
            break;
        }
        case NT::ASSIGNMENT_AUG: {
            auto an=std::static_pointer_cast<nython::node::AugAssignNode>(nd);
            if(an->op=="~="){
                // No natural binary reading of "complement" exists (see the
                // identical comment on the interpreter's evalAugAssignment,
                // NythonExecutor.hpp): `x ~= y` assigns the bitwise
                // complement of y to x, discarding the old x rather than
                // combining with it - doesn't fit the load-target/combine
                // pattern below.
                visit(an->value_node);
                emit(Op::UNARY_BITNOT,0,l);
                store(an->target,l); break;
            }
            // Load current value of target
            load_target(an->target,l);
            // Load new value and apply op
            visit(an->value_node);
            emit(aug_op(an->op),0,l);
            // Store back
            store(an->target,l); break;
        }

        // Attr / subscript
        case NT::ATTRIBUTE: {
            auto a=std::static_pointer_cast<nython::node::AttributeNode>(nd);
            visit(a->object); emit(Op::LOAD_ATTR,C().add_name(a->attr),l); break;
        }
        case NT::SUBSCRIPT: {
            auto s=std::static_pointer_cast<nython::node::SubscriptNode>(nd);
            visit(s->object); visit(s->index); emit(Op::LOAD_SUBSCR,0,l); break;
        }

        // Unary
        case NT::UNARY: {
            auto u=std::static_pointer_cast<nython::node::UnaryNode>(nd);
            std::string op=u->op;
            if(op=="++"||op=="--"){
                // Post-increment/decrement: `x++` evaluates to the OLD
                // value but updates the variable/attribute/subscript to
                // old+-1, matching the interpreter's evalUnary
                // (NythonExecutor.hpp). This used to fall through to the
                // `else` branch below (UNARY_POS, a no-op on the loaded
                // value) - `x++` compiled to reading x and discarding it:
                // no increment, no write-back, at all.
                load_target(u->operand,l);
                emit(Op::DUP_TOP,0,l);
                emit_lc(VMVal::make_int(1),l);
                emit(op=="++"?Op::IADD:Op::ISUB,0,l);
                store(u->operand,l);
                break;
            }
            visit(u->operand);
            if(op=="-"||op=="neg")      emit(Op::UNARY_NEG,0,l);
            else if(op=="not"||op=="!") emit(Op::UNARY_NOT,0,l);
            else if(op=="~")            emit(Op::UNARY_BITNOT,0,l);
            else                        emit(Op::UNARY_POS,0,l);
            break;
        }

        // Binary
        case NT::BINARY: {
            auto b=std::static_pointer_cast<nython::node::BinaryNode>(nd);
            std::string op=b->op;
            if(op=="and"||op=="&&") {
                visit(b->left); int j=C().here();
                emit(Op::JUMP_IF_FALSE_OR_POP,0,l); visit(b->right);
                C().patch(j,C().here()); break;
            }
            if(op=="or"||op=="||") {
                visit(b->left); int j=C().here();
                emit(Op::JUMP_IF_TRUE_OR_POP,0,l); visit(b->right);
                C().patch(j,C().here()); break;
            }
            // `x is int` / `x is MyClass`: the right operand names a TYPE, not
            // a value. Compiling it as an ordinary load would look `int` up as a
            // variable — which since round 52 raises NameError rather than
            // yielding none. A distinct opcode carrying the name as a constant
            // keeps `x is int` and `x is "int"` different things.
            // `instanceof` is a second spelling of `is` (see bin_op() and
            // the interpreter's evalBinary, NythonExecutor.hpp) and needs
            // the same type-name special case - without it, `a instanceof
            // Animal` fell to the generic bin_op() path below, which maps
            // straight to COMPARE_IS (plain value/pointer equality between
            // the instance and the class itself, never true) instead of
            // this opcode's actual type check.
            if((op=="is"||op=="is not"||op=="instanceof") && b->right
               && b->right->type()==NT::VARIABLE){
                const std::string& tn=b->right->token().value;
                if(isTypeNameToken(tn)){
                    visit(b->left);
                    emit_lc(VMVal::make_str(tn),l);
                    emit(op=="is not"?Op::COMPARE_IS_NOT_TYPE:Op::COMPARE_IS_TYPE,0,l);
                    break;
                }
            }
            visit(b->left); visit(b->right); emit(bin_op(op),0,l); break;
        }

        // Block/stmts/script
        case NT::SCRIPT: case NT::BLOCK: case NT::STATEMENTS: case NT::STATEMENT:
            for(auto& ch : nd->statements()) if(ch) visit_stmt(ch); break;

        // Print
        case NT::PRINT: {
            auto pn=std::static_pointer_cast<nython::node::PrintNode>(nd);
            // Stack: the arguments, then sep and end when given. PRINT's arg
            // packs the count with two flags; each value is formatted by the
            // op itself (so a list or an instance prints as itself rather
            // than going through string +).
            int argc=0;
            for(auto& a: pn->args){ if(a){ visit(a); argc++; } }
            int flags=0;
            if(pn->sep){ visit(pn->sep); flags|=1; }
            if(pn->end){ visit(pn->end); flags|=2; }
            emit(Op::PRINT,argc|(flags<<16)|(1<<20),l); break;
        }

        // Return
        case NT::RETURN: {
            auto rn=std::static_pointer_cast<nython::node::ReturnNode>(nd);
            if(rn->expr) visit(rn->expr); else emit_lc(VMVal::make_none(),l);
            emit(Op::RETURN_VALUE,0,l); break;
        }

        // If
        case NT::IF: visit_if(std::static_pointer_cast<nython::node::IfNode>(nd)); break;
        // While
        case NT::WHILE: visit_while(std::static_pointer_cast<nython::node::WhileNode>(nd)); break;
        // For
        case NT::FOR:   visit_for(std::static_pointer_cast<nython::node::ForNode>(nd)); break;
        // Function
        case NT::FUNCTION: visit_func(std::static_pointer_cast<nython::node::FunctionNode>(nd)); break;
        // Lambda:  lambda x, y: expr
        case NT::LAMBDA: {
            auto lm=std::static_pointer_cast<nython::node::LambdaNode>(nd);
            push_code("<lambda>");
            for(auto& p:lm->params){
                std::string pn=p->value(); if(pn=="self") continue;
                C().param_names.push_back(pn); C().add_name(pn);
            }
            if(lm->body){ visit(lm->body); emit(Op::RETURN_VALUE,0,l); }
            else{ emit_lc(VMVal::make_none(),l); emit(Op::RETURN_VALUE,0,l); }
            pop_code();
            emit(Op::MAKE_FUNCTION,(int)C().sub_codes.size()-1,l); break;
        }
        // Tuple
        case NT::TUPLE: {
            auto tn=std::static_pointer_cast<nython::node::TupleNode>(nd);
            for(auto& e:tn->elements) visit(e);
            emit(Op::BUILD_TUPLE,(int)tn->elements.size(),l); break;
        }
        case NT::YIELD: {
            auto yn=std::static_pointer_cast<nython::node::YieldNode>(nd);
            if(yn->expr) visit(yn->expr); else emit(Op::LOAD_CONST,C().add_const(VMVal::make_none()),l);
            emit(Op::YIELD_VALUE,0,l);
            break;
        }
        // yield from iterable: iterate it, yield each item
        case NT::YIELD_FROM: {
            auto yn=std::static_pointer_cast<nython::node::YieldFromNode>(nd);
            visit(yn->expr);
            emit(Op::YIELD_FROM_OP,0,l);
            break;
        }
        // Walrus operator (var n = expr) → eval expr, dup, store, leave on stack
        case NT::WALRUS: {
            auto wn=std::static_pointer_cast<nython::node::WalrusNode>(nd);
            visit(wn->init);
            emit(Op::DUP_TOP,0,l);
            emit_dn(wn->name,l);
            // DEBUG: verify DUP_TOP leaves a value
            std::cerr<<"[DBG] WALRUS compiled: init, DUP_TOP, DEFINE_NAME("<<wn->name<<")\n";
            break;
        }
        // Pass / global / nonlocal
        case NT::PASS: case NT::GLOBAL:
            break;
        // del target  (variable, subscript, attribute)
        case NT::DELETE: {
            auto dn=std::static_pointer_cast<nython::node::DeleteNode>(nd);
            if(!dn->target) break;
            if(dn->target->type()==NT::VARIABLE){
                emit_lc(VMVal::make_none(),l);
                emit_sn(dn->target->token().value,l);
            } else if(dn->target->type()==NT::SUBSCRIPT){
                // del obj[key] — emit: LOAD obj, LOAD key, DELETE_SUBSCR
                auto s=std::static_pointer_cast<nython::node::SubscriptNode>(dn->target);
                visit(s->object); visit(s->index); emit(Op::DELETE_SUBSCR,0,l);
            } else if(dn->target->type()==NT::ATTRIBUTE){
                // del obj.attr — emit: LOAD obj, DELETE_ATTR
                auto a=std::static_pointer_cast<nython::node::AttributeNode>(dn->target);
                visit(a->object); emit(Op::DELETE_ATTR,C().add_name(a->attr),l);
            } else if(dn->target->type()==NT::CALL){
                // del lst[a:b:c] - the parser spells the slice obj.slice(a, b, c)
                auto cn=std::static_pointer_cast<nython::node::CallNode>(dn->target);
                if(cn->callee && cn->callee->type()==NT::ATTRIBUTE){
                    auto attr=std::static_pointer_cast<nython::node::AttributeNode>(cn->callee);
                    if(attr->attr=="slice" && cn->args.size()>=1 && cn->args.size()<=3){
                        visit(attr->object);
                        for(auto& sa:cn->args) visit(sa);
                        if(cn->args.size()==1) emit_lc(VMVal::make_none(),l);
                        emit(Op::BUILD_LIST,(int)std::max<size_t>(2,cn->args.size()),l);
                        emit(Op::DELETE_SUBSCR,0,l);
                    }
                }
                break;
            }
            break;
        }
        // Switch/match
        case NT::WITH: {
            auto wn=std::static_pointer_cast<nython::node::WithNode>(nd);
            int l2=ln(wn);
            // Store ctx manager in a hidden temp var
            static int with_cnt=0;
            std::string ctx_tmp="__with_ctx"+std::to_string(with_cnt++)+"__";
            visit(wn->expr);
            emit_dn(ctx_tmp,l2);
            // Call __enter__, bind result to alias
            emit_ln(ctx_tmp,l2);
            emit_lc(VMVal::make_str("__enter__"),l2);
            emit(Op::CALL_METHOD,0,l2);
            if(!wn->alias.empty()) emit_dn(wn->alias,l2);
            else emit(Op::POP_TOP,0,l2);
            // Body protected by SETUP_EXCEPT
            int exc_entry=C().here(); emit(Op::SETUP_EXCEPT,0,l2);
            if(wn->body) visit_stmt(wn->body);
            emit(Op::END_EXCEPT,0,l2);
            // Normal exit: ctx.__exit__(none,none,none)
            emit_ln(ctx_tmp,l2);
            emit_lc(VMVal::make_str("__exit__"),l2);
            emit_lc(VMVal::make_none(),l2);
            emit_lc(VMVal::make_none(),l2);
            emit_lc(VMVal::make_none(),l2);
            emit(Op::CALL_METHOD,3,l2);
            emit(Op::POP_TOP,0,l2);
            int end_jmp=C().here(); emit(Op::JUMP_FORWARD,0,l2);
            // Exception exit: ctx.__exit__(exc_type,exc_val,tb)
            C().patch(exc_entry,C().here());
            emit_ln(ctx_tmp,l2);
            emit_lc(VMVal::make_str("__exit__"),l2);
            emit_lc(VMVal::make_none(),l2);
            emit_lc(VMVal::make_none(),l2);
            emit_lc(VMVal::make_none(),l2);
            emit(Op::CALL_METHOD,3,l2);
            emit(Op::POP_TOP,0,l2);
            C().patch(end_jmp,C().here());
            break;
        }
        case NT::SWITCH: {
            auto sw=std::static_pointer_cast<nython::node::SwitchNode>(nd);
            visit(sw->subject);
            std::vector<int> end_jumps;
            bool wildcard_handled=false;
            for(auto& c:sw->cases){
                auto cn=std::static_pointer_cast<nython::node::CaseNode>(c);
                // Python-style `case _:` wildcard. The interpreter's
                // evalSwitch (NythonExecutor.hpp) special-cases a case value
                // of exactly "_" as always-match rather than a variable
                // lookup; this compiled it as an ordinary comparison
                // instead (subject == <value of undefined name _>, which
                // reads none and is never equal), so `case _:` never ran
                // on the VM.
                if(cn->value_node && cn->value_node->value()=="_"){
                    emit(Op::POP_TOP,0,l);
                    if(cn->body) visit(cn->body);
                    wildcard_handled=true;
                    break;
                }
                emit(Op::DUP_TOP,0,l);
                visit(cn->value_node);
                emit(Op::COMPARE_EQ,0,l);
                int jf=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
                emit(Op::POP_TOP,0,l);
                if(cn->body) visit(cn->body);
                end_jumps.push_back(C().here()); emit(Op::JUMP_FORWARD,0,l);
                C().patch(jf,C().here());
            }
            if(!wildcard_handled){
                emit(Op::POP_TOP,0,l);
                if(sw->default_case) visit(sw->default_case);
            }
            int end=C().here();
            for(int j:end_jumps) C().patch(j,end);
            break;
        }
        // Class
        case NT::CLASS: visit_class(std::static_pointer_cast<nython::node::ClassNode>(nd)); break;
        // Enum - previously fell to `default: NOP`, silently dropping the
        // whole declaration (the interpreter's evalEnum, NythonExecutor.hpp,
        // already builds a real map of name->value; this compiles the same
        // shape via BUILD_MAP, reusing the NT::MAP pattern just above).
        case NT::ENUM: {
            auto en=std::static_pointer_cast<nython::node::EnumNode>(nd);
            int counter=0;
            for(auto& item:en->items){
                auto ei=std::static_pointer_cast<nython::node::EnumItemNode>(item);
                emit_lc(VMVal::make_str(ei->name),l);
                if(ei->value_node) visit(ei->value_node);
                else emit_lc(VMVal::make_int(counter),l);
                counter++;
            }
            emit(Op::BUILD_MAP,(int)en->items.size(),l);
            emit_dn(en->name,l);
            break;
        }
        // Namespace - previously dropped entirely (default: NOP), including
        // its body, so nothing inside a `namespace ns:` block ever ran on
        // the VM. Compiles the body normally (its statements define names
        // the ordinary way) then collects the namespace's own top-level
        // names into a map bound to its name, mirroring the interpreter's
        // evalNamespace fix (NythonExecutor.hpp) so `ns.thing` resolves.
        // Unlike the interpreter's child-Context version, the body's names
        // are NOT isolated from the enclosing scope here (the VM has no
        // equivalent lightweight child scope to run a statement list in) -
        // `thing` ends up reachable both bare and as `ns.thing`. A closer
        // match would need real block-scoping, which `block:` also lacks
        // (see HANDOFF.md) and is out of scope for this fix.
        case NT::NAMESPACE: {
            auto nn=std::static_pointer_cast<nython::node::NameSpaceNode>(nd);
            std::vector<std::string> member_names;
            if(nn->body) for(auto& stmt:nn->body->statements()){
                std::string mn;
                if(stmt->type()==NT::VARIABLE_DECL) mn=std::static_pointer_cast<nython::node::VarDeclNode>(stmt)->name;
                else if(stmt->type()==NT::FUNCTION) mn=std::static_pointer_cast<nython::node::FunctionNode>(stmt)->name;
                else if(stmt->type()==NT::CLASS) mn=std::static_pointer_cast<nython::node::ClassNode>(stmt)->name;
                if(!mn.empty()) member_names.push_back(mn);
            }
            if(nn->body) for(auto& s:nn->body->statements()) visit(s);
            for(auto& mn:member_names){ emit_lc(VMVal::make_str(mn),l); emit_ln(mn,l); }
            emit(Op::BUILD_MAP,(int)member_names.size(),l);
            emit_dn(nn->name,l);
            break;
        }
        // Interface - bound as a real class (same MAKE_CLASS path as
        // NT::CLASS just above) so `implements MyInterface` - which
        // Parser.cpp's classDecl stores as an extra base, the same list a
        // `class Foo(Bar):` parent occupies - resolves to something real,
        // matching the interpreter's fix (evalInterfaceDecl,
        // NythonExecutor.hpp). Previously dropped entirely (default: NOP),
        // including its body.
        case NT::INTERFACE: {
            auto in_=std::static_pointer_cast<nython::node::InterfaceNode>(nd);
            push_code(in_->name,true);
            code_->is_class=true;
            if(in_->body) for(auto& s:in_->body->statements()) visit(s);
            emit(Op::HALT,0,l);
            pop_code();
            int idx=(int)C().sub_codes.size()-1;
            emit(Op::MAKE_CLASS,idx,l); emit_dn(in_->name,l);
            break;
        }
        // Package - a cosmetic declaration on the interpreter too
        // (PackageNode::eval is a pure no-op, ASTNodes.hpp); NOP is the
        // correct, matching behaviour, not a gap.
        case NT::PACKAGE: break;
        // Call
        case NT::CALL: visit_call(std::static_pointer_cast<nython::node::CallNode>(nd)); break;

        // List literal
        // List comprehension (ComplexNode)
        case NT::COMPLEX: {
            auto cn=std::static_pointer_cast<nython::node::ComplexNode>(nd);
            // items: [0]=expr, [1]=iterable, [2]=filter(or null), 
            //        optionally [3]=var2, [4]=iterable2
            std::string var_name = cn->token().value;
            std::string tmp_name = "__lc" + std::to_string(comp_counter_++);
            // __tmp = []
            emit(Op::BUILD_LIST, 0, l);
            emit(Op::DEFINE_NAME, C().add_name(tmp_name), l);
            // Outer loop: for var_name in items[1]
            visit(cn->items[1]);                   // push iterable
            emit(Op::GET_ITER, 0, l);              // push iterator
            int loop_top = C().here();
            int for_iter_pos = C().here();
            emit(Op::FOR_ITER, 0, l);             // patch exit later
            // Handle tuple unpacking: "a,b" means UNPACK_SEQ 2
            if(var_name.find(',') != std::string::npos) {
                // Split var_name by comma and emit UNPACK_SEQ + STORE_NAME each
                std::vector<std::string> vnames;
                std::string tmp2; for(char ch:var_name){if(ch==','){vnames.push_back(tmp2);tmp2="";}else tmp2+=ch;}
                vnames.push_back(tmp2);
                emit(Op::UNPACK_SEQ, (int)vnames.size(), l);
                for(auto& vn : vnames) emit(Op::STORE_NAME, C().add_name(vn), l);
            } else {
                emit(Op::STORE_NAME, C().add_name(var_name), l);
            }
            // If nested for (items size >= 5)
            if(cn->items.size()>=5 && cn->items[3] && cn->items[4]) {
                std::string var2 = cn->items[3]->token().value;
                visit(cn->items[4]);
                emit(Op::GET_ITER, 0, l);
                int loop2_top = C().here();
                int for_iter2_pos = C().here();
                emit(Op::FOR_ITER, 0, l);
                emit(Op::STORE_NAME, C().add_name(var2), l);
                // Filter
                int filter_jmp = -1;
                if(cn->items[2]) {
                    visit(cn->items[2]);
                    filter_jmp = C().here();
                    emit(Op::JUMP_IF_FALSE, 0, l);
                }
                // __tmp.append(expr)
                emit(Op::LOAD_NAME, C().add_name(tmp_name), l);
                emit(Op::LOAD_ATTR, C().add_name("append"), l);
                visit(cn->items[0]);
                emit(Op::CALL_FUNCTION, 1, l);
                emit(Op::POP_TOP, 0, l);
                if(filter_jmp>=0) C().patch(filter_jmp, C().here());
                emit(Op::JUMP_ABSOLUTE, loop2_top, l);
                C().patch(for_iter2_pos, C().here());
                emit(Op::JUMP_ABSOLUTE, loop_top, l);
            } else {
                // Filter (items[2])
                int filter_jmp = -1;
                if(cn->items.size()>2 && cn->items[2]) {
                    visit(cn->items[2]);
                    filter_jmp = C().here();
                    emit(Op::JUMP_IF_FALSE, 0, l);
                }
                // __tmp.append(expr)  
                emit(Op::LOAD_NAME, C().add_name(tmp_name), l);
                emit(Op::LOAD_ATTR, C().add_name("append"), l);
                visit(cn->items[0]);
                emit(Op::CALL_FUNCTION, 1, l);
                emit(Op::POP_TOP, 0, l);
                if(filter_jmp>=0) C().patch(filter_jmp, C().here());
                emit(Op::JUMP_ABSOLUTE, loop_top, l);
            }
            C().patch(for_iter_pos, C().here());
            // Load result
            emit(Op::LOAD_NAME, C().add_name(tmp_name), l);
            break;
        }

        case NT::LIST: {
            auto ln_=std::static_pointer_cast<nython::node::ListNode>(nd);
            for(auto& e:ln_->elements) visit(e);
            emit(Op::BUILD_LIST,(int)ln_->elements.size(),l); break;
        }
        // Map literal
        case NT::MAP: {
            auto m=std::static_pointer_cast<nython::node::MapNode>(nd);
            for(auto& e:m->entries){
                auto ep=std::static_pointer_cast<nython::node::MapEntryNode>(e);
                visit(ep->key); visit(ep->val);
            }
            emit(Op::BUILD_MAP,(int)m->entries.size(),l); break;
        }

        // Break / Continue
        case NT::BREAK:
            // A break in a `for` must discard the iterator FOR_ITER would have
            // popped on natural exit; otherwise it outlives the loop.
            if(!loops_.empty() && loops_.back().is_for) emit(Op::POP_TOP,0,l);
            emit(Op::JUMP_ABSOLUTE,-9991,l); break;
        case NT::CONTINUE: emit(Op::JUMP_ABSOLUTE,-9992,l); break;

        // Import
        case NT::IMPORT: {
            auto in=std::static_pointer_cast<nython::node::ImportNode>(nd);
            std::string mn=in->module_name;
            if(mn.size()>=2&&(mn[0]=='"'||mn[0]=='\'')) mn=mn.substr(1,mn.size()-2);
            // `import "x" as m` — the alias travels with the module name so the
            // runtime can bind the namespace. The interpreter now does this;
            // without it here the same program would bind an alias on one
            // engine and not the other.
            if(!in->alias.empty())
                mn = mn + "\x01" + in->alias;
            emit(Op::IMPORT_NAME,C().add_name(mn),l); break;
        }


        // Raise
        case NT::RAISE: {
            auto rn=std::static_pointer_cast<nython::node::RaiseNode>(nd);
            if(rn->expr) visit(rn->expr);
            else emit_lc(VMVal::make_str("Exception"),l);
            emit(Op::RAISE_ERROR,0,l); break;
        }
        // Assert
        case NT::ASSERT: {
            auto an=std::static_pointer_cast<nython::node::AssertNode>(nd);
            visit(an->condition);
            int jt=C().here(); emit(Op::JUMP_IF_TRUE,0,l);
            if(an->message) visit(an->message);
            else emit_lc(VMVal::make_str("AssertionError"),l);
            emit(Op::RAISE_ERROR,0,l);
            C().patch(jt,C().here()); break;
        }
        // Try/except — exception table approach
        case NT::TRY: {
            auto tn=std::static_pointer_cast<nython::node::TryNode>(nd);
            ExceptionEntry ee;
            ee.try_start = C().here();
            // Compile try body
            if(tn->body) visit(tn->body);
            ee.try_end = C().here();
            // Jump over the handlers when no exception was raised.
            int jmp_over = C().here(); emit(Op::JUMP_FORWARD,0,l);
            // Compile EVERY except clause as its own handler entry point -
            // previously only the first clause's body was even compiled, so
            // `except TypeError:` after `except ValueError:` was dead code
            // and every exception ran the ValueError handler regardless of
            // its actual type. Which handler to jump to is decided at
            // runtime by match_except_handler(), comparing the raised
            // exception's type against each clause's type_name in order -
            // mirroring the interpreter's evalTry (NythonExecutor.hpp).
            std::vector<int> end_jumps;
            auto compile_clause=[&](const std::string& type_filter, const std::string& bind_var, node_ptr body){
                ExceptionEntry::Clause cl;
                cl.type_name=type_filter; cl.bind_var=bind_var;
                cl.handler=C().here();
                if(!bind_var.empty()) emit_dn(bind_var,l);
                else emit(Op::POP_TOP,0,l);
                if(body) visit(body);
                end_jumps.push_back(C().here()); emit(Op::JUMP_FORWARD,0,l);
                ee.clauses.push_back(std::move(cl));
            };
            for(auto& ec:tn->except_clauses){
                auto en=std::static_pointer_cast<nython::node::ExceptNode>(ec);
                // 'except e:'          -> name="e", alias=""    -> catch-all, bind "e"
                // 'except Err as e:'    -> name="Err", alias="e"  -> type "Err", bind "e"
                // 'except:'            -> name="", alias=""     -> catch-all, no bind
                bool has_type = !en->alias.empty();
                compile_clause(has_type?en->name:std::string(), has_type?en->alias:en->name, en->body);
            }
            if(tn->except_clauses.empty()){
                // try/finally with no except at all: give the dispatch a
                // catch-all landing spot that just discards the exception.
                compile_clause(std::string(),std::string(),nullptr);
            }
            // No-exception path (and "no clause matched") lands here.
            C().patch(jmp_over,C().here());
            ee.else_handler = tn->else_clause ? C().here() : -1;
            if(tn->else_clause) visit(tn->else_clause);
            int end_pos=C().here();
            for(int j:end_jumps) C().patch(j,end_pos);
            ee.end=end_pos;
            C().exc_table.push_back(ee);
            if(tn->finally_clause) visit(tn->finally_clause);
            break;
        }
        // Expression statement (discard result)
        case NT::RANGE: {
            auto rn=std::static_pointer_cast<nython::node::RangeNode>(nd);
            emit_ln("range",l);
            if(rn->start)visit(rn->start); else emit_lc(VMVal::make_int(0),l);
            if(rn->end_node)visit(rn->end_node); else emit_lc(VMVal::make_int(0),l);
            int rargc=2;
            if(rn->step){visit(rn->step);rargc=3;}
            emit(Op::CALL_FUNCTION,rargc,l); break;
        }
        case NT::SLICE: {
            // For subscript slicing: build a list [start,end,step]
            auto sn=std::static_pointer_cast<nython::node::SliceNode>(nd);
            if(sn->step){
                // Stepped slice: emit [start,end,step] with NONE marking an
                // omitted bound, because with a negative step "omitted" means
                // the *far* end, which 0/-1 cannot express. The two-element
                // form below is left exactly as it was so unstepped slices
                // keep their existing behaviour.
                if(sn->start)visit(sn->start); else emit_lc(VMVal::make_none(),l);
                if(sn->end_node)visit(sn->end_node); else emit_lc(VMVal::make_none(),l);
                visit(sn->step);
                emit(Op::BUILD_LIST,3,l); break;
            }
            if(sn->start)visit(sn->start); else emit_lc(VMVal::make_int(0),l);
            if(sn->end_node)visit(sn->end_node); else emit_lc(VMVal::make_int(-1),l);
            emit(Op::BUILD_LIST,2,l); break;
        }
        default: emit(Op::NOP,0,l); break;
        }
    }

    // ─── if ─────────────────────────────────────────────────────────────
    // NB: the branches below deliberately use visit(), not visit_stmt(). Nython
    // has no separate ternary node — `a if c else b` is also an IfNode — so
    // emitting POP_TOP here would discard the ternary's value. (It did: a dict
    // literal containing a ternary whose branch was a call came out with its
    // keys and values swapped.) The consequence is that a bare call as an
    // if-branch still leaves its result on the stack on the VM; fixing that
    // needs the parser to distinguish statement-ifs from ternaries first.
    void visit_if(std::shared_ptr<nython::node::IfNode> nd) {
        int l=ln(nd);
        visit(nd->condition);
        int jf=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
        visit(nd->then_branch);
        std::vector<int> ends; ends.push_back(C().here());
        emit(Op::JUMP_FORWARD,0,l);
        C().patch(jf,C().here());
        for(auto& ei:nd->elseif_branches){
            auto eif=std::static_pointer_cast<nython::node::IfNode>(ei);
            visit(eif->condition);
            int jf2=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
            visit(eif->then_branch);
            ends.push_back(C().here()); emit(Op::JUMP_FORWARD,0,l);
            C().patch(jf2,C().here());
        }
        if(nd->else_branch) visit(nd->else_branch);
        int end=C().here();
        for(int j:ends) C().patch(j,end);
    }

    // ─── while ──────────────────────────────────────────────────────────
    void visit_while(std::shared_ptr<nython::node::WhileNode> nd) {
        int l=ln(nd);
        int start=C().here();
        loops_.push_back({start,{},{},false});
        visit(nd->condition);
        int je=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
        visit_stmt(nd->body);
        emit(Op::JUMP_ABSOLUTE,start,l);
        int end=C().here(); C().patch(je,end);
        patch_loop(start,end);
        loops_.pop_back();
        // while-else: condition failed (natural exit) → falls through to else
        // break → jumps to 'end', then needs to skip else
        if(nd->else_branch){
            visit_stmt(nd->else_branch);
            int else_end=C().here();
            // Re-patch break jumps: JUMP_ABSOLUTE to 'end' → jump to 'else_end'
            for(int i=start;i<end;i++){
                auto& ins=C().instructions[i];
                if(ins.op==Op::JUMP_ABSOLUTE&&ins.arg==end)
                    ins.arg=else_end;
            }
        }
    }

    // ─── for ────────────────────────────────────────────────────────────
    void visit_for(std::shared_ptr<nython::node::ForNode> nd) {
        int l=ln(nd);
        visit(nd->iterable); emit(Op::GET_ITER,0,l);
        int start=C().here();
        // visit_stmt, not visit: the parser yields a BARE expression node as the
        // body when the statement is a single expression (e.g. after a
        // multi-line list literal in the loop header), and only BLOCK bodies
        // reach visit_stmt's POP_TOP. Without it a call-as-body left its return
        // value on the stack every iteration; FOR_ITER reads stack_.back(), so
        // it then read that leftover instead of the iterator and the loop ran
        // exactly once — silently, with no error.
        loops_.push_back({start,{},{},true});
        int fi=C().here(); emit(Op::FOR_ITER,0,l);
        if(!nd->unpack_vars.empty()) {
            // for a, b, c in ...: FOR_ITER pushed [a_val, b_val,...]; unpack by index
            std::string tmp="__for_unpack__";
            emit_dn(tmp,l);
            // Assign first var (nd->var)
            int idx0=C().add_const(VMVal::make_int(0));
            emit_ln(tmp,l); emit(Op::LOAD_CONST,idx0,l); emit(Op::LOAD_SUBSCR,0,l);
            emit_sn(nd->var?nd->var->value():"_",l);
            // Assign rest (nd->unpack_vars)
            for(int ui=0;ui<(int)nd->unpack_vars.size();ui++){
                int ci=C().add_const(VMVal::make_int(ui+1));
                emit_ln(tmp,l); emit(Op::LOAD_CONST,ci,l); emit(Op::LOAD_SUBSCR,0,l);
                emit_sn(nd->unpack_vars[ui]->value(),l);
            }
        } else {
            emit_sn(nd->var?nd->var->value():"_",l);
        }
        visit_stmt(nd->body);
        emit(Op::JUMP_ABSOLUTE,start,l);
        int end=C().here(); C().patch(fi,end);
        patch_loop(start,end);
        loops_.pop_back();
        // for-else:
        // Natural exit (iterator exhausted) → FOR_ITER jumped to 'end' → falls to else block
        // Break → jumps to else_end (skips else)
        if(nd->else_branch){
            // Natural exit: FOR_ITER already jumps to 'end' (= current position = else_start)
            int else_start = end; // else_start == end, already patched by C().patch(fi,end)
            visit_stmt(nd->else_branch);
            int else_end = C().here();
            // Re-patch break jumps: change JUMP_ABSOLUTE to 'end' → jump to 'else_end' (skip else)
            for(int i=start; i<else_start; i++){
                auto& ins=C().instructions[i];
                if(ins.op==Op::JUMP_ABSOLUTE && ins.arg==end)
                    ins.arg=else_end;
            }
        }
    }

    void patch_loop(int start, int end) {
        for(int i=start;i<end;i++){
            auto& ins=C().instructions[i];
            if(ins.op==Op::JUMP_ABSOLUTE){
                if(ins.arg==-9991) ins.arg=end;
                if(ins.arg==-9992) ins.arg=start;
            }
        }
    }

    // ─── function ───────────────────────────────────────────────────────
    void visit_func(std::shared_ptr<nython::node::FunctionNode> fn) {
        int l=ln(fn);
        push_code(fn->name);
        C().is_method=!fn->params.empty()&&fn->params[0]->value()=="self";
        int param_idx=0;
        for(int i=0;i<(int)fn->params.size();i++){
            std::string pn=fn->params[i]->value(); if(pn=="self") continue;
            C().param_names.push_back(pn); C().add_name(pn);
            // Defaults used to be left UNDEFINED here and filled in at runtime by
            // MAKE_FUNCTION. Class methods never go through MAKE_FUNCTION — they
            // are invoked straight out of sub_codes — so every method default was
            // silently dropped and the parameter arrived as none. A constructor
            // like __init__(self, x_or_w, y=0, w=0, h=0) then took the wrong
            // branch of `if w == 0`, building a wrong object with no error.
            // Literal defaults are therefore folded at compile time, which covers
            // the common cases; non-literal defaults still fall back to the
            // MAKE_FUNCTION path for plain functions.
            VMVal dflt{VMType::UNDEFINED};
            if(i<(int)fn->defaults.size()&&fn->defaults[i]){
                auto& dn=fn->defaults[i];
                switch(dn->type()){
                    case NT::INTEGER: dflt=int_literal(dn->token().value); break;
                    case NT::FLOAT:   dflt=VMVal::make_float(std::stod(dn->token().value)); break;
                    case NT::STRING:  dflt=VMVal::make_str(dn->token().value); break;
                    case NT::TRUE:    dflt=VMVal::make_bool(true); break;
                    case NT::FALSE:   dflt=VMVal::make_bool(false); break;
                    case NT::NONE:    dflt=VMVal::make_none(); break;
                    default: break;
                }
            }
            C().param_defaults.push_back(dflt);
            param_idx++;
        }
        // Emit default-filling prologue: for each param with default, if not supplied
        // We use a different approach: emit assignments at top of function body
        for(int i=0;i<(int)fn->params.size();i++){
            std::string pn=fn->params[i]->value(); if(pn=="self") continue;
            if(i<(int)fn->defaults.size()&&fn->defaults[i]){
                // Emit: if param is UNDEFINED/not set, assign default
                // We encode this as: LOAD_NAME pn, JUMP_IF_DEFINED skip, <default>, STORE_NAME pn, skip:
                // Simplest: emit LOAD_NAME, check UNDEFINED, if so set default
                // Use a special CHECK_DEFAULT opcode or just emit conditional at start
                // Actually emit: LOAD_CONST undefined → if LOAD_NAME is NONE?
                // Simplest approach: just emit the default assignment in a prologue
                // using a special "HAS_ARG" check. We'll use LOAD_NAME + COMPARE:
                // Actually SIMPLEST: emit at top of function:
                //   if name == None: name = default_expr
                // But "None" is a valid value. Better: use LOAD_LOCAL_OR_DEFAULT opcode.
                // HACK: emit instructions that check if local is UNDEFINED by trying to load
                // We can't easily check UNDEFINED in current ops. Let's use a different way:
                // Emit at top: LOAD_CONST <default_val>, STORE_DEFAULT pn
                // where STORE_DEFAULT only assigns if pn is not already set.
                // 
                // SIMPLEST CORRECT approach: store default VMVals in VMCode.param_defaults
                // and in exec_code, apply them when args.size() < param_names.size().
                // For this we need to EVALUATE the default at compile time... but defaults
                // can be expressions. Let's just handle literal defaults:
                // For now, emit NO code (handled in exec_code by pre-evaluating defaults)
                // We store the default AST node in VMCode... but VMCode is a runtime struct.
                // 
                // BEST APPROACH: Emit default value as a constant and store in VMCode.
                // Evaluate simple literal defaults to VMVal during compilation:
                // Visit the default AST node to compile it, but we need the VALUE not code.
                // Use a "constant folding" trick: for simple literals.
            }
        }
        if(fn->body) visit(fn->body);
        emit_lc(VMVal::make_none(),l); emit(Op::RETURN_VALUE,0,l);
        // Now store defaults: compile each default expr and store result
        // We can't easily do this at compile time for non-literal defaults.
        // Store default AST nodes → evaluate at MAKE_FUNCTION time (runtime).
        auto& sub=C().sub_codes.back(); // last pushed sub_code
        pop_code();
        int idx=(int)C().sub_codes.size()-1;
        // Compile defaults: emit instructions to evaluate each default, 
        // collect them at MAKE_FUNCTION time using a separate "defaults code"
        // For now: use a simpler approach - emit them into the parent context
        // and have MAKE_FUNCTION pop N defaults from stack.
        int n_defaults=0;
        for(int i=0;i<(int)fn->defaults.size();i++){
            if(fn->defaults[i]){ visit(fn->defaults[i]); n_defaults++; }
        }
        // MAKE_FUNCTION arg = idx | (n_defaults << 16)
        emit(Op::MAKE_FUNCTION, idx|(n_defaults<<16), l);
        emit_dn(fn->name,l);
    }

    // ─── class ──────────────────────────────────────────────────────────
    void visit_class(std::shared_ptr<nython::node::ClassNode> cn) {
        int l=ln(cn);
        push_code(cn->name,true);
        code_->is_class=true;  // mark this sub_code as a class
        if(!cn->bases.empty()){
            auto base=std::static_pointer_cast<nython::node::VariableNode>(cn->bases[0]);
            code_->parent_class=base->token().value;
        }
        if(cn->body) for(auto& s:cn->body->statements()) visit(s);
        // A method defined twice in one class body: the LAST definition wins,
        // as in Python and on the interpreter. Methods are found by scanning
        // sub_codes for the first name match, so the VM used to keep the
        // FIRST one - the same class behaved differently on the two engines.
        // Earlier duplicates are renamed out of reach (they stay in place,
        // since MAKE_FUNCTION refers to sub_codes by index).
        {
            auto& subs=code_->sub_codes;
            for(size_t i=0;i<subs.size();i++){
                if(!subs[i]||subs[i]->is_class) continue;
                for(size_t j=i+1;j<subs.size();j++){
                    if(subs[j]&&!subs[j]->is_class&&subs[j]->name==subs[i]->name){
                        subs[i]->name+="\x01shadowed";
                        break;
                    }
                }
            }
        }
        emit(Op::HALT,0,l);
        pop_code();
        int idx=(int)C().sub_codes.size()-1;
        emit(Op::MAKE_CLASS,idx,l); emit_dn(cn->name,l);
    }

    // ─── call ───────────────────────────────────────────────────────────
    void visit_call(std::shared_ptr<nython::node::CallNode> cn) {
        int l=ln(cn);
        // Separate positional from keyword args (AssignmentNode = keyword arg)
        std::vector<np> pos_args, kw_vals;
        std::vector<std::string> kw_names;
        bool has_star=false;
        for(auto& arg:cn->args){
            // The parser represents `f(x=1)` as a KeywordArgNode, not an
            // AssignmentNode. Matching only ASSIGNMENT meant every keyword
            // argument fell through to the positional branch, where visit()
            // emitted a NOP for it while argc still counted it — so
            // CALL_FUNCTION popped one item too many and took the callee as an
            // argument. Keyword arguments therefore never worked in the VM:
            // f(1, key=2) crashed on an operand-stack underflow.
            if(arg->type()==NT::KEYWORD_ARG){
                auto kn=std::static_pointer_cast<nython::node::KeywordArgNode>(arg);
                kw_names.push_back(kn->name);
                kw_vals.push_back(kn->val);
            } else if(arg->type()==NT::ASSIGNMENT){
                auto an=std::static_pointer_cast<nython::node::AssignmentNode>(arg);
                kw_names.push_back(an->target ? an->target->token().value : std::string());
                kw_vals.push_back(an->value_node);
            } else {
                if(arg->type()==NT::UNARY){
                    auto u=std::static_pointer_cast<nython::node::UnaryNode>(arg);
                    if(u->op=="*") has_star=true;
                }
                pos_args.push_back(arg);
            }
        }
        bool has_kw=!kw_names.empty();
        int argc=(int)pos_args.size();
        // ── *args spread call: fn(*list) ─────────────────────────────────
        if(has_star){
            // Build a combined positional args list:
            // emit [] then for each arg: if *x → LIST_EXTEND, else push x + LIST_APPEND
            if(cn->callee->type()==NT::ATTRIBUTE){
                auto a=std::static_pointer_cast<nython::node::AttributeNode>(cn->callee);
                visit(a->object); emit_lc(VMVal::make_str(a->attr),l);
                emit(Op::BUILD_LIST,0,l); // fresh empty list per call (not a constant!)
                for(auto& arg:pos_args){
                    if(arg->type()==NT::UNARY){
                        auto u=std::static_pointer_cast<nython::node::UnaryNode>(arg);
                        if(u->op=="*"){ visit(u->operand); emit(Op::LIST_EXTEND,0,l); continue; }
                    }
                    visit(arg); emit(Op::LIST_APPEND,0,l);
                }
                emit(Op::CALL_EX,-1,l); // method mode, 1 combined list arg
            } else {
                visit(cn->callee);
                emit(Op::BUILD_LIST,0,l); // fresh empty list per call (not a constant!)
                for(auto& arg:pos_args){
                    if(arg->type()==NT::UNARY){
                        auto u=std::static_pointer_cast<nython::node::UnaryNode>(arg);
                        if(u->op=="*"){ visit(u->operand); emit(Op::LIST_EXTEND,0,l); continue; }
                    }
                    visit(arg); emit(Op::LIST_APPEND,0,l);
                }
                emit(Op::CALL_EX,1,l); // 1 combined list arg
            }
            return;
        }
        if(cn->callee->type()==NT::ATTRIBUTE){
            auto a=std::static_pointer_cast<nython::node::AttributeNode>(cn->callee);
            visit(a->object); emit_lc(VMVal::make_str(a->attr),l);
            for(auto& arg:pos_args) visit(arg);
            if(has_kw){
                for(size_t i=0;i<kw_names.size();i++){
                    emit_lc(VMVal::make_str(kw_names[i]),l); visit(kw_vals[i]);
                }
                emit(Op::BUILD_MAP,(int)kw_names.size(),l);
                // Negative count = method mode, [obj, name, args..., kwargs]
                // on the stack (as CALL_EX does). The positive form took the
                // method NAME for the callee: obj.f(1, b=2) returned none.
                emit(Op::CALL_KW,-(argc+1),l);
            } else emit(Op::CALL_METHOD,argc,l);
        } else {
            visit(cn->callee);
            for(auto& arg:pos_args) visit(arg);
            if(has_kw){
                for(size_t i=0;i<kw_names.size();i++){
                    emit_lc(VMVal::make_str(kw_names[i]),l); visit(kw_vals[i]);
                }
                emit(Op::BUILD_MAP,(int)kw_names.size(),l);
                emit(Op::CALL_KW,argc+1,l);
            } else emit(Op::CALL_FUNCTION,argc,l);
        }
    }

    // ─── load target value (for augmented assignment) ──────────────────────────
    void load_target(np tgt, int l) {
        if(tgt->type()==NT::VARIABLE) {
            emit_ln(tgt->token().value,l);
        } else if(tgt->type()==NT::ATTRIBUTE) {
            auto a=std::static_pointer_cast<nython::node::AttributeNode>(tgt);
            visit(a->object); emit(Op::LOAD_ATTR,C().add_name(a->attr),l);
        } else if(tgt->type()==NT::SUBSCRIPT) {
            auto s=std::static_pointer_cast<nython::node::SubscriptNode>(tgt);
            visit(s->object); visit(s->index); emit(Op::LOAD_SUBSCR,0,l);
        }
    }

    // ─── store target ───────────────────────────────────────────────────
    void store(np tgt, int l) {
        if(tgt->type()==NT::VARIABLE) {
            emit_sn(tgt->token().value,l);
        } else if(tgt->type()==NT::ATTRIBUTE) {
            auto a=std::static_pointer_cast<nython::node::AttributeNode>(tgt);
            visit(a->object); emit(Op::STORE_ATTR,C().add_name(a->attr),l);
        } else if(tgt->type()==NT::SUBSCRIPT) {
            auto s=std::static_pointer_cast<nython::node::SubscriptNode>(tgt);
            visit(s->object); visit(s->index); emit(Op::STORE_SUBSCR,0,l);
        } else if(tgt->type()==NT::CALL) {
            // Should be handled in ASSIGNMENT case above, but fallback: pop
            emit(Op::POP_TOP,0,l);
        }
    }

    // ─── opcode maps ────────────────────────────────────────────────────
    static Op bin_op(const std::string& op) {
        if(op=="+"||op=="concat") return Op::BINARY_ADD;
        if(op=="-")  return Op::BINARY_SUB;
        if(op=="*")  return Op::BINARY_MUL;
        if(op=="/")  return Op::BINARY_DIV;
        if(op=="%")  return Op::BINARY_MOD;
        if(op=="**"||op=="pow") return Op::BINARY_POW;
        if(op=="\\"||op=="//")  return Op::BINARY_FLOOR_DIV;
        if(op=="&")  return Op::BINARY_AND;
        if(op=="|")  return Op::BINARY_OR;
        if(op=="^")  return Op::BINARY_XOR;
        if(op=="<<"||op=="lshift") return Op::BINARY_LSHIFT;
        if(op==">>"||op=="rshift") return Op::BINARY_RSHIFT;
        if(op=="==") return Op::COMPARE_EQ;
        if(op=="!="||op=="<>") return Op::COMPARE_NE;
        if(op=="<")  return Op::COMPARE_LT;
        if(op=="<=") return Op::COMPARE_LE;
        if(op==">")  return Op::COMPARE_GT;
        if(op==">=") return Op::COMPARE_GE;
        if(op=="in") return Op::COMPARE_IN;
        if(op=="not in") return Op::COMPARE_NOT_IN;
        if(op=="is") return Op::COMPARE_IS;
        if(op=="is not") return Op::COMPARE_IS_NOT;
        // `instanceof` is a second spelling of `is` for class-membership
        // checks (`x instanceof MyClass`), matching the interpreter
        // (NythonExecutor.hpp), which folds it into the same "is" branch.
        if(op=="instanceof") return Op::COMPARE_IS;
        if(op=="==="||op=="equals") return Op::COMPARE_SEQ;
        if(op=="!==") return Op::COMPARE_SNE;
        if(op=="xor"||op=="^^") return Op::LOGICAL_XOR;
        return Op::NOP;
    }
    static Op aug_op(const std::string& op) {
        if(op=="+=") return Op::IADD;
        if(op=="-=") return Op::ISUB;
        if(op=="*=") return Op::IMUL;
        if(op=="/=") return Op::BINARY_DIV;
        if(op=="%=") return Op::BINARY_MOD;
        // These fell through to NOP, which the ASSIGNMENT_AUG case treats as
        // "combine target and new value" - with no combining opcode emitted,
        // the target was just silently replaced by the right-hand operand
        // (x=24; x//=5 left x==5, the unmodified operand, instead of 4).
        if(op=="//="||op=="\\=") return Op::BINARY_FLOOR_DIV;
        if(op=="**=") return Op::BINARY_POW;
        if(op=="&=") return Op::BINARY_AND;
        if(op=="|=") return Op::BINARY_OR;
        if(op=="^=") return Op::BINARY_XOR;
        if(op=="<<=") return Op::BINARY_LSHIFT;
        if(op==">>="||op==">>>=") return Op::BINARY_RSHIFT;
        return Op::NOP;
    }
};


// ═══════════════════════════════════════════════════════════════════════════
// CALLFRAME
// ═══════════════════════════════════════════════════════════════════════════

struct GenState {
    std::shared_ptr<VMCode> code;
    size_t ip=0;
    VMMap locals;
    std::optional<VMVal> self_val;
    std::shared_ptr<VMMap> closure;
    bool done=false;
    std::vector<VMVal> saved_stack; // intermediate stack at yield point
    size_t stack_base=0;           // stack level when generator was entered
    // Set by YIELD_VALUE / YIELD_FROM_OP just before run_loop returns the
    // yielded value, read (and cleared) by gen_next: a yield and a return
    // both leave run_loop by an ordinary return now, not a C++ exception.
    bool yielded=false;
};


inline VMVal make_generator_val(std::shared_ptr<VMCode> code,
                            std::vector<VMVal> args,
                            std::optional<VMVal> self,
                            std::shared_ptr<VMMap> closure=nullptr) {
    VMVal g; g.type=VMType::GENERATOR;
    g.gen=std::make_shared<GenState>();
    g.gen->code=code; g.gen->ip=0; g.gen->self_val=self; g.gen->closure=closure;
    int n=(int)code->param_names.size();
    int arg_idx=0;
    for(int i=0;i<n;i++){
        const std::string& pn=code->param_names[i];
        if(pn.size()>=2&&pn[0]=='*'&&pn[1]=='*'){
            // **kwargs: build map from remaining args (simplified)
            g.gen->locals[pn.substr(2)]=args.size()>(size_t)arg_idx?args[arg_idx]:VMVal::make_map();
            arg_idx=(int)args.size();
        } else if(!pn.empty()&&pn[0]=='*'){
            // *args: collect ALL remaining positional args into a list
            std::vector<VMVal> rest(args.begin()+arg_idx, args.end());
            g.gen->locals[pn.substr(1)]=VMVal::make_list(std::move(rest));
            arg_idx=(int)args.size();
        } else if(arg_idx<(int)args.size()){
            g.gen->locals[pn]=args[arg_idx++];
        } else if(!code->param_defaults.empty()&&i<(int)code->param_defaults.size()
                  &&code->param_defaults[i].type!=VMType::UNDEFINED){
            g.gen->locals[pn]=code->param_defaults[i];
        }
    }
    g.gen->done=false;
    return g;
}

struct CallFrame {
    std::shared_ptr<VMCode>                       code;
    int                                           ip = 0;
    VMMap         locals;
    std::optional<VMVal>                          self_val;
    // Shared closure environment (shared with enclosing scope)
    std::shared_ptr<VMMap> closure_env;

    bool has_local(const std::string& n) const {
        if(locals.count(n)) return true;
        if(closure_env && closure_env->count(n)) return true;
        return false;
    }
    VMVal get_local(const std::string& n) const {
        auto it=locals.find(n);
        if(it!=locals.end()) return it->second;
        if(closure_env){ auto it2=closure_env->find(n); if(it2!=closure_env->end()) return it2->second; }
        // Return undefined to signal not found
        VMVal undef; undef.type=VMType::UNDEFINED; return undef;
    }
    VMVal& local(const std::string& n)           { return locals[n]; }
    void   set(const std::string& n, VMVal v)    {
        // If var exists in closure_env (and is NOT a local param), update closure_env
        auto li=locals.find(n);
        if(li!=locals.end()){ li->second=std::move(v); return; }
        if(closure_env){
            auto ci=closure_env->find(n);
            if(ci!=closure_env->end()){ ci->second=std::move(v); return; }
        }
        locals[n]=std::move(v);
    }
    void define(const std::string& n, VMVal v) { locals[n]=std::move(v); }
    std::shared_ptr<GenState>  gen_state;   // non-null when executing a generator
};

struct VMReturn   { VMVal value; };
struct VMYield    { VMVal value; };
enum   class VMResult { SUCCESS, COMPILE_ERROR, RUNTIME_ERROR };

// ═══════════════════════════════════════════════════════════════════════════
// VIRTUAL MACHINE
// ═══════════════════════════════════════════════════════════════════════════
// Threads, locks, channels, futures, async for the VM (src/VMConc.cpp): VM
// natives over the shared runtime in src/NyConc.cpp. It needs the VM's
// per-thread execution state (operand stack, frames), hence the friendship.
class VirtualMachine;
struct VMConc { static void install(VirtualMachine& vm); };
struct VMConcEngine;

class VirtualMachine : public Runnable {
    friend class gc::GarbageCollector;
    friend struct VMConc;
    friend struct VMConcEngine;
    using gc_ptr = std::shared_ptr<GarbageCollector>;

    gc_ptr                                             gc_;
    std::vector<VMVal>                                 stack_;
    // deque, not vector: run_loop() holds `CallFrame& fr = call_stack_.back()`
    // for the duration of an instruction, and several opcodes (CALL_KW, and any
    // path reaching exec_code_bound) push a frame while that reference is live.
    // A vector reallocates on growth, leaving `fr` dangling — which showed up as
    // a segfault on any keyword-argument call, e.g. g(1, key=2) or
    // sorted(xs, key=...). deque::push_back does not invalidate references to
    // existing elements.
    std::deque<CallFrame>                              call_stack_;
    VMMap              globals_;
    std::unordered_map<std::string,std::shared_ptr<VMCode>> class_reg_;
    std::unordered_map<std::string,VMMap> class_vars_;
    VMVal last_exception_obj_;
    bool prelude_loaded_=false;
    std::vector<nython::node::node_ptr> prelude_asts_;
    bool vm_trace_ = getenv("NY_VM_TRACE") != nullptr;
    bool export_to_globals_ = false;   // true while executing an import
    std::string cwd_ = ".";            // working directory for imports
    // ── Threads (round 74, src/VMConc.cpp) ──────────────────────────────────
    // Module-level variables live in the main thread's bottom frame and are
    // found by walking the call stack. A thread has a call stack of its own, so
    // it reaches the main module frame through this pointer, set when the first
    // thread starts. The frame outlives every non-daemon thread: run() joins
    // them before popping it (daemons never get the GIL back after that).
    CallFrame* module_frame_ = nullptr;
    bool in_other_thread() const {
        return module_frame_ && (call_stack_.empty() || &call_stack_.front() != module_frame_);
    }

    // Stack helpers
    void   push(VMVal v)       { stack_.push_back(std::move(v)); }
    // Guarded: popping an empty operand stack was undefined behaviour and
    // crashed the process. A stack imbalance is a compiler/opcode bug, but it
    // should surface as a diagnosable error rather than a segfault.
    VMVal  pop() {
        if(stack_.empty()){
            if(getenv("NY_VM_TRACE")) fprintf(stderr,"[vm] operand stack underflow\n");
            return VMVal::make_none();
        }
        VMVal v=std::move(stack_.back()); stack_.pop_back(); return v;
    }
    VMVal& peek(int off=0) {
        static VMVal s_none = VMVal::make_none();
        if(off < 0 || (size_t)off >= stack_.size()) return s_none;
        return stack_[stack_.size()-1-off];
    }

    // Variable resolution
    // ── Interpreter builtin bridge ──────────────────────────────────────────
    // The VM implements about 64 builtins of its own; the interpreter registers
    // 536. Everything else silently evaluated to none here, so most of the
    // standard library was simply unreachable from a program run with --vm.
    //
    // These hooks are installed from main.cpp, where both VMVal and the
    // interpreter's Value are complete types (VirtualMachine.hpp is included by
    // NythonExecutor.hpp, so this header cannot name Value directly).
public:
    static std::function<bool(const std::string&)>& bridge_exists() {
        static std::function<bool(const std::string&)> f; return f;
    }
    static std::function<VMVal(const std::string&, std::vector<VMVal>&)>& bridge_call() {
        static std::function<VMVal(const std::string&, std::vector<VMVal>&)> f; return f;
    }
    // Every builtin name the interpreter registers (for module namespaces).
    static std::function<std::vector<std::string>()>& bridge_names() {
        static std::function<std::vector<std::string>()> f; return f;
    }

private:
    VMVal load_var(const std::string& n) {
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            auto v=call_stack_[i].get_local(n);
            if(v.type!=VMType::UNDEFINED) return v;
        }
        if(in_other_thread()){                                   // round 74
            auto mv=module_frame_->get_local(n);
            if(mv.type!=VMType::UNDEFINED) return mv;
        }
        auto it=globals_.find(n);
        if(it!=globals_.end()) return it->second;
        // Fall back to an interpreter builtin of this name, wrapped as a native.
        // Only names the interpreter actually registers are wrapped, so an
        // undefined variable still reads as none rather than becoming callable.
        if(bridge_exists() && bridge_exists()(n)){
            std::string nm=n;
            VMVal nv=VMVal::make_native([nm](std::vector<VMVal>& a)->VMVal{
                if(bridge_call()) return bridge_call()(nm,a);
                return VMVal::make_none();
            });
            nv.class_name="__builtin__:"+nm;   // lets time.time() find time's members
            return nv;
        }
        return VMVal::make_none();
    }
    void store_var(const std::string& n, VMVal v) {
        // Walk frames: if found in locals or closure_env, update there
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            auto li=call_stack_[i].locals.find(n);
            if(li!=call_stack_[i].locals.end()){ li->second=std::move(v); return; }
            if(call_stack_[i].closure_env){
                auto ci=call_stack_[i].closure_env->find(n);
                if(ci!=call_stack_[i].closure_env->end()){ ci->second=std::move(v); return; }
            }
        }
        if(in_other_thread() && module_frame_->has_local(n)){    // round 74
            module_frame_->set(n,std::move(v)); return;
        }
        if(!call_stack_.empty()) call_stack_.back().locals[n]=std::move(v);
        else globals_[n]=std::move(v);
    }
    void define_var(const std::string& n, VMVal v) {
        if(export_to_globals_) { globals_[n]=std::move(v); return; }
        if(!call_stack_.empty()) call_stack_.back().set(n,std::move(v));
        else globals_[n]=std::move(v);
    }

public:
    void register_builtin(const std::string& name, NativeFunc fn) {
        globals_[name]=VMVal::make_native(std::move(fn));
    }
    void set_cwd(const std::string& d) { cwd_=d; }
    // Directory of the script being run, with a trailing separator, so imports
    // resolve relative to the file rather than to the working directory.
    void set_script_dir(const std::string& f) {
        size_t cut = f.find_last_of("/\\");
        script_dir_ = (cut==std::string::npos) ? std::string() : f.substr(0,cut+1);
    }
    std::string script_dir_;
    const std::string& get_cwd() const { return cwd_; }

    explicit VirtualMachine(Reporter* r=nullptr)
        : Runnable(r, RunnableType::COMPILER)
        , gc_(std::make_shared<GarbageCollector>(GarbageCollectorConfig{},this))
    { register_all_builtins(); }
    explicit VirtualMachine(Runnable* r)
        : Runnable((Reporter*)r, RunnableType::COMPILER)
        , gc_(std::make_shared<GarbageCollector>(GarbageCollectorConfig{},this))
    { register_all_builtins(); }

    // 171 general-purpose builtins (map, filter, reduce, any, all, next, set,
    // tuple, getattr, exp, log, sin, read_file, mkdir, ...) were only ever
    // registered by register_nytorch_builtins(), which runs on `import nytorch`
    // and nowhere else — so without that import they resolved to none on the VM
    // while working fine on the interpreter. They are registered first so that
    // the 11 names both blocks define keep register_builtins()' versions, which
    // is the behaviour the parity tests were written against.
    void register_all_builtins() {
        register_nytorch_builtins();
        register_builtins();
        register_nt_natives();
        register_pycore();        // after register_builtins: these replace its copies
        tag_type_builtins();      // again: register_pycore replaced the tagged ones
        VMConc::install(*this);   // last: its GIL-aware sleep natives win
    }
    void tag_type_builtins() {
        for(auto& nm_canon : std::vector<std::pair<std::string,std::string>>{
                {"int","int"},{"float","float"},{"bool","bool"},{"str","str"},
                {"string","str"},{"list","list"},{"tuple","tuple"},
                {"dict","map"},{"set","list"}}){
            auto git=globals_.find(nm_canon.first);
            if(git!=globals_.end()&&git->second.type==VMType::NATIVE)
                git->second.class_name=nm_canon.second;
        }
    }

    ~VirtualMachine() override = default;

    // Compile + run an AST
    VMResult run(nython::node::node_ptr ast) {
        try {
            load_prelude();
            Compiler c; auto code=c.compile(ast);
            // The module frame is pushed here rather than by exec_code() so that
            // non-daemon threads, which read module variables through it, are
            // joined before it is popped (round 74).
            size_t base=stack_.size();
            CallFrame fr; fr.code=code; fr.ip=0;
            call_stack_.push_back(std::move(fr));
            struct PopModule {
                VirtualMachine* vm; size_t base;
                ~PopModule(){
                    nyconc::join_nondaemon_at_exit();
                    vm->module_frame_=nullptr;
                    vm->call_stack_.pop_back();
                    if(vm->stack_.size()>base) vm->stack_.resize(base);
                }
            } pop_module{this, base};
            try { run_loop(); } catch(VMReturn&) {}
            return VMResult::SUCCESS;
        } catch(std::exception& e) {
            std::cerr<<"\x1b[31m[VMError] "<<e.what()<<"\x1b[0m\n";
            return VMResult::RUNTIME_ERROR;
        }
    }

    // The Nython prelude (include/NyPrelude.hpp) - the same text the
    // interpreter runs at startup: file objects for open().
    void load_prelude() {
        if(prelude_loaded_) return;
        prelude_loaded_=true;
        try {
            auto source=nython::reader::SourceCode(std::string(nyrt::prelude_source()));
            auto reporter=std::make_shared<nython::exception::Reporter>(source);
            auto lx=std::make_shared<nython::lexer::Lexer>(source);
            lx->tokenize();
            auto pr=std::make_shared<nython::parser::Parser>(reporter.get(),(nython::Runnable*)this,lx.get());
            auto ast=pr->parse();
            if(!ast) return;
            prelude_asts_.push_back(ast);
            Compiler c; auto code=c.compile(ast);
            bool old_exp=export_to_globals_; export_to_globals_=true;
            try{ exec_code(code,{},std::nullopt); } catch(VMReturn&){}
            export_to_globals_=old_exp;
            for(auto& sub:code->sub_codes) if(sub->is_class) class_reg_[sub->name]=sub;
        } catch(std::exception& e){ std::cerr<<"[VM] prelude failed to load: "<<e.what()<<"\n"; }
        // open() as a native: the prelude's `def open` raises from its own
        // frame, and an exception crossing a Nython frame is not yet
        // catchable by typed `except` in the caller on this engine. Opening
        // here raises FileNotFoundError & co. in the CALLER's frame; the
        // object is still the prelude's NythonFile.
        globals_["open"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            std::vector<VMVal> args=a;
            VMVal kw=VMVal::make_none();
            if(!args.empty()&&args.back().type==VMType::MAP&&args.back().map&&args.size()>=1){
                bool all_kw=true;
                for(auto& kv:*args.back().map) if(kv.first!="mode"&&kv.first!="encoding"&&kv.first!="file"&&kv.first!="path") all_kw=false;
                if(all_kw&&!args.back().map->empty()){ kw=args.back(); args.pop_back(); }
            }
            auto kwget=[&](const char* k)->VMVal{
                if(kw.type==VMType::MAP&&kw.map&&kw.map->count(k)) return (*kw.map)[k];
                return VMVal::make_none();
            };
            VMVal path=args.size()>0?args[0]:kwget("file");
            if(path.type==VMType::NONE) path=kwget("path");
            VMVal mode=args.size()>1?args[1]:kwget("mode");
            if(mode.type==VMType::NONE) mode=VMVal::make_str("r");
            std::vector<VMVal> oa={path,mode};
            VMVal opener=load_var("file_open_or_raise");
            VMVal h=vm_call(opener,oa,std::nullopt);
            auto cit=class_reg_.find("NythonFile");
            if(cit==class_reg_.end()) return h;
            VMVal cls=VMVal::make_class(cit->second,"NythonFile");
            std::vector<VMVal> ca={path,mode,h};
            return vm_call(cls,ca,std::nullopt);
        });
    }

    // `import os`: os.getcwd(), os.path.join(), ... over the interpreter's
    // os_* builtins (include/NyRuntime.hpp module_members), plus the
    // constants and a snapshot of os.environ - as on the interpreter.
    void define_os_module(const std::string& as_name) {
        std::vector<std::string> names;
        if(bridge_names()) names=bridge_names()();
        VMVal ns=VMVal::make_map(), path=VMVal::make_map();
        for(auto& m : nyrt::module_members("os",names)){
            if(m.first=="environ") continue;   // a map, below (os.environ["HOME"])
            VMVal fn=load_var(m.second);
            if(m.first.rfind("path.",0)==0) (*path.map)[m.first.substr(5)]=fn;
            else (*ns.map)[m.first]=fn;
        }
        for(const char* c : {"sep","pathsep","linesep","name"}){
            VMVal v=globals_.count(std::string("os_")+c)?globals_[std::string("os_")+c]:VMVal::make_none();
            (*ns.map)[c]=v;
            if(std::string(c)=="sep"||std::string(c)=="pathsep") (*path.map)[c]=v;
        }
        VMVal envf=load_var("os_environ");
        std::vector<VMVal> none_args;
        (*ns.map)["environ"]=envf.type==VMType::NATIVE?envf.native(none_args):VMVal::make_map();
        path.class_name="path";
        (*ns.map)["path"]=path;
        ns.class_name=as_name;
        globals_[as_name]=ns;
    }

    // `import sys`: a namespace with argv (the script path, then the
    // arguments after it), platform, executable and version; argv and
    // platform are also bound bare, as on the interpreter.
    void define_sys_module(const std::string& as_name) {
        std::vector<VMVal> av;
        for(auto& a : nyrt::argv()) av.push_back(VMVal::make_str(a));
        VMVal argv_list=VMVal::make_list(std::move(av));
#if defined(_WIN32)
        std::string plat="win32";
#elif defined(__APPLE__)
        std::string plat="darwin";
#else
        std::string plat="linux";
#endif
        VMVal ns=VMVal::make_map();
        (*ns.map)["argv"]=argv_list;
        (*ns.map)["platform"]=VMVal::make_str(plat);
        (*ns.map)["executable"]=VMVal::make_str(nyrt::executable_path());
        (*ns.map)["version"]=VMVal::make_str(NYTHON_VERSION);
        ns.class_name=as_name;
        globals_[as_name]=ns;
        globals_["argv"]=argv_list;
        globals_["platform"]=VMVal::make_str(plat);
    }

    // Raise a builtin exception of `type` from native code (the builtin
    // bridge uses it for "__exc__:Type:msg" errors from interpreter
    // builtins): the same instance and runtime_error an Op::RAISE of
    // Type(msg) produces, so it takes the VM's normal raise path.
    [[noreturn]] void raise_native_exception(const std::string& type, const std::string& msg) {
        auto attrs=std::make_shared<VMMap>();
        (*attrs)["msg"]=VMVal::make_str(msg);
        (*attrs)["args"]=VMVal::make_list(std::vector<VMVal>{VMVal::make_str(msg)});
        last_exception_obj_=VMVal::make_instance(type.empty()?std::string("Exception"):type, attrs);
        throw std::runtime_error((type.empty()?std::string("Exception"):type)+": "+msg);
    }

    // Compile only
    std::shared_ptr<VMCode> compile_ast(nython::node::node_ptr ast) {
        Compiler c; return c.compile(ast);
    }

    // Disassemble to string
    std::string disassemble(const VMCode& code, int depth=0) const {
        std::ostringstream oss;
        std::string ind(depth*2,' ');
        oss<<ind<<"=== "<<code.name<<" ===\n";
        oss<<ind<<"  Constants:\n";
        for(int i=0;i<(int)code.constants.size();i++)
            oss<<ind<<"    ["<<i<<"] "<<code.constants[i].repr()<<"\n";
        oss<<ind<<"  Names: ";
        for(int i=0;i<(int)code.names.size();i++){if(i)oss<<", ";oss<<i<<":"<<code.names[i];}
        oss<<"\n"<<ind<<"  Instructions:\n";
        for(int i=0;i<(int)code.instructions.size();i++){
            const auto& ins=code.instructions[i];
            oss<<ind<<"    "<<std::setw(4)<<i<<"  "<<std::left<<std::setw(24)<<op_name(ins.op)<<ins.arg;
            if(ins.op==Op::LOAD_CONST&&ins.arg<(int)code.constants.size())
                oss<<"  ("<<code.constants[ins.arg].repr()<<")";
            else if((ins.op==Op::LOAD_NAME||ins.op==Op::STORE_NAME||
                     ins.op==Op::DEFINE_NAME||ins.op==Op::LOAD_ATTR||
                     ins.op==Op::STORE_ATTR||ins.op==Op::IMPORT_NAME)
                     &&ins.arg<(int)code.names.size())
                oss<<"  ("<<code.names[ins.arg]<<")";
            if(ins.line) oss<<"  ; line "<<ins.line;
            oss<<"\n";
        }
        for(auto& sub:code.sub_codes) oss<<"\n"<<disassemble(*sub,depth+1);
        return oss.str();
    }

    template<typename T> T* create() {
        auto cell=gc_->allocate(); T* o=new T(this); cell->value=o; return o;
    }
    template<typename T, typename First, typename... Args>
    T* create(First&& first, Args&&... args) {
        auto cell=gc_->allocate();
        T* o=new T(this, std::forward<First>(first), std::forward<Args>(args)...);
        cell->value=o; return o;
    }

private:
    // ── Execute a VMCode object ──────────────────────────────────────────
    // ── UTF-8 index helpers ─────────────────────────────────────────────────
    // The VM measured strings in bytes throughout, while the interpreter's len()
    // counted characters. Non-ASCII text therefore behaved differently on the
    // two engines, and a slice could cut mid-character and emit invalid UTF-8.
    static inline bool u8_cont(unsigned char c){ return (c & 0xC0) == 0x80; }
    static size_t u8_chars(const std::string& s){
        size_t n=0; for(unsigned char c : s) if(!u8_cont(c)) n++; return n;
    }
    static size_t u8_byte_at(const std::string& s, size_t ci){
        size_t chars=0;
        for(size_t i=0;i<s.size();i++){
            if(!u8_cont((unsigned char)s[i])){ if(chars==ci) return i; chars++; }
        }
        return s.size();
    }
    static size_t u8_char_at(const std::string& s, size_t bi){
        size_t chars=0;
        for(size_t i=0;i<s.size() && i<bi;i++) if(!u8_cont((unsigned char)s[i])) chars++;
        return chars;
    }

    VMVal exec_code_bound(std::shared_ptr<VMCode> code,
                          VMMap locs,
                          std::optional<VMVal> self,
                          std::shared_ptr<VMMap> closure=nullptr) {
        CallFrame fr; fr.code=code; fr.ip=0;
        if(self) fr.self_val=self;
        fr.closure_env=closure;
        fr.locals=std::move(locs);
        call_stack_.push_back(std::move(fr));
        VMVal result=VMVal::make_none();
        try { result=run_loop(); }
        catch(VMReturn& r){ result=r.value; }
        catch(...){ call_stack_.pop_back(); throw; }
        call_stack_.pop_back();
        return result;
    }
    VMVal exec_code(std::shared_ptr<VMCode> code,
                    std::vector<VMVal> args,
                    std::optional<VMVal> self,
                    std::shared_ptr<VMMap> closure=nullptr) {
        size_t _stack_base=stack_.size();
        CallFrame fr; fr.code=code; fr.ip=0;
        if(self) fr.self_val=self;
        // Store closure env in frame (shared reference, not copy)
        fr.closure_env = closure;
        // Parameters go into locals; apply defaults and *args
        int n_params=(int)code->param_names.size();
        int arg_idx=0;
        for(int i=0;i<n_params;i++){
            const std::string& pn=code->param_names[i];
            if(pn.size()>=2&&pn[0]=='*'&&pn[1]=='*'){
                // **kw with no keyword arguments: an empty dict, not none
                fr.define(pn.substr(2), VMVal::make_map());
                continue;
            }
            if(!pn.empty()&&pn[0]=='*'){
                // *args: collect all remaining positional args into a list
                std::string vararg_name=pn.substr(1); // strip *
                std::vector<VMVal> rest(args.begin()+arg_idx,args.end());
                fr.define(vararg_name, VMVal::make_list(std::move(rest)));
                arg_idx=(int)args.size(); // consumed all
            } else if(arg_idx<(int)args.size()){
                fr.define(pn, args[arg_idx++]);
            } else if(!code->param_defaults.empty()&&i<(int)code->param_defaults.size()
                      &&code->param_defaults[i].type!=VMType::UNDEFINED){
                fr.define(pn, code->param_defaults[i]);
            }
        }
        call_stack_.push_back(std::move(fr));
        VMVal result=VMVal::make_none();
        try { result=run_loop(); }
        catch(VMReturn& r){ result=r.value; }
        catch(...){ call_stack_.pop_back(); if(stack_.size()>_stack_base) stack_.resize(_stack_base); throw; }
        call_stack_.pop_back();
        if(stack_.size()>_stack_base) stack_.resize(_stack_base);
        return result;
    }

    // ── Main dispatch loop ───────────────────────────────────────────────
    // Resume a generator; returns {value, done} as VMVal (NONE if done)
    VMVal gen_next(VMVal& gv) {
        if(gv.type!=VMType::GENERATOR||!gv.gen||gv.gen->done) return VMVal::make_none();
        auto& gs=*gv.gen;
        // Restore saved stack (iterators held across yields)
        gs.stack_base = stack_.size();
        for(auto& sv : gs.saved_stack) stack_.push_back(sv);
        gs.saved_stack.clear();
        CallFrame fr; fr.code=gs.code; fr.ip=gs.ip;
        fr.locals=gs.locals;
        fr.self_val=gs.self_val;
        fr.closure_env=gs.closure;
        fr.gen_state=gv.gen;
        call_stack_.push_back(std::move(fr));
        VMVal result=VMVal::make_none();
        try {
            gs.yielded=false;
            VMVal out=run_loop();
            if(gs.yielded){
                gs.yielded=false;
                result=out;          // stack state was saved by the yield
            } else {
                // Returned (or ran off the end) without yielding: done. A
                // `return v` still hands v back, as the VMReturn path did.
                gs.done=true; result=out;
                if(stack_.size() > gs.stack_base) stack_.resize(gs.stack_base);
            }
        } catch(VMYield& y) {
            result=y.value;
            // Stack state was already saved in YIELD_VALUE handler
        } catch(VMReturn& r) {
            gs.done=true; result=r.value;
            if(stack_.size() > gs.stack_base) stack_.resize(gs.stack_base);
        } catch(...) {
            if(!call_stack_.empty()) call_stack_.pop_back();
            gs.done=true;
            if(stack_.size() > gs.stack_base) stack_.resize(gs.stack_base);
            throw;
        }
        if(!call_stack_.empty()) call_stack_.pop_back();
        return result;
    }

    static int cmp_val(const VMVal& a, const VMVal& b) {
        if(a.type==VMType::INT&&b.type==VMType::INT) return a.i<b.i?-1:(a.i>b.i?1:0);
        if((a.type==VMType::INT||a.type==VMType::FLOAT)&&
           (b.type==VMType::INT||b.type==VMType::FLOAT)){
            double da=(a.type==VMType::FLOAT)?a.d:(double)a.i;
            double db=(b.type==VMType::FLOAT)?b.d:(double)b.i;
            return da<db?-1:(da>db?1:0);
        }
        if(a.type==VMType::STRING&&b.type==VMType::STRING)
            return a.s<b.s?-1:(a.s>b.s?1:0);
        return a.to_string()<b.to_string()?-1:(a.to_string()>b.to_string()?1:0);
    }

        VMVal call_dunder(const VMVal& obj, const std::string& dunder, std::vector<VMVal> args) {
        if(obj.type!=VMType::INSTANCE) return VMVal::make_none();
        std::string cls=obj.class_name;
        while(!cls.empty()){
            auto cit=class_reg_.find(cls);
            if(cit==class_reg_.end()) break;
            for(auto& sub:cit->second->sub_codes)
                if(sub->name==dunder&&!sub->is_class){
                    // Generator method (has yield) → return lazy generator
                    if(sub->has_yield())
                        return make_generator_val(sub, args, obj);
                    return exec_code(sub,args,obj);
                }
            cls=cit->second->parent_class;
        }
        return VMVal::make_none();
    }
    bool instance_truthy(VMVal& v) {
        VMVal r = call_dunder(v, "__bool__", {});
        if(r.type != VMType::NONE) return r.is_truthy();
        VMVal lr = call_dunder(v, "__len__", {});
        if(lr.type != VMType::NONE) return lr.i != 0;
        return true; // default: instances are truthy
    }

        VMVal run_loop() {
        // GIL switch points (round 74), as in CPython: entering a frame and
        // every backward jump (JUMP_ABSOLUTE closes each loop). A switch
        // swaps this thread's stacks out and back in; references into them
        // (`fr`) stay valid because deque elements never move.
        nyconc::tick();
        while(true){
            CallFrame& fr=call_stack_.back();
            if(fr.ip>=(int)fr.code->instructions.size()) return VMVal::make_none();
            const Instruction& ins=fr.code->instructions[fr.ip++];
            if(vm_trace_) fprintf(stderr,"[vm] op=%d arg=%d depth=%d\n",(int)ins.op,ins.arg,(int)stack_.size());
            try {
            switch(ins.op){

            case Op::NOP: break;
            case Op::HALT: return VMVal::make_none();

            case Op::LOAD_CONST:  push(fr.code->constants[ins.arg]); break;
            case Op::LOAD_NAME:   push(load_var(fr.code->names[ins.arg])); break;
            case Op::STORE_NAME: {
                if(export_to_globals_&&!call_stack_.empty()&&call_stack_.size()==1)
                    globals_[fr.code->names[ins.arg]]=pop();
                else {
                    VMVal sv=pop();
                    store_var(fr.code->names[ins.arg], sv);
                    // Also sync to shared closure_env so inner functions see update
                    if(fr.closure_env && fr.closure_env->count(fr.code->names[ins.arg]))
                        (*fr.closure_env)[fr.code->names[ins.arg]] = sv;
                }
                break;
            }
            case Op::DEFINE_NAME: {
                VMVal dv=pop();
                define_var(fr.code->names[ins.arg], dv);
                // Sync to shared closure_env if it exists
                if(fr.closure_env)
                    (*fr.closure_env)[fr.code->names[ins.arg]] = dv;
                break;
            }
            case Op::LOAD_SELF:   push(fr.self_val.value_or(VMVal::make_none())); break;

            case Op::LOAD_SUPER: {
                // Push a SUPER_PROXY: find parent of the DEFINING class (owner_class),
                // not self's runtime class (which would break chained super() calls)
                VMVal self_v = fr.self_val.value_or(VMVal::make_none());
                std::string cur_cls = fr.code->owner_class.empty() ? self_v.class_name : fr.code->owner_class;
                std::string parent_cls;
                if(!cur_cls.empty()){
                    auto it=class_reg_.find(cur_cls);
                    if(it!=class_reg_.end()&&it->second&&!it->second->parent_class.empty())
                        parent_cls=it->second->parent_class;
                }
                VMVal proxy;
                proxy.type=VMType::SUPER_PROXY;
                proxy.s=parent_cls.empty()?cur_cls:parent_cls;
                proxy.list=std::make_shared<std::vector<VMVal>>();
                proxy.list->push_back(self_v);
                push(proxy);
                break;
            }

            case Op::LOAD_ATTR: {
                VMVal obj=pop(); push(get_attr(obj,fr.code->names[ins.arg])); break;
            }
            case Op::STORE_ATTR: {
                VMVal obj=pop(); VMVal val=pop();
                set_attr(obj,fr.code->names[ins.arg],std::move(val)); break;
            }
            case Op::LOAD_SUBSCR: {
                VMVal idx=pop(),obj=pop();
                if(obj.type==VMType::INSTANCE){VMVal res=call_dunder(obj,"__getitem__",{idx});if(res.type!=VMType::NONE){push(res);break;}}
                push(get_sub(obj,idx)); break;
            }
            case Op::STORE_SUBSCR:{
                VMVal idx=pop(),obj=pop(),val=pop();
                if(obj.type==VMType::INSTANCE){VMVal res=call_dunder(obj,"__setitem__",{idx,val});if(res.type!=VMType::NONE) break;}
                set_sub(obj,idx,std::move(val)); break;
            }
            case Op::DELETE_SUBSCR: {
                VMVal key=pop(), obj=pop();
                if(obj.type==VMType::INSTANCE&&obj.map){
                    VMVal res=call_dunder(obj,"__delitem__",{key});
                    if(res.type==VMType::NONE) obj.map->erase(key.to_string());
                }
                else if(obj.type==VMType::MAP&&obj.map){
                    if(obj.map->erase(vkey(key))==0) raise_native_exception("KeyError",key.repr());
                }
                else if(obj.type==VMType::LIST&&obj.list){
                    if(obj.b) raise_native_exception("TypeError","'tuple' object doesn't support item deletion");
                    if(key.type==VMType::LIST&&key.list&&!key.b){
                        // del L[a:b:c] (the slice spec, as STORE_SUBSCR takes it)
                        auto& L=*obj.list;
                        int64_t len=(int64_t)L.size(),st,step,n=slice_spec(*key.list,len,st,step);
                        if(n<=0) break;
                        std::vector<bool> gone((size_t)len,false);
                        for(int64_t k=0,i=st;k<n;k++,i+=step) gone[(size_t)i]=true;
                        size_t w=0;
                        for(size_t r=0;r<L.size();r++) if(!gone[r]) L[w++]=std::move(L[r]);
                        L.resize(w);
                        break;
                    }
                    int64_t i=index_of(key,"list"), n=(int64_t)obj.list->size();
                    if(i<0) i+=n;
                    if(i<0||i>=n) raise_native_exception("IndexError","list assignment index out of range");
                    obj.list->erase(obj.list->begin()+i);
                }
                break;
            }
            case Op::DELETE_ATTR: {
                VMVal obj=pop();
                if((obj.type==VMType::MAP||obj.type==VMType::INSTANCE)&&obj.map)
                    obj.map->erase(fr.code->names[ins.arg]);
                break;
            }

            case Op::BUILD_LIST: {
                int n=ins.arg; std::vector<VMVal> items(n);
                for(int i=n-1;i>=0;i--) items[i]=pop();
                push(VMVal::make_list(std::move(items))); break;
            }
            case Op::BUILD_TUPLE: {
                int n=ins.arg; std::vector<VMVal> items(n);
                for(int i=n-1;i>=0;i--) items[i]=pop();
                push(VMVal::make_tuple(std::move(items))); break;
            }
            case Op::BUILD_MAP: {
                int n=ins.arg;
                std::vector<std::pair<VMVal,VMVal>> pairs(n);
                for(int i=n-1;i>=0;i--){pairs[i].second=pop();pairs[i].first=pop();}
                auto m=VMVal::make_map();
                for(auto&[k,v]:pairs) (*m.map)[vkey(k)]=std::move(v);
                push(std::move(m)); break;
            }

            case Op::DUP_TOP:  { VMVal v=peek(); push(v); break; }
            case Op::POP_TOP:  pop(); break;
            case Op::ROT_TWO:  { VMVal a=pop(),b=pop(); push(a); push(b); break; }
            case Op::ROT_THREE:{ VMVal a=pop(),b=pop(),c=pop(); push(a); push(c); push(b); break; }

            // Arithmetic
            case Op::BINARY_ADD: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__add__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                if(r.type==VMType::INSTANCE&&lv.type==VMType::STRING){
                    VMVal sv=call_dunder(r,"__str__",{});
                    r=sv.type!=VMType::NONE?sv:VMVal::make_str(r.to_string());
                }
                if(lv.type==VMType::INT&&r.type==VMType::INT&&lv.s.empty()&&r.s.empty()){
                    int64_t res; if(!nypy::add_ovf(lv.i,r.i,res)){ push(VMVal::make_int(res)); break; }
                }
                push(binop(nypy::A_ADD,lv,r)); break; }
            case Op::BINARY_SUB: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__sub__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(binop(nypy::A_SUB,lv,r)); break; }
            case Op::BINARY_MUL: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__mul__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                if(r.type==VMType::INSTANCE){VMVal res=call_dunder(r,"__rmul__",{lv});if(res.type!=VMType::NONE){push(res);break;}}
                push(binop(nypy::A_MUL,lv,r)); break; }
            case Op::BINARY_DIV: case Op::BINARY_MOD: case Op::BINARY_POW: case Op::BINARY_FLOOR_DIV:
            case Op::BINARY_AND: case Op::BINARY_OR: case Op::BINARY_XOR: case Op::BINARY_LSHIFT: case Op::BINARY_RSHIFT: {
                VMVal r=pop(),l=pop();
                int aop; const char* dunder;
                switch(ins.op){
                    case Op::BINARY_DIV: aop=nypy::A_DIV; dunder="__truediv__"; break;
                    case Op::BINARY_MOD: aop=nypy::A_MOD; dunder="__mod__"; break;
                    case Op::BINARY_POW: aop=nypy::A_POW; dunder="__pow__"; break;
                    case Op::BINARY_FLOOR_DIV: aop=nypy::A_FLOORDIV; dunder="__floordiv__"; break;
                    case Op::BINARY_AND: aop=nypy::A_AND; dunder="__and__"; break;
                    case Op::BINARY_OR: aop=nypy::A_OR; dunder="__or__"; break;
                    case Op::BINARY_XOR: aop=nypy::A_XOR; dunder="__xor__"; break;
                    case Op::BINARY_LSHIFT: aop=nypy::A_LSHIFT; dunder="__lshift__"; break;
                    default: aop=nypy::A_RSHIFT; dunder="__rshift__"; break;
                }
                if(l.type==VMType::INSTANCE){
                    VMVal res=call_dunder(l,dunder,{r});
                    if(res.type==VMType::NONE&&aop==nypy::A_DIV) res=call_dunder(l,"__div__",{r});
                    if(res.type!=VMType::NONE){push(res);break;}
                }
                push(binop(aop,l,r)); break; }
            // Compares
            case Op::COMPARE_EQ: {
                VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__eq__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(VMVal::make_bool(lv==r)); break;
            }
            case Op::COMPARE_NE: {
                VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__ne__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(VMVal::make_bool(lv!=r)); break;
            }
            case Op::COMPARE_SEQ: {
                // Strict equality: same type AND same value, no int/float
                // coercion (unlike ==) - matches the interpreter's "===".
                VMVal r=pop(),lv=pop();
                push(VMVal::make_bool(lv.type==r.type && lv==r)); break;
            }
            case Op::COMPARE_SNE: {
                VMVal r=pop(),lv=pop();
                push(VMVal::make_bool(!(lv.type==r.type && lv==r))); break;
            }
            case Op::LOGICAL_XOR: {
                // Truthiness xor - true when exactly one side is truthy,
                // matching the interpreter's "xor"/"^^" (distinct from the
                // bitwise `^`, which is BINARY_XOR).
                VMVal r=pop(),lv=pop();
                push(VMVal::make_bool(lv.is_truthy()!=r.is_truthy())); break;
            }
            case Op::COMPARE_LT: {
                VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__lt__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(VMVal::make_bool(lv<r)); break;
            }
            case Op::COMPARE_LE: {
                VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__le__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(VMVal::make_bool(lv<=r)); break;
            }
            case Op::COMPARE_GT: {
                VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__gt__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(VMVal::make_bool(lv>r)); break;
            }
            case Op::COMPARE_GE: {
                VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE){VMVal res=call_dunder(lv,"__ge__",{r});if(res.type!=VMType::NONE){push(res);break;}}
                push(VMVal::make_bool(lv>=r)); break;
            }
            case Op::COMPARE_IN:       { VMVal c=pop(),it=pop(); push(VMVal::make_bool(op_in(it,c))); break; }
            case Op::COMPARE_NOT_IN:   { VMVal c=pop(),it=pop(); push(VMVal::make_bool(!op_in(it,c))); break; }
            case Op::COMPARE_IS:       { VMVal r=pop(),l=pop(); push(VMVal::make_bool(op_is(l,r))); break; }
            case Op::COMPARE_IS_NOT:   { VMVal r=pop(),l=pop(); push(VMVal::make_bool(!op_is(l,r))); break; }
            case Op::COMPARE_IS_TYPE:  { VMVal t=pop(),v=pop(); push(VMVal::make_bool(value_is_type(v,t.s))); break; }
            case Op::COMPARE_IS_NOT_TYPE:{ VMVal t=pop(),v=pop(); push(VMVal::make_bool(!value_is_type(v,t.s))); break; }
            // Unary
            case Op::UNARY_NEG: {
                VMVal v=pop();
                nypy::NumV nv;
                if(v.to_numv(nv)) push(VMVal::from_numv(nypy::num_neg(nv)));
                else if(v.type==VMType::INSTANCE){
                    VMVal r=call_dunder(v,"__neg__",{});
                    push(r.type!=VMType::NONE?r:VMVal::make_none());
                }
                else push(VMVal::make_none()); break;
            }
            case Op::UNARY_NOT:    push(VMVal::make_bool(!pop().is_truthy())); break;
            case Op::UNARY_BITNOT: { VMVal v=pop(); nypy::NumV nv;
                if(v.to_numv(nv)){ push(nycall([&]{ return VMVal::from_numv(nypy::num_invert(nv)); })); break; }
                if(v.type==VMType::INSTANCE){ VMVal r=call_dunder(v,"__invert__",{}); push(r); break; }
                push(VMVal::make_none()); break; }
            case Op::UNARY_POS:
                if(!stack_.empty()&&stack_.back().type==VMType::BOOL) stack_.back()=VMVal::make_int(stack_.back().b?1:0);
                break;

            // Jumps
            case Op::JUMP_FORWARD:         fr.ip=ins.arg; break;
            case Op::JUMP_ABSOLUTE:        nyconc::tick(); fr.ip=ins.arg; break;
            case Op::JUMP_IF_FALSE: {
                VMVal v=pop();
                bool t = (v.type==VMType::INSTANCE) ? instance_truthy(v) : v.is_truthy();
                if(!t) fr.ip=ins.arg; break;
            }
            case Op::JUMP_IF_TRUE: {
                VMVal v=pop();
                bool t = (v.type==VMType::INSTANCE) ? instance_truthy(v) : v.is_truthy();
                if(t) fr.ip=ins.arg; break;
            }
            case Op::JUMP_IF_FALSE_OR_POP: { if(!peek().is_truthy()) fr.ip=ins.arg; else pop(); break; }
            case Op::JUMP_IF_TRUE_OR_POP:  { if(peek().is_truthy())  fr.ip=ins.arg; else pop(); break; }

            // Make function/class
            case Op::MAKE_FUNCTION: {
                int fn_idx = ins.arg & 0xFFFF;
                int n_defs = (ins.arg >> 16) & 0xFF;
                // Pop defaults from stack (pushed in order, last default on top)
                std::vector<VMVal> defs(n_defs);
                for(int i=n_defs-1;i>=0;i--) defs[i]=pop();
                auto fn_val = VMVal::make_func(fr.code->sub_codes[fn_idx]);
                // Store defaults into the function's sub_code
                if(n_defs>0 && fn_val.code){
                    int n_params=(int)fn_val.code->param_names.size();
                    fn_val.code->param_defaults.resize(n_params, VMVal{VMType::UNDEFINED});
                    // Defaults align to the END of param list
                    for(int i=0;i<n_defs&&i<n_params;i++)
                        fn_val.code->param_defaults[n_params-n_defs+i]=defs[i];
                }
                // Capture enclosing locals as closure environment ONLY when inside a function
                bool in_function = (fr.code->name != "<module>" && !fr.code->is_class);
                if(in_function){
                    // Create shared closure_env on first inner function in this frame
                    // so ALL inner functions share the SAME cell for mutable variables
                    if(!fr.closure_env){
                        fr.closure_env = std::make_shared<VMMap>(fr.locals);
                    } else {
                        // Sync any new locals into the shared closure_env
                        for(auto& kv : fr.locals)
                            if(!fr.closure_env->count(kv.first))
                                (*fr.closure_env)[kv.first] = kv.second;
                    }
                    fn_val.closure_env = fr.closure_env;
                }
                if(!fn_val.closure_env && fr.closure_env && !fr.closure_env->empty()){
                    fn_val.closure_env = fr.closure_env;
                }
                push(std::move(fn_val)); break;
            }
            case Op::MAKE_CLASS: {
                auto sub=fr.code->sub_codes[ins.arg];
                // Statically scan class body to collect class-level variable initializations
                // (LOAD_CONST followed by DEFINE_NAME = class variable)
                {
                    VMMap cvars;
                    const auto& insts = sub->instructions;
                    for(size_t ci=0;ci+1<insts.size();ci++){
                        const auto& prev_ins = insts[ci];
                        const auto& cur_ins  = insts[ci+1];
                        if(cur_ins.op==Op::DEFINE_NAME&&
                           prev_ins.op==Op::LOAD_CONST){
                            std::string vname=sub->names.size()>(size_t)cur_ins.arg?
                                              sub->names[cur_ins.arg]:"";
                            if(!vname.empty()){
                                VMVal val=VMVal::make_none();
                                if(sub->constants.size()>(size_t)prev_ins.arg)
                                    val=sub->constants[prev_ins.arg];
                                cvars[vname]=val;
                            }
                        }
                        // Nested class: MAKE_CLASS followed by DEFINE_NAME
                        if(cur_ins.op==Op::DEFINE_NAME&&prev_ins.op==Op::MAKE_CLASS){
                            std::string vname=sub->names.size()>(size_t)cur_ins.arg?
                                              sub->names[cur_ins.arg]:"";
                            if(!vname.empty()&&prev_ins.arg<(int)sub->sub_codes.size()){
                                auto nsub=sub->sub_codes[prev_ins.arg];
                                VMVal cv=VMVal::make_class(nsub,nsub->name);
                                cvars[vname]=cv;
                                class_reg_[nsub->name]=nsub;
                            }
                        }
                    }
                    if(!cvars.empty()) class_vars_[sub->name]=std::move(cvars);
                }
                push(VMVal::make_class(sub,sub->name));
                class_reg_[sub->name]=sub; break;
            }

            // Calls
            case Op::CALL_KW: {
                bool method_mode=ins.arg<0;
                int total=method_mode?-ins.arg:ins.arg;
                std::vector<VMVal> all_args(total);
                for(int i=total-1;i>=0;i--) all_args[i]=pop();
                VMVal kwargs_map=all_args.back(); all_args.pop_back();
                if(method_mode){
                    VMVal mname=pop(); VMVal obj=pop();
                    std::shared_ptr<VMCode> mcode; std::optional<VMVal> mself; std::shared_ptr<VMMap> menv;
                    if(resolve_user_method(obj,mname.s,all_args,mcode,mself,menv)){
                        push(exec_code_bound(mcode,bind_kw_locals(mcode,all_args,kwargs_map),mself,menv));
                    } else {
                        if(kwargs_map.type==VMType::MAP){ kwargs_map.class_name="__kwargs__"; all_args.push_back(kwargs_map); }
                        push(vm_call_method(obj,mname.s,all_args));
                    }
                    break;
                }
                VMVal callee=pop();
                if(callee.type==VMType::FUNCTION&&callee.code){
                    push(exec_code_bound(callee.code,bind_kw_locals(callee.code,all_args,kwargs_map),std::nullopt,callee.closure_env));
                } else {
                    // Native: append kwargs_map as last arg so natives can check by name
                    // (marked, so a positional dict argument is not taken for it).
                    if(kwargs_map.type==VMType::MAP){ kwargs_map.class_name="__kwargs__"; all_args.push_back(kwargs_map); }
                    std::optional<VMVal> no_self=std::nullopt;
                    push(vm_call(callee,all_args,no_self));
                }
                break;
            }
            case Op::LIST_EXTEND: {
                // TOS = iterable to extend with; TOS1 = list to extend
                VMVal ext=pop(); VMVal& lst=stack_.back();
                if(lst.type==VMType::LIST&&lst.list){
                    if(ext.type==VMType::LIST&&ext.list)
                        for(auto& v:*ext.list) lst.list->push_back(v);
                }
                break;
            }
            case Op::LIST_APPEND: {
                // TOS = item to append; TOS1 = list
                VMVal item=pop(); VMVal& lst=stack_.back();
                if(lst.type==VMType::LIST&&lst.list) lst.list->push_back(item);
                break;
            }
            case Op::CALL_EX: {
                // CALL_EX: stack has [callee, arg0, ..., argN-1, star_list]
                // ins.arg = n_args_pushed (includes star_list as last arg if positive)
                // negative ins.arg = method call mode: [obj, attr_str, ..., star_list]
                bool method_mode = ins.arg < 0;
                // Pop all stack items: the last one is the star_list
                // Determine how many items were pushed (excluding callee/obj+attr)
                // We don't know exactly how many non-star args were pushed — 
                // so we collect everything and the last item is the star list:
                // In our emit, we push: callee, then for each arg either visit(arg) 
                // or visit(u->operand) for *arg. Last arg is always the spread list.
                // ins.arg for non-method = n_pos_args (counting star as 1 item)
                // We need to pop n_pos_args items + the callee.
                int n_pushed = method_mode ? (-ins.arg) : ins.arg;
                std::vector<VMVal> raw(n_pushed);
                for(int i=n_pushed-1;i>=0;i--) raw[i]=pop();
                // The last element of raw is the star-list; spread it
                VMVal star_arg = raw.back(); raw.pop_back();
                std::vector<VMVal> args = std::move(raw);
                if(star_arg.type==VMType::LIST&&star_arg.list)
                    for(auto& v:*star_arg.list) args.push_back(v);
                else args.push_back(star_arg); // not a list, just append
                if(method_mode){
                    VMVal mname=pop(); VMVal obj=pop();
                    push(vm_call_method(obj,mname.s,args));
                } else {
                    VMVal callee=pop();
                    push(vm_call(callee,args,std::nullopt));
                }
                break;
            }
            case Op::CALL_FUNCTION: {
                int argc=ins.arg;
                std::vector<VMVal> args(argc);
                for(int i=argc-1;i>=0;i--) args[i]=pop();
                VMVal callee=pop();
                // Calling something that does not exist returned none and
                // carried on, exactly as the interpreter used to. The
                // interpreter now raises NameError, so without this the SAME
                // program errors on one engine and silently misbehaves on the
                // other — a divergence introduced by fixing only one side.
                //
                // The callee value no longer carries its name, but the
                // preceding LOAD_NAME does: recover it from the instruction
                // before this one so the message can name the identifier.
                if(callee.type==VMType::NONE||callee.type==VMType::UNDEFINED){
                    std::string called = calleeNameBefore(fr, fr.ip - 1);
                    if(!called.empty() && !globals_.count(called))
                        throw std::string("__exc__:NameError:'" + called
                            + "' is not defined at line " + std::to_string(ins.line));
                }
                push(vm_call(callee,args,std::nullopt)); break;
            }
            case Op::CALL_METHOD: {
                int argc=ins.arg;
                std::vector<VMVal> args(argc);
                for(int i=argc-1;i>=0;i--) args[i]=pop();
                VMVal mname=pop(); VMVal obj=pop();
                push(vm_call_method(obj,mname.s,args)); break;
            }
            // A return used to throw VMReturn, caught (and rethrown once) on the
            // way out: two C++ unwinds per call, ~90% of a function call's cost
            // (a 30k-call loop spent 14 of 15 billion instructions unwinding).
            // Every run_loop invocation runs exactly one frame - exec_code,
            // exec_code_bound and gen_next each push a frame and call run_loop
            // - so returning from run_loop returns from that frame.
            case Op::RETURN_VALUE: return pop();
            case Op::YIELD_VALUE: {
                VMVal yv=pop();
                auto& cfr=call_stack_.back();
                if(cfr.gen_state){
                    cfr.gen_state->ip=cfr.ip;   // ip points past YIELD_VALUE
                    cfr.gen_state->locals=cfr.locals;
                    // Save stack slice above stack_base (holds loop iterators etc.)
                    size_t base=cfr.gen_state->stack_base;
                    cfr.gen_state->saved_stack.clear();
                    if(stack_.size() > base){
                        cfr.gen_state->saved_stack.assign(stack_.begin()+base, stack_.end());
                        stack_.resize(base);
                    }
                    cfr.gen_state->yielded=true;
                    return yv;
                }
                throw VMYield{yv};
            }

            // yield from: get iterator from TOS, yield each item in turn
            case Op::YIELD_FROM_OP: {
                VMVal src=pop();
                // Convert to iterator
                VMVal it_val;
                if(src.type==VMType::GENERATOR||src.type==VMType::ITERATOR){it_val=src;}
                else if(src.type==VMType::LIST&&src.list){
                    std::vector<VMVal> copy=*src.list; it_val=VMVal::make_iter(std::move(copy));
                } else if(src.type==VMType::INSTANCE){
                    VMVal ir=call_dunder(src,"__iter__",{});
                    it_val=(ir.type!=VMType::NONE?ir:src);
                } else {it_val=src;}
                // Yield each item one by one
                // We re-use the stack save mechanism: save it_val above stack_base, re-enter YIELD_FROM_OP
                // by decrementing ip. But simpler: collect all & yield via FOR_ITER pattern.
                // For correctness: just iterate fully and yield each item inline.
                while(true){
                    VMVal item;
                    bool got=false;
                    if(it_val.type==VMType::GENERATOR){
                        if(!it_val.gen||it_val.gen->done) break;
                        item=gen_next(it_val);
                        if(it_val.gen&&it_val.gen->done) break;
                        got=true;
                    } else if(it_val.type==VMType::ITERATOR){
                        if(!it_val.iter||it_val.iter->first>=(int)it_val.iter->second.size()) break;
                        item=it_val.iter->second[it_val.iter->first++];
                        got=true;
                    } else break;
                    if(!got) break;
                    // Yield item: save generator state with it_val on saved_stack
                    auto& cfr=call_stack_.back();
                    if(cfr.gen_state){
                        cfr.gen_state->ip=cfr.ip-1; // re-execute YIELD_FROM_OP on resume
                        cfr.gen_state->locals=cfr.locals;
                        size_t base=cfr.gen_state->stack_base;
                        cfr.gen_state->saved_stack.clear();
                        // Save it_val (with updated iterator position) so resume can continue
                        push(it_val);
                        if(stack_.size()>base){
                            cfr.gen_state->saved_stack.assign(stack_.begin()+base,stack_.end());
                            stack_.resize(base);
                        }
                        cfr.gen_state->yielded=true;
                        return item;
                    }
                    // Not in a generator context (shouldn't happen) - just push
                }
                break;
            }

            // Iteration
            case Op::GET_ITER: {
                VMVal it=pop();
                if(it.type==VMType::GENERATOR){push(it);break;}
                if(it.type==VMType::ITERATOR){push(it);break;}
                if(it.type==VMType::INSTANCE){
                    // Call __iter__ if defined, else push as-is for __next__ protocol
                    VMVal iter_res=call_dunder(it,"__iter__",{});
                    push(iter_res.type!=VMType::NONE?iter_res:it); break;
                }
                if(it.type==VMType::LIST&&it.list){
                    std::vector<VMVal> copy=*it.list; push(VMVal::make_iter(std::move(copy))); break;
                }
                if((it.type==VMType::MAP&&it.map)||it.type==VMType::STRING){
                    // a dict's (typed) keys; a string's characters
                    push(make_iter(it)); break;
                }
                // Fallback: use the old make_iter(VMVal&) helper
                push(make_iter(it)); break;
            }
            case Op::FOR_ITER: {
                // NOTE: use index not reference — gen_next/call_dunder may reallocate stack_
                int it_idx = (int)stack_.size()-1;
                if(it_idx < 0){ fr.ip=ins.arg; break; }
                VMType it_type = stack_[it_idx].type;
                if(it_type==VMType::INSTANCE){
                    VMVal it_copy = stack_[it_idx]; // copy since stack may reallocate
                    VMVal nv;
                    bool stop_iter=false;
                    try { nv=call_dunder(it_copy,"__next__",{}); }
                    catch(std::runtime_error&){ stop_iter=true; }
                    // Sync back in case gen_next moved it
                    if(stop_iter||nv.type==VMType::NONE){ pop(); fr.ip=ins.arg; break; }
                    push(nv); break;
                }
                if(it_type==VMType::GENERATOR){
                    if(!stack_[it_idx].gen||stack_[it_idx].gen->done){ pop(); fr.ip=ins.arg; break; }
                    VMVal yv=gen_next(stack_[it_idx]); // pass by ref through index
                    if(!stack_[it_idx].gen||stack_[it_idx].gen->done){ pop(); fr.ip=ins.arg; break; }
                    push(yv); break;
                }
                if(it_type==VMType::ITERATOR&&stack_[it_idx].iter){
                    auto&[cur,items]=*stack_[it_idx].iter;
                    if(cur<(int)items.size()) push(items[cur++]);
                    else { pop(); fr.ip=ins.arg; }
                } else { pop(); fr.ip=ins.arg; }
                break;
            }
            case Op::UNPACK_SEQ: {
                VMVal seq=pop(); int n=ins.arg;
                std::vector<VMVal> items;
                if(seq.type==VMType::LIST&&seq.list) items=*seq.list;
                else if(seq.type==VMType::STRING||seq.type==VMType::MAP||seq.type==VMType::ITERATOR||seq.type==VMType::GENERATOR)
                    items=iter_items(seq);   // by character / key / item
                while((int)items.size()<n) items.push_back(VMVal::make_none());
                for(int i=n-1;i>=0;i--) push(items[i]); break;
            }

            case Op::PRINT: {
                auto str_of=[&](const VMVal& v)->std::string{
                    if(v.type!=VMType::INSTANCE) return v.to_string();
                    for(auto dname : {"__str__","__repr__"}){
                        std::string cls=v.class_name;
                        while(!cls.empty()){
                            auto cit=class_reg_.find(cls);
                            if(cit==class_reg_.end()) break;
                            for(auto& sub:cit->second->sub_codes)
                                if(sub->name==dname&&!sub->is_class){
                                    std::vector<VMVal> na; return exec_code(sub,na,v).to_string();
                                }
                            cls=cit->second->parent_class;
                        }
                    }
                    return v.to_string();
                };
                // Old single-value encoding (arg 0) or the packed call form.
                int argc=1, flags=0;
                if(ins.arg&(1<<20)){ argc=ins.arg&0xFFFF; flags=(ins.arg>>16)&3; }
                std::string sep=" ", end="\n";
                if(flags&2){ VMVal e=pop(); if(e.type!=VMType::NONE) end=str_of(e); }
                if(flags&1){ VMVal s=pop(); if(s.type!=VMType::NONE) sep=str_of(s); }
                std::vector<VMVal> vals(argc);
                for(int i=argc-1;i>=0;--i) vals[i]=pop();
                std::string out;
                for(int i=0;i<argc;++i){ if(i) out+=sep; out+=str_of(vals[i]); }
                std::cout<<out<<end;
                if(end!="\n") std::cout.flush();
                break;
            }
            case Op::IMPORT_NAME: vm_import(fr.code->names[ins.arg]); break;

            // Exception handling
            case Op::RAISE: {
                VMVal ev=pop();
                std::string msg;
                if(ev.type==VMType::INSTANCE){
                    // Store the instance as the current exception object (for except as e:)
                    std::string cls=ev.class_name;
                    bool found=false;
                    while(!cls.empty()&&!found){
                        auto cit=class_reg_.find(cls);
                        if(cit==class_reg_.end()) break;
                        for(auto& sub:cit->second->sub_codes)
                            if(sub->name=="__str__"&&!sub->is_class){
                                std::vector<VMVal> na; msg=exec_code(sub,na,ev).to_string(); found=true; break;
                            }
                        cls=cit->second->parent_class;
                    }
                    if(!found) msg=ev.to_string();
                    // Encode the instance into the error message so it survives the catch
                    // We wrap: encode as JSON-like to recover in except handler
                    last_exception_obj_=ev;
                } else {
                    msg=ev.to_string();
                    last_exception_obj_=VMVal::make_none();
                }
                throw std::runtime_error(msg);
            }
            case Op::SETUP_EXCEPT: break;   // marker only; handled structurally
            case Op::END_EXCEPT:   break;   // marker only
            case Op::STORE_EXCEPT_AS: {
                // exception value is on stack; store under alias name
                VMVal exc=stack_.empty()?VMVal::make_str("Exception"):pop();
                define_var(fr.code->names[ins.arg], exc); break;
            }
            case Op::LOAD_SELF_ATTR: {
                VMVal self_v = fr.self_val.value_or(VMVal::make_none());
                push(get_attr(self_v, fr.code->names[ins.arg])); break;
            }
            case Op::STORE_SELF_ATTR: {
                VMVal val = pop();
                VMVal& self_v = *fr.self_val;
                set_attr(self_v, fr.code->names[ins.arg], std::move(val)); break;
            }

            case Op::RAISE_ERROR: {
                VMVal ev=pop();
                std::string msg;
                VMVal exc_obj;
                if(ev.type==VMType::INSTANCE){
                    // Raised an instance — call __str__ for the message
                    exc_obj=ev;
                    last_exception_obj_=ev;
                    VMVal s=call_dunder(ev,"__str__",{});
                    msg=s.type!=VMType::NONE?s.to_string():ev.to_string();
                } else {
                    msg=ev.to_string();
                    exc_obj=VMVal::make_str(msg);
                    last_exception_obj_=VMVal::make_none();
                }
                // Check exception table for a matching handler
                int ip_at_raise = fr.ip - 1;
                bool handled = false;
                for(auto& ee : fr.code->exc_table){
                    if(ip_at_raise >= ee.try_start && ip_at_raise < ee.try_end){
                        push(exc_obj);
                        fr.ip = match_except_handler(ee, exc_obj);
                        handled = true;
                        last_exception_obj_=VMVal::make_none();
                        break;
                    }
                }
                if(!handled) throw std::runtime_error(msg);
                break;
            }
                push(VMVal::make_str(pop().to_string())); break;

            case Op::IADD: {
                VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE){
                    VMVal res=call_dunder(l,"__iadd__",{r});
                    if(res.type!=VMType::NONE){push(res);break;}
                    res=call_dunder(l,"__add__",{r});
                    if(res.type!=VMType::NONE){push(res);break;}
                }
                if(l.type==VMType::INT&&r.type==VMType::INT&&l.s.empty()&&r.s.empty()){
                    int64_t res; if(!nypy::add_ovf(l.i,r.i,res)){ push(VMVal::make_int(res)); break; }
                }
                push(binop_inplace(nypy::A_ADD,l,r)); break;
            }
            case Op::ISUB: { VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE){ VMVal res=call_dunder(l,"__isub__",{r}); if(res.type==VMType::NONE) res=call_dunder(l,"__sub__",{r}); if(res.type!=VMType::NONE){push(res);break;} }
                push(binop(nypy::A_SUB,l,r)); break; }
            case Op::IMUL: { VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE){ VMVal res=call_dunder(l,"__imul__",{r}); if(res.type==VMType::NONE) res=call_dunder(l,"__mul__",{r}); if(res.type!=VMType::NONE){push(res);break;} }
                push(binop_inplace(nypy::A_MUL,l,r)); break; }
            case Op::IDIV: { VMVal r=pop(),l=pop(); push(binop(nypy::A_DIV,l,r)); break; }
            case Op::IMOD: { VMVal r=pop(),l=pop(); push(binop(nypy::A_MOD,l,r)); break; }

            default: break;
            } // end switch
            } catch(VMReturn& r) { throw; }  // propagate returns
              catch(std::runtime_error& exc) {
                CallFrame& fr2=call_stack_.back();
                std::string emsg=exc.what();
                // Use the exception object if available (raised via 'raise instance')
                VMVal exc_val = (last_exception_obj_.type==VMType::INSTANCE) ?
                    last_exception_obj_ : VMVal::make_str(emsg);
                last_exception_obj_ = VMVal::make_none(); // clear after use
                bool handled=false;
                // 1) Check exc_table (structured try/except blocks)
                int ip_at_raise=fr2.ip-1;
                for(auto& ee:fr2.code->exc_table){
                    if(ip_at_raise>=ee.try_start && ip_at_raise<=ee.try_end){
                        push(exc_val);
                        fr2.ip=match_except_handler(ee, exc_val);
                        handled=true; break;
                    }
                }
                // 2) Fallback: find SETUP_EXCEPT instruction (used by `with`,
                // see NT::WITH). Must skip any SETUP_EXCEPT whose block
                // already exited normally (reached its matching END_EXCEPT)
                // - otherwise an exception raised anywhere after a completed
                // `with` block, with nothing else to catch it, walked back
                // into that `with`'s stale handler instead of propagating,
                // re-ran the code after the `with` block, hit the same raise
                // again, and looped forever.
                if(!handled){
                    int skip=0;
                    for(int i=fr2.ip-1;i>=0;i--){
                        Op op2=fr2.code->instructions[i].op;
                        if(op2==Op::END_EXCEPT){ skip++; continue; }
                        if(op2==Op::SETUP_EXCEPT){
                            if(skip>0){ skip--; continue; }
                            push(exc_val);
                            fr2.ip=fr2.code->instructions[i].arg;
                            handled=true; break;
                        }
                    }
                }
                if(!handled) throw;
              }
        }
    }

    // ── JSON parser ─────────────────────────────────────────────────────────
    static std::pair<VMVal,size_t> json_parse_val(const std::string& s, size_t pos) {
        // Skip whitespace
        while(pos<s.size()&&(s[pos]==' '||s[pos]=='\t'||s[pos]=='\r'||s[pos]=='\n')) pos++;
        if(pos>=s.size()) return {VMVal::make_none(),pos};
        char c=s[pos];
        if(c=='"') {
            // Parse string
            size_t start=pos+1; std::string val;
            pos=start;
            while(pos<s.size()&&s[pos]!='"'){
                if(s[pos]=='\\'&&pos+1<s.size()){
                    char esc=s[pos+1];
                    if(esc=='n') val+='\n';
                    else if(esc=='t') val+='\t';
                    else val+=esc;
                    pos+=2;
                } else { val+=s[pos++]; }
            }
            return {VMVal::make_str(val), pos+1};
        }
        if(c=='{') {
            // Parse object
            auto map=std::make_shared<VMMap>();
            pos++;
            while(pos<s.size()){
                while(pos<s.size()&&(s[pos]==' '||s[pos]=='\t'||s[pos]=='\r'||s[pos]=='\n')) pos++;
                if(pos>=s.size()||s[pos]=='}'){pos++;break;}
                if(s[pos]==','){pos++;continue;}
                auto [key,p1]=json_parse_val(s,pos); pos=p1;
                while(pos<s.size()&&s[pos]!=':') pos++;
                pos++; // skip ':'
                auto [val,p2]=json_parse_val(s,pos); pos=p2;
                (*map)[key.s]=std::move(val);
            }
            VMVal r; r.type=VMType::MAP; r.map=map; return {std::move(r),pos};
        }
        if(c=='[') {
            // Parse array
            std::vector<VMVal> items; pos++;
            while(pos<s.size()){
                while(pos<s.size()&&(s[pos]==' '||s[pos]=='\t'||s[pos]=='\r'||s[pos]=='\n')) pos++;
                if(pos>=s.size()||s[pos]==']'){pos++;break;}
                if(s[pos]==','){pos++;continue;}
                auto [val,p]=json_parse_val(s,pos); pos=p;
                items.push_back(std::move(val));
            }
            return {VMVal::make_list(std::move(items)),pos};
        }
        if(s.substr(pos,4)=="null"||s.substr(pos,4)=="none") return {VMVal::make_none(),pos+4};
        if(s.substr(pos,4)=="true") return {VMVal::make_bool(true),pos+4};
        if(s.substr(pos,5)=="false") return {VMVal::make_bool(false),pos+5};
        // Number
        size_t start=pos;
        bool is_float=false;
        if(pos<s.size()&&(s[pos]=='-')) pos++;
        while(pos<s.size()&&::isdigit((unsigned char)s[pos])) pos++;
        if(pos<s.size()&&s[pos]=='.'){is_float=true;pos++;while(pos<s.size()&&::isdigit((unsigned char)s[pos]))pos++;}
        if(pos<s.size()&&(s[pos]=='e'||s[pos]=='E')){is_float=true;pos++;if(pos<s.size()&&(s[pos]=='+'||s[pos]=='-'))pos++;while(pos<s.size()&&::isdigit((unsigned char)s[pos]))pos++;}
        std::string num_s=s.substr(start,pos-start);
        if(is_float) try{return {VMVal::make_float(std::stod(num_s)),pos};}catch(...){}
        else try{return {VMVal::make_int(std::stoll(num_s)),pos};}catch(...){}
        return {VMVal::make_none(),pos};
    }

    // ── Arithmetic helpers ────────────────────────────────────────────────
    static double to_d(const VMVal& v) {
        if(v.type==VMType::INT)   return (double)v.i;
        if(v.type==VMType::FLOAT) return v.d;
        if(v.type==VMType::BOOL)  return v.b?1.0:0.0;
        if(v.type==VMType::STRING){ try{return std::stod(v.s);}catch(...){} }
        return 0.0;
    }
    // ── Operators ───────────────────────────────────────────────────────
    // Arithmetic goes through nypy::arith (NyBigInt.hpp), the code the
    // interpreter uses: ints grow into big ints instead of wrapping at 2^64,
    // `/` is true division, `//` and `%` floor, bool is an int. The op codes
    // are nypy::ArithOp's.
    // Runs shared-library code, turning its errors into VM exceptions.
    template<class F> auto nycall(F&& f) -> decltype(f()) {
        try { return f(); }
        catch(nypy::PyError& e){ raise_native_exception(e.type, e.msg); }
    }
    static bool seq_times(const VMVal& n, int64_t& times){
        if(n.type==VMType::BOOL){ times=n.b?1:0; return true; }
        if(n.type!=VMType::INT) return false;
        times=n.s.empty()?n.i:(n.s[0]=='-'?0:INT64_MAX);
        return true;
    }
    static std::string vm_type_name(const VMVal& v){
        switch(v.type){
            case VMType::NONE: return "NoneType"; case VMType::BOOL: return "bool";
            case VMType::INT: return "int"; case VMType::FLOAT: return "float";
            case VMType::STRING: return "str";
            case VMType::LIST: return v.b?"tuple":"list";
            case VMType::MAP: return "dict";
            case VMType::FUNCTION: return "function";
            case VMType::NATIVE: return "builtin_function_or_method";
            case VMType::CLASS: return "type";
            case VMType::INSTANCE: return v.class_name;
            case VMType::GENERATOR: return "generator";
            case VMType::ITERATOR: return "iterator";
            default: return "object";
        }
    }
    VMVal binop(int op, const VMVal& l, const VMVal& r) {
        nypy::NumV x,y;
        if(l.to_numv(x)&&r.to_numv(y)){
            if((op==nypy::A_AND||op==nypy::A_OR||op==nypy::A_XOR)&&l.type==VMType::BOOL&&r.type==VMType::BOOL){
                bool v=op==nypy::A_AND?(l.b&&r.b):op==nypy::A_OR?(l.b||r.b):(l.b!=r.b);
                return VMVal::make_bool(v);
            }
            if(op<=nypy::A_SUB&&x.k==1&&y.k==1){   // the common case, inline
                int64_t res;
                if(!(op==nypy::A_ADD?nypy::add_ovf(x.i,y.i,res):nypy::sub_ovf(x.i,y.i,res))) return VMVal::make_int(res);
            }
            return nycall([&]{ return VMVal::from_numv(nypy::arith(op,x,y)); });
        }
        switch(op){
        case nypy::A_ADD:
            if(l.type==VMType::STRING&&r.type==VMType::STRING) return VMVal::make_str(l.s+r.s);
            if(l.type==VMType::LIST&&r.type==VMType::LIST){
                std::vector<VMVal> out; if(l.list) out=*l.list;
                if(r.list) out.insert(out.end(),r.list->begin(),r.list->end());
                VMVal res=VMVal::make_list(std::move(out)); res.b=l.b&&r.b; return res;
            }
            // Lenient, as on the interpreter: a string on either side
            // concatenates the other's text.
            if(l.type==VMType::STRING||r.type==VMType::STRING) return VMVal::make_str(l.to_string()+r.to_string());
            break;
        case nypy::A_MUL: {
            int64_t times;
            const VMVal* seq=nullptr;
            if(seq_times(r,times)) seq=&l; else if(seq_times(l,times)) seq=&r;
            if(seq&&seq->type==VMType::STRING){
                if(times>0&&seq->s.size()*(uint64_t)times>(1ull<<32)) raise_native_exception("MemoryError","repeated string is too long");
                return VMVal::make_str(nypy::repeat_str(seq->s,times));
            }
            if(seq&&seq->type==VMType::LIST){
                std::vector<VMVal> out;
                if(seq->list) for(int64_t t=0;t<times;t++) out.insert(out.end(),seq->list->begin(),seq->list->end());
                VMVal res=VMVal::make_list(std::move(out)); res.b=seq->b; return res;
            }
            break;
        }
        case nypy::A_MOD:
            if(l.type==VMType::STRING) return VMVal::make_str(percent_format(l.s,r));
            break;
        case nypy::A_SUB: case nypy::A_AND: case nypy::A_OR: case nypy::A_XOR:
            // Sets are deduplicated lists here.
            if(l.type==VMType::LIST&&r.type==VMType::LIST&&l.list&&r.list){
                std::unordered_set<std::string> other,seen;
                for(auto& v:*r.list) other.insert(v.repr());
                std::vector<VMVal> res;
                if(op==nypy::A_OR){
                    for(auto& v:*l.list) if(seen.insert(v.repr()).second) res.push_back(v);
                    for(auto& v:*r.list) if(seen.insert(v.repr()).second) res.push_back(v);
                } else {
                    for(auto& v:*l.list){
                        bool in=other.count(v.repr())>0;
                        if((op==nypy::A_AND)==in||(op==nypy::A_XOR&&!in)) res.push_back(v);
                    }
                    if(op==nypy::A_XOR){
                        std::unordered_set<std::string> mine; for(auto& v:*l.list) mine.insert(v.repr());
                        for(auto& v:*r.list) if(!mine.count(v.repr())) res.push_back(v);
                    }
                }
                return VMVal::make_list(std::move(res));
            }
            break;
        default: break;
        }
        if(op==nypy::A_DIV||op==nypy::A_FLOORDIV||op==nypy::A_MOD||op==nypy::A_POW||op==nypy::A_SUB||op==nypy::A_ADD||op==nypy::A_MUL)
            raise_native_exception("TypeError",std::string("unsupported operand type(s) for ")+nypy::arith_symbol(op)+": '"+vm_type_name(l)+"' and '"+vm_type_name(r)+"'");
        return VMVal::make_int(0);
    }
    // In place: `L += it` extends and `L *= n` repeats the list object itself,
    // so every alias sees it; anything else is the binary operator.
    VMVal binop_inplace(int op, VMVal& l, const VMVal& r) {
        if(l.type==VMType::LIST&&!l.b&&l.list){
            if(op==nypy::A_ADD){
                std::vector<VMVal> more=iter_items(r);
                l.list->insert(l.list->end(),more.begin(),more.end());
                return l;
            }
            int64_t times;
            if(op==nypy::A_MUL&&seq_times(r,times)){
                std::vector<VMVal> orig=*l.list;
                l.list->clear();
                for(int64_t t=0;t<times;t++) l.list->insert(l.list->end(),orig.begin(),orig.end());
                return l;
            }
        }
        return binop(op,l,r);
    }
    // A value as the shared formatter sees it (NyFormat.hpp); conv 's'/'r'/'a'
    // passes its str/repr/ascii text.
    nypy::FmtVal to_fmtval(const VMVal& v, char conv) {
        if(conv=='s') return nypy::FmtVal::of_str(vm_str(v));
        if(conv=='r') return nypy::FmtVal::of_str(vm_repr(v));
        if(conv=='a'){
            std::string rr=vm_repr(v),out;
            for(size_t k=0;k<rr.size();){ size_t j=k; uint32_t cp=nypy::u8_decode(rr,j); if(cp<0x80) out+=(char)cp; else out+=nypy::hex_esc(cp); k=j; }
            return nypy::FmtVal::of_str(out);
        }
        switch(v.type){
            case VMType::NONE: return nypy::FmtVal::of_none();
            case VMType::BOOL: return nypy::FmtVal::of_bool(v.b);
            case VMType::INT: {
                if(v.s.empty()) return nypy::FmtVal::of_int(v.i);
                nypy::BigInt bi; nypy::BigInt::parse(v.s,10,bi); return nypy::FmtVal::of_big(bi);
            }
            case VMType::FLOAT: return nypy::FmtVal::of_float(v.d);
            case VMType::STRING: return nypy::FmtVal::of_str(v.s);
            default: return nypy::FmtVal::of_other(vm_str(v),vm_type_name(v));
        }
    }
    // str(v) / repr(v), honouring __str__/__repr__ on instances.
    std::string vm_str(const VMVal& v) {
        if(v.type==VMType::INSTANCE){
            VMVal r=call_dunder(v,"__str__",{});
            if(r.type==VMType::STRING) return r.s;
            r=call_dunder(v,"__repr__",{});
            if(r.type==VMType::STRING) return r.s;
        }
        return v.to_string();
    }
    std::string vm_repr(const VMVal& v) {
        if(v.type==VMType::INSTANCE){
            VMVal r=call_dunder(v,"__repr__",{});
            if(r.type==VMType::STRING) return r.s;
        }
        return v.repr();
    }
    std::string format_value(const VMVal& v, const std::string& spec) {
        if(v.type==VMType::INSTANCE){
            VMVal r=call_dunder(v,"__format__",{VMVal::make_str(spec)});
            if(r.type==VMType::STRING) return r.s;
            if(spec.empty()) return vm_str(v);
        }
        return nycall([&]{ return nypy::format_value(to_fmtval(v,0),spec); });
    }
    // "fmt" % args
    std::string percent_format(const std::string& fmt, const VMVal& r) {
        std::vector<VMVal> args;
        bool mapping=false;
        if(r.is_tuple()&&r.list) args=*r.list;
        else { args.push_back(r); mapping=r.type==VMType::MAP; }
        return nycall([&]{
            return nypy::percent_format(fmt,(int64_t)args.size(),mapping,
                [&](int64_t idx,const std::string& key,char conv)->nypy::FmtVal{
                    if(idx<0){
                        auto it=r.map->find(nypy::key_of_str(key));
                        if(it==r.map->end()) raise_native_exception("KeyError",nypy::str_repr(key));
                        return to_fmtval(it->second,conv);
                    }
                    return to_fmtval(args[(size_t)idx],conv);
                });
        });
    }
    // str.format
    std::string str_format(const std::string& fmt, const std::vector<VMVal>& args, const VMVal* kw) {
        return nycall([&]{
            return nypy::str_format(fmt,[&](const nypy::FieldRef& f,char conv)->nypy::FmtVal{
                VMVal v;
                if(f.numeric){
                    if(f.index<0||(size_t)f.index>=args.size())
                        raise_native_exception("IndexError","Replacement index "+std::to_string(f.index)+" out of range for positional args tuple");
                    v=args[(size_t)f.index];
                } else {
                    VMMap::iterator it;
                    if(!kw||!kw->map||(it=kw->map->find(nypy::key_of_str(f.name)))==kw->map->end())
                        raise_native_exception("KeyError",nypy::str_repr(f.name));
                    v=it->second;
                }
                for(auto& step:f.chain){
                    if(step.first=='.') v=get_attr(v,step.second);
                    else {
                        bool digits=!step.second.empty()&&std::all_of(step.second.begin(),step.second.end(),[](char c){return c>='0'&&c<='9';});
                        v=get_sub(v,digits?VMVal::make_int(std::stoll(step.second)):VMVal::make_str(step.second));
                    }
                }
                if(conv) return to_fmtval(v,conv);
                if(v.type==VMType::INSTANCE) return nypy::FmtVal::of_other(vm_str(v),v.class_name);
                return to_fmtval(v,0);
            });
        });
    }
    // Every element an iterable yields: a list/tuple's items, a string's
    // characters, a dict's keys, what is left of an iterator or a
    // generator (consuming it), an instance's __iter__/__next__ sequence.
    std::vector<VMVal> iter_items(const VMVal& v) {
        switch(v.type){
            case VMType::LIST: return v.list?*v.list:std::vector<VMVal>{};
            case VMType::STRING: {
                std::vector<VMVal> out;
                for(auto& ch:nypy::u8_chars(v.s)) out.push_back(VMVal::make_str(ch));
                return out;
            }
            case VMType::MAP: {
                std::vector<VMVal> out;
                if(v.map) for(auto& kv:*v.map) if(!vm_internal_key(kv.first)) out.push_back(vm_key_value(kv.first));
                return out;
            }
            case VMType::ITERATOR: {
                std::vector<VMVal> out;
                if(v.iter){
                    for(size_t k=(size_t)std::max(0,v.iter->first);k<v.iter->second.size();k++) out.push_back(v.iter->second[k]);
                    v.iter->first=(int)v.iter->second.size();
                }
                return out;
            }
            case VMType::GENERATOR: {
                std::vector<VMVal> out;
                VMVal g=v;
                while(g.gen&&!g.gen->done){
                    VMVal item=gen_next(g);
                    if(g.gen&&g.gen->done) break;
                    out.push_back(item);
                }
                return out;
            }
            case VMType::INT: {   // for i in n: 0..n-1, as the VM always allowed
                std::vector<VMVal> out;
                for(int64_t k=0;k<v.i;k++) out.push_back(VMVal::make_int(k));
                return out;
            }
            case VMType::INSTANCE: {
                VMVal it=call_dunder(v,"__iter__",{});
                if(it.type!=VMType::NONE&&it.type!=VMType::INSTANCE) return iter_items(it);
                if(it.type==VMType::NONE) it=v;
                std::vector<VMVal> out;
                for(int guard=0;guard<100000000;guard++){
                    VMVal item;
                    try { item=call_dunder(it,"__next__",{}); }
                    catch(std::runtime_error& e){
                        std::string m=e.what();
                        if(m.find("StopIteration")!=std::string::npos){ last_exception_obj_=VMVal::make_none(); break; }
                        throw;
                    }
                    out.push_back(item);
                }
                return out;
            }
            default: break;
        }
        raise_native_exception("TypeError","'"+vm_type_name(v)+"' object is not iterable");
    }
    // A dict key's stored text (NyStr.hpp): 1 and "1" differ, 1 == 1.0 ==
    // true, tuples are keys, lists are not.
    std::string vkey(const VMVal& k) {
        switch(k.type){
            case VMType::STRING: return nypy::key_of_str(k.s);
            case VMType::INT:
                if(k.s.empty()) return nypy::key_of_int(k.i);
                { nypy::BigInt bi; nypy::BigInt::parse(k.s,10,bi); return nypy::key_of_big(bi); }
            case VMType::BOOL: return nypy::key_of_int(k.b?1:0);
            case VMType::FLOAT: return nypy::key_of_float(k.d);
            case VMType::NONE: case VMType::UNDEFINED: return nypy::key_of_none();
            case VMType::LIST:
                if(k.b){
                    std::vector<std::string> parts;
                    if(k.list) for(auto& e:*k.list) parts.push_back(vkey(e));
                    return nypy::key_of_tuple(parts);
                }
                raise_native_exception("TypeError","unhashable type: 'list'");
            case VMType::MAP: raise_native_exception("TypeError","unhashable type: 'dict'");
            default: break;
        }
        const void* id=k.map?(const void*)k.map.get():k.code?(const void*)k.code.get():k.gen?(const void*)k.gen.get():(const void*)k.iter.get();
        char buf[40]; snprintf(buf,sizeof buf,"v%p",id);
        vm_key_objs()[buf]=k;
        return nypy::key_of_obj(buf);
    }
    bool op_in(const VMVal& item, const VMVal& cont) {
        if(cont.type==VMType::INSTANCE){
            VMVal res=call_dunder(cont,"__contains__",{item});
            if(res.type!=VMType::NONE) return res.is_truthy();
        }
        if(cont.type==VMType::STRING&&item.type==VMType::STRING)
            return cont.s.find(item.s)!=std::string::npos;
        if(cont.type==VMType::LIST&&cont.list)
            for(auto& v:*cont.list) if(v==item) return true;
        if(cont.type==VMType::MAP&&cont.map)
            return cont.map->count(vkey(item))>0;
        return false;
    }
    // Which except clause (if any) a raised exception should run: the first
    // whose declared type is empty (catch-all), one of the generic
    // Exception/BaseException/Error names, equal to the exception's own
    // type, or a parent of it. Mirrors the interpreter's evalTry
    // (NythonExecutor.hpp) type-matching, including its silent fall-through
    // to `finally` (ee.end) when nothing matches rather than re-raising.
    int match_except_handler(const ExceptionEntry& ee, const VMVal& exc_val) {
        std::string exc_type = exc_val.type==VMType::INSTANCE ? exc_val.class_name : std::string();
        for(auto& cl : ee.clauses){
            if(cl.type_name.empty()) return cl.handler;
            if(exc_type.empty()) continue; // typed clause, untyped exception: no match
            if(exc_type==cl.type_name || cl.type_name=="Exception"
               || cl.type_name=="BaseException" || cl.type_name=="Error")
                return cl.handler;
            std::string cur=exc_type; int guard=0;
            while(!cur.empty() && guard++<16){
                auto cit=class_reg_.find(cur);
                if(cit==class_reg_.end()) break;
                cur=cit->second->parent_class;
                if(cur==cl.type_name) return cl.handler;
            }
        }
        return ee.end;
    }
    bool value_is_type(const VMVal& v, const std::string& want) {
        // Everything is an Object.
        if(want=="Object"||want=="object"||want=="any"||want=="Any") return true;
        // type(x) returns the type's name, so `type(t) is tuple` compares
        // that name with the type, as on the interpreter.
        if(v.type==VMType::STRING&&want!="str"&&want!="String"&&want!="string"){
            static const std::unordered_map<std::string,std::string> canon={
                {"int","int"},{"float","float"},{"bool","bool"},{"string","str"},{"list","list"},
                {"map","dict"},{"tuple","tuple"},{"none","none"},{"function","function"},{"builtin","function"},{"set","set"}};
            static const std::unordered_map<std::string,std::string> wantc={
                {"int","int"},{"Integer","int"},{"integer","int"},{"float","float"},{"Float","float"},{"double","float"},{"Double","float"},
                {"bool","bool"},{"Boolean","bool"},{"boolean","bool"},{"list","list"},{"List","list"},{"array","list"},{"Array","list"},
                {"map","dict"},{"Map","dict"},{"dict","dict"},{"Dict","dict"},{"tuple","tuple"},{"Tuple","tuple"},{"none","none"},{"None","none"},
                {"function","function"},{"Function","function"},{"set","set"},{"Set","set"}};
            auto a=canon.find(v.s); auto w=wantc.find(want);
            if(a!=canon.end()&&w!=wantc.end()&&a->second==w->second) return true;
        }
        switch(v.type){
            case VMType::INT:   return want=="int"||want=="Integer"||want=="integer";
            case VMType::FLOAT: return want=="float"||want=="Float"||want=="double"||want=="Double";
            case VMType::BOOL:  return want=="bool"||want=="Boolean"||want=="boolean";
            case VMType::NONE:  return want=="none"||want=="None";
            case VMType::STRING:return want=="str"||want=="String"||want=="string";
            case VMType::LIST:
                if(v.b) return want=="tuple"||want=="Tuple";
                return want=="list"||want=="List"||want=="array"||want=="Array";
            case VMType::MAP:   return want=="map"||want=="Map"||want=="dict"||want=="Dict";
            case VMType::FUNCTION: case VMType::NATIVE:
                                return want=="function"||want=="Function";
            default: break;
        }
        if(v.type==VMType::INSTANCE){
            // Walk the inheritance chain so `child is Base` holds.
            std::string cur=v.class_name;
            int guard=0;
            while(!cur.empty() && guard++<64){
                if(cur==want) return true;
                auto it=class_reg_.find(cur);
                if(it==class_reg_.end()||!it->second) break;
                cur=it->second->parent_class;
            }
        }
        return false;
    }

    static bool op_is(const VMVal& l, const VMVal& r) {
        if(l.type==VMType::NONE&&r.type==VMType::NONE) return true;
        if(l.type!=r.type) return false;
        if(l.type==VMType::BOOL) return l.b==r.b;
        // Containers compare by identity: two separately built lists with equal
        // contents are not the same list. The interpreter already did this; the
        // VM returned true for `L is L` only by accident of `l==r` and false
        // where the shared_ptrs differed, so the two disagreed both ways.
        if(l.type==VMType::LIST) return l.list.get()==r.list.get();
        if(l.type==VMType::MAP)  return l.map.get()==r.map.get();
        // Functions compare by identity, not by structural equality: two
        // distinct functions are not "the same function".
        if(l.type==VMType::FUNCTION) return l.code.get()==r.code.get();
        if(l.type==VMType::NATIVE)   return false;
        return l==r;
    }

    // ── Attribute access ────────────────────────────────────────────────
    VMVal get_attr(const VMVal& obj, const std::string& attr) {
        // Instance / map fields — check for property descriptors
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(attr);
            if(it!=obj.map->end()){
                VMVal& v=it->second;
                // Property descriptor: {__is_property__: true, __get__: func}
                if(v.type==VMType::MAP&&v.map&&v.map->count("__is_property__")){
                    auto git=v.map->find("__get__");
                    if(git!=v.map->end()&&git->second.type==VMType::FUNCTION){
                        std::vector<VMVal> no_args;
                        return exec_code(git->second.code, no_args, obj);
                    }
                }
                return v;
            }
        }
        // Method lookup via class registry — also check for property descriptors in class
        if(obj.type==VMType::INSTANCE){
            std::string cls=obj.class_name;
            while(!cls.empty()){
                auto cit=class_reg_.find(cls);
                if(cit==class_reg_.end()) break;
                for(auto& sub:cit->second->sub_codes){
                    if(sub->name==attr&&!sub->is_class){
                        // Carry the instance with the method. Returning a bare
                        // function meant `var f = obj.m` lost `self`, so calling
                        // f later shifted every argument left — the same defect
                        // the interpreter had (round 4). Reuses the existing
                        // __super_bound__ convention that vm_call understands.
                        VMVal bound=VMVal::make_map();
                        bound.class_name="__bound_method__";
                        (*bound.map)["__fn__"]=VMVal::make_func(sub);
                        (*bound.map)["__self__"]=obj;
                        return bound;
                    }
                }
                cls=cit->second->parent_class;
            }
        }
        if(obj.type==VMType::STRING) return str_method(obj,attr);
        if(obj.type==VMType::LIST)   return list_method(obj,attr);
        // CLASS type: look for nested classes and class-level vars in class_vars_
        if(obj.type==VMType::CLASS){
            std::string cname = obj.class_name.empty() ? obj.s : obj.class_name;
            // Check class_vars_ (class-level variables)
            auto cit = class_vars_.find(cname);
            if(cit != class_vars_.end()){
                auto vit = cit->second.find(attr);
                if(vit != cit->second.end()) return vit->second;
            }
            // Check sub-codes for nested class or static method
            auto rit = class_reg_.find(cname);
            if(rit != class_reg_.end()){
                for(auto& sub: rit->second->sub_codes){
                    if(sub->name == attr && sub->is_class){
                        // Return nested class as a CLASS VMVal
                        VMVal cv; cv.type=VMType::CLASS; cv.class_name=attr; cv.code=sub;
                        return cv;
                    }
                    if(sub->name == attr && !sub->is_class){
                        return VMVal::make_func(sub);
                    }
                }
            }
        }
        return VMVal::make_none();
    }
    void set_attr(VMVal& obj, const std::string& attr, VMVal val) {
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(attr);
            if(it!=obj.map->end()){
                VMVal& v=it->second;
                if(v.type==VMType::MAP&&v.map&&v.map->count("__is_property__")){
                    auto sit=v.map->find("__set__");
                    if(sit!=v.map->end()&&sit->second.type==VMType::FUNCTION){
                        std::vector<VMVal> args={val};
                        exec_code(sit->second.code, args, obj);
                        return;
                    }
                }
            }
            (*obj.map)[attr]=std::move(val);
        }
        // CLASS type: update class_vars_
        if(obj.type==VMType::CLASS){
            std::string cname = obj.class_name.empty() ? obj.s : obj.class_name;
            class_vars_[cname][attr] = std::move(val);
        }
    }
    // Resolve a [start,end,step] slice against a sequence of length sz,
    // returning the indices to take in order. NONE start/end mean "the natural
    // end for this direction", which differs by the sign of the step.
    // An index: an int (or bool); anything else raises TypeError.
    int64_t index_of(const VMVal& idx, const char* what) {
        if(idx.type==VMType::INT) return idx.s.empty()?idx.i:(idx.s[0]=='-'?INT64_MIN/2:INT64_MAX/2);
        if(idx.type==VMType::BOOL) return idx.b?1:0;
        raise_native_exception("TypeError",std::string(what)+" indices must be integers or slices, not "+vm_type_name(idx));
    }
    // A slice spec [start, stop(, step)] (none = omitted) against length len:
    // the number of items and the adjusted start/step (PySlice_AdjustIndices).
    int64_t slice_spec(const std::vector<VMVal>& sp, int64_t len, int64_t& st, int64_t& step) {
        int64_t en=0; st=0; step=1;
        bool hs=false,he=false;
        auto bound=[&](const VMVal& v,int64_t& out)->bool{
            if(v.type==VMType::NONE||v.type==VMType::UNDEFINED) return false;
            if(v.type!=VMType::INT&&v.type!=VMType::BOOL) raise_native_exception("TypeError","slice indices must be integers or None or have an __index__ method");
            out=index_of(v,"slice"); return true;
        };
        if(sp.size()>=1) hs=bound(sp[0],st);
        if(sp.size()>=2) he=bound(sp[1],en);
        if(sp.size()>=3&&sp[2].type!=VMType::NONE) bound(sp[2],step);
        return nycall([&]{ return nypy::slice_adjust(len,hs,st,he,en,step); });
    }
    VMVal get_sub(const VMVal& obj, const VMVal& idx) {
        if(obj.type==VMType::LIST&&obj.list){
            auto& L=*obj.list;
            if(idx.type==VMType::LIST&&idx.list&&!idx.b){
                int64_t st,step,n=slice_spec(*idx.list,(int64_t)L.size(),st,step);
                std::vector<VMVal> out;
                for(int64_t k=0,i=st;k<n;k++,i+=step) out.push_back(L[(size_t)i]);
                VMVal r=VMVal::make_list(std::move(out)); r.b=obj.b; return r;
            }
            int64_t i=index_of(idx,obj.b?"tuple":"list");
            int64_t sz=(int64_t)L.size();
            if(i<0) i+=sz;
            if(i<0||i>=sz) raise_native_exception("IndexError",std::string(obj.b?"tuple":"list")+" index out of range");
            return L[(size_t)i];
        }
        if(obj.type==VMType::MAP&&obj.map){
            // A missing key reads none, as on the interpreter (library code
            // relies on it); d.get() is the same.
            auto it=obj.map->find(vkey(idx));
            return it!=obj.map->end()?it->second:VMVal::make_none();
        }
        if(obj.type==VMType::STRING){
            if(idx.type==VMType::LIST&&idx.list&&!idx.b){
                std::vector<VMVal> sp=*idx.list;
                bool hs=false,he=false; int64_t st=0,en=0,step=1;
                if(sp.size()>=1&&sp[0].type!=VMType::NONE){ hs=true; st=index_of(sp[0],"slice"); }
                if(sp.size()>=2&&sp[1].type!=VMType::NONE){ he=true; en=index_of(sp[1],"slice"); }
                if(sp.size()>=3&&sp[2].type!=VMType::NONE) step=index_of(sp[2],"slice");
                return VMVal::make_str(nycall([&]{ return nypy::str_slice(obj.s,hs,st,he,en,step); }));
            }
            int64_t i=index_of(idx,"string");
            return VMVal::make_str(nycall([&]{ return nypy::str_getitem(obj.s,i); }));
        }
        return VMVal::make_none();
    }
    void set_sub(VMVal& obj, const VMVal& idx, VMVal val) {
        if(obj.type==VMType::LIST&&obj.list){
            if(obj.b) raise_native_exception("TypeError","'tuple' object does not support item assignment");
            auto& L=*obj.list;
            if(idx.type==VMType::LIST&&idx.list&&!idx.b){
                // L[a:b] = it / L[a:b:c] = it
                std::vector<VMVal> repl=iter_items(val);
                int64_t len=(int64_t)L.size(),st,step,n=slice_spec(*idx.list,len,st,step);
                if(step==1){
                    if(n<0) n=0;
                    if(st>len) st=len;
                    L.erase(L.begin()+st,L.begin()+st+n);
                    L.insert(L.begin()+st,repl.begin(),repl.end());
                } else {
                    if((int64_t)repl.size()!=n)
                        raise_native_exception("ValueError","attempt to assign sequence of size "+std::to_string(repl.size())+" to extended slice of size "+std::to_string(n));
                    for(int64_t k=0,i=st;k<n;k++,i+=step) L[(size_t)i]=repl[(size_t)k];
                }
                return;
            }
            int64_t i=index_of(idx,"list");
            int64_t sz=(int64_t)L.size();
            if(i<0) i+=sz;
            if(i<0) raise_native_exception("IndexError","list assignment index out of range");
            // Past the end the list grows (padded with none), on both engines:
            // library code appends with `a[len] = x`.
            if(i>=sz) L.resize((size_t)i+1,VMVal::make_none());
            L[(size_t)i]=std::move(val);
        } else if(obj.type==VMType::MAP&&obj.map) {
            (*obj.map)[vkey(idx)]=std::move(val);
        } else if(obj.type==VMType::STRING) {
            raise_native_exception("TypeError","'str' object does not support item assignment");
        }
    }

    // ── Function / method call ──────────────────────────────────────────
    // Name pushed by the LOAD_NAME/LOAD_GLOBAL that produced the callee for the
    // CALL_FUNCTION at `ip`. Scans back past the argument-producing
    // instructions rather than assuming a fixed offset.
    std::string calleeNameBefore(CallFrame& fr, int ip) {
        if(!fr.code) return std::string();
        if(ip < 0 || ip >= (int)fr.code->instructions.size()) return std::string();
        int argc = fr.code->instructions[ip].arg;
        int seen = 0;
        for(int k = ip - 1; k >= 0 && k > ip - 64; --k){
            const auto& pi = fr.code->instructions[k];
            if(pi.op==Op::LOAD_NAME){
                if(seen >= argc){
                    if(pi.arg >= 0 && pi.arg < (int)fr.code->names.size())
                        return fr.code->names[pi.arg];
                    return std::string();
                }
                seen++;
            } else if(pi.op==Op::LOAD_CONST){
                seen++;
            }
        }
        return std::string();
    }

    VMVal vm_call(VMVal callee, std::vector<VMVal>& args, std::optional<VMVal> self) {
        if(callee.type==VMType::NONE||callee.type==VMType::UNDEFINED)
            return VMVal::make_none();
        // __call__: instance used as callable
        if(callee.type==VMType::INSTANCE){
            VMVal r=call_dunder(callee,"__call__",args);
            return r;
        }
        // __super_bound__: bound method from super() proxy
        if(callee.type==VMType::MAP&&callee.class_name=="__bound_method__"&&callee.map){
            auto& bm=*callee.map;
            VMVal fn=bm.count("__fn__")?bm["__fn__"]:VMVal::make_none();
            VMVal sv=bm.count("__self__")?bm["__self__"]:VMVal::make_none();
            if(fn.type==VMType::FUNCTION&&fn.code) return exec_code(fn.code,args,sv);
            return VMVal::make_none();
        }
        if(callee.type==VMType::MAP&&callee.class_name=="__super_bound__"&&callee.map){
            auto& m=*callee.map;
            VMVal fn=m.count("__fn__")?m["__fn__"]:VMVal::make_none();
            VMVal sv=m.count("__self__")?m["__self__"]:VMVal::make_none();
            if(fn.type==VMType::FUNCTION&&fn.code)
                return exec_code(fn.code,args,sv);
            return VMVal::make_none();
        }
        // SUPER_PROXY called directly as super() → return itself
        if(callee.type==VMType::SUPER_PROXY) return callee;
        if(callee.type==VMType::NATIVE) return callee.native(args);
        if(callee.type==VMType::FUNCTION&&callee.code&&callee.code->has_yield()){
            // Generator function: collect all yielded values into a list
            std::vector<VMVal> yielded;
            std::vector<VMVal> gen_args=args;
            // Apply self-extraction if needed
            std::optional<VMVal> gen_self=self;
            if(!gen_self&&!gen_args.empty()&&!callee.code->param_names.empty()
               &&callee.code->param_names[0]=="self"
               &&(gen_args[0].type==VMType::INSTANCE||gen_args[0].type==VMType::MAP)){
                gen_self=gen_args[0];
                gen_args=std::vector<VMVal>(gen_args.begin()+1,gen_args.end());}
            // Return a lazy generator (coroutine-style)
            return make_generator_val(callee.code, gen_args, gen_self, callee.closure_env);
        }
        if(callee.type==VMType::FUNCTION&&callee.code){
            // If no explicit self but first param is "self" and first arg is an instance,
            // extract self from args (e.g. Animal.__init__(self, name) pattern)
            if(!self && !args.empty() && !callee.code->param_names.empty()
               && callee.code->param_names[0]=="self"
               && (args[0].type==VMType::INSTANCE||args[0].type==VMType::MAP)) {
                VMVal self_val = args[0];
                std::vector<VMVal> rest(args.begin()+1, args.end());
                return exec_code(callee.code, rest, self_val, callee.closure_env);
            }
            return exec_code(callee.code,args,self,callee.closure_env);
        }
        if(callee.type==VMType::CLASS&&callee.code){
            auto attrs=std::make_shared<VMMap>();
            VMVal inst=VMVal::make_instance(callee.class_name,attrs);
            if(!class_reg_.count(callee.class_name)) class_reg_[callee.class_name]=callee.code;
            {
                // Find __init__ in class hierarchy
                std::string search_cls=callee.class_name;
                bool found_init=false;
                while(!search_cls.empty()&&!found_init){
                    auto cit=class_reg_.find(search_cls);
                    if(cit==class_reg_.end()){
                        // Try callee.code if it's this class:
                        if(search_cls==callee.class_name){
                            for(auto& sub:callee.code->sub_codes)
                                if(is_ctor_name(sub->name)&&!sub->is_class){exec_code(sub,args,inst);found_init=true;break;}
                        }
                        break;
                    }
                    for(auto& sub:cit->second->sub_codes)
                        if(is_ctor_name(sub->name)&&!sub->is_class){exec_code(sub,args,inst);found_init=true;break;}
                    if(!found_init) search_cls=cit->second->parent_class;
                }
                if(!found_init){
                    // Fallback: search callee.code->sub_codes directly:
                    for(auto& sub:callee.code->sub_codes)
                        if(is_ctor_name(sub->name)&&!sub->is_class){exec_code(sub,args,inst);break;}
                }
            }
            return inst;
        }
        return VMVal::make_none();
    }
    // The interpreter accepts either `init` or `__init__` as the constructor
    // (three call sites in NythonExecutor.hpp test both). The VM matched only
    // `__init__`, so a class written with `def init(self, ...)` — the spelling
    // used by ~190 of the bundled examples — silently constructed an instance
    // with no fields set: attributes read back as none, not an error.
    static bool is_ctor_name(const std::string& n) {
        return n=="__init__" || n=="init";
    }
    // Positional + keyword arguments bound to a code object's parameters
    // (*rest, **kw, defaults), as locals for exec_code_bound.
    VMMap bind_kw_locals(const std::shared_ptr<VMCode>& code, const std::vector<VMVal>& all_args, const VMVal& kwargs_map) {
        auto& pnames=code->param_names;
        int n_pos=(int)all_args.size(), arg_idx=0;
        VMMap locs;
        for(int pi=0;pi<(int)pnames.size();pi++){
            const std::string& pn=pnames[pi];
            if(pn.size()>=2&&pn[0]=='*'&&pn[1]=='*'){ locs[pn.substr(2)]=kwargs_map; arg_idx=n_pos; }
            else if(!pn.empty()&&pn[0]=='*'){ std::vector<VMVal> rest(all_args.begin()+arg_idx,all_args.end()); locs[pn.substr(1)]=VMVal::make_list(std::move(rest)); arg_idx=n_pos; }
            else if(arg_idx<n_pos) locs[pn]=all_args[arg_idx++];
            else if(kwargs_map.map&&kwargs_map.map->count(pn)) locs[pn]=kwargs_map.map->at(pn);
            else if(pi<(int)code->param_defaults.size()&&code->param_defaults[pi].type!=VMType::UNDEFINED) locs[pn]=code->param_defaults[pi];
            else locs[pn]=VMVal::make_none();
        }
        return locs;
    }
    // The user-defined function obj.method(...) runs, with its self and
    // closure, following vm_call_method's lookup order; false for builtin
    // methods (str/list/map/natives), which take keyword arguments as a
    // trailing "__kwargs__" map instead. May drop a leading self from args
    // (Class.method(self, ...)).
    bool resolve_user_method(const VMVal& obj, const std::string& method, std::vector<VMVal>& args,
                             std::shared_ptr<VMCode>& code, std::optional<VMVal>& self, std::shared_ptr<VMMap>& env) {
        if(obj.type==VMType::SUPER_PROXY){
            VMVal self_v=(!obj.list||obj.list->empty())?VMVal::make_none():(*obj.list)[0];
            std::string cls=obj.s;
            while(!cls.empty()){
                auto cit=class_reg_.find(cls);
                if(cit==class_reg_.end()) break;
                for(auto& sub:cit->second->sub_codes)
                    if(sub->name==method&&!sub->is_class){ code=sub; self=self_v; return true; }
                cls=cit->second->parent_class;
            }
            return false;
        }
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(method);
            if(it!=obj.map->end()){
                const VMVal& held=it->second;
                if(held.type==VMType::FUNCTION&&held.code){
                    code=held.code; env=held.closure_env; self=obj;
                    return true;
                }
                return false;
            }
        }
        if(obj.type==VMType::INSTANCE){
            std::string cls=obj.class_name;
            while(!cls.empty()){
                auto cit=class_reg_.find(cls);
                if(cit==class_reg_.end()) break;
                for(auto& sub:cit->second->sub_codes)
                    if(sub->name==method&&!sub->is_class){ code=sub; self=obj; return true; }
                cls=cit->second->parent_class;
            }
            return false;
        }
        if(obj.type==VMType::CLASS&&obj.code){
            for(auto& sub:obj.code->sub_codes){
                if(sub->name==method&&!sub->is_class){
                    code=sub;
                    if(!args.empty()&&(args[0].type==VMType::INSTANCE||args[0].type==VMType::MAP)){
                        self=args[0]; args.erase(args.begin());
                    } else self=VMVal::make_none();
                    return true;
                }
            }
        }
        return false;
    }

    // Members every plain value answers: an operator used as a method name
    // (1.+(2, 3) is 1 + 2 + 3; a comparison chains, 1.<(2, 3) is 1 < 2 < 3)
    // and the object protocol's class_name / type_name / to_string. The
    // interpreter's primitiveMember is the same.
    static int operator_member_code(const std::string& m) {
        if(m.empty()||std::isalnum((unsigned char)m[0])||m[0]=='_') return 0;   // every ordinary method
        static const std::unordered_map<std::string,int> ops={
            {"+",nypy::A_ADD},{"-",nypy::A_SUB},{"*",nypy::A_MUL},{"/",nypy::A_DIV},{"//",nypy::A_FLOORDIV},
            {"\\",nypy::A_FLOORDIV},{"%",nypy::A_MOD},{"**",nypy::A_POW},{"&",nypy::A_AND},{"|",nypy::A_OR},
            {"^",nypy::A_XOR},{"<<",nypy::A_LSHIFT},{">>",nypy::A_RSHIFT},
            {"==",100},{"!=",101},{"<",102},{"<=",103},{">",104},{">=",105}};
        auto it=ops.find(m);
        return it==ops.end()?0:it->second;
    }
    bool primitive_member(const VMVal& obj, const std::string& m, std::vector<VMVal>& args, VMVal& out) {
        switch(obj.type){
            case VMType::INT: case VMType::FLOAT: case VMType::BOOL: case VMType::NONE:
            case VMType::STRING: case VMType::LIST: break;
            default: return false;
        }
        if(int op=operator_member_code(m)){
            if(args.empty())
                raise_native_exception("TypeError",vm_type_name(obj)+"."+m+"() takes at least 1 argument (0 given)");
            if(op<100){
                VMVal acc=obj;
                for(auto& a:args) acc=binop(op,acc,a);
                out=acc; return true;
            }
            VMVal l=obj;
            for(auto& r:args){
                bool ok=op==100?l==r:op==101?l!=r:op==102?l<r:op==103?l<=r:op==104?l>r:l>=r;
                if(!ok){ out=VMVal::make_bool(false); return true; }
                l=r;
            }
            out=VMVal::make_bool(true); return true;
        }
        if(m=="class_name"||m=="type_name"){ out=VMVal::make_str(vm_type_name(obj)); return true; }
        if(m=="to_string"){ out=VMVal::make_str(vm_str(obj)); return true; }
        return false;
    }

    VMVal vm_call_method(VMVal obj, const std::string& method, std::vector<VMVal>& args) {
        {
            VMVal pm;
            if(primitive_member(obj,method,args,pm)) return pm;
        }
        // SUPER_PROXY: call method on parent class with self
        if(obj.type==VMType::SUPER_PROXY){
            std::string parent=obj.s;
            VMVal self_v=(!obj.list||obj.list->empty())?VMVal::make_none():(*obj.list)[0];
            std::string cls=parent;
            while(!cls.empty()){
                auto cit=class_reg_.find(cls);
                if(cit==class_reg_.end()) break;
                for(auto& sub:cit->second->sub_codes)
                    if(sub->name==method&&!sub->is_class) return exec_code(sub,args,self_v);
                cls=cit->second->parent_class;
            }
            return VMVal::make_none();
        }
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(method);
            if(it!=obj.map->end()){
                VMVal& held=it->second;
                // A callable stored in an attribute, e.g. self.cb = other.method
                // then self.cb(a, b). A bound method carries its own instance,
                // so it must go through vm_call rather than being re-bound to
                // the object that happens to hold it; natives take no self at
                // all. Only a bare FUNCTION keeps the historical behaviour of
                // being treated as a method of this object.
                if(held.type==VMType::MAP&&held.class_name=="__bound_method__")
                    return vm_call(held,args,std::nullopt);
                if(held.type==VMType::NATIVE)
                    return vm_call(held,args,std::nullopt);
                if(held.type==VMType::FUNCTION)
                    // held.closure_env must come along too, or a closure
                    // stored in an attribute and invoked as obj.attr()
                    // silently loses every captured variable (they read
                    // back as none) the moment it's called this way instead
                    // of via a plain local reference (`f = obj.attr; f()`,
                    // which already passed callee.closure_env correctly).
                    return exec_code(held.code,args,obj,held.closure_env);
            }
        }
        if(obj.type==VMType::INSTANCE){
            std::string cls=obj.class_name;
            while(!cls.empty()){
                auto cit=class_reg_.find(cls);
                if(cit==class_reg_.end()) break;
                for(auto& sub:cit->second->sub_codes)
                    if(sub->name==method&&!sub->is_class) return exec_code(sub,args,obj);
                cls=cit->second->parent_class;
            }
            // Universal object protocol — mirrors NythonExecutor::objectProtocol
            // on the interpreter (see test_25_object_protocol.ny, which probes
            // for support and skipped here because the VM had none of this).
            // Only reached once no user-defined method/attribute of this name
            // was found above, so a class's own to_string/class_name etc, if
            // it defines one, still wins.
            if(method=="class_name"||method=="type_name")
                return VMVal::make_str(obj.class_name);
            if(method=="to_string"||method=="str")
                return VMVal::make_str("<"+obj.class_name+" instance>");
            if(method=="id"){
                uintptr_t raw=obj.map?(uintptr_t)obj.map.get():0;
                return VMVal::make_int((int64_t)(raw & 0x7fffffffffffffffULL));
            }
            if(method=="hash"){
                uintptr_t raw=obj.map?(uintptr_t)obj.map.get():0;
                uint64_t h=std::hash<std::string>{}(obj.class_name+"|"+std::to_string(raw));
                return VMVal::make_int((int64_t)(h & 0x7fffffffffffffffULL));
            }
            if(method=="is_a"||method=="instance_of"){
                if(args.empty()) return VMVal::make_bool(false);
                std::string want=args[0].to_string();
                std::string cur=obj.class_name;
                int guard=0;
                while(!cur.empty()&&guard++<64){
                    if(cur==want) return VMVal::make_bool(true);
                    auto cit=class_reg_.find(cur);
                    if(cit==class_reg_.end()) break;
                    cur=cit->second->parent_class;
                }
                return VMVal::make_bool(false);
            }
            if(method=="equals_to"||method=="same_as"){
                if(args.empty()||args[0].type!=VMType::INSTANCE) return VMVal::make_bool(false);
                return VMVal::make_bool(obj.map.get()==args[0].map.get());
            }
            if(method=="fields"||method=="attributes"){
                std::vector<VMVal> r;
                if(obj.map) for(auto& kv:*obj.map) r.push_back(VMVal::make_str(kv.first));
                return VMVal::make_list(std::move(r));
            }
        }
        // CLASS.method(self, args...) — parent class method call pattern
        // e.g. Animal.__init__(self, name) → args[0] is the instance, args[1:] are method args
        if(obj.type==VMType::CLASS&&obj.code){
            for(auto& sub:obj.code->sub_codes){
                if(sub->name==method&&!sub->is_class){
                    // Extract self from first arg if args[0] is an instance
                    if(!args.empty()&&(args[0].type==VMType::INSTANCE||args[0].type==VMType::MAP)){
                        VMVal self_val=args[0];
                        std::vector<VMVal> rest(args.begin()+1,args.end());
                        return exec_code(sub,rest,self_val);
                    }
                    return exec_code(sub,args,std::nullopt);
                }
            }
        }
        if(obj.type==VMType::STRING) return call_str_method(obj,method,args);
        if(obj.type==VMType::LIST)   return call_list_method(obj,method,args);
        if(obj.type==VMType::MAP){
            // A map member that is itself callable — a class or function held in
            // a namespace, as `import "m" as ns` produces — must be CALLED, not
            // treated as a dictionary operation. Without this, ns.SomeClass(9)
            // fell through to call_map_method, found no map method of that name
            // and returned none, while `var c = ns.SomeClass` then `c(9)`
            // worked: the same call spelled two ways behaved differently.
            if(obj.map){
                auto mit=obj.map->find(method);
                if(mit!=obj.map->end()){
                    const VMVal& member=mit->second;
                    if(member.type==VMType::CLASS||member.type==VMType::FUNCTION
                       ||member.type==VMType::NATIVE)
                        return vm_call(member,args,std::nullopt);
                }
            }
            return call_map_method(obj,method,args);
        }
        // CLASS type: support nested class instantiation via CALL_METHOD (e.g. Outer.Inner(v))
        if(obj.type==VMType::CLASS){
            VMVal nested = get_attr(obj, method);
            if(nested.type == VMType::CLASS) return vm_call(nested, args, std::nullopt);
            // Static method call
            if(nested.type == VMType::FUNCTION && nested.code)
                return exec_code(nested.code, args, VMVal::make_none());
        }
        // A builtin used as a namespace: `import time` then time.time(),
        // time.sleep(1), time.monotonic() - the builtin time_X, else X.
        if(obj.type==VMType::NATIVE&&obj.class_name.rfind("__builtin__:",0)==0){
            std::string target=nyrt::builtin_member(obj.class_name.substr(12),method,
                [&](const std::string& n){ return bridge_exists()&&bridge_exists()(n); });
            if(!target.empty()){
                VMVal fn=load_var(target);
                if(fn.type==VMType::NATIVE) return fn.native(args);
            }
            return VMVal::make_none();
        }
        // Fallback: check globals
        auto git=globals_.find(method);
        if(git!=globals_.end()&&git->second.type==VMType::NATIVE)
            return git->second.native(args);
        return VMVal::make_none();
    }

    // dict methods, typed keys (vkey / vm_key_value), as the interpreter's
    // dictMethod.
    VMVal call_map_method(VMVal obj, const std::string& m, std::vector<VMVal>& a) {
        if(!obj.map) return VMVal::make_none();
        auto& mp=*obj.map;
        VMVal kw=take_kwargs(a);
        auto need=[&](size_t lo,size_t hi){
            if(a.size()<lo||a.size()>hi) raise_native_exception("TypeError",m+"() takes "+(lo==hi?"exactly "+std::to_string(lo):"at most "+std::to_string(hi))+" argument"+(hi==1?"":"s")+" ("+std::to_string(a.size())+" given)");
        };
        if(m=="size"||m=="length"||m=="__len__"){
            int64_t n=0; for(auto& kv:mp) if(!vm_internal_key(kv.first)) n++;
            return VMVal::make_int(n);
        }
        if(m=="keys"||m=="values"||m=="items"||m=="entries"){
            std::vector<VMVal> r;
            for(auto& [k,v]:mp){
                if(vm_internal_key(k)) continue;
                if(m=="keys") r.push_back(vm_key_value(k));
                else if(m=="values") r.push_back(v);
                else r.push_back(VMVal::make_tuple({vm_key_value(k),v}));
            }
            return VMVal::make_list(std::move(r));
        }
        if(m=="get"){
            need(1,2);
            auto it=mp.find(vkey(a[0]));
            if(it!=mp.end()) return it->second;
            return a.size()>=2?a[1]:VMVal::make_none();
        }
        if(m=="has"||m=="contains"||m=="has_key"||m=="containsKey"){
            need(1,1);
            return VMVal::make_bool(mp.count(vkey(a[0]))>0);
        }
        if(m=="pop"){
            need(1,2);
            std::string key=vkey(a[0]);
            auto it=mp.find(key);
            if(it==mp.end()){
                if(a.size()>=2) return a[1];
                raise_native_exception("KeyError",a[0].repr());
            }
            VMVal v=it->second; mp.erase(key); return v;
        }
        // Nython's map.remove(key[, default]) / delete: erase and return.
        if(m=="remove"||m=="delete"){
            if(a.empty()) return VMVal::make_none();
            std::string key=vkey(a[0]);
            auto it=mp.find(key);
            if(it==mp.end()) return a.size()>=2?a[1]:VMVal::make_none();
            VMVal v=it->second; mp.erase(key); return v;
        }
        if(m=="popitem"){
            std::string last; bool found=false;
            for(auto& kv:mp) if(!vm_internal_key(kv.first)){ last=kv.first; found=true; }
            if(!found) raise_native_exception("KeyError","'popitem(): dictionary is empty'");
            VMVal item=VMVal::make_tuple({vm_key_value(last),mp[last]});
            mp.erase(last); return item;
        }
        if(m=="update"||m=="merge"){
            if(!a.empty()){
                if(a[0].type==VMType::MAP&&a[0].map){ for(auto& [k,v]:*a[0].map) if(!vm_internal_key(k)) mp[k]=v; }
                else for(auto& pr:iter_items(a[0])){
                    std::vector<VMVal> kv=iter_items(pr);
                    if(kv.size()!=2) raise_native_exception("ValueError","dictionary update sequence element has length "+std::to_string(kv.size())+"; 2 is required");
                    mp[vkey(kv[0])]=kv[1];
                }
            }
            if(kw.map) for(auto& [k,v]:*kw.map) mp[k]=v;
            return m=="merge"?obj:VMVal::make_none();
        }
        if(m=="clear"){
            std::vector<std::pair<std::string,VMVal>> keep;
            for(auto& kv:mp) if(vm_internal_key(kv.first)) keep.push_back(kv);
            mp.clear();
            for(auto& kv:keep) mp[kv.first]=kv.second;
            return VMVal::make_none();
        }
        // A copy, not the same dict (the copy used to alias the original).
        if(m=="copy"){ VMVal c=VMVal::make_map(); *c.map=mp; return c; }
        if(m=="setdefault"){
            need(1,2);
            std::string key=vkey(a[0]);
            auto it=mp.find(key);
            if(it!=mp.end()) return it->second;
            VMVal d=a.size()>=2?a[1]:VMVal::make_none();
            mp[key]=d; return d;
        }
        return VMVal::make_none();
    }


    // ── Import system ───────────────────────────────────────────────────────
    void vm_import(const std::string& raw_name_in) {
        std::string tried_paths;
        // Split the alias the compiler appended, if any.
        std::string raw_name = raw_name_in;
        std::string alias;
        size_t sep = raw_name.find('\x01');
        if(sep != std::string::npos){
            alias = raw_name.substr(sep + 1);
            raw_name = raw_name.substr(0, sep);
        }
        std::string name = raw_name;
        if(name.size()>=2&&(name[0]=='"'||name[0]=='\'')){
            name=name.substr(1,name.size()-2);
        }
        std::string guard_key = "__imported_"+name;
        // An aliased import must still run so its namespace can be built, even
        // if the module was already loaded — otherwise the name diff sees
        // nothing and the alias is empty. Matches the interpreter.
        if(globals_.count(guard_key) && alias.empty()) return;
        globals_[guard_key] = VMVal::make_bool(true);
        if(name=="nytorch"){ register_nytorch_builtins(); return; }
        // "nytorch_classes" used to sit in builtin_modules below - a no-op
        // acknowledgement, on the theory its functions were "already
        // registered as globals". That's true of the native tensor_* ops
        // (register_nytorch_builtins), but the class library itself
        // (Tensor, and everything built on it, in lib/nytorch.ny) was never
        // actually loaded, so `Tensor(...)` read as an undefined name on
        // this engine while the interpreter's own `nytorch_classes` handler
        // (NythonExecutor.hpp) really does load lib/nytorch.ny. Falling
        // through to the normal file-import path below (via filepath) does
        // the same here; the VM's shared_ptr-backed containers don't have
        // the interpreter's container-leak problem that made loading this
        // 220+-class file risky there (see GC_NOTES.md).
        if(name=="nytorch_classes"){ register_nytorch_builtins(); }
        // os/shell/time/io: their functions are the interpreter's, reached
        // through the builtin bridge - one implementation for both engines.
        // These imports used to install VM copies that differed (time_ms()
        // in seconds, sleep(0.5) not sleeping, shell() returning a wait
        // status); now they are acknowledgements only.
        if(name=="os"){ define_os_module(alias.empty()?std::string("os"):alias); return; }
        if(name=="shell"||name=="sh"){ return; }
        if(name=="sys"){ define_sys_module(alias.empty()?std::string("sys"):alias); return; }
        if(name=="math"){ register_math_builtins(); return; }
        if(name=="time"){ return; }
        if(name=="json"){ register_json_builtins(); return; }
        if(name=="io"||name=="fs"||name=="file"){ return; }
        if(name=="string"){
            globals_["isdigit_str"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
                return VMVal::make_bool(!a.empty()&&!a[0].s.empty()&&std::all_of(a[0].s.begin(),a[0].s.end(),::isdigit));});
            globals_["isalpha_str"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
                return VMVal::make_bool(!a.empty()&&!a[0].s.empty()&&std::all_of(a[0].s.begin(),a[0].s.end(),::isalpha));});
            return;
        }
        // Builtin module names that resolve to no file. The interpreter knows
        // 40 of these; the VM knew 14, so `import random` reached the file
        // lookup and — once that started reporting failures instead of
        // returning silently — became a hard error on one engine only. The
        // functions themselves are already registered as globals; the import is
        // just an acknowledgement.
        static const std::set<std::string> builtin_modules = {
            "random","collections","crypto","datetime","hash","http","re","regex",
            "sys","ml","ai","net","agent_net","threading",
            "thread","threads","threading_lib","string","math","time","json",
            "io","fs","file","os","sh","shell","gui","stdlib","oslib","os_lib",
            "netlib","network_lib","sockets","webserver","httpserver",
            "clientserver","cs_lib","aiagent","nyxai","nyx","nytorch"
        };

        static const std::unordered_map<std::string,std::string> lib_map = {
            {"stdlib","lib/stdlib.ny"},{"oslib","lib/os.ny"},{"os_lib","lib/os.ny"},
            {"network_lib","lib/network.ny"},{"netlib","lib/network.ny"},
            {"sockets","lib/sockets.ny"},{"webserver","lib/webserver.ny"},
            {"httpserver","lib/webserver.ny"},{"threads","lib/thread.ny"},
            {"threading_lib","lib/thread.ny"},{"clientserver","lib/clientserver.ny"},
            {"cs_lib","lib/clientserver.ny"},{"gui","lib/gui.ny"},
            {"aiagent","lib/aiagent.ny"},{"nyxai","lib/aiagent.ny"},{"nyx","lib/aiagent.ny"},
            {"nytorch_classes","lib/nytorch.ny"},
        };
        // Ancestors of the script's directory, nearest first. Library files
        // name each other relative to the project root ("lib/nytorch.ny"), so
        // running from any other working directory needs these. Tried after
        // every existing candidate, matching the interpreter's
        // ancestorCandidates().
        auto ancestors=[&](const std::string& rel){
            std::vector<std::string> out;
            std::string d=script_dir_;
#ifndef _WIN32
            char rb[4096];
            if(!d.empty() && realpath(d.c_str(),rb)) d=std::string(rb)+"/";
#endif
            for(int up=0;up<4;++up){
                while(d.size()>1&&(d.back()=='/'||d.back()=='\\')) d.pop_back();
                size_t cut=d.find_last_of("/\\");
                if(cut==std::string::npos) break;
                d=d.substr(0,cut+1);
                out.push_back(d+rel);
            }
            return out;
        };
        std::string filepath;
        auto it=lib_map.find(name);
        if(it!=lib_map.end()){
            filepath=it->second;
            struct stat lst;
            if(::stat(filepath.c_str(),&lst)!=0){
                std::vector<std::string> alt={script_dir_+filepath};
                for(auto& c:ancestors(filepath)) alt.push_back(c);
                for(auto& c:alt){ if(::stat(c.c_str(),&lst)==0){ filepath=c; break; } }
            }
        }
        if(filepath.empty()){
            std::vector<std::string> paths={
                // The importing script's own directory first, matching the
                // interpreter. Without it `import "mylib"` resolved on one
                // engine and not the other — the same file, the same import,
                // two different answers.
                script_dir_+name+".ny", script_dir_+name, script_dir_+"lib/"+name+".ny",
                name+".ny",name,"./"+name+".ny",
                cwd_+"/"+name+".ny","lib/"+name+".ny","./lib/"+name+".ny",
                cwd_+"/lib/"+name+".ny",
            };
            for(auto& c:ancestors(name+".ny")) paths.push_back(c);
            for(auto& c:ancestors(name)) paths.push_back(c);
            for(auto& p:paths){struct stat st;if(::stat(p.c_str(),&st)==0){filepath=p;break;}}
            // Kept for the error message below; `paths` goes out of scope here.
            for(size_t i=0;i<paths.size();++i){ if(i) tried_paths+=", "; tried_paths+=paths[i]; }
        }
        // A module that cannot be found used to return silently, so every name
        // it would have defined failed later with no hint that the import was
        // the cause. Matches the interpreter's ImportError, including the list
        // of paths tried — the two engines must agree on what is an error.
        if(filepath.empty()){
            // A builtin module has no file and that is not an error.
            if(builtin_modules.count(name)) return;
            // std::runtime_error, not std::string: the VM's try/except handler
            // catches what Op::RAISE throws, which is runtime_error. Throwing a
            // std::string unwound straight out of run_loop, so an import error
            // was uncatchable on this engine while the interpreter caught it.
            throw std::runtime_error("__exc__:ImportError:cannot find module \"" + raw_name
                                     + "\" (looked in: " + tried_paths + ")");
        }
        try {
            auto source=nython::reader::SourceCode(filepath);
            auto reporter=std::make_shared<nython::exception::Reporter>(source);
            auto lx=std::make_shared<nython::lexer::Lexer>(source);
            lx->tokenize();
            auto pr=std::make_shared<nython::parser::Parser>(reporter.get(),(nython::Runnable*)this,lx.get());
            auto ast=pr->parse();
            if(!ast) return;
            Compiler c; auto code=c.compile(ast);
            bool old_exp=export_to_globals_; export_to_globals_=true;
            // Snapshot the global names so the alias namespace can be built from
            // whatever the module adds, matching the interpreter.
            // The module's OWN top-level names, read from its AST. Diffing
            // globals_ before and after fails when the module was already
            // loaded — `import "m"` then `import "m" as x` adds nothing new, so
            // the namespace came out empty. Reading declarations directly is
            // independent of what is already defined.
            std::set<std::string> own_names;
            if(!alias.empty() && ast){
                for(auto& st : ast->statements()){
                    if(!st) continue;
                    if(st->type()==nython::node::NodeType::FUNCTION)
                        own_names.insert(std::static_pointer_cast<nython::node::FunctionNode>(st)->name);
                    else if(st->type()==nython::node::NodeType::CLASS)
                        own_names.insert(std::static_pointer_cast<nython::node::ClassNode>(st)->name);
                    else if(st->type()==nython::node::NodeType::VARIABLE_DECL)
                        own_names.insert(std::static_pointer_cast<nython::node::VarDeclNode>(st)->name);
                }
            }
            // __name__ / __file__ are the module's own while its top level
            // runs, so `if __name__ == "__main__":` does not fire on import.
            VMVal prev_name=globals_.count("__name__")?globals_["__name__"]:VMVal::make_str("__main__");
            VMVal prev_file=globals_.count("__file__")?globals_["__file__"]:VMVal::make_str("");
            {
                std::string stem=filepath;
                size_t cut=stem.find_last_of("/\\");
                if(cut!=std::string::npos) stem=stem.substr(cut+1);
                if(stem.size()>3&&stem.compare(stem.size()-3,3,".ny")==0) stem=stem.substr(0,stem.size()-3);
                globals_["__name__"]=VMVal::make_str(stem);
                globals_["__file__"]=VMVal::make_str(filepath);
            }
            try{ exec_code(code,{},std::nullopt); } catch(VMReturn&){}
              catch(std::exception& e){ std::cerr<<"[VM import error] "<<filepath<<": "<<e.what()<<"\n"; }
            globals_["__name__"]=prev_name;
            globals_["__file__"]=prev_file;
            export_to_globals_=old_exp;
            if(!alias.empty()){
                auto ns=std::make_shared<VMMap>();
                for(const auto& n : own_names){
                    auto it=globals_.find(n);
                    if(it!=globals_.end()){ (*ns)[n]=it->second; continue; }
                    // Classes are not ordinary globals on this engine: they live
                    // in class_reg_. Without this the alias exposed a module's
                    // functions and vars but silently omitted its classes.
                    auto cit=class_reg_.find(n);
                    if(cit!=class_reg_.end()){
                        VMVal cv=VMVal::make_class(cit->second, n);
                        (*ns)[n]=cv;
                    }
                }
                VMVal nsv=VMVal::make_map();
                nsv.map=ns;
                nsv.class_name=alias;
                globals_[alias]=nsv;
            }
            // Register classes from the imported module
            for(auto& sub:code->sub_codes) {
                if(sub->is_class) { class_reg_[sub->name]=sub; }
                else {
                    // Functions defined at module level are already in globals_ via DEFINE_NAME
                    // But their code objects need to be in class_reg for method dispatch
                    // Sub-codes of the module that are classes (nested under functions) need registration
                    for(auto& ssub:sub->sub_codes) if(ssub->is_class) class_reg_[ssub->name]=ssub;
                }
            }

        } catch(std::exception& e){ std::cerr<<"[VM import parse error] "<<name<<": "<<e.what()<<"\n"; }
    }

    // Safe list accessor for the tensor builtins.
    //
    // Several of them guarded only a[0] and then dereferenced a[1].list. When an
    // argument was none — which happens whenever an earlier tensor call returned
    // none, e.g. a builtin the VM does not implement — that was a null
    // dereference and the process segfaulted. Returning an empty list makes the
    // operation degrade instead of crashing.
    static std::vector<VMVal>& vm_arg_list(std::vector<VMVal>& a, size_t i) {
        static std::vector<VMVal> s_empty;
        if(i < a.size() && a[i].type == VMType::LIST && a[i].list) return *a[i].list;
        s_empty.clear();
        return s_empty;
    }

    // ── Shared tensor natives (include/NyTensor.hpp) ─────────────────────────
    // Every tensor native is implemented once, in src/builtins/nytensor.cpp,
    // and served to BOTH engines through a thin value adapter — this one for
    // the VM, dispatch_nt() in src/builtins/tensor.cpp for the interpreter —
    // so the two can no longer drift apart. The VM used to carry its own
    // copies here, several of them stubs (matmul returned [], transpose,
    // attention, batch_norm and dropout returned their input, ctc_loss was
    // the constant 2.5); those are gone.
    static nt::Val vm_to_nt(const VMVal& v, int depth) {
        switch (v.type) {
            case VMType::NONE:   return nt::Val::none();
            case VMType::BOOL:   return nt::Val::boolean(v.b);
            case VMType::INT:    return nt::Val::integer(v.i);
            case VMType::FLOAT:  return nt::Val::num(v.d);
            case VMType::STRING: return nt::Val::str(v.s);
            case VMType::LIST: {
                if (!v.list) return nt::Val::vec({});
                const auto& L = *v.list;
                bool allnum = true, allint = true;
                for (auto& e : L) {
                    if (e.type == VMType::FLOAT) allint = false;
                    else if (e.type != VMType::INT && e.type != VMType::BOOL) { allnum = false; break; }
                }
                if (allnum) {
                    std::vector<double> d(L.size());
                    for (size_t i = 0; i < L.size(); i++)
                        d[i] = L[i].type == VMType::FLOAT ? L[i].d : L[i].type == VMType::INT ? (double)L[i].i : (L[i].b ? 1.0 : 0.0);
                    return nt::Val::vec(std::move(d), allint);
                }
                if (depth > 64) throw std::runtime_error("ValueError: list nesting is too deep for a tensor");
                std::vector<nt::Val> items;
                items.reserve(L.size());
                for (auto& e : L) items.push_back(vm_to_nt(e, depth + 1));
                return nt::Val::list(std::move(items));
            }
            default: return nt::Val::none();
        }
    }
    static VMVal nt_to_vm(nt::Val& v) {
        switch (v.k) {
            case nt::Val::NONE:  return VMVal::make_none();
            case nt::Val::BOOL:  return VMVal::make_bool(v.b);
            case nt::Val::INT:   return VMVal::make_int(v.i);
            case nt::Val::FLOAT: return VMVal::make_float(v.d);
            case nt::Val::STR:   return VMVal::make_str(std::move(v.s));
            case nt::Val::VEC: {
                std::vector<VMVal> r;
                r.reserve(v.v.size());
                if (v.v_int) for (double x : v.v) r.push_back(VMVal::make_int((int64_t)x));
                else for (double x : v.v) r.push_back(VMVal::make_float(x));
                return VMVal::make_list(std::move(r));
            }
            case nt::Val::LIST: {
                std::vector<VMVal> r;
                r.reserve(v.items.size());
                for (auto& e : v.items) r.push_back(nt_to_vm(e));
                return VMVal::make_list(std::move(r));
            }
        }
        return VMVal::make_none();
    }
    void register_nt_natives() {
        for (const auto& name : nt::names()) {
            const nt::Op* op = nt::find(name);
            globals_[name] = VMVal::make_native([this, op](std::vector<VMVal>& a) -> VMVal {
                size_t n = a.size();
                if (n && a.back().type == VMType::MAP) n--;          // keyword-argument map: not used
                std::vector<nt::Val> args;
                args.reserve(n);
                for (size_t i = 0; i < n; i++) args.push_back(vm_to_nt(a[i], 0));
                nt::Val r;
                try {
                    r = op->fn(args);
                } catch (nt::Error& e) {
                    // A typed instance, so `except ValueError as e:` matches
                    // (a bare runtime_error only reaches untyped handlers).
                    auto attrs = std::make_shared<VMMap>();
                    (*attrs)["msg"] = VMVal::make_str(e.msg);
                    (*attrs)["args"] = VMVal::make_list({VMVal::make_str(e.msg)});
                    last_exception_obj_ = VMVal::make_instance(e.type, attrs);
                    throw std::runtime_error(e.type + ": " + e.msg);
                }
                for (int k : op->mutates) {
                    if (k >= (int)n || args[k].k != nt::Val::VEC) continue;
                    if (a[k].type != VMType::LIST || !a[k].list) continue;
                    auto& L = *a[k].list;                 // the caller's list, updated in place
                    L.resize(args[k].v.size());
                    for (size_t i = 0; i < L.size(); i++) L[i] = VMVal::make_float(args[k].v[i]);
                }
                return nt_to_vm(r);
            });
        }
    }

    void register_nytorch_builtins() {
        globals_["exp"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::exp(to_d(a.empty()?VMVal::make_int(0):a[0])));});
        globals_["log"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::log(to_d(a.empty()?VMVal::make_int(1):a[0])));});
        // These four read a[0] with no arity check, so sin()/cos()/tan()/tanh()
        // with no argument indexed past the end of an empty vector. VMVal holds
        // a std::string, so the garbage read faulted rather than returning junk:
        // a hard segfault of the VM. Their neighbours (exp, log, relu, sigmoid,
        // atan2) all guard, so this was an oversight, not a convention.
        globals_["sin"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::sin(a.empty()?0.0:to_d(a[0])));});
        globals_["cos"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::cos(a.empty()?0.0:to_d(a[0])));});
        globals_["tan"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::tan(a.empty()?0.0:to_d(a[0])));});
        globals_["tanh"]=globals_["tanh_fn"]=globals_["tanh_act"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::tanh(a.empty()?0.0:to_d(a[0])));});
        globals_["atan2"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{double y=a.size()>0?to_d(a[0]):0,x=a.size()>1?to_d(a[1]):1;return VMVal::make_float(std::atan2(y,x));});
        globals_["relu"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{double v=to_d(a.empty()?VMVal::make_int(0):a[0]);return VMVal::make_float(v>0?v:0);});
        globals_["sigmoid"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{double v=to_d(a.empty()?VMVal::make_int(0):a[0]);return VMVal::make_float(1.0/(1.0+std::exp(-v)));});
        globals_["leaky_relu"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            double x=to_d(a.empty()?VMVal::make_int(0):a[0]);double alpha=a.size()>1?to_d(a[1]):0.01;return VMVal::make_float(x>0?x:alpha*x);});
        globals_["tensor_apply"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::LIST||!a[0].list)return a.empty()?VMVal::make_list():a[0];
            std::vector<VMVal> r;
            for(auto& v:vm_arg_list(a,0)){
                std::vector<VMVal> args={v};
                if(a[1].type==VMType::NATIVE)r.push_back(a[1].native(args));
                else if(a[1].type==VMType::FUNCTION&&a[1].code)
                    r.push_back(this->vm_call(a[1],args,std::nullopt));
                else r.push_back(v);
            }
            return VMVal::make_list(std::move(r));});

        // clamp(value, lo, hi) is the scalar builtin (see the interpreter's
        // clamp in src/builtins/tensor.cpp) - a different function from
        // tensor_clip, which clips every element of a LIST. These used to
        // be aliased to the same tensor_clip native, so clamp(-5, 0, 10)
        // hit tensor_clip's "a[0] must be a LIST" guard and returned [].
        globals_["clamp"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3) return a.empty()?VMVal::make_none():a[0];
            double v=to_d(a[0]),lo=to_d(a[1]),hi=to_d(a[2]);
            if(v<lo) v=lo;
            if(v>hi) v=hi;
            if(a[0].type==VMType::INT) return VMVal::make_int((int64_t)v);
            return VMVal::make_float(v);});
        globals_["tensor_where"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3)return VMVal::make_list();
            // tensor_where(cond_list, x_list, y_list)
            if(a[0].type==VMType::LIST&&a[1].type==VMType::LIST&&a[2].type==VMType::LIST&&a[0].list&&a[1].list&&a[2].list){
                int n=(int)std::min({vm_arg_list(a,0).size(),vm_arg_list(a,1).size(),vm_arg_list(a,2).size()});
                std::vector<VMVal> r;
                for(int i=0;i<n;i++) r.push_back(to_d((vm_arg_list(a,0))[i])!=0.0?(vm_arg_list(a,1))[i]:(vm_arg_list(a,2))[i]);
                return VMVal::make_list(std::move(r));}
            return VMVal::make_list();});
        globals_["tensor_concat"]=globals_["tensor_cat"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            std::vector<VMVal> r;
            for(auto& x:a){if(x.type==VMType::LIST&&x.list)for(auto& v:*x.list)r.push_back(v);}
            return VMVal::make_list(std::move(r));});
        globals_["tensor_flatten"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list)return VMVal::make_list();
            std::vector<VMVal> r;
            std::function<void(const VMVal&)> flat=[&](const VMVal& v){
                if(v.type==VMType::LIST&&v.list){for(auto& x:*v.list)flat(x);}else r.push_back(v);};
            for(auto& x:vm_arg_list(a,0))flat(x); return VMVal::make_list(std::move(r));});
        globals_["softplus"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            double v=a.empty()?0:to_d(a[0]); return VMVal::make_float(std::log(1+std::exp(v)));});
        globals_["mish"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            double v=a.empty()?0:to_d(a[0]); return VMVal::make_float(v*std::tanh(std::log(1+std::exp(v))));});
        // ── device_info() ─────────────────────────────────────────────────────
        globals_["device_info"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            auto m=std::make_shared<VMMap>();
            (*m)["backend"]=VMVal::make_str("cpu");
            (*m)["cpu_cores"]=VMVal::make_int((int64_t)std::max(1u,std::thread::hardware_concurrency()));
            (*m)["gpu_available"]=VMVal::make_bool(false);
            (*m)["gpu_name"]=VMVal::make_str("none");
            (*m)["tpu_available"]=VMVal::make_bool(false);
            (*m)["tpu_count"]=VMVal::make_int(0);
            VMVal r; r.type=VMType::MAP; r.map=m; return r;});
        // time_now/time_ms: os_time.cpp through the bridge. (This copy made
        // time_ms() return SECONDS after `import nytorch`.)
        globals_["tensor_topk"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list)return VMVal::make_list();
            auto& v=vm_arg_list(a,0); int k=(int)v.size();
            if(a.size()>=2)k=std::min((int)to_d(a[1]),(int)v.size());
            std::vector<std::pair<double,int>> iv;
            for(int i=0;i<(int)v.size();i++)iv.push_back({to_d(v[i]),i});
            std::sort(iv.begin(),iv.end(),[](auto& a,auto& b){return a.first>b.first;});
            std::vector<VMVal> r;
            for(int i=0;i<k;i++){
                auto m=std::make_shared<VMMap>();
                (*m)["value"]=VMVal::make_float(iv[i].first);
                (*m)["index"]=VMVal::make_int(iv[i].second);
                VMVal entry; entry.type=VMType::MAP; entry.map=m; r.push_back(entry);}
            return VMVal::make_list(std::move(r));});
        globals_["tensor_flip"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list)return VMVal::make_list();
            std::vector<VMVal> r(a[0].list->rbegin(),a[0].list->rend());
            return VMVal::make_list(std::move(r));});
        globals_["tensor_roll"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list||vm_arg_list(a,0).empty())return VMVal::make_list();
            auto& v=vm_arg_list(a,0); int n=(int)v.size();
            int shift=a.size()>=2?(int)to_d(a[1])%n:1; if(shift<0)shift+=n;
            std::vector<VMVal> r(v.begin()+n-shift,v.end());
            r.insert(r.end(),v.begin(),v.begin()+n-shift);
            return VMVal::make_list(std::move(r));});
        globals_["tensor_unique"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list)return VMVal::make_list();
            std::vector<VMVal> r; std::unordered_set<std::string> seen;
            for(auto& x:vm_arg_list(a,0)){auto k=x.to_string();if(!seen.count(k)){seen.insert(k);r.push_back(x);}}
            return VMVal::make_list(std::move(r));});
        globals_["tensor_repeat"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            int n=a.size()>=2?(int)to_d(a[1]):1;
            std::vector<VMVal> r;
            for(int i=0;i<n;i++) for(auto& v:vm_arg_list(a,0)) r.push_back(v);
            return VMVal::make_list(std::move(r));});
        globals_["tensor_diag"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            int n=(int)vm_arg_list(a,0).size(); std::vector<VMVal> r;
            for(int i=0;i<n;i++) for(int j=0;j<n;j++)
                r.push_back(VMVal::make_float(i==j?to_d((vm_arg_list(a,0))[i]):0.0));
            return VMVal::make_list(std::move(r));});
        // ── rms_norm(x) ─────────────────────────────────────────────────────
        globals_["rms_norm"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list||vm_arg_list(a,0).empty()) return VMVal::make_list();
            auto& v=vm_arg_list(a,0); double s=0;
            for(auto& x:v){double d=to_d(x);s+=d*d;} double rms=std::sqrt(s/v.size())+1e-8;
            std::vector<VMVal> r;
            for(auto& x:v) r.push_back(VMVal::make_float(to_d(x)/rms));
            return VMVal::make_list(std::move(r));});
        // ── hasattr, ord, chr ────────────────────────────────────────────────
        globals_["hasattr"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            std::string attr=a[1].to_string();
            if((a[0].type==VMType::INSTANCE||a[0].type==VMType::MAP)&&a[0].map)
                return VMVal::make_bool(a[0].map->count(attr)>0);
            return VMVal::make_bool(false);});
        globals_["repr"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("none");
            if(a[0].type==VMType::INSTANCE){
                VMVal res=call_dunder(a[0],"__repr__",{});
                if(res.type!=VMType::NONE) return res;
                res=call_dunder(a[0],"__str__",{});
                if(res.type!=VMType::NONE) return res;
            }
            // repr of a string must be quoted; returning to_string() here made
            // repr identical to str(), so repr("abc") gave abc, not "abc".
            if(a[0].type==VMType::STRING){
                std::string q="\"";
                for(char c:a[0].s){
                    if(c=='"'||c=='\\') q+='\\';
                    q+=c;
                }
                return VMVal::make_str(q+"\"");
            }
            return VMVal::make_str(a[0].to_string());
        });
        globals_["getattr"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return a.size()>=3?a[2]:VMVal::make_none();
            VMVal result=get_attr(a[0],a[1].to_string());
            if(result.type==VMType::NONE&&a.size()>=3) return a[2];
            return result;
        });
        globals_["setattr"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3) return VMVal::make_none();
            set_attr(a[0],a[1].to_string(),a[2]);
            return VMVal::make_none();
        });
        globals_["getattr"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return a.size()>=3?a[2]:VMVal::make_none();
            VMVal result=get_attr(a[0],a[1].to_string());
            if(result.type==VMType::NONE&&a.size()>=3) return a[2]; // default
            return result;
        });
        globals_["setattr"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3) return VMVal::make_none();
            set_attr(a[0],a[1].to_string(),a[2]);
            return VMVal::make_none();
        });
        globals_["ord"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].s.empty()) return VMVal::make_int(0);
            return VMVal::make_int((int64_t)(unsigned char)a[0].s[0]);});
        globals_["chr"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            return VMVal::make_str(std::string(1,(char)(int64_t)to_d(a[0])));});
        globals_["sorted"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            VMVal key_fn; bool has_key=false; bool reverse=false;
            // Check kwargs_map passed as last arg by CALL_KW for natives:
            if(!a.empty()&&a.back().type==VMType::MAP&&a.back().map){
                auto& km=*a.back().map;
                if(km.count("key")){key_fn=km["key"];has_key=true;}
                if(km.count("reverse")&&km["reverse"].type==VMType::BOOL) reverse=km["reverse"].b;
                a.pop_back();
            }
            // Fallback: positional key arg:
            if(!has_key&&a.size()>=2&&(a[1].type==VMType::FUNCTION||a[1].type==VMType::NATIVE)){
                key_fn=a[1]; has_key=true;
            }
            if(!reverse&&a.size()>=3&&a[2].type==VMType::BOOL) reverse=a[2].b;
            std::vector<VMVal> lst=(a[0].type==VMType::LIST&&a[0].list)?vm_arg_list(a,0):a;
            // Decorate-sort-undecorate. The key function used to be invoked from
            // inside the comparator, which re-entered the VM while stable_sort
            // held references into the range being sorted — that segfaulted on
            //     sorted(words, key=lambda w: len(w))
            // Computing every key up front removes the re-entrancy, calls the
            // key function n times instead of O(n log n), and guarantees the
            // comparator is consistent even if the key function is impure.
            std::vector<std::pair<VMVal,VMVal>> decorated;
            decorated.reserve(lst.size());
            for(auto& v : lst){
                if(has_key){
                    std::vector<VMVal> kargs={v};
                    std::optional<VMVal> ns=std::nullopt;
                    decorated.emplace_back(vm_call(key_fn,kargs,ns), v);
                } else {
                    decorated.emplace_back(v, v);
                }
            }
            std::stable_sort(decorated.begin(),decorated.end(),
                [&](const std::pair<VMVal,VMVal>& x,const std::pair<VMVal,VMVal>& y){
                    int c2=cmp_val(x.first,y.first);
                    return reverse?c2>0:c2<0;
                });
            std::vector<VMVal> out;
            out.reserve(decorated.size());
            for(auto& d : decorated) out.push_back(d.second);
            return VMVal::make_list(std::move(out));
        });
        globals_["reversed"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            std::vector<VMVal> v(a[0].list->rbegin(),a[0].list->rend());
            return VMVal::make_list(std::move(v));});
        globals_["enumerate"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            int64_t start=0;
            if(a.size()>=2&&a.back().type==VMType::MAP&&a.back().map){
                auto& km=*a.back().map;
                if(km.count("start")){auto& sv=km.at("start");if(sv.type==VMType::INT)start=sv.i;else if(sv.type==VMType::FLOAT)start=(int64_t)to_d(sv);}
                a.pop_back();
            }
            if(a.size()>=2){
                if(a[1].type==VMType::INT) start=a[1].i;
                else if(a[1].type==VMType::FLOAT) start=(int64_t)to_d(a[1]);
            }
            std::vector<VMVal> r;
            for(int i=0;i<(int)vm_arg_list(a,0).size();i++){
                std::vector<VMVal> pair={VMVal::make_int(start+i),(vm_arg_list(a,0))[i]};
                r.push_back(VMVal::make_list(std::move(pair)));}
            return VMVal::make_list(std::move(r));});
        globals_["zip"]=globals_["zip_list"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::LIST||a[1].type!=VMType::LIST||!a[0].list||!a[1].list)
                return VMVal::make_list();
            int n=(int)std::min(vm_arg_list(a,0).size(),vm_arg_list(a,1).size());
            std::vector<VMVal> r;
            for(int i=0;i<n;i++){
                std::vector<VMVal> pair={(vm_arg_list(a,0))[i],(vm_arg_list(a,1))[i]};
                r.push_back(VMVal::make_list(std::move(pair)));}
            return VMVal::make_list(std::move(r));});
        globals_["input"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(!a.empty()) std::cout<<a[0].to_string();
            std::string line; std::getline(std::cin,line);
            return VMVal::make_str(line);});
        globals_["langevin_step"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            // langevin_step(x, grad, step_size) -> x - step_size*grad + noise
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            auto& x=vm_arg_list(a,0); int n=(int)x.size();
            double step=a.size()>=3?to_d(a[2]):0.01;
            std::vector<VMVal> r;
            if(a.size()>=2&&a[1].type==VMType::LIST&&a[1].list&&(int)vm_arg_list(a,1).size()==n){
                auto& g=vm_arg_list(a,1);
                for(int i=0;i<n;i++){
                    double noise=(double)(rand()%1000-500)/50000.0;
                    r.push_back(VMVal::make_float(to_d(x[i])-step*to_d(g[i])+noise));}
            } else { for(auto& v:x) r.push_back(v); }
            return VMVal::make_list(std::move(r));});
        // ── any / all / map / filter / list / set ──────────────────────────
        // ── map / filter (call Nython functions) ────────────────────────
        globals_["next"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            if(a[0].type==VMType::GENERATOR) return gen_next(a[0]);
            if(a[0].type==VMType::INSTANCE){
                VMVal nv;
                try { nv=call_dunder(a[0],"__next__",{}); }
                catch(std::runtime_error&){ return VMVal::make_none(); }
                return nv;
            }
            if(a[0].type!=VMType::ITERATOR||!a[0].iter) return VMVal::make_none();
            auto&[cur,items]=*a[0].iter;
            if(cur>=(int)items.size()) return VMVal::make_none();
            return items[cur++];});
        globals_["map"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[1].type!=VMType::LIST||!a[1].list) return VMVal::make_list();
            std::vector<VMVal> r;
            for(auto& item:vm_arg_list(a,1)){
                std::vector<VMVal> call_args={item};
                r.push_back(this->vm_call(a[0],call_args,std::nullopt));}
            return VMVal::make_list(std::move(r));});
        globals_["filter"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[1].type!=VMType::LIST||!a[1].list) return VMVal::make_list();
            std::vector<VMVal> r;
            for(auto& item:vm_arg_list(a,1)){
                std::vector<VMVal> call_args={item};
                VMVal result=this->vm_call(a[0],call_args,std::nullopt);
                if(result.is_truthy()) r.push_back(item);}
            return VMVal::make_list(std::move(r));});
        globals_["reduce"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[1].type!=VMType::LIST||!a[1].list||vm_arg_list(a,1).empty())
                return VMVal::make_none();
            auto& lst=vm_arg_list(a,1);
            VMVal acc=a.size()>=3?a[2]:lst[0];
            int start=a.size()>=3?0:1;
            for(int i=start;i<(int)lst.size();i++){
                std::vector<VMVal> call_args={acc,lst[i]};
                acc=this->vm_call(a[0],call_args,std::nullopt);}
            return acc;});
        globals_["any"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_bool(false);
            for(auto& v:vm_arg_list(a,0)) if(v.is_truthy()) return VMVal::make_bool(true);
            return VMVal::make_bool(false);});
        globals_["all"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_bool(true);
            for(auto& v:vm_arg_list(a,0)) if(!v.is_truthy()) return VMVal::make_bool(false);
            return VMVal::make_bool(true);});
        globals_["list"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            if(a[0].type==VMType::LIST) return a[0];
            if(a[0].type==VMType::STRING){
                std::vector<VMVal> r;
                for(char c:a[0].s) r.push_back(VMVal::make_str(std::string(1,c)));
                return VMVal::make_list(std::move(r));}
            if(a[0].type==VMType::ITERATOR&&a[0].iter){
                std::vector<VMVal> r(a[0].iter->second.begin(),a[0].iter->second.end());
                return VMVal::make_list(std::move(r));}
            if(a[0].type==VMType::GENERATOR){
                std::vector<VMVal> r;
                VMVal gen=a[0];
                while(gen.gen&&!gen.gen->done){
                    VMVal v=gen_next(gen);
                    if(!gen.gen||gen.gen->done) break;
                    r.push_back(v);
                }
                return VMVal::make_list(std::move(r));}
            if(a[0].type==VMType::MAP&&a[0].map){
                std::vector<VMVal> r;
                for(auto& [k,v]:*a[0].map) r.push_back(VMVal::make_str(k));
                return VMVal::make_list(std::move(r));}
            // Single item (not a generator — caller must have already consumed it)
            return VMVal::make_list(std::vector<VMVal>{a[0]});});
        globals_["set"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            std::vector<VMVal> r;
            std::unordered_set<std::string> seen;
            for(auto& v:vm_arg_list(a,0)){
                std::string k=v.to_string();
                if(!seen.count(k)){seen.insert(k);r.push_back(v);}}
            return VMVal::make_list(std::move(r));});
        globals_["dict"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            auto m=std::make_shared<VMMap>();
            if(!a.empty()&&a[0].type==VMType::LIST&&a[0].list){
                for(auto& item:vm_arg_list(a,0)){
                    if(item.type==VMType::LIST&&item.list&&item.list->size()>=2)
                        (*m)[(*item.list)[0].to_string()]=(*item.list)[1];}}
            VMVal r; r.type=VMType::MAP; r.map=m; return r;});
        globals_["tuple"]=globals_["list"]; // alias
        globals_["html_strip"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_str("");
            std::string s=a[0].to_string(),r; bool tag=false;
            for(char c:s){if(c=='<')tag=true;else if(c=='>')tag=false;else if(!tag)r+=c;}
            return VMVal::make_str(r);});
        globals_["regex_extract"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return a.size()>=2?a[1]:VMVal::make_str("");});
        globals_["tensor_benchmark"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            int n=a.empty()?100:(int)to_d(a[0]);
            auto t0=std::chrono::high_resolution_clock::now();
            volatile double acc=0;
            for(int i=0;i<n;i++)for(int j=0;j<64;j++)acc+=std::sin(j*0.01)*std::cos(i*0.01);
            auto t1=std::chrono::high_resolution_clock::now();
            return VMVal::make_float((double)std::chrono::duration_cast<std::chrono::microseconds>(t1-t0).count()/1000.0);});

        // ── rms_norm / layer_norm (already registered, add alias) ─────────────
        globals_["rms_norm"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list)return VMVal::make_list();
            auto& v=vm_arg_list(a,0); double rms=0;
            for(auto& x:v){double d=to_d(x);rms+=d*d;} rms=std::sqrt(rms/std::max(1,(int)v.size()));
            if(rms<1e-8)rms=1e-8;
            std::vector<VMVal> r; for(auto& x:v)r.push_back(VMVal::make_float(to_d(x)/rms));
            return VMVal::make_list(std::move(r));});
        // ── bpe_tokenize ──────────────────────────────────────────────────────
        globals_["bpe_tokenize"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_list();
            std::string s=a[0].to_string(); std::vector<VMVal> r;
            for(char c:s)r.push_back(VMVal::make_int((int64_t)c));
            return VMVal::make_list(std::move(r));});
        globals_["bpe_decode"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list)return VMVal::make_str("");
            std::string r; for(auto& v:vm_arg_list(a,0)){if(v.type==VMType::INT&&v.i>0&&v.i<128)r+=(char)v.i;}
            return VMVal::make_str(r);});
        register_json_builtins();
    }

    // (register_os_builtins / register_io_builtins lived here: VM copies of
    // os_*, read_file, write_file, shell, ... that disagreed with the
    // interpreter's. Removed in round 74 - the bridge serves the
    // interpreter's implementations, see include/builtins/os.hpp.)

    void register_math_builtins() {
        // Registered after the guarded copies above, so these shadowed them and
        // reintroduced the same unchecked a[0]. Same arity guard as cluster one.
        globals_["log"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::log(a.empty()?1.0:to_d(a[0])));});
        globals_["log2"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::log2(a.empty()?1.0:to_d(a[0])));});
        globals_["log10"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::log10(a.empty()?1.0:to_d(a[0])));});
        globals_["exp"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::exp(a.empty()?0.0:to_d(a[0])));});
        globals_["fabs"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{return VMVal::make_float(std::fabs(a.empty()?0.0:to_d(a[0])));});
    }

    void register_json_builtins() {
        // JSON: the codec shared with the interpreter (include/NyJson.hpp), so
        // both engines escape, format numbers and decode identically.
        globals_["json_encode"]=globals_["json_stringify"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("null");
            std::function<void(const VMVal&, std::string&, int)> enc;
            enc=[&](const VMVal& v, std::string& out, int depth){
                if(depth>200){ out+="null"; return; }
                if(v.type==VMType::NONE){ out+="null"; return; }
                if(v.type==VMType::BOOL){ out+=v.b?"true":"false"; return; }
                if(v.type==VMType::INT){ out+=v.to_string(); return; }
                if(v.type==VMType::FLOAT){ out+=nyjson::number(v.d); return; }
                if(v.type==VMType::STRING){ nyjson::quote_to(out, v.s); return; }
                if(v.type==VMType::LIST&&v.list){
                    out+="["; bool f=true;
                    for(auto& e:*v.list){ if(!f) out+=", "; enc(e,out,depth+1); f=false; }
                    out+="]"; return; }
                if((v.type==VMType::MAP||v.type==VMType::INSTANCE)&&v.map){
                    // Sorted keys, each written as its str() (1 -> "1"), as
                    // on the interpreter.
                    std::vector<std::pair<std::string,std::string>> keys;
                    for(auto& kv:*v.map){
                        const std::string& k=kv.first;
                        if(k=="__len__"||k=="__type__"||k=="__name__"||k=="__class__") continue;
                        keys.push_back({vm_key_value(k).to_string(),k}); }
                    std::sort(keys.begin(),keys.end());
                    out+="{"; bool f=true;
                    for(auto& k:keys){
                        if(!f) out+=", ";
                        nyjson::quote_to(out,k.first); out+=": ";
                        enc(v.map->find(k.second)->second,out,depth+1); f=false; }
                    out+="}"; return; }
                out+="null"; };
            std::string out;
            enc(a[0],out,0);
            return VMVal::make_str(out);});

        // fuzzy_score / fuzzy_positions / fuzzy_rank: include/NyFuzzy.hpp, the
        // same matcher as the interpreter.
        globals_["fuzzy_score"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::STRING||a[1].type!=VMType::STRING) return VMVal::make_none();
            int sc=0;
            if(!nyfuzzy::score(a[0].s,a[1].s,sc)) return VMVal::make_none();
            return VMVal::make_int(sc);});
        globals_["fuzzy_positions"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::STRING||a[1].type!=VMType::STRING) return VMVal::make_none();
            int sc=0; std::vector<int> pos;
            if(!nyfuzzy::score(a[0].s,a[1].s,sc,&pos)) return VMVal::make_none();
            std::vector<VMVal> out; for(int p:pos) out.push_back(VMVal::make_int(p));
            return VMVal::make_list(std::move(out));});
        globals_["fuzzy_rank"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::STRING||a[1].type!=VMType::LIST||!a[1].list) return VMVal::make_none();
            std::vector<std::string> texts;
            for(auto& v:*a[1].list) texts.push_back(v.type==VMType::STRING?v.s:v.to_string());
            size_t limit=0;
            if(a.size()>2&&a[2].type==VMType::INT&&a[2].i>0) limit=(size_t)a[2].i;
            std::vector<long long> bonus; bool hb=a.size()>3&&a[3].type==VMType::LIST&&a[3].list;
            if(hb) for(auto& v:*a[3].list) bonus.push_back(v.type==VMType::INT?v.i:(v.type==VMType::FLOAT?(long long)v.d:0));
            auto idx=nyfuzzy::rank(a[0].s,texts,hb?&bonus:nullptr,limit);
            std::vector<VMVal> out; for(int k:idx) out.push_back(VMVal::make_int(k));
            return VMVal::make_list(std::move(out));});

        auto json_parse_fn = [](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::STRING) return VMVal::make_none();
            nyjson::Node root; std::string err;
            if(!nyjson::parse(a[0].s,root,err)) return VMVal::make_none();
            std::function<VMVal(const nyjson::Node&)> conv=[&](const nyjson::Node& n)->VMVal{
                switch(n.kind){
                    case nyjson::Node::Null: return VMVal::make_none();
                    case nyjson::Node::Bool: return VMVal::make_bool(n.b);
                    case nyjson::Node::Int:
                        if(!n.s.empty()){ nypy::BigInt big; if(nypy::BigInt::parse(n.s,10,big)) return VMVal::make_bigint(big); }
                        return VMVal::make_int(n.i);
                    case nyjson::Node::Float: return VMVal::make_float(n.d);
                    case nyjson::Node::Str: return VMVal::make_str(n.s);
                    case nyjson::Node::Arr: {
                        std::vector<VMVal> lst; lst.reserve(n.items.size());
                        for(auto& it:n.items) lst.push_back(conv(it));
                        return VMVal::make_list(std::move(lst)); }
                    case nyjson::Node::Obj: {
                        auto m=VMVal::make_map();
                        for(auto& f:n.fields) (*m.map)[nypy::key_of_str(f.first)]=conv(f.second);
                        return m; }
                }
                return VMVal::make_none(); };
            return conv(root);
        };
        globals_["json_decode"]=globals_["json_parse"]=VMVal::make_native(json_parse_fn);
    }

    // ── Iterator ───────────────────────────────────────────────────────
    static VMVal make_iter(const VMVal& v) {
        if(v.type==VMType::ITERATOR) return v; // already an iterator (e.g. generator)
        if(v.type==VMType::LIST&&v.list) return VMVal::make_iter(*v.list);
        if(v.type==VMType::INT){
            std::vector<VMVal> items;
            for(int64_t i=0;i<v.i;i++) items.push_back(VMVal::make_int(i));
            return VMVal::make_iter(std::move(items));
        }
        if(v.type==VMType::STRING){
            std::vector<VMVal> items;
            for(auto& ch:nypy::u8_chars(v.s)) items.push_back(VMVal::make_str(ch));
            return VMVal::make_iter(std::move(items));
        }
        if(v.type==VMType::MAP&&v.map){
            std::vector<VMVal> items;
            for(auto&[k,val]:*v.map) if(!vm_internal_key(k)) items.push_back(vm_key_value(k));
            return VMVal::make_iter(std::move(items));
        }
        return VMVal::make_iter({});
    }

    // ── Built-in string methods ─────────────────────────────────────────
    // One implementation for both engines: nypy::str_method (NyStr.hpp);
    // only str.format needs the VM's values.
    nypy::SArg to_sarg(const VMVal& v) {
        nypy::SArg a; a.tname=vm_type_name(v);
        switch(v.type){
            case VMType::NONE: a.k=nypy::SArg::NONE; return a;
            case VMType::BOOL: a.k=nypy::SArg::BOOL; a.i=v.b?1:0; return a;
            case VMType::INT: a.k=nypy::SArg::INT; a.i=v.i; return a;
            case VMType::STRING: a.k=nypy::SArg::STR; a.s=v.s; return a;
            case VMType::LIST: case VMType::MAP: case VMType::ITERATOR: case VMType::GENERATOR: case VMType::INSTANCE: {
                std::vector<VMVal> items=iter_items(v);
                a.k=nypy::SArg::STRS;
                for(size_t k=0;k<items.size();k++){
                    if(items[k].type!=VMType::STRING)
                        raise_native_exception("TypeError","sequence item "+std::to_string(k)+": expected str instance, "+vm_type_name(items[k])+" found");
                    a.v.push_back(items[k].s);
                }
                return a;
            }
            default: a.k=nypy::SArg::OTHER; return a;
        }
    }
    static VMVal from_sres(const nypy::SRes& r) {
        switch(r.k){
            case nypy::SRes::INT: return VMVal::make_int(r.i);
            case nypy::SRes::BOOL: return VMVal::make_bool(r.b);
            case nypy::SRes::STR:
                if(r.i==1){ double d=0; nypy::parse_float_str(r.s,d); return VMVal::make_float(d); }
                return VMVal::make_str(r.s);
            case nypy::SRes::LIST: case nypy::SRes::TUPLE: {
                std::vector<VMVal> items; items.reserve(r.v.size());
                for(auto& x:r.v) items.push_back(VMVal::make_str(x));
                VMVal out=VMVal::make_list(std::move(items)); out.b=r.k==nypy::SRes::TUPLE; return out;
            }
            default: return VMVal::make_none();
        }
    }
    // Keyword arguments reach a native as a trailing map marked "__kwargs__"
    // (CALL_KW); this takes it off the argument list.
    static VMVal take_kwargs(std::vector<VMVal>& a) {
        if(!a.empty()&&a.back().type==VMType::MAP&&a.back().class_name=="__kwargs__"){
            VMVal kw=a.back(); a.pop_back(); return kw;
        }
        return VMVal::make_none();
    }
    static const VMVal* kwarg(const VMVal& kw, const char* name) {
        if(kw.type!=VMType::MAP||!kw.map) return nullptr;
        auto it=kw.map->find(name);
        return it==kw.map->end()?nullptr:&it->second;
    }
    VMVal str_method(VMVal obj, const std::string& m) {
        VirtualMachine* vm=this;
        return VMVal::make_native([obj,m,vm](std::vector<VMVal>& a)->VMVal{
            VMVal kw=take_kwargs(a);
            if(m=="format") return VMVal::make_str(vm->str_format(obj.s,a,kw.type==VMType::MAP?&kw:nullptr));
            if(m=="format_map"){
                VMVal mp=a.empty()?VMVal::make_none():a[0];
                std::vector<VMVal> none;
                return VMVal::make_str(vm->str_format(obj.s,none,mp.type==VMType::MAP?&mp:nullptr));
            }
            std::vector<nypy::SArg> sa; sa.reserve(a.size());
            for(auto& v:a) sa.push_back(vm->to_sarg(v));
            nypy::SRes r;
            if(vm->nycall([&]{ return nypy::str_method(obj.s,m,sa,r); })) return from_sres(r);
            return VMVal::make_none();
        });
    }
    VMVal call_str_method(VMVal obj, const std::string& m, std::vector<VMVal>& a) {
        VMVal fn=str_method(obj,m);
        return fn.type==VMType::NATIVE?fn.native(a):VMVal::make_none();
    }

    // ── Built-in list methods ───────────────────────────────────────────
    // Python list/tuple methods, as the interpreter's listMethod; false when
    // `m` is not one of them (the Nython extras follow in list_method).
    bool list_method_py(const VMVal& obj, const std::string& m, std::vector<VMVal>& a, const VMVal& kw, VMVal& out) {
        static const std::unordered_set<std::string> mine = {
            "sort","index","indexOf","count","pop","insert","copy","reverse","clear","extend","append","push","remove"};
        if(!mine.count(m)) return false;
        static const std::unordered_set<std::string> mutating = {"sort","pop","insert","reverse","clear","extend","append","push","remove"};
        if(obj.b&&mutating.count(m)) raise_native_exception("AttributeError","'tuple' object has no attribute '"+m+"'");
        auto& L=*obj.list;
        int64_t n=(int64_t)L.size();
        auto nargs=[&](size_t k,const char* what){ if(a.size()!=k) raise_native_exception("TypeError",std::string(what)+" takes exactly "+std::to_string(k)+" argument ("+std::to_string(a.size())+" given)"); };
        if(m=="append"||m=="push"){ nargs(1,"list.append()"); L.push_back(a[0]); out=VMVal::make_none(); return true; }
        if(m=="extend"){ nargs(1,"list.extend()"); std::vector<VMVal> more=iter_items(a[0]); L.insert(L.end(),more.begin(),more.end()); out=VMVal::make_none(); return true; }
        if(m=="remove"){
            nargs(1,"list.remove()");
            for(size_t k=0;k<L.size();k++) if(L[k]==a[0]){ L.erase(L.begin()+(long)k); out=VMVal::make_none(); return true; }
            raise_native_exception("ValueError","list.remove(x): x not in list");
        }
        if(m=="sort"){
            VMVal keyfn=VMVal::make_none(); bool rev=false;
            if(const VMVal* k=kwarg(kw,"key")) keyfn=*k;
            if(const VMVal* r=kwarg(kw,"reverse")) rev=r->is_truthy();
            for(auto& v:a){
                if(v.type==VMType::BOOL) rev=v.b;
                else if((v.type==VMType::FUNCTION||v.type==VMType::NATIVE)&&keyfn.type==VMType::NONE) keyfn=v;
            }
            std::vector<VMVal> keys;
            if(keyfn.type!=VMType::NONE) for(auto& v:L){ std::vector<VMVal> ka={v}; keys.push_back(vm_call(keyfn,ka,std::nullopt)); }
            std::vector<size_t> order(L.size());
            for(size_t k=0;k<order.size();k++) order[k]=k;
            std::stable_sort(order.begin(),order.end(),[&](size_t x,size_t y){
                const VMVal& kx=keys.empty()?L[x]:keys[x];
                const VMVal& ky=keys.empty()?L[y]:keys[y];
                return rev?sort_less(ky,kx):sort_less(kx,ky);
            });
            std::vector<VMVal> sorted_items; sorted_items.reserve(L.size());
            for(size_t k:order) sorted_items.push_back(L[k]);
            L.swap(sorted_items);
            out=obj; return true;   // the list itself, as on the interpreter
        }
        if(m=="index"||m=="indexOf"){
            if(a.empty()) raise_native_exception("TypeError","index expected at least 1 argument, got 0");
            int64_t st=0,en=n;
            if(a.size()>=2&&a[1].type!=VMType::NONE){ st=index_of(a[1],"slice"); if(st<0) st=std::max<int64_t>(0,st+n); }
            if(a.size()>=3&&a[2].type!=VMType::NONE){ en=index_of(a[2],"slice"); if(en<0) en+=n; en=std::min(en,n); }
            for(int64_t k=st;k<en;k++) if(L[(size_t)k]==a[0]){ out=VMVal::make_int(k); return true; }
            if(m=="indexOf"){ out=VMVal::make_int(-1); return true; }
            raise_native_exception("ValueError",vm_repr(a[0])+" is not in list");
        }
        if(m=="count"){ nargs(1,"count()"); int64_t c=0; for(auto& v:L) if(v==a[0]) c++; out=VMVal::make_int(c); return true; }
        if(m=="pop"){
            if(!a.empty()&&a[0].type!=VMType::INT&&a[0].type!=VMType::BOOL) return false;
            if(n==0) raise_native_exception("IndexError","pop from empty list");
            int64_t i=a.empty()?n-1:index_of(a[0],"list");
            if(i<0) i+=n;
            if(i<0||i>=n) raise_native_exception("IndexError","pop index out of range");
            out=L[(size_t)i]; L.erase(L.begin()+i); return true;
        }
        if(m=="insert"){
            if(a.size()!=2) raise_native_exception("TypeError","insert expected 2 arguments, got "+std::to_string(a.size()));
            int64_t i=index_of(a[0],"list");
            if(i<0) i=std::max<int64_t>(0,i+n);
            if(i>n) i=n;
            L.insert(L.begin()+i,a[1]); out=VMVal::make_none(); return true;
        }
        if(m=="copy"){ out=VMVal::make_list(std::vector<VMVal>(L)); out.b=obj.b; return true; }
        if(m=="reverse"){ std::reverse(L.begin(),L.end()); out=obj; return true; }
        if(m=="clear"){ L.clear(); out=VMVal::make_none(); return true; }
        return false;
    }
    // sorted()/min()/max()/list.sort() ordering: Python's where defined;
    // values Python cannot compare fall back to type name then text.
    bool sort_less(const VMVal& x, const VMVal& y) {
        if(x.is_num()&&y.is_num()) return VMVal::num_compare(x,y)==-1;
        if(x.type==VMType::STRING&&y.type==VMType::STRING) return x.s<y.s;
        if(x.type==VMType::LIST&&y.type==VMType::LIST&&x.list&&y.list){
            size_t n=std::min(x.list->size(),y.list->size());
            for(size_t k=0;k<n;k++){
                const VMVal& p=(*x.list)[k]; const VMVal& q=(*y.list)[k];
                if(p==q) continue;
                return sort_less(p,q);
            }
            return x.list->size()<y.list->size();
        }
        if(x.type==VMType::INSTANCE){
            VMVal r=call_dunder(x,"__lt__",{y});
            if(r.type==VMType::BOOL) return r.b;
        }
        std::string tx=vm_type_name(x), ty=vm_type_name(y);
        if(tx!=ty) return tx<ty;
        return x.to_string()<y.to_string();
    }
    VMVal list_method(VMVal obj, const std::string& m) {
        VirtualMachine* vm=this;
        return VMVal::make_native([obj,m,vm](std::vector<VMVal>& a)->VMVal{
            if(!obj.list) return VMVal::make_none();
            auto& lst=*obj.list;
            VMVal kw=take_kwargs(a);
            VMVal res;
            if(vm->list_method_py(obj,m,a,kw,res)) return res;
            if(m=="len"||m=="length"||m=="size") return VMVal::make_int((int64_t)lst.size());
            // Functional list methods. Without these, xs.filter(...) evaluated
            // to none — and because printing none still exits 0, the example
            // sweep counted chain2.ny as passing while it produced nothing.
            if(m=="map"||m=="filter"||m=="each"||m=="forEach"){
                if(a.empty()) return VMVal::make_list();
                VMVal fn=a[0];
                std::vector<VMVal> out;
                for(auto& v:lst){
                    std::vector<VMVal> ca={v};
                    VMVal r=vm->vm_call(fn,ca,std::nullopt);
                    if(m=="map") out.push_back(r);
                    else if(m=="filter"){ if(r.is_truthy()) out.push_back(v); }
                }
                if(m=="each"||m=="forEach") return VMVal::make_none();
                return VMVal::make_list(std::move(out));
            }
            if(m=="reduce"||m=="fold"){
                if(a.empty()) return VMVal::make_none();
                VMVal fn=a[0];
                size_t i=0;
                VMVal acc;
                if(a.size()>=2){ acc=a[1]; }
                else { if(lst.empty()) return VMVal::make_none(); acc=lst[0]; i=1; }
                for(;i<lst.size();i++){
                    std::vector<VMVal> ca={acc,lst[i]};
                    acc=vm->vm_call(fn,ca,std::nullopt);
                }
                return acc;
            }
            if(m=="pop"){
                // pop(i) removes index i (negative counts from the end); the
                // index used to be ignored, so pop(0) removed the LAST item.
                if(lst.empty())return VMVal::make_none();
                int64_t i=(int64_t)lst.size()-1;
                if(!a.empty()&&a[0].type==VMType::INT){i=a[0].i;if(i<0)i+=(int64_t)lst.size();}
                if(i<0||i>=(int64_t)lst.size())return VMVal::make_none();
                VMVal v=lst[(size_t)i];lst.erase(lst.begin()+i);return v;}
            if(m=="insert"){
                if(a.size()>=2){int64_t i=a[0].i;if(i<0)i+=(int64_t)lst.size();
                i=std::max((int64_t)0,std::min((int64_t)lst.size(),i));
                lst.insert(lst.begin()+i,a[1]);}return VMVal::make_none();}
            if(m=="remove"){
                if(!a.empty()){auto it=std::find_if(lst.begin(),lst.end(),[&](const VMVal& v){return v==a[0];});
                if(it!=lst.end())lst.erase(it);}return VMVal::make_none();}
            if(m=="index"||m=="indexOf"){   // indexOf was missing; returned none
                if(!a.empty())for(int64_t i=0;i<(int64_t)lst.size();i++)if(lst[i]==a[0])return VMVal::make_int(i);
                return VMVal::make_int(-1);}
            if(m=="count"){if(a.empty())return VMVal::make_int((int64_t)lst.size());int64_t cnt=0;for(auto& v:lst)if(v==a[0])cnt++;return VMVal::make_int(cnt);}
            // nums.min()/.max()/.sum() as method calls - only the global
            // min(nums)/max(nums)/sum(nums) forms were implemented, so the
            // method form fell through this whole if-chain and read none.
            // Reuse the global natives, which already handle a list argument.
            if(m=="min"||m=="max"||m=="sum"){
                std::vector<VMVal> la={obj};
                return vm->globals_[m].native(la);
            }
            if(m=="clear"){lst.clear();return VMVal::make_none();}
            if(m=="copy"){return VMVal::make_list(std::vector<VMVal>(lst));}
            if(m=="extend"){if(!a.empty()&&a[0].list)for(auto& v:*a[0].list)lst.push_back(v);return VMVal::make_none();}
            if(m=="contains"){
                if(!a.empty())for(auto& v:lst)if(v==a[0])return VMVal::make_bool(true);
                return VMVal::make_bool(false);}
            if(m=="join"){std::string sep=a.empty()?"":a[0].to_string(),r;bool first=true;
                for(auto& v:lst){if(!first)r+=sep;r+=v.to_string();first=false;}return VMVal::make_str(r);}
            if(m=="reverse"){std::reverse(lst.begin(),lst.end());return VMVal::make_none();}
            if(m=="sort"){std::sort(lst.begin(),lst.end(),[](const VMVal& a,const VMVal& b){return a<b;});
                // Return the list, not none: the interpreter does, and the
                // chained form .filter(..).map(..).sort() depends on it.
                return VMVal::make_list(std::vector<VMVal>(lst));}
            // Set methods (sets are stored as deduplicated lists):
            if(m=="add"){
                if(!a.empty()){
                    std::string k=a[0].to_string();
                    bool found=false; for(auto& v:lst) if(v.to_string()==k){found=true;break;}
                    if(!found) lst.push_back(a[0]);
                } return VMVal::make_none();}
            if(m=="remove"||m=="discard"){
                if(!a.empty()){
                    std::string k=a[0].to_string();
                    lst.erase(std::remove_if(lst.begin(),lst.end(),[&](const VMVal& v){return v.to_string()==k;}),lst.end());
                } return VMVal::make_none();}
            if(m=="union"||m=="__or__"){
                if(!a.empty()&&a[0].list){
                    auto res=lst;
                    std::unordered_set<std::string> seen; for(auto& v:res) seen.insert(v.to_string());
                    for(auto& v:*a[0].list) if(!seen.count(v.to_string())){seen.insert(v.to_string());res.push_back(v);}
                    return VMVal::make_list(std::move(res));}
                return VMVal::make_list(std::vector<VMVal>(lst));}
            if(m=="intersection"){
                if(!a.empty()&&a[0].list){
                    std::unordered_set<std::string> other; for(auto& v:*a[0].list) other.insert(v.to_string());
                    std::vector<VMVal> res;
                    for(auto& v:lst) if(other.count(v.to_string())) res.push_back(v);
                    return VMVal::make_list(std::move(res));}
                return VMVal::make_list({});}
            if(m=="difference"){
                if(!a.empty()&&a[0].list){
                    std::unordered_set<std::string> other; for(auto& v:*a[0].list) other.insert(v.to_string());
                    std::vector<VMVal> res;
                    for(auto& v:lst) if(!other.count(v.to_string())) res.push_back(v);
                    return VMVal::make_list(std::move(res));}
                return VMVal::make_list(std::vector<VMVal>(lst));}
            if(m=="slice"){
                // L[a:b:c] (the parser emits L.slice(a, b, c), none for an
                // omitted bound): Python's slice semantics; a tuple slice is
                // a tuple.
                int64_t st,step,n=vm->slice_spec(a,(int64_t)lst.size(),st,step);
                std::vector<VMVal> sub;
                for(int64_t k=0,i=st;k<n;k++,i+=step) sub.push_back(lst[(size_t)i]);
                VMVal r=VMVal::make_list(std::move(sub)); r.b=obj.b; return r;}
            return VMVal::make_none();
        });
    }
    VMVal call_list_method(VMVal obj, const std::string& m, std::vector<VMVal>& a) {
        VMVal fn=list_method(obj,m);
        return fn.type==VMType::NATIVE?fn.native(a):VMVal::make_none();
    }

    // ── Built-in registration ───────────────────────────────────────────
    // The Python core builtins, with the semantics of the interpreter's
    // builtins/pycore.cpp and the same shared libraries (NyBigInt/NyStr/
    // NyFormat): any iterable (lists, tuples, strings, dicts, generators,
    // __iter__ instances), keyword arguments by name, exact big ints.
    void register_pycore() {
        VirtualMachine* vm=this;
        auto def=[&](const char* name, std::function<VMVal(std::vector<VMVal>&, const VMVal&)> fn){
            globals_[name]=VMVal::make_native([fn](std::vector<VMVal>& a)->VMVal{
                VMVal kw=take_kwargs(a);
                return fn(a,kw);
            });
        };
        auto need=[vm](const std::vector<VMVal>& a, size_t n, const char* what){
            if(a.size()<n) vm->raise_native_exception("TypeError",std::string(what)+" expected "+std::to_string(n)+" argument"+(n==1?"":"s")+", got "+std::to_string(a.size()));
        };
        auto as_int=[vm](const VMVal& v)->nypy::NumV{
            nypy::NumV n;
            if(!v.to_numv(n)||n.k==3) vm->raise_native_exception("TypeError","'"+vm_type_name(v)+"' object cannot be interpreted as an integer");
            return n;
        };
        auto call1=[vm](const VMVal& fn, const VMVal& x){ std::vector<VMVal> a={x}; return vm->vm_call(fn,a,std::nullopt); };
        def("len",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","len() takes exactly one argument (0 given)");
            const VMVal& v=a[0];
            switch(v.type){
                case VMType::STRING: return VMVal::make_int((int64_t)nypy::str_width(v.s));
                case VMType::LIST: return VMVal::make_int(v.list?(int64_t)v.list->size():0);
                case VMType::MAP: { int64_t n=0; if(v.map) for(auto& kv:*v.map) if(!vm_internal_key(kv.first)) n++; return VMVal::make_int(n); }
                case VMType::INSTANCE: { VMVal r=vm->call_dunder(v,"__len__",{}); if(r.type!=VMType::NONE) return r; break; }
                case VMType::ITERATOR: return VMVal::make_int(v.iter?(int64_t)v.iter->second.size()-v.iter->first:0);
                case VMType::NONE: case VMType::UNDEFINED: return VMVal::make_int(0);   // as the interpreter
                default: break;
            }
            vm->raise_native_exception("TypeError","object of type '"+vm_type_name(v)+"' has no len()");
        });
        def("str",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            if(a[0].type==VMType::STRING) return a[0];
            return VMVal::make_str(vm->vm_str(a[0]));
        });
        globals_["string"]=globals_["str"];
        def("repr",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","repr() takes exactly one argument (0 given)");
            return VMVal::make_str(vm->vm_repr(a[0]));
        });
        def("ascii",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","ascii() takes exactly one argument (0 given)");
            return VMVal::make_str(vm->to_fmtval(a[0],'a').s);
        });
        def("format",[vm](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","format() takes at least 1 argument (0 given)");
            const VMVal* sp=a.size()>=2?&a[1]:kwarg(kw,"format_spec");
            return VMVal::make_str(vm->format_value(a[0],sp?sp->to_string():std::string()));
        });
        // An f-string field: __format_value__(value, spec, conversion).
        def("__format_value__",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.size()<3) return VMVal::make_str(a.empty()?std::string():vm->vm_str(a[0]));
            const std::string& spec=a[1].s; const std::string& conv=a[2].s;
            if(conv.empty()){
                if(spec.empty()) return VMVal::make_str(a[0].type==VMType::STRING?a[0].s:vm->vm_str(a[0]));
                return VMVal::make_str(vm->format_value(a[0],spec));
            }
            nypy::FmtVal fv=vm->to_fmtval(a[0],conv[0]);
            return VMVal::make_str(vm->nycall([&]{ return nypy::format_value(fv,spec); }));
        });
        def("int",[vm,as_int](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) return VMVal::make_int(0);
            const VMVal& v=a[0];
            const VMVal* bv=a.size()>=2?&a[1]:kwarg(kw,"base");
            if(bv){
                if(v.type!=VMType::STRING) vm->raise_native_exception("TypeError","int() can't convert non-string with explicit base");
                nypy::NumV b=as_int(*bv);
                int base=(int)b.i;
                if(b.k!=1||(base!=0&&(base<2||base>36))) vm->raise_native_exception("ValueError","int() base must be >= 2 and <= 36, or 0");
                nypy::BigInt out;
                if(!nypy::parse_int_str(v.s,base,out))
                    vm->raise_native_exception("ValueError","invalid literal for int() with base "+std::to_string(base)+": "+nypy::str_repr(v.s));
                return VMVal::make_bigint(out);
            }
            switch(v.type){
                case VMType::INT: return v;
                case VMType::BOOL: return VMVal::make_int(v.b?1:0);
                case VMType::FLOAT: {
                    if(std::isnan(v.d)) vm->raise_native_exception("ValueError","cannot convert float NaN to integer");
                    if(std::isinf(v.d)) vm->raise_native_exception("OverflowError","cannot convert float infinity to integer");
                    double t=std::trunc(v.d);
                    if(t>=-9.2e18&&t<=9.2e18) return VMVal::make_int((int64_t)t);
                    return VMVal::make_bigint(nypy::BigInt::from_double(t));
                }
                case VMType::STRING: {
                    nypy::BigInt out;
                    if(!nypy::parse_int_default(v.s,out))
                        vm->raise_native_exception("ValueError","invalid literal for int() with base 10: "+nypy::str_repr(v.s));
                    return VMVal::make_bigint(out);
                }
                case VMType::INSTANCE: { VMVal r=vm->call_dunder(v,"__int__",{}); if(r.type!=VMType::NONE) return r; break; }
                default: break;
            }
            vm->raise_native_exception("TypeError","int() argument must be a string, a bytes-like object or a real number, not '"+vm_type_name(v)+"'");
        });
        def("float",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) return VMVal::make_float(0.0);
            const VMVal& v=a[0];
            nypy::NumV n;
            if(v.to_numv(n)) return VMVal::make_float(n.dbl());
            if(v.type==VMType::STRING){
                double d;
                if(!nypy::parse_float_str(v.s,d)) vm->raise_native_exception("ValueError","could not convert string to float: "+nypy::str_repr(v.s));
                return VMVal::make_float(d);
            }
            if(v.type==VMType::INSTANCE){ VMVal r=vm->call_dunder(v,"__float__",{}); if(r.type!=VMType::NONE) return r; }
            vm->raise_native_exception("TypeError","float() argument must be a string or a real number, not '"+vm_type_name(v)+"'");
        });
        def("abs",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","abs() takes exactly one argument (0 given)");
            nypy::NumV n;
            if(a[0].to_numv(n)) return VMVal::from_numv(nypy::num_abs(n));
            if(a[0].type==VMType::INSTANCE){ VMVal r=vm->call_dunder(a[0],"__abs__",{}); if(r.type!=VMType::NONE) return r; }
            vm->raise_native_exception("TypeError","bad operand type for abs(): '"+vm_type_name(a[0])+"'");
        });
        def("round",[vm,as_int](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","round() missing required argument 'number' (pos 1)");
            nypy::NumV n;
            const VMVal* ndv=a.size()>=2?&a[1]:kwarg(kw,"ndigits");
            if(ndv&&ndv->type==VMType::NONE) ndv=nullptr;
            if(!a[0].to_numv(n)){
                if(a[0].type==VMType::INSTANCE){
                    VMVal r=ndv?vm->call_dunder(a[0],"__round__",{*ndv}):vm->call_dunder(a[0],"__round__",{});
                    if(r.type!=VMType::NONE) return r;
                }
                vm->raise_native_exception("TypeError","type "+vm_type_name(a[0])+" doesn't define __round__ method");
            }
            if(n.k==3){
                if(!ndv){
                    if(std::isnan(n.d)) vm->raise_native_exception("ValueError","cannot convert float NaN to integer");
                    if(std::isinf(n.d)) vm->raise_native_exception("OverflowError","cannot convert float infinity to integer");
                    double r=std::nearbyint(n.d);   // ties to even
                    if(r>=-9.2e18&&r<=9.2e18) return VMVal::make_int((int64_t)r);
                    return VMVal::make_bigint(nypy::BigInt::from_double(r));
                }
                nypy::NumV d=as_int(*ndv);
                return VMVal::make_float(nypy::round_ndigits(n.d,d.k==1?d.i:(d.neg()?-1000:1000)));
            }
            if(!ndv) return VMVal::from_numv(n.k==1?n:nypy::NumV::B(n.big()));
            nypy::NumV d=as_int(*ndv);
            if(d.k!=1||d.i>=0) return VMVal::from_numv(n);
            nypy::BigInt p=nypy::BigInt(10).pow((uint64_t)(-d.i)),q,r;
            nypy::BigInt::floordivmod(n.big(),p,q,r);
            int c=nypy::BigInt::cmp(r+r,p);
            if(c>0||(c==0&&!q.mag.empty()&&(q.mag[0]&1))) q=q+nypy::BigInt(1);
            return VMVal::make_bigint(q*p);
        });
        def("pow",[vm](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.size()<2) vm->raise_native_exception("TypeError","pow() expected 2 arguments");
            const VMVal* mv=a.size()>=3?&a[2]:kwarg(kw,"mod");
            if(mv&&mv->type!=VMType::NONE){
                nypy::NumV b,e,m;
                if(!a[0].to_numv(b)||!a[1].to_numv(e)||!mv->to_numv(m)) vm->raise_native_exception("TypeError","unsupported operand type(s) for pow()");
                return vm->nycall([&]{ return VMVal::from_numv(nypy::pow_mod(b,e,m)); });
            }
            return vm->binop(nypy::A_POW,a[0],a[1]);
        });
        def("divmod",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.size()<2) vm->raise_native_exception("TypeError","divmod expected 2 arguments");
            return VMVal::make_tuple({vm->binop(nypy::A_FLOORDIV,a[0],a[1]),vm->binop(nypy::A_MOD,a[0],a[1])});
        });
        for(const char* nm:{"hex","oct","bin"}){
            std::string spec=std::string(nm)=="hex"?"#x":std::string(nm)=="oct"?"#o":"#b";
            def(nm,[vm,as_int,spec](std::vector<VMVal>& a,const VMVal&)->VMVal{
                if(a.empty()) vm->raise_native_exception("TypeError","expected 1 argument");
                nypy::NumV n=as_int(a[0]);
                return VMVal::make_str(nypy::format_value(n.k==1?nypy::FmtVal::of_int(n.i):nypy::FmtVal::of_big(n.big()),spec));
            });
        }
        def("chr",[vm,as_int](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","chr() takes exactly one argument (0 given)");
            nypy::NumV n=as_int(a[0]);
            return VMVal::make_str(vm->nycall([&]{ return nypy::str_chr(n.k==1?n.i:-1); }));
        });
        def("ord",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()||a[0].type!=VMType::STRING) vm->raise_native_exception("TypeError","ord() expected string of length 1, but "+(a.empty()?std::string("nothing"):vm_type_name(a[0]))+" found");
            return VMVal::make_int(vm->nycall([&]{ return nypy::str_ord(a[0].s); }));
        });
        for(const char* nm:{"min","max"}){
            bool is_min=std::string(nm)=="min";
            std::string name=nm;
            def(nm,[vm,call1,is_min,name](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
                const VMVal* keyv=kwarg(kw,"key");
                const VMVal* defv=kwarg(kw,"default");
                if(keyv&&keyv->type==VMType::NONE) keyv=nullptr;
                std::vector<VMVal> items;
                if(a.size()==1) items=vm->iter_items(a[0]);
                else if(a.empty()) vm->raise_native_exception("TypeError",name+" expected at least 1 argument, got 0");
                else items=a;
                if(items.empty()){
                    if(defv) return *defv;
                    vm->raise_native_exception("ValueError",name+"() arg is an empty sequence");
                }
                size_t best=0;
                VMVal bk=keyv?call1(*keyv,items[0]):items[0];
                for(size_t k=1;k<items.size();k++){
                    VMVal kk=keyv?call1(*keyv,items[k]):items[k];
                    if(is_min?vm->sort_less(kk,bk):vm->sort_less(bk,kk)){ best=k; bk=kk; }
                }
                return items[best];
            });
        }
        def("sum",[vm](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","sum() takes at least 1 positional argument (0 given)");
            std::vector<VMVal> items=vm->iter_items(a[0]);
            const VMVal* sv=a.size()>=2?&a[1]:kwarg(kw,"start");
            VMVal acc=sv?*sv:VMVal::make_int(0);
            if(acc.type==VMType::STRING) vm->raise_native_exception("TypeError","sum() can't sum strings [use ''.join(seq) instead]");
            for(auto& v:items){
                if(acc.type==VMType::INT&&v.type==VMType::INT&&acc.s.empty()&&v.s.empty()){
                    int64_t r; if(!nypy::add_ovf(acc.i,v.i,r)){ acc.i=r; continue; }
                }
                if(acc.type==VMType::INSTANCE){ VMVal r=vm->call_dunder(acc,"__add__",{v}); if(r.type!=VMType::NONE){ acc=r; continue; } }
                if(v.type==VMType::INSTANCE){ VMVal r=vm->call_dunder(v,"__radd__",{acc}); if(r.type!=VMType::NONE){ acc=r; continue; } }
                acc=vm->binop(nypy::A_ADD,acc,v);
            }
            return acc;
        });
        def("sorted",[vm,call1](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","sorted expected 1 argument, got 0");
            std::vector<VMVal> items=vm->iter_items(a[0]);
            VMVal keyfn=VMVal::make_none(); bool rev=false;
            if(const VMVal* k=kwarg(kw,"key")) keyfn=*k;
            if(const VMVal* r=kwarg(kw,"reverse")) rev=r->is_truthy();
            for(size_t k=1;k<a.size();k++){   // old positional forms: sorted(xs, keyfn) / sorted(xs, true)
                if(a[k].type==VMType::BOOL) rev=a[k].b;
                else if((a[k].type==VMType::FUNCTION||a[k].type==VMType::NATIVE)&&keyfn.type==VMType::NONE) keyfn=a[k];
            }
            std::vector<VMVal> keys;
            if(keyfn.type!=VMType::NONE) for(auto& v:items) keys.push_back(call1(keyfn,v));
            std::vector<size_t> order(items.size());
            for(size_t k=0;k<order.size();k++) order[k]=k;
            std::stable_sort(order.begin(),order.end(),[&](size_t x,size_t y){
                const VMVal& kx=keys.empty()?items[x]:keys[x];
                const VMVal& ky=keys.empty()?items[y]:keys[y];
                return rev?vm->sort_less(ky,kx):vm->sort_less(kx,ky);
            });
            std::vector<VMVal> out; out.reserve(items.size());
            for(size_t k:order) out.push_back(items[k]);
            return VMVal::make_list(std::move(out));
        });
        def("reversed",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","reversed expected 1 argument, got 0");
            if(a[0].type==VMType::INSTANCE){ VMVal r=vm->call_dunder(a[0],"__reversed__",{}); if(r.type!=VMType::NONE) return r; }
            std::vector<VMVal> items=vm->iter_items(a[0]);
            std::reverse(items.begin(),items.end());
            return VMVal::make_list(std::move(items));
        });
        def("list",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) return VMVal::make_list();
            return VMVal::make_list(vm->iter_items(a[0]));
        });
        def("tuple",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) return VMVal::make_tuple();
            if(a[0].is_tuple()) return a[0];
            return VMVal::make_tuple(vm->iter_items(a[0]));
        });
        def("set",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            std::vector<VMVal> out;
            if(!a.empty()){
                std::unordered_set<std::string> seen;
                for(auto& v:vm->iter_items(a[0])) if(seen.insert(v.repr()).second) out.push_back(v);
            }
            return VMVal::make_list(std::move(out));
        });
        def("dict",[vm](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            VMVal d=VMVal::make_map();
            if(!a.empty()){
                if(a[0].type==VMType::MAP&&a[0].map){ for(auto& [k,v]:*a[0].map) if(!vm_internal_key(k)) (*d.map)[k]=v; }
                else for(auto& pr:vm->iter_items(a[0])){
                    std::vector<VMVal> kv=vm->iter_items(pr);
                    if(kv.size()!=2) vm->raise_native_exception("ValueError","dictionary update sequence element has length "+std::to_string(kv.size())+"; 2 is required");
                    (*d.map)[vm->vkey(kv[0])]=kv[1];
                }
            }
            if(kw.map) for(auto& [k,v]:*kw.map) (*d.map)[k]=v;
            return d;
        });
        def("enumerate",[vm,as_int](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","enumerate() missing required argument 'iterable'");
            std::vector<VMVal> items=vm->iter_items(a[0]);
            const VMVal* sv=a.size()>=2?&a[1]:kwarg(kw,"start");
            VMVal idx=sv?VMVal::from_numv(as_int(*sv)):VMVal::make_int(0);
            std::vector<VMVal> out; out.reserve(items.size());
            for(auto& v:items){
                out.push_back(VMVal::make_tuple({idx,v}));
                idx=vm->binop(nypy::A_ADD,idx,VMVal::make_int(1));
            }
            return VMVal::make_list(std::move(out));
        });
        def("zip",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            std::vector<std::vector<VMVal>> cols;
            size_t n=a.empty()?0:SIZE_MAX;
            for(auto& x:a){ cols.push_back(vm->iter_items(x)); n=std::min(n,cols.back().size()); }
            std::vector<VMVal> out;
            for(size_t k=0;k<n;k++){
                std::vector<VMVal> row; for(auto& c:cols) row.push_back(c[k]);
                out.push_back(VMVal::make_tuple(std::move(row)));
            }
            return VMVal::make_list(std::move(out));
        });
        globals_["zip_list"]=globals_["zip"];
        def("map",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.size()<2) vm->raise_native_exception("TypeError","map() must have at least two arguments.");
            std::vector<std::vector<VMVal>> cols;
            size_t n=SIZE_MAX;
            for(size_t k=1;k<a.size();k++){ cols.push_back(vm->iter_items(a[k])); n=std::min(n,cols.back().size()); }
            std::vector<VMVal> out;
            for(size_t k=0;k<n;k++){
                std::vector<VMVal> ca; for(auto& c:cols) ca.push_back(c[k]);
                out.push_back(vm->vm_call(a[0],ca,std::nullopt));
            }
            return VMVal::make_list(std::move(out));
        });
        def("filter",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.size()<2) vm->raise_native_exception("TypeError","filter expected 2 arguments");
            std::vector<VMVal> out;
            for(auto& v:vm->iter_items(a[1])){
                bool keep;
                if(a[0].type==VMType::NONE) keep=v.is_truthy();
                else { std::vector<VMVal> ca={v}; keep=vm->truthy(vm->vm_call(a[0],ca,std::nullopt)); }
                if(keep) out.push_back(v);
            }
            return VMVal::make_list(std::move(out));
        });
        def("any",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","any() takes exactly one argument (0 given)");
            for(auto& v:vm->iter_items(a[0])) if(vm->truthy(v)) return VMVal::make_bool(true);
            return VMVal::make_bool(false);
        });
        def("all",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","all() takes exactly one argument (0 given)");
            for(auto& v:vm->iter_items(a[0])) if(!vm->truthy(v)) return VMVal::make_bool(false);
            return VMVal::make_bool(true);
        });
        def("bool",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            return VMVal::make_bool(!a.empty()&&vm->truthy(a[0]));
        });
        def("type",[](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty())return VMVal::make_str("none");
            switch(a[0].type){
            case VMType::NONE:return VMVal::make_str("none");
            case VMType::BOOL:return VMVal::make_str("bool");
            case VMType::INT:return VMVal::make_str("int");
            case VMType::FLOAT:return VMVal::make_str("float");
            case VMType::STRING:return VMVal::make_str("string");  // as the interpreter reports it
            case VMType::LIST:return VMVal::make_str(a[0].b?"tuple":"list");
            case VMType::MAP:return VMVal::make_str("map");   // as the interpreter reports it
            case VMType::FUNCTION:return VMVal::make_str("function");
            case VMType::NATIVE:return VMVal::make_str("builtin");
            case VMType::CLASS:return VMVal::make_str("class");
            case VMType::INSTANCE:return VMVal::make_str(a[0].class_name);
            case VMType::GENERATOR:case VMType::ITERATOR:return VMVal::make_str("generator");
            default:return VMVal::make_str("unknown");}});
        globals_["typeof"]=globals_["type"];
    }
    // Truthiness with __bool__ / __len__ on instances.
    bool truthy(const VMVal& v) {
        if(v.type==VMType::INSTANCE){
            VMVal r=call_dunder(v,"__bool__",{});
            if(r.type!=VMType::NONE) return r.is_truthy();
            r=call_dunder(v,"__len__",{});
            if(r.type!=VMType::NONE) return r.is_truthy();
            return true;
        }
        return v.is_truthy();
    }

    void register_builtins() {
                // property() builtin — create a property descriptor
        globals_["property"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            VMVal desc; desc.type=VMType::MAP;
            desc.map=std::make_shared<VMMap>();
            if(!a.empty()) (*desc.map)["__get__"]=a[0];
            (*desc.map)["__is_property__"]=VMVal::make_bool(true);
            // Add .setter(fn) method to the descriptor so @prop.setter works:
            (*desc.map)["setter"]=VMVal::make_native([desc](std::vector<VMVal>& b) mutable ->VMVal{
                VMVal d2; d2.type=VMType::MAP;
                d2.map=std::make_shared<VMMap>(*desc.map);
                if(!b.empty()) (*d2.map)["__set__"]=b[0];
                (*d2.map)["setter"]=(*desc.map)["setter"]; // keep setter method
                return d2;
            });
            return desc;
        });
        globals_["staticmethod"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            VMVal fn=a[0];
            if(fn.type==VMType::FUNCTION&&fn.code) fn.code->is_static=true;
            return fn;
        });
        globals_["classmethod"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            VMVal fn=a[0];
            if(fn.type==VMType::FUNCTION&&fn.code) fn.code->is_classmethod=true;
            return fn;
        });
        globals_["print"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            for(size_t i=0;i<a.size();i++){
                if(i)std::cout<<" ";
                if(a[i].type==VMType::INSTANCE){
                    VMVal sv=call_dunder(a[i],"__str__",{});
                    if(sv.type==VMType::NONE) sv=call_dunder(a[i],"__repr__",{});
                    std::cout<<(sv.type!=VMType::NONE?sv.to_string():a[i].to_string());
                } else std::cout<<a[i].to_string();
            }
            std::cout<<"\n";return VMVal::make_none();});
        globals_["str"]=globals_["string"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            VMVal& v=a[0];
            if(v.type==VMType::INSTANCE){
                // Try __str__ first, then __repr__ as fallback
                for(auto dname : {"__str__","__repr__"}){
                    std::string cls=v.class_name;
                    while(!cls.empty()){
                        auto cit=class_reg_.find(cls);
                        if(cit==class_reg_.end()) break;
                        for(auto& sub:cit->second->sub_codes)
                            if(sub->name==dname&&!sub->is_class){
                                std::vector<VMVal> na; return exec_code(sub,na,v);
                            }
                        cls=cit->second->parent_class;
                    }
                }
            }
            return VMVal::make_str(v.to_string());
        });
        globals_["int"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_int(0);
            auto& v=a[0];
            if(v.type==VMType::INT)return v;
            if(v.type==VMType::FLOAT)return VMVal::make_int((int64_t)v.d);
            if(v.type==VMType::BOOL)return VMVal::make_int(v.b?1:0);
            if(v.type==VMType::STRING){
                // A parse failure was swallowed and silently returned 0, unlike
                // the interpreter's int() (src/builtins/tensor.cpp), which
                // raises ValueError - int("abc") looked like a successful
                // parse of 0 instead of an error a try/except could catch.
                // The base argument and 0x/0b/0o prefix auto-detection were
                // also missing here (always base 10), matched to the
                // interpreter below.
                // Surrounding whitespace is allowed, as on the interpreter.
                size_t b0=v.s.find_first_not_of(" \t\r\n"), b1=v.s.find_last_not_of(" \t\r\n");
                std::string s=b0==std::string::npos?std::string():v.s.substr(b0,b1-b0+1);
                int base=10;
                if(a.size()>=2&&a[1].type==VMType::INT) base=(int)a[1].i;
                if(s.size()>2&&s[0]=='0'){
                    if((s[1]=='x'||s[1]=='X')&&base==10) base=16;
                    if((s[1]=='b'||s[1]=='B')&&base==10) base=2;
                    if((s[1]=='o'||s[1]=='O')&&base==10) base=8;
                    if(base!=10&&(s[1]=='x'||s[1]=='X'||s[1]=='b'||s[1]=='B'||s[1]=='o'||s[1]=='O'))
                        s=s.substr(2);
                }
                try{
                    size_t idx=0;
                    long long iv=std::stoll(s,&idx,base);
                    if(idx!=s.size()) throw std::invalid_argument("not fully consumed");
                    return VMVal::make_int(iv);
                }catch(std::out_of_range&){
                    // VM integers are 64-bit (the interpreter's are unbounded)
                    throw std::runtime_error("OverflowError: int too large for the VM's 64-bit integers: '"+v.s+"'");
                }catch(...){
                    throw std::runtime_error("ValueError: invalid literal for int(): '"+v.s+"'");
                }
            }
            return VMVal::make_int(0);});
        globals_["float"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return a.empty()?VMVal::make_float(0.0):VMVal::make_float(to_d(a[0]));});
        globals_["bool"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(!a.empty()&&a[0].type==VMType::INSTANCE){
                VMVal r=call_dunder(a[0],"__bool__",{});
                if(r.type!=VMType::NONE) return VMVal::make_bool(r.is_truthy());
                // no __bool__: check __len__
                VMVal lr=call_dunder(a[0],"__len__",{});
                if(lr.type!=VMType::NONE) return VMVal::make_bool(lr.i!=0||to_d(lr)!=0.0);
            }
            return VMVal::make_bool(!a.empty()&&a[0].is_truthy());});
        globals_["len"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_int(0);
            auto& v=a[0];
            if(v.type==VMType::INSTANCE){VMVal res=call_dunder(v,"__len__",{});if(res.type!=VMType::NONE)return res;}
            if(v.type==VMType::STRING)return VMVal::make_int((int64_t)u8_chars(v.s));
            if(v.type==VMType::LIST&&v.list)return VMVal::make_int((int64_t)v.list->size());
            if(v.type==VMType::MAP&&v.map)return VMVal::make_int((int64_t)v.map->size());
            return VMVal::make_int(0);
        });
        globals_["range"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            int64_t st=0,en=0,step=1;
            if(a.size()==1)en=a[0].i;
            else if(a.size()>=2){st=a[0].i;en=a[1].i;}
            if(a.size()>=3)step=a[2].i;
            if(step==0)return VMVal::make_list();
            std::vector<VMVal> items;
            if(step>0)for(int64_t i=st;i<en;i+=step)items.push_back(VMVal::make_int(i));
            else for(int64_t i=st;i>en;i+=step)items.push_back(VMVal::make_int(i));
            return VMVal::make_list(std::move(items));});
        globals_["type"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_str("none");
            switch(a[0].type){
            case VMType::NONE:return VMVal::make_str("none");
            case VMType::BOOL:return VMVal::make_str("bool");
            case VMType::INT:return VMVal::make_str("int");
            case VMType::FLOAT:return VMVal::make_str("float");
            case VMType::STRING:return VMVal::make_str("string");  // as the interpreter reports it
            case VMType::LIST:return VMVal::make_str("list");
            case VMType::MAP:return VMVal::make_str("map");   // as the interpreter reports it
            case VMType::FUNCTION:return VMVal::make_str("function");
            case VMType::CLASS:return VMVal::make_str("class");
            case VMType::INSTANCE:return VMVal::make_str(a[0].class_name);
            default:return VMVal::make_str("unknown");}});
        globals_["abs"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_int(0);
            if(a[0].type==VMType::INT)return VMVal::make_int(std::abs(a[0].i));
            if(a[0].type==VMType::FLOAT)return VMVal::make_float(std::fabs(a[0].d));
            return a[0];});
        globals_["divmod"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_none();
            int64_t q=a[0].i/a[1].i, r=a[0].i%a[1].i;
            return VMVal::make_list({VMVal::make_int(q),VMVal::make_int(r)});
        });

        globals_["min"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            VMVal key_fn; bool has_key=false;
            if(!a.empty()&&a.back().type==VMType::MAP&&a.back().map){
                auto& km=*a.back().map;
                if(km.count("key")){key_fn=km["key"];has_key=true;}
                a.pop_back();
            }
            if(!has_key&&a.size()>=2&&(a[1].type==VMType::FUNCTION||a[1].type==VMType::NATIVE)){
                key_fn=a[1]; has_key=true; a={a[0]};
            } else if(has_key&&a.size()==1&&a[0].type==VMType::LIST) {}
            else if(has_key) { a.resize(1); }
            std::vector<VMVal>* lst=nullptr;
            if(a[0].type==VMType::LIST&&a[0].list) lst=a[0].list.get();
            if(lst&&!lst->empty()){
                auto apply=[&](const VMVal& v)->VMVal{
                    if(!has_key) return v;
                    std::vector<VMVal> kargs={v};
                    std::optional<VMVal> ns=std::nullopt;
                    return vm_call(key_fn,kargs,ns);
                };
                VMVal best=(*lst)[0];
                VMVal best_k=apply(best);
                for(size_t i=1;i<lst->size();i++){
                    VMVal ki=apply((*lst)[i]);
                    if(cmp_val(ki,best_k)<0){best=(*lst)[i];best_k=ki;}
                }
                return best;
            }
            // Multiple args: min(a,b,c)
            VMVal best=a[0];
            for(size_t i=1;i<a.size();i++) if(cmp_val(a[i],best)<0) best=a[i];
            return best;
        });
        globals_["max"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            VMVal key_fn; bool has_key=false;
            if(!a.empty()&&a.back().type==VMType::MAP&&a.back().map){
                auto& km=*a.back().map;
                if(km.count("key")){key_fn=km["key"];has_key=true;}
                a.pop_back();
            }
            if(!has_key&&a.size()>=2&&(a[1].type==VMType::FUNCTION||a[1].type==VMType::NATIVE)){
                key_fn=a[1]; has_key=true; a={a[0]};
            } else if(has_key) { a.resize(1); }
            std::vector<VMVal>* lst=nullptr;
            if(a[0].type==VMType::LIST&&a[0].list) lst=a[0].list.get();
            if(lst&&!lst->empty()){
                auto apply=[&](const VMVal& v)->VMVal{
                    if(!has_key) return v;
                    std::vector<VMVal> kargs={v};
                    std::optional<VMVal> ns=std::nullopt;
                    return vm_call(key_fn,kargs,ns);
                };
                VMVal best=(*lst)[0]; VMVal best_k=apply(best);
                for(size_t i=1;i<lst->size();i++){
                    VMVal ki=apply((*lst)[i]);
                    if(cmp_val(ki,best_k)>0){best=(*lst)[i];best_k=ki;}
                }
                return best;
            }
            VMVal best=a[0];
            for(size_t i=1;i<a.size();i++) if(cmp_val(a[i],best)>0) best=a[i];
            return best;
        });
        globals_["sum"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_int(0);
            if(a[0].type==VMType::LIST&&a[0].list){
                double s=0;bool hf=false;
                for(auto& v:*a[0].list){if(v.type==VMType::FLOAT){s+=v.d;hf=true;}else s+=to_d(v);}
                return hf?VMVal::make_float(s):VMVal::make_int((int64_t)s);}
            return VMVal::make_int(0);});
        globals_["input"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(!a.empty())std::cout<<a[0].to_string();
            std::string line;std::getline(std::cin,line);return VMVal::make_str(line);});
        globals_["chr"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return a.empty()?VMVal::make_str(""):VMVal::make_str(std::string(1,(char)a[0].i));});
        globals_["ord"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return(a.empty()||a[0].s.empty())?VMVal::make_int(0):VMVal::make_int((int64_t)(unsigned char)a[0].s[0]);});
        globals_["sqrt"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return VMVal::make_float(std::sqrt(to_d(a.empty()?VMVal::make_int(0):a[0])));});
        globals_["pow"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2)return VMVal::make_int(0);
            if(a[0].type==VMType::INT&&a[1].type==VMType::INT&&a[1].i>=0){
                // Float result, matching the interpreter: pow(2,10) is 1024.0
                // there, and a program comparing the two got different types.
                int64_t base=a[0].i,exp=a[1].i,res=1;
                for(int64_t k=0;k<exp;k++) res*=base;
                return VMVal::make_float((double)res);
            }
            return VMVal::make_float(std::pow(to_d(a[0]),to_d(a[1])));});
        globals_["floor"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return a.empty()?VMVal::make_int(0):VMVal::make_int((int64_t)std::floor(to_d(a[0])));});
        globals_["ceil"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return a.empty()?VMVal::make_int(0):VMVal::make_int((int64_t)std::ceil(to_d(a[0])));});
        globals_["round"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_int(0);
            if(a.size()==1)return VMVal::make_int((int64_t)std::round(to_d(a[0])));
            double f=std::pow(10,a[1].i);
            return VMVal::make_float(std::round(to_d(a[0])*f)/f);});
        globals_["list"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_list();
            if(a[0].type==VMType::LIST)return a[0];
            if(a[0].type==VMType::STRING){
                std::vector<VMVal> items;
                for(char c:a[0].s)items.push_back(VMVal::make_str(std::string(1,c)));
                return VMVal::make_list(std::move(items));}
            // Iterators and generators were missing here, so list(range(3)) and
            // list(gen()) both returned [] instead of their elements — a silent
            // wrong answer, not an error. The interpreter drains both.
            if(a[0].type==VMType::ITERATOR&&a[0].iter)
                return VMVal::make_list(std::vector<VMVal>(
                    a[0].iter->second.begin()+a[0].iter->first,
                    a[0].iter->second.end()));
            if(a[0].type==VMType::GENERATOR){
                std::vector<VMVal> r;
                VMVal gen=a[0];
                while(gen.gen&&!gen.gen->done){
                    VMVal v=gen_next(gen);
                    if(!gen.gen||gen.gen->done) break;
                    r.push_back(v);
                }
                return VMVal::make_list(std::move(r));}
            return VMVal::make_list();});
        globals_["dict"]=VMVal::make_native([](std::vector<VMVal>&)->VMVal{return VMVal::make_map();});
        // Tag the type-constructor builtins with the type name they build, so
        // isinstance(x, list) — passing the bare builtin, not a string — has
        // something to compare against. Done once, after every builtin above
        // has taken its final binding (list/dict are each registered twice;
        // this reads whichever registration actually won), rather than at
        // each individual registration site.
        tag_type_builtins();
        globals_["isinstance"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            VMVal& obj=a[0]; VMVal& cls=a[1];
            std::string cls_name;
            if(cls.type==VMType::CLASS) cls_name=cls.class_name;
            else if(cls.type==VMType::STRING) cls_name=cls.s;
            // isinstance(x, list) / isinstance(x, int): the bare builtin, not
            // a string. These are tagged with the type they build above.
            else if(cls.type==VMType::NATIVE&&!cls.class_name.empty()) cls_name=cls.class_name;
            else return VMVal::make_bool(false);
            if(obj.type!=VMType::INSTANCE){
                // Builtin/primitive types by name, e.g. isinstance(42, "int").
                // Only the class-instance case below was handled, so this
                // always read false; mirrors the interpreter's alias set
                // (dispatch_tensor's isinstance in src/builtins/tensor.cpp).
                if(cls_name=="int"||cls_name=="integer") return VMVal::make_bool(obj.type==VMType::INT||obj.type==VMType::BOOL);
                if(cls_name=="float"||cls_name=="double") return VMVal::make_bool(obj.type==VMType::FLOAT);
                if(cls_name=="bool"||cls_name=="boolean") return VMVal::make_bool(obj.type==VMType::BOOL);
                if(cls_name=="str"||cls_name=="string") return VMVal::make_bool(obj.type==VMType::STRING);
                if(cls_name=="list"||cls_name=="array") return VMVal::make_bool(obj.type==VMType::LIST&&!obj.b);
                if(cls_name=="tuple") return VMVal::make_bool(obj.type==VMType::LIST&&obj.b);
                if(cls_name=="map"||cls_name=="dict") return VMVal::make_bool(obj.type==VMType::MAP);
                if(cls_name=="none") return VMVal::make_bool(obj.type==VMType::NONE);
                if(cls_name=="function") return VMVal::make_bool(obj.type==VMType::FUNCTION||obj.type==VMType::NATIVE);
                return VMVal::make_bool(false);
            }
            // Walk inheritance chain
            std::string cur=obj.class_name;
            while(!cur.empty()){
                if(cur==cls_name) return VMVal::make_bool(true);
                auto cit=class_reg_.find(cur);
                if(cit==class_reg_.end()) break;
                cur=cit->second->parent_class;
            }
            return VMVal::make_bool(false);
        });
        globals_["hex"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_str("0x0");
            std::ostringstream oss;oss<<"0x"<<std::hex<<a[0].i;return VMVal::make_str(oss.str());});
        globals_["bin"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_str("0b0");
            int64_t n=a[0].i;if(n==0)return VMVal::make_str("0b0");
            std::string r;while(n>0){r=(char)('0'+(n&1))+r;n>>=1;}
            return VMVal::make_str("0b"+r);});
        globals_["oct"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty())return VMVal::make_str("0o0");
            std::ostringstream oss;oss<<"0o"<<std::oct<<a[0].i;return VMVal::make_str(oss.str());});
        // Constants
        globals_["none"]=VMVal::make_none();
        globals_["true"]=VMVal::make_bool(true);
        // ── Built-in exception classes ────────────────────────────────────────
        auto make_exc_class = [this](const std::string& cname) {
            globals_[cname] = VMVal::make_native([cname](std::vector<VMVal>& a) -> VMVal {
                auto attrs = std::make_shared<VMMap>();
                std::string msg = a.empty() ? cname : a[0].to_string();
                (*attrs)["msg"] = VMVal::make_str(msg);
                (*attrs)["args"] = VMVal::make_list(a);
                return VMVal::make_instance(cname, attrs);
            });
        };
        for(auto& en : std::vector<std::string>{
            "Exception","BaseException","ValueError","TypeError","ZeroDivisionError",
            "KeyError","IndexError","AttributeError","RuntimeError","NameError",
            "StopIteration","NotImplementedError","OverflowError","OSError","IOError",
            "FileNotFoundError","PermissionError","TimeoutError","ConnectionError",
            "ImportError","SyntaxError","AssertionError","ArithmeticError",
            "IsADirectoryError","NotADirectoryError","FileExistsError","ChildProcessError",
            "ProcessLookupError","InterruptedError","BlockingIOError","BrokenPipeError",
            "ConnectionRefusedError","ConnectionResetError","LookupError","EOFError",
            "ModuleNotFoundError","UnicodeError"
        }) make_exc_class(en);
        globals_["false"]=VMVal::make_bool(false);
        globals_["null"]=VMVal::make_none();
        globals_["PI"]  =VMVal::make_float(3.14159265358979323846);
        globals_["E"]   =VMVal::make_float(2.71828182845904523536);
        globals_["INFINITY"]=VMVal::make_float(std::numeric_limits<double>::infinity());
        // Time builtins (time, time_now, clock, time_ms, sleep, sleep_ms,
        // uuid, ...) come from the interpreter through the bridge.
        // OS constants and the running script.
#ifdef _WIN32
        globals_["os_sep"]=VMVal::make_str("\\"); globals_["os_pathsep"]=VMVal::make_str(";");
        globals_["os_linesep"]=VMVal::make_str("\r\n"); globals_["os_name"]=VMVal::make_str("nt");
#else
        globals_["os_sep"]=VMVal::make_str("/"); globals_["os_pathsep"]=VMVal::make_str(":");
        globals_["os_linesep"]=VMVal::make_str("\n"); globals_["os_name"]=VMVal::make_str("posix");
#endif
        globals_["__name__"]=VMVal::make_str("__main__");
        globals_["__file__"]=VMVal::make_str(nyrt::script_path());
        globals_["println"]=globals_["print"];

        // ── Map / collection builtins ─────────────────────────────────────
        globals_["keys"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            // A dict answers as d.keys() does (typed keys, none values kept,
            // pairs as tuples), like the interpreter's builtin.
            if(a[0].type==VMType::MAP&&a[0].map){ std::vector<VMVal> none; return call_map_method(a[0],"keys",none); }
            if((a[0].type==VMType::MAP||a[0].type==VMType::INSTANCE)&&a[0].map){
                std::vector<VMVal> ks;
                for(auto& [k,v]:*a[0].map) if(v.type!=VMType::NONE) ks.push_back(VMVal::make_str(k));
                return VMVal::make_list(std::move(ks));}
            // Not a container: the interpreter returns none here, not [].
            return VMVal::make_none();});
        globals_["values"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            // A dict answers as d.values() does (typed keys, none values kept,
            // pairs as tuples), like the interpreter's builtin.
            if(a[0].type==VMType::MAP&&a[0].map){ std::vector<VMVal> none; return call_map_method(a[0],"values",none); }
            if((a[0].type==VMType::MAP||a[0].type==VMType::INSTANCE)&&a[0].map){
                std::vector<VMVal> vs;
                for(auto& [k,v]:*a[0].map) if(v.type!=VMType::NONE) vs.push_back(v);
                return VMVal::make_list(std::move(vs));}
            // Not a container: the interpreter returns none here, not [].
            return VMVal::make_none();});
        globals_["items"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            // A dict answers as d.items() does (typed keys, none values kept,
            // pairs as tuples), like the interpreter's builtin.
            if(a[0].type==VMType::MAP&&a[0].map){ std::vector<VMVal> none; return call_map_method(a[0],"items",none); }
            if((a[0].type==VMType::MAP||a[0].type==VMType::INSTANCE)&&a[0].map){
                std::vector<VMVal> its;
                for(auto& [k,v]:*a[0].map){
                    if(v.type==VMType::NONE) continue;
                    std::vector<VMVal> pair={VMVal::make_str(k),v};
                    its.push_back(VMVal::make_tuple(std::move(pair)));}
                return VMVal::make_list(std::move(its));}
            // Not a container: the interpreter returns none here, not [].
            return VMVal::make_none();});
        globals_["sorted"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            VMVal key_fn; bool has_key=false; bool rev=false;
            // CALL_KW appends the keyword map as the last argument for natives,
            // so read key/reverse from it. This definition overrides the earlier
            // one, which did handle kwargs; without this, sorted(xs, reverse=true)
            // silently ignored reverse.
            if(a.size()>=2&&a.back().type==VMType::MAP&&a.back().map){
                auto& km=*a.back().map;
                if(km.count("key")){key_fn=km["key"];has_key=true;}
                if(km.count("reverse")&&km["reverse"].type==VMType::BOOL) rev=km["reverse"].b;
                a.pop_back();
            }
            if(!has_key&&a.size()>=2&&(a[1].type==VMType::FUNCTION||a[1].type==VMType::NATIVE)){key_fn=a[1];has_key=true;}
            if(!rev&&a.size()>=3&&a[2].type==VMType::BOOL&&a[2].b) rev=true;
            std::vector<VMVal> lst=(a[0].type==VMType::LIST&&a[0].list)?*a[0].list:a;
            // This definition overrides the earlier one, so it carries the same
            // decorate-sort-undecorate fix: calling the key function from inside
            // the comparator re-enters the VM mid-sort and segfaults.
            std::vector<std::pair<VMVal,VMVal>> decorated;
            decorated.reserve(lst.size());
            for(auto& v : lst){
                if(has_key){
                    std::vector<VMVal> kargs={v};
                    decorated.emplace_back(vm_call(key_fn,kargs,std::nullopt), v);
                } else {
                    decorated.emplace_back(v, v);
                }
            }
            std::stable_sort(decorated.begin(),decorated.end(),
                [rev](const std::pair<VMVal,VMVal>& x,const std::pair<VMVal,VMVal>& y){
                    int c2=cmp_val(x.first,y.first);
                    return rev?c2>0:c2<0;
                });
            std::vector<VMVal> out;
            out.reserve(decorated.size());
            for(auto& d : decorated) out.push_back(d.second);
            return VMVal::make_list(std::move(out));
        });
        globals_["reversed"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            std::vector<VMVal> v=*a[0].list; std::reverse(v.begin(),v.end());
            return VMVal::make_list(std::move(v));});
        // Set(iterable) -> deduplicated list, which is how the VM's set methods
        // (add / remove / union / ...) already represent sets. It was simply
        // never exposed as a global, so Set([1,2,3]) produced nothing.
        globals_["Set"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            std::vector<VMVal> out;
            std::unordered_set<std::string> seen;
            if(!a.empty()&&a[0].type==VMType::LIST&&a[0].list){
                for(auto& v:*a[0].list){
                    std::string k=v.to_string();
                    if(seen.insert(k).second) out.push_back(v);
                }
            }
            return VMVal::make_list(std::move(out));});
        globals_["enumerate"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::LIST||!a[0].list) return VMVal::make_list();
            int64_t start=0;
            // Check kwargs_map (last arg, MAP type) for start= keyword
            if(a.size()>=2&&a.back().type==VMType::MAP&&a.back().map){
                auto& km=*a.back().map;
                if(km.count("start")){
                    auto& sv=km.at("start");
                    if(sv.type==VMType::INT) start=sv.i;
                    else if(sv.type==VMType::FLOAT) start=(int64_t)sv.d;
                }
                a.pop_back();
            }
            // Positional start arg
            if(a.size()>=2){
                if(a[1].type==VMType::INT) start=a[1].i;
                else if(a[1].type==VMType::FLOAT) start=(int64_t)a[1].d;
            }
            std::vector<VMVal> res;
            for(auto& v:*a[0].list){
                std::vector<VMVal> pair={VMVal::make_int(start++),v};
                res.push_back(VMVal::make_list(std::move(pair)));}
            return VMVal::make_list(std::move(res));});
        globals_["zip"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::LIST||a[1].type!=VMType::LIST) return VMVal::make_list();
            std::vector<VMVal> res;
            size_t n=std::min(a[0].list->size(),a[1].list->size());
            for(size_t i=0;i<n;i++){
                std::vector<VMVal> pair={(*a[0].list)[i],(*a[1].list)[i]};
                res.push_back(VMVal::make_list(std::move(pair)));}
            return VMVal::make_list(std::move(res));});
        globals_["has_key"]=globals_["dict_has"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a[0].type!=VMType::MAP||!a[0].map) return VMVal::make_bool(false);
            return VMVal::make_bool(a[0].map->count(a[1].to_string())>0);});
        globals_["contains_key"]=globals_["has_key"];
        globals_["copy"]=globals_["deepcopy"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return a.empty()?VMVal::make_none():a[0];});
        globals_["id"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            // Only checked a[0].list, so id() on anything but a LIST (a map,
            // instance, function, string, int...) fell through to a null
            // shared_ptr and always returned 0. Use whichever backing
            // pointer the value actually has; primitives fall back to a
            // stable hash so id(x) is at least non-zero and repeatable.
            if(a.empty()) return VMVal::make_int(0);
            VMVal& v=a[0];
            uintptr_t raw=0;
            switch(v.type){
                case VMType::LIST:      raw=(uintptr_t)v.list.get(); break;
                case VMType::MAP:
                case VMType::INSTANCE:  raw=(uintptr_t)v.map.get();  break;
                case VMType::FUNCTION:
                case VMType::CLASS:     raw=(uintptr_t)v.code.get(); break;
                case VMType::ITERATOR:  raw=(uintptr_t)v.iter.get(); break;
                case VMType::GENERATOR: raw=(uintptr_t)v.gen.get();  break;
                default: raw=0; break;
            }
            if(raw) return VMVal::make_int((int64_t)(raw & 0x7fffffffffffffffULL));
            uint64_t h=std::hash<std::string>{}(v.to_string()+"|"+std::to_string((int)v.type));
            return VMVal::make_int((int64_t)(h & 0x7fffffffffffffffULL));});
        // As the interpreter's (pycore.cpp B_HASH): nypy::hash_of_key.
        globals_["hash"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) raise_native_exception("TypeError","hash() takes exactly one argument (0 given)");
            if(a[0].type==VMType::INSTANCE){
                VMVal h=call_dunder(a[0],"__hash__",{});
                if(h.type!=VMType::NONE) return h;
            }
            return VMVal::make_int(nypy::hash_of_key(vkey(a[0])));});
        globals_["random"]=VMVal::make_native([](std::vector<VMVal>&)->VMVal{return VMVal::make_float((double)rand()/(double)RAND_MAX);});
        globals_["randint"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            int64_t lo=a.size()>0?(a[0].type==VMType::INT?a[0].i:(int64_t)to_d(a[0])):0;
            int64_t hi=a.size()>1?(a[1].type==VMType::INT?a[1].i:(int64_t)to_d(a[1])):100;
            return VMVal::make_int(lo+(rand()%(hi-lo+1)));});
        globals_["assert_fn"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||!a[0].is_truthy()) throw std::runtime_error(a.size()>1?a[1].to_string():"AssertionError");
            return VMVal::make_none();});
        globals_["error"]=globals_["raise_error"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            throw std::runtime_error(a.empty()?"error":a[0].to_string()); return VMVal::make_none();});

        // ── String utility builtins (used by stdlib.ny) ─────────────────
        auto split_fn=[](const std::string& s,const std::string& sep)->VMVal{
            std::vector<VMVal> parts;
            if(sep.empty()){
                // split on whitespace
                std::istringstream ss(s); std::string tok;
                while(ss>>tok) parts.push_back(VMVal::make_str(tok));
            } else {
                size_t start=0,pos;
                while((pos=s.find(sep,start))!=std::string::npos){
                    parts.push_back(VMVal::make_str(s.substr(start,pos-start)));
                    start=pos+sep.size();
                }
                parts.push_back(VMVal::make_str(s.substr(start)));
            }
            return VMVal::make_list(std::move(parts));
        };
        globals_["string_split"]=globals_["str_split"]=VMVal::make_native([split_fn](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_list();
            std::string s=a[0].s;
            std::string sep=a.size()>1?a[1].s:" ";
            return split_fn(s,sep);
        });
        globals_["string_join"]=globals_["str_join"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_str("");
            // Accept both: string_join(list, sep) and string_join(sep, list)
            const VMVal* lst_ptr=nullptr; std::string sep="";
            if(a[0].type==VMType::LIST&&a[0].list){lst_ptr=&a[0];sep=a[1].to_string();}
            else if(a[1].type==VMType::LIST&&a[1].list){sep=a[0].to_string();lst_ptr=&a[1];}
            if(!lst_ptr) return VMVal::make_str("");
            std::string r; bool first=true;
            for(auto& v:*lst_ptr->list){if(!first)r+=sep;r+=v.to_string();first=false;}
            return VMVal::make_str(r);
        });
        globals_["string_contains"]=globals_["str_contains"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            return VMVal::make_bool(a[0].s.find(a[1].s)!=std::string::npos);
        });
        globals_["string_replace"]=globals_["str_replace"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3) return VMVal::make_str(a.empty()?"":a[0].s);
            std::string s=a[0].s,from=a[1].s,to=a[2].s,res;
            size_t pos=0,found;
            while((found=s.find(from,pos))!=std::string::npos){res+=s.substr(pos,found-pos)+to;pos=found+from.size();}
            return VMVal::make_str(res+s.substr(pos));
        });
        globals_["string_upper"]=globals_["str_upper"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string s=a[0].s; for(auto& c:s) c=(char)::toupper((unsigned char)c);
            return VMVal::make_str(s);
        });
        globals_["string_lower"]=globals_["str_lower"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string s=a[0].s; for(auto& c:s) c=(char)::tolower((unsigned char)c);
            return VMVal::make_str(s);
        });
        globals_["string_starts"]=globals_["str_startswith"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            return VMVal::make_bool(a[0].s.substr(0,a[1].s.size())==a[1].s);
        });
        globals_["string_ends"]=globals_["str_endswith"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            std::string& s=a[0].s,&e=a[1].s;
            return VMVal::make_bool(s.size()>=e.size()&&s.substr(s.size()-e.size())==e);
        });
        globals_["string_trim"]=globals_["str_strip"]=globals_["string_strip"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string s=a[0].s;
            size_t b=s.find_first_not_of(" \t\r\n"),e=s.find_last_not_of(" \t\r\n");
            return VMVal::make_str(b==std::string::npos?"":s.substr(b,e-b+1));
        });
        globals_["string_count"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_int(0);
            const std::string& s=a[0].s,&sub=a[1].s; int c=0; size_t pos=0;
            while((pos=s.find(sub,pos))!=std::string::npos){c++;pos+=sub.size();}
            return VMVal::make_int(c);
        });
        globals_["string_find"]=globals_["string_index"]=globals_["str_find"]=globals_["str_index"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_int(-1);
            size_t p=a[0].s.find(a[1].s);
            return p==std::string::npos?VMVal::make_int(-1)
                                       :VMVal::make_int((int64_t)u8_char_at(a[0].s,p));
        });
        globals_["string_rfind"]=globals_["str_rfind"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_int(-1);
            size_t p=a[0].s.rfind(a[1].s);
            return p==std::string::npos?VMVal::make_int(-1)
                                       :VMVal::make_int((int64_t)u8_char_at(a[0].s,p));
        });
        globals_["string_sub"]=globals_["string_slice"]=globals_["str_sub"]=globals_["str_slice"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            const std::string& s=a[0].s;
            int64_t n=(int64_t)u8_chars(s);   // characters, matching len()
            int64_t st=a.size()>1?(a[1].type==VMType::INT?a[1].i:(int64_t)to_d(a[1])):0;
            int64_t en=a.size()>2?(a[2].type==VMType::INT?a[2].i:(int64_t)to_d(a[2])):n;
            if(st<0)st+=n; if(en<0)en+=n;
            st=std::max((int64_t)0,std::min(st,n));
            en=std::max((int64_t)0,std::min(en,n));
            if(en<st) en=st;
            size_t b0=u8_byte_at(s,(size_t)st), b1=u8_byte_at(s,(size_t)en);
            return VMVal::make_str(b1>b0?s.substr(b0,b1-b0):"");
        });
        globals_["string_char"]=globals_["str_char"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_str("");
            const std::string& s=a[0].s; int64_t i=a[1].type==VMType::INT?a[1].i:(int64_t)to_d(a[1]);
            if(i<0)i+=(int64_t)s.size();
            return (i>=0&&i<(int64_t)s.size())?VMVal::make_str(std::string(1,s[i])):VMVal::make_str("");
        });
        globals_["string_repeat"]=globals_["str_repeat"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_str("");
            int64_t n=a[1].type==VMType::INT?a[1].i:(int64_t)to_d(a[1]);
            std::string r; for(int64_t i=0;i<n;i++) r+=a[0].s; return VMVal::make_str(r);
        });
        globals_["string_replace"]=globals_["str_replace"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3) return VMVal::make_str(a.empty()?"":a[0].s);
            std::string s=a[0].s,from=a[1].s,to=a[2].s; size_t p=0;
            while((p=s.find(from,p))!=std::string::npos){s.replace(p,from.size(),to);p+=to.size();}
            return VMVal::make_str(s);
        });
        globals_["string_to_int"]=globals_["str_to_int"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_int(0);
            try{return VMVal::make_int(std::stoll(a[0].s));}catch(...){return VMVal::make_int(0);}
        });
        globals_["string_to_float"]=globals_["str_to_float"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_float(0.0);
            try{return VMVal::make_float(std::stod(a[0].s));}catch(...){return VMVal::make_float(0.0);}
        });
        globals_["string_reverse"]=globals_["str_reverse"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string r=a[0].s; std::reverse(r.begin(),r.end()); return VMVal::make_str(r);
        });
        globals_["string_startswith"]=globals_["str_startswith"]=globals_["string_starts"]=globals_["str_starts"]=globals_["string_has_prefix"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            std::string& s=a[0].s,& p=a[1].s;
            return VMVal::make_bool(s.size()>=p.size()&&s.substr(0,p.size())==p);
        });
        globals_["string_endswith"]=globals_["str_endswith"]=globals_["string_ends"]=globals_["str_ends"]=globals_["string_has_suffix"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2) return VMVal::make_bool(false);
            std::string& s=a[0].s,& e=a[1].s;
            return VMVal::make_bool(s.size()>=e.size()&&s.substr(s.size()-e.size())==e);
        });
        globals_["string_len"]=globals_["str_len"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            return VMVal::make_int(a.empty()?0:(int64_t)a[0].s.size());
        });
        globals_["string_upper"]=globals_["str_upper_fn"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string r=a[0].s; for(auto& c:r) c=(char)toupper((unsigned char)c); return VMVal::make_str(r);
        });
        globals_["string_lower_fn"]=globals_["str_lower_fn"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string r=a[0].s; for(auto& c:r) c=(char)tolower((unsigned char)c); return VMVal::make_str(r);
        });
        globals_["hex_color"]=globals_["color_hex"]=globals_["rgb_to_hex"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.size()<3) return VMVal::make_str("#000000");
            int r=std::max(0,std::min(255,(int)(a[0].type==VMType::INT?a[0].i:to_d(a[0]))));
            int g=std::max(0,std::min(255,(int)(a[1].type==VMType::INT?a[1].i:to_d(a[1]))));
            int b=std::max(0,std::min(255,(int)(a[2].type==VMType::INT?a[2].i:to_d(a[2]))));
            char buf[8]; snprintf(buf,sizeof(buf),"#%02x%02x%02x",r,g,b);
            return VMVal::make_str(buf);
        });
        globals_["string_format"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            std::string s=a[0].s,r; size_t arg=1,pos=0,found;
            while((found=s.find("{}",pos))!=std::string::npos){
                r+=s.substr(pos,found-pos);
                r+=(arg<a.size()?a[arg++].to_string():"");
                pos=found+2;
            }
            return VMVal::make_str(r+s.substr(pos));
        });
        // count_words helper used by StringUtils
        globals_["count_words"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_int(0);
            std::istringstream ss(a[0].s); std::string tok; int c=0;
            while(ss>>tok) c++;
            return VMVal::make_int(c);
        });
        // JSON encode/decode globals
        
    }

    // ── Disassembly helper ──────────────────────────────────────────────
    static std::string op_name(Op op) {
        switch(op){
        case Op::LOAD_CONST:   return "LOAD_CONST";
        case Op::LOAD_NAME:    return "LOAD_NAME";
        case Op::STORE_NAME:   return "STORE_NAME";
        case Op::DEFINE_NAME:  return "DEFINE_NAME";
        case Op::LOAD_ATTR:    return "LOAD_ATTR";
        case Op::STORE_ATTR:   return "STORE_ATTR";
        case Op::LOAD_SUBSCR:  return "LOAD_SUBSCR";
        case Op::STORE_SUBSCR: return "STORE_SUBSCR";
        case Op::BUILD_LIST:   return "BUILD_LIST";
        case Op::BUILD_TUPLE:  return "BUILD_TUPLE";
        case Op::BUILD_MAP:    return "BUILD_MAP";
        case Op::DUP_TOP:      return "DUP_TOP";
        case Op::POP_TOP:      return "POP_TOP";
        case Op::ROT_TWO:      return "ROT_TWO";
        case Op::BINARY_ADD:   return "BINARY_ADD";
        case Op::BINARY_SUB:   return "BINARY_SUB";
        case Op::BINARY_MUL:   return "BINARY_MUL";
        case Op::BINARY_DIV:   return "BINARY_DIV";
        case Op::BINARY_MOD:   return "BINARY_MOD";
        case Op::BINARY_POW:   return "BINARY_POW";
        case Op::BINARY_FLOOR_DIV: return "BINARY_FLOOR_DIV";
        case Op::BINARY_AND:   return "BINARY_AND";
        case Op::BINARY_OR:    return "BINARY_OR";
        case Op::BINARY_XOR:   return "BINARY_XOR";
        case Op::BINARY_LSHIFT:return "BINARY_LSHIFT";
        case Op::BINARY_RSHIFT:return "BINARY_RSHIFT";
        case Op::COMPARE_EQ:   return "COMPARE_EQ";
        case Op::COMPARE_SEQ:  return "COMPARE_SEQ";
        case Op::COMPARE_SNE:  return "COMPARE_SNE";
        case Op::LOGICAL_XOR:  return "LOGICAL_XOR";
        case Op::COMPARE_NE:   return "COMPARE_NE";
        case Op::COMPARE_LT:   return "COMPARE_LT";
        case Op::COMPARE_LE:   return "COMPARE_LE";
        case Op::COMPARE_GT:   return "COMPARE_GT";
        case Op::COMPARE_GE:   return "COMPARE_GE";
        case Op::COMPARE_IN:   return "COMPARE_IN";
        case Op::COMPARE_NOT_IN: return "COMPARE_NOT_IN";
        case Op::COMPARE_IS:   return "COMPARE_IS";
        case Op::COMPARE_IS_NOT: return "COMPARE_IS_NOT";
        case Op::UNARY_NEG:    return "UNARY_NEG";
        case Op::UNARY_NOT:    return "UNARY_NOT";
        case Op::UNARY_BITNOT: return "UNARY_BITNOT";
        case Op::JUMP_FORWARD: return "JUMP_FORWARD";
        case Op::JUMP_IF_TRUE: return "JUMP_IF_TRUE";
        case Op::JUMP_IF_FALSE:return "JUMP_IF_FALSE";
        case Op::JUMP_ABSOLUTE:return "JUMP_ABSOLUTE";
        case Op::JUMP_IF_TRUE_OR_POP:  return "JUMP_IF_TRUE_OR_POP";
        case Op::JUMP_IF_FALSE_OR_POP: return "JUMP_IF_FALSE_OR_POP";
        case Op::MAKE_FUNCTION:return "MAKE_FUNCTION";
        case Op::CALL_FUNCTION:return "CALL_FUNCTION";
        case Op::CALL_METHOD:  return "CALL_METHOD";
        case Op::CALL_EX:      return "CALL_EX";
        case Op::LIST_EXTEND:  return "LIST_EXTEND";
        case Op::LIST_APPEND:  return "LIST_APPEND";
        case Op::LOAD_SUPER:   return "LOAD_SUPER";
        case Op::RETURN_VALUE: return "RETURN_VALUE";
        case Op::YIELD_FROM_OP: return "YIELD_FROM_OP";
        case Op::MAKE_CLASS:   return "MAKE_CLASS";
        case Op::LOAD_SELF:    return "LOAD_SELF";
        case Op::GET_ITER:     return "GET_ITER";
        case Op::FOR_ITER:     return "FOR_ITER";
        case Op::UNPACK_SEQ:   return "UNPACK_SEQ";
        case Op::PRINT:        return "PRINT";
        case Op::IMPORT_NAME:  return "IMPORT_NAME";
        case Op::NOP:          return "NOP";
        case Op::HALT:         return "HALT";
        case Op::RAISE_ERROR:  return "RAISE_ERROR";
        case Op::SETUP_EXCEPT: return "SETUP_EXCEPT";
        case Op::END_EXCEPT:   return "END_EXCEPT";
        default:               return "???";
        }
    }
};

using VM = VirtualMachine;

} // namespace nython::vm

#pragma GCC diagnostic pop

#endif // VIRTUAL_MACHINE_HPP
