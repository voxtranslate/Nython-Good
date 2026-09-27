#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-but-set-variable"
#pragma GCC diagnostic ignored "-Wunused-function"
// builtins/threading.cpp
// Threads, mutexes, async
// ─────────────────────────────────────────────────────────────────────────────
// HOW THIS FILE WORKS:
//   dispatch_threading() is called from NythonExecutor::callBuiltin().
//   It has full access to the executor via the `E` reference (same as `*this`
//   in the original monolithic main.cpp).  Every helper that was previously
//   a member call (getStringValue, makeStringValue, callBuiltin, etc.) is
//   accessed through `E.` — keeping code changes minimal.
// ─────────────────────────────────────────────────────────────────────────────

// Platform compatibility (must come first)
#include "platform_compat.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>
#include <regex>
#include <cstdlib>
#include <cmath>
#include <chrono>
#include <random>
#include <thread>
#include <mutex>
#include <functional>
#include <iomanip>
#include <string>
#include <vector>
#include <map>
#include <unordered_set>
#include <unordered_map>
#include <ctime>
#include <cwctype>
#include <locale>

// Full executor definition (needed for E.getStringValue etc.)
#include "NythonExecutor.hpp"
#include "builtins/threading.hpp"

#include "NyConc.hpp"

// ════════════════════════════════════════════════════════════════════════════
// Interpreter side of the concurrency runtime (src/NyConc.cpp).
// All semantics live in the runtime; this only converts values and errors.
// ════════════════════════════════════════════════════════════════════════════
namespace {

struct InterpBox : nyconc::Box { Value v; explicit InterpBox(const Value& x) : v(x) {} };

static Value unbox_value(const nyconc::BoxPtr& b) {
    auto* ib = dynamic_cast<InterpBox*>(b.get());
    return ib ? ib->v : NONE_VALUE;
}

struct InterpEngine : nyconc::Engine {
    NythonExecutor& E;
    explicit InterpEngine(NythonExecutor& e) : E(e) {}

    nyconc::BoxPtr box(const Value& v) { return std::make_shared<InterpBox>(v); }

    const std::string* tag_of(const Value& f) {
        if (f.type != ValueType::USERDATA || !f.value.p) return nullptr;
        auto it = E.func_names.find(f.value.p);
        return it == E.func_names.end() ? nullptr : &it->second;
    }

    // Any callable the language has: functions, lambdas, bound methods,
    // builtins, instances with __call__, classes.
    Value invoke(const Value& f, std::vector<Value>& av) {
        Context* ctx = E.globalContext();
        const std::string* tag = tag_of(f);
        if (!tag) throw nyconc::NyError::make("TypeError", "object is not callable");
        if (tag->rfind("__builtin__:", 0) == 0) return E.callBuiltin(tag->substr(12), av, ctx);
        if (tag->rfind("__instance__:", 0) == 0) return E.callMethod(f, "__call__", av, ctx);
        if (tag->rfind("__class__:", 0) == 0) {
            // Construct through the ordinary call path: bind callee and args to
            // names in a scratch scope and evaluate `callee(a0, a1, ...)`.
            Context* scope = new Context(E.runner, "<native-call>", nullptr, nullptr, E.globalContext());
            Token t(TokenIdent{}, "__ny_callee");
            auto call = std::make_shared<CallNode>(t, std::make_shared<VariableNode>(t));
            scope->defineByName("__ny_callee", f);
            for (size_t i = 0; i < av.size(); i++) {
                std::string nm = "__ny_arg" + std::to_string(i);
                scope->defineByName(nm, av[i]);
                call->add(std::make_shared<VariableNode>(Token(TokenIdent{}, nm)));
            }
            return E.evalNode(call, scope);
        }
        return E.callFunctionValue(f, av, ctx);
    }

