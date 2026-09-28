// NyGen.cpp — lazy generators on the interpreter; see include/NyGen.hpp.
#include "NythonExecutor.hpp"
#include "NyGen.hpp"
#include "NyCoro.hpp"

#include <cstdio>
#include <exception>
#include <unordered_map>

namespace nygen {

using nython::kernel::ValueType;
using nython::node::ComprehensionNode;
using nython::node::ForNode;
using nython::node::FunctionNode;
using nython::node::Node;
using nython::node::NodeType;

namespace {

// Thrown at the yield of a generator that ignored GeneratorExit while it was
// being finalized: a plain C++ unwind (no except clause of the language
// catches it), so the destructors of the frames on its stack run and the
// coroutine can end.
struct GenKill {};

enum class Kind : uint8_t { Function, GenExpr, Native };
enum class St : uint8_t { Created, Suspended, Running, Done };
enum class Mode : uint8_t { Next, Send, Throw, Close, Kill };
enum class Op : uint8_t { Zip, Map, Filter, Enumerate, Islice, Iter };

// A position in anything iterable, advanced one value at a time.
struct Cursor {
    enum K : uint8_t { END, SEQ, VEC, RANGE, GEN, INST, GETITEM };
    K k = END;
    Value hold;                 // the iterated object, kept alive
    Container* c = nullptr;     // SEQ: a list/tuple read by index (length re-read each step)
    int64_t i = 0, n = 0;       // SEQ/VEC/RANGE/GETITEM position; RANGE end
    std::vector<Value> v;       // VEC: a snapshot (dict keys, a string's characters, a set)
    Gen* g = nullptr;           // GEN
    Value it;                   // INST: the iterator (has __next__)
    Value stop_value;           // INST: the value of the StopIteration that ended it
    bool owns = false;          // GEN: a temporary only this cursor refers to
};

// The interpreter's per-execution state while a generator is switched out.
struct Saved {
    Context* fast_ctx = nullptr;
    bool brk_ok = false;
    int pending = 0;
    Value value;
    node_ptr last;
    int rel_depth = 0;                    // call depth inside the generator
    std::vector<std::string> handling;    // except clauses it is inside
    std::vector<Node*> owners;            // method owners (super())
    std::vector<std::string> trace;       // --trace frames
};

}  // namespace

struct Gen {
    NythonExecutor* E = nullptr;
    GenObject* obj = nullptr;
    Kind kind = Kind::Function;
    St st = St::Created;
    bool orphan = false;          // its object died while it was running
    std::string name;
    uint64_t serial = 0;
    uint64_t creator = 0;         // nycoro::thread_token() of the thread that made it
    int birth_depth = 0;
    Gen* lprev = nullptr;         // list of suspended function generators
    Gen* lnext = nullptr;
    bool listed = false;
    // Function
    FunctionNode* fn = nullptr;
    Context* fc = nullptr;
    bool fc_pinned = false;
    nycoro::Coro* co = nullptr;
    Mode mode = Mode::Next;
    Value xfer;                   // sent in / yielded out
    std::string thrown;           // raised at the yield (Mode::Throw)
    std::exception_ptr exc;       // what the body raised
    bool yielded = false;
    Value retval;                 // `return v`: StopIteration.value
    Saved saved;
    Value delegate;               // the iterator a `yield from` is running
    // GenExpr
    ComprehensionNode* comp = nullptr;
    node_ptr comp_keep;
    Context* outer = nullptr;
    bool outer_pinned = false;
    Context* cc = nullptr;
    std::vector<Cursor> cur;
    // Native
    Op op = Op::Zip;
    std::vector<Cursor> src;
    Value fnv;
    Value idx;                    // enumerate's next index
    int64_t cnt = 0, nxt = 0, stop = -1, step = 1;   // islice
};

namespace {

thread_local Gen* t_cur = nullptr;          // the generator whose body is running
bool g_shutdown = false;                    // the executor is being torn down
Gen* g_list_head = nullptr;                 // suspended function generators (GIL held)
Gen* g_list_tail = nullptr;
thread_local std::vector<Gen*> t_pending_list;   // dropped while suspended, to finalize
size_t g_created = 0;
size_t g_suspended = 0;

struct Pin { int count = 0; bool deferred = false; };
std::unordered_map<Context*, Pin>& pins() { static auto* m = new std::unordered_map<Context*, Pin>(); return *m; }

void pin(Context* c) {
    if (!c) return;
    pins()[c].count++;
    g_pinned = (int)pins().size();
}
void unpin(NythonExecutor& E, Context* c) {
    if (!c) return;
    auto& P = pins();
    auto it = P.find(c);
    if (it == P.end()) return;
    if (--it->second.count > 0) return;
    bool deferred = it->second.deferred;
    P.erase(it);
    g_pinned = (int)P.size();
    if (deferred) E.reapContext(c);
}

void list_add(Gen* g) {
    if (g->listed) return;
    g->listed = true;
    g->lprev = g_list_tail; g->lnext = nullptr;
    if (g_list_tail) g_list_tail->lnext = g; else g_list_head = g;
    g_list_tail = g;
    g_suspended++;
}
void list_remove(Gen* g) {
    if (!g->listed) return;
    g->listed = false;
    if (g->lprev) g->lprev->lnext = g->lnext; else g_list_head = g->lnext;
    if (g->lnext) g->lnext->lprev = g->lprev; else g_list_tail = g->lprev;
    g->lprev = g->lnext = nullptr;
    g_suspended--;
}

std::string hex_ptr(const void* p) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)(uintptr_t)p);
    return buf;
}

[[noreturn]] void raise(const std::string& type, const std::string& msg) {
    throw std::string("__exc__:" + type + ":" + msg);
}

// StopIteration carrying a generator's return value (StopIteration.value).
[[noreturn]] void raise_stop(NythonExecutor& E, const Value& rv, Context* ctx) {
    Node* cn = E.classNodeByName("StopIteration");
    if (!cn) raise("StopIteration", rv.type == ValueType::NONE ? std::string() : E.strOf(rv, ctx));
    Value cv; cv.type = ValueType::USERDATA; cv.value.p = (void*)cn;
    std::vector<Value> a;
    if (rv.type != ValueType::NONE && rv.type != ValueType::UNDEFINED) a.push_back(rv);
    static const std::unordered_map<std::string, Value> no_kw;
    Value inst = E.instantiateClass(cv, a, no_kw, ctx ? ctx : E.global_ctx);
    E.exc_instance_map_[inst.value.p] = inst;
    char buf[64];
    std::snprintf(buf, sizeof buf, "%llx", (unsigned long long)reinterpret_cast<uintptr_t>(inst.value.p));
    throw std::string("__exc__:StopIteration:__obj__:") + buf;
}

