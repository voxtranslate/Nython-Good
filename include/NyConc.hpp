#pragma once
// ─────────────────────────────────────────────────────────────────────────────
// NyConc.hpp — the concurrency runtime shared by BOTH engines.
//
// Everything that does not depend on how an engine represents values lives in
// src/NyConc.cpp: the GIL, the thread registry, every synchronisation
// primitive, channels/queues + select, futures and the thread pool, timers,
// task groups (structured concurrency), deadlock / lock-order detection and the
// async event loop. It is also where the builtins are dispatched — once — so
// the interpreter (src/builtins/threading.cpp) and the VM (src/VMConc.cpp)
// cannot drift apart: each engine only supplies
//   * an Engine (how to call a Nython callable, how to save/restore its
//     per-thread execution state when the GIL changes hands), and
//   * an Args adapter (read engine arguments) + a converter for Ret.
//
// Threading model
//   Real OS threads (std::thread). One process-wide GIL serialises execution
//   of Nython code: a thread holds it while it runs engine code and releases
//   it around every blocking operation. Engines call nyconc::tick() at every
//   statement (interpreter) / instruction (VM); when another thread is waiting
//   and the holder has had the GIL for longer than the switch interval (5 ms,
//   as CPython) it hands the GIL over. The GIL is a FIFO ticket lock, so a
//   yielding thread queues behind the waiters instead of re-grabbing it.
//   A hand-over that falls due while the thread holds a Nython lock waits
//   for its release (at most one more interval): a preempted lock holder
//   makes every other thread block on the lock, a convoy (tick_slow).
//   Nothing of this is active until the first thread is created, so a
//   single-threaded program pays one relaxed atomic load per statement.
//
// Lock order: the GIL may be held while taking the runtime mutex; the GIL is
// never *acquired* while the runtime mutex is held.
// ─────────────────────────────────────────────────────────────────────────────
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace nyconc {

// ── Engine values, type-erased ──────────────────────────────────────────────
struct Box { virtual ~Box() = default; };
using BoxPtr = std::shared_ptr<Box>;

// A Nython exception crossing the engine boundary.
//  - raised by the runtime itself: type + msg are set (DeadlockError, ...)
//  - captured from engine code (a thread's uncaught exception): `raw` holds the
//    engine's own payload and `obj` the engine exception object, if any, so the
//    exception can be re-raised unchanged in another thread (thread_join,
//    future_result, task groups, await).
struct NyError {
    std::string type;
    std::string msg;
    std::string raw;
    BoxPtr obj;
    NyError() : type(), msg(), raw(), obj() {}
    static NyError make(const std::string& t, const std::string& m) { NyError e; e.type = t; e.msg = m; return e; }
};

struct Engine {
    virtual ~Engine() = default;
    // Call a Nython callable on the current thread (the GIL is held). Throws
    // NyError if the callee raises.
    virtual BoxPtr call(const BoxPtr& fn, const std::vector<BoxPtr>& args) = 0;
    virtual BoxPtr box_int(int64_t v) = 0;
    virtual BoxPtr box_none() = 0;
    virtual bool   unbox_int(const BoxPtr& b, int64_t& out) = 0;
    virtual BoxPtr from_ret(const struct Ret& r) = 0;
    virtual bool   is_callable(const BoxPtr& b) = 0;
    // Human-readable text of a boxed value (task/thread names, errors).
    virtual std::string describe(const BoxPtr& b) = 0;
    // `await obj` for an object with __await__: what obj.__await__() returns
    // (nullptr when obj has none). Throws NyError if __await__ raises.
    virtual BoxPtr await_target(const BoxPtr&) { return nullptr; }
    // The exception object an error stands for (gather(return_exceptions=
    // True) returns them); nullptr when the engine cannot make one.
    virtual BoxPtr exception_object(const NyError&) { return nullptr; }
    // Per-thread engine state. The runtime creates one per thread (and one
    // per async task) and calls swap_in right after the thread acquires the
    // GIL and swap_out right before it releases it, and both when it switches
    // between a loop and its tasks on one thread (the VM keeps one operand
    // stack/frame stack per thread by swapping them in and out of the single
    // VirtualMachine object; the interpreter its call depth, control flow and
    // exception stack). A swap exchanges the live state with the record's, so
    // swap_in and swap_out may be the same operation.
    // Called (GIL held) on the thread that is about to start another thread or
    // an event loop.
    virtual void  on_thread_start() {}
    virtual void* state_new() { return nullptr; }
    virtual void  state_free(void*) {}
    virtual void  swap_in(void*) {}
    virtual void  swap_out(void*) {}
};

// ── Arguments / results of the shared builtin dispatcher ────────────────────
struct Args {
    virtual ~Args() = default;
    virtual size_t size() const = 0;
    virtual bool is_none(size_t i) const = 0;
    virtual bool is_number(size_t i) const = 0;
    virtual bool is_string(size_t i) const = 0;
    virtual bool is_list(size_t i) const = 0;
    virtual int64_t as_int(size_t i) const = 0;
    virtual double as_num(size_t i) const = 0;
    virtual std::string as_str(size_t i) const = 0;
    virtual bool truthy(size_t i) const = 0;
    virtual BoxPtr box(size_t i) const = 0;
    // Elements of a list argument, as another Args.
    virtual std::unique_ptr<Args> list(size_t i) const = 0;
};

struct Ret {
    enum Kind { NONE, BOOL, INT, NUM, STR, BOX, LIST } k = NONE;
    bool b = false; int64_t i = 0; double d = 0; std::string s; BoxPtr box;
    std::vector<Ret> list;
    static Ret none() { return Ret(); }
    static Ret boolean(bool v) { Ret r; r.k = BOOL; r.b = v; return r; }
    static Ret integer(int64_t v) { Ret r; r.k = INT; r.i = v; return r; }
    static Ret number(double v) { Ret r; r.k = NUM; r.d = v; return r; }
    static Ret str(const std::string& v) { Ret r; r.k = STR; r.s = v; return r; }
    static Ret boxed(const BoxPtr& v) { Ret r; if (v) { r.k = BOX; r.box = v; } return r; }
    static Ret lst(std::vector<Ret> v) { Ret r; r.k = LIST; r.list = std::move(v); return r; }
};

// Dispatch a concurrency builtin. Returns false if `name` is not one of ours.
// Throws NyError for Nython-level errors. Called with the GIL held.
bool dispatch(Engine& e, const std::string& name, const Args& a, Ret& out);

// Every builtin name handled by dispatch(), for registration by the engines.
const std::vector<std::string>& builtin_names();
// Exception type names the runtime raises (registered as constructors).
const std::vector<std::string>& exception_names();

// ── GIL ─────────────────────────────────────────────────────────────────────
extern std::atomic<int> g_gil_waiters;      // threads queued for the GIL
void tick_slow();
// Called by the engines at every statement / instruction.
inline void tick() {
    if (__builtin_expect(g_gil_waiters.load(std::memory_order_relaxed) != 0, 0)) tick_slow();
}
bool active();                              // true once a second thread exists
// True when this thread may touch engine values: it holds the GIL, or there
// is no GIL yet (one thread).
bool holds_gil();
// Release the GIL around a blocking native operation (no-op when inactive or
// not held). The operation must not touch engine state while released.
struct GilRelease {
    bool released = false;
    GilRelease();
    ~GilRelease();
    GilRelease(const GilRelease&) = delete;
    GilRelease& operator=(const GilRelease&) = delete;
};

// ── Async tasks inside generators ───────────────────────────────────────────
// An async task runs on a coroutine of the thread running its loop. When it
// blocks inside an interpreter generator's body (another coroutine, nested
// in the task's), the generator's coroutine suspends with a relay request:
// whoever resumed it (src/NyGen.cpp) must save the generator's state as at
// a yield, call relay_park() - which leaves through its own coroutine the
// same way, or switches to the loop - and, when that returns, resume the
// generator again. GIL held.
bool relay_requested();   // true once per request
void relay_park();

// ── Signals (round 77, section 9 of NyConc.cpp) ─────────────────────────────
// The C handler records the signal; the Nython handlers run on the main
// thread. Engines call run_signal_handlers() where signal_pending() at their
// tick sites and turn a NyError it throws into their own exception (the
// default SIGINT handler raises KeyboardInterrupt).
extern std::atomic<int> g_sig_any;
inline bool signal_pending() { return g_sig_any.load(std::memory_order_relaxed) != 0; }
void install_default_signals();   // SIGINT -> KeyboardInterrupt; at program start
void run_signal_handlers();       // GIL held; a no-op off the main thread
bool is_main_thread();

// ── I/O waits (round 77) ─────────────────────────────────────────────────────
// Until fd is readable / writable, or timeout_ms passes (< 0: no limit).
// Returns the ready events (IO_ERR on a socket error or hang-up), 0 on a
// timeout. Called with the GIL held: a thread releases it while it waits; an
// async task parks on its loop's poller, so the loop's other tasks run.
// Signals are handled inside (the wait resumes after a handler returns);
// throws NyError (CancelledError, a signal handler's exception).
enum { IO_READ = 1, IO_WRITE = 2, IO_ERR = 4 };

// One line from stdin for input(), without its newline: the GIL is released
// while it waits (other threads run), a signal's handler runs (Ctrl+C
// raises KeyboardInterrupt) and the read resumes when it returns. False at
// the end of input (input() raises EOFError). Both engines.
bool read_stdin_line(std::string& out);
// With NY_INPUT_REQUEST set in the environment (the IDE sets it for the
// programs it runs), a read of stdin first writes INPUT_REQUEST_MARK to
// stdout: a host showing the output knows the program now waits for input
// and that the text since the last newline is its prompt. An OSC sequence,
// so a terminal that sees one ignores it. read_stdin_line does it; a reader
// of its own calls announce_input_request() before it blocks.
constexpr const char* INPUT_REQUEST_MARK = "\x1b]ny;input\x07";
void announce_input_request();
int wait_io(intptr_t fd, int events, double timeout_ms);
// Several at once (select): fills each revents; returns how many are ready
// (0 on a timeout).
struct IoReq { intptr_t fd = -1; int events = 0; int revents = 0; };
// True on an async task's coroutine (its waits park it on the loop).
bool in_async_task();
int wait_io_many(std::vector<IoReq>& reqs, double timeout_ms);

// Wait for every non-daemon thread before the process tears the engine down
// (both engines' run paths call this after the main program). Never throws;
// reports a deadlock at exit instead of hanging.
void join_nondaemon_at_exit();

} // namespace nyconc