    nyconc::BoxPtr call(const nyconc::BoxPtr& fn, const std::vector<nyconc::BoxPtr>& args) override {
        Value f = unbox_value(fn);
        std::vector<Value> av;
        for (auto& a : args) av.push_back(unbox_value(a));
        try { return box(invoke(f, av)); }
        catch (std::string& s) {
            nyconc::NyError e; e.raw = s;
            // A raised exception object: its type and message for the
            // runtime's error text (the raw form still re-raises the object).
            Value inst = E.excInstanceOf(s);
            if (inst.type != ValueType::NONE) { e.type = E.instanceClassName(inst); e.msg = E.exceptionMessage(inst); }
            throw e;
        }
        catch (nython::node::ReturnSignal& r) { return box(r.value); }
        catch (nyconc::NyError&) { throw; }
        catch (std::exception& x) { throw nyconc::NyError::make("RuntimeError", x.what()); }
    }
    nyconc::BoxPtr box_int(int64_t v) override { return box(Value((int64_t)v)); }
    nyconc::BoxPtr box_none() override { return box(NONE_VALUE); }
    bool unbox_int(const nyconc::BoxPtr& b, int64_t& out) override {
        Value v = unbox_value(b);
        if (v.type != ValueType::INTEGER) return false;
        out = bigint_to_i64(v.value.i);
        return true;
    }
    Value to_value(const nyconc::Ret& r) {
        switch (r.k) {
            case nyconc::Ret::NONE: return NONE_VALUE;
            case nyconc::Ret::BOOL: return Value(r.b);
            case nyconc::Ret::INT:  return Value((int64_t)r.i);
            case nyconc::Ret::NUM:  return Value(r.d);
            case nyconc::Ret::STR:  return E.makeStringValue(r.s);
            case nyconc::Ret::BOX:  return unbox_value(r.box);
            case nyconc::Ret::LIST: {
                auto* lst = new Object((Runnable*)E.runner, "list", Type::LIST);
                int n = 0;
                for (auto& x : r.list) lst->set(std::to_string(n++), to_value(x));
                lst->set("__len__", Value(n));
                return Value(static_cast<Collectable*>(lst));
            }
        }
        return NONE_VALUE;
    }
    nyconc::BoxPtr from_ret(const nyconc::Ret& r) override { return box(to_value(r)); }
    bool is_callable(const nyconc::BoxPtr& b) override { return tag_of(unbox_value(b)) != nullptr; }
    std::string describe(const nyconc::BoxPtr& b) override {
        Value v = unbox_value(b);
        const std::string* tag = tag_of(v);
        if (tag) {
            std::string t = *tag;
            auto c = t.find(':');
            return c == std::string::npos ? t : t.substr(c + 1);
        }
        return E.isStringValue(v) ? E.getStringValue(v) : v.toString();
    }
};

struct InterpArgs : nyconc::Args {
    NythonExecutor& E;
    std::vector<Value> v;
    InterpArgs(NythonExecutor& e, std::vector<Value> xs) : E(e), v(std::move(xs)) {}
    size_t size() const override { return v.size(); }
    bool is_none(size_t i) const override { return v[i].type == ValueType::NONE; }
    bool is_number(size_t i) const override { return v[i].type == ValueType::INTEGER || v[i].type == ValueType::DOUBLE; }
    bool is_string(size_t i) const override { return E.isStringValue(v[i]); }
    Container* cont(size_t i) const {
        if (!v[i].isCollectable()) return nullptr;
        auto* c = dynamic_cast<Container*>(v[i].value.gc);
        return (c && c->container && c->container->count("__len__")) ? c : nullptr;
    }
    bool is_list(size_t i) const override { return cont(i) != nullptr; }
    int64_t as_int(size_t i) const override {
        if (v[i].type == ValueType::INTEGER) return bigint_to_i64(v[i].value.i);
        if (v[i].type == ValueType::DOUBLE) return (int64_t)v[i].value.d;
        if (v[i].type == ValueType::BOOLEAN) return v[i].value.b ? 1 : 0;
        return 0;
    }
    double as_num(size_t i) const override {
        if (v[i].type == ValueType::DOUBLE) return (double)v[i].value.d;
        return (double)as_int(i);
    }
    std::string as_str(size_t i) const override {
        return E.isStringValue(v[i]) ? E.getStringValue(v[i]) : v[i].toString();
    }
    bool truthy(size_t i) const override { return E.isTruthy(v[i]); }
    nyconc::BoxPtr box(size_t i) const override { return std::make_shared<InterpBox>(v[i]); }
    std::unique_ptr<nyconc::Args> list(size_t i) const override {
        std::vector<Value> out;
        if (Container* c = cont(i)) {
            int n = (int)bigint_to_i64(c->container->find("__len__")->second.value.i);
            for (int k = 0; k < n; k++) {
                auto it = c->container->find(std::to_string(k));
                out.push_back(it == c->container->end() ? NONE_VALUE : it->second);
            }
        }
        return std::make_unique<InterpArgs>(E, std::move(out));
    }
};

InterpEngine& engine_for(NythonExecutor& E) {
    // One engine per executor, never freed: threads may outlive the call that
    // created them (daemons at process exit).
    static std::unordered_map<NythonExecutor*, InterpEngine*> engines;
    auto it = engines.find(&E);
    if (it != engines.end()) return *it->second;
    auto* eng = new InterpEngine(E);
    engines[&E] = eng;
    return *eng;
}

} // namespace


