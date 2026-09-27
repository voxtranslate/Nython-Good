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
#include "NyPrelude.hpp"
#include <algorithm>
#include <fstream>
#include <cwctype>
#include <chrono>
#include <iomanip>
#include <map>
#include <thread>
#include <mutex>
#include <condition_variable>
#include "NyConc.hpp"   // concurrency runtime shared with the VM (src/NyConc.cpp)
#include <random>
#include <regex>
#include <sstream>
#include <ctime>
#include <functional>
#include "NyBigInt.hpp"
#include "NyStr.hpp"
#include "NyFormat.hpp"

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

#include "Evaluator.hpp"
#include "Context.hpp"
#include "ASTNodes.hpp"
#include "DynamicLang.hpp"
#include "Runtime.hpp"

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
inline Value intValue(int64_t v) { return Value((long int)v); }
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

// ── Forward declarations of module dispatch functions ─────────────────────
// Each is implemented in src/builtins/X.cpp
Value dispatch_tensor   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_nt       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> nt_builtin_names();   // shared tensor natives (src/builtins/tensor.cpp)
Value dispatch_audio    (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_string   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_io       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_network  (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_math     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_os       (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_data     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_threading(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_core     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_gui      (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_text     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_lang     (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
Value dispatch_pycore   (NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);


struct NythonExecutor {
    Context* global_ctx;
    Runnable* runner;
    std::map<void*, std::string> func_names;
    // Per OS thread: generator collection in one thread must not capture the
    // yields of another (round 74, threads).
    static inline thread_local std::vector<Value>* yield_sink_ = nullptr; // set during generator collection
    std::map<int, FILE*> file_handles{};
    int next_file_handle{1000};
    std::map<void*, Context*> closure_contexts;
    // ── Per-call context reclamation ────────────────────────────────────────
    // Every interpreted call allocated a Context that was never freed (~550
    // bytes a call: the Context plus the ContainerType map it news in its
    // constructor and no destructor releases).
    //
    // A context may outlive its call only if something retained a pointer to
    // it: a closure, a class body, or a child context that itself escaped.
    // Those are the only three retainers in this file, and each marks the
    // context AND its whole parent chain. Anything unmarked when the call
    // returns is provably unreachable and is freed.
    //
    // This is deliberately conservative: a missed retainer must cause a leak,
    // never a use-after-free, so escape marking walks upward and reaping only
    // ever happens for contexts this executor created for a single call.
    // unordered_set: this is probed once per call return, so an O(log n) lookup
    // against a set that grows with every closure and class is a per-call tax.
    std::unordered_set<Context*> escaped_ctxs_;
    void markEscaped(Context* c) {
        while (c && escaped_ctxs_.insert(c).second) c = c->parent;
    }
    void reapContext(Context* c) {
        if (!c) return;
        if (escaped_ctxs_.count(c)) return;
        // Container news its map and its destructor does not free it, and the
        // copy constructor is defaulted (shallow), so the shared destructor
        // cannot safely own it. Release it here, where this context is known
        // dead and known not to have been copied.
        if (c->container) { delete c->container; c->container = nullptr; }
        delete c;
    }
    // Frees the context on scope exit unless it escaped, including when the
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
    std::vector<std::unique_ptr<std::string>> string_store; // keeps strings alive
    std::unordered_set<void*> string_ptrs_; // fast positive lookup for string pointers

    // Create a Value that stores a string (persists across Value copies)
    // Strings made so far and their bytes; like heap objects they are kept for
    // the life of the process, and --profile attributes them per function.
    static long long& strings_created() { static long long n = 0; return n; }
    static long long& string_bytes_created() { static long long n = 0; return n; }

    // The empty string and the 256 one-byte strings are made once and shared.
    // Strings are immutable and never freed here, so a character loop
    // (line[i:i+1], string_lower(ch), ch == "a") used to leave one permanent
    // string behind per character examined.
    Value small_strs_[257];
    bool small_made_[257] = {};

    // One shared string per distinct text, for names the interpreter itself
    // binds over and over (the parent class set up on every method call of a
    // subclass). Those used to cost a new permanent string per call.
    std::unordered_map<std::string, Value> interned_;
    Value internString(const std::string& s) {
        auto it = interned_.find(s);
        if (it != interned_.end()) return it->second;
        Value v = makeStringValue(s);
        interned_.emplace(s, v);
        return v;
    }

    Value makeStringValue(const std::string& s) {
        if (s.size() <= 1) {
            int k = s.empty() ? 256 : (unsigned char)s[0];
            if (small_made_[k]) return small_strs_[k];
            small_made_[k] = true;
            string_store.push_back(std::make_unique<std::string>(s));
            Value sv;
            sv.type = ValueType::USERDATA;
            sv.value.p = (void*)string_store.back().get();
            string_ptrs_.insert(sv.value.p);
            small_strs_[k] = sv;
            return sv;
        }
        // A single multi-byte character (indexing and iterating a string go
        // by character): shared too, like the one-byte strings.
        if (s.size() <= 4 && (unsigned char)s[0] >= 0xC0 && nypy::u8_seq((unsigned char)s[0]) == s.size()) {
            auto it = interned_.find(s);
            if (it != interned_.end()) return it->second;
            string_store.push_back(std::make_unique<std::string>(s));
            Value cv;
            cv.type = ValueType::USERDATA;
            cv.value.p = (void*)string_store.back().get();
            string_ptrs_.insert(cv.value.p);
            interned_.emplace(s, cv);
            return cv;
        }
        strings_created()++;
        string_bytes_created() += (long long)s.size();
        string_store.push_back(std::make_unique<std::string>(s));
        Value v;
        v.type = ValueType::USERDATA;
        v.value.p = (void*)string_store.back().get();
        string_ptrs_.insert(v.value.p);
        return v;
    }

    // Get string from a string Value
    bool isStringValue(const Value& v) {
        if (v.type == ValueType::USERDATA && v.value.p && string_ptrs_.count(v.value.p))
            return true;
        return v.type == ValueType::USERDATA && v.value.p 
            && !func_names.count(v.value.p) 
            && !instance_to_class.count(v.value.p)
            && !instance_properties.count(v.value.p);
    }
    // func_names stores internal identifiers ("__func__:inner", "__lambda__",
    // "__class__:Point"); render them the way the VM does so the two engines
    // print the same thing.
    static std::string funcDisplayName(const std::string& fn) {
        if (fn.rfind("__class__:", 0) == 0) return "<class " + fn.substr(10) + ">";
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
            auto source = SourceCode(std::string(nyrt::prelude_source()));
            auto reporter = std::make_shared<Reporter>(source);
            auto lex = std::make_shared<Lexer>(source);
            lex->tokenize();
            auto parser = std::make_shared<Parser>(reporter.get(), (Runnable*)runner, lex.get());
            auto ast = parser->parse();
            if (ast) {
                imported_asts.push_back(ast);
                evalNode(ast, global_ctx);
            }
        } catch (std::exception& e) {
            std::cerr << "[Nython] prelude failed to load: " << e.what() << "\n";
        } catch (...) {
            std::cerr << "[Nython] prelude failed to load\n";
        }
    }

    ~NythonExecutor() {
        delete global_ctx;
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
            "input","abs","min","max","round","sorted","reversed",
            "list","tuple","dict","set","map","filter","reduce","zip",
            "enumerate","sum","any","all","hasattr","getattr","setattr",
            "isinstance","issubclass","id","hash","hex","oct","bin",
            "chr","ord","repr","format","open","exit","quit",
            "pow","divmod","input","dict","display","show","is_int","is_float","is_string","is_list","is_none","is_bool","to_int","to_float","to_str","clamp","lerp","map_range","repeat_str","repeat","flatten","flat","shell","system","ls","cat","pwd","mkdir","write","exists","env","all","any","complex","slice","super","property",
            "staticmethod","classmethod","callable","dir","vars","globals","locals",
            "iter","next","help","Set","Counter","OrderedDict","deque","defaultdict","assert",
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
            // ── GUI builtins — value-returning ──────────────────────────────
            "gui_get_error","gui_sdl_version","gui_get_display_size","gui_get_window_size","gui_set_window_size","gui_set_cursor","gui_hash_id","gui_display_scale","gui_display_density","gui_window_scale","gui_measure_text_w","gui_set_clipboard","gui_get_clipboard",
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
            "os_symlink","os_readlink","os_touch","append","os_gettempdir","os_mkstemp",
            "os_mkdtemp","os_disk_usage","os_chdir","cd","sh",
            "os_unsetenv","os_environ","os_platform","os_cpu_count","os_hostname",
            "os_username","os_home","os_uname",
            "os_system","os_run","subprocess_run","os_spawn","os_proc_read","os_poll",
            "os_wait","os_kill","os_getpid","os_getppid","shell_quote","os_shell_quote",
            "which","os_which","sys_argv",
            "time","clock","time_ns","time_monotonic","monotonic","time_perf_counter",
            "perf_counter","time_process","process_time","time_strftime","time_localtime",
            "time_gmtime","time_mktime","time_timegm","time_strptime","time_iso",
            "time_parse_iso","uuid","gen_uuid","sleep_ms",
            "file_open_or_raise","file_seek","file_tell","file_flush"
        };
        for (auto& name : builtins) registerBuiltin(name);
        // Concurrency runtime (src/NyConc.cpp): threads, locks, channels,
        // futures, task groups, async. Same names and semantics on the VM.
        for (auto& name : nyconc::builtin_names()) registerBuiltin(name);
        for (auto& name : nyconc::exception_names()) registerBuiltin(name);
        // Shared tensor natives (include/NyTensor.hpp): the same kernels the
        // VM registers, so both engines resolve these names identically.
        for (auto& name : nt_builtin_names()) registerBuiltin(name);
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
            "UnicodeError"
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
        try {
            return evalNode(ast, global_ctx);
        } catch (std::string& flow) {
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
    struct FlowState {
        Context* fast_ctx = nullptr;
        bool brk_ok = false;
        int pending = 0;          // 1 return, 2 break, 3 continue
        Value value;              // a pending return's value
    };
    static FlowState& flow() { static thread_local FlowState f; return f; }
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
        if (lf.pending == 1) return result; \
        int ny_pf_ = lf.pending; lf.pending = 0; \
        if (ny_pf_ == 2) { broke_var = true; break; } \
        continue; \
    }
    // Runs a function body in fc and returns what the call should return:
    // the value of a `return` (fast or thrown), or - as before - the value
    // of the body's last statement when it runs off the end.
    Value evalBody(node_ptr body, Context* fc) {
        FlowState& f = flow();
        struct Restore {
            FlowState& f; Context* c; bool b;
            ~Restore() { f.fast_ctx = c; f.brk_ok = b; }
        } _restore{f, f.fast_ctx, f.brk_ok};
        f.fast_ctx = fc;
        f.brk_ok = false;
        Value v = evalNode(body, fc);
        if (f.pending) {
            if (f.pending == 1) { v = f.value; f.value = NONE_VALUE; }
            f.pending = 0;
        }
        return v;
    }

    Value evalNode(node_ptr node, Context* ctx) {
        if (!node) return NONE_VALUE;

        switch (node->type()) {
            case NodeType::SCRIPT: return evalScript(node, ctx);
            case NodeType::STATEMENTS: return evalStatements(node, ctx);
            case NodeType::BLOCK: return evalStatements(node, ctx);
            case NodeType::INTEGER: return evalInteger(node);
            case NodeType::FLOAT: return evalFloat(node);
            case NodeType::STRING: return evalString(node, ctx);
            case NodeType::TRUE: return Value(true);
            case NodeType::FALSE: return Value(false);
            case NodeType::NONE: return NONE_VALUE;
            case NodeType::UNDEFINED: return UNDEFINED_VALUE;
            case NodeType::VARIABLE: return evalVariable(node, ctx);
            case NodeType::VARIABLE_DECL: return evalVarDecl(node, ctx);
            case NodeType::ASSIGNMENT: return evalAssignment(node, ctx);
            case NodeType::ASSIGNMENT_AUG: return evalAugAssignment(node, ctx);
            case NodeType::BINARY: return evalBinary(node, ctx);
            case NodeType::UNARY: return evalUnary(node, ctx);
            case NodeType::PRINT: return evalPrint(node, ctx);
            case NodeType::IF: return evalIf(node, ctx);
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
            case NodeType::CALL: return evalCall(node, ctx);
            case NodeType::ATTRIBUTE: return evalAttribute(node, ctx);
            case NodeType::SUBSCRIPT: return evalSubscript(node, ctx);
            case NodeType::LIST: return evalList(node, ctx);
            case NodeType::COMPLEX: return evalComprehension(node, ctx);
            case NodeType::COMPREHENSION: return evalComprehensionNode(node, ctx);
            case NodeType::MAP: return evalMap(node, ctx);
            case NodeType::TUPLE: return evalList(node, ctx);
            case NodeType::ARRAY: return evalList(node, ctx);
            case NodeType::RANGE: return evalRange(node, ctx);
            case NodeType::TRY: { SuspendFast _sf; return evalTry(node, ctx); }
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
            case NodeType::WITH: { SuspendFast _sf; return evalWith(node, ctx); }
            case NodeType::NAMESPACE: { SuspendFast _sf; return evalNamespace(node, ctx); }
            case NodeType::INTERFACE: { SuspendFast _sf; return evalInterfaceDecl(node, ctx); }
            case NodeType::YIELD: { auto yn = static_pointer_cast<YieldNode>(node); Value yv = yn->expr ? evalNode(yn->expr, ctx) : NONE_VALUE; if (yield_sink_) { yieldValue(yv); return NONE_VALUE; } throw nython::node::YieldSignal(yv); }
            case NodeType::YIELD_FROM: {
                // yield from it: every value of `it`, yielded in turn.
                auto yf = static_pointer_cast<YieldFromNode>(node);
                Value src = evalNode(yf->expr, ctx);
                // (what is left of a generator, which this consumes)
                std::vector<Value> items = iterValues(src, ctx);
                if (!yield_sink_) throw nython::node::YieldSignal(items.empty() ? NONE_VALUE : items[0]);
                for (auto& item : items) yieldValue(item);
                return NONE_VALUE;
            }
            case NodeType::GLOBAL: return NONE_VALUE;
            case NodeType::SELF: return ctx->getByName("self");
            case NodeType::SUPER: return ctx->getByName("super");
            case NodeType::WALRUS: {
                // Walrus operator: (var name = expr) — evaluates expr, stores it, returns value
                auto wn = static_pointer_cast<WalrusNode>(node);
                Value v = evalNode(wn->init, ctx);
                ctx->defineByName(wn->name, v);
                return v;
            }
            default: return NONE_VALUE;
        }
    }

    // ─── SCRIPT / STATEMENTS ────────────────────────────────────────────
    Value evalScript(node_ptr node, Context* ctx) {
        Value result = NONE_VALUE;
        FlowState& f = flow();
        for (auto& child : node->statements()) {
            noteStatement(child, ctx);
            result = evalNode(child, ctx);
            if (f.pending) return result;
        }
        return result;
    }

    Value evalStatements(node_ptr node, Context* ctx) {
        Value result = NONE_VALUE;
        FlowState& f = flow();
        for (auto& child : node->statements()) {
            noteStatement(child, ctx);
            result = evalNode(child, ctx);
            if (f.pending) return result;
        }
        return result;
    }

    // ─── LITERALS ───────────────────────────────────────────────────────
    Value evalInteger(node_ptr node) {
        const std::string& v = node->token().value;
        // Up to 18 decimal digits fit an int64 whatever they are.
        if (!v.empty() && v.size() <= 18 && std::all_of(v.begin(), v.end(), [](char c) { return c >= '0' && c <= '9'; }))
            return intValue((int64_t)std::strtoll(v.c_str(), nullptr, 10));
        // Prefixed (0x/0o/0b), long or with underscores: exact at any size
        // (literals past 64 bits used to read as 0).
        return intValue(nypy::parse_int_literal(v));
    }

    Value evalFloat(node_ptr node) {
        try { return Value(std::stod(node->token().value)); }
        catch (...) { return Value(0.0); }
    }

    Value evalString(node_ptr node, Context* ctx = nullptr) {
        const std::string& raw = node->token().value;
        // Check for ${...} interpolation
        if (ctx && raw.find("${") != std::string::npos) {
            std::string result;
            size_t i = 0;
            while (i < raw.size()) {
                if (i + 1 < raw.size() && raw[i] == '$' && raw[i+1] == '{') {
                    i += 2; // skip ${
                    std::string expr_name;
                    while (i < raw.size() && raw[i] != '}') expr_name += raw[i++];
                    if (i < raw.size()) i++; // skip }
                    // Evaluate the variable name
                    try {
                        Value v = ctx->getByName(expr_name);
                        if (v.type == ValueType::INTEGER) result += std::to_string(bigint_to_i64(v.value.i));
                        else if (v.type == ValueType::DOUBLE) { char buf[64]; snprintf(buf, sizeof(buf), "%g", static_cast<double>(v.value.d)); result += buf; }
                        else if (v.type == ValueType::NONE) result += "none";
                        else if (v.type == ValueType::BOOLEAN) result += v.value.b ? "true" : "false";
                        else if (isStringValue(v)) result += *static_cast<std::string*>(v.value.p);
                        else result += getStringValue(v);
                    } catch (...) { result += "${" + expr_name + "}"; }
                } else {
                    result += raw[i++];
                }
            }
            return makeStringValue(result);
        }
        // A literal is made into a string once, not on every evaluation. The
        // interpreter never frees a string (string_store), so `"a"` inside a
        // loop or a per-frame function used to add a new permanent string on
        // each pass - in the IDE, most of the memory typing consumed.
        auto* sn = dynamic_cast<StringNode*>(node.get());
        if (sn) {
            if (sn->interned_by != (const void*)this) {
                sn->interned = makeStringValue(raw);
                sn->interned_by = (const void*)this;
            }
            return sn->interned;
        }
        return makeStringValue(raw);
    }

    // ─── VARIABLES ──────────────────────────────────────────────────────


    Value evalVariable(node_ptr node, Context* ctx) {
        auto vn = static_pointer_cast<VariableNode>(node);
        // Check user-defined first
        Value found = ctx->getByName(vn->name);
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
        if (!ctx->hasByName(vn->name) && !knownName(vn->name)) {
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
            const std::string& n = kv.second;
            if (n == called
                || (n.rfind("__func__:", 0) == 0  && n.compare(9, std::string::npos, called) == 0)
                || (n.rfind("__class__:", 0) == 0 && n.compare(10, std::string::npos, called) == 0)
                || (n.rfind("__builtin__:", 0) == 0 && n.compare(12, std::string::npos, called) == 0))
                return true;
        }
        return false;
    }

    Value evalVarDecl(node_ptr node, Context* ctx) {
        auto vd = static_pointer_cast<VarDeclNode>(node);
        Value val = vd->init ? evalNode(vd->init, ctx) : NONE_VALUE;
        ctx->defineByName(vd->name, val);
        return val;
    }

    Value evalAssignment(node_ptr node, Context* ctx) {
        auto an = static_pointer_cast<AssignmentNode>(node);
        Value val = evalNode(an->value_node, ctx);
        if (an->target->type() == NodeType::VARIABLE) {
            auto vn = static_pointer_cast<VariableNode>(an->target);
            // In a class body a name is always bound in the class namespace:
            // setByName found a same-named variable in an enclosing scope and
            // rebound IT (`items = []` in a class body overwrote the global
            // builtin `items`, and the class never got the attribute).
            if (ctx->inClass) ctx->defineByName(vn->name, val);
            else ctx->setByName(vn->name, val);
        } else if (an->target->type() == NodeType::ATTRIBUTE) {
            auto attr = static_pointer_cast<AttributeNode>(an->target);
            Value obj = evalNode(attr->object, ctx);
            setAttr(obj, attr->attr, val);
        } else if (an->target->type() == NodeType::SUBSCRIPT) {
            auto sub = static_pointer_cast<SubscriptNode>(an->target);
            Value obj = evalNode(sub->object, ctx);
            Value idx = evalNode(sub->index, ctx);
            setItem(obj, idx, val, ctx);
        } else if (an->target->type() == NodeType::CALL) {
            // Slice assignment: arr[1:3] = [20, 30] is parsed as arr.slice(1,3) = [20,30]
            auto cn = static_pointer_cast<CallNode>(an->target);
            if (cn->callee && cn->callee->type() == NodeType::ATTRIBUTE) {
                auto attr = static_pointer_cast<AttributeNode>(cn->callee);
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
    Value makeOsNamespace() {
        std::vector<std::string> names;
        for (auto& kv : builtin_ptrs) names.push_back(kv.first);
        auto* ns = new Object((Runnable*)runner, "os", Type::MAP);
        auto* path = new Object((Runnable*)runner, "path", Type::MAP);
        for (auto& m : nyrt::module_members("os", names)) {
            if (m.first == "environ") continue;   // a map, below (os.environ["HOME"])
            if (m.first.rfind("path.", 0) == 0) path->set(m.first.substr(5), builtinValue(m.second));
            else ns->set(m.first, builtinValue(m.second));
        }
        for (const char* c : {"sep", "pathsep", "linesep", "name"}) {
            Value v = global_ctx->getByName(std::string("os_") + c);
            ns->set(c, v);
            if (std::string(c) == "sep" || std::string(c) == "pathsep") path->set(c, v);
        }
        std::vector<Value> no_args;
        ns->set("environ", callBuiltin("os_environ", no_args, global_ctx));
        ns->set("path", Value((Collectable*)path));
        return Value((Collectable*)ns);
    }

    Value nyos_list_of(const std::vector<std::string>& items) {
        auto* o = new Object((Runnable*)runner, "list", Type::LIST);
        for (size_t i = 0; i < items.size(); i++) o->set(std::to_string(i), makeStringValue(items[i]));
        o->set("__len__", Value((int)items.size()));
        return Value((Collectable*)o);
    }


    // ─── EXPRESSIONS ────────────────────────────────────────────────────

    // ── Set union / intersection helpers ────────────────────────────────────────
    std::string set_key_str(Value v) {
        if (v.type == ValueType::INTEGER) return "i:" + std::to_string(bigint_to_i64(v.value.i));
        if (v.type == ValueType::DOUBLE)  return "d:" + std::to_string(v.value.d);
        if (v.type == ValueType::BOOLEAN) return std::string("b:") + (v.value.b ? "1" : "0");
        if (v.type == ValueType::NONE)    return "none";
        return "s:" + getStringValue(v);
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
    Value build_set_val(const std::vector<Value>& items) {
        auto* obj = new Object((Runnable*)runner, "list", Type::LIST);
        obj->set("__set__", Value(1));
        int64_t idx = 0;
        std::unordered_set<std::string> seen;
        for (auto& v : items) {
            if (seen.insert(set_key_str(v)).second) (*obj->container)[std::to_string(idx++)] = v;
        }
        (*obj->container)["__len__"] = intValue(idx);
        return Value((Collectable*)obj);
    }
    Value setUnion(const Value& a, const Value& b) {
        auto av = collect_coll(a); auto bv = collect_coll(b);
        for (auto& v : bv) av.push_back(v);
        return build_set_val(av);
    }
    Value setIntersect(const Value& a, const Value& b) {
        auto av = collect_coll(a); auto bv = collect_coll(b);
        std::vector<Value> result;
        for (auto& v : av) {
            std::string k = set_key_str(v);
            for (auto& w : bv) if (set_key_str(w)==k) { result.push_back(v); break; }
        }
        return build_set_val(result);
    }
    Value setDiff(const Value& a, const Value& b) {
        auto av = collect_coll(a); auto bv = collect_coll(b);
        std::vector<Value> result;
        for (auto& v : av) {
            std::string k = set_key_str(v);
            bool inB = false;
            for (auto& w : bv) if (set_key_str(w)==k) { inB=true; break; }
            if (!inB) result.push_back(v);
        }
        return build_set_val(result);
    }
    Value setSymDiff(const Value& a, const Value& b) {
        auto av = collect_coll(a); auto bv = collect_coll(b);
        std::vector<Value> result;
        for (auto& v : av) {
            std::string k = set_key_str(v);
            bool inB = false;
            for (auto& w : bv) if (set_key_str(w)==k) { inB=true; break; }
            if (!inB) result.push_back(v);
        }
        for (auto& v : bv) {
            std::string k = set_key_str(v);
            bool inA = false;
            for (auto& w : av) if (set_key_str(w)==k) { inA=true; break; }
            if (!inA) result.push_back(v);
        }
        return build_set_val(result);
    }

    // ─── VALUE KINDS ────────────────────────────────────────────────────
    // Lists, tuples and sets are Containers keyed "0".."n-1" plus "__len__"
    // ("__tuple__" / "__set__" mark the latter two); dicts are Containers
    // without "__len__". Strings, functions, classes and instances are
    // USERDATA pointers told apart by the side tables.
    Container* contOf(const Value& v) const {
        if (!v.isCollectable() || !v.value.gc) return nullptr;
        auto* c = dynamic_cast<Container*>(v.value.gc);
        return (c && c->container) ? c : nullptr;
    }
    // Length of a list/tuple/set container, -1 if it is not one.
    static int64_t seqLen(Container* c) {
        auto it = c->container->find("__len__");
        if (it == c->container->end()) return -1;
        return bigint_to_i64(it->second.value.i);
    }
    static bool isTupleCont(Container* c) { return c->container->count("__tuple__") > 0; }
    static bool isSetCont(Container* c) { return c->container->count("__set__") > 0; }
    static bool isGenCont(Container* c) { return c->container->count("__gen__") > 0; }
    bool isInstanceVal(const Value& v) const {
        return v.type == ValueType::USERDATA && v.value.p && !string_ptrs_.count(v.value.p)
            && instance_to_class.count(v.value.p);
    }
    static std::vector<Value> seqItems(Container* c) {
        std::vector<Value> out;
        int64_t n = seqLen(c);
        if (n <= 0) return out;
        out.reserve((size_t)n);
        for (int64_t i = 0; i < n; i++) {
            auto it = c->container->find(std::to_string(i));
            if (it != c->container->end()) out.push_back(it->second);
        }
        return out;
    }
    Value makeListValue(const std::vector<Value>& items, bool tuple = false) {
        auto* obj = new Object((Runnable*)runner, tuple ? "tuple" : "list", Type::LIST);
        int64_t i = 0;
        for (auto& v : items) (*obj->container)[std::to_string(i++)] = v;
        (*obj->container)["__len__"] = intValue(i);
        if (tuple) (*obj->container)["__tuple__"] = Value(1);
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
        OP_IS, OP_ISNOT, OP_IN, OP_NOTIN, OP_AND, OP_OR, OP_LXOR
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
                                  "==", "!=", "<", "<=", ">", ">=", "===", "!==", "is", "is not", "in", "not in", "and", "or", "xor"};
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
    bool orderValues(const Value& a, const Value& b, int& res, Context* ctx, int depth = 0) {
        Num x, y;
        if (asNum(a, x) && asNum(b, y)) { res = numCmp(x, y); return res != 2; }
        bool as = isStringValue(a), bs = isStringValue(b);
        if (as && bs) {
            int c = ((std::string*)a.value.p)->compare(*(std::string*)b.value.p);
            res = c < 0 ? -1 : c > 0 ? 1 : 0;
            return true;
        }
        if (as || bs) return false;
        Container* ca = contOf(a); Container* cb = contOf(b);
        if (ca && cb && depth < 100) {
            int64_t la = seqLen(ca), lb = seqLen(cb);
            if (la < 0 || lb < 0) return false;
            for (int64_t i = 0; i < la && i < lb; i++) {
                auto ia = ca->container->find(std::to_string(i));
                auto ib = cb->container->find(std::to_string(i));
                if (ia == ca->container->end() || ib == cb->container->end()) return false;
                if (valuesEqual(ia->second, ib->second, depth + 1)) continue;
                return orderValues(ia->second, ib->second, res, ctx, depth + 1);
            }
            res = la < lb ? -1 : la > lb ? 1 : 0;
            return true;
        }
        // Objects: __lt__ (or the other side's __gt__), then __eq__.
        if ((isInstanceVal(a) || isInstanceVal(b)) && ctx) {
            Value lt;
            if (!binaryDunder("<", a, b, ctx, lt)) return false;
            if (isTruthy(lt)) { res = -1; return true; }
            Value eq;
            res = (binaryDunder("==", a, b, ctx, eq) ? isTruthy(eq) : identical(a, b)) ? 0 : 1;
            return true;
        }
        return false;
    }

    // `x in c`
    bool containsValue(const Value& c, const Value& x, Context* ctx) {
        // An object: __contains__, else a search of what it iterates over
        // (__iter__ / __getitem__), as in Python.
        if (isInstanceVal(c)) {
            if (instanceHasMethod(c, "__contains__")) {
                std::vector<Value> args = {x};
                return isTruthy(callMethod(c, "__contains__", args, ctx));
            }
            if (instanceHasMethod(c, "__iter__") || instanceHasMethod(c, "__getitem__") || instanceHasMethod(c, "__next__")) {
                for (auto& v : iterValues(c, ctx)) if (pyEquals(x, v, ctx)) return true;
                return false;
            }
            pyRaise("TypeError", "argument of type '" + instanceClassName(c) + "' is not iterable");
        }
        if (isStringValue(c)) {
            if (!isStringValue(x)) pyRaise("TypeError", "'in <string>' requires string as left operand");
            return ((std::string*)c.value.p)->find(*(std::string*)x.value.p) != std::string::npos;
        }
        Container* cont = contOf(c);
        if (!cont) return false;
        int64_t n = seqLen(cont);
        if (n >= 0) {
            for (int64_t i = 0; i < n; i++) {
                auto it = cont->container->find(std::to_string(i));
                if (it != cont->container->end() && valuesEqual(x, it->second, 0)) return true;
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
        Num x, y;
        bool nums = asNum(lv, x) && asNum(rv, y);
        switch (opc) {
        case OP_ADD: {
            if (nums) return numArith(opc, x, y);
            bool ls = isStringValue(lv), rs = isStringValue(rv);
            if (ls && rs) return makeStringValue(*(std::string*)lv.value.p + *(std::string*)rv.value.p);
            Container* lc = contOf(lv); Container* rc = contOf(rv);
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
            if (lv.isCollectable() && rv.isCollectable()) return setDiff(lv, rv);
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
            if (lv.isCollectable() && rv.isCollectable())
                return opc == OP_BAND ? setIntersect(lv, rv) : opc == OP_BOR ? setUnion(lv, rv) : setSymDiff(lv, rv);
            return intValue(0);
        }
        case OP_LSHIFT: case OP_RSHIFT:
            if (nums) return numArith(opc, x, y);
            return intValue(0);
        case OP_EQ: return Value(valuesEqual(lv, rv, 0));
        case OP_NE: return Value(!valuesEqual(lv, rv, 0));
        case OP_LT: case OP_LE: case OP_GT: case OP_GE: {
            int c;
            if (!orderValues(lv, rv, c, ctx)) return Value(false);
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

    // ─── AUGMENTED ASSIGNMENT ───────────────────────────────────────────
    // `t op= v` evaluates the target's object and index once, computes with
    // the same operators as the binary form, and stores back. Lists are
    // mutable, so `L += it` extends and `L *= n` repeats in place: every
    // alias sees the change (a new list used to be built, or none returned).
    Value evalAugAssignment(node_ptr node, Context* ctx) {
        auto an = static_pointer_cast<AugAssignNode>(node);
        const std::string& op = an->op;
        std::string base = op.substr(0, op.size() > 0 ? op.size() - 1 : 0);
        if (op == ">>>=") base = ">>";
        int opc = binOpCode(base);
        // Target: read its current value, remembering where to store.
        Value obj, idx, old_val;
        int kind = an->target->type() == NodeType::SUBSCRIPT ? 1 : an->target->type() == NodeType::ATTRIBUTE ? 2 : 0;
        if (kind == 1) {
            auto sub = static_pointer_cast<SubscriptNode>(an->target);
            obj = evalNode(sub->object, ctx);
            idx = evalNode(sub->index, ctx);
            old_val = getItem(obj, idx, ctx);
        } else if (kind == 2) {
            auto attr = static_pointer_cast<AttributeNode>(an->target);
            obj = evalNode(attr->object, ctx);
            receiver_cache()[attr->object.get()] = obj;
            try { old_val = evalNode(an->target, ctx); }
            catch (...) { receiver_cache().erase(attr->object.get()); throw; }
            receiver_cache().erase(attr->object.get());
        } else {
            old_val = evalNode(an->target, ctx);
        }
        Value new_val = evalNode(an->value_node, ctx);
        Value result;
        Container* oc = contOf(old_val);
        if (op == "~=") {
            // `x ~= y` assigns the bitwise complement of the right operand
            // (`x = ~y`) - the reading chosen when the operator was wired up.
            Num y;
            if (!asNum(new_val, y) || y.k == 3) pyRaise("TypeError", "bad operand type for unary ~");
            result = y.k == 1 ? intValue(~y.i) : intValue(-(numBig(y) + nypy::BigInt(1)));
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
                    {"|=", "__ior__"}, {"^=", "__ixor__"}, {"<<=", "__ilshift__"}, {">>=", "__irshift__"}};
                auto it = idunder.find(op);
                if (it != idunder.end()) {
                    std::vector<Value> a = {new_val};
                    Value r = callMethod(old_val, it->second, a, ctx);
                    if (r.type != ValueType::NONE) { result = r; done = true; }
                }
            }
            if (!done) {
                if (opc == OP_UNKNOWN) result = new_val;
                else result = binaryOp(opc, old_val, new_val, ctx);
            }
        }
        if (kind == 1) setItem(obj, idx, result, ctx);
        else if (kind == 2) setAttr(obj, static_pointer_cast<AttributeNode>(an->target)->attr, result);
        else if (an->target->type() == NodeType::VARIABLE)
            ctx->setByName(static_pointer_cast<VariableNode>(an->target)->name, result);
        return result;
    }

    // ─── ATTRIBUTE / ITEM STORES ────────────────────────────────────────
    void setAttr(const Value& obj, const std::string& name, const Value& val) {
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
                std::unordered_map<std::string, Value> nokw;
                invokeMember(st->second, owner, obj, a, nokw, global_ctx);
                return;
            }
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
                    class_vars_[cn->name + "." + name] = val;
                    // Also update class_ctx_map_ so subsequent reads via evalAttribute see the new value
                    auto cctx_it = class_ctx_map_.find((void*)class_node);
                    if (cctx_it != class_ctx_map_.end()) {
                        try { cctx_it->second->setByName(name, val); }
                        catch (...) { cctx_it->second->defineByName(name, val); }
                    }
                }
            }
        }
        // Store on Collectable containers (namespaces, modules)
        if (Container* cont = contOf(obj)) (*cont->container)[name] = val;
    }

    // Structural equality, recursive, as on the VM (and in Python): lists
    // and tuples element by element, maps key by key, sets as sets, 1 == 1.0
    // == true. A list never equals a tuple.
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
        bool as = isStringValue(a), bs = isStringValue(b);
        if (as || bs) {
            if (!(as && bs)) return false;
            return a.value.p == b.value.p || *(std::string*)a.value.p == *(std::string*)b.value.p;
        }
        if (a.isCollectable() && b.isCollectable() && a.value.gc && b.value.gc) {
            if (a.value.gc == b.value.gc) return true;
            auto* lc = dynamic_cast<Container*>(a.value.gc);
            auto* rc = dynamic_cast<Container*>(b.value.gc);
            if (!lc || !rc || !lc->container || !rc->container) return a == b;
            auto& L = *lc->container;
            auto& R = *rc->container;
            auto li = L.find("__len__");
            auto ri = R.find("__len__");
            bool llist = li != L.end(), rlist = ri != R.end();
            if (llist != rlist) return false;
            if (llist) {
                int64_t ln = bigint_to_i64(li->second.value.i);
                int64_t rn = bigint_to_i64(ri->second.value.i);
                if (ln != rn) return false;
                if (isTupleCont(lc) != isTupleCont(rc)) return false;
                bool lset = L.count("__set__") > 0, rset = R.count("__set__") > 0;
                if (lset != rset) return false;
                if (lset) {
                    for (int64_t i = 0; i < ln; i++) {
                        auto x2 = L.find(std::to_string(i));
                        if (x2 == L.end()) return false;
                        bool found = false;
                        for (int64_t j = 0; j < rn && !found; j++) {
                            auto y2 = R.find(std::to_string(j));
                            if (y2 != R.end() && valuesEqual(x2->second, y2->second, depth + 1)) found = true;
                        }
                        if (!found) return false;
                    }
                    return true;
                }
                for (int64_t i = 0; i < ln; i++) {
                    auto x2 = L.find(std::to_string(i));
                    auto y2 = R.find(std::to_string(i));
                    if (x2 == L.end() || y2 == R.end()) return false;
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
        if (isStringValue(k)) return nypy::key_of_str(*(std::string*)k.value.p);
        if (Container* c = contOf(k)) {
            if (seqLen(c) >= 0 && isTupleCont(c)) {
                std::vector<std::string> parts;
                for (auto& e : seqItems(c)) parts.push_back(dictKey(e));
                return nypy::key_of_tuple(parts);
            }
            if (!isInstanceVal(k)) pyRaise("TypeError", "unhashable type: '" + typeNameOf(k) + "'");
        }
        char buf[32]; snprintf(buf, sizeof buf, "%p", k.type == ValueType::USERDATA ? k.value.p : (void*)k.value.gc);
        std::string id = std::string(k.type == ValueType::USERDATA ? "u" : "g") + buf;
        key_objs_[id] = k;
        return nypy::key_of_obj(id);
    }
    std::unordered_map<std::string, Value> key_objs_;   // object keys, by identity
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
                    const std::unordered_map<std::string, Value>& kw, Context* ctx, Value& out) {
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
            C["__len__"] = intValue(n + 1);
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
            // A non-integer argument is a dict-style pop on a map; not here.
            if (!args.empty() && args[0].type != ValueType::INTEGER && args[0].type != ValueType::BOOLEAN) return false;
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
                    const std::unordered_map<std::string, Value>& kw, Context* ctx, Value& out) {
        auto& C = *cont->container;
        const bool is_dict = seqLen(cont) < 0;
        auto need = [&](size_t lo, size_t hi) {
            if (args.size() < lo || args.size() > hi)
                pyRaise("TypeError", name + "() takes " + (lo == hi ? "exactly " + std::to_string(lo) : "at most " + std::to_string(hi)) + " argument" + (hi == 1 ? "" : "s") + " (" + std::to_string(args.size()) + " given)");
        };
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
            pyRaise("KeyError", reprOf(args[0], ctx));
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
                if (Container* src = contOf(args[0]); src && seqLen(src) < 0) dictUpdate(cont, src);
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
    const std::unordered_map<std::string, Value>* cur_kwargs_ = nullptr;
    std::vector<std::string> cur_kw_order_;   // their names in call order (dict(a=1, b=2))
    struct KwScope {
        NythonExecutor* e; const std::unordered_map<std::string, Value>* prev;
        KwScope(NythonExecutor* x, const std::unordered_map<std::string, Value>* k) : e(x), prev(x->cur_kwargs_) { e->cur_kwargs_ = k; }
        ~KwScope() { e->cur_kwargs_ = prev; }
        KwScope(const KwScope&) = delete;
        KwScope& operator=(const KwScope&) = delete;
    };

    // A slice bound: false when omitted (none); raises for a non-integer.
    bool sliceArg(const std::vector<Value>& args, size_t i, int64_t& out) {
        if (i >= args.size() || args[i].type == ValueType::NONE) return false;
        Num n;
        if (!asNum(args[i], n) || n.k == 3) pyRaise("TypeError", "slice indices must be integers or None or have an __index__ method");
        out = n.k == 1 ? n.i : (numIsNeg(n) ? INT64_MIN / 2 : INT64_MAX / 2);
        return true;
    }
    // L[a:b] = it and L[a:b:c] = it (extended slices must match in length).
    void assignSlice(const Value& obj, const std::vector<Value>& sargs, const Value& val, Context* ctx) {
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
    Value getItem(const Value& obj, const Value& idx, Context* ctx) {
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
                    throw std::string("__exc__:IndexError:index " + std::to_string(i) + " out of range (length " + std::to_string(n) + ")");
                }
            }
            auto it = dictFind(cont, idx);
            if (it != cont->container->end()) return it->second;
            // A missing dict key reads none: the libraries and the IDE are
            // written against that (`v = d[k]` then `if v == none`) in too
            // many places to raise KeyError here; d.get() is the same.
            if (n < 0) return NONE_VALUE;
            pyRaise("TypeError", std::string(isTupleCont(cont) ? "tuple" : "list") + " indices must be integers or slices, not " + typeNameOf(idx));
        }
        // __getitem__ on instances
        if (isInstanceVal(obj)) {
            if (!instanceHasMethod(obj, "__getitem__"))
                pyRaise("TypeError", "'" + instanceClassName(obj) + "' object is not subscriptable");
            std::vector<Value> call_args = {idx};
            return callMethod(obj, "__getitem__", call_args, ctx);
        }
        return NONE_VALUE;
    }

    // obj[idx] = val
    void setItem(const Value& obj, const Value& idx, const Value& val, Context* ctx) {
        if (isInstanceVal(obj)) {
            if (!instanceHasMethod(obj, "__setitem__"))
                throw std::string("__exc__:TypeError:'" + instanceClassName(obj) + "' object does not support item assignment");
            std::vector<Value> call_args = {idx, val};
            Value result = callMethod(obj, "__setitem__", call_args, ctx);
            if (result.type != ValueType::NONE) return;
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

    Value evalSubscript(node_ptr node, Context* ctx) {
        auto sn = static_pointer_cast<SubscriptNode>(node);
        Value obj = evalNode(sn->object, ctx);
        Value idx = evalNode(sn->index, ctx);
        return getItem(obj, idx, ctx);
    }

    // Every element an iterable yields: lists/tuples/sets/generators in
    // order, a dict's keys, a string's characters, or an instance's
    // __iter__/__next__ sequence.
    std::vector<Value> iterItems(const Value& v, Context* ctx) {
        if (Container* c = contOf(v)) {
            if (seqLen(c) >= 0) {
                if (!isGenCont(c)) return seqItems(c);
                // A generator: what is left of it, which this consumes.
                auto ix = c->container->find("__idx__");
                int64_t from = ix != c->container->end() ? bigint_to_i64(ix->second.value.i) : 0;
                std::vector<Value> all = seqItems(c);
                (*c->container)["__idx__"] = intValue((int64_t)all.size());
                if (from <= 0) return all;
                return std::vector<Value>(all.begin() + std::min<int64_t>(from, (int64_t)all.size()), all.end());
            }
            return dictKeys(c);
        }
        if (isStringValue(v)) {
            std::vector<Value> out;
            for (auto& ch : nypy::u8_chars(*(std::string*)v.value.p)) out.push_back(makeStringValue(ch));
            return out;
        }
        // An object: __iter__ / __next__ / a __getitem__ sequence (iterValues).
        if (isInstanceVal(v)) return iterValues(v, ctx);
        pyRaise("TypeError", "'" + typeNameOf(v) + "' object is not iterable");
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
        if (isStringValue(v)) return "str";
        if (Container* c = contOf(v)) {
            if (seqLen(c) < 0) return "dict";
            return isTupleCont(c) ? "tuple" : isSetCont(c) ? "set" : isGenCont(c) ? "generator" : "list";
        }
        if (v.type == ValueType::USERDATA && v.value.p) {
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                if (fit->second.rfind("__instance__:", 0) == 0) return fit->second.substr(13);
                if (fit->second.rfind("__class__:", 0) == 0) return "type";
                if (fit->second.rfind("__builtin__:", 0) == 0) return "builtin_function_or_method";
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
        if (v.type == ValueType::USERDATA) {
            if (!v.value.p) return "none";
            if (string_ptrs_.count(v.value.p)) {
                const std::string& s = *(std::string*)v.value.p;
                return repr ? nypy::str_repr(s) : s;
            }
            if (instance_to_class.count(v.value.p)) {
                std::vector<Value> no_args;
                Context* c = ctx ? ctx : global_ctx;
                if (!repr && instanceHasMethod(v, "__str__")) {
                    Value r;
                    try { r = callMethod(v, "__str__", no_args, c); }
                    catch (nython::node::ReturnSignal& rs) { r = rs.value; }
                    if (r.type != ValueType::NONE && r.type != ValueType::UNDEFINED) return getStringValue(r);
                }
                if (instanceHasMethod(v, "__repr__")) {
                    Value r;
                    try { r = callMethod(v, "__repr__", no_args, c); }
                    catch (nython::node::ReturnSignal& rs) { r = rs.value; }
                    if (r.type != ValueType::NONE && r.type != ValueType::UNDEFINED) return getStringValue(r);
                }
                // An exception: its message for str(), Type('message') for
                // repr(), as in Python and on the VM.
                std::string cn0 = instanceClassName(v);
                if (!cn0.empty() && isExceptionClass(cn0)) {
                    std::string msg = exceptionMessage(v);
                    return repr ? cn0 + "(" + nypy::str_repr(msg) + ")" : msg;
                }
                return "<" + typeNameOf(v) + " instance>";
            }
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                if (fit->second.rfind("__builtin__:", 0) == 0) return "<built-in function " + fit->second.substr(12) + ">";
                return funcDisplayName(fit->second);
            }
            const std::string& s = *(std::string*)v.value.p;
            return repr ? nypy::str_repr(s) : s;
        }
        Container* c = contOf(v);
        if (!c) return v.value.gc ? v.value.gc->toString() : "none";
        int64_t n = seqLen(c);
        if (n >= 0) {
            bool tup = isTupleCont(c), st = isSetCont(c);
            if (st && n == 0) return "set()";
            std::string r = tup ? "(" : st ? "{" : "[";
            for (int64_t i = 0; i < n; i++) {
                if (i) r += ", ";
                auto it = c->container->find(std::to_string(i));
                if (it != c->container->end()) {
                    if (it->second.isCollectable() && it->second.value.gc == v.value.gc) r += tup ? "(...)" : "[...]";
                    else r += toText(it->second, true, ctx, depth + 1);
                }
            }
            if (tup && n == 1) r += ",";
            return r + (tup ? ")" : st ? "}" : "]");
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
            if (r.type != ValueType::NONE && r.type != ValueType::UNDEFINED) return getStringValue(r);
            if (spec.empty()) return strOf(v, ctx);
        }
        return nyCall([&] { return nypy::format_value(toFmtVal(v, 0, ctx), spec); });
    }
    // str methods: arguments to and results from nypy::str_method.
    nypy::SArg toSArg(const Value& v, Context* ctx) {
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
                          const std::unordered_map<std::string, Value>& kw, Context* ctx) {
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
                if (isInstanceVal(v)) return nypy::FmtVal::of_other(strOf(v, ctx), typeNameOf(v));
                return toFmtVal(v, 0, ctx);
            });
        });
    }

    // "fmt" % args
    Value percentFormat(const std::string& fmt, const Value& rv, Context* ctx) {
        std::vector<Value> args;
        bool mapping = false;
        Container* rc = contOf(rv);
        if (rc && seqLen(rc) >= 0 && isTupleCont(rc)) args = seqItems(rc);
        else { args.push_back(rv); mapping = rc && seqLen(rc) < 0; }
        std::string out = nyCall([&] {
            return nypy::percent_format(fmt, (int64_t)args.size(), mapping,
                [&](int64_t i, const std::string& key, char conv) -> nypy::FmtVal {
                    if (i < 0) {
                        auto it = dictFind(rc, makeStringValue(key));
                        if (it == rc->container->end()) pyRaise("KeyError", nypy::str_repr(key));
                        return toFmtVal(it->second, conv, ctx);
                    }
                    return toFmtVal(args[(size_t)i], conv, ctx);
                });
        });
        return makeStringValue(out);
    }

    Value evalBinary(node_ptr node, Context* ctx) {
        BinaryNode* bn = static_cast<BinaryNode*>(node.get());
        int opc = binOpCode(bn->op);
        switch (opc) {
        // `and` / `or` short-circuit on truthiness and yield an operand, as in
        // Python: 0 or "x" is "x", [] or [1] is [1], "" and 1 is "". They used
        // to test only for false/none and always produced a bool for `and`.
        case OP_AND: { Value lv = evalNode(bn->left, ctx); if (!isTruthy(lv)) return lv; return evalNode(bn->right, ctx); }
        case OP_OR:  { Value lv = evalNode(bn->left, ctx); if (isTruthy(lv)) return lv; return evalNode(bn->right, ctx); }
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
            if (!tn.empty()) r = valueIsOfType(lv, tn, ctx);
            else r = identical(lv, evalNode(bn->right, ctx));
            return Value(opc == OP_IS ? r : !r);
        }
        default: break;
        }
        Value lv = evalNode(bn->left, ctx);
        Value rv = evalNode(bn->right, ctx);
        if (opc == OP_UNKNOWN) {
            // a @ b: __matmul__ / __rmatmul__ only.
            if (bn->op == "@") {
                Value res;
                if (binaryDunder("@", lv, rv, ctx, res)) return res;
                pyRaise("TypeError", "unsupported operand type(s) for @: '" + typeNameOf(lv) + "' and '" + typeNameOf(rv) + "'");
            }
            return NONE_VALUE;
        }
        return binaryOp(opc, lv, rv, ctx);
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

    Value evalUnary(node_ptr node, Context* ctx) {
        auto un = static_pointer_cast<UnaryNode>(node);
        Value v = evalNode(un->operand, ctx);
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
                    pyRaise("TypeError", "bad operand type for unary " + op + ": '" + instanceClassName(v) + "'");
                std::vector<Value> no_args;
                return callMethod(v, d, no_args, ctx);
            }
            if (op == "+") return v;
            if (op == "~") return intValue(0);
            return Value(0) - v;
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
                auto attr = static_pointer_cast<AttributeNode>(un->operand);
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
        auto call = [&](const Value& self, const char* name, const Value& arg) {
            std::vector<Value> a{arg};
            out = callMethod(self, name, a, ctx);
        };
        if (li && instanceHasMethod(lv, d)) { call(lv, d, rv); return true; }
        if (op == "/" && li && instanceHasMethod(lv, "__div__")) { call(lv, "__div__", rv); return true; }
        if (ri && instanceHasMethod(rv, rd)) { call(rv, rd, lv); return true; }
        if (op == "!=") {
            Value eq;
            if (binaryDunder("==", lv, rv, ctx, eq)) { out = Value(!isTruthy(eq)); return true; }
        }
        return false;
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
    Value evalPrint(node_ptr node, Context* ctx) {
        auto pn = static_pointer_cast<PrintNode>(node);
        // While tracing, the printed line is also recorded, so the debugger
        // can show exactly the output produced up to the current step.
        std::ostringstream cap;
        std::streambuf* saved = nullptr;
        if (trace_on() && !tracer().in_repr) saved = std::cout.rdbuf(cap.rdbuf());
        struct Restore { std::streambuf* s; ~Restore() { if (s) std::cout.rdbuf(s); } } restore{saved};
        std::string sep = " ", end = "\n";
        if (pn->sep) { Value sv = evalNode(pn->sep, ctx); if (!sv.isNone()) sep = getStringValue(sv); }
        if (pn->end) { Value ev = evalNode(pn->end, ctx); if (!ev.isNone()) end = getStringValue(ev); }
        for (size_t i = 0; i < pn->args.size(); i++) {
            if (i > 0) std::cout << sep;
            Value v = evalNode(pn->args[i], ctx);
            printValue(v, ctx);
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
    }

    void printValueRepr(Value v, Context* ctx = nullptr) { std::cout << reprOf(v, ctx); }

    void printValue(Value v, Context* ctx = nullptr) { std::cout << strOf(v, ctx); }

    // ─── CONTROL FLOW ───────────────────────────────────────────────────
    Value evalIf(node_ptr node, Context* ctx) {
        auto in = static_pointer_cast<IfNode>(node);
        Value cond = evalNode(in->condition, ctx);
        if (isTruthy(cond)) return evalNode(in->then_branch, ctx);
        for (auto& ei : in->elseif_branches) {
            auto eif = static_pointer_cast<IfNode>(ei);
            if (isTruthy(evalNode(eif->condition, ctx))) return evalNode(eif->then_branch, ctx);
        }
        if (in->else_branch) return evalNode(in->else_branch, ctx);
        return NONE_VALUE;
    }

    Value evalWhile(node_ptr node, Context* ctx) {
        auto wn = static_pointer_cast<WhileNode>(node);
        Value result = NONE_VALUE;
        bool broke = false;
        FlowState& lf = flow();
        while (isTruthy(evalNode(wn->condition, ctx))) {
            try { LoopBody _lb(lf); result = evalNode(wn->body, ctx); }
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

    Value evalFor(node_ptr node, Context* ctx) {
        auto fn = static_pointer_cast<ForNode>(node);
        bool broke = false;
        FlowState& lf = flow();
        Value iter_val = evalNode(fn->iterable, ctx);
        std::string var_name = fn->var->value();
        Value result = NONE_VALUE;
        // The loop variable is a local, unless the function declared it
        // `global`/`nonlocal` (then the existing binding is rebound).
        auto bindv = [&](const std::string& n, const Value& v) {
            if (fn->rebinds) ctx->setByName(n, v); else ctx->defineByName(n, v);
        };
        // An object whose __iter__ returns a list, a generator or iter(...):
        // the loop runs over that. (The loop below called __next__ on the
        // list, got none forever and never ended.)
        Value pre_iterator; bool have_pre_iterator = false;
        if (isInstanceValue(iter_val) && instanceHasMethod(iter_val, "__iter__")) {
            std::vector<Value> no_args;
            Value it = callMethod(iter_val, "__iter__", no_args, ctx);
            if (isInstanceValue(it)) { pre_iterator = it; have_pre_iterator = true; }
            else if (it.type != ValueType::NONE && it.type != ValueType::UNDEFINED) iter_val = it;
            else throw std::string("__exc__:TypeError:iter() returned non-iterator of type 'NoneType'");
        }

        // range() returns an integer — iterate 0..n-1
        if (iter_val.type == ValueType::INTEGER) {
            int64_t n = bigint_to_i64(iter_val.value.i);
            for (int64_t i = 0; i < n; i++) {
                bindv(var_name, Value((int)i));
                try { LoopBody _lb(lf); result = evalNode(fn->body, ctx); }
                catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                NY_LOOP_FLOW(broke)
            }
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
                    // Dict/map iteration — iterate all non-internal keys
                    // Over a snapshot of the keys: the body may add or
                    // delete entries.
                    std::vector<Value> keys = iterItems(iter_val, ctx);
                    for (auto& key : keys) {
                        bindv(var_name, key);
                        try { LoopBody _lb(lf); result = evalNode(fn->body, ctx); }
                        catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                        NY_LOOP_FLOW(broke)
                    }
                    return result;
                }
                
                // List iteration by numeric index
                for (int i = 0; i < len; i++) {
                    std::string key = std::to_string(i);
                    auto it = cont->container->find(key);
                    if (it != cont->container->end()) {
                        Value elem = it->second;
                        if (!fn->unpack_vars.empty() && elem.isCollectable() && elem.value.gc) {
                            // Tuple unpacking: destructure element
                            auto* elem_cont = dynamic_cast<Container*>(elem.value.gc);
                            if (elem_cont && elem_cont->container) {
                                // First var gets index 0
                                auto it0 = elem_cont->container->find("0");
                                if (it0 != elem_cont->container->end())
                                    bindv(var_name, it0->second);
                                // Remaining vars get indices 1, 2, ...
                                for (size_t ui = 0; ui < fn->unpack_vars.size(); ui++) {
                                    auto itN = elem_cont->container->find(std::to_string(ui + 1));
                                    if (itN != elem_cont->container->end())
                                        bindv(fn->unpack_vars[ui]->value(), itN->second);
                                }
                            }
                        } else {
                            bindv(var_name, elem);
                        }
                        try { LoopBody _lb(lf); result = evalNode(fn->body, ctx); }
                        catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                        NY_LOOP_FLOW(broke)
                    }
                }
            }
            if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
            return result;
        }

        // String iteration — iterate characters
        if (iter_val.type == ValueType::USERDATA && iter_val.value.p) {
            // Check if it's a string (not in func_names)
            if (!func_names.count(iter_val.value.p)) {
                // By character, not byte.
                std::vector<std::string> chars = nypy::u8_chars(*static_cast<std::string*>(iter_val.value.p));
                for (auto& ch : chars) {
                    bindv(var_name, makeStringValue(ch));
                    try { LoopBody _lb(lf); result = evalNode(fn->body, ctx); }
                    catch (std::string& flow) { if (flow == "break") { broke = true; break; } if (flow == "continue") continue; throw; }
                    NY_LOOP_FLOW(broke)
                }
                if (!broke && fn->else_branch) result = evalNode(fn->else_branch, ctx);
                return result;
            }
        }

        // __iter__/__next__ protocol for user-defined iterables
        if (iter_val.type == ValueType::USERDATA && iter_val.value.p && !string_ptrs_.count(iter_val.value.p) && instance_to_class.count(iter_val.value.p)) {
            // Call __iter__ if present to get the iterator (may return self)
            std::vector<Value> no_args;
            Value iterator = have_pre_iterator ? pre_iterator : iter_val;
            if (!instanceHasMethod(iterator, "__next__"))
                throw std::string("__exc__:TypeError:'" + instanceClassName(iterator) + "' object is not iterable");
            // Now call __next__ repeatedly until StopIteration
            while (true) {
                Value item;
                bool stop = false;
                try {
                    item = callMethod(iterator, "__next__", no_args, ctx);
                } catch (nython::node::ReturnSignal& rs) {
                    item = rs.value;
                } catch (std::string& exc) {
                    if (excTypeMatches(exc, "StopIteration") || exc.find("StopIteration") != std::string::npos) { stop = true; }
                    else throw;
                }
                if (stop) break;
                // Unpack tuples for k,v iteration
                if (!fn->unpack_vars.empty() && item.isCollectable()) {
                    auto* cont = dynamic_cast<Container*>(item.value.gc);
                    if (cont && cont->container) {
                        bindv(var_name, cont->container->count("0") ? (*cont->container)["0"] : NONE_VALUE);
                        for (size_t ui = 0; ui < fn->unpack_vars.size(); ui++) {
                            std::string uname = fn->unpack_vars[ui]->value();
                            auto uit = cont->container->find(std::to_string(ui + 1));
                            bindv(uname, uit != cont->container->end() ? uit->second : NONE_VALUE);
                        }
                    }
                } else {
                    bindv(var_name, item);
                }
                try { LoopBody _lb(lf); result = evalNode(fn->body, ctx); }
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

    Value evalRepeat(node_ptr node, Context* ctx) {
        auto rn = static_pointer_cast<RepeatNode>(node);
        Value count = evalNode(rn->count, ctx);
        int64_t n = (count.type == ValueType::INTEGER) ? bigint_to_i64(count.value.i) : 0;
        Value result = NONE_VALUE;
        bool broke = false;
        FlowState& lf = flow();
        for (int64_t i = 0; i < n; i++) {
            try { LoopBody _lb(lf); result = evalNode(rn->body, ctx); }
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

    Value evalSwitch(node_ptr node, Context* ctx) {
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
    Value evalFunctionDecl(node_ptr node, Context* ctx) {
        auto fn = static_pointer_cast<FunctionNode>(node);
        // Create a unique identity per function instance using a counter
        int64_t fid = ++closure_id_counter;
        auto unique_key = std::make_unique<int64_t>(fid);
        void* unique_ptr = (void*)unique_key.get();
        func_id_store.push_back(std::move(unique_key));

        Value func_val;
        func_val.type = ValueType::USERDATA;
        func_val.value.p = unique_ptr;
        func_names[unique_ptr] = "__func__:" + fn->name;
        closure_contexts[unique_ptr] = ctx;
        markEscaped(ctx);
        // Also store the AST node pointer so we can find the FunctionNode later
        func_ast_nodes[unique_ptr] = (void*)node.get();
        captureDefaults(fn.get(), unique_ptr, ctx);

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
    bool hasYield(node_ptr node) {
        if (!node) return false;
        switch (node->type()) {
            case NodeType::YIELD: case NodeType::YIELD_FROM: return true;
            case NodeType::FUNCTION: case NodeType::LAMBDA: case NodeType::CLASS:
            case NodeType::COMPREHENSION:
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
        if (!raw || raw->type() != NodeType::FUNCTION) return fn_val;
        auto* fn = static_cast<FunctionNode*>(raw);
        if (fn->params.empty()) return fn_val;
        const std::string p0 = fn->params[0]->value();
        if (p0 != "self" && p0 != "this") return fn_val;
        // Reuse an existing binding for this exact (method, instance) pair.
        //
        // Without this, every read of `obj.method` as a VALUE allocated a fresh
        // bound method plus four map entries, none of which were ever released.
        // A loop doing `var f = o.m` leaked ~0.5 KB per iteration: 200k
        // iterations reached 109 MB and 2M reached 1023 MB. The earlier check
        // looked up fn_val.value.p in bound_self_, but that map is keyed by the
        // NEW bound pointer, so it could never hit.
        auto ck = std::make_pair(fn_val.value.p, self_val.value.p);
        auto cached = bound_cache_.find(ck);
        if (cached != bound_cache_.end()) {
            Value hit;
            hit.type    = ValueType::USERDATA;
            hit.value.p = cached->second;
            return hit;
        }

        auto holder = std::make_unique<std::string>("__bound__:" + fn->name);
        void* bp = (void*)holder.get();
        bound_store_.push_back(std::move(holder));
        func_names[bp]      = tag;          // keep "__func__:name" so call paths match
        func_ast_nodes[bp]  = ast_ptr;      // same body
        auto cit = closure_contexts.find(fn_val.value.p);
        if (cit != closure_contexts.end()) { closure_contexts[bp] = cit->second; markEscaped(cit->second); }
        bound_self_[bp] = self_val;
        bound_cache_[ck] = bp;
        Value out;
        out.type    = ValueType::USERDATA;
        out.value.p = bp;
        return out;
    }

    // NOTE: there is deliberately no applyBoundSelf() helper any more.
    // Supplying a bound method's captured instance happens in exactly one
    // place — bindParamsKw() — so no invocation path can forget to do it.

    Value callFunctionValue(Value fn_val, std::vector<Value>& call_args, Context* ctx) {
        if (fn_val.type != ValueType::USERDATA || !fn_val.value.p) return NONE_VALUE;
        auto fit = func_names.find(fn_val.value.p);
        if (fit == func_names.end()) return NONE_VALUE;
        // A class passed as a callable (map(Point, xs), a factory argument).
        if (fit->second.rfind("__class__:", 0) == 0) {
            static const std::unordered_map<std::string, Value> no_kw;
            return instantiateClass(fn_val, call_args, no_kw, ctx);
        }
        // A builtin, an instance or a class is not an AST function: treating its
        // pointer as a Node* crashed (thread_create(print), key=len, map(str, xs)).
        if (fit->second.rfind("__builtin__:", 0) == 0) return callBuiltin(fit->second.substr(12), call_args, ctx);
        if (fit->second.rfind("__instance__:", 0) == 0 || instance_to_class.count(fn_val.value.p)) return callMethod(fn_val, "__call__", call_args, ctx);
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
            if (cit != closure_contexts.end()) closure_parent = cit->second;
            Context* fn_ctx = new Context(runner, fn_node->name, nullptr, nullptr, closure_parent);
            CtxReaper _reap_fn_ctx2020(this, fn_ctx);
            bindParams(fn_node, call_args, fn_ctx, ctx, fn_val.value.p);
            return runFunctionBody(fn_node, fn_ctx);
        } else if (raw->type() == NodeType::LAMBDA) {
            auto* lam = static_cast<LambdaNode*>(raw);
            Context* closure_parent = ctx;
            auto cit = closure_contexts.find(fn_val.value.p);
            if (cit != closure_contexts.end()) closure_parent = cit->second;
            Context* fn_ctx = new Context(runner, "<lambda>", nullptr, nullptr, closure_parent);
            CtxReaper _reap_fn_ctx2033(this, fn_ctx);
            static const std::unordered_map<std::string, Value> no_kw;
            bindLambdaParams(lam, call_args, no_kw, fn_ctx, closure_parent);
            return evalNode(lam->body, fn_ctx);
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
                  || obj.type == ValueType::BOOLEAN || obj.type == ValueType::NONE || isStringValue(obj);
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
        return false;
    }

    Value callMethod(Value obj, const std::string& method_name, std::vector<Value>& args, Context* ctx,
                     const std::unordered_map<std::string, Value>* kw_in = nullptr) {
        static const std::unordered_map<std::string, Value> kEmptyKw;
        const std::unordered_map<std::string, Value>& kw_args_in = kw_in ? *kw_in : kEmptyKw;
        // A generator (eager, see collectGenerator): send(v) advances it as
        // next() does - the value is not delivered, `x = yield` reads none
        // on this engine (the VM delivers it) - and close() exhausts it.
        if (isGenValue(obj)) {
            if (method_name == "send" || method_name == "__next__") {
                std::vector<Value> a{obj};
                return callBuiltin("next", a, ctx);
            }
            if (method_name == "close") {
                auto* c = dynamic_cast<Container*>(obj.value.gc);
                (*c->container)["__idx__"] = (*c->container)["__len__"];
                return NONE_VALUE;
            }
        }
        {
            Value pm;
            if (primitiveMember(obj, method_name, args, ctx, pm)) return pm;
        }
        // Built-in string methods
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            std::string s = getStringValue(obj);
            bool is_string = string_ptrs_.count(obj.value.p) || (!func_names.count(obj.value.p) && !instance_to_class.count(obj.value.p));
            if (is_string) {
                // Every str method has one implementation shared with the VM
                // (NyStr.hpp: nypy::str_method); only format needs values.
                if (method_name == "format") return makeStringValue(strFormat(s, args, kw_args_in, ctx));
                if (method_name == "format_map" && !args.empty()) {
                    std::unordered_map<std::string, Value> kw;
                    if (Container* mc = contOf(args[0])) for (auto& kv : *mc->container) if (!isInternalKey(kv.first)) kw[nypy::key_payload(kv.first)] = kv.second;
                    std::vector<Value> none;
                    return makeStringValue(strFormat(s, none, kw, ctx));
                }
                std::vector<nypy::SArg> sa;
                sa.reserve(args.size());
                for (auto& a : args) sa.push_back(toSArg(a, ctx));
                nypy::SRes r;
                if (nyCall([&] { return nypy::str_method(s, method_name, sa, r); })) return fromSRes(r);
            }
        }

        // dict methods first: the list block below also has pop/remove/clear.
        if (Container* dc = contOf(obj); dc && seqLen(dc) < 0) {
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
                        std::string target_key = set_key_str(args[0]);
                        int found_idx = -1;
                        for (int i = 0; i < len; i++) {
                            auto it = cont->container->find(std::to_string(i));
                            if (it != cont->container->end() && set_key_str(it->second) == target_key) {
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
                    Node* raw = (Node*)ast_ptr;
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
                        if (cit != closure_contexts.end()) cp = cit->second;
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
            if (cn->body) {
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
                if (!pcn->body) continue;
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
                    if (pcn->body) {
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
                        if (pcn->body) {
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
            return callFunctionValue(target, args, ctx);
        }
        {
            std::string err;
            if (attributeErrorFor(obj, method_name, err)) throw err;
        }
        return NONE_VALUE;
    }

    std::vector<std::unique_ptr<int64_t>> func_id_store;
    std::map<void*, void*> func_ast_nodes;
    std::vector<node_ptr> imported_asts; // keep imported ASTs alive // unique_ptr -> AST node ptr
    std::unordered_set<std::string> imported_modules_; // prevent circular imports

    Value evalClassDecl(node_ptr node, Context* ctx) {
        auto cn = static_pointer_cast<ClassNode>(node);
        Value class_val;
        class_val.type = ValueType::USERDATA;
        class_val.value.p = (void*)node.get();
        func_names[(void*)node.get()] = "__class__:" + cn->name;
        class_by_name[cn->name] = (void*)node.get();
        mro_cache_.clear();
        if (cn->body)
            for (auto& st : cn->body->statements())
                if (st && st->type() == NodeType::FUNCTION) direct_methods_.insert(st.get());
        // Store parent class if exists
        if (!cn->bases.empty()) {
            // bases[0] is a VariableNode with parent class name
            class_parent[(void*)node.get()] = cn->bases[0]->value();
        }
        ctx->defineByName(cn->name, class_val);
        if (cn->body) {
            Context* class_ctx = new Context(runner, cn->name, nullptr, nullptr, ctx);
            class_ctx->inClass = true;
            evalNode(cn->body, class_ctx);
            // Store the evaluated class context so decorators (@property, @staticmethod) are visible
            class_ctx_map_[(void*)node.get()] = class_ctx;
            markEscaped(class_ctx);
        }
        return class_val;
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
    Value evalInterfaceDecl(node_ptr node, Context* ctx) {
        auto in_ = static_pointer_cast<InterfaceNode>(node);
        Value class_val;
        class_val.type = ValueType::USERDATA;
        class_val.value.p = (void*)node.get();
        func_names[(void*)node.get()] = "__class__:" + in_->name;
        class_by_name[in_->name] = (void*)node.get();
        ctx->defineByName(in_->name, class_val);
        if (in_->body) {
            Context* iface_ctx = new Context(runner, in_->name, nullptr, nullptr, ctx);
            evalNode(in_->body, iface_ctx);
            class_ctx_map_[(void*)node.get()] = iface_ctx;
            markEscaped(iface_ctx);
        }
        return class_val;
    }

    Value evalLambda(node_ptr node, Context* ctx) {
        int64_t fid = ++closure_id_counter;
        auto unique_key = std::make_unique<int64_t>(fid);
        void* unique_ptr = (void*)unique_key.get();
        func_id_store.push_back(std::move(unique_key));

        // Create a persistent closure context that copies current bindings
        // This prevents dangling pointers when the enclosing function returns
        Context* closure_ctx = new Context(runner, "__closure__", nullptr, nullptr, ctx->parent);
        if (ctx->container) {
            for (auto& [k, v] : *ctx->container) {
                closure_ctx->defineByName(k, v);
            }
        }
        // Also walk up and copy parent bindings for nested closures
        Context* walk = ctx->parent;
        while (walk) {
            if (walk->container) {
                for (auto& [k, v] : *walk->container) {
                    // Only copy if not already defined (local takes priority)
                    try {
                        Value existing = closure_ctx->getByName(k);
                        if (existing.type == ValueType::UNDEFINED) {
                            closure_ctx->defineByName(k, v);
                        }
                    } catch (...) {
                        closure_ctx->defineByName(k, v);
                    }
                }
            }
            walk = walk->parent;
        }

        Value fn_val;
        fn_val.type = ValueType::USERDATA;
        fn_val.value.p = unique_ptr;
        func_names[unique_ptr] = "__lambda__";
        closure_contexts[unique_ptr] = closure_ctx;
        markEscaped(closure_ctx);
        func_ast_nodes[unique_ptr] = (void*)node.get();
        return fn_val;
    }


    // Helper: build a positional args list and a keyword map from a CallNode's arg list
    // Returns positional args in call_args, named args in kw_args (name->value)
    void evalCallArgs(const std::vector<node_ptr>& raw_args, Context* ctx,
                      std::vector<Value>& call_args,
                      std::unordered_map<std::string, Value>& kw_args) {
        for (auto& a : raw_args) {
            if (a->type() == NodeType::KEYWORD_ARG) {
                // Named argument: name=value
                auto kn = static_pointer_cast<KeywordArgNode>(a);
                kw_args[kn->name] = evalNode(kn->val, ctx);
            } else if (a->type() == NodeType::UNARY) {
                auto un = static_pointer_cast<UnaryNode>(a);
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
                      const std::unordered_map<std::string, Value>& kw_args,
                      Context* fn_ctx, Context* eval_ctx, size_t skip_params = 0,
                      void* callee_ptr = nullptr) {
        std::vector<Value> bound_args;
        std::vector<Value>* argp = &call_args;
        if (callee_ptr && skip_params == 0) {
            auto bs = bound_self_.find(callee_ptr);
            if (bs != bound_self_.end()) {
                bound_args.reserve(call_args.size() + 1);
                bound_args.push_back(bs->second);
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
    void bindParamsImpl(FunctionNode* fn, std::vector<Value>& call_args,
                        const std::unordered_map<std::string, Value>& kw_args,
                        Context* fn_ctx, Context* eval_ctx, size_t skip_params,
                        void* callee_ptr = nullptr) {
        size_t arg_idx = 0;
        bool star_seen = false, has_varargs = false;
        std::string kw_collect;
        std::unordered_set<std::string> named;
        std::vector<std::string> missing;
        std::string err;
        size_t min_pos = 0, max_pos = 0;
        for (size_t i = skip_params; i < fn->params.size(); i++) {
            std::string pname = fn->params[i]->value();
            if (pname == "*") { star_seen = true; continue; }
            if (pname.size() > 1 && pname[0] == '*' && pname[1] != '*') {
                has_varargs = true;
                // *args: collect remaining positional args into a list
                std::string real_name = pname.substr(1);
                Object* varargs = new Object((Runnable*)runner, "list", Type::LIST);
                int va_idx = 0;
                while (!star_seen && arg_idx < call_args.size()) {
                    varargs->set(std::to_string(va_idx++), call_args[arg_idx++]);
                }
                varargs->set("__len__", Value(va_idx));
                fn_ctx->defineByName(real_name, Value((Collectable*)varargs));
                star_seen = true;
            } else if (pname.size() > 2 && pname[0] == '*' && pname[1] == '*') {
                kw_collect = pname.substr(2);
            } else {
                if (!kw_args.empty()) named.insert(pname);   // only read when keywords were passed
                auto kw_it = kw_args.find(pname);
                bool has_default = i < fn->defaults.size() && fn->defaults[i];
                if (!star_seen) { max_pos++; if (!has_default) min_pos++; }
                if (!star_seen && arg_idx < call_args.size()) {
                    if (kw_it != kw_args.end() && err.empty())
                        err = fn->name + "() got multiple values for argument '" + pname + "'";
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
            for (auto& [k, v] : kw_args) if (!named.count(k)) kwargs_obj->set(k, v);
            fn_ctx->defineByName(kw_collect, Value((Collectable*)kwargs_obj));
        } else if (err.empty()) {
            for (auto& [k, v] : kw_args)
                if (!named.count(k)) { err = fn->name + "() got an unexpected keyword argument '" + k + "'"; break; }
        }
        // A call that does not fit raises TypeError, in Python's words (the
        // missing parameters were none and extra arguments were dropped).
        // A bound self counts, as Python counts it.
        if (err.empty())
            err = nython::ny_arity_error(fn->name, missing, min_pos + skip_params,
                                         has_varargs ? -1L : (long)(max_pos + skip_params),
                                         call_args.size() + skip_params);
        if (!err.empty()) throw std::string("__exc__:TypeError:" + err);
    }
    // The same for a lambda: binds its parameters (positional, keyword,
    // *args, defaults evaluated in `def_ctx`) and checks the call fits.
    void bindLambdaParams(LambdaNode* lam, std::vector<Value>& args,
                          const std::unordered_map<std::string, Value>& kw, Context* fc, Context* def_ctx) {
        size_t ai = 0, min_pos = 0, max_pos = 0;
        bool has_varargs = false;
        std::vector<std::string> missing;
        for (size_t i = 0; i < lam->params.size(); i++) {
            std::string pname = lam->params[i]->value();
            if (pname.size() > 1 && pname[0] == '*' && pname[1] != '*') {
                Object* varargs = new Object((Runnable*)runner, "list", Type::LIST);
                int va_idx = 0;
                while (ai < args.size()) varargs->set(std::to_string(va_idx++), args[ai++]);
                varargs->set("__len__", Value(va_idx));
                fc->defineByName(pname.substr(1), Value((Collectable*)varargs));
                has_varargs = true;
                continue;
            }
            bool has_default = i < lam->defaults.size() && lam->defaults[i];
            max_pos++; if (!has_default) min_pos++;
            auto kw_it = kw.find(pname);
            if (ai < args.size()) fc->defineByName(pname, args[ai++]);
            else if (kw_it != kw.end()) fc->defineByName(pname, kw_it->second);
            else if (has_default) fc->defineByName(pname, evalNode(lam->defaults[i], def_ctx));
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
    static const int kMaxCallDepth = 900;
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
        auto tk = n->token();
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
        last_stmt() = st;
        if (trace_on()) traceStatement(st, ctx);
    }

    void traceStatement(const node_ptr& st, Context* ctx) {
        auto& T = tracer();
        if (!st || T.in_repr || T.capped) return;
        auto tk = st->token();
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

    // Best-effort display name for a call site: `f()`, `obj.m()` -> "obj.m".
    std::string callTargetName(const std::shared_ptr<CallNode>& cn) {
        if (!cn || !cn->callee) return std::string();
        if (cn->callee->type() == NodeType::ATTRIBUTE) {
            auto at = static_pointer_cast<AttributeNode>(cn->callee);
            std::string base;
            if (at->object && at->object->type() == NodeType::VARIABLE)
                base = at->object->token().value + ".";
            else if (at->object && at->object->type() == NodeType::SELF)
                base = "self.";
            return base + at->attr;
        }
        if (cn->callee->type() == NodeType::VARIABLE)
            return cn->callee->token().value;
        return std::string();
    }

    Value evalCall(node_ptr node, Context* ctx) {
        if (call_depth_ >= kMaxCallDepth)
            throw std::string("__exc__:RecursionError:maximum call depth exceeded ("
                              + std::to_string(kMaxCallDepth) + ") — check for unintended "
                              "self-recursion, e.g. a method with the same name as a builtin");
        DepthGuard _depth_guard(call_depth_);
        auto cn = static_pointer_cast<CallNode>(node);
        // Zero cost when profiling is off: ProfScope short-circuits on the flag.
        ProfScope _prof(this, profiling_enabled() ? callTargetName(cn) : std::string());
        TraceFrame _trace_frame(trace_on() ? callTargetName(cn) : std::string());

        // Special handling for method calls: obj.method(args)
        if (cn->callee->type() == NodeType::ATTRIBUTE) {
            auto attr = static_pointer_cast<AttributeNode>(cn->callee);
            std::string method_name = attr->attr;

            // ── super.method(args) — call parent class method with current self ──
            // Match both `super.method()` and `super().method()` patterns
            bool is_super_call = attr->object->type() == NodeType::SUPER;
            if (!is_super_call && attr->object->type() == NodeType::CALL) {
                auto* call_node = static_cast<CallNode*>(attr->object.get());
                if (call_node->callee && call_node->callee->type() == NodeType::SUPER)
                    is_super_call = true;
            }
            if (is_super_call && !owner_stack_.empty() && owner_stack_.back()) {
                // super().m(...): m from the class after the one defining the
                // running method, in the MRO of self's class, called with the
                // keyword arguments; its exceptions propagate. (Only the
                // first base of the class was searched, keyword arguments were
                // dropped and every exception was swallowed.)
                Value self_val = ctx->getByName("self");
                std::vector<Value> sargs; std::unordered_map<std::string, Value> skw;
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
                std::vector<Value> args; std::unordered_map<std::string, Value> kw_args;
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
                            if (pcn->body) {
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

            Value obj = evalNode(attr->object, ctx);

            // Evaluate arguments
            std::vector<Value> args; std::unordered_map<std::string, Value> kw_args;
            evalCallArgs(cn->args, ctx, args, kw_args);

            // Check class_ctx_map_ FIRST for decorated methods (e.g. @decorator on class method)
            // This ensures we call the decorated wrapper with self injected into *args.
            // (Decorated methods - functions a decorator returned into the
            // class namespace - are called by callMethod through the MRO.)

            // In Nython, everything is an object. Attributes can store callables
            // (functions, lambdas, closures). Check the attribute VALUE first;
            // if it is a callable, invoke it directly rather than as a named method.
            if (obj.type == ValueType::USERDATA && obj.value.p) {
                auto pit = instance_properties.find(obj.value.p);
                if (pit != instance_properties.end()) {
                    try {
                        Value attr_val = pit->second->getByName(method_name);
                        // An object with __call__ held in an attribute.
                        if (isInstanceValue(attr_val) && instanceHasMethod(attr_val, "__call__"))
                            return callMethod(attr_val, "__call__", args, ctx, &kw_args);
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
                                    pit->second->access_container_shared([&](ContainerType* c) { own = c && c->count(method_name); });
                                    if (!own) is_bi = false;
                                }
                                if (is_fn || is_lam || is_bi) {
                                    if (is_bi) return callBuiltin(fn_type.substr(12), args, ctx);
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
                                        if (cit != closure_contexts.end()) cp = cit->second;
                                        Context* fc = new Context(runner, "<lambda>", nullptr, nullptr, cp);
                                        CtxReaper _reap_fc3618(this, fc);
                                        bindLambdaParams(lam, args, kw_args, fc, cp);
                                        return evalNode(lam->body, fc);
                                    } else if (raw->type() == NodeType::FUNCTION) {
                                        auto fn = static_cast<FunctionNode*>(raw);
                                        Context* cp = ctx;
                                        auto cit = closure_contexts.find(attr_val.value.p);
                                        if (cit != closure_contexts.end()) cp = cit->second;
                                        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                                        CtxReaper _reap_fc3627(this, fc);
                                        bindParams(fn, args, fc, ctx, attr_val.value.p);
                                        return runFunctionBody(fn, fc);
                                    }
                                }
                            }
                        }
                    } catch (...) { throw; }   // the call's exceptions propagate
                }
            }

            // Also check collectable dict containers (e.g. math module, namespace objects)
            if (obj.isCollectable() && obj.value.gc) {
                auto* cont = dynamic_cast<Container*>(obj.value.gc);
                if (cont && cont->container) {
                    auto attr_it = cont->container->find(method_name);
                    if (attr_it != cont->container->end()) {
                        Value attr_val = attr_it->second;
                        if (attr_val.type == ValueType::USERDATA && attr_val.value.p) {
                            auto fn_it = func_names.find(attr_val.value.p);
                            if (fn_it != func_names.end()) {
                                if (fn_it->second.find("__builtin__:") == 0)
                                    return callBuiltin(fn_it->second.substr(12), args, ctx);
                                if (fn_it->second.find("__func__:") == 0 || fn_it->second.find("__lambda__") == 0) {
                                    void* ast_ptr = attr_val.value.p;
                                    auto ai = func_ast_nodes.find(attr_val.value.p);
                                    if (ai != func_ast_nodes.end()) ast_ptr = ai->second;
                                    Node* raw = (Node*)ast_ptr;
                                    if (raw && raw->type() == NodeType::FUNCTION) {
                                        auto fn = static_cast<FunctionNode*>(raw);
                                        Context* cp = ctx;
                                        auto ci = closure_contexts.find(attr_val.value.p);
                                        if (ci != closure_contexts.end()) cp = ci->second;
                                        Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                                        CtxReaper _reap_fc3662(this, fc);
                                        bindParamsKw(fn, args, kw_args, fc, ctx, 0, attr_val.value.p);
                                        return runFunctionBody(fn, fc);
                                    }
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
                // Reuse it via receiver_cache() instead of evaluating again.
                receiver_cache()[attr->object.get()] = obj;
                Value callee_val;
                try { callee_val = evalAttribute(cn->callee, ctx, true); }
                catch (...) { receiver_cache().erase(attr->object.get()); throw; }
                receiver_cache().erase(attr->object.get());
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
                        if (!stray && fn_it->second.find("__builtin__:") == 0)
                            return callBuiltin(fn_it->second.substr(12), args, ctx);
                        // Class value accessed via attribute (e.g. Outer.Inner()) -> instantiate
                        if (fn_it->second.find("__class__:") == 0) {
                            // Re-invoke evalCall with this as the callee directly
                            // Build a synthetic call: reuse current evalCall non-ATTRIBUTE path
                            std::string class_fname = fn_it->second;
                            std::string className = class_fname.substr(10);
                            Value instance;
                            instance.type = ValueType::USERDATA;
                            auto inst_ptr = std::make_unique<std::string>("__instance__:" + className);
                            instance.value.p = (void*)inst_ptr.get();
                            instance_store.push_back(std::move(inst_ptr));
                            instance_to_class[instance.value.p] = callee_val.value.p;
                            func_names[instance.value.p] = "__instance__:" + className;
                            Context* props = new Context(runner, className + "_props", nullptr, nullptr, nullptr);
                            instance_properties[instance.value.p] = props;
                            if (isExceptionClass(className)) setExceptionArgs(instance, args);
                            runConstructor(instance, args, kw_args, ctx);
                            return instance;
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
            return callMethod(obj, method_name, args, ctx, &kw_args);
        }

        // super(args) / a bare super() call: Nython's shorthand for calling
        // the parent class's constructor (super(name, 4)). It did nothing.
        if (cn->callee->type() == NodeType::SUPER && !owner_stack_.empty() && owner_stack_.back()) {
            Value self_val = ctx->getByName("self");
            std::vector<Value> sargs; std::unordered_map<std::string, Value> skw;
            evalCallArgs(cn->args, ctx, sargs, skw);
            Value out;
            superCall(self_val, owner_stack_.back(), "__init__", sargs, skw, ctx, out);
            return NONE_VALUE;
        }

        Value callee = evalNode(cn->callee, ctx);

        // Evaluate arguments (handles keyword args, *spread, **spread)
        std::vector<Value> args;
        std::unordered_map<std::string, Value> kw_args;
        evalCallArgs(cn->args, ctx, args, kw_args);

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
        if (fname.empty()) fname = callee.token.value;
        if (fname.find("__builtin__:") == 0) {
            std::string builtin = fname.substr(12);
            // Flatten kwargs for builtins that accept them (key=, reverse=, default=)
            // The core builtins (builtins/pycore.cpp) read their keyword
            // arguments by name. Flattening them into positional arguments
            // made min(a, b, key=f) look like min(a, b, f).
            static const std::unordered_set<std::string> kw_native = {
                "sorted", "min", "max", "sum", "enumerate", "round", "int", "dict", "pow",
                "format", "range", "zip", "map", "filter", "list", "tuple", "set", "str", "repr"
            };
            if (kw_native.count(builtin)) {
                cur_kw_order_.clear();
                for (auto& an : cn->args)
                    if (an->type() == NodeType::KEYWORD_ARG) cur_kw_order_.push_back(static_pointer_cast<KeywordArgNode>(an)->name);
                KwScope ks(this, kw_args.empty() ? nullptr : &kw_args);
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
            static const std::unordered_set<std::string> kwmap_builtins = {
                "os_run", "subprocess_run", "os_spawn", "os_wait", "os_kill",
                "os_getenv", "getenv", "env", "os_makedirs", "os_rmtree",
                "os_mkstemp", "os_mkdtemp", "os_path_relpath",
                "time_format", "time_date", "time_strftime", "time_iso",
                "file_open", "file_open_or_raise", "os_proc_read", "os_poll"
            };
            if (!kw_args.empty() && kwmap_builtins.count(builtin)) {
                auto* kw = new Object((Runnable*)runner, "map", Type::MAP);
                for (auto& kv : kw_args) kw->set(kv.first, kv.second);
                args.push_back(Value((Collectable*)kw));
            }
            return callBuiltin(builtin, args, ctx);
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
                    if (cit != closure_contexts.end()) closure_parent = cit->second;
                    Context* fn_ctx = new Context(runner, fn->name, nullptr, nullptr, closure_parent);
                    CtxReaper _reap(this, fn_ctx);
                    // Bind parameters with keyword arg and *args support
                    bindParamsKw(fn, args, kw_args, fn_ctx, ctx, 0, callee.value.p);
                    return runFunctionBody(fn, fn_ctx);
                } else if (raw->type() == NodeType::LAMBDA) {
                    auto lam = static_cast<LambdaNode*>(raw);
                    // Use closure context if available (for returned lambdas)
                    Context* closure_parent = ctx;
                    auto cit2 = closure_contexts.find(callee.value.p);
                    if (cit2 != closure_contexts.end()) closure_parent = cit2->second;
                    Context* fn_ctx = new Context(runner, "<lambda>", nullptr, nullptr, closure_parent);
                    CtxReaper _reap_fn_ctx3854(this, fn_ctx);
                    bindLambdaParams(lam, args, kw_args, fn_ctx, closure_parent);
                    Value result = evalNode(lam->body, fn_ctx);
                    return result;
                }
            }
        }

        // __call__ protocol: if callee is an instance with __call__ method, invoke it
        if (callee.type == ValueType::USERDATA && callee.value.p && !string_ptrs_.count(callee.value.p) &&
            fname.find("__instance__:") == 0 && instance_to_class.count(callee.value.p)) {
            if (!instanceHasMethod(callee, "__call__"))
                throw std::string("__exc__:TypeError:'" + instanceClassName(callee) + "' object is not callable");
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

        // Check for Object.call if callee is collectable
        if (callee.isCollectable() && callee.value.gc) {
            auto* obj = dynamic_cast<Object*>(callee.value.gc);
            if (obj) return obj->call(args);
        }

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
    std::vector<std::unique_ptr<std::string>> bound_store_;
    std::map<void*, Value> bound_self_;   // bound-method ptr -> the instance
    // (method ptr, instance ptr) -> bound-method ptr, so re-reading the same
    // method off the same object reuses one binding instead of leaking a new one.
    std::map<std::pair<void*, void*>, void*> bound_cache_;
    std::map<void*, void*> instance_to_class; // instance ptr -> class node ptr
    std::map<void*, Context*> instance_properties;
    std::map<std::string, void*> class_by_name; // className -> class node ptr
    std::vector<std::string> super_parent_stack; // for chained super() calls
    std::map<void*, std::string> class_parent; // class node ptr -> parent class name
    std::unordered_map<void*, Value> exc_instance_map_; // raised instance ptr -> Value
    std::map<std::string, Value> class_vars_; // "ClassName.varName" -> Value (shared class-level variables)
    std::map<void*, Context*> class_ctx_map_; // class node ptr -> evaluated class body context (for decorators)


    // Public (struct default) so the VM builtin bridge can dispatch by name.
    Value callBuiltin(const std::string& name_orig, std::vector<Value>& args, Context* ctx) {
        {
            Value r;
            if (iterableBuiltin(name_orig, args, ctx, r)) return r;
        }
        if (name_orig.rfind("__prop_setter__:", 0) == 0) {
            uintptr_t gp = 0;
            std::istringstream iss(name_orig.substr(16));
            iss >> std::hex >> gp;
            if (!args.empty()) prop_setters_[reinterpret_cast<void*>(gp)] = args[0];
            Value g; g.type = ValueType::USERDATA; g.value.p = reinterpret_cast<void*>(gp);
            return g;
        }
        // ── Exception type constructors ─────────────────────────────────────────
        // ── property() and staticmethod() ─────────────────────────────────────
        if (name_orig == "property") {
            // property(fn) — tag the function value with __property__ marker
            any_property_ = true;
            if (!args.empty() && args[0].type == ValueType::USERDATA && args[0].value.p) {
                func_names[args[0].value.p] += "__property__";
                return args[0];
            }
            return NONE_VALUE;
        }
        if (name_orig == "staticmethod") {
            // staticmethod(fn) — tag with __static__ so it's called without self
            if (!args.empty() && args[0].type == ValueType::USERDATA && args[0].value.p) {
                func_names[args[0].value.p] += "__static__";
                return args[0];
            }
            return NONE_VALUE;
        }
        if (name_orig == "classmethod") {
            // classmethod(fn) — tag with __classmethod__
            if (!args.empty() && args[0].type == ValueType::USERDATA && args[0].value.p) {
                func_names[args[0].value.p] += "__classmethod__";
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
            "UnicodeError"
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
        result = dispatch_math(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_os(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_data(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_threading(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_gui(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        result = dispatch_text(*this, name, args, ctx); if (result.type != ValueType::UNDEFINED) return result;
        return NONE_VALUE;
    }


    // ─── COLLECTIONS ────────────────────────────────────────────────────
    Value evalList(node_ptr node, Context* ctx) {
        auto ln = static_pointer_cast<ListNode>(node);
        bool is_tuple = (node->type() == NodeType::TUPLE);
        auto* obj = new Object((Runnable*)runner, is_tuple ? "tuple" : "list", Type::LIST);
        int idx = 0;
        for (auto& el : ln->elements) {
            obj->set(std::to_string(idx++), evalNode(el, ctx));
        }
        obj->set("__len__", Value((int)idx));
        if (is_tuple) obj->set("__tuple__", Value(1));
        return Value((Collectable*)obj);
    }

    Value evalMap(node_ptr node, Context* ctx) {
        auto mn = static_pointer_cast<MapNode>(node);
        auto* cont = new Object((Runnable*)runner, "map", Type::MAP);
        for (auto& e : mn->entries) {
            auto me = static_pointer_cast<MapEntryNode>(e);
            Value key = evalNode(me->key, ctx);
            Value val = evalNode(me->val, ctx);
            // Use string key for map storage
            dictSet(cont, key, val);
        }
        return Value((Collectable*)cont);
    }

    Value evalRange(node_ptr node, Context* ctx) {
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
    // Receivers already evaluated by evalCall, keyed by the object node. Lets
    // the callee-lookup fallback reuse a receiver instead of re-running it.
    // Per OS thread (round 74): two threads can run the same call node.
    // A function-local thread_local, not an `inline thread_local` member:
    // MinGW (the Windows build) emits the member's TLS init function in every
    // object that includes this header and the link fails with "multiple
    // definition of TLS init function".
    static std::unordered_map<const void*, Value>& receiver_cache() {
        static thread_local std::unordered_map<const void*, Value> m;
        return m;
    }

    // soft: a missing attribute of an instance or class reads UNDEFINED
    // instead of raising AttributeError (for hasattr/getattr, and for the
    // method-call path, where callMethod decides).
    Value evalAttribute(node_ptr node, Context* ctx, bool soft = false) {
        auto an = static_pointer_cast<AttributeNode>(node);
        Value obj;
        {
            auto rc = receiver_cache().find(an->object.get());
            if (rc != receiver_cache().end()) obj = rc->second;
            else obj = evalNode(an->object, ctx);
        }
        // Check instance properties first (and invoke @property getters)
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto pit = instance_properties.find(obj.value.p);
            if (pit != instance_properties.end()) {
                Value v = pit->second->getByName(an->attr);
                if (v.type != ValueType::UNDEFINED) {
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
                                if (cit != closure_contexts.end()) closure_parent = cit->second;
                                Context* fc = new Context(runner, fn->name, nullptr, nullptr, closure_parent);
                                fc->defineByName("self", obj);
                                return runFunctionBody(fn, fc);
                            }
                        }
                    }
                    return v;
                }
            }
        }
        if (obj.isCollectable() && obj.value.gc) {
            auto* cont = dynamic_cast<Container*>(obj.value.gc);
            if (cont && cont->container) {
                auto it = cont->container->find(an->attr);
                if (it != cont->container->end()) return it->second;
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
                std::string target = nyrt::builtin_member(bit->second.substr(12), an->attr,
                    [&](const std::string& n) { return builtin_ptrs.count(n) > 0; });
                if (!target.empty()) return builtinValue(target);
                return NONE_VALUE;
            }
        }
        // Class variable / static method lookup: ClassName.var or ClassName.staticmethod
        // Also handles instance.property for @property getters not stored per-instance
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            // If obj is an instance, find its class; if it IS a class, use directly
            void* class_ptr = obj.value.p;
            auto inst_it = instance_to_class.find(class_ptr);
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
                        auto own = ctx_it->second->container->find(an->attr);
                        if (own != ctx_it->second->container->end()) cv = own->second;
                    }
                    if (cv.type == ValueType::NONE) return cv;   // `x = None` in the class body
                    if (cv.type != ValueType::UNDEFINED) {
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
                                    if (cit2 != closure_contexts.end()) cp = cit2->second;
                                    Context* fc = new Context(runner, fn->name, nullptr, nullptr, cp);
                                    fc->defineByName("self", obj);
                                    return runFunctionBody(fn, fc);
                                }
                            }
                        }
                        // A method read as a value off an INSTANCE must carry its
                        // instance with it, or `self` is lost at call time.
                        if (instance_to_class.count(obj.value.p))
                            return makeBoundMethod(cv, obj);
                        return cv;
                    }
                }
                // Check class_vars_ (mutable class-level variables set at runtime)
                std::string cv_key = cn->name + "." + an->attr;
                auto cv_it = class_vars_.find(cv_key);
                if (cv_it != class_vars_.end()) return cv_it->second;
                // Not yet set — evaluate class-level default from body
                if (cn->body) {
                    for (auto& stmt : cn->body->statements()) {
                        if (stmt->type() == NodeType::ASSIGNMENT) {
                            auto as = static_pointer_cast<AssignmentNode>(stmt);
                            if (as->target->type() == NodeType::VARIABLE && as->target->value() == an->attr) {
                                return evalNode(as->value_node, ctx);
                            }
                        }
                    }
                }
              }
            }
        }
        return specialAttribute(obj, an->attr, ctx, soft);
    }
    // obj.name for a value in hand: UNDEFINED when it has no such attribute.
    Value lookupAttribute(const Value& obj, const std::string& name, Context* ctx) {
        auto objn = std::make_shared<VariableNode>(Token());
        auto an = std::make_shared<AttributeNode>(Token(), objn, name);
        receiver_cache()[objn.get()] = obj;
        try {
            Value v = evalAttribute(an, ctx, true);
            receiver_cache().erase(objn.get());
            return v;
        } catch (...) { receiver_cache().erase(objn.get()); throw; }
    }
    // The AttributeError for obj.name, when obj is an instance or a class.
    bool attributeErrorFor(const Value& obj, const std::string& name, std::string& err) {
        if (isInstanceValue(obj)) {
            err = "__exc__:AttributeError:'" + instanceClassName(obj) + "' object has no attribute '" + name + "'";
            return true;
        }
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            std::string t = fnTag(func_names, obj.value.p);
            if (t.rfind("__class__:", 0) == 0) {
                std::string cn = t.substr(10);
                size_t tag = cn.find("__");
                if (tag != std::string::npos && tag > 0) cn = cn.substr(0, tag);
                err = "__exc__:AttributeError:type object '" + cn + "' has no attribute '" + name + "'";
                return true;
            }
        }
        return false;
    }
    // Attributes every value answers: __name__ of a function or class (and of
    // the name string type() returns), an instance's __class__, and what an
    // instance's __getattr__ supplies for anything it does not have.
    // Properties: a getter function tagged __property__; its setter, from
    // @prop.setter, is kept here.
    std::unordered_map<void*, Value> prop_setters_;
    bool any_property_ = false;   // no property anywhere: attribute stores skip the class lookup
    std::vector<std::unique_ptr<std::string>> prop_setter_ids_;
    Value specialAttribute(const Value& obj, const std::string& attr, Context* ctx, bool soft = false) {
        if (obj.type == ValueType::USERDATA && obj.value.p) {
            auto fit = func_names.find(obj.value.p);
            // prop.setter: a callable that records its argument as the
            // property's setter and returns the property.
            if (attr == "setter" && fit != func_names.end() && fit->second.find("__property__") != std::string::npos) {
                std::ostringstream os; os << "__prop_setter__:" << obj.value.p;
                prop_setter_ids_.push_back(std::make_unique<std::string>(os.str()));
                void* id = prop_setter_ids_.back().get();
                func_names[id] = "__builtin__:" + os.str();
                Value v; v.type = ValueType::USERDATA; v.value.p = id;
                return v;
            }
            // C.__mro__ / C.__bases__: the classes, in C3 order / as written.
            if ((attr == "__mro__" || attr == "__bases__") && fit != func_names.end()
                && fit->second.rfind("__class__:", 0) == 0) {
                Node* cn = classNodeByName(fit->second.substr(10));
                std::vector<Value> out;
                if (cn) {
                    std::vector<Node*> seq;
                    if (attr == "__mro__") seq = classMro(cn);
                    else for (auto& b : static_cast<ClassNode*>(cn)->bases) if (Node* bn = classNodeByName(b->value())) seq.push_back(bn);
                    for (Node* c : seq) { Value cv; cv.type = ValueType::USERDATA; cv.value.p = (void*)c; out.push_back(cv); }
                }
                return makeListValue(out, attr == "__mro__");
            }
            if (attr == "__name__") {
                if (fit != func_names.end()) {
                    const std::string& t = fit->second;
                    size_t c = t.find(':');
                    std::string nm = c == std::string::npos ? t : t.substr(c + 1);
                    size_t tag = nm.find("__");
                    if (tag != std::string::npos && tag > 0) nm = nm.substr(0, tag);   // name__static__ etc
                    return makeStringValue(nm);
                }
                if (isStringValue(obj)) return obj;
            }
            if (isInstanceValue(obj)) {
                if (attr == "__class__") {
                    Value cv; cv.type = ValueType::USERDATA;
                    cv.value.p = instance_to_class[obj.value.p];
                    return cv;
                }
                if (instanceHasMethod(obj, "__getattr__")) {
                    std::vector<Value> a{makeStringValue(attr)};
                    return callMethod(obj, "__getattr__", a, ctx);
                }
            }
        }
        // A missing attribute of an instance or a class: hasattr / getattr
        // see it as missing. A plain read still gives none - library code
        // (lib/gui.ny above all) probes optional attributes that way
        // (`if w.rect != none`, `widget.is_layout == true`); raising
        // AttributeError there is one switch away once those idioms are
        // ported to hasattr/getattr. Calling a missing method does raise
        // (callMethod).
        std::string err;
        if (attributeErrorFor(obj, attr, err)) {
            if (soft) return UNDEFINED_VALUE;
            if (kStrictAttributeReads) throw err;
        }
        return NONE_VALUE;
    }
    static constexpr bool kStrictAttributeReads = false;

    // ─── RETURN ─────────────────────────────────────────────────────────
    Value evalReturn(node_ptr node, Context* ctx) {
        auto rn = static_pointer_cast<ReturnNode>(node);
        Value val = rn->expr ? evalNode(rn->expr, ctx) : NONE_VALUE;
        FlowState& f = flow();
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
        if ((v.isCollectable() && v.value.gc) || isStringValue(v)) return iterItems(v, ctx);
        if (isInstanceValue(v)) {
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
                throw std::string("__exc__:TypeError:'" + instanceClassName(v) + "' object is not iterable");
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

    Value evalComprehensionNode(node_ptr node, Context* ctx) {
        auto cn = static_pointer_cast<ComprehensionNode>(node);
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
            for (auto& item : iterValues(itv, cc)) {
                bindTarget(cl.target, item, cc);
                bool keep = true;
                for (auto& c : cl.conds) if (!isTruthy(evalNode(c, cc))) { keep = false; break; }
                if (!keep) continue;
                if (k + 1 < cn->clauses.size()) clause(k + 1);
                else if (cn->kind == ComprehensionNode::DICT) {
                    Value kv = evalNode(cn->elt, cc);
                    kvs.push_back({kv, evalNode(cn->value, cc)});
                }
                else items.push_back(evalNode(cn->elt, cc));
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

    Value evalComprehension(node_ptr node, Context* ctx) {
        auto cn = static_pointer_cast<ComplexNode>(node);
        if (cn->items.size() < 2) return NONE_VALUE;
        // List comprehension: [expr for var in iterable if cond]
        std::string var_name = cn->token().value;
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
    // Sets an exception instance's args (and the legacy msg) from the
    // constructor or super().__init__ arguments.
    void setExceptionArgs(const Value& inst, const std::vector<Value>& args) {
        auto pit = instance_properties.find(inst.value.p);
        if (pit == instance_properties.end()) return;
        pit->second->defineByName("args", makeListValue(args));
        pit->second->defineByName("msg", makeStringValue(args.size() == 1 ? valueToDisplay(args[0]) : std::string()));
    }
    std::string valueToDisplay(const Value& v) {
        if (v.type == ValueType::USERDATA && v.value.p && instance_to_class.count(v.value.p))
            return instanceString(v, global_ctx);
        if (isStringValue(v)) return getStringValue(v);
        if (v.type == ValueType::USERDATA) return getStringValue(v);
        std::vector<Value> sa{v};
        return getStringValue(callBuiltin("str", sa, global_ctx));
    }
    // Python's BaseException.__str__ over the instance's args.
    std::string exceptionMessage(const Value& inst) {
        auto pit = instance_properties.find(inst.value.p);
        if (pit == instance_properties.end()) return std::string();
        Value a = pit->second->getByName("args");
        std::vector<Value> items = listItems(a);
        if (a.type == ValueType::UNDEFINED) {
            Value m = pit->second->getByName("msg");
            return m.type == ValueType::UNDEFINED ? std::string() : valueToDisplay(m);
        }
        if (items.empty()) return std::string();
        if (items.size() == 1) return valueToDisplay(items[0]);
        std::string r = "(";
        for (size_t i = 0; i < items.size(); i++) { if (i) r += ", "; r += valueToDisplay(items[i]); }
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
        uintptr_t ptr_val = 0;
        std::istringstream iss(flow.substr(op + 9));
        iss >> std::hex >> ptr_val;
        auto eit = exc_instance_map_.find(reinterpret_cast<void*>(ptr_val));
        return eit != exc_instance_map_.end() ? eit->second : NONE_VALUE;
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
                std::vector<Value> a{makeStringValue(excMessageOf(flow))};
                static const std::unordered_map<std::string, Value> no_kw;
                Value obj = instantiateClass(cv, a, no_kw, global_ctx);
                exc_instance_map_[obj.value.p] = obj;
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
    bool classDerivesFrom(const std::string& cls, const std::string& want, int depth = 0) {
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
                     || classDerivesFrom(t0, "GeneratorExit"));
        if (t0.empty()) return flow == t;           // raise "StopIteration"
        return classDerivesFrom(t0, t);
    }
    bool excClauseMatches(ExceptNode* en, const std::string& flow) {
        if (en->types.empty()) return true;
        for (auto& t : en->types) if (excTypeMatches(flow, t)) return true;
        return false;
    }
    // A C++ exception from a builtin, as a tagged exception string.
    static std::string excFromCpp(const std::string& what) {
        std::string t, m;
        if (nython::ny_split_exc_message(what, t, m)) return "__exc__:" + t + ":" + m;
        return "__exc__:Exception:" + what;
    }

    Value evalTry(node_ptr node, Context* ctx) {
        auto tn = static_pointer_cast<TryNode>(node);
        Value result = NONE_VALUE;
        // The finally body runs on every way out: normal completion, return,
        // break/continue, an exception no clause matches (which then
        // propagates - it used to be silently dropped), and an exception
        // raised by a handler or the else clause (it used to skip finally).
        auto run_finally = [&]() { if (tn->finally_clause) evalNode(tn->finally_clause, ctx); };
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

        if (!raised) {
            if (tn->else_clause) {
                try { result = evalNode(tn->else_clause, ctx); }
                catch (nython::node::YieldSignal&) { throw; }
                catch (...) { run_finally(); throw; }
            }
            run_finally();
            return result;
        }

        ExceptNode* match = nullptr;
        for (auto& ec : tn->except_clauses) {
            auto* en = static_cast<ExceptNode*>(ec.get());
            if (excClauseMatches(en, exc)) { match = en; break; }
        }
        if (!match) { run_finally(); throw exc; }

        if (!match->var.empty()) {
            ctx->defineByName(match->var, exceptionObject(exc));
        }
        handling_exc_.push_back(exc);
        struct PopHandling { std::vector<std::string>& v; ~PopHandling() { v.pop_back(); } } _ph{handling_exc_};
        try { result = evalNode(match->body, ctx); }
        catch (nython::node::YieldSignal&) { throw; }
        catch (...) { run_finally(); throw; }
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
    Value instantiateClass(const Value& cls, std::vector<Value>& args,
                           const std::unordered_map<std::string, Value>& kw, Context* ctx) {
        std::string className = fnTag(func_names, cls.value.p).substr(10);
        Value instance;
        instance.type = ValueType::USERDATA;
        auto inst_ptr = std::make_unique<std::string>("__instance__:" + className);
        instance.value.p = (void*)inst_ptr.get();
        instance_store.push_back(std::move(inst_ptr));
        instance_to_class[instance.value.p] = cls.value.p;
        func_names[instance.value.p] = "__instance__:" + className;
        Context* props = new Context(runner, className + "_props", nullptr, nullptr, nullptr);
        instance_properties[instance.value.p] = props;
        if (isExceptionClass(className)) setExceptionArgs(instance, args);
        runConstructor(instance, args, kw, ctx);
        return instance;
    }
    Value evalRaise(node_ptr node, Context* ctx) {
        auto rn = static_pointer_cast<RaiseNode>(node);
        if (!rn->expr) {
            // Bare `raise`: the exception the enclosing except clause is
            // handling (it used to raise the string "Exception").
            if (!handling_exc_.empty()) throw std::string(handling_exc_.back());
            throw std::string("__exc__:RuntimeError:No active exception to reraise");
        }
        Value v = evalNode(rn->expr, ctx);
        // `raise SomeClass` raises a new instance of it.
        if (v.type == ValueType::USERDATA && v.value.p) {
            auto fit = func_names.find(v.value.p);
            if (fit != func_names.end()) {
                if (fit->second.rfind("__class__:", 0) == 0) {
                    std::vector<Value> none_args;
                    static const std::unordered_map<std::string, Value> no_kw;
                    v = instantiateClass(v, none_args, no_kw, ctx);
                } else if (fit->second.rfind("__builtin__:", 0) == 0
                           && nython::ny_is_builtin_exc(fit->second.substr(12))) {
                    throw std::string("__exc__:" + fit->second.substr(12) + ":");
                }
            }
        }
        if (v.type == ValueType::USERDATA && v.value.p && !string_ptrs_.count(v.value.p)) {
            auto cit = instance_to_class.find(v.value.p);
            if (cit != instance_to_class.end()) {
                std::string class_name = instanceClassName(v);
                if (rn->cause) {
                    Value cause = evalNode(rn->cause, ctx);
                    auto pit = instance_properties.find(v.value.p);
                    if (pit != instance_properties.end()) pit->second->defineByName("__cause__", cause);
                }
                std::ostringstream oss;
                oss << "__exc__:" << class_name << ":__obj__:" << std::hex << reinterpret_cast<uintptr_t>(v.value.p);
                exc_instance_map_[v.value.p] = v;
                throw std::string(oss.str());
            }
            throw getStringValue(v);
        }
        if (v.type == ValueType::USERDATA && v.value.p) throw getStringValue(v);   // a string
        if (v.type == ValueType::NONE) throw std::string("__exc__:Exception:");
        throw std::string(v.toString());
    }

    Value evalAssert(node_ptr node, Context* ctx) {
        auto an = static_pointer_cast<AssertNode>(node);
        if (!isTruthy(evalNode(an->condition, ctx))) {
            std::string msg;
            if (an->message) {
                Value mv = evalNode(an->message, ctx);
                msg = mv.type == ValueType::USERDATA ? getStringValue(mv) : mv.toString();
            } else {
                msg = "Assertion failed";
            }
            throw std::string("__exc__:AssertionError:" + msg);
        }
        return NONE_VALUE;
    }

    // ─── ENUM ───────────────────────────────────────────────────────────
    // Directory of the file containing this import, with a trailing separator.
    // Tokens carry their source file, so this needs no extra plumbing.
    std::string importerDir(const node_ptr& node) {
        if (!node) return std::string();
        std::string f = node->token().fileName();
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
        const std::string n = node->token().value;
        if (n.empty()) return std::string();
        static const std::set<std::string> type_names = {
            "int","Integer","integer","float","Float","double","Double",
            "str","String","string","bool","Boolean","boolean",
            "list","List","array","Array","map","Map","dict","Dict",
            "tuple","Tuple","set","Set",
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
        std::vector<Value> targs{v};
        std::string actual = getStringValue(callBuiltin("type", targs, ctx));
        auto names_type = [&](const std::string& t) {
            if (t == "string") return want=="str"||want=="String"||want=="string";
            if (t == "list")   return want=="list"||want=="List"||want=="array"||want=="Array";
            if (t == "map")    return want=="map"||want=="Map"||want=="dict"||want=="Dict";
            if (t == "tuple")  return want=="tuple"||want=="Tuple";
            if (t == "set")    return want=="set"||want=="Set";
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

    Value evalImport(node_ptr node, Context* ctx) {
        auto in_node = static_pointer_cast<ImportNode>(node);
        std::string module_name = in_node->module_name;
        // Strip quotes if present
        if (module_name.size() >= 2 && (module_name[0] == '"' || module_name[0] == '\'')) {
            module_name = module_name.substr(1, module_name.size() - 2);
        }

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
                auto* ns = new Object((Runnable*)runner, in_node->alias.empty() ? "sys" : in_node->alias, Type::MAP);
                ns->set("argv", argv_list);
                ns->set("platform", makeStringValue(plat));
                ns->set("executable", makeStringValue(nyrt::executable_path()));
                ns->set("version", makeStringValue(NYTHON_VERSION));
                ctx->defineByName(in_node->alias.empty() ? "sys" : in_node->alias, Value((Collectable*)ns));
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
                    ctx->defineByName(in_node->alias.empty() ? "os" : in_node->alias, makeOsNamespace());
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
        if (module_name == "collections") {
                registerBuiltin("OrderedDict");
                registerBuiltin("Counter");
                registerBuiltin("defaultdict");
                registerBuiltin("deque");
                registerBuiltin("Set");
                return NONE_VALUE;
        }
        if (module_name == "math") {
            // Create a math module object (collectable dict)
            std::vector<Value> no_args;
            Value math_obj = callBuiltin("dict", no_args, ctx);
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
                // Register math function builtins and store them as attributes
                std::vector<std::string> math_fns = {"sqrt","sin","cos","tan","log","log2","log10",
                    "floor","ceil","abs","pow","exp","asin","acos","atan","atan2","hypot",
                    "degrees","radians","trunc","gcd","factorial","comb","perm"};
                for (auto& fn : math_fns) {
                    registerBuiltin(fn);
                    // Get the registered builtin value from global_ctx
                    Value bv = global_ctx->getByName(fn);
                    if (bv.type == ValueType::USERDATA && bv.value.p)
                        (*cont->container)[fn] = bv;
                }
            }
            ctx->defineByName("math", math_obj);
            // Also define pi/e as globals for convenience
            ctx->defineByName("PI", Value(3.14159265358979323846));
            ctx->defineByName("E", Value(2.71828182845904523536));
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
            if (!here.empty()) {
                search_paths.push_back(here + module_name + ".ny");
                search_paths.push_back(here + module_name);
                search_paths.push_back(here + "lib/" + module_name + ".ny");
            }
        }
        search_paths.push_back(module_name + ".ny");
        search_paths.push_back(module_name);
        search_paths.push_back("./" + module_name + ".ny");
        search_paths.push_back("./lib/" + module_name + ".ny");
        search_paths.push_back("lib/" + module_name + ".ny");
        search_paths.push_back("lib/" + module_name + "/" + module_name + ".ny");
        for (auto& c : ancestorCandidates(node, module_name + ".ny")) search_paths.push_back(c);
        for (auto& c : ancestorCandidates(node, module_name)) search_paths.push_back(c);

        std::string filepath;
        for (auto& p : search_paths) {
            struct stat buf;
            if (stat(p.c_str(), &buf) == 0) { filepath = p; break; }
        }
        // A module that cannot be found used to import silently, so every name
        // it would have defined then failed later with no hint that the import
        // was the cause. Name the module and where it was looked for.
        if (filepath.empty()) {
            std::string tried;
            for (size_t i = 0; i < search_paths.size(); ++i) {
                if (i) tried += ", ";
                tried += search_paths[i];
            }
            throw std::string("__exc__:ImportError:cannot find module \"" + module_name
                              + "\" (looked in: " + tried + ")");
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
                const bool aliased = !in_node->alias.empty() && ctx;

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
                    if (stem.size() > 3 && stem.compare(stem.size() - 3, 3, ".ny") == 0) stem = stem.substr(0, stem.size() - 3);
                }
                Value prev_name = ctx->getByName("__name__"), prev_file = ctx->getByName("__file__");
                NameScope name_scope(ctx, prev_name, prev_file, makeStringValue(stem), makeStringValue(filepath));

                evalNode(ast, ctx);

                if (aliased) {
                    auto* ns = new Object((Runnable*)runner, in_node->alias, Type::MAP);
                    for (const auto& n : own) {
                        Value v = ctx->getByName(n);
                        if (v.type != ValueType::UNDEFINED) ns->set(n, v);
                    }
                    ctx->defineByName(in_node->alias, Value((Collectable*)ns));
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

        Value evalEnum(node_ptr node, Context* ctx) {
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

    Value evalDelete(node_ptr node, Context* ctx) {
        auto dn = static_pointer_cast<DeleteNode>(node);
        if (dn->target->type() == NodeType::VARIABLE) {
            ctx->defineByName(dn->target->value(), UNDEFINED_VALUE);
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
            if (Container* cont = contOf(obj)) {
                int64_t n = seqLen(cont);
                if (n < 0) {
                    // del d[k]: a missing key is a KeyError, as in Python
                    if (cont->container->erase(dictKey(idx)) == 0) pyRaise("KeyError", reprOf(idx, ctx));
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
        } else if (dn->target->type() == NodeType::ATTRIBUTE) {
            // del obj.attr
            auto attr = static_pointer_cast<AttributeNode>(dn->target);
            Value obj = evalNode(attr->object, ctx);
            if (obj.type == ValueType::USERDATA && obj.value.p) {
                auto pit = instance_properties.find(obj.value.p);
                if (pit != instance_properties.end())
                    pit->second->defineByName(attr->attr, UNDEFINED_VALUE);
            }
        }
        return NONE_VALUE;
    }


    // ── evalMacroCall ─────────────────────────────────────────────────────────
    // Invokes a user-registered Nython macro handler with collected token args.
    Value evalMacroCall(node_ptr node, Context* ctx) {
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
    Value evalDynBinop(node_ptr node, Context* ctx) {
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
        return false;
    }
    Node* classNodeOfInstance(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return nullptr;
        auto it = instance_to_class.find(v.value.p);
        if (it == instance_to_class.end()) return nullptr;
        Node* n = (Node*)it->second;
        return (n && n->type() == NodeType::CLASS) ? n : nullptr;
    }
    bool isInstanceValue(const Value& v) {
        return v.type == ValueType::USERDATA && v.value.p && !string_ptrs_.count(v.value.p)
               && instance_to_class.count(v.value.p);
    }
    bool instanceHasMethod(const Value& v, const std::string& name) {
        Node* cn = classNodeOfInstance(v);
        Value m;
        return cn && findClassMember(cn, name, m);
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
                       const std::unordered_map<std::string, Value>& kw, Context* ctx) {
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
            if (wc != closure_contexts.end() && wc->second) wp = wc->second;
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
        } else if (is_static || !has_self) {
            bindParamsKw(fn, args, kw, fc, ctx, 0, m.value.p);
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
    bool superCall(Value self, Node* owner, const std::string& name, std::vector<Value>& args,
                   const std::unordered_map<std::string, Value>& kw, Context* ctx, Value& out) {
        Node* start = isInstanceValue(self) ? classNodeOfInstance(self) : owner;
        if (!start) return false;
        Value m; Node* where = nullptr;
        if (findClassMember(start, name, m, &where, owner) && m.type == ValueType::USERDATA && m.value.p
            && func_names.count(m.value.p)) {
            out = invokeMember(m, where, self, args, kw, ctx);
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
            if (isInstanceValue(self) && isExceptionClass(instanceClassName(self))) setExceptionArgs(self, args);
            out = NONE_VALUE;
            return true;
        }
        return false;
    }
    // Builtins that take an iterable, given an object with __iter__ /
    // __next__ / __getitem__: its items first. sorted/min/max over objects
    // order by __lt__ (or the other side's __gt__), sum adds with __add__ /
    // __radd__, issubclass walks the MRO, hash() uses __hash__.
    void yieldValue(const Value& v) {
        if (yield_sink_->size() >= kMaxGeneratorValues)
            throw std::string("__exc__:RuntimeError:generator produced more than 10000000 values (generators are "
                              "collected eagerly by the interpreter; use the VM (--vm) for unbounded generators)");
        yield_sink_->push_back(v);
    }
    bool isGenValue(const Value& v) {
        if (!v.isCollectable() || !v.value.gc) return false;
        auto* c = dynamic_cast<Container*>(v.value.gc);
        return c && c->container && c->container->count("__gen__");
    }
    Value makeGenValue(const std::vector<Value>& items) {
        Object* gen_obj = new Object((Runnable*)runner, "__gen__", Type::LIST);
        int len = (int)items.size();
        for (int i = 0; i < len; i++) gen_obj->set(std::to_string(i), items[(size_t)i]);
        gen_obj->set("__len__", Value(len));
        gen_obj->set("__gen__", Value(1));
        gen_obj->set("__idx__", Value(0));
        return Value((Collectable*)gen_obj);
    }
    // Generators on this engine are eager: calling a generator function
    // runs its body to the end, collecting what it yields, and returns a
    // generator over those values. The enclosing collection (a generator
    // called from inside another) is restored afterwards - it was reset to
    // none, so the outer generator's next yield aborted the process. An
    // exception raised by the body propagates (it was swallowed), and a
    // body that yields nothing is still a generator (it ran a second time
    // as a plain function and returned none).
    static constexpr size_t kMaxGeneratorValues = 10000000;
    Value collectGenerator(const node_ptr& body, Context* fc) {
        std::vector<Value> yielded;
        std::vector<Value>* saved = yield_sink_;
        yield_sink_ = &yielded;
        try { evalBody(body, fc); }
        catch (nython::node::ReturnSignal&) {}
        catch (...) { yield_sink_ = saved; throw; }
        yield_sink_ = saved;
        return makeGenValue(yielded);
    }
    // A function body run to completion: its value, or the generator it is.
    Value runFunctionBody(FunctionNode* fn, Context* fc) {
        if (bodyYields(fn->body)) return collectGenerator(fn->body, fc);
        try { return evalBody(fn->body, fc); }
        catch (nython::node::ReturnSignal& r) { return r.value; }
    }
    bool iterableBuiltin(const std::string& name, std::vector<Value>& args, Context* ctx, Value& out) {
        static const std::unordered_set<std::string> takes = {
            "list","tuple","set","sorted","min","max","sum","any","all","enumerate","reversed","zip","frozenset"};
        if (name == "issubclass" && args.size() >= 2) {
            auto cls_name = [&](const Value& v) -> std::string {
                if (v.type == ValueType::USERDATA && v.value.p) {
                    std::string t = fnTag(func_names, v.value.p);
                    if (t.rfind("__class__:", 0) == 0) return t.substr(10);
                    if (t.rfind("__builtin__:", 0) == 0) return t.substr(12);
                    if (isStringValue(v)) return getStringValue(v);
                }
                return std::string();
            };
            std::string c = cls_name(args[0]);
            if (c.empty()) { out = Value(false); return true; }
            std::vector<Value> targets;
            auto items = listItems(args[1]);
            if (!items.empty()) targets = items; else targets.push_back(args[1]);
            for (auto& t : targets) {
                std::string tn = cls_name(t);
                if (!tn.empty() && (tn == "object" || tn == "Object" || classDerivesFrom(c, tn))) { out = Value(true); return true; }
            }
            out = Value(false); return true;
        }
        if (name == "hash" && !args.empty() && isInstanceValue(args[0]) && instanceHasMethod(args[0], "__hash__")) {
            std::vector<Value> none;
            out = callMethod(args[0], "__hash__", none, ctx);
            return true;
        }
        if (name == "bool" && args.size() == 1 && isInstanceValue(args[0])) { out = Value(isTruthy(args[0])); return true; }
        // iter(x) and next(it[, default]). A generator here is its collected
        // values with a read position (__gen__/__idx__), which next() already
        // understands; iter() of a list, string or dict makes one of those,
        // and objects go through __iter__/__next__. Both returned none.
        // hasattr / getattr on instances and classes: the full attribute
        // lookup (methods, class attributes, properties, __getattr__); only
        // an instance's own fields were seen.
        if ((name == "hasattr" || name == "getattr") && args.size() >= 2 && isStringValue(args[1])) {
            std::string err;
            if (attributeErrorFor(args[0], getStringValue(args[1]), err)) {
                Value v;
                try { v = lookupAttribute(args[0], getStringValue(args[1]), ctx); }
                catch (std::string& e) {
                    if (!excTypeMatches(e, "AttributeError")) throw;
                    v = UNDEFINED_VALUE;
                }
                bool has = v.type != ValueType::UNDEFINED;
                if (name == "hasattr") { out = Value(has); return true; }
                if (has) { out = v; return true; }
                if (args.size() >= 3) { out = args[2]; return true; }
                throw err;
            }
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
        if (name == "iter" && !args.empty()) {
            const Value& v = args[0];
            if (isGenValue(v)) { out = v; return true; }
            if (isInstanceValue(v)) {
                std::vector<Value> none;
                if (instanceHasMethod(v, "__iter__")) { out = callMethod(v, "__iter__", none, ctx); return true; }
                if (instanceHasMethod(v, "__next__")) { out = v; return true; }
                if (!instanceHasMethod(v, "__getitem__"))
                    throw std::string("__exc__:TypeError:'" + instanceClassName(v) + "' object is not iterable");
            }
            out = makeGenValue(iterValues(v, ctx));
            return true;
        }
        if (name == "next" && !args.empty()) {
            if (isInstanceValue(args[0])) {
                if (!instanceHasMethod(args[0], "__next__"))
                    throw std::string("__exc__:TypeError:'" + instanceClassName(args[0]) + "' object is not an iterator");
                std::vector<Value> none;
                try { out = callMethod(args[0], "__next__", none, ctx); }
                catch (std::string& e) {
                    if (args.size() >= 2 && excTypeMatches(e, "StopIteration")) { out = args[1]; return true; }
                    throw;
                }
                return true;
            }
            if (isGenValue(args[0])) {
                auto* c = dynamic_cast<Container*>(args[0].value.gc);
                auto ii = c->container->find("__idx__"), li = c->container->find("__len__");
                int64_t idx = ii != c->container->end() ? bigint_to_i64(ii->second.value.i) : 0;
                int64_t len = li != c->container->end() ? bigint_to_i64(li->second.value.i) : 0;
                if (idx >= len) {
                    if (args.size() >= 2) { out = args[1]; return true; }
                    throw std::string("__exc__:StopIteration:");
                }
                return false;
            }
            throw std::string("__exc__:TypeError:object is not an iterator");
        }
        if (!takes.count(name) || args.empty()) return false;
        size_t upto = (name == "zip") ? args.size() : 1;
        bool changed = false;
        for (size_t i = 0; i < upto && i < args.size(); i++) {
            if (isInstanceValue(args[i]) && (instanceHasMethod(args[i], "__iter__") || instanceHasMethod(args[i], "__next__")
                                             || instanceHasMethod(args[i], "__getitem__"))) {
                args[i] = makeListValue(iterValues(args[i], ctx));
                changed = true;
            }
        }
        (void)changed;
        if ((name == "set" || name == "frozenset") && args.size() == 1) {
            // Objects are one element per __hash__/__eq__ class (identity
            // without them); their text form, which the set builtin keyed on,
            // is the same for every instance of a class.
            std::vector<Value> items = listItems(args[0]);
            bool any_inst = false;
            for (auto& v : items) if (isInstanceValue(v)) { any_inst = true; break; }
            if (!any_inst) return false;
            std::vector<Value> uniq;
            for (auto& v : items) {
                bool dup = false;
                for (auto& u : uniq) {
                    if (isInstanceValue(v) != isInstanceValue(u)) continue;
                    if (isInstanceValue(v) && !instanceHasMethod(v, "__eq__") && !instanceHasMethod(u, "__eq__")) {
                        if (v.value.p == u.value.p) { dup = true; break; }
                        continue;
                    }
                    if (isInstanceValue(v) && instanceHasMethod(v, "__hash__") && instanceHasMethod(u, "__hash__")) {
                        std::vector<Value> none;
                        if (!pyEquals(callMethod(v, "__hash__", none, ctx), callMethod(u, "__hash__", none, ctx), ctx)) continue;
                    }
                    if (pyEquals(v, u, ctx)) { dup = true; break; }
                }
                if (!dup) uniq.push_back(v);
            }
            Value lst = makeListValue(uniq);
            if (auto* c = dynamic_cast<Container*>(lst.value.gc)) (*c->container)["__set__"] = Value(true);
            out = lst; return true;
        }
        // sorted / min / max / sum over objects: pycore's, which order
        // through orderValues (__lt__, reflected __gt__) and add through
        // binaryOp (__add__ / __radd__), with key=, reverse= and default=.
        return false;
    }
    bool isFunctionValue(const Value& v) {
        if (v.type != ValueType::USERDATA || !v.value.p) return false;
        std::string t = fnTag(func_names, v.value.p);
        return t.rfind("__func__:", 0) == 0 || t.rfind("__lambda__", 0) == 0 || t.rfind("__builtin__:", 0) == 0;
    }
    // Runs the constructor of a new instance: the first class in its MRO
    // that defines __init__ or init.
    void runConstructor(Value inst, std::vector<Value>& args,
                        const std::unordered_map<std::string, Value>& kw, Context* ctx) {
        Node* cls = classNodeOfInstance(inst);
        if (!cls) return;
        for (Node* c : classMro(cls)) {
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
    }
    // Calls method `name` of an instance (or a class) through the class
    // namespaces and the MRO. Returns false when no class defines it.
    bool callClassMethod(Value obj, const std::string& name, std::vector<Value>& args,
                         const std::unordered_map<std::string, Value>& kw, Context* ctx, Value& out) {
        Node* cls = isInstanceValue(obj) ? classNodeOfInstance(obj) : nullptr;
        if (!cls && obj.type == ValueType::USERDATA && obj.value.p
            && fnTag(func_names, obj.value.p).rfind("__class__:", 0) == 0) {
            Node* n = (Node*)obj.value.p;
            if (n && n->type() == NodeType::CLASS) cls = n;
        }
        if (!cls) return false;
        Value m; Node* owner = nullptr;
        if (!findClassMember(cls, name, m, &owner)) return false;
        if (m.type != ValueType::USERDATA || !m.value.p) return false;
        std::string tag = fnTag(func_names, m.value.p);
        if (tag.rfind("__func__:", 0) != 0 && tag.rfind("__lambda__", 0) != 0) {
            // A class stored in the class (Outer.Inner(...)) or a builtin.
            if (tag.rfind("__class__:", 0) == 0 || tag.rfind("__builtin__:", 0) == 0) {
                out = callFunctionValue(m, args, ctx);
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
    Value evalWith(node_ptr node, Context* ctx) {
        auto wn = static_pointer_cast<WithNode>(node);
        Value v = evalNode(wn->expr, ctx);
        bool managed = isInstanceValue(v);
        Value ctx_val = v;
        if (managed && instanceHasMethod(v, "__enter__")) {
            std::vector<Value> no_args;
            ctx_val = callMethod(v, "__enter__", no_args, ctx);
        }
        if (!wn->alias.empty()) ctx->defineByName(wn->alias, ctx_val);
        auto exit_plain = [&]() {
            if (!managed || !instanceHasMethod(v, "__exit__")) return;
            std::vector<Value> a{NONE_VALUE, NONE_VALUE, NONE_VALUE};
            callMethod(v, "__exit__", a, ctx);
        };
        auto exit_exc = [&](const std::string& flow) -> bool {
            if (!managed || !instanceHasMethod(v, "__exit__")) return false;
            Value ev = exceptionObject(flow);
            std::vector<Value> a{exceptionClassValue(flow), ev, NONE_VALUE};
            return isTruthy(callMethod(v, "__exit__", a, ctx));
        };
        Value result = NONE_VALUE;
        try {
            result = evalNode(wn->body, ctx);
        }
        catch (nython::node::ReturnSignal&) { exit_plain(); throw; }
        catch (nython::node::YieldSignal&) { throw; }
        catch (std::string& flow) {
            if (flow == "break" || flow == "continue") { exit_plain(); throw; }
            if (exit_exc(flow)) return NONE_VALUE;
            throw;
        }
        catch (std::exception& e) {
            std::string flow = excFromCpp(e.what());
            if (exit_exc(flow)) return NONE_VALUE;
            throw flow;
        }
        exit_plain();
        return result;
    }

    Value evalNamespace(node_ptr node, Context* ctx) {
        auto nn = static_pointer_cast<NameSpaceNode>(node);
        Context* ns_ctx = new Context(runner, nn->name, nullptr, nullptr, ctx);
        if (nn->body) evalNode(nn->body, ns_ctx);
        // The body ran in ns_ctx, but ns_ctx itself was never exposed under
        // the namespace's own name in the OUTER scope - `namespace ns: var
        // thing = 42` left `ns` completely undefined outside the block, so
        // `ns.thing` always read none. Collect the namespace's own
        // top-level names (matching how `import "m" as alias` builds its
        // namespace map elsewhere in this file) into a map bound to its
        // name, so it can actually be used from outside.
        auto* obj = new Object((Runnable*)runner, nn->name, Type::MAP);
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
        if (Container* c = contOf(v)) {
            int64_t n = seqLen(c);
            if (n >= 0) return n != 0;
            for (auto& kv : *c->container)
                if (!(kv.first.size() >= 2 && kv.first[0] == '_' && kv.first[1] == '_')) return true;
            return false;
        }
        return v.isCollectable() ? v.value.gc != nullptr : true;
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
        return isTruthy(r);
    }
};