// What `raise v` (with extra constructor arguments) throws: an exception
// class is instantiated, an instance travels as a reference, a string as
// itself (Nython lets any string be raised).
std::string exc_string_for(NythonExecutor& E, Value v, const std::vector<Value>& cargs, Context* ctx) {
    if (v.type == ValueType::USERDATA && v.value.p) {
        auto fit = E.func_names.find(v.value.p);
        if (fit != E.func_names.end()) {
            if (fit->second.rfind("__class__:", 0) == 0) {
                std::vector<Value> a = cargs;
                static const std::unordered_map<std::string, Value> no_kw;
                v = E.instantiateClass(v, a, no_kw, ctx);
            } else if (fit->second.rfind("__builtin__:", 0) == 0 && nython::ny_is_builtin_exc(fit->second.substr(12))) {
                return "__exc__:" + fit->second.substr(12) + ":" + (cargs.empty() ? std::string() : E.strOf(cargs[0], ctx));
            }
        }
    }
    if (E.isInstanceValue(v)) {
        std::string cls = E.instanceClassName(v);
        E.exc_instance_map_[v.value.p] = v;
        char buf[64];
        std::snprintf(buf, sizeof buf, "%llx", (unsigned long long)reinterpret_cast<uintptr_t>(v.value.p));
        return "__exc__:" + cls + ":__obj__:" + buf;
    }
    if (E.isStringValue(v)) return E.getStringValue(v);
    raise("TypeError", "exceptions must derive from BaseException");
}

bool is_exc(NythonExecutor& E, const std::string& s, const char* type) {
    try { return E.excTypeMatches(s, type); } catch (...) { return false; }
}

void report_ignored(NythonExecutor& E, Gen* g, const std::string& s) {
    std::string d;
    try { d = E.describeException(s); } catch (...) { d = s; }
    std::fprintf(stderr, "Exception ignored in: <generator object %s at %s>\n%s\n", g->name.c_str(),
                 hex_ptr(g->obj ? (const void*)g->obj : (const void*)g).c_str(), d.c_str());
}

// ── Cursors ─────────────────────────────────────────────────────────────────
void open(NythonExecutor& E, const Value& val, Context* ctx, Cursor& cu, bool owns = false) {
    cu = Cursor();
    cu.hold = val;
    if (Gen* g = gen_of(val)) { cu.k = Cursor::GEN; cu.g = g; cu.owns = owns; return; }
    if (val.type == ValueType::INTEGER) {   // range(n) is an integer on this engine
        cu.k = Cursor::RANGE; cu.n = bigint_to_i64(val.value.i); return;
    }
    if (E.isStringValue(val)) {
        cu.k = Cursor::VEC;
        for (auto& ch : nypy::u8_chars(*(std::string*)val.value.p)) cu.v.push_back(E.makeStringValue(ch));
        return;
    }
    if (Container* c = E.contOf(val)) {
        int64_t n = NythonExecutor::seqLen(c);
        if (n >= 0 && !NythonExecutor::isSetCont(c)) { cu.k = Cursor::SEQ; cu.c = c; return; }
        cu.k = Cursor::VEC;
        cu.v = E.iterItems(val, ctx);   // a set's items, a dict's typed keys
        return;
    }
    if (E.isInstanceValue(val)) {
        std::vector<Value> none;
        if (E.instanceHasMethod(val, "__iter__")) {
            Value it = E.callMethod(val, "__iter__", none, ctx);
            if (E.isInstanceValue(it)) {
                if (!E.instanceHasMethod(it, "__next__"))
                    raise("TypeError", "iter() returned non-iterator of type '" + E.instanceClassName(it) + "'");
                cu.k = Cursor::INST; cu.it = it; return;
            }
            if (it.type == ValueType::NONE || it.type == ValueType::UNDEFINED)
                raise("TypeError", "iter() returned non-iterator of type 'NoneType'");
            open(E, it, ctx, cu, false);
            return;
        }
        if (E.instanceHasMethod(val, "__next__")) { cu.k = Cursor::INST; cu.it = val; return; }
        if (E.instanceHasMethod(val, "__getitem__")) { cu.k = Cursor::GETITEM; return; }
        raise("TypeError", "'" + E.instanceClassName(val) + "' object is not iterable");
    }
    raise("TypeError", "'" + E.typeNameOf(val) + "' object is not iterable");
}

bool step(NythonExecutor& E, Cursor& cu, Value& out, Context* ctx) {
    switch (cu.k) {
    case Cursor::END: return false;
    case Cursor::SEQ: {
        int64_t n = NythonExecutor::seqLen(cu.c);
        if (cu.i >= n) { cu.k = Cursor::END; return false; }
        auto it = cu.c->container->find(std::to_string(cu.i++));
        out = it != cu.c->container->end() ? it->second : NONE_VALUE;
        return true;
    }
    case Cursor::VEC:
        if ((size_t)cu.i >= cu.v.size()) { cu.k = Cursor::END; return false; }
        out = cu.v[(size_t)cu.i++];
        return true;
    case Cursor::RANGE:
        if (cu.i >= cu.n) { cu.k = Cursor::END; return false; }
        out = intValue(cu.i++);
        return true;
    case Cursor::GEN:
        if (next(E, cu.g, out, ctx)) return true;
        cu.k = Cursor::END;
        return false;
    case Cursor::INST: {
        std::vector<Value> none;
        try { out = E.callMethod(cu.it, "__next__", none, ctx); }
        catch (nython::node::ReturnSignal& r) { out = r.value; }
        catch (std::string& s) {
            if (!is_exc(E, s, "StopIteration") && s.find("StopIteration") == std::string::npos) throw;
            Value ev = E.excInstanceOf(s);
            if (ev.type != ValueType::NONE) {
                auto pit = E.instance_properties.find(ev.value.p);
                if (pit != E.instance_properties.end()) {
                    Value vv = pit->second->getByName("value");
                    if (vv.type != ValueType::UNDEFINED) cu.stop_value = vv;
                }
            }
            cu.k = Cursor::END;
            return false;
        }
        return true;
    }
    case Cursor::GETITEM: {
        std::vector<Value> ia{intValue(cu.i)};
        try { out = E.callMethod(cu.hold, "__getitem__", ia, ctx); }
        catch (std::string& s) {
            if (is_exc(E, s, "IndexError") || is_exc(E, s, "StopIteration")) { cu.k = Cursor::END; return false; }
            throw;
        }
        cu.i++;
        return true;
    }
    }
    return false;
}

void finish(NythonExecutor& E, Gen* g);

