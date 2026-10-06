#pragma once// VirtualMachine.hpp — Nython Bytecode VM
// Compiler: AST → Bytecode. VM: Stack-based execution engine.
#ifndef __VIRTUAL_MACHINE__HPP
#define __VIRTUAL_MACHINE__HPP

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmisleading-indentation"

#include <memory>
#include <mutex>
#include <vector>
#include <deque>
#include <string>
#include <unordered_map>
#include <set>
#include <map>
#include <tuple>
#include <mutex>
#include <functional>
#include "platform_compat.hpp"   // ny_fs (directories on every platform)
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
#include "NyExcTypes.hpp"
#include "NyOrderedMap.hpp"
#include "NyBigInt.hpp"
#include "NyStr.hpp"
#include "NyBytes.hpp"
#include "NyScope.hpp"
#include "NyFormat.hpp"
#include "NyRuntime.hpp"
#include "NyMembers.hpp"
#include "NyPrelude.hpp"
#include "NyConc.hpp"   // concurrency runtime shared with the interpreter
#include "NyCoro.hpp"   // thread tokens: a started generator stays on its thread
#include <random>

#include "Value.hpp"
#include "Object.hpp"
#include "Lexer.hpp"
#include "Parser.hpp"
#include "Runnable.hpp"
#include "ASTNodes.hpp"
#include "Context.hpp"
#include "NyGC.hpp"     // rss_kb (round 75)

using nython::Runnable;
using nython::kernel::Value;
using nython::kernel::ValueType;
using nython::kernel::Object;

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
    // try/finally and with (see ExceptionEntry): FIN_NORMAL pushes the
    // "fell off the end" state, FIN_RETURN turns the returned value into a
    // pending-return state, FIN_JUMP a pending break/continue to arg;
    // END_FINALLY acts on the state once the finally body has run.
    FIN_NORMAL, FIN_RETURN, FIN_JUMP, END_FINALLY,
    WITH_ENTER, WITH_EXIT,
    BINARY_MATMUL,   // a @ b: __matmul__ / __rmatmul__ only
    MAP_MERGE,       // f(**d): TOS (a map) merged into the map below it
    // A tuple display `(a, b)`: BUILD_LIST's items, as a tuple (VMVal::is_tuple).
    BUILD_TUPLE,
    // Optional chaining and ?? / ??= (round 75; OptChainNode in ASTNodes.hpp).
    // JUMP_IF_NONE_KEEP: TOS none/undefined -> TOS = none, jump.
    // JUMP_IF_MISSING_KEEP: TOS the absent marker -> TOS = none, jump.
    // JUMP_IF_NOT_NONE_OR_POP: TOS neither none, undefined nor absent -> jump
    //   keeping it; else pop it.
    // LOAD_ATTR_OPT / LOAD_SUBSCR_OPT: as LOAD_ATTR / LOAD_SUBSCR, but a
    //   missing member / key / index pushes the absent marker.
    // CHECK_MEMBER: TOS lacks member names[arg] -> TOS = the absent marker.
    // DUP_TOP_TWO: a b -> a b a b.
    JUMP_IF_NONE_KEEP, JUMP_IF_MISSING_KEEP, JUMP_IF_NOT_NONE_OR_POP,
    LOAD_ATTR_OPT, LOAD_SUBSCR_OPT, CHECK_MEMBER, DUP_TOP_TWO,
    // A name declared `global` in the running function (VariableNode::
    // global_ref): read / bound at module level, created there if new.
    LOAD_GLOBAL_NAME, STORE_GLOBAL_NAME,
    // del x: unbinds the nearest x (a later read is a NameError).
    DELETE_NAME,
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
    BYTES,   // bytes (b false: data in s) or bytearray (b true: data in (*list)[0].s, shared)
};

struct VMCode;  // forward declaration (defined after VMVal)
struct VMVal;
// Dicts, instance fields and closure environments: insertion-ordered, so a
// dict iterates in the order its keys were added (as in Python).
using VMMap = nypy::OrderedMap<VMVal>;
using NativeFunc = std::function<struct VMVal(std::vector<struct VMVal>&)>;
} // namespace nython::vm
#include "VMGC.hpp"   // cycle collection for the containers below (round 75)
namespace nython::vm {

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
    // A set or frozenset (round 77): a list of its elements in insertion
    // order, with `map` indexing them by key (VirtualMachine::set_key).
    bool is_set() const { return type==VMType::LIST && map && (class_name=="__set__"||class_name=="__frozenset__"); }
    bool is_frozenset() const { return is_set() && class_name=="__frozenset__"; }
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
    // bytes / bytearray (round 77). A bytearray's data lives in a shared
    // one-element list, so every copy of the value sees a change.
    static VMVal make_bytes(std::string data, bool mut=false) {
        VMVal x; x.type=VMType::BYTES; x.b=mut;
        if(mut){ x.list=std::make_shared<std::vector<VMVal>>(1); (*x.list)[0].s=std::move(data); }
        else x.s=std::move(data);
        return x;
    }
    bool is_bytearray() const { return type==VMType::BYTES&&b; }
    const std::string& bdata() const { return (b&&list&&!list->empty())?(*list)[0].s:s; }
    std::string& bdata_mut() { return (b&&list&&!list->empty())?(*list)[0].s:s; }
    static VMVal make_none()              { return {}; }
    // UNDEFINED carries a tag in s: "undefined" is the language's
    // `undefined` value (distinct from none, falsy, absent to ?? and ?.);
    // untagged is the "not found" sentinel frames and defaults use;
    // "__absent__" is what an optional read (?. / ?[) pushes for a missing
    // member or key, consumed by the jump that follows it; "__fin__" is a
    // try/finally state (make_fin_state).
    static VMVal make_undefined()         { VMVal x; x.type=VMType::UNDEFINED; x.s="undefined"; return x; }
    static VMVal make_absent()            { VMVal x; x.type=VMType::UNDEFINED; x.s="__absent__"; return x; }
    bool is_missing() const               { return type==VMType::UNDEFINED && s.empty(); }
    bool is_absent_marker() const         { return type==VMType::UNDEFINED && s=="__absent__"; }
    // none or undefined: what ?? replaces and ?. short-circuits on
    bool is_nullish() const               { return type==VMType::NONE || type==VMType::UNDEFINED; }
    static VMVal make_bool(bool v)        { VMVal x; x.type=VMType::BOOL;  x.b=v; return x; }
    static VMVal make_int(int64_t v)      { VMVal x; x.type=VMType::INT;   x.i=v; return x; }
    static VMVal make_float(double v)     { VMVal x; x.type=VMType::FLOAT; x.d=v; return x; }
    static VMVal make_str(std::string v)  { VMVal x; x.type=VMType::STRING;x.s=std::move(v); return x; }
    static VMVal make_list(std::vector<VMVal> items={}) {
        VMVal x; x.type=VMType::LIST;
        x.list=vmgc::make_deep<std::vector<VMVal>>(std::move(items));
        vmgc::track_list(x.list);
        return x;
    }
    static VMVal make_map() {
        VMVal x; x.type=VMType::MAP;
        x.map=vmgc::make_deep<VMMap>();
        vmgc::track_map(x.map);
        return x;
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
        x.iter=vmgc::make_deep<std::pair<int,std::vector<VMVal>>>(0,std::move(items));
        vmgc::track_iter(x.iter);
        return x;
    }

    bool is_truthy() const {
        switch(type){
        case VMType::NONE:   return false;
        case VMType::UNDEFINED: return false;
        case VMType::BOOL:   return b;
        case VMType::INT:    return i!=0||!s.empty();
        case VMType::FLOAT:  return d!=0.0;
        case VMType::STRING: return !s.empty();
        case VMType::BYTES:  return !bdata().empty();
        case VMType::LIST:   return list&&!list->empty();
        case VMType::MAP:    return map&&!map->empty();
        default:             return true;
        }
    }

    std::string to_string() const;
    std::string repr() const;

    // A builtin type native's name (int, str, dict, ...), "" for anything else.
    std::string builtin_type_name() const {
        if(type!=VMType::NATIVE) return "";
        const std::string& c=class_name;
        std::string b=c.rfind("__builtin__:",0)==0?c.substr(12):c.rfind("__native__:",0)==0?c.substr(11):c;
        if(b=="map") b="dict";
        return nyrt::is_builtin_type_name(b)?b:std::string();
    }
    // A type object (a class or builtin type) named n: Python's name or the
    // legacy one type() returned ("string", "map", "class") - round 77.
    bool type_object_named(const std::string& n) const {
        if(type==VMType::CLASS) return nyrt::shown_class_name(class_name)==n;
        std::string b=builtin_type_name();
        if(b.empty()) return false;
        return n==b||(b=="str"&&n=="string")||(b=="dict"&&n=="map")||(b=="type"&&n=="class");
    }
    bool operator==(const VMVal& o) const {
        if(type==VMType::STRING&&(o.type==VMType::NATIVE||o.type==VMType::CLASS)) return o.type_object_named(s);
        if(o.type==VMType::STRING&&(type==VMType::NATIVE||type==VMType::CLASS)) return type_object_named(o.s);
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
        case VMType::BYTES:  return bdata()==o.bdata();   // bytes == bytearray by content
        case VMType::LIST:
            if(is_set()||o.is_set()){   // sets: the same keys, in any order
                if(!is_set()||!o.is_set()||map->size()!=o.map->size()) return false;
                for(auto& kv:*map) if(!o.map->count(kv.first)) return false;
                return true;
            }
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
        // Functions, classes, generators and iterators compare by identity
        // (f == f was false, so a handler could not be found in a list).
        case VMType::FUNCTION:
            return code.get()==o.code.get() && closure_env.get()==o.closure_env.get() && list.get()==o.list.get();
        case VMType::CLASS:  return code.get()==o.code.get() && class_name==o.class_name;
        case VMType::GENERATOR: return gen.get()==o.gen.get();
        case VMType::ITERATOR:  return iter.get()==o.iter.get();
        case VMType::NATIVE: {
            std::string a=builtin_type_name(), b=o.builtin_type_name();
            if(!a.empty()||!b.empty()) return a==b;
            return !class_name.empty() && class_name==o.class_name;
        }
        case VMType::UNDEFINED: return s==o.s;   // undefined == undefined
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
        if(type==VMType::BYTES&&o.type==VMType::BYTES) return bdata()<o.bdata();
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
    // One try (or with) statement. Its body [try_start, try_end) is covered
    // by the except clauses and then the finally; the handlers and the else
    // [try_end, finally_start) by the finally only. An exception that no
    // clause matches runs the finally and propagates (it used to be silently
    // dropped); one raised by a handler or the else runs the finally too.
    int try_start = 0;
    int try_end   = 0;
    struct Clause {
        std::vector<std::string> types;  // empty = catch-all
        std::string bind_var;            // empty = don't bind
        int handler = 0;                 // offset of the clause body
    };
    std::vector<Clause> clauses;
    int else_handler = -1;
    // Offset of the finally body, -1 if there is none. The body runs with a
    // pending state (normal / exception / return / break-continue) on the
    // stack, consumed by the END_FINALLY that closes it.
    int finally_start = -1;
    // Values that stay on the operand stack across the statement - one per
    // enclosing `for` loop's iterator, one per enclosing finally's pending
    // state - so a handler can drop whatever a half-evaluated expression
    // left behind when it raised (a raise in the middle of a list literal
    // inside a for loop otherwise left the literal's items above the loop's
    // iterator, and the loop stopped).
    int depth = 0;
    int end = 0;
    // The hidden variable its except clauses keep the exception in (a bare
    // `raise`, _ny_exc_current): an exception leaving a clause clears it
    // (round 77 - it stayed, and sys.exc_info() / __context__ saw it later).
    std::string held;
};

struct VMCode {
    std::string              name;
    std::string              doc;           // docstring (__doc__, round 77)
    bool                     has_doc = false;
    std::string              file;          // source file (diagnostics)
    std::string              parent_class;
    std::vector<std::string> bases;         // every base class, in order (parent_class is bases[0])
    std::string              owner_class;   // class that defines this method
    std::vector<Instruction> instructions;
    std::vector<VMVal>       constants;
    std::vector<std::string> names;
    std::vector<std::string> param_names;
    std::vector<VMVal>       param_defaults; // parallel to param_names; UNDEFINED = no default
    // For each default value MAKE_FUNCTION pops, the param_names index it
    // belongs to (defaults used to be aligned to the END of the parameter
    // list, which put them on the wrong parameters when *args, keyword-only
    // parameters or **kwargs followed).
    std::vector<int>         default_idx;
    size_t                   posonly = 0;   // param_names before a bare `/` (PEP 570)
    bool                     is_class      = false;
    bool                     is_method     = false;
    bool                     is_static     = false;
    bool                     is_classmethod= false;
    bool                     is_generator  = false;
    // For inspect / __code__ / __qualname__ (round 77): the parser's
    // qualified name, `async def` (its body is rewritten, so nothing else
    // says), and the line of the def.
    std::string              qualname;
    bool                     qualname_set = false;   // a __qualname__ assigned by the program (call errors use it)
    bool                     is_async = false, is_async_gen = false;
    int                      first_line = 0;
    std::shared_ptr<VMMap> closure_env;
    // Code of a module imported by name (round 77): the module's own scope,
    // where its top level (module_top) defines its names and its functions
    // find them - in place of the main program's frame.
    std::shared_ptr<VMMap> module_env;
    bool                   module_top = false;
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
    // Whether this function is a generator: a yield in its own body. A yield
    // in a nested function belongs to that function - searching sub_codes
    // made every function that merely defines a generator a generator
    // itself (make(k) returning an inner generator function returned a
    // generator instead).
    bool has_yield() const {
        if(yield_known) return yield_cached;
        bool y=false;
        for(auto& ins:instructions) if(ins.op==Op::YIELD_VALUE||ins.op==Op::YIELD_FROM_OP){ y=true; break; }
        yield_cached=y; yield_known=true;
        return y;
    }
    mutable bool yield_known=false, yield_cached=false;
    int  here() const { return (int)instructions.size(); }
};


// Class names that derive from BaseException - builtin or user-defined -
// filled in as classes are made, so a bare VMVal can tell an exception
// instance (which prints as its message) from any other instance.
inline std::unordered_set<std::string>& vm_exc_classes() {
    static std::unordered_set<std::string> s; return s;
}
// Which exception classes have fields str() is made from (NyExcTypes.hpp
// NyExcKind: KeyError, OSError, the Unicode errors), by class name, filled
// as vm_exc_classes is (round 77).
inline std::unordered_map<std::string,int>& vm_exc_kinds() {
    static std::unordered_map<std::string,int> m; return m;
}
inline int vm_exc_kind_of(const std::string& cn) {
    auto it=vm_exc_kinds().find(cn);
    return it==vm_exc_kinds().end()?0:it->second;
}
// Python's BaseException.__str__: no args -> "", one -> str(arg) (a
// KeyError: its repr), more -> the args tuple; an OSError's and the Unicode
// errors' own from their fields (round 77, as on the interpreter).
inline std::string vm_exc_message(const VMVal& e) {
    if(!e.map) return std::string();
    int kind=vm_exc_kind_of(e.class_name);
    auto field=[&](const char* k)->VMVal{ auto f=e.map->find(k); return f==e.map->end()?VMVal::make_none():f->second; };
    if(kind==nython::NYX_OS){
        VMVal en=field("errno"), se=field("strerror"), f1=field("filename"), f2=field("filename2");
        if(f1.type!=VMType::NONE)
            return "[Errno "+en.to_string()+"] "+se.to_string()+": "+f1.repr()+(f2.type==VMType::NONE?std::string():" -> "+f2.repr());
        if(en.type!=VMType::NONE&&se.type!=VMType::NONE) return "[Errno "+en.to_string()+"] "+se.to_string();
    } else if(nython::ny_exc_kind_unicode(kind)){
        VMVal ob=field("object"), sv=field("start"), ev=field("end");
        if(ob.type!=VMType::NONE&&sv.type==VMType::INT&&ev.type==VMType::INT&&sv.s.empty()&&ev.s.empty()){
            long long one=-1;
            if(kind==nython::NYX_UDECODE){
                if(ob.type==VMType::BYTES){ const std::string& bs=ob.bdata(); if(sv.i>=0&&(size_t)sv.i<bs.size()&&ev.i==sv.i+1) one=(unsigned char)bs[(size_t)sv.i]; }
            } else if(ob.type==VMType::STRING&&sv.i>=0&&ev.i==sv.i+1){
                auto ch=nypy::u8_chars(ob.s);
                if((size_t)sv.i<ch.size()){ size_t j=0; one=nypy::u8_decode(ch[(size_t)sv.i],j); }
            }
            VMVal enc=field("encoding");
            return nython::ny_unicode_error_message(kind, enc.type==VMType::NONE?std::string():enc.to_string(), one, sv.i, ev.i, field("reason").to_string());
        }
    } else if(kind==nython::NYX_SYNTAX){
        VMVal fn=field("filename"), ln=field("lineno");
        bool hf=fn.type==VMType::STRING, hl=ln.type==VMType::INT&&ln.s.empty();
        if(hf||hl) return nython::ny_syntax_message(field("msg").to_string(), hf, hf?fn.s:std::string(), hl, hl?ln.i:0);
    }
    auto it=e.map->find("args");
    if(it!=e.map->end()&&it->second.type==VMType::LIST&&it->second.list){
        auto& a=*it->second.list;
        if(a.empty()) return std::string();
        if(a.size()==1) return kind==nython::NYX_KEY?a[0].repr():a[0].to_string();
        std::string r="(";
        for(size_t k=0;k<a.size();k++){ if(k) r+=", "; r+=a[k].repr(); }
        return r+")";
    }
    return std::string();
}

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
        case nypy::K_BYTES: return VMVal::make_bytes(k.substr(2));
        case nypy::K_OBJ: {
            auto it=vm_key_objs().find(k.substr(2));
            return it!=vm_key_objs().end()?it->second:VMVal::make_none();
        }
    }
    return VMVal::make_none();
}
inline bool vm_internal_key(const std::string& k){ return k.size()>=2&&k[0]=='_'&&k[1]=='_'; }
// The lists and dicts being shown right now on this thread (CPython's
// Py_ReprEnter): one met again inside itself - `a.append(a)`, or through
// another container - is shown as [...] / {...} (round 77; only a direct
// self-reference was caught, and a cycle through two overflowed the stack).
inline std::vector<const void*>& vm_repr_active() { static thread_local std::vector<const void*> v; return v; }
struct VMReprEnter {
    const void* key; bool again=false, pushed=false;
    explicit VMReprEnter(const void* k) : key(k) {
        if(!k) return;
        auto& a=vm_repr_active();
        for(const void* p:a) if(p==k){ again=true; return; }
        a.push_back(k); pushed=true;
    }
    ~VMReprEnter(){ if(pushed&&!vm_repr_active().empty()) vm_repr_active().pop_back(); }
    VMReprEnter(const VMReprEnter&)=delete;
    VMReprEnter& operator=(const VMReprEnter&)=delete;
};
struct GenState;
inline std::string vm_gen_repr(const GenState* g);   // after GenState

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
        if(is_set()){
            bool fz=is_frozenset();
            if(!list||list->empty()) return fz?"frozenset()":"set()";
            std::string r=fz?"frozenset({":"{";
            for(size_t k=0;k<list->size();k++){ if(k) r+=", "; r+=(*list)[k].repr(); }
            return r+(fz?"})":"}");
        }
        VMReprEnter guard(list.get());
        if(guard.again) return b?"(...)":"[...]";
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
        VMReprEnter guard(map.get());
        if(guard.again) return "{...}";
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
    case VMType::CLASS:    return nyrt::class_repr(class_name);
    case VMType::INSTANCE: {
        // An exception reads as its message, as in Python: str(e) is the
        // message, not "Type: message" (that is how an uncaught one is
        // reported, not what the value is).
        if(map && vm_exc_classes().count(class_name)) return vm_exc_message(*this);
        return "<"+nyrt::shown_class_name(class_name)+" instance>";
    }
    case VMType::NATIVE:
        if(class_name.rfind("__builtin__:",0)==0){
            std::string bn=class_name.substr(12);
            if(nyrt::is_builtin_type_name(bn)) return "<class '"+bn+"'>";
            return "<built-in function "+bn+">";
        }
        if(nyrt::is_builtin_type_name(class_name)) return "<class '"+class_name+"'>";
        if(class_name.rfind("__native__:",0)==0){
            std::string bn=class_name.substr(11);
            if(bn=="map") bn="dict";
            if(nyrt::is_builtin_type_name(bn)) return "<class '"+bn+"'>";
            return "<built-in function "+bn+">";
        }
        if(class_name=="map") return "<class 'dict'>";
        return "<native>";
    case VMType::ITERATOR: {
        char buf[32];
        std::snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)(uintptr_t)iter.get());
        return std::string("<iterator object at ") + buf + ">";
    }
    case VMType::GENERATOR: return vm_gen_repr(gen.get());
    case VMType::BYTES:    return nypy::bytes_repr(bdata(), b);
    default:               return "undefined";
    }
}
inline std::string VMVal::repr() const {
    // Python's repr of a string (quotes and escapes chosen as Python does),
    // matching the interpreter.
    if(type==VMType::STRING) return nypy::str_repr(s);
    // An exception instance: Type(args...), as Python shows it.
    if(type==VMType::INSTANCE && map && vm_exc_classes().count(class_name)){
        // the class's own name, as type(e).__name__ (round 77: not "m.E" / "E#2")
        std::string r=nyrt::shown_class_name(class_name);
        size_t dot=r.rfind('.');
        if(dot!=std::string::npos) r=r.substr(dot+1);
        r+="(";
        auto it=map->find("args");
        if(it!=map->end()&&it->second.type==VMType::LIST&&it->second.list)
            for(size_t k=0;k<it->second.list->size();k++){ if(k) r+=", "; r+=(*it->second.list)[k].repr(); }
        return r+")";
    }
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

inline bool is_ident_text(const std::string& n) {
    if(n.empty()||!(std::isalpha((unsigned char)n[0])||n[0]=='_')) return false;
    for(char c:n) if(!(std::isalnum((unsigned char)c)||c=='_')) return false;
    return true;
}

class Compiler {
    std::shared_ptr<VMCode>              code_;
    std::vector<std::shared_ptr<VMCode>> code_stack_;
    int comp_counter_ = 0;

    void push_code(const std::string& name, bool is_class=false) {
        auto c=std::make_shared<VMCode>(); c->name=name; c->is_class=is_class;
        code_stack_.push_back(code_); code_=c;
        body_saves_.push_back({std::move(loops_),std::move(fin_stack_),persist_depth_,std::move(exc_vars_)});
        loops_.clear(); fin_stack_.clear(); persist_depth_=0; exc_vars_.clear();
    }
    std::shared_ptr<VMCode> pop_code() {
        {
            auto& sv=body_saves_.back();
            loops_=std::move(sv.loops); fin_stack_=std::move(sv.fins);
            persist_depth_=sv.depth; exc_vars_=std::move(sv.ev);
            body_saves_.pop_back();
        }
        auto c=code_; code_=code_stack_.back(); code_stack_.pop_back();
        // If this code is a method inside a class, tag its owner_class
        if(code_->is_class && c->owner_class.empty())
            c->owner_class = code_->name;
        code_->sub_codes.push_back(c); return c;
    }
    VMCode& C() { return *code_; }

    void emit(Op op,int arg=0,int ln=0)    { C().emit(op,arg,ln); }
    void emit_lc(VMVal v,int ln=0)         { emit(Op::LOAD_CONST,  C().add_const(std::move(v)),ln); }
    void emit_ln(const std::string& n,int l=0){ emit(Op::LOAD_NAME,  C().add_name(rn(n)),l); }
    void emit_sn(const std::string& n,int l=0){ emit(Op::STORE_NAME, C().add_name(rn(n)),l); }
    void emit_dn(const std::string& n,int l=0){ emit(Op::DEFINE_NAME,C().add_name(rn(n)),l); }

    // Comprehension targets are compiled under hidden names (the
    // comprehension's own scope, so they no longer overwrite a same-named
    // variable of the enclosing one). Innermost scope last; a function or
    // lambda parameter maps to itself, shadowing an outer rename.
    std::vector<std::unordered_map<std::string,std::string>> renames_;
    std::string rn(const std::string& n) const {
        for(auto it=renames_.rbegin(); it!=renames_.rend(); ++it){
            auto f=it->find(n);
            if(f!=it->end()) return f->second;
        }
        return n;
    }
    static void target_names(const nython::node::node_ptr& t, std::vector<std::string>& out){
        if(!t) return;
        if(t->type()==nython::node::NodeType::TUPLE||t->type()==nython::node::NodeType::LIST){ for(auto& e:t->statements()) target_names(e,out); return; }
        out.push_back(t->token().value);
    }
    // Stores TOS into a comprehension/for target, unpacking tuples.
    void store_target(const nython::node::node_ptr& t, int l){
        if(t->type()==nython::node::NodeType::TUPLE||t->type()==nython::node::NodeType::LIST){
            auto el=t->statements();
            emit(Op::UNPACK_SEQ,(int)el.size(),l);
            for(auto& e:el) store_target(e,l);
            return;
        }
        emit_dn(t->token().value,l);
    }
    int comp_id_ = 0;
    int  ln(nython::node::node_ptr nd) {
        if(!nd) return 0;
        if(C().file.empty()) C().file=nd->token().fileName();
        return nd->token().location().row;
    }

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

    // try/finally and with: the finally blocks the code being compiled is
    // inside (innermost last), so return/break/continue can run them first.
    struct FinCtx { int entry; size_t loop_depth; std::vector<int> jumps; };
    std::vector<FinCtx> fin_stack_;
    // Operand-stack values held across statements here (ExceptionEntry::depth).
    int persist_depth_ = 0;
    // Hidden variables holding the exception each enclosing except clause is
    // handling, for a bare `raise`.
    std::vector<std::string> exc_vars_;
    int try_counter_ = 0;
    // Emits a jump to the innermost enclosing finally (patched when its
    // offset is known).
    void jump_to_finally(int l){
        fin_stack_.back().jumps.push_back(C().here());
        emit(Op::JUMP_ABSOLUTE,-1,l);
    }
    // True when a break/continue here leaves a try/with inside the innermost
    // loop, and so must run that statement's finally first.
    bool loop_exit_crosses_finally() const {
        return !loops_.empty() && !fin_stack_.empty() && fin_stack_.back().loop_depth >= loops_.size();
    }
    // A function, lambda or class body starts with none of the above: a
    // `break` in a nested function does not belong to the enclosing loop and
    // a `return` there does not run the enclosing function's finally blocks.
    struct SavedBody { std::vector<LoopCtx> loops; std::vector<FinCtx> fins; int depth; std::vector<std::string> ev; };
    std::vector<SavedBody> body_saves_;

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
    // Every expression used as a statement leaves its value on the operand
    // stack and must be popped. Only calls, tuples and lists used to be: any
    // other expression statement - a docstring, `x == 1`, `a[i]` - left a
    // value behind, and inside a `for` loop FOR_ITER then read that value
    // instead of the loop's iterator and the loop silently ended after one
    // pass.
    static bool pushes_value(const np& nd) {
        switch(nd->type()){
        case NT::INTEGER: case NT::FLOAT: case NT::STRING: case NT::BYTES: case NT::TRUE:
        case NT::FALSE: case NT::NONE: case NT::UNDEFINED: case NT::OPT_CHAIN: case NT::VARIABLE: case NT::SELF:
        case NT::SUPER: case NT::ATTRIBUTE: case NT::SUBSCRIPT: case NT::UNARY:
        case NT::BINARY: case NT::CALL: case NT::LIST: case NT::TUPLE:
        case NT::MAP: case NT::COMPLEX: case NT::LAMBDA: case NT::WALRUS: case NT::COMPREHENSION:
        case NT::RANGE: case NT::SLICE: case NT::YIELD: case NT::YIELD_FROM:
            return true;
        case NT::IF:
            return std::static_pointer_cast<nython::node::IfNode>(nd)->is_expr;
        default:
            return false;
        }
    }
    void visit_stmt(np nd) {
        if(!nd) return;
        // `super()` on its own as a statement is Nython's shorthand for
        // calling the parent constructor (super(args) with arguments is
        // handled at run time: see vm_call's SUPER_PROXY case).
        if(nd->type()==NT::CALL){
            auto cn=std::static_pointer_cast<nython::node::CallNode>(nd);
            if(cn->callee && cn->callee->type()==NT::SUPER && cn->args.empty()){
                int l=ln(nd);
                emit(Op::LOAD_SUPER,0,l);
                emit_lc(VMVal::make_str("__init__"),l);
                emit(Op::CALL_METHOD,0,l);
                emit(Op::POP_TOP,0,l);
                return;
            }
        }
        visit(nd);
        if(pushes_value(nd)) emit(Op::POP_TOP,0,ln(nd));
    }

    // ─── dispatch ──────────────────────────────────────────────────────────
    void visit(np nd) {
        if(!nd) return;
        int l=ln(nd);
        switch(nd->type()) {
        // Literals
        case NT::INTEGER: emit_lc(int_literal(nd->token().value),l); break;
        case NT::FLOAT:   emit_lc(VMVal::make_float(std::strtod(nd->token().value.c_str(),nullptr)),l); break;   // 5e-324 / 1e400: strtod, not stod (it threw)
        case NT::STRING:  emit_lc(VMVal::make_str(nd->token().value),l); break;
        case NT::BYTES:   emit_lc(VMVal::make_bytes(nd->token().value),l); break;
        case NT::TRUE:    emit_lc(VMVal::make_bool(true),l); break;
        case NT::FALSE:   emit_lc(VMVal::make_bool(false),l); break;
        case NT::NONE:    emit_lc(VMVal::make_none(),l); break;
        case NT::UNDEFINED: emit_lc(VMVal::make_undefined(),l); break;
        // Optional chaining: the hole's value is already on the stack.
        case NT::CHAIN_HOLE: break;
        case NT::OPT_CHAIN: visit_opt_chain(std::static_pointer_cast<nython::node::OptChainNode>(nd)); break;

        // Names
        case NT::VARIABLE:
            if(std::static_pointer_cast<nython::node::VariableNode>(nd)->global_ref)
                emit(Op::LOAD_GLOBAL_NAME,C().add_name(nd->token().value),l);
            else emit_ln(nd->token().value,l);
            break;
        case NT::SELF:     emit(Op::LOAD_SELF,0,l); break;
        case NT::SUPER:    emit(Op::LOAD_SUPER,0,l); break;

        // Var decl
        case NT::VARIABLE_DECL: {
            auto vd=std::static_pointer_cast<nython::node::VarDeclNode>(nd);
            if(vd->unpack!=-2 && vd->init){
                // a, b = rhs: a generator or iterator is read into a list
                // first (__unpack_seq__), which the targets then index.
                emit(Op::LOAD_NAME,C().add_name("__unpack_seq__"),l);
                visit(vd->init);
                emit_lc(VMVal::make_int(vd->unpack),l);
                emit(Op::CALL_FUNCTION,2,l);
                emit_dn(vd->name,l); break;
            }
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
                        emit(Op::STORE_SUBSCR,1,l);   // 1: the index is a slice spec
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
            if(an->op=="?\?="){ visit_coalesce_assign(an.get(),l); break; }
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
            // a ?? b: b only when a is none or undefined (and only then evaluated).
            if(op=="??") {
                visit(b->left); int j=C().here();
                emit(Op::JUMP_IF_NOT_NONE_OR_POP,0,l); visit(b->right);
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
                    // A builtin type word (int, list, ...) is always a type
                    // test. Any other capitalised name is decided at run time
                    // (COMPARE_IS_TYPE arg 1): a type test when it names a
                    // class, identity when it is an ordinary value - `L is L`
                    // for a list named L was compiled as a type test and read
                    // false.
                    static const std::set<std::string> words = {
                        "int","Integer","integer","float","Float","double","Double",
                        "str","String","string","bool","Boolean","boolean",
                        "list","List","array","Array","map","Map","dict","Dict",
                        "tuple","Tuple","set","Set",
                        "none","None","function","Function","Object","object","any","Any"};
                    visit(b->left);
                    emit_lc(VMVal::make_str(tn),l);
                    emit(op=="is not"?Op::COMPARE_IS_NOT_TYPE:Op::COMPARE_IS_TYPE, words.count(tn)?0:1, l);
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
            // Inside try/finally or with: run the finally blocks first.
            if(!fin_stack_.empty()){ emit(Op::FIN_RETURN,0,l); jump_to_finally(l); }
            else emit(Op::RETURN_VALUE,0,l);
            break;
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
            C().qualname=lm->qualname; C().first_line=l; C().file=lm->token().fileName();   // round 77
            // a first parameter named self is bound as a def's is (round 77:
            // it was dropped, so `(lambda self: self)(5)` was an arity error)
            C().is_method=!lm->params.empty()&&lm->params[0]->value()=="self";
            renames_.emplace_back();
            for(auto& p:lm->params){
                std::string pn=p->value(); if(pn=="self") continue;
                C().param_names.push_back(pn); C().add_name(pn);
                renames_.back()[pn]=pn;
            }
            if(lm->body){ visit(lm->body); emit(Op::RETURN_VALUE,0,l); }
            else{ emit_lc(VMVal::make_none(),l); emit(Op::RETURN_VALUE,0,l); }
            renames_.pop_back();
            C().param_defaults.assign(C().param_names.size(), VMVal{VMType::UNDEFINED});
            pop_code();
            {
                // Lambda defaults (`lambda x, y=2: ...`) were ignored.
                auto lcode=C().sub_codes.back();
                int n_def=0, pn_idx=0;
                for(int i=0;i<(int)lm->params.size();i++){
                    if(lm->params[i]->value()=="self") continue;
                    if(i<(int)lm->defaults.size()&&lm->defaults[i]){
                        visit(lm->defaults[i]); n_def++;
                        lcode->default_idx.push_back(pn_idx);
                    }
                    pn_idx++;
                }
                emit(Op::MAKE_FUNCTION,((int)C().sub_codes.size()-1)|(n_def<<16),l);
            }
            break;
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
            if(wn->global_ref) emit(Op::STORE_GLOBAL_NAME,C().add_name(wn->name),l);
            else emit_dn(wn->name,l);
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
                emit(Op::DELETE_NAME,C().add_name(rn(dn->target->token().value)),l);
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
                        emit(Op::DELETE_SUBSCR,1,l);   // 1: the index is a slice spec
                    }
                }
                break;
            }
            break;
        }
        // Switch/match
        case NT::WITH: {
            // with E as x: body  ==  ctx = E; x = ctx.__enter__() (or ctx
            // itself when it has none); try: body; finally: ctx.__exit__(...)
            // __exit__ gets (type, value, none) for an exception, and a truthy
            // result suppresses it; every other way out - falling off the
            // end, return, break, continue - gets (none, none, none).
            auto wn=std::static_pointer_cast<nython::node::WithNode>(nd);
            int l2=ln(wn);
            std::string ctx_tmp="__with_ctx"+std::to_string(try_counter_++)+"__";
            visit(wn->expr);
            emit_dn(ctx_tmp,l2);
            emit_ln(ctx_tmp,l2);
            emit(Op::WITH_ENTER,0,l2);
            if(wn->alias.empty()) emit(Op::POP_TOP,0,l2);
            else if(wn->alias_global) emit(Op::STORE_GLOBAL_NAME,C().add_name(wn->alias),l2);
            else emit_dn(wn->alias,l2);
            int idx=(int)C().exc_table.size();
            C().exc_table.emplace_back();
            C().exc_table[idx].depth=persist_depth_;
            fin_stack_.push_back({idx,loops_.size(),{}});
            C().exc_table[idx].try_start=C().here();
            if(wn->body) visit_stmt(wn->body);
            C().exc_table[idx].try_end=C().here();
            FinCtx fc=std::move(fin_stack_.back()); fin_stack_.pop_back();
            emit(Op::FIN_NORMAL,0,l2);
            int fs=C().here();
            C().exc_table[idx].finally_start=fs;
            for(int j:fc.jumps) C().patch(j,fs);
            emit_ln(ctx_tmp,l2);
            emit(Op::WITH_EXIT,0,l2);
            emit(Op::END_FINALLY, fin_stack_.empty()?-1:fin_stack_.back().entry, l2);
            C().exc_table[idx].end=C().here();
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
                    if(cn->body) visit_stmt(cn->body);
                    wildcard_handled=true;
                    break;
                }
                emit(Op::DUP_TOP,0,l);
                visit(cn->value_node);
                emit(Op::COMPARE_EQ,0,l);
                int jf=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
                emit(Op::POP_TOP,0,l);
                if(cn->body) visit_stmt(cn->body);
                end_jumps.push_back(C().here()); emit(Op::JUMP_FORWARD,0,l);
                C().patch(jf,C().here());
            }
            if(!wildcard_handled){
                emit(Op::POP_TOP,0,l);
                // default_case is a DefaultNode wrapping the body; visiting
                // the wrapper itself compiled to a NOP, so `default:` never
                // ran on the VM.
                if(sw->default_case){
                    auto dn=std::static_pointer_cast<nython::node::DefaultNode>(sw->default_case);
                    if(dn->body) visit_stmt(dn->body);
                }
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
            if(nn->body) for(auto& s:nn->body->statements()) visit_stmt(s);
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
            if(in_->body) for(auto& s:in_->body->statements()) visit_stmt(s);
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
            // Comprehensions are ComprehensionNodes now; a ComplexNode is a
            // complex-number literal (`2j`), which has no items to index.
            if(cn->items.size()<2){ emit_lc(VMVal::make_none(),l); break; }
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

        case NT::COMPREHENSION: {
            auto cn=std::static_pointer_cast<nython::node::ComprehensionNode>(nd);
            using CK=nython::node::ComprehensionNode;
            if(cn->kind==CK::GEN && !cn->clauses.empty()){
                // (elt for t in it if c ...) is lazy (round 75): a generator
                // function of its own,
                //     def <genexpr>(.0): for t in .0: if c: yield elt
                // called with iter(it) - the first iterable is evaluated, and
                // iter() applied, now, in the enclosing scope (as in Python).
                push_code("<genexpr>");
                C().param_names.push_back(".0"); C().add_name(".0");
                renames_.emplace_back();
                renames_.back()[".0"]=".0";
                for(auto& cl:cn->clauses){
                    std::vector<std::string> names; target_names(cl.target,names);
                    for(auto& n:names) renames_.back()[n]=n;
                }
                std::vector<int> gexits, gtops;
                for(size_t k=0;k<cn->clauses.size();k++){
                    auto& cl=cn->clauses[k];
                    if(k==0) emit(Op::LOAD_NAME,C().add_name(".0"),l);
                    else visit(cl.iter);
                    emit(Op::GET_ITER,0,l);
                    int top=C().here(); gtops.push_back(top);
                    gexits.push_back(C().here()); emit(Op::FOR_ITER,0,l);
                    store_target(cl.target,l);
                    for(auto& c:cl.conds){ visit(c); emit(Op::JUMP_IF_FALSE,top,l); }
                }
                visit(cn->elt);
                emit(Op::YIELD_VALUE,0,l);
                emit(Op::POP_TOP,0,l);
                for(int k=(int)cn->clauses.size()-1;k>=0;k--){
                    emit(Op::JUMP_ABSOLUTE,gtops[k],l);
                    C().patch(gexits[k],C().here());
                }
                emit_lc(VMVal::make_none(),l);
                emit(Op::RETURN_VALUE,0,l);
                renames_.pop_back();
                C().param_defaults.assign(C().param_names.size(), VMVal{VMType::UNDEFINED});
                pop_code();
                emit(Op::MAKE_FUNCTION,(int)C().sub_codes.size()-1,l);
                visit(cn->clauses[0].iter);
                emit(Op::GET_ITER,0,l);
                emit(Op::CALL_FUNCTION,1,l);
                break;
            }
            int id=comp_id_++;
            std::string acc="__comp"+std::to_string(id)+"__";
            if(cn->kind==CK::DICT) emit(Op::BUILD_MAP,0,l); else emit(Op::BUILD_LIST,0,l);
            emit(Op::DEFINE_NAME,C().add_name(acc),l);
            // The first iterable is evaluated in the enclosing scope.
            if(!cn->clauses.empty()) visit(cn->clauses[0].iter);
            renames_.emplace_back();
            for(auto& cl:cn->clauses){
                std::vector<std::string> names; target_names(cl.target,names);
                for(auto& n:names) renames_.back()[n]="__c"+std::to_string(id)+"_"+n;
            }
            std::vector<int> exits;
            std::vector<int> tops;
            for(size_t k=0;k<cn->clauses.size();k++){
                auto& cl=cn->clauses[k];
                if(k>0) visit(cl.iter);
                emit(Op::GET_ITER,0,l);
                int top=C().here(); tops.push_back(top);
                exits.push_back(C().here()); emit(Op::FOR_ITER,0,l);
                store_target(cl.target,l);
                for(auto& c:cl.conds){ visit(c); emit(Op::JUMP_IF_FALSE,top,l); }
            }
            if(cn->kind==CK::DICT){
                visit(cn->value);
                emit(Op::LOAD_NAME,C().add_name(acc),l);
                visit(cn->elt);
                emit(Op::STORE_SUBSCR,0,l);
            } else {
                emit(Op::LOAD_NAME,C().add_name(acc),l);
                visit(cn->elt);
                emit(Op::LIST_APPEND,0,l);
                emit(Op::POP_TOP,0,l);
            }
            // Close the loops innermost first: each jumps back to its own
            // FOR_ITER; an exhausted inner loop falls through to the next
            // iteration of the one around it.
            for(int k=(int)cn->clauses.size()-1;k>=0;k--){
                emit(Op::JUMP_ABSOLUTE,tops[k],l);
                C().patch(exits[k],C().here());
            }
            renames_.pop_back();
            if(cn->kind==CK::SET){
                emit_ln("set",l);
                emit(Op::LOAD_NAME,C().add_name(acc),l);
                emit(Op::CALL_FUNCTION,1,l);
            } else emit(Op::LOAD_NAME,C().add_name(acc),l);
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
            if(loop_exit_crosses_finally()){ emit(Op::FIN_JUMP,-9991,l); jump_to_finally(l); }
            else emit(Op::JUMP_ABSOLUTE,-9991,l);
            break;
        case NT::CONTINUE:
            if(loop_exit_crosses_finally()){ emit(Op::FIN_JUMP,-9992,l); jump_to_finally(l); }
            else emit(Op::JUMP_ABSOLUTE,-9992,l);
            break;

        // Import
        case NT::IMPORT: {
            auto in=std::static_pointer_cast<nython::node::ImportNode>(nd);
            std::string mn=in->module_name;
            if(mn.size()>=2&&(mn[0]=='"'||mn[0]=='\'')) mn=mn.substr(1,mn.size()-2);
            // `import "x" as m` — the alias travels with the module name so the
            // runtime can bind the namespace. The interpreter now does this;
            // without it here the same program would bind an alias on one
            // engine and not the other.
            bool bare=!in->quoted&&!in->module_name.empty()&&in->module_name[0]!='"'&&in->module_name[0]!='\'';
            if(!in->names.empty()){
                // `from m import a, b` (round 77): the names travel too
                std::string ns;
                for(auto& n:in->names){ if(!ns.empty()) ns+=","; ns+=n; }
                mn = mn + "\x04" + ns;
            }
            else if(!in->alias.empty())
                mn = mn + "\x01" + in->alias;
            else if(bare&&is_ident_text(mn))
                mn = mn + "\x03" + mn;     // `import name` binds name (round 77)
            if(bare) mn = "\x02" + mn;     // a module named without quotes
            emit(Op::IMPORT_NAME,C().add_name(mn),l); break;
        }


        // Raise
        case NT::RAISE: {
            auto rn=std::static_pointer_cast<nython::node::RaiseNode>(nd);
            if(!rn->expr){
                // Bare `raise` re-raises the exception the enclosing except
                // clause is handling. It used to raise the string "Exception",
                // which no typed clause matched.
                if(!exc_vars_.empty()){ emit_ln(exc_vars_.back(),l); emit(Op::RAISE_ERROR,1,l); }
                else {
                    // outside an except clause of its own: the exception a
                    // caller's except clause is handling - a helper called
                    // from one re-raises it (round 77) - else RuntimeError
                    emit_ln("_ny_exc_current",l); emit(Op::CALL_FUNCTION,0,l);
                    emit(Op::RAISE_ERROR,3,l);
                }
                break;
            }
            visit(rn->expr);
            if(rn->cause){ visit(rn->cause); emit(Op::RAISE_ERROR,2,l); }
            else emit(Op::RAISE_ERROR,0,l);
            break;
        }
        // Assert: raises AssertionError(message) - it raised the bare message
        // string (or the string "AssertionError"), which `except
        // AssertionError` could not catch.
        case NT::ASSERT: {
            auto an=std::static_pointer_cast<nython::node::AssertNode>(nd);
            visit(an->condition);
            int jt=C().here(); emit(Op::JUMP_IF_TRUE,0,l);
            emit_ln("AssertionError",l);
            if(an->message){ visit(an->message); emit(Op::CALL_FUNCTION,1,l); }
            else emit(Op::CALL_FUNCTION,0,l);
            emit(Op::RAISE_ERROR,0,l);
            C().patch(jt,C().here()); break;
        }
        case NT::TRY: {
            auto tn=std::static_pointer_cast<nython::node::TryNode>(nd);
            int idx=(int)C().exc_table.size();
            C().exc_table.emplace_back();
            C().exc_table[idx].depth=persist_depth_;
            bool has_fin=(bool)tn->finally_clause;
            if(has_fin) fin_stack_.push_back({idx,loops_.size(),{}});
            C().exc_table[idx].try_start=C().here();
            if(tn->body) visit_stmt(tn->body);
            C().exc_table[idx].try_end=C().here();
            // Jump over the handlers when no exception was raised.
            int jmp_over=C().here(); emit(Op::JUMP_FORWARD,0,l);
            // Every except clause is its own handler entry point; which one
            // runs is decided at runtime (match_except_handler) from the
            // raised exception's class and each clause's types. The
            // exception is kept in a hidden variable for a bare `raise`.
            std::string held="__exc"+std::to_string(try_counter_++)+"__";
            if(!tn->except_clauses.empty()) C().exc_table[idx].held=rn(held);
            std::vector<int> to_exit;
            for(auto& ec:tn->except_clauses){
                auto en=std::static_pointer_cast<nython::node::ExceptNode>(ec);
                ExceptionEntry::Clause cl;
                cl.types=en->types; cl.bind_var=en->var;
                cl.handler=C().here();
                emit_dn(held,l);
                if(!en->var.empty()){
                    emit_ln(held,l);
                    if(en->var_global) emit(Op::STORE_GLOBAL_NAME,C().add_name(en->var),l);
                    else emit_dn(en->var,l);
                }
                exc_vars_.push_back(held);
                if(en->body) visit_stmt(en->body);
                exc_vars_.pop_back();
                // The clause is done with the exception: _ny_exc_current()
                // (sys.exc_info's source) no longer reports it.
                emit(Op::DELETE_NAME,C().add_name(rn(held)),l);
                to_exit.push_back(C().here()); emit(Op::JUMP_FORWARD,0,l);
                C().exc_table[idx].clauses.push_back(std::move(cl));
            }
            C().patch(jmp_over,C().here());
            C().exc_table[idx].else_handler = tn->else_clause ? C().here() : -1;
            if(tn->else_clause) visit_stmt(tn->else_clause);
            int exit_pt=C().here();
            for(int j:to_exit) C().patch(j,exit_pt);
            if(has_fin){
                FinCtx fc=std::move(fin_stack_.back()); fin_stack_.pop_back();
                emit(Op::FIN_NORMAL,0,l);
                int fs=C().here();
                C().exc_table[idx].finally_start=fs;
                for(int j:fc.jumps) C().patch(j,fs);
                persist_depth_++;
                visit_stmt(tn->finally_clause);
                persist_depth_--;
                emit(Op::END_FINALLY, fin_stack_.empty()?-1:fin_stack_.back().entry, l);
            }
            C().exc_table[idx].end=C().here();
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
        // An expression-if's branches are values; a statement-if's are
        // statements (IfNode::is_expr, set by the parser for ternaries).
        auto branch=[&](np b){ if(nd->is_expr) visit(b); else visit_stmt(b); };
        visit(nd->condition);
        int jf=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
        branch(nd->then_branch);
        std::vector<int> ends; ends.push_back(C().here());
        emit(Op::JUMP_FORWARD,0,l);
        C().patch(jf,C().here());
        for(auto& ei:nd->elseif_branches){
            auto eif=std::static_pointer_cast<nython::node::IfNode>(ei);
            visit(eif->condition);
            int jf2=C().here(); emit(Op::JUMP_IF_FALSE,0,l);
            branch(eif->then_branch);
            ends.push_back(C().here()); emit(Op::JUMP_FORWARD,0,l);
            C().patch(jf2,C().here());
        }
        if(nd->else_branch) branch(nd->else_branch);
        else if(nd->is_expr) emit_lc(VMVal::make_none(),l);
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
                if((ins.op==Op::JUMP_ABSOLUTE||ins.op==Op::FIN_JUMP)&&ins.arg==end)
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
        // A name declared `global` is the module's (VariableNode::global_ref).
        auto bind_loop=[&](const std::string& n){
            bool glob=false;
            auto gref=[](const np& v){ return v && v->type()==NT::VARIABLE && std::static_pointer_cast<nython::node::VariableNode>(v)->global_ref; };
            if(nd->var && nd->var->value()==n) glob=gref(nd->var);
            for(auto& u:nd->unpack_vars) if(!glob && u->value()==n) glob=gref(u);
            if(glob) emit(Op::STORE_GLOBAL_NAME,C().add_name(n),l);
            else if(nd->rebinds) emit_sn(n,l); else emit_dn(n,l);
        };
        if(!nd->unpack_vars.empty()) {
            // for a, b, c in ...: FOR_ITER pushed [a_val, b_val,...]; unpack by index
            std::string tmp="__for_unpack__";
            emit_dn(tmp,l);
            // Assign first var (nd->var)
            int idx0=C().add_const(VMVal::make_int(0));
            emit_ln(tmp,l); emit(Op::LOAD_CONST,idx0,l); emit(Op::LOAD_SUBSCR,0,l);
            bind_loop(nd->var?nd->var->value():"_");
            // Assign rest (nd->unpack_vars)
            for(int ui=0;ui<(int)nd->unpack_vars.size();ui++){
                int ci=C().add_const(VMVal::make_int(ui+1));
                emit_ln(tmp,l); emit(Op::LOAD_CONST,ci,l); emit(Op::LOAD_SUBSCR,0,l);
                bind_loop(nd->unpack_vars[ui]->value());
            }
        } else {
            // The loop variable is a local of the running function (as on
            // the interpreter): a STORE rebound a global of the same name,
            // so `for i in ...` inside any function overwrote a module `i`.
            // Declared global/nonlocal: the existing binding is rebound.
            bind_loop(nd->var?nd->var->value():"_");
        }
        persist_depth_++;   // the iterator stays on the stack during the body
        visit_stmt(nd->body);
        persist_depth_--;
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
                if((ins.op==Op::JUMP_ABSOLUTE||ins.op==Op::FIN_JUMP) && ins.arg==end)
                    ins.arg=else_end;
            }
        }
    }

    void patch_loop(int start, int end) {
        for(int i=start;i<end;i++){
            auto& ins=C().instructions[i];
            if(ins.op==Op::JUMP_ABSOLUTE||ins.op==Op::FIN_JUMP){
                if(ins.arg==-9991) ins.arg=end;
                if(ins.arg==-9992) ins.arg=start;
            }
        }
    }

    // ─── function ───────────────────────────────────────────────────────
    void visit_func(std::shared_ptr<nython::node::FunctionNode> fn) {
        int l=ln(fn);
        push_code(fn->name);
        C().doc=fn->doc; C().has_doc=fn->has_doc;
        C().qualname=fn->qualname; C().is_async=fn->is_async; C().is_async_gen=fn->is_async_gen;   // round 77
        C().first_line=fn->first_line?fn->first_line:l; C().file=fn->token().fileName();
        C().is_method=!fn->params.empty()&&fn->params[0]->value()=="self";
        int param_idx=0;
        for(int i=0;i<(int)fn->params.size();i++){
            std::string pn=fn->params[i]->value(); if(pn=="self") continue;
            if((size_t)i<fn->posonly) C().posonly=C().param_names.size()+1;
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
                    case NT::FLOAT:   dflt=VMVal::make_float(std::strtod(dn->token().value.c_str(),nullptr)); break;
                    case NT::STRING:  dflt=VMVal::make_str(dn->token().value); break;
                    case NT::TRUE:    dflt=VMVal::make_bool(true); break;
                    case NT::FALSE:   dflt=VMVal::make_bool(false); break;
                    case NT::NONE:    dflt=VMVal::make_none(); break;
                    case NT::UNDEFINED: dflt=VMVal::make_undefined(); break;
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
        renames_.emplace_back();
        for(auto& p:fn->params){ std::string pn=p->value(); renames_.back()[pn]=pn; }
        if(fn->body) visit_stmt(fn->body);
        renames_.pop_back();
        emit_lc(VMVal::make_none(),l); emit(Op::RETURN_VALUE,0,l);
        // Now store defaults: compile each default expr and store result
        // We can't easily do this at compile time for non-literal defaults.
        // Store default AST nodes → evaluate at MAKE_FUNCTION time (runtime).
        pop_code();
        int idx=(int)C().sub_codes.size()-1;
        auto fcode=C().sub_codes.back();
        // Every default is evaluated here, once, when the def runs, in the
        // scope the def is in - and MAKE_FUNCTION keeps the values with that
        // function value (VMVal::list), not in the shared code object.
        int n_defaults=0, pn_idx=0;
        for(int i=0;i<(int)fn->params.size();i++){
            if(fn->params[i]->value()=="self") continue;
            if(i<(int)fn->defaults.size()&&fn->defaults[i]){
                visit(fn->defaults[i]); n_defaults++;
                fcode->default_idx.push_back(pn_idx);
            }
            pn_idx++;
        }
        // __init_subclass__ / __class_getitem__ in a class body are
        // classmethods without the decorator, as in Python (round 77)
        if(C().is_class&&(fn->name=="__init_subclass__"||fn->name=="__class_getitem__")) fcode->is_classmethod=true;
        // MAKE_FUNCTION arg = idx | (n_defaults << 16)
        emit(Op::MAKE_FUNCTION, idx|(n_defaults<<16), l);
        // f.__annotations__, evaluated when the def runs (round 77)
        if(fn->annotations){
            emit(Op::DUP_TOP,0,l);
            visit(fn->annotations);
            emit(Op::ROT_TWO,0,l);
            emit(Op::STORE_ATTR,C().add_name("__annotations__"),l);
        }
        emit_dn(fn->name,l);
    }

    // ─── class ──────────────────────────────────────────────────────────
    void visit_class(std::shared_ptr<nython::node::ClassNode> cn) {
        int l=ln(cn);
        push_code(cn->name,true);
        code_->is_class=true;  // mark this sub_code as a class
        code_->doc=cn->doc; code_->has_doc=cn->has_doc;
        // A base given by an expression (Generic[T], a call) is evaluated
        // before MAKE_CLASS; its slot is "\x06<i>" until then (round 77).
        std::vector<np> expr_bases;
        for(auto& b:cn->bases){
            if(b->type()==NT::VARIABLE) code_->bases.push_back(b->token().value);
            else { code_->bases.push_back(std::string("\x06")+std::to_string(expr_bases.size())); expr_bases.push_back(b); }
        }
        if(!code_->bases.empty()) code_->parent_class=code_->bases[0];
        // a one-line body (`class A: x = 1`) is a statement, not a block
        if(cn->body&&cn->body->type()!=NT::BLOCK) visit_stmt(cn->body);
        else if(cn->body) for(auto& s:cn->body->statements()) visit_stmt(s);
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
        // the class keywords (a map) and the expression bases (a list)
        bool extras=!expr_bases.empty()||!cn->keywords.empty();
        if(extras){
            for(auto& [k,e]:cn->keywords){ emit_lc(VMVal::make_str(k),l); visit(e); }
            emit(Op::BUILD_MAP,(int)cn->keywords.size(),l);
            for(auto& e:expr_bases) visit(e);
            emit(Op::BUILD_LIST,(int)expr_bases.size(),l);
        }
        emit(Op::MAKE_CLASS,idx|(extras?(1<<24):0),l); emit_dn(cn->bind_name.empty()?cn->name:cn->bind_name,l);
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
        bool has_dstar=false;
        for(auto& arg:pos_args)
            if(arg->type()==NT::UNARY && std::static_pointer_cast<nython::node::UnaryNode>(arg)->op=="**") has_dstar=true;
        int argc=(int)pos_args.size();
        // ── Spread call: f(*xs, **d), with any keywords ──────────────────
        // The positionals are gathered into one fresh list (*xs extends
        // it) and the keywords into one fresh map (**d merges into it);
        // CALL_EX's arg is 1 (list) or 2 (list and map), negative for a
        // method call. `**d` used to be passed as a positional, and the
        // keywords of a call with *xs were dropped.
        if(has_star||has_dstar){
            bool method=cn->callee->type()==NT::ATTRIBUTE;
            if(method){
                auto a=std::static_pointer_cast<nython::node::AttributeNode>(cn->callee);
                visit(a->object); emit_lc(VMVal::make_str(a->attr),l);
            } else visit(cn->callee);
            emit(Op::BUILD_LIST,0,l); // fresh empty list per call (not a constant!)
            for(auto& arg:pos_args){
                if(arg->type()==NT::UNARY){
                    auto u=std::static_pointer_cast<nython::node::UnaryNode>(arg);
                    if(u->op=="*"){ visit(u->operand); emit(Op::LIST_EXTEND,0,l); continue; }
                    if(u->op=="**") continue;
                }
                visit(arg); emit(Op::LIST_APPEND,0,l);
            }
            int n=1;
            if(has_kw||has_dstar){
                for(size_t i=0;i<kw_names.size();i++){
                    emit_lc(VMVal::make_str(kw_names[i]),l); visit(kw_vals[i]);
                }
                emit(Op::BUILD_MAP,(int)kw_names.size(),l);
                for(auto& arg:pos_args){
                    if(arg->type()!=NT::UNARY) continue;
                    auto u=std::static_pointer_cast<nython::node::UnaryNode>(arg);
                    if(u->op=="**"){ visit(u->operand); emit(Op::MAP_MERGE,0,l); }
                }
                n=2;
            }
            emit(Op::CALL_EX,method?-n:n,l);
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
                emit(Op::CALL_KW,-(argc+1),l);   // negative: a method call
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

    // ─── optional chaining (OptChainNode) ─────────────────────────────────
    // recv; if none/undefined -> none, done. The link: an attribute or key
    // (missing -> none, done), a method call (receiver lacks the member ->
    // none, done), a slice or a call. Then the rest of the chain, compiled
    // against the value left on the stack (its hole compiles to nothing:
    // every postfix step evaluates its receiver first).
    void visit_opt_chain(std::shared_ptr<nython::node::OptChainNode> oc) {
        using OC=nython::node::OptChainNode;
        int l=ln(oc);
        std::vector<int> ends;
        visit(oc->recv);
        ends.push_back(C().emit(Op::JUMP_IF_NONE_KEEP,0,l));
        switch(oc->kind){
            case OC::ATTR:
                emit(Op::LOAD_ATTR_OPT,C().add_name(oc->name),l);
                ends.push_back(C().emit(Op::JUMP_IF_MISSING_KEEP,0,l));
                break;
            case OC::INDEX:
                visit(oc->index);
                emit(Op::LOAD_SUBSCR_OPT,0,l);
                ends.push_back(C().emit(Op::JUMP_IF_MISSING_KEEP,0,l));
                break;
            case OC::METHOD:
                emit(Op::CHECK_MEMBER,C().add_name(oc->name),l);
                ends.push_back(C().emit(Op::JUMP_IF_MISSING_KEEP,0,l));
                visit(oc->call);
                break;
            default:   // SLICE, CALL
                visit(oc->call);
                break;
        }
        if(oc->rest) visit(oc->rest);
        int end=C().here();
        for(int j:ends) C().patch(j,end);
    }
    // t ??= v (the interpreter's evalCoalesceAssign): v is evaluated and
    // stored only when t is none/undefined or, for an attribute or a key,
    // missing; the target's object and index are evaluated once.
    void visit_coalesce_assign(nython::node::AugAssignNode* an, int l) {
        auto tt=an->target->type();
        int j, jend;
        if(tt==NT::ATTRIBUTE){
            auto a=std::static_pointer_cast<nython::node::AttributeNode>(an->target);
            int ni=C().add_name(a->attr);
            visit(a->object);                                   // obj
            emit(Op::DUP_TOP,0,l);                              // obj obj
            emit(Op::LOAD_ATTR_OPT,ni,l);                       // obj cur
            j=C().emit(Op::JUMP_IF_NOT_NONE_OR_POP,0,l);        // obj
            visit(an->value_node);                              // obj val
            emit(Op::ROT_TWO,0,l);                              // val obj
            emit(Op::STORE_ATTR,ni,l);
            jend=C().emit(Op::JUMP_FORWARD,0,l);
            C().patch(j,C().here());                            // obj cur
            emit(Op::POP_TOP,0,l); emit(Op::POP_TOP,0,l);
        } else if(tt==NT::SUBSCRIPT){
            auto sb=std::static_pointer_cast<nython::node::SubscriptNode>(an->target);
            visit(sb->object); visit(sb->index);                // obj idx
            emit(Op::DUP_TOP_TWO,0,l);                          // obj idx obj idx
            emit(Op::LOAD_SUBSCR_OPT,0,l);                      // obj idx cur
            j=C().emit(Op::JUMP_IF_NOT_NONE_OR_POP,0,l);        // obj idx
            visit(an->value_node);                              // obj idx val
            emit(Op::ROT_THREE,0,l);                            // val obj idx
            emit(Op::STORE_SUBSCR,0,l);
            jend=C().emit(Op::JUMP_FORWARD,0,l);
            C().patch(j,C().here());                            // obj idx cur
            emit(Op::POP_TOP,0,l); emit(Op::POP_TOP,0,l); emit(Op::POP_TOP,0,l);
        } else {
            load_target(an->target,l);                          // cur
            j=C().emit(Op::JUMP_IF_NOT_NONE_OR_POP,0,l);
            visit(an->value_node);
            store(an->target,l);
            jend=C().emit(Op::JUMP_FORWARD,0,l);
            C().patch(j,C().here());                            // cur
            emit(Op::POP_TOP,0,l);
        }
        C().patch(jend,C().here());
    }

    // ─── load target value (for augmented assignment) ──────────────────────────
    void load_target(np tgt, int l) {
        if(tgt->type()==NT::VARIABLE) {
            visit(tgt);
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
            if(std::static_pointer_cast<nython::node::VariableNode>(tgt)->global_ref)
                emit(Op::STORE_GLOBAL_NAME,C().add_name(tgt->token().value),l);
            else emit_sn(tgt->token().value,l);
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
        if(op=="@") return Op::BINARY_MATMUL;
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

class VirtualMachine;
struct GenState : std::enable_shared_from_this<GenState> {
    std::shared_ptr<VMCode> code;
    size_t ip=0;
    VMMap locals;
    std::optional<VMVal> self_val;
    std::shared_ptr<VMMap> closure;
    bool own_env = false;          // closure is the generator frame's own environment
    bool done=false;
    std::vector<VMVal> saved_stack; // intermediate stack at yield point
    size_t stack_base=0;           // stack level when generator was entered
    // Set by YIELD_VALUE / YIELD_FROM_OP just before run_loop returns the
    // yielded value, read (and cleared) by gen_resume: a yield and a return
    // both leave run_loop by an ordinary return now, not a C++ exception.
    bool yielded=false;
    // Suspended at a `yield` expression: resuming pushes the value sent in
    // (none for next()), which is the yield's value. Resuming used to push
    // nothing, so `v = yield x` stored whatever was below it on the stack -
    // the loop's iterator - and the generator stopped.
    bool at_yield=false;
    bool started=false;
    // ── Round 75: the whole protocol (VirtualMachine::gen_resume) ──────────
    bool running=false;          // resumed and not yet paused or finished
    bool in_yield_from=false;    // paused in YIELD_FROM_OP (its iterator on saved_stack)
    bool is_genexpr=false;       // a generator expression: not bound to a thread
    uint64_t owner=0;            // nycoro::thread_token() of the thread that started it
    uint64_t serial=0;           // order started in (closed oldest first at exit)
    int mode=0;                  // this resume: 0 next/send, 1 throw, 2 close
    VMVal sent;                  // send()'s value, for a paused `yield from`
    VMVal pending;               // what throw() raises at a paused `yield from`
    VMVal retval;                // `return v`: StopIteration.value
    std::string name;            // the function's name, "<genexpr>", "zip", ...
    // A lazy builtin (zip, map, filter, enumerate, islice) runs this instead
    // of code: the next value, or false once exhausted.
    std::function<bool(VMVal&)> native;
    VirtualMachine* vm=nullptr;  // the VM that runs it (its registry of live generators)
    GenState() = default;
    GenState(const GenState&) = delete;
    GenState& operator=(const GenState&) = delete;
    ~GenState();                 // after VirtualMachine: a paused one is closed
};
inline std::string vm_gen_repr(const GenState* g) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)(uintptr_t)g);
    // A lazy zip/map/filter/enumerate/islice prints as Python prints it.
    if (g && g->native) return "<" + g->name + " object at " + buf + ">";
    return "<generator object " + (g ? g->name : std::string("?")) + " at " + buf + ">";
}

inline VMVal make_generator_val(std::shared_ptr<VMCode> code,
                            std::vector<VMVal> args,
                            std::optional<VMVal> self,
                            std::shared_ptr<VMMap> closure=nullptr) {
    VMVal g; g.type=VMType::GENERATOR;
    g.gen=std::make_shared<GenState>();
    vmgc::track_gen(g.gen);
    g.gen->code=code; g.gen->ip=0; g.gen->self_val=self; g.gen->closure=closure;
    g.gen->name=code->name;
    g.gen->is_genexpr=code->name=="<genexpr>";
    int n=(int)code->param_names.size();
    int arg_idx=0;
    for(int i=0;i<n;i++){
        const std::string& pn=code->param_names[i];
        if(pn.size()>=2&&pn[0]=='*'&&pn[1]=='*'){
            // **kwargs: build map from remaining args (simplified)
            g.gen->locals[pn.substr(2)]=args.size()>(size_t)arg_idx?args[arg_idx]:VMVal::make_map();
            arg_idx=(int)args.size();
        } else if(!pn.empty()&&pn[0]=='*'){
            // *args: ALL remaining positional args, as a tuple (Python's type)
            std::vector<VMVal> rest(args.begin()+arg_idx, args.end());
            g.gen->locals[pn.substr(1)]=VMVal::make_tuple(std::move(rest));
            arg_idx=(int)args.size();
        } else if(arg_idx<(int)args.size()){
            g.gen->locals[pn]=args[arg_idx++];
        } else if(!code->param_defaults.empty()&&i<(int)code->param_defaults.size()
                  &&!code->param_defaults[i].is_missing()){
            g.gen->locals[pn]=code->param_defaults[i];
        }
    }
    g.gen->done=false;
    return g;
}

// Closure environments are chained (round 77). A frame that makes a
// closure gets an environment of its own (CallFrame::own_env) holding its
// variables, whose reserved entry env_up_key() links the environment of the
// function it runs in. They used to be one flat map per outermost function:
// every call of a nested function wrote its locals into it, so closures made
// by different calls shared one variable (`def mk(x): return lambda: x`
// called three times gave three lambdas returning the first x).
inline const std::string& env_up_key() { static const std::string k("\x01up"); return k; }
inline VMMap* env_up(VMMap* e) {
    if(!e) return nullptr;
    auto it=e->find(env_up_key());
    return it!=e->end() && it->second.map ? it->second.map.get() : nullptr;
}
// The nearest environment in the chain from e that binds n.
inline VMMap* env_find(VMMap* e, const std::string& n) {
    for(int d=0; e && d<256; e=env_up(e), d++) if(e->count(n)) return e;
    return nullptr;
}
// Whether env `inner`'s chain reaches `outer`.
inline bool env_reaches(VMMap* inner, VMMap* outer) {
    for(int d=0; inner && d<256; inner=env_up(inner), d++) if(inner==outer) return true;
    return false;
}

struct CallFrame {
    std::shared_ptr<VMCode>                       code;
    int                                           ip = 0;
    VMMap         locals;
    std::optional<VMVal>                          self_val;
    // The environment this frame's names resolve in after its locals: the
    // one its function closed over, or (own_env) its own, which links that.
    std::shared_ptr<VMMap> closure_env;
    bool own_env = false;

    bool has_local(const std::string& n) const {
        if(locals.count(n)) return true;
        return env_find(closure_env.get(), n)!=nullptr;
    }
    VMVal get_local(const std::string& n) const {
        // A frame with its own environment reads it first: a closure can
        // have rebound one of its variables there, from another thread too.
        if(own_env){
            auto e=closure_env->find(n);
            if(e!=closure_env->end()) return e->second;
        }
        auto it=locals.find(n);
        if(it!=locals.end()) return it->second;
        if(VMMap* e=env_find(own_env ? env_up(closure_env.get()) : closure_env.get(), n)) return (*e)[n];
        // Return undefined to signal not found
        VMVal undef; undef.type=VMType::UNDEFINED; return undef;
    }
    VMVal& local(const std::string& n)           { return locals[n]; }
    void   set(const std::string& n, VMVal v)    {
        // A local (mirrored in the frame's own environment); else the
        // nearest enclosing binding; else a new local.
        auto li=locals.find(n);
        if(li!=locals.end()){
            if(own_env) (*closure_env)[n]=v;
            li->second=std::move(v); return;
        }
        if(VMMap* e=env_find(closure_env.get(), n)){ (*e)[n]=std::move(v); return; }
        if(own_env) (*closure_env)[n]=v;
        locals[n]=std::move(v);
    }
    void define(const std::string& n, VMVal v) { locals[n]=std::move(v); }
    std::shared_ptr<GenState>  gen_state;   // non-null when executing a generator
    // Operand-stack height when the frame was entered; an exception handler
    // truncates to stack_base + ExceptionEntry::depth.
    size_t stack_base = 0;
};

struct VMReturn   { VMVal value; };
struct VMYield    { VMVal value; };
// A raised exception travelling up the C++ stack: the exception object itself
// (an instance of an exception class, or whatever value was raised), so it
// reaches an `except` in an outer frame intact. what() is the uncaught form,
// "Type: message". It used to be a plain runtime_error whose object rode in a
// VM member that the first frame it passed through cleared, so every
// exception raised in a called function arrived as a bare string that no
// typed clause could match.
struct VMException : std::runtime_error {
    VMVal value;
    VMException(VMVal v, const std::string& what) : std::runtime_error(what), value(std::move(v)) {}
};
// Pending state of a finally body (see ExceptionEntry): a VMVal of type
// UNDEFINED tagged "__fin__", kind in i, payload in list[0], jump target in d.
enum { FIN_K_NORMAL=0, FIN_K_RETURN=1, FIN_K_JUMP=2, FIN_K_EXC=3 };
inline VMVal make_fin_state(int kind, VMVal payload=VMVal::make_none(), int target=-1){
    VMVal v; v.type=VMType::UNDEFINED; v.s="__fin__"; v.i=kind; v.d=(double)target;
    v.list=std::make_shared<std::vector<VMVal>>(); vmgc::track_list(v.list); v.list->push_back(std::move(payload));
    return v;
}
inline bool is_fin_state(const VMVal& v){ return v.type==VMType::UNDEFINED && v.s=="__fin__" && v.list; }
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
    friend struct VMConc;
    friend struct VMConcEngine;

    // ── Generators (round 75) ───────────────────────────────────────────────
    // Declared before the stacks and globals, so they outlive every value a
    // destructor can reach them from. gen_live_: started, unfinished code
    // generators by start order (closed oldest first at the end of the
    // program); gen_zombies_: paused ones whose last reference went away
    // inside a try/with, closed between two instructions (gen_dropped).
    std::map<uint64_t, GenState*>                      gen_live_;
    std::vector<std::shared_ptr<GenState>>             gen_zombies_;
    uint64_t                                           gen_serial_ = 0;
    bool                                               gen_zombie_flag_ = false;
    bool                                               gen_finalize_ = false;   // a program is running
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
    // The call depth of the importing module's own frame: only ITS top-level
    // names are exported. Every `var` in every function the module's code
    // called was written to the globals too, so two functions' locals of
    // the same name overwrote each other (the IDE, run from an import,
    // called methods on a Command where it meant `self`).
    int export_depth_ = -1;
    bool exporting() const { return export_to_globals_ && (int)call_stack_.size()==export_depth_; }
    std::string cwd_ = ".";            // working directory for imports
    // Runs the pending signal handlers (set by VMConc::install; round 77).
    std::function<void()> signal_hook_;
    // Raises a runtime NyError into the VM as its own exception (VMConc).
    std::function<void(const nyconc::NyError&)> raise_nyerror_;
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
    // An uncaught KeyboardInterrupt ended the program (exit status 130).
    static bool& keyboard_interrupted() { static bool b=false; return b; }
    // A set of these elements (the builtin bridge, src/main.cpp).
    VMVal make_set_value(const std::vector<VMVal>& items, bool frozen) { return build_set(items, frozen); }
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
    // Names resolve lexically: the running frame's locals and closure, the
    // frames of the functions it is nested in (they share its closure
    // environment - MAKE_FUNCTION), the main module's frame, then globals.
    // Every frame on the call stack used to be searched, so a function read
    // and assigned its CALLER's local variables (dynamic scoping): a helper
    // doing `i = 99` changed the i of whichever function called it.
    // The module scope of the running code, when it belongs to a module
    // imported by name (VMCode::module_env).
    VMMap* menv() const {
        return call_stack_.empty() || !call_stack_.back().code ? nullptr : call_stack_.back().code->module_env.get();
    }
    bool frame_visible(int i) const {
        int top=(int)call_stack_.size()-1;
        if(i==top) return true;
        if(i==0) return !menv();       // a module's code does not see the program's frame
        const auto& env=call_stack_[top].closure_env;
        const auto& fe=call_stack_[i].closure_env;
        return env && fe && call_stack_[i].own_env && env_reaches(env.get(), fe.get());
    }
    // The frame's own closure environment, made on first need (a closure,
    // a class body or a comprehension made in it): its variables, linked to
    // the environment it already resolved names in.
    static VMMap* ensure_own_env(CallFrame& f) {
        if(!f.own_env){
            auto e=vmgc::make_deep<VMMap>(f.locals);
            vmgc::track_map(e);
            if(f.closure_env){
                VMVal up; up.type=VMType::MAP; up.map=f.closure_env;
                (*e)[env_up_key()]=up;
            }
            f.closure_env=e;
            f.own_env=true;
        } else {
            for(auto& kv : f.locals) (*f.closure_env)[kv.first]=kv.second;
        }
        if(f.self_val && !f.closure_env->count("self")) (*f.closure_env)["self"]=*f.self_val;
        return f.closure_env.get();
    }
    // Whether `n` names anything a LOAD_NAME can find (a variable in a
    // visible scope, a global, or an interpreter builtin).
    bool name_bound(const std::string& n) {
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            if(!frame_visible(i)) continue;
            const auto& f=call_stack_[i];
            if(f.has_local(n)) return true;
        }
        if(VMMap* me=menv()){ if(me->count(n)) return true; }
        else if(in_other_thread() && module_frame_ && !module_frame_->get_local(n).is_missing()) return true;
        if(globals_.count(n)) return true;
        return bridge_exists() && bridge_exists()(n);
    }
    VMVal load_var(const std::string& n) {
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            if(!frame_visible(i)) continue;
            auto v=call_stack_[i].get_local(n);
            if(!v.is_missing()) return v;
        }
        if(VMMap* me=menv()){
            auto mi=me->find(n);
            if(mi!=me->end()) return mi->second;
        } else if(in_other_thread()){                            // round 74
            auto mv=module_frame_->get_local(n);
            if(!mv.is_missing()) return mv;
        }
        auto it=globals_.find(n);
        if(it!=globals_.end()){
            // A builtin carries its name, so two reads of it compare equal
            // (len == len).
            if(it->second.type==VMType::NATIVE && it->second.class_name.empty())
                it->second.class_name="__native__:"+n;
            return it->second;
        }
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
    // del x: the nearest binding of x goes (the scopes store_var looks in).
    bool delete_var(const std::string& n) {
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            if(!frame_visible(i)) continue;
            auto& f=call_stack_[i];
            bool hit=f.locals.erase(n)>0;
            if(f.own_env && f.closure_env->erase(n)>0) hit=true;
            if(hit) return true;
        }
        if(VMMap* me=menv()) return me->erase(n)>0;
        if(in_other_thread() && module_frame_ && module_frame_->locals.erase(n)>0) return true;
        return globals_.erase(n)>0;
    }
    // A `global` name: the main module's frame, then globals (an imported
    // module's names and builtins), then an interpreter builtin.
    bool load_global(const std::string& n, VMVal& out) {
        if(VMMap* me=menv()){
            auto mi=me->find(n);
            if(mi!=me->end()){ out=mi->second; return true; }
        } else {
            CallFrame* mf=in_other_thread()?module_frame_:(call_stack_.empty()?nullptr:&call_stack_.front());
            if(mf){ out=mf->get_local(n); if(!out.is_missing()) return true; }
        }
        auto it=globals_.find(n);
        if(it!=globals_.end()){ out=it->second; return true; }
        if(bridge_exists() && bridge_exists()(n)){ out=load_var(n); return true; }
        return false;
    }
    void store_var(const std::string& n, VMVal v) {
        // An existing binding in a lexically visible scope is rebound
        // (Nython's `x = ...` updates an enclosing variable); otherwise the
        // name becomes a local of the running frame.
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            if(!frame_visible(i)) continue;
            auto& f=call_stack_[i];
            auto li=f.locals.find(n);
            bool in_locals=li!=f.locals.end();
            VMMap* env=in_locals&&!f.own_env ? nullptr : env_find(f.closure_env.get(), n);
            if(!in_locals && !env) continue;
            if(!env){ li->second=std::move(v); return; }   // the common case: one lookup
            // A closure variable is one binding: write it to the environment
            // that holds it and to every still-running frame that keeps a
            // copy of it (the enclosing function read its stale local after
            // an inner function assigned the variable: x += 1 in inc() left
            // outer's x unchanged).
            (*env)[n]=v;
            if(in_locals) f.locals[n]=v;
            for(int j=(int)call_stack_.size()-1;j>=0;j--){
                auto& g=call_stack_[j];
                if(j!=i && g.own_env && g.closure_env.get()==env && g.locals.count(n)) g.locals[n]=v;
            }
            return;
        }
        if(VMMap* me=menv()){
            // A module's top level, or a module variable rebound by one of
            // its functions.
            if(call_stack_.back().code->module_top || me->count(n)){ (*me)[n]=std::move(v); return; }
        } else if(in_other_thread() && module_frame_->has_local(n)){    // round 74
            module_frame_->set(n,std::move(v)); return;
        }
        if(!call_stack_.empty()) call_stack_.back().locals[n]=std::move(v);
        else globals_[n]=std::move(v);
    }
    void define_var(const std::string& n, VMVal v) {
        if(VMMap* me=menv()){
            if(call_stack_.back().code->module_top){ (*me)[n]=std::move(v); return; }
        }
        if(exporting()) {
            // An included file's name replaces the program's of the same
            // name, as later definitions in one scope do (the interpreter).
            if(!call_stack_.empty()) call_stack_.front().locals.erase(n);
            globals_[n]=std::move(v); return;
        }
        // A declaration (var/let/const, def, class, import) binds a local of
        // the running frame, shadowing an enclosing variable of that name
        // (round 77: it rebound the enclosing one once environments chained).
        if(!call_stack_.empty()){
            auto& f=call_stack_.back();
            if(f.own_env) (*f.closure_env)[n]=v;
            f.locals[n]=std::move(v);
        }
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
    { vm_live(this, 1); register_all_builtins(); }
    explicit VirtualMachine(Runnable* r)
        : Runnable((Reporter*)r, RunnableType::COMPILER)
    { vm_live(this, 1); register_all_builtins(); }

    // 171 general-purpose builtins (map, filter, reduce, any, all, next, set,
    // tuple, getattr, exp, log, sin, read_file, mkdir, ...) were only ever
    // registered by register_nytorch_builtins(), which ran on `import nytorch`
    // and nowhere else — so without that import they resolved to none on the VM
    // while working fine on the interpreter. They are registered first so that
    // the 11 names both blocks define keep register_builtins()' versions, which
    // is the behaviour the parity tests were written against.
    void register_all_builtins() {
        register_nytorch_builtins();
        register_builtins();
        register_nt_natives();
        register_pycore();        // after register_builtins: these replace its copies
        capture_builtin_types();
        tag_type_builtins();      // again: register_pycore replaced the tagged ones
        wrap_iterable_natives();  // after the tensor and pycore natives, so it wraps those
        register_generator_natives();   // islice, take (round 75)
        VMConc::install(*this);   // last: its GIL-aware sleep natives win
        register_gc_natives();
    }
    // Builtins that consume an iterable get its items first when it is a
    // generator, an iterator, or an object with __iter__/__getitem__ -
    // list(gen()), sorted(obj), sum(x for ...), zip(gen(), ...) returned []
    // or [<generator>] for those. sum() of objects adds with __add__ /
    // __radd__, and set() of objects dedupes by __hash__/__eq__ (or identity)
    // instead of by their shared "<C instance>" text, which kept only one.
    void wrap_iterable_natives() {
        struct W { const char* name; size_t from; bool all; };
        const W ws[] = {{"list",0,false},{"tuple",0,false},{"set",0,false},{"sorted",0,false},
            {"sum",0,false},{"min",0,false},{"max",0,false},{"any",0,false},{"all",0,false},
            {"enumerate",0,false},{"reversed",0,false},{"zip",0,true},{"zip_list",0,true},
            {"map",1,true},{"filter",1,true},{"frozenset",0,false}};
        for(const W& w : ws){
            auto it=globals_.find(w.name);
            if(it==globals_.end()||it->second.type!=VMType::NATIVE) continue;
            NativeFunc orig=it->second.native;
            std::string nm=w.name;
            size_t from=w.from; bool all=w.all;
            it->second.native=[this,orig,nm,from,all](std::vector<VMVal>& a)->VMVal{
                // Given a generator or iterator: any/all pull values until
                // they know the answer; zip/map/filter/enumerate return lazy
                // iterators (round 75, both engines).
                if((nm=="any"||nm=="all") && a.size()==1 && vm_lazy_arg(a[0])){
                    VMVal itv=a[0], v;
                    bool want_any = nm=="any";
                    while(vm_iter_step(itv,v)){
                        bool t=vm_truthy(v);
                        if(want_any&&t) return VMVal::make_bool(true);
                        if(!want_any&&!t) return VMVal::make_bool(false);
                    }
                    return VMVal::make_bool(!want_any);
                }
                if(nm=="zip"||nm=="map"||nm=="filter"||nm=="enumerate"){
                    VMVal lazy;
                    if(gen_lazy_builtin(nm,a,lazy)) return lazy;
                }
                size_t end = all ? a.size() : std::min(a.size(), from+1);
                for(size_t i=from;i<end;i++){
                    VMVal& x=a[i];
                    if(x.type==VMType::GENERATOR||x.type==VMType::ITERATOR) x=VMVal::make_list(iter_items(x));
                    else if(x.type==VMType::INSTANCE){
                        VMVal m;
                        if(class_lookup(x.class_name,"__iter__",m)||class_lookup(x.class_name,"__getitem__",m)
                           ||class_lookup(x.class_name,"__next__",m))
                            x=VMVal::make_list(iter_items(x));
                    }
                }
                bool has_inst=false;
                if(!a.empty()&&a[0].type==VMType::LIST&&a[0].list)
                    for(auto& e:*a[0].list) if(e.type==VMType::INSTANCE){ has_inst=true; break; }
                if(nm=="sum"&&has_inst){
                    VMVal acc = a.size()>=2 ? a[1] : VMVal::make_int(0);
                    for(auto& e:*a[0].list){
                        VMVal r;
                        if(binary_dunder(acc,e,"__add__","__radd__",r)) acc=r;
                        else acc=binop(nypy::A_ADD,acc,e);
                    }
                    return acc;
                }
                if((nm=="set"||nm=="frozenset")&&has_inst)
                    return build_set(*a[0].list, nm=="frozenset");   // set_key: __hash__ (round 77)
                return orig(a);
            };
        }
    }
    void tag_type_builtins() {
        for(auto& nm_canon : std::vector<std::pair<std::string,std::string>>{
                {"int","int"},{"float","float"},{"bool","bool"},{"str","str"},
                {"string","str"},{"list","list"},{"tuple","tuple"},
                {"dict","map"},{"set","set"},{"frozenset","frozenset"},{"bytes","bytes"},{"bytearray","bytearray"}}){
            auto git=globals_.find(nm_canon.first);
            if(git!=globals_.end()&&git->second.type==VMType::NATIVE)
                git->second.class_name=nm_canon.second;
        }
    }


    // ── Memory (round 75, VMGC.hpp) ──────────────────────────────────────
    bool vm_finalizers_off_ = false;
    std::unordered_map<std::string, bool> has_del_cache_;
    // The field map of a new instance: one whose class (or a base) defines
    // __del__ is owned through the finalizing deleter.
    std::shared_ptr<VMMap> new_instance_fields(const std::string& cls) {
        auto it = has_del_cache_.find(cls);
        bool has_del;
        if (it != has_del_cache_.end()) has_del = it->second;
        else { VMVal m; has_del = class_lookup(cls, "__del__", m); has_del_cache_[cls] = has_del; }
        if (has_del && !vm_finalizers_off_) return vmgc::new_finalizable_map(cls);
        auto attrs = vmgc::make_deep<VMMap>();
        vmgc::track_map(attrs);
        return attrs;
    }
    // __del__ on an instance, at a safe point; an exception it raises is
    // reported and ignored, as in Python.
    // ── weakref callbacks (round 77) ─────────────────────────────────────
    // A weak reference: its target and the callback to call with it when
    // the target dies. The target's fields hold a WeakNotifier under a
    // hidden key ("\x01weakref": not an attribute, left out of __dict__,
    // vars() and dir()); freed with them, it queues the callbacks of the
    // references still alive, and they run at the next safe point (as
    // __del__ does), so whatever freed the target never runs Nython code.
    struct WeakCell {
        std::weak_ptr<VMMap> target;
        std::string cls;
        VMVal callback;
    };
    struct WeakNotifier {
        std::vector<std::weak_ptr<WeakCell>> cells;
        ~WeakNotifier() {
            std::vector<std::shared_ptr<WeakCell>> due;
            for (auto& c : cells) if (auto sp = c.lock()) if (sp->callback.type != VMType::NONE) due.push_back(sp);
            if (due.empty()) return;
            {
                std::lock_guard<std::mutex> lk(weak_queue_mutex());
                for (auto& d : due) weak_queue().push_back(d);
            }
            vmgc::g_pending.store(true, std::memory_order_relaxed);
        }
    };
    struct WeakHolder {   // the hidden field's native: owns the notifier
        std::shared_ptr<WeakNotifier> n;
        VMVal operator()(std::vector<VMVal>&) const { return VMVal::make_none(); }
    };
    static std::mutex& weak_queue_mutex() { static auto* m = new std::mutex(); return *m; }
    static std::vector<std::shared_ptr<WeakCell>>& weak_queue() {
        static auto* q = new std::vector<std::shared_ptr<WeakCell>>();
        return *q;
    }
    static WeakNotifier* weak_notifier_of(const std::shared_ptr<VMMap>& m) {
        auto it = m->find("\x01weakref");
        if (it != m->end() && it->second.type == VMType::NATIVE)
            if (auto* h = it->second.native.target<WeakHolder>()) return h->n.get();
        WeakHolder h{std::make_shared<WeakNotifier>()};
        WeakNotifier* n = h.n.get();
        (*m)["\x01weakref"] = VMVal::make_native(NativeFunc(h));
        return n;
    }
    static VMVal weak_value(const std::shared_ptr<WeakCell>& cell) {
        return VMVal::make_native([cell](std::vector<VMVal>&) -> VMVal {
            auto sp = cell->target.lock();
            if (!sp) return VMVal::make_none();
            return VMVal::make_instance(cell->cls, sp);
        });
    }
    // At a safe point (vmgc::safe_point_slow): the callbacks of dead targets.
    void gc_run_weak_callbacks() {
        for (;;) {
            std::vector<std::shared_ptr<WeakCell>> q;
            {
                std::lock_guard<std::mutex> lk(weak_queue_mutex());
                if (weak_queue().empty()) return;
                q.swap(weak_queue());
            }
            if (vm_finalizers_off_) continue;
            for (auto& c : q) {
                VMVal cb = c->callback;
                c->callback = VMVal::make_none();
                if (cb.type == VMType::NONE) continue;
                VMVal saved_exc = last_exception_obj_;
                std::vector<VMVal> args{weak_value(c)};
                try { vm_call(cb, args, std::nullopt); }
                catch (std::exception& e) {
                    std::cerr << "Exception ignored in: " << vm_repr(cb) << "\n" << e.what() << "\n";
                }
                catch (...) {}
                last_exception_obj_ = saved_exc;
            }
        }
    }
    void gc_run_finalizer(const std::string& cls, const std::shared_ptr<VMMap>& attrs) {
        if (vm_finalizers_off_) return;
        VMVal m;
        if (!class_lookup(cls, "__del__", m)) return;
        VMVal inst = VMVal::make_instance(cls, attrs);
        VMVal saved_exc = last_exception_obj_;
        std::vector<VMVal> no_args;
        try { invoke_method(m, inst, no_args, cls); }
        catch (std::exception& e) {
            std::cerr << "Exception ignored in: <function " << cls << ".__del__>\n" << e.what() << "\n";
        }
        catch (...) {}
        last_exception_obj_ = saved_exc;
    }
    // A suspended generator in unreachable garbage (a cycle through it) is
    // closed before anything is cleared, as Python's collector does, so its
    // finally blocks run (round 76; it used to be cleared without them).
    // Only the thread that started it may; an error is reported and ignored.
    bool gc_close_generator(GenState& gs) {
        if (vm_finalizers_off_ || gs.done || gs.running || !gs.started || gs.native) return false;
        if (!gs.is_genexpr && gs.owner && gs.owner != nycoro::thread_token()) return false;
        VMVal saved_exc = last_exception_obj_;
        try { gen_close(gs); }
        catch (std::exception& e) {
            std::cerr << "Exception ignored in: <generator object " << gs.name << ">\n" << e.what() << "\n";
        }
        catch (...) {}
        if (!gs.done) gen_finish(gs);
        last_exception_obj_ = saved_exc;
        return true;
    }
    // Teardown: drop the program's roots so reference counting and a last
    // collection free its objects (no finalizer runs, as on the interpreter).
    void gc_teardown() {
        vmgc::safe_point(*this);       // __del__ of what the last statement released
        vm_finalizers_off_ = true;
        bool saved = vmgc::g_shutdown;
        vmgc::g_shutdown = true;       // a dying __del__ instance is just freed
        {
            VMMap g; g.swap(globals_);
            std::unordered_map<std::string, VMMap> cv; cv.swap(class_vars_);
            std::vector<VMVal> st; st.swap(stack_);
            std::deque<CallFrame> cs; cs.swap(call_stack_);
            VMVal le; std::swap(le, last_exception_obj_);
        }
        vmgc::g_shutdown = false;
        vmgc::collect(*this, 2);
        vmgc::g_shutdown = saved;
    }
    void register_gc_natives() {
        auto I = [](int64_t v) { return VMVal::make_int(v); };
        globals_["gc_collect"] = VMVal::make_native([this, I](std::vector<VMVal>& a) -> VMVal {
            int g = (!a.empty() && a[0].type == VMType::INT) ? (int)a[0].i : 2;
            vmgc::safe_point(*this);
            long n = vmgc::collect(*this, g);
            vmgc::safe_point(*this);
            // Values the builtin bridge made on the interpreter's heap.
            if (nygc::tracked_objects() > 0) nygc::collect(g);
            return I(n);
        });
        // weakref(obj, callback=None): a callable giving the instance back
        // while it is alive, none afterwards (instances only, as on the
        // interpreter). With a callback, callback(ref) runs at the next safe
        // point after the instance dies, unless the ref died first (round 77).
        globals_["weakref"] = VMVal::make_native([this](std::vector<VMVal>& a) -> VMVal {
            if (!a.empty() && a.back().type == VMType::MAP && a.back().class_name == "__kwargs__") {
                VMVal kw = a.back(); a.pop_back();
                auto it = kw.map->find("callback");
                if (it != kw.map->end()) { if (a.size() < 2) a.push_back(it->second); }
            }
            if (a.empty() || a[0].type != VMType::INSTANCE || !a[0].map)
                throw_exception(make_exception("TypeError", {VMVal::make_str("cannot create weak reference to '"
                    + (a.empty() ? std::string("NoneType") : vm_type_name(a[0])) + "' object")}));
            auto cell = std::make_shared<WeakCell>();
            cell->target = a[0].map;
            cell->cls = a[0].class_name;
            if (a.size() >= 2 && a[1].type != VMType::NONE) {
                cell->callback = a[1];
                weak_notifier_of(a[0].map)->cells.push_back(cell);
            }
            return weak_value(cell);
        });
        globals_["gc_enable"] = VMVal::make_native([](std::vector<VMVal>&) -> VMVal { vmgc::set_enabled(true); return VMVal::make_none(); });
        globals_["gc_disable"] = VMVal::make_native([](std::vector<VMVal>&) -> VMVal { vmgc::set_enabled(false); return VMVal::make_none(); });
        globals_["gc_is_enabled"] = VMVal::make_native([](std::vector<VMVal>&) -> VMVal { return VMVal::make_bool(vmgc::is_enabled()); });
        globals_["gc_isenabled"] = globals_["gc_is_enabled"];
        globals_["gc_live_objects"] = VMVal::make_native([I](std::vector<VMVal>&) -> VMVal { return I(vmgc::live_objects()); });
        globals_["gc_set_threshold"] = VMVal::make_native([](std::vector<VMVal>& a) -> VMVal {
            for (size_t i = 0; i < a.size() && i < 3; i++) if (a[i].type == VMType::INT) vmgc::set_threshold((int)i, (long)a[i].i);
            return VMVal::make_none();
        });
        globals_["gc_get_threshold"] = VMVal::make_native([I](std::vector<VMVal>&) -> VMVal {
            return VMVal::make_tuple({I(vmgc::threshold(0)), I(vmgc::threshold(1)), I(vmgc::threshold(2))});
        });
        globals_["gc_stats"] = VMVal::make_native([I](std::vector<VMVal>&) -> VMVal {
            auto st = vmgc::stats();
            VMVal m = VMVal::make_map();
            auto key = [](const std::string& k) { return nypy::key_of_str(k); };
            long long coll = st.collections[0] + st.collections[1] + st.collections[2];
            (*m.map)[key("engine")] = VMVal::make_str("vm");
            (*m.map)[key("enabled")] = VMVal::make_bool(vmgc::is_enabled());
            (*m.map)[key("collections")] = I(coll);
            (*m.map)[key("collections_per_gen")] = VMVal::make_list({I(st.collections[0]), I(st.collections[1]), I(st.collections[2])});
            (*m.map)[key("collected")] = I(st.collected);
            (*m.map)[key("uncollectable")] = I(st.uncollectable);
            (*m.map)[key("finalized")] = I(st.finalized);
            (*m.map)[key("tracked")] = I(st.gen_count[0] + st.gen_count[1] + st.gen_count[2]);
            (*m.map)[key("gen0")] = I(st.gen_count[0]);
            (*m.map)[key("gen1")] = I(st.gen_count[1]);
            (*m.map)[key("gen2")] = I(st.gen_count[2]);
            (*m.map)[key("live_objects")] = I(vmgc::live_objects());
            (*m.map)[key("rss_kb")] = I(nygc::rss_kb());
            return m;
        });
        globals_["mem_rss_kb"] = VMVal::make_native([I](std::vector<VMVal>&) -> VMVal { return I(nygc::rss_kb()); });
        globals_["mem_peak_rss_kb"] = VMVal::make_native([I](std::vector<VMVal>&) -> VMVal { return I(nygc::peak_rss_kb()); });
    }

    // Teardown frees the program's values first (gc_teardown), while the
    // generator registry they report to still exists.
    ~VirtualMachine() override { gc_teardown(); vm_live(this, -1); }
    // The VMs alive now: a generator can be destroyed after its VM (a value
    // kept in a static table), and ~GenState must not call into a dead one.
    // op: 1 add, -1 remove, 0 query.
    static bool vm_live(VirtualMachine* vm, int op) {
        static std::mutex* mu = new std::mutex();
        static auto* live = new std::unordered_set<VirtualMachine*>();
        std::lock_guard<std::mutex> lk(*mu);
        if(op>0){ live->insert(vm); return true; }
        if(op<0){ live->erase(vm); return false; }
        return live->count(vm)>0;
    }

    // Compile + run an AST
    // session: a REPL's module variables (round 77): the chunk runs with
    // them and leaves its own there; the program's threads are not waited
    // for and its paused generators stay open between chunks.
    VMResult run(nython::node::node_ptr ast, VMMap* session=nullptr) {
        try {
            load_prelude();
            Compiler c; auto code=c.compile(ast);
            // The module frame is pushed here rather than by exec_code() so that
            // non-daemon threads, which read module variables through it, are
            // joined before it is popped (round 74).
            size_t base=stack_.size();
            CallFrame fr; fr.code=code; fr.ip=0;
            if(session) fr.locals=*session;
            prompt_session_=session!=nullptr;
            call_stack_.push_back(std::move(fr));
            gen_finalize_=true;
            struct PopModule {
                VirtualMachine* vm; size_t base; VMMap* session;
                ~PopModule(){
                    if(session) *session=vm->call_stack_.back().locals;
                    else nyconc::join_nondaemon_at_exit();
                    vm->gen_finalize_=false;
                    vm->module_frame_=nullptr;
                    vm->call_stack_.pop_back();
                    if(vm->stack_.size()>base) vm->stack_.resize(base);
                }
            } pop_module{this, base, session};
            // An uncaught exception is reported here, before PopModule waits
            // for the program's threads (as Python prints the traceback first):
            // Python's frames (round 77), then the [VMError] line. The atexit
            // handlers run after the threads are done (round 77).
            try { run_loop(); } catch(VMReturn&) {}
            catch(VMException& ve) {
                if(!session) print_uncaught_traceback(ve.value);
                VMResult r=report_uncaught(ve.what(), false);
                if(!session){ nyconc::join_nondaemon_at_exit(); run_atexit(); }
                return r;
            }
            catch(std::exception& e) {
                VMResult r=report_uncaught(e.what(), false);
                if(!session){ nyconc::join_nondaemon_at_exit(); run_atexit(); }
                return r;
            }
            catch(std::string& m) {
                VMResult r=report_uncaught(m, true);
                if(!session){ nyconc::join_nondaemon_at_exit(); run_atexit(); }
                return r;
            }
            if(!session){ nyconc::join_nondaemon_at_exit(); run_atexit(); }
            // Generators the program left paused: closed now, so their
            // finally blocks run (the interpreter does the same).
            if(!session) gen_close_all();
            return VMResult::SUCCESS;
        } catch(std::exception& e) {
            return report_uncaught(e.what(), false);
        } catch(std::string& m) {
            return report_uncaught(m, true);
        }
    }

    // repr() of a value as a program would see it (the prompt's echo).
    std::string repr_of(const VMVal& v) { return vm_repr(v); }

    // An uncaught exception's traceback, Python's way, chained exceptions
    // first, without the last line (the prelude's _ny_format_uncaught;
    // report_uncaught prints that line) - round 77.
    void print_uncaught_traceback(const VMVal& ev) {
        if(ev.type!=VMType::INSTANCE||prompt_session_) return;
        if(class_derives(ev.class_name,"SystemExit")||class_derives(ev.class_name,"KeyboardInterrupt")) return;
        try {
            VMVal f=load_var("_ny_format_uncaught");
            if(f.type!=VMType::FUNCTION) return;
            std::vector<VMVal> a{ev};
            VMVal r=vm_call(f,a,std::nullopt);
            if(r.type==VMType::STRING) std::cerr<<r.s;
        } catch(...) {}
    }
    // The exit handlers lib/atexit.ny registered (the prelude's _ny_run_atexit).
    void run_atexit() {
        try {
            VMVal f=load_var("_ny_run_atexit");
            if(f.type!=VMType::FUNCTION) return;
            VMVal hs=load_var("_ny_atexit_handlers");   // none registered: no call
            if(hs.type!=VMType::LIST||!hs.list||hs.list->empty()) return;
            std::vector<VMVal> a;
            vm_call(f,a,std::nullopt);
        } catch(...) {}
    }

    // The status of a program ended by an uncaught SystemExit (round 77).
    static int& exit_status() { static int s=-1; return s; }

    VMResult report_uncaught(const std::string& m, bool tagged) {
        std::string type, msg;
        bool split=tagged&&nython::ny_split_exc_message(m,type,msg);
        if(!split&&!tagged&&m.rfind("SystemExit",0)==0){
            split=true; type="SystemExit";
            msg=m.size()>12?m.substr(12):std::string();
        }
        if(split&&type=="SystemExit"){
            // sys.exit(n): status n, nothing printed; exit("text"): the
            // text on stderr and status 1; exit() / exit(None): 0.
            exit_status()=nyrt::system_exit_status(msg);
            return VMResult::RUNTIME_ERROR;
        }
        if((split&&type=="KeyboardInterrupt")||(!tagged&&m.rfind("KeyboardInterrupt",0)==0)){
            // as Python: the bare name, and the exit status of SIGINT (main.cpp)
            std::cerr<<"KeyboardInterrupt\n";
            keyboard_interrupted()=true;
            return VMResult::RUNTIME_ERROR;
        }
        if(prompt_session_){
            // at the prompt: Python's last traceback line, as the interpreter
            std::cerr<<(split ? (msg.empty() ? type : type+": "+msg) : m)<<"\n";
            return VMResult::RUNTIME_ERROR;
        }
        if(split) std::cerr<<"\x1b[31m[VMError] "<<type<<": "<<msg<<"\x1b[0m\n";
        else std::cerr<<"\x1b[31m[VMError] "<<m<<"\x1b[0m\n";
        return VMResult::RUNTIME_ERROR;
    }
    bool prompt_session_=false;

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
            // The prelude's names become globals (round 77: export_depth_ was
            // left unset, so only the native open() below and the classes
            // registered here were ever visible - NythonFile, but none of the
            // async helpers the parser desugars to).
            bool old_exp=export_to_globals_; export_to_globals_=true;
            int old_depth=export_depth_; export_depth_=(int)call_stack_.size()+1;
            try{ exec_code(code,{},std::nullopt); } catch(VMReturn&){}
            export_to_globals_=old_exp; export_depth_=old_depth;
            for(auto& sub:code->sub_codes) if(sub->is_class&&!class_reg_.count(sub->name)) class_reg_[sub->name]=sub;   // keep the class MAKE_CLASS made (a copy for metaclass= / expression bases), round 77
        } catch(std::exception& e){ std::cerr<<"[VM] prelude failed to load: "<<e.what()<<"\n"; }
        for(auto& kv:globals_) base_global_names_.insert(kv.first);   // globals() leaves these out
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
                for(auto& kv:*args.back().map)
                    if(kv.first!="mode"&&kv.first!="encoding"&&kv.first!="file"&&kv.first!="path"&&kv.first!="errors"
                       &&kv.first!="newline"&&kv.first!="buffering"&&kv.first!="closefd"&&kv.first!="opener") all_kw=false;
                if((all_kw||args.back().class_name=="__kwargs__")&&!args.back().map->empty()){ kw=args.back(); args.pop_back(); }
            }
            auto kwget=[&](const char* k)->VMVal{
                if(kw.type==VMType::MAP&&kw.map&&kw.map->count(k)) return (*kw.map)[k];
                return VMVal::make_none();
            };
            VMVal path=args.size()>0?args[0]:kwget("file");
            if(path.type==VMType::NONE) path=kwget("path");
            if(path.type==VMType::INSTANCE){            // a path-like object: open(Path(...))
                bool found=false;
                VMVal s=call_dunder_f(path,"__fspath__",{},found);
                if(found) path=s;
            }
            VMVal mode=args.size()>1?args[1]:kwget("mode");
            if(mode.type==VMType::NONE) mode=VMVal::make_str("r");
            // open(file, mode, buffering, encoding, errors, newline), Python's
            // order; newline= as the prelude's open (NythonFile.newline):
            // an explicit one opens the handle raw (round 77)
            VMVal newline=args.size()>5?args[5]:kwget("newline");
            bool binary=mode.type==VMType::STRING&&mode.s.find('b')!=std::string::npos;
            if(newline.type!=VMType::NONE){
                if(newline.type!=VMType::STRING||!(newline.s.empty()||newline.s=="\n"||newline.s=="\r"||newline.s=="\r\n"))
                    raise_native_exception("ValueError","illegal newline value: "+vm_repr(newline));
                if(binary) raise_native_exception("ValueError","binary mode doesn't take a newline argument");
            }
            VMVal native_mode=mode;
            if(newline.type!=VMType::NONE&&!binary) native_mode=VMVal::make_str(mode.s+"b");
            std::vector<VMVal> oa={path,native_mode};
            VMVal opener=load_var("file_open_or_raise");
            VMVal h=vm_call(opener,oa,std::nullopt);
            auto cit=class_reg_.find("NythonFile");
            if(cit==class_reg_.end()) return h;
            VMVal cls=VMVal::make_class(cit->second,"NythonFile");
            VMVal enc=args.size()>3?args[3]:kwget("encoding");
            if(enc.type==VMType::NONE) enc=VMVal::make_str("utf-8");
            if(mode.type==VMType::STRING&&mode.s.find('b')!=std::string::npos&&enc.type==VMType::STRING&&enc.s!="utf-8")
                raise_native_exception("ValueError","binary mode doesn't take an encoding argument");
            std::vector<VMVal> ca={path,mode,h,enc};
            VMVal f=vm_call(cls,ca,std::nullopt);
            if(f.type==VMType::INSTANCE&&f.map) (*f.map)["newline"]=newline;
            return f;
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
        // Python's own members: os.stat_result, os.terminal_size, the raising
        // listdir / rename / mkdir ... (round 77, NyRuntime.hpp)
        for(auto& pm : nyrt::os_python_members()){
            auto git=globals_.find(pm.second);
            VMVal v;
            if(git!=globals_.end()) v=git->second;
            else { try { v=load_var(pm.second); } catch(...) { continue; } }
            if(v.type!=VMType::NONE) (*ns.map)[pm.first]=v;
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
    // The sys module, once made: one namespace for every import, so a
    // stream replaced through one (contextlib.redirect_stdout) is the
    // stream of all.
    VMVal sys_ns_;
    // Whether sys.stdout is something else than the standard stream it
    // starts as; `target` is then that object.
    bool stdout_redirected(VMVal& target) {
        if(sys_ns_.type!=VMType::MAP||!sys_ns_.map) return false;
        auto it=sys_ns_.map->find("stdout");
        if(it==sys_ns_.map->end()) return false;
        const VMVal& so=it->second;
        if(so.type==VMType::NONE) return false;
        auto ot=globals_.find("_ny_stdout");
        if(ot!=globals_.end()&&ot->second.type==so.type&&ot->second.map==so.map) return false;
        target=so;
        return true;
    }
    void define_sys_module(const std::string& as_name) {
        if(sys_ns_.type==VMType::MAP&&sys_ns_.map){ globals_[as_name]=sys_ns_; return; }
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
        (*ns.map)["exit"]=load_var("exit");
        // sys.exc_info() / sys.exception() / sys._getframe() (round 77, the prelude's)
        (*ns.map)["exc_info"]=load_var("_ny_exc_info");
        (*ns.map)["exception"]=load_var("_ny_exc_current");
        (*ns.map)["_getframe"]=load_var("_ny_getframe");
        {
            std::vector<VMVal> wo;
            for(auto& o:nyrt::warn_options()) wo.push_back(VMVal::make_str(o));
            (*ns.map)["warnoptions"]=VMVal::make_list(std::move(wo));
        }
        // the standard streams (NyPrelude _NyStdStream, round 77)
        for(const char* st : {"stdin","stdout","stderr"}){
            auto it=globals_.find(std::string("_ny_")+st);
            VMVal sv=it!=globals_.end()?it->second:VMVal::make_none();
            (*ns.map)[st]=sv;
            (*ns.map)[std::string("__")+st+"__"]=sv;
        }
        (*ns.map)["platform"]=VMVal::make_str(plat);
        (*ns.map)["executable"]=VMVal::make_str(nyrt::executable_path());
        (*ns.map)["version"]=VMVal::make_str(NYTHON_VERSION);
        (*ns.map)["maxsize"]=VMVal::make_int((int64_t)PTRDIFF_MAX);   // as the interpreter's
        { const uint16_t probe=1; (*ns.map)["byteorder"]=VMVal::make_str(*(const uint8_t*)&probe?"little":"big"); }
        ns.class_name="sys";
        sys_ns_=ns;
        globals_[as_name]=ns;
        globals_["argv"]=argv_list;
        globals_["platform"]=VMVal::make_str(plat);
    }

    // Raise a builtin exception of `type` from native code (the builtin
    // bridge uses it for "__exc__:Type:msg" errors from interpreter
    // builtins): the same instance and runtime_error an Op::RAISE of
    // Type(msg) produces, so it takes the VM's normal raise path.
    // A path-like argument (an object with __fspath__, e.g. pathlib.Path)
    // given to a builtin that takes paths (nyrt::takes_paths): the string
    // its __fspath__ returns, positionally or as a keyword argument. The
    // builtin bridge applies it before converting the arguments.
    void fspath_args(std::vector<VMVal>& a) {
        auto conv=[&](VMVal& v){
            if(v.type!=VMType::INSTANCE) return;
            bool found=false;
            VMVal r=call_dunder_f(v,"__fspath__",{},found);
            if(found) v=r;
        };
        for(auto& v:a){
            conv(v);
            if(v.type==VMType::MAP&&v.map&&v.class_name=="__kwargs__")
                for(auto& kv:*v.map) conv(kv.second);
        }
    }

    [[noreturn]] void raise_native_exception(const std::string& type, const std::string& msg) {
        auto attrs=std::make_shared<VMMap>(); vmgc::track_map(attrs);
        // the arguments the message stands for (an OSError's errno and
        // filename, a codec error's fields, a KeyError's key - round 77)
        std::string t=type.empty()?std::string("Exception"):type;
        set_exc_args(*attrs, t, exc_args_from_message(t, msg));
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

    // Deep recursion raises RecursionError (it crashed the process with
    // SIGSEGV at ~1400 frames): at most kMaxFrames frames, and never past the
    // stack's own floor (smaller thread stacks, instrumented builds).
    static const size_t kMaxFrames = 1000;
    void check_depth() {
        if(call_stack_.size() >= kMaxFrames)
            throw_exception(make_exception("RecursionError",{VMVal::make_str("maximum recursion depth exceeded")}));
        // On a coroutine's stack (an async task) a deep call goes on to an
        // extension stack instead (run_frame); a thread's own stack ends here.
        if(!nycoro::current() && nycoro::native_stack_exhausted())
            throw_exception(make_exception("RecursionError",{VMVal::make_str("maximum recursion depth exceeded")}));
    }
    // Runs the frame just pushed. On a coroutine's stack that is nearly used
    // up, it runs on an extension stack of its own (switched to and back as
    // a nested call), as the interpreter does for calls inside a generator:
    // an async task's stack can then be small (2000 tasks on a 32-bit
    // system) and a task still recurses to kMaxFrames (round 76).
    struct Extension { VirtualMachine* vm; VMVal result; std::exception_ptr exc; };
    static void extension_entry(void* p) {
        auto* x = static_cast<Extension*>(p);
        try { x->result = x->vm->run_loop(); }
        catch (...) { x->exc = std::current_exception(); }   // nothing unwinds across the switch
    }
    VMVal run_frame() {
        if(!nycoro::current() || !nycoro::stack_exhausted()) return run_loop();
        Extension x{this, VMVal::make_none(), nullptr};
        nycoro::Coro* co = nullptr;
        try { co = nycoro::create(&extension_entry, &x); }
        catch(std::bad_alloc&) {
            throw_exception(make_exception("RecursionError",{VMVal::make_str("maximum recursion depth exceeded (no stack left to extend it)")}));
        }
        nycoro::resume(co);
        // An async task that blocks in it leaves through it (NyConc.hpp).
        while(!nycoro::done(co) && nyconc::relay_requested()) { nyconc::relay_park(); nycoro::resume(co); }
        bool finished = nycoro::done(co);
        if(finished) nycoro::destroy(co);
        if(!finished) throw std::runtime_error("internal error: a call on an extension stack suspended");
        if(x.exc) std::rethrow_exception(x.exc);
        return x.result;
    }
    VMVal exec_code_bound(std::shared_ptr<VMCode> code,
                          VMMap locs,
                          std::optional<VMVal> self,
                          std::shared_ptr<VMMap> closure=nullptr) {
        check_depth();
        CallFrame fr; fr.code=code; fr.ip=0;
        if(self) fr.self_val=self;
        fr.closure_env=closure;
        fr.locals=std::move(locs);
        fr.stack_base=stack_.size();
        call_stack_.push_back(std::move(fr));
        VMVal result=VMVal::make_none();
        try { result=run_frame(); }
        catch(VMReturn& r){ result=r.value; }
        catch(...){ call_stack_.pop_back(); throw; }
        call_stack_.pop_back();
        return result;
    }
    // Binds positional arguments `pos` and keyword arguments `kw` (a MAP, or
    // null) to code's parameters, Python's way: positionals fill the plain
    // parameters in order, `*name` takes the rest of them, a bare `*` ends
    // the positional ones, keywords fill parameters by name, `**name` takes
    // the keywords no parameter named, and a missing parameter takes its
    // default. `defaults` is the function value's own (MAKE_FUNCTION), else
    // the code's literal defaults. Returns an error message for a call that
    // does not fit (reported as TypeError by the caller when strict).
    // `bound_self`: the call supplies self (a method), counted as Python
    // counts it in the messages.
    std::string bind_args(const VMCode& code, const std::vector<VMVal>* defaults,
                          const std::vector<VMVal>& pos, const VMVal* kw,
                          VMMap& locs, bool bound_self=false) {
        const auto& pnames=code.param_names;
        // a __qualname__ the program set names the function in its call
        // errors; the compiler's own qualname does not (round 77)
        const std::string& fname=code.qualname_set&&!code.qualname.empty()?code.qualname:code.name;
        const std::vector<VMVal>& dflts = defaults ? *defaults : code.param_defaults;
        size_t ai=0;
        bool star_seen=false, has_varargs=false, has_varkw=false;
        std::unordered_set<std::string> used_kw;
        std::string err;
        std::string kw_name;
        std::vector<std::string> missing;
        std::string posonly_kw;   // positional-only parameters given as keywords
        size_t min_pos=0, max_pos=0;
        for(size_t pi=0;pi<pnames.size();pi++){
            const std::string& pn=pnames[pi];
            if(pn.size()>=2&&pn[0]=='*'&&pn[1]=='*'){ has_varkw=true; kw_name=pn.substr(2); continue; }
            if(pn=="*"){ star_seen=true; continue; }
            if(!pn.empty()&&pn[0]=='*'){
                std::vector<VMVal> rest;
                if(!star_seen) for(;ai<pos.size();ai++) rest.push_back(pos[ai]);
                locs[pn.substr(1)]=VMVal::make_tuple(std::move(rest));   // *args is a tuple
                star_seen=true; has_varargs=true; continue;
            }
            bool have=false;
            bool has_default = pi<dflts.size()&&!dflts[pi].is_missing();
            if(!star_seen){ max_pos++; if(!has_default) min_pos++; }
            if(!star_seen && ai<pos.size()){ locs[pn]=pos[ai++]; have=true; }
            if(kw && kw->map && pi<code.posonly){
                // never bound by keyword: the keyword goes to **kwargs, or is an error
                if(kw->map->count(nypy::key_of_str(pn))) posonly_kw += (posonly_kw.empty() ? "" : ", ") + pn;
            } else if(kw && kw->map){
                // the keywords are dict keys: a dunder name is a typed key
                // (round 77: f(__x__=1) never reached parameter __x__)
                auto it=kw->map->find(nypy::key_of_str(pn));
                if(it!=kw->map->end()){
                    if(have && err.empty()) err=fname+"() got multiple values for argument '"+pn+"'";
                    locs[pn]=it->second; used_kw.insert(it->first); have=true;
                }
            }
            if(!have){
                if(has_default){ locs[pn]=dflts[pi]; }
                else {
                    locs[pn]=VMVal::make_none();
                    missing.push_back(pn);
                }
            }
        }
        if(err.empty() && (!missing.empty() || (!has_varargs && pos.size()>max_pos))){
            size_t s = bound_self ? 1 : 0;
            err=nython::ny_arity_error(code.name=="<lambda>"?std::string():fname, missing,
                                       min_pos+s, has_varargs ? -1L : (long)(max_pos+s), pos.size()+s);
        }
        if(kw && kw->map){
            VMVal extra=VMVal::make_map();
            for(auto& [k,v]:*kw->map) if(!used_kw.count(k)) (*extra.map)[k]=v;
            if(has_varkw) locs[kw_name]=extra;
            else if(!posonly_kw.empty())
                err=fname+"() got some positional-only arguments passed as keyword arguments: '"+posonly_kw+"'";
            else if(!extra.map->empty() && err.empty())
                err=fname+"() got an unexpected keyword argument '"+nypy::key_payload(extra.map->begin()->first)+"'";
        } else if(has_varkw) locs[kw_name]=VMVal::make_map();
        return err;
    }
    VMVal exec_code(std::shared_ptr<VMCode> code,
                    std::vector<VMVal> args,
                    std::optional<VMVal> self,
                    std::shared_ptr<VMMap> closure=nullptr,
                    const std::vector<VMVal>* defaults=nullptr,
                    const VMVal* kwargs=nullptr) {
        check_depth();
        size_t _stack_base=stack_.size();
        CallFrame fr; fr.code=code; fr.ip=0;
        fr.stack_base=_stack_base;
        if(self) fr.self_val=self;
        // Store closure env in frame (shared reference, not copy)
        fr.closure_env = closure;
        std::string err=bind_args(*code, defaults, args, kwargs, fr.locals, self.has_value() && code->is_method);
        if(!err.empty() && strict_args_) throw_exception(make_exception("TypeError",{VMVal::make_str(err)}));
        call_stack_.push_back(std::move(fr));
        VMVal result=VMVal::make_none();
        try { result=run_frame(); }
        catch(VMReturn& r){ result=r.value; }
        catch(...){ call_stack_.pop_back(); if(stack_.size()>_stack_base) stack_.resize(_stack_base); throw; }
        call_stack_.pop_back();
        if(stack_.size()>_stack_base) stack_.resize(_stack_base);
        return result;
    }
    // Calling a user function value: its own defaults and closure, a new
    // generator for a generator function, `self` for a method.
    VMVal call_function(const VMVal& fn, std::vector<VMVal>& args, std::optional<VMVal> self,
                        const VMVal* kwargs=nullptr) {
        if(fn.type!=VMType::FUNCTION||!fn.code) return VMVal::make_none();
        const std::vector<VMVal>* d = fn.list ? fn.list.get() : nullptr;
        if(fn.code->has_yield()){
            VMVal g=make_generator_val(fn.code, args, self, fn.closure_env);
            // Re-bind with the function's own defaults and keywords.
            VMMap locs;
            std::string err=bind_args(*fn.code, d, args, kwargs, locs, self.has_value() && fn.code->is_method);
            if(!err.empty() && strict_args_) throw_exception(make_exception("TypeError",{VMVal::make_str(err)}));
            g.gen->locals=std::move(locs);
            return g;
        }
        return exec_code(fn.code, args, self, fn.closure_env, d, kwargs);
    }
    // A call that does not fit the parameters raises TypeError (it bound
    // none to the missing ones and dropped the extra ones).
    bool strict_args_ = true;

    // ── Generators (round 75) ───────────────────────────────────────────
    // Resumes a generator: true when it yields (the value in `out`), false
    // when it finishes (its return value in gs.retval, for StopIteration).
    // mode 0: next/send (`sent` is what the paused yield evaluates to),
    // 1: throw (`sent` is the exception, raised at the pause), 2: close
    // (GeneratorExit at the pause). What the body raises propagates; a
    // StopIteration becomes RuntimeError (PEP 479). `internal`: closing on
    // the program's behalf (finalization), whatever thread started it.
    bool gen_resume(GenState& gs, int mode, const VMVal& sent, VMVal& out, bool internal=false) {
        if(gs.done){ if(mode==1) throw_exception(sent); return false; }
        if(gs.running) throw_exception(make_exception("ValueError",{VMVal::make_str("generator already executing")}));
        if(gs.native){
            gs.started=true;
            if(mode!=0){ gen_finish(gs); if(mode==1) throw_exception(sent); return false; }
            gs.running=true;
            bool got=false;
            try { got=gs.native(out); }
            catch(...){ gs.running=false; gen_finish(gs); throw; }
            gs.running=false;
            if(!got) gen_finish(gs);
            return got;
        }
        if(!gs.started && mode!=0){ gen_finish(gs); if(mode==1) throw_exception(sent); return false; }
        check_depth();
        uint64_t me=nycoro::thread_token();
        if(gs.started && !gs.is_genexpr && !internal && gs.owner && gs.owner!=me)
            throw_exception(make_exception("RuntimeError",{VMVal::make_str("generator '"+gs.name+"' was started on another "
                "thread; a started generator can only be resumed by the thread that started it")}));
        if(!gs.started){
            gs.started=true; gs.owner=me; gs.vm=this;
            gs.serial=++gen_serial_;
            gen_live_[gs.serial]=&gs;
        }
        // Its operand stack (iterators of loops around the yield) and locals.
        gs.stack_base=stack_.size();
        for(auto& sv : gs.saved_stack) stack_.push_back(std::move(sv));
        gs.saved_stack.clear();
        CallFrame fr; fr.code=gs.code; fr.ip=(int)gs.ip;
        fr.stack_base=gs.stack_base;
        fr.locals=std::move(gs.locals);
        fr.self_val=gs.self_val;
        fr.closure_env=gs.closure;
        fr.own_env=gs.own_env;
        fr.gen_state=gs.shared_from_this();
        call_stack_.push_back(std::move(fr));
        gs.mode=mode; gs.running=true; gs.yielded=false;
        bool at_yield=gs.at_yield;
        gs.at_yield=false;
        VMVal r;
        try {
            if(gs.in_yield_from){
                // YIELD_FROM_OP runs again and passes this on to its iterator.
                gs.sent = mode==0 ? sent : VMVal::make_none();
                gs.pending = mode==1 ? sent : VMVal::make_none();
            } else if(at_yield){
                if(mode==0) push(sent);
                else {
                    // Raised at the paused yield: the generator's own
                    // except/finally/with see it first.
                    VMVal ev = mode==1 ? sent : make_exception("GeneratorExit",{});
                    if(!dispatch_exception(call_stack_.back(), ev)) throw VMException(ev, describe_exception(ev));
                }
            }
            r=run_frame();
        } catch(VMReturn& rv){
            r=rv.value;
        } catch(VMException& e){
            gen_unwind(gs);
            if(is_stop_iteration(e.value))
                throw_exception(make_exception("RuntimeError",{VMVal::make_str("generator raised StopIteration")}));
            throw;
        } catch(...){
            gen_unwind(gs);
            throw;
        }
        gs.running=false;
        if(gs.yielded){
            gs.yielded=false;
            call_stack_.pop_back();          // the yield saved its stack and locals
            out=std::move(r);
            return true;
        }
        if(stack_.size()>gs.stack_base) stack_.resize(gs.stack_base);
        call_stack_.pop_back();
        gs.retval=std::move(r);
        gen_finish(gs);
        return false;
    }
    // An exception is leaving the generator's frame.
    void gen_unwind(GenState& gs) {
        if(!call_stack_.empty()) call_stack_.pop_back();
        if(stack_.size()>gs.stack_base) stack_.resize(gs.stack_base);
        gen_finish(gs);
    }
    void gen_finish(GenState& gs) {
        gs.done=true; gs.running=false; gs.at_yield=false; gs.in_yield_from=false;
        gs.locals.clear(); gs.saved_stack.clear(); gs.native=nullptr;
        gs.sent=VMVal::make_none(); gs.pending=VMVal::make_none();
        if(gs.serial){ gen_live_.erase(gs.serial); gs.serial=0; }
    }
    // The value of the next yield, or none once it is exhausted (gv.gen->done).
    VMVal gen_next(VMVal& gv, VMVal sent=VMVal::make_none()) {
        if(gv.type!=VMType::GENERATOR||!gv.gen||gv.gen->done) return VMVal::make_none();
        GenState& gs=*gv.gen;
        VMVal out;
        if(gen_resume(gs, 0, sent, out)) return out;
        return VMVal::make_none();
    }
    // StopIteration carrying the return value (then forgotten: a second
    // next() raises a plain StopIteration, as in Python).
    [[noreturn]] void gen_raise_stop(GenState& gs) {
        VMVal rv=gs.retval;
        gs.retval=VMVal::make_none();
        std::vector<VMVal> a;
        if(rv.type!=VMType::NONE) a.push_back(rv);
        throw_exception(make_exception("StopIteration",a));
    }
    // g.close(): GeneratorExit at the pause; an error if it yields again.
    void gen_close(GenState& gs, bool internal=false) {
        if(gs.done) return;
        if(gs.running) throw_exception(make_exception("ValueError",{VMVal::make_str("generator already executing")}));
        if(!gs.started || gs.native){ gen_finish(gs); return; }
        VMVal out;
        bool yielded=false;
        try { yielded=gen_resume(gs, 2, VMVal::make_none(), out, internal); }
        catch(VMException& e){
            if(class_derives(e.value.class_name,"GeneratorExit")||is_stop_iteration(e.value)) return;
            throw;
        }
        if(yielded) throw_exception(make_exception("RuntimeError",{VMVal::make_str("generator ignored GeneratorExit")}));
    }
    // What g.throw(...) raises: a class is instantiated (with the extra
    // arguments), an instance or string as it is.
    VMVal gen_throw_value(std::vector<VMVal>& args) {
        if(args.empty()) throw_exception(make_exception("TypeError",{VMVal::make_str("throw expected at least 1 argument, got 0")}));
        if(args.size()>3) throw_exception(make_exception("TypeError",{VMVal::make_str("throw expected at most 3 arguments, got "+std::to_string(args.size()))}));
        // throw(type[, value[, tb]]) as Python normalizes it (round 77): a
        // value that is an instance of type is raised itself, None makes
        // type(), a tuple type(*value), anything else type(value); an
        // instance takes no separate value.
        VMVal ev=args[0];
        std::vector<VMVal> cargs;
        bool has_val=args.size()>1&&args[1].type!=VMType::NONE;
        if(has_val){
            const VMVal& val=args[1];
            if(val.type==VMType::LIST&&val.b&&!val.is_set()&&val.list) cargs=*val.list;
            else cargs.push_back(val);
        }
        if(ev.type==VMType::CLASS){
            if(has_val&&args[1].type==VMType::INSTANCE&&class_derives(args[1].class_name, ev.class_name)) return args[1];
            ev=instantiate(ev, cargs);
        } else if(ev.type==VMType::NATIVE && ev.class_name.rfind("__builtin__:",0)==0
                  && nython::ny_is_builtin_exc(ev.class_name.substr(12))){
            ev=make_exception(ev.class_name.substr(12), cargs);
        } else if(has_val&&ev.type==VMType::INSTANCE){
            throw_exception(make_exception("TypeError",{VMVal::make_str("instance exception may not have a separate value")}));
        }
        return normalize_exception(ev);
    }
    // A generator's attributes (round 77, as NyGen.cpp's attr): __name__,
    // __qualname__, gi_running, gi_suspended, gi_yieldfrom (the iterator a
    // paused `yield from` runs), gi_frame (None once finished; f_lineno is
    // the line it is paused at, the def line before it starts) and gi_code
    // (its function's __code__). A lazy zip/map/... has none of them.
    bool gen_attr(const VMVal& g, const std::string& attr, VMVal& out) {
        if(!g.gen||g.gen->native) return false;
        GenState& gs=*g.gen;
        if(attr=="__name__"){ out=VMVal::make_str(gs.name); return true; }
        if(attr=="__qualname__"){ out=VMVal::make_str(gs.code&&!gs.code->qualname.empty()?gs.code->qualname:gs.name); return true; }
        if(attr=="gi_running"){ out=VMVal::make_bool(gs.running); return true; }
        if(attr=="gi_suspended"){ out=VMVal::make_bool(gs.started&&!gs.done&&!gs.running); return true; }
        if(attr=="gi_yieldfrom"){
            out=gs.in_yield_from&&!gs.running&&!gs.saved_stack.empty()?gs.saved_stack.back():VMVal::make_none();
            return true;
        }
        if(attr=="gi_frame"){
            if(gs.done||!gs.code){ out=VMVal::make_none(); return true; }
            int line=gs.code->first_line;
            if(gs.started){
                // a paused yield: the instruction before ip; a paused yield
                // from: ip itself; running: the current instruction
                size_t at=gs.running?(call_stack_.empty()?0:(size_t)call_stack_.back().ip):(size_t)gs.ip;
                if(!gs.in_yield_from&&at>0) at--;
                if(at<gs.code->instructions.size()&&gs.code->instructions[at].line>0) line=gs.code->instructions[at].line;
            }
            std::string mod="__main__";
            if(gs.code->module_env){ auto it=gs.code->module_env->find("__name__"); if(it!=gs.code->module_env->end()&&it->second.type==VMType::STRING) mod=it->second.s; }
            std::vector<VMVal> a{VMVal::make_str(gs.code->file),VMVal::make_int(line),VMVal::make_str(gs.name),VMVal::make_str(mod)};
            out=vm_call(load_var("_NyFrame"),a,std::nullopt,nullptr);
            return true;
        }
        if(attr=="gi_code"){
            if(!gs.code){ out=VMVal::make_none(); return true; }
            VMVal f; f.type=VMType::FUNCTION; f.code=gs.code;
            if(gs.is_genexpr){
                std::vector<VMVal> a{VMVal::make_str(gs.code->file),VMVal::make_str(gs.name)};
                out=vm_call(load_var("_NyCodeInfo"),a,std::nullopt,nullptr);
            } else {
                std::vector<VMVal> a{f,VMVal::make_str("__code__")};
                out=vm_call(load_var("_ny_fn_attr"),a,std::nullopt,nullptr);
            }
            return true;
        }
        return false;
    }
    // Whether a try/except/finally/with covers the point where a generator
    // is paused - only then can closing it run code of the program.
    bool gen_pause_covered(const GenState& gs) const {
        if(!gs.code) return false;
        int pause = gs.in_yield_from ? (int)gs.ip : (int)gs.ip-1;
        for(auto& e : gs.code->exc_table){
            bool in_body = pause>=e.try_start && pause<e.try_end;
            bool in_rest = e.finally_start>=0 && pause>=e.try_end && pause<e.finally_start;
            if(in_body||in_rest) return true;
        }
        return false;
    }
public:
    // The last reference to a generator is gone (~GenState). Paused inside a
    // try/with while a program runs: its state moves to a zombie that is
    // closed between two instructions (never here, in the middle of whatever
    // dropped it), so its finally blocks and __exit__ run - as CPython's
    // reference counting finalizes a generator.
    void gen_dropped(GenState& gs) {
        if(gs.serial){ gen_live_.erase(gs.serial); gs.serial=0; }
        if(!gen_finalize_ || gs.done || !gs.started || gs.native || !gs.code) return;
        if(!gs.at_yield && !gs.in_yield_from) return;
        if(!gen_pause_covered(gs)) return;
        auto z=std::make_shared<GenState>();
        z->code=std::move(gs.code); z->ip=gs.ip; z->locals=std::move(gs.locals);
        z->self_val=std::move(gs.self_val); z->closure=std::move(gs.closure);
        z->saved_stack=std::move(gs.saved_stack);
        z->at_yield=gs.at_yield; z->in_yield_from=gs.in_yield_from;
        z->started=true; z->owner=gs.owner; z->is_genexpr=gs.is_genexpr;
        z->name=std::move(gs.name); z->vm=this;
        gen_zombies_.push_back(std::move(z));
        gen_zombie_flag_=true;
    }
private:
    void gen_report_ignored(GenState& gs, const VMVal& ev) {
        std::cerr<<"Exception ignored in: "<<vm_gen_repr(&gs)<<"\n"<<describe_exception(ev)<<"\n";
    }
    // Closes a generator nobody refers to; reports instead of raising.
    void gen_finalize(const std::shared_ptr<GenState>& sp) {
        GenState& gs=*sp;
        try { gen_close(gs, true); }
        catch(VMException& e){ gen_report_ignored(gs, e.value); }
        catch(std::exception& e){ std::cerr<<"Exception ignored in: "<<vm_gen_repr(&gs)<<"\n"<<e.what()<<"\n"; }
        if(!gs.done) gen_finish(gs);
    }
    void run_gen_zombies() {
        gen_zombie_flag_=false;
        std::vector<std::shared_ptr<GenState>> zs;
        zs.swap(gen_zombies_);
        for(auto& z : zs) gen_finalize(z);
        if(!gen_zombies_.empty()) gen_zombie_flag_=true;
    }
public:
    // End of the program: every generator this thread left paused is closed,
    // oldest first, so its finally blocks run (as when CPython shuts down).
    void gen_close_all() {
        if(gen_zombie_flag_) run_gen_zombies();
        uint64_t me=nycoro::thread_token();
        for(int guard=0; guard<10000000; guard++){
            GenState* victim=nullptr;
            for(auto& kv : gen_live_){
                GenState* g=kv.second;
                if(!g->done && !g->running && (g->at_yield||g->in_yield_from) && (g->owner==me||g->is_genexpr)){ victim=g; break; }
            }
            if(!victim) break;
            std::shared_ptr<GenState> sp;
            try { sp=victim->shared_from_this(); } catch(...) {}
            if(!sp){ gen_live_.erase(victim->serial); victim->serial=0; continue; }
            gen_finalize(sp);
            if(gen_zombie_flag_) run_gen_zombies();
        }
        gen_finalize_=false;
    }
private:
    // ── Lazy iteration helpers (zip/map/filter/enumerate/islice/any/all) ──
    // An iterator for anything iterable: generators and iterators as they
    // are, objects through __iter__ / __next__, everything else a snapshot.
    VMVal vm_iter_open(const VMVal& v) {
        switch(v.type){
            case VMType::GENERATOR: case VMType::ITERATOR: return v;
            case VMType::LIST: { std::vector<VMVal> c; if(v.list) c=*v.list; return VMVal::make_iter(std::move(c)); }
            case VMType::STRING: case VMType::MAP: case VMType::INT: case VMType::BYTES: return VMVal::make_iter(iter_items(v));
            case VMType::INSTANCE: {
                bool f=false;
                VMVal r=call_dunder_f(v,"__iter__",{},f);
                if(f){
                    if(r.type==VMType::INSTANCE){
                        VMVal m;
                        if(!class_lookup(r.class_name,"__next__",m))
                            throw_exception(make_exception("TypeError",{VMVal::make_str("iter() returned non-iterator of type '"+r.class_name+"'")}));
                        return r;
                    }
                    return vm_iter_open(r);
                }
                VMVal m;
                if(class_lookup(v.class_name,"__next__",m)) return v;
                return VMVal::make_iter(iter_items(v));   // __getitem__, or TypeError
            }
            default: break;
        }
        throw_exception(make_exception("TypeError",{VMVal::make_str("'"+vm_type_name(v)+"' object is not iterable")}));
    }
    bool vm_iter_step(VMVal& it, VMVal& out) {
        if(it.type==VMType::GENERATOR){
            if(!it.gen) return false;
            GenState& gs=*it.gen;
            return gen_resume(gs, 0, VMVal::make_none(), out);
        }
        if(it.type==VMType::ITERATOR){
            if(!it.iter) return false;
            auto& [cur,items]=*it.iter;
            if(cur>=(int)items.size()) return false;
            out=items[cur++];
            return true;
        }
        if(it.type==VMType::INSTANCE){
            try { out=call_dunder(it,"__next__",{}); return true; }
            catch(VMException& e){ if(is_stop_iteration(e.value)) return false; throw; }
        }
        return false;
    }
    VMVal gen_native(const std::string& name, std::function<bool(VMVal&)> fn) {
        VMVal g; g.type=VMType::GENERATOR;
        g.gen=std::make_shared<GenState>();
        g.gen->name=name; g.gen->native=std::move(fn); g.gen->vm=this;
        return g;
    }
    static bool vm_lazy_arg(const VMVal& v) { return v.type==VMType::GENERATOR||v.type==VMType::ITERATOR; }
    // An iterator object (an instance with __next__: itertools.count(), a
    // user iterator): zip/map/filter/enumerate over one are lazy too, as
    // over a generator - it was read to the end first, forever for an
    // infinite one (zip("abc", count())).
    bool vm_iterator_object(const VMVal& v) {
        if(v.type!=VMType::INSTANCE) return false;
        VMVal m;
        return class_lookup(v.class_name,"__next__",m);
    }
    // zip/map/filter/enumerate given a generator or iterator: lazy, like
    // the interpreter's (src/NyGen.cpp). Over lists they still return lists.
    bool gen_lazy_builtin(const std::string& nm, std::vector<VMVal>& a, VMVal& out) {
        VMVal kw=take_kwargs(a);
        size_t first = (nm=="map"||nm=="filter") ? 1 : 0;
        size_t last = nm=="enumerate" ? std::min<size_t>(1,a.size()) : a.size();
        bool lazy=false;
        for(size_t i=first;i<last;i++) if(vm_lazy_arg(a[i])||vm_iterator_object(a[i])) lazy=true;
        if(!lazy){ if(kw.type==VMType::MAP) a.push_back(kw); return false; }
        if(nm=="zip"){
            auto its=std::make_shared<std::vector<VMVal>>();
            for(auto& x : a) its->push_back(vm_iter_open(x));
            out=gen_native("zip",[this,its](VMVal& o)->bool{
                if(its->empty()) return false;
                std::vector<VMVal> row;
                for(auto& it : *its){ VMVal v; if(!vm_iter_step(it,v)) return false; row.push_back(std::move(v)); }
                o=VMVal::make_tuple(std::move(row));
                return true;
            });
            return true;
        }
        if(nm=="map"){
            if(a.size()<2) throw_exception(make_exception("TypeError",{VMVal::make_str("map() must have at least two arguments.")}));
            VMVal fn=a[0];
            auto its=std::make_shared<std::vector<VMVal>>();
            for(size_t i=1;i<a.size();i++) its->push_back(vm_iter_open(a[i]));
            out=gen_native("map",[this,its,fn](VMVal& o)->bool{
                std::vector<VMVal> args;
                for(auto& it : *its){ VMVal v; if(!vm_iter_step(it,v)) return false; args.push_back(std::move(v)); }
                o=vm_call(fn,args,std::nullopt);
                return true;
            });
            return true;
        }
        if(nm=="filter"){
            if(a.size()!=2) throw_exception(make_exception("TypeError",{VMVal::make_str("filter expected 2 arguments, got "+std::to_string(a.size()))}));
            VMVal fn=a[0];
            auto it=std::make_shared<VMVal>(vm_iter_open(a[1]));
            out=gen_native("filter",[this,it,fn](VMVal& o)->bool{
                for(;;){
                    VMVal v;
                    if(!vm_iter_step(*it,v)) return false;
                    bool keep;
                    if(fn.type==VMType::NONE) keep=vm_truthy(v);
                    else { std::vector<VMVal> args{v}; keep=vm_truthy(vm_call(fn,args,std::nullopt)); }
                    if(keep){ o=std::move(v); return true; }
                }
            });
            return true;
        }
        // enumerate(it, start=0)
        VMVal start=VMVal::make_int(0);
        if(a.size()>=2) start=a[1];
        else if(kw.type==VMType::MAP&&kw.map&&kw.map->count("start")) start=(*kw.map)["start"];
        auto it=std::make_shared<VMVal>(vm_iter_open(a[0]));
        auto idx=std::make_shared<VMVal>(start);
        out=gen_native("enumerate",[this,it,idx](VMVal& o)->bool{
            VMVal v;
            if(!vm_iter_step(*it,v)) return false;
            o=VMVal::make_tuple({*idx, std::move(v)});
            *idx=binop(nypy::A_ADD,*idx,VMVal::make_int(1));
            return true;
        });
        return true;
    }
    // islice / take, the same on both engines.
    void register_generator_natives() {
        globals_["islice"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a.size()>4)
                throw_exception(make_exception("TypeError",{VMVal::make_str("islice expected 2 to 4 arguments, got "+std::to_string(a.size()))}));
            auto ival=[&](const VMVal& v, const char* msg)->int64_t{
                if(v.type==VMType::NONE) return -1;
                if(v.type!=VMType::INT||!v.s.empty()||v.i<0) throw_exception(make_exception("ValueError",{VMVal::make_str(msg)}));
                return v.i;
            };
            const char* m_stop="Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize.";
            const char* m_idx="Indices for islice() must be None or an integer: 0 <= x <= sys.maxsize.";
            int64_t start=0, stop=-1, step=1;
            if(a.size()==2) stop=ival(a[1],m_stop);
            else {
                start=ival(a[1],m_idx); if(start<0) start=0;
                stop=ival(a[2],m_idx);
                if(a.size()==4 && a[3].type!=VMType::NONE){
                    if(a[3].type!=VMType::INT||!a[3].s.empty()||a[3].i<=0)
                        throw_exception(make_exception("ValueError",{VMVal::make_str("Step for islice() must be a positive integer or None.")}));
                    step=a[3].i;
                }
            }
            auto it=std::make_shared<VMVal>(vm_iter_open(a[0]));
            // CPython's islice_next: skip to the next wanted index, never
            // read past `stop`.
            struct St { int64_t cnt=0, next=0, stop=-1, step=1; };
            auto st=std::make_shared<St>();
            st->next=start; st->stop=stop; st->step=step;
            return gen_native("islice",[this,it,st](VMVal& o)->bool{
                VMVal v;
                while(st->cnt<st->next){ if(!vm_iter_step(*it,v)) return false; st->cnt++; }
                if(st->stop!=-1 && st->cnt>=st->stop) return false;
                if(!vm_iter_step(*it,v)) return false;
                st->cnt++;
                int64_t old=st->next;
                st->next+=st->step;
                if(st->next<old || (st->stop!=-1 && st->next>st->stop)) st->next=st->stop;
                o=std::move(v);
                return true;
            });
        });
        // The right side of an unpacking assignment (see VarDeclNode::unpack).
        globals_["__unpack_seq__"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            // an object with __iter__ / __next__ is iterated too, as Python
            // unpacks (it was indexed: "'It' object is not subscriptable")
            bool inst_iter=false;
            if(a[0].type==VMType::INSTANCE){
                VMVal m;
                inst_iter=class_lookup(a[0].class_name,"__iter__",m)||class_lookup(a[0].class_name,"__next__",m);
            }
            if(!vm_lazy_arg(a[0])&&!inst_iter) return a[0];
            int64_t n = a.size()>=2 && a[1].type==VMType::INT ? a[1].i : -1;
            VMVal it=inst_iter?vm_iter_open(a[0]):a[0], v;
            std::vector<VMVal> items;
            if(n<0){ while(vm_iter_step(it,v)) items.push_back(std::move(v)); }
            else {
                while((int64_t)items.size()<=n && vm_iter_step(it,v)) items.push_back(std::move(v));
                if((int64_t)items.size()>n)
                    throw_exception(make_exception("ValueError",{VMVal::make_str("too many values to unpack (expected "+std::to_string(n)+")")}));
                if((int64_t)items.size()<n)
                    throw_exception(make_exception("ValueError",{VMVal::make_str("not enough values to unpack (expected "+std::to_string(n)+", got "+std::to_string(items.size())+")")}));
            }
            return VMVal::make_list(std::move(items));
        });
        globals_["take"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()!=2) throw_exception(make_exception("TypeError",{VMVal::make_str("take() takes exactly 2 arguments ("+std::to_string(a.size())+" given)")}));
            if(a[0].type!=VMType::INT) throw_exception(make_exception("TypeError",{VMVal::make_str("take(): n must be an integer")}));
            VMVal it=vm_iter_open(a[1]);
            std::vector<VMVal> out;
            VMVal v;
            for(int64_t i=0;i<a[0].i && vm_iter_step(it,v);i++) out.push_back(v);
            return VMVal::make_list(std::move(out));
        });
    }

    // Ordering for sorted/min/max: an instance's __lt__ (or the other
    // side's __gt__), lists element by element.
    int cmp_val(const VMVal& a, const VMVal& b) {
        if(a.type==VMType::INSTANCE||b.type==VMType::INSTANCE){
            if(vm_less(a,b)) return -1;
            if(vm_less(b,a)) return 1;
            return 0;
        }
        if(a.type==VMType::LIST&&b.type==VMType::LIST&&a.list&&b.list){
            size_t n=std::min(a.list->size(),b.list->size());
            for(size_t k=0;k<n;k++){ int c=cmp_val((*a.list)[k],(*b.list)[k]); if(c) return c; }
            return a.list->size()<b.list->size()?-1:(a.list->size()>b.list->size()?1:0);
        }
        return cmp_basic(a,b);
    }
    static int cmp_basic(const VMVal& a, const VMVal& b) {
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

    // Like call_dunder, and reports whether the method exists at all - a
    // dunder that returns none is not the same as one that is missing.
    // Like call_dunder, and reports whether the method exists at all - a
    // dunder that returns none is not the same as one that is missing.
    VMVal call_dunder_f(const VMVal& obj, const std::string& dunder, std::vector<VMVal> args, bool& found) {
        found=false;
        if(obj.type!=VMType::INSTANCE) return VMVal::make_none();
        VMVal m;
        if(!class_lookup(obj.class_name, dunder, m)) return VMVal::make_none();
        found=true;
        return invoke_method(m, obj, args, obj.class_name);
    }
    VMVal call_dunder(const VMVal& obj, const std::string& dunder, std::vector<VMVal> args) {
        bool found=false;
        return call_dunder_f(obj, dunder, std::move(args), found);
    }
    bool instance_truthy(VMVal& v) {
        bool found=false;
        VMVal r = call_dunder_f(v, "__bool__", {}, found);
        if(found) return r.type==VMType::INSTANCE ? true : r.is_truthy();
        VMVal lr = call_dunder_f(v, "__len__", {}, found);
        if(found) return lr.type==VMType::INT ? lr.i != 0 : lr.is_truthy();
        return true; // default: instances are truthy
    }

    // ── Operator protocol ────────────────────────────────────────────────
    bool vm_truthy(const VMVal& v) {
        if(v.type==VMType::INSTANCE){ VMVal c=v; return instance_truthy(c); }
        return v.is_truthy();
    }
    // A comparison dunder of `a`, else the reflected one of `b` (Python
    // tries a.__lt__(b), then b.__gt__(a)). Returns false when neither
    // side defines one.
    bool rich_compare(const VMVal& a, const VMVal& b, const char* op, const char* rop, VMVal& out) {
        // NotImplemented declines (the other side is next); a subclass's
        // reflected method comes first (round 77)
        bool f=false;
        bool r_first=right_overrides(a,b,rop);
        if(r_first){ out=call_dunder_f(b,rop,{a},f); if(f&&!is_ni(out)) return true; }
        if(a.type==VMType::INSTANCE){ out=call_dunder_f(a,op,{b},f); if(f&&!is_ni(out)) return true; }
        if(!r_first&&b.type==VMType::INSTANCE){ out=call_dunder_f(b,rop,{a},f); if(f&&!is_ni(out)) return true; }
        return false;
    }
    static std::string op_symbol_of(const std::string& dunder) {
        static const std::unordered_map<std::string,const char*> m={
            {"__add__","+"},{"__sub__","-"},{"__mul__","*"},{"__truediv__","/"},{"__floordiv__","//"},
            {"__mod__","%"},{"__pow__","** or pow()"},{"__and__","&"},{"__or__","|"},{"__xor__","^"},
            {"__lshift__","<<"},{"__rshift__",">>"},{"__matmul__","@"},{"__div__","/"}};
        auto it=m.find(dunder);
        return it==m.end()?dunder:std::string(it->second);
    }
    [[noreturn]] void order_unsupported(const char* sym, const VMVal& a, const VMVal& b) {
        raise_native_exception("TypeError",std::string("'")+sym+"' not supported between instances of '"+vm_type_name(a)+"' and '"+vm_type_name(b)+"'");
        throw 0;   // not reached
    }
    // Python's orderable pairs for < <= > >= (round 77; the rest compared as
    // false): numbers, two str, two bytes, and two lists or two tuples
    // element by element; anything else - `1 < "a"`, `None < 1`, `[] < 3`, a
    // dict - is a TypeError naming the first pair that cannot be ordered
    // (`[1] < ["a"]`: int and str). Instances are left to their dunders.
    void order_check(const char* sym, const VMVal& a, const VMVal& b, int depth=0) {
        auto num=[](const VMVal& v){ return v.type==VMType::INT||v.type==VMType::FLOAT||v.type==VMType::BOOL; };
        if(num(a)&&num(b)) return;
        if(a.type==b.type&&(a.type==VMType::STRING||a.type==VMType::BYTES)) return;
        if(a.type==VMType::INSTANCE||b.type==VMType::INSTANCE) return;
        if(a.type==VMType::LIST&&b.type==VMType::LIST&&!a.is_set()&&!b.is_set()&&a.b==b.b&&depth<100){
            size_t n=std::min(a.list?a.list->size():0, b.list?b.list->size():0);
            for(size_t k=0;k<n;k++){
                const VMVal& x=(*a.list)[k]; const VMVal& y=(*b.list)[k];
                if(vm_eq(x,y)) continue;
                order_check(sym,x,y,depth+1);
                return;
            }
            return;
        }
        order_unsupported(sym,a,b);
    }
    // The prelude's NotImplemented singleton.
    static bool is_ni(const VMVal& v){ return v.type==VMType::INSTANCE&&v.class_name=="_NyNotImplementedType"; }
    static VMVal ni_none(VMVal v){ return is_ni(v)?VMVal::make_none():v; }
    // r's class is a subclass of l's and defines `rname` below l's class.
    bool right_overrides(const VMVal& l, const VMVal& r, const char* rname) {
        if(!rname||l.type!=VMType::INSTANCE||r.type!=VMType::INSTANCE||l.class_name==r.class_name) return false;
        if(!class_derives(r.class_name,l.class_name)) return false;
        VMVal m; std::string owner;
        if(!class_lookup(r.class_name,rname,m,&owner)) return false;
        auto lm=class_mro(l.class_name);
        return std::find(lm->begin(),lm->end(),owner)==lm->end();
    }
    bool vm_less(const VMVal& a, const VMVal& b) {
        VMVal r;
        if(rich_compare(a,b,"__lt__","__gt__",r)) return vm_truthy(r);
        if(a.type==VMType::INSTANCE||b.type==VMType::INSTANCE) order_unsupported("<",a,b);
        if((a.type==VMType::BYTES)!=(b.type==VMType::BYTES))
            raise_native_exception("TypeError","'<' not supported between instances of '"+vm_type_name(a)+"' and '"+vm_type_name(b)+"'");
        if(a.type==VMType::LIST&&b.type==VMType::LIST) return cmp_val(a,b)<0;
        return a<b;
    }
    // ==, through __eq__ (either side); __ne__ falls back to not __eq__.
    bool vm_eq(const VMVal& a, const VMVal& b) {
        VMVal r;
        if(rich_compare(a,b,"__eq__","__eq__",r)) return vm_truthy(r);
        if(a.is_set()||b.is_set()) return a==b;  // by keys, in any order
        if(a.type==VMType::LIST&&b.type==VMType::LIST&&a.list&&b.list){
            if(a.b!=b.b) return false;           // a tuple never equals a list
            if(a.list->size()!=b.list->size()) return false;
            for(size_t k=0;k<a.list->size();k++) if(!vm_eq((*a.list)[k],(*b.list)[k])) return false;
            return true;
        }
        return a==b;
    }
    bool vm_ne(const VMVal& a, const VMVal& b) {
        VMVal r;
        if(rich_compare(a,b,"__ne__","__ne__",r)) return vm_truthy(r);
        return !vm_eq(a,b);
    }
    // A binary operator's dunder on the left operand, else the reflected one
    // on the right (__add__, then __radd__ - so sum() of objects and 5 + v
    // work).
    // -obj / ~obj / +obj: its dunder, or TypeError.
    VMVal unary_dunder(const VMVal& v, const char* name, const char* sym) {
        bool f=false;
        VMVal r=call_dunder_f(v,name,{},f);
        if(!f) throw_exception(make_exception("TypeError",{VMVal::make_str(std::string("bad operand type for unary ")+sym+": '"+v.class_name+"'")}));
        return r;
    }
    bool binary_dunder(const VMVal& l, const VMVal& r, const char* name, const char* rname, VMVal& out) {
        bool f=false, declined=false;
        bool r_first=right_overrides(l,r,rname);
        if(r_first){ out=call_dunder_f(r,rname,{l},f); if(f&&!is_ni(out)) return true; declined|=f; }
        if(l.type==VMType::INSTANCE){ out=call_dunder_f(l,name,{r},f); if(f&&!is_ni(out)) return true; declined|=f; }
        if(!r_first&&r.type==VMType::INSTANCE && rname){ out=call_dunder_f(r,rname,{l},f); if(f&&!is_ni(out)) return true; declined|=f; }
        // every method declined (NotImplemented): TypeError, as Python
        if(declined) raise_native_exception("TypeError","unsupported operand type(s) for "+op_symbol_of(name)+": '"+vm_type_name(l)+"' and '"+vm_type_name(r)+"'");
        return false;
    }
    // The items of anything iterable, for natives that take an iterable:
    // lists, strings, maps (keys), iterators, generators, and instances with
    // __iter__, __next__ or a __getitem__ sequence.
    static bool is_iterable_object(const VMVal& v) {
        return v.type==VMType::INSTANCE||v.type==VMType::GENERATOR||v.type==VMType::ITERATOR;
    }

    // str(v) and repr(v) with the user's __str__/__repr__, also for the
    // items of a list or map (which rendered as "<C instance>" through
    // VMVal::repr, which cannot call into the program).
    std::string vm_str(const VMVal& v) {
        if(v.type==VMType::CLASS&&!class_meta_.empty()){
            VMVal r;
            if(meta_call(v,"__str__",{},r)||meta_call(v,"__repr__",{},r)) return r.to_string();
        }
        if(v.type==VMType::INSTANCE){
            // str() of an exception is BaseException.__str__ even when the
            // class has its own __repr__ (round 77, as on the interpreter)
            bool exc=v.map&&vm_exc_classes().count(v.class_name);
            for(auto dname : {"__str__","__repr__"}){
                if(exc&&dname[2]=='r') break;
                bool found=false;
                VMVal r=call_dunder_f(v,dname,{},found);
                if(found) return r.to_string();
            }
            return v.to_string();
        }
        if(v.type==VMType::LIST||v.type==VMType::MAP) return vm_repr(v);
        return v.to_string();
    }
    std::string vm_repr(const VMVal& v) {
        if(v.type==VMType::CLASS&&!class_meta_.empty()){
            VMVal r;
            if(meta_call(v,"__repr__",{},r)) return r.to_string();
        }
        if(v.type==VMType::INSTANCE){
            // __repr__ only: repr() does not fall back to __str__ (round 77,
            // as on the interpreter and in Python)
            bool found=false;
            VMVal r=call_dunder_f(v,"__repr__",{},found);
            if(found) return r.to_string();
            return v.repr();
        }
        if(v.is_set()&&v.list){
            bool fz=v.is_frozenset();
            if(v.list->empty()) return fz?"frozenset()":"set()";
            std::string r=fz?"frozenset({":"{";
            for(size_t k=0;k<v.list->size();k++){ if(k) r+=", "; r+=vm_repr((*v.list)[k]); }
            return r+(fz?"})":"}");
        }
        if(v.type==VMType::LIST&&v.list){
            VMReprEnter guard(v.list.get());   // round 77
            if(guard.again) return v.b?"(...)":"[...]";
            std::string r=v.b?"(":"[";
            for(size_t k=0;k<v.list->size();k++){
                if(k) r+=", ";
                const VMVal& e=(*v.list)[k];
                r+=(e.type==VMType::LIST&&e.list==v.list)?(v.b?"(...)":"[...]"):vm_repr(e);
            }
            if(v.b&&v.list->size()==1) r+=",";
            return r+(v.b?")":"]");
        }
        if(v.type==VMType::MAP&&v.class_name=="__bound_method__"&&v.map){
            auto f=v.map->find("__fn__");
            std::string nm = (f!=v.map->end()&&f->second.code) ? f->second.code->name : std::string("?");
            return "<bound method "+nm+">";
        }
        if(v.type==VMType::MAP&&v.map&&v.class_name.empty()){
            VMReprEnter guard(v.map.get());   // round 77
            if(guard.again) return "{...}";
            std::string r="{"; bool first=true;
            for(auto& [k,x]:*v.map){
                if(vm_internal_key(k)) continue;
                if(!first) r+=", ";
                r+=vm_key_value(k).repr()+": "+((x.type==VMType::MAP&&x.map==v.map)?std::string("{...}"):vm_repr(x));
                first=false;
            }
            return r+"}";
        }
        return v.repr();
    }

    // ── Classes ──────────────────────────────────────────────────────────
    // A class's namespace (class_vars_[name]) is what running its body
    // defined: methods (function values, carrying their defaults and
    // closure), decorated members (property, staticmethod, classmethod),
    // class variables, nested classes. Lookups follow the MRO - C3 over every
    // base, as on the interpreter. The VM used to scan the body's bytecode
    // for `name = constant` pairs and find methods among its compiled code
    // objects, so a class variable computed by an expression, a decorator,
    // @property, a second base, and any class-level statement were ignored.
    std::unordered_map<std::string,std::shared_ptr<std::vector<std::string>>> mro_cache_;
    std::shared_ptr<std::vector<std::string>> class_mro(const std::string& cls) {
        auto it=mro_cache_.find(cls);
        if(it!=mro_cache_.end()) return it->second;
        mro_cache_[cls]=std::make_shared<std::vector<std::string>>(std::vector<std::string>{cls}); // cycle guard
        std::vector<std::vector<std::string>> seqs;
        std::vector<std::string> direct;
        auto rit=class_reg_.find(cls);
        if(rit!=class_reg_.end()&&rit->second){
            std::vector<std::string> bases=rit->second->bases;
            if(bases.empty()&&!rit->second->parent_class.empty()) bases.push_back(rit->second->parent_class);
            for(auto& b:bases){
                if(b==cls) continue;
                seqs.push_back(*class_mro(b));
                direct.push_back(b);
            }
        }
        seqs.push_back(direct);
        std::vector<std::string> out{cls};
        bool ok=true;
        while(true){
            bool any=false;
            for(auto& sq:seqs) if(!sq.empty()){ any=true; break; }
            if(!any) break;
            std::string pick; bool found=false;
            for(auto& sq:seqs){
                if(sq.empty()) continue;
                const std::string& cand=sq[0];
                bool in_tail=false;
                for(auto& sq2:seqs) for(size_t k=1;k<sq2.size();k++) if(sq2[k]==cand){ in_tail=true; break; }
                if(!in_tail){ pick=cand; found=true; break; }
            }
            if(!found){ ok=false; break; }
            out.push_back(pick);
            for(auto& sq:seqs) if(!sq.empty()&&sq[0]==pick) sq.erase(sq.begin());
        }
        if(!ok){
            // Not C3-consistent: depth-first, left to right, first occurrence.
            out={cls};
            std::vector<std::string> todo=direct;
            while(!todo.empty()){
                std::string k=todo.front(); todo.erase(todo.begin());
                if(std::find(out.begin(),out.end(),k)!=out.end()) continue;
                out.push_back(k);
                auto kit=class_reg_.find(k);
                if(kit!=class_reg_.end()&&kit->second){
                    size_t at=0;
                    for(auto& b:kit->second->bases) todo.insert(todo.begin()+(long)(at++), b);
                }
            }
        }
        auto res=std::make_shared<std::vector<std::string>>(std::move(out));
        mro_cache_[cls]=res;
        return res;
    }
    // `attr` in the namespace of `cls` or a class after it in its MRO
    // (strictly after `after`, when given - for super()).
    bool class_lookup(const std::string& cls, const std::string& attr, VMVal& out,
                      std::string* owner=nullptr, const std::string* after=nullptr) {
        auto mro=class_mro(cls);
        size_t i=0;
        if(after){
            size_t k=0;
            for(;k<mro->size();k++) if((*mro)[k]==*after) break;
            i = k<mro->size() ? k+1 : mro->size();
        }
        for(;i<mro->size();i++){
            auto cv=class_vars_.find((*mro)[i]);
            if(cv==class_vars_.end()) continue;
            auto f=cv->second.find(attr);
            if(f==cv->second.end()) continue;
            out=f->second;
            if(owner) *owner=(*mro)[i];
            return true;
        }
        // every class reaches object's __subclasses__ and mro (round 77)
        if(!after&&(attr=="__subclasses__"||attr=="mro")&&cls!="object"
           &&std::find(mro->begin(),mro->end(),std::string("object"))==mro->end())
            return class_lookup("object",attr,out,owner);
        return false;
    }
    // ── eval / exec / compile (round 77; as NythonExecutor's) ──
    std::string snippet_source(const VMVal& v, std::string& mode, std::string& fname, const char* who) {
        if(v.type==VMType::INSTANCE&&nyrt::shown_class_name(v.class_name)=="_NyCode"&&v.map){
            auto g=[&](const char* k){ auto it=v.map->find(k); return it!=v.map->end()?it->second.to_string():std::string(); };
            mode=g("mode"); fname=g("co_filename");
            return g("source");
        }
        if(v.type==VMType::BYTES) return v.bdata();
        if(v.type==VMType::STRING) return v.s;
        raise_native_exception("TypeError",std::string(who)+"() arg 1 must be a string, bytes or code object");
        return std::string();
    }
    nython::node::node_ptr parse_snippet(const std::string& src, const std::string& fname) {
        try {
            auto source=nython::reader::SourceCode::from_text(src,fname);
            auto reporter=std::make_shared<nython::exception::Reporter>(source);
            auto lx=std::make_shared<nython::lexer::Lexer>(source);
            lx->tokenize();
            nython::parser::Parser pr(reporter.get(),(nython::Runnable*)this,lx.get());
            auto ast=pr.parse();
            if(ast) prelude_asts_.push_back(ast);   // what it defines outlives the call
            return ast;
        } catch(nython::exception::SyntaxError& e){
            raise_native_exception("SyntaxError",e.message());
        } catch(nython::exception::UnexpectedCharError& e){
            raise_native_exception("SyntaxError",e.message());
        }
        return nullptr;
    }
    // Runs module-level code in a frame of its own whose variables start as
    // `locals` and are handed back in it.
    void run_code_with_locals(std::shared_ptr<VMCode> code, VMMap& locals) {
        check_depth();
        size_t base=stack_.size();
        CallFrame fr; fr.code=code; fr.ip=0; fr.stack_base=base;
        fr.locals=locals;
        call_stack_.push_back(std::move(fr));
        try { run_frame(); } catch(VMReturn&){}
        catch(...){ call_stack_.pop_back(); if(stack_.size()>base) stack_.resize(base); throw; }
        locals=call_stack_.back().locals;
        call_stack_.pop_back();
        if(stack_.size()>base) stack_.resize(base);
    }
    VMVal vm_eval_exec(bool is_exec, std::vector<VMVal>& a) {
        const char* who=is_exec?"exec":"eval";
        if(a.empty()) raise_native_exception("TypeError",std::string(who)+"() missing required argument 'source' (pos 1)");
        std::string mode=is_exec?"exec":"eval", fname="<string>";
        std::string src=snippet_source(a[0],mode,fname,who);
        if(mode=="exec") is_exec=true;
        if(!is_exec){
            size_t b=src.find_first_not_of(" \t");
            src=b==std::string::npos?std::string():src.substr(b);
        }
        auto ast=parse_snippet(src,fname);
        if(!ast) return VMVal::make_none();
        if(!is_exec){
            if(!nython::node::is_expression_program(ast)) raise_native_exception("SyntaxError","invalid syntax");
            ast=parse_snippet("__ny_eval__ = (" + src + "\n)",fname);   // its value lands in a variable
        }
        bool has_g=a.size()>1&&a[1].type!=VMType::NONE, has_l=a.size()>2&&a[2].type!=VMType::NONE;
        if(has_g&&a[1].type!=VMType::MAP) raise_native_exception("TypeError",std::string(who)+"() globals must be a dict, not "+vm_type_name(a[1]));
        Compiler c; auto code=c.compile(ast);
        if(has_g||has_l){
            // A dict's string key is the plain name, except a dunder name
            // ("\x01s__x__"); a scope keys every name plainly (round 77).
            auto scope_name=[](const std::string& k, std::string& out)->bool{
                if(k.size()>=2&&k[0]=='\x01'){ if(k[1]!='s') return false; out=k.substr(2); return true; }
                if(vm_internal_key(k)) return false;
                out=k; return true;
            };
            // what the code bound that goes back into a dict: every name
            // but the engine's temporaries
            auto exported=[](const std::string& k){
                if(k.empty()||(unsigned char)k[0]<0x20||k=="__ny_eval__"||nyrt::is_decorator_temp(k)) return false;
                if(k.size()>7&&k.compare(0,5,"__exc")==0&&k.compare(k.size()-2,2,"__")==0
                   &&k.find_first_not_of("0123456789",5)==k.size()-2) return false;
                return true;
            };
            std::shared_ptr<VMMap> env;
            // exec(src, ns) / eval(src, ns): the dict itself is the module
            // scope (round 77, as Python) - functions defined there see
            // later changes to it, and what they bind with `global` lands
            // in it. With a locals dict too, a scope made from both, its
            // bindings copied into the locals dict afterwards.
            bool live=has_g&&a[1].map&&(!has_l||(a[2].type==VMType::MAP&&a[2].map==a[1].map));
            if(live){
                env=a[1].map;
                std::vector<std::pair<std::string,VMVal>> dunders;
                for(auto& kv:*env){ std::string n; if(kv.first.size()>=2&&kv.first[0]=='\x01'&&scope_name(kv.first,n)) dunders.push_back({n,kv.second}); }
                for(auto& d:dunders) (*env)[d.first]=d.second;
            } else {
                env=std::make_shared<VMMap>(); vmgc::track_map(env);
                std::string n;
                if(has_g&&a[1].map) for(auto& kv:*a[1].map) if(scope_name(kv.first,n)) (*env)[n]=kv.second;
                if(has_l&&a[2].type==VMType::MAP&&a[2].map) for(auto& kv:*a[2].map) if(scope_name(kv.first,n)) (*env)[n]=kv.second;
            }
            tag_module_code(code,env);
            code->module_top=true;
            try{ exec_code(code,{},std::nullopt); } catch(VMReturn&){}
            if(!is_exec){
                auto it=env->find("__ny_eval__");
                VMVal r=it!=env->end()?it->second:VMVal::make_none();
                if(live) env->erase("__ny_eval__");
                return r;
            }
            if(live){
                // a dunder name it bound (def __init__, __all__ = ...) shows in the dict too
                std::vector<std::pair<std::string,VMVal>> add;
                for(auto& kv:*env) if(vm_internal_key(kv.first)&&exported(kv.first)) add.push_back({nypy::key_of_str(kv.first),kv.second});
                for(auto& d:add) (*env)[d.first]=d.second;
                return VMVal::make_none();
            }
            VMVal out=has_l&&a[2].type==VMType::MAP?a[2]:a[1];
            for(auto& kv:*env) if(exported(kv.first)) (*out.map)[nypy::key_of_str(kv.first)]=kv.second;
            return VMVal::make_none();
        }
        VMMap locals;
        {
            VMVal l=vm_locals_map();
            if(l.map) for(auto& kv:*l.map) locals[kv.first]=kv.second;
        }
        VMMap seed=locals;
        run_code_with_locals(code,locals);
        if(!is_exec){
            auto it=locals.find("__ny_eval__");
            return it!=locals.end()?it->second:VMVal::make_none();
        }
        {
            // what it bound or rebound, into the caller's scope
            for(auto& kv:locals){
                if(reflect_hidden(kv.first)) continue;
                auto sit=seed.find(kv.first);
                if(sit==seed.end()||!vm_same(sit->second,kv.second)) store_var(kv.first,kv.second);
            }
        }
        return VMVal::make_none();
    }
    static bool vm_same(const VMVal& x, const VMVal& y) {
        if(x.type!=y.type) return false;
        switch(x.type){
            case VMType::INT: return x.i==y.i && x.s==y.s;
            case VMType::FLOAT: return x.d==y.d;
            case VMType::BOOL: return x.b==y.b;
            case VMType::STRING: return x.s==y.s;
            case VMType::NONE: return true;
            case VMType::LIST: return x.list==y.list;
            case VMType::MAP: case VMType::INSTANCE: return x.map==y.map;
            case VMType::FUNCTION: case VMType::CLASS: return x.code==y.code && x.class_name==y.class_name;
            default: return false;
        }
    }
    VMVal vm_compile(std::vector<VMVal>& a) {
        if(a.size()<3) raise_native_exception("TypeError","compile() missing required argument (source, filename, mode)");
        std::string fname=a[1].to_string(), mode=a[2].to_string();
        if(mode!="exec"&&mode!="eval"&&mode!="single") raise_native_exception("ValueError","compile() mode must be 'exec', 'eval' or 'single'");
        std::string m2=mode, f2=fname;
        std::string src=snippet_source(a[0],m2,f2,"compile");
        auto ast=parse_snippet(src,fname);
        if(mode=="eval"&&ast&&!nython::node::is_expression_program(ast)) raise_native_exception("SyntaxError","invalid syntax");
        std::vector<VMVal> ca{VMVal::make_str(src),VMVal::make_str(fname),VMVal::make_str(mode=="single"?"exec":mode)};
        return vm_call(load_var("_NyCode"),ca,std::nullopt,nullptr);
    }

    // ── Reflection (round 77) ──
    // The exception an except clause is handling now, here or in a caller
    // (_ny_exc_current, sys.exc_info()[1]); none outside every except
    // clause. A clause keeps its exception in a hidden "__excN__" variable
    // for a bare `raise` and deletes it when it completes; the innermost
    // clause has the highest N in its frame.
    VMVal vm_exc_current() {
        auto best_in=[](const VMMap& m, VMVal& out)->bool{
            long best=-1;
            for(auto& kv:m){
                const std::string& k=kv.first;
                if(k.size()<8||k.compare(0,5,"__exc")!=0||k.compare(k.size()-2,2,"__")!=0) continue;
                std::string mid=k.substr(5,k.size()-7);
                if(mid.empty()||mid.find_first_not_of("0123456789")!=std::string::npos) continue;
                long nn=std::stol(mid);
                if(nn>best && kv.second.type!=VMType::NONE){ best=nn; out=kv.second; }
            }
            return best>=0;
        };
        VMVal out=VMVal::make_none();
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            auto& f=call_stack_[i];
            if(best_in(f.locals,out)) return out;
            if(f.own_env&&f.closure_env&&best_in(*f.closure_env,out)) return out;
        }
        if(VMMap* me=menv()) if(best_in(*me,out)) return out;
        return VMVal::make_none();
    }
    static bool reflect_hidden(const std::string& k) {
        if(k.empty()||(unsigned char)k[0]<0x20) return true;
        if(k=="__name__"||k=="__file__"||k=="__doc__") return false;
        return k.size()>=2&&k[0]=='_'&&k[1]=='_';
    }
    std::unordered_set<std::string> base_global_names_;
    VMVal vm_globals_map() {
        VMVal d=VMVal::make_map();
        if(VMMap* me=menv()){
            for(auto& kv:*me) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
            return d;
        }
        for(auto& kv:globals_){
            if(reflect_hidden(kv.first)||base_global_names_.count(kv.first)) continue;
            (*d.map)[kv.first]=kv.second;
        }
        if(!call_stack_.empty())
            for(auto& kv:call_stack_.front().locals) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
        return d;
    }
    VMVal vm_locals_map() {
        if(call_stack_.size()<=1||!call_stack_.back().code||call_stack_.back().code->module_top) return vm_globals_map();
        auto& fr=call_stack_.back();
        VMVal d=VMVal::make_map();
        for(auto& kv:fr.locals) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
        if(fr.own_env&&fr.closure_env)
            for(auto& kv:*fr.closure_env) if(!reflect_hidden(kv.first)&&fr.locals.count(kv.first)) (*d.map)[kv.first]=kv.second;
        return d;
    }
    static bool is_module_ns(const VMVal& v) {
        return v.type==VMType::MAP&&v.map&&!v.class_name.empty()&&v.class_name!="__kwargs__";
    }
    // _ny_fn_info(f) (round 77): [name, qualname, module, params, flags,
    // file, line] - params [name, kind, has_default, default] with inspect's
    // kinds (0 positional-only .. 4 **kwargs), flags 1 generator, 2
    // coroutine, 4 async generator, 8 lambda - as the interpreter's
    // NythonExecutor::fnInfo. A bound method answers for its function; the
    // `self` this engine keeps out of param_names is put back.
    VMVal fn_info(VMVal f) {
        if(f.type==VMType::MAP&&f.class_name=="__bound_method__"&&f.map){
            auto it=f.map->find("__fn__");
            if(it==f.map->end()) return VMVal::make_none();
            VMVal fn=it->second; f=fn;
        }
        if(f.type!=VMType::FUNCTION||!f.code) return VMVal::make_none();
        const VMCode& c=*f.code;
        const std::vector<VMVal>& dflts=f.list?*f.list:c.param_defaults;
        auto S=[](const std::string& s){ return VMVal::make_str(s); };
        std::vector<VMVal> ps;
        if(c.is_method) ps.push_back(VMVal::make_list({S("self"),VMVal::make_int(c.posonly>0?0:1),VMVal::make_bool(false),VMVal::make_none()}));
        bool star=false;
        for(size_t i=0;i<c.param_names.size();i++){
            std::string pn=c.param_names[i];
            int kind=1;
            if(pn=="*"){ star=true; continue; }
            if(pn.size()>1&&pn[0]=='*'&&pn[1]=='*'){ kind=4; pn=pn.substr(2); }
            else if(pn.size()>1&&pn[0]=='*'){ kind=2; pn=pn.substr(1); star=true; }
            else if(star) kind=3;
            else if(i<c.posonly) kind=0;
            bool has=kind!=2&&kind!=4&&i<dflts.size()&&!dflts[i].is_missing();
            ps.push_back(VMVal::make_list({S(pn),VMVal::make_int(kind),VMVal::make_bool(has),has?dflts[i]:VMVal::make_none()}));
        }
        std::string mod="__main__";
        if(c.module_env){ auto it=c.module_env->find("__name__"); if(it!=c.module_env->end()&&it->second.type==VMType::STRING) mod=it->second.s; }
        int flags=c.name=="<lambda>"?8:0;
        if(c.is_async) flags|=c.is_async_gen?4:2;
        else if(c.has_yield()) flags|=1;
        return VMVal::make_list({S(c.name),S(c.qualname.empty()?c.name:c.qualname),S(mod),VMVal::make_list(std::move(ps)),
                                 VMVal::make_int(flags),S(c.file),VMVal::make_int(c.first_line)});
    }
    // _ny_fn_globals(f) (round 77): f.__globals__, the names of the module f
    // was defined in (a copy, as globals() is here).
    VMVal fn_globals(VMVal f) {
        if(f.type==VMType::MAP&&f.class_name=="__bound_method__"&&f.map){
            auto it=f.map->find("__fn__");
            if(it!=f.map->end()){ VMVal fn=it->second; f=fn; }
        }
        if(f.type!=VMType::FUNCTION||!f.code) return VMVal::make_none();
        VMVal d=VMVal::make_map();
        if(f.code->module_env){
            for(auto& kv:*f.code->module_env) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
            return d;
        }
        for(auto& kv:globals_){
            if(reflect_hidden(kv.first)||base_global_names_.count(kv.first)) continue;
            (*d.map)[kv.first]=kv.second;
        }
        CallFrame* mf=in_other_thread()?module_frame_:(call_stack_.empty()?nullptr:&call_stack_.front());
        if(mf) for(auto& kv:mf->locals) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
        return d;
    }
    VMVal vm_vars(std::vector<VMVal>& a) {
        if(a.empty()) return vm_locals_map();
        const VMVal& o=a[0];
        VMVal d=VMVal::make_map();
        if(o.type==VMType::INSTANCE){
            if(o.map) for(auto& kv:*o.map) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
            return d;
        }
        if(o.type==VMType::CLASS){
            auto cv=class_vars_.find(o.class_name);
            if(cv!=class_vars_.end()) for(auto& kv:cv->second) if(!kv.first.empty()&&(unsigned char)kv.first[0]>=0x20) (*d.map)[kv.first]=kv.second;
            return d;
        }
        if(is_module_ns(o)){
            for(auto& kv:*o.map) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
            return d;
        }
        raise_native_exception("TypeError","vars() argument must have __dict__ attribute");
        return VMVal::make_none();
    }
    void class_member_names(const std::string& cls, std::set<std::string>& out) {
        auto mro=class_mro(cls);
        for(auto& c:*mro){
            auto cv=class_vars_.find(c);
            if(cv==class_vars_.end()) continue;
            for(auto& kv:cv->second) if(!kv.first.empty()&&(unsigned char)kv.first[0]>=0x20) out.insert(kv.first);
        }
    }
    VMVal vm_dir(std::vector<VMVal>& a) {
        std::set<std::string> names;
        if(a.empty()){
            VMVal l=vm_locals_map();
            for(auto& kv:*l.map) names.insert(kv.first);
        } else {
            const VMVal& o=a[0];
            if(o.type==VMType::INSTANCE){
                if(o.map) for(auto& kv:*o.map) if(!reflect_hidden(kv.first)) names.insert(kv.first);
                class_member_names(o.class_name,names);
                names.insert("__class__"); names.insert("__dict__");
            } else if(o.type==VMType::CLASS){
                class_member_names(o.class_name,names);
                for(const char* n:{"__bases__","__mro__","__module__","__name__","__qualname__"}) names.insert(n);
            } else if(is_module_ns(o)){
                for(auto& kv:*o.map) if(!reflect_hidden(kv.first)) names.insert(kv.first);
            } else {
                nypy::MemberKind k=vm_member_kind(o);
                if(const auto* ms=nypy::kind_methods(k)) names.insert(ms->begin(),ms->end());
                if(k!=nypy::MemberKind::Other){
                    for(auto& m:nypy::protocol_members()) names.insert(m);
                    names.insert("__class__");
                } else if(o.type==VMType::FUNCTION||o.type==VMType::NATIVE){
                    for(const char* n:{"__module__","__name__","__qualname__"}) names.insert(n);
                }
            }
        }
        std::vector<VMVal> out;
        for(auto& n:names) out.push_back(VMVal::make_str(n));
        return VMVal::make_list(std::move(out));
    }
    // slice objects (round 77): the prelude's `slice` for a slice spec
    // [start, stop(, step)], and a slice object's parts
    VMVal make_slice_object(const VMVal& spec) {
        std::vector<VMVal> a{VMVal::make_none(),VMVal::make_none(),VMVal::make_none()};
        if(spec.type==VMType::LIST&&spec.list) for(size_t i=0;i<spec.list->size()&&i<3;i++) a[i]=(*spec.list)[i];
        return vm_call(load_var("slice"),a,std::nullopt,nullptr);
    }
    std::vector<VMVal> slice_parts(const VMVal& sl) {
        std::vector<VMVal> out;
        for(const char* f:{"start","stop","step"}){
            VMVal v=VMVal::make_none();
            if(sl.map){ auto it=sl.map->find(f); if(it!=sl.map->end()) v=it->second; }
            out.push_back(v);
        }
        return out;
    }
    // The class statements that have run, by code; each held, so that a
    // statement's code freed with its module cannot have its address taken
    // by a new class statement that would then read as a re-run (round 77).
    std::unordered_map<const VMCode*, std::shared_ptr<VMCode>> class_ran_;
    int class_generation_=0;
    VMVal class_value(const std::string& name) {
        auto it=class_reg_.find(name);
        if(it==class_reg_.end()) return VMVal::make_none();
        return VMVal::make_class(it->second, name);
    }
    static bool is_property_desc(const VMVal& v) {
        return v.type==VMType::MAP && v.map && v.map->count("__is_property__");
    }
    VMVal property_get(const VMVal& desc, const VMVal& obj) {
        auto git=desc.map->find("__get__");
        if(git==desc.map->end()) return VMVal::make_none();
        std::vector<VMVal> no_args;
        // a getter whose first parameter is not named self (a metaclass's
        // `def size(cls)`) takes the object as its first argument
        if(git->second.type==VMType::FUNCTION) return call_with_first(git->second, obj, no_args, nullptr);
        std::vector<VMVal> a{obj};
        return vm_call(git->second, a, std::nullopt);
    }
    static VMVal make_bound(const VMVal& fn, const VMVal& self, bool as_cls=false) {
        VMVal bound=VMVal::make_map();
        bound.class_name="__bound_method__";
        (*bound.map)["__fn__"]=fn;
        (*bound.map)["__self__"]=self;
        if(as_cls) (*bound.map)["__cls__"]=VMVal::make_bool(true);
        return bound;
    }
    // A descriptor: a class attribute holding an object whose class defines
    // __get__ (cached_property, partialmethod...). Read through an instance
    // the attribute is __get__(instance, owner); through the class,
    // __get__(None, owner). An instance's own attribute of that name is
    // found before it (a non-data descriptor, as Python's).
    bool descriptor_get(const VMVal& d, const VMVal& inst, const std::string& owner, VMVal& out) {
        if(d.type!=VMType::INSTANCE) return false;
        VMVal g;
        if(!class_lookup(d.class_name,"__get__",g)) return false;
        std::vector<VMVal> a{inst.type==VMType::INSTANCE?inst:VMVal::make_none(), class_value(owner)};
        out=invoke_method(g, d, a, d.class_name);
        return true;
    }
    // A class member read through an instance: a property is read, a method
    // is bound to the instance, a classmethod to the class, a staticmethod
    // (or a Nython method without self) stays a plain function.
    VMVal bind_member(const VMVal& m, const VMVal& obj, const std::string& cls) {
        if(is_property_desc(m)) return property_get(m, obj);
        if(m.type==VMType::INSTANCE){ VMVal r; if(descriptor_get(m, obj, cls, r)) return r; }
        if(m.type==VMType::FUNCTION&&m.code){
            if(m.code->is_static) return m;
            if(m.code->is_classmethod) return make_bound(m, class_value(cls), true);
            if(!m.code->is_method){
                // A function put in the class from elsewhere (a decorator's
                // wrapper(*args), `f = some_function`) is bound as Python
                // binds any function: the instance becomes its first
                // argument (the __cls__ form passes it so). One written in
                // the class body without self is Nython's plain function.
                if(m.code->owner_class.empty()&&obj.type==VMType::INSTANCE) return make_bound(m, obj, true);
                return m;
            }
            return make_bound(m, obj);
        }
        return m;
    }
    // Calls class member `m` as a method of `self`.
    VMVal invoke_method(const VMVal& m, const VMVal& self, std::vector<VMVal>& args,
                        const std::string& cls, const VMVal* kwargs=nullptr) {
        if(m.type==VMType::FUNCTION&&m.code){
            if(m.code->is_static) return call_function(m, args, std::nullopt, kwargs);
            if(m.code->is_classmethod){
                std::vector<VMVal> a2; a2.reserve(args.size()+1);
                a2.push_back(class_value(cls)); for(auto& x:args) a2.push_back(x);
                return call_function(m, a2, std::nullopt, kwargs);
            }
            if(!m.code->is_method&&m.code->owner_class.empty()&&self.type==VMType::INSTANCE){
                // a function put in the class from elsewhere (a decorator's
                // wrapper): the instance is its first argument, as Python
                // (it got none, and the wrapped method saw self = None)
                std::vector<VMVal> a2; a2.reserve(args.size()+1);
                a2.push_back(self); for(auto& x:args) a2.push_back(x);
                return call_function(m, a2, std::nullopt, kwargs);
            }
            return call_function(m, args, self, kwargs);
        }
        if(is_property_desc(m)){ VMVal v=property_get(m, self); return vm_call(v, args, std::nullopt, kwargs); }
        if(m.type==VMType::INSTANCE){
            // a descriptor: what its __get__ gives is called
            VMVal b;
            if(descriptor_get(m, self, cls, b)) return vm_call(b, args, std::nullopt, kwargs);
        }
        return vm_call(m, args, std::nullopt, kwargs);
    }
    // The constructor, first class in the MRO defining __init__ (or init).
    bool find_ctor(const std::string& cls, VMVal& out) {
        auto mro=class_mro(cls);
        for(auto& c:*mro){
            auto cv=class_vars_.find(c);
            if(cv==class_vars_.end()) continue;
            auto f=cv->second.find("__init__");
            if(f==cv->second.end()) f=cv->second.find("init");
            if(f!=cv->second.end()&&(f->second.type==VMType::FUNCTION||f->second.type==VMType::NATIVE)){ out=f->second; return true; }
        }
        return false;
    }
    // ── metaclasses (round 77) ──────────────────────────────────────────
    // A class's metaclass: its statement's metaclass=, else the nearest
    // base's (MRO order); none for a plain class.
    std::unordered_set<std::string> metaclass_types_;   // classes deriving from type
    std::vector<std::pair<VMVal,bool>> constructing_;   // see type_new
    bool type_call_skip_=false;                         // see instantiate
    VMVal metaclass_of(const std::string& cname) {
        if(class_meta_.empty()) return VMVal::make_none();
        for(auto& c:*class_mro(cname)){
            auto it=class_meta_.find(c);
            if(it!=class_meta_.end()&&it->second.type==VMType::CLASS) return it->second;
        }
        return VMVal::make_none();
    }
    static std::string class_key(const VMVal& c){ return c.class_name.empty()?c.s:c.class_name; }
    bool meta_member(const VMVal& cls, const std::string& name, VMVal& m) {
        if(class_meta_.empty()||cls.type!=VMType::CLASS) return false;
        VMVal M=metaclass_of(class_key(cls));
        if(M.type!=VMType::CLASS) return false;
        std::string owner;
        return class_lookup(class_key(M),name,m,&owner)&&nyrt::shown_class_name(owner)!="object"
               &&(m.type==VMType::FUNCTION||m.type==VMType::NATIVE);
    }
    // m called with `first` as its first argument (self, cls or mcs).
    VMVal call_with_first(const VMVal& m, const VMVal& first, std::vector<VMVal> rest, const VMVal* kw) {
        if(m.type==VMType::FUNCTION&&m.code&&m.code->is_method&&!m.code->is_static) return call_function(m, rest, first, kw);
        std::vector<VMVal> a;
        a.reserve(rest.size()+1);
        a.push_back(first);
        for(auto& x:rest) a.push_back(x);
        return vm_call(m, a, std::nullopt, kw);
    }
    bool meta_call(const VMVal& cls, const char* name, std::vector<VMVal> args, VMVal& out) {
        VMVal m;
        if(!meta_member(cls,name,m)) return false;
        out=call_with_first(m, cls, std::move(args), nullptr);
        return true;
    }
    // The class namespace as the dict a metaclass gets, and C.__dict__:
    // without the parser's decorator temporaries (round 77).
    VMVal class_namespace(const std::string& cname) {
        VMVal d=VMVal::make_map();
        auto cv=class_vars_.find(cname);
        if(cv!=class_vars_.end()) for(auto& kv:cv->second)
            if(!nyrt::is_decorator_temp(kv.first)) (*d.map)[nypy::key_of_str(kv.first)]=kv.second;
        return d;
    }
    // A class statement with a metaclass: M.__new__ (whose type.__new__
    // returns the class already made), then M.__init__.
    VMVal run_metaclass(const VMVal& meta, const VMVal& clsv, VMCode& sub, const VMVal& kw) {
        // the class's own name, as Python passes it ("A", not "m.A" - round 77)
        VMVal name=VMVal::make_str(nyrt::bare_class_name(nyrt::shown_class_name(sub.name)));
        std::vector<VMVal> bv;
        for(auto& b:sub.bases){
            VMVal c=class_value(b);
            if(c.type==VMType::CLASS) bv.push_back(c);
            // a builtin base is one of the bases the metaclass sees (round 77)
            else if(nyrt::is_builtin_type_name(b)&&b!="object"){ VMVal t=load_var(b); if(t.type!=VMType::NONE&&t.type!=VMType::UNDEFINED) bv.push_back(t); }
        }
        VMVal bases=VMVal::make_tuple(bv);
        VMVal ns=class_namespace(sub.name);
        bool has_kw=kw.type==VMType::MAP&&kw.map&&!kw.map->empty();
        VMVal made=clsv, m;
        std::string owner;
        if(class_lookup(class_key(meta),"__new__",m,&owner)&&nyrt::shown_class_name(owner)!="object"&&m.type==VMType::FUNCTION){
            constructing_.push_back({clsv,false});
            std::vector<VMVal> a{meta,name,bases,ns};
            try{ made=vm_call(m, a, std::nullopt, has_kw?&kw:nullptr); }
            catch(...){ constructing_.pop_back(); throw; }
            bool ran=constructing_.back().second;
            constructing_.pop_back();
            if(!ran) class_created(clsv, kw);
        } else {
            class_meta_[sub.name]=meta;
            class_created(clsv, kw);
        }
        if(made.type==VMType::CLASS&&class_lookup(class_key(meta),"__init__",m,&owner)&&nyrt::shown_class_name(owner)!="object"&&m.type==VMType::FUNCTION)
            call_with_first(m, made, {name,bases,ns}, has_kw?&kw:nullptr);
        return made;
    }
    // type.__new__(mcs, name, bases, ns, **kw): the class a class statement
    // is building, or a new class (type(name, bases, ns), M(name, bases, ns)).
    VMVal type_new(std::vector<VMVal>& a, const VMVal* kw) {
        if(a.size()<4) raise_native_exception("TypeError","type.__new__() takes exactly 3 arguments ("+std::to_string(a.empty()?0:a.size()-1)+" given)");
        VMVal kwv=kw&&kw->type==VMType::MAP?*kw:VMVal::make_map();
        std::string name=a[1].type==VMType::STRING?a[1].s:a[1].to_string();
        if(!constructing_.empty()&&!constructing_.back().second){
            VMVal cls=constructing_.back().first;
            if(nyrt::bare_class_name(nyrt::shown_class_name(class_key(cls)))==nyrt::bare_class_name(name)){
                constructing_.back().second=true;
                auto& ns=class_vars_[class_key(cls)];
                // the dict's keys as names: "__init__" is stored "\x01s__init__" (round 77)
                if(a[3].type==VMType::MAP&&a[3].map) for(auto& kv:*a[3].map) if(nypy::key_kind(kv.first)==nypy::K_STR) ns[nypy::key_payload(kv.first)]=kv.second;
                if(a[0].type==VMType::CLASS) class_meta_[class_key(cls)]=a[0];
                mro_cache_.clear(); attr_hook_cache_[0].clear(); attr_hook_cache_[1].clear();
                class_created(cls, kwv);
                return cls;
            }
        }
        auto code=std::make_shared<VMCode>();
        code->name=class_reg_.count(name)?name+"#"+std::to_string(++class_generation_):name;
        code->is_class=true;
        for(auto& b:iter_items(a[2])){
            std::string n;
            if(b.type==VMType::CLASS) n=class_key(b);
            else if(b.type==VMType::NATIVE) n=b.class_name.rfind("__builtin__:",0)==0?b.class_name.substr(12):b.class_name;
            if(n.empty()) raise_native_exception("TypeError","bases must be types");
            code->bases.push_back(n);
        }
        if(!code->bases.empty()) code->parent_class=code->bases[0];
        class_reg_[code->name]=code;
        mro_cache_.clear(); attr_hook_cache_[0].clear(); attr_hook_cache_[1].clear(); no_new_.clear(); has_del_cache_.clear();
        // the namespace's keys are dict keys (a dunder name is encoded,
        // key_of_str); class variables are plain names (round 77)
        VMMap vars;
        if(a[3].type==VMType::MAP&&a[3].map) for(auto& kv:*a[3].map) if(nypy::key_kind(kv.first)==nypy::K_STR) vars[nypy::key_payload(kv.first)]=kv.second;
        class_vars_[code->name]=vars;
        if(is_exception_class(code->name)) note_exc_class(code->name);   // with its kind (round 77)
        VMVal clsv=VMVal::make_class(code, code->name);
        if(a[0].type==VMType::CLASS) class_meta_[code->name]=a[0];
        class_created(clsv, kwv);
        return clsv;
    }
    // A metaclass called: M(name, bases, ns) makes a class.
    VMVal call_metaclass(const VMVal& M, std::vector<VMVal>& args, const VMVal* kw) {
        VMVal m, made;
        std::string owner;
        std::vector<VMVal> a{M};
        for(auto& x:args) a.push_back(x);
        if(class_lookup(class_key(M),"__new__",m,&owner)&&nyrt::shown_class_name(owner)!="object"&&m.type==VMType::FUNCTION)
            made=vm_call(m, a, std::nullopt, kw);
        else made=type_new(a, kw);
        if(made.type==VMType::CLASS&&class_lookup(class_key(M),"__init__",m,&owner)&&nyrt::shown_class_name(owner)!="object"&&m.type==VMType::FUNCTION)
            call_with_first(m, made, args, kw);
        return made;
    }
    // A class's own __new__ (not object's); classes without one are
    // remembered until the next class is made.
    std::unordered_set<std::string> no_new_;
    std::unordered_map<std::string,VMVal> class_meta_;   // metaclass= of a class statement
    bool class_new(const std::string& cname, VMVal& m) {
        if(no_new_.count(cname)) return false;
        std::string owner;
        if(class_lookup(cname,"__new__",m,&owner)&&nyrt::shown_class_name(owner)!="object"&&m.type==VMType::FUNCTION) return true;
        no_new_.insert(cname);
        return false;
    }
    // What a class statement has made: the hooks of PEP 487 - __set_name__
    // of its attributes, then __init_subclass__ of the nearest base defining
    // it (an implicit classmethod) with the statement's keywords (round 77).
    // C.__subclasses__(): each class's direct subclasses, in creation order.
    std::unordered_map<std::string,std::vector<std::string>> subclasses_;
    void class_created(const VMVal& clsv, const VMVal& kw) {
        const std::string& cname=clsv.class_name;
        {
            auto rit=class_reg_.find(cname);
            std::vector<std::string> bs;
            if(rit!=class_reg_.end()&&rit->second) bs=rit->second->bases;
            if(bs.empty()&&cname!="object") bs.push_back("object");
            for(auto& b:bs){
                auto& v=subclasses_[b];
                if(b!=cname&&std::find(v.begin(),v.end(),cname)==v.end()) v.push_back(cname);
            }
        }
        if(class_derives(cname,"type")) metaclass_types_.insert(cname);
        if(!any_data_descr_){
            // a data descriptor class: attribute stores look for it (round 77)
            VMVal dm;
            if(class_lookup(cname,"__set__",dm)||class_lookup(cname,"__delete__",dm)) any_data_descr_=true;
        }
        {
            std::vector<std::pair<std::string,VMVal>> attrs;
            auto cv=class_vars_.find(cname);
            if(cv!=class_vars_.end())
                for(auto& kv:cv->second) if(kv.second.type==VMType::INSTANCE) attrs.push_back(kv);
            for(auto& [n,v]:attrs){
                VMVal m;
                if(!class_lookup(v.class_name,"__set_name__",m)) continue;
                std::vector<VMVal> a{clsv, VMVal::make_str(n)};
                invoke_method(m, v, a, v.class_name);
            }
        }
        VMVal m; std::string owner;
        bool has_kw=kw.type==VMType::MAP&&kw.map&&!kw.map->empty();
        if(class_lookup(cname,"__init_subclass__",m,&owner,&cname)&&(m.type==VMType::FUNCTION||m.type==VMType::NATIVE)){
            std::vector<VMVal> a{clsv};
            vm_call(m, a, std::nullopt, has_kw?&kw:nullptr);
        } else if(has_kw)
            raise_native_exception("TypeError", nyrt::shown_class_name(cname)+".__init_subclass__() takes no keyword arguments");
    }
    // The bases given by expressions (placeholders "\x06<i>"): a class, a
    // builtin type, or an object whose __mro_entries__ (PEP 560) names them.
    // Returns the bases as written (the class's __orig_bases__, also what
    // __mro_entries__ is given - round 77), none when no base was an
    // expression.
    VMVal resolve_expr_bases(VMCode& sub, const VMVal& vals) {
        std::vector<std::string> nb;
        std::vector<VMVal> orig;
        bool any=false;
        for(auto& b:sub.bases){
            if(!b.empty()&&b[0]=='\x06'){
                size_t i=(size_t)std::stoul(b.substr(1));
                orig.push_back((vals.type==VMType::LIST&&vals.list&&i<vals.list->size())?(*vals.list)[i]:VMVal::make_none());
                any=true;
                continue;
            }
            VMVal bv=b.find('.')==std::string::npos?load_var(b):VMVal::make_none();
            if(bv.type!=VMType::CLASS&&bv.type!=VMType::NATIVE) bv=class_value(b);
            orig.push_back(bv);
        }
        if(!any) return VMVal::make_none();
        VMVal orig_t=VMVal::make_tuple(orig);
        size_t oi=0;
        for(auto& b:sub.bases){
            VMVal v=orig[oi++];
            if(b.empty()||b[0]!='\x06'){ nb.push_back(b); continue; }
            std::vector<VMVal> entries{v};
            VMVal me;
            if(v.type==VMType::INSTANCE&&class_lookup(v.class_name,"__mro_entries__",me)){
                std::vector<VMVal> a{orig_t};
                entries=iter_items(invoke_method(me, v, a, v.class_name));
            }
            for(auto& e:entries){
                std::string n;
                if(e.type==VMType::CLASS) n=e.class_name.empty()?e.s:e.class_name;
                else if(e.type==VMType::NATIVE){ n=e.class_name.rfind("__builtin__:",0)==0?e.class_name.substr(12):e.class_name; }
                if(n.empty()) raise_native_exception("TypeError","bases must be types");
                nb.push_back(n);
            }
        }
        sub.bases=nb;
        return orig_t;
    }
    // C[x]: __class_getitem__ (PEP 560, an implicit classmethod) and the
    // builtin generics list[int], dict[str, int], ... (_NyGenericAlias).
    bool class_subscript(const VMVal& obj, const VMVal& idx, VMVal& out) {
        if(obj.type==VMType::CLASS){
            std::string cname=obj.class_name.empty()?obj.s:obj.class_name;
            VMVal m;
            if(!class_lookup(cname,"__class_getitem__",m)) return false;
            std::vector<VMVal> a{obj, idx};
            out=vm_call(m, a, std::nullopt, nullptr);
            return true;
        }
        if(obj.type!=VMType::NATIVE) return false;
        std::string b=native_name(obj);
        static const std::unordered_set<std::string> generic={"list","dict","tuple","set","frozenset","type"};
        if(!generic.count(b)) return false;
        std::vector<VMVal> a{obj, idx};
        out=vm_call(load_var("_NyGenericAlias"), a, std::nullopt, nullptr);
        return true;
    }
    // The builtin type values type() gives, taken when the builtins are
    // registered (a program's own `list = ...` does not change them).
    std::unordered_map<std::string,VMVal> builtin_types_;
    void capture_builtin_types() {
        for(const char* n:{"int","float","str","bool","list","dict","tuple","set","frozenset","bytes","bytearray","type","range","slice"}){
            auto it=globals_.find(n);
            if(it==globals_.end()&&std::string(n)=="dict") it=globals_.find("map");
            if(it==globals_.end()||it->second.type!=VMType::NATIVE) continue;
            VMVal v=it->second;
            if(v.class_name.empty()) v.class_name=std::string("__native__:")+n;
            builtin_types_[n]=v;
        }
    }
    // type(v) as a type object; none for the kinds that keep a legacy name.
    VMVal type_object_of(const VMVal& v) {
        auto bt=[&](const char* n)->VMVal{ auto it=builtin_types_.find(n); return it==builtin_types_.end()?VMVal::make_none():it->second; };
        switch(v.type){
        case VMType::BOOL: return bt("bool");
        case VMType::INT: return bt("int");
        case VMType::FLOAT: return bt("float");
        case VMType::STRING: return bt("str");
        case VMType::BYTES: return bt(v.b?"bytearray":"bytes");
        case VMType::LIST: return bt(v.is_set()?(v.is_frozenset()?"frozenset":"set"):v.b?"tuple":"list");
        case VMType::MAP:
            if(v.class_name=="__bound_method__"||is_property_desc(v)) return VMVal::make_none();
            return bt("dict");
        case VMType::INSTANCE: { VMVal c=class_value(v.class_name); return c.type==VMType::CLASS?c:VMVal::make_none(); }
        case VMType::CLASS: { VMVal meta=metaclass_of(class_key(v)); if(meta.type==VMType::CLASS) return meta; return bt("type"); }
        case VMType::NATIVE: if(!v.builtin_type_name().empty()) return bt("type"); return VMVal::make_none();
        default: return VMVal::make_none();
        }
    }
    // The name a builtin native is tagged with ("__builtin__:x", the
    // "__native__:x" a global read gives it, or the type it builds).
    static std::string native_name(const VMVal& v) {
        const std::string& c=v.class_name;
        std::string b=c.rfind("__builtin__:",0)==0?c.substr(12):c.rfind("__native__:",0)==0?c.substr(11):c;
        return b=="map"?std::string("dict"):b;
    }
    // A type in an X | Y union: a class, a builtin type, None.
    bool is_type_operand(const VMVal& v) {
        if(v.type==VMType::NONE||v.type==VMType::CLASS) return true;
        if(v.type!=VMType::NATIVE) return false;
        return nyrt::is_builtin_type_name(native_name(v));
    }
    VMVal instantiate(const VMVal& cls, std::vector<VMVal>& args, const VMVal* kwargs=nullptr) {
        // type.__call__ (a metaclass's super().__call__) sets the flag for
        // the one instantiation it makes, which must not run the
        // metaclass's __call__ again; nested ones still do
        // OSError(errno, strerror, ...) makes the subclass for that errno:
        // OSError(2, "x") is a FileNotFoundError (round 77, CPython's errnomap)
        if(cls.class_name=="OSError"&&args.size()>=2&&args.size()<=5&&args[0].type==VMType::INT&&args[0].s.empty()){
            const char* sub=nython::ny_errno_exc_class((long)args[0].i);
            if(*sub&&class_reg_.count(sub)) return instantiate(class_value(sub), args, kwargs);
        }
        bool skip_meta_call=type_call_skip_;
        type_call_skip_=false;
        if(!class_meta_.empty()||!metaclass_types_.empty()){
            VMVal m;
            if(!skip_meta_call&&meta_member(cls,"__call__",m)) return call_with_first(m, cls, args, kwargs);
            if(metaclass_types_.count(cls.class_name)&&args.size()==3) return call_metaclass(cls, args, kwargs);
        }
        // __new__(cls, *args, **kw) makes the object; __init__ runs when it
        // returned an instance of the class (round 77).
        {
            VMVal nw;
            if(class_new(cls.class_name, nw)){
                std::vector<VMVal> a; a.reserve(args.size()+1);
                a.push_back(cls);
                for(auto& x:args) a.push_back(x);
                VMVal inst=vm_call(nw, a, std::nullopt, kwargs);
                if(inst.type==VMType::INSTANCE&&class_derives(inst.class_name, cls.class_name)){
                    if(vm_exc_classes().count(cls.class_name)&&inst.map) set_exc_args(*inst.map, inst.class_name, args);
                    VMVal init;
                    if(find_ctor(cls.class_name, init)) invoke_method(init, inst, args, cls.class_name, kwargs);
                }
                return inst;
            }
        }
        auto attrs=new_instance_fields(cls.class_name);
        VMVal inst=VMVal::make_instance(cls.class_name,attrs);
        if(!class_reg_.count(cls.class_name)&&cls.code) class_reg_[cls.class_name]=cls.code;
        // An exception's args are the constructor's arguments whatever its
        // __init__ does (Python's BaseException.__new__); a class that calls
        // super().__init__(...) replaces them there.
        if(vm_exc_classes().count(cls.class_name)) set_exc_args(*attrs, cls.class_name, args);   // and the fields (round 77)
        VMVal init;
        if(find_ctor(cls.class_name, init)) invoke_method(init, inst, args, cls.class_name, kwargs);
        return inst;
    }
    // Runs a class body in its own frame; what it defines is the namespace.
    VMMap run_class_body(std::shared_ptr<VMCode> sub, CallFrame& outer) {
        CallFrame cf; cf.code=sub; cf.ip=0; cf.stack_base=stack_.size();
        bool outer_fn = outer.code && outer.code->name!="<module>" && !outer.code->is_class;
        if(outer_fn){
            // Methods of a class defined in a function close over it.
            ensure_own_env(outer);
            cf.closure_env=outer.closure_env;
        } else if(outer.closure_env) cf.closure_env=outer.closure_env;
        size_t base=stack_.size();
        call_stack_.push_back(std::move(cf));
        try { run_loop(); }
        catch(...){ call_stack_.pop_back(); if(stack_.size()>base) stack_.resize(base); throw; }
        auto ns=std::move(call_stack_.back().locals);
        call_stack_.pop_back();
        if(stack_.size()>base) stack_.resize(base);
        return ns;
    }

        VMVal run_loop() {
        // GIL switch points (round 74), as in CPython: entering a frame and
        // every backward jump (JUMP_ABSOLUTE closes each loop). A switch
        // swaps this thread's stacks out and back in; references into them
        // (`fr`) stay valid because deque elements never move.
        nyconc::tick();
        if(__builtin_expect(nyconc::signal_pending(),0)&&signal_hook_) signal_hook_();
        while(true){
            // Queued __del__ calls and due cycle collections (one load).
            vmgc::safe_point(*this);
            // Generators dropped while paused in a try/with are closed here,
            // between two instructions (gen_dropped).
            if(__builtin_expect(gen_zombie_flag_,0)) run_gen_zombies();
            CallFrame& fr=call_stack_.back();
            if(fr.ip>=(int)fr.code->instructions.size()) return VMVal::make_none();
            const Instruction& ins=fr.code->instructions[fr.ip++];
            if(vm_trace_) fprintf(stderr,"[vm] op=%d arg=%d depth=%d\n",(int)ins.op,ins.arg,(int)stack_.size());
            try {
            switch(ins.op){

            case Op::NOP: break;
            case Op::HALT: return VMVal::make_none();

            case Op::LOAD_CONST:  push(fr.code->constants[ins.arg]); break;
            case Op::LOAD_NAME: {
                // Reading a name bound nowhere raises NameError (it read none).
                const std::string& n=fr.code->names[ins.arg];
                push(load_var(n));
                if(stack_.back().type==VMType::NONE && !name_bound(n)){
                    pop();
                    throw_exception(make_exception("NameError",{VMVal::make_str("name '"+n+"' is not defined")}));
                }
                break;
            }
            case Op::STORE_NAME: {
                // A class body binds in the class namespace, always.
                if(fr.code->is_class){ fr.locals[fr.code->names[ins.arg]]=pop(); break; }
                if(exporting()){
                    call_stack_.front().locals.erase(fr.code->names[ins.arg]);
                    globals_[fr.code->names[ins.arg]]=pop();
                }
                else {
                    VMVal sv=pop();
                    store_var(fr.code->names[ins.arg], sv);
                    // Also into the frame's own environment, which closures
                    // made here read.
                    if(fr.own_env && fr.locals.count(fr.code->names[ins.arg]))
                        (*fr.closure_env)[fr.code->names[ins.arg]] = sv;
                }
                break;
            }
            case Op::DELETE_NAME: {
                const std::string& n=fr.code->names[ins.arg];
                if(!delete_var(n)){
                    if(n.rfind("__exc",0)==0) break;   // an except clause's hidden name (see TRY)
                    throw_exception(make_exception("NameError",{VMVal::make_str("name '"+n+"' is not defined")}));
                }
                break;
            }
            case Op::LOAD_GLOBAL_NAME: {
                const std::string& n=fr.code->names[ins.arg];
                VMVal v;
                if(!load_global(n,v))
                    throw_exception(make_exception("NameError",{VMVal::make_str("name '"+n+"' is not defined")}));
                push(std::move(v));
                break;
            }
            case Op::STORE_GLOBAL_NAME: {
                const std::string& n=fr.code->names[ins.arg];
                VMVal v=pop();
                if(VMMap* me=menv()){ (*me)[n]=std::move(v); break; }
                CallFrame* mf=in_other_thread()?module_frame_:(call_stack_.empty()?nullptr:&call_stack_.front());
                if(mf && mf->has_local(n)) mf->set(n,std::move(v));
                else if(globals_.count(n) || !mf) globals_[n]=std::move(v);
                else mf->set(n,std::move(v));
                break;
            }
            case Op::DEFINE_NAME: {
                if(fr.code->is_class){ fr.locals[fr.code->names[ins.arg]]=pop(); break; }
                VMVal dv=pop();
                define_var(fr.code->names[ins.arg], dv);
                // Into the frame's own environment too, if it has one.
                if(fr.own_env && fr.locals.count(fr.code->names[ins.arg]))
                    (*fr.closure_env)[fr.code->names[ins.arg]] = dv;
                break;
            }
            case Op::LOAD_SELF: {
                if(fr.self_val){ push(*fr.self_val); break; }
                // A lambda or nested def inside a method: the method's self,
                // captured with the closure (MAKE_FUNCTION).
                if(VMMap* se=env_find(fr.closure_env.get(), "self")){ push((*se)["self"]); break; }
                push(VMVal::make_none()); break;
            }

            case Op::LOAD_SUPER: {
                // A SUPER_PROXY for the class that DEFINES the running method
                // (owner_class) and its self: super().m() looks m up in
                // type(self)'s MRO after that class (next in line, not simply
                // the first base).
                VMVal self_v = fr.self_val.value_or(VMVal::make_none());
                if(!fr.self_val && fr.closure_env){
                    VMMap* se=env_find(fr.closure_env.get(), "self");
                    if(se) self_v=(*se)["self"];
                }
                // def __call__(cls, ...) / def __new__(mcs, ...): the first
                // argument (round 77)
                if(self_v.type==VMType::NONE&&!fr.code->param_names.empty()){
                    auto fa=fr.locals.find(fr.code->param_names[0]);
                    if(fa!=fr.locals.end()) self_v=fa->second;
                }
                std::string cur_cls = fr.code->owner_class.empty() ? self_v.class_name : fr.code->owner_class;
                VMVal proxy;
                proxy.type=VMType::SUPER_PROXY;
                proxy.s=cur_cls;
                proxy.list=std::make_shared<std::vector<VMVal>>(); vmgc::track_list(proxy.list);
                proxy.list->push_back(self_v);
                push(proxy);
                break;
            }

            case Op::LOAD_ATTR: {
                VMVal obj=pop(); push(get_attr(obj,fr.code->names[ins.arg])); break;
            }
            case Op::LOAD_ATTR_OPT: {
                VMVal obj=pop(), v;
                if(lookup_attr(obj,fr.code->names[ins.arg],v)) push(std::move(v)); else push(VMVal::make_absent());
                break;
            }
            case Op::LOAD_SUBSCR_OPT: {
                VMVal idx=pop(),obj=pop(),v;
                if(try_get_sub(obj,idx,v)) push(std::move(v)); else push(VMVal::make_absent());
                break;
            }
            case Op::CHECK_MEMBER:
                if(!stack_.empty()&&!has_member_noeval(stack_.back(),fr.code->names[ins.arg])) stack_.back()=VMVal::make_absent();
                break;
            case Op::DUP_TOP_TWO: { VMVal b=peek(0), a=peek(1); push(a); push(b); break; }
            case Op::STORE_ATTR: {
                VMVal obj=pop(); VMVal val=pop();
                set_attr(obj,fr.code->names[ins.arg],std::move(val)); break;
            }
            case Op::LOAD_SUBSCR: {
                VMVal idx=pop(),obj=pop();
                // a slice object as the index of a builtin sequence (round 77)
                if(obj.type!=VMType::INSTANCE&&idx.type==VMType::INSTANCE&&nyrt::shown_class_name(idx.class_name)=="slice"){
                    std::vector<VMVal> parts=slice_parts(idx);
                    push(vm_call_method(obj,"slice",parts)); break;
                }
                if(obj.type==VMType::INSTANCE){bool f=false;VMVal res=call_dunder_f(obj,"__getitem__",{idx},f);if(f){push(res);break;}
                    throw_exception(make_exception("TypeError",{VMVal::make_str("'"+obj.class_name+"' object is not subscriptable")}));}
                if(obj.type==VMType::CLASS&&!class_meta_.empty()){ VMVal r; if(meta_call(obj,"__getitem__",{idx},r)){ push(std::move(r)); break; } }
                if(obj.type==VMType::CLASS||obj.type==VMType::NATIVE){ VMVal cg; if(class_subscript(obj,idx,cg)){ push(std::move(cg)); break; } }
                push(get_sub(obj,idx)); break;
            }
            case Op::STORE_SUBSCR:{
                VMVal idx=pop(),obj=pop(),val=pop();
                if(ins.arg==1&&obj.type==VMType::INSTANCE) idx=make_slice_object(idx);
                else if(obj.type!=VMType::INSTANCE&&idx.type==VMType::INSTANCE&&nyrt::shown_class_name(idx.class_name)=="slice")
                    idx=VMVal::make_list(slice_parts(idx));
                if(obj.type==VMType::INSTANCE){bool f=false;call_dunder_f(obj,"__setitem__",{idx,val},f);if(f) break;
                    throw_exception(make_exception("TypeError",{VMVal::make_str("'"+obj.class_name+"' object does not support item assignment")}));}
                set_sub(obj,idx,std::move(val)); break;
            }
            case Op::DELETE_SUBSCR: {
                VMVal key=pop(), obj=pop();
                if(ins.arg==1&&obj.type==VMType::INSTANCE) key=make_slice_object(key);
                else if(obj.type!=VMType::INSTANCE&&key.type==VMType::INSTANCE&&nyrt::shown_class_name(key.class_name)=="slice")
                    key=VMVal::make_list(slice_parts(key));
                if(obj.type==VMType::INSTANCE){
                    bool f=false; call_dunder_f(obj,"__delitem__",{key},f);
                    if(f) break;
                    throw_exception(make_exception("TypeError",{VMVal::make_str("'"+obj.class_name+"' object doesn't support item deletion")}));
                }
                else if(obj.type==VMType::MAP&&obj.map){
                    if(obj.map->erase(vkey(key))==0) throw_exception(make_exception("KeyError",{key}));   // the key itself (round 77)
                }
                else if(obj.type==VMType::BYTES){
                    if(!obj.b) raise_native_exception("TypeError","'bytes' object doesn't support item deletion");
                    std::string& d=obj.bdata_mut();
                    int64_t len=(int64_t)d.size();
                    if(key.type==VMType::LIST&&key.list&&!key.b){
                        int64_t st,step,n=slice_spec(*key.list,len,st,step);
                        if(n<=0) break;
                        std::vector<bool> gone((size_t)len,false);
                        for(int64_t k=0,i=st;k<n;k++,i+=step) gone[(size_t)i]=true;
                        std::string kept;
                        for(int64_t k=0;k<len;k++) if(!gone[(size_t)k]) kept+=d[(size_t)k];
                        d=std::move(kept);
                        break;
                    }
                    int64_t i=index_of(key,"bytearray");
                    if(i<0) i+=len;
                    if(i<0||i>=len) raise_native_exception("IndexError","bytearray index out of range");
                    d.erase((size_t)i,1);
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
                del_attr(obj, fr.code->names[ins.arg]);
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

            // Arithmetic. Objects first: the left operand's dunder, else
            // the right operand's reflected one (__add__, then __radd__ -
            // so sum() of objects and 5 + v work); then Python's numeric
            // and sequence semantics (binop, shared with the interpreter).
            case Op::BINARY_ADD: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(lv,r,"__add__","__radd__",res)){ push(std::move(res)); break; } }
                // A string joined with an instance takes str(instance).
                if(r.type==VMType::INSTANCE&&lv.type==VMType::STRING) r=VMVal::make_str(vm_str(r));
                if(lv.type==VMType::INSTANCE&&r.type==VMType::STRING) lv=VMVal::make_str(vm_str(lv));
                if(lv.type==VMType::INT&&r.type==VMType::INT&&lv.s.empty()&&r.s.empty()){
                    int64_t sum; if(!nypy::add_ovf(lv.i,r.i,sum)){ push(VMVal::make_int(sum)); break; }
                }
                push(binop(nypy::A_ADD,lv,r)); break; }
            case Op::BINARY_SUB: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(lv,r,"__sub__","__rsub__",res)){ push(std::move(res)); break; } }
                push(binop(nypy::A_SUB,lv,r)); break; }
            case Op::BINARY_MUL: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(lv,r,"__mul__","__rmul__",res)){ push(std::move(res)); break; } }
                push(binop(nypy::A_MUL,lv,r)); break; }
            case Op::BINARY_MATMUL: { VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(l,r,"__matmul__","__rmatmul__",res)){ push(std::move(res)); break; } }
                throw_exception(make_exception("TypeError",{VMVal::make_str("unsupported operand type(s) for @")}));
                break; }
            case Op::BINARY_DIV: case Op::BINARY_MOD: case Op::BINARY_POW: case Op::BINARY_FLOOR_DIV:
            case Op::BINARY_AND: case Op::BINARY_OR: case Op::BINARY_XOR: case Op::BINARY_LSHIFT: case Op::BINARY_RSHIFT: {
                VMVal r=pop(),l=pop();
                int aop; const char* dunder; const char* rdunder;
                switch(ins.op){
                    case Op::BINARY_DIV: aop=nypy::A_DIV; dunder="__truediv__"; rdunder="__rtruediv__"; break;
                    case Op::BINARY_MOD: aop=nypy::A_MOD; dunder="__mod__"; rdunder="__rmod__"; break;
                    case Op::BINARY_POW: aop=nypy::A_POW; dunder="__pow__"; rdunder="__rpow__"; break;
                    case Op::BINARY_FLOOR_DIV: aop=nypy::A_FLOORDIV; dunder="__floordiv__"; rdunder="__rfloordiv__"; break;
                    case Op::BINARY_AND: aop=nypy::A_AND; dunder="__and__"; rdunder="__rand__"; break;
                    case Op::BINARY_OR: aop=nypy::A_OR; dunder="__or__"; rdunder="__ror__"; break;
                    case Op::BINARY_XOR: aop=nypy::A_XOR; dunder="__xor__"; rdunder="__rxor__"; break;
                    case Op::BINARY_LSHIFT: aop=nypy::A_LSHIFT; dunder="__lshift__"; rdunder="__rlshift__"; break;
                    default: aop=nypy::A_RSHIFT; dunder="__rshift__"; rdunder="__rrshift__"; break;
                }
                if(l.type==VMType::INSTANCE||r.type==VMType::INSTANCE){
                    VMVal res;
                    if(binary_dunder(l,r,dunder,rdunder,res)){ push(std::move(res)); break; }
                    if(aop==nypy::A_DIV && binary_dunder(l,r,"__div__","__rdiv__",res)){ push(std::move(res)); break; }
                }
                // int | None, Foo | Bar: a union type (PEP 604, round 77)
                if(aop==nypy::A_OR&&is_type_operand(l)&&is_type_operand(r)){
                    std::vector<VMVal> a{l, r};
                    push(vm_call(load_var("_ny_union"), a, std::nullopt, nullptr)); break;
                }
                push(binop(aop,l,r)); break; }
            // Compares
            case Op::COMPARE_EQ: { VMVal r=pop(),lv=pop();
                // an object's __eq__ result as it is (a numpy-style
                // elementwise == stays an object); identity when declined
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){
                    VMVal res;
                    if(rich_compare(lv,r,"__eq__","__eq__",res)){ push(std::move(res)); break; }
                    push(VMVal::make_bool(op_is(lv,r))); break;
                }
                push(VMVal::make_bool(vm_eq(lv,r))); break; }
            case Op::COMPARE_NE: { VMVal r=pop(),lv=pop();
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){
                    VMVal res;
                    if(rich_compare(lv,r,"__ne__","__ne__",res)){ push(std::move(res)); break; }
                    if(rich_compare(lv,r,"__eq__","__eq__",res)){ push(VMVal::make_bool(!vm_truthy(res))); break; }
                    push(VMVal::make_bool(!op_is(lv,r))); break;
                }
                push(VMVal::make_bool(vm_ne(lv,r))); break; }
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
                if(lv.is_set()&&r.is_set()){ push(VMVal::make_bool(lv.list->size()<r.list->size()&&set_subset(lv,r))); break; }
                if((lv.type==VMType::BYTES)!=(r.type==VMType::BYTES)&&lv.type!=VMType::INSTANCE&&r.type!=VMType::INSTANCE)
                    raise_native_exception("TypeError","'<' not supported between instances of '"+vm_type_name(lv)+"' and '"+vm_type_name(r)+"'");
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(rich_compare(lv,r,"__lt__","__gt__",res)){ push(std::move(res)); break; } order_unsupported("<",lv,r); }
                order_check("<",lv,r);   // round 77
                push(VMVal::make_bool(lv.type==VMType::LIST&&r.type==VMType::LIST ? cmp_val(lv,r)<0 : lv<r)); break;
            }
            case Op::COMPARE_LE: {
                VMVal r=pop(),lv=pop();
                if(lv.is_set()&&r.is_set()){ push(VMVal::make_bool(set_subset(lv,r))); break; }
                if((lv.type==VMType::BYTES)!=(r.type==VMType::BYTES)&&lv.type!=VMType::INSTANCE&&r.type!=VMType::INSTANCE)
                    raise_native_exception("TypeError","'<=' not supported between instances of '"+vm_type_name(lv)+"' and '"+vm_type_name(r)+"'");
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(rich_compare(lv,r,"__le__","__ge__",res)){ push(std::move(res)); break; } order_unsupported("<=",lv,r); }
                order_check("<=",lv,r);   // round 77
                push(VMVal::make_bool(lv.type==VMType::LIST&&r.type==VMType::LIST ? cmp_val(lv,r)<=0 : lv<=r)); break;
            }
            case Op::COMPARE_GT: {
                VMVal r=pop(),lv=pop();
                if(lv.is_set()&&r.is_set()){ push(VMVal::make_bool(lv.list->size()>r.list->size()&&set_subset(r,lv))); break; }
                if((lv.type==VMType::BYTES)!=(r.type==VMType::BYTES)&&lv.type!=VMType::INSTANCE&&r.type!=VMType::INSTANCE)
                    raise_native_exception("TypeError","'>' not supported between instances of '"+vm_type_name(lv)+"' and '"+vm_type_name(r)+"'");
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(rich_compare(lv,r,"__gt__","__lt__",res)){ push(std::move(res)); break; } order_unsupported(">",lv,r); }
                order_check(">",lv,r);   // round 77
                push(VMVal::make_bool(lv.type==VMType::LIST&&r.type==VMType::LIST ? cmp_val(lv,r)>0 : lv>r)); break;
            }
            case Op::COMPARE_GE: {
                VMVal r=pop(),lv=pop();
                if(lv.is_set()&&r.is_set()){ push(VMVal::make_bool(set_subset(r,lv))); break; }
                if((lv.type==VMType::BYTES)!=(r.type==VMType::BYTES)&&lv.type!=VMType::INSTANCE&&r.type!=VMType::INSTANCE)
                    raise_native_exception("TypeError","'>=' not supported between instances of '"+vm_type_name(lv)+"' and '"+vm_type_name(r)+"'");
                if(lv.type==VMType::INSTANCE||r.type==VMType::INSTANCE){ VMVal res; if(rich_compare(lv,r,"__ge__","__le__",res)){ push(std::move(res)); break; } order_unsupported(">=",lv,r); }
                order_check(">=",lv,r);   // round 77
                push(VMVal::make_bool(lv.type==VMType::LIST&&r.type==VMType::LIST ? cmp_val(lv,r)>=0 : lv>=r)); break;
            }
            case Op::COMPARE_IN:       { VMVal c=pop(),it=pop(); push(VMVal::make_bool(op_in(it,c))); break; }
            case Op::COMPARE_NOT_IN:   { VMVal c=pop(),it=pop(); push(VMVal::make_bool(!op_in(it,c))); break; }
            case Op::COMPARE_IS:       { VMVal r=pop(),l=pop(); push(VMVal::make_bool(op_is(l,r))); break; }
            case Op::COMPARE_IS_NOT:   { VMVal r=pop(),l=pop(); push(VMVal::make_bool(!op_is(l,r))); break; }
            case Op::COMPARE_IS_TYPE:
            case Op::COMPARE_IS_NOT_TYPE: {
                VMVal t=pop(),v=pop();
                bool r;
                VMVal named;
                if(v.type==VMType::CLASS||!v.builtin_type_name().empty()){
                    // a type on the left (type(x) is int, C is C): identity,
                    // as Python - a class is not an instance of itself
                    VMVal rv;
                    bool have=false;
                    try{ rv=load_var(t.s); have=true; }catch(...){}
                    if(have&&(rv.type==VMType::CLASS||!rv.builtin_type_name().empty())){
                        r=v==rv;
                        push(VMVal::make_bool(ins.op==Op::COMPARE_IS_TYPE ? r : !r)); break;
                    }
                }
                if(ins.arg==1 && (named=load_var(t.s)).type!=VMType::NONE && named.type!=VMType::CLASS
                   && named.type!=VMType::UNDEFINED)
                    r=op_is(v,named);          // an ordinary value: identity
                else
                    r=value_is_type(v,t.s);
                push(VMVal::make_bool(ins.op==Op::COMPARE_IS_TYPE ? r : !r)); break;
            }
            // Unary
            case Op::UNARY_NEG: {
                VMVal v=pop();
                nypy::NumV nv;
                if(v.to_numv(nv)) push(VMVal::from_numv(nypy::num_neg(nv)));
                else if(v.type==VMType::INSTANCE) push(unary_dunder(v,"__neg__","-"));
                else throw_exception(make_exception("TypeError",{VMVal::make_str("bad operand type for unary -")}));
                break;
            }
            // not: Python truthiness, including __bool__ / __len__.
            case Op::UNARY_NOT:    { VMVal v=pop(); push(VMVal::make_bool(!vm_truthy(v))); break; }
            case Op::UNARY_BITNOT: { VMVal v=pop(); nypy::NumV nv;
                if(v.to_numv(nv)){ push(nycall([&]{ return VMVal::from_numv(nypy::num_invert(nv)); })); break; }
                if(v.type==VMType::INSTANCE){ push(unary_dunder(v,"__invert__","~")); break; }
                throw_exception(make_exception("TypeError",{VMVal::make_str("bad operand type for unary ~")}));
                break; }
            case Op::UNARY_POS:
                if(!stack_.empty()&&stack_.back().type==VMType::BOOL) stack_.back()=VMVal::make_int(stack_.back().b?1:0);
                else if(!stack_.empty()&&stack_.back().type==VMType::INSTANCE){ VMVal v=pop(); push(unary_dunder(v,"__pos__","+")); }
                break;

            // Jumps
            case Op::JUMP_FORWARD:         fr.ip=ins.arg; break;
            case Op::JUMP_ABSOLUTE:
                nyconc::tick();
                // a signal's handler runs between iterations (round 77)
                if(__builtin_expect(nyconc::signal_pending(),0)&&signal_hook_) signal_hook_();
                fr.ip=ins.arg; break;
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
            case Op::JUMP_IF_FALSE_OR_POP: { VMVal t=peek(); if(!vm_truthy(t)) fr.ip=ins.arg; else pop(); break; }
            case Op::JUMP_IF_NONE_KEEP:
                if(!stack_.empty()&&stack_.back().is_nullish()){ stack_.back()=VMVal::make_none(); fr.ip=ins.arg; }
                break;
            case Op::JUMP_IF_MISSING_KEEP:
                if(!stack_.empty()&&stack_.back().is_absent_marker()){ stack_.back()=VMVal::make_none(); fr.ip=ins.arg; }
                break;
            case Op::JUMP_IF_NOT_NONE_OR_POP:
                if(!stack_.empty()&&!stack_.back().is_nullish()) fr.ip=ins.arg; else pop();
                break;
            case Op::JUMP_IF_TRUE_OR_POP:  { VMVal t=peek(); if(vm_truthy(t))  fr.ip=ins.arg; else pop(); break; }

            // Make function/class
            case Op::MAKE_FUNCTION: {
                int fn_idx = ins.arg & 0xFFFF;
                int n_defs = (ins.arg >> 16) & 0xFF;
                // Defaults were pushed in parameter order, last on top.
                std::vector<VMVal> defs(n_defs);
                for(int i=n_defs-1;i>=0;i--) defs[i]=pop();
                auto fn_val = VMVal::make_func(fr.code->sub_codes[fn_idx]);
                if(n_defs>0 && fn_val.code){
                    auto& fc=*fn_val.code;
                    auto d=std::make_shared<std::vector<VMVal>>(fc.param_defaults);
                    vmgc::track_list(d);
                    d->resize(fc.param_names.size(), VMVal{VMType::UNDEFINED});
                    for(int i=0;i<n_defs && i<(int)fc.default_idx.size();i++){
                        int pi=fc.default_idx[i];
                        if(pi>=0 && pi<(int)d->size()) (*d)[pi]=defs[i];
                    }
                    fn_val.list=d;   // this function value's own defaults
                }
                // Capture enclosing locals as closure environment ONLY when inside a function
                bool in_function = (fr.code->name != "<module>" && !fr.code->is_class);
                if(in_function){
                    // The frame's own environment (made on its first closure),
                    // shared by every closure it makes: one cell per variable.
                    // A closure made inside a method sees its `self`.
                    ensure_own_env(fr);
                    fn_val.closure_env = fr.closure_env;
                }
                if(!fn_val.closure_env && fr.closure_env && !fr.closure_env->empty()){
                    fn_val.closure_env = fr.closure_env;
                }
                push(std::move(fn_val)); break;
            }
            case Op::MAKE_CLASS: {
                bool extras=(ins.arg>>24)&1;
                VMVal ex_bases, ex_kw;
                if(extras){ ex_bases=pop(); ex_kw=pop(); }
                auto sub=fr.code->sub_codes[ins.arg&0xFFFFFF];
                // Each run of a class statement makes a new class (round 77;
                // a factory's second call rebound the first one's class): a
                // re-run is a copy registered as "Name#n", shown as Name.
                if(class_ran_.count(sub.get())){
                    auto copy=std::make_shared<VMCode>(*sub);
                    copy->name=sub->name+"#"+std::to_string(++class_generation_);
                    // its methods are owned by it (super() starts from the
                    // method's owner_class)
                    for(auto& sc:copy->sub_codes){
                        if(sc&&sc->owner_class==sub->name){
                            auto m=std::make_shared<VMCode>(*sc);
                            m->owner_class=copy->name;
                            sc=m;
                        }
                    }
                    sub=copy;
                } else {
                    class_ran_[sub.get()]=sub;
                    // expression bases are resolved below: the statement's own
                    // code keeps its placeholders for the next run
                    if(extras) sub=std::make_shared<VMCode>(*sub);
                }
                VMVal orig_bases=extras?resolve_expr_bases(*sub, ex_bases):VMVal::make_none();
                // Bases are looked up in scope (NythonExecutor::evalClassDecl)
                for(auto& b:sub->bases){
                    // A module's own base is already "module.Class" (the
                    // parser qualified it): keep it.
                    if(b.find('.')!=std::string::npos&&class_reg_.count(b)) continue;
                    // A class bound in scope under that name: that class.
                    if(b.find('.')==std::string::npos){
                        VMVal bv=load_var(nyrt::shown_class_name(b));
                        if(bv.type==VMType::CLASS){
                            std::string full=bv.class_name.empty()?bv.s:bv.class_name;
                            if(!full.empty()&&class_reg_.count(full)){ b=full; continue; }
                        }
                    }
                    std::string rn=exc_class_name(b);
                    if(rn!=b && (class_reg_.count(rn) || nython::ny_is_builtin_exc(rn))) b=rn;
                }
                if(!sub->bases.empty()) sub->parent_class=sub->bases[0];
                class_reg_[sub->name]=sub;
                mro_cache_.clear();
                attr_hook_cache_[0].clear();
                attr_hook_cache_[1].clear();
                has_del_cache_.clear();
                no_new_.clear();
                class_vars_[sub->name]=run_class_body(sub, fr);
                if(orig_bases.type!=VMType::NONE) class_vars_[sub->name]["__orig_bases__"]=orig_bases;   // round 77
                if(is_exception_class(sub->name)) note_exc_class(sub->name);   // with its kind (round 77)
                else vm_exc_classes().erase(sub->name);
                {
                    VMVal clsv=VMVal::make_class(sub,sub->name);
                    VMVal kw=VMVal::make_map();
                    if(extras&&ex_kw.type==VMType::MAP&&ex_kw.map)
                        for(auto& kv:*ex_kw.map){
                            if(kv.first=="metaclass") class_meta_[sub->name]=kv.second;
                            else (*kw.map)[kv.first]=kv.second;
                        }
                    VMVal meta=metaclass_of(sub->name);
                    if(meta.type==VMType::CLASS) push(run_metaclass(meta, clsv, *sub, kw));
                    else { class_created(clsv, kw); push(clsv); }
                }
                break;
            }

            // Calls
            case Op::CALL_KW: {
                // Stack: callee (or obj, "name" for a method call), the
                // positional arguments, then a MAP of the keyword arguments.
                // arg = number of positionals + 1; arg < 0 marks a method call.
                bool method_mode = ins.arg < 0;
                int total = method_mode ? -ins.arg : ins.arg;
                std::vector<VMVal> all_args(total);
                for(int i=total-1;i>=0;i--) all_args[i]=pop();
                VMVal kwargs_map=all_args.back(); all_args.pop_back();
                if(method_mode){
                    VMVal mname=pop(); VMVal obj=pop();
                    push(vm_call_method(obj,mname.s,all_args,&kwargs_map));
                } else {
                    VMVal callee=pop();
                    push(vm_call(callee,all_args,std::nullopt,&kwargs_map));
                }
                break;
            }
            case Op::LIST_EXTEND: {
                // TOS = iterable to extend with; TOS1 = list to extend
                VMVal ext=pop();
                // *x over any iterable (a generator, a string, an object),
                // not only a list.
                std::vector<VMVal> items;
                if(ext.type!=VMType::LIST) items=iter_items(ext);
                VMVal& lst=stack_.back();
                if(lst.type==VMType::LIST&&lst.list){
                    if(ext.type==VMType::LIST&&ext.list)
                        for(auto& v:*ext.list) lst.list->push_back(v);
                    else for(auto& v:items) lst.list->push_back(v);
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
                // 2: the positionals list, then a map of the keywords.
                VMVal ex_kw; bool has_ex_kw=false;
                if(n_pushed==2){ ex_kw=pop(); has_ex_kw=true; n_pushed=1; }
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
                    push(vm_call_method(obj,mname.s,args,has_ex_kw?&ex_kw:nullptr));
                } else {
                    VMVal callee=pop();
                    push(vm_call(callee,args,std::nullopt,has_ex_kw?&ex_kw:nullptr));
                }
                break;
            }
            case Op::MAP_MERGE: {
                VMVal src=pop(); VMVal& dst=stack_.back();
                if(src.type!=VMType::MAP||!src.map)
                    throw_exception(make_exception("TypeError",{VMVal::make_str("argument after ** must be a mapping")}));
                if(dst.type==VMType::MAP&&dst.map)
                    for(auto& kv:*src.map) (*dst.map)[kv.first]=kv.second;
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
                    GenState& gs=*cfr.gen_state;
                    gs.ip=cfr.ip;   // ip points past YIELD_VALUE
                    // Moved, not copied: the frame is popped right after.
                    gs.locals=std::move(cfr.locals); gs.closure=cfr.closure_env; gs.own_env=cfr.own_env;
                    // Save stack slice above stack_base (holds loop iterators etc.)
                    size_t base=gs.stack_base;
                    gs.saved_stack.clear();
                    if(stack_.size() > base){
                        gs.saved_stack.assign(std::make_move_iterator(stack_.begin()+base), std::make_move_iterator(stack_.end()));
                        stack_.resize(base);
                    }
                    gs.yielded=true;
                    gs.at_yield=true;
                    gs.in_yield_from=false;
                    return yv;
                }
                throw VMYield{yv};
            }

            // yield from it: delegates next/send/throw/close to the iterator
            // (PEP 380) and evaluates to the subgenerator's return value. It
            // pauses AT this instruction with the iterator on the saved stack;
            // resuming runs it again with the resume request in the GenState.
            case Op::YIELD_FROM_OP: {
                auto& cfr=call_stack_.back();
                std::shared_ptr<GenState> gsp=cfr.gen_state;
                VMVal it=pop();
                if(!gsp) throw_exception(make_exception("SyntaxError",{VMVal::make_str("'yield from' outside function")}));
                GenState& gs=*gsp;
                int mode=0;
                VMVal sent, exc;
                if(!gs.in_yield_from) it=vm_iter_open(it);
                else {
                    mode=gs.mode; sent=gs.sent; exc=gs.pending;
                    gs.sent=VMVal::make_none(); gs.pending=VMVal::make_none();
                    gs.in_yield_from=false;
                    if(mode==1 && exc.type==VMType::INSTANCE && class_derives(exc.class_name,"GeneratorExit")) mode=2;
                }
                if(mode==2){
                    // The subiterator is closed first, then GeneratorExit is
                    // raised here.
                    if(it.type==VMType::GENERATOR&&it.gen) gen_close(*it.gen);
                    else if(it.type==VMType::INSTANCE){ bool f=false; call_dunder_f(it,"close",{},f); }
                    throw_exception(exc.type==VMType::INSTANCE?exc:make_exception("GeneratorExit",{}));
                }
                VMVal v, result;
                bool got=false;
                if(it.type==VMType::GENERATOR&&it.gen){
                    GenState& sub=*it.gen;
                    if(mode==1){
                        if(sub.done||!sub.started){ if(!sub.started) gen_finish(sub); throw_exception(exc); }
                        got=gen_resume(sub,1,exc,v);
                    } else got=gen_resume(sub,0,sent,v);
                    if(!got){ result=sub.retval; sub.retval=VMVal::make_none(); }
                } else if(mode==1){
                    VMVal m;
                    if(it.type!=VMType::INSTANCE||!class_lookup(it.class_name,"throw",m)) throw_exception(exc);
                    try { v=call_dunder(it,"throw",{exc}); got=true; }
                    catch(VMException& e){
                        if(!is_stop_iteration(e.value)) throw;
                        if(e.value.type==VMType::INSTANCE&&e.value.map&&e.value.map->count("value")) result=(*e.value.map)["value"];
                    }
                } else if(it.type==VMType::INSTANCE){
                    VMVal m;
                    bool use_send = sent.type!=VMType::NONE && class_lookup(it.class_name,"send",m);
                    try { v = use_send ? call_dunder(it,"send",{sent}) : call_dunder(it,"__next__",{}); got=true; }
                    catch(VMException& e){
                        if(!is_stop_iteration(e.value)) throw;
                        if(e.value.type==VMType::INSTANCE&&e.value.map&&e.value.map->count("value")) result=(*e.value.map)["value"];
                    }
                } else got=vm_iter_step(it,v);
                if(!got){ push(result); break; }   // the value of `yield from`
                // Pass v up; pause here with the iterator saved.
                gs.ip=cfr.ip-1;
                gs.locals=std::move(cfr.locals); gs.closure=cfr.closure_env; gs.own_env=cfr.own_env;
                push(std::move(it));
                size_t base=gs.stack_base;
                gs.saved_stack.clear();
                if(stack_.size()>base){
                    gs.saved_stack.assign(std::make_move_iterator(stack_.begin()+base), std::make_move_iterator(stack_.end()));
                    stack_.resize(base);
                }
                gs.yielded=true;
                gs.at_yield=false;
                gs.in_yield_from=true;
                return v;
            }

            // Iteration
            case Op::GET_ITER: {
                VMVal it=pop();
                if(it.type==VMType::CLASS&&!class_meta_.empty()){
                    // a class whose metaclass defines __iter__ (round 77)
                    VMVal r;
                    if(meta_call(it,"__iter__",{},r)){
                        if(r.type==VMType::LIST&&r.list){ std::vector<VMVal> c=*r.list; push(VMVal::make_iter(std::move(c))); }
                        else push(r);
                        break;
                    }
                }
                if(it.type==VMType::GENERATOR){push(it);break;}
                if(it.type==VMType::ITERATOR){push(it);break;}
                if(it.type==VMType::INSTANCE){
                    // __iter__'s result; else the object itself when it has
                    // __next__; else a __getitem__ sequence, indexed from 0.
                    bool f=false;
                    VMVal iter_res=call_dunder_f(it,"__iter__",{},f);
                    if(f){
                        if(iter_res.type==VMType::LIST&&iter_res.list){ std::vector<VMVal> c=*iter_res.list; push(VMVal::make_iter(std::move(c))); }
                        else push(iter_res);
                        break;
                    }
                    VMVal nx;
                    if(class_lookup(it.class_name,"__next__",nx)){ push(it); break; }
                    push(VMVal::make_iter(iter_items(it))); break;
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
                    bool stop_iter=false, found=false;
                    // Only StopIteration ends the loop: any other exception
                    // raised by __next__ propagates (it used to end the loop
                    // silently, as did a __next__ that returned none).
                    try { nv=call_dunder_f(it_copy,"__next__",{},found); }
                    catch(VMException& e){ if(is_stop_iteration(e.value)) stop_iter=true; else throw; }
                    if(!stop_iter && !found)
                        throw_exception(make_exception("TypeError",{VMVal::make_str("'"+it_copy.class_name+"' object is not an iterator")}));
                    if(stop_iter){ pop(); fr.ip=ins.arg; break; }
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
                auto str_of=[&](const VMVal& v)->std::string{ return vm_str(v); };
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
                {
                    // sys.stdout replaced (contextlib.redirect_stdout, a
                    // StringIO): the line goes to its write(), as Python's
                    VMVal target;
                    if(stdout_redirected(target)){
                        std::vector<VMVal> wa{VMVal::make_str(out+end)};
                        vm_call_method(target,"write",wa);
                        break;
                    }
                }
                std::cout<<out<<end;
                if(end!="\n") std::cout.flush();
                break;
            }
            case Op::IMPORT_NAME: vm_import(fr.code->names[ins.arg]); break;

            // Exception handling
            case Op::RAISE:
                throw_exception(pop());
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
                // arg 0: raise X   1: bare raise (re-raise)   2: raise X from Y
                // 3: bare raise of what a caller's except clause handles (round 77)
                if(ins.arg==3){
                    VMVal cur=pop();
                    if(cur.type==VMType::NONE) raise_native_exception("RuntimeError","No active exception to reraise");
                    tb_reraise_=true;
                    throw_exception(std::move(cur));
                }
                VMVal cause; if(ins.arg==2) cause=pop();
                VMVal ev=normalize_exception(pop());
                if(ins.arg==2 && ev.type==VMType::INSTANCE && ev.map){
                    (*ev.map)["__cause__"]=cause.type==VMType::NONE?cause:normalize_exception(cause);
                    (*ev.map)["__suppress_context__"]=VMVal::make_bool(true);   // round 77
                }
                // round 77: raised while an except clause handles another,
                // that one is its __context__; a bare raise goes on with the
                // traceback it has (this frame already heads it)
                if(ins.arg==1) tb_reraise_=true;
                else set_exc_context(ev, vm_exc_current());
                throw_exception(std::move(ev));
            }

            // ── try/finally, with (see ExceptionEntry) ─────────────────────
            case Op::FIN_NORMAL: push(make_fin_state(FIN_K_NORMAL)); break;
            case Op::FIN_RETURN: push(make_fin_state(FIN_K_RETURN, pop())); break;
            case Op::FIN_JUMP:   push(make_fin_state(FIN_K_JUMP, VMVal::make_none(), ins.arg)); break;
            case Op::END_FINALLY: {
                VMVal st=pop();
                if(!is_fin_state(st)) break;
                int outer=ins.arg;
                switch((int)st.i){
                case FIN_K_EXC:
                    tb_reraise_=true;   // on its way out still: no second entry for this frame (round 77)
                    throw_exception((*st.list)[0]);
                case FIN_K_RETURN:
                    if(outer>=0){ push(st); fr.ip=fr.code->exc_table[outer].finally_start; break; }
                    return (*st.list)[0];
                case FIN_K_JUMP: {
                    int t=(int)st.d;
                    if(outer>=0){
                        auto& oe=fr.code->exc_table[outer];
                        // Leaving the enclosing try as well: run its finally.
                        if(!(t>=oe.try_start && t<oe.finally_start)){ push(st); fr.ip=oe.finally_start; break; }
                    }
                    fr.ip=t; break;
                }
                default: break;
                }
                break;
            }
            case Op::WITH_ENTER: {
                VMVal cm=pop();
                bool found=false;
                VMVal r=call_dunder_f(cm,"__enter__",{},found);
                // No __enter__: bind the object itself (both engines).
                push(found?r:cm); break;
            }
            case Op::WITH_EXIT: {
                VMVal cm=pop();
                // By index: __exit__ runs code that can grow (reallocate) the
                // operand stack, so no reference into it may be held across.
                size_t st_idx=stack_.size()-1;
                VMVal st=stack_[st_idx];
                if(is_fin_state(st) && st.i==FIN_K_EXC){
                    VMVal exc=(*st.list)[0];
                    bool found=false;
                    VMVal tbv=VMVal::make_none();   // the traceback it has here (round 77)
                    if(exc.type==VMType::INSTANCE&&exc.map){ auto ti=exc.map->find("__traceback__"); if(ti!=exc.map->end()) tbv=ti->second; }
                    VMVal r=call_dunder_f(cm,"__exit__",{class_of_exception(exc),exc,tbv},found);
                    bool truthy = r.type==VMType::INSTANCE ? instance_truthy(r) : r.is_truthy();
                    if(found && truthy) stack_[st_idx]=make_fin_state(FIN_K_NORMAL);
                } else {
                    bool found=false;
                    call_dunder_f(cm,"__exit__",{VMVal::make_none(),VMVal::make_none(),VMVal::make_none()},found);
                }
                break;
            }

            case Op::IADD: {
                VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE){
                    VMVal res=ni_none(call_dunder(l,"__iadd__",{r}));
                    if(res.type!=VMType::NONE){push(res);break;}
                    res=ni_none(call_dunder(l,"__add__",{r}));
                    if(res.type!=VMType::NONE){push(res);break;}
                }
                // 10 += obj: the right operand's __radd__, as for 10 + obj
                // (it raised TypeError)
                if(r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(l,r,"__add__","__radd__",res)){push(res);break;} }
                if(l.type==VMType::INT&&r.type==VMType::INT&&l.s.empty()&&r.s.empty()){
                    int64_t res; if(!nypy::add_ovf(l.i,r.i,res)){ push(VMVal::make_int(res)); break; }
                }
                push(binop_inplace(nypy::A_ADD,l,r)); break;
            }
            case Op::ISUB: { VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE){ VMVal res=ni_none(call_dunder(l,"__isub__",{r})); if(res.type==VMType::NONE) res=ni_none(call_dunder(l,"__sub__",{r})); if(res.type!=VMType::NONE){push(res);break;} }
                if(r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(l,r,"__sub__","__rsub__",res)){push(res);break;} }
                push(binop(nypy::A_SUB,l,r)); break; }
            case Op::IMUL: { VMVal r=pop(),l=pop();
                if(l.type==VMType::INSTANCE){ VMVal res=ni_none(call_dunder(l,"__imul__",{r})); if(res.type==VMType::NONE) res=ni_none(call_dunder(l,"__mul__",{r})); if(res.type!=VMType::NONE){push(res);break;} }
                if(r.type==VMType::INSTANCE){ VMVal res; if(binary_dunder(l,r,"__mul__","__rmul__",res)){push(res);break;} }
                push(binop_inplace(nypy::A_MUL,l,r)); break; }
            case Op::IDIV: { VMVal r=pop(),l=pop(); push(binop(nypy::A_DIV,l,r)); break; }
            case Op::IMOD: { VMVal r=pop(),l=pop(); push(binop(nypy::A_MOD,l,r)); break; }

            default: break;
            } // end switch
            } catch(VMReturn& r) { throw; }  // propagate returns
              catch(VMYield&) { throw; }
              catch(VMException& ex) {
                // round 77: just raised (no traceback yet) while an except
                // clause handles another - its __context__; then the
                // traceback, a frame at a time
                if(ex.value.type==VMType::INSTANCE&&ex.value.map&&!tb_reraise_&&!ex.value.map->count("__traceback__")
                   &&!ex.value.map->count("__context__"))
                    set_exc_context(ex.value, vm_exc_current());
                tb_here(ex.value);
                if(!dispatch_exception(call_stack_.back(), ex.value)) throw;
              }
              catch(std::string& m) {
                // Interpreter builtins reached through the bridge, and a few
                // VM paths, report errors as "__exc__:Type:message" strings.
                VMVal ev=exception_from_message(m);
                set_exc_context(ev, vm_exc_current());
                tb_here(ev);
                if(!dispatch_exception(call_stack_.back(), ev)) throw VMException(ev, describe_exception(ev));
              }
              catch(std::exception& exc) {
                // Runtime errors raised as "Type: message" (ZeroDivisionError
                // from a division, ValueError from int(), ...) become instances
                // of that builtin class, so `except ZeroDivisionError` catches
                // them like any raised exception. Native code that built the
                // instance itself (the tensor and concurrency runtimes, the
                // builtin bridge) leaves it in last_exception_obj_.
                VMVal ev=take_native_exception(exc.what());
                set_exc_context(ev, vm_exc_current());
                tb_here(ev);
                if(!dispatch_exception(call_stack_.back(), ev)) throw VMException(ev, describe_exception(ev));
              }
        }
    }

    // ── Tracebacks (round 77) ────────────────────────────────────────────
    // An exception passing through a frame gets an entry for it at the head
    // of its __traceback__ (CPython's PyTraceBack_Here): a prelude
    // _NyTraceback with tb_next, tb_lineno and the frame's file, function
    // and module in _ny_loc, "\x1f"-separated (its tb_frame is made from
    // them when first read). A bare
    // raise, or an exception leaving a finally on its way out, is already
    // headed by this frame (tb_reraise_). The prelude's frames are not
    // shown (its source is named "stdin"), as CPython shows no frame for a
    // builtin written in C.
    bool tb_reraise_=false;
    std::string frame_module(const CallFrame& f) {
        if(f.code&&f.code->module_env){
            auto it=f.code->module_env->find("__name__");
            if(it!=f.code->module_env->end()&&it->second.type==VMType::STRING) return it->second.s;
        }
        return "__main__";
    }
    static int frame_line(const CallFrame& f) {
        int ip=f.ip-1;
        return (f.code&&ip>=0&&ip<(int)f.code->instructions.size())?f.code->instructions[(size_t)ip].line:0;
    }
    void tb_here(const VMVal& ev) {
        if(tb_reraise_){ tb_reraise_=false; return; }
        if(ev.type!=VMType::INSTANCE||!ev.map||call_stack_.empty()) return;
        const CallFrame& f=call_stack_.back();
        if(!f.code||f.code->file=="stdin") return;
        VMVal next=VMVal::make_none();
        auto it=ev.map->find("__traceback__");
        if(it!=ev.map->end()&&it->second.type==VMType::INSTANCE) next=it->second;
        auto attrs=std::make_shared<VMMap>(); vmgc::track_map(attrs);
        (*attrs)["tb_next"]=next;
        (*attrs)["tb_lineno"]=VMVal::make_int(frame_line(f));
        (*attrs)["_ny_loc"]=VMVal::make_str(f.code->file+'\x1f'+f.code->name+'\x1f'+frame_module(f));
        (*ev.map)["__traceback__"]=VMVal::make_instance("_NyTraceback", attrs);
    }
    // e.__context__ = c, as Python sets it when e is raised while c is being
    // handled - without making a cycle (a link back to e is cut).
    static void set_exc_context(const VMVal& ev, const VMVal& c) {
        if(ev.type!=VMType::INSTANCE||!ev.map||c.type!=VMType::INSTANCE||!c.map||c.map==ev.map) return;
        VMVal o=c;
        for(int guard=0; guard<1000 && o.type==VMType::INSTANCE && o.map; guard++){
            auto it=o.map->find("__context__");
            if(it==o.map->end()||it->second.type!=VMType::INSTANCE) break;
            if(it->second.map==ev.map){ it->second=VMVal::make_none(); break; }
            VMVal nx=it->second;
            o=nx;
        }
        (*ev.map)["__context__"]=c;
    }
    // _ny_stack(): the running frames, innermost first, as (filename,
    // lineno, function name, module name) - the prelude's left out.
    VMVal vm_stack_value() {
        std::vector<VMVal> out;
        for(int i=(int)call_stack_.size()-1;i>=0;i--){
            const CallFrame& f=call_stack_[(size_t)i];
            if(!f.code||f.code->file=="stdin"||f.code->file.empty()) continue;
            out.push_back(VMVal::make_tuple({VMVal::make_str(f.code->file), VMVal::make_int(frame_line(f)),
                                             VMVal::make_str(f.code->name), VMVal::make_str(frame_module(f))}));
        }
        return VMVal::make_list(std::move(out));
    }

    // ── Exceptions ───────────────────────────────────────────────────────
    // Finds the handler for `ev` raised at the current instruction of `f`:
    // the innermost try whose body covers it and has a matching clause, or
    // whose body/handlers cover it and has a finally. Truncates the operand
    // stack to that statement's depth, pushes the exception (or, for a
    // finally, its pending-exception state) and jumps there.
    bool dispatch_exception(CallFrame& f, const VMVal& ev) {
        if(!f.code) return false;
        int ip=f.ip-1;
        auto& tbl=f.code->exc_table;
        if(tbl.empty()) return false;
        // Leaving an except clause by an exception: it no longer handles its
        // own (round 77).
        for(auto& e:tbl)
            if(!e.held.empty() && ip>=e.try_end && ip<e.end){
                auto hv=f.locals.find(e.held);
                if(hv!=f.locals.end()) hv->second=VMVal::make_none();
                if(f.own_env&&f.closure_env){ auto he=f.closure_env->find(e.held); if(he!=f.closure_env->end()) he->second=VMVal::make_none(); }
                if(f.code->module_top&&f.code->module_env){ auto hm=f.code->module_env->find(e.held); if(hm!=f.code->module_env->end()) hm->second=VMVal::make_none(); }
            }
        std::vector<int> cands;
        for(int i=0;i<(int)tbl.size();i++){
            auto& e=tbl[i];
            bool in_body = ip>=e.try_start && ip<e.try_end;
            bool in_rest = e.finally_start>=0 && ip>=e.try_end && ip<e.finally_start;
            if(in_body||in_rest) cands.push_back(i);
        }
        // Innermost first. Nested statements can start at the same offset
        // (a try whose first statement is a try); the inner one's entry was
        // created later, so the higher index wins a tie.
        std::sort(cands.begin(),cands.end(),[&](int a,int b){
            if(tbl[a].try_start!=tbl[b].try_start) return tbl[a].try_start>tbl[b].try_start;
            return a>b; });
        for(int i:cands){
            auto& e=tbl[i];
            size_t want=f.stack_base+(size_t)e.depth;
            if(ip>=e.try_start && ip<e.try_end){
                int h=match_except_handler(e, ev);
                if(h>=0){
                    if(stack_.size()>want) stack_.resize(want);
                    push(ev); f.ip=h; return true;
                }
            }
            if(e.finally_start>=0){
                if(stack_.size()>want) stack_.resize(want);
                push(make_fin_state(FIN_K_EXC, ev)); f.ip=e.finally_start; return true;
            }
        }
        return false;
    }
    [[noreturn]] void throw_exception(VMVal ev) {
        std::string what=describe_exception(ev);
        throw VMException(std::move(ev), what);
    }
    // The uncaught form: "Type: message" (just "Type" without a message).
    std::string describe_exception(const VMVal& ev) {
        if(ev.type==VMType::INSTANCE){
            std::string m=exception_str(ev);
            return m.empty()?ev.class_name:ev.class_name+": "+m;
        }
        return ev.to_string();
    }
    // str(e): the class's own __str__ when it has one, else the message.
    std::string exception_str(const VMVal& ev) {
        if(ev.type==VMType::INSTANCE){
            bool found=false;
            VMVal r=call_dunder_f(ev,"__str__",{},found);
            if(found) return r.to_string();
        }
        return ev.to_string();
    }
    // Registers class `cn` as an exception class, with the kind of fields
    // its str() is made from (round 77).
    void note_exc_class(const std::string& cn) {
        vm_exc_classes().insert(cn);
        vm_exc_kinds()[cn]=nython::ny_exc_kind([&](const char* b){ return class_derives(cn,b); });
    }
    // An exception's args from its constructor's or super().__init__'s
    // arguments, and the fields some classes make of them (round 77, as the
    // interpreter's setExceptionArgs): OSError(errno, strerror[, filename[,
    // winerror[, filename2]]]) - args then (errno, strerror) -, the Unicode
    // errors' encoding/object/start/end/reason, StopIteration.value,
    // SystemExit.code. A field the arguments do not give keeps what it had
    // (None at first). No legacy `msg`: super().__init__ overwrote the one a
    // subclass's __init__ had computed.
    void set_exc_args(VMMap& attrs, const std::string& cls, const std::vector<VMVal>& args) {
        int kind=vm_exc_kinds().count(cls)?vm_exc_kind_of(cls):nython::ny_exc_kind([&](const char* b){ return class_derives(cls,b); });
        auto field=[&](const char* k, const VMVal& v, bool given){
            if(given||!attrs.count(k)) attrs[k]=given?v:VMVal::make_none();
        };
        std::vector<VMVal> a=args;
        if(kind==nython::NYX_OS){
            bool p=args.size()>=2&&args.size()<=5;
            VMVal none=VMVal::make_none();
            field("errno", p?args[0]:none, p);
            field("strerror", p?args[1]:none, p);
            field("filename", p&&args.size()>=3?args[2]:none, p);
            field("filename2", p&&args.size()==5?args[4]:none, p);
            if(p&&args.size()>=3&&args[2].type!=VMType::NONE) a.resize(2);
        } else if(nython::ny_exc_kind_unicode(kind)){
            bool tr=kind==nython::NYX_UTRANSLATE;
            bool p=args.size()==(tr?4u:5u);
            size_t o=tr?0:1;
            VMVal none=VMVal::make_none();
            field("encoding", p&&!tr?args[0]:none, p);
            field("object", p?args[o]:none, p);
            field("start", p?args[o+1]:none, p);
            field("end", p?args[o+2]:none, p);
            field("reason", p?args[o+3]:none, p);
        } else if(kind==nython::NYX_SYNTAX){
            // SyntaxError(msg, (filename, lineno, offset, text[, end_lineno, end_offset]))
            VMVal none=VMVal::make_none();
            field("msg", args.empty()?none:args[0], !args.empty());
            std::vector<VMVal> info;
            if(args.size()==2&&args[1].type==VMType::LIST&&!args[1].is_set()&&args[1].list&&args[1].list->size()>=4&&args[1].list->size()<=6) info=*args[1].list;
            for(int i=0;i<6;i++) field(nython::ny_syntax_fields()[i], i<(int)info.size()?info[(size_t)i]:none, !info.empty());
        } else if(kind==nython::NYX_IMPORT){
            field("msg", args.size()==1?args[0]:VMVal::make_none(), args.size()==1);
        }
        // StopIteration.value: a generator's return value (both engines).
        if(class_derives(cls,"StopIteration")) attrs["value"]=args.empty()?VMVal::make_none():args[0];
        if(class_derives(cls,"SystemExit")) attrs["code"]=args.empty()?VMVal::make_none():args.size()==1?args[0]:VMVal::make_tuple(args);
        attrs["args"]=VMVal::make_tuple(std::move(a));
    }
    // The arguments of a builtin exception made from a runtime error's
    // message (round 77, NythonExecutor::excArgsFromMessage): an OSError's
    // errno and filenames, a codec error's fields, a KeyError's key.
    std::vector<VMVal> exc_args_from_message(const std::string& type, const std::string& msg) {
        int kind=nython::ny_exc_kind([&](const char* b){ return class_derives(type,b); });
        if(kind==nython::NYX_OS){
            nython::NyErrnoParts ep;
            if(nython::ny_parse_errno_message(msg, ep)){
                std::vector<VMVal> a{VMVal::make_int((int64_t)ep.err), VMVal::make_str(ep.strerror)};
                if(ep.has_f1) a.push_back(VMVal::make_str(ep.f1));
                if(ep.has_f2){ a.push_back(VMVal::make_none()); a.push_back(VMVal::make_str(ep.f2)); }
                return a;
            }
        } else if(kind==nython::NYX_UDECODE||kind==nython::NYX_UENCODE){
            const nypy::UnicodeErrInfo& ui=nypy::last_unicode_error();
            if(ui.msg==msg&&ui.is_str==(kind==nython::NYX_UENCODE))
                return {VMVal::make_str(ui.encoding), ui.is_str?VMVal::make_str(ui.object):VMVal::make_bytes(ui.object,false),
                        VMVal::make_int(ui.start), VMVal::make_int(ui.end), VMVal::make_str(ui.reason)};
        } else if(kind==nython::NYX_KEY){
            std::string k; size_t i=0;
            if(nython::ny_unquote_py(msg,i,k)&&i==msg.size()) return {VMVal::make_str(k)};
            size_t d=msg.size()>1&&msg[0]=='-'?1:0;
            if(msg.size()>d&&msg.size()<19&&msg.find_first_not_of("0123456789",d)==std::string::npos)
                return {VMVal::make_int((int64_t)std::stoll(msg))};
        }
        return {VMVal::make_str(msg)};
    }
    // A new instance of builtin exception class `type` with the given args.
    VMVal make_exception(const std::string& type, std::vector<VMVal> args) {
        if(!class_reg_.count(type)) vm_exc_classes().insert(type);
        auto attrs=std::make_shared<VMMap>(); vmgc::track_map(attrs);
        set_exc_args(*attrs, type, args);
        return VMVal::make_instance(type, attrs);
    }
    // The exception a native raised as last_exception_obj_ + a "Type: msg"
    // runtime_error, when the two agree; else one made from the message.
    VMVal take_native_exception(const std::string& what) {
        if(last_exception_obj_.type==VMType::INSTANCE){
            VMVal ev=last_exception_obj_;
            last_exception_obj_=VMVal::make_none();
            const std::string& cn=ev.class_name;
            if(what.compare(0, cn.size(), cn)==0 && (what.size()==cn.size() || what[cn.size()]==':'))
                return ev;
        }
        return exception_from_message(what);
    }
    VMVal exception_from_message(const std::string& m) {
        std::string type, msg;
        if(!nython::ny_split_exc_message(m, type, msg)){ type="Exception"; msg=m; }
        return make_exception(type, exc_args_from_message(type, msg));   // round 77
    }
    // `raise X`: a class is instantiated with no arguments; an instance is
    // raised as is; anything else (Nython lets a string be raised) as well.
    VMVal normalize_exception(VMVal ev) {
        if(ev.type==VMType::CLASS){
            std::vector<VMVal> none_args;
            return vm_call(ev, none_args, std::nullopt);
        }
        return ev;
    }
    VMVal class_of_exception(const VMVal& ev) {
        std::string cn = ev.type==VMType::INSTANCE ? ev.class_name : std::string("Exception");
        auto it=class_reg_.find(cn);
        if(it==class_reg_.end()) return VMVal::make_none();
        return VMVal::make_class(it->second, cn);
    }
    // Whether class `cls` is `want` or derives from it (first base chain,
    // then the builtin exception table).
    bool class_derives(const std::string& cls, const std::string& want) {
        if(cls==want) return true;
        if(cls.empty()) return false;
        if(!class_reg_.count(cls)){
            if(nython::ny_is_builtin_exc(cls)) return nython::ny_builtin_exc_is(cls, want);
            // A typed error from a builtin ("__exc__:SomeError:...") whose
            // class is known to neither table is at least an Exception.
            return vm_exc_classes().count(cls) && (want=="Exception"||want=="BaseException");
        }
        for(auto& c:*class_mro(cls)) if(c==want) return true;
        return false;
    }
    bool is_exception_class(const std::string& cls) { return class_derives(cls, "BaseException"); }
    bool exception_matches(const VMVal& ev, const std::string& t) {
        if(ev.type==VMType::INSTANCE){
            if(t=="Error" && is_exception_class(ev.class_name)
               && !class_derives(ev.class_name,"SystemExit") && !class_derives(ev.class_name,"KeyboardInterrupt")
               && !class_derives(ev.class_name,"GeneratorExit")
               && !class_derives(ev.class_name,"CancelledError")) return true;
            return class_derives(ev.class_name, t);
        }
        // A raised non-exception value (Nython allows `raise "msg"`): the
        // generic names catch it, and a string naming a class matches that
        // class (`raise "StopIteration"`).
        if(t=="Exception"||t=="BaseException"||t=="Error") return true;
        return ev.type==VMType::STRING && ev.s==t;
    }
    bool is_stop_iteration(const VMVal& ev) {
        if(ev.type==VMType::INSTANCE) return class_derives(ev.class_name,"StopIteration");
        return ev.type==VMType::STRING && ev.s.find("StopIteration")!=std::string::npos;
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
            auto map=std::make_shared<VMMap>(); vmgc::track_map(map);
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
            case VMType::LIST: return v.is_set()?(v.is_frozenset()?"frozenset":"set"):v.b?"tuple":"list";
            case VMType::MAP: return "dict";
            case VMType::FUNCTION: return "function";
            case VMType::NATIVE: return "builtin_function_or_method";
            case VMType::CLASS: return "type";
            case VMType::INSTANCE: return nyrt::shown_class_name(v.class_name);
            case VMType::GENERATOR: return "generator";
            case VMType::ITERATOR: return "iterator";
            case VMType::UNDEFINED: return "undefined";
            case VMType::BYTES: return v.b?"bytearray":"bytes";
            default: return "object";
        }
    }
    // bytes / bytearray operands (round 77); false hands the operator back.
    bool bytes_binop(int op, const VMVal& l, const VMVal& r, VMVal& out) {
        bool lb=l.type==VMType::BYTES, rb=r.type==VMType::BYTES;
        if(!lb&&!rb) return false;
        switch(op){
        case nypy::A_ADD:
            if(lb&&rb){ out=VMVal::make_bytes(l.bdata()+r.bdata(),l.b); return true; }
            if(lb) raise_native_exception("TypeError","can't concat "+vm_type_name(r)+" to "+vm_type_name(l));
            if(l.type==VMType::STRING) raise_native_exception("TypeError","can only concatenate str (not \""+vm_type_name(r)+"\") to str");
            raise_native_exception("TypeError","unsupported operand type(s) for +: '"+vm_type_name(l)+"' and '"+vm_type_name(r)+"'");
        case nypy::A_MUL: {
            int64_t times;
            const VMVal* seq=nullptr;
            if(lb&&!rb&&seq_times(r,times)) seq=&l; else if(rb&&!lb&&seq_times(l,times)) seq=&r;
            if(!seq) raise_native_exception("TypeError","can't multiply sequence by non-int of type '"+vm_type_name(lb?r:l)+"'");
            if(times>0&&seq->bdata().size()*(uint64_t)times>(1ull<<32)) raise_native_exception("MemoryError","repeated bytes are too long");
            out=VMVal::make_bytes(nypy::repeat_str(seq->bdata(),times),seq->b);
            return true;
        }
        case nypy::A_MOD:
            if(lb) raise_native_exception("TypeError","%-formatting of bytes is not supported; use b''.join or .format on str and encode()");
            return false;
        default:
            raise_native_exception("TypeError",std::string("unsupported operand type(s) for ")+nypy::arith_symbol(op)+": '"+vm_type_name(l)+"' and '"+vm_type_name(r)+"'");
        }
    }
    // A value as an argument of a bytes method (NyBytes.hpp: BArg).
    nypy::BArg to_barg(const VMVal& v, int depth=0) {
        nypy::BArg a; a.tname=vm_type_name(v);
        switch(v.type){
            case VMType::NONE: case VMType::UNDEFINED: a.k=nypy::BArg::NONE; return a;
            case VMType::BOOL: a.k=nypy::BArg::BOOL; a.i=v.b?1:0; return a;
            case VMType::INT: a.k=nypy::BArg::INT; a.i=v.i; return a;
            case VMType::BYTES: a.k=nypy::BArg::BYTES; a.s=v.bdata(); return a;
            case VMType::STRING: a.k=nypy::BArg::STR; a.s=v.s; return a;
            case VMType::LIST: case VMType::MAP: case VMType::ITERATOR: case VMType::GENERATOR: case VMType::INSTANCE:
                if(depth==0){
                    a.k=nypy::BArg::SEQ;
                    for(auto& it:iter_items(v)) a.items.push_back(to_barg(it,1));
                    return a;
                }
                a.k=nypy::BArg::OTHER; return a;
            default: a.k=nypy::BArg::OTHER; return a;
        }
    }
    static VMVal from_bres(const nypy::BRes& r) {
        switch(r.k){
            case nypy::BRes::INT: return VMVal::make_int(r.i);
            case nypy::BRes::BOOL: return VMVal::make_bool(r.b);
            case nypy::BRes::STR: return VMVal::make_str(r.s);
            case nypy::BRes::BYTES: return VMVal::make_bytes(r.s,r.ba);
            case nypy::BRes::LIST: case nypy::BRes::TUPLE: {
                std::vector<VMVal> items; items.reserve(r.v.size());
                for(auto& x:r.v) items.push_back(VMVal::make_bytes(x,r.ba));
                VMVal out=VMVal::make_list(std::move(items)); out.b=r.k==nypy::BRes::TUPLE; return out;
            }
            default: return VMVal::make_none();
        }
    }
    // bytes(x) / bytearray(x) with encoding/errors (positional or keyword).
    VMVal construct_bytes(std::vector<VMVal>& a, bool mut) {
        VMVal kw=take_kwargs(a);
        std::string enc="utf-8", err="strict"; bool has_enc=false;
        const char* tn=mut?"bytearray":"bytes";
        if(kw.type==VMType::MAP&&kw.map) for(auto& kv:*kw.map){
            std::string k=nypy::key_payload(kv.first);
            if(vm_internal_key(kv.first)) continue;
            if(k=="encoding"){ enc=vm_str(kv.second); has_enc=true; }
            else if(k=="errors") err=vm_str(kv.second);
            else raise_native_exception("TypeError",std::string(tn)+"() got an unexpected keyword argument '"+k+"'");
        }
        if(a.size()>3) raise_native_exception("TypeError",std::string(tn)+"() takes at most 3 arguments ("+std::to_string(a.size())+" given)");
        if(a.size()>=2){ enc=vm_str(a[1]); has_enc=true; }
        if(a.size()>=3) err=vm_str(a[2]);
        if(!a.empty()&&a[0].type==VMType::INSTANCE){
            bool f=false;
            VMVal r=call_dunder_f(a[0],"__bytes__",{},f);
            if(f){
                if(r.type!=VMType::BYTES) raise_native_exception("TypeError","__bytes__ returned non-bytes (type "+vm_type_name(r)+")");
                return VMVal::make_bytes(r.bdata(),mut);
            }
        }
        std::vector<nypy::BArg> ba;
        if(!a.empty()) ba.push_back(to_barg(a[0]));
        return VMVal::make_bytes(nycall([&]{ return nypy::bytes_construct(ba,enc,err,has_enc,tn); }),mut);
    }
    VMVal binop(int op, const VMVal& l, const VMVal& r) {
        if(l.is_set()||r.is_set()){
            // | & - ^ between sets (round 77); anything else is a TypeError
            char so=op==nypy::A_OR?'|':op==nypy::A_AND?'&':op==nypy::A_SUB?'-':op==nypy::A_XOR?'^':0;
            if(so&&l.is_set()&&r.is_set()) return set_op(so,l,r);
            static const char* names[]={"?","+","-","*","/","//","%","**","&","|","^","<<",">>"};
            std::string sym=(op>=1&&op<=12)?names[op]:"?";
            if(l.type!=VMType::INSTANCE&&r.type!=VMType::INSTANCE)
                raise_native_exception("TypeError","unsupported operand type(s) for "+sym+": '"+vm_type_name(l)+"' and '"+vm_type_name(r)+"'");
        }
        if(op==nypy::A_OR&&l.type==VMType::MAP&&r.type==VMType::MAP&&l.map&&r.map&&l.class_name.empty()&&r.class_name.empty()){
            // dict | dict: a merged copy, the right one winning (Python 3.9)
            VMVal d=VMVal::make_map();
            for(auto& kv:*l.map) (*d.map)[kv.first]=kv.second;
            for(auto& kv:*r.map) (*d.map)[kv.first]=kv.second;
            return d;
        }
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
        if(l.type==VMType::BYTES||r.type==VMType::BYTES){ VMVal out; if(bytes_binop(op,l,r,out)) return out; }
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
        if(l.is_bytearray()&&(op==nypy::A_ADD||op==nypy::A_MUL)){
            // bytearray += b / *= n change it in place
            if(op==nypy::A_ADD){
                if(r.type!=VMType::BYTES) raise_native_exception("TypeError","can't concat "+vm_type_name(r)+" to bytearray");
                std::string add=r.bdata();
                l.bdata_mut()+=add;
                return l;
            }
            int64_t times;
            if(!seq_times(r,times)) raise_native_exception("TypeError","can't multiply sequence by non-int of type '"+vm_type_name(r)+"'");
            l.bdata_mut()=nypy::repeat_str(l.bdata(),times);
            return l;
        }
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
    std::string format_value(const VMVal& v, const std::string& spec) {
        if(v.type==VMType::INSTANCE){
            // its __format__, which must give a str; without one,
            // object.__format__: str(v) for an empty spec, else TypeError
            // (round 77, as the interpreter)
            bool found=false;
            VMVal r=call_dunder_f(v,"__format__",{VMVal::make_str(spec)},found);
            if(found){
                if(r.type==VMType::STRING) return r.s;
                raise_native_exception("TypeError","__format__ must return a str, not "+vm_type_name(r));
            }
            if(spec.empty()) return vm_str(v);
        }
        return nycall([&]{ return nypy::format_value(to_fmtval(v,0),spec); });
    }
    // An object formatted by %d / %x / %f ...: its __index__, else its
    // __float__ (round 77; an IntEnum member is formatted as its int)
    VMVal pct_number(const VMVal& v) {
        if(v.type!=VMType::INSTANCE) return v;
        VMVal iv;
        if(index_value(v,iv)) return iv;
        bool f=false;
        VMVal fv=call_dunder_f(v,"__float__",{},f);
        return f?fv:v;
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
                        return to_fmtval(conv==0?pct_number(it->second):it->second,conv);
                    }
                    return to_fmtval(conv==0?pct_number(args[(size_t)idx]):args[(size_t)idx],conv);
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
                if(v.type==VMType::INSTANCE){
                    // the object's __format__ (as the interpreter's strFormat)
                    nypy::FmtVal fv=nypy::FmtVal::of_other(vm_str(v),v.class_name);
                    VMVal m;
                    if(class_lookup(v.class_name,"__format__",m))
                        fv.custom=[this,v](const std::string& spec){ return format_value(v,spec); };
                    return fv;
                }
                return to_fmtval(v,0);
            });
        });
    }
    // Every element an iterable yields: a list/tuple's items, a string's
    // characters, a dict's keys, what is left of an iterator or a
    // generator (consuming it), an instance's __iter__/__next__ sequence.
    std::vector<VMVal> iter_items(const VMVal& v) {
        if(v.type==VMType::CLASS&&!class_meta_.empty()){
            VMVal r;
            if(meta_call(v,"__iter__",{},r)) return iter_items(r);
        }
        switch(v.type){
            case VMType::LIST: return v.list?*v.list:std::vector<VMVal>{};
            case VMType::STRING: {
                std::vector<VMVal> out;
                for(auto& ch:nypy::u8_chars(v.s)) out.push_back(VMVal::make_str(ch));
                return out;
            }
            case VMType::BYTES: {
                std::vector<VMVal> out;
                const std::string& d=v.bdata();
                out.reserve(d.size());
                for(unsigned char c:d) out.push_back(VMVal::make_int(c));
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
                // __iter__'s result (a list, iter(...), a generator, or an
                // iterator object), else the object itself with __next__,
                // else a __getitem__ sequence indexed from 0 until
                // IndexError; anything else is not iterable.
                std::vector<VMVal> out;
                bool f=false;
                VMVal it=call_dunder_f(v,"__iter__",{},f);
                if(f && it.type!=VMType::INSTANCE) return iter_items(it);
                VMVal iterator = f ? it : v;
                VMVal m;
                if(!class_lookup(iterator.class_name,"__next__",m)){
                    VMVal gi;
                    if(!f && class_lookup(v.class_name,"__getitem__",gi)){
                        for(int64_t k=0;;k++){
                            std::vector<VMVal> ka{VMVal::make_int(k)};
                            try { out.push_back(invoke_method(gi, v, ka, v.class_name)); }
                            catch(VMException& e){
                                if(class_derives(e.value.class_name,"IndexError")||is_stop_iteration(e.value)) break;
                                throw;
                            }
                        }
                        return out;
                    }
                    throw_exception(make_exception("TypeError",{VMVal::make_str("'"+v.class_name+"' object is not iterable")}));
                }
                while(true){
                    try { out.push_back(call_dunder(iterator,"__next__",{})); }
                    catch(VMException& e){ if(is_stop_iteration(e.value)) break; throw; }
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
                if(k.is_set()) return set_key(k);   // a frozenset; a set raises
                if(k.b){
                    std::vector<std::string> parts;
                    if(k.list) for(auto& e:*k.list) parts.push_back(vkey(e));
                    return nypy::key_of_tuple(parts);
                }
                raise_native_exception("TypeError","unhashable type: 'list'");
            case VMType::MAP: raise_native_exception("TypeError","unhashable type: 'dict'");
            case VMType::BYTES:
                if(k.b) raise_native_exception("TypeError","unhashable type: 'bytearray'");
                return nypy::key_of_bytes(k.s);
            case VMType::INSTANCE: {
                // An object with __hash__: keyed by its class and hash, as a
                // set element is (set_key) - two equal dates are one key. The
                // first object stored stands for the key.
                check_hashable(k);
                bool f=false;
                VMVal h=call_dunder_f(k,"__hash__",{},f);
                if(f){
                    std::string hid="vh"+k.class_name+":"+h.to_string();
                    vm_key_objs().emplace(hid,k);
                    return nypy::key_of_obj(hid);
                }
                break;
            }
            case VMType::NATIVE: {
                // a builtin (int, len, ...): keyed by what it is - every
                // native has no pointer of its own, so {int: 1, str: 2}
                // was one key (round 77)
                std::string b=k.builtin_type_name();
                std::string id="n"+(b.empty()?k.class_name:b);
                if(id=="n") break;
                vm_key_objs().emplace(id,k);
                return nypy::key_of_obj(id);
            }
            default: break;
        }
        const void* id=k.map?(const void*)k.map.get():k.code?(const void*)k.code.get():k.gen?(const void*)k.gen.get():(const void*)k.iter.get();
        char buf[40]; snprintf(buf,sizeof buf,"v%p",id);
        vm_key_objs()[buf]=k;
        return nypy::key_of_obj(buf);
    }
    // ── Sets (round 77; NythonExecutor's "SETS" section is the interpreter's)
    // An element's key: the dict key (vkey: 1 == 1.0 == true, tuples and
    // frozensets by content), an object with __hash__ by its hash.
    // A class whose __hash__ is None (a dataclass with eq=True, Python's
    // `__hash__ = None`): its instances are unhashable (round 77).
    void check_hashable(const VMVal& v) {
        VMVal m;
        if(v.type==VMType::INSTANCE&&class_lookup(v.class_name,"__hash__",m)&&m.type==VMType::NONE)
            raise_native_exception("TypeError","unhashable type: '"+vm_type_name(v)+"'");
    }
    std::string set_key(const VMVal& v) {
        if(v.type==VMType::INSTANCE){
            check_hashable(v);
            bool f=false;
            VMVal h=call_dunder_f(v,"__hash__",{},f);
            if(f) return "\x01h"+h.to_string();
        }
        if(v.is_set()){
            if(!v.is_frozenset()) raise_native_exception("TypeError","unhashable type: 'set'");
            std::vector<std::string> parts;
            for(auto& kv:*v.map) parts.push_back(kv.first);
            return nypy::key_of_frozenset(parts);
        }
        return vkey(v);
    }
    static VMVal new_set(bool frozen) {
        VMVal x=VMVal::make_list();
        x.class_name=frozen?"__frozenset__":"__set__";
        x.map=std::make_shared<VMMap>();
        return x;
    }
    bool set_has(const VMVal& s, const VMVal& v) { return s.map->count(set_key(v))>0; }
    bool set_add(VMVal& s, const VMVal& v) {
        std::string k=set_key(v);
        if(s.map->count(k)) return false;
        (*s.map)[k]=VMVal::make_int((int64_t)s.list->size());
        s.list->push_back(v);
        return true;
    }
    bool set_discard(VMVal& s, const VMVal& v) {
        std::string k=set_key(v);
        auto it=s.map->find(k);
        if(it==s.map->end()) return false;
        size_t at=(size_t)it->second.i;
        s.map->erase(k);
        s.list->erase(s.list->begin()+(long)at);
        for(size_t i=at;i<s.list->size();i++) (*s.map)[set_key((*s.list)[i])]=VMVal::make_int((int64_t)i);
        return true;
    }
    void set_clear(VMVal& s) { s.list->clear(); s.map->clear(); }
    VMVal build_set(const std::vector<VMVal>& items, bool frozen) {
        VMVal x=new_set(frozen);
        for(auto& v:items) set_add(x,v);
        return x;
    }
    // op: '|' '&' '-' '^'; b may be any iterable (the methods' operand).
    VMVal set_op(char op, const VMVal& a, const VMVal& b) {
        std::vector<VMVal> av=a.is_set()?*a.list:iter_items(a);
        VMVal bs=b.is_set()?b:build_set(iter_items(b),true);
        VMVal r=new_set(a.is_frozenset());
        if(op=='|'){ for(auto& v:av) set_add(r,v); for(auto& v:*bs.list) set_add(r,v); }
        else if(op=='&'){ for(auto& v:av) if(set_has(bs,v)) set_add(r,v); }
        else if(op=='-'){ for(auto& v:av) if(!set_has(bs,v)) set_add(r,v); }
        else {
            VMVal as=a.is_set()?a:build_set(av,true);
            for(auto& v:av) if(!set_has(bs,v)) set_add(r,v);
            for(auto& v:*bs.list) if(!set_has(as,v)) set_add(r,v);
        }
        return r;
    }
    bool set_subset(const VMVal& a, const VMVal& b) {
        std::vector<VMVal> av=a.is_set()?*a.list:iter_items(a);
        VMVal bs=b.is_set()?b:build_set(iter_items(b),true);
        for(auto& v:av) if(!set_has(bs,v)) return false;
        return true;
    }
    bool set_method(VMVal& obj, const std::string& m, std::vector<VMVal>& a, VMVal& out) {
        bool frozen=obj.is_frozenset();
        std::string tn=frozen?"frozenset":"set";
        auto need=[&](size_t n){
            if(a.size()!=n) raise_native_exception("TypeError",tn+"."+m+"() takes exactly "+(n==1?std::string("one argument"):std::to_string(n)+" arguments")+" ("+std::to_string(a.size())+" given)");
        };
        auto mutating=[&](){ if(frozen) raise_native_exception("AttributeError","'frozenset' object has no attribute '"+m+"'"); };
        out=VMVal::make_none();
        if(m=="add"){ mutating(); need(1); set_add(obj,a[0]); return true; }
        if(m=="discard"){ mutating(); need(1); set_discard(obj,a[0]); return true; }
        if(m=="remove"){ mutating(); need(1); if(!set_discard(obj,a[0])) throw_exception(make_exception("KeyError",{a[0]})); return true; }
        if(m=="pop"){
            mutating(); need(0);
            if(obj.list->empty()) raise_native_exception("KeyError","'pop from an empty set'");
            out=(*obj.list)[0]; set_discard(obj,out); return true;
        }
        if(m=="clear"){ mutating(); need(0); set_clear(obj); return true; }
        if(m=="copy"){ need(0); out=build_set(*obj.list,frozen); return true; }
        if(m=="update"||m=="intersection_update"||m=="difference_update"||m=="symmetric_difference_update"){
            mutating();
            if(m=="symmetric_difference_update") need(1);
            for(auto& x:a){
                if(m=="update"){ for(auto& v:iter_items(x)) set_add(obj,v); continue; }
                char op=m=="intersection_update"?'&':m=="difference_update"?'-':'^';
                VMVal r=set_op(op,obj,x);
                std::vector<VMVal> keep=*r.list;
                set_clear(obj);
                for(auto& v:keep) set_add(obj,v);
            }
            return true;
        }
        if(m=="union"||m=="intersection"||m=="difference"){
            char op=m=="union"?'|':m=="intersection"?'&':'-';
            VMVal r=build_set(*obj.list,frozen);
            for(auto& x:a) r=set_op(op,r,x);
            out=r; return true;
        }
        if(m=="symmetric_difference"){ need(1); out=set_op('^',obj,a[0]); return true; }
        if(m=="issubset"){ need(1); out=VMVal::make_bool(set_subset(obj,a[0])); return true; }
        if(m=="issuperset"){ need(1); out=VMVal::make_bool(set_subset(a[0],obj)); return true; }
        if(m=="isdisjoint"){
            need(1);
            for(auto& v:iter_items(a[0])) if(set_has(obj,v)){ out=VMVal::make_bool(false); return true; }
            out=VMVal::make_bool(true); return true;
        }
        if(m=="__contains__"||m=="contains"||m=="has"){ need(1); out=VMVal::make_bool(set_has(obj,a[0])); return true; }
        if(m=="len"||m=="length"||m=="size"||m=="__len__"){ out=VMVal::make_int((int64_t)obj.list->size()); return true; }
        if(m=="slice") raise_native_exception("TypeError","'"+tn+"' object is not subscriptable");
        return false;
    }

    bool op_in(const VMVal& item, const VMVal& cont) {
        if(cont.type==VMType::CLASS&&!class_meta_.empty()){
            VMVal r;
            if(meta_call(cont,"__contains__",{item},r)) return vm_truthy(r);
            for(auto& v:iter_items(cont)) if(vm_eq(v,item)) return true;
            return false;
        }
        if(cont.type==VMType::INSTANCE){
            bool f=false;
            VMVal res=call_dunder_f(cont,"__contains__",{item},f);
            if(f) return vm_truthy(res);
            // No __contains__: search what it iterates over.
            for(auto& v:iter_items(cont)) if(vm_eq(v,item)) return true;
            return false;
        }
        if(cont.type==VMType::GENERATOR||cont.type==VMType::ITERATOR){
            // Consumed up to the first match (an infinite one terminates).
            VMVal it=cont, v;
            while(vm_iter_step(it,v)) if(vm_eq(v,item)) return true;
            return false;
        }
        if(cont.type==VMType::STRING){
            if(item.type!=VMType::STRING)   // round 77: it was false
                raise_native_exception("TypeError","'in <string>' requires string as left operand, not "+vm_type_name(item));
            return cont.s.find(item.s)!=std::string::npos;
        }
        if(cont.type==VMType::BYTES){
            nypy::BArg x=to_barg(item);
            return nycall([&]{ return nypy::bytes_contains(cont.bdata(),x); });
        }
        if(cont.is_set()) return set_has(cont,item);   // one lookup (round 77)
        if(cont.type==VMType::LIST){
            if(cont.list) for(auto& v:*cont.list) if(vm_eq(v,item)) return true;
            return false;
        }
        if(cont.type==VMType::MAP){
            if(cont.map) return cont.map->count(vkey(item))>0;
            return false;
        }
        // `1 in 5`, `x in None`: TypeError, as in Python (round 77; it was false)
        raise_native_exception("TypeError","argument of type '"+vm_type_name(cont)+"' is not iterable");
    }
    // Which except clause (if any) a raised exception should run: the first
    // whose declared type is empty (catch-all), one of the generic
    // Exception/BaseException/Error names, equal to the exception's own
    // type, or a parent of it. Mirrors the interpreter's evalTry
    // (NythonExecutor.hpp) type-matching, including its silent fall-through
    // to `finally` (ee.end) when nothing matches rather than re-raising.
    // The first clause (in source order) that catches exc_val, -1 if none.
    int match_except_handler(const ExceptionEntry& ee, const VMVal& exc_val) {
        for(auto& cl : ee.clauses){
            if(cl.types.empty()) return cl.handler;
            for(auto& t : cl.types)
                if(exception_matches(exc_val, exc_class_name(t))) return cl.handler;
        }
        return -1;
    }
    // The class an except clause names (NythonExecutor::excClassName): the
    // name is looked up in scope, so a module's own class ("module.E"), an
    // alias and a dotted name match what they name (round 77).
    std::string exc_class_name(const std::string& t) {
        if(t.empty() || nython::ny_is_builtin_exc(t)) return t;
        size_t dot=t.find('.');
        std::string head=dot==std::string::npos?t:t.substr(0,dot);
        VMVal v;
        bool ok=name_bound(head);
        if(ok) v=load_var(head);
        while(ok && dot!=std::string::npos){
            size_t next=t.find('.',dot+1);
            std::string part=t.substr(dot+1, next==std::string::npos?std::string::npos:next-dot-1);
            VMVal a;
            try { ok=try_get_attr(v, part, a); } catch(...) { ok=false; }
            v=a; dot=next;
        }
        if(ok && v.type==VMType::CLASS) return v.class_name;
        size_t last=t.rfind('.');
        return last==std::string::npos?t:t.substr(last+1);
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
        // Every base counts (`child is Base`, a second base too).
        if(v.type==VMType::INSTANCE) return class_derives(v.class_name, want);
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
        // A function value is its code with its closure and defaults (round
        // 77: two closures of one def were `is`-identical - inspect.unwrap
        // saw a wrapper loop in two functools.wraps wrappers)
        if(l.type==VMType::FUNCTION) return l.code.get()==r.code.get()&&l.closure_env.get()==r.closure_env.get()&&l.list.get()==r.list.get();
        // builtins: the same one (int is int, len is len)
        if(l.type==VMType::NATIVE)   return l==r;
        return l==r;
    }

    // ── Attribute access ────────────────────────────────────────────────
    // obj.attr. Reading an attribute the object does not have raises
    // AttributeError, whatever the object (round 75: it read none), as on
    // the interpreter (NythonExecutor::evalAttribute). getattr(o, n, d),
    // hasattr, `o?.attr` and `o?.attr ?? d` are the graceful forms.
    VMVal get_attr(const VMVal& obj, const std::string& attr) {
        // The common read, a field present on an instance or a map (not a
        // property), straight from the map: a VMVal is costly to default-
        // construct and copy twice.
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(attr);
            if(it!=obj.map->end()&&!is_property_desc(it->second)) return it->second;
        }
        VMVal v;
        if(lookup_attr(obj, attr, v)) return v;
        return missing_attr(obj, attr);
    }
    // obj.attr for a value in hand: true with the value in `out`, false when
    // obj has no such attribute - nothing is raised for that. Property
    // getters and __getattr__ run, and what they raise propagates. `bind`
    // false: a builtin's method is not made into a bound value.
    bool lookup_attr(const VMVal& obj, const std::string& attr, VMVal& out, bool bind=true) {
        // a bound method: __self__, __func__, and everything else its
        // function's (__doc__, __name__, __annotations__, attributes set on it)
        if(obj.type==VMType::MAP&&obj.class_name=="__bound_method__"&&obj.map){
            auto fit=obj.map->find("__fn__");
            if(attr=="__self__"){ auto sit=obj.map->find("__self__"); out=sit!=obj.map->end()?sit->second:VMVal::make_none(); return true; }
            if(fit==obj.map->end()) return false;
            if(attr=="__func__"){ out=fit->second; return true; }
            return lookup_attr(fit->second, attr, out, bind);
        }
        // Instance / map fields — check for property descriptors
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(attr);
            if(it!=obj.map->end()){
                VMVal& v=it->second;
                // A property stored on the instance itself: self.x = property(get)
                if(obj.type==VMType::INSTANCE&&is_property_desc(v)){ out=property_get(v, obj); return true; }
                if(obj.type==VMType::MAP&&is_property_desc(v)){
                    auto git=v.map->find("__get__");
                    if(git!=v.map->end()&&git->second.type==VMType::FUNCTION){
                        std::vector<VMVal> no_args;
                        out=call_function(git->second, no_args, obj);
                        return true;
                    }
                }
                out=v;
                return true;
            }
        }
        if(attr=="__class__"&&obj.type!=VMType::INSTANCE){
            // (5).__class__ is int, C.__class__ is type (round 77)
            VMVal t=type_object_of(obj);
            if(t.type!=VMType::NONE){ out=t; return true; }
        }
        // a generator's __name__, gi_frame, gi_code, ... (round 77)
        if(obj.type==VMType::GENERATOR&&gen_attr(obj,attr,out)) return true;
        switch(obj.type){
        case VMType::INSTANCE: {
            VMVal m;
            if(class_lookup(obj.class_name, attr, m)){ out=bind_member(m, obj, obj.class_name); return true; }
            if(attr=="__class__"){ out=class_value(obj.class_name); return true; }
            if(attr=="__doc__"){
                auto cr=class_reg_.find(obj.class_name);
                out=cr!=class_reg_.end()&&cr->second&&cr->second->has_doc?VMVal::make_str(cr->second->doc):VMVal::make_none();
                return true;
            }
            if(attr=="__dict__"){
                // names as dict keys: self.__x__ is listed too (round 77)
                VMVal d=VMVal::make_map();
                // names as dict keys, without the engine's hidden field
                // ("\x01weakref") - round 77
                if(obj.map) for(auto& kv:*obj.map) if(kv.first!="\x01weakref") (*d.map)[nypy::key_of_str(kv.first)]=kv.second;
                out=d; return true;
            }
            VMVal ga;
            if(class_lookup(obj.class_name, "__getattr__", ga)){
                std::vector<VMVal> a{VMVal::make_str(attr)};
                out=invoke_method(ga, obj, a, obj.class_name);
                return true;
            }
            break;
        }
        case VMType::STRING:
            // type(x).__name__: type() gives a name string on this engine
            // (a module class "m.C" is named "C").
            if(attr=="__name__"||attr=="__qualname__"){
                std::string shown=nyrt::shown_class_name(obj.s);
                size_t dot=shown.rfind('.');
                out=VMVal::make_str(dot==std::string::npos?shown:shown.substr(dot+1)); return true;
            }
            break;
        case VMType::FUNCTION: {
            if(!func_attrs_.empty()){
                auto fa=func_attrs_.find(func_key(obj));
                if(fa!=func_attrs_.end()){ auto it=fa->second.find(attr); if(it!=fa->second.end()){ out=it->second; return true; } }
            }
            if(attr=="__name__"){ out=VMVal::make_str(obj.code?obj.code->name:""); return true; }
            if(attr=="__qualname__"){ out=VMVal::make_str(obj.code?(obj.code->qualname.empty()?obj.code->name:obj.code->qualname):""); return true; }
            if(attr=="__doc__"){ out=obj.code&&obj.code->has_doc?VMVal::make_str(obj.code->doc):VMVal::make_none(); return true; }
            // __defaults__, __kwdefaults__, __code__, __qualname__, __module__,
            // __globals__ (round 77): the prelude's _ny_fn_attr makes them from
            // _ny_fn_info (fn_info), as on the interpreter.
            if(obj.code&&(attr=="__defaults__"||attr=="__kwdefaults__"||attr=="__code__"||attr=="__qualname__"
                          ||attr=="__module__"||attr=="__globals__")){
                std::vector<VMVal> a{obj, VMVal::make_str(attr)};
                out=vm_call(load_var("_ny_fn_attr"), a, std::nullopt, nullptr);
                return true;
            }
            // no annotations: an empty dict, made on first read and kept
            if(attr=="__annotations__"&&obj.code){ out=VMVal::make_map(); func_attrs_[func_key(obj)][attr]=out; return true; }
            return false;
        }
        case VMType::CLASS: {
            std::string cname = obj.class_name.empty() ? obj.s : obj.class_name;
            VMVal m;
            if(class_lookup(cname, attr, m)){
                if(m.type==VMType::FUNCTION&&m.code&&m.code->is_classmethod) out=make_bound(m, obj, true);
                else if(m.type==VMType::INSTANCE&&descriptor_get(m, VMVal::make_none(), cname, out)) {}
                else out=m;   // a method read from the class is the plain function
                return true;
            }
            // A module's class is "module.Class" (round 77): __name__ is the
            // class's own name, __module__ the module's.
            if(attr=="__name__"||attr=="__qualname__"){
                std::string shown=nyrt::shown_class_name(cname);
                size_t dot=shown.rfind('.');
                out=VMVal::make_str(dot==std::string::npos?shown:shown.substr(dot+1)); return true;
            }
            if(attr=="__module__"){
                size_t dot=cname.rfind('.');
                out=VMVal::make_str(dot==std::string::npos?std::string("__main__"):cname.substr(0,dot)); return true;
            }
            if(attr=="__doc__"){
                auto cr=class_reg_.find(cname);
                out=cr!=class_reg_.end()&&cr->second&&cr->second->has_doc?VMVal::make_str(cr->second->doc):VMVal::make_none();
                return true;
            }
            if(attr=="__mro__"){
                // builtin bases as their builtin values; object last (round 77)
                std::vector<VMVal> r;
                for(auto& c:*class_mro(cname)){
                    if(c=="object") continue;
                    VMVal cv=class_value(c);
                    if(cv.type==VMType::NONE&&nyrt::is_builtin_type_name(c)) cv=load_var(c);
                    if(cv.type!=VMType::NONE) r.push_back(cv);
                }
                if(cname!="object"){ VMVal o=class_value("object"); if(o.type!=VMType::NONE) r.push_back(o); }
                out=VMVal::make_tuple(std::move(r)); return true;
            }
            // C.__dict__: the class's own namespace (a copy; a mappingproxy is read-only)
            if(attr=="__dict__"){ out=class_namespace(cname); return true; }
            if(attr=="__bases__"){
                std::vector<VMVal> r;
                auto rit=class_reg_.find(cname);
                if(rit!=class_reg_.end()&&rit->second) for(auto& b:rit->second->bases){
                    VMVal cv=class_value(b);
                    if(cv.type==VMType::NONE&&nyrt::is_builtin_type_name(b)) cv=load_var(b);
                    if(cv.type!=VMType::NONE) r.push_back(cv);
                }
                if(r.empty()&&cname!="object"){ VMVal o=class_value("object"); if(o.type!=VMType::NONE) r.push_back(o); }
                out=VMVal::make_tuple(std::move(r)); return true;
            }
            // the metaclass's members: methods bound to the class, its
            // properties read with the class, its attributes, __getattr__
            if(!class_meta_.empty()&&attr!="__init__"&&attr!="__new__"){
                VMVal M=metaclass_of(cname);
                if(M.type==VMType::CLASS){
                    VMVal m; std::string owner;
                    if(class_lookup(class_key(M),attr,m,&owner)&&nyrt::shown_class_name(owner)!="object"){
                        if(is_property_desc(m)){ out=property_get(m, obj); return true; }
                        if(m.type==VMType::FUNCTION&&m.code&&!m.code->is_static){
                            std::vector<VMVal> a{m, obj};
                            out=vm_call(load_var("_NyMetaBound"), a, std::nullopt, nullptr);
                            return true;
                        }
                        out=m; return true;
                    }
                    if(attr.rfind("__",0)!=0){
                        VMVal r;
                        if(meta_call(obj,"__getattr__",{VMVal::make_str(attr)},r)){ out=r; return true; }
                    }
                }
            }
            return false;
        }
        case VMType::NATIVE:
            // int.__mro__ / int.__bases__ of a builtin type (round 77):
            // (int, object), and bool's MRO is (bool, int, object)
            if((attr=="__mro__"||attr=="__bases__")&&!obj.builtin_type_name().empty()){
                std::string b=obj.builtin_type_name();
                std::vector<VMVal> r;
                if(attr=="__mro__") r.push_back(obj);
                if(b=="bool"){ auto it=builtin_types_.find("int"); if(it!=builtin_types_.end()) r.push_back(it->second); }
                if(attr=="__mro__"||b!="bool"){ VMVal o=class_value("object"); if(o.type!=VMType::NONE) r.push_back(o); }
                out=VMVal::make_tuple(std::move(r)); return true;
            }
            // len.__name__, int.__name__: the name the builtin is tagged with
            if(attr=="__name__"||attr=="__qualname__"||attr=="__module__"){
                const std::string& c=obj.class_name;
                size_t colon=c.find(':');
                bool tagged=colon!=std::string::npos&&(c.rfind("__builtin__:",0)==0||c.rfind("__native__:",0)==0);
                if(tagged||(!c.empty()&&colon==std::string::npos)){
                    if(attr=="__module__"){ out=VMVal::make_str("builtins"); return true; }
                    std::string nm=tagged?c.substr(colon+1):c;
                    if(nm=="map") nm="dict";   // the dict builtin is tagged with Nython's name for it
                    size_t dot=nm.rfind('.');
                    out=VMVal::make_str(dot==std::string::npos?nm:nm.substr(dot+1));
                    return true;
                }
            }
            // A builtin type (tagged with its name): str.upper, bytes.fromhex,
            // int.from_bytes, dict.fromkeys ... (round 77)
            if(!native_type_base(obj).empty()&&nypy::type_has_member(native_type_base(obj),attr)){
                std::string base=native_type_base(obj);
                VirtualMachine* vm=this;
                out=VMVal::make_native([vm,base,attr](std::vector<VMVal>& a)->VMVal{
                    VMVal kw=take_kwargs(a);
                    return vm->type_member_call(base,attr,a,kw.type==VMType::MAP?&kw:nullptr);
                });
                out.class_name="__builtin__:"+base+"."+attr;
                return true;
            }
            // A builtin used as a namespace: time.time, os.path ...
            if(obj.class_name.rfind("__builtin__:",0)==0){
                std::string base=obj.class_name.substr(12);
                if(nypy::type_has_member(base,attr)){
                    VirtualMachine* vm=this;
                    out=VMVal::make_native([vm,base,attr](std::vector<VMVal>& a)->VMVal{
                        VMVal kw=take_kwargs(a);
                        return vm->type_member_call(base,attr,a,kw.type==VMType::MAP?&kw:nullptr);
                    });
                    out.class_name="__builtin__:"+base+"."+attr;
                    return true;
                }
                std::string target=nyrt::builtin_member(obj.class_name.substr(12),attr,
                    [&](const std::string& n){ return bridge_exists()&&bridge_exists()(n); });
                if(!target.empty()){ out=load_var(target); return true; }
            }
            return false;
        default: break;
        }
        // A builtin value's method, or the object protocol, read as a value.
        if(bind){
            nypy::MemberKind k=vm_member_kind(obj);
            if(k!=nypy::MemberKind::Other&&nypy::kind_has_method(k,attr)){ out=bound_member(obj,attr); return true; }
        }
        return false;
    }
    // Attributes stored on a function (f.calls = 0), as in Python, keyed by
    // the function value's identity (VMVal::operator== for FUNCTION).
    using FuncKey=std::tuple<const void*,const void*,const void*>;
    std::map<FuncKey,std::unordered_map<std::string,VMVal>> func_attrs_;
    static FuncKey func_key(const VMVal& f){ return FuncKey{f.code.get(),f.closure_env.get(),f.list.get()}; }
    static nypy::MemberKind vm_member_kind(const VMVal& v){
        switch(v.type){
            case VMType::NONE:   return nypy::MemberKind::None;
            case VMType::BOOL:   return nypy::MemberKind::Bool;
            case VMType::INT:    return nypy::MemberKind::Int;
            case VMType::FLOAT:  return nypy::MemberKind::Float;
            case VMType::STRING: return nypy::MemberKind::Str;
            case VMType::LIST:   return v.is_set()?nypy::MemberKind::Set:v.b?nypy::MemberKind::Tuple:nypy::MemberKind::List;
            case VMType::MAP:    return nypy::MemberKind::Dict;
            case VMType::INSTANCE: return nypy::MemberKind::Instance;
            case VMType::GENERATOR: case VMType::ITERATOR: return nypy::MemberKind::Generator;
            case VMType::BYTES:  return v.b?nypy::MemberKind::ByteArray:nypy::MemberKind::Bytes;
            default:             return nypy::MemberKind::Other;
        }
    }
    // A builtin value's method read as a value: a native calling it on obj.
    VMVal bound_member(const VMVal& obj, const std::string& m){
        if(obj.type==VMType::STRING) return str_method(obj,m);
        if(obj.type==VMType::LIST)   return list_method(obj,m);
        VirtualMachine* vm=this;
        return VMVal::make_native([vm,obj,m](std::vector<VMVal>& a)->VMVal{
            VMVal kw=take_kwargs(a);
            VMVal o=obj;
            return vm->vm_call_method(o,m,a,kw.type==VMType::MAP?&kw:nullptr);
        });
    }
    // Whether obj has a member `name`, without running a property getter or
    // __getattr__ (an object with __getattr__ counts as having every name):
    // the test `obj?.m(...)` makes before calling.
    bool has_member_noeval(const VMVal& obj, const std::string& name){
        if(obj.type==VMType::INSTANCE){
            if(obj.map&&obj.map->count(name)) return true;
            VMVal m;
            if(class_lookup(obj.class_name,name,m)) return true;
            if(name=="__class__"||name=="__dict__"||class_lookup(obj.class_name,"__getattr__",m)) return true;
            return nypy::kind_has_method(nypy::MemberKind::Instance,name);
        }
        VMVal v;
        if(lookup_attr(obj,name,v,false)) return true;
        nypy::MemberKind k=vm_member_kind(obj);
        return k!=nypy::MemberKind::Other&&nypy::kind_has_method(k,name);
    }
    // obj.attr, or false when it has none (hasattr / getattr with a default):
    // an AttributeError from a property getter or __getattr__ counts as none.
    bool try_get_attr(const VMVal& obj, const std::string& attr, VMVal& out) {
        try { return lookup_attr(obj, attr, out); }
        catch(VMException& e){
            if(class_derives(e.value.class_name,"AttributeError")) return false;
            throw;
        }
    }
    std::string attr_error_text(const VMVal& obj, const std::string& attr){
        if(obj.type==VMType::INSTANCE) return "'"+obj.class_name+"' object has no attribute '"+attr+"'";
        if(obj.type==VMType::CLASS){
            std::string cname = obj.class_name.empty() ? obj.s : obj.class_name;
            return "type object '"+cname+"' has no attribute '"+attr+"'";
        }
        return "'"+vm_type_name(obj)+"' object has no attribute '"+attr+"'";
    }
    // A missing attribute read: AttributeError, or - NY_LENIENT_READS=log, a
    // porting aid - a line on stderr and none.
    VMVal missing_attr(const VMVal& obj, const std::string& attr){
        std::string msg=attr_error_text(obj,attr);
        if(nypy::lenient_reads_log()){ log_lenient_read("AttributeError: "+msg); return VMVal::make_none(); }
        throw_exception(make_exception("AttributeError",{VMVal::make_str(msg)}));
        return VMVal::make_none();
    }
    VMVal missing_key(const VMVal& key){
        if(nypy::lenient_reads_log()){ log_lenient_read("KeyError: "+key.repr()); return VMVal::make_none(); }
        throw_exception(make_exception("KeyError",{key}));   // the key itself (round 77)
        return VMVal::make_none();
    }
    // "file:line" of the running instruction.
    std::string vm_where(){
        if(call_stack_.empty()) return "?";
        auto& fr=call_stack_.back();
        int ip=fr.ip-1;
        int line=(fr.code&&ip>=0&&ip<(int)fr.code->instructions.size())?fr.code->instructions[(size_t)ip].line:0;
        std::string f=fr.code?(fr.code->file.empty()?fr.code->name:fr.code->file):std::string("?");
        return f+":"+std::to_string(line);
    }
    void log_lenient_read(const std::string& what){
        static std::mutex mu;
        static std::set<std::string> seen;
        std::string loc=vm_where();
        std::lock_guard<std::mutex> lk(mu);
        if(!seen.insert(loc+" "+what).second) return;
        fprintf(stderr,"[lenient-read] %s: %s\n",loc.c_str(),what.c_str());
    }
    // del obj.name / delattr(obj, name): an instance's field, a class
    // attribute or a namespace/dict entry is removed; anything else is an
    // AttributeError (it was ignored).
    // __setattr__ / __delattr__ (round 77, as NythonExecutor::setAttr): an
    // instance whose class defines one (not object's) runs it; object's own
    // store directly through _ny_setattr_raw / _ny_delattr_raw. Cached per
    // class until the next class statement.
    std::unordered_map<std::string, uint8_t> attr_hook_cache_[2];
    static inline thread_local int raw_attr_depth_=0;
    bool instance_attr_hook(const VMVal& obj, int which, VMVal& m) {
        if(raw_attr_depth_>0||obj.type!=VMType::INSTANCE) return false;
        auto& c=attr_hook_cache_[which];
        auto it=c.find(obj.class_name);
        if(it!=c.end()&&it->second==2) return false;
        std::string owner;
        bool has=class_lookup(obj.class_name, which?"__delattr__":"__setattr__", m, &owner)
                 && nyrt::shown_class_name(owner)!="object";
        c[obj.class_name]=has?1:2;
        return has;
    }
    struct RawAttr { RawAttr(){ raw_attr_depth_++; } ~RawAttr(){ raw_attr_depth_--; } RawAttr(const RawAttr&)=delete; RawAttr& operator=(const RawAttr&)=delete; };
    // C.x = v / del C.x for a class whose metaclass defines __setattr__ /
    // __delattr__ (not object's): the metaclass's runs (round 77, as
    // NythonExecutor::metaAttrHook); its super().__setattr__ stores directly.
    bool meta_attr_hook(const VMVal& cls, const char* which, std::vector<VMVal> args) {
        if(raw_attr_depth_>0||class_meta_.empty()||cls.type!=VMType::CLASS) return false;
        VMVal m;
        if(!meta_member(cls,which,m)) return false;
        call_with_first(m, cls, std::move(args), nullptr);
        return true;
    }
    // A data descriptor (an object whose class defines __set__ / __delete__)
    // held by the instance's class runs for an assignment / deletion of that
    // attribute (round 77, as NythonExecutor::dataDescriptor). Any class
    // defining one turns the check on (class_created).
    bool any_data_descr_=false;
    bool data_descriptor(const VMVal& obj, const std::string& attr, const char* which, VMVal& d, VMVal& m) {
        if(!any_data_descr_||obj.type!=VMType::INSTANCE) return false;
        return class_lookup(obj.class_name, attr, d) && d.type==VMType::INSTANCE && class_lookup(d.class_name, which, m)
               && (m.type==VMType::FUNCTION||m.type==VMType::NATIVE);
    }
    void del_attr(const VMVal& obj, const std::string& attr) {
        {
            VMVal m;
            if(instance_attr_hook(obj,1,m)){
                std::vector<VMVal> a{VMVal::make_str(attr)};
                invoke_method(m, obj, a, obj.class_name);
                return;
            }
        }
        if(any_data_descr_){
            VMVal d, m;
            if(data_descriptor(obj, attr, "__delete__", d, m)){
                std::vector<VMVal> a{obj};
                invoke_method(m, d, a, d.class_name);
                return;
            }
        }
        if(!class_meta_.empty()&&meta_attr_hook(obj,"__delattr__",{VMVal::make_str(attr)})) return;
        if((obj.type==VMType::MAP||obj.type==VMType::INSTANCE)&&obj.map&&obj.map->erase(attr)) return;
        if(obj.type==VMType::CLASS){
            std::string cname = obj.class_name.empty() ? obj.s : obj.class_name;
            auto it=class_vars_.find(cname);
            if(it!=class_vars_.end()&&it->second.erase(attr)) return;
        }
        if(obj.type==VMType::FUNCTION){
            auto fa=func_attrs_.find(func_key(obj));
            if(fa!=func_attrs_.end()&&fa->second.erase(attr)) return;
        }
        throw_exception(make_exception("AttributeError",{VMVal::make_str(attr_error_text(obj,attr))}));
    }
    void set_attr(VMVal& obj, const std::string& attr, VMVal val) {
        {
            VMVal m;
            if(instance_attr_hook(obj,0,m)){
                std::vector<VMVal> a{VMVal::make_str(attr), val};
                invoke_method(m, obj, a, obj.class_name);
                return;
            }
        }
        if(any_data_descr_){
            VMVal d, m;
            if(data_descriptor(obj, attr, "__set__", d, m)){
                std::vector<VMVal> a{obj, val};
                invoke_method(m, d, a, d.class_name);
                return;
            }
        }
        if(!class_meta_.empty()&&meta_attr_hook(obj,"__setattr__",{VMVal::make_str(attr), val})) return;
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(attr);
            if(it!=obj.map->end()){
                VMVal& v=it->second;
                if(is_property_desc(v)){
                    auto sit=v.map->find("__set__");
                    if(sit!=v.map->end()&&sit->second.type==VMType::FUNCTION){
                        std::vector<VMVal> args={val};
                        call_function(sit->second, args, obj);
                        return;
                    }
                }
            }
            // A property defined on the class: its setter, or an error for a
            // read-only one (writing the value into the instance used to
            // shadow the property silently).
            if(obj.type==VMType::INSTANCE && it==obj.map->end()){
                VMVal m;
                if(class_lookup(obj.class_name, attr, m) && is_property_desc(m)){
                    auto sit=m.map->find("__set__");
                    if(sit!=m.map->end()){
                        std::vector<VMVal> args={val};
                        if(sit->second.type==VMType::FUNCTION) call_function(sit->second, args, obj);
                        else { std::vector<VMVal> a2{obj,val}; vm_call(sit->second, a2, std::nullopt); }
                        return;
                    }
                    throw_exception(make_exception("AttributeError",{VMVal::make_str("can't set attribute '"+attr+"'")}));
                }
            }
            (*obj.map)[attr]=std::move(val);
            return;
        }
        // Class.attr = value: the class namespace
        if(obj.type==VMType::CLASS){
            std::string cname = obj.class_name.empty() ? obj.s : obj.class_name;
            class_vars_[cname][attr] = std::move(val);
            return;
        }
        if(obj.type==VMType::FUNCTION&&obj.code){
            // f.__qualname__ = "C.f": the name its call errors give (round 77)
            if(attr=="__qualname__"&&val.type==VMType::STRING){ obj.code->qualname=val.s; obj.code->qualname_set=true; }
            func_attrs_[func_key(obj)][attr]=std::move(val); return;
        }
        // none.x = v, 5.x = v, "s".x = v, len.x = v: nothing can hold it
        // (AttributeError, as in Python - it was dropped silently).
        std::string msg=attr_error_text(obj,attr);
        if(nypy::lenient_reads_log()){ log_lenient_read("AttributeError (store): "+msg); return; }
        throw_exception(make_exception("AttributeError",{VMVal::make_str(msg)}));
    }
    // Resolve a [start,end,step] slice against a sequence of length sz,
    // returning the indices to take in order. NONE start/end mean "the natural
    // end for this direction", which differs by the sign of the step.
    // An index: an int (or bool); anything else raises TypeError.
    int64_t index_of(const VMVal& idx, const char* what) {
        if(idx.type==VMType::INT) return idx.s.empty()?idx.i:(idx.s[0]=='-'?INT64_MIN/2:INT64_MAX/2);
        if(idx.type==VMType::BOOL) return idx.b?1:0;
        if(idx.type==VMType::INSTANCE){ VMVal r; if(index_value(idx,r)) return index_of(r,what); }
        raise_native_exception("TypeError",std::string(what)+" indices must be integers or slices, not "+vm_type_name(idx));
    }
    // x.__index__() (PEP 357): an object standing for an int as an index,
    // a range bound, hex()/bin()/chr() or %d (round 77; an IntEnum member)
    bool index_value(const VMVal& v, VMVal& out) {
        if(v.type!=VMType::INSTANCE) return false;
        bool f=false;
        out=call_dunder_f(v,"__index__",{},f);
        if(!f) return false;
        if(out.type!=VMType::INT&&out.type!=VMType::BOOL) raise_native_exception("TypeError","__index__ returned non-int (type "+vm_type_name(out)+")");
        return true;
    }
    // A slice spec [start, stop(, step)] (none = omitted) against length len:
    // the number of items and the adjusted start/step (PySlice_AdjustIndices).
    int64_t slice_spec(const std::vector<VMVal>& sp, int64_t len, int64_t& st, int64_t& step) {
        int64_t en=0; st=0; step=1;
        bool hs=false,he=false;
        auto bound=[&](const VMVal& v,int64_t& out)->bool{
            if(v.type==VMType::NONE||v.type==VMType::UNDEFINED) return false;
            VMVal iv;
            if(v.type==VMType::INSTANCE&&index_value(v,iv)){ out=index_of(iv,"slice"); return true; }
            if(v.type!=VMType::INT&&v.type!=VMType::BOOL) raise_native_exception("TypeError","slice indices must be integers or None or have an __index__ method");
            out=index_of(v,"slice"); return true;
        };
        if(sp.size()>=1) hs=bound(sp[0],st);
        if(sp.size()>=2) he=bound(sp[1],en);
        if(sp.size()>=3&&sp[2].type!=VMType::NONE) bound(sp[2],step);
        return nycall([&]{ return nypy::slice_adjust(len,hs,st,he,en,step); });
    }
    VMVal get_sub(const VMVal& obj, const VMVal& idx) {
        if(obj.is_set()) raise_native_exception("TypeError","'"+vm_type_name(obj)+"' object is not subscriptable");
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
            // A missing key raises KeyError, as in Python (round 75: it read
            // none). d.get(k, default), `k in d` and d?[k] are the graceful
            // forms.
            auto it=obj.map->find(vkey(idx));
            return it!=obj.map->end()?it->second:missing_key(idx);
        }
        if(obj.type==VMType::BYTES){
            const std::string& d=obj.bdata();
            if(idx.type==VMType::LIST&&idx.list&&!idx.b){
                int64_t st,step,n=slice_spec(*idx.list,(int64_t)d.size(),st,step);
                std::string out;
                if(step==1){ if(n>0) out=d.substr((size_t)st,(size_t)n); }
                else for(int64_t k=0,i=st;k<n;k++,i+=step) out+=d[(size_t)i];
                return VMVal::make_bytes(std::move(out),obj.b);
            }
            int64_t i=index_of(idx,obj.b?"bytearray":"byte"), sz=(int64_t)d.size();
            if(i<0) i+=sz;
            if(i<0||i>=sz) raise_native_exception("IndexError",obj.b?"bytearray index out of range":"index out of range");
            return VMVal::make_int((unsigned char)d[(size_t)i]);
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
        // none[k], 5[0], f[0]: TypeError (they read none).
        std::string msg="'"+vm_type_name(obj)+"' object is not subscriptable";
        if(nypy::lenient_reads_log()){ log_lenient_read("TypeError: "+msg); return VMVal::make_none(); }
        raise_native_exception("TypeError",msg);
        return VMVal::make_none();
    }
    // obj[idx] for d?[k]: false when the key or index does not exist - a
    // missing dict key, an index out of range, or __getitem__ raising
    // KeyError / IndexError. Other errors raise as obj[idx] does.
    bool try_get_sub(const VMVal& obj, const VMVal& idx, VMVal& out) {
        if(obj.type==VMType::MAP&&obj.map){
            auto it=obj.map->find(vkey(idx));
            if(it==obj.map->end()) return false;
            out=it->second; return true;
        }
        if(obj.type==VMType::LIST&&obj.list&&(idx.type==VMType::INT||idx.type==VMType::BOOL)){
            int64_t n=(int64_t)obj.list->size(), i=index_of(idx,"list");
            if(i<0) i+=n;
            if(i<0||i>=n) return false;
        }
        if(obj.type==VMType::STRING&&(idx.type==VMType::INT||idx.type==VMType::BOOL)){
            int64_t n=(int64_t)nypy::u8_len(obj.s), i=index_of(idx,"string");
            if(i<0) i+=n;
            if(i<0||i>=n) return false;
        }
        if(obj.type==VMType::BYTES&&(idx.type==VMType::INT||idx.type==VMType::BOOL)){
            int64_t n=(int64_t)obj.bdata().size(), i=index_of(idx,"byte");
            if(i<0) i+=n;
            if(i<0||i>=n) return false;
        }
        if(obj.type==VMType::INSTANCE){
            bool f=false;
            try { out=call_dunder_f(obj,"__getitem__",{idx},f); }
            catch(VMException& e){
                if(class_derives(e.value.class_name,"KeyError")||class_derives(e.value.class_name,"IndexError")) return false;
                throw;
            }
            if(f) return true;
            raise_native_exception("TypeError","'"+obj.class_name+"' object is not subscriptable");
        }
        out=get_sub(obj,idx);
        return true;
    }
    void set_sub(VMVal& obj, const VMVal& idx, VMVal val) {
        if(obj.is_set()) raise_native_exception("TypeError","'"+vm_type_name(obj)+"' object does not support item assignment");
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
        } else if(obj.type==VMType::BYTES) {
            if(!obj.b) raise_native_exception("TypeError","'bytes' object does not support item assignment");
            std::string& d=obj.bdata_mut();
            if(idx.type==VMType::LIST&&idx.list&&!idx.b){
                nypy::BArg ra=to_barg(val);
                if(ra.k==nypy::BArg::INT||ra.k==nypy::BArg::BOOL||ra.k==nypy::BArg::STR)
                    raise_native_exception("TypeError","can assign only bytes, buffers, or iterables of ints in range(0, 256)");
                std::string repl=ra.k==nypy::BArg::BYTES?ra.s:nycall([&]{
                    std::vector<nypy::BArg> one={ra};
                    return nypy::bytes_construct(one,"utf-8","strict",false,"bytearray"); });
                int64_t len=(int64_t)d.size(),st,step,n=slice_spec(*idx.list,len,st,step);
                if(step==1){
                    if(n<0) n=0;
                    if(st>len) st=len;
                    d.replace((size_t)st,(size_t)n,repl);
                } else {
                    if((int64_t)repl.size()!=n)
                        raise_native_exception("ValueError","attempt to assign bytes of size "+std::to_string(repl.size())+" to extended slice of size "+std::to_string(n));
                    for(int64_t k=0,i=st;k<n;k++,i+=step) d[(size_t)i]=repl[(size_t)k];
                }
                return;
            }
            int64_t i=index_of(idx,"bytearray"), sz=(int64_t)d.size();
            if(i<0) i+=sz;
            if(i<0||i>=sz) raise_native_exception("IndexError","bytearray index out of range");
            nypy::BArg b=to_barg(val);
            d[(size_t)i]=(char)nycall([&]{ return nypy::byte_of(b); });
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

    VMVal vm_call(VMVal callee, std::vector<VMVal>& args, std::optional<VMVal> self,
                  const VMVal* kwargs=nullptr) {
        if(callee.type==VMType::NONE||callee.type==VMType::UNDEFINED)
            return VMVal::make_none();
        // __call__: instance used as callable
        if(callee.type==VMType::INSTANCE){
            bool found=false;
            VMVal m;
            if(class_lookup(callee.class_name, "__call__", m)) return invoke_method(m, callee, args, callee.class_name, kwargs);
            (void)found;
            throw_exception(make_exception("TypeError",{VMVal::make_str("'"+callee.class_name+"' object is not callable")}));
        }
        // A method bound to its instance (obj.m read as a value), or a
        // classmethod bound to its class.
        if(callee.type==VMType::MAP&&(callee.class_name=="__bound_method__"||callee.class_name=="__super_bound__")&&callee.map){
            auto& bm=*callee.map;
            VMVal fn=bm.count("__fn__")?bm["__fn__"]:VMVal::make_none();
            VMVal sv=bm.count("__self__")?bm["__self__"]:VMVal::make_none();
            if(bm.count("__cls__")){
                std::vector<VMVal> a2; a2.reserve(args.size()+1);
                a2.push_back(sv); for(auto& x:args) a2.push_back(x);
                return fn.type==VMType::FUNCTION ? call_function(fn, a2, std::nullopt, kwargs) : vm_call(fn, a2, std::nullopt, kwargs);
            }
            if(fn.type==VMType::FUNCTION&&fn.code) return call_function(fn,args,sv,kwargs);
            return vm_call(fn,args,std::nullopt,kwargs);
        }
        // super(...): with no arguments the proxy itself; super(Class, obj)
        // Python's explicit form; any other arguments are Nython's shorthand
        // for calling the parent constructor, super(name, 4).
        if(callee.type==VMType::SUPER_PROXY){
            if(args.empty()) return callee;
            if(args.size()==2&&args[0].type==VMType::CLASS){
                VMVal proxy=callee;
                proxy.s=args[0].class_name;
                proxy.list=std::make_shared<std::vector<VMVal>>(); vmgc::track_list(proxy.list);
                proxy.list->push_back(args[1]);
                return proxy;
            }
            return vm_call_method(callee, "__init__", args, kwargs);
        }
        if(callee.type==VMType::NATIVE){
            if(kwargs && kwargs->type==VMType::MAP && kwargs->map && !kwargs->map->empty()){
                // Natives take the keywords as a trailing map marked
                // "__kwargs__" (take_kwargs; the builtin bridge forwards it as
                // the map nyos::Args reads), so a positional dict is not
                // taken for it.
                std::vector<VMVal> a2=args; a2.push_back(*kwargs);
                a2.back().class_name="__kwargs__";
                return callee.native(a2);
            }
            return callee.native(args);
        }
        if(callee.type==VMType::FUNCTION&&callee.code){
            // Class.method taken as a value and called with the instance
            // first: f = Animal.speak; f(dog).
            if(!self && callee.code->is_method && !callee.code->is_static && !args.empty()
               ){
                // any first argument is self (Props.x.fget(None), as Python)
                VMVal self_val = args[0];
                std::vector<VMVal> rest(args.begin()+1, args.end());
                return call_function(callee, rest, self_val, kwargs);
            }
            return call_function(callee,args,self,kwargs);
        }
        if(callee.type==VMType::CLASS&&callee.code) return instantiate(callee, args, kwargs);
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
        // (255).__format__("x"), "ab".__format__(">4"): format(obj, spec) (round 77)
        if(m=="__format__"){
            if(args.size()!=1||args[0].type!=VMType::STRING)
                raise_native_exception("TypeError",vm_type_name(obj)+".__format__() argument must be str");
            out=VMVal::make_str(format_value(obj,args[0].s)); return true;
        }
        return false;
    }

    VMVal vm_call_method(VMVal obj, const std::string& method, std::vector<VMVal>& args,
                         const VMVal* kwargs=nullptr) {
        // Generator protocol (round 75): send(v) resumes with v as the value
        // of the paused yield; throw(e) raises e there; close() raises
        // GeneratorExit there, so finally blocks run; __next__; __iter__.
        if(obj.type==VMType::GENERATOR&&obj.gen){
            std::shared_ptr<GenState> gsp=obj.gen;
            GenState& gs=*gsp;
            // A lazy zip/map/... is an iterator: no send or throw (send()
            // used to behave as next()).
            if(gs.native && (method=="send"||method=="throw"))
                throw_exception(make_exception("AttributeError",{VMVal::make_str("'"+gs.name+"' object has no attribute '"+method+"'")}));
            if(method=="send"||method=="__next__"||method=="next"){
                if(method=="send" && args.size()!=1)
                    throw_exception(make_exception("TypeError",{VMVal::make_str("generator.send() takes exactly one argument ("+std::to_string(args.size())+" given)")}));
                VMVal sent = method=="send" ? args[0] : VMVal::make_none();
                if(method=="send" && !gs.started && sent.type!=VMType::NONE)
                    throw_exception(make_exception("TypeError",{VMVal::make_str("can't send non-None value to a just-started generator")}));
                VMVal v;
                if(gen_resume(gs,0,sent,v)) return v;
                gen_raise_stop(gs);
            }
            if(method=="throw"){
                VMVal ev=gen_throw_value(args);
                VMVal v;
                if(gen_resume(gs,1,ev,v)) return v;
                gen_raise_stop(gs);
            }
            if(method=="close"){ gen_close(gs); return VMVal::make_none(); }
            if(method=="__iter__") return obj;
            VMVal pm;
            if(primitive_member(obj,method,args,pm)) return pm;
            throw_exception(make_exception("AttributeError",{VMVal::make_str("'generator' object has no attribute '"+method+"'")}));
        }
        // A value stored as an attribute of a function: f.cache_info(),
        // f.register(int). It was looked for as a method of the function and
        // not found (AttributeError), though reading it worked.
        if(obj.type==VMType::FUNCTION&&obj.code&&!func_attrs_.empty()){
            auto fa=func_attrs_.find(func_key(obj));
            if(fa!=func_attrs_.end()){
                auto it=fa->second.find(method);
                if(it!=fa->second.end()){ VMVal target=it->second; return vm_call(target,args,std::nullopt,kwargs); }
            }
        }
        {
            VMVal pm;
            if(primitive_member(obj,method,args,pm)) return pm;
        }
        // super().m(...): m from the class after the defining one in
        // type(self)'s MRO, bound to self.
        if(obj.type==VMType::SUPER_PROXY){
            std::string owner=obj.s;
            VMVal self_v=(!obj.list||obj.list->empty())?VMVal::make_none():(*obj.list)[0];
            std::string mro_of = self_v.type==VMType::INSTANCE ? self_v.class_name : owner;
            VMVal m; std::string where;
            // past a metaclass's own bases is type: type.__new__ / __call__
            // / __init__ (round 77)
            if((method=="__new__"||method=="__call__"||method=="__init__")&&class_derives(owner,"type")){
                bool own=class_lookup(mro_of, method, m, &where, &owner)&&nyrt::shown_class_name(where)!="object";
                if(!own){
                    if(method=="__init__") return VMVal::make_none();
                    if(method=="__new__") return type_new(args, kwargs);
                    type_call_skip_=true;
                    return instantiate(self_v, args, kwargs);
                }
            }
            if(class_lookup(mro_of, method, m, &where, &owner))
                return invoke_method(m, self_v, args, mro_of, kwargs);
            // The constructor goes by either name (init / __init__).
            if(is_ctor_name(method)){
                std::string other = method=="init" ? "__init__" : "init";
                if(class_lookup(mro_of, other, m, &where, &owner))
                    return invoke_method(m, self_v, args, mro_of, kwargs);
            }
            if(is_ctor_name(method)){
                // super().__init__(...) reaching a builtin exception class
                // sets the exception's args; reaching object, nothing.
                if(self_v.type==VMType::INSTANCE && self_v.map && is_exception_class(mro_of)){
                    set_exc_args(*self_v.map, self_v.class_name, args);   // and the fields (round 77)
                }
                return VMVal::make_none();
            }
            // past the last base is object, every class's implicit root
            // (super().__setattr__(k, v) ...); otherwise AttributeError, as
            // Python (it returned none)
            if(class_lookup("object", method, m)) return invoke_method(m, self_v, args, "object", kwargs);
            throw_exception(make_exception("AttributeError",{VMVal::make_str("'super' object has no attribute '"+method+"'")}));
        }
        if((obj.type==VMType::INSTANCE||obj.type==VMType::MAP)&&obj.map){
            auto it=obj.map->find(method);
            if(it!=obj.map->end()){
                VMVal& held=it->second;
                // A callable stored in an attribute, e.g. self.cb = other.method
                // then self.cb(a, b). A bound method carries its own instance,
                // so it must go through vm_call rather than being re-bound to
                // the object that happens to hold it; natives take no self at
                // all. A bare FUNCTION is not bound either (as in Python and
                // the interpreter, round 77): a nested def that uses its
                // enclosing method's self saw the holder as self instead.
                if(held.type==VMType::MAP&&held.class_name=="__bound_method__")
                    return vm_call(held,args,std::nullopt,kwargs);
                if(held.type==VMType::NATIVE)
                    return vm_call(held,args,std::nullopt,kwargs);
                if(held.type==VMType::FUNCTION)
                    // A function stored in an attribute is called with its
                    // own closure and defaults (a closure stored as obj.cb
                    // and called obj.cb() used to lose its captured values),
                    // through vm_call: a method taken from its class gets
                    // its instance from the first argument there
                    // (cached_property's self.func(instance) raised "takes
                    // 0 positional arguments").
                    return vm_call(held,args,std::nullopt,kwargs);
                if(held.type==VMType::CLASS||held.type==VMType::INSTANCE)
                    return vm_call(held,args,std::nullopt,kwargs);
            }
        }
        if(obj.type==VMType::INSTANCE){
            VMVal m;
            if(class_lookup(obj.class_name, method, m)) return invoke_method(m, obj, args, obj.class_name, kwargs);
            // obj[i:j:k] (spelt obj.slice(i, j, k)): __getitem__ gets a slice
            if(method=="slice"&&class_lookup(obj.class_name,"__getitem__",m)){
                VMVal spec=VMVal::make_list(std::vector<VMVal>(args.begin(),args.end()));
                std::vector<VMVal> ga{make_slice_object(spec)};
                return invoke_method(m, obj, ga, obj.class_name);
            }
            // __getattr__ supplies attributes that do not exist otherwise.
            {
                VMVal ga;
                if(class_lookup(obj.class_name, "__getattr__", ga)){
                    std::vector<VMVal> ga_args{VMVal::make_str(method)};
                    VMVal target=invoke_method(ga, obj, ga_args, obj.class_name);
                    return vm_call(target, args, std::nullopt, kwargs);
                }
            }
            // Universal object protocol — mirrors NythonExecutor::objectProtocol
            // on the interpreter (see test_25_object_protocol.ny, which probes
            // for support and skipped here because the VM had none of this).
            // Only reached once no user-defined method/attribute of this name
            // was found above, so a class's own to_string/class_name etc, if
            // it defines one, still wins.
            // self.__class__(...): a new instance of the object's class
            if(method=="__class__") return vm_call(class_value(obj.class_name), args, std::nullopt, kwargs);
            if(method=="class_name"||method=="type_name")
                return VMVal::make_str(nyrt::shown_class_name(obj.class_name));
            if(method=="to_string"||method=="str")
                return VMVal::make_str("<"+nyrt::shown_class_name(obj.class_name)+" instance>");
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
                std::string want = args[0].type==VMType::CLASS ? args[0].class_name : args[0].to_string();
                return VMVal::make_bool(class_derives(obj.class_name, want));
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
            // No such method: AttributeError (the call returned none, which
            // hid misspelt method names).
            throw_exception(make_exception("AttributeError",{VMVal::make_str(
                "'"+nyrt::shown_class_name(obj.class_name)+"' object has no attribute '"+method+"'")}));
        }
        // Class.method(...): a static method or a Nython method without self
        // takes the arguments as they are, a classmethod gets the class, and
        // a method with self takes it from the first argument
        // (Animal.__init__(self, name)).
        if(obj.type==VMType::CLASS&&obj.code){
            VMVal m;
            if(class_lookup(obj.class_name, method, m)){
                if(m.type==VMType::FUNCTION&&m.code){
                    if(m.code->is_classmethod) return invoke_method(m, obj, args, obj.class_name, kwargs);
                    if(m.code->is_static||!m.code->is_method) return call_function(m, args, std::nullopt, kwargs);
                    if(!args.empty()){
                        VMVal self_val=args[0];
                        std::vector<VMVal> rest(args.begin()+1,args.end());
                        return call_function(m, rest, self_val, kwargs);
                    }
                    return call_function(m, args, std::nullopt, kwargs);
                }
                return vm_call(m, args, std::nullopt, kwargs);
            }
            // Exception.__init__(self, msg) on a builtin exception class.
            if(is_ctor_name(method) && !args.empty() && args[0].type==VMType::INSTANCE && args[0].map
               && is_exception_class(obj.class_name)){
                std::vector<VMVal> rest(args.begin()+1,args.end());
                set_exc_args(*args[0].map, args[0].class_name, rest);   // and the fields (round 77)
                return VMVal::make_none();
            }
            // a method of the class's metaclass, or anything else the
            // metaclass gives the class (round 77)
            if(!class_meta_.empty()&&!is_ctor_name(method)){
                VMVal mm;
                if(meta_member(obj, method, mm)){
                    if(mm.type==VMType::FUNCTION&&mm.code&&mm.code->is_static) return call_function(mm, args, std::nullopt, kwargs);
                    return call_with_first(mm, obj, args, kwargs);
                }
                VMVal target;
                if(lookup_attr(obj, method, target)) return vm_call(target, args, std::nullopt, kwargs);
            }
            if(!is_ctor_name(method) && class_reg_.count(obj.class_name))
                throw_exception(make_exception("AttributeError",{VMVal::make_str(
                    "type object '"+obj.class_name+"' has no attribute '"+method+"'")}));
        }
        // str/list/dict methods and natives take keywords as a trailing map
        // marked "__kwargs__" (take_kwargs): L.sort(reverse=true),
        // "{n}".format(n=1).
        auto with_kw=[&]()->std::vector<VMVal>&{
            if(kwargs && kwargs->type==VMType::MAP && kwargs->map && !kwargs->map->empty()){
                args.push_back(*kwargs); args.back().class_name="__kwargs__";
            }
            return args;
        };
        if(obj.type==VMType::STRING) return call_str_method(obj,method,with_kw());
        if(obj.type==VMType::BYTES)  return call_bytes_method(obj,method,args,kwargs);
        if(obj.type==VMType::INT||obj.type==VMType::BOOL||obj.type==VMType::FLOAT){
            VMVal r;
            if(number_method(obj,method,args,kwargs,r)) return r;
        }
        if(obj.type==VMType::LIST)   return call_list_method(obj,method,with_kw());
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
                        return vm_call(member,args,std::nullopt,kwargs);
                }
            }
            return call_map_method(obj,method,with_kw());
        }
        // CLASS type: support nested class instantiation via CALL_METHOD (e.g. Outer.Inner(v))
        if(obj.type==VMType::CLASS){
            VMVal nested;
            lookup_attr(obj, method, nested, false);
            if(nested.type == VMType::CLASS) return vm_call(nested, args, std::nullopt, kwargs);
            // Static method call
            if(nested.type == VMType::FUNCTION && nested.code)
                return exec_code(nested.code, args, VMVal::make_none(), nullptr, nullptr, kwargs);
        }
        // A builtin used as a namespace: `import time` then time.time(),
        // time.sleep(1), time.monotonic() - the builtin time_X, else X.
        if(obj.type==VMType::NATIVE&&!native_type_base(obj).empty()&&nypy::type_has_member(native_type_base(obj),method))
            return type_member_call(native_type_base(obj),method,args,kwargs);
        if(obj.type==VMType::NATIVE&&obj.class_name.rfind("__builtin__:",0)==0){
            std::string target=nyrt::builtin_member(obj.class_name.substr(12),method,
                [&](const std::string& n){ return bridge_exists()&&bridge_exists()(n); });
            if(!target.empty()){
                VMVal fn=load_var(target);
                if(fn.type==VMType::NATIVE) return fn.native(with_kw());
            }
            return missing_attr(obj, method);
        }
        // Nothing else has methods: none.m(), 5.m(), f.m() raise
        // AttributeError (they returned none, or called a global native of
        // that name with the receiver dropped). x?.m() is the graceful form.
        return missing_attr(obj, method);
    }

    // The builtin type a native stands for ("int" for int, "dict" for dict ...),
    // "" for any other native.
    static std::string native_type_base(const VMVal& f) {
        if(f.type!=VMType::NATIVE) return std::string();
        const std::string& c=f.class_name;
        std::string b=c.rfind("__builtin__:",0)==0?c.substr(12):c;
        if(b=="map") b="dict";
        static const std::unordered_set<std::string> types={"int","float","bool","str","list","tuple","dict","bytes","bytearray"};
        return types.count(b)?b:std::string();
    }
    // A keyword argument from a kwargs map, else the positional one at pos.
    static const VMVal* kw_or_pos(const VMVal* kw, const char* name, std::vector<VMVal>& a, size_t pos) {
        if(kw&&kw->type==VMType::MAP&&kw->map){
            auto it=kw->map->find(nypy::key_of_str(name));
            if(it!=kw->map->end()) return &it->second;
        }
        return pos<a.size()?&a[pos]:nullptr;
    }
    // bytes / bytearray methods (NyBytes.hpp: bytes_method).
    VMVal call_bytes_method(VMVal obj, const std::string& m, std::vector<VMVal>& args_in, const VMVal* kw) {
        std::vector<VMVal> a=args_in;
        if(kw&&kw->type==VMType::MAP&&kw->map&&!kw->map->empty()){
            static const std::unordered_map<std::string,std::vector<const char*>> slots={
                {"decode",{"encoding","errors"}},{"hex",{"sep","bytes_per_sep"}},
                {"split",{"sep","maxsplit"}},{"rsplit",{"sep","maxsplit"}},
                {"splitlines",{"keepends"}},{"translate",{"table","delete"}},
                {"count",{"sub","start","end"}},{"replace",{"old","new","count"}}};
            auto it=slots.find(m);
            for(auto& kv:*kw->map){
                if(vm_internal_key(kv.first)) continue;
                std::string k=nypy::key_payload(kv.first);
                size_t pos=SIZE_MAX;
                if(it!=slots.end()) for(size_t q=0;q<it->second.size();q++) if(k==it->second[q]) pos=q;
                if(pos==SIZE_MAX) raise_native_exception("TypeError",m+"() got an unexpected keyword argument '"+k+"'");
                if(a.size()<=pos) a.resize(pos+1,VMVal::make_none());
                a[pos]=kv.second;
            }
        }
        if(m=="fromhex"){
            if(a.size()!=1||a[0].type!=VMType::STRING) raise_native_exception("TypeError","fromhex() argument must be str");
            return VMVal::make_bytes(nycall([&]{ return nypy::bytes_fromhex(a[0].s); }),obj.b);
        }
        if(m=="slice"){
            // b[a:b:c] spelled as a call (the parser's form for slices)
            const std::string& d=obj.bdata();
            int64_t st,step,n=slice_spec(a,(int64_t)d.size(),st,step);
            std::string out;
            if(step==1){ if(n>0) out=d.substr((size_t)st,(size_t)n); }
            else for(int64_t k=0,i=st;k<n;k++,i+=step) out+=d[(size_t)i];
            return VMVal::make_bytes(std::move(out),obj.b);
        }
        std::vector<nypy::BArg> ba; ba.reserve(a.size());
        for(auto& v:a) ba.push_back(to_barg(v));
        nypy::BRes r;
        std::string& data=obj.bdata_mut();
        if(nycall([&]{ return nypy::bytes_method(data,obj.b,m,ba,r); })) return from_bres(r);
        if(m=="class_name"||m=="type_name") return VMVal::make_str(vm_type_name(obj));
        if(m=="to_string"||m=="str") return VMVal::make_str(obj.to_string());
        return missing_attr(obj,m);
    }
    // int / float methods (round 77; NyBytes.hpp).
    bool number_method(const VMVal& obj, const std::string& m, std::vector<VMVal>& a, const VMVal* kw, VMVal& out) {
        bool isint=obj.type==VMType::INT||obj.type==VMType::BOOL;
        if(isint&&!nypy::int_methods().count(m)) return false;
        if(!isint&&!nypy::float_methods().count(m)) return false;
        if(isint){
            nypy::BigInt v;
            if(obj.type==VMType::BOOL) v=nypy::BigInt(obj.b?1:0);
            else if(obj.s.empty()) v=nypy::BigInt(obj.i);
            else nypy::BigInt::parse(obj.s,10,v);
            if(m=="bit_length"){ out=VMVal::make_int(nypy::big_bit_length(v)); return true; }
            if(m=="bit_count"){ out=VMVal::make_int(nypy::big_bit_count(v)); return true; }
            if(m=="conjugate"){ out=VMVal::make_bigint(v); return true; }
            if(m=="is_integer"){ out=VMVal::make_bool(true); return true; }
            if(m=="as_integer_ratio"){ out=VMVal::make_tuple({VMVal::make_bigint(v),VMVal::make_int(1)}); return true; }
            if(m=="to_bytes"){
                const VMVal* lv=kw_or_pos(kw,"length",a,0);
                int64_t len=1;
                if(lv){ if(lv->type!=VMType::INT) raise_native_exception("TypeError","length must be an int"); len=lv->i; }
                const VMVal* bo=kw_or_pos(kw,"byteorder",a,1);
                std::string order=bo?vm_str(*bo):std::string("big");
                if(order!="big"&&order!="little") raise_native_exception("ValueError","byteorder must be either 'little' or 'big'");
                const VMVal* sg=kw_or_pos(kw,"signed",a,99);
                bool sgn=sg&&vm_truthy(*sg);
                out=VMVal::make_bytes(nycall([&]{ return nypy::int_to_bytes(v,len,order=="little",sgn); }));
                return true;
            }
            return false;
        }
        double d=obj.d;
        if(m=="is_integer"){ out=VMVal::make_bool(std::isfinite(d)&&d==std::floor(d)); return true; }
        if(m=="hex"){ out=VMVal::make_str(nypy::float_hex(d)); return true; }
        if(m=="conjugate"){ out=obj; return true; }
        if(m=="as_integer_ratio"){
            nypy::BigInt n,dd;
            nycall([&]{ nypy::float_ratio(d,n,dd); return 0; });
            out=VMVal::make_tuple({VMVal::make_bigint(n),VMVal::make_bigint(dd)});
            return true;
        }
        return false;
    }
    // `T.m(...)` for a builtin type T (round 77), as the interpreter's
    // typeMemberCall.
    VMVal type_member_call(const std::string& t, const std::string& m, std::vector<VMVal>& a, const VMVal* kw) {
        if(nypy::type_classmethod(t,m)){
            if(m=="from_bytes"){
                const VMVal* b=kw_or_pos(kw,"bytes",a,0);
                if(!b) raise_native_exception("TypeError","from_bytes() missing required argument 'bytes' (pos 1)");
                nypy::BArg ba=to_barg(*b);
                std::string data=ba.k==nypy::BArg::BYTES?ba.s:nycall([&]{
                    std::vector<nypy::BArg> one={ba};
                    return nypy::bytes_construct(one,"utf-8","strict",false,"bytes"); });
                const VMVal* bo=kw_or_pos(kw,"byteorder",a,1);
                std::string order=bo?vm_str(*bo):std::string("big");
                if(order!="big"&&order!="little") raise_native_exception("ValueError","byteorder must be either 'little' or 'big'");
                const VMVal* sg=kw_or_pos(kw,"signed",a,99);
                bool sgn=sg&&vm_truthy(*sg);
                return VMVal::make_bigint(nycall([&]{ return nypy::int_from_bytes(data,order=="little",sgn); }));
            }
            if(m=="fromhex"){
                if(a.size()!=1||a[0].type!=VMType::STRING) raise_native_exception("TypeError","fromhex() argument must be str");
                if(t=="float") return VMVal::make_float(std::strtod(a[0].s.c_str(),nullptr));
                return VMVal::make_bytes(nycall([&]{ return nypy::bytes_fromhex(a[0].s); }),t=="bytearray");
            }
            if(m=="maketrans"){
                if(a.size()!=2||a[0].type!=VMType::BYTES||a[1].type!=VMType::BYTES) raise_native_exception("TypeError","maketrans expected 2 bytes-like arguments");
                const std::string& x=a[0].bdata(); const std::string& y=a[1].bdata();
                if(x.size()!=y.size()) raise_native_exception("ValueError","maketrans arguments must have same length");
                std::string table(256,'\0');
                for(int k=0;k<256;k++) table[(size_t)k]=(char)k;
                for(size_t k=0;k<x.size();k++) table[(unsigned char)x[k]]=y[k];
                return VMVal::make_bytes(table);
            }
            if(m=="fromkeys"){
                if(a.empty()) raise_native_exception("TypeError","fromkeys expected at least 1 argument, got 0");
                VMVal v=a.size()>=2?a[1]:VMVal::make_none();
                VMVal d=VMVal::make_map();
                for(auto& k:iter_items(a[0])) (*d.map)[vkey(k)]=v;
                return d;
            }
        }
        if(a.empty()) raise_native_exception("TypeError","unbound method "+t+"."+m+"() needs an argument");
        std::string have=vm_type_name(a[0]);
        if(!(have==t||(t=="int"&&have=="bool")))
            raise_native_exception("TypeError","descriptor '"+m+"' for '"+t+"' objects doesn't apply to a '"+have+"' object");
        VMVal self=a[0];
        std::vector<VMVal> rest(a.begin()+1,a.end());
        return vm_call_method(self,m,rest,kw);
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
                throw_exception(make_exception("KeyError",{a[0]}));   // the key itself (round 77)
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
        return missing_attr(obj,m);
    }


    // ── Import system ───────────────────────────────────────────────────────
    // Modules imported by name, their namespaces (vm_import).
    std::unordered_map<std::string, VMVal> module_ns_;

    static void tag_module_code(const std::shared_ptr<VMCode>& c, const std::shared_ptr<VMMap>& env) {
        if(!c || c->module_env==env) return;
        c->module_env=env;
        for(auto& s:c->sub_codes) tag_module_code(s, env);
        for(auto& k:c->constants) if(k.code) tag_module_code(k.code, env);
    }
    // `from m import a, b` / `*` (see the interpreter's bindFromNamespace).
    void bind_from_namespace(const VMVal& nsv, const std::vector<std::string>& names, const std::string& module_name) {
        if(nsv.type!=VMType::MAP || !nsv.map)
            throw_exception(make_exception("ImportError",{VMVal::make_str("cannot import from \""+module_name+"\"")}));
        auto& ns=*nsv.map;
        if(names.size()==1 && names[0]=="*"){
            auto all=ns.find("__all__");
            if(all!=ns.end()){
                std::vector<VMVal> items=iter_items(all->second);
                for(auto& nm:items){
                    std::string k=nm.type==VMType::STRING?nm.s:nm.to_string();
                    auto hit=ns.find(k);
                    if(hit==ns.end())
                        throw_exception(make_exception("AttributeError",{VMVal::make_str("module '"+module_name+"' has no attribute '"+k+"'")}));
                    define_var(k, hit->second);
                }
                return;
            }
            for(auto& kv:ns) if(!kv.first.empty() && kv.first[0]!='_') define_var(kv.first, kv.second);
            return;
        }
        for(auto& entry:names){
            auto [n, bound]=nyrt::import_name_alias(entry);
            auto hit=ns.find(n);
            if(hit==ns.end())
                throw_exception(make_exception("ImportError",{VMVal::make_str("cannot import name '"+n+"' from '"+module_name+"'")}));
            define_var(bound, hit->second);
        }
    }
    // `import m` / `import m as x` / `from m import ...` of a module file
    // named without quotes (round 77; NythonExecutor::importModule is the
    // interpreter's): the module runs once in a scope of its own
    // (VMCode::module_env), and the importer binds only its namespace - the
    // module scope as it was when the module finished - or the names asked
    // for. A quoted import still includes the file (export_to_globals_).
    // ── packages (round 77; NythonExecutor's findModulePath/importDotted)
    std::vector<std::string> module_dirs() {
        std::vector<std::string> dirs;
        if(!script_dir_.empty()){ dirs.push_back(script_dir_); dirs.push_back(script_dir_+"lib/"); }
        for(const char* d:{"","./","lib/","./lib/"}) dirs.push_back(d);
        dirs.push_back(cwd_+"/"); dirs.push_back(cwd_+"/lib/");
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
            dirs.push_back(d); dirs.push_back(d+"lib/");
        }
        for(auto& ld:nyrt::library_dirs()) dirs.push_back(ld);
        return dirs;
    }
    // Whether a directory can be a namespace package: it holds a .ny file or
    // a folder that does (platform_compat.hpp's ny_fs::holds_modules).
    static bool holds_modules(const std::string& dir, int depth=1) { return ny_fs::holds_modules(dir, depth); }
    std::string find_module_path(const std::string& dotted, bool* is_dir=nullptr) {
        std::string rel=dotted;
        std::replace(rel.begin(),rel.end(),'.','/');
        struct stat st;
        auto dirs=module_dirs();
        for(auto& d:dirs){
            if(::stat((d+rel+".ny").c_str(),&st)==0 && !S_ISDIR(st.st_mode)) return d+rel+".ny";
            if(::stat((d+rel+"/__init__.ny").c_str(),&st)==0) return d+rel+"/__init__.ny";
        }
        if(is_dir) for(auto& d:dirs){
            std::string p=d.empty()?rel:d+rel;
            if(::stat(p.c_str(),&st)==0 && S_ISDIR(st.st_mode) && holds_modules(p)){ *is_dir=true; return p; }
        }
        return std::string();
    }
    bool is_package_name(const std::string& name) {
        bool dir=false;
        std::string p=find_module_path(name,&dir);
        return dir || (p.size()>12 && p.compare(p.size()-12,12,"/__init__.ny")==0);
    }
    VMVal load_module(const std::string& dotted) {
        auto it=module_ns_.find(dotted);
        if(it!=module_ns_.end()) return it->second;
        bool dir=false;
        std::string path=find_module_path(dotted,&dir);
        if(path.empty()) throw_exception(make_exception("ModuleNotFoundError",{VMVal::make_str("No module named '"+dotted+"'")}));
        if(dir){
            auto nsmap=std::make_shared<VMMap>(); vmgc::track_map(nsmap);
            (*nsmap)["__name__"]=VMVal::make_str(dotted);
            VMVal nsv=VMVal::make_map(); nsv.map=nsmap; nsv.class_name=dotted;
            module_ns_[dotted]=nsv;
            return nsv;
        }
        return load_module_file(path, dotted);
    }
    void import_dotted(const std::string& name, const std::string& alias, const std::vector<std::string>& from_names, bool explicit_alias) {
        std::vector<std::string> parts;
        size_t a=0;
        while(a<=name.size()){
            size_t b=name.find('.',a);
            if(b==std::string::npos) b=name.size();
            parts.push_back(name.substr(a,b-a));
            a=b+1;
        }
        VMVal first, prev;
        std::string prefix;
        for(size_t i=0;i<parts.size();i++){
            prefix=i?prefix+"."+parts[i]:parts[i];
            VMVal ns=load_module(prefix);
            if(i==0) first=ns;
            else if(prev.type==VMType::MAP&&prev.map) (*prev.map)[parts[i]]=ns;
            prev=ns;
        }
        if(!from_names.empty()){
            for(auto& entry:from_names){
                std::string n=nyrt::import_name_alias(entry).first;
                if(n=="*"||!prev.map||prev.map->count(n)) continue;
                bool dir=false;
                if(!find_module_path(name+"."+n,&dir).empty()) (*prev.map)[n]=load_module(name+"."+n);
            }
            bind_from_namespace(prev, from_names, name);
        } else if(explicit_alias) define_var(alias, prev);
        else define_var(parts[0], first);
    }
    void import_module(const std::string& filepath, const std::string& name, const std::string& bind_as,
                       const std::vector<std::string>& from_names) {
        VMVal nsv=load_module_file(filepath, name);
        if(!from_names.empty()) bind_from_namespace(nsv, from_names, name);
        else if(!bind_as.empty()) define_var(bind_as, nsv);
    }
    VMVal load_module_file(const std::string& filepath, const std::string& name) {
        auto source=nython::reader::SourceCode(filepath);
        auto reporter=std::make_shared<nython::exception::Reporter>(source);
        auto lx=std::make_shared<nython::lexer::Lexer>(source);
        lx->tokenize();
        auto pr=std::make_shared<nython::parser::Parser>(reporter.get(),(nython::Runnable*)this,lx.get());
        auto ast=pr->parse();
        if(!ast) throw_exception(make_exception("ImportError",{VMVal::make_str("cannot import \""+filepath+"\"")}));
        nython::scope::qualify_module_classes(ast, name);
        prelude_asts_.push_back(ast);    // kept alive with the code
        Compiler c; auto code=c.compile(ast);
        auto env=std::make_shared<VMMap>(); vmgc::track_map(env);
        (*env)["__name__"]=VMVal::make_str(name);
        (*env)["__file__"]=VMVal::make_str(filepath);
        tag_module_code(code, env);
        code->module_top=true;
        // Registered before the module runs, so a circular import binds it.
        auto nsmap=std::make_shared<VMMap>(); vmgc::track_map(nsmap);
        VMVal nsv=VMVal::make_map(); nsv.map=nsmap; nsv.class_name=name;
        module_ns_[name]=nsv;
        bool old_exp=export_to_globals_; int old_depth=export_depth_;
        export_to_globals_=false; export_depth_=-1;
        struct Restore { VirtualMachine* vm; bool e; int d;
            ~Restore(){ vm->export_to_globals_=e; vm->export_depth_=d; } } restore{this, old_exp, old_depth};
        try{ exec_code(code,{},std::nullopt); }
        catch(VMReturn&){}
        catch(...){ module_ns_.erase(name); globals_.erase("__imported_"+name); throw; }
        for(auto& kv:*env) (*nsmap)[kv.first]=kv.second;
        for(auto& sub:code->sub_codes) if(sub->is_class&&!class_reg_.count(sub->name)) class_reg_[sub->name]=sub;   // keep the class MAKE_CLASS made (a copy for metaclass= / expression bases), round 77
        return nsv;
    }
    void vm_import(const std::string& raw_name_in) {
        std::string tried_paths;
        // Split the alias the compiler appended, if any.
        std::string raw_name = raw_name_in;
        std::string alias;
        bool implicit=false;
        bool bare=false;
        if(!raw_name.empty() && raw_name[0]=='\x02'){ bare=true; raw_name=raw_name.substr(1); }
        std::vector<std::string> from_names;
        {
            size_t fp=raw_name.find('\x04');
            if(fp!=std::string::npos){
                std::string lst=raw_name.substr(fp+1);
                raw_name=raw_name.substr(0,fp);
                size_t a=0;
                while(a<=lst.size()){
                    size_t b=lst.find(',',a);
                    if(b==std::string::npos) b=lst.size();
                    if(b>a) from_names.push_back(lst.substr(a,b-a));
                    a=b+1;
                }
            }
        }
        size_t sep = raw_name.find('\x01');
        if(sep != std::string::npos){
            alias = raw_name.substr(sep + 1);
            raw_name = raw_name.substr(0, sep);
        } else if((sep=raw_name.find('\x03'))!=std::string::npos){
            // `import name`: binds name to the module's namespace (round 77)
            alias = raw_name.substr(sep + 1);
            raw_name = raw_name.substr(0, sep);
            implicit = true;
        }
        std::string name = raw_name;
        if(name.size()>=2&&(name[0]=='"'||name[0]=='\'')){
            name=name.substr(1,name.size()-2);
        }
        std::string guard_key = "__imported_"+name;
        {
            // a module runs once: a later import (named or aliased) binds the
            // namespace its first import made
            // a.b.c, and packages (directories of modules), before the
            // builtin module names (lib/http/ is a package)
            if(bare && (name.find('.')!=std::string::npos || is_package_name(name))){
                bool explicit_alias=raw_name_in.find('\x01')!=std::string::npos;
                import_dotted(name, alias, from_names, explicit_alias);
                return;
            }
            // `import threading` / `json` / `re` / ... binds the Python module
            // in lib/ when there is one (nyrt::prefers_lib_module)
            if(bare && nyrt::prefers_lib_module(name)){
                std::string p=find_module_path(name);
                if(!p.empty()){
                    VMVal nsv=module_ns_.count(name)?module_ns_[name]:load_module_file(p,name);
                    if(!from_names.empty()) bind_from_namespace(nsv, from_names, name);
                    else define_var(alias.empty()?name:alias, nsv);
                    return;
                }
            }
            auto mc=module_ns_.find(name);
            if(bare && mc!=module_ns_.end()){
                if(!from_names.empty()) bind_from_namespace(mc->second, from_names, name);
                else if(!alias.empty()) define_var(alias, mc->second);
                return;
            }
            if(!alias.empty()&&mc!=module_ns_.end()){ globals_[alias]=mc->second; return; }
            if(implicit&&globals_.count(guard_key)) return;
        }
        // from sys import x after sys was imported: from the one sys namespace
        if(name=="sys"&&!from_names.empty()&&sys_ns_.type==VMType::MAP&&sys_ns_.map){
            bind_from_namespace(sys_ns_, from_names, "sys");
            return;
        }
        // An aliased import must still run so its namespace can be built, even
        // if the module was already loaded — otherwise the name diff sees
        // nothing and the alias is empty. Matches the interpreter.
        if(globals_.count(guard_key) && alias.empty()) return;
        globals_[guard_key] = VMVal::make_bool(true);
        // The tensor natives (register_nytorch_builtins) are registered when
        // the VM starts (register_all_builtins). Registering them again here
        // put back that block's older copies of 171 general builtins over
        // the ones registered after it - repr, ord, chr, sorted, sum, set,
        // list, the GIL-aware sleeps, ... - so on the VM any program that
        // imported nytorch (lib/aiagent.ny does) got repr("a\nb") unescaped,
        // among others. An acknowledgement now (round 76).
        if(name=="nytorch") return;
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
        // (its natives are registered at start-up, as for `import nytorch`)
        // os/shell/time/io: their functions are the interpreter's, reached
        // through the builtin bridge - one implementation for both engines.
        // These imports used to install VM copies that differed (time_ms()
        // in seconds, sleep(0.5) not sleeping, shell() returning a wait
        // status); now they are acknowledgements only.
        if(name=="os"){ define_os_module(alias.empty()?std::string("os"):alias); return; }
        if(name=="shell"||name=="sh"){ return; }
        if(name=="sys"){
            define_sys_module(alias.empty()?std::string("sys"):alias);
            // from sys import stdout, maxsize: the one sys namespace's
            if(!from_names.empty()) bind_from_namespace(sys_ns_, from_names, "sys");
            return;
        }
        if(name=="math"){
            // `from math import gcd` bound nothing (NameError); the namespace
            // is cached so later imports, from any module, bind it
            register_math_builtins();
            VMVal mns=define_math_module(alias.empty()?std::string("math"):alias);
            module_ns_["math"]=mns;
            if(!from_names.empty()) bind_from_namespace(mns, from_names, "math");
            return;
        }
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
            "random","crypto","datetime","hash","http","re","regex",
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
            for(auto& d:nyrt::library_dirs()) paths.push_back(d+name+".ny");
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
        // A module named without quotes runs in a scope of its own.
        if(bare && it==lib_map.end()){
            import_module(filepath, name, alias, from_names);
            return;
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
            int old_depth=export_depth_; export_depth_=(int)call_stack_.size()+1;
            struct ExportRestore { VirtualMachine* vm; bool e; int d;
                ~ExportRestore(){ vm->export_to_globals_=e; vm->export_depth_=d; } } _export_restore{this, old_exp, old_depth};
            // Snapshot the global names so the alias namespace can be built from
            // whatever the module adds, matching the interpreter.
            // The module's OWN top-level names, read from its AST. Diffing
            // globals_ before and after fails when the module was already
            // loaded — `import "m"` then `import "m" as x` adds nothing new, so
            // the namespace came out empty. Reading declarations directly is
            // independent of what is already defined.
            std::set<std::string> own_names;
            if(!alias.empty() && ast) nython::scope::module_names(ast, own_names);   // NyScope.cpp
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
            export_to_globals_=old_exp; export_depth_=old_depth;
            // A module name it defines itself (socket's class socket): the
            // module's names become attributes of that class or function, as
            // on the interpreter (see evalImport there).
            if(!alias.empty() && own_names.count(alias)){
                VMVal same;
                auto git=globals_.find(alias);
                if(git!=globals_.end()) same=git->second;
                else { auto cit=class_reg_.find(alias); if(cit!=class_reg_.end()) same=VMVal::make_class(cit->second, alias); }
                if(same.type==VMType::CLASS||same.type==VMType::FUNCTION){
                    for(const auto& n : own_names){
                        if(n==alias) continue;
                        auto it=globals_.find(n);
                        VMVal v;
                        if(it!=globals_.end()) v=it->second;
                        else { auto cit=class_reg_.find(n); if(cit==class_reg_.end()) continue; v=VMVal::make_class(cit->second, n); }
                        set_attr(same, n, v);
                    }
                    set_attr(same, alias, same);
                    module_ns_[name]=same;
                    globals_[alias]=same;
                    for(auto& sub:code->sub_codes) if(sub->is_class&&!class_reg_.count(sub->name)) class_reg_[sub->name]=sub;   // keep the class MAKE_CLASS made (a copy for metaclass= / expression bases), round 77
                    return;
                }
            }
            if(!alias.empty()){
                auto ns=std::make_shared<VMMap>(); vmgc::track_map(ns);
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
                module_ns_[name]=nsv;
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
                    auto attrs = std::make_shared<VMMap>(); vmgc::track_map(attrs);
                    (*attrs)["args"] = VMVal::make_tuple({VMVal::make_str(e.msg)});
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
        globals_["relu"]=VMVal::make_native([](std::vector<VMVal>& a)->VMVal{
            // relu is closed over the integers: relu(-5) is 0, relu(3) is 3.
            if(!a.empty()&&a[0].type==VMType::INT) return VMVal::make_int(a[0].i>0?a[0].i:0);
            double v=to_d(a.empty()?VMVal::make_int(0):a[0]);return VMVal::make_float(v>0?v:0);});
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
            auto m=std::make_shared<VMMap>(); vmgc::track_map(m);
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
                auto m=std::make_shared<VMMap>(); vmgc::track_map(m);
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
        // hasattr: the full attribute lookup (methods and class attributes
        // too; only an instance's own fields were seen).
        // hasattr / getattr / setattr / delattr for every kind of value, as
        // in Python and as on the interpreter: hasattr and getattr with a
        // default see an AttributeError (a missing attribute, or one a
        // property / __getattr__ raises) as absence; other errors propagate.
        auto attr_name=[this](std::vector<VMVal>& a, const char* fn)->std::string{
            if(a[1].type!=VMType::STRING)
                raise_native_exception("TypeError",std::string(fn)+"(): attribute name must be string, not '"+vm_type_name(a[1])+"'");
            return a[1].s;
        };
        globals_["hasattr"]=VMVal::make_native([this,attr_name](std::vector<VMVal>& a)->VMVal{
            if(a.size()!=2) raise_native_exception("TypeError","hasattr expected 2 arguments, got "+std::to_string(a.size()));
            VMVal v; return VMVal::make_bool(try_get_attr(a[0],attr_name(a,"hasattr"),v));});
        globals_["getattr"]=VMVal::make_native([this,attr_name](std::vector<VMVal>& a)->VMVal{
            if(a.size()<2||a.size()>3) raise_native_exception("TypeError","getattr expected at most 3 arguments, got "+std::to_string(a.size()));
            std::string n=attr_name(a,"getattr");
            VMVal v;
            if(try_get_attr(a[0],n,v)) return v;
            if(a.size()==3) return a[2];
            throw_exception(make_exception("AttributeError",{VMVal::make_str(attr_error_text(a[0],n))}));
            return VMVal::make_none();});
        globals_["setattr"]=VMVal::make_native([this,attr_name](std::vector<VMVal>& a)->VMVal{
            if(a.size()!=3) raise_native_exception("TypeError","setattr expected 3 arguments, got "+std::to_string(a.size()));
            set_attr(a[0],attr_name(a,"setattr"),a[2]);
            return VMVal::make_none();});
        globals_["delattr"]=VMVal::make_native([this,attr_name](std::vector<VMVal>& a)->VMVal{
            if(a.size()!=2) raise_native_exception("TypeError","delattr expected 2 arguments, got "+std::to_string(a.size()));
            del_attr(a[0],attr_name(a,"delattr"));
            return VMVal::make_none();});
        globals_["repr"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("none");
            if(a[0].type==VMType::INSTANCE||a[0].type==VMType::LIST||a[0].type==VMType::MAP)
                return VMVal::make_str(vm_repr(a[0]));
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
        // locals() / globals() / vars() / dir() (round 77; they read none):
        // as on the interpreter (NythonExecutor reflect*).
        // object.__new__(cls): an instance of cls without running __init__ (round 77)
        globals_["_ny_object_new"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()||a[0].type!=VMType::CLASS) raise_native_exception("TypeError","object.__new__(X): X is not a type object");
            const VMVal& cls=a[0];
            auto attrs=new_instance_fields(cls.class_name);
            VMVal inst=VMVal::make_instance(cls.class_name,attrs);
            if(!class_reg_.count(cls.class_name)&&cls.code) class_reg_[cls.class_name]=cls.code;
            if(vm_exc_classes().count(cls.class_name)) set_exc_args(*attrs, cls.class_name, {});   // round 77
            return inst;
        });
        globals_["_ny_subclasses"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            std::vector<VMVal> r;
            if(!a.empty()&&a[0].type==VMType::CLASS){
                auto it=subclasses_.find(class_key(a[0]));
                if(it!=subclasses_.end()) for(auto& n:it->second){ VMVal cv=class_value(n); if(cv.type==VMType::CLASS) r.push_back(cv); }
            }
            return VMVal::make_list(std::move(r)); });
        // a function's parameters, flags and place (inspect; round 77)
        globals_["_ny_fn_info"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return fn_info(a.empty()?VMVal::make_none():a[0]); });
        globals_["_ny_fn_globals"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return fn_globals(a.empty()?VMVal::make_none():a[0]); });
        globals_["_ny_setattr_raw"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()>=3){ RawAttr raw; VMVal o=a[0]; set_attr(o,a[1].to_string(),a[2]); }
            return VMVal::make_none(); });
        globals_["_ny_delattr_raw"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.size()>=2){ RawAttr raw; del_attr(a[0],a[1].to_string()); }
            return VMVal::make_none(); });
        globals_["eval"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return vm_eval_exec(false,a); });
        globals_["exec"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return vm_eval_exec(true,a); });
        globals_["compile"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return vm_compile(a); });
        globals_["globals"]=VMVal::make_native([this](std::vector<VMVal>&)->VMVal{ return vm_globals_map(); });
        // The __main__ module's globals from anywhere (a library module's
        // globals() is its own): unittest.main() finds the program's
        // TestCase classes here, as Python's reads sys.modules["__main__"].
        // The exception an except clause is handling right now, in this
        // frame or a caller's (Python's sys.exc_info()[1]); none outside
        // any except clause. A clause keeps its exception in a hidden
        // "__excN__" variable for a bare `raise` and deletes it when it
        // completes; the innermost clause has the highest N in its frame.
        globals_["_ny_exc_current"]=VMVal::make_native([this](std::vector<VMVal>&)->VMVal{ return vm_exc_current(); });
        // The running frames (round 77): sys._getframe, traceback.extract_stack, warnings.
        globals_["_ny_stack"]=VMVal::make_native([this](std::vector<VMVal>&)->VMVal{ return vm_stack_value(); });
        globals_["_ny_main_globals"]=VMVal::make_native([this](std::vector<VMVal>&)->VMVal{
            VMVal d=VMVal::make_map();
            for(auto& kv:globals_){
                if(reflect_hidden(kv.first)||base_global_names_.count(kv.first)) continue;
                (*d.map)[kv.first]=kv.second;
            }
            CallFrame* mf=in_other_thread()?module_frame_:(call_stack_.empty()?nullptr:&call_stack_.front());
            if(mf) for(auto& kv:mf->locals) if(!reflect_hidden(kv.first)) (*d.map)[kv.first]=kv.second;
            return d;
        });
        globals_["locals"]=VMVal::make_native([this](std::vector<VMVal>&)->VMVal{ return vm_locals_map(); });
        globals_["vars"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return vm_vars(a); });
        globals_["dir"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{ return vm_dir(a); });
        globals_["input"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            // one line from stdin (NyConc.cpp: read_stdin_line); EOFError at
            // the end of input, Ctrl+C raises KeyboardInterrupt
            if(!a.empty()) std::cout<<vm_str(a[0])<<std::flush;
            std::string line;
            bool ok;
            try { ok=nyconc::read_stdin_line(line); }
            catch(nyconc::NyError& err){
                if(raise_nyerror_) raise_nyerror_(err);
                raise_native_exception(err.type,err.msg);
            }
            if(!ok) raise_native_exception("EOFError","EOF when reading a line");
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
        // next(it[, default]): an exhausted iterator raises StopIteration
        // (or returns the default), as on the interpreter.
        // iter(x): generators and iterators are their own; an object goes
        // through __iter__ (or is its own iterator with __next__); a list,
        // string or dict gives an iterator over its items. It was not defined,
        // so `def __iter__(self): return iter(self.items)` iterated nothing.
        globals_["iter"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) throw_exception(make_exception("TypeError",{VMVal::make_str("iter expected 1 argument, got 0")}));
            if(a.size()>2) throw_exception(make_exception("TypeError",{VMVal::make_str("iter expected at most 2 arguments, got "+std::to_string(a.size()))}));
            if(a.size()==2){
                // iter(callable, sentinel): calls it until it returns the
                // sentinel (round 77, a lazy callable_iterator)
                std::vector<VMVal> ca{a[0]};
                if(!load_var("callable").native(ca).is_truthy())
                    throw_exception(make_exception("TypeError",{VMVal::make_str("iter(v, w): v must be callable")}));
                VMVal fn=a[0], sentinel=a[1];
                return gen_native("callable_iterator",[this,fn,sentinel](VMVal& out)->bool{
                    std::vector<VMVal> none;
                    VMVal v=vm_call(fn,none,std::nullopt);
                    if(vm_eq(v,sentinel)) return false;
                    out=v; return true;
                });
            }
            const VMVal& v=a[0];
            if(v.type==VMType::GENERATOR||v.type==VMType::ITERATOR) return v;
            if(v.type==VMType::INSTANCE){
                bool f=false;
                VMVal r=call_dunder_f(v,"__iter__",{},f);
                if(f) return r;
                VMVal nx;
                if(class_lookup(v.class_name,"__next__",nx)) return v;
                return VMVal::make_iter(iter_items(v));
            }
            if(v.type==VMType::LIST||v.type==VMType::STRING||v.type==VMType::MAP||v.type==VMType::BYTES)
                return VMVal::make_iter(iter_items(v));
            throw_exception(make_exception("TypeError",{VMVal::make_str("'"+vm_type_name(v)+"' object is not iterable")}));
        });
        // callable(x): functions, builtins, classes, and objects with __call__.
        globals_["callable"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_bool(false);
            const VMVal& v=a[0];
            if(v.type==VMType::FUNCTION||v.type==VMType::NATIVE||v.type==VMType::CLASS) return VMVal::make_bool(true);
            // a bound method (obj.method read as a value)
            if(v.type==VMType::MAP&&(v.class_name=="__bound_method__"||v.class_name=="__super_bound__")) return VMVal::make_bool(true);
            if(v.type==VMType::INSTANCE){ VMVal m; return VMVal::make_bool(class_lookup(v.class_name,"__call__",m)); }
            return VMVal::make_bool(false);
        });
        globals_["next"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_none();
            bool has_default=a.size()>=2;
            auto exhausted=[&]()->VMVal{
                if(has_default) return a[1];
                throw_exception(make_exception("StopIteration",{}));
            };
            if(a[0].type==VMType::GENERATOR){
                if(!a[0].gen) return exhausted();
                std::shared_ptr<GenState> gsp=a[0].gen;
                VMVal v;
                if(gen_resume(*gsp,0,VMVal::make_none(),v)) return v;
                if(has_default){ gsp->retval=VMVal::make_none(); return a[1]; }
                gen_raise_stop(*gsp);   // StopIteration(return value)
            }
            if(a[0].type==VMType::INSTANCE){
                VMVal nx;
                if(!class_lookup(a[0].class_name,"__next__",nx))
                    throw_exception(make_exception("TypeError",{VMVal::make_str("'"+vm_type_name(a[0])+"' object is not an iterator")}));
                try { return call_dunder(a[0],"__next__",{}); }
                catch(VMException& e){ if(is_stop_iteration(e.value)) return exhausted(); throw; }
            }
            // a list, str, int...: not an iterator (round 77; it returned none)
            if(a[0].type!=VMType::ITERATOR)
                throw_exception(make_exception("TypeError",{VMVal::make_str("'"+vm_type_name(a[0])+"' object is not an iterator")}));
            if(!a[0].iter) return exhausted();
            auto&[cur,items]=*a[0].iter;
            if(cur>=(int)items.size()) return exhausted();
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
            auto m=std::make_shared<VMMap>(); vmgc::track_map(m);
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

    // `import math`: a namespace of builtins/pymath.cpp's math_* functions
    // (through the bridge, so both engines run the same code) and the
    // constants. `math` used to be undefined on this engine.
    VMVal define_math_module(const std::string& as_name) {
        VMVal ns=VMVal::make_map();
        std::vector<std::string> names;
        if(bridge_names()) names=bridge_names()();
        for(auto& n:names)
            if(n.compare(0,5,"math_")==0){ VMVal fn=load_var(n); if(fn.type!=VMType::NONE) (*ns.map)[n.substr(5)]=fn; }
        // floor/ceil/trunc of an object: its __floor__/__ceil__/__trunc__,
        // here, before the bridge (which lost self: "takes 1 argument (0
        // given)" for math.floor(Fraction(7, 2))).
        for(const char* nm:{"floor","ceil","trunc"}){
            auto it=ns.map->find(nm);
            if(it==ns.map->end()) continue;
            VMVal inner=it->second;
            std::string dunder=std::string("__")+nm+"__";
            VirtualMachine* vm=this;
            (*ns.map)[nm]=VMVal::make_native([vm,inner,dunder](std::vector<VMVal>& a)->VMVal{
                if(a.size()==1&&a[0].type==VMType::INSTANCE){
                    bool f=false; VMVal r=vm->call_dunder_f(a[0],dunder,{},f);
                    if(f) return r;
                }
                return vm->vm_call(inner,a,std::nullopt);
            });
        }
        (*ns.map)["pi"]=VMVal::make_float(3.14159265358979323846);
        (*ns.map)["e"]=VMVal::make_float(2.71828182845904523536);
        (*ns.map)["tau"]=VMVal::make_float(6.28318530717958647692);
        (*ns.map)["inf"]=VMVal::make_float(std::numeric_limits<double>::infinity());
        (*ns.map)["nan"]=VMVal::make_float(std::numeric_limits<double>::quiet_NaN());
        ns.class_name=as_name;
        globals_[as_name]=ns;
        return ns;
    }

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
        if(v.type==VMType::BYTES){
            std::vector<VMVal> items;
            for(unsigned char c:v.bdata()) items.push_back(VMVal::make_int(c));
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
            if(m=="encode"){
                // str -> bytes (NyBytes.hpp: str_encode)
                const VMVal* ev=kw_or_pos(kw.type==VMType::MAP?&kw:nullptr,"encoding",a,0);
                const VMVal* rv=kw_or_pos(kw.type==VMType::MAP?&kw:nullptr,"errors",a,1);
                std::string enc=(ev&&ev->type!=VMType::NONE)?vm->vm_str(*ev):std::string("utf-8");
                std::string err=(rv&&rv->type!=VMType::NONE)?vm->vm_str(*rv):std::string("strict");
                return VMVal::make_bytes(vm->nycall([&]{ return nypy::str_encode(obj.s,enc,err); }));
            }
            std::vector<nypy::SArg> sa; sa.reserve(a.size());
            for(auto& v:a) sa.push_back(vm->to_sarg(v));
            nypy::SRes r;
            if(vm->nycall([&]{ return nypy::str_method(obj.s,m,sa,r); })) return from_sres(r);
            return vm->missing_attr(obj,m);
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
        if(x.type==VMType::INSTANCE||y.type==VMType::INSTANCE){
            // x.__lt__(y), else y.__gt__(x): sorted([F(3), 1, F(2)]) sorts
            // an int against objects (it compared type names)
            VMVal r;
            if(rich_compare(x,y,"__lt__","__gt__",r)) return vm_truthy(r);
        }
        std::string tx=vm_type_name(x), ty=vm_type_name(y);
        if(tx!=ty) return tx<ty;
        return x.to_string()<y.to_string();
    }
    VMVal list_method(VMVal obj, const std::string& m) {
        VirtualMachine* vm=this;
        return VMVal::make_native([obj,m,vm](std::vector<VMVal>& a)->VMVal{
            if(!obj.list) return VMVal::make_none();
            if(obj.is_set()){
                VMVal so=obj, out;
                take_kwargs(a);
                if(vm->set_method(so,m,a,out)) return out;
                return vm->missing_attr(obj,m);
            }
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
            return vm->missing_attr(obj,m);
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
        auto as_int=[vm](const VMVal& v0)->nypy::NumV{
            nypy::NumV n;
            VMVal v=v0;
            { VMVal iv; if(vm->index_value(v0,iv)) v=iv; }   // __index__ (round 77)
            if(!v.to_numv(n)||n.k==3) vm->raise_native_exception("TypeError","'"+vm_type_name(v)+"' object cannot be interpreted as an integer");
            return n;
        };
        auto call1=[vm](const VMVal& fn, const VMVal& x){ std::vector<VMVal> a={x}; return vm->vm_call(fn,a,std::nullopt); };
        def("len",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) vm->raise_native_exception("TypeError","len() takes exactly one argument (0 given)");
            const VMVal& v=a[0];
            switch(v.type){
                case VMType::STRING: return VMVal::make_int((int64_t)nypy::str_width(v.s));
                case VMType::BYTES: return VMVal::make_int((int64_t)v.bdata().size());
                case VMType::LIST: return VMVal::make_int(v.list?(int64_t)v.list->size():0);
                case VMType::MAP: { int64_t n=0; if(v.map) for(auto& kv:*v.map) if(!vm_internal_key(kv.first)) n++; return VMVal::make_int(n); }
                case VMType::INSTANCE: { VMVal r=vm->call_dunder(v,"__len__",{}); if(r.type!=VMType::NONE) return r; break; }
                // a class whose metaclass defines __len__ (round 77)
                case VMType::CLASS: { VMVal r; if(!vm->class_meta_.empty()&&vm->meta_call(v,"__len__",{},r)) return r; break; }
                case VMType::ITERATOR: return VMVal::make_int(v.iter?(int64_t)v.iter->second.size()-v.iter->first:0);
                case VMType::NONE: case VMType::UNDEFINED: return VMVal::make_int(0);   // as the interpreter
                default: break;
            }
            vm->raise_native_exception("TypeError","object of type '"+vm_type_name(v)+"' has no len()");
        });
        def("str",[vm](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            // str(b, encoding, errors) decodes; str(b) alone is its repr
            if(a[0].type==VMType::BYTES){
                const VMVal* ev=a.size()>=2?&a[1]:kwarg(kw,"encoding");
                const VMVal* rv=a.size()>=3?&a[2]:kwarg(kw,"errors");
                if(ev||rv){
                    std::string enc=ev?vm->vm_str(*ev):std::string("utf-8"), err=rv?vm->vm_str(*rv):std::string("strict");
                    return VMVal::make_str(vm->nycall([&]{ return nypy::bytes_decode(a[0].bdata(),enc,err); }));
                }
            }
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
                // f"{obj}" is format(obj, ""): an object's __format__ runs (round 77)
                if(spec.empty()&&a[0].type!=VMType::INSTANCE) return VMVal::make_str(a[0].type==VMType::STRING?a[0].s:vm->vm_str(a[0]));
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
                if(v.type!=VMType::STRING&&v.type!=VMType::BYTES) vm->raise_native_exception("TypeError","int() can't convert non-string with explicit base");
                nypy::NumV b=as_int(*bv);
                int base=(int)b.i;
                if(b.k!=1||(base!=0&&(base<2||base>36))) vm->raise_native_exception("ValueError","int() base must be >= 2 and <= 36, or 0");
                nypy::BigInt out;
                const std::string& txt=v.type==VMType::BYTES?v.bdata():v.s;
                if(!nypy::parse_int_str(txt,base,out))
                    vm->raise_native_exception("ValueError","invalid literal for int() with base "+std::to_string(base)+": "+(v.type==VMType::BYTES?v.to_string():nypy::str_repr(v.s)));
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
                case VMType::STRING: case VMType::BYTES: {
                    nypy::BigInt out;
                    const std::string& txt=v.type==VMType::BYTES?v.bdata():v.s;
                    if(!nypy::parse_int_default(txt,out))
                        vm->raise_native_exception("ValueError","invalid literal for int() with base 10: "+(v.type==VMType::BYTES?v.to_string():nypy::str_repr(v.s)));
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
            if(a[0].type==VMType::INSTANCE||a[1].type==VMType::INSTANCE){
                // __divmod__ / __rdivmod__, else the objects' // and %
                // (divmod(timedelta, timedelta) was a TypeError)
                VMVal res,q,r;
                if(vm->binary_dunder(a[0],a[1],"__divmod__","__rdivmod__",res)) return res;
                if(vm->binary_dunder(a[0],a[1],"__floordiv__","__rfloordiv__",q)&&vm->binary_dunder(a[0],a[1],"__mod__","__rmod__",r))
                    return VMVal::make_tuple({q,r});
                vm->raise_native_exception("TypeError","unsupported operand type(s) for divmod(): '"+vm_type_name(a[0])+"' and '"+vm_type_name(a[1])+"'");
            }
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
            if(!a.empty()&&a[0].type==VMType::BYTES){
                const std::string& d=a[0].bdata();
                if(d.size()!=1) vm->raise_native_exception("TypeError","ord() expected a character, but string of length "+std::to_string(d.size())+" found");
                return VMVal::make_int((unsigned char)d[0]);
            }
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
            // a class whose metaclass defines __reversed__: reversed(Color) (round 77)
            if(a[0].type==VMType::CLASS){ VMVal r; if(vm->meta_call(a[0],"__reversed__",{},r)) return r; }
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
            if(a.empty()) return new_set(false);
            return vm->build_set(vm->iter_items(a[0]),false);
        });
        def("frozenset",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            if(a.empty()) return new_set(true);
            if(a[0].is_frozenset()) return a[0];
            return vm->build_set(vm->iter_items(a[0]),true);
        });
        def("dict",[vm](std::vector<VMVal>& a,const VMVal& kw)->VMVal{
            VMVal d=VMVal::make_map();
            if(!a.empty()){
                VMVal keys_m;
                if(a[0].type==VMType::MAP&&a[0].map){ for(auto& [k,v]:*a[0].map) if(!vm_internal_key(k)) (*d.map)[k]=v; }
                else if(a[0].type==VMType::INSTANCE&&vm->class_lookup(a[0].class_name,"keys",keys_m)){
                    // a mapping: keys(), then obj[k] (Python's dict(mapping))
                    std::vector<VMVal> no_args;
                    VMVal ks=vm->vm_call_method(a[0],"keys",no_args);
                    for(auto& k:vm->iter_items(ks)){
                        std::vector<VMVal> ka{k};
                        (*d.map)[vm->vkey(k)]=vm->vm_call_method(a[0],"__getitem__",ka);
                    }
                }
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
        def("type",[vm](std::vector<VMVal>& a,const VMVal&)->VMVal{
            // type(name, bases, ns): a new class (round 77)
            if(a.size()==3){ std::vector<VMVal> t{VMVal::make_none(),a[0],a[1],a[2]}; return vm->type_new(t,nullptr); }
            if(a.empty())return VMVal::make_str("none");
            // a type object (type(5) is int, type(obj) is its class), equal
            // to its legacy name too (type(x) == "list") - round 77
            VMVal t=vm->type_object_of(a[0]);
            if(t.type!=VMType::NONE) return t;
            switch(a[0].type){
            case VMType::NONE:return VMVal::make_str("none");
            case VMType::BOOL:return VMVal::make_str("bool");
            case VMType::INT:return VMVal::make_str("int");
            case VMType::FLOAT:return VMVal::make_str("float");
            case VMType::STRING:return VMVal::make_str("string");  // as the interpreter reports it
            case VMType::LIST:return VMVal::make_str(a[0].is_set()?(a[0].is_frozenset()?"frozenset":"set"):a[0].b?"tuple":"list");
            case VMType::MAP:return VMVal::make_str("map");   // as the interpreter reports it
            case VMType::FUNCTION:return VMVal::make_str("function");
            case VMType::NATIVE:return VMVal::make_str("builtin");
            case VMType::CLASS:return VMVal::make_str("class");
            case VMType::INSTANCE:return VMVal::make_str(nyrt::shown_class_name(a[0].class_name));
            case VMType::GENERATOR:case VMType::ITERATOR:return VMVal::make_str("generator");
            case VMType::UNDEFINED:return VMVal::make_str("undefined");
            case VMType::BYTES:return VMVal::make_str(a[0].b?"bytearray":"bytes");
            default:return VMVal::make_str("unknown");}});
        // typeof(x): Nython's name of the type, the string type() gave
        // before type objects ("int", "string", "map", "class", a class's
        // name) - round 77
        {
            VMVal type_fn=globals_["type"];
            def("typeof",[vm,type_fn](std::vector<VMVal>& a,const VMVal&)->VMVal{
                if(a.empty()) return VMVal::make_str("none");
                VMVal t=vm->type_object_of(a[0]);
                if(t.type==VMType::CLASS) return VMVal::make_str(nyrt::shown_class_name(t.class_name));
                std::string b=t.builtin_type_name();
                if(!b.empty()) return VMVal::make_str(b=="str"?"string":b=="dict"?"map":b=="type"?"class":b);
                std::vector<VMVal> one{a[0]};
                VMVal r=type_fn.native(one);
                return r.type==VMType::STRING?r:VMVal::make_str(r.to_string());
            });
        }
        // bytes(x) / bytearray(x) (round 77)
        globals_["bytes"]=VMVal::make_native([vm](std::vector<VMVal>& a)->VMVal{ return vm->construct_bytes(a,false); });
        globals_["bytearray"]=VMVal::make_native([vm](std::vector<VMVal>& a)->VMVal{ return vm->construct_bytes(a,true); });
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
        globals_["property"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            VMVal desc; desc.type=VMType::MAP;
            desc.map=std::make_shared<VMMap>(); vmgc::track_map(desc.map);
            if(!a.empty()) (*desc.map)["__get__"]=a[0];
            (*desc.map)["__is_property__"]=VMVal::make_bool(true);
            // fget / fset and an abstract getter's __isabstractmethod__, as
            // Python's property (round 77; abc reads it)
            (*desc.map)["fget"]=a.empty()?VMVal::make_none():a[0];
            (*desc.map)["fset"]=VMVal::make_none();
            if(a.size()>=2&&a[1].type!=VMType::NONE){ (*desc.map)["__set__"]=a[1]; (*desc.map)["fset"]=a[1]; }
            bool abstract=false;
            if(!a.empty()&&a[0].type==VMType::FUNCTION){ VMVal r; if(lookup_attr(a[0],"__isabstractmethod__",r)) abstract=vm_truthy(r); }
            (*desc.map)["__isabstractmethod__"]=VMVal::make_bool(abstract);
            // Add .setter(fn) method to the descriptor so @prop.setter works:
            (*desc.map)["setter"]=VMVal::make_native([desc](std::vector<VMVal>& b) mutable ->VMVal{
                VMVal d2; d2.type=VMType::MAP;
                d2.map=std::make_shared<VMMap>(*desc.map); vmgc::track_map(d2.map);
                if(!b.empty()){ (*d2.map)["__set__"]=b[0]; (*d2.map)["fset"]=b[0]; }
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
            return VMVal::make_str(vm_str(v));
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
            return VMVal::make_bool(!a.empty()&&vm_truthy(a[0]));});
        // len and type: register_pycore (it runs after this and replaced
        // the copies that were here)
        globals_["range"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            // a bound given by an object with __index__ (round 77)
            for(auto& x:a) if(x.type==VMType::INSTANCE){
                VMVal iv;
                if(index_value(x,iv)) x=iv;
                else raise_native_exception("TypeError","'"+vm_type_name(x)+"' object cannot be interpreted as an integer");
            }
            int64_t st=0,en=0,step=1;
            if(a.size()==1)en=a[0].i;
            else if(a.size()>=2){st=a[0].i;en=a[1].i;}
            if(a.size()>=3)step=a[2].i;
            if(step==0)return VMVal::make_list();
            std::vector<VMVal> items;
            if(step>0)for(int64_t i=st;i<en;i+=step)items.push_back(VMVal::make_int(i));
            else for(int64_t i=st;i>en;i+=step)items.push_back(VMVal::make_int(i));
            return VMVal::make_list(std::move(items));});
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
        globals_["input"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            // one line from stdin (NyConc.cpp: read_stdin_line); EOFError at
            // the end of input, Ctrl+C raises KeyboardInterrupt
            if(!a.empty()) std::cout<<vm_str(a[0])<<std::flush;
            std::string line;
            bool ok;
            try { ok=nyconc::read_stdin_line(line); }
            catch(nyconc::NyError& err){
                if(raise_nyerror_) raise_nyerror_(err);
                raise_native_exception(err.type,err.msg);
            }
            if(!ok) raise_native_exception("EOFError","EOF when reading a line");
            return VMVal::make_str(line);});
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
            // isinstance(x, int | str): any of the union's types (round 77)
            if(a[1].type==VMType::INSTANCE&&a[1].map&&nyrt::shown_class_name(a[1].class_name)=="_NyUnionType"){
                auto it=a[1].map->find("__args__");
                if(it!=a[1].map->end()) for(auto& t:iter_items(it->second)){
                    if(t.type==VMType::NONE){ if(a[0].type==VMType::NONE) return VMVal::make_bool(true); continue; }
                    std::vector<VMVal> one{a[0], t};
                    if(globals_["isinstance"].native(one).b) return VMVal::make_bool(true);
                }
                return VMVal::make_bool(false);
            }
            // an object whose class defines __instancecheck__ (typing's
            // List, Union[int, str] ...), as CPython asks type(cls) - round 77
            if(a[1].type==VMType::INSTANCE){
                VMVal ic;
                if(class_lookup(a[1].class_name,"__instancecheck__",ic)){
                    std::vector<VMVal> one{a[0]};
                    return VMVal::make_bool(vm_truthy(invoke_method(ic, a[1], one, a[1].class_name)));
                }
            }
            if(a[1].type==VMType::LIST&&a[1].list){
                // isinstance(x, (A, B)): any of them.
                for(auto& c:*a[1].list){
                    std::vector<VMVal> one{a[0], c};
                    if(globals_["isinstance"].native(one).b) return VMVal::make_bool(true);
                }
                return VMVal::make_bool(false);
            }
            VMVal& obj=a[0]; VMVal& cls=a[1];
            // a metaclass's __instancecheck__; isinstance(C, type) / (C, M)
            if(cls.type==VMType::CLASS){
                VMVal r;
                if(!class_meta_.empty()&&meta_call(cls,"__instancecheck__",{obj},r)) return VMVal::make_bool(vm_truthy(r));
                if(obj.type==VMType::CLASS){
                    VMVal meta=metaclass_of(class_key(obj));
                    return VMVal::make_bool(meta.type==VMType::CLASS&&class_derives(class_key(meta),class_key(cls)));
                }
            }
            // isinstance(C, type), and of a builtin type: isinstance(int, type)
            // read false (round 77)
            if((obj.type==VMType::CLASS||(obj.type==VMType::NATIVE&&!obj.builtin_type_name().empty()))
               &&cls.type==VMType::NATIVE&&native_name(cls)=="type")
                return VMVal::make_bool(true);
            std::string cls_name;
            if(cls.type==VMType::CLASS) cls_name=cls.class_name;
            else if(cls.type==VMType::STRING) cls_name=cls.s;
            // isinstance(x, list) / isinstance(x, int): the bare builtin, not
            // a string. These are tagged with the type they build above.
            else if(cls.type==VMType::NATIVE&&!cls.class_name.empty()) cls_name=native_name(cls);
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
                if(cls_name=="list"||cls_name=="array") return VMVal::make_bool(obj.type==VMType::LIST&&!obj.b&&!obj.is_set());
                if(cls_name=="set") return VMVal::make_bool(obj.is_set()&&!obj.is_frozenset());
                if(cls_name=="frozenset") return VMVal::make_bool(obj.is_frozenset());
                if(cls_name=="tuple") return VMVal::make_bool(obj.type==VMType::LIST&&obj.b);
                if(cls_name=="map"||cls_name=="dict") return VMVal::make_bool(obj.type==VMType::MAP);
                if(cls_name=="bytes") return VMVal::make_bool(obj.type==VMType::BYTES&&!obj.b);
                if(cls_name=="bytearray") return VMVal::make_bool(obj.type==VMType::BYTES&&obj.b);
                if(cls_name=="none") return VMVal::make_bool(obj.type==VMType::NONE);
                // Every lazy iterator (it read false for all of them).
                if(cls_name=="generator") return VMVal::make_bool(obj.type==VMType::GENERATOR||obj.type==VMType::ITERATOR);
                if(cls_name=="function") return VMVal::make_bool(obj.type==VMType::FUNCTION||obj.type==VMType::NATIVE);
                return VMVal::make_bool(false);
            }
            return VMVal::make_bool(class_derives(obj.class_name, cls_name));
        });
        // issubclass(B, A): B's MRO contains A (a tuple of classes: any).
        globals_["issubclass"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            // issubclass(C, (A, B)): any of them, each asked as itself - an
            // ABC's __subclasscheck__ too (round 77)
            if(a.size()>=2&&a[1].type==VMType::LIST&&a[1].list&&!a[1].is_set()){
                std::vector<VMVal> items=*a[1].list;
                for(auto& c:items){
                    std::vector<VMVal> one{a[0], c};
                    if(globals_["issubclass"].native(one).b) return VMVal::make_bool(true);
                }
                return VMVal::make_bool(false);
            }
            if(a.size()>=2&&a[1].type==VMType::CLASS&&!class_meta_.empty()){
                VMVal r;
                if(meta_call(a[1],"__subclasscheck__",{a[0]},r)) return VMVal::make_bool(vm_truthy(r));
            }
            // an object whose class defines __subclasscheck__ (round 77)
            if(a.size()>=2&&a[1].type==VMType::INSTANCE){
                VMVal sc;
                if(class_lookup(a[1].class_name,"__subclasscheck__",sc)){
                    std::vector<VMVal> one{a[0]};
                    return VMVal::make_bool(vm_truthy(invoke_method(sc, a[1], one, a[1].class_name)));
                }
            }
            // a builtin type (int, bool ...) is a tagged native
            auto builtin_name=[](const VMVal& v)->std::string{
                if(v.type!=VMType::NATIVE) return std::string();
                for(const char* p:{"__builtin__:","__native__:"})
                    if(v.class_name.rfind(p,0)==0) return v.class_name.substr(std::string(p).size());
                // the type natives carry their type's name (tag_type_builtins)
                if(!v.class_name.empty()&&v.class_name.rfind("__",0)!=0) return v.class_name=="map"?std::string("dict"):v.class_name;
                return std::string();
            };
            if(a.size()>=2&&a[0].type==VMType::NATIVE){
                std::string sub=builtin_name(a[0]);
                auto bone=[&](const VMVal& c){
                    std::string sup=c.type==VMType::CLASS?nyrt::shown_class_name(c.class_name):c.type==VMType::STRING?c.s:builtin_name(c);
                    return nyrt::builtin_type_derives(sub,sup);
                };
                if(a[1].type==VMType::LIST&&a[1].list){ for(auto& c:*a[1].list) if(bone(c)) return VMVal::make_bool(true); return VMVal::make_bool(false); }
                return VMVal::make_bool(bone(a[1]));
            }
            if(a.size()<2||a[0].type!=VMType::CLASS) return VMVal::make_bool(false);
            auto one=[&](const VMVal& c){
                if(c.type==VMType::CLASS) return class_derives(a[0].class_name, c.class_name)||nyrt::shown_class_name(c.class_name)=="object";
                if(c.type==VMType::STRING) return class_derives(a[0].class_name, c.s);
                std::string bn=builtin_name(c);
                if(bn=="object") return true;
                // a class deriving from a builtin type: issubclass(IntEnum, int) (round 77)
                if(!bn.empty()&&nyrt::is_builtin_type_name(bn)&&class_derives(a[0].class_name, bn)) return true;
                return false;
            };
            if(a[1].type==VMType::LIST&&a[1].list){
                for(auto& c:*a[1].list) if(one(c)) return VMVal::make_bool(true);
                return VMVal::make_bool(false);
            }
            return VMVal::make_bool(one(a[1]));
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
        // Builtin exception classes are real classes - registered like a
        // user class, with Python's hierarchy - so `class E(ValueError)`,
        // `except LookupError`, isinstance(e, Exception) and super().__init__
        // all work on them. They used to be natives returning an instance,
        // unrelated to one another and impossible to subclass.
        for(auto& en : nython::ny_builtin_exc_names()){
            auto code=std::make_shared<VMCode>();
            code->name=en; code->is_class=true;
            const char* par=nython::ny_builtin_exc_parent(en);
            if(par && *par){ code->parent_class=par; code->bases.push_back(par); }
            code->instructions.emplace_back(Op::HALT);
            class_reg_[en]=code;
            globals_[en]=VMVal::make_class(code,en);
            note_exc_class(en);   // with its kind (round 77)
        }
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
                [this,rev](const std::pair<VMVal,VMVal>& x,const std::pair<VMVal,VMVal>& y){
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
                case VMType::FUNCTION:  // its closure and defaults too, as `is` (round 77)
                    raw=(uintptr_t)v.code.get()^((uintptr_t)v.closure_env.get()*31)^((uintptr_t)v.list.get()*17); break;
                case VMType::CLASS:     raw=(uintptr_t)v.code.get(); break;
                case VMType::ITERATOR:  raw=(uintptr_t)v.iter.get(); break;
                case VMType::GENERATOR: raw=(uintptr_t)v.gen.get();  break;
                default: raw=0; break;
            }
            if(raw) return VMVal::make_int((int64_t)(raw & 0x7fffffffffffffffULL));
            uint64_t h=std::hash<std::string>{}(v.to_string()+"|"+std::to_string((int)v.type));
            return VMVal::make_int((int64_t)(h & 0x7fffffffffffffffULL));});
        // As the interpreter's (pycore.cpp B_HASH): nypy::hash_of_key; an
        // object's __hash__, else its identity.
        globals_["hash"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) raise_native_exception("TypeError","hash() takes exactly one argument (0 given)");
            if(a[0].type==VMType::INSTANCE){
                check_hashable(a[0]);
                bool f=false; VMVal r=call_dunder_f(a[0],"__hash__",{},f);
                if(f) return r;
                uintptr_t raw=a[0].map?(uintptr_t)a[0].map.get():0;
                return VMVal::make_int((int64_t)(raw>>4));
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
        // string_format(template, *values) / (template, [values]): str.format
        // (the interpreter's builtins/string.cpp is the same).
        globals_["string_format"]=VMVal::make_native([this](std::vector<VMVal>& a)->VMVal{
            if(a.empty()) return VMVal::make_str("");
            VMVal tmpl=a[0];
            std::vector<VMVal> rest(a.begin()+1,a.end());
            if(rest.size()==1&&rest[0].type==VMType::LIST&&rest[0].list&&!rest[0].is_tuple()&&!rest[0].is_set())
                rest=*rest[0].list;
            return vm_call_method(tmpl,"format",rest);
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
        case Op::LOAD_ATTR_OPT: return "LOAD_ATTR_OPT";
        case Op::LOAD_SUBSCR_OPT: return "LOAD_SUBSCR_OPT";
        case Op::CHECK_MEMBER: return "CHECK_MEMBER";
        case Op::DUP_TOP_TWO:  return "DUP_TOP_TWO";
        case Op::LOAD_GLOBAL_NAME: return "LOAD_GLOBAL_NAME";
        case Op::DELETE_NAME:  return "DELETE_NAME";
        case Op::STORE_GLOBAL_NAME: return "STORE_GLOBAL_NAME";
        case Op::JUMP_IF_NONE_KEEP: return "JUMP_IF_NONE_KEEP";
        case Op::JUMP_IF_MISSING_KEEP: return "JUMP_IF_MISSING_KEEP";
        case Op::JUMP_IF_NOT_NONE_OR_POP: return "JUMP_IF_NOT_NONE_OR_POP";
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
        case Op::BINARY_MATMUL:return "BINARY_MATMUL";
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
        case Op::MAP_MERGE:    return "MAP_MERGE";
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
        case Op::FIN_NORMAL:   return "FIN_NORMAL";
        case Op::FIN_RETURN:   return "FIN_RETURN";
        case Op::FIN_JUMP:     return "FIN_JUMP";
        case Op::END_FINALLY:  return "END_FINALLY";
        case Op::WITH_ENTER:   return "WITH_ENTER";
        case Op::WITH_EXIT:    return "WITH_EXIT";
        default:               return "???";
        }
    }
};

using VM = VirtualMachine;

// A generator's last reference is gone: its VM decides whether closing it
// can run code (a pause inside try/with) and queues it if so.
inline GenState::~GenState() {
    if(vm && VirtualMachine::vm_live(vm, 0)) vm->gen_dropped(*this);
}

} // namespace nython::vm

#pragma GCC diagnostic pop

#endif // VIRTUAL_MACHINE_HPP
