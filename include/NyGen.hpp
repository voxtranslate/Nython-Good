#pragma once
// ─────────────────────────────────────────────────────────────────────────────
// NyGen.hpp — lazy generators on the interpreter (round 75).
//
// Until round 75 the interpreter ran a generator function's whole body the
// moment it was called, collecting what it yielded into a list: an infinite
// generator hung, side effects happened at the wrong time and send() never
// delivered its value. Now:
//
//   * a generator function's body runs on a stackful coroutine (NyCoro.hpp):
//     calling the function makes the generator object and nothing else;
//     next()/send()/throw()/close() switch into the body, which runs until
//     its next `yield` (from any depth of evalNode) and switches back;
//   * a generator expression is a small state machine over its clauses (no
//     coroutine: its element expression cannot yield);
//   * zip/map/filter/enumerate given a generator, islice() and iter() over a
//     generator return lazy iterators of the same kind (state machines).
//
// All three are one heap object, GenObject: a Container whose map holds only
// the "__gen__" marker (so the container code that already knew the old
// eager generator still recognises it), with Type::GENERATOR as its kernel
// type for a cheap test. src/NyGen.cpp holds the implementation; the hooks
// in NythonExecutor.hpp are marked "nygen".
//
// Invariants (see HANDOFF §0l):
//   * one generator body runs at a time per OS thread, nested like calls;
//     the interpreter's per-execution state (FlowState, last statement, call
//     depth, the handled-exception / method-owner / --trace frame stacks) is
//     swapped at every switch, so the resumer never sees the generator's;
//   * no C++ exception crosses a switch: the body's exception is caught at
//     the top of the coroutine and rethrown by the resumer;
//   * a started generator is resumed only by the thread that started it
//     (RuntimeError otherwise);
//   * a suspended generator that is dropped is finished by resuming it with
//     GeneratorExit (its finally blocks and __exit__ run), never by freeing
//     its stack under live frames.
// ─────────────────────────────────────────────────────────────────────────────
#include <cstdint>
#include <string>
#include <vector>
#include "Object.hpp"
#include "Definitions.hpp"

struct NythonExecutor;