// Closes a generator this cursor owns (a temporary): reports instead of
// raising, as CPython does for a finalizer.
void close_owned(NythonExecutor& E, Cursor& cu) {
    Gen* g = cu.g;
    if (g && cu.owns && g->st != St::Done && g->st != St::Running) {
        try { close(E, g); }
        catch (std::string& s) { report_ignored(E, g, s); }
        catch (...) {}
    }
    cu.k = Cursor::END;
}

// ── Function generators: switching ─────────────────────────────────────────
Value run_body(NythonExecutor& E, Gen* g) {
    auto& f = NythonExecutor::flow();
    f.fast_ctx = g->fc;
    f.brk_ok = false;
    f.pending = 0;
    f.value = NONE_VALUE;
    E.evalNode(g->fn->body, g->fc);
    Value r = NONE_VALUE;
    if (f.pending == 1) r = f.value;
    f.pending = 0;
    f.value = NONE_VALUE;
    return r;
}

// The coroutine's function: the body, with everything it raises caught
// here and handed to the resumer (nothing may unwind past this frame).
void entry(void* p) {
    Gen* g = (Gen*)p;
    NythonExecutor& E = *g->E;
    try {
        g->retval = run_body(E, g);
    } catch (nython::node::ReturnSignal& r) {
        g->retval = r.value;
    } catch (GenKill&) {
    } catch (std::string& s) {
        // PEP 479: a StopIteration escaping a generator body would silently
        // end whatever loop drives it; it becomes a RuntimeError.
        if (is_exc(E, s, "StopIteration"))
            g->exc = std::make_exception_ptr(std::string("__exc__:RuntimeError:generator raised StopIteration"));
        else
            g->exc = std::current_exception();
    } catch (...) {
        g->exc = std::current_exception();
    }
    g->yielded = false;
}

// What a paused `yield` evaluates to when the generator is resumed.
Value after_resume(Gen* g) {
    switch (g->mode) {
    case Mode::Next: return NONE_VALUE;
    case Mode::Send: { Value s = g->xfer; g->xfer = NONE_VALUE; return s; }
    case Mode::Throw: { std::string t; t.swap(g->thrown); throw t; }
    case Mode::Close: throw std::string("__exc__:GeneratorExit:");
    case Mode::Kill: throw GenKill();
    }
    return NONE_VALUE;
}

// Runs the generator until it yields (true: the value is in g->xfer) or
// finishes (false: g->retval). The body's exception propagates.
bool resume_function(NythonExecutor& E, Gen* g, Mode m) {
    if (g->co && nycoro::started(g->co) && nycoro::owner(g->co) != nycoro::thread_token())
        raise("RuntimeError", "generator '" + g->name + "' was started on another thread; a started "
              "generator can only be resumed by the thread that started it");
    int rd = NythonExecutor::call_depth_;
    if (rd + 1 >= NythonExecutor::kMaxCallDepth || nycoro::stack_exhausted())
        raise("RecursionError", "maximum recursion depth exceeded while resuming generator '" + g->name + "'");
    if (!g->co) {
        try { g->co = nycoro::create(&entry, g); }
        catch (std::bad_alloc&) {
            raise("MemoryError", "cannot allocate a stack for generator '" + g->name + "' ("
                  + std::to_string(g_suspended) + " generators are suspended)");
        }
    }
    auto& f = NythonExecutor::flow();
    auto& H = E.handling_exc_;
    auto& O = E.owner_stack_;
    auto& T = NythonExecutor::tracer().fn_stack;
    // The resumer's state.
    Context* r_fast = f.fast_ctx;
    bool r_brk = f.brk_ok;
    int r_pend = f.pending;
    Value r_val = f.value;
    node_ptr r_last = NythonExecutor::last_stmt();
    Gen* r_gen = t_cur;
    size_t h0 = H.size(), o0 = O.size(), t0 = T.size();
    bool tracing = NythonExecutor::trace_on() && !NythonExecutor::tracer().in_repr;
    // The generator's.
    f.fast_ctx = g->saved.fast_ctx;
    f.brk_ok = g->saved.brk_ok;
    f.pending = g->saved.pending;
    f.value = g->saved.value;
    if (g->saved.last) NythonExecutor::last_stmt() = g->saved.last;
    NythonExecutor::call_depth_ = rd + 1 + g->saved.rel_depth;
    H.insert(H.end(), g->saved.handling.begin(), g->saved.handling.end());
    O.insert(O.end(), g->saved.owners.begin(), g->saved.owners.end());
    if (tracing) T.push_back(g->name);
    size_t t1 = T.size();
    T.insert(T.end(), g->saved.trace.begin(), g->saved.trace.end());
    t_cur = g;
    g->st = St::Running;
    g->mode = m;
    g->yielded = false;
    {
        NythonExecutor::ProfScope prof(&E, NythonExecutor::profiling_enabled() ? g->name : std::string());
        nycoro::resume(g->co);
    }
    // Back: keep the generator's state, put the resumer's back.
    g->saved.fast_ctx = f.fast_ctx;
    g->saved.brk_ok = f.brk_ok;
    g->saved.pending = f.pending;
    g->saved.value = f.value;
    g->saved.last = NythonExecutor::last_stmt();
    g->saved.rel_depth = NythonExecutor::call_depth_ - (rd + 1);
    g->saved.handling.assign(H.size() > h0 ? H.begin() + (long)h0 : H.end(), H.end());
    H.resize(std::min(H.size(), h0));
    g->saved.owners.assign(O.size() > o0 ? O.begin() + (long)o0 : O.end(), O.end());
    O.resize(std::min(O.size(), o0));
    g->saved.trace.assign(T.size() > t1 ? T.begin() + (long)t1 : T.end(), T.end());
    T.resize(std::min(T.size(), t0));
    f.fast_ctx = r_fast;
    f.brk_ok = r_brk;
    f.pending = r_pend;
    f.value = r_val;
    NythonExecutor::call_depth_ = rd;
    t_cur = r_gen;
    bool finished = nycoro::done(g->co);
    // An exception keeps the generator's statement as the last one run, so
    // an uncaught error reports where it was raised.
    if (!(finished && g->exc)) NythonExecutor::last_stmt() = r_last;
    if (!finished) {
        g->st = St::Suspended;
        list_add(g);
        return true;
    }
    std::exception_ptr ex = g->exc;
    g->exc = nullptr;
    finish(E, g);
    if (ex) std::rethrow_exception(ex);
    return false;
}

