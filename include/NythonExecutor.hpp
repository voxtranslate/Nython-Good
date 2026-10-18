#pragma once
#include "platform_compat.hpp"
// NythonExecutor.hpp
// ─────────────────────────────────────────────────────────────────────────────
// NythonExecutor struct — the interpreter's runtime object.
// Includes the full struct definition so that builtin modules (which each live
// in their own .cpp) can take a `NythonExecutor&` and call all helpers freely.
//
// Split layout:
//   NythonExecutor.hpp         ← this file (struct definition + callBuiltin dispatcher)
//   src/builtins/tensor.cpp    ← dispatch_tensor()
//   src/builtins/audio.cpp     ← dispatch_audio()
//   src/builtins/string.cpp    ← dispatch_string()
//   src/builtins/io.cpp        ← dispatch_io()
//   src/builtins/network.cpp   ← dispatch_network()
//   src/builtins/math.cpp      ← dispatch_math()
//   src/builtins/os.cpp        ← dispatch_os()
//   src/builtins/data.cpp      ← dispatch_data()
//   src/builtins/threading.cpp ← dispatch_threading()
//   src/builtins/core.cpp      ← dispatch_core()
//   src/builtins/gui.cpp       ← dispatch_gui()    (SDL2 backend)
//   src/main.cpp               ← main(), repl(), run_file(), eval chain
// ─────────────────────────────────────────────────────────────────────────────

// Windows: winsock2.h MUST come before windows.h (which some headers pull in)
#include "Nython.hpp"
#include "NythonREPL.hpp"
#include "NyExcTypes.hpp"
#include "NyRuntime.hpp"
#include "NyKwMap.hpp"
#include "NyPrelude.hpp"
#include "NyPyTrace.hpp"   // sys.settrace / sys.setprofile (round 79)
#include <algorithm>
#include <fstream>
#include <cwctype>
#include <chrono>
#include <iomanip>
#include <map>
#include <set>
#include <deque>
#include <thread>
#include <mutex>
#include <condition_variable>
#include "NyConc.hpp"   // concurrency runtime shared with the VM (src/NyConc.cpp)
#include <random>
#include <regex>
#include <sstream>
#include <ctime>
#include <functional>
#include <charconv>   // round 81: std::to_chars (list keys)
#include "NyBigInt.hpp"
#include "NyRange.hpp"   // range objects and dict views (round 78)
#include "NyStr.hpp"
#include "NyBytes.hpp"
#include "NyScope.hpp"
#include "builtins/net.hpp"
#include "NyFormat.hpp"
#include "NyMembers.hpp"

// Platform compat (sockets, dirent, stat, getcwd, etc.) in platform_compat.hpp
#include <locale>

// Unicode case conversion tables for Latin characters
static uint32_t unicode_toupper(uint32_t cp) {
    // Latin-1 Supplement (U+00C0-U+00FF)
    if (cp >= 0xE0 && cp <= 0xF6) return cp - 0x20; // à-ö -> À-Ö
    if (cp >= 0xF8 && cp <= 0xFE) return cp - 0x20; // ø-þ -> Ø-Þ
    // Latin Extended-A
    if (cp >= 0x0101 && cp <= 0x017E && (cp & 1)) return cp - 1;
    // Special cases
    if (cp == 0x00FF) return 0x0178; // ÿ -> Ÿ
    if (cp == 0x00DF) return cp; // ß has no single uppercase (SS)
    if (cp == 0x0131) return 0x0049; // ı -> I
    return cp;
}
static uint32_t unicode_tolower(uint32_t cp) {
    if (cp >= 0xC0 && cp <= 0xD6) return cp + 0x20; // À-Ö -> à-ö
    if (cp >= 0xD8 && cp <= 0xDE) return cp + 0x20; // Ø-Þ -> ø-þ
    if (cp >= 0x0100 && cp <= 0x017D && !(cp & 1)) return cp + 1;
    if (cp == 0x0178) return 0x00FF; // Ÿ -> ÿ
    return cp;
}
static void utf8_encode(uint32_t cp, std::string& out) {
    if (cp < 0x80) out += (char)cp;
    else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
}
static uint32_t utf8_decode(const std::string& s, size_t& pos) {
    unsigned char ch = s[pos];
    if (ch < 0x80) { pos++; return ch; }
    if (ch < 0xC0) { pos++; return ch; } // invalid continuation
    uint32_t cp;
    if (ch < 0xE0) { cp = (ch & 0x1F) << 6; if (pos+1<s.size()) cp |= (s[pos+1]&0x3F); pos+=2; }
    else if (ch < 0xF0) { cp = (ch & 0x0F) << 12; if(pos+1<s.size()) cp |= ((s[pos+1]&0x3F)<<6); if(pos+2<s.size()) cp |= (s[pos+2]&0x3F); pos+=3; }
    else { cp = (ch & 0x07) << 18; if(pos+1<s.size()) cp |= ((s[pos+1]&0x3F)<<12); if(pos+2<s.size()) cp |= ((s[pos+2]&0x3F)<<6); if(pos+3<s.size()) cp |= (s[pos+3]&0x3F); pos+=4; }
    return cp;
}
static std::string utf8_upper(const std::string& s) {
    std::string r; size_t pos = 0;
    while (pos < s.size()) { uint32_t cp = utf8_decode(s, pos); utf8_encode(unicode_toupper(cp < 0x80 ? toupper(cp) : unicode_toupper(cp)), r); }
    return r;
}
static std::string utf8_lower(const std::string& s) {
    std::string r; size_t pos = 0;
    while (pos < s.size()) { uint32_t cp = utf8_decode(s, pos); utf8_encode(unicode_tolower(cp < 0x80 ? tolower(cp) : unicode_tolower(cp)), r); }
    return r;
}
// utf8_charcount removed (unused, functionality inlined)

#include "Context.hpp"
#include "ASTNodes.hpp"
#include "Interpreter.hpp"
#include "Class.hpp"
#include "VirtualMachine.hpp"
#include "DynamicLang.hpp"
#include "Runtime.hpp"
#include "NyCoro.hpp"   // stackful coroutines (round 75)
#include "NyGen.hpp"    // lazy generators on those coroutines (src/NyGen.cpp)

using namespace std;
using namespace nython;
using namespace nython::io;
using namespace nython::node;
using namespace nython::lexer;
using namespace nython::kernel;
using namespace nython::parser;
using namespace nython::reader;
using namespace nython::exception;

// ═══════════════════════════════════════════════════════════════════════════
// BUILT-IN FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

// Simple execution context that doesn't need full Runnable
static const std::set<std::string> builtin_set = {
    "len","type","str","int","float","bool","range","input","abs",
    "min","max","sum","list","map","print","isinstance","hasattr",
    "hex","oct","bin","ord","chr"
};

// ── Integers ──────────────────────────────────────────────────────────────
// Every interpreter int is stored in a nython::kernel::bigint (Value::value.i),
// but that class's arithmetic is not used: its multiplication is bit-serial,
// its bitwise operators are sign-magnitude and its `long long` conversion
// drops the sign. Ints that fit a machine word are computed as int64_t with
// overflow checks; anything larger goes through nypy::BigInt (NyBigInt.hpp),
// which both engines share. These convert through the limbs directly - the
// old bigint_to_i64 went through a decimal string and std::stoll on every
// arithmetic operation (a quarter of a call-heavy loop's time) and returned 0
// for anything past 64 bits.
inline bool bigint_fits_i64(const nython::kernel::bigint& b, int64_t& out) {
    const auto& d = b.limbs();
    size_t n = d.size();
    while (n && d[n - 1] == 0) n--;
    if (n == 0) { out = 0; return true; }
    if (n > 1) return false;
    uint64_t u = d[0];
    if (!b.isNegative()) {
        if (u > (uint64_t)INT64_MAX) return false;
        out = (int64_t)u;
        return true;
    }
    if (u > (uint64_t)INT64_MAX + 1) return false;
    out = (int64_t)(~u + 1);
    return true;
}
// For callers that need a machine integer (indexes, counts, sizes):
// saturates instead of wrapping when the value does not fit.
inline int64_t bigint_to_i64(const nython::kernel::bigint& bi) {
    int64_t v;
    if (bigint_fits_i64(bi, v)) return v;
    return bi.isNegative() ? INT64_MIN : INT64_MAX;
}
inline nypy::BigInt bigint_to_nbig(const nython::kernel::bigint& b) {
    nypy::BigInt r;
    for (auto l : b.limbs()) { r.mag.push_back((uint32_t)l); r.mag.push_back((uint32_t)((uint64_t)l >> 32)); }
    r.neg = b.isNegative();
    r.trim();
    return r;
}
inline nython::kernel::bigint nbig_to_bigint(const nypy::BigInt& n) {
    std::vector<unsigned long long> d;
    for (size_t i = 0; i < n.mag.size(); i += 2)
        d.push_back((unsigned long long)n.mag[i] | (i + 1 < n.mag.size() ? (unsigned long long)n.mag[i + 1] << 32 : 0ull));
    nython::kernel::bigint r;
    r.assignLimbs(n.neg, std::move(d));
    return r;
}
// Through bigint(long long): `long` is 32 bits on Windows (LLP64), and the
// old Value((long int)v) truncated every integer above 2^31 there.
inline Value intValue(int64_t v) { return Value(nython::kernel::bigint((long long)v)); }
inline Value intValue(const nypy::BigInt& n) {
    int64_t v;
    if (n.to_i64(v)) return intValue(v);
    return Value(nbig_to_bigint(n));
}
inline std::string intToString(const nython::kernel::bigint& b) {
    int64_t v;
    if (bigint_fits_i64(b, v)) return std::to_string(v);
    return bigint_to_nbig(b).to_string();
}
inline double bigint_to_double(const nython::kernel::bigint& b) {
    int64_t v;
    if (bigint_fits_i64(b, v)) return (double)v;
    return bigint_to_nbig(b).to_double();
}

// Safe double extraction from Value (avoids long double -> double warning)
inline double to_double(const Value& v) {
    if (v.type == ValueType::DOUBLE) return static_cast<double>(v.value.d);
    if (v.type == ValueType::INTEGER) return bigint_to_double(v.value.i);
    if (v.type == ValueType::BOOLEAN) return v.value.b ? 1.0 : 0.0;
    return 0.0;
}





// Forward-declare struct so dispatch function signatures compile cleanly.
struct NythonExecutor;
// Reference-counted heap payloads and the collector (round 75).
#include "NyGC.hpp"
#include "NyHeap.hpp"

// ── Forward declarations of module dispatch functions ─────────────────────
// Each is implemented in src/builtins/X.cpp
Value dispatch_tensor   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_nt       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> nt_builtin_names();   // shared tensor natives (src/builtins/tensor.cpp)
Value dispatch_audio    (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_string   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_io       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_network  (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_hash     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> hash_builtin_names();
Value dispatch_pymath   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pymath_builtin_names();
// lib/json.ny's scanner/encoder and lib/random.ny's Mersenne Twister (_json_*, _mt_*)
Value dispatch_pyjson   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pyjson_builtin_names();
Value dispatch_pyrandom (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> pyrandom_builtin_names();
// Regular expressions (round 77): the native engine of lib/re.ny (src/builtins/nyre.cpp).
Value dispatch_re       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> re_builtin_names();
Value dispatch_math     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_os       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_data     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_threading(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_core     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_gui      (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_text     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_lang     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_pycore   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
// isinstance (round 81: called by callBuiltin directly; builtins/tensor.cpp)
Value builtin_isinstance(NythonExecutor& E, std::vector<Value>& args, Context* ctx);


struct NythonExecutor;
// builtins/threading.cpp: runs the pending signal handlers, raising what they raise.
void ny_interp_check_signals(NythonExecutor& E);

struct NythonExecutor {
    Context* global_ctx;
    Runnable* runner;
    std::map<void*, std::string> func_names;
    std::map<int, FILE*> file_handles{};
    int next_file_handle{1000};
    std::map<void*, Context*> closure_contexts;
    // ── Scope lifetime (round 75) ───────────────────────────────────────────
    // A Context is reference counted like every heap object (NyGC.hpp) and
    // is born holding one reference, its creator's. A call's scope is
    // released by its CtxReaper when the call returns; it survives only if
    // something took its own counted reference to it: a function defined in
    // it (nyheap::Func::scope), a child scope (Context::parent), an
    // instance's fields (nyheap::Inst::props), a class body kept in
    // class_ctx_map_. A scope and a function defined in it refer to each
    // other; the cycle collector frees the pair when nothing else does.
    //
    // (Before round 75 an "escaped" set kept every scope a closure or class
    // had ever referred to alive for the life of the process.) A generator
    // running in a scope holds its own reference to it (nygen), so nothing
    // needs to be deferred here.
    void markEscaped(Context*) {}
    void reapContext(Context* c) { if (c) nygc::decref(c); }
    // Releases the creator's reference on scope exit, including when the
    // body exits via a ReturnSignal or a user exception.
    struct CtxReaper {
        NythonExecutor* e;
        Context* c;
        CtxReaper(NythonExecutor* ex, Context* cx) : e(ex), c(cx) {}
        ~CtxReaper() { if (c) e->reapContext(c); }
        void release() { c = nullptr; }
        CtxReaper(const CtxReaper&) = delete;
        CtxReaper& operator=(const CtxReaper&) = delete;
    };
    int64_t closure_id_counter = 0;
    std::map<int64_t, Context*> closure_by_id;
    std::map<void*, int64_t> value_closure_id;
    // Unused since round 75 (strings are nyheap::Str objects, freed with
    // their last reference); kept so code that names it still compiles.
    std::vector<std::unique_ptr<std::string>> string_store;
    std::unordered_set<void*> string_ptrs_; // fast positive lookup for string pointers

    // Strings made so far and their bytes; --profile attributes them per
    // function. Since round 75 a string is freed with its last reference
    // (nyheap::Str); gc_stats() reports the ones alive.
    static long long& strings_created() { static long long n = 0; return n; }
    static long long& string_bytes_created() { static long long n = 0; return n; }

    // The empty string and the 256 one-byte strings are made once and shared
    // (immortal: the tables below hold them for the executor's life), so a
    // character loop (line[i:i+1], string_lower(ch), ch == "a") makes no
    // string per character examined.
    Value small_strs_[257];
    bool small_made_[257] = {};

    // One shared string per distinct text, for names the interpreter itself
    // binds over and over (the parent class set up on every method call of a
    // subclass). Immortal, like the one-byte strings.
    std::unordered_map<std::string, Value> interned_;
    Value internString(const std::string& s) {
        auto it = interned_.find(s);
        if (it != interned_.end()) return it->second;
        Value v = newString(s);
        interned_.emplace(s, v);
        return v;
    }

    // A new string object and the value that holds it.
    Value newString(const std::string& s) {
        auto* so = new nyheap::Str(this, s);
        string_ptrs_.insert((void*)&so->s);
        return nyheap::userValue(so, (void*)&so->s);
    }
    Value newString(std::string&& s) {
        auto* so = new nyheap::Str(this, std::move(s));
        string_ptrs_.insert((void*)&so->s);
        return nyheap::userValue(so, (void*)&so->s);
    }

    // bytes / bytearray values (round 77): nyheap::Bytes, keyed by &s.
    std::unordered_map<void*, nyheap::Bytes*> bytes_ptrs_;
    Value makeBytesValue(std::string s, bool mut = false) {
        auto* bo = new nyheap::Bytes(this, std::move(s), mut);
        bytes_ptrs_.emplace((void*)&bo->s, bo);
        return nyheap::userValue(bo, (void*)&bo->s);
    }
    // ── Kinds of heap values by their objects' flags (round 81) ──────────
    // A USERDATA value's object (value.o) says what the value is when
    // value.p is that object's own payload and this executor made it: the
    // side tables are then known to agree with it (a live Str is listed in
    // string_ptrs_, a live Inst in instance_to_class and func_names, a live
    // Func in func_names), so the hash and tree lookups in them are skipped.
    // Anything else - a value without an owner, another executor's object -
    // still takes the lookups. (nygc::F_K* flags, set by the constructors.)
    enum HeapKind { HK_UNKNOWN = 0, HK_STR, HK_INST, HK_FUNC };
    int heapKind(const Value& v) const {
        nython::gc::Collectable* o = v.value.o;
        if (!o || v.type != ValueType::USERDATA) return HK_UNKNOWN;
        const uint16_t f = o->gc_flags;
        if (f & nygc::F_KSTR) {
            auto* so = static_cast<nyheap::Str*>(o);
            return (v.value.p == (void*)&so->s && so->E == this) ? HK_STR : HK_UNKNOWN;
        }
        if (f & nygc::F_KINST) {
            auto* io = static_cast<nyheap::Inst*>(o);
            return (v.value.p == (void*)&io->tag && io->E == this) ? HK_INST : HK_UNKNOWN;
        }
        if (f & nygc::F_KFUNC) {
            auto* fo = static_cast<nyheap::Func*>(o);
            return (v.value.p == (void*)&fo->id && fo->E == this) ? HK_FUNC : HK_UNKNOWN;
        }
        return HK_UNKNOWN;
    }
    nyheap::Bytes* bytesOf(const Value& v) const {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        if (heapKind(v) != HK_UNKNOWN) return nullptr;   // a str, instance or function (round 81)
        auto it = bytes_ptrs_.find(v.value.p);
        return it == bytes_ptrs_.end() ? nullptr : it->second;
    }
    bool isBytesValue(const Value& v) const { return bytesOf(v) != nullptr; }

    Value makeStringValue(const std::string& s) {
        if (s.size() <= 1) {
            int k = s.empty() ? 256 : (unsigned char)s[0];
            if (small_made_[k]) return small_strs_[k];
            small_made_[k] = true;
            small_strs_[k] = newString(s);
            return small_strs_[k];
        }
        // A single multi-byte character (indexing and iterating a string go
        // by character): shared too, like the one-byte strings.
        if (s.size() <= 4 && (unsigned char)s[0] >= 0xC0 && nypy::u8_seq((unsigned char)s[0]) == s.size()) {
            auto it = interned_.find(s);
            if (it != interned_.end()) return it->second;
            Value cv = newString(s);
            interned_.emplace(s, cv);
            return cv;
        }
        strings_created()++;
        string_bytes_created() += (long long)s.size();
        return newString(s);
    }

    // Get string from a string Value
    bool isStringValue(const Value& v) {
        if (v.type != ValueType::USERDATA) return false;   // round 81: numbers, containers ... at once
        switch (heapKind(v)) {
            case HK_STR: return true;
            case HK_INST: case HK_FUNC: return false;
            default: break;
        }
        if (v.type == ValueType::USERDATA && v.value.p && string_ptrs_.count(v.value.p))
            return true;
        return v.type == ValueType::USERDATA && v.value.p 
            && !bytes_ptrs_.count(v.value.p)
            && !func_names.count(v.value.p) 
            && !instance_to_class.count(v.value.p)
            && !instance_properties.count(v.value.p);
    }
    // func_names stores internal identifiers ("__func__:inner", "__lambda__",
    // "__class__:Point"); render them the way the VM does so the two engines
    // print the same thing.
    // A class statement run again makes a new class, registered as
    // "Name#n" (evalClassDecl); what is shown is Name.
    static std::string shownClassName(const std::string& n) { return nyrt::shown_class_name(n); }
    static std::string funcDisplayName(const std::string& fn) {
        if (fn.rfind("__class__:", 0) == 0) return nyrt::class_repr(fn.substr(10));
        std::string n = fn;
        if (n.rfind("__func__:", 0) == 0) n = n.substr(9);
        if (n == "__lambda__" || n.empty()) n = "<lambda>";
        return "<function " + n + ">";
    }
    std::string getStringValue(Value v) {
        if (v.type == ValueType::USERDATA && v.value.p && string_ptrs_.count(v.value.p)) {
            return *static_cast<std::string*>(v.value.p);
        }
        if (isStringValue(v)) {
            return *static_cast<std::string*>(v.value.p);
        }
        if (v.type == ValueType::USERDATA && v.value.p && !func_names.count(v.value.p)) {
            return *static_cast<std::string*>(v.value.p);
        }
        // A function value fell through to Value::toString(), which renders any
        // USERDATA as the literal "user-data" — so printing a function showed
        // that instead of anything identifying. func_names already holds the
        // name, so use it and match the VM's "<function name>" spelling.
        if (v.type == ValueType::USERDATA && v.value.p) {
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) return funcDisplayName(fit->second);
        }
        return v.toString();
    } // maps USERDATA ptr -> function identifier


    NythonExecutor(const NythonExecutor&) = delete;
    NythonExecutor& operator=(const NythonExecutor&) = delete;
    NythonExecutor(Runnable* r) : global_ctx{nullptr}, runner(r),
        func_names{}, closure_contexts{}, closure_by_id{}, value_closure_id{},
        string_store{}, string_ptrs_{}, builtin_ptrs{},
        func_id_store{}, func_ast_nodes{}, imported_asts{},
        instance_store{}, instance_to_class{}, instance_properties{},
        class_by_name{}, super_parent_stack{}, class_parent{} {
        nyheap::executor_born(this);
        global_ctx = new Context(r, "global");
        registerBuiltins();
        loadPrelude();
    }

    // Nython source every program starts with (include/NyPrelude.hpp): the
    // file objects open() returns. The VM runs the same text.
    void loadPrelude() {
        // The builtin exception classes are real classes, as on the VM:
        // `except ValueError as e` binds an instance (isinstance, e.args,
        // type(e).__name__, __cause__), `raise ValueError` instantiates it
        // and user classes derive from them. They were builtin constructors
        // of message strings.
        try {
            std::string src;
            for (auto& n : nython::ny_builtin_exc_names()) {
                const char* par = nython::ny_builtin_exc_parent(n);
                src += "class " + n + (par && *par ? std::string("(") + par + ")" : std::string()) + ":\n    pass\n";
            }
            auto source = SourceCode(src);
            auto reporter = std::make_shared<Reporter>(source);
            auto lex = std::make_shared<Lexer>(source);
            lex->tokenize();
            auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)runner, lex.get());
            auto ast = parser->parse();
            if (ast) {
                imported_asts.push_back(ast);
                evalNode(ast, global_ctx);
            }
        } catch (...) {
            std::cerr << "[Nython] builtin exception classes failed to load\n";
        }
        try {
            // round 82: parsed once per process (the VM's compiler shares it)
            auto ast = nython::vm::VirtualMachine::shared_prelude_ast();
            if (ast) {
                imported_asts.push_back(ast);
                // round 80: the prelude's code runs in prelude_ctx_, a scope
                // of its own. While the prelude loads it shares the global
                // scope's map (the engine reads the prelude's names there);
                // then it gets a copy, so prelude code keeps resolving list,
                // str, len, isinstance ... to the builtins whatever a program
                // rebinds at its top level (CPython's builtins module).
                prelude_ctx_ = new Context(runner, "<prelude>", nullptr, nullptr, global_ctx);
                delete prelude_ctx_->container;
                prelude_ctx_->container = global_ctx->container;
                prelude_ctx_->ns_owner = global_ctx;
                nygc::incref(global_ctx);
                try { evalNode(ast, prelude_ctx_); }
                catch (...) { splitPreludeScope(); throw; }
                splitPreludeScope();
            }
        } catch (std::exception& e) {
            std::cerr << "[Nython] prelude failed to load: " << e.what() << "\n";
        } catch (...) {
            std::cerr << "[Nython] prelude failed to load\n";
        }
        cacheRangeClasses();   // range and the dict views (round 78)
        // --profile measures the program, not the startup prelude (its
        // stream objects were the first calls profiled).
        prof_.clear();
        // What a module's scope sees of the global one (importModule): the
        // builtins and the prelude, not the program's own names.
        if (global_ctx && global_ctx->container)
            for (auto& kv : *global_ctx->container) base_global_names_.insert(kv.first);
        base_names_ver_++;   // round 81: assignName caches against it
        module_filter_ = [this](const std::string& n) {
            return base_global_names_.count(n) > 0 || builtin_ptrs.count(n) > 0 || builtin_set.count(n) > 0;
        };
        // ... and sees them as they were before the program ran (round 77):
        // a program's top-level `list = []` rebound list for every module
        // it imported (collections.abc's `MutableSequence.register(list)`
        // then failed), as the VM never did. A module scope's parent is this
        // copy of the builtins and the prelude; builtins registered later
        // are still found past it in the global scope.
        if (global_ctx && global_ctx->container) {
            module_base_ctx_ = new Context(runner, "<builtins>", nullptr, nullptr, global_ctx);
            module_base_ctx_->parentFilter = &module_filter_;
            for (auto& kv : *global_ctx->container) module_base_ctx_->defineByName(kv.first, kv.second);
        }
    }
    // The mirror classes of the builtin types (NyPrelude.hpp,
    // builtin_mirrors_source; round 77): a type's chunk runs in the global
    // scope the first time a class derives from the type or one of its
    // dunders is read (int.__new__), "dictview" at the first instance
    // __dict__ read: a program that never does pays nothing for them.
    std::unordered_set<std::string> mirrors_loaded_;
    void ensureMirror(const std::string& chunk) {
        if (mirrors_loaded_.count(chunk)) return;
        mirrors_loaded_.insert(chunk);
        if (chunk != "base" && chunk != "os") ensureMirror("base");   // (round 80: "os" needs no mirror base)
        if (chunk == "dictview") ensureMirror("dict");
        try {
            auto source = SourceCode(nyrt::builtin_mirror_chunk(chunk));
            auto reporter = std::make_shared<Reporter>(source);
            auto lex = std::make_shared<Lexer>(source);
            lex->tokenize();
            auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)runner, lex.get());
            auto ast = parser->parse();
            if (ast) {
                imported_asts.push_back(ast);
                // round 80: in the prelude's scope (its builtins are the real
                // ones whatever the program rebinds), the names it adds then
                // copied to the global scope and the modules' snapshot
                Context* pc = prelude_ctx_ ? prelude_ctx_ : global_ctx;
                std::unordered_set<std::string> had;
                if (pc != global_ctx) for (auto& kv : *pc->container) had.insert(kv.first);
                evalNode(ast, pc);
                if (pc != global_ctx)
                    for (auto& kv : *pc->container) {
                        if (had.count(kv.first)) continue;
                        global_ctx->defineByName(kv.first, kv.second);
                        if (module_base_ctx_) module_base_ctx_->defineByName(kv.first, kv.second);
                        base_global_names_.insert(kv.first);
                        base_names_ver_++;   // round 81
                    }
            }
        } catch (std::exception& e) {
            std::cerr << "[Nython] builtin mirror '" << chunk << "' failed to load: " << e.what() << "\n";
        }
        mro_cache_.clear(); specInvalidate();
    }
    // The prelude's scope gets its own copy of the global map (loadPrelude).
    void splitPreludeScope() {
        if (!prelude_ctx_ || prelude_ctx_->ns_owner != global_ctx) return;
        auto* own = new ContainerType(*global_ctx->container);
        prelude_ctx_->container = own;
        prelude_ctx_->ns_owner = nullptr;
        nygc::decref(global_ctx);
    }
    // A class naming `name` as a base needs its mirror.
    void mirrorsFor(const std::string& name) {
        if (nyrt::builtin_mirror(name) && !mirrors_loaded_.count(name) && !classNodeByName(name)) ensureMirror(name);
    }
    std::unordered_set<std::string> base_global_names_;
    Context* module_base_ctx_ = nullptr;
    Context* prelude_ctx_ = nullptr;   // the prelude's own scope (round 80, loadPrelude)
    std::function<bool(const std::string&)> module_filter_;
    // Functions and classes an imported module defined (importModule):
    // knownName() does not count them for the program.
    std::unordered_set<void*> module_owned_;

    ~NythonExecutor() {
        heapTeardown();
        nyheap::executor_died(this);
    }

    void registerBuiltin(const std::string& name) {
        // Skip if already registered
        if (builtin_ptrs.count(name)) return;
        Value v;
        v.type = ValueType::USERDATA;
        v.value.p = nullptr;
        // Store a unique pointer per builtin
        builtin_ptrs[name] = std::make_unique<std::string>(name);
        v.value.p = (void*)builtin_ptrs[name].get();
        func_names[v.value.p] = "__builtin__:" + name;
        global_ctx->defineByName(name, v);
    }

    std::unordered_map<std::string, std::unique_ptr<std::string>> builtin_ptrs;
public:
    // Used by the VM builtin bridge in main.cpp: is `name` a builtin this
    // executor registered, and where should a bridged call be evaluated?
    bool hasBuiltin(const std::string& name) const {
        return builtin_ptrs.find(name) != builtin_ptrs.end();
    }
    Context* globalContext() { return global_ctx; }
public:   // NythonExecutor is a struct: members default to public

    void registerBuiltins() {
        // Built-in values
        global_ctx->defineByName("true", Value(true));
        global_ctx->defineByName("false", Value(false));
        global_ctx->defineByName("none", NONE_VALUE);
        global_ctx->defineByName("null", NONE_VALUE);
        global_ctx->defineByName("undefined", UNDEFINED_VALUE);
        // Built-in functions
        std::vector<std::string> builtins = {
            "__format_value__","ascii",
            "print","println","range","len","type","str","int","float","bool",
            "bytes","bytearray",
            "input","abs","min","max","round","sorted","reversed",
            "list","tuple","dict","set","frozenset","map","filter","reduce","zip",
            "enumerate","sum","any","all","hasattr","getattr","setattr","delattr",
            "isinstance","issubclass","id","hash","hex","oct","bin",
            "chr","ord","repr","format","open","exit","quit",
            "pow","divmod","input","dict","display","show","is_int","is_float","is_string","is_list","is_none","is_bool","to_int","to_float","to_str","clamp","lerp","map_range","repeat_str","repeat","flatten","flat","shell","system","ls","cat","pwd","mkdir","write","exists","env","all","any","complex","slice","super","property",
            "staticmethod","classmethod","callable","dir","vars","globals","locals","eval","exec","compile","_ny_setattr_raw","_ny_delattr_raw","_ny_object_new","_ny_method_new","_ny_subclasses","_ny_type_new","_ny_type_call",
            "_ny_main_globals","_ny_exc_current","_ny_stack",
            "_ny_main_set","_ny_main_del","_ny_globals_view",   // globals() as a live view (round 81)
            "_ny_getrefcount","_ny_frame_jump",                 // sys.getrefcount, frame.f_lineno = n (round 81)
            "_ny_modules","_ny_module_new","_ny_module_exec","_ny_find_module",   // sys.modules, importlib (round 80)
            "_ny_sys_info","_ny_recursion_limit",                                 // sys's facts (round 80)
            "_ny_frame_get","_ny_frame_sync","_ny_frame_back","_ny_frame_globals","_ny_builtins_dict",   // frame objects (round 78)
            "_ny_settrace","_ny_setprofile","_ny_gettrace","_ny_getprofile","_ny_frame_local_set",   // sys.settrace ... (round 79)
            "sys.settrace","sys.setprofile","sys.gettrace","sys.getprofile",   // the same, named as sys's (__name__ "settrace")
            "_ny_fn_info","_ny_fn_globals","_ny_keywords",   // inspect, f.__code__, keyword (round 77)
            "_ny_unicode_lookup","_ny_unicode_name",          // unicodedata (round 77)
            "_ny_payload","_ny_payload_new","_ny_getattr_raw","_ny_setfield","_ny_delfield",   // builtin subclasses, __getattribute__, __dict__ (round 77)
            "_ny_getfield","_ny_mark_slots","_ny_slot_flags","_ny_switch_class",   // __slots__, __class__ assignment (round 79)
            "iter","next","help","Set","Counter","OrderedDict","deque","defaultdict","assert",
            "islice","take",   // lazy iteration (src/NyGen.cpp), both engines
            "_ny_range_iter","_ny_dict_iter",   // range and dict-view iterators (round 78)
            "sqrt","sin","cos","tan","log","floor","ceil",
            "keys","values","items",
            "read_file","write_file","file_exists",
            "string_split","string_join","string_replace","string_contains",
            "string_lower","string_upper","string_strip","string_startswith",
            "string_endswith","string_format","string_count","string_find","string_slice",
            // ── Runtime language-extension builtins ──
            "lang_define_token","lang_define_rule","lang_define_macro",
            "lang_define_infix","lang_define_prefix","lang_define_operator",
            "lang_remove_token","lang_remove_rule","lang_remove_operator",
            "lang_list_tokens","lang_list_rules","lang_list_operators",
            "lang_registry_json","lang_eval","lang_version","lang_reset",
            // ── Native text services for editors (src/builtins/text.cpp) ─────
            "text_words","ny_symbols","ny_check_syntax","text_diff","fs_list_files","fs_search",
            "text_fold_ranges","text_line_stats","text_todos","fs_todos","text_format_nython",
            "ac_index_new","ac_index_set_base","ac_index_scan","ac_index_rank","text_diff_classify","fs_symbols","ny_check_file","fs_line_stats",
            "text_defuse",   // round 79: the static half of the debugger's dynamic slices
            "ny_facts",      // round 82: per-function facts from the real parser (lib/nyxai)
            // ── GUI builtins — value-returning ──────────────────────────────
            "gui_get_error","gui_sdl_version","gui_get_display_size","gui_get_window_size","gui_set_window_size","gui_set_cursor","gui_hash_id","gui_display_scale","gui_display_density","gui_video_driver","gui_window_scale","gui_measure_text_w","gui_set_clipboard","gui_get_clipboard",
            "gui_wait_events","gui_set_min_size","gui_set_fullscreen","gui_is_fullscreen","gui_show_open_dialog","gui_show_save_dialog","gui_set_text_input_area","gui_draw_arc","gui_draw_text_wrapped","gui_wrap_text","gui_font_metrics","gui_image_size","gui_free_image","gui_push_clip","gui_pop_clip","gui_push_offset","gui_pop_offset","gui_ticks","gui_next_event","gui_event_get",
            // ── Previously implemented but never registered ──────────────
            // The module dispatchers implement 537 builtins; only 197 were
            // registered as global names, so the rest were unreachable and
            // silently evaluated to none. os_listdir, file_read, file_write,
            // getcwd, path_join and the whole filesystem layer were among
            // them, which is why the IDE could not open a real folder.
            "accuracy","agent_broadcast","agent_io","agent_listen","agent_net","agent_recv","agent_send","append_file",
            "append_text","argmax","argmin","array","atan2","attention","avg_pool1d","base64_decode",
            "base64_encode","batch_norm","batchnorm","binary_cross_entropy","broadcast","chdir","cmd","conv1d",
            "cos_sim","cosine_similarity","cross_entropy_loss","ctc_loss","device_info","dns_resolve","dropout","elu",
            "embedding","embedding_lookup","env_get","eprint","exec_cmd","exp","fclose","fft_magnitude",
            "file_append","file_close","file_copy","file_delete","file_open","file_read","file_readline","file_readlines",
            "file_read_bytes","file_readline_bytes","file_truncate","file_fileno",
            "stream_write","stream_flush","stream_isatty","stream_readline","stream_read",
            "file_rename","file_size","file_mtime","fuzzy_score","fuzzy_positions","fuzzy_rank","file_write","file_writelines","flush","fprint","fread","freadline",
            "fs_mkdirs","fs_stat","fs_walk","function","fwrite","gelu","getcwd","getenv",
            "gethostbyname","hash_md5","hash_sha256","hex_decode","hex_encode","html_strip","htonl","htons",
            "http_parse_request","http_respond","huber_loss","inet_aton","inet_ntoa","integer","ip_to_string","is_dict",
            "isalpha_str","isdigit_str","kb_load","kb_save","keepalive","kv_all","kv_del","kv_get",
            "kv_keys","kv_set","layer_norm","layernorm","leaky_relu","linspace","list_dir","listdir",
            "load_text","logspace","logsumexp","mat","mat_get","mat_mul","mat_shape","mat_transpose",
            "matmul","matrix","max_pool1d","md5","mel_filterbank","mfcc","mish","model_load",
            "model_save","mse_loss","multi_head_attention","mutex_create","mutex_lock","mutex_unlock","norm","ntohl",
            "ntohs","numerical_gradient","one_hot","ones","os_exec","os_exists","os_getcwd","os_getenv",
            "os_isdir","os_isfile","os_listdir","os_mkdir","os_path_abs","os_path_basename","os_path_dirname","os_path_ext",
            "os_path_join","os_remove","os_rename","os_setenv","path_basename","path_dirname","path_exists","path_ext",
            "path_isdir","path_isfile","path_join","popen","print_err","print_to","process_exec","rand_tensor",
            "randint","randn_tensor","random_choice","random_float","random_int","random_range","random_sample","random_seed",
            "random_shuffle","random_tensor","rcvbuf","re_findall","re_match","re_replace","re_search","re_split",
            "re_sub","re_test","read_bytes","read_text","readlines","regex_extract","regex_findall","regex_match",
            "regex_replace","regex_search","regex_split","relu","remove_file","return","reuseaddr","reuseport",
            "save_text","scaled_dot_attention","semaphore_acquire","semaphore_create","semaphore_release","sha256","sigmoid","signal_rms",
            "signal_window","signal_zero_crossings","silu","sizeof","sleep","sndbuf","socket_accept","socket_bind",
            "socket_close","socket_connect","socket_create","socket_create_tcp","socket_create_udp","socket_getpeername","socket_getsockname","socket_listen",
            "socket_recv","socket_recvfrom","socket_select","socket_send","socket_sendto","socket_setsockopt","socket_shutdown","socket_tcp",
            "socket_udp","softmax","softplus","std_dev","stft_magnitude","string","string_to_ip","swish",
            "tanh","tanh_act","tanh_fn","tcp_accept","tcp_close","tcp_connect","tcp_recv","tcp_recv_all",
            "tcp_send","tcp_server_create","tensor","tensor2d_conv","tensor2d_get","tensor2d_maxpool","tensor2d_set","tensor_abs",
            "tensor_add","tensor_apply","tensor_arange","tensor_argmax","tensor_argmin","tensor_benchmark","tensor_clamp","tensor_clip",
            "tensor_concat","tensor_corr","tensor_cosine_sim","tensor_cummax","tensor_cummin","tensor_cumprod","tensor_cumsum","tensor_diag",
            "tensor_diff","tensor_dot","tensor_dot_product","tensor_exp","tensor_eye","tensor_flatten","tensor_flip","tensor_gather",
            "tensor_histogram","tensor_linspace","tensor_load","tensor_log","tensor_matmul","tensor_max","tensor_mean","tensor_median",
            "tensor_min","tensor_mul","tensor_neg","tensor_norm","tensor_normalize","tensor_ones","tensor_outer","tensor_pad",
            "tensor_percentile","tensor_pow","tensor_rand","tensor_randn","tensor_reshape","tensor_roll","tensor_save","tensor_scale",
            "tensor_scatter_add","tensor_sign","tensor_slice","tensor_softmax","tensor_sort","tensor_split","tensor_sqrt","tensor_stack",
            "tensor_std","tensor_sub","tensor_sum","tensor_topk","tensor_transpose","tensor_unique","tensor_var","tensor_variance",
            "tensor_where","tensor_zeros","tensor_zscore","text_bow","text_char_ids","text_from_ids","text_ngrams","text_tokenize",
            "thread_create","thread_join","time_clock","time_date","time_elapsed","time_format","time_timestamp","typeof",
            "typeof_val","uniform","url_decode","url_encode","variance","where","write_bytes","write_text",
            "writelines","zeros","zip_extract_text","zip_list",
            "gui_create_window","gui_load_font","gui_measure_text",
            "gui_load_image","gui_poll_events",
            "gui_video_time","gui_video_duration",
            "gui_load_video",
            // ── GUI builtins — void (rendering, window ops) ─────────────────
            "gui_destroy_window","gui_center_window",
            "gui_maximize_window","gui_minimize_window","gui_restore_window",
            "gui_set_window_title","gui_set_window_icon",
            "gui_clear","gui_present",
            "gui_fill_rect","gui_draw_rect",
            "gui_fill_rounded_rect","gui_draw_rounded_rect",
            "gui_draw_text","gui_draw_image",
            "gui_draw_line","gui_draw_circle","gui_fill_circle",
            "gui_draw_shadow","gui_draw_gradient",
            "gui_draw_polygon","gui_fill_polygon",
            "gui_set_clip","gui_clear_clip",
            "gui_set_viewport","gui_clear_viewport",
            "gui_video_play","gui_video_pause","gui_video_stop",
            "gui_video_seek","gui_video_volume","gui_video_render",
            // ── JSON ────────────────────────────────────────────────────────
            "json_encode","json_decode","json_parse","json_stringify",
            // ── HTTP / network ───────────────────────────────────────────────
            "http_get","http_post","http_request","http_get_json","http_post_json",
            // ── Time ─────────────────────────────────────────────────────────
            "time_ms","time_now","time_sleep","thread_sleep",
            // ── Round 74: OS / filesystem / process / time (builtins/os*.cpp)
            // Every name here works on both engines (the VM through the
            // builtin bridge).
            "os_path_split","os_path_splitext","os_path_normpath","os_path_normalize",
            "os_path_abspath","os_path_realpath","os_path_relpath","os_path_isabs",
            "os_path_expanduser","os_path_expandvars","os_path_commonpath",
            "os_path_exists","os_path_isdir","os_path_isfile","os_path_islink",
            "os_path_getsize","os_path_getmtime","os_fnmatch","fnmatch","os_glob","glob",
            "os_islink","os_access","os_stat","os_lstat","os_makedirs","os_rmdir","os_rmtree",
            "os_walk","os_unlink","os_copy","os_copyfile","os_copytree","os_move","os_chmod",
            "os_symlink","os_readlink","os_touch","os_utime","append","os_gettempdir","os_mkstemp",
            "os_mkdtemp","os_disk_usage","os_chdir","cd","sh",
            "os_unsetenv","os_environ","os_platform","os_cpu_count","os_hostname",
            "os_username","os_home","os_uname","os_get_terminal_size","os_terminal_size",
            "_ny_os_call",   // the os namespace's raising listdir, rename, mkdir, fstat, ... (round 77)
            "os_system","os_run","subprocess_run","os_spawn","os_proc_read","os_poll","os_proc_write","os_proc_close_stdin",
            "os_proc_fds",   // round 82: asyncio waits on a child's pipes through its loop's reactor
            "os_wait","os_kill","os_getpid","os_getppid","shell_quote","os_shell_quote","os_shell",
            "which","os_which","sys_argv",
            "time","clock","time_ns","time_monotonic","monotonic","time_perf_counter",
            "perf_counter","time_process","process_time","time_strftime","time_localtime",
            "time_gmtime","time_mktime","time_timegm","time_strptime","time_iso",
            "time_parse_iso","uuid","gen_uuid","sleep_ms",
            "file_open_or_raise","file_seek","file_tell","file_flush",
            // ── Memory management (round 75; the same names on the VM) ─────
            "gc_collect","gc_enable","gc_disable","gc_is_enabled","gc_isenabled","gc_stats",
            "gc_live_objects","gc_set_threshold","gc_get_threshold","mem_rss_kb","mem_peak_rss_kb","weakref"
        };
        for (auto& name : builtins) registerBuiltin(name);
        // Concurrency runtime (src/NyConc.cpp): threads, locks, channels,
        // futures, task groups, async. Same names and semantics on the VM.
        for (auto& name : nyconc::builtin_names()) registerBuiltin(name);
        for (auto& name : nyconc::exception_names()) registerBuiltin(name);
        // Shared tensor natives (include/NyTensor.hpp): the same kernels the
        // VM registers, so both engines resolve these names identically.
        for (auto& name : nt_builtin_names()) registerBuiltin(name);
        // The socket and TLS layers (round 77): the VM reaches them through the bridge.
        for (auto& name : net_builtin_names()) registerBuiltin(name);
        for (auto& name : tls_builtin_names()) registerBuiltin(name);
        for (auto& name : hash_builtin_names()) registerBuiltin(name);
        for (auto& name : pymath_builtin_names()) registerBuiltin(name);
        for (auto& name : pyjson_builtin_names()) registerBuiltin(name);
        for (auto& name : pyrandom_builtin_names()) registerBuiltin(name);
        for (auto& name : re_builtin_names()) registerBuiltin(name);
        // Exception types
        std::vector<std::string> exc_types = {
            "Exception","BaseException","Error",
            "ValueError","TypeError","KeyError","IndexError","AttributeError",
            "NameError","RuntimeError","IOError","OSError","FileNotFoundError",
            "ZeroDivisionError","OverflowError","MemoryError","RecursionError",
            "StopIteration","GeneratorExit","SystemExit","KeyboardInterrupt",
            "AssertionError","NotImplementedError","PermissionError","TimeoutError",
            "IsADirectoryError","NotADirectoryError","FileExistsError","ChildProcessError",
            "ProcessLookupError","InterruptedError","BlockingIOError","ConnectionError",
            "BrokenPipeError","ConnectionRefusedError","ConnectionResetError",
            "LookupError","ArithmeticError","EOFError","ImportError","ModuleNotFoundError",
            "UnicodeError","UnicodeDecodeError","UnicodeEncodeError","UnicodeTranslateError",
            "ConnectionAbortedError","gaierror","herror","StopAsyncIteration",
            "SSLError","SSLCertVerificationError","SSLEOFError","SSLZeroReturnError",
            "SSLWantReadError","SSLWantWriteError","SSLSyscallError"
        };
        for (auto& name : exc_types) registerBuiltin(name);
        // OS constants (os.sep, os.pathsep, os.linesep, os.name)
#ifdef _WIN32
        global_ctx->defineByName("os_sep", makeStringValue("\\"));
        global_ctx->defineByName("os_pathsep", makeStringValue(";"));
        global_ctx->defineByName("os_linesep", makeStringValue("\r\n"));
        global_ctx->defineByName("os_name", makeStringValue("nt"));
#else
        global_ctx->defineByName("os_sep", makeStringValue("/"));
        global_ctx->defineByName("os_pathsep", makeStringValue(":"));
        global_ctx->defineByName("os_linesep", makeStringValue("\n"));
        global_ctx->defineByName("os_name", makeStringValue("posix"));
#endif
        // The running script: `if __name__ == "__main__":` and __file__.
        // evalImport switches both while a module's top level runs.
        global_ctx->defineByName("__name__", makeStringValue("__main__"));
        global_ctx->defineByName("__file__", makeStringValue(nyrt::script_path()));
        global_ctx->defineByName("__spec__", NONE_VALUE);   // a script run directly (round 81)
        // Math constants
        global_ctx->defineByName("PI", Value(3.14159265358979323846));
        global_ctx->defineByName("E", Value(2.71828182845904523536));
        global_ctx->defineByName("TAU", Value(6.28318530717958647692));
        global_ctx->defineByName("INFINITY", Value(std::numeric_limits<double>::infinity()));
#ifndef _WIN32
        // Socket-level option constants (SOL_SOCKET)
        global_ctx->defineByName("SOL_SOCKET",    Value((int)SOL_SOCKET));
        global_ctx->defineByName("SO_REUSEADDR",  Value((int)SO_REUSEADDR));
        #ifdef SO_REUSEPORT
        global_ctx->defineByName("SO_REUSEPORT",  Value((int)SO_REUSEPORT));
        #else
        global_ctx->defineByName("SO_REUSEPORT",  Value((int)SO_REUSEADDR));
        #endif
        global_ctx->defineByName("SO_KEEPALIVE",  Value((int)SO_KEEPALIVE));
        global_ctx->defineByName("SO_BROADCAST",  Value((int)SO_BROADCAST));
        global_ctx->defineByName("SO_RCVBUF",     Value((int)SO_RCVBUF));
        global_ctx->defineByName("SO_SNDBUF",     Value((int)SO_SNDBUF));
        global_ctx->defineByName("SO_LINGER",     Value((int)SO_LINGER));
        global_ctx->defineByName("SO_ERROR",      Value((int)SO_ERROR));
        global_ctx->defineByName("SO_TYPE",       Value((int)SO_TYPE));
        // Protocol-level option constants
        global_ctx->defineByName("IPPROTO_TCP",   Value((int)IPPROTO_TCP));
        global_ctx->defineByName("IPPROTO_UDP",   Value((int)IPPROTO_UDP));
        global_ctx->defineByName("IPPROTO_IP",    Value((int)IPPROTO_IP));
        global_ctx->defineByName("TCP_NODELAY",   Value((int)TCP_NODELAY));
        global_ctx->defineByName("TCP_KEEPIDLE",  Value((int)TCP_KEEPIDLE));
        global_ctx->defineByName("TCP_KEEPINTVL", Value((int)TCP_KEEPINTVL));
        global_ctx->defineByName("TCP_KEEPCNT",   Value((int)TCP_KEEPCNT));
        // Address family and socket type constants
        global_ctx->defineByName("AF_INET",       Value((int)AF_INET));
        global_ctx->defineByName("AF_INET6",      Value((int)AF_INET6));
        global_ctx->defineByName("AF_UNIX",       Value((int)AF_UNIX));
        global_ctx->defineByName("SOCK_STREAM",   Value((int)SOCK_STREAM));
        global_ctx->defineByName("SOCK_DGRAM",    Value((int)SOCK_DGRAM));
        global_ctx->defineByName("SOCK_RAW",      Value((int)SOCK_RAW));
        // Shutdown constants
        global_ctx->defineByName("SHUT_RD",       Value((int)SHUT_RD));
        global_ctx->defineByName("SHUT_WR",       Value((int)SHUT_WR));
        global_ctx->defineByName("SHUT_RDWR",     Value((int)SHUT_RDWR));
        // IP multicast
        global_ctx->defineByName("IP_ADD_MEMBERSHIP",  Value((int)IP_ADD_MEMBERSHIP));
        global_ctx->defineByName("IP_MULTICAST_TTL",   Value((int)IP_MULTICAST_TTL));
        global_ctx->defineByName("IP_MULTICAST_LOOP",  Value((int)IP_MULTICAST_LOOP));
        // Common errno-like socket error values
        global_ctx->defineByName("INADDR_ANY",         Value((int)INADDR_ANY));
        global_ctx->defineByName("INADDR_LOOPBACK",    Value((int)INADDR_LOOPBACK));
        global_ctx->defineByName("INADDR_BROADCAST",   Value((int)INADDR_BROADCAST));
#endif
    }

    Value execute(node_ptr ast) {
        if (!ast) return NONE_VALUE;
        main_ast_ = ast.get();   // round 81: the module frame's code block (f_lineno jumps)
        try {
            return evalNode(ast, global_ctx);
        } catch (std::string& flow) {
            // round 77: the uncaught exception's object, with its traceback,
            // for the report (main.cpp: uncaughtTracebackText)
            if (flow != "break" && flow != "continue") {
                try { uncaught_obj_ = uncaughtException(flow); } catch (...) {}
            }
            // An uncaught raised instance travels as "__exc__:C:__obj__:<ptr>";
            // resolve it to "__exc__:C:message" while the instance still
            // exists, so the top level reports the message, not a pointer.
            if (flow.find(":__obj__:") != std::string::npos)
                throw std::string("__exc__:" + excTypeOf(flow) + ":" + excMessageOf(flow));
            throw;
        }
    }

    // ── return / break / continue without C++ exceptions ─────────────────
    // Every `return` used to throw ReturnSignal and every break/continue a
    // std::string, caught where the function or loop was entered. Unwinding
    // costs microseconds: a call to a one-line function took ~20 us, 80% of
    // it in __gxx_personality_v0 and _Unwind_*.
    //
    // Now the common case sets a pending flag instead and returns normally.
    // Blocks, `if` and every loop check the flag after each statement and
    // stop; the function-call site (evalBody) or the loop consumes it. The
    // flag may only be used where EVERY construct between the statement and
    // its function/loop checks it, so:
    //   - fast_ctx is the context of the function whose body evalBody is
    //     running; a return in any other context (legacy call paths, an
    //     except handler's context...) still throws;
    //   - brk_ok is set only while a loop evaluates its body;
    //   - constructs that run statements but do not check the flag (try,
    //     with, switch, class/namespace/interface bodies, import, macros)
    //     suspend both for their duration (SuspendFast), so a return or
    //     break inside them throws exactly as before and they keep their
    //     finally/__exit__/else handling.
    // Thread-local, so each thread has its own.
    //
    // Exceptions (round 82): a Python exception raised inside Nython code
    // travels the same way - pending 4, the exception string in `exc` (the
    // string a C++ throw would carry) - CPython's error indicator
    // (PyErr_Occurred with a NULL return; its 3.11 zero-cost tables are the
    // C++ throw we keep for everything else). A statement may leave by it
    // where a return may (fast_ctx is its context: canPend); an expression
    // only when the evaluator that asked for its value checks the flag
    // right after (evalP: the `pend` argument evalCall, evalBinary,
    // evalSubscript, ... receive), so a pending exception never reaches
    // code that would go on with the value. evalTry/evalWith take it as
    // their catch clauses take a thrown one; a function's frame records it
    // as it leaves (runFunctionBody, tbUnwind) and hands it on by the flag
    // only when its call site asked (pend), else throws it - so builtins
    // calling back into Nython code, generators, threads and the prelude
    // see the C++ throw as before. Constructs that run user code must take
    // it out of the flag first (takeExc) and put it back (pendExc).
    struct FlowState {
        Context* fast_ctx = nullptr;
        bool brk_ok = false;
        int pending = 0;          // 1 return, 2 break, 3 continue, 4 exception (round 82)
        Value value;              // a pending return's value
        std::string exc;          // a pending exception (round 82)
    };
    // round 82: reached through a constant-initialized per-thread pointer, so
    // a use is one TLS load and a test: the function-local thread_local put
    // its guard and constructor at every inlined use, and the hot checks
    // (pendingSet) stopped being inlined
    static inline constinit thread_local FlowState* t_flow_ = nullptr;
    [[gnu::noinline, gnu::cold]] static FlowState& flowInit() { static thread_local FlowState f; t_flow_ = &f; return f; }
    static FlowState& flow() { FlowState* p = t_flow_; return __builtin_expect(p != nullptr, 1) ? *p : flowInit(); }
    static constexpr int kPendExc = 4;   // round 82
    // round 82: the exception leaves by the flag
    static void pendExc(std::string e) { FlowState& f = flow(); f.exc = std::move(e); f.pending = kPendExc; }
    // round 82: the pending exception, taken out of the flag
    static std::string takeExc(FlowState& f) { std::string e = std::move(f.exc); f.exc.clear(); f.pending = 0; return e; }
    // round 82: whether a statement running in ctx may leave by the flag
    // (every construct up to its function's evalBody checks it)
    static bool canPend(Context* ctx) { return ctx && astSpecOn() && flow().fast_ctx == ctx; }
    static bool isLoopFlow(const std::string& s) { return s == "break" || s == "continue"; }
    struct SuspendFast {
        FlowState& f; Context* c; bool b;
        SuspendFast() : f(flow()), c(f.fast_ctx), b(f.brk_ok) { f.fast_ctx = nullptr; f.brk_ok = false; }
        ~SuspendFast() { f.fast_ctx = c; f.brk_ok = b; }
        SuspendFast(const SuspendFast&) = delete;
        SuspendFast& operator=(const SuspendFast&) = delete;
    };
    // Held while a loop evaluates its body.
    struct LoopBody {
        FlowState& f; bool b;
        explicit LoopBody(FlowState& ff) : f(ff), b(ff.brk_ok) { f.brk_ok = true; }
        ~LoopBody() { f.brk_ok = b; }
        LoopBody(const LoopBody&) = delete;
        LoopBody& operator=(const LoopBody&) = delete;
    };
    // After a loop body: consume a pending break/continue, or leave the loop
    // (without running its else branch) with a pending return still set, so
    // the enclosing statements unwind to evalBody. `lf` is the loop's
    // FlowState reference and `result` its running value.
#define NY_LOOP_FLOW(broke_var) \
    if (lf.pending) { \
        if (lf.pending == 1 || lf.pending == kPendExc) return result; \
        int ny_pf_ = lf.pending; lf.pending = 0; \
        if (ny_pf_ == 2) { broke_var = true; break; } \
        continue; \
    }
    // sys.settrace (round 79): a for loop's header line is reached again
    // before each item after the first and when the items run out, as
    // CPython's line events report it (`node` is the loop's).
#define NY_PYT_HEAD(again) \
    if (__builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0) && (again)) pyEvLineAt(node.get(), true);
    // Runs a function body in fc and returns what the call should return:
    // the value of a `return` (fast or thrown), or - as before - the value
    // of the body's last statement when it runs off the end.
    // `pend` (round 82): an exception the body raised by the pending flag
    // is recorded as leaving the frame (tbUnwind) here, then handed on by
    // the flag (pend) or thrown - marked as recorded (tbUnwound) for the
    // catch clauses of runFunctionBody / runBodyHooked, so they do not
    // record it twice. (runFunctionBody returns the body's value without a
    // copy, as before round 82.)
    static bool& tbUnwound() { static thread_local bool b = false; return b; }
    Value evalBody(node_ptr body, Context* fc, bool pend = false) {
        FlowState& f = flow();
        struct Restore {
            FlowState& f; Context* c; bool b;
            ~Restore() { f.fast_ctx = c; f.brk_ok = b; }
        } _restore{f, f.fast_ctx, f.brk_ok};
        f.fast_ctx = fc;
        f.brk_ok = false;
        try { evalNode(body, fc); }
        catch (JumpSignal&) {
            // (round 81) a jump is always caught inside its own frame; one
            // that is not would leave the frame - stop it here
            jumpResume().clear(); jumpResuming() = false;
            throw std::string("__exc__:SystemError:f_lineno: the jump target was not reached");
        }
        // A function returns what its `return` gave, else None - not the value
        // of its last statement (round 77: `def f(): 5` returned 5 here and
        // None on the VM and in Python).
        Value v = NONE_VALUE;
        if (f.pending) {
            if (f.pending == kPendExc) {   // round 82
                std::string e = takeExc(f);
                tbUnwind(e);
                if (pend) { pendExc(std::move(e)); return v; }
                tbUnwound() = true;
                throw e;
            }
            if (f.pending == 1) { v = f.value; f.value = NONE_VALUE; }
            f.pending = 0;
        }
        return v;
    }
    // round 82: evaluates `n` for an evaluator that checks the pending flag
    // right after - so an exception it raises may come back by the flag
    // (see FlowState): the nodes that can raise one that way are given leave
    // (`pend`), the rest are evaluated as by evalNode.
    Value evalP(const node_ptr& n, Context* ctx) { return evalNode(n, ctx, true); }
    [[gnu::always_inline]] static bool pendingSet() { return __builtin_expect(flow().pending != 0, 0); }
    // round 82: whether `v`, what an evaluator given `pend` returned, left an
    // exception pending. Such an evaluator returns None whenever it leaves
    // one (every `pendExc` site returns NONE_VALUE, and so do evalBody and
    // runFunctionBody when they hand it on), so the flag is read only for a
    // None - CPython's NULL-then-PyErr_Occurred() test.
    [[gnu::always_inline]] static bool raisedBy(const Value& v) {
        return __builtin_expect(v.type == ValueType::NONE, 0) && pendingSet();
    }

    // `pend` (round 82): see evalP - handed to the evaluators that take it
    Value evalNode(const node_ptr& node, Context* ctx, bool pend = false) {
        if (!node) return NONE_VALUE;

        switch (node->type()) {
            case NodeType::SCRIPT: return evalScript(node, ctx);
            case NodeType::STATEMENTS: return evalStatements(node, ctx);
            case NodeType::BLOCK: return evalStatements(node, ctx);
            case NodeType::INTEGER: return evalInteger(node);
            case NodeType::FLOAT: return evalFloat(node);
            case NodeType::STRING: return evalString(node, ctx);
            case NodeType::BYTES: return makeBytesValue(node->tok().value);
            case NodeType::TRUE: return Value(true);
            case NodeType::FALSE: return Value(false);
            case NodeType::NONE: return NONE_VALUE;
            case NodeType::UNDEFINED: return UNDEFINED_VALUE;
            case NodeType::VARIABLE: return evalVariable(node, ctx);
            case NodeType::VARIABLE_DECL: return evalVarDecl(node, ctx, pend);
            case NodeType::ASSIGNMENT: return evalAssignment(node, ctx, pend);
            case NodeType::ASSIGNMENT_AUG: return evalAugAssignment(node, ctx, pend);
            case NodeType::BINARY: return evalBinary(node, ctx, pend);
            case NodeType::UNARY: return evalUnary(node, ctx, pend);
            case NodeType::PRINT: return evalPrint(node, ctx);
            case NodeType::IF: return evalIf(node, ctx, pend);
            case NodeType::WHILE: return evalWhile(node, ctx);
            case NodeType::FOR: return evalFor(node, ctx);
            case NodeType::FUNCTION: return evalFunctionDecl(node, ctx);
            case NodeType::CLASS: { SuspendFast _sf; return evalClassDecl(node, ctx); }
            case NodeType::RETURN: return evalReturn(node, ctx);
            case NodeType::BREAK: {
                FlowState& f = flow();
                if (f.brk_ok) { f.pending = 2; return NONE_VALUE; }
                throw std::string("break");
            }
            case NodeType::CONTINUE: {
                FlowState& f = flow();
                if (f.brk_ok) { f.pending = 3; return NONE_VALUE; }
                throw std::string("continue");
            }
            case NodeType::PASS: return NONE_VALUE;
            case NodeType::CALL: return evalCall(node, ctx, pend);
            case NodeType::ATTRIBUTE: return evalAttribute(node, ctx, pend);
            case NodeType::OPT_CHAIN: return evalOptChain(static_cast<OptChainNode*>(node.get()), ctx);
            case NodeType::CHAIN_HOLE: return static_cast<HoleNode*>(node.get())->slot;
            case NodeType::SUBSCRIPT: return evalSubscript(node, ctx, pend);
            case NodeType::LIST: return evalList(node, ctx);
            case NodeType::COMPLEX: return evalComprehension(node, ctx);
            case NodeType::COMPREHENSION: return evalComprehensionNode(node, ctx);
            case NodeType::MAP: return evalMap(node, ctx);
            case NodeType::TUPLE: return evalList(node, ctx);
            case NodeType::ARRAY: return evalList(node, ctx);
            case NodeType::RANGE: return evalRange(node, ctx);
            case NodeType::TRY: {
                // round 81: try checks the pending flag itself (evalTry), so
                // a return/break/continue in its body or handlers need not throw
                if (astSpecOn()) return evalTry(node, ctx, true);
                SuspendFast _sf; return evalTry(node, ctx);
            }
            case NodeType::RAISE: return evalRaise(node, ctx);
            case NodeType::ASSERT: return evalAssert(node, ctx);
            case NodeType::IMPORT: { SuspendFast _sf; return evalImport(node, ctx); }
            case NodeType::ENUM: return evalEnum(node, ctx);
            case NodeType::SWITCH: { SuspendFast _sf; return evalSwitch(node, ctx); }
            case NodeType::DELETE: return evalDelete(node, ctx);
            case NodeType::MACRO_CALL: { SuspendFast _sf; return evalMacroCall(node, ctx); }
            case NodeType::DYN_BINOP:  return evalDynBinop(node, ctx);
            case NodeType::LAMBDA: return evalLambda(node, ctx);
            case NodeType::REPEAT: return evalRepeat(node, ctx);
            case NodeType::WITH: {
                if (astSpecOn()) return evalWith(node, ctx, true);   // round 81, as try
                SuspendFast _sf; return evalWith(node, ctx);
            }
            case NodeType::NAMESPACE: { SuspendFast _sf; return evalNamespace(node, ctx); }
            case NodeType::INTERFACE: { SuspendFast _sf; return evalInterfaceDecl(node, ctx); }
            case NodeType::YIELD: {
                // Suspends the generator's coroutine; the value is what
                // send() delivers (none for next()) - src/NyGen.cpp.
                auto yn = static_pointer_cast<YieldNode>(node);
                Value yv = yn->expr ? evalNode(yn->expr, ctx) : NONE_VALUE;
                return nygen::yield_value(*this, yv);
            }
            case NodeType::YIELD_FROM: {
                // Delegates next/send/throw/close to the subiterator; the
                // value is the subgenerator's return value.
                auto yf = static_pointer_cast<YieldFromNode>(node);
                Value src = evalNode(yf->expr, ctx);
                return nygen::yield_from(*this, src, ctx);
            }
            case NodeType::GLOBAL: return NONE_VALUE;
            case NodeType::SELF: {
                // `this` in a def whose first parameter is this: that
                // parameter, however the method was bound (round 78)
                // (round 81: no Token copy, no std::string made per read, and
                // the node's caches of where the names were found)
                auto* sn = static_cast<SelfNode*>(node.get());
                if (__builtin_expect(sn->is_this < 0, 0)) sn->is_this = node->tok().value == "this" ? 1 : 0;
                if (sn->is_this) {
                    static const std::string kThis = "this";
                    Value tv = lookupName(kThis, sn->nc_this, ctx);
                    if (tv.type != ValueType::UNDEFINED) return tv;
                }
                static const std::string kSelf = "self";
                return lookupName(kSelf, sn->nc_self, ctx);
            }
            case NodeType::SUPER: return ctx->getByName("super");
            case NodeType::WALRUS: {
                // Walrus operator: (var name = expr) — evaluates expr, stores it, returns value
                auto wn = static_pointer_cast<WalrusNode>(node);
                Value v = evalNode(wn->init, ctx);
                Context* wc = wn->global_ref ? moduleCtx(ctx) : ctx;
                // in a comprehension or generator expression it binds in the
                // scope around it (PEP 572; round 77: the name stayed inside)
                while (!wn->global_ref && wc->parent && (wc->name == "<comprehension>" || wc->name == "<genexpr>"))
                    wc = wc->parent;
                wc->defineByName(wn->name, v);
                return v;
            }
            default: return NONE_VALUE;
        }
    }

    // ─── SCRIPT / STATEMENTS ────────────────────────────────────────────
    // The value of each statement is dropped before the next one starts (a
    // body's last value is still what it evaluates to): holding it kept an
    // object that `L.pop()` removed alive for one more statement, so its
    // __del__ ran late.
    // A block's statements in place (round 81): Node::statements() returns a
    // copy of the vector, an allocation and a reference count per statement
    // each time a block ran.
    static const std::vector<node_ptr>& blockStmts(Node* n) {
        static const std::vector<node_ptr> none;
        switch (n->type()) {
            case NodeType::STATEMENTS: return static_cast<StatementsNode*>(n)->stmts;
            case NodeType::BLOCK: return static_cast<BlockNode*>(n)->stmts;
            case NodeType::SCRIPT: return static_cast<Script*>(n)->decls;
            default: return none;
        }
    }
    Value evalScript(const node_ptr& node, Context* ctx) { return evalStatements(node, ctx); }

    Value evalStatements(const node_ptr& node, Context* ctx) {
        Value result = NONE_VALUE;
        FlowState& f = flow();
        const auto& stmts = blockStmts(node.get());
        size_t start = 0;
        bool resume = false;
        // round 81: a jump (frame.f_lineno) going on inside this block
        if (__builtin_expect(jumpResuming(), 0)) {
            auto& R = jumpResume();
            if (R.empty()) jumpResuming() = false;
            else if (R.front().first == node.get()) {
                start = R.front().second;
                R.erase(R.begin());
                resume = !R.empty();
                if (!resume) jumpResuming() = false;
            }
        }
        // round 82: in a function's own statements every construct up to
        // evalBody checks the pending flag, so an exception raised by a
        // statement's expression may come back by it (evalP)
        const bool pend = f.fast_ctx == ctx && ctx && astSpecOn();
        for (;;) {
            try {
                for (size_t i = start; i < stmts.size(); i++) {
                    const node_ptr& child = stmts[i];
                    if (result.value.o) result = Value();
                    if (__builtin_expect(resume, 0) && i == start) { resume = false; result = resumeInto(child, ctx); }
                    else {
                        noteStatement(child, ctx);
                        result = evalNode(child, ctx, pend);
                    }
                    if (f.pending) return result;
                }
                return result;
            } catch (JumpSignal& js) {
                // round 81: a jump to a statement of this block (or below it)
                if (js.block != node.get()) throw;
                start = js.index;
                resume = !jumpResume().empty();
                result = NONE_VALUE;
            }
        }
    }

    // ─── LITERALS ───────────────────────────────────────────────────────
    Value evalInteger(const node_ptr& node) {
        // The literal's value, made once (round 81): it was parsed from the
        // token's text on every evaluation. An int refers to no heap object,
        // so the node can keep it.
        auto* in = static_cast<IntegerNode*>(node.get());
        if (__builtin_expect(in->made, 1)) return in->made_value;
        const std::string& v = in->tok().value;
        // Up to 18 decimal digits fit an int64 whatever they are.
        if (!v.empty() && v.size() <= 18 && std::all_of(v.begin(), v.end(), [](char c) { return c >= '0' && c <= '9'; }))
            in->made_value = intValue((int64_t)std::strtoll(v.c_str(), nullptr, 10));
        // Prefixed (0x/0o/0b), long or with underscores: exact at any size
        // (literals past 64 bits used to read as 0).
        else in->made_value = intValue(nypy::parse_int_literal(v));
        in->made = true;
        return in->made_value;
    }

    // strtod, not stod: a literal past the double range is inf and one below
    // the normal range a subnormal (1e-320), as Python reads them; stod threw
    // out_of_range for both, which made them 0.0 here and a compile error on
    // the VM.
    Value evalFloat(const node_ptr& node) {
        // strtod, not stod: a literal that underflows or overflows (5e-324,
        // 1e400) is the nearest double or inf, as in Python; stod threw and
        // the literal read 0.0. Made once (round 81), as an int literal.
        auto* fl = static_cast<FloatNode*>(node.get());
        if (__builtin_expect(fl->made, 1)) return fl->made_value;
        fl->made_value = Value(std::strtod(fl->tok().value.c_str(), nullptr));
        fl->made = true;
        return fl->made_value;
    }

    Value evalString(const node_ptr& node, Context* ctx = nullptr) {
        // round 81: the node's token read in place (token() copied it each time)
        const std::string& raw = node->tok().value;
        // round 80: ${...} is interpolated by the parser (a literal holding
        // it becomes an f-string there); a string node still holding it is
        // text - f"${{x}}", a raw string, a Python-mode file - as on the VM
        (void)ctx;
        // A literal is made into a string once, not on every evaluation. The
        // interpreter never frees a string (string_store), so `"a"` inside a
        // loop or a per-frame function used to add a new permanent string on
        // each pass - in the IDE, most of the memory typing consumed.
        auto* sn = dynamic_cast<StringNode*>(node.get());
        if (sn) {
            if (__builtin_expect(sn->interned_by == (const void*)this, 1)) return sn->interned;   // round 81
            if (sn->interned_by != (const void*)this) {
                sn->interned = makeStringValue(raw);
                sn->interned_by = (const void*)this;
            }
            return sn->interned;
        }
        return makeStringValue(raw);
    }

    // ─── VARIABLES ──────────────────────────────────────────────────────


    // The module scope a context belongs to: the root of its scope chain.
    // The module scope a `global` name belongs to: an imported module's own
    // scope (Context::inModule), else the program's global scope.
    static Context* moduleCtx(Context* ctx) {
        while (ctx && !ctx->inModule && ctx->parent) ctx = ctx->parent;
        return ctx;
    }
    // Stores a plain `name = value`: in a class body the class namespace;
    // a name declared `global` at module level; otherwise the nearest
    // existing binding, or a new local (Context::setByName).
    void assignName(VariableNode* vn, const Value& val, Context* ctx) {
        if (vn->global_ref) moduleCtx(ctx)->defineByName(vn->name, val);
        else if (ctx->inClass) ctx->defineByName(vn->name, val);
        else {
            // A builtin's name (len, sorted, max, id, type, open...) assigned
            // in a function is a local of it, as in Python and on the VM
            // (round 77: the nearest binding was the builtin itself in the
            // global scope, which the assignment replaced for the whole
            // program). At the top level it shadows the builtin, as before.
            const std::string& n = vn->name;
            // whether n is a builtin's name, remembered by the node while the
            // set is unchanged (round 81: a string hash per assignment)
            if (vn->base_ver != base_names_ver_ || !astSpecOn()) {
                vn->base_hit = base_global_names_.count(n) > 0;
                vn->base_ver = base_names_ver_;
            }
            const bool base = vn->base_hit;
            if (ctx != global_ctx && base && !program_rebound_.count(n)) {
                Context* c = ctx;
                while (c && !(c->container && c->container->count(n))) c = c->inModule ? nullptr : c->parent;
                if (c == global_ctx) { ctx->defineByName(n, val); return; }
            }
            if (ctx == global_ctx && base) program_rebound_.insert(n);
            ctx->setByName(n, val);
        }
    }
    std::unordered_set<std::string> program_rebound_;   // builtin names the program's top level rebound
    uint32_t base_names_ver_ = 1;   // round 81: bumped whenever base_global_names_ grows

    // A name's value through the scope chain - Context::getByName, walked
    // here with the node's cache (round 81): the name hashed once, and the
    // slot it was found in last tried first at that depth (the key still
    // there makes it the entry). The scopes before it are searched as ever.
    Value lookupName(VariableNode* vn, Context* c) { return lookupName(vn->name, vn->nc, c); }
    Value lookupName(const std::string& n, NameCache& nc, Context* c) {
        if (!astSpecOn()) return c->getByName(n);
        if (__builtin_expect(!nc.hashed, 0)) { nc.hash = ContainerType::hash_key(n); nc.hashed = true; }
        unsigned d = 0;
        for (;;) {
            const ContainerType* m = c->container;
            if (!m) return NONE_VALUE;
            if (d == nc.depth) {
                const ContainerType::value_type* kv = m->slot_at(nc.slot);
                if (kv && kv->first == n) return kv->second;
            }
            long s = m->index_of_h(n, nc.hash);
            if (s >= 0) {
                if (d < 0xFF) { nc.depth = (uint8_t)d; nc.slot = (uint32_t)s; }
                return m->slot_at((size_t)s)->second;
            }
            if (!c->parent) return UNDEFINED_VALUE;
            if (c->parentFilter && !(*c->parentFilter)(n)) return UNDEFINED_VALUE;
            c = c->parent;
            d++;
        }
    }

    Value evalVariable(const node_ptr& node, Context* ctx) {
        auto* vn = static_cast<VariableNode*>((node).get());
        // Check user-defined first
        Value found = lookupName(vn, vn->global_ref ? moduleCtx(ctx) : ctx);
        if (found.type != ValueType::UNDEFINED) return found;
        // Then check builtins — return a USERDATA marker
        if (builtin_set.count(vn->name)) {
            Value v;
            v.type = ValueType::USERDATA;
            v.value.p = nullptr; // null ptr = builtin
            func_names[nullptr] = "__builtin__:" + vn->name; // temporary, overwritten each call
            return v;
        }
        // A name bound nowhere: NameError (it read as undefined and the
        // program carried on). Bound-to-undefined (`x = undefined`) and names
        // that resolve by another route (a class or function an imported
        // module registered) are not errors.
        if (!(vn->global_ref ? moduleCtx(ctx) : ctx)->hasByName(vn->name) && !knownName(vn->name)) {
            // round 81: __class__ in a method is the class defining it
            // (CPython's implicit __class__ cell, the one super() uses)
            if (vn->name == "__class__" && !owner_stack_.empty() && owner_stack_.back()
                && owner_stack_.back()->type() == NodeType::CLASS)
                return classValueOfNode(owner_stack_.back());
            // round 81: a name its function binds, read before it is
            // bound (or after del): CPython's UnboundLocalError
            if (vn->local_read)
                throw std::string("__exc__:UnboundLocalError:cannot access local variable '" + vn->name
                                  + "' where it is not associated with a value");
            std::string hint = suggestName(vn->name);
            if (!hint.empty()) hint = "  (did you mean '" + hint + "'?)";
            throw std::string("__exc__:NameError:name '" + vn->name + "' is not defined" + hint);
        }
        return found;
    }
    // A function, class or builtin registered under this name.
    bool knownName(const std::string& called) {
        if (builtin_set.count(called)) return true;
        for (auto& kv : func_names) {
            if (!module_owned_.empty() && module_owned_.count(kv.first)) continue;
            const std::string& n = kv.second;
            if (n == called
                || (n.rfind("__func__:", 0) == 0  && n.compare(9, std::string::npos, called) == 0)
                || (n.rfind("__class__:", 0) == 0 && n.compare(10, std::string::npos, called) == 0)
                || (n.rfind("__builtin__:", 0) == 0 && n.compare(12, std::string::npos, called) == 0))
                return true;
        }
        return false;
    }

    Value evalVarDecl(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* vd = static_cast<VarDeclNode*>((node).get());
        Value val = vd->init ? (evalNode(vd->init, ctx, pend)) : NONE_VALUE;
        // round 82: the value raised (evalP) - `val` (none), the one named
        // result, so it is still built in place
        if (pend && raisedBy(val)) return val;
        // a, b = gen(): the targets index a list of its values (nygen); an
        // object with __iter__ / __next__ is iterated the same way, as Python
        // unpacks (it was indexed: "'It' object is not subscriptable").
        if (vd->unpack != -2 && !nygen::is_gen(val) && isInstanceValue(val)
            && (instanceHasMethod(val, "__iter__") || instanceHasMethod(val, "__next__")))
            val = nygen::make_iter(*this, val, ctx);
        // a set or a dict is iterated too (its keys), and a list, tuple or
        // string must hold exactly as many items as there are targets - at
        // least as many as the unstarred ones (round 77: extra items were
        // dropped and missing ones an IndexError). VarDeclNode::unpack: n,
        // or -3 - k for a starred list of k other targets.
        if (vd->unpack != -2) {
            Container* uc = contOf(val);
            if (uc && (isSetCont(uc) || seqLen(uc) < 0) && !isGenCont(uc)) val = nygen::make_iter(*this, val, ctx);
            int64_t len = -1;
            if ((uc = contOf(val)) && !isGenCont(uc)) len = seqLen(uc);
            else if (string_ptrs_.count(val.value.p) && val.type == ValueType::USERDATA)
                len = (int64_t)nypy::u8_len(*static_cast<std::string*>(val.value.p));
            int n = vd->unpack;
            if (len >= 0 && n >= 0 && len > n)
                pyRaise("ValueError", "too many values to unpack (expected " + std::to_string(n) + ")");
            if (len >= 0 && n >= 0 && len < n)
                pyRaise("ValueError", "not enough values to unpack (expected " + std::to_string(n) + ", got " + std::to_string(len) + ")");
            if (len >= 0 && n <= -3 && len < -n - 3)
                pyRaise("ValueError", "not enough values to unpack (expected at least " + std::to_string(-n - 3) + ", got " + std::to_string(len) + ")");
        }
        if (vd->unpack != -2 && isInstanceValue(val) && instanceHasMethod(val, "__next__")) {
            std::vector<Value> items, no_args;
            int n = vd->unpack;
            while (n < 0 || (int)items.size() <= n) {
                Value item;
                try { item = callMethod(val, "__next__", no_args, ctx); }
                catch (std::string& exc) { if (excTypeMatches(exc, "StopIteration")) break; throw; }
                items.push_back(item);
            }
            if (n >= 0 && (int)items.size() > n)
                pyRaise("ValueError", "too many values to unpack (expected " + std::to_string(n) + ")");
            if (n >= 0 && (int)items.size() < n)
                pyRaise("ValueError", "not enough values to unpack (expected " + std::to_string(n) + ", got " + std::to_string(items.size()) + ")");
            if (n <= -3 && (int)items.size() < -n - 3)   // round 77
                pyRaise("ValueError", "not enough values to unpack (expected at least " + std::to_string(-n - 3) + ", got " + std::to_string(items.size()) + ")");
            val = makeListValue(items);
        }
        if (vd->unpack != -2 && nygen::is_gen(val)) val = nygen::unpack_list(*this, val, vd->unpack, ctx);
        ctx->defineByName(vd->name, val);
        return val;
    }

    Value evalAssignment(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* an = static_cast<AssignmentNode*>((node).get());
        Value val = evalNode(an->value_node, ctx, pend);
        if (pend && raisedBy(val)) return val;   // round 82: the value raised (evalP; see evalVarDecl)
        if (an->target->type() == NodeType::VARIABLE) {
            auto* vn = static_cast<VariableNode*>((an->target).get());
            // In a class body a name is always bound in the class namespace:
            // setByName found a same-named variable in an enclosing scope and
            // rebound IT (`items = []` in a class body overwrote the global
            // builtin `items`, and the class never got the attribute).
            assignName(vn, val, ctx);
        } else if (an->target->type() == NodeType::SELF) {
            // self = expr (round 77: `self = super().__new__(cls, v)` in a
            // __new__ was dropped)
            ctx->setByName("self", val);
        } else if (an->target->type() == NodeType::ATTRIBUTE) {
            auto* attr = static_cast<AttributeNode*>((an->target).get());
            Value obj = evalNode(attr->object, ctx);
            // an instance's field through the target's cache (round 81)
            if (!(astSpecOn() && heapKind(obj) == HK_INST && storeFast(attr, obj, val))) setAttr(obj, attr->attr, val);
        } else if (an->target->type() == NodeType::SUBSCRIPT) {
            auto* sub = static_cast<SubscriptNode*>((an->target).get());
            Value obj = evalNode(sub->object, ctx);
            Value idx = evalNode(sub->index, ctx);
            // a list's item by an int index (round 81)
            ContainerType::value_type* kv = astSpecOn() ? seqItemSlot(obj, idx, sub->slot_off, true) : nullptr;
            if (kv) kv->second = val; else setItem(obj, idx, val, ctx);
        } else if (an->target->type() == NodeType::CALL) {
            // Slice assignment: arr[1:3] = [20, 30] is parsed as arr.slice(1,3) = [20,30]
            auto* cn = static_cast<CallNode*>((an->target).get());
            if (cn->callee && cn->callee->type() == NodeType::ATTRIBUTE) {
                auto* attr = static_cast<AttributeNode*>((cn->callee).get());
                if (attr->attr == "slice" && cn->args.size() >= 1) {
                    Value obj = evalNode(attr->object, ctx);
                    std::vector<Value> sargs;
                    for (auto& an2 : cn->args) sargs.push_back(evalNode(an2, ctx));
                    assignSlice(obj, sargs, val, ctx);
                }
            }
        }
        return val;
    }

    // The value a registered builtin name evaluates to.
    Value builtinValue(const std::string& name) {
        auto it = builtin_ptrs.find(name);
        if (it == builtin_ptrs.end()) return NONE_VALUE;
        Value v;
        v.type = ValueType::USERDATA;
        v.value.p = (void*)it->second.get();
        return v;
    }

    // `import os`: a namespace over the os_* builtins (os.getcwd,
    // os.path.join, ...) plus os.sep/pathsep/linesep/name and a snapshot of
    // os.environ. The flat os_* names stay registered as well.
    // One os module per program (round 80): every `import os` binds this
    // namespace, as CPython's sys.modules["os"]. One made per import was
    // freed when a function's local `import os` went, and its address,
    // still in namespace_objs_, made the next dict made there a "module"
    // (pickle's **kwargs); it also rebuilt ~300 members per import.
    Value os_ns_cache_ = NONE_VALUE;
    Value makeOsNamespace() {
        // round 80: one os module per program - sys.modules["os"] when it is
        // there (part A), else the one made first (part B's cache: a module
        // made per import was freed with a function's local `import os`, and
        // its address, still in namespace_objs_, typed the next dict made
        // there as a module)
        {
            auto oc = module_ns_.find("os");
            if (oc != module_ns_.end() && contOf(oc->second)) return oc->second;
        }
        if (os_ns_cache_.type != ValueType::NONE) { noteModule("os", os_ns_cache_); return os_ns_cache_; }
        ensureMirror("os");   // the rest of Python's os, in Nython (round 80, NyPrelude.hpp "#@ os")
        std::vector<std::string> names;
        for (auto& kv : builtin_ptrs) names.push_back(kv.first);
        auto* ns = new Object((Runnable*)runner, "os", Type::MAP);
        noteNamespace(ns);
        auto* path = new Object((Runnable*)runner, "path", Type::MAP);
        noteNamespace(path);
        for (auto& m : nyrt::module_members("os", names)) {
            if (m.first == "environ") continue;   // a map, below (os.environ["HOME"])
            if (m.first.rfind("path.", 0) == 0) path->set(m.first.substr(5), builtinValue(m.second));
            else ns->set(m.first, builtinValue(m.second));
        }
        // Python's own members: os.stat_result, os.terminal_size, the raising
        // listdir / rename / mkdir ... (round 77, NyRuntime.hpp)
        for (auto& pm : nyrt::os_python_members()) {
            Value v = global_ctx->getByName(pm.second);
            if (v.type == ValueType::UNDEFINED || v.type == ValueType::NONE) v = builtinValue(pm.second);
            if (v.type != ValueType::UNDEFINED && v.type != ValueType::NONE) (*ns->container)[pm.first] = v;   // set() keeps an existing key
        }
        for (const char* c : {"sep", "pathsep", "linesep", "name"}) {
            Value v = global_ctx->getByName(std::string("os_") + c);
            ns->set(c, v);
            if (std::string(c) == "sep" || std::string(c) == "pathsep") path->set(c, v);
        }
        std::vector<Value> no_args;
        // os.environ / os.environb (round 80): the prelude's _Environ, which
        // writes through to the process environment
        Value envf = global_ctx->getByName("_ny_os_environ");
        if (envf.type == ValueType::USERDATA && envf.value.p) ns->set("environ", callFunctionValue(envf, no_args, global_ctx));
        else ns->set("environ", callBuiltin("os_environ", no_args, global_ctx));
#ifndef _WIN32
        Value envbf = global_ctx->getByName("_ny_os_environb");
        if (envbf.type == ValueType::USERDATA && envbf.value.p) ns->set("environb", callFunctionValue(envbf, no_args, global_ctx));
#endif
        // round 80: the "os" chunk's (name, value) pairs - fspath, scandir,
        // walk, the fd functions, ids, constants; "path.x" into os.path -
        // bound over the flat builtins of those names (None values too)
        {
            Value mem = global_ctx->getByName("_ny_os_members");
            for (auto& pair : nyos_pairs(mem)) {
                if (pair.first.rfind("path.", 0) == 0) (*path->container)[pair.first.substr(5)] = pair.second;
                else (*ns->container)[pair.first] = pair.second;
            }
        }
        ns->set("path", Value((Collectable*)path));
        ns->set("__name__", makeStringValue("os"));
        Value nsv((Collectable*)ns);
        noteModule("os", nsv);
        noteModule("os.path", Value((Collectable*)path));   // sys.modules["os.path"] (round 80)
        os_ns_cache_ = nsv;
        return nsv;
    }

    // The (str, value) pairs of a list of 2-tuples (round 80: _ny_os_members).
    std::vector<std::pair<std::string, Value>> nyos_pairs(const Value& lst) {
        std::vector<std::pair<std::string, Value>> out;
        Container* c = contOf(lst);
        if (!c || !c->container->count("__len__")) return out;
        for (auto& item : seqItems(c)) {
            Container* t = contOf(item);
            if (!t) continue;
            auto kv = seqItems(t);
            if (kv.size() == 2) out.push_back({getStringValue(kv[0]), kv[1]});
        }
        return out;
    }

    Value nyos_list_of(const std::vector<std::string>& items) {
        auto* o = new Object((Runnable*)runner, "list", Type::LIST);
        for (size_t i = 0; i < items.size(); i++) o->set(std::to_string(i), makeStringValue(items[i]));
        o->set("__len__", Value((int)items.size()));
        return Value((Collectable*)o);
    }


    // ─── EXPRESSIONS ────────────────────────────────────────────────────

    // ── Set union / intersection helpers ────────────────────────────────────────
    // ─── SETS (round 77) ────────────────────────────────────────────────
    // A set is a list-like Container ("0".."n-1" in insertion order, and
    // "__len__") marked "__set__" (1: set, 2: frozenset), plus an index
    // "\x02<key>" -> position, so membership is one lookup. The key is the
    // one dicts use (dictKey: 1 == 1.0 == true, tuples and frozensets by
    // content, bytes by value), except that an object with __hash__ is keyed
    // by its hash (equal objects hash alike). The VM's sets follow the same
    // rules (VirtualMachine.hpp, VMVal::is_set).
    static std::string setSlot(const std::string& key) { return std::string(1, '\x02') + key; }
    static bool isFrozenCont(Container* c) {
        auto it = c->container->find("__set__");
        return it != c->container->end() && it->second.type == ValueType::INTEGER && bigint_to_i64(it->second.value.i) == 2;
    }
    Container* setOf(const Value& v) { Container* c = contOf(v); return c && isSetCont(c) ? c : nullptr; }
    // A class whose __hash__ is None (a dataclass with eq=True, Python's
    // `__hash__ = None`): its instances are unhashable (round 77).
    void checkHashable(const Value& v) {
        Node* cn = classNodeOfInstance(v);
        Value m;
        if (cn && findClassMember(cn, "__hash__", m) && m.type == ValueType::NONE)
            pyRaise("TypeError", "unhashable type: '" + typeNameOf(v) + "'");
    }
    std::string setKey(const Value& v) {
        {
            Value p;   // MyInt(1) is the element 1 (round 77)
            if (any_payload_ && payloadKey(v, p)) return setKey(p);
        }
        // an object with __hash__: its dict key, which compares with __eq__
        // among the objects of its hash (round 78: the hash alone, so
        // unequal objects of one hash were one element)
        if (isInstanceValue(v) && instanceHasMethod(v, "__hash__")) return dictKey(v);
        if (Container* c = setOf(v)) {
            if (!isFrozenCont(c)) pyRaise("TypeError", "unhashable type: 'set'");
            std::vector<std::string> parts;
            for (auto& e : seqItems(c)) parts.push_back(setKey(e));
            return nypy::key_of_frozenset(parts);
        }
        return dictKey(v);
    }
    Value newSetValue(bool frozen) {
        auto* obj = new Object((Runnable*)runner, "list", Type::LIST);
        (*obj->container)["__set__"] = intValue(frozen ? 2 : 1);
        (*obj->container)["__len__"] = intValue(0);
        return Value((Collectable*)obj);
    }
    bool setHas(Container* c, const Value& v) { return c->container->count(setSlot(setKey(v))) > 0; }
    bool setAdd(Container* c, const Value& v) {
        std::string slot = setSlot(setKey(v));
        if (c->container->count(slot)) return false;
        int64_t n = seqLen(c);
        (*c->container)[std::to_string(n)] = v;
        (*c->container)[slot] = intValue(n);
        (*c->container)["__len__"] = intValue(n + 1);
        return true;
    }
    bool setDiscard(Container* c, const Value& v) {
        auto it = c->container->find(setSlot(setKey(v)));
        if (it == c->container->end()) return false;
        int64_t at = bigint_to_i64(it->second.value.i), n = seqLen(c);
        c->container->erase(it);
        for (int64_t i = at; i + 1 < n; i++) {
            Value nx = (*c->container)[std::to_string(i + 1)];
            (*c->container)[std::to_string(i)] = nx;
            (*c->container)[setSlot(setKey(nx))] = intValue(i);
        }
        c->container->erase(std::to_string(n - 1));
        (*c->container)["__len__"] = intValue(n - 1);
        return true;
    }
    void setClear(Container* c) {
        std::vector<std::string> drop;
        for (auto& kv : *c->container) if (kv.first != "__set__") drop.push_back(kv.first);
        for (auto& k : drop) c->container->erase(k);
        (*c->container)["__len__"] = intValue(0);
    }
    Value build_set_val(const std::vector<Value>& items, bool frozen = false) {
        Value sv = newSetValue(frozen);
        Container* c = contOf(sv);
        for (auto& v : items) setAdd(c, v);
        return sv;
    }
    std::vector<Value> collect_coll(const Value& v) {
        std::vector<Value> out;
        if (!v.isCollectable() || !v.value.gc) return out;
        auto* cont = dynamic_cast<Container*>(v.value.gc);
        if (!cont || !cont->container) return out;
        auto li = cont->container->find("__len__");
        int len = (li != cont->container->end()) ? (int)bigint_to_i64(li->second.value.i) : 0;
        for (int i = 0; i < len; i++) {
            auto it = cont->container->find(std::to_string(i));
            if (it != cont->container->end()) out.push_back(it->second);
        }
        return out;
    }
    // The other operand of a set operation or method: a set (its index) or
    // any iterable (the keys of its items).
    struct SetKeys {
        Container* set = nullptr;
        std::unordered_set<std::string> keys;
        std::vector<Value> items;
    };
    SetKeys setKeysOf(const Value& v, Context* ctx) {
        SetKeys k;
        if (Container* c = setOf(v)) { k.set = c; k.items = seqItems(c); return k; }
        k.items = iterItems(v, ctx);
        for (auto& e : k.items) k.keys.insert(setKey(e));
        return k;
    }
    bool setKeysHas(const SetKeys& k, const Value& v) {
        return k.set ? setHas(k.set, v) : k.keys.count(setKey(v)) > 0;
    }
    // op: '|' union, '&' intersection, '-' difference, '^' symmetric
    // difference; the result is a set, or a frozenset when a is one.
    Value setOp(char op, const Value& a, const Value& b, Context* ctx) {
        Container* ac = setOf(a);
        std::vector<Value> av = ac ? seqItems(ac) : iterItems(a, ctx);
        SetKeys bk = setKeysOf(b, ctx);
        Value r = newSetValue(ac && isFrozenCont(ac));
        Container* rc = contOf(r);
        if (op == '|') { for (auto& v : av) setAdd(rc, v); for (auto& v : bk.items) setAdd(rc, v); }
        else if (op == '&') { for (auto& v : av) if (setKeysHas(bk, v)) setAdd(rc, v); }
        else if (op == '-') { for (auto& v : av) if (!setKeysHas(bk, v)) setAdd(rc, v); }
        else {
            Value as = ac ? a : build_set_val(av);
            Container* asc = contOf(as);
            for (auto& v : av) if (!setKeysHas(bk, v)) setAdd(rc, v);
            for (auto& v : bk.items) if (!setHas(asc, v)) setAdd(rc, v);
        }
        return r;
    }
    Value setUnion(const Value& a, const Value& b) { return setOp('|', a, b, global_ctx); }
    Value setIntersect(const Value& a, const Value& b) { return setOp('&', a, b, global_ctx); }
    Value setDiff(const Value& a, const Value& b) { return setOp('-', a, b, global_ctx); }
    Value setSymDiff(const Value& a, const Value& b) { return setOp('^', a, b, global_ctx); }
    // a <= b (every element of a is in b)
    bool setSubset(const Value& a, const Value& b, Context* ctx) {
        Container* ac = setOf(a);
        std::vector<Value> av = ac ? seqItems(ac) : iterItems(a, ctx);
        SetKeys bk = setKeysOf(b, ctx);
        for (auto& v : av) if (!setKeysHas(bk, v)) return false;
        return true;
    }
    bool setEqual(Container* a, Container* b) {
        if (seqLen(a) != seqLen(b)) return false;
        for (auto& v : seqItems(a)) if (!setHas(b, v)) return false;
        return true;
    }
    // A set's methods (Python's set / frozenset API). False: not one of them.
    bool setMethod(Container* c, const Value& obj, const std::string& m, std::vector<Value>& args,
                   Context* ctx, Value& out) {
        bool frozen = isFrozenCont(c);
        const std::string tn = frozen ? "frozenset" : "set";
        auto need = [&](size_t n) {
            if (args.size() != n)
                pyRaise("TypeError", tn + "." + m + "() takes exactly " + (n == 1 ? std::string("one argument") : std::to_string(n) + " arguments")
                        + " (" + std::to_string(args.size()) + " given)");
        };
        auto mutating = [&]() {
            if (frozen) pyRaise("AttributeError", "'frozenset' object has no attribute '" + m + "'");
        };
        out = NONE_VALUE;
        if (m == "add") { mutating(); need(1); setAdd(c, args[0]); return true; }
        if (m == "discard") { mutating(); need(1); setDiscard(c, args[0]); return true; }
        if (m == "remove") {
            mutating(); need(1);
            if (!setDiscard(c, args[0])) raiseKeyError(args[0]);   // the key itself (round 77)
            return true;
        }
        if (m == "pop") {
            mutating(); need(0);
            if (seqLen(c) == 0) pyRaise("KeyError", "'pop from an empty set'");
            out = (*c->container)["0"];
            setDiscard(c, out);
            return true;
        }
        if (m == "clear") { mutating(); need(0); setClear(c); return true; }
        if (m == "copy") { need(0); out = build_set_val(seqItems(c), frozen); return true; }
        if (m == "update" || m == "intersection_update" || m == "difference_update" || m == "symmetric_difference_update") {
            mutating();
            if (m == "symmetric_difference_update") need(1);
            Value cur = obj;
            for (auto& a : args) {
                if (m == "update") { for (auto& v : iterItems(a, ctx)) setAdd(c, v); continue; }
                char op = m == "intersection_update" ? '&' : m == "difference_update" ? '-' : '^';
                Value r = setOp(op, cur, a, ctx);
                std::vector<Value> keep = seqItems(contOf(r));
                setClear(c);
                for (auto& v : keep) setAdd(c, v);
            }
            return true;
        }
        if (m == "union" || m == "intersection" || m == "difference") {
            char op = m == "union" ? '|' : m == "intersection" ? '&' : '-';
            Value r = build_set_val(seqItems(c), frozen);
            for (auto& a : args) r = setOp(op, r, a, ctx);
            out = r;
            return true;
        }
        if (m == "symmetric_difference") { need(1); out = setOp('^', obj, args[0], ctx); return true; }
        if (m == "issubset") { need(1); out = Value(setSubset(obj, args[0], ctx)); return true; }
        if (m == "issuperset") { need(1); out = Value(setSubset(args[0], obj, ctx)); return true; }
        if (m == "isdisjoint") {
            need(1);
            for (auto& v : iterItems(args[0], ctx)) if (setHas(c, v)) { out = Value(false); return true; }
            out = Value(true);
            return true;
        }
        if (m == "__contains__" || m == "contains" || m == "has") { need(1); out = Value(setHas(c, args[0])); return true; }
        if (m == "__len__" || m == "size" || m == "length" || m == "len") { out = intValue(seqLen(c)); return true; }
        return false;
    }
    // A set operator, both operands sets/frozensets: | & - ^ and the
    // subset comparisons. False when it is not one.
    bool setBinary(int opc, const Value& lv, const Value& rv, Context* ctx, Value& out) {
        Container* lc = setOf(lv);
        Container* rc = setOf(rv);
        if (!lc || !rc) return false;
        switch (opc) {
            case OP_BOR: out = setOp('|', lv, rv, ctx); return true;
            case OP_BAND: out = setOp('&', lv, rv, ctx); return true;
            case OP_SUB: out = setOp('-', lv, rv, ctx); return true;
            case OP_BXOR: out = setOp('^', lv, rv, ctx); return true;
            case OP_LE: out = Value(setSubset(lv, rv, ctx)); return true;
            case OP_GE: out = Value(setSubset(rv, lv, ctx)); return true;
            case OP_LT: out = Value(seqLen(lc) < seqLen(rc) && setSubset(lv, rv, ctx)); return true;
            case OP_GT: out = Value(seqLen(lc) > seqLen(rc) && setSubset(rv, lv, ctx)); return true;
            default: return false;
        }
    }

    // ─── VALUE KINDS ────────────────────────────────────────────────────
    // Lists, tuples and sets are Containers keyed "0".."n-1" plus "__len__"
    // ("__tuple__" / "__set__" mark the latter two); dicts are Containers
    // without "__len__". Strings, functions, classes and instances are
    // USERDATA pointers told apart by the side tables.
    Container* contOf(const Value& v) const {
        if (!v.isCollectable() || !v.value.gc) return nullptr;
        // round 81: every Container constructor sets F_KCONT, so the flag
        // answers what dynamic_cast did
        nython::gc::Collectable* g = v.value.gc;
        if (!(g->gc_flags & nygc::F_KCONT)) return nullptr;
        auto* c = static_cast<Container*>(g);
        return c->container ? c : nullptr;
    }
    // Length of a list/tuple/set container, -1 if it is not one.
    // (round 81: the marker keys' hashes are computed once - a list read
    // asked for "__len__", "__set__" and "__tuple__" by hashing each again)
    struct MarkerKey {
        std::string key; uint64_t hash;
        explicit MarkerKey(const char* k) : key(k), hash(ContainerType::hash_key(k)) {}
    };
    static const MarkerKey& kLenKey() { static const MarkerKey k("__len__"); return k; }
    static const MarkerKey& kTupleKey() { static const MarkerKey k("__tuple__"); return k; }
    static const MarkerKey& kSetKey() { static const MarkerKey k("__set__"); return k; }
    static const MarkerKey& kGenKey() { static const MarkerKey k("__gen__"); return k; }
    // The slot of a marker key, or -1: the last two slots first (a list or
    // tuple made at once ends with "__len__", then "__tuple__"), then the
    // lookup - keys are unique, so a slot holding it is its slot (round 81).
    static long markerSlot(const ContainerType* m, const MarkerKey& k) {
        const size_t e = m->slot_end();
        for (size_t back = 1; back <= 2 && back <= e; back++) {
            const ContainerType::value_type* kv = m->slot_at(e - back);
            if (kv && kv->first == k.key) return (long)(e - back);
        }
        return m->index_of_h(k.key, k.hash);
    }
    static bool hasMarker(Container* c, const MarkerKey& k) { return markerSlot(c->container, k) >= 0; }
    static int64_t seqLen(Container* c) {
        long s = markerSlot(c->container, kLenKey());
        if (s < 0) return -1;
        return bigint_to_i64(c->container->slot_at((size_t)s)->second.value.i);
    }
    static bool isTupleCont(Container* c) { return hasMarker(c, kTupleKey()); }
    static bool isSetCont(Container* c) { return hasMarker(c, kSetKey()); }
    static bool isGenCont(Container* c) { return hasMarker(c, kGenKey()); }
    // ── list[i] and list[i] = v (round 81) ──────────────────────────────
    // A list or tuple holds its items under "0", "1" ...: getItem and
    // setItem look the decimal key up after their other checks. For an int
    // index into one (not a set, generator, dict or object) in range, these
    // do what those do, the key spelled without a std::string and its slot
    // guessed from the index plus the offset the site saw last (lists keep
    // their items in order, after or before their markers).
    static std::string_view decKey(int64_t j, char* buf) {
        auto r = std::to_chars(buf, buf + 24, j);
        return std::string_view(buf, (size_t)(r.ptr - buf));
    }
    static ContainerType::value_type* seqSlot(ContainerType* m, int64_t j, int8_t& off) {
        char buf[24];
        std::string_view key = decKey(j, buf);
        ContainerType::value_type* kv = m->slot_at_mut((size_t)(j + off));
        if (kv && kv->first == key) return kv;
        long s = m->index_of(key);
        if (s < 0) return nullptr;
        long d = s - (long)j;
        if (d >= -100 && d <= 100) off = (int8_t)d;
        return m->slot_at_mut((size_t)s);
    }
    // The container of a list or tuple an int index reads in range, with
    // its slot; nullptr when getItem's general path must answer.
    ContainerType::value_type* seqItemSlot(const Value& obj, const Value& idx, int8_t& off, bool store) {
        if (idx.type != ValueType::INTEGER || obj.type != ValueType::COLLECTABLE) return nullptr;
        Container* c = contOf(obj);
        if (!c || nygen::is_gen(obj)) return nullptr;
        int64_t n = seqLen(c);
        if (n < 0 || isSetCont(c)) return nullptr;
        if (store && isTupleCont(c)) return nullptr;
        int64_t i;
        if (!bigint_fits_i64(idx.value.i, i)) return nullptr;
        int64_t j = i < 0 ? i + n : i;
        if (j < 0 || j >= n) return nullptr;
        return seqSlot(c->container, j, off);
    }
    bool isInstanceVal(const Value& v) const {
        if (v.type != ValueType::USERDATA) return false;
        switch (heapKind(v)) {   // round 81
            case HK_INST: return true;
            case HK_STR: case HK_FUNC: return false;
            default: break;
        }
        return v.type == ValueType::USERDATA && v.value.p && !string_ptrs_.count(v.value.p)
            && instance_to_class.count(v.value.p);
    }
    // ── range and dict views (round 78; NyRange.hpp) ────────────────────
    // `range`, `dict_keys`, `dict_values` and `dict_items` are the prelude's
    // classes (NyPrelude.hpp); found when the prelude has run (nullptr
    // before, and then range() and d.keys() behave as they used to).
    Node* range_node_ = nullptr;
    Node* view_nodes_[3] = {nullptr, nullptr, nullptr};
    void cacheRangeClasses() {
        range_node_ = classNodeByName("range");
        view_nodes_[0] = classNodeByName("dict_keys");
        view_nodes_[1] = classNodeByName("dict_values");
        view_nodes_[2] = classNodeByName("dict_items");
        if (!view_nodes_[1] || !view_nodes_[2]) view_nodes_[0] = nullptr;
    }
    // The class of an instance, nullptr for anything else.
    // An instance's field scope (instance_properties' entry), nullptr for
    // anything else. Round 81: read from the instance's object when the value
    // owns it (Inst::props is that entry: set together, cleared together).
    Context* instPropsOf(const Value& v) const {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        switch (heapKind(v)) {
            case HK_INST: return static_cast<nyheap::Inst*>(v.value.o)->props;
            case HK_STR: case HK_FUNC: return nullptr;
            default: break;
        }
        auto pit = instance_properties.find(v.value.p);
        return pit == instance_properties.end() ? nullptr : pit->second;
    }
    Node* instClassNode(const Value& v) const {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        switch (heapKind(v)) {   // round 81: an instance's class is in its object too (switchClass keeps both)
            case HK_INST: return (Node*)static_cast<nyheap::Inst*>(v.value.o)->cls;
            case HK_STR: case HK_FUNC: return nullptr;
            default: break;
        }
        auto it = instance_to_class.find(v.value.p);
        return it == instance_to_class.end() ? nullptr : (Node*)it->second;
    }
    // An instance's own field (UNDEFINED if it has none).
    Value instField(const Value& v, const std::string& name) {
        auto pit = instance_properties.find(v.value.p);
        if (pit == instance_properties.end() || !pit->second) return UNDEFINED_VALUE;
        return pit->second->getByName(name);
    }
    bool isRangeValue(const Value& v) const { return range_node_ && instClassNode(v) == range_node_; }
    // A range whose start, stop and step are 64-bit ints: the native paths.
    bool rangeOf(const Value& v, int64_t& start, int64_t& stop, int64_t& step) {
        if (!range_node_ || instClassNode(v) != range_node_) return false;
        Value a = instField(v, "start"), b = instField(v, "stop"), c = instField(v, "step");
        return a.type == ValueType::INTEGER && b.type == ValueType::INTEGER && c.type == ValueType::INTEGER
            && bigint_fits_i64(a.value.i, start) && bigint_fits_i64(b.value.i, stop)
            && bigint_fits_i64(c.value.i, step) && step != 0;
    }
    // range(...) itself: CPython's range_new checks (PyNumber_Index on each
    // argument, a zero step, no keywords) and the object, made here - the
    // class has no __init__.
    Value makeRange(std::vector<Value>& args, const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        if (!kw.empty()) pyRaise("TypeError", "range() takes no keyword arguments");
        if (args.empty()) pyRaise("TypeError", "range expected at least 1 argument, got 0");
        if (args.size() > 3) pyRaise("TypeError", "range expected at most 3 arguments, got " + std::to_string(args.size()));
        auto idx = [&](const Value& x) -> Value {
            if (x.type == ValueType::INTEGER) return x;
            if (x.type == ValueType::BOOLEAN) return intValue((int64_t)(x.value.b ? 1 : 0));
            Value p;
            if (any_payload_ && payloadOf(x, p) && p.type == ValueType::INTEGER) return p;
            if (indexValue(x, p, ctx)) return p.type == ValueType::BOOLEAN ? intValue((int64_t)(p.value.b ? 1 : 0)) : p;
            pyRaise("TypeError", "'" + typeNameOf(x) + "' object cannot be interpreted as an integer");
        };
        Value start = intValue((int64_t)0), stop, step = intValue((int64_t)1);
        if (args.size() == 1) stop = idx(args[0]);
        else {
            start = idx(args[0]);
            stop = idx(args[1]);
            if (args.size() == 3) step = idx(args[2]);
        }
        if (!isTruthy(step)) pyRaise("ValueError", "range() arg 3 must not be zero");
        rv_made_ = true;
        Value inst = newInstance("range", range_node_);
        Context* p = instance_properties[inst.value.p];
        p->defineByName("start", start);
        p->defineByName("stop", stop);
        p->defineByName("step", step);
        return inst;
    }
    // A dict view: its kind (nyrt::DI_KEYS / DI_VALUES / DI_ITEMS) and dict,
    // -1 for anything else.
    int viewOf(const Value& v, Value* dict) {
        if (!view_nodes_[0]) return -1;
        Node* cn = instClassNode(v);
        if (!cn) return -1;
        int k = cn == view_nodes_[0] ? 0 : cn == view_nodes_[1] ? 1 : cn == view_nodes_[2] ? 2 : -1;
        if (k < 0) return -1;
        Value d = instField(v, nyrt::view_field());
        Container* c = contOf(d);
        if (!c || seqLen(c) >= 0 || nygen::is_gen(d)) return -1;
        if (dict) *dict = d;
        return k;
    }
    // d.keys() / d.values() / d.items(): a live view of d.
    Value makeView(const Value& dict, int kind) {
        Node* cn = view_nodes_[kind];
        rv_made_ = true;
        Value inst = newInstance(static_cast<ClassNode*>(cn)->name, cn);
        instance_properties[inst.value.p]->defineByName(nyrt::view_field(), dict);
        return inst;
    }
    // Set once a range or a dict view object has been made: until then no
    // builtin argument can be one (callBuiltin's rangeArgsToLists).
    bool rv_made_ = false;
    void rangeArgsToLists(std::vector<Value>& args) {
        for (auto& a : args) {
            if (a.type != ValueType::USERDATA || !a.value.p || string_ptrs_.count(a.value.p)) continue;
            if (!isRangeValue(a) && viewOf(a, nullptr) < 0) continue;
            std::vector<Value> items;
            if (rangeOrViewItems(a, items)) a = makeListValue(items);
        }
    }
    // The values a range of 64-bit ints or a dict view holds, natively;
    // false for anything else (round 78).
    bool rangeOrViewItems(const Value& v, std::vector<Value>& out) {
        int64_t a, b, s, n;
        if (rangeOf(v, a, b, s)) {
            if (!nyrt::range_len(a, b, s, n)) pyRaise("OverflowError", "Python int too large to convert to C ssize_t");
            out.reserve(out.size() + (size_t)n);
            for (int64_t i = 0; i < n; i++) out.push_back(intValue(nyrt::range_at(a, s, i)));
            return true;
        }
        Value d;
        int k = viewOf(v, &d);
        if (k < 0) return false;
        for (auto& kv : *contOf(d)->container) {
            if (isInternalKey(kv.first)) continue;
            if (k == 0) out.push_back(keyValue(kv.first));
            else if (k == 1) out.push_back(kv.second);
            else out.push_back(makeListValue({keyValue(kv.first), kv.second}, true));
        }
        return true;
    }
    static std::vector<Value> seqItems(Container* c) {
        std::vector<Value> out;
        int64_t n = seqLen(c);
        if (n <= 0) return out;
        out.reserve((size_t)n);
        int8_t off = 0;   // round 81: seqSlot, not find(std::to_string(i))
        for (int64_t i = 0; i < n; i++) {
            if (auto* kv = seqSlot(c->container, i, off)) out.push_back(kv->second);
        }
        return out;
    }
    Value makeListValue(const std::vector<Value>& items, bool tuple = false) {
        auto* obj = new Object((Runnable*)runner, tuple ? "tuple" : "list", Type::LIST);
        // round 81: the keys are new and distinct, so each is appended
        // without being looked for first (the same entries, in the same order)
        ContainerType& m = *obj->container;
        m.reserve(items.size() + 2);
        int64_t i = 0;
        char buf[24];
        for (auto& v : items) m.append_new(std::string(decKey(i++, buf)), Value(v));
        m.append_new(std::string("__len__"), intValue(i));
        if (tuple) m.append_new(std::string("__tuple__"), Value(1));
        return Value((Collectable*)obj);
    }
    // Raises a Python exception the way the interpreter represents them.
    [[noreturn]] static void pyRaise(const std::string& type, const std::string& msg) {
        throw std::string("__exc__:" + type + ":" + msg);
    }
    // Runs a shared-library (nypy) operation, converting its errors.
    template<class F> auto nyCall(F&& f) -> decltype(f()) {
        try { return f(); }
        catch (nypy::PyError& e) { pyRaise(e.type, e.msg); }
    }

    // ─── NUMBERS ────────────────────────────────────────────────────────
    // A numeric operand: k = 1 machine int, 2 big int, 3 float. bool is an
    // int, as in Python (True + True == 2).
    struct Num { int k = 0; int64_t i = 0; double d = 0.0; const nython::kernel::bigint* b = nullptr; };
    static bool asNum(const Value& v, Num& n) {
        switch (v.type) {
            case ValueType::BOOLEAN: n.k = 1; n.i = v.value.b ? 1 : 0; return true;
            case ValueType::INTEGER:
                if (bigint_fits_i64(v.value.i, n.i)) n.k = 1; else { n.k = 2; n.b = &v.value.i; }
                return true;
            case ValueType::DOUBLE: n.k = 3; n.d = (double)v.value.d; return true;
            default: return false;
        }
    }
    static nypy::BigInt numBig(const Num& n) { return n.k == 2 ? bigint_to_nbig(*n.b) : nypy::BigInt(n.i); }
    static double numD(const Num& n) { return n.k == 3 ? n.d : n.k == 2 ? bigint_to_double(*n.b) : (double)n.i; }
    static bool numIsZero(const Num& n) { return n.k == 3 ? n.d == 0.0 : n.k == 1 ? n.i == 0 : false; }
    static bool numIsNeg(const Num& n) { return n.k == 3 ? n.d < 0 : n.k == 1 ? n.i < 0 : n.b->isNegative(); }
    // -1/0/1, or 2 when unordered (a NaN is involved).
    static int numCmp(const Num& a, const Num& b) {
        if (a.k == 1 && b.k == 1) return a.i < b.i ? -1 : a.i > b.i ? 1 : 0;
        return nypy::num_cmp(toNumV(a), toNumV(b));
    }
    enum BinOpCode {
        OP_UNKNOWN = 0, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_FLOORDIV, OP_MOD, OP_POW,
        OP_BAND, OP_BOR, OP_BXOR, OP_LSHIFT, OP_RSHIFT,
        OP_EQ, OP_NE, OP_LT, OP_LE, OP_GT, OP_GE, OP_SEQ, OP_SNE,
        OP_IS, OP_ISNOT, OP_IN, OP_NOTIN, OP_AND, OP_OR, OP_LXOR, OP_COALESCE
    };
    static int binOpCode(const std::string& op) {
        switch (op.size()) {
            case 1: switch (op[0]) {
                case '+': return OP_ADD; case '-': return OP_SUB; case '*': return OP_MUL;
                case '/': return OP_DIV; case '%': return OP_MOD; case '&': return OP_BAND;
                case '|': return OP_BOR; case '^': return OP_BXOR; case '<': return OP_LT;
                case '>': return OP_GT; case '\\': return OP_FLOORDIV;
                default: return OP_UNKNOWN; }
            case 2:
                if (op == "//") return OP_FLOORDIV; if (op == "**") return OP_POW;
                if (op == "==") return OP_EQ; if (op == "!=") return OP_NE;
                if (op == "<=") return OP_LE; if (op == ">=") return OP_GE;
                if (op == "<<") return OP_LSHIFT; if (op == ">>") return OP_RSHIFT;
                if (op == "is") return OP_IS; if (op == "in") return OP_IN;
                if (op == "or" || op == "||") return OP_OR; if (op == "&&") return OP_AND;
                if (op == "^^") return OP_LXOR;
                if (op == "??") return OP_COALESCE;
                return OP_UNKNOWN;
            case 3:
                if (op == "and") return OP_AND; if (op == "xor") return OP_LXOR;
                if (op == "===") return OP_SEQ; if (op == "!==") return OP_SNE;
                if (op == ">>>") return OP_RSHIFT;
                return OP_UNKNOWN;
            default:
                if (op == "not in") return OP_NOTIN; if (op == "is not") return OP_ISNOT;
                if (op == "instanceof") return OP_IS; if (op == "equals") return OP_SEQ;
                return OP_UNKNOWN;
        }
    }
    static const char* opSymbol(int opc) {
        static const char* s[] = {"?", "+", "-", "*", "/", "//", "%", "**", "&", "|", "^", "<<", ">>",
                                  "==", "!=", "<", "<=", ">", ">=", "===", "!==", "is", "is not", "in", "not in", "and", "or", "xor", "??"};
        return (opc >= 0 && opc <= OP_LXOR) ? s[opc] : "?";
    }
    // Arithmetic on two numbers: nypy::arith (NyBigInt.hpp), shared with
    // the VM. The OP_ codes 1..12 are nypy::ArithOp's.
    static nypy::NumV toNumV(const Num& n) {
        if (n.k == 3) return nypy::NumV::F(n.d);
        if (n.k == 1) return nypy::NumV::I(n.i);
        return nypy::NumV::B(bigint_to_nbig(*n.b));
    }
    static Value fromNumV(const nypy::NumV& n) {
        if (n.k == 3) return Value(n.d);
        if (n.k == 1) return intValue(n.i);
        return intValue(n.b);
    }
    Value numArith(int opc, const Num& a, const Num& b) {
        if (opc <= OP_SUB && a.k == 1 && b.k == 1) {   // the common case, inline
            int64_t r;
            if (!(opc == OP_ADD ? nypy::add_ovf(a.i, b.i, r) : nypy::sub_ovf(a.i, b.i, r))) return intValue(r);
        }
        return nyCall([&] { return fromNumV(nypy::arith(opc, toNumV(a), toNumV(b))); });
    }

    // ─── ORDERING ───────────────────────────────────────────────────────
    // Python ordering for the built-in types: numbers, strings (code point
    // order - UTF-8 byte order is the same), and lists/tuples element by
    // element. Returns false when the two are not comparable (the operators
    // then read false, as they always have here, rather than raising).
    // The two values that could not be ordered, for the operators' TypeError
    // (round 77: `[1] < ["a"]` names int and str, as Python does).
    std::string order_fail_l_, order_fail_r_;
    bool orderFail(const Value& a, const Value& b) {
        order_fail_l_ = typeNameOf(a); order_fail_r_ = typeNameOf(b);
        return false;
    }
    bool orderValues(const Value& a, const Value& b, int& res, Context* ctx, int depth = 0) {
        Num x, y;
        if (asNum(a, x) && asNum(b, y)) { res = numCmp(x, y); return res != 2; }
        bool as = isStringValue(a), bs = isStringValue(b);
        if (as && bs) {
            int c = ((std::string*)a.value.p)->compare(*(std::string*)b.value.p);
            res = c < 0 ? -1 : c > 0 ? 1 : 0;
            return true;
        }
        if (as || bs) return orderFail(a, b);
        Container* ca = contOf(a); Container* cb = contOf(b);
        if (ca && cb && depth < 100) {
            int64_t la = seqLen(ca), lb = seqLen(cb);
            // dicts, and a list against a tuple, have no order (round 77)
            if (la < 0 || lb < 0 || isTupleCont(ca) != isTupleCont(cb)) return orderFail(a, b);
            int8_t oa = 0, ob = 0;   // round 81: seqSlot, not find(std::to_string(i))
            for (int64_t i = 0; i < la && i < lb; i++) {
                auto* ia = seqSlot(ca->container, i, oa);
                auto* ib = seqSlot(cb->container, i, ob);
                if (!ia || !ib) return orderFail(a, b);
                if (valuesEqual(ia->second, ib->second, depth + 1)) continue;
                return orderValues(ia->second, ib->second, res, ctx, depth + 1);
            }
            res = la < lb ? -1 : la > lb ? 1 : 0;
            return true;
        }
        // Objects: __lt__ (or the other side's __gt__), then __eq__.
        if ((isInstanceVal(a) || isInstanceVal(b)) && ctx) {
            Value lt;
            if (!binaryDunder("<", a, b, ctx, lt)) return orderFail(a, b);
            if (isTruthy(lt)) { res = -1; return true; }
            Value eq;
            res = (binaryDunder("==", a, b, ctx, eq) ? isTruthy(eq) : identical(a, b)) ? 0 : 1;
            return true;
        }
        return orderFail(a, b);
    }

    // `x in c`
    bool containsValue(const Value& c, const Value& x, Context* ctx) {
        // A generator: consumed up to the first match.
        if (nygen::Gen* g = nygen::gen_of(c)) return nygen::contains(*this, g, x, ctx);
        // A class whose metaclass defines __contains__ / __iter__ (round 77)
        if (!class_meta_.empty() && classNodeOfValue(c)) {
            Value r;
            if (metaCall(c, "__contains__", {x}, ctx, r)) return isTruthy(r);
            for (auto& v : iterItems(c, ctx)) if (valuesEqual(v, x, 0)) return true;
            return false;
        }
        // An object: __contains__, else a search of what it iterates over
        // (__iter__ / __getitem__), stopping at the first match, as in Python.
        if (isInstanceVal(c)) {
            // an int in a range of 64-bit ints in O(1); a key in a keys view
            // (round 78)
            if (x.type == ValueType::INTEGER || x.type == ValueType::BOOLEAN) {
                int64_t ra, rb, rs, xi;
                if (rangeOf(c, ra, rb, rs)) {
                    if (x.type == ValueType::BOOLEAN) xi = x.value.b ? 1 : 0;
                    else if (!bigint_fits_i64(x.value.i, xi)) return false;
                    return nyrt::range_has(ra, rb, rs, xi);
                }
            }
            {
                Value dv;
                if (viewOf(c, &dv) == 0) { Container* dc = contOf(dv); return dictFind(dc, x) != dc->container->end(); }
            }
            if (instanceHasMethod(c, "__contains__")) {
                std::vector<Value> args = {x};
                return isTruthy(callMethod(c, "__contains__", args, ctx));
            }
            if (instanceHasMethod(c, "__iter__") || instanceHasMethod(c, "__getitem__") || instanceHasMethod(c, "__next__"))
                return nygen::contains_iter(*this, c, x, ctx);
            pyRaise("TypeError", "argument of type '" + shownClassName(instanceClassName(c)) + "' is not iterable");
        }
        if (isStringValue(c)) {
            Value px;
            if (any_payload_ && payloadOf(x, px) && isStringValue(px)) return containsValue(c, px, ctx);   // MyStr("a") in "cat" (round 77)
            if (!isStringValue(x)) pyRaise("TypeError", "'in <string>' requires string as left operand, not " + typeNameOf(x));
            return ((std::string*)c.value.p)->find(*(std::string*)x.value.p) != std::string::npos;
        }
        Container* cont = contOf(c);
        // `1 in 5`, `x in None`: TypeError, as in Python (round 77; it was false)
        if (!cont) pyRaise("TypeError", "argument of type '" + typeNameOf(c) + "' is not iterable");
        if (isSetCont(cont)) return setHas(cont, x);   // one lookup (round 77)
        int64_t n = seqLen(cont);
        if (n >= 0) {
            int8_t off = 0;   // round 81: seqSlot, not find(std::to_string(i))
            for (int64_t i = 0; i < n; i++) {
                auto* kv = seqSlot(cont->container, i, off);
                if (kv && valuesEqual(x, kv->second, 0)) return true;
            }
            return false;
        }
        return dictFind(cont, x) != cont->container->end();
    }

    // ─── BINARY OPERATORS ───────────────────────────────────────────────
    // Arithmetic between types that have no such operator: TypeError, as in
    // Python and on the VM (binop). 1 + none used to give none here and 1
    // there; an instance added to anything concatenated its handle's text.
    [[noreturn]] void unsupportedOperands(int opc, const Value& lv, const Value& rv) {
        pyRaise("TypeError", std::string("unsupported operand type(s) for ") + opSymbol(opc) + ": '"
                + typeNameOf(lv) + "' and '" + typeNameOf(rv) + "'");
    }
    Value binaryOp(int opc, Value lv, Value rv, Context* ctx) {
        // Sets: | & - ^ and the subset comparisons (round 77).
        if (opc == OP_BOR || opc == OP_BAND || opc == OP_SUB || opc == OP_BXOR ||
            opc == OP_LT || opc == OP_LE || opc == OP_GT || opc == OP_GE) {
            Value sr;
            if (setBinary(opc, lv, rv, ctx, sr)) return sr;
        }
        // Operator overloading: the left operand's dunder, else the right
        // operand's reflected one (a.__lt__(b), then b.__gt__(a); __add__,
        // then __radd__ - so sum() of objects and 5 + v work). A dunder that
        // exists is used even when it returns none; != falls back to not ==.
        if (isInstanceVal(lv) || isInstanceVal(rv)) {
            Value res;
            if (binaryDunder(opSymbol(opc), lv, rv, ctx, res)) return res;
            if (opc == OP_EQ || opc == OP_NE) {       // no __eq__: identity
                bool same = identical(lv, rv);
                return Value(opc == OP_EQ ? same : !same);
            }
            if (opc == OP_LT || opc == OP_LE || opc == OP_GT || opc == OP_GE)
                pyRaise("TypeError", std::string("'") + opSymbol(opc) + "' not supported between instances of '"
                        + typeNameOf(lv) + "' and '" + typeNameOf(rv) + "'");
        }
        {
            nyheap::Bytes* lb = bytesOf(lv); nyheap::Bytes* rb = bytesOf(rv);
            Value res;
            if ((lb || rb) && bytesBinary(opc, lv, rv, lb, rb, res, ctx)) return res;
        }
        Num x, y;
        bool nums = asNum(lv, x) && asNum(rv, y);
        switch (opc) {
        case OP_ADD: {
            if (nums) return numArith(opc, x, y);
            bool ls = isStringValue(lv), rs = isStringValue(rv);
            if (ls && rs) return makeStringValue(*(std::string*)lv.value.p + *(std::string*)rv.value.p);
            Container* lc = contOf(lv); Container* rc = contOf(rv);
            if ((lc && isSetCont(lc)) || (rc && isSetCont(rc))) unsupportedOperands(opc, lv, rv);
            if (lc && rc && seqLen(lc) >= 0 && seqLen(rc) >= 0) {
                std::vector<Value> items = seqItems(lc);
                for (auto& v : seqItems(rc)) items.push_back(v);
                return makeListValue(items, isTupleCont(lc) && isTupleCont(rc));
            }
            // Lenient: a string on either side concatenates the other's text.
            if (ls || rs) return makeStringValue(strOf(lv, ctx) + strOf(rv, ctx));
            unsupportedOperands(opc, lv, rv);
        }
        case OP_SUB:
            if (nums) return numArith(opc, x, y);
            unsupportedOperands(opc, lv, rv);
        case OP_MUL: {
            if (nums) return numArith(opc, x, y);
            // sequence * int, int * sequence (bool counts as an int)
            const Value* seq = nullptr; Num cnt;
            if (asNum(rv, cnt) && cnt.k != 3) seq = &lv;
            else if (asNum(lv, cnt) && cnt.k != 3) seq = &rv;
            if (seq) {
                int64_t n = cnt.k == 1 ? cnt.i : (numIsNeg(cnt) ? 0 : INT64_MAX);
                if (isStringValue(*seq)) {
                    const std::string& s = *(std::string*)seq->value.p;
                    if (n > 0 && s.size() * (uint64_t)n > (1ull << 32)) pyRaise("MemoryError", "repeated string is too long");
                    return makeStringValue(nypy::repeat_str(s, n));
                }
                if (Container* c = contOf(*seq)) {
                    if (seqLen(c) >= 0) {
                        std::vector<Value> items = seqItems(c), out;
                        for (int64_t t = 0; t < n; t++) out.insert(out.end(), items.begin(), items.end());
                        return makeListValue(out, isTupleCont(c));
                    }
                }
            }
            unsupportedOperands(opc, lv, rv);
        }
        case OP_DIV: case OP_FLOORDIV: case OP_POW:
            if (nums) return numArith(opc, x, y);
            unsupportedOperands(opc, lv, rv);
        case OP_MOD:
            if (isStringValue(lv)) return percentFormat(*(std::string*)lv.value.p, rv, ctx);
            if (nums) return numArith(opc, x, y);
            unsupportedOperands(opc, lv, rv);
        case OP_BAND: case OP_BOR: case OP_BXOR: {
            if (nums) {
                Value r = numArith(opc, x, y);
                if (lv.type == ValueType::BOOLEAN && rv.type == ValueType::BOOLEAN) return Value(isTruthy(r));
                return r;
            }
            // dict | dict: a merged copy, the right one winning (Python 3.9)
            if (opc == OP_BOR) {
                Container* lc = contOf(lv);
                Container* rc = contOf(rv);
                if (lc && rc && seqLen(lc) < 0 && seqLen(rc) < 0 && !isInstanceVal(lv) && !isInstanceVal(rv) && !nygen::is_gen(lv) && !nygen::is_gen(rv)) {
                    Value d = makeDictValue();
                    dictUpdate(contOf(d), lc);
                    dictUpdate(contOf(d), rc);
                    return d;
                }
                // int | None, Foo | Bar: a union type (PEP 604, round 77)
                if (isTypeOperand(lv) && isTypeOperand(rv)) {
                    std::vector<Value> a{lv, rv};
                    return callFunctionValue(global_ctx->getByName("_ny_union"), a, ctx);
                }
            }
            unsupportedOperands(opc, lv, rv);
        }
        case OP_LSHIFT: case OP_RSHIFT:
            if (nums) return numArith(opc, x, y);
            return intValue(0);
        case OP_EQ: return Value(valuesEqual(lv, rv, 0));
        case OP_NE: return Value(!valuesEqual(lv, rv, 0));
        case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            int c = 3;
            if (!orderValues(lv, rv, c, ctx)) {
                if (c == 2) return Value(false);   // a NaN: unordered, not an error
                // values Python cannot order: TypeError (round 77; it read false)
                pyRaise("TypeError", std::string("'") + opSymbol(opc) + "' not supported between instances of '"
                        + order_fail_l_ + "' and '" + order_fail_r_ + "'");
            }
            return Value(opc == OP_LT ? c < 0 : opc == OP_LE ? c <= 0 : opc == OP_GT ? c > 0 : c >= 0);
        }
        case OP_SEQ: case OP_SNE: {
            // Strict (in)equality: same type AND same value, no int/float coercion.
            bool eq = lv.type == rv.type && valuesEqual(lv, rv, 0);
            return Value(opc == OP_SEQ ? eq : !eq);
        }
        case OP_IN: return Value(containsValue(rv, lv, ctx));
        case OP_NOTIN: return Value(!containsValue(rv, lv, ctx));
        case OP_LXOR: return Value(isTruthy(lv) != isTruthy(rv));
        default: return NONE_VALUE;
        }
    }

    // Builtins whose keyword arguments arrive as one trailing map (marked
    // "__kwargs__"): the OS/time natives named here and the round 77
    // natives (network, signals, codecs) by prefix. Every call path uses
    // this test - a call through a namespace (os.makedirs(p, exist_ok=True))
    // used to check only the prefixes and dropped the keyword arguments.
    static bool isKwmapBuiltin(const std::string& n) {
        static const std::unordered_set<std::string> named = {
            "os_run", "subprocess_run", "os_spawn", "os_wait", "os_kill",
            "os_getenv", "getenv", "env", "os_makedirs", "os_rmtree",
            "os_mkstemp", "os_mkdtemp", "os_path_relpath", "os_utime",
            "time_format", "time_date", "time_strftime", "time_iso",
            "file_open", "file_open_or_raise", "os_proc_read", "os_poll"
        };
        if (named.count(n)) return true;
        static const char* pre[] = {"_net_", "_sig_", "_ws_", "_tls_", "_http_", "_struct_", "_codec_", "_cli_", "_hash_", "math_"};
        for (const char* p : pre) if (n.rfind(p, 0) == 0) return true;
        size_t dot = n.find('.');
        return dot != std::string::npos && nypy::type_kind(n.substr(0, dot)) != nypy::MemberKind::Other;
    }
    // Keyword arguments for a builtin that takes them as a trailing map.
    void appendKwMap(std::vector<Value>& args, const nyrt::OrderedKw<Value>& kw) {
        auto* m = new Object((Runnable*)runner, "map", Type::MAP);
        for (auto& kv : kw) m->set(kv.first, kv.second);
        (*m->container)["__kwargs__"] = Value(1);
        args.push_back(Value((Collectable*)m));
    }
    // Keyword arguments a builtin received as a trailing "__kwargs__" map
    // (isKwmapBuiltin): taken off `args`.
    nyrt::OrderedKw<Value> takeKwMap(std::vector<Value>& args) {
        nyrt::OrderedKw<Value> kw;
        if (args.empty()) return kw;
        Container* c = contOf(args.back());
        if (!c || !c->container->count("__kwargs__")) return kw;
        for (auto& kv : *c->container) if (!isInternalKey(kv.first)) kw[nypy::key_payload(kv.first)] = kv.second;
        args.pop_back();
        return kw;
    }
    // `T.m(...)` for a builtin type T (round 77): its class methods
    // (int.from_bytes, bytes.fromhex, dict.fromkeys ...) and its methods
    // called through the type (str.upper(s) is s.upper()).
    bool typeMemberCall(const std::string& name, std::vector<Value>& args_in, Context* ctx, Value& out) {
        size_t dot = name.find('.');
        if (dot == std::string::npos) return false;
        const std::string t = name.substr(0, dot), m = name.substr(dot + 1);
        if (!nypy::type_has_member(t, m)) return false;
        std::vector<Value> args = args_in;
        auto kw = takeKwMap(args);
        auto kwv = [&](const char* k, size_t pos) -> const Value* {
            auto it = kw.find(k);
            if (it != kw.end()) return &it->second;
            return pos < args.size() ? &args[pos] : nullptr;
        };
        if (nypy::type_classmethod(t, m)) {
            if (t == "str" && m == "maketrans") {   // round 80: CPython's three forms (the prelude's)
                if (!kw.empty()) pyRaise("TypeError", "maketrans() takes no keyword arguments");
                out = callFunctionValue(global_ctx->getByName("_ny_str_maketrans"), args, ctx);
                return true;
            }
            if (m == "from_bytes") {
                const Value* b = kwv("bytes", 0);
                if (!b) pyRaise("TypeError", "from_bytes() missing required argument 'bytes' (pos 1)");
                nypy::BArg ba = toBArg(*b, ctx);
                std::string data = ba.k == nypy::BArg::BYTES ? ba.s : nyCall([&] {
                    std::vector<nypy::BArg> one = {ba};
                    return nypy::bytes_construct(one, "utf-8", "strict", false, "bytes"); });
                const Value* bo = kwv("byteorder", 1);
                std::string order = bo ? strOf(*bo, ctx) : std::string("big");
                if (order != "big" && order != "little") pyRaise("ValueError", "byteorder must be either 'little' or 'big'");
                auto sg = kw.find("signed");
                bool sgn = sg != kw.end() && isTruthy(sg->second);
                out = intValue(nyCall([&] { return nypy::int_from_bytes(data, order == "little", sgn); }));
                return true;
            }
            if (m == "fromhex") {
                if (args.size() != 1 || !isStringValue(args[0])) pyRaise("TypeError", "fromhex() argument must be str");
                std::string h = *(std::string*)args[0].value.p;
                if (t == "float") {
                    double d = std::strtod(h.c_str(), nullptr);
                    out = Value(d);
                    return true;
                }
                out = makeBytesValue(nyCall([&] { return nypy::bytes_fromhex(h); }), t == "bytearray");
                return true;
            }
            if (m == "maketrans") {
                if (args.size() != 2) pyRaise("TypeError", "maketrans expected 2 arguments, got " + std::to_string(args.size()));
                nypy::BArg a = toBArg(args[0], ctx), b = toBArg(args[1], ctx);
                if (a.k != nypy::BArg::BYTES || b.k != nypy::BArg::BYTES) pyRaise("TypeError", "a bytes-like object is required");
                if (a.s.size() != b.s.size()) pyRaise("ValueError", "maketrans arguments must have same length");
                std::string table(256, '\0');
                for (int k = 0; k < 256; k++) table[(size_t)k] = (char)k;
                for (size_t k = 0; k < a.s.size(); k++) table[(unsigned char)a.s[k]] = b.s[k];
                out = makeBytesValue(table);
                return true;
            }
            if (m == "fromkeys") {
                if (args.empty()) pyRaise("TypeError", "fromkeys expected at least 1 argument, got 0");
                Value v = args.size() >= 2 ? args[1] : NONE_VALUE;
                auto* obj = new Object((Runnable*)runner, "map", Type::MAP);
                Value d((Collectable*)obj);
                for (auto& k : iterItems(args[0], ctx)) dictSet(obj, k, v);
                out = d;
                return true;
            }
            return false;
        }
        // An instance method through its type: the receiver must be of it.
        if (args.empty()) pyRaise("TypeError", "unbound method " + t + "." + m + "() needs an argument");
        std::string have = typeNameOf(args[0]);
        Value self = args[0];
        // an instance of a class deriving from t: the method on the value it
        // holds, as CPython's str.upper(MyStr("q")) (round 77)
        { Value p; if (any_payload_ && payloadOf(args[0], p) && typeNameOf(p) == t) { self = p; have = t; } }
        bool ok = have == t || (t == "int" && have == "bool");
        if (!ok) pyRaise("TypeError", "descriptor '" + m + "' for '" + t + "' objects doesn't apply to a '" + have + "' object");
        std::vector<Value> rest(args.begin() + 1, args.end());
        out = callMethod(self, m, rest, ctx, kw.empty() ? nullptr : &kw);
        return true;
    }
    // int / float methods (round 77; NyBytes.hpp).
    bool numberMethod(const Value& obj, const std::string& m, std::vector<Value>& args,
                      const nyrt::OrderedKw<Value>& kw, Context* ctx, Value& out) {
        bool isint = obj.type == ValueType::INTEGER || obj.type == ValueType::BOOLEAN;
        if (isint && !nypy::int_methods().count(m)) return false;
        if (!isint && (obj.type != ValueType::DOUBLE || !nypy::float_methods().count(m))) return false;
        if (isint) {
            nypy::BigInt v = obj.type == ValueType::BOOLEAN ? nypy::BigInt(obj.value.b ? 1 : 0) : bigint_to_nbig(obj.value.i);
            if (m == "bit_length") { out = intValue(nypy::big_bit_length(v)); return true; }
            if (m == "bit_count") { out = intValue(nypy::big_bit_count(v)); return true; }
            if (m == "conjugate") { out = intValue(v); return true; }
            if (m == "is_integer") { out = Value(true); return true; }
            if (m == "as_integer_ratio") { out = makeListValue({intValue(v), intValue((int64_t)1)}, true); return true; }
            if (m == "to_bytes") {
                auto get = [&](const char* k, size_t pos) -> const Value* {
                    auto it = kw.find(k);
                    if (it != kw.end()) return &it->second;
                    return pos < args.size() ? &args[pos] : nullptr;
                };
                const Value* lv = get("length", 0);
                int64_t len = 1;
                if (lv) { Num n; if (!asNum(*lv, n) || n.k != 1) pyRaise("TypeError", "length must be an int"); len = n.i; }
                const Value* bo = get("byteorder", 1);
                std::string order = bo ? strOf(*bo, ctx) : std::string("big");
                if (order != "big" && order != "little") pyRaise("ValueError", "byteorder must be either 'little' or 'big'");
                auto sg = kw.find("signed");
                bool sgn = sg != kw.end() && isTruthy(sg->second);
                out = makeBytesValue(nyCall([&] { return nypy::int_to_bytes(v, len, order == "little", sgn); }));
                return true;
            }
            return false;
        }
        double d = (double)obj.value.d;
        if (m == "is_integer") { out = Value(std::isfinite(d) && d == std::floor(d)); return true; }
        if (m == "hex") { out = makeStringValue(nypy::float_hex(d)); return true; }
        if (m == "conjugate") { out = obj; return true; }
        if (m == "as_integer_ratio") {
            nypy::BigInt n, dd;
            nyCall([&] { nypy::float_ratio(d, n, dd); return 0; });
            out = makeListValue({intValue(n), intValue(dd)}, true);
            return true;
        }
        return false;
    }
    // bytes / bytearray operands (round 77). False hands the operation back
    // to the general code (identity, `b in a_list`, and/or, ...).
    bool bytesBinary(int opc, const Value& lv, const Value& rv, nyheap::Bytes* lb, nyheap::Bytes* rb, Value& out, Context* ctx) {
        switch (opc) {
        case OP_ADD:
            if (lb && rb) { out = makeBytesValue(lb->s + rb->s, lb->mut); return true; }
            if (lb) pyRaise("TypeError", "can't concat " + typeNameOf(rv) + " to " + typeNameOf(lv));
            pyRaise("TypeError", isStringValue(lv) ? "can only concatenate str (not \"" + typeNameOf(rv) + "\") to str"
                                                   : "unsupported operand type(s) for +: '" + typeNameOf(lv) + "' and '" + typeNameOf(rv) + "'");
        case OP_MUL: {
            nyheap::Bytes* b = lb ? lb : rb;
            const Value& other = lb ? rv : lv;
            Num cnt;
            if ((lb && rb) || !asNum(other, cnt) || cnt.k == 3)
                pyRaise("TypeError", "can't multiply sequence by non-int of type '" + typeNameOf(other) + "'");
            int64_t n = cnt.k == 1 ? cnt.i : (numIsNeg(cnt) ? 0 : INT64_MAX);
            if (n > 0 && b->s.size() * (uint64_t)n > (1ull << 32)) pyRaise("MemoryError", "repeated bytes are too long");
            out = makeBytesValue(nypy::repeat_str(b->s, n), b->mut);
            return true;
        }
        case OP_EQ: case OP_NE: {
            bool eq = lb && rb && lb->s == rb->s;
            out = Value(opc == OP_EQ ? eq : !eq);
            return true;
        }
        case OP_SEQ: case OP_SNE: {
            bool eq = lb && rb && lb->mut == rb->mut && lb->s == rb->s;
            out = Value(opc == OP_SEQ ? eq : !eq);
            return true;
        }
        case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            if (!(lb && rb))
                pyRaise("TypeError", std::string("'") + opSymbol(opc) + "' not supported between instances of '"
                        + typeNameOf(lv) + "' and '" + typeNameOf(rv) + "'");
            int c = nypy::bytes_compare(lb->s, rb->s);
            out = Value(opc == OP_LT ? c < 0 : opc == OP_LE ? c <= 0 : opc == OP_GT ? c > 0 : c >= 0);
            return true;
        }
        case OP_IN: case OP_NOTIN: {
            if (!rb) return false;           // a bytes value looked up in a list, dict...
            bool in = nyCall([&] { return nypy::bytes_contains(rb->s, toBArg(lv, ctx)); });
            out = Value(opc == OP_IN ? in : !in);
            return true;
        }
        case OP_MOD:
            if (lb) pyRaise("TypeError", "%-formatting of bytes is not supported; use b''.join or .format on str and encode()");
            return false;
        case OP_SUB: case OP_DIV: case OP_FLOORDIV: case OP_POW: case OP_BAND: case OP_BOR: case OP_BXOR:
        case OP_LSHIFT: case OP_RSHIFT:
            unsupportedOperands(opc, lv, rv);
        default:
            return false;
        }
    }
    // A value as an argument of a bytes method (NyBytes.hpp: BArg).
    nypy::BArg toBArg(const Value& v_in, Context* ctx, int depth = 0) {
        // a bytes / int subclass's instance is its value (round 77)
        Value v = unwrapPayload(v_in);
        nypy::BArg a;
        a.tname = typeNameOf(v);
        switch (v.type) {
            case ValueType::NONE: case ValueType::UNDEFINED: a.k = nypy::BArg::NONE; return a;
            case ValueType::BOOLEAN: a.k = nypy::BArg::BOOL; a.i = v.value.b ? 1 : 0; return a;
            case ValueType::INTEGER: {
                a.k = nypy::BArg::INT;
                int64_t i;
                if (!bigint_fits_i64(v.value.i, i)) i = bigint_to_nbig(v.value.i).neg ? INT64_MIN : INT64_MAX;
                a.i = i;
                return a;
            }
            default: break;
        }
        if (auto* bo = bytesOf(v)) { a.k = nypy::BArg::BYTES; a.s = bo->s; return a; }
        if (isStringValue(v)) { a.k = nypy::BArg::STR; a.s = *(std::string*)v.value.p; return a; }
        if (depth == 0 && (contOf(v) || isInstanceVal(v) || nygen::is_gen(v))) {
            a.k = nypy::BArg::SEQ;
            for (auto& it : iterItems(v, ctx)) a.items.push_back(toBArg(it, ctx, 1));
            return a;
        }
        a.k = nypy::BArg::OTHER;
        return a;
    }
    Value fromBRes(const nypy::BRes& r) {
        switch (r.k) {
            case nypy::BRes::INT: return intValue(r.i);
            case nypy::BRes::BOOL: return Value(r.b);
            case nypy::BRes::STR: return makeStringValue(r.s);
            case nypy::BRes::BYTES: return makeBytesValue(r.s, r.ba);
            case nypy::BRes::LIST: case nypy::BRes::TUPLE: {
                std::vector<Value> items;
                items.reserve(r.v.size());
                for (auto& x : r.v) items.push_back(makeBytesValue(x, r.ba));
                return makeListValue(items, r.k == nypy::BRes::TUPLE);
            }
            default: return NONE_VALUE;
        }
    }
    // bytes(x) / bytearray(x), with encoding= and errors=.
    Value constructBytes(std::vector<Value>& args, bool mut, Context* ctx) {
        std::string enc = "utf-8", err = "strict";
        bool has_enc = false;
        std::vector<Value> pos;
        for (auto& a : args) {
            if (Container* c = contOf(a)) {
                if (c->container->count("__kwargs__")) {
                    for (auto& kv : *c->container) {
                        if (kv.first == "__kwargs__" || isInternalKey(kv.first)) continue;
                        if (kv.first == "encoding") { enc = strOf(kv.second, ctx); has_enc = true; }
                        else if (kv.first == "errors") err = strOf(kv.second, ctx);
                        else pyRaise("TypeError", std::string(mut ? "bytearray" : "bytes") + "() got an unexpected keyword argument '" + kv.first + "'");
                    }
                    continue;
                }
            }
            pos.push_back(a);
        }
        if (pos.size() > 3) pyRaise("TypeError", std::string(mut ? "bytearray" : "bytes") + "() takes at most 3 arguments (" + std::to_string(pos.size()) + " given)");
        if (pos.size() >= 2) { enc = strOf(pos[1], ctx); has_enc = true; }
        if (pos.size() >= 3) err = strOf(pos[2], ctx);
        // An object with __bytes__ converts itself.
        if (!pos.empty() && isInstanceVal(pos[0]) && instanceHasMethod(pos[0], "__bytes__")) {
            std::vector<Value> none;
            Value r = callMethod(pos[0], "__bytes__", none, ctx);
            auto* bo = bytesOf(r);
            if (!bo) pyRaise("TypeError", "__bytes__ returned non-bytes (type " + typeNameOf(r) + ")");
            return makeBytesValue(bo->s, mut);
        }
        std::vector<nypy::BArg> ba;
        if (!pos.empty()) ba.push_back(toBArg(pos[0], ctx));
        std::string data = nyCall([&] { return nypy::bytes_construct(ba, enc, err, has_enc, mut ? "bytearray" : "bytes"); });
        return makeBytesValue(std::move(data), mut);
    }

    // ─── AUGMENTED ASSIGNMENT ───────────────────────────────────────────
    // `t op= v` evaluates the target's object and index once, computes with
    // the same operators as the binary form, and stores back. Lists are
    // mutable, so `L += it` extends and `L *= n` repeats in place: every
    // alias sees the change (a new list used to be built, or none returned).
    Value evalAugAssignment(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* an = static_cast<AugAssignNode*>((node).get());
        const std::string& op = an->op;
        if (op == "?\?=") return evalCoalesceAssign(an, ctx);
        // the operator's code, worked out from its text once (round 81)
        if (__builtin_expect(an->opc < 0, 0)) {
            std::string base = op.substr(0, op.size() > 0 ? op.size() - 1 : 0);
            if (op == ">>>=") base = ">>";
            an->opc = (int8_t)binOpCode(base);
            an->plain_op = op != "~=" && op != "@=";
        }
        const int opc = an->opc;
        // Target: read its current value, remembering where to store.
        Value obj, idx, old_val;
        int kind = an->target->type() == NodeType::SUBSCRIPT ? 1 : an->target->type() == NodeType::ATTRIBUTE ? 2 : 0;
        if (kind == 1) {
            auto* sub = static_cast<SubscriptNode*>((an->target).get());
            obj = evalNode(sub->object, ctx);
            idx = evalNode(sub->index, ctx);
            ContainerType::value_type* kv = astSpecOn() ? seqItemSlot(obj, idx, sub->slot_off, false) : nullptr;   // round 81
            old_val = kv ? kv->second : getItem(obj, idx, ctx);
        } else if (kind == 2) {
            auto* attr = static_cast<AttributeNode*>((an->target).get());
            obj = evalNode(attr->object, ctx);
            if (!getAttrValue(obj, attr->attr, ctx, old_val)) old_val = missingAttribute(obj, attr->attr, an->target.get());
        } else {
            old_val = evalNode(an->target, ctx);
        }
        Value new_val = evalNode(an->value_node, ctx, pend);
        if (pend && raisedBy(new_val)) return NONE_VALUE;   // round 82: the value raised (evalP)
        Value result;
        // Two numbers (round 81): binaryOp's answer without its other checks
        // (no container, bytes or object is involved), then the store.
        if (astSpecOn() && an->plain_op && opc != OP_UNKNOWN && isNumType(old_val.type) && isNumType(new_val.type)
            && numBinary(opc, old_val, new_val, result)) {
            storeAugTarget(an, kind, obj, idx, result, ctx);
            return result;
        }
        Container* oc = contOf(old_val);
        if (op == "~=") {
            // `x ~= y` assigns the bitwise complement of the right operand
            // (`x = ~y`) - the reading chosen when the operator was wired up.
            Num y;
            if (!asNum(new_val, y) || y.k == 3) pyRaise("TypeError", "bad operand type for unary ~");
            result = y.k == 1 ? intValue(~y.i) : intValue(-(numBig(y) + nypy::BigInt(1)));
        } else if (bytesOf(old_val) && bytesOf(old_val)->mut && (opc == OP_ADD || opc == OP_MUL)) {
            // bytearray += b / *= n change it in place (every alias sees it)
            auto* bo = bytesOf(old_val);
            if (opc == OP_ADD) {
                nypy::BArg ra = toBArg(new_val, ctx);
                if (ra.k != nypy::BArg::BYTES) pyRaise("TypeError", "can't concat " + typeNameOf(new_val) + " to bytearray");
                bo->s += ra.s;
            } else {
                Num cnt;
                if (!asNum(new_val, cnt) || cnt.k == 3) pyRaise("TypeError", "can't multiply sequence by non-int of type '" + typeNameOf(new_val) + "'");
                int64_t times = cnt.k == 1 ? cnt.i : (numIsNeg(cnt) ? 0 : 1);
                bo->s = nypy::repeat_str(bo->s, times);
            }
            result = old_val;
        } else if (oc && seqLen(oc) >= 0 && !isTupleCont(oc) && !isSetCont(oc) && (opc == OP_ADD || opc == OP_MUL)) {
            if (opc == OP_ADD) {
                std::vector<Value> more = iterItems(new_val, ctx);
                int64_t n = seqLen(oc);
                for (auto& v : more) (*oc->container)[std::to_string(n++)] = v;
                (*oc->container)["__len__"] = intValue(n);
            } else {
                Num cnt;
                if (!asNum(new_val, cnt) || cnt.k == 3) pyRaise("TypeError", "can't multiply sequence by non-int");
                int64_t times = cnt.k == 1 ? cnt.i : (numIsNeg(cnt) ? 0 : 1);
                std::vector<Value> items = seqItems(oc);
                int64_t n = (int64_t)items.size();
                for (int64_t k = 0; k < n; k++) oc->container->erase(std::to_string(k));
                int64_t w = 0;
                for (int64_t t = 0; t < times; t++) for (auto& v : items) (*oc->container)[std::to_string(w++)] = v;
                (*oc->container)["__len__"] = intValue(w);
            }
            result = old_val;
        } else {
            result = NONE_VALUE;
            bool done = false;
            if (isInstanceVal(old_val)) {
                static const std::unordered_map<std::string, const char*> idunder = {
                    {"+=", "__iadd__"}, {"-=", "__isub__"}, {"*=", "__imul__"}, {"/=", "__itruediv__"},
                    {"//=", "__ifloordiv__"}, {"%=", "__imod__"}, {"**=", "__ipow__"}, {"&=", "__iand__"},
                    {"|=", "__ior__"}, {"^=", "__ixor__"}, {"<<=", "__ilshift__"}, {">>=", "__irshift__"},
                    {"@=", "__imatmul__"}};   // round 77
                auto it = idunder.find(op);
                // No __iadd__: x += y is x = x + y (__add__, then the
                // right operand's __radd__), as Python - it raised
                // AttributeError for a class with only __add__.
                if (it != idunder.end() && instanceHasMethod(old_val, it->second)) {
                    std::vector<Value> a = {new_val};
                    Value r = callMethod(old_val, it->second, a, ctx);
                    if (r.type != ValueType::NONE && !isNotImplemented(r)) { result = r; done = true; }
                }
            }
            if (!done && op == "@=") {
                // `a @= b` without __imatmul__: a = a @ b (round 77)
                if (!binaryDunder("@", old_val, new_val, ctx, result))
                    pyRaise("TypeError", "unsupported operand type(s) for @=: '" + typeNameOf(old_val) + "' and '" + typeNameOf(new_val) + "'");
                done = true;
            }
            if (!done) {
                if (opc == OP_UNKNOWN) result = new_val;
                else result = binaryOp(opc, old_val, new_val, ctx);
            }
        }
        storeAugTarget(an, kind, obj, idx, result, ctx);
        return result;
    }
    // The store of `t op= v`: an item, an attribute (an instance's field
    // through the target's cache - round 81) or a name.
    void storeAugTarget(AugAssignNode* an, int kind, const Value& obj, const Value& idx, const Value& result, Context* ctx) {
        if (kind == 1) {
            auto* sub = static_cast<SubscriptNode*>(an->target.get());
            ContainerType::value_type* kv = astSpecOn() ? seqItemSlot(obj, idx, sub->slot_off, true) : nullptr;   // round 81
            if (kv) kv->second = result; else setItem(obj, idx, result, ctx);
        }
        else if (kind == 2) {
            auto* at = static_cast<AttributeNode*>(an->target.get());
            if (!(astSpecOn() && heapKind(obj) == HK_INST && storeFast(at, obj, result))) setAttr(obj, at->attr, result);
        }
        else if (an->target->type() == NodeType::VARIABLE)
            assignName(static_cast<VariableNode*>(an->target.get()), result, ctx);
    }

    // t ??= v: v is evaluated and assigned only when t is absent - none or
    // undefined, or, for an attribute or a key, missing (a name must exist:
    // an unbound one is a NameError, as a read of it is). The target's
    // object and index are evaluated once. The value is t's, old or new.
    Value evalCoalesceAssign(AugAssignNode* an, Context* ctx) {
        NodeType tt = an->target->type();
        if (tt == NodeType::SUBSCRIPT) {
            auto* sub = static_cast<SubscriptNode*>(an->target.get());
            Value obj = evalNode(sub->object, ctx);
            Value idx = evalNode(sub->index, ctx);
            Value cur;
            if (tryGetItem(obj, idx, ctx, cur) && !isAbsent(cur)) return cur;
            Value nv = evalNode(an->value_node, ctx);
            setItem(obj, idx, nv, ctx);
            return nv;
        }
        if (tt == NodeType::ATTRIBUTE) {
            auto* at = static_cast<AttributeNode*>(an->target.get());
            Value obj = evalNode(at->object, ctx);
            Value cur;
            if (getAttrValue(obj, at->attr, ctx, cur) && !isAbsent(cur)) return cur;
            Value nv = evalNode(an->value_node, ctx);
            setAttr(obj, at->attr, nv);
            return nv;
        }
        Value cur = evalNode(an->target, ctx);
        if (!isAbsent(cur)) return cur;
        Value nv = evalNode(an->value_node, ctx);
        if (tt == NodeType::VARIABLE) assignName(static_cast<VariableNode*>(an->target.get()), nv, ctx);
        return nv;
    }

    // ─── ATTRIBUTE / ITEM STORES ────────────────────────────────────────
    // __setattr__ / __delattr__ (round 77): an assignment to (or del of)
    // an attribute of an object whose class defines one runs it. object's
    // own (the prelude's) store directly, through _ny_setattr_raw /
    // _ny_delattr_raw, which also back super().__setattr__(name, value).
    // Whether a class has such a hook is cached until the next class
    // statement.
    std::unordered_map<const Node*, uint8_t> attr_hook_cache_[3];   // __setattr__, __delattr__, __getattribute__ (round 77)
    static inline thread_local int raw_attr_depth_ = 0;
    bool instanceAttrHook(const Value& obj, int which) {
        if (raw_attr_depth_ > 0) return false;
        Node* cls = classNodeOfInstance(obj);
        if (!cls) return false;
        auto& c = attr_hook_cache_[which];
        auto it = c.find(cls);
        if (it != c.end()) return it->second == 1;
        Value m; Node* owner = nullptr;
        bool has = findClassMember(cls, which ? "__delattr__" : "__setattr__", m, &owner) && owner
                   && owner->type() == NodeType::CLASS && shownClassName(static_cast<ClassNode*>(owner)->name) != "object";
        c[cls] = has ? 1 : 2;
        return has;
    }
    struct RawAttr { RawAttr() { raw_attr_depth_++; } ~RawAttr() { raw_attr_depth_--; } RawAttr(const RawAttr&) = delete; RawAttr& operator=(const RawAttr&) = delete; };
    // ── __getattribute__ (round 77) ─────────────────────────────────────
    // A class defining one (not object's) has it called for every attribute
    // read on its instances - obj.x, obj.m(...), getattr, hasattr - and its
    // __getattr__ when it raises AttributeError, as in Python. The engine's
    // own lookups of special methods (operators, len, iter, str ...) do not
    // go through it, as in CPython. object.__getattribute__ (_ny_getattr_raw)
    // is the normal lookup, without __getattr__. Until a class defines one
    // (any_getattribute_), nothing is looked for.
    bool any_getattribute_ = false;
    bool raw_getattr_once_ = false;            // the next lookup is object.__getattribute__'s
    const void* raw_getattr_obj_ = nullptr;    // ... and its object's __getattr__ is not called
    bool getattributeHook(const Value& obj) {
        if (!any_getattribute_ || !isInstanceValue(obj)) return false;
        Node* cls = classNodeOfInstance(obj);
        if (!cls) return false;
        auto& c = attr_hook_cache_[2];
        auto it = c.find(cls);
        if (it != c.end()) return it->second == 1;
        Value m; Node* owner = nullptr;
        bool has = findClassMember(cls, "__getattribute__", m, &owner) && owner
                   && owner->type() == NodeType::CLASS && shownClassName(static_cast<ClassNode*>(owner)->name) != "object";
        c[cls] = has ? 1 : 2;
        return has;
    }
    Value hookedGetattr(const Value& obj, const std::string& name, Context* ctx) {
        std::vector<Value> a{makeStringValue(name)};
        try { return callMethod(obj, "__getattribute__", a, ctx ? ctx : global_ctx); }
        catch (std::string& flow) {
            if (!excTypeMatches(flow, "AttributeError") || !instanceHasMethod(obj, "__getattr__")) throw;
        }
        std::vector<Value> b{makeStringValue(name)};
        return callMethod(obj, "__getattr__", b, ctx ? ctx : global_ctx);
    }
    Value rawGetattr(const Value& obj, const std::string& name, Context* ctx) {
        const void* saved = raw_getattr_obj_;
        raw_getattr_obj_ = obj.value.p;
        raw_getattr_once_ = true;
        Value out;
        bool ok = false;
        try { ok = getAttrValue(obj, name, ctx ? ctx : global_ctx, out); }
        catch (...) { raw_getattr_once_ = false; raw_getattr_obj_ = saved; throw; }
        raw_getattr_once_ = false;
        raw_getattr_obj_ = saved;
        if (!ok) throw std::string("__exc__:AttributeError:" + attributeErrorText(obj, name));
        return out;
    }
    // C.x = v / del C.x for a class whose metaclass defines __setattr__ /
    // __delattr__ (not object's): the metaclass's runs (round 77; enum
    // refuses to reassign a member). Its super().__setattr__ stores directly.
    bool metaAttrHook(const Value& cls, const char* which, const std::vector<Value>& args) {
        if (raw_attr_depth_ > 0 || class_meta_.empty() || !classNodeOfValue(cls)) return false;
        Value m; Node* where = nullptr;
        if (!metaMember(cls, which, m, where) || !where || where->type() != NodeType::CLASS
            || shownClassName(static_cast<ClassNode*>(where)->name) == "object") return false;
        static const nyrt::OrderedKw<Value> no_kw;
        callMeta(m, where, cls, args, no_kw, global_ctx);
        return true;
    }
    // A data descriptor (an object whose class defines __set__ / __delete__)
    // held by the instance's class: assigning / deleting the attribute runs
    // it (round 77; enum.property refuses `member.name = x`). Any class
    // defining one turns the check on.
    bool any_data_descr_ = false;
    bool dataDescriptor(const Value& obj, const std::string& name, const char* which, Value& d, Node** where = nullptr) {
        if (!any_data_descr_ || !isInstanceValue(obj)) return false;
        Node* cls = classNodeOfInstance(obj);
        Node* owner = nullptr;
        bool r = cls && findClassMember(cls, name, d, &owner) && isInstanceValue(d) && instanceHasMethod(d, which);
        if (r && where) *where = owner;
        return r;
    }
    Node* object_class_node_ = nullptr;
    void setAttr(const Value& obj, const std::string& name, const Value& val) {
        if (isInstanceValue(obj) && instanceAttrHook(obj, 0)) {
            std::vector<Value> a{makeStringValue(name), val};
            Value o = obj;
            callMethod(o, "__setattr__", a, global_ctx);
            return;
        }
        // object() itself has no __dict__ (round 78: it took attributes)
        if (isInstanceValue(obj)) {
            if (!object_class_node_) object_class_node_ = classNodeByName("object");
            if (object_class_node_ && classNodeOfInstance(obj) == object_class_node_)
                pyRaise("AttributeError", "'object' object has no attribute '" + name + "'");
        }
        // obj.__class__ = C (round 79): the prelude's _ny_set_class checks
        // and switches it (any kind of value - it raises for builtin ones)
        if (name == "__class__" && !classNodeOfValue(obj)) { setClassOf(obj, val); return; }
        if (any_data_descr_) {
            Value d;
            Node* where = nullptr;
            if (dataDescriptor(obj, name, "__set__", d, &where)) {
                // a slot (round 79): its value is the instance's field
                if (member_desc_node_ && classNodeOfInstance(d) == member_desc_node_) {
                    fieldsOf(obj, "__slots__")->defineByName(name, val);
                    return;
                }
                // the prelude's property: its setter called directly (round 77)
                if (classNodeOfInstance(d) == prelude_property_node()) {
                    Value fs = attrOf(d, "fset");
                    if (isPlainFunction(fs)) {
                        std::vector<Value> a{obj, val};
                        OwnerScope _os(owner_stack_, where);
                        callFunctionValue(fs, a, global_ctx);
                        return;
                    }
                }
                std::vector<Value> a{obj, val};
                callMethod(d, "__set__", a, global_ctx);
                return;
            }
        }
        if (!class_meta_.empty() && metaAttrHook(obj, "__setattr__", {makeStringValue(name), val})) return;
        // A property defined on the class: its setter runs, and a read-only
        // one refuses (the value used to be written into the instance,
        // silently hiding the property).
        if (any_property_ && isInstanceValue(obj)) {
            Node* cls = classNodeOfInstance(obj);
            Value m; Node* owner = nullptr;
            if (cls && findClassMember(cls, name, m, &owner) && m.type == ValueType::USERDATA && m.value.p
                && fnTag(func_names, m.value.p).find("__property__") != std::string::npos) {
                auto st = prop_setters_.find(m.value.p);
                if (st == prop_setters_.end())
                    throw std::string("__exc__:AttributeError:can't set attribute '" + name + "'");
                std::vector<Value> a{val};
                nyrt::OrderedKw<Value> nokw;
                invokeMember(st->second, owner, obj, a, nokw, global_ctx);
                return;
            }
        }
        // an instance of a class with __slots__ and no __dict__ takes no
        // other attribute (round 79; its slots were stored above)
        if (!slot_flags_.empty() && isDictless(obj))
            pyRaise("AttributeError", "'" + typeNameOf(obj) + "' object has no attribute '" + name + "'");
        // obj.__dict__ = d: the fields become d's items (round 77; it stored
        // a field named __dict__)
        if (name == "__dict__" && isInstanceValue(obj)) {
            Value src = unwrapPayload(val);
            Container* sc = contOf(src);
            if (!sc || seqLen(sc) >= 0 || isInstanceVal(src))
                pyRaise("TypeError", "__dict__ must be set to a dictionary, not a '" + typeNameOf(val) + "'");
            std::vector<Value> keys = dictKeys(sc);
            std::vector<Value> vals;
            for (auto& k : keys) { auto it = dictFind(sc, k); vals.push_back(it != sc->container->end() ? it->second : NONE_VALUE); }
            Context* f = fieldsOf(obj, "__dict__");
            std::vector<std::string> drop;
            if (f->container) for (auto& kv : *f->container)
                if (!nyrt::hidden_field(kv.first) && (!member_desc_node_ || !isSlotOf(obj, kv.first))) drop.push_back(kv.first);   // (slots stay - round 79)
            for (auto& d : drop) f->container->erase(d);
            for (size_t i = 0; i < keys.size(); i++) if (isStringValue(keys[i])) f->defineByName(getStringValue(keys[i]), vals[i]);
            return;
        }
        // Store on instance properties (USERDATA instances)
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto pit = instance_properties.find(obj.value.p);
            if (pit != instance_properties.end()) {
                pit->second->defineByName(name, val);
            } else {
                // Might be a class object (not an instance) — store as class var
                void* class_ptr = obj.value.p;
                void* ast_ptr = class_ptr;
                auto ast_it = func_ast_nodes.find(class_ptr);
                if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
                Node* class_node = (Node*)ast_ptr;
                // Only a class's pointer is a Node (a builtin's or a
                // function's is not).
                if (class_node && fnTag(func_names, class_ptr).rfind("__class__:", 0) == 0 && class_node->type() == NodeType::CLASS) {
                    auto* cn = static_cast<ClassNode*>(class_node);
                    // C.f = staticmethod(g) / classmethod(g) / a property
                    // (round 77): as in a class body
                    Value val2 = isInstanceValue(val) ? unwrapMethodObject(val, global_ctx) : val;
                    noteDataDescriptor(val2, &name);
                    const Value& val = val2;
                    class_vars_[cn->name + "." + name] = val;
                    specInvalidate();   // round 81: the method caches read class_vars_
                    if (!class_vars_deleted_.empty()) class_vars_deleted_.erase(cn->name + "." + name);
                    if (name == "__getattribute__") { any_getattribute_ = true; attr_hook_cache_[2].clear(); specInvalidate(); }
                    // round 81: a hook assigned after instances stored
                    // attributes is called from now on (the cache said none)
                    if (name == "__setattr__") attr_hook_cache_[0].clear();
                    if (name == "__delattr__") attr_hook_cache_[1].clear();
                    if (name == "__new__") no_new_.clear();
                    if (name == "__iter__") iter_own_cache_.clear();   // round 77
                    // Also update class_ctx_map_ so subsequent reads via evalAttribute see the new value.
                    // In the class's own namespace: setByName walked on into
                    // the scope the class was defined in, so C.x = v rebound a
                    // same-named global when the class had no x yet.
                    auto cctx_it = class_ctx_map_.find((void*)class_node);
                    if (cctx_it != class_ctx_map_.end()) cctx_it->second->defineByName(name, val);
                    return;
                }
            }
            if (pit != instance_properties.end()) return;
        }
        // Store on Collectable containers (namespaces, modules)
        if (Container* cont = contOf(obj)) { (*cont->container)[name] = val; return; }
        if (isPlainFunction(obj)) {
            func_attrs_[obj.value.p][name] = val;
            // f.__qualname__ = "C.f": the name its call errors give (round 77)
            if (name == "__qualname__" && isStringValue(val)) {
                auto ait = func_ast_nodes.find(obj.value.p);
                if (ait != func_ast_nodes.end() && ait->second) fn_qualname_[(const Node*)ait->second] = getStringValue(val);
            }
            return;
        }
        // none.x = v, 5.x = v, "s".x = v, len.x = v: nothing can hold it
        // (AttributeError, as in Python - it was dropped silently).
        std::string msg = attributeErrorText(obj, name);
        if (nypy::lenient_reads_log()) { logLenientRead(nullptr, "AttributeError (store): " + msg); return; }
        throw std::string("__exc__:AttributeError:" + msg);
    }

    // Structural equality, recursive, as on the VM (and in Python): lists
    // and tuples element by element, maps key by key, sets as sets, 1 == 1.0
    // == true. A list never equals a tuple.
    // ── type objects (round 77) ─────────────────────────────────────────
    // A class, or a builtin type (int, str, dict, ...): what type() gives.
    // Its names, for == with a string: Python's, and the legacy one type()
    // returned before (str "string", dict "map", type "class").
    bool typeObjectNames(const Value& v, std::string& py, std::string& legacy) {
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        auto fit = func_names.find(v.value.p);
        if (fit == func_names.end()) return false;
        const std::string& t = fit->second;
        if (t.rfind("__class__:", 0) == 0) {
            py = shownClassName(t.substr(10));
            legacy = py;
            return true;
        }
        if (t.rfind("__builtin__:", 0) == 0) {
            std::string n = t.substr(12);
            if (n == "map") n = "dict";
            if (!nyrt::is_builtin_type_name(n)) return false;
            py = n;
            legacy = n == "str" ? "string" : n == "dict" ? "map" : n == "type" ? "class" : n;
            return true;
        }
        if (t.rfind("__rtype__:", 0) == 0) {
            const nyrt::RuntimeType* rt = nyrt::runtime_type(t.substr(10));
            if (!rt) return false;
            py = rt->name;
            legacy = rt->legacy;
            return true;
        }
        return false;
    }
    // The type objects of the runtime's own kinds (NoneType, function,
    // method, builtin_function_or_method, generator, zip, list_iterator ...),
    // tagged "__rtype__:<name>" and never bound to a global name (round 77).
    std::unordered_map<std::string, std::unique_ptr<std::string>> rtype_ptrs_;
    Value runtimeTypeValue(const std::string& n) {
        auto& p = rtype_ptrs_[n];
        if (!p) { p = std::make_unique<std::string>(n); func_names[(void*)p.get()] = "__rtype__:" + n; }
        Value v;
        v.type = ValueType::USERDATA;
        v.value.p = (void*)p.get();
        return v;
    }
    const nyrt::RuntimeType* runtimeTypeOf(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        auto fit = func_names.find(v.value.p);
        if (fit == func_names.end() || fit->second.rfind("__rtype__:", 0) != 0) return nullptr;
        return nyrt::runtime_type(fit->second.substr(10));
    }
    // Calling one: NoneType() is None, method(f, obj) binds, zip/map/filter/
    // enumerate make another, the rest cannot be made (Python's messages).
    Value runtimeTypeCall(const nyrt::RuntimeType& rt, std::vector<Value>& args, const nyrt::OrderedKw<Value>* kw, Context* ctx) {
        std::string n = rt.name;
        if (n == "NoneType") {
            if (!args.empty() || (kw && !kw->empty())) pyRaise("TypeError", "NoneType takes no arguments");
            return NONE_VALUE;
        }
        if (n == "method") {
            if (args.size() != 2) pyRaise("TypeError", "method expected 2 arguments, got " + std::to_string(args.size()));
            return methodNew(args[0], args[1], ctx);
        }
        if (n == "zip" || n == "map" || n == "filter" || n == "enumerate") return callBuiltinKw(n, args, kw, ctx);
        if (n == "function") pyRaise("TypeError", "function() missing required argument 'code' (pos 1)");
        pyRaise("TypeError", "cannot create '" + n + "' instances");
        return NONE_VALUE;
    }
    // types.MethodType(f, obj) / the method type called (round 77): f bound
    // to obj. A function becomes a bound method; another callable a
    // _NyMetaBound passing obj first.
    Value methodNew(const Value& f, const Value& obj, Context* ctx) {
        if (!isCallableValue(f)) pyRaise("TypeError", "first argument must be callable");
        if (obj.type == ValueType::NONE) pyRaise("TypeError", "instance must not be None");
        if (isPlainFunction(f) && !bound_self_.count(f.value.p)) {
            Value b = makeBoundClassMethod(f, obj);
            if (b.value.p != f.value.p) return b;
        }
        std::vector<Value> a{f, obj};
        return callFunctionValue(global_ctx->getByName("_NyMetaBound"), a, ctx);
    }
    bool isTypeObject(const Value& v) { std::string a, b; return typeObjectNames(v, a, b); }
    // The name type() gave before type objects ("int", "string", "map",
    // "class", a class's name): what `x is int` and the old string tests
    // compare against.
    std::string legacyTypeName(const Value& v) {
        Value t = typeObjectOf(v);
        std::string py, legacy;
        if (typeObjectNames(t, py, legacy)) return legacy;
        return getStringValue(t);
    }
    // type(v) as a type object, or the legacy name for the kinds without one
    // here (none, functions, builtins, generators, typed maps).
    Value typeObjectOf(const Value& v) {
        auto builtin = [&](const char* n) { Value b = builtinValue(n); return b.type == ValueType::NONE ? makeStringValue(n) : b; };
        switch (v.type) {
            case ValueType::NONE: return runtimeTypeValue("NoneType");   // round 77
            case ValueType::BOOLEAN: return builtin("bool");
            case ValueType::INTEGER: return builtin("int");
            case ValueType::DOUBLE: return builtin("float");
            case ValueType::UNDEFINED: return makeStringValue("undefined");
            default: break;
        }
        if (isStringValue(v)) return builtin("str");
        if (Container* c = contOf(v)) {
            if (c->container->count("__set__")) return builtin(isFrozenCont(c) ? "frozenset" : "set");
            if (c->container->count("__gen__")) return runtimeTypeValue(nygen::is_gen(v) ? nygen::type_name(nygen::gen_of(v)) : std::string("generator"));
            if (c->container->count("__tuple__")) return builtin("tuple");
            if (c->container->count("__len__")) return builtin("list");
            auto type_it = c->container->find("__type__");
            if (type_it != c->container->end()) return makeStringValue(getStringValue(type_it->second));
            // a module: the prelude's module type (round 78; it was dict)
            if (isModuleNamespace(v))
                if (Node* mt = classNodeByName("_NyModuleType")) return classValueOfNode(mt);
            if (builtinValue("dict").type != ValueType::NONE) return builtin("dict");
            return builtin("map");
        }
        if (v.isCollectable()) return makeStringValue("object");
        if (v.type == ValueType::USERDATA && v.value.p) {
            if (auto* bo = bytesOf(v)) return builtin(bo->mut ? "bytearray" : "bytes");
            if (string_ptrs_.count(v.value.p)) return builtin("str");
            if (isInstanceValue(v)) {
                auto ic = instance_to_class.find(v.value.p);
                if (ic != instance_to_class.end() && ic->second) { Value cv; cv.type = ValueType::USERDATA; cv.value.p = ic->second; return cv; }
            }
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                // functions, bound methods, builtins: their type objects (round 77)
                if (fit->second.find("__func__:") == 0 || fit->second.find("__lambda__") == 0)
                    return runtimeTypeValue(bound_self_.count(v.value.p) ? "method" : "function");
                if (fit->second.find("__rtype__:") == 0) return builtin("type");
                if (fit->second.find("__class__:") == 0) {
                    // a class: its metaclass, else type
                    Value meta = metaclassOf(classNodeOfValue(v));
                    if (meta.type != ValueType::NONE) return meta;
                    return builtin("type");
                }
                if (fit->second.find("__builtin__:") == 0) {
                    // a builtin type is itself of type type
                    if (isTypeObject(v)) return builtin("type");
                    return runtimeTypeValue("builtin_function_or_method");
                }
                if (fit->second.find("__bmethod__:") == 0) return runtimeTypeValue("builtin_function_or_method");
                if (fit->second.find("__instance__:") == 0) return makeStringValue(shownClassName(fit->second.substr(13)));
            }
            return makeStringValue("string");
        }
        return makeStringValue("unknown");
    }
    bool valuesEqual(const Value& a, const Value& b, int depth) {
        if (depth > 100) return false;
        // Objects compare through __eq__ (inside containers, for `in`,
        // index(), count(), remove()), as in Python.
        if (isInstanceVal(a) || isInstanceVal(b)) {
            Value r;
            if (binaryDunder("==", a, b, global_ctx, r)) return isTruthy(r);
            return identical(a, b);
        }
        Num x, y;
        if (asNum(a, x) && asNum(b, y)) return numCmp(x, y) == 0;
        {
            auto* ab = bytesOf(a); auto* bb = bytesOf(b);
            if (ab || bb) return ab && bb && ab->s == bb->s;   // bytes == bytearray by content
        }
        bool as = isStringValue(a), bs = isStringValue(b);
        if (as != bs) {
            // a type object and a name: type(x) == "list" (round 77)
            std::string py, legacy;
            if (typeObjectNames(as ? b : a, py, legacy)) {
                const std::string& s = *(std::string*)(as ? a : b).value.p;
                return s == py || s == legacy;
            }
        }
        if (as || bs) {
            if (!(as && bs)) return false;
            return a.value.p == b.value.p || *(std::string*)a.value.p == *(std::string*)b.value.p;
        }
        if (a.isCollectable() && b.isCollectable() && a.value.gc && b.value.gc) {
            if (a.value.gc == b.value.gc) return true;
            if (nygen::is_gen(a) || nygen::is_gen(b)) return false;   // generators: identity
            // round 81: the kind flag (contOf), the marker keys' hashes and
            // seqSlot, not dynamic_cast, "__len__" hashed again and
            // find(std::to_string(i)) - the same answers
            Container* lc = contOf(a);
            Container* rc = contOf(b);
            if (!lc || !rc) return a == b;
            auto& L = *lc->container;
            auto& R = *rc->container;
            const MarkerKey& lk = kLenKey();
            long lis = L.index_of_h(lk.key, lk.hash), ris = R.index_of_h(lk.key, lk.hash);
            bool llist = lis >= 0, rlist = ris >= 0;
            if (llist != rlist) return false;
            if (llist) {
                int64_t ln = bigint_to_i64(L.slot_at((size_t)lis)->second.value.i);
                int64_t rn = bigint_to_i64(R.slot_at((size_t)ris)->second.value.i);
                if (ln != rn) return false;
                if (isTupleCont(lc) != isTupleCont(rc)) return false;
                bool lset = isSetCont(lc), rset = isSetCont(rc);
                if (lset != rset) return false;
                if (lset) return setEqual(lc, rc);   // set == frozenset by content
                int8_t ox = 0, oy = 0;
                for (int64_t i = 0; i < ln; i++) {
                    auto* x2 = seqSlot(lc->container, i, ox);
                    auto* y2 = seqSlot(rc->container, i, oy);
                    if (!x2 || !y2) return false;
                    if (!valuesEqual(x2->second, y2->second, depth + 1)) return false;
                }
                return true;
            }
            auto internal = [](const std::string& k) {
                return k == "__type__" || k == "__name__" || k == "__class__";
            };
            size_t ln = 0, rn = 0;
            for (auto& kv : L) if (!internal(kv.first)) ln++;
            for (auto& kv : R) if (!internal(kv.first)) rn++;
            if (ln != rn) return false;
            for (auto& kv : L) {
                if (internal(kv.first)) continue;
                auto y2 = R.find(kv.first);
                if (y2 == R.end() || !valuesEqual(kv.second, y2->second, depth + 1)) return false;
            }
            return true;
        }
        if (a.type == ValueType::NONE || b.type == ValueType::NONE) return a.type == b.type;
        return a == b;
    }

    // ─── ITEMS ──────────────────────────────────────────────────────────
    // Dict keys keep their type (NyStr.hpp: nypy::key_of_*): 1 and "1" are
    // different keys, 1 == 1.0 == true are the same one, tuples are keys.
    std::string dictKey(const Value& k) {
        switch (k.type) {
            case ValueType::NONE: case ValueType::UNDEFINED: return nypy::key_of_none();
            case ValueType::BOOLEAN: return nypy::key_of_int(k.value.b ? 1 : 0);
            case ValueType::INTEGER: {
                int64_t v;
                if (bigint_fits_i64(k.value.i, v)) return nypy::key_of_int(v);
                return nypy::key_of_big(bigint_to_nbig(k.value.i));
            }
            case ValueType::DOUBLE: return nypy::key_of_float((double)k.value.d);
            default: break;
        }
        if (auto* bo = bytesOf(k)) {
            if (bo->mut) pyRaise("TypeError", "unhashable type: 'bytearray'");
            return nypy::key_of_bytes(bo->s);
        }
        if (isStringValue(k)) return nypy::key_of_str(*(std::string*)k.value.p);
        if (Container* c = contOf(k)) {
            if (seqLen(c) >= 0 && isTupleCont(c)) {
                std::vector<std::string> parts;
                for (auto& e : seqItems(c)) parts.push_back(dictKey(e));
                return nypy::key_of_tuple(parts);
            }
            if (isSetCont(c)) return setKey(k);       // a frozenset; a set raises
            if (!isInstanceVal(k)) pyRaise("TypeError", "unhashable type: '" + typeNameOf(k) + "'");
        }
        {
            Value p;   // MyStr("k") is the key "k" (round 77)
            if (any_payload_ && payloadKey(k, p)) return dictKey(p);
        }
        if (isInstanceVal(k) && instanceHasMethod(k, "__hash__")) {
            checkHashable(k);
            // An object with __hash__ is the key of every object of the same
            // hash it is equal to (__eq__), as in Python: two equal dates are
            // one key, and so are equal objects of two classes - a Fraction
            // and an int, two classes whose __eq__ say yes (round 78: they
            // were keyed by class name and hash, so those stayed apart, and
            // unequal objects of one class with one hash were one key). The
            // first object stored stands for the key; one equal to its hash
            // as an int is that int's key ({1: x}[Fraction(1)]).
            std::vector<Value> none;
            Value h = callMethod(k, "__hash__", none, global_ctx);
            if (h.type != ValueType::INTEGER && h.type != ValueType::BOOLEAN)
                pyRaise("TypeError", "__hash__ method should return an integer");
            return hashedKey(k, h);
        }
        char buf[32]; snprintf(buf, sizeof buf, "%p", k.type == ValueType::USERDATA ? k.value.p : (void*)k.value.gc);
        std::string id = std::string(k.type == ValueType::USERDATA ? "u" : "g") + buf;
        key_objs_[id] = k;
        if (!keys_owner_) {
            keys_owner_ = this;
            nygc::g_keys.any = &keysAny;
            nygc::g_keys.each = &keysEach;
            nygc::g_keys.lookup = &keysLookup;
            nygc::g_keys.drop_garbage = &keysDropGarbage;
        }
        return nypy::key_of_obj(id);
    }
    // Object keys, by identity. An entry does not keep its object alive by
    // itself: full collections treat its reference as the dicts' (NyGC.hpp,
    // KeyTable) and drop it with the object. Entries made only to look a key
    // up go at the next full collection.
    std::unordered_map<std::string, Value> key_objs_;
    // Objects with __hash__ as keys (round 78, dictKey): a hash's text ->
    // the key ids of the objects with that hash, each unequal to the others
    // (an id whose object is gone is dropped when next seen).
    std::unordered_map<std::string, std::vector<std::string>> hash_keys_;
    size_t hash_key_seq_ = 0;
    // == for a key collision; one that raises counts as unequal (Python would
    // compare only with the keys of the dict at hand)
    bool keyEquals(const Value& a, const Value& b) {
        try { return pyEquals(a, b, global_ctx); } catch (const std::string&) { return false; }
    }
    std::string hashedKey(const Value& k, const Value& h) {
        std::string hs = strOf(h, global_ctx);
        {
            auto& ids = hash_keys_[hs];
            for (size_t i = 0; i < ids.size();) {
                auto it = key_objs_.find(ids[i]);
                if (it == key_objs_.end()) { ids.erase(ids.begin() + (long)i); continue; }
                Value rep = it->second;
                if (rep.value.p == k.value.p) return nypy::key_of_obj(ids[i]);
                std::string id = ids[i];
                if (keyEquals(k, rep)) return nypy::key_of_obj(id);
                i++;
            }
        }
        // equal to its hash as an int (a Fraction(2, 2), an IntEnum member):
        // that int's key, as Python finds it
        if (h.type == ValueType::INTEGER && keyEquals(k, h)) return dictKey(h);
        // round 80: equal to a float or an int of the same hash (Decimal("0.5")
        // and 0.5, Fraction(1, 2) and 0.5, Decimal(10**30) and 10**30): that
        // number's key - Python's numeric hash and == make them one key
        int64_t hv;
        if (h.type == ValueType::INTEGER && bigint_fits_i64(h.value.i, hv) && isInstanceVal(k)) {
            for (const char* conv : {"__float__", "__int__"}) {
                if (!instanceHasMethod(k, conv)) continue;
                Value num;
                try { std::vector<Value> none; num = callMethod(k, conv, none, global_ctx); }
                catch (...) { continue; }
                if (num.type != ValueType::DOUBLE && num.type != ValueType::INTEGER) continue;
                std::string nk = dictKey(num);
                if (nypy::hash_of_key(nk) == hv && keyEquals(k, num)) return nk;
            }
        }
        std::string hid = "h" + hs + "#" + std::to_string(hash_key_seq_++);
        key_objs_.emplace(hid, k);
        hash_keys_[hs].push_back(hid);   // (keyEquals may have run code that touched the table)
        if (!keys_owner_) {
            keys_owner_ = this;
            nygc::g_keys.any = &keysAny;
            nygc::g_keys.each = &keysEach;
            nygc::g_keys.lookup = &keysLookup;
            nygc::g_keys.drop_garbage = &keysDropGarbage;
        }
        return nypy::key_of_obj(hid);
    }
    static inline NythonExecutor* keys_owner_ = nullptr;
    static bool keysAny() { return keys_owner_ && !keys_owner_->key_objs_.empty(); }
    static void keysEach(nython::gc::GcVisitFn visit, void* arg) {
        for (auto& kv : keys_owner_->key_objs_) if (kv.second.value.o) visit(kv.second.value.o, arg);
    }
    static nython::gc::Collectable* keysLookup(const std::string& id) {
        auto it = keys_owner_->key_objs_.find(id);
        return it == keys_owner_->key_objs_.end() ? nullptr : it->second.value.o;
    }
    static void keysDropGarbage() {
        std::vector<Value> dead;   // released after the loop; the collector still holds them
        auto& t = keys_owner_->key_objs_;
        for (auto it = t.begin(); it != t.end();) {
            auto* o = it->second.value.o;
            if (o && (o->gc_flags & nygc::F_COLLECTING)) { dead.push_back(it->second); it = t.erase(it); }
            else ++it;
        }
    }
    Value keyValue(const std::string& k) {
        switch (nypy::key_kind(k)) {
            case nypy::K_STR: return nypy::key_is_plain(k) ? internString(k) : makeStringValue(k.substr(2));
            case nypy::K_INT: {
                nypy::BigInt b;
                nypy::BigInt::parse(k.substr(2), 10, b);
                return intValue(b);
            }
            case nypy::K_FLOAT: return Value(std::strtod(k.c_str() + 2, nullptr));
            case nypy::K_NONE: return NONE_VALUE;
            case nypy::K_TUPLE: {
                std::vector<Value> items;
                for (auto& part : nypy::key_tuple_parts(k)) items.push_back(keyValue(part));
                return makeListValue(items, true);
            }
            case nypy::K_OBJ: {
                auto it = key_objs_.find(k.substr(2));
                return it != key_objs_.end() ? it->second : NONE_VALUE;
            }
            case nypy::K_BYTES: return makeBytesValue(k.substr(2));
            case nypy::K_FROZENSET: {
                std::vector<Value> items;
                for (auto& part : nypy::key_tuple_parts(k)) items.push_back(keyValue(part));
                return build_set_val(items, true);
            }
        }
        return NONE_VALUE;
    }
    ContainerType::iterator dictFind(Container* c, const Value& k) {
        return c->container->find(dictKey(k));
    }
    void dictSet(Container* c, const Value& k, const Value& v) {
        (*c->container)[dictKey(k)] = v;
    }
    // A dict's keys / values / (key, value) tuples, in insertion order.
    std::vector<Value> dictKeys(Container* c) {
        std::vector<Value> out;
        for (auto& kv : *c->container) if (!isInternalKey(kv.first)) out.push_back(keyValue(kv.first));
        return out;
    }

    // list/tuple methods with Python semantics. Returns false when `name`
    // is not one of them.
    bool listMethod(Container* c, const Value& obj, const std::string& name, std::vector<Value>& args,
                    const nyrt::OrderedKw<Value>& kw, Context* ctx, Value& out) {
        static const std::unordered_set<std::string> mine = {
            "sort", "index", "indexOf", "count", "pop", "insert", "copy", "reverse", "clear", "extend", "append", "push"};
        if (!mine.count(name)) return false;
        const bool tup = isTupleCont(c);
        static const std::unordered_set<std::string> mutating = {"sort", "pop", "insert", "reverse", "clear", "extend", "append", "push"};
        if (tup && mutating.count(name)) pyRaise("AttributeError", "'tuple' object has no attribute '" + name + "'");
        auto& C = *c->container;
        int64_t n = seqLen(c);
        auto store = [&](const std::vector<Value>& items) {
            for (int64_t k = (int64_t)items.size(); k < n; k++) C.erase(std::to_string(k));
            for (size_t k = 0; k < items.size(); k++) C[std::to_string(k)] = items[k];
            C["__len__"] = intValue((int64_t)items.size());
        };
        if (name == "append" || name == "push") {
            if (args.size() != 1) pyRaise("TypeError", "list.append() takes exactly one argument (" + std::to_string(args.size()) + " given)");
            C[std::to_string(n)] = args[0];
            // round 81: "__len__" through its known hash (it is there: n came from it)
            const MarkerKey& lk = kLenKey();
            if (long ls = C.index_of_h(lk.key, lk.hash); ls >= 0) C.slot_at_mut((size_t)ls)->second = intValue(n + 1);
            else C["__len__"] = intValue(n + 1);
            out = NONE_VALUE; return true;
        }
        if (name == "extend") {
            if (args.size() != 1) pyRaise("TypeError", "list.extend() takes exactly one argument (" + std::to_string(args.size()) + " given)");
            for (auto& v : iterItems(args[0], ctx)) C[std::to_string(n++)] = v;
            C["__len__"] = intValue(n);
            out = NONE_VALUE; return true;
        }
        if (name == "sort") {
            // key= / reverse= by keyword, or the old positional forms
            // L.sort(keyfn) / L.sort(true).
            Value keyfn = NONE_VALUE; bool rev = false;
            auto kit = kw.find("key"); if (kit != kw.end()) keyfn = kit->second;
            auto rit = kw.find("reverse"); if (rit != kw.end()) rev = isTruthy(rit->second);
            for (auto& a : args) {
                if (a.type == ValueType::BOOLEAN) rev = a.value.b;
                else if (a.type == ValueType::USERDATA && a.value.p && func_names.count(a.value.p) && keyfn.type == ValueType::NONE) keyfn = a;
            }
            std::vector<Value> items = seqItems(c), keys;
            if (keyfn.type != ValueType::NONE)
                for (auto& v : items) { std::vector<Value> ka = {v}; keys.push_back(callFunctionValue(keyfn, ka, ctx)); }
            std::vector<size_t> order(items.size());
            for (size_t k = 0; k < order.size(); k++) order[k] = k;
            auto less = [&](const Value& x, const Value& y) {
                int cmp;
                if (orderValues(x, y, cmp, ctx)) return cmp < 0;
                std::string tx = typeNameOf(x), ty = typeNameOf(y);
                if (tx != ty) return tx < ty;
                return strOf(x, ctx) < strOf(y, ctx);
            };
            std::stable_sort(order.begin(), order.end(), [&](size_t x, size_t y) {
                const Value& kx = keys.empty() ? items[x] : keys[x];
                const Value& ky = keys.empty() ? items[y] : keys[y];
                return rev ? less(ky, kx) : less(kx, ky);
            });
            std::vector<Value> sorted_items;
            for (size_t k : order) sorted_items.push_back(items[k]);
            store(sorted_items);
            out = obj; return true;   // the list itself, for chaining
        }
        if (name == "index" || name == "indexOf") {
            if (args.empty()) pyRaise("TypeError", "index expected at least 1 argument, got 0");
            int64_t st = 0, en = n;
            if (args.size() >= 2) { sliceArg(args, 1, st); if (st < 0) st = std::max<int64_t>(0, st + n); }
            if (args.size() >= 3) { sliceArg(args, 2, en); if (en < 0) en += n; en = std::min(en, n); }
            for (int64_t k = st; k < en; k++) {
                auto it = C.find(std::to_string(k));
                if (it != C.end() && valuesEqual(it->second, args[0], 0)) { out = intValue(k); return true; }
            }
            if (name == "indexOf") { out = intValue(-1); return true; }
            pyRaise("ValueError", reprOf(args[0], ctx) + " is not in list");
        }
        if (name == "count") {
            if (args.size() != 1) pyRaise("TypeError", "count() takes exactly one argument (" + std::to_string(args.size()) + " given)");
            int64_t cnt = 0;
            for (auto& v : seqItems(c)) if (valuesEqual(v, args[0], 0)) cnt++;
            out = intValue(cnt); return true;
        }
        if (name == "pop") {
            if (args.size() > 1) pyRaise("TypeError", "pop expected at most 1 argument, got " + std::to_string(args.size()));
            // The index is an int (a bool, an __index__ object, an int
            // subclass); anything else is CPython's TypeError - it fell
            // through to the dict-style pop, which gave None (round 81).
            if (!args.empty() && args[0].type != ValueType::INTEGER && args[0].type != ValueType::BOOLEAN) {
                Value p;
                if (any_payload_ && payloadOf(args[0], p) && p.type == ValueType::INTEGER) args[0] = p;
                else if (indexValue(args[0], p, ctx)) args[0] = p;
                else pyRaise("TypeError", "'" + typeNameOf(args[0]) + "' object cannot be interpreted as an integer");
            }
            if (n == 0) pyRaise("IndexError", "pop from empty list");
            int64_t i = n - 1;
            if (!args.empty()) { Num k; asNum(args[0], k); i = k.k == 1 ? k.i : INT64_MAX; if (i < 0) i += n; }
            if (i < 0 || i >= n) pyRaise("IndexError", "pop index out of range");
            std::vector<Value> items = seqItems(c);
            out = items[(size_t)i];
            items.erase(items.begin() + i);
            store(items);
            return true;
        }
        if (name == "insert") {
            if (args.size() != 2) pyRaise("TypeError", "insert expected 2 arguments, got " + std::to_string(args.size()));
            Num k;
            if (!asNum(args[0], k) || k.k == 3) pyRaise("TypeError", "'" + typeNameOf(args[0]) + "' object cannot be interpreted as an integer");
            int64_t i = k.k == 1 ? k.i : (numIsNeg(k) ? INT64_MIN / 2 : INT64_MAX / 2);
            if (i < 0) i = std::max<int64_t>(0, i + n);
            if (i > n) i = n;
            std::vector<Value> items = seqItems(c);
            items.insert(items.begin() + i, args[1]);
            store(items);
            out = NONE_VALUE; return true;
        }
        if (name == "copy") { out = makeListValue(seqItems(c), tup); return true; }
        if (name == "reverse") {
            std::vector<Value> items = seqItems(c);
            std::reverse(items.begin(), items.end());
            store(items);
            out = obj; return true;   // the list itself, like sort (Nython chains these)
        }
        if (name == "clear") { store({}); out = NONE_VALUE; return true; }
        return false;
    }

    // dict methods. Returns false when `name` is not one.
    bool dictMethod(Container* cont, const Value& obj, const std::string& name, std::vector<Value>& args,
                    const nyrt::OrderedKw<Value>& kw, Context* ctx, Value& out) {
        auto& C = *cont->container;
        const bool is_dict = seqLen(cont) < 0;
        auto need = [&](size_t lo, size_t hi) {
            if (args.size() < lo || args.size() > hi)
                pyRaise("TypeError", name + "() takes " + (lo == hi ? "exactly " + std::to_string(lo) : "at most " + std::to_string(hi)) + " argument" + (hi == 1 ? "" : "s") + " (" + std::to_string(args.size()) + " given)");
        };
        // d.keys() / values() / items(): live views, as Python's (round 78;
        // they were lists). Nython's d.entries() stays a list of pairs.
        if (is_dict && view_nodes_[0] && (name == "keys" || name == "values" || name == "items") && !nygen::is_gen(obj)) {
            if (!args.empty()) pyRaise("TypeError", "dict." + name + "() takes no arguments (" + std::to_string(args.size()) + " given)");
            out = makeView(obj, name == "keys" ? 0 : name == "values" ? 1 : 2);
            return true;
        }
        if (name == "keys" || name == "values" || name == "items" || name == "entries") {
            std::vector<Value> r;
            for (auto& kv : C) {
                if (isInternalKey(kv.first)) continue;
                if (name == "keys") r.push_back(keyValue(kv.first));
                else if (name == "values") r.push_back(kv.second);
                else r.push_back(makeListValue({keyValue(kv.first), kv.second}, true));
            }
            out = makeListValue(r);
            return true;
        }
        if (name == "get") {
            need(1, 2);
            auto it = dictFind(cont, args[0]);
            out = it != C.end() ? it->second : (args.size() >= 2 ? args[1] : NONE_VALUE);
            return true;
        }
        if (name == "has_key" || name == "has" || name == "containsKey") {
            need(1, 1);
            out = Value(dictFind(cont, args[0]) != C.end());
            return true;
        }
        if (name == "setdefault") {
            need(1, 2);
            std::string k = dictKey(args[0]);
            auto it = C.find(k);
            if (it != C.end()) { out = it->second; return true; }
            out = args.size() >= 2 ? args[1] : NONE_VALUE;
            C[k] = out;
            return true;
        }
        if (name == "copy" && is_dict) {
            Value d = makeDictValue();
            Container* dc = contOf(d);
            for (auto& kv : C) (*dc->container)[kv.first] = kv.second;
            out = d;
            return true;
        }
        if (name == "size" || name == "length") { out = intValue(dictSize(cont)); return true; }
        if (!is_dict) return false;   // list methods of the same name are elsewhere
        if (name == "pop") {
            need(1, 2);
            std::string k = dictKey(args[0]);
            auto it = C.find(k);
            if (it != C.end()) { out = it->second; C.erase(k); return true; }
            if (args.size() >= 2) { out = args[1]; return true; }
            raiseKeyError(args[0]);   // the key itself (round 77)
        }
        if (name == "popitem") {
            std::string last;
            for (auto& kv : C) if (!isInternalKey(kv.first)) last = kv.first;
            if (last.empty() && C.find(last) == C.end()) pyRaise("KeyError", "'popitem(): dictionary is empty'");
            out = makeListValue({keyValue(last), C[last]}, true);
            C.erase(last);
            return true;
        }
        if (name == "update" || name == "merge") {
            if (!args.empty()) {
                if (Container* src = contOf(args[0]); src && seqLen(src) < 0 && !nygen::is_gen(args[0])) dictUpdate(cont, src);
                else for (auto& pairv : iterItems(args[0], ctx)) {
                    std::vector<Value> kv = iterItems(pairv, ctx);
                    if (kv.size() != 2) pyRaise("ValueError", "dictionary update sequence element has length " + std::to_string(kv.size()) + "; 2 is required");
                    dictSet(cont, kv[0], kv[1]);
                }
            }
            for (auto& [k, v] : kw) dictSet(cont, makeStringValue(k), v);
            out = name == "merge" ? obj : NONE_VALUE;
            return true;
        }
        if (name == "remove" || name == "delete") {
            // Nython's map.remove(key[, default]): erases and returns the value.
            if (args.empty()) { out = NONE_VALUE; return true; }
            std::string k = dictKey(args[0]);
            auto it = C.find(k);
            if (it != C.end()) { out = it->second; C.erase(k); return true; }
            out = args.size() >= 2 ? args[1] : NONE_VALUE;
            return true;
        }
        if (name == "clear") {
            std::vector<std::pair<std::string, Value>> keep;
            for (auto& kv : C) if (isInternalKey(kv.first)) keep.push_back(kv);
            C.clear();
            for (auto& kv : keep) C[kv.first] = kv.second;
            out = NONE_VALUE;
            return true;
        }
        return false;
    }

    // A dict's own entries (containers also hold "__len__"/"__type__" style
    // internal markers, which are not keys).
    static bool isInternalKey(const std::string& k) { return k.size() >= 2 && k[0] == '_' && k[1] == '_'; }
    int64_t dictSize(Container* c) {
        int64_t n = 0;
        for (auto& kv : *c->container) if (!isInternalKey(kv.first)) n++;
        return n;
    }
    Value makeDictValue() {
        auto* m = new Object((Runnable*)runner, "map", Type::MAP);
        return Value((Collectable*)m);
    }
    void dictUpdate(Container* dst, Container* src) {
        for (auto& kv : *src->container) if (!isInternalKey(kv.first)) (*dst->container)[kv.first] = kv.second;
    }
    // Keyword arguments of the builtin call being dispatched (evalCall sets
    // it for the builtins that read them; dispatch_pycore takes it).
    const nyrt::OrderedKw<Value>* cur_kwargs_ = nullptr;
    std::vector<std::string> cur_kw_order_;   // their names in call order (dict(a=1, b=2))
    struct KwScope {
        NythonExecutor* e; const nyrt::OrderedKw<Value>* prev;
        KwScope(NythonExecutor* x, const nyrt::OrderedKw<Value>* k) : e(x), prev(x->cur_kwargs_) { e->cur_kwargs_ = k; }
        ~KwScope() { e->cur_kwargs_ = prev; }
        KwScope(const KwScope&) = delete;
        KwScope& operator=(const KwScope&) = delete;
    };
    // A builtin called with keyword arguments from a path other than a
    // direct call by name - one held in an attribute or passed as a value
    // (partial(int, base=2), self.func(x, key=k)) - reads them as a direct
    // call does: they were dropped (int("101", base=2) gave 101).
    Value callBuiltinKw(const std::string& bn, std::vector<Value>& args,
                        const nyrt::OrderedKw<Value>* kw, Context* ctx) {
        if (!kw || kw->empty()) return callBuiltin(bn, args, ctx);
        if (isKwmapBuiltin(bn)) { appendKwMap(args, *kw); return callBuiltin(bn, args, ctx); }
        cur_kw_order_.clear();
        for (auto& kv : *kw) cur_kw_order_.push_back(kv.first);
        KwScope ks(this, kw);
        return callBuiltin(bn, args, ctx);
    }

    // A slice bound: false when omitted (none); raises for a non-integer.
    bool sliceArg(const std::vector<Value>& args, size_t i, int64_t& out) {
        if (i >= args.size() || args[i].type == ValueType::NONE) return false;
        Num n;
        Value iv;
        if (isInstanceValue(args[i]) && indexValue(args[i], iv, nullptr)) {   // __index__ (round 77)
            if (!asNum(iv, n)) n.k = 3;
        } else if (!asNum(args[i], n)) n.k = 3;
        if (n.k == 3) pyRaise("TypeError", "slice indices must be integers or None or have an __index__ method");
        out = n.k == 1 ? n.i : (numIsNeg(n) ? INT64_MIN / 2 : INT64_MAX / 2);
        return true;
    }
    // L[a:b] = it and L[a:b:c] = it (extended slices must match in length).
    void assignSlice(const Value& obj, const std::vector<Value>& sargs, const Value& val, Context* ctx) {
        if (wantsSliceObject(obj, "__setitem__")) {
            std::vector<Value> a{makeSliceObject(sargs, ctx), val};
            callMethod(obj, "__setitem__", a, ctx);
            return;
        }
        if (auto* bo = bytesOf(obj)) {
            if (!bo->mut) pyRaise("TypeError", "'bytes' object does not support item assignment");
            // the replacement: a bytes-like, or an iterable of ints
            nypy::BArg ra = toBArg(val, ctx);
            if (ra.k == nypy::BArg::INT || ra.k == nypy::BArg::BOOL || ra.k == nypy::BArg::STR)
                pyRaise("TypeError", "can assign only bytes, buffers, or iterables of ints in range(0, 256)");
            std::string repl = ra.k == nypy::BArg::BYTES ? ra.s : nyCall([&] {
                std::vector<nypy::BArg> one = {ra};
                return nypy::bytes_construct(one, "utf-8", "strict", false, "bytearray"); });
            std::string& d = bo->s;
            int64_t len = (int64_t)d.size(), st = 0, en = 0, step = 1;
            bool hs = sliceArg(sargs, 0, st), he = sliceArg(sargs, 1, en);
            if (sargs.size() >= 3 && sargs[2].type != ValueType::NONE) sliceArg(sargs, 2, step);
            int64_t cnt = nyCall([&] { return nypy::slice_adjust(len, hs, st, he, en, step); });
            if (step == 1) {
                if (cnt < 0) cnt = 0;
                if (st > len) st = len;
                d.replace((size_t)st, (size_t)cnt, repl);
            } else {
                if ((int64_t)repl.size() != cnt)
                    pyRaise("ValueError", "attempt to assign bytes of size " + std::to_string(repl.size()) + " to extended slice of size " + std::to_string(cnt));
                for (int64_t k = 0, i = st; k < cnt; k++, i += step) d[(size_t)i] = repl[(size_t)k];
            }
            return;
        }
        Container* cont = contOf(obj);
        if (!cont || seqLen(cont) < 0) pyRaise("TypeError", "'" + typeNameOf(obj) + "' object does not support item assignment");
        if (isTupleCont(cont)) pyRaise("TypeError", "'tuple' object does not support item assignment");
        std::vector<Value> items = seqItems(cont);
        std::vector<Value> repl = iterItems(val, ctx);
        int64_t len = (int64_t)items.size(), st = 0, en = 0, step = 1;
        bool hs = sliceArg(sargs, 0, st), he = sliceArg(sargs, 1, en);
        if (sargs.size() >= 3 && sargs[2].type != ValueType::NONE) sliceArg(sargs, 2, step);
        int64_t cnt = nyCall([&] { return nypy::slice_adjust(len, hs, st, he, en, step); });
        std::vector<Value> out;
        if (step == 1) {
            if (cnt < 0) cnt = 0;
            if (st > len) st = len;
            out.assign(items.begin(), items.begin() + st);
            out.insert(out.end(), repl.begin(), repl.end());
            out.insert(out.end(), items.begin() + st + cnt, items.end());
        } else {
            if ((int64_t)repl.size() != cnt)
                pyRaise("ValueError", "attempt to assign sequence of size " + std::to_string(repl.size()) + " to extended slice of size " + std::to_string(cnt));
            out = items;
            for (int64_t k = 0, i = st; k < cnt; k++, i += step) out[(size_t)i] = repl[(size_t)k];
        }
        for (int64_t k = 0; k < len; k++) cont->container->erase(std::to_string(k));
        int64_t w = 0;
        for (auto& v : out) (*cont->container)[std::to_string(w++)] = v;
        (*cont->container)["__len__"] = intValue(w);
    }

    // obj[idx]
    // ── slice objects (round 77) ──
    // a[i:j:k] is spelt a.slice(i, j, k) by the parser. An object whose
    // class has __getitem__ / __setitem__ / __delitem__ (and no slice
    // method of its own) gets a `slice` (the prelude's class) instead, as
    // in Python; a slice object used as an index of a builtin sequence
    // slices it.
    Value makeSliceObject(const std::vector<Value>& sargs, Context* ctx) {
        Value cls = global_ctx->getByName("slice");
        std::vector<Value> a{sargs.size() > 0 ? sargs[0] : NONE_VALUE, sargs.size() > 1 ? sargs[1] : NONE_VALUE,
                             sargs.size() > 2 ? sargs[2] : NONE_VALUE};
        return callFunctionValue(cls, a, ctx);
    }
    bool sliceObjectParts(const Value& v, std::vector<Value>& out) {
        if (!isInstanceValue(v) || shownClassName(instanceClassName(v)) != "slice") return false;
        auto pit = instance_properties.find(v.value.p);
        if (pit == instance_properties.end() || !pit->second || !pit->second->container) return false;
        auto& c = *pit->second->container;
        for (const char* f : {"start", "stop", "step"}) {
            auto it = c.find(f);
            out.push_back(it != c.end() ? it->second : NONE_VALUE);
        }
        return true;
    }
    bool wantsSliceObject(const Value& obj, const char* dunder) {
        return isInstanceValue(obj) && !instanceHasMethod(obj, "slice") && instanceHasMethod(obj, dunder);
    }
    // x.__index__() (PEP 357): an object standing for an int as a sequence
    // index, a range bound, hex()/bin()/chr() or %d (round 77; an IntEnum
    // member). `out` is the int; false when v has no __index__.
    bool indexValue(const Value& v, Value& out, Context* ctx) {
        if (!isInstanceValue(v) || !instanceHasMethod(v, "__index__")) return false;
        std::vector<Value> none;
        Value o = v;
        out = callMethod(o, "__index__", none, ctx ? ctx : global_ctx);
        if (out.type != ValueType::INTEGER && out.type != ValueType::BOOLEAN)
            pyRaise("TypeError", "__index__ returned non-int (type " + typeNameOf(out) + ")");
        return true;
    }
    // A list, tuple, str or bytes: what an __index__ object indexes as an int
    bool indexableSeq(const Value& obj) {
        if (bytesOf(obj)) return true;
        if (obj.type == ValueType::USERDATA && obj.value.p && !func_names.count(obj.value.p) && string_ptrs_.count(obj.value.p)) return true;
        Container* c = contOf(obj);
        return c && !isInstanceVal(obj) && seqLen(c) >= 0 && !isSetCont(c);
    }
    // `exc_out` (round 82): a list's, tuple's or dict's IndexError /
    // KeyError is put there (and none returned) instead of thrown.
    Value getItem(const Value& obj, const Value& idx, Context* ctx, std::string* exc_out = nullptr) {
        if (nygen::is_gen(obj)) pyRaise("TypeError", "'" + typeNameOf(obj) + "' object is not subscriptable");
        if (isInstanceValue(idx) && indexableSeq(obj)) {
            Value iv;
            if (indexValue(idx, iv, ctx)) return getItem(obj, iv, ctx, exc_out);
        }
        {
            std::vector<Value> parts;
            if (!isInstanceValue(obj) && sliceObjectParts(idx, parts)) {
                Value o = obj;
                return callMethod(o, "slice", parts, ctx);
            }
        }
        if (Container* sc = setOf(obj)) pyRaise("TypeError", "'" + std::string(isFrozenCont(sc) ? "frozenset" : "set") + "' object is not subscriptable");
        if (auto* bo = bytesOf(obj)) {
            Num k;
            if (!asNum(idx, k) || k.k == 3) pyRaise("TypeError", "byte indices must be integers or slices, not " + typeNameOf(idx));
            int64_t n = (int64_t)bo->s.size();
            int64_t i = k.k == 1 ? k.i : (numIsNeg(k) ? INT64_MIN / 2 : INT64_MAX / 2);
            if (i < 0) i += n;
            if (i < 0 || i >= n) pyRaise("IndexError", bo->mut ? "bytearray index out of range" : "index out of range");
            return intValue((int64_t)(unsigned char)bo->s[(size_t)i]);
        }
        // String indexing, in characters: s[0], s[-1]
        if (obj.type == ValueType::USERDATA && obj.value.p && !func_names.count(obj.value.p)) {
            const std::string& s = *(std::string*)obj.value.p;
            Num k;
            if (!asNum(idx, k) || k.k == 3) pyRaise("TypeError", "string indices must be integers, not '" + typeNameOf(idx) + "'");
            int64_t i = k.k == 1 ? k.i : (numIsNeg(k) ? INT64_MIN / 2 : INT64_MAX / 2);
            return makeStringValue(nyCall([&] { return nypy::str_getitem(s, i); }));
        }
        // List/Map indexing with negative index support
        if (Container* cont = contOf(obj)) {
            int64_t n = seqLen(cont);
            if (n >= 0) {
                Num k;
                if (asNum(idx, k) && k.k != 3) {
                    int64_t i = k.k == 1 ? k.i : (numIsNeg(k) ? INT64_MIN : INT64_MAX);
                    int64_t j = i;
                    if (j < 0) j += n;
                    if (j >= 0 && j < n) {
                        auto it = cont->container->find(std::to_string(j));
                        if (it != cont->container->end()) return it->second;
                    }
                    // Python's words, as the VM says them (it said "index 5
                    // out of range (length 2)" here).
                    std::string e = std::string("__exc__:IndexError:") + (isTupleCont(cont) ? "tuple" : "list") + " index out of range";
                    if (exc_out) { *exc_out = std::move(e); return NONE_VALUE; }   // round 82
                    throw e;
                }
            }
            auto it = dictFind(cont, idx);
            if (it != cont->container->end()) return it->second;
            // A missing dict key raises KeyError, as in Python (round 75: it
            // read none). d.get(k, default), `k in d` and d?[k] are the
            // graceful forms.
            if (n < 0 && exc_out && !nypy::lenient_reads_log()) { *exc_out = keyErrorFlow(idx); return NONE_VALUE; }   // round 82
            if (n < 0) return missingKey(idx, ctx);
            pyRaise("TypeError", std::string(isTupleCont(cont) ? "tuple" : "list") + " indices must be integers or slices, not " + typeNameOf(idx));
        }
        // __getitem__ on instances
        if (isInstanceVal(obj)) {
            // r[i] of a range of 64-bit ints, natively (round 78)
            if (idx.type == ValueType::INTEGER || idx.type == ValueType::BOOLEAN) {
                int64_t ra, rb, rs, n, i;
                if (rangeOf(obj, ra, rb, rs) && nyrt::range_len(ra, rb, rs, n)
                    && (idx.type == ValueType::BOOLEAN ? (i = idx.value.b ? 1 : 0, true) : bigint_fits_i64(idx.value.i, i))) {
                    if (i < 0) i += n;
                    if (i < 0 || i >= n) pyRaise("IndexError", "range object index out of range");
                    return intValue(nyrt::range_at(ra, rs, i));
                }
            }
            if (!instanceHasMethod(obj, "__getitem__"))
                pyRaise("TypeError", "'" + shownClassName(instanceClassName(obj)) + "' object is not subscriptable");
            std::vector<Value> call_args = {idx};
            return callMethod(obj, "__getitem__", call_args, ctx);
        }
        {
            Value cg;
            // a metaclass's __getitem__ comes before __class_getitem__
            if (!class_meta_.empty() && metaCall(obj, "__getitem__", {idx}, ctx, cg)) return cg;
            if (classSubscript(obj, idx, ctx, cg)) return cg;
        }
        // none[k], 5[0], f[0]: TypeError (they read none).
        std::string msg = "'" + typeNameOf(obj) + "' object is not subscriptable";
        if (nypy::lenient_reads_log()) { logLenientRead(nullptr, "TypeError: " + msg); return NONE_VALUE; }
        pyRaise("TypeError", msg);
    }
    // obj[idx] for d?[k]: false when the key or index does not exist - a
    // missing dict key, an index out of range, or __getitem__ raising
    // KeyError / IndexError. Other errors (an unhashable key, a type that is
    // not subscriptable) raise as obj[idx] does.
    bool tryGetItem(const Value& obj, const Value& idx, Context* ctx, Value& out) {
        if (Container* cont = contOf(obj)) {
            int64_t n = seqLen(cont);
            if (n < 0) {
                auto it = dictFind(cont, idx);
                if (it == cont->container->end()) return false;
                out = it->second;
                return true;
            }
            Num k;
            if (asNum(idx, k) && k.k == 1) {
                int64_t j = k.i < 0 ? k.i + n : k.i;
                if (j < 0 || j >= n) return false;
            }
        } else if (auto* bo = bytesOf(obj)) {
            Num k;
            if (asNum(idx, k) && k.k == 1) {
                int64_t n = (int64_t)bo->s.size();
                int64_t j = k.i < 0 ? k.i + n : k.i;
                if (j < 0 || j >= n) return false;
            }
        } else if (isStringValue(obj)) {
            Num k;
            if (asNum(idx, k) && k.k == 1) {
                int64_t n = (int64_t)nypy::u8_len(*(std::string*)obj.value.p);
                int64_t j = k.i < 0 ? k.i + n : k.i;
                if (j < 0 || j >= n) return false;
            }
        } else if (isInstanceVal(obj) && instanceHasMethod(obj, "__getitem__")) {
            try { out = getItem(obj, idx, ctx); }
            catch (std::string& e) {
                if (excTypeMatches(e, "KeyError") || excTypeMatches(e, "IndexError")) return false;
                throw;
            }
            return true;
        }
        out = getItem(obj, idx, ctx);
        return true;
    }

    // obj[idx] = val
    void setItem(const Value& obj, const Value& idx, const Value& val, Context* ctx) {
        {
            std::vector<Value> parts;
            if (!isInstanceValue(obj) && sliceObjectParts(idx, parts)) { assignSlice(obj, parts, val, ctx); return; }
        }
        if (isInstanceValue(idx) && indexableSeq(obj)) {
            Value iv;
            if (indexValue(idx, iv, ctx)) { setItem(obj, iv, val, ctx); return; }   // __index__ (round 77)
        }
        if (Container* sc = setOf(obj)) pyRaise("TypeError", "'" + std::string(isFrozenCont(sc) ? "frozenset" : "set") + "' object does not support item assignment");
        if (isInstanceVal(obj)) {
            if (!instanceHasMethod(obj, "__setitem__"))
                throw std::string("__exc__:TypeError:'" + shownClassName(instanceClassName(obj)) + "' object does not support item assignment");
            std::vector<Value> call_args = {idx, val};
            Value result = callMethod(obj, "__setitem__", call_args, ctx);
            if (result.type != ValueType::NONE) return;
        }
        if (auto* bo = bytesOf(obj)) {
            if (!bo->mut) pyRaise("TypeError", "'bytes' object does not support item assignment");
            Num k;
            if (!asNum(idx, k) || k.k == 3) pyRaise("TypeError", "bytearray indices must be integers or slices, not " + typeNameOf(idx));
            int64_t n = (int64_t)bo->s.size();
            int64_t i = k.k == 1 ? k.i : (numIsNeg(k) ? INT64_MIN / 2 : INT64_MAX / 2);
            if (i < 0) i += n;
            if (i < 0 || i >= n) pyRaise("IndexError", "bytearray index out of range");
            nypy::BArg b = toBArg(val, ctx);
            bo->s[(size_t)i] = (char)nyCall([&] { return nypy::byte_of(b); });
            return;
        }
        Container* cont = contOf(obj);
        if (!cont) {
            if (isStringValue(obj)) pyRaise("TypeError", "'str' object does not support item assignment");
            return;
        }
        int64_t n = seqLen(cont);
        if (n >= 0) {
            if (isTupleCont(cont)) pyRaise("TypeError", "'tuple' object does not support item assignment");
            Num k;
            if (!asNum(idx, k) || k.k == 3) pyRaise("TypeError", "list indices must be integers or slices, not " + typeNameOf(idx));
            int64_t i = k.k == 1 ? k.i : (numIsNeg(k) ? INT64_MIN / 2 : INT64_MAX / 2);
            if (i < 0) i += n;
            if (i < 0) pyRaise("IndexError", "list assignment index out of range");
            // Past the end the list grows (padded with none): the VM always
            // did this, and library code appends with `a[len] = x`. It used
            // to store the element without growing the length here.
            if (i >= n) {
                for (int64_t k = n; k < i; k++) (*cont->container)[std::to_string(k)] = NONE_VALUE;
                (*cont->container)["__len__"] = intValue(i + 1);
            }
            (*cont->container)[std::to_string(i)] = val;
            return;
        }
        dictSet(cont, idx, val);
    }

    // `pend` (round 82): the evaluator asking checks the pending flag right
    // after (evalP) - a missing key or an index out of range of a list,
    // tuple or dict raises by it (getItem's exc_out).
    Value evalSubscript(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* sn = static_cast<SubscriptNode*>((node).get());
        Value obj = evalNode(sn->object, ctx);
        Value idx = evalNode(sn->index, ctx);
        if (astSpecOn())   // a list's item by an int index (round 81)
            if (ContainerType::value_type* kv = seqItemSlot(obj, idx, sn->slot_off, false)) return kv->second;
        if (pend) {
            std::string e;
            Value r = getItem(obj, idx, ctx, &e);
            if (!e.empty()) { pendExc(std::move(e)); return NONE_VALUE; }
            return r;
        }
        return getItem(obj, idx, ctx);
    }

    // Every element an iterable yields: lists/tuples/sets/generators in
    // order, a dict's keys, a string's characters, or an instance's
    // __iter__/__next__ sequence.
    std::vector<Value> iterItems(const Value& v, Context* ctx) {
        // A generator: what is left of it, pulled one value at a time.
        if (nygen::Gen* g = nygen::gen_of(v)) {
            std::vector<Value> out;
            nygen::drain(*this, g, out, ctx);
            return out;
        }
        if (Container* c = contOf(v)) {
            if (seqLen(c) >= 0) return seqItems(c);
            return dictKeys(c);
        }
        if (auto* bo = bytesOf(v)) {
            std::vector<Value> out;
            out.reserve(bo->s.size());
            for (unsigned char c : bo->s) out.push_back(intValue((int64_t)c));
            return out;
        }
        if (isStringValue(v)) {
            std::vector<Value> out;
            for (auto& ch : nypy::u8_chars(*(std::string*)v.value.p)) out.push_back(makeStringValue(ch));
            return out;
        }
        // An object: __iter__ / __next__ / a __getitem__ sequence (iterValues);
        // a range or dict view natively (round 78).
        if (isInstanceVal(v)) {
            std::vector<Value> out;
            if (rangeOrViewItems(v, out)) return out;
            return iterValues(v, ctx);
        }
        // A class whose metaclass defines __iter__ (round 77)
        if (!class_meta_.empty()) {
            Value it;
            if (metaCall(v, "__iter__", {}, ctx, it)) return iterItems(it, ctx);
        }
        pyRaise("TypeError", "'" + typeNameOf(v) + "' object is not iterable");
    }
    // A value's address as reprs show it ("0x7f..."), round 77.
    static std::string hexId(const Value& v) {
        uintptr_t p = v.type == ValueType::USERDATA ? (uintptr_t)v.value.p : v.isCollectable() ? (uintptr_t)v.value.gc : 0;
        char buf[32];
        std::snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)p);
        return buf;
    }
    // round 81: an instance's default repr (and str), CPython's
    // object.__repr__: <module.Qualname object at 0x...>, with the class's
    // __module__ and __qualname__ and the address id() gives (it was
    // "<P instance>")
    std::string defaultInstanceRepr(const Value& v, Context* c) {
        std::string mod = "__main__", qn = typeNameOf(v);
        if (Node* cn = classNodeOfInstance(v)) {
            Value cls = classValueOfNode(cn), m, q;
            try {
                if (getAttrValue(cls, "__module__", c, m)) {
                    if (isStringValue(m)) mod = getStringValue(m);
                    else if (m.type == ValueType::NONE) mod.clear();
                }
                if (getAttrValue(cls, "__qualname__", c, q) && isStringValue(q)) qn = getStringValue(q);
            } catch (std::string&) {}
        }
        return "<" + (mod.empty() || mod == "builtins" ? qn : mod + "." + qn) + " object at " + idHex(v, c) + ">";
    }
    // the address id(v) gives, as reprs show it (round 81)
    std::string idHex(const Value& v, Context* c) {
        std::vector<Value> ia{v};
        Value idv = callBuiltin("id", ia, c);
        int64_t id = 0;
        if (idv.type == ValueType::INTEGER) bigint_fits_i64(idv.value.i, id);
        char buf[40];
        std::snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)id);
        return buf;
    }
    // Python's type name for messages.
    std::string typeNameOf(const Value& v) {
        switch (v.type) {
            case ValueType::NONE: return "NoneType";
            case ValueType::BOOLEAN: return "bool";
            case ValueType::INTEGER: return "int";
            case ValueType::DOUBLE: return "float";
            case ValueType::UNDEFINED: return "undefined";
            default: break;
        }
        if (auto* bo = bytesOf(v)) return bo->mut ? "bytearray" : "bytes";
        if (isStringValue(v)) return "str";
        if (nygen::is_gen(v)) return nygen::type_name(nygen::gen_of(v));
        if (Container* c = contOf(v)) {
            if (seqLen(c) < 0) return "dict";
            return isTupleCont(c) ? "tuple" : isSetCont(c) ? (isFrozenCont(c) ? "frozenset" : "set") : isGenCont(c) ? "generator" : "list";
        }
        if (v.type == ValueType::USERDATA && v.value.p) {
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                if (fit->second.rfind("__instance__:", 0) == 0) return shownClassName(fit->second.substr(13));
                if (fit->second.rfind("__class__:", 0) == 0) return "type";
                if (fit->second.rfind("__rtype__:", 0) == 0) return "type";
                if (fit->second.rfind("__builtin__:", 0) == 0 || fit->second.rfind("__bmethod__:", 0) == 0) return "builtin_function_or_method";
                if (bound_self_.count(v.value.p)) return "method";
                return "function";
            }
        }
        return "object";
    }

    // ─── STR / REPR ─────────────────────────────────────────────────────
    // One implementation behind print(), str(), repr(), f-strings, format()
    // and the text of containers, so all of them agree: containers show their
    // elements' repr (strings quoted), floats the shortest round-trip form.
    std::string strOf(const Value& v, Context* ctx = nullptr) { return toText(v, false, ctx, 0); }
    std::string reprOf(const Value& v, Context* ctx = nullptr) { return toText(v, true, ctx, 0); }
    std::string toText(const Value& v, bool repr, Context* ctx, int depth) {
        switch (v.type) {
            case ValueType::NONE: return "none";
            case ValueType::BOOLEAN: return v.value.b ? "true" : "false";
            case ValueType::INTEGER: return intToString(v.value.i);
            case ValueType::DOUBLE: return nypy::float_repr((double)v.value.d);
            case ValueType::UNDEFINED: return "undefined";
            default: break;
        }
        if (depth > 50) return "...";
        // a module: <module 'name' from 'file'>, as Python shows it (round
        // 78; its namespace printed as a dict)
        if (v.isCollectable() && v.value.gc && isModuleNamespace(v)) {
            auto* o = dynamic_cast<Object*>(contOf(v));
            std::string nm = o->getName(), file;
            auto field = [&](const char* k) -> std::string {
                auto it = o->container->find(k);
                if (it == o->container->end()) it = o->container->find(nypy::key_of_str(k));
                return it != o->container->end() && isStringValue(it->second) ? getStringValue(it->second) : std::string();
            };
            if (!field("__name__").empty()) nm = field("__name__");
            file = field("__file__");
            return "<module " + nypy::str_repr(nm) + (file.empty() ? std::string(" (built-in)") : " from " + nypy::str_repr(file)) + ">";
        }
        if (v.type == ValueType::USERDATA) {
            if (!v.value.p) return "none";
            // str(b) is its repr, as in Python
            if (auto* bo = bytesOf(v)) return nypy::bytes_repr(bo->s, bo->mut);
            if (string_ptrs_.count(v.value.p)) {
                const std::string& s = *(std::string*)v.value.p;
                return repr ? nypy::str_repr(s) : s;
            }
            if (!class_meta_.empty() && classNodeOfValue(v)) {
                Value r;
                Context* c = ctx ? ctx : global_ctx;
                if ((!repr && metaCall(v, "__str__", {}, c, r)) || metaCall(v, "__repr__", {}, c, r)) return getStringValue(r);
            }
            if (instance_to_class.count(v.value.p)) {
                std::vector<Value> no_args;
                Context* c = ctx ? ctx : global_ctx;
                std::string cn0 = instanceClassName(v);
                bool exc = !cn0.empty() && isExceptionClass(cn0);
                // what __str__ / __repr__ gave: a str (a str subclass's
                // value too), else Python's TypeError (round 78: any value
                // was shown as text, and None fell back to the default)
                auto textOf = [&](const Value& r, const char* which) -> std::string {
                    if (isStringValue(r)) return getStringValue(r);
                    Value p;
                    if (any_payload_ && payloadOf(r, p) && isStringValue(p)) return getStringValue(p);
                    pyRaise("TypeError", std::string(which) + " returned non-string (type " + typeNameOf(r) + ")");
                };
                if (!repr && instanceHasMethod(v, "__str__")) {
                    Value r;
                    try { r = callMethod(v, "__str__", no_args, c); }
                    catch (nython::node::ReturnSignal& rs) { r = rs.value; }
                    return textOf(r, "__str__");
                }
                // str() of an exception is BaseException.__str__ even when the
                // class has its own __repr__ (it comes first in the MRO)
                if ((repr || !exc) && instanceHasMethod(v, "__repr__")) {
                    Value r;
                    try { r = callMethod(v, "__repr__", no_args, c); }
                    catch (nython::node::ReturnSignal& rs) { r = rs.value; }
                    return textOf(r, "__repr__");
                }
                // An exception: its message for str(), Type(args...) for
                // repr(), as in Python and on the VM (round 77: the args'
                // reprs, not the message quoted).
                if (exc) return repr ? exceptionRepr(v, c) : exceptionMessage(v);
                return defaultInstanceRepr(v, c);   // round 81
            }
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                if (fit->second.rfind("__builtin__:", 0) == 0) {
                    std::string bn = fit->second.substr(12);
                    if (nyrt::is_builtin_type_name(bn)) return "<class '" + bn + "'>";
                    return "<built-in function " + bn + ">";
                }
                // the runtime's type objects, bound methods and builtin
                // methods as Python shows them (round 77)
                if (const nyrt::RuntimeType* rt = runtimeTypeOf(v)) return nyrt::runtime_type_repr(*rt);
                if (depth < 8) {
                    auto bs = bound_self_.find(v.value.p);
                    if (bs != bound_self_.end() && bs->second) {
                        Value q;
                        std::string qn = specialAttribute(v, "__qualname__", ctx ? ctx : global_ctx, q) && isStringValue(q) ? getStringValue(q) : std::string("?");
                        return "<bound method " + qn + " of " + toText(bs->second->self, true, ctx, depth + 1) + ">";
                    }
                    auto bm = bound_members_.find(v.value.p);
                    if (bm != bound_members_.end() && bm->second) {
                        const Value& r = bm->second->recv;
                        if (isInstanceValue(r))
                            return "<bound method " + bm->second->name + " of " + toText(r, true, ctx, depth + 1) + ">";
                        return "<built-in method " + bm->second->name + " of " + typeNameOf(r) + " object at " + hexId(r) + ">";
                    }
                }
                // round 81: a function as CPython shows it, <function
                // Qualname at 0x...> with the address id() gives (it was
                // <function name>)
                if (fit->second.rfind("__class__:", 0) != 0) {
                    Value q;
                    std::string qn;
                    try {
                        if (specialAttribute(v, "__qualname__", ctx ? ctx : global_ctx, q) && isStringValue(q)) qn = getStringValue(q);
                    } catch (std::string&) {}
                    if (!qn.empty()) return "<function " + qn + " at " + idHex(v, ctx ? ctx : global_ctx) + ">";
                }
                return funcDisplayName(fit->second);
            }
            const std::string& s = *(std::string*)v.value.p;
            return repr ? nypy::str_repr(s) : s;
        }
        if (nygen::is_gen(v)) return v.value.gc->toString();   // <generator object f at 0x...>
        Container* c = contOf(v);
        if (!c) return v.value.gc ? v.value.gc->toString() : "none";
        int64_t n = seqLen(c);
        // A container met again inside itself - directly or through another
        // one - is [...] / {...} (CPython's Py_ReprEnter; round 77: a cycle
        // through two containers printed 50 levels deep).
        static thread_local std::vector<const void*> active;
        for (const void* p : active)
            if (p == (const void*)c) return n < 0 ? "{...}" : isTupleCont(c) ? "(...)" : "[...]";
        active.push_back((const void*)c);
        struct Leave { ~Leave() { active.pop_back(); } } leave;
        if (n >= 0) {
            bool tup = isTupleCont(c), st = isSetCont(c);
            bool fz = st && isFrozenCont(c);
            if (st && n == 0) return fz ? "frozenset()" : "set()";
            std::string r = tup ? "(" : fz ? "frozenset({" : st ? "{" : "[";
            for (int64_t i = 0; i < n; i++) {
                if (i) r += ", ";
                auto it = c->container->find(std::to_string(i));
                if (it != c->container->end()) {
                    if (it->second.isCollectable() && it->second.value.gc == v.value.gc) r += tup ? "(...)" : "[...]";
                    else r += toText(it->second, true, ctx, depth + 1);
                }
            }
            if (tup && n == 1) r += ",";
            return r + (tup ? ")" : fz ? "})" : st ? "}" : "]");
        }
        std::string r = "{";
        bool first = true;
        for (auto& kv : *c->container) {
            if (isInternalKey(kv.first)) continue;
            if (!first) r += ", ";
            first = false;
            r += toText(keyValue(kv.first), true, ctx, depth + 1) + ": " + (kv.second.isCollectable() && kv.second.value.gc == v.value.gc ? std::string("{...}") : toText(kv.second, true, ctx, depth + 1));
        }
        return r + "}";
    }

    // ─── FORMATTING ─────────────────────────────────────────────────────
    // A value as the shared formatter sees it (NyFormat.hpp); conv is
    // 's', 'r' or 'a' to pass its str/repr/ascii text instead.
    nypy::FmtVal toFmtVal(const Value& v, char conv, Context* ctx) {
        if (conv == 's') return nypy::FmtVal::of_str(strOf(v, ctx));
        if (conv == 'r') return nypy::FmtVal::of_str(reprOf(v, ctx));
        if (conv == 'a') {
            std::string r = reprOf(v, ctx), out;
            for (size_t i = 0; i < r.size();) {
                size_t j = i; uint32_t cp = nypy::u8_decode(r, j);
                if (cp < 0x80) out += (char)cp; else out += nypy::hex_esc(cp);
                i = j;
            }
            return nypy::FmtVal::of_str(out);
        }
        switch (v.type) {
            case ValueType::NONE: return nypy::FmtVal::of_none();
            case ValueType::BOOLEAN: return nypy::FmtVal::of_bool(v.value.b);
            case ValueType::INTEGER: {
                int64_t i;
                if (bigint_fits_i64(v.value.i, i)) return nypy::FmtVal::of_int(i);
                return nypy::FmtVal::of_big(bigint_to_nbig(v.value.i));
            }
            case ValueType::DOUBLE: return nypy::FmtVal::of_float((double)v.value.d);
            default: break;
        }
        if (isStringValue(v)) return nypy::FmtVal::of_str(*(std::string*)v.value.p);
        return nypy::FmtVal::of_other(strOf(v, ctx), typeNameOf(v));
    }
    // format(value, spec), with __format__ on instances.
    std::string formatValue(const Value& v, const std::string& spec, Context* ctx) {
        if (isInstanceVal(v) && instanceHasMethod(v, "__format__")) {
            std::vector<Value> a = {makeStringValue(spec)};
            Value r = callMethod(v, "__format__", a, ctx ? ctx : global_ctx);
            if (isStringValue(r)) return getStringValue(r);
            // it must give a str (round 77; it was shown whatever it was)
            pyRaise("TypeError", "__format__ must return a str, not " + typeNameOf(r));
        }
        if (isInstanceVal(v) && spec.empty()) return strOf(v, ctx);   // object.__format__
        return nyCall([&] { return nypy::format_value(toFmtVal(v, 0, ctx), spec); });
    }
    // str methods: arguments to and results from nypy::str_method.
    nypy::SArg toSArg(const Value& v_in, Context* ctx) {
        // a str subclass's instance is its str (round 77)
        Value v = unwrapPayload(v_in);
        nypy::SArg a;
        a.tname = typeNameOf(v);
        switch (v.type) {
            case ValueType::NONE: a.k = nypy::SArg::NONE; return a;
            case ValueType::BOOLEAN: a.k = nypy::SArg::BOOL; a.i = v.value.b ? 1 : 0; return a;
            case ValueType::INTEGER: a.k = nypy::SArg::INT; a.i = bigint_to_i64(v.value.i); return a;
            default: break;
        }
        if (isStringValue(v)) { a.k = nypy::SArg::STR; a.s = *(std::string*)v.value.p; return a; }
        if (contOf(v) || isInstanceVal(v)) {
            // An iterable of strings (join, startswith((...)))
            std::vector<Value> items = iterItems(v, ctx);
            a.k = nypy::SArg::STRS;
            for (size_t i = 0; i < items.size(); i++) {
                if (any_payload_) items[i] = unwrapPayload(items[i]);   // ",".join([MyStr("a")]) (round 77)
                if (!isStringValue(items[i]))
                    pyRaise("TypeError", "sequence item " + std::to_string(i) + ": expected str instance, " + typeNameOf(items[i]) + " found");
                a.v.push_back(*(std::string*)items[i].value.p);
            }
            return a;
        }
        a.k = nypy::SArg::OTHER;
        return a;
    }
    Value fromSRes(const nypy::SRes& r) {
        switch (r.k) {
            case nypy::SRes::INT: return intValue(r.i);
            case nypy::SRes::BOOL: return Value(r.b);
            case nypy::SRes::STR:
                if (r.i == 1) { double d = 0; nypy::parse_float_str(r.s, d); return Value(d); }
                return makeStringValue(r.s);
            case nypy::SRes::LIST: case nypy::SRes::TUPLE: {
                std::vector<Value> items;
                items.reserve(r.v.size());
                for (auto& x : r.v) items.push_back(makeStringValue(x));
                return makeListValue(items, r.k == nypy::SRes::TUPLE);
            }
            default: return NONE_VALUE;
        }
    }
    // A value's attribute, for "{0.attr}" fields.
    Value attrOf(const Value& obj, const std::string& name) {
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto pit = instance_properties.find(obj.value.p);
            if (pit != instance_properties.end()) {
                Value v = pit->second->getByName(name);
                if (v.type != ValueType::UNDEFINED) return v;
            }
        }
        if (Container* c = contOf(obj)) {
            auto it = c->container->find(name);
            if (it != c->container->end()) return it->second;
        }
        pyRaise("AttributeError", "'" + typeNameOf(obj) + "' object has no attribute '" + name + "'");
    }
    // str.format: positional {} / {0}, named {name}, {0.attr}, {0[key]},
    // !r/!s/!a and format specs, through nypy::str_format.
    std::string strFormat(const std::string& fmt, const std::vector<Value>& args,
                          const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        return nyCall([&] {
            return nypy::str_format(fmt, [&](const nypy::FieldRef& f, char conv) -> nypy::FmtVal {
                Value v;
                if (f.numeric) {
                    if (f.index < 0 || (size_t)f.index >= args.size())
                        pyRaise("IndexError", "Replacement index " + std::to_string(f.index) + " out of range for positional args tuple");
                    v = args[(size_t)f.index];
                } else {
                    auto it = kw.find(f.name);
                    if (it == kw.end()) pyRaise("KeyError", nypy::str_repr(f.name));
                    v = it->second;
                }
                for (auto& step : f.chain) {
                    if (step.first == '.') v = attrOf(v, step.second);
                    else {
                        bool digits = !step.second.empty() && std::all_of(step.second.begin(), step.second.end(), [](char c) { return c >= '0' && c <= '9'; });
                        v = getItem(v, digits ? intValue((int64_t)std::stoll(step.second)) : makeStringValue(step.second), ctx);
                    }
                }
                if (conv) return toFmtVal(v, conv, ctx);
                if (isInstanceVal(v)) {
                    // "{:.2f}".format(Fraction(1, 3)): the object's __format__
                    // (it was never called: unsupported format string)
                    nypy::FmtVal fv = nypy::FmtVal::of_other(strOf(v, ctx), typeNameOf(v));
                    if (instanceHasMethod(v, "__format__"))
                        fv.custom = [this, v, ctx](const std::string& spec) { return formatValue(v, spec, ctx); };
                    return fv;
                }
                return toFmtVal(v, 0, ctx);
            });
        });
    }

    // An object formatted by %d / %x / %f ...: its __index__, else its
    // __float__ (round 77; an IntEnum member is formatted as its int)
    Value pctNumber(const Value& v, Context* ctx) {
        if (!isInstanceValue(v)) return v;
        Value iv;
        if (indexValue(v, iv, ctx)) return iv;
        if (instanceHasMethod(v, "__float__")) { std::vector<Value> none; Value o = v; return callMethod(o, "__float__", none, ctx); }
        return v;
    }
    // "fmt" % args
    Value percentFormat(const std::string& fmt, const Value& rv, Context* ctx) {
        {
            // a tuple or dict subclass's instance: its value's items or keys,
            // as CPython's PyTuple_Check / PyMapping_Check (round 77)
            Value pv;
            if (any_payload_ && payloadOf(rv, pv)) {
                Container* pc = contOf(pv);
                if (pc && ((seqLen(pc) >= 0 && isTupleCont(pc)) || (seqLen(pc) < 0 && !nygen::is_gen(pv))))
                    return percentFormat(fmt, pv, ctx);
            }
        }
        std::vector<Value> args;
        bool mapping = false;
        Container* rc = contOf(rv);
        if (rc && seqLen(rc) >= 0 && isTupleCont(rc)) args = seqItems(rc);
        else { args.push_back(rv); mapping = rc && seqLen(rc) < 0 && !nygen::is_gen(rv); }
        std::string out = nyCall([&] {
            return nypy::percent_format(fmt, (int64_t)args.size(), mapping,
                [&](int64_t i, const std::string& key, char conv) -> nypy::FmtVal {
                    if (i < 0) {
                        auto it = dictFind(rc, makeStringValue(key));
                        if (it == rc->container->end()) pyRaise("KeyError", nypy::str_repr(key));
                        return toFmtVal(conv == 0 ? pctNumber(it->second, ctx) : it->second, conv, ctx);
                    }
                    return toFmtVal(conv == 0 ? pctNumber(args[(size_t)i], ctx) : args[(size_t)i], conv, ctx);
                });
        });
        return makeStringValue(out);
    }

    // `pend` (round 82): the evaluator asking checks the pending flag right
    // after (evalP); the operands are evaluated so too, and a division by
    // zero raises by the flag.
    Value evalBinary(const node_ptr& node, Context* ctx, bool pend = false) {
        BinaryNode* bn = static_cast<BinaryNode*>(node.get());
        // the operator's code, worked out from its text once (round 81)
        if (__builtin_expect(bn->opc < 0, 0)) bn->opc = (int8_t)binOpCode(bn->op);
        const int opc = bn->opc;
        switch (opc) {
        // `and` / `or` short-circuit on truthiness and yield an operand, as in
        // Python: 0 or "x" is "x", [] or [1] is [1], "" and 1 is "". They used
        // to test only for false/none and always produced a bool for `and`.
        case OP_AND: {
            Value lv = evalNode(bn->left, ctx, pend);
            if (pend && raisedBy(lv)) return NONE_VALUE;   // round 82
            if (!isTruthy(lv)) return lv;
            return evalNode(bn->right, ctx, pend);
        }
        case OP_OR: {
            Value lv = evalNode(bn->left, ctx, pend);
            if (pend && raisedBy(lv)) return NONE_VALUE;   // round 82
            if (isTruthy(lv)) return lv;
            return evalNode(bn->right, ctx, pend);
        }
        // a ?? b: b only when a is none or undefined (and only then evaluated).
        case OP_COALESCE: { Value lv = evalNode(bn->left, ctx); if (!isAbsent(lv)) return lv; return evalNode(bn->right, ctx); }
        case OP_IS: case OP_ISNOT: {
            // `is` answers "does the left operand belong to the right?" in the
            // widest useful sense, not only pointer identity:
            //     1 is 1          -> true   (same value)
            //     1 is int        -> true   (type name)
            //     1 is Object     -> true   (everything is an Object)
            //     obj is MyClass  -> true   (class, walking the parent chain)
            // The right operand may be a TYPE NAME rather than a value, so the
            // type test is tried before evaluating it. `instanceof` is a second
            // spelling of `is`. `is not` is its negation (it used to rewrite
            // the AST node in place and put it back afterwards).
            Value lv = evalNode(bn->left, ctx);
            std::string tn = typeNameOperand(bn->right, ctx);
            bool r;
            if (!tn.empty() && isTypeObject(lv)) {
                // a type on the left (type(x) is int, C is C): identity, as
                // Python - a class is not an instance of itself (round 77)
                Value rv;
                bool have = false;
                try { rv = evalNode(bn->right, ctx); have = true; } catch (std::string&) {}
                if (have && isTypeObject(rv)) { r = identical(lv, rv); return Value(opc == OP_IS ? r : !r); }
            }
            if (!tn.empty()) r = valueIsOfType(lv, tn, ctx);
            else r = identical(lv, evalNode(bn->right, ctx));
            return Value(opc == OP_IS ? r : !r);
        }
        default: break;
        }
        Value lv = evalNode(bn->left, ctx, pend);
        if (pend && raisedBy(lv)) return NONE_VALUE;   // round 82
        Value rv = evalNode(bn->right, ctx, pend);
        if (pend && raisedBy(rv)) return NONE_VALUE;
        if (opc == OP_UNKNOWN) {
            // a @ b: __matmul__ / __rmatmul__ only.
            if (bn->op == "@") {
                Value res;
                if (binaryDunder("@", lv, rv, ctx, res)) return res;
                pyRaise("TypeError", "unsupported operand type(s) for @: '" + typeNameOf(lv) + "' and '" + typeNameOf(rv) + "'");
            }
            return NONE_VALUE;
        }
        // Numbers (round 81): what binaryOp does with two of them, without
        // its checks for sets, objects and bytes (none of which a number is).
        if (astSpecOn() && isNumType(lv.type) && isNumType(rv.type)) {
            if (pend && (opc == OP_DIV || opc == OP_FLOORDIV || opc == OP_MOD)) {
                // round 82: ZeroDivisionError by the flag (nypy::arith's words)
                Num x, y;
                if (asNum(rv, y) && numIsZero(y) && asNum(lv, x))
                    if (const char* zm = zeroDivMessage(opc, x, y)) { pendExc(std::string("__exc__:ZeroDivisionError:") + zm); return NONE_VALUE; }
            }
            Value r;
            if (numBinary(opc, lv, rv, r)) return r;
        }
        return binaryOp(opc, std::move(lv), std::move(rv), ctx);
    }
    // round 82: the message of the ZeroDivisionError x / // % y raises
    // (nypy::arith's), or nullptr when y is not zero
    static const char* zeroDivMessage(int opc, const Num& x, const Num& y) {
        if (!((y.k == 1 && y.i == 0) || (y.k == 3 && y.d == 0.0))) return nullptr;
        bool fl = x.k == 3 || y.k == 3;
        if (opc == OP_DIV) return fl ? "float division by zero" : "division by zero";
        if (opc == OP_FLOORDIV) return fl ? "float floor division by zero" : "integer division or modulo by zero";
        if (opc == OP_MOD) return fl ? "float modulo" : "integer modulo by zero";
        return nullptr;
    }
    static bool isNumType(ValueType t) {
        return t == ValueType::INTEGER || t == ValueType::DOUBLE || t == ValueType::BOOLEAN;
    }
    // binaryOp's answer for two numbers (bool, int or float), or false for
    // an operator it does not handle here (in, xor ...: binaryOp's then).
    bool numBinary(int opc, const Value& lv, const Value& rv, Value& out) {
        Num x, y;
        asNum(lv, x); asNum(rv, y);
        switch (opc) {
        case OP_ADD: case OP_SUB: case OP_MUL:
            if (x.k == 1 && y.k == 1) {
                int64_t r;
                bool ovf = opc == OP_ADD ? nypy::add_ovf(x.i, y.i, r) : opc == OP_SUB ? nypy::sub_ovf(x.i, y.i, r)
                                                                       : __builtin_mul_overflow(x.i, y.i, &r);
                if (!ovf) { out = intValue(r); return true; }
            } else if (x.k == 3 && y.k == 3) {
                out = Value(opc == OP_ADD ? x.d + y.d : opc == OP_SUB ? x.d - y.d : x.d * y.d);
                return true;
            }
            out = numArith(opc, x, y);
            return true;
        case OP_DIV: case OP_FLOORDIV: case OP_POW: case OP_MOD: case OP_LSHIFT: case OP_RSHIFT:
            out = numArith(opc, x, y);
            return true;
        case OP_BAND: case OP_BOR: case OP_BXOR: {
            Value r = numArith(opc, x, y);
            if (lv.type == ValueType::BOOLEAN && rv.type == ValueType::BOOLEAN) out = Value(isTruthy(r));
            else out = std::move(r);
            return true;
        }
        case OP_EQ: out = Value(numCmp(x, y) == 0); return true;
        case OP_NE: out = Value(numCmp(x, y) != 0); return true;
        case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            int c = numCmp(x, y);
            if (c == 2) { out = Value(false); return true; }   // a NaN: unordered
            out = Value(opc == OP_LT ? c < 0 : opc == OP_LE ? c <= 0 : opc == OP_GT ? c > 0 : c >= 0);
            return true;
        }
        case OP_SEQ: case OP_SNE: {
            bool eq = lv.type == rv.type && numCmp(x, y) == 0;
            out = Value(opc == OP_SEQ ? eq : !eq);
            return true;
        }
        default: return false;
        }
    }

    // Identity for `is`: immutable values (numbers, strings, none, bools)
    // by value, everything else by reference.
    bool identical(const Value& lv, const Value& rv) {
        if (lv.isNone() && rv.isNone()) return true;
        if (lv.isNone() || rv.isNone()) return false;
        if (lv.type != rv.type) return false;
        switch (lv.type) {
            case ValueType::INTEGER: case ValueType::DOUBLE: return valuesEqual(lv, rv, 0);
            case ValueType::BOOLEAN: return lv.value.b == rv.value.b;
            case ValueType::USERDATA:
                // Two equal strings are the same value even when they are
                // separate allocations; instances compare by pointer.
                if (string_ptrs_.count(lv.value.p) && string_ptrs_.count(rv.value.p))
                    return *(std::string*)lv.value.p == *(std::string*)rv.value.p;
                return lv.value.p == rv.value.p;
            case ValueType::COLLECTABLE: return lv.value.gc == rv.value.gc;
            default: return false;
        }
    }

    Value evalUnary(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* un = static_cast<UnaryNode*>((node).get());
        Value v = evalNode(un->operand, ctx, pend);
        if (pend && raisedBy(v)) return NONE_VALUE;   // round 82 (evalP)
        const std::string& op = un->op;
        if (op == "!" || op == "not") return Value(!isTruthy(v));
        if (op == "-" || op == "+" || op == "~") {
            Num n;
            if (asNum(v, n)) {
                if (op == "+") return n.k == 3 ? v : (v.type == ValueType::BOOLEAN ? intValue(n.i) : v);
                if (op == "-") {
                    if (n.k == 3) return Value(-n.d);
                    if (n.k == 1 && n.i != INT64_MIN) return intValue(-n.i);
                    return intValue(-numBig(n));
                }
                if (n.k == 3) pyRaise("TypeError", "bad operand type for unary ~: 'float'");
                if (n.k == 1) return intValue(~n.i);
                return intValue(-(numBig(n) + nypy::BigInt(1)));
            }
            if (isInstanceVal(v)) {
                const char* d = op == "-" ? "__neg__" : op == "+" ? "__pos__" : "__invert__";
                if (!instanceHasMethod(v, d))
                    pyRaise("TypeError", "bad operand type for unary " + op + ": '" + shownClassName(instanceClassName(v)) + "'");
                std::vector<Value> no_args;
                return callMethod(v, d, no_args, ctx);
            }
            // anything else has no unary + - ~: TypeError, as Python (round
            // 77: `-{}` was none, `~[1]` 0 and `+"a"` "a")
            pyRaise("TypeError", "bad operand type for unary " + op + ": '" + typeNameOf(v) + "'");
        }
        if (op == "++" || op == "--") {
            Num n;
            Value result = asNum(v, n) ? numArith(op == "++" ? OP_ADD : OP_SUB, n, Num{1, 1, 0.0, nullptr})
                                       : ((op == "++") ? v + Value(1) : v - Value(1));
            // Post-increment/decrement: update the variable in context
            if (un->operand->type() == NodeType::VARIABLE) {
                ctx->setByName(un->operand->value(), result);
            } else if (un->operand->type() == NodeType::ATTRIBUTE) {
                // Handle obj.field++
                auto* attr = static_cast<AttributeNode*>((un->operand).get());
                Value obj = evalNode(attr->object, ctx);
                if (obj.type == ValueType::USERDATA && obj.value.p) {
                    auto pit = instance_properties.find(obj.value.p);
                    if (pit != instance_properties.end())
                        pit->second->setByName(attr->attr, result);
                }
            }
            return v; // return OLD value (post-increment)
        }
        return v;
    }

    // The dunder pair (method, reflected method) of a binary operator.
    static bool opDunders(const std::string& op, const char*& d, const char*& rd) {
        static const std::unordered_map<std::string, std::pair<const char*, const char*>> m = {
            {"+", {"__add__", "__radd__"}}, {"-", {"__sub__", "__rsub__"}},
            {"*", {"__mul__", "__rmul__"}}, {"/", {"__truediv__", "__rtruediv__"}},
            {"%", {"__mod__", "__rmod__"}}, {"**", {"__pow__", "__rpow__"}},
            {"//", {"__floordiv__", "__rfloordiv__"}}, {"&", {"__and__", "__rand__"}},
            {"|", {"__or__", "__ror__"}}, {"^", {"__xor__", "__rxor__"}},
            {"<<", {"__lshift__", "__rlshift__"}}, {">>", {"__rshift__", "__rrshift__"}},
            {"<", {"__lt__", "__gt__"}}, {">", {"__gt__", "__lt__"}},
            {"<=", {"__le__", "__ge__"}}, {">=", {"__ge__", "__le__"}},
            {"==", {"__eq__", "__eq__"}}, {"!=", {"__ne__", "__ne__"}},
            {"@", {"__matmul__", "__rmatmul__"}},
        };
        auto it = m.find(op);
        if (it == m.end()) return false;
        d = it->second.first; rd = it->second.second;
        return true;
    }
    bool binaryDunder(const std::string& op, const Value& lv, const Value& rv, Context* ctx, Value& out) {
        const char* d; const char* rd;
        if (!opDunders(op, d, rd)) return false;
        bool li = isInstanceValue(lv), ri = isInstanceValue(rv);
        // A method returning NotImplemented declines: the other operand's
        // is tried next, then the caller's fallback (round 77).
        bool declined = false;
        auto call = [&](const Value& self, const char* name, const Value& arg) {
            std::vector<Value> a{arg};
            out = callMethod(self, name, a, ctx);
            if (!isNotImplemented(out)) return true;
            declined = true;
            return false;
        };
        // The right operand's reflected method comes first when its class
        // is a subclass of the left's that provides its own (Python's rule:
        // a subclass can take an operation over from its base).
        bool r_first = li && ri && rightOverrides(lv, rv, rd);
        if (r_first && call(rv, rd, lv)) return true;
        if (li && instanceHasMethod(lv, d) && call(lv, d, rv)) return true;
        if (op == "/" && li && instanceHasMethod(lv, "__div__") && call(lv, "__div__", rv)) return true;
        if (!r_first && ri && instanceHasMethod(rv, rd) && call(rv, rd, lv)) return true;
        if (op == "!=") {
            Value eq;
            if (binaryDunder("==", lv, rv, ctx, eq)) { out = Value(!isTruthy(eq)); return true; }
        }
        // Every method declined an arithmetic operator: TypeError, as Python
        // (a str operand would otherwise be concatenated leniently).
        if (declined && op != "==" && op != "!=" && op != "<" && op != ">" && op != "<=" && op != ">=")
            unsupportedOperands(binOpCode(op), lv, rv);
        return false;
    }
    // The prelude's NotImplemented singleton.
    Node* ni_class_ = nullptr;
    bool isNotImplemented(const Value& v) {
        if (!isInstanceValue(v)) return false;
        if (!ni_class_) ni_class_ = classNodeByName("_NyNotImplementedType");
        return ni_class_ && classNodeOfInstance(v) == ni_class_;
    }
    // rv's class is a subclass of lv's and defines `rd` below lv's class.
    bool rightOverrides(const Value& lv, const Value& rv, const char* rd) {
        Node* lc = classNodeOfInstance(lv);
        Node* rc = classNodeOfInstance(rv);
        if (!lc || !rc || lc == rc) return false;
        const auto& rm = classMro(rc);
        if (std::find(rm.begin(), rm.end(), lc) == rm.end()) return false;
        Value m; Node* where = nullptr;
        if (!findClassMember(rc, rd, m, &where) || !where) return false;
        const auto& lm = classMro(lc);
        return std::find(lm.begin(), lm.end(), where) == lm.end();
    }
    // ==, through __eq__ when either side defines it.
    bool pyEquals(const Value& a, const Value& b, Context* ctx) {
        if (isInstanceValue(a) || isInstanceValue(b)) {
            Value r;
            if (binaryDunder("==", a, b, ctx, r)) return isTruthy(r);
        }
        return valuesEqual(a, b, 0);
    }
    // <, through __lt__ / __gt__, for sorted/min/max over objects.
    bool pyLess(const Value& a, const Value& b, Context* ctx) {
        Value r;
        if ((isInstanceValue(a) || isInstanceValue(b)) && binaryDunder("<", a, b, ctx, r)) return isTruthy(r);
        std::vector<Value> none;
        Value lt = evalBinaryValues("<", a, b, ctx);
        return isTruthy(lt);
    }
    // Evaluates a binary operator on two values (no AST).
    Value evalBinaryValues(const std::string& op, const Value& a, const Value& b, Context* ctx) {
        return binaryOp(binOpCode(op), a, b, ctx);
    }

    // ─── PRINT ──────────────────────────────────────────────────────────
    Value evalPrint(const node_ptr& node, Context* ctx) {
        auto pn = static_pointer_cast<PrintNode>(node);
        // While tracing, the printed line is also recorded, so the debugger
        // can show exactly the output produced up to the current step.
        std::ostringstream cap;
        std::streambuf* saved = nullptr;
        if (trace_on() && !tracer().in_repr) saved = std::cout.rdbuf(cap.rdbuf());
        struct Restore { std::streambuf* s; ~Restore() { if (s) std::cout.rdbuf(s); } } restore{saved};
        // Every argument is evaluated before anything is written, as in
        // Python and on the VM: `print(a(), b())` shows the output of a()
        // and b() first, then the line (it printed a()'s value between
        // them).
        std::vector<Value> vals;
        vals.reserve(pn->args.size());
        for (auto& a : pn->args) vals.push_back(evalNode(a, ctx));
        std::string sep = " ", end = "\n";
        if (pn->sep) { Value sv = evalNode(pn->sep, ctx); if (!sv.isNone()) sep = getStringValue(sv); }
        if (pn->end) { Value ev = evalNode(pn->end, ctx); if (!ev.isNone()) end = getStringValue(ev); }
        auto out = [&]() -> Value {
            {
                // sys.stdout replaced (contextlib.redirect_stdout, a StringIO):
                // the line goes to its write(), as Python's print does
                Value target;
                if (stdoutRedirected(target)) {
                    std::string line;
                    for (size_t i = 0; i < vals.size(); i++) { if (i > 0) line += sep; line += strOf(vals[i], ctx); }
                    line += end;
                    std::vector<Value> wa{makeStringValue(line)};
                    callMethod(target, "write", wa, ctx);
                    return NONE_VALUE;
                }
            }
            for (size_t i = 0; i < vals.size(); i++) {
                if (i > 0) std::cout << sep;
                printValue(vals[i], ctx);
            }
            if (saved) {
                std::cout.rdbuf(saved);
                restore.s = nullptr;
                std::string line = cap.str();
                std::cout << line << end;
                if (end != "\n") std::cout.flush();
                traceOutput(line);
                return NONE_VALUE;
            }
            std::cout << end;
            if (end != "\n") std::cout.flush();
            else std::cout.flush();
            return NONE_VALUE;
        };
        // print is a builtin function: c_call / c_return (round 79)
        if (__builtin_expect(nytrace::t_hooks & nytrace::PROFILE, 0)) return pyProfileBuiltin(builtinValue("print"), out);
        return out();
    }

    // The sys module, once imported (one namespace for every import).
    Value sys_ns_ = UNDEFINED_VALUE;
    // Whether sys.stdout is something else than the standard stream it
    // starts as; `target` is then that object.
    bool stdoutRedirected(Value& target) {
        if (sys_ns_.type == ValueType::UNDEFINED || !sys_ns_.isCollectable() || !sys_ns_.value.gc) return false;
        auto* cont = dynamic_cast<Container*>(sys_ns_.value.gc);
        if (!cont || !cont->container) return false;
        auto it = cont->container->find("stdout");
        if (it == cont->container->end()) return false;
        const Value& so = it->second;
        if (so.type == ValueType::NONE || so.type == ValueType::UNDEFINED) return false;
        Value orig = global_ctx->getByName("_ny_stdout");
        if (so.type == orig.type && so.value.p == orig.value.p) return false;
        target = so;
        return true;
    }

    void printValueRepr(Value v, Context* ctx = nullptr) { std::cout << reprOf(v, ctx); }

    void printValue(Value v, Context* ctx = nullptr) { std::cout << strOf(v, ctx); }

    // ─── CONTROL FLOW ───────────────────────────────────────────────────
    Value evalIf(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* in = static_cast<IfNode*>((node).get());
        Value cond = evalNode(in->condition, ctx, pend);
        if (pend && raisedBy(cond)) return NONE_VALUE;   // round 82: the test raised (evalP)
        if (isTruthy(cond)) return evalNode(in->then_branch, ctx);
        for (auto& ei : in->elseif_branches) {
            auto* eif = static_cast<IfNode*>((ei).get());
            if (__builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0) && !in->is_expr) pyEvLineAt(eif, true);   // an elif's line (round 79)
            if (isTruthy(evalNode(eif->condition, ctx))) return evalNode(eif->then_branch, ctx);
        }
        if (in->else_branch) return evalNode(in->else_branch, ctx);
        return NONE_VALUE;
    }

    Value evalWhile(const node_ptr& node, Context* ctx) {
        auto* wn = static_cast<WhileNode*>((node).get());
        Value result = NONE_VALUE;
        bool broke = false;
        FlowState& lf = flow();
        bool head_first = true;   // round 79: sys.settrace's line event for the header, each time it is tested again
        const bool pend = canPend(ctx);   // round 82: the test may raise by the flag (evalP)
        while (true) {
            if (__builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0) && !head_first) pyEvLineAt(node.get(), true);
            head_first = false;
            if (pend) {
                Value c = evalP(wn->condition, ctx);
                if (raisedBy(c)) return result;
                if (!isTruthy(c)) break;
            } else if (!isTruthy(evalNode(wn->condition, ctx))) break;
            try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(wn->body, ctx); }
            catch (std::string& flow) {
                if (flow == "break") { broke = true; break; }
                if (flow == "continue") continue;
                // Anything else is a raised exception (or a signal for an
                // outer construct). It used to fall out of this handler and
                // be dropped: `while ...: raise ValueError()` carried on
                // looping and nothing could catch the error.
                throw;
            }
            NY_LOOP_FLOW(broke)
        }
        // while/else: execute else branch only on natural exit (no break)
        if (!broke && wn->else_branch) result = evalNode(wn->else_branch, ctx);
        return result;
    }

    // `for a, b in ...` over an object item: its values, as the generator
    // loop's bind_item (src/NyGen.cpp) does (round 77).
    template <class Bind>
    void bindUnpacked(ForNode* fn, const std::string& var_name, const Value& item, Context* ctx, Bind& bindv) {
        bindForItem(fn, var_name, item, ctx, bindv);   // round 82
    }
    // round 82: `for a, b, c in ...` - the item's values bound to the loop's
    // targets, as Python unpacks: exactly as many (ValueError otherwise,
    // CPython's words), a non-iterable item a TypeError, an iterator read no
    // further than one past the count. (A list or tuple item had extra
    // values dropped and missing ones bound to none; a string item bound
    // only the first target.) Every loop kind binds through it - evalFor's
    // and nygen::for_loop's.
    template <class Bind>
    void bindForItem(ForNode* fn, const std::string& var_name, const Value& item, Context* ctx, Bind& bindv) {
        const size_t n = fn->unpack_vars.size() + 1;
        if (Container* ec = contOf(item); ec && !isGenCont(ec) && !isSetCont(ec) && seqLen(ec) >= 0) {
            int64_t len = seqLen(ec);
            if ((size_t)len == n) {
                // a list or tuple of that many: its items in place
                bindv(var_name, seqAt(ec, 0));
                for (size_t ui = 1; ui < n; ui++) bindv(fn->unpack_vars[ui - 1]->value(), seqAt(ec, (int64_t)ui));
                return;
            }
            forUnpackCount(n, (size_t)len);
        }
        std::vector<Value> parts = forUnpackParts(item, n, ctx);
        bindv(var_name, parts[0]);
        for (size_t ui = 1; ui < n; ui++) bindv(fn->unpack_vars[ui - 1]->value(), parts[ui]);
    }
    // round 82: a list's or tuple's item i (0 <= i < its length)
    static Value seqAt(Container* c, int64_t i) {
        int8_t off = 0;
        ContainerType::value_type* kv = seqSlot(c->container, i, off);
        return kv ? kv->second : NONE_VALUE;
    }
    [[noreturn]] static void forUnpackRaise(size_t n, size_t got) {
        if (got > n) pyRaise("ValueError", "too many values to unpack (expected " + std::to_string(n) + ")");
        pyRaise("ValueError", "not enough values to unpack (expected " + std::to_string(n) + ", got " + std::to_string(got) + ")");
    }
    static void forUnpackCount(size_t n, size_t got) { if (got != n) forUnpackRaise(n, got); }
    // round 82: the n values of an item that is not a list or tuple: a
    // string's characters, a dict's keys, a set's items, an object's or a
    // generator's values (at most n + 1 read, as CPython's unpack_iterable)
    std::vector<Value> forUnpackParts(const Value& item, size_t n, Context* ctx) {
        std::vector<Value> out;
        switch (item.type) {
            case ValueType::INTEGER: case ValueType::DOUBLE: case ValueType::BOOLEAN:
            case ValueType::NONE: case ValueType::UNDEFINED:
                pyRaise("TypeError", "cannot unpack non-iterable " + typeNameOf(item) + " object");
            default: break;
        }
        if (Container* ec = contOf(item); ec && !isGenCont(ec) && !isSetCont(ec) && seqLen(ec) >= 0) out = seqItems(ec);
        else if (isStringValue(item) || bytesOf(item) || (contOf(item) && !nygen::is_gen(item))) out = iterItems(item, ctx);
        else if (isInstanceValue(item) && !rangeOf3(item) && viewOf(item, nullptr) < 0
                 && !instanceHasMethod(item, "__iter__") && !instanceHasMethod(item, "__next__") && !instanceHasMethod(item, "__getitem__"))
            pyRaise("TypeError", "cannot unpack non-iterable " + shownClassName(instanceClassName(item)) + " object");
        else if (isInstanceValue(item) || nygen::is_gen(item)) {
            Value it = nygen::make_iter(*this, item, ctx);
            if (nygen::is_gen(it)) {
                Value lst = nygen::unpack_list(*this, it, (int)n, ctx);   // n values exactly, or its ValueError
                if (Container* lc = contOf(lst)) out = seqItems(lc);
            } else {
                std::vector<Value> no_args;
                while (out.size() <= n) {
                    Value v;
                    try { v = callMethod(it, "__next__", no_args, ctx); }
                    catch (nython::node::ReturnSignal& r) { v = r.value; }
                    catch (std::string& exc) { if (excTypeMatches(exc, "StopIteration")) break; throw; }
                    out.push_back(v);
                }
            }
        } else out = iterItems(item, ctx);   // a class whose metaclass iterates, or its TypeError
        forUnpackCount(n, out.size());
        return out;
    }
    bool rangeOf3(const Value& v) { int64_t a, b, s; return rangeOf(v, a, b, s); }
    Value evalFor(const node_ptr& node, Context* ctx) {
        auto* fn = static_cast<ForNode*>((node).get());
        bool broke = false;
        FlowState& lf = flow();
        uint64_t gen_s0 = nygen::serial_now();
        // `for i in range(...)` (round 78): the arguments are evaluated and,
        // when they are 64-bit ints, the loop counts natively without making
        // the range object; anything else makes it (range() itself checks).
        // `for k, v in d.items()` (and keys/values) over a plain dict: the
        // entries are walked without making the view (round 78).
        Value iter_val;
        bool counted = false, evaluated = false;
        int64_t r_first = 0, r_step = 1, r_n = 0;
        int dict_kind = -1;
        Value dict_val;
        if (range_node_ && fn->iterable && fn->iterable->type() == NodeType::CALL) {
            auto* rc = static_cast<CallNode*>(fn->iterable.get());
            if (rc->callee && rc->callee->type() == NodeType::VARIABLE && rc->callee->value() == "range"
                && !rc->args.empty() && rc->args.size() <= 3) {
                Value callee = evalNode(rc->callee, ctx);
                if (callee.type == ValueType::USERDATA && callee.value.p == (void*)range_node_) {
                    std::vector<Value> ra; nyrt::OrderedKw<Value> rkw;
                    evalCallArgs(rc->args, ctx, ra, rkw);
                    int64_t b[3] = {0, 0, 1};
                    bool small = rkw.empty() && !ra.empty() && ra.size() <= 3;
                    for (size_t k = 0; small && k < ra.size(); k++)
                        small = ra[k].type == ValueType::INTEGER && bigint_fits_i64(ra[k].value.i, b[ra.size() == 1 ? 1 : k]);
                    if (small && fn->unpack_vars.empty() && b[2] != 0 && nyrt::range_len(b[0], b[1], b[2], r_n)) {
                        counted = true; r_first = b[0]; r_step = b[2];
                    } else iter_val = makeRange(ra, rkw, ctx);
                    evaluated = true;
                }
            } else if (view_nodes_[0] && rc->args.empty() && rc->callee && rc->callee->type() == NodeType::ATTRIBUTE) {
                // d.keys() / d.values() / d.items() where d is a name or a
                // field of one (reading it is pure, so when it is not a plain
                // dict the call is simply evaluated as written)
                auto* an = static_cast<AttributeNode*>(rc->callee.get());
                int k = an->attr == "keys" ? 0 : an->attr == "values" ? 1 : an->attr == "items" ? 2 : -1;
                Value recv;
                if (k >= 0 && an->object && an->object->type() == NodeType::VARIABLE) recv = evalNode(an->object, ctx);
                else if (k >= 0 && an->object && an->object->type() == NodeType::ATTRIBUTE) {
                    auto* inner = static_cast<AttributeNode*>(an->object.get());
                    if (!any_getattribute_ && inner->object && inner->object->type() == NodeType::VARIABLE) {
                        Value owner = evalNode(inner->object, ctx);
                        if (isInstanceValue(owner)) recv = instField(owner, inner->attr);   // its own field, no getter
                    }
                }
                Container* dc = contOf(recv);
                if (dc && isPlainDict(dc)) { dict_kind = k; dict_val = recv; evaluated = true; }
            }
        }
        if (!evaluated) iter_val = evalNode(fn->iterable, ctx);
        if (!counted && dict_kind < 0) {
            int64_t ra, rb, rs;
            if (fn->unpack_vars.empty() && rangeOf(iter_val, ra, rb, rs) && nyrt::range_len(ra, rb, rs, r_n)) { counted = true; r_first = ra; r_step = rs; }
            else {
                // a dict view, or a dict itself (its keys)
                dict_kind = viewOf(iter_val, &dict_val);
                if (dict_kind < 0) {
                    Container* dc = contOf(iter_val);
                    if (dc && seqLen(dc) < 0 && !nygen::is_gen(iter_val)) { dict_kind = 0; dict_val = iter_val; }
                }
            }
        }
        // A generator the iterable expression made itself belongs to this
        // loop alone: it is closed when the loop ends (break, return, error),
        // as CPython's reference counting does (nygen::fresh).
        bool gen_owned = gen_s0 != nygen::serial_now() && nygen::fresh(iter_val, fn->iterable, call_depth_, gen_s0);
        std::string var_name = fn->var->value();
        Value result = NONE_VALUE;
        // The loop variable is a local, unless the function declared it
        // `global`/`nonlocal` (then the existing binding is rebound).
        // A name declared `global` is the module's (VariableNode::global_ref).
        auto bindv = [&](const std::string& n, const Value& v) {
            auto gref = [](const node_ptr& v) { return v && v->type() == NodeType::VARIABLE && static_cast<VariableNode*>(v.get())->global_ref; };
            bool glob = n == var_name && gref(fn->var);
            for (auto& u : fn->unpack_vars) if (!glob && u->value() == n) glob = gref(u);
            if (glob) moduleCtx(ctx)->defineByName(n, v);
            else if (fn->rebinds) ctx->setByName(n, v); else ctx->defineByName(n, v);
        };
        // An object whose __iter__ returns a list, a generator or iter(...):
        // the loop runs over that. (The loop below called __next__ on the
        // list, got none forever and never ended.)
        // A range of 64-bit ints (round 78): counted, no iterator object.
        if (counted) {
            // round 81: a plain local loop variable is stored straight into
            // its slot (defineByName's store, the slot remembered by the node)
            const bool plain_var = astSpecOn() && fn->unpack_vars.empty() && !fn->rebinds
                && !(fn->var && fn->var->type() == NodeType::VARIABLE && static_cast<VariableNode*>(fn->var.get())->global_ref);
            for (int64_t i = 0; i < r_n; i++) {
                NY_PYT_HEAD(i > 0)
                if (plain_var && ctx->container && !ctx->storeHook) {
                    ContainerType* m = ctx->container;
                    if (ContainerType::value_type* kv = m->slot_at_mut(fn->var_hint); kv && kv->first == var_name)
                        kv->second = intValue(nyrt::range_at(r_first, r_step, i));
                    else {
                        (*m)[var_name] = intValue(nyrt::range_at(r_first, r_step, i));
                        long s = m->index_of(var_name);
                        if (s >= 0) fn->var_hint = (uint32_t)s;
                    }
                } else
                bindv(var_name, intValue(nyrt::range_at(r_first, r_step, i)));
                try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                NY_LOOP_FLOW(broke)
            }
            NY_PYT_HEAD(!broke && r_n > 0)
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }
        // A dict, or a dict view: its entries walked live, as CPython's dict
        // iterators do (round 78; over a snapshot of the keys, a body adding
        // or deleting entries went unnoticed - a RuntimeError in Python).
        if (dict_kind >= 0) {
            Value hold = dict_val;
            auto* m = contOf(hold)->container;
            const size_t size0 = m->size();
            size_t slot = 0;
            auto bindElem = [&](const Value& elem) {
                if (fn->unpack_vars.empty()) { bindv(var_name, elem); return; }
                bindForItem(fn, var_name, elem, ctx, bindv);   // round 82: the count checked
            };
            for (bool head_first = true;; head_first = false) {
                NY_PYT_HEAD(!head_first)
                if (m->size() != size0) pyRaise("RuntimeError", "dictionary changed size during iteration");
                const std::pair<std::string, Value>* kv = nullptr;
                while (slot < m->slot_end()) {
                    kv = m->slot_at(slot++);
                    if (kv && !isInternalKey(kv->first)) break;
                    kv = nullptr;
                }
                if (!kv) break;
                if (dict_kind == 2 && fn->unpack_vars.size() == 1) {
                    // for k, v in d.items(): no pair is made
                    Value k = keyValue(kv->first), v = kv->second;
                    bindv(var_name, k);
                    bindv(fn->unpack_vars[0]->value(), v);
                } else {
                    Value elem = dict_kind == 0 ? keyValue(kv->first) : dict_kind == 1 ? Value(kv->second)
                               : makeListValue({keyValue(kv->first), kv->second}, true);
                    bindElem(elem);
                }
                try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                NY_LOOP_FLOW(broke)
            }
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }
        Value pre_iterator; bool have_pre_iterator = false;
        if (isInstanceValue(iter_val) && instanceHasMethod(iter_val, "__iter__")) {
            std::vector<Value> no_args;
            uint64_t s1 = nygen::serial_now();
            Value it = callMethod(iter_val, "__iter__", no_args, ctx);
            if (isInstanceValue(it)) { pre_iterator = it; have_pre_iterator = true; }
            else if (it.type != ValueType::NONE && it.type != ValueType::UNDEFINED) {
                iter_val = it;
                gen_owned = nygen::fresh_implicit(it, call_depth_, s1);   // `def __iter__(self): yield ...`
            }
            else throw std::string("__exc__:TypeError:iter() returned non-iterator of type 'NoneType'");
        }
        // A class whose metaclass defines __iter__ (`for m in Color:`): the
        // loop runs over what it returns (round 77; the loop ran no times).
        if (!class_meta_.empty() && !isInstanceValue(iter_val) && classNodeOfValue(iter_val)) {
            Value it;
            uint64_t s1 = nygen::serial_now();
            if (metaCall(iter_val, "__iter__", {}, ctx, it)) {
                if (isInstanceValue(it)) { pre_iterator = it; have_pre_iterator = true; }
                else gen_owned = nygen::fresh_implicit(it, call_depth_, s1);
                iter_val = it;
            }
        }
        // A generator: one value per iteration, pulled lazily (src/NyGen.cpp).
        if (nygen::is_gen(iter_val)) return nygen::for_loop(*this, fn, iter_val, ctx, gen_owned);

        // range() returns an integer — iterate 0..n-1
        if (iter_val.type == ValueType::INTEGER) {
            int64_t n = bigint_to_i64(iter_val.value.i);
            for (int64_t i = 0; i < n; i++) {
                NY_PYT_HEAD(i > 0)
                bindv(var_name, Value((int)i));
                try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                NY_LOOP_FLOW(broke)
            }
            NY_PYT_HEAD(!broke && n > 0)
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }

        // List/collection iteration — iterate by index order
        if (iter_val.isCollectable() && iter_val.value.gc) {
            auto* cont = dynamic_cast<Container*>(iter_val.value.gc);
            if (cont && cont->container) {
                // Check if this is a list (has numeric indices) or a map (has string keys)
                auto len_it = cont->container->find("__len__");
                int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                bool is_list = seqLen(cont) >= 0;
                
                if (!is_list) {
                    // Dict/map iteration: its keys, live, as Python's
                    // dict_keyiterator (round 78: over a snapshot, so a body
                    // adding or deleting entries went unnoticed; it is a
                    // RuntimeError in Python)
                    return nygen::for_loop(*this, fn, nygen::make_dict_iter(*this, iter_val, 0, false), ctx, true);
                }
                
                // List iteration by numeric index - round 81: the list's
                // length read at each step, as CPython's listiterator (an
                // item appended in the loop is reached, a shrunk list ends
                // it); a set keeps the length it started with, and one whose
                // size changed is a RuntimeError, as CPython's setiterator
                const bool live = !isSetCont(cont);
                const int start_len = len;
                for (int i = 0; ; i++) {
                    if (i > 0) {
                        auto li = cont->container->find("__len__");
                        int now = li != cont->container->end() ? static_cast<int>(bigint_to_i64(li->second.value.i)) : 0;
                        if (live) len = now;
                        else if (now != start_len) pyRaise("RuntimeError", "Set changed size during iteration");
                    }
                    if (i >= len) break;
                    NY_PYT_HEAD(i > 0)
                    std::string key = std::to_string(i);
                    auto it = cont->container->find(key);
                    if (it != cont->container->end()) {
                        Value elem = it->second;
                        // round 82: a tuple, list, string, object ... item
                        // unpacked as Python does, its count checked
                        if (!fn->unpack_vars.empty()) bindForItem(fn, var_name, elem, ctx, bindv);
                        else {
                            bindv(var_name, elem);
                        }
                        try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                        catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                        NY_LOOP_FLOW(broke)
                    }
                }
                NY_PYT_HEAD(!broke && len > 0)
            }
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }

        // bytes / bytearray: the ints of its bytes (a bytearray changed by
        // the loop is read as it is at each step, as in Python)
        if (auto* bo = bytesOf(iter_val)) {
            Value hold = iter_val;
            for (size_t k = 0; k < bo->s.size(); k++) {
                NY_PYT_HEAD(k > 0)
                bindv(var_name, intValue((int64_t)(unsigned char)bo->s[k]));
                try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                NY_LOOP_FLOW(broke)
            }
            NY_PYT_HEAD(!broke && !bo->s.empty())
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }
        // String iteration — iterate characters
        if (iter_val.type == ValueType::USERDATA && iter_val.value.p) {
            // Check if it's a string (not in func_names)
            if (!func_names.count(iter_val.value.p)) {
                // By character, not byte.
                std::vector<std::string> chars = nypy::u8_chars(*static_cast<std::string*>(iter_val.value.p));
                for (size_t ci = 0; ci < chars.size(); ci++) {
                    NY_PYT_HEAD(ci > 0)
                    bindv(var_name, makeStringValue(chars[ci]));
                    try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                    catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                    NY_LOOP_FLOW(broke)
                }
                NY_PYT_HEAD(!broke && !chars.empty())
                if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
                return result;
            }
        }

        // __iter__/__next__ protocol for user-defined iterables
        if (iter_val.type == ValueType::USERDATA && iter_val.value.p && !string_ptrs_.count(iter_val.value.p) && instance_to_class.count(iter_val.value.p)) {
            // Call __iter__ if present to get the iterator (may return self)
            std::vector<Value> no_args;
            Value iterator = have_pre_iterator ? pre_iterator : iter_val;
            // round 79: the sequence protocol - __getitem__(0), (1), ...
            // until IndexError, Python's fallback for an object with no
            // __iter__ (list(obj) took it; a for loop said "not iterable")
            bool by_index = false;
            int by_index_i = 0;
            if (!instanceHasMethod(iterator, "__next__")) {
                if (!have_pre_iterator && instanceHasMethod(iterator, "__getitem__")) by_index = true;
                else throw std::string("__exc__:TypeError:'" + shownClassName(instanceClassName(iterator)) + "' object is not iterable");
            }
            // Now call __next__ repeatedly until StopIteration
            for (bool head_first = true;; head_first = false) {
                NY_PYT_HEAD(!head_first)
                Value item;
                bool stop = false;
                try {
                    if (by_index) {
                        std::vector<Value> ia{Value(by_index_i++)};
                        item = callMethod(iterator, "__getitem__", ia, ctx);
                    } else {
                        item = callMethod(iterator, "__next__", no_args, ctx);
                    }
                } catch (nython::node::ReturnSignal& rs) {
                    item = rs.value;
                } catch (std::string& exc) {
                    if (by_index ? (excTypeMatches(exc, "IndexError") || excTypeMatches(exc, "StopIteration"))
                                 : (excTypeMatches(exc, "StopIteration") || exc.find("StopIteration") != std::string::npos)) { stop = true; }
                    else throw;
                }
                if (stop) break;
                // Unpack the item for `for k, v in ...` (round 82: as
                // Python does, its count checked - bindForItem)
                if (!fn->unpack_vars.empty()) bindForItem(fn, var_name, item, ctx, bindv);
                else {
                    bindv(var_name, item);
                }
                try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(fn->body, ctx); }
                catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                NY_LOOP_FLOW(broke)
            }
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }

        // Execute else branch if loop completed without break
        if (!broke && fn->else_branch) {
            result = evalNode(fn->else_branch, ctx);
        }
        return result;
    }

    Value evalRepeat(const node_ptr& node, Context* ctx) {
        auto rn = static_pointer_cast<RepeatNode>(node);
        Value count = evalNode(rn->count, ctx);
        int64_t n = (count.type == ValueType::INTEGER) ? bigint_to_i64(count.value.i) : 0;
        Value result = NONE_VALUE;
        bool broke = false;
        FlowState& lf = flow();
        for (int64_t i = 0; i < n; i++) {
            try { LoopBody _lb(lf); if (result.value.o) result = Value(); result = evalNode(rn->body, ctx); }
            catch (std::string& flow) {
                if (flow == "break") break;
                if (flow == "continue") continue;
                throw;   // a raised exception, not loop control (see evalWhile)
            }
            NY_LOOP_FLOW(broke)
        }
        (void)broke;
        return result;
    }

    Value evalSwitch(const node_ptr& node, Context* ctx) {
        auto sn = static_pointer_cast<SwitchNode>(node);
        Value subject = evalNode(sn->subject, ctx);
        for (auto& c : sn->cases) {
            auto cn = static_pointer_cast<CaseNode>(c);
            // Wildcard: `case _:` acts as a catch-all — also triggers if case val is UNDEFINED
            bool is_wildcard = (cn->value_node->value() == "_");
            if (!is_wildcard) {
                Value case_val_probe = evalNode(cn->value_node, ctx);
                if (case_val_probe.type == ValueType::UNDEFINED) is_wildcard = true;
            }
            if (is_wildcard) {
                try { return evalNode(cn->body, ctx); }
                catch (nython::node::ReturnSignal& r) { throw; }
                catch (...) { throw; }
            }
            Value case_val = evalNode(cn->value_node, ctx);
            // Compare using type-aware comparison
            bool match = false;
            if (subject.type == ValueType::INTEGER && case_val.type == ValueType::INTEGER)
                match = bigint_to_i64(subject.value.i) == bigint_to_i64(case_val.value.i);
            else if (subject.type == ValueType::DOUBLE && case_val.type == ValueType::DOUBLE)
                match = subject.value.d == case_val.value.d;
            else if (subject.type == ValueType::BOOLEAN && case_val.type == ValueType::BOOLEAN)
                match = subject.value.b == case_val.value.b;
            else if (isStringValue(subject) || isStringValue(case_val))
                match = getStringValue(subject) == getStringValue(case_val);
            else
                match = subject.equals(case_val);
            if (match) return evalNode(cn->body, ctx);
        }
        if (sn->default_case) {
            auto dn = static_pointer_cast<DefaultNode>(sn->default_case);
            if (dn->body) return evalNode(dn->body, ctx);
        }
        return NONE_VALUE;
    }

    // ─── FUNCTION / CLASS / LAMBDA ──────────────────────────────────────
    Value evalFunctionDecl(const node_ptr& node, Context* ctx) {
        auto fn = static_pointer_cast<FunctionNode>(node);
        // A unique identity per function value: the id inside its heap
        // object (nyheap::Func), which owns every side-table entry below.
        auto* fo = new nyheap::Func(this, ++closure_id_counter);
        void* unique_ptr = (void*)&fo->id;
        Value func_val = nyheap::userValue(fo, unique_ptr);
        func_names[unique_ptr] = "__func__:" + fn->name;
        closure_contexts[unique_ptr] = ctx;
        fo->setScope(ctx);
        // Also store the AST node pointer so we can find the FunctionNode later
        func_ast_nodes[unique_ptr] = (void*)node.get();
        fo->code = node.get();   // round 81
        heap_owner_[unique_ptr] = fo;
        nygc::track(fo);
        captureDefaults(fn.get(), unique_ptr, ctx);
        // __annotations__, evaluated when the def runs (round 77; the parser
        // makes the dict display, each value through the prelude's _ny_ann).
        if (fn->annotations) func_attrs_[unique_ptr]["__annotations__"] = evalNode(fn->annotations, ctx);

        ctx->defineByName(fn->name, func_val);
        return func_val;
    }



    // Check if an AST subtree contains any YieldNode (used to skip generator probe)
    // Whether a function body yields, cached per body node: every call to a
    // user function asks, and the walk is proportional to the body's size.
    std::unordered_map<const Node*, bool> yield_cache_;
    bool bodyYields(const node_ptr& body) {
        if (!body) return false;
        auto it = yield_cache_.find(body.get());
        if (it != yield_cache_.end()) return it->second;
        bool y = hasYield(body);
        yield_cache_[body.get()] = y;
        return y;
    }
    // Whether a function body contains yield / yield from anywhere outside
    // nested functions, lambdas and classes: in expressions (x = yield v,
    // f((yield v))), and in every compound statement - match (an if-chain),
    // with, except/else/finally clauses and switch cases were not looked at,
    // so such a function ran as a plain function and its yield aborted the
    // process with an uncaught YieldSignal.
    bool hasYield(const node_ptr& node) {
        if (!node) return false;
        switch (node->type()) {
            case NodeType::YIELD: case NodeType::YIELD_FROM: return true;
            case NodeType::FUNCTION: case NodeType::LAMBDA: case NodeType::CLASS:
            case NodeType::COMPREHENSION:
                return false;
            // round 82: leaves - no child can yield (the chain of
            // dynamic_casts below ran for each; most nodes are these)
            case NodeType::VARIABLE: case NodeType::INTEGER: case NodeType::FLOAT: case NodeType::STRING:
            case NodeType::TRUE: case NodeType::FALSE: case NodeType::NONE: case NodeType::UNDEFINED:
            case NodeType::PASS: case NodeType::BREAK: case NodeType::CONTINUE: case NodeType::GLOBAL:
            case NodeType::SELF: case NodeType::SUPER: case NodeType::BYTES:
                return false;
            default: break;
        }
        Node* n = node.get();
        auto any = [&](std::initializer_list<node_ptr> xs) { for (auto& x : xs) if (hasYield(x)) return true; return false; };
        auto anyv = [&](const std::vector<node_ptr>& xs) { for (auto& x : xs) if (hasYield(x)) return true; return false; };
        if (auto* ifn = dynamic_cast<IfNode*>(n))
            return any({ifn->condition, ifn->then_branch, ifn->else_branch}) || anyv(ifn->elseif_branches);
        if (auto* wn = dynamic_cast<WhileNode*>(n)) return any({wn->condition, wn->body, wn->else_branch});
        if (auto* forn = dynamic_cast<ForNode*>(n)) return any({forn->iterable, forn->body, forn->else_branch});
        if (auto* tryn = dynamic_cast<TryNode*>(n))
            return any({tryn->body, tryn->else_clause, tryn->finally_clause}) || anyv(tryn->except_clauses);
        if (auto* en = dynamic_cast<ExceptNode*>(n)) return hasYield(en->body);
        if (auto* wn = dynamic_cast<WithNode*>(n)) return any({wn->expr, wn->body});
        if (auto* sw = dynamic_cast<SwitchNode*>(n)) return any({sw->subject, sw->default_case}) || anyv(sw->cases);
        if (auto* cs = dynamic_cast<CaseNode*>(n)) return any({cs->value_node, cs->body});
        if (auto* dn = dynamic_cast<DefaultNode*>(n)) return hasYield(dn->body);
        if (auto* rn = dynamic_cast<ReturnNode*>(n)) return hasYield(rn->expr);
        if (auto* vd = dynamic_cast<VarDeclNode*>(n)) return hasYield(vd->init);
        if (auto* an = dynamic_cast<AssignmentNode*>(n)) return any({an->target, an->value_node});
        if (auto* an = dynamic_cast<AugAssignNode*>(n)) return any({an->target, an->value_node});
        if (auto* wl = dynamic_cast<WalrusNode*>(n)) return hasYield(wl->init);
        if (auto* un = dynamic_cast<UnaryNode*>(n)) return hasYield(un->operand);
        if (auto* bn = dynamic_cast<BinaryNode*>(n)) return any({bn->left, bn->right});
        if (auto* cn = dynamic_cast<CallNode*>(n)) return hasYield(cn->callee) || anyv(cn->args);
        if (auto* kn = dynamic_cast<KeywordArgNode*>(n)) return hasYield(kn->val);
        if (auto* at = dynamic_cast<AttributeNode*>(n)) return hasYield(at->object);
        if (auto* sb = dynamic_cast<SubscriptNode*>(n)) return any({sb->object, sb->index});
        if (auto* me = dynamic_cast<MapEntryNode*>(n)) return any({me->key, me->val});
        if (auto* pn = dynamic_cast<PrintNode*>(n)) return anyv(pn->args);
        if (auto* rn = dynamic_cast<RaiseNode*>(n)) return any({rn->expr, rn->cause});
        if (auto* as = dynamic_cast<AssertNode*>(n)) return any({as->condition, as->message});
        // Blocks, statement lists, list/tuple/map literals.
        return anyv(n->statements());
    }

    // The scope a function's body resolves names in after its own: where it
    // was defined, except that a class body is skipped (Python's rule: a
    // method does not see the class's names). invokeMember always did this;
    // the other call paths (a bound method called as a value, getattr(o, m)(),
    // a function held in an attribute) used the class body itself, so a
    // method calling the builtin open() got the class's own open method.
    static Context* scopeOf(Context* c) {
        return (c && c->inClass && c->parent) ? c->parent : c;
    }

    // Wrap a plain function Value into a method bound to `self_val`.
    // Returns fn_val unchanged if it is not a user-defined function/lambda.
    Value makeBoundMethod(Value fn_val, Value self_val) {
        if (fn_val.type != ValueType::USERDATA || !fn_val.value.p) return fn_val;
        if (string_ptrs_.count(fn_val.value.p)) return fn_val;
        auto fit = func_names.find(fn_val.value.p);
        if (fit == func_names.end()) return fn_val;
        const std::string& tag = fit->second;
        // Only bind real methods. Static methods, class methods, properties and
        // builtins must keep their existing calling convention.
        if (tag.find("__func__:") != 0 && tag.find("__lambda__") != 0) return fn_val;
        if (tag.find("__static__") != std::string::npos) return fn_val;
        if (tag.find("__classmethod__") != std::string::npos) return fn_val;
        if (tag.find("__property__") != std::string::npos) return fn_val;
        // The function must actually declare `self` as its first parameter,
        // otherwise it is a plain function stored on the instance and binding
        // would corrupt its arguments instead of fixing them.
        void* ast_ptr = fn_val.value.p;
        auto ast_it = func_ast_nodes.find(fn_val.value.p);
        if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
        Node* raw = (Node*)ast_ptr;
        // a lambda in a class binds as any function does (round 81:
        // `C.m = lambda self: 1; f = o.m; f()` lost the instance)
        const bool is_lambda = raw && raw->type() == NodeType::LAMBDA && tag.rfind("__lambda__", 0) == 0;
        if (!raw || (raw->type() != NodeType::FUNCTION && !is_lambda)) return fn_val;
        auto* fn = is_lambda ? nullptr : static_cast<FunctionNode*>(raw);
        // One written in the class body binds when it takes self (a Nython
        // method without self stays a plain function); one put in the class
        // from elsewhere - a decorator's wrapper(*args) - binds whatever its
        // parameters, as Python binds any function (`f = obj.m; f(x)` lost
        // the instance; a call obj.m(x) already supplied it, invokeMember).
        // (round 78: one written in the class body binds whatever its first
        // parameter is called, as Python - `def m(this, x)`, `def m(s)`;
        // __new__ is a static method)
        if (fn && direct_methods_.count(fn) && fn->name == "__new__") return fn_val;
        // Reuse an existing binding for this exact (method, instance) pair.
        //
        // Without this, every read of `obj.method` as a VALUE allocated a fresh
        // bound method plus four map entries, none of which were ever released.
        // A loop doing `var f = o.m` leaked ~0.5 KB per iteration: 200k
        // iterations reached 109 MB and 2M reached 1023 MB. The earlier check
        // looked up fn_val.value.p in bound_self_, but that map is keyed by the
        // NEW bound pointer, so it could never hit.
        //
        // The binding is a heap object (nyheap::Bound) holding the function
        // and the instance; the cache refers to it without owning it and
        // loses the entry when it is freed.
        auto ck = std::make_pair(fn_val.value.p, self_val.value.p);
        // a number or None as self ((5).__add__, round 78) has no pointer to
        // key the cache by: a binding of its own each time
        bool cacheable = self_val.value.p != nullptr;
        auto cached = cacheable ? bound_cache_.find(ck) : bound_cache_.end();
        if (cached != bound_cache_.end())
            return nyheap::userValue(cached->second, (void*)&cached->second->tag);

        auto* bo = new nyheap::Bound(this, "__bound__:" + (fn ? fn->name : std::string("<lambda>")));
        void* bp = (void*)&bo->tag;
        Value out = nyheap::userValue(bo, bp);
        bo->fn = fn_val;
        bo->self = self_val;
        bo->key_fn = ck.first;
        bo->key_self = ck.second;
        func_names[bp]      = tag;          // keep "__func__:name" so call paths match
        func_ast_nodes[bp]  = ast_ptr;      // same body
        auto cit = closure_contexts.find(fn_val.value.p);
        if (cit != closure_contexts.end()) closure_contexts[bp] = cit->second;   // kept alive by bo->fn
        bound_self_[bp] = bo;
        if (cacheable) bound_cache_[ck] = bo;
        nygc::track(bo);
        return out;
    }

    // A classmethod bound to a class (Cls.cm read as a value): the same
    // nyheap::Bound as a method bound to an instance, its `self` the class,
    // so bindParamsKw supplies `cls`. The binding's tag drops the
    // __classmethod__ mark: the call paths that add `cls` themselves must
    // not add it a second time.
    Value makeBoundClassMethod(Value fn_val, Value cls_val) {
        if (fn_val.type != ValueType::USERDATA || !fn_val.value.p) return fn_val;
        auto fit = func_names.find(fn_val.value.p);
        if (fit == func_names.end()) return fn_val;
        std::string tag = fit->second;
        size_t cm = tag.find("__classmethod__");
        if (cm != std::string::npos) tag.erase(cm, std::string("__classmethod__").size());
        void* ast_ptr = fn_val.value.p;
        auto ast_it = func_ast_nodes.find(fn_val.value.p);
        if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
        Node* raw = (Node*)ast_ptr;
        if (!raw || raw->type() != NodeType::FUNCTION) return fn_val;
        auto* fn = static_cast<FunctionNode*>(raw);
        auto ck = std::make_pair(fn_val.value.p, cls_val.value.p);
        auto cached = bound_cache_.find(ck);
        if (cached != bound_cache_.end())
            return nyheap::userValue(cached->second, (void*)&cached->second->tag);
        auto* bo = new nyheap::Bound(this, "__bound__:" + fn->name);
        void* bp = (void*)&bo->tag;
        Value out = nyheap::userValue(bo, bp);
        bo->fn = fn_val;
        bo->self = cls_val;
        bo->key_fn = ck.first;
        bo->key_self = ck.second;
        func_names[bp]      = tag;
        func_ast_nodes[bp]  = ast_ptr;
        auto cit = closure_contexts.find(fn_val.value.p);
        if (cit != closure_contexts.end()) closure_contexts[bp] = cit->second;
        bound_self_[bp] = bo;
        bound_cache_[ck] = bo;
        nygc::track(bo);
        return out;
    }

    // NOTE: there is deliberately no applyBoundSelf() helper any more.
    // Supplying a bound method's captured instance happens in exactly one
    // place — bindParamsKw() — so no invocation path can forget to do it.

    // `kw`: keyword arguments, when the call has them.
    Value callFunctionValue(Value fn_val, std::vector<Value>& call_args, Context* ctx,
                            const nyrt::OrderedKw<Value>* kw = nullptr) {
        static const nyrt::OrderedKw<Value> no_kw;
        if (fn_val.type != ValueType::USERDATA || !fn_val.value.p) return NONE_VALUE;
        auto fit = func_names.find(fn_val.value.p);
        if (fit == func_names.end()) return NONE_VALUE;
        // A class passed as a callable (map(Point, xs), a factory argument).
        if (fit->second.rfind("__class__:", 0) == 0)
            return instantiateClass(fn_val, call_args, kw ? *kw : no_kw, ctx);
        // A builtin, an instance or a class is not an AST function: treating its
        // pointer as a Node* crashed (thread_create(print), key=len, map(str, xs)).
        if (fit->second.rfind("__builtin__:", 0) == 0) return callBuiltinKw(fit->second.substr(12), call_args, kw, ctx);
        if (fit->second.rfind("__rtype__:", 0) == 0) {
            if (const nyrt::RuntimeType* rt = nyrt::runtime_type(fit->second.substr(10))) return runtimeTypeCall(*rt, call_args, kw, ctx);
            return NONE_VALUE;
        }
        if (fit->second.rfind("__bmethod__:", 0) == 0) { Value r; callBoundMember(fn_val, call_args, kw, ctx, r); return r; }
        if (fit->second.rfind("__instance__:", 0) == 0 || instance_to_class.count(fn_val.value.p)) return callMethod(fn_val, "__call__", call_args, ctx, kw);
        if (fit->second.rfind("__class__:", 0) == 0) return NONE_VALUE;
        // Bound-method `self` is supplied centrally in bindParamsKw via the
        // callee pointer. Lambdas are never bound (makeBoundMethod only binds
        // FUNCTION nodes declaring self), so the lambda path below can use
        // call_args directly.

        void* ast_ptr = fn_val.value.p;
        auto ast_it = func_ast_nodes.find(fn_val.value.p);
        if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
        Node* raw = (Node*)ast_ptr;

        if (raw->type() == NodeType::FUNCTION) {
            auto* fn_node = static_cast<FunctionNode*>(raw);
            Context* closure_parent = ctx;
            auto cit = closure_contexts.find(fn_val.value.p);
            if (cit != closure_contexts.end()) closure_parent = scopeOf(cit->second);
            Context* fn_ctx = new Context(runner, fn_node->name, nullptr, nullptr, closure_parent);
            CtxReaper _reap_fn_ctx2020(this, fn_ctx);
            bindParamsKw(fn_node, call_args, kw ? *kw : no_kw, fn_ctx, ctx, 0, fn_val.value.p);
            return runFunctionBody(fn_node, fn_ctx);
        } else if (raw->type() == NodeType::LAMBDA) {
            auto* lam = static_cast<LambdaNode*>(raw);
            Context* closure_parent = ctx;
            auto cit = closure_contexts.find(fn_val.value.p);
            if (cit != closure_contexts.end()) closure_parent = scopeOf(cit->second);
            Context* fn_ctx = new Context(runner, "<lambda>", nullptr, nullptr, closure_parent);
            CtxReaper _reap_fn_ctx2033(this, fn_ctx);
            bindLambdaParams(lam, call_args, kw ? *kw : no_kw, fn_ctx, closure_parent, fn_val.value.p);
            return runLambdaBody(lam, fn_ctx);
        }
        return NONE_VALUE;
    }

    // `kw_in` carries keyword arguments through to the method body. It used to
    // be absent entirely, so callMethod built an empty map and every keyword
    // argument passed to a method was silently dropped:
    //     c.m(b=20, a=10)  ->  a=none b=none
    // Plain functions were unaffected, which is why this went unnoticed.
    // Members every plain value answers: an operator used as a method name
    // (1.+(2, 3) is 1 + 2 + 3; a comparison chains, 1.<(2, 3) is 1 < 2 < 3)
    // and the object protocol's class_name / type_name / to_string. The VM's
    // primitive_member is the same.
    bool primitiveMember(const Value& obj, const std::string& m, std::vector<Value>& args, Context* ctx, Value& out) {
        if (m.empty()) return false;
        bool plain = obj.type == ValueType::INTEGER || obj.type == ValueType::DOUBLE
                  || obj.type == ValueType::BOOLEAN || obj.type == ValueType::NONE || isStringValue(obj)
                  || isBytesValue(obj);
        if (!plain) { Container* c = contOf(obj); plain = c && seqLen(c) >= 0; }
        if (!plain) return false;
        if (!std::isalnum((unsigned char)m[0]) && m[0] != '_') {
            int opc = binOpCode(m);
            if (opc < OP_ADD || opc > OP_GE) return false;
            if (args.empty()) pyRaise("TypeError", typeNameOf(obj) + "." + m + "() takes at least 1 argument (0 given)");
            if (opc < OP_EQ) {
                Value acc = obj;
                for (auto& a : args) acc = binaryOp(opc, acc, a, ctx);
                out = acc;
                return true;
            }
            Value l = obj;
            for (auto& r : args) {
                if (!isTruthy(binaryOp(opc, l, r, ctx))) { out = Value(false); return true; }
                l = r;
            }
            out = Value(true);
            return true;
        }
        if (m == "class_name" || m == "type_name") { out = makeStringValue(typeNameOf(obj)); return true; }
        if (m == "to_string") { out = makeStringValue(strOf(obj, ctx)); return true; }
        // (255).__format__("x"), "ab".__format__(">4"): format(obj, spec) (round 77)
        if (m == "__format__") {
            if (args.size() != 1 || !isStringValue(args[0]))
                pyRaise("TypeError", typeNameOf(obj) + ".__format__() argument must be str");
            out = makeStringValue(formatValue(obj, getStringValue(args[0]), ctx));
            return true;
        }
        return false;
    }

    // str.encode / bytes.decode / str(b, enc, errors) with a codec or an
    // error handler that only lib/codecs.ny's registry knows (round 80): the
    // prelude's _ny_codec_encode / _ny_codec_decode (fn) run it there.
    Value codecHook(const char* fn, const Value& obj, const std::string& enc, const std::string& err, Context* ctx) {
        Value f = global_ctx->getByName(fn);
        std::vector<Value> a{obj, makeStringValue(enc), makeStringValue(err)};
        return callFunctionValue(f, a, ctx);
    }

    // A method of a bytes / bytearray value (NyBytes.hpp: bytes_method).
    // Keyword arguments are placed where the method takes them.
    Value bytesMethodCall(const Value& obj, nyheap::Bytes* bo, const std::string& m, std::vector<Value>& args_in,
                          const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        std::vector<Value> args = args_in;
        if (!kw.empty()) {
            static const std::unordered_map<std::string, std::vector<const char*>> slots = {
                {"decode", {"encoding", "errors"}}, {"hex", {"sep", "bytes_per_sep"}},
                {"split", {"sep", "maxsplit"}}, {"rsplit", {"sep", "maxsplit"}},
                {"splitlines", {"keepends"}}, {"translate", {"table", "delete"}},
                {"count", {"sub", "start", "end"}}, {"replace", {"old", "new", "count"}}};
            auto it = slots.find(m);
            for (auto& kv : kw) {
                size_t pos = SIZE_MAX;
                if (it != slots.end())
                    for (size_t k = 0; k < it->second.size(); k++) if (kv.first == it->second[k]) pos = k;
                if (pos == SIZE_MAX) pyRaise("TypeError", m + "() got an unexpected keyword argument '" + kv.first + "'");
                if (args.size() <= pos) args.resize(pos + 1, NONE_VALUE);
                args[pos] = kv.second;
            }
        }
        if (m == "slice") {
            // b[a:b:c]: bytes of the same type, by byte
            const std::string& s = bo->s;
            int64_t len = (int64_t)s.size(), st = 0, en = 0, step = 1;
            bool hs = sliceArg(args, 0, st), he = sliceArg(args, 1, en);
            if (args.size() >= 3 && args[2].type != ValueType::NONE) sliceArg(args, 2, step);
            int64_t cnt = nyCall([&] { return nypy::slice_adjust(len, hs, st, he, en, step); });
            std::string out;
            if (step == 1) { if (cnt > 0) out = s.substr((size_t)st, (size_t)cnt); }
            else for (int64_t k = 0, i = st; k < cnt; k++, i += step) out += s[(size_t)i];
            return makeBytesValue(std::move(out), bo->mut);
        }
        if (m == "decode") {
            // round 80: a codec or error handler of lib/codecs.ny's registry
            std::string enc = args.size() >= 1 && isStringValue(args[0]) ? getStringValue(args[0]) : std::string("utf-8");
            std::string err = args.size() >= 2 && isStringValue(args[1]) ? getStringValue(args[1]) : std::string("strict");
            if (nypy::codec_needs_python(enc, err)) return codecHook("_ny_codec_decode", obj, enc, err, ctx);
        }
        if (m == "fromhex") {
            if (args.size() != 1 || !isStringValue(args[0])) pyRaise("TypeError", "fromhex() argument must be str, not " + (args.empty() ? std::string("nothing") : typeNameOf(args[0])));
            std::string h = *(std::string*)args[0].value.p;
            return makeBytesValue(nyCall([&] { return nypy::bytes_fromhex(h); }), bo->mut);
        }
        std::vector<nypy::BArg> ba;
        ba.reserve(args.size());
        for (auto& a : args) ba.push_back(toBArg(a, ctx));
        nypy::BRes r;
        if (nyCall([&] { return nypy::bytes_method(bo->s, bo->mut, m, ba, r); })) return fromBRes(r);
        Value pm;
        if (primitiveMember(obj, m, args, ctx, pm)) return pm;
        pyRaise("AttributeError", "'" + typeNameOf(obj) + "' object has no attribute '" + m + "'");
    }

    // A str method (callMethod's string section, round 81: its own function,
    // which evalCall's builtin-method path calls too): false when no str
    // method has the name. `s` is the string's text.
    bool strMethodCall(const Value& obj, const std::string& s, const std::string& method_name, std::vector<Value>& args,
                       const nyrt::OrderedKw<Value>& kw_args_in, Context* ctx, Value& out) {
        // Every str method has one implementation shared with the VM
        // (NyStr.hpp: nypy::str_method); only format needs values.
        if (method_name == "format") { out = makeStringValue(strFormat(s, args, kw_args_in, ctx)); return true; }
        if (method_name == "encode") {
            // str -> bytes (NyBytes.hpp: str_encode)
            std::string enc = "utf-8", err = "strict";
            if (args.size() >= 1 && args[0].type != ValueType::NONE) enc = strOf(args[0], ctx);
            if (args.size() >= 2 && args[1].type != ValueType::NONE) err = strOf(args[1], ctx);
            auto ki = kw_args_in.find("encoding"); if (ki != kw_args_in.end()) enc = strOf(ki->second, ctx);
            ki = kw_args_in.find("errors"); if (ki != kw_args_in.end()) err = strOf(ki->second, ctx);
            // round 80: a codec or error handler of lib/codecs.ny's registry
            if (nypy::codec_needs_python(enc, err)) { out = codecHook("_ny_codec_encode", obj, enc, err, ctx); return true; }
            out = makeBytesValue(nyCall([&] { return nypy::str_encode(s, enc, err); }));
            return true;
        }
        // round 80: str.translate / str.maketrans (the prelude's:
        // the table is any mapping, read with __getitem__)
        if (method_name == "translate" || method_name == "maketrans") {
            if (!kw_args_in.empty()) pyRaise("TypeError", "str." + method_name + "() takes no keyword arguments");
            std::vector<Value> a;
            if (method_name == "translate") {
                if (args.size() != 1) pyRaise("TypeError", "str.translate() takes exactly one argument (" + std::to_string(args.size()) + " given)");
                a.push_back(obj);
            }
            for (auto& x : args) a.push_back(x);
            out = callFunctionValue(global_ctx->getByName(method_name == "translate" ? "_ny_str_translate" : "_ny_str_maketrans"), a, ctx);
            return true;
        }
        if (method_name == "format_map" && !args.empty()) {
            nyrt::OrderedKw<Value> kw;
            if (Container* mc = contOf(args[0])) for (auto& kv : *mc->container) if (!isInternalKey(kv.first)) kw[nypy::key_payload(kv.first)] = kv.second;
            std::vector<Value> none;
            out = makeStringValue(strFormat(s, none, kw, ctx));
            return true;
        }
        // round 79: keyword arguments go where the method takes them
        // (NyStr.hpp: str_kw_slot); they used to be dropped
        std::vector<Value> kargs;
        const std::vector<Value>* sargs = &args;
        if (!kw_args_in.empty()) {
            kargs = args;
            for (auto& kv : kw_args_in) {
                size_t pos = nyCall([&] { return nypy::str_kw_slot(method_name, kv.first); });
                if (kargs.size() <= pos) kargs.resize(pos + 1, NONE_VALUE);
                kargs[pos] = kv.second;
            }
            sargs = &kargs;
        }
        std::vector<nypy::SArg> sa;
        sa.reserve(sargs->size());
        for (auto& a : *sargs) sa.push_back(toSArg(a, ctx));
        nypy::SRes r;
        if (nyCall([&] { return nypy::str_method(s, method_name, sa, r); })) { out = fromSRes(r); return true; }
        return false;
    }

    // ── A builtin value's own method, called (round 81) ──────────────────
    // s.strip(), d.get(k), xs.append(x): for a str, a plain dict or a list,
    // and a name the method table of its kind has, every step evalCall and
    // callMethod take before they reach that table answers no - no
    // __getattribute__ (checked by the caller), no field, key or callable
    // held under the name (a list holds none but its items; a plain dict's
    // methods win over its keys), no object-protocol or operator member,
    // no attribute read (getAttrValue gives nothing for these without
    // binding), no set, bytes or generator - so the table is asked at once.
    // Names those steps treat specially are never taken (sort's keyword
    // arguments, slice, class_name, type_name, to_string), nor is anything
    // under a profile function (its c_call events) or NY_LENIENT_READS=log
    // (its notes on shadowed keys). The tables answer as before: what they
    // do not take goes the general way, and they take nothing before
    // answering no.
    enum : uint8_t { BM_STR = 1, BM_DICT = 2, BM_LIST = 4, BM_KNOWN = 128 };
    static uint8_t builtinMethodKinds(const std::string& m) {
        uint8_t k = BM_KNOWN;
        if (m.empty() || !std::isalpha((unsigned char)m[0])) return k;
        if (m == "sort" || m == "sorted" || m == "slice" || m == "class_name" || m == "type_name" || m == "to_string") return k;
        // str: strMethodCall answers, or raises, for these (format_map
        // without arguments falls through to str_method: not taken)
        bool str_ok = m == "format" || m == "encode" || m == "translate" || m == "maketrans";
        if (!str_ok && m != "format_map") {
            // str_method's answer depends on the name alone (no name it does
            // not know raises): asked once with nothing
            static const std::vector<nypy::SArg> none;
            nypy::SRes r;
            try { str_ok = nypy::str_method(std::string(), m, none, r); } catch (...) { str_ok = true; }
        }
        if (str_ok) k |= BM_STR;
        // dict: the names dictMethod always takes that also win over a key
        // of the name (nyrt::is_dict_method_name)
        static const char* const dict_names[] = {"keys", "values", "items", "get", "pop", "popitem", "setdefault", "update", "clear", "copy"};
        for (const char* x : dict_names) if (m == x) { k |= BM_DICT; break; }
        // list: listMethod's names (sort aside)
        static const char* const list_names[] = {"index", "indexOf", "count", "pop", "insert", "copy", "reverse", "clear", "extend", "append", "push"};
        for (const char* x : list_names) if (m == x) { k |= BM_LIST; break; }
        return k;
    }
    bool builtinMethodFast(CallNode* cn, const Value& obj, const std::string& m, std::vector<Value>& args,
                           const nyrt::OrderedKw<Value>& kw, Context* ctx, Value& out) {
        if (__builtin_expect(!cn->bm_kinds, 0)) cn->bm_kinds = builtinMethodKinds(m);
        const uint8_t k = cn->bm_kinds;
        if (!(k & (BM_STR | BM_DICT | BM_LIST))) return false;
        if (obj.type == ValueType::USERDATA) {
            if (!(k & BM_STR) || heapKind(obj) != HK_STR) return false;
            return strMethodCall(obj, *static_cast<const std::string*>(obj.value.p), m, args, kw, ctx, out);
        }
        Container* c = contOf(obj);
        if (!c || nygen::is_gen(obj) || nypy::lenient_reads_log()) return false;
        if (seqLen(c) < 0) {
            if (!(k & BM_DICT) || !isPlainDict(c)) return false;
            return dictMethod(c, obj, m, args, kw, ctx, out);
        }
        if (!(k & BM_LIST) || isSetCont(c) || isGenCont(c) || c->container->index_of(m) >= 0) return false;
        return listMethod(c, obj, m, args, kw, ctx, out);
    }

    Value callMethod(Value obj, const std::string& method_name, std::vector<Value>& args, Context* ctx,
                     const nyrt::OrderedKw<Value>* kw_in = nullptr) {
        static const nyrt::OrderedKw<Value> kEmptyKw;
        const nyrt::OrderedKw<Value>& kw_args_in = kw_in ? *kw_in : kEmptyKw;
        // s = super(C, obj); s.m(...) (round 78)
        if (any_super_proxy_ && method_name != "__repr__" && isSuperProxy(obj)) {
            Node* owner = nullptr; Value self;
            superProxyParts(obj, owner, self);
            Node* start = isInstanceValue(self) ? classNodeOfInstance(self) : classNodeOfValue(self);
            Value out;
            if (owner && superCall(self, owner, method_name, args, kw_args_in, ctx, out, start)) return out;
            pyRaise("AttributeError", "'super' object has no attribute '" + method_name + "'");
        }
        if (method_name == "slice" && wantsSliceObject(obj, "__getitem__")) {
            std::vector<Value> a{makeSliceObject(args, ctx)};
            return callMethod(obj, "__getitem__", a, ctx);
        }
        // A generator: send / throw / close / __next__ / __iter__ (NyGen.cpp),
        // then the object protocol; nothing else.
        if (nygen::is_gen(obj)) {
            Value r;
            if (nygen::method(*this, obj, method_name, args, ctx, r)) return r;
            if (primitiveMember(obj, method_name, args, ctx, r)) return r;
            pyRaise("AttributeError", "'generator' object has no attribute '" + method_name + "'");
        }
        if (obj.type == ValueType::INTEGER || obj.type == ValueType::BOOLEAN || obj.type == ValueType::DOUBLE) {
            Value nm;
            if (numberMethod(obj, method_name, args, kw_args_in, ctx, nm)) return nm;
        }
        {
            Value pm;
            if (primitiveMember(obj, method_name, args, ctx, pm)) return pm;
        }
        // (5).__add__(3), [1].__getitem__(0), {}.__contains__(k): the type's
        // dunder (round 78; its __format__ is the kind's own)
        if (method_name.size() > 4 && method_name[0] == '_' && method_name[1] == '_') {
            Value bm;
            if (builtinValueDunder(obj, method_name, bm)) return callFunctionValue(bm, args, ctx, &kw_args_in);
        }
        if (auto* bo = bytesOf(obj)) return bytesMethodCall(obj, bo, method_name, args, kw_args_in, ctx);
        // Built-in string methods
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            std::string s = getStringValue(obj);
            bool is_string = string_ptrs_.count(obj.value.p) || (!func_names.count(obj.value.p) && !instance_to_class.count(obj.value.p));
            if (is_string) {
                Value sr;
                if (strMethodCall(obj, s, method_name, args, kw_args_in, ctx, sr)) return sr;   // (round 81: its own function)
            }
        }

        // set / frozenset methods (round 77)
        if (Container* sc = setOf(obj)) {
            Value r;
            if (setMethod(sc, obj, method_name, args, ctx, r)) return r;
        }
        // dict methods first: the list block below also has pop/remove/clear.
        if (Container* dc = contOf(obj); dc && seqLen(dc) < 0) {
            if (nypy::lenient_reads_log() && nyrt::is_dict_method_name(method_name) && isPlainDict(dc)) noteShadowedKey(dc, method_name);
            Value r;
            if (dictMethod(dc, obj, method_name, args, kw_args_in, ctx, r)) return r;
        }
        // Python list (and tuple) methods; the older block below keeps the
        // Nython extras (map/filter/forEach/reduce/join/...).
        if (Container* lc = contOf(obj); lc && seqLen(lc) >= 0 && !isSetCont(lc) && !isGenCont(lc)) {
            Value r;
            if (listMethod(lc, obj, method_name, args, kw_args_in, ctx, r)) return r;
        }
        // list.remove(x): the first element equal to x (ValueError if none)
        if (Container* lc = contOf(obj); lc && method_name == "remove" && seqLen(lc) >= 0 && !isSetCont(lc) && !isTupleCont(lc)) {
            if (args.size() != 1) pyRaise("TypeError", "list.remove() takes exactly one argument (" + std::to_string(args.size()) + " given)");
            std::vector<Value> items = seqItems(lc);
            for (size_t i = 0; i < items.size(); i++) {
                if (valuesEqual(items[i], args[0], 0)) {
                    for (size_t k = i; k + 1 < items.size(); k++) (*lc->container)[std::to_string(k)] = items[k + 1];
                    lc->container->erase(std::to_string(items.size() - 1));
                    (*lc->container)["__len__"] = intValue((int64_t)items.size() - 1);
                    return NONE_VALUE;
                }
            }
            pyRaise("ValueError", "list.remove(x): x not in list");
        }
        // Built-in list methods
        if (obj.isCollectable() && obj.value.gc) {
            auto* cont = dynamic_cast<Container*>(obj.value.gc);
            if (cont && cont->container) {
                if (method_name == "append" || method_name == "push") {
                    if (!args.empty()) {
                        int len = cont->size();
                        auto len_it = cont->container->find("__len__");
                        if (len_it != cont->container->end()) len = (int)bigint_to_i64(len_it->second.value.i);
                        (*cont->container)[std::to_string(len)] = args[0];
                        (*cont->container)["__len__"] = Value((int)(len + 1));
                    }
                    return NONE_VALUE;
                }
                // set.add(): append only if not already present
                if (method_name == "add") {
                    if (!args.empty()) {
                        auto len_it = cont->container->find("__len__");
                        int len = len_it != cont->container->end() ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        // Check for duplicate
                        std::string new_str = getStringValue(args[0]);
                        bool found = false;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                if (getStringValue(it->second) == new_str &&
                                    it->second.type == args[0].type) { found = true; break; }
                            }
                        }
                        if (!found) {
                            (*cont->container)[std::to_string(len)] = args[0];
                            (*cont->container)["__len__"] = Value((int)(len + 1));
                        }
                    }
                    return NONE_VALUE;
                }
                if ((method_name == "discard" || method_name == "remove")
                    && cont->container->count("__set__")) {
                    // SET semantics only. This branch used to be ungated, so it
                    // also swallowed map.remove() and list.remove(), applying
                    // set-element scanning to them and throwing "<x> not in set"
                    // (which aborted the interpreter) for a perfectly valid
                    // dict key removal.
                    if (!args.empty()) {
                        auto len_it = cont->container->find("__len__");
                        int len = len_it != cont->container->end() ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        std::string target_key = setKey(args[0]);
                        int found_idx = -1;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end() && setKey(it->second) == target_key) {
                                found_idx = i; break;
                            }
                        }
                        if (found_idx >= 0) {
                            // Shift elements down
                            for (int i = found_idx; i < len - 1; i++)
                                (*cont->container)[std::to_string(i)] = (*cont->container)[std::to_string(i+1)];
                            cont->container->erase(std::to_string(len-1));
                            (*cont->container)["__len__"] = Value((int)(len - 1));
                        } else if (method_name == "remove") {
                            throw std::string(getStringValue(args[0]) + " not in set");
                        }
                    }
                    return NONE_VALUE;
                }
                if (method_name == "pop") {
                    // Dict-style pop with key argument:
                    if (!args.empty() && args[0].type != ValueType::INTEGER) {
                        std::string key = getStringValue(args[0]);
                        auto it = cont->container->find(key);
                        if (it != cont->container->end()) {
                            Value val = it->second;
                            cont->container->erase(key);
                            return val;
                        }
                        if (args.size() >= 2) return args[1];
                        return NONE_VALUE;
                    }
                    // List-style pop (remove and return last element):
                    auto len_it = cont->container->find("__len__");
                    if (len_it != cont->container->end()) {
                        int len = static_cast<int>(bigint_to_i64(len_it->second.value.i));
                        if (len > 0) {
                            // Pop by index if provided, otherwise last
                            int idx = len - 1;
                            if (!args.empty() && args[0].type == ValueType::INTEGER)
                                idx = static_cast<int>(bigint_to_i64(args[0].value.i));
                            if (idx < 0) idx += len;   // pop(-1), pop(-2): from the end
                            auto it = cont->container->find(std::to_string(idx));
                            if (it != cont->container->end()) {
                                Value val = it->second;
                                // Shift elements left if not last
                                for (int i = idx; i < len - 1; i++) {
                                    auto next = cont->container->find(std::to_string(i + 1));
                                    if (next != cont->container->end())
                                        (*cont->container)[std::to_string(i)] = next->second;
                                }
                                cont->container->erase(std::to_string(len - 1));
                                (*cont->container)["__len__"] = Value(len - 1);
                                return val;
                            }
                        }
                    }
                    return NONE_VALUE;
                }
                if (method_name == "contains" || method_name == "includes"
                    || method_name == "has" || method_name == "__contains__") {
                    // Previously unimplemented for lists, so [1,2,3].contains(2)
                    // silently returned none — which made `assert list.contains(x)`
                    // fail even when the element was present.
                    if (args.empty()) return Value(false);
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                    for (int i = 0; i < len; i++) {
                        auto it = cont->container->find(std::to_string(i));
                        if (it == cont->container->end()) continue;
                        if (it->second == args[0]) return Value(true);
                        // Fall back to string comparison so 2 == "2" style
                        // cross-type lookups behave like the rest of Nython.
                        if (isStringValue(it->second) || isStringValue(args[0])) {
                            if (getStringValue(it->second) == getStringValue(args[0])) return Value(true);
                        }
                    }
                    return Value(false);
                }
                if (method_name == "indexOf" || method_name == "index") {
                    if (!args.empty()) {
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end() && it->second == args[0]) return Value(i);
                        }
                    }
                    return Value(-1);
                }
                if (method_name == "join") {
                    std::string sep = args.empty() ? ", " : getStringValue(args[0]);
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                    std::string result;
                    for (int i = 0; i < len; i++) {
                        if (i > 0) result += sep;
                        auto it = cont->container->find(std::to_string(i));
                        if (it != cont->container->end()) result += getStringValue(it->second);
                    }
                    return makeStringValue(result);
                }
                if (method_name == "forEach" || method_name == "each") {
                    if (!args.empty() && args[0].type == ValueType::USERDATA) {
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                std::vector<Value> ca = {it->second};
                                callFunctionValue(args[0], ca, ctx);
                            }
                        }
                    }
                    return NONE_VALUE;
                }
                if (method_name == "reduce") {
                    if (args.size() >= 2 && args[0].type == ValueType::USERDATA) {
                        Value accumulator = args[1];
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                std::vector<Value> ca = {accumulator, it->second};
                                accumulator = callFunctionValue(args[0], ca, ctx);
                            }
                        }
                        return accumulator;
                    }
                    return NONE_VALUE;
                }
                if (method_name == "slice" && seqLen(cont) >= 0) {
                    // L[a:b:c] (the parser emits L.slice(a, b, c), none for an
                    // omitted bound), Python's slice semantics; a tuple slice
                    // is a tuple.
                    int64_t len = seqLen(cont), st = 0, en = 0, step = 1;
                    bool hs = sliceArg(args, 0, st), he = sliceArg(args, 1, en);
                    if (args.size() >= 3 && args[2].type != ValueType::NONE) sliceArg(args, 2, step);
                    int64_t cnt = nyCall([&] { return nypy::slice_adjust(len, hs, st, he, en, step); });
                    std::vector<Value> out;
                    out.reserve((size_t)std::max<int64_t>(cnt, 0));
                    for (int64_t k = 0, i = st; k < cnt; k++, i += step) {
                        auto it = cont->container->find(std::to_string(i));
                        out.push_back(it != cont->container->end() ? it->second : NONE_VALUE);
                    }
                    return makeListValue(out, isTupleCont(cont));
                }
                if (method_name == "sort" || method_name == "sorted") {
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                    // Check for key= and reverse= args
                    // Convention: args[0] = key func (optional), last bool arg = reverse
                    Value key_func; bool reverse = false;
                    for (auto& a : args) {
                        if (a.type == ValueType::BOOLEAN) reverse = a.value.b;
                        else if (a.type == ValueType::USERDATA && a.value.p && func_names.count(a.value.p)) key_func = a;
                    }
                    // Extract values
                    std::vector<Value> vals;
                    for (int i = 0; i < len; i++) {
                        auto it = cont->container->find(std::to_string(i));
                        if (it != cont->container->end()) vals.push_back(it->second);
                    }
                    // Sort with optional key function
                    auto get_sort_key = [&](const Value& v) -> Value {
                        if (key_func.type != ValueType::NONE && key_func.type != ValueType::UNDEFINED &&
                            key_func.value.p != nullptr) {
                            std::vector<Value> ka = {v};
                            return callFunctionValue(key_func, ka, ctx);
                        }
                        return v;
                    };
                    std::stable_sort(vals.begin(), vals.end(), [&](const Value& a, const Value& b) {
                        Value ka = get_sort_key(a), kb = get_sort_key(b);
                        bool less;
                        if (ka.type == ValueType::INTEGER && kb.type == ValueType::INTEGER)
                            less = bigint_to_i64(ka.value.i) < bigint_to_i64(kb.value.i);
                        else if (ka.type == ValueType::DOUBLE || kb.type == ValueType::DOUBLE) {
                            double da = ka.type == ValueType::DOUBLE ? (double)ka.value.d : (double)bigint_to_i64(ka.value.i);
                            double db = kb.type == ValueType::DOUBLE ? (double)kb.value.d : (double)bigint_to_i64(kb.value.i);
                            less = da < db;
                        } else if (isStringValue(ka) || isStringValue(kb)) {
                            less = getStringValue(ka) < getStringValue(kb);
                        } else less = ka.toString() < kb.toString();
                        return reverse ? !less : less;
                    });
                    // Write back (in-place modification)
                    for (int i = 0; i < len; i++) {
                        (*cont->container)[std::to_string(i)] = vals[static_cast<size_t>(i)];
                    }
                    return obj; // return self for chaining
                }

                if (method_name == "reverse" || method_name == "reversed") {
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                    for (int i = 0; i < len / 2; i++) {
                        int j = len - 1 - i;
                        auto a = cont->container->find(std::to_string(i));
                        auto b = cont->container->find(std::to_string(j));
                        if (a != cont->container->end() && b != cont->container->end()) {
                            Value tmp = a->second;
                            a->second = b->second;
                            b->second = tmp;
                        }
                    }
                    return obj;
                }

                if (method_name == "map") {
                    if (!args.empty() && args[0].type == ValueType::USERDATA) {
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                std::vector<Value> ca = {it->second};
                                result->set(std::to_string(i), callFunctionValue(args[0], ca, ctx));
                            }
                        }
                        result->set("__len__", Value((int)len));
                        return Value((Collectable*)result);
                    }
                    return obj;
                }
                if (method_name == "filter") {
                    if (!args.empty() && args[0].type == ValueType::USERDATA) {
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                        Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                        int out_idx = 0;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end()) {
                                std::vector<Value> ca = {it->second};
                                Value rv = callFunctionValue(args[0], ca, ctx);
                                if (rv.isTrue()) result->set(std::to_string(out_idx++), it->second);
                            }
                        }
                        result->set("__len__", Value((int)out_idx));
                        return Value((Collectable*)result);
                    }
                    return obj;
                }
                if (method_name == "extend") {
                    if (!args.empty() && args[0].isCollectable()) {
                        auto* src = dynamic_cast<Container*>(args[0].value.gc);
                        if (src && src->container) {
                            auto len_it = cont->container->find("__len__");
                            int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                            auto src_len_it = src->container->find("__len__");
                            int src_len = (src_len_it != src->container->end()) ? static_cast<int>(bigint_to_i64(src_len_it->second.value.i)) : 0;
                            for (int i = 0; i < src_len; i++) {
                                auto it = src->container->find(std::to_string(i));
                                if (it != src->container->end())
                                    (*cont->container)[std::to_string(len + i)] = it->second;
                            }
                            (*cont->container)["__len__"] = Value(len + src_len);
                        }
                    }
                    return NONE_VALUE;
                }
                if (method_name == "count") {
                    // List count: count occurrences of a value
                    if (!args.empty()) {
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                        int count = 0;
                        std::string target = args[0].toString();
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end() && it->second.toString() == target) count++;
                        }
                        return Value(count);
                    }
                    return Value(0);
                }
                if (method_name == "insert") {
                    if (args.size() >= 2) {
                        int idx = static_cast<int>(bigint_to_i64(args[0].value.i));
                        auto len_it = cont->container->find("__len__");
                        int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                        // Negative counts from the end and out of range clamps,
                        // as on the VM (and in Python); insert(-1, x) used to
                        // write key "-1" and grow the list by a phantom slot.
                        if (idx < 0) idx += len;
                        if (idx < 0) idx = 0;
                        if (idx > len) idx = len;
                        // Shift elements right
                        for (int i = len; i > idx; i--) {
                            auto it = cont->container->find(std::to_string(i - 1));
                            if (it != cont->container->end())
                                (*cont->container)[std::to_string(i)] = it->second;
                        }
                        (*cont->container)[std::to_string(idx)] = args[1];
                        (*cont->container)["__len__"] = Value(len + 1);
                    }
                    return NONE_VALUE;
                }
                if (method_name == "copy") {
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                    Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                    for (int i = 0; i < len; i++) {
                        auto it = cont->container->find(std::to_string(i));
                        if (it != cont->container->end())
                            result->set(std::to_string(i), it->second);
                    }
                    result->set("__len__", Value(len));
                    return Value((Collectable*)result);
                }
                if (method_name == "clear") {
                    // A list stays a list (and a set a set); a map stays a map.
                    // Writing __len__ unconditionally turned a cleared map into
                    // an empty list, after which m[k] = v was silently lost.
                    bool is_list = cont->container->count("__len__") > 0;
                    std::vector<std::pair<std::string, Value>> keep;
                    for (auto& kv : *cont->container) {
                        const std::string& k = kv.first;
                        if (k != "__len__" && k.size() > 4 && k.rfind("__", 0) == 0
                            && k.compare(k.size() - 2, 2, "__") == 0)
                            keep.push_back(kv);
                    }
                    cont->container->clear();
                    for (auto& kv : keep) (*cont->container)[kv.first] = kv.second;
                    if (is_list) (*cont->container)["__len__"] = Value(0);
                    return NONE_VALUE;
                }
                if (method_name == "min" || method_name == "max" || method_name == "sum") {
                    auto len_it = cont->container->find("__len__");
                    int len = (len_it != cont->container->end()) ? static_cast<int>(bigint_to_i64(len_it->second.value.i)) : 0;
                    if (len == 0) return NONE_VALUE;
                    if (method_name == "sum") {
                        double total = 0.0;
                        bool all_int = true;
                        int64_t itotal = 0;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it == cont->container->end()) continue;
                            if (it->second.type == ValueType::DOUBLE) {
                                all_int = false;
                                total += static_cast<double>(it->second.value.d);
                            } else {
                                int64_t v = bigint_to_i64(it->second.value.i);
                                total += static_cast<double>(v);
                                itotal += v;
                            }
                        }
                        return all_int ? Value(static_cast<int>(itotal)) : Value(total);
                    }
                    // min or max
                    Value best = NONE_VALUE;
                    double best_num = 0;
                    bool first = true;
                    for (int i = 0; i < len; i++) {
                        auto it = cont->container->find(std::to_string(i));
                        if (it == cont->container->end()) continue;
                        double num = (it->second.type == ValueType::DOUBLE) ? static_cast<double>(it->second.value.d)
                                     : static_cast<double>(bigint_to_i64(it->second.value.i));
                        if (first || (method_name == "min" ? num < best_num : num > best_num)) {
                            best = it->second;
                            best_num = num;
                            first = false;
                        }
                    }
                    return best;
                }

            }
        }

        // Built-in dict methods (keys are typed: dictKey/keyValue)
        if (Container* cont = contOf(obj)) {
            Value r;
            if (dictMethod(cont, obj, method_name, args, kw_args_in, ctx, r)) return r;
        }

        // Find the class this instance belongs to
        void* class_ptr = nullptr;
        auto cit = instance_to_class.find(obj.value.p);
        if (cit != instance_to_class.end()) class_ptr = cit->second;
        // If obj IS a class itself (static method call), use it directly
        if (!class_ptr) {
            auto fn_it = func_names.find(obj.value.p);
            if (fn_it != func_names.end() && fn_it->second.find("__class__:") == 0) {
                class_ptr = obj.value.p;
            }
        }

        // Find the class node from func_ast_nodes or direct pointer
        Node* class_node = nullptr;
        if (class_ptr) {
            // class_ptr might be a unique function ID or direct node ptr
            auto ast_it = func_ast_nodes.find(class_ptr);
            if (ast_it != func_ast_nodes.end()) class_node = (Node*)ast_it->second;
            else class_node = (Node*)class_ptr;
        }


        // Methods through the class namespaces and the C3 MRO.
        if (class_node && class_node->type() == NodeType::CLASS) {
            Value out;
            if (callClassMethod(obj, method_name, args, kw_args_in, ctx, out)) return out;
        }

        if (class_node && fnTag(func_names, class_ptr).rfind("__class__:", 0) == 0 && class_node->type() == NodeType::CLASS) {
            auto* cn = static_cast<ClassNode*>(class_node);

            // Check class_ctx_map_ first — this respects @staticmethod/@property/@classmethod decorators
            auto class_ctx_it = class_ctx_map_.find((void*)class_node);
            if (class_ctx_it != class_ctx_map_.end()) {
                Context* ccx = class_ctx_it->second;
                // The class's own namespace only: getByName went on into the
                // enclosing scopes, so a global of the method's name (the
                // builtin hash for obj.hash()) was taken for a method.
                Value method_val;
                if (ccx && ccx->container) {
                    auto own = ccx->container->find(method_name);
                    if (own != ccx->container->end()) method_val = own->second;
                }
                if (method_val.type == ValueType::USERDATA && method_val.value.p) {
                    void* ast_ptr = method_val.value.p;
                    auto ast_it2 = func_ast_nodes.find(method_val.value.p);
                    if (ast_it2 != func_ast_nodes.end()) ast_ptr = ast_it2->second;
                    // only a function's pointer is an AST node (round 80: a
                    // string or a builtin's bound member was read as one)
                    Node* raw = func_names.count(method_val.value.p) && !string_ptrs_.count(method_val.value.p)
                                && !bound_members_.count(method_val.value.p) ? (Node*)ast_ptr : nullptr;
                    std::string fn_tag = func_names.count(method_val.value.p) ? func_names[method_val.value.p] : "";
                    bool is_static = fn_tag.find("__static__") != std::string::npos;
                    bool is_classmethod = fn_tag.find("__classmethod__") != std::string::npos;
                    bool is_property = fn_tag.find("__property__") != std::string::npos;
                    // If the method is a decorated closure (not directly a FunctionNode),
                    // call it via callFunctionValue with self prepended to args
                    if (!raw || raw->type() != NodeType::FUNCTION) {
                        std::vector<Value> with_self;
                        with_self.push_back(obj);
                        for (auto& a : args) with_self.push_back(a);
                        return callFunctionValue(method_val, with_self, ctx);
                    }
                    if (raw && raw->type() == NodeType::FUNCTION) {
                        auto fn = static_cast<FunctionNode*>(raw);
                        Context* cp = ctx;
                        auto cit = closure_contexts.find(method_val.value.p);
                        if (cit != closure_contexts.end()) cp = scopeOf(cit->second);
                        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                        CtxReaper _reap_fc3025(this, fc);
                        if (is_classmethod) {
                            // For @classmethod: bind cls = the class value (not instance)
                            // Look up the class value by name
                            Value cls_val;
                            for (auto& [cn2, cv2] : class_by_name) {
                                if (cv2 == class_ptr || cv2 == class_node) {
                                    try { cls_val = ctx->getByName(cn2); } catch (...) {}
                                    break;
                                }
                            }
                            if (cls_val.type == ValueType::UNDEFINED) cls_val = obj;
                            // Bind "cls" param (first param, skip it for arg binding)
                            size_t ps = (!fn->params.empty()) ? 1 : 0;
                            if (!fn->params.empty()) fc->defineByName(fn->params[0]->value(), cls_val);
                            for (size_t i = ps; i < fn->params.size(); i++) {
                                size_t ai = i - ps;
                                if (ai < args.size()) fc->defineByName(fn->params[i]->value(), args[ai]);
                                else fc->defineByName(fn->params[i]->value(), NONE_VALUE);
                            }
                        } else if (!is_static) {
                            bool has_self_param = (!fn->params.empty() && 
                                (fn->params[0]->value() == "self" || fn->params[0]->value() == "this"));
                            if (has_self_param) {
                                // Check if obj is a class (unbound method call like ClassName.method(instance, ...))
                                // vs an instance (bound method call like instance.method(...))
                                bool obj_is_class = false;
                                {
                                    auto fn_it2 = func_names.find(obj.value.p);
                                    if (fn_it2 != func_names.end() && fn_it2->second.find("__class__:") == 0)
                                        obj_is_class = true;
                                }
                                if (obj_is_class && !args.empty()) {
                                    // Unbound call: args[0] is self, rest are regular args
                                    fc->defineByName("self", args[0]);
                                    std::vector<Value> shifted(args.begin() + 1, args.end());
                                    bindParamsKw(fn, shifted, kw_args_in, fc, ctx, 1);
                                } else {
                                    fc->defineByName("self", obj);
                                    // Use bindParamsKw for *args support, skipping self
                                    std::vector<Value> shifted = args;
                                    bindParamsKw(fn, shifted, kw_args_in, fc, ctx, 1);
                                }
                            } else {
                                // First param is not `self`. That normally means a
                                // decorated wrapper (inner(*args)), which wants obj
                                // prepended. But when obj is the *class* rather than
                                // an instance, this is a static-style call —
                                // ClassName.method(x) — and prepending the class
                                // shifted every real argument one place right, so
                                // the first parameter received the class object.
                                bool obj_is_class_sm = false;
                                {
                                    auto fn_it_sm = func_names.find(obj.value.p);
                                    if (fn_it_sm != func_names.end() && fn_it_sm->second.find("__class__:") == 0)
                                        obj_is_class_sm = true;
                                }
                                if (obj_is_class_sm) {
                                    bindParamsKw(fn, args, kw_args_in, fc, ctx);
                                } else {
                                    std::vector<Value> with_self;
                                    with_self.push_back(obj);
                                    for (auto& a : args) with_self.push_back(a);
                                    bindParamsKw(fn, with_self, kw_args_in, fc, ctx);
                                    fc->defineByName("self", obj); // also bind self in case needed
                                }
                            }
                        } else {
                            size_t ps = 0;
                            for (size_t i = ps; i < fn->params.size(); i++) {
                                size_t ai = i - ps;
                                if (ai < args.size()) fc->defineByName(fn->params[i]->value(), args[ai]);
                                else if (i < fn->defaults.size() && fn->defaults[i])
                                    fc->defineByName(fn->params[i]->value(), paramDefault(fn, i, ctx));
                                else fc->defineByName(fn->params[i]->value(), NONE_VALUE);
                            }
                        }
                        // Set __parent_class__ so super() works in this method
                        if (cn->bases.size() > 0)
                            fc->defineByName("__parent_class__", internString(cn->bases[0]->value()));
                        return runFunctionBody(fn, fc);
                    }
                }
            }

            // Search class body for the method (fallback for non-decorated methods)
            // - not one `del C.m` removed (round 81: it was still called)
            if (cn->body && !memberDeleted(cn, method_name)) {
                for (auto& stmt : cn->body->statements()) {
                    if (stmt->type() == NodeType::FUNCTION) {
                        auto* fn = static_cast<FunctionNode*>(stmt.get());
                        if (fn->name == method_name) {
                            // Create method context with self bound
                            Context* fn_ctx = new Context(runner, method_name, nullptr, nullptr, ctx);
                            CtxReaper _reap_fn_ctx3103(this, fn_ctx);
                            // Check if obj is a class (unbound call) or instance (bound call)
                            bool obj_is_class2 = false;
                            {
                                auto fn_it3 = func_names.find(obj.value.p);
                                if (fn_it3 != func_names.end() && fn_it3->second.find("__class__:") == 0)
                                    obj_is_class2 = true;
                            }
                            if (obj_is_class2 && !args.empty()) {
                                fn_ctx->defineByName("self", args[0]);
                            } else {
                                fn_ctx->defineByName("self", obj);
                            }
                            // Set __parent_class__ so super() works
                            if (cn->bases.size() > 0)
                                fn_ctx->defineByName("__parent_class__", internString(cn->bases[0]->value()));
                            // Bind params (skip first "self" param)
                            size_t param_start = 0;
                            if (!fn->params.empty() && fn->params[0]->value() == "self") param_start = 1;
                            // Only skip args[0] as the explicit self when the method
                            // actually declares one; otherwise a static-style call
                            // lost its first argument entirely.
                            size_t arg_offset = (obj_is_class2 && !args.empty() && param_start == 1) ? 1 : 0;
                            for (size_t i = param_start; i < fn->params.size(); i++) {
                                size_t arg_idx = i - param_start + arg_offset;
                                if (arg_idx < args.size())
                                    fn_ctx->defineByName(fn->params[i]->value(), args[arg_idx]);
                            }
                            return runFunctionBody(fn, fn_ctx);
                        }
                    }
                }
            }
        }

        // Check ALL parent classes (multiple inheritance via MRO)
        if (class_node && fnTag(func_names, class_ptr).rfind("__class__:", 0) == 0 && class_node->type() == NodeType::CLASS) {
            auto* cn_check = static_cast<ClassNode*>(class_node);
            for (auto& base_node : cn_check->bases) {
                std::string parent_name = base_node->value();
                Node* parent_node = classNodeByName(parent_name);
                if (!parent_node) continue;
                auto* pcn = static_cast<ClassNode*>(parent_node);
                if (!pcn->body || memberDeleted(pcn, method_name)) continue;   // del Base.m (round 81)
                for (auto& stmt : pcn->body->statements()) {
                    if (stmt->type() != NodeType::FUNCTION) continue;
                    auto* fn = static_cast<FunctionNode*>(stmt.get());
                    if (fn->name != method_name) continue;
                    Context* fn_ctx = new Context(runner, method_name, nullptr, nullptr, ctx);
                    CtxReaper _reap_fn_ctx3162(this, fn_ctx);
                    fn_ctx->defineByName("self", obj);
                    size_t param_start = (!fn->params.empty() && fn->params[0]->value() == "self") ? 1 : 0;
                    // Defaults and keyword arguments too: binding only the supplied
                    // arguments left a missing parameter undefined, so an
                    // inherited `def m(self, x=5)` saw x as "" (round 74).
                    bindParamsKw(fn, args, kw_args_in, fn_ctx, ctx, param_start);
                    return runFunctionBody(fn, fn_ctx);
                }
            }
        }

        // Try parent class methods (inheritance) - walk full chain
        {
            void* search_class = class_ptr;
            for (int depth = 0; depth < 10; depth++) { // max 10 levels
                auto parent_it = class_parent.find(search_class);
                if (parent_it == class_parent.end()) break;
                auto parent_class_it = class_by_name.find(parent_it->second);
                if (parent_class_it == class_by_name.end()) break;
                Node* parent_node = (Node*)parent_class_it->second;
                if (parent_node->type() == NodeType::CLASS) {
                    auto* pcn = static_cast<ClassNode*>(parent_node);
                    if (pcn->body && !memberDeleted(pcn, method_name)) {
                        for (auto& stmt : pcn->body->statements()) {
                            if (stmt->type() == NodeType::FUNCTION) {
                                auto* fn = static_cast<FunctionNode*>(stmt.get());
                                if (fn->name == method_name) {
                                    Context* fn_ctx = new Context(runner, method_name, nullptr, nullptr, ctx);
                                    CtxReaper _reap_fn_ctx3192(this, fn_ctx);
                                    fn_ctx->defineByName("self", obj);
                                    size_t param_start = 0;
                                    if (!fn->params.empty() && fn->params[0]->value() == "self") param_start = 1;
                                    bindParamsKw(fn, args, kw_args_in, fn_ctx, ctx, param_start);   // defaults too (round 74)
                                    return runFunctionBody(fn, fn_ctx);
                                }
                            }
                        }
                    }
                }
                search_class = parent_class_it->second; // climb to next parent
            }
        }

         // Try parent class methods (inheritance)
        if (class_node && fnTag(func_names, class_ptr).rfind("__class__:", 0) == 0 && class_node->type() == NodeType::CLASS) {
            auto parent_it = class_parent.find(class_ptr);
            if (parent_it != class_parent.end()) {
                auto parent_class_it = class_by_name.find(parent_it->second);
                if (parent_class_it != class_by_name.end()) {
                    Node* parent_node = (Node*)parent_class_it->second;
                    if (parent_node->type() == NodeType::CLASS) {
                        auto* pcn = static_cast<ClassNode*>(parent_node);
                        if (pcn->body && !memberDeleted(pcn, method_name)) {
                            for (auto& stmt : pcn->body->statements()) {
                                if (stmt->type() == NodeType::FUNCTION) {
                                    auto* fn = static_cast<FunctionNode*>(stmt.get());
                                    if (fn->name == method_name) {
                                        Context* fn_ctx = new Context(runner, method_name, nullptr, nullptr, ctx);
                                        CtxReaper _reap_fn_ctx3226(this, fn_ctx);
                                        fn_ctx->defineByName("self", obj);
                                        size_t param_start = 0;
                                        if (!fn->params.empty() && fn->params[0]->value() == "self") param_start = 1;
                                        bindParamsKw(fn, args, kw_args_in, fn_ctx, ctx, param_start);   // defaults too (round 74)
                                        return runFunctionBody(fn, fn_ctx);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // round 80: object's members (objectMember) through an instance or a
        // class: p.__setattr__(k, v), Base.__init__(self), P.__eq__(a, b)
        if (objectFallbackName(method_name) && obj.type == ValueType::USERDATA && obj.value.p
            && (isInstanceValue(obj) || fnTag(func_names, obj.value.p).rfind("__class__:", 0) == 0)) {
            Value m; Node* where = nullptr;
            Node* rcls = isInstanceValue(obj) ? classNodeOfInstance(obj) : classNodeOfValue(obj);
            if (objectMember(method_name, m, &where, rcls)) {
                std::string tag = fnTag(func_names, m.value.p);
                if (tag.find("__classmethod__") != std::string::npos) {
                    Value clsv = obj;
                    if (isInstanceValue(obj)) { clsv = Value(); clsv.type = ValueType::USERDATA; clsv.value.p = instance_to_class[obj.value.p]; }
                    Value bm = makeBoundClassMethod(m, clsv);
                    return callFunctionValue(bm, args, ctx, kw_in);
                }
                if (isInstanceValue(obj) && tag.find("__static__") == std::string::npos)
                    return invokeMember(m, where, obj, args, kw_args_in, ctx);
                return callFunctionValue(m, args, ctx, kw_in);
            }
        }
        // ── Universal Object protocol ────────────────────────────────────────
        // Everything is an object in this language, so every instance should
        // answer a common set of queries without the author writing them.
        // Nothing provided them: a plain class had no to_string, no type_name,
        // no id, no is_a — hasattr() reported false for all of them.
        //
        // These are resolved only AFTER the class's own methods, so a class that
        // defines its own to_string() keeps it; the root supplies a default, it
        // does not override.
        {
            Value r = objectProtocol(obj, method_name, args, ctx);
            if (r.type != ValueType::UNDEFINED) return r;
        }

        // Nothing of that name: __getattr__ may supply it; otherwise an
        // instance or a class raises AttributeError (the call returned none,
        // which hid misspelt method names).
        if (isInstanceValue(obj) && method_name != "__getattr__" && instanceHasMethod(obj, "__getattr__")) {
            std::vector<Value> a{makeStringValue(method_name)};
            Value target = callMethod(obj, "__getattr__", a, ctx);
            if (isInstanceValue(target) && instanceHasMethod(target, "__call__"))
                return callMethod(target, "__call__", args, ctx, kw_in);
            // what it gave must be callable (round 78: a str gave none)
            if (target.type == ValueType::INTEGER || target.type == ValueType::DOUBLE || target.type == ValueType::BOOLEAN
                || target.type == ValueType::NONE || bytesOf(target) || (isStringValue(target) && !func_names.count(target.value.p))
                || (contOf(target) && !isInstanceValue(target)))
                pyRaise("TypeError", "'" + typeNameOf(target) + "' object is not callable");
            return callFunctionValue(target, args, ctx);
        }
        // BaseException's own methods called through a class, as subclasses
        // do: `ConnectionResetError.__init__(self, msg)`, `Exception.__str__(e)`.
        if (!args.empty() && isInstanceValue(args[0]) && obj.type == ValueType::USERDATA &&
            (method_name == "__init__" || method_name == "__str__" || method_name == "__repr__")) {
            std::string t = fnTag(func_names, obj.value.p);
            if (t.rfind("__class__:", 0) == 0) {
                std::string cn = t.substr(10);
                size_t tag = cn.find("__");
                if (tag != std::string::npos && tag > 0) cn = cn.substr(0, tag);
                if (classDerivesFrom(cn, "BaseException")) {
                    if (method_name == "__init__") {
                        std::vector<Value> rest(args.begin() + 1, args.end());
                        setExceptionArgs(args[0], rest);
                        return NONE_VALUE;
                    }
                    if (method_name == "__str__") return makeStringValue(exceptionMessage(args[0]));
                    return makeStringValue(exceptionRepr(args[0], ctx));
                }
            }
        }
        // A method of a class's metaclass, called through the class
        // (Color.from_name(...)), or anything else the metaclass gives the
        // class (round 77).
        if (!class_meta_.empty() && classNodeOfValue(obj)) {
            Value m; Node* where = nullptr;
            if (metaMember(obj, method_name, m, where)) {
                if (fnTag(func_names, m.value.p).find("__static__") != std::string::npos) return callFunctionValue(m, args, ctx);
                return callMeta(m, where, obj, args, kw_args_in, ctx);
            }
            Value target;
            if (getAttrValue(obj, method_name, ctx, target)) return callFunctionValue(target, args, ctx);
        }
        // obj.m(...) is getattr(obj, "m")(...): an attribute that is not a
        // method of its own - a property's fget, a function's attribute
        // (round 77)
        if (obj.type == ValueType::USERDATA && obj.value.p && !isInstanceValue(obj)) {
            Value target;
            if (specialAttribute(obj, method_name, ctx, target)) return callFunctionValue(target, args, ctx, kw_in);
        }
        // Any other value without such a method raises too: `none.m()` and
        // `"s".nosuch()` returned none (round 75). `x?.m()` is the graceful
        // spelling.
        if (isInstanceValue(obj) || fnTag(func_names, obj.value.p).rfind("__class__:", 0) == 0)
            throw std::string("__exc__:AttributeError:" + attributeErrorText(obj, method_name));
        return missingAttribute(obj, method_name, nullptr);
    }

    std::vector<std::unique_ptr<int64_t>> func_id_store;
    std::map<void*, void*> func_ast_nodes;
    std::vector<node_ptr> imported_asts; // keep imported ASTs alive // unique_ptr -> AST node ptr
    std::unordered_set<std::string> imported_modules_; // prevent circular imports

    // Each execution of a class statement makes a new class (round 77). A
    // class statement run again - in a function called twice, a factory, a
    // loop - rebound the one class: instances of the first saw the second
    // one's methods, closures and class attributes. A re-run registers a
    // copy of the node as "Name#n" (shown as Name); the plain name keeps
    // naming the newest, for bases looked up by name.
    std::unordered_set<const Node*> class_ran_;
    std::vector<node_ptr> class_copies_;
    int class_generation_ = 0;
    Value evalClassDecl(node_ptr node, Context* ctx) {
        auto cn = static_pointer_cast<ClassNode>(node);
        std::string plain_name = cn->name;
        bool expr_bases = false;
        for (auto& b : cn->bases) if (b && b->type() != NodeType::VARIABLE) expr_bases = true;
        // Another class statement of the same name (a factory's class P and
        // another function's class P, a redefinition) makes a class of its
        // own too, named like a re-run (round 77): bases looked up by name
        // and instances keyed by name saw whichever ran last.
        bool other_stmt = false;
        if (!class_ran_.count(node.get())) {
            auto prev = class_by_name.find(cn->name);
            other_stmt = prev != class_by_name.end() && prev->second && prev->second != (void*)node.get();
            if (other_stmt) class_ran_.insert(node.get());
        }
        if (other_stmt || class_ran_.count(node.get())) {
            auto copy = std::make_shared<ClassNode>(*cn);
            copy->name = cn->name + "#" + std::to_string(++class_generation_);
            if (copy->bind_name.empty()) copy->bind_name = plain_name;
            class_copies_.push_back(copy);
            node = copy;
            cn = copy;
            // expression bases are rewritten below on the copy
        } else {
            class_ran_.insert(node.get());
            if (expr_bases) {
                // its bases are rewritten below: the statement keeps the
                // expressions for its next run
                auto copy = std::make_shared<ClassNode>(*cn);
                class_copies_.push_back(copy);
                node = copy;
                cn = copy;
            }
        }
        // A base given by an expression (Generic[T], namedtuple("P", "x")):
        // evaluated; an object with __mro_entries__ (PEP 560) names the
        // classes it stands for (round 77).
        // The bases as written are the class's __orig_bases__ and what
        // __mro_entries__ is given, as in Python (round 77; typing.Generic
        // reads its type parameters from them).
        Value orig_bases = NONE_VALUE;
        if (expr_bases) {
            std::vector<Value> orig;
            // the base node each value came from: `class C(*bases)` gives
            // one value per item (round 78)
            std::vector<node_ptr> orig_node;
            for (auto& b : cn->bases) {
                if (!b) continue;
                if (b->type() == NodeType::UNARY && static_cast<UnaryNode*>(b.get())->op == "*") {
                    for (auto& it : iterItems(evalNode(static_cast<UnaryNode*>(b.get())->operand, ctx), ctx)) {
                        orig.push_back(it); orig_node.push_back(b);
                    }
                    continue;
                }
                if (b->type() != NodeType::VARIABLE) { orig.push_back(evalNode(b, ctx)); orig_node.push_back(b); continue; }
                Value bv = ctx->getByName(b->value());
                if (!classNodeOfValue(bv) && classNodeByName(b->value())) bv = classValueOfNode(classNodeByName(b->value()));
                orig.push_back(bv); orig_node.push_back(b);
            }
            orig_bases = makeListValue(orig, true);
            std::vector<node_ptr> nb;
            for (size_t oi = 0; oi < orig.size(); oi++) {
                const node_ptr& b = orig_node[oi];
                Value bv = orig[oi];
                if (b->type() == NodeType::VARIABLE) { nb.push_back(b); continue; }
                std::vector<Value> entries{bv};
                if (isInstanceValue(bv) && instanceHasMethod(bv, "__mro_entries__")) {
                    std::vector<Value> a{orig_bases};
                    entries = listItems(callMethod(bv, "__mro_entries__", a, ctx));
                }
                for (auto& e : entries) {
                    std::string bn;
                    if (Node* bcn = classNodeOfValue(e)) bn = static_cast<ClassNode*>(bcn)->name;
                    else {
                        std::string t = fnTag(func_names, e.value.p);
                        if (e.type == ValueType::USERDATA && t.rfind("__builtin__:", 0) == 0) bn = t.substr(12);
                    }
                    if (bn.empty()) pyRaise("TypeError", "bases must be types");
                    Token t = b->token();
                    t.value = bn;
                    nb.push_back(std::make_shared<VariableNode>(t));
                }
            }
            cn->bases = nb;
            ++class_names_ver_;   // round 82
        }
        // `class C(Base, metaclass=M, **kw)`: the keywords, for
        // __init_subclass__ (metaclass: the class's metaclass).
        nyrt::OrderedKw<Value> class_kw;
        for (auto& [k, e] : cn->keywords) {
            Value v = evalNode(e, ctx);
            if (k == "**") {
                // `class C(**kw)` (round 77): each item is a keyword
                Container* kc = contOf(v);
                if (!kc || seqLen(kc) >= 0) pyRaise("TypeError", "argument after ** must be a mapping, not " + typeNameOf(v));
                for (auto& [dk, dv] : *kc->container) {
                    if (isInternalKey(dk)) continue;   // a marker, not an item
                    if (nypy::key_kind(dk) != nypy::K_STR) pyRaise("TypeError", "keywords must be strings");
                    std::string kn = nypy::key_payload(dk);
                    if (kn == "metaclass") class_meta_[(void*)node.get()] = dv;
                    else class_kw[kn] = dv;
                }
                continue;
            }
            if (k == "metaclass") class_meta_[(void*)node.get()] = v;
            else class_kw[k] = v;
        }
        // Bases are looked up in scope (round 77): a module's class (named
        // "module.Class"), one imported with `from m import C`, an alias,
        // a dotted base (threading.Thread). The base node takes the class's
        // own name, which everything after this reads.
        for (auto& b : cn->bases) {
            if (!b) continue;
            std::string bn = b->value();
            // A module's own base is already "module.Class" (the parser
            // qualified it): keep it.
            if (bn.find('.') != std::string::npos && classNodeByName(bn)) continue;
            // A class bound in scope under that name: that class (the one a
            // factory made in this call, not the newest of the name).
            if (bn.find('.') == std::string::npos) {
                Value bv = ctx->getByName(shownClassName(bn));
                if (Node* bcn = classNodeOfValue(bv)) {
                    const std::string& full = static_cast<ClassNode*>(bcn)->name;
                    if (full != bn) {
                        Token t = b->token();
                        t.value = full;
                        b = std::make_shared<VariableNode>(t);
                    }
                    continue;
                }
            }
            std::string rn = excClassName(bn, ctx);
            if (rn != bn && (classNodeByName(rn) || nython::ny_is_builtin_exc(rn))) {
                Token t = b->token();
                t.value = rn;
                b = std::make_shared<VariableNode>(t);
            }
        }
        // a builtin base (int, list ...): its mirror class (round 77)
        for (auto& b : cn->bases) if (b) mirrorsFor(b->value());
        Value class_val;
        class_val.type = ValueType::USERDATA;
        class_val.value.p = (void*)node.get();
        func_names[(void*)node.get()] = "__class__:" + cn->name;
        class_by_name[cn->name] = (void*)node.get();
        ++class_names_ver_;   // round 82: classDerivesFrom's answers
        mro_cache_.clear(); specInvalidate();
        attr_hook_cache_[0].clear();
        attr_hook_cache_[1].clear();
        attr_hook_cache_[2].clear(); specInvalidate();   /* round 81 */
        no_new_.clear();
        if (cn->body)
            for (auto& st : cn->body->statements())
                if (st && st->type() == NodeType::FUNCTION) direct_methods_.insert(st.get());
        // Store parent class if exists
        if (!cn->bases.empty()) {
            // bases[0] is a VariableNode with parent class name
            class_parent[(void*)node.get()] = cn->bases[0]->value();
        }
        // A class with a metaclass is bound once the metaclass has made it,
        // as in Python and on the VM (round 77): its __new__ / __init_subclass__
        // still see the name's old value (enum's `Enum = None` bootstrap).
        Value meta_pre = metaclassOf(node.get());
        if (meta_pre.type == ValueType::NONE)
            ctx->defineByName(cn->bind_name.empty() ? cn->name : cn->bind_name, class_val);
        // A metaclass's __prepare__(name, bases, **kw) (round 77): the
        // mapping the body's bindings go to as they are made, in order
        // (prepareStore), and the namespace the metaclass's __new__ gets.
        PrepareHook prep{this, NONE_VALUE};
        if (meta_pre.type != ValueType::NONE) prep.ns = callPrepare(meta_pre, cn.get(), class_kw, ctx);
        if (cn->body) {
            Context* class_ctx = new Context(runner, cn->name, nullptr, nullptr, ctx);
            CtxReaper _class_creator(this, class_ctx);
            class_ctx->inClass = true;
            {
                struct Unhook { Context* c; ~Unhook() { c->storeHook = nullptr; c->storeHookArg = nullptr; } } unhook{class_ctx};
                if (prep.ns.type != ValueType::NONE) { class_ctx->storeHook = &NythonExecutor::prepareStoreThunk; class_ctx->storeHookArg = &prep; }
                evalNode(cn->body, class_ctx);
            }
            if (orig_bases.type != ValueType::NONE) class_ctx->defineByName("__orig_bases__", orig_bases);   // round 77
            // __init_subclass__ and __class_getitem__ are classmethods
            // without the decorator, as in Python (round 77)
            for (const char* nm : {"__init_subclass__", "__class_getitem__"}) {
                if (!class_ctx->container) break;
                auto it = class_ctx->container->find(nm);
                if (it == class_ctx->container->end() || !isPlainFunction(it->second)) continue;
                if (fnTag(func_names, it->second.value.p).find("__classmethod__") != std::string::npos) continue;
                std::vector<Value> a{it->second};
                Value cm = callBuiltin("classmethod", a, class_ctx);
                class_ctx->defineByName(nm, cm);
            }
            // Store the evaluated class context so decorators (@property, @staticmethod) are visible
            setClassContext((void*)node.get(), class_ctx);
        }
        // (__set_name__ runs in classCreated, before __init_subclass__)
        // A metaclass (the statement's metaclass=, or a base's): its __new__
        // and __init__ run on the class just made; what __new__ returns is
        // what the statement binds (round 77).
        Value meta = meta_pre;
        if (meta.type != ValueType::NONE) {
            Value made = runMetaclass(meta, class_val, node.get(), cn.get(), class_kw, ctx,
                                      prep.ns.type != ValueType::NONE ? &prep.ns : nullptr);
            ctx->defineByName(cn->bind_name.empty() ? cn->name : cn->bind_name, made);
            return made;
        }
        classCreated(class_val, node.get(), class_kw, ctx);
        return class_val;
    }
    // ── metaclasses (round 77) ──────────────────────────────────────────
    // A class's metaclass: its statement's metaclass=, else the nearest
    // base's in MRO order; none for a plain class (its metaclass is type).
    Value metaclassOf(Node* cn) {
        if (class_meta_.empty() || !cn) return NONE_VALUE;
        for (Node* c : classMro(cn)) {
            auto it = class_meta_.find((void*)c);
            if (it != class_meta_.end() && classNodeOfValue(it->second)) return it->second;
        }
        return NONE_VALUE;
    }
    // A member of cls's metaclass (cls a class with a metaclass).
    bool metaMember(const Value& cls, const std::string& name, Value& m, Node*& where) {
        if (class_meta_.empty()) return false;
        Node* cn = classNodeOfValue(cls);
        if (!cn) return false;
        Node* mn = classNodeOfValue(metaclassOf(cn));
        if (!mn) return false;
        return findClassMember(mn, name, m, &where) && m.type == ValueType::USERDATA && m.value.p && func_names.count(m.value.p);
    }
    // Calls the metaclass member found by metaMember with the class first.
    Value callMeta(const Value& m, Node* where, const Value& cls, const std::vector<Value>& args,
                   const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        std::vector<Value> a;
        a.reserve(args.size() + 1);
        a.push_back(cls);
        for (auto& x : args) a.push_back(x);
        return invokeMember(m, where, cls, a, kw, ctx);
    }
    bool metaCall(const Value& cls, const char* name, const std::vector<Value>& args, Context* ctx, Value& out) {
        Value m; Node* where = nullptr;
        if (!metaMember(cls, name, m, where)) return false;
        static const nyrt::OrderedKw<Value> no_kw;
        out = callMeta(m, where, cls, args, no_kw, ctx);
        return true;
    }
    Value classValueOfNode(Node* n) { Value v; v.type = ValueType::USERDATA; v.value.p = (void*)n; return v; }
    // The class namespace as the dict a metaclass gets, and C.__dict__.
    // Its names are stored as dict keys (key_of_str), so a dunder method is
    // a key like any other - it read as an internal marker, so __iter__,
    // __init__, __hash__ = None ... were missing - and the parser's
    // decorator temporaries are left out (round 77).
    Value classNamespace(Node* cnode, bool implicit = true) {   // implicit: __new__ as a staticmethod ... (round 78; not in the namespace a metaclass gets)
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        auto cit = class_ctx_map_.find((void*)cnode);
        if (cit != class_ctx_map_.end() && cit->second && cit->second->container)
            for (auto& kv : *cit->second->container)
                if (!kv.first.empty() && (unsigned char)kv.first[0] >= 0x20 && kv.first != "__parent_class__"
                    && !nyrt::is_decorator_temp(kv.first))
                    (*d->container)[nypy::key_of_str(kv.first)] = methodObjectOf(kv.second, global_ctx, implicit ? &kv.first : nullptr);
        return Value((Collectable*)d);
    }
    // The classes a class statement is building, for type.__new__ called by
    // a metaclass's __new__ (it returns the class already made); `second`:
    // type.__new__ has run for it.
    std::vector<std::pair<Value, bool>> constructing_;
    // The bases a metaclass sees: the classes, a builtin base (class
    // IntEnum(int, ReprEnum)) as its builtin type, as in Python (round 77).
    Value classBasesTuple(ClassNode* cn) {
        std::vector<Value> bvals;
        for (auto& b : cn->bases) {
            if (Node* bn = classNodeByName(b->value())) bvals.push_back(classValueOfNode(bn));
            else if (nyrt::is_builtin_type_name(b->value()) && b->value() != "object") {
                Value bv = global_ctx->getByName(b->value());
                if (bv.type != ValueType::UNDEFINED && bv.type != ValueType::NONE) bvals.push_back(bv);
            }
        }
        return makeListValue(bvals, true);
    }
    // ── __prepare__ (round 77) ──────────────────────────────────────────
    // A metaclass defining __prepare__ (not type's): it is called with the
    // class's name, bases and keywords before the body runs, and each name
    // the body binds goes to the mapping it returned, in order, through the
    // mapping's __setitem__ (so a name bound twice is seen twice); the body
    // reads back what the mapping then holds for the name (enum's auto()
    // values), and the mapping is the namespace the metaclass's __new__
    // gets. What differs from CPython: the body runs in the engine's own
    // namespace, so its reads do not go through the mapping's __getitem__,
    // `del name` in the body does not call __delitem__, a name the mapping
    // refuses to hold stays in the class, and the mapping does not receive
    // __module__ / __qualname__.
    struct PrepareHook { NythonExecutor* E; Value ns; int skip = 0; };
    static Value prepareStoreThunk(void* a, const std::string& name, const Value& v) {
        auto* h = static_cast<PrepareHook*>(a);
        return h->E->prepareStore(h->ns, name, v, h->skip);
    }
    Value prepareStore(const Value& ns, const std::string& name, const Value& v, int& skip) {
        if (name.empty() || (unsigned char)name[0] < 0x20) return v;
        // @D def f: the parser's `__decN__ = D; def f; f = __decN__(f)` -
        // the mapping sees f once, decorated, as in Python (nyrt::
        // decorator_binding; stacked decorators nest the pattern)
        if (nyrt::decorator_binding(name, skip)) return v;
        Value key = makeStringValue(name);
        if (isInstanceValue(ns)) {
            std::vector<Value> a{key, v};
            callMethod(ns, "__setitem__", a, global_ctx);
            Value back;
            if (tryGetItem(ns, key, global_ctx, back)) return back;
            return v;
        }
        if (Container* c = contOf(ns); c && seqLen(c) < 0) dictSet(c, key, v);
        return v;
    }
    Value callPrepare(const Value& meta, ClassNode* cn, const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        Node* mn = classNodeOfValue(meta);
        if (!mn) return NONE_VALUE;
        Value m; Node* where = nullptr;
        if (!findClassMember(mn, "__prepare__", m, &where) || !where || where->type() != NodeType::CLASS) return NONE_VALUE;
        std::string owner = shownClassName(static_cast<ClassNode*>(where)->name);
        if (owner == "object" || owner == "type") return NONE_VALUE;
        Value f;
        if (!getAttrValue(meta, "__prepare__", ctx, f)) return NONE_VALUE;
        std::vector<Value> a{makeStringValue(nyrt::bare_class_name(shownClassName(cn->name))), classBasesTuple(cn)};
        Value ns = callFunctionValue(f, a, ctx, &kw);
        if (!isInstanceValue(ns) && !(contOf(ns) && seqLen(contOf(ns)) < 0))
            pyRaise("TypeError", shownClassName(static_cast<ClassNode*>(mn)->name) + ".__prepare__() must return a mapping, not " + typeNameOf(ns));
        return ns;
    }
    Value runMetaclass(const Value& meta, const Value& cls, Node* cnode, ClassNode* cn,
                       const nyrt::OrderedKw<Value>& kw, Context* ctx, const Value* prepared = nullptr) {
        Node* mn = classNodeOfValue(meta);
        Node* objn = classNodeByName("object");
        // the class's own name, as Python passes it ("A", not the module's
        // "m.A" this engine keys it by - round 77)
        Value name = makeStringValue(nyrt::bare_class_name(shownClassName(cn->name)));
        Value bases = classBasesTuple(cn);
        // the namespace: what __prepare__ returned, else the body's (round 77)
        Value ns = prepared ? *prepared : classNamespace(cnode, false);
        Value made = cls;
        Value m; Node* where = nullptr;
        if (findClassMember(mn, "__new__", m, &where) && where != objn && func_names.count(m.value.p)) {
            constructing_.push_back({cls, false});
            std::vector<Value> a{meta, name, bases, ns};
            try { made = invokeMember(m, where, meta, a, kw, ctx); }
            catch (...) { constructing_.pop_back(); throw; }
            bool ran = constructing_.back().second;
            constructing_.pop_back();
            if (!ran) classCreated(cls, cnode, kw, ctx);
        } else {
            class_meta_[cnode] = meta;
            // type.__new__ itself: the class's namespace is the mapping
            // __prepare__ returned (round 77)
            if (prepared) {
                auto cit = class_ctx_map_.find((void*)cnode);
                if (Container* nc = contOf(unwrapPayload(*prepared)); nc && cit != class_ctx_map_.end() && cit->second)
                    for (auto& k : dictKeys(nc)) {
                        if (!isStringValue(k)) continue;
                        auto it = dictFind(nc, k);
                        if (it != nc->container->end()) cit->second->defineByName(getStringValue(k), it->second);
                    }
            }
            classCreated(cls, cnode, kw, ctx);
        }
        if (classNodeOfValue(made) && findClassMember(mn, "__init__", m, &where) && where != objn && func_names.count(m.value.p)) {
            std::vector<Value> a{made, name, bases, ns};
            invokeMember(m, where, made, a, kw, ctx);
        }
        return made;
    }
    // type.__new__(mcs, name, bases, ns, **kw): the class a class statement
    // is building (its namespace updated from ns, its metaclass mcs, then
    // __set_name__ / __init_subclass__), or a new class made from the
    // arguments - type(name, bases, ns) and a metaclass called directly.
    Value typeNew(std::vector<Value>& args, const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        if (args.size() < 4) pyRaise("TypeError", "type.__new__() takes exactly 3 arguments (" + std::to_string(args.size() ? args.size() - 1 : 0) + " given)");
        // the namespace may be a dict subclass's instance (what a
        // __prepare__ returned): its dict, as CPython copies it (round 77)
        args[3] = unwrapPayload(args[3]);
        Value mcs = args[0];
        std::string name = getStringValue(args[1]);
        if (!constructing_.empty() && !constructing_.back().second) {
            Value cls = constructing_.back().first;
            Node* cnode = classNodeOfValue(cls);
            if (cnode && nyrt::bare_class_name(shownClassName(static_cast<ClassNode*>(cnode)->name)) == nyrt::bare_class_name(name)) {
                constructing_.back().second = true;
                auto cit = class_ctx_map_.find((void*)cnode);
                if (Container* nc = contOf(args[3]); nc && cit != class_ctx_map_.end() && cit->second) {
                    for (auto& k : dictKeys(nc)) {
                        if (!isStringValue(k)) continue;
                        auto it = dictFind(nc, k);
                        if (it != nc->container->end()) cit->second->defineByName(getStringValue(k), it->second);
                    }
                }
                if (classNodeOfValue(mcs)) class_meta_[(void*)cnode] = mcs;
                mro_cache_.clear(); specInvalidate();
                attr_hook_cache_[0].clear();
                attr_hook_cache_[1].clear();
        attr_hook_cache_[2].clear(); specInvalidate();   /* round 81 */
                classCreated(cls, cnode, kw, ctx);
                return cls;
            }
        }
        return makeDynamicClass(mcs, name, args[2], args[3], kw, ctx);
    }
    // A class made by a call (type(name, bases, ns), M(name, bases, ns)):
    // a class node without a body, its namespace the dict's items.
    std::vector<node_ptr> dynamic_classes_;
    Value makeDynamicClass(const Value& mcs, const std::string& name, const Value& bases, const Value& ns,
                           const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        Token t;
        t.value = name;
        std::string full = name;
        if (class_by_name.count(full)) full = name + "#" + std::to_string(++class_generation_);
        auto node = std::make_shared<ClassNode>(t, full, std::make_shared<BlockNode>(t));
        node->bind_name = name;
        for (auto& b : listItems(bases)) {
            std::string bn;
            if (Node* bcn = classNodeOfValue(b)) bn = static_cast<ClassNode*>(bcn)->name;
            else {
                std::string tag = fnTag(func_names, b.value.p);
                if (b.type == ValueType::USERDATA && tag.rfind("__builtin__:", 0) == 0) bn = tag.substr(12);
            }
            if (bn.empty()) pyRaise("TypeError", "bases must be types");
            if (bn == "map") bn = "dict";
            mirrorsFor(bn);   // a builtin base's mirror class (round 77)
            Token bt = t; bt.value = bn;
            node->bases.push_back(std::make_shared<VariableNode>(bt));
        }
        dynamic_classes_.push_back(node);
        Value cls = classValueOfNode(node.get());
        func_names[(void*)node.get()] = "__class__:" + full;
        class_by_name[full] = (void*)node.get();
        ++class_names_ver_;   // round 82
        if (!node->bases.empty()) class_parent[(void*)node.get()] = node->bases[0]->value();
        mro_cache_.clear(); specInvalidate();
        attr_hook_cache_[0].clear();
        attr_hook_cache_[1].clear();
        attr_hook_cache_[2].clear(); specInvalidate();   /* round 81 */
        no_new_.clear();
        Context* class_ctx = new Context(runner, full, nullptr, nullptr, global_ctx);
        CtxReaper _class_creator(this, class_ctx);
        class_ctx->inClass = true;
        if (Container* nc = contOf(ns)) {
            for (auto& k : dictKeys(nc)) {
                if (!isStringValue(k)) continue;
                auto it = dictFind(nc, k);
                if (it != nc->container->end()) class_ctx->defineByName(getStringValue(k), it->second);
            }
        }
        setClassContext((void*)node.get(), class_ctx);
        if (classNodeOfValue(mcs) && !(classNodeByName("type") && classNodeOfValue(mcs) == classNodeByName("type")))
            class_meta_[(void*)node.get()] = mcs;
        classCreated(cls, node.get(), kw, ctx);
        return cls;
    }
    // A metaclass called: M(name, bases, ns) makes a class (type.__call__):
    // M.__new__ (else type.__new__), then M.__init__ on a class it returned.
    Value callMetaclass(const Value& M, std::vector<Value>& args, const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        Node* mn = classNodeOfValue(M);
        Node* objn = classNodeByName("object");
        Value m; Node* where = nullptr;
        Value made;
        if (findClassMember(mn, "__new__", m, &where) && where != objn && func_names.count(m.value.p)) {
            std::vector<Value> a{M};
            for (auto& x : args) a.push_back(x);
            made = invokeMember(m, where, M, a, kw, ctx);
        } else {
            std::vector<Value> a{M};
            for (auto& x : args) a.push_back(x);
            made = typeNew(a, kw, ctx);
        }
        if (classNodeOfValue(made) && findClassMember(mn, "__init__", m, &where) && where != objn && func_names.count(m.value.p)) {
            std::vector<Value> a{made};
            for (auto& x : args) a.push_back(x);
            invokeMember(m, where, made, a, kw, ctx);
        }
        return made;
    }
    // What a class statement has made: metaclass of each class (class_meta_),
    // and the hooks of PEP 487 run once the class exists - __set_name__ of
    // its attributes, then __init_subclass__ of the nearest base defining it
    // (an implicit classmethod) with the statement's keywords (round 77).
    std::unordered_map<void*, Value> class_meta_;
    // C.__subclasses__(): each class's direct subclasses, in creation order.
    std::unordered_map<Node*, std::vector<Node*>> subclasses_;
    Value subclassesOf(const Value& cls) {
        std::vector<Value> r;
        if (Node* cn = classNodeOfValue(cls)) {
            auto it = subclasses_.find(cn);
            if (it != subclasses_.end())
                for (Node* s : it->second) { Value v; v.type = ValueType::USERDATA; v.value.p = (void*)s; r.push_back(v); }
        }
        return makeListValue(r, false);
    }
    // staticmethod / classmethod objects (the prelude's) in a class's own
    // namespace are taken apart when the class is made (round 77): the
    // function is marked static / class - what every call path here knows -
    // and C.__dict__ makes the object again (methodObjectOf). A builtin or a
    // callable object inside one is left to the object's __get__.
    Value unwrapMethodObject(const Value& v, Context* ctx) {
        if (!isInstanceValue(v)) return v;
        Node* c = classNodeOfInstance(v);
        if (!c) return v;
        Node* smn = classNodeByName("staticmethod");
        Node* cmn = classNodeByName("classmethod");
        if (c != smn && c != cmn) return v;
        Value f = attrOf(v, "__func__");
        // a def's function (a lambda is never bound here: left to __get__)
        if (!isPlainFunction(f) || bound_self_.count(f.value.p) || fnTag(func_names, f.value.p).rfind("__func__:", 0) != 0) return v;
        const char* mark = c == smn ? "__static__" : "__classmethod__";
        if (fnTag(func_names, f.value.p).find(mark) != std::string::npos) return f;   // marked already
        std::vector<Value> a{f};
        return callBuiltin(c == smn ? "staticmethod" : "classmethod", a, ctx);
    }
    void unwrapMethodObjects(Container* ns, Context* ctx) {
        if (!ns || !ns->container) return;
        for (auto& kv : *ns->container)
            if (isInstanceValue(kv.second)) kv.second = unwrapMethodObject(kv.second, ctx);
    }
    // A class namespace's static / class method as the object Python's
    // C.__dict__ holds (round 77); anything else as it is.
    Value methodObjectOf(const Value& v, Context* ctx, const std::string* name = nullptr) {
        if (!isPlainFunction(v) || bound_self_.count(v.value.p)) return v;
        const std::string tag = fnTag(func_names, v.value.p);
        const char* kind = tag.find("__static__") != std::string::npos ? "staticmethod"
                         : tag.find("__classmethod__") != std::string::npos ? "classmethod" : nullptr;
        // __new__ is a static method, __init_subclass__ and
        // __class_getitem__ class methods, without the decorator (round 78)
        if (!kind && name) kind = nyrt::implicit_method_kind(*name);
        if (!kind) return v;
        Node* wn = classNodeByName(kind);
        if (!wn) return v;
        std::vector<Value> a{v};
        return callFunctionValue(classValueOfNode(wn), a, ctx);
    }
    // A data descriptor (an instance whose class defines __set__ or
    // __delete__: a property, enum.property ...) held by a class: attribute
    // stores look for one from then on (round 77; it was any class defining
    // __set__, which the prelude's property now is).
    void noteDataDescriptor(const Value& v, const std::string* name = nullptr) {
        if (name && isDataDescriptorValue(v) && data_descr_names_.insert(*name).second) dd_names_ver_++;   // round 78 (round 81: versioned)
        if (any_data_descr_ || !isInstanceValue(v)) return;
        if (instanceHasMethod(v, "__set__") || instanceHasMethod(v, "__delete__")) any_data_descr_ = true;
    }
    // A data descriptor - an object whose class defines __set__ or
    // __delete__, or a property (unwrapped to its tagged getter) - wins over
    // an instance field of its name, as in Python (round 78: the field was
    // read first). The names classes hold one under, so a field read pays
    // for the check only for those.
    std::unordered_set<std::string> data_descr_names_;
    uint32_t dd_names_ver_ = 1;   // round 81: bumped when a name is added to data_descr_names_
    bool isDataDescriptorValue(const Value& d) {
        if (isInstanceValue(d)) return instanceHasMethod(d, "__set__") || instanceHasMethod(d, "__delete__");
        return d.type == ValueType::USERDATA && d.value.p
               && fnTag(func_names, d.value.p).find("__property__") != std::string::npos;
    }
    bool classDataDescriptor(const Value& obj, const std::string& attr) {
        if (data_descr_names_.empty() || !data_descr_names_.count(attr) || !isInstanceValue(obj)) return false;
        Node* cls = classNodeOfInstance(obj);
        Value d;
        return cls && findClassMember(cls, attr, d) && isDataDescriptorValue(d);
    }
    void classCreated(const Value& cls, Node* cnode, const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        // __slots__ (round 79): the prelude's _ny_init_slots (mirrors chunk
        // "slots") checks them and puts a member descriptor on the class for
        // each, as type.__new__ does, before anything else sees the class
        {
            auto cit = class_ctx_map_.find((void*)cnode);
            if (cit != class_ctx_map_.end() && cit->second && cit->second->container
                && cit->second->container->count("__slots__")) {
                ensureSlotsChunk();
                std::vector<Value> a{cls};
                callFunctionValue(global_ctx->getByName("_ny_init_slots"), a, ctx);
            }
        }
        {
            auto cit = class_ctx_map_.find((void*)cnode);
            if (cit != class_ctx_map_.end() && cit->second && cit->second->container) {
                auto& ns = *cit->second->container;
                // __eq__ without __hash__ makes the class unhashable, as
                // Python's type.__new__ does (round 77)
                if (ns.count("__eq__") && !ns.count("__hash__")) cit->second->defineByName("__hash__", NONE_VALUE);
                unwrapMethodObjects(cit->second, ctx);
                for (auto& kv : ns) noteDataDescriptor(kv.second, &kv.first);
            }
        }
        {
            bool any = false;
            for (auto& b : static_cast<ClassNode*>(cnode)->bases)
                if (Node* bn = classNodeByName(b->value()); bn && bn != cnode) {
                    auto& v = subclasses_[bn];
                    if (std::find(v.begin(), v.end(), cnode) == v.end()) v.push_back(cnode);
                    any = true;
                }
            Node* objn = any ? nullptr : classNodeByName("object");
            if (objn && objn != cnode) {
                auto& v = subclasses_[objn];
                if (std::find(v.begin(), v.end(), cnode) == v.end()) v.push_back(cnode);
            }
        }
        // a class deriving from type is a metaclass (callable to make classes)
        if (classDerivesFrom(static_cast<ClassNode*>(cnode)->name, "type")) metaclass_types_.insert(cnode);
        auto cit = class_ctx_map_.find((void*)cnode);
        // a class with its own __getattribute__: attribute reads look for it
        // (round 77; object's is the plain lookup)
        if (!any_getattribute_ && cit != class_ctx_map_.end() && cit->second && cit->second->container
            && cit->second->container->count("__getattribute__") && shownClassName(static_cast<ClassNode*>(cnode)->name) != "object")
            any_getattribute_ = true;
        if (cit != class_ctx_map_.end() && cit->second && cit->second->container) {
            std::vector<std::pair<std::string, Value>> attrs;
            for (auto& kv : *cit->second->container)
                if (isInstanceValue(kv.second)) attrs.push_back({kv.first, kv.second});
            for (auto& [n, v] : attrs) {
                if (!instanceHasMethod(v, "__set_name__")) continue;
                std::vector<Value> a{cls, makeStringValue(n)};
                Value vv = v;
                callMethod(vv, "__set_name__", a, ctx);
            }
        }
        Value m; Node* where = nullptr;
        if (findClassMember(cnode, "__init_subclass__", m, &where, cnode) && m.type == ValueType::USERDATA
            && m.value.p && func_names.count(m.value.p)) {
            std::vector<Value> a;
            if (fnTag(func_names, m.value.p).find("__classmethod__") == std::string::npos) a.push_back(cls);
            invokeMember(m, where, cls, a, kw, ctx);
        } else if (!kw.empty()) {
            pyRaise("TypeError", shownClassName(static_cast<ClassNode*>(cnode)->name) + ".__init_subclass__() takes no keyword arguments");
        }
    }
    // C[x]: __class_getitem__ (PEP 560, an implicit classmethod), and the
    // builtin generics list[int], dict[str, int], ... (the prelude's
    // _NyGenericAlias) - round 77.
    bool classSubscript(const Value& obj, const Value& idx, Context* ctx, Value& out) {
        if (obj.type != ValueType::USERDATA || !obj.value.p) return false;
        if (Node* cn = classNodeOfValue(obj)) {
            Value m; Node* where = nullptr;
            if (!findClassMember(cn, "__class_getitem__", m, &where) || m.type != ValueType::USERDATA) return false;
            // round 80: a descriptor (`__class_getitem__ =
            // classmethod(types.GenericAlias)` - it was called as a function:
            // a segmentation fault): what its __get__(None, C) gives is
            // called with the item
            if (isInstanceValue(m)) {
                Value b;
                if (!descriptorGet(m, NONE_VALUE, obj.value.p, ctx, b, false, where)) b = m;
                std::vector<Value> a1{idx};
                out = callFunctionValue(b, a1, ctx);
                return true;
            }
            if (!func_names.count(m.value.p)) return false;
            std::vector<Value> a;
            if (fnTag(func_names, m.value.p).find("__classmethod__") == std::string::npos) a.push_back(obj);
            a.push_back(idx);
            static const nyrt::OrderedKw<Value> no_kw;
            out = invokeMember(m, where, obj, a, no_kw, ctx);
            return true;
        }
        std::string t = fnTag(func_names, obj.value.p);
        if (t.rfind("__builtin__:", 0) != 0) return false;
        static const std::unordered_set<std::string> generic = {"list", "dict", "tuple", "set", "frozenset", "type"};
        if (!generic.count(t.substr(12))) return false;
        std::vector<Value> a{obj, idx};
        out = callFunctionValue(global_ctx->getByName("_NyGenericAlias"), a, ctx);
        return true;
    }
    // A type in an X | Y union: a class, a builtin type, None.
    bool isTypeOperand(const Value& v) {
        if (v.type == ValueType::NONE) return true;
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        if (classNodeOfValue(v)) return true;
        std::string t = fnTag(func_names, v.value.p);
        if (t.rfind("__builtin__:", 0) != 0) return false;
        static const std::unordered_set<std::string> types = {"int", "float", "str", "bool", "list", "dict", "tuple",
            "set", "frozenset", "bytes", "bytearray", "complex", "object", "type"};
        return types.count(t.substr(12)) > 0;
    }

    // Bind the interface as a real class-like value, registered the same
    // way evalClassDecl registers a class, so `implements MyInterface`
    // (Parser.cpp's classDecl stores implemented interface names as extra
    // bases, same list a `class Foo(Bar):` parent occupies) resolves to
    // something real, and the existing is_a/isinstance inheritance-chain
    // walk - which looks classes up by name in class_by_name - finds it.
    // This used to be an unconditional `return NONE_VALUE;` in evalNode's
    // main switch that bypassed InterfaceNode's own (dead) eval() entirely,
    // so an interface's name was never defined at all and `implements
    // Shape` silently referenced nothing.
    Value evalInterfaceDecl(const node_ptr& node, Context* ctx) {
        auto in_ = static_pointer_cast<InterfaceNode>(node);
        Value class_val;
        class_val.type = ValueType::USERDATA;
        class_val.value.p = (void*)node.get();
        func_names[(void*)node.get()] = "__class__:" + in_->name;
        class_by_name[in_->name] = (void*)node.get();
        ++class_names_ver_;   // round 82
        ctx->defineByName(in_->name, class_val);
        if (in_->body) {
            Context* iface_ctx = new Context(runner, in_->name, nullptr, nullptr, ctx);
            CtxReaper _iface_creator(this, iface_ctx);
            evalNode(in_->body, iface_ctx);
            setClassContext((void*)node.get(), iface_ctx);
        }
        return class_val;
    }

    Value evalLambda(const node_ptr& node, Context* ctx) {
        auto* fo = new nyheap::Func(this, ++closure_id_counter);
        void* unique_ptr = (void*)&fo->id;
        Value fn_val = nyheap::userValue(fo, unique_ptr);

        // A lambda closes over the scope it is made in, as a `def` does
        // (evalFunctionDecl): it sees later assignments there, so a lambda
        // can call itself through the name it is assigned to, and
        // `[lambda: i for i in range(3)]` all return 2, as in Python and on
        // the VM. It used to copy every visible binding when it was made
        // (from before scopes were reference-counted), which broke both and
        // copied the whole module for each lambda.
        func_names[unique_ptr] = "__lambda__";
        closure_contexts[unique_ptr] = ctx;
        fo->setScope(ctx);
        // Defaults are evaluated now, as a def's are (captureDefaults):
        // `[lambda i=i: i for i in range(3)]` keeps 0, 1, 2.
        auto* lam = static_cast<LambdaNode*>(node.get());
        bool any_default = false;
        for (auto& d : lam->defaults) if (d) { any_default = true; break; }
        if (any_default) {
            std::vector<Value> vals(lam->params.size(), UNDEFINED_VALUE);
            for (size_t i = 0; i < lam->params.size() && i < lam->defaults.size(); i++)
                if (lam->defaults[i]) vals[i] = evalNode(lam->defaults[i], ctx);
            fn_defaults_val_[unique_ptr] = std::move(vals);
        }
        func_ast_nodes[unique_ptr] = (void*)node.get();
        fo->code = node.get();   // round 81
        heap_owner_[unique_ptr] = fo;
        nygc::track(fo);
        return fn_val;
    }


    // Helper: build a positional args list and a keyword map from a CallNode's arg list
    // Returns positional args in call_args, named args in kw_args (name->value)
    // ── Specialization (round 81) ───────────────────────────────────────
    // The interpreter's nodes remember what they saw and take a shorter,
    // equivalent path next time (a self-optimizing AST interpreter, after
    // Würthinger et al., DLS 2012). NY_ASTSPEC=0 turns every one of them
    // off, so a wrong answer can be told from a generic one.
    static inline const bool ast_spec_on_ = [] {
        const char* e = std::getenv("NY_ASTSPEC");
        return !(e && e[0] == '0' && e[1] == 0);
    }();
    static bool astSpecOn() { return ast_spec_on_; }
    static constexpr size_t kFastArgs = 8;   // arguments a fast call keeps on the C++ stack
    // The specialization epoch: what the method caches assume about classes
    // (their MROs, which namespace is each class's, class_vars_, the kind
    // a function's tag gives it, that a cached method is still alive) holds
    // only while it is unchanged; everything that can change those bumps it.
    uint64_t spec_epoch_ = 1;
    void specInvalidate() { ++spec_epoch_; }
    // Up to kFastArgs argument values on the C++ stack, made in order and
    // destroyed in order as a std::vector's are (round 81).
    struct ArgBuf {
        alignas(Value) unsigned char raw[sizeof(Value) * kFastArgs];
        size_t n = 0;
        ArgBuf() = default;
        ArgBuf(const ArgBuf&) = delete;
        ArgBuf& operator=(const ArgBuf&) = delete;
        Value& operator[](size_t i) { return reinterpret_cast<Value*>(raw)[i]; }
        void push(Value&& v) { new (&(*this)[n]) Value(std::move(v)); n++; }
        ~ArgBuf() { for (size_t i = 0; i < n; i++) (*this)[i].~Value(); }
    };
    // Whether the statements of a class body assign `name` at their top
    // level (getAttrValue evaluates such an assignment for a class whose
    // namespace lacks the name).
    static bool classBodyAssigns(ClassNode* cn, const std::string& name) {
        if (!cn || !cn->body) return false;
        for (auto& stmt : blockStmts(cn->body.get())) {
            if (stmt && stmt->type() == NodeType::ASSIGNMENT) {
                auto* as = static_cast<AssignmentNode*>(stmt.get());
                if (as->target && as->target->type() == NodeType::VARIABLE && as->target->value() == name) return true;
            }
        }
        return false;
    }
    // ── obj.m(args) on an instance, through the site's cache (round 81) ──
    // What evalCall's method path, callMethod, callClassMethod and
    // invokeMember do for a plain method - a def written in a class body,
    // first parameter self (or this), every parameter a plain name, called
    // with that many positional arguments - when nothing comes first: no
    // __getattribute__ anywhere, no instance field of that name, no class
    // before the owner in the MRO naming it (in its namespace, class_vars_
    // or its body). The entry is made by those same lookups (fill) and
    // checked on each use; anything else takes the general path.
    CallNode::MethodIC* methodICFill(CallNode* cn, const std::string& name, Node* cls, size_t na) {
        if (name.size() >= 2 && name[0] == '_' && name[1] == '_') return nullptr;   // dunders: callMethod's own first
        if (name == "slice") return nullptr;
        if (!cls || cls->type() != NodeType::CLASS) return nullptr;
        if (cls == preludeSuperNode()) return nullptr;            // super(...) proxies
        auto mit = mro_cache_.find(cls);
        if (mit == mro_cache_.end()) return nullptr;              // the general path works the MRO out first
        const std::vector<Node*>& mro = mit->second;
        std::vector<std::pair<Context*, uint32_t>> prefix;
        Node* owner = nullptr; Context* octx = nullptr; long slot = -1;
        for (Node* c : mro) {
            auto cit = class_ctx_map_.find((void*)c);
            Context* cc = (cit != class_ctx_map_.end() && cit->second && cit->second->container) ? cit->second : nullptr;
            if (cc) {
                long n = cc->container->index_of(name);
                if (n >= 0) { owner = c; octx = cc; slot = n; break; }
            }
            // getAttrValue's other places for this class: none may name it
            if (c->type() != NodeType::CLASS) return nullptr;
            auto* ccn = static_cast<ClassNode*>(c);
            if (class_vars_.count(ccn->name + "." + name) || classBodyAssigns(ccn, name)) return nullptr;
            if (cc) prefix.push_back({cc, cc->container->version()});
        }
        if (!owner || owner->type() != NodeType::CLASS) return nullptr;
        const Value& m = octx->container->slot_at((size_t)slot)->second;
        if (heapKind(m) != HK_FUNC) return nullptr;
        auto* fo = static_cast<nyheap::Func*>(m.value.o);
        Node* code = fo->code;
        if (!code || code->type() != NodeType::FUNCTION) return nullptr;
        auto* fn = static_cast<FunctionNode*>(code);
        std::string tag = fnTag(func_names, m.value.p);
        if (tag.rfind("__func__:", 0) != 0 || tag.find("__static__") != std::string::npos
            || tag.find("__classmethod__") != std::string::npos || tag.find("__property__") != std::string::npos)
            return nullptr;
        if (!direct_methods_.count(fn)) return nullptr;
        const std::vector<std::string>* names = simpleParams(fn);
        if (!names || names->size() != na + 1 || ((*names)[0] != "self" && (*names)[0] != "this")) return nullptr;
        if (!cn->mic) cn->mic.reset(new CallNode::MethodIC[CallNode::kMethodWays]);
        CallNode::MethodIC* e = nullptr;
        for (int w = 0; w < CallNode::kMethodWays && !e; w++)   // a stale or empty way first
            if (cn->mic[w].epoch != spec_epoch_ || cn->mic[w].by != this || !cn->mic[w].cls) e = &cn->mic[w];
        if (!e) { e = &cn->mic[cn->mic_next]; cn->mic_next = (uint8_t)((cn->mic_next + 1) % CallNode::kMethodWays); }
        fo->gc_flags |= nygc::F_KICREF;   // its death ends the epoch
        e->cls = (void*)cls; e->epoch = spec_epoch_; e->by = this;
        e->fn = fn; e->owner = owner; e->m_p = m.value.p; e->m_o = (void*)m.value.o;
        e->owner_ctx = octx; e->owner_slot = (uint32_t)slot;
        e->prefix = std::move(prefix);
        // __parent_class__: the interned string's entry (interned_ keeps it
        // for the executor's life, at a stable address)
        e->parent_name = nullptr;
        auto* ocn = static_cast<ClassNode*>(owner);
        if (!ocn->bases.empty()) {
            std::string pn = ocn->bases[0]->value();
            internString(pn);
            e->parent_name = &interned_.find(pn)->second;
        }
        // the scope's names - self, this, the parameters, __parent_class__ -
        // are distinct, so a fresh scope takes them without lookups
        bool ok = fn->names_distinct;
        for (size_t i = 1; ok && i < names->size(); i++) {
            const std::string& pn = (*names)[i];
            if (pn == "self" || pn == "this" || pn == "__parent_class__") ok = false;
        }
        e->append_ok = ok;
        return e;
    }
    // Whether none of these class namespaces holds `name`: a namespace
    // whose keys have not changed since (its version) still does not; one
    // whose keys changed is looked in, and its version taken again when it
    // still lacks the name.
    static bool namespacesLack(std::vector<std::pair<Context*, uint32_t>>& ns, const std::string& name) {
        for (auto& [c, ver] : ns) {
            const ContainerType* m = c->container;
            if (!m || m->version() == ver) continue;
            if (m->index_of(name) >= 0) return false;
            ver = m->version();
        }
        return true;
    }
    // ── obj.attr = v on an instance, through the target's cache (round 81) ──
    // setAttr for an instance whose class (and every class in its MRO)
    // holds nothing named attr and has no __setattr__: no hook, descriptor,
    // property or slot applies, and the value goes into the instance's
    // fields - which is all this does. The entry is made by setAttr's own
    // tests (fill) and its namespaces' keys checked on each use.
    AttributeNode::StoreIC* storeICFill(AttributeNode* an, const Value& obj, Node* cls) {
        const std::string& name = an->attr;
        if (name.size() >= 2 && name[0] == '_' && name[1] == '_') return nullptr;   // dunders: setAttr's own first
        if (name == "mro") return nullptr;                 // findClassMember's fallback to object's
        if (!cls || cls->type() != NodeType::CLASS || raw_attr_depth_ > 0) return nullptr;
        if (instanceAttrHook(obj, 0)) return nullptr;                             // a __setattr__
        if (!object_class_node_) object_class_node_ = classNodeByName("object");
        if (cls == object_class_node_) return nullptr;                            // object() takes no fields
        if (!slot_flags_.empty() && isDictless(obj)) return nullptr;              // __slots__ without __dict__
        auto mit = mro_cache_.find(cls);
        if (mit == mro_cache_.end()) return nullptr;
        std::vector<std::pair<Context*, uint32_t>> ns;
        for (Node* c : mit->second) {
            auto cit = class_ctx_map_.find((void*)c);
            if (cit == class_ctx_map_.end() || !cit->second || !cit->second->container) continue;
            if (cit->second->container->index_of(name) >= 0) return nullptr;      // a class holds the name
            ns.push_back({cit->second, cit->second->container->version()});
        }
        if (!an->sic) an->sic.reset(new AttributeNode::StoreIC[AttributeNode::kStoreWays]);
        AttributeNode::StoreIC* e = nullptr;
        for (int w = 0; w < AttributeNode::kStoreWays && !e; w++)
            if (an->sic[w].epoch != spec_epoch_ || an->sic[w].by != this || !an->sic[w].cls) e = &an->sic[w];
        if (!e) { e = &an->sic[an->sic_next]; an->sic_next = (uint8_t)((an->sic_next + 1) % AttributeNode::kStoreWays); }
        e->cls = (void*)cls; e->epoch = spec_epoch_; e->by = this;
        e->ns = std::move(ns);
        return e;
    }
    bool storeFast(AttributeNode* an, const Value& obj, const Value& val) {
        if (raw_attr_depth_ > 0) return false;
        auto* io = static_cast<nyheap::Inst*>(obj.value.o);
        void* cls = io->cls;
        Context* props = io->props;
        if (!props || !props->container || props->storeHook) return false;
        AttributeNode::StoreIC* e = nullptr;
        if (an->sic)
            for (int w = 0; w < AttributeNode::kStoreWays; w++) {
                AttributeNode::StoreIC& x = an->sic[w];
                if (x.cls == cls && x.epoch == spec_epoch_ && x.by == this) { e = &x; break; }
            }
        if (!e) {
            if (an->sic_skip) { an->sic_skip--; return false; }
            e = storeICFill(an, obj, (Node*)cls);
            if (!e) {
                if (an->sic_backoff < 7) an->sic_backoff++;
                an->sic_skip = (uint8_t)((1u << an->sic_backoff) - 1);
                return false;
            }
            an->sic_backoff = 0;
        }
        if (!namespacesLack(e->ns, an->attr)) { e->cls = nullptr; return false; }
        // the field: its slot from last time when it still holds it
        ContainerType* m = props->container;
        if (ContainerType::value_type* kv = m->slot_at_mut(an->store_hint); kv && kv->first == an->attr) { kv->second = val; return true; }
        long n = m->index_of(an->attr);
        if (n >= 0) { an->store_hint = (uint32_t)n; m->slot_at_mut((size_t)n)->second = val; return true; }
        (*m)[an->attr] = val;                              // a new field: the last slot
        an->store_hint = (uint32_t)(m->slot_end() - 1);
        return true;
    }
    // ── obj.attr answered by a class namespace, through the node's cache (round 81) ──
    // getAttrValue, for a class or an instance with no field of that name
    // (and no __getattribute__ anywhere), walks the class's MRO: in each
    // class its namespace, its class_vars_ entry and the assignments of its
    // body, until one names attr - then classNsResult makes the result. The
    // entry is made by those same lookups and remembers the namespace and
    // slot that answered and the namespaces before it (none naming attr,
    // their keys' versions); a hit gives the value found there to
    // classNsResult as the walk would. Dunder names are left to the general
    // path (its special cases come first).
    AttributeNode::LoadIC* classLoadFill(AttributeNode* an, void* cls, bool inst) {
        const std::string& name = an->attr;
        if (name.size() >= 2 && name[0] == '_' && name[1] == '_') return nullptr;
        // what getAttrValue takes cls for: a class (its own node)
        if (!cls || func_ast_nodes.count(cls) || instance_to_class.count(cls)) return nullptr;
        if (fnTag(func_names, cls).rfind("__class__:", 0) != 0) return nullptr;
        Node* cn = (Node*)cls;
        if (cn->type() != NodeType::CLASS) return nullptr;
        if (inst && cn == preludeSuperNode()) return nullptr;   // super(...) proxies
        auto mit = mro_cache_.find(cn);
        if (mit == mro_cache_.end()) return nullptr;            // the general path works the MRO out first
        std::vector<std::pair<Context*, uint32_t>> prefix;
        Node* owner = nullptr; Context* octx = nullptr; long slot = -1;
        for (Node* c : mit->second) {
            if (c->type() != NodeType::CLASS) return nullptr;
            auto cit = class_ctx_map_.find((void*)c);
            Context* cc = (cit != class_ctx_map_.end() && cit->second && cit->second->container) ? cit->second : nullptr;
            if (cc) {
                long n = cc->container->index_of(name);
                if (n >= 0) {
                    if (cc->container->slot_at((size_t)n)->second.type == ValueType::UNDEFINED) return nullptr;
                    owner = c; octx = cc; slot = n;
                    break;
                }
            }
            auto* ccn = static_cast<ClassNode*>(c);
            std::string key = ccn->name + "." + name;
            if (class_vars_.count(key)) return nullptr;
            if (ccn->body && (class_vars_deleted_.empty() || !class_vars_deleted_.count(key)) && classBodyAssigns(ccn, name)) return nullptr;
            if (cc) prefix.push_back({cc, cc->container->version()});
        }
        if (!owner) return nullptr;
        if (!an->lic) an->lic.reset(new AttributeNode::LoadIC());
        AttributeNode::LoadIC* e = an->lic.get();
        e->cls = cls; e->inst = inst; e->epoch = spec_epoch_; e->by = this;
        e->owner = owner; e->owner_ctx = octx; e->owner_slot = (uint32_t)slot;
        e->prefix = std::move(prefix);
        return e;
    }
    bool classLoadFast(AttributeNode* an, const Value& obj, Context* ctx, Value& out) {
        void* cls;
        bool inst;
        switch (heapKind(obj)) {
            case HK_INST: {
                auto* io = static_cast<nyheap::Inst*>(obj.value.o);
                // a field of that name answers first (evalAttribute's own
                // path did not take it: a property or data descriptor)
                if (io->props && io->props->container && io->props->container->index_of(an->attr) >= 0) return false;
                cls = io->cls; inst = true;
                break;
            }
            case HK_UNKNOWN: cls = obj.value.p; inst = false; break;
            default: return false;   // a str's or function's attributes: their own paths
        }
        AttributeNode::LoadIC* e = an->lic.get();
        if (!(e && e->cls == cls && e->inst == inst && e->epoch == spec_epoch_ && e->by == this)) {
            if (an->lic_skip) { an->lic_skip--; return false; }
            e = classLoadFill(an, cls, inst);
            if (!e) {
                if (an->lic_backoff < 7) an->lic_backoff++;
                an->lic_skip = (uint8_t)((1u << an->lic_backoff) - 1);
                return false;
            }
            an->lic_backoff = 0;
        }
        if (!namespacesLack(e->prefix, an->attr)) { e->cls = nullptr; return false; }
        const ContainerType::value_type* kv = e->owner_ctx->container ? e->owner_ctx->container->slot_at(e->owner_slot) : nullptr;
        if (!kv || kv->first != an->attr || kv->second.type == ValueType::UNDEFINED) { e->cls = nullptr; return false; }
        Value cv = kv->second;   // a copy, as the walk takes
        return classNsResult(cv, obj, cls, e->owner, ctx, true, out);
    }
    // The call itself, when the site's cache answers for this receiver;
    // false (nothing done) otherwise.
    bool methodFast(CallNode* cn, const std::string& name, const Value& obj, ArgBuf& argv, Context* ctx, Value& out, bool pend = false) {
        auto* io = static_cast<nyheap::Inst*>(obj.value.o);
        void* cls = io->cls;
        CallNode::MethodIC* e = nullptr;
        if (cn->mic)
            for (int w = 0; w < CallNode::kMethodWays; w++) {
                CallNode::MethodIC& x = cn->mic[w];
                if (x.cls == cls && x.epoch == spec_epoch_ && x.by == this) { e = &x; break; }
            }
        if (!e) {
            // a site where filling keeps finding nothing tries less often
            if (cn->mic_skip) { cn->mic_skip--; return false; }
            e = methodICFill(cn, name, (Node*)cls, argv.n);
            if (!e) {
                if (cn->mic_backoff < 7) cn->mic_backoff++;
                cn->mic_skip = (uint8_t)((1u << cn->mic_backoff) - 1);
                return false;
            }
            cn->mic_backoff = 0;
        }
        // the checks of each use: no instance field of that name, nothing
        // before the owner naming it, the owner still holding the method
        Context* props = io->props;
        if (props && props->container && props->container->index_of(name) >= 0) return false;
        if (!namespacesLack(e->prefix, name)) { e->cls = nullptr; return false; }
        const ContainerType* om = e->owner_ctx->container;
        const ContainerType::value_type* kv = om ? om->slot_at(e->owner_slot) : nullptr;
        if (!kv || kv->first != name || kv->second.type != ValueType::USERDATA
            || kv->second.value.p != e->m_p || (void*)kv->second.value.o != e->m_o) { e->cls = nullptr; return false; }
        // invokeMember, for a method with self: the method value held for
        // the call (callClassMethod's `m`), a scope over the one the class
        // was defined in, self (and this), the parameters, __parent_class__
        Value m = kv->second;
        auto* fn = static_cast<FunctionNode*>(e->fn);
        Node* owner = e->owner;
        auto* fo = static_cast<nyheap::Func*>(m.value.o);
        Context* cp = global_ctx;
        if (Context* sc = fo->scope) cp = sc->inClass && sc->parent ? sc->parent : sc;
        const std::vector<std::string>& names = fn->param_names;
        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
        CtxReaper _reap(this, fc);
        static const std::string kSelf = "self", kThis = "this", kParent = "__parent_class__";
        if (e->append_ok) {
            ContainerType* m2 = fc->container;
            m2->append_new(kSelf, Value(obj));
            if (names[0] == kThis) m2->append_new(kThis, Value(obj));
            for (size_t i = 1; i < names.size(); i++) m2->append_new(names[i], Value(argv[i - 1]));
            if (e->parent_name) m2->append_new(kParent, Value(*e->parent_name));
        } else {
            fc->defineByName(kSelf, obj);
            if (names[0] == kThis) fc->defineByName(kThis, obj);
            for (size_t i = 1; i < names.size(); i++) fc->defineByName(names[i], argv[i - 1]);
            if (e->parent_name) fc->defineByName(kParent, *e->parent_name);
        }
        OwnerScope _os(owner_stack_, owner);
        out = runFunctionBody(fn, fc, pend);   // round 82: pend, the call site's
        return true;
    }
    // Every argument a plain positional one (not name=v, *xs or **kw).
    static bool plainCallArgs(CallNode* cn) {
        for (auto& a : cn->args) {
            if (!a) return false;
            if (a->type() == NodeType::KEYWORD_ARG) return false;
            if (a->type() == NodeType::UNARY) {
                const std::string& op = static_cast<UnaryNode*>(a.get())->op;
                if (op == "*" || op == "**") return false;
            }
        }
        return true;
    }
    // The parameter names of a def or lambda whose parameters are all plain
    // names (no *args, **kw, bare * or /): bindParamsImpl / bindLambdaParams
    // then bind n positional arguments to them in order and nothing else.
    // nullptr for any other signature.
    static const std::vector<std::string>* simpleParams(Node* code) {
        auto analyse = [](const std::vector<node_ptr>& params, std::vector<std::string>& names) {
            names.clear();
            for (auto& p : params) {
                if (!p) return false;
                std::string n = p->value();
                if (n.empty() || n[0] == '*') return false;
                names.push_back(std::move(n));
            }
            return true;
        };
        auto distinct = [](const std::vector<std::string>& names) {
            for (size_t i = 0; i < names.size(); i++)
                for (size_t j = i + 1; j < names.size(); j++) if (names[i] == names[j]) return false;
            return true;
        };
        if (code->type() == NodeType::FUNCTION) {
            auto* fn = static_cast<FunctionNode*>(code);
            if (__builtin_expect(fn->simple_sig < 0, 0)) {
                fn->simple_sig = analyse(fn->params, fn->param_names) ? 1 : 0;
                fn->names_distinct = fn->simple_sig && distinct(fn->param_names);
            }
            return fn->simple_sig ? &fn->param_names : nullptr;
        }
        if (code->type() == NodeType::LAMBDA) {
            auto* lam = static_cast<LambdaNode*>(code);
            if (__builtin_expect(lam->simple_sig < 0, 0)) {
                lam->simple_sig = (lam->posonly == 0 && analyse(lam->params, lam->param_names)) ? 1 : 0;
                lam->names_distinct = lam->simple_sig && distinct(lam->param_names);
            }
            return lam->simple_sig ? &lam->param_names : nullptr;
        }
        return nullptr;
    }
    // Whether the simple parameters of `code` (simpleParams) are all distinct:
    // a fresh scope then takes them with append_new, no lookup first.
    static bool paramsDistinct(Node* code) {
        return code->type() == NodeType::FUNCTION ? static_cast<FunctionNode*>(code)->names_distinct
                                                  : static_cast<LambdaNode*>(code)->names_distinct;
    }

    void evalCallArgs(const std::vector<node_ptr>& raw_args, Context* ctx,
                      std::vector<Value>& call_args,
                      nyrt::OrderedKw<Value>& kw_args) {
        for (auto& a : raw_args) {
            if (a->type() == NodeType::KEYWORD_ARG) {
                // Named argument: name=value
                auto* kn = static_cast<KeywordArgNode*>((a).get());
                kw_args[kn->name] = evalNode(kn->val, ctx);
            } else if (a->type() == NodeType::UNARY) {
                auto* un = static_cast<UnaryNode*>((a).get());
                if (un->op == "*") {
                    // *iterable spread: unpack list/range into positional args
                    // (any iterable: a string's characters, a dict's keys,
                    // an object's __iter__ - a string was passed whole)
                    Value spread_val = evalNode(un->operand, ctx);
                    if ((spread_val.isCollectable() && spread_val.value.gc) || spread_val.type == ValueType::INTEGER
                        || isInstanceValue(spread_val) || isStringValue(spread_val)) {
                        for (auto& v : iterValues(spread_val, ctx)) call_args.push_back(v);
                    } else {
                        call_args.push_back(spread_val);
                    }
                } else if (un->op == "**") {
                    // **dict spread into kw_args
                    Value spread_val = evalNode(un->operand, ctx);
                    if (isInstanceValue(spread_val)) {
                        // a dict subclass's instance: its value; another
                        // mapping through keys() and [] (round 77: it was
                        // dropped without a word)
                        Value p;
                        if (any_payload_ && payloadOf(spread_val, p)) spread_val = p;
                        else {
                            std::vector<Value> a{spread_val};
                            spread_val = callFunctionValue(global_ctx->getByName("_ny_dict_merge"), a, ctx);
                        }
                    }
                    if (spread_val.isCollectable() && spread_val.value.gc) {
                        auto* cont = dynamic_cast<Container*>(spread_val.value.gc);
                        if (cont && cont->container)
                            for (auto& [k, v] : *cont->container)
                                if (!isInternalKey(k)) kw_args[nypy::key_payload(k)] = v;
                    }
                } else {
                    call_args.push_back(evalNode(a, ctx));
                }
            } else {
                call_args.push_back(evalNode(a, ctx));
            }
        }
    }

    // Helper: bind function params with *args/*kwargs support and keyword arg map
    void bindParams(FunctionNode* fn, std::vector<Value>& call_args, Context* fn_ctx, Context* eval_ctx,
                    void* callee_ptr = nullptr) {
        bindParamsKw(fn, call_args, {}, fn_ctx, eval_ctx, 0, callee_ptr);
    }
    // `callee_ptr` is the Value pointer the call was made through, when known.
    // If it names a bound method, the captured instance is supplied here as the
    // first positional argument.
    //
    // This is deliberately the ONLY place that does it. Previously each
    // invocation path re-supplied `self` itself, and three separate paths
    // (direct call, callFunctionValue, attribute-stored callable) each had to be
    // fixed in turn — a path that forgot produced no error, just arguments
    // shifted left and attribute reads yielding none. Every invocation must bind
    // parameters, so putting it here means a new call path cannot miss it.
    void bindParamsKw(FunctionNode* fn, std::vector<Value>& call_args,
                      const nyrt::OrderedKw<Value>& kw_args,
                      Context* fn_ctx, Context* eval_ctx, size_t skip_params = 0,
                      void* callee_ptr = nullptr) {
        std::vector<Value> bound_args;
        std::vector<Value>* argp = &call_args;
        if (callee_ptr && skip_params == 0) {
            auto bs = bound_self_.find(callee_ptr);
            if (bs != bound_self_.end()) {
                bound_args.reserve(call_args.size() + 1);
                bound_args.push_back(bs->second->self);
                for (auto& a : call_args) bound_args.push_back(a);
                argp = &bound_args;
            }
        }
        std::vector<Value>& args_in = *argp;
        bindParamsImpl(fn, args_in, kw_args, fn_ctx, eval_ctx, skip_params, callee_ptr);
    }
    // Default values, evaluated once when the def statement runs, in the
    // scope it runs in (Python's rule). They used to be evaluated at every
    // call, in the CALLER's scope: `n = 5; def f(x=n)` then `n = 10; f()`
    // gave 10, `def f(L=[])` got a new list each call, and `def f(i=i)` in a
    // loop read an undefined i.
    std::unordered_map<void*, std::vector<Value>> fn_defaults_val_;
    std::unordered_map<const Node*, std::vector<Value>> fn_defaults_node_;
    void captureDefaults(FunctionNode* fn, void* fn_ptr, Context* ctx) {
        bool any = false;
        for (auto& d : fn->defaults) if (d) { any = true; break; }
        if (!any) return;
        std::vector<Value> vals(fn->params.size(), UNDEFINED_VALUE);
        for (size_t i = 0; i < fn->params.size() && i < fn->defaults.size(); i++)
            if (fn->defaults[i]) vals[i] = evalNode(fn->defaults[i], ctx);
        fn_defaults_node_[fn] = vals;
        if (fn_ptr) fn_defaults_val_[fn_ptr] = std::move(vals);
    }
    Value paramDefault(FunctionNode* fn, size_t i, Context* eval_ctx, void* callee_ptr = nullptr) {
        if (callee_ptr) {
            auto it = fn_defaults_val_.find(callee_ptr);
            if (it != fn_defaults_val_.end() && i < it->second.size() && it->second[i].type != ValueType::UNDEFINED)
                return it->second[i];
        }
        auto nt = fn_defaults_node_.find(fn);
        if (nt != fn_defaults_node_.end() && i < nt->second.size() && nt->second[i].type != ValueType::UNDEFINED)
            return nt->second[i];
        return evalNode(fn->defaults[i], eval_ctx);
    }
    // Python's binding: positional arguments fill the plain parameters in
    // order, `*name` takes the rest, a bare `*` ends the positional ones,
    // keywords fill parameters by name, `**name` takes only the keywords no
    // parameter named (they were all copied into it), and a parameter given
    // neither takes its default. A keyword used to win over a positional
    // argument for the same parameter without consuming it, so the
    // positional one shifted onto the next parameter.
    // The name a function's call errors give: a __qualname__ set on it
    // (dataclasses' "Point.__init__"), else its name (round 77).
    std::unordered_map<const Node*, std::string> fn_qualname_;
    std::string fnShownName(FunctionNode* fn) {
        if (!fn_qualname_.empty()) {
            auto it = fn_qualname_.find(fn);
            if (it != fn_qualname_.end()) return it->second;
        }
        // its __qualname__, as CPython 3.10+ names it ("C.m() takes ...",
        // round 78: the bare name)
        if (!fn->qualname.empty()) return fn->qualname;
        return fn->name;
    }
    void bindParamsImpl(FunctionNode* fn, std::vector<Value>& call_args,
                        const nyrt::OrderedKw<Value>& kw_args,
                        Context* fn_ctx, Context* eval_ctx, size_t skip_params,
                        void* callee_ptr = nullptr) {
        size_t arg_idx = 0;
        bool star_seen = false, has_varargs = false;
        std::string kw_collect;
        std::unordered_set<std::string> named;
        std::vector<std::string> missing;
        std::string err;
        std::string posonly_kw;   // positional-only parameters given as keywords
        size_t min_pos = 0, max_pos = 0;
        for (size_t i = skip_params; i < fn->params.size(); i++) {
            std::string pname = fn->params[i]->value();
            if (pname == "*") { star_seen = true; continue; }
            if (pname.size() > 1 && pname[0] == '*' && pname[1] != '*') {
                has_varargs = true;
                // *args: the remaining positional args, as a tuple (Python's
                // type; it was a list, so `fmt % args` formatted the list)
                std::string real_name = pname.substr(1);
                Object* varargs = new Object((Runnable*)runner, "tuple", Type::LIST);
                int va_idx = 0;
                while (!star_seen && arg_idx < call_args.size()) {
                    varargs->set(std::to_string(va_idx++), call_args[arg_idx++]);
                }
                varargs->set("__len__", Value(va_idx));
                varargs->set("__tuple__", Value(1));
                fn_ctx->defineByName(real_name, Value((Collectable*)varargs));
                star_seen = true;
            } else if (pname.size() > 2 && pname[0] == '*' && pname[1] == '*') {
                kw_collect = pname.substr(2);
            } else {
                // A positional-only parameter is never bound by keyword: a
                // keyword of its name goes to **kwargs, or is an error.
                bool posonly = i < fn->posonly;
                if (!kw_args.empty() && !posonly) named.insert(pname);   // only read when keywords were passed
                auto kw_it = posonly ? kw_args.end() : kw_args.find(pname);
                if (posonly && !kw_args.empty() && kw_args.count(pname))
                    posonly_kw += (posonly_kw.empty() ? "" : ", ") + pname;
                bool has_default = i < fn->defaults.size() && fn->defaults[i];
                if (!star_seen) { max_pos++; if (!has_default) min_pos++; }
                if (!star_seen && arg_idx < call_args.size()) {
                    if (kw_it != kw_args.end() && err.empty())
                        err = fnShownName(fn) + "() got multiple values for argument '" + pname + "'";
                    fn_ctx->defineByName(pname, call_args[arg_idx++]);
                } else if (kw_it != kw_args.end()) {
                    fn_ctx->defineByName(pname, kw_it->second);
                } else if (has_default) {
                    fn_ctx->defineByName(pname, paramDefault(fn, i, eval_ctx, callee_ptr));
                } else {
                    fn_ctx->defineByName(pname, NONE_VALUE);
                    missing.push_back(pname);
                }
            }
        }
        if (!kw_collect.empty()) {
            Object* kwargs_obj = new Object((Runnable*)runner, "map", Type::MAP);
            // a dict key: a dunder name is a typed key (round 77: **kw lost __x__=1)
            for (auto& [k, v] : kw_args) if (!named.count(k)) kwargs_obj->set(nypy::key_of_str(k), v);
            fn_ctx->defineByName(kw_collect, Value((Collectable*)kwargs_obj));
        } else if (!posonly_kw.empty()) {
            err = fnShownName(fn) + "() got some positional-only arguments passed as keyword arguments: '" + posonly_kw + "'";
        } else if (err.empty()) {
            for (auto& [k, v] : kw_args)
                if (!named.count(k)) { err = fnShownName(fn) + "() got an unexpected keyword argument '" + k + "'"; break; }
        }
        // A call that does not fit raises TypeError, in Python's words (the
        // missing parameters were none and extra arguments were dropped).
        // A bound self counts, as Python counts it.
        if (err.empty())
            err = nython::ny_arity_error(fnShownName(fn), missing, min_pos + skip_params,
                                         has_varargs ? -1L : (long)(max_pos + skip_params),
                                         call_args.size() + skip_params);
        if (!err.empty()) throw std::string("__exc__:TypeError:" + err);
    }
    // The same for a lambda: binds its parameters (positional, keyword,
    // *args, defaults evaluated in `def_ctx`) and checks the call fits.
    void bindLambdaParams(LambdaNode* lam, std::vector<Value>& args,
                          const nyrt::OrderedKw<Value>& kw, Context* fc, Context* def_ctx,
                          void* callee_ptr = nullptr) {
        // a lambda bound as a method (makeBoundMethod) takes its instance
        // first; its defaults are kept under the lambda itself (round 81)
        if (callee_ptr && !bound_self_.empty()) {
            auto bs = bound_self_.find(callee_ptr);
            if (bs != bound_self_.end()) {
                std::vector<Value> with_self;
                with_self.reserve(args.size() + 1);
                with_self.push_back(bs->second->self);
                for (auto& a : args) with_self.push_back(a);
                bindLambdaParams(lam, with_self, kw, fc, def_ctx, bs->second->fn.value.p);
                return;
            }
        }
        // Python's whole parameter grammar - `*`, `/`, keyword-only
        // parameters, **kw, unexpected keywords - binds as a def's does
        // (round 77: `lambda *, k: k`, `lambda **kw: kw` and `lambda a, /, b`
        // were read as plain parameters). The signature is a FunctionNode
        // made once per lambda; its defaults are the ones evalLambda kept
        // under callee_ptr.
        bool simple = lam->posonly == 0;
        for (auto& p : lam->params) {
            const std::string& pn = p->value();
            if (!pn.empty() && pn[0] == '*') { simple = false; break; }
        }
        if (!simple || !kw.empty()) {
            if (!lam->sig) {
                auto sig = std::make_shared<FunctionNode>(lam->token(), "<lambda>", lam->body, false);
                for (auto& p : lam->params) sig->add(p);
                sig->defaults = lam->defaults;
                sig->posonly = lam->posonly;
                lam->sig = sig;
            }
            bindParamsImpl(static_cast<FunctionNode*>(lam->sig.get()), args, kw, fc, def_ctx, 0, callee_ptr);
            return;
        }
        const std::vector<Value>* made = nullptr;   // defaults evaluated by evalLambda
        if (callee_ptr) {
            auto it = fn_defaults_val_.find(callee_ptr);
            if (it != fn_defaults_val_.end()) made = &it->second;
        }
        size_t ai = 0, min_pos = 0, max_pos = 0;
        bool has_varargs = false;
        std::vector<std::string> missing;
        for (size_t i = 0; i < lam->params.size(); i++) {
            std::string pname = lam->params[i]->value();
            if (pname.size() > 1 && pname[0] == '*' && pname[1] != '*') {
                Object* varargs = new Object((Runnable*)runner, "tuple", Type::LIST);   // *args is a tuple
                int va_idx = 0;
                while (ai < args.size()) varargs->set(std::to_string(va_idx++), args[ai++]);
                varargs->set("__len__", Value(va_idx));
                varargs->set("__tuple__", Value(1));
                fc->defineByName(pname.substr(1), Value((Collectable*)varargs));
                has_varargs = true;
                continue;
            }
            bool has_default = i < lam->defaults.size() && lam->defaults[i];
            max_pos++; if (!has_default) min_pos++;
            auto kw_it = kw.find(pname);
            if (ai < args.size()) fc->defineByName(pname, args[ai++]);
            else if (kw_it != kw.end()) fc->defineByName(pname, kw_it->second);
            else if (has_default) {
                if (made && i < made->size() && (*made)[i].type != ValueType::UNDEFINED)
                    fc->defineByName(pname, (*made)[i]);
                else fc->defineByName(pname, evalNode(lam->defaults[i], def_ctx));
            }
            else { fc->defineByName(pname, NONE_VALUE); missing.push_back(pname); }
        }
        std::string err = nython::ny_arity_error("", missing, min_pos, has_varargs ? -1L : (long)max_pos, args.size());
        if (!err.empty()) throw std::string("__exc__:TypeError:" + err);
    }

    // Helper: bind function params with *args/*kwargs support

    // ── Recursion guard ─────────────────────────────────────────────────────
    // A tree-walking interpreter consumes real C++ stack per Nython call, so
    // runaway recursion crashed the process with SIGSEGV and no diagnostic.
    // (Easiest way to hit this: give a method the same name as a builtin and
    // call that builtin by bare name inside it — e.g. `def read_file(self, f)`
    // containing `read_file(f)`. The bare name resolves back to the method, so
    // it calls itself forever.) Convert that into a catchable Nython error.
    // Per OS thread: each thread has its own C++ stack (round 74).
    static inline thread_local int call_depth_ = 0;
    // round 80: sys.setrecursionlimit() sets it (nyrt::recursion_limit, the
    // VM's limit too); this engine keeps its old margin of 100 below it
    static int maxCallDepth() { int l = nyrt::recursion_limit(); return l > 200 ? l - 100 : l; }
    struct DepthGuard {
        int& d;
        explicit DepthGuard(int& x) : d(x) { ++d; }
        ~DepthGuard() { --d; }
        DepthGuard(const DepthGuard&) = delete;
        DepthGuard& operator=(const DepthGuard&) = delete;
    };

public:
    // ── Real profiling ───────────────────────────────────────────────────────
    // The IDE's PROFILER panel used to invent timings by scanning source text
    // for "def " lines. These are measured: every call routes through evalCall,
    // so counting and timing there yields real call counts and real wall time.
    //
    // self_ns excludes time spent inside nested calls (a caller's own cost),
    // total_ns includes it. Recursion is handled by only charging the outermost
    // activation of a frame, so a recursive function is not counted N times over.
    struct ProfEntry {
        long long calls = 0;
        long long total_ns = 0;
        long long self_ns = 0;
        int       depth = 0;      // active activations, for recursion handling
        // Allocations made by the function's own statements (self) - heap
        // objects, strings, string bytes. Nothing is reclaimed on the
        // interpreter, so these are what the function adds to memory for good.
        long long self_objs = 0;
        long long self_strs = 0;
        long long self_sbytes = 0;
    };
    static bool& profiling_enabled() { static bool e = false; return e; }
    std::map<std::string, ProfEntry> prof_;
    // Per OS thread (round 74): a frame's children run on the same thread.
    static inline thread_local long long prof_child_ns_ = 0;   // ns charged to callees of the current frame
    static inline thread_local long long prof_child_objs_ = 0; // allocations charged to callees, likewise
    static inline thread_local long long prof_child_strs_ = 0;
    static inline thread_local long long prof_child_sbytes_ = 0;

    struct ProfScope {
        NythonExecutor* ex; std::string name; bool on;
        std::chrono::steady_clock::time_point t0;
        long long saved_child;
        long long o0 = 0, s0 = 0, b0 = 0, saved_o = 0, saved_s = 0, saved_b = 0;
        ProfScope(NythonExecutor* e, const std::string& n) : ex(e), name(n) {
            on = profiling_enabled() && !name.empty();
            if (!on) return;
            auto& pe = ex->prof_[name];
            pe.calls++;
            pe.depth++;
            saved_child = ex->prof_child_ns_;
            ex->prof_child_ns_ = 0;
            saved_o = ex->prof_child_objs_; saved_s = ex->prof_child_strs_; saved_b = ex->prof_child_sbytes_;
            ex->prof_child_objs_ = 0; ex->prof_child_strs_ = 0; ex->prof_child_sbytes_ = 0;
            o0 = nython::gc::collectables_created(); s0 = strings_created(); b0 = string_bytes_created();
            t0 = std::chrono::steady_clock::now();
        }
        ~ProfScope() {
            if (!on) return;
            auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
                               std::chrono::steady_clock::now() - t0).count();
            auto& pe = ex->prof_[name];
            long long children = ex->prof_child_ns_;
            pe.self_ns += (elapsed - children);
            long long dobj = nython::gc::collectables_created() - o0;
            long long dstr = strings_created() - s0;
            long long dbyt = string_bytes_created() - b0;
            pe.self_objs += dobj - ex->prof_child_objs_;
            pe.self_strs += dstr - ex->prof_child_strs_;
            pe.self_sbytes += dbyt - ex->prof_child_sbytes_;
            pe.depth--;
            // Only the outermost activation contributes total time, otherwise a
            // recursive chain would count the same interval once per level.
            if (pe.depth == 0) pe.total_ns += elapsed;
            ex->prof_child_ns_ = saved_child + elapsed;
            ex->prof_child_objs_ = saved_o + dobj;
            ex->prof_child_strs_ = saved_s + dstr;
            ex->prof_child_sbytes_ = saved_b + dbyt;
        }
    };

    // "name,calls,total_ms,self_ms" sorted by self time — the shape the IDE
    // panel consumes, and readable enough to eyeball from a terminal.
    // With NY_PROFILE_SORT=alloc, rows are sorted by what each function's own
    // statements allocated (objects, then strings) instead of by time.
    std::string profile_report() {
        std::vector<std::pair<std::string, ProfEntry>> rows(prof_.begin(), prof_.end());
        const char* by = getenv("NY_PROFILE_SORT");
        bool by_alloc = by && std::string(by) == "alloc";
        std::sort(rows.begin(), rows.end(), [by_alloc](auto& a, auto& b){
            if (by_alloc) {
                long long wa = a.second.self_objs * 800 + a.second.self_strs * 64 + a.second.self_sbytes;
                long long wb = b.second.self_objs * 800 + b.second.self_strs * 64 + b.second.self_sbytes;
                if (wa != wb) return wa > wb;
            }
            return a.second.self_ns > b.second.self_ns; });
        std::ostringstream os;
        os << "name,calls,total_ms,self_ms,self_objects,self_strings,self_string_bytes\n";
        for (auto& [n, e] : rows) {
            os << n << "," << e.calls << ","
               << std::fixed << std::setprecision(3) << (double)e.total_ns / 1e6 << ","
               << std::fixed << std::setprecision(3) << (double)e.self_ns / 1e6 << ","
               << e.self_objs << "," << e.self_strs << "," << e.self_sbytes << "\n";
        }
        return os.str();
    }
    // Restore the surrounding access level: this block sits inside a public
    // section, and closing it with `private:` silently made everything after it
    // — callBuiltin included — private.
public:

    // ── Statement tracing (--trace) ─────────────────────────────────────────
    // Records every statement executed in the user's own files, with its call
    // depth, the enclosing function and that frame's variables, plus program
    // output and the uncaught exception, one JSON object per line. The IDE's
    // debugger replays the recording (lib/ide_debugger.ny), which is what lets
    // it step backwards as well as forwards and never hang mid-step. Off by
    // default; the only always-on cost is remembering the current statement
    // node, which also lets an uncaught error report where it happened.
    struct TraceState {
        FILE* f = nullptr;
        std::string main_file;
        std::string main_dir;
        long events = 0;
        long max_events = 60000;
        std::vector<std::string> fn_stack;
        std::set<std::string> globals;
        bool in_repr = false;
        bool capped = false;
    };
    static TraceState& tracer() { static TraceState t; return t; }
    static bool trace_on() { return tracer().f != nullptr; }
    // Per OS thread (round 74): written on every statement; a shared
    // shared_ptr assigned from two threads corrupted AST refcounts.
    static node_ptr& last_stmt() { static thread_local node_ptr p; return p; }
    // "file.ny:12" for the statement that was executing, "" if none.
    static std::string last_stmt_where() {
        auto& n = last_stmt();
        if (!n) return std::string();
        const auto& tk = n->tok();
        return tk.fileName() + ":" + std::to_string(tk.line());
    }

    struct TraceFrame {
        bool on;
        explicit TraceFrame(const std::string& name) {
            on = trace_on() && !tracer().in_repr;
            if (on) tracer().fn_stack.push_back(name.empty() ? std::string("<call>") : name);
        }
        ~TraceFrame() { if (on && !tracer().fn_stack.empty()) tracer().fn_stack.pop_back(); }
    };

    static std::string traceJson(const std::string& s) {
        std::string o = "\"";
        for (unsigned char c : s) {
            if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
            else if (c == '\n') o += "\\n";
            else if (c == '\t') o += "\\t";
            else if (c < 0x20) { char b[8]; snprintf(b, sizeof(b), "\\u%04x", c); o += b; }
            else o += (char)c;
        }
        return o + "\"";
    }

    bool traceIsUserFile(const std::string& file) {
        auto& T = tracer();
        if (file == T.main_file) return true;
        if (T.main_dir.empty() || file.rfind(T.main_dir, 0) != 0) return false;
        return file.find("/lib/") == std::string::npos;
    }

    // A short, side-effect-free rendering: no user __repr__ is ever called.
    std::string traceRepr(const Value& v, int depth) {
        switch (v.type) {
            case ValueType::NONE: return "none";
            case ValueType::UNDEFINED: return "undefined";
            case ValueType::BOOLEAN: return v.value.b ? "true" : "false";
            case ValueType::INTEGER: return std::to_string(bigint_to_i64(v.value.i));
            case ValueType::DOUBLE: { char b[64]; snprintf(b, sizeof(b), "%g", (double)v.value.d); return b; }
            default: break;
        }
        if (v.type == ValueType::USERDATA && v.value.p) {
            if (string_ptrs_.count(v.value.p) || isStringValue(v)) {
                std::string s = *static_cast<std::string*>(v.value.p);
                if (s.size() > 60) s = s.substr(0, 57) + "...";
                return "\"" + s + "\"";
            }
            auto fit = func_names.find(v.value.p);
            auto cit = instance_to_class.find(v.value.p);
            if (cit != instance_to_class.end()) {
                auto nit = func_names.find(cit->second);
                std::string cls = nit != func_names.end() ? funcDisplayName(nit->second) : std::string("object");
                if (cls.rfind("<class ", 0) == 0 && cls.size() > 8) cls = cls.substr(7, cls.size() - 8);
                return "<" + cls + " object>";
            }
            if (fit != func_names.end()) return funcDisplayName(fit->second);
            return "<value>";
        }
        if (v.isCollectable() && v.value.gc) {
            auto* cont = dynamic_cast<Container*>(v.value.gc);
            if (cont && cont->container) {
                if (depth > 1) return "[...]";
                auto len_it = cont->container->find("__len__");
                if (len_it != cont->container->end()) {
                    int len = (int)bigint_to_i64(len_it->second.value.i);
                    std::string s = "[";
                    for (int i = 0; i < len && i < 8; i++) {
                        if (i) s += ", ";
                        auto it = cont->container->find(std::to_string(i));
                        if (it != cont->container->end()) s += traceRepr(it->second, depth + 1);
                    }
                    if (len > 8) s += ", ... (" + std::to_string(len) + ")";
                    return s + "]";
                }
                std::vector<std::string> keys;
                for (auto& kv : *cont->container) keys.push_back(kv.first);
                std::sort(keys.begin(), keys.end());
                std::string s = "{";
                int n = 0;
                for (auto& k : keys) {
                    if (n >= 6) { s += ", ..."; break; }
                    if (n) s += ", ";
                    s += k + ": " + traceRepr((*cont->container)[k], depth + 1);
                    n++;
                }
                return s + "}";
            }
        }
        return "<value>";
    }

    inline void noteStatement(const node_ptr& st, Context* ctx) {
        nyconc::tick();          // GIL switch point (no-op until a thread exists)
        // A signal arrived: its handler runs here, on the main thread (round 77).
        if (__builtin_expect(nyconc::signal_pending(), 0)) ny_interp_check_signals(*this);
        nygc::safe_point();      // queued __del__ and due collections (one load)
        // Generators dropped while suspended are closed here, between
        // statements, not inside the destructor that dropped them.
        if (__builtin_expect(nygen::t_pending, 0)) nygen::run_pending(*this);
        if (__builtin_expect(tb_frames_held(), 0)) tbDropFrames();   // round 78
        last_stmt() = st;
        cur_stmt() = st.get();   // round 77: frames
        if (trace_on()) traceStatement(st, ctx);
        // sys.settrace's line event (round 79): one test of a thread-local
        // byte when no trace function is set
        if (__builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0)) pyEvLine(st.get(), true);
    }

    void traceStatement(const node_ptr& st, Context* ctx) {
        auto& T = tracer();
        if (!st || T.in_repr || T.capped) return;
        const auto& tk = st->tok();
        std::string file = tk.fileName();
        if (!traceIsUserFile(file)) return;
        if (T.events >= T.max_events) {
            T.capped = true;
            fprintf(T.f, "{\"cap\":%ld}\n", T.events);
            fflush(T.f);
            return;
        }
        T.events++;
        std::string fn = T.fn_stack.empty() ? std::string("<module>") : T.fn_stack.back();
        std::string out = "{\"f\":" + traceJson(file) + ",\"l\":" + std::to_string(tk.line())
                        + ",\"d\":" + std::to_string(T.fn_stack.size()) + ",\"fn\":" + traceJson(fn) + ",\"v\":{";
        if (ctx && ctx->container) {
            bool is_global = (ctx == global_ctx);
            std::vector<std::string> names;
            for (auto& kv : *ctx->container) {
                const std::string& nm = kv.first;
                if (nm.size() >= 2 && nm[0] == '_' && nm[1] == '_') continue;
                if (nm == "this") continue;   // alias of self
                if (is_global && !T.globals.count(nm)) continue;
                const Value& val = kv.second;
                if (val.type == ValueType::USERDATA && val.value.p && func_names.count(val.value.p)
                    && !instance_to_class.count(val.value.p) && !string_ptrs_.count(val.value.p)) continue;
                names.push_back(nm);
            }
            std::sort(names.begin(), names.end());
            T.in_repr = true;
            int n = 0;
            for (auto& nm : names) {
                if (n >= 40) break;
                if (n) out += ",";
                out += traceJson(nm) + ":" + traceJson(traceRepr((*ctx->container)[nm], 0));
                n++;
            }
            T.in_repr = false;
        }
        out += "}}\n";
        fputs(out.c_str(), T.f);
    }

    static void traceOutput(const std::string& text) {
        auto& T = tracer();
        if (!T.f || T.capped) return;
        std::string o = "{\"o\":" + traceJson(text) + "}\n";
        fputs(o.c_str(), T.f);
    }

    static void traceException(const std::string& msg) {
        auto& T = tracer();
        if (!T.f) return;
        std::string o = "{\"x\":" + traceJson(msg) + ",\"at\":" + traceJson(last_stmt_where()) + "}\n";
        fputs(o.c_str(), T.f);
        fflush(T.f);
    }

    // A builtin call some of whose arguments are generators their own
    // argument expressions just made (nygen::fresh), so nothing else refers
    // to them: lazy wrappers (zip, map, islice...) take them over, and a
    // builtin that consumes its argument (any, next, sum...) closes them when
    // it returns. Their finally blocks run then, as under CPython's reference
    // counting, and nothing is left suspended behind any(x for x in ...).
    Value callBuiltinTemps(const std::string& b, std::vector<Value>& args, Context* ctx,
                           CallNode* cn, uint64_t s0) {
        uint32_t mask = 0;
        size_t pos = 0;
        bool simple = true;
        std::vector<std::pair<size_t, node_ptr>> at;
        for (auto& a : cn->args) {
            if (a->type() == NodeType::KEYWORD_ARG) continue;
            if (a->type() == NodeType::UNARY) {
                auto un = static_pointer_cast<UnaryNode>(a);
                if (un->op == "*" || un->op == "**") { simple = false; break; }
            }
            at.push_back({pos++, a});
        }
        if (simple)
            for (auto& [i, a] : at)
                if (i < args.size() && i < 32 && nygen::fresh(args[i], a, call_depth_, s0)) mask |= 1u << i;
        if (!mask) return callBuiltin(b, args, ctx);
        bool consumes = nygen::consumes(b);
        auto close_temps = [&]() {
            if (!consumes) return;
            for (size_t i = 0; i < args.size() && i < 32; i++)
                if ((mask >> i) & 1u) nygen::close_temp(*this, args[i]);
        };
        nygen::t_fresh_args = mask;
        Value r;
        try { r = callBuiltin(b, args, ctx); }
        catch (...) { nygen::t_fresh_args = 0; close_temps(); throw; }
        nygen::t_fresh_args = 0;
        close_temps();
        return r;
    }

    // Best-effort display name for a call site: `f()`, `obj.m()` -> "obj.m".
    std::string callTargetName(CallNode* cn) {
        if (!cn || !cn->callee) return std::string();
        if (cn->callee->type() == NodeType::ATTRIBUTE) {
            auto at = static_pointer_cast<AttributeNode>(cn->callee);
            std::string base;
            if (at->object && at->object->type() == NodeType::VARIABLE)
                base = at->object->tok().value + ".";
            else if (at->object && at->object->type() == NodeType::SELF)
                base = "self.";
            return base + at->attr;
        }
        if (cn->callee->type() == NodeType::VARIABLE)
            return cn->callee->tok().value;
        return std::string();
    }

    // `pend` (round 82): the evaluator asking checks the pending flag right
    // after (evalP) - the fast paths below then let an exception come back
    // by it (from an argument, the receiver or the callee's body).
    Value evalCall(const node_ptr& node, Context* ctx, bool pend = false) {
        if (call_depth_ >= maxCallDepth())
            throw std::string("__exc__:RecursionError:maximum call depth exceeded ("
                              + std::to_string(maxCallDepth()) + ") — check for unintended "
                              "self-recursion, e.g. a method with the same name as a builtin");
        // Inside a generator the body runs on the generator's own stack;
        // near its end, the call continues on an extension stack (nygen).
        // round 81: so does a call near the end of the thread's own stack
        // (past the default depth): a raised recursion limit is reached on
        // segments of coroutine stack (it stopped near 1100 frames with
        // RecursionError, 8 MB at ~7 KB a frame)
        if (nycoro::stack_exhausted() || (call_depth_ > 800 && !nycoro::current() && nycoro::native_stack_exhausted()))
            return nygen::call_on_new_stack(*this, node, ctx);
        DepthGuard _depth_guard(call_depth_);
        auto* cn = static_cast<CallNode*>((node).get());
        // Zero cost when profiling is off: ProfScope short-circuits on the flag.
        ProfScope _prof(this, profiling_enabled() ? callTargetName(cn) : std::string());
        TraceFrame _trace_frame(trace_on() ? callTargetName(cn) : std::string());

        // Special handling for method calls: obj.method(args)
        if (cn->callee->type() == NodeType::ATTRIBUTE) {
            auto* attr = static_cast<AttributeNode*>((cn->callee).get());
            const std::string& method_name = attr->attr;   // (round 81: not copied - the AST outlives the call)

            // ── super.method(args) — call parent class method with current self ──
            // Match both `super.method()` and `super().method()` patterns
            bool is_super_call = attr->object->type() == NodeType::SUPER;
            if (!is_super_call && attr->object->type() == NodeType::CALL) {
                auto* call_node = static_cast<CallNode*>(attr->object.get());
                if (call_node->callee && call_node->callee->type() == NodeType::SUPER)
                    is_super_call = true;
            }
            // super(C, obj).m(...) / super(C, C2).m(...): explicit, inside a
            // method or not - m from the class after C in the MRO of obj's
            // class (or of C2) - round 77 (it returned none outside a method)
            if (is_super_call && attr->object->type() == NodeType::CALL
                && static_cast<CallNode*>(attr->object.get())->args.size() == 2) {
                auto* sc = static_cast<CallNode*>(attr->object.get());
                Value typ = evalNode(sc->args[0], ctx);
                Value recv = evalNode(sc->args[1], ctx);
                Node* owner = classNodeOfValue(typ);
                if (!owner) pyRaise("TypeError", "super() argument 1 must be a type, not " + typeNameOf(typ));
                Node* start = isInstanceValue(recv) ? classNodeOfInstance(recv) : classNodeOfValue(recv);
                if (!start || (start != owner && !classDerivesFrom(static_cast<ClassNode*>(start)->name, static_cast<ClassNode*>(owner)->name)))
                    pyRaise("TypeError", "super(type, obj): obj must be an instance or subtype of type");
                std::vector<Value> sargs; nyrt::OrderedKw<Value> skw;
                evalCallArgs(cn->args, ctx, sargs, skw);
                Value out;
                if (superCall(recv, owner, method_name, sargs, skw, ctx, out, start)) return out;
                pyRaise("AttributeError", "'super' object has no attribute '" + method_name + "'");
            }
            if (is_super_call && !owner_stack_.empty() && owner_stack_.back()) {
                // super().m(...): m from the class after the one defining the
                // running method, in the MRO of self's class, called with the
                // keyword arguments; its exceptions propagate. (Only the
                // first base of the class was searched, keyword arguments were
                // dropped and every exception was swallowed.)
                Value self_val = ctx->getByName("self");
                // def __call__(cls, ...) / def __new__(mcs, ...): the first
                // argument (round 77)
                if (self_val.type == ValueType::UNDEFINED || self_val.type == ValueType::NONE) {
                    Value fa = ctx->getByName("\x01first_arg");
                    if (fa.type != ValueType::UNDEFINED) self_val = fa;
                }
                std::vector<Value> sargs; nyrt::OrderedKw<Value> skw;
                evalCallArgs(cn->args, ctx, sargs, skw);
                Value out;
                if (superCall(self_val, owner_stack_.back(), method_name, sargs, skw, ctx, out)) return out;
                return NONE_VALUE;
            }
            if (is_super_call) {
                Value self_val = ctx->getByName("self");
                // Find parent class name from __parent_class__ (set by child init dispatch)
                std::string parent_name;
                try { parent_name = getStringValue(ctx->getByName("__parent_class__")); } catch (...) {}
                if (parent_name.empty()) {
                    // Fallback: get from instance's class's first base
                    if (self_val.type == ValueType::USERDATA && self_val.value.p) {
                        auto cit2 = instance_to_class.find(self_val.value.p);
                        if (cit2 != instance_to_class.end()) {
                            auto ppit = class_parent.find(cit2->second);
                            if (ppit != class_parent.end()) parent_name = ppit->second;
                        }
                    }
                }
                std::vector<Value> args; nyrt::OrderedKw<Value> kw_args;
                evalCallArgs(cn->args, ctx, args, kw_args);
                // super().__init__(...) reaching a builtin exception class.
                if ((method_name == "__init__" || method_name == "init") && !parent_name.empty()
                    && !classNodeByName(parent_name) && nython::ny_is_builtin_exc(parent_name)) {
                    setExceptionArgs(self_val, args);
                    return NONE_VALUE;
                }
                if (!parent_name.empty()) {
                    auto pcit = class_by_name.find(parent_name);
                    if (pcit != class_by_name.end()) {
                        Node* pnode = (Node*)pcit->second;
                        if (pnode && pnode->type() == NodeType::CLASS) {
                            auto* pcn = static_cast<ClassNode*>(pnode);
                            if (pcn->body && !memberDeleted(pcn, method_name)) {
                                for (auto& stmt : pcn->body->statements()) {
                                    if (stmt->type() != NodeType::FUNCTION) continue;
                                    auto* fn = static_cast<FunctionNode*>(stmt.get());
                                    if (fn->name != method_name) continue;
                                    Context* fn_ctx = new Context(runner, method_name, nullptr, nullptr, ctx);
                                    CtxReaper _reap_fn_ctx3513(this, fn_ctx);
                                    fn_ctx->defineByName("self", self_val);
                                    size_t ps = (!fn->params.empty() && fn->params[0]->value() == "self") ? 1 : 0;
                                    for (size_t i = ps; i < fn->params.size(); i++) {
                                        size_t ai = i - ps;
                                        if (ai < args.size()) fn_ctx->defineByName(fn->params[i]->value(), args[ai]);
                                        else if (i < fn->defaults.size() && fn->defaults[i])
                                            fn_ctx->defineByName(fn->params[i]->value(), paramDefault(fn, i, ctx));
                                        else fn_ctx->defineByName(fn->params[i]->value(), NONE_VALUE);
                                    }
                                    // Set parent chain for chained super() calls
                                    if (!pcn->bases.empty())
                                        fn_ctx->defineByName("__parent_class__", internString(pcn->bases[0]->value()));
                                    fn_ctx->defineByName("__instance__", self_val);
                                    return runFunctionBody(fn, fn_ctx);
                                }
                            }
                        }
                    }
                }
                return NONE_VALUE;
            }

            Value obj = evalNode(attr->object, ctx, pend);
            if (pend && raisedBy(obj)) return NONE_VALUE;   // round 82

            // Evaluate arguments
            std::vector<Value> args; nyrt::OrderedKw<Value> kw_args;
            // A method of an instance with plain arguments (round 81): the
            // arguments go on the C++ stack and the site's inline cache is
            // asked (methodFast); when it does not answer they move into
            // `args` and the general path goes on as before.
            if (astSpecOn() && !any_getattribute_ && heapKind(obj) == HK_INST) {
                if (__builtin_expect(cn->plain_args < 0, 0)) cn->plain_args = plainCallArgs(cn) ? 1 : 0;
                if (cn->plain_args && cn->args.size() < kFastArgs) {
                    ArgBuf argv;
                    for (auto& a : cn->args) {
                        argv.push(evalNode(a, ctx, pend));
                        if (pend && raisedBy(argv[argv.n - 1])) return NONE_VALUE;   // round 82: by the flag
                    }
                    {
                        Value out;
                        if (methodFast(cn, method_name, obj, argv, ctx, out, pend)) return out;
                    }
                    args.reserve(argv.n);
                    for (size_t i = 0; i < argv.n; i++) args.push_back(std::move(argv[i]));
                } else evalCallArgs(cn->args, ctx, args, kw_args);
            } else {
                evalCallArgs(cn->args, ctx, args, kw_args);
                // a str's, plain dict's or list's own method (round 81)
                if (astSpecOn() && !any_getattribute_ && !(nytrace::t_hooks & nytrace::PROFILE)) {
                    Value r;
                    if (builtinMethodFast(cn, obj, method_name, args, kw_args, ctx, r)) return r;
                }
            }

            // obj.m(...) on an object whose class defines __getattribute__:
            // m is what it gives (round 77)
            if (any_getattribute_ && getattributeHook(obj)) {
                Value target = hookedGetattr(obj, method_name, ctx);
                return callFunctionValue(target, args, ctx, &kw_args);
            }

            // Check class_ctx_map_ FIRST for decorated methods (e.g. @decorator on class method)
            // This ensures we call the decorated wrapper with self injected into *args.
            // (Decorated methods - functions a decorator returned into the
            // class namespace - are called by callMethod through the MRO.)

            // In Nython, everything is an object. Attributes can store callables
            // (functions, lambdas, closures). Check the attribute VALUE first;
            // if it is a callable, invoke it directly rather than as a named method.
            if (obj.type == ValueType::USERDATA && obj.value.p) {
                Context* pit_props = instPropsOf(obj);   // round 81: no table iterator kept (the table is hashed)
                if (pit_props) {
                    try {
                        Value attr_val = pit_props->getByName(method_name);
                        // An object with __call__ held in an attribute.
                        if (isInstanceValue(attr_val) && instanceHasMethod(attr_val, "__call__"))
                            return callMethod(attr_val, "__call__", args, ctx, &kw_args);
                        {
                            Value r;
                            if (callBoundMember(attr_val, args, &kw_args, ctx, r)) return r;
                        }
                        if (attr_val.type == ValueType::USERDATA && attr_val.value.p) {
                            auto fname_it = func_names.find(attr_val.value.p);
                            if (fname_it != func_names.end()) {
                                const std::string& fn_type = fname_it->second;
                                bool is_fn  = fn_type.find("__func__:") == 0;
                                bool is_lam = fn_type.find("__lambda__") == 0;
                                bool is_bi  = fn_type.find("__builtin__:") == 0;
                                // A builtin counts only when the instance really holds it:
                                // the lookup also finds global builtins, so c.hash()
                                // called hash() with no argument instead of the
                                // object protocol's hash.
                                if (is_bi) {
                                    bool own = false;
                                    pit_props->access_container_shared([&](ContainerType* c) { own = c && c->count(method_name); });
                                    if (!own) is_bi = false;
                                }
                                if (is_fn || is_lam || is_bi) {
                                    if (is_bi) return callBuiltinKw(fn_type.substr(12), args, &kw_args, ctx);
                                    // A bound method can be STORED in an attribute
                                    // (e.g. win.on_resize(self.on_resize) keeps it
                                    // in self._on_resize, then calls
                                    // self._on_resize(w, h)). Re-supply its captured
                                    // instance here too, or every argument shifts.
                                    // self is supplied by bindParamsKw via the callee pointer
                                    void* ast_ptr = attr_val.value.p;
                                    auto ast_it = func_ast_nodes.find(attr_val.value.p);
                                    if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
                                    Node* raw = (Node*)ast_ptr;
                                    if (raw->type() == NodeType::LAMBDA) {
                                        auto lam = static_cast<LambdaNode*>(raw);
                                        Context* cp = ctx;
                                        auto cit = closure_contexts.find(attr_val.value.p);
                                        if (cit != closure_contexts.end()) cp = scopeOf(cit->second);
                                        Context* fc = new Context(runner, "<lambda>", nullptr, nullptr, cp);
                                        CtxReaper _reap_fc3618(this, fc);
                                        bindLambdaParams(lam, args, kw_args, fc, cp, attr_val.value.p);
                                        return runLambdaBody(lam, fc);
                                    } else if (raw->type() == NodeType::FUNCTION) {
                                        auto fn = static_cast<FunctionNode*>(raw);
                                        Context* cp = ctx;
                                        auto cit = closure_contexts.find(attr_val.value.p);
                                        if (cit != closure_contexts.end()) cp = scopeOf(cit->second);
                                        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                                        CtxReaper _reap_fc3627(this, fc);
                                        // keyword arguments too (self.fn(*a, **kw) dropped them)
                                        bindParamsKw(fn, args, kw_args, fc, ctx, 0, attr_val.value.p);
                                        return runFunctionBody(fn, fc);
                                    }
                                }
                            }
                        }
                    } catch (...) { throw; }   // the call's exceptions propagate
                }
            }

            // A value stored as an attribute of a function: f.cache_info(),
            // f.register(int). It was looked for as a method of the function
            // and not found (AttributeError), though reading it worked.
            if (!func_attrs_.empty() && obj.type == ValueType::USERDATA && obj.value.p) {
                auto fa = func_attrs_.find(obj.value.p);
                if (fa != func_attrs_.end()) {
                    auto fit = fa->second.find(method_name);
                    if (fit != fa->second.end()) {
                        Value target = fit->second;   // kept while the call runs
                        return callFunctionValue(target, args, ctx, &kw_args);
                    }
                }
            }

            // Also check collectable dict containers (e.g. math module, namespace objects)
            if (obj.isCollectable() && obj.value.gc) {
                auto* cont = dynamic_cast<Container*>(obj.value.gc);
                if (cont && cont->container) {
                    auto attr_it = cont->container->find(method_name);
                    if (attr_it != cont->container->end() && !(nyrt::is_dict_method_name(method_name) && isPlainDict(cont))) {
                        Value attr_val = attr_it->second;
                        {
                            Value r;
                            if (callBoundMember(attr_val, args, &kw_args, ctx, r)) return r;
                        }
                        // a callable object held by a module or namespace: a
                        // staticmethod object (lib/time.ny's), a partial ...
                        // (round 77)
                        if (isInstanceValue(attr_val) && classNodeOfInstance(attr_val) == classNodeByName("staticmethod")) {
                            Value f = attrOf(attr_val, "__func__");   // the function, called directly
                            return callFunctionValue(f, args, ctx, &kw_args);
                        }
                        if (isInstanceValue(attr_val) && instanceHasMethod(attr_val, "__call__"))
                            return callMethod(attr_val, "__call__", args, ctx, &kw_args);
                        if (attr_val.type == ValueType::USERDATA && attr_val.value.p) {
                            auto fn_it = func_names.find(attr_val.value.p);
                            if (fn_it != func_names.end()) {
                                if (fn_it->second.find("__builtin__:") == 0) {
                                    std::string bn = fn_it->second.substr(12);
                                    if (!kw_args.empty() && isKwmapBuiltin(bn)) appendKwMap(args, kw_args);
                                    if (__builtin_expect(nytrace::t_hooks & nytrace::PROFILE, 0))   // math.sqrt(x): c_call ... (round 79)
                                        return pyProfileBuiltin(attr_val, [&]() { return callBuiltin(bn, args, ctx); });
                                    return callBuiltin(bn, args, ctx);
                                }
                                if (fn_it->second.find("__func__:") == 0 || fn_it->second.find("__lambda__") == 0) {
                                    void* ast_ptr = attr_val.value.p;
                                    auto ai = func_ast_nodes.find(attr_val.value.p);
                                    if (ai != func_ast_nodes.end()) ast_ptr = ai->second;
                                    Node* raw = (Node*)ast_ptr;
                                    if (raw && raw->type() == NodeType::FUNCTION) {
                                        auto fn = static_cast<FunctionNode*>(raw);
                                        Context* cp = ctx;
                                        auto ci = closure_contexts.find(attr_val.value.p);
                                        if (ci != closure_contexts.end()) cp = scopeOf(ci->second);
                                        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                                        CtxReaper _reap_fc3662(this, fc);
                                        bindParamsKw(fn, args, kw_args, fc, ctx, 0, attr_val.value.p);
                                        return runFunctionBody(fn, fc);
                                    }
                                    // a lambda a module or namespace holds (round 80:
                                    // `m.f = lambda: 1; m.f()` raised AttributeError)
                                    if (raw && raw->type() == NodeType::LAMBDA) return callFunctionValue(attr_val, args, ctx, &kw_args);
                                }
                            }
                        }
                    }
                }
            }

            // Fallback: evaluate the callee as a full expression (e.g. math.sqrt -> builtin USERDATA)
            // then invoke it directly. This handles namespace modules and function objects in dicts.
            {
                // `obj` above already holds the evaluated receiver. Evaluating
                // cn->callee here re-ran attr->object, so every receiver with a
                // side effect fired twice — and because the doubling compounds
                // through nesting, an n-deep method chain performed 2^n - 1
                // calls instead of n (v.add(1).add(1).add(1) incremented by 7).
                // The attribute of the receiver in hand (a builtin's method is
                // left to callMethod, not bound).
                Value callee_val;
                if (!getAttrValue(obj, method_name, ctx, callee_val, false)) callee_val = UNDEFINED_VALUE;
                // Only use the fallback for builtin functions stored in dict namespaces
                // (e.g. math.sqrt). For class methods (__func__), let callMethod handle
                // self-binding correctly.
                if (callee_val.type == ValueType::USERDATA && callee_val.value.p) {
                    auto fn_it = func_names.find(callee_val.value.p);
                    if (fn_it != func_names.end()) {
                        // On an instance the attribute read also finds global
                        // builtins; only one the instance holds is its member
                        // (c.hash() is the object protocol, not hash()).
                        bool stray = false;
                        if (fn_it->second.find("__builtin__:") == 0 && isInstanceVal(obj)) {
                            bool own = false;
                            auto pit2 = instance_properties.find(obj.value.p);
                            if (pit2 != instance_properties.end() && pit2->second)
                                pit2->second->access_container_shared([&](ContainerType* c) { own = c && c->count(method_name); });
                            stray = !own;
                        }
                        if (!stray && fn_it->second.find("__builtin__:") == 0) {
                            std::string bn = fn_it->second.substr(12);
                            if (!kw_args.empty() && isKwmapBuiltin(bn)) appendKwMap(args, kw_args);
                            return callBuiltin(bn, args, ctx);
                        }
                        // a runtime type object held as an attribute:
                        // types.MethodType(f, obj), types.NoneType() (round 77)
                        if (fn_it->second.rfind("__rtype__:", 0) == 0) return callFunctionValue(callee_val, args, ctx, &kw_args);
                        // int.__new__(cls, v), dict.__setitem__(d, k, v): the
                        // builtin type's mirror function, called (round 77)
                        if (isTypeObject(obj) && !classNodeOfValue(obj)
                            && (fn_it->second.rfind("__func__:", 0) == 0 || fn_it->second.rfind("__lambda__", 0) == 0))
                            return callFunctionValue(callee_val, args, ctx, &kw_args);
                        // Class value accessed via attribute (e.g. Outer.Inner()) -> instantiate
                        if (fn_it->second.find("__class__:") == 0) {
                            // as a call by name does: the metaclass's __call__,
                            // __new__, then __init__ (round 77: mod.C() skipped
                            // the first two, so types.NoneType() made an instance)
                            return instantiateClass(callee_val, args, kw_args, ctx);
                        }
                    }
                }            }

            // Inject keyword args for built-in list methods that accept them
            if (method_name == "sort" || method_name == "sorted") {
                auto rev_it = kw_args.find("reverse");
                if (rev_it != kw_args.end()) args.push_back(rev_it->second);
                auto key_it = kw_args.find("key");
                if (key_it != kw_args.end() && args.size() == 0) args.push_back(key_it->second);
                else if (key_it != kw_args.end()) args.insert(args.begin(), key_it->second);
            }
            // a builtin value's method (xs.append(1)): c_call ... for the
            // profile function, the bound method as its argument (round 79)
            if (__builtin_expect(nytrace::t_hooks & nytrace::PROFILE, 0) && !isInstanceVal(obj)
                && (isStringValue(obj) || bytesOf(obj) || (contOf(obj) && !classNodeOfValue(obj))) && !nytrace::no_c_call(method_name)) {
                Value bm;
                if (getAttrValue(obj, method_name, ctx, bm, true) && bm.type == ValueType::USERDATA)
                    return pyProfileBuiltin(bm, [&]() { return callMethod(obj, method_name, args, ctx, &kw_args); });
            }
            return callMethod(obj, method_name, args, ctx, &kw_args);
        }

        // super() / super(C, obj) used as a value: a proxy whose attributes
        // and methods come from the classes after C in the receiver's MRO,
        // as Python's (round 78: it was Nython's shorthand for calling the
        // parent's constructor, super(name, 4) - write super().__init__(name, 4)).
        if (cn->callee->type() == NodeType::SUPER) {
            Node* owner = nullptr; Value self;
            superArgs(cn, ctx, owner, self);
            return makeSuperProxy(owner, self, ctx);
        }

        Value callee = evalNode(cn->callee, ctx);

        // ── A plain function called with plain arguments (round 81) ──────
        // A def or lambda whose parameters are all plain names, given exactly
        // that many positional arguments: what the general path below does
        // for it - its arguments evaluated in order, a scope over the one it
        // closes over, each parameter bound - without the lookups in
        // func_names / func_ast_nodes / closure_contexts (the function's
        // object holds its code and scope), the argument vector, the
        // keyword map and the parameter analysis, which the nodes remember.
        if (heapKind(callee) == HK_FUNC) {
            if (__builtin_expect(cn->plain_args < 0, 0)) cn->plain_args = plainCallArgs(cn) ? 1 : 0;
            Node* code = static_cast<nyheap::Func*>(callee.value.o)->code;
            const size_t na = cn->args.size();
            const std::vector<std::string>* names = (cn->plain_args && code && na <= kFastArgs) ? simpleParams(code) : nullptr;
            if (names && names->size() == na && astSpecOn()) {
                ArgBuf argv;
                for (size_t i = 0; i < na; i++) {
                    argv.push(evalNode(cn->args[i], ctx, pend));
                    if (pend && raisedBy(argv[argv.n - 1])) return NONE_VALUE;   // round 82: by the flag
                }
                nyheap::Func* fo = static_cast<nyheap::Func*>(callee.value.o);
                Context* cp = fo->scope ? scopeOf(fo->scope) : ctx;
                const bool is_def = code->type() == NodeType::FUNCTION;
                Context* fc = is_def ? new Context(runner, static_cast<FunctionNode*>(code)->name, nullptr, nullptr, cp)
                                     : new Context(runner, "<lambda>", nullptr, nullptr, cp);
                CtxReaper _reap_fast(this, fc);
                // copied, not moved: the arguments stay referenced until the
                // call is over, as the general path's argument vector keeps them
                // (so what they release dies in the same order)
                if (paramsDistinct(code))   // a fresh scope, distinct names: appended
                    for (size_t i = 0; i < na; i++) fc->container->append_new((*names)[i], Value(argv[i]));
                else
                    for (size_t i = 0; i < na; i++) fc->defineByName((*names)[i], argv[i]);
                if (is_def) return runFunctionBody(static_cast<FunctionNode*>(code), fc, pend);
                return runLambdaBody(static_cast<LambdaNode*>(code), fc);
            }
        }

        // Evaluate arguments (handles keyword args, *spread, **spread)
        std::vector<Value> args;
        nyrt::OrderedKw<Value> kw_args;
        uint64_t gen_s0 = nygen::serial_now();
        evalCallArgs(cn->args, ctx, args, kw_args);

        // A number, a string, bytes or None is not callable (round 78: `1("x")`,
        // `"s"()`, `none()` gave none or "NameError: 'End'", and calling bytes
        // read them as a function node). A name that is bound nowhere still
        // goes on to the module-builtin fallback below.
        {
            bool not_callable = callee.type == ValueType::INTEGER || callee.type == ValueType::DOUBLE
                || callee.type == ValueType::BOOLEAN || bytesOf(callee)
                || (isStringValue(callee) && !func_names.count(callee.value.p));
            if (callee.type == ValueType::NONE && cn->callee && cn->callee->type() != NodeType::SUPER)
                not_callable = cn->callee->type() != NodeType::VARIABLE
                    || ctx->getByName(cn->callee->value()).type != ValueType::UNDEFINED;
            if (not_callable) pyRaise("TypeError", "'" + typeNameOf(callee) + "' object is not callable");
        }

        // Check for built-in functions
        std::string fname;
        if (callee.type == ValueType::USERDATA) {
            if (callee.value.p) {
                auto it = func_names.find(callee.value.p);
                if (it != func_names.end()) fname = it->second;
                else if (!string_ptrs_.count(callee.value.p)) {
                    // Try to cast as Node and get type
                    // Get the AST node from our mapping
                void* ast_ptr = callee.value.p;
                auto ast_it = func_ast_nodes.find(callee.value.p);
                if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
                Node* raw = (Node*)ast_ptr;
                    if (raw->type() == NodeType::FUNCTION) {
                        auto* fn = static_cast<FunctionNode*>(raw);
                        fname = "__func__:" + fn->name;
                    } else if (raw->type() == NodeType::LAMBDA) {
                        fname = "__lambda__";
                    }
                }
            } else {
                // nullptr = builtin marker
                auto it = func_names.find(nullptr);
                if (it != func_names.end()) fname = it->second;
            }
        }
        if (fname.empty()) fname = Value::token_default().value;   // round 81: a Value has no token of its own ("End")
        if (fname.find("__builtin__:") == 0) {
            std::string builtin = fname.substr(12);
            // Flatten kwargs for builtins that accept them (key=, reverse=, default=)
            // The core builtins (builtins/pycore.cpp) read their keyword
            // arguments by name. Flattening them into positional arguments
            // made min(a, b, key=f) look like min(a, b, f).
            static const std::unordered_set<std::string> kw_native = {
                "sorted", "min", "max", "sum", "enumerate", "round", "int", "dict", "pow",
                "format", "range", "zip", "map", "filter", "list", "tuple", "set", "str", "repr",
                "bytes", "bytearray"
            };
            if (kw_native.count(builtin)) {
                cur_kw_order_.clear();
                for (auto& an : cn->args)
                    if (an->type() == NodeType::KEYWORD_ARG) cur_kw_order_.push_back(static_pointer_cast<KeywordArgNode>(an)->name);
                KwScope ks(this, kw_args.empty() ? nullptr : &kw_args);
                if (__builtin_expect(nytrace::t_hooks & nytrace::PROFILE, 0) && !nytrace::no_c_call(builtin))   // c_call ... (round 79)
                    return pyProfileBuiltin(callee, [&]() { return gen_s0 != nygen::serial_now() ? callBuiltinTemps(builtin, args, ctx, cn, gen_s0) : callBuiltin(builtin, args, ctx); });
                if (gen_s0 != nygen::serial_now()) return callBuiltinTemps(builtin, args, ctx, cn, gen_s0);
                // round 82: its exception goes on by the flag from here (a
                // throw unwinds the builtin's frames only)
                if (pend) {
                    try { return callBuiltin(builtin, args, ctx); }
                    catch (std::string& e) { if (isLoopFlow(e)) throw; pendExc(std::move(e)); return NONE_VALUE; }
                }
                return callBuiltin(builtin, args, ctx);
            }
            static const std::unordered_set<std::string> kw_builtins = {
                "reduce"
            };
            if (!kw_args.empty() && kw_builtins.count(builtin)) {
                auto kit = kw_args.find("key");
                if (kit != kw_args.end()) args.push_back(kit->second);
                auto rit = kw_args.find("reverse");
                if (rit != kw_args.end()) args.push_back(rit->second);
                auto dit = kw_args.find("default");
                if (dit != kw_args.end()) args.push_back(dit->second);
                auto sit = kw_args.find("start");
                if (sit != kw_args.end()) args.push_back(sit->second);
            }
            // Builtins that take named options receive them as one trailing
            // map - the convention the VM's CALL_KW already uses for natives,
            // so the same implementation serves both engines (nyos::Args).
            if (!kw_args.empty() && isKwmapBuiltin(builtin)) {
                auto* kw = new Object((Runnable*)runner, "map", Type::MAP);
                for (auto& kv : kw_args) kw->set(kv.first, kv.second);
                // marks the map as keyword arguments (internal key: dict
                // reads and nyos::Args skip it)
                (*kw->container)["__kwargs__"] = Value(1);
                args.push_back(Value((Collectable*)kw));
            }
            if (__builtin_expect(nytrace::t_hooks & nytrace::PROFILE, 0) && !nytrace::no_c_call(builtin))   // c_call ... (round 79)
                return pyProfileBuiltin(callee, [&]() { return gen_s0 != nygen::serial_now() ? callBuiltinTemps(builtin, args, ctx, cn, gen_s0) : callBuiltin(builtin, args, ctx); });
            if (gen_s0 != nygen::serial_now()) return callBuiltinTemps(builtin, args, ctx, cn, gen_s0);
            if (pend) {   // round 82, as above
                try { return callBuiltin(builtin, args, ctx); }
                catch (std::string& e) { if (isLoopFlow(e)) throw; pendExc(std::move(e)); return NONE_VALUE; }
            }
            return callBuiltin(builtin, args, ctx);
        }
        // A builtin value's method read as a value (f = xs.append; f(1)).
        if (fname.rfind("__bmethod__:", 0) == 0) {
            Value r;
            if (callBoundMember(callee, args, &kw_args, ctx, r)) return r;
        }
        // type(None)(), types.MethodType(f, obj) ... (round 77)
        if (fname.rfind("__rtype__:", 0) == 0) {
            if (const nyrt::RuntimeType* rt = nyrt::runtime_type(fname.substr(10))) return runtimeTypeCall(*rt, args, &kw_args, ctx);
        }
        // Also check callee token for builtin (for print etc parsed as keywords)


        // Check for user-defined function (stored as USERDATA pointing to FunctionNode)
        if (callee.type == ValueType::USERDATA && callee.value.p) {
            // Bound method read off an instance (e.g. `win.run(self._main_loop)`):
            // restore the captured `self` as the first argument.
            // self is supplied by bindParamsKw via the callee pointer
            if (fname.find("__func__:") == 0 || fname.find("__lambda__") == 0) {
                // Get the AST node from our mapping
                void* ast_ptr = callee.value.p;
                auto ast_it = func_ast_nodes.find(callee.value.p);
                if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
                Node* raw = (Node*)ast_ptr;
                if (raw->type() == NodeType::FUNCTION) {
                    auto fn = static_cast<FunctionNode*>(raw);
                    // Use closure: parent is the context where function was defined
                    Context* closure_parent = ctx;
                    auto cit = closure_contexts.find(callee.value.p);
                    if (cit != closure_contexts.end()) closure_parent = scopeOf(cit->second);
                    Context* fn_ctx = new Context(runner, fn->name, nullptr, nullptr, closure_parent);
                    CtxReaper _reap(this, fn_ctx);
                    // Bind parameters with keyword arg and *args support
                    bindParamsKw(fn, args, kw_args, fn_ctx, ctx, 0, callee.value.p);
                    return runFunctionBody(fn, fn_ctx, pend);   // round 82: pend, the call site's
                } else if (raw->type() == NodeType::LAMBDA) {
                    auto lam = static_cast<LambdaNode*>(raw);
                    // Use closure context if available (for returned lambdas)
                    Context* closure_parent = ctx;
                    auto cit2 = closure_contexts.find(callee.value.p);
                    if (cit2 != closure_contexts.end()) closure_parent = scopeOf(cit2->second);
                    Context* fn_ctx = new Context(runner, "<lambda>", nullptr, nullptr, closure_parent);
                    CtxReaper _reap_fn_ctx3854(this, fn_ctx);
                    bindLambdaParams(lam, args, kw_args, fn_ctx, closure_parent, callee.value.p);
                    Value result = runLambdaBody(lam, fn_ctx);
                    return result;
                }
            }
        }

        // __call__ protocol: if callee is an instance with __call__ method, invoke it
        if (callee.type == ValueType::USERDATA && callee.value.p && !string_ptrs_.count(callee.value.p) &&
            fname.find("__instance__:") == 0 && instance_to_class.count(callee.value.p)) {
            if (!instanceHasMethod(callee, "__call__"))
                throw std::string("__exc__:TypeError:'" + shownClassName(instanceClassName(callee)) + "' object is not callable");
            Value call_result = callMethod(callee, "__call__", args, ctx, &kw_args);
            if (call_result.type != ValueType::NONE) return call_result;
            // __call__ returned none — still return it (it IS the result)
            // Check if __call__ method exists at all before returning NONE
            void* class_ptr2 = instance_to_class[callee.value.p];
            auto cctx2 = class_ctx_map_.find(class_ptr2);
            if (cctx2 == class_ctx_map_.end()) {
                Node* cn2 = (Node*)class_ptr2;
                cctx2 = class_ctx_map_.find((void*)cn2);
            }
            bool has_call = false;
            if (cctx2 != class_ctx_map_.end()) {
                try { Value v = cctx2->second->getByName("__call__"); has_call = (v.type != ValueType::UNDEFINED); } catch (...) {}
            }
            if (!has_call) {
                // Also check body
                Node* cn3 = (Node*)class_ptr2;
                if (cn3 && cn3->type() == NodeType::CLASS) {
                    for (auto& stmt : static_cast<ClassNode*>(cn3)->body->statements()) {
                        if (stmt->type() == NodeType::FUNCTION && static_cast<FunctionNode*>(stmt.get())->name == "__call__") {
                            has_call = true; break;
                        }
                    }
                }
            }
            if (has_call) return call_result;
        }

        // Class instantiation: __class__:Name
        if (callee.type == ValueType::USERDATA && callee.value.p && fname.find("__class__:") == 0)
            return instantiateClass(callee, args, kw_args, ctx);

        // A dict, list or namespace is not callable (the old Object::call
        // path threw a raw pointer here, which ended the process).
        if (callee.isCollectable() && callee.value.gc && contOf(callee))
            pyRaise("TypeError", "'" + typeNameOf(callee) + "' object is not callable");

        // Final fallback: if fname looks like a module builtin (contains '_' and callee was
        // unresolved), try dispatching through callBuiltin. This handles gui_*, os_*, etc.
        // functions that were not individually registered via registerBuiltin().
        if (!fname.empty() && callee.type == ValueType::NONE
            && fname.find("__") != 0   // not a dunder
            && fname.find('_') != std::string::npos) {  // contains underscore = module builtin pattern
            Value r = callBuiltin(fname, args, ctx);
            if (r.type != ValueType::NONE) return r;
            // return NONE even from callBuiltin so gui_clear() etc. still return none
            return NONE_VALUE;
        }

        // Calling something that does not exist used to return none and carry on.
        // `print(totally_undefined_fn(1))` printed "none" and the next statement
        // ran, so a typo in a method name produced a wrong answer instead of an
        // error — the same silent-failure class as the import bug in round 46,
        // and far harder to find because there is no diagnostic at all.
        //
        // Raise a located NameError instead. The token carries file, line and
        // column, so the message can say exactly where the call is.
        {
            // Use the callee's own token: `fname` is not the called name at this
            // point in the fallthrough, and reporting it named the wrong thing
            // ("'End' is not defined") at the wrong column.
            std::string called = fname;
            Token t = cn->token();
            if (cn->callee) {
                t = cn->callee->token();
                if (cn->callee->type() == NodeType::VARIABLE) called = t.value;
                else if (cn->callee->type() == NodeType::ATTRIBUTE)
                    called = static_pointer_cast<AttributeNode>(cn->callee)->attr;
            }
            if (called.empty()) return NONE_VALUE;

            // Only report a name that is absent EVERYWHERE. This fallthrough is
            // also reached for names that do resolve by another route -- classes
            // registered by an imported module, functions reached through the
            // builtin bridge -- and raising there broke 15 working examples on
            // the first attempt. Silence for a resolvable name is the lesser
            // error; a false NameError stops a correct program.
            if (builtin_set.count(called)) return NONE_VALUE;
            if (ctx && ctx->getByName(called).type != ValueType::UNDEFINED)
                return NONE_VALUE;
            for (auto& kv : func_names) {
                const std::string& n = kv.second;
                if (n == called
                    || (n.rfind("__func__:", 0) == 0  && n.substr(9)  == called)
                    || (n.rfind("__class__:", 0) == 0 && n.substr(10) == called)
                    || (n.rfind("__builtin__:", 0) == 0 && n.substr(12) == called))
                    return NONE_VALUE;
            }
            std::string where = " at line " + std::to_string(t.line())
                              + ", column " + std::to_string(t.column());
            std::string hint = suggestName(called);
            if (!hint.empty()) hint = "  (did you mean '" + hint + "'?)";
            throw std::string("__exc__:NameError:'" + called
                              + "' is not defined" + where + hint);
        }

        return NONE_VALUE;
    }

    // Closest known name by edit distance, for "did you mean" hints. Only
    // suggests when the candidate is genuinely close, so a wrong guess does not
    // send someone chasing an unrelated identifier.
    std::string suggestName(const std::string& want) {
        size_t best = std::string::npos;
        std::string bestName;
        auto consider = [&](const std::string& cand) {
            if (cand.empty() || cand.find("__") == 0) return;
            size_t la = want.size(), lb = cand.size();
            if (la > lb + 3 || lb > la + 3) return;
            std::vector<size_t> prev(lb + 1), cur(lb + 1);
            for (size_t j = 0; j <= lb; ++j) prev[j] = j;
            for (size_t i = 1; i <= la; ++i) {
                cur[0] = i;
                for (size_t j = 1; j <= lb; ++j) {
                    size_t cost = (want[i-1] == cand[j-1]) ? 0 : 1;
                    cur[j] = std::min({prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost});
                }
                prev = cur;
            }
            size_t d = prev[lb];
            if (d < best) { best = d; bestName = cand; }
        };
        for (auto& kv : func_names) {
            if (!module_owned_.empty() && module_owned_.count(kv.first)) continue;
            const std::string& n = kv.second;
            if (n.rfind("__func__:", 0) == 0) consider(n.substr(9));
            else if (n.rfind("__class__:", 0) == 0) consider(n.substr(10));
        }
        for (auto& b : builtin_set) consider(b);
        if (best <= 2 && best != std::string::npos) return bestName;
        return std::string();
    }

    std::vector<std::unique_ptr<std::string>> instance_store;
    // ── Bound methods ───────────────────────────────────────────────────────
    // When a method is read off an instance as a VALUE (e.g. `cb = obj.method`,
    // or `win.run(self._main_loop)`) rather than called immediately, we must
    // remember which instance it came from. Without this, `self` is never
    // supplied at call time and every argument shifts left by one:
    //     obj.m(a, b)  ->  self=obj,  x=a,    y=b     (correct)
    //     f = obj.m; f(a, b)  ->  self=a, x=b, y=none (silently wrong)
    // That shift is invisible — attribute reads on the wrong `self` just yield
    // none — so it corrupts callback-driven code without raising an error.
    std::vector<std::unique_ptr<std::string>> bound_store_;   // unused since round 75
    // bound-method ptr -> its heap object (which holds the instance); not
    // owning: the object removes its entries when it is freed.
    std::unordered_map<void*, nyheap::Bound*> bound_self_;
    // (method ptr, instance ptr) -> binding, so re-reading the same method off
    // the same object reuses one binding while it is alive.
    std::map<std::pair<void*, void*>, nyheap::Bound*> bound_cache_;
    // Hashed (round 81; never iterated, so their order never showed): a
    // tree lookup per attribute access cost log2(live instances) steps.
    std::unordered_map<void*, void*> instance_to_class; // instance ptr -> class node ptr
    std::unordered_map<void*, Context*> instance_properties;
    std::map<std::string, void*> class_by_name; // className -> class node ptr
    std::vector<std::string> super_parent_stack; // for chained super() calls
    std::map<void*, std::string> class_parent; // class node ptr -> parent class name
    std::unordered_map<void*, Value> exc_instance_map_; // raised instance ptr -> Value
    std::map<std::string, Value> class_vars_; // "ClassName.varName" -> Value (shared class-level variables)
    std::unordered_set<std::string> class_vars_deleted_;   // "ClassName.varName" deleted (round 77)
    // `del C.m` removed m from the class: its def in the class body is not
    // found again (round 81)
    bool memberDeleted(const ClassNode* cn, const std::string& n) const {
        return !class_vars_deleted_.empty() && class_vars_deleted_.count(cn->name + "." + n);
    }
    std::map<void*, Context*> class_ctx_map_; // class node ptr -> evaluated class body context (for decorators); owns a reference
    void setClassContext(void* class_node, Context* c) {
        nygc::incref(c);
        specInvalidate();   // round 81: the method caches remember class namespaces
        Context*& slot = class_ctx_map_[class_node];
        Context* old = slot;
        slot = c;
        if (old) nygc::decref(old);
    }


    // Public (struct default) so the VM builtin bridge can dispatch by name.
    // A path-like argument (an object with __fspath__, such as a
    // pathlib.Path) given to a builtin that takes paths is passed as the
    // string its __fspath__ returns, positionally or as a keyword argument
    // (nyrt::takes_paths).
    void fspathArgs(std::vector<Value>& args, Context* ctx) {
        auto conv = [&](Value& v) {
            if (!isInstanceValue(v) || !instanceHasMethod(v, "__fspath__")) return;
            std::vector<Value> none;
            v = callMethod(v, "__fspath__", none, ctx);
        };
        for (auto& a : args) {
            conv(a);
            Container* c = contOf(a);
            if (c && c->container->count("__kwargs__"))
                for (auto& kv : *c->container) conv(kv.second);
        }
    }

    Value callBuiltin(const std::string& name_orig, std::vector<Value>& args, Context* ctx) {
        // an instance of a class deriving from a builtin type is its value
        // to a builtin (round 77) - but not to the ones asking for its class,
        // dunders or identity, or storing it (nyrt::payload_transparent)
        if (any_payload_ && !args.empty()) unwrapBuiltinArgs(name_orig, args);
        // a range or a dict view given to one of Nython's own flat natives is
        // the list of its values, as before round 78 (nyrt::takes_range_objects)
        if (rv_made_ && !args.empty() && !nyrt::takes_range_objects(name_orig)) rangeArgsToLists(args);
        if (!args.empty() && nyrt::takes_paths(name_orig)) fspathArgs(args, ctx);
        // islice/take, and iter/next/any/all/zip/map/filter/enumerate given a
        // generator: lazy (src/NyGen.cpp).
        // Round 78: zip/map/filter/enumerate are lazy over every iterable.
        if (nygen::builtin_candidate(name_orig, args) || nygen::lazy_builtin_name(name_orig)) {
            Value r;
            if (nygen::builtin(*this, name_orig, args, ctx, r)) return r;
        }
        {
            Value r;
            if (iterableBuiltin(name_orig, args, ctx, r)) return r;
            if (gcBuiltin(name_orig, args, r)) return r;
            if (name_orig.find('.') != std::string::npos && typeMemberCall(name_orig, args, ctx, r)) return r;
        }
        if (name_orig.rfind("__prop_setter__:", 0) == 0) {
            // The getter, held since `prop.setter` was read: the def that
            // follows rebinds the property's name, which used to leave the
            // getter unreferenced (and its address free for the next def).
            Value getter;
            auto pt = prop_setter_target_.find(name_orig);
            if (pt != prop_setter_target_.end()) { getter = pt->second; prop_setter_target_.erase(pt); }
            else {
                uintptr_t gp = 0;
                std::istringstream iss(name_orig.substr(16));
                iss >> std::hex >> gp;
                getter = ownedValue(reinterpret_cast<void*>(gp));
            }
            if (!args.empty()) prop_setters_[getter.value.p] = args[0];
            return getter;
        }
        // ── Exception type constructors ─────────────────────────────────────────
        // ── property() and staticmethod() ─────────────────────────────────────
        if (name_orig == "property") {
            // property(fn) — tag the function value with __property__ marker
            any_property_ = true;
            if (!args.empty() && args[0].type == ValueType::USERDATA && args[0].value.p) {
                func_names[args[0].value.p] += "__property__"; specInvalidate();   // round 81: a cached method may change kind
                return args[0];
            }
            return NONE_VALUE;
        }
        if (name_orig == "staticmethod") {
            // staticmethod(fn) — tag with __static__ so it's called without self
            if (!args.empty() && args[0].type == ValueType::USERDATA && args[0].value.p) {
                func_names[args[0].value.p] += "__static__"; specInvalidate();
                return args[0];
            }
            return NONE_VALUE;
        }
        if (name_orig == "classmethod") {
            // classmethod(fn) — tag with __classmethod__
            if (!args.empty() && args[0].type == ValueType::USERDATA && args[0].value.p) {
                func_names[args[0].value.p] += "__classmethod__"; specInvalidate();
                return args[0];
            }
            return NONE_VALUE;
        }
        static const std::unordered_set<std::string> exc_types_ = {
            "Exception","BaseException","Error",
            "ValueError","TypeError","KeyError","IndexError","AttributeError",
            "NameError","RuntimeError","IOError","OSError","FileNotFoundError",
            "ZeroDivisionError","OverflowError","MemoryError","RecursionError",
            "StopIteration","GeneratorExit","SystemExit","KeyboardInterrupt",
            "AssertionError","NotImplementedError","PermissionError","TimeoutError",
            "IsADirectoryError","NotADirectoryError","FileExistsError","ChildProcessError",
            "ProcessLookupError","InterruptedError","BlockingIOError","ConnectionError",
            "BrokenPipeError","ConnectionRefusedError","ConnectionResetError",
            "LookupError","ArithmeticError","EOFError","ImportError","ModuleNotFoundError",
            "UnicodeError","UnicodeDecodeError","UnicodeEncodeError","UnicodeTranslateError",
            "ConnectionAbortedError","gaierror","herror","StopAsyncIteration",
            "SSLError","SSLCertVerificationError","SSLEOFError","SSLZeroReturnError",
            "SSLWantReadError","SSLWantWriteError","SSLSyscallError"
        };
        if (exc_types_.count(name_orig)) {
            // Create exception Value tagged as "__exc__:TypeName:message"
            std::string msg = args.empty() ? "" : args[0].type == ValueType::USERDATA
                ? getStringValue(args[0]) : args[0].toString();
            // Store as a special tagged string value so evalRaise can extract type
            return makeStringValue("__exc__:" + name_orig + ":" + msg);
        }
        // ── Name normalisation aliases ─────────────────────────────────────────
        std::string name = name_orig;
        if (name == "regex_match")   name = "re_match";
        if (name == "regex_replace") name = "re_sub";
        if (name == "regex_findall") name = "re_findall";
        if (name == "regex_split")   name = "re_split";

        // ── Module dispatch (try each module in priority order) ────────────────
        Value result;
        // lib/random.ny's generator and lib/json's codec (builtins/pyrandom.cpp,
        // pyjson.cpp: _mt_*, _json_*) are called in hot loops: straight to them.
        if (name.size() > 4 && name[0] == '_' && (name[1] == 'm' || name[1] == 'j')) {
            result = dispatch_pyrandom(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
            result = dispatch_pyjson(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        }
        // isinstance: what dispatch_tensor does with it, without the ~600
        // names compared on the way (the dispatchers before it know no
        // isinstance; round 81)
        if (name.size() == 10 && name == "isinstance") return builtin_isinstance(*this, args, ctx);
        // Shared tensor kernels first: they replace the older per-module
        // implementations of the same names (see include/NyTensor.hpp).
        result = dispatch_nt(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        // The Python core builtins (builtins/pycore.cpp).
        result = dispatch_pycore(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_lang(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_core(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_tensor(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_audio(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_string(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_io(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_network(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        if (name.size() > 5 && name[0] == '_') {
            // the round 77 socket and TLS layers (builtins/net.cpp, tls.cpp)
            result = dispatch_net(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
            result = dispatch_tls(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
            result = dispatch_hash(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
            if (name.compare(0, 4, "_re_") == 0) return dispatch_re(*this, name, args, ctx);
        }
        if (name == "os_urandom") return dispatch_hash(*this, name, args, ctx);
        if (name.compare(0, 5, "math_") == 0) {
            result = dispatch_pymath(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        }
        result = dispatch_math(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_os(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_data(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_threading(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_gui(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_text(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        return NONE_VALUE;
    }


    // ─── COLLECTIONS ────────────────────────────────────────────────────
    Value evalList(const node_ptr& node, Context* ctx) {
        // A TupleNode is not a ListNode (only laid out alike): read the
        // elements through the node's own type.
        bool is_tuple = (node->type() == NodeType::TUPLE);
        const std::vector<node_ptr>& elements = is_tuple
            ? static_pointer_cast<TupleNode>(node)->elements
            : static_pointer_cast<ListNode>(node)->elements;
        auto* obj = new Object((Runnable*)runner, is_tuple ? "tuple" : "list", Type::LIST);
        // round 81: the keys are new and distinct - each appended at once
        // (Object::set inserted it after looking for it; the same entries in
        // the same order)
        ContainerType& m = *obj->container;
        m.reserve(elements.size() + 2);
        int idx = 0;
        char buf[24];
        for (auto& el : elements) {
            Value v = evalNode(el, ctx);
            m.append_new(std::string(decKey(idx++, buf)), std::move(v));
        }
        m.append_new(std::string("__len__"), Value((int)idx));
        if (is_tuple) m.append_new(std::string("__tuple__"), Value(1));
        return Value((Collectable*)obj);
    }

    Value evalMap(const node_ptr& node, Context* ctx) {
        auto* mn = static_cast<MapNode*>((node).get());
        auto* cont = new Object((Runnable*)runner, "map", Type::MAP);
        for (auto& e : mn->entries) {
            auto* me = static_cast<MapEntryNode*>((e).get());
            Value key = evalNode(me->key, ctx);
            Value val = evalNode(me->val, ctx);
            // Use string key for map storage
            dictSet(cont, key, val);
        }
        return Value((Collectable*)cont);
    }

    Value evalRange(const node_ptr& node, Context* ctx) {
        auto rn = static_pointer_cast<RangeNode>(node);
        Value start = evalNode(rn->start, ctx);
        Value end = evalNode(rn->end_node, ctx);
        // Build the SAME shape a list literal builds: an Object with string
        // indices and a __len__. It previously built a Container with
        // write(key,value) pairs, which len() understood but for-loops and the
        // printer did not — `1..4` had the right three elements and still
        // iterated zero times and printed as a map.
        auto* obj = new Object((Runnable*)runner, "list", Type::LIST);
        int idx = 0;
        if (start.type == ValueType::INTEGER && end.type == ValueType::INTEGER) {
            int64_t s = bigint_to_i64(start.value.i), e = bigint_to_i64(end.value.i);
            int64_t step = rn->step ? bigint_to_i64(evalNode(rn->step, ctx).value.i)
                                    : (s <= e ? 1 : -1);
            if (step > 0)      for (auto i = s; i < e; i += step) obj->set(std::to_string(idx++), Value(bigint(i)));
            else if (step < 0) for (auto i = s; i > e; i += step) obj->set(std::to_string(idx++), Value(bigint(i)));
        }
        obj->set("__len__", Value((int)idx));
        return Value((Collectable*)obj);
    }

    // ─── ATTRIBUTE / SUBSCRIPT ──────────────────────────────────────────
    // obj.attr. Reading an attribute the object does not have raises
    // AttributeError, whatever the object (round 75: it read none, and
    // library code probed optional attributes that way). Graceful forms:
    // getattr(o, n, d), hasattr, `o?.attr` and `o?.attr ?? d`.
    // `pend` (round 82): the evaluator asking checks the pending flag right
    // after (evalP) - a missing attribute raises by it.
    Value evalAttribute(const node_ptr& node, Context* ctx, bool pend = false) {
        auto* an = static_cast<AttributeNode*>(node.get());
        {
            Value sv;
            if (an->object && an->object->type() == NodeType::CALL && superAttribute(an, ctx, sv)) return sv;   // super().x (round 77)
        }
        Value obj = evalNode(an->object, ctx);
        // The common read, an instance's own field, straight from its
        // namespace (a Value is not cheap to copy: it carries a Token) -
        // unless its class defines __getattribute__ (round 77).
        if (obj.type == ValueType::USERDATA && obj.value.p && !(any_getattribute_ && getattributeHook(obj))) {
            Context* pc = instPropsOf(obj);
            if (pc && pc->container) {
                // Round 81: the field's slot in the instance's scope, cached
                // in the node and checked (the key still there) before use -
                // instances of a class mostly lay their fields out alike.
                const auto* kv = fieldAt(pc->container, an->attr, an->slot_hint);
                // whether some class holds a data descriptor of this name
                // (round 78), remembered by the node while the set of such
                // names is unchanged (round 81)
                if (an->dd_ver != dd_names_ver_ || !astSpecOn()) {
                    an->dd_hit = !data_descr_names_.empty() && data_descr_names_.count(an->attr);
                    an->dd_ver = dd_names_ver_;
                }
                if (kv && !isPropertyGetter(kv->second) && !an->dd_hit)
                    return kv->second;
            }
        }
        Value v;
        // a class attribute or a method read as a value (round 81)
        if (astSpecOn() && !any_getattribute_ && obj.type == ValueType::USERDATA && obj.value.p
            && classLoadFast(an, obj, ctx, v)) return v;
        if (getAttrValue(obj, an->attr, ctx, v)) return v;
        if (pend && !nypy::lenient_reads_log()) {   // round 82: missingAttribute's, by the flag
            pendExc("__exc__:AttributeError:" + attributeErrorText(obj, an->attr));
            return NONE_VALUE;
        }
        return missingAttribute(obj, an->attr, node.get());
    }
    // The entry of `key` in a scope's map, trying the slot `hint` remembers
    // first and remembering where it was found (round 81: an inline cache of
    // the slot, validated by the key it holds, as the VM's are).
    static const ContainerType::value_type* fieldAt(const ContainerType* m, const std::string& key, uint32_t& hint) {
        const ContainerType::value_type* kv = astSpecOn() ? m->slot_at(hint) : nullptr;
        if (kv && kv->first == key) return kv;
        long n = m->index_of(key);
        if (n < 0) return nullptr;
        hint = (uint32_t)n;
        return m->slot_at((size_t)n);
    }
    bool isPropertyGetter(const Value& v) {
        // round 81: only property() tags a function "__property__", and it
        // sets any_property_ first
        if (!any_property_) return false;
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        auto fn_it = func_names.find(v.value.p);
        return fn_it != func_names.end() && fn_it->second.find("__property__") != std::string::npos;
    }

    // a?.b  a?[k]  a?.m(x)  a?[i:j]  f?.(x), and the chain after the link
    // (OptChainNode, ASTNodes.hpp). none/undefined is absent (isAbsent).
    static bool isAbsent(const Value& v) { return v.type == ValueType::NONE || v.type == ValueType::UNDEFINED; }
    Value evalOptChain(OptChainNode* oc, Context* ctx) {
        Value r = evalNode(oc->recv, ctx);
        if (isAbsent(r)) return NONE_VALUE;
        Value v;
        switch (oc->kind) {
            case OptChainNode::ATTR:
                if (!getAttrValue(r, oc->name, ctx, v)) return NONE_VALUE;
                break;
            case OptChainNode::INDEX: {
                Value idx = evalNode(oc->index, ctx);
                if (!tryGetItem(r, idx, ctx, v)) return NONE_VALUE;
                break;
            }
            case OptChainNode::METHOD: {
                if (!hasMemberNoEval(r, oc->name, ctx)) return NONE_VALUE;
                oc->recv_hole->slot = r;
                v = evalNode(oc->call, ctx);
                break;
            }
            default:   // SLICE, CALL
                oc->recv_hole->slot = r;
                v = evalNode(oc->call, ctx);
                break;
        }
        if (!oc->rest) return v;
        oc->hole->slot = v;
        return evalNode(oc->rest, ctx);
    }
    // Whether obj.m(...) finds a method the call path supplies itself (a
    // builtin kind's method or the object protocol) - the methods a read
    // with bind=false leaves to callMethod.
    bool hasMethodMember(const Value& obj, const std::string& m) {
        nypy::MemberKind k = memberKindOf(obj);
        return k != nypy::MemberKind::Other && nypy::kind_has_method(k, m);
    }
    // Whether obj has a member `name`, without running a property getter or
    // __getattr__ (an object with __getattr__ counts as having every name):
    // the test `obj?.m(...)` makes before calling.
    // NY_LENIENT_READS=log, the porting aid: a dict method read or called
    // where the dict has a key of that name (d.get reads the method since
    // round 77; d["get"] reads the key) is reported once per line.
    void noteShadowedKey(Container* c, const std::string& name) {
        if (nypy::lenient_reads_log() && c && c->container && c->container->count(nypy::key_of_str(name)))
            logLenientRead(nullptr, "dict method '" + name + "' used where the dict has a key '" + name + "' (d[\"" + name + "\"] reads the key)");
    }
    // A dict made by a display, dict() or json - not a module or namespace
    // object, not a typed map (round 77).
    bool isPlainDict(Container* c) {
        if (!c || !c->container || seqLen(c) >= 0 || isSetCont(c) || c->container->count("__gen__")) return false;
        // (an Object's name is not kept - Object's constructor assigns the
        // member to itself - so modules and namespaces are known by
        // namespace_objs_ alone)
        auto* o = dynamic_cast<Object*>(c);
        if (!o || namespace_objs_.count((const void*)o)) return false;
        return !c->container->count("__type__");
    }
    bool hasMemberNoEval(const Value& obj, const std::string& name, Context* ctx) {
        if (isInstanceValue(obj)) {
            auto pit = instance_properties.find(obj.value.p);
            if (pit != instance_properties.end() && pit->second && pit->second->container
                && pit->second->container->count(name)) return true;
            Value m;
            if (Node* cls = classNodeOfInstance(obj); cls && findClassMember(cls, name, m)) return true;
            if (name == "__class__" || name == "__dict__" || instanceHasMethod(obj, "__getattr__")) return true;
            return hasMethodMember(obj, name);
        }
        Value v;
        return getAttrValue(obj, name, ctx, v, false) || hasMethodMember(obj, name);
    }

    // obj.attr found in the namespace of class_node, an MRO class of
    // class_ptr (getAttrValue's last steps for it, round 81: its own
    // function, which classLoadFast calls too): a property's getter run, a
    // descriptor's __get__, a classmethod bound to the class, a method
    // bound to an instance, else the value itself.
    bool classNsResult(const Value& cv, const Value& obj, void* class_ptr, Node* class_node, Context* ctx, bool bind, Value& out) {
        if (cv.type == ValueType::NONE) { out = cv; return true; }   // `x = None` in the class body
        // Check if this is a @property getter — invoke it with self
        if (cv.type == ValueType::USERDATA && cv.value.p) {
            auto fn_it = func_names.find(cv.value.p);
            if (fn_it != func_names.end() && fn_it->second.find("__property__") != std::string::npos) {
                void* pst = cv.value.p;
                auto pit2 = func_ast_nodes.find(cv.value.p);
                if (pit2 != func_ast_nodes.end()) pst = pit2->second;
                Node* raw = (Node*)pst;
                if (raw && raw->type() == NodeType::FUNCTION) {
                    auto fn = static_cast<FunctionNode*>(raw);
                    Context* cp = ctx;
                    auto cit2 = closure_contexts.find(cv.value.p);
                    if (cit2 != closure_contexts.end()) cp = scopeOf(cit2->second);
                    Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                    CtxReaper _reap_prop2(this, fc);
                    fc->defineByName("self", obj);
                    if (!fn->params.empty()) fc->defineByName(fn->params[0]->value(), obj);   // def p(s) (round 78)
                    out = runFunctionBody(fn, fc);
                    return true;
                }
            }
        }
        // A descriptor (an object whose class defines __get__):
        // the attribute is what its __get__ gives. Not with
        // bind=false: the call that follows runs it (once).
        if (bind && descriptorGet(cv, obj, class_ptr, ctx, out, false, class_node)) return true;
        // A method read as a value off an INSTANCE must carry its
        // instance with it, or `self` is lost at call time.
        // bind=false (evalCall's method path, hasMemberNoEval):
        // only the kind is looked at, so no heap object is made
        // for a binding that would be freed right after the call.
        // A classmethod read as a value (getattr(Cls, "cm"),
        // f = obj.cm) is bound to the receiver's class, as
        // Python's classmethod descriptor binds it; it used to
        // come back unbound, so calling it lacked `cls`.
        if (bind && cv.type == ValueType::USERDATA && cv.value.p
            && fnTag(func_names, cv.value.p).find("__classmethod__") != std::string::npos) {
            Value clsv;
            clsv.type = ValueType::USERDATA;
            clsv.value.p = class_ptr;
            out = makeBoundClassMethod(cv, clsv);
            return true;
        }
        if (bind && instance_to_class.count(obj.value.p)) { out = makeBoundMethod(cv, obj); return true; }
        out = cv;
        return true;
    }

    // obj.attr for a value in hand: true with the value in `out`, false when
    // obj has no such attribute - nothing is raised for that. Property
    // getters and __getattr__ run, and what they raise propagates. `bind`
    // false: a builtin method (list.append ...) is left to the method call
    // that is about to happen instead of being read as a bound value.
    bool getAttrValue(const Value& obj, const std::string& attr, Context* ctx, Value& out, bool bind = true) {
        if (any_getattribute_) {
            // a class's __getattribute__ (round 77); object.__getattribute__
            // asks for the lookup below
            if (raw_getattr_once_) raw_getattr_once_ = false;
            else if (getattributeHook(obj)) { out = hookedGetattr(obj, attr, ctx); return true; }
        }
        // a generator's __name__, gi_frame, gi_code, ... (round 77, NyGen.cpp)
        if (nygen::is_gen(obj) && nygen::attr(*this, obj, attr, out)) return true;
        // s = super(C, obj); s.attr (round 78): from the classes after C
        if (any_super_proxy_ && attr != "__thisclass__" && attr != "__self__" && attr != "__self_class__"
            && attr != "__class__" && attr != "__repr__" && isSuperProxy(obj)) {
            Node* owner = nullptr; Value self;
            superProxyParts(obj, owner, self);
            if (owner) return superAttrOf(owner, self, attr, ctx, out);
        }
        if (attr == "__class__" && !isInstanceValue(obj)) {
            // (5).__class__ is int, [].__class__ is list, C.__class__ is
            // type (round 77)
            Value t = typeObjectOf(obj);
            if (isTypeObject(t)) { out = t; return true; }
        }
        // Check instance properties first (and invoke @property getters)
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            // (round 81: the scope, not the table's iterator, is kept - the
            // table is hashed now, and the class lookup below may add to it)
            Context* pc = instPropsOf(obj);
            if (pc && pc->container) {
                // Present even when it holds undefined (self.x = undefined).
                auto fit0 = pc->container->find(attr);
                // A data descriptor of the class (a property, an object with
                // __set__ / __delete__) wins over the instance's own field of
                // that name, as in Python (round 78: the field was read
                // first): the class lookup below reads it.
                // A slot's member descriptor (round 79) reads that field.
                if (fit0 != pc->container->end() && !data_descr_names_.empty() && classDataDescriptor(obj, attr)
                    && !isSlotOf(obj, attr))
                    fit0 = pc->container->end();
                if (fit0 != pc->container->end()) {
                    const Value& v = fit0->second;
                    // Check if this is a @property — if so, call it with self
                    if (v.type == ValueType::USERDATA && v.value.p) {
                        auto fn_it = func_names.find(v.value.p);
                        if (fn_it != func_names.end() && fn_it->second.find("__property__") != std::string::npos) {
                            // Invoke the getter
                            void* ast_ptr = v.value.p;
                            auto ast_it = func_ast_nodes.find(v.value.p);
                            if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
                            Node* raw = (Node*)ast_ptr;
                            if (raw && raw->type() == NodeType::FUNCTION) {
                                auto fn = static_cast<FunctionNode*>(raw);
                                Context* closure_parent = ctx;
                                auto cit = closure_contexts.find(v.value.p);
                                if (cit != closure_contexts.end()) closure_parent = scopeOf(cit->second);
                                Context* fc = new Context(runner, fn->name, nullptr, nullptr, closure_parent);
                                CtxReaper _reap_prop(this, fc);
                                fc->defineByName("self", obj);
                                if (!fn->params.empty()) fc->defineByName(fn->params[0]->value(), obj);   // def p(s) (round 78)
                                out = runFunctionBody(fn, fc);
                                return true;
                            }
                        }
                    }
                    out = v;
                    return true;
                }
            }
        }
        if (obj.isCollectable() && obj.value.gc) {
            auto* cont = dynamic_cast<Container*>(obj.value.gc);
            if (cont && cont->container) {
                // a dict's methods win over its keys (round 77)
                if (nyrt::is_dict_method_name(attr) && isPlainDict(cont)) {
                    noteShadowedKey(cont, attr);
                    if (bind) { out = boundMember(obj, attr); return true; }
                    return false;
                }
                auto it = cont->container->find(attr);
                if (it != cont->container->end()) { out = it->second; return true; }
                // round 81: a module's __spec__ / __loader__, made when first
                // read (the prelude's _ny_module_spec_attr)
                if ((attr == "__spec__" || attr == "__loader__") && isModuleNamespace(obj)) {
                    std::vector<Value> a{obj, makeStringValue(attr)};
                    out = callFunctionValue(global_ctx->getByName("_ny_module_spec_attr"), a, ctx ? ctx : global_ctx);
                    return true;
                }
                // A dict / list / tuple / set method read as a value.
                if (bind && builtinValueDunder(obj, attr, out)) return true;   // [1].__getitem__ (round 78)
                if (bind && nypy::kind_has_method(memberKindOf(obj), attr)) { out = boundMember(obj, attr); return true; }
                return false;
            }
        }
        // A builtin used as a namespace: `import time` then time.time(),
        // time.sleep(1), time.monotonic() - the builtin time_X, else X for
        // `time`. A builtin must never reach the class lookup below: its
        // pointer is a std::string, and reading it as an AST node crashed
        // (time.time() was a segmentation fault).
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto bit = func_names.find(obj.value.p);
            if (bit != func_names.end() && bit->second.rfind("__builtin__:", 0) == 0) {
                const std::string base = bit->second.substr(12);
                // str.upper, bytes.fromhex, int.from_bytes ... (round 77)
                if (nypy::type_has_member(base, attr)) {
                    std::string full = base + "." + attr;
                    if (!builtin_ptrs.count(full)) registerBuiltin(full);
                    out = builtinValue(full);
                    return true;
                }
                std::string target = nyrt::builtin_member(base, attr,
                    [&](const std::string& n) { return builtin_ptrs.count(n) > 0; });
                if (!target.empty()) { out = builtinValue(target); return true; }
                // len.__name__, int.__name__ (argparse's "invalid int value")
                if (attr == "__name__" || attr == "__qualname__") {
                    size_t dot = base.rfind('.');
                    out = makeStringValue(dot == std::string::npos ? base : base.substr(dot + 1));
                    return true;
                }
                if (attr == "__module__") { out = makeStringValue("builtins"); return true; }
                // int.__mro__ / int.__bases__ of a builtin type (round 77):
                // (int, object), and bool's MRO is (bool, int, object)
                if (attr == "__mro__" || attr == "__bases__") {
                    std::string py, legacy;
                    if (!typeObjectNames(obj, py, legacy)) return false;
                    std::vector<Value> chain;
                    if (attr == "__mro__") chain.push_back(obj);
                    if (py == "bool") chain.push_back(builtinValue("int"));
                    if (attr == "__mro__" || py != "bool")
                        if (Node* on = classNodeByName("object")) chain.push_back(classValueOfNode(on));
                    out = makeListValue(chain, true);
                    return true;
                }
                // int.__new__, list.__init__, dict.__setitem__, int.__repr__
                // ...: the type's mirror class has them (round 77)
                if (nyrt::mirror_dunder(attr)) {
                    std::string bt = base == "map" ? std::string("dict") : base;
                    if (nyrt::builtin_mirror(bt)) ensureMirror(bt);
                    if (Node* mn = builtinMirrorNode(bt)) {
                        Value mv;
                        if (findClassMember(mn, attr, mv)) { out = mv; return true; }
                    }
                }
                return false;
            }
        }
        // Class variable / static method lookup: ClassName.var or ClassName.staticmethod
        // Also handles instance.property for @property getters not stored per-instance
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            // If obj is an instance, find its class; if it IS a class, use directly
            void* class_ptr = obj.value.p;
            auto inst_it = instance_to_class.find(class_ptr);
            const bool was_inst = inst_it != instance_to_class.end();   // round 81: the iterator is not kept (hashed table)
            if (inst_it != instance_to_class.end()) class_ptr = inst_it->second;
            void* ast_ptr = class_ptr;
            auto ast_it = func_ast_nodes.find(class_ptr);
            if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
            Node* class_node = (Node*)ast_ptr;
            if (class_node && fnTag(func_names, class_ptr).rfind("__class__:", 0) == 0 && class_node->type() == NodeType::CLASS) {
              // The class itself, then its bases depth-first, left to right.
              // Only the instance's own class used to be searched here, so a
              // method inherited from a base read as `none` when taken as a
              // value (`cb = self.on_resize` in a subclass) even though
              // calling it directly worked - the call path walks the chain.
              // C3 MRO, as the VM and method calls use.
              std::vector<Node*> mro = classMro(class_node);
              for (Node* mro_node : mro) {
                // a class's __name__ / __qualname__ is its own, never a base's
                // namespace entry (round 80: a dataclass(slots=True) base's
                // __qualname__ named its subclasses)
                if (mro_node != mro.front() && !was_inst && (attr == "__qualname__" || attr == "__name__")) continue;
                class_node = mro_node;
                auto* cn = static_cast<ClassNode*>(class_node);
                // Check class body context (handles @staticmethod, @property, class vars).
                // Only the class's own namespace: getByName walked on into the
                // scope the class was defined in, so reading a missing
                // attribute returned any same-named variable there (a global
                // `a` read as obj.a).
                auto ctx_it = class_ctx_map_.find((void*)class_node);
                if (ctx_it != class_ctx_map_.end() && ctx_it->second && ctx_it->second->container) {
                    Value cv = UNDEFINED_VALUE;
                    {
                        auto own = ctx_it->second->container->find(attr);
                        if (own != ctx_it->second->container->end()) cv = own->second;
                    }
                    if (cv.type != ValueType::UNDEFINED) return classNsResult(cv, obj, class_ptr, class_node, ctx, bind, out);   // (round 81: its own function)
                }
                // Check class_vars_ (mutable class-level variables set at runtime)
                std::string cv_key = cn->name + "." + attr;
                auto cv_it = class_vars_.find(cv_key);
                if (cv_it != class_vars_.end()) {
                    if (bind && descriptorGet(cv_it->second, obj, class_ptr, ctx, out, false, class_node)) return true;
                    out = cv_it->second;
                    return true;
                }
                // Not yet set — evaluate class-level default from body
                // (unless it was deleted: del C.x, round 77)
                if (cn->body && (class_vars_deleted_.empty() || !class_vars_deleted_.count(cv_key))) {
                    for (auto& stmt : cn->body->statements()) {
                        if (stmt->type() == NodeType::ASSIGNMENT) {
                            auto as = static_pointer_cast<AssignmentNode>(stmt);
                            if (as->target->type() == NodeType::VARIABLE && as->target->value() == attr) {
                                out = evalNode(as->value_node, ctx);
                                return true;
                            }
                        }
                    }
                }
              }
              // round 80: object's members, after the MRO (objectMember)
              {
                  Value cv; Node* owner = nullptr;
                  if (objectMember(attr, cv, &owner, mro.empty() ? nullptr : mro.front())) {
                      std::string tag = cv.type == ValueType::USERDATA && cv.value.p ? fnTag(func_names, cv.value.p) : std::string();
                      if (bind && tag.find("__classmethod__") != std::string::npos) {
                          Value clsv; clsv.type = ValueType::USERDATA; clsv.value.p = class_ptr;
                          out = makeBoundClassMethod(cv, clsv);
                          return true;
                      }
                      if (bind && tag.find("__static__") == std::string::npos && instance_to_class.count(obj.value.p)) {
                          out = makeBoundMethod(cv, obj);
                          return true;
                      }
                      out = cv;
                      return true;
                  }
              }
            }
        }
        return specialAttribute(obj, attr, ctx, out, bind);
    }
    // obj.name for a value in hand: UNDEFINED when it has no such attribute.
    Value lookupAttribute(const Value& obj, const std::string& name, Context* ctx) {
        Value v;
        return getAttrValue(obj, name, ctx, v) ? v : UNDEFINED_VALUE;
    }
    // Which builtin kind a value is, for the method tables (NyMembers.hpp).
    nypy::MemberKind memberKindOf(const Value& v) {
        switch (v.type) {
            case ValueType::NONE: return nypy::MemberKind::None;
            case ValueType::BOOLEAN: return nypy::MemberKind::Bool;
            case ValueType::INTEGER: return nypy::MemberKind::Int;
            case ValueType::DOUBLE: return nypy::MemberKind::Float;
            case ValueType::UNDEFINED: return nypy::MemberKind::Other;
            default: break;
        }
        if (auto* bo = bytesOf(v)) return bo->mut ? nypy::MemberKind::ByteArray : nypy::MemberKind::Bytes;
        if (isStringValue(v)) return nypy::MemberKind::Str;
        if (nygen::is_gen(v)) return nypy::MemberKind::Generator;
        if (Container* c = contOf(v)) {
            if (seqLen(c) < 0) return nypy::MemberKind::Dict;
            if (isTupleCont(c)) return nypy::MemberKind::Tuple;
            if (isSetCont(c)) return nypy::MemberKind::Set;
            return nypy::MemberKind::List;
        }
        if (isInstanceVal(v)) return nypy::MemberKind::Instance;
        return nypy::MemberKind::Other;
    }
    // A method of a builtin value (or an object-protocol member) read as a
    // value: a callable that calls it on `recv`. One per receiver and name
    // (the interpreter keeps what it allocates, so it is cached).
    // Attributes stored on a function (f.calls = 0), as in Python: per
    // function value (each `def` evaluation is its own value).
    std::unordered_map<void*, std::unordered_map<std::string, Value>> func_attrs_;
    bool isPlainFunction(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        std::string t = fnTag(func_names, v.value.p);
        return t.rfind("__func__:", 0) == 0 || t.rfind("__lambda__", 0) == 0;
    }
    // _ny_fn_info(f) (round 77): what inspect, f.__defaults__ / __kwdefaults__
    // / __code__ / __qualname__ / __module__ are made from (the prelude's
    // _ny_fn_attr) - [name, qualname, module, params, flags, file, line],
    // params a list of [name, kind, has_default, default] with inspect's
    // kinds (0 positional-only, 1 positional-or-keyword, 2 *args,
    // 3 keyword-only, 4 **kwargs), flags 1 generator, 2 coroutine, 4 async
    // generator, 8 lambda. A bound method answers for its function (self
    // included). None for anything else. The VM's is VirtualMachine::fn_info.
    Value fnInfo(Value f) {
        if (f.type == ValueType::USERDATA && f.value.p && !bound_self_.empty()) {
            auto bs = bound_self_.find(f.value.p);
            if (bs != bound_self_.end() && bs->second) f = bs->second->fn;
        }
        if (!isPlainFunction(f)) return NONE_VALUE;
        void* p = f.value.p;
        auto an = func_ast_nodes.find(p);
        Node* node = an == func_ast_nodes.end() ? nullptr : (Node*)an->second;
        auto cc = closure_contexts.find(p);
        return fnInfoOf(node, p, cc == closure_contexts.end() ? nullptr : cc->second);
    }
    // fnInfo for a function's node; `p` (the function value, for its
    // default values) may be null - a generator's gi_code (round 77).
    Value fnInfoOf(Node* node, void* p, Context* where) {
        auto* fn = dynamic_cast<FunctionNode*>(node);
        auto* lam = fn ? nullptr : dynamic_cast<LambdaNode*>(node);
        if (!fn && !lam) return NONE_VALUE;
        const std::vector<node_ptr>& params = fn ? fn->params : lam->params;
        const std::vector<node_ptr>& defs = fn ? fn->defaults : lam->defaults;
        size_t posonly = fn ? fn->posonly : 0;
        std::vector<Value> ps;
        bool star = false;
        for (size_t i = 0; i < params.size(); i++) {
            std::string pn = params[i]->value();
            int kind = 1;
            if (pn == "*") { star = true; continue; }
            if (pn.size() > 1 && pn[0] == '*' && pn[1] == '*') { kind = 4; pn = pn.substr(2); }
            else if (pn.size() > 1 && pn[0] == '*') { kind = 2; pn = pn.substr(1); star = true; }
            else if (star) kind = 3;
            else if (i < posonly) kind = 0;
            bool has = i < defs.size() && defs[i] && kind != 2 && kind != 4;
            Value dv = NONE_VALUE;
            if (has && p) {
                auto dit = fn_defaults_val_.find(p);
                if (dit != fn_defaults_val_.end() && i < dit->second.size() && dit->second[i].type != ValueType::UNDEFINED) dv = dit->second[i];
                else if (fn) dv = paramDefault(fn, i, where ? where : global_ctx, p);
            }
            ps.push_back(makeListValue({makeStringValue(pn), Value(kind), Value(has), dv}));
        }
        Value mod = makeStringValue("__main__");
        if (Context* m = moduleCtx(where ? where : global_ctx)) {
            Value mn = m->getByName("__name__");
            if (isStringValue(mn)) mod = mn;
        }
        int flags = lam ? 8 : 0;
        if (fn && fn->is_async) flags |= fn->is_async_gen ? 4 : 2;
        else if (bodyYields(fn ? fn->body : lam->body)) flags |= 1;
        std::string name = fn ? fn->name : std::string("<lambda>");
        std::string qn = fn ? fn->qualname : lam->qualname;
        if (fn && !fn_qualname_.empty()) {          // a __qualname__ the program set
            auto it = fn_qualname_.find(fn);
            if (it != fn_qualname_.end()) qn = it->second;
        }
        if (qn.empty()) qn = name;
        // [7]: the code's identity (round 81: one code object per function,
        // so f.__code__ is frame.f_code - the prelude's _ny_code_of)
        return makeListValue({makeStringValue(name), makeStringValue(qn), mod, makeListValue(ps), Value(flags),
                              makeStringValue(node->tok().fileName()), Value(fn && fn->first_line ? fn->first_line : (int)node->tok().line()),
                              intValue((int64_t)(uintptr_t)node)});
    }
    // _ny_fn_globals(f) (round 77): f.__globals__, the names of the module
    // f was defined in (a copy, as globals() is here).
    Value fnGlobals(Value f) {
        if (f.type == ValueType::USERDATA && f.value.p && !bound_self_.empty()) {
            auto bs = bound_self_.find(f.value.p);
            if (bs != bound_self_.end() && bs->second) f = bs->second->fn;
        }
        if (!isPlainFunction(f)) return NONE_VALUE;
        auto cc = closure_contexts.find(f.value.p);
        return globalsView(cc == closure_contexts.end() ? global_ctx : cc->second);   // round 81: the live view
    }
    // A heap object (nyheap::BMember) holding the receiver; the tables refer
    // to it without owning it and lose its entries when it is freed.
    std::unordered_map<void*, nyheap::BMember*> bound_members_;
    std::map<std::pair<uintptr_t, std::string>, nyheap::BMember*> bound_member_cache_;
    Value boundMember(const Value& recv, const std::string& name) {
        uintptr_t id = 0;
        if (recv.type == ValueType::USERDATA) id = (uintptr_t)recv.value.p;
        else if (recv.isCollectable()) id = (uintptr_t)recv.value.gc;
        if (id) {
            auto it = bound_member_cache_.find({id, name});
            if (it != bound_member_cache_.end()) return nyheap::userValue(it->second, (void*)&it->second->tag);
        }
        auto* bm = new nyheap::BMember(this, "__bmethod__:" + name);
        void* p = (void*)&bm->tag;
        Value v = nyheap::userValue(bm, p);
        bm->recv = recv;
        bm->name = name;
        bm->key_id = id;
        func_names[p] = bm->tag;
        bound_members_[p] = bm;
        if (id) bound_member_cache_[{id, name}] = bm;
        nygc::track(bm);
        return v;
    }
    void forgetBoundMember(nyheap::BMember* bm) {
        void* p = (void*)&bm->tag;
        func_names.erase(p);
        bound_members_.erase(p);
        if (bm->key_id) {
            auto it = bound_member_cache_.find({bm->key_id, bm->name});
            if (it != bound_member_cache_.end() && it->second == bm) bound_member_cache_.erase(it);
        }
    }
    // Calls a bound member made by boundMember; false if `fn` is not one.
    bool callBoundMember(const Value& fn, std::vector<Value>& args, const nyrt::OrderedKw<Value>* kw,
                         Context* ctx, Value& out) {
        if (fn.type != ValueType::USERDATA || !fn.value.p) return false;
        auto it = bound_members_.find(fn.value.p);
        if (it == bound_members_.end()) return false;
        Value recv = it->second->recv;          // kept while the call runs
        std::string name = it->second->name;
        out = callMethod(recv, name, args, ctx, kw);
        return true;
    }
    // The text of the AttributeError for obj.name.
    std::string attributeErrorText(const Value& obj, const std::string& name) {
        if (isInstanceValue(obj))
            return "'" + shownClassName(instanceClassName(obj)) + "' object has no attribute '" + name + "'";
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            std::string t = fnTag(func_names, obj.value.p);
            if (t.rfind("__class__:", 0) == 0) {
                std::string cn = t.substr(10);
                size_t tag = cn.find("__");
                if (tag != std::string::npos && tag > 0) cn = cn.substr(0, tag);
                return "type object '" + cn + "' has no attribute '" + name + "'";
            }
        }
        return "'" + typeNameOf(obj) + "' object has no attribute '" + name + "'";
    }
    // A missing attribute read: AttributeError, or - NY_LENIENT_READS=log, a
    // porting aid - a line on stderr and none.
    Value missingAttribute(const Value& obj, const std::string& name, Node* where) {
        std::string msg = attributeErrorText(obj, name);
        if (nypy::lenient_reads_log()) { logLenientRead(where, "AttributeError: " + msg); return NONE_VALUE; }
        throw std::string("__exc__:AttributeError:" + msg);
    }
    // A missing dict key read: KeyError(key), or the NY_LENIENT_READS=log line.
    Value missingKey(const Value& key, Context* ctx) {
        if (nypy::lenient_reads_log()) { logLenientRead(nullptr, "KeyError: " + reprOf(key, ctx)); return NONE_VALUE; }
        raiseKeyError(key);   // KeyError(key), the key itself (round 77)
    }
    void logLenientRead(Node* where, const std::string& what) {
        std::string loc;
        if (where) { const auto& tk = where->tok(); loc = tk.fileName() + ":" + std::to_string(tk.line()); }
        else loc = last_stmt_where();
        static std::mutex mu;
        static std::set<std::string> seen;
        std::lock_guard<std::mutex> lk(mu);
        if (!seen.insert(loc + " " + what).second) return;
        fprintf(stderr, "[lenient-read] %s: %s\n", loc.c_str(), what.c_str());
    }
    // Attributes every value answers: __name__ of a function or class (and of
    // the name string type() returns), an instance's __class__ and __dict__,
    // what an instance's __getattr__ supplies for anything it does not have,
    // and a builtin value's methods (NyMembers.hpp) read as bound values.
    // Properties: a getter function tagged __property__; its setter, from
    // @prop.setter, is kept here.
    std::unordered_map<void*, Value> prop_setters_;
    std::unordered_map<std::string, Value> prop_setter_target_;   // "__prop_setter__:<p>" -> the getter
    bool any_property_ = false;   // no property anywhere: attribute stores skip the class lookup
    std::vector<std::unique_ptr<std::string>> prop_setter_ids_;
    bool specialAttribute(const Value& obj, const std::string& attr, Context* ctx, Value& out, bool bind = true) {
        if (obj.type == ValueType::USERDATA && obj.value.p && (attr == "fget" || attr == "fset" || attr == "fdel")) {
            // a property's fget / fset / fdel, as Python's (round 77): the
            // property is its getter, tagged
            auto pf = func_names.find(obj.value.p);
            if (pf != func_names.end() && pf->second.find("__property__") != std::string::npos) {
                if (attr == "fget") out = obj;
                else if (attr == "fset") { auto ps = prop_setters_.find(obj.value.p); out = ps != prop_setters_.end() ? ps->second : NONE_VALUE; }
                else out = NONE_VALUE;
                return true;
            }
        }
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            // A runtime type object (NoneType, function, ...): its names, and
            // object its only base (round 77)
            if (const nyrt::RuntimeType* rt = runtimeTypeOf(obj)) {
                if (attr == "__name__" || attr == "__qualname__") { out = makeStringValue(rt->name); return true; }
                if (attr == "__module__") { out = makeStringValue(rt->module); return true; }
                if (attr == "__doc__") { out = NONE_VALUE; return true; }
                if (attr == "__mro__" || attr == "__bases__") {
                    std::vector<Value> chain;
                    if (attr == "__mro__") chain.push_back(obj);
                    if (Node* on = classNodeByName("object")) chain.push_back(classValueOfNode(on));
                    out = makeListValue(chain, true);
                    return true;
                }
                return false;
            }
            // f.__call__ (round 78): a function's, a bound method's, a
            // builtin's - calling it calls the callable
            if (attr == "__call__") {
                const std::string ft = fnTag(func_names, obj.value.p);
                if (ft.rfind("__func__:", 0) == 0 || ft.rfind("__lambda__", 0) == 0 || ft.rfind("__builtin__:", 0) == 0
                    || ft.rfind("__bmethod__:", 0) == 0) { out = obj; return true; }
            }
            // A builtin method ([].append): __self__ and its qualified name
            // (round 77)
            if (!bound_members_.empty() && (attr == "__self__" || attr == "__qualname__")) {
                auto bm = bound_members_.find(obj.value.p);
                if (bm != bound_members_.end() && bm->second) {
                    if (attr == "__self__") out = bm->second->recv;
                    else out = makeStringValue(typeNameOf(bm->second->recv) + "." + bm->second->name);
                    return true;
                }
            }
            // A bound method: __self__, __func__, and everything else its
            // function's (__annotations__, __doc__, attributes set on it).
            if (!bound_self_.empty()) {
                auto bs = bound_self_.find(obj.value.p);
                if (bs != bound_self_.end() && bs->second) {
                    if (attr == "__self__") { out = bs->second->self; return true; }
                    if (attr == "__func__") { out = bs->second->fn; return true; }
                    Value fnv = bs->second->fn;
                    if (fnv.value.p != obj.value.p && specialAttribute(fnv, attr, ctx, out, bind)) return true;
                }
            }
            if (!func_attrs_.empty()) {
                auto fa = func_attrs_.find(obj.value.p);
                if (fa != func_attrs_.end()) {
                    auto it = fa->second.find(attr);
                    if (it != fa->second.end()) { out = it->second; return true; }
                }
            }
            // A function's __defaults__, __kwdefaults__, __code__, __qualname__,
            // __module__, __globals__ (round 77): the prelude's _ny_fn_attr
            // makes them from _ny_fn_info (fnInfo), as on the VM.
            if (attr.size() > 4 && attr[0] == '_' && attr[1] == '_'
                && (attr == "__defaults__" || attr == "__kwdefaults__" || attr == "__code__" || attr == "__qualname__"
                    || attr == "__module__" || attr == "__globals__")
                && isPlainFunction(obj)) {
                std::vector<Value> a{obj, makeStringValue(attr)};
                out = callFunctionValue(global_ctx->getByName("_ny_fn_attr"), a, ctx);
                return true;
            }
            if (attr == "__name__" && fnTag(func_names, obj.value.p) == "__lambda__") { out = makeStringValue("<lambda>"); return true; }
            // C.__dict__: the class's own namespace (a copy, as a mappingproxy
            // is read-only).
            if (attr == "__dict__") {
                if (Node* cn = classNodeOfValue(obj)) { out = classNamespace(cn); return true; }
            }
            // A class's metaclass members (methods bound to the class, its
            // properties read with the class), then its __getattr__ (round 77).
            if (!class_meta_.empty() && classNodeOfValue(obj) && attr != "__init__" && attr != "__new__") {
                Value m; Node* where = nullptr;
                if (metaMember(obj, attr, m, where)) {
                    // a descriptor of the metaclass (a property): read with
                    // the class as its receiver (round 77)
                    if (isInstanceValue(m)) {
                        if (!descriptorGet(m, obj, (void*)where, ctx, out, true)) out = m;
                        return true;
                    }
                    std::string tag = fnTag(func_names, m.value.p);
                    static const nyrt::OrderedKw<Value> no_kw;
                    if (tag.find("__property__") != std::string::npos) {
                        std::vector<Value> a{obj};
                        out = callFunctionValue(m, a, ctx);
                        return true;
                    }
                    if (tag.find("__static__") != std::string::npos) { out = m; return true; }
                    std::vector<Value> a{m, obj};
                    out = callFunctionValue(global_ctx->getByName("_NyMetaBound"), a, ctx);
                    return true;
                }
                if (Node* mn = classNodeOfValue(metaclassOf(classNodeOfValue(obj)))) {
                    auto mit = class_ctx_map_.find((void*)mn);
                    if (mit != class_ctx_map_.end() && mit->second && mit->second->container) {
                        auto vit = mit->second->container->find(attr);
                        if (vit != mit->second->container->end()) {
                            // a descriptor (a property) of the metaclass: read
                            // with the class as its receiver (round 77)
                            if (isInstanceValue(vit->second) && descriptorGet(vit->second, obj, (void*)mn, ctx, out, true)) return true;
                            out = vit->second;
                            return true;
                        }
                    }
                }
                if (attr.size() < 2 || attr.substr(0, 2) != "__") {
                    std::vector<Value> a{makeStringValue(attr)};
                    if (metaCall(obj, "__getattr__", a, ctx, out)) return true;
                }
            }
            // A function without annotations has an empty __annotations__
            // dict, made on first read and kept (writes to it stay).
            if (attr == "__annotations__" && isPlainFunction(obj)) {
                out = Value((Collectable*)new Object((Runnable*)runner, "map", Type::MAP));
                func_attrs_[obj.value.p]["__annotations__"] = out;
                return true;
            }
            auto fit = func_names.find(obj.value.p);
            // prop.setter: a callable that records its argument as the
            // property's setter and returns the property.
            if (attr == "setter" && fit != func_names.end() && fit->second.find("__property__") != std::string::npos) {
                std::ostringstream os; os << "__prop_setter__:" << obj.value.p;
                prop_setter_target_[os.str()] = obj;
                prop_setter_ids_.push_back(std::make_unique<std::string>(os.str()));
                void* id = prop_setter_ids_.back().get();
                func_names[id] = "__builtin__:" + os.str();
                out = Value(); out.type = ValueType::USERDATA; out.value.p = id;
                return true;
            }
            // C.__mro__ / C.__bases__: the classes, in C3 order / as written.
            if ((attr == "__mro__" || attr == "__bases__") && fit != func_names.end()
                && fit->second.rfind("__class__:", 0) == 0) {
                Node* cn = classNodeByName(fit->second.substr(10));
                std::vector<Value> seq_vals;
                if (cn) {
                    // builtin bases (type, dict, int, ...) as their builtin
                    // values; object ends every __mro__ and is the base of
                    // a class that names none (round 77)
                    Node* objn = classNodeByName("object");
                    auto builtin = [&](const std::string& n, Value& v) {
                        if (classNodeByName(n) || !nyrt::is_builtin_type_name(n) || n == "object") return false;
                        v = global_ctx->getByName(n);
                        return v.type != ValueType::UNDEFINED && v.type != ValueType::NONE;
                    };
                    auto push = [&](Node* c) { Value cv; cv.type = ValueType::USERDATA; cv.value.p = (void*)c; seq_vals.push_back(cv); };
                    if (attr == "__mro__") {
                        std::vector<Node*> seq = classMro(cn);
                        std::vector<std::string> extra;
                        for (Node* c : seq) {
                            // a builtin type's mirror is that type, where it
                            // stands (round 77)
                            std::string bt = nyrt::mirror_builtin(static_cast<ClassNode*>(c)->name);
                            if (!bt.empty() && c != cn) {
                                Value v;
                                if (builtin(bt, v)) seq_vals.push_back(v);
                                extra.push_back(bt);
                                continue;
                            }
                            if (c != objn) push(c);
                        }
                        for (Node* c : seq)
                            for (auto& b : static_cast<ClassNode*>(c)->bases)
                                if (std::find(extra.begin(), extra.end(), b->value()) == extra.end()) extra.push_back(b->value());
                        for (Node* c : seq) {
                            std::string bt = nyrt::mirror_builtin(static_cast<ClassNode*>(c)->name);
                            if (!bt.empty()) extra.erase(std::remove(extra.begin(), extra.end(), bt), extra.end());
                        }
                        for (auto& n : extra) { Value v; if (builtin(n, v)) seq_vals.push_back(v); }
                        if (objn && cn != objn) push(objn);
                    } else {
                        for (auto& b : static_cast<ClassNode*>(cn)->bases) {
                            Value v;
                            if (Node* bn = classNodeByName(b->value())) push(bn);
                            else if (builtin(b->value(), v)) seq_vals.push_back(v);
                        }
                        if (seq_vals.empty() && objn && cn != objn) push(objn);
                    }
                }
                out = makeListValue(seq_vals, true);   // both are tuples
                return true;
            }
            // __doc__: the docstring of a function, method, class, or an
            // instance's class (round 77)
            if (attr == "__doc__" && fit != func_names.end()) {
                const std::string& t = fit->second;
                Node* n = nullptr;
                if (t.rfind("__class__:", 0) == 0) n = (Node*)obj.value.p;
                else if (t.rfind("__instance__:", 0) == 0) n = classNodeOfInstance(obj);
                else {
                    auto ait = func_ast_nodes.find(obj.value.p);
                    if (ait != func_ast_nodes.end()) n = (Node*)ait->second;
                }
                out = NONE_VALUE;
                if (auto* cn = dynamic_cast<ClassNode*>(n)) { if (cn->has_doc) out = makeStringValue(cn->doc); }
                else if (auto* fnode = dynamic_cast<FunctionNode*>(n)) { if (fnode->has_doc) out = makeStringValue(fnode->doc); }
                return true;
            }
            if (attr == "__name__" || attr == "__qualname__" || attr == "__module__") {
                if (fit != func_names.end()) {
                    const std::string& t = fit->second;
                    size_t c = t.find(':');
                    std::string nm = c == std::string::npos ? t : t.substr(c + 1);
                    // name__static__ etc: the decorator tags (round 78: any
                    // "__" was cut, so a mangled _C__m read "_C")
                    for (bool cut = true; cut; ) {
                        cut = false;
                        for (const char* sfx : {"__static__", "__classmethod__", "__property__"}) {
                            size_t sl = std::strlen(sfx);
                            if (nm.size() > sl && nm.compare(nm.size() - sl, sl, sfx) == 0) { nm.resize(nm.size() - sl); cut = true; }
                        }
                    }
                    if (attr == "__name__" && t.rfind("__func__:", 0) == 0) {
                        void* ap = obj.value.p;
                        auto ai = func_ast_nodes.find(ap);
                        if (ai != func_ast_nodes.end()) ap = ai->second;
                        if (auto* fnode = dynamic_cast<FunctionNode*>((Node*)ap)) nm = nyrt::unmangled_name(nm, fnode->qualname);
                    }
                    nm = shownClassName(nm);
                    // A module's class is "module.Class" (round 77): __name__
                    // is the class's own name, __module__ the module's.
                    bool is_class = t.rfind("__class__:", 0) == 0;
                    size_t dot = is_class ? nm.rfind('.') : std::string::npos;
                    if (attr == "__module__") {
                        if (!is_class) return false;
                        // the builtin exceptions and object are builtins' (round 80)
                        if (dot == std::string::npos && (nm == "object" || nython::ny_is_builtin_exc(nm)) && t.find('#') == std::string::npos) {
                            out = makeStringValue("builtins");
                            return true;
                        }
                        out = makeStringValue(dot == std::string::npos ? std::string("__main__") : nm.substr(0, dot));
                        return true;
                    }
                    // a nested class's __qualname__ is Outer.Inner, a class in
                    // a function's f.<locals>.C (round 79: the parser's)
                    if (is_class && attr == "__qualname__") {
                        if (auto* cnode = dynamic_cast<ClassNode*>(classNodeOfValue(obj)); cnode && !cnode->qualname.empty()) {
                            out = makeStringValue(cnode->qualname);
                            return true;
                        }
                    }
                    out = makeStringValue(dot == std::string::npos ? nm : nm.substr(dot + 1));
                    return true;
                }
                // type(x).__name__ (type() gives the class's name): a module
                // class "m.C" is named "C"
                if ((attr == "__name__" || attr == "__qualname__") && isStringValue(obj)) {
                    std::string t = getStringValue(obj);
                    size_t dot = t.rfind('.');
                    out = dot == std::string::npos ? obj : makeStringValue(t.substr(dot + 1));
                    return true;
                }
            }
            if (isInstanceValue(obj)) {
                if (attr == "__class__") {
                    void* cls = instance_to_class[obj.value.p];
                    out = Value(); out.type = ValueType::USERDATA; out.value.p = cls;
                    return true;
                }
                if (attr == "__dict__") {
                    // (none for a class with __slots__ and no __dict__ - round 79)
                    if (!slot_flags_.empty() && isDictless(obj))
                        pyRaise("AttributeError", "'" + typeNameOf(obj) + "' object has no attribute '__dict__'");
                    // a live view of the fields (round 77; it was a copy):
                    // names as dict keys, self.__x__ listed too
                    out = instanceDictView(obj);
                    return true;
                }
                // (not for object.__getattribute__'s lookup - round 77)
                if (raw_getattr_obj_ != obj.value.p && instanceHasMethod(obj, "__getattr__")) {
                    std::vector<Value> a{makeStringValue(attr)};
                    out = callMethod(obj, "__getattr__", a, ctx);
                    return true;
                }
            }
        }
        // A builtin value's method, or the object protocol (c.to_string),
        // read as a value.
        // a number's real / imag, an int's numerator / denominator (round 78)
        if (obj.type == ValueType::INTEGER || obj.type == ValueType::BOOLEAN || obj.type == ValueType::DOUBLE) {
            bool is_int = obj.type != ValueType::DOUBLE;
            Value iv = obj.type == ValueType::BOOLEAN ? intValue(obj.value.b ? 1 : 0) : obj;
            if (attr == "real") { out = iv; return true; }
            if (attr == "imag") { out = is_int ? intValue(0) : Value(0.0); return true; }
            if (is_int && attr == "numerator") { out = iv; return true; }
            if (is_int && attr == "denominator") { out = intValue(1); return true; }
        }
        if (bind) {
            nypy::MemberKind k = memberKindOf(obj);
            // (5).__add__, "ab".__len__ (round 78)
            if (k != nypy::MemberKind::Other && builtinValueDunder(obj, attr, out)) return true;
            if (k != nypy::MemberKind::Other && nypy::kind_has_method(k, attr)) { out = boundMember(obj, attr); return true; }
        }
        return false;
    }

    // ─── RETURN ─────────────────────────────────────────────────────────
    Value evalReturn(const node_ptr& node, Context* ctx) {
        auto* rn = static_cast<ReturnNode*>((node).get());
        // round 82: `return f(x)` - the call's exception may come back by
        // the flag (evalP), and leaves as the statement's (val is none then;
        // one named value, so it is built in place)
        FlowState& f = flow();
        const bool pend = rn->expr && ctx && f.fast_ctx == ctx && astSpecOn();   // canPend
        Value val = rn->expr ? evalNode(rn->expr, ctx, pend) : NONE_VALUE;
        if (pend && val.type == ValueType::NONE && f.pending) return val;   // raisedBy
        if (ctx && f.fast_ctx == ctx) { f.value = val; f.pending = 1; return val; }
        throw nython::node::ReturnSignal{val};
    }

    // ─── TRY / EXCEPT ───────────────────────────────────────────────────
    // ── Iteration protocol ─────────────────────────────────────────────
    // The values a `for` over `v` visits, in order: a list's items (a
    // generator here is a list), a map's keys, a string's characters, the
    // numbers below an integer (what range() returns on this engine), or an
    // instance's __iter__/__next__ protocol (a __getitem__ sequence without
    // __iter__ is indexed from 0 until IndexError).
    std::vector<Value> iterValues(const Value& v, Context* ctx) {
        std::vector<Value> out;
        if (v.type == ValueType::INTEGER) {
            int64_t n = bigint_to_i64(v.value.i);
            for (int64_t i = 0; i < n; i++) out.push_back(Value((int)i));
            return out;
        }
        // Lists, tuples, sets, generators, dicts (their typed keys) and
        // strings (by character): the shared iteration (iterItems).
        if ((v.isCollectable() && v.value.gc) || isStringValue(v) || isBytesValue(v)) return iterItems(v, ctx);
        // a class whose metaclass defines __iter__ (round 77)
        if (!class_meta_.empty() && classNodeOfValue(v)) return iterItems(v, ctx);
        if (isInstanceValue(v)) {
            if (rangeOrViewItems(v, out)) return out;   // round 78
            std::vector<Value> no_args;
            Value iterator = v;
            if (instanceHasMethod(v, "__iter__")) {
                iterator = callMethod(v, "__iter__", no_args, ctx);
                if (!isInstanceValue(iterator)) return iterValues(iterator, ctx);
            } else if (!instanceHasMethod(v, "__next__") && instanceHasMethod(v, "__getitem__")) {
                for (int i = 0; ; i++) {
                    std::vector<Value> ia{Value(i)};
                    try { out.push_back(callMethod(v, "__getitem__", ia, ctx)); }
                    catch (std::string& flow) {
                        if (excTypeMatches(flow, "IndexError") || excTypeMatches(flow, "StopIteration")) break;
                        throw;
                    }
                }
                return out;
            }
            if (!instanceHasMethod(iterator, "__next__"))
                throw std::string("__exc__:TypeError:'" + shownClassName(instanceClassName(v)) + "' object is not iterable");
            while (true) {
                try { out.push_back(callMethod(iterator, "__next__", no_args, ctx)); }
                catch (std::string& flow) {
                    if (excTypeMatches(flow, "StopIteration") || flow.find("StopIteration") != std::string::npos) break;
                    throw;
                }
            }
            return out;
        }
        if (v.type == ValueType::USERDATA && v.value.p && !func_names.count(v.value.p)) {
            const std::string& sv = *static_cast<std::string*>(v.value.p);
            for (size_t i = 0; i < sv.size(); i++) out.push_back(makeStringValue(std::string(1, sv[i])));
        }
        return out;
    }
    // Binds a for/comprehension target: a name, or a (nested) tuple of
    // targets unpacked from the value.
    void bindTarget(node_ptr target, const Value& v, Context* ctx) {
        if (!target) return;
        if (target->type() == NodeType::TUPLE || target->type() == NodeType::LIST) {
            std::vector<Value> items = iterValues(v, ctx);
            auto elems = target->statements();
            for (size_t i = 0; i < elems.size(); i++)
                bindTarget(elems[i], i < items.size() ? items[i] : NONE_VALUE, ctx);
            return;
        }
        ctx->defineByName(target->value(), v);
    }

    Value evalComprehensionNode(const node_ptr& node, Context* ctx) {
        auto cn = static_pointer_cast<ComprehensionNode>(node);
        // (x for x in it): a lazy generator, not a list (src/NyGen.cpp).
        if (cn->kind == ComprehensionNode::GEN) return nygen::make_genexpr(*this, node, ctx);
        // The targets live in the comprehension's own scope, as in Python 3:
        // `x = 10; [x for x in range(3)]` leaves x == 10.
        Context* cc = new Context(runner, "<comprehension>", nullptr, nullptr, ctx);
        CtxReaper _reap_cc(this, cc);
        std::vector<Value> items;
        std::vector<std::pair<Value, Value>> kvs;
        std::function<void(size_t)> clause = [&](size_t k) {
            auto& cl = cn->clauses[k];
            // The first iterable is evaluated in the enclosing scope.
            Value itv = evalNode(cl.iter, k == 0 ? ctx : cc);
            auto one = [&](const Value& item) {
                bindTarget(cl.target, item, cc);
                for (auto& c : cl.conds) if (!isTruthy(evalNode(c, cc))) return;
                if (k + 1 < cn->clauses.size()) clause(k + 1);
                else if (cn->kind == ComprehensionNode::DICT) {
                    Value kv = evalNode(cn->elt, cc);
                    kvs.push_back({kv, evalNode(cn->value, cc)});
                }
                else items.push_back(evalNode(cn->elt, cc));
            };
            // Over a generator, one value at a time: its side effects and
            // the element's interleave, as in Python.
            if (nygen::Gen* g = nygen::gen_of(itv)) {
                Value item;
                while (nygen::next(*this, g, item, cc)) one(item);
            } else if (int64_t ra, rb, rs, rn; rangeOf(itv, ra, rb, rs) && nyrt::range_len(ra, rb, rs, rn)) {
                // a range of 64-bit ints: counted (round 78)
                for (int64_t i = 0; i < rn; i++) one(intValue(nyrt::range_at(ra, rs, i)));
            } else if (isInstanceValue(itv)) {
                // An iterator object too (or an object whose __iter__ gives
                // one): it was read to the end before the first element was
                // made, so `[list(g) for k, g in groupby(...)]` saw every
                // group already invalidated.
                Value hold = nygen::make_iter(*this, itv, cc);
                if (nygen::Gen* g2 = nygen::gen_of(hold)) {
                    Value item;
                    while (nygen::next(*this, g2, item, cc)) one(item);
                } else {
                    std::vector<Value> no_args;
                    while (true) {
                        Value item;
                        try { item = callMethod(hold, "__next__", no_args, cc); }
                        catch (std::string& exc) {
                            if (excTypeMatches(exc, "StopIteration")) break;
                            throw;
                        }
                        one(item);
                    }
                }
            } else {
                for (auto& item : iterValues(itv, cc)) one(item);
            }
        };
        if (!cn->clauses.empty()) clause(0);
        if (cn->kind == ComprehensionNode::DICT) {
            // Keys keep their type (1, "1" and 1.0 as Python treats them).
            Value d = makeDictValue();
            Container* cont = contOf(d);
            for (auto& [k, v] : kvs) dictSet(cont, k, v);
            return d;
        }
        Value lst = makeListValue(items);
        if (cn->kind == ComprehensionNode::SET) {
            std::vector<Value> sa{lst};
            return callBuiltin("set", sa, ctx);
        }
        return lst;
    }

    Value evalComprehension(const node_ptr& node, Context* ctx) {
        auto cn = static_pointer_cast<ComplexNode>(node);
        if (cn->items.size() < 2) return NONE_VALUE;
        // List comprehension: [expr for var in iterable if cond]
        std::string var_name = cn->tok().value;
        node_ptr expr_node = cn->items[0];
        node_ptr iter_node = cn->items[1];
        node_ptr filter_node = (cn->items.size() >= 3) ? cn->items[2] : nullptr;

        Value iterable = evalNode(iter_node, ctx);
        auto* result = new Object((Runnable*)runner, "list", Type::LIST);
        int idx = 0;

        if (iterable.isCollectable() && iterable.value.gc) {
            auto* cont = dynamic_cast<Container*>(iterable.value.gc);
            if (cont && cont->container) {
                auto len_it = cont->container->find("__len__");
                int len = (len_it != cont->container->end()) ? (int)bigint_to_i64(len_it->second.value.i) : 0;
                // Check for nested for (items[3] = var2, items[4] = iterable2)
                bool has_nested = (cn->items.size() >= 5 && cn->items[3] && cn->items[4]);
                for (int i = 0; i < len; i++) {
                    auto it = cont->container->find(std::to_string(i));
                    if (it == cont->container->end()) continue;
                    ctx->defineByName(var_name, it->second);
                    if (has_nested) {
                        std::string var2 = cn->items[3]->value();
                        Value iter2 = evalNode(cn->items[4], ctx);
                        if (iter2.isCollectable() && iter2.value.gc) {
                            auto* cont2 = dynamic_cast<Container*>(iter2.value.gc);
                            if (cont2 && cont2->container) {
                                auto li2 = cont2->container->find("__len__");
                                int len2 = (li2 != cont2->container->end()) ? (int)bigint_to_i64(li2->second.value.i) : 0;
                                for (int j = 0; j < len2; j++) {
                                    auto it2 = cont2->container->find(std::to_string(j));
                                    if (it2 == cont2->container->end()) continue;
                                    ctx->defineByName(var2, it2->second);
                                    if (filter_node && cn->items[2]) {
                                        Value fv = evalNode(filter_node, ctx);
                                        if (!isTruthy(fv)) continue;
                                    }
                                    result->set(std::to_string(idx++), evalNode(expr_node, ctx));
                                }
                            }
                        }
                    } else {
                        if (filter_node && cn->items.size() >= 3 && cn->items[2]) {
                            Value fv = evalNode(filter_node, ctx);
                            if (!isTruthy(fv)) continue;
                        }
                        result->set(std::to_string(idx++), evalNode(expr_node, ctx));
                    }
                }
            }
        }
        result->set("__len__", Value(idx));
        return Value((Collectable*)result);
        // =====================================================================

    }

    // The ClassNode declared under `name`, or nullptr (an interface, a
    // builtin, or nothing).
    Node* classNodeByName(const std::string& name) {
        auto it = class_by_name.find(name);
        if (it == class_by_name.end()) return nullptr;
        Node* n = (Node*)it->second;
        return (n && n->type() == NodeType::CLASS) ? n : nullptr;
    }
    std::string instanceClassName(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return std::string();
        auto fn_it = func_names.find(v.value.p);
        if (fn_it != func_names.end() && fn_it->second.rfind("__instance__:", 0) == 0)
            return fn_it->second.substr(13);
        auto cit = instance_to_class.find(v.value.p);
        if (cit != instance_to_class.end())
            for (auto& kv : class_by_name) if (kv.second == cit->second) return kv.first;
        return std::string();
    }
    // A list value holding `items`.
    // The items of a list-like value, in order.
    std::vector<Value> listItems(const Value& v) {
        std::vector<Value> out;
        if (!v.isCollectable() || !v.value.gc) return out;
        auto* cont = dynamic_cast<Container*>(v.value.gc);
        if (!cont || !cont->container) return out;
        auto li = cont->container->find("__len__");
        int n = li != cont->container->end() ? (int)bigint_to_i64(li->second.value.i) : 0;
        for (int i = 0; i < n; i++) {
            auto it = cont->container->find(std::to_string(i));
            out.push_back(it != cont->container->end() ? it->second : NONE_VALUE);
        }
        return out;
    }
    // Sets an exception instance's args from the constructor or
    // super().__init__ arguments (Python's BaseException.__new__ and
    // __init__), and the fields some classes make of them (round 77):
    // OSError(errno, strerror[, filename[, winerror[, filename2]]]) - whose
    // args are then (errno, strerror) -, UnicodeDecodeError/EncodeError(
    // encoding, object, start, end, reason), UnicodeTranslateError(object,
    // start, end, reason), StopIteration.value, SystemExit.code. A field the
    // arguments do not give keeps what it had (None at first), as in CPython;
    // the legacy `msg` attribute is gone - super().__init__ overwrote the one
    // a subclass's __init__ had computed.
    std::unordered_map<std::string, int> exc_kind_cache_;
    int excKindOf(const std::string& cn) {
        auto it = exc_kind_cache_.find(cn);
        if (it != exc_kind_cache_.end()) return it->second;
        int k = nython::ny_exc_kind([&](const char* b) { return classDerivesFrom(cn, b); });
        exc_kind_cache_[cn] = k;
        return k;
    }
    void setExceptionArgs(const Value& inst, const std::vector<Value>& args) {
        auto pit = instance_properties.find(inst.value.p);
        if (pit == instance_properties.end()) return;
        Context* props = pit->second;
        std::string cn = instanceClassName(inst);
        int kind = excKindOf(cn);
        auto field = [&](const char* k, const Value& v, bool given) {
            if (given || !props->container || !props->container->count(k)) props->defineByName(k, given ? v : NONE_VALUE);
        };
        std::vector<Value> a = args;
        if (kind == nython::NYX_OS) {
            bool p = args.size() >= 2 && args.size() <= 5;
            field("errno", p ? args[0] : NONE_VALUE, p);
            field("strerror", p ? args[1] : NONE_VALUE, p);
            field("filename", p && args.size() >= 3 ? args[2] : NONE_VALUE, p);
            field("filename2", p && args.size() == 5 ? args[4] : NONE_VALUE, p);
#ifdef _WIN32
            // winerror, on Windows as in CPython: the errno is the one the
            // Windows error maps to (round 77)
            {
                bool w = p && args.size() >= 4 && args[3].type != ValueType::NONE;
                field("winerror", w ? args[3] : NONE_VALUE, p);
                Num wn;
                if (w && asNum(args[3], wn) && wn.k == 1) field("errno", intValue((int64_t)nython::ny_winerror_to_errno((long)wn.i)), true);
            }
#endif
            if (p && args.size() >= 3 && args[2].type != ValueType::NONE) a.resize(2);
        } else if (kind == nython::NYX_UDECODE || kind == nython::NYX_UENCODE || kind == nython::NYX_UTRANSLATE) {
            bool tr = kind == nython::NYX_UTRANSLATE;
            bool p = args.size() == (tr ? 4u : 5u);
            size_t o = tr ? 0 : 1;
            field("encoding", p && !tr ? args[0] : NONE_VALUE, p);
            field("object", p ? args[o] : NONE_VALUE, p);
            field("start", p ? args[o + 1] : NONE_VALUE, p);
            field("end", p ? args[o + 2] : NONE_VALUE, p);
            field("reason", p ? args[o + 3] : NONE_VALUE, p);
        } else if (kind == nython::NYX_SYNTAX) {
            // SyntaxError(msg, (filename, lineno, offset, text[, end_lineno, end_offset]))
            field("msg", args.empty() ? NONE_VALUE : args[0], !args.empty());
            std::vector<Value> info;
            if (args.size() == 2) { Container* ic = contOf(args[1]); int64_t n = ic ? seqLen(ic) : -1; if (n >= 4 && n <= 6) info = listItems(args[1]); }
            for (int i = 0; i < 6; i++)
                field(nython::ny_syntax_fields()[i], i < (int)info.size() ? info[(size_t)i] : NONE_VALUE, !info.empty());
        } else if (kind == nython::NYX_IMPORT) {
            field("msg", args.size() == 1 ? args[0] : NONE_VALUE, args.size() == 1);
        }
        // round 80: ImportError's name/path, AttributeError's name/obj,
        // NameError's name (CPython 3.10+): None until given
        switch (excKwFamily(cn, kind)) {
            case 1: field("name", NONE_VALUE, false); field("path", NONE_VALUE, false); break;
            case 2: field("name", NONE_VALUE, false); field("obj", NONE_VALUE, false); break;
            case 3: field("name", NONE_VALUE, false); break;
            default: break;
        }
        props->defineByName("args", makeListValue(a, true));
        // StopIteration.value: a generator's return value (both engines).
        if (classDerivesFrom(cn, "StopIteration"))
            props->defineByName("value", args.empty() ? NONE_VALUE : args[0]);
        // SystemExit.code: exit(n) / sys.exit(n) (round 77)
        if (classDerivesFrom(cn, "SystemExit"))
            props->defineByName("code", args.empty() ? NONE_VALUE : args.size() == 1 ? args[0] : makeListValue(args, true));
    }
    int excKwFamily(const std::string& cn, int kind) {
        return nython::ny_exc_kw_family(kind == nython::NYX_IMPORT, classDerivesFrom(cn, "AttributeError"),
                                        classDerivesFrom(cn, "NameError"));
    }
    // ImportError(msg, name=, path=), AttributeError(msg, name=, obj=),
    // NameError(msg, name=) (round 80; other keywords are left to the
    // class's own __init__)
    void setExceptionKw(const Value& inst, const nyrt::OrderedKw<Value>& kw) {
        if (kw.empty() || !isInstanceValue(inst)) return;
        auto pit = instance_properties.find(inst.value.p);
        if (pit == instance_properties.end() || !pit->second) return;
        std::string cn = instanceClassName(inst);
        int fam = excKwFamily(cn, excKindOf(cn));
        for (auto& kv : kw) if (nython::ny_exc_kw_field(fam, kv.first)) pit->second->defineByName(kv.first, kv.second);
    }
    // The arguments of a builtin exception made from a runtime error's
    // message (round 77): an OSError's "[Errno N] text: 'name'" back into
    // (errno, strerror, filename, None, filename2), a codec error's fields
    // from the codec (nypy::last_unicode_error), a KeyError's key from its
    // repr (a str or int key; anything else stays the text).
    std::vector<Value> excArgsFromMessage(const std::string& t, const std::string& msg) {
        // a runtime error with no message is Type() - empty args, as CPython
        // (round 82: CancelledError() from cancel() had args ('',))
        if (msg.empty()) return {};
        int kind = excKindOf(t);
        if (kind == nython::NYX_OS) {
            nython::NyErrnoParts ep;
            if (nython::ny_parse_errno_message(msg, ep)) {
                std::vector<Value> a{intValue((int64_t)ep.err), makeStringValue(ep.strerror)};
                if (ep.has_win) {
                    // (errno, strerror, filename, winerror[, filename2])
                    a.push_back(ep.has_f1 ? makeStringValue(ep.f1) : NONE_VALUE);
                    a.push_back(intValue((int64_t)ep.winerror));
                    if (ep.has_f2) a.push_back(makeStringValue(ep.f2));
                    return a;
                }
                if (ep.has_f1) a.push_back(makeStringValue(ep.f1));
                if (ep.has_f2) { a.push_back(NONE_VALUE); a.push_back(makeStringValue(ep.f2)); }
                return a;
            }
        } else if (kind == nython::NYX_UDECODE || kind == nython::NYX_UENCODE) {
            const nypy::UnicodeErrInfo& ui = nypy::last_unicode_error();
            if (ui.msg == msg && ui.is_str == (kind == nython::NYX_UENCODE))
                return {makeStringValue(ui.encoding), ui.is_str ? makeStringValue(ui.object) : makeBytesValue(ui.object, false),
                        intValue(ui.start), intValue(ui.end), makeStringValue(ui.reason)};
        } else if (kind == nython::NYX_KEY) {
            std::string k;
            size_t i = 0;
            if (nython::ny_unquote_py(msg, i, k) && i == msg.size()) return {makeStringValue(k)};
            size_t d = msg.size() > 1 && msg[0] == '-' ? 1 : 0;
            if (msg.size() > d && msg.size() < 19 && msg.find_first_not_of("0123456789", d) == std::string::npos)
                return {intValue((int64_t)std::stoll(msg))};
        }
        return {makeStringValue(msg)};
    }
    // KeyError(key) raised by the runtime (a missing key, set.remove, ...):
    // the key itself is its argument, as in Python (round 77).
    [[noreturn]] void raiseKeyError(const Value& key) { throw keyErrorFlow(key); }
    // round 82: what raiseKeyError raises, not thrown
    std::string keyErrorFlow(const Value& key) {
        Node* cn = classNodeByName("KeyError");
        if (cn) {
            Value cv; cv.type = ValueType::USERDATA; cv.value.p = (void*)cn;
            std::vector<Value> a{key};
            static const nyrt::OrderedKw<Value> no_kw;
            Value inst = instantiateClass(cv, a, no_kw, global_ctx);
            if (isInstanceVal(inst)) {
                if (!handling_obj_.empty()) setExcContext(inst, handling_obj_.back().second);
                return rememberRaised("KeyError", inst);
            }
        }
        return "__exc__:KeyError:" + reprOf(key);
    }
    std::string valueToDisplay(const Value& v) {
        if (v.type == ValueType::USERDATA && v.value.p && instance_to_class.count(v.value.p))
            return instanceString(v, global_ctx);
        if (isStringValue(v)) return getStringValue(v);
        if (v.type == ValueType::USERDATA) return getStringValue(v);
        std::vector<Value> sa{v};
        return getStringValue(callBuiltin("str", sa, global_ctx));
    }
    // Python's BaseException.__str__ over the instance's args: "" for none,
    // str(arg) for one (KeyError: its repr), the args tuple's repr for more -
    // and OSError's / the Unicode errors' own, made from their fields (round
    // 77; CPython's Objects/exceptions.c).
    std::string exceptionMessage(const Value& inst) {
        auto pit = instance_properties.find(inst.value.p);
        if (pit == instance_properties.end() || !pit->second->container) return std::string();
        auto& pc = *pit->second->container;
        auto field = [&](const char* k) { auto it = pc.find(k); return it == pc.end() ? NONE_VALUE : it->second; };
        auto absent = [](const Value& v) { return v.type == ValueType::NONE || v.type == ValueType::UNDEFINED; };
        int kind = excKindOf(instanceClassName(inst));
        if (kind == nython::NYX_OS) {
            Value en = field("errno"), se = field("strerror"), f1 = field("filename"), f2 = field("filename2");
#ifdef _WIN32
            // a Windows error is shown by its own number (CPython's OSError_str)
            Value we = field("winerror");
            if (!absent(we) && !absent(se)) {
                if (!absent(f1)) return "[WinError " + strOf(we) + "] " + strOf(se) + ": " + reprOf(f1) + (absent(f2) ? std::string() : " -> " + reprOf(f2));
                return "[WinError " + strOf(we) + "] " + strOf(se);
            }
#endif
            if (!absent(f1))
                return "[Errno " + strOf(en) + "] " + strOf(se) + ": " + reprOf(f1) + (absent(f2) ? std::string() : " -> " + reprOf(f2));
            if (!absent(en) && !absent(se)) return "[Errno " + strOf(en) + "] " + strOf(se);
        } else if (kind == nython::NYX_UDECODE || kind == nython::NYX_UENCODE || kind == nython::NYX_UTRANSLATE) {
            Value ob = field("object"), sv = field("start"), ev = field("end");
            Num s, e;
            if (!absent(ob) && asNum(sv, s) && asNum(ev, e) && s.k == 1 && e.k == 1) {
                long long one = -1;
                if (kind == nython::NYX_UDECODE) {
                    if (auto* bo = bytesOf(ob)) if (s.i >= 0 && (size_t)s.i < bo->s.size() && e.i == s.i + 1) one = (unsigned char)bo->s[(size_t)s.i];
                } else if (isStringValue(ob) && e.i == s.i + 1 && s.i >= 0) {
                    auto chars = nypy::u8_chars(getStringValue(ob));
                    if ((size_t)s.i < chars.size()) { size_t j = 0; one = nypy::u8_decode(chars[(size_t)s.i], j); }
                }
                Value enc = field("encoding"), why = field("reason");
                return nython::ny_unicode_error_message(kind, absent(enc) ? std::string() : strOf(enc), one, s.i, e.i, strOf(why));
            }
        } else if (kind == nython::NYX_SYNTAX) {
            Value fn = field("filename"), ln = field("lineno");
            bool hf = isStringValue(fn), hl = ln.type == ValueType::INTEGER;
            if (hf || hl) {
                int64_t line = 0;
                if (hl) bigint_fits_i64(ln.value.i, line);
                return nython::ny_syntax_message(strOf(field("msg")), hf, hf ? getStringValue(fn) : std::string(), hl, line);
            }
        }
        auto ait = pc.find("args");
        if (ait == pc.end()) return std::string();
        std::vector<Value> items = listItems(ait->second);
        if (items.empty()) return std::string();
        if (items.size() == 1) return kind == nython::NYX_KEY ? reprOf(items[0]) : valueToDisplay(items[0]);
        return reprOf(ait->second);
    }
    // Python's BaseException.__repr__: Type(args...), the args as reprs.
    std::string exceptionRepr(const Value& inst, Context* ctx) {
        std::vector<Value> items;
        auto pit = instance_properties.find(inst.value.p);
        if (pit != instance_properties.end() && pit->second->container) {
            auto it = pit->second->container->find("args");
            if (it != pit->second->container->end()) items = listItems(it->second);
        }
        std::string r = shownClassName(instanceClassName(inst));
        size_t dot = r.rfind('.');
        if (dot != std::string::npos) r = r.substr(dot + 1);
        r += "(";
        for (size_t i = 0; i < items.size(); i++) r += (i ? ", " : "") + reprOf(items[i], ctx);
        return r + ")";
    }
    // str(instance): its __str__/__repr__, an exception's message, or
    // "<Class instance>".
    std::string instanceString(const Value& inst, Context* ctx) {
        std::vector<Value> sa{inst};
        return getStringValue(callBuiltin("str", sa, ctx ? ctx : global_ctx));
    }

    // ── Exceptions ──────────────────────────────────────────────────────
    // An exception travels as a std::string: "__exc__:Type:message" for a
    // builtin exception, "__exc__:Class:__obj__:<ptr>" for a raised instance
    // (the instance itself is kept in exc_instance_map_), or any other string
    // for a plain `raise "text"`.
    std::vector<std::string> handling_exc_;   // except clauses running, innermost last (bare raise)

    static std::string excTypeOf(const std::string& flow) {
        if (flow.size() > 8 && flow.compare(0, 8, "__exc__:") == 0) {
            size_t c = flow.find(':', 8);
            return flow.substr(8, c == std::string::npos ? std::string::npos : c - 8);
        }
        return std::string();
    }
    Value excInstanceOf(const std::string& flow) {
        size_t op = flow.find(":__obj__:");
        if (op == std::string::npos || flow.compare(0, 8, "__exc__:") != 0) return NONE_VALUE;
        // round 82: the serial read without a stream (one was made per read)
        uintptr_t ptr_val = (uintptr_t)std::strtoull(flow.c_str() + op + 9, nullptr, 16);
        auto eit = exc_instance_map_.find(reinterpret_cast<void*>(ptr_val));
        if (eit != exc_instance_map_.end()) return eit->second;
        // Evicted from the ring below while an except clause still handles it.
        for (auto it = handling_obj_.rbegin(); it != handling_obj_.rend(); ++it)
            if (it->first == flow) return it->second;
        return NONE_VALUE;
    }
    // A raised instance travels inside the exception string as a serial
    // number ("__exc__:C:__obj__:<serial>"), and this ring keeps the last
    // kExcRing raised instances alive for it to find (plus those an except
    // clause is handling, handling_obj_). A serial, not the address: a string
    // that outlives its entry must not find a newer object that reuses the
    // address. (Before round 75 every raised instance was kept forever.)
    static constexpr size_t kExcRing = 256;
    uint64_t exc_serial_ = 0;
    std::deque<void*> exc_ring_;
    std::vector<std::pair<std::string, Value>> handling_obj_;
    std::string rememberRaised(const std::string& class_name, const Value& v) {
        uint64_t serial = ++exc_serial_;
        void* key = reinterpret_cast<void*>((uintptr_t)serial);
        exc_instance_map_[key] = v;
        exc_ring_.push_back(key);
        while (exc_ring_.size() > kExcRing) {
            exc_instance_map_.erase(exc_ring_.front());
            exc_ring_.pop_front();
        }
        // round 82: spelled without a stream (one was made per raise)
        char hex[20];
        auto r = std::to_chars(hex, hex + sizeof hex, (unsigned long long)serial, 16);
        std::string out;
        out.reserve(17 + class_name.size() + (size_t)(r.ptr - hex));
        out.append("__exc__:").append(class_name).append(":__obj__:").append(hex, (size_t)(r.ptr - hex));
        return out;
    }
    // The exception object an except clause binds: the raised instance, or
    // for an error raised as "__exc__:Type:message" (runtime errors, native
    // builtins) a new instance of that builtin class with the message as its
    // argument; a plain message string when no such class exists.
    Value exceptionObject(const std::string& flow) {
        Value inst = excInstanceOf(flow);
        if (inst.type != ValueType::NONE) return inst;
        std::string t = excTypeOf(flow);
        Node* cn = t.empty() ? nullptr : classNodeByName(t);
        if (cn && flow.rfind("__exc__:", 0) == 0) {
            Value cv; cv.type = ValueType::USERDATA; cv.value.p = (void*)cn;
            if (fnTag(func_names, cv.value.p).rfind("__class__:", 0) == 0) {
                // the arguments the message stands for: an OSError's errno
                // and filename, a codec error's fields, a KeyError's key
                // (round 77)
                std::vector<Value> a = excArgsFromMessage(t, excMessageOf(flow));
                // StopIteration() / GeneratorExit() raised by the runtime
                // carry no argument (value is none, args empty).
                if ((t == "StopIteration" || t == "GeneratorExit") && excMessageOf(flow).empty()) a.clear();
                static const nyrt::OrderedKw<Value> no_kw;
                Value obj = instantiateClass(cv, a, no_kw, global_ctx);
                // its name field, from the message (round 80: e.name of a
                // ModuleNotFoundError, AttributeError, NameError)
                std::string nm;
                if (nython::ny_exc_name_from_message(excKwFamily(t, excKindOf(t)), excMessageOf(flow), nm)) {
                    auto pit = instance_properties.find(obj.value.p);
                    if (pit != instance_properties.end() && pit->second) pit->second->defineByName("name", makeStringValue(nm));
                }
                return obj;
            }
        }
        return makeStringValue(excMessageOf(flow));
    }
    // The message of an exception string: what str(e) gives in an except.
    std::string excMessageOf(const std::string& flow) {
        Value inst = excInstanceOf(flow);
        if (inst.type != ValueType::NONE) return instanceString(inst, global_ctx);
        if (flow.size() > 8 && flow.compare(0, 8, "__exc__:") == 0) {
            size_t c = flow.find(':', 8);
            // A raised instance no longer in the ring (rememberRaised): its
            // serial number is not a message.
            if (c != std::string::npos && flow.compare(c + 1, 8, "__obj__:") == 0) return std::string();
            return c == std::string::npos ? std::string() : flow.substr(c + 1);
        }
        return flow;
    }
    // "Type: message", the uncaught form.
    std::string describeException(const std::string& flow) {
        std::string t = excTypeOf(flow);
        std::string m = excMessageOf(flow);
        if (t.empty()) return m;
        return m.empty() ? t : t + ": " + m;
    }
    // Whether class `cls` is `want` or derives from it - through every base
    // of a user class, then Python's builtin exception hierarchy.
    // round 82: the answers, kept while no class name is bound anew and no
    // class statement's bases change (class_names_ver_): every except clause
    // tested and every exception made (isExceptionClass, setExceptionArgs'
    // four questions) walked class_by_name - a std::map by name - and the
    // builtin hierarchy by string (11% of the exceptions benchmark)
    uint64_t class_names_ver_ = 1, derives_memo_ver_ = 0;
    std::unordered_map<std::string, bool> derives_memo_;
    bool classDerivesFrom(const std::string& cls, const std::string& want, int depth = 0) {
        if (cls == want) return true;
        if (depth == 0 && astSpecOn()) {
            if (derives_memo_ver_ != class_names_ver_ || derives_memo_.size() > 8192) { derives_memo_.clear(); derives_memo_ver_ = class_names_ver_; }
            std::string key;
            key.reserve(cls.size() + want.size() + 1);
            key.append(cls).push_back('\x1f');
            key.append(want);
            auto it = derives_memo_.find(key);
            if (it != derives_memo_.end()) return it->second;
            bool r = classDerivesFromWalk(cls, want, 0);
            derives_memo_.emplace(std::move(key), r);
            return r;
        }
        return classDerivesFromWalk(cls, want, depth);
    }
    bool classDerivesFromWalk(const std::string& cls, const std::string& want, int depth) {
        if (cls == want) return true;
        if (depth > 32 || cls.empty()) return false;
        auto it = class_by_name.find(cls);
        if (it != class_by_name.end()) {
            Node* n = (Node*)it->second;
            if (n && n->type() == NodeType::CLASS)
                for (auto& b : static_cast<ClassNode*>(n)->bases)
                    if (classDerivesFrom(b->value(), want, depth + 1)) return true;
            return false;
        }
        return nython::ny_builtin_exc_is(cls, want);
    }
    bool isExceptionClass(const std::string& cls) { return classDerivesFrom(cls, "BaseException"); }
    // Python's rule for one type named in an except clause, plus Nython's
    // leniency: Exception/Error also catch a raised non-exception (a plain
    // string or an instance of an unrelated class).
    bool excTypeMatches(const std::string& flow, const std::string& t) {
        std::string t0 = excTypeOf(flow);
        if (t == "BaseException") return true;
        if (t == "Exception" || t == "Error")
            return !(classDerivesFrom(t0, "SystemExit") || classDerivesFrom(t0, "KeyboardInterrupt")
                     || classDerivesFrom(t0, "GeneratorExit") || classDerivesFrom(t0, "CancelledError"));
        if (t0.empty()) return flow == t;           // raise "StopIteration"
        return classDerivesFrom(t0, t);
    }
    bool excClauseMatches(ExceptNode* en, const std::string& flow, Context* ctx = nullptr) {
        if (en->types.empty()) return true;
        for (auto& t : en->types) {
            // round 80: a name bound to a tuple of classes (`except ERRORS:`)
            // catches what any of them catches, as in Python
            std::vector<Value> tup;
            std::string cn = ctx ? excClassName(t, ctx, &tup) : t;
            if (!tup.empty()) { if (excTupleMatches(flow, tup, 0)) return true; continue; }
            if (excTypeMatches(flow, cn)) return true;
        }
        return false;
    }
    bool excTupleMatches(const std::string& flow, const std::vector<Value>& items, int depth) {
        for (auto& v : items) {
            if (Container* c = contOf(v)) {
                if (depth < 16 && seqLen(c) >= 0 && isTupleCont(c) && excTupleMatches(flow, seqItems(c), depth + 1)) return true;
                continue;
            }
            if (v.type == ValueType::USERDATA && v.value.p) {
                auto it = func_names.find(v.value.p);
                if (it != func_names.end() && it->second.rfind("__class__:", 0) == 0 && excTypeMatches(flow, it->second.substr(10)))
                    return true;
            }
        }
        return false;
    }
    // The class an except clause names, as the name the class is known by:
    // `except E` looks E up in scope (round 77), so a module's own class
    // (named "module.E"), an alias (`Err = ValueError`) and a dotted name
    // (`except socket.error`, `except asyncio.QueueEmpty`) all match what
    // they name. A builtin exception name, or a name that is not bound to a
    // class, matches by name as before (the last part of a dotted one).
    std::string excClassName(const std::string& t, Context* ctx, std::vector<Value>* tuple_items = nullptr) {
        if (t.empty() || nython::ny_is_builtin_exc(t)) return t;
        size_t dot = t.find('.');
        Value v = ctx->getByName(dot == std::string::npos ? t : t.substr(0, dot));
        while (v.type != ValueType::UNDEFINED && dot != std::string::npos) {
            size_t next = t.find('.', dot + 1);
            std::string part = t.substr(dot + 1, next == std::string::npos ? std::string::npos : next - dot - 1);
            try { v = attrOf(v, part); } catch (...) { v = UNDEFINED_VALUE; }
            dot = next;
        }
        if (tuple_items)   // round 80: a tuple of classes (excClauseMatches)
            if (Container* c = contOf(v)) if (seqLen(c) >= 0 && isTupleCont(c)) { *tuple_items = seqItems(c); return std::string(); }
        if (v.type == ValueType::USERDATA && v.value.p) {
            auto it = func_names.find(v.value.p);
            if (it != func_names.end() && it->second.rfind("__class__:", 0) == 0) return it->second.substr(10);
        }
        size_t last = t.rfind('.');
        return last == std::string::npos ? t : t.substr(last + 1);
    }
    // A C++ exception from a builtin, as a tagged exception string.
    static std::string excFromCpp(const std::string& what) {
        std::string t, m;
        if (nython::ny_split_exc_message(what, t, m)) return "__exc__:" + t + ":" + m;
        return "__exc__:Exception:" + what;
    }

    // ── Frames and tracebacks (round 77) ────────────────────────────────
    // The frames running on this thread (or async task, or generator body -
    // InterpEngine::State and NyGen keep them apart), innermost last: what
    // _ny_stack() reports (sys._getframe, traceback.extract_stack,
    // warnings' stacklevel) and what e.__traceback__ is made of. `code` is
    // the FunctionNode / LambdaNode (nullptr: a module's top level),
    // `call_site` the caller's statement when the frame began - so the
    // caller's current line while it runs - and `ctx` its scope (whose
    // __name__ is the frame's module). The main program's top level is the
    // frame below them all; its line is the first frame's call_site.
    // `fobj` (round 78): the frame's Python frame object, once a program has
    // asked for one (frameObject below) - a counted reference; null for
    // every call nobody asks about.
    struct PyFrame { Node* code; Node* call_site; Context* ctx; nyheap::Inst* fobj = nullptr; };
    using PyFrames = std::vector<PyFrame>;
    static PyFrames& py_frames() { static thread_local PyFrames v; return v; }
    // The running frame's current statement: last_stmt() as a plain pointer,
    // put back to the caller's when a frame ends (last_stmt() is not: an
    // uncaught error reports the innermost statement).
    static Node*& cur_stmt() { static thread_local Node* p = nullptr; return p; }
    struct FrameGuard {
        FrameGuard(Node* code, Context* ctx) { py_frames().push_back({code, cur_stmt(), ctx}); }
        ~FrameGuard() {
            if (py_frames().back().fobj) frameEnded();   // round 78
            cur_stmt() = py_frames().back().call_site; py_frames().pop_back();
        }
    };
    // An exception on its way out: the frames it has left so far, innermost
    // first, recorded as it unwinds through each frame (tbUnwind) and made
    // into e.__traceback__ where an except clause catches it (tbCaught) -
    // CPython's PyTraceBack_Here, one entry per frame the exception passes.
    // A record is the exception string's while that string keeps unwinding:
    // `last` (the statement then) and `depth` (the frames then) tell it from
    // a record of an exception native code caught and dropped (hasattr, a
    // loop's StopIteration), which a new exception must not continue.
    struct TbRec { std::string file; int64_t line; std::string name; std::string mod; Value frame; };   // frame: round 78
    struct TbPending {
        std::string flow;
        std::vector<TbRec> recs;
        Node* line = nullptr;         // the current frame's line for it (where it entered the frame)
        Node* last = nullptr;         // cur_stmt() as this left it
        size_t depth = 0;             // py_frames().size() then
        bool active = false;
        bool reraise = false;         // a bare raise: that frame already heads its traceback
    };
    static TbPending& tb_pending() { static thread_local TbPending p; return p; }
    // The prelude's frames are not shown (its source is named "stdin"), as
    // CPython shows no frame for a builtin written in C.
    static bool tbHiddenFile(const std::string& f) { return f == "stdin"; }
    static std::string frameName(Node* code) {
        if (!code) return "<module>";
        if (code->type() == NodeType::FUNCTION) {
            const std::string& n = static_cast<FunctionNode*>(code)->name;
            return n.empty() ? std::string("<lambda>") : n;
        }
        return "<lambda>";
    }
    std::string frameModule(Context* c) {
        Value v = c ? c->getByName("__name__") : UNDEFINED_VALUE;
        return isStringValue(v) ? getStringValue(v) : std::string("__main__");
    }
    // A lambda runs no statement of its own: its line is the lambda's.
    static Node* frameLine(const PyFrame& f, Node* cur) {
        return f.code && f.code->type() == NodeType::LAMBDA ? f.code : cur;
    }
    // `idx`: the frame's place in py_frames() (kNoFrame: the main
    // program's top level), whose frame object the entry gets (round 78).
    void tbRecord(TbPending& P, Node* where, const PyFrame& fr, size_t idx) {
        if (!where) return;
        const auto& tk = where->tok();
        std::string file = tk.fileName();
        if (tbHiddenFile(file)) return;
        P.recs.push_back({std::move(file), (int64_t)tk.line(), frameName(fr.code), frameModule(fr.ctx), frameObject(idx, where, false)});
        tb_frames_held() = true;
    }
    // The frame objects a record holds keep their frames' locals alive; an
    // exception native code caught and dropped (a generator's close,
    // hasattr, a loop's StopIteration) leaves its record behind, so they go
    // at the next statement (noteStatement - no exception propagates across
    // a statement boundary: finally bodies and handlers save or take the
    // record first) and when close() swallows GeneratorExit (round 78).
    static bool& tb_frames_held() { static thread_local bool b = false; return b; }
    static void tbDropFrames() {
        tb_frames_held() = false;
        for (auto& r : tb_pending().recs) r.frame = Value();
    }
    bool tbContinues(const TbPending& P, const std::string& flow) {
        return P.active && P.depth == py_frames().size() && P.last == cur_stmt() && P.flow == flow;
    }
    // `flow` is leaving the innermost frame.
    void tbUnwind(const std::string& flow) {
        if (flow == "break" || flow == "continue") return;
        auto& F = py_frames();
        if (F.empty()) return;
        auto& P = tb_pending();
        bool skip = false;
        Node* where = cur_stmt();
        if (tbContinues(P, flow)) {
            if (P.line) where = P.line;
            if (P.reraise) { skip = true; P.reraise = false; }
        } else {
            P.flow = flow; P.recs.clear(); P.active = true; P.reraise = false;
        }
        const PyFrame& top = F.back();
        if (!skip) tbRecord(P, frameLine(top, where), top, F.size() - 1);
        P.depth = F.size() - 1;
        P.line = P.last = top.call_site;   // the caller's line; cur_stmt() once this frame is gone
    }
    // `flow` has reached the running frame and code (a finally body, a
    // handler) is about to run there: its line in this frame is the one
    // running now, whatever that code runs.
    void tbSee(const std::string& flow) {
        if (flow == "break" || flow == "continue") return;
        auto& P = tb_pending();
        if (tbContinues(P, flow)) { if (!P.line) P.line = cur_stmt(); return; }
        P.flow = flow; P.recs.clear(); P.active = true; P.reraise = false;
        P.line = P.last = cur_stmt();
        P.depth = py_frames().size();
    }
    // `flow` is raised again from the running frame as it is (a bare raise,
    // a with statement whose __exit__ did not suppress it): that frame is
    // already the head of its traceback.
    void tbReraise(const std::string& flow) {
        auto& P = tb_pending();
        P.flow = flow; P.recs.clear(); P.active = true; P.reraise = true;
        P.line = P.last = cur_stmt();
        P.depth = py_frames().size();
    }
    Context* instanceProps(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        auto it = instance_properties.find(v.value.p);
        return it == instance_properties.end() ? nullptr : it->second;
    }
    // A traceback entry: a prelude _NyTraceback whose fields the engine sets
    // - tb_next, tb_lineno and _ny_loc ("file\x1ffunction\x1fmodule"); its
    // tb_frame is made from them when first read (the VM's tb_here is the same).
    Node* tb_class_ = nullptr;
    Value makeTbValue(const TbRec& r, const Value& next) {
        if (!tb_class_) tb_class_ = classNodeByName("_NyTraceback");
        if (!tb_class_) return next;
        Value tb = newInstance("_NyTraceback", (void*)tb_class_);
        Context* p = instanceProps(tb);
        if (!p) return next;
        p->defineByName("tb_next", next);
        p->defineByName("tb_lineno", intValue(r.line));
        p->defineByName("_ny_loc", makeStringValue(r.file + '\x1f' + r.name + '\x1f' + r.mod));
        if (isInstanceVal(r.frame)) p->defineByName("_ny_frame", r.frame);   // round 78: the frame itself
        return tb;
    }
    // e.__context__ = c, as Python sets it when e is raised while c is
    // being handled - without making a cycle (a link back to e is cut).
    void setExcContext(const Value& inst, const Value& c) {
        Context* ip = instanceProps(inst);
        if (!ip || !isInstanceVal(c) || c.value.p == inst.value.p) return;
        Value o = c;
        for (int guard = 0; guard < 1000; guard++) {
            Context* op = instanceProps(o);
            if (!op) break;
            Value nx = op->getByName("__context__");
            if (!isInstanceVal(nx)) break;
            if (nx.value.p == inst.value.p) { op->defineByName("__context__", NONE_VALUE); break; }
            o = nx;
        }
        ip->defineByName("__context__", c);
    }
    // A runtime error (no object yet) leaving an except clause: the exception
    // that clause handles becomes its __context__ when it is made.
    std::string pending_ctx_flow_;
    Value pending_ctx_;
    void tbHandlerExit(const std::string& flow) {
        if (flow == "break" || flow == "continue" || handling_obj_.empty() || handling_exc_.empty()) return;
        if (flow == handling_exc_.back() || isInstanceVal(excInstanceOf(flow))) return;
        pending_ctx_flow_ = flow;
        pending_ctx_ = handling_obj_.back().second;
    }
    // An except clause (or a with statement's __exit__) receives `exc`: its
    // object is made if it is a runtime error, the frames it unwound become
    // its __traceback__ (ahead of what it had: a re-raised exception keeps
    // its old frames, as in Python) and the string that now carries it is
    // returned.
    std::string tbCaught(const std::string& exc) {
        auto& F = py_frames();
        auto& P = tb_pending();
        Node* where = cur_stmt();
        bool skip = false;
        if (tbContinues(P, exc)) { skip = P.reraise; if (P.line) where = P.line; }
        else P.recs.clear();
        if (!skip) {
            PyFrame here{nullptr, nullptr, global_ctx};
            if (!F.empty()) here = F.back();
            tbRecord(P, frameLine(here, where), here, F.empty() ? kNoFrame : F.size() - 1);
        }
        P.active = false; P.reraise = false; P.line = nullptr;
        std::vector<TbRec> recs;
        recs.swap(P.recs);
        Value inst = excInstanceOf(exc);
        std::string out = exc;
        bool fresh = false;
        if (!isInstanceVal(inst)) {
            Value obj = exceptionObject(exc);
            if (!isInstanceVal(obj)) return exc;
            inst = obj;
            fresh = true;
            out = rememberRaised(instanceClassName(obj), obj);
        }
        Context* props = instanceProps(inst);
        if (!props) return out;
        Value tb = props->getByName("__traceback__");
        if (!isInstanceVal(tb)) tb = NONE_VALUE;
        for (auto& r : recs) tb = makeTbValue(r, tb);
        props->defineByName("__traceback__", tb);
        if (fresh) {
            if (!pending_ctx_flow_.empty() && pending_ctx_flow_ == exc) setExcContext(inst, pending_ctx_);
            else if (!handling_obj_.empty()) setExcContext(inst, handling_obj_.back().second);
        }
        pending_ctx_flow_.clear();
        pending_ctx_ = NONE_VALUE;
        return out;
    }
    // A finally body run while an exception propagates: when it completes,
    // the exception's record is as it was (whatever the body raised and
    // caught inside).
    template <class Fn> void tbFinally(Fn&& f) {
        TbPending saved = tb_pending();
        f();
        if (flow().pending) return;   // round 82: its own flow replaced the exception (as when it throws)
        tb_pending() = std::move(saved);
        tb_pending().last = cur_stmt();
        for (auto& r : tb_pending().recs) if (r.frame.value.o) { tb_frames_held() = true; break; }   // round 78
    }
    // The uncaught exception `flow` at the top of the program: its object
    // with the whole traceback (main.cpp reports it), or none.
    Value uncaughtException(const std::string& flow) {
        std::string f = tbCaught(flow);
        return excInstanceOf(f);
    }
    // Python's traceback of it, the chained exceptions first, without the
    // last line (main.cpp's own line follows): the prelude's
    // _ny_format_uncaught. The statement an uncaught error reports stays.
    Value uncaught_obj_;
    std::string uncaughtTracebackText(const std::string& flow) {
        node_ptr saved = last_stmt();
        std::string out;
        try {
            Value inst = isInstanceVal(uncaught_obj_) ? uncaught_obj_ : uncaughtException(flow);
            uncaught_obj_ = Value();
            Value f = global_ctx ? global_ctx->getByName("_ny_format_uncaught") : UNDEFINED_VALUE;
            if (isInstanceVal(inst) && f.type == ValueType::USERDATA) {
                std::vector<Value> a{inst};
                Value r = callFunctionValue(f, a, global_ctx);
                if (isStringValue(r)) out = getStringValue(r);
                else if (r.type == ValueType::NONE) uncaught_hooked_ = true;   // sys.excepthook ran (round 80)
            }
        } catch (...) {}
        last_stmt() = saved;
        return out;
    }
    bool uncaught_hooked_ = false;
    // The exit handlers lib/atexit.ny registered, when the program ends
    // (the prelude's _ny_run_atexit).
    // threading._register_atexit's callbacks (round 80): before the program's
    // non-daemon threads are waited for (main.cpp), as CPython's
    // threading._shutdown runs them.
    void runThreadingAtexit() {
        Value f = global_ctx ? global_ctx->getByName("_ny_run_threading_atexit") : UNDEFINED_VALUE;
        if (f.type != ValueType::USERDATA) return;
        if (listItems(global_ctx->getByName("_ny_threading_atexits")).empty()) return;
        node_ptr saved = last_stmt();
        std::vector<Value> a;
        try { callFunctionValue(f, a, global_ctx); } catch (...) {}
        last_stmt() = saved;
    }
    void runAtexit() {
        Value f = global_ctx ? global_ctx->getByName("_ny_run_atexit") : UNDEFINED_VALUE;
        if (f.type != ValueType::USERDATA) return;
        // none registered: no call (nothing for --profile to count)
        if (listItems(global_ctx->getByName("_ny_atexit_handlers")).empty()) return;
        node_ptr saved = last_stmt();
        std::vector<Value> a;
        try { callFunctionValue(f, a, global_ctx); } catch (...) {}
        last_stmt() = saved;
    }
    // _ny_stack(): the running frames, innermost first, as
    // (filename, lineno, function name, module name) - the prelude's left out.
    Value pyStackValue() {
        auto& F = py_frames();
        std::vector<Value> out;
        auto add = [&](Node* where, const PyFrame& fr) {
            if (!where) return;
            const auto& tk = where->tok();
            std::string file = tk.fileName();
            if (tbHiddenFile(file)) return;
            std::vector<Value> t{makeStringValue(file), intValue((int64_t)tk.line()),
                                 makeStringValue(frameName(fr.code)), makeStringValue(frameModule(fr.ctx))};
            out.push_back(makeListValue(t, true));
        };
        Node* cur = cur_stmt();
        for (size_t i = F.size(); i-- > 0;) {
            add(frameLine(F[i], cur), F[i]);
            cur = F[i].call_site;
        }
        add(cur, PyFrame{nullptr, nullptr, global_ctx});
        return makeListValue(out);
    }

    // ── Frame objects (round 78) ────────────────────────────────────────
    // A Python frame object - a prelude _NyFrame whose fields are set here,
    // no __init__ run - is made for a running frame only when a program
    // asks for one: sys._getframe() / inspect.currentframe()
    // (_ny_frame_get), a traceback entry (tbRecord), a generator's gi_frame
    // (NyGen.cpp). The frame's record keeps it (PyFrame::fobj), so the same
    // object comes back each time. While the call runs, f_lineno and
    // f_locals are read from the record (_ny_frame_sync: the locals as
    // locals() gives them, a new dict each read) and f_back is the caller's
    // frame (_ny_frame_back). When the call ends (frameEnded), a frame
    // object referenced elsewhere keeps its last line and locals and its
    // caller's frame object; one nobody else holds just goes. A call nobody
    // asks about pays one pointer test when it ends. The VM's are the same
    // (VirtualMachine::frame_object).
    static constexpr size_t kNoFrame = (size_t)-1;   // the main program's top level
    Node* frame_class_ = nullptr;
    nyheap::Inst* main_fobj_ = nullptr;              // its frame object (counted)
    // The statement frame `idx` is at: the running one for the innermost,
    // else the call it is making (the next frame's call site).
    Node* frameWhere(size_t idx) {
        auto& F = py_frames();
        if (idx == kNoFrame) return F.empty() ? cur_stmt() : F[0].call_site;
        return frameLine(F[idx], idx + 1 < F.size() ? F[idx + 1].call_site : cur_stmt());
    }
    // The prelude's frames are not shown (as in _ny_stack)
    bool frameVisible(size_t idx) {
        Node* w = frameWhere(idx);
        return w && !tbHiddenFile(w->tok().fileName());
    }
    nyheap::Inst*& frameSlot(size_t idx) { return idx == kNoFrame ? main_fobj_ : py_frames()[idx].fobj; }
    Context* frameCtx(size_t idx) { return idx == kNoFrame ? global_ctx : py_frames()[idx].ctx; }
    static Value instValue(nyheap::Inst* o) { return nyheap::userValue(o, (void*)&o->tag); }
    // The frame's code as _ny_fn_info gives a function's (the prelude's
    // _NyFuncCode reads it); a module's top level is "<module>".
    struct FrameInfoMemo { std::string name; int64_t line; Value info; };
    std::unordered_map<Node*, FrameInfoMemo> frame_info_memo_;   // per function node (a node freed and reused is told apart by name and line)
    Value frameInfo(Node* code, Context* ctx, Node* where) {
        if (code) {
            auto* fnode = dynamic_cast<FunctionNode*>(code);
            std::string nm = fnode ? fnode->name : std::string("<lambda>");
            int64_t ln = (int64_t)code->tok().line();
            auto it = frame_info_memo_.find(code);
            if (it != frame_info_memo_.end() && it->second.name == nm && it->second.line == ln
                && (!fnode || fn_qualname_.empty())) return it->second.info;
            Value info = fnInfoOf(code, nullptr, ctx);
            if (info.type != ValueType::NONE) {
                frame_info_memo_[code] = FrameInfoMemo{nm, ln, info};
                return info;
            }
        }
        std::string file = where ? where->tok().fileName() : std::string("<unknown>");
        return makeListValue({makeStringValue("<module>"), makeStringValue("<module>"), makeStringValue(frameModule(ctx)),
                              makeListValue({}), intValue((int64_t)0), makeStringValue(file), intValue((int64_t)1)});
    }
    // A frame object's line and locals, as of now (`line` when there is no
    // statement: a generator that has not started is at its def line).
    void frameStore(nyheap::Inst* o, Node* where, Context* ctx, int64_t line = 0, bool with_locals = true) {
        Context* p = o ? o->props : nullptr;
        if (!p) return;
        if (where) line = (int64_t)where->tok().line();
        p->defineByName("_ny_line", intValue(line));
        p->defineByName("_ny_lasti", intValue(line * 2));   // no instruction offsets here: approximate
        if (with_locals) p->defineByName("_ny_locals", ctx ? reflectLocals(ctx) : reflectGlobals(nullptr));
    }
    // A new frame object for code running in ctx (nobody keeps it yet).
    Value newFrameObject(Node* code, Context* ctx, Node* where, int64_t line = 0, bool with_locals = true) {
        if (!frame_class_) frame_class_ = classNodeByName("_NyFrame");
        if (!frame_class_) return NONE_VALUE;
        Value fo = newInstance("_NyFrame", (void*)frame_class_);
        auto* o = static_cast<nyheap::Inst*>(fo.value.o);
        if (!o || !o->props) return NONE_VALUE;
        o->props->defineByName("_ny_info", frameInfo(code, ctx, where));
        frameStore(o, where, ctx, line, with_locals);
        return fo;
    }
    // The frame object of frame `idx` (made now if it has none). Its locals
    // are copied when they are read (the frame runs) or when the frame ends,
    // not now - a traceback's frames cost no copy until then.
    Value frameObject(size_t idx, Node* where, bool with_locals = false) {
        if (nyheap::Inst* o = frameSlot(idx)) return instValue(o);
        Value fo = newFrameObject(idx == kNoFrame ? nullptr : py_frames()[idx].code, frameCtx(idx), where, 0, with_locals);
        if (!isInstanceVal(fo)) return NONE_VALUE;
        auto* o = static_cast<nyheap::Inst*>(fo.value.o);
        nygc::incref(o);
        frameSlot(idx) = o;
        return fo;
    }
    // Where frame object `fo` runs on this thread (its record), if it does.
    bool frameFind(const Value& fo, size_t& idx) {
        if (!isInstanceVal(fo) || !fo.value.o) return false;
        const Collectable* o = fo.value.o;
        if (main_fobj_ && (const Collectable*)main_fobj_ == o) { idx = kNoFrame; return true; }
        auto& F = py_frames();
        for (size_t i = F.size(); i-- > 0;)
            if (F[i].fobj && (const Collectable*)F[i].fobj == o) { idx = i; return true; }
        return false;
    }
    // The visible frame that called frame `idx`.
    bool frameCaller(size_t idx, size_t& out) {
        if (idx == kNoFrame) return false;
        for (size_t j = idx; j-- > 0;) if (frameVisible(j)) { out = j; return true; }
        if (frameVisible(kNoFrame)) { out = kNoFrame; return true; }
        return false;
    }
    // _ny_frame_get(depth): sys._getframe(depth) - 0 is the innermost
    // visible frame (the caller of the prelude's sys._getframe).
    Value frameGet(std::vector<Value>& args) {
        int64_t depth = 0;
        if (!args.empty() && args[0].type == ValueType::INTEGER) depth = bigint_to_i64(args[0].value.i);
        else if (!args.empty() && args[0].type == ValueType::BOOLEAN) depth = args[0].value.b ? 1 : 0;
        if (depth < 0) depth = 0;
        auto& F = py_frames();
        int64_t seen = 0;
        for (size_t i = F.size(); i-- > 0;) {
            if (!frameVisible(i)) continue;
            if (seen++ == depth) return frameObject(i, frameWhere(i));
        }
        if (seen == depth && frameVisible(kNoFrame)) return frameObject(kNoFrame, frameWhere(kNoFrame));
        pyRaise("ValueError", "call stack is not deep enough");
        return NONE_VALUE;
    }
    // _ny_frame_sync(f): whether f's call is running on this thread; if so
    // its f_lineno / f_locals are refreshed from it.
    Value frameSync(const Value& fo) {
        size_t idx;
        if (!frameFind(fo, idx)) return Value(false);
        frameStore(frameSlot(idx), frameWhere(idx), frameCtx(idx));
        return Value(true);
    }
    // _ny_frame_back(f): f.f_back - the caller's frame while f runs, the
    // one it had when it ended afterwards.
    Value frameBack(const Value& fo) {
        size_t idx, c;
        if (frameFind(fo, idx)) return frameCaller(idx, c) ? frameObject(c, frameWhere(c)) : NONE_VALUE;
        Context* p = instanceProps(fo);
        Value b = p ? p->getByName("_ny_back") : NONE_VALUE;
        return isInstanceVal(b) ? b : NONE_VALUE;
    }
    // _ny_frame_globals(f): f.f_globals - round 81: its module's live
    // globals() view (sys._getframe(1).f_globals["x"] = v binds x in the
    // caller's module, as CPython); it was a copy.
    Value frameGlobals(std::vector<Value>& args) {
        size_t idx;
        if (!args.empty() && frameFind(args[0], idx)) return globalsView(frameCtx(idx));
        std::string mod = "__main__";
        if (Context* p = args.empty() ? nullptr : instanceProps(args[0])) {
            std::vector<Value> info = listItems(p->getByName("_ny_info"));
            if (info.size() > 2 && isStringValue(info[2])) mod = getStringValue(info[2]);
        }
        if (mod != "__main__")
            for (Context* m : module_ctxs_) {
                Value n = m ? m->getByName("__name__") : NONE_VALUE;
                if (isStringValue(n) && getStringValue(n) == mod) return globalsView(m);
            }
        return globalsView(nullptr);
    }
    // _ny_builtins_dict(): f.f_builtins - the builtins every program starts
    // with (the prelude's private names left out).
    Value builtinsDict() {
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        Value dv((Collectable*)d);
        std::vector<std::string> names(base_global_names_.begin(), base_global_names_.end());
        std::sort(names.begin(), names.end());
        for (auto& n : names) {
            if (n.rfind("_ny", 0) == 0 || n.rfind("_Ny", 0) == 0 || reflectHidden(n)) continue;
            Value v = global_ctx->getByName(n);
            if (v.type != ValueType::UNDEFINED) (*d->container)[nypy::key_of_str(n)] = v;
        }
        return dv;
    }
    // The innermost record is ending and has a frame object (FrameGuard).
    static void frameEnded() {
        auto& F = py_frames();
        nyheap::Inst* o = F.back().fobj;
        NythonExecutor* E = o->E;
        if (o->gc_rc > 1 && E && nyheap::executor_alive(E)) {
            try {
                size_t idx = F.size() - 1, c;
                E->frameStore(o, E->frameWhere(idx), F[idx].ctx);
                if (E->frameCaller(idx, c)) {
                    Value b = E->frameObject(c, E->frameWhere(c));
                    o->props->defineByName("_ny_back", b);
                }
            } catch (...) {}
        }
        F.back().fobj = nullptr;
        nygc::decref(o);
    }

    // ── sys.settrace / sys.setprofile (round 79; CPython 3.11's events) ──
    // A thread's trace and profile functions are kept here, keyed by
    // thread; the hot paths test only nytrace::t_hooks (NyPyTrace.hpp).
    //   call       a frame begins (runBodyHooked: a def, a lambda, exec'd
    //              code) or a generator resumes (NyGen.cpp): the trace
    //              function's result becomes the frame's f_trace (None
    //              leaves it), then the profile function is told
    //   line       a statement starts (noteStatement), a loop's header is
    //              reached again (for / while), an except clause takes the
    //              exception, a with statement exits - through the frame's
    //              f_trace, when its f_trace_lines is true
    //   return     the frame ends (its value; None when an exception leaves
    //              it) or a generator yields (the value): f_trace, then the
    //              profile function
    //   exception  an exception reaches a try statement in the frame, or
    //              leaves the frame - once per frame it passes (a bare
    //              raise or a finally passing it on does not repeat it):
    //              (type, value, traceback) to f_trace
    //   c_call / c_return / c_exception   a builtin called by name or as a
    //              method of a builtin value (the profile function; arg is
    //              the builtin)
    // A hook runs with both off (t_in_hook). One that raises is unset (and
    // the frame's f_trace cleared) and its exception goes on in the traced
    // code, as CPython's trace_trampoline / profile_trampoline do. The
    // prelude's frames ("stdin") have no events, as C functions have none.
    struct PyHookFns {
        Value trace, profile;
        std::string exc_flow;            // the exception last reported ...
        size_t exc_depth = (size_t)-2;   // ... in the frame at this depth (py_frames().size())
    };
    std::unordered_map<std::thread::id, PyHookFns> pyhooks_;
    std::string pyt_exc_flow_;           // the exception object an event made last
    Value pyt_exc_obj_;
    PyHookFns* pyHooks() {
        if (pyhooks_.empty()) return nullptr;
        auto it = pyhooks_.find(std::this_thread::get_id());
        return it == pyhooks_.end() ? nullptr : &it->second;
    }
    static bool hookSet(const Value& v) { return v.type != ValueType::NONE && v.type != ValueType::UNDEFINED; }
    void pyHooksRecompute() {
        uint8_t b = 0;
        auto it = pyhooks_.find(std::this_thread::get_id());
        if (it != pyhooks_.end()) {
            if (hookSet(it->second.trace)) b |= nytrace::TRACE;
            if (hookSet(it->second.profile)) b |= nytrace::PROFILE;
            if (!b) pyhooks_.erase(it);
        }
        nytrace::t_hooks = nytrace::t_in_hook ? 0 : b;
    }
    // _ny_settrace(fn) / _ny_setprofile(fn); _ny_gettrace() / _ny_getprofile()
    Value pySetHook(std::vector<Value>& args, bool trace) {
        Value fn = args.empty() ? NONE_VALUE : args[0];
        if (!hookSet(fn) && !pyHooks()) return NONE_VALUE;
        PyHookFns& h = pyhooks_[std::this_thread::get_id()];
        (trace ? h.trace : h.profile) = hookSet(fn) ? fn : NONE_VALUE;
        pyHooksRecompute();
        return NONE_VALUE;
    }
    Value pyGetHook(bool trace) {
        PyHookFns* h = pyHooks();
        return h ? (trace ? h->trace : h->profile) : NONE_VALUE;
    }
    // Calls hook `fn` with (frame, event, arg), both hooks off meanwhile.
    Value pyHookCall(const Value& fn, const Value& frame, const char* ev, const Value& arg, uint8_t which) {
        bool saved = nytrace::t_in_hook;
        nytrace::t_in_hook = true;
        nytrace::t_hooks = 0;
        Node* saved_cur = cur_stmt();
        node_ptr saved_last = last_stmt();
        // an exception on its way (the exception event, an except clause
        // about to take it) keeps its traceback record, whatever the hook
        // raises and catches (as tbFinally)
        TbPending saved_tb = tb_pending();
        bool saved_held = tb_frames_held();
        Value r;
        try {
            std::vector<Value> a{frame, makeStringValue(ev), arg};
            r = callFunctionValue(fn, a, global_ctx);
        } catch (...) {
            nytrace::t_in_hook = saved;
            if (PyHookFns* h = pyHooks()) (which == nytrace::TRACE ? h->trace : h->profile) = NONE_VALUE;
            if (which == nytrace::TRACE) { if (Context* p = instanceProps(frame)) p->defineByName("f_trace", NONE_VALUE); }
            cur_stmt() = saved_cur;
            pyHooksRecompute();
            throw;
        }
        nytrace::t_in_hook = saved;
        cur_stmt() = saved_cur;
        last_stmt() = saved_last;
        tb_pending() = std::move(saved_tb);
        tb_frames_held() = saved_held;
        pyHooksRecompute();
        return r;
    }
    Value frameTraceOf(nyheap::Inst* o) {
        if (!o || !o->props) return NONE_VALUE;
        Value v = o->props->getByName("f_trace");
        return hookSet(v) ? v : NONE_VALUE;
    }
    static size_t pyTopIdx() { auto& F = py_frames(); return F.empty() ? kNoFrame : F.size() - 1; }
    // An event through frame idx's f_trace (line / return / exception).
    void pyEvLocal(size_t idx, const char* ev, const Value& arg) {
        nyheap::Inst* o = frameSlot(idx);
        if (!o) return;   // no frame object: no f_trace
        Value ft = frameTraceOf(o);
        if (!hookSet(ft)) return;
        if (ev[0] == 'l') {
            Value tl = o->props->getByName("f_trace_lines");
            if (tl.type != ValueType::UNDEFINED && !isTruthy(tl)) return;
        }
        Value fo = instValue(o);
        // round 81: which event a jump (f_lineno) would be made from - a
        // line event's is set by pyEvLine
        struct EvScope {
            JumpEv saved; bool set;
            EvScope(size_t i, const char* e) : saved(jumpEv()), set(e[0] != 'l') { if (set) jumpEv() = JumpEv{i, e[0], nullptr, false}; }
            ~EvScope() { if (set) jumpEv() = saved; }
        } _evs(idx, ev);
        Value r = pyHookCall(ft, fo, ev, arg, nytrace::TRACE);
        if (hookSet(r)) { if (Context* p = instanceProps(fo)) p->defineByName("f_trace", r); }
    }
    void pyEvProfile(size_t idx, const char* ev, const Value& arg) {
        PyHookFns* h = pyHooks();
        if (!h || !hookSet(h->profile)) return;
        Value fn = h->profile;
        Value fo = frameObject(idx, frameWhere(idx), false);
        if (isInstanceVal(fo)) pyHookCall(fn, fo, ev, arg, nytrace::PROFILE);
    }
    // A frame begins (record idx; cur_stmt() is its def line).
    void pyEvCall(size_t idx) {
        if (nytrace::t_hooks & nytrace::TRACE) {
            PyHookFns* h = pyHooks();
            if (h && hookSet(h->trace)) {
                Value fn = h->trace;
                Value fo = frameObject(idx, frameWhere(idx), false);
                if (isInstanceVal(fo)) {
                    JumpEv saved = jumpEv();   // round 81: no jump from a call event
                    jumpEv() = JumpEv{idx, 'c', nullptr, false};
                    struct Restore { JumpEv s; ~Restore() { jumpEv() = s; } } _restore{saved};
                    Value r = pyHookCall(fn, fo, "call", NONE_VALUE, nytrace::TRACE);
                    if (hookSet(r)) { if (Context* p = instanceProps(fo)) p->defineByName("f_trace", r); }
                }
            }
        }
        if (nytrace::t_hooks & nytrace::PROFILE) pyEvProfile(idx, "call", NONE_VALUE);
    }
    // The frame ends with `v` (None when an exception leaves it), or a
    // generator yields `v`.
    void pyEvReturn(size_t idx, const Value& v) {
        if (nytrace::t_hooks & nytrace::TRACE) pyEvLocal(idx, "return", v);
        if (nytrace::t_hooks & nytrace::PROFILE) pyEvProfile(idx, "return", v);
    }
    // A statement starts in the innermost frame.
    // `jumpable` (round 81): a statement's line, a loop header's or an
    // elif's - where a trace function may move the frame (f_lineno).
    void pyEvLine(Node* st, bool jumpable = false) {
        if (!st || tbHiddenFile(st->tok().fileName())) return;
        // a function's docstring is no code in CPython: no line event
        if (st->type() == NodeType::STRING && !py_frames().empty()) {
            if (auto* fn = dynamic_cast<FunctionNode*>(py_frames().back().code); fn && fn->has_doc && st->tok().value == fn->doc) return;
        }
        size_t idx = pyTopIdx();
        JumpState& js = jumpState();
        if (__builtin_expect(js.skip_idx != SIZE_MAX, 0)) {
            // the line a jump went to: not reported (as CPython does not)
            bool same = js.skip_idx == idx && js.skip_line == (int)st->tok().line();
            js.skip_idx = SIZE_MAX;
            if (same) return;
        }
        JumpEv saved = jumpEv();
        jumpEv() = JumpEv{idx, 'l', st, jumpable};
        try { pyEvLocal(idx, "line", NONE_VALUE); }
        catch (...) { jumpEv() = saved; js.pending = false; throw; }
        jumpEv() = saved;
        if (__builtin_expect(js.pending, 0)) {
            // round 81: the trace function set f_lineno - go there
            js.pending = false;
            jumpResume() = std::move(js.rest);
            js.rest.clear();
            jumpResuming() = !jumpResume().empty();
            throw JumpSignal{js.block, js.index};
        }
    }
    // Execution comes back to `n`'s line (a loop's header, an except
    // clause, a with statement's exit): a line event there.
    void pyEvLineAt(Node* n, bool jumpable = false) {
        cur_stmt() = n;
        pyEvLine(n, jumpable);
    }

    // ── frame.f_lineno = n: a trace function moves its frame (round 81) ──
    // CPython's frame_setlineno over the tree: from a 'line' event of the
    // frame to the first statement on or after line n in its code block
    // (the def's body, or a module's). A jump may enter if/elif/else,
    // while bodies, try bodies, else and finally blocks and a for loop's
    // else; not a for loop's body (its iterator would be missing), an
    // except clause (no exception) or a with body (no __exit__) - CPython's
    // compatible stacks. What it leaves (loops, handlers, with bodies,
    // finally blocks) is just left: no finally or __exit__ runs, as there.
    // The jump is a JumpSignal thrown when the trace function returns,
    // caught by the deepest block holding both statements
    // (evalStatements), which goes on at the target, entering the blocks on
    // the way down (jumpResume, resumeInto). The target's own line event
    // is not reported, as CPython's is not.
    struct JumpSignal { Node* block; size_t index; };
    struct JumpEv { size_t idx = SIZE_MAX; char ev = 0; Node* stmt = nullptr; bool jumpable = false; };
    static JumpEv& jumpEv() { static thread_local JumpEv e; return e; }
    struct JumpState {
        bool pending = false;                        // a jump to take when the trace function returns
        Node* block = nullptr; size_t index = 0;     // the block that goes on, at this statement
        std::vector<std::pair<Node*, size_t>> rest;  // the bodies entered below it (index SIZE_MAX: not a block)
        size_t skip_idx = SIZE_MAX; int skip_line = 0;   // the target's own line event
    };
    static JumpState& jumpState() { static thread_local JumpState s; return s; }
    static std::vector<std::pair<Node*, size_t>>& jumpResume() { static thread_local std::vector<std::pair<Node*, size_t>> r; return r; }
    static bool& jumpResuming() { static thread_local bool b = false; return b; }
    static bool jumpIsBlock(Node* n) {
        return n && (n->type() == NodeType::BLOCK || n->type() == NodeType::STATEMENTS || n->type() == NodeType::SCRIPT);
    }
    // The bodies a statement holds, in order (elif and except clauses are
    // nodes of their own, their bodies below them).
    static void jumpChildren(Node* s, std::vector<Node*>& out) {
        switch (s->type()) {
            case NodeType::IF: {
                auto* n = static_cast<IfNode*>(s);
                if (n->is_expr) return;
                if (n->then_branch) out.push_back(n->then_branch.get());
                for (auto& e : n->elseif_branches) if (e) out.push_back(e.get());
                if (n->else_branch) out.push_back(n->else_branch.get());
                return;
            }
            case NodeType::WHILE: {
                auto* n = static_cast<WhileNode*>(s);
                if (n->body) out.push_back(n->body.get());
                if (n->else_branch) out.push_back(n->else_branch.get());
                return;
            }
            case NodeType::FOR: {
                auto* n = static_cast<ForNode*>(s);
                if (n->body) out.push_back(n->body.get());
                if (n->else_branch) out.push_back(n->else_branch.get());
                return;
            }
            case NodeType::TRY: {
                auto* n = static_cast<TryNode*>(s);
                if (n->body) out.push_back(n->body.get());
                for (auto& e : n->except_clauses) if (e) out.push_back(e.get());
                if (n->else_clause) out.push_back(n->else_clause.get());
                if (n->finally_clause) out.push_back(n->finally_clause.get());
                return;
            }
            case NodeType::EXCEPT: { auto* n = static_cast<ExceptNode*>(s); if (n->body) out.push_back(n->body.get()); return; }
            case NodeType::WITH: { auto* n = static_cast<WithNode*>(s); if (n->body) out.push_back(n->body.get()); return; }
            default: return;
        }
    }
    // Every statement of a code block with the chain of nodes down to it
    // (block, statement, block, statement ...; a body that is a single
    // statement, an elif or except clause, stands in the chain itself).
    struct JumpEntry { int line; std::vector<Node*> chain; };
    static void jumpWalk(Node* n, std::vector<Node*>& chain, std::vector<JumpEntry>& out) {
        if (!n) return;
        if (!jumpIsBlock(n)) { jumpWalkStmt(n, chain, out); return; }
        chain.push_back(n);
        for (auto& s : n->statements()) if (s) jumpWalkStmt(s.get(), chain, out);
        chain.pop_back();
    }
    static void jumpWalkStmt(Node* s, std::vector<Node*>& chain, std::vector<JumpEntry>& out) {
        chain.push_back(s);
        out.push_back({(int)s->tok().line(), chain});
        if (s->type() != NodeType::FUNCTION && s->type() != NodeType::CLASS) {   // their bodies are frames of their own
            std::vector<Node*> kids;
            jumpChildren(s, kids);
            for (Node* k : kids) jumpWalk(k, chain, out);
        }
        chain.pop_back();
    }
    Node* main_ast_ = nullptr;   // the program's tree: the module frame's code block
    // _ny_frame_jump(frame, lineno): the f_lineno setter's work (both
    // engines check CPython's rules; the messages are 3.12's)
    Value frameJump(std::vector<Value>& args) {
        size_t idx;
        JumpEv ev = jumpEv();
        if (args.size() < 2 || !frameFind(args[0], idx) || ev.idx != idx || !ev.ev)
            pyRaise("ValueError", "f_lineno can only be set in a trace function");
        if (ev.ev == 'c') pyRaise("ValueError", "can't jump from the 'call' trace event of a new frame");
        if (ev.ev != 'l' || !ev.jumpable || !ev.stmt) pyRaise("ValueError", "can only jump from a 'line' trace event");
        int64_t lineno = 0;
        if (args[1].type != ValueType::INTEGER || !bigint_fits_i64(args[1].value.i, lineno)) pyRaise("ValueError", "lineno must be an integer");
        // the code block: the function's body, else the module's
        Node* root = nullptr;
        int first = 1;
        std::vector<JumpEntry> entries;
        std::vector<Node*> chain;
        auto holds = [&](Node* r) {
            entries.clear(); chain.clear();
            jumpWalk(r, chain, entries);
            for (auto& e : entries) if (e.chain.back() == ev.stmt) return true;
            return false;
        };
        if (auto* fn = dynamic_cast<FunctionNode*>(py_frames()[idx].code)) {
            root = fn->body.get(); first = fn->first_line ? (int)fn->first_line : (int)fn->tok().line();
            holds(root);
        } else {
            if (main_ast_ && holds(main_ast_)) root = main_ast_;
            else for (auto& a : imported_asts) if (a && holds(a.get())) { root = a.get(); break; }
            if (!root) pyRaise("ValueError", "can't jump from unreachable code");
        }
        if (lineno < first) pyRaise("ValueError", "line " + std::to_string(lineno) + " comes before the current code block");
        const JumpEntry* from = nullptr;
        int best = INT_MAX;
        for (auto& e : entries) {
            if (!from && e.chain.back() == ev.stmt) from = &e;
            if (e.line >= lineno && e.line < best) best = e.line;
        }
        if (best == INT_MAX) pyRaise("ValueError", "line " + std::to_string(lineno) + " comes after the current code block");
        if (!from) pyRaise("ValueError", "can't jump from unreachable code");
        std::string err;
        for (auto& e : entries) {
            if (e.line != best) continue;
            const auto& a = from->chain;
            const auto& b = e.chain;
            size_t p = 0;
            while (p < a.size() && p < b.size() && a[p] == b[p]) p++;
            // the deepest block both are in
            size_t blk = SIZE_MAX;
            for (size_t q = std::min(p, b.size()); q-- > 0;) if (jumpIsBlock(b[q])) { blk = q; break; }
            if (blk == SIZE_MAX || blk + 1 >= b.size()) { if (err.empty()) err = "can't jump there"; continue; }
            // what the jump enters below the common part
            std::string why;
            for (size_t q = blk + 1; q + 1 < b.size() && why.empty(); q++) {
                if (q + 1 < p) continue;   // still common: not entered
                Node* s = b[q]; Node* c = b[q + 1];
                if (s->type() == NodeType::FOR && c == static_cast<ForNode*>(s)->body.get())
                    why = "can't jump into the body of a for loop";
                else if (s->type() == NodeType::WITH)
                    why = "can't jump into the body of a for loop";   // CPython 3.12's message for a with body
                else if (s->type() == NodeType::EXCEPT || c->type() == NodeType::EXCEPT)
                    why = "can't jump into an 'except' block as there's no exception";
            }
            if (!why.empty()) { if (err.empty()) err = why; continue; }
            JumpState& js = jumpState();
            js.block = b[blk];
            js.index = 0;
            {
                auto stmts = b[blk]->statements();
                for (size_t k = 0; k < stmts.size(); k++) if (stmts[k].get() == b[blk + 1]) { js.index = k; break; }
            }
            js.rest.clear();
            for (size_t q = blk + 1; q + 1 < b.size();) {
                Node* c = b[q + 1];
                if (jumpIsBlock(c) && q + 2 < b.size()) {
                    size_t ix = 0;
                    auto cs = c->statements();
                    for (size_t k = 0; k < cs.size(); k++) if (cs[k].get() == b[q + 2]) { ix = k; break; }
                    js.rest.push_back({c, ix});
                    q += 2;
                } else {
                    js.rest.push_back({c, SIZE_MAX});
                    q += 1;
                }
            }
            js.pending = true;
            js.skip_idx = idx;
            // a jump to the def line itself reports the first line again
            js.skip_line = (lineno == first && best > first) ? -1 : best;
            return NONE_VALUE;
        }
        pyRaise("ValueError", err.empty() ? std::string("cannot find bytecode for specified line") : err);
        return NONE_VALUE;
    }
    // A statement a jump goes into (jumpResume's front is the body it
    // enters): that body runs, its header skipped - an if's test, a
    // while's (then the loop goes on), a try's body under its handlers, an
    // else or finally block as the statement would run it.
    Value resumeInto(const node_ptr& x, Context* ctx) {
        auto& R = jumpResume();
        if (R.empty()) return evalNode(x, ctx);
        Node* c = R.front().first;
        auto enter = [&](const node_ptr& body) -> Value {
            if (!jumpIsBlock(body.get())) {
                R.erase(R.begin());
                if (!R.empty()) return resumeInto(body, ctx);
            }
            return evalNode(body, ctx);   // a block resumes itself (evalStatements)
        };
        switch (x->type()) {
            case NodeType::IF: {
                auto* n = static_cast<IfNode*>(x.get());
                if (n->then_branch.get() == c) return enter(n->then_branch);
                if (n->else_branch.get() == c) return enter(n->else_branch);
                for (size_t k = 0; k < n->elseif_branches.size(); k++) {
                    if (n->elseif_branches[k].get() != c) continue;
                    R.erase(R.begin());
                    auto* e = static_cast<IfNode*>(c);
                    if (!R.empty() && R.front().first == e->then_branch.get()) return enter(e->then_branch);
                    R.clear();
                    // at the elif's own line: its test, and the chain from there
                    for (size_t j = k; j < n->elseif_branches.size(); j++) {
                        auto* ej = static_cast<IfNode*>(n->elseif_branches[j].get());
                        if (j > k && __builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0)) pyEvLineAt(ej, true);
                        if (isTruthy(evalNode(ej->condition, ctx))) return evalNode(ej->then_branch, ctx);
                    }
                    return n->else_branch ? evalNode(n->else_branch, ctx) : NONE_VALUE;
                }
                break;
            }
            case NodeType::WHILE: {
                auto* n = static_cast<WhileNode*>(x.get());
                if (n->else_branch.get() == c) return enter(n->else_branch);
                if (n->body.get() != c) break;
                FlowState& lf = flow();
                Value r;
                bool broke = false;
                try { LoopBody _lb(lf); r = enter(n->body); }
                catch (std::string& f) { if (f == "break") broke = true; else if (f != "continue") throw; }
                if (lf.pending) {
                    if (lf.pending == 1 || lf.pending == kPendExc) return r;   // round 82: an exception too
                    int pf = lf.pending; lf.pending = 0;
                    if (pf == 2) broke = true;
                }
                if (broke) return NONE_VALUE;
                // the loop goes on: its test again (its line, as a repetition)
                if (__builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0)) pyEvLineAt(x.get(), true);
                return evalWhile(x, ctx);
            }
            case NodeType::FOR: {
                auto* n = static_cast<ForNode*>(x.get());
                if (n->else_branch.get() == c) return enter(n->else_branch);
                break;
            }
            case NodeType::TRY: {
                auto* n = static_cast<TryNode*>(x.get());
                SuspendFast _sf;
                if (n->body.get() == c) return evalTry(x, ctx);   // the body resumes under the handlers
                if (n->finally_clause.get() == c) return enter(n->finally_clause);
                if (n->else_clause.get() == c) {
                    Value r;
                    try { r = enter(n->else_clause); }
                    catch (JumpSignal&) { throw; }
                    catch (...) { if (n->finally_clause) evalNode(n->finally_clause, ctx); throw; }
                    if (n->finally_clause) evalNode(n->finally_clause, ctx);
                    return r;
                }
                break;
            }
            default: break;
        }
        R.clear();
        return evalNode(x, ctx);
    }
    // The exception `flow` in the running frame: the exception event, once
    // per frame it passes.
    void pyEvException(const std::string& flow) {
        if (flow == "break" || flow == "continue" || !(nytrace::t_hooks & nytrace::TRACE)) return;
        PyHookFns* h = pyHooks();
        if (!h) return;
        size_t depth = py_frames().size();
        if (h->exc_depth == depth && h->exc_flow == flow) return;
        h->exc_flow = flow;
        h->exc_depth = depth;
        size_t idx = pyTopIdx();
        nyheap::Inst* o = frameSlot(idx);
        if (!o || !hookSet(frameTraceOf(o))) return;
        if (Node* cs = cur_stmt(); cs && tbHiddenFile(cs->tok().fileName())) return;
        Value ev = excInstanceOf(flow);
        if (!isInstanceVal(ev)) {
            if (pyt_exc_flow_ != flow) { pyt_exc_obj_ = exceptionObject(flow); pyt_exc_flow_ = flow; }
            ev = pyt_exc_obj_;
        }
        Value ty = exceptionClassValue(flow), tb = NONE_VALUE;
        if (Context* ep = instanceProps(ev)) { tb = ep->getByName("__traceback__"); if (!isInstanceVal(tb)) tb = NONE_VALUE; }
        pyEvLocal(idx, "exception", makeListValue({ty, ev, tb}, true));
    }
    // An except clause has handled the exception: the next one raised in
    // this frame is reported again, even with the same text.
    void pyExcHandled() {
        if (PyHookFns* h = pyHooks()) { h->exc_flow.clear(); h->exc_depth = (size_t)-2; }
    }
    // `flow` leaves frame idx: exception, then return(None).
    void pyEvLeave(const std::string& flow, size_t idx) {
        if (!(nytrace::t_hooks & nytrace::ANY) || flow == "break" || flow == "continue") return;
        pyEvException(flow);
        pyEvReturn(idx, NONE_VALUE);
    }
    // c_call / c_return / c_exception around a builtin called from a frame
    // that is not the prelude's (`fn` is what the profile function sees).
    template <class F> Value pyProfileBuiltin(const Value& fn, F&& run) {
        Node* cs = cur_stmt();
        if (!(nytrace::t_hooks & nytrace::PROFILE) || (cs && tbHiddenFile(cs->tok().fileName()))) return run();
        size_t idx = pyTopIdx();
        pyEvProfile(idx, "c_call", fn);
        Value r;
        try { r = run(); }
        catch (...) { if (nytrace::t_hooks & nytrace::PROFILE) pyEvProfile(idx, "c_exception", fn); throw; }
        if (nytrace::t_hooks & nytrace::PROFILE) pyEvProfile(idx, "c_return", fn);
        return r;
    }
    // _ny_frame_local_set(frame, name, value): frame.f_locals[name] = value
    // reaching the running frame's variable (PEP 667's write-through);
    // false when the frame is not running on this thread.
    Value frameLocalSet(std::vector<Value>& args) {
        size_t idx;
        if (args.size() < 3 || !isStringValue(args[1]) || !frameFind(args[0], idx)) return Value(false);
        Context* c = frameCtx(idx);
        if (!c) return Value(false);
        c->defineByName(getStringValue(args[1]), args[2]);
        return Value(true);
    }

    // A return, break or continue left a try's body, else clause or handler
    // by the pending flag (round 81; `fast` below): the finally body runs
    // with the flag cleared, then the flow goes on - unless the finally body
    // itself returned, broke, continued or raised, which replaces it, as it
    // does when the flow is thrown.
    void leaveWithPending(FlowState& f, const node_ptr& fin, Context* ctx) {
        if (!fin) return;
        int p = f.pending;
        Value v = std::move(f.value);
        f.pending = 0;
        f.value = NONE_VALUE;
        evalNode(fin, ctx);
        if (!f.pending) { f.pending = p; f.value = std::move(v); }
    }
    // `fast` (round 81): the statement runs without SuspendFast, so a return
    // or break in its clauses sets the pending flag instead of throwing;
    // each clause is checked for it as it ends. Otherwise as before.
    // round 82: an exception may arrive by the flag too (pending 4) - from
    // the body, the else clause or a handler - and is taken as the catch
    // clauses take a thrown one; one that goes on leaves by the flag where
    // the statement may (canPend: always when it came that way). A finally
    // body run while an exception propagates that leaves by the flag
    // itself (return, break, continue, its own exception) replaces it, as
    // in Python (round 81's fast path re-raised the exception after it).
    Value evalTry(const node_ptr& node, Context* ctx, bool fast = false) {
        auto* tn = static_cast<TryNode*>(node.get());
        FlowState& fl = flow();
        Value result = NONE_VALUE;
        // The finally body runs on every way out: normal completion, return,
        // break/continue, an exception no clause matches (which then
        // propagates - it used to be silently dropped), and an exception
        // raised by a handler or the else clause (it used to skip finally).
        auto run_finally = [&]() { if (tn->finally_clause) evalNode(tn->finally_clause, ctx); };
        // ... with an exception on its way out (its traceback record kept,
        // round 77); true when the body's own flow replaced it (round 82)
        auto run_finally_exc = [&]() -> bool {
            if (!tn->finally_clause) return false;
            tbFinally([&]() { evalNode(tn->finally_clause, ctx); });
            return fast && fl.pending;
        };
        // round 82: an exception going on from here - by the flag when the
        // statement may leave by it, else thrown
        const bool may_pend = fast && canPend(ctx);
        std::string exc;
        bool raised = false;
        try {
            result = evalNode(tn->body, ctx);
        }
        catch (nython::node::ReturnSignal&) { run_finally(); throw; }
        catch (nython::node::YieldSignal&) { throw; }
        catch (std::string& flow) {
            if (flow == "break" || flow == "continue") { run_finally(); throw; }
            exc = flow; raised = true;
        }
        catch (std::exception& e) { exc = excFromCpp(e.what()); raised = true; }
        if (fast && fl.pending == kPendExc) { exc = takeExc(fl); raised = true; }   // round 82
        if (raised) tbSee(exc);   // round 77: its line here, before a finally runs
        if (raised && __builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) pyEvException(exc);   // round 79

        if (!raised) {
            if (fast && fl.pending) { leaveWithPending(fl, tn->finally_clause, ctx); return result; }   // round 81
            if (tn->else_clause) {
                try { result = evalNode(tn->else_clause, ctx); }
                catch (nython::node::YieldSignal&) { throw; }
                catch (JumpSignal&) { throw; }   // round 81: a jump runs no finally
                catch (nython::node::ReturnSignal&) { run_finally(); throw; }
                catch (std::string& f2) {
                    if (f2 == "break" || f2 == "continue") run_finally();
                    else { tbSee(f2); if (run_finally_exc()) return result; }
                    throw;
                }
                catch (std::exception& e3) { tbSee(excFromCpp(e3.what())); if (run_finally_exc()) return result; throw; }
                catch (...) { run_finally(); throw; }
                if (fast && fl.pending == kPendExc) {   // round 82: the else clause raised
                    std::string f2 = takeExc(fl);
                    tbSee(f2);
                    if (run_finally_exc()) return result;
                    pendExc(std::move(f2));
                    return NONE_VALUE;
                }
                if (fast && fl.pending) { leaveWithPending(fl, tn->finally_clause, ctx); return result; }   // round 81
            }
            run_finally();
            return result;
        }

        ExceptNode* match = nullptr;
        for (auto& ec : tn->except_clauses) {
            auto* en = static_cast<ExceptNode*>(ec.get());
            if (excClauseMatches(en, exc, ctx)) { match = en; break; }
        }
        if (!match) {
            if (run_finally_exc()) return result;
            if (may_pend) { pendExc(std::move(exc)); return NONE_VALUE; }   // round 82
            throw exc;
        }
        // the exception object, with its traceback (round 77)
        exc = tbCaught(exc);
        if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) {
            // round 79: re-raised from here as it is now (a bare raise), it
            // is not reported again; the clause's own line event
            if (PyHookFns* h = pyHooks(); h && h->exc_depth == py_frames().size()) h->exc_flow = exc;
            if (nytrace::t_hooks & nytrace::TRACE) pyEvLineAt(match);
        }

        if (!match->var.empty()) {
            (match->var_global ? moduleCtx(ctx) : ctx)->defineByName(match->var, exceptionObject(exc));
        }
        handling_exc_.push_back(exc);
        handling_obj_.emplace_back(exc, excInstanceOf(exc));
        struct PopHandling {
            std::vector<std::string>& v; std::vector<std::pair<std::string, Value>>& o;
            ~PopHandling() { v.pop_back(); o.pop_back(); }
        } _ph{handling_exc_, handling_obj_};
        try {
            // round 81: `except E as e:` unbinds e when the clause ends,
            // however it ends - before the handlers below and the try's
            // finally run (CPython: try: body finally: e = None; del e)
            struct UnbindAs {
                NythonExecutor* x; Context* ctx; ExceptNode* en;
                ~UnbindAs() {
                    if (en->var.empty()) return;
                    auto unbind = [&](const std::string& n, bool g) {
                        Context* c = g ? x->moduleCtx(ctx) : ctx;
                        if (c && c->container) c->container->erase(n);
                    };
                    unbind(en->var, en->var_global);
                    for (auto& u : en->unbind_names) unbind(u.first, u.second);   // the lowered `except <expr> as e`
                }
            } _ua{this, ctx, match};
            result = evalNode(match->body, ctx);
        }
        catch (nython::node::YieldSignal&) { throw; }
        catch (JumpSignal&) { throw; }   // round 81: a jump out of the clause runs no finally
        catch (std::string& f2) {
            if (f2 == "break" || f2 == "continue") { run_finally(); throw; }
            tbHandlerExit(f2);
            tbSee(f2);
            if (run_finally_exc()) return result;
            if (may_pend) { pendExc(f2); return NONE_VALUE; }   // round 82
            throw;
        }
        catch (std::exception& e2) { std::string f3 = excFromCpp(e2.what()); tbHandlerExit(f3); tbSee(f3); if (run_finally_exc()) return result; throw; }
        catch (...) { run_finally(); throw; }
        if (fast && fl.pending == kPendExc) {   // round 82: the handler raised (a bare raise, a new exception)
            std::string f2 = takeExc(fl);
            tbHandlerExit(f2);
            tbSee(f2);
            if (run_finally_exc()) return result;
            pendExc(std::move(f2));
            return NONE_VALUE;
        }
        // a return/break/continue left the handler: as the thrown one did
        // (the finally body, no pyExcHandled) - round 81
        if (fast && fl.pending) { leaveWithPending(fl, tn->finally_clause, ctx); return result; }
        if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) pyExcHandled();   // round 79
        run_finally();
        return result;
    }

    // A new instance of a user class: its storage, an exception's args (the
    // constructor's arguments whatever its __init__ does, as in Python;
    // super().__init__(...) replaces them), then the constructor - __init__
    // (or init) from the first class in the MRO that defines one, called
    // like any method: keyword arguments, defaults evaluated at definition,
    // the class's own scope as its parent (not the caller's), exceptions
    // propagate.
    // The storage of a new instance: a heap object (nyheap::Inst) that owns
    // its field scope and every side-table entry keyed by its identity.
    // Where an Inst's identity (its tag) sits in it, measured on the first
    // instance made (round 81): the object of a live instance's identity.
    ptrdiff_t inst_tag_off_ = -1;
    nyheap::Inst* instObjectOf(void* p) const {
        if (inst_tag_off_ < 0 || !p || !instance_to_class.count(p)) return nullptr;
        return reinterpret_cast<nyheap::Inst*>(static_cast<char*>(p) - inst_tag_off_);
    }
    Value newInstance(const std::string& className, void* class_ptr) {
        auto* io = new nyheap::Inst(this, "__instance__:" + className, class_ptr);
        void* ip = (void*)&io->tag;
        if (inst_tag_off_ < 0) inst_tag_off_ = (char*)ip - (char*)io;
        Value instance = nyheap::userValue(io, ip);
        instance_to_class[ip] = class_ptr;
        func_names[ip] = "__instance__:" + className;
        io->props = new Context(runner, className + "_props", nullptr, nullptr, nullptr);   // adopts the creator's reference
        // Only the instance refers to its field scope, so the collector sees
        // the pair as one object (Inst::gc_traverse walks the fields): half
        // the tracked objects for instance-heavy programs.
        nygc::untrack(io->props);
        instance_properties[ip] = io->props;
        nygc::track(io);
        return instance;
    }
    // A class's own __new__ (not object's), found through the MRO; classes
    // without one are remembered (cleared whenever a class is made).
    std::unordered_set<const Node*> no_new_;
    bool classNew(Node* cn, Value& m, Node*& where) {
        if (!cn || no_new_.count(cn)) return false;
        Node* objn = classNodeByName("object");
        if (findClassMember(cn, "__new__", m, &where) && where != objn && m.type == ValueType::USERDATA
            && m.value.p && func_names.count(m.value.p))
            return true;
        no_new_.insert(cn);
        return false;
    }
    // Set by type.__call__ (a metaclass's super().__call__) for the one
    // instantiation it makes, which must not run the metaclass's __call__
    // again; consumed at once, so instantiations nested in that object's
    // __init__ still go through their metaclasses.
    bool type_call_skip_ = false;
    Value instantiateClass(const Value& cls, std::vector<Value>& args,
                           const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        if (range_node_ && cls.value.p == (void*)range_node_) return makeRange(args, kw, ctx);   // round 78
        std::string className = fnTag(func_names, cls.value.p).substr(10);
        // OSError(errno, strerror, ...) makes the subclass for that errno:
        // OSError(2, "x") is a FileNotFoundError (round 77, CPython's errnomap)
        if (className == "OSError" && args.size() >= 2 && args.size() <= 5 && args[0].type == ValueType::INTEGER) {
            int64_t en = 0;
            const char* sub = bigint_fits_i64(args[0].value.i, en) ? nython::ny_errno_exc_class((long)en) : "";
            Node* sn = *sub ? classNodeByName(sub) : nullptr;
            if (sn) { Value sv; sv.type = ValueType::USERDATA; sv.value.p = (void*)sn; return instantiateClass(sv, args, kw, ctx); }
        }
        bool skip_meta_call = type_call_skip_;
        type_call_skip_ = false;
        if (!class_meta_.empty() || !metaclass_types_.empty()) {
            // a metaclass's __call__ (round 77)
            Value m; Node* where = nullptr;
            if (!skip_meta_call && metaMember(cls, "__call__", m, where))
                return callMeta(m, where, cls, args, kw, ctx);
            // a metaclass itself called: it makes a class
            if (Node* cn = classNodeOfValue(cls); cn && isMetaclassNode(cn) && args.size() == 3)
                return callMetaclass(cls, args, kw, ctx);
        }
        // __new__(cls, *args, **kw) makes the object; __init__ runs when it
        // returned an instance of the class (round 77).
        {
            Value nm; Node* where = nullptr;
            Node* cn = classNodeOfValue(cls);
            if (cn && classNew(cn, nm, where)) {
                std::vector<Value> a;
                a.reserve(args.size() + 1);
                a.push_back(cls);
                for (auto& x : args) a.push_back(x);
                Value inst = invokeMember(nm, where, cls, a, kw, ctx);
                if (isInstanceValue(inst) && classDerivesFrom(instanceClassName(inst), static_cast<ClassNode*>(cn)->name)) {
                    if (isExceptionClass(className)) { setExceptionArgs(inst, args); setExceptionKw(inst, kw); }
                    runConstructor(inst, args, kw, ctx, true);
                }
                return inst;
            }
        }
        Value instance = newInstance(className, cls.value.p);
        if (isExceptionClass(className)) { setExceptionArgs(instance, args); setExceptionKw(instance, kw); }
        runConstructor(instance, args, kw, ctx);
        return instance;
    }
    // round 82: the raise statement leaves by the pending flag where it may
    // (canPend), else throws as before; raiseFlow makes what it raises.
    Value evalRaise(const node_ptr& node, Context* ctx) {
        std::string e = raiseFlow(node, ctx);
        if (canPend(ctx)) { pendExc(std::move(e)); return NONE_VALUE; }
        throw e;
    }
    std::string raiseFlow(const node_ptr& node, Context* ctx) {
        auto* rn = static_cast<RaiseNode*>(node.get());
        if (!rn->expr) {
            // Bare `raise`: the exception the enclosing except clause is
            // handling (it used to raise the string "Exception"), with the
            // traceback it has (round 77).
            if (!handling_exc_.empty()) { tbReraise(handling_exc_.back()); return handling_exc_.back(); }
            return "__exc__:RuntimeError:No active exception to reraise";
        }
        Value v = evalNode(rn->expr, ctx);
        // `raise SomeClass` raises a new instance of it.
        if (v.type == ValueType::USERDATA && v.value.p) {
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                if (fit->second.rfind("__class__:", 0) == 0) {
                    std::vector<Value> none_args;
                    static const nyrt::OrderedKw<Value> no_kw;
                    v = instantiateClass(v, none_args, no_kw, ctx);
                } else if (fit->second.rfind("__builtin__:", 0) == 0
                           && nython::ny_is_builtin_exc(fit->second.substr(12))) {
                    return "__exc__:" + fit->second.substr(12) + ":";
                }
            }
        }
        if (v.type == ValueType::USERDATA && v.value.p && !string_ptrs_.count(v.value.p)) {
            auto cit = instance_to_class.find(v.value.p);
            if (cit != instance_to_class.end()) {
                std::string class_name = instanceClassName(v);
                if (rn->cause) {
                    // `raise X from Y`: Y (an instance of it when Y is a
                    // class, none for `from None`) is the cause, and the
                    // context is not shown (round 77: __suppress_context__)
                    Value cause = evalNode(rn->cause, ctx);
                    if (cause.type == ValueType::USERDATA && cause.value.p
                        && fnTag(func_names, cause.value.p).rfind("__class__:", 0) == 0) {
                        std::vector<Value> none_args;
                        static const nyrt::OrderedKw<Value> no_kw2;
                        cause = instantiateClass(cause, none_args, no_kw2, ctx);
                    }
                    auto pit = instance_properties.find(v.value.p);
                    if (pit != instance_properties.end()) {
                        pit->second->defineByName("__cause__", cause);
                        pit->second->defineByName("__suppress_context__", Value(true));
                    }
                }
                // raised while an except clause handles another: that one
                // is its __context__ (round 77)
                if (!handling_obj_.empty()) setExcContext(v, handling_obj_.back().second);
                return rememberRaised(class_name, v);
            }
            return getStringValue(v);
        }
        if (v.type == ValueType::USERDATA && v.value.p) return getStringValue(v);   // a string
        if (v.type == ValueType::NONE) return "__exc__:Exception:";
        return v.toString();
    }

    Value evalAssert(const node_ptr& node, Context* ctx) {
        auto an = static_pointer_cast<AssertNode>(node);
        if (!isTruthy(evalNode(an->condition, ctx))) {
            std::string msg;
            if (an->message) {
                Value mv = evalNode(an->message, ctx);
                msg = mv.type == ValueType::USERDATA ? getStringValue(mv) : mv.toString();
            } else {
                msg = "Assertion failed";
            }
            std::string e = "__exc__:AssertionError:" + msg;
            if (canPend(ctx)) { pendExc(std::move(e)); return NONE_VALUE; }   // round 82, as raise
            throw e;
        }
        return NONE_VALUE;
    }

    // ─── ENUM ───────────────────────────────────────────────────────────
    // Directory of the file containing this import, with a trailing separator.
    // Tokens carry their source file, so this needs no extra plumbing.
    std::string importerDir(const node_ptr& node) {
        if (!node) return std::string();
        std::string f = node->tok().fileName();
        if (f.empty()) return std::string();
        size_t cut = f.find_last_of("/\\");
        if (cut == std::string::npos) return std::string();
        return f.substr(0, cut + 1);
    }

    // "/a/b/lib/" -> "/a/b/". Normalised through realpath first so a path
    // such as "build/../lib/" climbs to the real parent, not into build/.
    static std::string parentDirOf(const std::string& dir) {
        if (dir.empty()) return std::string();
        std::string d = dir;
#ifndef _WIN32
        char buf[4096];
        if (realpath(d.c_str(), buf)) d = std::string(buf) + "/";
#endif
        while (d.size() > 1 && (d.back() == '/' || d.back() == '\\')) d.pop_back();
        size_t cut = d.find_last_of("/\\");
        if (cut == std::string::npos) return std::string();
        return d.substr(0, cut + 1);
    }

    // Library files name each other relative to the project root
    // (lib/aiagent.ny does `import "lib/nytorch.ny"`), which only resolved when
    // the working directory WAS the project root. Launching the IDE from any
    // other folder - i.e. opening any other project - died with an ImportError.
    // Tried after every existing candidate, so resolution that already worked
    // is unchanged: the importing file's ancestor directories, nearest first.
    std::vector<std::string> ancestorCandidates(const node_ptr& node, const std::string& rel) {
        std::vector<std::string> out;
        std::string anc = parentDirOf(importerDir(node));
        for (int up = 0; up < 4 && !anc.empty(); ++up) {
            out.push_back(anc + rel);
            std::string next = parentDirOf(anc);
            if (next == anc) break;
            anc = next;
        }
        return out;
    }

    std::string locateModuleFile(const node_ptr& node, const std::string& rel) {
        struct stat st;
        if (stat(rel.c_str(), &st) == 0) return rel;
        std::string here = importerDir(node);
        if (!here.empty() && stat((here + rel).c_str(), &st) == 0) return here + rel;
        for (auto& c : ancestorCandidates(node, rel))
            if (stat(c.c_str(), &st) == 0) return c;
        return rel;
    }

    // Top-level declarations of a module: functions, classes and vars. Used to
    // build an `import ... as` namespace without depending on scope state.
    void collectTopLevelNames(const node_ptr& root, std::set<std::string>& out) {
        nython::scope::module_names(root, out);   // NyScope.cpp, shared with the VM
        return;
        if (!root) return;
        for (auto& st : root->statements()) {
            if (!st) continue;
            switch (st->type()) {
                case NodeType::FUNCTION:
                    out.insert(static_pointer_cast<FunctionNode>(st)->name); break;
                case NodeType::CLASS:
                    out.insert(static_pointer_cast<ClassNode>(st)->name); break;
                case NodeType::VARIABLE_DECL:
                    out.insert(static_pointer_cast<VarDeclNode>(st)->name); break;
                default: break;
            }
        }
    }

    // Default members every object inherits. Returns UNDEFINED when the name is
    // not part of the protocol, so the caller can continue its own lookup.
    // If `node` names a type (a bare identifier that is a known type name or a
    // declared class), return that name; otherwise "" so the caller falls back
    // to a value comparison. Only a bare VARIABLE counts: `1 is x` where x
    // holds 1 must still be a value test.
    std::string typeNameOperand(const node_ptr& node, Context* ctx) {
        if (!node || node->type() != NodeType::VARIABLE) return std::string();
        const std::string n = node->tok().value;
        if (n.empty()) return std::string();
        static const std::set<std::string> type_names = {
            "int","Integer","integer","float","Float","double","Double",
            "str","String","string","bool","Boolean","boolean",
            "list","List","array","Array","map","Map","dict","Dict",
            "tuple","Tuple","set","Set","bytes","bytearray",
            "none","None","function","Function","Object","object","any","Any"
        };
        if (type_names.count(n)) return n;
        // A declared class name is a type; a variable holding a value is not.
        if (class_by_name.count(n) && ctx && ctx->getByName(n).type == ValueType::UNDEFINED)
            return n;
        if (class_by_name.count(n)) return n;
        return std::string();
    }

    bool valueIsOfType(Value v, const std::string& want, Context* ctx) {
        // Everything is an Object, so the root always matches. That is the
        // point of having a root at all.
        if (want == "Object" || want == "object" || want == "any" || want == "Any")
            return true;

        switch (v.type) {
            case ValueType::INTEGER:
                return want=="int"||want=="Integer"||want=="integer";
            case ValueType::DOUBLE:
                return want=="float"||want=="Float"||want=="double"||want=="Double";
            case ValueType::BOOLEAN:
                return want=="bool"||want=="Boolean"||want=="boolean";
            case ValueType::NONE:
                return want=="none"||want=="None";
            default: break;
        }

        // Strings, lists, maps and instances are all USERDATA/COLLECTABLE here.
        // Rather than duplicate the logic that tells them apart, ask the same
        // `type` builtin the language exposes — one source of truth, so `is`
        // and `type()` can never disagree.
        std::string actual = legacyTypeName(v);
        auto names_type = [&](const std::string& t) {
            if (t == "string") return want=="str"||want=="String"||want=="string";
            if (t == "list")   return want=="list"||want=="List"||want=="array"||want=="Array";
            if (t == "map")    return want=="map"||want=="Map"||want=="dict"||want=="Dict";
            if (t == "tuple")  return want=="tuple"||want=="Tuple";
            if (t == "set")    return want=="set"||want=="Set";
            if (t == "frozenset") return want=="frozenset";
            // A builtin (print, len...) is a function like any other.
            if (t == "function" || t == "builtin") return want=="function"||want=="Function";
            if (t == "int")    return want=="int"||want=="Integer"||want=="integer";
            if (t == "float")  return want=="float"||want=="Float"||want=="double"||want=="Double";
            if (t == "bool")   return want=="bool"||want=="Boolean"||want=="boolean";
            if (t == "none")   return want=="none"||want=="None";
            return false;
        };
        if (names_type(actual) || actual == want) return true;
        // type(x) returns the type's name, so `type(t) is tuple` compares
        // that name with the type.
        if (actual == "string" && names_type(*static_cast<std::string*>(v.value.p))) return true;

        // Class membership, walking the inheritance chain so
        // `child is Base` holds.
        std::string cur = actual;
        int guard = 0;
        while (!cur.empty() && guard++ < 64) {
            if (cur == want) return true;
            auto cbn = class_by_name.find(cur);
            if (cbn == class_by_name.end()) break;
            auto pit = class_parent.find(cbn->second);
            if (pit == class_parent.end()) break;
            cur = pit->second;
        }
        return false;
    }

    Value objectProtocol(Value obj, const std::string& name,
                         std::vector<Value>& args, Context* ctx) {
        // instance_to_class maps to the class NODE, not to a name; the name
        // comes from func_names, the same route type() uses.
        auto class_of = [&]() -> std::string {
            auto it = instance_to_class.find(obj.value.p);
            if (it == instance_to_class.end()) return std::string("object");
            auto nit = func_names.find(it->second);
            if (nit == func_names.end()) return std::string("object");
            const std::string& n = nit->second;
            if (n.rfind("__class__:", 0) == 0) return n.substr(10);
            return n;
        };

        if (name == "class_name" || name == "type_name")
            return makeStringValue(class_of());
        if (name == "to_string" || name == "str") {
            // getStringValue() renders an instance through func_names, which
            // produces "<function __instance__:Child>" — the internal handle,
            // not a description of the object. Use the same "<Class instance>"
            // form print uses, and honour a user __str__ if the class has one.
            std::vector<Value> noargs;
            Value custom = isInstanceValue(obj) && instanceHasMethod(obj, "__str__")
                         ? callMethod(obj, "__str__", noargs, ctx) : NONE_VALUE;
            if (custom.type == ValueType::USERDATA && !getStringValue(custom).empty()
                && getStringValue(custom).rfind("<function", 0) != 0)
                return custom;
            // round 81: str(obj)'s default, <__main__.C object at 0x...>
            if (isInstanceValue(obj)) return makeStringValue(defaultInstanceRepr(obj, ctx ? ctx : global_ctx));
            return makeStringValue("<" + class_of() + " instance>");
        }
        if (name == "id") {
            // A pointer can exceed what bigint(long long) round-trips through
            // the numeric path; reduce it rather than returning 0.
            unsigned long long raw = (unsigned long long)(size_t)obj.value.p;
            return Value(bigint((long long)(raw & 0x7fffffffULL)));
        }
        if (name == "hash")
            return Value(bigint((long long)std::hash<std::string>{}(getStringValue(obj))));
        if (name == "is_a" || name == "instance_of") {
            if (args.empty()) return Value(false);
            std::string want = getStringValue(args[0]);
            // Walks the inheritance chain, so is_a("Base") is true for a
            // subclass — the whole point of asking.
            // class_parent is keyed by class NODE pointer, not by name, so the
            // chain is walked by looking each name back up in class_by_name.
            std::string cur = class_of();
            int guard = 0;
            while (!cur.empty() && guard++ < 64) {
                if (cur == want) return Value(true);
                auto cbn = class_by_name.find(cur);
                if (cbn == class_by_name.end()) break;
                auto pit = class_parent.find(cbn->second);
                if (pit == class_parent.end()) break;
                cur = pit->second;
            }
            return Value(false);
        }
        if (name == "equals_to" || name == "same_as") {
            if (args.empty()) return Value(false);
            return Value(getStringValue(obj) == getStringValue(args[0]));
        }
        if (name == "fields" || name == "attributes") {
            auto* lst = new Object((Runnable*)runner, "list", Type::LIST);
            int n = 0;
            auto pit = instance_properties.find(obj.value.p);
            if (pit != instance_properties.end() && pit->second)
                pit->second->access_container_shared([&](ContainerType* c) {
                    if (c) for (auto& kv : *c) lst->set(std::to_string(n++), makeStringValue(kv.first));
                });
            lst->set("__len__", Value((int)n));
            return Value((Collectable*)lst);
        }
        return UNDEFINED_VALUE;   // not part of the protocol (Value() is none)
    }

    // Modules imported by name, their namespaces (evalImport).
    std::unordered_map<std::string, Value> module_ns_;
    // ── sys.modules (round 80) ──────────────────────────────────────────
    // A real dict of the loaded modules, made the first time a program asks
    // for it (sys.modules, __import__, importlib - the prelude's
    // _ny_modules()). Once it exists every module registered is put in it
    // (noteModule), and an import first asks it (syncModule): a name deleted
    // from it is loaded again, a value assigned to it is what the import
    // binds. "__main__" is the prelude's _NyMainModule (the program's
    // globals, read through it).
    Value sys_modules_ = UNDEFINED_VALUE;
    Container* sysModulesCont() {
        if (sys_modules_.type == ValueType::UNDEFINED) return nullptr;
        return contOf(sys_modules_);
    }
    Value sysModulesValue() {
        if (sys_modules_.type != ValueType::UNDEFINED) return sys_modules_;
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        sys_modules_ = Value((Collectable*)d);
        auto put = [&](const std::string& n, const Value& v) { (*d->container)[nypy::key_of_str(n)] = v; };
        if (sys_ns_.type != ValueType::UNDEFINED) put("sys", sys_ns_);
        Value bm = global_ctx->getByName("_ny_builtins_module");
        if (bm.type != ValueType::UNDEFINED && bm.type != ValueType::NONE) {
            std::vector<Value> none;
            put("builtins", callFunctionValue(bm, none, global_ctx));
        }
        Value mm = global_ctx->getByName("_NyMainModule");
        if (mm.type != ValueType::UNDEFINED && mm.type != ValueType::NONE) {
            std::vector<Value> none;
            put("__main__", callFunctionValue(mm, none, global_ctx));
        }
        std::vector<std::string> names;
        for (auto& kv : module_ns_) names.push_back(kv.first);
        std::sort(names.begin(), names.end());
        for (auto& n : names) put(n, module_ns_[n]);
        return sys_modules_;
    }
    void noteModule(const std::string& name, const Value& v) {
        module_ns_[name] = v;
        if (Container* c = sysModulesCont()) (*c->container)[nypy::key_of_str(name)] = v;
    }
    void forgetModule(const std::string& name) {
        module_ns_.erase(name);
        imported_modules_.erase(name);
        if (Container* c = sysModulesCont()) c->container->erase(nypy::key_of_str(name));
    }
    // importlib's natives (round 80): a new empty module, a file run as a
    // module in a given one (exec_module, reload), and where `import name`
    // would find name - [path, "file" | "package" | "namespace" | ""].
    Value moduleNew(const std::string& name) {
        auto* ns = new Object((Runnable*)runner, name.empty() ? std::string("module") : name, Type::MAP);
        noteNamespace(ns);
        ns->set("__name__", makeStringValue(name));
        return Value((Collectable*)ns);
    }
    Value moduleExec(const Value& m, const std::string& path, const std::string& name) {
        if (!m.isCollectable() || !dynamic_cast<Object*>(m.value.gc)) pyRaise("TypeError", "_ny_module_exec(module, path, name)");
        struct stat st;
        if (stat(path.c_str(), &st) != 0) pyRaise("FileNotFoundError", "[Errno 2] No such file or directory: '" + path + "'");
        runModuleFile(path, name, m);
        return m;
    }
    Value findModule(const std::string& name) {
        bool dir = false;
        std::string p = name.empty() ? std::string() : findModulePath(nullptr, name, &dir);
        std::string kind = p.empty() ? "" : dir ? "namespace"
                         : nyrt::is_package_init(p) ? "package" : "file";
        return nyos_list_of({p, kind});
    }
    // What sys.modules says about `name` wins over the engine's own cache.
    void syncModule(const std::string& name) {
        Container* c = sysModulesCont();
        if (!c) return;
        auto it = c->container->find(nypy::key_of_str(name));
        auto mc = module_ns_.find(name);
        if (it == c->container->end()) {
            if (mc != module_ns_.end()) { module_ns_.erase(mc); imported_modules_.erase(name); }
            return;
        }
        if (mc == module_ns_.end() || mc->second.value.o != it->second.value.o || mc->second.type != it->second.type)
            module_ns_[name] = it->second;
    }
    // Scopes of the modules imported by name (importModule); a module lives
    // as long as the program, so its scope is never released.
    std::vector<Context*> module_ctxs_;

    // `from m import a, b` / `from m import *`: binds names of module m's
    // namespace in ctx (ImportError for a name m does not define). `*` binds
    // the names in m's __all__, or every name not starting with "_".
    void bindFromNamespace(const Value& nsv, const std::vector<std::string>& names,
                           const std::string& module_name, Context* ctx) {
        auto* ns = nsv.isCollectable() ? dynamic_cast<Object*>(nsv.value.gc) : nullptr;
        if ((!ns || !ns->container) && nsv.type != ValueType::NONE && nsv.type != ValueType::UNDEFINED
            && !(names.size() == 1 && names[0] == "*")) {
            // round 80: any object put in sys.modules - its attributes
            for (const auto& entry : names) {
                auto [n, bound] = nyrt::import_name_alias(entry);
                Value v;
                if (!getAttrValue(nsv, n, ctx, v))
                    throw std::string("__exc__:ImportError:cannot import name '" + n + "' from '" + module_name + "'");
                ctx->defineByName(bound, v);
            }
            return;
        }
        if (!ns || !ns->container) throw std::string("__exc__:ImportError:cannot import from \"" + module_name + "\"");
        if (names.size() == 1 && names[0] == "*") {
            auto all = ns->container->find("__all__");
            if (all != ns->container->end()) {
                for (const Value& nm : iterItems(all->second, ctx)) {
                    std::string k = isStringValue(nm) ? getStringValue(nm) : nm.toString();
                    auto it = ns->container->find(k);
                    if (it == ns->container->end())
                        throw std::string("__exc__:AttributeError:module '" + module_name + "' has no attribute '" + k + "'");
                    ctx->defineByName(k, it->second);
                }
                return;
            }
            for (auto& kv : *ns->container)
                if (!kv.first.empty() && kv.first[0] != '_') ctx->defineByName(kv.first, kv.second);
            return;
        }
        for (const auto& entry : names) {
            auto [n, bound] = nyrt::import_name_alias(entry);
            auto it = ns->container->find(n);
            if (it == ns->container->end())
                throw std::string("__exc__:ImportError:cannot import name '" + n + "' from '" + module_name + "'");
            ctx->defineByName(bound, it->second);
        }
    }

    // `import m` / `import m as x` / `from m import ...` of a module FILE
    // named without quotes: Python's module semantics (round 77). The module
    // runs once, in a scope of its own (Context::inModule: its functions'
    // plain assignments and `global` stop there), whose parent is the global
    // scope, so builtins and the prelude are visible to it. The importer gets
    // only the binding: the namespace (the module's scope as it was when the
    // module finished running), or the names it asked for. A quoted import
    // (`import "lib/x.ny"`) still includes the file into the importing scope,
    // which the IDE's files and older programs rely on.
    // ── packages (round 77) ─────────────────────────────────────────────
    // The file of module `dotted` ("a.b.c" -> a/b/c.ny, or the package's
    // a/b/c/__init__.ny), looked for beside the importing file, in the working
    // directory and its lib/, the importer's ancestors, NYTHONPATH and the
    // interpreter's own lib/. A directory with neither is a namespace package
    // (*is_dir). "" when nothing is found.
    std::vector<std::string> moduleDirs(const node_ptr& node) {
        std::vector<std::string> dirs;
        std::string here = importerDir(node);
        // A module of a package does not search beside itself (Python has no
        // implicit relative imports; the VM never searched there): `from abc
        // import ABCMeta` in lib/collections/abc.ny is lib/abc.ny, not the
        // module importing it (round 77).
        struct stat pst;
        bool in_package = !here.empty() && (stat((here + "__init__.ny").c_str(), &pst) == 0
                                            || stat((here + "__init__.py").c_str(), &pst) == 0);
        if (!here.empty() && !in_package) { dirs.push_back(here); dirs.push_back(here + "lib/"); }
        for (auto& d : sysPathDirs()) dirs.push_back(d);   // round 80
        for (const char* d : {"", "./", "lib/", "./lib/"}) dirs.push_back(d);
        std::string anc = parentDirOf(here);
        for (int up = 0; up < 4 && !anc.empty(); ++up) {
            dirs.push_back(anc); dirs.push_back(anc + "lib/");
            std::string next = parentDirOf(anc);
            if (next == anc) break;
            anc = next;
        }
        for (auto& d : nyrt::library_dirs()) dirs.push_back(d);
        return dirs;
    }
    // round 80: sys.path's entries (a program's sys.path.insert(0, d) is
    // searched), then the main script's directory - CPython's sys.path[0],
    // which __import__ / importlib reach from exec'd code. Each ends with a
    // separator.
    std::vector<std::string> sysPathDirs() {
        std::vector<std::string> dirs;
        if (sys_ns_.type != ValueType::UNDEFINED)
            if (Container* sc = contOf(sys_ns_)) {
                auto pit = sc->container->find("path");
                if (pit != sc->container->end() && contOf(pit->second))
                    for (auto& e : listItems(pit->second)) {
                        if (!isStringValue(e)) continue;
                        std::string d = getStringValue(e);
                        if (d.empty()) continue;
                        if (d.back() != '/' && d.back() != '\\') d += '/';
                        dirs.push_back(d);
                    }
            }
        const std::string& sp = nyrt::script_path();
        size_t cut = sp.find_last_of("/\\");
        if (cut != std::string::npos) dirs.push_back(sp.substr(0, cut + 1));
        return dirs;
    }
    std::string findModulePath(const node_ptr& node, const std::string& dotted, bool* is_dir = nullptr) {
        std::string rel = dotted;
        std::replace(rel.begin(), rel.end(), '.', '/');
        struct stat st;
        auto dirs = moduleDirs(node);
        // round 81: `builtins` is the builtin module whatever sits beside
        // the script (CPython's BuiltinImporter comes first)
        if (dotted == "builtins") dirs = nyrt::library_dirs();
        // round 82: then name.py / name/__init__.py, when no directory has
        // a .ny one (nyrt::module_exts)
        for (auto& ext : nyrt::module_exts())
            for (auto& d : dirs) {
                if (stat((d + rel + ext).c_str(), &st) == 0 && !S_ISDIR(st.st_mode)) return d + rel + ext;
                if (stat((d + rel + "/__init__" + ext).c_str(), &st) == 0) return d + rel + "/__init__" + ext;
            }
        if (is_dir) for (auto& d : dirs) {
            std::string p = d.empty() ? rel : d + rel;
            if (stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode) && ny_fs::holds_modules(p)) { *is_dir = true; return p; }
        }
        return std::string();
    }
    // Whether `name` is a package (a directory of modules) rather than a file.
    bool isPackageName(const node_ptr& node, const std::string& name) {
        bool dir = false;
        std::string p = findModulePath(node, name, &dir);
        return dir || nyrt::is_package_init(p);
    }
    // Module `dotted`, loaded once (its namespace).
    Value loadModule(const node_ptr& node, const std::string& dotted) {
        syncModule(dotted);   // round 80
        auto it = module_ns_.find(dotted);
        if (it != module_ns_.end()) return it->second;
        bool dir = false;
        std::string path = findModulePath(node, dotted, &dir);
        if (path.empty()) throw std::string("__exc__:ModuleNotFoundError:No module named '" + dotted + "'");
        if (dir) {
            auto* ns = new Object((Runnable*)runner, dotted, Type::MAP);
            noteNamespace(ns);
            ns->set("__name__", makeStringValue(dotted));
            Value nsv((Collectable*)ns);
            noteModule(dotted, nsv);   // round 80: sys.modules too
            return nsv;
        }
        return runModuleFile(path, dotted);
    }
    // import a.b.c / import a.b as x / from a.b import c, d (c may itself be
    // a submodule a/b/c.ny): each package's namespace gets its loaded
    // submodules as attributes.
    Value importDotted(const node_ptr& node, ImportNode* in_node, const std::string& module_name, Context* ctx) {
        // `import os.path` binds os, `import os.path as p` and `from
        // os.path import join` the path namespace of the builtin os
        // module (round 77: "No module named 'os.path'")
        if (module_name == "os.path") {
            Value osv = makeOsNamespace();
            Value pv = NONE_VALUE;
            if (auto* po = dynamic_cast<Object*>(osv.value.gc)) {
                auto it = po->container->find("path");
                if (it != po->container->end()) pv = it->second;
            }
            if (!in_node->names.empty()) bindFromNamespace(pv, in_node->names, module_name, ctx);
            else if (!in_node->alias.empty()) ctx->defineByName(in_node->alias, pv);
            else ctx->defineByName("os", osv);
            return NONE_VALUE;
        }
        std::vector<std::string> parts;
        size_t a = 0;
        while (a <= module_name.size()) {
            size_t b = module_name.find('.', a);
            if (b == std::string::npos) b = module_name.size();
            parts.push_back(module_name.substr(a, b - a));
            a = b + 1;
        }
        Value first, prev;
        std::string prefix;
        for (size_t i = 0; i < parts.size(); i++) {
            prefix = i ? prefix + "." + parts[i] : parts[i];
            Value ns = loadModule(node, prefix);
            if (i == 0) first = ns;
            else if (auto* po = dynamic_cast<Object*>(prev.value.gc)) po->set(parts[i], ns);
            prev = ns;
        }
        if (!in_node->names.empty()) {
            auto* po = dynamic_cast<Object*>(prev.value.gc);
            for (auto& entry : in_node->names) {
                std::string n = nyrt::import_name_alias(entry).first;
                if (n == "*" || !po || po->container->count(n)) continue;
                bool dir = false;
                if (!findModulePath(node, module_name + "." + n, &dir).empty())
                    po->set(n, loadModule(node, module_name + "." + n));
            }
            bindFromNamespace(prev, in_node->names, module_name, ctx);
        } else if (!in_node->alias.empty()) ctx->defineByName(in_node->alias, prev);
        else ctx->defineByName(parts[0], first);
        return NONE_VALUE;
    }
    // Runs a module file in a scope of its own; its namespace.
    // `into` (round 80): an existing module namespace to run the file in -
    // importlib.reload(m), a loader's exec_module(m) - instead of a new one.
    Value runModuleFile(const std::string& filepath, const std::string& module_name, Value into = UNDEFINED_VALUE) {
        auto source = SourceCode(filepath);
        auto reporter = std::make_shared<Reporter>(source);
        auto lex = std::make_shared<Lexer>(source);
        lex->tokenize();
        auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)runner, lex.get());
        auto ast = parser->parse();
        if (!ast) throw std::string("__exc__:ImportError:cannot import \"" + filepath + "\"");
        nython::scope::qualify_module_classes(ast, module_name);
        imported_asts.push_back(ast);
        Object* ns = into.isCollectable() ? dynamic_cast<Object*>(into.value.gc) : nullptr;
        if (!ns) {
            ns = new Object((Runnable*)runner, module_name, Type::MAP);
            noteNamespace(ns);
        }
        Value nsv((Collectable*)ns);
        // Registered before the module runs, so a circular import binds it
        // (round 80: in sys.modules too; exec_module / reload register nothing)
        if (into.type == ValueType::UNDEFINED) noteModule(module_name, nsv);
        Context* mctx = new Context(runner, module_name, nullptr, nullptr, module_base_ctx_ ? module_base_ctx_ : global_ctx);
        mctx->inModule = true;
        mctx->parentFilter = &module_filter_;
        // round 79: the module's scope IS its namespace's map (as exec(src,
        // ns) does), so the module object stays live: what its functions
        // rebind with `global` is what importers read (mimetypes.inited,
        // zoneinfo.TZPATH), and `mod.x = v` from outside is what they see.
        delete mctx->container;
        mctx->container = ns->container;
        mctx->ns_owner = ns;
        nygc::incref(ns);
        module_ctxs_.push_back(mctx);
        mctx->defineByName("__name__", makeStringValue(module_name));
        mctx->defineByName("__file__", makeStringValue(filepath));
        {   // round 80: __package__ (relative imports, importlib) and a package's __path__
            bool pkg = nyrt::is_package_init(filepath);
            size_t dot = module_name.rfind('.');
            mctx->defineByName("__package__", makeStringValue(pkg ? module_name : dot == std::string::npos ? std::string() : module_name.substr(0, dot)));
            if (pkg) {
                std::string dir = filepath.substr(0, filepath.size() - 12);
#ifdef _WIN32
                for (char& ch : dir) if (ch == '/') ch = '\\';   // native separators, as CPython's __path__ (round 80)
#endif
                mctx->defineByName("__path__", nyos_list_of({dir}));
            }
        }
        std::unordered_set<void*> before;
        for (auto& kv : func_names) before.insert(kv.first);
        {
            FrameGuard _frame(nullptr, mctx);   // round 77: <module> of the file
            try { evalNode(ast, mctx); }
            catch (nython::node::ReturnSignal&) {}
            catch (std::string& flow) { tbUnwind(flow); if (into.type == ValueType::UNDEFINED) forgetModule(module_name); throw; }
            catch (std::exception& e) { tbUnwind(excFromCpp(e.what())); if (into.type == ValueType::UNDEFINED) forgetModule(module_name); throw; }
        }
        for (auto& kv : func_names) if (!before.count(kv.first)) module_owned_.insert(kv.first);
        return nsv;
    }
    Value importModule(const std::string& filepath, const std::string& module_name,
                       ImportNode* in_node, const std::string& bind_as, Context* ctx) {
        Value nsv = runModuleFile(filepath, module_name);
        if (!in_node->names.empty()) bindFromNamespace(nsv, in_node->names, module_name, ctx);
        else if (!bind_as.empty()) ctx->defineByName(bind_as, nsv);
        return NONE_VALUE;
    }
    static bool isIdentifierText(const std::string& n) {
        if (n.empty() || !(std::isalpha((unsigned char)n[0]) || n[0] == '_')) return false;
        for (char c : n) if (!(std::isalnum((unsigned char)c) || c == '_')) return false;
        return true;
    }
    // A relative import's module (round 80: `from .m import x`, `from ..
    // import y` - the parser keeps the dots in the name): CPython's
    // _calc___package__ and _resolve_name over the importing module's
    // __package__, else its __name__ (a package's own when it has __path__).
    std::string resolveRelativeImport(const std::string& rel, Context* ctx) {
        size_t level = 0;
        while (level < rel.size() && rel[level] == '.') level++;
        std::string rest = rel.substr(level), package;
        Value pk = ctx->getByName("__package__");
        if (isStringValue(pk)) package = getStringValue(pk);
        else {
            Value nm = ctx->getByName("__name__");
            if (isStringValue(nm)) {
                package = getStringValue(nm);
                Value pth = ctx->getByName("__path__");
                if (pth.type == ValueType::UNDEFINED || pth.type == ValueType::NONE) {
                    size_t c = package.rfind('.');
                    package = c == std::string::npos ? std::string() : package.substr(0, c);
                }
            }
        }
        if (package.empty()) pyRaise("ImportError", "attempted relative import with no known parent package");
        for (size_t i = 1; i < level; i++) {
            size_t c = package.rfind('.');
            if (c == std::string::npos) pyRaise("ImportError", "attempted relative import beyond top-level package");
            package = package.substr(0, c);
        }
        return rest.empty() ? package : package + "." + rest;
    }
    Value evalImport(const node_ptr& node, Context* ctx) {
        auto in_node = static_pointer_cast<ImportNode>(node);
        std::string module_name = in_node->module_name;
        // Strip quotes if present
        bool quoted = in_node->quoted;
        if (module_name.size() >= 2 && (module_name[0] == '"' || module_name[0] == '\'')) {
            module_name = module_name.substr(1, module_name.size() - 2);
            quoted = true;
        }
        if (!quoted && !module_name.empty() && module_name[0] == '.') module_name = resolveRelativeImport(module_name, ctx);   // round 80
        // `import name` (an identifier, not a quoted path) binds `name` to the
        // module's namespace, as in Python (round 77); its names are also
        // defined in the importing scope, as every import here always did.
        // A module runs once: a later import binds the cached namespace.
        std::string implicit_alias;
        const bool from_import = !in_node->names.empty();
        if (!quoted && in_node->alias.empty() && !from_import && isIdentifierText(module_name)) implicit_alias = module_name;
        if (!quoted) syncModule(module_name);   // round 80: sys.modules first
        // round 81: sys.meta_path / sys.path_hooks - a module not loaded yet
        // is offered to a program's own finders (the prelude's
        // _ny_import_via_hooks, None at once while there are none: the
        // native search below)
        if (!quoted && sys_ns_.type != ValueType::UNDEFINED && !module_ns_.count(module_name)) {
            Value hook = global_ctx->getByName("_ny_import_via_hooks");
            if (hook.type == ValueType::USERDATA && hook.value.p) {
                std::vector<Value> ha{makeStringValue(module_name)};
                Value got = callFunctionValue(hook, ha, ctx);
                if (got.type != ValueType::NONE && got.type != ValueType::UNDEFINED) syncModule(module_name);
            }
        }
        {
            // a module runs once: a later import (named or aliased) binds the
            // namespace its first import made
            const std::string& want = !in_node->alias.empty() ? in_node->alias : implicit_alias;
            auto mc = module_ns_.find(module_name);
            if (mc != module_ns_.end() && module_name.find('.') == std::string::npos) {
                // a name the namespace lacks may be a package's submodule
                // not loaded yet (import urllib; from urllib import parse):
                // the package path below loads it, as the VM does (round 77)
                bool all_bound = true;
                if (from_import && !quoted && mc->second.isCollectable() && mc->second.value.gc)
                    if (auto* po = dynamic_cast<Object*>(mc->second.value.gc))
                        for (auto& entry : in_node->names) {
                            std::string n = nyrt::import_name_alias(entry).first;
                            if (n != "*" && !po->container->count(n)) { all_bound = false; break; }
                        }
                if (from_import && !quoted && (all_bound || !isPackageName(node, module_name))) { bindFromNamespace(mc->second, in_node->names, module_name, ctx); return NONE_VALUE; }
                if (!want.empty()) { ctx->defineByName(want, mc->second); return NONE_VALUE; }
            }
        }
        // a.b.c, and packages (directories of modules): before the builtin
        // module names, so a package named like one (lib/http/) is found.
        if (!quoted && (module_name.find('.') != std::string::npos || isPackageName(node, module_name)))
            return importDotted(node, in_node.get(), module_name, ctx);

        // Circular import guard.
        //
        // An ALIASED import must still build its namespace even when the module
        // has already been loaded: `import "m"` followed by `import "m" as x`
        // would otherwise return here, and the diff that populates `x` would
        // see nothing new, so the alias exposed only whatever happened to be
        // defined between the two imports. Re-running the module is safe — it
        // is idempotent by construction — and is what makes the alias complete.
        if (imported_modules_.count(module_name) && in_node->alias.empty())
            return NONE_VALUE;
        imported_modules_.insert(module_name);

        // Candidate paths. The importing script's OWN directory was missing, so
        // `import "mylib"` from examples/import2.ny never found
        // examples/mylib.ny sitting beside it — it only ever looked relative to
        // the working directory. A module next to the file that imports it is
        // the most obvious place to look and was the one place not searched.
        std::vector<std::string> paths;
        {
            std::string here = importerDir(node);
            if (!here.empty()) {
                paths.push_back(here + module_name + ".ny");
                paths.push_back(here + module_name);
                paths.push_back(here + "lib/" + module_name + ".ny");
            }
        }
        paths.push_back(module_name + ".ny");
        paths.push_back(module_name);
        paths.push_back("./" + module_name + ".ny");
        paths.push_back("./lib/" + module_name + ".ny");

        // A standard module written in Nython (lib/json.ny, lib/re.ny, ...)
        // is the module `import json` binds; the names below were bare
        // acknowledgements of builtin groups (nyrt::prefers_lib_module).
        if (!quoted && nyrt::prefers_lib_module(module_name)) {
            std::string p = findModulePath(node, module_name);
            if (!p.empty()) {
                Value nsv = module_ns_.count(module_name) ? module_ns_[module_name] : runModuleFile(p, module_name);
                if (from_import) bindFromNamespace(nsv, in_node->names, module_name, ctx);
                else ctx->defineByName(!in_node->alias.empty() ? in_node->alias : module_name, nsv);
                return NONE_VALUE;
            }
        }
        // Check builtin modules first
        if (module_name == "string") {
                registerBuiltin("isdigit_str");
                registerBuiltin("isalpha_str");
                return NONE_VALUE;
        }
        if (module_name == "io" || module_name == "fs" || module_name == "file") {
                registerBuiltin("read_file"); registerBuiltin("write_file");
                registerBuiltin("file_exists");
                registerBuiltin("open"); registerBuiltin("file_open");
                registerBuiltin("file_close"); registerBuiltin("fclose");
                registerBuiltin("file_read"); registerBuiltin("fread");
                registerBuiltin("file_write"); registerBuiltin("fwrite");
                registerBuiltin("file_readline"); registerBuiltin("freadline");
                registerBuiltin("file_readlines"); registerBuiltin("readlines");
                registerBuiltin("file_writelines"); registerBuiltin("writelines");
                registerBuiltin("file_append"); registerBuiltin("append_file");
                registerBuiltin("file_size"); registerBuiltin("file_delete");
                registerBuiltin("file_mtime");
                registerBuiltin("file_rename"); registerBuiltin("file_copy");
                registerBuiltin("print_to"); registerBuiltin("fprint");
                registerBuiltin("eprint"); registerBuiltin("print_err");
                registerBuiltin("flush"); registerBuiltin("remove_file");
                return NONE_VALUE;
        }
        if (module_name == "shell" || module_name == "sh") {
                registerBuiltin("shell"); registerBuiltin("system"); registerBuiltin("cmd");
                registerBuiltin("ls"); registerBuiltin("cat"); registerBuiltin("pwd");
                registerBuiltin("mkdir"); registerBuiltin("write"); registerBuiltin("exists");
                registerBuiltin("env");
                return NONE_VALUE;
        }
        if (module_name == "nytorch") {
                registerBuiltin("tensor");
                registerBuiltin("tensor_add"); registerBuiltin("tensor_sub");
                registerBuiltin("tensor_mul"); registerBuiltin("tensor_dot");
                registerBuiltin("tensor_sum"); registerBuiltin("tensor_mean");
                registerBuiltin("tensor_max"); registerBuiltin("tensor_min");
                registerBuiltin("tensor_scale"); registerBuiltin("tensor_apply");
                registerBuiltin("relu"); registerBuiltin("sigmoid"); registerBuiltin("tanh_fn");
                registerBuiltin("tanh_act"); registerBuiltin("leaky_relu"); registerBuiltin("softmax"); registerBuiltin("tensor_softmax");
                registerBuiltin("tensor_exp"); registerBuiltin("tensor_log"); registerBuiltin("tensor_sqrt");
                registerBuiltin("tensor_abs"); registerBuiltin("tensor_neg"); registerBuiltin("tensor_pow");
                registerBuiltin("tensor_matmul"); registerBuiltin("matmul");
                registerBuiltin("tensor_transpose"); registerBuiltin("tensor_concat");
                registerBuiltin("tensor_zeros"); registerBuiltin("zeros");
                registerBuiltin("tensor_ones"); registerBuiltin("ones");
                registerBuiltin("tensor_rand"); registerBuiltin("rand_tensor");
                registerBuiltin("tensor_randn"); registerBuiltin("randn_tensor");
                registerBuiltin("exp"); registerBuiltin("tanh"); registerBuiltin("atan2"); registerBuiltin("tensor_cumprod"); registerBuiltin("tensor_sign"); registerBuiltin("logsumexp"); registerBuiltin("tensor_scatter_add"); registerBuiltin("tensor_gather");
        registerBuiltin("http_get"); registerBuiltin("http_post");
        registerBuiltin("load_text"); registerBuiltin("read_text"); registerBuiltin("save_text"); registerBuiltin("write_text"); registerBuiltin("append_text");
        registerBuiltin("path_exists"); registerBuiltin("list_dir");
        // OS builtins (available with import nytorch for lib compatibility)
        registerBuiltin("os_path_join"); registerBuiltin("os_path_basename");
        registerBuiltin("os_path_dirname"); registerBuiltin("os_path_ext");
        registerBuiltin("os_path_abs"); registerBuiltin("os_exists");
        registerBuiltin("os_isfile"); registerBuiltin("os_isdir");
        registerBuiltin("os_mkdir"); registerBuiltin("os_remove");
        registerBuiltin("os_rename"); registerBuiltin("os_listdir");
        registerBuiltin("os_getcwd"); registerBuiltin("os_getenv");
        registerBuiltin("os_setenv"); registerBuiltin("os_exec");
        registerBuiltin("fs_stat"); registerBuiltin("fs_mkdirs");
        registerBuiltin("json_encode"); registerBuiltin("json_decode");
        registerBuiltin("string_split"); registerBuiltin("string_join"); registerBuiltin("string_replace");
        registerBuiltin("string_contains"); registerBuiltin("string_lower"); registerBuiltin("string_upper");
        registerBuiltin("string_strip"); registerBuiltin("string_startswith"); registerBuiltin("string_endswith");
        registerBuiltin("string_format"); registerBuiltin("string_count"); registerBuiltin("string_find");
        registerBuiltin("string_slice"); registerBuiltin("json_stringify");
        registerBuiltin("device_info"); registerBuiltin("time_now"); registerBuiltin("time_ms");
        registerBuiltin("process_exec"); registerBuiltin("env_get");
        registerBuiltin("base64_encode"); registerBuiltin("sha256");
        registerBuiltin("zip_list"); registerBuiltin("zip_extract_text");
        registerBuiltin("html_strip"); registerBuiltin("regex_extract");
        registerBuiltin("tensor_benchmark");
                registerBuiltin("tensor_arange"); registerBuiltin("tensor_linspace");
                registerBuiltin("linspace"); registerBuiltin("logspace");
                registerBuiltin("tensor_median"); registerBuiltin("tensor_cummax"); registerBuiltin("tensor_cummin");
                registerBuiltin("tensor_flip"); registerBuiltin("tensor_roll"); registerBuiltin("tensor_unique");
                registerBuiltin("tensor_abs"); registerBuiltin("tensor_pow"); registerBuiltin("tensor_sqrt");
                registerBuiltin("tensor_matmul"); registerBuiltin("matmul");
                registerBuiltin("mel_filterbank"); registerBuiltin("mfcc");
                registerBuiltin("stft_magnitude"); registerBuiltin("ctc_loss");
                registerBuiltin("softplus"); registerBuiltin("mish");
                registerBuiltin("mse_loss"); registerBuiltin("cross_entropy_loss");
                registerBuiltin("numerical_gradient");
                registerBuiltin("tensor_clip"); registerBuiltin("tensor_clamp");
                registerBuiltin("tensor_argmax"); registerBuiltin("argmax");
                registerBuiltin("tensor_argmin"); registerBuiltin("argmin");
                registerBuiltin("tensor_norm"); registerBuiltin("norm");
                registerBuiltin("tensor_normalize");
                registerBuiltin("tensor_slice"); registerBuiltin("tensor_reshape");
                registerBuiltin("one_hot"); registerBuiltin("binary_cross_entropy");
                registerBuiltin("accuracy");
                registerBuiltin("conv1d"); registerBuiltin("max_pool1d"); registerBuiltin("avg_pool1d");
                registerBuiltin("dropout"); registerBuiltin("embedding"); registerBuiltin("embedding_lookup");
                registerBuiltin("cosine_similarity"); registerBuiltin("cos_sim");
                registerBuiltin("attention"); registerBuiltin("scaled_dot_attention");
                registerBuiltin("batch_norm"); registerBuiltin("batchnorm");
                registerBuiltin("layer_norm"); registerBuiltin("layernorm");
                registerBuiltin("gelu"); registerBuiltin("elu"); registerBuiltin("swish"); registerBuiltin("silu");
                registerBuiltin("tensor_where"); registerBuiltin("huber_loss");
                registerBuiltin("tensor_var"); registerBuiltin("tensor_std"); registerBuiltin("tensor_cumsum");
                registerBuiltin("gelu"); registerBuiltin("swish"); registerBuiltin("silu");
                registerBuiltin("elu"); registerBuiltin("tensor_where");
                registerBuiltin("tensor_cumsum"); registerBuiltin("tensor_diff");
                registerBuiltin("tensor_var"); registerBuiltin("tensor_std");
                registerBuiltin("huber_loss");
                registerBuiltin("tensor_var"); registerBuiltin("tensor_variance");
                registerBuiltin("tensor_std"); registerBuiltin("tensor_where");
                registerBuiltin("tensor_stack"); registerBuiltin("elu");
                registerBuiltin("gelu"); registerBuiltin("silu"); registerBuiltin("swish");
                registerBuiltin("layer_norm"); registerBuiltin("tensor_cumsum");
                registerBuiltin("tensor_diff"); registerBuiltin("tensor_outer");
                registerBuiltin("huber_loss");
                registerBuiltin("tensor_var"); registerBuiltin("variance");
                registerBuiltin("tensor_std"); registerBuiltin("std_dev");
                registerBuiltin("tensor_where"); registerBuiltin("where");
                registerBuiltin("tensor_stack"); registerBuiltin("tensor_split");
                registerBuiltin("huber_loss");
                registerBuiltin("multi_head_attention");
                registerBuiltin("gelu"); registerBuiltin("silu"); registerBuiltin("swish");
                registerBuiltin("elu"); registerBuiltin("layer_norm");
                // Agent I/O & Network
                registerBuiltin("tensor_save"); registerBuiltin("tensor_load");
                registerBuiltin("model_save");  registerBuiltin("model_load");
                registerBuiltin("kv_set"); registerBuiltin("kv_get");
                registerBuiltin("kv_del"); registerBuiltin("kv_keys"); registerBuiltin("kv_all");
                registerBuiltin("http_post_json"); registerBuiltin("http_get_json");
                registerBuiltin("http_request"); registerBuiltin("http_get"); registerBuiltin("http_post");
                registerBuiltin("agent_broadcast"); registerBuiltin("agent_listen");
                registerBuiltin("agent_send"); registerBuiltin("agent_recv");
                registerBuiltin("tcp_server_create"); registerBuiltin("tcp_accept"); registerBuiltin("tcp_connect");
                registerBuiltin("tcp_send"); registerBuiltin("tcp_recv"); registerBuiltin("tcp_recv_all"); registerBuiltin("tcp_close");
                registerBuiltin("http_respond"); registerBuiltin("http_parse_request");
                registerBuiltin("fs_mkdirs"); registerBuiltin("fs_stat"); registerBuiltin("fs_walk");
                registerBuiltin("path_join"); registerBuiltin("path_basename");
                registerBuiltin("path_dirname"); registerBuiltin("path_ext");
                registerBuiltin("read_bytes"); registerBuiltin("write_bytes");
                registerBuiltin("json_encode"); registerBuiltin("json_decode");
                registerBuiltin("json_stringify"); registerBuiltin("json_parse");
                registerBuiltin("time_now"); registerBuiltin("time_timestamp"); registerBuiltin("time_sleep");
                // File I/O
                registerBuiltin("read_file"); registerBuiltin("write_file");
                registerBuiltin("file_append"); registerBuiltin("append_file");
                registerBuiltin("file_delete"); registerBuiltin("file_exists");
                registerBuiltin("listdir"); registerBuiltin("mkdir");
                registerBuiltin("random_int"); registerBuiltin("random_float"); registerBuiltin("random_choice");
                // Vision 2D, extended tensor, NLP, signal
                registerBuiltin("tensor2d_get"); registerBuiltin("tensor2d_set");
                registerBuiltin("tensor2d_conv"); registerBuiltin("tensor2d_maxpool");
                registerBuiltin("tensor_sort"); registerBuiltin("tensor_topk");
                registerBuiltin("tensor_eye"); registerBuiltin("tensor_diag");
                registerBuiltin("tensor_flatten"); registerBuiltin("tensor_pad");
                registerBuiltin("tensor_dot_product"); registerBuiltin("tensor_cosine_sim");
                registerBuiltin("tensor_corr"); registerBuiltin("tensor_histogram");
                registerBuiltin("tensor_percentile"); registerBuiltin("tensor_zscore");
                registerBuiltin("text_tokenize"); registerBuiltin("text_ngrams");
                registerBuiltin("text_char_ids"); registerBuiltin("text_from_ids");
                registerBuiltin("text_bow");
                registerBuiltin("fft_magnitude"); registerBuiltin("signal_window");
                registerBuiltin("signal_rms"); registerBuiltin("signal_zero_crossings");
                return NONE_VALUE;
        }
        if (module_name == "nytorch_classes") {
                // Load nytorch builtins first (if not already)
                if (!imported_modules_.count("nytorch")) {
                    imported_modules_.insert("nytorch");
                    // Minimal builtin registration for tensor ops
                    registerBuiltin("tensor"); registerBuiltin("tensor_add"); registerBuiltin("tensor_sub");
                    registerBuiltin("tensor_mul"); registerBuiltin("tensor_dot");
                    registerBuiltin("tensor_sum"); registerBuiltin("tensor_mean");
                    registerBuiltin("tensor_zeros"); registerBuiltin("tensor_ones");
                    registerBuiltin("tensor_rand"); registerBuiltin("tensor_randn");
                    registerBuiltin("relu"); registerBuiltin("sigmoid"); registerBuiltin("softmax");
                }
                // Load the class library
                {
                    std::vector<std::string> ny_paths = {"lib/nytorch.ny", "./lib/nytorch.ny", locateModuleFile(node, "lib/nytorch.ny")};
                    for (auto& np : ny_paths) {
                        struct stat nst; if (stat(np.c_str(), &nst) == 0) {
                            try {
                                auto nsrc = SourceCode(np); auto nrep = std::make_shared<Reporter>(nsrc);
                                auto nlx = std::make_shared<Lexer>(nsrc); nlx->tokenize();
                                auto npr = std::make_shared<Parser>(nrep.get(), (Runnable*)runner, nlx.get());
                                auto nast = npr->parse();
                                if (nast) { imported_asts.push_back(nast); evalNode(nast, ctx); }
                            } catch (...) {}
                            break;
                        }
                    }
                }
                return NONE_VALUE;
        }
        if (module_name == "agent_net") {
                registerBuiltin("tensor_save"); registerBuiltin("tensor_load");
                registerBuiltin("model_save");  registerBuiltin("model_load");
                registerBuiltin("kv_set"); registerBuiltin("kv_get");
                registerBuiltin("kv_del"); registerBuiltin("kv_keys"); registerBuiltin("kv_all");
                registerBuiltin("http_post_json"); registerBuiltin("http_get_json");
                registerBuiltin("http_request"); registerBuiltin("http_get"); registerBuiltin("http_post");
                registerBuiltin("agent_broadcast"); registerBuiltin("agent_listen");
                registerBuiltin("agent_send"); registerBuiltin("agent_recv");
                registerBuiltin("tcp_server_create"); registerBuiltin("tcp_accept"); registerBuiltin("tcp_connect");
                registerBuiltin("tcp_send"); registerBuiltin("tcp_recv"); registerBuiltin("tcp_recv_all"); registerBuiltin("tcp_close");
                registerBuiltin("http_respond"); registerBuiltin("http_parse_request");
                registerBuiltin("fs_mkdirs"); registerBuiltin("fs_stat"); registerBuiltin("fs_walk");
                registerBuiltin("path_join"); registerBuiltin("path_basename");
                registerBuiltin("path_dirname"); registerBuiltin("path_ext");
                registerBuiltin("read_bytes"); registerBuiltin("write_bytes");
                registerBuiltin("json_encode"); registerBuiltin("json_decode");
                registerBuiltin("json_stringify"); registerBuiltin("json_parse");
                registerBuiltin("time_now"); registerBuiltin("time_timestamp"); registerBuiltin("time_sleep");
                return NONE_VALUE;
        }
        if (module_name == "ai" || module_name == "ml") {
                registerBuiltin("tensor");
                registerBuiltin("tensor_add"); registerBuiltin("tensor_sub");
                registerBuiltin("tensor_mul"); registerBuiltin("tensor_dot");
                registerBuiltin("tensor_sum"); registerBuiltin("tensor_mean");
                registerBuiltin("tensor_max"); registerBuiltin("tensor_min");
                registerBuiltin("tensor_scale"); registerBuiltin("tensor_apply");
                registerBuiltin("relu"); registerBuiltin("sigmoid"); registerBuiltin("tanh_fn");
                registerBuiltin("tanh_act"); registerBuiltin("leaky_relu"); registerBuiltin("softmax"); registerBuiltin("tensor_softmax");
                registerBuiltin("tensor_exp"); registerBuiltin("tensor_log"); registerBuiltin("tensor_sqrt");
                registerBuiltin("tensor_abs"); registerBuiltin("tensor_neg"); registerBuiltin("tensor_pow");
                registerBuiltin("tensor_matmul"); registerBuiltin("matmul");
                registerBuiltin("tensor_transpose"); registerBuiltin("tensor_concat");
                registerBuiltin("tensor_zeros"); registerBuiltin("zeros");
                registerBuiltin("tensor_ones"); registerBuiltin("ones");
                registerBuiltin("tensor_rand"); registerBuiltin("rand_tensor");
                registerBuiltin("tensor_randn"); registerBuiltin("randn_tensor");
                registerBuiltin("exp"); registerBuiltin("tanh"); registerBuiltin("atan2"); registerBuiltin("tensor_cumprod"); registerBuiltin("tensor_sign"); registerBuiltin("logsumexp"); registerBuiltin("tensor_scatter_add"); registerBuiltin("tensor_gather");
                registerBuiltin("tensor_arange"); registerBuiltin("tensor_linspace");
                registerBuiltin("linspace"); registerBuiltin("logspace");
                registerBuiltin("tensor_median"); registerBuiltin("tensor_cummax"); registerBuiltin("tensor_cummin");
                registerBuiltin("tensor_flip"); registerBuiltin("tensor_roll"); registerBuiltin("tensor_unique");
                registerBuiltin("tensor_abs"); registerBuiltin("tensor_pow"); registerBuiltin("tensor_sqrt");
                registerBuiltin("tensor_matmul"); registerBuiltin("matmul");
                registerBuiltin("mel_filterbank"); registerBuiltin("mfcc");
                registerBuiltin("stft_magnitude"); registerBuiltin("ctc_loss");
                registerBuiltin("softplus"); registerBuiltin("mish");
                registerBuiltin("mse_loss"); registerBuiltin("cross_entropy_loss");
                registerBuiltin("numerical_gradient");
                registerBuiltin("tensor_clip"); registerBuiltin("tensor_clamp");
                registerBuiltin("tensor_argmax"); registerBuiltin("argmax");
                registerBuiltin("tensor_argmin"); registerBuiltin("argmin");
                registerBuiltin("tensor_norm"); registerBuiltin("norm");
                registerBuiltin("tensor_normalize");
                registerBuiltin("tensor_slice"); registerBuiltin("tensor_reshape");
                registerBuiltin("one_hot"); registerBuiltin("binary_cross_entropy");
                registerBuiltin("accuracy");
                registerBuiltin("conv1d"); registerBuiltin("max_pool1d"); registerBuiltin("avg_pool1d");
                registerBuiltin("dropout"); registerBuiltin("embedding"); registerBuiltin("embedding_lookup");
                registerBuiltin("cosine_similarity"); registerBuiltin("cos_sim");
                registerBuiltin("attention"); registerBuiltin("scaled_dot_attention");
                registerBuiltin("batch_norm"); registerBuiltin("batchnorm");
                registerBuiltin("layer_norm"); registerBuiltin("layernorm");
                registerBuiltin("gelu"); registerBuiltin("elu"); registerBuiltin("swish"); registerBuiltin("silu");
                registerBuiltin("tensor_where"); registerBuiltin("huber_loss");
                registerBuiltin("tensor_var"); registerBuiltin("tensor_std"); registerBuiltin("tensor_cumsum");
                registerBuiltin("gelu"); registerBuiltin("swish"); registerBuiltin("silu");
                registerBuiltin("elu"); registerBuiltin("tensor_where");
                registerBuiltin("tensor_cumsum"); registerBuiltin("tensor_diff");
                registerBuiltin("tensor_var"); registerBuiltin("tensor_std");
                registerBuiltin("huber_loss");
                registerBuiltin("tensor_var"); registerBuiltin("tensor_variance");
                registerBuiltin("tensor_std"); registerBuiltin("tensor_where");
                registerBuiltin("tensor_stack"); registerBuiltin("elu");
                registerBuiltin("gelu"); registerBuiltin("silu"); registerBuiltin("swish");
                registerBuiltin("layer_norm"); registerBuiltin("tensor_cumsum");
                registerBuiltin("tensor_diff"); registerBuiltin("tensor_outer");
                registerBuiltin("huber_loss");
                registerBuiltin("tensor_var"); registerBuiltin("variance");
                registerBuiltin("tensor_std"); registerBuiltin("std_dev");
                registerBuiltin("tensor_where"); registerBuiltin("where");
                registerBuiltin("tensor_stack"); registerBuiltin("tensor_split");
                registerBuiltin("huber_loss");
                registerBuiltin("multi_head_attention");
                registerBuiltin("gelu"); registerBuiltin("silu"); registerBuiltin("swish");
                registerBuiltin("elu"); registerBuiltin("layer_norm");
                registerBuiltin("matrix"); registerBuiltin("mat"); registerBuiltin("mat_mul");
                registerBuiltin("mat_transpose"); registerBuiltin("mat_get"); registerBuiltin("mat_shape");
                registerBuiltin("zeros"); registerBuiltin("ones"); registerBuiltin("random_tensor");
                registerBuiltin("softmax"); registerBuiltin("tensor_softmax"); registerBuiltin("kb_save"); registerBuiltin("kb_load");
                return NONE_VALUE;
        }
        if (module_name == "sys" && sys_ns_.type != ValueType::UNDEFINED) {
                // one sys module: a stream replaced through one import
                // (contextlib.redirect_stdout) is the stream of every other
                imported_modules_.erase(module_name);
                if (from_import) bindFromNamespace(sys_ns_, in_node->names, "sys", ctx);
                else ctx->defineByName(in_node->alias.empty() ? std::string("sys") : in_node->alias, sys_ns_);
                // argv and platform bare, as every import of sys binds them
                if (auto* sc = dynamic_cast<Container*>(sys_ns_.value.gc); sc && sc->container) {
                    auto a = sc->container->find("argv");
                    if (a != sc->container->end()) ctx->defineByName("argv", a->second);
                    auto pl = sc->container->find("platform");
                    if (pl != sc->container->end()) ctx->defineByName("platform", pl->second);
                }
                return NONE_VALUE;
        }
        if (module_name == "sys") {
                // `sys` is a namespace: sys.argv (the script path, then the
                // arguments after it on the command line), sys.platform,
                // sys.executable, sys.version. argv and platform are also
                // bound bare, as they always were - but argv is now the real
                // list, not the string "nython", and platform is the real OS.
                std::vector<std::string> av = nyrt::argv();
                Value argv_list = nyos_list_of(av);
                std::string plat;
#if defined(_WIN32)
                plat = "win32";
#elif defined(__APPLE__)
                plat = "darwin";
#else
                plat = "linux";
#endif
                auto* ns = new Object((Runnable*)runner, "sys", Type::MAP);   // round 80: "sys", not the alias
                noteNamespace(ns);
                ns->set("__name__", makeStringValue("sys"));
                ns->set("argv", argv_list);
                ns->set("platform", makeStringValue(plat));
                ns->set("executable", makeStringValue(nyrt::executable_path()));
                ns->set("version", makeStringValue(NYTHON_VERSION));
                // Python's: 2**31 - 1 on a 32-bit build, 2**63 - 1 on a 64-bit one.
                ns->set("maxsize", intValue((int64_t)PTRDIFF_MAX));
                {   // the machine's byte order (struct, array, int.to_bytes callers)
                    const uint16_t probe = 1;
                    ns->set("byteorder", makeStringValue(*(const uint8_t*)&probe ? "little" : "big"));
                }
                ns->set("exit", global_ctx->getByName("exit"));
                // sys.exc_info() / sys.exception() / sys._getframe() (round 77, the prelude's)
                ns->set("exc_info", global_ctx->getByName("_ny_exc_info"));
                ns->set("exception", global_ctx->getByName("_ny_exc_current"));
                ns->set("_getframe", global_ctx->getByName("_ny_getframe"));
                // sys.settrace / setprofile and breakpoint()'s hook (round 79)
                // (builtins named "sys.settrace" ...: their __name__ is
                // "settrace", as a profile function's c_call sees it)
                ns->set("settrace", builtinValue("sys.settrace"));
                ns->set("gettrace", builtinValue("sys.gettrace"));
                ns->set("setprofile", builtinValue("sys.setprofile"));
                ns->set("getprofile", builtinValue("sys.getprofile"));
                ns->set("breakpointhook", global_ctx->getByName("_ny_breakpointhook"));
                ns->set("__breakpointhook__", global_ctx->getByName("_ny_breakpointhook"));
                ns->set("warnoptions", nyos_list_of(nyrt::warn_options()));
                // the standard streams (NyPrelude _NyStdStream, round 77)
                for (const char* st : {"stdin", "stdout", "stderr"}) {
                    Value sv = global_ctx->getByName(std::string("_ny_") + st);
                    ns->set(st, sv);
                    ns->set(std::string("__") + st + "__", sv);
                }
                sys_ns_ = Value((Collectable*)ns);
                {   // round 80: sys's Python-level members (the prelude's)
                    Value ext = global_ctx->getByName("_ny_sys_extend");
                    if (ext.type == ValueType::USERDATA && ext.value.p) {
                        std::vector<Value> a{sys_ns_};
                        callFunctionValue(ext, a, global_ctx);
                    }
                }
                if (from_import) bindFromNamespace(sys_ns_, in_node->names, "sys", ctx);
                else ctx->defineByName(in_node->alias.empty() ? "sys" : in_node->alias, sys_ns_);
                ctx->defineByName("argv", argv_list);
                ctx->defineByName("platform", makeStringValue(plat));
                imported_modules_.erase(module_name);   // `import sys as s` after `import sys`
                return NONE_VALUE;
        }
        if (module_name == "json") {
                registerBuiltin("json_encode");
                registerBuiltin("json_decode");
                registerBuiltin("json_parse");
                registerBuiltin("json_stringify");
                return NONE_VALUE;
        }
        if (module_name == "time" || module_name == "datetime") {
                registerBuiltin("time_now");
                registerBuiltin("time_clock");
                registerBuiltin("time_sleep");
                registerBuiltin("time_format");
                registerBuiltin("time_timestamp");
                registerBuiltin("time_date");
                registerBuiltin("time_elapsed");
                return NONE_VALUE;
        }
        if (module_name == "random") {
                registerBuiltin("random_int");
                registerBuiltin("random_float");
                registerBuiltin("random_choice");
                registerBuiltin("random_shuffle");
                registerBuiltin("random_seed");
                registerBuiltin("random_range");
                registerBuiltin("random_sample");
                registerBuiltin("randint");
                registerBuiltin("uniform");
                return NONE_VALUE;
        }
        if (module_name == "os" || module_name == "sys") {
                registerBuiltin("os_getenv");
                registerBuiltin("os_setenv");
                registerBuiltin("os_getcwd");
                registerBuiltin("getcwd");
                registerBuiltin("getenv");
                registerBuiltin("system");
                registerBuiltin("shell");
                registerBuiltin("popen");
                registerBuiltin("exec_cmd");
                registerBuiltin("sh");
                registerBuiltin("listdir");
                registerBuiltin("ls");
                registerBuiltin("mkdir");
                registerBuiltin("chdir");
                registerBuiltin("cd");
                registerBuiltin("path_exists");
                registerBuiltin("path_isdir");
                registerBuiltin("path_isfile");
                registerBuiltin("os_listdir");
                registerBuiltin("os_mkdir");
                registerBuiltin("os_remove");
                registerBuiltin("os_rename");
                registerBuiltin("os_exists");
                registerBuiltin("os_isdir");
                registerBuiltin("os_isfile");
                registerBuiltin("os_exec");
                registerBuiltin("os_path_join");
                registerBuiltin("os_path_basename");
                registerBuiltin("os_path_dirname");
                registerBuiltin("os_path_ext");
                registerBuiltin("os_path_abs");
                if (module_name == "os") {
                    // `from os import path as p, sep` binds the names asked
                    // for (round 77: only `import os` bound anything)
                    if (from_import) bindFromNamespace(makeOsNamespace(), in_node->names, "os", ctx);
                    else ctx->defineByName(in_node->alias.empty() ? "os" : in_node->alias, makeOsNamespace());
                    imported_modules_.erase(module_name);
                }
                return NONE_VALUE;
        }
        if (module_name == "regex" || module_name == "re") {
                registerBuiltin("re_match");
                registerBuiltin("re_search");
                registerBuiltin("re_findall");
                registerBuiltin("re_replace");
                registerBuiltin("re_split");
                registerBuiltin("re_test");
                registerBuiltin("regex_match");
                registerBuiltin("regex_replace");
                registerBuiltin("regex_findall");
                registerBuiltin("regex_split");
                registerBuiltin("regex_search");
                registerBuiltin("re_sub");
                return NONE_VALUE;
        }
        if (module_name == "threading" || module_name == "thread") {
                registerBuiltin("thread_create");
                registerBuiltin("thread_sleep");
                registerBuiltin("mutex_create");
                registerBuiltin("mutex_lock");
                registerBuiltin("mutex_unlock");
                registerBuiltin("sleep");
                registerBuiltin("semaphore_create");
                registerBuiltin("semaphore_acquire");
                registerBuiltin("semaphore_release");
                registerBuiltin("atomic_inc");
                registerBuiltin("atomic_dec");
                registerBuiltin("atomic_get");
                // `import threading` also binds Python's threading module
                // (lib/threading.ny, round 77).
                if (module_name == "threading" && !quoted) {
                    std::string p = findModulePath(node, "threading");
                    if (!p.empty()) {
                        Value nsv = module_ns_.count("threading") ? module_ns_["threading"] : runModuleFile(p, "threading");
                        if (!in_node->names.empty()) bindFromNamespace(nsv, in_node->names, "threading", ctx);
                        else ctx->defineByName(!in_node->alias.empty() ? in_node->alias : "threading", nsv);
                    }
                }
                return NONE_VALUE;
        }
        if (module_name == "net" || module_name == "http") {
                registerBuiltin("http_get");
                registerBuiltin("http_post");
                registerBuiltin("url_encode");
                registerBuiltin("url_decode");
                registerBuiltin("socket_create");
                registerBuiltin("socket_connect");
                registerBuiltin("socket_send");
                registerBuiltin("socket_recv");
                registerBuiltin("socket_udp"); registerBuiltin("socket_tcp");
                registerBuiltin("socket_sendto"); registerBuiltin("socket_recvfrom");
                registerBuiltin("socket_shutdown"); registerBuiltin("socket_setsockopt");
                registerBuiltin("socket_getpeername"); registerBuiltin("socket_getsockname");
                registerBuiltin("socket_select");
                registerBuiltin("gethostbyname"); registerBuiltin("dns_resolve");
                registerBuiltin("inet_ntoa"); registerBuiltin("inet_aton");
                registerBuiltin("ip_to_string"); registerBuiltin("string_to_ip");
                registerBuiltin("htons"); registerBuiltin("ntohs");
                registerBuiltin("htonl"); registerBuiltin("ntohl");
                registerBuiltin("http_request");
                registerBuiltin("socket_close");
                registerBuiltin("socket_bind");
                registerBuiltin("socket_listen");
                registerBuiltin("socket_accept");
                return NONE_VALUE;
        }
        if (module_name == "crypto" || module_name == "hash") {
                registerBuiltin("hash_sha256");
                registerBuiltin("hash_md5");
                registerBuiltin("base64_encode");
                registerBuiltin("base64_decode");
                registerBuiltin("hex_encode");
                registerBuiltin("hex_decode");
                registerBuiltin("url_encode");
                registerBuiltin("url_decode");
                registerBuiltin("md5");
                registerBuiltin("sha256");
                registerBuiltin("sha512");
                return NONE_VALUE;
        }
        // `collections` is lib/collections.ny (round 77): real deque,
        // Counter, defaultdict, OrderedDict, namedtuple, ChainMap. The bare
        // Counter/deque/... builtins stay for programs that never import it.
        if (module_name == "math") {
            // The math module: a namespace object, as `import os` makes
            // (it was a plain dict, so dir(math) listed dict methods).
            auto* math_ns = new Object((Runnable*)runner, "math", Type::MAP);
            noteNamespace(math_ns);
            Value math_obj((Collectable*)math_ns);
            if (!math_obj.isCollectable() || !math_obj.value.gc) {
                // Fallback: just register as globals and return none
                ctx->defineByName("PI", Value(3.14159265358979323846));
                ctx->defineByName("E", Value(2.71828182845904523536));
                ctx->defineByName("TAU", Value(6.28318530717958647692));
                registerBuiltin("sqrt"); registerBuiltin("sin"); registerBuiltin("cos");
                registerBuiltin("tan"); registerBuiltin("log"); registerBuiltin("floor"); registerBuiltin("ceil");
                return NONE_VALUE;
            }
            auto* cont = dynamic_cast<Container*>(math_obj.value.gc);
            if (cont && cont->container) {
                (*cont->container)["pi"] = Value(3.14159265358979323846);
                (*cont->container)["e"] = Value(2.71828182845904523536);
                (*cont->container)["tau"] = Value(6.28318530717958647692);
                (*cont->container)["inf"] = Value(std::numeric_limits<double>::infinity());
                (*cont->container)["nan"] = Value(std::numeric_limits<double>::quiet_NaN());
                // The members are builtins/pymath.cpp's math_* functions,
                // the same ones the VM's namespace holds (round 77).
                for (auto& full : pymath_builtin_names()) {
                    registerBuiltin(full);
                    Value bv = global_ctx->getByName(full);
                    if (bv.type == ValueType::USERDATA && bv.value.p)
                        (*cont->container)[full.substr(5)] = bv;
                }
                // The bare names, as before (sqrt(x) without math.)
                for (auto& fn : {"sqrt","sin","cos","tan","log","floor","ceil","abs","pow","exp","asin","acos","atan","atan2"})
                    registerBuiltin(fn);
            }
            // Cached like a .ny module's namespace, so `import math` (or
            // `from math import gcd`) in a module run after the program
            // imported math binds it there too: the circular-import guard
            // above returned without binding anything (NameError: math in
            // lib/fractions.ny when the program had imported math first).
            noteModule("math", math_obj);   // round 80: sys.modules too
            if (!in_node->names.empty()) bindFromNamespace(math_obj, in_node->names, "math", ctx);
            else ctx->defineByName(in_node->alias.empty() ? "math" : in_node->alias, math_obj);
            // a second `import math` in another module's scope binds it there too
            imported_modules_.erase(module_name);
            // Also define pi/e as globals for convenience (round 80: in the
            // program's own scope only - exec("import math as m", ns) put
            // them in ns)
            if (ctx == global_ctx) {
                ctx->defineByName("PI", Value(3.14159265358979323846));
                ctx->defineByName("E", Value(2.71828182845904523536));
            }
            return math_obj;
        }


        // ── lib/ module shortcuts ──────────────────────────────────────────────
        if (module_name == "stdlib") {
            std::string p = locateModuleFile(node, "lib/stdlib.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "os_lib" || module_name == "oslib") {
            std::string p = locateModuleFile(node, "lib/os.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "network_lib" || module_name == "netlib") {
            std::string p = locateModuleFile(node, "lib/network.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "sockets") {
            std::string p = locateModuleFile(node, "lib/sockets.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "webserver" || module_name == "httpserver") {
            std::string p = locateModuleFile(node, "lib/webserver.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "threads" || module_name == "threading_lib") {
            std::string p = locateModuleFile(node, "lib/thread.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "clientserver" || module_name == "cs_lib") {
            std::string p = locateModuleFile(node, "lib/clientserver.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "gui") {
            std::string p = locateModuleFile(node, "lib/gui.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }
        if (module_name == "aiagent" || module_name == "nyxai" || module_name == "nyx") {
            std::string p = locateModuleFile(node, "lib/aiagent.ny");
            struct stat st; if (stat(p.c_str(),&st)==0){
                auto src=SourceCode(p); auto rep=std::make_shared<Reporter>(src);
                auto lx=std::make_shared<Lexer>(src); lx->tokenize();
                auto pr=std::make_shared<Parser>(rep.get(),(Runnable*)runner,lx.get());
                auto ast=pr->parse(); if(ast){imported_asts.push_back(ast);evalNode(ast,ctx);}
            } return NONE_VALUE;
        }

                // Search filesystem for module file
        // The importing script's own directory comes FIRST. `import "mylib"`
        // from examples/foo.ny must find examples/mylib.ny sitting beside it;
        // previously every candidate was relative to the working directory, so
        // running the same file from a different cwd changed whether its
        // imports resolved.
        //
        // (Round 53 added this to a list named `paths` further up that is built
        // and never read — the resolver has always used `search_paths`. The fix
        // was real but landed in dead code, which is why it changed nothing.)
        std::vector<std::string> search_paths;
        {
            std::string here = importerDir(node);
            // not beside a module of a package, for a name without quotes
            // (see moduleDirs, round 77)
            struct stat pst;
            if (!here.empty() && !quoted && (stat((here + "__init__.ny").c_str(), &pst) == 0
                                             || stat((here + "__init__.py").c_str(), &pst) == 0)) here.clear();
            if (!here.empty()) {
                search_paths.push_back(here + module_name + ".ny");
                search_paths.push_back(here + module_name);
                search_paths.push_back(here + "lib/" + module_name + ".ny");
            }
        }
        // round 80: sys.path's entries (sys.path.insert(0, d)) for `import name`
        if (!quoted) for (auto& d : sysPathDirs()) search_paths.push_back(d + module_name + ".ny");
        search_paths.push_back(module_name + ".ny");
        search_paths.push_back(module_name);
        search_paths.push_back("./" + module_name + ".ny");
        search_paths.push_back("./lib/" + module_name + ".ny");
        search_paths.push_back("lib/" + module_name + ".ny");
        search_paths.push_back("lib/" + module_name + "/" + module_name + ".ny");
        for (auto& c : ancestorCandidates(node, module_name + ".ny")) search_paths.push_back(c);
        for (auto& c : ancestorCandidates(node, module_name)) search_paths.push_back(c);
        for (auto& d : nyrt::library_dirs()) search_paths.push_back(d + module_name + ".ny");
        if (quoted) for (auto& c : nyrt::quoted_import_candidates(module_name)) search_paths.push_back(c);   // round 82
        // round 81: `builtins` is the builtin module whatever sits beside
        // the script (CPython's BuiltinImporter comes first)
        if (!quoted && module_name == "builtins") {
            search_paths.clear();
            for (auto& d : nyrt::library_dirs()) search_paths.push_back(d + module_name + ".ny");
        }

        std::string filepath;
        for (auto& p : search_paths) {
            struct stat buf;
            if (stat(p.c_str(), &buf) == 0) { filepath = p; break; }
        }
        // round 82: `import name` finds name.py when there is no name.ny
        if (filepath.empty() && !quoted && module_name != "builtins") filepath = findModulePath(node, module_name);
        // A module that cannot be found used to import silently, so every name
        // it would have defined then failed later with no hint that the import
        // was the cause. Name the module and where it was looked for.
        if (filepath.empty()) {
            std::string tried;
            for (size_t i = 0; i < search_paths.size(); ++i) {
                if (i) tried += ", ";
                tried += search_paths[i];
            }
            // `import name`: Python's ModuleNotFoundError (round 80); a quoted
            // import keeps the paths it tried
            if (!quoted) throw std::string("__exc__:ModuleNotFoundError:No module named '" + module_name + "'");
            throw std::string("__exc__:ImportError:cannot find module \"" + module_name
                              + "\" (looked in: " + tried + ")");
        }

        // A module named without quotes runs in a scope of its own.
        if (!quoted) {
            try {
                return importModule(filepath, module_name, in_node.get(),
                                    !in_node->alias.empty() ? in_node->alias : implicit_alias, ctx);
            } catch (std::exception& e) {
                std::cerr << "[Nython] Failed to import \"" << filepath << "\": " << e.what() << "\n";
                throw std::string("__exc__:ImportError:cannot import \"" + filepath + "\": " + e.what());
            }
        }

        // Read and execute the file
        try {
            auto source = SourceCode(filepath);
            auto reporter = std::make_shared<Reporter>(source);
            auto lex = std::make_shared<Lexer>(source);
            lex->tokenize();
            auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)runner, lex.get());
            auto ast = parser->parse();
            if (ast) {
                imported_asts.push_back(ast); // keep AST alive

                // `import "x" as m` must bind the module's names under `m`.
                // The parser has always recorded the alias in ImportNode::alias
                // and nothing ever read it, so the alias bound nothing and
                // `m.greet()` returned none with no diagnostic.
                //
                // Names are collected by diffing the scope across the module's
                // execution, so a module needs no cooperation to be aliasable.
                // Context inherits Container, whose access_container() gives the
                // iteration this needs.
                const std::string bind_as = !in_node->alias.empty() ? in_node->alias : implicit_alias;
                const bool aliased = !bind_as.empty() && ctx;

                // Collect the module's OWN top-level names from its AST rather
                // than by diffing scope before and after.
                //
                // The diff approach fails whenever the module has already been
                // loaded — `import "m"` then `import "m" as x` leaves nothing
                // new in scope, so the namespace came out empty. Reading the
                // module's declarations directly is independent of what is
                // already defined, so the alias is complete no matter how many
                // times the module has been imported.
                std::set<std::string> own;
                if (aliased) collectTopLevelNames(ast, own);

                // While the module's top level runs, __name__ is the module's
                // name and __file__ its path, so `if __name__ == "__main__":`
                // in a module does not run on import.
                struct NameScope {
                    Context* c; Value name, file;
                    NameScope(Context* cx, Value n, Value f, Value nn, Value nf) : c(cx), name(n), file(f) {
                        c->defineByName("__name__", nn); c->defineByName("__file__", nf);
                    }
                    ~NameScope() { c->defineByName("__name__", name); c->defineByName("__file__", file); }
                };
                std::string stem = filepath;
                {
                    size_t cut = stem.find_last_of("/\\");
                    if (cut != std::string::npos) stem = stem.substr(cut + 1);
                    if (stem.size() > 3 && (stem.compare(stem.size() - 3, 3, ".ny") == 0 || stem.compare(stem.size() - 3, 3, ".py") == 0)) stem = stem.substr(0, stem.size() - 3);
                }
                Value prev_name = ctx->getByName("__name__"), prev_file = ctx->getByName("__file__");
                NameScope name_scope(ctx, prev_name, prev_file, makeStringValue(stem), makeStringValue(filepath));

                evalNode(ast, ctx);

                if (aliased) {
                    // Modules share the importer's globals here, so binding the
                    // namespace under a name the module itself defines (socket's
                    // class socket, glob's def glob) would take that name from
                    // the module's own code. Then the module's names become
                    // attributes of its same-named class or function instead:
                    // socket.socket(), socket.AF_INET and a call to socket()
                    // inside the module all work (round 77).
                    Value same = own.count(bind_as) ? ctx->getByName(bind_as) : UNDEFINED_VALUE;
                    bool merge = same.type == ValueType::USERDATA && same.value.p && func_names.count(same.value.p)
                                 && !instance_to_class.count(same.value.p);
                    if (merge) {
                        for (const auto& n : own) {
                            if (n == bind_as) continue;
                            Value v = ctx->getByName(n);
                            if (v.type != ValueType::UNDEFINED) setAttr(same, n, v);
                        }
                        setAttr(same, bind_as, same);
                        module_ns_[module_name] = same;
                        ctx->defineByName(bind_as, same);
                    } else {
                        auto* ns = new Object((Runnable*)runner, bind_as, Type::MAP);
                        noteNamespace(ns);
                        for (const auto& n : own) {
                            Value v = ctx->getByName(n);
                            if (v.type != ValueType::UNDEFINED) ns->set(n, v);
                        }
                        Value nsv((Collectable*)ns);
                        module_ns_[module_name] = nsv;
                        ctx->defineByName(bind_as, nsv);
                    }
                }
            }
        } catch (nython::node::ReturnSignal&) {
            // A bare `return` at module scope is harmless; ignore it.
        } catch (std::string& e) {
            // A thrown Nython exception inside the module: propagate, otherwise
            // the module half-executes and the caller never learns why.
            throw;
        } catch (std::exception& e) {
            // This used to be `catch (...) {}`. A module with a SYNTAX ERROR
            // therefore imported "successfully" and silently: every class in it
            // constructed to none and every method returned none, with no
            // diagnostic anywhere. The failure looked like a broken class rather
            // than a broken file. Report the file and the reason.
            std::cerr << "[Nython] Failed to import \"" << filepath << "\": "
                      << e.what() << "\n";
            throw std::string("__exc__:ImportError:cannot import \"" + filepath
                              + "\": " + e.what());
        }

        return NONE_VALUE;
    }

        Value evalEnum(const node_ptr& node, Context* ctx) {
        auto en = static_pointer_cast<EnumNode>(node);
        // Create enum as Object with only named members (no numeric keys)
        auto* obj = new Object((Runnable*)runner, en->name, Type::MAP);
        int counter = 0;
        for (auto& item : en->items) {
            auto ei = static_pointer_cast<EnumItemNode>(item);
            Value val = ei->value_node ? evalNode(ei->value_node, ctx) : Value(counter);
            (*obj->container)[ei->name] = val;
            counter++;
        }
        // Store enum name for type() and printing
        (*obj->container)["__name__"] = makeStringValue(en->name);
        (*obj->container)["__type__"] = makeStringValue("enum");
        Value enum_val((Collectable*)obj);
        ctx->defineByName(en->name, enum_val);
        return enum_val;
    }

    Value evalDelete(const node_ptr& node, Context* ctx) {
        auto dn = static_pointer_cast<DeleteNode>(node);
        if (dn->target->type() == NodeType::VARIABLE) {
            // del x unbinds the nearest x: reading it afterwards is a
            // NameError (x used to stay bound, to undefined here and to
            // none on the VM).
            const std::string n = dn->target->value();
            for (Context* c = ctx; c; c = c->parent)
                if (c->container && c->container->erase(n)) return NONE_VALUE;
            pyRaise("NameError", "name '" + n + "' is not defined");
        } else if (dn->target->type() == NodeType::SUBSCRIPT) {
            // del dict[key] or del list[idx]
            auto sub = static_pointer_cast<SubscriptNode>(dn->target);
            Value obj = evalNode(sub->object, ctx);
            Value idx = evalNode(sub->index, ctx);
            if (isInstanceValue(obj) && instanceHasMethod(obj, "__delitem__")) {
                std::vector<Value> a{idx};
                callMethod(obj, "__delitem__", a, ctx);
                return NONE_VALUE;
            }
            {
                std::vector<Value> parts;
                if (sliceObjectParts(idx, parts)) { delSlice(obj, parts, ctx); return NONE_VALUE; }
            }
            if (auto* bo = bytesOf(obj)) {
                if (!bo->mut) pyRaise("TypeError", "'bytes' object doesn't support item deletion");
                Num k;
                if (!asNum(idx, k) || k.k == 3) pyRaise("TypeError", "bytearray indices must be integers or slices, not " + typeNameOf(idx));
                int64_t n = (int64_t)bo->s.size(), i = k.k == 1 ? k.i : INT64_MAX;
                if (i < 0) i += n;
                if (i < 0 || i >= n) pyRaise("IndexError", "bytearray index out of range");
                bo->s.erase((size_t)i, 1);
                return NONE_VALUE;
            }
            if (Container* cont = contOf(obj)) {
                int64_t n = seqLen(cont);
                if (n < 0) {
                    // del d[k]: a missing key is a KeyError, as in Python
                    if (cont->container->erase(dictKey(idx)) == 0) raiseKeyError(idx);   // round 77
                } else {
                    if (isTupleCont(cont)) pyRaise("TypeError", "'tuple' object doesn't support item deletion");
                    Num k;
                    if (!asNum(idx, k) || k.k == 3) pyRaise("TypeError", "list indices must be integers or slices, not " + typeNameOf(idx));
                    int64_t i = k.k == 1 ? k.i : INT64_MAX;
                    if (i < 0) i += n;
                    if (i < 0 || i >= n) pyRaise("IndexError", "list assignment index out of range");
                    std::vector<Value> items = seqItems(cont);
                    for (int64_t j = i; j + 1 < n; j++) (*cont->container)[std::to_string(j)] = items[(size_t)j + 1];
                    cont->container->erase(std::to_string(n - 1));
                    (*cont->container)["__len__"] = intValue(n - 1);
                }
            }
        } else if (dn->target->type() == NodeType::CALL) {
            // del L[a:b:c]: the parser spells the slice L.slice(a, b, c)
            auto cn = static_pointer_cast<CallNode>(dn->target);
            if (cn->callee && cn->callee->type() == NodeType::ATTRIBUTE
                && static_pointer_cast<AttributeNode>(cn->callee)->attr == "slice") {
                Value obj = evalNode(static_pointer_cast<AttributeNode>(cn->callee)->object, ctx);
                std::vector<Value> sargs;
                for (auto& a : cn->args) sargs.push_back(evalNode(a, ctx));
                delSlice(obj, sargs, ctx);
            }
        } else if (dn->target->type() == NodeType::ATTRIBUTE) {
            // del obj.attr
            auto attr = static_pointer_cast<AttributeNode>(dn->target);
            Value obj = evalNode(attr->object, ctx);
            delAttrValue(obj, attr->attr);
        }
        return NONE_VALUE;
    }
    // del obj[a:b:c] (the parser spells the slice obj.slice(a, b, c)), and
    // del obj[slice_object]
    void delSlice(const Value& obj, std::vector<Value>& sargs, Context* ctx) {
        if (wantsSliceObject(obj, "__delitem__")) {
            std::vector<Value> a{makeSliceObject(sargs, ctx)};
            callMethod(obj, "__delitem__", a, ctx);
            return;
        }
        if (auto* bo = bytesOf(obj)) {
            if (!bo->mut) pyRaise("TypeError", "'bytes' object doesn't support item deletion");
            int64_t len = (int64_t)bo->s.size(), st = 0, en = 0, step = 1;
            bool hs = sliceArg(sargs, 0, st), he = sliceArg(sargs, 1, en);
            if (sargs.size() >= 3 && sargs[2].type != ValueType::NONE) sliceArg(sargs, 2, step);
            int64_t cnt = nyCall([&] { return nypy::slice_adjust(len, hs, st, he, en, step); });
            if (cnt > 0) {
                std::vector<bool> gone((size_t)len, false);
                for (int64_t k = 0, i = st; k < cnt; k++, i += step) gone[(size_t)i] = true;
                std::string kept;
                for (int64_t k = 0; k < len; k++) if (!gone[(size_t)k]) kept += bo->s[(size_t)k];
                bo->s = std::move(kept);
            }
            return;
        }
        Container* cont = contOf(obj);
        if (!cont || seqLen(cont) < 0) pyRaise("TypeError", "'" + typeNameOf(obj) + "' object does not support item deletion");
        if (isTupleCont(cont)) pyRaise("TypeError", "'tuple' object doesn't support item deletion");
        std::vector<Value> items = seqItems(cont);
        int64_t len = (int64_t)items.size(), st = 0, en = 0, step = 1;
        bool hs = sliceArg(sargs, 0, st), he = sliceArg(sargs, 1, en);
        if (sargs.size() >= 3 && sargs[2].type != ValueType::NONE) sliceArg(sargs, 2, step);
        int64_t cnt = nyCall([&] { return nypy::slice_adjust(len, hs, st, he, en, step); });
        if (cnt > 0) {
            std::vector<bool> gone((size_t)len, false);
            for (int64_t k = 0, i = st; k < cnt; k++, i += step) gone[(size_t)i] = true;
            for (int64_t k = 0; k < len; k++) cont->container->erase(std::to_string(k));
            int64_t w = 0;
            for (int64_t k = 0; k < len; k++) if (!gone[(size_t)k]) (*cont->container)[std::to_string(w++)] = items[(size_t)k];
            (*cont->container)["__len__"] = intValue(w);
        }
    }
    // del obj.name / delattr(obj, name): an instance's field, a class
    // attribute or a namespace/dict entry is removed; anything else is an
    // AttributeError. (A deleted field used to stay, holding undefined.)
    void delAttrValue(const Value& obj, const std::string& name) {
        if (name == "__class__" && isInstanceValue(obj)) pyRaise("TypeError", "can't delete __class__ attribute");   // round 79
        if (isInstanceValue(obj) && instanceAttrHook(obj, 1)) {
            std::vector<Value> a{makeStringValue(name)};
            Value o = obj;
            callMethod(o, "__delattr__", a, global_ctx);
            return;
        }
        if (any_data_descr_) {
            Value d;
            if (dataDescriptor(obj, name, "__delete__", d)) {
                std::vector<Value> a{obj};
                callMethod(d, "__delete__", a, global_ctx);
                return;
            }
        }
        if (!class_meta_.empty() && metaAttrHook(obj, "__delattr__", {makeStringValue(name)})) return;
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto pit = instance_properties.find(obj.value.p);
            if (pit != instance_properties.end() && pit->second && pit->second->container) {
                if (pit->second->container->erase(name)) return;
            } else if (fnTag(func_names, obj.value.p).rfind("__class__:", 0) == 0) {
                auto cit = class_ctx_map_.find(obj.value.p);
                auto ast_it = func_ast_nodes.find(obj.value.p);
                if (cit == class_ctx_map_.end() && ast_it != func_ast_nodes.end()) cit = class_ctx_map_.find(ast_it->second);
                if (cit != class_ctx_map_.end() && cit->second && cit->second->container && cit->second->container->erase(name)) {
                    if (auto* cn = dynamic_cast<ClassNode*>((Node*)(ast_it != func_ast_nodes.end() ? ast_it->second : obj.value.p))) {
                        class_vars_.erase(cn->name + "." + name);
                        specInvalidate();   // round 81
                        // not read again from the class body (round 77)
                        class_vars_deleted_.insert(cn->name + "." + name);
                    }
                    // round 81: a removed attribute hook is no longer called
                    if (name == "__setattr__") attr_hook_cache_[0].clear();
                    else if (name == "__delattr__") attr_hook_cache_[1].clear();
                    else if (name == "__getattribute__") attr_hook_cache_[2].clear();
                    else if (name == "__new__") no_new_.clear();
                    return;
                }
            }
        } else if (Container* cont = contOf(obj)) {
            if (seqLen(cont) < 0 && cont->container->erase(name)) return;
        }
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto fa = func_attrs_.find(obj.value.p);
            if (fa != func_attrs_.end() && fa->second.erase(name)) return;
        }
        throw std::string("__exc__:AttributeError:" + attributeErrorText(obj, name));
    }


    // ── evalMacroCall ─────────────────────────────────────────────────────────
    // Invokes a user-registered Nython macro handler with collected token args.
    Value evalMacroCall(const node_ptr& node, Context* ctx) {
        auto* mn = static_cast<MacroCallNode*>(node.get());
        auto& reg = nython::DynamicLangRegistry::instance();

        // Look up the MACRO rule for this name
        const nython::DynamicRule* rule = reg.macro_rule_for(mn->macro_name);
        if (!rule || !rule->handler_value) return NONE_VALUE;

        // handler_value points to a heap-allocated Value (the Nython function)
        Value* hv = static_cast<Value*>(rule->handler_value);

        // Build argument list: each token string becomes a Nython string Value
        std::vector<Value> call_args;
        for (auto& s : mn->argv) {
            // Strip __dyntok: prefixes if any
            std::string raw = nython::is_dyntok_value(s) ? nython::decode_dyntok_name(s) : s;
            call_args.push_back(makeStringValue(raw));
        }

        return callFunctionValue(*hv, call_args, ctx);
    }

    // ── evalDynBinop ──────────────────────────────────────────────────────────
    // Evaluates lhs and rhs, then calls the registered handler(lhs, rhs).
    Value evalDynBinop(const node_ptr& node, Context* ctx) {
        auto* dn = static_cast<DynBinopNode*>(node.get());
        auto& reg = nython::DynamicLangRegistry::instance();

        Value lhs = evalNode(dn->lhs, ctx);
        Value rhs = evalNode(dn->rhs, ctx);

        // Look up INFIX_OP rule (for dynamic keyword operators)
        const nython::DynamicRule* rule = reg.infix_rule_for(dn->op_symbol);
        if (rule && rule->handler_value) {
            Value* hv = static_cast<Value*>(rule->handler_value);
            std::vector<Value> binop_args1 = {lhs, rhs};
            return callFunctionValue(*hv, binop_args1, ctx);
        }

        // Look up dynamic symbol operator
        nython::DynamicOperator* dop = reg.find_operator(dn->op_symbol);
        if (dop && dop->handler_value) {
            Value* hv = static_cast<Value*>(dop->handler_value);
            std::vector<Value> binop_args2 = {lhs, rhs};
            return callFunctionValue(*hv, binop_args2, ctx);
        }

        return NONE_VALUE;
    }

    // ── Classes: method resolution order ────────────────────────────────
    // C3 linearisation over the declared bases (resolved by class name),
    // the order Python uses; a hierarchy C3 rejects falls back to depth-first
    // left-to-right. Bases that are not user classes (a builtin exception,
    // an interface) have no node and are left out here.
    std::unordered_map<Node*, std::vector<Node*>> mro_cache_;
    const std::vector<Node*>& classMro(Node* cls) {
        static const std::vector<Node*> empty;
        if (!cls || cls->type() != NodeType::CLASS) return empty;
        auto it = mro_cache_.find(cls);
        if (it != mro_cache_.end()) return it->second;
        mro_cache_[cls] = {cls};                    // guards against a cycle
        std::vector<std::vector<Node*>> seqs;
        std::vector<Node*> direct;
        for (auto& b : static_cast<ClassNode*>(cls)->bases) {
            Node* bn = classNodeByName(b->value());
            // a builtin base (int, list, dict ...): its mirror class stands
            // where it does (round 77; it was left out)
            if (!bn) bn = builtinMirrorNode(b->value());
            if (!bn || bn == cls) continue;
            seqs.push_back(std::vector<Node*>(classMro(bn)));
            direct.push_back(bn);
        }
        seqs.push_back(direct);
        std::vector<Node*> out{cls};
        bool ok = true;
        while (true) {
            bool any = false;
            for (auto& sq : seqs) if (!sq.empty()) { any = true; break; }
            if (!any) break;
            Node* pick = nullptr;
            for (auto& sq : seqs) {
                if (sq.empty()) continue;
                Node* cand = sq[0];
                bool in_tail = false;
                for (auto& sq2 : seqs)
                    for (size_t k = 1; k < sq2.size(); k++) if (sq2[k] == cand) { in_tail = true; break; }
                if (!in_tail) { pick = cand; break; }
            }
            if (!pick) { ok = false; break; }
            out.push_back(pick);
            for (auto& sq : seqs) if (!sq.empty() && sq[0] == pick) sq.erase(sq.begin());
        }
        if (!ok) {
            out = {cls};
            std::vector<Node*> todo(direct.begin(), direct.end());
            while (!todo.empty()) {
                Node* k = todo.front(); todo.erase(todo.begin());
                if (std::find(out.begin(), out.end(), k) != out.end()) continue;
                out.push_back(k);
                size_t at = 0;
                for (auto& b : static_cast<ClassNode*>(k)->bases) {
                    Node* bn = classNodeByName(b->value());
                    if (!bn) bn = builtinMirrorNode(b->value());   // round 77
                    if (bn) todo.insert(todo.begin() + (long)(at++), bn);
                }
            }
        }
        mro_cache_[cls] = out;
        return mro_cache_[cls];
    }
    // A member defined in the body of class `cls` or a class after it in its
    // MRO: its value in that class's own namespace (not the enclosing
    // scope's), and the class that defines it.
    bool findClassMember(Node* cls, const std::string& name, Value& out, Node** owner = nullptr,
                         Node* after = nullptr) {
        const std::vector<Node*>& mro = classMro(cls);
        size_t start = 0;
        if (after) {
            for (size_t i = 0; i < mro.size(); i++) if (mro[i] == after) { start = i + 1; break; }
        }
        for (size_t i = start; i < mro.size(); i++) {
            auto cit = class_ctx_map_.find((void*)mro[i]);
            if (cit == class_ctx_map_.end() || !cit->second || !cit->second->container) continue;
            auto vit = cit->second->container->find(name);
            if (vit == cit->second->container->end()) continue;
            out = vit->second;
            if (owner) *owner = mro[i];
            return true;
        }
        // every class reaches object's __subclasses__ and mro (round 77;
        // a class naming no base has no object in its MRO here), and its
        // pickle/copy protocol: __reduce_ex__, __reduce__, __getstate__
        // (round 79)
        if (!after && (name == "__subclasses__" || name == "mro" || name == "__reduce_ex__" || name == "__reduce__"
                       || name == "__getstate__")) {
            Node* objn = classNodeByName("object");
            if (objn && objn != cls && std::find(mro.begin(), mro.end(), objn) == mro.end())
                return findClassMember(objn, name, out, owner);
        }
        return false;
    }
    // ── object's members, read through any class (round 80) ──────────────
    // Every class's MRO ends in object (C.__mro__ says so), but a class
    // naming no base does not have object in the MRO the engines search, and
    // object's class body holds only the members the engines dispatch to
    // themselves (__init__, __new__, __setattr__ ...); the others - __eq__,
    // __hash__, __repr__ ... - are the prelude's _NyObjectExtra. They are
    // looked for only where a read through the class has found nothing (a
    // failed lookup: instance attribute reads that succeed pay nothing), and
    // only for the names object has in CPython.
    static bool objectFallbackName(const std::string& a) {
        if (a.size() < 6 || a[0] != '_' || a[1] != '_') return false;
        static const std::unordered_set<std::string> names = {
            "__init__", "__new__", "__setattr__", "__delattr__", "__getattribute__", "__init_subclass__",
            "__subclasshook__", "__reduce__", "__reduce_ex__", "__getstate__", "__eq__", "__ne__", "__lt__",
            "__le__", "__gt__", "__ge__", "__hash__", "__repr__", "__str__", "__format__", "__sizeof__", "__dir__"};
        return names.count(a) > 0;
    }
    // `cls` (the receiver's class): an exception's __init__ / __str__ /
    // __repr__ are BaseException's, which the engine supplies itself.
    bool objectMember(const std::string& name, Value& out, Node** owner = nullptr, Node* cls = nullptr) {
        if (!objectFallbackName(name)) return false;
        if (cls && cls->type() == NodeType::CLASS && (name == "__init__" || name == "__str__" || name == "__repr__")
            && isExceptionClass(static_cast<ClassNode*>(cls)->name)) return false;
        Node* objn = classNodeByName("object");
        if (objn && findClassMember(objn, name, out, owner)) return true;
        Node* ex = classNodeByName("_NyObjectExtra");
        return ex && findClassMember(ex, name, out, owner);
    }
    Node* classNodeOfInstance(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        auto it = instance_to_class.find(v.value.p);
        if (it == instance_to_class.end()) return nullptr;
        Node* n = (Node*)it->second;
        return (n && n->type() == NodeType::CLASS) ? n : nullptr;
    }
    bool isInstanceValue(const Value& v) {
        return isInstanceVal(v);   // round 81: the same test (it was written twice)
    }
    // ── Classes deriving from builtin types (round 77) ──────────────────
    // An instance of `class MyInt(int)` holds its value - the payload - in
    // the hidden field nyrt::payload_field(); the prelude's mirror class of
    // the type (_NyB_int ...) answers for it, standing in the MRO where the
    // type does (classMro). Builtins are given the payload (callBuiltin).
    bool any_payload_ = false;   // a payload instance was made: builtins unwrap their arguments
    bool payloadOf(const Value& v, Value& out) {
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        auto pit = instance_properties.find(v.value.p);
        if (pit == instance_properties.end() || !pit->second || !pit->second->container) return false;
        auto it = pit->second->container->find(nyrt::payload_field());
        if (it == pit->second->container->end()) {
            // an instance-dict view's value: its owner's fields as they are now
            it = pit->second->container->find("__ny_view_of__");
            if (it == pit->second->container->end()) {
                // round 81: a globals() view's: the module's variables now
                it = pit->second->container->find("__ny_globals_of__");
                if (it == pit->second->container->end()) return false;
                out = globalsOf(it->second);
                return true;
            }
            out = instanceFields(it->second);
            return true;
        }
        out = it->second;
        return true;
    }
    // ── obj.__dict__ / vars(obj): a live view (round 77) ────────────────
    // An instance of the prelude's _NyInstanceDict (a dict subclass, the
    // mirrors' "dictview" chunk) whose field __ny_view_of__ is the object:
    // its value is a fresh dict of the object's fields (payloadOf), so
    // every read sees them as they are; its __setitem__ / __delitem__ /
    // update ... store and remove fields (_ny_setfield / _ny_delfield). The
    // view holds the object; while it is alive the object's __dict__ is it
    // (vars(o) is o.__dict__), through a table that does not hold it - so
    // reading __dict__ makes no cycle and the object is still freed at once.
    std::unordered_map<const void*, std::pair<nyheap::Inst*, void*>> dict_views_;   // object -> its view
    std::unordered_map<const void*, const void*> dict_view_owner_;                  // view -> its object
    void forgetDictView(void* p) {
        auto o = dict_view_owner_.find(p);
        if (o != dict_view_owner_.end()) { dict_views_.erase(o->second); dict_view_owner_.erase(o); }
        auto v = dict_views_.find(p);
        if (v != dict_views_.end()) { dict_view_owner_.erase(v->second.second); dict_views_.erase(v); }
    }
    Value instanceFields(const Value& obj) {
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        Value dv((Collectable*)d);
        auto pit = instance_properties.find(obj.value.p);
        if (obj.type == ValueType::USERDATA && obj.value.p && pit != instance_properties.end() && pit->second && pit->second->container)
            for (auto& kv : *pit->second->container)
                if (!nyrt::hidden_field(kv.first) && (!member_desc_node_ || !isSlotOf(obj, kv.first)))   // a slot's value is not in __dict__ (round 79)
                    (*d->container)[nypy::key_of_str(kv.first)] = kv.second;
        return dv;
    }
    Value instanceDictView(const Value& obj) {
        auto pit = instance_properties.find(obj.value.p);
        if (pit == instance_properties.end() || !pit->second || !pit->second->container) return instanceFields(obj);
        auto it = dict_views_.find(obj.value.p);
        if (it != dict_views_.end()) return nyheap::userValue(it->second.first, it->second.second);
        ensureMirror("dictview");
        Node* vn = classNodeByName("_NyInstanceDict");
        if (!vn) return instanceFields(obj);
        Value view = newInstance(static_cast<ClassNode*>(vn)->name, (void*)vn);
        auto vit = instance_properties.find(view.value.p);
        if (vit != instance_properties.end() && vit->second) vit->second->defineByName("__ny_view_of__", obj);
        dict_views_[obj.value.p] = {static_cast<nyheap::Inst*>(view.value.o), view.value.p};
        dict_view_owner_[view.value.p] = obj.value.p;
        any_payload_ = true;
        return view;
    }
    // _ny_setfield(obj, name, value) / _ny_delfield(obj, name): a field
    // stored or removed directly (no __setattr__, no descriptor), as
    // obj.__dict__[name] = value does.
    Context* fieldsOf(const Value& obj, const char* who) {
        auto pit = obj.type == ValueType::USERDATA && obj.value.p ? instance_properties.find(obj.value.p) : instance_properties.end();
        if (pit == instance_properties.end() || !pit->second) pyRaise("TypeError", std::string(who) + ": not an instance");
        return pit->second;
    }
    void setField(const Value& obj, const Value& name, const Value& v) {
        if (!isStringValue(name)) pyRaise("TypeError", "attribute name must be string, not '" + typeNameOf(name) + "'");
        fieldsOf(obj, "__dict__")->defineByName(getStringValue(name), v);
    }
    void delField(const Value& obj, const Value& name) {
        Context* f = fieldsOf(obj, "__dict__");
        std::string n = isStringValue(name) ? getStringValue(name) : std::string();
        if (n.empty() || nyrt::hidden_field(n) || !f->container || !f->container->erase(n)) missingKey(name, global_ctx);
    }
    // ── __slots__ and __class__ assignment (round 79) ───────────────────
    // The prelude's "slots" chunk does the Python-level work; these keep
    // what the engine needs: per class the flags _ny_mark_slots gave (1: its
    // instances have no __dict__, 2: no weak references), the member
    // descriptor class (a slot's value is the instance's field of its name:
    // reads and stores go straight to it), and the switch of an instance's
    // class.
    std::unordered_map<const Node*, int> slot_flags_;
    Node* member_desc_node_ = nullptr;
    void ensureSlotsChunk() {
        if (member_desc_node_) return;
        ensureMirror("slots");
        member_desc_node_ = classNodeByName("_NyMemberDescriptor");
    }
    bool isDictless(const Value& obj) {
        if (!isInstanceValue(obj)) return false;
        auto it = slot_flags_.find(classNodeOfInstance(obj));
        return it != slot_flags_.end() && (it->second & 1);
    }
    // obj's class holds a slot (a member descriptor) named attr
    bool isSlotOf(const Value& obj, const std::string& attr) {
        if (!member_desc_node_) return false;
        Node* cls = classNodeOfInstance(obj);
        Value d;
        return cls && findClassMember(cls, attr, d) && isInstanceValue(d) && classNodeOfInstance(d) == member_desc_node_;
    }
    // _ny_getfield(obj, name): a slot's value (AttributeError when unset)
    Value getField(const Value& obj, const Value& name) {
        Context* f = fieldsOf(obj, "__slots__");
        std::string n = isStringValue(name) ? getStringValue(name) : std::string();
        if (f->container && !n.empty()) {
            auto it = f->container->find(n);
            if (it != f->container->end()) return it->second;
        }
        pyRaise("AttributeError", "'" + typeNameOf(obj) + "' object has no attribute '" + n + "'");
        return NONE_VALUE;
    }
    void markSlots(const Value& cls, int flags) {
        if (Node* cn = classNodeOfValue(cls)) { slot_flags_[cn] = flags; specInvalidate(); }   // (round 81: store caches read it)
    }
    int slotFlags(const Value& cls) {
        Node* cn = classNodeOfValue(cls);
        auto it = cn ? slot_flags_.find(cn) : slot_flags_.end();
        return it == slot_flags_.end() ? 0 : it->second;
    }
    void setClassOf(const Value& obj, const Value& cls) {
        ensureSlotsChunk();
        std::vector<Value> a{obj, cls};
        callFunctionValue(global_ctx->getByName("_ny_set_class"), a, global_ctx);
    }
    // _ny_switch_class(obj, cls): every reference to obj sees cls at once
    // (the class is kept by the instance's identity, not in each value)
    void switchClass(const Value& obj, const Value& cls) {
        Node* cn = classNodeOfValue(cls);
        if (!isInstanceValue(obj) || !cn || isInstanceValue(cls))
            pyRaise("TypeError", "__class__ assignment only supported for mutable types or ModuleType subclasses");
        const std::string tag = "__instance__:" + static_cast<ClassNode*>(cn)->name;
        void* p = obj.value.p;
        instance_to_class[p] = cls.value.p;
        func_names[p] = tag;
        // The instance's object is found from its identity even when this
        // value does not own it (round 81: instClassNode reads the class
        // from the object, so the two must never disagree).
        nyheap::Inst* io = dynamic_cast<nyheap::Inst*>(obj.value.o);
        if (!io || (void*)&io->tag != p) io = instObjectOf(p);
        if (io) { io->tag = tag; io->cls = cls.value.p; }
        mro_cache_.clear(); specInvalidate();
    }
    Value unwrapPayload(const Value& v) { Value p; return any_payload_ && payloadOf(v, p) ? p : v; }
    void unwrapPayloadArgs(std::vector<Value>& args) {
        for (auto& a : args) { Value p; if (payloadOf(a, p)) a = p; }
    }
    // A builtin's arguments (callBuiltin): payload instances as their values,
    // unless the builtin is one of nyrt::payload_transparent's.
    void unwrapBuiltinArgs(const std::string& name, std::vector<Value>& args) {
        int decided = 0;
        for (auto& a : args) {
            if (a.type != ValueType::USERDATA || !a.value.p || string_ptrs_.count(a.value.p)) continue;
            Value p;
            if (!payloadOf(a, p) || iterOverridden(a)) continue;
            if (!decided) decided = nyrt::payload_transparent(name) ? -1 : 1;
            if (decided < 0) return;
            a = p;
        }
    }
    // An instance of a class deriving from a builtin type that holds no
    // value (made by object.__new__): an error from _ny_payload, not the
    // mirror's methods calling themselves for ever.
    void checkHasPayload(const Value& v) {
        Node* cn = classNodeOfInstance(v);
        if (!cn) return;
        for (Node* c : classMro(cn)) {
            std::string bt = nyrt::mirror_builtin(static_cast<ClassNode*>(c)->name);
            if (!bt.empty() && c != cn)
                pyRaise("TypeError", "'" + nyrt::bare_class_name(shownClassName(static_cast<ClassNode*>(cn)->name)) + "' object holds no "
                        + bt + " value (it was made by object.__new__(), not " + bt + ".__new__())");
        }
    }
    Node* builtinMirrorNode(const std::string& t) {
        const char* m = nyrt::builtin_mirror(t);
        return m ? classNodeByName(m) : nullptr;
    }
    // (5).__add__, "ab".__len__, [1].__getitem__, {}.__contains__ ... (round
    // 78): a plain builtin value's dunder methods are its type's, from the
    // type's mirror class (nyrt::value_dunder_class: int and float have
    // versions giving Python's NotImplemented for an operand the type does
    // not take), bound to the value. False: not such a dunder.
    bool builtinValueDunder(const Value& obj, const std::string& attr, Value& out) {
        if (attr.size() < 5 || attr[0] != '_' || attr[1] != '_' || attr == "__new__" || attr == "__init__" || attr == "__format__"
            || !nyrt::mirror_dunder(attr) || isInstanceValue(obj)) return false;
        std::string t = typeNameOf(obj);
        if (t == "bool") t = "int";
        if (!nyrt::builtin_mirror(t)) return false;
        if (Container* c = contOf(obj)) if (seqLen(c) < 0 && !isPlainDict(c)) return false;   // a namespace
        ensureMirror(t);
        Value m;
        Node* vn = classNodeByName(nyrt::value_dunder_class(t));
        if (!vn || !findClassMember(vn, attr, m)) {
            Node* mn = builtinMirrorNode(t);
            // a type without a __str__ of its own: object's, its __repr__
            if (!mn || (!findClassMember(mn, attr, m) && !(attr == "__str__" && findClassMember(mn, "__repr__", m))))
                return false;
        }
        if (!isPlainFunction(m)) return false;
        out = makeBoundMethod(m, obj);
        return true;
    }
    // _ny_payload_new(cls, T, value), what T.__new__(cls, ...) does: value
    // itself when cls is T, else a new instance of cls (a subclass of T)
    // holding it.
    Value newPayloadInstance(const Value& cls, const Value& t, const Value& value) {
        std::string tn = t.type == ValueType::USERDATA && t.value.p ? fnTag(func_names, t.value.p) : std::string();
        if (tn.rfind("__builtin__:", 0) == 0) tn = tn.substr(12);
        if (tn == "map") tn = "dict";
        if (cls.type == ValueType::USERDATA && cls.value.p && cls.value.p == t.value.p) return value;
        Node* cn = classNodeOfValue(cls);
        if (!cn && isTypeObject(cls)) {
            std::string sn = fnTag(func_names, cls.value.p);
            if (sn.rfind("__builtin__:", 0) == 0) sn = sn.substr(12);
            pyRaise("TypeError", tn + ".__new__(" + sn + "): " + sn + " is not a subtype of " + tn);
        }
        if (!cn) pyRaise("TypeError", tn + ".__new__(X): X is not a type object (" + typeNameOf(cls) + ")");
        std::string cname = static_cast<ClassNode*>(cn)->name;
        std::string shown = nyrt::bare_class_name(shownClassName(cname));
        if (!classDerivesFrom(cname, tn))
            pyRaise("TypeError", tn + ".__new__(" + shown + "): " + shown + " is not a subtype of " + tn);
        Value inst = newInstance(cname, cls.value.p);
        auto pit = instance_properties.find(inst.value.p);
        if (pit != instance_properties.end() && pit->second) pit->second->defineByName(nyrt::payload_field(), value);
        any_payload_ = true;
        return inst;
    }
    // A payload instance whose class keeps the type's __hash__ and __eq__
    // is the same dict key / set element as its value (MyStr("k") finds
    // d["k"], 1 in {MyInt(1)}); cached per class (class nodes are never
    // freed, and a class's MRO does not change).
    std::unordered_map<const Node*, bool> payload_key_cache_;
    // A class with an __iter__ of its own (Flag's, a list subclass's): a
    // builtin is given the instance and iterates it through that, as
    // CPython's slots would (round 77); cached per class, cleared with the
    // attribute-hook caches.
    std::unordered_map<const Node*, bool> iter_own_cache_;
    bool iterOverridden(const Value& v) {
        Node* cn = classNodeOfInstance(v);
        if (!cn) return false;
        auto it = iter_own_cache_.find(cn);
        if (it != iter_own_cache_.end()) return it->second;
        Value m; Node* owner = nullptr;
        bool own = findClassMember(cn, "__iter__", m, &owner) && owner && owner->type() == NodeType::CLASS
                   && nyrt::mirror_builtin(static_cast<ClassNode*>(owner)->name).empty();
        iter_own_cache_[cn] = own;
        return own;
    }
    bool payloadKey(const Value& v, Value& out) {
        if (!any_payload_ || !payloadOf(v, out)) return false;
        Node* cn = classNodeOfInstance(v);
        if (!cn) return false;
        auto it = payload_key_cache_.find(cn);
        if (it != payload_key_cache_.end()) return it->second;
        bool plain = true;
        for (const char* d : {"__hash__", "__eq__"}) {
            Value m; Node* owner = nullptr;
            if (!findClassMember(cn, d, m, &owner) || !owner || owner->type() != NodeType::CLASS
                || nyrt::mirror_builtin(static_cast<ClassNode*>(owner)->name).empty()) plain = false;
        }
        payload_key_cache_[cn] = plain;
        return plain;
    }
    // ── eval / exec / compile (round 77; there were none) ──────────────
    // Source text - a str, bytes, or what compile() made - parsed and run:
    // eval gives the value of one expression, exec runs statements. With a
    // globals (and locals) dict the code runs in a scope of its own made
    // from them, the builtins visible but not the program's names, and exec
    // writes what it binds back into the dict; without one, in the caller's
    // scope.
    std::string snippetSource(const Value& v, std::string& mode, std::string& fname, const char* who) {
        if (isInstanceValue(v) && shownClassName(instanceClassName(v)) == "_NyCode") {
            auto pit = instance_properties.find(v.value.p);
            if (pit != instance_properties.end() && pit->second && pit->second->container) {
                auto& c = *pit->second->container;
                auto g = [&](const char* k) { auto it = c.find(k); return it != c.end() ? getStringValue(it->second) : std::string(); };
                mode = g("mode");
                fname = g("co_filename");
                return g("source");
            }
        }
        if (auto* bo = bytesOf(v)) return bo->s;
        if (isStringValue(v)) return getStringValue(v);
        pyRaise("TypeError", std::string(who) + "() arg 1 must be a string, bytes or code object");
        return std::string();
    }
    node_ptr parseSnippet(const std::string& src, const std::string& fname) {
        try {
            auto source = SourceCode::from_text(src, fname);
            auto rep = std::make_shared<Reporter>(source);
            auto lex = std::make_shared<Lexer>(source);
            lex->tokenize();
            Parser par(rep.get(), (Runnable*)runner, lex.get());
            node_ptr ast = par.parse();
            if (ast) imported_asts.push_back(ast);   // what it defines outlives the call
            return ast;
        } catch (nython::exception::SyntaxError& e) {
            pyRaise("SyntaxError", e.message());
        } catch (nython::exception::UnexpectedCharError& e) {
            pyRaise("SyntaxError", e.message());
        }
        return nullptr;
    }
    // exec / eval run their code in a frame of its own - "<module>" of the
    // snippet's file, "<string>" - as CPython's (round 79: the VM's always
    // had one; frames, tracebacks and the trace events see it).
    Value runSnippetFrame(const node_ptr& ast, Context* sc) {
        FrameGuard _frame(nullptr, sc);
        // round 82: exec(src) runs in the caller's own scope - its
        // statements are not the caller's, whose pending flags they must
        // not use (a raise there left by the flag, through exec)
        SuspendFast _sf;
        if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) {
            Node* first = ast.get();
            if (ast && (ast->type() == NodeType::SCRIPT || ast->type() == NodeType::STATEMENTS || ast->type() == NodeType::BLOCK)) {
                auto sts = ast->statements();
                if (!sts.empty() && sts[0]) first = sts[0].get();
            }
            if (first && !tbHiddenFile(first->tok().fileName())) return runBodyHooked(first, ast, sc, false);
        }
        try { return evalNode(ast, sc); }
        catch (std::string& flow) { tbUnwind(flow); throw; }
        catch (std::exception& e) { tbUnwind(excFromCpp(e.what())); throw; }
    }
    Value evalExecBuiltin(bool is_exec, std::vector<Value>& args, Context* ctx) {
        const char* who = is_exec ? "exec" : "eval";
        if (args.empty()) pyRaise("TypeError", std::string(who) + "() missing required argument 'source' (pos 1)");
        if (any_payload_) { Value p; if (payloadOf(args[0], p)) args[0] = p; }   // a str subclass (round 81: exec is payload-transparent)
        std::string mode = is_exec ? "exec" : "eval", fname = "<string>";
        std::string src = snippetSource(args[0], mode, fname, who);
        if (mode == "exec") is_exec = true;    // eval(compile(..., "exec")) runs it
        if (!is_exec) {
            size_t b = src.find_first_not_of(" \t");
            src = b == std::string::npos ? std::string() : src.substr(b);
        }
        node_ptr ast = parseSnippet(src, fname);
        if (!ast) return NONE_VALUE;
        if (!is_exec && !nython::node::is_expression_program(ast)) pyRaise("SyntaxError", "invalid syntax");
        bool has_g = args.size() > 1 && !args[1].isNone(), has_l = args.size() > 2 && !args[2].isNone();
        // round 81: exec(src, globals()) / eval(src, globals()) run in that
        // module's own scope (the view stands for it); any other dict
        // subclass is given as its value
        // a dict subclass's object: its value is read, what the code binds
        // goes back through its __setitem__ (OrderedDict, a class body's
        // namespace...) - it was lost in a copy
        Value sub_out = NONE_VALUE;
        bool same_gl = has_g && has_l && args[2].type == args[1].type && args[2].value.p == args[1].value.p;
        if (has_g) {
            Context* vs = globalsViewScope(args[1]);
            if (vs && (!has_l || same_gl)) {
                Value r = runSnippetFrame(ast, vs);
                return is_exec ? NONE_VALUE : r;
            }
            Value p;
            if (any_payload_ && payloadOf(args[1], p)) { if (!has_l || same_gl) sub_out = args[1]; args[1] = p; }
        }
        if (has_l && any_payload_) { Value p; if (payloadOf(args[2], p)) { sub_out = args[2]; args[2] = p; } }
        if (has_l && !same_gl && isInstanceValue(args[2]) && !isInstanceValue(sub_out)) {
            // round 81: locals may be any mapping (Python): its bindings
            // are read through keys()/__getitem__, written back through
            // __setitem__ like a dict subclass's
            std::vector<Value> a{args[2]};
            Value snap = callFunctionValue(global_ctx->getByName("_ny_mapping_snapshot"), a, ctx);
            sub_out = args[2];
            args[2] = snap;
        }
        if (same_gl && isInstanceValue(sub_out)) has_l = false;   // one mapping: the globals
        Container* gd = has_g ? contOf(args[1]) : nullptr;
        Container* ld = has_l ? contOf(args[2]) : nullptr;
        if (has_g && (!gd || seqLen(gd) >= 0)) pyRaise("TypeError", std::string(who) + "() globals must be a dict, not " + typeNameOf(args[1]));
        if (!gd && !ld) {
            Value r = runSnippetFrame(ast, ctx);
            return is_exec ? NONE_VALUE : r;
        }
        Context* sc = new Context(runner, "<string>", nullptr, nullptr, global_ctx);
        CtxReaper reap(this, sc);
        sc->inModule = true;
        sc->parentFilter = &module_filter_;
        // what the code bound that goes back into a dict: every name but the
        // parser's temporaries (round 77: dunder names too - def __init__)
        auto exported = [](const std::string& k) {
            return !k.empty() && (unsigned char)k[0] >= 0x20 && !nyrt::is_decorator_temp(k);
        };
        // A dict's string key is the plain name, except a dunder name
        // ("\x01s__x__"); a scope keys every name plainly.
        bool live = gd && (!ld || ld == gd) && !isInstanceValue(sub_out);
        if (live) {
            // exec(src, ns) / eval(src, ns): the scope's variables ARE the
            // dict's (round 77, as Python) - functions defined there see
            // later changes to ns, and what they bind with `global` lands in
            // it. With a locals dict too, a scope made from both, its
            // bindings copied into the locals dict afterwards.
            delete sc->container;
            sc->container = gd->container;
            sc->ns_owner = gd;
            nygc::incref(gd);
            std::vector<std::pair<std::string, Value>> dn;
            for (auto& kv : *gd->container)
                if (kv.first.size() > 2 && kv.first[0] == '\x01' && kv.first[1] == 's') dn.push_back({kv.first.substr(2), kv.second});
            for (auto& d : dn) (*gd->container)[d.first] = d.second;
        } else {
            auto load = [&](Container* d) {
                for (auto& kv : *d->container) {
                    if (isInternalKey(kv.first)) continue;
                    if (kv.first.size() >= 2 && kv.first[0] == '\x01' && kv.first[1] != 's') continue;   // not a str key
                    sc->defineByName(nypy::key_payload(kv.first), kv.second);
                }
            };
            if (gd) load(gd);
            if (ld) load(ld);
        }
        // the markers a dict's map must not hold as plain keys (a "__len__"
        // makes it a list): bound by the code, they stay under the dict key
        static const char* const markers[] = {"__len__", "__tuple__", "__set__", "__kwargs__", "__type__", "__class__"};
        std::vector<const char*> fresh_markers;
        if (live) for (const char* m : markers) if (!gd->container->count(m)) fresh_markers.push_back(m);
        Value r = runSnippetFrame(ast, sc);
        if (live) {
            std::vector<std::pair<std::string, Value>> add;
            for (auto& kv : *gd->container)
                if (isInternalKey(kv.first) && exported(kv.first)) add.push_back({nypy::key_of_str(kv.first), kv.second});
            for (auto& d : add) (*gd->container)[d.first] = d.second;
            for (const char* m : fresh_markers) gd->container->erase(m);
            return is_exec ? NONE_VALUE : r;
        }
        if (!is_exec) return r;
        Container* out = ld ? ld : gd;
        if (isInstanceValue(sub_out)) {
            // a dict subclass (round 81): what the code bound or rebound,
            // through its __setitem__
            for (auto& kv : *sc->container) {
                if (!exported(kv.first)) continue;
                // as it was loaded: from the locals, else the globals
                bool same = false;
                for (Container* src0 : {ld, gd}) {
                    if (!src0) continue;
                    auto s = src0->container->find(nypy::key_of_str(kv.first));
                    if (s == src0->container->end()) continue;
                    same = identical(s->second, kv.second);
                    break;
                }
                if (same) continue;
                std::vector<Value> a{makeStringValue(kv.first), kv.second};
                callMethod(sub_out, "__setitem__", a, ctx);
            }
            return NONE_VALUE;
        }
        for (auto& kv : *sc->container) if (exported(kv.first)) dictSet(out, makeStringValue(kv.first), kv.second);
        return NONE_VALUE;
    }
    Value compileBuiltin(std::vector<Value>& args, Context* ctx) {
        if (args.size() < 3) pyRaise("TypeError", "compile() missing required argument (source, filename, mode)");
        std::string fname = getStringValue(args[1]), mode = getStringValue(args[2]);
        if (mode != "exec" && mode != "eval" && mode != "single") pyRaise("ValueError", "compile() mode must be 'exec', 'eval' or 'single'");
        std::string m2 = mode, f2 = fname;
        std::string src = snippetSource(args[0], m2, f2, "compile");
        node_ptr ast = parseSnippet(src, fname);   // a syntax error is raised now, as Python's
        if (mode == "eval" && ast && !nython::node::is_expression_program(ast)) pyRaise("SyntaxError", "invalid syntax");
        Value cls = global_ctx->getByName("_NyCode");
        std::vector<Value> a{makeStringValue(src), makeStringValue(fname), makeStringValue(mode == "single" ? "exec" : mode)};
        return callFunctionValue(cls, a, ctx);
    }

    // ── Reflection: locals(), globals(), vars(), dir() (round 77) ──────
    // All four were placeholders returning none. locals() is the calling
    // scope's names (at module level, globals()); globals() the module's
    // own names - not the builtins and prelude every program starts with;
    // vars(x) is x.__dict__ (a class: its namespace, a module: its names);
    // dir(x) the sorted names x answers to.
    static bool reflectHidden(const std::string& k) {
        if (k.empty() || (unsigned char)k[0] < 0x20) return true;
        if (k == "__name__" || k == "__file__" || k == "__doc__") return false;
        if (nyrt::user_dunder_name(k)) return false;   // a program's __x__ (round 80)
        return isInternalKey(k);
    }
    Value reflectGlobals(Context* ctx) {
        Context* m = moduleCtx(ctx ? ctx : global_ctx);
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        if (m && m->container)
            for (auto& kv : *m->container) {
                if (reflectHidden(kv.first)) continue;
                // the module's __name__ and __file__ are its own (round 78:
                // globals() had neither)
                if (m == global_ctx && base_global_names_.count(kv.first) && kv.first != "__name__" && kv.first != "__file__") continue;
                (*d->container)[nypy::key_of_str(kv.first)] = kv.second;   // a dict key (round 78: __name__ was not one)
            }
        return Value((Collectable*)d);
    }
    // ── globals(): the module's live namespace (round 81) ──────────────
    // A view - the prelude's _NyGlobalsDict - whose value is the module's
    // variables as they are now (payloadOf) and whose stores and deletions
    // bind and unbind them (_ny_main_set / _ny_main_del for the program,
    // setattr / delattr on an imported module's live namespace); one per
    // module, so globals() is globals(). Its field __ny_globals_of__ is none
    // for the program, else the module's namespace object.
    Value main_globals_view_;
    std::unordered_map<const void*, Value> module_globals_views_;
    Value globalsOf(const Value& owner) {
        Container* c = owner.type == ValueType::NONE ? nullptr : contOf(owner);
        if (!c) return reflectGlobals(nullptr);
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        Value dv((Collectable*)d);
        for (auto& kv : *c->container) if (!reflectHidden(kv.first)) (*d->container)[nypy::key_of_str(kv.first)] = kv.second;
        return dv;
    }
    // The module scope a globals() view stands for (null: not a view)
    Context* globalsViewScope(const Value& v) {
        if (!isInstanceValue(v)) return nullptr;
        auto pit = instance_properties.find(v.value.p);
        if (pit == instance_properties.end() || !pit->second || !pit->second->container) return nullptr;
        auto it = pit->second->container->find("__ny_globals_of__");
        if (it == pit->second->container->end()) return nullptr;
        if (it->second.type == ValueType::NONE) return global_ctx;
        for (Context* m : module_ctxs_) if (m && it->second.isCollectable() && m->ns_owner == it->second.value.gc) return m;
        return nullptr;
    }
    Value globalsView(Context* ctx) {
        Context* m = moduleCtx(ctx ? ctx : global_ctx);
        Value owner = NONE_VALUE;
        if (m && m != global_ctx) {
            if (!m->ns_owner) return reflectGlobals(ctx);
            Value o(m->ns_owner);
            if (!isModuleNamespace(o)) return o;   // exec(src, ns): ns itself, as CPython
            owner = o;
        }
        return globalsViewFor(owner);
    }
    // the view for a module object (none: the program)
    Value globalsViewFor(const Value& owner) {
        Value& slot = owner.type == ValueType::NONE ? main_globals_view_ : module_globals_views_[(const void*)owner.value.gc];
        if (isInstanceValue(slot)) return slot;
        ensureMirror("dictview");
        Node* vn = classNodeByName("_NyGlobalsDict");
        if (!vn) return globalsOf(owner);
        Value view = newInstance(static_cast<ClassNode*>(vn)->name, (void*)vn);
        auto vit = instance_properties.find(view.value.p);
        if (vit != instance_properties.end() && vit->second) vit->second->defineByName("__ny_globals_of__", owner);
        any_payload_ = true;
        slot = view;
        return view;
    }
    Value reflectLocals(Context* ctx) {
        if (!ctx || ctx == global_ctx || ctx->inModule || !ctx->parent) return reflectGlobals(ctx);
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        if (ctx->container)
            for (auto& kv : *ctx->container) if (!reflectHidden(kv.first)) (*d->container)[nypy::key_of_str(kv.first)] = kv.second;   // round 78
        return Value((Collectable*)d);
    }
    Node* classNodeOfValue(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        auto fit = func_names.find(v.value.p);
        if (fit == func_names.end() || fit->second.rfind("__class__:", 0) != 0) return nullptr;
        Node* n = (Node*)v.value.p;
        return n->type() == NodeType::CLASS ? n : nullptr;
    }
    // A class's members along its MRO, then what every object answers to
    // (object's, as CPython lists them - not the prelude object's own
    // helpers such as mro) - round 77.
    void classMemberNames(Node* cls, std::set<std::string>& out) {
        Node* objn = classNodeByName("object");
        for (auto& n : nyrt::object_dir_names()) out.insert(n);
        if (cls != objn) for (auto& n : nyrt::class_dir_names()) out.insert(n);
        for (Node* c : classMro(cls)) {
            if (c == objn) continue;
            auto cit = class_ctx_map_.find((void*)c);
            if (cit == class_ctx_map_.end() || !cit->second || !cit->second->container) continue;
            for (auto& kv : *cit->second->container)
                if (!kv.first.empty() && (unsigned char)kv.first[0] >= 0x20 && kv.first != "__parent_class__"
                    && !nyrt::is_decorator_temp(kv.first)) out.insert(kv.first);
        }
    }
    // Module and namespace objects (import X, `namespace N:`, os, sys)
    // are recorded where they are made, with their names: a freed one's
    // address reused by a dict is not mistaken for it.
    std::unordered_map<const void*, std::string> namespace_objs_;
    void noteNamespace(Object* o) { if (o) namespace_objs_[(const void*)o] = o->getName(); }
    bool isModuleNamespace(const Value& v) {
        Container* c = contOf(v);
        auto* o = c ? dynamic_cast<Object*>(c) : nullptr;
        if (!o) return false;
        auto it = namespace_objs_.find((const void*)o);
        // (round 78: a list or tuple made at a freed namespace's address is
        // none - modules are mostly nameless here; it printed as a module)
        return it != namespace_objs_.end() && it->second == o->getName() && o->getName() != "map"
               && seqLen(c) < 0;
    }
    Value reflectVars(std::vector<Value>& args, Context* ctx) {
        if (args.empty()) {
            // round 81: at a module's top level, its globals() view
            if (!ctx || ctx == global_ctx || ctx->inModule || !ctx->parent) return globalsView(ctx);
            return reflectLocals(ctx);
        }
        const Value& o = args[0];
        // round 81: a module's, its live globals() view
        if (isModuleNamespace(o) && o.isCollectable())
            for (Context* m : module_ctxs_) if (m && m->ns_owner == o.value.gc) return globalsViewFor(o);
        // an instance's: its __dict__, the live view (round 77); none with
        // __slots__ and no __dict__ (round 79)
        if (isInstanceValue(o) && !slot_flags_.empty() && isDictless(o))
            pyRaise("TypeError", "vars() argument must have __dict__ attribute");
        if (isInstanceValue(o)) {
            // a class's own __dict__ (a property: sys.modules["__main__"]'s
            // is the program's globals - round 81)
            Value dm; Node* downer = nullptr;
            if (Node* cn = classNodeOfInstance(o); cn && findClassMember(cn, "__dict__", dm, &downer) && downer != classNodeByName("object")) {
                Value r;
                if (getAttrValue(o, "__dict__", ctx, r)) return r;
            }
            return instanceDictView(o);
        }
        auto* d = new Object((Runnable*)runner, "map", Type::MAP);
        Value dv((Collectable*)d);
        if (Node* cn = classNodeOfValue(o)) return classNamespace(cn);
        if (isModuleNamespace(o)) {
            for (auto& kv : *contOf(o)->container) if (!reflectHidden(kv.first)) d->set(kv.first, kv.second);
            return dv;
        }
        pyRaise("TypeError", "vars() argument must have __dict__ attribute");
        return NONE_VALUE;
    }
    Value reflectDir(std::vector<Value>& args, Context* ctx) {
        std::set<std::string> names;
        if (args.empty()) {
            Value l = reflectLocals(ctx);
            for (auto& kv : *contOf(l)->container) if (!isInternalKey(kv.first) || !reflectHidden(kv.first)) names.insert(nypy::key_payload(kv.first));
        } else {
            const Value& o = args[0];
            if (isInstanceValue(o)) {
                // its own attributes (dunders too), its class's, object's
                // (round 77)
                auto pit = instance_properties.find(o.value.p);
                if (pit != instance_properties.end() && pit->second && pit->second->container)
                    for (auto& kv : *pit->second->container)
                        if (!kv.first.empty() && (unsigned char)kv.first[0] >= 0x20 && !nyrt::hidden_field(kv.first)) names.insert(kv.first);
                if (Node* cn = classNodeOfInstance(o)) classMemberNames(cn, names);
                names.insert("__class__"); names.insert("__dict__");
            } else if (Node* cn = classNodeOfValue(o)) {
                classMemberNames(cn, names);
            } else if (isModuleNamespace(o)) {
                for (auto& kv : *contOf(o)->container) if (!reflectHidden(kv.first)) names.insert(kv.first);
            } else {
                nypy::MemberKind k = memberKindOf(o);
                if (const auto* ms = nypy::kind_methods(k)) names.insert(ms->begin(), ms->end());
                if (k != nypy::MemberKind::Other) {
                    for (auto& m : nypy::protocol_members()) names.insert(m);
                    names.insert("__class__");
                } else if (o.type == ValueType::USERDATA) {
                    for (const char* n : {"__module__", "__name__", "__qualname__"}) names.insert(n);
                }
            }
        }
        std::vector<Value> out;
        for (auto& n : names) out.push_back(makeStringValue(n));
        return makeListValue(out);
    }
    bool anyIteratorObject(const std::vector<Value>& args) {
        for (auto& a : args) if (isInstanceValue(a) && instanceHasMethod(a, "__next__")) return true;
        return false;
    }
    bool instanceHasMethod(const Value& v, const std::string& name) {
        Node* cn = classNodeOfInstance(v);
        Value m;
        return cn && findClassMember(cn, name, m);
    }
    // A descriptor: a class attribute `d` holding an object whose class
    // defines __get__ (cached_property, partialmethod...). Read through an
    // instance the attribute is d.__get__(instance, owner); through the
    // class, d.__get__(None, owner). An instance's own attribute of that
    // name is found before it (a non-data descriptor, as in Python).
    // `any_recv`: obj is the receiver whatever it is (a class reading its
    // metaclass's property).
    // `defining`: the class whose namespace holds d (super() in a property's
    // getter starts after it).
    bool descriptorGet(const Value& d, const Value& obj, void* owner_ptr, Context* ctx, Value& out, bool any_recv = false,
                       Node* defining = nullptr) {
        if (!isInstanceValue(d)) return false;
        bool recv = any_recv || isInstanceValue(obj);
        // the prelude's property: its getter called directly (round 77)
        Node* dc = classNodeOfInstance(d);
        if (dc && dc == prelude_property_node()) {
            if (!recv) { out = d; return true; }
            Value fg = attrOf(d, "fget");
            if (isPlainFunction(fg)) {
                std::vector<Value> a{obj};
                OwnerScope _os(owner_stack_, defining ? defining : (Node*)owner_ptr);
                out = callFunctionValue(fg, a, ctx);
                return true;
            }
        }
        if (!instanceHasMethod(d, "__get__")) return false;
        Value owner; owner.type = ValueType::USERDATA; owner.value.p = owner_ptr;
        std::vector<Value> a{recv ? obj : NONE_VALUE, any_recv ? typeObjectOf(obj) : owner};
        out = callMethod(d, "__get__", a, ctx);
        return true;
    }
    // The prelude's property class (nullptr before the prelude defines it).
    Node* prelude_property_node_ = nullptr;
    Node* prelude_property_node() {
        if (!prelude_property_node_) prelude_property_node_ = classNodeByName("property");
        return prelude_property_node_;
    }
    // Methods run with the class that defines them on this stack, so a
    // super() call inside knows where in the MRO to continue from.
    std::vector<Node*> owner_stack_;
    // FunctionNodes written directly in a class body (its methods), as
    // opposed to functions a decorator returned into the class namespace.
    std::unordered_set<const Node*> direct_methods_;
    struct OwnerScope {
        std::vector<Node*>& st;
        OwnerScope(std::vector<Node*>& s_, Node* o) : st(s_) { st.push_back(o); }
        ~OwnerScope() { st.pop_back(); }
    };
    template <typename M> static std::string fnTag(const M& fnames, void* p) {
        auto it = fnames.find(p);
        return it == fnames.end() ? std::string() : it->second;
    }
    // Calls class member `m` (defined in `owner`) as a method of `self`
    // (an instance, or the class itself for Class.method(...)): a static
    // method takes the arguments as they are, a classmethod gets the class,
    // a method with self gets the instance (from the arguments when called
    // on the class). Keyword arguments, defaults and exceptions all behave
    // as for a plain call.
    Value invokeMember(Value m, Node* owner, Value self, std::vector<Value>& args,
                       const nyrt::OrderedKw<Value>& kw, Context* ctx) {
        std::string tag = fnTag(func_names, m.value.p);
        bool is_static = tag.find("__static__") != std::string::npos;
        bool is_cm = tag.find("__classmethod__") != std::string::npos;
        void* ast_ptr = m.value.p;
        auto ai = func_ast_nodes.find(m.value.p);
        if (ai != func_ast_nodes.end()) ast_ptr = ai->second;
        Node* raw = (Node*)ast_ptr;
        bool self_is_class = !isInstanceValue(self);
        if (!raw || raw->type() != NodeType::FUNCTION) {
            // A decorated method (a closure the decorator returned): it takes
            // the instance as its first argument.
            std::vector<Value> with_self;
            if (!self_is_class) with_self.push_back(self);
            for (auto& a : args) with_self.push_back(a);
            return callFunctionValue(m, with_self, ctx);
        }
        auto* fn = static_cast<FunctionNode*>(raw);
        if (!direct_methods_.count(fn) && !self_is_class && !is_static && !is_cm) {
            // A function a decorator put in the class: called with the
            // instance as its first argument, as Python binds any function.
            std::vector<Value> with_self; with_self.reserve(args.size() + 1);
            with_self.push_back(self);
            for (auto& a : args) with_self.push_back(a);
            Context* wp = global_ctx;
            auto wc = closure_contexts.find(m.value.p);
            if (wc != closure_contexts.end() && wc->second) wp = scopeOf(wc->second);
            Context* wfc = new Context(runner, fn->name, nullptr, nullptr, wp);
            CtxReaper _reap_w(this, wfc);
            bindParamsKw(fn, with_self, kw, wfc, ctx, 0, m.value.p);
            OwnerScope _osw(owner_stack_, owner);
            return runFunctionBody(fn, wfc);
        }
        Context* cp = global_ctx;
        auto cit = closure_contexts.find(m.value.p);
        if (cit != closure_contexts.end() && cit->second) {
            // The class body's scope, minus the class body itself: methods see
            // the scope the class was defined in, not the caller's.
            cp = cit->second->inClass && cit->second->parent ? cit->second->parent : cit->second;
        }
        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
        CtxReaper _reap(this, fc);
        bool has_self = !fn->params.empty() && (fn->params[0]->value() == "self" || fn->params[0]->value() == "this");
        if (is_cm) {
            Value cls_val;
            Node* cls_node = self_is_class ? (Node*)self.value.p : classNodeOfInstance(self);
            cls_val.type = ValueType::USERDATA; cls_val.value.p = (void*)cls_node;
            std::vector<Value> a2; a2.push_back(cls_val);
            for (auto& a : args) a2.push_back(a);
            bindParamsKw(fn, a2, kw, fc, ctx, 0, m.value.p);
            // super().m() in a classmethod passes the class on (round 77; it
            // passed nothing, so a base's classmethod got no cls)
            fc->defineByName("\x01first_arg", cls_val);
        } else if (!is_static && !has_self && !self_is_class && fn->name != "__new__") {
            // A method whose first parameter is not self/this (`def m(s)`,
            // `def m(cls)`, `def m(*a)`): the instance is its first
            // argument, as Python binds any function on the class (round
            // 78: it was a plain function).
            std::vector<Value> with_self; with_self.reserve(args.size() + 1);
            with_self.push_back(self);
            for (auto& a : args) with_self.push_back(a);
            bindParamsKw(fn, with_self, kw, fc, ctx, 0, m.value.p);
            fc->defineByName("\x01first_arg", self);
        } else if (is_static || !has_self) {
            bindParamsKw(fn, args, kw, fc, ctx, 0, m.value.p);
            // what super() takes as the receiver in a method whose first
            // parameter is cls / mcs (round 77)
            if (!is_static && !args.empty()) fc->defineByName("\x01first_arg", args[0]);
        } else if (self_is_class) {
            // Class.method(instance, ...)
            if (!args.empty()) {
                fc->defineByName(fn->params[0]->value(), args[0]);
                fc->defineByName("self", args[0]);
                std::vector<Value> rest(args.begin() + 1, args.end());
                bindParamsKw(fn, rest, kw, fc, ctx, 1, m.value.p);
                self = args[0];
            } else bindParamsKw(fn, args, kw, fc, ctx, 1, m.value.p);
        } else {
            fc->defineByName("self", self);
            if (fn->params[0]->value() == "this") fc->defineByName("this", self);
            bindParamsKw(fn, args, kw, fc, ctx, 1, m.value.p);
        }
        auto* ocn = owner ? static_cast<ClassNode*>(owner) : nullptr;
        if (ocn && !ocn->bases.empty())
            fc->defineByName("__parent_class__", internString(ocn->bases[0]->value()));
        OwnerScope _os(owner_stack_, owner);
        return runFunctionBody(fn, fc);
    }
    // super().name(...): `name` from the class after `owner` in the MRO of
    // self's class. Returns false when nothing defines it there.
    // A class deriving from type (a metaclass); cached by node.
    std::unordered_set<const Node*> metaclass_types_;
    bool isMetaclassNode(Node* cn) {
        if (!cn) return false;
        if (metaclass_types_.count(cn)) return true;
        if (classDerivesFrom(static_cast<ClassNode*>(cn)->name, "type")) { metaclass_types_.insert(cn); return true; }
        return false;
    }
    // super().attr / super(C, obj).attr read without a call (round 77; it
    // ran the parent constructor and read the attribute of what that gave):
    // the member after the owner in the MRO, bound as a read binds it - a
    // property's getter runs, a method is bound to self, a classmethod to the
    // class. False: `node` is no super() expression.
    bool superAttribute(AttributeNode* an, Context* ctx, Value& out) {
        Node* obj = an->object.get();
        if (!obj || obj->type() != NodeType::CALL) return false;
        auto* sc = static_cast<CallNode*>(obj);
        if (!sc->callee || sc->callee->type() != NodeType::SUPER || (sc->args.size() != 0 && sc->args.size() != 2)) return false;
        Value self;
        Node* owner = nullptr;
        superArgs(sc, ctx, owner, self);
        return superAttrOf(owner, self, an->attr, ctx, out);
    }
    // super() / super(C, obj): the class after which the MRO is searched
    // and the receiver (round 78: shared by super().attr, super().m(...)
    // and the proxy object super(...) is as a value). Python's TypeErrors.
    void superArgs(CallNode* sc, Context* ctx, Node*& owner, Value& self) {
        if (sc->args.size() > 2)
            pyRaise("TypeError", "super() takes at most 2 arguments (" + std::to_string(sc->args.size()) + " given)");
        if (!sc->args.empty()) {
            Value typ = evalNode(sc->args[0], ctx);
            owner = classNodeOfValue(typ);
            if (!owner) pyRaise("TypeError", "super() argument 1 must be a type, not " + typeNameOf(typ));
            if (sc->args.size() < 2) pyRaise("TypeError", "super(type): unbound super objects are not supported");
            self = evalNode(sc->args[1], ctx);
            Node* st = isInstanceValue(self) ? classNodeOfInstance(self) : classNodeOfValue(self);
            // (a class is also an instance of its metaclass: super(Meta, cls))
            if (!st || (st != owner && !classDerivesFrom(static_cast<ClassNode*>(st)->name, static_cast<ClassNode*>(owner)->name)
                        && !(!isInstanceValue(self) && isMetaclassNode(owner))))
                pyRaise("TypeError", "super(type, obj): obj must be an instance or subtype of type");
        } else {
            if (owner_stack_.empty() || !owner_stack_.back()) pyRaise("RuntimeError", "super(): no arguments");
            owner = owner_stack_.back();
            self = ctx->getByName("self");
            if (self.type == ValueType::UNDEFINED || self.type == ValueType::NONE) {
                Value fa = ctx->getByName("\x01first_arg");
                if (fa.type != ValueType::UNDEFINED) self = fa;
            }
        }
    }
    // The prelude's super proxy class (_NySuper): super(...) used as a
    // value (round 78; it ran the parent's constructor - the shorthand
    // super(args) from before super() existed).
    Node* prelude_super_node_ = nullptr;
    bool any_super_proxy_ = false;
    Node* preludeSuperNode() {
        if (!prelude_super_node_) prelude_super_node_ = classNodeByName("_NySuper");
        return prelude_super_node_;
    }
    bool isSuperProxy(const Value& v) {
        if (!any_super_proxy_ || !isInstanceValue(v) || classNodeOfInstance(v) != preludeSuperNode()) return false;
        // made: its __init__ sets __thisclass__ last
        auto pit = instance_properties.find(v.value.p);
        return pit != instance_properties.end() && pit->second && pit->second->container
               && pit->second->container->count("__thisclass__");
    }
    Value makeSuperProxy(Node* owner, const Value& self, Context* ctx) {
        Node* sn = preludeSuperNode();
        if (!sn) pyRaise("RuntimeError", "super(): the prelude's _NySuper is missing");
        any_super_proxy_ = true;
        std::vector<Value> a{classValueOfNode(owner), self};
        return callFunctionValue(classValueOfNode(sn), a, ctx);
    }
    // proxy -> (owner, receiver)
    void superProxyParts(const Value& p, Node*& owner, Value& self) {
        owner = classNodeOfValue(attrOf(p, "__thisclass__"));
        self = attrOf(p, "__self__");
    }
    bool superAttrOf(Node* owner, const Value& self, const std::string& attr, Context* ctx, Value& out) {
        Node* start = isInstanceValue(self) ? classNodeOfInstance(self) : classNodeOfValue(self);
        if (!start) pyRaise("TypeError", "super(type, obj): obj must be an instance or subtype of type");
        Value m; Node* where = nullptr;
        bool found = findClassMember(start, attr, m, &where, owner);
        if (!found) {
            Node* objn = classNodeByName("object");
            found = objn && objn != owner && findClassMember(objn, attr, m, &where);
        }
        if (!found) found = objectMember(attr, m, &where, start);   // super().__eq__ ... (round 80)
        if (!found) pyRaise("AttributeError", "'super' object has no attribute '" + attr + "'");
        std::string tag = m.type == ValueType::USERDATA && m.value.p ? fnTag(func_names, m.value.p) : std::string();
        Value cls = isInstanceValue(self) ? classValueOfNode(start) : self;
        if (isInstanceValue(m)) {
            if (!descriptorGet(m, isInstanceValue(self) ? self : NONE_VALUE, (void*)start, ctx, out, false, where)) out = m;
            return true;
        }
        if (tag.find("__classmethod__") != std::string::npos) { out = makeBoundClassMethod(m, cls); return true; }
        if (tag.find("__static__") != std::string::npos || !isInstanceValue(self)) { out = m; return true; }
        out = makeBoundMethod(m, self);
        return true;
    }
    // `start_at`: the class whose MRO is searched (super(C, C2): C2's).
    bool superCall(Value self, Node* owner, const std::string& name, std::vector<Value>& args,
                   const nyrt::OrderedKw<Value>& kw, Context* ctx, Value& out, Node* start_at = nullptr) {
        Node* start = start_at ? start_at : isInstanceValue(self) ? classNodeOfInstance(self) : owner;
        if (!start) return false;
        // past a metaclass's own bases is type: type.__new__ / __call__ /
        // __init__ (round 77)
        if (isMetaclassNode(owner) && (name == "__new__" || name == "__call__" || name == "__init__")) {
            Value m0; Node* w0 = nullptr;
            if (!(findClassMember(start, name, m0, &w0, owner) && w0 != classNodeByName("object"))) {
                if (name == "__init__") { out = NONE_VALUE; return true; }
                if (name == "__new__") { out = typeNew(args, kw, ctx); return true; }
                // type.__call__(cls, *args): make the instance, the metaclass's
                // __call__ not run again
                type_call_skip_ = true;
                out = instantiateClass(self, args, kw, ctx);
                return true;
            }
        }
        Value m; Node* where = nullptr;
        // In a metaclass's method the receiver is a class: it is the first
        // argument of what super() finds (super().__setattr__(name, value)
        // in EnumType.__setattr__ - round 77; invokeMember would read the
        // first argument as the receiver).
        bool meta_recv = !isInstanceValue(self) && classNodeOfValue(self) && isMetaclassNode(owner);
        auto invoke = [&](const Value& fm, Node* fw) {
            std::string tg = fnTag(func_names, fm.value.p);
            if (meta_recv && tg.find("__static__") == std::string::npos && tg.find("__classmethod__") == std::string::npos) {
                std::vector<Value> a2;
                a2.reserve(args.size() + 1);
                a2.push_back(self);
                for (auto& x : args) a2.push_back(x);
                return invokeMember(fm, fw, self, a2, kw, ctx);
            }
            return invokeMember(fm, fw, self, args, kw, ctx);
        };
        if (findClassMember(start, name, m, &where, owner) && m.type == ValueType::USERDATA && m.value.p
            && func_names.count(m.value.p)) {
            out = invoke(m, where);
            return true;
        }
        if (name == "__init__" || name == "init") {
            std::string other = name == "init" ? "__init__" : "init";
            if (findClassMember(start, other, m, &where, owner) && m.type == ValueType::USERDATA && m.value.p
                && func_names.count(m.value.p)) {
                out = invokeMember(m, where, self, args, kw, ctx);
                return true;
            }
            // Reaching a builtin exception base sets the exception's args;
            // reaching object, nothing.
            if (isInstanceValue(self) && isExceptionClass(instanceClassName(self))) { setExceptionArgs(self, args); setExceptionKw(self, kw); }
            // round 81: object.__init__ given arguments - its errors (the
            // prelude's object.__init__ checks CPython's rules)
            else if (!args.empty() || !kw.empty())
                if (Node* objn = classNodeByName("object"))
                    if (findClassMember(objn, "__init__", m, &where) && m.type == ValueType::USERDATA && m.value.p && func_names.count(m.value.p)) {
                        out = invoke(m, where);
                        return true;
                    }
            out = NONE_VALUE;
            return true;
        }
        // Past the last base is object (every class's implicit root):
        // super().__setattr__(k, v) and the like (round 77); its other
        // members too - super().__eq__(o), super().__repr__() (round 80)
        if (Node* objn = classNodeByName("object")) {
            if ((findClassMember(objn, name, m, &where) || objectMember(name, m, &where, start))
                && m.type == ValueType::USERDATA && m.value.p && func_names.count(m.value.p)) {
                out = invoke(m, where);
                return true;
            }
        }
        return false;
    }
    // Builtins that take an iterable, given an object with __iter__ /
    // __next__ / __getitem__: its items first. sorted/min/max over objects
    // order by __lt__ (or the other side's __gt__), sum adds with __add__ /
    // __radd__, issubclass walks the MRO, hash() uses __hash__.
    // A function body run to completion: its value. A generator function's
    // body does not run here: the call makes the generator, which runs the
    // body on a coroutine of its own, a step per next() (src/NyGen.cpp).
    // `pend` (round 82): the call site checks the pending flag right after
    // (evalP), so an exception leaving the body - by the flag or thrown - is
    // handed on by the flag once the frame has recorded it; else thrown.
    Value runFunctionBody(FunctionNode* fn, Context* fc, bool pend = false) {
        // whether the body yields, remembered by the def (round 81: a hash
        // lookup per call)
        if (__builtin_expect(fn->body_yields < 0, 0)) fn->body_yields = bodyYields(fn->body) ? 1 : 0;
        if (fn->body_yields) return nygen::make_function_gen(*this, fn, fc);
        // Calls that do not pass through evalCall (operators, callbacks of
        // builtins) meet the same stack check (see evalCall).
        // (round 81: on the thread's own stack too - and the recursion
        // limit holds here, for frames that evalCall does not count: a
        // __eq__ that compares with itself crashed the interpreter)
        if (py_frames().size() >= (size_t)nyrt::recursion_limit())
            throw std::string("__exc__:RecursionError:maximum recursion depth exceeded");
        if (nycoro::stack_exhausted() || (!nycoro::current() && nycoro::native_stack_exhausted()))
            return nygen::body_on_new_stack(*this, fn, fc);
        FrameGuard _frame(fn, fc);   // round 77: frames and tracebacks
        // sys.settrace / sys.setprofile (round 79): one test per call
        if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0) && !tbHiddenFile(fn->tok().fileName())) return runBodyHooked(fn, fn->body, fc, true);
        try { return evalBody(fn->body, fc, pend); }   // round 82: pend - see evalBody
        catch (nython::node::ReturnSignal& rs) { return rs.value; }
        catch (std::string& flow) {
            if (tbUnwound()) tbUnwound() = false;   // round 82: evalBody recorded it
            else tbUnwind(flow);
            if (pend && !isLoopFlow(flow)) { pendExc(flow); return NONE_VALUE; }   // round 82
            throw;
        }
        catch (std::exception& e) { tbUnwind(excFromCpp(e.what())); throw; }
    }
    // A lambda's body (round 77: a frame of its own, "<lambda>").
    Value runLambdaBody(LambdaNode* lam, Context* fc) {
        FrameGuard _frame(lam, fc);
        if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0) && !tbHiddenFile(lam->tok().fileName())) return runBodyHooked(lam, lam->body, fc, false);   // round 79
        try { return evalNode(lam->body, fc); }
        catch (std::string& flow) { tbUnwind(flow); throw; }
        catch (std::exception& e) { tbUnwind(excFromCpp(e.what())); throw; }
    }
    // A function's (or lambda's, or exec'd code's) body with the trace and
    // profile events around it (round 79): its frame record is the
    // innermost one (the caller's FrameGuard). `fn_body`: a def's body,
    // whose value is what `return` gave; else an expression / a module's
    // statements, whose value is the result.
    Value runBodyHooked(Node* code, const node_ptr& body, Context* fc, bool fn_body) {
        size_t idx = py_frames().size() - 1;
        if (code) cur_stmt() = code;   // the call event's f_lineno: the def line
        pyEvCall(idx);
        if (code && code->type() == NodeType::LAMBDA && (nytrace::t_hooks & nytrace::TRACE)) pyEvLine(code);   // a lambda's one line
        Value result;
        try { result = fn_body ? evalBody(body, fc) : evalNode(body, fc); }
        catch (nython::node::ReturnSignal& r) { result = r.value; }
        catch (std::string& flow) {
            if (tbUnwound()) tbUnwound() = false;   // round 82: evalBody recorded it
            else tbUnwind(flow);
            pyEvLeave(flow, idx);
            throw;
        }
        catch (std::exception& e) { std::string f = excFromCpp(e.what()); tbUnwind(f); pyEvLeave(f, idx); throw; }
        // round 82: raised by the pending flag - as the catch above, thrown
        if (FlowState& f = flow(); __builtin_expect(f.pending == kPendExc, 0)) {
            std::string e = takeExc(f);
            tbUnwind(e);
            pyEvLeave(e, idx);
            throw e;
        }
        if (nytrace::t_hooks & nytrace::ANY) pyEvReturn(idx, result);
        return result;
    }
    bool iterableBuiltin(const std::string& name, std::vector<Value>& args, Context* ctx, Value& out) {
        static const std::unordered_set<std::string> takes = {
            "list","tuple","set","sorted","min","max","sum","any","all","enumerate","zip","frozenset"};   // reversed: pycore's (round 78)
        if (name == "issubclass" && args.size() >= 2) {
            auto cls_name = [&](const Value& v) -> std::string {
                if (v.type == ValueType::USERDATA && v.value.p) {
                    std::string t = fnTag(func_names, v.value.p);
                    if (t.rfind("__class__:", 0) == 0) return t.substr(10);
                    if (t.rfind("__builtin__:", 0) == 0) return t.substr(12);
                    if (t.rfind("__rtype__:", 0) == 0) return t.substr(10);   // NoneType, function ... (round 77)
                    if (isStringValue(v)) return getStringValue(v);
                }
                return std::string();
            };
            // issubclass(C, (A, B)): any of them, each asked as itself - an
            // ABC's __subclasscheck__ too (round 77)
            if (!classNodeOfValue(args[1]) && !isInstanceVal(args[1])) {
                Container* tc = contOf(args[1]);
                if (tc && seqLen(tc) >= 0) {
                    for (auto& t : listItems(args[1])) {
                        std::vector<Value> one{args[0], t};
                        Value r;
                        if (iterableBuiltin(name, one, ctx, r) && isTruthy(r)) { out = Value(true); return true; }
                    }
                    out = Value(false); return true;
                }
            }
            // a metaclass's __subclasscheck__ (round 77)
            if (!class_meta_.empty() && classNodeOfValue(args[1])) {
                Value r;
                if (metaCall(args[1], "__subclasscheck__", {args[0]}, ctx, r)) { out = Value(isTruthy(r)); return true; }
            }
            // an object whose class defines __subclasscheck__ (round 77)
            if (isInstanceValue(args[1]) && instanceHasMethod(args[1], "__subclasscheck__")) {
                std::vector<Value> one{args[0]};
                out = Value(isTruthy(callMethod(args[1], "__subclasscheck__", one, ctx)));
                return true;
            }
            std::string c = cls_name(args[0]);
            if (c.empty()) { out = Value(false); return true; }
            std::vector<Value> targets;
            auto items = listItems(args[1]);
            if (!items.empty()) targets = items; else targets.push_back(args[1]);
            for (auto& t : targets) {
                std::string tn = cls_name(t);
                if (!tn.empty() && (tn == "object" || tn == "Object" || classDerivesFrom(c, tn) || nyrt::builtin_type_derives(c, tn))) { out = Value(true); return true; }
            }
            out = Value(false); return true;
        }
        if (name == "hash" && !args.empty() && isInstanceValue(args[0]) && instanceHasMethod(args[0], "__hash__")) {
            checkHashable(args[0]);
            std::vector<Value> none;
            out = callMethod(args[0], "__hash__", none, ctx);
            // an int, as Python checks it (round 78)
            if (out.type == ValueType::BOOLEAN) out = intValue(out.value.b ? 1 : 0);
            else if (out.type != ValueType::INTEGER) pyRaise("TypeError", "__hash__ method should return an integer");
            return true;
        }
        if (name == "bool" && args.size() == 1 && isInstanceValue(args[0])) { out = Value(isTruthy(args[0])); return true; }
        // iter(x) and next(it[, default]). Generators are handled first, by
        // nygen::builtin; iter() of a list, string, dict, set or range makes
        // a lazy iterator (nygen::make_iter), and objects go through
        // __iter__/__next__.
        // hasattr / getattr on instances and classes: the full attribute
        // lookup (methods, class attributes, properties, __getattr__); only
        // an instance's own fields were seen.
        // hasattr / getattr / setattr / delattr, for every kind of value, as
        // in Python: hasattr and getattr with a default see an AttributeError
        // (a missing attribute, or one a property / __getattr__ raises) as
        // absence; other errors propagate.
        if ((name == "hasattr" || name == "getattr" || name == "setattr" || name == "delattr") && args.size() >= 2) {
            if (!isStringValue(args[1]))
                pyRaise("TypeError", name + "(): attribute name must be string, not '" + typeNameOf(args[1]) + "'");
            std::string an = getStringValue(args[1]);
            if (name == "setattr") {
                if (args.size() != 3) pyRaise("TypeError", "setattr expected 3 arguments, got " + std::to_string(args.size()));
                setAttr(args[0], an, args[2]);
                out = NONE_VALUE; return true;
            }
            if (name == "delattr") {
                if (args.size() != 2) pyRaise("TypeError", "delattr expected 2 arguments, got " + std::to_string(args.size()));
                delAttrValue(args[0], an);
                out = NONE_VALUE; return true;
            }
            if (args.size() > 3 || (name == "hasattr" && args.size() != 2))
                pyRaise("TypeError", name + " expected " + (name == "hasattr" ? "2" : "at most 3") + " arguments, got " + std::to_string(args.size()));
            Value v;
            bool has;
            try { has = getAttrValue(args[0], an, ctx, v); }
            catch (std::string& e) {
                // getattr(o, n) without a default raises the AttributeError a
                // property's getter or __getattr__ raised (round 77)
                if (!excTypeMatches(e, "AttributeError") || (name == "getattr" && args.size() == 2)) throw;
                has = false;
            }
            if (name == "hasattr") { out = Value(has); return true; }
            if (has) { out = v; return true; }
            if (args.size() >= 3) { out = args[2]; return true; }
            throw std::string("__exc__:AttributeError:" + attributeErrorText(args[0], an));
        }
        if (name == "callable" && args.size() == 1) {
            const Value& v = args[0];
            bool r = isFunctionValue(v);
            if (!r && v.type == ValueType::USERDATA && v.value.p) {
                if (fnTag(func_names, v.value.p).rfind("__class__:", 0) == 0) r = true;
                else if (isInstanceValue(v)) r = instanceHasMethod(v, "__call__");
            }
            out = Value(r); return true;
        }
        // iter(callable, sentinel): calls it until it returns the sentinel
        // (round 77, a lazy callable_iterator)
        if (name == "iter" && args.size() == 2) {
            std::vector<Value> ca{args[0]};
            if (!isTruthy(callBuiltin("callable", ca, ctx))) pyRaise("TypeError", "iter(v, w): v must be callable");
            out = nygen::make_callable_iter(*this, args[0], args[1]);
            return true;
        }
        if (name == "iter" && args.size() > 2) pyRaise("TypeError", "iter expected at most 2 arguments, got " + std::to_string(args.size()));
        // The engines' range and dict-view iterators (round 78): what the
        // prelude's range.__iter__ / __reversed__ and the views' use. A
        // range past 64-bit ints gets none (the prelude's generator).
        if (name == "_ny_range_iter" && args.size() == 3) {
            int64_t f, s, n;
            bool ok = true;
            for (auto& a : args) ok = ok && a.type == ValueType::INTEGER;
            if (ok && bigint_fits_i64(args[0].value.i, f) && bigint_fits_i64(args[1].value.i, s)
                && bigint_fits_i64(args[2].value.i, n) && nyrt::range_iter_fits(f, s, n))
                out = nygen::make_range_iter(*this, f, s, n);
            else out = NONE_VALUE;
            return true;
        }
        if (name == "_ny_dict_iter" && args.size() == 3) {
            Num k;
            int kind = asNum(args[1], k) && k.k == 1 && k.i >= 0 && k.i <= 2 ? (int)k.i : 0;
            Value d = args[0], p;
            if (any_payload_ && payloadOf(d, p)) d = p;
            out = nygen::make_dict_iter(*this, d, kind, isTruthy(args[2]));
            return true;
        }
        if (name == "iter" && !args.empty()) {
            const Value& v = args[0];
            if (nygen::is_gen(v)) { out = v; return true; }
            // a range or a dict view: its native iterator (round 78)
            if (isRangeValue(v) || viewOf(v, nullptr) >= 0) { out = nygen::make_iter(*this, v, ctx); return true; }
            if (isInstanceValue(v)) {
                std::vector<Value> none;
                if (instanceHasMethod(v, "__iter__")) {
                    out = callMethod(v, "__iter__", none, ctx);
                    // an iterator, as Python checks it (round 78)
                    if (!nygen::is_gen(out) && !(isInstanceValue(out) && instanceHasMethod(out, "__next__")))
                        pyRaise("TypeError", "iter() returned non-iterator of type '" + typeNameOf(out) + "'");
                    return true;
                }
                if (instanceHasMethod(v, "__next__")) { out = v; return true; }
                if (!instanceHasMethod(v, "__getitem__"))
                    throw std::string("__exc__:TypeError:'" + shownClassName(instanceClassName(v)) + "' object is not iterable");
            }
            // A lazy iterator over a list, string, dict, set or range.
            out = nygen::make_iter(*this, v, ctx);
            return true;
        }
        if (name == "next" && !args.empty()) {
            if (isInstanceValue(args[0])) {
                if (!instanceHasMethod(args[0], "__next__"))
                    throw std::string("__exc__:TypeError:'" + shownClassName(instanceClassName(args[0])) + "' object is not an iterator");
                std::vector<Value> none;
                try { out = callMethod(args[0], "__next__", none, ctx); }
                catch (std::string& e) {
                    if (args.size() >= 2 && excTypeMatches(e, "StopIteration")) { out = args[1]; return true; }
                    throw;
                }
                return true;
            }
            throw std::string("__exc__:TypeError:'" + typeNameOf(args[0]) + "' object is not an iterator");
        }
        if (!takes.count(name) || args.empty()) return false;
        size_t upto = (name == "zip") ? args.size() : 1;
        bool changed = false;
        for (size_t i = 0; i < upto && i < args.size(); i++) {
            // a range or a dict view is read natively where it is used (round 78)
            if (isRangeValue(args[i]) || viewOf(args[i], nullptr) >= 0) continue;
            if (isInstanceValue(args[i]) && (instanceHasMethod(args[i], "__iter__") || instanceHasMethod(args[i], "__next__")
                                             || instanceHasMethod(args[i], "__getitem__"))) {
                args[i] = makeListValue(iterValues(args[i], ctx));
                changed = true;
            }
        }
        (void)changed;
        if ((name == "set" || name == "frozenset") && args.size() == 1) {
            // set_key keys an object with __hash__ by it (round 77)
            out = build_set_val(iterItems(args[0], ctx), name == "frozenset");
            return true;
        }
        // sorted / min / max / sum over objects: pycore's, which order
        // through orderValues (__lt__, reflected __gt__) and add through
        // binaryOp (__add__ / __radd__), with key=, reverse= and default=.
        return false;
    }
    bool isFunctionValue(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        std::string t = fnTag(func_names, v.value.p);
        return t.rfind("__func__:", 0) == 0 || t.rfind("__lambda__", 0) == 0 || t.rfind("__builtin__:", 0) == 0 || t.rfind("__bmethod__:", 0) == 0
            || t.rfind("__rtype__:", 0) == 0;
    }
    bool isCallableValue(const Value& v) {
        if (isFunctionValue(v)) return true;
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        if (fnTag(func_names, v.value.p).rfind("__class__:", 0) == 0) return true;
        return isInstanceValue(v) && instanceHasMethod(v, "__call__");
    }
    // Runs the constructor of a new instance: the first class in its MRO
    // that defines __init__ or init.
    void runConstructor(Value inst, std::vector<Value>& args,
                        const nyrt::OrderedKw<Value>& kw, Context* ctx, bool own_new = false) {
        Node* cls = classNodeOfInstance(inst);
        if (!cls) return;
        Node* objn = classNodeByName("object");
        for (Node* c : classMro(cls)) {
            // round 81: object's own __init__ (it does nothing) is not called
            if (c == objn) break;
            auto cit = class_ctx_map_.find((void*)c);
            if (cit == class_ctx_map_.end() || !cit->second || !cit->second->container) continue;
            auto& cont = *cit->second->container;
            auto it = cont.find("__init__");
            if (it == cont.end()) it = cont.find("init");
            if (it == cont.end()) continue;
            if (it->second.type != ValueType::USERDATA || !it->second.value.p || !func_names.count(it->second.value.p)) continue;
            invokeMember(it->second, c, inst, args, kw, ctx);
            return;
        }
        // round 81: neither __init__ nor __new__ of its own, and arguments:
        // CPython's object_new - "P() takes no arguments" (an exception
        // class takes any)
        if (!own_new && (!args.empty() || !kw.empty())) {
            std::string cn = static_cast<ClassNode*>(cls)->name;
            if (!isExceptionClass(cn))
                pyRaise("TypeError", nyrt::bare_class_name(shownClassName(cn)) + "() takes no arguments");
        }
    }
    // Calls method `name` of an instance (or a class) through the class
    // namespaces and the MRO. Returns false when no class defines it.
    bool callClassMethod(Value obj, const std::string& name, std::vector<Value>& args,
                         const nyrt::OrderedKw<Value>& kw, Context* ctx, Value& out) {
        Node* cls = isInstanceValue(obj) ? classNodeOfInstance(obj) : nullptr;
        if (!cls && obj.type == ValueType::USERDATA && obj.value.p
            && fnTag(func_names, obj.value.p).rfind("__class__:", 0) == 0) {
            Node* n = (Node*)obj.value.p;
            if (n && n->type() == NodeType::CLASS) cls = n;
        }
        if (!cls) return false;
        Value m; Node* owner = nullptr;
        if (!findClassMember(cls, name, m, &owner)) return false;
        // a class attribute that is a number, a string, bytes, None or a
        // plain container is not callable (round 80: C.label() gave none)
        if (m.type == ValueType::INTEGER || m.type == ValueType::DOUBLE || m.type == ValueType::BOOLEAN
            || m.type == ValueType::NONE || bytesOf(m) || (isStringValue(m) && !func_names.count(m.value.p))
            || (contOf(m) && !isInstanceValue(m)))
            pyRaise("TypeError", "'" + typeNameOf(m) + "' object is not callable");
        if (m.type != ValueType::USERDATA || !m.value.p) return false;
        {
            // a descriptor (partialmethod, singledispatchmethod...): what its
            // __get__ gives is called
            Value got;
            void* owner_ptr = isInstanceValue(obj) ? instance_to_class[obj.value.p] : obj.value.p;
            if (descriptorGet(m, obj, owner_ptr, ctx, got, false, owner)) { out = callFunctionValue(got, args, ctx, &kw); return true; }
        }
        std::string tag = fnTag(func_names, m.value.p);
        if (tag.rfind("__func__:", 0) != 0 && tag.rfind("__lambda__", 0) != 0) {
            // A class stored in the class (Outer.Inner(...)) or a builtin.
            if (tag.rfind("__class__:", 0) == 0 || tag.rfind("__builtin__:", 0) == 0) {
                out = callFunctionValue(m, args, ctx);
                return true;
            }
            // round 80: any other callable a class holds - a builtin's bound
            // member (`__next__ = gen.__next__`), a bound method, an object
            // with __call__ - is called as it is, no self added (as Python;
            // the older path below read it as a function's AST node and
            // crashed)
            if (tag.find("__property__") == std::string::npos
                && (bound_members_.count(m.value.p) || bound_self_.count(m.value.p) || isInstanceValue(m) || !tag.empty())) {
                out = callFunctionValue(m, args, ctx, &kw);
                return true;
            }
            return false;
        }
        if (tag.find("__property__") != std::string::npos) return false;
        out = invokeMember(m, owner, obj, args, kw, ctx);
        return true;
    }

    // The class value of an exception string's type (the class itself for a
    // user class, the builtin for a builtin exception), for __exit__.
    Value exceptionClassValue(const std::string& flow) {
        std::string t = excTypeOf(flow);
        if (t.empty()) t = "Exception";
        Node* cn = classNodeByName(t);
        if (cn) { Value cv; cv.type = ValueType::USERDATA; cv.value.p = (void*)cn; return cv; }
        Value bv = global_ctx->getByName(t);
        return bv.type == ValueType::UNDEFINED ? makeStringValue(t) : bv;
    }

    // with E as x: body. __enter__'s result is bound (the object itself when
    // it has none); __exit__ runs on every way out, with (type, value, none)
    // for an exception - a truthy result suppresses it - and (none, none,
    // none) otherwise. It used to be called with no arguments at all, and
    // its result was ignored.
    Value evalWith(const node_ptr& node, Context* ctx, bool fast = false) {
        auto* wn = static_cast<WithNode*>(node.get());
        Value v = evalNode(wn->expr, ctx);
        bool managed = isInstanceValue(v);
        Value ctx_val = v;
        if (managed && instanceHasMethod(v, "__enter__")) {
            std::vector<Value> no_args;
            ctx_val = callMethod(v, "__enter__", no_args, ctx);
        }
        if (!wn->alias.empty()) (wn->alias_global ? moduleCtx(ctx) : ctx)->defineByName(wn->alias, ctx_val);
        auto exit_plain = [&]() {
            if (!managed || !instanceHasMethod(v, "__exit__")) return;
            std::vector<Value> a{NONE_VALUE, NONE_VALUE, NONE_VALUE};
            callMethod(v, "__exit__", a, ctx);
        };
        // __exit__(type, value, traceback): the exception object with the
        // traceback it has here; not suppressed, it goes on from this frame
        // as a re-raise (round 77).
        auto exit_exc = [&](std::string& flow) -> bool {
            if (!managed || !instanceHasMethod(v, "__exit__")) return false;
            flow = tbCaught(flow);
            Value ev = exceptionObject(flow);
            Value tb = NONE_VALUE;
            if (Context* ep = instanceProps(ev)) { tb = ep->getByName("__traceback__"); if (!isInstanceVal(tb)) tb = NONE_VALUE; }
            std::vector<Value> a{exceptionClassValue(flow), ev, tb};
            bool sup = isTruthy(callMethod(v, "__exit__", a, ctx));
            if (!sup) tbReraise(flow);
            return sup;
        };
        Value result = NONE_VALUE;
        // round 82: an exception __exit__ does not suppress goes on by the
        // pending flag where the statement may leave by it
        const bool may_pend = fast && canPend(ctx);
        try {
            result = evalNode(wn->body, ctx);
        }
        catch (nython::node::ReturnSignal&) { exit_plain(); throw; }
        catch (nython::node::YieldSignal&) { throw; }
        catch (std::string& flow) {
            if (flow == "break" || flow == "continue") { exit_plain(); throw; }
            std::string f = flow;
            if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) pyEvException(f);   // round 79
            if (exit_exc(f)) return NONE_VALUE;
            if (may_pend) { pendExc(std::move(f)); return NONE_VALUE; }   // round 82
            throw f;
        }
        catch (std::exception& e) {
            std::string flow = excFromCpp(e.what());
            if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) pyEvException(flow);   // round 79
            if (exit_exc(flow)) return NONE_VALUE;
            throw flow;
        }
        // round 81 (`fast`): a return/break/continue left the body by the
        // pending flag - __exit__(None, None, None) runs with it cleared (it
        // is a call, whose body must not see it), as for the thrown flow
        if (fast) {
            FlowState& fl = flow();
            if (fl.pending == kPendExc) {
                // round 82: an exception left the body by the flag - taken
                // out of it while __exit__ runs, as the catch above does
                std::string f = takeExc(fl);
                if (__builtin_expect(nytrace::t_hooks & nytrace::ANY, 0)) pyEvException(f);
                if (exit_exc(f)) return NONE_VALUE;
                pendExc(std::move(f));
                return NONE_VALUE;
            }
            if (fl.pending) {
                int p = fl.pending;
                Value pv = std::move(fl.value);
                fl.pending = 0;
                fl.value = NONE_VALUE;
                exit_plain();
                fl.pending = p;
                fl.value = std::move(pv);
                return result;
            }
        }
        // sys.settrace: the with statement's line again as it exits (round 79)
        if (__builtin_expect(nytrace::t_hooks & nytrace::TRACE, 0)) pyEvLineAt(node.get());
        exit_plain();
        return result;
    }

    Value evalNamespace(const node_ptr& node, Context* ctx) {
        auto nn = static_pointer_cast<NameSpaceNode>(node);
        Context* ns_ctx = new Context(runner, nn->name, nullptr, nullptr, ctx);
        CtxReaper _ns_creator(this, ns_ctx);   // its functions hold their own references
        if (nn->body) evalNode(nn->body, ns_ctx);
        // The body ran in ns_ctx, but ns_ctx itself was never exposed under
        // the namespace's own name in the OUTER scope - `namespace ns: var
        // thing = 42` left `ns` completely undefined outside the block, so
        // `ns.thing` always read none. Collect the namespace's own
        // top-level names (matching how `import "m" as alias` builds its
        // namespace map elsewhere in this file) into a map bound to its
        // name, so it can actually be used from outside.
        auto* obj = new Object((Runnable*)runner, nn->name, Type::MAP);
        noteNamespace(obj);
        if (nn->body) {
            for (auto& stmt : nn->body->statements()) {
                std::string member_name;
                if (stmt->type() == NodeType::VARIABLE_DECL)
                    member_name = static_pointer_cast<VarDeclNode>(stmt)->name;
                else if (stmt->type() == NodeType::FUNCTION)
                    member_name = static_pointer_cast<FunctionNode>(stmt)->name;
                else if (stmt->type() == NodeType::CLASS)
                    member_name = static_pointer_cast<ClassNode>(stmt)->name;
                if (member_name.empty()) continue;
                try { (*obj->container)[member_name] = ns_ctx->getByName(member_name); }
                catch (...) {}
            }
        }
        (*obj->container)["__name__"] = makeStringValue(nn->name);
        (*obj->container)["__type__"] = makeStringValue("namespace");
        Value ns_val((Collectable*)obj);
        ctx->defineByName(nn->name, ns_val);
        return ns_val;
    }

    // ─── HELPER ─────────────────────────────────────────────────────────
    // Python truthiness: none, false, 0, 0.0, "" and empty containers are
    // false; an instance asks its __bool__, then its __len__.
    bool isTruthy(const Value& v) {
        switch (v.type) {
            case ValueType::NONE: case ValueType::UNDEFINED: return false;
            case ValueType::BOOLEAN: return v.value.b;
            case ValueType::INTEGER: { for (auto l : v.value.i.limbs()) if (l) return true; return false; }
            case ValueType::DOUBLE: return v.value.d != 0.0;
            case ValueType::USERDATA:
                if (!v.value.p) return false;
                if (string_ptrs_.count(v.value.p)) return !static_cast<std::string*>(v.value.p)->empty();
                if (instance_to_class.count(v.value.p)) return instanceTruthy(v);
                if (func_names.count(v.value.p)) return true;
                return !static_cast<std::string*>(v.value.p)->empty();
            default: break;
        }
        if (nygen::is_gen(v)) return true;   // lazy: no length to test
        if (Container* c = contOf(v)) {
            int64_t n = seqLen(c);
            if (n >= 0) return n != 0;
            for (auto& kv : *c->container)
                if (!(kv.first.size() >= 2 && kv.first[0] == '_' && kv.first[1] == '_')) return true;
            return false;
        }
        return v.isCollectable() ? v.value.gc != nullptr : true;
    }
    // ── Heap objects: side tables, finalizers, teardown (round 75) ─────────
    // The heap object behind each function identity (not owning), so a
    // value can be rebuilt from a bare pointer (a property getter named by a
    // setter's builtin tag) with its reference.
    std::unordered_map<void*, nython::gc::Collectable*> heap_owner_;
    bool finalizers_off_ = false;   // teardown: no __del__
    Value ownedValue(void* p) {
        auto it = heap_owner_.find(p);
        if (it != heap_owner_.end()) return nyheap::userValue(it->second, p);
        Value v; v.type = ValueType::USERDATA; v.value.p = p;
        return v;
    }
    // A function object is being freed: everything keyed by its identity goes.
    void forgetFunction(void* p) {
        func_names.erase(p);
        closure_contexts.erase(p);
        func_ast_nodes.erase(p);
        value_closure_id.erase(p);
        heap_owner_.erase(p);
        // Released after the table no longer lists them: releasing a default
        // can free more functions, which erase their own entries.
        std::vector<Value> dead_defaults;
        auto dit = fn_defaults_val_.find(p);
        if (dit != fn_defaults_val_.end()) { dead_defaults.swap(dit->second); fn_defaults_val_.erase(dit); }
        Value dead_setter;
        auto sit = prop_setters_.find(p);
        if (sit != prop_setters_.end()) { dead_setter = sit->second; prop_setters_.erase(sit); }
        // f.attr = v: the attributes go with the function; a new function
        // at this address must not inherit them.
        std::unordered_map<std::string, Value> dead_attrs;
        auto fa = func_attrs_.find(p);
        if (fa != func_attrs_.end()) { dead_attrs.swap(fa->second); func_attrs_.erase(fa); }
    }
    void forgetBound(nyheap::Bound* b) {
        void* p = (void*)&b->tag;
        func_names.erase(p);
        func_ast_nodes.erase(p);
        closure_contexts.erase(p);
        bound_self_.erase(p);
        auto ck = std::make_pair(b->key_fn, b->key_self);
        auto cit = bound_cache_.find(ck);
        if (cit != bound_cache_.end() && cit->second == b) bound_cache_.erase(cit);
    }
    void forgetInstance(void* p) {
        instance_to_class.erase(p);
        func_names.erase(p);
        instance_properties.erase(p);
        if (!dict_views_.empty()) forgetDictView(p);   // round 77
    }
    // weakref(): its objects by id, for the builtin tag that calls them.
    std::unordered_map<int64_t, nyheap::Weak*> weak_by_id_;
    int64_t weak_serial_ = 0;
    void forgetWeak(nyheap::Weak* w) {
        func_names.erase((void*)&w->tag);
        weak_by_id_.erase(w->id);
    }
    Value makeWeakRef(const Value& obj, const Value& callback = Value()) {
        // What can be weakly referenced (round 78, as in Python): an
        // instance, a function or lambda, a bound method (heap objects with
        // an identity), a set or frozenset (its container), a class - which
        // lives as long as the program, so the reference holds it. Not an
        // int, str, list, tuple, dict or bytes.
        bool heap = obj.type == ValueType::USERDATA && obj.value.p && obj.value.o
                    && (isInstanceVal(obj) || isPlainFunction(obj) || bound_self_.count(obj.value.p));
        bool coll = !heap && obj.isCollectable() && obj.value.gc && setOf(obj) != nullptr;
        bool cls = !heap && !coll && classNodeOfValue(obj) != nullptr;
        if (!heap && !coll && !cls)
            pyRaise("TypeError", "cannot create weak reference to '" + typeNameOf(obj) + "' object");
        nygc::g_weak_hook = &nyheap::weak_target_died;
        nygc::g_weak_cb_hook = &nyheap::run_weak_callbacks;
        auto* w = new nyheap::Weak(this, ++weak_serial_);
        if (cls) { w->held = obj; w->has_held = true; }
        else {
            w->target = coll ? obj.value.gc : obj.value.o;
            w->payload = coll ? nullptr : obj.value.p;
            w->coll = coll;
            nyheap::weak_register(w);
        }
        weak_by_id_[w->id] = w;
        func_names[(void*)&w->tag] = "__builtin__:" + w->tag;
        Value wv = nyheap::userValue(w, (void*)&w->tag);
        if (callback.type != ValueType::NONE && callback.type != ValueType::UNDEFINED) {
            w->callback = callback;   // round 77
            nygc::track(w);
        }
        return wv;
    }
    // A weak reference's callback, its target dead (round 77): called once
    // with the reference; what it raises is reported and ignored, as in Python.
    void runWeakCallback(nyheap::Weak* w) {
        Value cb = w->callback;
        w->callback = Value();
        if (cb.type == ValueType::NONE || cb.type == ValueType::UNDEFINED) return;
        Value self = nyheap::userValue(w, (void*)&w->tag);
        node_ptr saved_stmt = last_stmt();
        std::vector<Value> a{self};
        try { callFunctionValue(cb, a, global_ctx); }
        catch (std::string& flow) { std::cerr << "Exception ignored in: " << valueToDisplay(cb) << "\n" << describeException(flow) << "\n"; }
        catch (nython::node::ReturnSignal&) {}
        catch (std::exception& e) { std::cerr << "Exception ignored in: " << valueToDisplay(cb) << "\n" << e.what() << "\n"; }
        catch (...) {}
        last_stmt() = saved_stmt;
    }
    // Whether instances of this class run __del__ when they are freed.
    std::unordered_map<void*, bool> has_del_;
    bool classHasFinalizer(void* cls) {
        if (finalizers_off_ || !cls) return false;
        auto it = has_del_.find(cls);
        if (it != has_del_.end()) return it->second;
        bool d = classDefines(cls, "__del__");
        has_del_[cls] = d;
        return d;
    }
    // __del__, at a safe point (NyGC.hpp): with the instance alive again for
    // the call. An exception it raises is reported and ignored, as in Python.
    void runFinalizer(nyheap::Inst* in) {
        Value self = nyheap::userValue(in, (void*)&in->tag);
        node_ptr saved_stmt = last_stmt();
        std::vector<Value> no_args;
        try { callMethod(self, "__del__", no_args, global_ctx); }
        catch (std::string& flow) {
            std::cerr << "Exception ignored in: <function " << instanceClassName(self) << ".__del__>\n"
                      << describeException(flow) << "\n";
        }
        catch (nython::node::ReturnSignal&) {}
        catch (std::exception& e) {
            std::cerr << "Exception ignored in: <function " << instanceClassName(self) << ".__del__>\n" << e.what() << "\n";
        }
        catch (...) {}
        last_stmt() = saved_stmt;
    }
    // Statement boundaries are the safe points: queued finalizers run and
    // due collections happen here (one load when there is nothing to do).
    static inline void gcSafePoint() { nygc::safe_point(); }

    // The executor is going away: release what it holds for the program (the
    // global scope, class bodies, class variables, raised exceptions, dict
    // key objects) so reference counting and a last collection free the
    // program's objects while the side tables they clean up still exist.
    // No finalizer runs during teardown (on the VM neither).
    void heapTeardown() {
        if (!global_ctx) return;
        // Objects whose last reference went with the program's last statement
        // still get their __del__ (there was no statement boundary after it).
        nygc::safe_point();
        finalizers_off_ = true;
        {
            std::vector<Value> dead;
            for (auto& kv : exc_instance_map_) dead.push_back(kv.second);
            exc_instance_map_.clear();
            exc_ring_.clear();
            handling_obj_.clear();
            dead.push_back(pending_ctx_);   // round 77
            pending_ctx_ = Value();
            dead.push_back(uncaught_obj_);
            uncaught_obj_ = Value();
            for (auto& kv : pyhooks_) { dead.push_back(kv.second.trace); dead.push_back(kv.second.profile); }   // round 79
            pyhooks_.clear();
            nytrace::t_hooks = 0;
            dead.push_back(pyt_exc_obj_);
            pyt_exc_obj_ = Value();
            if (main_fobj_) {   // round 78
                dead.push_back(instValue(main_fobj_));
                nygc::decref(main_fobj_);
                main_fobj_ = nullptr;
            }
            for (auto& r : tb_pending().recs) dead.push_back(r.frame);   // their frame objects (round 78)
            tb_pending().recs.clear();
            pending_ctx_flow_.clear();
            for (auto& kv : frame_info_memo_) dead.push_back(kv.second.info);   // round 78
            frame_info_memo_.clear();
            for (auto& kv : key_objs_) dead.push_back(kv.second);
            key_objs_.clear();
            if (keys_owner_ == this) { keys_owner_ = nullptr; nygc::g_keys = nygc::KeyTable(); }
            for (auto& kv : class_vars_) dead.push_back(kv.second);
            class_vars_.clear();
            specInvalidate();   // round 81
            for (auto& kv : prop_setters_) dead.push_back(kv.second);
            prop_setters_.clear();
            for (auto& kv : prop_setter_target_) dead.push_back(kv.second);
            prop_setter_target_.clear();
            for (auto& kv : fn_defaults_node_) for (auto& v : kv.second) dead.push_back(v);
            fn_defaults_node_.clear();
            for (auto& kv : func_attrs_) for (auto& a : kv.second) dead.push_back(a.second);
            func_attrs_.clear();
            bound_members_.clear();          // the BMember objects own their receivers
            bound_member_cache_.clear();
            bound_member_cache_.clear();
            flow().value = Value();
        }
        std::vector<Context*> bodies;
        for (auto& kv : class_ctx_map_) if (kv.second) bodies.push_back(kv.second);
        class_ctx_map_.clear();
        specInvalidate();   // round 81
        for (Context* c : bodies) { c->gc_clear(); nygc::decref(c); }
        global_ctx->gc_clear();
        nygc::collect(nygc::kGenerations - 1);
        Context* g = global_ctx;
        global_ctx = nullptr;
        nygc::decref(g);
        nygc::collect(nygc::kGenerations - 1);
    }

    // gc_* builtins (the same names on the VM, src/VMGC.cpp).
    bool gcBuiltin(const std::string& name, std::vector<Value>& args, Value& out) {
        if (name.size() < 3 || !(name[0] == 'g' || name[0] == 'm' || name[0] == 'w' || name[0] == '_')) return false;
        if (name.rfind("__weakref__:", 0) == 0) {
            auto it = weak_by_id_.find(std::strtoll(name.c_str() + 12, nullptr, 10));
            if (it != weak_by_id_.end() && it->second->has_held) { out = it->second->held; return true; }   // a class (round 78)
            if (it == weak_by_id_.end() || !it->second->target) { out = NONE_VALUE; return true; }
            out = it->second->coll ? Value(it->second->target) : nyheap::userValue(it->second->target, it->second->payload);
            return true;
        }
        if (name == "weakref") {
            if (args.empty()) pyRaise("TypeError", "weakref() takes exactly one argument (0 given)");
            out = makeWeakRef(args[0], args.size() > 1 ? args[1] : Value());
            return true;
        }
        auto argInt = [&](size_t i, int64_t dflt) -> int64_t {
            if (i < args.size() && args[i].type == ValueType::INTEGER) return bigint_to_i64(args[i].value.i);
            return dflt;
        };
        if (name == "gc_collect") {
            // Queued finalizers first (they would have run at the next statement).
            nygc::safe_point();
            out = intValue((int64_t)nygc::collect((int)argInt(0, nygc::kGenerations - 1)));
            nygc::safe_point();
            return true;
        }
        if (name == "gc_enable") { nygc::set_enabled(true); out = NONE_VALUE; return true; }
        if (name == "gc_disable") { nygc::set_enabled(false); out = NONE_VALUE; return true; }
        if (name == "gc_is_enabled" || name == "gc_isenabled") { out = Value(nygc::is_enabled()); return true; }
        if (name == "gc_live_objects") { out = intValue((int64_t)nython::gc::collectables_created()); return true; }
        if (name == "gc_set_threshold") {
            for (size_t i = 0; i < args.size() && i < (size_t)nygc::kGenerations; i++)
                nygc::set_threshold((int)i, (long)argInt(i, nygc::threshold((int)i)));
            out = NONE_VALUE;
            return true;
        }
        if (name == "gc_get_threshold") {
            std::vector<Value> t;
            for (int g = 0; g < nygc::kGenerations; g++) t.push_back(intValue((int64_t)nygc::threshold(g)));
            out = makeListValue(t, true);
            return true;
        }
        if (name == "gc_stats") {
            nygc::Stats st = nygc::stats();
            auto* m = new Object((Runnable*)runner, "map", Type::MAP);
            Value mv((Collectable*)m);
            long long coll = 0, freed = 0;
            std::vector<Value> per;
            for (int g = 0; g < nygc::kGenerations; g++) {
                coll += st.collections[g];
                freed += st.collected[g];
                per.push_back(intValue((int64_t)st.collections[g]));
            }
            dictSet(m, internString("engine"), internString("interpreter"));
            dictSet(m, internString("enabled"), Value(nygc::is_enabled()));
            dictSet(m, internString("collections"), intValue((int64_t)coll));
            dictSet(m, internString("collections_per_gen"), makeListValue(per));
            dictSet(m, internString("collected"), intValue((int64_t)freed));
            dictSet(m, internString("uncollectable"), intValue((int64_t)st.uncollectable));
            dictSet(m, internString("finalized"), intValue((int64_t)st.finalized));
            dictSet(m, internString("freed_by_refcount"), intValue((int64_t)st.freed_by_refcount));
            dictSet(m, internString("tracked"), intValue((int64_t)st.tracked));
            dictSet(m, internString("gen0"), intValue((int64_t)st.gen_count[0]));
            dictSet(m, internString("gen1"), intValue((int64_t)st.gen_count[1]));
            dictSet(m, internString("gen2"), intValue((int64_t)st.gen_count[2]));
            dictSet(m, internString("live_objects"), intValue((int64_t)nython::gc::collectables_created()));
            dictSet(m, internString("live_strings"), intValue((int64_t)st.live_strings));
            dictSet(m, internString("string_bytes"), intValue((int64_t)st.string_bytes));
            dictSet(m, internString("rss_kb"), intValue((int64_t)nygc::rss_kb()));
            out = mv;
            return true;
        }
        if (name == "mem_rss_kb") { out = intValue((int64_t)nygc::rss_kb()); return true; }
        if (name == "mem_peak_rss_kb") { out = intValue((int64_t)nygc::peak_rss_kb()); return true; }
        return false;
    }

    // 0 = neither, 1 = __bool__, 2 = __len__, per class.
    std::unordered_map<void*, int> truthy_proto_;
    bool classDefines(void* class_ptr, const std::string& name, int depth = 0) {
        if (!class_ptr || depth > 32) return false;
        void* ast_ptr = class_ptr;
        auto ast_it = func_ast_nodes.find(class_ptr);
        if (ast_it != func_ast_nodes.end()) ast_ptr = ast_it->second;
        Node* nd = (Node*)ast_ptr;
        if (!nd || nd->type() != NodeType::CLASS) return false;
        auto* cn = static_cast<ClassNode*>(nd);
        if (cn->body)
            for (auto& st : cn->body->statements())
                if (st->type() == NodeType::FUNCTION && static_cast<FunctionNode*>(st.get())->name == name) return true;
        for (auto& b : cn->bases) {
            auto bit = class_by_name.find(b->value());
            // a builtin base: its mirror class (round 77)
            if (bit == class_by_name.end())
                if (const char* mn = nyrt::builtin_mirror(b->value())) bit = class_by_name.find(mn);
            if (bit != class_by_name.end() && classDefines(bit->second, name, depth + 1)) return true;
        }
        return false;
    }
    bool instanceTruthy(const Value& v) {
        void* cls = instance_to_class[v.value.p];
        auto it = truthy_proto_.find(cls);
        int kind;
        if (it != truthy_proto_.end()) kind = it->second;
        else {
            kind = classDefines(cls, "__bool__") ? 1 : classDefines(cls, "__len__") ? 2 : 0;
            truthy_proto_[cls] = kind;
        }
        if (kind == 0) return true;
        std::vector<Value> no_args;
        Value r = callMethod(v, kind == 1 ? "__bool__" : "__len__", no_args, global_ctx);
        // __bool__ must give a bool, __len__ an int >= 0, as Python checks
        // (round 78)
        if (kind == 1) {
            if (r.type != ValueType::BOOLEAN)
                pyRaise("TypeError", "__bool__ should return bool, returned " + typeNameOf(r));
            return r.value.b;
        }
        if (r.type == ValueType::BOOLEAN) return r.value.b;
        if (r.type != ValueType::INTEGER) pyRaise("TypeError", "'" + typeNameOf(r) + "' object cannot be interpreted as an integer");
        if (r.value.i.isNegative()) pyRaise("ValueError", "__len__() should return >= 0");
        return isTruthy(r);
    }
};

// Heap object members that need the whole executor (round 75).
#include "NyHeapImpl.hpp"