namespace nygen {

using nython::kernel::Value;
using nython::kernel::Context;
using nython::node::node_ptr;

struct Gen;

struct GenObject : nython::kernel::Object {
    Gen* g = nullptr;
    GenObject(Runnable* r, Gen* gen);
    ~GenObject() override;
    std::string toString() override;
    // The collector sees what the generator holds through its record (its
    // scope, values in flight, the iterators it reads), and a suspended one
    // is finalizable: an unreachable cycle through it is closed (finally
    // blocks run, its stack unwinds and lets go) and then freed (round 76).
    void gc_traverse(nython::gc::GcVisitFn visit, void* arg) override;
    bool gc_has_finalizer() override;
    void gc_finalize() override;
    GenObject(const GenObject&) = delete;
    GenObject& operator=(const GenObject&) = delete;
};

// The generator a value holds, or nullptr.
inline bool is_gen(const Value& v) {
    return v.type == nython::kernel::ValueType::COLLECTABLE && v.value.gc
        && v.value.gc->getType() == nython::kernel::Type::GENERATOR;
}
inline Gen* gen_of(const Value& v) { return is_gen(v) ? static_cast<GenObject*>(v.value.gc)->g : nullptr; }

// ── Creation (hooks in runFunctionBody / evalComprehensionNode) ────────────
// A generator for a call of generator function `fn` whose arguments are
// bound in `fc`. The generator keeps `fc` alive until it finishes.
Value make_function_gen(NythonExecutor& E, void* fn_node, Context* fc);
// A lazy generator expression; its first iterable is evaluated now, in ctx.
Value make_genexpr(NythonExecutor& E, const node_ptr& comp, Context* ctx);

// ── Inside a generator body (hooks for YIELD / YIELD_FROM) ─────────────────
Value yield_value(NythonExecutor& E, const Value& v);
Value yield_from(NythonExecutor& E, const Value& src, Context* ctx);

// ── Protocol ────────────────────────────────────────────────────────────────
// The next value, or false once it is exhausted (StopIteration is not
// raised; the generator's return value stays available to yield from).
bool next(NythonExecutor& E, Gen* g, Value& out, Context* ctx);
// next(g): the next value, or StopIteration carrying the return value.
Value next_or_raise(NythonExecutor& E, Gen* g, Context* ctx);
// Every remaining value (list(g), sum(g), ...).
void drain(NythonExecutor& E, Gen* g, std::vector<Value>& out, Context* ctx);
// Methods: send, throw, close, __next__, __iter__. False: not a generator
// method (the caller carries on with its own lookup).
bool method(NythonExecutor& E, const Value& obj, const std::string& name, std::vector<Value>& args,
            Context* ctx, Value& out);
// g.close(): GeneratorExit at the paused yield; finally blocks run.
void close(NythonExecutor& E, Gen* g);
// `x in g`: consumes up to the first match.
bool contains(NythonExecutor& E, Gen* g, const Value& x, Context* ctx);
// "generator".
std::string type_name(const Gen* g);
// The values an unpacking assignment of `n` targets takes from generator
// `v` (n = -1: a starred target, all of them): n + 1 are pulled at most, as
// Python does, and too many or too few is a ValueError.
Value unpack_list(NythonExecutor& E, const Value& v, int n, Context* ctx);
// `x in v` for any iterable, pulling values until the first match.
bool contains_iter(NythonExecutor& E, const Value& v, const Value& x, Context* ctx);
// iter(v) for anything that is not already a generator: a lazy iterator.
Value make_iter(NythonExecutor& E, const Value& v, Context* ctx);
// A `for` loop whose iterable is a generator: pulls one value per iteration.
// `owned`: the loop's temporary, closed when the loop ends.
Value for_loop(NythonExecutor& E, void* for_node, const Value& gen, Context* ctx, bool owned);

// ── Builtins ────────────────────────────────────────────────────────────────
// Cheap pre-check for callBuiltin: a name this module implements, or a
// generator among the arguments.
inline bool builtin_candidate(const std::string& name, const std::vector<Value>& args) {
    if ((name.size() == 6 && name == "islice") || (name.size() == 4 && name == "take")) return true;
    for (auto& a : args) if (is_gen(a)) return true;
    return false;
}
// islice, take; iter/next/any/all/zip/map/filter/enumerate over generators.
bool builtin(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx, Value& out);

// ── Ownership of temporaries ────────────────────────────────────────────────
// A generator made by the expression a `for` loop or a builtin call
// consumes, and bound to nothing else, is closed as soon as that consumer is
// done with it - as CPython's reference counting does - so `for x in g():
// break` runs g's finally blocks at the break, and any()/next() over a
// generator expression leave nothing suspended behind.
inline thread_local uint64_t t_serial = 0;   // generators made on this thread so far
inline uint64_t serial_now() { return t_serial; }
// Whether `v` is a generator that `node` (evaluated at call depth `depth`,
// after serial_now() was `s0`) made itself.
bool fresh(const Value& v, const node_ptr& node, int depth, uint64_t s0);
// Whether `v` is a generator made by an implicit __iter__() call at `depth`.
bool fresh_implicit(const Value& v, int depth, uint64_t s0);
// Closes a temporary generator its consumer is done with (errors are
// reported, as CPython reports a failing finalizer, not raised).
void close_temp(NythonExecutor& E, const Value& v);
// Positions of the arguments of the builtin call being made that are fresh
// temporaries (set by evalCall around callBuiltin; lazy wrappers take
// ownership of those).
inline thread_local uint32_t t_fresh_args = 0;
// Whether builtin `name` consumes its iterable arguments (they can be closed
// once it returns).
bool consumes(const std::string& name);

// ── Contexts kept alive by generators ───────────────────────────────────────
// reapContext() asks before freeing a call's context: a generator still
// running in it (or a generator expression reading it) keeps it, and it is
// freed when the last such generator finishes.
inline int g_pinned = 0;   // contexts pinned now (0: nothing to look up)
bool defer_reap(Context* c);   // true: pinned, reaping deferred

// ── Finalization ────────────────────────────────────────────────────────────
// A suspended generator whose object is destroyed is queued and closed at the
// next statement boundary of its own thread (not inside the destructor, which
// can run in the middle of any container operation). One dropped by another
// thread than the one that started it is left suspended (its stack stays
// mapped; its finally blocks do not run).
inline thread_local bool t_pending = false;
void run_pending(NythonExecutor& E);
// At the end of the program: close every generator still suspended on this
// thread, oldest first, so their finally blocks run (as CPython does when
// its interpreter shuts down).
void close_all(NythonExecutor& E);

// The executor is going away: generator objects destroyed from now on only
// release their own memory (no language code runs, no contexts are reaped).
void shutdown();

// ── Deep calls inside a generator ──────────────────────────────────────────
// A generator body runs on a stack of NY_GEN_STACK_KB (1 MB by default). A
// call made where that stack is nearly full runs on an extension stack of
// its own instead (switched to and back like a nested call), so recursion
// inside a generator reaches the interpreter's usual depth limit
// (RecursionError at 900 calls) exactly as it does outside one.
Value call_on_new_stack(NythonExecutor& E, const node_ptr& call_node, Context* ctx);
Value body_on_new_stack(NythonExecutor& E, void* fn_node, Context* fc);

struct Stats { size_t live_suspended; size_t created; size_t coroutines; };
Stats stats();

// The generator whose body this thread (or async task) is running: part of
// the interpreter's per-thread state that NyConc swaps (threading.cpp).
Gen*& running();

}  // namespace nygen