// ── Finishing ──────────────────────────────────────────────────────────────
void finish(NythonExecutor& E, Gen* g) {
    g->st = St::Done;
    switch (g->kind) {
    case Kind::Function:
        list_remove(g);
        if (g->co) {
            if (!nycoro::started(g->co) || nycoro::done(g->co)) { nycoro::destroy(g->co); g->co = nullptr; }
        }
        g->saved = Saved();
        g->delegate = NONE_VALUE;
        g->xfer = NONE_VALUE;
        if (g->fc_pinned) { g->fc_pinned = false; unpin(E, g->fc); }
        g->fc = nullptr;
        break;
    case Kind::GenExpr: {
        std::vector<Cursor> cs;
        cs.swap(g->cur);
        for (auto& c : cs) close_owned(E, c);
        if (g->cc) { Context* cc = g->cc; g->cc = nullptr; E.reapContext(cc); }
        if (g->outer_pinned) { g->outer_pinned = false; unpin(E, g->outer); }
        g->outer = nullptr;
        break;
    }
    case Kind::Native: {
        std::vector<Cursor> cs;
        cs.swap(g->src);
        for (auto& c : cs) close_owned(E, c);
        g->fnv = NONE_VALUE;
        break;
    }
    }
}

Gen* new_gen(NythonExecutor& E, Kind k, const std::string& name) {
    Gen* g = new Gen();
    g->E = &E;
    g->kind = k;
    g->name = name;
    g->serial = ++t_serial;
    g->creator = nycoro::thread_token();
    g->birth_depth = NythonExecutor::call_depth_;
    g_created++;
    return g;
}
Value wrap(NythonExecutor& E, Gen* g) {
    auto* o = new GenObject((Runnable*)E.runner, g);
    g->obj = o;
    return Value((Collectable*)o);
}

// ── Generator expressions ───────────────────────────────────────────────────
bool genexpr_next(NythonExecutor& E, Gen* g, Value& out) {
    auto* cn = g->comp;
    while (!g->cur.empty()) {
        size_t k = g->cur.size() - 1;
        Value item;
        if (!step(E, g->cur[k], item, g->cc)) {
            Cursor done = std::move(g->cur[k]);
            g->cur.pop_back();
            close_owned(E, done);
            continue;
        }
        auto& cl = cn->clauses[k];
        E.bindTarget(cl.target, item, g->cc);
        bool keep = true;
        for (auto& c : cl.conds) if (!E.isTruthy(E.evalNode(c, g->cc))) { keep = false; break; }
        if (!keep) continue;
        if (k + 1 < cn->clauses.size()) {
            Value iv = E.evalNode(cn->clauses[k + 1].iter, g->cc);
            Cursor nc;
            open(E, iv, g->cc, nc);
            g->cur.push_back(std::move(nc));
            continue;
        }
        out = E.evalNode(cn->elt, g->cc);
        return true;
    }
    return false;
}

// ── Native lazy iterators ──────────────────────────────────────────────────
bool native_next(NythonExecutor& E, Gen* g, Value& out, Context* ctx) {
    switch (g->op) {
    case Op::Zip: {
        if (g->src.empty()) return false;
        std::vector<Value> row;
        row.reserve(g->src.size());
        for (auto& s : g->src) {
            Value v;
            if (!step(E, s, v, ctx)) return false;
            row.push_back(v);
        }
        out = E.makeListValue(row, true);
        return true;
    }
    case Op::Map: {
        std::vector<Value> a;
        a.reserve(g->src.size());
        for (auto& s : g->src) {
            Value v;
            if (!step(E, s, v, ctx)) return false;
            a.push_back(v);
        }
        out = E.callFunctionValue(g->fnv, a, ctx);
        return true;
    }
    case Op::Filter:
        for (;;) {
            Value v;
            if (!step(E, g->src[0], v, ctx)) return false;
            bool keep;
            if (g->fnv.type == ValueType::NONE) keep = E.isTruthy(v);
            else { std::vector<Value> a{v}; keep = E.isTruthy(E.callFunctionValue(g->fnv, a, ctx)); }
            if (keep) { out = v; return true; }
        }
    case Op::Enumerate: {
        Value v;
        if (!step(E, g->src[0], v, ctx)) return false;
        out = E.makeListValue({g->idx, v}, true);
        g->idx = E.binaryOp(NythonExecutor::OP_ADD, g->idx, intValue(1), ctx);
        return true;
    }
    case Op::Iter:
        return step(E, g->src[0], out, ctx);
    case Op::Islice: {
        // CPython's islice_next: skip to the next wanted index, stop at `stop`
        // without reading past it.
        Cursor& s = g->src[0];
        Value v;
        while (g->cnt < g->nxt) {
            if (!step(E, s, v, ctx)) return false;
            g->cnt++;
        }
        if (g->stop != -1 && g->cnt >= g->stop) return false;
        if (!step(E, s, v, ctx)) return false;
        g->cnt++;
        int64_t old = g->nxt;
        g->nxt += g->step;
        if (g->nxt < old || (g->stop != -1 && g->nxt > g->stop)) g->nxt = g->stop;
        out = v;
        return true;
    }
    }
    return false;
}

// Advances a generator expression or native iterator, with the running
// guard and finishing (sources closed) on exhaustion or error.
bool machine_next(NythonExecutor& E, Gen* g, Value& out, Context* ctx) {
    if (g->st == St::Done) return false;
    if (g->st == St::Running) raise("ValueError", "generator already executing");
    g->st = St::Running;
    bool got;
    try {
        got = g->kind == Kind::GenExpr ? genexpr_next(E, g, out) : native_next(E, g, out, ctx);
    } catch (...) {
        finish(E, g);
        throw;
    }
    if (!got) { finish(E, g); return false; }
    g->st = St::Suspended;
    return true;
}

// Closes (and if need be force-unwinds) a suspended function generator
// nobody refers to any more; never raises.
void finalize(NythonExecutor& E, Gen* g) {
    if (g->kind != Kind::Function) { if (g->st != St::Done) finish(E, g); return; }
    if (g->st == St::Suspended) {
        try { close(E, g); }
        catch (std::string& s) { report_ignored(E, g, s); }
        catch (...) {}
    }
    for (int i = 0; i < 4 && g->st == St::Suspended; i++) {
        try { resume_function(E, g, Mode::Kill); } catch (...) {}
    }
    if (g->st == St::Suspended) {
        // It yields even while being unwound: give up on its stack.
        list_remove(g);
        nycoro::destroy(g->co);
        g->co = nullptr;
        finish(E, g);
    }
    if (g->st == St::Created) finish(E, g);
}

}  // namespace

// ── GenObject ───────────────────────────────────────────────────────────────
GenObject::GenObject(Runnable* r, Gen* gen) : Object(r, "__gen__", nython::kernel::Type::GENERATOR), g(gen) {
    (*container)["__gen__"] = Value(1);
}