// ── Namespace imports (match main.cpp) ────────────────────────────────────────
using namespace std;
using namespace nython;
using namespace nython::io;
using namespace nython::node;
using namespace nython::lexer;
using namespace nython::kernel;
using namespace nython::parser;
using namespace nython::reader;
using namespace nython::exception;

// ════════════════════════════════════════════════════════════════════════════════
// dispatch_threading
// ════════════════════════════════════════════════════════════════════════════════
Value dispatch_threading(NythonExecutor& E,
                       const std::string& name,
                       std::vector<Value>& args,
                       Context* ctx) {
    // Local aliases — identical names to original main.cpp code so the
    // extracted if-blocks compile unchanged.
    auto  makeStringValue  = [&](const std::string& s) { return E.makeStringValue(s); };
    auto  getStringValue   = [&](const Value& v)       { return E.getStringValue(v); };
    auto  isStringValue    = [&](const Value& v)       { return E.isStringValue(v); };
    auto  callBuiltin      = [&](const std::string& n, std::vector<Value>& a, Context* c)
                                { return E.callBuiltin(n, a, c); };
    auto  callFunctionValue= [&](Value fn, std::vector<Value>& a, Context* c)
                                { return E.callFunctionValue(fn, a, c); };
    auto  isTruthy         = [&](Value v) { return E.isTruthy(v); };
    auto  evalNode         = [&](node_ptr n, Context* c) { return E.evalNode(n, c); };
    auto& file_handles     = E.file_handles;
    auto& next_file_handle = E.next_file_handle;
    Runnable* runner       = E.runner;
    auto& func_names       = E.func_names;
    auto& instance_to_class= E.instance_to_class;
    auto& instance_properties = E.instance_properties;
    auto& class_by_name    = E.class_by_name;
    auto& class_parent     = E.class_parent;
    auto& super_parent_stack = E.super_parent_stack;
    auto& func_ast_nodes   = E.func_ast_nodes;
    auto& func_id_store    = E.func_id_store;
    auto& instance_store   = E.instance_store;
    auto& string_store     = E.string_store;
    auto  registerBuiltin  = [&](const std::string& n) { E.registerBuiltin(n); };
    auto  callMethod       = [&](Value inst, const std::string& mname, std::vector<Value>& a, Context* c)
                                { return E.callMethod(inst, mname, a, c); };
    auto  printValue       = [&](const Value& v, Context* c = nullptr) { E.printValue(v, c ? c : ctx); };

    // ── shape_to_size helper (used by tensor builtins) ───────────────────────

    // ── Concurrency runtime (threads, locks, channels, futures, async) ──────
    {
        static const std::unordered_set<std::string> exc_names(
            nyconc::exception_names().begin(), nyconc::exception_names().end());
        if (exc_names.count(name)) {
            std::string msg = args.empty() ? "" : (E.isStringValue(args[0]) ? E.getStringValue(args[0]) : args[0].toString());
            return E.makeStringValue("__exc__:" + name + ":" + msg);
        }
        InterpEngine& eng = engine_for(E);
        InterpArgs ia(E, args);
        nyconc::Ret r;
        bool handled;
        try { handled = nyconc::dispatch(eng, name, ia, r); }
        catch (nyconc::NyError& err) {
            if (!err.raw.empty()) throw std::string(err.raw);
            throw std::string("__exc__:" + err.type + ":" + err.msg);
        }
        if (handled) return eng.to_value(r);
    }
    auto shape_to_size = [&](const Value& v) -> int {
        if (v.type == ValueType::INTEGER) return (int)bigint_to_i64(v.value.i);
        if (v.type == ValueType::DOUBLE)  return (int)v.value.d;
        if (v.isCollectable()) {
            auto* c = dynamic_cast<Container*>(v.value.gc);
            if (c && c->container) {
                auto li = c->container->find("__len__");
                int len = (li != c->container->end()) ? (int)bigint_to_i64(li->second.value.i) : 0;
                if (len == 0) return 0;
                int total = 1;
                for (int k = 0; k < len; k++) {
                    auto ei = c->container->find(std::to_string(k));
                    if (ei != c->container->end()) {
                        if (ei->second.type == ValueType::INTEGER)
                            total *= (int)bigint_to_i64(ei->second.value.i);
                        else if (ei->second.type == ValueType::DOUBLE)
                            total *= (int)ei->second.value.d;
                    }
                }
                return total;
            }
        }
        return 0;
    };

// ── Extracted builtin implementations ────────────────────────────────────────
    // ── from main.cpp lines 3678–3754 ──────────────────────────────────────────
        // =====================================================================
        // NYTORCH SIGNAL: FFT (DFT via Cooley-Tukey, power-of-2 sizes)
        // =====================================================================
        if (name == "fft_magnitude") {
            // fft_magnitude(signal_tensor) -> magnitude spectrum tensor (N/2+1)
            if (!args.empty() && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                if (!t||!t->container) return NONE_VALUE;
                auto li=t->container->find("__len__"); int N=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                std::vector<double> re((size_t)N,0.0), im((size_t)N,0.0);
                for (int i=0;i<N;i++) { auto it=t->container->find(std::to_string(i)); re[(size_t)i]=(it!=t->container->end())?it->second.value.d:0.0; }
                // DFT (O(N^2), works for any N; for large N use with care)
                int out_n=N/2+1;
                auto* out=new Container((Runnable*)runner,Type::LIST);
                (*out->container)["__len__"]=Value(out_n);
                for (int k=0;k<out_n;k++) {
                    double sr=0,si=0;
                    for (int n=0;n<N;n++) { double ang=2.0*3.14159265358979323846*k*n/N; sr+=re[(size_t)n]*std::cos(ang); si-=re[(size_t)n]*std::sin(ang); }
                    (*out->container)[std::to_string(k)]=Value(std::sqrt(sr*sr+si*si));
                }
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "signal_window") {
            // signal_window(t, window_type="hann") -> windowed tensor
            if (!args.empty() && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                std::string wtype=(args.size()>=2)?getStringValue(args[1]):"hann";
                if (!t||!t->container) return NONE_VALUE;
                auto li=t->container->find("__len__"); int N=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                auto* out=new Container((Runnable*)runner,Type::LIST);
                (*out->container)["__len__"]=Value(N);
                const double PI=3.14159265358979323846;
                for (int i=0;i<N;i++) {
                    auto it=t->container->find(std::to_string(i));
                    double v=(it!=t->container->end())?it->second.value.d:0.0;
                    double w=1.0;
                    if (wtype=="hann") w=0.5*(1.0-std::cos(2.0*PI*i/(N-1)));
                    else if (wtype=="hamming") w=0.54-0.46*std::cos(2.0*PI*i/(N-1));
                    else if (wtype=="blackman") w=0.42-0.5*std::cos(2.0*PI*i/(N-1))+0.08*std::cos(4.0*PI*i/(N-1));
                    (*out->container)[std::to_string(i)]=Value(v*w);
                }
                return Value((Collectable*)out);
            }
            return NONE_VALUE;
        }
        if (name == "signal_rms") {
            // signal_rms(t) -> scalar rms energy
            if (!args.empty() && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                if (!t||!t->container) return Value(0.0);
                auto li=t->container->find("__len__"); int n=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                double ss=0;
                for (int i=0;i<n;i++) { auto it=t->container->find(std::to_string(i)); double v=(it!=t->container->end())?it->second.value.d:0.0; ss+=v*v; }
                return Value(std::sqrt(ss/std::max(1,n)));
            }
            return Value(0.0);
        }
        if (name == "signal_zero_crossings") {
            // signal_zero_crossings(t) -> count of zero crossings
            if (!args.empty() && args[0].isCollectable()) {
                auto* t=dynamic_cast<Container*>(args[0].value.gc);
                if (!t||!t->container) return Value(0);
                auto li=t->container->find("__len__"); int n=(li!=t->container->end())?(int)bigint_to_i64(li->second.value.i):0;
                int count=0; double prev=0;
                for (int i=0;i<n;i++) {
                    auto it=t->container->find(std::to_string(i)); double v=(it!=t->container->end())?it->second.value.d:0.0;
                    if (i>0 && ((prev>=0&&v<0)||(prev<0&&v>=0))) count++;
                    prev=v;
                }
                return Value(count);
            }
            return Value(0);
        }
        // =====================================================================
        // NYTORCH MATH: STATISTICS & LINEAR ALGEBRA
    // ── from main.cpp lines 4939–4988 ──────────────────────────────────────────
        if (name == "isdigit_str") {
            if (!args.empty()) {
                std::string s = getStringValue(args[0]);
                bool result = !s.empty();
                for (char c : s) if (!std::isdigit(static_cast<unsigned char>(c))) { result = false; break; }
                return Value(result);
            }
            return Value(false);
        }
        if (name == "isalpha_str") {
            if (!args.empty()) {
                std::string s = getStringValue(args[0]);
                bool result = !s.empty();
                for (char c : s) if (!std::isalpha(static_cast<unsigned char>(c))) { result = false; break; }
                return Value(result);
            }
            return Value(false);
        }
        if (name == "regex_search" || name == "re_search") {
            if (args.size() >= 2) {
                std::string pattern = getStringValue(args[0]);
                std::string input = getStringValue(args[1]);
                try {
                    std::regex re(pattern);
                    std::smatch m;
                    if (std::regex_search(input, m, re)) {
                        if (m.size() <= 1) return makeStringValue(m[0].str());
                        Object* result = new Object((Runnable*)runner, "list", Type::LIST);
                        for (size_t i = 0; i < m.size(); i++) {
                            result->set(std::to_string(i), makeStringValue(m[i].str()));
                        }
                        result->set("__len__", Value(static_cast<int>(m.size())));
                        return Value((Collectable*)result);
                    }
                    return Value(false);
                } catch (std::regex_error& e) {
                    return makeStringValue(std::string("regex error: ") + e.what());
                } catch (...) {
                    return makeStringValue("unknown regex error");
                }
            }
            return NONE_VALUE;
        }
    // Threads, locks, channels, futures, task groups, async: see the shared
    // runtime (src/NyConc.cpp), dispatched at the top of this function.

        // ===================== NET/SOCKET MODULE =====================

    return UNDEFINED_VALUE;  // not handled by this module
}

#pragma GCC diagnostic pop