GenObject::~GenObject() {
    Gen* gg = g;
    g = nullptr;
    if (!gg) return;
    gg->obj = nullptr;
    if (g_shutdown) {
        // The executor is gone or going: release memory only. A suspended
        // generator's stack is left as it is (its frames were never unwound).
        list_remove(gg);
        if (gg->co && (!nycoro::started(gg->co) || nycoro::done(gg->co))) nycoro::destroy(gg->co);
        gg->co = nullptr;
        gg->cur.clear();
        gg->src.clear();
        delete gg;
        return;
    }
    if (gg->st == St::Running) { gg->orphan = true; return; }
    if (gg->kind == Kind::Function && gg->st == St::Suspended) {
        if (gg->co && nycoro::owner(gg->co) == nycoro::thread_token()) {
            // Finish it at the next statement boundary, not here.
            t_pending_list.push_back(gg);
            t_pending = true;
        } else {
            // Another thread started it: that thread alone may resume it.
            list_remove(gg);
        }
        return;
    }
    if (gg->st != St::Done) {
        // Nothing of the language runs for these: drop the references.
        gg->cur.clear();
        gg->src.clear();
        if (gg->kind == Kind::Function) {
            if (gg->co) { nycoro::destroy(gg->co); gg->co = nullptr; }
            if (gg->fc_pinned && gg->E) { gg->fc_pinned = false; unpin(*gg->E, gg->fc); }
        } else if (gg->kind == Kind::GenExpr && gg->E) {
            if (gg->cc) { Context* cc = gg->cc; gg->cc = nullptr; gg->E->reapContext(cc); }
            if (gg->outer_pinned) { gg->outer_pinned = false; unpin(*gg->E, gg->outer); }
        }
    }
    delete gg;
}

std::string GenObject::toString() {
    return "<generator object " + (g ? g->name : std::string("?")) + " at " + hex_ptr(this) + ">";
}

// ── Creation ────────────────────────────────────────────────────────────────
Value make_function_gen(NythonExecutor& E, void* fn_node, Context* fc) {
    auto* fn = static_cast<FunctionNode*>(fn_node);
    Gen* g = new_gen(E, Kind::Function, fn->name);
    g->fn = fn;
    g->fc = fc;
    pin(fc);
    g->fc_pinned = true;
    if (!E.owner_stack_.empty()) g->saved.owners.push_back(E.owner_stack_.back());
    return wrap(E, g);
}

Value make_genexpr(NythonExecutor& E, const node_ptr& comp, Context* ctx) {
    auto* cn = static_cast<ComprehensionNode*>(comp.get());
    Gen* g = new_gen(E, Kind::GenExpr, "<genexpr>");
    g->comp = cn;
    g->comp_keep = comp;
    try {
        if (!cn->clauses.empty()) {
            // The first iterable is evaluated, and iter() applied to it, now,
            // in the enclosing scope (as in Python).
            uint64_t s0 = t_serial;
            Value itv = E.evalNode(cn->clauses[0].iter, ctx);
            Cursor c0;
            open(E, itv, ctx, c0, fresh(itv, cn->clauses[0].iter, NythonExecutor::call_depth_, s0));
            g->cur.push_back(std::move(c0));
        }
    } catch (...) {
        delete g;
        throw;
    }
    g->serial = ++t_serial;   // made after its first iterable
    g->outer = ctx;
    if (ctx && ctx != E.global_ctx) { pin(ctx); g->outer_pinned = true; }
    g->cc = new Context(E.runner, "<genexpr>", nullptr, nullptr, ctx);
    return wrap(E, g);
}

// ── Inside a generator body ─────────────────────────────────────────────────
Value yield_value(NythonExecutor& E, const Value& v) {
    (void)E;
    Gen* g = t_cur;
    if (!g || !g->co || nycoro::current() != g->co) raise("SyntaxError", "'yield' outside function");
    g->xfer = v;
    g->yielded = true;
    nycoro::suspend();
    return after_resume(g);
}

Value yield_from(NythonExecutor& E, const Value& src, Context* ctx) {
    Gen* g = t_cur;
    if (!g || !g->co || nycoro::current() != g->co) raise("SyntaxError", "'yield from' outside function");
    Cursor cu;
    open(E, src, ctx, cu);
    Value result = NONE_VALUE;
    g->delegate = src;
    Mode m = Mode::Next;
    Value in;
    std::string th;
    for (;;) {
        Value v;
        bool got = false;
        if (cu.k == Cursor::GEN && cu.g->kind == Kind::Function) {
            Gen* sub = cu.g;
            if (sub->st == St::Running) raise("ValueError", "generator already executing");
            if (m == Mode::Throw) {
                if (sub->st == St::Done || sub->st == St::Created) {
                    if (sub->st == St::Created) finish(E, sub);
                    g->delegate = NONE_VALUE;
                    throw th;
                }
                sub->thrown = th;
                got = resume_function(E, sub, Mode::Throw);
            } else if (sub->st == St::Done) {
                got = false;
            } else {
                if (m == Mode::Send) sub->xfer = in;
                got = resume_function(E, sub, m);
            }
            if (got) { v = sub->xfer; sub->xfer = NONE_VALUE; }
            else { result = sub->retval; sub->retval = NONE_VALUE; }
        } else if (m == Mode::Throw) {
            // A plain iterator: its own throw(), if it has one.
            if (cu.k == Cursor::INST && E.instanceHasMethod(cu.it, "throw")) {
                std::vector<Value> a{E.exceptionObject(th)};
                try { v = E.callMethod(cu.it, "throw", a, ctx); got = true; }
                catch (std::string& s) {
                    if (!is_exc(E, s, "StopIteration")) throw;
                    got = false;
                }
            } else {
                if (cu.k == Cursor::GEN) close_owned(E, cu);
                g->delegate = NONE_VALUE;
                throw th;
            }
        } else if (m == Mode::Send && cu.k == Cursor::INST && E.instanceHasMethod(cu.it, "send")) {
            std::vector<Value> a{in};
            try { v = E.callMethod(cu.it, "send", a, ctx); got = true; }
            catch (std::string& s) {
                if (!is_exc(E, s, "StopIteration")) throw;
                got = false;
            }
        } else {
            got = step(E, cu, v, ctx);
            if (!got && cu.k == Cursor::END) result = cu.stop_value;
        }
        if (!got) {
            g->delegate = NONE_VALUE;
            return result;
        }
        // Pass the value up, and what comes back down.
        g->xfer = v;
        g->yielded = true;
        nycoro::suspend();
        m = g->mode;
        in = NONE_VALUE;
        if (m == Mode::Send) { in = g->xfer; g->xfer = NONE_VALUE; if (in.type == ValueType::NONE) m = Mode::Next; }
        if (m == Mode::Throw) {
            th.clear();
            th.swap(g->thrown);
            if (is_exc(E, th, "GeneratorExit")) m = Mode::Close;
        }
        if (m == Mode::Close) {
            // The subiterator is closed first, then GeneratorExit is raised
            // here (PEP 380).
            g->delegate = NONE_VALUE;
            if (cu.k == Cursor::GEN && cu.g) close(E, cu.g);
            else if (cu.k == Cursor::INST && E.instanceHasMethod(cu.it, "close")) {
                std::vector<Value> none;
                E.callMethod(cu.it, "close", none, ctx);
            }
            throw std::string("__exc__:GeneratorExit:");
        }
        if (m == Mode::Kill) { g->delegate = NONE_VALUE; throw GenKill(); }
    }
}

// ── Protocol ────────────────────────────────────────────────────────────────
bool next(NythonExecutor& E, Gen* g, Value& out, Context* ctx) {
    if (g->kind != Kind::Function) return machine_next(E, g, out, ctx);
    if (g->st == St::Done) return false;
    if (g->st == St::Running) raise("ValueError", "generator already executing");
    if (!resume_function(E, g, Mode::Next)) return false;
    out = g->xfer;
    g->xfer = NONE_VALUE;
    return true;
}

Value next_or_raise(NythonExecutor& E, Gen* g, Context* ctx) {
    Value v;
    if (next(E, g, v, ctx)) return v;
    Value rv = g->retval;
    g->retval = NONE_VALUE;
    raise_stop(E, rv, ctx);
}

void drain(NythonExecutor& E, Gen* g, std::vector<Value>& out, Context* ctx) {
    Value v;
    while (next(E, g, v, ctx)) out.push_back(v);
}

bool contains(NythonExecutor& E, Gen* g, const Value& x, Context* ctx) {
    Value v;
    while (next(E, g, v, ctx)) if (E.pyEquals(x, v, ctx)) return true;
    return false;
}

void close(NythonExecutor& E, Gen* g) {
    if (g->st == St::Done) return;
    if (g->st == St::Running) raise("ValueError", "generator already executing");
    if (g->kind != Kind::Function || g->st == St::Created) { finish(E, g); return; }
    bool yielded;
    try {
        yielded = resume_function(E, g, Mode::Close);
    } catch (std::string& s) {
        if (is_exc(E, s, "GeneratorExit") || is_exc(E, s, "StopIteration")) return;
        throw;
    }
    if (yielded) raise("RuntimeError", "generator ignored GeneratorExit");
}

std::string type_name(const Gen*) { return "generator"; }

bool method(NythonExecutor& E, const Value& obj, const std::string& name, std::vector<Value>& args,
            Context* ctx, Value& out) {
    Gen* g = gen_of(obj);
    if (!g) return false;
    if (name == "__next__" || name == "next") {
        out = next_or_raise(E, g, ctx);
        return true;
    }
    if (name == "__iter__") { out = obj; return true; }
    if (name == "send") {
        if (args.size() != 1) raise("TypeError", "generator.send() takes exactly one argument (" + std::to_string(args.size()) + " given)");
        const Value& v = args[0];
        bool is_none = v.type == ValueType::NONE;
        if (g->st == St::Created && !is_none) raise("TypeError", "can't send non-None value to a just-started generator");
        if (g->kind != Kind::Function || is_none) { out = next_or_raise(E, g, ctx); return true; }
        if (g->st == St::Done) raise_stop(E, NONE_VALUE, ctx);
        if (g->st == St::Running) raise("ValueError", "generator already executing");
        g->xfer = v;
        if (resume_function(E, g, Mode::Send)) { out = g->xfer; g->xfer = NONE_VALUE; return true; }
        Value rv = g->retval;
        g->retval = NONE_VALUE;
        raise_stop(E, rv, ctx);
    }
    if (name == "throw") {
        if (args.empty()) raise("TypeError", "throw expected at least 1 argument, got 0");
        std::vector<Value> cargs(args.begin() + 1, args.end());
        std::string th = exc_string_for(E, args[0], cargs, ctx ? ctx : E.global_ctx);
        if (g->st == St::Running) raise("ValueError", "generator already executing");
        if (g->kind != Kind::Function || g->st != St::Suspended) {
            // Not paused at a yield: the exception is raised straight away
            // and the generator is finished (Python's behaviour for one not
            // yet started, or already done).
            if (g->st != St::Done) finish(E, g);
            throw th;
        }
        g->thrown = th;
        if (resume_function(E, g, Mode::Throw)) { out = g->xfer; g->xfer = NONE_VALUE; return true; }
        Value rv = g->retval;
        g->retval = NONE_VALUE;
        raise_stop(E, rv, ctx);
    }
    if (name == "close") { close(E, g); out = NONE_VALUE; return true; }
    return false;
}

// ── Builtins ────────────────────────────────────────────────────────────────
namespace {
// Whether argument i of the builtin call being made is a temporary the
// call's own argument expressions made (evalCall's callBuiltinTemps).
bool owns_arg(uint32_t mask, size_t i) { return i < 32 && (mask >> i) & 1u; }

Value make_native(NythonExecutor& E, Op op, const char* name) {
    Gen* g = new_gen(E, Kind::Native, name);
    g->op = op;
    return wrap(E, g);
}

int64_t islice_int(NythonExecutor& E, const Value& v, bool& none, const char* what) {
    none = v.type == ValueType::NONE;
    if (none) return -1;
    NythonExecutor::Num n;
    if (!NythonExecutor::asNum(v, n) || n.k != 1 || n.i < 0) {
        (void)E;
        raise("ValueError", std::string(what));
    }
    return n.i;
}
}  // namespace

bool consumes(const std::string& name) {
    static const std::unordered_map<std::string, int> names = {
        {"any", 1}, {"all", 1}, {"sum", 1}, {"min", 1}, {"max", 1}, {"sorted", 1}, {"list", 1},
        {"tuple", 1}, {"set", 1}, {"frozenset", 1}, {"dict", 1}, {"next", 1}, {"take", 1},
        {"reversed", 1},
    };
    return names.count(name) > 0;
}

bool builtin(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx, Value& out) {
    const uint32_t fresh_mask = t_fresh_args;   // taken: nested builtins must not see it
    t_fresh_args = 0;
    auto kwv = [&](const char* k) -> const Value* {
        if (!E.cur_kwargs_) return nullptr;
        auto it = E.cur_kwargs_->find(k);
        return it == E.cur_kwargs_->end() ? nullptr : &it->second;
    };
    if (name == "islice") {
        if (args.size() < 2 || args.size() > 4) raise("TypeError", "islice expected 2 to 4 arguments, got " + std::to_string(args.size()));
        E.cur_kwargs_ = nullptr;
        const char* msg_idx = "Stop argument for islice() must be None or an integer: 0 <= x <= sys.maxsize.";
        const char* msg_ss = "Indices for islice() must be None or an integer: 0 <= x <= sys.maxsize.";
        int64_t start = 0, stop = -1, stp = 1;
        bool none = false;
        if (args.size() == 2) {
            stop = islice_int(E, args[1], none, msg_idx);
            if (none) stop = -1;
        } else {
            start = islice_int(E, args[1], none, msg_ss);
            if (none) start = 0;
            stop = islice_int(E, args[2], none, msg_ss);
            if (none) stop = -1;
            if (args.size() == 4) {
                bool snone = false;
                int64_t s = 0;
                if (args[3].type != ValueType::NONE) {
                    NythonExecutor::Num n;
                    if (!NythonExecutor::asNum(args[3], n) || n.k != 1 || n.i <= 0)
                        raise("ValueError", "Step for islice() must be a positive integer or None.");
                    s = n.i;
                } else snone = true;
                stp = snone ? 1 : s;
            }
        }
        Value res = make_native(E, Op::Islice, "islice");
        Gen* g = gen_of(res);
        g->src.emplace_back();
        open(E, args[0], ctx, g->src.back(), owns_arg(fresh_mask, 0));
        g->nxt = start;
        g->stop = stop;
        g->step = stp;
        out = res;
        return true;
    }
    if (name == "take") {
        // take(n, iterable): the first n values as a list (the itertools
        // recipe; the iterator is left just after them).
        if (args.size() != 2) raise("TypeError", "take() takes exactly 2 arguments (" + std::to_string(args.size()) + " given)");
        NythonExecutor::Num n;
        if (!NythonExecutor::asNum(args[0], n) || n.k != 1) raise("TypeError", "take(): n must be an integer");
        Cursor cu;
        open(E, args[1], ctx, cu);
        std::vector<Value> items;
        Value v;
        for (int64_t i = 0; i < n.i && step(E, cu, v, ctx); i++) items.push_back(v);
        out = E.makeListValue(items);
        return true;
    }
    // The rest only when a generator is involved.
    if (name == "iter" && args.size() == 1 && is_gen(args[0])) { out = args[0]; return true; }
    if (name == "next" && !args.empty() && is_gen(args[0])) {
        Gen* g = gen_of(args[0]);
        if (args.size() >= 2) {
            Value v;
            if (next(E, g, v, ctx)) out = v;
            else { g->retval = NONE_VALUE; out = args[1]; }
            return true;
        }
        out = next_or_raise(E, g, ctx);
        return true;
    }
    if ((name == "any" || name == "all") && args.size() == 1 && is_gen(args[0])) {
        bool want_any = name == "any";
        Gen* g = gen_of(args[0]);
        Value v;
        while (next(E, g, v, ctx)) {
            bool t = E.isTruthy(v);
            if (want_any && t) { out = Value(true); return true; }
            if (!want_any && !t) { out = Value(false); return true; }
        }
        out = Value(!want_any);
        return true;
    }
    if (name == "zip" || name == "map" || name == "filter" || name == "enumerate") {
        size_t first = (name == "map" || name == "filter") ? 1 : 0;
        size_t last = name == "enumerate" ? 1 : args.size();
        bool lazy = false;
        for (size_t i = first; i < last && i < args.size(); i++) if (is_gen(args[i])) lazy = true;
        if (!lazy) return false;
        if (name == "zip") {
            E.cur_kwargs_ = nullptr;
            Value res = make_native(E, Op::Zip, "zip");
            Gen* g = gen_of(res);
            g->src.resize(args.size());
            for (size_t i = 0; i < args.size(); i++) open(E, args[i], ctx, g->src[i], owns_arg(fresh_mask, i));
            out = res;
            return true;
        }
        if (name == "map") {
            E.cur_kwargs_ = nullptr;
            if (args.size() < 2) raise("TypeError", "map() must have at least two arguments.");
            Value res = make_native(E, Op::Map, "map");
            Gen* g = gen_of(res);
            g->fnv = args[0];
            g->src.resize(args.size() - 1);
            for (size_t i = 1; i < args.size(); i++) open(E, args[i], ctx, g->src[i - 1], owns_arg(fresh_mask, i));
            out = res;
            return true;
        }
        if (name == "filter") {
            E.cur_kwargs_ = nullptr;
            if (args.size() != 2) raise("TypeError", "filter expected 2 arguments, got " + std::to_string(args.size()));
            Value res = make_native(E, Op::Filter, "filter");
            Gen* g = gen_of(res);
            g->fnv = args[0];
            g->src.resize(1);
            open(E, args[1], ctx, g->src[0], owns_arg(fresh_mask, 1));
            out = res;
            return true;
        }
        // enumerate(g, start=0)
        const Value* sv = args.size() >= 2 ? &args[1] : kwv("start");
        Value start = sv ? *sv : intValue((int64_t)0);
        E.cur_kwargs_ = nullptr;
        Value res = make_native(E, Op::Enumerate, "enumerate");
        Gen* g = gen_of(res);
        g->idx = start;
        g->src.resize(1);
        open(E, args[0], ctx, g->src[0], owns_arg(fresh_mask, 0));
        out = res;
        return true;
    }
    return false;
}

// ── Ownership of temporaries ────────────────────────────────────────────────


bool fresh(const Value& v, const node_ptr& node, int depth, uint64_t s0) {
    Gen* g = gen_of(v);
    if (!g || g->serial <= s0 || !node || g->creator != nycoro::thread_token()) return false;
    if (node->type() == NodeType::CALL) return g->kind != Kind::GenExpr && g->birth_depth == depth + 1;
    if (node->type() == NodeType::COMPREHENSION) return g->kind == Kind::GenExpr && g->birth_depth == depth;
    return false;
}

bool fresh_implicit(const Value& v, int depth, uint64_t s0) {
    Gen* g = gen_of(v);
    return g && g->serial > s0 && g->kind == Kind::Function && g->birth_depth == depth
        && g->creator == nycoro::thread_token();
}

void close_temp(NythonExecutor& E, const Value& v) {
    Gen* g = gen_of(v);
    if (!g || g->st == St::Done || g->st == St::Running) return;
    try { close(E, g); }
    catch (std::string& s) { report_ignored(E, g, s); }
    catch (...) {}
}

// ── A `for` over a generator ───────────────────────────────────────────────
Value for_loop(NythonExecutor& E, void* for_node, const Value& gv, Context* ctx, bool owned) {
    auto* fn = static_cast<ForNode*>(for_node);
    Gen* g = gen_of(gv);
    auto& lf = NythonExecutor::flow();
    bool broke = false, returning = false;
    Value result = NONE_VALUE;
    std::string var_name = fn->var->value();
    auto bindv = [&](const std::string& n, const Value& v) {
        if (fn->rebinds) ctx->setByName(n, v); else ctx->defineByName(n, v);
    };
    auto bind_item = [&](const Value& elem) {
        if (fn->unpack_vars.empty()) { bindv(var_name, elem); return; }
        std::vector<Value> parts;
        if (Container* ec = E.contOf(elem); ec && NythonExecutor::seqLen(ec) >= 0) parts = NythonExecutor::seqItems(ec);
        else parts = E.iterValues(elem, ctx);
        bindv(var_name, parts.empty() ? NONE_VALUE : parts[0]);
        for (size_t ui = 0; ui < fn->unpack_vars.size(); ui++)
            bindv(fn->unpack_vars[ui]->value(), ui + 1 < parts.size() ? parts[ui + 1] : NONE_VALUE);
    };
    try {
        Value elem;
        while (next(E, g, elem, ctx)) {
            bind_item(elem);
            try { NythonExecutor::LoopBody _lb(lf); result = E.evalNode(fn->body, ctx); }
            catch (std::string& flow) {
                if (flow == "break") { broke = true; break; }
                if (flow == "continue") continue;
                throw;
            }
            if (lf.pending) {
                if (lf.pending == 1) { returning = true; break; }
                int p = lf.pending;
                lf.pending = 0;
                if (p == 2) { broke = true; break; }
                continue;
            }
        }
    } catch (...) {
        if (owned) close_temp(E, gv);
        throw;
    }
    if (owned) close_temp(E, gv);
    if (returning) return result;
    if (!broke && fn->else_branch) result = E.evalNode(fn->else_branch, ctx);
    return result;
}

Value unpack_list(NythonExecutor& E, const Value& v, int n, Context* ctx) {
    Gen* g = gen_of(v);
    std::vector<Value> items;
    if (!g) return v;
    Value x;
    if (n < 0) drain(E, g, items, ctx);
    else {
        while ((int)items.size() <= n && next(E, g, x, ctx)) items.push_back(x);
        if ((int)items.size() > n) raise("ValueError", "too many values to unpack (expected " + std::to_string(n) + ")");
        if ((int)items.size() < n)
            raise("ValueError", "not enough values to unpack (expected " + std::to_string(n) + ", got " + std::to_string(items.size()) + ")");
    }
    return E.makeListValue(items);
}

bool contains_iter(NythonExecutor& E, const Value& v, const Value& x, Context* ctx) {
    Cursor cu;
    open(E, v, ctx, cu);
    Value item;
    while (step(E, cu, item, ctx)) if (E.pyEquals(x, item, ctx)) return true;
    return false;
}

Value make_iter(NythonExecutor& E, const Value& v, Context* ctx) {
    if (is_gen(v)) return v;
    Cursor cu;
    open(E, v, ctx, cu);
    if (cu.k == Cursor::GEN) return cu.hold;   // __iter__ returned a generator
    if (cu.k == Cursor::INST && E.isInstanceValue(cu.it)) return cu.it;
    Value res = make_native(E, Op::Iter, "iterator");
    gen_of(res)->src.push_back(std::move(cu));
    return res;
}

// ── Contexts ───────────────────────────────────────────────────────────────
bool defer_reap(Context* c) {
    auto& P = pins();
    auto it = P.find(c);
    if (it == P.end()) return false;
    it->second.deferred = true;
    return true;
}

// ── Finalization ────────────────────────────────────────────────────────────
void run_pending(NythonExecutor& E) {
    t_pending = false;
    std::vector<Gen*> todo;
    todo.swap(t_pending_list);
    for (Gen* g : todo) {
        finalize(E, g);
        delete g;
    }
}

void close_all(NythonExecutor& E) {
    if (t_pending) run_pending(E);
    uint64_t me = nycoro::thread_token();
    // Oldest first: module-level generators go in the order they were made,
    // as CPython clears a module's names in definition order.
    for (int guard = 0; guard < 1000000; guard++) {
        Gen* victim = nullptr;
        for (Gen* g = g_list_head; g; g = g->lnext)
            if (g->co && nycoro::owner(g->co) == me && g->st == St::Suspended) { victim = g; break; }
        if (!victim) break;
        finalize(E, victim);
        if (victim->st == St::Suspended) list_remove(victim);   // cannot happen; never loop on it
    }
}

void shutdown() { g_shutdown = true; }

// ── Deep calls inside a generator ──────────────────────────────────────────
namespace {
struct Extension {
    NythonExecutor* E = nullptr;
    const node_ptr* call = nullptr;   // evalCall(call, ctx), or
    FunctionNode* fn = nullptr;       // runFunctionBody(fn, fc)
    Context* ctx = nullptr;
    Value result;
    std::exception_ptr exc;
};
void extension_entry(void* p) {
    auto* x = (Extension*)p;
    try {
        if (x->call) x->result = x->E->evalCall(*x->call, x->ctx);
        else x->result = x->E->runFunctionBody(x->fn, x->ctx);
    } catch (...) {
        x->exc = std::current_exception();
    }
}
Value run_extension(Extension& x) {
    nycoro::Coro* co = nullptr;
    try { co = nycoro::create(&extension_entry, &x); }
    catch (std::bad_alloc&) {
        raise("RecursionError", "maximum recursion depth exceeded in a generator (no stack left to extend it)");
    }
    // A plain nested call: runs to the end, never suspends (a yield inside
    // it belongs to another generator, which has a coroutine of its own).
    nycoro::resume(co);
    bool finished = nycoro::done(co);
    if (finished) nycoro::destroy(co);
    if (!finished) raise("RuntimeError", "internal error: a call on an extension stack suspended");
    if (x.exc) std::rethrow_exception(x.exc);
    return x.result;
}
}  // namespace

Value call_on_new_stack(NythonExecutor& E, const node_ptr& call_node, Context* ctx) {
    Extension x;
    x.E = &E; x.call = &call_node; x.ctx = ctx;
    return run_extension(x);
}

Value body_on_new_stack(NythonExecutor& E, void* fn_node, Context* fc) {
    Extension x;
    x.E = &E; x.fn = static_cast<FunctionNode*>(fn_node); x.ctx = fc;
    return run_extension(x);
}

Stats stats() {
    Stats s;
    s.live_suspended = g_suspended;
    s.created = g_created;
    s.coroutines = nycoro::stats().live;
    return s;
}

}  // namespace nygen
